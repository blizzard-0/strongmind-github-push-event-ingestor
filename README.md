# StrongMind GitHub Push Event Ingestor

## Overview

This Rails API service fetches one page of recent activity from GitHub's public
events API, processes only `PushEvent` records, and stores them in PostgreSQL.
Each event retains its complete original JSON payload and also exposes commonly
queried push fields as normal database columns. Actor and repository details are
enriched when GitHub's unauthenticated API allowance permits.

The service is designed for repeatable one-shot ingestion and reviewer inspection.
It does not require a GitHub token.

## Architecture

The repository uses one application image for three roles:

- `web` runs the Rails API and health endpoint.
- `ingest` runs one ingestion batch and exits.
- `test` prepares the test database and runs RSpec.

PostgreSQL is both the durable event store and the cache for actor and repository
enrichment. `Github::Client` owns outbound HTTP behavior, `Github::EventParser`
validates event data, and `Github::PushEventIngestor` persists each valid event
before coordinating enrichment.

## Technology stack

- Ruby 3.3
- Rails 8 in API-only mode
- PostgreSQL 17
- RSpec and WebMock
- Docker and Docker Compose

## Prerequisites

Only these host tools are required:

- Git
- Docker
- Docker Compose

Ruby, Rails, PostgreSQL, Bundler, and project gems run inside containers and do not
need to be installed on the host.

## Quick start

```sh
git clone https://github.com/blizzard-0/strongmind-github-push-event-ingestor.git
cd strongmind-github-push-event-ingestor
docker compose up --build
```

This starts PostgreSQL and the Rails API. Compose waits for PostgreSQL's health
check before starting Rails, and the application entrypoint prepares the development
database. Rails is available on port `3000` by default.

In another terminal, check both Rails and PostgreSQL:

```sh
curl -i http://localhost:3000/health
```

Expected JSON:

```json
{"status":"ok","rails":"ok","database":"ok"}
```

Use `docker compose up --build -d` instead to run the services in the background.

## Running ingestion

Run one ingestion batch:

```sh
docker compose run --rm ingest
```

The command makes one unauthenticated request to
`https://api.github.com/events`, processes only `PushEvent` records, stores their
raw and structured data, attempts actor and repository enrichment, prints a batch
summary, and exits. It does not continuously poll and is safe to run repeatedly.
The GitHub event ID and a database unique constraint prevent duplicate events.

A valid event is committed before actor or repository enrichment begins. An isolated
malformed event or enrichment failure is logged but does not discard other valid
events. Failure to fetch the source collection produces a non-zero command exit.

Operational log events include:

- `ingestion.started`
- `ingestion.events_fetched`
- `push_event.processed`
- `push_event.duplicate`
- `push_event.malformed`
- `enrichment.succeeded`
- `enrichment.skipped`
- `enrichment.failed`
- `github.rate_limited`
- `ingestion.completed`
- `ingestion.failed`

## Inspecting stored events

The API exposes read-only inspection endpoints:

```text
GET /health
GET /api/v1/push_events
GET /api/v1/push_events/:id
```

List recent events:

```sh
curl -s "http://localhost:3000/api/v1/push_events?page=1&per_page=20"
```

Collection results are ordered by GitHub creation time newest first, default to 20
records per page, and cap `per_page` at 100. They include structured event fields and
compact actor/repository summaries, but exclude `raw_payload`.

An optional GitHub event ID filter is available:

```sh
curl -s "http://localhost:3000/api/v1/push_events?github_event_id=EVENT_ID"
```

Find an internal record ID:

```sh
docker compose run --rm web \
  bin/rails runner \
  'puts PushEvent.order(:id).first&.id'
```

Then inspect the detail response:

```sh
curl -s http://localhost:3000/api/v1/push_events/RECORD_ID
```

Detail responses include the complete `raw_payload`. Unknown record IDs return a
JSON error with HTTP 404. Read requests never fetch data from GitHub.

### Database inspection

Count stored records without needing PostgreSQL credentials:

```sh
docker compose run --rm web \
  bin/rails runner \
  'puts({push_events: PushEvent.count, actors: Actor.count, repositories: Repository.count}.to_json)'
```

Check for duplicate GitHub event IDs:

```sh
docker compose run --rm web \
  bin/rails runner \
  'puts PushEvent.group(:github_event_id).having("COUNT(*) > 1").count.to_json'
```

Expected result:

```json
{}
```

Show one event's structured fields without printing its raw payload:

```sh
docker compose run --rm web \
  bin/rails runner \
  'event = PushEvent.order(:id).last; puts(event&.slice(:github_event_id, :repository_github_id, :push_id, :ref, :head, :before).to_json)'
```

### Data model

`push_events` stores the complete event in a PostgreSQL JSONB `raw_payload`, plus
`github_event_id`, `repository_github_id`, `push_id`, `ref`, `head`, `before`, and
`github_created_at`. Actor and repository relationships are optional so enrichment
cannot block durable event persistence.

`actors` stores the stable numeric GitHub ID, login, API URL, full enrichment payload,
and enrichment timestamp. `repositories` stores the stable numeric GitHub ID, name,
API URL, full enrichment payload, and enrichment timestamp.

Database unique constraints enforce event and enrichment identity. Foreign keys
protect associations, and JSON-object check constraints ensure raw payload columns
contain JSON objects.

