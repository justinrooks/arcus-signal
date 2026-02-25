import Queues

public enum ArcusQueueLane: String, CaseIterable, Sendable {
    case ingest
    case target
    case send

    public var queueName: QueueName {
        .init(string: rawValue)
    }
}
