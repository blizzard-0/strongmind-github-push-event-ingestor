# Design Brief

## Problem understanding

The service ingests a recent page of public GitHub activity, selects only
`PushEvent` records, and retains enough information for later inspection and
analysis. Each valid event must preserve its original payload while exposing the
repository ID, push ID, ref, head, and before SHA as independently queryable fields.
Actor and repository responses add useful context, but enrichment is secondary to
durable event storage.

The design therefore prioritizes operability, idempotency, and failure isolation.
One malformed event or unavailable enrichment resource must not terminate a batch or
discard another valid PushEvent.

## Architecture

```text
GitHub Public Events API
          |
          v
    Github::Client
          |
          v
  Github::EventParser
          |
          v
Github::PushEventIngestor ----> PostgreSQL
          |
          +----> Github::ActorEnricher
          |
          +----> Github::RepositoryEnricher
```

The same Rails API-only image supports a long-running `web` service, a one-shot
`ingest` service, and the test command. PostgreSQL stores PushEvents and normalized
actor/repository enrichment. The web service exposes health and read-only paginated
inspection endpoints; it performs no GitHub calls during reads.

## Key decisions

- **Rails API-only:** keeps controllers and middleware focused on JSON operations.
- **JSONB plus structured columns:** retains the complete source event without giving
  up efficient queries over required push fields.
- **Persist before enrichment:** each valid PushEvent is committed before any actor
  or repository HTTP request. Associations remain nullable when enrichment fails.
- **Database-level identity:** unique indexes on GitHub event and entity IDs are the
  final authority for idempotency and concurrency races.
- **PostgreSQL enrichment cache:** usable actor/repository rows are reused
  indefinitely, conserving the unauthenticated GitHub allowance without another
  caching system.
- **Bounded synchronous retries:** the HTTP client retries only transient network,
  selected 5xx, and reasonable rate-limit waits. It validates that event-provided
  URLs use HTTPS on `api.github.com`.
- **Failure isolation:** parsing, persistence, and enrichment failures are classified
  per event so later records continue.
- **One-shot ingestion:** a Compose command performs one collection request and
  exits, avoiding an unnecessary worker or polling daemon.
- **Operational logs:** concise stdout/stderr lifecycle events include run IDs,
  counts, safe identifiers, failures, and rate-limit metadata.

## Rate limits and fan-out control

GitHub access is deliberately unauthenticated. HTTP 429 and rate-limit-indicated
HTTP 403 responses retain reset, remaining, and retry metadata. Retries are bounded,
and waits beyond the configured in-code maximum are not performed.

Enrichment runs sequentially and consults PostgreSQL before fetching an entity. If an
enrichment request becomes rate limited, the ingestor stops additional enrichment
fan-out for that batch. Valid events already fetched continue to persist without
associations where necessary. No authenticated token is supported.

## Durability and restart safety

`push_events.github_event_id` is unique and drives repeat-run idempotency. Actor and
repository GitHub IDs are also unique, and foreign keys protect event associations.
JSON-object check constraints prevent non-object raw payloads.

Event creation uses a short database transaction and no external HTTP request occurs
inside it. A pre-insert existence check handles the common duplicate case, while
`RecordNotUnique` recovery handles concurrent inserts. Duplicate events can repair
missing enrichment without overwriting their original raw payload.

There is no ingestion checkpoint. GitHub's public events endpoint exposes a recent,
non-durable window rather than an ordered historical stream, so repeated runs are
safe but cannot guarantee complete coverage.

## Tradeoffs and assumptions

- This is not a complete historical GitHub archive; events can be missed between
  manual ingestion runs.
- Actor and repository enrichment can be incomplete due to missing URLs, resource
  errors, or rate limits.
- Normalized enrichment is reused indefinitely and can become stale.
- Sequential enrichment favors simple failure handling and predictable request usage
  over throughput.
- The paginated read-only API is an inspection surface, not a public product API.
- PostgreSQL is the sole durable store and enrichment cache.

## Intentionally not built

The repository intentionally excludes a frontend, authentication, write API, Redis,
Kafka, a background queue, Kubernetes, cloud deployment, object storage, full
historical backfill, and authenticated GitHub API integration.
