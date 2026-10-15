-- Read-only verification for v1.4.0+ subject identity; no schema/data repair.
WITH tables(name) AS (VALUES ('notification_outbox'),('notification_ledger'),
 ('notification_debug'),('notification_send_attempts')),
columns_ok AS (
 SELECT t.name, count(*) FILTER (WHERE c.column_name IN ('subject_kind','subject_id','subject_revision_id') AND c.data_type='text')=3
   AND count(*) FILTER (WHERE c.column_name='series_id' AND c.is_nullable='YES' AND c.data_type='uuid')=1 AS passed
 FROM tables t LEFT JOIN information_schema.columns c ON c.table_schema='public' AND c.table_name=t.name GROUP BY t.name
), expected_check(definition) AS (
 -- PostgreSQL 16 canonical expression, matching MakeNotificationSubjectKindsExtensible.
 -- Normalize formatting and the literal whitespace vocabulary, preserving grouping.
 VALUES ($definition$CHECK (((((series_id IS NOT NULL) AND (subject_kind IS NULL) AND (subject_id IS NULL) AND (subject_revision_id IS NULL)) OR ((subject_kind IS NOT NULL) AND (length(btrim(subject_kind, identity_whitespace)) > 0) AND (subject_id IS NOT NULL) AND (length(btrim(subject_id, identity_whitespace)) > 0) AND (subject_revision_id IS NOT NULL) AND (length(btrim(subject_revision_id, identity_whitespace)) > 0) AND (subject_revision_id = revision_urn) AND (((subject_kind = 'nws'::text) AND (series_id IS NOT NULL) AND (subject_id = lower((series_id)::text))) OR ((subject_kind <> 'nws'::text) AND (series_id IS NULL))))) IS TRUE))$definition$)
), checks_ok AS (
 SELECT t.name, coalesce(c.convalidated AND c.contype='c'
   AND regexp_replace(regexp_replace(pg_get_constraintdef(c.oid),
     $pattern$btrim\((subject_kind|subject_id|subject_revision_id), '[^']*'::text\)$pattern$,
     'btrim(\1, identity_whitespace)','g'),'[[:space:]]','','g')
     = regexp_replace(e.definition,'[[:space:]]','','g'),false) AS passed
 FROM tables t CROSS JOIN expected_check e
 LEFT JOIN pg_constraint c ON c.conrelid=to_regclass('public.'||t.name) AND c.conname=t.name||'_subject_identity_check'
), expected_indexes(name,table_name,keys,predicate) AS (
 VALUES ('idx_notification_ledger_subject_identity','notification_ledger','installation_id,subject_kind,subject_id,subject_revision_id','series_idISNULL'),
 ('idx_notification_outbox_subject_identity','notification_outbox','subject_kind,subject_id,subject_revision_id,mode','series_idISNULL'),
 ('idx_notification_debug_subject_preview','notification_debug','subject_kind,subject_id,subject_revision_id,mode,record_kind','series_idISNULLANDrecord_kind=''preview_no_candidates''::text')
), indexes_ok AS (
 SELECT e.name, coalesce(i.indisunique AND i.indisvalid AND i.indisready AND i.indnatts=i.indnkeyatts
   AND i.indrelid=to_regclass('public.'||e.table_name)
   AND (SELECT string_agg(a.attname,',' ORDER BY k.ordinality) FROM unnest(i.indkey) WITH ORDINALITY k(attnum,ordinality)
     JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.attnum)=e.keys
   AND regexp_replace(pg_get_expr(i.indpred,i.indrelid),'[[:space:]()]','','g')=e.predicate,false) AS passed
 FROM expected_indexes e LEFT JOIN pg_index i ON i.indexrelid=to_regclass('public.'||e.name)
), identities AS (
 SELECT 'notification_outbox' AS name, count(*) FILTER (WHERE num_nonnulls(subject_kind,subject_id,subject_revision_id) BETWEEN 1 AND 2) AS partial_count FROM notification_outbox
 UNION ALL SELECT 'notification_ledger',count(*) FILTER (WHERE num_nonnulls(subject_kind,subject_id,subject_revision_id) BETWEEN 1 AND 2) FROM notification_ledger
 UNION ALL SELECT 'notification_debug',count(*) FILTER (WHERE num_nonnulls(subject_kind,subject_id,subject_revision_id) BETWEEN 1 AND 2) FROM notification_debug
 UNION ALL SELECT 'notification_send_attempts',count(*) FILTER (WHERE num_nonnulls(subject_kind,subject_id,subject_revision_id) BETWEEN 1 AND 2) FROM notification_send_attempts
), ledger AS (
 SELECT count(DISTINCT name)=2 AS passed FROM _fluent_migrations
 WHERE name IN ('App.AddNotificationSubjectIdentity','App.MakeNotificationSubjectKindsExtensible')
)
SELECT json_build_object('passed',(SELECT passed FROM ledger)
 AND (SELECT bool_and(passed) FROM columns_ok) AND (SELECT bool_and(passed) FROM checks_ok)
 AND (SELECT bool_and(passed) FROM indexes_ok) AND (SELECT bool_and(partial_count=0) FROM identities),
 'migrationLedger',(SELECT passed FROM ledger),'columns',(SELECT json_object_agg(name,passed) FROM columns_ok),
 'checks',(SELECT json_object_agg(name,passed) FROM checks_ok),'indexes',(SELECT json_object_agg(name,passed) FROM indexes_ok),
 'partialIdentities',(SELECT json_object_agg(name,partial_count) FROM identities));
