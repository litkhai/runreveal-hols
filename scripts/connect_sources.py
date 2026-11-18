#!/usr/bin/env python3
"""Connect the lab sources of #1 to a RunReveal workspace through its API.

  scripts/connect_sources.py --dry-run          print each request body, secrets masked
  scripts/connect_sources.py                    test, then create, every source whose variables are set
  scripts/connect_sources.py --only github      one source: clickhouse-cloud-audit, github, cloudtrail
  scripts/connect_sources.py --env other.env    read another env file (default: .env at the repo root)

For each source: skip it when a required variable is empty, skip it when a source with the same
name already exists (GET /sources/list), run POST /sources/test, and only if that succeeds run
POST /sources/create. Nothing else is created: CloudTrail's bucket and trail come from RunReveal's
CloudFormation template, which the operator deploys separately.

Endpoints and auth: https://docs.runreveal.com/api-reference/sources and
https://docs.runreveal.com/api-reference (read 2026-11-18). The per-type `settings` and `secrets`
keys are not in that reference; they were read from the console's own /sources/test requests,
sent with fake values on 2026-11-18. Secrets are read from the env file and sent only in request
bodies and headers, never printed and never on a command line. Standard library only.
"""
import argparse
import json
import os
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# name, type, ingestType, settings {key: env}, secrets {key: env}, optional settings {key: env}
SOURCES = {
    "clickhouse-cloud-audit": {
        "ingestType": "polling",
        "settings": {"organizationID": "CHC_AUDIT_ORG_ID"},
        "secrets": {"keyID": "CHC_AUDIT_KEY_ID", "keySecret": "CHC_AUDIT_KEY_SECRET"},
        "optional": {},
    },
    "github": {
        "ingestType": "polling",
        "settings": {"organization": "GITHUB_AUDIT_ORG"},
        "secrets": {"apiToken": "GITHUB_AUDIT_TOKEN"},
        # "all" was seen in the console; empty leaves the console default (web events only).
        "optional": {"include": "GITHUB_AUDIT_INCLUDE"},
    },
    "cloudtrail": {
        "ingestType": "s3",
        "settings": {"bucketName": "CLOUDTRAIL_BUCKET"},
        "secrets": {},
        # Empty role ARN = RunReveal's own role, the CloudFormation path in the CloudTrail docs.
        "optional": {"pathPrefix": "CLOUDTRAIL_PATH_PREFIX", "roleARN": "CLOUDTRAIL_ROLE_ARN",
                     "externalID": "CLOUDTRAIL_EXTERNAL_ID"},
    },
}
REQUIRED_API = ("RUNREVEAL_TOKEN", "RUNREVEAL_WORKSPACE")


def load_env(path):
    if not path.exists():
        sys.exit(f"connect_sources: {path.name} not found; copy .env.example to .env and fill it in")
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        sys.exit(f"connect_sources: {path.name} is mode {mode:o}; run: chmod 600 {path.name}")
    env = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip().removeprefix("export ").strip()] = value.strip().strip("'\"")
    # The process environment wins, so a single value can be overridden for one run.
    return {**env, **{k: v for k, v in os.environ.items() if k in env or k.startswith("RUNREVEAL_")}}


def body_for(name, spec, env):
    missing = [v for v in [*spec["settings"].values(), *spec["secrets"].values()] if not env.get(v)]
    if missing:
        return None, missing
    settings = {k: env[v] for k, v in spec["settings"].items()}
    settings.update({k: env[v] for k, v in spec["optional"].items() if env.get(v)})
    return {
        "name": env.get(f"{name.upper().replace('-', '_')}_NAME") or name,
        "displayName": "",
        "type": name,
        "ingestType": spec["ingestType"],
        "isActive": True,
        "settings": settings,
        "secrets": {k: env[v] for k, v in spec["secrets"].items()},
    }, []


def masked(body):
    return {**body, "secrets": {k: "***" for k in body["secrets"]}}


class Api:
    def __init__(self, env):
        self.base = (env.get("RUNREVEAL_BASEURL") or "https://api.runreveal.com").rstrip("/")
        self.workspace = env["RUNREVEAL_WORKSPACE"]
        self.token = env["RUNREVEAL_TOKEN"]

    def call(self, method, path, body=None):
        url = f"{self.base}{path}?{urllib.parse.urlencode({'workspaceid': self.workspace})}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            # "Authorization: Basic <token>" per https://docs.runreveal.com/api-reference
            "Authorization": f"Basic {self.token}",
            "Content-Type": "application/json",
        })
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as e:
            detail = e.read()[:300].decode(errors="replace")
            hint = " (check RUNREVEAL_TOKEN and RUNREVEAL_BASEURL)" if e.code in (401, 403) else ""
            raise SystemExit(f"connect_sources: {method} {path} -> HTTP {e.code}{hint}: {detail}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="print the bodies, send nothing")
    ap.add_argument("--only", choices=sorted(SOURCES), help="connect one source")
    ap.add_argument("--env", default=str(ROOT / ".env"), help="env file (default: .env at the repo root)")
    args = ap.parse_args()

    env = load_env(Path(args.env))
    names = [args.only] if args.only else list(SOURCES)
    bodies = {}
    for name in names:
        body, missing = body_for(name, SOURCES[name], env)
        if body is None:
            print(f"skip   {name}: not set: {', '.join(missing)}")
        else:
            bodies[name] = body
    if not bodies:
        sys.exit("connect_sources: no source has its variables set")

    if args.dry_run:
        for name, body in bodies.items():
            print(f"would test, then create {name}:\n{json.dumps(masked(body), indent=2)}")
        return

    missing_api = [k for k in REQUIRED_API if not env.get(k)]
    if missing_api:
        sys.exit(f"connect_sources: not set: {', '.join(missing_api)}")
    api = Api(env)
    existing = {s.get("name") for s in (api.call("GET", "/sources/list").get("result") or [])}
    failed = 0
    for name, body in bodies.items():
        if body["name"] in existing:
            print(f"exists {body['name']}: left as it is")
            continue
        test = api.call("POST", "/sources/test", body).get("result") or {}
        if not test.get("success"):
            print(f"FAIL   {name}: test: {test.get('error') or 'no success flag in the reply'}")
            failed += 1
            continue
        created = api.call("POST", "/sources/create", body)
        source_id = (created.get("result") or {}).get("id")
        if not created.get("success") or not source_id:
            print(f"FAIL   {name}: create: {created.get('error') or 'no id in the reply'}")
            failed += 1
            continue
        print(f"ok     {name}: test passed, created {source_id}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
