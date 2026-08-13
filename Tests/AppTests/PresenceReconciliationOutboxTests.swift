@testable import App
import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor

@Suite("Presence reconciliation outbox persistence", .serialized)
struct PresenceReconciliationOutboxTests {
    private let store = PresenceReconciliationOutboxStore()

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

    private func createInstallation(
        id: UUID,
        on database: any Database
    ) async throws {
        try await DeviceInstallationModel(
            installationId: id,
            apnsDeviceToken: "test-apns-token",
            apnsEnvironment: .sandbox,
            platform: .iOS,
            osVersion: "26.0",
            appVersion: "1.0.0",
            buildNumber: "100",
            locationAuth: .always,
            lastSeenAt: .now,
            isSubscribed: true
        ).create(on: database)
    }

    @Test("migration can revert and prepare the outbox table")
    func migrationCanRevertAndPrepareTheTable() async throws {
        try await withApp { app in
            try await withRollbackTransaction(on: app) { database in
                guard let sql = database as? any SQLDatabase else {
                    throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
                }
                try await sql.raw(
                    "LOCK TABLE presence_reconciliation_outbox IN ACCESS EXCLUSIVE MODE"
                ).run()

                let migration = CreatePresenceReconciliationOutbox()
                try await migration.revert(on: database)
                try await migration.prepare(on: database)

                let installationID = UUID()
                try await createInstallation(id: installationID, on: database)
                try await PresenceReconciliationOutboxModel(
                    installationID: installationID,
                    presenceCapturedAt: .now,
                    triggerCategory: .firstUsablePresence,
                    targetingFingerprint: "opaque-fingerprint"
                ).create(on: database)

                let rows = try await PresenceReconciliationOutboxModel.query(on: database).all()
                #expect(rows.count == 1)
            }
        }
    }

    @Test("insert participates in the caller-owned transaction")
    func insertParticipatesInCallerOwnedTransaction() async throws {
        try await withApp { app in
            let installationID = UUID()

            try await withRollbackTransaction(on: app) { database in
                try await createInstallation(id: installationID, on: database)
                let result = try await store.insert(
                    installationID: installationID,
                    presenceCapturedAt: Date(timeIntervalSince1970: 1_717_513_600),
                    triggerCategory: .firstUsablePresence,
                    targetingFingerprint: "opaque-fingerprint",
                    on: database
                )

                #expect(result.inserted)
                #expect(result.id != nil)
                #expect(try await PresenceReconciliationOutboxModel.query(on: database).count() == 1)
            }

            #expect(try await PresenceReconciliationOutboxModel.query(on: app.db).count() == 0)
        }
    }

    @Test("duplicate immutable intents are absorbed by the database identity")
    func duplicateIntentsAreAbsorbedByTheDatabaseIdentity() async throws {
        try await withApp { app in
            try await withRollbackTransaction(on: app) { database in
                let installationID = UUID()
                try await createInstallation(id: installationID, on: database)
                let capturedAt = Date(timeIntervalSince1970: 1_717_513_600)

                let first = try await store.insert(
                    installationID: installationID,
                    presenceCapturedAt: capturedAt,
                    triggerCategory: .movedWhileUsable,
                    targetingFingerprint: "opaque-fingerprint",
                    on: database
                )
                let duplicate = try await store.insert(
                    installationID: installationID,
                    presenceCapturedAt: capturedAt,
                    triggerCategory: .movedWhileUsable,
                    targetingFingerprint: "opaque-fingerprint",
                    on: database
                )

                #expect(first.inserted)
                #expect(!duplicate.inserted)
                #expect(try await PresenceReconciliationOutboxModel.query(on: database).count() == 1)
            }
        }
    }

