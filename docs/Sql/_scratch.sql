

SELECT *
FROM arcus_series
ORDER BY ends DESC NULLS LAST


SELECT *
FROM arcus_series
WHERE ends >= NOW()

-- ACTIVE
-- Haven't expired or ended yet
SELECT id, event, ends, expires, NOW()
FROM arcus_series
WHERE expires >= NOW() AND ends >= NOW()

-- Stale
-- expired, but conditions haven't ended yet
SELECT id, event, ends, expires, NOW()
FROM arcus_series
WHERE expires <= NOW() AND ends >= NOW()

-- Over
-- Ended
SELECT id, event, ends, expires, last_seen_active, NOW()
FROM arcus_series
WHERE ends < NOW()
ORDER BY ends DESC NULLS LAST

SELECT id, current_revision_sent, created, updated, sent, effective, onset, expires, ends, state, status, now()
FROM arcus_series
ORDER by ends DESC nulls last
limit 15




SELECT id, ends - now() as ago, now() - ends as in
FROM arcus_series
-- WHERE (now() - expires ) > interval '0 seconds'
WHERE (now() - ends ) > interval '0 seconds'
ORDER BY ends DESC nulls LAST
limit 15



SELECT *
FROM arcus_series
ORDER BY ends DESC nulls last
LIMIT 1