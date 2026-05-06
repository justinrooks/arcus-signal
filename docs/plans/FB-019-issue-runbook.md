# FB-019 Issue Runbook

**Status:** Active  
**Applies To:** FB-019 Location Freshness & Presence Policy  
**Project:** Arcus Signal  
**Related Docs:**
- `AGENTS.md`
- `docs/architecture.md`
- `docs/epics-stories.md`
- `docs/event-cleanup-strategy.md`
- `docs/plans/FB-019-progress.md`
- `/Users/justin/Library/Mobile Documents/iCloud~md~obsidian/Documents/Second Brain/Efforts/Notes/FB-019 Location Freshness Policy.md`

This document defines how to execute one issue at a time for FB-019.

---

## Purpose

Implement one incremental issue for FB-019 Location Freshness & Presence Policy in a way that aligns with the feature brief, Arcus Signal's existing notification pipeline, and the backend's idempotency and exactly-once constraints.

This runbook exists to keep implementation:
- issue-scoped
- sequential
- testable
- verifiable
- traceable across product intent, persistence, notification delivery, and operator diagnostics

> Do not treat a single issue as permission to rebuild notification targeting.  
> Implement the current slice cleanly, leave a durable handoff, and move to the next issue only after verification.

---

## Source of Truth

Treat these inputs with the following authority:

1. The relevant repo `AGENTS.md`  
   Repo-wide and server standing rules.

2. `docs/architecture.md` and `docs/epics-stories.md`  
   Arcus Signal pipeline, persistence, idempotency, and delivery invariants.

3. `docs/plans/FB-019-issue-runbook.md`  
   The execution contract for how FB-019 issues should be worked.

4. `FB-019 Location Freshness Policy.md`  
   The product, behavior, thresholds, copy, and acceptance criteria source of truth.

5. `docs/plans/FB-019-progress.md`  
   The durable implementation ledger and issue-to-issue handoff record.

6. The current GitHub issue or implementation slice for FB-019  
   The implementation boundary for the current run.

7. Current source, migrations, tests, SQL diagnostics, and operator dashboard code touched by that issue.

---

## Required Read Order

Read in this order before doing any implementation work:

1. `AGENTS.md`
2. `docs/architecture.md`
3. `docs/epics-stories.md`
4. `docs/plans/FB-019-issue-runbook.md`
5. `/Users/justin/Library/Mobile Documents/iCloud~md~obsidian/Documents/Second Brain/Efforts/Notes/FB-019 Location Freshness Policy.md`
6. `docs/plans/FB-019-progress.md`
7. `docs/event-cleanup-strategy.md`, especially the stale presence notes, when the issue touches retention, suppression, or cleanup
8. The current GitHub issue or implementation slice
9. Relevant source, migrations, tests, SQL diagnostics, and dashboard paths touched by that issue

FB-019 is server-side unless a future issue explicitly says otherwise. Do not inspect or modify app repositories for this feature.

---

## Scope Rules

Implement **only** the current issue's scope.

### Required

- Stay aligned with `FB-019 Location Freshness Policy.md`.
- Treat the current GitHub issue or slice as the implementation boundary for this run.
- Keep changes incremental and reviewable.
- Leave the codebase in a clean state for the next issue.
- Update `docs/plans/FB-019-progress.md` before finishing.
- Keep freshness state names exactly:
  - `fresh`
  - `degraded`
  - `stale`
- Compute freshness from `device_presence.captured_at`, not `received_at`, `updated_at`, or `device_installations.last_seen_at`.
- Use the recorded permission mode from `device_installations.location_auth`.
- Keep the global hard-stale threshold at 24 hours after `captured_at`.
- Apply v1 thresholds:
  - When In Use: fresh `0-2 hr`, degraded `2-24 hr`, stale `>24 hr`
  - Always: fresh `0-6 hr`, degraded `6-24 hr`, stale `>24 hr`
