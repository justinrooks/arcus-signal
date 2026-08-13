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
```

The arrows are distinct boundaries. A durable intent, successful queue enqueue, job completion, APNs completion, debug copy, and attempt telemetry are not interchangeable evidence.

## Dispatch intents and queue handoff

### Target dispatch

[`NWSIngestPersistence.enqueueTargetDispatchOutboxIfNeeded(...)`](../Sources/App/Services/NWSIngestPersistence.swift) writes one `target_dispatch_outbox` row for a geometry-bearing revision. [`CreateTargetDispatchOutbox`](../Sources/App/Migrations/CreateTargetDispatchOutbox.swift) enforces `UNIQUE(revision_urn)`.

[`IngestNWSAlertsJob.dispatchPendingTargetJobs(...)`](../Sources/App/Jobs/IngestNWSAlertsJob.swift) selects rows without `dispatched`, enqueues `TargetEventRevisionJob`, and then sets `dispatched`, increments `attempt_count`, and records any enqueue error. This outbox represents target-job queue handoff only. A `dispatched` row is not evidence that the target consumer completed; if database update fails after enqueue, a later drain can enqueue the job again.

### Notification dispatch

[`DispatchAgent.enqueueNotificationDispatchOutbox(...)`](../Sources/App/lib/DispatchAgent.swift) writes `notification_outbox` intent for a `(series_id, revision_urn, mode)` and records the triggering reason. [`CreateNotificationOutbox`](../Sources/App/Migrations/CreateNotificationOutbox.swift) enforces that identity. The row contains revision, mode, reason, queue-dispatch state, queue-dispatch attempts, availability, and errors. It contains neither installation identity nor rendered APNs content.

[`DispatchAgent.dispatchPendingNotificationJobs(...)`](../Sources/App/lib/DispatchAgent.swift) enqueues `NotificationSendJob`, then marks the row `done` after successful queue enqueue. Its `attempts`, `available_at`, and `last_error` describe attempts to hand work to the send queue, not APNs delivery retries. A queue handoff can be duplicated if the subsequent row update fails; downstream ledger uniqueness absorbs a duplicate claim. Conversely, marking `done` does not provide consumer-completion replay.

### Presence reconciliation

[`DeviceController`](../Sources/App/Controllers/DeviceController.swift) compares the previously persisted installation/presence state with the accepted authoritative result. First usable presence, a changed H3/UGC targeting fingerprint, or an unusable/hard-stale state becoming usable writes a `presence_reconciliation_outbox` intent in the same PostgreSQL transaction. Unchanged targeting, source/app metadata changes, and stale rejected updates do not create work.

After commit, the API attempts a target-lane handoff without waiting for reconciliation or APNs. [`DispatchPresenceReconciliationScheduledJob`](../Sources/App/Jobs/DispatchPresenceReconciliationScheduledJob.swift) drains ready intents when that best-effort handoff fails. Sequential drains stop after the ready row becomes done; concurrent selection or an enqueue/update split can still duplicate the queue handoff, which downstream reconciliation and ledger idempotency absorb. [`ReconcileInstallationAlertsJob`](../Sources/App/Jobs/ReconcileInstallationAlertsJob.swift) has three bounded queue retries (15, 60, and 300 seconds), reloads the latest authoritative presence, and queries only active, unexpired, current revisions matching that installation by H3 or UGC provenance.

Each match is handed to the existing send lane as a `NotificationSendJob` constrained to the installation. The constraint narrows candidate selection but preserves the alert-driven path's lifecycle, freshness, claim, copy, APNs environment, completion, and telemetry behavior. Location-driven work therefore cannot send directly or create a parallel delivery authority.

### Queue retries and replay limits

Production `.dispatch(...)` calls default to Vapor Queues' `maxRetryCount` of `0`, so most dequeued job failures are not retried by Vapor Queues. `ReconcileInstallationAlertsJob` is explicitly retryable because rediscovery and constrained send dispatch converge on the ledger identity; `PressureArtifactFailureCompletionJob` separately uses its configured completion schedule on the `model-artifacts` lane. Outbox drain attempts and reconciliation retries are not substitutes for general queue replay or APNs retry.

## Candidate selection, claim, and APNs delivery

[`NotificationCandidateStore`](../Sources/App/Models/Notification/NotificationCandidateStore.swift) owns H3/UGC candidate selection. [`NotificationSendJob`](../Sources/App/Jobs/NotificationSendJob.swift) first verifies revision and lifecycle eligibility, then applies per-candidate freshness gating. Stale candidates receive a missed-decision record rather than a delivery claim.

For a delivery-eligible candidate (`fresh` or `degraded`), [`NotificationDeliveryStore.claim(...)`](../Sources/App/Models/Notification/NotificationDeliveryStore.swift) atomically inserts `notification_ledger` with `ON CONFLICT DO NOTHING`. [`CreateNotificationLedger`](../Sources/App/Migrations/CreateNotificationLedger.swift) enforces `UNIQUE(installation_id, series_id, revision_urn)`. `mode` and `reason` are recorded on a claim but do not participate in its deduplication identity.

After a successful claim, [`NotificationEngine.buildNotification(...)`](../Sources/App/Infrastructure/Notifications/NotificationEngine.swift) builds candidate-specific title, subtitle, and body; the send job then sends APNs using that candidate’s environment. [`NotificationDebugModel`](../Sources/App/Models/Notification/NotificationDebugModel.swift) records the composed preview/candidate copy for diagnostics. [`NotificationSendAttemptModel`](../Sources/App/Models/Notification/NotificationSendAttemptModel.swift) records a send-job attempt summary. Neither is the dispatch-intent outbox or an APNs-delivery guarantee.

On APNs success, `NotificationDeliveryStore.completeSent(...)` completes the claimed ledger row. On APNs failure, `completeFailed(...)` records `failed` and any APNs error code. Delivery is sequential within the job.

## Guarantees and explicit gaps

- The ledger provides a database-enforced, at-most-one claim boundary for `(installation_id, series_id, revision_urn)`.
- It does **not** guarantee exactly-once APNs delivery or eventual delivery. A process loss or cancellation after a claim can leave it `claimed`; an unknown APNs outcome cannot safely be inferred from the claim; failed rows are terminal today.
- APNs retry/backoff and failure classification, queue replay after consumer failure, abandoned-claim recovery, and a stored-payload redesign are deferred reliability work. They are not implemented by the outboxes, ledger, Swift concurrency, or `Sendable`.

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
