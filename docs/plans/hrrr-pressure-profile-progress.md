# HRRR Pressure Profile Progress Log

## Overview

HRRR Pressure Profile adds byte-range pressure-level HRRR profile extraction and Arcus-Anvil ingredient evidence to Arcus Signal.

Implementation should proceed one issue at a time, following `docs/plans/hrrr-pressure-profile-runbook.md`.

Epic status:
- Complete

Primary GitHub epic:
- `#85` - https://github.com/justinrooks/arcus-signal/issues/85

Related local docs:
- `AGENTS.md`
- `docs/architecture.md`
- `docs/epics-stories.md`
- `docs/hrrr-pressure-profile.md`
- `docs/plans/hrrr-pressure-profile-runbook.md`
- `docs/plans/storm-setup-issue-runbook.md`
- `docs/plans/storm-setup-progress.md`

---

## Global Decisions

- Feature name: HRRR Pressure Profile.
- Keep the existing Storm Setup surface HRRR flow intact.
- Pressure profile input remains H3-first; Signal resolves the H3 centroid internally.
- AWS HRRR direct objects are the primary source for `wrfprsf`.
- `.idx` inventory parsing and HTTP byte ranges are the target pressure acquisition path.
- The whole-file pressure GRIB cache was retired; future pressure work must use the byte-range subset cache.
- Do not introduce Zarr, BUFKit, SHARPpy inside Signal, or a broad data-platform layer.
- Do not move HRRR fetching into Arcus-Anvil.
- Use existing `wgrib2` execution and point-sampling plumbing.
- Use existing pressure grouping and Anvil request-builder seams where possible.
- The frozen Anvil profile request remains profile-only; no extra surface-field inputs were required beyond the existing runTime, forecastHour, validTime, location, and profile payload.
- Response contract values are transport-only: optional SCP/STP/SHIP plus diagnostics and status, with missing severe-weather values treated as absent rather than synthesized.
- Required profile variables for the first vertical slice are:
  - `HGT`
  - `TMP`
  - `DPT` when available, or an explicitly scoped moisture alternative if Anvil contract requires it
  - `UGRD`
  - `VGRD`
- Preferred initial pressure levels are the existing `StormSetupPressureLevel.preferredDescending` values unless a later issue changes them with evidence.
- Unit normalization belongs after point sampling and before Anvil request construction.
- Invalid and below-ground levels must be filtered before Anvil dispatch.
- Anvil SCP/STP/SHIP output is supporting ingredient evidence, not raw user-facing output.
- Product language must describe environmental favorability, not tornado or hail prediction.

---

## Current State Summary

Keep:
- Surface Storm Setup endpoint and provider are working.
- HRRR run/forecast selection exists.
- `wgrib2` process execution and point-sample parsing exist.
- Pressure product/source metadata exists.
- AWS pressure direct-object URL construction and `.idx` probing exist.
- Whole-file pressure raw cache has been retired.
- Pressure-profile grouping exists.
- Frozen Anvil request DTO and preview endpoint exist.
- Frozen Anvil response DTO exists.
- Ingredient interpreter already has nullable composite slots, but they are currently unpopulated.

Missing:
- None. The byte-range `.idx` path, preview wiring, Anvil client, and ingredient-evidence mapping are complete.

Do not touch:
- Existing surface GRIB flow.
- Notification/APNs/NWS pipelines.
- Server-side user location storage model.

---

## Issue Sequence

Work these issues sequentially:

1. `#91` - 01: Parse HRRR pressure `.idx` inventories
2. `#99` - 02: Select Anvil pressure-profile messages and plan byte ranges
3. `#98` - 03: Download and cache byte-range HRRR pressure GRIB subsets
4. `#92` - 04: Wire Anvil profile preview through byte-range pressure subsets
5. `#103` - 05: Reconcile and freeze the Anvil request/response contract
6. `#101` - 06: Add Arcus-Anvil HTTP client for profile analysis
7. `#102` - 07: Map Anvil severe-weather output into ingredient evidence
8. `#100` - 08: Finalize HRRR pressure-profile docs and verification ledger

`#93` is obsolete after consolidation into `#85`.

---

## Existing Code Map

