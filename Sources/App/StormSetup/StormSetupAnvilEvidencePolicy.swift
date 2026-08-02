import Foundation
import ArcusCore

enum StormSetupAnvilEvidencePolicy {
    static let staleWarningPrefix = "Pressure artifact stale fallback selected:"

    static func missingSelectedSurfaceValidTime() -> AnvilEvidenceResolution {
        .unavailable(reason: "Selected surface HRRR source was missing valid time metadata.")
    }

    static func classify(
        selectedSurfaceValidTime: Date,
        analysis: AnvilAnalyzeProfileAnalysisResponse
    ) -> AnvilEvidenceResolution {
        guard analysis.request.validTime == analysis.debug.validTime else {
            return .unavailable(
                reason: "Anvil request valid time \(analysis.request.validTime) did not match debug valid time \(analysis.debug.validTime)."
            )
        }

        let pressureArtifactValidTime = analysis.debug.validTime
        let staleWarnings = analysis.debug.warnings.filter { warning in
            warning.hasPrefix(staleWarningPrefix)
        }

        if pressureArtifactValidTime == selectedSurfaceValidTime {
            return .exact(
                evidence: AnvilIngredientEvidence(response: analysis.response),
                profileAnalysis: analysis.response,
                pressureArtifactRunTime: analysis.debug.runTime,
                pressureArtifactForecastHour: analysis.debug.forecastHour,
                pressureArtifactValidTime: pressureArtifactValidTime,
                pressureArtifactProduct: analysis.debug.product
            )
        }

        guard pressureArtifactValidTime < selectedSurfaceValidTime,
              !staleWarnings.isEmpty else {
            return .unavailable(
                reason: "Anvil evidence valid time \(pressureArtifactValidTime) did not match the selected surface HRRR valid time \(selectedSurfaceValidTime)."
            )
        }

        return .stale(
            evidence: AnvilIngredientEvidence(
                response: analysis.response,
                additionalWarnings: staleWarnings
            ),
            profileAnalysis: analysis.response,
            pressureArtifactRunTime: analysis.debug.runTime,
            pressureArtifactForecastHour: analysis.debug.forecastHour,
            pressureArtifactValidTime: pressureArtifactValidTime,
            pressureArtifactProduct: analysis.debug.product,
            staleAgeSeconds: max(
                0,
                Int(selectedSurfaceValidTime.timeIntervalSince(pressureArtifactValidTime).rounded(.down))
            )
        )
    }
}
