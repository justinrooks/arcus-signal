# Arcus Signal Architecture Recovery Roadmap

**Source audit:** `docs/audits/architecture-recovery-audit.md`

**Baseline:** `main` at `254728f` on 2026-07-28

**Intent:** Ordered, behavior-preserving architecture recovery

## Guardrails

Every slice in this roadmap preserves:

- API and worker runtime ownership.
- Existing queue lane names and handoff order.
- Public endpoint and ArcusCore contracts.
- Database schema and migration order.
- NWS series/revision lineage and current-snapshot ordering.
- H3 resolution, signed `Int64` representation, polygon holes, UGC fallback, and unchanged-geometry dispatch.
- Target and notification outbox uniqueness and replay behavior.
- Per-device ledger deduplication, missed decisions, debug records, attempt records, copy, lifecycle gates, and freshness rules.
- HRRR candidate ordering, surface→pressure valid-time equivalence, exact-before-stale lookup, cache identity, field-set version, and degraded response results.
- Pressure claim tokens, leases, conditional completion, validation, cleanup confinement, and protected-path behavior.
- Storm Setup sampled-cache behavior, current Anvil refresh, exact/stale evidence exposure, canonical ingredients, and tornado interpretation.
- AirNow request, cache, normalization, and 503 degradation behavior.

The roadmap deliberately excludes feature changes. In particular, queue retries, APNs retry/backoff, ledger reclaim, outbox payload storage, schema changes, and migration cleanup require separate approval and design.

## Sequencing principles

1. Add missing characterization before moving the behavior it protects.
2. Extract pure, repeated policy before persistence or composition changes.
3. Move one state-machine boundary at a time, preserving exact SQL.
4. Keep one visible orchestrator per flow.
5. Do not combine structural refactoring with copy, lifecycle, weather-rule, fallback, or response changes.
6. Stop each PR at one reviewable architectural purpose.

## Slice 1 — Characterize the notification dequeue lifecycle boundary

**Goal**

Execute the real inactive/expired early-return path in `NotificationSendJob.dequeue` and pin its persisted attempt result.

**Why now**

Notification delivery is the highest-risk refactor area, and the current weekly test-gap audit identifies this exact missing boundary. A test-only slice creates a safe baseline without forcing a production seam prematurely.

**Exact scope**

- Add a database-backed test that seeds a current but inactive series.
- Execute `NotificationSendJob.dequeue` with a recording sender.
- Assert zero candidate resolution/APNs sends and exactly one `NotificationSendAttemptModel` with `inactiveOrExpiredSeries`.
- Add one active control only if needed to prove the test reaches the intended branch.

**Explicit non-goals**

- No production changes.
- No candidate-query refactor.
- No retry or ledger behavior changes.
- No generic integration-test framework.

**Production files likely affected**

- None.

**Test files likely affected**

- `Tests/AppTests/NotificationSendJobDeliveryBoundaryTests.swift`
- A small existing test-support file only if table bootstrap would otherwise be duplicated.

**Characterization coverage required first**

- This slice is the characterization.

**Preserved invariants**

- Lifecycle gate remains before candidate resolution and APNs.
- Explicit terminal reasons remain eligible.
- Attempt fields and no-op reason remain unchanged.

**Acceptance criteria**

- Test executes `dequeue`, not only `deliveryNoOpReason`.
- Sender count is zero.
- Candidate resolution is false and all counts are zero.
- Exactly one persisted attempt records `inactiveOrExpiredSeries`.
- Existing notification suites remain unchanged.

**Validation commands**

```bash
swift test --filter NotificationSendJobDeliveryBoundaryTests
swift test --filter NotificationSendJobFreshnessDecisionTests
git diff --check
```

**Dependencies**

- None.

**Estimated risk**

- Low.

**Recommended implementation model**

- `gpt-5.6-terra`, medium reasoning.

## Slice 2 — Establish one HRRR surface-to-pressure identity policy

**Goal**

Replace four identical production implementations of surface→pressure candidate conversion with one pure named policy.

**Why now**

This is the clearest accidental-complexity hotspot and the safest production recovery. It removes a drift vector before further Storm Setup, pressure, or dashboard work.

**Exact scope**

- Add a small pure type or `HrrrRunCandidate` helper in the Storm Setup source-selection area.
- Preserve: prior-hour run time, forecast hour plus one, same valid time, `wrfprsf`, same model/domain, and default pressure field-set version.
- Adopt it in:
  - `HRRRPressureArtifactProbeService`
  - `DefaultHrrrPressureDirectObjectResolver`
  - `DefaultAnvilProfilePreviewProvider`
  - `OperatorDashboardSnapshotRefresher`
- Add a focused mapping matrix across multiple surface forecast hours and a UTC date boundary.

**Explicit non-goals**

- No candidate reordering.
- No lookup/fallback change.
- No field-set version change.
- No dashboard or response contract change.
- Do not rewrite test helpers unless they can directly call the production policy.

