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

func previewSample(_ line: String) -> HrrrFieldSample {
    HrrrFieldSample(
        requestedLongitude: -104.4661,
        requestedLatitude: 39.7825,
        point: Wgrib2PointSample.parse(from: line)
    )
}
