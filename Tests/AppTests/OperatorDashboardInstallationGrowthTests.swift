@testable import App
import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor

@Suite("Operator dashboard installation growth", .serialized)
struct OperatorDashboardInstallationGrowthTests {
    private enum Rollback: Error {
        case afterAssertions
    }

    private let now = Date(timeIntervalSince1970: 1_775_649_600) // 2026-04-08T12:00:00Z

    private func withApp(test: @escaping @Sendable (any Database) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            do {
                try await app.db.transaction { database in
                    guard let sql = database as? any SQLDatabase else {
                        throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
                    }

                    try await sql.raw("""
                        CREATE TEMPORARY TABLE device_installations (
                            installation_id UUID PRIMARY KEY,
                            created_at TIMESTAMPTZ NOT NULL,
                            last_seen_at TIMESTAMPTZ NOT NULL,
                            is_active BOOLEAN NOT NULL,
                            is_subscribed BOOLEAN NOT NULL,
                            apns_environment TEXT NOT NULL DEFAULT 'prod'
                        ) ON COMMIT DROP
                    """).run()
                    try await sql.raw("""
                        CREATE TEMPORARY TABLE installation_activity_daily (
                            installation_id UUID NOT NULL,
                            created_at TIMESTAMPTZ NOT NULL
                        ) ON COMMIT DROP
                    """).run()
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

    private func date(_ value: String) -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            fatalError("Invalid date fixture: \(value)")
        }
        return date
    }

    private func seedInstallation(
        createdAt: Date,
        lastSeenAt: Date,
        isActive: Bool = true,
        isSubscribed: Bool = true,
        apnsEnvironment: String = "prod",
        installationID: UUID = UUID(),
        on database: any Database
    ) async throws -> UUID {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("""
            INSERT INTO device_installations
                (installation_id, created_at, last_seen_at, is_active, is_subscribed, apns_environment)
            VALUES
                (\(bind: installationID), \(bind: createdAt), \(bind: lastSeenAt),
                 \(bind: isActive), \(bind: isSubscribed), \(bind: apnsEnvironment))
        """).run()
        return installationID
    }

    @Test("growth aggregate respects UTC month boundaries and cumulative totals")
    func growthAggregateRespectsMonthBoundariesAndCumulativeTotals() async throws {
        try await withApp { database in
            guard let sql = database as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
            }
            let activityCutoff = now.addingTimeInterval(-24 * 60 * 60)
            try await seedInstallation(
                createdAt: date("2025-04-30T23:59:59Z"),
                lastSeenAt: activityCutoff.addingTimeInterval(-1),
                on: database
            )
            try await seedInstallation(
                createdAt: date("2025-05-01T00:00:00Z"),
                lastSeenAt: activityCutoff,
                on: database
            )
            try await seedInstallation(
                createdAt: date("2026-03-31T23:59:59Z"),
                lastSeenAt: activityCutoff.addingTimeInterval(-1),
                isActive: false,
                on: database
            )
            try await seedInstallation(
                createdAt: date("2026-04-01T00:00:00Z"),
                lastSeenAt: now,
                isSubscribed: false,
                on: database
            )
            try await seedInstallation(
                createdAt: date("2026-04-08T11:59:59Z"),
                lastSeenAt: now,
                on: database
            )

            let metric = try await OperatorDashboardSnapshotRefresher()
                .loadInstallationGrowth(on: sql, now: now)

            #expect(metric.knownInstallationCount == 5)
            #expect(metric.currentInstallationCount == 4)
            #expect(metric.dormantInstallationCount == 0)
            #expect(metric.newThisMonthCount == 2)
            #expect(metric.currentlySubscribedCount == 3)
            #expect(metric.seenLast24HoursCount == 3)
            #expect(metric.monthlyGrowth.count == 12)
            #expect(metric.monthlyGrowth.first?.monthStart == date("2025-05-01T00:00:00Z"))
            #expect(metric.monthlyGrowth.first?.newInstallationCount == 1)
            #expect(metric.monthlyGrowth.first?.cumulativeInstallationCount == 2)
            #expect(metric.monthlyGrowth[10].newInstallationCount == 1)
            #expect(metric.monthlyGrowth[10].cumulativeInstallationCount == 3)
            #expect(metric.monthlyGrowth.last?.newInstallationCount == 2)
            #expect(metric.monthlyGrowth.last?.cumulativeInstallationCount == 5)
        }
    }

