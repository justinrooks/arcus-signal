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
- Issue `#118` implemented the worker-owned probe slice and dedicated model-artifacts scheduling lane.
- Issue `#119` changed the normal `storm-setup/current` pressure-evidence path to consume exact ready catalog artifacts instead of request-time cold acquisition.
- Issue `#120` added bounded stale pressure-artifact fallback plus worker-owned expiration and deletion.
- Issue `#121` added structured diagnostics across probe, warm, lookup, and request-path evidence resolution, plus the regression guard for exact-artifact unusable-profile failures.
- Issue `#122` added claim fencing, stale `pending` recovery, expired `warming` reclamation, and unusable-ready repair.
- The currently scoped warmer issue set is complete, including cleanup claim fencing and active-deletion exclusion.
- The normal Storm Setup request path remains unchanged.
- No cold pressure artifact acquisition has been introduced into the request path.

## Warm Invariant

Pressure artifact promotion now requires all of the following before a row may become `ready`:

- The current field-set contract selected every pressure level and every required variable.
- Every HTTP 206 range response included a parseable `Content-Range` header and matched the requested range shape.
- `wgrib2 -s` returned exactly the selected message count.
- Any validation failure invalidates the subset cache entry before another warm attempt can reuse it.

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
5. `#118` - 05: Worker-owned HRRR pressure artifact probe and schedule
6. `#119` - 06: Change storm-setup/current to consume ready pressure artifacts
7. `#120` - 07: Add pressure artifact cleanup, expiration, and stale fallback
8. `#121` - 08: Add diagnostics for pressure artifact acquisition
9. `#122` - 09: Add claim fencing and stale-state recovery

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

Validation and promotion behavior:
- Warm selection now fails before download when the pressure inventory is incomplete for the expanded contract.
- `wgrib2` line-count validation must match the selected message count before a row can transition to `ready`.
- Validation failures evict both `subset.grib2` and `subset.json` from the pressure subset cache before the next warm attempt.

Validation run for this slice:
- `swift build`
- `swift test --filter HrrrPressureByteRangeDownloaderTests`
- `swift test --filter HrrrPressureSubsetGribCacheTests`
- `swift test --filter HrrrPressureProfileMessageSelectorTests`
- `swift test --filter PressureArtifactDiagnosticsTests`
- `swift test --filter PressureArtifactWarmJobTests`
- `swift test --no-parallel`

Remaining lifecycle and deployment findings:
- No Docker, lease, or cleanup lifecycle behavior changed in this slice.
- The worker-owned cleanup and probe schedules remain the only lifecycle hooks for this warmer path.
- The repository’s broader parallel database-test isolation issue remains out of scope, but `swift test --no-parallel` passed.
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

### Issue #118 - 05: Worker-owned HRRR pressure artifact probe and schedule

Status: Completed

Scope:
- Add `HRRRPressureArtifactProbeService`.
- Add `ProbeHRRRPressureArtifactsScheduledJob`.
- Add the dedicated queue lane `model-artifacts`.
- Schedule probe work in worker mode only, every 300 seconds by default.
- Keep the probe limited to `.idx` availability checks and catalog state gating.
- Enqueue `PressureArtifactWarmJob` only when the catalog state is missing, `failed`, or `expired`.

Files changed:
- `Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift`
- `Sources/App/Jobs/ProbeHRRRPressureArtifactsScheduledJob.swift`
- `Sources/App/Worker/ArcusQueueLane.swift`
- `Sources/App/StormSetup/StormSetupConfiguration.swift`
- `Sources/App/configure.swift`
- `Sources/App/Extensions/ext+Application.swift`
- `Tests/AppTests/HRRRPressureArtifactProbeServiceTests.swift`
- `Tests/AppTests/AppTests.swift`
- `Tests/AppTests/AnvilProfileClientTests.swift`
- `Tests/AppTests/StormSetupConfigurationTests.swift`
- `Tests/AppTests/StormSetupWgrib2ClientTests.swift`
- `docs/plans/hrrr-pressure-artifact-warmer-progress.md`

Queue lane:
- `model-artifacts`

Scheduling cadence:
- 300 seconds by default
- Environment override: `STORM_SETUP_PRESSURE_ARTIFACT_PROBE_INTERVAL_SECONDS`

