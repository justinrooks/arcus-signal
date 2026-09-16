SELECT
      activity_date,
      COUNT(*) AS dau,
      MAX(created_at) AS latest_capture
  FROM installation_activity_daily
  WHERE activity_date >= (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date - 13
  GROUP BY activity_date
  ORDER BY activity_date DESC;


 SELECT installation_id, activity_date, created_at
  FROM installation_activity_daily
  ORDER BY created_at DESC
  LIMIT 20;

SELECT COUNT(DISTINCT installation_id) AS mau
  FROM installation_activity_daily
  WHERE activity_date >= date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date
    AND activity_date < (date_trunc('month', CURRENT_TIMESTAMP AT TIME ZONE 'UTC') + INTERVAL '1 month')::date;
