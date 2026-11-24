"""Benchmark catalog of the Bench workbench: which suites exist and how they run.

Every suite has an id, a category, a Chinese name and description, and one
runner kind:

- ``harbor-registry``: a Harbor 0.26 registry dataset (``harbor run -d REF``).
  Task ids are fixed in this module or in ``registry_tasks.json`` and were
  taken from the registry itself; ``filter_prefix`` turns an id into the
  ``-i`` pattern Harbor matches (Hub datasets name tasks ``org/name``,
  legacy-registry ones the bare name). ``host_env`` names execution-host
  variables the dataset's task.toml reads (τ³-bench's user simulator key),
  forwarded like an adapter's HOST_ENV; ``required_env`` must be set.
- ``harbor-local``: a Harbor dataset directory generated on the execution
  machine by an adapter's ``prepare()`` (``harbor run -p DIR``). Its task ids
  are the task directory names found there, read at runtime.
- ``workbuddy``: the pinned WorkBuddy-Bench integration
  (scripts/eval/workbuddy, launched by ``suites.workbuddy``).

The launch API accepts a suite id plus explicit task ids. Every id must belong
to that suite, so nothing a browser sends can widen what Harbor runs.

Adapter interface (``harbor-local`` suites)
-------------------------------------------

An adapter is the module ``scripts/eval/harbor/adapters/<name>.py``, named in
``ADAPTER_SUITES`` below (one entry per suite id; the entry's id and category
are authoritative). Add the file to ``scripts/bench_assets.zig`` so the binary
carries it. The module exposes::

    SUITE = {                      # optional refinements of the catalog entry
        "name": "HumanEval",       # display name
        "description": "...",      # Chinese one-line description
        "default_tasks": [...],    # suggested sample (ids that exist)
        "max_tasks": 164,          # per-launch cap (<= MAX_TASKS)
        "max_concurrency": 4,      # optional per-suite cap
    }

    def prepare(dest: Path) -> Path:      # or prepare(dest, ctx): the
        '''Write Harbor task directories   # Context (cfg, bench root)
        (<dest>/<task-id>/task.toml, ...) and return the dataset directory
        (normally ``dest``).'''

    # optional
    def check(ctx) -> list[str]:   # extra readiness reasons (Chinese), [] if ready;
                                   # ctx.cfg / ctx.env / ctx.dataset_dir(suite)
    HOST_ENV = ("NAME", ...)       # execution-host environment the task's
                                   # verifier reads (e.g. a judge key); an SSH
                                   # executor receives these values over the
                                   # run's SSH stdin, never argv or a file
    def tasks(dataset: Path) -> list[str]:   # default: sorted dirs with task.toml
    JUDGE = {                      # an OpenAI-compatible LLM judge in the
        "default_model": "...",    # verifier; in Metask authentication it is
        "env": {"api_key": "OPENAI_API_KEY", "base_url": "OPENAI_BASE_URL",
                "model": "JUDGE_MODEL", "ca_file": "SSL_CERT_FILE"},
    }                              # routed through the run's relay (judge())

Task ids must match ``TASK`` (no glob characters: Harbor's ``-i`` is an
fnmatch pattern). ``metacodes bench prepare --suite <id>`` runs ``prepare``
on the execution machine with ``dest = <state root>/bench/datasets/<suite id>``;
``metacodes bench --dataset <suite id>=<dir>`` registers an existing
directory instead. Until the module exists the suite is listed as not yet
available, with that reason.
"""
from __future__ import annotations

import importlib
import json
import os
import re
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

HARBOR_REGISTRY = "harbor-registry"
HARBOR_LOCAL = "harbor-local"
WORKBUDDY = "workbuddy"
RUNNERS = (HARBOR_REGISTRY, HARBOR_LOCAL, WORKBUDDY)

TASK = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,254}$")
ENV_NAME = re.compile(r"^[A-Z][A-Z0-9_]*$")
MAX_TASKS = 500
DEFAULT_SUITE = "terminal-bench-2.1"

