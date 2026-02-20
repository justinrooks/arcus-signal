import Logging
import Vapor

public protocol NWSIngestService: Sendable {
    func ingestOnce(logger: Logger) async throws
}

public struct StubNWSIngestService: NWSIngestService {
    public init() {}

    public func ingestOnce(logger: Logger) async throws {
        logger.info("Stub NWS ingest completed.")
    }
}

private struct NWSIngestServiceKey: StorageKey {
    typealias Value = any NWSIngestService
}

public extension Application {
    var nwsIngestService: any NWSIngestService {
        get {
            guard let service = storage[NWSIngestServiceKey.self] else {
                fatalError("NWSIngestService was accessed before being configured.")
            }
            return service
        }
        set {
            storage[NWSIngestServiceKey.self] = newValue
        }
    }
}
