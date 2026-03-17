# Arcus Signal Agent Guide

## Project Overview

Arcus Signal is the server backend for SkyAware / Project Arcus. Its v1 mission is to send timely, location-targeted APNs alerts for:

- NWS watches/warnings (TOR, SVR, FF)
- SPC Mesoscale Discussions (next ingestion step after NWS stub)

The backend is intentionally split into two runtime roles:

- `Run` (`api` container): HTTP endpoints and enqueue-only behavior
- `RunWorker` (`worker` container): queue workers, ingestion scheduler, targeting, and APNs delivery pipeline

This solution is implemented with Vapor. For all feature work, architecture changes, and operational behavior, default to official Vapor documentation and Vapor best practices.

## Arcus Signal — Canonical Specs
Before making changes, read:
- docs/architecture.md
- docs/epics-stories.md

Treat these as the source of truth for:
- pipeline flow (ingest → target → outbox → send)
- DB invariants (exactly-once via unique constraints)
- notification content composition (compose at outbox insert time)
- queue lanes and concurrency caps

## Working agreements
- Prefer idempotent jobs and DB-enforced uniqueness.
- Never send APNs directly from targeting; write to outbox.
- Do not introduce server-side lat/lon storage unless explicitly requested.
- Keep solutions, code, and suggestions as simple as possible. We are iterating and building
- Don't over engineer, over architect, or over design solutions or suggestions.

## Key Architecture Decisions

- Two executables, one shared `App` module.
- Queue-backed background processing via Vapor `Queues` + Redis backend.
- Shared relational persistence via Vapor Fluent + PostgreSQL for both runtime roles.
- `REDIS_URL` is the canonical queue backend config. No silent non-dev fallback.
- `DATABASE_URL` is the canonical Postgres config. No silent non-dev fallback.
- Worker-only Vapor Queues scheduled job dispatches ingestion jobs every 60 seconds.
- Health endpoints are separate per process (`GET /health`).
- API never sends APNs directly. Push delivery stays worker-owned.

## Conventions and Patterns

- Thin entrypoints in `Sources/Run` and `Sources/RunWorker`.
- Shared wiring in `Sources/App`.
- Protocol-based services for dependency injection and testability (example: `NWSIngestService`).
- Queue jobs are idempotent and log start/end/error.
- Keep environment-driven configuration explicit and fail fast for production-like runs.
- Worker queue concurrency is explicit (`QUEUE_WORKER_COUNT`, default `1`).
- Redis queue pool size is explicit (`REDIS_POOL_MAX_CONNECTIONS`, default `8`).
- Redis pool lease timeout is explicit (`REDIS_POOL_CONNECTION_TIMEOUT_SECONDS`, default `30`).
- Worker startup grace is explicit (`WORKER_STARTUP_GRACE_SECONDS`, default `5`).
- Dev/testing Postgres fallback knobs are explicit (`DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `DATABASE_NAME`).

## Build and Run

### SwiftPM

```bash
swift build
swift run Run serve --hostname 0.0.0.0 --port 8080
swift run RunWorker serve --hostname 0.0.0.0 --port 8081
swift test
```

### Docker Compose

```bash
docker compose up --build
```

Expected ports:

- API: `8080`
- Worker health: `8081`
- Redis: `6379`
- Postgres: `5432`

## Quirks and Gotchas

- Worker scheduler and queue consumers are intentionally started only in `RunWorker`.
- `RunWorker` still binds HTTP for health checks, but should expose only internal/ops endpoints.
- In `development`/`testing`, queue config defaults to `redis://127.0.0.1:6379` with a warning when `REDIS_URL` is absent.
- In `development`/`testing`, DB config defaults to local Postgres values with a warning when `DATABASE_URL` is absent.
- In non-dev environments, missing `REDIS_URL` is an immediate startup failure.
- In non-dev environments, missing `DATABASE_URL` is an immediate startup failure.