# Ordered as the picker shows them.
CATEGORIES = (
    ("software-engineering", "软件工程", "修复真实开源仓库的 issue，用仓库测试验收"),
    ("code-generation", "代码生成", "根据描述写出函数，通过单元测试"),
    ("basic-programming", "基础编程", "Python 基础编程任务"),
    ("interactive-planning", "交互规划", "多步骤家庭任务的规划与执行"),
    ("question-answering", "问答", "根据检索到的段落回答问题"),
    ("math-reasoning", "数学推理", "数学问题求解"),
    ("competition-math", "竞赛数学", "AIME 竞赛题，答案为整数"),
    ("terminal", "终端工程", "在容器终端里完成真实工程任务"),
    ("general-agent", "通用 Agent", "动态环境中的工具使用与任务执行"),
    ("customer-service", "客服对话", "按业务政策与模拟用户多轮对话并调用工具办理业务"),
    ("work-agent", "办公 Agent", "WorkBuddy 工作场景任务：代码、网页、办公文档、安全"),
)
CATEGORY_IDS = tuple(c[0] for c in CATEGORIES)

# Terminal-Bench 2.0 (legacy registry `terminal-bench@2.0`, laude-institute/
# terminal-bench-2 @ 69671fba) and 2.1 (Hub `terminal-bench/terminal-bench-2-1`,
# revision 6) carry the same 89 task names; 2.1 updates their contents.
TERMINAL_BENCH_2 = (
    'adaptive-rejection-sampler', 'bn-fit-modify', 'break-filter-js-from-html',
    'build-cython-ext', 'build-pmars', 'build-pov-ray', 'caffe-cifar-10', 'cancel-async-tasks',
    'chess-best-move', 'circuit-fibsqrt', 'cobol-modernization', 'code-from-image',
    'compile-compcert', 'configure-git-webserver', 'constraints-scheduling',
    'count-dataset-tokens', 'crack-7z-hash', 'custom-memory-heap-crash', 'db-wal-recovery',
    'distribution-search', 'dna-assembly', 'dna-insert', 'extract-elf',
    'extract-moves-from-video', 'feal-differential-cryptanalysis', 'feal-linear-cryptanalysis',
    'filter-js-from-html', 'financial-document-processor', 'fix-code-vulnerability', 'fix-git',
    'fix-ocaml-gc', 'gcode-to-text', 'git-leak-recovery', 'git-multibranch', 'gpt2-codegolf',
    'headless-terminal', 'hf-model-inference', 'install-windows-3.11', 'kv-store-grpc',
    'large-scale-text-editing', 'largest-eigenval', 'llm-inference-batching-scheduler',
    'log-summary-date-ranges', 'mailman', 'make-doom-for-mips', 'make-mips-interpreter',
    'mcmc-sampling-stan', 'merge-diff-arc-agi-task', 'model-extraction-relu-logits',
    'modernize-scientific-stack', 'mteb-leaderboard', 'mteb-retrieve', 'multi-source-data-merger',
    'nginx-request-logging', 'openssl-selfsigned-cert', 'overfull-hbox', 'password-recovery',
    'path-tracing', 'path-tracing-reverse', 'polyglot-c-py', 'polyglot-rust-c',
    'portfolio-optimization', 'protein-assembly', 'prove-plus-comm', 'pypi-server',
    'pytorch-model-cli', 'pytorch-model-recovery', 'qemu-alpine-ssh', 'qemu-startup',
    'query-optimize', 'raman-fitting', 'regex-chess', 'regex-log', 'reshard-c4-data',
    'rstan-to-pystan', 'sam-cell-seg', 'sanitize-git-repo', 'schemelike-metacircular-eval',
    'sparql-university', 'sqlite-db-truncate', 'sqlite-with-gcov', 'torch-pipeline-parallelism',
    'torch-tensor-parallelism', 'train-fasttext', 'tune-mjcf', 'video-processing',
    'vulnerable-secret', 'winning-avg-corewars', 'write-compressor',
)
TERMINAL_BENCH_SAMPLE = (
    "kv-store-grpc", "pypi-server", "fix-git", "git-multibranch", "log-summary-date-ranges",
    "cancel-async-tasks", "largest-eigenval", "write-compressor", "schemelike-metacircular-eval",
    "torch-tensor-parallelism",
)

