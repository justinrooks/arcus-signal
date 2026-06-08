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
- `#75` - Provider/controller orchestration for local end-to-end snapshots
- `#76` - Local sampled snapshot cache keyed by H3/source/rules version
- `#77` - ProcessRunner stdout/stderr draining
- `#78` - Lazy/API-scoped provider wiring
- `#79` - Progress log status, open questions, and verification ledger reconciliation
- `#80` - Replace production precondition failures with explicit errors
- `#81` - Package `wgrib2` into Docker image
- `#82` - Configure Docker runtime paths and caches

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
- The implementation chain through `#75`, `#76`, `#77`, `#78`, and `#80` is complete.
- Issue `#79` is this reconciliation pass and is complete with this update.
- The next runtime follow-up is `#81` unless the actual issue tracker still has `#77`, `#78`, or `#80` open.
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
- Issue `#72` is complete.
- Issue `#73` is complete.
- Issue `#74` is complete.
- Issue `#75` is complete.
- Issue `#76` is complete.
- Issue `#77` is complete.
- Issue `#78` is complete.
- Issue `#80` is complete.

## Follow-up Sequence

- `#77` - ProcessRunner stdout/stderr draining: complete.
- `#78` - Lazy/API-scoped provider wiring: complete.
- `#79` - Progress log status, open questions, and verification ledger reconciliation: complete.
- `#80` - Replace production precondition failures with explicit errors: complete.
- `#81` - Package `wgrib2` into Docker image: next runtime follow-up.
- `#82` - Configure Docker runtime paths and caches: queued after Docker packaging.

## Issue #78 - Storm Setup provider wiring stays lazy and API-scoped

### Status
- Complete

### Final wiring decision
- Removed the eager Storm Setup bootstrap from `Sources/App/configure.swift`.
- Left `Application.stormSetupProvider` as the lazy construction seam.
- Kept test injection intact by continuing to use `app.stormSetupProvider = ...` in tests.
- Did not add new Storm Setup wiring in `apiRoutes.swift` because the lazy provider default was already sufficient.

### Files changed
- `Sources/App/configure.swift`
- `Tests/AppTests/AppTests.swift`
- `docs/plans/storm-setup-progress.md`

### Tests / commands run
- `swift test --filter StormSetup`
- `swift test`
- `swift build`

### Local verification notes
- `swift test --filter StormSetup` passed and exercised the Storm Setup controller, provider, cache, and wgrib2 client suites.
- `swift test` passed across the full suite.
- `swift build` passed.
- The new worker bootstrap test confirmed a pre-injected Storm Setup provider survives worker configuration, which is the practical proof that `configure(..., mode: .worker)` is no longer constructing a default provider eagerly.

### Deferred scope
- No Storm Setup runtime logic changed.
- No HRRR sampling, cache, `wgrib2`, Docker, or assessment logic changed.
- No worker-side Storm Setup feature work was added.

### Handoff notes for issue #80
- Keep Storm Setup wiring lazy unless a future API-only seam truly needs explicit configuration.
- If later issues need API-scoped setup, prefer route/controller-local wiring over broad bootstrap changes.
- Do not reintroduce global provider construction in `configure.swift`; the current ownership boundary is now correct.

## Issue #80 - Production helper traps become explicit errors

### GitHub
- `#80` - https://github.com/justinrooks/arcus-signal/issues/80

### Status
- Complete

### Scope
- Replace production `preconditionFailure` usage in Storm Setup date/key/URL helpers with explicit error paths or safe optional construction.
- Keep valid-path behavior unchanged for HRRR run selection, NOMADS URL composition, and cache key generation.
- Add focused tests for explicit missing-metadata and missing-URL failure paths.

### Files changed
- `Sources/App/StormSetup/HrrrSourceModels.swift`
- `Sources/App/StormSetup/HrrrRunResolver.swift`
- `Sources/App/StormSetup/HrrrNomadsURLBuilder.swift`
- `Sources/App/StormSetup/StormSetupCacheKey.swift`
- `Sources/App/StormSetup/StormSetupSnapshotCacheKey.swift`
- `Tests/AppTests/StormSetupGribSubsetCacheTests.swift`
- `Tests/AppTests/StormSetupSnapshotCacheTests.swift`
- `docs/plans/storm-setup-progress.md`

