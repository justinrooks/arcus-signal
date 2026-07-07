# Storm Setup Current Response Issue Runbook

**Status:** Active
**Applies To:** Storm Setup production response consolidation
**Project:** Arcus Signal
**Parent Issue:** https://github.com/justinrooks/arcus-signal/issues/133
**Related Docs:**
- `AGENTS.md`
- `docs/architecture.md`
- `docs/epics-stories.md`
- `docs/plans/storm-setup-current-response-progress.md`
- `docs/plans/storm-setup-issue-runbook.md`
- `docs/plans/storm-setup-progress.md`
- `docs/plans/hrrr-pressure-profile-runbook.md`
- `docs/plans/hrrr-pressure-profile-progress.md`

This document defines how to execute one Storm Setup current-response sub-issue at a time.

Every implementation prompt for this work should reference this runbook and `docs/plans/storm-setup-current-response-progress.md`.

---

## Purpose

Consolidate the production Storm Setup response so `GET /api/v1/storm-setup/current` returns the existing setup data, surface-derived ingredient values, Anvil profile-analysis result, and interpreted tornado ingredient assessment in one composed contract.

This is a response-contract consolidation. It is not a rewrite of Storm Setup orchestration.

The current execution path already calls Anvil/profile analysis internally. The work is to preserve the existing `AnvilAnalyzeProfileResponse` and expose it from the production response without duplicating computation, moving dev diagnostics into production, or creating a second source of truth for assessment logic.

---

## Source Of Truth

Treat these inputs with the following authority:

1. The repo `AGENTS.md`
   Repo-wide server and review-slice rules.

2. `docs/architecture.md` and `docs/epics-stories.md`
   Arcus Signal pipeline and production invariants.

3. `docs/plans/storm-setup-current-response-runbook.md`
   The execution contract for this epic.

4. `docs/plans/storm-setup-current-response-progress.md`
   Durable issue sequence, decisions, and handoff ledger.

5. Existing Storm Setup and pressure-profile docs
   Prior boundaries for surface sampling, Anvil evidence, and dev diagnostics.

6. The current GitHub sub-issue
   The implementation boundary for the current run.

7. Current source and tests touched by that sub-issue.

---

## Required Read Order

Read in this order before implementation:

1. `AGENTS.md`
2. `docs/architecture.md`
3. `docs/epics-stories.md`
4. `docs/plans/storm-setup-current-response-runbook.md`
5. `docs/plans/storm-setup-current-response-progress.md`
6. `docs/plans/storm-setup-issue-runbook.md`
7. `docs/plans/storm-setup-progress.md`
8. `docs/plans/hrrr-pressure-profile-runbook.md`
9. `docs/plans/hrrr-pressure-profile-progress.md`
10. The current GitHub issue
11. Relevant source and tests for the current issue

Do not inspect or modify the SkyAware iOS repository unless a future issue explicitly scopes app-side work. This epic is server-side contract preparation.

---

## Minimal Prompt Contract

A future implementation prompt can be as small as:

```text
Implement GitHub issue #NN for arcus-signal.

Before coding, read:
- docs/plans/storm-setup-current-response-runbook.md
- docs/plans/storm-setup-current-response-progress.md
- the GitHub issue body

Work only that issue. Keep the slice compact and reviewable.
After verification, update docs/plans/storm-setup-current-response-progress.md.
```

If a prompt omits these docs, the implementing agent should still read them before coding.

---

## Production Contract Target

Prefer a composed production DTO with stable top-level sections:

```swift
struct StormSetupCurrentResponse: Content, Sendable {
    let setup: StormSetupResponse
    let ingredients: TornadoIngredientSnapshot
    let profileAnalysis: AnvilAnalyzeProfileResponse?
    let assessment: TornadoIngredientAssessment
}
```

Exact type names must follow the existing codebase. If the current `TornadoIngredientSnapshot` remains the best available setup/ingredient container for the first slice, preserve behavior and document the transitional shape in the progress log.

