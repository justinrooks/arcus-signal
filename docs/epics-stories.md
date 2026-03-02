# Arcus Signal — Epics & Stories (Server Notifications Pipeline)

> Goal: deliver **reliable, timely** APNs notifications based on **event revisions** and **device overlap**, with **exactly-once effects** per `(device_id, event_key, revision)`.

---

## Epic 1 — Canonical Event & Revision Foundation (Notifiability Gate)
**Outcome:** Ingest NWS alerts into a canonical model, create immutable revisions, and flag **which revisions are eligible to notify** (active + meaningful changes only).

### Story 1.1 — Define canonical event identity and lifecycle mapping
**Context:** Downstream workers must operate on stable identifiers and normalized states.
- Define `event_key` format (e.g., `nws:<feature.id>`)
- Map NWS `status/messageType/ends/expires` into canonical `status` (`active|ended`)
- Persist `source_url` as canonical fetch pointer

**Acceptance**
- `event.event_key` stable across ingests
- `event.status` updates correctly when alerts expire/end/cancel
- Stored `source_url` matches upstream alert `@id`/feature `id`

### Story 1.2 — Persist `event_revision` immutably and increment revisions deterministically
**Context:** Revisions are the unit of notification targeting and accounting.
- Insert a new `event_revision` only when ingest detects upstream change
- Increment `event.current_revision` atomically
- Store core fields needed for later policy and debugging (severity/urgency/certainty/geom_hash)

**Acceptance**
- A repeated ingest sweep with no changes produces **no new revision**
- Revisions are monotonically increasing per `event_key`
- Revision rows are immutable after insert

### Story 1.3 — Implement meaningful-change detection and notifiable fingerprint
**Context:** You want to notify on updates, but only when changes matter.
- Compute:
  - `geom_hash`
  - `notifiable_fingerprint = hash(geom_hash, severity, urgency, certainty)`
- Compute `change_flags` bitmask:
  - 1 geometry, 2 severity, 4 urgency, 8 certainty
- Set `is_active` and `is_notifiable`:
  - `is_active = not ended/expired`
  - `is_notifiable = is_active && (new_event || fingerprint_changed)`

**Acceptance**
- Revisions with only non-meaningful changes produce `is_notifiable=false`
- Revisions that change geometry/severity/urgency/certainty produce `is_notifiable=true`
- Expired/ended revisions always produce `is_notifiable=false`

### Story 1.4 — Emit `TargetEventRevision` trigger for notifiable revisions
**Context:** Targeting work should be demand-driven and not run for every ingest.
- When a revision is created with `is_notifiable=true`, enqueue `TargetEventRevision(event_key, revision)`

**Acceptance**
- Targeting job is enqueued exactly once per notifiable revision
- No targeting jobs are enqueued for non-notifiable revisions

---

## Epic 2 — Device Registration, Presence, and UGC Data (API Surface)
**Outcome:** Devices can register, update tokens, and provide presence + zone/firezones required for targeting.

### Story 2.1 — Device registration endpoint and durable device identity
**Context:** APNs tokens rotate; you need stable `device_id`.
- Endpoint: `POST /v1/devices/register`
- Store:
  - `device_id` (app UUID)
  - `apns_token`, `apns_env`, `token_valid`
  - `time_sensitive_enabled`, `audience_level`, `enabled_event_types`
- Return a server session token (if used) and server time

**Acceptance**
- Re-register updates existing device row (idempotent)
- Token/env updates succeed without creating duplicate devices

### Story 2.2 — Presence update endpoint (H3 res8 + TTL)
**Context:** Presence is the join key for H3 matching later.
- Endpoint: `POST /v1/presence/update`
- Input:
  - `device_id`
  - `h3_res8`
  - `updated_at` (device timestamp)
  - permission mode (`always|whenInUse`)
- Server computes `expires_at` based on mode (initially 4–6h for when-in-use)

**Acceptance**
- Presence row upserts by `device_id`
- Expired presence is excluded from matching queries
- TTL policy is configurable

### Story 2.3 — Device UGC zone/fire sets update endpoint
**Context:** Watches with null geometry will match on UGC zone OR fire zone; messaging differs.
- Endpoint: `POST /v1/device/ugc`
- Inputs:
  - `ugc_zone_codes[]`
  - `ugc_fire_codes[]`
- Persist in:
  - `device_ugc_zone(device_id, code)`
  - `device_ugc_fire(device_id, code)`
- Replace semantics (server treats payload as authoritative set)

**Acceptance**
- Updates replace previous sets cleanly (no orphan codes)
- Lookup by code is indexed and fast

### Story 2.4 — Token refresh endpoint
**Context:** Tokens change; server must update fast.
- Endpoint: `POST /v1/devices/token`
- Updates `apns_token`, `apns_env`, `token_valid=true`

**Acceptance**
- Token updates are idempotent
- Invalid token markers can be cleared by a new token update endpoint call

---

