import Foundation

enum OperatorDashboardPageRenderer {
    enum Page: String, CaseIterable {
        case overview, models, installations, nws, delivery
        var path: String { self == .overview ? "/dashboard" : "/dashboard/\(rawValue)" }
        var title: String {
            switch self {
            case .overview: "Overview"
            case .models: "Model Pipeline"
            case .installations: "Usage & Installations"
            case .nws: "NWS Activity"
            case .delivery: "Delivery"
            }
        }
        var subtitle: String {
            switch self {
            case .overview: "The system, at a glance."
            case .models: "Is the expected model artifact ready, and what is blocking it?"
            case .installations: "Foreground activity, growth, and coarse operational presence."
            case .nws: "Recent weather activity, lifecycle, and hazard context."
            case .delivery: "Delivery outcomes, candidate coverage, and reasons a push did not send."
            }
        }
    }

    static func render(snapshot: OperatorDashboardSnapshotResponse, page: Page = .overview, environment: String = "") -> String {
        let age = max(0, Int(snapshot.renderedAt.timeIntervalSince(snapshot.generatedAt)))
        let live = age <= OperatorDashboardConfig.fastRefreshIntervalSeconds * 2
        return shell(page: page, environment: environment, status: live ? "live" : "stale", age: "Snapshot \(formatDuration(age)) ago", content: pageContent(snapshot, page: page), script: liveUpdateScript(
            pollIntervalMilliseconds: pollIntervalMilliseconds,
            initialGeneratedAtMilliseconds: Int(snapshot.generatedAt.timeIntervalSince1970 * 1_000),
            freshnessThresholdMilliseconds: freshnessThresholdMilliseconds,
            initialSnapshotAgeMilliseconds: age * 1_000
        ))
    }

