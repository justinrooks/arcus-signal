# Arcus Signal Server Architecture

## Purpose

Arcus Signal ingests NWS alert revisions, targets eligible installations by H3 or UGC coverage, and sends APNs notifications. This document describes the implemented runtime, persistence boundaries, and delivery guarantees. It is the living architecture reference; [epics-stories.md](epics-stories.md) is historical planning.

## Runtime ownership

- **API (`Run`)** configures HTTP routes and API-scoped Storm Setup/Anvil dependencies. [`configure(_:mode:)`](../Sources/App/configure.swift) calls [`installAPIRequestDependencies(on:)`](../Sources/App/StormSetup/APIDependencyComposition.swift) once for `.api`; this establishes the request graph without starting queue consumers or schedulers.
- **Worker (`RunWorker`)** configures APNs, queue settings, worker-only routes, schedules, and queues. [`configure(_:mode:)`](../Sources/App/configure.swift) installs [`WorkerRuntime`](../Sources/App/Worker/WorkerRuntime.swift), whose `startWorkerRuntime(on:)` starts consumers for the configured lanes and the scheduled jobs.
- Both processes share PostgreSQL and Redis/Vapor Queues. The API does not deliver APNs notifications; APNs setup and send execution are worker-owned.

### Queue topology

[`ArcusQueueLane`](../Sources/App/Worker/ArcusQueueLane.swift) defines the `ingest`, `target`, `send`, and `model-artifacts` lanes. Worker configuration applies the same `QUEUE_WORKER_COUNT` to Vapor Queues, with a minimum and default of `1`, through [`configureWorkerQueueSettings(on:)`](../Sources/App/configure.swift). Before any consumer or schedule starts, [`WorkerRuntime`](../Sources/App/Worker/WorkerRuntime.swift) atomically returns abandoned registered model-artifact jobs to waiting while preserving and reporting unknown or malformed entries; failed reconciliation shuts the worker down. After successful reconciliation, `WorkerRuntime` starts consumers for every lane.

## Delivery pipeline

```text
NWS ingest
  -> geometry present: target-dispatch intent -> target queue handoff -> H3 target processing
  -> nil or point geometry: UGC notification-dispatch intent -> send queue handoff
  -> point geometry: both paths above
  -> target processing: notification-dispatch intent -> send queue handoff
authoritative installation/presence transition
  -> presence-reconciliation intent -> target queue handoff -> active-alert lookup
  -> installation-constrained send queue handoff
  -> delivery-eligible installation (fresh or degraded) -> ledger claim
  -> candidate-specific copy composition -> APNs send and ledger completion
  -> retryable APNs/transport failure -> retrying ledger state -> bounded send-queue retry
```

The arrows are distinct boundaries. A durable intent, successful queue enqueue, job completion, APNs completion, debug copy, and attempt telemetry are not interchangeable evidence.

## Dispatch intents and queue handoff

### Target dispatch

[`NWSIngestPersistence.enqueueTargetDispatchOutboxIfNeeded(...)`](../Sources/App/Services/NWSIngestPersistence.swift) writes one `target_dispatch_outbox` row for a geometry-bearing revision. [`CreateTargetDispatchOutbox`](../Sources/App/Migrations/CreateTargetDispatchOutbox.swift) enforces `UNIQUE(revision_urn)`.

[`IngestNWSAlertsJob.dispatchPendingTargetJobs(...)`](../Sources/App/Jobs/IngestNWSAlertsJob.swift) selects rows without `dispatched`, enqueues `TargetEventRevisionJob`, and then sets `dispatched`, increments `attempt_count`, and records any enqueue error. This outbox represents target-job queue handoff only. A `dispatched` row is not evidence that the target consumer completed; if database update fails after enqueue, a later drain can enqueue the job again.

### Notification dispatch

[`DispatchAgent.enqueueNotificationDispatchOutbox(...)`](../Sources/App/lib/DispatchAgent.swift) writes `notification_outbox` intent for a `(series_id, revision_urn, mode)` and records the triggering reason. [`CreateNotificationOutbox`](../Sources/App/Migrations/CreateNotificationOutbox.swift) enforces that identity. The row contains revision, mode, reason, queue-dispatch state, queue-dispatch attempts, availability, and errors. It contains neither installation identity nor rendered APNs content.

