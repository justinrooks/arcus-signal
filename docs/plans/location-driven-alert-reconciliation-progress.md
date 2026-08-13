# Location-Driven Active-Alert Reconciliation Progress

## Overview

Arcus Signal currently discovers notification relevance when an alert revision changes. This campaign adds the inverse discovery path for an installation whose authoritative presence changes, while retaining one server delivery pipeline and one ledger claim boundary.

Epic status:
- Active

Primary GitHub epic:
- `#207` - https://github.com/justinrooks/arcus-signal/issues/207

Runbook:
- `docs/plans/location-driven-alert-reconciliation-runbook.md`

---

## Global Decisions

- Arcus Signal remains the sole watch/warning notification producer and deduplication authority.
- Keep the API boundary as validate -> transactional persistence/intention -> queued worker work. No request-time APNs.
- Reconcile only first usable presence, changed persisted targeting fingerprint, or unusable/hard-stale to usable transitions.
- Define the targeting fingerprint from persisted H3 cell, county, forecast zone, and fire zone.
- Do not trigger on upload source, labels, accuracy, or a fresh unchanged heartbeat.
- Use `captured_at` and `LocationFreshnessPolicy`; `location_age_seconds` and `received_at` are not the current delivery-freshness authority.
- Persist a durable reconciliation intent in the same transaction as the authoritative installation/presence change.
- Query active current revisions for one installation. Do not invoke global alert fan-out from location work.
- Use current-revision `notification_outbox.mode` and `.reason` to preserve H3 versus UGC fallback and existing copy semantics.
- Add a backward-compatible optional installation constraint to `NotificationSendJob`; do not create a parallel last-mile delivery service unless this seam proves inadequate.
- Preserve `UNIQUE(installation_id, series_id, revision_urn)` as the race and retry convergence point.
- Treat duplicate discovery and duplicate queue handoff as safe; do not claim exactly-once APNs delivery.
- Keep APNs failure/reclaim work in `#13` and general outbox concurrency work in `#6` out of scope.
- Server deployment and validation must precede any separate client WatchEngine removal campaign.

---

## Confirmed Current State

### Alert-driven flow

1. `IngestNWSAlertsJob` fetches NWS events and calls `NWSIngestPersistence` in a database transaction.
2. A new current revision writes a target-dispatch intent for any geometry and writes a UGC notification-dispatch intent immediately for nil or point geometry.
3. `TargetEventRevisionJob` computes/persists H3 coverage for supported polygons, then writes an H3 notification-dispatch intent. Point or cover failure uses UGC fallback.
4. `DispatchAgent` enqueues `NotificationSendJob` on the send lane and marks the notification outbox row done after queue handoff.
5. `NotificationSendJob` requires the payload revision to equal `arcus_series.current_revision_urn`.
6. Normal `.new`/`.update` work stops before candidate selection unless the series is active and neither `expires` nor `ends` is past.
7. `NotificationCandidateStore` selects active, subscribed, token-bearing installations with `captured_at` no older than 24 hours using exact H3 membership or county/forecast-zone/fire-zone OR matching.
8. `LocationFreshnessPolicy` classifies each candidate. Stale authorization/location records are recorded as missed and skipped; fresh/degraded candidates continue.
9. `NotificationDeliveryStore.claim` performs `INSERT ... ON CONFLICT DO NOTHING` against the ledger identity `(installation_id, series_id, revision_urn)`.
10. After a claim, `NotificationEngine` composes candidate-specific copy, the sender calls APNs, and the ledger becomes `sent` or terminal `failed`. A send-attempt summary and debug copy are recorded separately.

### Presence flow

1. `POST /api/v1/devices/location-snapshots` decodes the ArcusCore payload and validates identifiers, enums, non-negative age/accuracy, paired H3 fields, resolution, and a captured time no more than five minutes in the future.
2. The route transaction upserts the installation and one presence row keyed by installation UUID.
3. Presence with an older `captured_at` is ignored. Equal timestamps are accepted.
4. Newer accepted records update timestamps, quality, scheme, and source. Optional H3/UGC fields and labels overwrite only when supplied, so omitted fields preserve prior authoritative values.
5. The route returns success after logging the insert/update/stale-ignore outcome.
6. No active-alert query, durable reconciliation intent, queue dispatch, delivery claim, or APNs work currently follows presence persistence.

### Root capability gap

Alert fan-out sees only installations matching when a revision is targeted. A later presence change can make that same active current revision relevant, but no inverse evaluation runs. Therefore an installation outside at issuance can enter the covered H3/UGC area and receive no server notification for that revision.