Relevant source:
- `Sources/App/StormSetup/HrrrSourceModels.swift`
- `Sources/App/StormSetup/HrrrPressureDirectObjectResolver.swift`
- `Sources/App/StormSetup/HrrrPressureSubsetGribCache.swift`
- `Sources/App/StormSetup/StormSetupPressureLevel.swift`
- `Sources/App/StormSetup/StormSetupPressureProfileModels.swift`
- `Sources/App/StormSetup/StormSetupPressureProfileGrouper.swift`
- `Sources/App/StormSetup/AnvilProfileRequestBuilder.swift`
- `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`
- `Sources/App/Controllers/AnvilProfilePreviewController.swift`
- `Sources/App/Models/API/AnvilAnalyzeProfileRequest.swift`
- `Sources/App/Models/API/AnvilAnalyzeProfilePreviewResponse.swift`

Relevant tests:
- `Tests/AppTests/StormSetupHrrrSourceTests.swift`
- `Tests/AppTests/HrrrPressureSubsetGribCacheTests.swift`
- `Tests/AppTests/StormSetupPressureProfileGroupingTests.swift`
- `Tests/AppTests/AnvilAnalyzeProfileDTOTests.swift`
- `Tests/AppTests/AnvilProfileRequestBuilderTests.swift`
- `Tests/AppTests/AnvilProfilePreviewProviderTests.swift`
- `Tests/AppTests/AnvilProfilePreviewControllerTests.swift`

---

## Investigation Notes

- `HrrrPressureDirectObjectResolver` currently builds `.idx` URLs and probes them for availability, but does not parse inventory content.
- `StormSetupPressureSubsetGribCache` performs the byte-range pressure download and caches only the selected subset.
- The existing HTTP abstraction accepts headers, so range requests can be added without changing every caller.
- No sample `.idx`, BUFKit, SHARPpy, SCP/STP/SHIP fixture, or sounding fixture exists in the repo outside build artifacts.
- Pressure grouping currently starts after `wgrib2 -lon` output exists. Byte-range planning needs tests before that point.
- The old pressure-level plan under `docs/superpowers/plans/2026-06-19-hrrr-pressure-level-support.md` is historical and still describes the obsolete NOMADS pressure attempt.

---

## Status Ledger

### Issue #91 - 01: Parse HRRR pressure `.idx` inventories

Status: Completed

Scope:
- Add a pure parser for HRRR pressure `.idx` inventory text.
- Preserve message number, byte offset, variable, level, forecast label, and raw line.
- Add a compact representative fixture.

Deferred:
- Selecting profile fields.
- Computing byte ranges.
- HTTP downloads.

Files changed:
- `Sources/App/StormSetup/HrrrPressureIdxInventory.swift`
- `Tests/AppTests/HrrrPressureIdxInventoryTests.swift`
- `Tests/AppTests/Fixtures/HrrrPressureSample.idx`

Tests and commands run:
- `swift test --filter HrrrPressureIdxInventoryTests` (blocked by an existing package/toolchain link failure involving `VaporAPNS` and `SwiftUICore`)
- `HOME=/private/tmp SWIFT_MODULE_CACHE_PATH=/private/tmp/clang-cache xcrun swiftc -typecheck Sources/App/StormSetup/HrrrPressureIdxInventory.swift`
- `HOME=/private/tmp SWIFT_MODULE_CACHE_PATH=/private/tmp/clang-cache xcrun swiftc Sources/App/StormSetup/HrrrPressureIdxInventory.swift /private/tmp/hrrr_pressure_idx_inventory_check.swift -o /private/tmp/hrrr_pressure_idx_inventory_check && /private/tmp/hrrr_pressure_idx_inventory_check`

Local verification notes:
- The parser is pure and deterministic.
- Malformed lines are skipped without throwing.
- Duplicate variable/level records remain distinct.
- Extra colon-delimited fields are preserved on the forecast label tail.
- Byte offsets remain numeric and ordered as read.

Deferred scope:
- Message selection from parsed inventories.
- Byte-range planning and `Range` header construction.
- HTTP range downloading and partial-content validation.
- GRIB subset assembly/caching and preview wiring.

Handoff notes for `#99`:
- Consume `HrrrPressureIdxInventory.records` directly instead of re-parsing raw strings.
- Keep the parser unchanged; selection logic should live in the next issue’s narrow planner layer.
- Preserve `rawLine` for diagnostics when a later selector drops or rejects a record.

