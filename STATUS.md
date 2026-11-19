# STATUS

Snapshot of the repository. Planned work lives in [issues](https://github.com/litkhai/runreveal-hols/issues), not here.

| Item | State (2026-11-19) |
|---|---|
| Labs | `schema-tour` (scenario 1), `data-path` (scenario 5), run 2026-11-18; `ingest-storage` (scenario 2), `query-shapes` (scenario 3), run 2026-11-19; all `web: false`. Open in #1: `sourceTTL` deletion, detections and agents, scenario 4 |
| Lab tools | `tools/labs_json.py`, `tools/lab.schema.md` synced from khai-workbench @f01143a, with the `runreveal` category and the `security` tag |
| `docs/labs.json` | written by `tools/labs_json.py`; no lab sets `web: true` yet |
| Source setup | `scripts/connect_sources.py` (API test → create), checked 2026-11-18 against a local mock, then used for real: `clickhouse-cloud-audit` created in our workspace (test passed, rows arriving); GitHub and CloudTrail not connected |
| CI | one `guard` job on pull requests; `links` and `syntax` by hand |

## Pins

| What | Pin | Recorded |
|---|---|---|
| Destination | ClickHouse Cloud 26.8.1.654, AWS `ap-northeast-2` | 2026-11-18 |
| Destination | ClickHouse Cloud 26.8.1.780 (upgraded 2026-11-19 08:04 UTC; `query_log` rotated to `query_log_<N>`) | 2026-11-19 |
| RunReveal client (from `query_log.client_name`) | clickhouse-go 2.33.1, go 1.27.3 | 2026-11-18 |

The RunReveal console build and CLI version are recorded by the first lab that uses them (scenario 4).
