

SELECT s.* --s.id, s.event, r.id as RevId
FROM arcus_series s
--LEFT JOIN alert_revisions r ON r.series_id = s.id
-- WHERE ends = '2026-03-15 04:00:00+00'
ORDER BY created DESC NULLS LAST

SELECT *
FROM alert_revisions


SELECT s.*, o.*
FROM arcus_series s
-- LEFT JOIN alert_revisions r on r.series_id = s.id
-- LEFT JOIN arcus_geolocation g on g.series_id = s.id
-- LEFT JOIN notification_ledger n ON n.series_id = s.id
LEFT JOIN notification_outbox o ON o.series_id = s.id
WHERE s.id = '6b2a670a-3b6e-4f63-8dff-c9c640381cb8'

-- series
-- revisions
-- h3 cells
-- notification ledger

SelECT *
FROM notification_ledger
ORDER BY created desc nulls LAST

SELECT * FROM device_installations;
SELECT * FROM device_presence


select * from target_dispatch_outbox

SELECT *
FROM arcus_series
WHERE ends >= NOW()

-- ACTIVE
-- Haven't expired or ended yet
SELECT id, event, ends, expires, NOW()
FROM arcus_series
WHERE expires >= NOW() AND ends >= NOW()

-- Stale
-- expired, but conditions haven't ended yet
SELECT id, event, ends, expires, NOW()
FROM arcus_series
WHERE expires <= NOW() AND ends >= NOW()

-- Over
-- Ended
SELECT id, event, ends, expires, last_seen_active, NOW()
FROM arcus_series
WHERE ends < NOW()
ORDER BY ends DESC NULLS LAST

SELECT id, current_revision_sent, created, updated, sent, effective, onset, expires, ends, state, status, now()
FROM arcus_series
ORDER by ends DESC nulls last
limit 15




SELECT id, ends - now() as ago, now() - ends as in
FROM arcus_series
-- WHERE (now() - expires ) > interval '0 seconds'
WHERE (now() - ends ) > interval '0 seconds'
ORDER BY ends DESC nulls LAST
limit 15



SELECT * --id, event, expires, ends, state
FROM arcus_series
WHERE state = 'active'
ORDER BY ends DESC nulls last
LIMIT 1

-- UPDATE arcus_series SET state = 'active'

-- ALTER TABLE arcus_series
-- DROP CONSTRAINT alert_series_state_check;

-- ALTER TABLE arcus_series
-- ADD CONSTRAINT alert_series_state_check
-- CHECK (state IN ('active', 'cancelled_in_error', 'cancelled', 'ended', 'expired'));

SELECT *
FROM notification_ledger
WHERE series_id = 'b3c804ae-7707-4fd8-a280-f3a7ad5c2581'



SELECT *--id, event, description, message_type
FROM arcus_series
-- WHERE event = 'Severe Thunderstorm Warning' AND message_type = 'alert' --AND description ~~* '%Tornado%'
ORDER BY created desc
WHERE description ~~* '%Tornado%' AND event <> 'Tornado Warning' AND event <> 'Tornado Watch'
ORDER BY created DESC


SELECT *
FROM arcus_series
WHERE 'COZ045' = ANY (ugc_codes)
ORDER BY created DESC

SELECT * from alert_revisions
WHERE series_id = '32e7a79b-3599-4a39-a60e-ce7e961f3016'

SELECT *
FROM arcus_series
WHERE id = '67DD1A5C-21E7-4BFB-8A3C-A7E40D7BDFB9'

-- UPDATE arcus_series
--     SET tornado_damage_threat = 'catastrophic', tornado_detection = 'possible',
--     max_wind_gust = '60', max_hail_size = '1.25', wind_threat = 'yes', hail_threat = 'no',
--     thunderstorm_damage_threat = 'significant', flash_flood_damage_threat = 'deep', flash_flood_detection = 'radar indicated'
--     WHERE id = '67DD1A5C-21E7-4BFB-8A3C-A7E40D7BDFB9'




SELECT s.id, s.event, s.geometry, g.*
FROM arcus_series s
LEFT JOIN arcus_geolocation g on s.id = g.series_id
WHERE s.geometry IS NOT NULL AND g.id IS NULL
ORDER BY s.created DESC


SELECT *
FROM target_dispatch_outbox
WHERE created >= NOW() - INTERVAL '24 hours'

WHERE geometry IS NOT NULL
AND created >= NOW() - INTERVAL '24 hours';



WITH base AS (
    SELECT created, completed, result
    FROM target_dispatch_outbox
    WHERE created >= NOW() - INTERVAL '24 hours'
),
successful AS (
    SELECT EXTRACT(EPOCH FROM (completed - created)) AS conversion_seconds
    FROM base
    WHERE result = 'succeeded'
      AND completed IS NOT NULL
)
SELECT
    (SELECT COUNT(*) FROM base) AS "geometryBearingRevisionCount",
    (SELECT COUNT(*) FROM base WHERE result = 'succeeded') AS "successfulConversionCount",
    (SELECT PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY conversion_seconds) FROM successful) AS "p95ConversionSeconds";





SELECT run_time, forecast_hour, valid_time, status, local_path, byte_size, error_summary
   FROM pressure_artifact_catalog
   ORDER BY valid_time DESC, updated_at DESC
   LIMIT 10;

DELETE FROM pressure_artifact_catalog where status = 'failed'