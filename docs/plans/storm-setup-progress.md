# Storm Setup Progress Log

## Overview

Storm Setup adds a local-first Arcus Signal endpoint for Tornado Ingredient Snapshots.

Implementation should proceed one issue at a time, following `docs/plans/storm-setup-issue-runbook.md`.

Primary source of truth:
- `/Users/justin/Library/Mobile Documents/iCloud~md~obsidian/Documents/Second Brain/+/Tornado Ingredient Snapshot.md`

Related local docs:
- `AGENTS.md`
- `docs/architecture.md`
- `docs/epics-stories.md`
- `docs/plans/storm-setup-issue-runbook.md`

Related GitHub issues:
- Parent: `#68` - https://github.com/justinrooks/arcus-signal/issues/68
- `#69` - Contracts, route boundary, and H3 centroid resolution
- `#70` - Safe local `wgrib2` execution and point-sample parsing
- `#71` - HRRR run/forecast selection and NOMADS subset URL construction
- `#72` - NOMADS GRIB subset download and local filesystem cache
- `#73` - HRRR field sampling and raw-parameter normalization
- `#74` - Tornado ingredient assessment and freshness/degraded semantics
- `#76` - Local sampled snapshot cache keyed by H3/source/rules version
- `#75` - Provider/controller orchestration for local end-to-end snapshots

---

## Global Decisions

- Feature label: `Storm Setup`.
- Detail label: `Tornado Ingredients`.
- Internal model concept: `TornadoIngredientSnapshot`.
- First pass is local development only.
- Keep Storm Setup inside Arcus Signal as a bounded module.
- Do not split Storm Setup into a separate deployed service for v1.
- Keep implementation files under `Sources/App/StormSetup`.
- Keep only the controller entrypoint under `Sources/App/Controllers/StormSetupController.swift`.
- Preferred endpoint shape: `GET /api/v1/storm-setup/current?h3=<cell>`.
- Use H3 for model sampling.
- Use H3 as signed `Int64` values at the API boundary and throughout the local contract.
- Resolve H3 cell center to latitude/longitude for HRRR point sampling.
- User-facing copy should say `near your area`, `around your location`, or `for your local area`.
- User-facing copy should not say `at your exact location`.
- Use official HRRR 2D GRIB from NOMADS as the durable source path.
- Use local `wgrib2` for GRIB point sampling:
  - `/Users/justin/Downloads/wgrib2-3.8.0/build/install/bin/wgrib2`
- Do not run `Process` directly in routes.
- Cache source GRIB subsets separately from sampled snapshot JSON.
- Do not key anything as simply `hrrr_latest`.
- Use deterministic keys that include HRRR run time and forecast hour.
- Missing unavailable fields should be nil, not zero.
- Assessment language must describe environmental favorability, not tornado prediction.
- `conditional` is a first-class support state.

---

## Current Status

- GitHub parent issue and child issues have been created.
- Storm Setup runbook and progress documents have been created.
- Initial source scaffolding exists in the working tree:
  - `Sources/App/Controllers/StormSetupController.swift`
  - `Sources/App/StormSetup/GribAdapter.swift`
  - `Sources/App/StormSetup/Wgrib2Client.swift`
  - `Sources/App/apiRoutes.swift`
- Local `wgrib2` executable was verified to exist at:
  - `/Users/justin/Downloads/wgrib2-3.8.0/build/install/bin/wgrib2`
- Issue `#69` is complete.
- Issue `#70` is complete.
- Issue `#71` is complete.
- No later Storm Setup issue has been started.

---

## Codebase Investigation Notes

- Relevant existing paths:
  - `Sources/App/Controllers/StormSetupController.swift`
  - `Sources/App/StormSetup/GribAdapter.swift`
  - `Sources/App/StormSetup/Wgrib2Client.swift`
  - `Sources/App/apiRoutes.swift`
  - `Package.swift`
  - `Tests/AppTests`
- `Package.swift` already depends on `SwiftyH3`.
- Existing H3 usage appears in `Sources/App/Jobs/TargetEventRevisionJob.swift`.
- Existing route collections are registered from `Sources/App/apiRoutes.swift`.
- Current `StormSetupController` already registers a Storm Setup route group, but the route shape is not yet the preferred `/current` route.
- Current `TornadoIngredientsResponse` is only a placeholder with `h3Cell`, `validTime`, `source`, and `[String: Double]`.
- Current `Wgrib2Client` builds argument arrays rather than shell strings, which is the right direction.
- Current `Wgrib2Client` has only tolerant `val=` parsing and needs stronger parser tests and metadata extraction.
- Current `ProcessRunner` has timeout and stderr capture scaffolding, but it needs hardening before live use.
- Current `ProcessRunner` busy-waits because the sleep line is commented out.
- The current working tree already contains user-started Storm Setup changes. Do not revert them.

