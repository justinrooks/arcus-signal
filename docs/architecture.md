# Arcus Signal Server Architecture

## Purpose
Arcus Signal ingests upstream weather events, computes **notifiable revisions**, targets devices whose **presence overlaps** those events (via **H3 geometry** or **UGC zone/fire zone**), and delivers push notifications via **APNs** with **exactly-once effects** per device per event revision.

## Principles and invariants
1. **Notify only on active, notifiable revisions**
   - No notifications for ended/expired revisions.
2. **Notify on meaningful updates**
   - Only when **geometry, severity, urgency, or certainty** changes (or on first-seen/new event).
3. **Exactly-once notification effect**
   - A device receives **at most one notification** per `(device_id, event_key, revision)`, even with retries or reprocessing.
4. **Idempotent processing**
   - All jobs can run multiple times safely; DB constraints enforce effects.
5. **Tight latency**
   - Ingest cadence is 60s; downstream targeting + delivery should execute in seconds.
6. **Deterministic content**
   - Push content is composed **once** (at outbox insertion) and stored, so retries resend the same message.

---

## System components

### Runtime processes (containers)
- **API**
  - Device registration
  - APNs token updates
  - Presence updates (H3 + UGC sets)
  - Preferences updates
  - Health endpoints
- **Worker**
  - Runs background pipeline via queue “lanes”:
    - `ingest`
    - `target`
    - `send`
  - (Later) `cover` lane for H3 polyfill/expansion, if separated from target.

### External dependencies
- **NWS API**: active alerts feed (JSON-LD)
- **APNs**: token-based authentication (`.p8`)
- **Postgres**: durable store, constraints enforce idempotency
- **Valkey/Redis**: queue backend (Vapor Queues)

---

## Canonical data model

### Canonical event identity
- `event_key`: stable, server-defined
  - e.g. `nws:<feature.id>` or `spc:md:<id>`
- `source_url`: canonical upstream pointer (for debugging / client fetch-on-demand)

### Event kinds (v1)
- `torWarning`, `svrWarning`, `ffWarning`
- `torWatch`, `svrWatch`
- (Later) `spcMesoscaleDiscussion`

---

## Postgres schema (tables, constraints, indexes)

> Names are suggestions; adjust to your naming conventions. Constraints are non-negotiable.

### 1) `event`
Holds current state pointer for each event.

**Columns**
- `event_key` (PK)
- `source` (enum/text)
- `kind` (enum/text)
- `status` (`active|ended`)
- `current_revision` (int)
- `source_url` (text)
- `title` (text, nullable)
- `area_desc` (text, nullable)
- `issued_at`, `effective_at`, `expires_at` (timestamp, nullable)
- `updated_at` (timestamp)

**Indexes**
- `(status)`
- `(kind, status)`
- `(expires_at)` (optional for pruning queries)

---

### 2) `event_revision`
Immutable revisions of an event. Each revision may or may not be notifiable.

**Columns**
- `event_key` (FK → event)
- `revision` (int)
- `created_at` (timestamp)
- `is_active` (bool) — derived at ingest time
- `is_notifiable` (bool) — derived at ingest time
- `change_flags` (int bitmask) — which meaningful fields changed
- `notifiable_fingerprint` (text) — hash of meaningful fields
- `geom_hash` (text, nullable) — hash of geometry only
- `severity`, `urgency`, `certainty` (text/enums, nullable)
- `raw_ref` (text, nullable) — pointer to stored raw payload if used

**PK**
- `(event_key, revision)`

**Indexes**
- `(is_notifiable, created_at)`
- `(created_at)`

---

### 3) `device`
Registered devices and APNs token state.

**Columns**
- `device_id` (PK) — app-generated UUID (Keychain persisted)
- `apns_token` (text)
- `apns_env` (`sandbox|production`)
- `token_valid` (bool)
- `time_sensitive_enabled` (bool)
- `audience_level` (`basic|enthusiast|chaser`)
- `enabled_event_types` (text[] or join table; v1 can be simple)
- `created_at`, `last_seen_at` (timestamp)

**Indexes**
- `(token_valid)`
- `(last_seen_at)`

---

### 4) `presence`
Latest device presence for targeting.

**Columns**
- `device_id` (PK, FK → device)
- `h3_res8` (bigint/text) — device presence cell
- `updated_at` (timestamp)
- `expires_at` (timestamp)
- `mode` (`always|whenInUse`)
- `accuracy_bucket` (smallint/text)

**Indexes**
- `(h3_res8)`
- `(expires_at)` (for pruning and match filters)

---

### 5) Device UGC sets (for watch fallback)
#### 5a) `device_ugc_zone`
- `device_id` (FK)
- `code` (text)

**PK**
- `(device_id, code)`

**Index**
- `(code)`

#### 5b) `device_ugc_fire`
- `device_id` (FK)
- `code` (text)

**PK**
- `(device_id, code)`

