@testable import App
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Vapor

func previewWithEnvironment(
    _ overrides: [String: String?],
    test: () async throws -> Void
) async throws {
    let previousValues = overrides.keys.reduce(into: [String: String?]()) { partialResult, key in
        partialResult[key] = Environment.get(key)
    }

    func apply(_ values: [String: String?]) {
        for (key, value) in values {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
    }

    apply(overrides)
    do {
        try await test()
    } catch {
        apply(previousValues)
        throw error
    }
    apply(previousValues)
}

func previewMakeUTCDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int = 0,
    second: Int = 0
) -> Date {
    let components = DateComponents(
        timeZone: TimeZone(secondsFromGMT: 0),
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: second
    )

    guard let date = StormSetupUTC.calendar.date(from: components) else {
        preconditionFailure("Unable to create UTC date for test.")
    }

    return date
}

struct PreviewFixedStormSetupDateProvider: StormSetupDateProviding {
    let nowDate: Date

    func now() -> Date {
        nowDate
    }
}

struct PreviewStaticHrrrRunResolver: HrrrRunResolving {
    let resolution: HrrrRunResolution

    func resolveRunCandidates() -> HrrrRunResolution {
        resolution
    }
}

actor PreviewStubStormSetupSubsetLoader: StormSetupSubsetLoading {
    private let handler: @Sendable (Int, HrrrRunResolution, StormSetupCentroid) async throws -> GribSubsetCacheResult
    private(set) var callCount = 0

    init(
        handler: @escaping @Sendable (Int, HrrrRunResolution, StormSetupCentroid) async throws -> GribSubsetCacheResult
    ) {
        self.handler = handler
    }

    func loadFirstAvailableSubset(
        for resolution: HrrrRunResolution,
        around centroid: StormSetupCentroid
    ) async throws -> GribSubsetCacheResult {
        let index = callCount
        callCount += 1
        return try await handler(index, resolution, centroid)
    }
}

actor PreviewStubPressureSourceResolver: HrrrPressureDirectObjectResolving {
    private let handler: @Sendable (Int, HrrrRunResolution) async throws -> HrrrPressureDirectObjectResolution
    private(set) var callCount = 0

    init(
        handler: @escaping @Sendable (Int, HrrrRunResolution) async throws -> HrrrPressureDirectObjectResolution
    ) {
        self.handler = handler
    }

    func resolveSource(for resolution: HrrrRunResolution) async throws -> HrrrPressureDirectObjectResolution {
        let index = callCount
        callCount += 1
        return try await handler(index, resolution)
    }
}

actor PreviewStubPressureArtifactCatalogLookupService: PressureArtifactCatalogLookupProviding {
    private let handler: @Sendable (HrrrRunCandidate) async throws -> PressureArtifactCatalogReadyArtifact?
    private let staleHandler: @Sendable (HrrrRunResolution) async throws -> PressureArtifactCatalogReadyArtifact?
    private(set) var callCount = 0
    private(set) var staleCallCount = 0

    init(
        handler: @escaping @Sendable (HrrrRunCandidate) async throws -> PressureArtifactCatalogReadyArtifact?,
        staleHandler: @escaping @Sendable (HrrrRunResolution) async throws -> PressureArtifactCatalogReadyArtifact? = { _ in nil }
    ) {
        self.handler = handler
        self.staleHandler = staleHandler
    }

    func readyArtifact(
        for candidate: HrrrRunCandidate
    ) async throws -> PressureArtifactCatalogReadyArtifact? {
        callCount += 1
        return try await handler(candidate)
    }

    func staleArtifact(
        for resolution: HrrrRunResolution
    ) async throws -> PressureArtifactCatalogReadyArtifact? {
        staleCallCount += 1
        return try await staleHandler(resolution)
    }
}