    static func shell(page: Page, environment: String, status: String, age: String, content: String, script: String) -> String {
        let navigation = Page.allCases.enumerated().map { index, destination in
            "<a href=\"\(destination.path)\"\(destination == page ? " aria-current=\"page\"" : "")><span class=\"nav-index\">0\(index + 1)</span>\(destination.title)</a>"
        }.joined()
        let environmentLabel = environment.isEmpty ? "" : "<span class=\"environment\">\(escape(environment.uppercased()))</span>"
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="color-scheme" content="dark"><title>\(page.title) · Arcus Signal</title><style>\(styles)</style></head>
        <body class="control\(page == .overview ? "" : " detail-page")"><a class="skip" href="#main">Skip to content</a>
        <div class="app"><header class="masthead"><a class="wordmark" href="/dashboard">Arcus Signal\(environmentLabel)</a>
        <div class="telemetry" aria-label="Snapshot connection"><span id="connection-status" class="status-dot \(status)" aria-hidden="true"></span><span id="connection-status-label" class="status-label \(status)">\(status.uppercased())</span><span id="snapshot-age">\(escape(age))</span><a href="/v1/metrics">JSON API ↗</a></div></header>
        <nav class="primary-nav" aria-label="Primary">\(navigation)<div class="sidebar-note"><strong>Arcus operations</strong>Worker-computed snapshot<br>Coarse location only</div></nav>
        <main id="main"><div class="page-head"><div>\(page == .overview ? "" : "<div class=\"breadcrumbs\"><a href=\"/dashboard\">Overview</a> / \(page.title)</div>")<h1>\(page.title)</h1><p>\(page.subtitle)</p></div></div>
        <div id="freshness-notice" class="freshness-notice" role="status" aria-live="polite"\(status == "live" || status == "unavailable" ? " hidden" : "")>\(status == "stale" ? "Snapshot is stale. Showing the last available data; current system health is not confirmed." : "")</div>
        <div class="\(page == .overview ? "overview-grid" : "detail-grid")">\(content)</div></main>
        <footer class="page-footer"><span>Arcus Signal · Operational Dashboard</span><span>All times UTC · canonical worker snapshot</span></footer></div>\(script)
        </body></html>
        """
    }

    static func pageContent(_ s: OperatorDashboardSnapshotResponse, page: Page) -> String {
        switch page {
        case .overview:
            return controlModule("health-overview", "health", healthOverview(s.redLights))
                + controlModule("model-overview", "model", modelOverview(s.modelArtifacts))
                + controlModule("usage-overview", "usage", usageOverview(s.growthUsage))
                + controlModule("footprint-overview", "footprint", footprintOverview(s.growthUsage))
                + controlModule("geography-overview", "geography", geographyOverview(s.growthUsage.installationActivity))
                + controlModule("nws-overview", "nws", nwsOverview(s.operatorContext.lastTouchedSeries))
                + controlModule("delivery-overview", "delivery", deliveryOverview(s.deliveryKPIs, s.audienceTargeting))
        case .models:
            return controlModule("model-overview", "model", modelOverview(s.modelArtifacts, detail: true))
                + detailModule("Catalog diagnostics", slot("pressure-artifact-catalog-card", content: pressureArtifactCatalogCard(s.modelArtifacts.pressureArtifactCatalog)))
                + detailModule("Recent pressure artifacts", slot("recent-pressure-artifacts-table", content: recentPressureArtifactsTable(s.modelArtifacts.recentPressureArtifacts)) + "<details><summary>Selected artifact evidence</summary>" + slot("pressure-artifact-readiness-card", content: pressureArtifactReadinessCard(s.modelArtifacts.pressureArtifactReadiness)) + "</details>", wide: true)
        case .installations:
            return controlModule("usage-overview", "usage", usageOverview(s.growthUsage, detail: true))
                + detailModule("Server activity", slot("recent-server-activity-card", content: recentServerActivityCard(s.growthUsage.installationGrowth)) + slot("known-installations-card", content: knownInstallationsCard(s.growthUsage.installationGrowth)))
                + controlModule("footprint-overview", "footprint wide", footprintOverview(s.growthUsage, detail: true))
                + controlModule("geography-overview", "geography", geographyOverview(s.growthUsage.installationActivity, detail: true))
                + detailModule("Monthly installation growth", slot("installation-growth-table", content: installationGrowthTable(s.growthUsage.installationGrowth)))
        case .nws:
            return controlModule("health-overview", "health wide", healthOverview(s.redLights))
                + detailModule("Stale series context", "<p id=\"stale\" class=\"detail-copy\">The snapshot supplies the stale-series count, not the affected identities. The recently touched series below are not necessarily the stale ones.</p>", wide: true)
                + detailModule("Hazard and revision context", slot("touched-series-table", content: touchedSeriesTable(s.operatorContext.lastTouchedSeries)), wide: true)
        case .delivery:
            return controlModule("delivery-overview", "delivery", deliveryOverview(s.deliveryKPIs, s.audienceTargeting, detail: true))
                + detailModule("APNs outcomes & latency", slot("apns-success-card", content: apnsSuccessCard(s.deliveryKPIs.apnsDeliverySuccessRate)) + slot("latency-card", content: latencyCard(s.deliveryKPIs.endToEndAlertLatency)))
                + detailModule("Targeting coverage", slot("coverage-card", content: coverageCard(s.audienceTargeting.freshTargetableInstallationCoverage)) + slot("h3-card", content: h3Card(s.audienceTargeting.alertsWithGeographyAndH3Success)))
                + detailModule("Send decisions", slot("noop-card", content: noOpCard(s.deliveryKPIs.sendNoOpRateByReason)) + slot("zero-candidate-card", content: zeroCandidateCard(s.deliveryKPIs.zeroCandidateRevisionRate)))
                + detailModule("Recent notification context", slot("recent-debug-table", content: recentDebugTable(s.operatorContext.recentNotificationDebugEntries)), wide: true)
        }
    }

    static func renderUnavailable(renderedAt: Date = .now, page: Page = .overview, environment: String = "") -> String {
        shell(page: page, environment: environment, status: "unavailable", age: "No snapshot", content: """
        <section class="module wide unavailable"><h1>Dashboard Snapshot Unavailable</h1><p class="detail-copy">The API process has not received a worker-computed dashboard snapshot yet. This page will keep checking for a fresh snapshot.</p><p class="module-note">Rendered \(escape(formatDate(renderedAt)))</p><p><a href="/v1/metrics">Try the JSON API ↗</a></p></section>
        """, script: unavailablePollingScript(pollIntervalMilliseconds: pollIntervalMilliseconds, recoveryPath: page.path))
    }

    private static let pollIntervalMilliseconds = max(15, OperatorDashboardConfig.fastRefreshIntervalSeconds / 2) * 1_000
    private static let freshnessThresholdMilliseconds = OperatorDashboardConfig.fastRefreshIntervalSeconds * 2 * 1_000
}
