# Arcus Signal Server Architecture

## Purpose

Arcus Signal ingests NWS alert revisions, targets eligible installations by H3 or UGC coverage, and sends APNs notifications. This document describes the implemented runtime, persistence boundaries, and delivery guarantees. It is the living architecture reference; [epics-stories.md](epics-stories.md) is historical planning.

## Runtime ownership

- **API (`Run`)** configures HTTP routes and API-scoped Storm Setup/Anvil dependencies. [`configure(_:mode:)`](../Sources/App/configure.swift) calls [`installAPIRequestDependencies(on:)`](../Sources/App/StormSetup/APIDependencyComposition.swift) once for `.api`; this establishes the request graph without starting queue consumers or schedulers.
- **Worker (`RunWorker`)** configures APNs, queue settings, worker-only routes, schedules, and queues. [`configure(_:mode:)`](../Sources/App/configure.swift) installs [`WorkerRuntime`](../Sources/App/Worker/WorkerRuntime.swift), whose `startWorkerRuntime(on:)` starts consumers for the configured lanes and the scheduled jobs.
- Both processes share PostgreSQL and Redis/Vapor Queues. The API does not deliver APNs notifications; APNs setup and send execution are worker-owned.

### Queue topology

[`ArcusQueueLane`](../Sources/App/Worker/ArcusQueueLane.swift) defines the `ingest`, `target`, `send`, and `model-artifacts` lanes. Worker configuration applies the same `QUEUE_WORKER_COUNT` to Vapor Queues, with a minimum and default of `1`, through [`configureWorkerQueueSettings(on:)`](../Sources/App/configure.swift). Before any consumer or schedule starts, [`WorkerRuntime`](../Sources/App/Worker/WorkerRuntime.swift) atomically returns abandoned registered model-artifact jobs to waiting while preserving and reporting unknown or malformed entries; failed reconciliation shuts the worker down. After successful reconciliation, `WorkerRuntime` starts consumers for every lane.

## AirNow dependency visibility

The API records real AirNow fetch outcomes in the singleton
`airnow_dependency_status` row. The AirNow client preserves HTTP, transport,
missing-data, and decode classifications; the AQI provider determines whether
observations yield usable AQI. Cache hits do not write upstream health evidence.
API startup records disabled/unconfigured state without contacting AirNow.
The worker reads this row on the dashboard's fast-refresh lane; dashboard
rendering remains passive and `/health` is independent of AirNow.

Writes use a PostgreSQL transaction advisory lock. Latest outcome follows
completion time (including older-started fetches finishing last) with a stable
tie-breaker; late successes retain timestamp
watermarks and conservatively reset any interrupted failure streak. The record
contains bounded operational classifications and timing only, with no location,
device, AQI value, downstream error text, or API key. A telemetry write failure
warns without changing the public AQI result.

Healthy means the latest real outcome produced usable AQI. Other known outcomes
are Warning; absent evidence is Unknown. Critical requires at least two accepted
failure completions in a streak lasting 90 minutes (twice the AQI cache lifetime)
and no usable AQI in that interval. One failed attempt cannot age into Critical.
Idle time alone cannot promote transient failures. Equal-time updates count as
one failure observation. A subsequent usable result restores Healthy and clears
the failure streak.

## SPC mesoscale coverage

`SPCMesoIngestPersistence` accepts canonical meso snapshots and their polygon coverage
in one PostgreSQL transaction under the existing feed-write lock. `SPCMesoCoverage`
validates polygon input and delegates to `H3CoverageBuilder` for sorted, deduplicated
resolution-8 cells and canonical geometry/H3 hashes. Unchanged completed coverage
skips computation and geolocation writes; replay fills legacy rows with nil coverage
metadata. Changed geometry replaces all coverage fields atomically. Missing geometry
remains readable without a geolocation row. Coverage failure throws a product-specific
error and rolls back the accepted feed, retaining the previous snapshot and cover.
`MESO_NOTIFICATIONS_ENABLED` is a shared API/worker ownership gate and defaults off; absent or other values do not enable it. When enabled, the worker must have valid sandbox and production APNs credential pairs configured before startup succeeds, because the API may acknowledge ownership for installations in either environment. The preference-sync acknowledgment reports configured server ownership from this gate and the installation's persisted subscription and explicit meso preference. It does not report transient worker health or guarantee APNs delivery. With the gate enabled, accepted active products with completed nonempty resolution-8 coverage also write a meso notification intent in the same transaction. Coverage failure therefore rolls back both canonical data and intent creation. Meso targeting has no fallback.

