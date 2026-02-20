@testable import App
import Testing
import Vapor
import VaporTesting

@Suite("Arcus Signal bootstrap tests", .serialized)
struct AppTests {
    private func withApp(
        mode: AppRuntimeMode,
        test: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: mode)
            try await test(app)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("API health endpoint returns ok")
    func apiHealth() async throws {
        try await withApp(mode: .api) { app in
            try await app.testing().test(.GET, "health", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "ok")
            })
        }
    }

    @Test("Worker health endpoint returns ok")
    func workerHealth() async throws {
        try await withApp(mode: .worker) { app in
            try await app.testing().test(.GET, "health", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "ok")
            })
        }
    }
}
