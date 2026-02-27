
//public extension ArcusEventModel {

//    private static func encodeGeometry(_ geometry: GeoShape?) throws -> String? {
//        guard let geometry else { return nil }
//        let data = try JSONEncoder().encode(geometry)
//        return String(decoding: data, as: UTF8.self)
//    }
//

//

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
