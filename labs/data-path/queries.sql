-- data-path: where RunReveal's connections to the destination come from.
-- Read-only. Run against the destination service. Set the date to the day you connected it.

-- 1. Connections from the RunReveal user, by address and client.
--    The address is the egress IP of RunReveal's pipeline; look it up in
--    https://ip-ranges.amazonaws.com/ip-ranges.json (see README).
SELECT initial_address,
       client_name,
       groupUniqArray(query_kind) AS kinds,
       count() AS queries,
       min(event_time) AS first,
       max(event_time) AS last
FROM clusterAllReplicas(default, system.query_log)
WHERE event_date >= '2026-11-16' AND user = 'runreveal' AND type = 'QueryFinish'
GROUP BY initial_address, client_name
ORDER BY queries DESC;

-- 2. Protocol per kind of query (interface 1 = native TCP, 2 = HTTP).
SELECT query_kind, interface, is_secure, count() AS queries
FROM clusterAllReplicas(default, system.query_log)
WHERE event_date >= '2026-11-16' AND user = 'runreveal' AND type = 'QueryFinish'
GROUP BY query_kind, interface, is_secure;

-- 3. Control for is_secure: your own session over HTTPS (port 8443).
--    If it also shows 0, the field does not say whether the client used TLS.
SELECT interface, is_secure, count() AS queries
FROM clusterAllReplicas(default, system.query_log)
WHERE event_date = today() AND user = currentUser() AND type = 'QueryFinish'
GROUP BY interface, is_secure;

-- 4. The SELECTs RunReveal sent while we used the console (dashboards, source pages).
SELECT normalized_query_hash AS h,
       count() AS queries,
       any(substring(replaceRegexpAll(query, '\\s+', ' '), 1, 160)) AS example
FROM clusterAllReplicas(default, system.query_log)
WHERE event_date >= '2026-11-16' AND user = 'runreveal'
  AND type = 'QueryFinish' AND query_kind = 'Select'
GROUP BY h
ORDER BY queries DESC;
