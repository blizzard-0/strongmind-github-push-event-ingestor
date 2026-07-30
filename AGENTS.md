# StrongMind Full Stack Developer Assessment

## Goal

Build an internal service that ingests GitHub public PushEvent activity,
enriches it with actor and repository information, and stores the data
for future querying and analysis.

## Required Stack

- Ruby on Rails
- Rails API-only mode is acceptable
- PostgreSQL
- Docker
- Docker Compose
- All dependencies must run through Docker Compose

Do not require Ruby, Rails, or PostgreSQL to be installed on the host.

## GitHub API

Use:

https://api.github.com/events

Do NOT use an authenticated GitHub token.

The service must:
- Be aware of GitHub rate limits
- Behave predictably when rate-limited
- Avoid unnecessary polling

## Story 1 — Ingest Push Events

- Fetch GitHub public events
- Process only `PushEvent`
- Persist each event durably
- Events must have a unique identifier
- Ingestion must be repeatable or continuous

## Story 2 — Raw + Structured Persistence

Keep the complete raw GitHub event payload.

Also store these as normal queryable database columns:

- repository identifier
- push identifier
- ref
- head
- before

Prefer PostgreSQL JSONB for the raw payload.

## Story 3 — Enrichment

Fetch actor and repository information using URLs available from the
GitHub event payload.

Persist enrichment data.

Avoid repeatedly fetching actor/repository information when usable data
already exists.

## Story 4 — Operability

Logs must clearly show:

- ingestion started/completed
- successful processing
- duplicates
- enrichment
- failures
- retries
- rate limiting

Malformed data must be handled gracefully.

Transient GitHub failures must not cause crash loops.

Logs must go to stdout/stderr.

## Senior-Level Extensions

Prioritize:

1. Rate limiting and fan-out control
2. Idempotency and restart safety
3. Testing strategy

Do not implement object storage unless core functionality is complete.

## Idempotency

Use the GitHub event ID as an idempotency key.

Use database-level unique constraints.

Running ingestion repeatedly must not create duplicate push events.

## Error Handling

Handle:

- HTTP 403 / 429 rate limits
- HTTP 5xx errors
- connection failures
- timeouts
- malformed JSON
- missing fields

Use bounded retries with exponential backoff where appropriate.

Never allow one malformed event to terminate an entire batch.

## Testing

Use RSpec.

Tests must not call the real GitHub API.

Stub or fixture GitHub responses.

Cover at minimum:

- filtering PushEvent
- structured field extraction
- raw payload persistence
- duplicate prevention
- actor/repository enrichment
- malformed events
- rate-limit handling
- retry behavior

## Required Reviewer Commands

The final repository should support commands equivalent to:

docker compose up --build

docker compose run --rm ingest

docker compose run --rm test

## Documentation

Create:

- README.md
- DESIGN.md

DESIGN.md must be no more than 1–2 pages and explain:

- understanding of the problem
- architecture
- key tradeoffs and assumptions
- rate-limit handling
- durability
- enrichment strategy
- what was intentionally not built

README.md must explain:

- how to start
- how to run ingestion
- how to run tests
- how to inspect logs
- how to inspect stored records
- how long results should take to appear

Include a section exactly titled:

## How to verify it's working

## Engineering Principles

Prefer:
- simple code
- clear service boundaries
- explicit failure handling
- database constraints
- maintainable Rails conventions

Avoid unnecessary:
- Redis
- Kafka
- Kubernetes
- frontend UI
- cloud infrastructure

Focus on a polished, reliable assessment submission rather than excessive features.