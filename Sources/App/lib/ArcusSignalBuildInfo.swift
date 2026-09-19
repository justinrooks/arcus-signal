import Foundation

struct ArcusSignalBuildInfo: Sendable, Equatable {
    let version: String
    let revision: String?

    static func resolved(from environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let version = nonEmpty(environment["ARCUS_SIGNAL_VERSION"])
        let revision = nonEmpty(environment["ARCUS_SIGNAL_REVISION"])

        return .init(
            version: version ?? "development",
            revision: revision.flatMap { $0 == "unknown" ? nil : $0 }
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
