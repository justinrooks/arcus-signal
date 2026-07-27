# Weekly Bug Scan

## 2026-05-21

### 1. Repos scanned
- `arcus-signal`
- `project-arcus`

### 2. Commit window inspected
- Last automation run marker: `2026-05-14T16:06:33.583Z`
- Window used: commits after `2026-05-14T16:06:33Z`
- `arcus-signal` commits inspected:
  - `091c45c898343894e06e9c05d0fd976644115e56` (APNs HotAlert payload change)
  - `191dd6b59482461154c540446658c6249914c2a0` (operator dashboard rendering changes)
- `project-arcus` commits inspected:
  - `b5d15fea95d29b430d4304edda3c53ca6c1eab62` (alert architecture streamlining)
  - Other commits in window were release/docs/project metadata updates only.

### 3. Highest-risk changed areas
- Notification delivery payload contract (`arcus-signal` APNs payload generation)
- Remote alert ingestion/update lifecycle (`project-arcus` remote push handling + targeted alert sync)
- Shared API contract between backend APNs payload and iOS decoder (`HotAlertAPNsPayload` / `APNsHotAlertPayloadContract`)

### 4. Findings table

| Bug | Repo | Evidence | Impact | Confidence | Minimal fix | Validation |
|---|---|---|---|---|---|---|
| APNs hot-alert payload sends series UUID as `alertID`, causing targeted remote refresh to query wrong identifier | `arcus-signal` + `project-arcus` | `arcus-signal` `091c45c` sets `hotAlertPayload.alertID` to `payload.seriesId.uuidString` and `seriesId` same value in [`/Users/justin/Code/arcus-signal/Sources/App/Jobs/NotificationSendJob.swift`](/Users/justin/Code/arcus-signal/Sources/App/Jobs/NotificationSendJob.swift:500). iOS resolves `alertID ?? seriesId` and uses it for targeted refresh in [`/Users/justin/Code/project-arcus/Sources/App/RemoteHotAlertHandler.swift`](/Users/justin/Code/project-arcus/Sources/App/RemoteHotAlertHandler.swift:147) and fetch call in [`/Users/justin/Code/project-arcus/Sources/Clients/ArcusClient.swift`](/Users/justin/Code/project-arcus/Sources/Clients/ArcusClient.swift:54). App-side matcher expects canonical alert id semantics in [`/Users/justin/Code/project-arcus/Sources/App/RemoteHotAlertHandler.swift`](/Users/justin/Code/project-arcus/Sources/App/RemoteHotAlertHandler.swift:267). | Missed or failed remote hot-alert updates and deep-link context after push. Background fetch can return `.failed`, reducing reliability of severe-weather alert freshness. | High | Populate APNs `alertID` with the canonical Arcus alert id (NWS/canonical id), not internal series UUID. Keep `seriesId` optional/backward-compatible for transition, but prioritize `alertID` correctness. | Unit: add assertion in `NotificationSendJob` tests that emitted payload `alertID` equals canonical alert identifier. Integration: push -> app receipt -> targeted refresh returns `.newData` for real alert id and not `.failed`. Manual: send test push and confirm alert detail opens with latest revision. Log/metric: track remote ingestion `.failed` rate keyed by source payload id kind. |

### 5. Top recommended fix
- Highest-priority bug: APNs payload identifier mismatch (`alertID` incorrectly uses series UUID).
- Why it matters: it directly affects push-to-refresh correctness during active severe weather and can suppress timely user-visible updates.
- Expected files touched:
  - [`/Users/justin/Code/arcus-signal/Sources/App/Jobs/NotificationSendJob.swift`](/Users/justin/Code/arcus-signal/Sources/App/Jobs/NotificationSendJob.swift)
  - [`/Users/justin/Code/arcus-signal/Tests/AppTests/NotificationSendJobDeliveryBoundaryTests.swift`](/Users/justin/Code/arcus-signal/Tests/AppTests/NotificationSendJobDeliveryBoundaryTests.swift)
  - Optional contract guard in [`/Users/justin/Code/project-arcus/Sources/App/RemoteHotAlertHandler.swift`](/Users/justin/Code/project-arcus/Sources/App/RemoteHotAlertHandler.swift)
- Estimated churn: small (roughly 20-60 LOC).
- Regression risk: low-to-moderate; limited to payload mapping and contract tests.

