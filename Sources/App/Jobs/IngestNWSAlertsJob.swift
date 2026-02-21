import Queues
import Vapor

enum DecoderFactory {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
    
    static var base: JSONDecoder {
        JSONDecoder()
    }
}


public struct IngestNWSAlertsPayload: Codable, Sendable {
    public init() {}
}

public struct IngestNWSAlertsJob: AsyncJob {
    public typealias Payload = IngestNWSAlertsPayload
    let client: any NwsClient

    public init() {
        let responseObserver = LastGlobalSuccessHTTPObserver()
        let httpClient = URLSessionHTTPClient(observer: responseObserver)
        self.client = NwsHttpClient(http: httpClient)
    }

    public func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
        context.logger.info("IngestNWSAlertsJob started.")
        let decoder = DecoderFactory.iso8601

        do {
            try await context.application.nwsIngestService.ingestOnce(logger: context.logger)
            
            let data = try await client.fetchActiveAlertsJsonData()
            let decoded = try decoder.decode(NwsEventDTO.self, from: data)
            let arcusEvents = decoded.toArcusEvents()
            context.logger.info(
                "Mapped NWS alert payload into canonical events.",
                metadata: [
                    "nwsFeatures": .string("\(decoded.features?.count ?? 0)"),
                    "arcusEvents": .string("\(arcusEvents.count)")
                ]
            )

            context.logger.info("IngestNWSAlertsJob finished.")
        } catch {
            context.logger.report(error: error)
            throw error
        }
    }

    public func error(_ context: QueueContext, _ error: any Error, _ payload: Payload) async throws {
        context.logger.error(
            "IngestNWSAlertsJob failed.",
            metadata: ["error": .string(String(describing: error))]
        )
    }
}