**Production files likely affected**

- `Sources/App/StormSetup/HrrrSourceModels.swift` or one new focused mapping file
- `Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift`
- `Sources/App/StormSetup/HrrrPressureDirectObjectResolver.swift`
- `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`
- `Sources/App/lib/OperatorDashboardSnapshotRefresher.swift`

**Characterization coverage required first**

- Add the mapping matrix before replacing call sites.
- Existing exact/stale selection tests must remain green.

**Preserved invariants**

- Exact surface/pressure valid-time equivalence.
- Existing candidate order.
- Current product and field-set identity.
- Dashboard readiness matches request lookup.

**Acceptance criteria**

- One production definition of the mapping remains.
- All four consumers use it.
- No response fixture, catalog key, URL, or log identity changes.
- No unrelated provider cleanup.

**Validation commands**

```bash
swift test --filter StormSetupHrrrSourceTests
swift test --filter AnvilProfilePreviewProviderTests
swift test --filter HRRRPressureArtifactProbeServiceTests
swift test --filter OperatorDashboardPressureArtifactTests
git diff --check
```

**Dependencies**

- None.

**Estimated risk**

- Low.

**Recommended implementation model**

- `gpt-5.6-terra`, high reasoning.

## Slice 3 — Extract the pure H3 coverage result

**Goal**

Separate deterministic H3 coverage/hash computation from geolocation persistence without changing when it runs.

**Why now**

Targeting is a compact, well-tested vertical flow. A pure seam improves execution clarity and prepares a later transaction-duration improvement without risking persistence in the first move.

**Exact scope**

- Introduce an immutable coverage result containing sorted signed cells, H3 hash, geometry hash, and supported/unsupported outcome as appropriate.
- Move `buildH3Cover`, ring conversion, cell hashing, and geometry hashing out of `TargetEventRevisionJob`.
- Keep the builder call inside `persistGeolocation` and therefore inside the current transaction.
- Add direct polygon, multipolygon, hole, point, stable hash, and signed-cell tests.

**Explicit non-goals**

- Do not move computation outside the transaction yet.
- Do not change H3 resolution.
- Do not alter fallback or outbox flow.
- Do not change geolocation schema or hash encoding.

**Production files likely affected**

- `Sources/App/Jobs/TargetEventRevisionJob.swift`
- One new focused file under `Sources/App/Infrastructure` or a targeting-specific existing directory

**Characterization coverage required first**

- Golden cell/hash expectations for representative geometry.
- Existing fallback/replay tests.

**Preserved invariants**

- Resolution 8.
- Signed `Int64(bitPattern:)`.
- Hole handling, deduplication, sorting, hashes.
- Point/error → UGC.
- Unchanged geometry still enqueues H3.

**Acceptance criteria**

- Job reads as persistence/orchestration around a pure coverage result.
- Existing transaction boundary is unchanged.
- Existing outbox and completion ordering is unchanged.

**Validation commands**

```bash
swift test --filter TargetEventRevisionJobFallbackTests
swift test --filter H3
swift build
git diff --check
```

**Dependencies**

- None.

**Estimated risk**

- Low.

**Recommended implementation model**

- `gpt-5.6-terra`, high reasoning.

## Slice 4 — Move H3 computation before the database transaction

**Goal**

Shorten the target transaction so it contains only geolocation/outbox persistence.

**Why now**

Slice 3 creates and characterizes the pure result. Only then is transaction timing safe to change.

**Exact scope**

- Compute the characterized coverage result before `db.transaction`.
- Pass it into a persistence method.
- Preserve fallback logging, completion state, and drain order.
- Add a test seam proving persistence receives a precomputed result; do not use timing assertions.

**Explicit non-goals**

- No background task or parallel H3 computation.
- No queue/payload changes.
- No H3 cache.
- No persistence repository beyond what this move needs.

**Production files likely affected**

- `Sources/App/Jobs/TargetEventRevisionJob.swift`
- The coverage file from Slice 3

**Characterization coverage required first**

- Slice 3 complete.
- Existing fallback/replay suite green.

**Preserved invariants**

- All Slice 3 invariants.
- Geolocation and H3 outbox remain one transaction.
- Completion and downstream drain remain post-commit.

**Acceptance criteria**

- SwiftyH3 and hashing execute before transaction creation.
- DB mutation statements and order are unchanged.
- Failure still selects UGC exactly as before.

**Validation commands**

```bash
swift test --filter TargetEventRevisionJobFallbackTests
swift test --filter H3
swift test --no-parallel
git diff --check
```

**Dependencies**

- Slice 3.

**Estimated risk**

- Medium.

**Recommended implementation model**

- `gpt-5.6-sol`, high reasoning.

## Slice 5 — Isolate notification candidate selection

**Goal**