### 6. Watchlist
- No additional low-confidence bug candidates promoted. Reviewed `191dd6b` dashboard/UI polling changes and did not find concrete correctness/reliability regressions from inspected diff hunks.

### 7. Implementation recommendation
- Implementation is recommended for the APNs `alertID` payload correction.

### 8. Implementation status
- Marked stale on 2026-06-04 after re-checking the shared contract: `ArcusCore/Sources/ArcusCore/HotAlertAPNsPayload.swift` defines `arcusAlertId` as the canonical hot-alert identifier, `project-arcus/docs/audits/weekly-contract-drift-audit.md` already records that contract as resolved, and the current `NotificationSendJob` payload mapping still matches that series-id contract. No backend code change is recommended for this audit item.

### Audit entry (short)
- Date: `2026-05-21`
- Workflow reviewed: weekly bug scan (commits since last run marker)
- Files inspected:
  - `/Users/justin/Code/arcus-signal/Sources/App/Jobs/NotificationSendJob.swift`
  - `/Users/justin/Code/arcus-signal/Sources/App/Clients/APNsClient.swift`
  - `/Users/justin/Code/arcus-signal/Tests/AppTests/NotificationSendJobDeliveryBoundaryTests.swift`
  - `/Users/justin/Code/project-arcus/Sources/App/RemoteHotAlertHandler.swift`
  - `/Users/justin/Code/project-arcus/Sources/Clients/ArcusClient.swift`
  - `/Users/justin/Code/project-arcus/Tests/UnitTests/RemoteHotAlertHandlerTests.swift`
  - `/Users/justin/Code/project-arcus/Sources/Repos/AlertRepo.swift`
- Top finding: APNs payload `alertID` is currently set to `seriesId` UUID instead of canonical alert id.
- Best next fix: map canonical alert id into APNs `alertID` and add contract assertions.
- Implementation recommended: `no` - stale after contract re-check on 2026-06-04

## 2026-05-28

### 1. Repos scanned
- `arcus-signal`
- `project-arcus`

### 2. Commit window inspected
- Last automation run marker: `2026-05-21T16:05:46.968Z`
- Window used: commits after `2026-05-21T16:05:46Z`
- `arcus-signal` commits inspected:
  - `4469c10c667df02bc54711d6566f95b9472bfc90`
  - `c4232cc77d7c565e8eeaeed891fbe5f6427efcee`
  - `2c0103316e7b6a5baf7d82f557cf392e49ae4021`
  - `9d1cacac5923944cf6981c65168f4fa325f5c6e2`
- `project-arcus` commits inspected (high-risk subset):
  - `9c08b1333fa61fce999eaaf87dd818c949ba07c6`
  - `58272f407d67ec04beb14a6fe216d5767cbd988e`
  - `99278828060652975def6648979591d9ceb918fb`
  - `8f1f27209c101f69eaf5516bd0b45f24054133cf`
  - `97391228e63ba88664e6b402cac7e8bf97f928ac`

### 3. Highest-risk changed areas
- alert ingestion/update lifecycle and geometry-first targeting
- notification delivery/APNs payload path
- location/presence + preference upload reliability
- persistence migrations and rollback safety
- shared API contracts (`ArcusCore` payloads across server/app)

### 4. Findings table

| Bug | Repo | Evidence | Impact | Confidence | Minimal fix | Validation |
|---|---|---|---|---|---|---|
| Rollback migration can fail in production-like data after new `source` values are written | `arcus-signal` | `9d1cacac5923944cf6981c65168f4fa325f5c6e2` adds [`/Users/justin/Code/arcus-signal/Sources/App/Migrations/UpdateDevicePresenceSourceConstraintForExpandedLocationUploadSources.swift`](/Users/justin/Code/arcus-signal/Sources/App/Migrations/UpdateDevicePresenceSourceConstraintForExpandedLocationUploadSources.swift). `prepare` allows expanded sources (`foregroundPrime`, `settingsPreference`, etc.), but `revert` re-adds old narrow check (`foreground`, `backgroundRefresh`, `significantChange`, `manual`, `unknown`). Any row inserted after deploy with expanded values violates revert constraint and causes rollback migration failure at `ADD CONSTRAINT`. | Operational reliability risk during rollback/recovery. Failed rollback can prolong incident response and keep deploys stuck while severe-weather notification pipeline is degraded. | High | Keep rollback safe by making `revert` non-breaking for existing rows: either (a) keep expanded allow-list in revert, or (b) map unsupported rows to `unknown` in a data update before re-adding narrow constraint. Smallest safe option: revert to expanded allow-list. | Migration check: apply migration, insert `device_presence.source='settingsPreference'`, run revert, confirm success. Integration: run migrate+revert in ephemeral DB CI job. Log/metric: migration failure count and startup abort reason. |

