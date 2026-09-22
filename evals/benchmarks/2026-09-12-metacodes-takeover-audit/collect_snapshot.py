"""Read-only, bounded WorkBuddy snapshot. Run over SSH stdin; no provider calls."""
import hashlib
import json
import pathlib
import subprocess
import sys
from datetime import datetime, timezone

host = sys.argv[1]
base = pathlib.Path.home() / "frontier-bench/workbuddy"
slugs = []
for domain in (["code", "office"] if host == "patron" else ["security", "web"]):
    for cohort in ["dev", "proma", "promb", "sealed"]:
        suffix = "diag1" if domain == "security" and cohort != "proma" else "full1"
        slugs.append(f"metacodes-glm52-{domain}-{cohort}-{suffix}")
if host == "kunshan":
    slugs.append("metacodes-glm52-security-sealed-sec15")

def read(path):
    return json.loads(path.read_text())

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def pick(d, keys):
    return {k: d.get(k) for k in keys}

out = {"host": host, "collected_at": datetime.now(timezone.utc).isoformat(), "slugs": {}}
for slug in slugs:
    root = base / "checkout/results" / slug
    runs = []
    for run in sorted(root.glob("2026-09-1*")):
        rows = []
        for result in sorted(run.glob("*/result.json")):
            d = read(result)
            if d.get("started_at", "") < "2026-09-10T00:00:00":
                continue
            row = pick(d, ["task_name", "trial_name", "started_at", "finished_at", "verifier_result"])
            row["task"] = d["task_name"].split("/")[-1]
            row["result_path"] = str(result.relative_to(base))
            row["result_sha256"] = digest(result)
            tid = d.get("task_id") or {}
            path = tid.get("path", "") if isinstance(tid, dict) else str(tid)
            row["launch_run_id"] = path.split("/staged/")[1].split("/")[0] if "/staged/" in path else None
            row["agent_result"] = pick(d.get("agent_result") or {}, ["n_input_tokens", "n_output_tokens", "n_cache_tokens", "cost_usd"])
            ex = d.get("exception_info") or {}
            row["exception_type"] = ex.get("exception_type") or ex.get("type")
            cfg = d.get("config") or {}
            agent = cfg.get("agent") or {}
            row["agent_config"] = pick(agent, ["name", "import_path", "model_name"])
            row["step_count"] = len(d.get("step_results") or [])
            rows.append(row)
        if rows:
            runs.append({"run": run.name, "started_at": min(r["started_at"] for r in rows), "rows": rows})
    runs.sort(key=lambda r: r["started_at"])
    selected = runs[-1] if runs else None
    selected_ids = {r["launch_run_id"] for r in selected["rows"]} if selected else set()
    launches, receipts = [], []
    private = base / "private" / slug
    for path in sorted(private.glob("launch-*.json")):
        d = read(path)
        if d.get("run_id") not in selected_ids:
            continue
        l = pick(d, ["run_id", "content_sha256", "harness_fingerprint", "quality_evidence", "evaluation_treatment"])
        l["file"] = str(path.relative_to(base))
        l["sha256"] = digest(path)
        l["artifacts"] = {k: pick(v, ["bytes", "sha256"]) for k, v in d["artifacts"]["executables"].items()}
        l["artifact_manifest_sha256"] = d["artifacts"]["manifest"]["sha256"]
        l["workbuddy"] = pick(d["workbuddy"], ["commit", "overlay_content_sha256"])
        l["model"] = pick(d["model"], ["backend_model_name", "fingerprint", "slug"])
        l["execution"] = pick(d["execution"], ["n_attempts", "n_concurrent_trials", "local_tinykg", "remote_tinykg_env_cleared"])
        launches.append(l)
    for path in sorted(private.glob("receipt-*.json")):
        d = read(path)
        if d.get("run_id") not in selected_ids:
            continue
        r = pick(d, ["run_id", "schema_version", "state", "failure_stage", "quality_evidence", "actual_usage_known", "retry_allowed", "runner"])
        if r["state"] is None and "paid-receipt" in str(r["schema_version"]):
            r["state"] = "committed"
        r["file"] = str(path.relative_to(base))
        r["sha256"] = digest(path)
        r["budget_transaction"] = pick(d.get("budget_transaction") or {}, ["state", "max_cost_microusd", "max_metered_tokens", "actual_cost_microusd", "actual_metered_tokens", "journal_head_sha256"])
        r["failure_evidence_keys"] = list((d.get("failure_evidence") or {}).keys())
        receipts.append(r)
    out["slugs"][slug] = {"selected": selected, "other_runs": [{"run": r["run"], "started_at": r["started_at"], "trials": len(r["rows"])} for r in runs[:-1]], "launches": launches, "receipts": receipts}

manifest = base / "checkout/configs/harnesses/metacodes/docker/artifacts/share/metacodes/artifact-manifest.json"
out["current_artifact_manifest"] = read(manifest)
out["current_artifact_manifest_sha256"] = digest(manifest)
binary = base / "checkout/configs/harnesses/metacodes/docker/artifacts/bin/metacodes"
out["current_binary_sha256"] = digest(binary)
out["current_binary_version"] = subprocess.run([str(binary), "--version"], capture_output=True, text=True, timeout=10).stdout.strip()
repo = base.parent / "metacodes-git"
out["current_host_checkout_commit"] = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
print(json.dumps(out, indent=2, ensure_ascii=False))
