# Changelog

## v1.5.0

### Features

- Device writes now support authenticated v2 installation enrollment, while v3 consent revisions are ordered and permanently fenced against downgrade; v3 meso ownership requires usable accepted presence.
<!-- evidence: 24f3f87, f8efe0e, 3b69ae2 -->

### Reliability

- NWS outbox handoffs can be recovered without fresh weather, and dispatch diagnostics expose expired notification leases and failed queue handoffs.
<!-- evidence: b01a7e0, 5df90b5 -->
- Invalid NWS collection envelopes are rejected before ingestion, and meso feature gates are checked explicitly throughout release operations.
<!-- evidence: ffdbdeb, c4f5ee2 -->
- Storm Setup surface cache reclamation coordinates readers and publishers, while the AirNow current cache bounds residency and performs expiry cleanup.
<!-- evidence: d415c0e, 237a6f5 -->

### Operations

- The operator dashboard aligns targetable coverage with location-sharing consent.
<!-- evidence: 31eed26 -->

## v1.4.2

### Features

- Added a guarded development-only `POST /v1/dev/notification-test` flow that creates short-lived synthetic `TEST` SPC discussions from resolution-8 H3 cells and can hand accepted fixtures to the existing notification pipeline when its rollout gate is enabled.
<!-- evidence: 0491925, 0e44beb, 8a1ff08 -->

### Reliability

- NWS coverage now remains tied to the canonical revision: revision advancement invalidates prior geometry/H3, delayed targeting cannot replace newer coverage, and sends reject content read across a revision change.
<!-- evidence: dfda009 -->
- NWS location collections now expose recent cancellation states for reconciliation, while targeted lookups retain cancellation payloads by series ID; H3 targeting also requires the current supported scheme and resolution 8.
<!-- evidence: 39c5518, cfa5ffe -->
- Storm Setup fallbacks preserve parcel identity by keeping surface CIN and condensation-height values out of mixed-layer fields and leaving unsupported canonical ingredients nil.
<!-- evidence: dcb5828 -->

### Operations

- The worker now reports Anvil reachability, SHARPpy readiness, and observed version/revision; the Control Room shows those observations and surfaces actionable health findings.
<!-- evidence: 5bd252d, a7066d9 -->
- Usage reporting now limits DAU/MAU to foreground-active registered production installations and reports the subset registered before the current UTC month.
<!-- evidence: 2880221 -->
- Release installation now verifies the selected stable image and runtime identity, checks migrations and schema before service replacement, observes health and delivery evidence, and persists the verified image tag for later Compose commands.
<!-- evidence: d272ac1, 0491925 -->

### Maintenance

- Added a repeatable runbook for separately validating development meso notifications, distinguishing endpoint acceptance, queue handoff, APNs response, and physical receipt or tap evidence.
<!-- evidence: c40c0f8 -->

## v1.4.1

### Reliability

- Notification subject identity migration can resume after partial schema preparation, preserving existing identities, backfilling only legacy rows with no identity, and recreating its checks while creating missing indexes.

### Operations

- Run production migrations with a single migration runner; do not overlap deployment migrations with test runners against the same database.

## v1.4.0

### Features

- Device preference updates now persist an optional per-installation SPC meso notification setting, and responses indicate when server delivery is active for that installation.
<!-- evidence: a7b9c20, 1bba1b5 -->
- Accepted SPC discussions can enqueue event-first notifications behind the `MESO_NOTIFICATIONS_ENABLED` rollout gate, which defaults to disabled; the worker requires complete sandbox and production APNs credentials when delivery is enabled.
<!-- evidence: f2a4789, f483afe, 1bba1b5 -->

### Reliability

- NWS and SPC meso delivery now use product-neutral notification subjects and the shared per-installation ledger claim boundary; meso claims use stable discussion identity across revisions.
<!-- evidence: e100aa2, 5c8df75, bc62ce4, 4eef148 -->
- Active SPC meso delivery is reconciled after device presence changes so updated installation eligibility is applied to retained discussions.
<!-- evidence: b7efb1c -->

### Operations

- Red Lights now reports persisted AirNow dependency health, including recent success and failure outcomes.
<!-- evidence: 279074d -->
- Operator dashboard diagnostics now include meso candidate counts, no-op reasons, APNs outcomes, recent notification evidence, and accepted-to-first-successful-delivery latency.
<!-- evidence: 4aca49a -->

### Migrations

- Added persistence for per-installation meso notification preferences, product-neutral notification subject identity, and AirNow dependency status.
<!-- evidence: a7b9c20, e100aa2, 279074d -->

### Tests / QA