### 5. Top recommended fix
- Highest-priority bug: rollback migration failure in `UpdateDevicePresenceSourceConstraintForExpandedLocationUploadSources`.
- Why it matters: this is a concrete recoverability bug; rollback paths fail exactly when you need them most.
- Expected files touched:
  - [`/Users/justin/Code/arcus-signal/Sources/App/Migrations/UpdateDevicePresenceSourceConstraintForExpandedLocationUploadSources.swift`](/Users/justin/Code/arcus-signal/Sources/App/Migrations/UpdateDevicePresenceSourceConstraintForExpandedLocationUploadSources.swift)
  - optional migration test file in `Tests/AppTests`
- Estimated churn: very small (roughly 5-25 LOC).
- Regression risk: low (constraint text only, no runtime code path changes).

### 6. Watchlist
- `project-arcus` `99278828060652975def6648979591d9ceb918fb`: [`/Users/justin/Code/project-arcus/Sources/Infrastructure/Location/LocationSession.swift`](/Users/justin/Code/project-arcus/Sources/Infrastructure/Location/LocationSession.swift) methods `syncNotificationPreference(enabled:)` / `syncLocationSharingPreference(enabled:)` ignore their `enabled` argument and rely on downstream state reads. This may be intentional, but it increases race-window risk for stale preference uploads if state persistence timing changes.
- `arcus-signal` `4469c10c667df02bc54711d6566f95b9472bfc90`: `sent` query param is accepted on targeted `/api/v2/alerts` but currently ignored by implementation and docs. Not a correctness bug today, but it can mislead clients expecting freshness gating.

### 7. Implementation recommendation
- Implementation is recommended for the migration rollback bug.

### 8. Implementation status
- Fixed on `2026-06-04` by making the rollback constraint match the expanded allow-list and adding a regression test in `Tests/AppTests/DevicePresenceMigrationTests.swift`.

### Audit entry (short)
- Date: `2026-05-28`
- Workflow reviewed: weekly bug scan (commits since last automation run marker)
- Files inspected:
  - `/Users/justin/Code/arcus-signal/Sources/App/Migrations/UpdateDevicePresenceSourceConstraintForExpandedLocationUploadSources.swift`
  - `/Users/justin/Code/arcus-signal/Sources/App/Controllers/AlertsController.swift`
  - `/Users/justin/Code/arcus-signal/Sources/App/Jobs/IngestNWSAlertsJob.swift`
  - `/Users/justin/Code/arcus-signal/Sources/App/Jobs/TargetEventRevisionJob.swift`
  - `/Users/justin/Code/arcus-signal/Sources/App/Jobs/NotificationSendJob.swift`
  - `/Users/justin/Code/project-arcus/Sources/Infrastructure/Location/LocationSnapshotPusher.swift`
  - `/Users/justin/Code/project-arcus/Sources/Infrastructure/Location/LocationSession.swift`
  - `/Users/justin/Code/project-arcus/Sources/App/RemoteHotAlertHandler.swift`
  - `/Users/justin/Code/project-arcus/Sources/Repos/AlertRepo.swift`
- Top finding: rollback migration for `device_presence.source` can fail with post-deploy rows using expanded source values.
- Best next fix: make migration `revert` path data-safe (prefer expanded allow-list to avoid rollback failure).
- Implementation recommended: `yes`

## 2026-06-04

### 1. Repos scanned
- `arcus-signal`
- `project-arcus`

### 2. Commit window inspected
- Last automation run marker: `2026-05-28T16:06:26.231Z`
- Window used: commits after `2026-05-28T16:06:26Z`
- `arcus-signal` commits inspected: none
- `project-arcus` commits inspected:
  - `a9b833fabf2fa016055433a5924628c34d7fed43`
  - `2ff15307a9a559004b1c8eb48b502a45f5a6a513`

