@testable import App
import Foundation
import Testing
import Vapor
import VaporTesting

@Suite("Device preferences endpoint", .serialized)
struct DevicePreferencesControllerTests {
    private struct DevicePreferencesRequest: Content {
        let installationId: String
        let apnsDeviceToken: String
        let apnsEnvironment: String
        let platform: String
        let osVersion: String
        let appVersion: String
        let buildNumber: String
        let auth: String
        let isSubscribed: Bool
        let source: String
        let reason: String
    }

    private func withApp(
        test: (Application) async throws -> Void
    ) async throws {
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

    private func makeRequest(
        installationId: String = UUID().uuidString,
        apnsDeviceToken: String = "abcd1234efgh5678ijkl9012mnop3456",
        apnsEnvironment: String = "sandbox",
        platform: String = "iOS",
        osVersion: String = "26.0",
        appVersion: String = "1.0.0",
        buildNumber: String = "100",
        auth: String = "always",
        isSubscribed: Bool = true,
        source: String = "settingsPreference",
        reason: String = "preferenceChanged"
    ) -> DevicePreferencesRequest {
        .init(
            installationId: installationId,
            apnsDeviceToken: apnsDeviceToken,
            apnsEnvironment: apnsEnvironment,
            platform: platform,
            osVersion: osVersion,
            appVersion: appVersion,
            buildNumber: buildNumber,
            auth: auth,
            isSubscribed: isSubscribed,
            source: source,
            reason: reason
        )
    }

    @Test("POST /api/v1/devices/preferences inserts installation only")
    func insertsInstallationWithoutPresence() async throws {
        try await withApp { app in
            let installationId = UUID()
            let payload = makeRequest(installationId: installationId.uuidString, isSubscribed: true)

            try await app.testing().test(.POST, "api/v1/devices/preferences", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("abcd1234efgh5678ijkl9012mnop3456") == false)
            })

            let installation = try await DeviceInstallationModel.find(installationId, on: app.db)
            #expect(installation != nil)
            #expect(installation?.isSubscribed == true)

            let presence = try await DevicePresenceModel.find(installationId, on: app.db)
            #expect(presence == nil)
        }
    }

    @Test("POST /api/v1/devices/preferences updates isSubscribed true to false")
    func updatesSubscribedTrueToFalse() async throws {
        try await withApp { app in
            let installationId = UUID()
            let existing = DeviceInstallationModel(
                installationId: installationId,
                apnsDeviceToken: "token-a",
                apnsEnvironment: .sandbox,
                platform: .iOS,
                osVersion: "26.0",
                appVersion: "1.0.0",
                buildNumber: "100",
                locationAuth: .always,
                isSubscribed: true
            )
            try await existing.create(on: app.db)

            let payload = makeRequest(installationId: installationId.uuidString, isSubscribed: false)
            try await app.testing().test(.POST, "api/v1/devices/preferences", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let updated = try await DeviceInstallationModel.find(installationId, on: app.db)
            #expect(updated?.isSubscribed == false)
        }
    }

    @Test("POST /api/v1/devices/preferences updates isSubscribed false to true")
    func updatesSubscribedFalseToTrue() async throws {
        try await withApp { app in
            let installationId = UUID()
            let existing = DeviceInstallationModel(
                installationId: installationId,
                apnsDeviceToken: "token-b",
                apnsEnvironment: .sandbox,
                platform: .iOS,
                osVersion: "26.0",
                appVersion: "1.0.0",
                buildNumber: "100",
                locationAuth: .always,
                isSubscribed: false
            )
            try await existing.create(on: app.db)

            let payload = makeRequest(installationId: installationId.uuidString, isSubscribed: true)
            try await app.testing().test(.POST, "api/v1/devices/preferences", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let updated = try await DeviceInstallationModel.find(installationId, on: app.db)
            #expect(updated?.isSubscribed == true)
        }
    }

    @Test("POST /api/v1/devices/preferences succeeds without location payload fields")
    func succeedsWithoutLocationFields() async throws {
        try await withApp { app in
            let payload = makeRequest()
            try await app.testing().test(.POST, "api/v1/devices/preferences", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
        }
    }

    @Test("POST /api/v1/devices/preferences rejects invalid installationId")
    func rejectsInvalidInstallationId() async throws {
        try await withApp { app in
            let payload = makeRequest(installationId: "not-a-uuid")
            try await app.testing().test(.POST, "api/v1/devices/preferences", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("POST /api/v1/devices/preferences rejects blank APNS token")
    func rejectsBlankToken() async throws {
        try await withApp { app in
            let payload = makeRequest(apnsDeviceToken: "   ")
            try await app.testing().test(.POST, "api/v1/devices/preferences", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("POST /api/v1/devices/preferences rejects invalid enum value")
    func rejectsInvalidEnum() async throws {
        try await withApp { app in
            let payload = makeRequest(platform: "android")
            try await app.testing().test(.POST, "api/v1/devices/preferences", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("POST /api/v1/devices/preferences preserves existing location presence")
    func preservesExistingPresence() async throws {
        try await withApp { app in
            let installationId = UUID()
            let installation = DeviceInstallationModel(
                installationId: installationId,
                apnsDeviceToken: "token-c",
                apnsEnvironment: .sandbox,
                platform: .iOS,
                osVersion: "26.0",
                appVersion: "1.0.0",
                buildNumber: "100",
                locationAuth: .always,
                isSubscribed: true
            )
            try await installation.create(on: app.db)

            let capturedAt = Date(timeIntervalSince1970: 1_000)
            let receivedAt = Date(timeIntervalSince1970: 1_100)
            let presence = DevicePresenceModel(
                installationId: installationId,
                capturedAt: capturedAt,
                receivedAt: receivedAt,
                locationAgeSeconds: 5.0,
                horizontalAccuracyMeters: 10.0,
                cellScheme: .h3,
                h3Cell: 617700169958293503,
                h3Resolution: 8,
                county: "COC013",
                zone: "COZ041",
                fireZone: "COF241",
                source: .foreground,
                countyLabel: "Boulder County",
                fireZoneLabel: "Front Range"
            )
            try await presence.create(on: app.db)

            let payload = makeRequest(installationId: installationId.uuidString, isSubscribed: false)
            try await app.testing().test(.POST, "api/v1/devices/preferences", beforeRequest: { req in
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            let storedPresence = try await DevicePresenceModel.find(installationId, on: app.db)
            #expect(storedPresence != nil)
            #expect(storedPresence?.capturedAt == capturedAt)
            #expect(storedPresence?.receivedAt == receivedAt)
            #expect(storedPresence?.h3Cell == 617700169958293503)
            #expect(storedPresence?.h3Resolution == 8)
            #expect(storedPresence?.county == "COC013")
            #expect(storedPresence?.zone == "COZ041")
            #expect(storedPresence?.fireZone == "COF241")
        }
    }
}