    @Test("ready intents are selected by deterministic availability order")
    func readyIntentsAreSelectedByAvailabilityOrder() async throws {
        try await withApp { app in
            try await withRollbackTransaction(on: app) { database in
                let installationID = UUID()
                try await createInstallation(id: installationID, on: database)
                let base = Date(timeIntervalSince1970: 1_717_513_600)

                let later = try await store.insert(
                    installationID: installationID,
                    presenceCapturedAt: base.addingTimeInterval(1),
                    triggerCategory: .firstUsablePresence,
                    targetingFingerprint: "later",
                    availableAt: base.addingTimeInterval(20),
                    on: database
                )
                let earlier = try await store.insert(
                    installationID: installationID,
                    presenceCapturedAt: base.addingTimeInterval(2),
                    triggerCategory: .movedWhileUsable,
                    targetingFingerprint: "earlier",
                    availableAt: base.addingTimeInterval(10),
                    on: database
                )
                let future = try await store.insert(
                    installationID: installationID,
                    presenceCapturedAt: base.addingTimeInterval(3),
                    triggerCategory: .becameUsable,
                    targetingFingerprint: "future",
                    availableAt: base.addingTimeInterval(40),
                    on: database
                )

                let ready = try await store.readyIntents(
                    availableThrough: base.addingTimeInterval(20),
                    limit: 10,
                    on: database
                )

                #expect(ready.map(\.id) == [earlier.id, later.id])
                #expect(!ready.contains { $0.id == future.id })
            }
        }
    }

    @Test("queue-handoff outcomes retain retry metadata and cannot overwrite completion")
    func queueHandoffOutcomesRetainRetryMetadataAndCannotOverwriteCompletion() async throws {
        try await withApp { app in
            try await withRollbackTransaction(on: app) { database in
                let installationID = UUID()
                try await createInstallation(id: installationID, on: database)
                let inserted = try await store.insert(
                    installationID: installationID,
                    presenceCapturedAt: Date(timeIntervalSince1970: 1_717_513_600),
                    triggerCategory: .firstUsablePresence,
                    targetingFingerprint: "opaque-fingerprint",
                    on: database
                )
                let intentID = try #require(inserted.id)
                let retryAt = Date(timeIntervalSince1970: 1_717_513_660)

                #expect(try await store.recordQueueHandoffFailure(
                    intentID: intentID,
                    error: "redis unavailable",
                    nextAvailableAt: retryAt,
                    on: database
                ))

                let failed = try #require(try await PresenceReconciliationOutboxModel.find(intentID, on: database))
                #expect(failed.state == .ready)
                #expect(failed.attemptCount == 1)
                #expect(failed.lastError == "redis unavailable")
                #expect(failed.availableAt == retryAt)

                #expect(try await store.recordQueueHandoffSuccess(intentID: intentID, on: database))

                let completed = try #require(try await PresenceReconciliationOutboxModel.find(intentID, on: database))
                #expect(completed.state == .done)
                #expect(completed.attemptCount == 2)
                #expect(completed.lastError == nil)
                #expect(completed.dispatchedAt != nil)
                #expect(!(try await store.recordQueueHandoffFailure(
                    intentID: intentID,
                    error: "late error",
                    nextAvailableAt: retryAt,
                    on: database
                )))
            }
        }
    }

    @Test("terminal handoff failure cannot be retried or completed")
    func terminalHandoffFailureCannotBeRetriedOrCompleted() async throws {
        try await withApp { app in
            try await withRollbackTransaction(on: app) { database in
                let installationID = UUID()
                try await createInstallation(id: installationID, on: database)
                let inserted = try await store.insert(
                    installationID: installationID,
                    presenceCapturedAt: Date(timeIntervalSince1970: 1_717_513_600),
                    triggerCategory: .firstUsablePresence,
                    targetingFingerprint: "opaque-fingerprint",
                    on: database
                )
                let intentID = try #require(inserted.id)

                #expect(try await store.markDead(
                    intentID: intentID,
                    error: "retry budget exhausted",
                    on: database
                ))

                let dead = try #require(try await PresenceReconciliationOutboxModel.find(intentID, on: database))
                #expect(dead.state == .dead)
                #expect(dead.lastError == "retry budget exhausted")
                #expect(!(try await store.recordQueueHandoffSuccess(intentID: intentID, on: database)))
                #expect(!(try await store.recordQueueHandoffFailure(
                    intentID: intentID,
                    error: "late error",
                    nextAvailableAt: .now,
                    on: database
                )))
            }
        }
    }
}
