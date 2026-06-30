import Foundation
import Vapor

extension Application {
    var arcusDebugEndpointsEnabled: Bool {
        Self.arcusDebugEndpointsEnabled(from: ProcessInfo.processInfo.environment)
    }

    static func arcusDebugEndpointsEnabled(from environment: [String: String]) -> Bool {
        guard let rawValue = environment["ARCUS_DEBUG_ENDPOINTS_ENABLED"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !rawValue.isEmpty else {
            return false
        }

        return rawValue == "true"
    }
}