---

## Material Findings Versus Initial Assumptions

- The named `NotificationCandidateStore` and `NotificationDeliveryStore` already exist on current `main`; they are not merely proposed architecture seams.
- The ledger identity is confirmed exactly as `(installation_id, series_id, revision_urn)`. Mode and reason are recorded but do not participate in uniqueness.
- The ledger gives at-most-one claim, not exactly-once or eventual APNs delivery. A crash after claim can leave `claimed`, and failed claims are terminal today.
- `NotificationSendJob` owns lifecycle/revision gating, fan-out selection, freshness, claim, composition, APNs, completion, debug, and attempt telemetry. An installation constraint is smaller than extracting a new delivery subsystem.
- Candidate SQL excludes records older than 24 hours before the richer freshness policy runs. Freshness is based on `captured_at` and authorization, not the uploaded `location_age_seconds`.
- `DeviceController` preserves old H3/UGC values when an accepted partial payload omits them, including for `ugc-only`. The current candidate queries match persisted fields and do not filter on `cell_scheme`; reconciliation must preserve that behavior unless separately changed.
- A series-level `arcus_geolocation` row is not revision-keyed. Its mere existence cannot safely determine the current revision's H3/UGC mode after a fallback revision. The current-revision notification-dispatch record is the safer mode provenance.
- Current production queue dispatches use zero Vapor Queue retries by default. Bounded reconciliation retries can be added because the new path is idempotent, but this campaign does not repair APNs retry semantics.

---

## Target Flow

```text
accepted authoritative installation/presence transition
  -> pure meaningful-transition decision
  -> durable presence reconciliation intent in same DB transaction
  -> best-effort API queue handoff plus worker scheduled drain
  -> target-lane installation reconciliation job
  -> installation-scoped active-current-revision H3/UGC lookup
  -> send-lane NotificationSendJob constrained to one installation
  -> existing lifecycle + freshness + atomic ledger claim
  -> existing composition + APNs + sent/failed completion
```

Race result:

```text
alert-driven discovery -----\
                             -> INSERT ledger claim -> one winner
location-driven discovery --/
```

---

## Issue Sequence

Work sequentially:

1. `#208` - https://github.com/justinrooks/arcus-signal/issues/208 - 01: Define meaningful presence reconciliation transitions
2. `#209` - https://github.com/justinrooks/arcus-signal/issues/209 - 02: Add durable presence reconciliation intents
3. `#210` - https://github.com/justinrooks/arcus-signal/issues/210 - 03: Record intents for authoritative presence transitions
4. `#211` - https://github.com/justinrooks/arcus-signal/issues/211 - 04: Query matching active alerts for one installation
5. `#212` - https://github.com/justinrooks/arcus-signal/issues/212 - 05: Constrain the existing send job to one installation
6. `#213` - https://github.com/justinrooks/arcus-signal/issues/213 - 06: Dispatch and process installation reconciliation work
7. `#214` - https://github.com/justinrooks/arcus-signal/issues/214 - 07: Verify end-to-end races, retries, and rollout readiness

---

## Existing Code Map

Production:
- `Sources/App/Controllers/DeviceController.swift`
- `Sources/App/Models/Device/DeviceInstallationModel.swift`
- `Sources/App/Models/Device/DevicePresenceModel.swift`
- `Sources/App/Infrastructure/Notifications/LocationFreshnessPolicy.swift`
- `Sources/App/Services/NWSIngestPersistence.swift`
- `Sources/App/Jobs/IngestNWSAlertsJob.swift`
- `Sources/App/Jobs/TargetEventRevisionJob.swift`
- `Sources/App/lib/DispatchAgent.swift`
- `Sources/App/Models/Notification/NotificationCandidateStore.swift`
- `Sources/App/Models/Notification/NotificationDeliveryStore.swift`
- `Sources/App/Jobs/NotificationSendJob.swift`
- `Sources/App/Infrastructure/Notifications/NotificationEngine.swift`
- `Sources/App/Migrations/CreateDevicePresence.swift`
- `Sources/App/Migrations/CreateArcusGeolocation.swift`
- `Sources/App/Migrations/CreateNotificationOutbox.swift`
- `Sources/App/Migrations/CreateNotificationLedger.swift`
- `Sources/App/configure.swift`
- `Sources/App/Worker/ArcusQueueLane.swift`
- `Sources/App/Worker/WorkerRuntime.swift`