### Tests / commands run
- `rg -n "preconditionFailure|fatalError" Sources/App/StormSetup`
- `swift test --filter StormSetup`
- `swift test`
- `swift build`

### Local verification notes
- `swift test --filter StormSetup` passed and exercised the Storm Setup controller, provider, cache, selection, and wgrib2 client suites.
- `swift test` passed across the full package test suite.
- `swift build` passed.
- The production Storm Setup module now has no `preconditionFailure` or `fatalError` hits.
- The new tests cover explicit missing source metadata for cache key construction and missing NOMADS URL handling through the GRIB subset cache.

### Deferred scope
- No HRRR selection policy changes.
- No NOMADS field-set changes.
- No cache identity semantic changes.
- No provider/controller orchestration refactor.
- No broader error-model cleanup outside `Sources/App/StormSetup`.

### Handoff notes for issue #79
- Use this section as the verified state for the Storm Setup runtime changes.
- Issue `#79` stayed focused on progress-log reconciliation only; the helper refactor was not reopened and no runtime edits were added as part of that documentation pass.
- The verification commands and file list above are the authoritative references for the completed runtime change.

## Issue #79 - Progress log status, open questions, and verification ledger reconciliation

### GitHub
- `#79` - https://github.com/justinrooks/arcus-signal/issues/79

### Status
- Complete

### Scope
- Reconcile `docs/plans/storm-setup-progress.md` with the completed Storm Setup implementation history.
- Mark the completed implementation chain accurately for `#69`, `#70`, `#71`, `#72`, `#73`, `#74`, `#76`, and `#75`.
- Add the follow-up issue sequence for `#77`, `#78`, `#79`, `#80`, `#81`, and `#82`.
- Remove stale open questions that were resolved by implementation decisions.
- Replace the stale verification note with the review commands that were actually run.

### Files changed
- `docs/plans/storm-setup-progress.md`

### Tests / commands run
- `rg -n "No later Storm Setup issue has been started|No Storm Setup verification has been run yet|Open Questions" docs/plans/storm-setup-progress.md`

### Deferred scope
- No source code changes.
- No runbook changes.
- No additional Storm Setup runtime work.

### Handoff notes for issue #81
- The runtime implementation chain is complete through `#80`; the next work item should be `#81` unless the tracker still shows `#77`, `#78`, or `#80` incomplete.
- Keep `docs/plans/storm-setup-progress.md` as the living handoff ledger and only update it when the tracker state changes again.
- Do not reopen the resolved runtime decisions while packaging `wgrib2` or configuring Docker paths and caches.

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

## Issue 4 - ProcessRunner drains stdout/stderr safely

### GitHub
- `#77` - https://github.com/justinrooks/arcus-signal/issues/77

### Status
- Complete

### Scope
- Drain `ProcessRunner` stdout and stderr while the child process is still running.
- Preserve the existing `launchFailed`, `timedOut(timeoutSeconds:stderr:)`, `nonZeroExit(code:stderr:)`, and successful `ProcessResult(stdout:stderr:exitCode:)` behavior.
- Keep the fix local to `Sources/App/StormSetup/GribAdapter.swift`.
- Add focused tests for success, non-zero exit, timeout stderr preservation, and large-output pipe draining.

### Handoff notes
- `ProcessRunner` now launches detached stdout/stderr drain tasks immediately after `Process.run()`, so large child output no longer has to wait for process exit before being consumed.
- The large-output regression test writes 15,000 lines to both stdout and stderr and completes without timing out.
- The timeout regression test now uses a child that flushes stderr before sleeping, which proves the runner preserves useful stderr on the timeout path.
- Issue `#78` should treat the runner as fixed and should not revisit pipe draining unless a new regression is discovered.

### Files changed
- `Sources/App/StormSetup/GribAdapter.swift`
- `Tests/AppTests/StormSetupWgrib2ClientTests.swift`

### Tests run
- `swift test --filter StormSetup` - passed
- `swift test` - passed
- `swift build` - passed

### Local verification notes
- The Storm Setup slice passed with the new pipe-draining implementation in place.
- The full package test suite passed.
- `swift build` completed cleanly.
- Existing unrelated deprecation warnings remain elsewhere in the codebase, but there were no failures.