[`DispatchAgent.dispatchPendingNotificationJobs(...)`](../Sources/App/lib/DispatchAgent.swift) uses [`NotificationDispatchOutboxStore`](../Sources/App/Models/Notification/NotificationDispatchOutboxStore.swift) to atomically claim a mode-specific bounded batch with `FOR UPDATE SKIP LOCKED`. Eligible `ready` rows and expired `processing` rows become `processing` with a five-minute lease in `available_at`. The claim statement commits before queue handoff; no row locks are held across Redis awaits. Replay cannot modify processing rows, including expired leases, whose recovery belongs to the claim path.

After enqueueing `NotificationSendJob`, completion conditionally marks only the same processing lease `done`, increments `attempts`, and clears `last_error`. Failed handoff conditionally increments attempts and returns the row to `ready` with 30/120-second backoff, or to `dead` at three attempts. Its `attempts`, `available_at`, and `last_error` describe queue handoff, not APNs delivery retries. Handoff remains at least once: enqueue followed by a crash or completion-write failure can be duplicated after lease recovery; downstream ledger uniqueness absorbs a duplicate claim. Marking `done` does not provide consumer-completion replay.

### Presence reconciliation

[`DeviceController`](../Sources/App/Controllers/DeviceController.swift) compares the previously persisted installation/presence state with the accepted authoritative result. First usable presence, a changed H3/UGC targeting fingerprint, or an unusable/hard-stale state becoming usable writes a `presence_reconciliation_outbox` intent in the same PostgreSQL transaction. Unchanged targeting, source/app metadata changes, and stale rejected updates do not create work.

After commit, the API attempts a target-lane handoff without waiting for reconciliation or APNs. [`DispatchPresenceReconciliationScheduledJob`](../Sources/App/Jobs/DispatchPresenceReconciliationScheduledJob.swift) drains ready intents when that best-effort handoff fails. Sequential drains stop after the ready row becomes done; concurrent selection or an enqueue/update split can still duplicate the queue handoff, which downstream reconciliation and ledger idempotency absorb. [`ReconcileInstallationAlertsJob`](../Sources/App/Jobs/ReconcileInstallationAlertsJob.swift) has three bounded queue retries (15, 60, and 300 seconds), reloads the latest authoritative presence, and queries only active, unexpired, current revisions matching that installation by H3 or UGC provenance.

Each match is handed to the existing send lane as a `NotificationSendJob` constrained to the installation. The constraint narrows candidate selection but preserves the alert-driven path's lifecycle, freshness, claim, copy, APNs environment, completion, and telemetry behavior. Location-driven work therefore cannot send directly or create a parallel delivery authority.

### Queue retries and replay limits

Production `.dispatch(...)` calls default to Vapor Queues' `maxRetryCount` of `0`, so most dequeued job failures are not retried by Vapor Queues. `NotificationSendJob` is an explicit exception: every producer dispatches it with three retries using capped delays of 30, 120, and 300 seconds. A retry processes only ledger rows already marked `retrying` and owned by that queue job, atomically reclaims each row with a retry-generation compare-and-swap, and revalidates current installation, subscription, targeting, and location-freshness eligibility before APNs delivery. A queue retry that failed before creating an owned retry row does not perform fresh candidate discovery. `ReconcileInstallationAlertsJob` is also explicitly retryable because rediscovery and constrained send dispatch converge on the ledger identity; `PressureArtifactFailureCompletionJob` separately uses its configured completion schedule on the `model-artifacts` lane. Outbox drain attempts and reconciliation retries remain distinct from APNs delivery retries.

## Candidate selection, claim, and APNs delivery

[`NotificationCandidateStore`](../Sources/App/Models/Notification/NotificationCandidateStore.swift) owns H3/UGC candidate selection. [`NotificationSendJob`](../Sources/App/Jobs/NotificationSendJob.swift) first verifies revision and lifecycle eligibility, then applies per-candidate freshness gating. Stale candidates receive a missed-decision record rather than a delivery claim.

