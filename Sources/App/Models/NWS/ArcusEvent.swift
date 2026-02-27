import Foundation
import SwiftyH3

// MARK: - Canonical Domain Model

public enum EventSource: String, Codable, Sendable {
    case nws
    case spc
}

public enum EventKind: String, Codable, Sendable {
    // NWS
    case torWarning
    case svrTstormWarning
    case ffWarning
    case torWatch
    case svrTstormWatch
    case winterStormWarning
    case fireWarning
    case fireWeatherWatch
    case extremeFireDanger
    case redFlagWarning

    // SPC
    case spcMesoscaleDiscussion
}

public enum EventStatus: String, Codable, Sendable {
    case active
    case ended
    case issuedInError
}

public enum EventSeverity: String, Codable, Sendable {
    // severities pairing with CAP standards
    case extreme // extraordinary threat to live or property
    case severe // significant threat to life or property
    case moderate // possible threat to life or property
    case minor // minimal to no konwn threat to life or property
    case unknown // unknown
}

public enum EventUrgency: String, Codable, Sendable {
    // urgencies pairing with CAP standards
    case immediate //Responsive action should be taken immediately
    case expected // Responsive action should be taken soon (within the next hr)
    case future // Responsive action should be taken in the near future
    case past // Responsive action is no longer required
    case unknown
}

public enum EventCertainty: String, Codable, Sendable {
    case observed // determined to have occurred or to be ongoing
    case likely // > ~50% probability
    case possible //possible but not likely, <= ~50% probability of
    case unlikely // probability ~0
    case unknown // unknown
}

public enum NWSAlertMessageType: String, Codable, Sendable {
    // NWS spin on CAP standard
    case alert
    case update
    case cancel // Issued in error
    case unknown
}

/// Geometry sufficient for H3 cover generation.
public enum GeoShape: Codable, Sendable, Equatable {
    case point(lon: Double, lat: Double)
    case polygon(rings: [[GeoCoordinate]])
    case multiPolygon(polygons: [[[GeoCoordinate]]])

    public struct GeoCoordinate: Codable, Sendable, Equatable {
        public let lon: Double
        public let lat: Double

        public init(lon: Double, lat: Double) {
            self.lon = lon
            self.lat = lat
        }
    }
}

/// Canonical event that downstream systems should depend on.
public struct ArcusEvent: Codable, Sendable, Equatable {
    // Identity
    public let id: String      // urn:oid:...
    public let source: EventSource
    public let kind: EventKind // event property in the message
    public let sourceURL: String
    public let vtec: VTECDescriptor?
    public let messageType: NWSAlertMessageType

    // Lifecycle
    public let status: EventStatus
    public let references: [String] // list of id's this message supersedes

    // Timing
    public let sentAt: Date? // time of the origination of message itself
    public let effectiveAt: Date? // goes into effect
    public let onsetAt: Date? // beginning of the event in message
    public let expiresAt: Date? // alert message expiration
    public let endsAt: Date?

    // Severity inputs (normalized)
    public let severity: EventSeverity
    public let urgency: EventUrgency
    public let certainty: EventCertainty

    // Targeting
    public let geometry: GeoShape?
    public let ugcCodes: [String]
    public let h3Resolution: Int?
    public let h3CoverHash: String?

    // Human-facing metadata
    public let title: String?
    public let areaDesc: String?

    // Raw payload reference
    public let rawRef: String?