---

## Suggested Issue Slices

## Issue 1 - Contracts, route boundary, and H3 centroid resolution

### GitHub
- `#69` - https://github.com/justinrooks/arcus-signal/issues/69

### Status
- Complete

### Scope
- Define the local Storm Setup API contract.
- Prefer endpoint shape `GET /api/v1/storm-setup/current?h3=<cell>`.
- Add request validation for missing and invalid H3.
- Add response models for source metadata, raw parameters, assessment placeholder, and freshness placeholder.
- Add H3 resolver that validates the incoming H3 cell and returns centroid latitude/longitude.
- Keep controller thin and route-only.

### Relevant feature brief sections
- `Recommended user-facing model`
- `Recommended data model`
- `H3 sampling decision`
- `Example JSON response`
- `Server architecture decision`

### Handoff notes
- The Storm Setup contract now returns a stable `TornadoIngredientSnapshot` with:
  - canonical `h3Cell`
  - resolved `centroid.latitude` / `centroid.longitude`
  - placeholder `source`, `raw`, `assessment`, and `freshness` objects
- The controller only validates the `h3` query parameter and delegates to `StormSetupProviding.currentSnapshot(for:)`.
- `DefaultStormSetupH3Resolver` canonicalizes valid H3 input and rejects malformed cells with a `400` abort reason.
- H3 is now carried as a signed `Int64` contract value instead of a hex/string cell identifier.
- Keep issue `#70` focused on safe local `wgrib2` execution and point-sample parsing. Do not broaden it back into route or contract work.

### Files changed
- `Sources/App/Controllers/StormSetupController.swift`
- `Sources/App/StormSetup/H3CellResolver.swift`
- `Sources/App/StormSetup/StormSetupModels.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Tests/AppTests/StormSetupControllerTests.swift`

### Tests run
- `swift test --filter StormSetupControllerTests` - passed
- `swift test` - passed
- Both runs completed with the expected existing deprecation warnings elsewhere in the codebase, but no failures.

### Deferred
- HRRR source selection.
- GRIB download/cache.
- `wgrib2` execution.
- Raw parameter normalization.
- Assessment rules.
- Snapshot caching.

### Risks / open questions
- The `source`, `raw`, and `assessment` fields are intentionally placeholder-shaped and mostly nil until later issues supply real HRRR data.
- The current route contract resolves the H3 centroid but does not yet sample any model data. That is by design for this issue.

---

## Issue 2 - Safe local wgrib2 execution and point-sample parsing

### GitHub
- `#70` - https://github.com/justinrooks/arcus-signal/issues/70

### Status
- Complete

### Scope
- Harden the local `ProcessRunner` / `Wgrib2Client` adapter.
- Centralize local executable path:
  - `/Users/justin/Downloads/wgrib2-3.8.0/build/install/bin/wgrib2`
- Capture stdout and stderr.
- Enforce timeout and terminate timed-out processes.
- Surface non-zero exit codes with useful diagnostics.
- Avoid busy-spinning.
- Keep command invocation as executable URL plus argument array.
- Parse representative `wgrib2 -lon` output while preserving inventory text.

### Relevant feature brief sections
- `wgrib2 role`
- `What a GRIB2 file is`
- `Proposed HRRR server pipeline`

### Handoff notes
- `ProcessRunner` now executes `wgrib2` by executable URL plus argument array, captures stdout/stderr, enforces a timeout, and reports launch, timeout, and non-zero exit failures with useful diagnostics.
- Timed-out processes are terminated and force-killed after a short grace window so the adapter does not busy-spin or hang on pipe reads.
- `Wgrib2Client` now centralizes the local executable path through `StormSetupConfiguration` wiring and builds safe `wgrib2 <file> [-match <pattern>] -lon <lon> <lat>` arguments without shell strings.
- `Wgrib2PointSample` preserves the inventory line and parses optional `lon=`, `lat=`, and `val=` fields, while tolerating missing or non-numeric `val=` values.
- The local executable path was verified at `/Users/justin/Downloads/wgrib2-3.8.0/build/install/bin/wgrib2`.
- Issue `#71` should start from the config seam and client/parser behavior here; do not rework process execution or point-sample parsing again unless a bug is found.

### Files changed
- `Sources/App/StormSetup/GribAdapter.swift`
- `Sources/App/StormSetup/StormSetupConfiguration.swift`
- `Sources/App/StormSetup/Wgrib2Client.swift`
- `Sources/App/StormSetup/Wgrib2PointSample.swift`
- `Sources/App/configure.swift`
- `Tests/AppTests/StormSetupWgrib2ClientTests.swift`

