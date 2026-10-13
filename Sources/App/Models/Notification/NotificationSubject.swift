import Foundation

/// Delivery identity only; canonical NWS and SPC persistence remain separate.
public struct NotificationSubject: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case nws
        case spcMeso = "spc-meso"
    }

    public let kind: Kind
    public let productID: String
    public let revisionID: String

    public init(kind: Kind, productID: String, revisionID: String) {
        self.kind = kind
        self.productID = productID
        self.revisionID = revisionID
    }

    public static func nws(seriesID: UUID, revisionUrn: String) -> Self {
        .init(kind: .nws, productID: seriesID.uuidString.lowercased(), revisionID: revisionUrn)
    }

    // Unchanged NWS SQL writers may omit the additive columns during cutover.
    static func resolve(kind: String?, productID: String?, revisionID: String?, seriesID: UUID?, revisionUrn: String) -> Self? {
        if let kind, let kind = Kind(rawValue: kind), let productID, let revisionID {
            return .init(kind: kind, productID: productID, revisionID: revisionID)
        }
        guard kind == nil, productID == nil, revisionID == nil, let seriesID else { return nil }
        return .nws(seriesID: seriesID, revisionUrn: revisionUrn)
    }
}
