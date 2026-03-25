-- Check all the revisions for a series
-- allows validating that information
-- is rolling up. Search for a series_id
-- to test with

select *
from alert_revisions
WHERE series_id = '92e9bdfd-0c14-4b6a-9377-026250270a69'
ORDER BY received desc;
--where series_id = 'd894a41f-8d18-47a4-b022-0f804278c7bc';



-- Verify Series Snapshot
WITH replay_series AS (
  SELECT DISTINCT series_id
  FROM alert_revisions
  WHERE revision_urn IN (
    'urn:oid:2.49.0.1.840.0.79f8d15a0ca5cb7b89b4138fef84690cebd7375d.001.1'
  )
)
SELECT id, current_revision_urn, current_revision_sent, state, last_seen_active
FROM arcus_series
WHERE id IN (SELECT series_id FROM replay_series);

