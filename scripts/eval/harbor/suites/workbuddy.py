"""The `workbuddy` runner kind: WorkBuddy-Bench subsets under the workbench worker.

This drives the existing pinned integration (scripts/eval/workbuddy): a
checkout provisioned by `provision_checkout.sh` (pinned commit, metacodes
overlay, locked `.venv`), linux/amd64 split-mount artifacts staged by
`stage_artifacts`, and an official subset fetched by WorkBuddy's
`scripts/dataset/fetch-dataset.sh`. One launch writes a transient model and
job configuration into that checkout, runs WorkBuddy's own runner
(`uv run --frozen bash scripts/run.sh --job <slug>`) under the same durable
worker as Harbor launches (record/spec/cancel/heartbeat), and removes the
two files afterwards so the checkout stays clean for `install_overlay` and
the paid launch gate.

Results: WorkBuddy runs Harbor itself, with `jobs_dir` set to
`<jobs-dir>/<run>/workbuddy`. Harbor creates its own run directories there;
the worker writes the workbench job's `config.json`/`result.json` at
`<jobs-dir>/<run>/`, and the viewer reads the trials from the nested Harbor
run directories (data.trial_dirs).

Scope: these are ordinary (unbudgeted) WorkBuddy runs with the execution
host's Metask account key, not launch-gate receipts; their results are not
quality evidence for the paired studies in scripts/eval/workbuddy/README.md.
The Web and Office subsets run an LLM judge whose spend only the launch gate
budgets, so the workbench lists them but does not launch them.
"""
from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from scripts.eval.harbor.command import split_model
from scripts.eval.workbuddy import WORKBUDDY_JUDGE_KEY_ENV, WORKBUDDY_PINNED_COMMIT

CHECKOUT_ENV = "METACODES_WORKBUDDY_CHECKOUT"
TARGET_PLATFORM = "linux/amd64"  # stage_artifacts.TARGET_PLATFORM
HARNESS = "metacodes/0.1.0"
OVERLAY = Path("configs/harnesses/metacodes/OVERLAY.json")
ARTIFACT_MANIFEST = Path("configs/harnesses/metacodes/docker/artifacts/share/metacodes/artifact-manifest.json")
JUDGED_SUBSETS = ("web", "office")
BASE_URL_ENV = "METACODES_BENCH_WORKBUDDY_BASE_URL"
KEY_ENV = "METACODES_BENCH_WORKBUDDY_API_KEY"
RESULTS_DIR = "workbuddy"


def dataset_rel(subset: str) -> str:
    return f"datasets/wb-bench-{subset}-v1.0/tasks"


def checkout(ctx) -> Optional[Path]:
    value = ctx.cfg.get("workbuddy_checkout") or ctx.env.get(CHECKOUT_ENV)
    return Path(value).expanduser() if value else None


def _head(repo: Path) -> str:
    try:
        head = (repo / ".git" / "HEAD").read_text(encoding="utf-8").strip()
        if head.startswith("ref: "):
            head = (repo / ".git" / head[5:]).read_text(encoding="utf-8").strip()
        return head
    except OSError:
        return ""


def _json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def auth_mode(cfg) -> str:
    return cfg.get("auth_mode") or ("provider" if cfg.get("provider_config") else "metask")


def task_ids(suite, ctx) -> List[str]:
    from scripts.eval.harbor.suites import TASK, Unavailable, local_tasks
    repo = checkout(ctx)
    if repo is None:
        raise Unavailable(f"未配置 WorkBuddy checkout：metacodes bench --workbuddy-checkout <目录>，或设置 {CHECKOUT_ENV}"
                          "（用 scripts/eval/workbuddy/provision_checkout.sh 准备）")
    found = [t for t in local_tasks(repo / dataset_rel(suite.subset)) if TASK.fullmatch(t)]
    if not found:
        raise Unavailable(f"{suite.name} 数据集未下载：在 WorkBuddy checkout 中运行 scripts/dataset/fetch-dataset.sh {suite.subset}")
    return found


def readiness(suite, ctx) -> List[str]:
    reasons = []
    if suite.subset in JUDGED_SUBSETS:
        reasons.append(f"{suite.name} 需要 LLM judge，其花费只能由 WorkBuddy launch_gate 预算授权；工作台暂不发起")
    if auth_mode(ctx.cfg) != "metask":
        reasons.append("WorkBuddy 评测目前只支持 Metask 账号模式（--auth metask）")
    repo = checkout(ctx)
    if repo is not None:
        if not repo.is_dir():
            reasons.append(f"WorkBuddy checkout 不存在：{repo}")
        else:
            head = _head(repo)
            if head != WORKBUDDY_PINNED_COMMIT:
                reasons.append(f"WorkBuddy checkout 必须是固定提交 {WORKBUDDY_PINNED_COMMIT[:12]}（当前 {head[:12] or '未知'}）")
            overlay = _json(repo / OVERLAY) or {}
            if overlay.get("workbuddy_commit") != WORKBUDDY_PINNED_COMMIT:
                reasons.append("WorkBuddy checkout 未安装 metacodes overlay：python3 -m scripts.eval.workbuddy.install_overlay <checkout>")
            if not (repo / ".venv").is_dir():
                reasons.append("WorkBuddy checkout 缺少 .venv：用 provision_checkout.sh 准备（uv sync --frozen）")
            manifest = _json(repo / ARTIFACT_MANIFEST)
            if not isinstance(manifest, dict):
                reasons.append("WorkBuddy 未暂存 metacodes 制品：python3 -m scripts.eval.workbuddy.stage_artifacts --output "
                               "<checkout>/configs/harnesses/metacodes/docker/artifacts ...")
            elif manifest.get("target_platform") != TARGET_PLATFORM or manifest.get("synthetic_fixture"):
                reasons.append("WorkBuddy 暂存制品不是 linux/amd64 正式制品（W0 合成制品不能用于评测）")
    for tool in ("docker", "uv", "bash"):
        if not shutil.which(tool):
            reasons.append(f"未找到 {tool}；WorkBuddy 评测需要它")
    return reasons