Give H3/UGC candidate SQL one narrow owner and make `NotificationSendJob.dequeue` read as target-mode orchestration.

**Why now**

Notification dequeue is characterized by Slice 1, while candidate cutoff SQL already has focused H3/UGC integration tests. This is the safest persistence seam in the delivery flow.

**Exact scope**

- Introduce `NotificationCandidateStore` or equivalently specific name.
- Move only `loadH3Candidates` and `loadUGCCandidates` and their decoded row type.
- Inject it into `NotificationSendJob` with the existing default behavior.
- Preserve exact SQL predicates, inclusivity at the hard-stale cutoff, and result fields.

**Explicit non-goals**

- No ledger/debug/missed/attempt movement.
- No SQL rewrite to Fluent.
- No pagination, ordering, batching, or concurrency.
- No freshness or lifecycle changes.

**Production files likely affected**

- `Sources/App/Jobs/NotificationSendJob.swift`
- One new notification persistence file

**Characterization coverage required first**

- Slice 1.
- Existing `NotificationSendJobCandidateQueryTests` must pin exact boundary inclusion and exclusions.

**Preserved invariants**

- Active/subscribed/token filters.
- H3/UGC matching.
- Captured-at cutoff semantics.
- Candidate labels and APNs environment.

**Acceptance criteria**

- No raw candidate query remains in the job.
- SQL serialization/behavior is unchanged.
- Job public payload and queue behavior are unchanged.

**Validation commands**

```bash
swift test --filter NotificationSendJobCandidateQueryTests
swift test --filter NotificationSendJobDeliveryBoundaryTests
swift test --filter LocationFreshnessPolicyTests
git diff --check
```

**Dependencies**

- Slice 1.

**Estimated risk**

- Medium.

**Recommended implementation model**

- `gpt-5.6-sol`, high reasoning.

## Slice 6 — Isolate notification claim and completion persistence

**Goal**

Separate the exact-once ledger state machine from copy composition and APNs I/O.

**Why now**

Candidate selection is already outside the job, making the remaining delivery phases visible. This slice tackles the most correctness-sensitive persistence seam without changing delivery policy.

**Exact scope**

- Introduce a delivery store that owns:
  - atomic ledger claim;
  - conditional lookup/update to `sent` or `failed`;
  - APNs error code and completion timestamp.
- Keep missed decisions in their existing store.
- Keep debug and attempt recording in the job for this slice.
- Preserve claim-before-copy/send ordering.
- Add characterization for duplicate claim and failed/sent completion.

**Explicit non-goals**

- No reclaim of `claimed` or `failed`.
- No APNs retry/backoff.
- No transaction around APNs.
- No change to uniqueness identity.
- No immutable notification projection yet.

**Production files likely affected**

- `Sources/App/Jobs/NotificationSendJob.swift`
- `Sources/App/Models/Notification/NotificationLedgerModel.swift`
- One new notification delivery-store file

**Characterization coverage required first**

- Duplicate claim remains a no-op.
- Freshness state, reason, and mode persist exactly.
- Sent/failed status and completion fields are pinned.

**Preserved invariants**

- Unique installation/series/revision wall.
- Claim-before-side-effect tradeoff.
- Current terminal failure behavior.
- Debug snapshot association with ledger ID.

**Acceptance criteria**

- Ledger SQL/status mutation has one owner.
- `NotificationSendJob` still performs the same sequential candidate loop.
- All existing delivery metrics remain populated identically.

**Validation commands**

```bash
swift test --filter NotificationLedgerFreshnessPersistenceTests
swift test --filter NotificationSendJobDeliveryBoundaryTests
swift test --filter NotificationMissedDecisionPersistenceTests
swift test --filter NotificationEngineTests
git diff --check
```

**Dependencies**

- Slices 1 and 5.

**Estimated risk**

- High.

**Recommended implementation model**

- `gpt-5.6-sol`, high reasoning with senior human review.

## Slice 7 — Characterize NWS persistence and lineage as a flow

**Goal**

Create a database-backed safety net around the complete canonical persistence transaction before extracting it.

**Why now**

NWS lineage is the largest uncharacterized correctness boundary. It should not be structurally changed until the suite proves current series/revision/outbox results.

**Exact scope**

- Exercise a callable transaction seam or `IngestNWSAlertsJob.dequeue` with controlled ingest and queue dependencies.
- Cover:
  - new series/revision;
  - duplicate revision no-op;
  - newer revision advances snapshot;
  - older revision does not;
  - referenced-series merge;
  - polygon target outbox versus point/nil UGC intent;
  - transaction rollback on a forced late failure.
- Assert persisted rows and outbox identities, not private method calls.

**Explicit non-goals**

- No production algorithm change.
- No transaction splitting.
- No fixture replay redesign.
- No cleanup behavior changes beyond assertions.

**Production files likely affected**

