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
- `docker-compose.yml`: local orchestration (`api`, `worker`, `redis`, `postgres`)

## 4) Tech Stack & Why

- **Vapor**: fast Swift server framework with clean lifecycle hooks.
- **Queues + queues-redis-driver**: battle-tested async job model with Redis-compatible backend support.
- **Redis**: local queue backend and canonical protocol target for production parity.
- **Fluent + PostgreSQL**: relational storage layer shared by API and worker with Vapor-native database configuration.
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

### Milestone: Postgres wiring for both runtime roles

- Added Vapor Fluent + Fluent PostgreSQL driver dependencies to shared `App` target.
- Added shared database bootstrap in `configure.swift` so both `Run` and `RunWorker` register Postgres the same way.
- Standardized on `DATABASE_URL` as the canonical production/staging config.
- Added development/testing fallback knobs:
  - `DATABASE_HOST` (`127.0.0.1`)
  - `DATABASE_PORT` (`5432`)
  - `DATABASE_USERNAME` (`arcus`)
  - `DATABASE_PASSWORD` (`arcus`)
  - `DATABASE_NAME` (`arcus_signal`)
- Updated Compose with a `postgres:16-alpine` service, healthcheck, persistent volume, and dependency gating for both API and worker.

War story: this is one of those “it works on one process” traps. If API and worker don’t share identical DB wiring, you get ghost bugs where one process can read state the other never wrote. Centralizing DB config in shared `App` avoids that split-brain class of failure.

### Bug squash: GeoJSON coordinate shape mismatch in NWS alert decoding

- Symptom: ingest failed with `Expected to decode Double but found an array instead` at `features[18].geometry.coordinates[0]`.
- Root cause: `NWSGeometryDTO.coordinates` was modeled as `[Double]`, which only fits `Point` geometry. NWS can return nested arrays for `Polygon` and `MultiPolygon`.
- Fix: replaced `[Double]` with a recursive `NWSCoordinatesDTO` (`number` or nested `array`) so any GeoJSON numeric nesting depth decodes cleanly.
- Added regression tests for both `Point` and `Polygon` coordinate payloads.

War story: this was the classic “one sample lied to us” bug. The first payload looked like a neat `[lon, lat]`, so the model felt obvious. Then the real world showed up with polygons and reminded us that GeoJSON is a shape family, not a single tuple.

### Milestone: Canonical ArcusEvent + NWS mapper landed

- Brought `ArcusEvent` online as an active canonical model (no longer commented scaffolding).
- Kept `NwsEventJson` as an ingest DTO and added explicit mapper boundaries:
  - `NwsEventFeatureDTO.toArcusEvent(...)`
  - `NwsEventJson.toArcusEvents(...)`
- Added normalization rules so downstream logic gets stable enums instead of source-specific strings:
  - event kind (`Tornado Warning` -> `torWarning`, etc.)
  - status (`expires/ends` compared to now)
  - severity/urgency/certainty normalization
- Added geometry conversion from decoded NWS coordinates to canonical `GeoShape` (`point`, `polygon`, `multiPolygon`).
- Preserved NWS `geocode.UGC` on canonical events (`ArcusEvent.ugcCodes`) so zone-level targeting and lookups can run without re-reading raw DTO payloads.
- Updated ingest job to map decoded payloads into canonical events and log feature/event counts.

War story: this is the “airport baggage claim” moment for data models. NWS JSON is the luggage tag from one airline. ArcusEvent is the standardized suitcase conveyor every downstream system uses. If we skip that normalization belt, every consumer becomes its own custom baggage handler and mistakes multiply.

### Milestone: Fluent persistence scaffold for ArcusEvent

- Added `ArcusEventModel` as a Fluent `Model` (`arcus_events` schema) with explicit field mapping for canonical event data.
- Added `CreateArcusEventModel` async migration with a unique constraint on (`event_key`, `revision`) for revision-safe persistence.
- Registered migrations in app configuration so both API and worker runtimes know about the schema.
- Added domain/persistence mapping helpers:
  - `ArcusEventModel.init(from: ArcusEvent)`
  - `ArcusEventModel.asDomain()`
- Preserved complex shape data (`GeoShape`) by encoding/decoding JSON in `geometry_json`, and preserved `ugcCodes` as a first-class persisted array field.

War story: ORMs are like shipping containers. If you stuff domain objects directly into them without labeling and boundaries, you get customs problems later. A separate canonical model + persistence model keeps border control clean.

