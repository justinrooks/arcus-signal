# Tornado Viability Current Response Runbook

**Status:** Active
**Applies To:** Storm Setup `current` response tornado viability contract
**Project:** Arcus Signal
**Parent Issue:** https://github.com/justinrooks/arcus-signal/issues/139
**Related Docs:**
- `AGENTS.md`
- `docs/architecture.md`
- `docs/epics-stories.md`
- `docs/plans/tornado-viability-interpreter-redesign.md`
- `docs/plans/tornado-viability-current-response-progress.md`
- `docs/plans/storm-setup-current-response-runbook.md`
- `docs/plans/storm-setup-current-response-progress.md`

This runbook defines how to execute the tornado viability current-response epic one issue at a time.

Every implementation prompt for this work should reference this runbook and `docs/plans/tornado-viability-current-response-progress.md`.

---

## Purpose

Replace the current top-level `assessment` object on `GET /api/v1/storm-setup/current` with a localized tornado formation viability report that explains environmental capability, conditional realization, primary limiter, and confidence.

This is a deliberate production response-contract change. It is not a new endpoint, not a storm prediction system, and not a rewrite of Storm Setup orchestration.

The endpoint should keep using the existing H3-first Storm Setup flow:

1. signed `Int64` H3 input
2. HRRR surface diagnostics
3. Anvil/profile canonical ingredients when available
4. existing sampled snapshot cache
5. one interpreted tornado viability report

SHIP must remain available as a data property in raw/canonical/profile payloads. SHIP must not participate in tornado viability calculation, confidence raising, or summary wording.

---

## Source Of Truth

Treat these inputs with the following authority:

1. `AGENTS.md`
   Repo-wide server, review-slice, H3, and verification rules.

2. `docs/architecture.md` and `docs/epics-stories.md`
   Arcus Signal pipeline and production invariants.

3. `docs/plans/tornado-viability-interpreter-redesign.md`
   Investigation evidence, current-state analysis, and meteorological design direction.

4. This runbook
   The execution contract for this epic.

5. `docs/plans/tornado-viability-current-response-progress.md`
   Durable issue sequence, decisions, and handoff ledger.

6. The current GitHub sub-issue
   The implementation boundary for the current run.

7. Current source and tests touched by that sub-issue.

If a GitHub issue conflicts with this runbook, stop and reconcile before editing code.

---

## Required Read Order

Read in this order before implementation:

1. `AGENTS.md`
2. `docs/architecture.md`
3. `docs/epics-stories.md`
4. `docs/plans/tornado-viability-interpreter-redesign.md`
5. `docs/plans/tornado-viability-current-response-runbook.md`
6. `docs/plans/tornado-viability-current-response-progress.md`
7. The current GitHub issue
8. Relevant source and tests for the current issue

Do not inspect or modify SkyAware iOS unless a future issue explicitly scopes app-side work.

---

## Minimal Prompt Contract

A future implementation prompt can be as small as:

```text
Implement GitHub issue #NN for arcus-signal.

Before coding, read:
- docs/plans/tornado-viability-current-response-runbook.md
- docs/plans/tornado-viability-current-response-progress.md
- the GitHub issue body

Work only that issue. Keep the slice compact and reviewable.
After verification, update docs/plans/tornado-viability-current-response-progress.md.
```

If a prompt omits these docs, the implementing agent should still read them before coding.

---

## Target Production Contract

`GET /api/v1/storm-setup/current?h3=<signed-int64-cell>` should keep the existing top-level structure except the old `assessment` property should be replaced by `tornadoViability`.

Target shape:

```swift
struct StormSetupCurrentResponse: Content, Sendable {
    let setup: StormSetupCurrentSetupResponse
    let ingredients: StormSetupTornadoIngredientsResponse
    let profileAnalysis: AnvilAnalyzeProfileResponse?
    let tornadoViability: TornadoViabilityReport
}
```

Recommended report shape:

