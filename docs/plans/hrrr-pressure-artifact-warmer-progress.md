# HRRR Pressure Artifact Warmer Progress Log

## Overview

HRRR Pressure Artifact Warmer adds a sequential planning and implementation path for pressure artifact warming without changing the normal Storm Setup request path into a cold-acquisition path.

Implementation should proceed one issue at a time, following `docs/plans/hrrr-pressure-artifact-warmer-runbook.md`.

Parent epic:
- `#113` - https://github.com/justinrooks/arcus-signal/issues/113

Related local docs:
- `AGENTS.md`
- `docs/architecture.md`
- `docs/epics-stories.md`
- `docs/plans/hrrr-pressure-profile-runbook.md`
- `docs/plans/hrrr-pressure-profile-progress.md`
- `docs/plans/storm-setup-issue-runbook.md`
- `docs/plans/storm-setup-progress.md`
- `docs/plans/hrrr-pressure-artifact-warmer-runbook.md`

---

## Global Decisions

- Feature label: `HRRR Pressure Artifact Warmer`.
- Keep the existing working surface GRIB path intact.
- Do not add cold pressure acquisition to the normal storm-setup/current request path.
- Do not add pressure acquisition to the existing NWS alert polling loop.
- Do not move HRRR acquisition into Arcus-Anvil.
- Do not introduce Zarr, BUFKIT, native HRRR levels, or a new data platform.
- Keep the warmer sequential and issue-scoped.
- Use explicit cache keys and field-set versioning so future warmer slices can invalidate safely.
- Treat request-path degradation as preferable to on-demand cold fetching.
- Keep the warmer separate from notification/APNs behavior.

---

## Current State Summary

- Issue `#114` created the planning docs only.
- No runtime code, migrations, jobs, models, routes, tests, or refactors were added for this issue.
- Issue `#115` implemented the first runtime slice and locked in the expanded pressure contract.
- Issue `#116` added the persistent pressure artifact catalog model, migration, and focused persistence tests.
- Issue `#117` implemented the warm-job slice with catalog claim/promotion, byte-range reuse, and validation.
- The next implementation issue is `#118`.
- The normal Storm Setup request path remains unchanged.
- No cold pressure artifact acquisition has been introduced into the request path.

Do not touch:
- The existing surface GRIB path.
- The NWS alert polling loop.
- Arcus-Anvil.
- Notification/APNs pipelines.

---

## Issue Sequence

Work these issues sequentially:

1. `#114` - 01: Create HRRR pressure artifact warmer planning docs
2. `#115` - 02: First runtime warmer slice
3. `#116` - 03: Add pressure artifact catalog and metadata model
4. `#117` - 04: Warm-job slice, catalog claim, and validation

Issue `#114` is complete and only created planning documentation.

---

## Status Ledger

### Issue #114 - 01: Create HRRR pressure artifact warmer planning docs

Status: Completed

Scope:
- Create `docs/plans/hrrr-pressure-artifact-warmer-runbook.md`
- Create `docs/plans/hrrr-pressure-artifact-warmer-progress.md`
- Preserve the narrow, sequential execution model for future issues

Deferred:
- All runtime implementation
- Any queue or scheduler wiring
- Any request-path behavior changes
- Any cache implementation changes
- Any field-set or warmer job code

Files changed:
- `docs/plans/hrrr-pressure-artifact-warmer-runbook.md`
- `docs/plans/hrrr-pressure-artifact-warmer-progress.md`

Validation performed:
- Reviewed the existing planning-doc pattern in:
  - `docs/plans/hrrr-pressure-profile-runbook.md`
  - `docs/plans/hrrr-pressure-profile-progress.md`
  - `docs/plans/storm-setup-issue-runbook.md`
  - `docs/plans/storm-setup-progress.md`
- Verified the new docs were added and that the diff is scoped to the two planning files.

Known failures or follow-up work:
- None for this documentation-only issue.
- Issue `#115` is the first runtime slice and should be treated as the next active implementation target.

Handoff notes for issue `#115`:
- Keep the first runtime change narrow.
- Do not add cold acquisition to the live request path.
- Do not change the working surface GRIB path.
- Preserve explicit cache-key and field-set versioning decisions in the next implementation notes.

### Issue #115 - 02: First runtime warmer slice

Status: Completed

Scope:
- Define the expanded HRRR pressure artifact field-set contract.
- Expand `StormSetupPressureLevel` to the full pressure ladder required by the warmer contract.
- Introduce `tornadoPressureV2` and make `wrfprsf` default to it.
- Update direct-object pressure source creation to use the v2 pressure contract.
- Replace the old explicit pressure-level subset in the loader with the shared pressure contract.

Files changed:
- `Sources/App/StormSetup/StormSetupPressureLevel.swift`
- `Sources/App/StormSetup/HrrrSourceModels.swift`
- `Sources/App/StormSetup/HrrrPressureProfileLoading.swift`
- `Sources/App/StormSetup/HrrrPressureDirectObjectResolver.swift`
- `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`
- `Tests/AppTests/StormSetupPressureLevelTests.swift`
- `Tests/AppTests/HrrrPressureProfileMessageSelectorTests.swift`
- `Tests/AppTests/HrrrPressureProfileLoadingTests.swift`
- `Tests/AppTests/StormSetupHrrrSourceTests.swift`

Field-set version decision:
- `wrfprsf` now defaults to `tornadoPressureV2`.
- `tornadoPressureV1` remains in place for backward compatibility and historical fixtures.
- Direct-object pressure candidates and source metadata now resolve against the v2 contract.

Validation run and results:
- `swift test --filter HrrrPressureProfileMessageSelectorTests` passed
- `swift test --filter HrrrPressureProfileLoadingTests` passed
- `swift test --filter StormSetupHrrrSourceTests` passed

