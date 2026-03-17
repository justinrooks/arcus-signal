# Event Cleanup Strategy

## Why this exists

Arcus Signal currently has good insert-side discipline and weak exit-side discipline.

We are good at:

- ingesting active NWS alerts
- creating immutable `alert_revisions`
- maintaining a mutable `arcus_series` head row
- deriving geolocation and queue handoff rows

We are not yet good at:

- deciding exactly when a series is terminal
- separating terminal-state reconciliation from data pruning
- bounding table growth without risking duplicate sends or deleting active rows

This doc describes the live data model, the current gaps, and a deterministic cleanup process that keeps the system safe.

## The live data model today

### Root record: `arcus_series`

This is the "current folder on the desk."

- One row per alert series.
- Holds the current revision pointer via `current_revision_urn`.
- Holds the current lifecycle-ish fields: `state`, `sent`, `effective`, `expires`, `ends`, `last_seen_active`.
- Returned by the client alerts API.

Important consequence:

- If `arcus_series.state = 'active'`, the alert can still show up in the API.

### Immutable history: `alert_revisions`

This is the "paper trail in the filing cabinet."

- One row per ingested revision URN.
- Linked to `arcus_series` by `series_id`.
- Used to resolve lineage from `references`.
- Deleted automatically if the parent series is deleted (`ON DELETE CASCADE`).

### Derived geometry: `arcus_geolocation`

This is the "current map overlay."

- One row per series, not one row per revision.
- Stores the latest geometry, geometry hash, H3 cells, and H3 hash.
- Deleted automatically if the parent series is deleted.

Important consequence:

- Cleanup is series-centric right now, not revision-centric.
- We do not retain old H3 covers per revision.

### Queue handoff: `target_dispatch_outbox`

This is the "ticket that says geocoding work needs to happen."

- One row per `revision_urn`.
- Exists only to get ingest work onto the `target` lane.
- Deleted automatically if the parent series is deleted.

### Queue handoff: `notification_outbox`

This is the "ticket that says a notification send job should be queued."

- One row per `(series_id, revision_urn, mode)`.
- Tracks queue-dispatch state, not per-device delivery.
- Deleted automatically if the parent series is deleted.

Important consequence:

- This table is safe to prune aggressively after dispatch has completed.
- It is not the exactly-once wall.

### Exactly-once wall: `notification_ledger`

This is the "bouncer at the door."

- One row per `(installation_id, series_id, revision_urn)`.
- Prevents duplicate sends for the same device and revision.
- Deleted automatically if the parent series or installation is deleted.

Important consequence:

- If we prune this too early while the series is still alive, replayed work could notify again.

## The current lifecycle gaps

### 1) `last_seen_active` is not a reliable "still in feed" heartbeat

Today, ingest skips duplicate revisions immediately.

That means an alert that is still present in the active NWS feed but has not changed will not refresh `arcus_series.last_seen_active`.

So right now `last_seen_active` really means:

- "last time a newer current snapshot was persisted"

not:

- "last time this series was observed in the active feed"

Cleanup cannot safely use this column for disappearance detection until ingest refreshes it for unchanged alerts too.

### 2) We do not have a complete terminal-state model

Current persisted states are:

- `active`
- `expired`
- `cancelled_in_error`

What we still need for deterministic cleanup:

- explicit issuer cancellation (`cancelled`)
- disappeared from active feed without an explicit terminal revision (`ended`)
- a terminal timestamp (`terminal_at`)
- ideally a terminal reason field instead of overloading `state`

### 3) Disappearance from the active feed is not reconciled today

If an alert falls out of the active feed and we do not receive a final revision that flips state, the series can remain `active` forever.

That means:

- stale alerts can remain queryable
- stale geolocation can remain matchable
- stale rows can never become eligible for prune

### 4) Presence is not time-bounded in queries

`device_presence` has no `expires_at`, and notification queries currently pass no freshness cutoff.

That is a separate but related cleanup problem:

- even perfect event cleanup will still target stale device location if presence never expires

## Recommended lifecycle model

Keep the cleanup model brutally simple:

- `state`: `active | terminal`
- `terminal_reason`: `cancelled | cancelled_in_error | expired | ended`
- `terminal_at`: timestamp when we decided the series is terminal
- `last_observed_at`: timestamp when the series was last seen in the active feed

If we want the least invasive migration, we can keep the current `state` enum and add:

- `ended`
- `cancelled`
- `terminal_at`
- repurpose `last_seen_active` to mean `last_observed_at`

The important part is not the exact column names. The important part is that terminal reason and terminal time become explicit.

## Deterministic terminal rules

These rules should be evaluated in priority order.

### Rule 1: explicit cancellation in error

Evidence:

- CAP/NWS `messageType = Cancel`

Action:

- mark series terminal immediately
- `terminal_reason = cancelled_in_error`
- `terminal_at = now`

### Rule 2: explicit issuer cancellation / VTEC cancellation

Evidence:

