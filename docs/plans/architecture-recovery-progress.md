# Arcus Signal Architecture Recovery Progress

## Overview

This ledger tracks the sequential, behavior-preserving architecture recovery campaign defined by `docs/plans/architecture-recovery-runbook.md`.

**Epic status:** Active

**Primary GitHub epic:** [#153](https://github.com/justinrooks/arcus-signal/issues/153)

## Global decisions

- One roadmap slice equals one child issue and normally one pull request.
- Issue sequence numbers 01–18 map to roadmap slices 1–16B.
- Shared guardrails live in the runbook; issue bodies contain only issue-specific deltas.
- Required model/reasoning profiles are minimum execution requirements.
- Reliability-policy work remains in existing or separately approved issues.
- No production behavior, public contract, schema, migration order, runtime ownership, or queue lane may change.
- Update only the current issue ledger during implementation.

## Current state summary

- Architecture audit complete at `main` commit `254728f`.
- Recovery roadmap complete with 18 single-purpose slices.
- GitHub epic #153 and child issues #154–#171 are created and linked as sub-issues.
- No recovery implementation has started.
- Existing issues #6, #8, and #13 remain independent.
- First recommended implementation work is the issue sequence below.

## Issue sequence

| Seq. | GitHub issue | Roadmap | Title | Dependencies | Execution profile | Status |
|---:|---|---|---|---|---|---|
| 01 | [#154](https://github.com/justinrooks/arcus-signal/issues/154) | 1 | Characterize notification dequeue lifecycle | None | `gpt-5.6-terra`, medium | Pending |
| 02 | [#155](https://github.com/justinrooks/arcus-signal/issues/155) | 2 | Centralize HRRR surface-to-pressure identity | None | `gpt-5.6-terra`, high | Complete |
| 03 | [#156](https://github.com/justinrooks/arcus-signal/issues/156) | 3 | Extract pure H3 coverage result | None | `gpt-5.6-terra`, high | Pending |
| 04 | [#157](https://github.com/justinrooks/arcus-signal/issues/157) | 4 | Move H3 work before transaction | 03 | `gpt-5.6-sol`, high | Complete |
| 05 | [#158](https://github.com/justinrooks/arcus-signal/issues/158) | 5 | Isolate notification candidate selection | 01 | `gpt-5.6-sol`, high | Complete |
| 06 | [#159](https://github.com/justinrooks/arcus-signal/issues/159) | 6 | Isolate notification ledger persistence | 01, 05 | `gpt-5.6-sol`, high + senior review | Ready for commit |
| 07 | [#160](https://github.com/justinrooks/arcus-signal/issues/160) | 7 | Characterize NWS persistence flow | None | `gpt-5.6-sol`, high | Ready for commit |
| 08 | [#161](https://github.com/justinrooks/arcus-signal/issues/161) | 8 | Extract NWS transaction script | 07 | `gpt-5.6-sol`, high + senior review | Pending |
| 09 | [#162](https://github.com/justinrooks/arcus-signal/issues/162) | 9 | Recover explicit API dependency ownership | 02 | `gpt-5.6-sol`, high | READY FOR COMMIT |
| 10 | [#163](https://github.com/justinrooks/arcus-signal/issues/163) | 10 | Own warm claim/completion SQL | 02 | `gpt-5.6-sol`, high | Pending |
| 11 | [#164](https://github.com/justinrooks/arcus-signal/issues/164) | 11A | Own probe catalog transitions | 10 | `gpt-5.6-sol`, high | READY FOR COMMIT |
| 12 | [#165](https://github.com/justinrooks/arcus-signal/issues/165) | 11B | Own cleanup catalog transitions | 10, 11 | `gpt-5.6-sol`, high + persistence/filesystem review | READY FOR COMMIT |
| 13 | [#166](https://github.com/justinrooks/arcus-signal/issues/166) | 12 | Move request cache I/O to bounded executor | 09 | `gpt-5.6-sol`, high | READY FOR COMMIT |
| 14 | [#167](https://github.com/justinrooks/arcus-signal/issues/167) | 13 | Clarify Storm Setup candidate attempts | 02, 09, 13 | `gpt-5.6-sol`, high | Pending |
| 15 | [#168](https://github.com/justinrooks/arcus-signal/issues/168) | 14 | Own child-process cancellation | 13 recommended | `gpt-5.6-sol`, high + manual runtime review | Pending |
| 16 | [#169](https://github.com/justinrooks/arcus-signal/issues/169) | 15 | Consolidate minimal integration harness | 01, 07 | `gpt-5.6-terra`, high | Pending |
| 17 | [#170](https://github.com/justinrooks/arcus-signal/issues/170) | 16A | Remove verified dead code | 05, 08, 09, 14 | `gpt-5.6-terra`, medium | Pending |
| 18 | [#171](https://github.com/justinrooks/arcus-signal/issues/171) | 16B | Align living architecture docs | 05, 08, 09, 14, 17 | `gpt-5.6-terra`, medium | Pending |

## Existing code map

- Composition: `Sources/App/configure.swift`, `Sources/App/apiRoutes.swift`, `Sources/App/Worker/WorkerRuntime.swift`
- NWS persistence: `Sources/App/Jobs/IngestNWSAlertsJob.swift`
- Targeting: `Sources/App/Jobs/TargetEventRevisionJob.swift`, `Sources/App/lib/DispatchAgent.swift`
- Notification delivery: `Sources/App/Jobs/NotificationSendJob.swift`, `Sources/App/Infrastructure/Notifications`
- Storm Setup and Anvil: `Sources/App/StormSetup/StormSetupProvider.swift`, analysis/preview providers
- Pressure lifecycle: probe, warming, lookup, cleanup services under `Sources/App/StormSetup`
- Blocking work: `Sources/App/Infrastructure/PressureArtifactBlockingWorkExecutor.swift`, `Sources/App/StormSetup/GribAdapter.swift`
- Test integration: `Tests/AppTests`

## Investigation notes

- Core API/worker, outbox, uniqueness, and pressure-fencing architecture is sound.
- Main accidental complexity is hidden composition ownership, mixed orchestration/persistence, duplicated HRRR identity policy, and blocking I/O hidden behind actors.
- NWS lineage and notification dequeue need flow-level characterization before extraction.
- All production queue dispatches currently inherit Vapor Queues’ zero-retry default. This campaign must not change it.
- Notification copy is composed after the per-device ledger claim, not stored in the dispatch-intent outbox.
- Existing #6 and #13 own future outbox/APNs reliability changes.

## Status ledger

### Issue #154 - 01: Characterize notification dequeue lifecycle

- **Status:** Pending
- **Roadmap:** Slice 1
- **Execution profile:** `gpt-5.6-terra`, medium reasoning
- **Dependencies:** None
- **Stop condition:** Real inactive-series `dequeue` path is characterized; no production changes.

### Issue #155 - 02: Centralize HRRR surface-to-pressure identity

- **Status:** Complete
- **Roadmap:** Slice 2
- **Execution profile:** `gpt-5.6-terra`, high reasoning
- **Dependencies:** None
- **Stop condition:** One production mapping owner; ordering and identities unchanged.
- **Files changed:** `Sources/App/StormSetup/HrrrSourceModels.swift`, `Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift`, `Sources/App/StormSetup/HrrrPressureDirectObjectResolver.swift`, `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`, `Sources/App/lib/OperatorDashboardSnapshotRefresher.swift`, and `Tests/AppTests/StormSetupHrrrSourceTests.swift`.
- **Behavior:** `HrrrSurfaceToPressureCandidatePolicy` is the sole owner of the existing prior-hour run, next forecast-hour, `wrfprsf`, default pressure field-set conversion. Probe, direct-object resolution, preview, and dashboard readiness use it without changing iteration, lookup, cancellation, or fallback flow.
- **Validation:** `swift test --filter StormSetupHrrrSourceTests` passed (16 tests); `swift test --filter AnvilProfilePreviewProviderTests` passed (17 tests); `swift test --filter HRRRPressureArtifactProbeServiceTests` passed (10 tests); `swift test --filter OperatorDashboardPressureArtifactTests` passed (9 tests). `git diff --check` is blocked by pre-existing trailing whitespace in `docs/Sql/Device.sql`.
- **Residual risk / handoff:** No slice-owned residual risk. Re-run `git diff --check` after the unrelated `docs/Sql/Device.sql` whitespace is resolved.

### Issue #156 - 03: Extract pure H3 coverage result

- **Status:** Complete
- **Roadmap:** Slice 3
- **Execution profile:** `gpt-5.6-terra`, high reasoning
- **Dependencies:** None
- **Stop condition:** Pure result extracted at the same transaction point.
- **Files changed:** `Sources/App/Jobs/H3CoverageBuilder.swift`, `Sources/App/Jobs/TargetEventRevisionJob.swift`, `Tests/AppTests/H3CoverageBuilderTests.swift`, and `Tests/AppTests/TargetEventRevisionJobFallbackTests.swift`.
- **Behavior:** `H3CoverageBuilder` now owns deterministic polygon/multipolygon cover construction, signed-cell ordering, H3 hashing, and geometry hashing. `TargetEventRevisionJob` retains the same in-transaction invocation, point and cover-failure fallback logs, persistence, outbox insertion, completion, and drain ordering.
- **Validation:** `swift test --filter TargetEventRevisionJobFallbackTests` passed (3 tests); `swift test --filter H3` passed (18 tests); `swift build` passed. Scoped whitespace checks passed; unscoped `git diff --check` remains blocked only by pre-existing trailing whitespace in `docs/Sql/Device.sql:48`.
- **Residual risk / handoff:** Geometry-hash errors still propagate as failed jobs, while H3 cover errors retain UGC fallback. Slice #157 may move this now-characterized builder invocation before the transaction; do not alter persistence or fallback behavior.

### Issue #157 - 04: Move H3 work before transaction

- **Status:** Complete
- **Roadmap:** Slice 4
- **Execution profile:** `gpt-5.6-sol`, high reasoning
- **Dependencies:** 03
- **Stop condition:** Transaction contains persistence only; output unchanged.
- **Files changed:** `Sources/App/Jobs/TargetEventRevisionJob.swift`, `Tests/AppTests/TargetEventRevisionJobFallbackTests.swift`, and `docs/plans/architecture-recovery-progress.md`.
- **Behavior:** H3 coverage and hashing now execute once before transaction creation. Supported coverage enters the unchanged geolocation/outbox transaction; unsupported-point and cover-failure results bypass it and retain the existing completion and UGC drain flow.
- **Validation:** `swift test --filter TargetEventRevisionJobFallbackTests` passed (5 tests); `swift test --filter H3` passed (19 tests); `swift test --no-parallel` passed (437 tests). The scoped whitespace check passed; unscoped `git diff --check` remains blocked only by pre-existing trailing whitespace in `docs/Sql/Device.sql:48`.
- **Residual risk / handoff:** No known behavior change beyond transaction placement. The internal `@Sendable` builder seam proves supported coverage reaches persistence without recomputation or normalization and cover failure creates no H3 persistence effects.

### Issue #158 - 05: Isolate notification candidate selection

- **Status:** Complete
- **Roadmap:** Slice 5
- **Execution profile:** `gpt-5.6-sol`, high reasoning
- **Dependencies:** 01
- **Stop condition:** Candidate SQL has one owner; send orchestration unchanged.
- **Files changed:** `Sources/App/Models/Notification/NotificationCandidateStore.swift`, `Sources/App/Jobs/NotificationSendJob.swift`, `Tests/AppTests/NotificationSendJobCandidateQueryTests.swift`, and `docs/plans/architecture-recovery-progress.md`.
- **Behavior:** `NotificationCandidateStore` now solely owns the H3/UGC candidate row and queries. `NotificationSendJob` retains lifecycle and target-mode orchestration through a trailing defaulted store dependency. Candidate selection, cutoff, exclusions, matching, and sequential delivery are unchanged; quoted label aliases repair previously silent `nil` decoding without changing current notification copy.
- **Validation:** `swift test --filter NotificationSendJobCandidateQueryTests` passed (3 tests); `swift test --filter NotificationSendJobDeliveryBoundaryTests` passed (4 tests); `swift test --filter LocationFreshnessPolicyTests` passed (13 tests). The scoped whitespace check passed; unscoped `git diff --check` remains blocked only by pre-existing trailing whitespace in `docs/Sql/Device.sql:48`.
- **Residual risk / handoff:** County and fire-zone labels now decode from populated presence rows, but `NotificationEngine` currently uses generic area wording and ignores them. Issue #159 retains ownership of all ledger claim/completion extraction; no ledger, delivery, retry, queue, schema, or contract behavior moved here.

### Issue #159 - 06: Isolate notification ledger persistence

- **Status:** Ready for commit
- **Roadmap:** Slice 6
- **Execution profile:** `gpt-5.6-sol`, high reasoning with senior human review
- **Dependencies:** 01, 05
- **Stop condition:** Claim/completion persistence is isolated without retry or delivery changes.
- **Files changed:** `Sources/App/Models/Notification/NotificationDeliveryStore.swift`, `Sources/App/Jobs/NotificationSendJob.swift`, `Tests/AppTests/NotificationLedgerFreshnessPersistenceTests.swift`, `Tests/AppTests/NotificationSendJobDeliveryBoundaryTests.swift`, and `docs/plans/architecture-recovery-progress.md`.
- **Behavior:** `NotificationDeliveryStore` now solely owns the unchanged atomic ledger claim SQL and sent/failed completion mutation. `NotificationSendJob` retains sequential candidate orchestration, copy/debug/APNs work, APNs error interpretation, logging, and metrics through a trailing defaulted store dependency. Duplicate, missing-row, and generic-failure behavior remain unchanged.
- **Validation:** `swift test --filter NotificationLedgerFreshnessPersistenceTests` passed (3 tests); `swift test --filter NotificationSendJobDeliveryBoundaryTests` passed (6 tests); `swift test --filter NotificationMissedDecisionPersistenceTests` passed (2 tests); `swift test --filter NotificationEngineTests` passed (8 tests). Independent defect review found one low-severity job-boundary duplicate-claim test gap; the test auditor reported no findings. The gap was accepted, fixed, and confirmed resolved by focused re-review with no new defect.
- **Residual risk / handoff:** Claim-before-APNs remains intentionally at-most-once: abandoned or failed claims are not reclaimed. Independent review confirmed exact claim SQL preservation, sent missing-row no-op behavior, failed missing-row `404`, and generic failure leaving `apns_error_code` unchanged.

### Issue #160 - 07: Characterize NWS persistence flow

- **Status:** Ready for commit
- **Roadmap:** Slice 7
- **Execution profile:** `gpt-5.6-sol`, high reasoning
- **Dependencies:** None
- **Stop condition:** Lineage, outbox, duplicate, merge, and rollback paths are pinned.
- **Files changed:** `Sources/App/Jobs/IngestNWSAlertsJob.swift`, `Tests/AppTests/NWSIngestPersistenceFlowTests.swift`, and this progress entry.
- **Behavior:** Production persistence behavior is unchanged. `PersistResult` and `persistArcusEvents` now have module-internal visibility for `@testable` access; the method body, helper visibility, transaction ownership, post-commit drains, and cleanup remain in place.
- **Coverage:** Five serialized PostgreSQL tests pin new polygon/point/nil dispatch combinations, duplicate-revision idempotency, newer/older snapshot ordering, deterministic referenced-series merge including the UUID tie-break, lineage/outbox/geolocation reconciliation, loser tombstoning, and complete late-failure batch rollback.
- **Validation:** `swift test --filter NWSIngestPersistenceFlowTests` passed (5 tests); `swift test --filter NWSAlertLifecycleTests` passed (2 tests); `swift test --filter ArcusEventFingerprintTests` passed (2 tests). Independent review accepted and resolved two missing series-state assertions and one deterministic merge setup defect; focused re-review found no remaining affected-area finding. Human review completed with no suggested changes, and the final independent reviewer and test auditor reported no actionable findings. A proposed `dequeue`-owned rollback test was rejected because Slice 7 explicitly prescribes the callable persistence seam and sentinel transaction shape. The scoped whitespace check passed; unscoped `git diff --check` remains blocked only by pre-existing trailing whitespace in `docs/Sql/Device.sql:48`.
- **Residual risk / handoff:** The suite requires the existing local PostgreSQL integration-test service and intentionally excludes queue drains, Redis, APNs, live NWS, lifecycle cleanup, and fixture replay. Issue #161 may extract the now-characterized transaction script but must preserve the tested operation order and full-batch transaction.

### Issue #161 - 08: Extract NWS transaction script

- **Status:** Ready for commit
- **Roadmap:** Slice 8
- **Execution profile:** `gpt-5.6-sol`, high reasoning with senior human review
- **Dependencies:** 07
- **Stop condition:** One named persistence operation preserves the batch transaction.
- **Files changed:** `Sources/App/Services/NWSIngestPersistence.swift`, `Sources/App/Jobs/IngestNWSAlertsJob.swift`, `Tests/AppTests/NWSIngestPersistenceFlowTests.swift`, `Tests/AppTests/IngestNWSAlertsJobTargetingDecisionTests.swift`, and this progress entry.
- **Behavior:** `NWSIngestPersistence` now owns the unchanged canonical event persistence, lineage resolution and merge reconciliation, snapshot mutation, and target/UGC outbox insertion script. `IngestNWSAlertsJob.dequeue` still resolves the complete batch first, opens the single full-batch transaction around that operation, drains target then UGC outboxes post-commit, runs cleanup in a separate transaction, and records best-effort sweep telemetry with the same `PersistResult` counters.
- **Coverage:** The five PostgreSQL persistence-flow scenarios and four geometry targeting-decision cases now exercise `NWSIngestPersistence` directly. Their persisted-state assertions, forced late-failure rollback sentinel, and decision inputs are unchanged.
- **Validation:** Pre-change `swift test --filter NWSIngestPersistenceFlowTests` passed (5 tests). Post-change `swift test --filter NWSIngestPersistenceFlowTests` passed (5 tests); `swift test --filter NWS` passed (11 tests); `swift test --filter TargetEventRevisionJobFallbackTests` passed (5 tests); and `swift test --no-parallel` passed (445 tests across 58 suites). Human review completed with no suggested changes. The independent defect reviewer and test auditor reported no actionable findings; their focused reruns passed the 5 persistence-flow, 4 targeting-decision, 11 NWS, and 5 target-fallback tests. The issue-scoped whitespace check and separate untracked new-file check passed; unscoped `git diff --check` remains blocked only by the pre-existing `docs/Sql/Device.sql:48` trailing whitespace.
- **Residual risk / handoff:** This is a structural ownership move with no transaction, Fluent operation-order, lifecycle, dispatcher, schema, or runtime-role change. Complete `dequeue` orchestration, queue drains, cleanup, and telemetry still lack one deterministic end-to-end test; that documented #160 limitation predates this slice and remains out of scope.

### Issue #162 - 09: Recover explicit API dependency ownership

- **Status:** READY FOR COMMIT
- **Roadmap:** Slice 9
- **Execution profile:** `gpt-5.6-sol`, high reasoning
- **Dependencies:** 02
- **Stop condition:** API graph is installed once with stable lifetime; worker ownership unchanged.
- **Files changed:** `Sources/App/configure.swift`, `Sources/App/StormSetup/APIDependencyComposition.swift`, the three Storm Setup/Anvil provider files, `Tests/AppTests/APIDependencyCompositionTests.swift`, and this progress entry.
- **Behavior:** `installAPIRequestDependencies(on:)` now installs the API request-provider graph once in preview → analysis → Storm Setup order before route registration. Existing providers survive configuration and feed downstream defaults. Worker bootstrap leaves all three providers unconfigured. Provider getters no longer construct defaults; unconfigured access returns provider-specific configuration failures without mutating storage.
- **Coverage:** Added six deterministic composition tests covering default API installation and retained storage, all three preconfigure overrides, preview-only and analysis-only overrides participating in downstream default construction, worker non-installation, and explicit missing-provider failures.
- **Validation:** `swift test --filter AppTests.AppTests` passed (29 tests); `swift test --filter AppTests.APIDependencyCompositionTests` passed (6 tests); the requested Storm Setup controller, Anvil preview controller, Anvil analysis controller, and Storm Setup provider filters passed (6, 9, 5, and 18 tests). The exact broad `swift test --filter AppTests` command selected the full package and failed one unrelated parallel PostgreSQL migration test; the same command already failed once before this slice, and `swift test --filter DevicePresenceMigrationTests` passed alone (1 test). The strict-concurrency build passed with one pre-existing deprecation warning. The issue-scoped tracked diff check and new-file whitespace scan passed; unscoped `git diff --check` remains blocked only by the pre-existing `docs/Sql/Device.sql:48` trailing whitespace. Human review completed with no suggested changes. The independent defect reviewer reported no actionable defects; the test auditor identified the missing analysis-only override coverage and stale summary status, both were accepted and resolved, and both focused re-reviews reported no actionable findings.
- **Residual risk / handoff:** Default providers remain value-type wrappers around their existing actor/service dependencies, so stable lifetime is established through `Application.storage`, not reference identity of the wrapper itself. The default Storm Setup provider exposes its immutable analysis dependency only at module-internal visibility for deterministic composition testing. No provider contract, route, cache, environment, worker schedule, or external response behavior changed. Ready for commit.

### Issue #163 - 10: Own warm claim/completion SQL

- **Status:** READY FOR COMMIT
- **Roadmap:** Slice 10
- **Execution profile:** `gpt-5.6-sol`, high reasoning
- **Dependencies:** 02
- **Stop condition:** Warm transition SQL has one owner with identical predicates.
- **Files changed:** `Sources/App/Models/Data/PressureArtifactCatalogStore.swift`, `Sources/App/StormSetup/PressureArtifactWarmingService.swift`, `Tests/AppTests/PressureArtifactWarmJobTests.swift`, and this progress entry.
- **Behavior:** A concrete, stateless `PressureArtifactCatalogStore` now owns ensure-row, conditional warm claim, claim-fenced ready completion, and claim-fenced failed completion. `PressureArtifactWarmingService` computes the same clamped lease expiration, delegates those four transitions at the same orchestration points, and retains current-row skip lookup, acquisition, validation, cancellation, claim-loss logging, and error propagation behavior. The moved SQL preserves its artifact-key predicates, claim eligibility, mutations, fencing, `RETURNING` behavior, and follow-up model lookup.
- **Coverage:** Retargeted direct warm-claim, exact-key, and stale-token ready-completion tests to the store. Added deterministic coverage proving an old token cannot mark failed or alter the newer owner’s token, lease, status, or error state.
- **Validation:** Pre-change `swift test --filter PressureArtifactWarmJobTests` passed (17 tests) and `swift test --filter PressureArtifactCatalogTests` passed (9 tests). Post-change `swift test --filter PressureArtifactWarmJobTests` passed (18 tests); `swift test --filter PressureArtifactCatalogTests` passed (9 tests); `swift test --parallel --num-workers 8 --filter PressureArtifactWarmJobTests` passed (18 tests); and `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency` passed with only the pre-existing `ArcusEvent.title` deprecation warning. The issue-scoped tracked diff check and four-file trailing-whitespace scan passed; unscoped `git diff --check` remains blocked only by the pre-existing `docs/Sql/Device.sql:48` trailing whitespace.
- **Review:** Human review completed with no suggested changes. The independent defect reviewer reported no actionable findings and independently reran the warm suite (18 tests passed). The independent test auditor reported no actionable findings, mapped every acceptance criterion to coverage, and found the evidence sufficient for commit. There were no disagreements, accepted findings, fixes, or affected-area re-review requirements. Final full-diff review found no SQL, concurrency, cancellation, persistence, or scope drift.
- **Residual risk / handoff:** The pre-existing claim-update/follow-up-lookup race window is intentionally preserved rather than redesigned. Probe, cleanup, lookup, dashboard, model, schema, migration, warm-job composition, cache, HTTP, validation, scheduler, and queue behavior are unchanged. Ready for commit.

### Issue #164 - 11: Own probe catalog transitions

- **Status:** READY FOR COMMIT
- **Roadmap:** Slice 11A
- **Execution profile:** `gpt-5.6-sol`, high reasoning
- **Dependencies:** 10
- **Stop condition:** Probe transition SQL has one owner; discovery unchanged.
- **Files changed:** `Sources/App/Models/Data/PressureArtifactCatalogStore.swift`, `Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift`, `Tests/AppTests/HRRRPressureArtifactProbeServiceTests.swift`, and this progress entry.
- **Behavior:** The existing concrete, stateless catalog store now owns warmable-row claim/upsert, unusable-ready recovery, remote-unavailability persistence, and probe-failure persistence. The probe injects that store through a trailing defaulted initializer parameter, passes persistence-ready summaries, and retains candidate discovery and ordering, remote probing, model lookup, ready-file validation, recovery decisions, dispatch gating, cancellation, logging, and the existing `databaseNotSQL` error contract. The moved SQL preserves its predicates, bindings, mutations, `NOW()`, and `RETURNING` behavior.
- **Coverage:** Strengthened the unavailable-conflict scenario to prove only `last_checked_at` changes while status, source, error, artifact metadata, claim token, and lease remain intact. Added deterministic dispatch-failure coverage proving the row becomes failed, artifact/fencing fields clear, the same reflected error is stored, and the original error is rethrown.
- **Validation:** Pre-change `swift test --filter HRRRPressureArtifactProbeServiceTests` passed (10 tests), and the characterization-expanded suite passed before the SQL move (11 tests). Post-change probe tests passed (11 tests), `swift test --filter PressureArtifactDiagnosticsTests` passed (9 tests), and `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency` passed with only the pre-existing `ArcusEvent.title` deprecation warning. Across three `swift test --parallel --num-workers 8` runs, one passed all 453 tests and two reported one issue; the reproducible unrelated failure was `DevicePresenceMigrationTests.rollback keeps expanded source values valid` with a PostgreSQL error, while that suite passed alone (1 test).
- **Review:** Human review completed with no suggested changes. The independent defect reviewer reported no actionable findings after comparing all four moved transitions and independently reran the probe and diagnostics suites. The independent test auditor reported no actionable findings, mapped every acceptance criterion to sufficient evidence, and independently reran both focused suites. There were no disagreements, accepted findings, fixes, or affected-area re-review requirements. The auditor's two non-blocking test uncertainties were rejected as unsupported because `databaseNotSQL` and first-available control flow remain structurally unchanged; the unrelated parallel migration failure was deferred out of scope. Final full-diff review found no predicate, mutation, dispatch-order, candidate-order, cancellation, logging, concurrency, persistence, or scope drift.
- **Residual risk / handoff:** Full parallel validation retains a pre-existing database-isolation failure outside pressure artifacts. Cleanup, warming, lookup, dashboard, model, schema, migration, queue, cache, HTTP, filesystem, and diagnostics-copy behavior are unchanged. No #165 work was included. Ready for commit.

### Issue #165 - 12: Own cleanup catalog transitions

- **Status:** READY FOR COMMIT
- **Roadmap:** Slice 11B
- **Execution profile:** `gpt-5.6-sol`, high reasoning with persistence/filesystem-safety review
- **Dependencies:** 10, 11
- **Stop condition:** Cleanup transition SQL has one owner; path safety unchanged.
- **Files changed:** `Sources/App/Models/Data/PressureArtifactCatalogStore.swift`, `Sources/App/StormSetup/PressureArtifactCleanupService.swift`, `Tests/AppTests/PressureArtifactCleanupServiceTests.swift`, and this progress entry.
- **Behavior:** The existing concrete, stateless catalog store now owns ready-row expiration, deletion claim, successful and failed cleanup completion, claim release, and ownership recheck. Cleanup injects the store through a trailing defaulted initializer parameter, delegates each transition at its original call position, and retains expiration logging, expired/protected-row reads, canonicalization, root confinement, protected-path rechecks, regular-file validation, bounded filesystem work, deletion, cancellation, and orchestration. Newly expired rows still wait for a later run because the service loads expired rows before delegating ready-row expiration.
- **Coverage:** Retargeted direct claim and stale-success-token tests to the store. Added store-level fencing coverage proving stale tokens cannot record failure or release a newer claim. Added deterministic `beforePhysicalRemovalHook` coverage proving an ownership change after path validation prevents deletion and preserves the newer token and lease.
- **Validation:** Pre-change `swift test --filter PressureArtifactCleanupServiceTests` passed (12 tests). Post-change cleanup tests passed (14 tests), `swift test --filter PressureArtifactDiagnosticsTests` passed (9 tests), and `swift test --parallel --num-workers 8` passed all 455 tests across 59 suites; the known unrelated `DevicePresenceMigrationTests` isolation failure did not reproduce. The four-file scoped whitespace check passed. Unscoped `git diff --check` remains blocked only by the pre-existing `docs/Sql/Device.sql:48` trailing whitespace.
- **Review:** Human review completed with no suggested changes. The independent defect reviewer reported no actionable findings after comparing the moved SQL byte-for-byte and reviewing persistence fencing, filesystem ordering, cancellation, and scope. The independent test auditor reported no actionable findings, mapped every acceptance criterion to deterministic evidence, and independently reran the cleanup and diagnostics suites. There were no disagreements or code fixes. The reviewer's stale lifecycle-metadata uncertainty was accepted and resolved by this update. The auditor's lack of an independent full-suite rerun was already resolved by the primary full run; its non-blocking cancellation-test uncertainty was rejected as unsupported because cancellation code and ordering are unchanged. Final full-diff review found no path-check ordering, ownership-recheck, physical-deletion, successful-completion, cancellation, timing, predicate, token, lease, state, or scope drift.
- **Residual risk / handoff:** The pre-existing unrelated changes in `docs/Sql/Device.sql`, `docs/audits/weekly-bug-scan.md`, and `docs/audits/weekly-test-gap-audit.md` were preserved and excluded. Warm, probe, lookup, dashboard, model, schema, migration, scheduler, queue, cache, HTTP, and #166 behavior are unchanged. No branch, commit, push, or pull request was created. Ready for commit.

### Issue #166 - 13: Move request cache I/O to bounded executor

- **Status:** READY FOR COMMIT
- **Roadmap:** Slice 12
- **Execution profile:** `gpt-5.6-sol`, high reasoning
- **Dependencies:** 09
- **Stop condition:** Surface/snapshot cache filesystem work uses the existing executor.
- **Files changed:** `Sources/App/Infrastructure/PressureArtifactBlockingWorkExecutor.swift`, `Sources/App/StormSetup/GribSubsetCache.swift`, `Sources/App/StormSetup/StormSetupSnapshotCache.swift`, `Sources/App/StormSetup/APIDependencyComposition.swift`, `Sources/App/StormSetup/StormSetupProvider.swift`, `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`, `Tests/AppTests/PressureArtifactBlockingWorkTestSupport.swift`, `Tests/AppTests/StormSetupGribSubsetCacheTests.swift`, `Tests/AppTests/StormSetupSnapshotCacheTests.swift`, and this progress entry.
- **Behavior:** Both request cache actors now require the existing blocking-work executor. GRIB directory creation, hit reads, metadata decoding/encoding, checksum validation/calculation, atomic persistence, invalidation, and partial-write cleanup run in cohesive bounded operations. Snapshot load/decode/validation/invalidation and surface-only encode/atomic store do the same. Each cache uses one instance-owned NIO critical section inside executor closures to preserve the actor's former synchronous filesystem serialization across actor reentrancy. API composition constructs one executor from `Application.threadPool` and passes it through both application-based provider constructors; worker ownership remains unchanged. Cache keys, paths, formats, expiry, result/error contracts, HTTP cancellation checks, fallback behavior, and snapshot assessment recomputation are unchanged.
- **Coverage:** Reused the real NIO executor and counting wrapper. GRIB coverage proves executor use across miss/write, hit/read/checksum, corrupt-entry invalidation/redownload, and metadata-write failure cleanup. A gated three-thread executor test proves the critical section serializes work, releases after cancellation, and remains usable. Snapshot coverage proves executor use across store, load, and expired-entry invalidation while retaining surface-only records, baseline recomputation, corrupt/truncated handling, and atomic writes.
- **Validation:** Pre-change GRIB cache tests passed 11 tests and snapshot cache tests passed 14 tests. Final `swift test --filter StormSetupGribSubsetCacheTests` passed 13 tests, `swift test --filter StormSetupSnapshotCacheTests` passed 14 tests, `swift test --filter APIDependencyCompositionTests` passed 6 tests, and `swift test --filter StormSetupProviderTests` passed 18 tests. `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency` passed with only the pre-existing deprecated `ArcusEvent.title` warning. The scoped whitespace check passed. Unscoped `git diff --check` remains blocked only by the pre-existing `docs/Sql/Device.sql:48` trailing whitespace.
- **Review:** Human review completed with no suggested changes. The independent defect review identified a medium actor-reentrancy filesystem-overlap defect, while the test audit did not identify that defect; architecture review accepted it and approved the issue-local per-cache critical section. Both reviewers identified the missing metadata-write cleanup characterization. Both findings were accepted and fixed. Focused defect re-review and test re-audit returned GO with no actionable findings; both confirmed the serialization and cleanup findings resolved. Final full-diff review found no direct cache filesystem, JSON, or checksum work outside bounded operations and no cache identity, atomic-write, cleanup, error-path, cancellation-contract, provider-lifetime, or worker-ownership drift.
- **Residual risk / handoff:** Executor work remains non-preemptive, with cancellation observed before and after each bounded operation. Critical sections coordinate each cache instance, matching prior actor ownership; cross-instance access to the same cache root remains a pre-existing watchlist item outside #166. The pre-existing unrelated changes in `docs/Sql/Device.sql`, `docs/audits/weekly-bug-scan.md`, and `docs/audits/weekly-test-gap-audit.md` were preserved and excluded. No commit, push, or pull request was created.

### Issue #167 - 14: Clarify Storm Setup candidate attempts

- **Status:** Pending
- **Roadmap:** Slice 13
- **Execution profile:** `gpt-5.6-sol`, high reasoning
- **Dependencies:** 02, 09, 13
- **Stop condition:** Candidate/evidence decisions are explicit; response behavior is identical.

### Issue #168 - 15: Own child-process cancellation

- **Status:** Pending
- **Roadmap:** Slice 14
- **Execution profile:** `gpt-5.6-sol`, high reasoning with manual runtime review
- **Dependencies:** 13 recommended
- **Stop condition:** Parent cancellation terminates and drains the child deterministically.

### Issue #169 - 16: Consolidate minimal integration harness

- **Status:** Pending
- **Roadmap:** Slice 15
- **Execution profile:** `gpt-5.6-terra`, high reasoning
- **Dependencies:** 01, 07
- **Stop condition:** Shared lifecycle setup exists without a fixture framework or parallelization campaign.

### Issue #170 - 17: Remove verified dead code

- **Status:** Pending
- **Roadmap:** Slice 16A
- **Execution profile:** `gpt-5.6-terra`, medium reasoning
- **Dependencies:** 05, 08, 09, 14
- **Stop condition:** Only proven-unused code/comments are removed.

### Issue #171 - 18: Align living architecture docs

- **Status:** Pending
- **Roadmap:** Slice 16B
- **Execution profile:** `gpt-5.6-terra`, medium reasoning
- **Dependencies:** 05, 08, 09, 14, 17
- **Stop condition:** Living docs describe implemented guarantees without claiming deferred fixes.

## Verification ledger

Planning verification on 2026-07-28:

- GitHub GraphQL confirmed epic #153 has 18 true sub-issues, #154–#171.
- Every child body contains the parent epic, required reading, execution model, reasoning level, and stop condition.
- The epic body contains all 18 ordered checklist entries.
- The local issue sequence and status ledger each contain 18 exact issue numbers.
- Placeholder scan found no stale issue/epic placeholders.
- Markdown whitespace and code-fence checks passed for the runbook and progress ledger.
- No Swift build or test ran because this campaign changes planning documents and GitHub metadata only.

## Handoff notes

- Start with issue 01.
- Do not implement later issues merely because they have no hard dependency; the campaign is deliberately review-sequenced.
- Read only the current issue’s roadmap/audit sections.
- Record actual files, commands, failures, risks, and next handoff in the current status-ledger section.
- Stop systematic recovery when the runbook’s target conditions hold.