Enqueue / skip policy:
- Enqueue `PressureArtifactWarmJob` when `.idx` is available and the catalog row is missing, `failed`, or `expired`.
- Transition the catalog row to `pending` before enqueueing.
- Skip duplicate work when the catalog row is `pending`, `warming`, or `ready`.
- When `.idx` is unavailable, update `last_checked_at`, keep the row non-ready/non-warming, and do not enqueue warm work.

Validation performed:
- `swift test --filter HRRRPressureArtifactProbeServiceTests` passed
- `swift test --filter scheduledDispatchUsesIngestLane` passed
- `swift test --filter AppTests.workerBootstrapRegistersPressureArtifactProbeSchedule` passed
- `swift test --filter AppTests.arcusQueueLanesIncludeModelArtifacts` passed
- `swift test --filter AppTests` failed with unrelated shared-state and catalog-collision issues in broader suite execution

Known failures or follow-up work:
- The broad `swift test --filter AppTests` pass still reports unrelated failures when suites run together, including existing pressure-artifact catalog collisions and pressure warm-job tests that assume isolated database state.
- No follow-up work is required for issue `#118` itself.
- Issue `#119` is next.

### Issue #119 - 06: Change storm-setup/current to consume ready pressure artifacts

Status: Completed

Scope:
- Add a ready-artifact catalog lookup service for the storm-setup pressure path.
- Require an exact ready catalog row for each pressure candidate identity.
- Validate the local artifact path before sampling.
- Load pressure profiles from the ready local file without request-time `.idx` retrieval, byte-range downloading, subset stitching, artifact warming, or synchronous queue execution.
- Preserve the existing surface-source versus Anvil valid-time consistency check.
- Leave the cold acquisition path available only for explicit debug/manual use.

Files changed:
- `Sources/App/StormSetup/PressureArtifactCatalogLookupService.swift`
- `Sources/App/StormSetup/HrrrPressureProfileLoading.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`
- `Tests/AppTests/PressureArtifactCatalogLookupServiceTests.swift`
- `Tests/AppTests/AnvilProfilePreviewProviderTests.swift`
- `Tests/AppTests/AnvilProfilePreviewTestSupport.swift`
- `Tests/AppTests/StormSetupProviderTests.swift`
- `docs/plans/hrrr-pressure-artifact-warmer-progress.md`

Behavior:
- The request path now derives pressure artifact identity from `runTime`, `forecastHour`, `wrfprsf`, and `wrfprsf.defaultFieldSetVersion`.
- Only `.ready` catalog rows with a non-empty `localPath` that resolves to an existing non-zero regular file are accepted.
- Missing, non-ready, missing-file, directory, or zero-byte artifacts are treated as unavailable evidence.
- The surface `storm-setup/current` response still succeeds when pressure evidence is unavailable.
- No stale artifact fallback was added.
- No request-time warming seam was added; the scheduled probe remains the only enqueue path.

Validation run and results:
- `swift test --filter PressureArtifactCatalogLookupServiceTests` passed
- `swift test --filter AnvilProfilePreviewProviderTests` passed
- `swift test --filter StormSetupProviderTests` passed
- `swift test --filter HrrrPressureProfileLoadingTests` passed
- `swift test --filter StormSetupControllerTests` passed
- `swift test` was run and reported unrelated existing failures in broader suites outside the scoped change

Known failures or follow-up work:
- Stale ready-artifact fallback remains deferred to `#120`.
- No new probe or queue abstraction was added for request-time work.
- The cold `DefaultHrrrPressureProfileLoader` path remains available only for explicit debug/manual use.
- Issue `#120` completed this sequence.

### Issue #120 - 07: Add pressure artifact cleanup, expiration, and stale fallback

Status: Completed

Scope:
- Add bounded stale fallback for pressure-artifact lookup after exact misses.
- Preserve exact ready-artifact lookup behavior and request-time no-download behavior.
- Mark stale Anvil evidence as degraded while retaining the computed metric evidence.
- Add worker-owned pressure-artifact expiration and deletion with a one-hour grace period.
- Schedule cleanup work in worker mode on the existing `model-artifacts` lane.

