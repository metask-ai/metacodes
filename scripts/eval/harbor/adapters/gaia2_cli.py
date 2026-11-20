"""GAIA2 in Harbor's CLI mode (`gaia2-cli`), generated on the workbench.

GAIA2 is in neither Harbor 0.26 registry (the legacy registry nor the Hub;
the only GAIA there is GAIA 1). Harbor's own adapter
(`adapters/gaia2/run_adapter.py --cli` in the Harbor source tree, tag
v0.26.0) writes one task directory per scenario, `gaia2-<config>-<row>-<id>`,
from the public Hugging Face dataset `meta-agents-research-environments/gaia2`
(five configs, 160 validation scenarios each). Each CLI-mode task runs the
agent in `main` and the ARE environment in an `are-sidecar` container that
serves the scenario's tools over MCP; the task declares that server in
`[[environment.mcp_servers]]`, and MetacodesAgent forwards it to metacodes'
`mcpServers` configuration.

`prepare` needs no manual steps: unless `METACODES_BENCH_HARBOR_SOURCE` names
a Harbor checkout, it fetches Harbor at the pinned commit into
`<state>/bench/sources/harbor-<commit>` (a shallow fetch of exactly that
commit, HEAD verified, reused afterwards) and runs the adapter there with the
workbench's `uv` (`--no-dev --extra huggingface`; `--frozen` unless the
workbench's `pypi_index` mirror is set, then UV_DEFAULT_INDEX). The dataset
revision is pinned too. `workbench.json` `prepare.gaia2-cli` may narrow the
set: `{"configs": ["search", ...], "limit": N}` (the adapter's `--configs`
and `--limit`); the default is the full 800 (about 2.1 GB: 2.5-2.7 MB per
task, mostly its scenario.json; an SSH executor receives the whole prepared
set once per content digest). A finished dataset is recorded in a marker and
not regenerated while its options and task trees match.

The verifier is an LLM judge (Harbor's `tests/llm_judge.py`, OpenAI Chat
Completions via the `openai` SDK). In Metask authentication the workbench
routes it through the run's credential relay (`JUDGE`): the task container
gets the relay route, a judge-only placeholder token, the model id and a CA
bundle path; the relay forwards to the Metask gateway with the real,
refreshing credential. The model is `judges.gaia2-cli.model` in
`workbench.json` (default `glm-5.3-flash`), so scores are not directly
comparable with Harbor's published numbers (judge `openai/gpt-4o-mini`). In
provider authentication the judge keeps reading the execution host's
`OPENAI_API_KEY` / `OPENAI_BASE_URL` / `JUDGE_MODEL` (HOST_ENV).
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Dict, List, Optional

from scripts.eval.harbor.adapters import _common as c

SUITE_ID = "gaia2-cli"
SOURCE_ENV = "METACODES_BENCH_HARBOR_SOURCE"
HARBOR_REPO = "https://github.com/harbor-framework/harbor.git"
HARBOR_TAG = "v0.26.0"
HARBOR_COMMIT = "3cb627394b95d3ae605f31e0d694edf508cf4b7b"
HF_DATASET = "meta-agents-research-environments/gaia2"
# The dataset revision the task ids below were generated from (2026-11-18).
HF_REVISION = "78ea3bdbdeec2bdcd6afa5420915d8a22f23ed99"
CONFIGS = ("execution", "search", "adaptability", "time", "ambiguity")
ADAPTER = ("adapters", "gaia2", "run_adapter.py")
ADAPTER_TIMEOUT = 3 * 3600
GIT_TIMEOUT = 600

JUDGE_KEY_ENV = "OPENAI_API_KEY"
# Provider authentication: the verifier's judge reads these on the execution
# host; an SSH executor receives them over the run's SSH stdin.
HOST_ENV = (JUDGE_KEY_ENV, "OPENAI_BASE_URL", "JUDGE_MODEL")
# Metask authentication: the judge goes through the run's credential relay.
JUDGE = {
    "default_model": "glm-5.3-flash",
    "upstream_default": "openai/gpt-4o-mini",   # Harbor's task.toml default
    "env": {"api_key": JUDGE_KEY_ENV, "base_url": "OPENAI_BASE_URL", "model": "JUDGE_MODEL",
            "ca_file": "SSL_CERT_FILE"},
}

SUITE = {
    "name": "GAIA2（CLI 模式）",
    "description": "Meta GAIA2 的 Harbor CLI 变体：800 个动态场景，agent 通过 MCP 侧车调用 ARE 环境工具；判分使用 LLM judge（Metask 登录时默认 glm-5.3-flash）",
    "max_tasks": 100,
    "max_concurrency": 2,
    # A small sample: the first scenario of each config (validation split
    # at HF_REVISION, as generated with Harbor at HARBOR_COMMIT). The page
    # and `bench run` offer only those present in the prepared dataset.
    "default_tasks": [
        "gaia2-execution-0052-snsq4rd73gytoo0wr75bgd2nyzra07z1",
        "gaia2-search-0002-46myz87t501b0c902dy81rlbqbye2dyi",
        "gaia2-adaptability-0601-mz4dh4tml93gims9dxwrcz7i16t0p5ud",
        "gaia2-time-0710-e2cjolirnhypj7tgr44nl3woxkfrgtu2",
        "gaia2-ambiguity-0132-4hy9gimaap8287dl6so87nfx59ivjykp",
    ],
}


def adapter_command(source: Path, dest: Path, uv: str = "uv", *, configs=None, limit=None,
                    mirror: bool = False) -> List[str]:
    """The Harbor adapter invocation; argv only, no shell."""
    argv = [uv, "run"] + ([] if mirror else ["--frozen"]) + [
        "--no-dev", "--extra", "huggingface", "--project", str(source), "python",
        str(source.joinpath(*ADAPTER)), "--cli", "--output-dir", str(dest), "--overwrite",
        "--revision", HF_REVISION]
    if configs:
        argv += ["--configs", *configs]
    if limit:
        argv += ["--limit", str(limit)]
    return argv


# ---------------------------------------------------------------- options


def options(cfg) -> Dict:
    """`prepare.gaia2-cli` of workbench.json, validated: configs and limit."""
    entry = ((cfg or {}).get("prepare") or {}).get(SUITE_ID) or {}
    if not isinstance(entry, dict) or set(entry) - {"configs", "limit"}:
        raise ValueError("workbench.json 的 prepare.gaia2-cli 只接受 configs 和 limit")
    configs = entry.get("configs")
    if configs is not None:
        if not isinstance(configs, list) or not configs or len(set(configs)) != len(configs) \
                or any(c not in CONFIGS for c in configs):
            raise ValueError("prepare.gaia2-cli.configs 必须是 " + "、".join(CONFIGS) + " 中不重复的若干项")
        configs = [c for c in CONFIGS if c in configs]
    limit = entry.get("limit")
    if limit is not None and not (type(limit) is int and 1 <= limit <= 800):
        raise ValueError("prepare.gaia2-cli.limit 必须是 1–800 的整数")
    return {"configs": configs, "limit": limit}


def pypi_index(cfg) -> Optional[str]:
    from scripts.eval.harbor.bench.executors import MIRROR_URL
    value = (cfg or {}).get("pypi_index")
    if value is None:
        return None
    if not isinstance(value, str) or not MIRROR_URL.fullmatch(value):
        raise ValueError("workbench.json 的 pypi_index 必须是 http(s) 地址")
    return value


def tool(name: str) -> Optional[str]:
    from scripts.eval.harbor.bench.executors import search_path
    return shutil.which(name, path=search_path())


def hf_endpoint() -> str:
    return (os.environ.get("HF_ENDPOINT") or "https://huggingface.co").rstrip("/")


def hf_reachable(timeout: float = 10) -> Optional[str]:
    """None when the pinned dataset revision answers, else why not."""
    url = f"{hf_endpoint()}/api/datasets/{HF_DATASET}/revision/{HF_REVISION}"
    request = urllib.request.Request(url, headers={"User-Agent": c.USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            response.read(1)
        return None
    except urllib.error.HTTPError as exc:
        exc.close()
        return f"Hugging Face 返回 HTTP {exc.code}（{url}）"
    except (OSError, ValueError) as exc:
        return f"无法连接 Hugging Face（{hf_endpoint()}）：{getattr(exc, 'reason', exc)}"


# Readiness runs on every catalog read: the network probe is cached.
_PROBE = {"at": 0.0, "value": None}
PROBE_TTL = 300


def cached_hf_problem() -> Optional[str]:
    if time.monotonic() - _PROBE["at"] > PROBE_TTL:
        _PROBE.update(at=time.monotonic(), value=hf_reachable(timeout=3))
    return _PROBE["value"]


# ----------------------------------------------------------------- source


def stderr_log(text):
    print(text, file=sys.stderr, flush=True)


def harbor_source(root: Path, log=stderr_log) -> Path:
    """The Harbor checkout the adapter runs from: METACODES_BENCH_HARBOR_SOURCE,
    else `<root>/sources/harbor-<commit>`, fetched once at the pinned commit."""
    configured = os.environ.get(SOURCE_ENV)
    if configured:
        source = Path(configured).expanduser().resolve()
        if not source.joinpath(*ADAPTER).is_file():
            raise ValueError(f"{SOURCE_ENV}={configured} 不是 Harbor 源码目录（缺少 adapters/gaia2/run_adapter.py）")
        return source
    final = Path(root) / "sources" / ("harbor-" + HARBOR_COMMIT)
    git = tool("git")
    if not git:
        raise ValueError("生成 GAIA2 需要 git（拉取 Harbor " + HARBOR_TAG + " 源码），请安装后重试")
    if final.joinpath(*ADAPTER).is_file() and head(git, final) == HARBOR_COMMIT:
        log(f"复用 Harbor 源码 {final}")
        return final
    final.parent.mkdir(parents=True, exist_ok=True)
    work = final.parent / (final.name + ".tmp-" + uuid.uuid4().hex[:8])
    log(f"拉取 Harbor {HARBOR_TAG}（{HARBOR_COMMIT[:12]}）到 {final}")
    try:
        for argv in ([git, "init", "-q", str(work)],
                     [git, "-C", str(work), "fetch", "-q", "--depth", "1", HARBOR_REPO, HARBOR_COMMIT],
                     [git, "-C", str(work), "-c", "advice.detachedHead=false", "checkout", "-q", "FETCH_HEAD"]):
            done = run(argv, timeout=GIT_TIMEOUT)
            if done.returncode != 0:
                raise ValueError("拉取 Harbor 源码失败（" + " ".join(argv[1:4]) + "）："
                                 + (done.stderr or done.stdout or "").strip()[-300:])
        found = head(git, work)
        if found != HARBOR_COMMIT:
            raise ValueError(f"拉取的 Harbor 源码版本不符：HEAD {found or '未知'}，应为 {HARBOR_COMMIT}")
        if not work.joinpath(*ADAPTER).is_file():
            raise ValueError("拉取的 Harbor 源码缺少 adapters/gaia2/run_adapter.py")
        shutil.rmtree(final, ignore_errors=True)
        work.replace(final)
        return final
    finally:
        shutil.rmtree(work, ignore_errors=True)


def head(git: str, checkout: Path) -> Optional[str]:
    done = run([git, "-C", str(checkout), "rev-parse", "HEAD"], timeout=60)
    return done.stdout.strip() if done.returncode == 0 else None


def run(argv, timeout, env=None, cwd=None):
    try:
        return subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=timeout, env=env, cwd=cwd)
    except subprocess.TimeoutExpired:
        raise ValueError(f"{Path(argv[0]).name} 超时（{timeout} 秒）") from None
    except OSError as exc:
        raise ValueError(f"无法运行 {argv[0]}：{exc}") from None


# ---------------------------------------------------------------- prepare


def prepare(dest: Path, ctx=None, log=stderr_log) -> Path:
    """Generate the GAIA2 CLI tasks into `dest` (idempotent, see module doc).

    `ctx` is the workbench's suites.Context (its cfg and bench state root);
    without one the root is dest's grandparent (`<root>/datasets/<suite>`)."""
    dest = Path(dest)
    cfg = ctx.cfg if ctx is not None else {}
    root = Path(ctx.root) if ctx is not None else dest.resolve().parent.parent
    chosen = options(cfg)
    mirror = pypi_index(cfg)
    configured = os.environ.get(SOURCE_ENV)
    fingerprint = c.fingerprint_of(SUITE_ID, "harbor-adapter", HARBOR_COMMIT if not configured else
                                   "source:" + str(Path(configured).expanduser().resolve()),
                                   HF_DATASET, HF_REVISION, chosen)
    if c.dataset_complete(dest, SUITE_ID, fingerprint):
        log(f"GAIA2 数据集已是最新：{dest}")
        return dest
    uv = tool("uv")
    if not uv:
        raise ValueError("生成 GAIA2 需要 uv（metacodes bench setup 会安装），请安装后重试")
    problem = hf_reachable()
    if problem:
        raise ValueError("生成 GAIA2 需要访问 Hugging Face 公开数据集 " + HF_DATASET + "：" + problem
                         + "；可设置 HF_ENDPOINT 指向镜像")
    source = harbor_source(root, log=log)

    def fetch_sources(_cache):
        return {}

    def build(_inputs, scratch):
        env = dict(os.environ)
        if mirror:
            env["UV_DEFAULT_INDEX"] = mirror
        argv = adapter_command(source, Path(scratch).resolve(), uv, mirror=bool(mirror), **chosen)
        log("$ " + " ".join(argv))
        started = time.monotonic()
        try:
            # The adapter's progress goes to this process's stderr (copied
            # afterwards when stderr is no real file).
            try:
                sink = sys.stderr.fileno()
            except (AttributeError, OSError, ValueError):
                sink = None
            done = subprocess.run(argv, stdin=subprocess.DEVNULL, timeout=ADAPTER_TIMEOUT, env=env, cwd=str(source),
                                  **({"stdout": sink, "stderr": sink} if sink is not None else
                                     {"capture_output": True, "text": True}))
            if sink is None:
                sys.stderr.write((done.stdout or "") + (done.stderr or ""))
        except subprocess.TimeoutExpired:
            raise ValueError(f"GAIA2 适配器超时（{ADAPTER_TIMEOUT} 秒）") from None
        except OSError as exc:
            raise ValueError(f"无法运行 uv：{exc}") from None
        if done.returncode != 0:
            raise ValueError(f"GAIA2 适配器失败（退出码 {done.returncode}），输出见上方")
        log(f"GAIA2 适配器完成：{len(c.task_ids(Path(scratch)))} 道任务，{time.monotonic() - started:.0f} 秒")

    return c.prepare_dataset(dest, suite_id=SUITE_ID, fingerprint=fingerprint, fetch_sources=fetch_sources,
                             build=build, provenance={"harbor": HARBOR_COMMIT if not configured else "custom",
                                                      "dataset": HF_DATASET, "revision": HF_REVISION, **chosen})