### Deferred
- No additional `ProcessRunner` cleanup is needed for this issue.
- Docker/runtime follow-up work remains out of scope for `#77` and should stay deferred to `#78` or later.

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
- Complete

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
- `GribSubsetCache` now owns the GRIB subset filesystem cache and validates cache entries before reuse.
- Cache hits return existing file metadata without redownloading; cache misses download from the NOMADS subset URL produced by issue `#71`.
- Cache entries are written atomically with a JSON sidecar that stores the source metadata, byte size, checksum, fetch time, and expiry.
- Corrupt, truncated, missing, expired, oversized, empty, and obvious HTML/text responses are rejected and never treated as valid cache entries.
- `NomadsGribDownloader` walks ordered HRRR candidates and returns the first usable subset, surfacing aggregate failure detail if all candidates fail.
- Cache root decision: `FileManager.default.temporaryDirectory/arcus-signal/storm-setup/grib-subsets` via `StormSetupConfiguration.localGribSubsetCacheRootURL`.
- Max byte-size decision: `25 MiB` (`25 * 1024 * 1024` bytes).
- Cache retention decision: `12 hours` for local development.
- Fallback behavior: try candidates in the order provided by issue `#71`; the first successful HTTP 2xx, non-empty, non-HTML subset wins.
- Issue `#73` should consume `GribSubsetCacheResult.localFileURL` / `byteSize` / `fetchedAt` / `expiresAt` and not assume the GRIB subset is always fresh on first request.

### Files changed
- `Sources/App/StormSetup/GribSubsetCache.swift`
- `Sources/App/StormSetup/NomadsGribDownloader.swift`
- `Sources/App/StormSetup/StormSetupCacheKey.swift`
- `Sources/App/StormSetup/StormSetupConfiguration.swift`
- `Sources/App/StormSetup/StormSetupModels.swift`
- `Tests/AppTests/StormSetupGribSubsetCacheTests.swift`
- `Tests/AppTests/StormSetupWgrib2ClientTests.swift`

### Tests run
- `swift test --filter StormSetupGribSubsetCacheTests` - passed
- `swift test --filter StormSetup` - passed
- `swift test` - passed
- No live NOMADS download was attempted; network success remains manual-only and is not required for the automated test suite.

### Deferred
- Database persistence.
- Distributed cache.
- Sampled JSON cache (`#76`).
- Raw parameter normalization and `wgrib2` sampling orchestration (`#73`).
- Assessment/freshness rules (`#74`).
- End-to-end provider/controller orchestration (`#75`).

---

## Issue 5 - HRRR field sampling and raw-parameter normalization

### GitHub
- `#73` - https://github.com/justinrooks/arcus-signal/issues/73

### Status
- Complete

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
- `HrrrFieldSampler` now wraps cached GRIB subset files with the hardened `Wgrib2Client` seam and preserves the requested centroid coordinates alongside each sampled `Wgrib2PointSample`.
- `GribInventoryFieldMap` performs explicit variable + level matching from wgrib2 inventory text and drives deterministic normalization.
- `TornadoIngredientNormalizer` produces `TornadoRawParameters` plus raw sample diagnostics without throwing on missing, unmatched, or non-numeric values.
- Raw diagnostics now preserve inventory text, parsed value, matched raw parameter key, requested lon/lat, and nearest grid lon/lat when wgrib2 provides it.
- `TornadoRawParameters` now includes `mlcinJkg` and an optional `diagnostics` array so the response shape can carry the raw sampling trail forward into issue `#75`.
- `VUCSH`/`VVCSH` are converted from m/s to knots for `shear06kmKt` using the explicit factor `1.9438444924406`.
- `HGT` at the level of adiabatic condensation from surface is carried through as `mllclM` without further conversion.
- Issue `#74` should start from the normalized raw fields and the current nil surface for unsupported fields. Do not re-open the sampler/normalizer seam unless a field-map bug is proven.

### Files changed
- `Sources/App/StormSetup/GribInventoryFieldMap.swift`
- `Sources/App/StormSetup/HrrrFieldSampler.swift`
- `Sources/App/StormSetup/StormSetupModels.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Sources/App/StormSetup/TornadoIngredientNormalizer.swift`
- `Sources/App/StormSetup/Wgrib2Client.swift`
- `Sources/App/StormSetup/Wgrib2PointSample.swift`
- `Tests/AppTests/StormSetupIngredientNormalizationTests.swift`