Files changed:
- `Sources/App/StormSetup/PressureArtifactCatalogLookupService.swift`
- `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`
- `Sources/App/StormSetup/AnvilIngredientEvidence.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Sources/App/StormSetup/StormSetupConfiguration.swift`
- `Sources/App/StormSetup/PressureArtifactCleanupService.swift`
- `Sources/App/Jobs/CleanupPressureArtifactsJob.swift`
- `Sources/App/Jobs/CleanupPressureArtifactsScheduledJob.swift`
- `Sources/App/configure.swift`
- `Tests/AppTests/AnvilProfilePreviewTestSupport.swift`
- `Tests/AppTests/PressureArtifactCatalogLookupServiceTests.swift`
- `Tests/AppTests/AnvilProfilePreviewProviderTests.swift`
- `Tests/AppTests/StormSetupProviderTests.swift`
- `Tests/AppTests/StormSetupConfigurationTests.swift`
- `Tests/AppTests/AnvilProfileClientTests.swift`
- `Tests/AppTests/StormSetupWgrib2ClientTests.swift`
- `Tests/AppTests/AppTests.swift`
- `Tests/AppTests/PressureArtifactCleanupServiceTests.swift`
- `docs/plans/hrrr-pressure-artifact-warmer-progress.md`

Behavior:
- Exact pressure artifacts still win over stale artifacts.
- Stale lookup runs only after all exact candidates miss.
- Stale artifacts are limited to ready `wrfprsf` rows at the current field-set version, older than the requested target, and within the configured max stale age.
- Boundary stale age is inclusive at 2 hours.
- The request path still refuses any cold-acquisition fallback.
- Cleanup first expires old ready rows, then deletes only rows that were already expired before the run and whose files are safe to remove.
- Files outside the configured cache root, directories, shared ready/warming paths, and missing files are handled conservatively and idempotently.

Validation run and results:
- `swift test --filter PressureArtifactCleanupServiceTests` passed
- `swift test --filter PressureArtifactCatalogLookupServiceTests` passed
- `swift test --filter AnvilProfilePreviewProviderTests` passed
- `swift test --filter StormSetupProviderTests` passed
- `swift test --filter StormSetupConfigurationTests` passed
- `swift test --filter scheduledDispatchUsesModelArtifactsLane` passed
- `swift test --filter workerBootstrapRegistersPressureArtifactProbeSchedule` passed
- `swift test` still reports unrelated broad-suite failures in shared-state pressure tests when the full suite runs together

Known failures or follow-up work:
- No follow-up work is required for `#120`.
- Broad-suite failures remain unrelated and are not part of this slice.
- The warmer sequence is complete for the currently scoped issues.

### Issue #121 - 08: Add diagnostics for pressure artifact acquisition

Status: Completed

Scope:
- Add structured observability for pressure artifact probe, warm-job, catalog lookup, and request-path evidence resolution.
- Preserve existing lifecycle logs while enriching them with stable artifact-key metadata.
- Add the `wrfsfc` source reconstruction regression guard and preserve the underlying unusable-profile error when an exact artifact is present.
- Reconcile the warmer runbook and progress log with the verified local acquisition behavior.

Files changed:
- `Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift`
- `Sources/App/StormSetup/PressureArtifactWarmingService.swift`
- `Sources/App/StormSetup/PressureArtifactCatalogLookupService.swift`
- `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Tests/AppTests/PressureArtifactDiagnosticsTests.swift`
- `Tests/AppTests/AnvilProfilePreviewProviderTests.swift`
- `docs/plans/hrrr-pressure-artifact-warmer-progress.md`
- `docs/plans/hrrr-pressure-artifact-warmer-runbook.md`

Diagnostics added:
- Probe start, per-candidate `.idx` availability, enqueue, skip, failure, and exhaustion events.
- Warm-job start, skip, inventory fetch, level selection, range selection, cache preparation, validation success/failure, ready transition, and failure events.
- Catalog lookup exact-hit, exact-miss, non-ready, unusable-local-file, stale-hit, stale-skip, and stale-miss events.
- Request-path evidence resolution with `artifactOutcome`, `evidenceStatus`, pressure artifact valid time, selected surface valid time, stale age, and concise reason metadata.

Regression fix:
- Verified `PressureArtifactWarmingService.makeSourceMetadata` already constructs the pressure source with `HrrrRunCandidate(product: payload.product, ...)`.
- Verified the warm-job regression test already proves warm requests use `wrfprsf` URLs.
- Added a regression test that keeps the exact-artifact unusable-profile error intact instead of degrading it into a false “no ready or stale artifact” miss.

