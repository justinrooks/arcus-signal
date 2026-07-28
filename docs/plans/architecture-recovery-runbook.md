# Arcus Signal Architecture Recovery Runbook

**Status:** Active

**Applies to:** Behavior-preserving architecture recovery

**Project:** Arcus Signal

**Parent epic:** [#153](https://github.com/justinrooks/arcus-signal/issues/153)

## Related documents

- `AGENTS.md`
- `docs/architecture.md`
- `docs/epics-stories.md`
- `docs/audits/architecture-recovery-audit.md`
- `docs/plans/architecture-recovery-roadmap.md`
- `docs/plans/architecture-recovery-progress.md`

## Purpose

Execute the architecture recovery roadmap as a sequence of small, reviewable GitHub issues without changing Arcus Signal behavior or guarantees.

This campaign recovers explicit orchestration, dependency ownership, persistence seams, blocking-work boundaries, and flow-level characterization. It is not a rewrite, feature campaign, or reliability-policy redesign.

Each child issue is one review unit and should normally produce one pull request. Implement the current issue, validate it, update the progress ledger, and stop.

## Source-of-truth order

1. `AGENTS.md`
2. `docs/architecture.md` and `docs/epics-stories.md`
3. This runbook
4. `docs/plans/architecture-recovery-roadmap.md`
5. `docs/audits/architecture-recovery-audit.md`
6. `docs/plans/architecture-recovery-progress.md`
7. The current GitHub issue
8. Current source and tests

If the current implementation conflicts with historical planning text, preserve production behavior and record the mismatch. Do not silently “restore” historical intent.

## Required read order

Before implementation:

1. Read `AGENTS.md`.
2. Read `docs/architecture.md` and `docs/epics-stories.md`.
3. Read this runbook.
4. Read the current issue and its exact slice in `docs/plans/architecture-recovery-roadmap.md`.
5. Read only the relevant audit flow/hotspot and current progress-ledger entry.
6. Inspect the issue’s production and test files.

Do not reread unrelated roadmap slices or progress history. Paths are durable context; issue bodies intentionally avoid repeating it.

## Minimal prompt contract

```text
Implement arcus-signal GitHub issue #NN.

Read:
- docs/plans/architecture-recovery-runbook.md
- docs/plans/architecture-recovery-progress.md (current issue entry only)
- docs/plans/architecture-recovery-roadmap.md (named slice only)
- the GitHub issue body

Use the issue's required model/reasoning profile.
Work only that issue, preserve every listed invariant, run focused validation, update the progress entry, and stop.
```

## Target architecture

Recovery is complete when:

- NWS ingest, target, and notification jobs read as linear orchestration over named seams.
- NWS lineage and notification lifecycle have flow-level database characterization.
- HRRR surface-to-pressure identity has one production owner.
- Pressure catalog transitions have one narrow persistence owner.
- Storm Setup/Anvil dependencies have explicit API-scoped construction and stable lifetime.
- Request-path filesystem work uses the existing bounded executor.
- Child-process cancellation has an owned and tested lifecycle.
- Living architecture docs match implemented outbox, ledger, copy-composition, and retry behavior.

Do not continue extracting types after these conditions hold.

## Required guardrails

- Preserve API/worker runtime ownership and all queue lanes.
- Preserve endpoint and ArcusCore contracts.
- Preserve schema and migration order.
- Preserve NWS lineage, batch transaction scope, snapshot ordering, and lifecycle.
- Preserve target/notification outbox uniqueness and current replay behavior.
- Preserve H3 resolution, signed-cell representation, holes, UGC fallback, and unchanged-geometry dispatch.
- Preserve notification deduplication, copy, lifecycle gates, freshness, missed decisions, debug, and attempts.
- Preserve HRRR ordering, exact-before-stale fallback, cache identity, and response results.
- Preserve pressure claim tokens, leases, validation, cleanup confinement, and protected paths.
- Preserve Storm Setup/Anvil degradation, evidence exposure, canonical ingredients, and interpretation.
- Preserve AirNow behavior.
- Use existing dependencies and the single `App` target.
- Keep raw SQL semantics exact while moving ownership.

## Forbidden scope

- Queue retry-count changes.
- APNs retry/backoff or failure-policy changes; see GitHub issue #13.
- Atomic outbox redesign; see GitHub issue #6.
- Ledger reclaim or notification payload-storage redesign.
- NWS transaction-granularity changes.
- Schema changes, migration cleanup, or migration reordering.
- Public endpoint or ArcusCore contract changes.
- SwiftPM target splits or new dependencies.
- Concurrent APNs fan-out.
- Broad file splitting, formatting, or unrelated cleanup.
- Treating open test-baseline issue #8 as part of this campaign.

## Current code boundaries to preserve

| Flow | Current owner |
|---|---|
| Composition | `Sources/App/configure.swift`, `Sources/App/apiRoutes.swift`, `Sources/App/Worker/WorkerRuntime.swift` |
| NWS lineage | `Sources/App/Jobs/IngestNWSAlertsJob.swift` |
| H3/UGC targeting | `Sources/App/Jobs/TargetEventRevisionJob.swift`, `Sources/App/lib/DispatchAgent.swift` |
| Notification delivery | `Sources/App/Jobs/NotificationSendJob.swift`, `Sources/App/Infrastructure/Notifications/NotificationEngine.swift` |
| Storm Setup | `Sources/App/StormSetup/StormSetupProvider.swift`, Anvil preview/analysis providers |
| Pressure artifacts | probe, warming, lookup, and cleanup services under `Sources/App/StormSetup` |
| Blocking work | `Sources/App/Infrastructure/PressureArtifactBlockingWorkExecutor.swift`, `Sources/App/StormSetup/GribAdapter.swift` |
| Air quality | `Sources/App/AirQuality`, `Sources/App/Controllers/AirQualityController.swift` |

## Sequential execution model

Do not parallelize issues that share production files or state-machine ownership. A later issue may begin only when its listed dependencies are merged and the progress ledger is current.

| Seq. | Roadmap slice | Purpose | Required execution profile |
|---:|---|---|---|
| 01 | 1 | Characterize notification dequeue lifecycle | `gpt-5.6-terra`, medium |
| 02 | 2 | Centralize surface-to-pressure identity | `gpt-5.6-terra`, high |
| 03 | 3 | Extract pure H3 coverage result | `gpt-5.6-terra`, high |
| 04 | 4 | Move H3 work before transaction | `gpt-5.6-sol`, high |
| 05 | 5 | Isolate notification candidate selection | `gpt-5.6-sol`, high |
| 06 | 6 | Isolate notification ledger persistence | `gpt-5.6-sol`, high + senior review |
| 07 | 7 | Characterize NWS persistence flow | `gpt-5.6-sol`, high |
| 08 | 8 | Extract NWS transaction script | `gpt-5.6-sol`, high + senior review |
| 09 | 9 | Recover explicit API dependency ownership | `gpt-5.6-sol`, high |
| 10 | 10 | Own warm claim/completion SQL | `gpt-5.6-sol`, high |
| 11 | 11A | Own probe catalog transitions | `gpt-5.6-sol`, high |
| 12 | 11B | Own cleanup catalog transitions | `gpt-5.6-sol`, high + persistence/filesystem review |
| 13 | 12 | Move request cache I/O to bounded executor | `gpt-5.6-sol`, high |
| 14 | 13 | Clarify Storm Setup candidate attempts | `gpt-5.6-sol`, high |
| 15 | 14 | Own child-process cancellation | `gpt-5.6-sol`, high + manual runtime review |
| 16 | 15 | Consolidate minimal integration harness | `gpt-5.6-terra`, high |
| 17 | 16A | Remove verified dead code | `gpt-5.6-terra`, medium |
| 18 | 16B | Align living architecture docs | `gpt-5.6-terra`, medium |

The profile is a minimum, not a target to downgrade. If the named model is unavailable, use an equal-or-stronger coding model at the same reasoning level. Small-agent profiles such as `5.4 mini medium` are acceptable only for tightly mechanical, test-only, or docs-only execution after the issue has been reduced to that capacity.

## Verification defaults

- Run the focused commands in the current issue first.
- Run broader serial/parallel suites only where the issue requires them.
- Use deterministic fixtures; no live NWS, HRRR, AirNow, Anvil, APNs, Redis, or Postgres dependency unless the existing focused integration test explicitly requires local infrastructure.
- Run `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency` for concurrency/runtime slices.
- Run `git diff --check`.
- Compare preserved outputs or persisted state before and after structural movement.
- Never claim a check passed unless it ran.

## Quality bar

- One architectural purpose per issue and PR.
- Prefer 1–3 production files; stop and split before exceeding five without explicit approval.
- Keep most diffs under roughly 200 changed lines when practical.
- Add characterization before moving high-risk behavior.
- Do not create abstractions solely to reduce file size.
- Preserve exact SQL predicates, state transitions, ordering, fallback, and logging semantics unless the issue explicitly permits a non-observable naming change.
- Update the matching progress-ledger entry with files, behavior, validation, risks, and handoff notes before completion.
- A `5.4 mini medium` implementer should be able to recover all authoritative context from the issue and the named document sections without repository-wide exploration.
