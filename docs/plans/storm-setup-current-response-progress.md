# Storm Setup Current Response Progress Log

## Overview

Storm Setup Current Response consolidates the production `GET /api/v1/storm-setup/current` contract so one call returns setup data, surface-derived ingredient values, Anvil profile-analysis result, and interpreted tornado ingredient assessment.

Implementation should proceed one issue at a time, following `docs/plans/storm-setup-current-response-runbook.md`.

Epic status:
- Active

Primary GitHub epic:
- `#133` - https://github.com/justinrooks/arcus-signal/issues/133

Related local docs:
- `AGENTS.md`
- `docs/architecture.md`
- `docs/epics-stories.md`
- `docs/plans/storm-setup-current-response-runbook.md`
- `docs/plans/storm-setup-issue-runbook.md`
- `docs/plans/storm-setup-progress.md`
- `docs/plans/hrrr-pressure-profile-runbook.md`
- `docs/plans/hrrr-pressure-profile-progress.md`

---

## Global Decisions

- Keep `api/v1/storm-setup/current` as the production endpoint.
- The existing storm setup and Anvil/profile pipelines are already fused at execution time.
- This epic changes response contract clarity, not orchestration.
- Prefer composed response sections over a flattened mega-object.
- Production response should expose `AnvilAnalyzeProfileResponse`.
- Production response should not expose `AnvilAnalyzeProfileRequest` or `AnvilAnalyzeProfilePreviewDebugDTO`.
- Keep request/profile-preview debug data on `api/v1/dev/anvil/profile-analysis`.
- Avoid duplicate Anvil calls.
- Preserve `TornadoIngredientInterpreter` as the only source of truth for assessment logic.
- Preserve `AnvilIngredientEvidence` as the interpretation/evidence summary, even when raw profile analysis is also returned.
- Keep Anvil/profile data optional in the production response when unavailable or rejected.
- Do not remove the dev Anvil profile-analysis endpoint until the production response is verified and the app migration path is clear.

---

## Current State Summary

Production endpoint:
- `GET /api/v1/storm-setup/current?h3=<cell>`
- Defined in `Sources/App/Controllers/StormSetupController.swift`
- Currently returns `TornadoIngredientSnapshot` directly.

Dev diagnostics endpoint:
- `GET /api/v1/dev/anvil/profile-analysis?h3=<cell>`
- Defined in `Sources/App/Controllers/AnvilProfileAnalysisController.swift`
- Debug-gated and production-blocked.
- Returns `AnvilAnalyzeProfileAnalysisResponse`.

Current storm setup flow:
- Resolves H3 to centroid.
- Loads cached surface snapshot or samples HRRR surface fields.
- Normalizes surface values into `TornadoRawParameters`.
- Builds a surface `TornadoIngredientSnapshot`.
- Calls Anvil/profile analysis through `AnvilProfileAnalysisProviding`.
- Converts `AnvilAnalyzeProfileResponse` into `AnvilIngredientEvidence`.
- Re-runs `TornadoIngredientInterpreter` with the evidence.
- Returns `TornadoIngredientSnapshot` with `anvilEvidence` and adjusted `assessment`.

Contract gap:
- The full `AnvilAnalyzeProfileResponse` is available inside `StormSetupProvider`.
- It is summarized into `AnvilIngredientEvidence` before the production response is returned.
- The production endpoint currently does not expose the raw Anvil profile-analysis values needed by detailed app views.

---

## Issue Sequence

Work these issues sequentially:

1. `#134` - 01: Add composed Storm Setup current response DTO
2. `#135` - 02: Populate composed response from existing Storm Setup flow
3. `#136` - 03: Add production Storm Setup current response contract tests
4. `#137` - 04: Prepare app-facing Storm Setup current response contract docs
5. `#138` - 05: Decide dev Anvil profile-analysis endpoint lifecycle

---

## Existing Code Map