Focused tests:
- `Tests/AppTests/DeviceControllerTests.swift`
- `Tests/AppTests/NWSIngestPersistenceFlowTests.swift`
- `Tests/AppTests/TargetEventRevisionJobFallbackTests.swift`
- `Tests/AppTests/NotificationSendJobCandidateQueryTests.swift`
- `Tests/AppTests/NotificationSendJobFreshnessDecisionTests.swift`
- `Tests/AppTests/NotificationSendJobDeliveryBoundaryTests.swift`
- `Tests/AppTests/NotificationLedgerFreshnessPersistenceTests.swift`
- `Tests/AppTests/NWSAlertLifecycleTests.swift`
- `Tests/AppTests/IntegrationTestSupport.swift`

---

## Performance And Resilience Notes

- The inverse query is bounded by one installation and the small set of active current series. Existing indexes cover series lifecycle, H3 arrays, UGC arrays, and notification-outbox series joins.
- Only meaningful state transitions create reconciliation work, so ordinary foreground heartbeats do not scan active alerts.
- The durable intent closes the database-commit/Redis-enqueue gap for accepted transitions. API queue handoff remains best effort; the worker schedule drains missed ready rows.
- Duplicate outbox drain or job retry can enqueue the same constrained send more than once. The ledger uniqueness makes delivery claim convergence safe.
- Reconciliation must load latest authoritative presence rather than treating the intent's historical fingerprint as delivery input. This prevents a delayed job from targeting an obsolete location.
- Existing general outbox non-atomic drain behavior remains. Duplicates are acceptable here; lost committed intent is not.
- Existing APNs failure behavior remains terminal and is not made reliable by this campaign.
- Logs should expose reconciliation intent ID, installation ID, trigger category, matched alert count, constrained dispatch count, retry attempt, and error without APNs tokens or raw coordinates.

---

## Status Ledger

### Issue #208 - 01: Define meaningful presence reconciliation transitions

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/208

Status: Complete

Goal:
- Add a pure, deterministic decision for first usable presence, persisted targeting-fingerprint change, and unusable/hard-stale to usable transition.

Likely files:
- `Sources/App/Infrastructure/Notifications/PresenceReconciliationTrigger.swift`
- `Tests/AppTests/PresenceReconciliationTriggerTests.swift`

Verification:
- `swift test --filter PresenceReconciliationTriggerTests`

Evidence:
- Added `PresenceReconciliationTrigger` as a pure `Sendable` decision over authoritative persisted state.
- Added nine deterministic matrix tests covering first usable, moved while usable, unusable-to-usable, stale-to-fresh, unchanged heartbeat, irrelevant changes, unusable-to-unusable, and delivery-state gates.
- Focused verification passed on 2026-08-13.

Stop condition:
- Policy and matrix tests exist; no controller, queue, migration, query, or send behavior is wired.

Handoff:
- Issue #209 may add durable reconciliation intents; do not wire route or worker behavior into this policy slice.

### Issue #209 - 02: Add durable presence reconciliation intents

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/209

Status: Complete

Goal:
- Add the minimal PostgreSQL model, migration, and store for immutable ready/done/dead reconciliation queue-handoff intents.

Likely files:
- `Sources/App/Models/Notification/PresenceReconciliationOutboxModel.swift`
- `Sources/App/Migrations/CreatePresenceReconciliationOutbox.swift`
- `Sources/App/Models/Notification/PresenceReconciliationOutboxStore.swift`
- `Sources/App/configure.swift`
- `Tests/AppTests/PresenceReconciliationOutboxTests.swift`

Verification:
- `swift test --filter PresenceReconciliationOutboxTests`
- `swift test --filter DevicePresenceMigrationTests`

Stop condition:
- Schema and persistence semantics are tested and registered; no route or worker behavior consumes them.

Evidence:
- Added `presence_reconciliation_outbox` with immutable installation/presence/trigger/fingerprint identity, ready/done/dead handoff state, retry metadata, and deterministic ready-drain index.
- Added a transaction-owned store for idempotent intent insertion and guarded queue-handoff outcome updates.
- `swift test --filter PresenceReconciliationOutboxTests` and `swift test --filter DevicePresenceMigrationTests` passed on 2026-08-13.

Handoff:
- Issue #210 should create intents only inside the accepted `DeviceController` transaction; it must not dispatch or consume them.

### Issue #210 - 03: Record intents for authoritative presence transitions

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/210

Status: Complete

Goal:
- Evaluate persisted before/after installation and presence state inside the existing route transaction and insert an intent only for meaningful usable transitions.

