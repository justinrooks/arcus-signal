# Arcus Signal dashboard exploration

Baseline: GitHub main `e8ecf14984a7279b615b93a70073e7456cc7aaa4`, verified 2026-09-17. Current worktree has identical production dashboard files. Reviewed epic #231 and completed #235, #236, #238, #250, #241, #240; renderer, CSS, refresh script, metrics DTO, and rendered deployed dashboard.

Mode: redesign/preservation of operational content and semantics; expressly authorized divergence in composition and navigation. No production edits. Existing identity is the plain-text “Arcus Signal” masthead; preserve that wordmark without inventing a logo. Reference: `../../docs/operator-dashboard-visual-north-star.svg`.

## Design read

Operator cockpit, laptop viewing distance, calm/authoritative temperature, static interactions. Four health signals, selected artifact/catalog, four usage totals, five footprint rows, state attribution, five recent NWS series, four delivery signals fit in roughly 1–1.5 desktop screens. No decorative imagery or invented time-series charts.

| Direction | Variance / motion / density / assets / fidelity | System |
|---|---|---|
| Quiet Operational | 4 / 1 / 7 / 1 / 7 | Avenir Next with native fallbacks; cool off-white, ink, restrained teal; 4px rhythm, 24px grouping, 12px surfaces; virtually no shadow; top navigation; broad shared surfaces |
| Technical Editorial | 6 / 1 / 8 / 1 / 6 | Georgia headings with Avenir Next data; warm paper and ink; 4px rhythm, ruled columns, sharp corners, no shadow; horizontal numbered contents; narrow health margin |
| Control Room | 5 / 1 / 9 / 1 / 8 | Avenir Next with SFMono numeric detail; deep blue-gray, existing Arcus teal/amber; 4px rhythm, 16px groups, 6px panels; no glow; left navigation and compact subsystem grid |

Semantic colors always include text. Connection state is separate from operational findings. Sample data is expressly authorized by the brief, prominently labeled, frozen at 2026-09-17 21:18 UTC, and never fetched from production. No fabricated health thresholds or APNs-retry guarantees. Native details disclose definitions and secondary evidence. Ordinary links navigate pre-rendered HTML documents; no client router, dependencies, bundler, or chart library.

## Owl findings and architecture

| Dimension | Rating | Observation → consequence → change |
|---|---|---|
| Cognitive load | Minor issue | Repeated summary cards and history tables share one document → daily scan includes investigation material → summaries on Overview, focused detail destinations |
| Content priority | Major issue | Artifact rows and 12-month growth precede delivery → delivery takes substantial scrolling → compress artifact history and move monthly history into Usage & Installations |
| Scanning | Minor issue | Expanded unknown-health card and tall artifact table leave uneven gaps → comparison loses its horizontal rhythm → shared health rail or aligned margin; concise current artifact summary |
| Disclosure | Minor issue | Native details already protect many identifiers, but history is always expanded → screen length remains high → retain inline details for definitions/IDs, use pages for a sustained investigation |

Five destinations, one level deep:
- Overview: What needs attention now? All four health signals, model readiness/catalog counts, known/DAU/MAU/new totals, state activity, exactly five freshest production footprint rows from the last 90 days, five recently touched NWS series, delivery/targeting summary.
- Model Pipeline: Is the expected artifact ready, and what blocked it? Readiness, run/forecast/valid times, full available recent artifact slice, catalog/lease/failure details.
- Usage & Installations: Is foreground usage growing and where is it attributed? DAU/MAU, state breakdown (including Unknown), monthly growth, subscriptions and clearly separate server activity. Existing bounded footprint slice only; no fictional directory/search API.
- NWS Activity: What was recently touched, where, and with what hazard/lifecycle? Existing five-series slice with threat fields and identifier disclosures. Not a national active-warning count or a new feed.
- Delivery: Why did a push send, fail, or have no candidates? Latency, APNs denominator/failures, fresh coverage vs candidate eligibility, H3 conversion, no-op reasons and existing debug context. No extra Diagnostics page.

Overview section links and navigation land on the same destinations. Detail documents are scope demonstrations, not production route implementations. Unknown ingestion semantics remain unknown. Backlog with pending rows remains unclassified under the current contract. Empty data and stale/disconnected snapshots must not look like zero activity or all-clear health. Mobile stacks preserve DOM order; navigation wraps rather than hiding primary destinations; tables become labeled rows.