### 3. Highest-risk changed areas
- legacy `MdDTO` persistence / Codable compatibility
- location upload payload decode compatibility
- target/revision dispatch and notification outbox enqueueing
- device presence and H3 targeting

### 4. Findings table

| Bug | Repo | Evidence | Impact | Confidence | Minimal fix | Validation |
|---|---|---|---|---|---|---|
| `TargetEventRevisionJob.persistGeolocation` returns before enqueuing notification dispatch when H3 geometry is unchanged | `arcus-signal` | [`/Users/justin/Code/arcus-signal/Sources/App/Jobs/TargetEventRevisionJob.swift`](/Users/justin/Code/arcus-signal/Sources/App/Jobs/TargetEventRevisionJob.swift) lines 177-188 return `.succeeded` on unchanged geometry. The notification enqueue happens later in the same function, so unchanged polygons never queue the revision’s notification outbox. `queueDispatchMessages` in [`/Users/justin/Code/arcus-signal/Sources/App/Jobs/IngestNWSAlertsJob.swift`](/Users/justin/Code/arcus-signal/Sources/App/Jobs/IngestNWSAlertsJob.swift) only queues UGC fallback for non-polygon shapes, so polygon updates/cancels rely entirely on the H3 path. | Missed severe-weather notifications for updates/cancels that reuse the same polygon, which is a real user-visible awareness failure. | High | Keep the no-op geolocation shortcut, but move notification outbox enqueueing ahead of the unchanged-geometry early return, or split the “unchanged geolocation” and “notification enqueue” responsibilities. | Unit test: add a TargetEventRevisionJob test proving a same-geometry update still queues and drains the H3 notification outbox. Integration test: run the job against a seeded series with existing geolocation and a new revision using the same polygon. Log/metric: count of updated revisions where notification outbox rows are created. |

### 5. Top recommended fix
- Highest-priority bug: unchanged-geometry early return in `TargetEventRevisionJob`.
- Why it matters: polygon-based revisions can silently skip notification fanout even though the alert content changed.
- Expected files touched:
  - [`/Users/justin/Code/arcus-signal/Sources/App/Jobs/TargetEventRevisionJob.swift`](/Users/justin/Code/arcus-signal/Sources/App/Jobs/TargetEventRevisionJob.swift)
  - optional test file under [`/Users/justin/Code/arcus-signal/Tests/AppTests`](/Users/justin/Code/arcus-signal/Tests/AppTests)
- Estimated churn: very small, likely under 30 LOC.
- Regression risk: low if the fix only reorders notification enqueueing and leaves geolocation deduplication intact.

### 6. Watchlist
- `arcus-signal` `IngestNWSAlertsJob.shouldAdvanceSeriesSnapshot(currentSent:incomingSent:)` drops revisions when `event.sent` is nil even though the DTO/model allow nil. That could suppress a rare revision update if upstream omits `sent`, but I did not find a concrete recent payload proving it in this run.
- `project-arcus` `MdDTO` legacy decode fallback uses localized number formatting for `watchProbabilityText`; if a legacy payload ever carries a fractional probability on a locale that formats decimals with commas, the derived text may stop parsing as numeric in `MesoComposer`.

### 7. Implementation recommendation
- Implementation is recommended for the unchanged-geometry notification enqueue bug.

### 8. Implementation status
- Fixed on `2026-06-04` by removing the premature unchanged-geometry return in `TargetEventRevisionJob.persistGeolocation` and adding a regression test in `Tests/AppTests/TargetEventRevisionJobFallbackTests.swift`.

### Audit entry (short)
- Date: `2026-06-04`
- Workflow reviewed: weekly bug scan (audit-only)
- Files inspected:
  - `/Users/justin/Code/project-arcus/Sources/Models/Meso/MdDTO.swift`
  - `/Users/justin/Code/project-arcus/Tests/UnitTests/MdDTOCodableCompatibilityTests.swift`
  - `/Users/justin/Code/arcus-signal/Sources/App/Jobs/TargetEventRevisionJob.swift`
  - `/Users/justin/Code/arcus-signal/Sources/App/Jobs/IngestNWSAlertsJob.swift`
  - `/Users/justin/Code/arcus-signal/Sources/App/Jobs/NotificationSendJob.swift`
  - `/Users/justin/Code/arcus-signal/Sources/App/Controllers/DeviceController.swift`
  - `/Users/justin/Code/arcus-signal/Sources/App/Models/Device/DevicePresenceModel.swift`
