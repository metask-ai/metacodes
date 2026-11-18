"""HumanEval (openai_humaneval, 164 problems) as Harbor 0.26 tasks.

Source: github.com/openai/human-eval data/HumanEval.jsonl.gz at commit
463c980b59e818ace59f6f9803cd92c749ceae61 (MIT), the file the Hugging Face
`openai/openai_humaneval` dataset was converted from. SHA-256 pinned.

Each task asks for /app/solution.py implementing the problem's function from
its signature and docstring. The verifier (graders/code_grader.py, in a
separate offline container) runs the dataset's `check(candidate)` against it
as an unprivileged user; reward 1 iff every assertion passes. The oracle is
prompt + canonical_solution.

Harbor 0.26 references: adapters/humanevalfix/template (task layout, reward
file), examples/tasks/secure-python-worker (separate verifier grading a
submitted /app/solution.py artifact).
"""

from __future__ import annotations

import gzip
import json
from pathlib import Path
from typing import Dict, List

from scripts.eval.harbor.adapters import _answer_tasks as at
from scripts.eval.harbor.adapters import _common as c

GENERATOR_VERSION = "1"
PIN = c.Pin(
    name="HumanEval.jsonl.gz",
    url="https://raw.githubusercontent.com/openai/human-eval/463c980b59e818ace59f6f9803cd92c749ceae61/data/HumanEval.jsonl.gz",
    sha256="b796127e635a67f93fb35c04f4cb03cf06f38c8072ee7cee8833d7bee06979ef",
    size=44877,
)
EXPECTED_COUNT = 164

SUITE_ID = "humaneval"  # catalog id (scripts/eval/harbor/suites ADAPTER_SUITES)

SUITE = {
    "name": "HumanEval",
    "description": "OpenAI HumanEval 164 题：根据函数签名与文档字符串写出 Python 实现，由隐藏单元测试判定（全部通过得 1 分）。",
    "default_tasks": ["humaneval-0", "humaneval-13", "humaneval-42", "humaneval-101", "humaneval-163"],
    "max_tasks": 164,
    "max_concurrency": 8,
    "arch": "amd64, arm64 (python:3.12-slim-bookworm multi-arch)",
}


def task_id(source_id: str) -> str:
    return "humaneval-" + source_id.split("/", 1)[1]


def instruction(problem: Dict[str, str]) -> str:
    entry = problem["entry_point"]
    return (
        f"# {problem['task_id']}\n\n"
        f"Implement the Python function `{entry}` described below.\n\n"
        f"Write a complete, self-contained Python module to `/app/solution.py` that defines "
        f"`{entry}` with exactly this signature, together with any imports and helper "
        f"functions it needs. Only `/app/solution.py` is graded: hidden unit tests import "
        f"nothing else and call `{entry}` directly under Python 3.12 with the standard "
        f"library only. Do not print anything at import time.\n\n"
        "```python\n" + problem["prompt"].rstrip() + "\n```\n"
    )


def load(path: Path) -> List[Dict[str, str]]:
    with gzip.open(path, "rt", encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def build(inputs: Dict[str, Path], out: Path) -> None:
    problems = load(inputs[PIN.name])
    for problem in problems:
        tid = task_id(problem["task_id"])
        files = at.answer_task_files(
            task_id=tid,
            kind="code",
            artifact="/app/solution.py",
            description=f"HumanEval {problem['task_id']}: implement `{problem['entry_point']}`.",
            keywords=["humaneval", "python", "code-generation"],
            metadata={
                "benchmark": "humaneval",
                "source_id": problem["task_id"],
                "source": "openai/human-eval@463c980b59e818ace59f6f9803cd92c749ceae61",
            },
            instruction=instruction(problem),
            oracle=problem["prompt"] + problem["canonical_solution"],
            spec={"kind": "humaneval", "entry_point": problem["entry_point"], "test": problem["test"]},
            agent_timeout_sec=900.0,
        )
        c.write_task(out / tid, files)


def fingerprint() -> str:
    return c.fingerprint_of("humaneval", GENERATOR_VERSION, PIN, files=[Path(__file__).resolve(), *at.own_sources()])


def prepare(dest: Path) -> Path:
    """Download the pinned HumanEval file and write 164 tasks into dest."""
    return c.prepare_dataset(
        Path(dest),
        suite_id=SUITE_ID,
        fingerprint=fingerprint(),
        fetch_sources=lambda cache: {PIN.name: c.fetch(PIN, cache)},
        build=build,
        provenance={"humaneval": PIN.describe(), "license": "MIT"},
    )


def tasks(dataset: Path) -> List[str]:
    return c.task_ids(Path(dataset))
