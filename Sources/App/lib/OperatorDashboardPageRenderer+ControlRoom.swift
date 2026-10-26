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

    static func healthItem(_ title: String, _ value: String, _ status: OperatorDashboardHealthState, _ summary: String, _ details: String = "", page: Page? = nil) -> String {
        """
        <div class="health-item health-\(status.rawValue)"><h3>\(escape(title))</h3><div class="health-reading"><strong>\(escape(value))</strong><span class="health-status">\(status.rawValue.capitalized)</span></div><p>\(escape(summary))</p>\(details.isEmpty ? "" : "<details class=\"health-details\"><summary>Details</summary><div class=\"detail-copy\">\(escape(details))</div></details>")\(page.map { "<p><a href=\"\($0.path)\">Inspect \($0.title) ↗</a></p>" } ?? "")</div>
        """
    }

    static func mesoSummary(_ m: SPCMesoIngestMetricResponse) -> String {
        "<p class=\"detail-copy\">" + escape("\(m.activeProductCount) active discussions · \(m.status.rawValue.capitalized) · Last success: \(controlTime(m.lastSuccessfulAt)). Active geometry H3 coverage: \(m.activeProductsWithH3Coverage) complete, \(m.activeProductsWithoutH3Coverage) missing. Latest issued: \(m.latestProductTitle ?? "n/a") · \(controlTime(m.latestProductIssuedAt)).") + "</p>"
    }

    static func mesoActivity(_ activity: StoredMesoActivity?) -> String {
        guard let activity else { return "<p class=\"empty\">Meso activity unavailable in this snapshot. Awaiting worker refresh.</p>" }
        let note = "<p class=\"module-note\">Issued within 48 hours plus currently active discussions · UTC · " + (activity.capped ? "Capped sample: up to 50 discussions, active products prioritized. " : "") + "Refreshed " + escape(controlTime(activity.refreshedAt)) + "</p>"
        if activity.entries.isEmpty { return note + "<p class=\"empty\">No active or recently issued discussions.</p>" }
        return note + activity.entries.map { e in
            let probability = e.watchProbability.map { "\($0.formatted(.number.grouping(.never).precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US"))))%" } ?? (e.watchProbabilityText.isEmpty ? "Unknown" : e.watchProbabilityText)
            var fields = [("Valid from", controlTime(e.validStart)), ("Valid until", controlTime(e.validEnd)), ("Product identity", e.productKey), ("Coverage", e.geometryAvailable ? (e.h3CoverageComplete ? "Geometry present · H3 complete" : "Geometry present · H3 missing") : "No geometry")]
            if let text = e.concerning, !text.isEmpty { fields.append(("Concerning / watch", text)) }
            if !e.watchProbabilityText.isEmpty { fields.append(("Watch source text", e.watchProbabilityText)) }
            if let wind = e.peakWindMPH { fields.append(("Peak wind", "\(wind) mph")) }
            if let hail = e.hailRangeInches { fields.append(("Hail", "\(hail.formatted(.number.grouping(.never).precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US")))) inches")) }
            if let tornado = e.tornadoStrength, !tornado.isEmpty { fields.append(("Tornado", tornado)) }
            let definitions = fields.map { "<div><dt>" + escape($0.0) + "</dt><dd>" + escape($0.1) + "</dd></div>" }.joined()
            let link = e.safeSourceURL.map { "<p><a href=\"" + escape($0) + "\">Original SPC product ↗</a></p>" } ?? ""
            return "<details class=\"metric-details\" data-disclosure-key=\"" + escape(e.productKey) + "\"><summary class=\"metric-summary\">" + escape("MD \(e.number) · \(e.status(asOf: activity.refreshedAt)) · \(e.areasAffected) · Issued \(controlTime(e.issued)) · Valid until \(controlTime(e.validEnd)) · Watch probability: \(probability)") + "</summary><dl class=\"definition-list\">" + definitions + "</dl><p class=\"detail-copy\" style=\"white-space:pre-wrap\">" + escape(e.summary) + "</p>" + link + "</details>"
        }.joined()
    }

    static func healthOverview(_ r: OperatorDashboardRedLightsSectionResponse, anvil: AnvilServiceObservation? = nil) -> String {
        let i = r.ingestFreshness, m = r.spcMesoIngest, b = r.pipelineBacklogAge, c = r.stuckClaimedRows, s = r.staleActiveSeriesCount, a = r.airQuality
        var findings: [String] = []
        if i.status == .warning { findings.append("Ingest delayed") }
        if m.status == .warning { findings.append("SPC meso delayed or failing") }
        if c.status == .critical { findings.append("\(c.count) stuck claims") }
        if s.status == .warning { findings.append("\(s.count) stale active series") }
        if a.status == .warning || a.status == .critical { findings.append(a.summary) }
        let anvilFinding = anvil.flatMap(anvilFindingSummary)
        if let anvilFinding { findings.append(anvilFinding) }
        let unknown = [i.status, m.status, b.status, c.status, s.status, a.status, anvil?.status ?? .unknown].filter { $0 == .unknown }.count
        let headline = findings.isEmpty ? "No classified red lights · \(unknown) unknown signals" : findings.joined(separator: " · ") + " need review"
        let tone = c.status == .critical || a.status == .critical || anvil?.status == .critical ? "danger" : (findings.isEmpty ? "muted" : "warning")
        let destination = c.status == .critical ? Page.delivery : (anvil?.status == .critical || anvilFinding != nil && m.status != .warning ? Page.models : (m.status == .warning ? Page.mesos : Page.nws))
        let airNowOnlyFinding = findings.count == 1 && (a.status == .warning || a.status == .critical)
        let inspectLink = airNowOnlyFinding ? "" : "<a href=\"\(destination.path)\">Inspect \(destination.title) ↗</a>"
        return """
        <div class="health-top \(findings.isEmpty ? "neutral" : "")"><div><div class="health-label">Red Lights</div><strong class="\(tone)">\(escape(headline))</strong></div>\(inspectLink)</div><div class="health-rail">
        \(healthItem("Ingest freshness", maybeDuration(i.timeSinceLastSuccessfulSweepSeconds), i.status, "\(i.recentSuccessCount) successes / \(i.recentFailureCount) failures", "Last success: \(controlTime(i.lastSuccessfulSweepAt)). Last attempt: \(controlTime(i.lastAttemptAt)). Last failure: \(controlTime(i.lastFailureAt)). Error: \(i.lastFailureMessage ?? "none")."))
        \(healthItem("SPC meso ingest", maybeDuration(m.lastAttemptAgeSeconds), m.status, "\(m.activeProductCount) active products · last attempt \(m.lastAttemptStatus ?? "unknown") · 10-minute cadence", "Last attempt: \(controlTime(m.lastAttemptAt)). Last success: \(controlTime(m.lastSuccessfulAt)). Latest accepted: \(m.latestProductTitle ?? "none") (\(m.latestProductKey ?? "n/a")), issued \(controlTime(m.latestProductIssuedAt)), valid \(controlTime(m.latestProductValidStart)) to \(controlTime(m.latestProductValidEnd)). Active geometry H3 coverage: \(m.activeProductsWithH3Coverage) complete, \(m.activeProductsWithoutH3Coverage) missing. Recent failures: \(m.recentFailureCount) total; transport/fetch \(m.fetchFailureCount), parse/reject \(m.parseRejectionCount), persistence \(m.persistenceFailureCount), H3 \(m.h3FailureCount), other \(m.otherFailureCount). Last error: \(m.lastFailureMessage ?? "none").", page: .mesos))
        \(healthItem("Air Quality / AirNow", a.status.rawValue.capitalized, a.status, a.summary, "Last real attempt: \(controlTime(a.dependency.lastAttemptAt)). Last HTTP success: \(controlTime(a.dependency.lastUpstreamSuccessAt)). Last usable AQI: \(controlTime(a.dependency.lastUsableAQIAt)). Consecutive failures: \(a.dependency.consecutiveFailures). Failure streak started: \(controlTime(a.dependency.failureStartedAt)). Duration: \(a.dependency.durationMilliseconds.map { "\($0) ms" } ?? "n/a"). Updated: \(controlTime(a.dependency.updatedAt))."))
        \(healthItem("Dispatch backlog", "\(b.pendingTargetDispatchCount + b.pendingNotificationDispatchCount)", b.status, "\(b.pendingTargetDispatchCount) target · \(b.pendingNotificationDispatchCount) notification rows", "Oldest target: \(maybeDuration(b.oldestPendingTargetDispatchAgeSeconds)) (\(controlTime(b.oldestPendingTargetDispatchCreatedAt))). Oldest notification: \(maybeDuration(b.oldestPendingNotificationDispatchAgeSeconds)) (\(controlTime(b.oldestPendingNotificationDispatchCreatedAt))). Pending queue handoffs, not delivery completions."))
        \(healthItem("Stuck claims", "\(c.count)", c.status, "Claim age threshold: \(formatDuration(c.thresholdSeconds))", "Oldest claim: \(maybeDuration(c.oldestClaimedAgeSeconds)) (\(controlTime(c.oldestClaimedCreatedAt)))."))
        \(healthItem("Stale active series", "\(s.count)", s.status, "Grace window: \(formatDuration(s.graceSeconds))"))\(anvil.flatMap(anvilFindingSummary) == nil ? "" : anvilHealthItem(anvil))</div>
        """
    }

    static func anvilFindingSummary(_ observation: AnvilServiceObservation) -> String? {
        switch observation.status {
        case .warning: "Anvil reachable · SHARPpy unavailable"
        case .critical: "Anvil unreachable after \(observation.consecutiveFailures) consecutive probes"
        case .healthy, .unknown: nil
        }
    }

    static func anvilHealthItem(_ observation: AnvilServiceObservation?) -> String {
        guard let observation, let summary = anvilFindingSummary(observation) else { return "" }
        let failure = observation.recentFailure.map { $0.rawValue } ?? "none"
        let identity = observation.version.map { "\($0) (revision \(observation.revision ?? "n/a"))" } ?? "n/a"
        return healthItem(
            "Anvil", observation.status.rawValue.capitalized, observation.status, summary,
            "Last successful SHARPpy import readiness: \(observation.sharppyAvailable.map { $0 ? "ready" : "unavailable" } ?? "unknown"), observed \(controlTime(observation.lastSuccessfulAt)). Last successful identity: \(identity). Last check: \(controlTime(observation.checkedAt)). Recent failure category: \(failure).",
            page: .models
        )
    }

    static func anvilOverview(_ observation: AnvilServiceObservation?, detail: Bool) -> String {
        let value = observation ?? .init()
        let current = value.status == .healthy || value.status == .warning
        let identity: String
        if current, let version = value.version {
            identity = "Version \(version) · revision \(value.revision ?? "n/a")"
        } else if let version = value.version {
            identity = "Last successful identity \(version) · revision \(value.revision ?? "n/a") · observed \(controlTime(value.lastSuccessfulAt))"
        } else {
            identity = "No successful identity recorded"
        }
        let readiness: String
        if value.status == .healthy || value.status == .warning {
            readiness = value.sharppyAvailable.map { $0 ? "SHARPpy import ready" : "SHARPpy import unavailable" } ?? "SHARPpy readiness unknown"
        } else if let available = value.sharppyAvailable {
            readiness = "Last successful SHARPpy import was \(available ? "ready" : "unavailable")"
        } else {
            readiness = "SHARPpy readiness unknown"
        }
        let summary = "Anvil · \(value.status.rawValue.capitalized) · \(readiness) · \(identity) · Checked \(controlTime(value.checkedAt))"
        if detail {
            let failure = value.recentFailure.map { $0.rawValue } ?? "none"
            return "<div class=\"anvil-observation\"><p class=\"module-note \(value.status == .warning ? "warning" : value.status == .critical ? "danger" : "")\"><strong>Anvil · \(escape(value.status.rawValue.capitalized))</strong> · \(escape(readiness))</p><p class=\"module-note\">\(escape(identity))</p><p class=\"module-note\">Last check: \(escape(controlTime(value.checkedAt))) · Last successful observation: \(escape(controlTime(value.lastSuccessfulAt))) · Recent failure category: \(escape(failure))</p></div>"
        }
        let tone = value.status == .healthy ? "good" : value.status == .warning ? "warning" : value.status == .critical ? "danger" : "muted"
        return "<p class=\"module-note anvil-status\"><strong class=\"\(tone)\">\(escape(summary))</strong></p>"
    }

    static func modelOverview(_ m: OperatorDashboardModelArtifactsSectionResponse, anvil: AnvilServiceObservation? = nil, detail: Bool = false) -> String {
        let r = m.pressureArtifactReadiness, c = m.pressureArtifactCatalog
        let outcome = pressureArtifactOutcome(r.selectionOutcome)
        let tone = pressureArtifactOutcomeClass(r.selectionOutcome) ?? "muted"
        let catalog = [("Ready", c.readyCount), ("Warming", c.warmingCount), ("Pending", c.pendingCount), ("Failed", c.failedCount)]
        let counts = catalog.map { name, count in "<div><strong>\(c.refreshedAt == nil ? "n/a" : String(count))</strong><span>\(name)</span></div>" }.joined()
        let track = c.refreshedAt == nil ? "" : catalog.filter { $0.1 > 0 }.map { name, count in "<i class=\"catalog-\(name.lowercased())\" style=\"flex:\(count)\"></i>" }.joined()
        return """
        \(moduleHead("Model Pipeline", "HRRR · pressure artifacts", detail ? nil : .models))<div class="model-current"><span class="ready-mark \(tone)" aria-hidden="true">\(r.selectionOutcome == .exact ? "✓" : "—")</span><div><div class="artifact-title">\(r.selectionOutcome == .exact ? "Current artifact ready" : "Pressure artifact \(outcome.lowercased())")</div><div class="artifact-sub">\(escape(controlTime(r.runTime))) / F\(r.forecastHour.map(String.init) ?? "—") · valid \(escape(controlTime(r.validTime)))</div></div><span class="badge \(tone)">\(outcome)</span></div><div class="catalog">\(counts)</div><div class="catalog-track" aria-hidden="true">\(track)</div><p class="module-note">Checked \(escape(controlTime(r.lastCheckedAt ?? r.updatedAt))) · \(c.refreshedAt == nil ? "Catalog unavailable" : "\(c.stuckWarmingCount) stuck warming · \(c.expiredCount) expired catalog rows")</p><p class="module-note">Pressure artifact catalog history retained for 60 days</p>\([r.readinessReason, r.errorSummary, c.stuckReason].compactMap { $0 }.map { "<p class=\"module-note warning\">\(escape($0))</p>" }.joined())\(anvilOverview(anvil, detail: detail))
        """
    }

    static func usageOverview(_ g: OperatorDashboardGrowthUsageSectionResponse, detail: Bool = false) -> String {
        let growth = g.installationGrowth, activity = g.installationActivity
        let returningCount = activity.refreshedAt == nil ? "n/a" : String(activity.returningThisMonthInstallationCount)
        return """
        \(moduleHead("Usage & Installations", "Explicit foreground activity · UTC windows", detail ? nil : .installations))<div class="usage-metrics">\(controlStat("Current", growth.refreshedAt == nil ? "n/a" : String(growth.currentInstallationCount), "installations"))\(controlStat("Today", activity.refreshedAt == nil ? "n/a" : String(activity.dailyActiveInstallationCount), "DAU"))\(controlStat("This month", activity.refreshedAt == nil ? "n/a" : String(activity.monthlyActiveInstallationCount), "MAU"))\(controlStat("New this month", growth.refreshedAt == nil ? "n/a" : String(growth.newThisMonthCount), growth.monthlyGrowth.last.map { formatMonth($0.monthStart) } ?? "n/a"))</div><p class="usage-returning"><strong>Returning this month:</strong> \(escape(returningCount)) <span>registered before current UTC month</span></p><div class="usage-foot"><span><strong>\(growth.refreshedAt == nil ? "n/a" : String(growth.currentlySubscribedCount))</strong> subscribed</span><span class="muted">Activity updated \(escape(controlTime(activity.refreshedAt)))</span></div><p class="module-note">Installations, not people. Background contact is not DAU.</p>
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
        let rows: String = n.entries.prefix(OperatorDashboardConfig.touchedSeriesOverviewLimit).map { e -> String in
            let area = operatorDashboardAreaDescription(areaDescription: e.areaDescription, ugcCodes: e.ugcCodes) ?? "Unknown area"
            let threats = [e.tornadoDetection, e.tornadoDamageThreat].compactMap { $0 }.map { "<span class=\"\(tornadoThreatClass($0))\">\(escape($0))</span>" }.joined(separator: " · ")
            return "<div class=\"weather-row\"><time class=\"weather-time\" title=\"\(escape(controlTime(e.touchedAt)))\" datetime=\"\(ISO8601DateFormatter().string(from: e.touchedAt))\">\(String(controlTime(e.touchedAt).dropFirst(11).prefix(5)))</time><div><div class=\"weather-event\">\(escape(e.eventName))</div><div class=\"weather-place\">\(escape(area))</div><div class=\"weather-threat\">\(threats)</div></div><span class=\"weather-lifecycle\">\(escape(e.state))</span></div>"
        }.joined()
        return moduleHead("NWS Activity", "Five most recently touched series · UTC", .nws) + (rows.isEmpty ? "<p class=\"empty\">No recently touched series.</p>" : "<div class=\"weather-list\">\(rows)</div>") + "<p class=\"module-note\">Recent activity is a bounded sample, not a national alert census.</p>"
    }

    static func deliveryOverview(_ d: OperatorDashboardDeliveryKPIsSectionResponse, _ a: OperatorDashboardAudienceTargetingSectionResponse, detail: Bool = false) -> String {
        let l = d.endToEndAlertLatency, p = d.apnsDeliverySuccessRate, c = a.freshTargetableInstallationCoverage, h = a.alertsWithGeographyAndH3Success
        return """
        \(moduleHead("Delivery & Targeting", "\(p.windowHours)h APNs window · current coverage", detail ? nil : .delivery))<div class="delivery-metrics">\(controlStat("Pipeline latency · p95", maybeDuration(l.p95Seconds.map { Int($0.rounded()) }), "p50 \(maybeDuration(l.p50Seconds.map { Int($0.rounded()) })) · max \(maybeDuration(l.maxSeconds.map { Int($0.rounded()) })) · \(l.sampleCount) samples · \(l.windowHours)h"))\(controlStat("APNs success", maybePercent(p.successRate), "\(p.sentCount) sent / \(p.sentCount + p.failedCount) outcomes"))\(controlStat("Fresh coverage", maybePercent(c.targetableRate), "\(c.targetableInstallationCount) / \(c.activeSubscribedInstallationCount) active subscribed"))\(controlStat("Geography → H3", maybePercent(h.successRate), "\(h.successfulConversionCount) / \(h.geometryBearingRevisionCount) geometry revisions · \(h.windowHours)h"))</div><details><summary>Coverage & delivery context</summary><div class="detail-copy">Candidate-query eligible: \(c.candidateQueryEligibleInstallationCount) / \(c.activeSubscribedInstallationCount) (presence ≤\(formatDuration(c.hardStalePresenceThresholdSeconds))); fresh targetable: \(c.targetableInstallationCount) / \(c.activeSubscribedInstallationCount). These are distinct measures. APNs acceptance does not prove an alert was seen.</div></details>
        """
    }
}