actor PreviewStubPressureProfileLoader: HrrrPressureProfileLoading {
    private let handler: @Sendable (Int, HrrrPressureDirectObjectResolution, StormSetupCentroid, Double?) async throws -> HrrrPressureProfileLoadResult
    private let readyHandler: @Sendable (PressureArtifactCatalogReadyArtifact, StormSetupCentroid, Double?) async throws -> HrrrPressureProfileLoadResult
    private(set) var callCount = 0

    init(
        handler: @escaping @Sendable (Int, HrrrPressureDirectObjectResolution, StormSetupCentroid, Double?) async throws -> HrrrPressureProfileLoadResult
    ) {
        self.handler = handler
        self.readyHandler = { _, _, _ in
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: "ready artifact path was not configured for this test.")
        }
    }

    init(
        handler: @escaping @Sendable (Int, HrrrPressureDirectObjectResolution, StormSetupCentroid, Double?) async throws -> HrrrPressureProfileLoadResult,
        readyHandler: @escaping @Sendable (PressureArtifactCatalogReadyArtifact, StormSetupCentroid, Double?) async throws -> HrrrPressureProfileLoadResult
    ) {
        self.handler = handler
        self.readyHandler = readyHandler
    }

    func loadPressureProfile(
        for sourceResolution: HrrrPressureDirectObjectResolution,
        centroid: StormSetupCentroid,
        surfaceHeightMslM: Double?
    ) async throws -> HrrrPressureProfileLoadResult {
        let index = callCount
        callCount += 1
        return try await handler(index, sourceResolution, centroid, surfaceHeightMslM)
    }

    func loadPressureProfile(
        for readyArtifact: PressureArtifactCatalogReadyArtifact,
        centroid: StormSetupCentroid,
        surfaceHeightMslM: Double?
    ) async throws -> HrrrPressureProfileLoadResult {
        try await readyHandler(readyArtifact, centroid, surfaceHeightMslM)
    }
}

actor PreviewStubSurfaceProfileLoader: HrrrAnvilSurfaceProfileLoading {
    private let handler: @Sendable (Int, HrrrRunResolution, StormSetupCentroid) async throws -> HrrrAnvilSurfaceProfileLoadResult
    private(set) var callCount = 0

    init(
        handler: @escaping @Sendable (Int, HrrrRunResolution, StormSetupCentroid) async throws -> HrrrAnvilSurfaceProfileLoadResult
    ) {
        self.handler = handler
    }

    func loadSurfaceProfile(
        for resolution: HrrrRunResolution,
        around centroid: StormSetupCentroid
    ) async throws -> HrrrAnvilSurfaceProfileLoadResult {
        let index = callCount
        callCount += 1
        return try await handler(index, resolution, centroid)
    }
}

actor PreviewStubStormSetupFieldSampler: StormSetupFieldSampling {
    private let handler: @Sendable (GribSubsetCacheResult, StormSetupCentroid) async throws -> [HrrrFieldSample]

    init(
        handler: @escaping @Sendable (GribSubsetCacheResult, StormSetupCentroid) async throws -> [HrrrFieldSample]
    ) {
        self.handler = handler
    }

    func sample(
        from subset: GribSubsetCacheResult,
        around centroid: StormSetupCentroid
    ) async throws -> [HrrrFieldSample] {
        try await handler(subset, centroid)
    }

    func sample(
        localFileURL: URL,
        around centroid: StormSetupCentroid
    ) async throws -> [HrrrFieldSample] {
        try await handler(
            GribSubsetCacheResult(
                source: StormSetupSourceMetadata(
                    sourceKind: .directObject,
                    model: nil,
                    product: nil,
                    domain: nil,
                    runTime: nil,
                    forecastHour: nil,
                    validTime: nil,
                    fieldSetVersion: nil,
                    primaryDownloadURL: localFileURL
                ),
                localFileURL: localFileURL,
                byteSize: 0,
                fetchedAt: .distantPast,
                expiresAt: .distantFuture,
                cacheHit: true
            ),
            centroid
        )
    }
}

struct PreviewStubAnvilProfilePreviewProvider: AnvilProfilePreviewProviding {
    let result: Result<AnvilAnalyzeProfilePreviewResponse, AnvilProfilePreviewError>