**Index**
- `(code)`

---

### 6) Event coverage tables
#### 6a) H3 coverage (geometry-present)
`event_cover_h3`
- `event_key`
- `revision`
- `h3_res8`

**PK**
- `(event_key, revision, h3_res8)`

**Indexes**
- `(h3_res8)`
- `(event_key, revision)`

#### 6b) H3 ring1 “near” coverage
`event_cover_h3_ring1`
- same columns/keys as above

**Note**
- `ring1` should exclude base cells or targeting should handle “at takes precedence.”

#### 6c) UGC coverage (geometry-null watches)
`event_cover_ugc_zone`
- `event_key`, `revision`, `code`
**PK** `(event_key, revision, code)`
**Index** `(code)`

`event_cover_ugc_fire`
- `event_key`, `revision`, `code`
**PK** `(event_key, revision, code)`
**Index** `(code)`

---

### 7) Notification outbox (exactly-once effects)
This is the central accounting mechanism and the **source of truth** for what will be sent.

**Table** `notification_outbox`

**Columns**
- `outbox_id` (PK, UUID)
- `device_id` (FK → device)
- `event_key` (FK → event)
- `revision` (int)
- `primary_match_reason` (enum/text):
  - `h3_at`, `h3_near`, `ugc_zone`, `ugc_fire`
- `match_reasons` (jsonb or bitmask) — optional merged reasons
- `payload_version` (int) — start at `1`
- `payload` (jsonb) — composed push payload (see “Notification content”)
- `state` (enum/text): `queued|sending|sent|failed|dead`
- `attempts` (int)
- `next_attempt_at` (timestamp)
- `sent_at` (timestamp, nullable)
- `apns_id` (text, nullable)
- `last_error` (text, nullable)
- `created_at` (timestamp)

**Constraint (required)**
- `UNIQUE(device_id, event_key, revision)`

**Indexes**
- `(state, next_attempt_at)`
- `(event_key, revision)` (for auditing)
- `(device_id)` (for troubleshooting)

---

## Notifiable fingerprint and change gating

### Meaningful update definition (v1)
A revision is **notifiable** iff:
- revision is **active** (not ended/expired) AND
- either:
  - it is the first revision we have for this `event_key`, OR
  - at least one of these changed vs the last revision:
    - geometry (by `geom_hash`)
    - severity
    - urgency
    - certainty

### Fingerprint
Compute:
- `notifiable_fingerprint = hash(geom_hash, severity, urgency, certainty)`

### Change flags (bitmask)
- `1` = geometry changed
- `2` = severity changed
- `4` = urgency changed
- `8` = certainty changed

Store `change_flags` on `event_revision` for debugging and policy evolution.

### Expired/ended suppression
`event_revision.is_active = false` if any of:
- computed `expires_at`/`ends` ≤ now
- status indicates ended/cancelled (source mapping)
- messageType cancel (source mapping)

If `is_active = false`, then `is_notifiable = false` regardless of fingerprint changes.

---

## Queue lanes, jobs, and payloads

### Queues (lanes)
- `ingest` — strict serial (concurrency 1)
- `target` — moderate (concurrency 2–4)
- `send` — higher (concurrency 10–25)

### Job: `IngestNwsActiveAlerts`
**Runs:** every 60 seconds  
**Does:**
- fetch all active alerts (paged)
- upsert `event`
- insert `event_revision`
- compute `geom_hash` and `notifiable_fingerprint`
- compute `change_flags`
- set `is_active` and `is_notifiable`
- enqueue `TargetEventRevision(event_key, revision)` only if `is_notifiable`

**Idempotency**
- Re-running a sweep must not create extra notifiable triggers.
- Use `event_revision` PK + your existing revision logic.

---

### Job: `TargetEventRevision(event_key, revision)`
**Does:**
- load revision, verify `is_notifiable == true` (defense-in-depth)
- find eligible devices by overlap (H3 or UGC)
- compose push content (deterministically)
- insert outbox rows (idempotent)

#### A) Geometry present (H3)
- ensure `event_cover_h3` exists for this revision
  - if missing, compute polyfill at res8 and store
- ensure `event_cover_h3_ring1` exists
  - compute ring1 via `gridDisk(1)` or equivalent
- match:
  - `h3_at` candidates from base cover
  - `h3_near` candidates from ring1 minus base

#### B) Geometry null (watches): UGC OR matching
- ensure `event_cover_ugc_zone` and `event_cover_ugc_fire` exist for this revision
- match:
  - zone matches → reason `ugc_zone`
  - fire matches → reason `ugc_fire`
- if a device matches both, choose precedence:
  - default precedence: `ugc_zone` > `ugc_fire`
  - optionally store both in `match_reasons`

Insert outbox rows:
- `INSERT ... ON CONFLICT DO NOTHING` (or merge reasons on conflict)

Then enqueue send:
- either enqueue `SendOutbox(outbox_id)` for newly inserted rows
- or rely on send worker polling queued rows

