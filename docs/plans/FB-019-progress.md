# FB-019 Progress Log

## Overview

FB-019 adds a server-owned Location Freshness & Presence Policy for Arcus Signal notification targeting.

Implementation should proceed one issue at a time, following `docs/plans/FB-019-issue-runbook.md`.

Primary source of truth:
- `/Users/justin/Library/Mobile Documents/iCloud~md~obsidian/Documents/Second Brain/Efforts/Notes/FB-019 Location Freshness Policy.md`

Related local docs:
- `AGENTS.md`
- `docs/architecture.md`
- `docs/epics-stories.md`
- `docs/event-cleanup-strategy.md`

Related GitHub issues:
- Not created yet.

---

## Global Decisions

- Feature name: Location Freshness & Presence Policy.
- Freshness states are locked as:
  - `fresh`
  - `degraded`
  - `stale`
- Freshness must be computed from `device_presence.captured_at`.
- Freshness must not be computed from `device_presence.received_at`, `device_presence.updated_at`, or `device_installations.last_seen_at`.
- Permission mode comes from `device_installations.location_auth`.
- Global hard-stale threshold is 24 hours after `captured_at`.
- When In Use thresholds:
  - fresh: `0-2 hr`
  - degraded: `2-24 hr`
  - stale: `>24 hr`
- Always thresholds:
  - fresh: `0-6 hr`
  - degraded: `6-24 hr`
  - stale: `>24 hr`
- Degraded presence remains eligible for warning and watch pushes.
- Stale presence is ineligible for push targeting.
- Stale does not mean delete immediately; it means not trustworthy enough for current-location targeting.
- Fresh warning and watch pushes use subtitle copy `Includes your location`.
- Degraded warning and watch pushes use subtitle copy `For your last known area`.
- Do not use `Near your last known area` in v1.
- Stale candidates are suppressed rather than sent.
- Stale suppressions must be recorded once in a dedicated missed-decision table.
- Delivered notification decisions should record the freshness state used at decision time.
- Observability should answer: "How many candidate pushes were skipped because location was stale?"
- Keep the existing `NotificationEngine` and notification delivery flow in place.
- Do not introduce a parallel targeting pipeline.
- Morning summaries remain out of scope because they are handled on-device.

---

## Current Status

- FB-019 runbook and progress documents have been created.
- No FB-019 GitHub epic or sub-issues have been identified in this repository yet.
- No implementation changes have been made for FB-019.
- Initial codebase investigation confirms the server has the core data needed for the policy:
  - `device_presence.captured_at`
  - `device_presence.received_at`
  - `device_installations.location_auth`
  - H3 and UGC candidate queries in `NotificationSendJob`
  - push copy composition in `NotificationEngine`
  - exactly-once sent-delivery accounting in `notification_ledger`
  - operator metrics that already reference stale presence conceptually

---

## Codebase Investigation Notes

- Relevant existing paths:
  - `Sources/App/Controllers/DeviceController.swift`
  - `Sources/App/Models/Device/DevicePresenceModel.swift`
  - `Sources/App/Models/Device/DeviceInstallationModel.swift`
  - `Sources/App/Migrations/CreateDevicePresence.swift`
  - `Sources/App/Migrations/CreateDeviceInstallations.swift`
  - `Sources/App/Jobs/NotificationSendJob.swift`
  - `Sources/App/Infrastructure/Notifications/NotificationEngine.swift`
  - `Sources/App/Models/Notification/NotificationLedgerModel.swift`
  - `Sources/App/Models/Data/ArcusNotificationOutboxModel.swift`
  - `Sources/App/lib/OperatorDashboardSnapshotRefresher.swift`
  - `Sources/App/lib/OperatorDashboardConfig.swift`
  - `Tests/AppTests/NotificationEngineTests.swift`
  - `Tests/AppTests/OperatorDashboardTests.swift`
  - `docs/event-cleanup-strategy.md`
  - `docs/Sql/NotificationProcessing.sql`
  - `docs/Sql/NotificationDebug.sql`
  - `docs/Sql/Device.sql`
