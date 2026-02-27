//import Fluent
//import Foundation
//import Crypto
//
//public enum ArcusEventModelError: Error, Sendable {
//    case invalidEnum(field: String, value: String)
//    case invalidGeometryJSON
//}
//
//#warning("DEPRECATED")
//public final class ArcusEventModel: Model, @unchecked Sendable {
//    public static let schema = "arcus_events"
//
//    @ID(key: .id)
//    public var id: UUID?
//
//    @Field(key: "event_key")
//    public var eventKey: String
//
//    @Field(key: "source")
//    public var source: String
//
//    @Field(key: "kind")
//    public var kind: String
//
//    @Field(key: "source_url")
//    public var sourceURL: String
//
//    @Field(key: "status")
//    public var status: String
//
//    @Field(key: "revision")
//    public var revision: Int
//
//    @OptionalField(key: "issued_at")
//    public var issuedAt: Date?
//
//    @OptionalField(key: "effective_at")
//    public var effectiveAt: Date?
//
//    @OptionalField(key: "expires_at")
//    public var expiresAt: Date?
//
//    @Field(key: "severity")
//    public var severity: String
//
//    @Field(key: "urgency")
//    public var urgency: String
//
//    @Field(key: "certainty")
//    public var certainty: String
//
//    @OptionalField(key: "geometry_json")
//    public var geometryJSON: String?
//
//    @Field(key: "ugc_codes")
//    public var ugcCodes: [String]
//
//    @OptionalField(key: "h3_resolution")
//    public var h3Resolution: Int?
//
//    @OptionalField(key: "h3_cover_hash")
//    public var h3CoverHash: String?
//
//    @OptionalField(key: "title")
//    public var title: String?
//
//    @OptionalField(key: "area_desc")
//    public var areaDesc: String?
//
//    @OptionalField(key: "raw_ref")
//    public var rawRef: String?
//
//    @Field(key: "content_hash")
//    public var contentHash: String
//
//    @Field(key: "is_expired")
//    public var isExpired: Bool
//
//    @Timestamp(key: "created_at", on: .create)
//    public var createdAt: Date?
//
//    @Timestamp(key: "updated_at", on: .update)
//    public var updatedAt: Date?
//
//    public init() {}
//
//    public init(
//        id: UUID? = nil,
//        eventKey: String,
//        source: String,
//        kind: String,
//        sourceURL: String,
//        status: String,
//        revision: Int,
//        issuedAt: Date?,
//        effectiveAt: Date?,
//        expiresAt: Date?,
//        severity: String,
//        urgency: String,
//        certainty: String,
//        geometryJSON: String?,
//        ugcCodes: [String],
//        h3Resolution: Int?,
//        h3CoverHash: String?,
//        title: String?,
//        areaDesc: String?,
//        rawRef: String?,
//        contentHash: String,
//        isExpired: Bool = false
//    ) {
//        self.id = id
//        self.eventKey = eventKey
//        self.source = source
//        self.kind = kind
//        self.sourceURL = sourceURL
//        self.status = status
//        self.revision = revision
//        self.issuedAt = issuedAt
//        self.effectiveAt = effectiveAt
//        self.expiresAt = expiresAt
//        self.severity = severity
//        self.urgency = urgency
//        self.certainty = certainty
//        self.geometryJSON = geometryJSON
//        self.ugcCodes = ugcCodes
//        self.h3Resolution = h3Resolution
//        self.h3CoverHash = h3CoverHash
//        self.title = title
//        self.areaDesc = areaDesc
//        self.rawRef = rawRef
//        self.contentHash = contentHash
//        self.isExpired = isExpired
//    }
//}
//
//public extension ArcusEventModel {
//    convenience init(from event: ArcusEvent, asOf: Date = .now) throws {
//        let geometryJSON = try Self.encodeGeometry(event.geometry)
//        let isExpired = Self.computeIsExpired(from: event, asOf: asOf)
//        let contentHash = try Self.computeContentHash(from: event)
//
//        self.init(
//            eventKey: event.id,
//            source: event.source.rawValue,
//            kind: event.kind.rawValue,
//            sourceURL: event.sourceURL,
//            status: event.status.rawValue,
//            revision: 1,
//            issuedAt: nil,
//            effectiveAt: event.effectiveAt,
//            expiresAt: event.expiresAt,
//            severity: event.severity.rawValue,
//            urgency: event.urgency.rawValue,
//            certainty: event.certainty.rawValue,
//            geometryJSON: geometryJSON,
//            ugcCodes: event.ugcCodes,
//            h3Resolution: event.h3Resolution,
//            h3CoverHash: event.h3CoverHash,
//            title: event.title,
//            areaDesc: event.areaDesc,
//            rawRef: event.rawRef,
//            contentHash: contentHash,
//            isExpired: isExpired
//        )
//    }
//
//    func asDomain() throws -> ArcusEvent {
//        guard let source = EventSource(rawValue: source) else {
//            throw ArcusEventModelError.invalidEnum(field: "source", value: source)
//        }
//
//        guard let kind = EventKind(rawValue: kind) else {
//            throw ArcusEventModelError.invalidEnum(field: "kind", value: kind)
//        }
//
//        guard let status = EventStatus(rawValue: status) else {
//            throw ArcusEventModelError.invalidEnum(field: "status", value: status)
//        }
//
//        guard let severity = EventSeverity(rawValue: severity) else {
//            throw ArcusEventModelError.invalidEnum(field: "severity", value: severity)
//        }
//
//        guard let urgency = EventUrgency(rawValue: urgency) else {
//            throw ArcusEventModelError.invalidEnum(field: "urgency", value: urgency)
//        }
//
//        guard let certainty = EventCertainty(rawValue: certainty) else {
//            throw ArcusEventModelError.invalidEnum(field: "certainty", value: certainty)
//        }
//
//        return ArcusEvent(
//            eventKey: eventKey,
//            source: source,
//            kind: kind,
//            sourceURL: sourceURL,
//            status: status,
//            revision: revision,
//            issuedAt: issuedAt,
//            effectiveAt: effectiveAt,
//            expiresAt: expiresAt,
//            severity: severity,
//            urgency: urgency,
//            certainty: certainty,
//            geometry: try decodeGeometry(geometryJSON),
//            ugcCodes: ugcCodes,
//            h3Resolution: h3Resolution,
//            h3CoverHash: h3CoverHash,
//            title: title,
//            areaDesc: areaDesc,
//            rawRef: rawRef
//        )
//    }
//
//    private static func encodeGeometry(_ geometry: GeoShape?) throws -> String? {
//        guard let geometry else { return nil }
//        let data = try JSONEncoder().encode(geometry)
//        return String(decoding: data, as: UTF8.self)
//    }
//
//    private static var hashEncoder: JSONEncoder {
//        let encoder = JSONEncoder()
//        encoder.dateEncodingStrategy = .iso8601
//        encoder.outputFormatting = [.sortedKeys]
//        return encoder
//    }
//
//    private static func computeContentHash(from event: ArcusEvent) throws -> String {
//        let fingerprint = ArcusEventContentFingerprint(
//            kind: event.kind,
//            status: event.status,
//            effectiveAt: event.effectiveAt,
//            expiresAt: event.expiresAt,
//            severity: event.severity,
//            urgency: event.urgency,
//            certainty: event.certainty,
//            geometry: event.geometry,
//            ugcCodes: event.ugcCodes,
//            title: event.title,
//            areaDesc: event.areaDesc
//        )
//
//        let data = try hashEncoder.encode(fingerprint)
//        let digest = SHA256.hash(data: data)
//        return digest.map { String(format: "%02x", $0) }.joined()
//    }
//
//    private static func computeIsExpired(from event: ArcusEvent, asOf: Date) -> Bool {
//        if let expiresAt = event.expiresAt {
//            return expiresAt <= asOf
//        }
//
//        return event.status == .ended
//    }
//
//    private func decodeGeometry(_ geometryJSON: String?) throws -> GeoShape? {
//        guard let geometryJSON else { return nil }
//        guard let data = geometryJSON.data(using: .utf8) else {
//            throw ArcusEventModelError.invalidGeometryJSON
//        }
//
//        return try JSONDecoder().decode(GeoShape.self, from: data)
//    }
//}
//
//private struct ArcusEventContentFingerprint: Codable, Sendable {
//    let kind: EventKind
//    let status: EventStatus
//    let effectiveAt: Date?
//    let expiresAt: Date?
//    let severity: EventSeverity
//    let urgency: EventUrgency
//    let certainty: EventCertainty
//    let geometry: GeoShape?
//    let ugcCodes: [String]
//    let title: String?
//    let areaDesc: String?
//}