The production response should expose `AnvilAnalyzeProfileResponse` only. Keep `AnvilAnalyzeProfileRequest` and `AnvilAnalyzeProfilePreviewDebugDTO` on `api/v1/dev/anvil/profile-analysis` unless a future issue explicitly promotes them.

---

## Scope Rules

Implement only the current issue's scope.

### Required

- Keep `api/v1/storm-setup/current` as the production endpoint.
- Preserve the existing Storm Setup execution path.
- Reuse the existing Anvil/profile analysis call already made inside Storm Setup.
- Avoid duplicate Anvil calls.
- Preserve the existing assessment logic in `TornadoIngredientInterpreter`.
- Preserve existing surface ingredient values represented by `TornadoIngredientSnapshot` / `TornadoRawParameters`.
- Preserve existing `AnvilIngredientEvidence` behavior while adding access to the raw `AnvilAnalyzeProfileResponse`.
- Keep Anvil/profile fields optional when Anvil evidence is unavailable, stale, or rejected.
- Keep DTOs explicit, `Content`, and `Sendable` where appropriate.
- Add focused tests for every behavior-changing slice.
- Run the narrowest meaningful verification before finishing.
- Update `docs/plans/storm-setup-current-response-progress.md` before finishing each sub-issue.

### Forbidden

- Do not rebuild Storm Setup orchestration.
- Do not create a parallel production Anvil path.
- Do not call Anvil twice for one Storm Setup request.
- Do not move dev-only request/debug diagnostics into the production response.
- Do not remove or deprecate `api/v1/dev/anvil/profile-analysis` before the production response is verified.
- Do not change assessment thresholds or interpretation language.
- Do not flatten all fields into one large DTO.
- Do not broaden the issue into iOS implementation work.
- Do not introduce new storage, queues, jobs, or database schema.
- Do not refactor unrelated Storm Setup, notification, APNs, NWS, or operator-dashboard code.

If a future-facing seam is needed, keep it narrow, local, test-backed, and documented in the progress log.

---

## Current Code Boundaries To Preserve

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

Relevant tests:
- `Tests/AppTests/StormSetupControllerTests.swift`
- `Tests/AppTests/StormSetupProviderTests.swift`
- `Tests/AppTests/AnvilAnalyzeProfileResponseDTOTests.swift`
- `Tests/AppTests/AnvilProfileAnalysisControllerTests.swift`
- `Tests/AppTests/AnvilIngredientEvidenceTests.swift`
- `Tests/AppTests/TornadoIngredientInterpreterTests.swift`

---

## Sequential Execution Model

Work one GitHub sub-issue at a time, in the sequence listed in `docs/plans/storm-setup-current-response-progress.md`.

Do not execute multiple sub-issues in parallel. Parallelism is acceptable only for read-only investigation inside the current issue.

For each issue:

1. Read the issue body, this runbook, and the progress log.
2. Identify the smallest useful slice and intended review unit.
3. Write or update the focused failing test first when practical.
4. Implement the smallest change that satisfies the issue acceptance criteria.
5. Run the issue's verification command.
6. Update the progress log with files changed, tests run, local notes, deferred scope, and handoff notes.
7. Stop.

---

## Verification Defaults

Prefer narrow verification first:

```bash
swift test --filter StormSetupControllerTests
swift test --filter StormSetupProviderTests
swift test --filter AnvilAnalyzeProfileResponseDTOTests
```

Run broader verification when the issue touches shared DTOs or provider protocols:

```bash
swift test --filter StormSetup
swift test
swift build
```

Do not claim tests passed unless they were run in the current implementation pass.

---

## Quality Bar

Each sub-issue should be suitable for 5.4 mini medium:

- one behavior change
- one coherent review unit
- preferably 1-3 production files
- no unrelated cleanup
- compact issue body
- explicit guardrails
- focused tests
- deterministic verification

The whole epic should trade cleverness for boring clarity. This is contract work; boring is a feature.
