# ingest-storage — what the first days leave, and what it cost to write (scenario 2)

[English](#english) | [한국어](#한국어)

## English

Two real sources ran for a day and a half. This lab reads what they left in the destination
(`system.parts`, `runreveal.logs`) and what RunReveal wrote to get there (`system.query_log`).

Run on 2026-11-19.

- **Destination:** a ClickHouse Cloud service in AWS `ap-northeast-2` (Seoul). It ran 26.8.1.654
  until a service upgrade at 2026-11-19 08:04 UTC and 26.8.1.780 after it. `system.parts` and every
  query in this lab were read on 26.8.1.780.
- **Sources:** `runreveal-audit` (since 2026-11-17 05:39 UTC) and `clickhouse-cloud-audit` (created
  2026-11-18 13:30 UTC). GitHub and CloudTrail are not connected.
- **Windows (UTC):** since connection = 2026-11-17 05:39 to 2026-11-19 14:00; last 24 h =
  2026-11-18 14:00 to 2026-11-19 14:00. `system.parts` read at 2026-11-19 14:01.
- **query_log:** the upgrade renamed `system.query_log` to `query_log_<N>` on both replicas.
  The queries read all of them with `merge('system', '^query_log')`.

| File | What |
|---|---|
| `queries.sql` | The queries below, read-only |

### What is stored

Active parts in `runreveal` (query 1). Tables with no part are empty. Bytes are exact.

| Table | Partition | Parts | Rows | Compressed | Uncompressed |
|---|---|---|---|---|---|
| `logs` | 20261117 | 1 | 52 | 6,699 | 43,928 |
| `logs` | 20261118 | 2 | 1,113 | 73,851 | 855,224 |
| `threat_feed_ips` | `tuple()` | 4 | 46,330 | 193,414 | 4,702,353 |
| `external_metrics` | `tuple()` | 2 | 173 | 2,565 | 27,367 |
| `runreveal_source_volumes` | `tuple()` | 2 | 48 | 1,346 | 4,598 |
| `ueba_actor_hourly` | 20261117 / 20261118 | 1 / 1 | 1 / 8 | 737 / 1,422 | 527 / 2,734 |
| `_runreveal_meta` | `tuple()` | 1 | 1 | 149 | 47 |

- 14 active parts, 47,726 rows in all. 97 % of the rows are the threat feed, not events.
- `logs` holds 1,165 events in 80,550 bytes on disk. That is too little for a compression ratio
  or a bytes-per-event figure to mean anything, so this lab does not quote one.
- Every part is a Compact part with one granule (`index_granularity = 8192`). The 36 inserts into
  partition 20261118 were merged into one part (`20261118_0_35_9`) plus the last insert.

Rows per source (query 2):

| `sourceType` | Rows | Received in the last 24 h | Event time | Received |
|---|---|---|---|---|
| `runreveal-audit` | 1,072 | 301 | 11-17 05:39 to 11-18 14:33 | 11-17 05:39 to 11-18 14:33 |
| `clickhouse-cloud-audit` | 93 | 81 | 10-20 06:49 to 11-18 13:19 | 11-18 13:30 to 11-18 16:11 |

No row reached `logs` after 2026-11-18 16:13 UTC, which leaves the last ~22 hours of the window with
no events. The RunReveal audit source writes when someone uses the console, and nobody did.
Whether the organisation had any Cloud console activity in that time was not checked here.

### The backfill

`clickhouse-cloud-audit` backfills up to 30 days, oldest first (query 3).

| Received (15 min) | Rows | Event days | Max lag |
|---|---|---|---|
| 11-18 13:30 | 12 | 10-20 to 10-21 | 29 days |
| 11-18 14:45 | 42 | 11-04 | 14 days |
| 11-18 15:00 | 10 | 11-06 | 12 days |
| 11-18 15:15 | 7 | 11-10 | 8 days |
| 11-18 15:30 | 11 | 11-11 | 7 days |
| 11-18 16:00 | 11 | 11-18 | 0 days |

The 30 days arrived in 2 h 41 min. Every row's TTL counts from `receivedAt`, so the 29-day-old
events keep the full `sourceTTL` from 2026-11-18 (schema-tour).

### What it cost to write

Inserts of user `runreveal` (query 4). `written_bytes` is the uncompressed size of what was written.

| Window | Table set | Inserts | Written rows | Written bytes |
|---|---|---|---|---|
| before the last 24 h | `threat_feed_ips` | 378 | 1,177,912 | 145,715,441 |
| before the last 24 h | `logs` + 13 MV targets | 26 | 838 | 775,760 |
| before the last 24 h | `external_metrics`, `_runreveal_meta` | 4 | 37 | 7,063 |
| last 24 h | `threat_feed_ips` | 291 | 934,544 | 115,469,578 |
| last 24 h | `logs` + 13 MV targets | 16 | 412 | 377,140 |
| last 24 h | `external_metrics` | 7 | 137 | 26,906 |

- **The threat feed is almost all of the writing.** In the last 24 h RunReveal wrote 934,544 rows
  into `threat_feed_ips`, which keeps 46,330 (about 20×). In bytes it is 115.5 MB written for
  4.7 MB kept uncompressed and 193 KB on disk. Since connection the ratio is 2,112,456 written rows
  to 46,330 kept (about 46×). The table is a VersionedCollapsingMergeTree, so each refresh writes
  a new version and merges collapse the old one.
- **The cadence does not depend on events** (query 5). Usually 12 inserts and about 30.5k rows an
  hour, about 48.7k every third hour, up to 73,254 in one hour. It went on unchanged through the
  22 hours with no events.
- **An event insert is small and wide.** The 42 inserts into `logs` carried 1,165 events, about
  28 each, and each one wrote through 13 materialized views (check A).

### Checks

| Check | Expected | 2026-11-19 |
|---|---|---|
| A (positive): an insert into `logs` writes through every MV | all inserts that touch `logs` list 14 tables | Pass: 42 of 42 list 14 tables |
| B (negative): `threat_feed_ips` does not keep what it is sent | kept rows well below written rows | Pass: 46,330 kept, 934,544 written in 24 h |

### Not measured

- **Whether `sourceTTL` deletes data** (the issue's check for this scenario). It needs a source
  setting changed and seven days of waiting; this run was read-only.
- **Compression and part counts at a size that means something.** That needs a high-volume source
  (CloudTrail or GitHub); neither is connected.

## 한국어

실제 소스 두 개를 하루 반 동안 돌렸습니다. 이 실습은 그 소스들이 destination에 남긴 것
(`system.parts`, `runreveal.logs`)과 RunReveal이 그걸 남기려고 쓴 양(`system.query_log`)을 읽습니다.

실행일은 2026-11-19입니다.

- **destination:** AWS `ap-northeast-2`(서울)의 ClickHouse Cloud 서비스. 2026-11-19 08:04 UTC 서비스
  업그레이드 전에는 26.8.1.654, 이후에는 26.8.1.780. `system.parts`와 이 실습의 쿼리는 모두
  26.8.1.780에서 읽었습니다.
- **소스:** `runreveal-audit`(2026-11-17 05:39 UTC부터)와 `clickhouse-cloud-audit`(2026-11-18 13:30 UTC
  생성). GitHub과 CloudTrail은 연결하지 않았습니다.
- **기간(UTC):** 연결 이후 = 2026-11-17 05:39 ~ 2026-11-19 14:00, 최근 24시간 = 2026-11-18 14:00 ~
  2026-11-19 14:00. `system.parts`는 2026-11-19 14:01에 읽었습니다.
- **query_log:** 업그레이드 때 두 replica 모두 `system.query_log`가 `query_log_<N>`으로 이름이
  바뀌었습니다. 쿼리는 `merge('system', '^query_log')`로 전부 읽습니다.

| 파일 | 내용 |
|---|---|
| `queries.sql` | 아래 쿼리(읽기 전용) |

### 무엇이 저장됐나

`runreveal`의 활성 파트(쿼리 1). 파트가 없는 테이블은 비어 있습니다. 바이트는 정확한 값입니다.

| 테이블 | 파티션 | 파트 | 행 | 압축 | 비압축 |
|---|---|---|---|---|---|
| `logs` | 20261117 | 1 | 52 | 6,699 | 43,928 |
| `logs` | 20261118 | 2 | 1,113 | 73,851 | 855,224 |
| `threat_feed_ips` | `tuple()` | 4 | 46,330 | 193,414 | 4,702,353 |
| `external_metrics` | `tuple()` | 2 | 173 | 2,565 | 27,367 |
| `runreveal_source_volumes` | `tuple()` | 2 | 48 | 1,346 | 4,598 |
| `ueba_actor_hourly` | 20261117 / 20261118 | 1 / 1 | 1 / 8 | 737 / 1,422 | 527 / 2,734 |
| `_runreveal_meta` | `tuple()` | 1 | 1 | 149 | 47 |

- 활성 파트 14개, 전체 47,726행. 행의 97%는 이벤트가 아니라 위협 피드입니다.
- `logs`에는 이벤트 1,165건이 디스크 80,550바이트에 있습니다. 압축률이나 이벤트당 바이트가 의미를
  갖기엔 너무 적어서 이 실습은 그 값을 쓰지 않습니다.
- 모든 파트는 granule 하나짜리 Compact 파트입니다(`index_granularity = 8192`). 파티션 20261118에 들어간
  insert 36건은 파트 하나(`20261118_0_35_9`)와 마지막 insert 하나로 merge됐습니다.

소스별 행(쿼리 2):

| `sourceType` | 행 | 최근 24시간 수신 | 이벤트 시각 | 수신 시각 |
|---|---|---|---|---|
| `runreveal-audit` | 1,072 | 301 | 11-17 05:39 ~ 11-18 14:33 | 11-17 05:39 ~ 11-18 14:33 |
| `clickhouse-cloud-audit` | 93 | 81 | 10-20 06:49 ~ 11-18 13:19 | 11-18 13:30 ~ 11-18 16:11 |

2026-11-18 16:13 UTC 이후로 `logs`에 들어온 행은 없습니다. 기간의 마지막 약 22시간은 이벤트가 없습니다.
RunReveal audit 소스는 누가 콘솔을 쓸 때 기록되는데 아무도 쓰지 않았습니다. 그 사이 조직에 Cloud
콘솔 활동이 있었는지는 여기서 확인하지 않았습니다.

### backfill

`clickhouse-cloud-audit`는 최대 30일을 오래된 것부터 채웁니다(쿼리 3).

| 수신(15분) | 행 | 이벤트 날짜 | 최대 지연 |
|---|---|---|---|
| 11-18 13:30 | 12 | 10-20 ~ 10-21 | 29일 |
| 11-18 14:45 | 42 | 11-04 | 14일 |
| 11-18 15:00 | 10 | 11-06 | 12일 |
| 11-18 15:15 | 7 | 11-10 | 8일 |
| 11-18 15:30 | 11 | 11-11 | 7일 |
| 11-18 16:00 | 11 | 11-18 | 0일 |

30일치가 2시간 41분 만에 들어왔습니다. TTL은 행마다 `receivedAt`부터 세므로, 29일 된 이벤트도
2026-11-18부터 `sourceTTL`을 온전히 보관합니다(schema-tour).

### 쓰는 데 든 비용

`runreveal` 사용자의 insert(쿼리 4). `written_bytes`는 쓴 데이터의 비압축 크기입니다.

| 기간 | 테이블 묶음 | insert | 쓴 행 | 쓴 바이트 |
|---|---|---|---|---|
| 최근 24시간 이전 | `threat_feed_ips` | 378 | 1,177,912 | 145,715,441 |
| 최근 24시간 이전 | `logs` + MV 대상 13개 | 26 | 838 | 775,760 |
| 최근 24시간 이전 | `external_metrics`, `_runreveal_meta` | 4 | 37 | 7,063 |
| 최근 24시간 | `threat_feed_ips` | 291 | 934,544 | 115,469,578 |
| 최근 24시간 | `logs` + MV 대상 13개 | 16 | 412 | 377,140 |
| 최근 24시간 | `external_metrics` | 7 | 137 | 26,906 |

- **쓰기의 거의 전부가 위협 피드입니다.** 최근 24시간에 RunReveal은 `threat_feed_ips`에 934,544행을
  썼고, 테이블에 남은 것은 46,330행(약 20배)입니다. 바이트로는 115.5 MB를 써서 비압축 4.7 MB,
  디스크 193 KB가 남았습니다. 연결 이후로는 쓴 행 2,112,456 대 남은 행 46,330(약 46배)입니다.
  테이블이 VersionedCollapsingMergeTree라서 갱신마다 새 버전을 쓰고 merge가 이전 버전을 접습니다.
- **주기는 이벤트와 무관합니다**(쿼리 5). 보통 시간당 insert 12건, 약 30.5k행이고, 세 시간마다
  약 48.7k행, 가장 많은 시간은 73,254행입니다. 이벤트가 없던 22시간 동안에도 그대로였습니다.
- **이벤트 insert는 작고 넓습니다.** `logs`에 들어간 insert 42건이 이벤트 1,165건, 건당 약 28건을
  실었고, 매번 materialized view 13개를 거쳤습니다(판정 A).

### 판정

| 판정 | 기대 | 2026-11-19 |
|---|---|---|
| A (positive): `logs` insert는 모든 MV를 거친다 | `logs`를 건드린 insert가 모두 테이블 14개를 기록 | 통과: 42건 중 42건이 14개 |
| B (negative): `threat_feed_ips`는 받은 만큼 남기지 않는다 | 남은 행이 쓴 행보다 훨씬 적다 | 통과: 24시간에 934,544행을 써서 46,330행이 남음 |

### 재지 않은 것

- **`sourceTTL`이 실제로 데이터를 지우는지**(이 시나리오의 이슈 판정). 소스 설정을 바꾸고 7일을
  기다려야 합니다. 이번 실행은 읽기 전용이었습니다.
- **의미 있는 크기에서의 압축률과 파트 수.** 볼륨이 큰 소스(CloudTrail이나 GitHub)가 필요한데 둘 다
  연결하지 않았습니다.
