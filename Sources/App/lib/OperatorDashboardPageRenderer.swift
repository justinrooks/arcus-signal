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
              padding: 28px max(env(safe-area-inset-right), 0px) calc(40px + env(safe-area-inset-bottom)) max(env(safe-area-inset-left), 0px);
            }
            @media (min-width: 721px) and (max-width: 1120px) {
              .shell {
                width: min(1080px, calc(100vw - 28px));
                padding: 20px 0 32px;
              }
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
            .table-wrap {
              position: relative;
              width: 100%;
              overflow-x: auto;
              -webkit-overflow-scrolling: touch;
            }
            .stream-table {
              min-width: 720px;
            }
            .pressure-artifact-table {
              min-width: 920px;
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
            .stream-table tbody tr {
              opacity: 1;
              transform: translateY(0);
            }
            .stream-table tbody tr.stream-row {
              opacity: 0;
              transform: translateY(8px);
              animation: streamIn 380ms cubic-bezier(0.2, 0.68, 0.22, 0.99) forwards;
            }
            @keyframes streamIn {
              to {
                opacity: 1;
                transform: translateY(0);
              }
            }
            @media (min-width: 721px) and (max-width: 1120px) {
              .grid {
                grid-template-columns: repeat(2, minmax(0, 1fr));
              }
              th, td {
                padding: 11px 12px;
              }
              td {
                font-size: 0.9rem;
              }
              .micro-mono {
                font-size: 0.6rem;
              }
            }
            @media (max-width: 720px) {
              .shell {
                width: calc(100vw - 18px);
                padding-top: 16px;
                padding-bottom: calc(28px + env(safe-area-inset-bottom));
              }
              .section {
                margin-top: 18px;
              }
              .section h2 {
                margin-bottom: 10px;
                font-size: 0.92rem;
                letter-spacing: 0.1em;
              }
              .hero {
                padding: 16px;
                border-radius: 18px;
                flex-direction: column;
                align-items: stretch;
              }
              .hero h1 {
                font-size: clamp(1.5rem, 8vw, 2rem);
                letter-spacing: -0.02em;
              }
              .hero p {
                margin-top: 8px;
                font-size: 0.92rem;
                line-height: 1.4;
              }
              .hero-meta {
                text-align: left;
                font-size: 0.86rem;
              }
              .card {
                padding: 14px;
                border-radius: 16px;
              }
              .card h3 {
                font-size: 0.82rem;
              }
              .primary {
                margin: 10px 0 5px;
                font-size: 1.6rem;
              }
              .grid {
                grid-template-columns: 1fr;
                gap: 12px;
              }
              .stack {
                gap: 12px;
              }
              .meta-list {
                margin-top: 10px;
              }
              .meta-list li {
                gap: 10px;
                padding: 8px 0;
                font-size: 0.86rem;
              }
              .subtle {
                font-size: 0.84rem;
              }
              .pill {
                font-size: 0.72rem;
                padding: 3px 8px;
              }
              th, td {
                padding: 12px;
              }
              .stream-table {
                min-width: 640px;
              }
              .inline-mobile-table {
                min-width: 0;
                width: 100%;
                border-collapse: separate;
                border-spacing: 0;
              }
              .inline-mobile-table thead {
                display: none;
              }
              .inline-mobile-table tbody {
                display: grid;
                gap: 14px;
                padding: 12px 12px 14px;
              }
              .inline-mobile-table tbody tr {
                display: grid;
                gap: 9px;
                padding: 12px;
                border: 1px solid rgba(117, 165, 196, 0.24);
                border-radius: 12px;
                background: linear-gradient(180deg, rgba(19, 40, 63, 0.34), rgba(12, 27, 45, 0.2));
                box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.04), 0 8px 20px rgba(1, 8, 16, 0.35);
              }
              .inline-mobile-table tbody td {
                display: grid;
                grid-template-columns: minmax(96px, 34%) 1fr;
                gap: 10px;
                padding: 0;
                border: 0;
                font-size: 0.86rem;
              }
              .inline-mobile-table tbody td + td {
                padding-top: 3px;
                border-top: 1px solid rgba(117, 165, 196, 0.14);
              }
            .inline-mobile-table tbody td::before {
                content: attr(data-label);
                color: var(--muted);
                font-size: 0.72rem;
                letter-spacing: 0.04em;
                text-transform: uppercase;
            }
              .inline-mobile-table .narrow-truncate {
                display: inline-block;
                max-width: 15ch;
                overflow: hidden;
                text-overflow: ellipsis;
                white-space: nowrap;
                direction: rtl;
                text-align: left;
                vertical-align: bottom;
              }
            }
            @media (max-width: 430px) {
              .shell {
                width: calc(100vw - 12px);
                padding-top: 12px;
              }
              .hero {
                padding: 14px;
                border-radius: 14px;
              }
              .section h2 {
                font-size: 0.84rem;
              }
              .card {
                padding: 12px;
              }
              .primary {
                font-size: 1.45rem;
              }
              .meta-list li {
                font-size: 0.82rem;
              }
              .mono {
                font-size: 0.72rem;
              }
              .micro-mono {
                font-size: 0.5rem;
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
              <h2>Growth / Usage</h2>
              <div class="grid">
                \(slot("known-installations-card", content: knownInstallationsCard(snapshot.growthUsage.installationGrowth)))
                \(slot("new-installations-card", content: newInstallationsCard(snapshot.growthUsage.installationGrowth)))
                \(slot("recent-server-activity-card", content: recentServerActivityCard(snapshot.growthUsage.installationGrowth)))
              </div>
              <div class="stack" style="margin-top: 16px;">
                \(slot("installation-growth-table", content: installationGrowthTable(snapshot.growthUsage.installationGrowth)))
              </div>
            </section>

            <section class="section">
              <h2>Model Artifacts</h2>
              <div class="grid">
                \(slot("pressure-artifact-readiness-card", content: pressureArtifactReadinessCard(snapshot.modelArtifacts.pressureArtifactReadiness)))
                \(slot("pressure-artifact-catalog-card", content: pressureArtifactCatalogCard(snapshot.modelArtifacts.pressureArtifactCatalog)))
              </div>
              <div class="stack" style="margin-top: 16px;">
                \(slot("recent-pressure-artifacts-table", content: recentPressureArtifactsTable(snapshot.modelArtifacts.recentPressureArtifacts)))
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
          const hiddenPollIntervalMs = Math.max(pollIntervalMs * 3, pollIntervalMs + 5_000);
          const state = {
            inFlight: false,
            lastGeneratedAtMs: \#(initialGeneratedAtMilliseconds),
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

          function renderCard(title, primary, refreshedAt, lines, primaryClass = '') {
            const primaryClassSuffix = primaryClass ? ` ${primaryClass}` : '';
            return `
              <div class="card">
                <h3>${escapeHtml(title)}</h3>
                <div class="primary${primaryClassSuffix}">${escapeHtml(primary)}</div>
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
                <div style="padding: 18px 18px 0;">
                  <h3>Monthly Installation Growth</h3>
                  <div class="subtle">Refreshed ${escapeHtml(formatDate(metric.refreshedAt))}</div>
                </div>
                ${body}
              </div>
            `;
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
            return renderCard('Candidate-query eligibility', formatPercent(metric.candidateQueryEligibilityRate), metric.refreshedAt, [
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
            return renderCard('Geography to H3 conversion', formatPercent(metric.successRate), metric.refreshedAt, [
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
            const lines = [
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

            return renderCard(
              'Pressure artifact readiness',
              renderPressureArtifactOutcome(metric?.selectionOutcome),
              metric?.refreshedAt,
              lines,
              renderPressureArtifactOutcomeClass(metric?.selectionOutcome)
            );
          }

          function renderPressureArtifactCatalogCard(metric) {
            return renderCard('Pressure artifact catalog', `${metric?.readyCount ?? 0} ready`, metric?.refreshedAt, [
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
            ]);
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
                <td data-label="Error">${escapeHtml(entry.errorSummary ?? 'none')}</td>
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
                <div style="padding: 18px 18px 0;">
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
                  <div class="subtle mono">${escapeHtml(entry.seriesID)}</div>
                </td>
                <td data-label="Mode / reason">
                  <span class="pill">${escapeHtml(entry.mode)}</span>
                  <div class="subtle">${escapeHtml(entry.reason)} / ${escapeHtml(entry.recordKind)}</div>
                </td>
                <td data-label="Message">
                  <div><strong>${escapeHtml(entry.title)}</strong></div>
                  <div class="subtle">${escapeHtml(entry.subtitle)}</div>
                  <div class="subtle">${escapeHtml(entry.body)}</div>
                </td>
                <td data-label="Outcome">
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
                <td data-label="Touched">${escapeHtml(formatDate(entry.touchedAt))}</td>
                <td data-label="Alert">
                  <div>${escapeHtml(entry.eventName)}</div>
                  <div class="subtle mono">${escapeHtml(entry.seriesID)}</div>
                  <div class="subtle micro-mono narrow-truncate" title="${escapeHtml(entry.currentRevisionUrn)}">${escapeHtml(entry.currentRevisionUrn)}</div>
                </td>
                <td data-label="State"><span class="pill">${escapeHtml(entry.state)}</span></td>
                <td data-label="Tornado detection">${escapeHtml(entry.tornadoDetection ?? 'none')}</td>
                <td data-label="Tornado damage">${escapeHtml(entry.tornadoDamageThreat ?? 'none')}</td>
                <td data-label="ugc_codes" class="mono">${escapeHtml(joinedCodes(entry.ugcCodes))}</td>
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
            updateSlot('known-installations-card', refreshKey(snapshot.growthUsage.installationGrowth.refreshedAt), renderKnownInstallationsCard(snapshot.growthUsage.installationGrowth));
            updateSlot('new-installations-card', refreshKey(snapshot.growthUsage.installationGrowth.refreshedAt), renderNewInstallationsCard(snapshot.growthUsage.installationGrowth));
            updateSlot('recent-server-activity-card', refreshKey(snapshot.growthUsage.installationGrowth.refreshedAt), renderRecentServerActivityCard(snapshot.growthUsage.installationGrowth));
            updateSlot(
              'installation-growth-table',
              refreshKey(snapshot.growthUsage.installationGrowth.refreshedAt),
              renderInstallationGrowthTable(snapshot.growthUsage.installationGrowth),
              { streamRows: true, streamDelayStepMs: 28 }
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
              scheduleNextPoll();
            }
          }

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

    private static func knownInstallationsCard(_ metric: InstallationGrowthMetricResponse) -> String {
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

    private static func newInstallationsCard(_ metric: InstallationGrowthMetricResponse) -> String {
        card(
            title: "New This Month",
            primary: "\(metric.newThisMonthCount)",
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Month", metric.monthlyGrowth.last.map { formatMonth($0.monthStart) } ?? "n/a")
            ]
        )
    }

    private static func recentServerActivityCard(_ metric: InstallationGrowthMetricResponse) -> String {
        card(
            title: "Seen Last 24h — Server Activity",
            primary: "\(metric.seenLast24HoursCount)",
            refreshedAt: metric.refreshedAt,
            lines: [
                ("Share of known", maybePercent(metric.seenLast24HoursRate)),
                ("Interpretation", "Operational activity, not DAU")
            ]
        )
    }

    private static func installationGrowthTable(_ metric: InstallationGrowthMetricResponse) -> String {
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
          <div style="padding: 18px 18px 0;">
            <h3>Monthly Installation Growth</h3>
            <div class="subtle">Refreshed \(escape(maybeDate(metric.refreshedAt)))</div>
          </div>
          \(body)
        </div>
        """
    }

    private static func installationGrowthRow(_ entry: MonthlyInstallationGrowthResponse) -> String {
        """
        <tr>
          <td data-label="Month">\(escape(formatMonth(entry.monthStart)))</td>
          <td data-label="New installations">\(entry.newInstallationCount)</td>
          <td data-label="Cumulative total">\(entry.cumulativeInstallationCount)</td>
        </tr>
        """
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
            title: "Candidate-query eligibility",
            primary: maybePercent(metric.candidateQueryEligibilityRate),
            refreshedAt: metric.refreshedAt,
            lines: [
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

    private static func pressureArtifactReadinessCard(_ metric: PressureArtifactReadinessMetricResponse?) -> String {
        let metric = metric ?? .init(refreshedAt: nil, renderedAt: .now, metric: .init())
        var lines: [(String, String)] = [
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
            lines.insert(("Readiness reason", readinessReason), at: 1)
        }
        if let errorSummary = metric.errorSummary {
            lines.append(("Error", errorSummary))
        }

        return card(
            title: "Pressure artifact readiness",
            primary: pressureArtifactOutcome(metric.selectionOutcome),
            primaryClass: pressureArtifactOutcomeClass(metric.selectionOutcome),
            refreshedAt: metric.refreshedAt,
            lines: lines
        )
    }

    private static func pressureArtifactCatalogCard(_ metric: PressureArtifactCatalogMetricResponse?) -> String {
        let metric = metric ?? .init(refreshedAt: nil, metric: .init())
        return card(
            title: "Pressure artifact catalog",
            primary: "\(metric.readyCount) ready",
            refreshedAt: metric.refreshedAt,
            lines: [
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
            ]
        )
    }

    private static func recentPressureArtifactsTable(_ metric: RecentPressureArtifactEntriesResponse?) -> String {
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
                  <th>Source</th>
                  <th>Size</th>
                  <th>Updated</th>
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
          <div style="padding: 18px 18px 0;">
            <h3>Recent pressure artifacts</h3>
            <div class="subtle">Refreshed \(escape(maybeDate(metric.refreshedAt)))</div>
          </div>
          \(body)
        </div>
        """
    }

    private static func renderPressureArtifactRow(_ entry: PressureArtifactEntryResponse) -> String {
        """
        <tr>
          <td data-label="Valid time">\(escape(maybeDate(entry.validTime)))</td>
          <td data-label="Run / FH">\(escape(pressureArtifactRunAndForecast(entry.runTime, entry.forecastHour)))</td>
          <td data-label="Status"><span class="pill \(escape(statusClass(entry.status)))">\(escape(pressureArtifactStatus(entry.status)))</span></td>
          <td data-label="Source">\(escape(entry.source))</td>
          <td data-label="Size" class="mono">\(escape(maybeByteSize(entry.byteSize)))</td>
          <td data-label="Updated">\(escape(maybeDate(entry.updatedAt)))</td>
          <td data-label="Error">\(escape(entry.errorSummary ?? "none"))</td>
        </tr>
        """
    }

    private static func recentDebugTable(_ metric: RecentNotificationDebugEntriesResponse) -> String {
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
            <div class="table-wrap">
            <table class="stream-table inline-mobile-table">
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
            </div>
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
          <td data-label="Time">\(escape(formatDate(entry.createdAt)))</td>
          <td data-label="Alert">
            <div>\(escape(entry.eventName))</div>
            <div class="subtle mono">\(escape(entry.seriesID.uuidString))</div>
          </td>
          <td data-label="Mode / reason">
            <span class="pill">\(escape(entry.mode))</span>
            <div class="subtle">\(escape(entry.reason)) / \(escape(entry.recordKind))</div>
          </td>
          <td data-label="Message">
            <div><strong>\(escape(entry.title))</strong></div>
            <div class="subtle">\(escape(entry.subtitle))</div>
            <div class="subtle">\(escape(entry.body))</div>
          </td>
          <td data-label="Outcome">
            <div>\(escape(entry.ledgerStatus ?? "preview"))</div>
            <div class="subtle">\(escape(entry.apnsErrorCode ?? "none"))</div>
          </td>
        </tr>
        """
    }

    private static func renderTouchedSeriesRow(_ entry: TouchedSeriesEntryResponse) -> String {
        """
        <tr>
          <td data-label="Touched">\(escape(formatDate(entry.touchedAt)))</td>
          <td data-label="Alert">
            <div>\(escape(entry.eventName))</div>
            <div class="subtle mono">\(escape(entry.seriesID.uuidString))</div>
            <div class="subtle micro-mono narrow-truncate" title="\(escape(entry.currentRevisionUrn))">\(escape(entry.currentRevisionUrn))</div>
          </td>
          <td data-label="State"><span class="pill">\(escape(entry.state))</span></td>
          <td data-label="Tornado detection">\(escape(entry.tornadoDetection ?? "none"))</td>
          <td data-label="Tornado damage">\(escape(entry.tornadoDamageThreat ?? "none"))</td>
          <td data-label="ugc_codes" class="mono">\(escape(joinedCodes(entry.ugcCodes)))</td>
        </tr>
        """
    }

    private static func card(
        title: String,
        primary: String,
        primaryClass: String? = nil,
        refreshedAt: Date?,
        lines: [(String, String)]
    ) -> String {
        let primaryClassAttribute = primaryClass.map { " \($0)" } ?? ""
        return """
        <div class="card">
          <h3>\(escape(title))</h3>
          <div class="primary\(primaryClassAttribute)">\(escape(primary))</div>
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

    private static func pressureArtifactOutcome(_ outcome: PressureArtifactReadinessSelectionOutcome?) -> String {
        guard let outcome else { return "NO DATA" }
        return outcome.rawValue.uppercased()
    }

    private static func pressureArtifactOutcomeClass(_ outcome: PressureArtifactReadinessSelectionOutcome?) -> String? {
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

    private static func pressureArtifactStatus(_ status: String?) -> String {
        guard let status, status.isEmpty == false else { return "NO DATA" }
        return status.uppercased()
    }

    private static func pressureArtifactRunAndForecast(_ runTime: Date?, _ forecastHour: Int?) -> String {
        guard let runTime else { return "n/a" }
        guard let forecastHour else { return formatDate(runTime) }
        return "\(formatDate(runTime)) / FH \(forecastHour)"
    }

    private static func maybeByteSize(_ byteSize: Int64?) -> String {
        guard let byteSize else { return "n/a" }
        return formatByteSize(byteSize)
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

    private static func formatPercent(_ value: Double) -> String {
        let percent = value * 100
        return String(format: "%.1f%%", percent)
    }

    private static func formatMonth(_ date: Date) -> String {
        DateFormatter.dashboardMonthFormatter.string(from: date)
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

    private static func formatByteSize(_ byteSize: Int64) -> String {
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

    private static func statusClass(_ status: String?) -> String {
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