### Tests run
- `test -x /Users/justin/Downloads/wgrib2-3.8.0/build/install/bin/wgrib2` - passed
- `swift test --filter StormSetupWgrib2ClientTests` - passed
- `swift test` - passed
- Full suite completed with existing unrelated deprecation warnings from other areas of the codebase, but no failures.

### Deferred
- Downloading GRIB files.
- HRRR run selection.
- NOMADS subset URL construction.
- Field mapping into `TornadoRawParameters`.
- Assessment rules.
- Controller integration beyond the existing route boundary.

### Risks / open questions
- `ProcessRunner` uses a polling sleep while waiting for process exit, but it no longer busy-spins and it force-kills a process that survives the timeout grace window.
- `Wgrib2PointSample` now parses nearest-point coordinates when present, but later issues may want a richer type for sampled grid metadata if the output shape expands.

---

## Issue 3 - HRRR run/forecast selection and NOMADS subset URLs

### GitHub
- `#71` - https://github.com/justinrooks/arcus-signal/issues/71

### Status
- Complete

### Scope
- Add deterministic HRRR source selection.
- Build NOMADS HRRR 2D filter URLs for the tornado-v1 field set.
- Include run time, forecast hour, valid time, bbox, product, and field set in source metadata.
- Use fallback candidates when the newest run is unavailable.
- Avoid vague `latest` source/cache keys.

### Relevant feature brief sections
- `NOMADS HRRR 2D GRIB filter`
- `NOMADS HRRR 2D GRIB test URL`
- `HRRR run / forecast-hour policy`
- `Caching model`

### Handoff notes
- Deterministic HRRR source selection now resolves the current-setup target valid hour by rounding the current UTC clock down to the hour, then emits ordered candidate runs from newest plausible to older fallbacks within a six-hour lookback window.
- The selected candidate now carries explicit HRRR metadata in `StormSetupSourceMetadata`: model, product, domain, run time, forecast hour, valid time, field set version, bbox, and NOMADS URL.
- `HrrrNomadsURLBuilder` builds the official NOMADS `filter_hrrr_2d.pl` subset URL for `tornado-v1` with the required field and level flags, a small bbox around the H3 centroid, and an encoded `dir` query value.
- The small bbox assumption is `0.30°` wide by `0.35°` tall around the H3 centroid.
- The lookup policy is intentionally simple and deterministic. It does not check live NOMADS availability yet; issue `#72` will handle download and cache use.
- Issue `#72` should consume the ordered candidate list and URL metadata as-is. Do not widen this issue back into download or cache work.

### Files changed
- `Sources/App/StormSetup/HrrrSourceModels.swift`
- `Sources/App/StormSetup/HrrrRunResolver.swift`
- `Sources/App/StormSetup/HrrrNomadsURLBuilder.swift`
- `Sources/App/StormSetup/StormSetupModels.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Sources/App/configure.swift`
- `Tests/AppTests/StormSetupControllerTests.swift`
- `Tests/AppTests/StormSetupHrrrSourceTests.swift`
- `Tests/AppTests/StormSetupWgrib2ClientTests.swift`

### Tests run
- `swift test --filter 'StormSetupHrrrSourceTests|StormSetupControllerTests|StormSetupWgrib2ClientTests'` - passed
- `swift test` - passed
- Both runs completed with existing unrelated deprecation warnings elsewhere in the codebase, but no failures.

### Deferred
- HTTP download.
- Filesystem cache.
- `wgrib2` execution.
- Assessment rules.
- Raw parameter normalization.

### Risks / open questions
- The current selection policy uses the rounded-down UTC hour and a six-hour fallback window. That is conservative for a current-setup slice but not a live availability guarantee.
- The bbox assumption is intentionally small and local-dev friendly; if the eventual sampled footprint proves too tight or too noisy, issue `#72` or `#73` can widen or tighten it.

---

## Issue 4 - NOMADS GRIB subset download and local filesystem cache

### GitHub
- `#72` - https://github.com/justinrooks/arcus-signal/issues/72

### Status
- Not started

### Scope
- Add local filesystem cache for GRIB2 subset files.
- Cache by model/product, run time, forecast hour, valid time, bbox key/hash, and field set version.
- Download from NOMADS on cache miss.
- Store basic metadata: file path, byte size, fetched time, expires time.
- Detect empty responses, non-success statuses, oversized responses, and HTML/error responses.
- Support fallback HRRR candidates from Issue 3.

### Relevant feature brief sections
- `Caching model`
- `Proposed HRRR server pipeline`
- `NOMADS HRRR 2D GRIB test URL`

### Handoff notes
- None yet.

### Files changed
- None yet.

### Tests run
- None yet.

### Deferred
- Database persistence.
- Distributed cache.
- Sampled JSON cache.
- `wgrib2` sampling orchestration.

---

## Issue 5 - HRRR field sampling and raw-parameter normalization

