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
    private var callCount = 0

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
    private var callCount = 0

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

actor PreviewStubPressureGribLoader: StormSetupPressureGribLoading {
    private let handler: @Sendable (Int, StormSetupSourceMetadata) async throws -> StormSetupPressureGribCacheResult
    private var callCount = 0

    init(
        handler: @escaping @Sendable (Int, StormSetupSourceMetadata) async throws -> StormSetupPressureGribCacheResult
    ) {
        self.handler = handler
    }

    func loadOrFetch(sourceMetadata: StormSetupSourceMetadata) async throws -> StormSetupPressureGribCacheResult {
        let index = callCount
        callCount += 1
        return try await handler(index, sourceMetadata)
    }
}

actor PreviewStubPressureProfileLoader: HrrrPressureProfileLoading {
    private let handler: @Sendable (Int, HrrrPressureDirectObjectResolution, StormSetupCentroid, Double?) async throws -> HrrrPressureProfileLoadResult
    private var callCount = 0

    init(
        handler: @escaping @Sendable (Int, HrrrPressureDirectObjectResolution, StormSetupCentroid, Double?) async throws -> HrrrPressureProfileLoadResult
    ) {
        self.handler = handler
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

func previewMakePressureCacheResult(
    source: StormSetupSourceMetadata,
    fetchedAt: Date,
    cacheHit: Bool = false
) -> StormSetupPressureGribCacheResult {
    StormSetupPressureGribCacheResult(
        source: source,
        localFileURL: URL(fileURLWithPath: "/private/tmp/anvil-preview-pressure.grib2"),
        downloadURL: source.primaryDownloadURL!,
        idxURL: source.idxURL,
        byteSize: 1024,
        checksumSHA256: "preview-checksum",
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
