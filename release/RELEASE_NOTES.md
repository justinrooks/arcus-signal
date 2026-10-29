# Release Notes

## v1.5.0

## Overview

Arcus Signal v1.5.0 strengthens authenticated device enrollment and consent ordering, improves NWS delivery recovery and validation, and tightens cache lifecycle and location-consent reporting. A GitHub release builds the production container; deployment remains a separate explicit operation.

## Highlights

- Device writes use authenticated installation enrollment, with ordered v3 consent revisions and downgrade fencing; meso ownership requires usable accepted presence.
- NWS outbox handoffs can recover without new weather, and operator diagnostics expose expired leases and failed queue handoffs.
- Invalid NWS collection envelopes are rejected, while surface cache cleanup and AQI cache residency are bounded.
- Dashboard coverage reflects location-sharing consent, and meso rollout gates are checked explicitly during release operations.

## v1.4.2

## Overview

Arcus Signal v1.4.2 improves NWS revision and cancellation handling, preserves Storm Setup parcel meaning during native fallbacks, and adds operator visibility into Anvil and production installation usage. It also provides a gated development path for exercising SPC meso notifications. A GitHub release builds the production container; deployment remains a separate explicit operation.

## Highlights

- NWS targeting and delivery now follow the canonical alert revision, reject stale H3 presence, and expose recent cancellations for client reconciliation.
- Storm Setup keeps surface measurements separate from mixed-layer ingredients and leaves unsupported canonical values unset.
- The Control Room reports Anvil health and deployed identity, plus production-only DAU/MAU and returning installations registered before the current month.
- A guarded development endpoint creates short-lived TEST meso fixtures and can pass them through the existing notification pipeline when the rollout gate is enabled.
- Release installation verifies the selected stable image and runtime, checks migrations and schema before replacing services, observes outcomes, and saves the verified tag for subsequent Compose commands.

## Maintenance

- Added a runbook for separately validating the development meso notification path, from HTTP acceptance through queue and APNs evidence to physical device receipt or interaction.

## v1.4.1

## Overview

Arcus Signal v1.4.1 hardens recovery of the notification subject identity migration when an earlier attempt left part of its schema in place. Run the migration with a single runner and keep tests from migrating the same production database concurrently. A GitHub release builds the production container; deployment remains a separate explicit operation.

## Highlights

- The migration adds missing identity columns, preserves already populated identities, and backfills only legacy rows whose identity fields are all empty.
- Existing subject identity checks are recreated on retry, and missing subject identity indexes are created.

## Maintenance

- No application behavior change is intended; this patch makes the v1.4.0 schema migration resumable for the partially prepared production database.

## v1.4.0

## Overview

Arcus Signal v1.4.0 adds opt-in SPC mesoscale notifications, installation-level preferences, and operator visibility into meso delivery and AirNow dependency health. Meso notification delivery remains disabled by default. A GitHub release builds the production container; deployment remains a separate explicit operation.

## Highlights

- Device preference updates persist an optional SPC meso notification setting per installation, and responses indicate when server-owned delivery is active.
- SPC meso notifications use an event-first queue and stable discussion identity, with delivery gated by `MESO_NOTIFICATIONS_ENABLED` and worker APNs readiness.
- NWS and SPC meso delivery share product-neutral notification subjects and the per-installation ledger claim boundary; active meso delivery is reconciled after device presence changes.
- Red Lights reports persisted AirNow dependency health, while operator dashboard diagnostics show meso candidate resolution, no-op reasons, APNs outcomes, recent notification evidence, and delivery latency.

## Maintenance

- Added database persistence for meso notification preferences, notification subject identity, and AirNow dependency health; database-backed test suites use shared serialization and deterministic fixture cleanup.

## v1.3.1

## Overview

Arcus Signal v1.3.1 fixes the missing XML runtime dependency in the production container. A GitHub release builds the production container; deployment remains a separate explicit operation.

## Highlights

- The runtime image now includes `libxml2`, resolving the `libxml2.so.2` loader error affecting the API and worker executables after the SPC meso parser was added.

## v1.3.0