- Exclude stale presence from push targeting.
- Log stale exclusions as missed notification decisions with idempotent persistence.
- Allow degraded warning and watch candidates to remain eligible.
- Use conservative subtitle copy for degraded candidates: `For your last known area`.
- Preserve fresh current-location subtitle copy: `Includes your location`.
- Keep stale candidates unsent; do not create stale notification copy because no push should be delivered.
- Integrate policy into the existing notification decision flow.
- Keep `NotificationEngine` in place.
- Keep idempotency enforced by database constraints where effects matter.
- Add focused tests for fresh, degraded, and stale behavior across When In Use and Always modes.
- Record freshness state used at decision time for delivered notification decisions.
- Add observability sufficient to answer: "How many candidate pushes were skipped because location was stale?"
- Evaluate whether `swift-concurrency-expert` applies before implementation and before final verification.

### Forbidden

- Do not introduce a new notification architecture or parallel targeting pipeline.
- Do not target using stale presence.
- Do not compute freshness from `received_at`, `updated_at`, or `last_seen_at`.
- Do not silently drop stale candidates without durable missed-decision accounting.
- Do not send user-facing copy that implies current-location precision for degraded presence.
- Do not use `Near your last known area` in v1.
- Do not change in-app UI freshness state or Summary screen behavior.
- Do not build real-time continuous location tracking.
- Do not redesign the full notification policy matrix for every alert type.
- Do not move mesoscale discussion notification handling from device-side logic to server-side targeting in FB-019.
- Do not implement route-aware or travel-mode alerting.
- Do not solve multi-device account sync semantics unless a future issue explicitly scopes it.
- Do not introduce server-side raw lat/lon storage.
- Do not refactor unrelated app, ingestion, APNs, or dashboard areas unless a small local change is strictly required.

If a future-facing seam is required, keep it:
- minimal
- local
- easy to extend later

Document the deferred remainder clearly in `docs/plans/FB-019-progress.md`.

---

## Working Style

Prefer:
- simple policy value types
- pure freshness computation
- database-backed idempotency for missed decisions
- narrow changes to candidate resolution, delivery ledger, and notification copy
- explicit SQL over clever query indirection when it matches the surrounding code
- focused model/migration tests where practical
- deterministic unit tests for threshold boundaries
- clear operator diagnostics over noisy logs

Avoid:
- global notification rewrites
- ambiguous freshness terminology
- hidden fallback thresholds
- wall-clock assumptions that make tests flaky
- per-alert-type branching unless the current issue requires it
- broad dashboard redesigns
- stale-location deletion masquerading as targeting policy

The policy should become a small, testable decision point in the existing delivery path, not a second notification system wearing a serious expression.

---

## Sequential Execution Model

Work **one issue at a time**, sequentially.

Do not attempt to execute multiple issues in parallel under a parent coordinator.

Parallelism is allowed **only inside the current issue** and only for narrow investigation or isolated subtasks.

---

## Delegated Agent Rules

If delegated agents or subtasks are available, use them only when they reduce context sprawl and improve quality for the **current issue**.

### Good delegated tasks

- tracing candidate query paths for H3 and UGC modes
- mapping current ledger, outbox, debug snapshot, and attempt persistence
- reviewing migration and constraint patterns
- checking dashboard metric queries and SQL diagnostics
- validating a small proposed policy seam against surrounding code

### Do not delegate

- overall architecture
- final issue planning
- final policy thresholds or copy decisions
- final database identity design
- cross-issue sequencing decisions
- final integration decisions

Delegated work should stay scoped and concise.

The primary executor remains responsible for:
- reconciling findings
- resolving conflicts
- producing one coherent implementation for the current issue

---

## Execution Sequence

Before making code changes for the current issue:

### 1. Inspect inputs

Inspect the relevant sections of:
- `FB-019 Location Freshness Policy.md`
- `docs/plans/FB-019-progress.md`
- the current issue or implementation slice
- existing presence, installation, candidate query, notification engine, ledger, outbox, debug, metrics, migration, and test code touched by that issue