### Tests run
- `swift test --filter StormSetupIngredientNormalizationTests` - passed
- `swift test --filter StormSetup` - passed
- `swift test` - passed
- Full suite completed with existing unrelated deprecation warnings only; no failures.

### Deferred
- Interpretation/scoring (`#74`).
- Provider/controller end-to-end orchestration (`#75`).
- Sampled JSON cache (`#76`).
- Database persistence.
- Full sounding reconstruction.
- SPC fallback.
- Effective SRH, effective shear, and storm-motion/vector fields remain nil until the current HRRR 2D slice supports them without guesswork.

### Confirmed field mappings
- `CAPE:surface` -> `sbcapeJkg`
- `CAPE:90-0 mb above ground` -> `mlcapeJkg`
- `CAPE:255-0 mb above ground` -> `mucapeJkg`
- `CIN:90-0 mb above ground` -> `mlcinJkg`
- `HLCY:1000-0 m above ground` or `HLCY:0-1 km above ground` -> `srh01kmM2s2`
- `HLCY:3000-0 m above ground` or `HLCY:0-3 km above ground` -> `srh03kmM2s2`
- `VUCSH` + `VVCSH` at `0-6000 m above ground` or `0-6 km above ground` -> `shear06kmKt` via vector magnitude and explicit m/s to kt conversion
- `HGT` at the level of adiabatic condensation from sfc/surface -> `mllclM`

### Uncertain / deferred field mappings
- `effectiveSrhM2s2`
- `effectiveShearKt`
- `bunkersRightMotion`
- `bunkersLeftMotion`
- `stormRelativeWind46km`
- `meanWind850300mb`
- Any CAPE/CIN layer beyond the explicit inventory combinations above should remain nil unless a later issue proves a deterministic, documented mapping.

### Unit conversion decisions
- `shear06kmKt` is derived from `VUCSH`/`VVCSH` in m/s using `hypot(u, v) * 1.9438444924406`.
- `mllclM` uses the HRRR `HGT` height value directly as a meters-like raw field.
- CAPE/CIN and SRH values are passed through without additional unit conversion.

### Risks / open questions
- The CAPE/CIN layer semantics are explicit in the current field map and validated by tests, but they remain the most inference-heavy piece of the slice because HRRR exposes them as fixed layer selections rather than labeled parcel types.
- `#74` should decide how to interpret the raw fields and whether any of the currently nil fields should become part of the assessment model.

---

## Issue 6 - Tornado ingredient assessment and freshness/degraded semantics

### GitHub
- `#74` - https://github.com/justinrooks/arcus-signal/issues/74

### Status
- Completed

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
- `TornadoIngredientAssessment` is now a stable nonoptional payload with `overall`, per-pillar support values, `confidence`, `trend`, `stormModeHint`, `primaryDrivers`, `limitingFactors`, and a calm summary string.
- `IngredientFreshness` now derives from source timing metadata and exposes `expiresAt`, `isStale`, and `isDegraded`.
- The new interpreter keeps `trend` and `stormModeHint` at `unknown` because this slice does not yet have defensible history or storm-mode signals.
- `DefaultStormSetupProvider` now routes snapshot construction through the new freshness and assessment helpers instead of returning placeholder `nil` assessment fields.
- The controller contract is unchanged, but the returned JSON now carries explicit unknown/degraded semantics instead of nullable assessment fields.
- Issue `#76` should consume these stable models and add the sampled snapshot cache around them without changing the interpretation rules again unless a bug is found.

