-- Use these queries to get device specific details about
-- presence and installation

SELECT * FROM device_installations;-- where installation_id =  '131c8480-c74a-47c2-8cec-8d10ee6dc19f';
SELECT * FROM device_presence;

SELECT
    d.location_auth,
    d.app_version,
    d.is_active,
    d.is_subscribed,
    NOW() - p.captured_at AS presence_age,
    (
        d.is_active = TRUE
        AND d.is_subscribed = TRUE
        AND d.apns_device_token <> ''
        AND p.captured_at >= NOW() - INTERVAL '24 hours'
    ) AS is_candidate_query_eligible,
    p.*
FROM device_presence p
LEFT JOIN device_installations d ON d.installation_id = p.installation_id
WHERE (
    d.apns_environment = 'prod'
    AND d.is_active = TRUE
    AND d.is_subscribed = TRUE
    AND d.apns_device_token <> ''
    AND p.captured_at >= NOW() - INTERVAL '24 hours'
    AND p.county NOT LIKE 'CA%'
)
OR p.installation_id IN (
    '131c8480-c74a-47c2-8cec-8d10ee6dc19f' --,
   -- '320f09e1-35cc-4358-8082-5a91efdbe82f'
)
ORDER BY p.updated_at DESC;


SELECT d.location_auth, d.app_version,p.*
FROM device_presence p
LEFT JOIN device_installations d ON d.installation_id = p.installation_id
WHERE (d.apns_environment = 'prod' AND p.county NOT LIKE 'CA%') OR p.installation_id = '131c8480-c74a-47c2-8cec-8d10ee6dc19f' OR p.installation_id = '320f09e1-35cc-4358-8082-5a91efdbe82f'
ORDER BY p.updated_at DESC

SELECT *
FROM device_presence
ORDER BY updated_at desc


SELECT * 
FROM device_installations
ORDER BY last_seen_at DESC

SELECT i.*, p.county, p.zone
FROM device_installations i
LEFT JOIN device_presence p on i.installation_id = p.installation_id
WHERE p.county IS NOT NULL
ORDER BY i.created_at DESC

SELECT *
FROM device_installations
WHERE installation_id = 'e7b1471d-5336-41c7-a321-70983e7e45d7';

SELECT *
FROM device_presence
WHERE installation_id = 'e7b1471d-5336-41c7-a321-70983e7e45d7'





SELECT id, run_time, forecast_hour, valid_time, status, lease_expires_at, updated_at
FROM pressure_artifact_catalog
-- WHERE status = 'pending'
  --AND lease_expires_at <= NOW()
ORDER BY valid_time DESC;

-- DELETE FROM pressure_artifact_catalog
-- WHERE id = '0bd6c94d-e37a-4394-8825-db6cc560e9e1'
--   AND status = 'warming'
--   AND lease_expires_at <= NOW()
-- RETURNING id, valid_time, status;

-- UPDATE pressure_artifact_catalog SET status = 'expired' WHERE id = '64b778e0-4a6c-4e83-b7a6-175b92bc700b'