# StrongMind GitHub Events — Implementation Plan

## Scope and guiding decisions

Build a small Rails API-only service that fetches unauthenticated public events from
`https://api.github.com/events`, selects `PushEvent` records, stores each event's
complete payload plus queryable push fields, and enriches it with actor and repository
details. PostgreSQL is the durable source of truth. A Docker Compose one-shot `ingest`
service provides repeatable ingestion; the API service provides health and read-only
inspection endpoints.

The implementation will favor Rails conventions, explicit service objects, database
constraints, and bounded synchronous work. It will not introduce Redis, Kafka,
Kubernetes, a frontend, object storage, cloud infrastructure, or a background-job
system. Continuous ingestion, if included, will be a simple shell loop around the
one-shot ingestion command with a conservative interval rather than another runtime
dependency.

## 1. Proposed architecture

The system has three runtime components:

1. **Rails API service (`web`)** — boots the application, exposes a health endpoint,
   and optionally exposes read-only JSON endpoints for inspecting stored push events.
2. **One-shot ingestion process (`ingest`)** — runs a Rails runner or Rake task that
   invokes the ingestion service, logs a batch summary, then exits with a predictable
   status. It uses the same image and application code as `web`.
3. **PostgreSQL (`db`)** — stores push events and cached actor/repository enrichment.

The application flow is:

```text
GitHub public events API
        |
        v
GitHubApiClient (HTTP, headers, retry/rate-limit classification)
        |
        v
PushEventIngestor (filter and isolate failures per event)
        |
        +--> ActorEnricher ------> actors
        +--> RepositoryEnricher -> repositories
        |
        v
push_events (structured columns + complete JSONB payload)
```

No external queue is required. The source endpoint returns a small page of recent
events, and database uniqueness makes repeated runs safe.

## 2. Rails API application structure

Generate Rails in API-only mode with PostgreSQL and RSpec:

- `ApplicationRecord` models for persistence.
- Small service classes under `app/services` for GitHub HTTP access, ingestion, and
  enrichment.
- Domain-specific errors under `app/errors` (or beside the client if fewer files are
  clearer).
- A Rake task under `lib/tasks` as the stable ingestion entry point.
- Minimal controllers under `app/controllers/api/v1` for health and record
  inspection; no write API is needed for the assessment.
- Environment configuration for database URLs, HTTP timeouts, maximum retries, and
  enrichment freshness.

Business behavior will remain outside controllers and tasks. The task invokes one
top-level ingestor; the ingestor coordinates client and persistence services.

## 3. PostgreSQL data model

### `push_events`

| Column | Type | Null? | Purpose |
| --- | --- | --- | --- |
| `id` | bigint primary key | no | Internal Rails key |
| `github_event_id` | string | no | GitHub event ID and idempotency key |
| `repository_github_id` | bigint | no | Queryable repository identifier from `repo.id` |
| `push_id` | bigint | no | Queryable identifier from `payload.push_id` |
| `ref` | string | no | Git ref from `payload.ref` |
| `head` | string | no | Head SHA from `payload.head` |
| `before` | string | no | Previous SHA from `payload.before` |
| `actor_id` | bigint foreign key | yes | Cached actor enrichment, if available |
| `repository_id` | bigint foreign key | yes | Cached repository enrichment, if available |
| `raw_payload` | jsonb | no | Complete unmodified GitHub event object |
| `github_created_at` | datetime | yes | Event timestamp for analysis |
| timestamps | datetime | no | Local persistence timestamps |

The five required structured values are mandatory for a valid persisted event.
Malformed records missing them are logged and skipped rather than partially stored.
The raw payload receives a JSONB default of `{}` only as defense in depth; validation
requires a non-empty event object.

### `actors`

| Column | Type | Null? | Purpose |
| --- | --- | --- | --- |
| `id` | bigint primary key | no | Internal Rails key |
| `github_id` | bigint | no | Stable GitHub actor identifier |
| `login` | string | yes | Actor login |
| `api_url` | string | no | Enrichment URL supplied by the event |
| `raw_payload` | jsonb | no | Latest complete actor response |
| `enriched_at` | datetime | yes | Freshness marker |
| timestamps | datetime | no | Local timestamps |

### `repositories`