- Database-backed test suites now share a cross-process serialization gate, and SPC/dashboard fixtures clean up stale records or use stable time windows to avoid dependence on earlier runs.
<!-- evidence: 34df784 -->

## v1.3.1

### Reliability

- The runtime container now installs `libxml2`, providing the `libxml2.so.2` dependency required by FoundationXML for SPC meso parsing so the API and worker executables can load on Linux.
<!-- evidence: 4252edd -->

## v1.3.0

### Features

- Added SPC mesoscale-discussion fetching and parsing with canonical annual product identities, issuance and validity times, affected areas, discussion text, watch probability, parsed threats, and polygon coordinates.
<!-- evidence: 5ddf2fc -->

### Reliability

- Accepted meso feeds now persist canonical snapshots transactionally and idempotently; feed absence does not remove products, validity determines activity, and older observations cannot replace newer content.
<!-- evidence: b7c1863 -->
- Meso polygon snapshots and resolution-8 H3 coverage now update atomically, skip recomputation for unchanged completed coverage, and roll back the accepted feed on coverage failure. H3 matching uses cell centers without ring expansion or geography fallback.
<!-- evidence: db0535a -->

### Operations

- The worker now schedules SPC meso ingestion every ten minutes and records fetch, parse, persistence, and H3 outcomes separately from NWS ingest freshness.
<!-- evidence: f94f8cf -->
- Operator snapshots and Red Lights now report SPC meso ingest freshness, active product counts, latest product validity, H3 coverage, and recent failure categories.
<!-- evidence: cd6f4db -->
- Added Meso Activity at `/dashboard/mesos` with canonical product details and a 48-hour recent sample plus active discussions, capped at 50 with active products prioritized. Server and live rendering preserve product disclosure state by identity, and meso health diagnostics link to the page.
<!-- evidence: 2c54ffe -->

### API / Contracts

- Added `GET /v1/mesos` and `/api/v1/mesos` for all active discussions, active resolution-8 H3 matches, or a retained product by stable ID, including expired products for ID lookups. Responses use the shared ArcusCore payload and the alerts API's date representation.
<!-- evidence: d585809 -->
- Meso reads now provide deterministic ordering, payload-derived ETags and conditional `304` responses; invalid or conflicting filters return `400`, unknown product IDs return `404`, and empty collections return `200` with `[]`.
<!-- evidence: d585809 -->
- Stored dashboard snapshots and `/v1/metrics` now include additive meso health and activity data while retaining decoding of older snapshots; unavailable activity remains distinct from an empty collection.
<!-- evidence: cd6f4db, 2c54ffe -->

### Migrations

- Added `spc_mesos` and one-to-one `spc_meso_geolocation` storage with unique product keys and issue-year/MD-number pairs, cascading geometry deletion, H3 coverage metadata, and validity/H3 indexes.
<!-- evidence: c18d2be -->

### Tests / QA

- Added focused regression coverage for SPC fetching and parsing, canonical persistence, H3 coverage and rollback, worker scheduling, meso API behavior, dashboard compatibility, and server/live rendering and disclosure parity.
<!-- evidence: 5ddf2fc, b7c1863, db0535a, f94f8cf, d585809, cd6f4db, 2c54ffe -->
- Recorded full-suite runs in this release range include alert-collection and dashboard fixture failures.
<!-- evidence: c18d2be, b7c1863, d585809, cd6f4db -->

### Maintenance

- Updated the ArcusCore dependency to 0.5.0 for shared mesoscale-discussion payload, threat, and coordinate types.
<!-- evidence: 5ddf2fc -->

## v1.2.0

### Reliability

- Pipeline latency now measures revision receipt to the first original alert-driven APNs attempt, excluding reconciliation sends, retries, and APNs response time.
<!-- evidence: 44fbb9f -->
- Persisted stage timings now distinguish queue waits, target processing, candidate resolution, and notification preparation while preserving execution provenance across retries and replay.
<!-- evidence: 5bac4cb -->

### Operations

- Operator snapshots now expose p50, p95, maximum, and sample count for full-pipeline latency, plus per-stage latency distributions and counts.
<!-- evidence: cb810bb -->
- The dashboard now presents pipeline p95 as the primary latency value and shows a compact stage p95 and sample-count breakdown, including unavailable stages.
<!-- evidence: 0ff709d -->

### Migrations

- Added migration-backed delivery provenance, pipeline stage timing, and candidate-resolution count fields; historical timing is not backfilled.
<!-- evidence: 44fbb9f, 5bac4cb, cb810bb -->

### Tests / QA

- Added focused regression coverage for first-attempt latency semantics, stage timing and provenance, aggregate distributions, and dashboard rendering.
<!-- evidence: 44fbb9f, 5bac4cb, cb810bb, 0ff709d -->

