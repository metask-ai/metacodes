"""MBPP (google-research, "full" config, test split: 500 problems) as Harbor 0.26 tasks.

Source: github.com/google-research/google-research mbpp/mbpp.jsonl at commit
f46ca8374b4cddef97ca4208ad986049d74d296a (data CC-BY-4.0), the file the
Hugging Face `google-research-datasets/mbpp` "full" config is built from.
SHA-256 pinned. The test split is task ids 11-510, as in the paper and the
Hugging Face config.

Each task gives the problem text and its three test asserts, in the paper's
prompt format, and asks for /app/solution.py. The verifier
(graders/code_grader.py, in a separate offline container) runs
test_setup_code after the submission, as the reference harness does, and the
three `test_list` asserts in a separate test process that calls into the
submission's names (`solution_names`); reward 1 iff all pass. `challenge_test_list` is not
used, as in the reference evaluation. The oracle is the reference `code`.

Harbor 0.26 references: see humaneval.py.
"""

from __future__ import annotations

import ast
import json
from pathlib import Path
from typing import Dict, List, Sequence, Set

from scripts.eval.harbor.adapters import _answer_tasks as at
from scripts.eval.harbor.adapters import _common as c

GENERATOR_VERSION = "1"
REVISION = "f46ca8374b4cddef97ca4208ad986049d74d296a"
PIN = c.Pin(
    name="mbpp.jsonl",
    url=f"https://raw.githubusercontent.com/google-research/google-research/{REVISION}/mbpp/mbpp.jsonl",
    sha256="ccf64ceae9c5403bf50a044cb6d505bfd2a2963ee58338ba268fd65beab92a9f",
    size=563743,
)
TEST_IDS = range(11, 511)

SUITE_ID = "mbpp"  # catalog id (scripts/eval/harbor/suites ADAPTER_SUITES)

SUITE = {
    "name": "MBPP",
    "description": "Google MBPP（full 配置）测试集 500 题：按题目描述与示例断言编写 Python 函数，三条断言全部通过得 1 分。",
    "default_tasks": ["mbpp-11", "mbpp-100", "mbpp-250", "mbpp-400", "mbpp-510"],
    "max_tasks": 200,
    "max_concurrency": 16,
    "arch": "amd64, arm64 (python:3.12-slim-bookworm multi-arch)",
}


def instruction(text: str, tests: Sequence[str], header: str) -> str:
    # The MBPP paper's prompt ("You are an expert Python programmer, and here
    # is your task: ... Your code should pass these tests:"), with the
    # submission path the verifier reads.
    return (
        f"# {header}\n\n"
        f"You are an expert Python programmer, and here is your task: {text.strip()}\n\n"
        "Your code should pass these tests:\n\n"
        "```python\n" + "\n".join(t.strip() for t in tests) + "\n```\n\n"
        "Write the complete solution as a self-contained Python module to `/app/solution.py` "
        "(define the function with the name and arguments the tests use, plus any imports "
        "it needs). Only `/app/solution.py` is graded, under Python 3.12 with the standard "
        "library only. Do not print anything at import time.\n"
    )


def _bound_names(source: str) -> Set[str]:
    """Names a module's top-level statements bind."""
    names: Set[str] = set()
    for node in ast.parse(source).body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(node.name)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            names.update((alias.asname or alias.name).split(".")[0] for alias in node.names)
        else:
            for sub in ast.walk(node):
                if isinstance(sub, ast.Name) and isinstance(sub.ctx, ast.Store):
                    names.add(sub.id)
    return names


def solution_names(code: str, setup: str, tests: Sequence[str]) -> List[str]:
    """The names the tests take from the solution module.

    Those the reference code or test_setup_code binds at top level and the
    asserts read. The grader's test driver reaches exactly these in the
    submission (graders/code_grader.py), so a submission cannot shadow a
    builtin the tests use unless the reference itself does (MBPP 126 `sum`).
    """
    bound = _bound_names(code.replace("\r\n", "\n")) | _bound_names(setup.replace("\r\n", "\n"))
    read = {
        node.id
        for test in tests
        for node in ast.walk(ast.parse(test))
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load)
    }
    return sorted(bound & read)


def write_code_task(
    out: Path,
    *,
    suite: str,
    tid: str,
    header: str,
    text: str,
    tests: Sequence[str],
    setup: str,
    imports: Sequence[str],
    code: str,
    source_id: int,
    source: str,
) -> None:
    files = at.answer_task_files(
        task_id=tid,
        kind="code",
        artifact="/app/solution.py",
        description=f"{header}: {text.strip()[:200]}",
        keywords=[suite, "python", "code-generation"],
        metadata={"benchmark": suite, "source_id": source_id, "source": source},
        instruction=instruction(text, tests, header),
        oracle=code.replace("\r\n", "\n"),
        spec={
            "kind": "mbpp",
            "setup": setup,
            "imports": list(imports),
            "tests": list(tests),
            "names": solution_names(code, setup, tests),
        },
        agent_timeout_sec=900.0,
    )
    c.write_task(out / tid, files)


def load(path: Path) -> List[Dict[str, object]]:
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def build(inputs: Dict[str, Path], out: Path) -> None:
    for row in load(inputs[PIN.name]):
        source_id = int(row["task_id"])  # type: ignore[arg-type]
        if source_id not in TEST_IDS:
            continue
        write_code_task(
            out,
            suite="mbpp",
            tid=f"mbpp-{source_id}",
            header=f"MBPP task {source_id}",
            text=str(row["text"]),
            tests=list(row["test_list"]),  # type: ignore[arg-type]
            setup=str(row.get("test_setup_code") or ""),
            imports=[],
            code=str(row["code"]),
            source_id=source_id,
            source=f"google-research/google-research@{REVISION}:mbpp/mbpp.jsonl",
        )


def fingerprint() -> str:
    return c.fingerprint_of("mbpp", GENERATOR_VERSION, PIN, files=[Path(__file__).resolve(), *at.own_sources()])


def prepare(dest: Path) -> Path:
    """Download the pinned MBPP file and write the 500 test-split tasks into dest."""
    return c.prepare_dataset(
        Path(dest),
        suite_id=SUITE_ID,
        fingerprint=fingerprint(),
        fetch_sources=lambda cache: {PIN.name: c.fetch(PIN, cache)},
        build=build,
        provenance={"mbpp": PIN.describe(), "license": "CC-BY-4.0"},
    )


def tasks(dataset: Path) -> List[str]:
    return c.task_ids(Path(dataset))
