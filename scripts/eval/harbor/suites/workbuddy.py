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
The Web and Office subsets run WorkBuddy's in-container LLM judge through
the same account route as the agent, with the model `judges.<suite id>.model`
from workbench.json (default `DEFAULT_JUDGE_MODEL`).
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
DEFAULT_JUDGE_MODEL = "kimi-k3.1-pro"
BASE_URL_ENV = "METACODES_BENCH_WORKBUDDY_BASE_URL"
JUDGE_BASE_URL_ENV = "METACODES_BENCH_WORKBUDDY_JUDGE_BASE_URL"
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


def judge_model(suite, cfg) -> Optional[str]:
    if suite.subset not in JUDGED_SUBSETS:
        return None
    entry = ((cfg or {}).get("judges") or {}).get(suite.id) or {}
    if not isinstance(entry, dict) or set(entry) - {"model"}:
        raise ValueError(f"workbench.json 的 judges.{suite.id} 只接受 model")
    model = entry.get("model", DEFAULT_JUDGE_MODEL)
    from scripts.eval.harbor.profiling import JUDGE_MODEL
    if not isinstance(model, str) or not JUDGE_MODEL.fullmatch(model.removeprefix("metask/")):
        raise ValueError(f"judges.{suite.id}.model 无效：{str(model)[:80]}")
    return model.removeprefix("metask/")


def judge_slug(spec) -> str:
    return slug(spec["name"]) + "-judge"


def model_document(name: str, spec, protocol: str = "anthropic", url_env: str = BASE_URL_ENV,
                   max_output_tokens: Optional[int] = None) -> dict:
    return {"model": {"name": name, "protocols": [protocol],
                      "backend_url_env": url_env, "backend_key_env": KEY_ENV,
                      "context_window": 200000, "max_concurrent": spec["concurrency"],
                      "params": {"max_output_tokens": max_output_tokens or 32768}}}


