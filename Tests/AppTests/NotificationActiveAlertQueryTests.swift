@testable import App
import Fluent
import Foundation
import Testing

@Suite("Notification active alert query", .serialized)
struct NotificationActiveAlertQueryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func seedInstallation(
        id: UUID,
        h3Cell: Int64,
        county: String,
        zone: String,
        fireZone: String,
        on database: any Database
    ) async throws {
        try await DeviceInstallationModel(
            installationId: id,
            apnsDeviceToken: "token",
            apnsEnvironment: .sandbox,
            platform: .iOS,
            osVersion: "26.0",
            appVersion: "1.0.0",
            buildNumber: "100",
            locationAuth: .always,
            lastSeenAt: now
        ).create(on: database)

        try await DevicePresenceModel(
            installationId: id,
            capturedAt: now,
            receivedAt: now,
            locationAgeSeconds: 0,
            horizontalAccuracyMeters: 10,
            cellScheme: .h3,
            h3Cell: h3Cell,
            h3Resolution: 8,
            county: county,
            zone: zone,
            fireZone: fireZone,
            source: .foregroundPrime,
            countyLabel: "Test County",
            fireZoneLabel: "Test Fire Zone"
        ).create(on: database)
    }

    private func seedAlert(
        mode: NotificationTargetMode,
        reason: NotificationReason = .new,
        state: EventState = .active,
        expires: Date? = nil,
        ends: Date? = nil,
        ugcCodes: [String] = [],
        h3Cells: [Int64]? = nil,
        outboxUsesCurrentRevision: Bool = true,
        on database: any Database
    ) async throws -> (id: UUID, revisionUrn: String) {
        let id = UUID()
        let currentRevisionUrn = "urn:oid:\(UUID().uuidString.lowercased())"
        let series = ArcusSeriesModel(
            id: id,
            source: "nws",
            event: "Tornado Warning",
            sourceURL: "https://api.weather.gov/alerts/\(id.uuidString.lowercased())",
            currentRevisionUrn: currentRevisionUrn,
            currentRevisionSent: now,
            messageType: "alert",
            contentFingerprint: String(repeating: "a", count: 64),
            state: state.rawValue,
            expires: expires,
            ends: ends,
            lastSeenActive: now,
            severity: "severe",
            urgency: "immediate",
            certainty: "observed",
            ugcCodes: ugcCodes
        )
        try await series.create(on: database)

        try await ArcusEventRevisionModel(
            seriesId: id,
            revisionUrn: currentRevisionUrn,
            messageType: "alert",
            sent: now,
            received: now,
            referencedUrns: []
        ).create(on: database)

        let outboxRevisionUrn: String
        if outboxUsesCurrentRevision {
            outboxRevisionUrn = currentRevisionUrn
        } else {
            outboxRevisionUrn = "urn:oid:\(UUID().uuidString.lowercased())"
            try await ArcusEventRevisionModel(
                seriesId: id,
                revisionUrn: outboxRevisionUrn,
                messageType: "update",
                sent: now.addingTimeInterval(-60),
                received: now,
                referencedUrns: []
            ).create(on: database)
        }

        try await ArcusNotificationOutboxModel(
            series: id,
            revisionUrn: outboxRevisionUrn,
            mode: mode.rawValue,
            reason: reason.rawValue,
            state: "done",
            attempts: 1,
            availableAt: now
        ).create(on: database)

        if let h3Cells {
            try await ArcusGeolocationModel(
                series: id,
                geometry: .point(lon: -104.99, lat: 39.74),
                geometryHash: "geometry-\(id)",
                h3Cells: h3Cells,
                h3Resolution: 8,
                h3Hash: "h3-\(id)"
            ).create(on: database)
        }

        return (id, currentRevisionUrn)
    }

    @Test("H3 and every UGC field match exactly for one installation")
    func targetingSemanticsAndInstallationScope() async throws {
        try await withIntegrationTestApplication(
            setup: .configured(mode: .api, migrate: true)
        ) { app in
            try await withRollbackTransaction(on: app) { database in
                let installationId = UUID()
                let h3Cell: Int64 = 617_700_169_958_293_503
                let codePrefix = UUID().uuidString.lowercased()
                let county = "county-\(codePrefix)"
                let zone = "zone-\(codePrefix)"
                let fireZone = "fire-zone-\(codePrefix)"
                try await seedInstallation(
                    id: installationId,
                    h3Cell: h3Cell,
                    county: county,
                    zone: zone,
                    fireZone: fireZone,
                    on: database
                )

                let h3 = try await seedAlert(mode: .h3, h3Cells: [h3Cell], on: database)
                let countyMatch = try await seedAlert(mode: .ugc, ugcCodes: [county], on: database)
                let zoneMatch = try await seedAlert(mode: .ugc, reason: .update, ugcCodes: [zone], on: database)
                let fireZoneMatch = try await seedAlert(mode: .ugc, ugcCodes: [fireZone], on: database)
                _ = try await seedAlert(mode: .h3, h3Cells: [h3Cell + 1], on: database)
                _ = try await seedAlert(mode: .ugc, ugcCodes: ["COC000"], on: database)

                let otherInstallationId = UUID()
                try await seedInstallation(
                    id: otherInstallationId,
                    h3Cell: h3Cell + 2,
                    county: "COC998",
                    zone: "COZ998",
                    fireZone: "COZ997",
                    on: database
                )
                _ = try await seedAlert(mode: .h3, h3Cells: [h3Cell + 2], on: database)

                let matches = try await NotificationCandidateStore().loadMatchingActiveAlerts(
                    for: installationId,
                    evaluatedAt: now,
                    on: database
                )

                #expect(Set(matches.map(\.seriesId)) == [h3.id, countyMatch.id, zoneMatch.id, fireZoneMatch.id])
                #expect(matches.contains {
                    $0.seriesId == h3.id && $0.revisionUrn == h3.revisionUrn && $0.mode == .h3 && $0.reason == .new
                })
                #expect(matches.contains {
                    $0.seriesId == zoneMatch.id && $0.revisionUrn == zoneMatch.revisionUrn
                        && $0.mode == .ugc && $0.reason == .update
                })
            }
        }
    }

    @Test("Only current, active, future, non-terminal work is returned")
    func lifecycleRevisionAndFallbackProvenance() async throws {
        try await withIntegrationTestApplication(
            setup: .configured(mode: .api, migrate: true)
        ) { app in
            try await withRollbackTransaction(on: app) { database in
                let installationId = UUID()
                let h3Cell: Int64 = 617_700_169_958_293_503
                let county = "county-\(UUID().uuidString.lowercased())"
                try await seedInstallation(
                    id: installationId,
                    h3Cell: h3Cell,
                    county: county,
                    zone: "COZ001",
                    fireZone: "COZ201",
                    on: database
                )

                let fallback = try await seedAlert(
                    mode: .ugc,
                    reason: .update,
                    expires: now.addingTimeInterval(60),
                    ends: now.addingTimeInterval(120),
                    ugcCodes: [county],
                    h3Cells: [h3Cell],
                    on: database
                )
                _ = try await seedAlert(mode: .ugc, state: .expired, ugcCodes: [county], on: database)
                _ = try await seedAlert(mode: .ugc, state: .ended, ugcCodes: [county], on: database)
                _ = try await seedAlert(mode: .ugc, state: .cancelled, ugcCodes: [county], on: database)
                _ = try await seedAlert(mode: .ugc, expires: now, ugcCodes: [county], on: database)
                _ = try await seedAlert(mode: .ugc, ends: now, ugcCodes: [county], on: database)
                _ = try await seedAlert(
                    mode: .ugc,
                    ugcCodes: [county],
                    outboxUsesCurrentRevision: false,
                    on: database
                )
                _ = try await seedAlert(mode: .ugc, reason: .endedAllClear, ugcCodes: [county], on: database)
                _ = try await seedAlert(mode: .ugc, reason: .cancelInError, ugcCodes: [county], on: database)

                let matches = try await NotificationCandidateStore().loadMatchingActiveAlerts(
                    for: installationId,
                    evaluatedAt: now,
                    on: database
                )

                #expect(matches.count == 1)
                #expect(matches.first?.seriesId == fallback.id)
                #expect(matches.first?.revisionUrn == fallback.revisionUrn)
                #expect(matches.first?.mode == .ugc)
                #expect(matches.first?.reason == .update)
            }
        }
    }
}
