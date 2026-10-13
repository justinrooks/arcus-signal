import Foundation

struct AirQualityConfiguration: Sendable, Equatable {
    static let defaultCacheLifetime: TimeInterval = 45 * 60

    let airNowAPIKey: String?
    let cacheLifetime: TimeInterval

    static func resolved(from environment: [String: String] = ProcessInfo.processInfo.environment) -> AirQualityConfiguration {
        AirQualityConfiguration(
            airNowAPIKey: environment["AIRNOW_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            cacheLifetime: defaultCacheLifetime
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