Validation performed:
- `swift test --filter PressureArtifactDiagnosticsTests` passed
- `swift test --filter PressureArtifactWarmJobTests` passed
- `swift test --filter HRRRPressureArtifactProbeServiceTests` passed
- `swift test --filter PressureArtifactCatalogLookupServiceTests` passed
- `swift test --filter AnvilProfilePreviewProviderTests` passed
- `swift test --filter StormSetupProviderTests` passed
- `swift test` still reports unrelated broad-suite failures in pressure catalog persistence, pressure cleanup, and a few shared-state pressure tests when the full suite runs together

Local end-to-end validation:
- 37 retained pressure levels
- pressure range `1000` through `100 mb`
- matching pressure, height, temperature, dewpoint, U-wind, and V-wind array counts
- Anvil successfully computed storm motion
- effective layer was legitimately not found for a zero-CAPE profile

Remaining broad-suite failures:
- `swift test` still shows unrelated failures in pressure catalog persistence, pressure cleanup, and shared-state pressure tests when the whole suite is run together.

Final next action:
- Keep issue `#121` closed out at the docs level and move to the next unrelated task only after the broad-suite noise is addressed separately.

---

### Issue #122 - 09: Add claim fencing and stale-state recovery

Status: Completed

Scope:
- Add claim fencing metadata to the pressure artifact catalog.
- Recover stale `pending` rows and expired `warming` rows during probe dispatch.
- Repair unusable `ready` rows by downgrading them back to `pending` and enqueueing one warm job.
- Fence warm-job completion with a per-attempt claim token and lease expiration.

Files changed:
- `Sources/App/Models/Data/PressureArtifactCatalogModel.swift`
- `Sources/App/Migrations/AddClaimFencingToPressureArtifactCatalog.swift`
- `Sources/App/configure.swift`
- `Sources/App/StormSetup/StormSetupConfiguration.swift`
- `Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift`
- `Sources/App/StormSetup/PressureArtifactWarmingService.swift`
- `Tests/AppTests/PressureArtifactCatalogTests.swift`
- `Tests/AppTests/StormSetupConfigurationTests.swift`
- `Tests/AppTests/HRRRPressureArtifactProbeServiceTests.swift`
- `Tests/AppTests/PressureArtifactWarmJobTests.swift`
- `Tests/AppTests/AnvilProfileClientTests.swift`
- `Tests/AppTests/StormSetupWgrib2ClientTests.swift`
- `docs/plans/hrrr-pressure-artifact-warmer-runbook.md`
- `docs/plans/hrrr-pressure-artifact-warmer-progress.md`

Behavior:
- Recent `pending` rows remain duplicate-protected.
- Stale `pending` rows are redispatched.
- Actively leased `warming` rows remain duplicate-protected until the lease expires.
- Expired `warming` leases are reclaimed and redispatched.
- `ready` rows with missing, empty, or non-regular files are downgraded to `pending` and enqueued once.
- Warm-job completion is conditional on both `status = warming` and the same claim token.
- A worker that loses its claim cannot overwrite a newer catalog state.

Validation performed:
- `swift build`
- `swift test --filter StormSetupConfigurationTests`
- `swift test --filter PressureArtifactCatalogTests`
- `swift test --filter HRRRPressureArtifactProbeServiceTests`
- `swift test --filter PressureArtifactWarmJobTests`
- `swift test --filter PressureArtifactCatalogLookupServiceTests`
- `swift test --no-parallel`
- `swift test --parallel --num-workers 8`
- `git diff --check`

Known failures or follow-up work:
- No heartbeat renewal was added; warming and cleanup still assume they complete within the configured lease.
- The broader suite remains noisy outside the scoped pressure-artifact tests, but the targeted lifecycle and configuration filters passed.

## Decisions Made

- The planning docs are the only deliverable for `#114`.
- Sequential execution is mandatory for future warmer work.
- The request path must not perform cold pressure acquisition.
- The existing surface GRIB path is out of bounds for this effort.
- The warmer should be positioned as a separate scheduling concern, not a request-time fallback.

---

## Open Questions

- No open questions remain for the currently scoped warmer issues.

---

## Validation Performed