- `DeviceController` already rejects future `capturedAt` values more than five minutes ahead of server receive time.
- `DeviceController` ignores older presence updates by comparing incoming `capturedAt` against the stored `capturedAt`.
- `DevicePresenceModel` stores `capturedAt`, `receivedAt`, location age, accuracy, cell scheme, H3 cell, UGC codes, and location source.
- `DeviceInstallationModel` stores `locationAuthRaw`, with typed `LocationAuth` values:
  - `always`
  - `whenInUse`
  - `denied`
  - `restricted`
  - `notDetermined`
  - `unknown`
- `NotificationSendJob.loadH3Candidates` and `loadUGCCandidates` already accept an optional `freshnessCutoff`, but current callers pass `nil`.
- The existing optional `freshnessCutoff` branches filter `i.last_seen_at`, not `p.captured_at`. FB-019 must not use that as the final policy implementation.
- `NotificationCandidate` currently does not include `captured_at`, `received_at`, or `location_auth`, so the delivery loop cannot yet choose freshness-aware copy or stale suppression after broad candidate selection.
- `NotificationEngine.deriveSubtitle` currently returns `Includes your location` for new H3 notifications and `For your area` for new UGC notifications.
- `NotificationEngine.deriveSubtitle` currently ignores candidate freshness because freshness is not modeled on `NotificationCandidate`.
- `notification_ledger` currently enforces a sent-delivery identity around `(installation_id, series_id, revision_urn)` through the claim path.
- `notification_ledger` records status and APNs failures but does not currently record freshness state.
- No dedicated missed-decision table exists yet.
- `OperatorDashboardConfig.presenceFreshnessThresholdSeconds` currently uses a flat 6-hour threshold for dashboard calculations.
- `OperatorDashboardSnapshotRefresher` already has stale presence metrics, but they use a single cutoff rather than the FB-019 permission-aware policy.
- `docs/event-cleanup-strategy.md` explicitly calls out that `device_presence` has no `expires_at` and notification queries currently pass no freshness cutoff.
- Presence cleanup remains adjacent but out of scope for the initial targeting policy. Stale presence should be excluded from targeting before deletion/retention policy is solved.

---

## Suggested Issue Slices

## Issue 1 - Add location freshness policy model

### Status
- Completed (2026-05-05)

### Scope
- Define a small, testable policy model that computes `fresh`, `degraded`, or `stale`.
- Inputs should include:
  - `capturedAt`
  - permission mode / `LocationAuth`
  - current server time
- Keep threshold logic isolated from SQL and APNs sending.
- Cover exact boundary behavior for When In Use and Always.
- Decide and document fallback behavior for denied, restricted, not determined, and unknown authorization.

### Relevant feature brief sections
- `Decisions`
- `Target behavior`
- `Constraints / invariants`
- `Acceptance criteria`

### Handoff notes
- Implemented a pure value policy under `Sources/App/Infrastructure/Notifications/LocationFreshnessPolicy.swift`:
  - `LocationFreshnessState` (`fresh`, `degraded`, `stale`)
  - `LocationFreshnessDecision` (`state`, computed `age`)
  - `LocationFreshnessPolicy.decide(capturedAt:locationAuth:now:)`
- Threshold behavior implemented exactly:
  - `whenInUse`: fresh `<=2h`, degraded `>2h && <=24h`, stale `>24h`
  - `always`: fresh `<=6h`, degraded `>6h && <=24h`, stale `>24h`
- Global hard stale threshold enforced at `>24h` for all modes.
- Conservative fallback decision for non-granted/unknown auth (`denied`, `restricted`, `notDetermined`, `unknown`): classify as `stale`.
- Freshness computation is explicitly `capturedAt`-based; policy API does not accept `receivedAt`, `updatedAt`, or `lastSeenAt`.
- Added focused deterministic boundary tests in `Tests/AppTests/LocationFreshnessPolicyTests.swift`.
- No NotificationEngine integration and no delivery behavior change in this slice.

### Files changed
- `Sources/App/Infrastructure/Notifications/LocationFreshnessPolicy.swift`
- `Tests/AppTests/LocationFreshnessPolicyTests.swift`
- `docs/plans/FB-019-progress.md`

### Tests run
- `swift test --filter LocationFreshness`
- `swift test`

---

## Issue 2 - Add missed notification decision persistence

### Status
- Completed (2026-05-05)

