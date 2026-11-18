"""MBPP sanitized (google-research, "sanitized" config, test split: 257 problems).

Source: github.com/google-research/google-research mbpp/sanitized-mbpp.json at
commit f46ca8374b4cddef97ca4208ad986049d74d296a (data CC-BY-4.0), the file
the Hugging Face `google-research-datasets/mbpp` "sanitized" config is built
from. SHA-256 pinned. The test split is the sanitized problems with task ids
11-510 (257), matching the Hugging Face config.

Same task shape and grader as mbpp.py; the sanitized rows add `test_imports`,
which the verifier executes before the asserts.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List

from scripts.eval.harbor.adapters import _answer_tasks as at
from scripts.eval.harbor.adapters import _common as c
from scripts.eval.harbor.adapters import mbpp

GENERATOR_VERSION = "1"
PIN = c.Pin(
    name="sanitized-mbpp.json",
    url=f"https://raw.githubusercontent.com/google-research/google-research/{mbpp.REVISION}/mbpp/sanitized-mbpp.json",
    sha256="ca95deaa9a01ef0a6f439f88bcf0dd3db3563d22f22aad6cae04ebb9a8d8c8e9",
    size=255053,
)

SUITE_ID = "mbpp-sanitized"  # catalog id (scripts/eval/harbor/suites ADAPTER_SUITES)

SUITE = {
    "name": "MBPP (sanitized)",
    "description": "Google MBPP 人工校订版（sanitized 配置）测试集 257 题：题面与断言更规范，三条断言全部通过得 1 分。",
    "default_tasks": ["mbpp-sanitized-11", "mbpp-sanitized-101", "mbpp-sanitized-245", "mbpp-sanitized-410", "mbpp-sanitized-479"],
    "max_tasks": 200,
    "max_concurrency": 8,
    "arch": "amd64, arm64 (python:3.12-slim-bookworm multi-arch)",
}


def build(inputs: Dict[str, Path], out: Path) -> None:
    with open(inputs[PIN.name], encoding="utf-8") as handle:
        rows = json.load(handle)
    for row in rows:
        source_id = int(row["task_id"])
        if source_id not in mbpp.TEST_IDS:
            continue
        mbpp.write_code_task(
            out,
            suite="mbpp_sanitized",
            tid=f"mbpp-sanitized-{source_id}",
            header=f"MBPP (sanitized) task {source_id}",
            text=str(row["prompt"]),
            tests=list(row["test_list"]),
            setup="",
            imports=list(row.get("test_imports") or []),
            code=str(row["code"]),
            source_id=source_id,
            source=f"google-research/google-research@{mbpp.REVISION}:mbpp/sanitized-mbpp.json",
        )


def fingerprint() -> str:
    return c.fingerprint_of(
        "mbpp_sanitized",
        GENERATOR_VERSION,
        PIN,
        files=[Path(__file__).resolve(), Path(mbpp.__file__).resolve(), *at.own_sources()],
    )


def prepare(dest: Path) -> Path:
    """Download the pinned sanitized MBPP file and write 257 tasks into dest."""
    return c.prepare_dataset(
        Path(dest),
        suite_id=SUITE_ID,
        fingerprint=fingerprint(),
        fetch_sources=lambda cache: {PIN.name: c.fetch(PIN, cache)},
        build=build,
        provenance={"mbpp_sanitized": PIN.describe(), "license": "CC-BY-4.0"},
    )


def tasks(dataset: Path) -> List[str]:
    return c.task_ids(Path(dataset))
