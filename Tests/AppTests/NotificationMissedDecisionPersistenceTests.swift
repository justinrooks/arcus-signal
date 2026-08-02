@testable import App
import Foundation
import Fluent
import FluentSQL
import Testing
import Vapor

@Suite("Notification missed decision persistence", .serialized)
struct NotificationMissedDecisionPersistenceTests {
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
            CREATE TABLE IF NOT EXISTS notification_missed_decisions (
                id UUID PRIMARY KEY,
                installation_id UUID NOT NULL REFERENCES device_installations(installation_id) ON DELETE CASCADE,
                series_id UUID NOT NULL REFERENCES arcus_series(id) ON DELETE CASCADE,
                revision_urn TEXT NOT NULL,
                mode TEXT NOT NULL,
                reason TEXT NOT NULL,
                freshness_state TEXT NOT NULL,
                miss_reason TEXT NOT NULL,
                permission_mode TEXT NOT NULL,
                captured_at TIMESTAMP NOT NULL,
                received_at TIMESTAMP NOT NULL,
                evaluated_at TIMESTAMP NOT NULL,
                created TIMESTAMP NOT NULL
            );
            """).run()

        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_notification_missed_decisions_identity
            ON notification_missed_decisions
            (installation_id, series_id, revision_urn, mode, reason, miss_reason);
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
                created TIMESTAMP NOT NULL
            );
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

    private func seedSeries(id: UUID, revisionUrn _: String, on db: any Database) async throws {
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

    @Test("stale missed decision can be inserted")
    func insertsStaleMissDecision() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:test-revision"
            let now = Date()
            let capturedAt = now.addingTimeInterval(-3_600)
            let receivedAt = now.addingTimeInterval(-3_500)

            try await seedInstallation(id: installationID, on: app.db)
            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)

            let store = NotificationMissedDecisionStore()
            let result = try await store.insertStaleMissDecision(
                .init(
                    installationID: installationID,
                    seriesID: seriesID,
                    revisionUrn: revisionUrn,
                    mode: .h3,
                    reason: .new,
                    freshnessState: .stale,
                    missReason: .staleLocation,
                    permissionMode: .whenInUse,
                    capturedAt: capturedAt,
                    receivedAt: receivedAt,
                    evaluatedAt: now
                ),
                on: app.db
            )

            #expect(result.inserted)
            #expect(result.id != nil)

            let row = try await NotificationMissedDecisionModel.find(
                result.id,
                on: app.db
            )
            #expect(row != nil)
            #expect(row?.freshnessState == .stale)
            #expect(row?.permissionMode == .whenInUse)
            #expect(row?.missReason == .staleLocation)

            let ledgerCount = try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == installationID)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .count()
            #expect(ledgerCount == 0)
        }
    }

    @Test("duplicate logical stale misses are ignored")
    func ignoresDuplicateLogicalMiss() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:test-revision"
            let now = Date()
            let capturedAt = now.addingTimeInterval(-3_600)
            let receivedAt = now.addingTimeInterval(-3_500)

            try await seedInstallation(id: installationID, on: app.db)
            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)

            let store = NotificationMissedDecisionStore()
            let input = NotificationMissedDecisionInsertInput(
                installationID: installationID,
                seriesID: seriesID,
                revisionUrn: revisionUrn,
                mode: .ugc,
                reason: .update,
                freshnessState: .stale,
                missReason: .staleLocation,
                permissionMode: .always,
                capturedAt: capturedAt,
                receivedAt: receivedAt,
                evaluatedAt: now
            )

            let first = try await store.insertStaleMissDecision(input, on: app.db)
            let second = try await store.insertStaleMissDecision(input, on: app.db)

            #expect(first.inserted)
            #expect(second.inserted == false)

            let count = try await NotificationMissedDecisionModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == installationID)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .count()

            #expect(count == 1)
        }
    }
}