## Overview

Arcus Signal v1.3.0 adds canonical SPC mesoscale-discussion ingestion, persistence, H3 coverage, read APIs, and operator visibility. A GitHub release builds the production container; deployment remains a separate explicit operation.

## Highlights

- The worker ingests SPC discussions every ten minutes, retaining canonical product content and deriving activity from validity times. Accepted snapshots and H3 coverage update transactionally.
- `GET /v1/mesos`, also available at `/api/v1/mesos`, returns all active discussions, active resolution-8 H3 matches, or a retained product by stable ID. Reads include shared payload fields, deterministic ordering, and ETag-based conditional responses.
- Red Lights reports meso ingest freshness, active counts, product validity, coverage, and failure categories separately from NWS freshness.
- Meso Activity at `/dashboard/mesos` exposes discussion text, affected areas, watch probability, available threats, coverage, and source links. Its 48-hour recent sample plus active discussions is capped at 50 with active products prioritized; live refresh preserves expanded products and keyboard focus by identity.
- Dashboard snapshot additions preserve older snapshot decoding and distinguish unavailable meso activity from an empty collection.

## Maintenance

- Added canonical meso and geometry tables with annual identity uniqueness, H3 metadata, and validity/H3 indexes; adopted ArcusCore 0.5.0 shared meso types.
- Added focused regression coverage across ingestion, persistence, coverage, APIs, and dashboard rendering. Recorded full-suite runs in this release range include alert-collection and dashboard fixture failures.

## v1.2.0

## Overview

Arcus Signal now measures alert-pipeline latency through the first original alert-driven APNs attempt and provides stage-level diagnostics for operators.

## Highlights

- The operator dashboard shows pipeline p95, p50, maximum, and sample count, with a compact p95 and sample-count breakdown for each major stage.
- Reconciliation sends, retries, and APNs response time no longer define the primary pipeline-latency measurement.

## Maintenance

- Added migration-backed provenance and timing data for pipeline diagnostics. Historical timing is not backfilled.

## v1.1.0

## Overview

Arcus Signal v1.1.0 strengthens notification dispatch and pressure-artifact cleanup while expanding operator health and delivery diagnostics. A GitHub release builds the production container; deployment remains a separate explicit operation.

## Highlights

- Notification outbox dispatch now uses atomic claims and lease fencing to recover safely from concurrent workers and queue-handoff failures.
- Pressure-artifact processing protects worker-claimed and completed records from late probe failures, and cleanup removes eligible terminal catalog records after 60 days.
- Operator dashboard freshness thresholds now match each page: three minutes for Overview and fifteen minutes for Model Pipeline and other detail pages.
- Ingest freshness now distinguishes healthy, delayed, and unknown states using the last successful sweep, with a 105-second healthy threshold.
- Delivery diagnostics show the 30 newest notification attempts with details inline and All / Targeted / Preview filters that remain selected during live refresh.

## v1.0.0

## Overview

Arcus Signal v1.0.0 establishes the server-side severe-weather alert pipeline, including NWS ingestion, durable revision and notification processing, location-aware targeting, Storm Setup data workflows, operator diagnostics, and explicit versioned container deployment.

## Highlights

- NWS alerts now flow through durable ingestion, revision, geospatial targeting, outbox, and notification-delivery boundaries.
- The server provides canonical `/v1` APIs for alerts, device presence and preferences, location snapshots, and operator diagnostics while preserving the documented compatibility routes.
- Storm Setup processing includes HRRR surface and pressure-artifact workflows, tornado viability analysis, and AirNow AQI data.
- Notification delivery includes installation-scoped targeting, freshness-aware presence reconciliation, durable ledger protection, bounded retries, and replay-safe processing.
- The operator dashboard reports health state, alert and installation activity, delivery context, responsive layouts, and the deployed Arcus Signal release version.
- Stable GitHub Releases now define the production container build boundary; the installer deploys an explicitly selected version to both API and worker services.

## Maintenance

- Architecture, endpoint, Postman, operational, rollout-readiness, and release documentation were updated alongside the implementation work.