    func previewProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfilePreviewResponse {
        _ = h3Cell
        switch result {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}

func previewMakeSubsetResult(
    source: StormSetupSourceMetadata,
    fetchedAt: Date,
    cacheHit: Bool = false
) -> GribSubsetCacheResult {
    GribSubsetCacheResult(
        source: source,
        localFileURL: URL(fileURLWithPath: "/private/tmp/anvil-preview.grib2"),
        byteSize: 1024,
        fetchedAt: fetchedAt,
        expiresAt: fetchedAt.addingTimeInterval(3600),
        cacheHit: cacheHit
    )
}

func previewMakePressureProfileLoadResult(
    sourceResolution: HrrrPressureDirectObjectResolution,
    fetchedAt: Date,
    subsetCacheHit: Bool = false,
    samples: [HrrrFieldSample]? = nil,
    surfaceHeightMslM: Double? = nil
) -> HrrrPressureProfileLoadResult {
    let inventory = HrrrPressureIdxInventory.parse(
        """
        1:0:d=2026060313:HGT:1000 mb:9 hour fcst:
        2:1487:d=2026060313:TMP:1000 mb:9 hour fcst:
        3:2975:d=2026060313:DPT:1000 mb:9 hour fcst:
        4:4461:d=2026060313:UGRD:1000 mb:9 hour fcst:
        5:5947:d=2026060313:VGRD:1000 mb:9 hour fcst:
        6:7434:d=2026060313:HGT:925 mb:9 hour fcst:
        """
    )
    let selection = HrrrPressureProfileMessageSelector(preferredLevels: [.mb1000]).select(inventory: inventory)
    let byteRangePlan = HrrrGribByteRangePlanner().plan(inventory: inventory, selectedMessages: selection.selectedMessages)
    let subsetCacheResult = previewMakePressureSubsetCacheResult(
        source: sourceResolution.source,
        fetchedAt: fetchedAt,
        cacheHit: subsetCacheHit
    )
    let fieldSamples = samples ?? previewMakePressureSamples(
        level: 1000,
        hgt: 1200,
        tmp: 301.55,
        dpt: 285.45,
        ugrd: -2.1,
        vgrd: 4.6
    )
    let groupedProfile = StormSetupPressureProfileGrouper().group(
        samples: fieldSamples,
        surfaceHeightMslM: surfaceHeightMslM
    )

    return HrrrPressureProfileLoadResult(
        sourceResolution: sourceResolution,
        inventory: inventory,
        selection: selection,
        byteRangePlan: byteRangePlan,
        subsetCacheResult: subsetCacheResult,
        samples: fieldSamples,
        groupedProfile: groupedProfile
    )
}

func previewMakeSurfaceProfileLoadResult(
    sourceResolution: HrrrRunResolution,
    fetchedAt: Date,
    cacheHit: Bool = false,
    samples: [HrrrFieldSample]? = nil
) -> HrrrAnvilSurfaceProfileLoadResult {
    let subsetCacheResult = previewMakeSubsetResult(
        source: HrrrNomadsURLBuilder().makeSourceMetadata(
            for: sourceResolution.primaryCandidate ?? HrrrRunCandidate(
                runTime: fetchedAt,
                forecastHour: 0
            ),
            around: StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
        ),
        fetchedAt: fetchedAt,
        cacheHit: cacheHit
    )

    return HrrrAnvilSurfaceProfileLoadResult(
        sourceResolution: sourceResolution,
        subsetCacheResult: subsetCacheResult,
        samples: samples ?? previewMakeSurfaceSamples()
    )
}

func previewMakeReadyPressureProfileLoadResult(
    readyArtifact: PressureArtifactCatalogReadyArtifact,
    fetchedAt: Date,
    subsetCacheHit: Bool = true,
    samples: [HrrrFieldSample]? = nil,
    surfaceHeightMslM: Double? = nil
) -> HrrrPressureProfileLoadResult {
    let sourceResolution = previewMakeReadyPressureSourceResolution(for: readyArtifact)
    let groupedProfile = StormSetupPressureProfileGrouper().group(
        samples: samples ?? previewMakePressureSamples(
            level: 1000,
            hgt: 1200,
            tmp: 301.55,
            dpt: 285.45,
            ugrd: -2.1,
            vgrd: 4.6
        ),
        surfaceHeightMslM: surfaceHeightMslM
    )
    let requestedLevels = StormSetupPressureLevel.preferredDescending
    let variables = StormSetupPressureProfileVariable.allCases
    let selectedMessages = groupedProfile.retainedLevels.enumerated().flatMap { levelIndex, level in
        variables.enumerated().map { variableIndex, variable in
            HrrrPressureProfileSelectedMessage(
                inventoryIndex: levelIndex * variables.count + variableIndex,
                record: HrrrPressureIdxInventoryRecord(
                    messageNumber: levelIndex * variables.count + variableIndex + 1,
                    byteOffset: Int64((levelIndex * variables.count + variableIndex) * 1_024),
                    dateRunToken: nil,
                    variableToken: variable.rawValue,
                    levelText: "\(level.pressureMb) mb",
                    forecastLabel: "ready artifact",
                    rawLine: "\(level.pressureMb) mb"
                ),
                pressureLevel: StormSetupPressureLevel(rawValue: level.pressureMb) ?? .mb1000,
                variable: variable
            )
        }
    }
    let selection = HrrrPressureProfileMessageSelectionResult(
        requestedLevels: requestedLevels,
        selectedMessages: selectedMessages,
        missingLevels: groupedProfile.missingLevels,
        ignoredRecords: []
    )
    let byteRangePlan = HrrrGribByteRangePlanner().plan(
        inventory: HrrrPressureIdxInventory(records: selection.selectedMessages.map(\.record)),
        selectedMessages: selection.selectedMessages
    )

    return HrrrPressureProfileLoadResult(
        sourceResolution: sourceResolution,
        inventory: HrrrPressureIdxInventory(records: selection.selectedMessages.map(\.record)),
        selection: selection,
        byteRangePlan: byteRangePlan,
        subsetCacheResult: previewMakePressureSubsetCacheResult(
            source: sourceResolution.source,
            fetchedAt: fetchedAt,
            cacheHit: subsetCacheHit
        ),
        samples: samples ?? previewMakePressureSamples(
            level: 1000,
            hgt: 1200,
            tmp: 301.55,
            dpt: 285.45,
            ugrd: -2.1,
            vgrd: 4.6
        ),
        groupedProfile: groupedProfile
    )
}

func previewMakePressureSubsetCacheResult(
    source: StormSetupSourceMetadata,
    fetchedAt: Date,
    cacheHit: Bool = false
) -> HrrrPressureSubsetGribCacheResult {
    HrrrPressureSubsetGribCacheResult(
        source: source,
        localFileURL: URL(fileURLWithPath: "/private/tmp/anvil-preview-pressure-subset.grib2"),
        byteSize: 1024,
        checksumSHA256: "preview-checksum",
        fetchedAt: fetchedAt,
        expiresAt: fetchedAt.addingTimeInterval(3600),
        cacheHit: cacheHit
    )
}

func previewMakeSurfaceSamples(
    pressurePa: Double = 94_000,
    heightMslM: Double = 1_234,
    temperatureK: Double = 295.15,
    dewpointK: Double = 289.15,
    uWindMs: Double = -4.25,
    vWindMs: Double = 6.5
) -> [HrrrFieldSample] {
    [
        previewSample("1:0:d=2026060313:PRES:surface:9 hour fcst:lon=-104.47,lat=39.79,val=\(pressurePa)"),
        previewSample("2:0:d=2026060313:HGT:surface:9 hour fcst:lon=-104.47,lat=39.79,val=\(heightMslM)"),
        previewSample("3:0:d=2026060313:TMP:2 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=\(temperatureK)"),
        previewSample("4:0:d=2026060313:DPT:2 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=\(dewpointK)"),
        previewSample("5:0:d=2026060313:UGRD:10 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=\(uWindMs)"),
        previewSample("6:0:d=2026060313:VGRD:10 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=\(vWindMs)")
    ]
}

func previewMakeSurfaceLevel(
    pressurePa: Double = 94_000,
    heightMslM: Double = 1_234,
    temperatureK: Double = 295.15,
    dewpointK: Double = 289.15,
    uWindMs: Double = -4.25,
    vWindMs: Double = 6.5
) -> StormSetupPressureProfileLevel {
    StormSetupPressureProfileLevel(
        pressureMb: Int((pressurePa / 100).rounded()),
        heightMslM: heightMslM,
        temperatureC: temperatureK - 273.15,
        dewpointC: dewpointK - 273.15,
        uWindMs: uWindMs,
        vWindMs: vWindMs
    )
}

func previewMakeReadyPressureArtifact(
    runTime: Date,
    forecastHour: Int,
    validTime: Date,
    localPath: String = "/private/tmp/anvil-preview-pressure-artifact.grib2",
    byteSize: Int64 = 1024,
    product: HrrrProduct = .wrfprsf,
    fieldSetVersion: HrrrFieldSetVersion = .tornadoPressureV2,
    freshness: PressureArtifactCatalogReadyArtifactFreshness = .exact
) -> PressureArtifactCatalogReadyArtifact {
    PressureArtifactCatalogReadyArtifact(
        runTime: runTime,
        forecastHour: forecastHour,
        validTime: validTime,
        product: product,
        fieldSetVersion: fieldSetVersion,
        localFileURL: URL(fileURLWithPath: localPath),
        byteSize: byteSize,
        freshness: freshness
    )
}

private func previewMakeReadyPressureSourceResolution(
    for readyArtifact: PressureArtifactCatalogReadyArtifact
) -> HrrrPressureDirectObjectResolution {
    let candidate = HrrrRunCandidate(
        product: readyArtifact.product,
        runTime: readyArtifact.runTime,
        forecastHour: readyArtifact.forecastHour,
        fieldSetVersion: readyArtifact.fieldSetVersion
    )
    let source = StormSetupSourceMetadata(
        sourceKind: .directObject,
        model: candidate.model,
        product: candidate.product,
        domain: candidate.domain,
        runTime: candidate.runTime,
        forecastHour: candidate.forecastHour,
        validTime: readyArtifact.validTime,
        fieldSetVersion: candidate.fieldSetVersion,
        primaryDownloadURL: readyArtifact.localFileURL
    )

    return HrrrPressureDirectObjectResolution(
        candidate: candidate,
        source: source,
        idxProbe: HrrrRemoteObjectProbeResult(
            url: readyArtifact.localFileURL,
            available: false,
            status: nil
        ),
        gribProbe: nil
    )
}

func previewMakePressureSamples(
    level: Int,
    hgt: Double,
    tmp: Double,
    dpt: Double,
    ugrd: Double,
    vgrd: Double
) -> [HrrrFieldSample] {
    [
        previewSample("1:0:d=2026060313:HGT:\(level) mb:9 hour fcst:lon=-104.47,lat=39.79,val=\(hgt)"),
        previewSample("2:0:d=2026060313:TMP:\(level) mb:9 hour fcst:lon=-104.47,lat=39.79,val=\(tmp)"),
        previewSample("3:0:d=2026060313:DPT:\(level) mb:9 hour fcst:lon=-104.47,lat=39.79,val=\(dpt)"),
        previewSample("4:0:d=2026060313:UGRD:\(level) mb:9 hour fcst:lon=-104.47,lat=39.79,val=\(ugrd)"),
        previewSample("5:0:d=2026060313:VGRD:\(level) mb:9 hour fcst:lon=-104.47,lat=39.79,val=\(vgrd)")
    ]
}

func previewMakeEightLevelPressureSamples() -> [HrrrFieldSample] {
    previewMakePressureSamples(
        level: 1000,
        hgt: 1200,
        tmp: 301.55,
        dpt: 285.45,
        ugrd: -2.1,
        vgrd: 4.6
    ) + previewMakePressureSamples(
        level: 925,
        hgt: 1500,
        tmp: 295.95,
        dpt: 283.25,
        ugrd: -5.4,
        vgrd: 7.9
    ) + previewMakePressureSamples(
        level: 850,
        hgt: 1800,
        tmp: 290.65,
        dpt: 284.35,
        ugrd: -6.25,
        vgrd: 8.75
    ) + previewMakePressureSamples(
        level: 700,
        hgt: 2450,
        tmp: 283.15,
        dpt: 274.15,
        ugrd: -12.5,
        vgrd: 14.2
    ) + previewMakePressureSamples(
        level: 600,
        hgt: 4100,
        tmp: 275.85,
        dpt: 266.75,
        ugrd: -15.25,
        vgrd: 18.4
    ) + previewMakePressureSamples(
        level: 500,
        hgt: 5600,
        tmp: 268.95,
        dpt: 261.15,
        ugrd: -18.75,
        vgrd: 22.0
    ) + previewMakePressureSamples(
        level: 400,
        hgt: 7100,
        tmp: 258.75,
        dpt: 252.35,
        ugrd: -23.5,
        vgrd: 27.8
    ) + previewMakePressureSamples(
        level: 300,
        hgt: 9300,
        tmp: 246.15,
        dpt: 240.35,
        ugrd: -28.9,
        vgrd: 31.4
    )
}

func previewSample(_ line: String) -> HrrrFieldSample {
    HrrrFieldSample(
        requestedLongitude: -104.4661,
        requestedLatitude: 39.7825,
        point: Wgrib2PointSample.parse(from: line)
    )
}