| Column | Type | Null? | Purpose |
| --- | --- | --- | --- |
| `id` | bigint primary key | no | Internal Rails key |
| `github_id` | bigint | no | Stable GitHub repository identifier |
| `name` | string | yes | Repository name/full name |
| `api_url` | string | no | Enrichment URL supplied by the event |
| `raw_payload` | jsonb | no | Latest complete repository response |
| `enriched_at` | datetime | yes | Freshness marker |
| timestamps | datetime | no | Local timestamps |

Keeping enrichment in normalized tables avoids copying large actor and repository
responses into every event while retaining the event's original embedded data in
`push_events.raw_payload`.

## 4. Models, relationships, indexes, and database constraints

- `PushEvent belongs_to :actor, optional: true`.
- `PushEvent belongs_to :repository, optional: true`.
- `Actor has_many :push_events`.
- `Repository has_many :push_events`.
- Unique indexes on `push_events.github_event_id`, `actors.github_id`, and
  `repositories.github_id`.
- Foreign keys from `push_events.actor_id` and `push_events.repository_id`.
- Non-null database constraints on required structured fields and raw JSONB columns.
- JSONB columns use `default: {}` and `null: false`.
- Indexes on `push_events.repository_github_id`, `push_events.push_id`,
  `push_events.github_created_at`, `push_events.actor_id`, and
  `push_events.repository_id`.
- Optional composite index on `[repository_github_id, github_created_at]` for the
  likely query of recent pushes by repository.
- Check constraints ensure raw payloads are JSON objects
  (`jsonb_typeof(raw_payload) = 'object'`).

Rails validations mirror important constraints for useful errors, but correctness
does not depend on validations. Persistence catches `ActiveRecord::RecordNotUnique`
so concurrent or repeated ingestion reports a duplicate instead of failing the batch.

## 5. GitHub API client responsibilities

`Github::Client` will be the only class that performs HTTP calls. It will:

- Fetch the public events collection and actor/repository URLs supplied by events.
- Send an explicit `User-Agent` and GitHub API `Accept` header.
- Use open/read timeouts and parse JSON safely.
- Allow only `https://api.github.com/...` enrichment URLs to prevent arbitrary
  outbound requests from untrusted payload data.
- Return parsed JSON plus relevant response metadata when successful.
- Classify rate limits, transient failures, permanent HTTP errors, malformed JSON,
  timeouts, and connection failures into explicit error types.
- Read `X-RateLimit-Remaining`, `X-RateLimit-Reset`, `Retry-After`, `ETag`, and
  `Last-Modified` headers where applicable.
- Implement bounded retry behavior in one place and accept injectable sleeper/clock
  collaborators so tests remain fast and deterministic.
- Never read or require a GitHub token.

The client will use a lightweight HTTP library already suitable for Rails (prefer
Faraday only if its adapter/test stubbing materially simplifies the code; otherwise
Ruby `Net::HTTP` avoids another dependency).

## 6. PushEvent ingestion flow

`Github::PushEventIngestor#call` will:

1. Log `ingestion.started` with a batch/run identifier.
2. Request one page from `/events` using a conservative `per_page` value, with no
   unnecessary pagination by default.
3. Validate that the top-level response is an array.
4. Iterate through records and ignore non-`PushEvent` objects.
5. Process each candidate inside its own rescue boundary so one bad event cannot end
   the batch.
6. Validate and extract the GitHub event ID, repository ID, push ID, ref, head,
   before, actor/repository API URLs, and event timestamp.
7. Check for an existing `github_event_id`; log and count a duplicate when found.
8. Resolve reusable actor and repository records and enrich only when necessary.
9. Create the `PushEvent` with its structured fields, associations, and the complete
   raw event hash in a short database transaction.
10. Treat a uniqueness conflict as a duplicate, supporting races safely.
11. Log success or a structured failure for that event.
12. Log `ingestion.completed` with fetched, filtered, created, duplicate, malformed,
    enrichment-failure, and failed counts plus elapsed time.

An individual enrichment failure will not discard an otherwise valid push event.
The event is persisted with a nullable association and can be enriched on a later
ingestion run.

## 7. Actor and repository enrichment strategy

Separate `ActorEnricher` and `RepositoryEnricher` services will:

- Identify records by stable GitHub numeric ID, not by mutable login/name.
- Find or initialize the normalized record.
- Fetch the payload from the event-provided API URL only when the record lacks usable
  enrichment or its data is stale.
- Validate that the response represents the expected GitHub ID before saving it.
- Update selected query-friendly fields, the complete enrichment JSONB payload, API
  URL, and `enriched_at`.
