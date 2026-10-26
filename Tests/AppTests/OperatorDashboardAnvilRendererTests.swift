@testable import App
import Foundation
import Testing

@Suite("Operator dashboard Anvil rendering")
struct OperatorDashboardAnvilRendererTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let buildInfo = ArcusSignalBuildInfo(version: "test", revision: nil)

    private func snapshot(with observation: AnvilServiceObservation?) -> OperatorDashboardStoredSnapshot {
        var snapshot = OperatorDashboardStoredSnapshot.empty(now: now)
        snapshot.anvil = observation
        return snapshot
    }

    private func observation(
        status: OperatorDashboardHealthState,
        checkedAt: Date? = nil,
        lastSuccessfulAt: Date? = nil,
        sharppyAvailable: Bool? = nil,
        version: String? = nil,
        revision: String? = nil,
        consecutiveFailures: Int = 0,
        recentFailure: AnvilServiceObservation.Failure? = nil
    ) -> AnvilServiceObservation {
        var value = AnvilServiceObservation()
        value.status = status
        value.checkedAt = checkedAt
        value.lastSuccessfulAt = lastSuccessfulAt
        value.sharppyAvailable = sharppyAvailable
        value.version = version
        value.revision = revision
        value.consecutiveFailures = consecutiveFailures
        value.recentFailure = recentFailure
        return value
    }

    @Test("Healthy service identity appears in Overview and Models")
    func healthyRendering() {
        let anvil = observation(
            status: .healthy, checkedAt: now, lastSuccessfulAt: now,
            sharppyAvailable: true, version: "1.4.2", revision: "abc123"
        )
        let stored = snapshot(with: anvil)
        let overview = OperatorDashboardPageRenderer.render(
            snapshot: .init(snapshot: stored, renderedAt: now), buildInfo: buildInfo
        )
        let models = OperatorDashboardPageRenderer.render(
            snapshot: .init(snapshot: stored, renderedAt: now), page: .models, buildInfo: buildInfo
        )

        #expect(overview.contains("HRRR · pressure artifacts"))
        #expect(overview.contains("Anvil · Healthy · SHARPpy import ready"))
        #expect(overview.contains("Version 1.4.2 · revision abc123"))
        #expect(models.contains("Anvil · Healthy"))
        #expect(models.contains("Last check:"))
        #expect(models.contains("Last successful observation:"))
        #expect(!OperatorDashboardPageRenderer.healthOverview(.init(snapshot: stored, renderedAt: now), anvil: anvil).contains("<h3>Anvil</h3>"))
    }

    @Test("Warning and sustained critical states create Red Lights linked to Models")
    func actionableStates() {
        let warning = observation(
            status: .warning, checkedAt: now, lastSuccessfulAt: now,
            sharppyAvailable: false, version: "1.4.2", revision: "abc123"
        )
        let warningSnapshot = snapshot(with: warning)
        let warningRedLights = OperatorDashboardPageRenderer.healthOverview(
            .init(snapshot: warningSnapshot, renderedAt: now), anvil: warning
        )
        #expect(warningRedLights.contains("Anvil reachable · SHARPpy unavailable"))
        #expect(warningRedLights.contains("href=\"/dashboard/models\">Inspect Model Pipeline"))

        let critical = observation(
            status: .critical, checkedAt: now, lastSuccessfulAt: now.addingTimeInterval(-120),
            sharppyAvailable: true, version: "1.4.1", revision: "oldrev",
            consecutiveFailures: 3, recentFailure: .transport
        )
        let criticalSnapshot = snapshot(with: critical)
        let criticalRedLights = OperatorDashboardPageRenderer.healthOverview(
            .init(snapshot: criticalSnapshot, renderedAt: now), anvil: critical
        )
        #expect(criticalRedLights.contains("Anvil unreachable after 3 consecutive probes"))
        #expect(criticalRedLights.contains("href=\"/dashboard/models\">Inspect Model Pipeline"))

        let criticalModels = OperatorDashboardPageRenderer.render(
            snapshot: .init(snapshot: criticalSnapshot, renderedAt: now), page: .models, buildInfo: buildInfo
        )
        #expect(criticalModels.contains("Last successful identity 1.4.1"))
        #expect(criticalModels.contains("Recent failure category: transport"))
        #expect(!criticalModels.contains("Version 1.4.1 · revision oldrev"))
    }

    @Test("Unknown and stale observations stay out of Red Lights and label old identity")
    func unknownAndStaleStates() {
        let unknown = observation(status: .unknown)
        let unknownSnapshot = snapshot(with: unknown)
        let unknownRedLights = OperatorDashboardPageRenderer.healthOverview(
            .init(snapshot: unknownSnapshot, renderedAt: now), anvil: unknown
        )
        #expect(!unknownRedLights.contains("<h3>Anvil</h3>"))
        #expect(!unknownRedLights.contains("Anvil reachable"))
        #expect(!unknownRedLights.contains("Inspect Model Pipeline"))

        let stale = observation(
            status: .healthy, checkedAt: now.addingTimeInterval(-181),
            lastSuccessfulAt: now.addingTimeInterval(-181), sharppyAvailable: true,
            version: "1.4.2", revision: "abc123"
        )
        let staleSnapshot = snapshot(with: stale)
        let staleResponse = OperatorDashboardSnapshotResponse(snapshot: staleSnapshot, renderedAt: now)
        #expect(staleResponse.anvil?.status == .unknown)
        let staleModels = OperatorDashboardPageRenderer.render(
            snapshot: staleResponse, page: .models, buildInfo: buildInfo
        )
        #expect(staleModels.contains("Last successful identity 1.4.2"))
        #expect(staleModels.contains("observed 2027-01-15 07:56:59 UTC"))
        #expect(!staleModels.contains("Version 1.4.2 · revision abc123"))
    }

    @Test("Identity text is escaped and live refresh consumes the top-level observation")
    func escapesIdentityAndRefreshes() {
        let anvil = observation(
            status: .healthy, checkedAt: now, lastSuccessfulAt: now,
            sharppyAvailable: true, version: "<script>alert(1)</script>", revision: "<b>rev</b>"
        )
        let html = OperatorDashboardPageRenderer.render(
            snapshot: .init(snapshot: snapshot(with: anvil), renderedAt: now),
            page: .models,
            buildInfo: buildInfo
        )
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(html.contains("&lt;b&gt;rev&lt;/b&gt;"))
        #expect(!html.contains("<script>alert(1)</script>"))
        #expect(html.contains("renderHealthOverview(snapshot.redLights,snapshot.anvil)"))
        #expect(html.contains("renderModelOverview(snapshot.modelArtifacts, detail,snapshot.anvil)"))
    }
}
