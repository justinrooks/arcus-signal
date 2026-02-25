@testable import App
import Foundation
import Queues
import Testing
import Vapor
import VaporTesting
import XCTQueues

@Suite("Arcus Signal bootstrap tests", .serialized)
struct AppTests {
    private func withApp(
        mode: AppRuntimeMode,
        test: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: mode)
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

    private func makeEvent(
        key: String,
        revision: Int = 1,
        expiresAt: Date? = nil,
        title: String? = nil
    ) -> ArcusEvent {
        ArcusEvent(
            eventKey: key,
            source: .nws,
            kind: .torWarning,
            sourceURL: "https://api.weather.gov/alerts/\(key)",
            status: .active,
            revision: revision,
            issuedAt: isoDate("2026-02-21T16:00:00Z"),
            effectiveAt: isoDate("2026-02-21T16:05:00Z"),
            expiresAt: expiresAt,
            severity: .warning,
            urgency: .immediate,
            certainty: .observed,
            geometry: nil,
            ugcCodes: [],
            h3Resolution: nil,
            h3CoverHash: nil,
            title: title,
            areaDesc: "Test Area",
            rawRef: nil
        )
    }

    private func makeIngestEvent(
        key: String,
        revision: Int = 1,
        expiresAt: Date? = nil,
        title: String? = nil,
        referenceSourceURLs: [String] = []
    ) -> ArcusIngestEvent {
        ArcusIngestEvent(
            event: makeEvent(key: key, revision: revision, expiresAt: expiresAt, title: title),
            referenceSourceURLs: referenceSourceURLs
        )
    }