- Ideally none.
- If testability requires it, only visibility/injection at `IngestNWSAlertsJob` with no logic movement.

**Test files likely affected**

- One new `NWSIngestPersistenceFlowTests.swift`
- Existing focused NWS test support only.

**Characterization coverage required first**

- This slice is the characterization.

**Preserved invariants**

- Revision/series identity and ordering.
- Reference merge behavior.
- Geometry precedence.
- Batch atomicity.
- Outbox uniqueness.

**Acceptance criteria**

- Tests assert database state after complete scenarios.
- No live NWS/Redis/APNs dependency.
- Failure scenario proves the current full-batch rollback.

**Validation commands**

```bash
swift test --filter NWSIngestPersistenceFlowTests
swift test --filter NWSAlertLifecycleTests
swift test --filter ArcusEventFingerprintTests
git diff --check
```

**Dependencies**

- None, but schedule after early low-risk slices to keep review focus.

**Estimated risk**

- Low if test-only; medium if injection is required.

**Recommended implementation model**

- `gpt-5.6-sol`, high reasoning.

## Slice 8 — Extract the NWS persistence transaction script

**Goal**

Make `IngestNWSAlertsJob` an orchestrator over one named persistence operation while preserving the single-batch transaction.

**Why now**

Slice 7 provides the missing lineage safety net. The transaction script is the natural boundary because its output is already summarized by `PersistResult`.

**Exact scope**

- Move `persistArcusEvents`, series resolution/merge, snapshot mutation, and target/notification outbox insertion into `NWSIngestPersistence`.
- Keep the job responsible for source resolution, opening the one transaction, post-commit drains, cleanup transaction, and telemetry.
- Keep cleanup separate.
- Retain exact Fluent operations and order.

**Explicit non-goals**

- No per-event transactions.
- No model/repository rewrite.
- No outbox dispatcher consolidation.
- No last-seen or lifecycle policy changes.
- No dead-code cleanup in the same PR.

**Production files likely affected**

- `Sources/App/Jobs/IngestNWSAlertsJob.swift`
- One new NWS persistence file under `Sources/App/Services` or a focused NWS directory

**Characterization coverage required first**

- Slice 7 complete and green.

**Preserved invariants**

- All Slice 7 invariants.
- One full-batch transaction.
- Post-commit queue drains.
- Separate cleanup transaction and best-effort sweep telemetry.

**Acceptance criteria**

- Job `dequeue` shows the execution phases without containing lineage SQL/Fluent details.
- Extracted type has no Redis, APNs, or scheduler dependency.
- No persisted result changes across characterization scenarios.

**Validation commands**

```bash
swift test --filter NWSIngestPersistenceFlowTests
swift test --filter NWS
swift test --filter TargetEventRevisionJobFallbackTests
swift test --no-parallel
git diff --check
```

**Dependencies**

- Slice 7.

**Estimated risk**

- High.

**Recommended implementation model**

- `gpt-5.6-sol`, high reasoning with senior human review.

## Slice 9 — Recover explicit API dependency ownership

**Goal**

Replace recursive per-access Storm Setup/Anvil default construction with one explicit API-scoped composition path.

**Why now**

Earlier slices remove duplicated policy and clarify critical jobs. Dependency lifetime can now be changed with fewer confounding variables.

**Exact scope**

- First add tests for current injection behavior and API-only construction.
- Introduce a single API dependency installer/factory used by `configure(_:mode: .api)`.
- Store configured Storm Setup, preview, and analysis providers explicitly.
- Preserve test overrides installed before `configure`.
- Worker bootstrap must not construct surface/Anvil request dependencies.
- Make missing required dependencies fail clearly rather than force unwrap.

**Explicit non-goals**

- No SwiftPM target split.
- No generic DI container.
- No feature-wide protocol rewrite.
- No cache format or retention change.
- No worker ownership of Storm Setup requests.

**Production files likely affected**

- `Sources/App/configure.swift`
- `Sources/App/StormSetup/StormSetupProvider.swift`
- `Sources/App/StormSetup/AnvilProfileAnalysisProvider.swift`
- `Sources/App/StormSetup/AnvilProfilePreviewProvider.swift`
- Possibly one new focused composition file

**Characterization coverage required first**

- Injected providers survive configure.
- Worker does not eagerly construct API request graph.
- Default API provider graph serves existing controller/provider tests.
- Cache hit/result behavior remains unchanged.

**Preserved invariants**

- API/worker split.
- Provider contracts and route behavior.
- Filesystem cache roots and actor behavior.
- Existing test injection.

**Acceptance criteria**

- Default providers are constructed by one named API composition function.
- `Application.storage` getters no longer recursively create transitive defaults.
- No global singleton or third-party container.

**Validation commands**

```bash
swift test --filter AppTests
swift test --filter StormSetupControllerTests
swift test --filter AnvilProfilePreviewControllerTests
swift test --filter AnvilProfileAnalysisControllerTests
swift test --filter StormSetupProviderTests
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency
git diff --check
```