# FrontierHarness Eval v1.1 (Hub `frontier-harness-eval/frontier-harness-eval@v1.1.0`,
# frontier-harness-eval/eval release/v1.1 datasets/dataset.toml): 62 pinned tasks,
# all named `terminal-bench/<name>`.
FRONTIER_HARNESS_EVAL_1_1 = (
    'mvcc-lsm-compaction', 'bun-sourcemap-leak', 'wal-recovery-ordering',
    'session-window-debug', 'ontology-kg-querying', 'roy-polymorph-cn', 'gsea-proteomics',
    'foodstuff-beta-activity', 'glycan-ms2-elucidation', 'embedding-drift-monitor',
    'batched-eval-parity', 'vpp-loss-divergence', 'cargo-flight-dispatch', 'intrastat-meldung',
    'freecad-impeller', 'html-js-filter', 'music-harmony', 'log-summary-date-ranges',
    'regex-log', 'sparql-university', 'hf-model-inference', 'mteb-leaderboard',
    'rstan-to-pystan', 'sam-cell-seg', 'merge-diff-arc-agi-task', 'sqlite-db-truncate',
    'gcode-to-text', 'large-scale-text-editing', 'chess-best-move', 'caffe-cifar-10',
    'feal-linear-cryptanalysis', 'model-extraction-relu-logits', 'pytorch-model-cli',
    'pytorch-model-recovery', 'portfolio-optimization', 'constraints-scheduling',
    'adaptive-rejection-sampler', 'dna-assembly', 'dna-insert', 'tune-mjcf',
    'filter-js-from-html', 'fix-code-vulnerability', 'openssl-selfsigned-cert',
    'vulnerable-secret', 'cancel-async-tasks', 'circuit-fibsqrt', 'code-from-image', 'fix-git',
    'fix-ocaml-gc', 'kv-store-grpc', 'make-doom-for-mips', 'path-tracing-reverse',
    'polyglot-c-py', 'polyglot-rust-c', 'prove-plus-comm', 'pypi-server',
    'schemelike-metacircular-eval', 'install-windows-3.11', 'mailman', 'nginx-request-logging',
    'sqlite-with-gcov', 'video-processing',
)
FRONTIER_HARNESS_EVAL_SAMPLE = (
    "fix-git", "regex-log", "log-summary-date-ranges", "cancel-async-tasks", "kv-store-grpc",
    "pypi-server", "sqlite-db-truncate", "wal-recovery-ordering", "session-window-debug",
    "html-js-filter",
)

# Hub datasets with hundreds of tasks, listed in registry_tasks.json by the
# pinned reference (task names without the org prefix).
REGISTRY_TASKS = json.loads(Path(__file__).with_name("registry_tasks.json").read_text(encoding="utf-8"))

# SWE-bench Verified (Hub `swe-bench/swe-bench-verified`, revision 2): the 500
# human-validated SWE-bench instances, named `<owner>__<repo>-<number>`.
SWE_BENCH_VERIFIED_REF = "swe-bench/swe-bench-verified@2"
SWE_BENCH_VERIFIED = tuple(REGISTRY_TASKS[SWE_BENCH_VERIFIED_REF]["tasks"])
SWE_BENCH_VERIFIED_SAMPLE = (
    "astropy__astropy-12907", "django__django-11099", "django__django-11133", "matplotlib__matplotlib-23314",
    "psf__requests-2317", "pytest-dev__pytest-10051", "scikit-learn__scikit-learn-13142",
    "sphinx-doc__sphinx-8721", "sympy__sympy-20590", "pydata__xarray-4094",
)

# τ³-bench (Hub `sierra-research/tau3-bench`, revision 1): 375 customer-service
# tasks in four domains, named `tau3-bench__tau3-<domain>-...`. taubench.com
# scores each domain separately, so each domain is its own suite.
TAU3_BENCH_REF = "sierra-research/tau3-bench@1"
TAU3_DOMAINS = ("airline", "retail", "telecom", "banking_knowledge")


def tau3_tasks(domain: str) -> Tuple[str, ...]:
    return tuple(t for t in REGISTRY_TASKS[TAU3_BENCH_REF]["tasks"]
                 if t.startswith(f"tau3-bench__tau3-{domain}-"))


# The task.toml reads these on the execution host: the user simulator (and the
# banking verifier's NL assertions) call an OpenAI-compatible model.
TAU3_REQUIRED_ENV = ("OPENAI_API_KEY",)
TAU3_HOST_ENV = ("OPENAI_BASE_URL", "TAU2_USER_MODEL", "TAU2_USER_REASONING_EFFORT", "TAU2_NL_ASSERTIONS_MODEL")

# Legacy registry `aime@1.0` (harbor-datasets @ 414014c2). Harbor's AIME adapter
# reads GAIR-NLP/AIME-Preview: test2024 ids 60-89, test2025-I I-1..I-15 and
# test2025-II II-1..II-15, named aime_<id lowercased>.
AIME_2024 = tuple(f"aime_{n}" for n in range(60, 90))
AIME_2025 = tuple(f"aime_i-{n}" for n in range(1, 16)) + tuple(f"aime_ii-{n}" for n in range(1, 16))


