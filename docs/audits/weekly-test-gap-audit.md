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

## 2026-06-09
- Repos scanned: `arcus-signal`
- Commit window: since the last automation run (`2026-06-02T15:07:36Z` to `2026-06-09`)
- High-risk areas inspected:
  - `Sources/App/StormSetup/StormSetupProvider.swift` candidate fallback and normalized-data failure handling
  - `Sources/App/StormSetup/HrrrRunResolver.swift` and `Sources/App/StormSetup/HrrrSourceModels.swift` HRRR candidate windowing and source metadata
  - `Sources/App/StormSetup/StormSetupConfiguration.swift` packaged `wgrib2` default selection
  - `Tests/AppTests/StormSetupProviderTests.swift`, `Tests/AppTests/StormSetupHrrrSourceTests.swift`, `Tests/AppTests/StormSetupConfigurationTests.swift`, `Tests/AppTests/StormSetupWgrib2ClientTests.swift`
- Files inspected:
  - `Sources/App/StormSetup/StormSetupProvider.swift`
  - `Sources/App/StormSetup/HrrrRunResolver.swift`
  - `Sources/App/StormSetup/HrrrSourceModels.swift`
  - `Sources/App/StormSetup/StormSetupConfiguration.swift`
  - `Sources/App/StormSetup/GribAdapter.swift`
  - `Tests/AppTests/StormSetupProviderTests.swift`
  - `Tests/AppTests/StormSetupHrrrSourceTests.swift`
  - `Tests/AppTests/StormSetupConfigurationTests.swift`
  - `Tests/AppTests/StormSetupWgrib2ClientTests.swift`
- Existing relevant tests found:
  - `StormSetupProviderTests` covers snapshot cache hit/miss, a fallback from subset download failure, and `wgrib2` sampling failure classification
  - `StormSetupHrrrSourceTests` covers ordered candidate generation, lookback trimming, and NOMADS URL construction
  - `StormSetupConfigurationTests` covers local defaults, packaged `wgrib2` selection, and environment overrides
- Top recommended test: add a `StormSetupProviderTests` case proving that a valid first HRRR candidate with zero recognizable normalized fields still falls back to the next candidate instead of failing the whole snapshot request
- Watchlist items: none
- Implementation recommended: yes
- Implementation status: added [`/Users/justin/Code/arcus-signal/Tests/AppTests/StormSetupProviderTests.swift`](/Users/justin/Code/arcus-signal/Tests/AppTests/StormSetupProviderTests.swift) regression coverage for empty-normalization fallback
- Out-of-scope repositories intentionally not scanned: none

## 2026-06-28
- Repository reviewed: `arcus-signal`
- Commit window inspected: since the last automation run (`2026-06-16T15:02:20Z` through `2026-06-22T09:16:42-06:00`)
- High-risk areas inspected: `Tests/AppTests/HrrrPressureSubsetGribCacheTests.swift` and `Sources/App/StormSetup/HrrrPressureSubsetGribCache.swift`
- Existing relevant tests found: `HrrrPressureSubsetGribCacheTests` now includes cache hit/miss, corruption recovery, and expiry invalidation coverage
- Top recommended test: already implemented
- Watchlist items: none
- Implementation recommended: no
- Implementation status: implemented on 2026-06-28 by [`/Users/justin/Code/arcus-signal/Tests/AppTests/HrrrPressureSubsetGribCacheTests.swift`](/Users/justin/Code/arcus-signal/Tests/AppTests/HrrrPressureSubsetGribCacheTests.swift)
- Out-of-scope repositories intentionally not scanned: none

