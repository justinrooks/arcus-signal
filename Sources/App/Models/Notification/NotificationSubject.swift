import Foundation

/// Delivery identity only; canonical NWS and SPC persistence remain separate.
public struct NotificationSubject: Equatable, Sendable {
    // Fixed whitespace vocabulary shared with the SQL checks, independent of DB locale.
    static let identityWhitespace = "\t\n\u{000B}\u{000C}\r \u{0085}\u{00A0}\u{1680}"
        + "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{200B}"
        + "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}"

    public struct Kind: RawRepresentable, Equatable, Codable, Sendable {
        public let rawValue: String

        public init?(rawValue: String) {
            guard !rawValue.trimmingCharacters(in: CharacterSet(charactersIn: NotificationSubject.identityWhitespace)).isEmpty else { return nil }
            self.rawValue = rawValue
        }

        private init(known: String) { rawValue = known }
        public static let nws = Self(known: "nws")
        public static let spcMeso = Self(known: "spc-meso")

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let kind = Self(rawValue: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Notification kind must be nonblank")
            }
            self = kind
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
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