For a delivery-eligible candidate (`fresh` or `degraded`), [`NotificationDeliveryStore.claim(...)`](../Sources/App/Models/Notification/NotificationDeliveryStore.swift) atomically inserts `notification_ledger` with `ON CONFLICT DO NOTHING`. [`CreateNotificationLedger`](../Sources/App/Migrations/CreateNotificationLedger.swift) enforces `UNIQUE(installation_id, series_id, revision_urn)`. `mode` and `reason` are recorded on a claim but do not participate in its deduplication identity.

After a successful claim, [`NotificationEngine.buildNotification(...)`](../Sources/App/Infrastructure/Notifications/NotificationEngine.swift) builds candidate-specific title, subtitle, and body; the send job then sends APNs using that candidate’s environment. [`NotificationDebugModel`](../Sources/App/Models/Notification/NotificationDebugModel.swift) records the composed preview/candidate copy for diagnostics. [`NotificationSendAttemptModel`](../Sources/App/Models/Notification/NotificationSendAttemptModel.swift) records a send-job attempt summary. Neither is the dispatch-intent outbox or an APNs-delivery guarantee.

On APNs success, `NotificationDeliveryStore.completeSent(...)` completes the claimed ledger row. Classified terminal failures use `completeFailed(...)` to record `failed` and the APNs error code. Delivery is sequential within the job.

APNs service throttling, service/server failures, shutdown/idle responses, and transport failures with unknown token validity transition the claim to non-terminal `retrying` and throw a dedicated job error after attempt telemetry is recorded. A retry atomically transitions only the owning job's matching `retrying` generation back to `claimed`; concurrent or stale retry attempts therefore have one database winner. Non-retryable request/provider failures become terminal `failed`. Responses proving that the exact device token is invalid or unregistered atomically complete the ledger failure and conditionally deactivate the installation, but only while it still stores the token that failed, so a late response cannot deactivate a replacement token. Retry exhaustion terminalizes only the queue job's remaining owned `retrying` rows.

## Primary alert pipeline latency

The primary latency sample runs from `alert_revisions.received` to the first original
alert-driven APNs attempt boundary. Send producers explicitly identify `alertDriven`
or `presenceReconciliation` origin in the queued payload; a winning ledger claim
persists that origin in `delivery_origin`. Legacy payloads and historical ledger rows
retain unknown origin and are excluded rather than heuristically classified or backfilled.

The job captures `first_apns_attempt_started_at` immediately before invoking the
sender and persists that captured value atomically with the ledger outcome, including
failed requests. Retries cannot create or replace it. The dashboard takes the minimum
original-path boundary per revision, giving at most one sample regardless of
installations or H3/UGC fan-out. Reconciliation, retry delay, and provider response
time do not contribute to its duration. Existing APNs outcome telemetry remains
separate. The dashboard's legacy `endToEndLatency.successfulRevisionCount` JSON field
now counts sampled revisions, including failed initial requests; its wire name is
preserved for compatibility. The primary rolling distribution exposes p50, p95, max,
and sample count, with p95 as the operational value. Stage distributions expose p50,
p95, and their own sample counts. Ordinary stages use the notification timing row
associated with the first qualifying APNs boundary; duplicate executions that did not
own that boundary are excluded. A persisted zero candidate count is the exception:
that execution contributes only stages it reached, even without an APNs boundary.

An in-flight original request has no persisted boundary until its outcome is recorded.
Process loss or outcome-write failure can leave its claim without timing. The dashboard
withholds a revision's sample while any original claim lacks timing, rather than using
a later known attempt as the first. Thus incomplete or abandoned original deliveries
can reduce sample coverage without fabricating a start or affecting delivery authority.

### Persisted stage timing

`target_pipeline_timings` records each identified target queue execution. A new
optional `targetExecutionId` is generated at each Redis handoff, retained on replay,
and keys the paired target boundaries. It is indexed by series/revision:
`queued_at` is captured immediately before Redis dispatch, `started_at` at dequeue,
and `h3_completed_at` captured after successful coverage persistence, before
notification intent creation in the same transaction. The captured completion is
written after the transaction commits, so a timing-storage failure cannot roll back
coverage or notification intent. UGC-only paths have no target row; point/cover-failure fallback retains a
target start but has no completed H3 stage. A failed first execution remains incomplete
rather than acquiring a completion from replay. The unique notification intent
records its creating target execution in immutable `source_target_execution_id`.
Duplicates and outbox replay cannot overwrite that association. Direct ingest UGC
intents retain nil; target-originated UGC fallback retains its execution identity
without fabricating an H3 completion. This is correlation, not delivery authority.

