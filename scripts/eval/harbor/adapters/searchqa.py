"""SearchQA (Dunn et al. 2017), a pinned 200-question test subset, as Harbor 0.26 tasks.

Source: the original SearchQA release as hosted on Hugging Face,
`kyunghyuncho/search_qa` at commit 06907e45883b7cae435453b65d598447039fde79,
file data/train_test_val/test.zip (621,941,314 bytes, LFS SHA-256
ab7e0222eff6420c3c378d97c15dc9d1d657abac34c5d1660dd38a5d075dab1c; one JSON
file per Jeopardy! clue with its Google snippets). License: not stated by the
authors (dataset card: "unknown"); Jeopardy! clues are J! Archive material
and snippets are Google search results, so use it for research evaluation only.

Subset: the test split has 43,228 questions. prepare() reads only the zip's
central directory and the chosen members through HTTP range requests (about
3 MB plus ~15 KB per question) instead of the 622 MB archive. The members are
ordered by SHA-256 of their file name and the first 200 with a non-empty
answer and at least one non-empty snippet are taken. The subset is pinned by
SUBSET_SHA256, a SHA-256 over every chosen (name, SHA-256 of member bytes)
pair, so a changed archive, a changed member or a changed choice fails closed.
Each member's zip CRC-32 is checked as it is read.

Task: the clue, its category and all of its snippets are in instruction.md;
the agent writes a short answer to /app/answer.txt. graders/qa_grader.py (in a
separate offline container) scores SQuAD-normalised exact match against the
answer and its parenthetical alternates; reward 1 iff EM = 1, token F1 is
reported but awards nothing.

Harbor 0.26 references: adapters/simpleqa (short-answer QA task shape),
examples/tasks/sidecar-artifacts (separate verifier from tests/Dockerfile).
"""

from __future__ import annotations

import hashlib
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from scripts.eval.harbor.adapters import _answer_tasks as at
from scripts.eval.harbor.adapters import _common as c

GENERATOR_VERSION = "1"
REVISION = "06907e45883b7cae435453b65d598447039fde79"
ZIP_URL = f"https://huggingface.co/datasets/kyunghyuncho/search_qa/resolve/{REVISION}/data/train_test_val/test.zip"
ZIP_SIZE = 621941314
ZIP_LFS_SHA256 = "ab7e0222eff6420c3c378d97c15dc9d1d657abac34c5d1660dd38a5d075dab1c"
SUBSET_SIZE = 200
SUBSET_SHA256 = "a7dba6c1fc45520158bc99a8a3d6895be765733047f98af4198264fe5a718e2e"
SUBSET_FILE = "searchqa-test-subset.json"
READ_WORKERS = 8

SUITE_ID = "searchqa"  # catalog id (scripts/eval/harbor/suites ADAPTER_SUITES)

SUITE = {
    "name": "SearchQA (200 题子集)",
    "description": "SearchQA 测试集的固定 200 题子集：依据给出的搜索摘要回答 Jeopardy! 问题，SQuAD 归一化后精确匹配（EM=1）得 1 分，F1 仅记录。",
    # The first five of the pinned order.
    "default_tasks": ["searchqa-124678", "searchqa-150794", "searchqa-41440", "searchqa-57769", "searchqa-152112"],
    "max_tasks": 200,
    "max_concurrency": 16,
    "arch": "amd64, arm64 (python:3.12-slim-bookworm multi-arch)",
}


def _usable(record: Dict[str, object]) -> bool:
    answer = str(record.get("answer") or "").strip()
    results = record.get("search_results") or []
    snippets = [r for r in results if isinstance(r, dict) and str(r.get("snippet") or "").strip()]  # type: ignore[union-attr]
    return bool(answer) and bool(snippets)


def subset_digest(pairs: List[Tuple[str, bytes]]) -> str:
    digest = hashlib.sha256()
    for name, data in pairs:
        digest.update(name.encode("utf-8") + b"\0" + c.sha256_bytes(data).encode("ascii") + b"\n")
    return digest.hexdigest()


def select_subset(archive: c.RemoteZip, size: int, expected: Optional[str]) -> List[Tuple[str, bytes]]:
    """The pinned subset, read member by member; fails closed on mismatch."""
    names = sorted(
        (n for n in archive.names() if n.endswith(".json")),
        key=lambda n: hashlib.sha256(n.encode("utf-8")).hexdigest(),
    )
    chosen: List[Tuple[str, bytes]] = []
    # Reads run in parallel batches; the choice is made in name order.
    with ThreadPoolExecutor(max_workers=READ_WORKERS) as pool:
        for start in range(0, len(names), READ_WORKERS * 2):
            batch = names[start : start + READ_WORKERS * 2]
            for name, data in zip(batch, pool.map(archive.read, batch)):
                try:
                    record = json.loads(data.decode("utf-8"))
                except ValueError as error:
                    raise c.SourceIntegrityError(f"searchqa: {name} is not JSON") from error
                if _usable(record):
                    chosen.append((name, data))
                    if len(chosen) == size:
                        break
            if len(chosen) == size:
                break
    if len(chosen) != size:
        raise c.SourceIntegrityError(f"searchqa: only {len(chosen)} usable questions")
    if expected is not None and subset_digest(chosen) != expected:
        raise c.SourceIntegrityError(f"searchqa: subset digest {subset_digest(chosen)} != pinned {expected}")
    return chosen


