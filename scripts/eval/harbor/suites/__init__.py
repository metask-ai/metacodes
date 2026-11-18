"""Benchmark catalog of the Bench workbench: which suites exist and how they run.

Every suite has an id, a category, a Chinese name and description, and one
runner kind:

- ``harbor-registry``: a Harbor 0.26 registry dataset (``harbor run -d REF``).
  Task ids are fixed in this module and were taken from the registry itself;
  ``filter_prefix`` turns an id into the ``-i`` pattern Harbor matches
  (Hub datasets name tasks ``org/name``, legacy-registry ones the bare name).
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
        "max_concurrency": 4,      # <= MAX_CONCURRENCY
    }

    def prepare(dest: Path) -> Path:
        '''Write Harbor task directories (<dest>/<task-id>/task.toml, ...)
        and return the dataset directory (normally ``dest``).'''

    # optional
    def check(ctx) -> list[str]:   # extra readiness reasons (Chinese), [] if ready;
                                   # ctx.cfg / ctx.env / ctx.dataset_dir(suite)
    def tasks(dataset: Path) -> list[str]:   # default: sorted dirs with task.toml

Task ids must match ``TASK`` (no glob characters: Harbor's ``-i`` is an
fnmatch pattern). ``metacodes bench prepare --suite <id>`` runs ``prepare``
on the execution machine with ``dest = <state root>/bench/datasets/<suite id>``;
``metacodes bench --dataset <suite id>=<dir>`` registers an existing
directory instead. Until the module exists the suite is listed as not yet
available, with that reason.
"""
from __future__ import annotations

import importlib
import os
import re
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

HARBOR_REGISTRY = "harbor-registry"
HARBOR_LOCAL = "harbor-local"
WORKBUDDY = "workbuddy"
RUNNERS = (HARBOR_REGISTRY, HARBOR_LOCAL, WORKBUDDY)

TASK = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,160}$")
MAX_TASKS = 200
MAX_CONCURRENCY = 8
DEFAULT_SUITE = "terminal-bench-2.1"

