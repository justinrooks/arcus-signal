import Foundation
import Vapor

struct IngredientFreshness: Content, Sendable {
    let sourceValidTime: Date?
    let modelRunTime: Date?
    let forecastHour: Int?
    let fetchedAt: Date
    let expiresAt: Date
    let isStale: Bool
    let isDegraded: Bool
}

extension IngredientFreshness {
    static func make(
        source: StormSetupSourceMetadata,
        fetchedAt: Date,
        staleAfter: TimeInterval = 90 * 60
    ) -> IngredientFreshness {
        let sourceReferenceTime = source.validTime ?? source.runTime ?? fetchedAt
        let expiresAt = sourceReferenceTime.addingTimeInterval(staleAfter)
        let isStale = fetchedAt >= expiresAt
        let isDegraded = isStale || source.validTime == nil || source.runTime == nil || source.forecastHour == nil

        return IngredientFreshness(
            sourceValidTime: source.validTime,
            modelRunTime: source.runTime,
            forecastHour: source.forecastHour,
            fetchedAt: fetchedAt,
            expiresAt: expiresAt,
            isStale: isStale,
            isDegraded: isDegraded
        )
    }
}