def slug(name: str) -> str:
    return "metacodes-" + name


def job_documents(spec) -> Tuple[dict, dict]:
    """(model config, job config). JSON is valid YAML; WorkBuddy reads YAML."""
    # Account models are listed as `metask/<id>`; the gateway takes the id.
    model = {"model": {"name": split_model(spec["model"])[1], "protocols": ["anthropic"],
                       "backend_url_env": BASE_URL_ENV, "backend_key_env": KEY_ENV,
                       "context_window": 200000, "max_concurrent": spec["concurrency"],
                       "params": {"max_output_tokens": 32768}}}
    params = {}
    if spec.get("reasoning_effort"):
        params["METACODES_REASONING_EFFORT"] = spec["reasoning_effort"]
    job = {"model": slug(spec["name"]), "harness": HARNESS, "dataset": dataset_rel(spec["workbuddy"]["subset"]),
           "harness_backend": "local", "model_connection": "local_proxy",
           "jobs_dir": str(Path(spec["jobs_dir"]) / spec["name"] / RESULTS_DIR),
           "n_attempts": spec["attempts"], "record_full_io": False,
           "agent_user": "dev", "verifier_user": "dev",
           "extra_allowed_hosts": ["host.docker.internal"],
           "task_selection": {"mode": "name", "names": list(spec["tasks"])},
           "orchestrator_override": {"n_concurrent_trials": spec["concurrency"]},
           "context_window": 200000, "context_compact_pct": 92}
    if params:
        job["harness_params_override"] = params
    return model, job


def config_paths(spec) -> List[Path]:
    repo = Path(spec["workbuddy"]["checkout"])
    name = slug(spec["name"]) + ".yaml"
    return [repo / "configs" / "models" / name, repo / "configs" / "jobs" / name]


def launch(spec, env) -> Tuple[List[str], str, Dict[str, str]]:
    """Write the transient configs and the workbench job; return argv, cwd, env."""
    from scripts.eval.harbor.bench.runner import atomic_json, now
    wb = spec["workbuddy"]
    model, job = job_documents(spec)
    for path, document in zip(config_paths(spec), (model, job)):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("x", encoding="utf-8") as output:
            json.dump(document, output, indent=2)
            output.write("\n")
    root = Path(spec["jobs_dir"]) / spec["name"]
    atomic_json(root / "config.json", {
        "job_name": spec["name"], "runner": "workbuddy",
        "agents": [{"name": "metacodes", "model_name": spec["model"]}],
        "datasets": [{"name": "workbuddy/wb-bench-" + wb["subset"] + "-v1.0"}],
        "n_attempts": spec["attempts"], "n_concurrent_trials": spec["concurrency"]})
    atomic_json(root / "result.json", {"started_at": now(), "finished_at": None,
                                       "n_total_trials": len(spec["tasks"]) * spec["attempts"]})
    child = dict(env)
    child.pop("PYTHONPATH", None)  # WorkBuddy sets its own src path
    child.pop(WORKBUDDY_JUDGE_KEY_ENV, None)
    key = child.pop("METASK_API_KEY", None)
    if not key:
        raise ValueError("缺少账号 Key")
    child.update({BASE_URL_ENV: spec["account_gateway"].rstrip("/") + "/v1/messages", KEY_ENV: key,
                  "SHARDS": "1", "SHARD_CONCURRENCY": str(spec["concurrency"]),
                  "AUTO_BUILD_HARNESS_MOUNT": "1", "DOCKER_DEFAULT_PLATFORM": TARGET_PLATFORM})
    argv = [wb["uv"], "run", "--frozen", wb["bash"], "scripts/run.sh", "--job", slug(spec["name"])]
    return argv, wb["checkout"], child


def finish(spec):
    """Mark the workbench job finished and remove the transient configs."""
    from scripts.eval.harbor.bench import data
    from scripts.eval.harbor.bench.runner import atomic_json, now
    for path in config_paths(spec):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    result = Path(spec["jobs_dir"]) / spec["name"] / "result.json"
    value = data.read_json(result)
    if isinstance(value, dict) and not value.get("finished_at"):
        atomic_json(result, {**value, "finished_at": now()})


def spec_fields(suite, ctx) -> dict:
    return {"checkout": str(checkout(ctx).resolve()), "subset": suite.subset,
            "uv": shutil.which("uv"), "bash": shutil.which("bash")}