- Use `upsert`/unique-conflict recovery to remain safe if two runs enrich the same
  entity concurrently.
- Log `enrichment.succeeded`, `enrichment.skipped`, and `enrichment.failed` with
  entity type and GitHub ID.

The event is the durable priority. If actor or repository details cannot be fetched,
the ingestor logs the error and saves the event without that association. A later
duplicate encounter may invoke a repair path that attaches missing enrichment without
creating another event.

## 8. Avoiding unnecessary repeated enrichment requests

An enrichment record is usable when it has a non-empty object payload and a populated
`enriched_at`. By default it will be reused indefinitely during this assessment,
because stable identifiers and durable caching provide the best use of the small
unauthenticated rate-limit budget. A configurable freshness duration may be supported
(`ENRICHMENT_TTL`, default several days) if refresh behavior is desired.

Additional fan-out controls:

- Deduplicate actor and repository IDs within each fetched batch before making
  enrichment calls where practical.
- Look up local records before every outbound enrichment request.
- Check whether a duplicate event has missing associations; only fetch the missing
  entity.
- Enrich sequentially, not with unbounded threads.
- Cap total enrichment HTTP requests per ingestion run with a configurable budget.
  Valid events beyond that budget are still stored and can be repaired later.
- Optionally persist response ETags later, but do not add that complexity unless the
  core implementation and tests are complete.

## 9. GitHub rate-limit handling

The unauthenticated GitHub limit is a shared, scarce budget, so ingestion will be
deliberately conservative:

- Inspect rate-limit headers on every GitHub response.
- Before fan-out, stop further enrichment if `X-RateLimit-Remaining` reaches a small
  safety threshold.
- Treat HTTP 429 as rate limited.
- Treat HTTP 403 as rate limited only when rate-limit headers or response content
  indicate it; other 403 responses are permanent request failures.
- Prefer `Retry-After`; otherwise calculate delay from `X-RateLimit-Reset`.
- Add a small jitter to avoid synchronized retries.
- Bound any in-process wait with a configurable maximum. If the reset is too far
  away, log the reset time, stop the current batch gracefully, and let a later
  invocation resume.
- Do not rapidly poll. Documentation will recommend an ingestion interval of at least
  60 seconds, and the one-shot command itself performs only one collection request.
- Emit a structured `github.rate_limited` log containing status, remaining requests,
  reset time, chosen delay, URL category, and whether the run will retry or stop.

Rate limiting during enrichment will stop additional enrichment fan-out but will not
roll back already persisted events or cause a crash loop.

## 10. Retry and transient failure handling

Retry only failures likely to recover:

- HTTP 500, 502, 503, and 504.
- Connection reset/refused and temporary DNS/network errors.
- Open/read timeouts.
- HTTP 429 and confirmed rate-limit 403 only when the required wait is within the
  configured maximum.

Use a small bounded number of attempts (for example, three total attempts) with
exponential backoff such as 1s, 2s, plus jitter. Honor `Retry-After` when it is
present. Log every retry with attempt number, reason, and delay.

Do not retry malformed JSON, invalid payload shapes, missing required event fields,
most other 4xx responses, or enrichment identity mismatches. Exhausted collection
request failures cause the command to exit non-zero after a clear completion/failure
log. Exhausted per-entity enrichment failures are logged and isolated so event
persistence can proceed.

## 11. Idempotency and restart safety

- `github_event_id` is the application and database idempotency key.
- A database-level unique index is the final authority for duplicate prevention.
- A fast existence check avoids unnecessary enrichment for known complete events,
  while `RecordNotUnique` handles races.
- Each event is committed independently; a crash loses at most the event currently
  being processed.
- Re-running ingestion re-fetches recent public events, reports duplicates, repairs
  missing enrichment where possible, and creates only unseen events.
- Actor and repository uniqueness constraints make enrichment upserts restart-safe.
- No checkpoint is required because the GitHub public events endpoint is a recent
  window rather than an ordered durable stream. This limitation will be explicit in
  `DESIGN.md`: polling can miss events between runs and is not intended as a complete
  historical archive.

## 12. Logging and observability

Logs go to stdout/stderr through Rails' logger in a consistent, structured
key-value/JSON-like format. Each ingestion run gets a generated `run_id`.

Required event names include:

