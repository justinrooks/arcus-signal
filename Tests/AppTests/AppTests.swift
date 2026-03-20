@testable import App
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
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

    private func withEnvironment(
        _ overrides: [String: String?],
        test: () async throws -> Void
    ) async throws {
        let previousValues = overrides.keys.reduce(into: [String: String?]()) { partialResult, key in
            partialResult[key] = Environment.get(key)
        }

        func apply(_ values: [String: String?]) {
            for (key, value) in values {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        apply(overrides)
        do {
            try await test()
        } catch {
            apply(previousValues)
            throw error
        }
        apply(previousValues)
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
        let sourceURL = key.hasPrefix("http") ? key : "https://api.weather.gov/alerts/\(key)"
        return ArcusEvent(
            eventKey: key,
            source: .nws,
            kind: .torWarning,
            sourceURL: sourceURL,
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
        messageType: NWSAlertMessageType = .alert,
        sentAt: Date? = nil,
        supersededEventKeys: [String] = []
    ) -> ArcusIngestEvent {
        ArcusIngestEvent(
            event: makeEvent(key: key, revision: revision, expiresAt: expiresAt, title: title),
            messageType: messageType,
            sentAt: sentAt,
            supersededEventKeys: supersededEventKeys
        )
    }

    private func makeAlertSeriesRow(
        id: UUID = UUID(),
        now: Date,
        ugcCodes: [String] = ["COC031"],
        h3Cells: [Int64] = []
    ) -> AlertSeriesRow {
        AlertSeriesRow(
            id: id,
            event: "Tornado Warning",
            currentRevisionUrn: "urn:oid:test-alert",
            currentRevisionSent: now,
            messageType: NWSAlertMessageType.alert.rawValue,
            contentFingerprint: "fingerprint",
            state: EventState.active.rawValue,
            created: now,
            updated: now,
            lastSeenActive: now,
            sent: now,
            effective: now,
            onset: nil,
            expires: nil,
            ends: nil,
            severity: EventSeverity.severe.rawValue,
            urgency: EventUrgency.immediate.rawValue,
            certainty: EventCertainty.observed.rawValue,
            areaDesc: "Denver County",
            senderName: "NWS Boulder CO",
            headline: "Tornado Warning issued",
            description: "Storm text",
            instructions: "Take shelter now",
            response: "Shelter",
            ugcCodes: ugcCodes,
            h3Cells: h3Cells
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

    @Test("Worker testing bootstrap allows missing APNS config")
    func workerTestingBootstrapAllowsMissingAPNSConfig() async throws {
        try await withEnvironment([
            "APNS_PRIVATE_KEY_PATH": nil,
            "APNS_KEY_ID": nil,
            "APNS_TEAM_ID": nil
        ]) {
            try await withApp(mode: .worker) { app in
                let productionContainer = await app.apns.containers.container(for: .production)
                let developmentContainer = await app.apns.containers.container(for: .development)
                #expect(productionContainer == nil)
                #expect(developmentContainer == nil)
            }
        }
    }

    @Test("Worker production bootstrap fails when APNS config is missing")
    func workerProductionBootstrapFailsWithoutAPNSConfig() async throws {
        try await withEnvironment([
            "DATABASE_URL": "postgres://arcus:arcus@127.0.0.1:5432/arcus_signal?tlsmode=disable",
            "REDIS_URL": "redis://127.0.0.1:6379",
            "APNS_PRIVATE_KEY_PATH": nil,
            "APNS_KEY_ID": nil,
            "APNS_TEAM_ID": nil
        ]) {
            let app = try await Application.make(.production)
            var capturedError: (any Error)?
            do {
                try await configure(app, mode: .worker)
            } catch {
                capturedError = error
            }
            try await app.asyncShutdown()

            guard let capturedError else {
                Issue.record("Expected configure to fail when APNS config is missing in production.")
                return
            }

            guard let abortError = capturedError as? any AbortError else {
                Issue.record("Expected AbortError but got \(String(describing: capturedError)).")
                return
            }

            #expect(abortError.status == .internalServerError)
            #expect(abortError.reason.contains("APNS configuration is incomplete."))
        }
    }

    @Test("Device alert payload tolerates unloaded geolocation relation")
    func deviceAlertPayloadAllowsUnloadedGeolocation() throws {
        let now = isoDate("2026-03-19T16:00:00Z")
        let seriesID = UUID()
        let series = ArcusSeriesModel(
            id: seriesID,
            source: EventSource.nws.rawValue,
            event: "Tornado Warning",
            sourceURL: "https://api.weather.gov/alerts/test-alert",
            currentRevisionUrn: "urn:oid:test-alert",
            currentRevisionSent: now,
            messageType: NWSAlertMessageType.alert.rawValue,
            contentFingerprint: "fingerprint",
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
            description: "Storm text"
        )

        let payload = try series.asDeviceAlertPayload()

        #expect(payload.ugc == ["COC031"])
        #expect(payload.h3Cells == [])
    }

    @Test("Device alert payload includes eager-loaded geolocation cells")
    func deviceAlertPayloadIncludesGeolocationCells() throws {
        let now = isoDate("2026-03-19T16:00:00Z")
        let seriesID = UUID()
        let series = ArcusSeriesModel(
            id: seriesID,
            source: EventSource.nws.rawValue,
            event: "Tornado Warning",
            sourceURL: "https://api.weather.gov/alerts/test-alert",
            currentRevisionUrn: "urn:oid:test-alert",
            currentRevisionSent: now,
            messageType: NWSAlertMessageType.alert.rawValue,
            contentFingerprint: "fingerprint",
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
            description: "Storm text"
        )
        series.$geolocation.value = .some(
            ArcusGeolocationModel(
                series: seriesID,
                geometry: .point(lon: -104.9903, lat: 39.7392),
                geometryHash: "geom-hash",
                h3Cells: [617700169958293503],
                h3Resolution: 8,
                h3Hash: "h3-hash"
            )
        )

        let payload = try series.asDeviceAlertPayload()

        #expect(payload.h3Cells == [617700169958293503])
    }

    @Test("Alert series row maps UGC codes and empty H3 cells into device payload")
    func alertSeriesRowPayloadAllowsMissingGeolocation() {
        let now = isoDate("2026-03-19T16:00:00Z")
        let row = makeAlertSeriesRow(
            now: now,
            ugcCodes: ["COC031", "COZ038"]
        )

        let payload = row.asDeviceAlertPayload()

        #expect(payload.ugc == ["COC031", "COZ038"])
        #expect(payload.h3Cells == [])
        #expect(payload.senderName == "NWS Boulder CO")
    }

    @Test("Alert series row carries joined H3 cells into device payload")
    func alertSeriesRowPayloadIncludesJoinedH3Cells() {
        let now = isoDate("2026-03-19T16:00:00Z")
        let row = makeAlertSeriesRow(
            now: now,
            h3Cells: [617700169958293503, 617700170495164415]
        )

        let payload = row.asDeviceAlertPayload()

        #expect(payload.ugc == ["COC031"])
        #expect(payload.h3Cells == [617700169958293503, 617700170495164415])
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

        #expect(event.eventKey == "https://api.weather.gov/alerts/abc123")
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

    @Test("NWS mapper marks event ended when message is cancel")
    func nwsMapperMarksEndedWhenCancel() throws {
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
                "messageType": "Cancel"
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

    @Test("NWS mapper keeps event active when only expires is in past")
    func nwsMapperDoesNotEndWhenOnlyExpiresPassed() throws {
        let json = """
        {
          "type": "FeatureCollection",
          "features": [
            {
              "id": "urn:oid:expires-1",
              "type": "Feature",
              "geometry": {
                "type": "Point",
                "coordinates": [-104.99, 39.73]
              },
              "properties": {
                "id": "https://api.weather.gov/alerts/expires-1",
                "areaDesc": "Denver County",
                "event": "Tornado Warning",
                "expires": "2026-02-21T15:00:00Z"
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
        #expect(events.first?.status == .active)
    }

    @Test("NWS mapper preserves superseded event keys for ingest linkage")
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
        #expect(ingestEvents.first?.supersededEventKeys == ["https://api.weather.gov/alerts/update-1"])
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

        let deduped = ArcusIngestMessageDeduplicator.deduplicate([first, second, distinct])

        #expect(deduped.events.count == 2)
        #expect(deduped.duplicatesIgnored == 1)
        #expect(deduped.events[0].event.eventKey == "nws:dup-1")
        #expect(deduped.events[0].event.title == "Second")
        #expect(deduped.events[1].event.eventKey == "nws:dup-2")
    }

    @Test("Ingest lineage resolver keeps only final superseding message in a chain")
    func ingestLineageResolverKeepsLatestSupersedingMessage() {
        let alert = makeIngestEvent(
            key: "https://api.weather.gov/alerts/a",
            sentAt: isoDate("2026-02-21T16:00:00Z")
        )
        let update1 = makeIngestEvent(
            key: "https://api.weather.gov/alerts/b",
            messageType: .update,
            sentAt: isoDate("2026-02-21T16:05:00Z"),
            supersededEventKeys: ["https://api.weather.gov/alerts/a"]
        )
        let update2 = makeIngestEvent(
            key: "https://api.weather.gov/alerts/c",
            messageType: .update,
            sentAt: isoDate("2026-02-21T16:10:00Z"),
            supersededEventKeys: [
                "https://api.weather.gov/alerts/a",
                "https://api.weather.gov/alerts/b"
            ]
        )

        let resolved = ArcusIngestLineageResolver.resolve(
            events: [alert, update1, update2],
            existingByEventKey: [:]
        )

        #expect(resolved.count == 1)
        #expect(resolved.first?.winner.event.eventKey == "https://api.weather.gov/alerts/c")
        #expect(resolved.first?.supersededInRun == 2)
    }

    @Test("Ingest lineage resolver links update chain to existing event key")
    func ingestLineageResolverLinksToExistingEvent() throws {
        let existingEventKey = "https://api.weather.gov/alerts/existing-a"
        let existingModel = try ArcusEventModel(
            from: makeEvent(key: existingEventKey, title: "Existing"),
            asOf: isoDate("2026-02-21T16:00:00Z")
        )

        let incomingUpdate = makeIngestEvent(
            key: "https://api.weather.gov/alerts/existing-b",
            messageType: .update,
            sentAt: isoDate("2026-02-21T16:05:00Z"),
            supersededEventKeys: [existingEventKey]
        )

        let resolved = ArcusIngestLineageResolver.resolve(
            events: [incomingUpdate],
            existingByEventKey: [existingEventKey: existingModel]
        )

        #expect(resolved.count == 1)
        #expect(resolved.first?.existing?.eventKey == existingEventKey)
        #expect(resolved.first?.winner.event.eventKey == "https://api.weather.gov/alerts/existing-b")
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