    @Test("API health endpoint returns ok")
    func apiHealth() async throws {
        try await withApp(mode: .api) { app in
            try await app.testing().test(.GET, "health", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "ok")
            })
        }
    }

    @Test("Worker health endpoint returns ok")
    func workerHealth() async throws {
        try await withApp(mode: .worker) { app in
            try await app.testing().test(.GET, "health", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "ok")
            })
        }
    }

    @Test("NWS event JSON decodes polygon geometry coordinates")
    func nwsPolygonCoordinatesDecode() throws {
        let json = """
        {
          "type": "FeatureCollection",
          "features": [
            {
              "id": "urn:oid:example",
              "type": "Feature",
              "geometry": {
                "type": "Polygon",
                "coordinates": [
                  [
                    [-104.0, 39.0],
                    [-103.5, 39.5],
                    [-104.0, 39.0]
                  ]
                ]
              },
              "properties": {
                "id": "https://api.weather.gov/alerts/example",
                "areaDesc": "Test County"
              }
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(NwsEventDTO.self, from: Data(json.utf8))

        guard let geometry = decoded.features?.first?.geometry else {
            Issue.record("Expected a geometry payload.")
            return
        }

        switch geometry.coordinates {
        case .array(let rings):
            #expect(rings.isEmpty == false)
        default:
            Issue.record("Expected polygon coordinates to decode as a nested array.")
        }
    }

    @Test("NWS event JSON decodes point geometry coordinates")
    func nwsPointCoordinatesDecode() throws {
        let json = """
        {
          "type": "FeatureCollection",
          "features": [
            {
              "id": "urn:oid:example-point",
              "type": "Feature",
              "geometry": {
                "type": "Point",
                "coordinates": [-104.0, 39.0]
              },
              "properties": {
                "id": "https://api.weather.gov/alerts/example-point",
                "areaDesc": "Test County"
              }
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(NwsEventDTO.self, from: Data(json.utf8))

        guard let geometry = decoded.features?.first?.geometry else {
            Issue.record("Expected a geometry payload.")
            return
        }

        switch geometry.coordinates {
        case .array(let pair):
            #expect(pair.count == 2)
        default:
            Issue.record("Expected point coordinates to decode as an array pair.")
        }
    }

    @Test("NWS feature maps to canonical ArcusEvent")
    func nwsFeatureMapsToArcusEvent() throws {
        let json = """
        {
          "type": "FeatureCollection",
          "features": [
            {
              "id": "urn:oid:abc123",
              "type": "Feature",
              "geometry": {
                "type": "Point",
                "coordinates": [-104.99, 39.73]
              },
              "properties": {
                "id": "https://api.weather.gov/alerts/abc123",
                "areaDesc": "Denver County",
                "geocode": {
                  "UGC": ["COC031", "COC005"],
                  "SAME": ["08031", "08005"]
                },
                "event": "Tornado Warning",
                "headline": "Tornado Warning for Denver County",
                "severity": "Severe",
                "urgency": "Immediate",
                "certainty": "Observed",
                "sent": "2026-02-21T16:00:00Z",
                "effective": "2026-02-21T16:02:00Z",
                "expires": "2026-02-21T17:00:00Z"
              }
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(NwsEventDTO.self, from: Data(json.utf8))
        let now = isoDate("2026-02-21T16:30:00Z")
        let events = decoded.toArcusEvents(now: now)

        #expect(events.count == 1)
        guard let event = events.first else {
            Issue.record("Expected a canonical event from mapper.")
            return
        }

        #expect(event.eventKey == "nws:urn:oid:abc123")
        #expect(event.source == .nws)
        #expect(event.kind == .torWarning)
        #expect(event.sourceURL == "https://api.weather.gov/alerts/abc123")
        #expect(event.status == .active)
        #expect(event.severity == .warning)
        #expect(event.urgency == .immediate)
        #expect(event.certainty == .observed)
        #expect(event.areaDesc == "Denver County")
        #expect(event.title == "Tornado Warning for Denver County")
        #expect(event.ugcCodes == ["COC031", "COC005"])

        switch event.geometry {
        case .point(let lon, let lat):
            #expect(lon == -104.99)
            #expect(lat == 39.73)
        default:
            Issue.record("Expected point geometry in mapped canonical event.")
        }
    }

    @Test("NWS mapper marks event ended when expired")
    func nwsMapperMarksEndedWhenExpired() throws {
        let json = """
        {
          "type": "FeatureCollection",
          "features": [
            {
              "id": "urn:oid:ended-1",
              "type": "Feature",
              "geometry": {
                "type": "Point",
                "coordinates": [-105.2, 39.1]
              },
              "properties": {
                "id": "https://api.weather.gov/alerts/ended-1",
                "areaDesc": "Jefferson County",
                "event": "Severe Thunderstorm Warning",
                "expires": "2026-02-21T15:00:00Z"
              }
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(NwsEventDTO.self, from: Data(json.utf8))
        let now = isoDate("2026-02-21T16:30:00Z")
        let events = decoded.toArcusEvents(now: now)

        #expect(events.count == 1)
        #expect(events.first?.status == .ended)
    }

    @Test("NWS mapper converts polygon geometry and filters unsupported events")
    func nwsMapperConvertsPolygonAndFiltersUnsupported() throws {
        let json = """
        {
          "type": "FeatureCollection",
          "features": [
            {
              "id": "urn:oid:poly-1",
              "type": "Feature",
              "geometry": {
                "type": "Polygon",
                "coordinates": [
                  [
                    [-104.0, 39.0],
                    [-103.5, 39.5],
                    [-104.0, 39.0]
                  ]
                ]
              },
              "properties": {
                "id": "https://api.weather.gov/alerts/poly-1",
                "areaDesc": "Polygon County",
                "event": "Flash Flood Warning"
              }
            },
            {
              "id": "urn:oid:skip-1",
              "type": "Feature",
              "geometry": {
                "type": "Point",
                "coordinates": [-100.0, 40.0]
              },
              "properties": {
                "id": "https://api.weather.gov/alerts/skip-1",
                "areaDesc": "Skip County",
                "event": "Special Weather Statement"
              }
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(NwsEventDTO.self, from: Data(json.utf8))
        let events = decoded.toArcusEvents(now: isoDate("2026-02-21T16:30:00Z"))

        #expect(events.count == 1)
        #expect(events.first?.kind == .ffWarning)

        switch events.first?.geometry {
        case .polygon(let rings):
            #expect(rings.isEmpty == false)
            #expect(rings.first?.isEmpty == false)
        default:
            Issue.record("Expected polygon geometry in mapped canonical event.")
        }
    }

    @Test("NWS mapper preserves references for ingest linkage")
    func nwsMapperPreservesReferenceSourceURLs() throws {
        let json = """
        {
          "type": "FeatureCollection",
          "features": [
            {
              "id": "urn:oid:update-2",
              "type": "Feature",
              "geometry": {
                "type": "Point",
                "coordinates": [-104.99, 39.73]
              },
              "properties": {
                "id": "https://api.weather.gov/alerts/update-2",
                "areaDesc": "Denver County",
                "event": "Tornado Warning",
                "references": [
                  {
                    "@id": "https://api.weather.gov/alerts/update-1",
                    "identifier": "ABC-123",
                    "sender": "w-nws.webmaster@noaa.gov",
                    "sent": "2026-02-21T16:00:00Z"
                  }
                ]
              }
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(NwsEventDTO.self, from: Data(json.utf8))
        let ingestEvents = decoded.toArcusIngestEvents(now: isoDate("2026-02-21T16:30:00Z"))

        #expect(ingestEvents.count == 1)
        #expect(ingestEvents.first?.referenceSourceURLs == ["https://api.weather.gov/alerts/update-1"])
        #expect(ingestEvents.first?.event.sourceURL == "https://api.weather.gov/alerts/update-2")
    }

    @Test("ArcusEventModel round-trips canonical event")
    func arcusEventModelRoundTrip() throws {
        let domain = ArcusEvent(
            eventKey: "nws:urn:oid:roundtrip-1",
            source: .nws,
            kind: .torWarning,
            sourceURL: "https://api.weather.gov/alerts/roundtrip-1",
            status: .active,
            revision: 2,
            issuedAt: isoDate("2026-02-21T16:00:00Z"),
            effectiveAt: isoDate("2026-02-21T16:05:00Z"),
            expiresAt: isoDate("2026-02-21T17:00:00Z"),
            severity: .warning,
            urgency: .immediate,
            certainty: .observed,
            geometry: .polygon(
                rings: [[
                    .init(lon: -104.0, lat: 39.0),
                    .init(lon: -103.5, lat: 39.5),
                    .init(lon: -104.0, lat: 39.0)
                ]]
            ),
            ugcCodes: ["COC031", "COC005"],
            h3Resolution: 8,
            h3CoverHash: "test-cover-hash",
            title: "Round trip test",
            areaDesc: "Denver Metro",
            rawRef: "raw/nws/roundtrip-1.json"
        )

        let model = try ArcusEventModel(from: domain, asOf: isoDate("2026-02-21T16:30:00Z"))
        #expect(model.isExpired == false)

        let expiredModel = try ArcusEventModel(from: domain, asOf: isoDate("2026-02-21T18:00:00Z"))
        #expect(expiredModel.isExpired == true)

        let roundTrip = try model.asDomain()

        #expect(roundTrip == domain)
    }

    @Test("Ingest deduplicator ignores duplicates and keeps latest payload")
    func ingestDeduplicatorKeepsLatest() throws {
        let first = makeIngestEvent(key: "nws:dup-1", revision: 1, title: "First")
        let second = makeIngestEvent(key: "nws:dup-1", revision: 99, title: "Second")
        let distinct = makeIngestEvent(key: "nws:dup-2", revision: 1, title: "Distinct")

        let deduped = ArcusEventDeduplicator.deduplicate([first, second, distinct])

        #expect(deduped.events.count == 2)
        #expect(deduped.duplicatesIgnored == 1)
        #expect(deduped.events[0].event.eventKey == "nws:dup-1")
        #expect(deduped.events[0].event.title == "Second")
        #expect(deduped.events[1].event.eventKey == "nws:dup-2")
    }

    @Test("ArcusEventModel content hash ignores revision but tracks payload changes")
    func arcusEventContentHashSemantics() throws {
        let base = makeEvent(key: "nws:hash-1", revision: 1, title: "Title A")
        let samePayloadDifferentRevision = makeEvent(key: "nws:hash-1", revision: 42, title: "Title A")
        let changedPayload = makeEvent(key: "nws:hash-1", revision: 1, title: "Title B")

        let asOf = isoDate("2026-02-21T16:30:00Z")
        let baseModel = try ArcusEventModel(from: base, asOf: asOf)
        let samePayloadModel = try ArcusEventModel(from: samePayloadDifferentRevision, asOf: asOf)
        let changedPayloadModel = try ArcusEventModel(from: changedPayload, asOf: asOf)

        #expect(baseModel.contentHash == samePayloadModel.contentHash)
        #expect(baseModel.contentHash != changedPayloadModel.contentHash)
    }

    @Test("Scheduler dispatches ingest job to ingest lane")
    func scheduledDispatchUsesIngestLane() async throws {
        try await withApp(mode: .worker) { app in
            app.queues.use(.test)
            let hook = DispatchCaptureHook()
            app.queues.add(hook)

            let context = QueueContext(
                queueName: QueueName(string: "scheduled"),
                configuration: app.queues.configuration,
                application: app,
                logger: app.logger,
                on: app.eventLoopGroup.any()
            )
            try await DispatchIngestNWSAlertsScheduledJob().run(context: context)

            #expect(app.queues.test.contains(IngestNWSAlertsJob.self))
            #expect(await hook.dispatchedQueueNames().contains(ArcusQueueLane.ingest.rawValue))
        }
    }

    @Test("TargetEventRevision dispatch policy gates to changed and active revisions")
    func targetDispatchPolicyGatesChangedAndActive() {
        #expect(TargetEventRevisionDispatchPolicy.shouldDispatchOnCreate(isExpired: false))
        #expect(!TargetEventRevisionDispatchPolicy.shouldDispatchOnCreate(isExpired: true))
        #expect(TargetEventRevisionDispatchPolicy.shouldDispatchOnUpdate(contentChanged: true, isExpired: false))
        #expect(!TargetEventRevisionDispatchPolicy.shouldDispatchOnUpdate(contentChanged: false, isExpired: false))
        #expect(!TargetEventRevisionDispatchPolicy.shouldDispatchOnUpdate(contentChanged: true, isExpired: true))
    }
}

private actor DispatchCaptureHook: AsyncJobEventDelegate {
    private var queueNames: [String] = []

    func dispatched(job: JobEventData) async throws {
        queueNames.append(job.queueName)
    }

    func dispatchedQueueNames() -> [String] {
        queueNames
    }
}