## v1.1.0

### Reliability

- Notification outbox draining now claims rows atomically, uses leases for recovery, fences completion and replay updates against stale workers, and persists queue-handoff failures with bounded backoff.
<!-- evidence: 3d6cda7 -->
- Pressure-artifact probe failures now update only pending catalog rows, preserving artifacts already claimed or completed by workers.
<!-- evidence: cb193a8 -->

### Operations

- Pressure-artifact cleanup now prunes eligible failed and expired catalog records after 60 days, and the operator dashboard reports the retention period.
<!-- evidence: b3ae674, 3ba5412 -->
- Dashboard snapshot freshness is now page-specific: Overview tolerates three minutes while Model Pipeline and other detail pages use fifteen minutes; polling cadence is unchanged.
<!-- evidence: 3ba5412, fba6df4 -->
- Ingest freshness now reports healthy, warning, or unknown based on the age of the last successful sweep, with a 105-second healthy threshold; delayed ingestion is surfaced in the dashboard.
<!-- evidence: 627700f -->
- Delivery diagnostics now show the 30 newest notification attempts with key details inline and All / Targeted / Preview filters based on persisted record kind; the selection persists across live refreshes.
<!-- evidence: aa0865e -->

## v1.0.0

### Features

- Arcus Signal now provides a durable NWS alert-ingestion, revision, geospatial-targeting, and notification-dispatch pipeline for location-aware severe-weather alerts.
<!-- evidence: cda3a25, e67214b, 48d2343, 5e758fc, c539de3 -->
- The server now exposes location-scoped alert APIs, canonical `/v1` routes, device preference and location snapshot ingestion, and operator-facing dashboard endpoints.
<!-- evidence: 2a45e6e, 1cd4ecc, 2c01033, 98bb09d, fadeeaa, ab99bca -->
- Storm Setup now includes HRRR surface and pressure-artifact processing, tornado viability analysis, AirNow AQI data, and durable artifact warming and cleanup workflows.
<!-- evidence: dd6e743, ba97707, 852d7f1, a7b277d, ffa751e, a12d34e -->

### Reliability

- Notification delivery now uses durable outbox and ledger boundaries, bounded APNs retries, installation-scoped candidate selection, and freshness-aware presence reconciliation.
<!-- evidence: 48bcbb9, 69fcf76, 7d0f7bc, ed27578, b568bac, b5d3555, 5bf7c3e, e3a742a -->
- NWS alert lifecycle and revision persistence now preserve authoritative state through replay, deduplication, cleanup, cancellation, and freshness boundaries.
<!-- evidence: 98bb09d, 5e758fc, c78dd6a, ebbfd07, c6ec4ff, a89b32a -->
- Worker processing now bounds pressure-artifact work, recovers abandoned jobs, retries transient failures with backoff, and surfaces backlog health.
<!-- evidence: 8ededc7, 9821099, 75ecea7, 457b7e4, 4749879, 8985a4d -->
- Queue subprocesses, database ownership boundaries, and startup behavior were hardened to prevent stalls, leaked descriptors, and unsafe concurrent state transitions.
<!-- evidence: e957a45, 7cf72c3, 05a76c2, 1f5cda0, 7e88a0c, b5d3555 -->

### Operations

- The operator dashboard now reports installation activity, alert activity, delivery hierarchy, health state, operational footprint, responsive layouts, and the deployed Arcus Signal release version.
<!-- evidence: 35152ff, bd77697, 95b6f83, 2bf6e34, c393993, 5946528, a4048f2, cb79c84, e8ecf14, cb4e375 -->
- Production container publishing is now tied to stable GitHub Releases, with explicit versioned deployment through the installer and image metadata containing the release version and source revision.
<!-- evidence: 1ccaaf2, cea3ea2 -->

### API / Contracts

- API endpoint behavior, request validation, alert payloads, geometry targeting, notification diagnostics, and source-controlled Postman coverage are now documented and maintained with the server.
<!-- evidence: 1e0aa98, 7eb8ce8, 4469c10, 1011233, 7eb8ce8 -->

### Tests / QA

- Focused integration, persistence, queue, delivery, dashboard, and rollout-readiness coverage was expanded across the alert, notification, Storm Setup, and operational workflows.
<!-- evidence: f9b29d0, c6ec4ff, 4c3859f, 4c3859f, d7273f2 -->

### Maintenance

- Swift, package, architecture, runbook, and release-readiness documentation was updated alongside the implementation work.
<!-- evidence: 004e9ab, 45b6362, 51f4259, 9452b4f, d7273f2 -->