### Milestone: Networking stack moved to Vapor client primitives

- Replaced custom `URLSession` transport with a Vapor-native HTTP transport (`VaporApplicationHTTPClient`) so outbound requests run through Vapor's client lifecycle and connection handling.
- Kept the app's protocol boundary (`HTTPClient`) and status classification logic, but swapped the concrete engine under it.
- Updated NWS ingest wiring to construct the HTTP client from `QueueContext.application`, which keeps worker jobs aligned with app runtime configuration.
- Removed server-side `UserDefaults` persistence from network observer behavior and kept observer state in-memory for process-local telemetry only.

War story: this was a good reminder that server apps are airports, not notebooks. Local sticky notes (`UserDefaults`) feel convenient, but in distributed systems they turn into conflicting gate announcements.

### Milestone: Logging stack aligned to Vapor/SwiftLog

- Removed `OSLog` usage from server networking code and standardized on SwiftLog (`Logging.Logger`) so logs flow through Vapor's configured logging pipeline.
- Reworked logger categories to use logger metadata (`category`) instead of Apple-platform subsystem/category APIs.
- Updated NWS client logging to structured metadata fields (`endpoint`, `status`, `retryAfterSeconds`, etc.) for cleaner filtering and ingestion downstream.

War story: mixed logging stacks are like speaking half in English and half in radio code on the same ops channel. Everyone hears something, but nobody gets the full message quickly during an incident.

### Bug squash: Vapor contract cleanup + Linux safety pass

- Fixed API health response contract to return `"ok"` so it matches bootstrap test expectations.
- Refactored `NWSIngestService` into the actual ingest boundary and moved job execution to call service-first, keeping job responsibilities focused on persistence.
- Replaced `fatalError` on missing ingest service registration with a logged critical + thrown service error path.
- Hardened ingest persistence against worker concurrency collisions by handling unique-constraint conflicts and converting them into update behavior.
- Removed timezone force unwraps in SPC date parsing (`CDT`/`CST`) with a UTC fallback to avoid platform-specific crashes.

War story: this was the “small paper cuts” sprint. None of the issues alone looked dramatic, but together they defined whether the app behaves like a server in production or a demo on one laptop.

### Bug squash: upsert duplicate-key noise in recurring ingest

- Symptom: periodic worker runs logged Postgres `23505` unique violations on (`event_key`, `revision`) during normal ingest cycles.
- Root cause: ingest persistence used insert-first behavior, so existing rows generated conflict errors before reconciliation.
- Fix: switched to query-first upsert flow (update when present, insert only when missing) and kept a unique-violation fallback path only for real cross-worker race conditions.

War story: this one looked like a race at first glance, but it was mostly a strategy mismatch. If you know most rows already exist, asking Postgres to "fail then recover" every minute just creates noise and masks real incidents.

### Optimization: reduced per-event DB round trips in ingest upsert

- Replaced per-event existence checks with one batched prefetch for known event keys/revisions.
- Added in-memory indexing by (`event_key`, `revision`) so each incoming event can decide update/insert without extra lookup queries.
- Added no-op detection so unchanged rows are not updated, reducing unnecessary write churn during recurring ingests.
- Kept a unique-constraint fallback path for true multi-worker insert races.

War story: when the feed repeats mostly unchanged data, "always update" is like repainting the same wall every minute. It looks busy, but it's mostly wasted effort.

### Milestone: ingestion flow hardened for dedupe + update reliability

- Refactored ingest persistence into explicit phases: dedupe incoming events, upsert changes, then mark expired rows.
- Added deterministic dedupe behavior keyed by `event_key` with "latest duplicate wins" semantics.
- Added transaction-wrapped persistence for each ingest run so counts and state changes are coherent per run.
- Added richer run metrics (`inserted`, `updated`, `unchanged`, `duplicatesIgnored`, `expiredMarked`) to make ingestion behavior observable in logs.
- Added unit coverage for dedupe semantics so duplicate handling is tested independent of external feeds.

War story: this is the "assembly line" upgrade. When each stage has one job and clear counters, incidents stop feeling like guesswork and start feeling like accounting.

### Milestone: hash-based change detection + revision bumps

- Added persisted `content_hash` on `arcus_events` and compute it from canonical event payload fields.
- Switched update detection to compare `content_hash` values, so duplicates are clearly identified as "same payload" instead of field-by-field guesswork.
- Treat `revision` as a server-owned version counter: inserts start at 1, and updates bump revision only when payload hash changes.
- Updated ingest identity matching to use `event_key` as the canonical key for "same alert, newer info."

