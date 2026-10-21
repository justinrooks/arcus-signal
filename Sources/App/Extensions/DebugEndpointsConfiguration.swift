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

    var mesoNotificationTestEndpointConfiguration: MesoNotificationTestEndpointConfiguration? {
        MesoNotificationTestEndpointConfiguration(
            appEnvironment: environment,
            processEnvironment: ProcessInfo.processInfo.environment
        )
    }
}

struct MesoNotificationTestEndpointConfiguration: Sendable {
    let bearerSecret: String

    init?(appEnvironment: Environment, processEnvironment: [String: String]) {
        guard appEnvironment == .development,
              processEnvironment["ARCUS_MESO_NOTIFICATION_TEST_ENABLED"] == "true",
              let secret = processEnvironment["ARCUS_MESO_NOTIFICATION_TEST_BEARER_SECRET"],
              secret.utf8.count >= 32 else {
            return nil
        }
        self.bearerSecret = secret
    }
}
