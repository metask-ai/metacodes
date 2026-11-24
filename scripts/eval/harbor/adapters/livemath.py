"""LiveMath = LiveMathBench v202412, English (OpenCompass), as Harbor 0.26 tasks.

DATASET CHOICE. "LiveMath" is read as LiveMathBench (Liu et al., "Are Your
LLMs Capable of Stable Reasoning?", arXiv:2412.13147), published by
OpenCompass as the Hugging Face dataset `opencompass/LiveMathBench`. Of its
two releases this adapter uses v202412 in English: the four competition sets
AMC_en, CCEE_en, CNMO_en and WLPMC_en (the English half of the 238-question
release). v202505 (100 questions) is not used: many of its gold answers are
prose ("Paul can win") that no deterministic grader can check.

Source: opencompass/LiveMathBench at commit
ea05b95ab431f3ef3900ce86f864451cf5bcd699, files 202412/<SET>_en.jsonl
(CC-BY-4.0). The dataset is GATED on Hugging Face: accept its terms (the
gate asks you to agree to non-commercial use) and provide HF_TOKEN or a
`huggingface-cli login` token, or prepare() fails. Because the bytes could
not be fetched without that agreement when this adapter was written, each
file is pinned by the git blob SHA-1 and size Hugging Face reports for it at
that commit (fail-closed like a SHA-256 pin); prepare() records the SHA-256
of what it verified in the dataset marker.

Grading is deterministic (graders/math_grader.py, separate offline
container): reward 1 iff the submitted final answer matches the gold answer
by normalised string, numeric value, list/set or choice-letter equivalence.
The LiveMathBench authors grade with an LLM judge; this grader is stricter.

Harbor 0.26 references: adapters/aime (final-answer math task shape),
examples/tasks/sidecar-artifacts (separate verifier from tests/Dockerfile).
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List

from scripts.eval.harbor.adapters import _answer_tasks as at
from scripts.eval.harbor.adapters import _common as c

GENERATOR_VERSION = "1"
REVISION = "ea05b95ab431f3ef3900ce86f864451cf5bcd699"
_BASE = f"https://huggingface.co/datasets/opencompass/LiveMathBench/resolve/{REVISION}/202412/"
# (set, git blob sha1, size) from
# https://huggingface.co/api/datasets/opencompass/LiveMathBench/tree/<REVISION>/202412
SETS = (
    ("AMC", "ea90b457512bf681b26b19ba15c45beaa3a4e241", 14765),
    ("CCEE", "4ef9068e2e6532645b38728c2253cdc46b84b34c", 11631),
    ("CNMO", "0ee937da9ad8b2aaad803cde3f555b08540167e2", 5682),
    ("WLPMC", "7fa43ceaac886ccfcbd96b17a00e849e013fb714", 5633),
)
PINS = tuple(
    c.Pin(name=f"{name}_en.jsonl", url=f"{_BASE}{name}_en.jsonl", git_blob_sha1=blob, size=size, hf_auth=True)
    for name, blob, size in SETS
)

SUITE_ID = "livemath"  # catalog id (scripts/eval/harbor/suites ADAPTER_SUITES)

SUITE = {
    "name": "LiveMathBench (v202412, EN)",
    "description": "OpenCompass LiveMathBench v202412 英文版（AMC/高考/CNMO/Putnam 四套竞赛题）：给出最终答案，按确定性规则（字符串/数值/集合/选项等价）判分。数据集需在 Hugging Face 同意条款并提供 HF_TOKEN。",
    "default_tasks": ["livemath-amc-1", "livemath-amc-20", "livemath-ccee-1", "livemath-cnmo-1", "livemath-wlpmc-1"],
    "max_tasks": 200,
    "arch": "amd64, arm64 (python:3.12-slim-bookworm multi-arch)",
}


def instruction(header: str, question: str, options: List[str]) -> str:
    body = f"# {header}\n\nSolve the following competition mathematics problem.\n\n{question.strip()}\n"
    if options:
        body += "\nOptions:\n\n" + "\n".join(f"- {opt}" for opt in options) + "\n"
    body += (
        "\nWrite only your final answer to `/app/answer.txt`, in LaTeX if needed (for example "
        "`\\frac{2n+2}{3}` or `\\boxed{17}`). For a multiple-choice question write the option "
        "letter(s). Only `/app/answer.txt` is graded: the last `\\boxed{...}` in it, or else its "
        "last non-empty line, is compared with the reference answer.\n"
    )
    return body


def load(path: Path) -> List[Dict[str, object]]:
    with open(path, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def build(inputs: Dict[str, Path], out: Path) -> None:
    for name, _, _ in SETS:
        pin_name = f"{name}_en.jsonl"
        for index, row in enumerate(load(inputs[pin_name]), start=1):
            tid = f"livemath-{name.lower()}-{index}"
            question = str(row["question"])
            answer = str(row["answer"])
            options = [str(opt) for opt in (row.get("options") or []) if opt]
            header = f"LiveMathBench v202412 {name}_en #{index}"
            files = at.answer_task_files(
                task_id=tid,
                kind="math",
                artifact="/app/answer.txt",
                description=header,
                keywords=["livemathbench", "math", name.lower()],
                metadata={
                    "benchmark": "livemathbench",
                    "subset": f"v202412_{name}_en",
                    "source_id": index,
                    "question_type": str(row.get("question_type") or ""),
                    "source": f"opencompass/LiveMathBench@{REVISION}:202412/{pin_name}",
                },
                instruction=instruction(header, question, options),
                # Boxed, so a multi-line reference answer is still read whole.
                oracle="\\boxed{" + answer + "}",
                spec={"answer": answer, "question_type": str(row.get("question_type") or "")},
                agent_timeout_sec=1800.0,
            )
            c.write_task(out / tid, files)


def fingerprint() -> str:
    return c.fingerprint_of("livemath", GENERATOR_VERSION, *PINS, files=[Path(__file__).resolve(), *at.own_sources()])


def prepare(dest: Path) -> Path:
    """Download the four gated v202412 English files (HF_TOKEN) and write tasks into dest."""
    return c.prepare_dataset(
        Path(dest),
        suite_id=SUITE_ID,
        fingerprint=fingerprint(),
        fetch_sources=lambda cache: {pin.name: c.fetch(pin, cache) for pin in PINS},
        build=build,
        provenance={
            "dataset": "opencompass/LiveMathBench",
            "revision": REVISION,
            "files": {pin.name: pin.describe() for pin in PINS},
            "license": "CC-BY-4.0 (gated; non-commercial use agreement)",
        },
    )


def check(ctx) -> List[str]:
    """Readiness: the gated download needs a Hugging Face token until the dataset exists."""
    try:
        from scripts.eval.harbor import suites

        dataset = ctx.dataset_dir(suites.get(SUITE_ID))
    except (ImportError, AttributeError, ValueError):
        dataset = None
    if dataset is not None and c.task_ids(Path(dataset)):
        return []
    env = getattr(ctx, "env", None) or {}
    if env.get("HF_TOKEN") or env.get("HUGGING_FACE_HUB_TOKEN") or c.huggingface_token():
        return []
    return ["LiveMathBench 在 Hugging Face 上是受限数据集：请先在网页上同意其条款（非商业用途），"
            "再为执行服务设置 HF_TOKEN（或 huggingface-cli login）后准备数据集"]


def tasks(dataset: Path) -> List[str]:
    return c.task_ids(Path(dataset))
