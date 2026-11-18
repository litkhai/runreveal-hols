# STATUS

Snapshot of the repository. Planned work lives in [issues](https://github.com/litkhai/runreveal-hols/issues), not here.

| Item | State (2026-11-18) |
|---|---|
| Labs | `schema-tour` (scenario 1), `data-path` (scenario 5), both run 2026-11-18, `web: false`; scenarios 2–4 wait for real sources (#1) |
| Lab tools | `tools/labs_json.py`, `tools/lab.schema.md` synced from khai-workbench @f01143a, with the `runreveal` category and the `security` tag |
| `docs/labs.json` | written by `tools/labs_json.py`; no lab sets `web: true` yet |
| Source setup | `scripts/connect_sources.py` (API test → create), checked 2026-11-18 against a local mock, then used for real: `clickhouse-cloud-audit` created in our workspace (test passed, rows arriving); GitHub and CloudTrail not connected |
| CI | one `guard` job on pull requests; `links` and `syntax` by hand |

## Pins

| What | Pin | Recorded |
|---|---|---|
| Destination | ClickHouse Cloud 26.8.1.654, AWS `ap-northeast-2` | 2026-11-18 |
| RunReveal client (from `query_log.client_name`) | clickhouse-go 2.33.1, go 1.27.3 | 2026-11-18 |

The RunReveal console build and CLI version are recorded by the first lab that uses them (scenario 4).
