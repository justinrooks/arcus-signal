@testable import App
import Foundation
import Testing
import Vapor
import VaporTesting

@Suite("Storm setup controller", .serialized)
struct StormSetupControllerTests {
    private func withApp(test: (Application) async throws -> Void) async throws {
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

    @Test("GET /api/v1/storm-setup/current returns source metadata from the selected HRRR candidate")
    func currentResponseIncludesSelectedSourceMetadata() async throws {
        try await withApp { app in
            let fixedNow = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
            app.stormSetupProvider = makeStormSetupRouteProvider(now: fixedNow)
            let expectedAnalysis = makeStormSetupRouteAnalysisResponse(validTime: fixedNow).response

            let inputH3: Int64 = 617700169958293503

            try await app.testing().test(.GET, "api/v1/storm-setup/current?h3=\(inputH3)", afterResponse: { res async throws in
                #expect(res.status == .ok)

                let response = try res.content.decode(StormSetupCurrentResponse.self)
                #expect(response.setup.source.model == .hrrr)
                #expect(response.setup.source.product == .wrfsfc)
                #expect(response.setup.source.domain == .conus)
                #expect(response.setup.source.fieldSetVersion == .tornadoV1)
                #expect(response.setup.source.runTime == makeUTCDate(year: 2026, month: 6, day: 3, hour: 22))
                #expect(response.setup.source.forecastHour == 0)
                #expect(response.setup.source.validTime == makeUTCDate(year: 2026, month: 6, day: 3, hour: 22))
                #expect(response.setup.source.bbox != nil)
                #expect(response.setup.source.nomadsURL?.absoluteString.contains("filter_hrrr_2d.pl") == true)
                #expect(response.setup.freshness.modelRunTime == makeUTCDate(year: 2026, month: 6, day: 3, hour: 22))
                #expect(response.setup.freshness.sourceValidTime == makeUTCDate(year: 2026, month: 6, day: 3, hour: 22))
                #expect(response.setup.freshness.expiresAt == makeUTCDate(year: 2026, month: 6, day: 3, hour: 23, minute: 30))
                #expect(response.setup.freshness.isStale == false)
                #expect(response.setup.freshness.isDegraded == false)
                #expect(response.ingredients.canonical.mucapeJkg == 362.1018454649957)
                #expect(response.ingredients.canonical.mlcapeJkg == 191.7304143918497)
                #expect(response.ingredients.canonical.effectiveLayer?.status == "found")
                #expect(response.ingredients.diagnostics.sbcapeJkg == 1450)
                #expect(response.ingredients.diagnostics.temperature2mK == 295.15)
                #expect(response.profileAnalysis == expectedAnalysis)
                #expect(response.assessment.overall == .conditional)
                #expect(response.assessment.confidence == .moderate)
                #expect(response.assessment.summary.contains("conditionally supportive"))
            })
        }
    }

    @Test("GET /api/v1/storm-setup/current rejects a missing h3 query parameter")
    func missingH3ReturnsBadRequest() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "api/v1/storm-setup/current", afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("Missing required query parameter 'h3'."))
            })
        }
    }

    @Test("GET /api/v1/storm-setup/current rejects an invalid h3 cell")
    func invalidH3ReturnsBadRequest() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "api/v1/storm-setup/current?h3=not-a-valid-h3", afterResponse: { res async in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("Invalid H3 cell"))
            })
        }
    }

    @Test("GET /api/v1/storm-setup/current maps provider errors to useful HTTP responses")
    func providerErrorsMapToUsefulHTTPResponses() async throws {
        try await withApp { app in
            let source = makeSourceMetadataForErrorMapping()
            app.stormSetupProvider = ThrowingStormSetupProvider(
                error: StormSetupCurrentSnapshotError.insufficientNormalizedData(
                    source: source,
                    reason: "wgrib2 produced no recognizable ingredient values"
                )
            )

            try await app.testing().test(.GET, "api/v1/storm-setup/current?h3=617700169958293503", afterResponse: { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Insufficient normalized ingredient data"))
            })
        }
    }

    @Test("GET /api/v1/storm-setup/current resolves the H3 centroid")
    func validH3ResolvesCentroid() async throws {
        try await withApp { app in
            let inputH3: Int64 = 617700169958293503
            app.stormSetupProvider = makeStormSetupRouteProvider(now: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45))
            let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: inputH3)

            try await app.testing().test(.GET, "api/v1/storm-setup/current?h3=\(inputH3)", afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .json)

                let response = try res.content.decode(StormSetupCurrentResponse.self)
                #expect(response.setup.h3Cell == expected.h3Cell)
                #expect(response.setup.centroid.latitude.isApproximatelyEqual(to: expected.centroid.latitude))
                #expect(response.setup.centroid.longitude.isApproximatelyEqual(to: expected.centroid.longitude))
            })
        }
    }

    @Test("GET /api/v1/storm-setup/current encodes the snapshot contract")
    func currentResponseEncodesSuccessfully() async throws {
        try await withApp { app in
            let fixedNow = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
            app.stormSetupProvider = makeStormSetupRouteProvider(now: fixedNow)
            let inputH3: Int64 = 617700169958293503

            try await app.testing().test(.GET, "api/v1/storm-setup/current?h3=\(inputH3)", afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .json)

                let response = try res.content.decode(StormSetupCurrentResponse.self)
                #expect(response.setup.h3Cell == inputH3)
                #expect(response.setup.source.model == .hrrr)
                #expect(response.setup.source.nomadsURL != nil)
                #expect(response.ingredients.canonical.mucapeJkg == 362.1018454649957)
                #expect(response.ingredients.diagnostics.sbcapeJkg == 1450)
                #expect(response.profileAnalysis != nil)
                #expect(response.assessment.overall == .conditional)
                #expect(response.assessment.confidence == .moderate)
                #expect(response.setup.freshness.isStale == false)
            })
        }
    }
}

private extension Double {
    func isApproximatelyEqual(to other: Double, tolerance: Double = 0.0000000001) -> Bool {
        abs(self - other) <= tolerance
    }
}

private struct FixedStormSetupDateProvider: StormSetupDateProviding {
    let nowDate: Date

    func now() -> Date {
        nowDate
    }
}

private func makeUTCDate(
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

private struct ThrowingStormSetupProvider: StormSetupProviding {
    let error: StormSetupCurrentSnapshotError

    func currentSnapshot(for h3Cell: Int64) async throws -> TornadoIngredientSnapshot {
        _ = h3Cell
        throw error
    }
}

private func makeSourceMetadataForErrorMapping() -> StormSetupSourceMetadata {
    let candidate = HrrrRunCandidate(
        runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
        forecastHour: 0
    )

    return HrrrNomadsURLBuilder().makeSourceMetadata(
        for: candidate,
        around: StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
    )
}
