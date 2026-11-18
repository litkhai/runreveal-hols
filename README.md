# RunReveal Hands-on Labs

[English](#english) | [한국어](#한국어)

## English

Self-test labs for **ClickHouse Security** (RunReveal), looked at from the ClickHouse side: what
it creates in a ClickHouse Cloud service, which queries it sends, and what that costs in rows,
bytes and time. The product's own feature tour lives in the
[RunReveal docs](https://docs.runreveal.com); these labs do not repeat it.

Every capture and number comes from our own workspace and our own sources (ClickHouse Cloud audit
log, GitHub, AWS CloudTrail of the lab account). Nothing here comes from demo workspaces or
synthetic attack data.

### What these labs look at

- **The destination.** With the ClickHouse Cloud destination, RunReveal provisions a `runreveal`
  database in a service you own. Its tables, engines, sorting keys and TTL decide how searches and
  detections behave.
- **The query path.** AI chat, scheduled detections and hunting agents end up as SQL in that
  service. `system.query_log` shows what they read.
- **Detection as code.** Detection SQL and YAML kept in Git and deployed with the RunReveal CLI.

### 🧪 Labs

| Lab | Scenario | What it shows |
|---|---|---|
| [schema-tour](labs/schema-tour/) | 1 | The 171 objects in `runreveal`: one wide `logs` table read through views, MVs for heavy sources, TTL with a 7-day floor |
| [data-path](labs/data-path/) | 5 | Inserts and console queries reach the destination from AWS `us-east-2`, wherever the destination is |

Scenarios 2 to 4 need real sources and are planned in [#1](https://github.com/litkhai/runreveal-hols/issues/1).

### Prerequisites

- A RunReveal workspace with the **ClickHouse Cloud** destination, pointed at a service you can query.
- An LLM API key of your own for chat and agents, entered in the RunReveal console and never committed.

### Connecting the sources

`scripts/connect_sources.py` connects the lab's sources (ClickHouse Cloud audit, GitHub audit,
AWS CloudTrail) through the RunReveal API. Copy `.env.example` to `.env`, run `chmod 600 .env`, and
fill in the sources you want.

```bash
scripts/connect_sources.py --dry-run   # bodies with secrets masked, nothing sent
scripts/connect_sources.py             # test each source, create it only if the test passes
```

The script skips a source with empty values and leaves a source with the same name alone. It
creates nothing in AWS. For CloudTrail, deploy RunReveal's CloudFormation template first (it
creates a bucket, an SNS topic and a trail, which cost money), then set `CLOUDTRAIL_BUCKET`.

### Repository checks

Enable the guard once per clone:

```bash
git config core.hooksPath .githooks
```

Pull requests run one `guard` job (gitleaks and hygiene). Link and syntax checks run by hand:
`gh workflow run checks.yml --ref <branch>`.

## 한국어

**ClickHouse Security**(RunReveal)를 ClickHouse 쪽에서 들여다보는 실습입니다. ClickHouse Cloud
서비스에 무엇을 만드는지, 어떤 쿼리를 보내는지, 그 비용이 행·바이트·시간으로 얼마인지를 봅니다.
제품 기능 소개는 [RunReveal 문서](https://docs.runreveal.com)에 있으므로 여기서는 반복하지 않습니다.

캡처와 수치는 모두 우리 워크스페이스와 우리 소스(ClickHouse Cloud audit 로그, GitHub, 실습 계정의
AWS CloudTrail)에서 나옵니다. 데모 워크스페이스나 합성 공격 데이터는 쓰지 않습니다.

### 실습에서 보는 것

- **Destination.** ClickHouse Cloud destination을 고르면 RunReveal은 내가 가진 서비스에
  `runreveal` 데이터베이스를 만듭니다. 그 테이블·엔진·정렬 키·TTL이 검색과 디텍션의 동작을 정합니다.
- **쿼리 경로.** AI chat, 예약 디텍션, 헌팅 에이전트는 결국 그 서비스의 SQL이 됩니다.
  `system.query_log`로 무엇을 읽는지 봅니다.
- **Detection as code.** 디텍션 SQL과 YAML을 Git에 두고 RunReveal CLI로 배포합니다.

### 🧪 실습

| 실습 | 시나리오 | 보여주는 것 |
|---|---|---|
| [schema-tour](labs/schema-tour/) | 1 | `runreveal`의 객체 171개: view로 읽는 넓은 `logs` 테이블, 무거운 소스용 MV, 하한 7일인 TTL |
| [data-path](labs/data-path/) | 5 | destination이 어디 있든 insert와 콘솔 쿼리는 AWS `us-east-2`에서 들어온다 |

시나리오 2~4는 실제 소스가 필요하며 [#1](https://github.com/litkhai/runreveal-hols/issues/1)에 계획이 있습니다.

### 준비물

- **ClickHouse Cloud** destination이 연결된 RunReveal 워크스페이스(직접 쿼리할 수 있는 서비스).
- chat과 에이전트용 LLM API 키. RunReveal 콘솔에 직접 넣고 커밋하지 않습니다.

### 소스 연결

`scripts/connect_sources.py`가 RunReveal API로 실습 소스(ClickHouse Cloud audit, GitHub audit,
AWS CloudTrail)를 연결합니다. `.env.example`을 `.env`로 복사하고 `chmod 600 .env` 한 뒤, 연결할
소스의 값을 채웁니다.

```bash
scripts/connect_sources.py --dry-run   # 시크릿을 가린 요청 본문만 출력, 전송 안 함
scripts/connect_sources.py             # 소스마다 test, 통과한 것만 create
```

값이 빈 소스는 건너뛰고, 같은 이름의 소스가 이미 있으면 건드리지 않습니다. AWS에는 아무것도
만들지 않습니다. CloudTrail은 RunReveal의 CloudFormation 템플릿을 먼저 배포한 뒤(버킷, SNS topic,
trail이 생기고 비용이 듭니다) `CLOUDTRAIL_BUCKET`을 채웁니다.

### 저장소 검사

클론마다 한 번 가드를 켭니다.

```bash
git config core.hooksPath .githooks
```

PR에서는 `guard` 작업 하나(gitleaks, 위생 검사)만 돕니다. 링크·문법 검사는 손으로 돌립니다:
`gh workflow run checks.yml --ref <branch>`.
