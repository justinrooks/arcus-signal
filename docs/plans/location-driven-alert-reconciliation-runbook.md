# Location-Driven Active-Alert Reconciliation Runbook

**Status:** Active
**Applies To:** Installation movement into already-active NWS watches and warnings
**Project:** Arcus Signal
**Parent Issue:** https://github.com/justinrooks/arcus-signal/issues/207

**Related Docs:**
- `AGENTS.md`
- `docs/architecture.md`
- `docs/epics-stories.md`
- `docs/plans/location-driven-alert-reconciliation-progress.md`
- `docs/plans/architecture-recovery-runbook.md`
- `docs/plans/architecture-recovery-progress.md`

This runbook defines how to implement one location-driven reconciliation sub-issue at a time. It is an Arcus-Signal-only campaign.

---

## Purpose

Allow Arcus Signal to discover notification relevance in both directions:

```text
alert/revision changed -> matching installations
installation/presence changed -> matching active alerts
                         \     /
               one server delivery pipeline
               one atomic ledger claim
```

The location-driven path closes the current gap where an installation can move into an already-active alert after that revision's alert-driven fan-out ran. It must enqueue worker work after authoritative presence persistence; the HTTP request must not send APNs.

The invariant remains:

> Discovery may happen more than once, but `notification_ledger` permits at most one claim for an installation, series, and revision.

This is not an exactly-once APNs guarantee. Existing claimed/failed-row recovery and APNs retry limitations remain tracked separately.

---

## Source Of Truth

Use this order:

1. `AGENTS.md`
2. `docs/architecture.md`
3. This runbook
4. `docs/plans/location-driven-alert-reconciliation-progress.md`
5. The current GitHub child issue
6. Current source, migrations, and focused tests touched by that issue
7. `docs/epics-stories.md` as historical context only

The living architecture and current source override historical stored-payload, retry, or exactly-once language.

---

## Required Read Order

Before implementation:

1. `AGENTS.md`
2. `docs/architecture.md`
3. `docs/plans/location-driven-alert-reconciliation-runbook.md`
4. `docs/plans/location-driven-alert-reconciliation-progress.md`
5. The current GitHub issue
6. Relevant files from the code map in the progress doc

Read `docs/epics-stories.md` only when historical intent is needed. Do not inspect or modify `project-arcus`.

---

## Minimal Prompt Contract

```text
Implement GitHub issue #NN for arcus-signal.

Before coding, read:
- docs/plans/location-driven-alert-reconciliation-runbook.md
- docs/plans/location-driven-alert-reconciliation-progress.md
- the GitHub issue body

Work only that issue. Preserve the existing alert-driven path and ledger identity.
Run the issue's focused verification, update the progress ledger, and stop.
```

---

## Target Architecture

### Presence transition

`DeviceController` continues to validate and persist installation plus presence in one database transaction. A pure transition policy compares the authoritative before/after state and requests reconciliation only for:

- first usable presence;
- a changed persisted targeting fingerprint;
- unusable or hard-stale presence becoming delivery-usable.

The persisted targeting fingerprint consists of the fields the current candidate queries actually use: H3 cell, county, forecast zone, and fire zone. Freshness uses `captured_at` plus installation authorization through `LocationFreshnessPolicy`; `received_at`, `location_age_seconds`, upload source, labels, and ordinary heartbeat timestamps do not independently change targeting relevance.

The policy must evaluate the persisted result, not raw optional payload fields. Current partial-update behavior preserves previously stored H3/UGC values when an upload omits them.

### Durable queue handoff

A meaningful transition writes an immutable presence-reconciliation intent in the same database transaction as the accepted authoritative state. After commit, the API may make a best-effort queue handoff. A worker-owned scheduled drain retries ready intents so a Redis enqueue failure does not erase the committed transition.

Duplicate queue handoffs and reconciliation retries are acceptable. The reconciliation job and downstream ledger make them idempotent. Do not expand this campaign into the general outbox concurrency redesign tracked by GitHub issue `#6`.

### Installation-to-alert lookup

Add one installation-scoped inverse query beside existing notification candidate selection. It must:

- load only the current revision of active, unexpired, unended series;
- use the current revision's existing `notification_outbox` mode and reason as targeting provenance;
- use `h3_cell = ANY(arcus_geolocation.h3_cells)` for H3 mode;
- use the same county/forecast-zone/fire-zone OR semantics for UGC mode;
- ignore cancelled, expired, ended, stale-revision, and terminal-only notification work;
- avoid global alert fan-out.

The existing current-revision notification-dispatch row is important: it preserves whether that revision was delivered through supported H3 coverage or UGC fallback. Do not infer the current mode solely from whether a series-level geolocation row exists; that row is not revision-keyed and can represent an earlier revision.

Existing state, expiration, GIN H3-array, GIN UGC-array, and notification-outbox indexes appear sufficient for the expected active-alert set. Add an index only if focused query evidence proves it necessary.

### Shared delivery

Extend `NotificationSendJobPayload` with a backward-compatible optional installation constraint. With no constraint, alert-driven fan-out behaves unchanged. With an installation ID, candidate selection is restricted to that installation while retaining the same:

- current-revision and lifecycle checks;
- H3/UGC predicates;
- freshness decision and stale-miss behavior;
- atomic `NotificationDeliveryStore.claim`;
- `NotificationEngine` composition;
- APNs environment selection and send;
- sent/failed ledger completion and attempt telemetry.