### Files changed
- `Sources/App/StormSetup/StormSetupModels.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Sources/App/StormSetup/IngredientFreshness.swift`
- `Sources/App/StormSetup/StormSetupRulesVersion.swift`
- `Sources/App/StormSetup/TornadoIngredientAssessment.swift`
- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Sources/App/StormSetup/TornadoRawParameters+Empty.swift`
- `Tests/AppTests/StormSetupControllerTests.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`

### Tests run
- `swift test --filter TornadoIngredientInterpreterTests` - passed
- `swift test --filter StormSetupControllerTests` - passed
- `swift test` - passed
- Full suite completed with existing unrelated Vapor/deprecation warnings elsewhere in the codebase, but no failures.

### Assessment threshold decisions
- Instability uses the strongest available CAPE signal, with weak/conditional/supportive/strong cutoffs at `<500`, `<1000`, `<2000`, and `>=2000` J/kg.
- Deep shear uses the strongest available 0-6 km or effective shear signal, with cutoffs at `<30`, `<40`, `<55`, and `>=55` kt.
- Low-level rotation uses the strongest available SRH signal, with cutoffs at `<75`, `<175`, `<250`, and `>=250` m2/s2.
- Cloud-base favorability combines MLLCL and temperature/dewpoint spread and stays conservative when either field is missing or high.
- Overall support only reaches `strong` when multiple core pillars are strong and the composite signal also agrees; `conditional` stays first-class when rotation is merely modest.

### Freshness / degraded decisions
- Freshness is derived from source valid time, run time, forecast hour, fetched at, and a fixed 90-minute validity window by default.
- `isStale` flips when the fetched time is beyond the derived expiry.
- `isDegraded` is reserved for stale timing metadata or missing source timing inputs.
- Assessment `confidence` becomes `degraded` when freshness is degraded or too few core pillars are available; missing composite data alone now lowers confidence without pretending to know more than we do.

### Deferred
- Multi-run trend computation. `trend` remains `unknown` until real history is available.
- Full storm-mode diagnosis. `stormModeHint` remains `unknown` until a defensible signal exists.
- Actual sampled raw HRRR data in the provider/controller path. That remains issue `#75`.
- Sample cache persistence. That is issue `#76`.
- Push notification wording.
- SwiftUI presentation.

### Risks / open questions
- The provider still emits `TornadoRawParameters.empty` until the orchestration issue wires real sampled raw values through the snapshot path.
- The current rules are deliberately conservative. They are explainable, but they are not a meteorology simulator wearing a fake mustache.
- If future HRRR fields supply a real storm-mode signal, `stormModeHint` should be updated in one place, not smeared across the controller or cache layers.

---

## Issue 7 - Local sampled snapshot cache keyed by H3/source/rules version

### GitHub
- `#76` - https://github.com/justinrooks/arcus-signal/issues/76

### Status
- Completed

### Scope
- Add local sampled snapshot cache.
- Key by H3 cell, model/product, domain when present, run time, forecast hour, valid time, field set version, and rules version.
- Store an internal `TornadoIngredientSnapshot` wrapper that can be returned directly by #75.
- Include fetched time, expires time, cache hit/miss, rules version, and source valid time in the returned cache result.
- Ignore stale, corrupt, unreadable, incomplete, or rules-version-mismatched cache entries safely.

### Relevant feature brief sections
- `Caching model`
- `Cache expiration`
- `Recommended v1 cache policy`

### Handoff notes
- The sampled cache now lives alongside the GRIB subset cache under the shared temp-root family chosen in #72:
  - `/tmp/arcus-signal/storm-setup/grib-subsets`
  - `/tmp/arcus-signal/storm-setup/sampled-snapshots`
- Cache identity intentionally excludes bbox. That belongs to the GRIB subset cache, not the sampled snapshot cache.
- Cache identity includes `h3Cell` as signed `Int64`, `model`, `product`, `domain` when present, `runTime`, `forecastHour`, `validTime`, `fieldSetVersion`, and `rulesVersion`.
- `domain` is normalized to `none` when absent so optional source metadata cannot alias a different concrete domain.
- `StormSetupSnapshotCache` persists a Codable wrapper with the full snapshot and validates the stored key against both the persisted key and the reconstructed key from the snapshot payload.
- Expired entries are ignored when `now >= expiresAt`, and unreadable/corrupt/incomplete records are removed on read.
- Cache writes use atomic file replacement.
- Issue #75 should use `StormSetupSnapshotCacheKey` and `StormSetupSnapshotCache` directly rather than inventing another cache layer.

### Files changed
- `Sources/App/StormSetup/StormSetupConfiguration.swift`
- `Sources/App/StormSetup/StormSetupRulesVersion.swift`
- `Sources/App/StormSetup/StormSetupSnapshotCacheKey.swift`
- `Sources/App/StormSetup/StormSetupSnapshotCache.swift`
- `Tests/AppTests/StormSetupSnapshotCacheTests.swift`
- `Tests/AppTests/StormSetupWgrib2ClientTests.swift`

### Tests run
- `swift test --filter StormSetupSnapshotCacheTests` - passed
- `swift test` - passed
- Existing unrelated Vapor/deprecation warnings still appear in the broader suite, but there were no failures.