- Top finding: unchanged H3 geometry short-circuits notification enqueueing in `TargetEventRevisionJob`.
- Best next fix: enqueue notification outbox before the unchanged-geometry early return.
- Implementation recommended: `yes`

## 2026-07-02

### 1. Repos scanned
- `arcus-signal`

### 2. Commit window inspected
- Last automation run marker: `2026-06-04T16:06:26.231Z`
- Window used: commits after `2026-06-04T16:06:26Z` through `2026-07-01`
- Commits inspected:
  - `49ece86b45f76c6b00a95a63d9c9281b9767f635` (`Fix expanded device presence sources and H3 dispatch regression`)
  - `dd6e7438b90f5cf401a41fd8bb593d36b7e96097` (`Add Storm Setup tornado ingredient snapshots`)
  - `ba97707e1f3bf8223413a86a8b9918b4d6a1c626` (`Add HRRR pressure artifact pipeline and Anvil pressure-profile support`)
  - `852d7f1c1ea36076773b5bcdf04b8cb182be623c` (`Add exact-cycle surface loading for Anvil profile requests`)

### 3. Highest-risk changed areas
- notification delivery and outbox dispatch (`Sources/App/Jobs/TargetEventRevisionJob.swift`, `Sources/App/lib/DispatchAgent.swift`)
- alert ingestion/update lifecycle (`Sources/App/Jobs/IngestNWSAlertsJob.swift`, `Sources/App/Jobs/NotificationSendJob.swift`)
- Storm Setup surface/pressure profile assembly and exact-cycle loading (`Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`, `Sources/App/StormSetup/AnvilProfileRequestBuilder.swift`, `Sources/App/StormSetup/HrrrAnvilSurfaceProfileLoading.swift`)
- pressure-artifact catalog and stale fallback lookup (`Sources/App/StormSetup/PressureArtifactCatalogLookupService.swift`)

### 4. Findings table

| Bug | Repo | Evidence | Impact | Confidence | Minimal fix | Validation |
|---|---|---|---|---|---|---|
| No credible bug found in the inspected window | `arcus-signal` | Reviewed the four commits above plus the changed preview/request-builder/load-path files and their focused tests. I also ran `swift test --filter HrrrAnvilSurfaceProfileLoadingTests`, which passed. | No confirmed defect to fix. | High | None. | No implementation required; continue with the next weekly scan. |

### 5. Top recommended fix
- No fix recommended.
- Why it matters: the inspected changes were internally consistent, and the focused surface-loader test passed.
- Expected files touched: none.
- Estimated churn: none.
- Regression risk: none.

### 6. Watchlist
- `Sources/App/StormSetup/PressureArtifactCatalogLookupService.swift`: stale lookup only considers the first candidate in a resolution. That is documented behavior today, but it should be rechecked if candidate ordering or multi-product resolutions change.
- `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`: exact-cycle surface loading now fails the preview when the surface row is missing or incomplete. I did not find evidence that this is unintended, but it is the main place to revisit if users report lost preview availability.

### 7. Out-of-scope notes
- Sibling repository `project-arcus` was intentionally not scanned in this run.

### 8. No fix recommended
- Evidence inspected: the four commits in the window above, plus the direct code paths for Anvil preview/analysis, surface loading, request assembly, pressure-artifact lookup, and the focused `HrrrAnvilSurfaceProfileLoadingTests` test suite.
- Implementation recommended: `no`

## 2026-07-16

### 1. Repos scanned
- `arcus-signal`

### 2. Commit window inspected
- Last automation run marker: `2026-07-09T16:07:08.815Z`
- Window used: commits after `2026-07-09T16:07:08Z`
- Commits inspected:
  - `a7b277d` (`Separate tornado viability from the Storm Setup current response`)
  - `5514f5a` (`update pkgs and test`)
  - `ffa751e` (`Add current AirNow AQI endpoint`)
  - `139f10b` (`Fix airnow payload parsing, fix airnow api url`)

