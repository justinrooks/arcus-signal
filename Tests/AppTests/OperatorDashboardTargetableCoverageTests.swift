@testable import App
import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor

@Suite("Operator dashboard targetable coverage", .serialized)
struct OperatorDashboardTargetableCoverageTests {
    private enum Rollback: Error {
        case afterAssertions
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func withApp(test: @escaping @Sendable (any Database) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            try await app.autoMigrate()
            do {
                try await app.db.transaction { database in
                    guard let sql = database as? any SQLDatabase else {
                        throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
                    }

                    try await sql.raw(
                        "LOCK TABLE device_installations, device_presence IN ACCESS EXCLUSIVE MODE"
                    ).run()
                    try await clearDeviceData(on: database)
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

    private func clearDeviceData(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("DELETE FROM device_presence;").run()
        try await sql.raw("DELETE FROM device_installations;").run()
    }

    private func seedInstallation(
        token: String = "token",
        apnsEnvironment: APNsEnvironment = .prod,
        locationAuth: LocationAuth = .always,
        isActive: Bool = true,
        isSubscribed: Bool = true,
        lastSeenAt: Date,
        capturedAt: Date? = nil,
        hasTargetingData: Bool = true,
        on database: any Database
    ) async throws {
        let installationID = UUID()
        try await DeviceInstallationModel(
            installationId: installationID,
            apnsDeviceToken: token,
            apnsEnvironment: apnsEnvironment,
            platform: .iOS,
            osVersion: "26.0",
            appVersion: "1.0.0",
            buildNumber: "100",
            locationAuth: locationAuth,
            isActive: isActive,
            lastSeenAt: lastSeenAt,
            isSubscribed: isSubscribed
        ).create(on: database)

        guard let capturedAt else { return }
        try await DevicePresenceModel(
            installationId: installationID,
            capturedAt: capturedAt,
            receivedAt: capturedAt,
            locationAgeSeconds: 0,
            horizontalAccuracyMeters: 0,
            cellScheme: hasTargetingData ? .h3 : .ugcOnly,
            h3Cell: hasTargetingData ? 617_700_169_958_293_503 : nil,
            h3Resolution: hasTargetingData ? 8 : nil,
            county: nil,
            zone: nil,
            fireZone: nil,
            source: .foregroundPrime,
            countyLabel: nil,
            fireZoneLabel: nil
        ).create(on: database)
    }

    @Test("coverage aggregate uses the shared hard-stale cutoff without legacy heartbeat or authorization filters")
    func coverageAggregateUsesHardStaleCutoff() async throws {
        try await withApp { database in
            let cutoff = now.addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold)
            let staleHeartbeat = now.addingTimeInterval(-48 * 60 * 60)

            try await seedInstallation(
                locationAuth: .denied,
                lastSeenAt: staleHeartbeat,
                capturedAt: cutoff,
                on: database
            )
            try await seedInstallation(
                apnsEnvironment: .prod,
                lastSeenAt: now,
                capturedAt: cutoff.addingTimeInterval(1),
                on: database
            )
            try await seedInstallation(
                lastSeenAt: staleHeartbeat,
                capturedAt: cutoff.addingTimeInterval(-1),
                on: database
            )
            try await seedInstallation(
                token: "",
                lastSeenAt: now,
                capturedAt: now,
                on: database
            )
            try await seedInstallation(
                apnsEnvironment: .prod,
                lastSeenAt: now,
                capturedAt: now,
                hasTargetingData: false,
                on: database
            )
            try await seedInstallation(lastSeenAt: now, capturedAt: nil, on: database)
            try await seedInstallation(isActive: false, lastSeenAt: now, capturedAt: now, on: database)
            try await seedInstallation(isSubscribed: false, lastSeenAt: now, capturedAt: now, on: database)
            try await seedInstallation(
                apnsEnvironment: .sandbox,
                lastSeenAt: now,
                capturedAt: now,
                on: database
            )

            guard let sql = database as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
            }

            let coverage = try await OperatorDashboardSnapshotRefresher()
                .loadTargetableCoverage(on: sql, now: now)
            #expect(coverage.hardStalePresenceThresholdSeconds == Int(LocationFreshnessPolicy.hardStaleThreshold))
            #expect(coverage.activeSubscribedInstallationCount == 6)
            #expect(coverage.candidateQueryEligibleInstallationCount == 2)
            #expect(coverage.hardStalePresenceCount == 1)
        }
    }

    @Test("installation footprint is bounded, ordered, and explains eligibility")
    func installationFootprintIsBoundedOrderedAndExplainsEligibility() async throws {
        try await withApp { database in
            try await seedInstallation(
                apnsEnvironment: .prod,
                lastSeenAt: now,
                capturedAt: now.addingTimeInterval(-60),
                on: database
            )
            try await seedInstallation(
                apnsEnvironment: .prod,
                lastSeenAt: now,
                capturedAt: now.addingTimeInterval(-120),
                hasTargetingData: false,
                on: database
            )
            try await seedInstallation(
                apnsEnvironment: .prod,
                lastSeenAt: now,
                capturedAt: now.addingTimeInterval(-180),
                on: database
            )
            try await seedInstallation(
                token: "",
                apnsEnvironment: .prod,
                lastSeenAt: now,
                capturedAt: now.addingTimeInterval(-240),
                on: database
            )

            guard let sql = database as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
            }

            let entries = try await OperatorDashboardSnapshotRefresher()
                .loadInstallationFootprint(on: sql, now: now)
            #expect(entries.count == 4)
            #expect(entries[0].capturedAt == now.addingTimeInterval(-60))
            #expect(entries[0].candidateQueryEligible)
            #expect(entries[1].ineligibilityReason == "missing targeting data")
            #expect(entries[2].candidateQueryEligible)
            #expect(entries[3].ineligibilityReason == "missing device token")
        }
    }

    @Test("installation footprint returns the five freshest production rows within 90 days")
    func installationFootprintReturnsOnlyFiveFreshestRowsWithin90Days() async throws {
        try await withApp { database in
            try await seedInstallation(
                apnsEnvironment: .sandbox,
                lastSeenAt: now,
                capturedAt: now,
                on: database
            )
            for offset in 0..<7 {
                try await seedInstallation(
                    apnsEnvironment: .prod,
                    lastSeenAt: now,
                    capturedAt: now.addingTimeInterval(-Double(offset * 60)),
                    on: database
                )
            }
            try await seedInstallation(
                apnsEnvironment: .prod,
                lastSeenAt: now,
                capturedAt: now.addingTimeInterval(-Double(91 * 24 * 60 * 60)),
                on: database
            )

            guard let sql = database as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
            }

            let entries = try await OperatorDashboardSnapshotRefresher()
                .loadInstallationFootprint(on: sql, now: now)
            #expect(entries.count == 5)
            #expect(entries.first?.capturedAt == now)
            #expect(entries.last?.capturedAt == now.addingTimeInterval(-4 * 60))
        }
    }
}