- Read the existing issue-runbook and progress-doc patterns before writing the new docs.
- Verified the new files exist under `docs/plans`.
- Verified the implementation scope for `#114` is documentation only.
- Verified issue `#121` diagnostics, source metadata, and request-path evidence logging with targeted regression tests.
- Ran and passed the warm-job verification filters for issue `#117`:
  - `swift test --filter PressureArtifactWarmJobTests`
  - `swift test --filter HrrrPressureSubsetGribCacheTests`
  - `swift test --filter PressureArtifactCatalogTests`
- Ran and passed the targeted verification filters for issue `#120`:
  - `swift test --filter PressureArtifactCleanupServiceTests`
  - `swift test --filter PressureArtifactCatalogLookupServiceTests`
  - `swift test --filter AnvilProfilePreviewProviderTests`
  - `swift test --filter StormSetupProviderTests`
  - `swift test --filter StormSetupConfigurationTests`
  - `swift test --filter scheduledDispatchUsesModelArtifactsLane`
  - `swift test --filter workerBootstrapRegistersPressureArtifactProbeSchedule`
- Ran and passed the diagnostics and request-path verification filters for issue `#121`:
  - `swift test --filter PressureArtifactDiagnosticsTests`
- `swift test --filter PressureArtifactWarmJobTests`
- `swift test --filter HRRRPressureArtifactProbeServiceTests`
- `swift test --filter PressureArtifactCatalogLookupServiceTests`
- `swift test --filter AnvilProfilePreviewProviderTests`
- `swift test --filter StormSetupProviderTests`
- Ran `swift test`; the repository still reports unrelated broad-suite failures in pressure catalog persistence, pressure cleanup, and some shared-state pressure tests.

### Follow-on Slice - Cleanup claim fencing and active-deletion exclusion

Status: Completed

Scope:
- Atomically claim expired cleanup candidates with a UUID cleanup token and leased expiration.
- Reclaim abandoned expired cleanup leases by replacing the token and lease atomically.
- Refuse probe and warm claims for expired rows while a cleanup claim is active.
- Fence cleanup completion metadata updates with the same cleanup token used to claim the row.
- Recheck shared-path protection immediately before filesystem removal.
- Preserve path safety, missing-file idempotency, and cleanup recovery after lease expiry.

Files changed:
- `Sources/App/StormSetup/PressureArtifactCleanupService.swift`
- `Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift`
- `Sources/App/StormSetup/PressureArtifactWarmingService.swift`
- `Tests/AppTests/PressureArtifactCleanupServiceTests.swift`
- `Tests/AppTests/HRRRPressureArtifactProbeServiceTests.swift`
- `Tests/AppTests/PressureArtifactWarmJobTests.swift`
- `docs/plans/hrrr-pressure-artifact-warmer-runbook.md`
- `docs/plans/hrrr-pressure-artifact-warmer-progress.md`

Cleanup claim state transitions:
- `expired` with no active cleanup claim -> atomically claimed for deletion with `claim_token` and `lease_expires_at`
- `expired` with an active but expired cleanup lease -> atomically reclaimed with a new cleanup token
- `expired` with an active cleanup lease -> skipped by probe and warm claim SQL
- claimed cleanup row -> filesystem work only while the same token remains fenced
- successful deletion or already-missing file -> clear `local_path`, `byte_size`, `error_summary`, `claim_token`, and `lease_expires_at`
- deletion failure, unsafe path, or non-regular path -> preserve path and size, clear claim token and lease, and keep the row `expired`
- lost ownership during completion -> no metadata mutation and no further filesystem deletion

Validation performed:
- `swift build` passed
- `swift test --filter PressureArtifactCleanupServiceTests` passed
- `swift test --filter HRRRPressureArtifactProbeServiceTests` passed
- `swift test --filter PressureArtifactWarmJobTests` passed
- `swift test --no-parallel` passed

Remaining risks:
- Cleanup still depends on a leased claim rather than a heartbeat-renewed lock, so an overlong deletion can be reclaimed after lease expiry.
- The broader suite still has unrelated shared-state noise outside the targeted cleanup/probe/warm slices.
- Path-safety checks remain intentionally conservative and will keep skipping suspicious paths instead of trying to be clever.

---

## Current Follow-Up

- The currently scoped warmer issues are complete.
- No further cleanup-claim lifecycle work is currently open in the warmer ledger.
- Broader suite isolation issues remain outside the scope of the scoped pressure-artifact lifecycle work.

