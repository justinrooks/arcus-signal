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

For broad database-backed validation, point `DATABASE_NAME` or `DATABASE_URL` at a dedicated test database and run `tools/test_lane.sh --full --no-parallel`. Avoid using the shared default `arcus_signal` database for concurrent or repeated full-suite runs. If a test lane stalls, treat it as incomplete, preserve its logs, and inspect PostgreSQL activity (queries and locks) before attributing the stall to a particular test. If PostgreSQL activity cannot be inspected, report that as a diagnostic limitation.

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

### Docker runtime dependencies

- When adding a Swift import or package that uses a native shared library,
  update the final runtime stage of `Dockerfile` with the required OS package.
  `--static-swift-stdlib` does not make the entire executable self-contained.
- `FoundationXML` requires the runtime package `libxml2`
  (`libxml2.so.2`). Keep it installed while SPC parsing uses FoundationXML.
- For dependency changes, inspect `ldd` output for both `Run` and `RunWorker`
  inside the final runtime image and confirm no libraries are reported as
  `not found`. Verify executable startup in that image; success in the Swift
  build image alone is insufficient.

<!-- trail:start -->
## Trail — repo context graph

This repo is indexed in `graft/`: small linked markdown nodes that explain each
system and carry exact file:line spans, kept in sync with the code through git.

For ANY task here — understanding how something works, finding where code lives,
or scoping a change — get context from the graph before grepping or opening
source files. Re-ask freely (it's cheap) and reuse literal identifiers you
already have (symbol, error string, file name) as the query. New to this repo?
Run `trail map` first — a token-budgeted orientation (dir clusters, hubs,
hotspots), no LLM, no key.

- Run `trail ask "<your question>" --source` → ranked nodes with the relevant
  code spans inlined (each hit's ≤8-line crux by default; `--full` for whole
  definitions when the crux isn't enough). Match the tool to the task shape:
  for understanding or editing, the top node IS the answer — cite its
  `covers:` file:line spans and edit straight from `--source`. For
  exhaustive tasks ("every occurrence / every caller of this pattern"), ranked
  results are top-N, not complete — run `trail grep "<literal>"` instead
  (exhaustive over indexed files, grouped by enclosing symbol), falling back
  to raw `grep -rn` only for unindexed files.
- `trail skeleton <file>` → every definition's signature + span, ~10× cheaper
  than reading the file; use it to skim an API surface.
- `trail callers <symbol>` gives precomputed, exact edges — who calls this.
  Add `--direction out` for what it calls, or `--depth N` to walk
  transitively for the full blast radius. For structural questions, skip
  ranking and use this directly.
- Or browse: `graft/INDEX.md` lists every node; follow the links.
- Monorepos and folders of multiple repos rank fairly across sub-projects —
  hits carry `[scope/]` labels naming which one they're from. Narrow with
  `trail ask "<task>" --in <scope>/` once you know where you're working.

If a returned span is truncated ("+N more lines"), open the file at that exact
range before finalizing. Only open source files when a node genuinely lacks a
needed detail, and then at the exact file:line the node points to — never
re-read whole files.

After big code changes, refresh the graph with `trail build` (deterministic,
no API key, $0).
<!-- trail:end -->