### Issue #99 - 02: Select Anvil pressure-profile messages and plan byte ranges

Status: Completed

Scope:
- Select only profile messages needed for Anvil from parsed `.idx` records.
- Convert selected offsets to closed byte ranges.
- Report missing variables and levels.

Deferred:
- HTTP range fetching.
- GRIB file assembly.

Files changed:
- `Sources/App/StormSetup/HrrrPressureProfileMessageSelector.swift`
- `Sources/App/StormSetup/HrrrGribByteRangePlanner.swift`
- `Tests/AppTests/HrrrPressureProfileMessageSelectorTests.swift`
- `Tests/AppTests/HrrrGribByteRangePlannerTests.swift`

Tests and commands run:
- `swift test --filter HrrrPressureProfile` (blocked by the existing package link failure involving `VaporAPNS` and `SwiftUICore`)
- `swift test --filter HrrrGribByteRangePlannerTests` (blocked by the same package link failure)
- `HOME=/private/tmp SWIFT_MODULE_CACHE_PATH=/private/tmp/clang-cache xcrun swiftc Sources/App/StormSetup/HrrrPressureIdxInventory.swift Sources/App/StormSetup/StormSetupPressureLevel.swift Sources/App/StormSetup/StormSetupPressureProfileModels.swift Sources/App/StormSetup/HrrrPressureProfileMessageSelector.swift Sources/App/StormSetup/HrrrGribByteRangePlanner.swift /private/tmp/hrrr_pressure_profile_verify.swift -o /private/tmp/hrrr_pressure_profile_verify && /private/tmp/hrrr_pressure_profile_verify`

Local verification notes:
- The selector keeps only complete pressure levels in the preferred descending order contract and preserves inventory order for the retained records.
- Missing required variables are reported per pressure level; `DPT` is treated as missing moisture data when absent rather than synthesized.
- Unknown variables and unrequested pressure levels are recorded as ignored diagnostics, not fatal errors.
- The byte-range planner closes each selected message against the next inventory record offset and leaves the terminal selected message open-ended when there is no successor record.

Deferred scope:
- HTTP `Range` header fetching and partial-content validation.
- GRIB subset concatenation and cache persistence.
- Any preview or Anvil wiring that consumes the planned ranges.

Handoff notes for `#98`:
- Consume `HrrrPressureProfileMessageSelectionResult.selectedMessages` in inventory order.
- Use `HrrrGribByteRange.httpRangeHeaderValue` for deterministic range headers.
- Handle the terminal open-ended range explicitly when the last selected message has no following inventory record.

### Issue #98 - 03: Download and cache byte-range HRRR pressure GRIB subsets

Status: Implemented, runtime verification blocked by existing package link failure

Scope:
- Fetch selected byte ranges with `Range` headers.
- Validate partial-content responses.
- Concatenate selected messages into a subset GRIB2 file.
- Cache subset files by deterministic source and selection identity.

Deferred:
- Preview endpoint wiring.
- Anvil transport.

Files changed:
- `Sources/App/StormSetup/HrrrPressureByteRangeDownloader.swift`
- `Sources/App/StormSetup/HrrrPressureSubsetGribCache.swift`
- `Sources/App/StormSetup/StormSetupConfiguration.swift`
- `Tests/AppTests/HrrrPressureByteRangeDownloaderTests.swift`
- `Tests/AppTests/HrrrPressureSubsetGribCacheTests.swift`
- `Tests/AppTests/StormSetupConfigurationTests.swift`
- `Tests/AppTests/StormSetupWgrib2ClientTests.swift`

Tests and commands run:
- `swift test --filter HrrrPressureByteRangeDownloaderTests`

Local verification notes:
- The package build compiled the new downloader, cache, config, and test sources successfully.
- The test run stopped at the repository’s pre-existing link failure involving `VaporAPNS` and `SwiftUICore`, so the new tests could not execute in this environment.
- The downloader now requires `206 Partial Content`, validates `Content-Range` when present, and rejects ignored-range `200` responses, `416`, empty bodies, and obvious text/HTML bodies.
- The subset cache uses a separate pressure-subset cache root and a key that includes source URL plus selected range identity, so it does not collide with the surface or whole-file pressure caches.

Deferred scope:
- Preview endpoint wiring for `#92`.
- Any Anvil request/response transport work.
- Live-network verification against HRRR or NOMADS.