# Ordered as the picker shows them.
CATEGORIES = (
    ("code-generation", "代码生成", "根据描述写出函数，通过单元测试"),
    ("basic-programming", "基础编程", "Python 基础编程任务"),
    ("interactive-planning", "交互规划", "多步骤家庭任务的规划与执行"),
    ("question-answering", "问答", "根据检索到的段落回答问题"),
    ("math-reasoning", "数学推理", "数学问题求解"),
    ("competition-math", "竞赛数学", "AIME 竞赛题，答案为整数"),
    ("terminal", "终端工程", "在容器终端里完成真实工程任务"),
    ("general-agent", "通用 Agent", "动态环境中的工具使用与任务执行"),
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
    max_concurrency: int = 3
    # harbor-local: adapter module under scripts.eval.harbor.adapters.
    adapter: str = ""
    # workbuddy: dataset subset (code/web/office/sec) and whether the
    # workbench can launch it (judged subsets need a judge budget).
    subset: str = ""
    notes: Tuple[str, ...] = field(default_factory=tuple)


SUITES: Tuple[Suite, ...] = (
    Suite("terminal-bench-2.1", "terminal", "Terminal-Bench 2.1",
          "89 道终端工程任务（2.1 版更新了题目内容），每题独立容器运行并自动判分",
          HARBOR_REGISTRY, dataset="terminal-bench/terminal-bench-2-1",
          filter_prefix="terminal-bench/", tasks=TERMINAL_BENCH_2,
          default_tasks=TERMINAL_BENCH_SAMPLE, max_tasks=89),
    Suite("terminal-bench-2.0", "terminal", "Terminal-Bench 2.0",
          "89 道终端工程任务的 2.0 原版，用于与公开榜单对齐",
          HARBOR_REGISTRY, dataset="terminal-bench@2.0", tasks=TERMINAL_BENCH_2,
          default_tasks=TERMINAL_BENCH_SAMPLE, max_tasks=89),
    Suite("aime", "competition-math", "AIME 2024–2025",
          "60 道 AIME 竞赛题：2024 年 30 道，2025 年 I/II 卷各 15 道",
          HARBOR_REGISTRY, dataset="aime@1.0", tasks=AIME_2024 + AIME_2025,
          default_tasks=AIME_2024 + AIME_2025, max_tasks=60, max_concurrency=8),
    Suite("aime-2025", "competition-math", "AIME 2025",
          "单独实验：只跑 2025 年 I/II 卷 30 道题（与 aime 数据集相同来源）",
          HARBOR_REGISTRY, dataset="aime@1.0", tasks=AIME_2025,
          default_tasks=AIME_2025, max_tasks=30, max_concurrency=8),
)

# harbor-local suites. The id/category here are authoritative; the adapter
# module may refine name, description, sample and caps.
ADAPTER_SUITES: Tuple[Suite, ...] = (
    Suite("humaneval", "code-generation", "HumanEval", "根据函数描述写出实现，通过单元测试",
          HARBOR_LOCAL, adapter="humaneval", max_tasks=164, max_concurrency=8),
    Suite("mbpp", "basic-programming", "MBPP", "MBPP / MBPP-sanitized Python 编程任务",
          HARBOR_LOCAL, adapter="mbpp", max_tasks=MAX_TASKS, max_concurrency=8),
    Suite("alfworld", "interactive-planning", "ALFWorld", "多步骤家庭任务的规划与执行",
          HARBOR_LOCAL, adapter="alfworld", max_tasks=134),
    Suite("searchqa", "question-answering", "SearchQA", "根据检索到的段落回答问题",
          HARBOR_LOCAL, adapter="searchqa", max_tasks=MAX_TASKS, max_concurrency=8),
    Suite("livemath", "math-reasoning", "LiveMath", "数学问题求解",
          HARBOR_LOCAL, adapter="livemath", max_tasks=MAX_TASKS, max_concurrency=8),
    Suite("gaia2-cli", "general-agent", "GAIA2（CLI 模式）",
          "Meta GAIA2 的 Harbor CLI 变体：agent 通过 MCP 侧车调用 ARE 环境的 101 个工具完成动态场景任务",
          HARBOR_LOCAL, adapter="gaia2_cli", max_tasks=100),
)

WORKBUDDY_SUITES: Tuple[Suite, ...] = (
    Suite("workbuddy-code", "work-agent", "WorkBuddy Code", "WorkBuddy-Bench 代码子集（80 题），verifier 判分",
          WORKBUDDY, subset="code", max_tasks=20, max_concurrency=2),
    Suite("workbuddy-sec", "work-agent", "WorkBuddy Security", "WorkBuddy-Bench 安全子集（60 题），verifier 判分",
          WORKBUDDY, subset="sec", max_tasks=20, max_concurrency=2),
    Suite("workbuddy-web", "work-agent", "WorkBuddy Web", "WorkBuddy-Bench 网页子集（70 题），需 LLM judge",
          WORKBUDDY, subset="web", max_tasks=20, max_concurrency=2),
    Suite("workbuddy-office", "work-agent", "WorkBuddy Office", "WorkBuddy-Bench 办公文档子集（50 题），需 LLM judge",
          WORKBUDDY, subset="office", max_tasks=20, max_concurrency=2),
)

ALL: Tuple[Suite, ...] = SUITES + ADAPTER_SUITES + WORKBUDDY_SUITES


def _validate():
    seen = set()
    for suite in ALL:
        assert suite.id not in seen and TASK.fullmatch(suite.id), suite.id
        seen.add(suite.id)
        assert suite.category in CATEGORY_IDS and suite.runner in RUNNERS, suite.id
        assert 1 <= suite.max_tasks <= MAX_TASKS and 1 <= suite.max_concurrency <= MAX_CONCURRENCY, suite.id
        if suite.tasks is not None:
            assert all(TASK.fullmatch(t) for t in suite.tasks) and len(set(suite.tasks)) == len(suite.tasks), suite.id
            assert set(suite.default_tasks) <= set(suite.tasks), suite.id
        assert (suite.runner == HARBOR_REGISTRY) == bool(suite.dataset), suite.id
        assert (suite.runner == HARBOR_LOCAL) == bool(suite.adapter), suite.id
        assert (suite.runner == WORKBUDDY) == bool(suite.subset), suite.id


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
    allowed = {"name", "description", "default_tasks", "max_tasks", "max_concurrency"}
    changes = {k: v for k, v in meta.items() if k in allowed}
    if "default_tasks" in changes:
        changes["default_tasks"] = tuple(changes["default_tasks"])
    for key in ("max_tasks", "max_concurrency"):
        limit = MAX_TASKS if key == "max_tasks" else MAX_CONCURRENCY
        if key in changes and not (type(changes[key]) is int and 1 <= changes[key] <= limit):
            changes.pop(key)
    return replace(suite, **changes)


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
    elif suite.runner == WORKBUDDY:
        from scripts.eval.harbor.suites import workbuddy
        reasons += workbuddy.readiness(suite, ctx)
    try:
        task_ids(suite, ctx)
    except Unavailable as exc:
        reasons.insert(0, str(exc))
    return reasons


def validate_tasks(suite: Suite, ctx: Context, tasks) -> List[str]:
    """The requested ids, refused unless each is one of this suite's tasks."""
    if not isinstance(tasks, list) or not 1 <= len(tasks) <= suite.max_tasks:
        raise ValueError(f"请选择 1–{suite.max_tasks} 道任务")
    if suite.filter_prefix:
        tasks = [t[len(suite.filter_prefix):] if isinstance(t, str) and t.startswith(suite.filter_prefix) else t
                 for t in tasks]
    if any(not isinstance(t, str) or not TASK.fullmatch(t) for t in tasks) or len(set(tasks)) != len(tasks):
        raise ValueError("任务名无效或重复")
    known = set(task_ids(suite, ctx))
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
    return {"id": suite.id, "category": suite.category, "name": suite.name,
            "description": suite.description, "runner": suite.runner,
            "dataset": suite.dataset or None, "task_count": count,
            "default_tasks": list(suite.default_tasks), "max_tasks": suite.max_tasks,
            "max_concurrency": suite.max_concurrency,
            "available": suite.runner != HARBOR_LOCAL or adapter_module(suite) is not None,
            "ready": not reasons, "reasons": reasons}


def categories() -> List[dict]:
    return [{"id": i, "name": n, "description": d} for i, n, d in CATEGORIES]
