"""Freeze coding intent families for procedural-memory transfer.

The raw dataset is host-owned.  It contains baseline workspaces, deterministic
validators, and oracle file replacements used only to prove that each validator
rejects the baseline and accepts one known solution.  The adapter emits three
separate artifacts:

* a public source slice with prompts and materializable baseline workspaces;
* a host-only validator bundle with no oracle solution; and
* the ordinary memory replay manifest with a causal online-before-offline
  schedule.

No model, shell, network, or TinyKG process is used by this adapter.
"""

from __future__ import annotations

import hashlib
import json
import re
import string
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Tuple

from .memory_benchmark import PROTOCOL_ID
from .memory_replay import REPLAY_SCHEMA_VERSION, validate_manifest
from .model import ValidationError, stable_json


ADAPTER_ID = "coding-intent-families"
ADAPTER_REVISION = "workspace-validator-family-v1"
SOURCE_SCHEMA_VERSION = 1
SOURCE_SLICE_SCHEMA_VERSION = 1
VALIDATOR_BUNDLE_SCHEMA_VERSION = 1
SELECTION_ALGORITHM = "sha256-seed-null-family-id-v1"
VALIDATOR_KIND = "workspace_assertions_v1"
CHECK_KINDS = frozenset({"contains", "not_contains", "equals"})
IDENTIFIER = re.compile(r"^[a-z0-9][a-z0-9_.:-]{0,127}$")


def _fail(where: str, message: str) -> None:
    raise ValidationError(f"{where}: {message}")


def _object(value: Any, where: str, keys: Iterable[str]) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        _fail(where, "expected an object")
    expected = frozenset(keys)
    missing = expected - set(value)
    unknown = set(value) - expected
    if missing:
        _fail(where, f"missing fields: {sorted(missing)}")
    if unknown:
        _fail(where, f"unknown fields: {sorted(unknown)}")
    return value


def _string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        _fail(where, "expected non-empty string")
    return value


def _text(value: Any, where: str) -> str:
    if not isinstance(value, str):
        _fail(where, "expected a string")
    return value


def _identifier(value: Any, where: str) -> str:
    result = _string(value, where)
    if IDENTIFIER.fullmatch(result) is None:
        _fail(where, "expected a stable lowercase identifier")
    return result


