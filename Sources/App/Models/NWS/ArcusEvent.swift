import Foundation

// MARK: - Canonical Model

public enum EventSource: String, Codable, Sendable {
    case nws
    case spc
}

public enum EventKind: String, Codable, Sendable {
    // NWS
    case torWarning
    case svrWarning
    case ffWarning
    case torWatch
    case svrWatch
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
}

public enum EventSeverity: String, Codable, Sendable {
    // Normalized severity buckets owned by Arcus.
    case info
    case advisory
    case watch
    case warning
    case emergency
}

public enum EventUrgency: String, Codable, Sendable {
    case immediate
    case expected
    case future
    case past
    case unknown
}

public enum EventCertainty: String, Codable, Sendable {
    case observed
    case likely
    case possible
    case unlikely
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
    public let eventKey: String      // "nws:<feature.id>" OR "spc:md:<id>"
    public let source: EventSource
    public let kind: EventKind
    public let sourceURL: String

    // Lifecycle
    public let status: EventStatus
    public let revision: Int

    // Timing
    public let issuedAt: Date?
    public let effectiveAt: Date?
    public let expiresAt: Date?

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
        eventKey: String,
        source: EventSource,
        kind: EventKind,
        sourceURL: String,
        status: EventStatus,
        revision: Int,
        issuedAt: Date?,
        effectiveAt: Date?,
        expiresAt: Date?,
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
        self.eventKey = eventKey
        self.source = source
        self.kind = kind
        self.sourceURL = sourceURL
        self.status = status
        self.revision = revision
        self.issuedAt = issuedAt
        self.effectiveAt = effectiveAt
        self.expiresAt = expiresAt
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

/// Ingest payload that preserves upstream linkage metadata needed for revision chaining.
public struct ArcusIngestEvent: Sendable, Equatable {
    public let event: ArcusEvent
    public let referenceSourceURLs: [String]

    public init(event: ArcusEvent, referenceSourceURLs: [String]) {
        self.event = event
        self.referenceSourceURLs = referenceSourceURLs
    }
}

/// Revision record for idempotency + dedupe persistence.
/// Intended unique constraint: (eventKey, revisionHash).
public struct EventRevision: Codable, Sendable, Equatable {
    public let eventKey: String
    public let revision: Int
    public let revisionHash: String
    public let createdAt: Date
    public let changeSummary: String?

    public init(
        eventKey: String,
        revision: Int,
        revisionHash: String,
        createdAt: Date = Date(),
        changeSummary: String? = nil
    ) {
        self.eventKey = eventKey
        self.revision = revision
        self.revisionHash = revisionHash
        self.createdAt = createdAt
        self.changeSummary = changeSummary
    }
}

// MARK: - NWS -> Canonical Mapper

public extension NwsEventDTO {
    func toArcusIngestEvents(
        now: Date = .now,
        revision: Int = 1,
        h3Resolution: Int? = 8,
        rawRef: String? = nil
    ) -> [ArcusIngestEvent] {
        (features ?? []).compactMap {
            $0.toArcusIngestEvent(
                now: now,
                revision: revision,
                h3Resolution: h3Resolution,
                rawRef: rawRef
            )
        }
    }

    func toArcusEvents(
        now: Date = .now,
        revision: Int = 1,
        h3Resolution: Int? = 8,
        rawRef: String? = nil
    ) -> [ArcusEvent] {
        toArcusIngestEvents(
            now: now,
            revision: revision,
            h3Resolution: h3Resolution,
            rawRef: rawRef
        ).map(\.event)
    }
}

public extension NwsEventFeatureDTO {
    func toArcusIngestEvent(
        now: Date = .now,
        revision: Int = 1,
        h3Resolution: Int? = 8,
        rawRef: String? = nil
    ) -> ArcusIngestEvent? {
        guard let event = toArcusEvent(
            now: now,
            revision: revision,
            h3Resolution: h3Resolution,
            rawRef: rawRef
        ) else {
            return nil
        }

        let referenceSourceURLs = properties.references?
            .map(\.id)
            .filter { !$0.isEmpty } ?? []

        return ArcusIngestEvent(event: event, referenceSourceURLs: referenceSourceURLs)
    }

    func toArcusEvent(
        now: Date = .now,
        revision: Int = 1,
        h3Resolution: Int? = 8,
        rawRef: String? = nil
    ) -> ArcusEvent? {
        guard let kind = EventKind.fromNwsEventName(properties.event) else {
            return nil
        }

        let expiresAt = properties.ends ?? properties.expires

        return ArcusEvent(
            eventKey: "nws:\(id)",
            source: .nws,
            kind: kind,
            sourceURL: properties.id,
            status: ArcusEvent.status(now: now, expiresAt: expiresAt),
            revision: revision,
            issuedAt: properties.sent,
            effectiveAt: properties.effective ?? properties.onset ?? properties.sent,
            expiresAt: expiresAt,
            severity: ArcusEvent.severity(for: kind, nwsSeverity: properties.severity),
            urgency: EventUrgency.fromNws(properties.urgency),
            certainty: EventCertainty.fromNws(properties.certainty),
            geometry: geometry?.toGeoShape(),
            ugcCodes: properties.geocode?.ugc ?? [],
            h3Resolution: h3Resolution,
            h3CoverHash: nil,
            title: properties.headline ?? properties.event,
            areaDesc: properties.areaDesc,
            rawRef: rawRef
        )
    }
}

private extension ArcusEvent {
    static func status(now: Date, expiresAt: Date?) -> EventStatus {
        guard let expiresAt else { return .active }
        return expiresAt <= now ? .ended : .active
    }

    static func severity(for kind: EventKind, nwsSeverity: String?) -> EventSeverity {
        switch nwsSeverity?.normalizedLowercased {
        case "extreme":
            return .emergency
        case "severe":
            return .warning
        case "moderate":
            return kind.isWatch ? .watch : .advisory
        case "minor":
            return .advisory
        default:
            return kind.defaultSeverity
        }
    }
}

private extension EventKind {
    static func fromNwsEventName(_ eventName: String?) -> EventKind? {
        switch eventName?.normalizedLowercased {
        case "tornado warning":
            return .torWarning
        case "severe thunderstorm warning":
            return .svrWarning
        case "flash flood warning":
            return .ffWarning
        case "tornado watch":
            return .torWatch
        case "severe thunderstorm watch":
            return .svrWatch
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

    var isWatch: Bool {
        switch self {
        case .torWatch, .svrWatch:
            return true
        default:
            return false
        }
    }

    var defaultSeverity: EventSeverity {
        isWatch ? .watch : .warning
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

private extension String {
    var normalizedLowercased: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
