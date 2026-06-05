# Weekly Test Gap Audit

## 2026-05-26
- Repos scanned: `project-arcus` (SkyAware), `arcus-signal`, `ArcusCore`
- Commit window: last 7 days (`2026-05-19` to `2026-05-26` MDT), because no prior automation marker existed
- High-risk areas inspected:
  - `arcus-signal` alert targeting/dispatch fallbacks (`IngestNWSAlertsJob`, `TargetEventRevisionJob`)
  - `arcus-signal` APNs payload construction and `/api/v2/alerts` targeted lookup (`NotificationSendJob`, `APNsClient`, `AlertsController`)
  - `project-arcus` remote hot-alert parsing and geometry-first active alert matching (`RemoteHotAlertHandler`, `AlertRepo`)
  - `project-arcus` location upload durability/dedupe/drain behavior (`LocationSnapshotPusher`, `LocationSession`, `RemoteNotificationRegistrar`)
  - `ArcusCore` shared APNs payload Codable contract (`HotAlertAPNsPayload`)
- Top recommended test: add `TargetEventRevisionJob` fallback-path test that asserts unsupported geometry triggers UGC notification dispatch enqueue + UGC drain (and does not run H3 drain in that path)
- Watchlist:
  - targeted `/api/v2/alerts?id=...&sent=...` currently accepts `sent` but server-side targeted query does not filter by it; likely intentional, but contract expectation should be clarified before adding strict tests
- Implementation recommended: no - handled on 2026-06-04 by [`/Users/justin/Code/arcus-signal/Tests/AppTests/TargetEventRevisionJobFallbackTests.swift`](/Users/justin/Code/arcus-signal/Tests/AppTests/TargetEventRevisionJobFallbackTests.swift)

### 6. Implementation status
- Added a regression test for the fallback path: unsupported geometry now asserts UGC notification dispatch enqueue + UGC drain without running the H3 drain path.

## 2026-06-02
- Repos scanned: `project-arcus` (SkyAware), `arcus-signal`, `ArcusCore`
- Commit window: since last automation run (`2026-05-26T15:00:38Z` to `2026-06-02T00:00:00-06:00`)
- High-risk areas inspected:
  - `arcus-signal` device preference sync endpoint and expanded `device_presence.source` constraint (`DeviceController`, `UpdateDevicePresenceSourceConstraintForExpandedLocationUploadSources`)
  - `project-arcus` location/preference upload reliability, explicit-source fallback, SPC batch persistence, mesoscale notification copy, and `MdDTO` Codable compatibility
  - `ArcusCore` shared device preference DTOs and `LocationUploadSource`
- Top recommended test: add an `arcus-signal` endpoint test proving `POST /api/v1/devices/location-snapshots` accepts newly introduced `LocationUploadSource` values and persists them without triggering the client’s legacy `"unknown"` fallback path
- Watchlist:
  - `project-arcus` `HTTPDevicePreferenceSyncUploader` still treats 2xx response decoding as best-effort; current evidence does not justify a stricter test yet because the client ignores malformed success bodies by design
- Implementation recommended: no - handled on 2026-06-04 by [`/Users/justin/Code/arcus-signal/Tests/AppTests/DeviceControllerTests.swift`](/Users/justin/Code/arcus-signal/Tests/AppTests/DeviceControllerTests.swift)

### 6. Implementation status
- Added a controller regression test that posts `LocationUploadSource.settingsPreference` and `LocationUploadSource.foregroundPrime` through `/api/v1/devices/location-snapshots` and asserts the persisted `device_presence.source` matches the submitted value.
