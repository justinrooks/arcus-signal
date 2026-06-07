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

    @Test("GET /api/v1/storm-setup/current resolves the H3 centroid")
    func validH3ResolvesCentroid() async throws {
        try await withApp { app in
            let inputH3: Int64 = 617700169958293503
            let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: inputH3)

            try await app.testing().test(.GET, "api/v1/storm-setup/current?h3=\(inputH3)", afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .json)

                let snapshot = try res.content.decode(TornadoIngredientSnapshot.self)
                #expect(snapshot.h3Cell == expected.h3Cell)
                #expect(snapshot.centroid.latitude.isApproximatelyEqual(to: expected.centroid.latitude))
                #expect(snapshot.centroid.longitude.isApproximatelyEqual(to: expected.centroid.longitude))
            })
        }
    }

    @Test("GET /api/v1/storm-setup/current encodes the snapshot contract")
    func currentResponseEncodesSuccessfully() async throws {
        try await withApp { app in
            let inputH3: Int64 = 617700169958293503

            try await app.testing().test(.GET, "api/v1/storm-setup/current?h3=\(inputH3)", afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .json)

                let snapshot = try res.content.decode(TornadoIngredientSnapshot.self)
                #expect(snapshot.h3Cell == inputH3)
                #expect(snapshot.source.model == nil)
                #expect(snapshot.raw.sbcapeJkg == nil)
                #expect(snapshot.assessment.overall == nil)
                #expect(snapshot.freshness.isStale)
            })
        }
    }
}

private extension Double {
    func isApproximatelyEqual(to other: Double, tolerance: Double = 0.0000000001) -> Bool {
        abs(self - other) <= tolerance
    }
}
