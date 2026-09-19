@testable import App
import FluentSQL
import Foundation
import Testing
import Vapor
import VaporTesting
import ArcusCore

@Suite("Alerts controller", .serialized)
struct AlertsControllerTests {
    private struct DecodedAlertPayload: Decodable {
        let id: UUID
        let event: String
        let currentRevisionUrn: String
        let ugc: [String]
        let h3Cells: [Int64]
    }

    private func withApp(
        test: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            try await test(app)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func isoDate(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else {
            fatalError("Invalid ISO8601 date in test fixture: \(value)")
        }
        return date
    }

    private func seedSeries(
        id: UUID,
        state: EventState = .active,
        expires: Date? = nil,
        ends: Date? = nil,
        ugcCodes: [String] = ["COC031"],
        h3Cells: [Int64] = [617700169958293503],
        on app: Application
    ) async throws {
        let now = isoDate("2026-05-21T18:00:00Z")
        let series = ArcusSeriesModel(
            id: id,
            source: EventSource.nws.rawValue,
            event: "Tornado Warning",
            sourceURL: "https://api.weather.gov/alerts/\(id.uuidString)",
            currentRevisionUrn: "urn:oid:\(id.uuidString)",
            currentRevisionSent: now,
            messageType: NWSAlertMessageType.alert.rawValue,
            contentFingerprint: "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            state: state.rawValue,
            created: now,
            updated: now,
            sent: now,
            effective: now,
            onset: nil,
            expires: expires,
            ends: ends,
            lastSeenActive: now,
            severity: EventSeverity.severe.rawValue,
            urgency: EventUrgency.immediate.rawValue,
            certainty: EventCertainty.observed.rawValue,
            ugcCodes: ugcCodes,
            areaDesc: "Denver County",
            senderName: "NWS Boulder CO",
            headline: "Tornado Warning issued",
            description: "Storm text",
            instructions: "Take shelter now",
            response: "Shelter"
        )
        try await series.save(on: app.db)

        let geolocation = ArcusGeolocationModel(
            series: id,
            geometry: .point(lon: -104.9903, lat: 39.7392),
            geometryHash: "geom-hash",
            h3Cells: h3Cells,
            h3Resolution: 8,
            h3Hash: "h3-hash"
        )
        try await geolocation.save(on: app.db)
    }

    @Test("collection lookup returns active and recent terminal alerts only")
    func collectionLookupBoundsLifecycleWindow() async throws {
        try await withApp { app in
            let now = isoDate("2026-05-21T18:00:00Z")
            let oneHourAgo = now.addingTimeInterval(-60 * 60)
            let collectionUGC = ["COC262"]

            let active = UUID()
            let activeExpired = UUID()
            let activeEnded = UUID()
            let recentlyExpired = UUID()
            let cutoffExpired = UUID()
            let oldExpired = UUID()
            let recentlyEnded = UUID()
            let cutoffEnded = UUID()
            let oldEnded = UUID()
            let cancelled = UUID()
            let cancelledInError = UUID()
            let geographyMismatch = UUID()

            try await seedSeries(id: active, ugcCodes: collectionUGC, on: app)
            try await seedSeries(id: activeExpired, expires: now.addingTimeInterval(-1), ugcCodes: collectionUGC, on: app)
            try await seedSeries(id: activeEnded, ends: now.addingTimeInterval(-1), ugcCodes: collectionUGC, on: app)
            try await seedSeries(id: recentlyExpired, state: .expired, expires: now.addingTimeInterval(-30 * 60), ugcCodes: collectionUGC, on: app)
            try await seedSeries(id: cutoffExpired, state: .expired, expires: oneHourAgo, ugcCodes: collectionUGC, on: app)
            try await seedSeries(id: oldExpired, state: .expired, expires: now.addingTimeInterval(-2 * 60 * 60), ugcCodes: collectionUGC, on: app)
            try await seedSeries(id: recentlyEnded, state: .ended, ends: now.addingTimeInterval(-30 * 60), ugcCodes: collectionUGC, on: app)
            try await seedSeries(id: cutoffEnded, state: .ended, ends: oneHourAgo, ugcCodes: collectionUGC, on: app)
            try await seedSeries(id: oldEnded, state: .ended, ends: now.addingTimeInterval(-2 * 60 * 60), ugcCodes: collectionUGC, on: app)
            try await seedSeries(id: cancelled, state: .cancelled, ugcCodes: collectionUGC, on: app)
            try await seedSeries(id: cancelledInError, state: .cancelled_in_error, ugcCodes: collectionUGC, on: app)
            try await seedSeries(id: geographyMismatch, ugcCodes: ["COC999"], on: app)

            let sql = try #require(app.db as? any SQLDatabase)
            let rows = try await loadAlertSeries(
                sql: sql,
                ugcCodes: collectionUGC,
                h3: nil,
                evaluatedAt: now
            )
            let ids = Set(rows.map(\.id))

            #expect(ids == [active, recentlyExpired, cutoffExpired, recentlyEnded, cutoffEnded])
            #expect(!ids.contains(activeExpired))
            #expect(!ids.contains(activeEnded))
            #expect(!ids.contains(oldExpired))
            #expect(!ids.contains(oldEnded))
            #expect(!ids.contains(cancelled))
            #expect(!ids.contains(cancelledInError))
            #expect(!ids.contains(geographyMismatch))
        }
    }

    @Test("GET /api/v2/alerts supports targeted series UUID lookup")
    func targetedLookupBySeriesUUID() async throws {
        try await withApp { app in
            let seriesID = UUID()
            try await seedSeries(id: seriesID, on: app)

            try await app.testing().test(.GET, "api/v2/alerts?id=\(seriesID.uuidString)", afterResponse: { res async throws in
                #expect(res.status == .ok)

                let payload = try res.content.decode([DecodedAlertPayload].self)
                #expect(payload.count == 1)
                #expect(payload.first?.id == seriesID)
                #expect(payload.first?.event == "Tornado Warning")
                #expect(payload.first?.ugc == ["COC031"])
                #expect(payload.first?.h3Cells == [617700169958293503])
            })
        }
    }

    @Test("GET /v2/alerts preserves the legacy response through the canonical route")
    func canonicalTargetedLookupBySeriesUUID() async throws {
        try await withApp { app in
            let seriesID = UUID()
            try await seedSeries(id: seriesID, on: app)

            try await app.testing().test(.GET, "v2/alerts?id=\(seriesID.uuidString)", afterResponse: { res async throws in
                #expect(res.status == .ok)

                let payload = try res.content.decode([DecodedAlertPayload].self)
                #expect(payload.count == 1)
                #expect(payload.first?.id == seriesID)
            })
        }
    }

    @Test("GET /api/v2/alerts rejects malformed targeted UUID")
    func targetedLookupRejectsMalformedUUID() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "api/v2/alerts?id=not-a-uuid", afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("GET /api/v2/alerts returns 404 for missing targeted series UUID")
    func targetedLookupReturnsNotFoundForMissingSeries() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "api/v2/alerts?id=\(UUID().uuidString)", afterResponse: { res async in
                #expect(res.status == .notFound)
            })
        }
    }

    @Test("GET /api/v2/alerts rejects mixed targeted and location filters")
    func targetedLookupRejectsMixedFilters() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "api/v2/alerts?id=\(UUID().uuidString)&county=COC031", afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("GET /api/v2/alerts targeted response uses existing device alert payload contract")
    func targetedLookupResponseUsesDeviceAlertPayloadContract() async throws {
        try await withApp { app in
            let seriesID = UUID()
            try await seedSeries(id: seriesID, on: app)

            try await app.testing().test(
                .GET,
                "api/v2/alerts?id=\(seriesID.uuidString)&sent=2026-05-21T18:00:00Z",
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(res.headers.contentType == .json)

                    let payload = try res.content.decode([DecodedAlertPayload].self)
                    #expect(payload.count == 1)
                    #expect(payload[0].id == seriesID)
                    #expect(payload[0].currentRevisionUrn == "urn:oid:\(seriesID.uuidString)")
                }
            )
        }
    }
}