Handoff notes for `#92`:
- Wire the preview provider to `HrrrPressureSubsetGribCache` rather than the whole-file pressure cache.
- Pass the planned `HrrrGribByteRangePlan` through unchanged so the preview path preserves the same selection identity used for caching.
- Keep preview debug metadata focused on selected ranges and cache identity; do not reintroduce whole-file pressure fallback.

### Issue #92 - 04: Wire Anvil profile preview through byte-range pressure subsets

Status: Completed

Note:
- The preview wiring is complete, and pressure-level tuning is intentionally deferred to a separate follow-up so we can evaluate the lower bound without reopening the byte-range plumbing.

Scope:
- Replace the preview provider's whole-pressure-file path with the byte-range pressure profile loader.
- Preserve the embedded `AnvilAnalyzeProfileRequest` payload shape in the preview response.
- Expand debug metadata with selected message/range diagnostics and subset-cache hit/miss state.

Files changed:
- `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`
- `Sources/App/StormSetup/HrrrPressureProfileLoading.swift`
- `Sources/App/Models/API/AnvilAnalyzeProfilePreviewResponse.swift`
- `Tests/AppTests/AnvilProfilePreviewProviderTests.swift`
- `Tests/AppTests/AnvilProfilePreviewControllerTests.swift`
- `Tests/AppTests/AnvilProfilePreviewTestSupport.swift`
- `Tests/AppTests/HrrrPressureProfileLoadingTests.swift`

Tests and commands run:
- `swift build --target App`
- `swift test --filter HrrrPressureProfileLoadingTests` (blocked by the existing package link failure involving `VaporAPNS` and `SwiftUICore`)
- `swift test --filter AnvilProfilePreviewProviderTests` (blocked by the same package link failure)

Local verification notes:
- The app target compiles cleanly with the new loader seam and preview wiring.
- The preview response still returns the embedded Anvil request payload unchanged, while debug now reports selected-message count, selected pressure levels, range count, total selected range bytes, and subset-cache hit/miss.
- The preview provider now resolves the HRRR pressure source, fetches and parses `.idx`, selects the five-level preview slice (`1000/925/850/700/500`), downloads byte-range subsets, samples with `wgrib2`, groups the pressure profile, and only then builds the preview request.
- Narrowing the preview slice reduced the selected byte-range set from the full pressure ladder to the smaller sounding profile that the preview request builder actually needs.
- Controlled unusable-profile failures now include missing/incomplete level diagnostics in the error text.
- The repository still has the pre-existing `VaporAPNS` / `SwiftUICore` link failure, so the new tests could not complete end-to-end in this environment.

Deferred scope:
- Arcus-Anvil HTTP dispatch and response DTO freezing.
- Ingredient evidence mapping for Anvil severe-weather output.
- Any surface API changes beyond the preview debug payload.

Handoff notes for `#103`:
- Freeze the current preview request shape as the compatibility baseline unless an Anvil contract constraint forces a minimal internal adjustment.
- Keep the preview debug fields additive if possible; do not backslide into surface-product output.
- Reuse the new byte-range loader seam when reconciling request/response contract tests so the preview path stays offline and deterministic.

### Issue #103 - 05: Reconcile and freeze the Anvil request/response contract

Status: Completed

Scope:
- Confirm whether Anvil needs surface fields beyond the current profile DTO.
- Add response DTOs for SCP/STP/SHIP and diagnostics.
- Keep request and response contract tests fixture-backed.

Decision:
- The request stays profile-only, but the `profile` field is a nested object of parallel arrays rather than a list of level objects.
- The response contract now carries the nested analysis payload with `effectiveLayer`, `stormMotion`, scalar instability/shear fields, and a `quality` object with profile count and warnings.

Deferred:
- Live Anvil calls.
- Ingredient interpretation.

Files changed:
- `Sources/App/Models/API/AnvilAnalyzeProfileResponse.swift`
- `Tests/AppTests/Fixtures/AnvilAnalyzeProfileResponse.json`
- `Tests/AppTests/AnvilAnalyzeProfileResponseDTOTests.swift`