    @Test("current and dormant counts use the newest operational or foreground communication")
    func currentAndDormantCountsUseEffectiveCommunication() async throws {
        try await withApp { database in
            guard let sql = database as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
            }
            let old = now.addingTimeInterval(-Double(OperatorDashboardConfig.installationDormancyThresholdSeconds) - 1)
            let exact = now.addingTimeInterval(-Double(OperatorDashboardConfig.installationDormancyThresholdSeconds))
            let oldWithRecentActivity = try await seedInstallation(createdAt: old, lastSeenAt: old, on: database)
            let recentWithOldActivity = try await seedInstallation(createdAt: old, lastSeenAt: now, on: database)
            let latestActivityMakesCurrent = try await seedInstallation(createdAt: old, lastSeenAt: old, on: database)
            _ = try await seedInstallation(createdAt: old, lastSeenAt: old, on: database)
            _ = try await seedInstallation(createdAt: old, lastSeenAt: exact, on: database)
            let dormantWithMultipleActivities = try await seedInstallation(createdAt: old, lastSeenAt: old, on: database)
            _ = try await seedInstallation(createdAt: old, lastSeenAt: old, apnsEnvironment: "sandbox", on: database)
            _ = try await seedInstallation(createdAt: old, lastSeenAt: old, isActive: false, on: database)
            try await sql.raw("""
                INSERT INTO installation_activity_daily (installation_id, created_at)
                VALUES (\(bind: oldWithRecentActivity), \(bind: now))
            """).run()
            try await sql.raw("""
                INSERT INTO installation_activity_daily (installation_id, created_at)
                VALUES (\(bind: recentWithOldActivity), \(bind: old))
            """).run()
            try await sql.raw("""
                INSERT INTO installation_activity_daily (installation_id, created_at)
                VALUES
                    (\(bind: latestActivityMakesCurrent), \(bind: old)),
                    (\(bind: latestActivityMakesCurrent), \(bind: now.addingTimeInterval(-1))),
                    (\(bind: dormantWithMultipleActivities), \(bind: old)),
                    (\(bind: dormantWithMultipleActivities), \(bind: old.addingTimeInterval(-1)))
            """).run()

            let metric = try await OperatorDashboardSnapshotRefresher()
                .loadInstallationGrowth(on: sql, now: now)

            #expect(metric.currentInstallationCount == 4)
            #expect(metric.dormantInstallationCount == 2)
        }
    }

    @Test("new communication moves a dormant installation into current")
    func newCommunicationMovesDormantInstallationIntoCurrent() async throws {
        try await withApp { database in
            guard let sql = database as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
            }
            let old = now.addingTimeInterval(-Double(OperatorDashboardConfig.installationDormancyThresholdSeconds) - 1)
            let installationID = try await seedInstallation(createdAt: old, lastSeenAt: old, on: database)

            let dormantMetric = try await OperatorDashboardSnapshotRefresher()
                .loadInstallationGrowth(on: sql, now: now)
            #expect(dormantMetric.currentInstallationCount == 0)
            #expect(dormantMetric.dormantInstallationCount == 1)

            try await sql.raw("""
                INSERT INTO installation_activity_daily (installation_id, created_at)
                VALUES (\(bind: installationID), \(bind: now))
            """).run()

            let currentMetric = try await OperatorDashboardSnapshotRefresher()
                .loadInstallationGrowth(on: sql, now: now)
            #expect(currentMetric.currentInstallationCount == 1)
            #expect(currentMetric.dormantInstallationCount == 0)
        }
    }

    @Test("stored growth metric decodes legacy snapshots without new fields")
    func storedGrowthMetricDecodesLegacySnapshots() throws {
        let data = Data("""
        {
          "knownInstallationCount": 7,
          "newThisMonthCount": 2,
          "currentlySubscribedCount": 5,
          "seenLast24HoursCount": 3,
          "monthlyGrowth": []
        }
        """.utf8)

        let metric = try JSONDecoder().decode(StoredInstallationGrowthMetric.self, from: data)

        #expect(metric.knownInstallationCount == 7)
        #expect(metric.currentInstallationCount == 0)
        #expect(metric.dormantInstallationCount == 0)
        #expect(metric.monthlyGrowth.isEmpty)
    }
}
