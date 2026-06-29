@testable import App
import Foundation
import Testing

@Suite("Anvil profile analysis provider", .serialized)
struct AnvilProfileAnalysisProviderTests {
    @Test("analysis provider forwards the preview request to Anvil and returns the combined response")
    func analysisProviderForwardsPreviewRequestToAnvilAndReturnsCombinedResponse() async throws {
        let previewResponse = makePreviewResponse()
        let expectedAnvilResponse = makeAnvilResponse()
        let previewProvider = PreviewStubAnvilProfilePreviewProvider(result: .success(previewResponse))
        let client = AnalysisStubAnvilProfileClient(response: expectedAnvilResponse)
        let provider = DefaultAnvilProfileAnalysisProvider(
            previewProvider: previewProvider,
            anvilClient: client
        )

        let response = try await provider.analyzeProfile(for: 617_700_169_958_293_503)

        #expect(response.request == previewResponse.request)
        #expect(response.debug == previewResponse.debug)
        #expect(response.response == expectedAnvilResponse)
        #expect(client.requestCount == 1)
        #expect(client.recordedRequests.first == previewResponse.request)
    }

    @Test("analysis provider propagates cancellation from preview generation")
    func analysisProviderPropagatesCancellationFromPreviewGeneration() async throws {
        let previewProvider = CancellationThrowingAnvilProfilePreviewProvider()
        let client = AnalysisStubAnvilProfileClient(response: makeAnvilResponse())
        let provider = DefaultAnvilProfileAnalysisProvider(
            previewProvider: previewProvider,
            anvilClient: client
        )

        await #expect(throws: CancellationError.self) {
            _ = try await provider.analyzeProfile(for: 617_700_169_958_293_503)
        }