- VTEC action/status indicates the alert was cancelled before natural expiry
- examples: `CAN`, `EXP`, or the exact VTEC states we choose to trust

Action:

- mark series terminal immediately
- `terminal_reason = cancelled`
- `terminal_at = now`

Note:

- current code parses VTEC but does not persist or use it yet
- this rule becomes available once VTEC termination data is persisted or mapped during ingest

### Rule 3: wall-clock expiry

Evidence:

- `coalesce(ends, expires) <= now`

Action:

- mark series terminal immediately
- `terminal_reason = expired`
- `terminal_at = coalesce(ends, expires)` or `now`

Recommendation:

- prefer `ends`
- fall back to `expires`

This keeps the system deterministic even if the upstream feed is slow to remove the alert.

### Rule 4: disappeared from the active feed

Evidence:

- series is still marked active
- series has not been observed in the active feed for longer than the disappearance grace window
- no stronger terminal rule above has already fired

Action:

- mark series terminal
- `terminal_reason = ended`
- `terminal_at = now`

Recommendation:

- use a small grace window, not zero
- start with 5 minutes or 2-3 ingest intervals

This protects us from transient upstream feed hiccups.

## Proposed job split

### Job A: lifecycle reconciliation

Cadence:

- minutely, ideally at the end of ingest

Why minutely:

- this job controls whether alerts remain active
- waiting an hour means users can see stale alerts for up to an hour

Responsibilities:

1. Refresh `last_observed_at` for every series seen in the active feed, even if the revision is unchanged.
2. Apply terminal rules for explicit cancel / expiry.
3. Mark missing-from-feed series as `ended` after the grace window.
4. Optionally queue terminal notifications if product policy wants them.

### Job B: prune terminal data

Cadence:

- hourly

Why hourly is good here:

- deletion is not user-visible in the same way state reconciliation is
- it is maintenance work, not product behavior

Responsibilities:

1. Delete old completed handoff rows from `target_dispatch_outbox`.
2. Delete old completed rows from `notification_outbox`.
3. Delete terminal series past retention, relying on cascade delete for children.
4. Delete stale device presence once presence freshness rules exist.

## Retention policy recommendation

Start simple and make it configurable.

### Event-side retention

- `target_dispatch_outbox`: 3 days after `dispatched IS NOT NULL`
- `notification_outbox`: 7 days after `state IN ('done', 'dead')`
- terminal `arcus_series`: 30 days after `terminal_at`

Why this works:

- outbox tables are operational scratch space
- series retention is the real audit window because deleting a series cascades revisions, geolocation, and ledger rows

### Child data retention under series delete

When a terminal series is deleted, these children should disappear with it:

- `alert_revisions`
- `arcus_geolocation`
- `target_dispatch_outbox`
- `notification_outbox`
- `notification_ledger`

That is already supported by the current foreign keys.

## Safety invariants for prune

The hourly prune job must obey these rules:

1. Never delete a series whose state is still active.
2. Never delete a series without an explicit terminal timestamp.
3. Never prune `notification_ledger` independently while the parent series is still retained.
4. Never delete undispatched target outbox rows.
5. Never delete notification outbox rows still in `ready`.
6. Make every delete query idempotent.
7. Log counts by table and reason every run.

## Recommended SQL shape

This can run in one transaction per phase.

### Phase 1: outbox scratch cleanup

```sql
DELETE FROM target_dispatch_outbox
WHERE dispatched IS NOT NULL
  AND dispatched < NOW() - INTERVAL '3 days';

DELETE FROM notification_outbox
WHERE state IN ('done', 'dead')
  AND updated < NOW() - INTERVAL '7 days';
```

### Phase 2: terminal series cleanup

```sql
DELETE FROM arcus_series
WHERE state <> 'active'
  AND terminal_at IS NOT NULL
  AND terminal_at < NOW() - INTERVAL '30 days';
```

Because of cascade delete, that single series delete removes the child rows safely.

## Required code changes before we trust cleanup

These are the minimum changes needed before any automatic event cleanup is safe:

1. Update ingest so unchanged alerts still refresh `last_observed_at`.
2. Add explicit terminal tracking (`terminal_reason`, `terminal_at`, or equivalent).
3. Reconcile missing-from-feed series into a terminal state.
4. Decide and implement the VTEC-to-terminal mapping for issuer cancellation vs normal ending.
5. Add presence freshness (`expires_at` or query cutoff) so stale device presence stops matching forever.

## Proposed implementation order

1. Fix observation tracking in ingest.
2. Add terminal columns and state reconciliation logic.
3. Backfill terminal state for obviously expired rows.
4. Add the hourly prune scheduled job.
5. Add metrics and a dry-run mode before enabling hard deletes in production.

## Short version

The deterministic approach is:

- first decide whether a series is terminal
- record why and when
- only then delete it after retention

Cleanup should never be the first place we "figure out" lifecycle.
Cleanup should only enforce retention on lifecycle decisions that were already made explicitly.