---

### Job: `SendQueuedOutboxBatch`
**Runs:** continuous worker loop or periodic job (e.g., every few seconds)  
**Does:**
- select batch:
  - `state IN (queued, failed)` and `next_attempt_at <= now()`
- mark as `sending` (optimistic lock)
- send APNs
- update to `sent` or `failed/dead`

**Retry policy**
- exponential backoff with cap
- max attempts (configurable)
- APNs invalid/unregistered token → mark device token invalid, set outbox `dead`

---

## Targeting precedence rules
When multiple match methods apply for the same `(device, event_key, revision)`:
1. `h3_at`
2. `h3_near`
3. `ugc_zone`
4. `ugc_fire`

Rationale: geometric locality > coarse administrative areas; “warning/watch zone” generally more actionable than fire-zone-only messaging.

---

## Notification content (push payload composition)

### Goals
- Push messages must be **short, actionable**, and **truthful**.
- Content must be **deterministic** across retries and auditable.
- App remains the source of full detail by fetching authoritative data via `source_url`.

### When to compose
Compose **during targeting**, at outbox insertion time:
- `TargetEventRevision` computes `payload` for each matched device and stores it in `notification_outbox.payload`.
- Send worker transmits exactly what is stored.

### Composition inputs
- `event.kind`
- `event_revision.severity`, `urgency`, `certainty`
- `event_revision.change_flags`
- `match_reason` (`h3_at|h3_near|ugc_zone|ugc_fire`)
- `proximity` (`at|near` for H3)
- `device.audience_level` (`basic|enthusiast|chaser`)
- `device.time_sensitive_enabled`

### Composition output (stored in outbox)
Store a structured payload with:
- `aps.alert.title`
- `aps.alert.body`
- `aps.thread-id` (group updates by eventKey)
- `apns-collapse-id` (collapse bursts by eventKey)
- `aps.interruption-level = time-sensitive` (when enabled)

And custom keys:
- `eventKey`, `revision`, `kind`, `source`, `sourceURL`
- `matchReason`, `proximity`, `changeFlags`, `expiresAt` (optional)

### Wording rules (v1)
- H3:
  - `h3_at` → “at your location”
  - `h3_near` → “near your location”
- UGC:
  - `ugc_zone` → “in your zone”
  - `ugc_fire` → “in your fire zone”
- Updates:
  - If `change_flags != 0`, add “— Update” to title and pick one short cue in body:
    - geometry: “Area updated …”
    - severity: “Severity updated …”
    - urgency/certainty: “Confidence updated …”
- Audience tuning:
  - `basic`: keep body minimal (“Tap for details.”)
  - `enthusiast`: may include normalized sev/urg/cert (brief)
  - `chaser`: include sev/urg/cert more consistently (still short)

### Example templates (illustrative)
- New TOR warning, at:
  - Title: `Tornado Warning`
  - Body: `At your location. Tap for details.`
- TOR warning update, near, geometry changed:
  - Title: `Tornado Warning — Update`
  - Body: `Area updated near your location. Tap for details.`
- Watch match by fire UGC:
  - Title: `Fire Weather Alert`
  - Body: `Fire danger in your fire zone. Tap for details.`

---

## Push payload contract (v1)
Outbox `payload` should include only what the app needs for UX + follow-up fetch:

- `eventKey`
- `revision`
- `kind`
- `source` (`nws`)
- `sourceURL` (canonical NWS `@id`)
- `proximity` (`at|near`) when H3-based
- `matchReason` (`h3_at|h3_near|ugc_zone|ugc_fire`)
- `changeFlags` (bitmask) for update wording
- `expiresAt` (optional)

**Delivery**
- Use **Time Sensitive** notifications (where enabled)
- Silent stop for ended/expired (no “cancelled” push for now)

---

## Operational notes (v1)
- Keep worker lanes isolated so H3 compute never starves APNs sends.
- Measure:
  - ingest sweep duration
  - time from revision created → first outbox row inserted
  - time from outbox queued → APNs sent
  - APNs error rates and invalid token counts
- Prune:
  - old `event_cover_*` rows for ended revisions
  - old outbox rows after retention window (configurable)
  - expired presence rows

---

## Implementation phasing
### Phase 1 (ship notifications without H3)
- UGC OR matching for geometry-null watches
- outbox + APNs send worker
- notifiable fingerprint gating
- deterministic payload composition stored in outbox

### Phase 2 (add H3 coverage)
- polyfill + ring1 tables
- h3_at / h3_near targeting + proximity wording
- precedence merging with UGC fallback

---

## Open decisions (tracked)
- Retention windows (presence, outbox, event revisions)
- Whether to merge match reasons on outbox conflict or enforce precedence-only
- Rate limits and adaptive backoff for NWS ingestion under upstream instability
- SPC Mesoscale Discussion ingestion and mapping into the same pipeline