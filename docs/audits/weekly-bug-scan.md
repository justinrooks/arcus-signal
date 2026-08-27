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

## 2026-08-13

### 1. Repository scanned
- `arcus-signal`

### 2. Commit window inspected
- Reliable previous end marker: `51f4259b06f1e851f97ee37742e3384fe005f21a` from the 2026-08-06 audit entry
- Window used: commits after `51f4259b06f1e851f97ee37742e3384fe005f21a` through `8985a4d89e22b31bc6951acfbe3ba2886a973991`
- Dates: `2026-08-06T12:34:12-06:00` through `2026-08-10T08:11:36-06:00`
- Commit count: 7
- Start commit: `8ededc70f7fcef9f99cf251d34269dbed52fde8b`
- End commit: `8985a4d89e22b31bc6951acfbe3ba2886a973991`
- Fallback strategy: none; the bounded window contained commits

### 3. High-risk areas inspected
- Pressure-artifact HTTP request deadlines and transport failure classification (`Sources/App/Infrastructure/Networking/HTTPDataDownloader.swift`, pressure downloaders and caches)
- Warm attempt timeout, claim fencing, failure completion, and bounded acquisition retry (`Sources/App/StormSetup/PressureArtifactWarmingService.swift`, `Sources/App/Jobs/PressureArtifactWarmJob.swift`, `Sources/App/Jobs/PressureArtifactFailureCompletionJob.swift`)
- Abandoned Redis queue-job recovery before worker startup (`Sources/App/Worker/ModelArtifactQueueRecovery.swift`, `Sources/App/Worker/WorkerRuntime.swift`)
- Pressure-artifact backlog health and dashboard compatibility (`Sources/App/lib/OperatorDashboardSnapshotRefresher.swift`, `Sources/App/Models/API/OperatorDashboardSnapshotResponse.swift`)
- Prior probe dispatch-failure finding (`Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift`, `Sources/App/Models/Data/PressureArtifactCatalogStore.swift`)

