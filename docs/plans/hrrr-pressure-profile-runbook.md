# HRRR Pressure Profile Issue Runbook

**Status:** Active  
**Applies To:** HRRR Pressure Profiles, Anvil, and Storm Setup Ingredient Evidence  
**Project:** Arcus Signal  
**Parent Issue:** https://github.com/justinrooks/arcus-signal/issues/85  
**Related Docs:**
- `AGENTS.md`
- `docs/architecture.md`
- `docs/epics-stories.md`
- `docs/plans/storm-setup-issue-runbook.md`
- `docs/plans/storm-setup-progress.md`
- `docs/plans/hrrr-pressure-profile-progress.md`

This document defines how to execute one HRRR pressure-profile sub-issue at a time.

Every implementation prompt for this work should reference this runbook and `docs/plans/hrrr-pressure-profile-progress.md`.

---

## Purpose

Build the smallest reliable pressure-profile path that can fetch selected HRRR `wrfprsf` GRIB messages by byte range, decode a point profile with existing `wgrib2` plumbing, send the profile to Arcus-Anvil, and use Anvil's severe-weather parameters as supporting ingredient evidence.

This is not a tornado, hail, or storm predictor. It is an environmental ingredient signal: conditions may be favorable if storms form.

This runbook exists to keep implementation:
- issue-scoped
- sequential
- testable offline
- compatible with the existing surface HRRR flow
- clear enough for small-agent execution
- honest about uncertainty in model fields and Anvil contract details

> Do not treat any single sub-issue as permission to rebuild Storm Setup.  
> Implement the current slice, verify it, update the progress log, and stop.

---

## Source of Truth

Treat these inputs with the following authority:

1. The repo `AGENTS.md`  
   Repo-wide and server standing rules.

2. `docs/architecture.md` and `docs/epics-stories.md`  
   Arcus Signal pipeline, persistence, idempotency, and delivery invariants.

3. `docs/plans/hrrr-pressure-profile-runbook.md`  
   The execution contract for pressure-profile issues.

4. `docs/plans/hrrr-pressure-profile-progress.md`  
   Durable implementation ledger and issue-to-issue handoff record.

5. `docs/plans/storm-setup-issue-runbook.md` and `docs/plans/storm-setup-progress.md`  
   Existing Storm Setup boundaries and completed surface HRRR decisions.

6. The current GitHub sub-issue  
   The implementation boundary for the current run.

7. Current source and tests touched by that issue.

---

## Required Read Order

Read in this order before implementation:

1. `AGENTS.md`
2. `docs/architecture.md`
3. `docs/epics-stories.md`
4. `docs/plans/hrrr-pressure-profile-runbook.md`
5. `docs/plans/hrrr-pressure-profile-progress.md`
6. `docs/plans/storm-setup-issue-runbook.md`
7. `docs/plans/storm-setup-progress.md`
8. The current GitHub issue
9. Relevant source and tests for the current issue

Do not inspect or modify app repositories unless a future issue explicitly scopes that work.

---

## Minimal Prompt Contract

A future implementation prompt can be as small as:

```text
Implement GitHub issue #NN for arcus-signal.

Before coding, read:
- docs/plans/hrrr-pressure-profile-runbook.md
- docs/plans/hrrr-pressure-profile-progress.md
- the GitHub issue body

Work only that issue. Do not touch the existing surface GRIB flow unless the issue explicitly allows it.
After verification, update docs/plans/hrrr-pressure-profile-progress.md.
```

If a prompt omits those docs, the implementing agent should still read them before coding.

---

## Scope Rules

Implement only the current issue's scope.

### Required

- Keep implementation files under `Sources/App/StormSetup` unless the issue explicitly targets API DTOs or controllers.
- Keep the existing surface HRRR endpoint and surface GRIB path behavior unchanged.
- Reuse the existing `HrrrRunCandidate`, `StormSetupSourceMetadata`, `Wgrib2Client`, `HrrrFieldSampler`, pressure-profile grouper, and Anvil request builder where they fit.
- Use AWS HRRR direct-object URLs as the primary pressure source.
- Use `.idx` inventory files to select only required pressure-product GRIB messages.
- Use HTTP byte-range downloads for the pressure path; the whole-file pressure cache is retired.
- Preserve deterministic source identity: model, product, domain, run time, forecast hour, valid time, field set, selected levels, selected messages, and source URL.
- Keep H3 as signed `Int64` inside server boundaries.
- Resolve H3 to centroid latitude/longitude internally before sampling.
- Use `wgrib2 -s -lon` through the existing wrapper for point decoding.
- Return missing/unavailable fields as missing diagnostics, not fake zeroes.
- Normalize units explicitly:
  - temperature/dewpoint in Celsius for Anvil profile DTOs
  - wind components in meters per second unless Anvil contract says otherwise
  - height as meters MSL
