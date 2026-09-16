import Foundation

extension OperatorDashboardPageRenderer {
    static func slot(_ id: String, content: String) -> String {
        """
        <div id="\(escape(id))" class="live-slot">\(content)</div>
        """
    }

    static func ingestCard(_ metric: IngestFreshnessMetricResponse) -> String {
        card(
            title: "Ingest freshness",
            primary: maybeDuration(metric.timeSinceLastSuccessfulSweepSeconds),
            status: metric.status,
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Last success", maybeDate(metric.lastSuccessfulSweepAt)),
                ("Last attempt", maybeDate(metric.lastAttemptAt)),
                ("Recent", "\(metric.recentSuccessCount) success / \(metric.recentFailureCount) failure"),
                ("Last error", metric.lastFailureMessage ?? "none")
            ]
        )
    }

    static func pipelineBacklogCard(_ metric: PipelineBacklogMetricResponse) -> String {
        card(
            title: "Pipeline backlog age",
            primary: "Target \(maybeDuration(metric.oldestPendingTargetDispatchAgeSeconds))",
            status: metric.status,
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Pending target rows", "\(metric.pendingTargetDispatchCount)"),
                ("Oldest target row", maybeDate(metric.oldestPendingTargetDispatchCreatedAt)),
                ("Notification backlog", maybeDuration(metric.oldestPendingNotificationDispatchAgeSeconds)),
                ("Pending notification rows", "\(metric.pendingNotificationDispatchCount)")
            ]
        )
    }

    static func stuckClaimedCard(_ metric: StuckClaimedRowsMetricResponse) -> String {
        card(
            title: "Stuck claimed rows",
            primary: "\(metric.count)",
            status: metric.status,
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Threshold", maybeDuration(metric.thresholdSeconds)),
                ("Oldest claim age", maybeDuration(metric.oldestClaimedAgeSeconds)),
                ("Oldest claim", maybeDate(metric.oldestClaimedCreatedAt))
            ]
        )
    }

    static func staleSeriesCard(_ metric: StaleActiveSeriesMetricResponse) -> String {
        card(
            title: "Stale active series",
            primary: "\(metric.count)",
            status: metric.status,
            refreshedAt: metric.refreshedAt,
            lines: [("Grace window", maybeDuration(metric.graceSeconds))]
        )
    }

    static func knownInstallationsCard(_ metric: InstallationGrowthMetricResponse) -> String {
        let previousMonthTotal = metric.monthlyGrowth.dropLast().last?.cumulativeInstallationCount
        return card(
            title: "Known Installations",
            primary: "\(metric.knownInstallationCount)",
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Through last month", previousMonthTotal.map(String.init) ?? "n/a"),
                ("Currently subscribed", "\(metric.currentlySubscribedCount)")
            ]
        )
    }

    static func newInstallationsCard(_ metric: InstallationGrowthMetricResponse) -> String {
        card(
            title: "New This Month",
            primary: "\(metric.newThisMonthCount)",
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Month", metric.monthlyGrowth.last.map { formatMonth($0.monthStart) } ?? "n/a")
            ]
        )
    }

    static func recentServerActivityCard(_ metric: InstallationGrowthMetricResponse) -> String {
        card(
            title: "Seen Last 24h — Server Activity",
            primary: "\(metric.seenLast24HoursCount)",
            refreshedAt: metric.refreshedAt,
            showDetails: false,
            lines: [
                ("Share of known", maybePercent(metric.seenLast24HoursRate)),
                ("Interpretation", "Operational activity, not DAU")
            ]
        )
    }

    static func activeTodayCard(_ metric: InstallationActivityMetricResponse) -> String {
        card(
            title: "Active Today",
            primary: "\(metric.dailyActiveInstallationCount)",
            refreshedAt: metric.refreshedAt,
            showDetails: false,
            lines: [
                ("Metric", "DAU"),
                ("Source", "Explicit foreground activity")
            ]
        )
    }

    static func activeThisMonthCard(_ metric: InstallationActivityMetricResponse) -> String {
        card(
            title: "Active This Month",
            primary: "\(metric.monthlyActiveInstallationCount)",
            refreshedAt: metric.refreshedAt,
            showDetails: false,
            lines: [
                ("Metric", "MAU"),
                ("Source", "Explicit foreground activity")
            ]
        )
    }

    static func installationActivityStateTable(_ metric: InstallationActivityMetricResponse) -> String {
        let body = metric.stateBreakdown.isEmpty
            ? #"<div class="empty">No foreground activity this month.</div>"#
            : """
              <div class="table-wrap">
                <table class="inline-mobile-table">
                  <thead><tr><th>State</th><th>Today</th><th>This Month</th></tr></thead>
                  <tbody>
                    \(metric.stateBreakdown.map(installationActivityStateRow).joined())
                  </tbody>
                </table>
              </div>
            """

        return """
        <div class="card table-card">
          <div class="table-card__header">
            <h3>Active Installations by State</h3>
            <div class="subtle">Current/last-known operational state · Refreshed \(escape(maybeDate(metric.refreshedAt)))</div>
          </div>
          \(body)
        </div>
        """
    }

    static func installationActivityStateRow(_ entry: InstallationActivityStateResponse) -> String {
        return """
        <tr>
          <td data-label="State">\(escape(entry.state))</td>
          <td data-label="Today">\(entry.activeTodayCount)</td>
          <td data-label="This Month">\(entry.activeThisMonthCount)</td>
        </tr>
        """
    }

    static func installationGrowthTable(_ metric: InstallationGrowthMetricResponse) -> String {
        let body = metric.monthlyGrowth.isEmpty
            ? #"<div class="empty">No installation growth history.</div>"#
            : """
              <div class="table-wrap">
                <table class="stream-table inline-mobile-table">
                  <thead><tr><th>Month</th><th>New installations</th><th>Cumulative total</th></tr></thead>
                  <tbody>
                    \(metric.monthlyGrowth.map(installationGrowthRow).joined())
                  </tbody>
                </table>
              </div>
            """

        return """
        <div class="card table-card">
          <div class="table-card__header">
            <h3>Monthly Installation Growth</h3>
            <div class="subtle">Refreshed \(escape(maybeDate(metric.refreshedAt)))</div>
          </div>
          \(body)
        </div>
        """
    }

    static func installationGrowthRow(_ entry: MonthlyInstallationGrowthResponse) -> String {
        return """
        <tr>
          <td data-label="Month">\(escape(formatMonth(entry.monthStart)))</td>
          <td data-label="New installations">\(entry.newInstallationCount)</td>
          <td data-label="Cumulative total">\(entry.cumulativeInstallationCount)</td>
        </tr>
        """
    }

    static func installationFootprintTable(
        _ entries: [InstallationFootprintEntryResponse],
        refreshedAt: Date?
    ) -> String {
        let body = entries.isEmpty
            ? #"<div class="empty">No installation presence rows available.</div>"#
            : """
              <div class="table-wrap footprint-table-wrap" role="region" aria-label="Installation footprint" tabindex="0">
                <table class="stream-table footprint-table inline-mobile-table">
                  <thead><tr><th>Coarse location</th><th>App version</th><th>Auth</th><th>Presence age</th><th>State</th><th>Eligibility</th></tr></thead>
                  <tbody>
                    \(entries.map(installationFootprintRow).joined())
                  </tbody>
                </table>
              </div>
            """

        return """
        <div class="card table-card">
          <div class="table-card__header">
            <h3>Installation Footprint</h3>
            <div class="subtle">Freshest presence first · \(entries.count) of \(OperatorDashboardConfig.installationFootprintLimit) rows · Refreshed \(escape(maybeDate(refreshedAt)))</div>
          </div>
          \(body)
        </div>
        """
    }

    static func installationFootprintRow(_ entry: InstallationFootprintEntryResponse) -> String {
        let eligibility = entry.candidateQueryEligible ? "Eligible" : entry.ineligibilityReason ?? "Ineligible"
        let eligibilityClass = entry.candidateQueryEligible ? "footprint-eligible" : "footprint-ineligible"
        let state = entry.isActive ? (entry.isSubscribed ? "Active / subscribed" : "Active / paused") : "Inactive"
        return """
        <tr>
          <td data-label="Coarse location">\(escape(entry.locationLabel))</td>
          <td data-label="App version">\(escape(entry.appVersion))</td>
          <td data-label="Auth">\(escape(entry.locationAuth))</td>
          <td data-label="Presence age" class="presence-age">\(escape(maybeDuration(entry.presenceAgeSeconds)))</td>
          <td data-label="State">\(escape(state))</td>
          <td data-label="Eligibility"><span class="pill \(eligibilityClass)">\(escape(eligibility))</span></td>
        </tr>
        """
    }

    static func latencyCard(_ metric: EndToEndLatencyMetricResponse) -> String {
        compactMetricCard(
            title: "End-to-end alert latency p95",
            primary: maybeDuration(metric.p95Seconds.flatMap { Int($0.rounded()) }),
            refreshedAt: metric.refreshedAt,
            details: [
                ("Window", "\(metric.windowHours)h"),
                ("Successful revisions", "\(metric.successfulRevisionCount)")
            ]
        )
    }

    static func apnsSuccessCard(_ metric: APNsDeliveryMetricResponse) -> String {
        compactMetricCard(
            title: "APNs delivery success rate",
            primary: maybePercent(metric.successRate),
            refreshedAt: metric.refreshedAt,
            details: [
                ("Sent", "\(metric.sentCount)"),
                ("Failed", "\(metric.failedCount)"),
                ("Top failures", joinedReasons(metric.topFailureReasons))
            ]
        )
    }

    static func noOpCard(_ metric: SendNoOpsMetricResponse) -> String {
        compactMetricCard(
            title: "Send no-op rate by reason",
            primary: maybePercent(metric.noOpRate),
            refreshedAt: metric.refreshedAt,
            details: [
                ("Total attempts", "\(metric.totalAttemptCount)"),
                ("No-op attempts", "\(metric.noOpAttemptCount)"),
                ("Reasons", joinedReasons(metric.reasons))
            ]
        )
    }

    static func zeroCandidateCard(_ metric: ZeroCandidateRateMetricResponse) -> String {
        compactMetricCard(
            title: "Zero-candidate revision rate",
            primary: maybePercent(metric.zeroCandidateRate),
            refreshedAt: metric.refreshedAt,
            details: [
                ("Candidate-resolution attempts", "\(metric.candidateResolutionAttemptCount)"),
                ("Zero-candidate attempts", "\(metric.zeroCandidateAttemptCount)")
            ]
        )
    }

    static func coverageCard(_ metric: TargetableCoverageMetricResponse) -> String {
        compactMetricCard(
            title: "Fresh targetable coverage",
            primary: maybePercent(metric.targetableRate),
            refreshedAt: metric.refreshedAt,
            summary: "Fresh targetable \(metric.targetableInstallationCount) / \(metric.activeSubscribedInstallationCount) · Eligible ≤24h \(metric.candidateQueryEligibleInstallationCount) / \(metric.activeSubscribedInstallationCount)",
            details: [
                ("Eligible ≤24h", "\(metric.candidateQueryEligibleInstallationCount) / \(metric.activeSubscribedInstallationCount)"),
                ("Excluded >24h", "\(metric.hardStalePresenceCount)"),
                ("Fresh targetable (≤6h)", "\(metric.targetableInstallationCount) / \(metric.activeSubscribedInstallationCount)"),
                ("Missing token", "\(metric.lossBreakdown.missingDeviceTokenCount)"),
                ("Stale install", "\(metric.lossBreakdown.staleInstallationHeartbeatCount)"),
                ("Stale presence", "\(metric.lossBreakdown.stalePresenceCount)"),
                ("Missing targeting", "\(metric.lossBreakdown.missingTargetingDataCount)")
            ]
        )
    }

    static func h3Card(_ metric: H3DerivationMetricResponse) -> String {
        compactMetricCard(
            title: "Geography to H3 conversion",
            primary: maybePercent(metric.successRate),
            refreshedAt: metric.refreshedAt,
            details: [
                ("Geometry-bearing revisions", "\(metric.geometryBearingRevisionCount)"),
                ("Successful conversions", "\(metric.successfulConversionCount)"),
                ("p95 conversion", maybeDuration(metric.p95ConversionSeconds.flatMap { Int($0.rounded()) }))
            ]
        )
    }

    static func pressureArtifactReadinessCard(_ metric: PressureArtifactReadinessMetricResponse?) -> String {
        let metric = metric ?? .init(refreshedAt: nil, renderedAt: .now, metric: .init())
        var details: [(String, String)] = [
            ("Catalog status", metric.status ?? "n/a"),
            ("Valid time", maybeDate(metric.validTime)),
            ("Valid-time age", maybeDuration(metric.validTimeAgeSeconds)),
            ("Run / FH", pressureArtifactRunAndForecast(metric.runTime, metric.forecastHour)),
            ("Field-set version", metric.fieldSetVersion ?? "n/a"),
            ("Size", maybeByteSize(metric.byteSize)),
            ("Source", metric.source ?? "n/a"),
            ("Last checked / updated", maybeDate(metric.lastCheckedAt ?? metric.updatedAt))
        ]
        if let readinessReason = metric.readinessReason {
            details.insert(("Readiness reason", readinessReason), at: 1)
        }
        if let errorSummary = metric.errorSummary {
            details.append(("Error", errorSummary))
        }

        let summary = [
            metric.validTime.map { "Valid \(maybeDate($0))" },
            pressureArtifactRunAndForecast(metric.runTime, metric.forecastHour),
            "checked \(maybeDate(metric.lastCheckedAt ?? metric.updatedAt))"
        ].compactMap { $0 }.joined(separator: " · ")

        return compactMetricCard(
            title: "Pressure Artifact",
            primary: pressureArtifactOutcome(metric.selectionOutcome),
            primaryClass: pressureArtifactOutcomeClass(metric.selectionOutcome),
            refreshedAt: metric.refreshedAt,
            summary: summary,
            details: details,
            expanded: metric.selectionOutcome != .exact || metric.readinessReason != nil || metric.errorSummary != nil
        )
    }

    static func pressureArtifactCatalogCard(_ metric: PressureArtifactCatalogMetricResponse?) -> String {
        let metric = metric ?? .init(refreshedAt: nil, metric: .init())
        return compactMetricCard(
            title: "Catalog Summary",
            primary: "\(metric.readyCount) ready",
            refreshedAt: metric.refreshedAt,
            summary: "Ready \(metric.readyCount) · Warming \(metric.warmingCount) · Pending \(metric.pendingCount) · Failed \(metric.failedCount)",
            details: [
                ("Total", "\(metric.totalCount)"),
                ("Pending", "\(metric.pendingCount)"),
                ("Oldest pending", maybeDuration(metric.oldestPendingAgeSeconds)),
                ("Warming", "\(metric.warmingCount)"),
                ("Stuck warming", "\(metric.stuckWarmingCount)"),
                ("Oldest expired lease", maybeDuration(metric.oldestExpiredWarmingLeaseAgeSeconds)),
                ("Pipeline status", metric.stuckReason ?? "Healthy"),
                ("Failed", "\(metric.failedCount)"),
                ("Expired", "\(metric.expiredCount)"),
                ("Most recent failure", maybeDate(metric.mostRecentFailureAt)),
                ("Most recent failure reason", metric.mostRecentFailureSummary ?? "none")
            ],
            expanded: metric.stuckReason != nil
        )
    }

    static func recentPressureArtifactsTable(_ metric: RecentPressureArtifactEntriesResponse?) -> String {
        let metric = metric ?? .init(refreshedAt: nil, entries: [])
        let body: String
        if metric.entries.isEmpty {
            body = #"<div class="empty">No current-version pressure artifacts.</div>"#
        } else {
            body = """
            <div class="table-wrap">
            <table class="stream-table pressure-artifact-table inline-mobile-table">
              <thead>
                <tr>
                  <th>Valid time</th>
                  <th>Run / FH</th>
                  <th>Status</th>
                  <th>Size</th>
                  <th>Error</th>
                </tr>
              </thead>
              <tbody>
                \(metric.entries.map(renderPressureArtifactRow).joined())
              </tbody>
            </table>
            </div>
            """
        }

        return """
        <div class="card table-card">
          <div class="table-card__header">
            <h3>Recent pressure artifacts</h3>
            <div class="subtle">Refreshed \(escape(maybeDate(metric.refreshedAt)))</div>
          </div>
          \(body)
        </div>
        """
    }

    static func renderPressureArtifactRow(_ entry: PressureArtifactEntryResponse) -> String {
        return """
        <tr>
          <td data-label="Valid time">\(escape(maybeDate(entry.validTime)))</td>
          <td data-label="Run / FH">\(escape(pressureArtifactRunAndForecast(entry.runTime, entry.forecastHour)))</td>
          <td data-label="Status"><span class="pill \(escape(statusClass(entry.status)))">\(escape(pressureArtifactStatus(entry.status)))</span></td>
          <td data-label="Size" class="mono">\(escape(maybeByteSize(entry.byteSize)))</td>
          <td data-label="Error"><span class="diagnostic-truncate">\(escape(entry.errorSummary ?? "none"))</span></td>
        </tr>
        """
    }

    static func recentDebugTable(_ metric: RecentNotificationDebugEntriesResponse) -> String {
        let body: String
        if metric.entries.isEmpty {
            body = #"<div class="empty">No recent notification debug entries.</div>"#
        } else {
            body = """
            <div class="table-wrap">
            <table class="stream-table inline-mobile-table">
              <thead>
                <tr>
                  <th>Time</th>
                  <th>Alert</th>
                  <th>Mode / reason</th>
                  <th>Message</th>
                  <th>Outcome</th>
                </tr>
              </thead>
              <tbody>
                \(metric.entries.map(renderDebugRow).joined())
              </tbody>
            </table>
            </div>
            """
        }

        return """
        <div class="card table-card">
          <div class="table-card__header">
            <h3>Recent notification debug entries</h3>
            <div class="subtle">Refreshed \(escape(maybeDate(metric.refreshedAt)))</div>
          </div>
          \(body)
        </div>
        """
    }

    static func touchedSeriesTable(_ metric: LastTouchedSeriesResponse) -> String {
        let body: String
        if metric.entries.isEmpty {
            body = #"<div class="empty">No recently touched series.</div>"#
        } else {
            body = """
            <div class="table-wrap">
            <table class="stream-table inline-mobile-table">
              <thead>
                <tr>
                  <th>Touched</th>
                  <th>Alert</th>
                  <th>Geography</th>
                  <th>State</th>
                  <th>Tornado detection</th>
                  <th>Tornado damage threat</th>
                </tr>
              </thead>
              <tbody>
                \(metric.entries.map(renderTouchedSeriesRow).joined())
              </tbody>
            </table>
            </div>
            """
        }

        return """
        <div class="card table-card">
          <div class="table-card__header">
            <h3>Last 5 touched series</h3>
            <div class="subtle">Refreshed \(escape(maybeDate(metric.refreshedAt)))</div>
          </div>
          \(body)
        </div>
        """
    }

    static func renderDebugRow(_ entry: RecentNotificationDebugEntryResponse) -> String {
        """
        <tr>
          <td data-label="Time">\(escape(formatDate(entry.createdAt)))</td>
          <td data-label="Alert">
            <div>\(escape(entry.eventName))</div>
            <div class="diagnostic-mono">\(escape(entry.seriesID.uuidString))</div>
          </td>
          <td data-label="Mode / reason">
            <span class="pill">\(escape(entry.mode))</span>
            \(diagnosticDisclosure("\(entry.reason) / \(entry.recordKind)"))
          </td>
          <td data-label="Message">
            <div><strong>\(escape(entry.title))</strong></div>
            <div class="subtle">\(escape(entry.subtitle))</div>
            \(diagnosticDisclosure(entry.body))
          </td>
          <td data-label="Outcome">
            <div>\(escape(entry.ledgerStatus ?? "preview"))</div>
            \(diagnosticDisclosure(entry.apnsErrorCode ?? "none"))
          </td>
        </tr>
        """
    }

    static func renderTouchedSeriesRow(_ entry: TouchedSeriesEntryResponse) -> String {
        let area = operatorDashboardAreaDescription(areaDescription: entry.areaDescription, ugcCodes: entry.ugcCodes) ?? "Unknown area"
        return """
        <tr>
          <td data-label="Touched">\(escape(formatDate(entry.touchedAt)))</td>
          <td data-label="Alert">
            <div>\(escape(entry.eventName))</div>
            <div class="diagnostic-mono">\(escape(entry.seriesID.uuidString))</div>
            <div class="diagnostic-mono">\(escape(entry.currentRevisionUrn))</div>
          </td>
          <td data-label="Geography">
            <div>\(escape(area))</div>
            <div class="diagnostic-mono">UGC: \(escape(joinedCodes(entry.ugcCodes)))</div>
          </td>
          <td data-label="State"><span class="pill \(escape(seriesStateClass(entry.state)))">\(escape(entry.state))</span></td>
          <td data-label="Tornado detection"><span class="\(escape(tornadoThreatClass(entry.tornadoDetection)))">\(escape(entry.tornadoDetection ?? "none"))</span></td>
          <td data-label="Tornado damage"><span class="\(escape(tornadoThreatClass(entry.tornadoDamageThreat)))">\(escape(entry.tornadoDamageThreat ?? "none"))</span></td>
        </tr>
        """
    }

    static func card(
        title: String,
        primary: String,
        primaryClass: String? = nil,
        status: OperatorDashboardHealthState? = nil,
        refreshedAt: Date?,
        showDetails: Bool = true,
        lines: [(String, String)]
    ) -> String {
        let primaryClassAttribute = primaryClass.map { " \($0)" } ?? ""
        let cardClass = status.map { "card health-card health-\($0.rawValue)" } ?? "card"
        let statusDot = status.map { _ in
            "<span class=\"health-dot\" aria-hidden=\"true\"></span>"
        } ?? ""
        let statusText = status.map { "<span class=\"health-status\">\(escape($0.rawValue.capitalized))</span>" } ?? ""
        let isExpanded = status == .warning || status == .critical || status == .unknown
        let summary = lines.first.map { "\($0.0): \($0.1)" }
        let details = showDetails ? lines.dropFirst().map { "<li><span>\(escape($0.0))</span><strong>\(escape($0.1))</strong></li>" }.joined() : ""
        let disclosure = details.isEmpty ? "" : """
          <details class="metric-details"\(isExpanded ? " open" : "")>
            <summary>Details</summary>
            <ul class="meta-list">\(details)</ul>
          </details>
        """
        return """
        <div class="\(cardClass)">
          <div class="card-heading"><h3>\(escape(title))</h3><span class="health-indicator">\(statusText)\(statusDot)</span></div>
          <div class="primary\(primaryClassAttribute)">\(escape(primary))</div>
          \(summary.map { "<div class=\"metric-summary\">\(escape($0))</div>" } ?? "")
          \(disclosure)
        </div>
        """
    }

    static func compactMetricCard(
        title: String,
        primary: String,
        primaryClass: String? = nil,
        refreshedAt: Date?,
        summary: String? = nil,
        details: [(String, String)],
        expanded: Bool = false
    ) -> String {
        let primaryClassAttribute = primaryClass.map { " \($0)" } ?? ""
        let disclosure = details.isEmpty ? "" : """
          <details class="metric-details"\(expanded ? " open" : "")>
            <summary>Details</summary>
            <ul class="meta-list">
              \(details.map { "<li><span>\(escape($0.0))</span><strong>\(escape($0.1))</strong></li>" }.joined())
            </ul>
          </details>
        """
        return """
        <div class="card compact-card">
          <div class="card-heading"><h3>\(escape(title))</h3></div>
          <div class="primary\(primaryClassAttribute)">\(escape(primary))</div>
          \(summary.map { "<div class=\"metric-summary\">\(escape($0))</div>" } ?? "")
          <div class="subtle">Refreshed \(escape(maybeDate(refreshedAt)))</div>
          \(disclosure)
        </div>
        """
    }

    static func joinedReasons(_ reasons: [ReasonBreakdownResponse]) -> String {
        guard reasons.isEmpty == false else { return "none" }
        return reasons.map { "\($0.reason) (\($0.count))" }.joined(separator: ", ")
    }

    static func joinedCodes(_ codes: [String]) -> String {
        guard codes.isEmpty == false else { return "none" }
        return codes.joined(separator: ", ")
    }

    static func diagnosticDisclosure(_ value: String, className: String = "diagnostic-copy") -> String {
        """
        <details class="diagnostic-disclosure">
          <summary class="\(className)">\(escape(value))</summary>
          <div class="diagnostic-full">\(escape(value))</div>
        </details>
        """
    }

    static func seriesStateClass(_ state: String) -> String {
        switch state.lowercased() {
        case "active": return "accent"
        case "warning", "pending": return "warn"
        default: return ""
        }
    }

    static func tornadoThreatClass(_ value: String?) -> String {
        switch value?.lowercased() {
        case "observed", "confirmed", "considerable", "catastrophic": return "danger"
        case "possible", "probable", "radar indicated", "significant": return "warn"
        default: return ""
        }
    }

    static func pressureArtifactOutcome(_ outcome: PressureArtifactReadinessSelectionOutcome?) -> String {
        guard let outcome else { return "NO DATA" }
        return outcome == .exact ? "READY" : outcome.rawValue.uppercased()
    }

    static func pressureArtifactOutcomeClass(_ outcome: PressureArtifactReadinessSelectionOutcome?) -> String? {
        guard let outcome else { return nil }
        switch outcome {
        case .exact:
            return "accent"
        case .stale:
            return "warn"
        case .unavailable:
            return "danger"
        }
    }

    static func pressureArtifactStatus(_ status: String?) -> String {
        guard let status, status.isEmpty == false else { return "NO DATA" }
        return status.uppercased()
    }

    static func pressureArtifactRunAndForecast(_ runTime: Date?, _ forecastHour: Int?) -> String {
        guard let runTime else { return "n/a" }
        guard let forecastHour else { return formatDate(runTime) }
        return "\(formatDate(runTime)) / FH \(forecastHour)"
    }

    static func maybeByteSize(_ byteSize: Int64?) -> String {
        guard let byteSize else { return "n/a" }
        return formatByteSize(byteSize)
    }

    static func maybeDate(_ date: Date?) -> String {
        guard let date else { return "n/a" }
        return formatDate(date)
    }

    static func maybeDuration(_ seconds: Int?) -> String {
        guard let seconds else { return "n/a" }
        return formatDuration(seconds)
    }

    static func maybePercent(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return formatPercent(value)
    }

    static func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let dayDifference = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0

        let timeText = DateFormatter.dashboardTimeFormatter.string(from: date)
        if dayDifference <= 0 {
            return "Today \(timeText)"
        }

        if dayDifference == 1 {
            return "Yesterday \(timeText)"
        }

        return "\(dayDifference) days ago \(timeText)"
    }

    static func formatPercent(_ value: Double) -> String {
        let percent = value * 100
        return String(format: "%.1f%%", percent)
    }

    static func formatMonth(_ date: Date) -> String {
        DateFormatter.dashboardMonthFormatter.string(from: date)
    }

    static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }

        if seconds < 3_600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }

        if seconds < 86_400 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return "\(hours)h \(minutes)m"
        }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        return "\(days)d \(hours)h"
    }

    static func formatByteSize(_ byteSize: Int64) -> String {
        if byteSize < 1_024 {
            return "\(byteSize) B"
        }

        let units = ["KiB", "MiB", "GiB", "TiB"]
        var scaled = Double(byteSize) / 1_024.0
        var unitIndex = 0
        while scaled >= 1_024.0, unitIndex < units.count - 1 {
            scaled /= 1_024.0
            unitIndex += 1
        }

        let formatted = scaled >= 10 || unitIndex == 0
            ? String(format: "%.0f", scaled)
            : String(format: "%.1f", scaled)
        return "\(formatted) \(units[unitIndex])"
    }

    static func statusClass(_ status: String?) -> String {
        switch status?.lowercased() {
        case "ready":
            return "accent"
        case "pending", "warming":
            return "warn"
        case "failed", "expired":
            return "danger"
        default:
            return ""
        }
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private extension DateFormatter {
    static let dashboardMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    static let dashboardTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