H3 polyfill selects cells by their centers. Matching a location's cell therefore
approximates the polygon boundary: a point just outside can share an included cell,
and a point just inside can share an excluded cell. Tiny polygons can produce an
empty cover. This deliberately differs from the app's prior exact point-in-polygon
check; no ring expansion or broad fallback compensates for boundary misses.

The authenticated development-only `POST /v1/dev/notification-test` endpoint accepts a short-lived synthetic TEST meso through canonical polygon/H3 persistence. With the existing meso rollout gate enabled, acceptance atomically writes the ordinary event-first notification intent; the worker's existing drain handles unfiltered fanout, eligibility, claims, retries, and APNs. The requested `installationId` validates registration and provides correlation only; it neither changes presence nor constrains recipients. The response returns `202`, `status: accepted`, the unique `productID` as test identifier, the requested `installationId`, expiry, and `notificationStatus: pending` (durable intent awaiting worker handoff) or `disabled` (gate off). It does not report queue consumption, APNs acceptance, or device receipt. Reserved synthetic products carry explicit TEST notification copy. The endpoint remains absent outside development and requires its separate enablement and bearer secret; enable the shared rollout gate only in the isolated development deployment. Production enablement remains separately gated.

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

NWS snapshot advancement locks the series row and invalidates its previous geolocation in the same transaction, including transitions to nil or point geometry. Target workers compute H3 coverage before opening their transaction, then lock the same series row and accept coverage plus notification intent only when the payload revision is still canonical. Series merges never borrow a losing series' coverage. Until current polygon coverage completes, API geometry/H3 and H3 discovery remain empty; existing UGC policies still apply. The send job rechecks canonical revision after eager loading to reject mixed reads across snapshot advancement.

### Notification dispatch

Delivery subject identity in `notification_outbox`, `notification_ledger`,
`notification_debug`, and `notification_send_attempts` accepts any nonblank kind,
product ID, and revision ID. Explicit tuples must be complete and their revision
must equal `revision_urn`. `nws` requires its matching CAP `series_id`; all other
kinds require a null series. Legacy series-only NWS writes remain valid and
resolve to NWS subjects on read. Known `.nws` and `.spcMeso` kinds retain typed
call sites; future kinds round-trip without a schema registration step.
The existing drain remains explicitly NWS-only. Recognition grants no sender policy. `MesoNotificationOutboxStore` separately claims only `spc-meso` H3 intents with the stable `initial` delivery revision, using the same five-minute lease and bounded queue-handoff backoff. The worker drains these intents after ingestion and on a minutely recovery schedule, only while the meso gate is enabled. Redis awaits hold no database locks, and completion is fenced by the exact lease. Changed accepted content can ready a completed intent again to reach newly matching installations; unchanged replay cannot reset it, and the discussion-level ledger prevents another send to an already claimed installation.

`MakeNotificationSubjectKindsExtensible` replaces the four constraints atomically
after the original identity migration, preserving its backfill, foreign keys,
and uniqueness indexes. Rollback restores the original `nws`/`spc-meso` allowlist
and refuses atomically while any other kind exists; those records must be handled
explicitly before rollback. It never deletes or rewrites delivery history.

[`DispatchAgent.enqueueNotificationDispatchOutbox(...)`](../Sources/App/lib/DispatchAgent.swift) writes `notification_outbox` intent for a `(series_id, revision_urn, mode)` and records the triggering reason. [`CreateNotificationOutbox`](../Sources/App/Migrations/CreateNotificationOutbox.swift) enforces that identity. The row contains revision, mode, reason, queue-dispatch state, queue-dispatch attempts, availability, and errors. It contains neither installation identity nor rendered APNs content.

[`DispatchAgent.dispatchPendingNotificationJobs(...)`](../Sources/App/lib/DispatchAgent.swift) uses [`NotificationDispatchOutboxStore`](../Sources/App/Models/Notification/NotificationDispatchOutboxStore.swift) to atomically claim a mode-specific bounded batch with `FOR UPDATE SKIP LOCKED`. Eligible `ready` rows and expired `processing` rows become `processing` with a five-minute lease in `available_at`. The claim statement commits before queue handoff; no row locks are held across Redis awaits. Replay cannot modify processing rows, including expired leases, whose recovery belongs to the claim path.

