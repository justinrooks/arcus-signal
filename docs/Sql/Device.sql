-- Use these queries to get device specific details about
-- presence and installation

SELECT * FROM device_installations; --where installation_id =  '131c8480-c74a-47c2-8cec-8d10ee6dc19f';
SELECT * FROM device_presence;

SELECT d.location_auth, d.app_version,p.*
FROM device_presence p
LEFT JOIN device_installations d ON d.installation_id = p.installation_id
WHERE (d.apns_environment = 'prod' AND p.county NOT LIKE 'CA%') OR p.installation_id = '131c8480-c74a-47c2-8cec-8d10ee6dc19f' OR p.installation_id = '320f09e1-35cc-4358-8082-5a91efdbe82f'
ORDER BY p.updated_at DESC





SELECT *
FROM device_installations
WHERE installation_id = 'e7b1471d-5336-41c7-a321-70983e7e45d7';

SELECT *
FROM device_presence
WHERE installation_id = 'e7b1471d-5336-41c7-a321-70983e7e45d7'
