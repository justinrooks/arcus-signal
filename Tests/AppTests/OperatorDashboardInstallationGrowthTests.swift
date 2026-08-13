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
                            is_subscribed BOOLEAN NOT NULL
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
        on database: any Database
    ) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("""
            INSERT INTO device_installations
                (installation_id, created_at, last_seen_at, is_active, is_subscribed)
            VALUES
                (\(bind: UUID()), \(bind: createdAt), \(bind: lastSeenAt),
                 \(bind: isActive), \(bind: isSubscribed))
        """).run()
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
}