War story: this is the "fingerprint scanner" moment. Instead of asking a dozen questions to see if two events are the same, you compare fingerprints and move on.

### Milestone: explicit ingest hooks for notification handoff points

- Added explicit hook logs for:
  - event created
  - event updated
  - event ended
- Standardized hook message prefixes so downstream orchestration can grep/filter reliably during bring-up.
- Included metadata (event key, revisions, reason, ended timestamp) so future notification jobs can consume context without another DB query for basics.

### Milestone: Story 1.4 queue handoff (ingest -> target) landed

- Added explicit queue lane constants (`ingest`, `target`, `send`) so dispatch and workers no longer rely on the anonymous default queue.
- Added `TargetEventRevisionJob` as a stub worker contract with `eventKey + revision` payload, giving us a concrete queue handoff surface before targeting logic is implemented.
- Updated scheduler dispatch to enqueue ingest work onto the `ingest` lane.
- Updated ingest persistence summary to collect and dispatch `TargetEventRevision` payloads when revisions are:
  - newly created and active, or
  - updated with changed content and still active.
- Updated worker runtime startup to watch named lanes instead of only `.default`.
- Added tests for:
  - scheduler dispatch routing to `ingest` lane
  - dispatch gating policy (`changed && active`) for the temporary pre-`is_notifiable` phase.

War story: this is the "conveyor belt labels" bug class. Jobs were moving, but all on the same unlabeled belt (`default`). It works until throughput grows, then debugging turns into "which worker consumed what?" chaos. Naming lanes early is cheap and saves incident time later.

### Milestone: persisted expiration flag for lifecycle filtering

- Added `is_expired` to persisted Arcus events so queries can quickly filter active vs expired alerts without recomputing at read time.
- Expiration is computed during ingest using a single run timestamp (`asOf`) for consistency across all events in one job execution.
- Added a migration to add `is_expired` so future purge jobs can query expired rows directly.
- Added a post-upsert expiration backfill step: rows already in DB with `expires_at <= asOf` are marked `is_expired = true` even if they are absent from the latest `/alerts/active` payload.

War story: this is one of those small schema choices that pays rent forever. "Can we purge old alerts?" goes from a full-table scan problem to an indexed query.

### Milestone: supersession-aware ingest flow for NWS update messages

- Updated ingest identity semantics so `event_key` now tracks the **current NWS message id** (not the original feature id).
- Added a lineage resolver that groups messages into one chain when an incoming message references prior message ids in `references`.
- Collapsed each run to a single winner per lineage (latest superseding message), so we persist one final state and avoid noisy intermediate writes.
- Updated status rules:
  - `Cancel` messages end the event immediately.
  - `ends` is treated as lifecycle end.
  - `expires` is no longer used as an automatic end signal.
- Tightened revision bumps to tracked property changes only by removing message-identity fields from the content hash.

War story: this was a classic "label mismatch" bug. We were grouping by the envelope id while NOAA was shipping updates in brand-new envelopes every time. Once we switched to supersession chains, the ingest line stopped treating updates like strangers.

### Milestone: geometry storage moved to JSONB-ready schema

- Added a forward migration to append `geometry` to `arcus_series` using Fluent `.dictionary` (Postgres `JSONB`).
- Added a Postgres GIN index on `arcus_series.geometry` so future structured queries can stay fast.
- Registered the migration in shared app bootstrap so API and worker runtimes stay schema-aligned.

War story: storing geometry as plain text felt simple until we asked future-us to query pieces of it. JSONB is the difference between "read a sentence" and "ask the database a precise question."

### Milestone: content fingerprinting hardened for deterministic persistence

- Made `ArcusEvent.computeContentFingerprint()` throwing so encoding failures cannot silently persist a placeholder hash.
- Canonicalized fingerprint inputs:
  - UGC codes are now trimmed, uppercased, de-duplicated, and sorted before hashing.
  - `title` and `areaDesc` are trimmed so incidental whitespace does not create false deltas.
- Switched the fingerprint payload from derived `state` to `messageType` to reduce time-sensitive hash drift.
- Added a migration to strengthen DB integrity for `content_fingerprint`:
  - dropped the empty-string default
  - added a lowercase SHA-256 format check constraint (`NOT VALID` for safe rollout)
  - added an index for future lookup workflows.

War story: a hash is only useful if it's boringly predictable. If one bad encode path can write "encoding failed," you've built a random-number generator with extra steps.