@dataclass(frozen=True)
class Suite:
    id: str
    category: str
    name: str
    description: str
    runner: str
    # harbor-registry: `-d` reference and the -i prefix of a task id.
    dataset: str = ""
    filter_prefix: str = ""
    tasks: Optional[Tuple[str, ...]] = None      # None: listed at runtime
    default_tasks: Tuple[str, ...] = ()
    max_tasks: int = 20
    max_concurrency: Optional[int] = None      # None: no cap
    # harbor-local: adapter module under scripts.eval.harbor.adapters.
    adapter: str = ""
    # workbuddy: dataset subset (code/web/office/sec).
    subset: str = ""
    notes: Tuple[str, ...] = field(default_factory=tuple)
    # harbor-local: container architectures the adapter's tasks support
    # (SUITE["arch"]), shown on the page; ALFWorld's sidecar is amd64 only.
    arch: str = ""
    # harbor-registry: execution-host variables the tasks read.
    required_env: Tuple[str, ...] = ()
    host_env: Tuple[str, ...] = ()


def tau3_suite(domain: str, name: str, description: str) -> Suite:
    tasks = tau3_tasks(domain)
    return Suite("tau3-" + domain.replace("_", "-"), "customer-service", name, description,
                 HARBOR_REGISTRY, dataset=TAU3_BENCH_REF, filter_prefix="sierra-research/",
                 tasks=tasks, default_tasks=tasks[:5], max_tasks=len(tasks),
                 required_env=TAU3_REQUIRED_ENV, host_env=TAU3_HOST_ENV)


SUITES: Tuple[Suite, ...] = (
    Suite("swe-bench-verified", "software-engineering", "SWE-bench Verified",
          "500 个真实 GitHub issue（Django、SymPy 等 12 个 Python 仓库，人工确认可解）：在仓库里改代码修复问题，"
          "原本失败的测试转为通过、其余测试不回归才算解决",
          HARBOR_REGISTRY, dataset=SWE_BENCH_VERIFIED_REF, filter_prefix="swe-bench/",
          tasks=SWE_BENCH_VERIFIED, default_tasks=SWE_BENCH_VERIFIED_SAMPLE, max_tasks=500),
    Suite("terminal-bench-2.1", "terminal", "Terminal-Bench 2.1",
          "89 道终端工程任务（编译、调试、运维、数据、ML、安全等），每题独立容器运行，任务自带测试脚本判定是否完成；"
          "2.1 版修订了部分题目内容",
          HARBOR_REGISTRY, dataset="terminal-bench/terminal-bench-2-1",
          filter_prefix="terminal-bench/", tasks=TERMINAL_BENCH_2,
          default_tasks=TERMINAL_BENCH_SAMPLE, max_tasks=89),
    Suite("terminal-bench-2.0", "terminal", "Terminal-Bench 2.0",
          "Terminal-Bench 2.0 原版 89 题（题名与 2.1 相同、内容未修订），测试脚本判分；用于和 tbench.ai 2.0 公开榜单对齐",
          HARBOR_REGISTRY, dataset="terminal-bench@2.0", tasks=TERMINAL_BENCH_2,
          default_tasks=TERMINAL_BENCH_SAMPLE, max_tasks=89),
    Suite("frontier-harness-eval-1.1", "terminal", "FrontierHarness Eval v1.1",
          "FrontierHarness 榜单的 62 道固定版本命令行任务（45 道 TB2.1 衍生 + 17 道新题，覆盖工程、科学、数据、系统、ML、安全），"
          "每题独立容器运行，测试脚本判分；用于比较不同 harness",
          HARBOR_REGISTRY, dataset="frontier-harness-eval/frontier-harness-eval@v1.1.0",
          filter_prefix="terminal-bench/", tasks=FRONTIER_HARNESS_EVAL_1_1,
          default_tasks=FRONTIER_HARNESS_EVAL_SAMPLE, max_tasks=62),
    Suite("aime", "competition-math", "AIME 2024–2025",
          "60 道 AIME 数学竞赛题（2024 年 30 道，2025 年 I/II 卷各 15 道），答案是 0–999 的整数，与标准答案精确比对判分",
          HARBOR_REGISTRY, dataset="aime@1.0", tasks=AIME_2024 + AIME_2025,
          default_tasks=AIME_2024 + AIME_2025, max_tasks=60),
    Suite("aime-2025", "competition-math", "AIME 2025",
          "只跑 AIME 2025 年 I/II 卷 30 题（与 aime 同一数据集），整数答案精确比对；对应 Vals.ai、MathArena 的 2025 榜单",
          HARBOR_REGISTRY, dataset="aime@1.0", tasks=AIME_2025,
          default_tasks=AIME_2025, max_tasks=30),
    tau3_suite("airline", "τ³-bench Airline",
               "τ³-bench 航空客服 50 题：按航司政策与 LLM 模拟的旅客对话，用工具改签、退票、加行李；"
               "结束时数据库状态与标准答案一致才得分。用户模拟器需要 OPENAI_API_KEY"),
    tau3_suite("retail", "τ³-bench Retail",
               "τ³-bench 零售客服 114 题：按电商政策处理退货、换货、改地址等请求，与 LLM 模拟用户多轮对话；"
               "数据库终态与要求的回复信息都对才得分。用户模拟器需要 OPENAI_API_KEY"),
    tau3_suite("telecom", "τ³-bench Telecom",
               "τ³-bench 电信技术支持 114 题：指导模拟用户在自己手机上排查无服务、流量、彩信等故障（用户也要操作工具），"
               "设备与账户终态正确才得分。用户模拟器需要 OPENAI_API_KEY"),
    tau3_suite("banking_knowledge", "τ³-bench Banking Knowledge",
               "τ³-bench 银行客服 97 题：先在知识库里检索政策和产品文档，再与模拟用户对话办理业务；"
               "数据库终态与 LLM 判定的回复要点都满足才得分。用户模拟器和判分需要 OPENAI_API_KEY"),
)