### 4. Findings
- New findings: none.
- Changed findings: none.
- Recurring finding: `BUG-SIGNAL-PRESSURE-PROBE-ENQUEUE-OVERWRITE` remains present at current `HEAD`. `PressureArtifactCatalogStore.markProbeFailure` still updates by artifact identity without a pending-state or ownership predicate. No materially new evidence, severity change, blast-radius change, or remediation improvement was found, so the normalized finding is not repeated. Existing GitHub issue: [#198](https://github.com/justinrooks/arcus-signal/issues/198) (open).
- Resolved findings: none.

### 5. Watchlist
- None. The newly added timeout, retry, fenced failure-completion, startup recovery, and backlog-health paths had direct focused coverage and no concrete unsupported failure path was found.

### 6. Top finding and best next fix
- Top finding: recurring `BUG-SIGNAL-PRESSURE-PROBE-ENQUEUE-OVERWRITE`.
- Best next fix: constrain probe failure persistence to the probe-owned pending transition and add ambiguous-dispatch regression coverage, as already scoped in issue #198.
- Implementation recommended: `yes`, through the existing issue; no new issue is warranted.

### 7. Validation
- `swift test --filter PressureArtifactWarmJobTests` passed (32 tests).
- `swift test --filter PressureArtifactFailureCompletionJobTests` passed (8 tests).
- `swift test --filter ModelArtifactQueueRecoveryTests` passed (13 tests).
- `swift test --filter OperatorDashboardPressureArtifactTests` passed (11 tests).
- `swift test --filter HRRRPressureArtifactProbeServiceTests` passed (12 tests).
- Total focused validation: 76 tests passed.

### 8. GitHub triage
- GitHub issues created: none.
- GitHub issues updated: none; no materially new evidence justified a repetitive comment or edit.
- Existing issues referenced: [#198](https://github.com/justinrooks/arcus-signal/issues/198).

### 9. Files inspected
- `Sources/App/Infrastructure/Networking/HTTPDataDownloader.swift`
- `Sources/App/Jobs/PressureArtifactFailureCompletionJob.swift`
- `Sources/App/Jobs/PressureArtifactWarmJob.swift`
- `Sources/App/Models/API/OperatorDashboardSnapshotResponse.swift`
- `Sources/App/Models/Data/PressureArtifactCatalogStore.swift`
- `Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift`
- `Sources/App/StormSetup/PressureArtifactWarmingService.swift`
- `Sources/App/Worker/ModelArtifactQueueRecovery.swift`
- `Sources/App/Worker/WorkerRuntime.swift`
- `Sources/App/lib/OperatorDashboardSnapshotRefresher.swift`
- `Tests/AppTests/HRRRPressureArtifactProbeServiceTests.swift`
- `Tests/AppTests/ModelArtifactQueueRecoveryTests.swift`
- `Tests/AppTests/OperatorDashboardPressureArtifactTests.swift`
- `Tests/AppTests/PressureArtifactFailureCompletionJobTests.swift`
- `Tests/AppTests/PressureArtifactWarmJobTests.swift`

### 10. Scope notes
- Repository scanned: `arcus-signal` only.
- Out-of-scope repositories: all sibling repositories and external clients were intentionally not scanned.
- Skipped evidence: no cross-repository claims were evaluated or included.

### Audit entry (short)
- Date: `2026-08-13`
- Repository reviewed: `arcus-signal`
- Workflow reviewed: weekly bug scan (audit-only, commits since the reliable previous end marker)
- Commit window inspected: `8ededc70f7fcef9f99cf251d34269dbed52fde8b` through `8985a4d89e22b31bc6951acfbe3ba2886a973991`; 7 commits
- Files inspected: pressure-artifact HTTP deadlines, warm timeout/retry/failure completion, abandoned-job recovery, backlog health, prior probe failure transition, and focused tests listed above
- Top finding: recurring probe enqueue failure can overwrite pressure-artifact work already advanced to `warming` or `ready`
- Best next fix: implement existing issue #198; no duplicate issue or repetitive update
- Implementation recommended: `yes`, through existing issue #198
- Out-of-scope repositories intentionally not scanned: all sibling repositories

### 9. Implementation status
- Fixed on `2026-07-26`.
- `NotificationSendJob` now blocks `.new` and `.update` deliveries before candidate resolution, ledger claiming, and APNs when the series is inactive or its `expires` or `ends` timestamp has elapsed.
- Explicit `.cancelInError` and `.endedAllClear` notifications remain eligible for future intentional terminal-alert workflows.
- Added `inactive_or_expired_series` send-attempt observability and focused unit coverage for inactive states and elapsed/future lifecycle timestamps.
- Validation: `swift test --filter NotificationSendJobFreshnessDecisionTests` passed (7 tests).
- Follow-up fixed on `2026-07-26`: NWS lifecycle classification and cleanup now expire alerts with an elapsed `expires` timestamp when `ends` is absent. Regression coverage verifies both canonical state derivation and persisted-series cleanup.
- Roadmap: APNs failure retry/backoff remains unresolved and is tracked in [GitHub issue #13](https://github.com/justinrooks/arcus-signal/issues/13). The planned slice adds bounded queue retries, exponential backoff, retryable ledger reclaim, and terminal handling for permanent token failures.

## 2026-07-30

### 1. Repository scanned
- `arcus-signal`

### 2. Commit window inspected
- Last automation run marker: `2026-07-23T16:07:02.928Z`
- Window used: commits after `2026-07-23T16:07:02Z` through `2026-07-30`
- Commits inspected:
  - `c539de30e3f22fdab9e1d6a8d5c2dbba580003b8` (`Harden NWS alert lifecycle and notification delivery (#151)`)
  - `254728f4c54816e59a06bd4422418f75a57c7267` (`Filter notification candidates by 24-hour presence freshness (#152)`)
  - `45b636218ab262ed9bbf8a7022e7cb16f3d30024` (`Document architecture recovery plan and execution guardrails (#172)`)
  - `a12d34e26c757b691bb97412b43f0bdb6ed9f9ba` (`Centralize HRRR surface-to-pressure identity (#173)`)
  - `9fbb0f2260dd215dedee8c5de4af37b7d8d3a95f` (`Extract pure H3 coverage result (#174)`)
  - `7feb0ada715baf7e3b26d7641c194963d145dc17` (`Move H3 computation before the transaction (#175)`)
  - `a4b9f436bdc8ed87380f45bdf64f6f5796c8595d` (`Isolate notification candidate selection #158`)

### 3. Highest-risk changed areas
- NWS alert lifecycle and final delivery eligibility (`Sources/App/Jobs/IngestNWSAlertsJob.swift`, `Sources/App/Jobs/NotificationSendJob.swift`, `Sources/App/Models/NWS/ArcusEvent.swift`)
- Candidate freshness and H3/UGC selection (`Sources/App/Infrastructure/Notifications/LocationFreshnessPolicy.swift`, `Sources/App/Models/Notification/NotificationCandidateStore.swift`)
- H3 coverage computation, persistence transaction, and notification outbox dispatch (`Sources/App/Jobs/H3CoverageBuilder.swift`, `Sources/App/Jobs/TargetEventRevisionJob.swift`)
- HRRR surface-to-pressure artifact identity (`Sources/App/StormSetup/HrrrSourceModels.swift`, `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`, `Sources/App/StormSetup/HrrrPressureDirectObjectResolver.swift`)

### 4. Findings table

| Bug | Repo | Evidence | Impact | Confidence | Minimal fix | Validation |
|---|---|---|---|---|---|---|
| No credible bug found | `arcus-signal` | Reviewed all seven commits and the changed lifecycle, candidate-query, H3 targeting, and HRRR identity paths. Focused suites passed: `NotificationSendJobCandidateQueryTests` (3), `H3CoverageBuilderTests` (6), `TargetEventRevisionJobFallbackTests` (5), `StormSetupHrrrSourceTests` (16), and `NotificationSendJobFreshnessDecisionTests` (7). | No confirmed defect to fix. | High | None. | No implementation required; continue with the next weekly scan. |

### 5. Top recommended fix
- No fix recommended.
- Why it matters: the prior lifecycle finding is fixed, candidate freshness remains enforced after extraction, and H3 computation moved outside the transaction without breaking persistence, fallback, or notification dispatch behavior.
- Expected files touched: none.
- Estimated churn: none.
- Regression risk: none.

### 6. Watchlist
- No low-confidence concern met the evidence threshold. Future-dated presence was considered, but `Sources/App/Controllers/DeviceController.swift` rejects timestamps more than five minutes ahead, so the local evidence does not support a bug finding.

### 7. Out-of-scope notes
- All sibling repositories and external client implementations were intentionally not scanned. No cross-repository findings were included.

### 8. No fix recommended
- Evidence inspected: seven commits in the bounded window; direct inspection of NWS lifecycle cleanup and delivery gates, H3/UGC candidate queries, H3 coverage construction and transaction boundaries, HRRR surface-to-pressure identity, and the five focused test suites listed above.
- Implementation recommended: `no`

### Audit entry (short)
- Date: `2026-07-30`
- Repository reviewed: `arcus-signal`
- Workflow reviewed: weekly bug scan (audit-only, commits since last automation run)
- Commit window inspected: after `2026-07-23T16:07:02Z` through `2026-07-30`; seven commits
- Files inspected:
  - `Sources/App/Clients/NwsClient.swift`
  - `Sources/App/Infrastructure/Notifications/LocationFreshnessPolicy.swift`
  - `Sources/App/Jobs/H3CoverageBuilder.swift`
  - `Sources/App/Jobs/IngestNWSAlertsJob.swift`
  - `Sources/App/Jobs/NotificationSendJob.swift`
  - `Sources/App/Jobs/TargetEventRevisionJob.swift`
  - `Sources/App/Models/NWS/ArcusEvent.swift`
  - `Sources/App/Models/Notification/NotificationCandidateStore.swift`
  - `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`
  - `Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift`
  - `Sources/App/StormSetup/HrrrPressureDirectObjectResolver.swift`
  - `Sources/App/StormSetup/HrrrSourceModels.swift`
  - `Tests/AppTests/H3CoverageBuilderTests.swift`
  - `Tests/AppTests/NotificationSendJobCandidateQueryTests.swift`
  - `Tests/AppTests/NotificationSendJobFreshnessDecisionTests.swift`
  - `Tests/AppTests/StormSetupHrrrSourceTests.swift`
  - `Tests/AppTests/TargetEventRevisionJobFallbackTests.swift`
- Top finding: no credible bug found
- Best next fix: no fix recommended; retain the current focused regression coverage
- Implementation recommended: `no`
- Out-of-scope repositories intentionally not scanned: all sibling repositories
## 2026-08-06

### 1. Repository scanned
- `arcus-signal`

### 2. Commit window inspected
- Reliable previous end marker: `7d0f7bc51423f0f0df64663ffb02be1d872c302b` from the 2026-07-30 audit entry
- Window used: commits after `7d0f7bc51423f0f0df64663ffb02be1d872c302b` through `51f4259b06f1e851f97ee37742e3384fe005f21a`
- Dates: `2026-07-30T11:36:38-06:00` through `2026-08-02T13:05:34-06:00`
- Commit count: 13
- Start commit: `ed27578baabd48f63cb74c4dfb0f51ba1a154e0e`
- End commit: `51f4259b06f1e851f97ee37742e3384fe005f21a`
- Fallback strategy: none; the bounded window contained commits

### 3. Highest-risk changed areas
- Pressure-artifact catalog claims, probe transitions, cleanup, and warming completion (`Sources/App/Models/Data/PressureArtifactCatalogStore.swift`, `Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift`, `Sources/App/StormSetup/PressureArtifactWarmingService.swift`)
- Storm Setup cache I/O and Anvil evidence orchestration (`Sources/App/StormSetup/GribSubsetCache.swift`, `Sources/App/StormSetup/StormSetupSnapshotCache.swift`, `Sources/App/StormSetup/StormSetupProvider.swift`, `Sources/App/StormSetup/StormSetupAnvilEvidencePolicy.swift`)
- Child-process cancellation and output draining (`Sources/App/StormSetup/GribAdapter.swift`)
- NWS persistence and notification ledger ownership (`Sources/App/Services/NWSIngestPersistence.swift`, `Sources/App/Models/Notification/NotificationDeliveryStore.swift`)
- Device-presence migration repair (`Sources/App/Migrations/RepairDevicePresenceSourceConstraintForExpandedLocationUploadSources.swift`)

### 4. Findings

#### BUG-SIGNAL-PRESSURE-PROBE-ENQUEUE-OVERWRITE

- Finding ID: `BUG-SIGNAL-PRESSURE-PROBE-ENQUEUE-OVERWRITE`
- Fingerprint: `weekly-bug-scan|arcus-signal|HRRRPressureArtifactProbeService.markProbeFailure|unconditional-post-dispatch-state-overwrite`
- Repository: `arcus-signal`
- Audit type: Weekly Bug Scan
- Title: Probe enqueue failure can overwrite active or completed pressure-artifact work
- Status: `NEW`
- Severity: `MEDIUM`
- Confidence: `MEDIUM`
- First observed: `2026-08-06`
- Last verified: `2026-08-06`
- Affected files and symbols: `Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift` (`probe`), `Sources/App/Models/Data/PressureArtifactCatalogStore.swift` (`markProbeFailure`), `Sources/App/StormSetup/PressureArtifactWarmingService.swift` (`warm`, `claimCatalogRow`, `markReady`)
- Failure mode: The probe changes a row to `pending`, dispatches `PressureArtifactWarmJob`, and treats any dispatch error as proof that the job was not accepted. If queue acceptance succeeds but the dispatcher throws afterward, the worker may advance the row to `warming` or `ready` before the probe catch path executes. `markProbeFailure` updates by artifact identity without a status or ownership predicate, so it can erase an active claim or replace a valid ready artifact with `failed`, clearing `local_path` and `byte_size`.
- Evidence: Commit `1f5cda034628b4ae806cfca541e522353307c9e5` centralized the transition while preserving its behavior. `HRRRPressureArtifactProbeService.probe` claims at lines 204-223, dispatches at 225-230, and calls `markProbeFailure` for a non-cancellation error at 244-251. `PressureArtifactCatalogStore.markProbeFailure` at lines 474-499 has no current-state or ownership predicate. `PressureArtifactWarmingService` can legitimately claim the pending row at lines 112-117 and complete it ready at 288-304. The existing dispatch-failure test covers only a dispatcher that throws without advancing the row.
- Blast radius: Affected cycles can lose current pressure-profile evidence until a later probe and warm cycle recovers the artifact, degrading Storm Setup analysis. Reachability is limited to ambiguous queue-dispatch failures, but the state mutation can discard completed work.
- Minimal fix strategy: Make probe-failure persistence compare-and-set against the probe-owned pending transition so it cannot mutate `warming` or `ready`. Preserve the ordinary pre-enqueue failure behavior. Avoid broader queue or retry redesign.
- Required validation: Deterministic integration tests that advance the row to `warming` and `ready` before the dispatcher throws, proving lease/claim and artifact metadata remain intact; retain the ordinary dispatch-failure test; run `HRRRPressureArtifactProbeServiceTests` and `PressureArtifactWarmJobTests`.
- Related GitHub issue: [#198](https://github.com/justinrooks/arcus-signal/issues/198)
- Triage: `ACTIONABLE`

### 5. Watchlist
- None. No lower-confidence candidate in the bounded window had enough concrete local evidence to retain.

### 6. Resolved findings
- None re-verified in this bounded window.

### 7. Top finding
- `BUG-SIGNAL-PRESSURE-PROBE-ENQUEUE-OVERWRITE`

### 8. Best next fix
- Add an ownership/current-state predicate to probe failure persistence and regression-test ambiguous dispatch outcomes where the worker has already reached `warming` or `ready`.
- Expected files: `Sources/App/Models/Data/PressureArtifactCatalogStore.swift`, optionally `Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift`, and `Tests/AppTests/HRRRPressureArtifactProbeServiceTests.swift`.
- Estimated churn: small, approximately 30-70 LOC.
- Regression risk: low to medium; the ordinary pre-enqueue error path must continue to become `failed`.
- Implementation recommended: `yes`

### 9. Validation
- `swift test --filter HRRRPressureArtifactProbeServiceTests` passed (11 tests).
- `swift test --filter PressureArtifactWarmJobTests` passed (18 tests).
- `swift test --filter ProcessRunnerTests` passed (9 tests).
- `swift test --filter StormSetupAnvilEvidencePolicyTests` passed (6 tests).
- `swift test --filter StormSetupGribSubsetCacheTests` passed (13 tests).
- `swift test --filter StormSetupSnapshotCacheTests` passed (14 tests).
- Total focused validation: 71 tests passed.

### 10. GitHub triage
- GitHub issues created: [#198](https://github.com/justinrooks/arcus-signal/issues/198)
- GitHub issues updated: none
- Existing issues referenced: none; searches by finding mechanism and affected subsystem found no equivalent open issue

### 11. Files inspected
- `Sources/App/Models/Data/PressureArtifactCatalogStore.swift`
- `Sources/App/Models/Notification/NotificationDeliveryStore.swift`
- `Sources/App/Services/NWSIngestPersistence.swift`
- `Sources/App/StormSetup/APIDependencyComposition.swift`
- `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`
- `Sources/App/StormSetup/GribAdapter.swift`
- `Sources/App/StormSetup/GribSubsetCache.swift`
- `Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift`
- `Sources/App/StormSetup/PressureArtifactCleanupService.swift`
- `Sources/App/StormSetup/PressureArtifactWarmingService.swift`
- `Sources/App/StormSetup/StormSetupAnvilEvidencePolicy.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Sources/App/StormSetup/StormSetupSnapshotCache.swift`
- `Sources/App/Migrations/RepairDevicePresenceSourceConstraintForExpandedLocationUploadSources.swift`
- `Tests/AppTests/HRRRPressureArtifactProbeServiceTests.swift`
- `Tests/AppTests/PressureArtifactWarmJobTests.swift`
- `Tests/AppTests/ProcessRunnerTests.swift`
- `Tests/AppTests/StormSetupAnvilEvidencePolicyTests.swift`
- `Tests/AppTests/StormSetupGribSubsetCacheTests.swift`
- `Tests/AppTests/StormSetupSnapshotCacheTests.swift`

### 12. Scope notes
- Repository scanned: `arcus-signal` only.
- Out-of-scope repositories: all sibling repositories and external clients were intentionally not scanned.
- Skipped evidence: no cross-repository claims were evaluated or included.

### Audit entry (short)
- Date: `2026-08-06`
- Repository reviewed: `arcus-signal`
- Workflow reviewed: weekly bug scan (audit-only, commits since the reliable previous end marker)
- Commit window inspected: `ed27578baabd48f63cb74c4dfb0f51ba1a154e0e` through `51f4259b06f1e851f97ee37742e3384fe005f21a`; 13 commits
- Files inspected: pressure-artifact catalog/probe/warm/cleanup paths, Storm Setup cache and evidence orchestration, child-process cancellation, NWS persistence, notification ledger ownership, migration repair, and focused tests listed above
- Top finding: probe enqueue failure can overwrite pressure-artifact work that a worker has already advanced to `warming` or `ready`
- Best next fix: constrain `markProbeFailure` to the probe-owned pending state and add deterministic ambiguous-dispatch regression tests
- Implementation recommended: `yes`
- Out-of-scope repositories intentionally not scanned: all sibling repositories

## 2026-08-20

### 1. Repository scanned
- `arcus-signal`

### 2. Commit window inspected
- Reliable previous end marker: `8985a4d89e22b31bc6951acfbe3ba2886a973991` from the 2026-08-13 audit entry
- Window used: commits after `8985a4d89e22b31bc6951acfbe3ba2886a973991` through `563bdb0d3f63df49a67f7d8fb20bad287811288b`
- Dates: `2026-08-13T11:54:39-06:00` through `2026-08-13T16:46:49-06:00`
- Commit count: 8
- Start commit: `b5e08e633529b8028c49d344e5e42465debd38f2`
- End commit: `563bdb0d3f63df49a67f7d8fb20bad287811288b`
- Fallback strategy: none; the bounded window contained commits

### 3. High-risk areas inspected
- Authoritative installation/presence transition detection and transactional outbox creation (`Sources/App/Controllers/DeviceController.swift`, `Sources/App/Infrastructure/Notifications/PresenceReconciliationTrigger.swift`)
- Durable reconciliation handoff, scheduled drain, and retry/idempotency behavior (`Sources/App/Models/Notification/PresenceReconciliationOutboxStore.swift`, `Sources/App/Jobs/DispatchPresenceReconciliationScheduledJob.swift`, `Sources/App/Jobs/ReconcileInstallationAlertsJob.swift`)
- Active-alert H3/UGC matching and installation-constrained notification delivery (`Sources/App/Models/Notification/NotificationCandidateStore.swift`, `Sources/App/Jobs/NotificationSendJob.swift`)
- Installation-growth dashboard aggregation and rendering (`Sources/App/lib/OperatorDashboardSnapshotRefresher.swift`, `Sources/App/lib/OperatorDashboardPageRenderer.swift`)

### 4. Findings

#### BUG-SIGNAL-PRESENCE-PREFERENCE-RECONCILIATION

- Finding ID: `BUG-SIGNAL-PRESENCE-PREFERENCE-RECONCILIATION`
- Fingerprint: `weekly-bug-scan|arcus-signal|DeviceController.createPreferences|usable-installation-transition-without-reconciliation-intent`
- Repository: `arcus-signal`
- Audit type: Weekly Bug Scan
- Title: Preference sync can restore delivery eligibility without reconciling active alerts
- Status: `NEW`
- Severity: `MEDIUM`
- Confidence: `MEDIUM`
- First observed: `2026-08-20`
- Last verified: `2026-08-20`
- Affected files and symbols: `Sources/App/Controllers/DeviceController.swift` (`createPreferences`, `create`), `Sources/App/Infrastructure/Notifications/PresenceReconciliationTrigger.swift` (`decide`, `isUsable`)
- Failure mode: The location-snapshot route captures previous installation/presence state, persists both, evaluates whether the installation became usable, transactionally inserts a reconciliation intent, and performs post-commit queue handoff. The preferences route can independently change `isSubscribed`, APNs token, or location authorization while fresh targetable presence already exists, but it only upserts `device_installations`. An unusable-to-usable preference transition therefore creates no reconciliation intent and does not rediscover matching active alerts until a later qualifying location snapshot.
- Evidence: Commit `31651e819170697dc4f88374c38c3301c0315d1a` added transition evaluation to `DeviceController.create`. Current `DeviceController.swift` lines 108-186 contain previous/current state evaluation, transactional intent creation, and handoff for location snapshots; lines 267-281 show `createPreferences` only updating the installation. `PresenceReconciliationTrigger.swift` lines 65-99 explicitly treats subscription, activity, APNs token, and location authorization as usability gates and returns `becameUsable` for recovery. Existing controller tests exercise a subscription recovery only through the location-snapshot route; no preference-sync test covers existing fresh presence.
- Blast radius: Users who restore notification eligibility through preference sync can miss already-active severe-weather alerts matching their stored location. Future alert revisions still use the alert-driven path, and a later qualifying location heartbeat can recover the gap.
- Minimal fix strategy: Apply the existing previous/current state evaluation and transactional outbox insertion to the preferences route when fresh targetable presence exists, then use the existing post-commit handoff. Keep the slice controller-local and avoid worker or notification-pipeline changes.
- Required validation: Route-level tests for unsubscribed-to-subscribed recovery with existing fresh presence, unchanged/no-op preference updates, unusable states, transaction rollback on intent failure, and queue-handoff failure retention; run `DeviceControllerTests` and `LocationDrivenAlertReconciliationFlowTests` with PostgreSQL available.
- Related GitHub issue: creation attempted on `2026-08-20` but blocked because the GitHub connector required approval while the automation approval policy was `never`; no issue was created and no prohibited fallback was used.
- Triage: `ACTIONABLE`

### 5. Recurring findings
- `BUG-SIGNAL-PRESSURE-PROBE-ENQUEUE-OVERWRITE` remains represented by open GitHub issue [#198](https://github.com/justinrooks/arcus-signal/issues/198). The bounded commit window did not touch its failure mechanism, so the normalized finding is not repeated.

### 6. Watchlist
- None. No additional candidate met the evidence threshold.

### 7. Resolved findings
- None re-verified in this bounded window.

### 8. Top finding and best next fix
- Top finding: `BUG-SIGNAL-PRESENCE-PREFERENCE-RECONCILIATION`.
- Best next fix: make preference-sync usability recovery create and hand off the existing durable reconciliation intent.
- Expected files: `Sources/App/Controllers/DeviceController.swift` and `Tests/AppTests/DeviceControllerTests.swift`.
- Estimated churn: small, approximately 40-90 LOC.
- Regression risk: low to medium; preserve transactional intent insertion and avoid duplicate intents for unchanged preferences.
- Implementation recommended: `yes`

### 9. Validation
- Static execution-path inspection completed for all eight commits and the focused production/test files listed below.
- `swift test --filter DeviceControllerTests` attempted; build passed, but all 12 selected tests were blocked by unavailable PostgreSQL at `127.0.0.1:5432` (`connection refused`).
- Later focused suites in the chained command did not run after the first suite failed.

### 10. GitHub triage
- Deduplication searches by finding mechanism, route symbol, and impact found no equivalent issue.
- GitHub issues created: none; the authorized creation attempt failed because the GitHub connector required approval under an approval policy of `never`.
- GitHub issues updated: none.
- Existing issues referenced: [#198](https://github.com/justinrooks/arcus-signal/issues/198).

### 11. Files inspected
- `Sources/App/Controllers/DeviceController.swift`
- `Sources/App/Infrastructure/Notifications/PresenceReconciliationTrigger.swift`
- `Sources/App/Jobs/DispatchPresenceReconciliationScheduledJob.swift`
- `Sources/App/Jobs/NotificationSendJob.swift`
- `Sources/App/Jobs/ReconcileInstallationAlertsJob.swift`
- `Sources/App/Migrations/CreatePresenceReconciliationOutbox.swift`
- `Sources/App/Models/Notification/NotificationCandidateStore.swift`
- `Sources/App/Models/Notification/PresenceReconciliationOutboxStore.swift`
- `Sources/App/configure.swift`
- `Sources/App/lib/OperatorDashboardPageRenderer.swift`
- `Sources/App/lib/OperatorDashboardSnapshotRefresher.swift`
- `Tests/AppTests/DeviceControllerTests.swift`
- `Tests/AppTests/InstallationAlertReconciliationJobTests.swift`
- `Tests/AppTests/LocationDrivenAlertReconciliationFlowTests.swift`
- `Tests/AppTests/NotificationActiveAlertQueryTests.swift`
- `Tests/AppTests/PresenceReconciliationOutboxTests.swift`
- `Tests/AppTests/PresenceReconciliationTriggerTests.swift`
- `docs/architecture.md`

### 12. Scope notes
- Repository scanned: `arcus-signal` only.
- Out-of-scope repositories: all sibling repositories and external clients were intentionally not scanned.
- Skipped evidence: no cross-repository claims were evaluated or included.

### Audit entry (short)
- Date: `2026-08-20`
- Repository reviewed: `arcus-signal`
- Workflow reviewed: weekly bug scan (audit-only, commits since the reliable previous end marker)
- Commit window inspected: `b5e08e633529b8028c49d344e5e42465debd38f2` through `563bdb0d3f63df49a67f7d8fb20bad287811288b`; 8 commits
- Files inspected: presence transition policy, API persistence/intent boundary, reconciliation handoff and worker, active-alert matching, constrained notification delivery, installation-growth dashboard, and focused tests listed above
- Top finding: preference sync can restore delivery eligibility without reconciling already-active alerts
- Best next fix: apply the existing transactional transition/intent pattern to `createPreferences` and add route-level regression coverage
- Implementation recommended: `yes`
- GitHub issue creation: attempted but blocked by connector approval requirements; no issue created
- Out-of-scope repositories intentionally not scanned: all sibling repositories

## 2026-08-27

### 1. Repository scanned
- `arcus-signal`

### 2. Commit window inspected
- Reliable previous end marker: `563bdb0d3f63df49a67f7d8fb20bad287811288b` from the 2026-08-20 audit entry
- Window used: commits after `563bdb0d3f63df49a67f7d8fb20bad287811288b` through `e957a454b2f1bcbd336abb66a162659cbc2a0a95`
- Dates: `2026-08-26T12:08:09-06:00` through `2026-08-26T12:08:09-06:00`
- Commit count: 1
- Start and end commit: `e957a454b2f1bcbd336abb66a162659cbc2a0a95`
- Fallback strategy: none; the bounded window contained one commit

### 3. Files and high-risk areas inspected
- Subprocess launch, output capture, timeout, cancellation, termination, and descriptor ownership (`Sources/App/StormSetup/GribAdapter.swift`, `Tests/AppTests/ProcessRunnerTests.swift`)
- Stale notification-revision suppression at the final send boundary (`Tests/AppTests/NotificationSendJobDeliveryBoundaryTests.swift`)
- API collection scalar normalization (`arcus-signal.postman_collection/Arcus Signal API/.resources/definition.yaml`)
- Living delivery and runtime contracts (`docs/architecture.md`)

### 4. Findings
- No new credible bug was found. New findings by confidence: `HIGH 0`, `MEDIUM 0`, `LOW 0`.

### 5. Recurring, changed, and resolved findings
- Recurring findings re-verified: none.
- Changed findings: none.
- The commit did not touch `BUG-SIGNAL-PRESSURE-PROBE-ENQUEUE-OVERWRITE` or `BUG-SIGNAL-PRESENCE-PREFERENCE-RECONCILIATION`; neither is repeated or reclassified.
- The descriptor fix corresponds to earlier `BUG-SIGNAL-PROCESS-PIPE-FD-LEAK`, but its Linux-only runtime regression could not be independently executed here, so resolution is not newly asserted.

### 6. Watchlist
- None. No low-confidence concern had sufficient local evidence to retain.

### 7. Top finding and best next fix
- Top finding: none.
- Best next fix: no fix recommended.
- Implementation recommended: `no`; expected churn and regression risk are none.

### 8. Validation
- Static inspection covered the complete production diff and focused tests in commit `e957a454b2f1bcbd336abb66a162659cbc2a0a95`.
- The commit records 10 passing `ProcessRunnerTests` and 9 passing `NotificationSendJobDeliveryBoundaryTests`.
- A local `ProcessRunnerTests` attempt was blocked before manifest compilation because the managed sandbox denied SwiftPM's sandbox operation. No local pass is claimed.

### 9. GitHub triage
- GitHub issues created: none.
- GitHub issues updated: none.
- Existing issues referenced: none for a new finding.
- No candidate met issue eligibility, so remote deduplication and mutation were unnecessary.

### 10. Scope notes
- Repository scanned: `arcus-signal` only.
- Out-of-scope repositories: all sibling repositories and external clients were intentionally not scanned.
- Skipped evidence: no cross-repository claims were evaluated or included.
- Unrelated working-tree change preserved: `docs/Sql/Device.sql`.

### 11. No fix recommended
- The single bounded commit fixes subprocess descriptor ownership, adds focused regression coverage, and exposes no concrete correctness, reliability, privacy, notification, or severe-weather-awareness regression.

### Audit entry (short)
- Date: `2026-08-27`
- Repository reviewed: `arcus-signal`
- Workflow reviewed: weekly bug scan (audit-only, commits since the reliable previous end marker)
- Commit window inspected: `e957a454b2f1bcbd336abb66a162659cbc2a0a95`; 1 commit
- Files inspected: `Sources/App/StormSetup/GribAdapter.swift`, `Tests/AppTests/ProcessRunnerTests.swift`, `Tests/AppTests/NotificationSendJobDeliveryBoundaryTests.swift`, `arcus-signal.postman_collection/Arcus Signal API/.resources/definition.yaml`, and `docs/architecture.md`
- Top finding: no credible bug found
- Best next fix: no fix recommended
- Implementation recommended: `no`
- GitHub issues created: none
- GitHub issues updated: none
- Existing issues referenced: none for a new finding
- Out-of-scope repositories intentionally not scanned: all sibling repositories
