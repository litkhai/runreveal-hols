-- ingest-storage: what the first days of real sources leave in `runreveal`, and what it cost to write.
-- Read-only. Run against the destination service as a user that can read `runreveal` and `system`.
-- Results of the 2026-11-19 run are in README.md. Change the dates to your own window.
--
-- A service upgrade renames system.query_log to query_log_<N> and starts a new one. merge('system',
-- '^query_log') reads all of them; clusterAllReplicas reads every replica.

-- 1. Active parts per table and partition: rows, compressed and uncompressed bytes.
SELECT table,
       partition,
       count() AS parts,
       sum(rows) AS rows,
       sum(data_compressed_bytes) AS compressed,
       sum(data_uncompressed_bytes) AS uncompressed,
       round(uncompressed / greatest(compressed, 1), 2) AS ratio
FROM system.parts
WHERE database = 'runreveal' AND active
GROUP BY table, partition
ORDER BY table, partition;

-- 2. Rows per source type, with the event-time and receive-time range.
SELECT sourceType,
       count() AS rows,
       countIf(receivedAt >= '2026-11-18 14:00:00') AS last_24h,
       min(eventTime) AS min_event,
       max(eventTime) AS max_event,
       min(receivedAt) AS min_received,
       max(receivedAt) AS max_received,
       sum(length(rawLog)) AS rawlog_bytes
FROM runreveal.logs
GROUP BY sourceType
ORDER BY rows DESC;

-- 3. Backfill of the ClickHouse Cloud audit source: which event days arrived when.
SELECT toStartOfFifteenMinutes(receivedAt) AS received,
       count() AS rows,
       min(eventTime) AS min_event,
       max(eventTime) AS max_event,
       max(dateDiff('day', eventTime, receivedAt)) AS max_lag_days
FROM runreveal.logs
WHERE sourceType = 'clickhouse-cloud-audit'
GROUP BY received
ORDER BY received;

-- 4. Inserts of user `runreveal` per table set, before and inside the last 24 hours.
--    An insert into `logs` lists `logs` and the 13 MV target tables.
SELECT if(event_time >= '2026-11-18 14:00:00', 'last 24 h', 'before') AS window,
       if(has(tables, 'runreveal.logs'), 'logs + MV targets',
          arrayStringConcat(arraySort(tables), ',')) AS table_set,
       length(tables) AS tables_touched,
       count() AS inserts,
       sum(written_rows) AS written_rows,
       sum(written_bytes) AS written_bytes,
       round(avg(query_duration_ms)) AS avg_ms
FROM clusterAllReplicas(default, merge('system', '^query_log'))
WHERE event_date >= '2026-11-16' AND event_time < '2026-11-19 14:00:00'
  AND user = 'runreveal' AND type = 'QueryFinish' AND query_kind = 'Insert'
GROUP BY window, table_set, tables_touched
ORDER BY window, inserts DESC;

-- 5. Inserts per hour: `logs` versus `threat_feed_ips`.
SELECT toStartOfHour(event_time) AS hour,
       countIf(has(tables, 'runreveal.logs')) AS logs_inserts,
       sumIf(written_rows, has(tables, 'runreveal.logs')) AS logs_written_rows,
       countIf(tables = ['runreveal.threat_feed_ips']) AS feed_inserts,
       sumIf(written_rows, tables = ['runreveal.threat_feed_ips']) AS feed_written_rows
FROM clusterAllReplicas(default, merge('system', '^query_log'))
WHERE event_date >= '2026-11-16' AND event_time >= '2026-11-18 12:00:00'
  AND user = 'runreveal' AND type = 'QueryFinish' AND query_kind = 'Insert'
GROUP BY hour
ORDER BY hour;

-- Check A (positive): an insert into `logs` writes through all 13 MVs.
-- Expect one table set of 14 tables and no insert into `logs` alone.
SELECT length(tables) AS tables_touched, count() AS inserts
FROM clusterAllReplicas(default, merge('system', '^query_log'))
WHERE event_date >= '2026-11-16' AND user = 'runreveal' AND type = 'QueryFinish'
  AND query_kind = 'Insert' AND has(tables, 'runreveal.logs')
GROUP BY tables_touched;

-- Check B (negative): rows kept in `threat_feed_ips` are not the rows written.
-- Compare with query 4: written_rows of threat_feed_ips over this number.
SELECT sum(rows) AS kept_rows, count() AS parts
FROM system.parts
WHERE database = 'runreveal' AND table = 'threat_feed_ips' AND active;

-- 6. Merges keep up: parts per partition of `logs`.
SELECT partition, name, part_type, rows, marks
FROM system.parts
WHERE database = 'runreveal' AND table = 'logs' AND active
ORDER BY name;