### Deferred
- Database-backed sample persistence.
- Distributed cache coherence.
- User/device-specific personalization.
- Push refresh graph integration.
- Provider/controller orchestration for #75.
- Any future cache eviction policy beyond source expiration.

---

## Issue 8 - Provider/controller orchestration for local end-to-end snapshots

### GitHub
- `#75` - https://github.com/justinrooks/arcus-signal/issues/75

### Status
- Completed

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
- `GET /api/v1/storm-setup/current?h3=<cell>` is now wired end-to-end through the local provider/controller path.
- The controller stays thin: it validates the query parameter, converts H3 at the HTTP boundary, maps provider errors to useful HTTP responses, and returns `Content`.
- The provider now orchestrates H3 resolution, ordered HRRR candidate selection, NOMADS URL construction, sampled snapshot cache lookup, GRIB subset fetch/cache, `wgrib2` point sampling, raw normalization, assessment/freshness interpretation, and sampled snapshot persistence.
- Cache hit/miss behavior is runtime-driven. The sampled snapshot cache can short-circuit the rest of the pipeline, while the GRIB subset cache still owns bbox-specific storage.
- Source metadata is preserved in the response and includes model, product, domain, run time, forecast hour, valid time, field set version, and freshness timestamps.
- Logging now records selected candidates, fallback decisions, cache hit/miss decisions, `wgrib2` failures, and degraded/freshness state without dumping binary payloads.
- Errors stay specific: invalid H3, no usable HRRR candidate, NOMADS download failure, GRIB cache failure, `wgrib2` failure, and insufficient normalized data.

### Files changed
- `Sources/App/Controllers/StormSetupController.swift`
- `Sources/App/StormSetup/StormSetupConfiguration.swift`
- `Sources/App/StormSetup/StormSetupModels.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Sources/App/StormSetup/StormSetupSnapshotCache.swift`
- `Sources/App/configure.swift`
- `Tests/AppTests/StormSetupControllerTests.swift`
- `Tests/AppTests/StormSetupProviderTests.swift`

### Tests run
- `swift test --filter StormSetupProviderTests` - passed
- `swift test --filter StormSetupControllerTests` - passed
- `swift test` - passed
- Broader suite still emits unrelated repository warnings, but there were no test failures.

### Manual local verification
- Representative command:
  - `curl -sS -D - 'http://127.0.0.1:8080/api/v1/storm-setup/current?h3=617700169958293503'`
- Result:
  - `200 OK`
  - JSON response included `h3Cell`, `centroid`, `source`, `raw`, `assessment`, and `freshness`.
  - `source` preserved model/product/domain/run time/forecast hour/valid time/field set metadata.
  - `raw` included sampled tornado ingredients and diagnostics.
  - `freshness` included fetched/expires timestamps and degraded/stale flags.
- Cache behavior observed:
  - First live request: sampled snapshot cache miss, GRIB subset cache miss, live NOMADS fetch, `wgrib2` sampling, sampled snapshot cached.
  - Repeated same request: sampled snapshot cache hit, no downstream re-sampling.
  - Forced replay after removing only the sampled snapshot file: sampled snapshot cache miss, GRIB subset cache hit, no second NOMADS download.

### Deferred
- Production deployment config for `wgrib2`.
- APNs/content-available push wiring.
- Database persistence for caches.
- Broader app refresh graph integration.
- Separate Storm Setup service.

### Risks / open questions
- Live NOMADS availability still governs the real endpoint. When upstream data is unavailable, the route correctly returns a source failure instead of inventing a snapshot.
- The local `wgrib2` path is still an environment dependency, so this endpoint is only as portable as that binary path.
- No new Storm Setup API questions remain for this issue; the remaining work is deferred production plumbing, not orchestration design.

---

## Open Questions

- None remain for the completed Storm Setup slices. The remaining work is tracked in the follow-up issues, not in unresolved design questions.

---

## Verification Ledger

- `swift test --filter StormSetup` - passed during the Storm Setup review pass.
- `swift build` - passed during the Storm Setup review pass.
- `swift test` - passed during the Storm Setup review pass.
- `rg -n "No later Storm Setup issue has been started|No Storm Setup verification has been run yet|Open Questions" docs/plans/storm-setup-progress.md` - passed as the reconciliation smoke check for issue `#79`.