```swift
struct TornadoViabilityReport: Content, Sendable {
    let overall: IngredientSupport
    let realization: TornadoViabilityRealization
    let primaryFailureMode: TornadoViabilityFailureMode
    let confidence: SnapshotConfidence
    let summary: String
    let details: TornadoViabilityDetails
    let limitingFactors: [TornadoViabilityLimiter]
}

struct TornadoViabilityDetails: Content, Sendable {
    let stormViability: IngredientSupport
    let supercellViability: IngredientSupport
    let tornadoEfficiency: IngredientSupport
    let inhibition: IngredientSupport
    let lowLevelRotation: IngredientSupport
    let lowLevelStretching: IngredientSupport
    let cloudBaseEfficiency: IngredientSupport
    let supercellComposite: IngredientSupport
    let tornadoComposite: TornadoCompositeSignal
}

struct TornadoCompositeSignal: Content, Sendable {
    let fixedLayer: IngredientSupport
    let effectiveLayer: IngredientSupport
    let combined: IngredientSupport
    let fixedStrongerThanEffective: Bool
}
```

Exact names may change during implementation if the issue explains why, but the endpoint must not continue exposing top-level `assessment` after this epic completes.

Keep the existing raw/canonical ingredients in `ingredients`. That is where SHIP remains visible through `significantHail` / `ship` and `profileAnalysis.ship`.

---

## Product Language Guardrails

Use this framing:

- environmental viability
- tornado formation viability
- capability vs realization
- localized H3 diagnosis
- conditional setup
- primary limiter / failure mode
- "How weather-aware do I need to be right now?"

Avoid this framing:

- tornado risk score
- tornado probability
- tornado prediction
- warning replacement
- deterministic tornado occurrence claims

Required copy tone:

- calm
- clear
- useful
- trustworthy
- not dramatic

---

## Required Guardrails

- Work one sub-issue at a time.
- Keep `GET /api/v1/storm-setup/current` as the delivery surface.
- Do not add a separate tornado viability endpoint in this epic.
- Preserve signed `Int64` H3 input and validation.
- Preserve the existing Storm Setup provider orchestration.
- Do not add server-side lat/lon storage.
- Do not add new weather data dependencies.
- Do not duplicate Anvil/profile calls.
- Preserve Anvil/profile-derived values as canonical for sounding-derived ingredients when available.
- Preserve surface/2D GRIB values as diagnostics, context, and fallback.
- Keep `AnvilAnalyzeProfileResponse.ship`, `TornadoRawParameters.significantHail`, and existing SHIP transport behavior.
- Do not use SHIP to compute tornado viability, raise confidence, select limiters, or write tornado summaries.
- Preserve `Content`, `Codable`, and `Sendable` expectations.
- Keep implementations deterministic and test-backed.
- Update `docs/plans/tornado-viability-current-response-progress.md` before finishing each implementation issue.

---

## Forbidden Scope

- No broad Storm Setup orchestration rewrite.
- No new database schema, queues, jobs, or persistence.
- No notification/APNs changes.
- No live HRRR, Anvil, Redis, Postgres, or network-dependent tests.
- No app repository changes.
- No removal of SHIP fields.
- No use of SHIP in tornado viability calculation.
- No public tornado probability or risk-score fields.
- No deterministic tornado wording.
- No opportunistic cleanup outside the current issue.

---

## Current Code Boundaries To Preserve

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

## Sequential Execution Model

Work issues in the sequence listed in the progress doc.

For each issue:

1. Read the issue body, this runbook, and the progress doc.
2. State the smallest useful slice before editing non-trivial code.
3. Write or update focused tests first when practical.
4. Implement only the current issue.
5. Run the issue's verification commands.
6. Update the progress doc with files changed, tests run, behavior, deferred scope, and handoff notes.
7. Stop.

Do not move into the next issue without explicit user direction.

---

## Verification Defaults

Prefer narrow verification:

```bash
swift test --filter StormSetupCurrentResponseDTOTests
swift test --filter TornadoIngredientInterpreterTests
swift test --filter StormSetupProviderTests
swift test --filter StormSetupControllerTests
swift test --filter AnvilIngredientEvidenceTests
```

Run broader verification when shared DTOs, provider protocols, or controller contracts change:

```bash
swift test --filter StormSetup
swift test
swift build
```

Do not claim tests passed unless they were run in the current implementation pass.

---

## Quality Bar For 5.4 Mini Medium

Each sub-issue should be:

- one behavior or contract change
- one coherent review unit
- preferably 1-3 production files
- no unrelated cleanup
- deterministic
- locally testable
- explicit about non-goals
- stopped at the acceptance criteria

If a slice starts exceeding the review budget, stop at the nearest coherent checkpoint and update the progress doc.
