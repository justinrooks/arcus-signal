import Fluent
import Foundation

public enum NotificationSendAttemptOutcome: String, Codable, Sendable {
    case delivered
    case noOp = "no_op"
    case failed
}

public enum NotificationSendNoOpReason: String, Codable, Sendable {
    case staleRevisionMismatch = "stale_revision_mismatch"
    case missingGeolocation = "missing_geolocation"
    case zeroCandidates = "zero_candidates"
    case allCandidatesPreviouslyClaimed = "all_candidates_previously_claimed"
}

public final class NotificationSendAttemptModel: Model, @unchecked Sendable {
    public static let schema = "notification_send_attempts"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "series_id")
    public var series: ArcusSeriesModel

    @Field(key: "revision_urn")
    public var revisionUrn: String

    @Field(key: "mode")
    public var mode: String

    @Field(key: "reason")
    public var reason: String

    @Field(key: "outcome")
    public var outcome: String

    @OptionalField(key: "no_op_reason")
    public var noOpReason: String?

    @Field(key: "candidate_resolution_reached")
    public var candidateResolutionReached: Bool

    @Field(key: "candidate_count")
    public var candidateCount: Int

    @Field(key: "claimed_count")
    public var claimedCount: Int

    @Field(key: "sent_count")
    public var sentCount: Int

    @Field(key: "failed_count")
    public var failedCount: Int

    @Field(key: "attempted_at")
    public var attemptedAt: Date

    public init() {}

    public init(
        id: UUID? = nil,
        seriesID: UUID,
        revisionUrn: String,
        mode: NotificationTargetMode,
        reason: NotificationReason,
        outcome: NotificationSendAttemptOutcome,
        noOpReason: NotificationSendNoOpReason? = nil,
        candidateResolutionReached: Bool,
        candidateCount: Int,
        claimedCount: Int,
        sentCount: Int,
        failedCount: Int,
        attemptedAt: Date = .now
    ) {
        self.id = id
        self.$series.id = seriesID
        self.revisionUrn = revisionUrn
        self.mode = mode.rawValue
        self.reason = reason.rawValue
        self.outcome = outcome.rawValue
        self.noOpReason = noOpReason?.rawValue
        self.candidateResolutionReached = candidateResolutionReached
        self.candidateCount = candidateCount
        self.claimedCount = claimedCount
        self.sentCount = sentCount
        self.failedCount = failedCount
        self.attemptedAt = attemptedAt
    }
}