def _integer(value: Any, where: str, *, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        _fail(where, f"expected integer >= {minimum}")
    return value


def _hash(value: Any, where: str) -> str:
    result = _string(value, where).lower()
    if len(result) != 64 or any(ch not in "0123456789abcdef" for ch in result):
        _fail(where, "expected lowercase SHA-256 hex")
    return result


def _canonical_sha256(value: Any) -> str:
    return hashlib.sha256(stable_json(value).encode("utf-8")).hexdigest()


def artifact_bytes(value: Any) -> bytes:
    return (stable_json(value) + "\n").encode("utf-8")


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
    value, _, _ = _load_json_snapshot(path, "procedural execution config")
    if not isinstance(value, dict):
        _fail("procedural execution config", "expected an object")
    return value


def _workspace_path(value: Any, where: str) -> str:
    path = _string(value, where)
    if "\\" in path or len(path.encode("utf-8")) > 240:
        _fail(where, "expected a short POSIX relative path")
    parsed = PurePosixPath(path)
    if parsed.is_absolute() or not parsed.parts or any(part in {"", ".", ".."} for part in parsed.parts):
        _fail(where, "path must stay inside the materialized workspace")
    return path


def _sorted_unique_paths(value: Any, where: str, *, allow_empty: bool = False) -> List[str]:
    if not isinstance(value, list):
        _fail(where, "expected an array")
    result = [_workspace_path(item, f"{where}[{index}]") for index, item in enumerate(value)]
    if not allow_empty and not result:
        _fail(where, "must not be empty")
    if result != sorted(result):
        _fail(where, "paths must use canonical sorted order")
    if len(set(result)) != len(result):
        _fail(where, "paths must not contain duplicates")
    return result


def _workspace_files(value: Any, where: str) -> Dict[str, str]:
    workspace = _object(value, where, ("files",))
    raw_files = workspace["files"]
    if not isinstance(raw_files, list) or not raw_files:
        _fail(f"{where}.files", "expected a non-empty array")
    result: Dict[str, str] = {}
    previous = ""
    for index, raw_file in enumerate(raw_files):
        file_where = f"{where}.files[{index}]"
        item = _object(raw_file, file_where, ("path", "content"))
        path = _workspace_path(item["path"], f"{file_where}.path")
        if path <= previous:
            _fail(f"{file_where}.path", "files must use unique canonical sorted order")
        previous = path
        result[path] = _text(item["content"], f"{file_where}.content")
    return result


def workspace_fingerprint(files: Mapping[str, str]) -> str:
    normalized = [
        {
            "path": path,
            "content_sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
            "bytes": len(content.encode("utf-8")),
        }
        for path, content in sorted(files.items())
    ]
    return _canonical_sha256({"format": "inline-files-v1", "files": normalized})


def _public_workspace(files: Mapping[str, str]) -> Mapping[str, Any]:
    return {
        "format": "inline-files-v1",
        "fingerprint": workspace_fingerprint(files),
        "files": [
            {
                "path": path,
                "content": content,
                "sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
            }
            for path, content in sorted(files.items())
        ],
    }


def _validator(value: Any, where: str, workspace_paths: set[str]) -> Mapping[str, Any]:
    validator = _object(
        value,
        where,
        ("kind", "allowed_changed_paths", "required_changed_paths", "checks"),
    )
    if validator["kind"] != VALIDATOR_KIND:
        _fail(f"{where}.kind", f"expected {VALIDATOR_KIND!r}")
    allowed = _sorted_unique_paths(
        validator["allowed_changed_paths"],
        f"{where}.allowed_changed_paths",
    )
    required = _sorted_unique_paths(
        validator["required_changed_paths"],
        f"{where}.required_changed_paths",
    )
    if not set(allowed).issubset(workspace_paths):
        _fail(f"{where}.allowed_changed_paths", "references a file absent from the baseline workspace")
    if not set(required).issubset(set(allowed)):
        _fail(f"{where}.required_changed_paths", "must be a subset of allowed_changed_paths")
    raw_checks = validator["checks"]
    if not isinstance(raw_checks, list) or not raw_checks:
        _fail(f"{where}.checks", "expected a non-empty array")
    checks: List[Mapping[str, str]] = []
    seen_checks: set[Tuple[str, str, str]] = set()
    for index, raw_check in enumerate(raw_checks):
        check_where = f"{where}.checks[{index}]"
        check = _object(raw_check, check_where, ("kind", "path", "value"))
        kind = _string(check["kind"], f"{check_where}.kind")
        if kind not in CHECK_KINDS:
            _fail(f"{check_where}.kind", f"unsupported check {kind!r}")
        path = _workspace_path(check["path"], f"{check_where}.path")
        if path not in workspace_paths:
            _fail(f"{check_where}.path", "references a file absent from the baseline workspace")
        expected = _text(check["value"], f"{check_where}.value")
        if kind != "equals" and not expected:
            _fail(f"{check_where}.value", "substring checks require non-empty text")
        key = (kind, path, expected)
        if key in seen_checks:
            _fail(check_where, "duplicate validator check")
        seen_checks.add(key)
        checks.append({"kind": kind, "path": path, "value": expected})
    return {
        "kind": VALIDATOR_KIND,
        "allowed_changed_paths": allowed,
        "required_changed_paths": required,
        "checks": checks,
    }


def evaluate_workspace(
    baseline: Mapping[str, str],
    candidate: Mapping[str, str],
    validator: Mapping[str, Any],
) -> Tuple[bool, List[str]]:
    """Evaluate a candidate without a shell, network, or model judge."""

    failures: List[str] = []
    baseline_paths = set(baseline)
    candidate_paths = set(candidate)
    if candidate_paths != baseline_paths:
        missing = sorted(baseline_paths - candidate_paths)
        added = sorted(candidate_paths - baseline_paths)
        failures.append(f"workspace file set changed: missing={missing}, added={added}")
    changed = {
        path
        for path in baseline_paths & candidate_paths
        if baseline[path] != candidate[path]
    }
    allowed = set(validator["allowed_changed_paths"])
    required = set(validator["required_changed_paths"])
    unexpected = sorted(changed - allowed)
    unchanged_required = sorted(required - changed)
    if unexpected:
        failures.append(f"changed paths outside validator allowance: {unexpected}")
    if unchanged_required:
        failures.append(f"required paths were not changed: {unchanged_required}")
    for index, check in enumerate(validator["checks"]):
        path = check["path"]
        if path not in candidate:
            failures.append(f"check[{index}] cannot read missing path {path!r}")
            continue
        content = candidate[path]
        expected = check["value"]
        if check["kind"] == "contains" and expected not in content:
            failures.append(f"check[{index}] expected {path!r} to contain pinned text")
        elif check["kind"] == "not_contains" and expected in content:
            failures.append(f"check[{index}] expected {path!r} to omit pinned text")
        elif check["kind"] == "equals" and content != expected:
            failures.append(f"check[{index}] expected exact pinned contents for {path!r}")
    return not failures, failures


def _oracle_candidate(
    value: Any,
    where: str,
    baseline: Mapping[str, str],
    allowed: set[str],
) -> Dict[str, str]:
    if not isinstance(value, list) or not value:
        _fail(where, "expected a non-empty array")
    result = dict(baseline)
    seen: set[str] = set()
    previous = ""
    for index, raw_file in enumerate(value):
        file_where = f"{where}[{index}]"
        item = _object(raw_file, file_where, ("path", "content"))
        path = _workspace_path(item["path"], f"{file_where}.path")
        if path <= previous or path in seen:
            _fail(f"{file_where}.path", "oracle files must use unique canonical sorted order")
        previous = path
        seen.add(path)
        if path not in baseline:
            _fail(f"{file_where}.path", "oracle cannot add a new workspace file")
        if path not in allowed:
            _fail(f"{file_where}.path", "oracle changes a path outside validator allowance")
        result[path] = _text(item["content"], f"{file_where}.content")
    return result


def _template_fields(template: str, where: str) -> List[str]:
    fields: List[str] = []
    try:
        for _, field, format_spec, conversion in string.Formatter().parse(template):
            if field is None:
                continue
            if not field or format_spec or conversion or not field.isidentifier():
                _fail(where, "template fields must be plain Python identifiers")
            fields.append(field)
    except ValueError as exc:
        raise ValidationError(f"{where}: invalid format template: {exc}") from exc
    if not fields:
        _fail(where, "intent template must contain at least one binding")
    if len(set(fields)) != len(fields):
        _fail(where, "intent template fields must not repeat")
    return fields


def _bindings(value: Any, where: str, fields: Sequence[str]) -> Mapping[str, str]:
    if not isinstance(value, dict):
        _fail(where, "expected an object")
    if set(value) != set(fields):
        _fail(where, f"expected exactly template bindings {sorted(fields)}")
    return {field: _string(value[field], f"{where}.{field}") for field in sorted(fields)}


def _task_contract(
    *,
    family_id: str,
    case_id: str,
    split: str,
    template: str,
    bindings: Mapping[str, str],
    prompt: str,
    workspace_sha256: str,
) -> Mapping[str, Any]:
    return _task_contract_from_template_hash(
        family_id=family_id,
        case_id=case_id,
        split=split,
        intent_template_sha256=hashlib.sha256(template.encode("utf-8")).hexdigest(),
        bindings=bindings,
        prompt=prompt,
        workspace_sha256=workspace_sha256,
    )


def _task_contract_from_template_hash(
    *,
    family_id: str,
    case_id: str,
    split: str,
    intent_template_sha256: str,
    bindings: Mapping[str, str],
    prompt: str,
    workspace_sha256: str,
) -> Mapping[str, Any]:
    return {
        "family_id": family_id,
        "case_id": case_id,
        "split": split,
        "intent_template_sha256": intent_template_sha256,
        "bindings": dict(bindings),
        "prompt": prompt,
        "workspace_sha256": workspace_sha256,
    }


def _grader_contract(
    task_fingerprint: str,
    workspace_sha256: str,
    validator: Mapping[str, Any],
) -> Mapping[str, Any]:
    return {
        "kind": "deterministic_validator",
        "revision": VALIDATOR_KIND,
        "task_fingerprint": task_fingerprint,
        "workspace_sha256": workspace_sha256,
        "validator": validator,
    }


def _validate_source(raw: Any) -> Mapping[str, Any]:
    source = _object(
        raw,
        "procedural source",
        ("schema_version", "dataset_id", "dataset_revision", "families"),
    )
    if source["schema_version"] != SOURCE_SCHEMA_VERSION:
        _fail("procedural source.schema_version", f"expected {SOURCE_SCHEMA_VERSION}")
    dataset_id = _identifier(source["dataset_id"], "procedural source.dataset_id")
    dataset_revision = _string(source["dataset_revision"], "procedural source.dataset_revision")
    raw_families = source["families"]
    if not isinstance(raw_families, list) or not raw_families:
        _fail("procedural source.families", "expected a non-empty array")
    normalized_families: List[Mapping[str, Any]] = []
    seen_families: set[str] = set()
    seen_cases: set[str] = set()
    seen_evidence_ids: set[str] = set()
    for family_index, raw_family in enumerate(raw_families):
        family_where = f"procedural source.families[{family_index}]"
        family = _object(
            raw_family,
            family_where,
            ("id", "intent_template", "procedure_evidence_id", "cases"),
        )
        family_id = _identifier(family["id"], f"{family_where}.id")
        if family_id in seen_families:
            _fail(f"{family_where}.id", "duplicate family")
        seen_families.add(family_id)
        template = _string(family["intent_template"], f"{family_where}.intent_template")
        fields = _template_fields(template, f"{family_where}.intent_template")
        evidence_id = _identifier(
            family["procedure_evidence_id"],
            f"{family_where}.procedure_evidence_id",
        )
        if evidence_id in seen_evidence_ids:
            _fail(f"{family_where}.procedure_evidence_id", "duplicate procedure evidence id")
        seen_evidence_ids.add(evidence_id)
        raw_cases = family["cases"]
        if not isinstance(raw_cases, list) or len(raw_cases) < 3:
            _fail(f"{family_where}.cases", "expected one online and at least two offline siblings")
        cases: List[Mapping[str, Any]] = []
        split_counts = {"online": 0, "offline": 0}
        for case_index, raw_case in enumerate(raw_cases):
            case_where = f"{family_where}.cases[{case_index}]"
            case = _object(
                raw_case,
                case_where,
                ("id", "split", "bindings", "workspace", "validator", "oracle_files"),
            )
            local_case_id = _identifier(case["id"], f"{case_where}.id")
            case_id = f"coding:{family_id}:{local_case_id}"
            if case_id in seen_cases:
                _fail(f"{case_where}.id", "duplicate case")
            seen_cases.add(case_id)
            split = _string(case["split"], f"{case_where}.split")
            if split not in split_counts:
                _fail(f"{case_where}.split", "must be online or offline")
            split_counts[split] += 1
            bindings = _bindings(case["bindings"], f"{case_where}.bindings", fields)
            try:
                prompt = template.format_map(bindings)
            except (KeyError, ValueError) as exc:
                raise ValidationError(f"{case_where}.bindings: cannot render intent template: {exc}") from exc
            _string(prompt, f"{case_where}.prompt")
            baseline = _workspace_files(case["workspace"], f"{case_where}.workspace")
            validator = _validator(
                case["validator"],
                f"{case_where}.validator",
                set(baseline),
            )
            oracle = _oracle_candidate(
                case["oracle_files"],
                f"{case_where}.oracle_files",
                baseline,
                set(validator["allowed_changed_paths"]),
            )
            baseline_passed, _ = evaluate_workspace(baseline, baseline, validator)
            if baseline_passed:
                _fail(f"{case_where}.validator", "baseline already passes; task is not discriminating")
            oracle_passed, oracle_failures = evaluate_workspace(baseline, oracle, validator)
            if not oracle_passed:
                _fail(
                    f"{case_where}.oracle_files",
                    f"known solution fails deterministic validator: {oracle_failures}",
                )
            workspace_sha256 = workspace_fingerprint(baseline)
            task_contract = _task_contract(
                family_id=family_id,
                case_id=case_id,
                split=split,
                template=template,
                bindings=bindings,
                prompt=prompt,
                workspace_sha256=workspace_sha256,
            )
            task_fingerprint = _canonical_sha256(task_contract)
            grader_contract = _grader_contract(task_fingerprint, workspace_sha256, validator)
            cases.append(
                {
                    "id": case_id,
                    "local_id": local_case_id,
                    "split": split,
                    "bindings": bindings,
                    "prompt": prompt,
                    "baseline": baseline,
                    "workspace_sha256": workspace_sha256,
                    "task_fingerprint": task_fingerprint,
                    "validator": validator,
                    "grader_fingerprint": _canonical_sha256(grader_contract),
                    "oracle_sha256": workspace_fingerprint(oracle),
                }
            )
        if split_counts != {"online": 1, "offline": len(cases) - 1}:
            _fail(
                f"{family_where}.cases",
                "family must contain exactly one online and at least two offline siblings",
            )
        normalized_families.append(
            {
                "id": family_id,
                "intent_template": template,
                "intent_template_sha256": hashlib.sha256(template.encode("utf-8")).hexdigest(),
                "procedure_evidence_id": evidence_id,
                "cases": cases,
            }
        )
    return {
        "dataset_id": dataset_id,
        "dataset_revision": dataset_revision,
        "families": normalized_families,
    }


def _selection_key(family_id: str, split_seed: int) -> Tuple[str, str]:
    digest = hashlib.sha256(f"{split_seed}\0{family_id}".encode("utf-8")).hexdigest()
    return digest, family_id


def select_families(
    families: Iterable[Mapping[str, Any]],
    *,
    limit_families: int,
    split_seed: int,
) -> List[Mapping[str, Any]]:
    _integer(limit_families, "procedural selection.limit_families", minimum=1)
    _integer(split_seed, "procedural selection.split_seed")
    materialized = list(families)
    if limit_families > len(materialized):
        _fail(
            "procedural selection.limit_families",
            f"requested {limit_families} families but source only contains {len(materialized)}",
        )
    return sorted(
        materialized,
        key=lambda family: _selection_key(str(family["id"]), split_seed),
    )[:limit_families]


def _ordered_cases(family: Mapping[str, Any]) -> List[Mapping[str, Any]]:
    return sorted(
        family["cases"],
        key=lambda case: (0 if case["split"] == "online" else 1, str(case["id"])),
    )


def _schedule(
    families: Sequence[Mapping[str, Any]],
    execution: Mapping[str, Any],
) -> List[Mapping[str, Any]]:
    raw_arms = execution.get("arms")
    trials = execution.get("trials")
    if not isinstance(raw_arms, list) or not raw_arms:
        _fail("procedural execution config.arms", "expected a non-empty array")
    if not isinstance(trials, int) or isinstance(trials, bool) or trials < 1:
        _fail("procedural execution config.trials", "expected integer >= 1")
    arm_ids = [arm.get("id") if isinstance(arm, dict) else None for arm in raw_arms]
    entries: List[Mapping[str, Any]] = []
    case_offset = 0
    for family in families:
        ordered_cases = _ordered_cases(family)
        for trial in range(trials):
            for case_index, case in enumerate(ordered_cases):
                rotation = (case_offset + case_index + trial) % len(arm_ids)
                for arm_id in arm_ids[rotation:] + arm_ids[:rotation]:
                    entries.append(
                        {
                            "sequence": len(entries),
                            "case_id": case["id"],
                            "trial": trial,
                            "arm": arm_id,
                        }
                    )
        case_offset += len(ordered_cases)
    return entries


def _build_source_slice(
    selected: Sequence[Mapping[str, Any]],
    *,
    dataset_id: str,
    dataset_revision: str,
    upstream_sha256: str,
    upstream_bytes: int,
    upstream_families: int,
    split_seed: int,
) -> Mapping[str, Any]:
    return {
        "schema_version": SOURCE_SLICE_SCHEMA_VERSION,
        "dataset_id": dataset_id,
        "adapter_id": ADAPTER_ID,
        "adapter_revision": ADAPTER_REVISION,
        "upstream": {
            "source_revision": dataset_revision,
            "source_sha256": upstream_sha256,
            "source_bytes": upstream_bytes,
            "source_families": upstream_families,
        },
        "selection": {
            "algorithm": SELECTION_ALGORITHM,
            "split_seed": split_seed,
            "selected_families": len(selected),
            "selected_cases": sum(len(family["cases"]) for family in selected),
        },
        "families": [
            {
                "id": family["id"],
                "intent_template_sha256": family["intent_template_sha256"],
                "procedure_evidence_id": family["procedure_evidence_id"],
                "cases": [
                    {
                        "id": case["id"],
                        "split": case["split"],
                        "prompt": case["prompt"],
                        "bindings": dict(case["bindings"]),
                        "task_fingerprint": case["task_fingerprint"],
                        "validator_fingerprint": case["grader_fingerprint"],
                        "workspace": _public_workspace(case["baseline"]),
                    }
                    for case in _ordered_cases(family)
                ],
            }
            for family in selected
        ],
    }


def _build_validator_bundle(
    selected: Sequence[Mapping[str, Any]],
    source_slice_sha256: str,
) -> Mapping[str, Any]:
    return {
        "schema_version": VALIDATOR_BUNDLE_SCHEMA_VERSION,
        "adapter_id": ADAPTER_ID,
        "adapter_revision": ADAPTER_REVISION,
        "dataset_source_sha256": source_slice_sha256,
        "cases": [
            {
                "case_id": case["id"],
                "family_id": family["id"],
                "split": case["split"],
                "task_fingerprint": case["task_fingerprint"],
                "workspace_sha256": case["workspace_sha256"],
                "validator": case["validator"],
                "grader_fingerprint": case["grader_fingerprint"],
            }
            for family in selected
            for case in _ordered_cases(family)
        ],
    }


def validate_validator_bundle(
    bundle: Mapping[str, Any],
    source_slice: Mapping[str, Any],
    where: str = "procedural validator bundle",
) -> None:
    value = _object(
        bundle,
        where,
        ("schema_version", "adapter_id", "adapter_revision", "dataset_source_sha256", "cases"),
    )
    if value["schema_version"] != VALIDATOR_BUNDLE_SCHEMA_VERSION:
        _fail(f"{where}.schema_version", f"expected {VALIDATOR_BUNDLE_SCHEMA_VERSION}")
    if value["adapter_id"] != ADAPTER_ID or value["adapter_revision"] != ADAPTER_REVISION:
        _fail(where, "adapter identity mismatch")
    expected_source_sha256 = hashlib.sha256(artifact_bytes(source_slice)).hexdigest()
    if _hash(value["dataset_source_sha256"], f"{where}.dataset_source_sha256") != expected_source_sha256:
        _fail(f"{where}.dataset_source_sha256", "does not bind the public source slice")
    public_cases = {
        case["id"]: (family, case)
        for family in source_slice["families"]
        for case in family["cases"]
    }
    raw_cases = value["cases"]
    if not isinstance(raw_cases, list) or len(raw_cases) != len(public_cases):
        _fail(f"{where}.cases", f"expected exactly {len(public_cases)} cases")
    seen: set[str] = set()
    for index, raw_case in enumerate(raw_cases):
        case_where = f"{where}.cases[{index}]"
        case = _object(
            raw_case,
            case_where,
            (
                "case_id",
                "family_id",
                "split",
                "task_fingerprint",
                "workspace_sha256",
                "validator",
                "grader_fingerprint",
            ),
        )
        case_id = _identifier(case["case_id"], f"{case_where}.case_id")
        if case_id in seen or case_id not in public_cases:
            _fail(f"{case_where}.case_id", "duplicate or unknown case")
        seen.add(case_id)
        public_family, public = public_cases[case_id]
        task_fingerprint = _hash(case["task_fingerprint"], f"{case_where}.task_fingerprint")
        workspace_sha256 = _hash(case["workspace_sha256"], f"{case_where}.workspace_sha256")
        grader_fingerprint = _hash(case["grader_fingerprint"], f"{case_where}.grader_fingerprint")
        public_files: Dict[str, str] = {}
        previous_path = ""
        for file_index, raw_file in enumerate(public["workspace"]["files"]):
            file_where = f"public workspace for {case_id}.files[{file_index}]"
            file_item = _object(raw_file, file_where, ("path", "content", "sha256"))
            path = _workspace_path(file_item["path"], f"{file_where}.path")
            if path <= previous_path or path in public_files:
                _fail(f"{file_where}.path", "files must use unique canonical sorted order")
            previous_path = path
            content = _text(file_item["content"], f"{file_where}.content")
            content_sha256 = hashlib.sha256(content.encode("utf-8")).hexdigest()
            if _hash(file_item["sha256"], f"{file_where}.sha256") != content_sha256:
                _fail(f"{file_where}.sha256", "does not match public file contents")
            public_files[path] = content
        recomputed_workspace = workspace_fingerprint(public_files)
        if _hash(public["workspace"]["fingerprint"], f"public workspace for {case_id}.fingerprint") != recomputed_workspace:
            _fail(f"public workspace for {case_id}.fingerprint", "does not match public files")
        if task_fingerprint != public["task_fingerprint"]:
            _fail(f"{case_where}.task_fingerprint", "does not match public task identity")
        if workspace_sha256 != recomputed_workspace:
            _fail(f"{case_where}.workspace_sha256", "does not match public workspace")
        if grader_fingerprint != public["validator_fingerprint"]:
            _fail(f"{case_where}.grader_fingerprint", "does not match public validator identity")
        validator = _validator(
            case["validator"],
            f"{case_where}.validator",
            {item["path"] for item in public["workspace"]["files"]},
        )
        expected_grader = _canonical_sha256(
            _grader_contract(task_fingerprint, workspace_sha256, validator)
        )
        if grader_fingerprint != expected_grader:
            _fail(f"{case_where}.grader_fingerprint", "validator contents do not match fingerprint")
        if case["split"] != public["split"]:
            _fail(f"{case_where}.split", "does not match public split")
        family_id = _identifier(case["family_id"], f"{case_where}.family_id")
        if family_id != public_family["id"]:
            _fail(f"{case_where}.family_id", "does not match public family")
        expected_task = _canonical_sha256(
            _task_contract_from_template_hash(
                family_id=family_id,
                case_id=case_id,
                split=case["split"],
                intent_template_sha256=_hash(
                    public_family["intent_template_sha256"],
                    f"public family {family_id}.intent_template_sha256",
                ),
                bindings=public["bindings"],
                prompt=_string(public["prompt"], f"public case {case_id}.prompt"),
                workspace_sha256=recomputed_workspace,
            )
        )
        if task_fingerprint != expected_task:
            _fail(f"{case_where}.task_fingerprint", "public task fields do not match fingerprint")
    if seen != set(public_cases):
        _fail(f"{where}.cases", "missing public cases")


def _build_manifest(
    selected: Sequence[Mapping[str, Any]],
    execution: Mapping[str, Any],
    source_slice_sha256: str,
    *,
    dataset_id: str,
    split_seed: int,
) -> Mapping[str, Any]:
    cases = [
        {
            "id": case["id"],
            "benchmark": "procedural_transfer",
            "split": case["split"],
            "prompt": case["prompt"],
            "gold_answers": [],
            "expected_evidence_ids": (
                [] if case["split"] == "online" else [family["procedure_evidence_id"]]
            ),
            "grader": {
                "kind": "deterministic_validator",
                "fingerprint": case["grader_fingerprint"],
            },
            "family_id": family["id"],
        }
        for family in selected
        for case in _ordered_cases(family)
    ]
    manifest: Mapping[str, Any] = {
        "schema_version": REPLAY_SCHEMA_VERSION,
        "protocol_id": PROTOCOL_ID,
        "manifest_id": f"coding-intent-families-{split_seed}-{len(selected)}",
        "dataset": {
            "id": dataset_id,
            "source_sha256": source_slice_sha256,
            "adapter_id": ADAPTER_ID,
            "adapter_revision": ADAPTER_REVISION,
            "split_seed": split_seed,
        },
        "execution": dict(execution),
        "cases": cases,
        "schedule": _schedule(selected, execution),
    }
    validate_manifest(manifest)
    return manifest


def adapt_procedural(
    source_path: Path,
    execution: Mapping[str, Any],
    *,
    expected_source_sha256: str,
    limit_families: int,
    split_seed: int,
) -> Tuple[Mapping[str, Any], Mapping[str, Any], Mapping[str, Any]]:
    expected = _hash(expected_source_sha256, "expected procedural source SHA-256")
    raw, actual, source_bytes = _load_json_snapshot(source_path, "procedural source")
    if actual != expected:
        _fail(
            "procedural source SHA-256",
            f"expected {expected!r}, observed {actual!r}",
        )
    source = _validate_source(raw)
    selected = select_families(
        source["families"],
        limit_families=limit_families,
        split_seed=split_seed,
    )
    source_slice = _build_source_slice(
        selected,
        dataset_id=source["dataset_id"],
        dataset_revision=source["dataset_revision"],
        upstream_sha256=actual,
        upstream_bytes=source_bytes,
        upstream_families=len(source["families"]),
        split_seed=split_seed,
    )
    source_slice_sha256 = hashlib.sha256(artifact_bytes(source_slice)).hexdigest()
    validator_bundle = _build_validator_bundle(selected, source_slice_sha256)
    validate_validator_bundle(validator_bundle, source_slice)
    manifest = _build_manifest(
        selected,
        execution,
        source_slice_sha256,
        dataset_id=source["dataset_id"],
        split_seed=split_seed,
    )
    return source_slice, validator_bundle, manifest
