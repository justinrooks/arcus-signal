@testable import App
import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor

@Suite("Notification candidate store queries", .serialized)
struct NotificationSendJobCandidateQueryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

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
        zone: String? = nil,
        fireZone: String? = nil,
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
                (\(bind: id), \(bind: capturedAt), \(bind: capturedAt.addingTimeInterval(30)), 0, 0,
                 \(bind: h3Cell == nil ? "ugc-only" : "h3"), \(bind: h3Cell), \(bind: h3Cell == nil ? nil : 8),
                 \(bind: county), \(bind: zone), \(bind: fireZone), 'foreground', \(bind: now), \(bind: now),
                 \(bind: county), 'Test Fire Zone');
            """).run()
    }

    private func seedCandidates(
        h3Cell: Int64?,
        county: String?,
        on db: any Database
    ) async throws -> (atCutoff: UUID, included: Set<UUID>, excluded: Set<UUID>) {
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

        return (exactlyAtCutoff, [newer, exactlyAtCutoff], [older, inactive, unsubscribed, tokenless])
    }

    private func assertDecodedFields(
        for candidate: NotificationCandidate,
        id: UUID,
        capturedAt: Date,
        countyLabel: String?
    ) {
        #expect(candidate.id == id)
        #expect(candidate.apnsToken == "token")
        #expect(candidate.apnsEnvironment == "sandbox")
        #expect(candidate.locationAuthRaw == "always")
        #expect(candidate.locationAuth == .always)
        #expect(candidate.capturedAt == capturedAt)
        #expect(candidate.receivedAt == capturedAt.addingTimeInterval(30))
        #expect(candidate.countyLabel == countyLabel)
        #expect(candidate.fireZoneLabel == "Test Fire Zone")
    }

    @Test("H3 candidates include fresh and cutoff presence while preserving installation exclusions")
    func h3CandidatesFilterHardStalePresence() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            try await withRollbackTransaction(on: app) { database in
                let h3Cell = Int64(
                    UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(15),
                    radix: 16
                )!
                let expected = try await seedCandidates(h3Cell: h3Cell, county: nil, on: database)
                let cutoff = now.addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold)

                let candidates = try await NotificationCandidateStore().loadH3Candidates(
                    cells: [h3Cell],
                    capturedAtOrAfter: cutoff,
                    on: database
                )
                let actual = Set(candidates.map(\.id))

                #expect(actual == expected.included)
                #expect(actual.isDisjoint(with: expected.excluded))
                let cutoffCandidate = try #require(candidates.first { $0.id == expected.atCutoff })
                assertDecodedFields(for: cutoffCandidate, id: expected.atCutoff, capturedAt: cutoff, countyLabel: nil)
            }
        }
    }

    @Test("H3 candidates return empty for empty cells")
    func h3CandidatesReturnEmptyForEmptyCells() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            try await withRollbackTransaction(on: app) { database in
                let candidates = try await NotificationCandidateStore().loadH3Candidates(
                    cells: [],
                    capturedAtOrAfter: now,
                    on: database
                )

                #expect(candidates.isEmpty)
            }
        }
    }

    @Test("UGC candidates include fresh and cutoff presence while preserving installation exclusions")
    func ugcCandidatesFilterHardStalePresence() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            try await withRollbackTransaction(on: app) { database in
                let county = "test-\(UUID().uuidString)"
                let expected = try await seedCandidates(h3Cell: nil, county: county, on: database)
                let cutoff = now.addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold)
                let zoneOnly = UUID()
                let fireZoneOnly = UUID()
                try await seedCandidate(
                    id: zoneOnly,
                    capturedAt: cutoff,
                    h3Cell: nil,
                    county: nil,
                    zone: county,
                    on: database
                )
                try await seedCandidate(
                    id: fireZoneOnly,
                    capturedAt: cutoff,
                    h3Cell: nil,
                    county: nil,
                    fireZone: county,
                    on: database
                )

                let candidates = try await NotificationCandidateStore().loadUGCCandidates(
                    ugcCodes: [county],
                    capturedAtOrAfter: cutoff,
                    on: database
                )
                let actual = Set(candidates.map(\.id))

                #expect(actual == expected.included.union([zoneOnly, fireZoneOnly]))
                #expect(actual.isDisjoint(with: expected.excluded))
                let cutoffCandidate = try #require(candidates.first { $0.id == expected.atCutoff })
                assertDecodedFields(for: cutoffCandidate, id: expected.atCutoff, capturedAt: cutoff, countyLabel: county)
            }
        }
    }

    @Test("installation constraint applies to H3 and UGC candidates")
    func installationConstraintAppliesToBothCandidatePaths() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            try await withRollbackTransaction(on: app) { database in
                let h3Cell = Int64(
                    UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(15),
                    radix: 16
                )!
                let otherH3Cell = h3Cell + 1
                let ugcCode = "test-\(UUID().uuidString)"
                let h3Target = UUID()
                let movedH3Target = UUID()
                let ugcTarget = UUID()
                let movedUGCTarget = UUID()

                try await seedCandidate(id: h3Target, capturedAt: now, h3Cell: h3Cell, county: nil, on: database)
                try await seedCandidate(
                    id: movedH3Target,
                    capturedAt: now,
                    h3Cell: otherH3Cell,
                    county: nil,
                    on: database
                )
                try await seedCandidate(id: ugcTarget, capturedAt: now, h3Cell: nil, county: ugcCode, on: database)
                try await seedCandidate(
                    id: movedUGCTarget,
                    capturedAt: now,
                    h3Cell: nil,
                    county: "other-\(ugcCode)",
                    on: database
                )

                let h3Candidates = try await NotificationCandidateStore().loadH3Candidates(
                    cells: [h3Cell],
                    capturedAtOrAfter: now.addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold),
                    installationId: h3Target,
                    on: database
                )
                let movedH3Candidates = try await NotificationCandidateStore().loadH3Candidates(
                    cells: [h3Cell],
                    capturedAtOrAfter: now.addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold),
                    installationId: movedH3Target,
                    on: database
                )
                let ugcCandidates = try await NotificationCandidateStore().loadUGCCandidates(
                    ugcCodes: [ugcCode],
                    capturedAtOrAfter: now.addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold),
                    installationId: ugcTarget,
                    on: database
                )
                let movedUGCCandidates = try await NotificationCandidateStore().loadUGCCandidates(
                    ugcCodes: [ugcCode],
                    capturedAtOrAfter: now.addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold),
                    installationId: movedUGCTarget,
                    on: database
                )

                #expect(h3Candidates.map(\.id) == [h3Target])
                #expect(movedH3Candidates.isEmpty)
                #expect(ugcCandidates.map(\.id) == [ugcTarget])
                #expect(movedUGCCandidates.isEmpty)
            }
        }
    }
}
