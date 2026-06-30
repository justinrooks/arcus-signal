@testable import App
import Foundation
import Testing

@Suite("HRRR Anvil surface profile loading", .serialized)
struct HrrrAnvilSurfaceProfileLoadingTests {
    @Test("loader constructs exactly one matching wrfsfc candidate")
    func loaderConstructsExactlyOneMatchingWrfsfcCandidate() async throws {
        let centroid = StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
        let sourceResolution = HrrrRunResolution(
            targetValidTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            candidates: [
                HrrrRunCandidate(
                    product: .wrfprsf,
                    runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                    forecastHour: 0,
                    fieldSetVersion: .tornadoPressureV2
                ),
                HrrrRunCandidate(
                    product: .wrfprsf,
                    runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 21),
                    forecastHour: 1,
                    fieldSetVersion: .tornadoPressureV2
                )
            ]
        )
        let expectedSurfaceCandidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let subsetLoader = SurfaceProfileStubSubsetLoading { resolution, requestCentroid in
            #expect(resolution.targetValidTime == sourceResolution.targetValidTime)
            #expect(resolution.candidates == [expectedSurfaceCandidate])
            #expect(resolution.candidates.allSatisfy { $0.product == .wrfsfc })
            #expect(requestCentroid == centroid)

            return GribSubsetCacheResult(
                source: HrrrNomadsURLBuilder().makeSourceMetadata(
                    for: expectedSurfaceCandidate,
                    around: requestCentroid
                ),
                localFileURL: URL(fileURLWithPath: "/private/tmp/surface-profile.grib2"),
                byteSize: 1_024,
                fetchedAt: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                expiresAt: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 34),
                cacheHit: false
            )
        }
        let sampler = SurfaceProfileStubFieldSampling { subset, requestCentroid in
            #expect(subset.source.product == .wrfsfc)
            #expect(subset.byteSize == 1_024)
            #expect(requestCentroid == centroid)
            return [
                previewSample("1:0:d=2026060313:HGT:1000 mb:9 hour fcst:lon=-104.47,lat=39.79,val=100")
            ]
        }
        let loader = DefaultHrrrAnvilSurfaceProfileLoader(
            subsetLoader: subsetLoader,
            fieldSampler: sampler
        )

        let result = try await loader.loadSurfaceProfile(
            for: sourceResolution,
            around: centroid
        )

        #expect(result.sourceResolution.candidates == [expectedSurfaceCandidate])
        #expect(result.subsetCacheResult.cacheHit == false)
        #expect(result.samples.count == 1)
    }

    @Test("loader preserves cancellation and does not advance to another cycle")
    func loaderPreservesCancellationAndDoesNotAdvanceToAnotherCycle() async throws {
        let centroid = StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
        let sourceResolution = HrrrRunResolution(
            targetValidTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            candidates: [
                HrrrRunCandidate(
                    product: .wrfprsf,
                    runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                    forecastHour: 0,
                    fieldSetVersion: .tornadoPressureV2
                ),
                HrrrRunCandidate(
                    product: .wrfprsf,
                    runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 21),
                    forecastHour: 1,
                    fieldSetVersion: .tornadoPressureV2
                )
            ]
        )
        let subsetLoader = SurfaceProfileStubSubsetLoading { _, _ in
            throw CancellationError()
        }
        let sampler = SurfaceProfileStubFieldSampling { _, _ in
            Issue.record("Field sampling should not run after cancellation.")
            throw AnvilProfilePreviewError.internalExecutionFailure(reason: "unexpected sampler call")
        }
        let loader = DefaultHrrrAnvilSurfaceProfileLoader(
            subsetLoader: subsetLoader,
            fieldSampler: sampler
        )

        await #expect(throws: CancellationError.self) {
            _ = try await loader.loadSurfaceProfile(
                for: sourceResolution,
                around: centroid
            )
        }

        #expect(subsetLoader.requestCount == 1)
        #expect(sampler.requestCount == 0)
    }
}

private final class SurfaceProfileStubSubsetLoading: StormSetupSubsetLoading, @unchecked Sendable {
    typealias Handler = @Sendable (HrrrRunResolution, StormSetupCentroid) throws -> GribSubsetCacheResult

    private let handler: Handler
    private(set) var requestCount = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func loadFirstAvailableSubset(
        for resolution: HrrrRunResolution,
        around centroid: StormSetupCentroid
    ) async throws -> GribSubsetCacheResult {
        requestCount += 1
        return try handler(resolution, centroid)
    }
}

private final class SurfaceProfileStubFieldSampling: StormSetupFieldSampling, @unchecked Sendable {
    typealias Handler = @Sendable (GribSubsetCacheResult, StormSetupCentroid) throws -> [HrrrFieldSample]

    private let handler: Handler
    private(set) var requestCount = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func sample(
        from subset: GribSubsetCacheResult,
        around centroid: StormSetupCentroid
    ) async throws -> [HrrrFieldSample] {
        requestCount += 1
        return try handler(subset, centroid)
    }

    func sample(
        localFileURL: URL,
        around centroid: StormSetupCentroid
    ) async throws -> [HrrrFieldSample] {
        requestCount += 1
        return try handler(
            GribSubsetCacheResult(
                source: HrrrNomadsURLBuilder().makeSourceMetadata(
                    for: HrrrRunCandidate(
                        runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                        forecastHour: 0
                    ),
                    around: centroid
                ),
                localFileURL: localFileURL,
                byteSize: 0,
                fetchedAt: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                expiresAt: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 34),
                cacheHit: true
            ),
            centroid
        )
    }
}