## 2026-07-07
- Repository reviewed: `arcus-signal`
- Commit window inspected: since the last automation run (`2026-06-30T15:00:37.541Z` through `2026-07-07T00:00:00-06:00`); commits `852d7f1c1ea36076773b5bcdf04b8cb182be623c` and `4c1da3bdd50e2cd5f919e4fb9ac1bccf07716ce8`
- High-risk areas inspected:
  - `Sources/App/Clients/NwsClient.swift` NWS active-alert URL construction and supported-event whitelist
  - `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift` exact-cycle surface loading and preview fallback behavior
  - `Sources/App/StormSetup/AnvilProfileRequestBuilder.swift` surface-row assembly
  - `Sources/App/StormSetup/HrrrAnvilSurfaceProfileLoading.swift`
  - `Sources/App/StormSetup/AnvilSurfaceProfileNormalizer.swift`
- Files inspected:
  - `Sources/App/Clients/NwsClient.swift`
  - `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`
  - `Sources/App/StormSetup/AnvilProfileRequestBuilder.swift`
  - `Sources/App/StormSetup/HrrrAnvilSurfaceProfileLoading.swift`
  - `Sources/App/StormSetup/AnvilSurfaceProfileNormalizer.swift`
  - `Sources/App/StormSetup/StormSetupSurfaceProfileModels.swift`
  - `Tests/AppTests/AppTests.swift`
  - `Tests/AppTests/AnvilProfilePreviewProviderTests.swift`
  - `Tests/AppTests/AnvilProfileRequestBuilderTests.swift`
  - `Tests/AppTests/HrrrAnvilSurfaceProfileLoadingTests.swift`
  - `Tests/AppTests/AnvilSurfaceProfileNormalizerTests.swift`
- Existing relevant tests found:
  - `Tests/AppTests/AppTests.swift` covers NWS DTO mapping and confirms `Special Weather Statement` is preserved in event mapping, but it does not exercise `NwsHttpClient` request construction
  - `Tests/AppTests/AnvilProfilePreviewProviderTests.swift` covers exact-cycle surface loading, failure handling, and no-fallback behavior
  - `Tests/AppTests/AnvilProfileRequestBuilderTests.swift` covers surface-row prepend, ordering, and rejection paths
  - `Tests/AppTests/HrrrAnvilSurfaceProfileLoadingTests.swift` covers exact-cycle surface candidate construction and cancellation
  - `Tests/AppTests/AnvilSurfaceProfileNormalizerTests.swift` covers unit normalization and invalid-field rejection
- Recommended test gaps table:
  - Behavior: `NwsHttpClient.fetchActiveAlertsJsonData()` should keep building `/alerts/active` with `status=actual`, `region_type=land`, and the curated `event` whitelist, including the newly enabled severe-weather types
  - Repo: `arcus-signal`
  - Evidence: commit `4c1da3bdd50e2cd5f919e4fb9ac1bccf07716ce8` updated [`/Users/justin/Code/arcus-signal/Sources/App/Clients/NwsClient.swift`](/Users/justin/Code/arcus-signal/Sources/App/Clients/NwsClient.swift#L39) and [`/Users/justin/Code/arcus-signal/Sources/App/Clients/NwsClient.swift`](/Users/justin/Code/arcus-signal/Sources/App/Clients/NwsClient.swift#L137); implemented by [`/Users/justin/Code/arcus-signal/Tests/AppTests/NwsClientTests.swift`](/Users/justin/Code/arcus-signal/Tests/AppTests/NwsClientTests.swift)
  - Risk reduced: prevents silent drops in the NWS ingest filter that would hide user-visible severe-weather alerts
  - Test type: unit
  - Suggested test name: `fetchActiveAlertsJsonDataBuildsSupportedEventQuery`
  - Size: XS
  - Confidence: Medium
- Top recommended test: already implemented on 2026-07-07 by [`/Users/justin/Code/arcus-signal/Tests/AppTests/NwsClientTests.swift`](/Users/justin/Code/arcus-signal/Tests/AppTests/NwsClientTests.swift)
- Watchlist items: none
- Implementation recommended: no
- Implementation status: implemented on 2026-07-07 by [`/Users/justin/Code/arcus-signal/Tests/AppTests/NwsClientTests.swift`](/Users/justin/Code/arcus-signal/Tests/AppTests/NwsClientTests.swift)
- Out-of-scope repositories intentionally not scanned: none