    public init(
        urn: String,
        source: EventSource,
        kind: EventKind,
        sourceURL: String,
        vtec: VTECDescriptor?,
        messageType: NWSAlertMessageType,
        status: EventStatus,
        references: [String] = [],
        sentAt: Date?,
        effectiveAt: Date?,
        onsetAt: Date?,
        expiresAt: Date?,
        endsAt: Date?,
        severity: EventSeverity,
        urgency: EventUrgency,
        certainty: EventCertainty,
        geometry: GeoShape?,
        ugcCodes: [String],
        h3Resolution: Int?,
        h3CoverHash: String?,
        title: String?,
        areaDesc: String?,
        rawRef: String?
    ) {
        self.id = urn
        self.source = source
        self.kind = kind
        self.sourceURL = sourceURL
        self.vtec = vtec
        self.messageType = messageType
        self.status = status
        self.references = references
        self.sentAt = sentAt
        self.effectiveAt = effectiveAt
        self.onsetAt = onsetAt
        self.expiresAt = expiresAt
        self.endsAt = endsAt
        self.severity = severity
        self.urgency = urgency
        self.certainty = certainty
        self.geometry = geometry
        self.ugcCodes = ugcCodes
        self.h3Resolution = h3Resolution
        self.h3CoverHash = h3CoverHash
        self.title = title
        self.areaDesc = areaDesc
        self.rawRef = rawRef
    }
}

///// Ingest payload that preserves upstream linkage metadata needed for revision chaining.
//public struct ArcusIngestEvent: Sendable, Equatable {
//    public let event: ArcusEvent
//    public let messageType: NWSAlertMessageType
//    public let sentAt: Date?
//    public let supersededEventKeys: [String]
//
//    public init(
//        event: ArcusEvent,
//        messageType: NWSAlertMessageType,
//        sentAt: Date?,
//        supersededEventKeys: [String]
//    ) {
//        self.event = event
//        self.messageType = messageType
//        self.sentAt = sentAt
//        self.supersededEventKeys = supersededEventKeys
//    }
//}

///// Revision record for idempotency + dedupe persistence.
///// Intended unique constraint: (eventKey, revisionHash).
//public struct EventRevision: Codable, Sendable, Equatable {
//    public let eventKey: String
//    public let revision: Int
//    public let revisionHash: String
//    public let createdAt: Date
//    public let changeSummary: String?
//
//    public init(
//        eventKey: String,
//        revision: Int,
//        revisionHash: String,
//        createdAt: Date = Date(),
//        changeSummary: String? = nil
//    ) {
//        self.eventKey = eventKey
//        self.revision = revision
//        self.revisionHash = revisionHash
//        self.createdAt = createdAt
//        self.changeSummary = changeSummary
//    }
//}

// MARK: - NWS -> Canonical Mapper

public extension NwsEventDTO {
    func toArcusEvents(
        now: Date = .now,
        revision: Int = 1,
        h3Resolution: Int? = 8,
        rawRef: String? = nil
    ) -> [ArcusEvent] {
        (features ?? []).compactMap {
            $0.toArcusEvent(
                now: now,
                revision: revision,
                h3Resolution: h3Resolution,
                rawRef: rawRef
            )
        }
    }
//
//    func toArcusEvents(
//        now: Date = .now,
//        revision: Int = 1,
//        h3Resolution: Int? = 8,
//        rawRef: String? = nil
//    ) -> [ArcusEvent] {
//        toArcusIngestEvents(
//            now: now,
//            revision: revision,
//            h3Resolution: h3Resolution,
//            rawRef: rawRef
//        ).map(\.event)
//    }
}

