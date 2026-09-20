# Changelog

## Unreleased

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