### Milestone: durable ingest -> target handoff with outbox

- Replaced direct in-memory target dispatch handoff with a durable outbox table (`target_dispatch_outbox`).
- Ingest now writes outbox rows in the same DB transaction as revision/series persistence, keyed by `revision_urn` for idempotency.
- Added an outbox drain step after commit:
  - dispatches pending rows to the `target` queue lane
  - marks successes with `dispatched` timestamp
  - records `attempt_count` + `last_error` on failures for retry/audit
- This closes the "DB commit succeeded but queue publish failed" gap where retries previously skipped dispatch due revision dedupe.

War story: this is the distributed-systems version of mailing a package after you shred the receipt. If the courier fails and you already forgot what you mailed, recovery is guesswork. Outbox keeps the receipt until delivery is confirmed.

### Milestone: multi-reference series merge now resolves to freshest lineage

- Updated merge winner selection for multi-reference events to pick the series with the most recent `current_revision_sent` (deterministic tie-break by UUID).
- Added full alias consolidation when multiple series are referenced:
  - move all revision rows to the winner series
  - move pending outbox rows to winner and rewrite payload `seriesId`
  - consolidate geolocation row ownership under winner and prune extras
  - tombstone loser series to preserve historical references without dangling lookups

War story: this one is like merging duplicate customer profiles. If you pick the winner by random UUID, you might keep the stale profile and archive the one with the latest address. Freshness-first avoids that subtle but expensive drift.

### Milestone: APNs secrets moved to worker-only mounted key + env identifiers

- Moved APNs bootstrap from global app setup to worker-only setup so the API process never receives push credentials.
- Switched APNs key handling to file-based loading via `APNS_PRIVATE_KEY_PATH` (mounted `.p8`), with `APNS_KEY_ID` and `APNS_TEAM_ID` loaded from env vars.
- Hardened startup policy:
  - `development` / `testing`: warn and disable APNs when config is missing/invalid.
  - non-dev envs (including `production`): fail fast on missing/invalid APNs config.
- Updated local Compose wiring to mount `.p8` into `worker` only and keep API container clean of APNs secrets.

War story: this was the "don’t hand the restaurant host the safe combination" fix. The host stand (`Run`) only needs reservation data. The kitchen (`RunWorker`) is the only place that should touch the expensive ingredients and the lockbox key.

### Bug squash: installation ID type mismatch (String vs UUID) in notification ledger path

- Standardized `installation_id` to UUID end-to-end:
  - device installation model
  - device presence model
  - notification ledger model
  - API payload decoding and upsert path
  - create-table migrations
- Added an explicit conversion migration to cast existing `installation_id` values from `text` to `uuid` with FK constraints dropped/recreated in the right order.

War story: this was a "same idea, two dialects" failure. Part of the code treated IDs like plain strings, another part treated them like UUIDs, and Postgres was the strict language teacher refusing to translate automatically. We fixed it by making the entire stack speak UUID natively.

### Milestone: notification outbox now respects delayed readiness

- Fixed `dispatchPendingNotificationJobs` to honor `available_at <= now` before dispatching send-lane jobs.
- Added deterministic drain ordering by `available_at` first, then `created`, so older ready rows are processed first.
- This aligns notification outbox semantics with its own schema contract (`available_at` exists for backoff/delayed readiness) and prevents premature dispatch.

War story: this was a "restaurant buzzer" bug. We had a queue of tables and a buzzer time, but the host kept seating people before their buzzer went off. It works until retries/backoff show up, then ordering turns into chaos.

### Bug squash: preserve notification reason through outbox and H3 handoff

- Carried `reason` end-to-end through the H3 path:
  - added `reason` to `TargetEventRevisionPayload`
  - propagated `reason` from ingest queueing into target outbox payload
  - consumed payload `reason` in `TargetEventRevisionJob` instead of hardcoding `.new`
- Added backward-compatible decoding for older target outbox payload rows that predate `reason` by defaulting missing values to `.new`.
- Hardened `AddReasonToNotificationOutbox` migration for existing data:
  - add column as nullable first
  - backfill existing rows with `'new'`
  - then enforce `NOT NULL` + default.

War story: this one was like sending food tickets from host stand to kitchen but dropping the “allergy note” on transfer. The dish still arrives, but not the right one. We fixed the handoff so intent survives every station.

### Bug squash: migration ordering for `installation_id` UUID conversion

