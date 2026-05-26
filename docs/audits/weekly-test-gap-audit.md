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
- Implementation recommended: Yes (tests only; no production code changes in this automation)
