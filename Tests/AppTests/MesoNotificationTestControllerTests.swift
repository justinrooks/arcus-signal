@testable import App
import ArcusCore
import Fluent
import Foundation
import SwiftyH3
import Testing
import Vapor
import VaporTesting
import XCTQueues

@Suite("Meso notification test endpoint", .serialized, .sharedDatabase)
struct MesoNotificationTestControllerTests {
    private func withApp(
        enabled: String? = "true",
        secret: String? = String(repeating: "a", count: 32),
        environment: Environment = .development,
        autoMigrate: Bool = false,
        databaseURL: String? = Environment.get("DATABASE_URL"),
        test: (Application) async throws -> Void
    ) async throws {
        if autoMigrate || environment == .production {
            try requireIsolatedTestDatabaseURL(databaseURL)
        }
        var environmentOverrides: [String: String?] = [
            "ARCUS_MESO_NOTIFICATION_TEST_ENABLED": enabled,
            "ARCUS_MESO_NOTIFICATION_TEST_BEARER_SECRET": secret
        ]
        if environment == .production {
            environmentOverrides["DATABASE_URL"] = databaseURL
            environmentOverrides["REDIS_URL"] = "redis://127.0.0.1:6379"
        }
        try await previewWithEnvironment(environmentOverrides) {
            let app = try await Application.make(environment)
            do {
                try await configure(app, mode: .api)
                if autoMigrate { try await app.autoMigrate() }
                app.queues.use(.test)
                try await test(app)
            } catch {
                try? await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func requireIsolatedTestDatabaseURL(_ rawURL: String?) throws {
        guard let rawURL,
              let components = URLComponents(string: rawURL),
              let databaseName = components.path.split(separator: "/").last.map(String.init),
              databaseName.range(
                  of: #"^arcus_issue[0-9]+_(test|validation)(_|$)"#,
                  options: .regularExpression
              ) != nil else {
            throw TestDatabaseIsolationError.databaseURLMustIdentifyDedicatedTestDatabase
        }
    }

    @Test("database-backed cases require an explicit dedicated test database")
    func databaseIsolationGuardRejectsSharedFallback() async throws {
        #expect(throws: TestDatabaseIsolationError.self) {
            try requireIsolatedTestDatabaseURL(nil)
        }
        #expect(throws: TestDatabaseIsolationError.self) {
            try requireIsolatedTestDatabaseURL("postgres://arcus:arcus@127.0.0.1:5432/arcus_signal")
        }
        #expect(throws: TestDatabaseIsolationError.self) {
            try requireIsolatedTestDatabaseURL("postgres://arcus:arcus@127.0.0.1:5432/arcus_signal_production_test")
        }
        try requireIsolatedTestDatabaseURL("postgres://arcus:arcus@127.0.0.1:5432/arcus_issue344_validation")

        await #expect(throws: TestDatabaseIsolationError.self) {
            try await withApp(autoMigrate: true, databaseURL: "postgres://arcus:arcus@127.0.0.1:5432/arcus_signal") { _ in
                Issue.record("Unsafe database URL reached app migration setup.")
            }
        }
        await #expect(throws: TestDatabaseIsolationError.self) {
            try await withApp(environment: .production, databaseURL: "postgres://arcus:arcus@127.0.0.1:5432/arcus_signal_production_test") { _ in
                Issue.record("Unsafe database URL reached production app setup.")
            }
        }
    }

    private func request(
        to app: Application,
        installationID: UUID = UUID(),
        h3Cell: Int64? = nil,
        type: String = "meso",
        token: String? = String(repeating: "a", count: 32)
    ) async throws -> (status: HTTPResponseStatus, body: String) {
        let encoder = JSONEncoder()
        let requestedH3Cell: Int64
        if let h3Cell {
            requestedH3Cell = h3Cell
        } else {
            requestedH3Cell = try validH3Cell()
        }
        let payload = RequestPayload(
            installationId: installationID,
            h3Cell: requestedH3Cell,
            type: type
        )
        var result: (status: HTTPResponseStatus, body: String) = (.internalServerError, "")
        try await app.testing().test(
            .POST,
            "/v1/dev/notification-test",
            beforeRequest: { req in
                req.headers.contentType = .json
                if let token {
                    req.headers.replaceOrAdd(name: .authorization, value: "Bearer \(token)")
                }
                req.body = .init(data: try encoder.encode(payload))
            },
            afterResponse: { res async in result = (res.status, res.body.string) }
        )
        return result
    }

    private func validH3Cell() throws -> Int64 {
        let cell = try H3LatLng(latitudeDegs: 39.7392, longitudeDegs: -104.9903).cell(at: .res8)
        return Int64(bitPattern: cell.id)
    }

    @Test("route requires development environment, explicit enablement, and a strong secret")
    func routeRequiresFailClosedConfiguration() async throws {
        #expect(MesoNotificationTestEndpointConfiguration(
            appEnvironment: .production,
            processEnvironment: [
                "ARCUS_MESO_NOTIFICATION_TEST_ENABLED": "true",
                "ARCUS_MESO_NOTIFICATION_TEST_BEARER_SECRET": String(repeating: "a", count: 32)
            ]
        )?.bearerSecret == nil)
        try await withApp(environment: .production) { app in
            #expect(!app.routes.all.map(\.description).contains("POST /v1/dev/notification-test"))
        }
        try await withApp(enabled: nil) { app in
            #expect(!app.routes.all.map(\.description).contains("POST /v1/dev/notification-test"))
        }
        try await withApp(secret: nil) { app in
            #expect(!app.routes.all.map(\.description).contains("POST /v1/dev/notification-test"))
        }
        try await withApp(secret: "too-short") { app in
            #expect(!app.routes.all.map(\.description).contains("POST /v1/dev/notification-test"))
        }
    }

    @Test("unauthorized and invalid requests are rejected without creating records")
    func rejectedRequestsHaveNoPersistenceSideEffects() async throws {
        try await withApp { app in
            let installationID = UUID()
            let missingAuthorization = try await request(to: app, installationID: installationID, token: nil)
            #expect(missingAuthorization.status == .unauthorized)

            let unauthorized = try await request(to: app, installationID: installationID, token: "wrong")
            #expect(unauthorized.status == .unauthorized)

            let invalidType = try await request(to: app, installationID: installationID, type: "nws")
            #expect(invalidType.status == .badRequest)

            let invalidCell = try await request(to: app, installationID: installationID, h3Cell: 42)
            #expect(invalidCell.status == .badRequest)

            #expect(app.queues.test.all(MesoNotificationSendJob.self).isEmpty)
            #expect(app.queues.test.all(NotificationSendJob.self).isEmpty)
        }
    }

    @Test("unknown installations are rejected without creating records")
    func unknownInstallationHasNoSideEffects() async throws {
        try await withApp(autoMigrate: true) { app in
            let installationID = UUID()
            let outboxBefore = try await ArcusNotificationOutboxModel.query(on: app.db).count()
            let response = try await request(to: app, installationID: installationID)

            #expect(response.status == .notFound)
            #expect(try await DevicePresenceModel.find(installationID, on: app.db) == nil)
            #expect(try await ArcusNotificationOutboxModel.query(on: app.db).count() == outboxBefore)
            #expect(app.queues.test.all(MesoNotificationSendJob.self).isEmpty)
            #expect(app.queues.test.all(NotificationSendJob.self).isEmpty)
        }
    }

    @Test("valid request validates installation and returns not-yet-wired without changing presence")
    func validRequestStopsBeforeNotificationSideEffects() async throws {
        try await withApp(autoMigrate: true) { app in
            let installationID = UUID()
            let installation = DeviceInstallationModel(
                installationId: installationID,
                apnsDeviceToken: "abcd1234efgh5678ijkl9012mnop3456",
                apnsEnvironment: .sandbox,
                platform: .iOS,
                osVersion: "26.0",
                appVersion: "1.0.0",
                buildNumber: "100",
                locationAuth: .always
            )
            try await installation.save(on: app.db)
            do {
                let outboxBefore = try await ArcusNotificationOutboxModel.query(on: app.db).count()
                let response = try await request(to: app, installationID: installationID)

                #expect(response.status == .notImplemented)
                #expect(response.body.contains("not-yet-wired"))
                #expect(try await DevicePresenceModel.find(installationID, on: app.db) == nil)
                #expect(try await ArcusNotificationOutboxModel.query(on: app.db).count() == outboxBefore)
                #expect(app.queues.test.all(MesoNotificationSendJob.self).isEmpty)
                #expect(app.queues.test.all(NotificationSendJob.self).isEmpty)
            } catch {
                try? await installation.delete(on: app.db)
                throw error
            }
            try await installation.delete(on: app.db)
        }
    }
}

private enum TestDatabaseIsolationError: Error {
    case databaseURLMustIdentifyDedicatedTestDatabase
}

private struct RequestPayload: Encodable {
    let installationId: UUID
    let h3Cell: Int64
    let type: String
}
