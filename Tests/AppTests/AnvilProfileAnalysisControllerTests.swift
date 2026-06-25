@testable import App
import Foundation
import Testing
import Vapor
import VaporTesting

@Suite("Anvil profile analysis controller", .serialized)
struct AnvilProfileAnalysisControllerTests {
    private func withApp(
        debugEndpointsEnabled: Bool,
        environment: Environment = .testing,
        test: (Application) async throws -> Void
    ) async throws {
        try await previewWithEnvironment([
            "ARCUS_DEBUG_ENDPOINTS_ENABLED": debugEndpointsEnabled ? "true" : nil,
            "ANVIL_PROFILE_ANALYSIS_BASE_URL": "https://anvil.example.com",
            "DATABASE_URL": environment == .production ? "postgres://arcus:arcus@127.0.0.1:5432/arcus_signal?tlsmode=disable" : nil,
            "REDIS_URL": environment == .production ? "redis://127.0.0.1:6379" : nil,
            "ANVIL_PROFILE_ANALYSIS_TIMEOUT_SECONDS": "9"
        ]) {
            let app = try await Application.make(environment)
            do {
                try await configure(app, mode: .api)
                try await test(app)
            } catch {
                try? await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    @Test("disabled debug endpoints return 404")
    func disabledDebugEndpointsReturnNotFound() async throws {
        try await withApp(debugEndpointsEnabled: false) { app in
            try await app.testing().test(.GET, "api/v1/dev/anvil/profile-analysis?h3=617700169958293503") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("production still blocks the endpoint")
    func productionStillBlocksTheEndpoint() async throws {
        try await withApp(debugEndpointsEnabled: true, environment: .production) { app in
            app.anvilProfileAnalysisProvider = PreviewStubAnvilProfileAnalysisProvider(
                result: .success(makeAnalysisResponse())
            )

            try await app.testing().test(.GET, "api/v1/dev/anvil/profile-analysis?h3=617700169958293503") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("missing h3 returns bad request")
    func missingH3ReturnsBadRequest() async throws {
        try await withApp(debugEndpointsEnabled: true) { app in
            app.anvilProfileAnalysisProvider = PreviewStubAnvilProfileAnalysisProvider(
                result: .success(makeAnalysisResponse())
            )

            try await app.testing().test(.GET, "api/v1/dev/anvil/profile-analysis") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("Missing required query parameter 'h3'."))
            }
        }
    }

    @Test("happy path returns the request, debug metadata, and decoded Anvil response")
    func happyPathReturnsAnalysisResponse() async throws {
        try await withApp(debugEndpointsEnabled: true) { app in
            let expected = makeAnalysisResponse()
            app.anvilProfileAnalysisProvider = PreviewStubAnvilProfileAnalysisProvider(
                result: .success(expected)
            )

            try await app.testing().test(.GET, "api/v1/dev/anvil/profile-analysis?h3=617700169958293503") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .json)

                let response = try res.content.decode(AnvilAnalyzeProfileAnalysisResponse.self)
                #expect(response == expected)
                #expect(response.request.location.h3 == expected.request.location.h3)
                #expect(response.request.profile.pressureMb == [1000, 925, 850])
                #expect(response.response.effectiveLayer.status == "found")
                #expect(response.response.stormMotion.status == "computed")
                #expect(response.response.scp == 1.7)
                #expect(response.response.stpFixed == 2.4)
                #expect(response.response.ship == 0.6)
                #expect(response.response.quality.profileLevelCount == 3)
            }
        }
    }

    private func makeAnalysisResponse() -> AnvilAnalyzeProfileAnalysisResponse {
        let preview = makePreviewResponse()
        return AnvilAnalyzeProfileAnalysisResponse(
            request: preview.request,
            debug: preview.debug,
            response: AnvilAnalyzeProfileResponse(
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
        )
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

    private func isoDate(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else {
            fatalError("Invalid ISO8601 date in test fixture: \(value)")
        }
        return date
    }
}

private struct PreviewStubAnvilProfileAnalysisProvider: AnvilProfileAnalysisProviding {
    let result: Result<AnvilAnalyzeProfileAnalysisResponse, AnvilProfileAnalysisError>

    func analyzeProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfileAnalysisResponse {
        _ = h3Cell
        switch result {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}
