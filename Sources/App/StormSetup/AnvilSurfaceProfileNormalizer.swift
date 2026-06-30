import Foundation

struct AnvilSurfaceProfileNormalizer: Sendable {
    func normalize(
        response: AnvilAnalyzeProfileResponse,
        additionalWarnings: [String] = []
    ) -> AnvilIngredientEvidence {
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

        return AnvilIngredientEvidence(
            status: diagnostics.isDegraded || supportCount == 0 ? .degraded : .available,
            reason: nil,
            scp: scp,
            stp: stp,
            ship: ship,
            diagnostics: diagnostics
        )
    }

    private static func supportBand(forSCP value: Double) -> IngredientSupport {
        switch value {
        case ..<0.5:
            return .weak
        case ..<1.5:
            return .conditional
        case ..<3:
            return .supportive
        default:
            return .strong
        }
    }

    private static func supportBand(forSTP value: Double) -> IngredientSupport {
        switch value {
        case ..<0.5:
            return .weak
        case ..<1.25:
            return .conditional
        case ..<2.5:
            return .supportive
        default:
            return .strong
        }
    }

    private static func supportBand(forSHIP value: Double) -> IngredientSupport {
        switch value {
        case ..<0.5:
            return .weak
        case ..<1:
            return .conditional
        case ..<2:
            return .supportive
        default:
            return .strong
        }
    }
}
