import Foundation
import Vapor

enum AnvilIngredientEvidenceStatus: String, Content, Sendable, Equatable {
    case available
    case degraded
    case unavailable
}

struct AnvilIngredientEvidence: Content, Sendable, Equatable {
    let status: AnvilIngredientEvidenceStatus
    let reason: String?
    let scp: AnvilIngredientMetricEvidence?
    let stp: AnvilIngredientMetricEvidence?
    let ship: AnvilIngredientMetricEvidence?
    let diagnostics: AnvilIngredientDiagnostics

    init(response: AnvilAnalyzeProfileResponse) {
        self.init(response: response, additionalWarnings: [])
    }

    init(
        response: AnvilAnalyzeProfileResponse,
        additionalWarnings: [String]
    ) {
        let normalized = AnvilSurfaceProfileNormalizer().normalize(
            response: response,
            additionalWarnings: additionalWarnings
        )
        self = normalized
    }

    static func unavailable(reason: String) -> AnvilIngredientEvidence {
        AnvilIngredientEvidence(
            status: .unavailable,
            reason: reason,
            scp: nil,
            stp: nil,
            ship: nil,
            diagnostics: AnvilIngredientDiagnostics(
                hasEffectiveLayer: false,
                hasStormMotion: false,
                qualityProfileLevelCount: 0,
                warnings: []
            )
        )
    }

    init(
        status: AnvilIngredientEvidenceStatus,
        reason: String?,
        scp: AnvilIngredientMetricEvidence?,
        stp: AnvilIngredientMetricEvidence?,
        ship: AnvilIngredientMetricEvidence?,
        diagnostics: AnvilIngredientDiagnostics
    ) {
        self.status = status
        self.reason = reason
        self.scp = scp
        self.stp = stp
        self.ship = ship
        self.diagnostics = diagnostics
    }

    var supportCount: Int {
        [scp, stp, ship].compactMap { $0 }.count
    }

    var strongestSupport: IngredientSupport? {
        [scp?.support, stp?.support, ship?.support].compactMap { $0 }.max()
    }

    var isDegraded: Bool {
        status != .available || diagnostics.isDegraded || supportCount == 0
    }
}

struct AnvilIngredientMetricEvidence: Content, Sendable, Equatable {
    let support: IngredientSupport
}

struct AnvilIngredientDiagnostics: Content, Sendable, Equatable {
    let hasEffectiveLayer: Bool
    let hasStormMotion: Bool
    let qualityProfileLevelCount: Int
    let warnings: [String]

    var isDegraded: Bool {
        !hasEffectiveLayer || !hasStormMotion || qualityProfileLevelCount < 5 || !warnings.isEmpty
    }
}
