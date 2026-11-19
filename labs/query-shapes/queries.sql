-- query-shapes: the SELECTs RunReveal sends to the destination, and what a sourceType filter
-- buys over a rawLog text filter. Read-only. Run against the destination service.
-- Results of the 2026-11-19 run are in README.md. Change the dates to your own window.
--
-- A service upgrade renames system.query_log to query_log_<N>; merge('system', '^query_log')
-- reads all of them.

-- 1. Every SELECT of user `runreveal`, grouped by normalized query.
SELECT normalized_query_hash AS h,
       count() AS queries,
       min(event_time) AS first,
       sum(read_rows) AS read_rows,
       sum(read_bytes) AS read_bytes,
       max(query_duration_ms) AS max_ms,
       max(memory_usage) AS max_memory,
       max(match(query, 'workspaceID\\s*=')) AS filters_workspace,
       arrayStringConcat(arraySort(groupUniqArrayArray(tables)), ',') AS tables,
       any(substring(replaceRegexpAll(query, '\\s+', ' '), 1, 160)) AS example
FROM clusterAllReplicas(default, merge('system', '^query_log'))
WHERE event_date >= '2026-11-16' AND user = 'runreveal'
  AND type = 'QueryFinish' AND query_kind IN ('Select', 'Show')
GROUP BY h
ORDER BY first;

-- 2. The same, summed by who sent it. The workspace client (`workspace-<id>/ clickhouse-go`)
--    is the console and chat; the chat window is taken from the audit events in query 4.
SELECT multiIf(client_name LIKE 'workspace-%'
                 AND event_time BETWEEN '2026-11-18 14:32:50' AND '2026-11-18 14:33:10', 'chat agent',
               client_name LIKE 'workspace-%', 'console',
               'pipeline / migration') AS sender,
       query_kind,
       count() AS queries,
       sum(read_rows) AS read_rows,
       sum(read_bytes) AS read_bytes,
       max(query_duration_ms) AS max_ms,
       max(memory_usage) AS max_memory,
       countIf(match(query, 'workspaceID\\s*=')) AS filter_workspace
FROM clusterAllReplicas(default, merge('system', '^query_log'))
WHERE event_date >= '2026-11-16' AND user = 'runreveal'
  AND type = 'QueryFinish' AND query_kind IN ('Select', 'Show')
GROUP BY sender, query_kind
ORDER BY sender;

-- 3. Everything the workspace client sent around the chat message, in order (SET ROLE included).
SELECT event_time,
       query_kind,
       substring(replaceRegexpAll(query, '\\s+', ' '), 1, 120) AS query,
       read_rows,
       query_duration_ms
FROM clusterAllReplicas(default, merge('system', '^query_log'))
WHERE event_date >= '2026-11-16' AND user = 'runreveal' AND type = 'QueryFinish'
  AND client_name LIKE 'workspace-%'
  AND event_time BETWEEN '2026-11-18 14:32:50' AND '2026-11-18 14:33:10'
ORDER BY event_time;

-- 4. The RunReveal audit events at the same time: chat message, agent tool calls.
SELECT eventTime, eventName
FROM runreveal.logs
WHERE sourceType = 'runreveal-audit'
  AND eventTime BETWEEN '2026-11-18 14:29:55' AND '2026-11-18 14:33:10'
  AND eventName IN ('chat_message', 'chat_mcp_warmup', 'agent_skills_load',
                    'list_tables', 'get_table_schema', 'run_query')
ORDER BY eventTime;

-- 5. What the role that chat switches to can do (ids replaced).
SELECT replaceRegexpAll(ifNull(role_name, user_name), '[0-9A-Za-z]{20,}', '<id>') AS grantee,
       replaceRegexpAll(granted_role_name, '[0-9A-Za-z]{20,}', '<id>') AS granted
FROM system.role_grants
WHERE ifNull(role_name, '') LIKE 'role_%'
ORDER BY grantee, granted;

SELECT access_type, database, count() AS objects,
       arraySlice(arraySort(groupArray(ifNull(table, '*'))), 1, 3) AS examples
FROM system.grants
WHERE role_name = 'role_selector'
GROUP BY access_type, database
ORDER BY access_type, database;

-- 6. Our own comparison: the same rows through a sourceType view and through rawLog text.
--    `organizationId` appears only in the ClickHouse Cloud audit events.
EXPLAIN indexes = 1 SELECT count(), max(length(rawLog)) FROM runreveal.clickhouse_cloud_audit_logs;
EXPLAIN indexes = 1 SELECT count(), max(length(rawLog)) FROM runreveal.logs WHERE rawLog LIKE '%organizationId%';
EXPLAIN indexes = 1 SELECT count(), max(length(rawLog)) FROM runreveal.logs WHERE rawLog ILIKE '%organizationid%';

SELECT count(), max(length(rawLog)) FROM runreveal.clickhouse_cloud_audit_logs SETTINGS log_comment = 'rr-qs-A-sourceType';
SELECT count(), max(length(rawLog)) FROM runreveal.logs WHERE rawLog LIKE '%organizationId%' SETTINGS log_comment = 'rr-qs-B-like';
SELECT count(), max(length(rawLog)) FROM runreveal.logs WHERE rawLog ILIKE '%organizationid%' SETTINGS log_comment = 'rr-qs-C-ilike';
-- Negative control: text that is in no event. The ngram index should skip every part.
SELECT count(), max(length(rawLog)) FROM runreveal.logs WHERE rawLog LIKE '%no-such-text-zq%' SETTINGS log_comment = 'rr-qs-D-like-miss';

-- 7. What each of the four read. Run a few seconds after 6 (query_log is flushed periodically).
SELECT log_comment,
       read_rows,
       read_bytes,
       ProfileEvents['SelectedParts'] AS parts,
       ProfileEvents['SelectedMarks'] AS marks,
       query_duration_ms
FROM clusterAllReplicas(default, system.query_log)
WHERE event_date = today() AND type = 'QueryFinish' AND log_comment LIKE 'rr-qs-%'
ORDER BY event_time;
