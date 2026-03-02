import Fluent
import Foundation

public final class ArcusTargetDispatchOutboxModel: Model, @unchecked Sendable {
    public static let schema = "target_dispatch_outbox"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "revision_urn")
    public var revisionUrn: String

    @Parent(key: "series_id")
    public var series: ArcusSeriesModel

    @Field(key: "payload")
    public var payload: TargetEventRevisionPayload

    @Field(key: "attempt_count")
    public var attemptCount: Int

    @OptionalField(key: "last_error")
    public var lastError: String?

    @Field(key: "created")
    public var created: Date

    @OptionalField(key: "dispatched")
    public var dispatched: Date?

    public init() {}

    public init(
        id: UUID? = nil,
        revisionUrn: String,
        seriesId: UUID,
        payload: TargetEventRevisionPayload,
        attemptCount: Int = 0,
        lastError: String? = nil,
        created: Date = .now,
        dispatched: Date? = nil
    ) {
        self.id = id
        self.revisionUrn = revisionUrn
        self.$series.id = seriesId
        self.payload = payload
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.created = created
        self.dispatched = dispatched
    }
}
