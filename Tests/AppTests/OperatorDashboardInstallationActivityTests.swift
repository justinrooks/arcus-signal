@testable import App
import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor

@Suite("Operator dashboard installation activity", .serialized)
struct OperatorDashboardInstallationActivityTests {
    private enum Rollback: Error {
        case afterAssertions
    }

    private let now = Date(timeIntervalSince1970: 1_775_649_600) // 2026-04-08T12:00:00Z

    private func withApp(test: @escaping @Sendable (any SQLDatabase) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            do {
                try await app.db.transaction { database in
                    guard let sql = database as? any SQLDatabase else {
                        throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
                    }

                    try await sql.raw("""
                        CREATE TEMPORARY TABLE installation_activity_daily (
                            installation_id UUID NOT NULL,
                            activity_date DATE NOT NULL,
                            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                            UNIQUE (installation_id, activity_date)
                        ) ON COMMIT DROP
                    """).run()
                    try await sql.raw("""
                        CREATE TEMPORARY TABLE device_presence (
                            installation_id UUID PRIMARY KEY,
                            county TEXT,
                            zone TEXT,
                            fire_zone TEXT
                        ) ON COMMIT DROP
                    """).run()

                    try await test(sql)
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

    private func seedActivity(
        installationID: UUID,
        activityDate: String,
        on sql: any SQLDatabase
    ) async throws {
        try await sql.raw("""
            INSERT INTO installation_activity_daily (installation_id, activity_date)
            VALUES (\(bind: installationID), \(bind: activityDate)::date)
        """).run()
    }

    private func seedPresence(
        installationID: UUID,
        county: String? = nil,
        zone: String? = nil,
        fireZone: String? = nil,
        on sql: any SQLDatabase
    ) async throws {
        try await sql.raw("""
            INSERT INTO device_presence (installation_id, county, zone, fire_zone)
            VALUES (\(bind: installationID), \(bind: county), \(bind: zone), \(bind: fireZone))
        """).run()
    }

    @Test("activity aggregate respects UTC boundaries, distinct installations, and state precedence")
    func activityAggregateRespectsUTCBoundariesAndStatePrecedence() async throws {
        try await withApp { sql in
            let colorado = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let texas = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            let kansas = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
            let missingPresence = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
            let invalidPresence = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
            let priorMonth = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
            let nextMonth = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!

            try await seedActivity(installationID: colorado, activityDate: "2026-04-07", on: sql)
            try await seedActivity(installationID: colorado, activityDate: "2026-04-08", on: sql)
            try await seedActivity(installationID: texas, activityDate: "2026-04-01", on: sql)
            try await seedActivity(installationID: kansas, activityDate: "2026-04-08", on: sql)
            try await seedActivity(installationID: missingPresence, activityDate: "2026-04-08", on: sql)
            try await seedActivity(installationID: invalidPresence, activityDate: "2026-04-07", on: sql)
            try await seedActivity(installationID: priorMonth, activityDate: "2026-03-31", on: sql)
            try await seedActivity(installationID: nextMonth, activityDate: "2026-05-01", on: sql)

            try await seedPresence(
                installationID: colorado,
                county: "coc005",
                zone: "TXZ001",
                fireZone: "KSZ001",
                on: sql
            )
            try await seedPresence(
                installationID: texas,
                county: "not-a-ugc",
                zone: "TXZ001",
                fireZone: "KSZ001",
                on: sql
            )
            try await seedPresence(
                installationID: kansas,
                county: "XXC001",
                zone: "XXZ001",
                fireZone: "KSZ001",
                on: sql
            )
            try await seedPresence(
                installationID: invalidPresence,
                county: "XXC001",
                zone: "XXZ001",
                fireZone: "XXZ002",
                on: sql
            )

            let metric = try await OperatorDashboardSnapshotRefresher()
                .loadInstallationActivity(on: sql, now: now)

            #expect(metric.dailyActiveInstallationCount == 3)
            #expect(metric.monthlyActiveInstallationCount == 5)
            #expect(metric.stateBreakdown.map(\.state) == ["CO", "KS", "TX", "Unknown"])
            #expect(metric.stateBreakdown.map(\.activeTodayCount) == [1, 1, 0, 1])
            #expect(metric.stateBreakdown.map(\.activeThisMonthCount) == [1, 1, 1, 2])
            #expect(metric.stateBreakdown.reduce(0) { $0 + $1.activeTodayCount } == metric.dailyActiveInstallationCount)
            #expect(metric.stateBreakdown.reduce(0) { $0 + $1.activeThisMonthCount } == metric.monthlyActiveInstallationCount)
        }
    }

    @Test("activity aggregate returns zeros for empty data")
    func activityAggregateReturnsZerosForEmptyData() async throws {
        try await withApp { sql in
            let metric = try await OperatorDashboardSnapshotRefresher()
                .loadInstallationActivity(on: sql, now: now)

            #expect(metric.dailyActiveInstallationCount == 0)
            #expect(metric.monthlyActiveInstallationCount == 0)
            #expect(metric.stateBreakdown.isEmpty)
        }
    }
}
