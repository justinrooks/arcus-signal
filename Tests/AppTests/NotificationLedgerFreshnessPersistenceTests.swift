@testable import App
import Foundation
import Fluent
import FluentPostgresDriver
import FluentSQL
import Testing
import Vapor

@Suite("Notification ledger freshness persistence", .serialized)
struct NotificationLedgerFreshnessPersistenceTests {
    private func withApp(test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            let databaseURL = Environment.get("DATABASE_URL")
                ?? "postgres://arcus:arcus@127.0.0.1:5432/arcus_signal?tlsmode=disable"
            app.databases.use(try .postgres(url: databaseURL), as: .psql)
            try await bootstrapTables(on: app.db)
            try await test(app)
        } catch {
            Issue.record("Test DB error: \(String(reflecting: error))")
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func bootstrapTables(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS device_installations (
                installation_id UUID PRIMARY KEY,
                apns_device_token TEXT NOT NULL,
                apns_environment TEXT NOT NULL,
                platform TEXT NOT NULL,
                os_version TEXT NOT NULL,
                app_version TEXT NOT NULL,
                build_number TEXT NOT NULL,
                location_auth TEXT NOT NULL,
                is_active BOOLEAN NOT NULL,
                created_at TIMESTAMP NOT NULL,
                updated_at TIMESTAMP NOT NULL,
                last_seen_at TIMESTAMP NOT NULL
            );
            """).run()

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS arcus_series (
                id UUID PRIMARY KEY,
                source TEXT NOT NULL,
                event TEXT NOT NULL,
                source_url TEXT NOT NULL,
                current_revision_urn TEXT NOT NULL,
                current_revision_sent TIMESTAMP NOT NULL,
                message_type TEXT NOT NULL,
                content_fingerprint TEXT NOT NULL,
                state TEXT NOT NULL,
                severity TEXT NOT NULL,
                urgency TEXT NOT NULL,
                certainty TEXT NOT NULL,
                ugc_codes TEXT[] NOT NULL,
                created TIMESTAMP NOT NULL,
                updated TIMESTAMP NOT NULL,
                last_seen_active TIMESTAMP NOT NULL
            );
            """).run()

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS notification_ledger (
                id UUID PRIMARY KEY,
                installation_id UUID NOT NULL REFERENCES device_installations(installation_id) ON DELETE CASCADE,
                series_id UUID NOT NULL REFERENCES arcus_series(id) ON DELETE CASCADE,
                revision_urn TEXT NOT NULL,
                mode TEXT NOT NULL,
                reason TEXT NOT NULL,
                freshness_state TEXT NOT NULL,
                status TEXT,
                apns_error_code TEXT,
                completed_at TIMESTAMP,
                created TIMESTAMP NOT NULL
            );
            """).run()

        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_notification_ledger_identity
            ON notification_ledger (installation_id, series_id, revision_urn);
            """).run()

        try await sql.raw("""
            ALTER TABLE notification_ledger
            ADD COLUMN IF NOT EXISTS status TEXT;
            """).run()

        try await sql.raw("""
            ALTER TABLE notification_ledger
            ADD COLUMN IF NOT EXISTS apns_error_code TEXT;
            """).run()

        try await sql.raw("""
            ALTER TABLE notification_ledger
            ADD COLUMN IF NOT EXISTS completed_at TIMESTAMP;
            """).run()