# harbor-local suites. The id/category here are authoritative; the adapter
# module may refine name, description, sample and caps.
ADAPTER_SUITES: Tuple[Suite, ...] = (
    Suite("humaneval", "code-generation", "HumanEval", "根据函数描述写出实现，通过单元测试",
          HARBOR_LOCAL, adapter="humaneval", max_tasks=164),
    Suite("mbpp", "basic-programming", "MBPP", "MBPP full 测试集 500 道 Python 编程任务",
          HARBOR_LOCAL, adapter="mbpp", max_tasks=200),
    Suite("mbpp-sanitized", "basic-programming", "MBPP sanitized", "MBPP sanitized 测试集 257 道人工校对的 Python 编程任务",
          HARBOR_LOCAL, adapter="mbpp_sanitized", max_tasks=200),
    Suite("alfworld", "interactive-planning", "ALFWorld", "多步骤家庭任务的规划与执行",
          HARBOR_LOCAL, adapter="alfworld", max_tasks=134),
    Suite("searchqa", "question-answering", "SearchQA", "根据检索到的段落回答问题",
          HARBOR_LOCAL, adapter="searchqa", max_tasks=200),
    Suite("livemath", "math-reasoning", "LiveMath", "数学问题求解",
          HARBOR_LOCAL, adapter="livemath", max_tasks=200),
    Suite("gaia2-cli", "general-agent", "GAIA2（CLI 模式）",
          "Meta GAIA2 的 Harbor CLI 变体：agent 通过 MCP 侧车调用 ARE 环境的 101 个工具完成动态场景任务",
          HARBOR_LOCAL, adapter="gaia2_cli", max_tasks=100),
)

WORKBUDDY_SUITES: Tuple[Suite, ...] = (
    Suite("workbuddy-code", "work-agent", "WorkBuddy Code",
          "腾讯 WorkBuddy-Bench 代码子集 80 题：日常开发工作（写功能、修 bug、改脚本），由任务自带的 verifier 程序判分",
          WORKBUDDY, subset="code", max_tasks=80),
    Suite("workbuddy-sec", "work-agent", "WorkBuddy Security",
          "腾讯 WorkBuddy-Bench 安全子集 60 题：漏洞分析、加固、日志排查等安全工作，由 verifier 程序判分",
          WORKBUDDY, subset="sec", max_tasks=60),
    Suite("workbuddy-web", "work-agent", "WorkBuddy Web",
          "腾讯 WorkBuddy-Bench 网页子集 70 题：按需求做网页和前端页面，由 LLM judge 对照评分标准打分",
          WORKBUDDY, subset="web", max_tasks=70),
    Suite("workbuddy-office", "work-agent", "WorkBuddy Office",
          "腾讯 WorkBuddy-Bench 办公文档子集 50 题：生成或修改 Word、Excel、PPT 等文档，由 LLM judge 对照评分标准打分",
          WORKBUDDY, subset="office", max_tasks=50),
)

