@testable import App
import ArcusCore
import Foundation
import Testing
import Vapor
import VaporTesting

@Suite("Device controller", .serialized)
struct DeviceControllerTests {
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

    private func makePayload(
        installationId: String,
        source: LocationUploadSource
    ) -> LocationSnapshotPushPayload {
        LocationSnapshotPushPayload(
            capturedAt: Date(timeIntervalSince1970: 1_717_513_600),
            locationAgeSeconds: 12,
            horizontalAccuracyMeters: 25,
            cellScheme: CellScheme.ugcOnly.rawValue,
            h3Cell: nil,
            h3Resolution: nil,
            county: "COC031",
            zone: "COZ041",
            fireZone: "COF241",
            apnsDeviceToken: "abcd1234efgh5678ijkl9012mnop3456",
            installationId: installationId,
            source: source.rawValue,
            auth: LocationAuth.always.rawValue,
            appVersion: "1.0.0",
            buildNumber: "100",
            platform: Platform.iOS.rawValue,
            osVersion: "26.0",
            apnsEnvironment: APNsEnvironment.sandbox.rawValue,
            countyLabel: "Boulder County",
            fireZoneLabel: "Front Range",
            isSubscribed: true
        )
    }

    @Test("POST /api/v1/devices/location-snapshots persists expanded source values")
    func createPersistsExpandedSourceValues() async throws {
        try await withApp { app in
            let cases: [LocationUploadSource] = [.settingsPreference, .foregroundPrime]

            for source in cases {
                let installationID = UUID()
                let payload = makePayload(
                    installationId: installationID.uuidString,
                    source: source
                )

                try await app.testing().test(
                    .POST,
                    "api/v1/devices/location-snapshots",
                    beforeRequest: { req in
                        req.headers.contentType = .json
                        req.body = .init(data: try JSONEncoder().encode(payload))
                    },
                    afterResponse: { res async in
                        #expect(res.status == .ok)
                    }
                )

                let storedPresence = try await DevicePresenceModel.find(installationID, on: app.db)
                #expect(storedPresence != nil)
                #expect(storedPresence?.source == source)
            }
        }
    }
}
