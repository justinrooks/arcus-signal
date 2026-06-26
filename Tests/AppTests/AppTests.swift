@testable import App
import FluentSQL
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
import ArcusCore

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
        urn: String = "urn:oid:test-event",
        sourceURL: String = "https://api.weather.gov/alerts/test-event",
        title: String? = "Tornado Warning for Test Area"
    ) -> ArcusEvent {
        ArcusEvent(
            urn: urn,
            source: .nws,
            kind: "Tornado Warning",
            sourceURL: sourceURL,
            vtec: nil,
            messageType: .alert,
            state: .active,
            references: [],
            sent: isoDate("2026-02-21T16:00:00Z"),
            effective: isoDate("2026-02-21T16:05:00Z"),
            onset: isoDate("2026-02-21T16:10:00Z"),
            expires: isoDate("2026-02-21T17:00:00Z"),
            ends: nil,
            lastSeenActive: isoDate("2026-02-21T16:30:00Z"),
            severity: .severe,
            urgency: .immediate,
            certainty: .observed,
            geometry: nil,
            ugcCodes: ["COC031"],
            title: title,
            areaDesc: "Test Area",
            rawRef: nil,
            category: "Met",
            event: "Tornado Warning",
            senderName: "NWS Boulder CO",
            headline: title,
            description: "Storm text",
            instructions: "Take shelter now",
            response: "Shelter",
            status: "Actual",
            tornadoDetection: "observed",
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

    private func makeAlertSeriesRow(
        id: UUID = UUID(),
        now: Date,
        ugcCodes: [String] = ["COC031"],
        h3Cells: [Int64] = [],
        geometry: GeoShape? = nil
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
            h3Cells: h3Cells,
            geometry: geometry,
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

    @Test("API health endpoint returns ok")
    func apiHealth() async throws {
        try await withApp(mode: .api) { app in
            try await app.testing().test(.GET, "health", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "")
            })
        }
    }

    private func productionBootstrapEnvironment(
        databaseURL: String? = "postgres://arcus:arcus@127.0.0.1:5432/arcus_signal?tlsmode=disable",
        redisURL: String? = "redis://127.0.0.1:6379"
    ) -> [String: String?] {
        [
            "DATABASE_URL": databaseURL,
            "REDIS_URL": redisURL
        ]
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
            "APNS_TEAM_ID": nil,
            "APNS_TOPIC": nil,
            "APNS_SANDBOX_KEY_ID": nil,
            "APNS_SANDBOX_PRIVATE_KEY_PATH": nil,
            "APNS_PROD_KEY_ID": nil,
            "APNS_PROD_PRIVATE_KEY_PATH": nil
        ]) {
            try await withApp(mode: .worker) { app in
                let productionContainer = await app.apns.containers.container(for: .production)
                let developmentContainer = await app.apns.containers.container(for: .development)
                #expect(productionContainer == nil)
                #expect(developmentContainer == nil)
            }
        }
    }

    @Test("Worker bootstrap preserves an injected Storm Setup provider")
    func workerBootstrapPreservesInjectedStormSetupProvider() async throws {
        let app = try await Application.make(.testing)
        do {
            app.stormSetupProvider = SentinelStormSetupProvider()
            try await configure(app, mode: .worker)
            #expect(app.stormSetupProvider is SentinelStormSetupProvider)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("Worker APNS request encoder uses ISO8601 dates")
    func workerAPNSRequestEncoderUsesISO8601Dates() throws {
        let encoder = makeAPNSRequestEncoder()
        let payload = HotAlertAPNsPayload(
            arcusAlertId: "11111111-2222-3333-4444-555555555555",
            revisionSent: Date(timeIntervalSince1970: 1_747_744_896)
        )

        let encoded = try encoder.encode(payload)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        #expect(object?[HotAlertAPNsPayload.revisionSentKey] as? String == "2025-05-20T12:41:36Z")
        #expect(object?[HotAlertAPNsPayload.arcusAlertIDKey] as? String == "11111111-2222-3333-4444-555555555555")
    }

    @Test("Worker production bootstrap fails when APNS config is missing")
    func workerProductionBootstrapFailsWithoutAPNSConfig() async throws {
        var overrides = productionBootstrapEnvironment()
        overrides.merge([
            "APNS_TEAM_ID": nil,
            "APNS_TOPIC": nil,
            "APNS_SANDBOX_KEY_ID": nil,
            "APNS_SANDBOX_PRIVATE_KEY_PATH": nil,
            "APNS_PROD_KEY_ID": nil,
            "APNS_PROD_PRIVATE_KEY_PATH": nil
        ], uniquingKeysWith: { _, new in new })

        try await withEnvironment(overrides) {
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

    @Test("Production bootstrap fails when DATABASE_URL is missing")
    func productionBootstrapFailsWithoutDatabaseURL() async throws {
        try await withEnvironment([
            "DATABASE_URL": nil,
            "REDIS_URL": "redis://127.0.0.1:6379"
        ]) {
            let app = try await Application.make(.production)
            var capturedError: (any Error)?
            do {
                try await configure(app, mode: .api)
            } catch {
                capturedError = error
            }
            try await app.asyncShutdown()

            guard let capturedError else {
                Issue.record("Expected configure to fail when DATABASE_URL is missing in production.")
                return
            }

            guard let abortError = capturedError as? any AbortError else {
                Issue.record("Expected AbortError but got \(String(describing: capturedError)).")
                return
            }

            #expect(abortError.status == .internalServerError)
            #expect(abortError.reason.contains("DATABASE_URL must be set when running in production."))
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
        #expect(payload.geometry == nil)
    }

    @Test("Device alert payload includes eager-loaded polygon geometry")
    func deviceAlertPayloadIncludesGeolocationGeometry() throws {
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
                geometry: .polygon(
                    rings: [[
                        .init(lon: -104.0, lat: 39.0),
                        .init(lon: -103.5, lat: 39.5),
                        .init(lon: -104.0, lat: 39.0)
                    ]]
                ),
                geometryHash: "geom-hash",
                h3Cells: [617700169958293503],
                h3Resolution: 8,
                h3Hash: "h3-hash"
            )
        )

        let payload = try series.asDeviceAlertPayload()

        #expect(payload.h3Cells == [617700169958293503])
        #expect(payload.geometry == .polygon(rings: [[
            .init(longitude: -104.0, latitude: 39.0),
            .init(longitude: -103.5, latitude: 39.5),
            .init(longitude: -104.0, latitude: 39.0)
        ]]))
    }

    @Test("Device alert geometry uses multipolygon wire shape")
    func deviceAlertGeometryUsesMultipolygonWireShape() {
        let geometry: DeviceAlertGeometry = .multiPolygon(polygons: [[[
            .init(longitude: -104.0, latitude: 39.0),
            .init(longitude: -103.5, latitude: 39.5),
            .init(longitude: -104.0, latitude: 39.0)
        ]]])

        #expect(geometry == .multiPolygon(polygons: [[[
            .init(longitude: -104.0, latitude: 39.0),
            .init(longitude: -103.5, latitude: 39.5),
            .init(longitude: -104.0, latitude: 39.0)
        ]]]))
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
        #expect(payload.geometry == nil)
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

    @Test("Alert series row carries joined polygon geometry into device payload")
    func alertSeriesRowPayloadIncludesJoinedGeometry() {
        let now = isoDate("2026-03-19T16:00:00Z")
        let row = makeAlertSeriesRow(
            now: now,
            geometry: .polygon(rings: [[
                .init(lon: -104.0, lat: 39.0),
                .init(lon: -103.5, lat: 39.5),
                .init(lon: -104.0, lat: 39.0)
            ]])
        )

        let payload = row.asDeviceAlertPayload()

        #expect(payload.geometry == .polygon(rings: [[
            .init(longitude: -104.0, latitude: 39.0),
            .init(longitude: -103.5, latitude: 39.5),
            .init(longitude: -104.0, latitude: 39.0)
        ]]))
    }

    @Test("Alert series row selects geolocation geometry instead of deprecated series geometry")
    func alertSeriesRowSelectsJoinedGeolocationGeometry() async throws {
        try await withApp(mode: .api) { app in
            guard let sql = app.db as? any SQLDatabase else {
                Issue.record("Expected configured app database to support SQL serialization.")
                return
            }

            let columns = sql.serialize(AlertSeriesRow.sqlSelectColumns()).sql

            #expect(columns.contains(#""g"."geometry" AS "geometry""#))
            #expect(!columns.contains(#""s"."geometry" AS "geometry""#))
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

    @Test("NWS feature maps to current ArcusEvent fields")
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

        #expect(event.id == "https://api.weather.gov/alerts/abc123")
        #expect(event.source == .nws)
        #expect(event.kind == "Tornado Warning")
        #expect(event.sourceURL == "urn:oid:abc123")
        #expect(event.state == .active)
        #expect(event.severity == .severe)
        #expect(event.urgency == .immediate)
        #expect(event.certainty == .observed)
        #expect(event.areaDesc == "Denver County")
        #expect(event.headline == "Tornado Warning for Denver County")
        #expect(event.ugcCodes == ["COC031", "COC005"])

        switch event.geometry {
        case .point(let lon, let lat):
            #expect(lon == -104.99)
            #expect(lat == 39.73)
        default:
            Issue.record("Expected point geometry in mapped canonical event.")
        }
    }

    @Test("NWS mapper marks cancel messages as cancelled in error")
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
        #expect(events.first?.state == .cancelled_in_error)
    }

    @Test("NWS mapper keeps supported and unsupported events while preserving polygon geometry")
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

        #expect(events.count == 2)
        #expect(events.map(\.kind).contains("Flash Flood Warning"))
        #expect(events.map(\.kind).contains("Special Weather Statement"))

        guard let polygonEvent = events.first(where: { $0.kind == "Flash Flood Warning" }) else {
            Issue.record("Expected polygon event in mapped results.")
            return
        }

        switch polygonEvent.geometry {
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
        #expect(events.first?.state == .active)
    }

    @Test("NWS mapper preserves reference identifiers on ArcusEvent")
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
        let events = decoded.toArcusEvents(now: isoDate("2026-02-21T16:30:00Z"))

        #expect(events.count == 1)
        #expect(events.first?.id == "https://api.weather.gov/alerts/update-2")
        #expect(events.first?.sourceURL == "urn:oid:update-2")
        #expect(events.first?.references == ["ABC-123"])
    }

    @Test("ArcusSeriesModel round-trips canonical event fields")
    func arcusEventModelRoundTrip() throws {
        let domain = ArcusEvent(
            urn: "urn:oid:roundtrip-1",
            source: .nws,
            kind: "Tornado Warning",
            sourceURL: "https://api.weather.gov/alerts/roundtrip-1",
            vtec: nil,
            messageType: .alert,
            state: .active,
            references: [],
            sent: isoDate("2026-02-21T16:00:00Z"),
            effective: isoDate("2026-02-21T16:05:00Z"),
            onset: isoDate("2026-02-21T16:06:00Z"),
            expires: isoDate("2026-02-21T17:00:00Z"),
            ends: nil,
            lastSeenActive: isoDate("2026-02-21T16:30:00Z"),
            severity: .severe,
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
            title: "Round trip test",
            areaDesc: "Denver Metro",
            rawRef: nil,
            category: "Met",
            event: "Tornado Warning",
            senderName: "NWS Boulder CO",
            headline: "Round trip headline",
            description: "Round trip description",
            instructions: "Round trip instruction",
            response: "Shelter",
            status: "Actual",
            tornadoDetection: "observed",
            tornadoDamageThreat: "considerable",
            maxWindGust: "80",
            maxHailSize: "1.75",
            windThreat: "observed",
            hailThreat: "radar indicated",
            thunderstormDamageThreat: "destructive",
            flashFloodDetection: "observed",
            flashFloodDamageThreat: "considerable"
        )

        let model = try ArcusSeriesModel(from: domain, asOf: domain.lastSeenActive)
        let roundTrip = try model.asDomain()

        #expect(roundTrip == domain)
    }

    @Test("ArcusEvent fingerprint ignores identifiers but tracks payload changes")
    func arcusEventContentHashSemantics() throws {
        let base = makeEvent(
            urn: "urn:oid:hash-1",
            sourceURL: "https://api.weather.gov/alerts/hash-1",
            title: "Title A"
        )
        let samePayloadDifferentIdentifiers = makeEvent(
            urn: "urn:oid:hash-2",
            sourceURL: "https://api.weather.gov/alerts/hash-2",
            title: "Title A"
        )
        let changedPayload = makeEvent(
            urn: "urn:oid:hash-1",
            sourceURL: "https://api.weather.gov/alerts/hash-1",
            title: "Title B"
        )

        let baseHash = try base.computeContentFingerprint()
        let sameHash = try samePayloadDifferentIdentifiers.computeContentFingerprint()
        let changedHash = try changedPayload.computeContentFingerprint()

        #expect(baseHash == sameHash)
        #expect(baseHash != changedHash)
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

    @Test("Arcus queue lanes include model artifacts")
    func arcusQueueLanesIncludeModelArtifacts() {
        #expect(ArcusQueueLane.allCases.contains(.modelArtifacts))
    }

    @Test("Worker bootstrap registers the HRRR pressure artifact probe schedule")
    func workerBootstrapRegistersPressureArtifactProbeSchedule() async throws {
        try await withApp(mode: .worker) { app in
            #expect(app.workerScheduledJobNames.contains("DispatchIngestNWSAlertsScheduledJob"))
            #expect(app.workerScheduledJobNames.contains("ProbeHRRRPressureArtifactsScheduledJob"))
            #expect(app.workerScheduledJobNames.contains("RefreshOperatorDashboardSnapshotScheduledJob"))
            #expect(app.workerScheduledJobNames.count == 3)
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

private final class SentinelStormSetupProvider: StormSetupProviding, @unchecked Sendable {
    func currentSnapshot(for h3Cell: Int64) async throws -> TornadoIngredientSnapshot {
        _ = h3Cell
        throw Abort(.internalServerError, reason: "Sentinel provider should never be called.")
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