**Dependencies**

- Slice 2.

**Estimated risk**

- Medium-high.

**Recommended implementation model**

- `gpt-5.6-sol`, high reasoning.

## Slice 10 — Give warm claim/completion SQL one catalog owner

**Goal**

Start pressure catalog persistence recovery with one bounded transition family: warming claim and completion.

**Why now**

Pressure behavior is already heavily characterized. Starting with warm-only transitions avoids a risky all-at-once repository extraction across probe, lookup, dashboard, and cleanup.

**Exact scope**

- Introduce a `PressureArtifactCatalogStore` that owns:
  - ensure row exists;
  - conditional warm claim with token/lease;
  - claim-fenced `ready`;
  - claim-fenced `failed`.
- Inject it into `PressureArtifactWarmingService`.
- Preserve exact SQL conditions and decoded results.

**Explicit non-goals**

- Do not move probe recovery SQL.
- Do not move cleanup claims.
- Do not alter lookup or dashboard queries.
- No status enum/schema/lease changes.
- No generic repository.

**Production files likely affected**

- `Sources/App/StormSetup/PressureArtifactWarmingService.swift`
- `Sources/App/Models/Data/PressureArtifactCatalogModel.swift`
- One new pressure catalog store file

**Characterization coverage required first**

- Concurrent warm claim.
- Active cleanup claim exclusion.
- old-token cannot complete.
- cancellation leaves recoverable warming lease.
- validation success/failure state.

**Preserved invariants**

- Exact artifact key.
- UUID token and lease.
- Conditional owner-only completion.
- Current cancellation and failure behavior.

**Acceptance criteria**

- Warm service contains acquisition/selection/validation orchestration, not raw catalog transition SQL.
- All existing concurrency tests pass without timing sleeps.
- No other pressure consumer changes.

**Validation commands**

```bash
swift test --filter PressureArtifactWarmJobTests
swift test --filter PressureArtifactCatalogTests
swift test --parallel --num-workers 8 --filter PressureArtifactWarmJobTests
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency
git diff --check
```

**Dependencies**

- Slice 2.

**Estimated risk**

- High.

**Recommended implementation model**

- `gpt-5.6-sol`, high reasoning.

## Slice 11A — Give probe catalog transitions one owner

**Goal**

Move pressure probe claim and recovery SQL behind the catalog store without changing artifact discovery.

**Why now**

Slice 10 proves the store shape against the most active transition family. Probe is the next consumer because it selects and recovers work before warming begins.

**Exact scope**

- Move probe claim, recovery, unavailable, and failed transitions to the store from Slice 10.
- Keep candidate ordering, remote availability probing, warm dispatch, and logs in `HRRRPressureArtifactProbeService`.
- Preserve each conditional SQL predicate and decoded result.

**Explicit non-goals**

- No cleanup transition movement.
- No lookup/dashboard movement.
- No state or lease policy change.

**Production files likely affected**

- `Sources/App/StormSetup/HRRRPressureArtifactProbeService.swift`
- The catalog store from Slice 10

**Characterization coverage required first**

- Existing probe recovery/concurrency suite.
- Existing diagnostics assertions for probe outcomes.

**Preserved invariants**

- Probe first-available behavior and recoverable states.
- Usable `ready` short-circuit.
- Warm dispatch only after a successful transition.
- Existing unavailable/failure diagnostics.

**Acceptance criteria**

- Probe catalog transitions have one persistence owner.
- Probe remains a readable I/O and candidate-order orchestrator.
- No SQL condition or row state changes.

**Validation commands**

```bash
swift test --filter HRRRPressureArtifactProbeServiceTests
swift test --filter PressureArtifactDiagnosticsTests
swift test --parallel --num-workers 8
git diff --check
```

**Dependencies**

- Slice 10.

**Estimated risk**

- High.

**Recommended implementation model**

- `gpt-5.6-sol`, high reasoning.

## Slice 11B — Give cleanup catalog transitions one owner

**Goal**

Move cleanup expiry, deletion-claim, completion, and release SQL behind the pressure catalog store without changing filesystem safety.

**Why now**

It follows the probe transition slice so the shared store evolves one state-machine family at a time. Cleanup remains separate because its path-safety and ownership risks are materially different from probe recovery.

**Exact scope**

- Move ready→expired, deletion claim, deletion completion, claim release, and ownership-recheck persistence to the store.
- Keep path canonicalization, protected-path calculation, regular-file checks, thread-pool deletion, and logging in `PressureArtifactCleanupService`.
- Preserve each conditional SQL predicate and claim-token check.

**Explicit non-goals**

- No probe, warm, lookup, or dashboard movement.
- No path-algorithm or retention-policy change.
- No state, token, or lease-policy change.
- No newly-expired same-run deletion.

**Production files likely affected**