## Epic 3 — Notification Outbox (Exactly-Once Accounting + Stored Payload)
**Outcome:** A durable outbox provides idempotent “intent-to-send” records, stores the composed push payload, and tracks retry state.

### Story 3.1 — Create `notification_outbox` schema + constraints
**Context:** This is the anti-duplicate wall and the payload source of truth.
- Table includes:
  - `(device_id, event_key, revision)` unique constraint
  - `payload_version` (start at 1)
  - `payload` (jsonb) storing composed APNs payload
  - state machine (`queued|sending|sent|failed|dead`)
  - retry fields (`attempts`, `next_attempt_at`, `last_error`)
  - APNs metadata (`apns_id`, `sent_at`)

**Acceptance**
- DB enforces `UNIQUE(device_id, event_key, revision)`
- Index supports fast dequeue: `(state, next_attempt_at)`

### Story 3.2 — Outbox insert helpers (idempotent)
**Context:** Targeting must write intents safely under retries.
- Provide DAL/repo method:
  - `enqueueNotification(device, event, revision, payload, matchReason)`
  - Uses `INSERT ... ON CONFLICT DO NOTHING` (or explicit precedence merge rules)

**Acceptance**
- Duplicate targeting runs do not create duplicates
- Insert returns “inserted vs already existed” signal

---

## Epic 4 — Notification Content Composition (Deterministic Message Builder)
**Outcome:** Compose short, actionable push content based on event kind, match reason, and change flags; store it in outbox.

### Story 4.1 — Define push payload contract v1
**Context:** Payload must be stable and versioned.
- Define required fields:
  - `aps.alert.title`, `aps.alert.body`
  - `thread-id` and `collapse-id` policies
  - custom data: `eventKey`, `revision`, `kind`, `sourceURL`, `matchReason`, `proximity`, `changeFlags`, `expiresAt`
- Add `payload_version = 1`

**Acceptance**
- Payload contract documented and validated via unit tests
- Size stays within APNs limits (guard rails in code)

### Story 4.2 — Implement `MessageComposer` (pure function)
**Context:** Determinism and auditability.
- Inputs:
  - `event.kind`, `severity/urgency/certainty`, `changeFlags`
  - `matchReason`, `proximity` (`at|near`)
  - `audience_level`, `time_sensitive_enabled`
- Output:
  - structured payload object to be serialized into outbox

**Acceptance**
- Same inputs produce identical output (snapshot tests)
- Templates cover `torWarning/svrWarning/ffWarning/torWatch/svrWatch`
- UGC fire vs zone phrasing differs appropriately

### Story 4.3 — Update wording using `changeFlags`
**Context:** You notify on updates; the message should reflect that without being verbose.
- Add `— Update` title suffix when `changeFlags != 0`
- Body chooses one short cue:
  - geometry: “Area updated …”
  - severity: “Severity updated …”
  - urgency/certainty: “Confidence updated …”

**Acceptance**
- Update pushes are clearly labeled
- No notification created for ended/expired revisions

### Story 4.4 — Threading/collapsing policy
**Context:** Prevent notification spam in the tray during rapid updates.
- `thread-id = eventKey`
- `collapse-id = eventKey` (so OS can collapse bursts to latest)

**Acceptance**
- Multiple updates appear grouped and collapse as expected on device

---

## Epic 5 — Targeting Worker (UGC OR Matching for Watches w/ Null Geometry)
**Outcome:** Notifiable revisions create outbox entries for devices matching UGC zone OR fire UGC, with correct messaging.

### Story 5.1 — Persist event UGC coverage sets for relevant revisions
**Context:** Matching needs event-side codes in normalized tables.
- On `TargetEventRevision` for geometry-null events:
  - Extract UGC from event payload
  - Populate:
    - `event_cover_ugc_zone(event_key, revision, code)`
    - `event_cover_ugc_fire(event_key, revision, code)`
- Ensure idempotent re-runs do not duplicate rows

**Acceptance**
- Event cover tables reflect UGC codes for that revision
- Reprocessing same revision does not add duplicate rows

### Story 5.2 — Implement UGC OR match query and outbox population + compose payload
**Context:** Rule: match on zone OR fire zone; messaging differs.
- Query candidates:
  - zone matches → reason `ugc_zone`
  - fire matches → reason `ugc_fire`
- If a device matches both:
  - precedence: `ugc_zone` > `ugc_fire`
  - optionally include both reasons in payload
- Compose payload via `MessageComposer`
- Insert into outbox idempotently

**Acceptance**
- Devices matching either set get exactly one outbox row per revision
- Payload indicates correct reason and wording

### Story 5.3 — Gating: enforce `is_notifiable && is_active`
**Context:** Defense-in-depth.
- Targeting job re-checks revision `is_notifiable=true` and `is_active=true` before matching

**Acceptance**
- No outbox rows created for non-notifiable or inactive revisions

---

## Epic 6 — APNs Delivery Worker (Send + Retry + Token Invalidation)
**Outcome:** Outbox rows are delivered via APNs, retried safely, and tokens are invalidated when APNs says so.

