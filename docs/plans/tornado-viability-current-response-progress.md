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

Status: Complete

Scope:
- Split SCP support from STP fixed/effective support.
- Stop maxing SCP and STP together.
- Ensure SHIP is retained as data but ignored by tornado viability calculations.

Files changed:
- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Sources/App/StormSetup/AnvilIngredientEvidence.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`
- `Tests/AppTests/AnvilIngredientEvidenceTests.swift`

Behavior change:
- SCP now feeds supercell support only.
- STP fixed/effective feed tornado-specific composite support without being maxed together with SCP.
- SHIP still decodes and is exposed, but it no longer contributes to tornado viability or confidence adjustments.

Skipped validation:
- None.

Deferred scope:
- Full internal tornado viability diagnosis model for #142.
- Broader summary rewrite beyond the minimal conditional branches needed for this split.

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
- SHIP still ships through `AnvilAnalyzeProfileResponse` and `TornadoRawParameters`, but tornado viability now reads SCP/STP-only evidence for adjustment and summary language.
- The next slice can add the internal diagnosis model without undoing this split.

### Issue #142 - 03: Introduce internal tornado viability diagnosis

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/142

Status: Complete

Scope:
- Add internal diagnosis types for storm viability, supercell viability, low-level rotation, low-level stretching, cloud-base efficiency, tornado efficiency, inhibition, composites, realization, failure mode, and confidence.
- Map the diagnosis to `TornadoViabilityReport`.

Deferred:
- Public endpoint shape changes should already be done in issue 01.
- Avoid broad provider/controller refactors.

Files likely touched:
- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`
- `Sources/App/StormSetup/StormSetupCurrentResponse.swift`

Tests / commands:
- `swift test --filter TornadoIngredientInterpreterTests`

Handoff notes:
- Keep diagnosis private/internal unless Swift visibility requires otherwise.
- Preserve `Content` DTOs separately from internal diagnosis types.
- The interpreter now builds an internal `TornadoViabilityDiagnosis` and derives the existing assessment/report values from that diagnosis.
- `TornadoViabilityReport(diagnosis:)` now maps the diagnosis directly for the response boundary; the provider still uses the assessment bridge for now.
- Representative weak, conditional, supportive, strong, missing-field, Anvil-degraded, and Anvil-backed cases remain covered.
- #143 can now focus on limiter precision and failure-mode sharpening without reworking the diagnosis plumbing again.

### Issue #143 - 04: Improve failure modes and limiter precision

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/143

Status: Complete

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

Files changed:
- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Sources/App/StormSetup/StormSetupCurrentResponse.swift`
- `Sources/App/StormSetup/TornadoIngredientAssessment.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`
- `Tests/AppTests/StormSetupCurrentResponseDTOTests.swift`

Behavior change:
- Low-level rotation, low-level stretching, cloud-base efficiency, and tornado efficiency are now separated in the internal diagnosis and surfaced distinctly in the public tornado viability report.
- Weak SRH and weak 3CAPE now produce different report limiters, with elevated cloud bases, strong cap, conditional initiation, weak storm organization, and fixed/effective STP disagreement represented separately.
- `primaryFailureMode` is now emitted on the tornado viability report and realization can remain conditional for moderate CIN or STP disagreement without collapsing into strong-cap language.
- Missing storm-mode data is still reported as unknown rather than invented.

Tests run:
- `swift test --filter TornadoIngredientInterpreterTests`

Skipped validation:
- Full repository test suite.
- Provider/controller integration tests outside the focused interpreter filter.

Deferred scope:
- #144 summary rewrite.
- Any further public copy tuning beyond the minimal test-driven adjustments.
- New weather inputs or storm-mode inference from radar/reflectivity/UH.

Handoff notes for #144:
- The public report now has the right structure and limiter precision; #144 should focus on tightening summary language around the richer diagnosis.
- Preserve SHIP as data-only.
- Keep diagnosis authoritative; do not reintroduce combined low-level wording unless the summary explicitly wants to talk about the combined tornado-efficiency bucket.

Handoff notes:
- Existing `TornadoLimitingFactor` does not need to drive the new report.
- Prefer new viability-specific limiter enum for the new report.

### Issue #144 - 05: Rewrite tornado viability summaries

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/144

Status: Complete

Scope:
- Rewrite `tornadoViability.summary` around environmental capability vs realization.
- Keep raw values out of casual summary copy.
- Maintain prohibited-language tests.

Deferred:
- App UI rendering.
- Advanced raw-value drilldowns.

Files changed:
- `Sources/App/StormSetup/TornadoIngredientInterpreter.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`

Behavior change:
- `tornadoViability.summary` now leads with calm SkyAware capability language such as "environment can support" and "tornado-capable storms" instead of the older weak/supportive phrasing.
- Conditional summaries now distinguish realization limits from capability limits, with branch-specific limiter copy for CIN, STP disagreement, low-level rotation, low-level stretching, cloud bases, moisture, and storm organization.
- Supportive and strong summaries now end with weather-aware guidance rather than implying deterministic tornado occurrence.
- Anvil degraded/unavailable handling remains appended and unchanged.

Tests run:
- `swift test --filter TornadoIngredientInterpreterTests`

Skipped validation:
- Full repository test suite.
- Provider/controller integration tests outside the focused interpreter filter.

Deferred scope:
- App UI rendering.
- Advanced raw-value drilldowns.
- Any matrix or contract expansion reserved for #145.

Handoff notes:
- Preserve the current "environment can support" framing and the prohibited-language guardrails.
- Keep the summary calm, not dramatic.
- #145 should focus on matrix and contract coverage using the newly stabilized copy.

### Issue #145 - 06: Expand matrix and contract tests

GitHub:
- https://github.com/justinrooks/arcus-signal/issues/145

Status: Complete

Scope:
- Add focused tests for representative environments.
- Pin the new current-response contract.
- Verify Anvil-backed canonical values are not double-counted.
- Verify SHIP remains data-only and does not influence tornado viability.

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

Validation:
- `swift test --filter TornadoIngredientInterpreterTests` passed.
- `swift test --filter StormSetupCurrentResponseDTOTests` passed.
- `swift test --filter StormSetupProviderTests` passed.
- `swift test --filter StormSetupControllerTests` passed.

Files changed:
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`
- `Tests/AppTests/StormSetupCurrentResponseDTOTests.swift`
- `Tests/AppTests/StormSetupProviderTests.swift`
- `Tests/AppTests/StormSetupControllerTests.swift`
- `docs/plans/tornado-viability-current-response-progress.md`

Coverage added:
- Weak setup.
- Supercell-supportive but tornado-limited setup.
- Capped conditional setup.
- Low-level efficient setup.
- Strong supportive setup.
- Missing-field fallback.
- Degraded Anvil evidence.
- Anvil-backed canonical values not double-counted.
- SHIP present in data payloads but excluded from tornado viability.
- Response-contract assertions for `tornadoViability` and absent top-level `assessment`.

Skipped validation:
- None.

Deferred scope:
- Live weather fixtures.
- Broad snapshot fixtures.
- Any follow-on documentation work for the app-facing migration itself.

Handoff notes:
- Keep tests deterministic and local.
- The live current-response contract is pinned on `tornadoViability` with top-level `assessment` absent.
- SHIP remains visible in raw/canonical/profile payloads, but tornado viability ignores it.
- #146 should document the app-facing response migration only; do not reopen the interpreter coverage slice.

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