## Running tests

```sh
docker compose run --rm test
```

RSpec runs entirely through Docker Compose. WebMock disables external network access
in the test suite, so automated tests cannot call the live GitHub API. Coverage
includes models, database constraints, the GitHub client, parsing, enrichment,
ingestion, the Rake task, health behavior, and read-only API responses.

## Configuration

Compose reads `.env` automatically for its supported substitutions. The included
`.env.example` contains development defaults and no real secrets.

| Variable | Default | Purpose |
| --- | --- | --- |
| `POSTGRES_USER` | `strongmind` | PostgreSQL user |
| `POSTGRES_PASSWORD` | `strongmind_development` | Local PostgreSQL password |
| `DB_NAME` | `strongmind_github_events_development` | Development database |
| `TEST_DB_NAME` | `strongmind_github_events_test` | Test database |
| `RAILS_MAX_THREADS` | `5` | Database pool and application concurrency setting |
| `WEB_PORT` | `3000` | Host port mapped to Rails |

Rails also reads `RAILS_LOG_LEVEL` inside the application and defaults to `info`.
For example, it can be passed to a one-shot container with:

```sh
docker compose run --rm -e RAILS_LOG_LEVEL=debug web bin/rails runner 'puts Rails.logger.level'
```

The GitHub client uses fixed bounded timeout and retry defaults in code. No GitHub
token, enrichment TTL, or enrichment-budget environment variable is supported.

## Logging and operational behavior

Application logs go to stdout/stderr and use concise key-value lifecycle messages
with a unique ingestion `run_id`. INFO is the default level, which keeps normal SQL
debug output—including bound raw payloads—out of reviewer logs. Set
`RAILS_LOG_LEVEL` only when more or less verbosity is needed.

Inspect the running API logs with:

```sh
docker compose logs -f web
```

One-shot ingestion writes its lifecycle logs and final summary directly to the
terminal that runs `docker compose run --rm ingest`.

## Rate-limit behavior

GitHub is accessed without authentication, so its unauthenticated request allowance
is limited. The client recognizes HTTP 429 and rate-limit-indicated HTTP 403
responses, retains reset/retry headers, and uses bounded retries only when the wait
is reasonable. It does not sleep inside the container for an excessive reset delay.

If enrichment becomes rate limited, the current run stops additional enrichment
fan-out but continues persisting valid events already fetched from the collection.
The batch result and logs include available reset metadata. Wait until the reported
reset time before running ingestion again.

## Troubleshooting

- **Docker is unavailable:** start Docker Desktop or the Docker daemon, then rerun
  `docker compose up --build`.
- **Port 3000 is in use:** set another host port, for example
  `WEB_PORT=3001 docker compose up --build`, then use port 3001 in curl commands.
- **PostgreSQL is not healthy:** inspect `docker compose ps` and
  `docker compose logs db`. Rails waits for the database health check.
- **GitHub rate limit exceeded:** inspect `github.rate_limited` and the batch summary,
  then wait until the logged reset time.
- **Ingestion exits non-zero:** inspect `github.request_failed` and
  `ingestion.failed`. A source fetch failure is fatal to that one-shot command;
  previously persisted records remain intact.
- **Reset local data:** `docker compose down -v` removes containers and the named
  PostgreSQL volume. **This permanently deletes all locally persisted assessment
  data.** Start again with `docker compose up --build -d`.

## How to verify it's working

1. Build and start the application:

   ```sh
   docker compose up --build -d
   ```

2. Check health:

   ```sh
   curl -i http://localhost:3000/health
   ```

3. Run one ingestion batch:

   ```sh
   docker compose run --rm ingest
   ```

4. Check stored counts:

   ```sh
   docker compose run --rm web \
     bin/rails runner \
     'puts({push_events: PushEvent.count, actors: Actor.count, repositories: Repository.count}.to_json)'
   ```

5. Inspect two collection records:

   ```sh
   curl -s "http://localhost:3000/api/v1/push_events?page=1&per_page=2"
   ```

6. Find and inspect one detail record:

   ```sh
   RECORD_ID="$(docker compose run --rm web bin/rails runner 'puts PushEvent.order(:id).first&.id' | tail -n 1)"
   curl -s "http://localhost:3000/api/v1/push_events/${RECORD_ID}"
   ```

7. Run the test suite:

   ```sh
   docker compose run --rm test
   ```

8. Follow API logs:

   ```sh
   docker compose logs -f web
   ```

Health becomes available after PostgreSQL is healthy and Rails finishes starting.
Ingestion normally completes in seconds, but actor/repository enrichment can take
longer and is constrained by GitHub's unauthenticated rate allowance. A rate-limited
run clearly reports the available reset time.

## Known limitations

- GitHub's public events endpoint is a recent, non-durable window; this is not a
  complete historical archive and polling gaps can miss events.
- Ingestion is one-shot and manually invoked rather than a continuous daemon.
- Actor or repository enrichment may remain incomplete because it is optional and
  rate limited.
- Cached enrichment is reused indefinitely and may become stale.
- Sequential enrichment favors predictable behavior over maximum throughput.
- The read-only API is intended for reviewer inspection and has no authentication.
- There is no frontend, write API, background queue, historical backfill, or cloud
  deployment.