- Hit a migration-time FK error where `notification_ledger.installation_id` was `uuid` but `device_installations.installation_id` was still `text` on older databases.
- Fixed by moving `ConvertInstallationIDsToUUID` to run before `CreateNotificationLedger` in migration registration order.
- Hardened the conversion migration so it conditionally handles `notification_ledger` only when that table exists (works both pre- and post-ledger creation states).

War story: this was a train-switch bug. We changed the track gauge (text -> UUID) but one station was still on old rails when the next train (new FK) arrived. Reordering the switch and making it context-aware fixed the derailment.

### Bug squash: APNs environment routing now follows each installation record

- Found a mixed-environment delivery bug in the new notification send path: candidate selection only returned token + installation ID, and APNs sends picked `.development`/`.production` based on process env, not per-device `apns_environment`.
- Updated candidate queries to include `apns_environment` and route each send to the matching APNs container (`sandbox -> development`, `prod -> production`).
- Tightened candidate filters to skip inactive installs and empty tokens before attempting ledger claims/sends.

War story: this was shipping-label roulette. The package (token) was right, but we were choosing the destination hub from the warehouse sign instead of the label on the box. Works in single-hub tests, breaks in mixed traffic.

### Milestone: deterministic notification engine now speaks in one voice

- Rebuilt `NotificationEngine` as a pure formatter with no extra lookups, no hidden state, and no new inputs.
- The engine now derives three things in a predictable order:
  - event display name
  - location subtitle (`your location`, county label, fire-zone label, or `your area`)
  - body copy based on alert kind + severity tone + notification reason
- Added stable wording paths for:
  - `new`
  - `update`
  - `endedAllClear`
  - `cancelInError`
- Kept the design intentionally conservative:
  - H3 notifications say `At your location`
  - UGC notifications prefer the best existing human label already on the candidate
  - updates are generic-but-clear because we do **not** yet have change flags or proximity detail in this path
- Added focused formatter tests for tornado, watch, fire-zone, cancellation, and generic-fallback cases.

War story: notification copy is like cockpit instrumentation. If every dial uses a different language, the pilot wastes precious seconds translating instead of reacting. The fix was not "be more clever." The fix was "be boringly consistent, every single time."

### Gotcha: raw SQL -> Fluent model decoding wants database field keys, not Swift property names

- Added a reusable `ArcusSeriesModel.sqlSelectColumns(...)` helper for joined/raw SQL paths.
- Key lesson: when decoding a Fluent `Model` from `sql.raw(...)`, the row must expose database column names like `source_url`, `current_revision_urn`, and `ugc_codes`.
- Translation: this is not normal `Codable` land. Fluent is reading the luggage tags on the database columns, not the nicer names on the Swift suitcases.
- Follow-on lesson: `ArcusEvent` is the opposite case. Its raw SQL projection aliases into Swift DTO keys like `sourceURL`, `lastSeenActive`, and `ugcCodes`, and it synthesizes non-persisted fields like `references` so plain `Codable` decoding has a complete payload.

### Bug squash: alerts lookup route stopped fighting both Vapor and SQL

- Replaced the half-built `alerts.get` query-builder experiment with a dedicated lookup path that does what the route actually wants: fetch active alerts matching any provided UGC code or H3 cell.
- Switched from unsafe string interpolation to bound SQL parameters, which means the endpoint now stops treating query strings like trusted house guests.
- Used `LEFT JOIN` for geolocation so UGC-only alerts still show up even when there is no geometry row.
- Joined the current revision row as well, so the API DTO can return real `references` instead of an empty stand-in.

### Architecture cleanup: one stable hashing primitive instead of several cousins

- Extracted the sorted-keys SHA256 logic into a shared `StableContentHasher`.
- Wired `ArcusEvent` content fingerprinting and target-job geometry hashing through the same helper so cache and change-detection rules stop drifting apart.
- Used that same primitive to build the alerts collection ETag from `(id, currentRevisionUrn, contentFingerprint)`, which keeps the device refresh path cheap without stuffing cache-only fields into the device payload.

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
- Use one canonical env var per infra dependency (`DATABASE_URL`, `REDIS_URL`) and keep fallback behavior explicitly scoped to dev/testing.

## 7) If I Were Starting Over...

- I would create dual executables on day zero instead of evolving from a single-process scaffold.
- I would define structured event IDs and dedupe keys earlier to make idempotency observable from the first ingest.
- I would add a tiny integration test harness that boots Redis + worker in CI sooner, before real upstream feed parsing lands.