        try await sql.raw("""
            ALTER TABLE notification_ledger
            ADD COLUMN IF NOT EXISTS freshness_state TEXT NOT NULL DEFAULT 'fresh';
            """).run()
    }

    private func seedInstallation(id: UUID, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        try await sql.raw("""
            INSERT INTO device_installations
                (installation_id, apns_device_token, apns_environment, platform, os_version, app_version,
                 build_number, location_auth, is_active, created_at, updated_at, last_seen_at)
            VALUES
                (\(bind: id), 'token', 'sandbox', 'iOS', '26.0', '1.0.0', '100', 'whenInUse',
                 TRUE, NOW(), NOW(), NOW())
            ON CONFLICT (installation_id) DO NOTHING
            """).run()
    }

    private func seedSeries(id: UUID, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        try await sql.raw("""
            INSERT INTO arcus_series
                (id, source, event, source_url, current_revision_urn, current_revision_sent, message_type,
                 content_fingerprint, state, severity, urgency, certainty, ugc_codes, created, updated, last_seen_active)
            VALUES
                (\(bind: id), 'nws', 'Tornado Warning', 'https://api.weather.gov/alerts/test', 'urn:oid:series',
                 NOW(), 'alert', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                 'active', 'severe', 'immediate', 'observed', ARRAY[]::text[],
                 NOW(), NOW(), NOW())
            ON CONFLICT (id) DO NOTHING
            """).run()
    }

    private func seedAndClaim(
        revisionUrn: String,
        mode: NotificationTargetMode,
        reason: NotificationReason,
        freshnessState: LocationFreshnessState,
        using store: NotificationDeliveryStore,
        on db: any Database
    ) async throws -> (result: LedgerClaimResult, installationID: UUID, seriesID: UUID) {
        let installationID = UUID()
        let seriesID = UUID()
        try await seedInstallation(id: installationID, on: db)
        try await seedSeries(id: seriesID, on: db)

        let result = try await store.claim(
            installationID: installationID,
            seriesID: seriesID,
            revisionUrn: revisionUrn,
            mode: mode,
            reason: reason,
            freshnessState: freshnessState,
            on: db
        )
        return (result, installationID, seriesID)
    }

    @Test("fresh, degraded, and duplicate claims preserve exact original fields")
    func claimSemanticsArePreserved() async throws {
        try await withApp { app in
            let store = NotificationDeliveryStore()
            let fresh = try await seedAndClaim(
                revisionUrn: "urn:oid:fresh-claim",
                mode: .h3,
                reason: .new,
                freshnessState: .fresh,
                using: store,
                on: app.db
            )
            let degraded = try await seedAndClaim(
                revisionUrn: "urn:oid:degraded-claim",
                mode: .ugc,
                reason: .update,
                freshnessState: .degraded,
                using: store,
                on: app.db
            )
            let duplicate = try await store.claim(
                installationID: fresh.installationID,
                seriesID: fresh.seriesID,
                revisionUrn: "urn:oid:fresh-claim",
                mode: .ugc,
                reason: .update,
                freshnessState: .degraded,
                on: app.db
            )

            #expect(fresh.result.inserted)
            #expect(degraded.result.inserted)
            #expect(duplicate.inserted == false)
            #expect(duplicate.id == nil)

            let freshRows = try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == fresh.installationID)
                .filter(\.$series.$id == fresh.seriesID)
                .filter(\.$revisionUrn == "urn:oid:fresh-claim")
                .all()
            let freshLedger = try #require(freshRows.first)
            let degradedLedger = try #require(
                try await NotificationLedgerModel.find(degraded.result.id, on: app.db)
            )

            #expect(freshRows.count == 1)
            #expect(freshLedger.mode == NotificationTargetMode.h3.rawValue)
            #expect(freshLedger.reason == NotificationReason.new.rawValue)
            #expect(freshLedger.freshnessState == .fresh)
            #expect(freshLedger.status == "claimed")
            #expect(degradedLedger.mode == NotificationTargetMode.ugc.rawValue)
            #expect(degradedLedger.reason == NotificationReason.update.rawValue)
            #expect(degradedLedger.freshnessState == .degraded)
            #expect(degradedLedger.status == "claimed")
        }
    }

    @Test("sent, APNs-failed, and generic-failed completions preserve terminal semantics")
    func completionSemanticsArePreserved() async throws {
        try await withApp { app in
            let store = NotificationDeliveryStore()
            let sent = try await seedAndClaim(
                revisionUrn: "urn:oid:sent-completion",
                mode: .ugc,
                reason: .update,
                freshnessState: .degraded,
                using: store,
                on: app.db
            ).result
            let failed = try await seedAndClaim(
                revisionUrn: "urn:oid:failed-completion",
                mode: .h3,
                reason: .new,
                freshnessState: .degraded,
                using: store,
                on: app.db
            ).result
            let genericFailed = try await seedAndClaim(
                revisionUrn: "urn:oid:generic-failed-completion",
                mode: .h3,
                reason: .new,
                freshnessState: .fresh,
                using: store,
                on: app.db
            ).result
            let existing = try #require(
                try await NotificationLedgerModel.find(genericFailed.id, on: app.db)
            )
            existing.apnsErrorCode = "existing-code"
            try await existing.save(on: app.db)

            try await store.completeSent(claimID: sent.id, on: app.db)
            try await store.completeFailed(
                claimID: failed.id,
                apnsErrorCode: "BadDeviceToken",
                on: app.db
            )
            try await store.completeFailed(
                claimID: genericFailed.id,
                apnsErrorCode: nil,
                on: app.db
            )

            let sentLedger = try #require(try await NotificationLedgerModel.find(sent.id, on: app.db))
            let failedLedger = try #require(try await NotificationLedgerModel.find(failed.id, on: app.db))
            let genericLedger = try #require(
                try await NotificationLedgerModel.find(genericFailed.id, on: app.db)
            )

            #expect(sentLedger.status == "sent")
            #expect(sentLedger.completedAt != nil)
            #expect(sentLedger.mode == NotificationTargetMode.ugc.rawValue)
            #expect(sentLedger.reason == NotificationReason.update.rawValue)
            #expect(sentLedger.freshnessState == .degraded)
            #expect(sentLedger.apnsErrorCode == nil)
            #expect(failedLedger.status == "failed")
            #expect(failedLedger.completedAt != nil)
            #expect(failedLedger.apnsErrorCode == "BadDeviceToken")
            #expect(failedLedger.freshnessState == .degraded)
            #expect(genericLedger.status == "failed")
            #expect(genericLedger.completedAt != nil)
            #expect(genericLedger.apnsErrorCode == "existing-code")
        }
    }

    @Test("missing sent completion is a no-op and missing failed completion remains not found")
    func missingCompletionSemanticsArePreserved() async throws {
        try await withApp { app in
            let store = NotificationDeliveryStore()

            try await store.completeSent(claimID: UUID(), on: app.db)

            do {
                try await store.completeFailed(
                    claimID: UUID(),
                    apnsErrorCode: nil,
                    on: app.db
                )
                Issue.record("Expected missing failed completion to throw")
            } catch let error as Abort {
                #expect(error.status == .notFound)
            }
        }
    }
}
