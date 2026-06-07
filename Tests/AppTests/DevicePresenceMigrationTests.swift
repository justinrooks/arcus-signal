@testable import App
import Foundation
import Testing
import Vapor

@Suite("Device presence migration tests", .serialized)
struct DevicePresenceMigrationTests {
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

    @Test("rollback keeps expanded source values valid")
    func revertPreservesExpandedSources() async throws {
        try await withApp { app in
            let installationID = UUID()
            let now = Date(timeIntervalSince1970: 1_717_513_600)

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
            ).create(on: app.db)

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
            ).create(on: app.db)

            try await UpdateDevicePresenceSourceConstraintForExpandedLocationUploadSources().revert(on: app.db)

            let storedPresence = try await DevicePresenceModel.find(installationID, on: app.db)
            #expect(storedPresence?.source == .settingsPreference)
        }
    }
}
