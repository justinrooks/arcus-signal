extension OperatorDashboardPageRenderer {
    static let styles = """
            :root {
              color-scheme: dark;
              --bg: #07111c;
              --panel: rgba(12, 24, 39, 0.96);
              --panel-2: rgba(17, 33, 52, 0.92);
              --line: rgba(117, 165, 196, 0.16);
              --text: #eef6ff;
              --muted: #a5bbcd;
              --accent: #58d6c3;
              --warn: #ffb15c;
              --danger: #ff6f7d;
              --shadow: 0 8px 22px rgba(0, 0, 0, 0.16);
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
              background: linear-gradient(180deg, #08121d 0%, #050a11 100%);
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
            .masthead {
              display: flex;
              gap: 16px;
              justify-content: space-between;
              align-items: flex-end;
              padding: 16px 20px;
              border: 1px solid var(--line);
              border-radius: 16px;
              background: linear-gradient(135deg, rgba(14, 29, 46, 0.96), rgba(7, 15, 25, 0.94));
              box-shadow: var(--shadow);
            }
            .masthead h1 {
              margin: 0;
              font-family: inherit;
              font-size: clamp(1.7rem, 2.5vw, 2.35rem);
              letter-spacing: -0.04em;
            }
            .masthead p {
              margin: 4px 0 0;
              color: var(--muted);
            }
            .masthead-meta {
              text-align: right;
              color: var(--muted);
              font-size: 0.95rem;
            }
            .masthead-status {
              display: flex;
              align-items: center;
              justify-content: flex-end;
              gap: 8px;
              margin-bottom: 6px;
              color: var(--text);
              font-weight: 700;
              letter-spacing: 0.06em;
            }
            .status-label.stale, .status-label.disconnected { color: var(--warn); }
            .status-label.live { color: var(--accent); }
            .status-dot {
              width: 8px;
              height: 8px;
              border-radius: 50%;
              background: currentColor;
              box-shadow: 0 0 12px currentColor;
            }
            .status-dot.live { color: var(--accent); }
            .status-dot.stale, .status-dot.disconnected { color: var(--warn); }
            #snapshot-age {
              color: var(--muted);
              font-size: 0.84rem;
              font-weight: 400;
              letter-spacing: 0;
            }
            .masthead-meta a {
              display: inline-block;
              padding: 4px 0;
              color: var(--accent);
              text-decoration: none;
            }
            :where(a, summary):focus-visible {
              outline: 2px solid var(--accent);
              outline-offset: 4px;
              border-radius: 4px;
            }
            .section {
              margin-top: 28px;
            }
            .section h2 {
              margin: 0;
              font-size: 1.28rem;
              letter-spacing: -0.02em;
              color: var(--text);
            }
            .section-header {
              display: flex;
              align-items: baseline;
              justify-content: flex-start;
              flex-wrap: wrap;
              gap: 12px;
              margin-bottom: 12px;
            }
            .section-header h2 {
              margin: 0;
            }
            .section-header p {
              margin: 0;
              color: var(--muted);
              font-size: 0.82rem;
            }
            .section-header .subtle {
              font-size: 0.88rem;
              min-width: 0;
              flex: 1 1 240px;
            }
            .section-table {
              margin-top: 16px;
            }
            .table-card__header {
              padding: 18px 18px 0;
            }
            .table-card__header h3 {
              margin: 0;
            }
            .grid {
              display: grid;
              grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
              gap: 16px;
            }
            .growth-primary-grid {
              grid-template-columns: repeat(4, minmax(0, 1fr));
            }
            .growth-secondary {
              max-width: calc(25% - 12px);
              margin-top: 12px;
            }
            .installation-detail-grid {
              display: grid;
              grid-template-columns: repeat(2, minmax(0, 1fr));
              gap: 16px;
            }
            .model-pipeline-grid {
              display: grid;
              grid-template-columns: repeat(4, minmax(0, 1fr));
              gap: 16px;
            }
            .model-pipeline-grid > :nth-child(3) {
              grid-column: span 2;
            }
            .operational-kpi-grid {
              display: grid;
              grid-template-columns: repeat(4, minmax(0, 1fr));
              gap: 16px;
            }
            .operational-kpi-secondary {
              display: grid;
              grid-template-columns: repeat(2, minmax(0, 1fr));
              gap: 16px;
              margin-top: 12px;
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
              padding: 16px;
              border-radius: 14px;
              border: 1px solid var(--line);
              background: var(--panel);
              box-shadow: var(--shadow);
            }
            .card h3 {
              margin: 0;
              font-size: 0.92rem;
              letter-spacing: 0.02em;
              color: var(--muted);
            }
            .card-heading {
              display: flex;
              align-items: center;
              justify-content: space-between;
              gap: 12px;
            }
            .health-indicator {
              display: inline-flex;
              align-items: center;
              gap: 7px;
              color: var(--health-color, var(--muted));
              font-size: 0.7rem;
              font-weight: 700;
              letter-spacing: 0.06em;
              text-transform: uppercase;
            }
            .health-healthy .health-indicator { color: #7de3d2; }
            .health-warning .health-indicator { color: #ffc77d; }
            .health-critical .health-indicator { color: #ff9aa3; }
            .health-unknown .health-indicator { color: #c1d0dc; }
            .health-card {
              --health-color: var(--muted);
              border-left: 4px solid var(--health-color);
              padding: 14px 16px;
            }
            .health-healthy { --health-color: rgba(88, 214, 195, 0.46); }
            .health-warning { --health-color: var(--warn); }
            .health-critical { --health-color: var(--danger); }
            .health-unknown { --health-color: rgba(140, 164, 186, 0.48); }
            .health-dot {
              flex: 0 0 auto;
              width: 8px;
              height: 8px;
              border-radius: 50%;
              color: var(--health-color);
              background: currentColor;
              box-shadow: 0 0 10px currentColor;
            }
            .health-warning .primary { color: var(--warn); }
            .health-critical .primary { color: var(--danger); }
            .health-unknown .primary { color: var(--muted); }
            .health-card .primary {
              margin: 10px 0 0;
            }
            .health-card .metric-details {
              margin-top: 8px;
            }
            .primary {
              margin: 14px 0 6px;
              font-size: 2rem;
              font-weight: 700;
              letter-spacing: -0.04em;
            }
            .compact-card {
              padding: 16px;
              border-radius: 16px;
            }
            .compact-card .primary {
              margin: 10px 0 4px;
              font-size: 1.55rem;
            }
            .metric-summary {
              color: var(--text);
              font-size: 0.86rem;
              line-height: 1.45;
              min-height: 2.5em;
            }
            .metric-details {
              margin-top: 10px;
              border-top: 1px solid rgba(117, 165, 196, 0.10);
            }
            .metric-details summary {
              cursor: pointer;
              padding-top: 10px;
              color: var(--accent);
              font-size: 0.78rem;
              font-weight: 700;
              letter-spacing: 0.05em;
              text-transform: uppercase;
            }
            .metric-details .meta-list {
              margin-top: 4px;
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
              min-width: 0;
              table-layout: fixed;
            }
            .pressure-artifact-table th:last-child,
            .pressure-artifact-table td:last-child {
              width: 28%;
            }
            .footprint-table {
              min-width: 820px;
            }
            .footprint-table-wrap {
              max-height: 24rem;
              overflow-y: auto;
              scrollbar-gutter: stable;
            }
            .footprint-table-wrap:focus-visible {
              outline: 2px solid var(--accent);
              outline-offset: 4px;
              border-radius: 4px;
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
            .footprint-eligible { color: var(--accent); border-color: rgba(88, 214, 195, 0.35); }
            .footprint-ineligible { color: var(--warn); border-color: rgba(245, 190, 93, 0.35); }
            .presence-age { font-weight: 700; color: var(--text); }
            .accent { color: var(--accent); }
            .warn { color: var(--warn); }
            .danger { color: var(--danger); }
            .mono { font-family: "SF Mono", "IBM Plex Mono", monospace; font-size: 0.78rem; }
            .micro-mono { font-family: "SF Mono", "IBM Plex Mono", monospace; font-size: 0.54rem; line-height: 1.3; }
            .diagnostic-mono {
              font-family: "SF Mono", "IBM Plex Mono", monospace;
              font-size: 0.72rem;
              line-height: 1.4;
              overflow-wrap: anywhere;
            }
            .diagnostic-truncate {
              display: block;
              max-width: min(42ch, 34vw);
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            .diagnostic-copy {
              display: block;
              max-width: 48ch;
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
            }
            .diagnostic-disclosure {
              max-width: 100%;
            }
            .diagnostic-disclosure summary {
              max-width: 100%;
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
              cursor: pointer;
              color: var(--text);
            }
            .diagnostic-disclosure[open] summary {
              white-space: normal;
              overflow-wrap: anywhere;
            }
            .diagnostic-full {
              margin-top: 6px;
              color: var(--muted);
              overflow-wrap: anywhere;
            }
            .masthead-meta, .primary, th, td, .mono, .micro-mono {
              font-variant-numeric: tabular-nums;
            }
            .empty {
              padding: 18px 16px;
              color: var(--muted);
            }
            .stream-table tbody tr {
              opacity: 1;
              transform: translateY(0);
              transition: background-color 0.18s ease;
            }
            .stream-table tbody tr:hover {
              background: rgba(88, 214, 195, 0.045);
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
            @media (prefers-reduced-motion: reduce) {
              *, *::before, *::after {
                animation-duration: 0.01ms !important;
                animation-iteration-count: 1 !important;
                scroll-behavior: auto !important;
                transition-duration: 0.01ms !important;
              }
              .stream-table tbody tr.stream-row {
                animation: none !important;
                opacity: 1;
                transform: none;
              }
            }
            @media (min-width: 721px) and (max-width: 1120px) {
              .grid {
                grid-template-columns: repeat(2, minmax(0, 1fr));
              }
              .growth-primary-grid {
                grid-template-columns: repeat(2, minmax(0, 1fr));
              }
              .growth-secondary {
                max-width: calc(50% - 8px);
              }
              .installation-detail-grid {
                grid-template-columns: 1fr;
              }
              .model-pipeline-grid,
              .operational-kpi-grid {
                grid-template-columns: repeat(2, minmax(0, 1fr));
              }
              .model-pipeline-grid > :nth-child(3) {
                grid-column: span 2;
              }
              th, td {
                padding: 11px 12px;
              }
              td {
                font-size: 0.9rem;
              }
              .micro-mono {
                font-size: 0.68rem;
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
                margin-bottom: 0;
                font-size: 1.08rem;
                letter-spacing: -0.01em;
              }
              .masthead {
                padding: 16px;
                border-radius: 18px;
                flex-direction: column;
                align-items: stretch;
              }
              .masthead h1 {
                font-size: clamp(1.5rem, 8vw, 2rem);
                letter-spacing: -0.02em;
              }
              .masthead p {
                margin-top: 8px;
                font-size: 0.92rem;
                line-height: 1.4;
              }
              .masthead-meta {
                text-align: left;
                font-size: 0.86rem;
              }
              .masthead-status {
                justify-content: flex-start;
                flex-wrap: wrap;
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
              .growth-primary-grid,
              .installation-detail-grid {
                grid-template-columns: 1fr;
              }
              .growth-secondary {
                max-width: none;
              }
              .model-pipeline-grid,
              .operational-kpi-grid,
              .operational-kpi-secondary {
                grid-template-columns: 1fr;
                gap: 12px;
              }
              .model-pipeline-grid > :nth-child(3) {
                grid-column: auto;
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
              .diagnostic-truncate,
              .diagnostic-copy {
                max-width: 100%;
              }
            }
            @media (min-width: 721px) and (max-width: 900px) {
              .footprint-table-wrap .inline-mobile-table {
                min-width: 0;
                border-collapse: separate;
                border-spacing: 0;
              }
              .footprint-table-wrap .inline-mobile-table thead {
                display: none;
              }
              .footprint-table-wrap .inline-mobile-table tbody {
                display: grid;
                gap: 14px;
                padding: 12px 12px 14px;
              }
              .footprint-table-wrap .inline-mobile-table tbody tr {
                display: grid;
                gap: 9px;
                padding: 12px;
                border: 1px solid rgba(117, 165, 196, 0.24);
                border-radius: 12px;
                background: linear-gradient(180deg, rgba(19, 40, 63, 0.34), rgba(12, 27, 45, 0.2));
              }
              .footprint-table-wrap .inline-mobile-table tbody td {
                display: grid;
                grid-template-columns: minmax(112px, 28%) 1fr;
                gap: 12px;
                min-width: 0;
                padding: 0;
                border: 0;
              }
              .footprint-table-wrap .inline-mobile-table tbody td + td {
                padding-top: 3px;
                border-top: 1px solid rgba(117, 165, 196, 0.14);
              }
              .footprint-table-wrap .inline-mobile-table tbody td::before {
                content: attr(data-label);
                color: var(--muted);
                font-size: 0.72rem;
                letter-spacing: 0.04em;
                text-transform: uppercase;
              }
              .footprint-table-wrap .inline-mobile-table tbody td > * {
                min-width: 0;
                max-width: 100%;
              }
              .footprint-table-wrap .inline-mobile-table .pill {
                white-space: normal;
                overflow-wrap: anywhere;
              }
              .diagnostic-truncate,
              .diagnostic-copy {
                max-width: 100%;
              }
            }
            @media (max-width: 430px) {
              .shell {
                width: calc(100vw - 12px);
                padding-top: 12px;
              }
              .masthead {
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
                font-size: 0.62rem;
              }
            }

    """

    static let unavailableStyles = """
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
              box-shadow: 0 12px 32px rgba(0, 0, 0, 0.24);
            }
            h1 { margin: 0 0 8px; }
            p { color: #8ca4ba; line-height: 1.5; }
            a { color: #58d6c3; text-decoration: none; }
    """
}
