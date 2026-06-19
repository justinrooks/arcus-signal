# HRRR Pressure-Level Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add pressure-level HRRR source support without changing the existing surface-product path.

**Architecture:** Keep the current `HrrrRunCandidate` and `StormSetupSourceMetadata` seam. Extend the HRRR product and field-set enums so the NOMADS URL builder can derive file names, variable flags, and level flags from the request profile instead of branching across the pipeline.

**Tech Stack:** Swift, Vapor, `Testing`

---

### Task 1: Extend HRRR source modeling

**Files:**
- Modify: `Sources/App/StormSetup/HrrrSourceModels.swift`
- Test: `Tests/AppTests/StormSetupHrrrSourceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("pressure-level candidates build wrfprsf filenames")
func pressureLevelCandidateUsesPressureFilename() {
    let candidate = HrrrRunCandidate(
        product: .wrfprsf,
        runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
        forecastHour: 9,
        fieldSetVersion: .tornadoPressureV1
    )

    #expect(candidate.fileName == "hrrr.t13z.wrfprsf09.grib2")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StormSetupHrrrSourceTests/pressureLevelCandidateUsesPressureFilename -v`
Expected: FAIL until `HrrrProduct` and `HrrrFieldSetVersion` gain the pressure-level cases.

- [ ] **Step 3: Write minimal implementation**

```swift
enum HrrrProduct: String, Content, Sendable, Equatable {
    case wrfsfc
    case wrfprsf
}

enum HrrrFieldSetVersion: String, Content, Sendable, Equatable {
    case tornadoV1 = "tornado-v1"
    case tornadoPressureV1 = "tornado-pressure-v1"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StormSetupHrrrSourceTests/pressureLevelCandidateUsesPressureFilename -v`
Expected: PASS

### Task 2: Derive NOMADS query flags from the field set

**Files:**
- Modify: `Sources/App/StormSetup/HrrrSourceModels.swift`
- Modify: `Sources/App/StormSetup/HrrrNomadsURLBuilder.swift`
- Test: `Tests/AppTests/StormSetupHrrrSourceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test("pressure-level URL includes pressure variables and levels")
func urlBuilderIncludesPressureFieldSet() throws {
    let candidate = HrrrRunCandidate(
        product: .wrfprsf,
        runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
        forecastHour: 9,
        fieldSetVersion: .tornadoPressureV1
    )
    let centroid = StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
    let urlString = HrrrNomadsURLBuilder()
        .makeSourceMetadata(for: candidate, around: centroid)
        .nomadsURL?
        .absoluteString ?? ""

    #expect(urlString.contains("file=hrrr.t13z.wrfprsf09.grib2"))
    #expect(urlString.contains("var_HGT=on"))
    #expect(urlString.contains("var_TMP=on"))
    #expect(urlString.contains("var_DPT=on"))
    #expect(urlString.contains("var_UGRD=on"))
    #expect(urlString.contains("var_VGRD=on"))
    #expect(urlString.contains("lev_850_mb=on"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StormSetupHrrrSourceTests/urlBuilderIncludesPressureFieldSet -v`
Expected: FAIL until the URL builder reads field-set-specific flags.

- [ ] **Step 3: Write minimal implementation**

```swift
extension HrrrFieldSetVersion {
    var nomadsVariableFlags: [String] { ... }
    var nomadsLevelFlags: [String] { ... }
}

private func percentEncodedQuery(for candidate: HrrrRunCandidate, bbox: StormSetupHrrrBoundingBox) -> String {
    var items: [String] = [
        encodedQueryItem(name: "dir", value: candidate.directoryPath),
        encodedQueryItem(name: "file", value: candidate.fileName)
    ]

    items.append(contentsOf: candidate.fieldSetVersion.nomadsVariableFlags.map { encodedQueryItem(name: $0, value: "on") })
    items.append(contentsOf: candidate.fieldSetVersion.nomadsLevelFlags.map { encodedQueryItem(name: $0, value: "on") })
    ...
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StormSetupHrrrSourceTests/urlBuilderIncludesPressureFieldSet -v`
Expected: PASS

### Task 3: Keep cache identity distinct for pressure-level requests

**Files:**
- Modify: `Sources/App/StormSetup/StormSetupProvider.swift`
- Modify: `Tests/AppTests/StormSetupGribSubsetCacheTests.swift`
- Modify: `Tests/AppTests/StormSetupSnapshotCacheTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@Test("cache keys separate surface and pressure requests")
func cacheKeysSeparateSurfaceAndPressureRequests() throws {
    let centroid = StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
    let surface = HrrrNomadsURLBuilder().makeSourceMetadata(
        for: HrrrRunCandidate(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        ),
        around: centroid
    )
    let pressure = HrrrNomadsURLBuilder().makeSourceMetadata(
        for: HrrrRunCandidate(
            product: .wrfprsf,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9,
            fieldSetVersion: .tornadoPressureV1
        ),
        around: centroid
    )

    #expect(try StormSetupCacheKey(sourceMetadata: surface) != try StormSetupCacheKey(sourceMetadata: pressure))
    #expect(try StormSetupSnapshotCacheKey(h3Cell: 123, sourceMetadata: surface, rulesVersion: .current) != try StormSetupSnapshotCacheKey(h3Cell: 123, sourceMetadata: pressure, rulesVersion: .current))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StormSetupGribSubsetCacheTests/cacheKeysSeparateSurfaceAndPressureRequests -v`
Expected: FAIL until the pressure-level source metadata is wired through consistently.

- [ ] **Step 3: Write minimal implementation**

```swift
private func makeCandidate(from sourceMetadata: StormSetupSourceMetadata) -> HrrrRunCandidate {
    let product = sourceMetadata.product ?? .wrfsfc
    return HrrrRunCandidate(
        model: sourceMetadata.model ?? .hrrr,
        product: product,
        domain: sourceMetadata.domain ?? .conus,
        runTime: sourceMetadata.runTime ?? dateProvider.now(),
        forecastHour: sourceMetadata.forecastHour ?? 0,
        fieldSetVersion: sourceMetadata.fieldSetVersion ?? product.defaultFieldSetVersion
    )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StormSetupGribSubsetCacheTests/cacheKeysSeparateSurfaceAndPressureRequests -v`
Expected: PASS

### Task 4: Verify the full Storm Setup suite

**Files:**
- None

- [ ] **Step 1: Run the full targeted tests**

Run: `swift test --filter StormSetup -v`
Expected: All Storm Setup tests pass, including existing `wrfsfc` coverage.

- [ ] **Step 2: Commit**

```bash
git add Sources/App/StormSetup/HrrrSourceModels.swift Sources/App/StormSetup/HrrrNomadsURLBuilder.swift Sources/App/StormSetup/StormSetupProvider.swift Tests/AppTests/StormSetupHrrrSourceTests.swift Tests/AppTests/StormSetupGribSubsetCacheTests.swift Tests/AppTests/StormSetupSnapshotCacheTests.swift docs/superpowers/plans/2026-06-19-hrrr-pressure-level-support.md
git commit -m "feat: add pressure-level hrrr source support"
```
