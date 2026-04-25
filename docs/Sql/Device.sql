-- Use these queries to get device specific details about
-- presence and installation

SELECT * FROM device_installations;
SELECT * FROM device_presence;

SELECT d.apns_environment,p.*
FROM device_presence p
LEFT JOIN device_installations d ON d.installation_id = p.installation_id
WHERE d.apns_environment = 'prod'