### Scope
- Add a dedicated table/model/migration for stale or missed notification decisions.
- Use an idempotent key aligned as closely as practical with the existing delivery ledger identity.
- Record enough context to debug stale suppression without storing raw location.
- Add tests or SQL-level validation for duplicate suppression.

### Relevant feature brief sections
- `Dependencies`
- `Acceptance criteria`
- `Done means`
- `Open questions`

### Handoff notes
- Added a dedicated stale/missed table: `notification_missed_decisions`.
- Kept delivery ledger semantics unchanged; stale misses persist separately from `notification_ledger`.
- Identity decision finalized as:
  - `UNIQUE (installation_id, series_id, revision_urn, mode, reason, miss_reason)`
  - This mirrors delivery identity (`installation_id`, `series_id`, `revision_urn`) and extends with decision context (`mode`, `reason`, `miss_reason`) to keep stale-miss inserts idempotent across retries/re-evaluation.
- Column set implemented:
  - `id`
  - `installation_id` FK -> `device_installations.installation_id` (`ON DELETE CASCADE`)
  - `series_id` FK -> `arcus_series.id` (`ON DELETE CASCADE`)
  - `revision_urn`
  - `mode`
  - `reason`
  - `freshness_state`
  - `miss_reason`
  - `permission_mode`
  - `captured_at`
  - `received_at`
  - `evaluated_at`
  - `created`
- Added `NotificationMissedDecisionModel` and `NotificationMissedDecisionStore.insertStaleMissDecision(...)` using SQL `INSERT ... ON CONFLICT DO NOTHING RETURNING id`.
- Helper returns inserted-vs-existing via `NotificationMissedDecisionInsertResult`.
- Freshness typing uses existing `LocationFreshnessState` from Issue 1 / dependency #52 (no reimplementation).
- No integration into `NotificationSendJob` decision flow yet (deferred to Issue 3 by design).

### Files changed
- `Sources/App/Migrations/CreateNotificationMissedDecisions.swift`
- `Sources/App/Models/Notification/NotificationMissedDecisionModel.swift`
- `Sources/App/configure.swift`
- `Tests/AppTests/NotificationMissedDecisionPersistenceTests.swift`
- `docs/plans/FB-019-progress.md`

### Tests run
- `swift test --filter Missed`
- `swift test`

### Deferred
- NotificationEngine / send-job integration remains deferred to Issue 3.
- No subtitle/candidate SQL/push-delivery behavior changes in this slice.
- No retention/cleanup/metrics changes in this slice.

---

## Issue 3 - Integrate freshness into notification candidate decisions

### Status
- Completed (2026-05-05)

### Scope
- Load candidate presence `captured_at` and installation `location_auth` for H3 and UGC candidates.
- Evaluate freshness before claiming/sending delivery.
- Suppress stale candidates.
- Write missed-decision rows for stale candidates.
- Allow fresh and degraded candidates through the existing delivery path.

### Relevant feature brief sections
- `Target behavior`
- `Constraints / invariants`
- `Acceptance criteria`
- `Done means`

### Handoff notes
- Integrated freshness evaluation in `NotificationSendJob.dispatchNotifications(...)` immediately after candidate selection and before `claimNotificationLedger(...)`.
- Enriched `NotificationCandidate` to carry freshness inputs:
  - `locationAuthRaw` (`device_installations.location_auth`)
  - `capturedAt` (`device_presence.captured_at`)
  - `receivedAt` (`device_presence.received_at`)
- Updated both candidate loaders (`loadH3Candidates`, `loadUGCCandidates`) to select these columns.
- Removed the legacy `freshnessCutoff` argument/branches that filtered on `device_installations.last_seen_at` so FB-019 freshness is exclusively `captured_at` policy-driven.
- Added a small decision seam `deliveryDisposition(for:evaluatedAt:)` in `NotificationSendJob`:
  - `.skipStale` -> persist stale/missed via `NotificationMissedDecisionStore.insertStaleMissDecision(...)`, then skip send path.
  - `.deliver` (fresh/degraded) -> continue unchanged through ledger claim and APNs send.