- `Sources/App/StormSetup/PressureArtifactCleanupService.swift`
- The catalog store from Slice 10

**Characterization coverage required first**

- Existing cleanup claim/concurrency suite.
- Existing root-confinement, symlink, protected-path, ownership-recheck, and cancellation tests.
- Existing cleanup diagnostics assertions.

**Preserved invariants**

- Cleanup claims exclude warming rows.
- Protected paths and root confinement.
- Claim-token ownership recheck before and after file deletion.
- Newly expired rows wait until a later run.

**Acceptance criteria**

- Cleanup catalog transitions have one persistence owner.
- Cleanup remains a readable filesystem-safety orchestrator.
- No SQL condition, path check, row state, or timing changes.

**Validation commands**

```bash
swift test --filter PressureArtifactCleanupServiceTests
swift test --filter PressureArtifactDiagnosticsTests
swift test --parallel --num-workers 8
git diff --check
```

**Dependencies**

- Slices 10 and 11A.

**Estimated risk**

- High.

**Recommended implementation model**

- `gpt-5.6-sol`, high reasoning with focused persistence and filesystem-safety review.

## Slice 12 — Move request-path cache filesystem work to the bounded executor

**Goal**

Prevent synchronous surface and sampled-snapshot file work from occupying request/cooperative executor threads.

**Why now**

Explicit API composition from Slice 9 provides a clean place to inject the existing application thread-pool executor. Pressure caches already demonstrate the intended pattern.

**Exact scope**

- Inject `PressureArtifactBlockingWorkExecuting` or a neutrally renamed equivalent into:
  - `GribSubsetCache`;
  - `StormSetupSnapshotCache`.
- Route directory creation, reads, writes, checksum work, metadata decoding/encoding as needed, and invalidation through the bounded executor.
- Preserve actor coordination and atomic writes.
- Rename the executor only if the rename is isolated and reviewable.

**Explicit non-goals**

- No cache-key, path, retention, checksum, file-format, or fallback changes.
- No new queue or dependency.
- No process-runner work in this slice.
- No actor removal.

**Production files likely affected**

- `Sources/App/StormSetup/GribSubsetCache.swift`
- `Sources/App/StormSetup/StormSetupSnapshotCache.swift`
- `Sources/App/Infrastructure/PressureArtifactBlockingWorkExecutor.swift`
- API composition from Slice 9

**Characterization coverage required first**

- Existing miss/hit, corruption, expiry, isolation, and atomic-write tests.
- Add executor-use counting similar to pressure cleanup tests.

**Preserved invariants**

- Same file paths and contents.
- Same cache hit/miss and invalidation behavior.
- Same fallback and response metadata.
- Cooperative cancellation before/after non-preemptive operations.

**Acceptance criteria**

- No direct synchronous file operation remains in request-path cache actors outside the injected boundary.
- Cache tests produce identical results.
- No hidden global queue or detached task.

**Validation commands**

```bash
swift test --filter StormSetupGribSubsetCacheTests
swift test --filter StormSetupSnapshotCacheTests
swift test --filter StormSetupProviderTests
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency
git diff --check
```

**Dependencies**

- Slice 9.

**Estimated risk**

- Medium-high.

**Recommended implementation model**

- `gpt-5.6-sol`, high reasoning.

## Slice 13 — Clarify Storm Setup candidate-attempt orchestration

**Goal**

Reduce `DefaultStormSetupProvider` control-flow density while retaining one orchestrator and exact response behavior.

**Why now**

Candidate identity is centralized, dependencies are explicit, and blocking cache boundaries are stable. The provider can now be simplified without conflating infrastructure changes.

**Exact scope**

- Extract a value describing one surface candidate attempt: selected source, surface snapshot/cache result, failure stage/reason.
- Extract pure Anvil evidence classification from response/debug valid times and warnings.
- Keep candidate iteration, fallback decisions, cache calls, Anvil call, and final response composition visibly in `DefaultStormSetupProvider`.

**Explicit non-goals**

- Do not split the interpreter.
- Do not change exact/stale/unavailable policy.
- Do not change canonical ingredients or response DTOs.
- No new protocol per helper.
- No cold pressure acquisition.

**Production files likely affected**

- `Sources/App/StormSetup/StormSetupProvider.swift`
- At most two small focused value/policy files

**Characterization coverage required first**

- Existing 18 provider orchestration tests.
- Exact/stale/mismatch response contract tests.
- Candidate fallback and cancellation tests.

**Preserved invariants**

- Surface candidate order and failures.
- Snapshot cache semantics.
- Current Anvil refresh on cache hit.
- Exact-only `profileAnalysis`.
- Tornado viability output.

**Acceptance criteria**

- Provider’s top-level method reads as a linear flow.
- Extracted helpers are pure value decisions, not a second orchestration layer.
- All response fixtures remain byte-equivalent where ordering is defined.