Tests and commands run:
- `swift build --target App`
- `swift test --filter AnvilAnalyzeProfileResponseDTOTests` (blocked by the pre-existing package link failure involving `VaporAPNS` and `SwiftUICore`)
- `swift test --filter AnvilAnalyzeProfileDTOTests` (blocked by the same pre-existing package link failure)
- `HOME=/private/tmp SWIFT_MODULE_CACHE_PATH=/private/tmp/clang-cache xcrun swiftc /Users/justin/Code/arcus-signal/Sources/App/Models/API/AnvilAnalyzeProfileRequest.swift /private/tmp/anvil_request_check.swift -o /private/tmp/anvil_request_check && /private/tmp/anvil_request_check`
- `HOME=/private/tmp SWIFT_MODULE_CACHE_PATH=/private/tmp/clang-cache xcrun swiftc /Users/justin/Code/arcus-signal/Sources/App/Models/API/AnvilAnalyzeProfileResponse.swift /private/tmp/anvil_response_check.swift -o /private/tmp/anvil_response_check && /private/tmp/anvil_response_check`

Local verification notes:
- `swift build --target App` completed successfully, which compiled the new Anvil response DTO without touching the existing package link problem.
- The package-level test invocations still fail at link time for the existing `VaporAPNS` / `SwiftUICore` issue, so the DTO suites could not execute inside `swift test` here.
- Direct compile-and-run checks against the frozen request and response DTO source files passed and confirmed:
  - the request fixture still round-trips exactly with the current profile-only payload shape
  - the response fixture decodes and re-encodes exactly
  - missing scalar analysis fields decode to `nil`
  - nested `effectiveLayer`, `stormMotion`, and `quality` fields decode with the expected required shape

Surface-field dependency and unit expectations:
- No extra surface-field dependency was identified for the frozen request contract.
- Existing request units remain unchanged: temperatures in Celsius, wind components in meters per second, and height in meters MSL.

Deferred scope:
- Anvil HTTP transport.
- Ingredient interpretation.
- Live Anvil calls.
- Surface HRRR flow refactors.
- SHARPpy inside Signal.

Handoff notes for `#101`:
- Decode the frozen `AnvilAnalyzeProfileResponse` directly in the future client.
- Treat missing scalar analysis fields as absent evidence, not as zeros.
- Preserve nested `effectiveLayer`, `stormMotion`, and `quality` status so the client can distinguish degraded analysis from outright transport failure.

### Issue #101 - 06: Add Arcus-Anvil HTTP client for profile analysis

Status: Completed

Scope:
- Add a small injected Anvil client.
- Send `AnvilAnalyzeProfileRequest`.
- Decode the frozen response DTO.
- Keep tests mocked.

Deferred:
- Scheduler/background refresh design.
- App-facing fields.

Files changed:
- `Sources/App/Infrastructure/Networking/HTTPDataDownloader.swift`
- `Sources/App/StormSetup/AnvilProfileClient.swift`
- `Sources/App/StormSetup/StormSetupConfiguration.swift`
- `Tests/AppTests/AnvilProfileClientTests.swift`
- `Tests/AppTests/HrrrPressureByteRangeDownloaderTests.swift`
- `Tests/AppTests/HrrrPressureProfileLoadingTests.swift`
- `Tests/AppTests/HrrrPressureSubsetGribCacheTests.swift`
- `Tests/AppTests/StormSetupConfigurationTests.swift`
- `Tests/AppTests/StormSetupGribSubsetCacheTests.swift`

Tests and commands run:
- `swift test --filter AnvilProfileClientTests` (blocked by the pre-existing package link failure involving `VaporAPNS` and `SwiftUICore`)
- `swift build --target App`

Local verification notes:
- The App target compiles successfully with the new Anvil client and Storm Setup configuration fields.
- The client encodes the frozen request body as JSON with the nested `profile` object, posts it to the configured analysis endpoint, and decodes the frozen response DTO.
- Missing configuration fails in the configuration factory before any request is issued.
- Transport failures and timeouts are mapped separately from HTTP status failures and decoding failures.
- The filtered test command still dies at the repository’s existing `VaporAPNS` / `SwiftUICore` link issue, so the new tests could not execute in this environment.
- The preview pressure subset cache limit is now 30 MB, which is the limit that gates the 8-level lower-troposphere preview slice.
- Preview debug metadata now sources `pressureLevelsRequested` and `missingLevels` from the actual selector result so the preview output reflects the requested slice rather than the canonical preferred ladder.

