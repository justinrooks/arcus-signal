@testable import App
import Foundation
import Testing
import Vapor
import VaporTesting

@Suite("Anvil profile preview controller", .serialized)
struct AnvilProfilePreviewControllerTests {
    private func withApp(
        debugEndpointsEnabled: Bool,
        test: (Application) async throws -> Void
    ) async throws {
        try await previewWithEnvironment([
            "ARCUS_DEBUG_ENDPOINTS_ENABLED": debugEndpointsEnabled ? "true" : nil
        ]) {
            let app = try await Application.make(.testing)
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
            try await app.testing().test(.GET, "api/v1/dev/anvil/profile-preview?h3=617700169958293503") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("missing h3 returns bad request")
    func missingH3ReturnsBadRequest() async throws {
        try await withApp(debugEndpointsEnabled: true) { app in
            app.anvilProfilePreviewProvider = PreviewStubAnvilProfilePreviewProvider(
                result: .success(makePreviewResponse())
            )

            try await app.testing().test(.GET, "api/v1/dev/anvil/profile-preview") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("Missing required query parameter 'h3'."))
            }
        }
    }

    @Test("invalid h3 returns bad request")
    func invalidH3ReturnsBadRequest() async throws {
        try await withApp(debugEndpointsEnabled: true) { app in
            app.anvilProfilePreviewProvider = PreviewStubAnvilProfilePreviewProvider(
                result: .success(makePreviewResponse())
            )

            try await app.testing().test(.GET, "api/v1/dev/anvil/profile-preview?h3=not-a-cell") { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("Invalid H3 cell"))
            }
        }
    }

    @Test("happy path returns the preview request and debug metadata")
    func happyPathReturnsPreviewResponse() async throws {
        try await withApp(debugEndpointsEnabled: true) { app in
            let expected = makePreviewResponse()
            app.anvilProfilePreviewProvider = PreviewStubAnvilProfilePreviewProvider(
                result: .success(expected)
            )

            try await app.testing().test(.GET, "api/v1/dev/anvil/profile-preview?h3=617700169958293503") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .json)

                let response = try res.content.decode(AnvilAnalyzeProfilePreviewResponse.self)
                #expect(response == expected)
                #expect(response.request.location.h3 == expected.request.location.h3)
                #expect(response.request.profile.pressureMb.count == 8)
                #expect(response.debug.sourceKind == .directObject)
                #expect(response.debug.product == .wrfprsf)
                #expect(response.debug.h3 == expected.request.location.h3)
                #expect(response.debug.centroid == expected.debug.centroid)
                #expect(response.debug.selectedMessageCount == expected.debug.selectedMessageCount)
                #expect(response.debug.selectedPressureLevels == expected.debug.selectedPressureLevels)
                #expect(response.debug.rangeCount == expected.debug.rangeCount)
                #expect(response.debug.totalSelectedRangeBytes == expected.debug.totalSelectedRangeBytes)
                #expect(response.debug.pressureLevelsRequested == expected.debug.pressureLevelsRequested)
                #expect(response.debug.pressureLevelsRetained == expected.debug.pressureLevelsRetained)
                #expect(response.debug.missingLevels == expected.debug.missingLevels)
                #expect(response.debug.warnings == expected.debug.warnings)
                #expect(response.debug.subsetCacheHit == false)
                #expect(response.debug.primaryDownloadURL == expected.debug.primaryDownloadURL)
                #expect(response.debug.idxURL == expected.debug.idxURL)
                #expect(response.debug.idxAvailable == expected.debug.idxAvailable)
                #expect(response.debug.gribAvailable == expected.debug.gribAvailable)

                guard let jsonData = res.body.string.data(using: .utf8) else {
                    Issue.record("Unable to decode response body as UTF-8.")
                    return
                }

                let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                #expect(object?.keys.sorted() == ["debug", "request"])

                let requestObject = object?["request"] as? [String: Any]
                #expect(requestObject?.keys.sorted() == ["forecastHour", "location", "profile", "runTime", "validTime"])

                let debugObject = object?["debug"] as? [String: Any]
                #expect(debugObject?.keys.sorted() == [
                    "centroid",
                    "forecastHour",
                    "gribAvailable",
                    "h3",
                    "idxAvailable",
                    "idxURL",
                    "missingLevels",
                    "pressureLevelsRequested",
                    "pressureLevelsRetained",
                    "primaryDownloadURL",
                    "product",
                    "rangeCount",
                    "runTime",
                    "selectedMessageCount",
                    "selectedPressureLevels",
                    "sourceKind",
                    "subsetCacheHit",
                    "totalSelectedRangeBytes",
                    "validTime",
                    "warnings"
                ])
            }
        }
    }

    @Test("unusable profile returns unprocessable entity")
    func unusableProfileReturnsUnprocessableEntity() async throws {
        try await withApp(debugEndpointsEnabled: true) { app in
            app.anvilProfilePreviewProvider = PreviewStubAnvilProfilePreviewProvider(
                result: .failure(.unusableProfile(reason: "Only four retained levels were available."))
            )

            try await app.testing().test(.GET, "api/v1/dev/anvil/profile-preview?h3=617700169958293503") { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("The grouped HRRR profile could not produce a valid Anvil request."))
            }
        }
    }

    @Test("upstream failure returns service unavailable")
    func upstreamFailureReturnsServiceUnavailable() async throws {
        try await withApp(debugEndpointsEnabled: true) { app in
            app.anvilProfilePreviewProvider = PreviewStubAnvilProfilePreviewProvider(
                result: .failure(.upstreamUnavailable(reason: "NOMADS returned HTTP 503"))
            )

            try await app.testing().test(.GET, "api/v1/dev/anvil/profile-preview?h3=617700169958293503") { res async in
                #expect(res.status == .serviceUnavailable)
                #expect(res.body.string.contains("Upstream HRRR data was unavailable."))
            }
        }
    }

    @Test("internal execution failure returns internal server error")
    func internalExecutionFailureReturnsInternalServerError() async throws {
        try await withApp(debugEndpointsEnabled: true) { app in
            app.anvilProfilePreviewProvider = PreviewStubAnvilProfilePreviewProvider(
                result: .failure(.internalExecutionFailure(reason: "wgrib2 exited with code 1"))
            )

            try await app.testing().test(.GET, "api/v1/dev/anvil/profile-preview?h3=617700169958293503") { res async in
                #expect(res.status == .internalServerError)
                #expect(res.body.string.contains("Anvil preview request assembly failed during internal execution."))
            }
        }
    }

    private func makePreviewResponse() -> AnvilAnalyzeProfilePreviewResponse {
        let runTime = previewMakeUTCDate(year: 2026, month: 6, day: 19, hour: 22)
        let forecastHour = 3
        let h3Cell: Int64 = 617_700_169_958_293_503
        let grouping = makeGroupingResult(
            levels: [
                makeLevel(pressureMb: 1000, heightMslM: 1200, temperatureC: 28.4, dewpointC: 12.3, uWindMs: -2.1, vWindMs: 4.6),
                makeLevel(pressureMb: 925, heightMslM: 1500, temperatureC: 22.8, dewpointC: 10.1, uWindMs: -5.4, vWindMs: 7.9),
                makeLevel(pressureMb: 850, heightMslM: 1800, temperatureC: 17.5, dewpointC: 11.2, uWindMs: -6.25, vWindMs: 8.75),
                makeLevel(pressureMb: 700, heightMslM: 2450, temperatureC: 10.0, dewpointC: 1.0, uWindMs: -12.5, vWindMs: 14.2),
                makeLevel(pressureMb: 600, heightMslM: 4100, temperatureC: 3.2, dewpointC: -2.6, uWindMs: -15.25, vWindMs: 18.4),
                makeLevel(pressureMb: 500, heightMslM: 5600, temperatureC: -4.2, dewpointC: -12.0, uWindMs: -18.75, vWindMs: 22.0),
                makeLevel(pressureMb: 400, heightMslM: 7100, temperatureC: -14.4, dewpointC: -20.8, uWindMs: -23.5, vWindMs: 27.8),
                makeLevel(pressureMb: 300, heightMslM: 9300, temperatureC: -27.0, dewpointC: -32.8, uWindMs: -28.9, vWindMs: 31.4)
            ],
            missingLevels: makeMissingLevels(excluding: [1000, 925, 850, 700, 600, 500, 400, 300])
        )

        let builder = AnvilProfileRequestBuilder()
        let request = try! builder.build(
            h3Cell: h3Cell,
            runTime: runTime,
            forecastHour: forecastHour,
            groupedProfile: grouping
        ).request
        let debug = AnvilAnalyzeProfilePreviewDebugDTO(
            sourceKind: .directObject,
            product: .wrfprsf,
            runTime: request.runTime,
            forecastHour: request.forecastHour,
            validTime: request.validTime,
            h3: request.location.h3,
            centroid: request.location.centroid,
            selectedMessageCount: 5,
            selectedPressureLevels: [1000],
            rangeCount: 5,
            totalSelectedRangeBytes: 1024,
            pressureLevelsRequested: [1000],
            pressureLevelsRetained: grouping.retainedLevels.map(\.pressureMb),
            missingLevels: [],
            warnings: [makeDroppedLevelsWarning(from: grouping.missingLevels)],
            subsetCacheHit: false,
            primaryDownloadURL: URL(string: "https://noaa-hrrr-bdp-pds.s3.amazonaws.com/hrrr.20260619/conus/hrrr.t21z.wrfprsf03.grib2"),
            idxURL: URL(string: "https://noaa-hrrr-bdp-pds.s3.amazonaws.com/hrrr.20260619/conus/hrrr.t21z.wrfprsf03.grib2.idx"),
            idxAvailable: true,
            gribAvailable: nil
        )

        return AnvilAnalyzeProfilePreviewResponse(request: request, debug: debug)
    }
}