def job_documents(spec) -> Tuple[dict, dict]:
    """(model config, job config). JSON is valid YAML; WorkBuddy reads YAML."""
    # Account models are listed as `metask/<id>`; the gateway takes the id.
    model = model_document(split_model(spec["model"])[1], spec, max_output_tokens=spec.get("max_tokens"))
    params = {}
    if spec.get("reasoning_effort"):
        params["METACODES_REASONING_EFFORT"] = spec["reasoning_effort"]
    # A run with its own mount image names it through its own harness version.
    harness = "metacodes/" + slug(spec["name"]) if spec["workbuddy"].get("harness_image") else HARNESS
    job = {"model": slug(spec["name"]), "harness": harness, "dataset": dataset_rel(spec["workbuddy"]["subset"]),
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
    if spec.get("workbuddy_judge"):
        job["llm_judge_override"] = {"enabled": True, "mode": "in_container", "model": judge_slug(spec)}
    return model, job


def config_paths(spec) -> List[Path]:
    repo = Path(spec["workbuddy"]["checkout"])
    name = slug(spec["name"]) + ".yaml"
    paths = [repo / "configs" / "models" / name, repo / "configs" / "jobs" / name]
    if spec["workbuddy"].get("harness_image"):
        paths.append(repo / HARNESS_VERSIONS / name)
    if spec.get("workbuddy_judge"):
        paths.append(repo / "configs" / "models" / (judge_slug(spec) + ".yaml"))
    return paths


def harness_version_document(repo: Path, image: str) -> str:
    """The pinned harness version file (HARNESS) with the mount image set to
    `image` (`mount.images.local`, which WorkBuddy otherwise derives as the
    shared HARNESS_IMAGE tag). WorkBuddy deep-merges it over _defaults.yaml."""
    text = (repo / HARNESS_VERSIONS / (HARNESS.split("/")[1] + ".yaml")).read_text(encoding="utf-8")
    lines = text.splitlines()
    tops = [line for line in lines if line.strip() and not line.startswith((" ", "#"))]
    if tops != ["harness:"] or any(line.startswith("  mount:") for line in lines):
        raise ValueError("WorkBuddy harness 版本文件的结构与预期不同，无法为本次运行指定挂载镜像")
    return text.rstrip("\n") + "\n  mount:\n    images:\n      local: " + json.dumps(image) + "\n"


def launch(spec, env) -> Tuple[List[str], str, Dict[str, str]]:
    """Write the transient configs and the workbench job; return argv, cwd, env."""
    from scripts.eval.harbor.bench.runner import atomic_json, now
    wb = spec["workbuddy"]
    if wb["subset"] in JUDGED_SUBSETS and not spec.get("workbuddy_judge"):
        raise ValueError(f"WorkBuddy {wb['subset']} 需要 LLM judge，但本次运行没有评委模型；请把工作台和执行节点更新到同一版本")
    model, job = job_documents(spec)
    documents = [json.dumps(model, indent=2), json.dumps(job, indent=2)]
    if wb.get("harness_image"):
        documents.append(harness_version_document(Path(wb["checkout"]), wb["harness_image"]).rstrip("\n"))
    if spec.get("workbuddy_judge"):
        documents.append(json.dumps(model_document(spec["workbuddy_judge"], spec, "openai", JUDGE_BASE_URL_ENV), indent=2))
    for path, document in zip(config_paths(spec), documents):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("x", encoding="utf-8") as output:
            output.write(document)
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
    child.update({BASE_URL_ENV: spec["account_gateway"].rstrip("/") + "/v1/messages",
                  JUDGE_BASE_URL_ENV: spec["account_gateway"].rstrip("/") + "/v1", KEY_ENV: key,
                  "SHARDS": "1", "SHARD_CONCURRENCY": str(spec["concurrency"]),
                  "AUTO_BUILD_HARNESS_MOUNT": "1", "DOCKER_DEFAULT_PLATFORM": TARGET_PLATFORM})
    argv = [wb["uv"], "run", "--frozen", wb["bash"], "scripts/run.sh", "--job", slug(spec["name"])]
    return argv, wb["checkout"], child


def finish(spec):
    """Mark the workbench job finished and remove the transient configs
    (the node that ran it removes them when it ran on an SSH executor)."""
    from scripts.eval.harbor.bench import data
    from scripts.eval.harbor.bench.runner import atomic_json, now
    for path in config_paths(spec) if "checkout" in spec["workbuddy"] else ():
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    result = Path(spec["jobs_dir"]) / spec["name"] / "result.json"
    value = data.read_json(result)
    if isinstance(value, dict) and not value.get("finished_at"):
        atomic_json(result, {**value, "finished_at": now()})


# environment_preflight.DEFAULT_HARNESS_IMAGE: the split-mount image every
# WorkBuddy trial mounts, built from HARNESS_CONTEXT. run.sh reuses the tag
# whenever it exists, whatever was staged since.
HARNESS_IMAGE = "workbuddy-bench/harness/metacodes:0.1.0"
HARNESS_CONTEXT = Path("configs/harnesses/metacodes/docker")
HARNESS_VERSIONS = Path("configs/harnesses/metacodes/versions")
# Each executable stage_artifacts stages, by the bundle path it comes from.
BUNDLE_EXECUTABLES = {"metacodes": "bin/metacodes", "tinykg": "vendor/tinykg/tinykg",
                      "metacodes-formal-kernel": "libexec/metacodes/metacodes-formal-kernel",
                      "ripgrep": "bin/rg", "metacodes-project-kernel": "libexec/metacodes/metacodes-project-kernel"}
# The adapter installs bin/rg beside bin/metacodes in every trial.
REQUIRED_EXECUTABLES = ("metacodes", "tinykg", "metacodes-formal-kernel", "ripgrep")


def staged_executables(ctx) -> Optional[Dict[str, str]]:
    """{label: sha256} of the executables staged in the checkout (the
    artifact manifest's), or None when nothing is staged."""
    repo = checkout(ctx)
    return manifest_executables(_json(repo / ARTIFACT_MANIFEST) if repo is not None else None)


def manifest_executables(manifest) -> Optional[Dict[str, str]]:
    """{label: sha256} of an artifact manifest's executables."""
    if not isinstance(manifest, dict):
        return None
    rows = dict(manifest.get("executables") or {})
    kernel = (manifest.get("project_control") or {}).get("kernel")
    if kernel:
        rows["metacodes-project-kernel"] = kernel
    return {label: row["sha256"] for label, row in rows.items()
            if isinstance(row, dict) and isinstance(row.get("sha256"), str)}


def bundle_executables(bundle) -> Dict[str, str]:
    """{label: sha256} of the same executables in a Linux bundle."""
    import hashlib
    result = {}
    for label, relative in BUNDLE_EXECUTABLES.items():
        path = Path(bundle) / relative
        if path.is_file():
            result[label] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def executable_mismatch(staged: Optional[Dict[str, str]], expected: Dict[str, str]) -> List[str]:
    """Labels whose staged executable is not the expected bundle's (every
    staged one, and the ones every run uses)."""
    staged = staged or {}
    return sorted(label for label in set(staged) | set(REQUIRED_EXECUTABLES)
                  if staged.get(label) is None or staged.get(label) != expected.get(label))


RUN_IMAGE_REPOSITORY = "wbm"


def run_image_tag(name: str) -> str:
    """The mount image tag of one run: no other run builds or moves it."""
    import hashlib
    return RUN_IMAGE_REPOSITORY + ":" + hashlib.sha256(name.encode("utf-8")).hexdigest()[:12]


def build_harness_image(repo: Path, tag: str, stop, expected: Optional[Dict[str, str]] = None,
                        docker: str = "docker") -> bool:
    """Build the mount image from the checkout's staged context as `tag`.
    The manifest read once here is the one checked against `expected` (the
    run's bundle) and compared after the build. False when `stop` was set
    meanwhile (the build is killed). Raises ValueError when the staged
    executables are not the expected ones, the build fails, or the staged
    artifacts changed while it ran."""
    import signal
    import subprocess
    import tempfile
    import time
    from scripts.eval.harbor.bench.executors import signal_group
    manifest = repo / ARTIFACT_MANIFEST
    before = manifest.read_bytes()
    if expected is not None:
        try:
            staged = manifest_executables(json.loads(before))
        except ValueError:
            staged = None
        different = executable_mismatch(staged, expected)
        if different:
            raise ValueError("WorkBuddy 暂存的制品不是本次运行的 metacodes 版本：" + "、".join(different))
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen([docker, "buildx", "build", "--platform", TARGET_PLATFORM, "--load", "--tag", tag,
                                    str(repo / HARNESS_CONTEXT)], cwd=str(repo), stdin=subprocess.DEVNULL,
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 3600
        while process.poll() is None:
            if stop.is_set() or time.monotonic() > deadline:
                signal_group(process, signal.SIGKILL)
                process.wait()
                if stop.is_set():
                    return False
                raise ValueError("构建 WorkBuddy 挂载镜像超时（1 小时）")
            time.sleep(0.25)
        if process.returncode != 0:
            output.seek(0)
            raise ValueError("构建 WorkBuddy 挂载镜像失败：" + output.read().decode(errors="replace").strip()[-300:])
    if manifest.read_bytes() != before:
        raise ValueError("构建 WorkBuddy 挂载镜像时暂存制品发生了变化，请重试")
    return True


def spec_fields(suite, ctx) -> dict:
    return {"checkout": str(checkout(ctx).resolve()), "subset": suite.subset,
            "uv": shutil.which("uv"), "bash": shutil.which("bash")}
