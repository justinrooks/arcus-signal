-- Check the notification debug table
-- preview_no_candidates means we built a notification
-- but there were no matching devices for that revision

SELECT
    d.created,
    d.record_kind,
    d.series_id,
    d.revision_urn,
    d.mode,
    d.reason,
    d.title,
    d.subtitle,
    d.body,
    d.installation_id,
    l.status AS ledger_status,
    l.apns_error_code
FROM notification_debug d
LEFT JOIN notification_ledger l
  ON l.id = d.notification_ledger_id
ORDER BY d.created DESC;


-- Check snapshots for one alert series
-- replace the series_id with the one you care about

SELECT
    d.created,
    d.record_kind,
    d.revision_urn,
    d.mode,
    d.reason,
    d.title,
    d.subtitle,
    d.body,
    d.installation_id,
    l.status AS ledger_status,
    l.apns_error_code
FROM notification_debug d
LEFT JOIN notification_ledger l
  ON l.id = d.notification_ledger_id
WHERE d.series_id = '92e9bdfd-0c14-4b6a-9377-026250270a69'
ORDER BY d.created DESC;


-- Quick sanity check
-- shows whether rows are mostly previews or actual candidates

SELECT
    record_kind,
    mode,
    count(*) AS c
FROM notification_debug
GROUP BY record_kind, mode
ORDER BY record_kind, mode;