Known failures or follow-up work:
- None.
- Issue `#116` is next.

Handoff notes for issue `#116`:
- Keep the next slice narrow and issue-scoped.
- Preserve the new pressure field-set contract.
- Do not broaden into request-path behavior or warmer scheduling yet.

### Issue #116 - 03: Add pressure artifact catalog and metadata model

Status: Completed

Scope:
- Add a persistent pressure artifact catalog model.
- Add a migration for `pressure_artifact_catalog`.
- Enforce artifact identity uniqueness on `run_time`, `forecast_hour`, `product`, and `field_set_version`.
- Add focused tests for insert/query behavior, duplicate handling, version separation, and nullable ready/warming fields.

Files changed:
- `Sources/App/Models/Data/PressureArtifactCatalogModel.swift`
- `Sources/App/Migrations/CreatePressureArtifactCatalog.swift`
- `Sources/App/configure.swift`
- `Sources/App/lib/DbUtils.swift`
- `Tests/AppTests/PressureArtifactCatalogTests.swift`
- `docs/plans/hrrr-pressure-artifact-warmer-progress.md`

Schema / table:
- `pressure_artifact_catalog`

Unique constraint decision:
- Enforced on `run_time`, `forecast_hour`, `product`, and `field_set_version`.
- `valid_time` is intentionally excluded because it is derived metadata, not part of the identity wall.

Validation run and results:
- `swift test --filter PressureArtifactCatalogTests` passed
- `swift test --filter StormSetupHrrrSourceTests` passed

Known failures or follow-up work:
- None from this slice.
- `DbUtils.isUniqueConstraintViolation(_:)` now checks both `String(describing:)` and `String(reflecting:)` so Postgres unique violations are detected reliably in tests and existing call sites.
- Issue `#117` is next.

Handoff notes for issue `#117`:
- Keep the next slice narrow and issue-scoped.
- Build on the catalog table without adding request-path lookup yet.
- Do not introduce queue jobs or live HRRR acquisition.

### Issue #117 - 04: Warm-job slice, catalog claim, and validation

Status: Completed

Scope:
- Add `PressureArtifactWarmJob`.
- Add `PressureArtifactWarmingService`.
- Add a small `PressureArtifactValidating` protocol plus a default `wgrib2 -s` validation service.
- Reuse the existing `HrrrPressureIdxInventory`, `HrrrPressureProfileMessageSelector`, `HrrrGribByteRangePlanner`, and `HrrrPressureSubsetGribCache` pipeline.
- Claim pending/failed/expired catalog rows, skip ready/warming rows, and promote successful warm results to `ready`.

Files changed:
- `Sources/App/Jobs/PressureArtifactWarmJob.swift`
- `Sources/App/StormSetup/PressureArtifactWarmingService.swift`
- `Sources/App/StormSetup/PressureArtifactValidationService.swift`
- `Sources/App/configure.swift`
- `Tests/AppTests/PressureArtifactWarmJobTests.swift`
- `docs/plans/hrrr-pressure-artifact-warmer-progress.md`

Claim behavior:
- `pending`, `failed`, and `expired` rows are promoted to `warming` with a conditional SQL update.
- `ready` and `warming` rows are skipped without rebuilding.
- Duplicate jobs for the same artifact key collapse to one build path in the tests and the losing job sees the existing `warming` state.

Validation approach:
- Production validation uses the existing `ProcessRunner` pattern with `wgrib2 <subset> -s`.
- Tests use a small fake validator that can succeed or fail deterministically.
- Validation failure leaves the row in `failed` and does not promote the artifact to `ready`.

Artifact storage:
- Reuses `HrrrPressureSubsetGribCache`.
- No separate promoted artifact path was added.
- The catalog is only flipped to `ready` after the subset cache returns and validation succeeds.

Validation commands and results:
- `swift test --filter PressureArtifactWarmJobTests` passed
- `swift test --filter HrrrPressureSubsetGribCacheTests` passed
- `swift test --filter PressureArtifactCatalogTests` passed

Known failures or follow-up work:
- None from this slice.
- The job is registered with Vapor Queues, but no new lane or scheduled probe was added.
- Issue `#118` is next and owns the model-artifacts lane and scheduled probe.

Handoff notes for issue `#118`:
- Keep the lane and scheduler work separate from the warm-job implementation.
- Do not revisit the claim logic or byte-range reuse unless the lane wiring forces it.
- Preserve the current request-path boundaries.

---

## Decisions Made

- The planning docs are the only deliverable for `#114`.
- Sequential execution is mandatory for future warmer work.
- The request path must not perform cold pressure acquisition.
- The existing surface GRIB path is out of bounds for this effort.
- The warmer should be positioned as a separate scheduling concern, not a request-time fallback.

---

## Open Questions

- What exact warmer cadence will `#115` use?
- What is the initial pressure field-set version number?
- Which cache-retention policy should apply when a field-set version changes?
- Should a stale warmed artifact be consumed for degraded responses, or only a fresh matching artifact?

These are intentionally left for the next implementation slice and should be settled before code is written.

---

## Validation Performed

- Read the existing issue-runbook and progress-doc patterns before writing the new docs.
- Verified the new files exist under `docs/plans`.
- Verified the implementation scope for `#114` is documentation only.
- Ran and passed the warm-job verification filters for issue `#117`:
  - `swift test --filter PressureArtifactWarmJobTests`
  - `swift test --filter HrrrPressureSubsetGribCacheTests`
  - `swift test --filter PressureArtifactCatalogTests`

---

## Current Follow-Up

- `#118` is the next issue to run.
- `#118` should preserve the boundaries set here and build on the warm-job slice without expanding into request-path lookup.
