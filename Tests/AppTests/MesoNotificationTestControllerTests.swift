@testable import App
import ArcusCore
import Fluent
import Foundation
import SQLKit
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

            let res7 = try H3LatLng(latitudeDegs: 39.7392, longitudeDegs: -104.9903).cell(at: .res7)
            let wrongResolution = try await request(to: app, h3Cell: Int64(bitPattern: res7.id))
            #expect(wrongResolution.status == .badRequest)

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

    @Test("valid request creates a canonical fixture without changing presence or handing off notifications")
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
            var fixtureIDs: [String] = []
            do {
                let outboxBefore = try await ArcusNotificationOutboxModel.query(on: app.db).count()
                let response = try await request(to: app, installationID: installationID)

                #expect(response.status == .created)
                let result = try JSONDecoder().decode(FixtureResponse.self, from: Data(response.body.utf8))
                fixtureIDs.append(result.productID)
                #expect(result.status == "fixture-created")
                let second = try await request(to: app, installationID: installationID)
                let repeated = try JSONDecoder().decode(FixtureResponse.self, from: Data(second.body.utf8))
                fixtureIDs.append(repeated.productID)
                #expect(result.productID != repeated.productID)
                try await app.testing().test(.GET, "/v1/mesos?id=\(result.productID)", afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let products = try JSONDecoder().decode([MesoscaleDiscussionPayload].self, from: Data(res.body.readableBytesView))
                    let product = try #require(products.first)
                    #expect(product.productID == result.productID)
                    #expect(product.title.contains("TEST"))
                    #expect(!product.coordinates.isEmpty)
                    #expect(product.validEnd > Date())
                })
                #expect(try await DevicePresenceModel.find(installationID, on: app.db) == nil)
                #expect(try await ArcusNotificationOutboxModel.query(on: app.db).count() == outboxBefore)
                #expect(app.queues.test.all(MesoNotificationSendJob.self).isEmpty)
                #expect(app.queues.test.all(NotificationSendJob.self).isEmpty)
            } catch {
                try? await SPCMesoModel.query(on: app.db).filter(\.$productKey ~~ fixtureIDs).delete()
                try? await installation.delete(on: app.db)
                throw error
            }
            try await SPCMesoModel.query(on: app.db).filter(\.$productKey ~~ fixtureIDs).delete()
            try await installation.delete(on: app.db)
        }
    }

    private enum Rollback: Error { case assertionsComplete }

    @Test("computed coverage missing the requested cell rolls back canonical acceptance")
    func missingComputedCellRollsBack() async throws {
        let raw = try validH3Cell()
        try await withApp(autoMigrate: true) { app in
            let before = try await SPCMesoModel.query(on: app.db).count()
            let geoBefore = try await SPCMesoGeolocationModel.query(on: app.db).count()
            let persistence = SPCMesoIngestPersistence(buildCoverage: { geometry in
                let actual = try SPCMesoCoverage.build(for: geometry)
                return H3Coverage(cells: [], h3Hash: actual.h3Hash, geometryHash: actual.geometryHash, resolution: 8)
            })
            do {
                _ = try await SyntheticMesoService(persistence: persistence).create(h3Cell: raw, on: app.db)
                Issue.record("Missing coverage accepted a fixture")
            } catch let error as Abort { #expect(error.status == .unprocessableEntity) }
            #expect(try await SPCMesoModel.query(on: app.db).count() == before)
            #expect(try await SPCMesoGeolocationModel.query(on: app.db).count() == geoBefore)

            // The canonical planar validator cannot represent this dateline-
            // crossing boundary. Fail clearly and leave no partial fixture.
            let dateline = try H3LatLng(latitudeDegs: 0, longitudeDegs: 179.9999).cell(at: .res8)
            do {
                _ = try await SyntheticMesoService().create(h3Cell: Int64(bitPattern: dateline.id), on: app.db)
                Issue.record("Unsupported polygon accepted a fixture")
            } catch let error as Abort { #expect(error.status == .unprocessableEntity) }
            #expect(try await SPCMesoModel.query(on: app.db).count() == before)
            #expect(try await SPCMesoGeolocationModel.query(on: app.db).count() == geoBefore)
        }
    }

    private func withFixtureDatabase(_ test: @escaping @Sendable (any Database) async throws -> Void) async throws {
        try await withApp(autoMigrate: true) { app in
            do {
                try await app.db.transaction { db in
                    let sql = try #require(db as? any SQLDatabase)
                    try await sql.raw("LOCK TABLE spc_mesos IN SHARE ROW EXCLUSIVE MODE").run()
                    try await test(db)
                    throw Rollback.assertionsComplete
                }
            } catch Rollback.assertionsComplete {}
        }
    }

    @Test("canonical stored polyfill contains the requested cell", arguments: [
        [39.7392, -104.9903], [89.99, 0.0], [-33.86, 151.21]
    ])
    func canonicalCoverage(point: [Double]) async throws {
        let raw = Int64(bitPattern: try H3LatLng(latitudeDegs: point[0], longitudeDegs: point[1]).cell(at: .res8).id)
        try await withFixtureDatabase { db in
            let now = Date(timeIntervalSince1970: 1_782_777_600)
            let product = try await SyntheticMesoService().create(h3Cell: raw, on: db, now: now)
            #expect((9000...9999).contains(product.number))
            #expect(product.issueYear == 2026)
            #expect(product.issued == now && product.validStart == now)
            #expect(product.validEnd.timeIntervalSince(now) == SyntheticMesoService.lifetime)
            let row = try #require(try await SPCMesoModel.query(on: db).filter(\.$productKey == product.productID).first())
            let geo = try #require(try await SPCMesoGeolocationModel.query(on: db).filter(\.$meso.$id == row.requireID()).first())
            #expect(geo.h3Cells.contains(raw))
            #expect(try SPCMesoCoverage.build(for: geo.geometry).cells == geo.h3Cells)
        }
    }

    @Test("allocation skips real products, retains a watermark through cleanup, and fails on exhaustion")
    func allocationAndCleanup() async throws {
        let raw = try validH3Cell()
        try await withFixtureDatabase { db in
            let service = SyntheticMesoService()
            let now = Date(timeIntervalSince1970: 1_782_777_600)
            let first = try await service.create(h3Cell: raw, on: db, now: now)
            let real = try #require(try await SPCMesoModel.query(on: db).filter(\.$productKey == first.productID).first())
            real.sourceURL = "https://www.spc.noaa.gov/real-product"
            real.title = "Real product collision sentinel"
            try await real.update(on: db)
            let second = try await service.create(h3Cell: raw, on: db, now: now)
            #expect(second.number > first.number)
            let later = now.addingTimeInterval(3 * 24 * 60 * 60)
            let third = try await service.create(h3Cell: raw, on: db, now: later)
            #expect(third.number > second.number)
            #expect(try await SPCMesoModel.query(on: db).filter(\.$productKey == second.productID).count() == 0)
            let preserved = try #require(try await SPCMesoModel.find(real.requireID(), on: db))
            #expect(preserved.title == "Real product collision sentinel")
            // A later request still advances after earlier fixtures were deleted.
            let fourth = try await service.create(h3Cell: raw, on: db, now: later.addingTimeInterval(3 * 24 * 60 * 60))
            #expect(fourth.number > third.number)
            let last = try #require(try await SPCMesoModel.query(on: db).filter(\.$productKey == fourth.productID).first())
            last.productKey = "SPC-MD-2026-9999"
            last.number = 9999
            try await last.update(on: db)
            do {
                _ = try await service.create(h3Cell: raw, on: db, now: later)
                Issue.record("Exhausted reserved range accepted a fixture")
            } catch let error as Abort { #expect(error.status == .conflict) }
            #expect(try await SPCMesoModel.find(last.requireID(), on: db)?.number == 9999)
        }
    }

    @Test("concurrent requests cannot select the same identity")
    func concurrentAllocation() async throws {
        let raw = try validH3Cell()
        try await withApp(autoMigrate: true) { app in
            let before = Set(try await SPCMesoModel.query(on: app.db).all().map(\.productKey))
            do {
                let products = try await withThrowingTaskGroup(of: String.self) { group in
                    for _ in 0..<4 {
                        group.addTask { try await SyntheticMesoService().create(h3Cell: raw, on: app.db).productID }
                    }
                    var ids: [String] = []
                    for try await id in group { ids.append(id) }
                    return ids
                }
                #expect(Set(products).count == 4)
            } catch {
                let created = try await SPCMesoModel.query(on: app.db).all().filter { !before.contains($0.productKey) }
                for row in created { try await row.delete(on: app.db) }
                throw error
            }
            let created = try await SPCMesoModel.query(on: app.db).all().filter { !before.contains($0.productKey) }
            for row in created { try await row.delete(on: app.db) }
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

private struct FixtureResponse: Decodable {
    let status: String
    let productID: String
}
