import Foundation

enum StormSetupRulesVersion: String, Sendable, Codable, Equatable {
    case tornadoIngredientV1 = "tornado-ingredient-v1"
}

extension StormSetupRulesVersion {
    static let current: Self = .tornadoIngredientV1
}