### Story 6.1 — Configure APNs token auth in worker
**Context:** Worker must send to APNs via `.p8` token auth.
- Load Team ID, Key ID, Bundle ID, `.p8` file via secrets mount
- Support sandbox/production by device `apns_env`

**Acceptance**
- Worker can successfully send a test push to sandbox and production tokens

### Story 6.2 — Implement dequeue loop / batch send job
**Context:** Delivery must be continuous and fast.
- Select batch:
  - `state IN (queued, failed)` and `next_attempt_at <= now()`
- Transition to `sending` with optimistic locking
- Send APNs, update outbox state

**Acceptance**
- Sent rows move to `sent` with `sent_at` and `apns_id`
- Failures move to `failed` and schedule `next_attempt_at`

### Story 6.3 — Retry policy + max attempts
**Context:** Avoid infinite retry loops.
- Exponential backoff with cap (config)
- `max_attempts` then `dead`

**Acceptance**
- Backoff increases per attempt
- Rows exceed max attempts become `dead`

### Story 6.4 — Token invalidation handling
**Context:** Prevent wasted retries and reduce APNs noise.
- If APNs returns invalid/unregistered token:
  - set `device.token_valid=false`
  - mark outbox row `dead` with reason

**Acceptance**
- Invalid tokens stop being retried
- Device can recover via token update endpoint

---

## Epic 7 — H3 Coverage & Targeting (Geometry-Present Alerts)
**Outcome:** When geometry exists, compute res8 H3 cover + ring1 expansion and match devices for “at” vs “near”.

> Implement after UGC flow is working end-to-end.

### Story 7.1 — Compute and persist `event_cover_h3` for geometry revisions
**Context:** H3 polyfill enables scalable matching.
- For revisions with polygon/multipolygon geometry:
  - polyfill at res8
  - store `(event_key, revision, h3_res8)` rows

**Acceptance**
- Cover computed and persisted idempotently per revision
- Reasonable performance for typical warning polygons

### Story 7.2 — Compute ring1 expansion for “near your location”
**Context:** Provide “near” classification and avoid boundary misses.
- For each cover cell, compute `gridDisk(1)` and store in `event_cover_h3_ring1`
- Ensure ring1 does not override “at” (exclude base cells or subtract at-match later)

**Acceptance**
- ring1 table exists and is populated for revision
- Devices matching base cover label “at”, ring1-only label “near”

### Story 7.3 — Implement H3 match queries and outbox insert + compose payload
**Context:** Fast join by H3 cell ID.
- Query `presence` where `expires_at > now()`
- Join to base cover for `h3_at`
- Join to ring1 for `h3_near` excluding base matches
- Compose payload via `MessageComposer`
- Insert outbox rows with `primary_match_reason = h3_at|h3_near`

**Acceptance**
- Exactly one outbox row per device/event/revision
- Correct proximity labeling and wording

### Story 7.4 — Precedence merge with UGC
**Context:** Device might match via H3 and UGC.
- Apply precedence:
  - `h3_at` > `h3_near` > `ugc_zone` > `ugc_fire`
- Implement as:
  - (simple) attempt inserts in precedence order
  - or (advanced) conflict update merge reasons

**Acceptance**
- Final outbox row uses highest precedence reason
- Optional merged reasons captured for auditing

---

## Epic 8 — Operational Hardening (Metrics, Pruning, Backpressure)
**Outcome:** The system remains stable and understandable as usage grows.

### Story 8.1 — Metrics and tracing
**Context:** Debugging “why no push?” requires visibility.
- Track:
  - ingest duration
  - revisions created per sweep
  - notifiable revisions count
  - targeting duration
  - outbox queued rate
  - APNs send success/fail rates and p95 send latency

**Acceptance**
- Metrics exposed (Prometheus or logs-based)
- Key dashboards can be built from emitted metrics

### Story 8.2 — Pruning jobs (retention policies)
**Context:** Prevent table bloat.
- Prune:
  - expired presence
  - ended event covers beyond retention
  - old outbox rows beyond retention (keep some for audit)

**Acceptance**
- Scheduled prune job runs safely and idempotently
- Table sizes remain bounded

### Story 8.3 — Queue lane tuning and safety caps
**Context:** Prevent one lane from starving another.
- Configure per-queue concurrency:
  - ingest: 1
  - target: 2–4
  - send: 10–25
- Add circuit breaker for upstream instability (optional)

**Acceptance**
- APNs send lane stays healthy even if ingest/cover work spikes

---

# Suggested Implementation Order (Minimum Viable Flow)
1. Epic 1 (notifiable gating)
2. Epic 2 (device + presence + UGC)
3. Epic 3 (outbox)
4. Epic 4 (message composer + payload contract)
5. Epic 5 (UGC targeting)
6. Epic 6 (APNs send worker)
7. Epic 7 (H3 targeting)
8. Epic 8 (ops hardening)