import Foundation

enum OperatorDashboardPageRenderer {
    static func render(snapshot: OperatorDashboardSnapshotResponse) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Arcus Signal Operator Dashboard</title>
          <style>
            \(styles)
          </style>
        </head>
        <body>
          <main class="shell">
            <header class="masthead">
              <div>
                <h1>Arcus Signal</h1>
                <p>Operational Dashboard</p>
              </div>
              <div class="masthead-meta">
                <div class="masthead-status">
                  <span id="connection-status" class="status-dot \(initialStatusClass(for: snapshot))" aria-hidden="true"></span>
                  <span id="connection-status-label" class="status-label \(initialStatusClass(for: snapshot))">\(initialStatusLabel(for: snapshot))</span>
                  <span id="snapshot-age">Snapshot \(escape(formatDuration(max(0, Int(snapshot.renderedAt.timeIntervalSince(snapshot.generatedAt))))) ) ago</span>
                </div>
                <div><a href="/v1/metrics">JSON API ↗</a></div>
              </div>
            </header>

            <section class="section">
              <div class="section-header"><h2>Red Lights</h2></div>
              <div class="grid">
                \(slot("ingest-card", content: ingestCard(snapshot.redLights.ingestFreshness)))
                \(slot("pipeline-backlog-card", content: pipelineBacklogCard(snapshot.redLights.pipelineBacklogAge)))
                \(slot("stuck-claimed-card", content: stuckClaimedCard(snapshot.redLights.stuckClaimedRows)))
                \(slot("stale-series-card", content: staleSeriesCard(snapshot.redLights.staleActiveSeriesCount)))
              </div>
            </section>

            <section class="section">
              <div class="section-header"><h2>Growth / Usage</h2></div>
              <div class="grid">
                \(slot("known-installations-card", content: knownInstallationsCard(snapshot.growthUsage.installationGrowth)))
                \(slot("new-installations-card", content: newInstallationsCard(snapshot.growthUsage.installationGrowth)))
                \(slot("recent-server-activity-card", content: recentServerActivityCard(snapshot.growthUsage.installationGrowth)))
                \(slot("active-today-card", content: activeTodayCard(snapshot.growthUsage.installationActivity)))
                \(slot("active-this-month-card", content: activeThisMonthCard(snapshot.growthUsage.installationActivity)))
              </div>
              <div class="stack section-table">
                \(slot("installation-activity-state-table", content: installationActivityStateTable(snapshot.growthUsage.installationActivity)))
                \(slot("installation-growth-table", content: installationGrowthTable(snapshot.growthUsage.installationGrowth)))
                \(slot("installation-footprint-table", content: installationFootprintTable(snapshot.growthUsage.installationFootprint, refreshedAt: snapshot.growthUsage.installationActivity.refreshedAt)))
              </div>
            </section>

            <section class="section">
              <div class="section-header"><h2>Model Artifacts</h2></div>
              <div class="grid">
                \(slot("pressure-artifact-readiness-card", content: pressureArtifactReadinessCard(snapshot.modelArtifacts.pressureArtifactReadiness)))
                \(slot("pressure-artifact-catalog-card", content: pressureArtifactCatalogCard(snapshot.modelArtifacts.pressureArtifactCatalog)))
              </div>
              <div class="stack section-table">
                \(slot("recent-pressure-artifacts-table", content: recentPressureArtifactsTable(snapshot.modelArtifacts.recentPressureArtifacts)))
              </div>
            </section>

            <section class="section">
              <div class="section-header"><h2>Delivery KPIs</h2></div>
              <div class="grid">
                \(slot("latency-card", content: latencyCard(snapshot.deliveryKPIs.endToEndAlertLatency)))
                \(slot("apns-success-card", content: apnsSuccessCard(snapshot.deliveryKPIs.apnsDeliverySuccessRate)))
                \(slot("noop-card", content: noOpCard(snapshot.deliveryKPIs.sendNoOpRateByReason)))
                \(slot("zero-candidate-card", content: zeroCandidateCard(snapshot.deliveryKPIs.zeroCandidateRevisionRate)))
              </div>
            </section>

            <section class="section">
              <div class="section-header"><h2>Audience / Targeting</h2></div>
              <div class="grid">
                \(slot("coverage-card", content: coverageCard(snapshot.audienceTargeting.freshTargetableInstallationCoverage)))
                \(slot("h3-card", content: h3Card(snapshot.audienceTargeting.alertsWithGeographyAndH3Success)))
              </div>
            </section>

            <section class="section">
              <div class="section-header"><h2>NWS / Alert Activity</h2><div class="subtle">Recent severe-weather activity and geography</div></div>
              <div class="stack">
                \(slot("touched-series-table", content: touchedSeriesTable(snapshot.operatorContext.lastTouchedSeries)))
              </div>
            </section>

            <section class="section">
              <div class="section-header"><h2>Operator Context</h2></div>
              <div class="stack">
                \(slot("recent-debug-table", content: recentDebugTable(snapshot.operatorContext.recentNotificationDebugEntries)))
              </div>
            </section>
          </main>
          \(liveUpdateScript(
              pollIntervalMilliseconds: pollIntervalMilliseconds,
              initialGeneratedAtMilliseconds: Int(snapshot.generatedAt.timeIntervalSince1970 * 1_000),
              freshnessThresholdMilliseconds: freshnessThresholdMilliseconds,
              initialSnapshotAgeMilliseconds: initialSnapshotAgeMilliseconds(for: snapshot)
          ))
        </body>
        </html>
        """
    }
static func renderUnavailable(renderedAt: Date = .now) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Arcus Signal Operator Dashboard</title>
          <style>
            \(unavailableStyles)
          </style>
        </head>
        <body>
          <section class="panel">
            <h1>Dashboard Snapshot Unavailable</h1>
            <p>The API process has not received a worker-computed dashboard snapshot yet. The page will keep checking for a fresh snapshot in the background.</p>
            <p>Rendered \(escape(formatDate(renderedAt)))</p>
            <p><a href="/v1/metrics">Try the JSON API</a></p>
          </section>
          \(unavailablePollingScript(pollIntervalMilliseconds: pollIntervalMilliseconds))
        </body>
        </html>
        """
    }

    private static let pollIntervalMilliseconds = max(15, OperatorDashboardConfig.fastRefreshIntervalSeconds / 2) * 1_000
    private static let freshnessThresholdMilliseconds = OperatorDashboardConfig.fastRefreshIntervalSeconds * 2 * 1_000

    private static func initialSnapshotAgeMilliseconds(for snapshot: OperatorDashboardSnapshotResponse) -> Int {
        max(0, Int(snapshot.renderedAt.timeIntervalSince(snapshot.generatedAt) * 1_000))
    }

    private static func initialStatusClass(for snapshot: OperatorDashboardSnapshotResponse) -> String {
        snapshot.renderedAt.timeIntervalSince(snapshot.generatedAt) <= TimeInterval(OperatorDashboardConfig.fastRefreshIntervalSeconds * 2)
            ? "live"
            : "stale"
    }

    private static func initialStatusLabel(for snapshot: OperatorDashboardSnapshotResponse) -> String {
        initialStatusClass(for: snapshot).uppercased()
    }
}
