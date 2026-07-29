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
| 04 | [#157](https://github.com/justinrooks/arcus-signal/issues/157) | 4 | Move H3 work before transaction | 03 | `gpt-5.6-sol`, high | Pending |
| 05 | [#158](https://github.com/justinrooks/arcus-signal/issues/158) | 5 | Isolate notification candidate selection | 01 | `gpt-5.6-sol`, high | Pending |
| 06 | [#159](https://github.com/justinrooks/arcus-signal/issues/159) | 6 | Isolate notification ledger persistence | 01, 05 | `gpt-5.6-sol`, high + senior review | Pending |
| 07 | [#160](https://github.com/justinrooks/arcus-signal/issues/160) | 7 | Characterize NWS persistence flow | None | `gpt-5.6-sol`, high | Pending |
| 08 | [#161](https://github.com/justinrooks/arcus-signal/issues/161) | 8 | Extract NWS transaction script | 07 | `gpt-5.6-sol`, high + senior review | Pending |
| 09 | [#162](https://github.com/justinrooks/arcus-signal/issues/162) | 9 | Recover explicit API dependency ownership | 02 | `gpt-5.6-sol`, high | Pending |
| 10 | [#163](https://github.com/justinrooks/arcus-signal/issues/163) | 10 | Own warm claim/completion SQL | 02 | `gpt-5.6-sol`, high | Pending |
| 11 | [#164](https://github.com/justinrooks/arcus-signal/issues/164) | 11A | Own probe catalog transitions | 10 | `gpt-5.6-sol`, high | Pending |
| 12 | [#165](https://github.com/justinrooks/arcus-signal/issues/165) | 11B | Own cleanup catalog transitions | 10, 11 | `gpt-5.6-sol`, high + persistence/filesystem review | Pending |
| 13 | [#166](https://github.com/justinrooks/arcus-signal/issues/166) | 12 | Move request cache I/O to bounded executor | 09 | `gpt-5.6-sol`, high | Pending |
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

- **Status:** Pending
- **Roadmap:** Slice 3
- **Execution profile:** `gpt-5.6-terra`, high reasoning
- **Dependencies:** None
- **Stop condition:** Pure result extracted at the same transaction point.

### Issue #157 - 04: Move H3 work before transaction

- **Status:** Pending
- **Roadmap:** Slice 4
- **Execution profile:** `gpt-5.6-sol`, high reasoning
- **Dependencies:** 03
- **Stop condition:** Transaction contains persistence only; output unchanged.

### Issue #158 - 05: Isolate notification candidate selection

- **Status:** Pending
- **Roadmap:** Slice 5
- **Execution profile:** `gpt-5.6-sol`, high reasoning
- **Dependencies:** 01
- **Stop condition:** Candidate SQL has one owner; send orchestration unchanged.

### Issue #159 - 06: Isolate notification ledger persistence

- **Status:** Pending
- **Roadmap:** Slice 6
- **Execution profile:** `gpt-5.6-sol`, high reasoning with senior human review
- **Dependencies:** 01, 05
- **Stop condition:** Claim/completion persistence is isolated without retry or delivery changes.

### Issue #160 - 07: Characterize NWS persistence flow

- **Status:** Pending
- **Roadmap:** Slice 7
- **Execution profile:** `gpt-5.6-sol`, high reasoning
- **Dependencies:** None
- **Stop condition:** Lineage, outbox, duplicate, merge, and rollback paths are pinned.

### Issue #161 - 08: Extract NWS transaction script

- **Status:** Pending
- **Roadmap:** Slice 8
- **Execution profile:** `gpt-5.6-sol`, high reasoning with senior human review
- **Dependencies:** 07
- **Stop condition:** One named persistence operation preserves the batch transaction.

### Issue #162 - 09: Recover explicit API dependency ownership

- **Status:** Pending
- **Roadmap:** Slice 9
- **Execution profile:** `gpt-5.6-sol`, high reasoning
- **Dependencies:** 02
- **Stop condition:** API graph is installed once with stable lifetime; worker ownership unchanged.

### Issue #163 - 10: Own warm claim/completion SQL

- **Status:** Pending
- **Roadmap:** Slice 10
- **Execution profile:** `gpt-5.6-sol`, high reasoning
- **Dependencies:** 02
- **Stop condition:** Warm transition SQL has one owner with identical predicates.

### Issue #164 - 11: Own probe catalog transitions

- **Status:** Pending
- **Roadmap:** Slice 11A
- **Execution profile:** `gpt-5.6-sol`, high reasoning
- **Dependencies:** 10
- **Stop condition:** Probe transition SQL has one owner; discovery unchanged.

### Issue #165 - 12: Own cleanup catalog transitions

- **Status:** Pending
- **Roadmap:** Slice 11B
- **Execution profile:** `gpt-5.6-sol`, high reasoning with persistence/filesystem-safety review
- **Dependencies:** 10, 11
- **Stop condition:** Cleanup transition SQL has one owner; path safety unchanged.

### Issue #166 - 13: Move request cache I/O to bounded executor

- **Status:** Pending
- **Roadmap:** Slice 12
- **Execution profile:** `gpt-5.6-sol`, high reasoning
- **Dependencies:** 09
- **Stop condition:** Surface/snapshot cache filesystem work uses the existing executor.

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