**Validation commands**

```bash
swift test --filter StormSetupProviderTests
swift test --filter StormSetupCurrentResponseDTOTests
swift test --filter StormSetupControllerTests
swift test --filter AnvilIngredientEvidenceTests
swift test --filter TornadoIngredientInterpreterTests
git diff --check
```

**Dependencies**

- Slices 2, 9, and 12.

**Estimated risk**

- Medium-high.

**Recommended implementation model**

- `gpt-5.6-sol`, high reasoning.

## Slice 14 — Establish an explicit child-process cancellation contract

**Goal**

Make `ProcessRunner` own child termination when the parent task is cancelled.

**Why now**

This is runtime behavior, not ordinary structural cleanup. It should follow cache/runtime recovery and proceed only with executable characterization.

**Exact scope**

- Add a deterministic test executable/script fixture that can run, emit stdout/stderr, and wait.
- Characterize success, nonzero exit, timeout, concurrent pipe drain, cancellation, TERM grace, and forced kill.
- Rework `ProcessRunner` so cancellation triggers child termination and awaits pipe/process cleanup.
- Preserve timeout error shape and output capture.

**Explicit non-goals**

- Do not recommend or reintroduce `Task.detached` mechanically.
- No `wgrib2` argument/timeout/config changes.
- No process pool or actor.
- No surface/pressure behavior changes.

**Production files likely affected**

- `Sources/App/StormSetup/GribAdapter.swift`
- Possibly `Sources/App/StormSetup/Wgrib2Client.swift` only for injection

**Characterization coverage required first**

- All process lifecycle tests listed above.

**Preserved invariants**

- Timeout termination escalation.
- Complete stdout/stderr drainage.
- Existing `ProcessRunnerError` mapping.
- `wgrib2` callers and response/fallback behavior.

**Acceptance criteria**

- Cancelled parent does not leave the child running.
- No pipe deadlock for large stdout/stderr.
- Timeout and nonzero-exit tests remain deterministic.

**Validation commands**

```bash
swift test --filter ProcessRunner
swift test --filter StormSetupWgrib2ClientTests
swift test --filter PressureArtifactWarmJobTests
swift test --filter StormSetupProviderTests
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency
git diff --check
```

**Dependencies**

- Slice 12 recommended, not strictly required.

**Estimated risk**

- High.

**Recommended implementation model**

- `gpt-5.6-sol`, high reasoning with manual runtime review.

## Slice 15 — Consolidate the minimum integration-test harness

**Goal**

Remove repeated application/Postgres lifecycle setup without creating a test framework empire.

**Why now**

Earlier slices reveal the stable setup patterns actually needed. Consolidating too early would encode guesses and make feature tests harder to read.

**Exact scope**

- Add one shared helper for:
  - test `Application` lifecycle;
  - Postgres URL resolution;
  - optional `configure`/migration;
  - rollback or unique identity cleanup.
- Migrate only notification and NWS flow suites first.
- Leave pressure’s specialized cancellation-aware gate in place unless the new helper demonstrably replaces it.

**Explicit non-goals**

- No wholesale test move/rename.
- No fixture builder DSL.
- No base classes.
- No attempt to remove all `.serialized`.
- No production changes.

**Production files likely affected**

- None.

**Test files likely affected**

- One new focused integration test-support file
- Notification/NWS flow suites from Slices 1 and 7

**Characterization coverage required first**

- Existing migrated tests must pass before and after helper adoption.

**Preserved invariants**

- Same schema setup and cleanup.
- No live external services.
- Explicit serialization where global environment or shared tables require it.

**Acceptance criteria**

- Duplicated DB URL/application shutdown boilerplate is reduced in the migrated suites.
- Test scenario bodies become shorter and clearer.
- Helper API has no feature-specific fixture concepts.

**Validation commands**

```bash
swift test --filter Notification
swift test --filter NWS
swift test --no-parallel
swift test --parallel --num-workers 8
git diff --check
```

**Dependencies**

- Slices 1 and 7.

**Estimated risk**

- Low-medium.

**Recommended implementation model**

- `gpt-5.6-terra`, high reasoning.

## Slice 16A — Remove verified dead code

**Goal**

Remove verified-unused production symbols and obsolete commented implementations without changing runtime behavior.

**Why now**

Dead code provides little structural value early. Removing it after the recovered seams establish ownership avoids obscuring higher-value behavior-preserving PRs and makes usage verification decisive.

**Exact scope**

- Remove verified-unused `TargetEventRevisionDispatchPolicy` and its tests.
- Remove `MyPayload` and obsolete commented APNs/send/ingest blocks.

**Explicit non-goals**

- No production behavior changes.
- No endpoint removal, including placeholder/dev/operator routes.
- No migration edits.
- No architecture or progress-document rewrite.
- No broad formatting.

**Production files likely affected**

