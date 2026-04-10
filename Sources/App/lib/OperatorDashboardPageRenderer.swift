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
            :root {
              color-scheme: dark;
              --bg: #07111c;
              --panel: rgba(12, 24, 39, 0.92);
              --panel-2: rgba(17, 33, 52, 0.88);
              --line: rgba(117, 165, 196, 0.18);
              --text: #eef6ff;
              --muted: #8ca4ba;
              --accent: #58d6c3;
              --warn: #ffb15c;
              --danger: #ff6f7d;
              --shadow: 0 24px 60px rgba(0, 0, 0, 0.35);
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              font-family: "Avenir Next", "IBM Plex Sans", "Segoe UI", sans-serif;
              background:
                radial-gradient(circle at top left, rgba(88, 214, 195, 0.10), transparent 32%),
                radial-gradient(circle at top right, rgba(255, 111, 125, 0.12), transparent 28%),
                linear-gradient(180deg, #08121d 0%, #050a11 100%);
              color: var(--text);
            }
            .shell {
              width: min(1320px, calc(100vw - 32px));
              margin: 0 auto;
              padding: 28px 0 40px;
            }
            .hero {
              display: flex;
              gap: 16px;
              justify-content: space-between;
              align-items: flex-end;
              padding: 24px;
              border: 1px solid var(--line);
              border-radius: 24px;
              background: linear-gradient(135deg, rgba(14, 29, 46, 0.96), rgba(7, 15, 25, 0.94));
              box-shadow: var(--shadow);
            }
            .hero h1 {
              margin: 0;
              font-family: "Space Grotesk", "Avenir Next", sans-serif;
              font-size: clamp(2rem, 3vw, 3rem);
              letter-spacing: -0.04em;
            }
            .hero p {
              margin: 10px 0 0;
              color: var(--muted);
              max-width: 720px;
            }
            .hero-meta {
              text-align: right;
              color: var(--muted);
              font-size: 0.95rem;
            }
            .hero-meta a {
              color: var(--accent);
              text-decoration: none;
            }
            .section {
              margin-top: 28px;
            }
            .section h2 {
              margin: 0 0 14px;
              font-size: 1.05rem;
              text-transform: uppercase;
              letter-spacing: 0.12em;
              color: var(--muted);
            }
            .grid {
              display: grid;
              grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
              gap: 16px;
            }
            .stack {
              display: grid;
              grid-template-columns: 1fr;
              gap: 16px;
            }
            .live-slot {
              min-width: 0;
              transition: opacity 0.18s ease, transform 0.18s ease;
            }
            .live-slot.is-updating {
              opacity: 0.78;
              transform: translateY(1px);
            }
            .card {
              padding: 18px;
              border-radius: 20px;
              border: 1px solid var(--line);
              background: linear-gradient(180deg, var(--panel), var(--panel-2));
              box-shadow: var(--shadow);
            }
            .card h3 {
              margin: 0;
              font-size: 0.92rem;
              letter-spacing: 0.02em;
              color: var(--muted);
            }
            .primary {
              margin: 14px 0 6px;
              font-size: 2rem;
              font-weight: 700;
              letter-spacing: -0.04em;
            }
            .subtle {
              color: var(--muted);
              font-size: 0.92rem;
            }
            .meta-list {
              margin: 14px 0 0;
              padding: 0;
              list-style: none;
            }
            .meta-list li {
              display: flex;
              justify-content: space-between;
              gap: 12px;
              padding: 9px 0;
              border-top: 1px solid rgba(117, 165, 196, 0.10);
              color: var(--muted);
              font-size: 0.92rem;
            }
            .meta-list li strong {
              color: var(--text);
              font-weight: 600;
            }
            .table-card {
              padding: 0;
              overflow: hidden;
            }
            table {
              width: 100%;
              border-collapse: collapse;
            }
            th, td {
              padding: 13px 16px;
              text-align: left;
              vertical-align: top;
              border-bottom: 1px solid rgba(117, 165, 196, 0.10);
            }
            th {
              font-size: 0.8rem;
              text-transform: uppercase;
              letter-spacing: 0.08em;
              color: var(--muted);
              background: rgba(255, 255, 255, 0.02);
            }
            td {
              font-size: 0.94rem;
            }
            .pill {
              display: inline-block;
              padding: 4px 10px;
              border-radius: 999px;
              font-size: 0.78rem;
              letter-spacing: 0.04em;
              text-transform: uppercase;
              border: 1px solid rgba(117, 165, 196, 0.18);
              color: var(--text);
              background: rgba(255, 255, 255, 0.05);
            }
            .accent { color: var(--accent); }
            .warn { color: var(--warn); }
            .danger { color: var(--danger); }
            .mono { font-family: "SF Mono", "IBM Plex Mono", monospace; font-size: 0.78rem; }
            .micro-mono { font-family: "SF Mono", "IBM Plex Mono", monospace; font-size: 0.54rem; line-height: 1.3; }
            .hero-meta, .primary, th, td, .mono, .micro-mono {
              font-variant-numeric: tabular-nums;
            }
            .empty {
              padding: 18px 16px;
              color: var(--muted);
            }
            @media (max-width: 720px) {
              .hero {
                flex-direction: column;
                align-items: stretch;
              }
              .hero-meta {
                text-align: left;
              }
              th, td {
                padding: 12px;
              }
            }
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
              <h2>Red Lights</h2>
              <div class="grid">
                \(slot("ingest-card", content: ingestCard(snapshot.redLights.ingestFreshness)))
                \(slot("pipeline-backlog-card", content: pipelineBacklogCard(snapshot.redLights.pipelineBacklogAge)))
                \(slot("stuck-claimed-card", content: stuckClaimedCard(snapshot.redLights.stuckClaimedRows)))
                \(slot("stale-series-card", content: staleSeriesCard(snapshot.redLights.staleActiveSeriesCount)))
              </div>
            </section>

            <section class="section">
              <h2>Delivery KPIs</h2>
              <div class="grid">
                \(slot("latency-card", content: latencyCard(snapshot.deliveryKPIs.endToEndAlertLatency)))
                \(slot("apns-success-card", content: apnsSuccessCard(snapshot.deliveryKPIs.apnsDeliverySuccessRate)))
                \(slot("noop-card", content: noOpCard(snapshot.deliveryKPIs.sendNoOpRateByReason)))
                \(slot("zero-candidate-card", content: zeroCandidateCard(snapshot.deliveryKPIs.zeroCandidateRevisionRate)))
              </div>
            </section>

            <section class="section">
              <h2>Audience / Targeting</h2>
              <div class="grid">
                \(slot("coverage-card", content: coverageCard(snapshot.audienceTargeting.freshTargetableInstallationCoverage)))
                \(slot("h3-card", content: h3Card(snapshot.audienceTargeting.alertsWithGeographyAndH3Success)))
              </div>
            </section>

            <section class="section">
              <h2>Operator Context</h2>
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
            :root { color-scheme: dark; }
            body {
              margin: 0;
              font-family: "Avenir Next", "IBM Plex Sans", sans-serif;
              background: linear-gradient(180deg, #08121d 0%, #050a11 100%);
              color: #eef6ff;
              display: grid;
              place-items: center;
              min-height: 100vh;
            }
            .panel {
              width: min(560px, calc(100vw - 32px));
              padding: 28px;
              border-radius: 24px;
              border: 1px solid rgba(117, 165, 196, 0.18);
              background: rgba(12, 24, 39, 0.94);
              box-shadow: 0 24px 60px rgba(0, 0, 0, 0.35);
            }
            h1 { margin: 0 0 8px; }
            p { color: #8ca4ba; line-height: 1.5; }
            a { color: #58d6c3; text-decoration: none; }
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

    private static func slot(_ id: String, content: String) -> String {
        """
        <div id="\(escape(id))" class="live-slot">\(content)</div>
        """
    }

    private static func liveUpdateScript(
        pollIntervalMilliseconds: Int,
        initialGeneratedAtMilliseconds: Int
    ) -> String {
        #"""
        <script>
        (function() {
          const pollIntervalMs = \#(pollIntervalMilliseconds);
          const state = {
            inFlight: false,
            lastGeneratedAtMs: \#(initialGeneratedAtMilliseconds),
            refreshKeys: Object.create(null)
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

          function formatDate(value) {
            const date = parseDateValue(value);
            if (!date) {
              return 'n/a';
            }

            return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())} ${timeZoneAbbreviation(date)}`;
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

          function renderCard(title, primary, refreshedAt, lines) {
            return `
              <div class="card">
                <h3>${escapeHtml(title)}</h3>
                <div class="primary">${escapeHtml(primary)}</div>
                <div class="subtle">Refreshed ${escapeHtml(formatDate(refreshedAt))}</div>
                <ul class="meta-list">
                  ${lines.map((line) => `<li><span>${escapeHtml(line.label)}</span><strong>${escapeHtml(line.value)}</strong></li>`).join('')}
                </ul>
              </div>
            `;
          }

          function renderIngestCard(metric) {
            return renderCard('Ingest freshness', formatDuration(metric.timeSinceLastSuccessfulSweepSeconds), metric.refreshedAt, [
              { label: 'Last success', value: formatDate(metric.lastSuccessfulSweepAt) },
              { label: 'Last attempt', value: formatDate(metric.lastAttemptAt) },
              { label: 'Recent', value: `${metric.recentSuccessCount} success / ${metric.recentFailureCount} failure` },
              { label: 'Last error', value: metric.lastFailureMessage ?? 'none' }
            ]);
          }

          function renderPipelineBacklogCard(metric) {
            return renderCard('Pipeline backlog age', `Target ${formatDuration(metric.oldestPendingTargetDispatchAgeSeconds)}`, metric.refreshedAt, [
              { label: 'Pending target rows', value: String(metric.pendingTargetDispatchCount) },
              { label: 'Oldest target row', value: formatDate(metric.oldestPendingTargetDispatchCreatedAt) },
              { label: 'Notification backlog', value: formatDuration(metric.oldestPendingNotificationDispatchAgeSeconds) },
              { label: 'Pending notification rows', value: String(metric.pendingNotificationDispatchCount) }
            ]);
          }

          function renderStuckClaimedCard(metric) {
            return renderCard('Stuck claimed rows', String(metric.count), metric.refreshedAt, [
              { label: 'Threshold', value: formatDuration(metric.thresholdSeconds) },
              { label: 'Oldest claim age', value: formatDuration(metric.oldestClaimedAgeSeconds) },
              { label: 'Oldest claim', value: formatDate(metric.oldestClaimedCreatedAt) }
            ]);
          }

          function renderStaleSeriesCard(metric) {
            return renderCard('Stale active series', String(metric.count), metric.refreshedAt, [
              { label: 'Grace window', value: formatDuration(metric.graceSeconds) }
            ]);
          }

          function renderLatencyCard(metric) {
            return renderCard('End-to-end alert latency p95', formatDuration(metric.p95Seconds === null ? null : Math.round(metric.p95Seconds)), metric.refreshedAt, [
              { label: 'Window', value: `${metric.windowHours}h` },
              { label: 'Successful revisions', value: String(metric.successfulRevisionCount) }
            ]);
          }

          function renderAPNsSuccessCard(metric) {
            return renderCard('APNs delivery success rate', formatPercent(metric.successRate), metric.refreshedAt, [
              { label: 'Sent', value: String(metric.sentCount) },
              { label: 'Failed', value: String(metric.failedCount) },
              { label: 'Top failures', value: joinedReasons(metric.topFailureReasons) }
            ]);
          }

          function renderNoOpCard(metric) {
            return renderCard('Send no-op rate by reason', formatPercent(metric.noOpRate), metric.refreshedAt, [
              { label: 'Total attempts', value: String(metric.totalAttemptCount) },
              { label: 'No-op attempts', value: String(metric.noOpAttemptCount) },
              { label: 'Reasons', value: joinedReasons(metric.reasons) }
            ]);
          }

          function renderZeroCandidateCard(metric) {
            return renderCard('Zero-candidate revision rate', formatPercent(metric.zeroCandidateRate), metric.refreshedAt, [
              { label: 'Candidate-resolution attempts', value: String(metric.candidateResolutionAttemptCount) },
              { label: 'Zero-candidate attempts', value: String(metric.zeroCandidateAttemptCount) }
            ]);
          }

          function renderCoverageCard(metric) {
            return renderCard('Fresh targetable coverage', formatPercent(metric.targetableRate), metric.refreshedAt, [
              { label: 'Targetable', value: `${metric.targetableInstallationCount} / ${metric.activeSubscribedInstallationCount}` },
              { label: 'Missing token', value: String(metric.lossBreakdown.missingDeviceTokenCount) },
              { label: 'Stale install', value: String(metric.lossBreakdown.staleInstallationHeartbeatCount) },
              { label: 'Stale presence', value: String(metric.lossBreakdown.stalePresenceCount) },
              { label: 'Missing targeting', value: String(metric.lossBreakdown.missingTargetingDataCount) }
            ]);
          }

          function renderH3Card(metric) {
            return renderCard('Geography to H3 conversion', formatPercent(metric.successRate), metric.refreshedAt, [
              { label: 'Geometry-bearing revisions', value: String(metric.geometryBearingRevisionCount) },
              { label: 'Successful conversions', value: String(metric.successfulConversionCount) },
              { label: 'p95 conversion', value: formatDuration(metric.p95ConversionSeconds === null ? null : Math.round(metric.p95ConversionSeconds)) }
            ]);
          }

          function renderRecentDebugRow(entry) {
            return `
              <tr>
                <td>${escapeHtml(formatDate(entry.createdAt))}</td>
                <td>
                  <div>${escapeHtml(entry.eventName)}</div>
                  <div class="subtle mono">${escapeHtml(entry.seriesID)}</div>
                </td>
                <td>
                  <span class="pill">${escapeHtml(entry.mode)}</span>
                  <div class="subtle">${escapeHtml(entry.reason)} / ${escapeHtml(entry.recordKind)}</div>
                </td>
                <td>
                  <div><strong>${escapeHtml(entry.title)}</strong></div>
                  <div class="subtle">${escapeHtml(entry.subtitle)}</div>
                  <div class="subtle">${escapeHtml(entry.body)}</div>
                </td>
                <td>
                  <div>${escapeHtml(entry.ledgerStatus ?? 'preview')}</div>
                  <div class="subtle">${escapeHtml(entry.apnsErrorCode ?? 'none')}</div>
                </td>
              </tr>
            `;
          }

          function renderRecentDebugTable(metric) {
            const body = !Array.isArray(metric.entries) || metric.entries.length === 0
              ? '<div class="empty">No recent notification debug entries.</div>'
              : `
                <table>
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
                <div style="padding: 18px 18px 0;">
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
                <td>${escapeHtml(formatDate(entry.touchedAt))}</td>
                <td>
                  <div>${escapeHtml(entry.eventName)}</div>
                  <div class="subtle mono">${escapeHtml(entry.seriesID)}</div>
                  <div class="subtle micro-mono">${escapeHtml(entry.currentRevisionUrn)}</div>
                </td>
                <td><span class="pill">${escapeHtml(entry.state)}</span></td>
                <td>${escapeHtml(entry.tornadoDetection ?? 'none')}</td>
                <td>${escapeHtml(entry.tornadoDamageThreat ?? 'none')}</td>
                <td class="mono">${escapeHtml(joinedCodes(entry.ugcCodes))}</td>
              </tr>
            `;
          }

          function renderTouchedSeriesTable(metric) {
            const body = !Array.isArray(metric.entries) || metric.entries.length === 0
              ? '<div class="empty">No recently touched series.</div>'
              : `
                <table>
                  <thead>
                    <tr>
                      <th>Touched</th>
                      <th>Alert</th>
                      <th>State</th>
                      <th>Tornado detection</th>
                      <th>Tornado damage threat</th>
                      <th>ugc_codes</th>
                    </tr>
                  </thead>
                  <tbody>
                    ${metric.entries.map(renderTouchedSeriesRow).join('')}
                  </tbody>
                </table>
              `;

            return `
              <div class="card table-card">
                <div style="padding: 18px 18px 0;">
                  <h3>Last 5 touched series</h3>
                  <div class="subtle">Refreshed ${escapeHtml(formatDate(metric.refreshedAt))}</div>
                </div>
                ${body}
              </div>
            `;
          }

          function refreshKey(value) {
            return value ?? 'none';
          }

          function swapHTML(id, html) {
            const node = document.getElementById(id);
            if (!node) {
              return;
            }

            node.classList.add('is-updating');
            node.innerHTML = html;
            window.requestAnimationFrame(() => node.classList.remove('is-updating'));
          }

          function updateSlot(id, key, html) {
            if (state.refreshKeys[id] === key) {
              return;
            }

            state.refreshKeys[id] = key;
            swapHTML(id, html);
          }

          function updateHero(snapshot) {
            const renderedNode = document.getElementById('hero-rendered-at');
            if (renderedNode) {
              renderedNode.textContent = `Rendered ${formatDate(snapshot.renderedAt)}`;
            }

            const generatedNode = document.getElementById('hero-generated-at');
            if (generatedNode) {
              generatedNode.textContent = `Snapshot generated ${formatDate(snapshot.generatedAt)}`;
            }
          }

          function applySnapshot(snapshot) {
            updateHero(snapshot);
            updateSlot('ingest-card', refreshKey(snapshot.redLights.ingestFreshness.refreshedAt), renderIngestCard(snapshot.redLights.ingestFreshness));
            updateSlot('pipeline-backlog-card', refreshKey(snapshot.redLights.pipelineBacklogAge.refreshedAt), renderPipelineBacklogCard(snapshot.redLights.pipelineBacklogAge));
            updateSlot('stuck-claimed-card', refreshKey(snapshot.redLights.stuckClaimedRows.refreshedAt), renderStuckClaimedCard(snapshot.redLights.stuckClaimedRows));
            updateSlot('stale-series-card', refreshKey(snapshot.redLights.staleActiveSeriesCount.refreshedAt), renderStaleSeriesCard(snapshot.redLights.staleActiveSeriesCount));
            updateSlot('latency-card', refreshKey(snapshot.deliveryKPIs.endToEndAlertLatency.refreshedAt), renderLatencyCard(snapshot.deliveryKPIs.endToEndAlertLatency));
            updateSlot('apns-success-card', refreshKey(snapshot.deliveryKPIs.apnsDeliverySuccessRate.refreshedAt), renderAPNsSuccessCard(snapshot.deliveryKPIs.apnsDeliverySuccessRate));
            updateSlot('noop-card', refreshKey(snapshot.deliveryKPIs.sendNoOpRateByReason.refreshedAt), renderNoOpCard(snapshot.deliveryKPIs.sendNoOpRateByReason));
            updateSlot('zero-candidate-card', refreshKey(snapshot.deliveryKPIs.zeroCandidateRevisionRate.refreshedAt), renderZeroCandidateCard(snapshot.deliveryKPIs.zeroCandidateRevisionRate));
            updateSlot('coverage-card', refreshKey(snapshot.audienceTargeting.freshTargetableInstallationCoverage.refreshedAt), renderCoverageCard(snapshot.audienceTargeting.freshTargetableInstallationCoverage));
            updateSlot('h3-card', refreshKey(snapshot.audienceTargeting.alertsWithGeographyAndH3Success.refreshedAt), renderH3Card(snapshot.audienceTargeting.alertsWithGeographyAndH3Success));
            updateSlot('recent-debug-table', refreshKey(snapshot.operatorContext.recentNotificationDebugEntries.refreshedAt), renderRecentDebugTable(snapshot.operatorContext.recentNotificationDebugEntries));
            updateSlot('touched-series-table', refreshKey(snapshot.operatorContext.lastTouchedSeries.refreshedAt), renderTouchedSeriesTable(snapshot.operatorContext.lastTouchedSeries));
          }

          async function fetchSnapshot() {
            if (state.inFlight) {
              return;
            }

            state.inFlight = true;
            try {
              const response = await fetch('/v1/metrics', {
                headers: { 'Accept': 'application/json' },
                cache: 'no-store'
              });

              if (!response.ok) {
                return;
              }

              const snapshot = await response.json();
              const generatedAtMs = dateToMillis(snapshot.generatedAt);
              if (generatedAtMs !== null && generatedAtMs === state.lastGeneratedAtMs) {
                return;
              }

              applySnapshot(snapshot);
              state.lastGeneratedAtMs = generatedAtMs;
            } catch (_) {
            } finally {
              state.inFlight = false;
            }
          }

          window.setInterval(fetchSnapshot, pollIntervalMs);
          window.addEventListener('focus', fetchSnapshot);
          document.addEventListener('visibilitychange', function() {
            if (document.visibilityState === 'visible') {
              fetchSnapshot();
            }
          });
          fetchSnapshot();
        })();
        </script>
        """#
    }

    private static func unavailablePollingScript(pollIntervalMilliseconds: Int) -> String {
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

    private static func ingestCard(_ metric: IngestFreshnessMetricResponse) -> String {
        card(
            title: "Ingest freshness",
            primary: maybeDuration(metric.timeSinceLastSuccessfulSweepSeconds),
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Last success", maybeDate(metric.lastSuccessfulSweepAt)),
                ("Last attempt", maybeDate(metric.lastAttemptAt)),
                ("Recent", "\(metric.recentSuccessCount) success / \(metric.recentFailureCount) failure"),
                ("Last error", metric.lastFailureMessage ?? "none")
            ]
        )
    }

    private static func pipelineBacklogCard(_ metric: PipelineBacklogMetricResponse) -> String {
        card(
            title: "Pipeline backlog age",
            primary: "Target \(maybeDuration(metric.oldestPendingTargetDispatchAgeSeconds))",
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Pending target rows", "\(metric.pendingTargetDispatchCount)"),
                ("Oldest target row", maybeDate(metric.oldestPendingTargetDispatchCreatedAt)),
                ("Notification backlog", maybeDuration(metric.oldestPendingNotificationDispatchAgeSeconds)),
                ("Pending notification rows", "\(metric.pendingNotificationDispatchCount)")
            ]
        )
    }

    private static func stuckClaimedCard(_ metric: StuckClaimedRowsMetricResponse) -> String {
        card(
            title: "Stuck claimed rows",
            primary: "\(metric.count)",
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Threshold", maybeDuration(metric.thresholdSeconds)),
                ("Oldest claim age", maybeDuration(metric.oldestClaimedAgeSeconds)),
                ("Oldest claim", maybeDate(metric.oldestClaimedCreatedAt))
            ]
        )
    }

    private static func staleSeriesCard(_ metric: StaleActiveSeriesMetricResponse) -> String {
        card(
            title: "Stale active series",
            primary: "\(metric.count)",
            refreshedAt: metric.refreshedAt,
            lines: [("Grace window", maybeDuration(metric.graceSeconds))]
        )
    }

    private static func latencyCard(_ metric: EndToEndLatencyMetricResponse) -> String {
        card(
            title: "End-to-end alert latency p95",
            primary: maybeDuration(metric.p95Seconds.flatMap { Int($0.rounded()) }),
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Window", "\(metric.windowHours)h"),
                ("Successful revisions", "\(metric.successfulRevisionCount)")
            ]
        )
    }

    private static func apnsSuccessCard(_ metric: APNsDeliveryMetricResponse) -> String {
        card(
            title: "APNs delivery success rate",
            primary: maybePercent(metric.successRate),
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Sent", "\(metric.sentCount)"),
                ("Failed", "\(metric.failedCount)"),
                ("Top failures", joinedReasons(metric.topFailureReasons))
            ]
        )
    }

    private static func noOpCard(_ metric: SendNoOpsMetricResponse) -> String {
        card(
            title: "Send no-op rate by reason",
            primary: maybePercent(metric.noOpRate),
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Total attempts", "\(metric.totalAttemptCount)"),
                ("No-op attempts", "\(metric.noOpAttemptCount)"),
                ("Reasons", joinedReasons(metric.reasons))
            ]
        )
    }

    private static func zeroCandidateCard(_ metric: ZeroCandidateRateMetricResponse) -> String {
        card(
            title: "Zero-candidate revision rate",
            primary: maybePercent(metric.zeroCandidateRate),
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Candidate-resolution attempts", "\(metric.candidateResolutionAttemptCount)"),
                ("Zero-candidate attempts", "\(metric.zeroCandidateAttemptCount)")
            ]
        )
    }

    private static func coverageCard(_ metric: TargetableCoverageMetricResponse) -> String {
        card(
            title: "Fresh targetable coverage",
            primary: maybePercent(metric.targetableRate),
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Targetable", "\(metric.targetableInstallationCount) / \(metric.activeSubscribedInstallationCount)"),
                ("Missing token", "\(metric.lossBreakdown.missingDeviceTokenCount)"),
                ("Stale install", "\(metric.lossBreakdown.staleInstallationHeartbeatCount)"),
                ("Stale presence", "\(metric.lossBreakdown.stalePresenceCount)"),
                ("Missing targeting", "\(metric.lossBreakdown.missingTargetingDataCount)")
            ]
        )
    }

    private static func h3Card(_ metric: H3DerivationMetricResponse) -> String {
        card(
            title: "Geography to H3 conversion",
            primary: maybePercent(metric.successRate),
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Geometry-bearing revisions", "\(metric.geometryBearingRevisionCount)"),
                ("Successful conversions", "\(metric.successfulConversionCount)"),
                ("p95 conversion", maybeDuration(metric.p95ConversionSeconds.flatMap { Int($0.rounded()) }))
            ]
        )
    }

    private static func recentDebugTable(_ metric: RecentNotificationDebugEntriesResponse) -> String {
        let body: String
        if metric.entries.isEmpty {
            body = #"<div class="empty">No recent notification debug entries.</div>"#
        } else {
            body = """
            <table>
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
            """
        }

        return """
        <div class="card table-card">
          <div style="padding: 18px 18px 0;">
            <h3>Recent notification debug entries</h3>
            <div class="subtle">Refreshed \(escape(maybeDate(metric.refreshedAt)))</div>
          </div>
          \(body)
        </div>
        """
    }

    private static func touchedSeriesTable(_ metric: LastTouchedSeriesResponse) -> String {
        let body: String
        if metric.entries.isEmpty {
            body = #"<div class="empty">No recently touched series.</div>"#
        } else {
            body = """
            <table>
              <thead>
                <tr>
                  <th>Touched</th>
                  <th>Alert</th>
                  <th>State</th>
                  <th>Tornado detection</th>
                  <th>Tornado damage threat</th>
                  <th>ugc_codes</th>
                </tr>
              </thead>
              <tbody>
                \(metric.entries.map(renderTouchedSeriesRow).joined())
              </tbody>
            </table>
            """
        }

        return """
        <div class="card table-card">
          <div style="padding: 18px 18px 0;">
            <h3>Last 5 touched series</h3>
            <div class="subtle">Refreshed \(escape(maybeDate(metric.refreshedAt)))</div>
          </div>
          \(body)
        </div>
        """
    }

    private static func renderDebugRow(_ entry: RecentNotificationDebugEntryResponse) -> String {
        """
        <tr>
          <td>\(escape(formatDate(entry.createdAt)))</td>
          <td>
            <div>\(escape(entry.eventName))</div>
            <div class="subtle mono">\(escape(entry.seriesID.uuidString))</div>
          </td>
          <td>
            <span class="pill">\(escape(entry.mode))</span>
            <div class="subtle">\(escape(entry.reason)) / \(escape(entry.recordKind))</div>
          </td>
          <td>
            <div><strong>\(escape(entry.title))</strong></div>
            <div class="subtle">\(escape(entry.subtitle))</div>
            <div class="subtle">\(escape(entry.body))</div>
          </td>
          <td>
            <div>\(escape(entry.ledgerStatus ?? "preview"))</div>
            <div class="subtle">\(escape(entry.apnsErrorCode ?? "none"))</div>
          </td>
        </tr>
        """
    }

    private static func renderTouchedSeriesRow(_ entry: TouchedSeriesEntryResponse) -> String {
        """
        <tr>
          <td>\(escape(formatDate(entry.touchedAt)))</td>
          <td>
            <div>\(escape(entry.eventName))</div>
            <div class="subtle mono">\(escape(entry.seriesID.uuidString))</div>
            <div class="subtle micro-mono">\(escape(entry.currentRevisionUrn))</div>
          </td>
          <td><span class="pill">\(escape(entry.state))</span></td>
          <td>\(escape(entry.tornadoDetection ?? "none"))</td>
          <td>\(escape(entry.tornadoDamageThreat ?? "none"))</td>
          <td class="mono">\(escape(joinedCodes(entry.ugcCodes)))</td>
        </tr>
        """
    }

    private static func card(
        title: String,
        primary: String,
        refreshedAt: Date?,
        lines: [(String, String)]
    ) -> String {
        """
        <div class="card">
          <h3>\(escape(title))</h3>
          <div class="primary">\(escape(primary))</div>
          <div class="subtle">Refreshed \(escape(maybeDate(refreshedAt)))</div>
          <ul class="meta-list">
            \(lines.map { "<li><span>\(escape($0.0))</span><strong>\(escape($0.1))</strong></li>" }.joined())
          </ul>
        </div>
        """
    }

    private static func joinedReasons(_ reasons: [ReasonBreakdownResponse]) -> String {
        guard reasons.isEmpty == false else { return "none" }
        return reasons.map { "\($0.reason) (\($0.count))" }.joined(separator: ", ")
    }

    private static func joinedCodes(_ codes: [String]) -> String {
        guard codes.isEmpty == false else { return "none" }
        return codes.joined(separator: ", ")
    }

    private static func maybeDate(_ date: Date?) -> String {
        guard let date else { return "n/a" }
        return formatDate(date)
    }

    private static func maybeDuration(_ seconds: Int?) -> String {
        guard let seconds else { return "n/a" }
        return formatDuration(seconds)
    }

    private static func maybePercent(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return formatPercent(value)
    }

    private static func formatDate(_ date: Date) -> String {
        DateFormatter.dashboardDateFormatter.string(from: date)
    }

    private static func formatPercent(_ value: Double) -> String {
        let percent = value * 100
        return String(format: "%.1f%%", percent)
    }

    private static func formatDuration(_ seconds: Int) -> String {
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

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private extension DateFormatter {
    static let dashboardDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss z"
        return formatter
    }()
}
