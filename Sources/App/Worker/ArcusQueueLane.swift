import Queues

// Available queues for the server to monitor with workers.
public enum ArcusQueueLane: String, CaseIterable, Sendable {
    case ingest
    case target
    case send

    public var queueName: QueueName {
        .init(string: rawValue)
    }
}