Relevant source:
- `Sources/App/Controllers/StormSetupController.swift`
- `Sources/App/Controllers/AnvilProfileAnalysisController.swift`
- `Sources/App/StormSetup/StormSetupModels.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Sources/App/StormSetup/AnvilIngredientEvidence.swift`
- `Sources/App/StormSetup/TornadoIngredientAssessment.swift`
- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Sources/App/Models/API/AnvilAnalyzeProfileResponse.swift`
- `Sources/App/Models/API/AnvilAnalyzeProfileAnalysisResponse.swift`
- `Sources/App/Models/API/AnvilAnalyzeProfileRequest.swift`
- `Sources/App/Models/API/AnvilAnalyzeProfilePreviewResponse.swift`

Relevant tests:
- `Tests/AppTests/StormSetupControllerTests.swift`
- `Tests/AppTests/StormSetupProviderTests.swift`
- `Tests/AppTests/AnvilAnalyzeProfileResponseDTOTests.swift`
- `Tests/AppTests/AnvilProfileAnalysisControllerTests.swift`
- `Tests/AppTests/AnvilIngredientEvidenceTests.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`

---

## Investigation Notes

- `StormSetupController.current(req:)` currently returns `TornadoIngredientSnapshot`.
- `TornadoIngredientSnapshot` includes setup metadata, `raw`, `assessment`, `freshness`, and optional `anvilEvidence`.
- `DefaultStormSetupProvider.resolveAnvilEvidence` receives `AnvilAnalyzeProfileAnalysisResponse` from `anvilProfileAnalysisProvider.analyzeProfile(for:)`.
- `resolveAnvilEvidence` currently keeps timing/debug metadata only long enough to decide exact, stale, or unavailable evidence.
- `AnvilIngredientEvidence(response:)` maps raw Anvil values into support bands and diagnostics.
- `composeSnapshotWithCurrentAnvilEvidence` re-runs the interpreter with summarized evidence and returns a new `TornadoIngredientSnapshot`.
- The sampled snapshot cache stores a surface-only snapshot and recomputes current Anvil evidence on each response. Preserve that design.

---

## Status Ledger

### Issue #134 - 01: Add composed Storm Setup current response DTO

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/134

Status: Complete

Scope:
- Define the production composed response DTO.
- Keep the response sections explicit.
- Do not switch the route yet unless the issue explicitly says so.

Deferred:
- Provider population.
- Controller contract switch.
- Dev endpoint changes.

Files changed:
- `Sources/App/StormSetup/StormSetupCurrentResponse.swift`
- `Tests/AppTests/StormSetupCurrentResponseDTOTests.swift`

Tests / commands run:
- `swift test --filter StormSetupCurrentResponseDTOTests`

Local verification notes:
- The new DTO encodes the explicit top-level sections: `setup`, `ingredients`, `profileAnalysis`, and `assessment`.
- `profileAnalysis` round-trips as `AnvilAnalyzeProfileResponse?`.
- The production route still returns `TornadoIngredientSnapshot`; no controller behavior changed.

Deferred scope:
- Populate the new response from the existing Storm Setup flow.
- Switch `StormSetupController.current` to return `StormSetupCurrentResponse`.
- Touch the dev Anvil profile-analysis endpoint.

Handoff notes for #135:
- Reuse `StormSetupCurrentResponse` and `StormSetupCurrentSetupResponse`.
- Map the existing `TornadoIngredientSnapshot` into the new `setup` and `ingredients` sections without adding a second Anvil call.
- Preserve current provider behavior and assessment logic.

### Issue #135 - 02: Populate composed response from existing Storm Setup flow

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/135

Status: Complete

Scope:
- Preserve `AnvilAnalyzeProfileResponse` through the existing provider flow.
- Build the composed response without duplicate Anvil calls.
- Preserve assessment behavior.

Deferred:
- Dev endpoint deprecation/removal.
- iOS implementation.

Files changed:
- `Sources/App/Controllers/StormSetupController.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Tests/AppTests/StormSetupControllerTests.swift`
- `Tests/AppTests/StormSetupProviderTests.swift`

Tests / commands run:
- `swift test --filter StormSetupProviderTests`
- `swift test --filter StormSetupControllerTests`

Local verification notes:
- `GET /api/v1/storm-setup/current` now returns `StormSetupCurrentResponse` with explicit `setup`, `ingredients`, `profileAnalysis`, and `assessment` sections.
- The provider threads the existing Anvil analysis response through the same execution path and exposes it only for usable exact analysis results.
- The legacy surface snapshot path still returns surface-only data when Anvil is not configured.

Deferred scope:
- Dev endpoint lifecycle changes for `api/v1/dev/anvil/profile-analysis`.
- Any iOS-side contract migration work.

Handoff notes for #136:
- Add contract coverage for the production composed response payload shape and nil `profileAnalysis` paths that remain usable without Anvil.
- Keep the verification focused on the production endpoint only; do not broaden into dev endpoint behavior.

### Issue #136 - 03: Add production Storm Setup current response contract tests

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/136

Status: Complete

Scope:
- Add focused tests proving the production response returns all required sections together.
- Cover Anvil available and unavailable/rejected paths.

Deferred:
- Live HRRR or live Anvil verification.

Files changed:
- `Tests/AppTests/StormSetupControllerTests.swift`
- `Tests/AppTests/StormSetupProviderTests.swift`
- `Tests/AppTests/StormSetupCurrentResponseDTOTests.swift`
- `docs/plans/storm-setup-current-response-progress.md`

Tests / commands run:
- `swift test --filter StormSetupCurrentResponseDTOTests`
- `swift test --filter StormSetupControllerTests`
- `swift test --filter StormSetupProviderTests`

Local verification notes:
- The production route test now pins the full composed response contract, including exact `AnvilAnalyzeProfileResponse` values in `profileAnalysis`.
- The provider test proves the composed response still comes from a single Anvil analysis call.
- The DTO test now asserts the encoded production `profileAnalysis` section only contains response fields and does not expose dev-only request or debug payloads.

Deferred scope:
- App-facing contract docs and migration notes for issue `#137`.
- Any dev endpoint lifecycle changes for `api/v1/dev/anvil/profile-analysis`.

