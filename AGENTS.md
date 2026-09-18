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

Treat `docs/architecture.md` as the living source of truth. `docs/epics-stories.md` is a historical planning artifact; preserve it as a record, but do not treat its stored-payload, retry, or exactly-once language as the production contract.

Use the living architecture document for:
- pipeline flow (ingest → target → outbox → send)
- DB invariants (including the per-installation, at-most-one ledger claim boundary)
- notification content composition (compose candidate-specific copy after a successful ledger claim, at send time)
- queue lanes and concurrency caps

## Working agreements
- Prefer idempotent jobs and DB-enforced uniqueness.
- Never send APNs directly from targeting; write to outbox.
- Do not introduce server-side lat/lon storage unless explicitly requested.
- Keep solutions, code, and suggestions as simple as possible. We are iterating and building
- Don't over engineer, over architect, or over design solutions or suggestions.

## Arcus-Signal Slice Boundaries

For Vapor server work, prefer slices around one of:
- One route behavior.
- One service method.
- One DTO or decoding path.
- One persistence query/model interaction.
- One notification/update workflow.
- One parser/classifier/scoring behavior.
- One focused test suite.

Stop before mixing route changes, persistence changes, notification behavior, and refactors in the same pass unless explicitly requested.

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

<!-- graft:start -->
## Graft — Repository Context

Arcus-Signal has a local structural context graph under `graft/`. Use Graft as a navigation and impact-analysis aid, not as a source of truth.

For intended system behavior and architectural invariants, follow `docs/architecture.md`. For actual runtime behavior, verify the relevant implementation and focused tests.

### When to use Graft

Use Graft when a task is unfamiliar, cross-cutting, or requires tracing relationships across multiple files, especially:

* ingest → persistence → targeting → notification flows
* queue and outbox orchestration
* model/revision relationships
* notification routing and delivery
* locating ownership of an unfamiliar behavior
* determining callers, dependencies, or blast radius before a change

For a small task with a known file, symbol, or focused slice, go directly to the relevant source and tests. Do not add a Graft query merely because Graft is available.

### Recommended workflow

Start broad only when necessary:

`graft ask "<question>" --source`

Treat the results as ranked leads. Identify the likely architectural spine, then verify the important behavior in the referenced source and tests.

Prefer a small number of targeted follow-up queries over repeatedly rephrasing the same question.

Use:

* `graft callers <symbol>` for callers and dependency/blast-radius questions.
* `graft callers <symbol> --direction out` for dependencies used by a symbol.
* `graft skeleton <file>` when only a file's API surface is needed.
* `graft grep "<pattern>"` when every indexed occurrence matters.
* normal repository search for unindexed content, documentation, configuration, or when a direct literal search is simpler.

Use `--full` only when the normal source excerpts do not contain enough context. Otherwise prefer the smaller default spans.

### Verification

Do not treat a Graft result, generated summary, or top-ranked node as authoritative by itself.

Before changing production behavior:

1. verify the relevant implementation;
2. inspect focused tests covering the behavior;
3. check `docs/architecture.md` when an architectural invariant or pipeline boundary is involved.

Open as much surrounding source as needed to understand invariants, error handling, transaction boundaries, concurrency, or lifecycle behavior. Token savings are useful, but correctness comes first.

### Keeping the graph current

Graft queries normally refresh the structural graph against working-tree changes automatically.

Use `graft check` when graph freshness is in doubt. Run `graft build` manually only when the graph needs rebuilding or troubleshooting; do not rebuild reflexively after every edit.

<!-- graft:end -->
