"""Freeze cleaned LongMemEval-S for ``memory-maturation-v1``.

The emitted corpus deliberately strips ``answer``, ``answer_session_ids`` and
turn-level ``has_answer`` labels.  The separate replay manifest owns those
hidden labels.  Raw question ids are hashed before they are used in corpus or
result ids so the public ``_abs`` suffix cannot reveal an abstention case to a
memory implementation.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import re
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Tuple

from .memory_benchmark import PROTOCOL_ID, qa_execution_prompt
from .memory_replay import REPLAY_SCHEMA_VERSION, validate_manifest
from .model import ValidationError, stable_json


ADAPTER_ID = "longmemeval-s-cleaned"
ADAPTER_REVISION = "official-cleaned-session-v3-final-answer-contract"
DATASET_ID = "longmemeval-s-cleaned"
SOURCE_SLICE_SCHEMA_VERSION = 1
SELECTION_ALGORITHM = "sha256-seed-null-question-id-v1"
OFFICIAL_SOURCE_URL = (
    "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/"
    "resolve/98d7416c24c778c2fee6e6f3006e7a073259d48f/longmemeval_s_cleaned.json"
)
OFFICIAL_SOURCE_REVISION = "98d7416c24c778c2fee6e6f3006e7a073259d48f"
QUESTION_TYPES = frozenset(
    {
        "single-session-user",
        "single-session-assistant",
        "single-session-preference",
        "temporal-reasoning",
        "knowledge-update",
        "multi-session",
    }
)
REQUIRED_RECORD_KEYS = frozenset(
    {
        "question_id",
        "question_type",
        "question",
        "answer",
        "question_date",
        "haystack_session_ids",
        "haystack_dates",
        "haystack_sessions",
        "answer_session_ids",
    }
)
DATE_RE = re.compile(r"^\d{4}/\d{2}/\d{2} \([A-Z][a-z]{2}\) \d{2}:\d{2}$")


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


def _hash(value: Any, where: str) -> str:
    result = _string(value, where).lower()
    if len(result) != 64 or any(ch not in "0123456789abcdef" for ch in result):
        _fail(where, "expected lowercase SHA-256 hex")
    return result


def _answer_text(value: Any, where: str) -> str:
    if isinstance(value, str) and value.strip():
        return value
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    _fail(where, "expected a non-empty string or integer")


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


def load_execution(path: Path) -> Mapping[str, Any]:
    value, _, _ = _load_json_snapshot(path, "memory execution config")
    if not isinstance(value, dict):
        _fail("memory execution config", "expected an object")
    return value


def _parse_date(value: Any, where: str) -> dt.datetime:
    text = _string(value, where)
    if DATE_RE.fullmatch(text) is None:
        _fail(where, "expected YYYY/MM/DD (Ddd) HH:MM")
    try:
        parsed = dt.datetime.strptime(text, "%Y/%m/%d (%a) %H:%M")
    except ValueError as exc:
        raise ValidationError(f"{where}: invalid timestamp {text!r}: {exc}") from exc
    if parsed.strftime("%a") != text[12:15]:
        _fail(where, "weekday does not match calendar date")
    return parsed


def _validate_records(raw: Any) -> List[Mapping[str, Any]]:
    if not isinstance(raw, list) or not raw:
        _fail("LongMemEval-S source", "expected a non-empty JSON array")
    records: List[Mapping[str, Any]] = []
    seen_question_ids: set[str] = set()
    for index, item in enumerate(raw):
        where = f"LongMemEval-S source[{index}]"
        if not isinstance(item, dict):
            _fail(where, "expected an object")
        unknown = set(item) - REQUIRED_RECORD_KEYS
        missing = REQUIRED_RECORD_KEYS - set(item)
        if unknown:
            _fail(where, f"unknown fields: {sorted(unknown)}")
        if missing:
            _fail(where, f"missing fields: {sorted(missing)}")

        question_id = _string(item["question_id"], f"{where}.question_id")
        if question_id in seen_question_ids:
            _fail(f"{where}.question_id", f"duplicate question id {question_id!r}")
        seen_question_ids.add(question_id)
        question_type = _string(item["question_type"], f"{where}.question_type")
        if question_type not in QUESTION_TYPES:
            _fail(f"{where}.question_type", f"unsupported category {question_type!r}")
        _string(item["question"], f"{where}.question")
        _answer_text(item["answer"], f"{where}.answer")
        _parse_date(item["question_date"], f"{where}.question_date")

        session_ids = item["haystack_session_ids"]
        dates = item["haystack_dates"]
        sessions = item["haystack_sessions"]
        if not all(isinstance(value, list) for value in (session_ids, dates, sessions)):
            _fail(where, "haystack session ids, dates, and contents must be arrays")
        if not session_ids or len({len(session_ids), len(dates), len(sessions)}) != 1:
            _fail(where, "haystack arrays must be non-empty and length aligned")

        occurrence_count: Dict[str, int] = {}
        for session_index, (raw_session_id, raw_date, raw_session) in enumerate(
            zip(session_ids, dates, sessions)
        ):
            session_where = f"{where}.haystack_sessions[{session_index}]"
            session_id = _string(
                raw_session_id,
                f"{where}.haystack_session_ids[{session_index}]",
            )
            occurrence_count[session_id] = occurrence_count.get(session_id, 0) + 1
            # LongMemEval uses question_date as a temporal reasoning reference,
            # not a strict event cutoff.  The cleaned set intentionally has
            # same-day sessions whose clock time is later than question_date.
            _parse_date(raw_date, f"{where}.haystack_dates[{session_index}]")
            if not isinstance(raw_session, list) or not raw_session:
                _fail(session_where, "expected a non-empty turn array")
            for turn_index, turn in enumerate(raw_session):
                turn_where = f"{session_where}[{turn_index}]"
                if not isinstance(turn, dict):
                    _fail(turn_where, "expected an object")
                allowed_turn_keys = {"role", "content", "has_answer"}
                unknown_turn = set(turn) - allowed_turn_keys
                missing_turn = {"role", "content"} - set(turn)
                if unknown_turn:
                    _fail(turn_where, f"unknown fields: {sorted(unknown_turn)}")
                if missing_turn:
                    _fail(turn_where, f"missing fields: {sorted(missing_turn)}")
                role = _string(turn["role"], f"{turn_where}.role")
                if role not in {"user", "assistant"}:
                    _fail(f"{turn_where}.role", "must be user or assistant")
                _text(turn["content"], f"{turn_where}.content")
                if "has_answer" in turn and not isinstance(turn["has_answer"], bool):
                    _fail(f"{turn_where}.has_answer", "expected boolean")

        answer_session_ids = item["answer_session_ids"]
        if not isinstance(answer_session_ids, list) or not answer_session_ids:
            _fail(f"{where}.answer_session_ids", "expected a non-empty array")
        seen_answer_ids: set[str] = set()
        for answer_index, raw_answer_id in enumerate(answer_session_ids):
            answer_id = _string(
                raw_answer_id,
                f"{where}.answer_session_ids[{answer_index}]",
            )
            if answer_id in seen_answer_ids:
                _fail(f"{where}.answer_session_ids[{answer_index}]", "duplicate evidence session")
            seen_answer_ids.add(answer_id)
            count = occurrence_count.get(answer_id, 0)
            if count != 1:
                _fail(
                    f"{where}.answer_session_ids[{answer_index}]",
                    f"expected exactly one matching history session, observed {count}",
                )
        records.append(item)
    return records


def load_longmem_records(path: Path) -> List[Mapping[str, Any]]:
    raw, _, _ = _load_json_snapshot(path, "LongMemEval-S source")
    return _validate_records(raw)


def _selection_key(question_id: str, split_seed: int) -> Tuple[str, str]:
    digest = hashlib.sha256(f"{split_seed}\0{question_id}".encode("utf-8")).hexdigest()
    return digest, question_id


def select_records(
    records: Iterable[Mapping[str, Any]],
    *,
    limit: int,
    split_seed: int,
) -> List[Mapping[str, Any]]:
    if not isinstance(limit, int) or isinstance(limit, bool) or limit < 1:
        _fail("LongMemEval-S selection.limit", "expected integer >= 1")
    if not isinstance(split_seed, int) or isinstance(split_seed, bool) or split_seed < 0:
        _fail("LongMemEval-S selection.split_seed", "expected integer >= 0")
    materialized = list(records)
    if limit > len(materialized):
        _fail(
            "LongMemEval-S selection.limit",
            f"requested {limit} cases but source only contains {len(materialized)}",
        )
    return sorted(
        materialized,
        key=lambda row: _selection_key(str(row["question_id"]), split_seed),
    )[:limit]


def _question_digest(question_id: str) -> str:
    return hashlib.sha256(question_id.encode("utf-8")).hexdigest()


def _case_id(record: Mapping[str, Any]) -> str:
    return f"longmem:{record['question_type']}:{_question_digest(str(record['question_id']))[:32]}"


def _session_id(question_digest: str, position: int, source_session_id: str) -> str:
    session_digest = hashlib.sha256(source_session_id.encode("utf-8")).hexdigest()
    return f"longmem:{question_digest}:session:{position}:{session_digest}"


def _normalize_case(record: Mapping[str, Any]) -> Mapping[str, Any]:
    question_digest = _question_digest(str(record["question_id"]))
    sessions: List[Mapping[str, Any]] = []
    for position, (source_session_id, date, raw_turns) in enumerate(
        zip(
            record["haystack_session_ids"],
            record["haystack_dates"],
            record["haystack_sessions"],
        )
    ):
        session_id = _session_id(question_digest, position, str(source_session_id))
        turns = [
            {
                "id": f"{session_id}:turn:{turn_index}",
                "turn_index": turn_index,
                "role": turn["role"],
                "content": turn["content"],
            }
            for turn_index, turn in enumerate(raw_turns)
        ]
        sessions.append(
            {
                "id": session_id,
                "source_position": position,
                "date": date,
                "turns": turns,
            }
        )
    return {
        "id": _case_id(record),
        "source_id_sha256": question_digest,
        "question_type": record["question_type"],
        "question": record["question"],
        "question_date": record["question_date"],
        "sessions": sessions,
    }


def artifact_bytes(value: Any) -> bytes:
    return (stable_json(value) + "\n").encode("utf-8")


def build_source_slice(
    selected: Sequence[Mapping[str, Any]],
    *,
    upstream_sha256: str,
    upstream_bytes: int,
    upstream_cases: int,
    source_url: str,
    source_revision: str,
    split_seed: int,
) -> Mapping[str, Any]:
    return {
        "schema_version": SOURCE_SLICE_SCHEMA_VERSION,
        "dataset_id": DATASET_ID,
        "adapter_id": ADAPTER_ID,
        "adapter_revision": ADAPTER_REVISION,
        "upstream": {
            "source_url": _string(source_url, "LongMemEval-S source URL"),
            "source_revision": _string(source_revision, "LongMemEval-S source revision"),
            "source_sha256": _hash(upstream_sha256, "LongMemEval-S source SHA-256"),
            "source_bytes": upstream_bytes,
            "source_cases": upstream_cases,
        },
        "selection": {
            "algorithm": SELECTION_ALGORITHM,
            "split_seed": split_seed,
            "selected_cases": len(selected),
        },
        "cases": [_normalize_case(record) for record in selected],
    }


def _grader_fingerprint() -> str:
    contract = {
        "kind": "normalized_exact_match",
        "normalizer": "scripts.eval.memory_benchmark.normalized_exact_match-v1",
        "secondary": "token-f1-v1",
        "evidence_unit": "session-id-v1",
    }
    return hashlib.sha256(stable_json(contract).encode("utf-8")).hexdigest()


def _schedule(cases: Sequence[Mapping[str, Any]], execution: Mapping[str, Any]) -> List[Mapping[str, Any]]:
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
    if len(source_slice["cases"]) != len(selected_records):
        _fail("LongMemEval-S manifest", "source and hidden case counts disagree")
    cases: List[Mapping[str, Any]] = []
    for corpus_case, record in zip(source_slice["cases"], selected_records):
        if corpus_case["id"] != _case_id(record):
            _fail("LongMemEval-S manifest", "source and hidden case order disagree")
        question_digest = _question_digest(str(record["question_id"]))
        positions: Dict[str, int] = {
            str(source_id): position
            for position, source_id in enumerate(record["haystack_session_ids"])
        }
        # The official cleaned set supplies answer_session_ids for abstention
        # cases too.  They are relevant near-miss sessions that justify a
        # refusal even though no turn is labeled has_answer=true.
        expected = sorted(
            _session_id(question_digest, positions[str(source_id)], str(source_id))
            for source_id in record["answer_session_ids"]
        )
        corpus_session_ids = {session["id"] for session in corpus_case["sessions"]}
        if not set(expected).issubset(corpus_session_ids):
            _fail("LongMemEval-S manifest", "evidence ids are absent from the corpus")
        cases.append(
            {
                "id": corpus_case["id"],
                "benchmark": "episodic_recall",
                "split": "test",
                "prompt": qa_execution_prompt(
                    f"Question date: {record['question_date']}\n"
                    f"Question: {record['question']}"
                ),
                "gold_answers": [
                    _answer_text(record["answer"], "LongMemEval-S manifest answer")
                ],
                "expected_evidence_ids": expected,
                "grader": {
                    "kind": "normalized_exact_match",
                    "fingerprint": _grader_fingerprint(),
                },
                "family_id": None,
            }
        )
    split_seed = source_slice["selection"]["split_seed"]
    manifest: Mapping[str, Any] = {
        "schema_version": REPLAY_SCHEMA_VERSION,
        "protocol_id": PROTOCOL_ID,
        "manifest_id": f"longmemeval-s-cleaned-{split_seed}-{len(cases)}",
        "dataset": {
            "id": DATASET_ID,
            "source_sha256": hashlib.sha256(artifact_bytes(source_slice)).hexdigest(),
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


def adapt_longmem(
    source_path: Path,
    execution: Mapping[str, Any],
    *,
    expected_source_sha256: str,
    limit: int,
    split_seed: int,
    source_url: str = OFFICIAL_SOURCE_URL,
    source_revision: str = OFFICIAL_SOURCE_REVISION,
) -> Tuple[Mapping[str, Any], Mapping[str, Any]]:
    expected = _hash(expected_source_sha256, "expected LongMemEval-S source SHA-256")
    raw, actual, source_bytes = _load_json_snapshot(source_path, "LongMemEval-S source")
    if actual != expected:
        _fail(
            "LongMemEval-S source SHA-256",
            f"expected {expected!r}, observed {actual!r}",
        )
    records = _validate_records(raw)
    selected = select_records(records, limit=limit, split_seed=split_seed)
    source_slice = build_source_slice(
        selected,
        upstream_sha256=actual,
        upstream_bytes=source_bytes,
        upstream_cases=len(records),
        source_url=source_url,
        source_revision=source_revision,
        split_seed=split_seed,
    )
    return source_slice, build_manifest(source_slice, execution, selected)