### 3. Highest-risk changed areas
- AirNow client request construction and payload decoding (`Sources/App/AirQuality/AirNowClient.swift`, `Sources/App/AirQuality/AirNowObservation.swift`)
- Air quality provider normalization and short-lived cache behavior (`Sources/App/AirQuality/AirQualityProvider.swift`)
- Storm Setup current-response contract and tornado-viability response mapping (`Sources/App/StormSetup/StormSetupCurrentResponse.swift`, `Sources/App/StormSetup/StormSetupProvider.swift`)
- Storm Setup controller request validation and response contract (`Sources/App/Controllers/StormSetupController.swift`)

### 4. Findings table

| Bug | Repo | Evidence | Impact | Confidence | Minimal fix | Validation |
|---|---|---|---|---|---|---|
| No credible bug found | `arcus-signal` | Reviewed the four commits above, the changed AirNow and Storm Setup source paths, and the focused tests `AirQualityTests`, `StormSetupCurrentResponseDTOTests`, `StormSetupProviderTests`, and `StormSetupControllerTests`. All targeted tests passed. | No confirmed defect to fix. | High | None. | No implementation required; continue with the next weekly scan. |

### 5. Top recommended fix
- No fix recommended.
- Why it matters: the inspected commit window and the affected request/response paths were internally consistent, and the focused tests passed.
- Expected files touched: none.
- Estimated churn: none.
- Regression risk: none.

### 6. Watchlist
- No low-confidence bug candidates were promoted. The only remaining concern was contract drift risk at the AirNow boundary, but the local tests now cover the current payload shape and the provider/controller behavior.

### 7. Out-of-scope notes
- No sibling repositories were scanned in this run.

### 8. No fix recommended
- Evidence inspected: the four commits in the window above, direct inspection of the AirNow and Storm Setup source paths, and focused `swift test` runs for `AirQualityTests`, `StormSetupCurrentResponseDTOTests`, `StormSetupProviderTests`, and `StormSetupControllerTests`.
- Implementation recommended: `no`

## 2026-07-23

### 1. Repository scanned
- `arcus-signal`

### 2. Commit window inspected
- Last automation run marker: `2026-07-16T16:10:29Z`
- Window used: commits after `2026-07-16T16:10:29Z` through `2026-07-23`
- Commits found: none
- Fallback strategy: current-state inspection on the default branch (`main`) of the three highest-risk areas: notification/outbox delivery, NWS alert lifecycle, and device presence/H3 targeting.

### 3. Highest-risk changed areas
- Notification delivery and exactly-once boundary (`Sources/App/Jobs/NotificationSendJob.swift`, `Sources/App/lib/DispatchAgent.swift`)
- NWS alert expiry/cancellation lifecycle (`Sources/App/Jobs/IngestNWSAlertsJob.swift`, `Sources/App/Models/NWS/ArcusEvent.swift`, `Sources/App/Models/NWS/ArcusSeriesModel.swift`)
- Device presence and H3/UGC targeting (`Sources/App/Jobs/TargetEventRevisionJob.swift`, `Sources/App/Models/Device/DevicePresenceModel.swift`)

### 4. Findings table

| Bug | Repo | Evidence | Impact | Confidence | Minimal fix | Validation |
|---|---|---|---|---|---|---|
| Queued notification jobs can send after an alert ends or is cancelled | `arcus-signal` | `Sources/App/Jobs/NotificationSendJob.swift:138-174` loads the current series and gates only on `currentRevisionUrn`; the end-time filter at line 143 is commented out and no `state` check exists before candidate resolution and APNs delivery. `Sources/App/Models/NWS/ArcusEvent.swift:308-314` derives expired state from `ends`, while `Sources/App/Jobs/IngestNWSAlertsJob.swift:203-228` and `:467-495` persist expired, ended, and cancelled lifecycle states. `Tests/AppTests/NotificationSendJobDeliveryBoundaryTests.swift` covers stale presence and ledger behavior but has no ended/cancelled alert case. | A delayed or retried send-lane job can deliver an obsolete severe-weather warning after it is no longer active, creating a false user-visible awareness signal. | High | Add a single delivery-boundary guard after loading the series that no-ops unless the current series is active and has not passed its authoritative end time. Record a distinct no-op reason for observability. Do not change targeting or outbox architecture. | Unit/integration: seed current-revision series rows in `ended`, `expired`, and `cancelled` states and an active row with `ends <= now`; assert zero sender calls and no ledger claim. Add an active future-ending control that still sends. |

