@testable import App
import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor
import VaporTesting

@Suite("Operator dashboard targetable coverage", .serialized, .sharedDatabase)
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
        installationID: UUID = UUID(),
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

    @Test("coverage follows current sharing consent while presence remains")
    func coverageFollowsSharingConsent() async throws {
        try await withApp { database in
            try await seedInstallation(lastSeenAt: now, capturedAt: now, on: database)
            guard let sql = database as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
            }
            for enabled in [true, false, true] {
                try await sql.raw("UPDATE device_installations SET location_sharing_enabled = \(bind: enabled)").run()
                let coverage = try await OperatorDashboardSnapshotRefresher().loadTargetableCoverage(on: sql, now: now)
                let response = TargetableCoverageMetricResponse(refreshedAt: now, metric: coverage)
                #expect(coverage.activeSubscribedInstallationCount == 1)
                #expect(coverage.targetableInstallationCount == (enabled ? 1 : 0))
                #expect(coverage.candidateQueryEligibleInstallationCount == (enabled ? 1 : 0))
                #expect(response.targetableInstallationCount == (enabled ? 1 : 0))
                #expect(response.candidateQueryEligibleInstallationCount == (enabled ? 1 : 0))
                #expect(response.activeSubscribedInstallationCount == 1)
            }
        }
    }

    @Test("refreshed consent coverage reaches the persisted metrics endpoint")
    func refreshedConsentCoverageReachesMetrics() async throws {
        let name = Environment.get("DATABASE_URL").flatMap(URL.init(string:))?.lastPathComponent ?? ""
        guard name.range(of: #"^arcus_issue[0-9]+_(test|validation)(_|$)"#, options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "An issue-scoped database is required")
        }
        try await withIntegrationTestApplication(setup: .configured(mode: .api, migrate: true)) { app in
            guard let sql = app.db as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
            }
            let store = DatabaseOperatorDashboardSnapshotStore()
            let original = try await store.load(on: app.db)
            let installationID = UUID()
            func cleanup() async throws {
                try await sql.raw("DELETE FROM device_presence WHERE installation_id = \(bind: installationID)").run()
                try await sql.raw("DELETE FROM device_installations WHERE installation_id = \(bind: installationID)").run()
                if let original {
                    try await store.save(original, on: app.db)
                } else {
                    try await sql.raw("DELETE FROM operator_dashboard_snapshots WHERE id = 'current'").run()
                }
            }
            do {
                let baseline = try await OperatorDashboardSnapshotRefresher().loadTargetableCoverage(on: sql, now: now)
                try await seedInstallation(installationID: installationID, lastSeenAt: now, capturedAt: now, on: app.db)
                for enabled in [true, false, true] {
                    try await sql.raw("UPDATE device_installations SET location_sharing_enabled = \(bind: enabled) WHERE installation_id = \(bind: installationID)").run()
                    var snapshot = try await store.load(on: app.db) ?? .empty(now: now)
                    snapshot.fastRefreshedAt = now
                    snapshot.standardRefreshedAt = now
                    snapshot.slowRefreshedAt = nil
                    try await store.save(snapshot, on: app.db)
                    try await OperatorDashboardSnapshotRefresher().refreshIfDue(on: app, now: now)
                    let saved = try #require(try await store.load(on: app.db))
                    let expectedTargetable = baseline.targetableInstallationCount + (enabled ? 1 : 0)
                    let expectedEligible = baseline.candidateQueryEligibleInstallationCount + (enabled ? 1 : 0)
                    let expectedDenominator = baseline.activeSubscribedInstallationCount + 1
                    #expect(saved.targetableCoverage.targetableInstallationCount == expectedTargetable)
                    #expect(saved.targetableCoverage.candidateQueryEligibleInstallationCount == expectedEligible)
                    #expect(saved.targetableCoverage.activeSubscribedInstallationCount == expectedDenominator)
                    try await app.testing().test(.GET, "/v1/metrics", afterResponse: { response async throws in
                        #expect(response.status == .ok)
                        let payload = try response.content.decode(OperatorDashboardSnapshotResponse.self)
                        let coverage = payload.audienceTargeting.freshTargetableInstallationCoverage
                        #expect(coverage.targetableInstallationCount == expectedTargetable)
                        #expect(coverage.candidateQueryEligibleInstallationCount == expectedEligible)
                        #expect(coverage.activeSubscribedInstallationCount == expectedDenominator)
                    })
                }
            } catch {
                try await cleanup()
                throw error
            }
            try await cleanup()
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

    @Test("touched series uses the rolling detail window and hard cap")
    func touchedSeriesUsesRollingDetailWindowAndHardCap() async throws {
        try await withApp { database in
            // 2100-01-01 keeps this window clear of rows from current-date integration fixtures.
            let testNow = Date(timeIntervalSince1970: 4_102_444_800)
            let prefix = UUID().uuidString.lowercased()
            guard let sql = database as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
            }
            for index in 0...250 {
                let seriesID = UUID()
                let touchedAt = testNow.addingTimeInterval(-Double(index))
                try await ArcusSeriesModel(
                    id: seriesID,
                    source: "nws",
                    event: "NWS \(index)",
                    sourceURL: "https://example.test/\(prefix)/\(index)",
                    currentRevisionUrn: "urn:oid:\(prefix)-\(index)",
                    currentRevisionSent: touchedAt,
                    messageType: "Alert",
                    contentFingerprint: String(repeating: "a", count: 63) + String(index % 16, radix: 16),
                    state: "active",
                    updated: touchedAt,
                    sent: touchedAt,
                    effective: touchedAt,
                    onset: touchedAt,
                    expires: testNow.addingTimeInterval(3_600),
                    ends: nil,
                    lastSeenActive: touchedAt,
                    severity: "Severe",
                    urgency: "Immediate",
                    certainty: "Observed",
                    ugcCodes: ["COC031"]
                ).create(on: database)
                try await sql.raw(
                    "UPDATE arcus_series SET updated = \(bind: touchedAt) WHERE id = \(bind: seriesID)"
                ).run()
            }

            let oldSeriesID = UUID()
            let oldTouchedAt = testNow.addingTimeInterval(
                -Double(OperatorDashboardConfig.touchedSeriesDetailWindowHours * 60 * 60) - 1
            )
            try await ArcusSeriesModel(
                id: oldSeriesID,
                source: "nws",
                event: "Outside window",
                sourceURL: "https://example.test/\(prefix)/old",
                currentRevisionUrn: "urn:oid:\(prefix)-old",
                currentRevisionSent: oldTouchedAt,
                messageType: "Alert",
                contentFingerprint: String(repeating: "b", count: 64),
                state: "active",
                updated: oldTouchedAt,
                sent: oldTouchedAt,
                effective: oldTouchedAt,
                onset: oldTouchedAt,
                expires: testNow.addingTimeInterval(3_600),
                ends: nil,
                lastSeenActive: oldTouchedAt,
                severity: "Severe",
                urgency: "Immediate",
                certainty: "Observed",
                ugcCodes: ["COC031"]
            ).create(on: database)
            try await sql.raw(
                "UPDATE arcus_series SET updated = \(bind: oldTouchedAt) WHERE id = \(bind: oldSeriesID)"
            ).run()

            let entries = try await OperatorDashboardSnapshotRefresher()
                .loadTouchedSeries(on: sql, now: testNow)
            #expect(entries.count == OperatorDashboardConfig.touchedSeriesDetailLimit)
            #expect(entries.first?.eventName == "NWS 0")
            #expect(entries.last?.eventName == "NWS 249")
            #expect(entries.contains { $0.eventName == "Outside window" } == false)
        }
    }
}
