import Foundation

extension OperatorDashboardPageRenderer {
    static func liveUpdateScript(
        pollIntervalMilliseconds: Int,
        initialGeneratedAtMilliseconds: Int,
        freshnessThresholdMilliseconds: Int,
        initialSnapshotAgeMilliseconds: Int
    ) -> String {
        #"""
        <script>
        (function() {
          const pollIntervalMs = \#(pollIntervalMilliseconds);
          const hiddenPollIntervalMs = Math.max(pollIntervalMs * 3, pollIntervalMs + 5_000);
          const freshnessThresholdMs = \#(freshnessThresholdMilliseconds);
          const disconnectAfterFailures = 2;
          const requestTimeoutMs = Math.max(5_000, pollIntervalMs - 1_000);
          const state = {
            inFlight: false,
            lastGeneratedAtMs: \#(initialGeneratedAtMilliseconds),
            snapshotAgeMs: \#(initialSnapshotAgeMilliseconds),
            snapshotAgeAnchorMs: performance.now(),
            consecutiveFailures: 0,
            refreshKeys: Object.create(null),
            timerHandle: null
          };

          function parseDateValue(value) {
            if (value === null || value === undefined || value === '') {
              return null;
            }

            if (typeof value === 'number') {
              const millis = value > 1e12 ? value : value * 1000;
              const numericDate = new Date(millis);
              return Number.isNaN(numericDate.getTime()) ? null : numericDate;
            }

            const date = new Date(value);
            return Number.isNaN(date.getTime()) ? null : date;
          }

          function dateToMillis(value) {
            const date = parseDateValue(value);
            return date ? date.getTime() : null;
          }

          function pad(value) {
            return String(value).padStart(2, '0');
          }

          function timeZoneAbbreviation(date) {
            try {
              const parts = new Intl.DateTimeFormat('en-US', { timeZoneName: 'short' }).formatToParts(date);
              const match = parts.find((part) => part.type === 'timeZoneName');
              return match ? match.value : 'UTC';
            } catch (_) {
              return 'UTC';
            }
          }

          function escapeHtml(value) {
            return String(value ?? '')
              .replaceAll('&', '&amp;')
              .replaceAll('<', '&lt;')
              .replaceAll('>', '&gt;')
              .replaceAll('"', '&quot;')
              .replaceAll("'", '&#39;');
          }

          function diagnosticDisclosure(value, className = 'diagnostic-copy') {
            const escapedValue = escapeHtml(value);
            return `<details class="diagnostic-disclosure"><summary class="${className}">${escapedValue}</summary><div class="diagnostic-full">${escapedValue}</div></details>`;
          }

          function formatDate(value) {
            const date = parseDateValue(value);
            if (!date) {
              return 'n/a';
            }
            const now = new Date();
            const dateDayStart = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
            const nowDayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
            const dayDifference = Math.floor((nowDayStart - dateDayStart) / 86_400_000);
            const hour = date.getHours();
            const minute = pad(date.getMinutes());
            const isPM = hour >= 12;
            const twelveHour = hour % 12 === 0 ? 12 : hour % 12;
            const timeText = `${twelveHour}:${minute} ${isPM ? 'PM' : 'AM'}`;

            if (dayDifference <= 0) {
              return `Today ${timeText}`;
            }

            if (dayDifference === 1) {
              return `Yesterday ${timeText}`;
            }

            return `${dayDifference} days ago ${timeText}`;
          }

          function formatMonth(value) {
            const date = parseDateValue(value);
            if (!date) {
              return 'n/a';
            }

            return new Intl.DateTimeFormat('en-US', {
              month: 'long',
              year: 'numeric',
              timeZone: 'UTC'
            }).format(date);
          }

          function formatDuration(value) {
            if (value === null || value === undefined || Number.isNaN(Number(value))) {
              return 'n/a';
            }

            const seconds = Math.max(0, Math.round(Number(value)));
            if (seconds < 60) {
              return `${seconds}s`;
            }

            if (seconds < 3600) {
              return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
            }

            if (seconds < 86400) {
              const hours = Math.floor(seconds / 3600);
              const minutes = Math.floor((seconds % 3600) / 60);
              return `${hours}h ${minutes}m`;
            }

            const days = Math.floor(seconds / 86400);
            const hours = Math.floor((seconds % 86400) / 3600);
            return `${days}d ${hours}h`;
          }

          function currentSnapshotAgeMs() {
            if (state.snapshotAgeMs === null) {
              return null;
            }

            return state.snapshotAgeMs + (performance.now() - state.snapshotAgeAnchorMs);
          }

          function formatSnapshotAge(ageMs) {
            if (ageMs === null) {
              return 'Snapshot age unavailable';
            }

            return `Snapshot ${formatDuration(ageMs / 1000)} ago`;
          }

          function updateStatus() {
            const statusDot = document.getElementById('connection-status');
            const statusLabel = document.getElementById('connection-status-label');
            const ageNode = document.getElementById('snapshot-age');
            const ageMs = currentSnapshotAgeMs();
            const disconnected = state.consecutiveFailures >= disconnectAfterFailures;
            const stale = ageMs === null || ageMs > freshnessThresholdMs;
            const status = disconnected ? 'DISCONNECTED' : (stale ? 'STALE' : 'LIVE');

            if (statusDot) {
              statusDot.className = `status-dot ${status.toLowerCase()}`;
            }
            if (statusLabel) {
              statusLabel.className = `status-label ${status.toLowerCase()}`;
              statusLabel.textContent = status;
            }
            if (ageNode) {
              ageNode.textContent = formatSnapshotAge(ageMs);
            }
          }

          function formatByteSize(value) {
            if (value === null || value === undefined || Number.isNaN(Number(value))) {
              return 'n/a';
            }

            const size = Number(value);
            if (size < 1024) {
              return `${size} B`;
            }

            const units = ['KiB', 'MiB', 'GiB', 'TiB'];
            let scaled = size / 1024;
            let unitIndex = 0;
            while (scaled >= 1024 && unitIndex < units.length - 1) {
              scaled /= 1024;
              unitIndex += 1;
            }

            return `${scaled >= 10 || unitIndex === 0 ? scaled.toFixed(0) : scaled.toFixed(1)} ${units[unitIndex]}`;
          }

          function formatPercent(value) {
            if (value === null || value === undefined || Number.isNaN(Number(value))) {
              return 'n/a';
            }

            return `${(Number(value) * 100).toFixed(1)}%`;
          }

          function joinedReasons(reasons) {
            if (!Array.isArray(reasons) || reasons.length === 0) {
              return 'none';
            }

            return reasons.map((reason) => `${reason.reason} (${reason.count})`).join(', ');
          }

          function joinedCodes(codes) {
            if (!Array.isArray(codes) || codes.length === 0) {
              return 'none';
            }

            return codes.join(', ');
          }

          function renderCard(title, primary, refreshedAt, lines, primaryClass = '', status = null) {
            const primaryClassSuffix = primaryClass ? ` ${primaryClass}` : '';
            const healthClassSuffix = status ? ` health-card health-${status}` : '';
            const statusDot = status
              ? '<span class="health-dot" aria-hidden="true"></span>'
              : '';
            const statusText = status
              ? `<span class="health-status">${escapeHtml(status.charAt(0).toUpperCase() + status.slice(1))}</span>`
              : '';
            return `
              <div class="card${healthClassSuffix}">
                <div class="card-heading"><h3>${escapeHtml(title)}</h3><span class="health-indicator">${statusText}${statusDot}</span></div>
                <div class="primary${primaryClassSuffix}">${escapeHtml(primary)}</div>
                <div class="subtle">Refreshed ${escapeHtml(formatDate(refreshedAt))}</div>
                <ul class="meta-list">
                  ${lines.map((line) => `<li><span>${escapeHtml(line.label)}</span><strong>${escapeHtml(line.value)}</strong></li>`).join('')}
                </ul>
              </div>
            `;
          }

          function renderCompactMetricCard(title, primary, refreshedAt, summary, details, primaryClass = '', expanded = false) {
            const primaryClassSuffix = primaryClass ? ' ' + primaryClass : '';
            const detailMarkup = details.length === 0 ? '' : (
              '<details class="metric-details"' + (expanded ? ' open' : '') + '>' +
                '<summary>Details</summary><ul class="meta-list">' +
                details.map((line) => '<li><span>' + escapeHtml(line.label) + '</span><strong>' + escapeHtml(line.value) + '</strong></li>').join('') +
                '</ul></details>'
            );
            return '<div class="card compact-card">' +
              '<div class="card-heading"><h3>' + escapeHtml(title) + '</h3></div>' +
              '<div class="primary' + primaryClassSuffix + '">' + escapeHtml(primary) + '</div>' +
              (summary ? '<div class="metric-summary">' + escapeHtml(summary) + '</div>' : '') +
              '<div class="subtle">Refreshed ' + escapeHtml(formatDate(refreshedAt)) + '</div>' +
              detailMarkup +
              '</div>';
          }

          function renderIngestCard(metric) {
            return renderCard('Ingest freshness', formatDuration(metric.timeSinceLastSuccessfulSweepSeconds), metric.refreshedAt, [
              { label: 'Last success', value: formatDate(metric.lastSuccessfulSweepAt) },
              { label: 'Last attempt', value: formatDate(metric.lastAttemptAt) },
              { label: 'Recent', value: `${metric.recentSuccessCount} success / ${metric.recentFailureCount} failure` },
              { label: 'Last error', value: metric.lastFailureMessage ?? 'none' }
            ], '', metric.status);
          }

          function renderPipelineBacklogCard(metric) {
            return renderCard('Pipeline backlog age', `Target ${formatDuration(metric.oldestPendingTargetDispatchAgeSeconds)}`, metric.refreshedAt, [
              { label: 'Pending target rows', value: String(metric.pendingTargetDispatchCount) },
              { label: 'Oldest target row', value: formatDate(metric.oldestPendingTargetDispatchCreatedAt) },
              { label: 'Notification backlog', value: formatDuration(metric.oldestPendingNotificationDispatchAgeSeconds) },
              { label: 'Pending notification rows', value: String(metric.pendingNotificationDispatchCount) }
            ], '', metric.status);
          }

          function renderStuckClaimedCard(metric) {
            return renderCard('Stuck claimed rows', String(metric.count), metric.refreshedAt, [
              { label: 'Threshold', value: formatDuration(metric.thresholdSeconds) },
              { label: 'Oldest claim age', value: formatDuration(metric.oldestClaimedAgeSeconds) },
              { label: 'Oldest claim', value: formatDate(metric.oldestClaimedCreatedAt) }
            ], '', metric.status);
          }

          function renderStaleSeriesCard(metric) {
            return renderCard('Stale active series', String(metric.count), metric.refreshedAt, [
              { label: 'Grace window', value: formatDuration(metric.graceSeconds) }
            ], '', metric.status);
          }

          function renderKnownInstallationsCard(metric) {
            const previousMonth = metric.monthlyGrowth.length > 1
              ? metric.monthlyGrowth[metric.monthlyGrowth.length - 2]
              : null;
            return renderCard('Known Installations', String(metric.knownInstallationCount), metric.refreshedAt, [
              { label: 'Through last month', value: previousMonth ? String(previousMonth.cumulativeInstallationCount) : 'n/a' },
              { label: 'Currently subscribed', value: String(metric.currentlySubscribedCount) }
            ]);
          }

          function renderNewInstallationsCard(metric) {
            const currentMonth = metric.monthlyGrowth.at(-1);
            return renderCard('New This Month', String(metric.newThisMonthCount), metric.refreshedAt, [
              { label: 'Month', value: formatMonth(currentMonth?.monthStart) }
            ]);
          }

          function renderRecentServerActivityCard(metric) {
            return renderCard('Seen Last 24h — Server Activity', String(metric.seenLast24HoursCount), metric.refreshedAt, [
              { label: 'Share of known', value: formatPercent(metric.seenLast24HoursRate) },
              { label: 'Interpretation', value: 'Operational activity, not DAU' }
            ]);
          }

          function renderActiveTodayCard(metric) {
            return renderCard('Active Today', String(metric.dailyActiveInstallationCount), metric.refreshedAt, [
              { label: 'Metric', value: 'DAU' },
              { label: 'Source', value: 'Explicit foreground activity' }
            ]);
          }

          function renderActiveThisMonthCard(metric) {
            return renderCard('Active This Month', String(metric.monthlyActiveInstallationCount), metric.refreshedAt, [
              { label: 'Metric', value: 'MAU' },
              { label: 'Source', value: 'Explicit foreground activity' }
            ]);
          }

          function renderInstallationActivityStateTable(metric) {
            const rows = Array.isArray(metric.stateBreakdown) ? metric.stateBreakdown : [];
            const body = rows.length === 0
              ? '<div class="empty">No foreground activity this month.</div>'
              : `
                <div class="table-wrap">
                  <table class="inline-mobile-table">
                    <thead><tr><th>State</th><th>Today</th><th>This Month</th></tr></thead>
                    <tbody>
                      ${rows.map((entry) => `
                        <tr>
                          <td data-label="State">${escapeHtml(entry.state)}</td>
                          <td data-label="Today">${escapeHtml(entry.activeTodayCount)}</td>
                          <td data-label="This Month">${escapeHtml(entry.activeThisMonthCount)}</td>
                        </tr>
                      `).join('')}
                    </tbody>
                  </table>
                </div>
              `;

            return `
              <div class="card table-card">
                <div class="table-card__header">
                  <h3>Active Installations by State</h3>
                  <div class="subtle">Current/last-known operational state · Refreshed ${escapeHtml(formatDate(metric.refreshedAt))}</div>
                </div>
                ${body}
              </div>
            `;
          }

          function renderInstallationGrowthTable(metric) {
            const rows = Array.isArray(metric.monthlyGrowth) ? metric.monthlyGrowth : [];
            const body = rows.length === 0
              ? '<div class="empty">No installation growth history.</div>'
              : `
                <div class="table-wrap">
                  <table class="stream-table inline-mobile-table">
                    <thead><tr><th>Month</th><th>New installations</th><th>Cumulative total</th></tr></thead>
                    <tbody>
                      ${rows.map((entry) => `
                        <tr>
                          <td data-label="Month">${escapeHtml(formatMonth(entry.monthStart))}</td>
                          <td data-label="New installations">${escapeHtml(entry.newInstallationCount)}</td>
                          <td data-label="Cumulative total">${escapeHtml(entry.cumulativeInstallationCount)}</td>
                        </tr>
                      `).join('')}
                    </tbody>
                  </table>
                </div>
              `;

            return `
              <div class="card table-card">
                <div class="table-card__header">
                  <h3>Monthly Installation Growth</h3>
                  <div class="subtle">Refreshed ${escapeHtml(formatDate(metric.refreshedAt))}</div>
                </div>
                ${body}
              </div>
            `;
          }

          function renderInstallationFootprintTable(entries, refreshedAt) {
            const rows = Array.isArray(entries) ? entries : [];
            const body = rows.length === 0
              ? '<div class="empty">No installation presence rows available.</div>'
              : `
                <div class="table-wrap">
                  <table class="stream-table footprint-table inline-mobile-table">
                    <thead><tr><th>Coarse location</th><th>App version</th><th>Auth</th><th>Presence age</th><th>State</th><th>Eligibility</th></tr></thead>
                    <tbody>
                      ${rows.map((entry) => {
                        const eligibility = entry.candidateQueryEligible ? 'Eligible' : (entry.ineligibilityReason || 'Ineligible');
                        const eligibilityClass = entry.candidateQueryEligible ? 'footprint-eligible' : 'footprint-ineligible';
                        const state = entry.isActive ? (entry.isSubscribed ? 'Active / subscribed' : 'Active / paused') : 'Inactive';
                        return `
                          <tr>
                            <td data-label="Coarse location">${escapeHtml(entry.locationLabel)}</td>
                            <td data-label="App version">${escapeHtml(entry.appVersion)}</td>
                            <td data-label="Auth">${escapeHtml(entry.locationAuth)}</td>
                            <td data-label="Presence age" class="presence-age">${escapeHtml(formatDuration(entry.presenceAgeSeconds))}</td>
                            <td data-label="State">${escapeHtml(state)}</td>
                            <td data-label="Eligibility"><span class="pill ${eligibilityClass}">${escapeHtml(eligibility)}</span></td>
                          </tr>
                        `;
                      }).join('')}
                    </tbody>
                  </table>
                </div>
              `;

            return `
              <div class="card table-card">
                <div class="table-card__header">
                  <h3>Installation Footprint</h3>
                  <div class="subtle">Newest presence first · ${rows.length} of 50 rows · Refreshed ${escapeHtml(formatDate(refreshedAt))}</div>
                </div>
                ${body}
              </div>
            `;
          }

          function renderLatencyCard(metric) {
            return renderCompactMetricCard('End-to-end alert latency p95', formatDuration(metric.p95Seconds === null ? null : Math.round(metric.p95Seconds)), metric.refreshedAt, null, [
              { label: 'Window', value: `${metric.windowHours}h` },
              { label: 'Successful revisions', value: String(metric.successfulRevisionCount) }
            ]);
          }

          function renderAPNsSuccessCard(metric) {
            return renderCompactMetricCard('APNs delivery success rate', formatPercent(metric.successRate), metric.refreshedAt, null, [
              { label: 'Sent', value: String(metric.sentCount) },
              { label: 'Failed', value: String(metric.failedCount) },
              { label: 'Top failures', value: joinedReasons(metric.topFailureReasons) }
            ]);
          }

          function renderNoOpCard(metric) {
            return renderCompactMetricCard('Send no-op rate by reason', formatPercent(metric.noOpRate), metric.refreshedAt, null, [
              { label: 'Total attempts', value: String(metric.totalAttemptCount) },
              { label: 'No-op attempts', value: String(metric.noOpAttemptCount) },
              { label: 'Reasons', value: joinedReasons(metric.reasons) }
            ]);
          }

          function renderZeroCandidateCard(metric) {
            return renderCompactMetricCard('Zero-candidate revision rate', formatPercent(metric.zeroCandidateRate), metric.refreshedAt, null, [
              { label: 'Candidate-resolution attempts', value: String(metric.candidateResolutionAttemptCount) },
              { label: 'Zero-candidate attempts', value: String(metric.zeroCandidateAttemptCount) }
            ]);
          }

          function renderCoverageCard(metric) {
            return renderCompactMetricCard('Fresh targetable coverage', formatPercent(metric.targetableRate), metric.refreshedAt,
              'Fresh targetable ' + metric.targetableInstallationCount + ' / ' + metric.activeSubscribedInstallationCount + ' · Eligible ≤24h ' + metric.candidateQueryEligibleInstallationCount + ' / ' + metric.activeSubscribedInstallationCount, [
              { label: 'Eligible ≤24h', value: `${metric.candidateQueryEligibleInstallationCount} / ${metric.activeSubscribedInstallationCount}` },
              { label: 'Excluded >24h', value: String(metric.hardStalePresenceCount) },
              { label: 'Fresh targetable (≤6h)', value: `${metric.targetableInstallationCount} / ${metric.activeSubscribedInstallationCount}` },
              { label: 'Missing token', value: String(metric.lossBreakdown.missingDeviceTokenCount) },
              { label: 'Stale install', value: String(metric.lossBreakdown.staleInstallationHeartbeatCount) },
              { label: 'Stale presence', value: String(metric.lossBreakdown.stalePresenceCount) },
              { label: 'Missing targeting', value: String(metric.lossBreakdown.missingTargetingDataCount) }
            ]);
          }

          function renderH3Card(metric) {
            return renderCompactMetricCard('Geography to H3 conversion', formatPercent(metric.successRate), metric.refreshedAt, null, [
              { label: 'Geometry-bearing revisions', value: String(metric.geometryBearingRevisionCount) },
              { label: 'Successful conversions', value: String(metric.successfulConversionCount) },
              { label: 'p95 conversion', value: formatDuration(metric.p95ConversionSeconds === null ? null : Math.round(metric.p95ConversionSeconds)) }
            ]);
          }

          function statusClass(status) {
            switch (String(status ?? '').toLowerCase()) {
              case 'ready':
                return 'accent';
              case 'pending':
              case 'warming':
                return 'warn';
              case 'failed':
              case 'expired':
                return 'danger';
              default:
                return '';
            }
          }

          function renderPressureArtifactOutcome(outcome) {
            if (!outcome) {
              return 'NO DATA';
            }

            return String(outcome).toUpperCase();
          }

          function renderPressureArtifactOutcomeClass(outcome) {
            switch (String(outcome ?? '').toLowerCase()) {
              case 'exact':
                return 'accent';
              case 'stale':
                return 'warn';
              case 'unavailable':
                return 'danger';
              default:
                return '';
            }
          }

          function renderPressureArtifactStatus(status) {
            if (!status) {
              return 'NO DATA';
            }

            return String(status).toUpperCase();
          }

          function renderPressureArtifactRunAndForecast(runTime, forecastHour) {
            if (runTime === null || runTime === undefined) {
              return 'n/a';
            }

            const runText = formatDate(runTime);
            if (forecastHour === null || forecastHour === undefined) {
              return runText;
            }

            return `${runText} / FH ${forecastHour}`;
          }

          function renderPressureArtifactReadinessCard(metric) {
            const details = [
              { label: 'Catalog status', value: metric?.status ?? 'n/a' },
              { label: 'Valid time', value: formatDate(metric?.validTime) },
              { label: 'Valid-time age', value: formatDuration(metric?.validTimeAgeSeconds) },
              { label: 'Run / FH', value: renderPressureArtifactRunAndForecast(metric?.runTime, metric?.forecastHour) },
              { label: 'Field-set version', value: metric?.fieldSetVersion ?? 'n/a' },
              { label: 'Size', value: formatByteSize(metric?.byteSize) },
              { label: 'Source', value: metric?.source ?? 'n/a' },
              { label: 'Last checked / updated', value: formatDate(metric?.lastCheckedAt ?? metric?.updatedAt) },
              ...(metric?.readinessReason ? [{ label: 'Readiness reason', value: metric.readinessReason }] : []),
              ...(metric?.errorSummary ? [{ label: 'Error', value: metric.errorSummary }] : [])
            ];

            const summary = [
              metric?.validTime ? 'Valid ' + formatDate(metric.validTime) : null,
              renderPressureArtifactRunAndForecast(metric?.runTime, metric?.forecastHour),
              'checked ' + formatDate(metric?.lastCheckedAt ?? metric?.updatedAt)
            ].filter(Boolean).join(' · ');
            return renderCompactMetricCard(
              'Pressure artifact readiness',
              renderPressureArtifactOutcome(metric?.selectionOutcome),
              metric?.refreshedAt,
              summary,
              details,
              renderPressureArtifactOutcomeClass(metric?.selectionOutcome),
              metric?.selectionOutcome !== 'exact' || Boolean(metric?.readinessReason) || Boolean(metric?.errorSummary)
            );
          }

          function renderPressureArtifactCatalogCard(metric) {
            return renderCompactMetricCard('Pressure artifact catalog', String(metric?.readyCount ?? 0) + ' ready', metric?.refreshedAt,
              'Ready ' + (metric?.readyCount ?? 0) + ' · Warming ' + (metric?.warmingCount ?? 0) + ' · Pending ' + (metric?.pendingCount ?? 0) + ' · Failed ' + (metric?.failedCount ?? 0), [
              { label: 'Total', value: String(metric?.totalCount ?? 0) },
              { label: 'Pending', value: String(metric?.pendingCount ?? 0) },
              { label: 'Oldest pending', value: formatDuration(metric?.oldestPendingAgeSeconds) },
              { label: 'Warming', value: String(metric?.warmingCount ?? 0) },
              { label: 'Stuck warming', value: String(metric?.stuckWarmingCount ?? 0) },
              { label: 'Oldest expired lease', value: formatDuration(metric?.oldestExpiredWarmingLeaseAgeSeconds) },
              { label: 'Pipeline status', value: metric?.stuckReason ?? 'Healthy' },
              { label: 'Failed', value: String(metric?.failedCount ?? 0) },
              { label: 'Expired', value: String(metric?.expiredCount ?? 0) },
              { label: 'Most recent failure', value: formatDate(metric?.mostRecentFailureAt) },
              { label: 'Most recent failure reason', value: metric?.mostRecentFailureSummary ?? 'none' }
            ], '', Boolean(metric?.stuckReason));
          }

          function renderPressureArtifactRow(entry) {
            return `
              <tr>
                <td data-label="Valid time">${escapeHtml(formatDate(entry.validTime))}</td>
                <td data-label="Run / FH">${escapeHtml(renderPressureArtifactRunAndForecast(entry.runTime, entry.forecastHour))}</td>
                <td data-label="Status"><span class="pill ${statusClass(entry.status)}">${escapeHtml(renderPressureArtifactStatus(entry.status))}</span></td>
                <td data-label="Source">${escapeHtml(entry.source ?? 'n/a')}</td>
                <td data-label="Size" class="mono">${escapeHtml(formatByteSize(entry.byteSize))}</td>
                <td data-label="Updated">${escapeHtml(formatDate(entry.updatedAt))}</td>
                <td data-label="Error">${diagnosticDisclosure(entry.errorSummary ?? 'none')}</td>
              </tr>
            `;
          }

          function renderRecentPressureArtifactsTable(metric) {
            const body = !Array.isArray(metric?.entries) || metric.entries.length === 0
              ? '<div class="empty">No current-version pressure artifacts.</div>'
              : `
                <div class="table-wrap">
                <table class="stream-table pressure-artifact-table inline-mobile-table">
                  <thead>
                    <tr>
                      <th>Valid time</th>
                      <th>Run / FH</th>
                      <th>Status</th>
                      <th>Source</th>
                      <th>Size</th>
                      <th>Updated</th>
                      <th>Error</th>
                    </tr>
                  </thead>
                  <tbody>
                    ${metric.entries.map(renderPressureArtifactRow).join('')}
                  </tbody>
                </table>
                </div>
              `;

            return `
              <div class="card table-card">
                <div class="table-card__header">
                  <h3>Recent pressure artifacts</h3>
                  <div class="subtle">Refreshed ${escapeHtml(formatDate(metric?.refreshedAt))}</div>
                </div>
                ${body}
              </div>
            `;
          }

          function renderRecentDebugRow(entry) {
            return `
              <tr>
                <td data-label="Time">${escapeHtml(formatDate(entry.createdAt))}</td>
                <td data-label="Alert">
                  <div>${escapeHtml(entry.eventName)}</div>
                  ${diagnosticDisclosure(entry.seriesID, 'diagnostic-mono')}
                </td>
                <td data-label="Mode / reason">
                  <span class="pill">${escapeHtml(entry.mode)}</span>
                  ${diagnosticDisclosure(`${entry.reason} / ${entry.recordKind}`)}
                </td>
                <td data-label="Message">
                  <div><strong>${escapeHtml(entry.title)}</strong></div>
                  <div class="subtle">${escapeHtml(entry.subtitle)}</div>
                  ${diagnosticDisclosure(entry.body)}
                </td>
                <td data-label="Outcome">
                  <div>${escapeHtml(entry.ledgerStatus ?? 'preview')}</div>
                  ${diagnosticDisclosure(entry.apnsErrorCode ?? 'none')}
                </td>
              </tr>
            `;
          }

          function renderRecentDebugTable(metric) {
            const body = !Array.isArray(metric.entries) || metric.entries.length === 0
              ? '<div class="empty">No recent notification debug entries.</div>'
              : `
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
                    ${metric.entries.map(renderRecentDebugRow).join('')}
                  </tbody>
                </table>
              `;

            return `
              <div class="card table-card">
                <div class="table-card__header">
                  <h3>Recent notification debug entries</h3>
                  <div class="subtle">Refreshed ${escapeHtml(formatDate(metric.refreshedAt))}</div>
                </div>
                ${body}
              </div>
            `;
          }

          function renderTouchedSeriesRow(entry) {
            return `
              <tr>
                <td data-label="Touched">${escapeHtml(formatDate(entry.touchedAt))}</td>
                <td data-label="Alert">
                  <div>${escapeHtml(entry.eventName)}</div>
                  ${diagnosticDisclosure(entry.seriesID, 'diagnostic-mono')}
                  ${diagnosticDisclosure(entry.currentRevisionUrn, 'diagnostic-mono')}
                </td>
                <td data-label="Geography">
                  <div>${escapeHtml(entry.areaDescription ?? 'Unknown area')}</div>
                  ${diagnosticDisclosure(`UGC Codes: ${joinedCodes(entry.ugcCodes)}`, 'diagnostic-mono')}
                </td>
                <td data-label="State"><span class="pill ${seriesStateClass(entry.state)}">${escapeHtml(entry.state)}</span></td>
                <td data-label="Tornado detection"><span class="${tornadoThreatClass(entry.tornadoDetection)}">${escapeHtml(entry.tornadoDetection ?? 'none')}</span></td>
                <td data-label="Tornado damage"><span class="${tornadoThreatClass(entry.tornadoDamageThreat)}">${escapeHtml(entry.tornadoDamageThreat ?? 'none')}</span></td>
              </tr>
            `;
          }

          function renderTouchedSeriesTable(metric) {
            const body = !Array.isArray(metric.entries) || metric.entries.length === 0
              ? '<div class="empty">No recently touched series.</div>'
              : `
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
                    ${metric.entries.map(renderTouchedSeriesRow).join('')}
                  </tbody>
                </table>
              `;

            return `
              <div class="card table-card">
                <div class="table-card__header">
                  <h3>Last 5 touched series</h3>
                  <div class="subtle">Refreshed ${escapeHtml(formatDate(metric.refreshedAt))}</div>
                </div>
                ${body}
              </div>
            `;
          }

          function seriesStateClass(state) {
            switch ((state ?? '').toLowerCase()) {
              case 'active': return 'accent';
              case 'warning':
              case 'pending': return 'warn';
              default: return '';
            }
          }

          function tornadoThreatClass(value) {
            switch ((value ?? '').toLowerCase()) {
              case 'observed':
              case 'confirmed':
              case 'considerable':
              case 'catastrophic': return 'danger';
              case 'possible':
              case 'probable':
              case 'radar indicated':
              case 'significant': return 'warn';
              default: return '';
            }
          }

          function refreshKey(value) {
            return value ?? 'none';
          }

          function streamRows(node, delayStepMs) {
            const rows = node.querySelectorAll('tbody tr');
            rows.forEach((row, index) => {
              row.classList.add('stream-row');
              row.style.animationDelay = `${Math.min(index * delayStepMs, 360)}ms`;
            });
          }

          function swapHTML(id, html, options) {
            const node = document.getElementById(id);
            if (!node) {
              return;
            }

            node.classList.add('is-updating');
            node.innerHTML = html;
            if (options && options.streamRows) {
              streamRows(node, options.streamDelayStepMs ?? 32);
            }
            window.requestAnimationFrame(() => node.classList.remove('is-updating'));
          }

          function updateSlot(id, key, html, options) {
            if (state.refreshKeys[id] === key) {
              return;
            }

            state.refreshKeys[id] = key;
            swapHTML(id, html, options);
          }

          function applySnapshot(snapshot) {
            updateSlot('ingest-card', refreshKey(snapshot.redLights.ingestFreshness.refreshedAt), renderIngestCard(snapshot.redLights.ingestFreshness));
            updateSlot('pipeline-backlog-card', refreshKey(snapshot.redLights.pipelineBacklogAge.refreshedAt), renderPipelineBacklogCard(snapshot.redLights.pipelineBacklogAge));
            updateSlot('stuck-claimed-card', refreshKey(snapshot.redLights.stuckClaimedRows.refreshedAt), renderStuckClaimedCard(snapshot.redLights.stuckClaimedRows));
            updateSlot('stale-series-card', refreshKey(snapshot.redLights.staleActiveSeriesCount.refreshedAt), renderStaleSeriesCard(snapshot.redLights.staleActiveSeriesCount));
            updateSlot('known-installations-card', refreshKey(snapshot.growthUsage.installationGrowth.refreshedAt), renderKnownInstallationsCard(snapshot.growthUsage.installationGrowth));
            updateSlot('new-installations-card', refreshKey(snapshot.growthUsage.installationGrowth.refreshedAt), renderNewInstallationsCard(snapshot.growthUsage.installationGrowth));
            updateSlot('recent-server-activity-card', refreshKey(snapshot.growthUsage.installationGrowth.refreshedAt), renderRecentServerActivityCard(snapshot.growthUsage.installationGrowth));
            updateSlot('active-today-card', refreshKey(snapshot.growthUsage.installationActivity.refreshedAt), renderActiveTodayCard(snapshot.growthUsage.installationActivity));
            updateSlot('active-this-month-card', refreshKey(snapshot.growthUsage.installationActivity.refreshedAt), renderActiveThisMonthCard(snapshot.growthUsage.installationActivity));
            updateSlot(
              'installation-activity-state-table',
              refreshKey(snapshot.growthUsage.installationActivity.refreshedAt),
              renderInstallationActivityStateTable(snapshot.growthUsage.installationActivity),
              { streamRows: true, streamDelayStepMs: 28 }
            );
            updateSlot(
              'installation-growth-table',
              refreshKey(snapshot.growthUsage.installationGrowth.refreshedAt),
              renderInstallationGrowthTable(snapshot.growthUsage.installationGrowth),
              { streamRows: true, streamDelayStepMs: 28 }
            );
            updateSlot(
              'installation-footprint-table',
              refreshKey(snapshot.growthUsage.installationActivity.refreshedAt),
              renderInstallationFootprintTable(snapshot.growthUsage.installationFootprint, snapshot.growthUsage.installationActivity.refreshedAt),
              { streamRows: true, streamDelayStepMs: 24 }
            );
            updateSlot(
              'pressure-artifact-readiness-card',
              refreshKey(snapshot.modelArtifacts?.pressureArtifactReadiness?.refreshedAt),
              renderPressureArtifactReadinessCard(snapshot.modelArtifacts?.pressureArtifactReadiness)
            );
            updateSlot(
              'pressure-artifact-catalog-card',
              refreshKey(snapshot.modelArtifacts?.pressureArtifactCatalog?.refreshedAt),
              renderPressureArtifactCatalogCard(snapshot.modelArtifacts?.pressureArtifactCatalog)
            );
            updateSlot(
              'recent-pressure-artifacts-table',
              refreshKey(snapshot.modelArtifacts?.recentPressureArtifacts?.refreshedAt),
              renderRecentPressureArtifactsTable(snapshot.modelArtifacts?.recentPressureArtifacts),
              { streamRows: true, streamDelayStepMs: 28 }
            );
            updateSlot('latency-card', refreshKey(snapshot.deliveryKPIs.endToEndAlertLatency.refreshedAt), renderLatencyCard(snapshot.deliveryKPIs.endToEndAlertLatency));
            updateSlot('apns-success-card', refreshKey(snapshot.deliveryKPIs.apnsDeliverySuccessRate.refreshedAt), renderAPNsSuccessCard(snapshot.deliveryKPIs.apnsDeliverySuccessRate));
            updateSlot('noop-card', refreshKey(snapshot.deliveryKPIs.sendNoOpRateByReason.refreshedAt), renderNoOpCard(snapshot.deliveryKPIs.sendNoOpRateByReason));
            updateSlot('zero-candidate-card', refreshKey(snapshot.deliveryKPIs.zeroCandidateRevisionRate.refreshedAt), renderZeroCandidateCard(snapshot.deliveryKPIs.zeroCandidateRevisionRate));
            updateSlot('coverage-card', refreshKey(snapshot.audienceTargeting.freshTargetableInstallationCoverage.refreshedAt), renderCoverageCard(snapshot.audienceTargeting.freshTargetableInstallationCoverage));
            updateSlot('h3-card', refreshKey(snapshot.audienceTargeting.alertsWithGeographyAndH3Success.refreshedAt), renderH3Card(snapshot.audienceTargeting.alertsWithGeographyAndH3Success));
            updateSlot(
              'recent-debug-table',
              refreshKey(snapshot.operatorContext.recentNotificationDebugEntries.refreshedAt),
              renderRecentDebugTable(snapshot.operatorContext.recentNotificationDebugEntries),
              { streamRows: true, streamDelayStepMs: 26 }
            );
            updateSlot(
              'touched-series-table',
              refreshKey(snapshot.operatorContext.lastTouchedSeries.refreshedAt),
              renderTouchedSeriesTable(snapshot.operatorContext.lastTouchedSeries),
              { streamRows: true, streamDelayStepMs: 34 }
            );
          }

          async function fetchSnapshot() {
            if (state.inFlight) {
              return;
            }

            state.inFlight = true;
            const abortController = new AbortController();
            const timeoutHandle = window.setTimeout(() => abortController.abort(), requestTimeoutMs);
            try {
              const response = await fetch('/v1/metrics', {
                headers: { 'Accept': 'application/json' },
                cache: 'no-store',
                signal: abortController.signal
              });

              if (!response.ok) {
                state.consecutiveFailures += 1;
                updateStatus();
                return;
              }

              const snapshot = await response.json();
              const generatedAtMs = dateToMillis(snapshot.generatedAt);
              const renderedAtMs = dateToMillis(snapshot.renderedAt);
              const snapshotChanged = generatedAtMs !== null && generatedAtMs !== state.lastGeneratedAtMs;
              state.consecutiveFailures = 0;
              state.lastGeneratedAtMs = generatedAtMs;
              state.snapshotAgeMs = generatedAtMs !== null && renderedAtMs !== null
                ? Math.max(0, renderedAtMs - generatedAtMs)
                : null;
              state.snapshotAgeAnchorMs = performance.now();
              updateStatus();
              if (!snapshotChanged) {
                return;
              }

              applySnapshot(snapshot);
            } catch (_) {
              state.consecutiveFailures += 1;
              updateStatus();
            } finally {
              window.clearTimeout(timeoutHandle);
              state.inFlight = false;
              scheduleNextPoll();
            }
          }

          updateStatus();
          window.setInterval(updateStatus, 1_000);

          function scheduleNextPoll() {
            if (state.timerHandle !== null) {
              window.clearTimeout(state.timerHandle);
            }

            const isVisible = document.visibilityState === 'visible';
            const nextDelay = isVisible ? pollIntervalMs : hiddenPollIntervalMs;
            state.timerHandle = window.setTimeout(fetchSnapshot, nextDelay);
          }

          window.addEventListener('focus', fetchSnapshot);
          document.addEventListener('visibilitychange', function() {
            if (document.visibilityState === 'visible') {
              fetchSnapshot();
            } else {
              scheduleNextPoll();
            }
          });
          fetchSnapshot();
        })();
        </script>
        """#
    }

    static func unavailablePollingScript(pollIntervalMilliseconds: Int) -> String {
        #"""
        <script>
        (function() {
          const pollIntervalMs = \#(pollIntervalMilliseconds);

          async function pollForSnapshot() {
            try {
              const response = await fetch('/v1/metrics', {
                headers: { 'Accept': 'application/json' },
                cache: 'no-store'
              });

              if (response.ok) {
                window.location.replace('/dashboard');
              }
            } catch (_) {
            }
          }

          window.setInterval(pollForSnapshot, pollIntervalMs);
          pollForSnapshot();
        })();
        </script>
        """#
    }

}