private extension AnvilLocationDTO {
    var centroid: StormSetupCentroid {
        StormSetupCentroid(latitude: lat, longitude: lon)
    }
}

private func makeGroupingResult(
    levels: [StormSetupPressureProfileLevel],
    missingLevels: [StormSetupPressureProfileMissingLevel] = []
) -> StormSetupPressureProfileGroupingResult {
    StormSetupPressureProfileGroupingResult(
        requestedLevels: StormSetupPressureLevel.preferredDescending,
        retainedLevels: levels,
        missingLevels: missingLevels,
        ignoredSamples: []
    )
}

private func makeMissingLevels(excluding retainedPressureLevels: [Int]) -> [StormSetupPressureProfileMissingLevel] {
    let retained = Set(retainedPressureLevels)
    return StormSetupPressureLevel.preferredDescending
        .filter { !retained.contains($0.pressureMb) }
        .map {
            StormSetupPressureProfileMissingLevel(
                pressureMb: $0.pressureMb,
                missingVariables: [.hgt, .tmp, .dpt, .ugrd, .vgrd]
            )
        }
}

private func makeDroppedLevelsWarning(from missingLevels: [StormSetupPressureProfileMissingLevel]) -> String {
    let summary = missingLevels
        .map { "\($0.pressureMb) mb missing \($0.missingVariables.map(\.rawValue).joined(separator: ", "))" }
        .joined(separator: "; ")
    return "Dropped incomplete pressure levels: \(summary)."
}

private func makeLevel(
    pressureMb: Int,
    heightMslM: Double,
    temperatureC: Double,
    dewpointC: Double,
    uWindMs: Double,
    vWindMs: Double
) -> StormSetupPressureProfileLevel {
    StormSetupPressureProfileLevel(
        pressureMb: pressureMb,
        heightMslM: heightMslM,
        temperatureC: temperatureC,
        dewpointC: dewpointC,
        uWindMs: uWindMs,
        vWindMs: vWindMs
    )
}