ALL: Tuple[Suite, ...] = SUITES + ADAPTER_SUITES + WORKBUDDY_SUITES


def _validate():
    seen = set()
    for suite in ALL:
        assert suite.id not in seen and TASK.fullmatch(suite.id), suite.id
        seen.add(suite.id)
        assert suite.category in CATEGORY_IDS and suite.runner in RUNNERS, suite.id
        assert 1 <= suite.max_tasks <= MAX_TASKS and (suite.max_concurrency is None or suite.max_concurrency >= 1), suite.id
        if suite.tasks is not None:
            assert all(TASK.fullmatch(t) for t in suite.tasks) and len(set(suite.tasks)) == len(suite.tasks), suite.id
            assert set(suite.default_tasks) <= set(suite.tasks), suite.id
        assert (suite.runner == HARBOR_REGISTRY) == bool(suite.dataset), suite.id
        assert (suite.runner == HARBOR_LOCAL) == bool(suite.adapter), suite.id
        assert (suite.runner == WORKBUDDY) == bool(suite.subset), suite.id
        assert suite.runner == HARBOR_REGISTRY or not (suite.required_env or suite.host_env), suite.id
        assert all(ENV_NAME.fullmatch(n) for n in suite.required_env + suite.host_env), suite.id


_validate()
BY_ID: Dict[str, Suite] = {s.id: s for s in ALL}


class Unavailable(ValueError):
    """The suite cannot list or run tasks on this machine; str() says why."""


class Context:
    """What readiness depends on: server settings, the bench state dir, env."""

    def __init__(self, cfg: dict, root: Path, env=None):
        self.cfg = cfg or {}
        self.root = Path(root)
        self.env = os.environ if env is None else env

    def dataset_dir(self, suite: Suite) -> Path:
        configured = (self.cfg.get("datasets") or {}).get(suite.id)
        return Path(configured) if configured else self.root / "datasets" / suite.id

    def auth_mode(self) -> str:
        return auth_mode(self.cfg)


def auth_mode(cfg) -> str:
    """The workbench's authentication: `metask` (account login) or `provider`."""
    cfg = cfg or {}
    return cfg.get("auth_mode") or ("provider" if cfg.get("provider_config") else "metask")


def get(suite_id) -> Suite:
    suite = BY_ID.get(suite_id) if isinstance(suite_id, str) else None
    if suite is None:
        raise ValueError("未知的评测集：" + str(suite_id)[:80])
    return suite


def adapter_module(suite: Suite):
    """The adapter module of a harbor-local suite, or None when absent."""
    try:
        return importlib.import_module("scripts.eval.harbor.adapters." + suite.adapter)
    except ModuleNotFoundError as exc:
        if exc.name in ("scripts.eval.harbor.adapters." + suite.adapter, "scripts.eval.harbor.adapters"):
            return None
        raise


def resolved(suite: Suite) -> Suite:
    """The suite with its adapter's SUITE refinements applied."""
    if suite.runner != HARBOR_LOCAL:
        return suite
    module = adapter_module(suite)
    meta = getattr(module, "SUITE", None) or {}
    allowed = {"name", "description", "default_tasks", "max_tasks", "max_concurrency", "arch"}
    changes = {k: v for k, v in meta.items() if k in allowed}
    if "default_tasks" in changes:
        changes["default_tasks"] = tuple(changes["default_tasks"])
    if "max_tasks" in changes and not (type(changes["max_tasks"]) is int and 1 <= changes["max_tasks"] <= MAX_TASKS):
        changes.pop("max_tasks")
    if "max_concurrency" in changes and not (type(changes["max_concurrency"]) is int and changes["max_concurrency"] >= 1):
        changes.pop("max_concurrency")
    if not isinstance(changes.get("arch", ""), str):
        changes.pop("arch")
    return replace(suite, **changes)


def capped_concurrency(suite: Suite, concurrency: int) -> int:
    return concurrency if suite.max_concurrency is None else min(concurrency, suite.max_concurrency)