public extension NwsEventFeatureDTO {
//    func toArcusIngestEvent(
//        now: Date = .now,
//        revision: Int = 1,
//        h3Resolution: Int? = 8,
//        rawRef: String? = nil
//    ) -> ArcusIngestEvent? {
//        guard let event = toArcusEvent(
//            now: now,
//            revision: revision,
//            h3Resolution: h3Resolution,
//            rawRef: rawRef
//        ) else {
//            return nil
//        }
//
//        let supersededEventKeys = properties.references?
//            .compactMap { Self.normalizeMessageID($0.id) }
//            .uniquedPreservingOrder() ?? []
//        let messageType = NWSAlertMessageType.fromNws(properties.messageType)
//
//        return ArcusIngestEvent(
//            event: event,
//            messageType: messageType,
//            sentAt: properties.sent,
//            supersededEventKeys: supersededEventKeys
//        )
//    }
//
    func toArcusEvent(
        now: Date = .now,
        revision: Int = 1,
        h3Resolution: Int? = 8,
        rawRef: String? = nil
    ) -> ArcusEvent? {
        guard let kind = EventKind.fromNwsEventName(properties.event) else {
            return nil
        }

        let messageID = Self.normalizeMessageID(properties.id) ?? Self.normalizeMessageID(id) ?? properties.id
        let endsAt = properties.ends
        let messageType = NWSAlertMessageType.fromNws(properties.messageType)
        let vtec = properties.parameters?["VTEC"]?.first ?? ""
        let vtecP = vtec.parseVTEC()
        let refs = properties.references?.compactMap{ $0.identifier }
        let geometry = geometry?.toGeoShape()
        let poly: String? = switch geometry {
        case .polygon(let rings)?:
            try? Self.h3CoverHashForPolygon(rings, resolution: h3Resolution)
        case .multiPolygon(let polygons)?:
            if let firstPolygon = polygons.first {
                try? Self.h3CoverHashForPolygon(firstPolygon, resolution: h3Resolution)
            } else {
                nil
            }
        case .point?:
            nil
        case nil:
            nil
        }

        return .init(
            urn: messageID,
            source: .nws,
            kind: kind,
            sourceURL: id,
            vtec: vtecP ?? nil, // We are specifically only grabbing the first. Its a business decision, we can adjust later
            messageType: NWSAlertMessageType.fromNws(properties.messageType),
            status: ArcusEvent.status(now: now, messageType: messageType, endsAt: endsAt),
            references: refs ?? [],
            sentAt: properties.sent,
            effectiveAt: properties.effective,
            onsetAt: properties.onset,
            expiresAt: properties.expires,
            endsAt: endsAt,
            severity: EventSeverity.fromNws(properties.severity),
            urgency: EventUrgency.fromNws(properties.urgency),
            certainty: EventCertainty.fromNws(properties.certainty),
            geometry: geometry,
            ugcCodes: properties.geocode?.ugc ?? [],
            h3Resolution: h3Resolution,
            h3CoverHash: poly, // We'll compute this later, and only if there's geometry provided.
            title: properties.headline ?? properties.event,
            areaDesc: properties.areaDesc,
            rawRef: rawRef
        )
    }

    private static func h3CoverHashForPolygon(
        _ rings: [[GeoShape.GeoCoordinate]],
        resolution: Int?
    ) throws -> String {
        guard let boundaryRing = rings.first, !boundaryRing.isEmpty else {
            throw SwiftyH3Error.invalidInput
        }
        let boundary: H3Loop = boundaryRing.map { coordinate in
            H3LatLng(latitudeDegs: coordinate.lat, longitudeDegs: coordinate.lon)
        }

        let holes: [H3Loop] = rings.dropFirst().map { holeRing in
            holeRing.map { coordinate in
                H3LatLng(latitudeDegs: coordinate.lat, longitudeDegs: coordinate.lon)
            }
        }

        let polygon = H3Polygon(boundary, holes: holes)
        let h3Resolution = H3Cell.Resolution(rawValue: Int32(resolution ?? 8)) ?? .res8
        let cells = try polygon.cells(at: h3Resolution)
        let hashes = cells.map(\.description).sorted()
        //print(hashes)
        return hashes.joined(separator: ",")
    }

