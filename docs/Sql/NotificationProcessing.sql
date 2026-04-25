-- Checks the notification ledger
-- build it out


SElECT l.series_id, l.mode, l.reason, l.status, p.zone, p.h3_cell, l.created, l.completed_at
FROM notification_ledger l
left join device_presence p on l.installation_id = p.installation_id
ORDER BY created desc nulls LAST