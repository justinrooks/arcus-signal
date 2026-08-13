@testable import App
import ArcusCore
import Fluent
import FluentSQL
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
        source: LocationUploadSource = .foregroundPrime,
        capturedAt: Date = .now,
        county: String? = "COC031",
        zone: String? = "COZ041",
        fireZone: String? = "COF241",
        isSubscribed: Bool? = true,
        auth: LocationAuth = .always,
        cellScheme: CellScheme = .ugcOnly,
        h3Cell: Int64? = nil,
        h3Resolution: Int? = nil,
        appVersion: String = "1.0.0"
    ) -> LocationSnapshotPushPayload {
        LocationSnapshotPushPayload(
            capturedAt: capturedAt,
            locationAgeSeconds: 12,
            horizontalAccuracyMeters: 25,
            cellScheme: cellScheme.rawValue,
            h3Cell: h3Cell,
            h3Resolution: h3Resolution,
            county: county,
            zone: zone,
            fireZone: fireZone,
            apnsDeviceToken: "abcd1234efgh5678ijkl9012mnop3456",
            installationId: installationId,
            source: source.rawValue,
            auth: auth.rawValue,
            appVersion: appVersion,
            buildNumber: "100",
            platform: Platform.iOS.rawValue,
            osVersion: "26.0",
            apnsEnvironment: APNsEnvironment.sandbox.rawValue,
            countyLabel: "Boulder County",
            fireZoneLabel: "Front Range",
            isSubscribed: isSubscribed
        )
    }

    private func submit(
        _ payload: LocationSnapshotPushPayload,
        to app: Application,
        expecting status: HTTPResponseStatus = .ok
    ) async throws {
        try await app.testing().test(
            .POST,
            "api/v1/devices/location-snapshots",
            beforeRequest: { req in
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                req.headers.contentType = .json
                req.body = .init(data: try encoder.encode(payload))
            },
            afterResponse: { res async in
                #expect(res.status == status)
            }
        )
    }

    private func intents(
        for installationID: UUID,
        in app: Application
    ) async throws -> [PresenceReconciliationOutboxModel] {
        try await PresenceReconciliationOutboxModel.query(on: app.db)
            .filter(\.$installation.$id == installationID)
            .all()
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

                try await submit(payload, to: app)

                let storedPresence = try await DevicePresenceModel.find(installationID, on: app.db)
                #expect(storedPresence != nil)
                #expect(storedPresence?.source == source)
            }
        }
    }

    @Test("first usable presence records a reconciliation intent")
    func firstUsablePresenceRecordsIntent() async throws {
        try await withApp { app in
            let installationID = UUID()
            let capturedAt = Date()

            try await submit(makePayload(installationId: installationID.uuidString, capturedAt: capturedAt), to: app)

            let intent = try #require(try await intents(for: installationID, in: app).first)
            #expect(abs(intent.presenceCapturedAt.timeIntervalSince(capturedAt)) < 1)
            #expect(intent.triggerCategory == .firstUsablePresence)
        }
    }

    @Test("changed persisted targeting fields record a movement intent")
    func targetingFingerprintChangeRecordsIntent() async throws {
        try await withApp { app in
            let installationID = UUID()
            let capturedAt = Date().addingTimeInterval(-30)
            try await submit(makePayload(installationId: installationID.uuidString, capturedAt: capturedAt), to: app)
            try await submit(makePayload(
                installationId: installationID.uuidString,
                capturedAt: capturedAt.addingTimeInterval(1),
                county: "COC013"
            ), to: app)

            let intents = try await intents(for: installationID, in: app)
            #expect(intents.map(\.triggerCategory).contains(.firstUsablePresence))
            #expect(intents.map(\.triggerCategory).contains(.movedWhileUsable))
        }
    }

    @Test("equal captured timestamps are accepted and record movement")
    func equalTimestampChangeRecordsMovementIntent() async throws {
        try await withApp { app in
            let installationID = UUID()
            let capturedAt = Date().addingTimeInterval(-30)
            try await submit(makePayload(installationId: installationID.uuidString, capturedAt: capturedAt), to: app)
            try await submit(makePayload(
                installationId: installationID.uuidString,
                capturedAt: capturedAt,
                county: "COC013"
            ), to: app)

            let intents = try await intents(for: installationID, in: app)
            let presence = try #require(try await DevicePresenceModel.find(installationID, on: app.db))
            #expect(intents.map(\.triggerCategory).contains(.movedWhileUsable))
            #expect(presence.county == "COC013")
        }
    }

    @Test("installation usability changes are evaluated after persistence")
    func installationUsabilityChangeRecordsIntent() async throws {
        try await withApp { app in
            let installationID = UUID()
            let capturedAt = Date().addingTimeInterval(-30)
            try await submit(makePayload(
                installationId: installationID.uuidString,
                capturedAt: capturedAt,
                isSubscribed: false
            ), to: app)
            try await submit(makePayload(
                installationId: installationID.uuidString,
                capturedAt: capturedAt.addingTimeInterval(1),
                isSubscribed: true
            ), to: app)

            let intents = try await intents(for: installationID, in: app)
            #expect(intents.count == 1)
            #expect(intents.first?.triggerCategory == .becameUsable)
        }
    }

    @Test("intent insertion failure rolls back the location transaction")
    func intentInsertionFailureRollsBackLocationTransaction() async throws {
        try await withApp { app in
            guard let sql = app.db as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
            }

            let installationID = UUID()
            let fingerprint = try StableContentHasher.sha256Hex(of: PresenceTargetingFingerprint(
                h3Cell: nil,
                county: "COC031",
                forecastZone: "COZ041",
                fireZone: "COF241"
            ))
            try await sql.raw("""
                ALTER TABLE presence_reconciliation_outbox
                ADD CONSTRAINT device_controller_test_reject_intent_check
                CHECK (targeting_fingerprint <> '\(unsafeRaw: fingerprint)') NOT VALID
                """).run()
            do {
                try await submit(
                    makePayload(installationId: installationID.uuidString),
                    to: app,
                    expecting: .internalServerError
                )
            } catch {
                try? await sql.raw("""
                    ALTER TABLE presence_reconciliation_outbox
                    DROP CONSTRAINT device_controller_test_reject_intent_check
                    """).run()
                throw error
            }
            try await sql.raw("""
                ALTER TABLE presence_reconciliation_outbox
                DROP CONSTRAINT device_controller_test_reject_intent_check
                """).run()

            #expect(try await DeviceInstallationModel.find(installationID, on: app.db) == nil)
            #expect(try await DevicePresenceModel.find(installationID, on: app.db) == nil)
            #expect(try await intents(for: installationID, in: app).isEmpty)
        }
    }

    @Test("hard-stale presence becoming usable records an intent")
    func stalePresenceBecomingUsableRecordsIntent() async throws {
        try await withApp { app in
            let installationID = UUID()
            let staleCapturedAt = Date().addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold - 1)
            try await submit(makePayload(installationId: installationID.uuidString, capturedAt: staleCapturedAt), to: app)
            try await submit(makePayload(
                installationId: installationID.uuidString,
                capturedAt: Date()
            ), to: app)

            let intents = try await intents(for: installationID, in: app)
            #expect(intents.count == 1)
            #expect(intents.first?.triggerCategory == .becameUsable)
        }
    }

    @Test("heartbeats and source changes do not record extra intents")
    func heartbeatAndSourceChangesDoNotRecordExtraIntents() async throws {
        try await withApp { app in
            let installationID = UUID()
            let capturedAt = Date().addingTimeInterval(-30)
            try await submit(makePayload(installationId: installationID.uuidString, capturedAt: capturedAt), to: app)
            try await submit(makePayload(
                installationId: installationID.uuidString,
                source: .backgroundLocationChange,
                capturedAt: capturedAt.addingTimeInterval(1),
                appVersion: "1.0.1"
            ), to: app)

            let intents = try await intents(for: installationID, in: app)
            #expect(intents.count == 1)
        }
    }

    @Test("targetless presence does not record an intent until targeting becomes usable")
    func targetlessPresenceDoesNotRecordIntent() async throws {
        try await withApp { app in
            let installationID = UUID()
            let capturedAt = Date().addingTimeInterval(-30)
            try await submit(makePayload(
                installationId: installationID.uuidString,
                capturedAt: capturedAt,
                county: nil,
                zone: nil,
                fireZone: nil
            ), to: app)

            #expect(try await intents(for: installationID, in: app).isEmpty)

            try await submit(makePayload(
                installationId: installationID.uuidString,
                capturedAt: capturedAt.addingTimeInterval(1),
                county: "COC013",
                zone: nil,
                fireZone: nil
            ), to: app)

            let intents = try await intents(for: installationID, in: app)
            #expect(intents.count == 1)
            #expect(intents.first?.triggerCategory == .becameUsable)
        }
    }

    @Test("partial presence updates evaluate the persisted targeting fingerprint")
    func partialPresenceUpdateUsesPersistedTargetingFields() async throws {
        try await withApp { app in
            let installationID = UUID()
            let capturedAt = Date().addingTimeInterval(-30)
            let h3Cell: Int64 = 617_700_169_958_293_503
            try await submit(makePayload(
                installationId: installationID.uuidString,
                capturedAt: capturedAt,
                cellScheme: .h3,
                h3Cell: h3Cell,
                h3Resolution: 8
            ), to: app)
            try await submit(makePayload(
                installationId: installationID.uuidString,
                capturedAt: capturedAt.addingTimeInterval(1),
                county: "COC013",
                zone: nil,
                fireZone: nil
            ), to: app)

            let intent = try #require(try await intents(for: installationID, in: app)
                .first { $0.triggerCategory == .movedWhileUsable })
            let expectedFingerprint = try StableContentHasher.sha256Hex(of: PresenceTargetingFingerprint(
                h3Cell: h3Cell,
                county: "COC013",
                forecastZone: "COZ041",
                fireZone: "COF241"
            ))
            #expect(intent.targetingFingerprint == expectedFingerprint)
        }
    }

    @Test("older presence is ignored without recording an intent")
    func olderPresenceDoesNotRecordIntent() async throws {
        try await withApp { app in
            let installationID = UUID()
            let capturedAt = Date().addingTimeInterval(-30)
            try await submit(makePayload(installationId: installationID.uuidString, capturedAt: capturedAt), to: app)
            try await submit(makePayload(
                installationId: installationID.uuidString,
                capturedAt: capturedAt.addingTimeInterval(-1),
                county: "COC013"
            ), to: app)

            let intents = try await intents(for: installationID, in: app)
            let presence = try #require(try await DevicePresenceModel.find(installationID, on: app.db))
            #expect(intents.count == 1)
            #expect(abs(presence.capturedAt.timeIntervalSince(capturedAt)) < 1)
            #expect(presence.county == "COC031")
        }
    }
}
