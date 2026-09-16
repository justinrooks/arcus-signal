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
            <section class="hero">
              <div>
                <h1>Arcus Signal</h1>
                <p>Operational snapshot for ingest, targeting, and notification delivery. The page polls the canonical <span class="mono">/v1/metrics</span> snapshot and updates in place without a full reload.</p>
              </div>
              <div class="hero-meta">
                <div id="hero-rendered-at">Rendered \(escape(formatDate(snapshot.renderedAt)))</div>
                <div id="hero-generated-at">Snapshot generated \(escape(formatDate(snapshot.generatedAt)))</div>
                <div><a href="/v1/metrics">View JSON API</a></div>
              </div>
            </section>

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
              </div>
              <div class="stack section-table">
                \(slot("installation-growth-table", content: installationGrowthTable(snapshot.growthUsage.installationGrowth)))
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
              <div class="section-header"><h2>Operator Context</h2></div>
              <div class="stack">
                \(slot("recent-debug-table", content: recentDebugTable(snapshot.operatorContext.recentNotificationDebugEntries)))
                \(slot("touched-series-table", content: touchedSeriesTable(snapshot.operatorContext.lastTouchedSeries)))
              </div>
            </section>
          </main>
          \(liveUpdateScript(
              pollIntervalMilliseconds: pollIntervalMilliseconds,
              initialGeneratedAtMilliseconds: Int(snapshot.generatedAt.timeIntervalSince1970 * 1_000)
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
}
