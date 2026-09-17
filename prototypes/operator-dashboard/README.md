# Arcus Signal dashboard directions

Run from the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory prototypes/operator-dashboard
```

Open http://127.0.0.1:8765/. The direction picker stays at the top of every page.

| Direction | Philosophy and advantage | Cost |
|---|---|---|
| [Quiet Operational](quiet/index.html) | Calm top navigation, shared health rail, broad white surfaces, deliberate space. Makes routine checks easier to read than the current repeated dark-card stack. | More vertical space; delivery remains below the fold. |
| [Technical Editorial](editorial/index.html) | A compact operational report: health in the margin, serif hierarchy, ruled columns, minimal boxes. Strongest distinction between content and chrome. | Less familiar tool aesthetic; narrower columns require more adaptation on tablets. |
| [Control Room](control/index.html) | Persistent navigation, compact status strip, model and delivery side by side. Fastest cross-system scan and closest to the existing Arcus identity. | Higher density; sidebar consumes width on smaller laptops. |

Recommendation: Control Room for Arcus. Its first screen pairs model readiness with delivery outcomes and keeps the red lights immediate. Quiet Operational is the calmer alternative for the once-or-twice-daily cadence. Choose on the live prototypes, not the names.

## Scope

All numbers, locations, warnings and timestamps are synthetic, frozen samples, not current observations. Plain HTML is served intact; JavaScript only switches preview conditions and density. This is a presentation exploration, not a second metrics implementation. Production Swift renderers, API contracts and live polling remain untouched. No dependency installation, framework, bundler, charting library, GitHub issues or production routes.

Five ordinary HTML destinations exist in every direction so navigation can be evaluated. The four detail destinations demonstrate content ownership, not fully designed production workbenches. Overview always contains exactly five freshest production footprint rows from the last 90 days; details do not imply an unbounded installation query. Unknown state attribution remains visible. No map, daily trend, national active-warning total or incident history is invented.

Owl established five destinations and moved historical/debug material out of the daily scan. Garden drove the different grid, type, density and surface systems. Detailed rationale and snapshot limitations are in [brand-spec.md](brand-spec.md).

Use **Tweaks** for populated, stale, disconnected and empty-list conditions. [Responsive preview](preview.html) supplies real 390/768/1280/1440px iframe viewports. [Layout checks](acceptance.html) runs a local browser smoke harness; it is not a production regression suite.

## Validation

Browser evidence and repairs are recorded in [VALIDATION.md](VALIDATION.md).
