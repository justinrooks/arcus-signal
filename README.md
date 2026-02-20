# Arcus Signal

Arcus Signal is the notification backend for Project Arcus / SkyAware. It runs as two Vapor executables:

- `Run`: API process for HTTP endpoints
- `RunWorker`: worker process for queue consumption + ingestion scheduling

## Local SwiftPM

```bash
swift build
swift run Run serve --hostname 0.0.0.0 --port 8080
swift run RunWorker serve --hostname 0.0.0.0 --port 8081
swift test
```

`REDIS_URL` is required outside development/testing environments.
Optional tuning:

- `QUEUE_WORKER_COUNT` (default `1` for worker runtime)
- `REDIS_POOL_MAX_CONNECTIONS` (default `8`)
- `REDIS_POOL_CONNECTION_TIMEOUT_SECONDS` (default `30`)
- `WORKER_STARTUP_GRACE_SECONDS` (default `5`)

## Docker Compose

```bash
docker compose up --build
```

Compose sets defaults for queue tuning env vars (`QUEUE_WORKER_COUNT`, `REDIS_POOL_MAX_CONNECTIONS`, `REDIS_POOL_CONNECTION_TIMEOUT_SECONDS`, `WORKER_STARTUP_GRACE_SECONDS`).

Services:

- `api` on `:8080` (`GET /health`)
- `worker` on `:8081` (`GET /health`)
- `redis` on `:6379`

The worker uses Vapor Queues scheduled jobs to dispatch `IngestNWSAlertsJob` every 60 seconds (`minutely().at(0)`).
