import Fluent
import Foundation

public enum IngestSweepRunStatus: String, Codable, Sendable {
    case succeeded
    case failed
}

public final class IngestSweepRunModel: Model, @unchecked Sendable {
    public static let schema = "ingest_sweep_runs"

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "source")
    public var source: String

    @OptionalField(key: "fixture_name")
    public var fixtureName: String?

    @OptionalField(key: "run_label")
    public var runLabel: String?

    @Field(key: "status")
    public var status: String

    @Field(key: "started_at")
    public var startedAt: Date

    @Field(key: "completed_at")
    public var completedAt: Date

    @OptionalField(key: "event_count")
    public var eventCount: Int?

    @OptionalField(key: "new_series_count")
    public var newSeriesCount: Int?

    @OptionalField(key: "new_revision_count")
    public var newRevisionCount: Int?

    @OptionalField(key: "target_outbox_queued_count")
    public var targetOutboxQueuedCount: Int?

    @OptionalField(key: "notification_outbox_queued_count")
    public var notificationOutboxQueuedCount: Int?

    @OptionalField(key: "error_message")
    public var errorMessage: String?

    public init() {}

    public init(
        id: UUID? = nil,
        source: String,
        fixtureName: String? = nil,
        runLabel: String? = nil,
        status: IngestSweepRunStatus,
        startedAt: Date,
        completedAt: Date,
        eventCount: Int? = nil,
        newSeriesCount: Int? = nil,
        newRevisionCount: Int? = nil,
        targetOutboxQueuedCount: Int? = nil,
        notificationOutboxQueuedCount: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.source = source
        self.fixtureName = fixtureName
        self.runLabel = runLabel
        self.status = status.rawValue
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.eventCount = eventCount
        self.newSeriesCount = newSeriesCount
        self.newRevisionCount = newRevisionCount
        self.targetOutboxQueuedCount = targetOutboxQueuedCount
        self.notificationOutboxQueuedCount = notificationOutboxQueuedCount
        self.errorMessage = errorMessage
    }
}