### Pressure Artifact Test Isolation

Status: Completed

Root cause:
- Seven pressure-artifact suites shared the same PostgreSQL `pressure_artifact_catalog` table.
- Each suite was individually marked `.serialized`, but Swift Testing still ran the suites concurrently.
- The suite helpers all performed `DELETE FROM pressure_artifact_catalog;`, so one suite could wipe another suite's rows or collide on fixed artifact keys during setup or execution.

Isolation design:
- Added `Tests/AppTests/PressureArtifactCatalogTestGate.swift`, a test-only async gate backed by a scoped lock and FIFO waiter queue.
- Wrapped each affected suite's `withApp` helper in the gate so it covers `Application.make`, `configure`, `autoMigrate`, `clearCatalog`, the test body, and `app.asyncShutdown`.
- Kept the existing table cleanup and the existing `.serialized` suite traits.
- Left production source code untouched.

Validation commands and results:
- `swift build` passed.
- `swift test --no-parallel` passed with 327 tests and 0 failures.
- `swift test --parallel --num-workers 8` run 1 failed with 3 issues in unrelated, non-pressure suites.
- `swift test --parallel --num-workers 8` run 2 passed with 327 tests and 0 failures.
- `swift test --parallel --num-workers 8` run 3 passed with 327 tests and 0 failures.
- `swift test --parallel --num-workers 8` run 4 failed with 4 issues in unrelated, non-pressure suites.

### Follow-on Story - Surface HRRR pressure artifact health on the operator dashboard

Status: Completed

Scope:
- Surface current HRRR pressure artifact readiness on the operator dashboard.
- Carry the pressure-artifact catalog through the worker-computed snapshot path.
- Add a model-artifacts dashboard section with readiness, catalog health, and recent rows.
- Preserve the existing dashboard sections and the pressure-warmer flows.

Dashboard files changed:
- `Sources/App/Models/API/OperatorDashboardSnapshotResponse.swift`
- `Sources/App/lib/OperatorDashboardSnapshotRefresher.swift`
- `Sources/App/lib/OperatorDashboardPageRenderer.swift`
- `Tests/AppTests/OperatorDashboardPressureArtifactTests.swift`

Snapshot schema version:
- Incremented `OperatorDashboardStoredSnapshot.currentSchemaVersion` from `2` to `3`.
- Added `StoredPressureArtifactDashboardMetric` with `StoredPressureArtifactDashboardReadinessMetric`, `StoredPressureArtifactDashboardCatalogMetric`, `StoredPressureArtifactDashboardRecentEntriesMetric`, and `StoredPressureArtifactDashboardEntry`.
- Legacy snapshots decode with an empty pressure-artifact metric through `decodeIfPresent(... ) ?? .init()`.

Metrics exposed:
- `modelArtifacts.pressureArtifactReadiness`
- `modelArtifacts.pressureArtifactCatalog`
- `modelArtifacts.recentPressureArtifacts`

SQL filtering policy:
- Fast refresh now queries `pressure_artifact_catalog` only for `product = 'wrfprsf'`.
- Fast refresh also filters to `field_set_version = wrfprsf.defaultFieldSetVersion`.
- Counts, recent rows, and the latest failed row all stay on the current field-set version so obsolete artifacts cannot make current readiness look healthy.
- Recent rows are ordered by `valid_time DESC, updated_at DESC` and limited to five.
- The most recently updated failed row is selected with a separate narrow query.

Visual states implemented:
- `NO DATA` when no current-version rows exist.
- Pending, warming, ready, failed, and expired status pills.
- Missing byte size renders as `n/a`.
- Missing timestamps render as `n/a`.
- Missing error summaries render as `none` or omit the error row on the readiness tile.
- The readiness tile uses the latest current-version artifact row.
- The catalog tile shows counts and the most recent failure timestamp/reason.
- The recent-artifacts table shows five current-version rows without `localPath`.

Validation performed:
- `swift test --filter OperatorDashboardPressureArtifactTests`
- `swift test --filter OperatorDashboardTests`
- `swift test`

Known failures or follow-up work:
- `swift test` still reports unrelated broad-suite failures that predate this change, including shared-state pressure-artifact catalog and cleanup tests, warm-job tests, and some pressure diagnostics lookups when the full suite runs together.
- The dashboard change itself passed in the focused dashboard test slices.
