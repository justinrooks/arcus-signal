@testable import App
import Fluent
import FluentPostgresDriver
import FluentSQL
import Foundation
import Testing
import Vapor

@Suite("Notification send job candidate queries", .serialized)
struct NotificationSendJobCandidateQueryTests {
    private enum Rollback: Error {
        case afterAssertions
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func withApp(test: @escaping @Sendable (any Database) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            let databaseURL = Environment.get("DATABASE_URL")
                ?? "postgres://arcus:arcus@127.0.0.1:5432/arcus_signal?tlsmode=disable"
            app.databases.use(try .postgres(url: databaseURL), as: .psql)
            try await bootstrapTables(on: app.db)
            do {
                try await app.db.transaction { database in
                    try await test(database)
                    throw Rollback.afterAssertions
                }
            } catch Rollback.afterAssertions {
                // Expected: keep shared integration-test tables unchanged.
            }
        } catch {
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
                is_subscribed BOOLEAN NOT NULL DEFAULT TRUE,
                created_at TIMESTAMP NOT NULL,
                updated_at TIMESTAMP NOT NULL,
                last_seen_at TIMESTAMP NOT NULL
            );
            """).run()

        try await sql.raw("""
            ALTER TABLE device_installations
            ADD COLUMN IF NOT EXISTS is_subscribed BOOLEAN NOT NULL DEFAULT TRUE;
            """).run()

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS device_presence (
                installation_id UUID PRIMARY KEY REFERENCES device_installations(installation_id) ON DELETE CASCADE,
                captured_at TIMESTAMP NOT NULL,
                received_at TIMESTAMP NOT NULL,
                location_age_seconds DOUBLE PRECISION NOT NULL,
                horizontal_accuracy_meters DOUBLE PRECISION NOT NULL,
                cell_scheme TEXT NOT NULL,
                h3_cell BIGINT,
                h3_resolution INTEGER,
                county TEXT,
                zone TEXT,
                fire_zone TEXT,
                source TEXT NOT NULL,
                created_at TIMESTAMP NOT NULL,
                updated_at TIMESTAMP NOT NULL,
                county_label TEXT,
                fire_zone_label TEXT
            );
            """).run()
    }

    private func seedCandidate(
        id: UUID,
        capturedAt: Date,
        h3Cell: Int64?,
        county: String?,
        isActive: Bool = true,
        isSubscribed: Bool = true,
        token: String = "token",
        on db: any Database
    ) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("""
            INSERT INTO device_installations
                (installation_id, apns_device_token, apns_environment, platform, os_version, app_version,
                 build_number, location_auth, is_active, is_subscribed, created_at, updated_at, last_seen_at)
            VALUES
                (\(bind: id), \(bind: token), 'sandbox', 'iOS', '26.0', '1.0.0', '100',
                 'always', \(bind: isActive), \(bind: isSubscribed), \(bind: now), \(bind: now), \(bind: now));
            """).run()

        try await sql.raw("""
            INSERT INTO device_presence
                (installation_id, captured_at, received_at, location_age_seconds, horizontal_accuracy_meters,
                 cell_scheme, h3_cell, h3_resolution, county, zone, fire_zone, source, created_at, updated_at,
                 county_label, fire_zone_label)
            VALUES
                (\(bind: id), \(bind: capturedAt), \(bind: capturedAt), 0, 0,
                 \(bind: h3Cell == nil ? "ugc-only" : "h3"), \(bind: h3Cell), \(bind: h3Cell == nil ? nil : 8),
                 \(bind: county), NULL, NULL, 'foreground', \(bind: now), \(bind: now), \(bind: county), NULL);
            """).run()
    }

    private func seedCandidates(
        h3Cell: Int64?,
        county: String?,
        on db: any Database
    ) async throws -> (included: Set<UUID>, excluded: Set<UUID>) {
        let cutoff = now.addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold)
        let newer = UUID()
        let exactlyAtCutoff = UUID()
        let older = UUID()
        let inactive = UUID()
        let unsubscribed = UUID()
        let tokenless = UUID()

        try await seedCandidate(id: newer, capturedAt: cutoff.addingTimeInterval(1), h3Cell: h3Cell, county: county, on: db)
        try await seedCandidate(id: exactlyAtCutoff, capturedAt: cutoff, h3Cell: h3Cell, county: county, on: db)
        try await seedCandidate(id: older, capturedAt: cutoff.addingTimeInterval(-1), h3Cell: h3Cell, county: county, on: db)
        try await seedCandidate(id: inactive, capturedAt: now, h3Cell: h3Cell, county: county, isActive: false, on: db)
        try await seedCandidate(id: unsubscribed, capturedAt: now, h3Cell: h3Cell, county: county, isSubscribed: false, on: db)
        try await seedCandidate(id: tokenless, capturedAt: now, h3Cell: h3Cell, county: county, token: "", on: db)

        return ([newer, exactlyAtCutoff], [older, inactive, unsubscribed, tokenless])
    }

    @Test("H3 candidates include fresh and cutoff presence while preserving installation exclusions")
    func h3CandidatesFilterHardStalePresence() async throws {
        try await withApp { database in
            let h3Cell = Int64(
                UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(15),
                radix: 16
            )!
            let expected = try await seedCandidates(h3Cell: h3Cell, county: nil, on: database)
            let cutoff = now.addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold)

            let candidates = try await NotificationSendJob().loadH3Candidates(
                cells: [h3Cell],
                capturedAtOrAfter: cutoff,
                on: database
            )
            let actual = Set(candidates.map(\.id))

            #expect(actual == expected.included)
            #expect(actual.isDisjoint(with: expected.excluded))
        }
    }

    @Test("UGC candidates include fresh and cutoff presence while preserving installation exclusions")
    func ugcCandidatesFilterHardStalePresence() async throws {
        try await withApp { database in
            let county = "test-\(UUID().uuidString)"
            let expected = try await seedCandidates(h3Cell: nil, county: county, on: database)
            let cutoff = now.addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold)

            let candidates = try await NotificationSendJob().loadUGCCandidates(
                ugcCodes: [county],
                capturedAtOrAfter: cutoff,
                on: database
            )
            let actual = Set(candidates.map(\.id))

            #expect(actual == expected.included)
            #expect(actual.isDisjoint(with: expected.excluded))
        }
    }
}
