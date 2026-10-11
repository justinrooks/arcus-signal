import ArcusCore
import Fluent
import Foundation

/// Canonical SPC product, independent of NWS series and revisions.
final class SPCMesoModel: Model, @unchecked Sendable {
    static let schema = "spc_mesos"

    @ID(key: .id) var id: UUID?
    @Field(key: "product_key") var productKey: String
    @Field(key: "issue_year") var issueYear: Int
    @Field(key: "md_number") var number: Int
    @Field(key: "issued") var issued: Date
    @Field(key: "valid_start") var validStart: Date
    @Field(key: "valid_end") var validEnd: Date
    @Field(key: "title") var title: String
    @Field(key: "source_url") var sourceURL: String
    @Field(key: "areas_affected") var areasAffected: String
    @Field(key: "summary") var summary: String
    @OptionalField(key: "concerning") var concerning: String?
    @OptionalField(key: "watch_probability") var watchProbability: Double?
    @Field(key: "watch_probability_text") var watchProbabilityText: String
    @OptionalField(key: "peak_wind_mph") var peakWindMPH: Int?
    @OptionalField(key: "hail_range_inches") var hailRangeInches: Double?
    @OptionalField(key: "tornado_strength") var tornadoStrength: String?
    @Field(key: "content_fingerprint") var contentFingerprint: String
    @Field(key: "first_seen") var firstSeen: Date
    @Field(key: "last_seen") var lastSeen: Date

    @OptionalChild(for: \.$meso) var geolocation: SPCMesoGeolocationModel?

    init() {}

    init(product: MesoscaleDiscussionPayload, contentFingerprint: String, seenAt: Date) {
        self.productKey = product.productID
        self.issueYear = product.issueYear
        self.number = product.number
        self.issued = product.issued
        self.validStart = product.validStart
        self.validEnd = product.validEnd
        self.title = product.title
        self.sourceURL = product.sourceURL.absoluteString
        self.areasAffected = product.areasAffected
        self.summary = product.summary
        self.concerning = product.concerning
        self.watchProbability = product.watchProbability
        self.watchProbabilityText = product.watchProbabilityText
        self.peakWindMPH = product.threats?.peakWindMPH
        self.hailRangeInches = product.threats?.hailRangeInches
        self.tornadoStrength = product.threats?.tornadoStrength
        self.contentFingerprint = contentFingerprint
        self.firstSeen = seenAt
        self.lastSeen = seenAt
    }
}