### 5. Top recommended fix
- Highest-priority bug: block APNs delivery for ended, expired, or cancelled current series.
- Why it matters: revision freshness alone does not prove that a severe-weather alert remains active when a queued job finally runs.
- Expected files touched:
  - `Sources/App/Jobs/NotificationSendJob.swift`
  - `Sources/App/Models/Notification/NotificationSendAttemptModel.swift` if a dedicated no-op reason is added
  - `Tests/AppTests/NotificationSendJobDeliveryBoundaryTests.swift`
- Estimated churn: small, approximately 25-60 LOC.
- Regression risk: low; the change narrows delivery at the final boundary without altering ingestion, targeting, or idempotency.

### 6. Watchlist
- `Sources/App/lib/DispatchAgent.swift`: rows are marked `done` only after queue dispatch returns. A database update failure after successful dispatch can enqueue the job more than once, but the notification ledger should prevent duplicate APNs effects. Promote only if logs or a fault-injection test show duplicate sends or a ledger bypass.

### 7. Out-of-scope notes
- Sibling repositories and external client implementations were intentionally not scanned. No cross-repository findings were included.

### 8. Implementation recommendation
- Implementation is recommended for the final delivery-boundary lifecycle guard.
- Focused tests were attempted but SwiftPM manifest evaluation was blocked by the automation sandbox (`sandbox_apply: Operation not permitted`); no test result is claimed.

### Audit entry (short)
- Date: `2026-07-23`
- Repository reviewed: `arcus-signal`
- Workflow reviewed: weekly bug scan (audit-only, high-risk current-state fallback)
- Commit window inspected: after `2026-07-16T16:10:29Z` through `2026-07-23`; no commits found
- Files inspected:
  - `Sources/App/Jobs/NotificationSendJob.swift`
  - `Sources/App/lib/DispatchAgent.swift`
  - `Sources/App/Jobs/IngestNWSAlertsJob.swift`
  - `Sources/App/Jobs/TargetEventRevisionJob.swift`
  - `Sources/App/Models/NWS/ArcusEvent.swift`
  - `Sources/App/Models/NWS/ArcusSeriesModel.swift`
  - `Sources/App/Models/Device/DevicePresenceModel.swift`
  - `Sources/App/Migrations/CreateNotificationOutbox.swift`
  - `Tests/AppTests/NotificationSendJobDeliveryBoundaryTests.swift`
  - `Tests/AppTests/NotificationSendJobFreshnessDecisionTests.swift`
  - `Tests/AppTests/IngestNWSAlertsJobTargetingDecisionTests.swift`
  - `Tests/AppTests/TargetEventRevisionJobFallbackTests.swift`
- Top finding: queued notification jobs can send after the current alert has ended, expired, or been cancelled.
- Best next fix: add an active-lifecycle guard at the start of `NotificationSendJob` delivery and cover it with boundary tests.
- Implementation recommended: `yes`
- Out-of-scope repositories intentionally not scanned: all sibling repositories

### 9. Implementation status
- Fixed on `2026-07-26`.
- `NotificationSendJob` now blocks `.new` and `.update` deliveries before candidate resolution, ledger claiming, and APNs when the series is inactive or its `expires` or `ends` timestamp has elapsed.
- Explicit `.cancelInError` and `.endedAllClear` notifications remain eligible for future intentional terminal-alert workflows.
- Added `inactive_or_expired_series` send-attempt observability and focused unit coverage for inactive states and elapsed/future lifecycle timestamps.
- Validation: `swift test --filter NotificationSendJobFreshnessDecisionTests` passed (7 tests).
- Follow-up fixed on `2026-07-26`: NWS lifecycle classification and cleanup now expire alerts with an elapsed `expires` timestamp when `ends` is absent. Regression coverage verifies both canonical state derivation and persisted-series cleanup.
- Roadmap: APNs failure retry/backoff remains unresolved and is tracked in [GitHub issue #13](https://github.com/justinrooks/arcus-signal/issues/13). The planned slice adds bounded queue retries, exponential backoff, retryable ledger reclaim, and terminal handling for permanent token failures.
