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

    @Test("fresh candidate claim persists fresh freshness_state")
    func freshClaimPersistsFreshness() async throws {
        try await withApp { app in
            let job = NotificationSendJob()
            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:fresh-claim"

            try await seedInstallation(id: installationID, on: app.db)
            try await seedSeries(id: seriesID, on: app.db)

            let claim = try await job.claimNotificationLedger(
                installationID: installationID,
                seriesID: seriesID,
                revisionUrn: revisionUrn,
                mode: .h3,
                reason: .new,
                freshnessState: .fresh,
                on: app.db
            )

            #expect(claim.inserted)
            let ledger = try await NotificationLedgerModel.find(claim.id, on: app.db)
            #expect(ledger?.freshnessState == .fresh)
            #expect(ledger?.status == "claimed")
        }
    }

    @Test("degraded candidate claim persists degraded freshness_state")
    func degradedClaimPersistsFreshness() async throws {
        try await withApp { app in
            let job = NotificationSendJob()
            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:degraded-claim"

            try await seedInstallation(id: installationID, on: app.db)
            try await seedSeries(id: seriesID, on: app.db)

            let claim = try await job.claimNotificationLedger(
                installationID: installationID,
                seriesID: seriesID,
                revisionUrn: revisionUrn,
                mode: .ugc,
                reason: .update,
                freshnessState: .degraded,
                on: app.db
            )

            #expect(claim.inserted)
            let ledger = try await NotificationLedgerModel.find(claim.id, on: app.db)
            #expect(ledger?.freshnessState == .degraded)
            #expect(ledger?.status == "claimed")
        }
    }

    @Test("failed claimed send keeps original persisted freshness_state")
    func failedClaimKeepsOriginalFreshness() async throws {
        try await withApp { app in
            let job = NotificationSendJob()
            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:failed-claim"

            try await seedInstallation(id: installationID, on: app.db)
            try await seedSeries(id: seriesID, on: app.db)

            let claim = try await job.claimNotificationLedger(
                installationID: installationID,
                seriesID: seriesID,
                revisionUrn: revisionUrn,
                mode: .h3,
                reason: .new,
                freshnessState: .degraded,
                on: app.db
            )

            #expect(claim.inserted)

            guard let existing = try await NotificationLedgerModel.find(claim.id, on: app.db) else {
                Issue.record("Missing claimed ledger row")
                return
            }
            existing.status = "failed"
            existing.completedAt = Date()
            try await existing.save(on: app.db)

            let refreshed = try await NotificationLedgerModel.find(claim.id, on: app.db)
            #expect(refreshed?.status == "failed")
            #expect(refreshed?.freshnessState == .degraded)
        }
    }
}
