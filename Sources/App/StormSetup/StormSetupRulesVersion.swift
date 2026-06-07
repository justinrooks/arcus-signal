import Foundation

enum StormSetupRulesVersion: String, Sendable, Codable, Equatable {
    case tornadoIngredientV1 = "tornado-ingredient-v1"
    case tornadoIngredientV2 = "tornado-ingredient-v2"
}

extension StormSetupRulesVersion {
    static let current: Self = .tornadoIngredientV1
}