Handoff notes for `#137`:
- Use the new tests as the canonical production contract reference.
- `StormSetupCurrentResponse.profileAnalysis` should be treated as the app-facing payload, while `AnvilAnalyzeProfileRequest` and `AnvilAnalyzeProfilePreviewDebugDTO` remain dev-only.
- Do not expand the migration doc slice beyond contract documentation.

### Issue #137 - 04: Prepare app-facing Storm Setup current response contract docs

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/137

Status: Complete

Scope:
- Add a compact fixture or contract note for the iOS migration.
- Clarify that production returns `AnvilAnalyzeProfileResponse`, not the dev request/debug envelope.

App-facing contract note:

- Production `GET /api/v1/storm-setup/current?h3=<cell>` returns `StormSetupCurrentResponse`.
- Response shape:
  - `setup`: `StormSetupCurrentSetupResponse`
  - `ingredients`: `TornadoRawParameters`
  - `profileAnalysis`: `AnvilAnalyzeProfileResponse?`
  - `assessment`: `TornadoIngredientAssessment`
- Intended app mapping:
  - summary UI from `assessment`
  - surface detail UI from `ingredients`
  - profile detail UI from `profileAnalysis`
  - setup/source metadata from `setup`
- `AnvilAnalyzeProfileRequest` and `AnvilAnalyzeProfilePreviewDebugDTO` remain dev-only on `GET /api/v1/dev/anvil/profile-analysis`.

Files changed:
- `docs/plans/storm-setup-current-response-progress.md`

Tests / commands run:
- `rg -n "AnvilAnalyzeProfileRequest|AnvilAnalyzeProfilePreviewDebugDTO" docs/plans/storm-setup-current-response*`

Local verification notes:
- The new contract note keeps the production response explicit and app-facing.
- The remaining request/debug DTO references in the storm-setup-current docs are either dev-only or point at the dev endpoint.

Deferred scope:
- Editing the SkyAware app.
- Adding a fixture, since the existing contract tests already pin the payload shape.

Handoff notes for `#138`:
- Do not change the dev Anvil endpoint lifecycle in this slice.
- Keep the production response note as the app-facing contract reference until the lifecycle decision is made separately.

### Issue #138 - 05: Decide dev Anvil profile-analysis endpoint lifecycle

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/138

Status: Not started

Scope:
- Decide endpoint fate only after the production response is verified.
- Keep diagnostics if still useful; otherwise deprecate or remove in a separate reviewable slice.

Deferred:
- Any dev endpoint change before production contract verification.

---

## Verification Ledger

No implementation verification has been run for this epic yet.

---

## Handoff Notes

- Keep the first implementation slice small. DTO first, behavior second.
- Do not accidentally expose `AnvilAnalyzeProfileRequest` or `AnvilAnalyzeProfilePreviewDebugDTO` from production.
- If the exact `setup` section type is unclear, prefer a transitional DTO and document the choice before widening scope.
- Any breaking change to the top-level `storm-setup/current` JSON shape must be called out explicitly in the issue and progress log.