### GitHub
- `#73` - https://github.com/justinrooks/arcus-signal/issues/73

### Status
- Not started

### Scope
- Use `Wgrib2Client` against cached GRIB subsets.
- Normalize representative records into `TornadoRawParameters`.
- Preserve sampled-grid/inventory diagnostics where practical.
- Convert units only when source units are known and deterministic.
- Leave unavailable fields nil.

### Relevant feature brief sections
- `Core parameter set`
- `Recommended data model`
- `wgrib2 role`
- `Example JSON response`

### Handoff notes
- None yet.

### Files changed
- None yet.

### Tests run
- None yet.

### Deferred
- Interpretation/scoring.
- Database persistence.
- Full sounding reconstruction.
- SPC fallback.

---

## Issue 6 - Tornado ingredient assessment and freshness/degraded semantics

### GitHub
- `#74` - https://github.com/justinrooks/arcus-signal/issues/74

### Status
- Not started

### Scope
- Define assessment enums:
  - `IngredientSupport`
  - `SnapshotConfidence`
  - `IngredientTrend`
  - `StormModeHint`
  - `TornadoLimitingFactor`
- Implement deterministic v1 assessment rules for:
  - instability
  - deep shear
  - low-level rotation
  - cloud-base favorability
  - composite/available agreement
- Produce primary drivers, limiting factors, confidence, and summary.
- Add freshness/degraded semantics from source/cache metadata.

### Relevant feature brief sections
- `Recommended user-facing model`
- `Core parameter set`
- `The five core assessment pillars`
- `Recommended data model`
- `Example JSON response`

### Handoff notes
- None yet.

### Files changed
- None yet.

### Tests run
- None yet.

### Deferred
- Trend from multi-run comparison unless trivial.
- Full storm-mode diagnosis.
- Push notification wording.
- SwiftUI presentation.

---

## Issue 7 - Local sampled snapshot cache keyed by H3/source/rules version

### GitHub
- `#76` - https://github.com/justinrooks/arcus-signal/issues/76

### Status
- Not started

### Scope
- Add local sampled snapshot cache.
- Key by H3 cell, model/product, run time, forecast hour, valid time, and rules version.
- Store response-ready JSON or an internal snapshot model.
- Include fetched time and expires time.
- Ignore stale, corrupt, or rules-version-mismatched cache entries safely.

### Relevant feature brief sections
- `Caching model`
- `Cache expiration`
- `Recommended v1 cache policy`

### Handoff notes
- None yet.

### Files changed
- None yet.

### Tests run
- None yet.

### Deferred
- Database-backed sample persistence.
- Distributed cache coherence.
- User/device-specific personalization.
- Push refresh graph integration.

---

## Issue 8 - Provider/controller orchestration for local end-to-end snapshots

### GitHub
- `#75` - https://github.com/justinrooks/arcus-signal/issues/75

### Status
- Not started

### Scope
- Wire the provider and controller for local end-to-end behavior.
- Orchestrate:
  1. H3 validation and centroid resolution.
  2. HRRR candidate selection.
  3. NOMADS URL construction.
  4. GRIB subset cache/fetch.
  5. Sampled snapshot cache check.
  6. `wgrib2` point sampling.
  7. Raw parameter normalization.
  8. Assessment and freshness.
  9. JSON response.
- Return useful HTTP errors for invalid input, source unavailability, `wgrib2` failure, and insufficient data.
- Log source metadata and degraded/fallback decisions.

### Relevant feature brief sections
- `Proposed HRRR server pipeline`
- `Example JSON response`
- `Caching model`
- `Server architecture decision`

### Handoff notes
- None yet.

### Files changed
- None yet.

### Tests run
- None yet.

### Deferred
- Production deployment config for `wgrib2`.
- APNs/content-available push wiring.
- Database persistence for caches.
- Broader app refresh graph integration.
- Separate Storm Setup service.

---

## Open Questions

1. Should the first route preserve the currently-started `GET /api/v1/storm-setup?h3=<cell>` shape temporarily, or immediately move to `GET /api/v1/storm-setup/current?h3=<cell>`?
2. What exact local cache root should be used for GRIB subsets and sampled snapshots?
3. How large should the v1 bbox around the H3 centroid be?
4. Which HRRR forecast-hour fallback window is acceptable before returning degraded/unavailable?
5. Which `wgrib2` inventory fields can be reliably mapped to effective shear and mixed-layer values from HRRR 2D products?
6. Should the first endpoint return partial snapshots with degraded confidence when only some core fields are available, or fail until a minimum field set is present?
7. Should sampled snapshot cache survive process restarts in v1, or is in-memory plus GRIB cache enough for the earliest local validation?

---

## Verification Ledger

No Storm Setup verification has been run yet.
