#!/usr/bin/env python3
"""Reconcile the local Metask ledger with the Metask gateway's billing records.

The client ledger (~/.metacodes/ledger/metask.ndjson) records one line per gateway
request with the server request id and the token usage the server reported. The
gateway exposes the same requests with the platform's billing result at
GET {gateway}/v1/usage (scope=key: only this client authorization). Zero-discrepancy
means: every completed ledger request exists server-side with identical token
counts, every server record for this authorization exists in the ledger, and the
platform cost is attached to each request.

Usage:
  python3 scripts/metask_reconcile.py [--ledger PATH] [--oauth PATH] [--since ISO|unix]
  Exit code 0 = reconciled, 1 = mismatch, 2 = environment error. Never prints tokens.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone


def load_ledger(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def fetch_usage(gateway, token, since=None, scope="key"):
    out, before = [], None
    while True:
        params = {"limit": "500", "scope": scope}
        if since:
            params["since"] = since
        if before:
            params["before"] = before
        req = urllib.request.Request(f"{gateway.rstrip('/')}/v1/usage?{urllib.parse.urlencode(params)}",
                                     headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            page = json.load(resp)
        if page.get("object") != "list" or page.get("unit") != "mU" or not isinstance(page.get("data"), list):
            raise ValueError("unexpected /v1/usage envelope")
        out.extend(page["data"])
        if not page.get("has_more") or not page.get("next_before"):
            return out
        before = page["next_before"]


def parse_since_ms(v):
    """--since 同时用于服务端查询与本地账本(ts 为毫秒):RFC3339 或 unix 秒。"""
    if v is None:
        return None
    try:
        return int(v) * 1000
    except ValueError:
        return int(datetime.fromisoformat(v.replace("Z", "+00:00")).astimezone(timezone.utc).timestamp() * 1000)


def gateway_origin_ok(url):
    u = urllib.parse.urlsplit(url)
    return u.scheme in ("http", "https") and bool(u.netloc) and u.path in ("", "/") and not u.query and not u.fragment


REQUIRED_SERVER_FIELDS = ("request_id", "model", "input_tokens", "output_tokens", "cache_read_tokens",
                          "cache_creation_tokens", "charged", "cost_mu")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ledger", default=os.environ.get("METACODES_LEDGER_DIR", os.path.expanduser("~/.metacodes/ledger")) + "/metask.ndjson")
    ap.add_argument("--oauth", default=os.environ.get("METACODES_OAUTH_DIR", os.path.expanduser("~/.metacodes/oauth")) + "/metask.json")
    ap.add_argument("--gateway", default=os.environ.get("METASK_GATEWAY_URL"))
    ap.add_argument("--since", default=None, help="only reconcile server records at/after this time (RFC3339 or unix seconds)")
    ap.add_argument("--json", action="store_true", help="machine-readable report")
    a = ap.parse_args()
    try:
        with open(a.oauth, encoding="utf-8") as f:
            oauth = json.load(f)
    except (OSError, ValueError) as e:
        print(f"cannot read oauth store {a.oauth}: {e}", file=sys.stderr)
        return 2
    gateway = a.gateway or oauth.get("gateway_url")
    token = oauth.get("access_token")
    if not gateway or not token:
        print("oauth store lacks gateway_url/access_token; run `metacodes login --provider metask`", file=sys.stderr)
        return 2
    if not gateway_origin_ok(gateway):
        print(f"gateway must be an http(s) origin without a path: {gateway}", file=sys.stderr)
        return 2
    try:
        since_ms = parse_since_ms(a.since)
    except ValueError:
        print("--since must be RFC3339 or unix seconds", file=sys.stderr)
        return 2
    try:
        ledger = load_ledger(a.ledger)
    except (OSError, ValueError) as e:
        print(f"cannot read ledger {a.ledger}: {e}", file=sys.stderr)
        return 2
    try:
        server = fetch_usage(gateway, token, a.since)
    except urllib.error.HTTPError as e:
        print(f"gateway rejected the usage query: HTTP {e.code}", file=sys.stderr)  # body may echo credentials; not printed
        return 2
    except (urllib.error.URLError, TimeoutError, ValueError, OSError) as e:
        print(f"gateway unreachable or malformed response: {e.__class__.__name__}", file=sys.stderr)
        return 2

    problems = []
    if since_ms is not None:
        ledger = [r for r in ledger if int(r.get("ts", 0)) >= since_ms]
    completed = [r for r in ledger if r.get("http_status") == 200 and r.get("outcome") == "completed" and r.get("server_request_id")]
    local_failed = [r for r in ledger if not (r.get("http_status") == 200 and r.get("outcome") == "completed")]
    local_ok = {}
    for r in completed:
        rid = r["server_request_id"]
        if rid in local_ok:
            problems.append({"kind": "duplicate_in_ledger", "request_id": rid})
        local_ok[rid] = r
    remote = {}
    for s_ in server:
        missing = [k for k in REQUIRED_SERVER_FIELDS if k not in s_]
        if missing:
            problems.append({"kind": "malformed_server_record", "request_id": s_.get("request_id"), "missing": missing})
            continue
        if s_["request_id"] in remote:
            problems.append({"kind": "duplicate_on_server", "request_id": s_["request_id"]})
        remote[s_["request_id"]] = s_
    matched = 0
    for rid, r in local_ok.items():
        s_ = remote.get(rid)
        if not s_:
            problems.append({"kind": "missing_on_server", "request_id": rid, "local": r})
            continue
        before = len(problems)
        for lk, sk in (("input_tokens", "input_tokens"), ("output_tokens", "output_tokens"),
                       ("cache_read_tokens", "cache_read_tokens"), ("cache_creation_tokens", "cache_creation_tokens")):
            if int(r.get(lk, 0)) != int(s_.get(sk, 0)):
                problems.append({"kind": "token_mismatch", "request_id": rid, "field": lk, "local": r.get(lk), "server": s_.get(sk)})
        if r.get("model") != s_.get("model"):
            problems.append({"kind": "model_mismatch", "request_id": rid, "local": r.get("model"), "server": s_.get("model")})
        if not s_.get("charged"):
            problems.append({"kind": "not_charged_yet", "request_id": rid})
        if len(problems) == before:
            matched += 1
    for rid, s_ in remote.items():
        if rid not in local_ok:
            problems.append({"kind": "missing_in_ledger", "request_id": rid, "server": s_})
    total_cost = sum(int(s_["cost_mu"]) for s_ in remote.values())
    report = {
        "gateway": gateway,
        "ledger_completed": len(local_ok),
        "ledger_failed": len(local_failed),
        "server_records": len(remote),
        "server_cost_mu": total_cost,
        "server_cost_u": total_cost / 1000,
        "matched": matched,
        "problems": problems,
    }
    if a.json:
        print(json.dumps(report, ensure_ascii=False, indent=1))
    else:
        print(f"gateway {gateway}")
        print(f"ledger: {len(local_ok)} completed, {len(local_failed)} failed (not billable)")
        print(f"server: {len(remote)} billed requests, cost {total_cost} mU = {total_cost / 1000:.3f} U")
        for rid, s_ in sorted(remote.items(), key=lambda kv: kv[1].get("ts", "")):
            l = local_ok.get(rid)
            flag = "OK " if l and not [p for p in problems if p.get("request_id") == rid] else "!! "
            print(f"  {flag}{rid}  {s_.get('model')}  in={s_.get('input_tokens')} out={s_.get('output_tokens')} cache={s_.get('cache_read_tokens')}  cost={s_.get('cost_mu')} mU  (quota/A/U {s_.get('from_quota_mu')}/{s_.get('from_a_mu')}/{s_.get('from_u_mu')})")
        for p in problems:
            print(f"  MISMATCH {p}")
        print("RECONCILED: zero discrepancy" if not problems else f"NOT RECONCILED: {len(problems)} problem(s)")
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