`notification_pipeline_timings` records the initial execution of each explicitly
alert-driven, unconstrained send payload. Its `delivery_attempt_id` is the existing
payload identity and matches `LOWER(notification_ledger.retry_owner_id)` when
cast to PostgreSQL UUID text (Swift UUID strings use uppercase). `queued_at`
is captured at notification Redis handoff, `started_at` at dequeue, and
`candidate_resolution_completed_at` with `candidate_count` immediately after the
H3/UGC candidate query,
before freshness gating, ledger claims, copy composition, or APNs. Zero-candidate
queries persist this boundary too, with no fabricated APNs endpoint. Reconciliation,
unknown-origin payloads, and queue retries cannot create initial execution evidence;
replay of the same payload cannot overwrite or fill missing first-execution stages.

Reuse `alert_revisions.received`, target and notification outbox `created` timestamps
for durable intent creation, and the existing qualifying ledger APNs boundary. Outbox
`dispatched`/`updated`/`completed` describe handoff acknowledgement or mutable state,
so they cannot replace the captured queue-entry/execution boundaries: a consumer can
start before the producer records acknowledgement. New queued payload fields are
optional for compatibility; missing historical queue-entry times remain unknown.

For the first qualifying APNs ledger row, join its retry owner to its notification
stage row, then join that row's `source_target_execution_id` to the target timing's
`execution_id`. Never substitute another target execution by revision. The selected
H3 intent can come from a faster concurrent duplicate rather than the first starter.
Missing identity or timing leaves the target duration unavailable. Derive:

| Duration | Persisted boundaries |
|---|---|
| Initial handoff | revision receipt → applicable target/send queue entry (outbox creation additionally separates intent delay) |
| Target queue wait | target queue entry → target start |
| H3/target processing | target start → H3 completion |
| Notification handoff | H3 completion → send queue entry; for direct UGC, revision receipt → send queue entry |
| Notification queue wait | send queue entry → send start |
| Candidate resolution | send start → candidate resolution completion |
| Notification preparation/APNs handoff | candidate resolution completion → first qualifying ledger APNs start |
| Total pipeline | revision receipt → first qualifying ledger APNs start |

Use the existing primary-sample completeness rules when choosing the first APNs row.
Keep that row's execution stages together; independent minima across send attempts
can splice unrelated H3/UGC paths. For zero-candidate analysis, use stage rows directly
without requiring a ledger join. Missing boundaries yield unavailable durations,
and UGC's H3 duration is not applicable. Timing rows cascade with series deletion. Stage writes are best-effort operational
evidence: failures warn and allow delivery to continue, leaving boundaries unavailable.
They do not grant delivery authority or change APNs retry behavior.

## Guarantees and explicit gaps

- The ledger provides a database-enforced, at-most-one claim boundary for `(installation_id, series_id, revision_urn)`.
- It does **not** guarantee exactly-once APNs delivery or eventual delivery. A process loss or cancellation after a claim can leave it `claimed`; an unknown APNs outcome cannot safely be inferred from the claim; exhausted or terminally classified rows remain `failed`.
- Bounded APNs retry covers classified transient send outcomes only. General queue replay after consumer failure, abandoned-claim recovery, and a stored-payload redesign remain deferred reliability work. They are not implemented by the outboxes, ledger, Swift concurrency, or `Sendable`.

## Deployment and client-retirement gate

Before any SkyAware WatchEngine notification producer is removed, a deployed Arcus Signal release must show:

- presence-reconciliation intents are created for meaningful transitions, drain without a growing ready/dead backlog, and retain bounded failure metadata;
- reconciliation logs show plausible match and constrained-dispatch counts for H3 and UGC traffic without repeated exhaustion;
- constrained send-attempt telemetry reaches candidate resolution and records expected delivered, previously-claimed, stale, and zero-candidate outcomes;
- ledger rows confirm one `(installation_id, series_id, revision_urn)` claim across alert-driven and location-driven discovery, with failed or abandoned claims investigated under the existing delivery limitations.

Passing tests establishes release readiness, not production validation. Client WatchEngine removal is a separate campaign and is prohibited until these deployed observations succeed.