Likely files:
- `Sources/App/Controllers/DeviceController.swift`
- `Sources/App/Infrastructure/Notifications/PresenceReconciliationTrigger.swift`
- `Sources/App/Models/Notification/PresenceReconciliationOutboxStore.swift`
- `Tests/AppTests/DeviceControllerTests.swift`

Verification:
- `swift test --filter DeviceControllerTests`
- `swift test --filter PresenceReconciliationTriggerTests`

Stop condition:
- The route transaction durably records correct intents; it does not dispatch reconciliation or APNs work.

Evidence:
- The location-snapshot transaction captures authoritative before/after installation and presence state, evaluates the established trigger after persistence, and inserts the immutable reconciliation intent only for accepted meaningful usable transitions.
- Older `captured_at` uploads remain ignored without an intent; partial updates hash the persisted targeting fingerprint, preserving omitted H3/UGC fields.
- `swift test --filter DeviceControllerTests` and `swift test --filter PresenceReconciliationTriggerTests` passed on 2026-08-13.

Handoff:
- Issue #211 may add the installation-scoped active-current-revision query. This route still does not dispatch, query alerts, or send APNs.

### Issue #211 - 04: Query matching active alerts for one installation

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/211

Status: Implemented — Ready for Commit

Goal:
- Add an installation-scoped active-current-revision lookup that preserves current H3 and UGC-fallback mode semantics.

Likely files:
- `Sources/App/Models/Notification/NotificationCandidateStore.swift`
- `Tests/AppTests/NotificationActiveAlertQueryTests.swift`

Verification:
- `swift test --filter NotificationActiveAlertQueryTests`
- `swift test --filter NotificationSendJobCandidateQueryTests`

Stop condition:
- Query tests cover H3, all three UGC fields, fallback mode, current revision, and lifecycle exclusions; no queue or delivery behavior changes.

Evidence:
- Added an installation-scoped inverse lookup that returns current series/revision identity plus existing H3/UGC mode and `.new`/`.update` reason provenance.
- H3 exact membership, county/forecast-zone/fire-zone OR matching, current-revision UGC fallback despite an older series geolocation row, and lifecycle/reason exclusions are covered by PostgreSQL integration tests.
- Existing indexes remain sufficient for this bounded lookup; no schema or index change was added.
- `swift test --filter NotificationActiveAlertQueryTests` and `swift test --filter NotificationSendJobCandidateQueryTests` passed on 2026-08-13.

Handoff:
- After review and merge, issue #212 may add the backward-compatible installation constraint to the existing send job. This slice does not dispatch queue work or alter delivery behavior.

### Issue #212 - 05: Constrain the existing send job to one installation

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/212

Status: Implemented — Awaiting Human Review

Goal:
- Make `NotificationSendJob` optionally select one installation without changing existing unconstrained alert-driven fan-out or last-mile semantics.

Likely files:
- `Sources/App/Jobs/NotificationSendJob.swift`
- `Sources/App/Models/Notification/NotificationCandidateStore.swift`
- `Tests/AppTests/NotificationSendJobCandidateQueryTests.swift`
- `Tests/AppTests/NotificationSendJobDeliveryBoundaryTests.swift`

Verification:
- `swift test --filter NotificationSendJobCandidateQueryTests`
- `swift test --filter NotificationSendJobDeliveryBoundaryTests`
- `swift test --filter NotificationEngineTests`

Stop condition:
- Optional constrained payload behavior and backward decoding are tested; no reconciliation job exists yet.

Evidence:
- Added an optional installation ID to `NotificationSendJobPayload`; payloads queued before this field existed continue to decode with no constraint.
- H3 and UGC candidate queries restrict to the requested installation when present and retain current fan-out when absent.
- Focused tests cover constrained matching, moved-away no-op behavior, existing-claim no-op behavior, and concurrent constrained/unconstrained discovery converging at the ledger identity.
- All three focused verification suites passed on 2026-08-13.

Handoff:
- After review and merge, issue #213 may dispatch installation-constrained send jobs from worker-owned reconciliation. This slice does not add reconciliation dispatch or processing.

### Issue #213 - 06: Dispatch and process installation reconciliation work

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/213

Status: Implemented — Awaiting Human Review

Goal:
- Add best-effort API queue handoff, a worker scheduled outbox drain, and a bounded-retry target-lane job that dispatches installation-constrained send work for active matches.

Likely files:
- `Sources/App/Jobs/ReconcileInstallationAlertsJob.swift`
- `Sources/App/Jobs/DispatchPresenceReconciliationScheduledJob.swift`
- `Sources/App/Models/Notification/PresenceReconciliationOutboxStore.swift`
- `Sources/App/Controllers/DeviceController.swift`
- `Sources/App/configure.swift`
- `Tests/AppTests/InstallationAlertReconciliationJobTests.swift`