Configuration keys added:
- `ANVIL_PROFILE_ANALYSIS_BASE_URL`
- `ANVIL_PROFILE_ANALYSIS_TIMEOUT_SECONDS`

Error model summary:
- `AnvilProfileClientError.missingConfiguration`
- `AnvilProfileClientError.transportFailure`
- `AnvilProfileClientError.requestTimedOut`
- `AnvilProfileClientError.unexpectedHTTPStatus`
- `AnvilProfileClientError.malformedResponseJSON`

Deferred scope:
- Scheduler/background refresh design.
- App-facing fields.
- Preview endpoint Anvil dispatch.
- Ingredient interpretation mapping.

Handoff notes for `#102`:
- Consume `AnvilAnalyzeProfileResponse` directly from the new client rather than re-decoding in downstream logic.
- Treat missing `scp`, `stp`, and `ship` as absent evidence, not synthesized zero values.
- Reuse the new client seam for mock-driven tests; do not wire live Anvil calls into the preview endpoint here.

### Follow-up - Dev analysis endpoint

Status: Completed

Scope:
- Wire a dev-only endpoint that reuses the pressure-profile preview pipeline, posts the frozen request to Anvil, and returns the decoded response for inspection.

Files changed:
- `Sources/App/Controllers/AnvilProfileAnalysisController.swift`
- `Sources/App/Models/API/AnvilAnalyzeProfileAnalysisResponse.swift`
- `Sources/App/StormSetup/AnvilProfileAnalysisProvider.swift`
- `Sources/App/apiRoutes.swift`
- `Tests/AppTests/AnvilProfileAnalysisControllerTests.swift`
- `Tests/AppTests/AnvilProfileAnalysisProviderTests.swift`

Tests and commands run:
- `swift build --target App`
- `swift test --filter AnvilProfileAnalysis` (blocked by the pre-existing package link failure involving `VaporAPNS` and `SwiftUICore`)

Local verification notes:
- The new endpoint is dev-only and lives under `/api/v1/dev/anvil/profile-analysis`.
- The provider reuses the frozen preview request, then sends that request through the injected Anvil client and returns the decoded response.
- The route returns a wrapper with the request, preview debug metadata, and the decoded Anvil response so the pipeline is inspectable end to end.

Deferred scope:
- Live Anvil use in the preview endpoint.
- UI work.
- Ingredient interpretation mapping.

### Issue #102 - 07: Map Anvil severe-weather output into ingredient evidence

Status: Completed

Scope:
- Convert Anvil SCP/STP/SHIP output into internal ingredient evidence.
- Feed evidence into the existing interpreter as support/confidence context.
- Avoid raw-number product copy.

Files changed:
- `Sources/App/StormSetup/AnvilIngredientEvidence.swift`
- `Sources/App/StormSetup/TornadoIngredientAssessment.swift`
- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Sources/App/StormSetup/StormSetupModels.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Tests/AppTests/AnvilIngredientEvidenceTests.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`
- `Tests/AppTests/StormSetupControllerTests.swift`
- `Tests/AppTests/StormSetupProviderTests.swift`
- `docs/plans/hrrr-pressure-profile-progress.md`

Tests and commands run:
- `swift build --target App`
- `swift test --filter AnvilIngredientEvidenceTests` (blocked by the pre-existing package link failure involving `VaporAPNS` and `SwiftUICore`)
- `swift test --filter TornadoIngredientInterpreterTests` (blocked by the same pre-existing package link failure)
- `swift test --filter StormSetupControllerTests` (blocked by the same pre-existing package link failure)
- `swift test --filter StormSetupProviderTests/providerAugmentsSnapshotWithAnvilEvidence` (blocked by the same pre-existing package link failure)
- `swift test --filter StormSetupProviderTests/providerMarksAssessmentDegradedWhenAnvilEvidenceIsUnavailable` (blocked by the same pre-existing package link failure)

Local verification result:
- The App target compiles cleanly with the new internal Anvil evidence seam and Storm Setup response plumbing.
- Package-level test execution is still blocked by the repository’s existing `VaporAPNS` / `SwiftUICore` link failure, so the filtered test suites could not complete in this environment.

Evidence model summary:
- `AnvilIngredientEvidence` now maps the frozen Anvil response into stable internal evidence for `scp`, `stp`, and `ship`.
- The mapper converts the response diagnostics into internal health flags plus quality metadata, and treats low profile counts, missing severe-weather values, or warnings as degraded evidence.
- The snapshot now carries an optional `anvilEvidence` debug block so the Storm Setup endpoint can surface the same internal evidence that fed the assessment.
- Raw severe-weather numbers stay internal to the evidence layer and are not surfaced as product copy.

Interpreter behavior summary:
- `TornadoIngredientInterpreter` now accepts optional Anvil evidence through a narrow overload.
- Healthy evidence can lift support or confidence by one conservative step when the raw setup is already near the threshold.
- Weak, degraded, or unavailable evidence can lower confidence, and summary text now explicitly reports when Anvil is unavailable or degraded.
- The production Storm Setup provider now resolves Anvil analysis, maps it into evidence, and passes that into the interpreter while also including the evidence block in the snapshot response.

Deferred:
- UI work.
- New prediction language.
- Live Anvil calls.

Handoff notes for `#100`:
- Record the exact compile and test outcomes above, including the existing link failure, rather than implying the test suite fully passes.
- Keep the docs focused on the internal evidence seam, the conservative interpreter adjustment, and the new debug visibility on the Storm Setup response.
- The remaining ledger work should only reconcile status and verification text; no new behavior is expected from the final docs pass.

