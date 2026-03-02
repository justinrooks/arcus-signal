# Arcus Signal

Arcus Signal is the notification backend for Project Arcus / SkyAware. It runs as two Vapor executables:

- `Run`: API process for HTTP endpoints
- `RunWorker`: worker process for queue consumption + ingestion scheduling

## Overview

Arcus Signal ingests active NWS CAP alerts from `api.weather.gov`, stores immutable revision records, maintains a canonical alert series snapshot, and dispatches downstream targeting work through queue lanes.

Current ingestion flow:

- Persist revision records idempotently by CAP message URN.
- Resolve/merge referenced revisions into a canonical series.
- Compute and persist geolocation coverage (`GeoShape` JSONB + H3 cells/hash).
- Use a durable outbox table for ingest -> target queue handoff.
- Keep queue processing split across named lanes (`ingest`, `target`, `send`).

## Local SwiftPM

```bash
swift build
swift run Run migrate --yes
swift run Run serve --hostname 0.0.0.0 --port 8080
swift run RunWorker serve --hostname 0.0.0.0 --port 8081
swift test
```

`REDIS_URL` is required outside development/testing environments.
`DATABASE_URL` is required outside development/testing environments.
Optional tuning:

- `QUEUE_WORKER_COUNT` (default `1` for worker runtime)
- `REDIS_POOL_MAX_CONNECTIONS` (default `8`)
- `REDIS_POOL_CONNECTION_TIMEOUT_SECONDS` (default `30`)
- `WORKER_STARTUP_GRACE_SECONDS` (default `5`)

Development/testing Postgres fallback (when `DATABASE_URL` is absent):

- `DATABASE_HOST` (default `127.0.0.1`)
- `DATABASE_PORT` (default `5432`)
- `DATABASE_USERNAME` (default `arcus`)
- `DATABASE_PASSWORD` (default `arcus`)
- `DATABASE_NAME` (default `arcus_signal`)

Current migration set includes series/revision persistence, geolocation (`arcus_geolocation`), and target dispatch outbox (`target_dispatch_outbox`).

## Docker Compose

```bash
docker compose up --build
```

Compose sets defaults for queue tuning env vars (`QUEUE_WORKER_COUNT`, `REDIS_POOL_MAX_CONNECTIONS`, `REDIS_POOL_CONNECTION_TIMEOUT_SECONDS`, `WORKER_STARTUP_GRACE_SECONDS`).

Services:

- `api` on `:8080` (`GET /health`)
- `worker` on `:8081` (`GET /health`)
- `redis` on `:6379`
- `postgres` on `:5432`

The worker uses Vapor Queues scheduled jobs to dispatch `IngestNWSAlertsJob` every 60 seconds (`minutely().at(0)`).
