-- schema-tour: what the ClickHouse Cloud destination creates in database `runreveal`.
-- Read-only. Run against the destination service as any user that can read `runreveal`
-- and `system`, e.g. in the SQL console, or:
--   clickhouse client --host <service-host> --secure --user <user> --password --queries-file queries.sql
-- Results of the 2026-11-18 run are in README.md.

-- 1. Objects by engine.
SELECT engine, count() AS objects, sum(total_rows) AS rows
FROM system.tables
WHERE database = 'runreveal'
GROUP BY engine
ORDER BY objects DESC;

-- 2. Storage tables: sorting key, partition key, TTL, size.
SELECT name,
       replaceRegexpOne(engine, '^Shared', '') AS engine,
       sorting_key,
       partition_key,
       extract(create_table_query, '\\) TTL (.*?)( SETTINGS|$)') AS ttl,
       total_rows,
       total_bytes
FROM system.tables
WHERE database = 'runreveal' AND engine LIKE '%MergeTree'
ORDER BY name;

-- 3. Materialized views: source table, target table, filter.
SELECT name,
       extract(create_table_query, 'FROM (runreveal\\.[A-Za-z0-9_]+)') AS source,
       extract(create_table_query, 'TO (runreveal\\.[A-Za-z0-9_]+)') AS target,
       extract(create_table_query, 'WHERE (.{0,100})') AS filter
FROM system.tables
WHERE database = 'runreveal' AND engine = 'MaterializedView'
ORDER BY name;

-- 4. Views: which table each one reads.
SELECT extract(create_table_query, 'FROM (runreveal\\.[A-Za-z0-9_]+)') AS reads,
       count() AS views,
       arraySlice(groupArray(name), 1, 4) AS examples
FROM system.tables
WHERE database = 'runreveal' AND engine = 'View'
GROUP BY reads
ORDER BY views DESC;

-- 5. Skip indexes on `logs`.
SELECT name, type_full, expr, granularity
FROM system.data_skipping_indices
WHERE database = 'runreveal' AND table = 'logs';

-- 6. Per-source fields are computed at read time: count the JSONExtract calls in a view.
SELECT name,
       countMatches(create_table_query, 'JSONExtract') AS json_extracts
FROM system.tables
WHERE database = 'runreveal' AND name IN ('github_logs', 'okta_logs', 'clickhouse_cloud_audit_logs');

-- Check A (positive): a per-source view over `logs` reaches the primary key of `logs`.
-- Expect ReadFromMergeTree (runreveal.logs) with sourceType in the PrimaryKey condition.
EXPLAIN indexes = 1
SELECT count() FROM runreveal.github_logs WHERE receivedAt > now() - INTERVAL 1 DAY;

-- Check B (negative): a heavy source's view does not read `logs`.
-- Expect no ReadFromMergeTree (runreveal.logs); the view reads aws_cloudtrail_logs
-- (ReadNothing while that table is empty).
EXPLAIN indexes = 1
SELECT count() FROM runreveal.cloudtrail_logs WHERE receivedAt > now() - INTERVAL 1 DAY;

-- 7. What the RunReveal user has written since the destination was connected.
--    Set the date to the day you connected it.
SELECT arrayStringConcat(arrayFilter(t -> t LIKE 'runreveal.%', tables), ',') AS tables_written,
       count() AS inserts,
       sum(written_rows) AS written_rows,
       formatReadableSize(sum(written_bytes)) AS written,
       round(avg(query_duration_ms)) AS avg_ms
FROM clusterAllReplicas(default, system.query_log)
WHERE event_date >= '2026-11-16' AND user = 'runreveal'
  AND type = 'QueryFinish' AND query_kind = 'Insert'
GROUP BY tables_written
ORDER BY sum(written_rows) DESC;
