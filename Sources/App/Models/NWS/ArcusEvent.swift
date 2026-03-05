import Foundation
import Crypto

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

public enum EventState: String, Codable, Sendable {
    case active
    case expired
    case cancelled_in_error
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
    public let vtec: VTECDescriptor? // Maybe remove, we aren't going to persist. may be used for calculation
    public let messageType: NWSAlertMessageType
//    public let contentFingerprint: String

    // Lifecycle
    public let state: EventState
    public let references: [String] // list of id's this message supersedes

    // Timing
    public let sent: Date? // time of the origination of message itself
    public let effective: Date? // goes into effect
    public let onset: Date? // beginning of the event in message
    public let expires: Date? // alert message expiration
    public let ends: Date?
    public let lastSeenActive: Date

    // Severity inputs (normalized)
    public let severity: EventSeverity
    public let urgency: EventUrgency
    public let certainty: EventCertainty

    // Targeting
    public let geometry: GeoShape?
    public let ugcCodes: [String]

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
        state: EventState,
        references: [String] = [],
        sent: Date?,
        effective: Date?,
        onset: Date?,
        expires: Date?,
        ends: Date?,
        lastSeenActive: Date,
        severity: EventSeverity,
        urgency: EventUrgency,
        certainty: EventCertainty,
        geometry: GeoShape?,
        ugcCodes: [String],
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
        self.state = state
        self.references = references
        self.sent = sent
        self.effective = effective
        self.onset = onset
        self.expires = expires
        self.ends = ends
        self.lastSeenActive = lastSeenActive
        self.severity = severity
        self.urgency = urgency
        self.certainty = certainty
        self.geometry = geometry
        self.ugcCodes = ugcCodes
        self.title = title
        self.areaDesc = areaDesc
        self.rawRef = rawRef
    }
}

// MARK: - NWS -> Canonical Mapper

public extension NwsEventDTO {
    func toArcusEvents(
        now: Date = .now,
        revision: Int = 1,
        rawRef: String? = nil
    ) -> [ArcusEvent] {
        (features ?? []).compactMap {
            $0.toArcusEvent(
                now: now,
                revision: revision,
                rawRef: rawRef
            )
        }
    }
}

public extension NwsEventFeatureDTO {
    func toArcusEvent(
        now: Date = .now,
        revision: Int = 1,
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
        

        return .init(
            urn: messageID,
            source: .nws,
            kind: kind,
            sourceURL: id,
            vtec: vtecP ?? nil, // We are specifically only grabbing the first. Its a business decision, we can adjust later
            messageType: NWSAlertMessageType.fromNws(properties.messageType),
            state: ArcusEvent.status(now: now, messageType: messageType, endsAt: endsAt),
            references: refs ?? [],
            sent: properties.sent,
            effective: properties.effective,
            onset: properties.onset,
            expires: properties.expires,
            ends: endsAt,
            lastSeenActive: now,
            severity: EventSeverity.fromNws(properties.severity),
            urgency: EventUrgency.fromNws(properties.urgency),
            certainty: EventCertainty.fromNws(properties.certainty),
            geometry: geometry,
            ugcCodes: properties.geocode?.ugc ?? [],
            title: properties.headline ?? properties.event,
            areaDesc: properties.areaDesc,
            rawRef: rawRef
        )
    }

    private static func normalizeMessageID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private extension ArcusEvent {
    static func status(now: Date, messageType: NWSAlertMessageType, endsAt: Date?) -> EventState {
        if messageType == .cancel {
            return .cancelled_in_error
        }

        guard let endsAt else { return .active }
        return endsAt <= now ? .expired : .active
    }
}
    
extension ArcusEvent {
    func computeContentFingerprint() throws -> String {
        struct ArcusEventContentFingerprint: Codable, Sendable {
            let kind: EventKind
            let messageType: NWSAlertMessageType
            let sent: Date?
            let effective: Date?
            let onset: Date?
            let expires: Date?
            let ends: Date?
            let severity: EventSeverity
            let urgency: EventUrgency
            let certainty: EventCertainty
            let geometry: GeoShape?
            let ugcCodes: [String]
            let title: String?
            let areaDesc: String?
        }

        let fingerprint = ArcusEventContentFingerprint(
            kind: self.kind,
            messageType: self.messageType,
            sent: self.sent,
            effective: self.effective,
            onset: self.onset,
            expires: self.expires,
            ends: self.ends,
            severity: self.severity,
            urgency: self.urgency,
            certainty: self.certainty,
            geometry: self.geometry,
            ugcCodes: normalizedUGCCodes,
            title: normalizedText(self.title),
            areaDesc: normalizedText(self.areaDesc)
        )

        let data = try hashEncoder.encode(fingerprint)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    private var hashEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var normalizedUGCCodes: [String] {
        var normalized: [String] = []
        normalized.reserveCapacity(ugcCodes.count)

        for code in ugcCodes {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            normalized.append(trimmed.uppercased())
        }

        return Array(Set(normalized)).sorted()
    }

    private func normalizedText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
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