Verification:
- `swift test --filter InstallationAlertReconciliationJobTests`
- `swift test --filter DeviceControllerTests`
- `swift test --filter AppTests.AppTests`

Stop condition:
- Durable intents reach the target lane and dispatch only installation-scoped send work; no end-to-end campaign expansion or client change.

Evidence:
- The location route now attempts target-lane handoff only after its persistence transaction commits; queue failure preserves the ready intent and records sanitized retry metadata without failing the accepted response.
- A worker-only minute schedule drains ready intents, while `ReconcileInstallationAlertsJob` reloads authoritative installation/presence, applies bounded queue retries, rediscovers current active matches, and dispatches installation-constrained children on the send lane.
- Focused tests cover immediate successful API handoff, target/send lane ownership, retry bounds, durable handoff failure, latest-presence movement, zero-match success, unusable state, and API/worker schedule isolation.
- `swift test --filter InstallationAlertReconciliationJobTests`, `swift test --filter DeviceControllerTests`, and `swift test --filter AppTests.AppTests` passed on 2026-08-13.
- Human review completed on 2026-08-13. Independent defect review found no actionable defects; the validation audit's two test-coverage findings were accepted, corrected, and confirmed closed.
- `swift build` and the final full 552-test `swift test --no-parallel` pass completed successfully on 2026-08-13.

Handoff:
- After review and merge, issue #214 may add the final vertical race/idempotency matrix and align living architecture documentation. This slice does not change APNs retry/reclaim behavior or any client producer.

### Issue #214 - 07: Verify end-to-end races, retries, and rollout readiness

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/214

Status: Pending

Goal:
- Add final deterministic vertical coverage, align living architecture docs, and record deployment validation and client-removal gates.

Likely files:
- `Tests/AppTests/LocationDrivenAlertReconciliationFlowTests.swift`
- `docs/architecture.md`
- `docs/plans/location-driven-alert-reconciliation-progress.md`

Verification:
- `swift test --filter LocationDrivenAlertReconciliationFlowTests`
- `swift test --filter Notification`
- `swift test --filter Device`
- `swift test --filter Reconciliation`
- `swift build`
- `swift test --no-parallel`

Required vertical matrix:
- outside at issuance, later enters active revision and sends once;
- prior delivery and leave/re-enter do not resend;
- new revision remains independently eligible;
- first valid presence discovers an existing alert;
- hard-stale/unusable to usable transition reconciles;
- unchanged/irrelevant presence creates no intent or constrained send;
- H3 and UGC fallback both work;
- expired, ended, cancelled, and stale revisions are ignored;
- alert-driven and location-driven discovery racing produces one ledger claim;
- duplicate intent drain and reconciliation retry remain idempotent.

Stop condition:
- Full server capability and rollout evidence are documented. No client issue, repository change, or WatchEngine removal is created.

---

## Verification Ledger

- Investigation verified local `main` at `8985a4d89e22b31bc6951acfbe3ba2886a973991`, matching the latest GitHub commit returned by the connector.
- Read `AGENTS.md`, living/historical architecture docs, existing Epic Builder plan patterns, notification and presence production paths, migrations, and focused tests.
- Searched GitHub for overlapping active-alert/location-reconciliation issues; none were found.
- Related existing work: completed freshness epic `#51`; open outbox concurrency issue `#6`; open APNs retry issue `#13`.
- GitHub connector verification confirmed epic `#207` is open with seven checklist children, and issues `#208` through `#214` are open, linked to `#207`, labeled `server`/`feature`/`codex`, and reference both campaign docs.
- Placeholder and whitespace verification passed for both campaign docs after exact issue links were patched.
- Planning-only task: project build and tests are not required until implementation because no production code changed.

---

## Handoff Notes

- Future implementers should recover context from this progress doc, the runbook, and the current child issue instead of restating the investigation.
- The first implementation slice is policy only. Do not jump directly into controller queue dispatch.
- Preserve user-owned working-tree changes in `docs/Sql/Device.sql`, `docs/audits/weekly-bug-scan.md`, and `docs/audits/weekly-test-gap-audit.md`.
- If implementation finds that current-revision notification-outbox mode is not reliable provenance, stop and document evidence before adding a new revision contract or schema field.
- If an issue exceeds the likely files or review budget, split it before editing rather than broadening the slice.
