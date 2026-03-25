
-- Verify ingestion rows
SELECT revision_urn, series_id, message_type, sent, referenced_urns
FROM alert_revisions
WHERE revision_urn IN (
  'urn:oid:2.49.0.1.840.0.replay.alert.001',
  'urn:oid:2.49.0.1.840.0.replay.alert.002'
)
ORDER BY sent DESC;

-- Verify Series Snapshot
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

-- Check target dispatch outbox
SELECT revision_urn, series_id, attempt_count, dispatched, last_error
FROM target_dispatch_outbox
WHERE revision_urn IN (
  'urn:oid:2.49.0.1.840.0.replay.alert.001',
  'urn:oid:2.49.0.1.840.0.replay.alert.002'
)
ORDER BY revision_urn;

-- Check Geolocation hashing
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

-- Check idempotency
SELECT revision_urn, count(*) AS c
FROM alert_revisions
WHERE revision_urn IN (
  'urn:oid:2.49.0.1.840.0.replay.alert.001',
  'urn:oid:2.49.0.1.840.0.replay.alert.002'
)
GROUP BY revision_urn
ORDER BY revision_urn;






-- DELETE FROM arcus_geolocation
-- DELETE FROM alert_revisions
-- DELETE FROM arcus_series