### Issue #100 - 08: Finalize HRRR pressure-profile docs and verification ledger

Status: Completed

Scope:
- Update internal docs after implementation.
- Reconcile old pressure/full-file issue notes.
- Record final verification commands and known deferred risks.

Files changed:
- `docs/plans/hrrr-pressure-profile-progress.md`
- `docs/hrrr-pressure-profile.md`
- `docs/superpowers/plans/2026-06-19-hrrr-pressure-level-support.md`

Tests and commands run:
- `swift build --target App` (passed)
- `swift test --filter HrrrPressure` (failed with 12 issues across the pressure-profile suites, including downloader, selector, cache, and loading tests)
- `swift test --filter StormSetup` (failed with 7 issues across the Storm Setup suites, including pressure grouping, pressure source selection, and pressure cache tests)

Local verification notes:
- `swift build --target App` completed successfully.
- `swift test --filter HrrrPressure` and `swift test --filter StormSetup` both completed enough of the suite to report concrete test failures rather than a package-link failure.
- The pressure-profile failures were concentrated in downloader, selector, cache, and loading coverage.
- The Storm Setup failures were concentrated in pressure-profile grouping and pressure-source selection coverage.
- The documentation updates were reconciled against the completed implementation trail in issues `#91`, `#99`, `#98`, `#92`, `#103`, `#101`, and `#102`.
- The final docs now describe the byte-range `.idx` path as the current pressure-profile behavior and keep Anvil scoped to ingredient evidence rather than prediction.

Skipped validation:
- Direct GitHub issue body retrieval for `#100` was unavailable because `gh issue view` could not connect to `api.github.com` from this environment.
- No runtime behavior was changed, so no code-level verification beyond the existing pressure-profile and Storm Setup test commands was required.

Deferred work:
- No new feature work remains from the pressure-profile epic.
- Live network verification against HRRR or Anvil remains environment-dependent and was not part of this final docs pass.

Handoff outcome:
- The pressure-profile epic is complete and the progress ledger is now the durable handoff record.
- Future maintenance should treat `docs/hrrr-pressure-profile.md` and this progress log as the current reference, and the historical pressure-level plan as superseded.

### Issue #124 - 09: Add a pure Anvil surface-profile normalization seam

Status: Completed

Scope:
- Introduce a pure normalizer for `AnvilAnalyzeProfileResponse` to `AnvilIngredientEvidence`.
- Keep the existing support-band thresholds, degraded-state rules, and missing-value handling unchanged.
- Add focused tests for the normalization seam.

Files changed:
- `Sources/App/StormSetup/AnvilSurfaceProfileNormalizer.swift`
- `Sources/App/StormSetup/AnvilIngredientEvidence.swift`
- `Tests/AppTests/AnvilSurfaceProfileNormalizerTests.swift`
- `docs/plans/hrrr-pressure-profile-progress.md`

Tests and commands run:
- `swift test --filter AnvilSurfaceProfileNormalizerTests`
- `swift test --filter StormSetupHrrrSourceTests`
- `swift build -Xswiftc -strict-concurrency=complete`
- `git diff --check`

