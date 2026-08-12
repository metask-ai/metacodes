"""Freeze HotpotQA distractor data for ``memory-maturation-v1``.

The adapter has no model or network dependency.  It validates the official
HotpotQA JSON shape, selects cases by a seed-bound hash of the source id, and
emits two separate artifacts:

* a source slice containing the evidence corpus and upstream provenance; and
* a replay manifest containing prompts, hidden answers, support ids, and the
  complete arm/trial schedule.

Keeping this step deterministic lets a later runtime prove which benchmark
bytes it actually used without treating a synthetic fixture as memory-quality
evidence.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Tuple

from .memory_benchmark import PROTOCOL_ID
from .memory_replay import REPLAY_SCHEMA_VERSION, validate_manifest
from .model import ValidationError, stable_json


ADAPTER_ID = "hotpotqa-distractor"
ADAPTER_REVISION = "official-json-hash-subset-v2"
DATASET_ID = "hotpotqa-distractor-dev-v1"
SOURCE_SLICE_SCHEMA_VERSION = 1
SOURCE_POLICY_SCHEMA_VERSION = 1
SELECTION_ALGORITHM = "sha256-seed-null-source-id-v1"
OFFICIAL_SOURCE_URL = (
    "https://hotpotqa.github.io/"
    "#dev-set-distractor"
)
OFFICIAL_SOURCE_REVISION = "hotpot_dev_distractor_v1"
REQUIRED_RECORD_KEYS = frozenset(
    {"_id", "question", "answer", "type", "level", "supporting_facts", "context"}
)


def _fail(where: str, message: str) -> None:
    raise ValidationError(f"{where}: {message}")


def _string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        _fail(where, "expected non-empty string")
    return value


def _text(value: Any, where: str) -> str:
    if not isinstance(value, str):
        _fail(where, "expected a string")
    return value


def _integer(value: Any, where: str, *, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        _fail(where, f"expected integer >= {minimum}")
    return value


def _hash(value: Any, where: str) -> str:
    result = _string(value, where).lower()
    if len(result) != 64 or any(ch not in "0123456789abcdef" for ch in result):
        _fail(where, "expected lowercase SHA-256 hex")
    return result


def _load_json_snapshot(path: Path, label: str) -> Tuple[Any, str, int]:
    def reject_duplicates(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                _fail(label, f"duplicate field {key!r}")
            result[key] = value
        return result

    try:
        source_bytes = path.read_bytes()
        value = json.loads(
            source_bytes.decode("utf-8"),
            object_pairs_hook=reject_duplicates,
        )
    except ValidationError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValidationError(f"cannot read {label} {path}: {exc}") from exc
    return value, hashlib.sha256(source_bytes).hexdigest(), len(source_bytes)


def _load_json_rejecting_duplicate_keys(path: Path, label: str) -> Any:
    return _load_json_snapshot(path, label)[0]


def load_source_policy(path: Path) -> Mapping[str, Any]:
    value = _load_json_rejecting_duplicate_keys(path, "HotpotQA source policy")
    if not isinstance(value, dict):
        _fail("HotpotQA source policy", "expected an object")
    return value


def _validate_source_policy(
    policy: Mapping[str, Any] | None,
    *,
    source_sha256: str,
) -> Dict[str, Mapping[str, Any]]:
    if policy is None:
        return {}
    expected_keys = {"schema_version", "dataset_sha256", "exclusions"}
    unknown = set(policy) - expected_keys
    missing = expected_keys - set(policy)
    if unknown:
        _fail("HotpotQA source policy", f"unknown fields: {sorted(unknown)}")
    if missing:
        _fail("HotpotQA source policy", f"missing fields: {sorted(missing)}")
    if policy["schema_version"] != SOURCE_POLICY_SCHEMA_VERSION:
        _fail(
            "HotpotQA source policy.schema_version",
            f"expected {SOURCE_POLICY_SCHEMA_VERSION}",
        )
    bound_sha = _hash(policy["dataset_sha256"], "HotpotQA source policy.dataset_sha256")
    if bound_sha != source_sha256:
        _fail(
            "HotpotQA source policy.dataset_sha256",
            f"expected {source_sha256!r}, observed {bound_sha!r}",
        )
    raw_exclusions = policy["exclusions"]
    if not isinstance(raw_exclusions, list) or not raw_exclusions:
        _fail("HotpotQA source policy.exclusions", "expected a non-empty array")
    result: Dict[str, Mapping[str, Any]] = {}
    exclusion_keys = {
        "source_id",
        "issue",
        "title",
        "sentence_id",
        "observed_sentence_count",
    }
    for index, raw in enumerate(raw_exclusions):
        where = f"HotpotQA source policy.exclusions[{index}]"
        if not isinstance(raw, dict):
            _fail(where, "expected an object")
        unknown = set(raw) - exclusion_keys
        missing = exclusion_keys - set(raw)
        if unknown:
            _fail(where, f"unknown fields: {sorted(unknown)}")
        if missing:
            _fail(where, f"missing fields: {sorted(missing)}")
        source_id = _string(raw["source_id"], f"{where}.source_id")
        if source_id in result:
            _fail(f"{where}.source_id", "duplicate quarantined source id")
        if raw["issue"] != "support_sentence_out_of_range":
            _fail(f"{where}.issue", "unsupported quarantine issue")
        _string(raw["title"], f"{where}.title")
        _integer(raw["sentence_id"], f"{where}.sentence_id")
        _integer(
            raw["observed_sentence_count"],
            f"{where}.observed_sentence_count",
            minimum=1,
        )
        result[source_id] = raw
    return result


def load_hotpot_records(
    path: Path,
    *,
    source_policy: Mapping[str, Any] | None = None,
) -> List[Mapping[str, Any]]:
    """Load and validate one official-shape HotpotQA JSON array."""

    raw, source_sha256, _ = _load_json_snapshot(path, "HotpotQA source")
    return _validate_hotpot_records(
        raw,
        source_sha256=source_sha256,
        source_policy=source_policy,
    )


def _validate_hotpot_records(
    raw: Any,
    *,
    source_sha256: str,
    source_policy: Mapping[str, Any] | None,
) -> List[Mapping[str, Any]]:
    if not isinstance(raw, list) or not raw:
        _fail("HotpotQA source", "expected a non-empty JSON array")
    exclusions = _validate_source_policy(source_policy, source_sha256=source_sha256)
    consumed_exclusions: set[str] = set()
    records: List[Mapping[str, Any]] = []
    seen_ids: set[str] = set()
    for index, item in enumerate(raw):
        where = f"HotpotQA source[{index}]"
        if not isinstance(item, dict):
            _fail(where, "expected an object")
        unknown = set(item) - REQUIRED_RECORD_KEYS
        missing = REQUIRED_RECORD_KEYS - set(item)
        if unknown:
            _fail(where, f"unknown fields: {sorted(unknown)}")
        if missing:
            _fail(where, f"missing fields: {sorted(missing)}")

        source_id = _string(item["_id"], f"{where}._id")
        if source_id in seen_ids:
            _fail(f"{where}._id", f"duplicate source id {source_id!r}")
        seen_ids.add(source_id)
        _string(item["question"], f"{where}.question")
        _string(item["answer"], f"{where}.answer")
        case_type = _string(item["type"], f"{where}.type")
        if case_type not in {"bridge", "comparison"}:
            _fail(f"{where}.type", f"unsupported HotpotQA type {case_type!r}")
        level = _string(item["level"], f"{where}.level")
        if level not in {"easy", "medium", "hard"}:
            _fail(f"{where}.level", f"unsupported HotpotQA level {level!r}")

        raw_context = item["context"]
        if not isinstance(raw_context, list) or not raw_context:
            _fail(f"{where}.context", "expected a non-empty array")
        context: Dict[str, List[str]] = {}
        for paragraph_index, raw_paragraph in enumerate(raw_context):
            paragraph_where = f"{where}.context[{paragraph_index}]"
            if not isinstance(raw_paragraph, list) or len(raw_paragraph) != 2:
                _fail(paragraph_where, "expected [title, sentences]")
            title = _string(raw_paragraph[0], f"{paragraph_where}[0]")
            if title in context:
                _fail(f"{paragraph_where}[0]", f"duplicate context title {title!r}")
            raw_sentences = raw_paragraph[1]
            if not isinstance(raw_sentences, list) or not raw_sentences:
                _fail(f"{paragraph_where}[1]", "expected a non-empty sentence array")
            sentences = [
                _text(sentence, f"{paragraph_where}[1][{sentence_index}]")
                for sentence_index, sentence in enumerate(raw_sentences)
            ]
            context[title] = sentences

        raw_supports = item["supporting_facts"]
        if not isinstance(raw_supports, list):
            _fail(f"{where}.supporting_facts", "expected an array")
        supports: set[Tuple[str, int]] = set()
        for support_index, raw_support in enumerate(raw_supports):
            support_where = f"{where}.supporting_facts[{support_index}]"
            if not isinstance(raw_support, list) or len(raw_support) != 2:
                _fail(support_where, "expected [title, sentence_id]")
            title = _string(raw_support[0], f"{support_where}[0]")
            sentence_id = _integer(raw_support[1], f"{support_where}[1]")
            if title not in context:
                _fail(support_where, f"support title {title!r} is absent from context")
            if sentence_id >= len(context[title]):
                exclusion = exclusions.get(source_id)
                observed = {
                    "source_id": source_id,
                    "issue": "support_sentence_out_of_range",
                    "title": title,
                    "sentence_id": sentence_id,
                    "observed_sentence_count": len(context[title]),
                }
                if exclusion != observed:
                    _fail(
                        f"{support_where}[1]",
                        f"sentence id {sentence_id} is out of range for {title!r}",
                    )
                consumed_exclusions.add(source_id)
                continue
            if not context[title][sentence_id].strip():
                _fail(support_where, "supporting fact text must not be empty")
            key = (title, sentence_id)
            if key in supports:
                _fail(support_where, "duplicate supporting fact")
            supports.add(key)
        if source_id in consumed_exclusions:
            continue
        if len(supports) < 2:
            _fail(f"{where}.supporting_facts", "expected at least two supporting facts")
        records.append(item)
    unused = sorted(set(exclusions) - consumed_exclusions)
    if unused:
        _fail(
            "HotpotQA source policy.exclusions",
            f"did not match an observed source defect: {unused}",
        )
    return records


def load_execution(path: Path) -> Mapping[str, Any]:
    """Load the execution block later validated as part of the full manifest."""

    value = _load_json_rejecting_duplicate_keys(path, "memory execution config")
    if not isinstance(value, dict):
        _fail("memory execution config", "expected an object")
    return value


def _selection_key(source_id: str, split_seed: int) -> Tuple[str, str]:
    digest = hashlib.sha256(f"{split_seed}\0{source_id}".encode("utf-8")).hexdigest()
    return digest, source_id


def select_records(
    records: Iterable[Mapping[str, Any]],
    *,
    limit: int,
    split_seed: int,
) -> List[Mapping[str, Any]]:
    if limit < 1:
        _fail("HotpotQA selection.limit", "expected integer >= 1")
    if split_seed < 0:
        _fail("HotpotQA selection.split_seed", "expected integer >= 0")
    materialized = list(records)
    if limit > len(materialized):
        _fail(
            "HotpotQA selection.limit",
            f"requested {limit} cases but source only contains {len(materialized)}",
        )
    return sorted(
        materialized,
        key=lambda row: _selection_key(str(row["_id"]), split_seed),
    )[:limit]


def _title_digest(title: str) -> str:
    return hashlib.sha256(title.encode("utf-8")).hexdigest()


def evidence_id(source_id: str, title: str, sentence_id: int) -> str:
    return f"hotpot:{source_id}:sentence:{_title_digest(title)}:{sentence_id}"


def title_id(source_id: str, title: str) -> str:
    return f"hotpot:{source_id}:title:{_title_digest(title)}"


def _normalize_case(record: Mapping[str, Any]) -> Mapping[str, Any]:
    source_id = str(record["_id"])
    documents: List[Mapping[str, Any]] = []
    all_evidence_ids: set[str] = set()
    for title, sentences in sorted(record["context"], key=lambda pair: str(pair[0])):
        normalized_sentences = []
        for sentence_id, text in enumerate(sentences):
            item_id = evidence_id(source_id, str(title), sentence_id)
            if item_id in all_evidence_ids:
                _fail(f"HotpotQA case {source_id}", f"evidence id collision {item_id!r}")
            all_evidence_ids.add(item_id)
            normalized_sentences.append(
                {
                    "id": item_id,
                    "sentence_id": sentence_id,
                    "text": text,
                }
            )
        documents.append(
            {
                "id": title_id(source_id, str(title)),
                "title": title,
                "sentences": normalized_sentences,
            }
        )
    return {
        "id": f"hotpot:{source_id}",
        "source_id": source_id,
        "question": record["question"],
        "type": record["type"],
        "level": record["level"],
        "documents": documents,
    }


def build_source_slice(
    selected: Sequence[Mapping[str, Any]],
    *,
    upstream_sha256: str,
    upstream_bytes: int,
    upstream_cases: int,
    source_url: str,
    source_revision: str,
    split_seed: int,
    source_policy: Mapping[str, Any] | None,
) -> Mapping[str, Any]:
    _hash(upstream_sha256, "HotpotQA upstream SHA-256")
    _integer(upstream_bytes, "HotpotQA upstream bytes")
    _integer(upstream_cases, "HotpotQA upstream cases", minimum=1)
    _string(source_url, "HotpotQA source URL")
    _string(source_revision, "HotpotQA source revision")
    normalized_cases = [_normalize_case(record) for record in selected]
    return {
        "schema_version": SOURCE_SLICE_SCHEMA_VERSION,
        "dataset_id": DATASET_ID,
        "adapter_id": ADAPTER_ID,
        "adapter_revision": ADAPTER_REVISION,
        "upstream": {
            "source_url": source_url,
            "source_revision": source_revision,
            "source_sha256": upstream_sha256,
            "source_bytes": upstream_bytes,
            "source_cases": upstream_cases,
        },
        "selection": {
            "algorithm": SELECTION_ALGORITHM,
            "split_seed": split_seed,
            "selected_cases": len(normalized_cases),
            "eligible_cases": upstream_cases - (
                len(source_policy["exclusions"]) if source_policy is not None else 0
            ),
            "excluded_cases": (
                len(source_policy["exclusions"]) if source_policy is not None else 0
            ),
        },
        "source_policy": source_policy,
        "cases": normalized_cases,
    }


def artifact_bytes(value: Any) -> bytes:
    return (stable_json(value) + "\n").encode("utf-8")


def _grader_fingerprint() -> str:
    contract = {
        "kind": "normalized_exact_match",
        "normalizer": "scripts.eval.memory_benchmark.normalized_exact_match-v1",
        "support_metric": "exact-evidence-id-set-v1",
    }
    return hashlib.sha256(stable_json(contract).encode("utf-8")).hexdigest()


def _schedule(
    cases: Sequence[Mapping[str, Any]],
    execution: Mapping[str, Any],
) -> List[Mapping[str, Any]]:
    raw_arms = execution.get("arms")
    raw_trials = execution.get("trials")
    if not isinstance(raw_arms, list) or not raw_arms:
        _fail("memory execution config.arms", "expected a non-empty array")
    if not isinstance(raw_trials, int) or isinstance(raw_trials, bool) or raw_trials < 1:
        _fail("memory execution config.trials", "expected integer >= 1")
    arm_ids = [arm.get("id") if isinstance(arm, dict) else None for arm in raw_arms]
    entries: List[Mapping[str, Any]] = []
    for case_index, case in enumerate(cases):
        for trial in range(raw_trials):
            rotation = (case_index + trial) % len(arm_ids)
            ordered_arms = arm_ids[rotation:] + arm_ids[:rotation]
            for arm_id in ordered_arms:
                entries.append(
                    {
                        "sequence": len(entries),
                        "case_id": case["id"],
                        "trial": trial,
                        "arm": arm_id,
                    }
                )
    return entries


def build_manifest(
    source_slice: Mapping[str, Any],
    execution: Mapping[str, Any],
    selected_records: Sequence[Mapping[str, Any]],
) -> Mapping[str, Any]:
    split_seed = source_slice["selection"]["split_seed"]
    if len(source_slice["cases"]) != len(selected_records):
        _fail("HotpotQA manifest", "source and hidden case counts disagree")
    cases: List[Mapping[str, Any]] = []
    for corpus_case, record in zip(source_slice["cases"], selected_records):
        source_id = str(record["_id"])
        if corpus_case["source_id"] != source_id:
            _fail("HotpotQA manifest", "source and hidden case order disagree")
        supports = {
            (str(title), int(sentence_id))
            for title, sentence_id in record["supporting_facts"]
        }
        expected = sorted(
            evidence_id(source_id, title, sentence_id)
            for title, sentence_id in supports
        )
        corpus_ids = {
            sentence["id"]
            for document in corpus_case["documents"]
            for sentence in document["sentences"]
        }
        if not set(expected).issubset(corpus_ids):
            _fail(f"HotpotQA case {source_id}", "support ids are not present in the corpus")
        cases.append(
            {
                "id": corpus_case["id"],
                "benchmark": "multihop_retrieval",
                "split": "test",
                "prompt": record["question"],
                "gold_answers": [record["answer"]],
                "expected_evidence_ids": expected,
                "grader": {
                    "kind": "normalized_exact_match",
                    "fingerprint": _grader_fingerprint(),
                },
                "family_id": None,
            }
        )
    source_sha256 = hashlib.sha256(artifact_bytes(source_slice)).hexdigest()
    manifest: Mapping[str, Any] = {
        "schema_version": REPLAY_SCHEMA_VERSION,
        "protocol_id": PROTOCOL_ID,
        "manifest_id": f"hotpotqa-distractor-{split_seed}-{len(cases)}",
        "dataset": {
            "id": DATASET_ID,
            "source_sha256": source_sha256,
            "adapter_id": ADAPTER_ID,
            "adapter_revision": ADAPTER_REVISION,
            "split_seed": split_seed,
        },
        "execution": dict(execution),
        "cases": cases,
        "schedule": _schedule(cases, execution),
    }
    validate_manifest(manifest)
    return manifest


def adapt_hotpot(
    source_path: Path,
    execution: Mapping[str, Any],
    *,
    expected_source_sha256: str,
    limit: int,
    split_seed: int,
    source_url: str = OFFICIAL_SOURCE_URL,
    source_revision: str = OFFICIAL_SOURCE_REVISION,
    source_policy: Mapping[str, Any] | None = None,
) -> Tuple[Mapping[str, Any], Mapping[str, Any]]:
    expected = _hash(expected_source_sha256, "expected HotpotQA source SHA-256")
    raw, actual, source_bytes = _load_json_snapshot(source_path, "HotpotQA source")
    if actual != expected:
        _fail(
            "HotpotQA source SHA-256",
            f"expected {expected!r}, observed {actual!r}",
        )
    records = _validate_hotpot_records(
        raw,
        source_sha256=actual,
        source_policy=source_policy,
    )
    excluded_count = len(source_policy["exclusions"]) if source_policy is not None else 0
    selected = select_records(records, limit=limit, split_seed=split_seed)
    source_slice = build_source_slice(
        selected,
        upstream_sha256=actual,
        upstream_bytes=source_bytes,
        upstream_cases=len(records) + excluded_count,
        source_url=source_url,
        source_revision=source_revision,
        split_seed=split_seed,
        source_policy=source_policy,
    )
    return source_slice, build_manifest(source_slice, execution, selected)