After enqueueing `NotificationSendJob`, completion conditionally marks only the same processing lease `done`, increments `attempts`, and clears `last_error`. Failed handoff conditionally increments attempts and returns the row to `ready` with 30/120-second backoff, or to `dead` at three attempts. Its `attempts`, `available_at`, and `last_error` describe queue handoff, not APNs delivery retries. Handoff remains at least once: enqueue followed by a crash or completion-write failure can be duplicated after lease recovery; downstream ledger uniqueness absorbs a duplicate claim. Marking `done` does not provide consumer-completion replay.

### Presence reconciliation

[`DeviceController`](../Sources/App/Controllers/DeviceController.swift) compares the previously persisted installation/presence state with the accepted authoritative result. First usable presence, a changed H3/UGC targeting fingerprint, or an unusable/hard-stale state becoming usable writes a `presence_reconciliation_outbox` intent in the same PostgreSQL transaction. Unchanged targeting, source/app metadata changes, and stale rejected updates do not create work.

After commit, the API attempts a target-lane handoff without waiting for reconciliation or APNs. [`DispatchPresenceReconciliationScheduledJob`](../Sources/App/Jobs/DispatchPresenceReconciliationScheduledJob.swift) drains ready intents when that best-effort handoff fails. Sequential drains stop after the ready row becomes done; concurrent selection or an enqueue/update split can still duplicate the queue handoff, which downstream reconciliation and ledger idempotency absorb. [`ReconcileInstallationAlertsJob`](../Sources/App/Jobs/ReconcileInstallationAlertsJob.swift) has three bounded queue retries (15, 60, and 300 seconds), reloads the latest authoritative presence, and queries only active, unexpired, current revisions matching that installation by H3 or UGC provenance.

Each match is handed to the existing send lane as a `NotificationSendJob` constrained to the installation. The constraint narrows candidate selection but preserves the alert-driven path's lifecycle, freshness, claim, copy, APNs environment, completion, and telemetry behavior. Location-driven work therefore cannot send directly or create a parallel delivery authority.

### Queue retries and replay limits

Production `.dispatch(...)` calls default to Vapor Queues' `maxRetryCount` of `0`, so most dequeued job failures are not retried by Vapor Queues. `NotificationSendJob` is an explicit exception: every producer dispatches it with three retries using capped delays of 30, 120, and 300 seconds. A retry processes only ledger rows already marked `retrying` and owned by that queue job, atomically reclaims each row with a retry-generation compare-and-swap, and revalidates current installation, subscription, targeting, and location-freshness eligibility before APNs delivery. An NWS queue retry that failed before creating an owned retry row does not perform fresh candidate discovery. `MesoNotificationSendJob` uses the same bounded retry delays, but allows pre-claim recovery while no ledger row exists for its discussion and retry owner; after its first persisted claim, only owned retrying rows are eligible. `ReconcileInstallationAlertsJob` is also explicitly retryable because rediscovery and constrained send dispatch converge on the ledger identity; `PressureArtifactFailureCompletionJob` separately uses its configured completion schedule on the `model-artifacts` lane. Outbox drain attempts and reconciliation retries remain distinct from APNs delivery retries.

## Candidate selection, claim, and APNs delivery

[`NotificationCandidateStore`](../Sources/App/Models/Notification/NotificationCandidateStore.swift) owns H3/UGC candidate selection. [`NotificationSendJob`](../Sources/App/Jobs/NotificationSendJob.swift) first verifies revision and lifecycle eligibility, then applies per-candidate freshness gating. Stale candidates receive a missed-decision record rather than a delivery claim.

For a delivery-eligible candidate (`fresh` or `degraded`), [`NotificationDeliveryStore.claim(...)`](../Sources/App/Models/Notification/NotificationDeliveryStore.swift) atomically inserts `notification_ledger` with `ON CONFLICT DO NOTHING`. [`CreateNotificationLedger`](../Sources/App/Migrations/CreateNotificationLedger.swift) enforces `UNIQUE(installation_id, series_id, revision_urn)`. `mode` and `reason` are recorded on a claim but do not participate in its deduplication identity.