def local_tasks(dataset: Path) -> List[str]:
    try:
        children = sorted(dataset.iterdir())
    except OSError:
        return []
    return [c.name for c in children
            if TASK.fullmatch(c.name) and not c.is_symlink() and (c / "task.toml").is_file()]


def task_ids(suite: Suite, ctx: Context) -> List[str]:
    """Every task id of a suite on this machine; Unavailable when unknown."""
    if suite.tasks is not None:
        return list(suite.tasks)
    if suite.runner == HARBOR_LOCAL:
        module = adapter_module(suite)
        if module is None:
            raise Unavailable(suite.name + " 适配器尚未接入（scripts/eval/harbor/adapters/" + suite.adapter + ".py）")
        dataset = ctx.dataset_dir(suite)
        lister: Callable = getattr(module, "tasks", local_tasks)
        found = [t for t in lister(dataset) if isinstance(t, str) and TASK.fullmatch(t)]
        if not found:
            raise Unavailable(f"{suite.name} 数据集尚未准备：运行 metacodes bench prepare --suite {suite.id}"
                              f"，或用 --dataset {suite.id}=<目录> 指定已生成的数据集")
        return found
    from scripts.eval.harbor.suites import workbuddy
    return workbuddy.task_ids(suite, ctx)


def readiness(suite: Suite, ctx: Context) -> List[str]:
    """Suite-specific reasons this suite cannot launch here ([] when ready)."""
    reasons: List[str] = []
    if suite.runner == HARBOR_LOCAL:
        module = adapter_module(suite)
        if module is not None and hasattr(module, "check"):
            reasons += [str(r) for r in module.check(ctx)]
        try:
            judge(suite, ctx.cfg)
        except ValueError as exc:
            reasons.append(str(exc))
    elif suite.runner == WORKBUDDY:
        from scripts.eval.harbor.suites import workbuddy
        reasons += workbuddy.readiness(suite, ctx)
    missing = [n for n in suite.required_env if not ctx.env.get(n)]
    if missing:
        reasons.append(f"{suite.name} 需要在工作台的环境变量里设置 {'、'.join(missing)}"
                       f"（可选 {'、'.join(suite.host_env)}），用于任务里的 LLM 用户模拟器")
    try:
        task_ids(suite, ctx)
    except Unavailable as exc:
        reasons.insert(0, str(exc))
    return reasons


def validate_tasks(suite: Suite, ctx: Context, tasks, known=None) -> List[str]:
    """The requested ids, refused unless each is one of this suite's tasks
    (`known`: the executor's own list, when another machine reports it)."""
    if not isinstance(tasks, list) or not 1 <= len(tasks) <= suite.max_tasks:
        raise ValueError(f"请选择 1–{suite.max_tasks} 道任务")
    if suite.filter_prefix:
        tasks = [t[len(suite.filter_prefix):] if isinstance(t, str) and t.startswith(suite.filter_prefix) else t
                 for t in tasks]
    if any(not isinstance(t, str) or not TASK.fullmatch(t) for t in tasks) or len(set(tasks)) != len(tasks):
        raise ValueError("任务名无效或重复")
    known = set(task_ids(suite, ctx) if known is None else known)
    unknown = [t for t in tasks if t not in known]
    if unknown:
        raise ValueError(f"{suite.name} 中没有这些任务：" + "、".join(unknown[:5]))
    return tasks


def harbor_dataset_args(suite: Suite, ctx: Context) -> List[str]:
    if suite.runner == HARBOR_REGISTRY:
        return ["-d", suite.dataset]
    if suite.runner == HARBOR_LOCAL:
        return ["-p", str(ctx.dataset_dir(suite).resolve())]
    raise ValueError(suite.id + " 不是 Harbor 评测集")


def host_env(suite: Suite) -> Tuple[str, ...]:
    """Environment names a suite needs on the execution host (a registry
    suite's own, a harbor-local adapter's HOST_ENV); forwarded by name to
    SSH executors."""
    if suite.runner == HARBOR_REGISTRY:
        return suite.required_env + suite.host_env
    if suite.runner != HARBOR_LOCAL:
        return ()
    names = getattr(adapter_module(suite), "HOST_ENV", ()) or ()
    return tuple(n for n in names if isinstance(n, str) and ENV_NAME.fullmatch(n))


