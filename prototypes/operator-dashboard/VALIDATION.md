# Prototype validation — 17 September 2026

Environment: local static HTTP server, `http://127.0.0.1:8765`, native Safari. No dependencies installed. No production requests are made by the prototypes.

- Inspected the deployed dashboard visually in Safari and compared its composition with the current main renderer and committed SVG north star.
- Inspected all three Overview directions at the available desktop window size, all three at a 390px iframe width, and Editorial at a 768px iframe width. Inspected lower mobile footprint/state/NWS content in Control Room and the model detail route.
- Browser harness exercised all three Overviews at 390, 768, 1280 and 1440px frame widths. Safari's visible scrollbar subtracts 17px from layout content width. These are browser frame checks, not tests on physical iOS devices.
- Checked document/component overflow, exactly five footprint rows, five navigation destinations, native disclosures, stale/disconnected/empty scenarios, all 15 document routes and local links/anchors. Final Safari run: **390 checks, 0 failures**. Reproduce with `acceptance.html`.
- Inspected the disconnected presentation visually. Verified direction switching and the ordinary Model Pipeline navigation by clicking in Safari.
- Repairs: increased 9–10px metadata styles to 11px; aligned panel heights; reduced doubled phone health padding; preserved proportional state bars at narrow widths; removed redundant self-links in detail modules.
- `node --check prototype.js` passed; inline JavaScript in all 18 HTML documents parses, and the prototype files have no trailing whitespace. Production renderer, styles, sections, live-update script and snapshot DTO remain byte-identical to main. Working-tree changes are confined to `prototypes/operator-dashboard/`.

Limits: sample data and status conditions are frozen presentation fixtures, not production live updates. Detail routes illustrate ownership and navigation; they are not a complete production feature. No Swift tests were run because no Swift or production behavior changed. No console-wide audit, physical iOS-device run, or multi-browser acceptance is claimed. Screenshots were inspected through the browser-control session; no screenshot files are included.

Production adoption remains a separate decision after human direction selection. It must preserve SSR/live-update parity, server-owned health semantics, canonical refresh timing, and metric definitions.