### 2. Identify what matters now

Identify:
- which parts of the feature brief are relevant to the current issue
- which parts are already partially implemented, if any
- what existing seams, models, SQL queries, migrations, tests, and diagnostics are most relevant
- what must change now versus what should remain deferred to later issues

### 3. Produce a pre-implementation plan

Before coding, produce:
- a concise findings summary
- an issue-scoped implementation plan
- a short ambiguity/risk list
- any assumptions to be made
- a progress-verification plan explaining how the issue will be checked against both the brief and the issue once implemented

### 4. Evaluate the plan before coding

Evaluate the plan and:
- remove anything that reaches beyond the current issue without strong justification
- remove speculative abstractions or premature architecture
- check for conflicts with the feature brief, prior progress log entries, or existing code conventions
- verify that the plan leaves a clean handoff for the next issue
- simplify the design if it is becoming broader than the issue requires

### 4.5 Skill evaluation gate

Before coding, decide whether `swift-concurrency-expert` applies.

Use `swift-concurrency-expert` when the issue touches:
- async/await flows
- `Sendable` or `Codable` models crossing concurrency boundaries
- Vapor queue jobs
- APNs delivery paths
- Fluent models or repository helpers used from async contexts
- shared policy types used across jobs, tests, and services

For applicable skill use:
- read the skill before implementation
- use it to evaluate the issue-scoped plan
- apply only guidance relevant to the current issue
- record any important skill-driven decisions in `docs/plans/FB-019-progress.md`

Do not use the skill as permission to broaden scope.

### 5. Implement

Implement in small, reviewable steps.

Prefer extending existing patterns over inventing new ones.

### 6. Ask questions only when necessary

Stop to ask questions only if a missing decision would materially affect:
- the current issue's scope
- a durable model or persistence shape
- a public or cross-cutting API contract
- a user-visible notification behavior that would be costly to reverse later
- the missed-decision table identity or uniqueness rule

### 7. Verify

Run the smallest meaningful verification for the issue:
- focused unit tests for freshness policy thresholds
- focused tests for candidate eligibility and subtitle selection
- migration tests or database-level checks for missed-decision persistence when applicable
- notification job tests for stale suppression and degraded delivery when practical
- dashboard or SQL checks when observability changes
- `swift test` or narrower SwiftPM test filters when the issue touches shared behavior

Do not claim tests passed unless they were actually run.

### 8. Update progress

Before finishing the issue:
- update `docs/plans/FB-019-progress.md`
- record files changed
- record tests run and results
- record deferred scope
- record handoff notes for the next issue

---

## Suggested Implementation Sequence

Work these slices in order unless the epic owner explicitly changes the order:

1. `FB-019: Add location freshness policy model`
2. `FB-019: Add missed notification decision persistence`
3. `FB-019: Integrate freshness into notification candidate decisions`
4. `FB-019: Select push subtitle by freshness state`
5. `FB-019: Record freshness state on delivered decisions`
6. `FB-019: Add freshness observability and validation`

---

## Expected End State

FB-019 is done when:
- Arcus Signal computes `fresh`, `degraded`, or `stale` from `device_presence.captured_at` and `device_installations.location_auth`.
- When In Use presence is fresh through 2 hours, degraded through 24 hours, and stale after 24 hours.
- Always presence is fresh through 6 hours, degraded through 24 hours, and stale after 24 hours.
- Fresh warning and watch notifications use `Includes your location`.
- Degraded warning and watch notifications remain eligible and use `For your last known area`.
- Stale notification candidates are excluded from push delivery.
- Stale exclusions are written once to a durable missed-decision table.
- Delivered notification decisions record the freshness state used at decision time.
- Observability reports candidate counts by freshness state, permission mode, delivery outcome, and stale-miss reason.
- Tests prove fresh, degraded, and stale behavior for both permission modes.
- No app UI behavior, real-time tracking, or parallel notification architecture is introduced.