Local verification notes:
- The normalization path remains pure and deterministic.
- Existing surface and pressure defaults were left unchanged.
- No networking, provider wiring, or `TornadoIngredientNormalizer` changes were introduced.

Deferred scope:
- Any future tuning of Anvil evidence thresholds or semantics.
- Networking, transport, and provider wiring remain out of scope for this slice.

### Issue #125 - 10: Add a pure Anvil surface-profile loading seam

Status: Completed

Scope:
- Add a narrow loader that builds one matching `wrfsfc` candidate from the current surface-cycle resolution.
- Reuse the existing subset-loading and field-sampling seams.
- Preserve cancellation and avoid fallback to another cycle.

Files changed:
- `Sources/App/StormSetup/HrrrAnvilSurfaceProfileLoading.swift`
- `Tests/AppTests/HrrrAnvilSurfaceProfileLoadingTests.swift`
- `docs/plans/hrrr-pressure-profile-progress.md`

Tests and commands run:
- `swift test --filter HrrrAnvilSurfaceProfileLoadingTests`
- `swift build -Xswiftc -strict-concurrency=complete`
- `git diff --check`

Local verification notes:
- The loader now constructs a single `wrfsfc` candidate and passes exactly one resolution into the subset loader.
- Cancellation short-circuits the load path before any second cycle or sampler work can run.
- The new tests stay offline and deterministic; they only use local stubs and fixture samples.

Deferred scope:
- Wiring the surface-profile loader into any provider or controller.
- Any Anvil contract or response changes beyond the loader seam itself.

Handoff notes for `#126`:
- Reuse the new surface loader instead of rebuilding the `wrfsfc` candidate logic again.
- Keep any provider wiring pointed at the injected subset/cache/sampler seams so the offline tests remain deterministic.

### Issue #126 - 11: Prepend the explicit Anvil surface row without changing the DTO

Status: Completed

Scope:
- Extend the frozen Anvil profile-request builder with an optional explicit surface row.
- Prepend the surface row without interpolation while preserving the existing request DTO shape.
- Keep the five retained pressure-level minimum independent of the surface row.
- Reject invalid pressure ordering instead of sorting the profile rows into a valid-looking sequence.

Files changed:
- `Sources/App/StormSetup/AnvilProfileRequestBuilder.swift`
- `Tests/AppTests/AnvilProfileRequestBuilderTests.swift`
- `docs/plans/hrrr-pressure-profile-progress.md`

Tests and commands run:
- `swift test --filter AnvilProfileRequestBuilderTests`
- `swift build -Xswiftc -strict-concurrency=complete`
- `git diff --check`

Local verification notes:
- The builder now accepts an optional `surfaceLevel` seam and prepends it directly to the frozen profile arrays.
- The request DTO remains unchanged, so downstream consumers still see the same nested `profile` shape.
- The retained pressure-level minimum is still enforced before the surface row is attached.
- Invalid pressure ordering now fails fast instead of being normalized by sorting.

Deferred scope:
- Provider/controller wiring for the new surface-row seam.
- Any follow-on issue that consumes the seam from the preview or analysis paths.

Handoff notes for `#127`:
- Thread the new surface row through the provider layer instead of reconstructing the request assembly rules again.
- Preserve the builder’s explicit ordering rules so downstream wiring does not reintroduce silent sorting.

---

## Final Completion Summary

- Epic `#85` is complete.
- Follow-on surface-profile seams `#124` and `#125` are complete.
- Follow-on Anvil request-builder seam `#126` is complete.
- Sub-issues `#91`, `#99`, `#98`, `#92`, `#103`, `#101`, `#102`, and `#100` are all complete.
- The completed implementation path is byte-range `.idx` selection, partial-content pressure subset download, preview wiring, Anvil profile transport, ingredient-evidence mapping, and the explicit Anvil surface-row builder seam.
- The #126 verification record is `swift test --filter AnvilProfileRequestBuilderTests`, `swift build -Xswiftc -strict-concurrency=complete`, and `git diff --check` all passing.
- Known remaining risks are environmental only:
  - the filtered test suites still have outstanding failures in the current working tree or fixtures
  - live HRRR, NOMADS, and Anvil verification was not part of this docs-only finalization pass
- Deferred work from the epic is intentionally closed out; no new runtime behavior was added in this documentation pass.
