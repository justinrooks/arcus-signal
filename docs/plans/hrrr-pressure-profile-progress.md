# HRRR Pressure Profile Progress Log

## Overview

HRRR Pressure Profile adds byte-range pressure-level HRRR profile extraction and Arcus-Anvil ingredient evidence to Arcus Signal.

Implementation should proceed one issue at a time, following `docs/plans/hrrr-pressure-profile-runbook.md`.

Primary GitHub epic:
- `#85` - https://github.com/justinrooks/arcus-signal/issues/85

Related local docs:
- `AGENTS.md`
- `docs/architecture.md`
- `docs/epics-stories.md`
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
- Whole-file pressure GRIB download may remain as transitional/debug fallback only when explicitly scoped.
- Do not introduce Zarr, BUFKit, SHARPpy inside Signal, or a broad data-platform layer.
- Do not move HRRR fetching into Arcus-Anvil.
- Use existing `wgrib2` execution and point-sampling plumbing.
- Use existing pressure grouping and Anvil request-builder seams where possible.
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
- Whole-file pressure raw cache exists.
- Pressure-profile grouping exists.
- Frozen Anvil request DTO and preview endpoint exist.
- Ingredient interpreter already has nullable composite slots, but they are currently unpopulated.

Missing:
- `.idx` inventory parser.
- Pressure message selector from `.idx`.
- Byte-range planner.
- HTTP range downloader with `206 Partial Content` validation.
- Partial GRIB concatenation/cache.
- Preview wiring through byte-range subsets.
- Anvil response DTOs and HTTP client.
- SCP/STP/SHIP evidence mapping into ingredient interpretation.

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
- `Sources/App/StormSetup/StormSetupPressureGribCache.swift`
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
- `Tests/AppTests/StormSetupPressureGribCacheTests.swift`
- `Tests/AppTests/StormSetupPressureProfileGroupingTests.swift`
- `Tests/AppTests/AnvilAnalyzeProfileDTOTests.swift`
- `Tests/AppTests/AnvilProfileRequestBuilderTests.swift`
- `Tests/AppTests/AnvilProfilePreviewProviderTests.swift`
- `Tests/AppTests/AnvilProfilePreviewControllerTests.swift`

---

## Investigation Notes

- `HrrrPressureDirectObjectResolver` currently builds `.idx` URLs and probes them for availability, but does not parse inventory content.
- `StormSetupPressureGribCache` currently performs whole-object `GET` and stores a full raw pressure GRIB.
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

Status: Planned

Scope:
- Replace preview's whole-pressure-file loader with the byte-range subset loader.
- Keep preview response request shape stable.
- Add debug metadata for selected messages/ranges.

Deferred:
- Anvil HTTP dispatch.
- User-facing product API changes.

### Issue #103 - 05: Reconcile and freeze the Anvil request/response contract

Status: Planned

Scope:
- Confirm whether Anvil needs surface fields beyond the current profile DTO.
- Add response DTOs for SCP/STP/SHIP and diagnostics.
- Keep request and response contract tests fixture-backed.

Deferred:
- Live Anvil calls.
- Ingredient interpretation.

### Issue #101 - 06: Add Arcus-Anvil HTTP client for profile analysis

Status: Planned

Scope:
- Add a small injected Anvil client.
- Send `AnvilAnalyzeProfileRequest`.
- Decode the frozen response DTO.
- Keep tests mocked.

Deferred:
- Scheduler/background refresh design.
- App-facing fields.

### Issue #102 - 07: Map Anvil severe-weather output into ingredient evidence

Status: Planned

Scope:
- Convert Anvil SCP/STP/SHIP output into internal ingredient evidence.
- Feed evidence into the existing interpreter as support/confidence context.
- Avoid raw-number product copy.

Deferred:
- UI work.
- New prediction language.

### Issue #100 - 08: Finalize HRRR pressure-profile docs and verification ledger

Status: Planned

Scope:
- Update internal docs after implementation.
- Reconcile old pressure/full-file issue notes.
- Record final verification commands and known deferred risks.

Deferred:
- Any new feature behavior.
