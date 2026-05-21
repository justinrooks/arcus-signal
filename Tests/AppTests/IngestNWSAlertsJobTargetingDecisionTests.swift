@testable import App
import Foundation
import Testing

@Suite("Ingest NWS alerts targeting decision tests")
struct IngestNWSAlertsJobTargetingDecisionTests {
    private let job = IngestNWSAlertsJob()

    private func makeEvent(geometry: GeoShape?) -> ArcusEvent {
        ArcusEvent(
            urn: "urn:oid:test-targeting-decision",
            source: .nws,
            kind: "Tornado Warning",
            sourceURL: "https://api.weather.gov/alerts/test-targeting-decision",
            vtec: nil,
            messageType: .alert,
            state: .active,
            references: [],
            sent: Date(timeIntervalSince1970: 1_708_560_000),
            effective: Date(timeIntervalSince1970: 1_708_560_060),
            onset: Date(timeIntervalSince1970: 1_708_560_120),
            expires: Date(timeIntervalSince1970: 1_708_563_600),
            ends: nil,
            lastSeenActive: Date(timeIntervalSince1970: 1_708_560_030),
            severity: .severe,
            urgency: .immediate,
            certainty: .observed,
            geometry: geometry,
            ugcCodes: ["COC031"],
            title: "Tornado Warning for Test County",
            areaDesc: "Test County",
            rawRef: nil,
            category: "Met",
            event: "Tornado Warning",
            senderName: "NWS Boulder CO",
            headline: "Tornado Warning for Test County",
            description: "Storm text",
            instructions: "Take shelter now",
            response: "Shelter",
            status: "Actual",
            tornadoDetection: nil,
            tornadoDamageThreat: nil,
            maxWindGust: nil,
            maxHailSize: nil,
            windThreat: nil,
            hailThreat: nil,
            thunderstormDamageThreat: nil,
            flashFloodDetection: nil,
            flashFloodDamageThreat: nil
        )
    }

    @Test("nil geometry queues UGC fallback")
    func nilGeometryQueuesUGC() {
        let event = makeEvent(geometry: nil)

        #expect(job.shouldQueueUGCNotificationDispatch(for: event))
    }

    @Test("polygon geometry suppresses UGC fallback")
    func polygonGeometrySuppressesUGC() {
        let event = makeEvent(
            geometry: .polygon(rings: [[
                .init(lon: -104.0, lat: 39.0),
                .init(lon: -103.5, lat: 39.5),
                .init(lon: -104.0, lat: 39.0)
            ]])
        )

        #expect(job.shouldQueueUGCNotificationDispatch(for: event) == false)
    }

    @Test("multipolygon geometry suppresses UGC fallback")
    func multiPolygonGeometrySuppressesUGC() {
        let event = makeEvent(
            geometry: .multiPolygon(polygons: [[[
                .init(lon: -104.0, lat: 39.0),
                .init(lon: -103.5, lat: 39.5),
                .init(lon: -104.0, lat: 39.0)
            ]]])
        )

        #expect(job.shouldQueueUGCNotificationDispatch(for: event) == false)
    }

    @Test("point geometry keeps UGC fallback")
    func pointGeometryKeepsUGC() {
        let event = makeEvent(geometry: .point(lon: -104.99, lat: 39.73))

        #expect(job.shouldQueueUGCNotificationDispatch(for: event))
    }
}
