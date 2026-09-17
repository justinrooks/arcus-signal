import Foundation

extension OperatorDashboardPageRenderer {
    static func controlModule(_ id: String, _ kind: String, _ body: String) -> String {
        "<section id=\"\(id)\" class=\"module \(kind)\">\(body)</section>"
    }

    static func moduleHead(_ title: String, _ subtitle: String, _ page: Page? = nil) -> String {
        "<div class=\"module-head\"><div><h2>\(escape(title))</h2><p>\(escape(subtitle))</p></div>\(page.map { "<a href=\"\($0.path)\">Inspect ↗</a>" } ?? "")</div>"
    }

    static func detailModule(_ title: String, _ body: String, wide: Bool = false) -> String {
        "<section class=\"module\(wide ? " wide" : "")\">\(moduleHead(title, ""))\(body)</section>"
    }

    static func controlStat(_ label: String, _ value: String, _ context: String) -> String {
        "<div><span class=\"stat-label\">\(escape(label))</span><strong class=\"stat-value\">\(escape(value))</strong><span class=\"stat-unit\">\(escape(context))</span></div>"
    }

    static func controlTime(_ date: Date?) -> String {
        guard let date else { return "n/a" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date).replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: ":00Z", with: " UTC").replacingOccurrences(of: "Z", with: " UTC")
    }

    static func healthItem(_ title: String, _ value: String, _ status: OperatorDashboardHealthState, _ summary: String, _ details: String = "") -> String {
        """
        <div class="health-item health-\(status.rawValue)"><h3>\(escape(title))</h3><div class="health-reading"><strong>\(escape(value))</strong><span class="health-status">\(status.rawValue.capitalized)</span></div><p>\(escape(summary))</p>\(details.isEmpty ? "" : "<details class=\"health-details\"><summary>Details</summary><div class=\"detail-copy\">\(escape(details))</div></details>")</div>
        """
    }

    static func healthOverview(_ r: OperatorDashboardRedLightsSectionResponse) -> String {
        let i = r.ingestFreshness, b = r.pipelineBacklogAge, c = r.stuckClaimedRows, s = r.staleActiveSeriesCount
        var findings: [String] = []
        if c.status == .critical { findings.append("\(c.count) stuck claims") }
        if s.status == .warning { findings.append("\(s.count) stale active series") }
        let unknown = [i.status, b.status, c.status, s.status].filter { $0 == .unknown }.count
        let headline = findings.isEmpty ? "No classified red lights · \(unknown) unknown signals" : findings.joined(separator: " · ") + " need review"
        let tone = c.status == .critical ? "danger" : (findings.isEmpty ? "muted" : "warning")
        let destination = c.status == .critical ? Page.delivery : Page.nws
        return """
        <div class="health-top \(findings.isEmpty ? "neutral" : "")"><div><div class="health-label">Red Lights</div><strong class="\(tone)">\(escape(headline))</strong></div><a href="\(destination.path)">Inspect \(destination.title) ↗</a></div><div class="health-rail">
        \(healthItem("Ingest freshness", maybeDuration(i.timeSinceLastSuccessfulSweepSeconds), i.status, "\(i.recentSuccessCount) successes / \(i.recentFailureCount) failures", "No server health threshold is defined. Last success: \(controlTime(i.lastSuccessfulSweepAt)). Last attempt: \(controlTime(i.lastAttemptAt)). Last failure: \(controlTime(i.lastFailureAt)). Error: \(i.lastFailureMessage ?? "none")."))
        \(healthItem("Dispatch backlog", "\(b.pendingTargetDispatchCount + b.pendingNotificationDispatchCount)", b.status, "\(b.pendingTargetDispatchCount) target · \(b.pendingNotificationDispatchCount) notification rows", "Oldest target: \(maybeDuration(b.oldestPendingTargetDispatchAgeSeconds)) (\(controlTime(b.oldestPendingTargetDispatchCreatedAt))). Oldest notification: \(maybeDuration(b.oldestPendingNotificationDispatchAgeSeconds)) (\(controlTime(b.oldestPendingNotificationDispatchCreatedAt))). Pending queue handoffs, not delivery completions."))
        \(healthItem("Stuck claims", "\(c.count)", c.status, "Claim age threshold: \(formatDuration(c.thresholdSeconds))", "Oldest claim: \(maybeDuration(c.oldestClaimedAgeSeconds)) (\(controlTime(c.oldestClaimedCreatedAt)))."))
        \(healthItem("Stale active series", "\(s.count)", s.status, "Grace window: \(formatDuration(s.graceSeconds))"))</div>
        """
    }

    static func modelOverview(_ m: OperatorDashboardModelArtifactsSectionResponse, detail: Bool = false) -> String {
        let r = m.pressureArtifactReadiness, c = m.pressureArtifactCatalog
        let outcome = pressureArtifactOutcome(r.selectionOutcome)
        let tone = pressureArtifactOutcomeClass(r.selectionOutcome) ?? "muted"
        let catalog = [("Ready", c.readyCount), ("Warming", c.warmingCount), ("Pending", c.pendingCount), ("Failed", c.failedCount)]
        let counts = catalog.map { name, count in "<div><strong>\(c.refreshedAt == nil ? "n/a" : String(count))</strong><span>\(name)</span></div>" }.joined()
        let track = c.refreshedAt == nil ? "" : catalog.filter { $0.1 > 0 }.map { name, count in "<i class=\"catalog-\(name.lowercased())\" style=\"flex:\(count)\"></i>" }.joined()
        return """
        \(moduleHead("Model Pipeline", "HRRR · pressure artifacts", detail ? nil : .models))<div class="model-current"><span class="ready-mark \(tone)" aria-hidden="true">\(r.selectionOutcome == .exact ? "✓" : "—")</span><div><div class="artifact-title">\(r.selectionOutcome == .exact ? "Current artifact ready" : "Pressure artifact \(outcome.lowercased())")</div><div class="artifact-sub">\(escape(controlTime(r.runTime))) / F\(r.forecastHour.map(String.init) ?? "—") · valid \(escape(controlTime(r.validTime)))</div></div><span class="badge \(tone)">\(outcome)</span></div><div class="catalog">\(counts)</div><div class="catalog-track" aria-hidden="true">\(track)</div><p class="module-note">Checked \(escape(controlTime(r.lastCheckedAt ?? r.updatedAt))) · \(c.refreshedAt == nil ? "Catalog unavailable" : "\(c.stuckWarmingCount) stuck warming · \(c.expiredCount) expired catalog rows")</p>\([r.readinessReason, r.errorSummary, c.stuckReason].compactMap { $0 }.map { "<p class=\"module-note warning\">\(escape($0))</p>" }.joined())
        """
    }

    static func usageOverview(_ g: OperatorDashboardGrowthUsageSectionResponse, detail: Bool = false) -> String {
        let growth = g.installationGrowth, activity = g.installationActivity
        return """
        \(moduleHead("Usage & Installations", "Explicit foreground activity · UTC windows", detail ? nil : .installations))<div class="usage-metrics">\(controlStat("Known", growth.refreshedAt == nil ? "n/a" : String(growth.knownInstallationCount), "installations"))\(controlStat("Today", activity.refreshedAt == nil ? "n/a" : String(activity.dailyActiveInstallationCount), "DAU"))\(controlStat("This month", activity.refreshedAt == nil ? "n/a" : String(activity.monthlyActiveInstallationCount), "MAU"))\(controlStat("New this month", growth.refreshedAt == nil ? "n/a" : String(growth.newThisMonthCount), growth.monthlyGrowth.last.map { formatMonth($0.monthStart) } ?? "n/a"))</div><div class="usage-foot"><span><strong>\(growth.refreshedAt == nil ? "n/a" : String(growth.currentlySubscribedCount))</strong> subscribed</span><span class="muted">Activity updated \(escape(controlTime(activity.refreshedAt)))</span></div><p class="module-note">Installations, not people. Background contact is not DAU.</p>
        """
    }

    static func footprintOverview(_ g: OperatorDashboardGrowthUsageSectionResponse, detail: Bool = false) -> String {
        let rows = g.installationFootprint.prefix(5).map { e in
            """
            <tr><td data-label="Location"><strong>\(escape(e.locationLabel))</strong><small>\(e.isActive ? "Active" : "Inactive") · \(e.isSubscribed ? "subscribed" : "unsubscribed")</small></td><td data-label="App / auth">\(escape(e.appVersion))<small>\(escape(e.locationAuth))</small></td><td data-label="Presence age" class="mono">\(escape(maybeDuration(e.presenceAgeSeconds)))</td><td data-label="Candidate eligibility"><span class="eligibility \(e.candidateQueryEligible ? "good" : "muted")">\(e.candidateQueryEligible ? "Eligible" : "Not eligible")</span>\(e.ineligibilityReason.map { "<small>\(escape($0))</small>" } ?? "")</td></tr>
            """
        }.joined()
        let body = rows.isEmpty ? "<p class=\"empty\">No production presence rows in the last 90 days.</p>" : "<div class=\"table-wrap footprint-table-wrap\" role=\"region\" aria-label=\"Installation footprint\" tabindex=\"0\"><table><thead><tr><th>Coarse location</th><th>App / auth</th><th>Presence</th><th>Candidate</th></tr></thead><tbody>\(rows)</tbody></table></div>"
        return moduleHead("Installation footprint", "5 freshest production rows · last 90 days", detail ? nil : .installations) + body + "<p class=\"module-note\">Presence freshness, not app-open history · updated \(escape(controlTime(g.installationActivity.refreshedAt)))</p>"
    }

    static func geographyOverview(_ a: InstallationActivityMetricResponse, detail: Bool = false) -> String {
        let maximum = max(1, a.stateBreakdown.map(\.activeTodayCount).max() ?? 1)
        let rows = a.stateBreakdown.map { e in
            "<tr><td class=\"state-label\"><div class=\"state-bar\"><span>\(escape(e.state))</span><i style=\"--count:\(Double(e.activeTodayCount) / Double(maximum) * 8)\" aria-hidden=\"true\"></i></div></td><td class=\"num\">\(e.activeTodayCount)</td><td class=\"num\">\(e.activeThisMonthCount)</td></tr>"
        }.joined()
        let body = rows.isEmpty ? "<p class=\"empty\">\(a.refreshedAt == nil ? "Activity data unavailable." : "No foreground activity this month.")</p>" : "<table class=\"state-table\"><thead><tr><th>State</th><th class=\"num\">Today</th><th class=\"num\">Month</th></tr></thead><tbody>\(rows)</tbody></table>"
        return moduleHead("Where usage is attributed", "Current / last-known state", detail ? nil : .installations) + body + "<p class=\"geo-note\">Not location at app open · Unknown stays visible</p>"
    }

    static func nwsOverview(_ n: LastTouchedSeriesResponse) -> String {
        let rows: String = n.entries.map { e -> String in
            let area = operatorDashboardAreaDescription(areaDescription: e.areaDescription, ugcCodes: e.ugcCodes) ?? "Unknown area"
            let threats = [e.tornadoDetection, e.tornadoDamageThreat].compactMap { $0 }.map { "<span class=\"\(tornadoThreatClass($0))\">\(escape($0))</span>" }.joined(separator: " · ")
            return "<div class=\"weather-row\"><time class=\"weather-time\" title=\"\(escape(controlTime(e.touchedAt)))\" datetime=\"\(ISO8601DateFormatter().string(from: e.touchedAt))\">\(String(controlTime(e.touchedAt).dropFirst(11).prefix(5)))</time><div><div class=\"weather-event\">\(escape(e.eventName))</div><div class=\"weather-place\">\(escape(area))</div><div class=\"weather-threat\">\(threats)</div></div><span class=\"weather-lifecycle\">\(escape(e.state))</span></div>"
        }.joined()
        return moduleHead("NWS Activity", "Five most recently touched series · UTC", .nws) + (rows.isEmpty ? "<p class=\"empty\">No recently touched series.</p>" : "<div class=\"weather-list\">\(rows)</div>") + "<p class=\"module-note\">Recent activity is a bounded sample, not a national alert census.</p>"
    }

    static func deliveryOverview(_ d: OperatorDashboardDeliveryKPIsSectionResponse, _ a: OperatorDashboardAudienceTargetingSectionResponse, detail: Bool = false) -> String {
        let l = d.endToEndAlertLatency, p = d.apnsDeliverySuccessRate, c = a.freshTargetableInstallationCoverage, h = a.alertsWithGeographyAndH3Success
        return """
        \(moduleHead("Delivery & Targeting", "\(p.windowHours)h APNs window · current coverage", detail ? nil : .delivery))<div class="delivery-metrics">\(controlStat("Alert latency · p95", maybeDuration(l.p95Seconds.map { Int($0.rounded()) }), "\(l.successfulRevisionCount) successful revisions · \(l.windowHours)h"))\(controlStat("APNs success", maybePercent(p.successRate), "\(p.sentCount) sent / \(p.sentCount + p.failedCount) outcomes"))\(controlStat("Fresh coverage", maybePercent(c.targetableRate), "\(c.targetableInstallationCount) / \(c.activeSubscribedInstallationCount) active subscribed"))\(controlStat("Geography → H3", maybePercent(h.successRate), "\(h.successfulConversionCount) / \(h.geometryBearingRevisionCount) geometry revisions · \(h.windowHours)h"))</div><details><summary>Coverage & delivery context</summary><div class="detail-copy">Candidate-query eligible: \(c.candidateQueryEligibleInstallationCount) / \(c.activeSubscribedInstallationCount) (presence ≤\(formatDuration(c.hardStalePresenceThresholdSeconds))); fresh targetable: \(c.targetableInstallationCount) / \(c.activeSubscribedInstallationCount). These are distinct measures. APNs acceptance does not prove an alert was seen.</div></details>
        """
    }
}
