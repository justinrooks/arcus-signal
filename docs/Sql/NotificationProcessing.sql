-- Notification processing diagnostics
-- FB-019 location freshness observability

-- 1) Delivered outcomes (delivery-level) from notification_ledger.
-- Counts successful/failed sends by mode/reason and optional event.
SELECT
    l.mode,
    l.reason,
    COALESCE(s.event, 'unknown') AS event_type,
    l.status AS decision_outcome,
    COUNT(*) AS count
FROM notification_ledger l
LEFT JOIN arcus_series s ON s.id = l.series_id
WHERE l.status IN ('sent', 'failed')
GROUP BY l.mode, l.reason, COALESCE(s.event, 'unknown'), l.status
ORDER BY count DESC, l.mode, l.reason, event_type, decision_outcome;

-- 2) Stale-location misses (candidate-level) from notification_missed_decisions.
-- This answers: how many candidate pushes were skipped because location was stale?
SELECT
    m.mode,
    m.reason,
    COALESCE(s.event, 'unknown') AS event_type,
    m.freshness_state,
    m.permission_mode,
    m.miss_reason,
    'missed_stale_location'::text AS decision_outcome,
    COUNT(*) AS count
FROM notification_missed_decisions m
LEFT JOIN arcus_series s ON s.id = m.series_id
WHERE m.miss_reason = 'stale_location'
GROUP BY m.mode, m.reason, COALESCE(s.event, 'unknown'), m.freshness_state, m.permission_mode, m.miss_reason
ORDER BY count DESC, m.mode, m.reason, event_type, m.permission_mode;

-- 3) Unified decision-outcome view (candidate + delivery) for quick reporting.
WITH delivered AS (
    SELECT
        l.mode,
        l.reason,
        COALESCE(s.event, 'unknown') AS event_type,
        NULL::text AS freshness_state,
        NULL::text AS permission_mode,
        NULL::text AS miss_reason,
        CASE
            WHEN l.status = 'sent' THEN 'delivered'
            WHEN l.status = 'failed' THEN 'delivery_failed'
            ELSE l.status
        END AS decision_outcome,
        COUNT(*) AS count
    FROM notification_ledger l
    LEFT JOIN arcus_series s ON s.id = l.series_id
    WHERE l.status IN ('sent', 'failed')
    GROUP BY l.mode, l.reason, COALESCE(s.event, 'unknown'), l.status
), stale_missed AS (
    SELECT
        m.mode,
        m.reason,
        COALESCE(s.event, 'unknown') AS event_type,
        m.freshness_state,
        m.permission_mode,
        m.miss_reason,
        'missed_stale_location'::text AS decision_outcome,
        COUNT(*) AS count
    FROM notification_missed_decisions m
    LEFT JOIN arcus_series s ON s.id = m.series_id
    WHERE m.miss_reason = 'stale_location'
    GROUP BY m.mode, m.reason, COALESCE(s.event, 'unknown'), m.freshness_state, m.permission_mode, m.miss_reason
)
SELECT * FROM delivered
UNION ALL
SELECT * FROM stale_missed
ORDER BY count DESC, mode, reason, event_type, decision_outcome;

-- 4) Send-attempt no-op reasons (attempt-level) including stale-only runs.
SELECT
    outcome,
    no_op_reason,
    COUNT(*) AS count
FROM notification_send_attempts
GROUP BY outcome, no_op_reason
ORDER BY count DESC, outcome, no_op_reason;
