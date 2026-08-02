import Foundation
import Testing
@testable import App

@Suite("Storm Setup Anvil evidence policy")
struct StormSetupAnvilEvidencePolicyTests {
    private let selectedSurfaceValidTime = makeStormSetupRouteAnalysisResponse().request.validTime

    @Test("exact pressure timing produces canonical Anvil evidence")
    func exactPressureTiming() {
        let analysis = makeStormSetupRouteAnalysisResponse(
            validTime: selectedSurfaceValidTime
        )

        let resolution = StormSetupAnvilEvidencePolicy.classify(
            selectedSurfaceValidTime: selectedSurfaceValidTime,
            analysis: analysis
        )

        #expect(resolution.artifactOutcome == .exact)
        #expect(resolution.evidence == AnvilIngredientEvidence(response: analysis.response))
        #expect(resolution.profileAnalysis == analysis.response)
        #expect(resolution.pressureArtifactValidTime == selectedSurfaceValidTime)
        #expect(resolution.staleAgeSeconds == nil)
    }

    @Test("request and debug timing mismatch is unavailable")
    func requestAndDebugTimingMismatch() {
        let debugValidTime = selectedSurfaceValidTime.addingTimeInterval(-3_600)
        let analysis = makeStormSetupRouteAnalysisResponse(
            validTime: selectedSurfaceValidTime,
            debugValidTime: debugValidTime
        )

        let resolution = StormSetupAnvilEvidencePolicy.classify(
            selectedSurfaceValidTime: selectedSurfaceValidTime,
            analysis: analysis
        )

        #expect(resolution.artifactOutcome == .unavailable)
        #expect(resolution.evidence.status == .unavailable)
        #expect(resolution.evidence.reason?.contains("did not match debug valid time") == true)
        #expect(resolution.pressureArtifactValidTime == nil)
    }

    @Test("recognized stale fallback retains its warning and age")
    func recognizedStaleFallback() {
        let pressureValidTime = selectedSurfaceValidTime.addingTimeInterval(-3_600.75)
        let staleWarning = "Pressure artifact stale fallback selected: retained test warning."
        let analysis = makeStormSetupRouteAnalysisResponse(
            validTime: pressureValidTime,
            warnings: [staleWarning, "Unrelated debug warning."]
        )

        let resolution = StormSetupAnvilEvidencePolicy.classify(
            selectedSurfaceValidTime: selectedSurfaceValidTime,
            analysis: analysis
        )

        #expect(resolution.artifactOutcome == .stale)
        #expect(resolution.evidence.status == .degraded)
        #expect(resolution.evidence.diagnostics.warnings == [staleWarning])
        #expect(resolution.profileAnalysis == analysis.response)
        #expect(resolution.pressureArtifactValidTime == pressureValidTime)
        #expect(resolution.staleAgeSeconds == 3_600)
    }

    @Test("older pressure timing without an acknowledged fallback is unavailable")
    func unacknowledgedOlderPressureTiming() {
        let pressureValidTime = selectedSurfaceValidTime.addingTimeInterval(-3_600)
        let analysis = makeStormSetupRouteAnalysisResponse(
            validTime: pressureValidTime,
            warnings: ["Pressure data is older."]
        )

        let resolution = StormSetupAnvilEvidencePolicy.classify(
            selectedSurfaceValidTime: selectedSurfaceValidTime,
            analysis: analysis
        )

        #expect(resolution.artifactOutcome == .unavailable)
        #expect(resolution.evidence.status == .unavailable)
        #expect(resolution.profileAnalysis == nil)
        #expect(resolution.staleAgeSeconds == nil)
    }

    @Test("future pressure timing is unavailable even with a stale warning")
    func futurePressureTiming() {
        let analysis = makeStormSetupRouteAnalysisResponse(
            validTime: selectedSurfaceValidTime.addingTimeInterval(3_600),
            warnings: ["Pressure artifact stale fallback selected: invalid future fallback."]
        )

        let resolution = StormSetupAnvilEvidencePolicy.classify(
            selectedSurfaceValidTime: selectedSurfaceValidTime,
            analysis: analysis
        )

        #expect(resolution.artifactOutcome == .unavailable)
        #expect(resolution.evidence.status == .unavailable)
        #expect(resolution.profileAnalysis == nil)
        #expect(resolution.staleAgeSeconds == nil)
    }

    @Test("missing selected surface valid time is unavailable")
    func missingSelectedSurfaceValidTime() {
        let resolution = StormSetupAnvilEvidencePolicy.missingSelectedSurfaceValidTime()

        #expect(resolution.artifactOutcome == .unavailable)
        #expect(resolution.evidence.status == .unavailable)
        #expect(
            resolution.evidence.reason
                == "Selected surface HRRR source was missing valid time metadata."
        )
        #expect(resolution.profileAnalysis == nil)
        #expect(resolution.pressureArtifactValidTime == nil)
    }
}
