import Foundation
import Vapor
import ArcusCore

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
        let combinedWarnings = response.quality.warnings + additionalWarnings
        let diagnostics = AnvilIngredientDiagnostics(
            hasEffectiveLayer: response.effectiveLayer.status.lowercased() == "found",
            hasStormMotion: response.stormMotion.status.lowercased() == "computed",
            qualityProfileLevelCount: response.quality.profileLevelCount,
            warnings: combinedWarnings
        )

        let scp = response.scp.map { AnvilIngredientMetricEvidence(support: Self.supportBand(forSCP: $0)) }
        let stpSupports = [response.stpCin, response.stpFixed]
            .compactMap { $0 }
            .map(Self.supportBand(forSTP:))
        let stp = stpSupports.max().map { AnvilIngredientMetricEvidence(support: $0) }
        let ship = response.ship.map { AnvilIngredientMetricEvidence(support: Self.supportBand(forSHIP: $0)) }
        let supportCount = [scp, stp, ship].compactMap { $0 }.count

        self.status = diagnostics.isDegraded || supportCount == 0 ? .degraded : .available
        self.reason = nil
        self.scp = scp
        self.stp = stp
        self.ship = ship
        self.diagnostics = diagnostics
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

    var tornadoStrongestSupport: IngredientSupport? {
        [scp?.support, stp?.support].compactMap { $0 }.max()
    }

    var isDegraded: Bool {
        status != .available || diagnostics.isDegraded || supportCount == 0
    }

    private static func supportBand(forSCP value: Double) -> IngredientSupport {
        switch value {
        case ..<0.5: return .weak
        case ..<1.5: return .conditional
        case ..<3: return .supportive
        default: return .strong
        }
    }

    private static func supportBand(forSTP value: Double) -> IngredientSupport {
        switch value {
        case ..<0.5: return .weak
        case ..<1.25: return .conditional
        case ..<2.5: return .supportive
        default: return .strong
        }
    }

    private static func supportBand(forSHIP value: Double) -> IngredientSupport {
        switch value {
        case ..<0.5: return .weak
        case ..<1: return .conditional
        case ..<2: return .supportive
        default: return .strong
        }
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