    private static func normalizeMessageID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private extension ArcusEvent {
    static func status(now: Date, messageType: NWSAlertMessageType, endsAt: Date?) -> EventStatus {
        if messageType == .cancel {
            return .issuedInError
        }

        guard let endsAt else { return .active }
        return endsAt <= now ? .ended : .active
    }
}

private extension EventKind {
    static func fromNwsEventName(_ eventName: String?) -> EventKind? {
        switch eventName?.normalizedLowercased {
        case "tornado warning":
            return .torWarning
        case "severe thunderstorm warning":
            return .svrTstormWarning
        case "flash flood warning":
            return .ffWarning
        case "tornado watch":
            return .torWatch
        case "severe thunderstorm watch":
            return .svrTstormWatch
        case "winter storm warning":
            return .winterStormWarning
        case "extreme fire danger":
            return .extremeFireDanger
        case "fire warning":
            return .fireWarning
        case "fire weather watch":
            return .fireWeatherWatch
        case "red flag warning":
            return .redFlagWarning
        default: // If it isn't defined here, we aren't supporting it yet.
            return nil
        }
    }
}

private extension EventSeverity {
    static func fromNws(_ raw: String?) -> EventSeverity {
        switch raw?.normalizedLowercased {
        case "extreme":
            return .extreme
        case "severe":
            return .severe
        case "moderate":
            return .moderate
        case "minor":
            return .moderate
        default:
            return .unknown
        }
    }
}

private extension EventUrgency {
    static func fromNws(_ raw: String?) -> EventUrgency {
        switch raw?.normalizedLowercased {
        case "immediate":
            return .immediate
        case "expected":
            return .expected
        case "future":
            return .future
        case "past":
            return .past
        default:
            return .unknown
        }
    }
}

private extension EventCertainty {
    static func fromNws(_ raw: String?) -> EventCertainty {
        switch raw?.normalizedLowercased {
        case "observed":
            return .observed
        case "likely":
            return .likely
        case "possible":
            return .possible
        case "unlikely":
            return .unlikely
        default:
            return .unknown
        }
    }
}

private extension NWSAlertMessageType {
    static func fromNws(_ raw: String?) -> NWSAlertMessageType {
        switch raw?.normalizedLowercased {
        case "alert":
            return .alert
        case "update":
            return .update
        case "cancel":
            return .cancel
        default:
            return .unknown
        }
    }
}

//private extension Array where Element: Hashable {
//    func uniquedPreservingOrder() -> [Element] {
//        var seen: Set<Element> = []
//        var result: [Element] = []
//        result.reserveCapacity(count)
//
//        for value in self where seen.insert(value).inserted {
//            result.append(value)
//        }
//
//        return result
//    }
//}
//
private extension NWSGeometryDTO {
    func toGeoShape() -> GeoShape? {
        switch type.normalizedLowercased {
        case "point":
            guard let point = coordinates.toGeoCoordinate() else { return nil }
            return .point(lon: point.lon, lat: point.lat)
        case "polygon":
            guard let rings = coordinates.toPolygon() else { return nil }
            return .polygon(rings: rings)
        case "multipolygon":
            guard let polygons = coordinates.toMultiPolygon() else { return nil }
            return .multiPolygon(polygons: polygons)
        default:
            return nil
        }
    }
}

private extension NWSCoordinatesDTO {
    var number: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var array: [NWSCoordinatesDTO]? {
        guard case .array(let values) = self else { return nil }
        return values
    }

    func toGeoCoordinate() -> GeoShape.GeoCoordinate? {
        guard let values = array,
              values.count >= 2,
              let lon = values[0].number,
              let lat = values[1].number else {
            return nil
        }

        return .init(lon: lon, lat: lat)
    }

    func toRing() -> [GeoShape.GeoCoordinate]? {
        guard let values = array else { return nil }
        let ring = values.compactMap { $0.toGeoCoordinate() }
        return ring.isEmpty ? nil : ring
    }

    func toPolygon() -> [[GeoShape.GeoCoordinate]]? {
        guard let values = array else { return nil }
        let rings = values.compactMap { $0.toRing() }
        return rings.isEmpty ? nil : rings
    }

    func toMultiPolygon() -> [[[GeoShape.GeoCoordinate]]]? {
        guard let values = array else { return nil }
        let polygons = values.compactMap { $0.toPolygon() }
        return polygons.isEmpty ? nil : polygons
    }
}
