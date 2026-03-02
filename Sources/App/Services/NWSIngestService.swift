import Foundation
import Logging
import Vapor

public protocol NWSIngestService: Sendable {
    func ingestOnce(on application: Application, logger: Logger) async throws -> [ArcusEvent]
}

public enum NWSIngestServiceError: Error, Sendable {
    case unconfigured
}

public struct DefaultNWSIngestService: NWSIngestService {
    public init() {}

    public func ingestOnce(on application: Application, logger: Logger) async throws -> [ArcusEvent] {
        let responseObserver = LastGlobalSuccessHTTPObserver()
        let httpClient = VaporApplicationHTTPClient(
            application: application,
            observer: responseObserver
        )
        let client = NwsHttpClient(http: httpClient)

        let data = try await client.fetchActiveAlertsJsonData()
        let decoded = try Self.iso8601Decoder.decode(NwsEventDTO.self, from: data)
        let arcusEvents = decoded.toArcusEvents()
        logger.info(
            "Mapped NWS alert payload into canonical events.",
            metadata: [
                "nwsFeatures": .string("\(decoded.features?.count ?? 0)"),
                    "arcusEvents": .string("\(arcusEvents.count)")
                ]
        )
        return arcusEvents
    }

    private static var iso8601Decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct StubNWSIngestService: NWSIngestService {
    public init() {}

    public func ingestOnce(on application: Application, logger: Logger) async throws -> [ArcusEvent] {
        logger.info("Stub NWS ingest completed.")
        return []
    }
}

private struct UnconfiguredNWSIngestService: NWSIngestService {
    func ingestOnce(on application: Application, logger: Logger) async throws -> [ArcusEvent] {
        logger.critical("NWSIngestService was accessed before being configured.")
        throw NWSIngestServiceError.unconfigured
    }
}

private struct NWSIngestServiceKey: StorageKey {
    typealias Value = any NWSIngestService
}

public extension Application {
    var nwsIngestService: any NWSIngestService {
        get {
            storage[NWSIngestServiceKey.self] ?? UnconfiguredNWSIngestService()
        }
        set {
            storage[NWSIngestServiceKey.self] = newValue
        }
    }
}
