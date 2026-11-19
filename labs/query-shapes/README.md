# query-shapes — the SQL RunReveal sends, and what a sourceType filter buys (scenario 3)

[English](#english) | [한국어](#한국어)

## English

Everything the console, chat and detections show is SQL against the destination. This lab lists
every SELECT the `runreveal` user sent since the workspace was connected, ties the chat's queries
to the audit events that triggered them, and then runs our own comparison: the same rows read
through a `sourceType` view and through `rawLog` text.

Run on 2026-11-19.

- **Destination:** a ClickHouse Cloud service in AWS `ap-northeast-2` (Seoul), 26.8.1.654 until
  2026-11-19 08:04 UTC, 26.8.1.780 after. The comparison (queries 6 and 7) ran on 26.8.1.780.
- **Sources:** `runreveal-audit` and `clickhouse-cloud-audit`; 1,165 rows in `logs`.
- **Windows (UTC):** since connection = 2026-11-17 05:39 to 2026-11-19 14:00; last 24 h =
  2026-11-18 14:00 to 2026-11-19 14:00.
- **What ran in the workspace:** dashboards and the detections page (2026-11-18), one chat question
  answered with SQL (2026-11-18 14:32 UTC). No detection, scheduled query or agent schedule has run:
  `detections`, `signals`, `scheduled_query_runs` and `agent_schedule_runs` are empty.
- Workspace ids, source ids and role suffixes are replaced with `<id>`.

| File | What |
|---|---|
| `queries.sql` | The queries below, read-only (6 tags its own queries with `log_comment`) |

### Every SELECT, by sender

Query 2. The console and chat use the client name `workspace-<id>/ clickhouse-go/2.33.1`; the
pipeline uses `<id>/ clickhouse-go/2.33.1`.

| Sender | When (UTC) | Queries | Rows read | Max duration | Max memory | Filter `workspaceID =` |
|---|---|---|---|---|---|---|
| Console | 11-18 00:09–00:26, 13:30–13:42 | 42 `Select` | 913 | 76 ms | 19.1 MB | 6 |
| Pipeline / migration | 11-17 05:40 to 11-18 13:28 | 5 `Select` | 10 | 6 ms | 0.6 MB | 0 |
| Chat agent | 11-18 14:32:54–14:33:05 | 4 `Select` + 1 `Show` | 1,172 | 11 ms | 0.9 MB | 0 |

- **The console is dashboards** (query 1): source volumes and latency from `runreveal_source_volumes`
  and `external_metrics`, signal and alert counts, the audit log page, and the detections page. The
  six queries that filter on `workspaceID` are the detections page (facets, counts, list); they
  read 0 rows because `detections` is empty.
- **The only SELECTs in the last 24 h are the chat's.** Nothing else read the destination between
  2026-11-18 14:33 and 2026-11-19 14:00.

### One chat question, as SQL

The audit events (query 4) and `query_log` (query 3) line up to the second:

| Time (UTC) | Audit event | SQL in `query_log` | Rows read |
|---|---|---|---|
| 14:32:49 | `chat_message` | — | |
| 14:32:50 – 52 | `chat_mcp_warmup`, `agent_skills_load` | — | |
| 14:32:54 | `list_tables` | `SELECT name FROM system.tables WHERE database = 'runreveal'`, `SHOW TABLES` | 0, 152 |
| 14:32:58 | `get_table_schema` ×3 | `system.columns` and `system.data_skipping_indices` for `clickhouse_cloud_audit_logs` | 52, 12 |
| 14:33:05 | `run_query` ×2 | `SELECT eventName, count(), min(eventTime), max(eventTime) FROM clickhouse_cloud_audit_logs WHERE receivedAt >= now() - INTERVAL 30 DAY GROUP BY eventName ORDER BY event_count DESC` | 956 |

- The agent reads the catalogue first (tables, columns, skip indexes), then sends one aggregate.
  The aggregate went through the per-source view, so the `sourceType` condition reached the
  primary key of `logs`, and filtered on `receivedAt`, the last key column. It read 956 rows,
  59 KB, in 11 ms with 0.9 MB of memory.
- An earlier `chat_message` at 14:30:00 produced no SQL.
- **Every chat query runs under a workspace role.** Each one is wrapped in
  `SET ROLE role_<id>` … `SET ROLE ALL` on the same connection. `role_<id>` is granted
  `role_selector` and `role_<id>_views` (query 5). `role_selector` holds `SELECT` on 151 objects in
  `runreveal` (including `logs`) and on `system.data_skipping_indices` and `system.numbers`,
  `INSERT` only on `runreveal.async_query_results`, and `CREATE TEMPORARY TABLE`, `READ` and
  `WRITE` with no database. This lab does not say which sources the last two cover.
- The chat's queries do not filter on `workspaceID`. This destination holds one workspace.

### Our comparison: sourceType vs rawLog text

The same 93 ClickHouse Cloud audit events, four ways (queries 6 and 7). `organizationId` is a key
that appears only in those events.

| Query | Index used (`EXPLAIN indexes = 1`) | Parts | Rows read | Bytes read | Result |
|---|---|---|---|---|---|
| A: view `clickhouse_cloud_audit_logs` (`sourceType =`) | PrimaryKey, `sourceType in [...]`, generic exclusion search: 2/3 granules | 2 | 1,113 | 447,110 | 93 |
| B: `logs WHERE rawLog LIKE '%organizationId%'` | Skip `idx_rawLog` (`ngrambf_v1`): 2/3 granules | 2 | 1,113 | 445,898 | 93 |
| C: `logs WHERE rawLog ILIKE '%organizationid%'` | none: 3/3 granules | 3 | 1,165 | 470,918 | 93 |
| D: `logs WHERE rawLog LIKE '%no-such-text-zq%'` | Skip `idx_rawLog`: 0 granules | 0 | 0 | 0 | 0 |

- **At this volume the sourceType filter reads no less than `LIKE`.** Every part of `logs` is one
  granule, so either index can only drop whole parts. Both dropped the same part (11-17, RunReveal
  audit only) and read the other two, which mix both sources.
- **`ILIKE` reads everything.** The `ngrambf_v1` index on `rawLog` serves `LIKE` but not `ILIKE`.
- **The ngram index works.** Text that no event contains reads nothing (D).
- A plain `count()` over the view is answered from the primary key without reading rows
  (`_exact_count_projection` in the plan), so the queries read `max(length(rawLog))` too.

### Checks

| Check | Expected | 2026-11-19 |
|---|---|---|
| Positive: chat SQL can be found and tied to the question | `query_log` has SELECTs of `runreveal` at the times of the audit tool events | Pass: 5 queries, 14:32:54–14:33:05, matching `list_tables`, `get_table_schema`, `run_query` |
| Negative (from #1): a `sourceType` filter reads far less than a `rawLog`-text filter | A reads fewer rows than B | Not shown: A and B both read 1,113 rows; with one granule per part the difference cannot appear. Only `ILIKE` (C) reads more |

### Not measured

- **Detections and hunting agents.** None ran; their SQL is not in `query_log`.
- **The sourceType vs `LIKE` gap at a size where granules matter.** It needs `logs` to grow past
  one granule per part (8,192 rows), which takes a high-volume source.
- **Chat cost on the LLM side.** Out of scope for the destination; it depends on the provider key
  the workspace owner entered.

## 한국어

콘솔, chat, 디텍션이 보여주는 것은 모두 destination에 보내는 SQL입니다. 이 실습은 워크스페이스를
연결한 뒤 `runreveal` 사용자가 보낸 SELECT를 모두 나열하고, chat 쿼리를 그것을 일으킨 audit 이벤트와
맞춥니다. 그리고 같은 행을 `sourceType` view와 `rawLog` 텍스트로 읽는 비교를 직접 돌립니다.

실행일은 2026-11-19입니다.

- **destination:** AWS `ap-northeast-2`(서울)의 ClickHouse Cloud 서비스. 2026-11-19 08:04 UTC까지
  26.8.1.654, 이후 26.8.1.780. 비교(쿼리 6, 7)는 26.8.1.780에서 돌렸습니다.
- **소스:** `runreveal-audit`와 `clickhouse-cloud-audit`, `logs`에 1,165행.
- **기간(UTC):** 연결 이후 = 2026-11-17 05:39 ~ 2026-11-19 14:00, 최근 24시간 = 2026-11-18 14:00 ~
  2026-11-19 14:00.
- **워크스페이스에서 돌린 것:** 대시보드와 디텍션 화면(2026-11-18), SQL로 답한 chat 질문 하나
  (2026-11-18 14:32 UTC). 디텍션, 예약 쿼리, 에이전트 스케줄은 한 번도 돌지 않았습니다.
  `detections`, `signals`, `scheduled_query_runs`, `agent_schedule_runs`가 비어 있습니다.
- 워크스페이스 ID, 소스 ID, 역할 이름의 ID는 `<id>`로 바꿨습니다.

| 파일 | 내용 |
|---|---|
| `queries.sql` | 아래 쿼리(읽기 전용, 6은 자기 쿼리에 `log_comment`를 붙임) |

### 모든 SELECT, 보낸 쪽별

쿼리 2. 콘솔과 chat은 클라이언트 이름 `workspace-<id>/ clickhouse-go/2.33.1`을, 파이프라인은
`<id>/ clickhouse-go/2.33.1`을 씁니다.

| 보낸 쪽 | 시각(UTC) | 쿼리 | 읽은 행 | 최대 시간 | 최대 메모리 | `workspaceID =` 필터 |
|---|---|---|---|---|---|---|
| 콘솔 | 11-18 00:09–00:26, 13:30–13:42 | `Select` 42 | 913 | 76 ms | 19.1 MB | 6 |
| 파이프라인 / 마이그레이션 | 11-17 05:40 ~ 11-18 13:28 | `Select` 5 | 10 | 6 ms | 0.6 MB | 0 |
| chat 에이전트 | 11-18 14:32:54–14:33:05 | `Select` 4 + `Show` 1 | 1,172 | 11 ms | 0.9 MB | 0 |

- **콘솔 쿼리는 대시보드입니다**(쿼리 1). `runreveal_source_volumes`와 `external_metrics`의 소스 볼륨·지연,
  signal·alert 수, audit 로그 화면, 디텍션 화면. `workspaceID`로 거르는 여섯 개는 디텍션 화면(facet,
  개수, 목록)이고, `detections`가 비어 있어 읽은 행은 0입니다.
- **최근 24시간의 SELECT는 chat 것뿐입니다.** 2026-11-18 14:33부터 2026-11-19 14:00까지 다른 것은
  destination을 읽지 않았습니다.

### chat 질문 하나를 SQL로 보면

audit 이벤트(쿼리 4)와 `query_log`(쿼리 3)가 초 단위로 맞습니다.

| 시각(UTC) | audit 이벤트 | `query_log`의 SQL | 읽은 행 |
|---|---|---|---|
| 14:32:49 | `chat_message` | — | |
| 14:32:50 – 52 | `chat_mcp_warmup`, `agent_skills_load` | — | |
| 14:32:54 | `list_tables` | `SELECT name FROM system.tables WHERE database = 'runreveal'`, `SHOW TABLES` | 0, 152 |
| 14:32:58 | `get_table_schema` ×3 | `clickhouse_cloud_audit_logs`의 `system.columns`, `system.data_skipping_indices` | 52, 12 |
| 14:33:05 | `run_query` ×2 | `SELECT eventName, count(), min(eventTime), max(eventTime) FROM clickhouse_cloud_audit_logs WHERE receivedAt >= now() - INTERVAL 30 DAY GROUP BY eventName ORDER BY event_count DESC` | 956 |

- 에이전트는 먼저 카탈로그(테이블, 컬럼, skip 인덱스)를 읽고 집계 하나를 보냅니다. 집계는 소스별
  view를 거쳤으므로 `sourceType` 조건이 `logs`의 기본 키에 닿았고, 키 마지막 컬럼인 `receivedAt`으로
  걸렀습니다. 956행, 59 KB를 11 ms, 메모리 0.9 MB로 읽었습니다.
- 그보다 앞선 14:30:00의 `chat_message`는 SQL을 만들지 않았습니다.
- **chat 쿼리는 모두 워크스페이스 역할로 돕니다.** 같은 연결에서 쿼리마다 `SET ROLE role_<id>` …
  `SET ROLE ALL`로 감쌉니다. `role_<id>`에는 `role_selector`와 `role_<id>_views`가 부여돼 있습니다
  (쿼리 5). `role_selector`는 `runreveal`의 객체 151개(`logs` 포함)와 `system.data_skipping_indices`,
  `system.numbers`에 `SELECT`, `runreveal.async_query_results`에만 `INSERT`, 그리고 데이터베이스 없는
  `CREATE TEMPORARY TABLE`, `READ`, `WRITE`를 가집니다. 마지막 두 권한이 어느 소스에 걸리는지는 이
  실습에서 말하지 않습니다.
- chat 쿼리는 `workspaceID`로 거르지 않습니다. 이 destination에는 워크스페이스가 하나뿐입니다.

### 직접 비교: sourceType 대 rawLog 텍스트

ClickHouse Cloud audit 이벤트 93건을 네 가지로 읽었습니다(쿼리 6, 7). `organizationId`는 그
이벤트에만 있는 키입니다.

| 쿼리 | 쓴 인덱스(`EXPLAIN indexes = 1`) | 파트 | 읽은 행 | 읽은 바이트 | 결과 |
|---|---|---|---|---|---|
| A: view `clickhouse_cloud_audit_logs`(`sourceType =`) | PrimaryKey, `sourceType in [...]`, generic exclusion search: granule 2/3 | 2 | 1,113 | 447,110 | 93 |
| B: `logs WHERE rawLog LIKE '%organizationId%'` | Skip `idx_rawLog`(`ngrambf_v1`): granule 2/3 | 2 | 1,113 | 445,898 | 93 |
| C: `logs WHERE rawLog ILIKE '%organizationid%'` | 없음: granule 3/3 | 3 | 1,165 | 470,918 | 93 |
| D: `logs WHERE rawLog LIKE '%no-such-text-zq%'` | Skip `idx_rawLog`: granule 0 | 0 | 0 | 0 | 0 |

- **이 볼륨에서는 sourceType 필터가 `LIKE`보다 덜 읽지 않습니다.** `logs`의 파트는 모두 granule
  하나라서 어느 인덱스든 파트 단위로만 버릴 수 있습니다. 둘 다 같은 파트(11-17, RunReveal audit만)를
  버리고 두 소스가 섞인 나머지 둘을 읽었습니다.
- **`ILIKE`는 전부 읽습니다.** `rawLog`의 `ngrambf_v1` 인덱스는 `LIKE`에는 쓰이고 `ILIKE`에는 쓰이지
  않습니다.
- **ngram 인덱스는 동작합니다.** 어느 이벤트에도 없는 텍스트는 아무것도 읽지 않습니다(D).
- view에 그냥 `count()`를 하면 행을 읽지 않고 기본 키로 답합니다(실행 계획의
  `_exact_count_projection`). 그래서 쿼리에 `max(length(rawLog))`를 같이 넣었습니다.

### 판정

| 판정 | 기대 | 2026-11-19 |
|---|---|---|
| Positive: chat SQL을 찾아 질문과 맞출 수 있다 | audit 도구 이벤트 시각에 `runreveal`의 SELECT가 `query_log`에 있다 | 통과: 14:32:54–14:33:05의 쿼리 5개가 `list_tables`, `get_table_schema`, `run_query`와 맞음 |
| Negative(#1): `sourceType` 필터가 `rawLog` 텍스트 필터보다 훨씬 덜 읽는다 | A가 B보다 적게 읽는다 | 보이지 않음: A와 B 모두 1,113행. 파트당 granule이 하나라 차이가 날 수 없음. 더 읽은 것은 `ILIKE`(C)뿐 |

### 재지 않은 것

- **디텍션과 헌팅 에이전트.** 돌지 않았고, 그 SQL은 `query_log`에 없습니다.
- **granule이 의미를 갖는 크기에서의 sourceType 대 `LIKE` 차이.** `logs`가 파트당 granule 하나
  (8,192행)를 넘어야 하고, 볼륨이 큰 소스가 필요합니다.
- **chat의 LLM 쪽 비용.** destination의 범위 밖이고, 워크스페이스 소유자가 넣은 provider 키에 달렸습니다.
