# Replay Ingest Runbook

Use this runbook to manually exercise the NWS ingest pipeline with a known fixture:

- Fixture: `Fixtures/NWSReplay/nws-series-geometry-v1.json`
- Revisions:
  - `urn:oid:2.49.0.1.840.0.replay.alert.001` (`Alert`)
  - `urn:oid:2.49.0.1.840.0.replay.alert.002` (`Update`, references `.001`)

## 1) Prerequisites

1. Run migrations.
2. Run API and Worker processes.
3. Ensure the worker is consuming `ingest` and `target` lanes.

## 2) Trigger replay ingest

```bash
curl -i -X POST http://localhost:8080/api/v1/dev/replay-ingest \
  -H "Content-Type: application/json" \
  -d '{
    "fixtureName": "nws-series-geometry-v1",
    "runLabel": "manual-replay-001"
  }'
```

Expected response:

- HTTP `202 Accepted`
- JSON body with `status=accepted` and `source=fixture`

## 3) Verify ingestion rows

```sql
SELECT revision_urn, series_id, message_type, sent, referenced_urns
FROM alert_revisions
WHERE revision_urn IN (
  'urn:oid:2.49.0.1.840.0.replay.alert.001',
  'urn:oid:2.49.0.1.840.0.replay.alert.002'
)
ORDER BY sent;
```

Expected:

- 2 rows (one for each revision)
- both map to the same `series_id`
- `.002` references `.001`

## 4) Verify series snapshot

```sql
WITH replay_series AS (
  SELECT DISTINCT series_id
  FROM alert_revisions
  WHERE revision_urn IN (
    'urn:oid:2.49.0.1.840.0.replay.alert.001',
    'urn:oid:2.49.0.1.840.0.replay.alert.002'
  )
)
SELECT id, current_revision_urn, current_revision_sent, state, last_seen_active
FROM arcus_series
WHERE id IN (SELECT series_id FROM replay_series);
```

Expected:

- 1 row
- `current_revision_urn = urn:oid:2.49.0.1.840.0.replay.alert.002`

## 5) Verify outbox behavior

```sql
SELECT revision_urn, series_id, attempt_count, dispatched, last_error
FROM target_dispatch_outbox
WHERE revision_urn IN (
  'urn:oid:2.49.0.1.840.0.replay.alert.001',
  'urn:oid:2.49.0.1.840.0.replay.alert.002'
)
ORDER BY revision_urn;
```

Expected today:

- outbox row exists for `.001`
- `attempt_count >= 1`
- `dispatched IS NOT NULL` if worker drained successfully
- `.002` likely absent (current implementation only queues outbox on new-series path)

## 6) Verify geolocation persistence

```sql
WITH replay_series AS (
  SELECT DISTINCT series_id
  FROM alert_revisions
  WHERE revision_urn IN (
    'urn:oid:2.49.0.1.840.0.replay.alert.001',
    'urn:oid:2.49.0.1.840.0.replay.alert.002'
  )
)
SELECT series_id, h3_resolution, cardinality(h3_cells) AS h3_count, geometry_hash, h3_hash, created, updated
FROM arcus_geolocation
WHERE series_id IN (SELECT series_id FROM replay_series);
```

Expected:

- 1 row for the replay series
- non-empty `h3_cells`
- populated hashes

## 7) Verify idempotency by replaying again

Replay same fixture again with a new run label:

```bash
curl -i -X POST http://localhost:8080/api/v1/dev/replay-ingest \
  -H "Content-Type: application/json" \
  -d '{
    "fixtureName": "nws-series-geometry-v1",
    "runLabel": "manual-replay-002"
  }'
```

Check no duplicate revisions:

```sql
SELECT revision_urn, count(*) AS c
FROM alert_revisions
WHERE revision_urn IN (
  'urn:oid:2.49.0.1.840.0.replay.alert.001',
  'urn:oid:2.49.0.1.840.0.replay.alert.002'
)
GROUP BY revision_urn
ORDER BY revision_urn;
```

Expected:

- count remains `1` per revision URN

