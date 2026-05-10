SELECT
  i.installation_id,
  i.is_active,
  i.is_subscribed,
  i.apns_environment,
  i.location_auth,
  i.last_seen_at,
  p.captured_at,
  p.received_at,
  p.h3_cell,
  p.county,
  p.zone,
  p.fire_zone
FROM device_installations i
JOIN device_presence p ON p.installation_id = i.installation_id -- 88268cd713fffff
ORDER BY i.last_seen_at DESC;


-- Step 2 - Update the presence
UPDATE device_presence
SET captured_at = NOW() - INTERVAL '25 hours', 
    county = 'COTC001',
    zone = 'COTZ045',
    fire_zone = 'COTFZ245',
    h3_cell = '-1'
WHERE installation_id = '131c8480-c74a-47c2-8cec-8d10ee6dc19f';


-- Verify ensure targetable
SELECT
  i.installation_id,
  i.is_active,
  i.is_subscribed,
  i.apns_device_token <> '' AS has_token,
  i.location_auth,
  p.captured_at,
  NOW() - p.captured_at AS presence_age,
  p.h3_cell,
  p.county,
  p.zone,
  p.fire_zone
FROM device_installations i
JOIN device_presence p ON p.installation_id = i.installation_id
WHERE i.installation_id = '131c8480-c74a-47c2-8cec-8d10ee6dc19f';


-- Verify suppression
SELECT
  installation_id,
  series_id,
  revision_urn,
  mode,
  reason,
  freshness_state,
  miss_reason,
  permission_mode,
  captured_at,
  received_at,
  evaluated_at,
  created
FROM notification_missed_decisions
WHERE installation_id = '131c8480-c74a-47c2-8cec-8d10ee6dc19f'
ORDER BY created DESC
LIMIT 20;


-- no delivery ledger
SELECT *
FROM notification_ledger
WHERE installation_id = '131c8480-c74a-47c2-8cec-8d10ee6dc19f'
ORDER BY created DESC
LIMIT 20;

-- Send attempt summary
SELECT
  series_id,
  revision_urn,
  mode,
  reason,
  outcome,
  no_op_reason,
  candidate_count,
--   stale_missed_count,
  claimed_count,
  sent_count,
  failed_count,
  attempted_at
FROM notification_send_attempts
WHERE no_op_reason <> 'zero_candidates'
ORDER BY attempted_at DESC
LIMIT 20;

-- Restore
-- UPDATE device_presence
-- SET captured_at = NOW(), 
--     received_at = NOW(),
--     county = 'COC001',
--     zone = 'COZ045',
--     fire_zone = 'COZ245',
--     h3_cell = '613167714648719359'
-- WHERE installation_id = '131c8480-c74a-47c2-8cec-8d10ee6dc19f';