- `ingestion.started`
- `ingestion.completed`
- `push_event.processed`
- `push_event.duplicate`
- `push_event.malformed`
- `enrichment.started`
- `enrichment.succeeded`
- `enrichment.skipped`
- `enrichment.failed`
- `github.retry`
- `github.rate_limited`
- `github.request_failed`

Logs include safe identifiers, counts, attempt numbers, status codes, elapsed time,
and error class/message. They do not dump entire raw payloads, which may be noisy.
Unexpected exceptions include backtraces at error level. A simple `/health` endpoint
will confirm the Rails process and database connection. The ingestion task's exit
status will distinguish a failed source fetch from a successfully completed batch
that contained isolated record errors.

## 13. Dockerfile and Docker Compose structure

Use one production-like application image:

- A multi-stage `Dockerfile` based on a pinned official Ruby slim image.
- Install build dependencies only in the build stage and PostgreSQL runtime client
  libraries in the final stage.
- Install gems via Bundler, copy application code, and run as a non-root user where
  practical.
- An entrypoint removes a stale Rails PID and prepares the database for `web`;
  migration behavior will be explicit rather than hidden for test/ingest commands.

`compose.yaml` will define:

- `db`: pinned PostgreSQL image, health check, named volume, and development
  credentials supplied by Compose/environment.
- `web`: application image, database dependency gated by health, port mapping, and
  Rails server command.
- `ingest`: same image/configuration, a one-shot Rake ingestion command, and a
  database health dependency.
- `test`: same image with `RAILS_ENV=test`, isolated test database name, and RSpec
  command.

The final reviewer workflow will support:

```sh
docker compose up --build
docker compose run --rm ingest
docker compose run --rm test
```

All Ruby, Rails, PostgreSQL, and test dependencies run inside Docker Compose. A
`.dockerignore`, `.env.example`, and explicit Compose defaults will keep setup small
and reproducible.

## 14. RSpec testing strategy

Use RSpec, FactoryBot only if it materially reduces setup, and WebMock (or injected
HTTP adapters) so no test can reach the real GitHub API. Disable external network
connections in the test suite except localhost.

Test layers:

- **Model/database specs**
  - Required field validations.
  - Relationships.
  - Unique event, actor, and repository IDs.
  - JSONB raw payload persistence without loss.
  - Database constraints, including a direct persistence attempt that bypasses Rails
    validation where useful.
- **GitHub client specs**
  - Headers, parsing, timeouts, and allowed host validation.
  - Successful collection/entity responses.
  - 403/429 rate-limit classification and header handling.
  - Bounded 5xx/network retries and exponential delays with an injected fake sleeper.
  - No retry for permanent 4xx or malformed JSON.
  - Retry exhaustion.
- **Ingestor specs**
  - Filters out non-`PushEvent` records.
  - Extracts repository ID, push ID, ref, head, and before.
  - Stores the exact full raw event payload.
  - Prevents duplicates across repeated runs.
  - Handles a uniqueness race.
  - Enriches and associates actor/repository records.
  - Reuses existing usable enrichment without HTTP requests.
  - Continues after malformed events and missing required fields.
  - Persists valid events when enrichment fails.
  - Stops fan-out predictably when rate limited or request budget is exhausted.
  - Produces accurate batch counts.
- **Request/task specs**
  - Health/read endpoint behavior.
  - Ingestion task success and source-fetch failure behavior.

Fixtures under `spec/fixtures/github` will contain representative collection,
PushEvent, actor, repository, malformed, and error payloads. Tests will assert both
observable persistence and selected log messages for key operational paths without
over-specifying every log string.

## 15. `README.md` and `DESIGN.md` deliverables

`README.md` will document prerequisites (Docker and Docker Compose only), initial
build/start, database setup, one-shot ingestion, tests, configuration, logs, record
inspection through Rails console/API/SQL, troubleshooting, and expected timing.
Results should normally appear within seconds after `docker compose run --rm ingest`,
subject to GitHub availability and rate limits.

It will contain the exact heading:

```markdown
## How to verify it's working
```

That section will give copy-paste commands to run ingestion, inspect logs, count
stored records, and view one structured/raw record.

`DESIGN.md` will remain within 1–2 pages and summarize:

- Problem understanding and scope.
- Architecture and service boundaries.
- Data durability and idempotency.
- Enrichment caching and fan-out control.
- Rate-limit and retry behavior.
- Key assumptions and tradeoffs, including the public endpoint's recent-window
  limitation.
- Intentionally omitted systems and features.