SPC meso producers use `NotificationSubject.spcMeso(issueYear:number:)` and
`NotificationDeliveryStore.claimMeso(...)`. The product ID is the canonical
`SPC-MD-<issueYear>-<number>`; the delivery revision is always `initial`.
Content fingerprints, watch probabilities, polygon/H3 coverage, last-seen times,
targeting modes, reasons, and producer origins never change this identity.
The existing partial unique index enforces one claim per installation and
discussion; atomic insert conflict handling permits only one delivery winner.
A claim is not evidence of a successful send. Transient failure uses the existing
`markRetrying(...)` transition, then `reclaimRetryingMeso(...)` on the same row,
fenced by product, installation, retry owner and generation.
`loadRetryingMesoDeliveries(...)` discovers the owning job's retries;
`hasMesoRetryInFlight(...)` detects its claimed work. Ineligible retries use
`completeRetryingMesoFailure(...)`, and exhaustion uses
`failRetryingMesoDeliveries(...)` for only that subject and owner.
A competing producer
cannot obtain a fresh claim or take over an owned retry. Intentional re-notification
of an existing MD requires a separately approved policy and delivery-revision
change; canonical content updates must never implicitly enable it.
`MesoNotificationSendJob` consumes these primitives behind the disabled runtime gate. It loads current canonical content and matches only active, subscribed installations whose explicit meso preference is true, whose presence uses resolution-8 H3 matching completed coverage, and whose location passes the existing freshness policy. Unknown capability, UGC-only presence, invalid resolution, and stale authorization/location are excluded. The gate is checked at execution and again before sending, including queued retries. Composition follows a successful ledger claim and uses the typed mesoscale-discussion APNs resource identity. The send lane owns three retries with 30/120/300-second delays. Before any claim exists for the discussion and retry owner, a queue retry may repeat candidate discovery to recover transient pre-claim read failures. Once any owned ledger claim exists, regardless of status, executions process only owned retrying rows and cannot broaden to new candidates. A claim committed before a lost database response also establishes this boundary. Pre-claim recovery remains bounded by the queue retry budget; outbox completion continues to represent successful queue handoff. Presence reconciliation also queries active canonical meso coverage through the same H3 eligibility predicates and enqueues `MesoNotificationSendJob` constrained to the moving installation. Send-time eligibility is rechecked against current presence; the optional installation constraint persists through retries and records `presenceReconciliation` origin. Both discovery paths use the same stable discussion subject and atomic ledger claim, so moves and content refreshes cannot create another delivery. The meso rollout gate controls both paths and remains disabled by default.
NWS CAP revision identity and retry paths remain unchanged.

After a successful claim, [`NotificationEngine.buildNotification(...)`](../Sources/App/Infrastructure/Notifications/NotificationEngine.swift) builds candidate-specific title, subtitle, and body; the send job then sends APNs using that candidate’s environment. [`NotificationDebugModel`](../Sources/App/Models/Notification/NotificationDebugModel.swift) records the composed preview/candidate copy for diagnostics. [`NotificationSendAttemptModel`](../Sources/App/Models/Notification/NotificationSendAttemptModel.swift) records a send-job attempt summary. Neither is the dispatch-intent outbox or an APNs-delivery guarantee.

On APNs success, `NotificationDeliveryStore.completeSent(...)` completes the claimed ledger row. Classified terminal failures use `completeFailed(...)` to record `failed` and the APNs error code. Delivery is sequential within the job.

`notification_send_attempts` records one bounded execution summary for NWS and meso send jobs, including candidate resolution/count, claims, sends, failures, retryable outcomes, and no-op reason. Meso send jobs also write best-effort `notification_debug` preview rows when no candidates match and candidate-specific composed copy after a successful ledger claim. This diagnostic telemetry does not replace the per-installation ledger as delivery and deduplication authority. Dashboard notification metrics retain all-kind totals and expose SPC meso counts and failure reasons by subject kind. Recent dashboard notification debug evidence reserves up to five of its 30 rows for SPC meso entries, with the remaining capacity filled by the newest entries from other subjects. Meso end-to-end delivery latency measures from the discussion first-seen timestamp to the first successful alert-driven delivery per product; products without a successful delivery are excluded. Meso eligible-candidate totals sum rows returned per send attempt after location freshness and authorization policy plus retry-owner filtering, so retries can count the same installation again; exclusions before the initial active, subscribed, preference-enabled, and H3-coverage query are not counted individually.

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

## Device installation authority

Device enrollment and authenticated v2 mutations use the ArcusCore 0.6.0 contract. See [Installation enrollment and authenticated device writes](device-enrollment.md) for verifier persistence, transactional authorization, the temporary v1 compatibility boundary, and the required server-before-client deployment order. Claimed installations reject all v1 writes; enrollment and every device mutation serialize at the installation UUID, including before a delivery row exists.

## V3 installation consent

