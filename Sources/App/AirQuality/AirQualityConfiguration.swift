import Foundation

struct AirQualityConfiguration: Sendable, Equatable {
    let airNowAPIKey: String?
    let cacheLifetime: TimeInterval

    static func resolved(from environment: [String: String] = ProcessInfo.processInfo.environment) -> AirQualityConfiguration {
        AirQualityConfiguration(
            airNowAPIKey: environment["AIRNOW_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            cacheLifetime: 45 * 60
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