Do not extract a second notification service unless implementation evidence shows the optional constraint cannot keep this path clear and testable.

### Worker reconciliation

The target-lane reconciliation job loads the installation's latest authoritative state, finds matching active current revisions, and dispatches installation-constrained `NotificationSendJob` payloads on the send lane. It does not compose or send APNs itself. Bounded retries may rediscover or redispatch the same work because all delivery attempts converge on the ledger claim.

---

## Required Guardrails

- Keep Arcus Signal the only watch/warning notification eligibility, deduplication, and delivery authority.
- Preserve `UNIQUE(installation_id, series_id, revision_urn)` on `notification_ledger`.
- Preserve existing `.new` and `.update` notification reason and copy semantics; discovery source is operational metadata, not a new user-visible notification type.
- Keep APNs worker-owned and asynchronous from the location HTTP request.
- Use the latest persisted presence at reconciliation and again at constrained candidate delivery so stale queued work cannot target an obsolete location.
- Treat source/reason fields as telemetry only; never make correctness depend on `backgroundLocationChange`, `significantChange`, or another client hint.
- Preserve signed `Int64` H3 identifiers and current H3/UGC behavior.
- Preserve first-valid, stale-to-usable, new-revision, leave/re-enter, and concurrent-discovery semantics.
- Keep each slice within the repo review budget and add deterministic focused tests.
- Update the progress doc after each completed child issue.

---

## Forbidden Scope

- No `project-arcus` files, issues, or client WatchEngine removal.
- No synchronous APNs delivery from `DeviceController`.
- No server-side latitude/longitude storage.
- No second notification history or deduplication table.
- No new user-visible “entered alert area” reason or copy.
- No global re-fan-out of every installation for each location upload.
- No source-string-triggered correctness policy.
- No APNs retry/reclaim redesign tracked by `#13`.
- No notification-outbox atomic-claim redesign tracked by `#6`.
- No broad `NotificationEngine`, ingest, queue, or persistence rewrite.

---

## Current Boundaries To Preserve

| Concern | Current owner |
|---|---|
| Location request validation and installation/presence transaction | `Sources/App/Controllers/DeviceController.swift` |
| Presence and installation state | `Sources/App/Models/Device/DevicePresenceModel.swift`, `DeviceInstallationModel.swift` |
| Alert revision targeting and mode selection | `Sources/App/Jobs/TargetEventRevisionJob.swift`, `Sources/App/lib/DispatchAgent.swift` |
| Candidate H3/UGC matching | `Sources/App/Models/Notification/NotificationCandidateStore.swift` |
| Lifecycle, freshness, claim, composition, APNs, completion | `Sources/App/Jobs/NotificationSendJob.swift` |
| Atomic delivery identity | `Sources/App/Models/Notification/NotificationDeliveryStore.swift`, `CreateNotificationLedger.swift` |
| Notification wording | `Sources/App/Infrastructure/Notifications/NotificationEngine.swift` |
| API/worker queue ownership | `Sources/App/configure.swift`, `Sources/App/Worker/WorkerRuntime.swift` |

---

## Sequential Execution Model

Execute the child issues in the exact order recorded in the progress doc. Do not parallelize implementation issues.

For each issue:

1. Read this runbook, the progress doc, and the issue.
2. State the smallest review unit and explicit non-goals.
3. Add or update focused deterministic tests.
4. Implement only the issue contract.
5. Run the listed focused verification.
6. Update the progress ledger with evidence and handoff notes.
7. Stop.

Intermediate slices may introduce dormant schema or helpers before wiring runtime behavior. They must remain backward-compatible and safe to deploy in sequence.

---

## Verification Defaults

Prefer focused suites during implementation:

```bash
swift test --filter PresenceReconciliationTriggerTests
swift test --filter PresenceReconciliationOutboxTests
swift test --filter DeviceControllerTests
swift test --filter NotificationActiveAlertQueryTests
swift test --filter NotificationSendJobCandidateQueryTests
swift test --filter NotificationSendJobDeliveryBoundaryTests
swift test --filter InstallationAlertReconciliationJobTests
```

Before epic completion:

```bash
swift build
swift test --filter Notification
swift test --filter Device
swift test --filter Reconciliation
swift test --no-parallel
```

Use the actual final suite names if implementation chooses clearer names. Do not require live NWS, Redis, or APNs for behavioral tests; use the existing test queue, recording sender, and PostgreSQL integration harness.

---

## Quality Bar For `5.6 luna medium`

- One child issue at a time, normally one behavior and 1-3 production files.
- Exact required reading and focused validation are in every issue.
- Tests pin observable behavior rather than implementation trivia.
- SQL remains installation-scoped and lifecycle-bounded.
- Duplicate discovery, queue retry, and alert/location races end at one ledger claim.
- Existing alert-driven tests remain unchanged or are explicitly extended.
- Any deviation from current H3/UGC, freshness, lifecycle, or copy semantics stops the slice for review.

---

## Rollout Gate

Epic completion means the server capability is implemented and deterministically verified. Deployment must then validate reconciliation intents, match counts, constrained send attempts, and ledger outcomes in Arcus Signal. Only after that server validation may a separate SkyAware campaign remove the WatchEngine alert-notification producer. Client removal is not part of this epic.