def check(ctx):
    """What keeps GAIA2 from launching here, beyond a missing dataset."""
    reasons = []
    try:
        options(ctx.cfg)
        pypi_index(ctx.cfg)
    except ValueError as exc:
        reasons.append(str(exc))
    from scripts.eval.harbor import suites
    if not c.task_ids(ctx.dataset_dir(suites.get(SUITE_ID))):
        # Not prepared yet: say what `bench prepare --suite gaia2-cli` needs.
        missing = [name for name in ("uv",) + (() if os.environ.get(SOURCE_ENV) else ("git",)) if not tool(name)]
        if missing:
            reasons.append("准备 GAIA2 数据集需要 " + "、".join(missing) + "（metacodes bench setup 安装 uv；git 请用系统包管理器安装）")
        problem = cached_hf_problem()
        if problem:
            reasons.append("准备 GAIA2 数据集需要访问 Hugging Face：" + problem + "（可设置 HF_ENDPOINT 指向镜像）")
    if ctx.auth_mode() == "provider" and not ctx.env.get(JUDGE_KEY_ENV):
        reasons.append(f"第三方 Provider 模式下 GAIA2 判分使用执行服务环境变量 {JUDGE_KEY_ENV}"
                       "（OPENAI_BASE_URL 默认 OpenRouter，JUDGE_MODEL 默认 openai/gpt-4o-mini），设置后重启服务")
    return reasons
