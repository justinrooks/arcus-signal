import Foundation

// MARK: - Canonical Domain Model

public enum EventSource: String, Codable, Sendable {
    case nws
    case spc
}

public enum EventState: String, Codable, Sendable {
    case active
    case expired
    case ended
    case cancelled
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
    public let kind: String // event property in the message
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
    @available(*, deprecated, message: "Use event or headline instead")
    public let title: String?
    public let areaDesc: String?
   
    public let category: String?
    public let event: String?
    public let senderName: String?
    public let headline: String?
    public let description: String?
    public let instructions: String?
    public let response: String?
    
    public let status: String?

    // Raw payload reference
    public let rawRef: String?
    
    // CAP Params
    public let tornadoDetection: String?
    public let tornadoDamageThreat: String?
    public let maxWindGust: String?
    public let maxHailSize: String?
    public let windThreat: String?
    public let hailThreat: String?
    public let thunderstormDamageThreat: String?
    public let flashFloodDetection: String?
    public let flashFloodDamageThreat: String?

    public init(
        urn: String,
        source: EventSource,
        kind: String,
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
        rawRef: String?,
        category: String?,
        event: String?,
        senderName: String?,
        headline: String?,
        description: String?,
        instructions: String?,
        response: String?,
        status: String?,
        tornadoDetection: String?,
        tornadoDamageThreat: String?,
        maxWindGust: String?,
        maxHailSize: String?,
        windThreat: String?,
        hailThreat: String?,
        thunderstormDamageThreat: String?,
        flashFloodDetection: String?,
        flashFloodDamageThreat: String?
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
        self.category = category
        self.event = event
        self.senderName = senderName
        self.headline = headline
        self.description = description
        self.instructions = instructions
        self.response = response
        self.status = status
        self.tornadoDetection = tornadoDetection
        self.tornadoDamageThreat = tornadoDamageThreat
        self.maxWindGust = maxWindGust
        self.maxHailSize = maxHailSize
        self.windThreat = windThreat
        self.hailThreat = hailThreat
        self.thunderstormDamageThreat = thunderstormDamageThreat
        self.flashFloodDetection = flashFloodDetection
        self.flashFloodDamageThreat = flashFloodDamageThreat
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
        let messageID = Self.normalizeMessageID(properties.id) ?? Self.normalizeMessageID(id) ?? properties.id
        let endsAt = properties.ends
        let messageType = NWSAlertMessageType.fromNws(properties.messageType)
        let vtec = properties.parameters?.vtec?.first ?? ""
        let vtecP = vtec.parseVTEC()
        let refs = properties.references?.compactMap{ $0.identifier }
        let geometry = geometry?.toGeoShape()
        
        let tornadoDetectionValue = properties.parameters?.tornadoDetection?.first ?? ""
        let tornadoDamageThreatValue = properties.parameters?.tornadoDamageThreat?.first ?? ""
        let maxWindGustValue = properties.parameters?.maxWindGust?.first ?? ""
        let maxHailSizeValue = properties.parameters?.maxHailSize?.first ?? ""
        let windThreatValue = properties.parameters?.windThreat?.first ?? ""
        let hailThreatValue = properties.parameters?.hailThreat?.first ?? ""
        let thunderstormDamageThreatValue = properties.parameters?.thunderstormDamageThreat?.first ?? ""
        let flashFloodDetectionValue = properties.parameters?.flashFloodDetection?.first ?? ""
        let flashFloodDamageThreatValue = properties.parameters?.flashFloodDamageThreat?.first ?? ""
        

        return .init(
            urn: messageID,
            source: .nws,
            kind: properties.event ?? "Unknown",
            sourceURL: id,
            vtec: vtecP ?? nil, // We are specifically only grabbing the first. Its a business decision, we can adjust later
            messageType: NWSAlertMessageType.fromNws(properties.messageType),
            state: ArcusEvent.lifecycleState(
                now: now,
                messageType: messageType,
                expiresAt: properties.expires,
                endsAt: endsAt
            ),
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
            rawRef: rawRef,
            category: properties.category,
            event: properties.event,
            senderName: properties.senderName,
            headline: properties.headline,
            description: properties.description,
            instructions: properties.instruction,
            response: properties.response,
            status: properties.status,
            tornadoDetection: tornadoDetectionValue,
            tornadoDamageThreat: tornadoDamageThreatValue,
            maxWindGust: maxWindGustValue,
            maxHailSize: maxHailSizeValue,
            windThreat: windThreatValue,
            hailThreat: hailThreatValue,
            thunderstormDamageThreat: thunderstormDamageThreatValue,
            flashFloodDetection: flashFloodDetectionValue,
            flashFloodDamageThreat: flashFloodDamageThreatValue
        )
    }

    private static func normalizeMessageID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

extension ArcusEvent {
    static func lifecycleState(
        now: Date,
        messageType: NWSAlertMessageType,
        expiresAt: Date?,
        endsAt: Date?
    ) -> EventState {
        if messageType == .cancel {
            return .cancelled_in_error
        }

        let terminalAt = [expiresAt, endsAt].compactMap { $0 }.min()
        return terminalAt.map { $0 <= now ? .expired : .active } ?? .active
    }
}
    
extension ArcusEvent {
    func computeContentFingerprint() throws -> String {
        struct ArcusEventContentFingerprint: Codable, Sendable {
            let kind: String
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
            let category: String?
            let senderName: String?
            let headline: String?
            let description: String?
            let instructions: String?
            let response: String?
            let status: String?
            let tornadoDetection: String?
            let tornadoDamageThreat: String?
            let maxWindGust: String?
            let maxHailSize: String?
            let windThreat: String?
            let hailThreat: String?
            let thunderstormDamageThreat: String?
            let flashFloodDetection: String?
            let flashFloodDamageThreat: String?
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
            areaDesc: normalizedText(self.areaDesc),
            category: self.category,
            senderName: self.senderName,
            headline: self.headline,
            description: self.description,
            instructions: self.instructions,
            response: self.response,
            status: self.status,
            tornadoDetection: self.tornadoDetection,
            tornadoDamageThreat: self.tornadoDamageThreat,
            maxWindGust: self.maxWindGust,
            maxHailSize: self.maxHailSize,
            windThreat: self.windThreat,
            hailThreat: self.hailThreat,
            thunderstormDamageThreat: self.thunderstormDamageThreat,
            flashFloodDetection: self.flashFloodDetection,
            flashFloodDamageThreat: self.flashFloodDamageThreat
        )

        return try StableContentHasher.sha256Hex(of: fingerprint)
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
