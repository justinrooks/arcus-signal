@testable import App
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
            state: EventState.active.rawValue,
            created: now,
            updated: now,
            sent: now,
            effective: now,
            onset: nil,
            expires: nil,
            ends: nil,
            lastSeenActive: now,
            severity: EventSeverity.severe.rawValue,
            urgency: EventUrgency.immediate.rawValue,
            certainty: EventCertainty.observed.rawValue,
            ugcCodes: ["COC031"],
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
            h3Cells: [617700169958293503],
            h3Resolution: 8,
            h3Hash: "h3-hash"
        )
        try await geolocation.save(on: app.db)
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