- Filter invalid or below-ground levels before building the Anvil request.
- Validate profile completeness before sending to Anvil.
- Add offline deterministic tests for each slice.
- Run the narrowest meaningful verification before finishing.
- Update `docs/plans/hrrr-pressure-profile-progress.md` before finishing.

### Forbidden

- Do not refactor the existing surface GRIB flow.
- Do not introduce Zarr, BUFKit, or a new data platform unless a completed issue proves byte-range GRIB is blocked.
- Do not add SHARPpy inside Arcus Signal.
- Do not move HRRR fetching into Arcus-Anvil.
- Do not introduce server-side raw user lat/lon storage.
- Do not expose raw SCP/STP/SHIP numbers directly as user-facing product copy.
- Do not describe outputs as tornado prediction, hail prediction, probability, or risk score.
- Do not add a broad NOAA provider framework.
- Do not use live HRRR, live NOMADS, live AWS, or live Anvil calls in unit tests.
- Do not close or rewrite unrelated notification/APNs/NWS issues as part of pressure-profile work.

If a future-facing seam is required, keep it:
- narrow
- test-backed
- replaceable
- documented in the progress log

---

## Current Code Boundaries To Preserve

Keep:
- `Sources/App/Controllers/StormSetupController.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Sources/App/StormSetup/HrrrRunResolver.swift`
- `Sources/App/StormSetup/HrrrNomadsURLBuilder.swift` for the existing surface path
- `Sources/App/StormSetup/GribSubsetCache.swift` for existing NOMADS surface subsets
- `Sources/App/StormSetup/Wgrib2Client.swift`
- `Sources/App/StormSetup/Wgrib2PointSample.swift`
- `Sources/App/StormSetup/StormSetupPressureProfileGrouper.swift`
- `Sources/App/StormSetup/AnvilProfileRequestBuilder.swift`
- `Sources/App/Models/API/AnvilAnalyzeProfileRequest.swift`

Pressure work may extend or add adjacent types, but should not require the surface endpoint to change.

---

## Working Style

Prefer:
- small value types for parsed inventory records and range plans
- pure parsers and selectors
- mocked HTTP clients for range-download tests
- explicit diagnostics for missing variables, missing levels, and invalid ranges
- cache keys that are boring and inspectable
- vertical slices over broad abstractions
- one issue, one commit-sized implementation

Avoid:
- generic provider hierarchies
- route-level orchestration
- hidden live network dependencies
- shell command strings
- ambiguous "latest" source naming
- silent fallbacks from byte-range to whole-file download
- user-facing prediction language

The right shape is a narrow pressure-profile extension inside Storm Setup, not a meteorology platform trying to sneak into the room wearing a lanyard.

---

## Sequential Execution Model

Work one GitHub sub-issue at a time, in the sequence order listed in `docs/plans/hrrr-pressure-profile-progress.md`.

Issue numbers are not the sequence source of truth. Issue titles are prefixed with `01` through `08` because some later issues were created out of numeric order.

Do not execute multiple pressure-profile sub-issues in parallel under a parent coordinator.

Parallelism is allowed only inside the current issue and only for read-only investigation or isolated subtasks.

---

## Execution Sequence

Before coding for the current issue:

1. Inspect the issue body, this runbook, and the progress log.
2. Identify which existing types can be reused without changing the surface path.
3. Write a short issue-scoped plan.
4. Add or update the focused failing test first when code changes are required.
5. Implement the smallest change that satisfies the issue acceptance criteria.
6. Run the issue's required verification.
7. Update the progress log with status, files changed, tests run, deferred scope, and handoff notes.

If implementation discovers that the issue scope is wrong, stop and report the mismatch instead of broadening the change.

---

## Standard Completion Checklist

Before finishing any sub-issue:

- Current issue acceptance criteria are satisfied or a blocker is documented.
- Existing surface HRRR tests still pass when the issue touches shared Storm Setup types.
- New tests do not use live network calls.
- No raw user lat/lon storage was added.
- No Anvil response numbers are surfaced as product copy.
- `docs/plans/hrrr-pressure-profile-progress.md` is updated.
- The final response names verification that actually ran.