def write_subset(path: Path, pairs: List[Tuple[str, bytes]]) -> None:
    payload = {"members": [{"name": name, "data": data.decode("utf-8")} for name, data in pairs]}
    tmp = path.with_suffix(".partial")
    tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    tmp.replace(path)


def read_subset(path: Path) -> List[Tuple[str, bytes]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    return [(m["name"], m["data"].encode("utf-8")) for m in payload["members"]]


def fetch_subset(cache_dir: Path, source: Optional[c.RangeSource] = None) -> Dict[str, Path]:
    """The verified subset file in `cache_dir`, read from the archive only when missing."""
    expected = SUBSET_SHA256
    cache_dir.mkdir(parents=True, exist_ok=True)
    target = cache_dir / SUBSET_FILE
    if target.is_file():
        try:
            if subset_digest(read_subset(target)) == expected:
                return {SUBSET_FILE: target}
        except (ValueError, KeyError):
            pass
        target.unlink()
    archive = c.RemoteZip(source or c.HttpRangeSource(ZIP_URL, ZIP_SIZE))
    write_subset(target, select_subset(archive, SUBSET_SIZE, expected))
    return {SUBSET_FILE: target}


def task_id_for(name: str) -> str:
    # "124678-5727_doublejeopardy_economics_400.json" -> "searchqa-124678"
    return "searchqa-" + name.split("-", 1)[0].lstrip("0").rjust(1, "0")


def instruction(record: Dict[str, object]) -> str:
    lines = [
        "# SearchQA",
        "",
        "Answer the Jeopardy! clue below using the search-engine snippets that were retrieved for it.",
        "",
        f"Category: {str(record.get('category') or '').strip()}",
        f"Clue: {str(record['question']).strip()}",
        "",
        "## Retrieved snippets",
        "",
    ]
    number = 0
    for result in record.get("search_results") or []:  # type: ignore[union-attr]
        if not isinstance(result, dict):
            continue
        snippet = " ".join(str(result.get("snippet") or "").split())
        if not snippet:
            continue
        number += 1
        title = " ".join(str(result.get("title") or "").split())
        lines.append(f"{number}. {title}: {snippet}" if title else f"{number}. {snippet}")
    lines += [
        "",
        "## What to submit",
        "",
        "Write only the answer (a short phrase such as a name, place or thing, not a question "
        "and not a sentence) on the first line of `/app/answer.txt`. Only that file is graded: "
        "it is lower-cased, stripped of punctuation and articles, and compared for exact match "
        "with the reference answer.",
    ]
    return "\n".join(lines) + "\n"


def build(inputs: Dict[str, Path], out: Path) -> None:
    for name, data in read_subset(inputs[SUBSET_FILE]):
        record = json.loads(data.decode("utf-8"))
        tid = task_id_for(name)
        answer = str(record["answer"]).strip()
        files = at.answer_task_files(
            task_id=tid,
            kind="qa",
            artifact="/app/answer.txt",
            description=f"SearchQA test question {name.split('-', 1)[0]}",
            keywords=["searchqa", "qa", "reading-comprehension"],
            metadata={
                "benchmark": "searchqa",
                "source_id": name,
                "category": str(record.get("category") or ""),
                "source": f"kyunghyuncho/search_qa@{REVISION}:data/train_test_val/test.zip",
            },
            instruction=instruction(record),
            oracle=answer,
            spec={"answer": answer},
            agent_timeout_sec=600.0,
        )
        c.write_task(out / tid, files)


def fingerprint() -> str:
    return c.fingerprint_of(
        "searchqa", GENERATOR_VERSION, ZIP_URL, ZIP_SIZE, SUBSET_SIZE, SUBSET_SHA256,
        files=[Path(__file__).resolve(), *at.own_sources()],
    )


def prepare(dest: Path) -> Path:
    """Fetch the pinned 200-question subset (range reads) and write tasks into dest."""
    return c.prepare_dataset(
        Path(dest),
        suite_id=SUITE_ID,
        fingerprint=fingerprint(),
        fetch_sources=fetch_subset,
        build=build,
        provenance={
            "dataset": "kyunghyuncho/search_qa",
            "revision": REVISION,
            "archive": {"url": ZIP_URL, "size": ZIP_SIZE, "lfs_sha256": ZIP_LFS_SHA256},
            "subset": {"size": SUBSET_SIZE, "sha256": SUBSET_SHA256, "rule": "sha256(member name) order, usable rows"},
            "license": "unknown (research use)",
        },
    )


def tasks(dataset: Path) -> List[str]:
    return c.task_ids(Path(dataset))
