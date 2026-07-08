# Tornado Viability Current Response Progress Log

## Overview

This epic replaces the top-level `assessment` object on `GET /api/v1/storm-setup/current` with a localized tornado formation viability report.

Implementation should proceed one issue at a time, following `docs/plans/tornado-viability-current-response-runbook.md`.

Epic status:
- Active

Primary GitHub epic:
- `#139` - https://github.com/justinrooks/arcus-signal/issues/139

Related local docs:
- `AGENTS.md`
- `docs/architecture.md`
- `docs/epics-stories.md`
- `docs/plans/tornado-viability-interpreter-redesign.md`
- `docs/plans/tornado-viability-current-response-runbook.md`
- `docs/plans/storm-setup-current-response-runbook.md`
- `docs/plans/storm-setup-current-response-progress.md`

---

## Global Decisions

- Use `GET /api/v1/storm-setup/current` as the delivery surface.
- Replace top-level `assessment` with top-level `tornadoViability`.
- Treat this as an intentional production response-contract change.
- Keep `setup`, `ingredients`, and `profileAnalysis` top-level response sections.
- Preserve signed `Int64` H3 input.
- Do not create a separate tornado viability endpoint in this epic.
- Keep raw/canonical/profile SHIP fields available.
- Do not use SHIP in tornado viability calculation, confidence adjustment, limiter selection, or summary text.
- Keep Anvil/profile-derived values canonical for sounding-derived ingredients when available.
- Keep surface/2D GRIB values as diagnostics, context, and fallback.
- Preserve existing Storm Setup orchestration and cache behavior.
- Avoid duplicate Anvil calls.
- Use calm environmental viability language, not tornado prediction/risk/probability framing.

---

## Current State Summary

Production endpoint:
- `GET /api/v1/storm-setup/current?h3=<signed-int64-cell>`
- Defined in `Sources/App/Controllers/StormSetupController.swift`
- Returns `StormSetupCurrentResponse`.

Current response sections:
- `setup`
- `ingredients`
- `profileAnalysis`
- `tornadoViability`

Current interpretation:
- `TornadoIngredientInterpreter` returns `TornadoIngredientAssessment`.
- `lowLevelRotation` already blends SRH, 3CAPE, and cloud-base support.
- `compositeSignal` currently maxes SCP, fixed STP, and effective STP together.
- `AnvilIngredientEvidence.strongestSupport` can include SHIP, which is wrong for raising tornado viability.

Target response sections:
- `setup`
- `ingredients`
- `profileAnalysis`
- `tornadoViability`

Contract change:
- `assessment` is removed from the production current response.
- `tornadoViability` is the app-facing replacement.

---

## Issue Sequence

Work these issues sequentially:

1. `#140` - 01: Define tornado viability response contract
2. `#141` - 02: Split composite interpretation and exclude SHIP from viability math
3. `#142` - 03: Introduce internal tornado viability diagnosis
4. `#143` - 04: Improve failure modes and limiter precision
5. `#144` - 05: Rewrite tornado viability summaries
6. `#145` - 06: Expand matrix and contract tests
7. `#146` - 07: Document app-facing current response migration

---

## Existing Code Map

Relevant source:
- `Sources/App/Controllers/StormSetupController.swift`
- `Sources/App/StormSetup/StormSetupCurrentResponse.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Sources/App/StormSetup/StormSetupModels.swift`
- `Sources/App/StormSetup/TornadoIngredientAssessment.swift`
- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Sources/App/StormSetup/AnvilIngredientEvidence.swift`
- `Sources/App/Models/API/AnvilAnalyzeProfileResponse.swift`

Relevant tests:
- `Tests/AppTests/StormSetupCurrentResponseDTOTests.swift`
- `Tests/AppTests/StormSetupControllerTests.swift`
- `Tests/AppTests/StormSetupProviderTests.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`
- `Tests/AppTests/AnvilIngredientEvidenceTests.swift`

---

## Investigation Notes

- The existing provider already accepts any signed `Int64` H3 cell through `currentSnapshot(for:)`.
- The current controller already validates signed `Int64` H3 input.
- The current response already includes canonical and diagnostic ingredients.
- `profileAnalysis` exposes exact `AnvilAnalyzeProfileResponse` when Anvil evidence is accepted.
- `makeCanonicalIngredients` maps Anvil/profile values over diagnostics for sounding-derived fields.
- `TornadoRawParameters.significantHail` maps to Anvil `ship`.
- SHIP remains useful severe-weather context and must remain present in payloads.
- SHIP should not influence tornado viability.
- The current `compositeSignal` combines SCP and STP on a single max ladder, which conflates supercell support with tornado-specific support.
- The public `lowLevelRotation` concept is now too broad; internal diagnosis should split rotation, stretching, cloud-base efficiency, and tornado efficiency.
- Existing tests already cover 0-1 km SRH priority, 3CAPE limiting behavior, STP fixed/effective mismatch language, degraded Anvil evidence, and no Anvil double-counting.

---

## Status Ledger

### Issue #140 - 01: Define tornado viability response contract

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/140

Status: In Progress

Scope:
- Define `TornadoViabilityReport` and supporting response DTOs.
- Replace `StormSetupCurrentResponse.assessment` with `tornadoViability`.
- Populate the new report initially from existing `TornadoIngredientAssessment` behavior so the contract compiles before deeper interpreter redesign.

Deferred:
- Composite cleanup.
- Internal diagnosis model.
- Copy rewrite.

Files likely touched:
- `Sources/App/StormSetup/StormSetupCurrentResponse.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Tests/AppTests/StormSetupCurrentResponseDTOTests.swift`
- `Tests/AppTests/StormSetupProviderTests.swift`

Tests / commands:
- `swift test --filter StormSetupCurrentResponseDTOTests`
- `swift test --filter StormSetupProviderTests`

Handoff notes:
- This issue is intentionally contract-first.
- Do not preserve top-level `assessment` as a parallel property unless the issue is explicitly revised.
- The response contract now uses `tornadoViability`; the next slice should keep the provider interpretation untouched and build on this public DTO.
- `StormSetupCurrentResponseDTOTests` passed after the contract update.
- `StormSetupProviderTests` still needs one cache-hit assertion reconciled before I would call verification complete.

### Issue #141 - 02: Split composite interpretation and exclude SHIP from viability math

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/141

Status: Pending

Scope:
- Split SCP support from STP fixed/effective support.
- Stop maxing SCP and STP together.
- Ensure SHIP is retained as data but ignored by tornado viability calculations.

Deferred:
- Full internal diagnosis object.
- Summary rewrite beyond what tests require.

Files likely touched:
- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Sources/App/StormSetup/AnvilIngredientEvidence.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`
- `Tests/AppTests/AnvilIngredientEvidenceTests.swift`