Signal adopts ArcusCore 0.7.0 for authenticated `/v3/devices/preferences`, `/v3/devices/location-snapshots`, and `/v3/devices/foreground-activity`, with `/api` aliases. Enrollment remains v2. Preferences alone own the complete four-field consent snapshot; location alone owns presence using existing `capturedAt` ordering and optional-field merge semantics. Activity requires initialized v3 consent and writes only activity. All mutations authorize and check admission inside the existing per-installation advisory-lock transaction.

`device_installations.consent_revision` is nullable for legacy installations and is itself the permanent v3 protocol floor. First accepted v3 preferences set it atomically with canonical consent; every later mutating v1/v2 request is rejected. Enrollment stays idempotent. `location_sharing_enabled` defaults/backfills true for unversioned rows. Rollback is allowed before adoption but refuses any populated revision, preserving the privacy fence; rollback of the application to a version unaware of this fence is unsafe after adoption.

Higher revisions replace the complete snapshot. Equal revisions require identical consent and may refresh metadata/APNs binding independently; omitted/null token preserves token and environment, and a supplied token updates both. This does not establish independent token freshness. Older revisions return current accepted revision/ownership without any metadata, binding, presence, or reconciliation effects. Conflicting equal revisions return 409. Tokenless initialization stores an empty binding, excluded by candidate query guards. Location/activity return 409 before initial consent. Location returns ignored without effects when accepted sharing or location authorization disallows it, stale for older observations, and accepted otherwise.

Accepted sharing gates NWS/meso candidates and reconciliation usability. Send jobs recheck promoted consent after ledger claim and before invoking APNs, including retry claims; historical presence remains stored. These checks cannot recall a send already started or APNs-accepted. No database transaction spans APNs. Ownership acknowledgments describe canonical consent plus rollout/authorization gates, not transient worker health or guaranteed delivery.

Deploy compatible Signal before the SkyAware v3 client. Deployment is separate from this implementation: verify old routes first, then v3 acceptance and downgrade fencing using isolated test identities, without production-user mutations or live APNs. Global legacy retirement remains #387.

## Surface cache reclamation

The worker runs `CleanupSurfaceCachesScheduledJob` every 60 seconds for the configured `grib-subsets` and `sampled-snapshots` roots only. Each root retains an incremental traversal cursor between passes, examines at most 500 filesystem entries per pass, and reads at most 1 MiB of metadata per candidate. Restart begins a new sweep. Expiry comes from the existing decoded record; removal requires expiry and metadata modification time to be at least ten minutes old. Grace affects deletion only; request freshness checks are unchanged. Unknown, malformed, unreadable, symlinked, or mismatched identities are retained. Cleanup uses descriptor-relative directory traversal without following symlinks and removes empty identity directories after unlinking recognized files.

`SurfaceCacheFileLease` defines the cooperative filesystem contract: one permanent root operation lock serializes cache filesystem operations and cleanup; 64 permanent reader-lock stripes protect GRIB result lifetimes. Stable hashing makes the stripes identical across processes. GRIB lookup/publication acquires a shared reader lease before releasing the operation lock; `HrrrFieldSampler` explicitly retains it through asynchronous sampling. Cleanup takes the operation lock and a nonblocking exclusive reader lease, skipping busy stripes. Existing invalidation also skips pinned files. Writers may atomically replace bytes for the same source identity while readers are pinned; cleanup cannot unlink those paths. Snapshot reads materialize their value before releasing the operation lock. No lock waits occupy the bounded filesystem executor; request lock acquisition retries cooperatively and honors cancellation. Lock files must never be deleted while participants run, since replacing a lock inode breaks coordination. There are at most 65 lock files per root.

For a stable tree of N entries, a sweep needs at most `ceil((N + 1) / 500)` scheduled passes per root; an entry skipped by a reader waits for a later sweep. Retention therefore includes the ten-minute grace, traversal lag, active reader lifetime, scheduler availability, and a new sweep after restart. This is not an aggregate disk capacity limit or a production capacity claim; sustained input beyond traversal capacity requires operational follow-up. Cleanup logs examined entries, removed files/logical bytes, and elapsed time per pass. Pressure-catalog files, leases, warming, stale fallback, scientific identities, and fresh Anvil evidence remain separately owned.

All readers and writers must participate before cleanup is enabled. During rollout from an older binary, stop the old API/worker processes before starting the new worker's cleanup schedule; ordinary overlapping old/new containers do not provide this guarantee. Stop cleanup before rollback to a nonparticipating binary. This code change does not authorize deployment or cleanup of production files.