## Recovered owner map

| Concern | Current owner and invariant |
|---|---|
| API dependency graph | [`installAPIRequestDependencies(on:)`](../Sources/App/StormSetup/APIDependencyComposition.swift) constructs and stores the API request graph once. |
| Worker lifecycle | [`configure(_:mode:)`](../Sources/App/configure.swift) and [`WorkerRuntime`](../Sources/App/Worker/WorkerRuntime.swift) own worker configuration, consumers, schedules, and APNs setup. |
| NWS persistence and target intent | [`NWSIngestPersistence`](../Sources/App/Services/NWSIngestPersistence.swift) owns the ingest transaction script and target-dispatch intent creation. |
| Target queue handoff | [`IngestNWSAlertsJob`](../Sources/App/Jobs/IngestNWSAlertsJob.swift) drains `target_dispatch_outbox`. |
| H3/UGC targeting orchestration | [`TargetEventRevisionJob`](../Sources/App/Jobs/TargetEventRevisionJob.swift) and [`DispatchAgent`](../Sources/App/lib/DispatchAgent.swift) preserve targeting and notification-dispatch behavior. |
| Presence transition and durable intent | [`DeviceController`](../Sources/App/Controllers/DeviceController.swift), [`PresenceReconciliationTrigger`](../Sources/App/Infrastructure/Notifications/PresenceReconciliationTrigger.swift), and [`PresenceReconciliationOutboxStore`](../Sources/App/Models/Notification/PresenceReconciliationOutboxStore.swift) own meaningful-transition policy and transactional intent persistence. |
| Installation-to-alert reconciliation | [`DispatchPresenceReconciliationScheduledJob`](../Sources/App/Jobs/DispatchPresenceReconciliationScheduledJob.swift) and [`ReconcileInstallationAlertsJob`](../Sources/App/Jobs/ReconcileInstallationAlertsJob.swift) own durable target-lane handoff, latest-presence lookup, and constrained send dispatch. |
| Candidate selection | [`NotificationCandidateStore`](../Sources/App/Models/Notification/NotificationCandidateStore.swift) owns H3/UGC candidate queries. |
| Delivery claim/completion | [`NotificationDeliveryStore`](../Sources/App/Models/Notification/NotificationDeliveryStore.swift) owns atomic ledger claim and terminal completion persistence. |
| Copy composition | [`NotificationEngine`](../Sources/App/Infrastructure/Notifications/NotificationEngine.swift) owns send-time notification wording. |
| Storm Setup attempts/policy | [`StormSetupProvider`](../Sources/App/StormSetup/StormSetupProvider.swift), [`AnvilProfilePreviewProvider`](../Sources/App/StormSetup/AnvilProfilePreviewProvider.swift), and [`AnvilProfileAnalysisProvider`](../Sources/App/StormSetup/AnvilProfileAnalysisProvider.swift) own the recovered request/attempt seams. |

## Supporting evidence

The recovered boundaries are characterized by [`NWSIngestPersistenceFlowTests.swift`](../Tests/AppTests/NWSIngestPersistenceFlowTests.swift), [`TargetEventRevisionJobFallbackTests.swift`](../Tests/AppTests/TargetEventRevisionJobFallbackTests.swift), [`LocationDrivenAlertReconciliationFlowTests.swift`](../Tests/AppTests/LocationDrivenAlertReconciliationFlowTests.swift), [`NotificationSendJobCandidateQueryTests.swift`](../Tests/AppTests/NotificationSendJobCandidateQueryTests.swift), [`NotificationSendJobDeliveryBoundaryTests.swift`](../Tests/AppTests/NotificationSendJobDeliveryBoundaryTests.swift), [`NotificationLedgerFreshnessPersistenceTests.swift`](../Tests/AppTests/NotificationLedgerFreshnessPersistenceTests.swift), [`APIDependencyCompositionTests.swift`](../Tests/AppTests/APIDependencyCompositionTests.swift), [`StormSetupProviderTests.swift`](../Tests/AppTests/StormSetupProviderTests.swift), and [`StormSetupAnvilEvidencePolicyTests.swift`](../Tests/AppTests/StormSetupAnvilEvidencePolicyTests.swift).
