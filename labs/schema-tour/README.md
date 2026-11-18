# schema-tour — what the ClickHouse Cloud destination creates (scenario 1)

[English](#english) | [한국어](#한국어)

## English

With the **ClickHouse Cloud** destination, RunReveal creates a database named `runreveal` in a
service you own and writes every event there. This lab reads that database from `system` tables
alone: which engines it uses, how per-source tables relate to one wide `logs` table, and what TTL
and indexes decide.

Run on 2026-11-18. The destination was a ClickHouse Cloud service in AWS `ap-northeast-2` (Seoul),
ClickHouse 26.8.1.654. The only source was RunReveal's own audit log, connected 2026-11-17. That is
too little data for sizes or timings, so this lab covers structure only. Ingest and storage are
scenario 2, and query shapes are scenario 3 ([#1](https://github.com/litkhai/runreveal-hols/issues/1)).

| File | What |
|---|---|
| `queries.sql` | Every query below, read-only, with the two checks |

### What is there

171 objects (query 1):

| Engine | Objects | What they are |
|---|---|---|
| View | 127 | One per source type. 120 read `logs`, 3 sit on top of other views (`gsuite_logs`, `guardduty_logs`, `signals_grouped`), and the others read `detections`, `aws_cloudtrail_logs` and `threat_feed_ips` |
| SharedMergeTree | 26 | `logs`, per-source storage for heavy sources, and product state such as detections, scheduled runs, errors and usage |
| MaterializedView | 14 | 13 read `logs`, 1 reads `usage_events` |
| SharedReplacingMergeTree | 2 | `user_login_locations` (last IP per actor), `_runreveal_meta` |
| SharedAggregatingMergeTree | 1 | `ueba_actor_hourly`, per-actor hourly aggregates for behaviour analytics |
| SharedVersionedCollapsingMergeTree | 1 | `threat_feed_ips`, threat-intel IPs replaced by version |

### One wide table, read through views

Every event is written to `logs`:

- `ORDER BY (workspaceID, sourceType, eventName, receivedAt)`, `PARTITION BY toYYYYMMDD(receivedAt)`
- 37 columns:
  - a common envelope: ids, times, `eventName`, source and destination IP with GeoIP/ASN fields, `actor` and `tags` as `Map(String, String)`, `resources`, `enrichments` as `Array(Tuple(...))`, `readOnly`;
  - the original event as `rawLog String`.
- Skip indexes (query 5):
  - `minmax` on `eventTime`;
  - `bloom_filter(0.01)` on `srcIP`, `dstIP` and `mapValues(actor)`;
  - `ngrambf_v1(7, 1024, 1, 0)` on `rawLog`.
  - All have granularity 1.

A per-source "table" such as `github_logs` is a view: `SELECT *, JSONExtractString(rawLog, ...) AS ... FROM runreveal.logs WHERE sourceType = 'github'`.
The source-specific fields are **not stored**. They are parsed out of `rawLog` each time the view is read.
Query 6 counts the `JSONExtract` calls in three such views: 75 in `github_logs`, 37 in `okta_logs`, 16 in `clickhouse_cloud_audit_logs`.
Adding a field to a source therefore changes a view, not the data, while filtering on such a field parses JSON for every row the
`sourceType` range lets through. Scenario 3 measures what that costs.

### Heavy sources get their own tables

13 materialized views read `logs` and write elsewhere (query 3):

| Target | Filter | Sorting key |
|---|---|---|
| `aws_cloudtrail_logs` | `sourceType = 'cloudtrail'` | `sourceType, workspaceID, sourceID, receivedAt`, plus bloom filters on `eventSource` and `eventName` |
| `aws_waf_logs_v2` | `sourceType = 'aws-waf'` | `workspaceID, toStartOfHour(receivedAt), webaclId, action, srcIP`, with the event as a `JSON` column |
| `s3_access_logs_v2` | `sourceType = 's3-access'` | `workspaceID, toStartOfHour(receivedAt), bucket, operation, srcIP`, with a `JSON` column |
| `crowdstrike_fdr_{dns,file,host,network,process}` | `sourceType = 'crowdstrike-fdr'` and a list of event names per table | `workspaceID, aid, eventName, receivedAt, eventTime` |
| `panorama_traffic_logs` | `sourceType = 'palo-panorama-traffic'` | rule, app, device, IPs and ports |
| `flow_logs_minutely` | `sourceType = 'flow'` | per-minute aggregate by `srcIP` |
| `ueba_actor_hourly` | `actor['email'] != ''` | per-actor hourly aggregate |
| `user_login_locations` | RunReveal audit `User Login` events | `actorID, actorIP` |
| `runreveal_source_volumes` | none | per-minute volume per source |

These tables store the source fields as real columns, typed and in a sorting key that fits the
source. The view for such a source reads the MV's table, not `logs`. For example `cloudtrail_logs`
reads `aws_cloudtrail_logs`.

The MVs read from `logs`, so a CloudTrail event is written to `logs` **and** to
`aws_cloudtrail_logs`. That means it is stored twice. This is a hypothesis from the DDL. Scenario 2
confirms it with row counts once CloudTrail flows.

Every insert into `logs` also runs all 13 MVs. In the first day, the 4 inserts that reached `logs`
listed all 14 tables (`logs` and the 13 MV targets) in `system.query_log.tables` (query 7).

### TTL

| Tables | TTL |
|---|---|
| `logs`, `aws_cloudtrail_logs`, `aws_waf_logs_v2`, `s3_access_logs_v2`, `crowdstrike_fdr_*` | `receivedAt + toIntervalDay(greatest(sourceTTL, toUInt32(7)))`. `sourceTTL` is a column with default 550 |
| `ueba_actor_hourly` | `hourBucket + 550 days`, fixed |
| `usage_events` | 180 days |
| `external_metrics`, `handler_errors` | 30 days |
| `async_query_results` | 14 days |
| `detections`, `scheduled_query_runs`, `panorama_traffic_logs`, `flow_logs_minutely`, others | none |

Two things follow from the DDL and are tested in scenario 2:

- Retention is per row: each row carries its source's `sourceTTL`. It has a **floor of 7 days**, so a
  shorter setting still keeps 7 days.
- Shortening a source's retention does not shorten `ueba_actor_hourly`, which keeps actor aggregates
  550 days whatever the source says. Detections and their results have no TTL at all.

Customers who ask how long data stays need both points, not only the source setting.

### Checks

| Check | Query | Expected | 2026-11-18 |
|---|---|---|---|
| A, positive: a per-source view over `logs` uses the primary key of `logs` | `EXPLAIN indexes = 1` on `github_logs` with a one-day `receivedAt` filter | `ReadFromMergeTree (runreveal.logs)` with `sourceType in ['github', 'github']` in the PrimaryKey condition | Pass: PrimaryKey condition on `sourceType` and `receivedAt`, generic exclusion search (`workspaceID` comes first in the key), 0/1 granules |
| B, negative: a heavy source's view does not read `logs` | same on `cloudtrail_logs` | no `ReadFromMergeTree (runreveal.logs)` | Pass: the plan reads nothing from `logs`; the source table `aws_cloudtrail_logs` is empty, so the plan is `ReadNothing`. Re-run when CloudTrail flows to see `ReadFromMergeTree (runreveal.aws_cloudtrail_logs)` |

Check A shows that the view's `WHERE sourceType = ...` is pushed into the scan of `logs`. Because
`workspaceID` is the first key column and the view does not filter on it, the search is
generic exclusion rather than binary search. Scenario 3 checks whether RunReveal's own queries add
`workspaceID`.

### Writes before any source

Even with no source but its own audit log, the RunReveal user wrote steadily (query 7, 2026-11-17
12:15 to 2026-11-18 12:42 UTC):

| Tables written | Inserts | Rows written | Bytes written | Avg ms |
|---|---|---|---|---|
| `threat_feed_ips` | 289 | 898,529 | 105.99 MiB | 401 |
| `logs` and its 13 MV targets | 4 | 275 | 259.62 KiB | 594 |

`threat_feed_ips` held 45,468 rows (189 KiB) at the end of that window. Inserts came about 12 times an hour, and 20 times as many rows were written as the table keeps, which looks
like the threat-intel feed being re-written and collapsed by version (not confirmed). This is a cost a customer sees on an otherwise idle destination. Scenario 2 follows it over a
longer window.

### Not covered here

Sizes, compression and query timings (scenarios 2 and 3). The column-by-column schema of every
view (run `DESCRIBE runreveal.<view>`).

## 한국어

**ClickHouse Cloud** destination을 고르면 RunReveal은 내가 가진 서비스에 `runreveal` 데이터베이스를
만들고 모든 이벤트를 그곳에 씁니다. 이 실습은 `system` 테이블만으로 그 데이터베이스를 읽습니다.
어떤 엔진을 쓰는지, 소스별 테이블이 넓은 `logs` 테이블 하나와 어떤 관계인지, TTL과 인덱스가 무엇을
정하는지를 봅니다.

실행일은 2026-11-18입니다. destination은 AWS `ap-northeast-2`(서울)의 ClickHouse Cloud 서비스이고
버전은 ClickHouse 26.8.1.654입니다. 연결된 소스는 2026-11-17에 연결한 RunReveal 자체 audit 로그뿐이라
크기나 시간을 말하기엔 데이터가 너무 적습니다. 그래서 이 실습은 구조만 다룹니다. ingest와 저장은
시나리오 2, 쿼리 형태는 시나리오 3에서 봅니다([#1](https://github.com/litkhai/runreveal-hols/issues/1)).

| 파일 | 내용 |
|---|---|
| `queries.sql` | 아래 쿼리 전부(읽기 전용)와 두 가지 판정 |

### 무엇이 있나

객체는 171개입니다(쿼리 1).

| 엔진 | 개수 | 무엇인가 |
|---|---|---|
| View | 127 | 소스 유형마다 하나씩입니다. 120개는 `logs`를 읽고, 3개는 다른 view 위에 있습니다(`gsuite_logs`, `guardduty_logs`, `signals_grouped`). 나머지는 `detections`, `aws_cloudtrail_logs`, `threat_feed_ips`를 읽습니다 |
| SharedMergeTree | 26 | `logs`, 무거운 소스용 별도 저장 테이블, 그리고 디텍션·예약 실행·오류·사용량 같은 제품 상태 |
| MaterializedView | 14 | 13개는 `logs`를, 1개는 `usage_events`를 읽습니다 |
| SharedReplacingMergeTree | 2 | `user_login_locations`(사용자별 마지막 IP), `_runreveal_meta` |
| SharedAggregatingMergeTree | 1 | `ueba_actor_hourly`, 행위 분석용 사용자별 시간 단위 집계 |
| SharedVersionedCollapsingMergeTree | 1 | `threat_feed_ips`, 버전 단위로 교체되는 위협 인텔 IP |

### 넓은 테이블 하나를 view로 읽는다

모든 이벤트는 `logs`에 씁니다.

- `ORDER BY (workspaceID, sourceType, eventName, receivedAt)`, `PARTITION BY toYYYYMMDD(receivedAt)`
- 컬럼은 37개입니다.
  - 공통 봉투: ID, 시각, `eventName`, 출발지·목적지 IP와 GeoIP/ASN 필드, `Map(String, String)`인 `actor`와 `tags`, `resources`, `Array(Tuple(...))`인 `enrichments`, `readOnly`
  - 원본 이벤트를 담은 `rawLog String`
- skip 인덱스(쿼리 5):
  - `eventTime`에 `minmax`
  - `srcIP`, `dstIP`, `mapValues(actor)`에 `bloom_filter(0.01)`
  - `rawLog`에 `ngrambf_v1(7, 1024, 1, 0)`
  - 모두 granularity 1입니다.

`github_logs` 같은 소스별 "테이블"은 view입니다: `SELECT *, JSONExtractString(rawLog, ...) AS ... FROM runreveal.logs WHERE sourceType = 'github'`.
소스 고유 필드는 **저장되지 않습니다**. view를 읽을 때마다 `rawLog`에서 꺼냅니다.
쿼리 6으로 view 세 개의 `JSONExtract` 호출 수를 세면 `github_logs` 75개, `okta_logs` 37개, `clickhouse_cloud_audit_logs` 16개입니다.
그래서 소스에 필드를 추가하면 데이터가 아니라 view가 바뀝니다. 대신 그런 필드로 거르면 `sourceType` 범위를 통과한 모든 행에서 JSON을 파싱합니다.
그 비용은 시나리오 3에서 잽니다.

### 무거운 소스는 별도 테이블로

MV 13개가 `logs`를 읽어 다른 테이블에 씁니다(쿼리 3).

| 대상 | 필터 | 정렬 키 |
|---|---|---|
| `aws_cloudtrail_logs` | `sourceType = 'cloudtrail'` | `sourceType, workspaceID, sourceID, receivedAt`, 그리고 `eventSource`·`eventName`에 bloom filter |
| `aws_waf_logs_v2` | `sourceType = 'aws-waf'` | `workspaceID, toStartOfHour(receivedAt), webaclId, action, srcIP`. 이벤트는 `JSON` 컬럼 |
| `s3_access_logs_v2` | `sourceType = 's3-access'` | `workspaceID, toStartOfHour(receivedAt), bucket, operation, srcIP`. `JSON` 컬럼 |
| `crowdstrike_fdr_{dns,file,host,network,process}` | `sourceType = 'crowdstrike-fdr'`와 테이블별 이벤트 이름 목록 | `workspaceID, aid, eventName, receivedAt, eventTime` |
| `panorama_traffic_logs` | `sourceType = 'palo-panorama-traffic'` | 룰, 앱, 장비, IP, 포트 |
| `flow_logs_minutely` | `sourceType = 'flow'` | `srcIP`별 분 단위 집계 |
| `ueba_actor_hourly` | `actor['email'] != ''` | 사용자별 시간 단위 집계 |
| `user_login_locations` | RunReveal audit의 `User Login` 이벤트 | `actorID, actorIP` |
| `runreveal_source_volumes` | 없음 | 소스별 분 단위 볼륨 |

이 테이블들은 소스 필드를 실제 컬럼으로 저장합니다. 타입이 있고, 정렬 키도 그 소스에 맞춰져
있습니다. 이런 소스의 view는 `logs`가 아니라 MV의 테이블을 읽습니다. 예를 들어 `cloudtrail_logs`는
`aws_cloudtrail_logs`를 읽습니다.

MV는 `logs`에서 읽기 때문에 CloudTrail 이벤트는 `logs`와 `aws_cloudtrail_logs` **양쪽에** 쓰입니다.
즉 두 번 저장됩니다. 이것은 DDL에서 나온 가설이고, 시나리오 2에서 CloudTrail이 들어온 뒤 행 수로
확인합니다.

`logs`에 insert할 때마다 MV 13개도 모두 돕니다. 첫날 `logs`에 들어간 insert 4건은 모두
`system.query_log.tables`에 테이블 14개(`logs`와 MV 대상 13개)가 찍혔습니다(쿼리 7).

### TTL

| 테이블 | TTL |
|---|---|
| `logs`, `aws_cloudtrail_logs`, `aws_waf_logs_v2`, `s3_access_logs_v2`, `crowdstrike_fdr_*` | `receivedAt + toIntervalDay(greatest(sourceTTL, toUInt32(7)))`. `sourceTTL`은 기본값 550인 컬럼 |
| `ueba_actor_hourly` | `hourBucket + 550일`, 고정 |
| `usage_events` | 180일 |
| `external_metrics`, `handler_errors` | 30일 |
| `async_query_results` | 14일 |
| `detections`, `scheduled_query_runs`, `panorama_traffic_logs`, `flow_logs_minutely` 등 | 없음 |

DDL에서 나오는 두 가지는 시나리오 2에서 시험합니다.

- 보존 기간은 행 단위입니다. 각 행이 자기 소스의 `sourceTTL`을 들고 있습니다. 하한이 **7일**이라
  더 짧게 설정해도 7일은 남습니다.
- 소스의 보존 기간을 줄여도 `ueba_actor_hourly`는 줄지 않습니다. 소스 설정과 상관없이 사용자 집계를
  550일 보관합니다. 디텍션과 그 결과는 TTL이 아예 없습니다.

데이터가 얼마나 남는지 묻는 고객에게는 소스 설정만이 아니라 이 두 가지를 함께 알려야 합니다.

### 판정

| 판정 | 쿼리 | 기대 | 2026-11-18 |
|---|---|---|---|
| A, positive: `logs` 위의 소스별 view가 `logs`의 primary key를 쓴다 | `github_logs`에 하루치 `receivedAt` 필터를 걸고 `EXPLAIN indexes = 1` | `ReadFromMergeTree (runreveal.logs)`, PrimaryKey 조건에 `sourceType in ['github', 'github']` | 통과: `sourceType`과 `receivedAt`에 PrimaryKey 조건, generic exclusion search(키 첫 컬럼이 `workspaceID`), granule 0/1 |
| B, negative: 무거운 소스의 view는 `logs`를 읽지 않는다 | `cloudtrail_logs`에 같은 쿼리 | `ReadFromMergeTree (runreveal.logs)` 없음 | 통과: 계획에 `logs` 읽기가 없습니다. 원본 테이블 `aws_cloudtrail_logs`가 비어 있어 계획이 `ReadNothing`입니다. CloudTrail이 들어오면 다시 돌려 `ReadFromMergeTree (runreveal.aws_cloudtrail_logs)`를 확인합니다 |

판정 A는 view의 `WHERE sourceType = ...`가 `logs` 스캔까지 내려간다는 것을 보여줍니다. 키 첫 컬럼인
`workspaceID`를 view가 거르지 않아서 binary search가 아니라 generic exclusion search입니다.
RunReveal 자체 쿼리가 `workspaceID`를 붙이는지는 시나리오 3에서 확인합니다.

### 소스 없이도 일어나는 쓰기

자체 audit 로그 외에는 소스가 없는데도 RunReveal 사용자는 꾸준히 썼습니다(쿼리 7, 2026-11-17 12:15 ~
2026-11-18 12:42 UTC).

| 쓴 테이블 | insert | 쓴 행 | 쓴 바이트 | 평균 ms |
|---|---|---|---|---|
| `threat_feed_ips` | 289 | 898,529 | 105.99 MiB | 401 |
| `logs`와 MV 대상 13개 | 4 | 275 | 259.62 KiB | 594 |

같은 시점에 `threat_feed_ips`는 45,468행(189 KiB)이었습니다. insert는 시간당 약 12번이었고, 쓴 행은 남은 행의 20배였습니다.
위협 인텔 피드를 다시 쓰고 버전으로 접는 것으로 보입니다(확인 안 됨). 다른 일이 없는 destination에서도 고객이
보게 되는 비용입니다. 더 긴 기간은 시나리오 2에서 봅니다.

### 여기서 다루지 않는 것

크기, 압축, 쿼리 시간(시나리오 2, 3). 모든 view의 컬럼별 스키마(`DESCRIBE runreveal.<view>`로 확인).
