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
- Implementation recommended: `yes`