- Stale/missed writes are idempotent through #53 uniqueness and `ON CONFLICT DO NOTHING`; retries do not duplicate stale rows.
- Existing notification ledger dedupe/idempotency remains intact; stale candidates are evaluated before ledger claim so no stale claims/sends are created.
- Delivered-decision freshness state is currently carried in local decision flow only and not persisted to `notification_ledger` in this slice to avoid widening schema/scope; follow-up remains for downstream usage (#55/#56).

### Files changed
- `Sources/App/Jobs/NotificationSendJob.swift`
- `Tests/AppTests/NotificationSendJobFreshnessDecisionTests.swift`
- `Tests/AppTests/NotificationEngineTests.swift`
- `docs/plans/FB-019-progress.md`

### Tests run
- `swift test --filter LocationFreshness`
- `swift test --filter Notification`
- `swift test --filter Missed`
- `swift test`

### Deferred
- Subtitle wording changes are still deferred (no push copy changes introduced in this issue).
- Delivered freshness-state persistence is deferred to later FB-019 slices (#55/#56) to keep this issue narrow.
- Additional stale-suppression observability/dashboard expansion is deferred.

---

## Issue 4 - Select push subtitle by freshness state

### Status
- Completed (2026-05-05)

### Scope
- Centralize subtitle selection based on freshness state.
- Use `Includes your location` only for fresh current-location warning/watch notifications.
- Use `For your last known area` for degraded warning/watch notifications.
- Preserve existing non-current-area semantics where the feature brief does not require a copy change.
- Add focused notification engine tests.

### Relevant feature brief sections
- `Target behavior`
- `Copy and trust rules`
- `Acceptance criteria`

### Handoff notes
- Threaded only derived freshness context (`LocationFreshnessState`) into notification composition.
- `NotificationEngine.buildNotification(...)` now accepts optional `freshnessState` so copy remains centralized in `NotificationEngine` without passing raw presence models.
- `NotificationSendJob` now forwards the already-computed freshness decision from Issue 3 when building sendable notifications.
- Subtitle selection decision implemented for `.new` warning/watch notifications:
  - `fresh` -> `Includes your location`
  - `degraded` -> `For your last known area`
  - `stale` -> `preconditionFailure` guard because stale candidates should have been filtered before composition in Issue 3.
- Existing subtitle copy for `.update`, `.endedAllClear`, and `.cancelInError` is intentionally preserved unchanged.
- Notification body composition remains unchanged and focused on event content.
- Existing fallback copy for cases without freshness context (e.g., preview/no-candidate flows) is preserved.

### Files changed
- `Sources/App/Infrastructure/Notifications/NotificationEngine.swift`
- `Sources/App/Jobs/NotificationSendJob.swift`
- `Tests/AppTests/NotificationEngineTests.swift`
- `docs/plans/FB-019-progress.md`

### Tests run
- `swift test --filter NotificationEngine`
- `swift test --filter LocationFreshness`
- `swift test`

### Deferred
- Freshness observability/dashboard additions remain deferred to Issue 6 / GitHub #56.

---

## Issue 5 - Record freshness state on delivered decisions

### Status
- Completed (2026-05-06)

### Scope
- Persist freshness state used at decision time for delivered or attempted notification decisions.
- Keep the recorded value stable even if presence changes after the decision.
- Update relevant models, migrations, and tests.

### Relevant feature brief sections
- `Acceptance criteria`
- `Done means`

### Handoff notes
- Added a dedicated ledger migration to persist decision-time freshness on delivery rows:
  - `AddFreshnessStateToNotificationLedger` adds required `notification_ledger.freshness_state`.
- Updated `NotificationLedgerModel` with typed freshness access:
  - `freshnessStateRaw` (stored raw string)
  - computed `freshnessState: LocationFreshnessState`
- Updated `NotificationSendJob.claimNotificationLedger(...)` to accept `freshnessState: LocationFreshnessState` and write it during claim insert.
- Freshness is captured once at decision/claim time and no longer depends on mutable `device_presence` for delivered/failed reporting.
- Stale behavior remains unchanged:
  - stale candidates are still skipped before claim/send
  - stale candidates persist only in `notification_missed_decisions`
  - stale candidates still do not create ledger rows.
- Updated `docs/Sql/NotificationProcessing.sql` to include/group on `notification_ledger.freshness_state` for delivered and failed outcomes.
- Added DB-backed persistence tests for fresh/degraded claim rows and failure-state freshness retention.

### Files changed
- `Sources/App/Migrations/AddFreshnessStateToNotificationLedger.swift`
- `Sources/App/configure.swift`
- `Sources/App/Models/Notification/NotificationLedgerModel.swift`
- `Sources/App/Jobs/NotificationSendJob.swift`
- `Tests/AppTests/NotificationLedgerFreshnessPersistenceTests.swift`
- `Tests/AppTests/NotificationMissedDecisionPersistenceTests.swift`
- `docs/Sql/NotificationProcessing.sql`
- `docs/plans/FB-019-progress.md`

### Tests run
- `swift test --filter NotificationLedgerFreshnessPersistenceTests`
- `swift test --filter NotificationMissedDecisionPersistenceTests`
- `swift test`

---

## Issue 6 - Add freshness observability and validation

### Status
- Completed (2026-05-05)

### Scope
- Add metrics/logging/reporting for:
  - freshness state
  - permission mode
  - delivery outcome
  - stale-miss reason
- Update operator dashboard queries only as much as needed.
- Add or update SQL diagnostic docs.
- Run end-to-end validation where practical.

### Handoff notes
- Added structured stale-skip observability logs in `NotificationSendJob` with:
  - `installation_id`
  - `series_id`
  - `revision_urn`
  - `event_type`
  - `mode`
  - `reason`
  - `freshness_state`
  - `permission_mode`
  - `decision_outcome=missed_stale_location`
  - `miss_reason=stale_location`
  - `decision_persisted` (`inserted` or `already_recorded`)
- Updated no-op attempt classification so stale-only candidate runs are distinguishable:
  - new `notification_send_attempts.no_op_reason` value: `all_candidates_stale_location`
  - existing `all_candidates_previously_claimed` preserved for dedupe-only no-op runs.
- Expanded SQL diagnostics in `docs/Sql/NotificationProcessing.sql`:
  - delivered/failed counts from `notification_ledger`
  - stale-miss counts from `notification_missed_decisions`
  - unified decision-outcome query with dimensions (`freshness_state`, `permission_mode`, `event_type`, `mode`, `reason`, `decision_outcome`, `miss_reason`)
  - attempt-level no-op reason rollup from `notification_send_attempts`
- Dashboard/API changes intentionally deferred: existing dashboard model would require non-trivial schema/section additions for this slice, and SQL/log diagnostics provide immediate production answerability with minimal risk.

### Files changed
- `Sources/App/Jobs/NotificationSendJob.swift`
- `Sources/App/Models/Notification/NotificationSendAttemptModel.swift`
- `Tests/AppTests/LocationFreshnessPolicyTests.swift`
- `Tests/AppTests/NotificationSendJobFreshnessDecisionTests.swift`
- `docs/Sql/NotificationProcessing.sql`
- `docs/plans/FB-019-progress.md`

### Tests run
- `swift test --filter LocationFreshness`
- `swift test --filter NotificationEngine`
- `swift test --filter Missed`
- `swift test --filter OperatorDashboard`
- `swift test`

### Remaining risks / open questions
- Dashboard stale-presence slices still use their existing thresholding surface; this issue only closes delivered/failed ledger freshness persistence and SQL diagnostics grouping.

### Relevant feature brief sections
- `Goals`
- `Dependencies`
- `Acceptance criteria`
- `Done means`

### Handoff notes
- Existing dashboard stale-presence metrics use a flat 6-hour threshold.
- Align dashboard reporting with the FB-019 policy after the core decision path is implemented.
- Do not redesign the dashboard layout unless required by the metric surface.

---

## Open Questions

1. Should denied, restricted, not determined, and unknown authorization modes be treated as When In Use degradation, immediately stale, or a separate ineligible reason?
2. What exact schema and unique constraint should the missed-decision table use?
3. Should stale suppressions be recorded for all event kinds/reasons, or only warning/watch pushes covered by the brief?
4. Should `endedAllClear` and `cancelInError` notifications bypass freshness because they are cleanup/trust messages, or should they follow the same current-location targeting policy?
5. How long should stale presence records and missed-decision records be retained for diagnostics?

---

## Verification Ledger

No FB-019 verification has been run yet.
