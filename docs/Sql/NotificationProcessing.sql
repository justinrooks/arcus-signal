-- Checks the notification ledger
-- build it out


SElECT *
FROM notification_ledger
ORDER BY created desc nulls LAST