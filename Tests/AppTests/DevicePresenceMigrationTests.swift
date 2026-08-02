@testable import App
import Foundation
import SQLKit
import Testing
import Vapor

@Suite("Device presence migration tests", .serialized)
struct DevicePresenceMigrationTests {
    private enum Rollback: Error {
        case afterAssertions
    }

    private func withApp(test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            try await app.autoMigrate()
            try await test(app)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("repair restores expanded source values from the historical constraint")
    func repairRestoresExpandedSources() async throws {
        try await withApp { app in
            let installationID = UUID()
            let now = Date(timeIntervalSince1970: 1_717_513_600)

            do {
                try await app.db.transaction { database in
                    guard let sql = database as? any SQLDatabase else {
                        throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
                    }

                    try await sql.raw(
                        "LOCK TABLE device_installations, device_presence IN ACCESS EXCLUSIVE MODE"
                    ).run()
                    try await sql.raw("DELETE FROM device_presence;").run()
                    try await sql.raw("DELETE FROM device_installations;").run()
                    try await sql.raw("""
                        ALTER TABLE device_presence
                        DROP CONSTRAINT IF EXISTS device_presence_source_check;
                        """).run()
                    try await sql.raw("""
                        ALTER TABLE device_presence
                        ADD CONSTRAINT device_presence_source_check
                        CHECK (source IN ('foreground', 'backgroundRefresh', 'significantChange', 'manual', 'unknown'));
                        """).run()

                    try await RepairDevicePresenceSourceConstraintForExpandedLocationUploadSources().prepare(on: database)

                    try await DeviceInstallationModel(
                        installationId: installationID,
                        apnsDeviceToken: "apns-token-1234",
                        apnsEnvironment: .sandbox,
                        platform: .iOS,
                        osVersion: "26.0",
                        appVersion: "1.0.0",
                        buildNumber: "100",
                        locationAuth: .always,
                        lastSeenAt: now,
                        isSubscribed: true
                    ).create(on: database)

                    try await DevicePresenceModel(
                        installationId: installationID,
                        capturedAt: now,
                        receivedAt: now,
                        locationAgeSeconds: 5,
                        horizontalAccuracyMeters: 10,
                        cellScheme: .ugcOnly,
                        h3Cell: nil,
                        h3Resolution: nil,
                        county: nil,
                        zone: nil,
                        fireZone: nil,
                        source: .settingsPreference,
                        countyLabel: nil,
                        fireZoneLabel: nil
                    ).create(on: database)

                    try await RepairDevicePresenceSourceConstraintForExpandedLocationUploadSources().revert(on: database)

                    let storedPresence = try await DevicePresenceModel.find(installationID, on: database)
                    #expect(storedPresence?.source == .settingsPreference)
                    throw Rollback.afterAssertions
                }
            } catch Rollback.afterAssertions {
                // Expected: restore shared schema and fixture rows.
            }
        }
    }
}