## 16. Planned repository file structure

```text
.
├── AGENTS.md
├── IMPLEMENTATION_PLAN.md
├── README.md
├── DESIGN.md
├── Dockerfile
├── compose.yaml
├── .dockerignore
├── .env.example
├── Gemfile
├── Gemfile.lock
├── Rakefile
├── config.ru
├── app
│   ├── controllers
│   │   ├── application_controller.rb
│   │   └── api/v1
│   │       ├── health_controller.rb
│   │       └── push_events_controller.rb
│   ├── models
│   │   ├── application_record.rb
│   │   ├── actor.rb
│   │   ├── repository.rb
│   │   └── push_event.rb
│   └── services
│       └── github
│           ├── client.rb
│           ├── errors.rb
│           ├── push_event_ingestor.rb
│           ├── event_parser.rb
│           ├── actor_enricher.rb
│           └── repository_enricher.rb
├── bin
│   ├── docker-entrypoint
│   ├── rails
│   └── rake
├── config
│   ├── application.rb
│   ├── boot.rb
│   ├── database.yml
│   ├── environment.rb
│   ├── environments
│   │   ├── development.rb
│   │   ├── test.rb
│   │   └── production.rb
│   ├── initializers
│   │   └── filter_parameter_logging.rb
│   ├── routes.rb
│   └── puma.rb
├── db
│   ├── migrate
│   │   ├── *_create_actors.rb
│   │   ├── *_create_repositories.rb
│   │   └── *_create_push_events.rb
│   └── schema.rb
├── lib
│   └── tasks
│       └── github_ingestion.rake
└── spec
    ├── fixtures/github
    │   ├── events.json
    │   ├── push_event.json
    │   ├── actor.json
    │   ├── repository.json
    │   └── malformed_events.json
    ├── models
    │   ├── actor_spec.rb
    │   ├── repository_spec.rb
    │   └── push_event_spec.rb
    ├── requests
    │   ├── health_spec.rb
    │   └── push_events_spec.rb
    ├── services/github
    │   ├── client_spec.rb
    │   ├── event_parser_spec.rb
    │   ├── actor_enricher_spec.rb
    │   ├── repository_enricher_spec.rb
    │   └── push_event_ingestor_spec.rb
    ├── tasks
    │   └── github_ingestion_spec.rb
    ├── rails_helper.rb
    └── spec_helper.rb
```

Exact generated Rails support files may vary with the selected Rails version. Files
will be kept only when required for the application or standard Rails operation.

## 17. Step-by-step implementation order

1. Pin compatible Ruby, Rails, PostgreSQL, and RSpec versions; generate the Rails
   API-only skeleton without installing anything on the host.
2. Add the Dockerfile, entrypoint, Compose services, database configuration, and
   health checks; verify the empty Rails app and test command boot in containers.
3. Configure RSpec and prohibit real external network calls.
4. Create migrations for actors, repositories, and push events with all indexes,
   foreign keys, defaults, and check/unique constraints.
5. Implement models, relationships, and validations; add database-focused specs.
6. Add representative GitHub fixtures.
7. Implement the GitHub client with safe URL handling, timeouts, response metadata,
   explicit errors, bounded retries, rate-limit behavior, and unit specs.
8. Implement the event parser for validation and structured extraction; cover valid
   and malformed payloads.
9. Implement actor and repository enrichers with durable reuse, stale/missing checks,
   uniqueness-race safety, request budgeting, and specs.
10. Implement the push-event ingestor with filtering, per-event isolation,
    idempotent persistence, enrichment repair, batch summaries, and logs.
11. Add the one-shot Rake task and Compose `ingest` service; verify repeat runs create
    no duplicates.
12. Add minimal health and read-only inspection endpoints with request specs.
13. Exercise rate-limit, retry exhaustion, malformed JSON, missing fields,
    connection failure, duplicate race, and partial enrichment failure scenarios.
14. Write `README.md`, including the exact verification heading and reviewer
    commands.
15. Write the concise `DESIGN.md`, explicitly recording tradeoffs and omissions.
16. Run the complete reviewer workflow from a clean Docker Compose environment,
    inspect stdout logs and stored records, and fix any reproducibility issues.

Implementation is considered complete when the three required Docker Compose commands
work without host Ruby/PostgreSQL, all required behaviors have isolated tests, repeat
ingestion is demonstrably idempotent, and the documentation lets a reviewer verify
the service quickly.
