# data-path — where the events go, and from which region (scenario 5)

[English](#english) | [한국어](#한국어)

## English

Customers who keep data in a given region ask a fair question: if the ClickHouse Cloud destination
is in my region, does the data stay there? This lab does not answer from documentation. It reads it
from the destination service: `system.query_log` shows which addresses RunReveal connects from,
and AWS's published IP ranges say which region those addresses belong to.

Run on 2026-11-18.

- **Destination:** a ClickHouse Cloud service in AWS `ap-northeast-2` (Seoul), ClickHouse 26.8.1.654.
- **Source:** RunReveal's own audit log only.
- **Window:** 2026-11-17 12:15 to 2026-11-18 12:44 UTC.
- **IP ranges:** [`ip-ranges.json`](https://ip-ranges.amazonaws.com/ip-ranges.json), createDate `2026-11-18-10-27-05`.

| File | What |
|---|---|
| `queries.sql` | The `query_log` queries below, read-only |

### What the destination saw

All connections from the `runreveal` user, grouped by address and client (query 1). The addresses
and the ids in `client_name` are redacted. Each address was matched to the most specific prefix in
`ip-ranges.json`.

| Address | Region (AWS ip-ranges) | Client | Queries |
|---|---|---|---|
| one IP in `3.14.0.0/15` | `us-east-2`, EC2 | `<id>/ clickhouse-go/2.33.1 (lv:go/1.27.3; os:linux)` | 293 `Insert` |
| one IP in `3.16.0.0/14` | `us-east-2`, EC2 | `workspace-<workspace id>/ clickhouse-go/2.33.1 ...` | 112 `Set` and `Select`, sent while we used the console |
| the same IP in `3.16.0.0/14` | `us-east-2`, EC2 | `<id>/ clickhouse-go/2.33.1 ...` | 2 `Insert` |

- Every query arrived over the native protocol (`interface` 1, query 2).
- `is_secure` was 0 for all of them. Our own HTTPS session on port 8443 also shows `is_secure = 0`
  (query 3, the control), so on this service the field does not tell whether the client used TLS.
  This lab does not say either way.
- The console's queries are dashboards: source volumes, dropped-log metrics, signal and alert counts,
  detection results, and the audit log (query 4).

Name resolution of the public API host on the same day:

```text
api.runreveal.com → k8s-runrevealproducti-…us-east-2.elb.amazonaws.com
```

The vendor docs (read 2026-11-18) add two things. The API base URL is `https://api.runreveal.com`.
The CloudTrail CloudFormation templates are published in `us-east-2`
([CloudTrail source](https://docs.runreveal.com/sources/source-types/aws/cloudtrail)). The docs
do not name a control-plane region.

### What that means

```text
source (GitHub, AWS, ClickHouse Cloud audit, …)
  → RunReveal pipeline, AWS us-east-2
  → INSERT over the public internet → destination service, ap-northeast-2
console, chat, detections
  → SELECT from us-east-2 → results back to us-east-2
```

- Events are **stored** in the destination's region. They are **processed** in `us-east-2` before
  they get there, and query results travel back to `us-east-2` whenever the console, chat or a
  detection reads them.
- A service with an IP access list has to allow RunReveal's egress addresses. Those addresses are in
  `us-east-2`. An access list that leaves them out was not tested here.

### Checks

| Check | Expected | 2026-11-18 |
|---|---|---|
| Positive: RunReveal's inserts come from a region we can name | every `runreveal` address maps to an `ip-ranges.json` prefix | Pass: both addresses are in `us-east-2` EC2 prefixes |
| Negative: nothing is processed in the destination's region | no `runreveal` address in an `ap-northeast-2` prefix | Pass: none |

### Not confirmed

- Whether RunReveal keeps events in `us-east-2` (queues, buffers, its own topics) and for how long.
  The docs describe sources → topics → pipelines → ClickHouse without saying where topics live.
- Whether other regions exist for the control plane. The docs name none, and this run saw only `us-east-2`.
- Where the LLM calls for chat and agents go. That depends on the provider key the workspace owner enters.
- Private connectivity (PrivateLink or similar) between RunReveal and the destination. Not documented
  in the pages read, and not tested.

## 한국어

데이터를 특정 리전에 두어야 하는 고객은 이렇게 묻습니다. ClickHouse Cloud destination이 우리
리전에 있으면 데이터도 거기에만 있나요? 이 실습은 문서로 답하지 않고 destination 서비스에서 직접
읽습니다. `system.query_log`는 RunReveal이 어느 주소에서 접속하는지 보여주고, AWS가 공개한 IP 대역은
그 주소가 어느 리전인지 알려줍니다.

실행일은 2026-11-18입니다.

- **destination:** AWS `ap-northeast-2`(서울)의 ClickHouse Cloud 서비스, ClickHouse 26.8.1.654
- **소스:** RunReveal 자체 audit 로그뿐
- **기간:** 2026-11-17 12:15 ~ 2026-11-18 12:44 UTC
- **IP 대역:** [`ip-ranges.json`](https://ip-ranges.amazonaws.com/ip-ranges.json), createDate `2026-11-18-10-27-05`

| 파일 | 내용 |
|---|---|
| `queries.sql` | 아래 `query_log` 쿼리(읽기 전용) |

### destination이 본 것

`runreveal` 사용자의 모든 접속을 주소와 클라이언트로 묶었습니다(쿼리 1). 주소와 `client_name`의 ID는
가렸습니다. 주소마다 `ip-ranges.json`에서 가장 좁은 대역을 찾았습니다.

| 주소 | 리전(AWS ip-ranges) | 클라이언트 | 쿼리 |
|---|---|---|---|
| `3.14.0.0/15` 안의 IP 하나 | `us-east-2`, EC2 | `<id>/ clickhouse-go/2.33.1 (lv:go/1.27.3; os:linux)` | `Insert` 293건 |
| `3.16.0.0/14` 안의 IP 하나 | `us-east-2`, EC2 | `workspace-<workspace id>/ clickhouse-go/2.33.1 ...` | `Set`·`Select` 112건, 우리가 콘솔을 쓰는 동안 |
| 같은 `3.16.0.0/14` IP | `us-east-2`, EC2 | `<id>/ clickhouse-go/2.33.1 ...` | `Insert` 2건 |

- 모든 쿼리는 native 프로토콜(`interface` 1)로 들어왔습니다(쿼리 2).
- `is_secure`는 모두 0이었습니다. 그런데 우리가 8443 포트 HTTPS로 붙은 세션도 `is_secure = 0`입니다
  (쿼리 3, 대조군). 그래서 이 서비스에서는 이 필드로 클라이언트의 TLS 사용 여부를 알 수 없습니다.
  이 실습은 어느 쪽이라고도 말하지 않습니다.
- 콘솔 쿼리는 대시보드용입니다: 소스 볼륨, 누락 로그 지표, signal·alert 수, 디텍션 결과, audit 로그(쿼리 4).

같은 날 공개 API 호스트의 이름 해석:

```text
api.runreveal.com → k8s-runrevealproducti-…us-east-2.elb.amazonaws.com
```

벤더 문서(2026-11-18 읽음)는 두 가지를 더 알려줍니다. API base URL은 `https://api.runreveal.com`입니다.
CloudTrail용 CloudFormation 템플릿은 `us-east-2`에 있습니다
([CloudTrail source](https://docs.runreveal.com/sources/source-types/aws/cloudtrail)). 문서에
control plane 리전은 나오지 않습니다.

### 무슨 뜻인가

```text
source (GitHub, AWS, ClickHouse Cloud audit, …)
  → RunReveal pipeline, AWS us-east-2
  → INSERT over the public internet → destination service, ap-northeast-2
console, chat, detections
  → SELECT from us-east-2 → results back to us-east-2
```

- 이벤트는 destination 리전에 **저장**됩니다. 하지만 거기 도착하기 전에 `us-east-2`에서 **처리**됩니다.
  콘솔, chat, 디텍션이 데이터를 읽을 때마다 쿼리 결과도 `us-east-2`로 돌아갑니다.
- 서비스에 IP access list가 있으면 RunReveal의 송신 주소를 허용해야 합니다. 그 주소들은 `us-east-2`에
  있습니다. 이 주소를 뺀 access list는 여기서 시험하지 않았습니다.

### 판정

| 판정 | 기대 | 2026-11-18 |
|---|---|---|
| Positive: RunReveal의 insert가 오는 리전을 특정할 수 있다 | `runreveal`의 모든 주소가 `ip-ranges.json` 대역에 들어간다 | 통과: 두 주소 모두 `us-east-2` EC2 대역 |
| Negative: destination 리전에서는 아무것도 처리되지 않는다 | `ap-northeast-2` 대역의 `runreveal` 주소가 없다 | 통과: 없음 |

### 확인하지 못한 것

- RunReveal이 이벤트를 `us-east-2`에 보관하는지(큐, 버퍼, 자체 topic), 보관한다면 얼마나 오래인지.
  문서는 sources → topics → pipelines → ClickHouse 순서만 설명하고 topic의 위치는 말하지 않습니다.
- control plane이 다른 리전에도 있는지. 문서에는 없고, 이번 실행에서는 `us-east-2`만 보였습니다.
- chat과 에이전트의 LLM 호출이 어디로 가는지. 워크스페이스 소유자가 넣는 provider 키에 달렸습니다.
- RunReveal과 destination 사이의 사설 연결(PrivateLink 등). 읽은 문서에 없고 시험하지 않았습니다.
