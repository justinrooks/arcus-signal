-- Use these queries to get device specific details about
-- presence and installation

SELECT * FROM device_installations;
SELECT * FROM device_presence;

SELECT d.location_auth, d.app_version,p.*
FROM device_presence p
LEFT JOIN device_installations d ON d.installation_id = p.installation_id
WHERE d.apns_environment = 'prod'
ORDER BY p.updated_at DESC





SELECT *
FROM device_installations
WHERE installation_id = 'e7b1471d-5336-41c7-a321-70983e7e45d7';

SELECT *
FROM device_presence
WHERE installation_id = 'e7b1471d-5336-41c7-a321-70983e7e45d7'
