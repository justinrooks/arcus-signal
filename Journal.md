# Arcus Signal Journal

## 1) The Big Picture

Imagine a weather-savvy friend who texts you before the sky gets weird. Arcus Signal is that friend, but automated and fast. It watches authoritative weather feeds, figures out who is in the risk zone, and triggers APNs notifications before users are caught off guard.

This service is the “dispatch center” behind SkyAware: take signal in, match signal to location, send only what matters.

## 2) Architecture Deep Dive

Think of the system like a restaurant with a front desk and a kitchen:

- `Run` (API) is the host stand. It greets requests, takes orders, and passes tickets to the kitchen.
- `RunWorker` is the kitchen line. It does the real cooking: ingest feeds, compute geospatial candidates, match presence, build push payloads, and send APNs.
- Redis is the ticket rail between host and kitchen.

The key rule: hosts do not cook, cooks do not seat guests. This keeps latency-sensitive HTTP work isolated from heavy background processing.

## 3) The Codebase Map

- `Sources/App/`: shared infrastructure and domain wiring
- `Sources/App/configure.swift`: runtime mode setup (`api` vs `worker`)
- `Sources/App/Services/`: protocol-based service layer (`NWSIngestService`)
- `Sources/App/Jobs/`: queued jobs (`IngestNWSAlertsJob`)
- `Sources/App/Worker/`: worker lifecycle startup and scheduler bootstrap
- `Sources/Run/main.swift`: API executable entrypoint
- `Sources/RunWorker/main.swift`: worker executable entrypoint
- `Tests/AppTests/`: bootstrap route tests
- `docker-compose.yml`: local orchestration (`api`, `worker`, `redis`)

## 4) Tech Stack & Why

- **Vapor**: fast Swift server framework with clean lifecycle hooks.
- **Queues + queues-redis-driver**: battle-tested async job model with Redis-compatible backend support.
- **Redis**: local queue backend and canonical protocol target for production parity.
- **Docker Compose**: cheapest path to reproducible local multi-process behavior.

Why this combo? It gives us production-like process boundaries now, without overcommitting to expensive infra too early.

## 5) The Journey

### Milestone: Dual-runtime bootstrap (today)

- Replaced default single Vapor executable with:
  - shared `App` module
  - `Run` executable (API)
  - `RunWorker` executable (worker)
- Added queue backend config via `REDIS_URL`.
- Added explicit fail-fast behavior in non-dev when `REDIS_URL` is missing.
- Added scheduled ingestion dispatching of `IngestNWSAlertsJob` every 60 seconds.
- Added `IngestNWSAlertsJob` skeleton calling a DI-backed `NWSIngestService` stub.
- Added `/health` endpoints for both API and worker processes.
- Updated Docker image and compose wiring for `api` + `worker` + `redis`.

### Milestone: Switched local queue backend image to plain Redis

- Replaced local Compose service `valkey` with `redis` (`redis:7-alpine`).
- Updated default `REDIS_URL` in Compose to `redis://redis:6379`.
- Standardized docs and runbooks on Redis naming to reduce environment confusion.

### Bug squash: transient Redis pool timeouts at worker boot

- Symptom: a few startup logs of `timedOutWaitingForConnection`, followed by normal job processing.
- Root cause: queue worker default concurrency can exceed RediStack's default pool size (`2`), especially during boot churn.
- Deeper gotcha: passing `nil` for pool `connectionRetryTimeout` in RediStack maps to a tiny fallback timeout (`10ms`), not the documented default.
- Fix: made both knobs explicit:
  - `QUEUE_WORKER_COUNT` default `1` for deterministic local behavior.
  - `REDIS_POOL_MAX_CONNECTIONS` default `8` to avoid lease starvation.
  - `REDIS_POOL_CONNECTION_TIMEOUT_SECONDS` default `30` to avoid ultra-short lease timeouts.
- Added a startup grace period before worker consumers begin (`WORKER_STARTUP_GRACE_SECONDS`, default `5`), so Redis has time to settle before the first lease attempts.

### Architecture alignment: adopted Vapor Queues scheduler primitives

- Replaced custom scheduler `Task` loop with an `AsyncScheduledJob`.
- Registered schedule via `app.queues.schedule(...).minutely().at(0)`.
- Worker runtime now starts both in-process jobs and scheduled jobs with `startInProcessJobs()` + `startScheduledJobs()`.
- Centralized queue tuning env defaults in `docker-compose.yml` for reproducible local worker behavior.
- If delayed startup still fails, worker now logs critical and shuts down instead of staying half-alive.
- Net effect: scheduling now follows documented Queues behavior and lifecycle.

### Aha moments

- Splitting runtime roles early prevents “just this once” logic leaks where APIs start doing worker jobs.
- Health endpoints on worker are operational gold; you get liveness checks without exposing product routes.

### Pitfalls spotted

- Silent queue fallback in production-like environments is dangerous; jobs appear “working” locally but vanish in deployed setups.
- Running worker logic inside API process makes scaling and incident debugging much harder later.

## 6) Engineer's Wisdom

- Keep boundaries strict: APIs should enqueue, workers should process.
- Prefer protocol-backed services in app storage for fast testing and easy future swaps.
- Make idempotency a job contract from day one; retries are inevitable.
- Fail configuration loudly when correctness depends on external systems.

## 7) If I Were Starting Over...

- I would create dual executables on day zero instead of evolving from a single-process scaffold.
- I would define structured event IDs and dedupe keys earlier to make idempotency observable from the first ingest.
- I would add a tiny integration test harness that boots Redis + worker in CI sooner, before real upstream feed parsing lands.
