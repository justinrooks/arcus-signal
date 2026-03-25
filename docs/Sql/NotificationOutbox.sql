-- View the notification outbox and 
-- get a list of all the alerts that
-- triggered a notification


select o.id, o.series_id, o.mode, o.state, a.*
FROM notification_outbox o
JOIN arcus_series a ON a.id = o.series_id
-- JOIN arcus_geolocation g on g.series_id = a.id
