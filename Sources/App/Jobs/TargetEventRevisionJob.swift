import Queues
import Vapor

public struct TargetEventRevisionPayload: Codable, Sendable {
    public let eventKey: String
    public let revision: Int

    public init(eventKey: String, revision: Int) {
        self.eventKey = eventKey
        self.revision = revision
    }
}

public struct TargetEventRevisionJob: AsyncJob {
    public typealias Payload = TargetEventRevisionPayload

    public init() {}

    public func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
        context.logger.info(
            "TargetEventRevisionJob dequeued.",
            metadata: [
                "eventKey": .string(payload.eventKey),
                "revision": .stringConvertible(payload.revision)
            ]
        )
    }

    public func error(_ context: QueueContext, _ error: any Error, _ payload: Payload) async throws {
        context.logger.error(
            "TargetEventRevisionJob failed.",
            metadata: [
                "eventKey": .string(payload.eventKey),
                "revision": .stringConvertible(payload.revision),
                "error": .string(String(reflecting: error))
            ]
        )
    }
}