- `Sources/App/configure.swift`
- `Sources/App/Jobs/IngestNWSAlertsJob.swift`
- `Sources/App/Jobs/NotificationSendJob.swift`
- `Sources/App/Clients/APNsClient.swift`
- `Sources/App/Jobs/TargetEventRevisionDispatchPolicy.swift` (deletion only after usage verification)

**Test files likely affected**

- Only tests whose sole subject is a verified-unused production symbol

**Characterization coverage required first**

- `rg` proves symbols/comments are unreferenced.
- Full build and relevant tests pass before deletion.

**Preserved invariants**

- All runtime behavior.
- Historical migration and issue records.
- Public contracts and diagnostics.

**Acceptance criteria**

- No commented alternative implementation remains in critical orchestrators.
- Deleted symbols have no production consumers.
- Build and behavior suites pass without replacement logic.

**Validation commands**

```bash
rg -n 'TargetEventRevisionDispatchPolicy|MyPayload' Sources Tests
swift build
swift test --no-parallel
git diff --check
```

**Dependencies**

- Recommended after Slices 5, 8, 9, and 13.

**Estimated risk**

- Low-medium.

**Recommended implementation model**

- `gpt-5.6-terra`, medium reasoning.

## Slice 16B — Align living architecture documentation

**Goal**

Make canonical and status documentation describe the implemented outbox, delivery, composition, and retry boundaries.

**Why now**

Documentation should follow recovered ownership rather than predict it. This final docs-only slice prevents stale intent from being mistaken for current guarantees after the structural work lands.

**Exact scope**

- Update canonical architecture text to distinguish:
  - revision/mode dispatch intent outbox;
  - per-device delivery ledger;
  - send-time copy composition;
  - current zero-retry queue dispatch behavior.
- Mark historical progress “current state” sections as historical rather than rewriting their ledgers.
- Link the implemented owners and invariants from the living architecture document.

**Explicit non-goals**

- No production or test code changes.
- No claim that reliability gaps have been fixed.
- No rewrite of historical decision or progress records.
- No schema, endpoint, ArcusCore, or operational behavior changes.

**Production files likely affected**

- None.

**Documentation likely affected**

- `docs/architecture.md`
- `docs/epics-stories.md`
- selected progress documents only for historical-status banners

**Characterization coverage required first**

- Reconfirm queue default, outbox columns, ledger claim order, and copy-composition location against the current implementation.
- Review the architecture audit and the completed recovery seams for naming drift.

**Preserved invariants**

- All runtime behavior.
- Historical migration, issue, and progress records.
- Public contracts and diagnostics.

**Acceptance criteria**

- Living docs do not claim unimplemented retries or stored rendered payloads.
- Each current delivery guarantee names its actual owner.
- Historical documents remain recognizable as records of their time.

**Validation commands**

```bash
rg -n 'outbox|ledger|retry|NotificationEngine|compose' docs/architecture.md docs/epics-stories.md
git diff --check -- docs
```

**Dependencies**

- Recommended after Slices 5, 8, 9, 13, and 16A.

**Estimated risk**

- Low.

**Recommended implementation model**

- `gpt-5.6-terra`, medium reasoning.

## First three pull requests

1. **Test-only:** characterize inactive-series `NotificationSendJob.dequeue`.
2. **Pure policy:** centralize HRRR surface→pressure candidate mapping.
3. **Pure seam:** extract H3 coverage/hash while preserving transaction timing.

These establish trust, remove a concrete drift risk, and demonstrate the review pattern before touching lineage or delivery persistence.

## Work that must remain separate

The following are worthwhile product/correctness investigations but are not architecture-recovery slices:

- nonzero Vapor Queue retry counts;
- APNs transient/permanent failure classification and backoff;
- reclaim of abandoned `claimed` ledger rows;
- notification content storage in an outbox;
- per-event versus whole-batch NWS transactions;
- candidate batching or concurrent APNs sends;
- device presence concurrent monotonic-upsert hardening;
- schema or migration changes.

Each changes observable reliability or persistence semantics and requires its own issue, acceptance criteria, rollout plan, and failure-mode analysis.

## “Good enough” exit criteria

Stop systematic recovery and resume normal feature delivery when all of the following are true:

- NWS ingest, target, and notification jobs expose linear orchestration over named seams.
- NWS lineage and notification lifecycle have flow-level database tests.
- HRRR pressure identity is defined once.
- Pressure catalog transitions have one narrow persistence owner.
- Storm Setup/Anvil dependencies have explicit API-scoped construction and stable ownership.
- Request-path filesystem work uses the bounded executor.
- Process cancellation has an owned, tested child lifecycle.
- Living architecture docs match actual outbox, ledger, composition, and retry behavior.
- Full serial and parallel suites pass in the supported local test environment.

Do not continue extracting types merely to reduce line counts. Once these conditions hold, use the recovered patterns opportunistically in touched code.