        #expect(client.requestCount == 0)
    }

    @Test("analysis provider propagates cancellation from the Anvil client")
    func analysisProviderPropagatesCancellationFromTheAnvilClient() async throws {
        let previewProvider = PreviewStubAnvilProfilePreviewProvider(result: .success(makePreviewResponse()))
        let client = AnalysisStubAnvilProfileClient(error: CancellationError())
        let provider = DefaultAnvilProfileAnalysisProvider(
            previewProvider: previewProvider,
            anvilClient: client
        )

        await #expect(throws: CancellationError.self) {
            _ = try await provider.analyzeProfile(for: 617_700_169_958_293_503)
        }

        #expect(client.requestCount == 1)
    }

    @Test("analysis provider fails before preview work when Anvil analysis configuration is missing")
    func analysisProviderFailsBeforePreviewWorkWhenAnvilAnalysisConfigurationIsMissing() async throws {
        let previewProvider = RecordingAnvilProfilePreviewProvider(result: .success(makePreviewResponse()))
        let configuration = StormSetupConfiguration(
            gribSubsetCacheRootURL: URL(fileURLWithPath: "/tmp/grib-subsets"),
            pressureGribSubsetCacheRootURL: URL(fileURLWithPath: "/tmp/pressure-grib-subsets"),
            sampledSnapshotCacheRootURL: URL(fileURLWithPath: "/tmp/sampled-snapshots"),
            gribSubsetCacheRetentionSeconds: 12 * 60 * 60,
            gribSubsetMaximumByteCount: 200 * 1024 * 1024,
            pressureArtifactProbeIntervalSeconds: 5 * 60,
            pressureArtifactMaxStaleAgeSeconds: 2 * 60 * 60,
            pressureArtifactDeleteGraceSeconds: 60 * 60,
            pressureArtifactCleanupIntervalSeconds: 15 * 60,
            pressureArtifactRecoveryTimeoutSeconds: 30 * 60,
            wgrib2ExecutableURL: URL(fileURLWithPath: "/usr/local/bin/wgrib2"),
            wgrib2TimeoutSeconds: 15,
            anvilProfileAnalysisBaseURL: nil,
            anvilProfileAnalysisTimeoutSeconds: nil
        )
        let provider = DefaultAnvilProfileAnalysisProvider(
            previewProvider: previewProvider,
            configuration: configuration,
            httpClient: StubHTTPClient()
        )

        do {
            _ = try await provider.analyzeProfile(for: 617_700_169_958_293_503)
            Issue.record("Expected missing Anvil configuration to fail before preview generation.")
        } catch let error as AnvilProfileAnalysisError {
            guard case .internalExecutionFailure(let reason) = error else {
                Issue.record("Expected internalExecutionFailure, got \(error).")
                return
            }

            #expect(reason.contains("Missing Anvil configuration"))
            #expect(previewProvider.requestCount == 0)
        }
    }

    private func makePreviewResponse() -> AnvilAnalyzeProfilePreviewResponse {
        let request = AnvilAnalyzeProfileRequest(
            runTime: isoDate("2026-06-19T22:00:00Z"),
            forecastHour: 3,
            validTime: isoDate("2026-06-20T01:00:00Z"),
            location: AnvilLocationDTO(
                lat: 39.7392,
                lon: -104.9903,
                h3: "882681b59fffffff"
            ),
            profile: AnvilProfileDTO(
                pressureMb: [1000, 925, 850],
                heightMslM: [1560, 780, 1450],
                temperatureC: [28.4, 22.8, 17.5],
                dewpointC: [12.3, 10.1, 11.2],
                uWindMs: [-2.1, -5.4, -6.25],
                vWindMs: [4.6, 7.9, 8.75]
            )
        )

        return AnvilAnalyzeProfilePreviewResponse(
            request: request,
            debug: AnvilAnalyzeProfilePreviewDebugDTO(
                sourceKind: .directObject,
                product: .wrfprsf,
                runTime: request.runTime,
                forecastHour: request.forecastHour,
                validTime: request.validTime,
                h3: request.location.h3,
                centroid: StormSetupCentroid(latitude: request.location.lat, longitude: request.location.lon),
                selectedMessageCount: 5,
                selectedPressureLevels: [1000, 925, 850],
                rangeCount: 3,
                totalSelectedRangeBytes: 1024,
                pressureLevelsRequested: [1000, 925, 850],
                pressureLevelsRetained: [1000, 925, 850],
                missingLevels: [],
                warnings: [],
                subsetCacheHit: true,
                primaryDownloadURL: URL(string: "https://example.com/hrrr.grib2"),
                idxURL: URL(string: "https://example.com/hrrr.idx"),
                idxAvailable: true,
                gribAvailable: true
            )
        )
    }

    private func makeAnvilResponse() -> AnvilAnalyzeProfileResponse {
        AnvilAnalyzeProfileResponse(
            effectiveLayer: AnvilEffectiveLayerDTO(
                status: "found",
                basePressureMb: 1000,
                topPressureMb: 925,
                baseMetersAgl: 0,
                topMetersAgl: 690
            ),
            stormMotion: AnvilStormMotionDTO(
                status: "computed",
                bunkersRight: AnvilBunkersRightStormMotionDTO(
                    uKt: 36.80394762849837,
                    vKt: 13.53066796460426,
                    speedKt: 39.21236458834915,
                    directionTowardDeg: 69.81446460119884,
                    uMs: 18.933570033795217,
                    vMs: 6.960770950382875,
                    speedMs: 20.172565688288692
                )
            ),
            mucape: 362.1018454649957,
            mlcape: 191.7304143918497,
            mlcin: -221.93726424748172,
            mllclMetersAgl: 1179.4130766012365,
            effectiveSrh: 29.42420403684148,
            effectiveBulkShearMs: 30.134722226263612,
            scp: 1.7,
            stpCin: 0.0,
            stpFixed: 2.4,
            ship: 0.6,
            quality: AnvilQualityDTO(
                profileLevelCount: 3,
                warnings: []
            )
        )
    }

    private func isoDate(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else {
            fatalError("Invalid ISO8601 date in test fixture: \(value)")
        }
        return date
    }
}

private struct CancellationThrowingAnvilProfilePreviewProvider: AnvilProfilePreviewProviding {
    func previewProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfilePreviewResponse {
        _ = h3Cell
        throw CancellationError()
    }
}

private final class AnalysisStubAnvilProfileClient: AnvilProfileClient, @unchecked Sendable {
    let response: AnvilAnalyzeProfileResponse?
    let error: (any Error)?
    private(set) var recordedRequests: [AnvilAnalyzeProfileRequest] = []

    var requestCount: Int { recordedRequests.count }

    init(response: AnvilAnalyzeProfileResponse? = nil, error: (any Error)? = nil) {
        self.response = response
        self.error = error
    }

    func analyzeProfile(_ request: AnvilAnalyzeProfileRequest) async throws -> AnvilAnalyzeProfileResponse {
        recordedRequests.append(request)
        if let error {
            throw error
        }

        guard let response else {
            fatalError("Expected a planned response or error.")
        }

        return response
    }
}

private final class RecordingAnvilProfilePreviewProvider: AnvilProfilePreviewProviding, @unchecked Sendable {
    let result: Result<AnvilAnalyzeProfilePreviewResponse, AnvilProfilePreviewError>
    private(set) var requestCount = 0

    init(result: Result<AnvilAnalyzeProfilePreviewResponse, AnvilProfilePreviewError>) {
        self.result = result
    }

    func previewProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfilePreviewResponse {
        _ = h3Cell
        requestCount += 1
        switch result {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}