def judge(suite: Suite, cfg) -> Optional[Dict]:
    """The suite's LLM judge routed through the run's credential relay, or
    None (no judge, or provider authentication: the verifier then reads
    HOST_ENV on the execution host).

    {"model": bare gateway model id, "env": the verifier's variable names}.
    The model is `judges.<suite id>.model` in workbench.json, else the
    adapter's default; a `metask/` prefix (the catalog's spelling) is
    dropped, since the gateway names models without it."""
    if suite.runner != HARBOR_LOCAL or auth_mode(cfg) != "metask":
        return None
    declared = getattr(adapter_module(suite), "JUDGE", None)
    if not isinstance(declared, dict):
        return None
    entry = ((cfg or {}).get("judges") or {}).get(suite.id) or {}
    if not isinstance(entry, dict) or set(entry) - {"model"}:
        raise ValueError(f"workbench.json 的 judges.{suite.id} 只接受 model")
    model = entry.get("model", declared["default_model"])
    if isinstance(model, str):
        model = model.removeprefix("metask/")
    from scripts.eval.harbor.profiling import JUDGE_ENV_NAME, JUDGE_MODEL
    if not isinstance(model, str) or not JUDGE_MODEL.fullmatch(model):
        raise ValueError(f"judges.{suite.id}.model 无效：{str(model)[:80]}")
    env = dict(declared["env"])
    if set(env) - {"api_key", "base_url", "model", "ca_file"} or \
            not all(k in env for k in ("api_key", "base_url", "model")) or \
            not all(isinstance(v, str) and JUDGE_ENV_NAME.fullmatch(v) for v in env.values()):
        raise ValueError(suite.id + " 适配器的 JUDGE.env 无效")
    return {"model": model, "env": env}


def judge_label(suite: Suite, cfg, env=None) -> Optional[Dict]:
    """The run record's (non-secret) view of the suite's judge, or None."""
    routed = judge(suite, cfg)
    if routed:
        return {"model": routed["model"], "via": "metask"}
    declared = getattr(adapter_module(suite), "JUDGE", None) if suite.runner == HARBOR_LOCAL else None
    if not isinstance(declared, dict):
        return None
    env = os.environ if env is None else env
    model = env.get(declared["env"]["model"]) or declared.get("upstream_default")
    return {"model": model, "via": "host_env"} if model else None


def task_filters(suite: Suite, tasks: List[str]) -> List[str]:
    """Harbor `-i` patterns: exact names (TASK excludes glob characters)."""
    return [suite.filter_prefix + task for task in tasks]


def infer(dataset) -> Optional[str]:
    """Suite id of an older job from its Harbor dataset name, when unambiguous."""
    if not isinstance(dataset, str):
        return None
    if dataset in ("terminal-bench/terminal-bench-2-1",) or dataset.startswith("terminal-bench/terminal-bench-2-1@"):
        return "terminal-bench-2.1"
    name = dataset.rstrip("/").rsplit("/", 1)[-1]
    return "gaia2-cli" if name == "gaia2-cli" else None


def label(suite_id) -> Dict[str, str]:
    """Display fields for a job that ran (or is inferred to have run) a suite."""
    suite = BY_ID.get(suite_id) if isinstance(suite_id, str) else None
    if suite is None:
        return {}
    category = dict((c[0], c[1]) for c in CATEGORIES)[suite.category]
    return {"suite": suite.id, "suite_name": resolved(suite).name,
            "category": suite.category, "category_name": category}


def public(suite: Suite, ctx: Context, common_reasons=()) -> dict:
    """Catalog entry for the page/CLI. Task lists are served per suite."""
    suite = resolved(suite)
    reasons = list(common_reasons) + readiness(suite, ctx)
    try:
        count = len(task_ids(suite, ctx))
    except Unavailable:
        count = None
    try:
        shown_judge = judge_label(suite, ctx.cfg, ctx.env)
    except ValueError:
        shown_judge = None  # the readiness reasons say why
    return {"id": suite.id, "category": suite.category, "name": suite.name,
            "judge": shown_judge,
            "description": suite.description, "runner": suite.runner,
            "dataset": suite.dataset or None, "task_count": count,
            "default_tasks": list(suite.default_tasks), "max_tasks": suite.max_tasks,
            "max_concurrency": suite.max_concurrency, "arch": suite.arch or None,
            "available": suite.runner != HARBOR_LOCAL or adapter_module(suite) is not None,
            "ready": not reasons, "reasons": reasons}


def categories() -> List[dict]:
    return [{"id": i, "name": n, "description": d} for i, n, d in CATEGORIES]