Tests / commands:
- `swift test --filter TornadoIngredientInterpreterTests`
- `swift test --filter AnvilIngredientEvidenceTests`

Handoff notes:
- High SCP plus low STP should mean supercell support but limited tornado-specific signal.
- High fixed STP plus lower effective STP should mean conditional realization.

### Issue #142 - 03: Introduce internal tornado viability diagnosis

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/142

Status: Pending

Scope:
- Add internal diagnosis types for storm viability, supercell viability, low-level rotation, low-level stretching, cloud-base efficiency, tornado efficiency, inhibition, composites, realization, failure mode, and confidence.
- Map the diagnosis to `TornadoViabilityReport`.

Deferred:
- Public endpoint shape changes should already be done in issue 01.
- Avoid broad provider/controller refactors.

Files likely touched:
- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`

Tests / commands:
- `swift test --filter TornadoIngredientInterpreterTests`

Handoff notes:
- Keep diagnosis private/internal unless Swift visibility requires otherwise.
- Preserve `Content` DTOs separately from internal diagnosis types.

### Issue #143 - 04: Improve failure modes and limiter precision

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/143

Status: Pending

Scope:
- Distinguish weak SRH, weak 3CAPE, elevated cloud bases, strong cap, conditional initiation, weak storm organization, and STP disagreement.
- Map these into report limiters and primary failure mode.

Deferred:
- New data dependencies.
- Storm mode inference from reflectivity/UH/radar.

Files likely touched:
- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Sources/App/StormSetup/StormSetupCurrentResponse.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`

Tests / commands:
- `swift test --filter TornadoIngredientInterpreterTests`

Handoff notes:
- Existing `TornadoLimitingFactor` does not need to drive the new report.
- Prefer new viability-specific limiter enum for the new report.

### Issue #144 - 05: Rewrite tornado viability summaries

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/144

Status: Pending

Scope:
- Rewrite `tornadoViability.summary` around environmental capability vs realization.
- Keep raw values out of casual summary copy.
- Maintain prohibited-language tests.

Deferred:
- App UI rendering.
- Advanced raw-value drilldowns.

Files likely touched:
- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`

Tests / commands:
- `swift test --filter TornadoIngredientInterpreterTests`

Handoff notes:
- Use "tornado-capable storms" and "environment can support" phrasing.
- Avoid probability/risk/prediction wording.

### Issue #145 - 06: Expand matrix and contract tests

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/145

Status: Pending

Scope:
- Add focused tests for representative environments.
- Pin the new current-response contract.
- Verify Anvil-backed canonical values are not double-counted.

Deferred:
- Live weather verification.
- Full JSON snapshots unless needed for contract clarity.

Files likely touched:
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`
- `Tests/AppTests/StormSetupCurrentResponseDTOTests.swift`
- `Tests/AppTests/StormSetupProviderTests.swift`
- `Tests/AppTests/StormSetupControllerTests.swift`

Tests / commands:
- `swift test --filter TornadoIngredientInterpreterTests`
- `swift test --filter StormSetupCurrentResponseDTOTests`
- `swift test --filter StormSetupProviderTests`
- `swift test --filter StormSetupControllerTests`

Handoff notes:
- Keep tests deterministic and local.
- Include weak, supercell-supportive/tornado-limited, capped conditional, low-level efficient, strong supportive, missing-field fallback, degraded Anvil, and Anvil-backed canonical cases.

### Issue #146 - 07: Document app-facing current response migration

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/146

Status: Pending

Scope:
- Document the app-facing `storm-setup/current` response change.
- Call out removal of top-level `assessment` and replacement with `tornadoViability`.
- Clarify SHIP remains available as data but not part of tornado viability math.

Deferred:
- SkyAware iOS implementation.
- Separate endpoint documentation.

Files likely touched:
- `docs/plans/tornado-viability-current-response-progress.md`
- Optional: `docs/api-endpoints.md` if current Storm Setup response docs are already present there.

Tests / commands:
- `rg -n "assessment|tornadoViability|SHIP|significantHail" docs Sources/App/StormSetup Tests/AppTests`

Handoff notes:
- Keep docs concise and app-consumable.
- Do not reopen endpoint design unless the contract changed during implementation.

---

## Verification Ledger

No implementation verification has run yet for this epic.

Planning verification:
- GitHub issue creation completed for `#139` through `#146`.

---

## Handoff Notes

- This epic supersedes the investigation document's earlier compatibility preference. The user explicitly requested replacing the top-level `assessment` object/property in `storm-setup/current`.
- SHIP is intentionally retained as data.
- SHIP is intentionally excluded from tornado viability calculation.
- A separate future H3 endpoint is not part of this campaign because `storm-setup/current` already accepts H3 and is now the chosen delivery surface.
