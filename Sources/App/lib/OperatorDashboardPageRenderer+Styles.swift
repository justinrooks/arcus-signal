extension OperatorDashboardPageRenderer {
    static let styles = #"""
/* Control Room prototype port; canonical metrics remain server-owned. */
:root {
  color-scheme: light;
  --bg: #f3f5f5; --surface: #fff; --surface-soft: #f7f9f8;
  --ink: #172b30; --muted: #596b6f; --line: #dbe3e1;
  --accent: #206e64; --good: #247565; --warn: #926017;
  --danger: #ad3844; --warn-bg: #faf0dd; --danger-bg: #f9e9eb;
  --radius: 12px; --space: 24px;
  --sans: "Avenir Next", Avenir, -apple-system, BlinkMacSystemFont, sans-serif;
  --mono: "SFMono-Regular", Consolas, monospace;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 14px/1.45 var(--sans); -webkit-font-smoothing: antialiased; }
a { color: inherit; text-decoration: none; }
a:hover { color: var(--accent); }
button, select { font: inherit; color: inherit; }
button, summary, select { cursor: pointer; }
button, select { background: var(--surface); border: 1px solid var(--line); border-radius: 6px; padding: 8px 12px; }
:where(a,button,summary,select):focus-visible { outline: 2px solid var(--accent); outline-offset: 4px; }
button:hover, select:hover { border-color: var(--muted); }
button:active { background: var(--surface-soft); }
.debug-filter { display:flex; gap:6px; margin:0 0 10px; }
.debug-filter button { padding:5px 10px; border-radius:6px; color:var(--muted); }
.debug-filter button[aria-pressed="true"] { color:var(--ink); border-color:var(--accent); background:var(--surface-soft); }
.debug-filter-empty { margin-top:10px; }
h1,h2,h3,p { margin: 0; text-wrap: pretty; }
h1 { font-size: 30px; letter-spacing: -.045em; line-height: 1.15; font-weight: 600; }
h2 { font-size: 17px; font-weight: 600; letter-spacing: -.025em; }
h3 { font-size: 13px; font-weight: 600; }
small, .meta { color: var(--muted); font-size: 11px; }
.mono, .value, td.num { font-variant-numeric: tabular-nums; }
.mono { font-family: var(--mono); }
.num { text-align: right; }
.good { color: var(--good); }
.warning { color: var(--warn); }
.danger { color: var(--danger); }
.muted { color: var(--muted); }
.skip { position: fixed; left: 16px; top: -60px; z-index: 20; padding: 12px; background: var(--surface); }
.skip:focus { top: 12px; }
.app { max-width: 1296px; margin: auto; padding: 0 32px; }
.masthead { display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 26px 0 20px; }
.wordmark { font-size: 22px; font-weight: 650; letter-spacing: -.055em; }
.environment { font-size: 11px; letter-spacing: .06em; border: 1px solid var(--line); border-radius: 4px; padding: 3px 6px; margin-left: 10px; color: var(--muted); vertical-align: middle; }
.telemetry { display: flex; align-items: center; gap: 12px; font-size: 11px; color: var(--muted); }
.connection { font-weight: 600; color: var(--good); }
.connection::before { content: ''; width: 6px; height: 6px; background: currentColor; display: inline-block; border-radius: 50%; margin-right: 6px; }
.primary-nav { display: flex; align-items: center; gap: 28px; border-bottom: 1px solid var(--line); }
.primary-nav a { padding: 12px 0; color: var(--muted); font-size: 12px; white-space: nowrap; }
.primary-nav a[aria-current] { color: var(--ink); font-weight: 650; box-shadow: inset 0 -2px var(--accent); }
.nav-index { display: none; }
.sidebar-note { display: none; }
.page-head { display: flex; justify-content: space-between; gap: 20px; align-items: center; padding: 26px 0 20px; }
.page-head p { margin-top: 5px; color: var(--muted); font-size: 12px; }
.dateline { color: var(--muted); font-size: 11px; text-align: right; }
.freshness-notice { display: none; padding: 13px 18px; background: var(--warn-bg); border: 1px solid var(--warn); border-radius: 6px; margin-bottom: 16px; font-size: 13px; }
.overview-grid { display: grid; grid-template-columns: repeat(12,minmax(0,1fr)); gap: 20px; align-items: stretch; }
.module { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); padding: var(--space); min-width: 0; }
.module-head { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; margin-bottom: 18px; }
.module-head a { font-size: 11px; color: var(--muted); white-space: nowrap; }
.module-head a:hover { color: var(--accent); }
.module-head p { color: var(--muted); font-size: 11px; margin-top: 3px; }
.health { grid-column: 1/-1; padding: 0; border: 0; background: transparent; }
.health-top { display: flex; align-items: center; justify-content: space-between; gap: 20px; padding: 15px 18px; background: var(--warn-bg); border: 1px solid color-mix(in srgb,var(--warn) 20%,transparent); border-radius: 8px; margin-bottom: 16px; }
.health-top strong { font-weight: 600; font-size: 14px; }
.health-top a { font-size: 11px; white-space: nowrap; }
.health-label { font-size: 11px; text-transform: uppercase; letter-spacing: .1em; color: var(--muted); margin-bottom: 4px; }
.health-rail { display: grid; grid-template-columns: repeat(4,minmax(0,1fr)); padding: 4px 0 2px; }
.health-item { padding: 0 20px; border-right: 1px solid var(--line); }
.health-item:first-child { padding-left: 2px; }
.health-item:last-child { border: 0; }
.health-item h3 { color: var(--muted); font-size: 11px; }
.health-reading { display: flex; gap: 10px; align-items: baseline; margin: 4px 0; }
.health-reading strong { font-size: 25px; font-weight: 500; letter-spacing: -.04em; }
.health-reading span { font-size: 11px; }
.health-item p { font-size: 11px; color: var(--muted); }
.health details { margin-top: 6px; font-size: 11px; }
details summary { color: var(--muted); font-size: 11px; padding: 6px 0; }
details[open] summary { color: var(--ink); }
.detail-copy { font-size: 12px; color: var(--muted); line-height: 1.65; margin-top: 8px; overflow-wrap: anywhere; }
.model { grid-column: 1/8; }
.usage { grid-column: 8/-1; }
.footprint { grid-column: 1/8; }
.geography { grid-column: 8/-1; }
.nws { grid-column: 1/8; }
.delivery { grid-column: 8/-1; }
.model-current { display: flex; align-items: center; gap: 18px; padding-bottom: 18px; }
.ready-mark { display: grid; place-items: center; width: 48px; height: 48px; border: 1px solid var(--line); border-radius: 50%; font-size: 22px; color: var(--good); flex-shrink: 0; }
.artifact-title { font-size: 21px; font-weight: 500; letter-spacing: -.035em; }
.artifact-sub { font-size: 11px; color: var(--muted); margin-top: 4px; }
.model-current .badge { margin-left: auto; }
.badge { font-size: 11px; font-weight: 600; padding: 3px 7px; border: 1px solid var(--line); border-radius: 4px; white-space: nowrap; }
.catalog { display: grid; grid-template-columns: repeat(4,1fr); border-top: 1px solid var(--line); padding-top: 14px; gap: 8px; }
.catalog span { display: block; color: var(--muted); font-size: 11px; }
.catalog strong { font-size: 19px; font-weight: 500; }
.catalog-track { display: flex; height: 3px; gap: 3px; margin-top: 14px; }
.catalog-track i { background: var(--accent); flex: 8; }
.catalog-track i:last-child { flex: 1; background: var(--warn); }
.module-note { font-size: 11px; color: var(--muted); margin-top: 12px; }
.usage-metrics { display: grid; grid-template-columns: repeat(4,minmax(0,1fr)); gap: 10px; }
.stat-label { font-size: 11px; color: var(--muted); display: block; }
.stat-value { font-size: 32px; font-weight: 500; letter-spacing: -.05em; line-height: 1.2; margin: 7px 0; display: block; font-variant-numeric: tabular-nums; }
.stat-unit { font-size: 11px; color: var(--muted); }
.usage-foot { display: flex; justify-content: space-between; gap: 12px; border-top: 1px solid var(--line); margin-top: 22px; padding-top: 13px; font-size: 11px; }
.usage-foot strong { font-weight: 600; }
.table-wrap { min-width: 0; }
table { width: 100%; border-collapse: collapse; font-size: 12px; }
th { color: var(--muted); font-size: 11px; font-weight: 500; text-transform: uppercase; letter-spacing: .055em; text-align: left; padding: 0 8px 10px 0; }
td { border-top: 1px solid var(--line); padding: 11px 8px 11px 0; vertical-align: middle; }
td:last-child,th:last-child { padding-right: 0; }
td strong { font-weight: 500; }
td small { display: block; font-size: 11px; margin-top: 2px; }
.eligibility { font-size: 11px; color: var(--good); white-space: nowrap; }
.state-table td { padding: 9px 0; }
.state-label { width: 64%; }
.state-bar { display: flex; align-items: center; gap: 10px; }
.state-bar > span { flex: 0 0 76px; }
.state-bar i { height: 4px; background: var(--accent); opacity: .65; width: calc(var(--count)*9px); display: block; }
.state-bar.unknown i { background: var(--muted); }
.geo-note { margin-top: 9px; font-size: 11px; color: var(--muted); }
.weather-list { display: grid; }
.weather-row { display: grid; grid-template-columns: 52px 1fr auto; align-items: baseline; gap: 12px; padding: 10px 0; border-top: 1px solid var(--line); }
.weather-time { font: 11px var(--mono); color: var(--muted); }
.weather-event { font-size: 12px; font-weight: 500; }
.weather-place { font-size: 11px; color: var(--muted); margin-top: 2px; }
.weather-lifecycle { font-size: 11px; text-align: right; color: var(--muted); }
.weather-threat { color: var(--danger); font-size: 11px; margin-top: 3px; font-weight: 600; }
.delivery-metrics { display: grid; grid-template-columns: repeat(2,minmax(0,1fr)); gap: 18px 22px; }
.delivery-metrics .stat-value { font-size: 26px; margin: 3px 0; }
.delivery-metrics .stat-unit { font-size: 11px; }
.delivery details { border-top: 1px solid var(--line); padding-top: 8px; margin-top: 16px; }
.page-footer { display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 12px; padding: 24px 0 72px; font-size: 11px; color: var(--muted); }
.page-footer a { text-decoration: underline; text-underline-offset: 3px; }
.empty-state { display: none; padding: 30px 0; color: var(--muted); font-size: 12px; }
/* Control Room uses a persistent sidebar and a denser, reordered desktop grid. */
.control { color-scheme: dark; --bg: #111a21; --surface: #18232b; --surface-soft: #202f38; --ink: #e3ecec; --muted: #a0b2ba; --line: #30414b; --accent: #85c7b7; --good: #85c7b7; --warn: #e4b86d; --danger: #f39398; --warn-bg: #302a21; --danger-bg: #36262b; --radius: 6px; --space: 18px; }
.control .app { max-width: 1600px; padding: 0 28px 0 208px; }
.control .masthead { padding: 18px 0; border-bottom: 1px solid var(--line); }
.control .wordmark { font-size: 20px; }
.control .primary-nav { position: fixed; top: 38px; left: max(0px,calc((100vw - 1600px)/2)); bottom: 0; width: 180px; display: flex; flex-direction: column; align-items: stretch; gap: 5px; padding: 33px 14px; border: 0; border-right: 1px solid var(--line); background: #131e26; }
.control .primary-nav::before { content: 'WORKSPACE'; font: 11px var(--mono); letter-spacing: .1em; color: var(--muted); margin: 0 10px 12px; }
.control .primary-nav a { padding: 11px 10px; font-size: 11px; border-radius: 4px; }
.control .primary-nav a[aria-current] { background: var(--surface-soft); box-shadow: inset 2px 0 var(--accent); }
.control .nav-index { display: inline; font: 11px var(--mono); margin-right: 10px; opacity: .65; }
.control .sidebar-note { display: block; margin-top: auto; padding: 10px; color: var(--muted); font-size: 11px; line-height: 1.7; }
.control .sidebar-note strong { display: block; font-weight: 500; color: var(--ink); }
.control .page-head { padding: 20px 0 17px; }
.control h1 { font-size: 26px; }
.control .overview-grid { gap: 14px; }
.control .health { grid-column: 1/-1; grid-row: 1; }
.control .health-top { margin-bottom: 10px; padding: 10px 14px; border-radius: 4px; }
.control .health-label { display: inline; margin-right: 14px; }
.control .health-rail { background: var(--surface); border: 1px solid var(--line); border-radius: 5px; padding: 13px 0; }
.control .health-item:first-child { padding-left: 18px; }
.control .health-reading strong { font: 22px var(--mono); }
.control .model { grid-column: 1/8; grid-row: 2; }
.control .usage { grid-column: 1/8; grid-row: 3; }
.control .footprint { grid-column: 1/8; grid-row: 4; }
.control .geography { grid-column: 8/-1; grid-row: 3; }
.control .nws { grid-column: 8/-1; grid-row: 4; }
.control .delivery { grid-column: 8/-1; grid-row: 2; }
.control .module-head { margin-bottom: 12px; }
.control h2 { font-size: 14px; }
.control .model-current { padding-bottom: 12px; gap: 12px; }
.control .ready-mark { width: 36px; height: 36px; border-radius: 6px; font-size: 17px; }
.control .artifact-title { font-size: 18px; }
.control .catalog { padding-top: 10px; }
.control .catalog strong { font: 18px var(--mono); }
.control .stat-value { font: 28px/1.2 var(--mono); letter-spacing: -.05em; }
.control .usage-foot { margin-top: 16px; padding-top: 12px; }
.control .usage { align-self: stretch; display: flex; flex-direction: column; }
.control .usage-metrics { margin-top: 20px; }
.control .usage-foot { margin-top: auto; }
.control .delivery-metrics { gap: 13px; }
.control .delivery-metrics .stat-value { font-size: 24px; }
.control .delivery details { margin-top: 10px; padding-top: 2px; }
.control td { padding-top: 10px; padding-bottom: 10px; }
.control .state-table td { padding: 5px 0; }
.control .weather-row { grid-template-columns: 42px 1fr; gap: 8px; padding: 8px 0; }
.control .weather-lifecycle { display: none; }
.control .weather-event { font-size: 11px; }
.control .weather-place { font-size: 11px; }
.control .nws .weather-lifecycle { display: block; grid-column: 2; text-align: left; margin-top: -6px; font-size: 11px; }
.detail-page .detail-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
.detail-page .detail-grid > .module { grid-column: auto; grid-row: auto; }
.detail-page .detail-grid > .wide { grid-column: 1/-1; }
.detail-page .detail-grid .health { padding: 20px; }
.detail-page .detail-grid .health-rail { display: grid; }
.detail-page .detail-grid .health-top { display: flex; }
.breadcrumbs { font-size: 11px; margin-bottom: 10px; color: var(--muted); }
.definition-list { margin: 0; }
.definition-list > div { display: flex; justify-content: space-between; gap: 20px; border-top: 1px solid var(--line); padding: 12px 0; font-size: 12px; }
.definition-list dt { color: var(--muted); }
.definition-list dd { margin: 0; text-align: right; }
@media (max-width: 1100px) {
  .app { padding-left: 24px; padding-right: 24px; }
  .overview-grid { gap: 16px; }
  .module { --space: 18px; }
  .control .app { padding-left: 180px; }
  .control .primary-nav { width: 160px; padding-left: 8px; padding-right: 8px; }
  .usage-metrics { grid-template-columns: repeat(2,minmax(0,1fr)); gap: 12px; }
  .control .usage-metrics { margin-top: 4px; }
  .control .usage-foot { margin-top: 12px; }
  .stat-value { font-size: 28px; }
  .state-bar i { width: calc(var(--count)*4px); }
  .module-head { flex-wrap: wrap; gap: 5px; }
  .weather-row { gap: 8px; }
  .model-current { flex-wrap: wrap; }
  .model-current .badge { margin-left: 0; }
}
@media (max-width: 850px) {
  .app,.control .app { padding: 0 22px; }
  .control .primary-nav { position: static; width: auto; flex-direction: row; flex-wrap: wrap; padding: 0; border: 0; border-bottom: 1px solid var(--line); background: none; gap: 16px; }
  .control .primary-nav::before,.control .sidebar-note,.control .nav-index { display: none; }
  .control .primary-nav a { padding: 12px 0; }
  .control .primary-nav a[aria-current] { background: none; box-shadow: inset 0 -2px var(--accent); border-radius: 0; }
  .primary-nav { gap: 20px; }
  .primary-nav a { font-size: 11px; }
  .overview-grid { grid-template-columns: repeat(2,minmax(0,1fr)); gap: 18px; }
  .overview-grid > .module > .module,.control .overview-grid > .module { grid-column: auto; grid-row: auto; }
  .overview-grid > .health > .health,.control .overview-grid > .health { grid-column: 1/-1; }
  .overview-grid > .footprint > .footprint,.control .overview-grid > .footprint { grid-column: 1/-1; }
  .overview-grid > .nws > .nws,.control .overview-grid > .nws { grid-column: 1/-1; }
  .overview-grid > .delivery > .delivery,.control .overview-grid > .delivery { grid-column: 1/-1; }
  .delivery-metrics { grid-template-columns: repeat(4,minmax(0,1fr)); }
  .overview-grid > .geography > .geography,.control .overview-grid > .geography { grid-column: 1/-1; }
  .geography .state-label { width: 70%; }
  .state-bar i { width: calc(var(--count)*9px); }
  .control .weather-row { grid-template-columns: 52px 1fr auto; }
  .control .nws .weather-lifecycle { grid-column: auto; text-align: right; margin-top: 0; }
}
@media (max-width: 560px) {
  body { font-size: 14px; }
  .app,.control .app { padding: 0 16px; }
  .masthead,.control .masthead { padding: 19px 0 15px; flex-wrap: wrap; gap: 10px; }
  .telemetry { width: 100%; justify-content: space-between; gap: 8px; }
  .primary-nav,.control .primary-nav { gap: 0 18px; flex-wrap: wrap; }
  .primary-nav a,.control .primary-nav a { padding: 13px 0; font-size: 11px; min-height: 44px; }
  .page-head { padding: 21px 0 18px; align-items: flex-start; }
  h1 { font-size: 27px; }
  .dateline { font-size: 11px; max-width: 90px; }
  .overview-grid { display: flex; flex-direction: column; gap: 18px; }
  .overview-grid > .module { width: 100%; }
  .health-top { display: block; padding: 12px 14px; }
  .health-top a { display: inline-block; margin-top: 8px; min-height: 32px; padding-top: 6px; }
  .health-rail { grid-template-columns: repeat(2,minmax(0,1fr)); gap: 20px 12px; padding: 4px 0; }
  .health-item,.health-item:first-child,.control .health-item:first-child { padding: 0 10px; border: 0; }
  .health-item p { font-size: 11px; }
  .health-reading span { font-size: 11px; }
  .control .health-rail { padding: 16px 2px; }
  .health details summary, details summary { min-height: 36px; padding-top: 9px; }
  .module { padding: 18px; }
  .overview-grid > .health { padding: 0; }
  .usage-metrics { grid-template-columns: repeat(4,minmax(0,1fr)); gap: 8px; }
  .stat-value { font-size: 27px; }
  .stat-label { font-size: 11px; }
  .control .stat-value { font-size: 25px; }
  .usage-foot { font-size: 11px; }
  .footprint table thead { display: none; }
  .footprint table tr { display: grid; grid-template-columns: 1fr 1fr; gap: 8px 12px; padding: 13px 0; border-top: 1px solid var(--line); }
  .footprint table td { border: 0; padding: 0; font-size: 11px; }
  .footprint table td:first-child { grid-column: 1/-1; font-size: 14px; }
  .footprint table td::before { content: attr(data-label); display: block; font-size: 11px; color: var(--muted); margin-bottom: 2px; }
  .footprint table td:first-child::before { display: none; }
  .footprint table td small { font-size: 11px; }
  .weather-row,.control .weather-row { grid-template-columns: 42px 1fr; }
  .weather-lifecycle,.control .nws .weather-lifecycle { grid-column: 2; text-align: left; margin-top: -4px; }
  .weather-event { font-size: 12px; }
  .delivery-metrics { grid-template-columns: repeat(2,minmax(0,1fr)); }
  .page-footer { display: block; line-height: 1.8; padding-bottom: 80px; }
  .detail-page .detail-grid { display: block; }
  .detail-page .detail-grid > .module { margin-bottom: 18px; }
  .detail-page .table-wrap { overflow-x: auto; }
  .detail-page .table-wrap table { min-width: 540px; }
  .detail-page .footprint .table-wrap table { min-width: 0; }
}
@media (prefers-reduced-motion: reduce) { *,*::before,*::after { scroll-behavior: auto !important; transition: none !important; } }

/* Production shell: omit the prototype picker and its 38px offset. */
.control .primary-nav { top: 0; }
.freshness-notice { display: block; }
.freshness-notice[hidden] { display: none; }
.status-dot { display:inline-block; width:6px; height:6px; border-radius:50%; background:currentColor; }
.status-label { font-weight:600; }
.status-dot.live,.status-label.live,.accent,.health-healthy .health-status { color:var(--good); }
.status-dot.stale,.status-label.stale,.warn,.health-warning .health-reading { color:var(--warn); }
.status-label.disconnected { color: var(--danger); }
.status-dot.disconnected { color: var(--danger); }
.health-critical .health-reading { color:var(--danger); }
.health-unknown .health-status { color:var(--muted); }
.health-top.neutral { background:var(--surface); border-color:var(--line); }
.module,.live-slot,.card { min-width:0; }
.module .live-slot + .live-slot { margin-top:18px; }
.card-heading h3 { font-size:13px; margin-bottom:8px; }
.card .primary { font-size:26px; font-variant-numeric:tabular-nums; }
.definition-list .primary { font:12px var(--mono); }
.pipeline-latency-card .definition-list .primary { font-size:26px; }
.definition-list dt,.definition-list dd { min-width:0; overflow-wrap:anywhere; }
.metric-summary,.subtle { font-size:11px; color:var(--muted); overflow-wrap:anywhere; }
.meta-list { list-style:none; margin:8px 0 0; padding:0; }
.meta-list li { display:flex; justify-content:space-between; gap:16px; border-top:1px solid var(--line); padding:9px 0; font-size:12px; }
.meta-list li span { color:var(--muted); }
.meta-list li strong { text-align:right; font-weight:500; overflow-wrap:anywhere; min-width:0; }
.table-card__header { margin-bottom:14px; }
.table-card__header h3 { display:none; }
.table-wrap { overflow-x:auto; }
.footprint-table-wrap:focus-visible { outline:2px solid var(--accent); outline-offset:4px; }
.diagnostic-mono,.diagnostic-copy,.diagnostic-full,.diagnostic-truncate { overflow-wrap:anywhere; font-size:11px; }
.diagnostic-mono { font-family:var(--mono); color:var(--muted); }
.pill { display:inline-block; padding:2px 6px; border:1px solid var(--line); border-radius:4px; font-size:11px; }
.empty { color:var(--muted); padding:20px 0; font-size:12px; }
.unavailable { grid-column:1/-1; }
.catalog-track i { min-width:0; }
.catalog-track i.catalog-ready { background:var(--good); }
.catalog-track i.catalog-warming { background:var(--warn); }
.catalog-track i.catalog-pending { background:var(--muted); }
.catalog-track i.catalog-failed { background:var(--danger); }
.weather-time { overflow-wrap:anywhere; }
.ready-mark.danger { color:var(--danger); }
.ready-mark.warn { color:var(--warn); }
.ready-mark.muted { color:var(--muted); }
.module-note.warning { color:var(--warn); }
.weather-place,.weather-event { overflow-wrap:anywhere; }
.eligibility.muted { color:var(--muted); white-space:normal; }
@media (max-width:850px) { .control .primary-nav { position:static; } }
@media (max-width:560px) {
  .telemetry { flex-wrap:wrap; justify-content:flex-start; }
  .detail-page .table-wrap { overflow-x:auto; }
  .meta-list li { flex-wrap:wrap; gap:4px; }
  .meta-list li strong { text-align:left; }
}
"""#
}
