-- Keep rollout-overlap completions without attributing them to the new worker.
SELECT json_build_object(
 'sentCount',count(*) FILTER (WHERE status='sent' AND completed_at >= :'attributable_since'::timestamptz),
 'failedCount',count(*) FILTER (WHERE status='failed' AND completed_at >= :'attributable_since'::timestamptz),
 'ambiguousSentCount',count(*) FILTER (WHERE status='sent' AND completed_at < :'attributable_since'::timestamptz),
 'ambiguousFailedCount',count(*) FILTER (WHERE status='failed' AND completed_at < :'attributable_since'::timestamptz))
FROM notification_ledger WHERE completed_at >= :'since'::timestamptz AND completed_at <= now();
