"""Zero-provider E2 evaluation for governed project-Harness evolution.

This experiment is deliberately narrower than a model-quality benchmark.  It
proves that one transcript-backed user correction can traverse the production
candidate lifecycle, become the hash-pinned active bundle, block the real
dispatcher before a side effect, and leave an admitted recovery path.  A
separate process and this Python analyzer both reopen the evidence chain.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from typing import Any, Dict, List, Mapping, Sequence


MANIFEST_SCHEMA = "metacodes-project-harness-evolution-manifest-v2"
REPORT_SCHEMA = "metacodes-project-harness-evolution-report-v2"
PREPARE_SCHEMA = "metacodes-project-harness-lifecycle-prepare-v2"
FINAL_SCHEMA = "metacodes-project-harness-lifecycle-final-v2"
AUDIT_SCHEMA = "metacodes-project-harness-lifecycle-audit-v2"
BUILD_SCHEMA = "metacodes-project-rule-build-v1"
RUNTIME_CONTRACT_SCHEMA = "metacodes-project-harness-runtime-contract-v1"
RULE_FLAVORS = frozenset({"evolved", "static"})
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_JOURNAL_BYTES = 64 * 1024 * 1024
RUNTIME_SESSION_ID = "fedcba9876543210fedcba98"


class EvolutionError(RuntimeError):
    """Fail-closed experiment contract error."""


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _read_regular(path: Path, maximum: int) -> bytes:
    before_path = path.lstat()
    if not stat.S_ISREG(before_path.st_mode) or before_path.st_nlink != 1:
        raise EvolutionError(f"artifact must be a single-link regular file: {path}")
    if before_path.st_size < 0 or before_path.st_size > maximum:
        raise EvolutionError(f"artifact size is invalid: {path}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        before_fd = os.fstat(fd)
        expected = (before_fd.st_dev, before_fd.st_ino, before_fd.st_size)
        if not stat.S_ISREG(before_fd.st_mode) or before_fd.st_nlink != 1:
            raise EvolutionError(f"opened artifact is not trusted: {path}")
        if expected != (before_path.st_dev, before_path.st_ino, before_path.st_size):
            raise EvolutionError(f"artifact changed before open: {path}")
        chunks: List[bytes] = []
        remaining = before_fd.st_size
        while remaining:
            chunk = os.read(fd, min(1024 * 1024, remaining))
            if not chunk:
                raise EvolutionError(f"artifact truncated during read: {path}")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(fd, 1):
            raise EvolutionError(f"artifact grew during read: {path}")
        after_fd = os.fstat(fd)
    finally:
        os.close(fd)
    after_path = path.lstat()
    if (after_fd.st_dev, after_fd.st_ino, after_fd.st_size) != expected or (
        after_path.st_dev,
        after_path.st_ino,
        after_path.st_size,
    ) != expected:
        raise EvolutionError(f"artifact changed during read: {path}")
    return b"".join(chunks)


def _strict_json(raw: bytes, path: Path) -> Dict[str, Any]:
    def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise EvolutionError(f"duplicate JSON field in {path}: {key}")
            result[key] = value
        return result

    try:
        value = json.loads(
            raw,
            object_pairs_hook=object_pairs,
            parse_constant=lambda value: (_ for _ in ()).throw(
                EvolutionError(f"invalid JSON constant in {path}: {value}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise EvolutionError(f"invalid JSON artifact {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise EvolutionError(f"JSON artifact is not an object: {path}")
    return value


def _read_json(path: Path, maximum: int = MAX_JSON_BYTES) -> Dict[str, Any]:
    return _strict_json(_read_regular(path, maximum), path)


def _sha256_file(path: Path, maximum: int = MAX_JOURNAL_BYTES) -> str:
    return _sha256_bytes(_read_regular(path, maximum))


def _stable_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def _wire_json(value: Any) -> bytes:
    """Match Zig/Python lifecycle writers, which preserve declared key order."""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _fsync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _write_new(path: Path, value: Any) -> None:
    raw = _stable_json(value) + b"\n"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, 0o600)
    try:
        offset = 0
        while offset < len(raw):
            wrote = os.write(fd, raw[offset:])
            if wrote <= 0:
                raise EvolutionError(f"short write: {path}")
            offset += wrote
        os.fsync(fd)
    finally:
        os.close(fd)
    _fsync_directory(path.parent)


def _identity(value: Any, where: str) -> str:
    if not isinstance(value, str) or len(value) != 64 or any(
        char not in "0123456789abcdef" for char in value
    ):
        raise EvolutionError(f"{where} must be lower-case SHA-256")
    return value


def _project_identity(project_root: Path) -> str:
    return _sha256_bytes(
        b"metacodes-project-identity-v1\x00" + os.fsencode(str(project_root))
    )


def _inside(root: Path, child: Path) -> bool:
    try:
        child.resolve(strict=True).relative_to(root.resolve(strict=True))
        return True
    except (FileNotFoundError, ValueError):
        return False


def _git_identity(repo: Path) -> Mapping[str, Any]:
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout.strip()
    dirty = bool(
        subprocess.run(
            ["git", "status", "--porcelain", "--", "."],
            cwd=repo,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
    )
    return {"commit": commit, "dirty": dirty}


def freeze_manifest(
    repo: Path,
    root: Path,
    driver: Path,
    kernel: Path,
    lake: Path,
    builder: Path,
    *,
    project_root: Path | None = None,
    home_root: Path | None = None,
    rule_flavor: str = "evolved",
) -> Dict[str, Any]:
    repo = repo.resolve(strict=True)
    root = root.resolve(strict=True)
    if rule_flavor not in RULE_FLAVORS:
        raise EvolutionError(f"unsupported project rule flavor: {rule_flavor}")
    project_root = (project_root if project_root is not None else root / "project").resolve(
        strict=False
    )
    home_root = (home_root if home_root is not None else root / "home").resolve(
        strict=False
    )
    if not project_root.is_absolute() or not home_root.is_absolute():
        raise EvolutionError("runtime project/HOME paths must be absolute")
    if project_root != Path(os.path.normpath(str(project_root))):
        raise EvolutionError("runtime project path must use canonical lexical spelling")
    if home_root != root / "home":
        raise EvolutionError("runtime HOME must be the artifact-local home directory")
    artifacts = {
        "driver": driver.resolve(strict=True),
        "kernel": kernel.resolve(strict=True),
        "lake": lake.resolve(strict=True),
        "builder": builder.resolve(strict=True),
        "sdk_source": repo / "control-plane/lean/MetaCodesControl/ProjectRule.lean",
        "sdk_olean": repo / "control-plane/lean/.lake/build/lib/MetaCodesControl/ProjectRule.olean",
    }
    for name, path in artifacts.items():
        if not path.is_file():
            raise EvolutionError(f"missing frozen artifact {name}: {path}")
    return {
        "schema_version": MANIFEST_SCHEMA,
        "experiment_kind": "zero-provider-real-correction-to-production-lifecycle",
        "evidence_level": "E2",
        "quality_evidence": False,
        "outcome_superiority_claimed": False,
        "provider_mode": "none",
        "external_network_calls_authorized": 0,
        "paid_cost_authority_usd": 0,
        "raw_artifact_root": str(root),
        "runtime_contract": {
            "schema_version": RUNTIME_CONTRACT_SCHEMA,
            "rule_flavor": rule_flavor,
            "project_root": str(project_root),
            "home_root": str(home_root),
            "project_root_binding": "exact_absolute",
            "home_root_binding": "artifact_local_exact",
        },
        "repository": dict(_git_identity(repo)),
        "artifacts": {
            name: {"path": str(path), "sha256": _sha256_file(path)}
            for name, path in artifacts.items()
        },
        "phases": ["prepare", "isolated_build", "finalize", "independent_audit"],
        "claim_boundary": {
            "permitted": "a real correction traversed the governed production lifecycle",
            "forbidden": "model-task outcome superiority or memory-quality improvement",
        },
        "cache_claim": {
            "provider_visible_prefix_measured": False,
            "reason": "E2 makes no provider request; cache equality is an E3 gate",
        },
    }


def _journal_events(path: Path) -> List[Dict[str, Any]]:
    raw = _read_regular(path, MAX_JOURNAL_BYTES)
    records: List[Dict[str, Any]] = []
    for index, line in enumerate(raw.splitlines(keepends=True)):
        if not line.endswith(b"\n"):
            raise EvolutionError("runtime journal has a truncated record")
        record = _strict_json(line, path)
        if record.get("sequence") != index:
            raise EvolutionError("runtime journal sequence is not contiguous")
        records.append(record)
    if len(records) < 2 or "run_started" not in records[0].get("event", {}):
        raise EvolutionError("runtime journal does not start with run_started")
    if "run_finished" not in records[-1].get("event", {}):
        raise EvolutionError("runtime journal does not end with run_finished")
    return records


def _formal_or_dispatch(record: Mapping[str, Any]) -> tuple[str, Mapping[str, Any]] | None:
    event = record.get("event")
    if not isinstance(event, Mapping):
        return None
    formal = event.get("formal_decision")
    if isinstance(formal, Mapping):
        return "formal", formal
    observation = event.get("tool_observation")
    if isinstance(observation, Mapping):
        for name in ("dispatch_started", "dispatch_finished"):
            payload = observation.get(name)
            if isinstance(payload, Mapping):
                return name, payload
    return None


def analyze_lifecycle(manifest_path: Path) -> Dict[str, Any]:
    manifest = _read_json(manifest_path)
    if manifest.get("schema_version") != MANIFEST_SCHEMA:
        raise EvolutionError("unsupported evolution manifest")
    if (
        manifest.get("evidence_level") != "E2"
        or manifest.get("quality_evidence") is not False
        or manifest.get("outcome_superiority_claimed") is not False
        or manifest.get("provider_mode") != "none"
        or manifest.get("external_network_calls_authorized") != 0
        or manifest.get("paid_cost_authority_usd") != 0
    ):
        raise EvolutionError("manifest overclaims evidence or authorizes a provider")
    root = Path(str(manifest.get("raw_artifact_root", "")))
    if not root.is_absolute() or not _inside(root, manifest_path):
        raise EvolutionError("manifest/root binding drift")
    runtime_contract = manifest.get("runtime_contract")
    if not isinstance(runtime_contract, Mapping) or set(runtime_contract) != {
        "schema_version",
        "rule_flavor",
        "project_root",
        "home_root",
        "project_root_binding",
        "home_root_binding",
    }:
        raise EvolutionError("manifest runtime contract drift")
    rule_flavor = runtime_contract.get("rule_flavor")
    project_root = Path(str(runtime_contract.get("project_root", "")))
    home_root = Path(str(runtime_contract.get("home_root", "")))
    if (
        runtime_contract.get("schema_version") != RUNTIME_CONTRACT_SCHEMA
        or rule_flavor not in RULE_FLAVORS
        or runtime_contract.get("project_root_binding") != "exact_absolute"
        or runtime_contract.get("home_root_binding") != "artifact_local_exact"
        or not project_root.is_absolute()
        or not home_root.is_absolute()
        or project_root != Path(os.path.normpath(str(project_root)))
        or home_root != root / "home"
    ):
        raise EvolutionError("manifest runtime contract is invalid")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, Mapping):
        raise EvolutionError("manifest has no frozen artifacts")
    for name in ("driver", "kernel", "lake", "builder", "sdk_source", "sdk_olean"):
        item = artifacts.get(name)
        if not isinstance(item, Mapping):
            raise EvolutionError(f"manifest artifact missing: {name}")
        path = Path(str(item.get("path", "")))
        if _sha256_file(path) != _identity(item.get("sha256"), f"artifact {name}"):
            raise EvolutionError(f"frozen artifact drift: {name}")

    prepare_path = root / "lifecycle-prepare.json"
    final_path = root / "lifecycle-final.json"
    audit_path = root / "lifecycle-audit.json"
    prepare = _read_json(prepare_path)
    final = _read_json(final_path)
    audit = _read_json(audit_path)
    if prepare.get("schema_version") != PREPARE_SCHEMA or prepare.get("phase") != "prepare":
        raise EvolutionError("prepare result contract drift")
    if final.get("schema_version") != FINAL_SCHEMA or final.get("phase") != "finalize":
        raise EvolutionError("final result contract drift")
    if audit.get("schema_version") != AUDIT_SCHEMA or audit.get("phase") != "audit":
        raise EvolutionError("audit result contract drift")
    for name, value in (("prepare", prepare), ("final", final), ("audit", audit)):
        if value.get("quality_evidence") is not False or value.get("provider_requests") != 0 or value.get("paid_cost_usd") != 0:
            raise EvolutionError(f"{name} result overclaims evidence or provider usage")
    if final.get("outcome_superiority_claimed") is not False:
        raise EvolutionError("E2 result claimed E3 superiority")

    project = _identity(prepare.get("project_sha256"), "prepare.project_sha256")
    if project != _project_identity(project_root):
        raise EvolutionError("project identity does not bind the runtime project path")
    candidate = _identity(prepare.get("candidate_id"), "prepare.candidate_id")
    source = _identity(prepare.get("source_receipt_id"), "prepare.source_receipt_id")
    for name, value in (("final", final), ("audit", audit)):
        if _identity(value.get("candidate_id"), f"{name}.candidate_id") != candidate:
            raise EvolutionError("candidate identity drift")
    if final.get("project_sha256") != project or final.get("source_receipt_id") != source:
        raise EvolutionError("source/project identity drift")
    for key in ("promotion_receipt_id", "bundle_sha256", "runtime_journal_sha256"):
        if _identity(final.get(key), f"final.{key}") != _identity(audit.get(key), f"audit.{key}"):
            raise EvolutionError(f"independent audit identity drift: {key}")
    if not all(
        audit.get(key) is True
        for key in (
            "audit_passed",
            "source_is_host_bound",
            "lifecycle_chain_reopened",
            "active_bundle_reattested",
            "runtime_journal_reopened",
        )
    ):
        raise EvolutionError("independent audit did not pass every gate")
    if (
        final.get("source_kind") != "user_correction"
        or final.get("real_isolated_lean_build") is not True
        or final.get("synthetic_active_identity") is not False
        or prepare.get("rule_flavor") != rule_flavor
        or final.get("rule_flavor") != rule_flavor
        or audit.get("rule_flavor") != rule_flavor
        or final.get("runtime_blocked_before_dispatch") is not (rule_flavor == "evolved")
        or final.get("runtime_task_succeeded") is not True
        or final.get("runtime_recovery_succeeded") is not (rule_flavor == "evolved")
    ):
        raise EvolutionError("production lifecycle mechanism gate failed")

    session_dir = Path(str(prepare.get("session_dir", "")))
    rules_dir = Path(str(prepare.get("rules_dir", "")))
    candidate_path = Path(str(prepare.get("candidate_path", "")))
    if (
        Path(str(prepare.get("project_root", ""))) != project_root
        or Path(str(prepare.get("home_root", ""))) != home_root
    ):
        raise EvolutionError("prepare/runtime path contract drift")
    if project_root.resolve(strict=True) != project_root:
        raise EvolutionError("runtime project path is not canonical")
    for path in (home_root, session_dir, rules_dir, candidate_path):
        if not path.is_absolute() or not _inside(root, path):
            raise EvolutionError(f"lifecycle path escaped experiment root: {path}")
    state_root = session_dir.parent
    if (
        session_dir.name != "0123456789abcdef01234567"
        or rules_dir != state_root / "project-rules"
        or candidate_path.parent != session_dir
        or state_root.parent != home_root / ".metacodes/projects"
    ):
        raise EvolutionError("lifecycle state path topology drift")
    if candidate_path.name != f"rule-candidate-{candidate}.json":
        raise EvolutionError("candidate path identity drift")
    candidate_record = _read_json(candidate_path)
    candidate_body = candidate_record.get("body")
    if (
        candidate_record.get("candidate_id") != candidate
        or candidate_record.get("state") != "proposed"
        or not isinstance(candidate_body, Mapping)
        or _sha256_bytes(_wire_json(candidate_body)) != candidate
    ):
        raise EvolutionError("candidate artifact identity/state drift")
    source_path = session_dir / f"rule-source-receipt-{source}.json"
    source_record = _read_json(source_path)
    source_body = source_record.get("body")
    if not isinstance(source_body, Mapping):
        raise EvolutionError("source receipt body is missing")
    source_evidence = source_body.get("evidence")
    user_correction = source_evidence.get("user_correction") if isinstance(source_evidence, Mapping) else None
    issuer = _identity(prepare.get("issuer_sha256"), "prepare.issuer_sha256")
    proposer = _identity(prepare.get("proposer_sha256"), "prepare.proposer_sha256")
    correction = _identity(prepare.get("correction_sha256"), "prepare.correction_sha256")
    transcript_path = session_dir / "transcript.jsonl"
    transcript_raw = _read_regular(transcript_path, MAX_JSON_BYTES)
    transcript_lines = transcript_raw.splitlines(keepends=True)
    if (
        source_record.get("receipt_id") != source
        or _sha256_bytes(_wire_json(source_body)) != source
        or source_body.get("schema_version") != "metacodes-rule-source-receipt-v1"
        or source_body.get("project_sha256") != project
        or source_body.get("issuer_sha256") != issuer
        or source_body.get("issued_by_host") is not True
        or not isinstance(user_correction, Mapping)
        or user_correction.get("session_id") != "0123456789abcdef01234567"
        or user_correction.get("transcript_line_index") != 0
        or user_correction.get("correction_sha256") != correction
        or len(transcript_lines) != 1
        or not transcript_lines[0].endswith(b"\n")
        or _sha256_bytes(transcript_lines[0][:-1]) != user_correction.get("transcript_line_sha256")
        or _sha256_bytes(transcript_raw) != user_correction.get("transcript_prefix_sha256")
    ):
        raise EvolutionError("host correction/source receipt binding drift")

    build_manifest_path = root / "isolated-build/manifest.json"
    build_raw = _read_regular(build_manifest_path, MAX_JSON_BYTES)
    build = _strict_json(build_raw, build_manifest_path)
    if build.get("schema_version") != BUILD_SCHEMA or _sha256_bytes(build_raw) != final.get("build_manifest_sha256"):
        raise EvolutionError("isolated build manifest identity drift")
    if build.get("candidate_id") != candidate or build.get("project_sha256") != project:
        raise EvolutionError("isolated build source identity drift")
    if not all(
        build.get(key) is True
        for key in ("network_disabled", "secrets_absent", "source_bounded", "output_bounded", "completion_marker")
    ) or build.get("axiom_policy") != "empty" or build.get("unexpected_axiom_count") != 0:
        raise EvolutionError("isolated build/axiom policy failed")
    if build.get("toolchain_sha256") != artifacts["lake"].get("sha256") or build.get("sdk_sha256") != artifacts["sdk_source"].get("sha256") or build.get("sdk_olean_sha256") != artifacts["sdk_olean"].get("sha256"):
        raise EvolutionError("isolated build used an unfrozen toolchain/SDK")

    receipt_keys = (
        "build_receipt_id",
        "axiom_receipt_id",
        "replay_receipt_id",
        "shadow_receipt_id",
        "promotion_receipt_id",
    )
    expected_evidence = ("built", "axiom_audited", "replay_passed", "shadow_passed", "promoted")
    receipt_ids = [_identity(final.get(key), f"final.{key}") for key in receipt_keys]
    actors: List[str] = []
    for index, (receipt_id, evidence_name) in enumerate(zip(receipt_ids, expected_evidence)):
        receipt_path = session_dir / f"rule-stage-receipt-{receipt_id}.json"
        receipt = _read_json(receipt_path)
        body = receipt.get("body")
        if (
            receipt.get("receipt_id") != receipt_id
            or not isinstance(body, Mapping)
            or _sha256_bytes(_wire_json(body)) != receipt_id
        ):
            raise EvolutionError("lifecycle receipt envelope drift")
        predecessor = body.get("predecessor_receipt_id")
        expected_predecessor = None if index == 0 else receipt_ids[index - 1]
        evidence = body.get("evidence")
        if (
            body.get("schema_version") != "metacodes-rule-stage-receipt-v2"
            or body.get("candidate_id") != candidate
            or body.get("project_sha256") != project
            or predecessor != expected_predecessor
            or not isinstance(evidence, Mapping)
            or set(evidence) != {evidence_name}
        ):
            raise EvolutionError("lifecycle receipt chain drift")
        actor = _identity(body.get("actor_sha256"), "lifecycle.actor_sha256")
        if actor == proposer or actor in actors:
            raise EvolutionError("lifecycle actor independence failed")
        actors.append(actor)

    active = _read_json(rules_dir / "active.json")
    active_body = active.get("body")
    if not isinstance(active_body, Mapping):
        raise EvolutionError("active pointer body is missing")
    if (
        active.get("pointer_sha256") != final.get("active_pointer_sha256")
        or _sha256_bytes(_wire_json(active_body)) != active.get("pointer_sha256")
        or active_body.get("schema_version") != "metacodes-project-rule-active-v2"
        or active_body.get("project_sha256") != project
        or active_body.get("bundle_sha256") != final.get("bundle_sha256")
        or active_body.get("revision") != final.get("bundle_revision")
        or active_body.get("kernel_sha256") != artifacts["kernel"].get("sha256")
        or active_body.get("promotion_receipt_id") != receipt_ids[-1]
        or active_body.get("promotion_request_sha256") != final.get("promotion_request_sha256")
        or active_body.get("promotion_verdict_sha256") != final.get("promotion_verdict_sha256")
    ):
        raise EvolutionError("active pointer identity drift")
    bundle_id = _identity(final.get("bundle_sha256"), "final.bundle_sha256")
    bundle = _read_json(rules_dir / f"project-rule-bundle-{bundle_id}.json")
    bundle_body = bundle.get("body")
    if not isinstance(bundle_body, Mapping):
        raise EvolutionError("active bundle body is missing")
    rules = bundle_body.get("rules")
    if (
        bundle.get("bundle_sha256") != bundle_id
        or _sha256_bytes(_wire_json(bundle_body)) != bundle_id
        or bundle_body.get("schema_version") != "metacodes-project-rule-bundle-v2"
        or bundle_body.get("project_sha256") != project
        or bundle_body.get("revision") != final.get("bundle_revision")
        or bundle_body.get("kernel_sha256") != artifacts["kernel"].get("sha256")
        or not isinstance(rules, list)
        or len(rules) != 1
        or not isinstance(rules[0], Mapping)
        or rules[0].get("candidate_id") != candidate
    ):
        raise EvolutionError("active bundle identity drift")

    runtime_dir = state_root / RUNTIME_SESSION_ID
    journal_path = runtime_dir / "tool-observations.jsonl"
    if _sha256_file(journal_path) != final.get("runtime_journal_sha256"):
        raise EvolutionError("runtime journal identity drift")
    events = _journal_events(journal_path)
    runtime_binding = final.get("runtime_run")
    session_ids = {record.get("session_id") for record in events}
    run_ids = {record.get("run_id") for record in events}
    if (
        not isinstance(runtime_binding, Mapping)
        or runtime_binding.get("session_id") != RUNTIME_SESSION_ID
        or session_ids != {runtime_binding.get("session_id")}
        or run_ids != {runtime_binding.get("run_id")}
        or runtime_binding.get("first_sequence") != 0
        or runtime_binding.get("last_sequence") != len(events) - 1
        or runtime_binding.get("interval_sha256") != final.get("runtime_journal_sha256")
    ):
        raise EvolutionError("runtime Run binding drift")
    dispatch_starts: List[Mapping[str, Any]] = []
    dispatch_finishes: List[Mapping[str, Any]] = []
    formal: List[Mapping[str, Any]] = []
    for record in events:
        event = record.get("event")
        observation = event.get("tool_observation") if isinstance(event, Mapping) else None
        if not isinstance(observation, Mapping):
            continue
        started = observation.get("dispatch_started")
        finished = observation.get("dispatch_finished")
        if isinstance(started, Mapping):
            dispatch_starts.append(started)
        if isinstance(finished, Mapping):
            dispatch_finishes.append(finished)
        batch = observation.get("formal_decision_batch")
        if isinstance(batch, Mapping):
            decisions = batch.get("decisions")
            if not isinstance(decisions, list) or not decisions:
                raise EvolutionError("runtime emitted an empty formal batch")
            for decision in decisions:
                if not isinstance(decision, Mapping):
                    raise EvolutionError("runtime emitted a malformed formal decision")
                formal.append({**decision, **batch, "_sequence": record["sequence"]})
        single = observation.get("formal_decision")
        if isinstance(single, Mapping):
            formal.append({**single, "_sequence": record["sequence"]})
    if (
        [item.get("id") for item in dispatch_starts] != ["runtime-write"]
        or [item.get("id") for item in dispatch_finishes] != ["runtime-write"]
    ):
        raise EvolutionError("runtime dispatch identity drift")
    expected_formal_count = 3 if rule_flavor == "evolved" else 2
    if len(formal) != expected_formal_count:
        raise EvolutionError("runtime formal-decision count drift")
    kernel_sha = _identity(artifacts["kernel"].get("sha256"), "kernel.sha256")
    for item in formal:
        if (
            item.get("project_sha256") != project
            or item.get("bundle_sha256") != bundle_id
            or item.get("bundle_revision") != final.get("bundle_revision")
            or item.get("kernel_sha256") != kernel_sha
            or item.get("checker_batch_size") != 1
            or item.get("checker_failure") is not None
            or item.get("actuation") != "enforced"
        ):
            raise EvolutionError("runtime formal-decision identity drift")
        for key in (
            "checker_call_sha256",
            "checker_verdict_sha256",
            "request_sha256",
            "verdict_sha256",
        ):
            _identity(item.get(key), f"formal.{key}")
    rewrite_started = dispatch_starts[0]
    rewrite_finished = dispatch_finishes[0]
    start_sequence = next(
        record["sequence"] for record in events
        if (_formal_or_dispatch(record) or (None, None))[0] == "dispatch_started"
    )
    finish_sequence = next(
        record["sequence"] for record in events
        if (_formal_or_dispatch(record) or (None, None))[0] == "dispatch_finished"
    )
    if rule_flavor == "evolved":
        expected_tool = "Edit"
        expected_decisions = (
            ("pre_decision", "pre", "block", "edit_existing_file_exact"),
            ("recovery_pre_decision", "pre", "admit", "none"),
            ("recovery_post_decision", "post", "admit", "none"),
        )
    else:
        expected_tool = "Write"
        expected_decisions = (
            ("pre_decision", "pre", "admit", "none"),
            ("post_decision", "post", "admit", "none"),
        )
    matched_decisions: List[Mapping[str, Any]] = []
    for operation, phase, result, recovery_action in expected_decisions:
        matches = [
            item for item in formal
            if item.get("dispatch_id") == "runtime-write"
            and item.get("operation") == operation
            and item.get("phase") == phase
            and item.get("result") == result
            and item.get("recovery_action") == recovery_action
            and item.get("candidate_id") == candidate
        ]
        if len(matches) != 1:
            raise EvolutionError("runtime formal-decision result drift")
        matched_decisions.append(matches[0])
    decision_sequences = [item["_sequence"] for item in matched_decisions]
    expected_order = (
        [decision_sequences[0], decision_sequences[1], start_sequence, decision_sequences[2], finish_sequence]
        if rule_flavor == "evolved"
        else [decision_sequences[0], start_sequence, decision_sequences[1], finish_sequence]
    )
    if expected_order != sorted(expected_order) or len(set(expected_order)) != len(expected_order):
        raise EvolutionError("formal gate/dispatch causal ordering drift")
    effect = rewrite_finished.get("effect")
    mutation_v2 = effect.get("file_mutation_v2") if isinstance(effect, Mapping) else None
    mutation = mutation_v2.get("mutation") if isinstance(mutation_v2, Mapping) else None
    reobservation = mutation_v2.get("reobservation") if isinstance(mutation_v2, Mapping) else None
    if (
        rewrite_started.get("requested_name") != "Write"
        or rewrite_started.get("dispatched_name") != expected_tool
        or rewrite_finished.get("requested_name") != "Write"
        or rewrite_finished.get("dispatched_name") != expected_tool
        or rewrite_finished.get("outcome") != "succeeded"
        or rewrite_finished.get("effect_valid") is not True
        or not isinstance(mutation, Mapping)
        or mutation.get("change") != "changed"
        or not isinstance(reobservation, Mapping)
        or reobservation.get("state") != "matched"
    ):
        raise EvolutionError("Lean-authorized dispatch lacks a successful reobserved effect")
    if _read_regular(project_root / "protected.txt", 1024) != b"new":
        raise EvolutionError("admitted host rewrite did not recover the real file")

    gates = {
        "real_transcript_backed_user_correction": True,
        "typed_candidate_identity_preserved": True,
        "isolated_lean_build_and_empty_axiom_audit": True,
        "replay_shadow_promotion_chain_reopened": True,
        "hash_pinned_active_bundle_reattested": True,
        "runtime_contract_and_rule_flavor_matched": True,
        "independent_process_audit_passed": True,
        "provider_requests_zero": True,
    }
    if rule_flavor == "evolved":
        gates.update({
            "write_blocked_before_dispatch": True,
            "lean_authorized_host_rewrite_reobserved": True,
        })
    else:
        gates.update({
            "bounded_write_admitted_by_static_rule": True,
            "static_write_effect_reobserved": True,
        })
    return {
        "schema_version": REPORT_SCHEMA,
        "manifest_sha256": _sha256_file(manifest_path),
        "evidence_level": "E2",
        "quality_evidence": False,
        "outcome_superiority_claimed": False,
        "rule_flavor": rule_flavor,
        "evolution_lifecycle_passed": all(gates.values()),
        "gates": gates,
        "candidate_id": candidate,
        "project_root": str(project_root),
        "source_receipt_id": source,
        "promotion_receipt_id": final["promotion_receipt_id"],
        "bundle_sha256": final["bundle_sha256"],
        "runtime_journal_sha256": final["runtime_journal_sha256"],
        "boundaries": [
            "zero provider requests: model-task benefit and cache reuse are unmeasured",
            "one correction family proves lifecycle wiring, not semantic generalization",
            "filesystem locking/fsync semantics are native assumptions tested outside Lean",
        ],
    }


def _run(
    argv: Sequence[str],
    cwd: Path,
    env: Mapping[str, str],
    timeout: int = 120,
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        argv,
        cwd=cwd,
        env=dict(env),
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )


def run_evolution(
    repo: Path,
    root: Path,
    driver: Path,
    kernel: Path,
    lake: Path,
    builder: Path,
    *,
    project_root: Path | None = None,
    home_root: Path | None = None,
    rule_flavor: str = "evolved",
) -> Dict[str, Any]:
    repo = repo.resolve(strict=True)
    root = root.absolute()
    if root.exists() and any(root.iterdir()):
        raise EvolutionError("experiment root must be absent or empty")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    root_info = root.lstat()
    if not stat.S_ISDIR(root_info.st_mode) or root_info.st_uid != os.getuid():
        raise EvolutionError("experiment root must be an owned real directory")
    os.chmod(root, 0o700)
    # Keep the spelling passed to Seatbelt, the native driver, and the
    # analyzer identical (`/var` is a symlink to `/private/var` on macOS).
    root = root.resolve(strict=True)
    project_root = (project_root if project_root is not None else root / "project").resolve(
        strict=False
    )
    home_root = (home_root if home_root is not None else root / "home").resolve(
        strict=False
    )
    manifest = freeze_manifest(
        repo,
        root,
        driver,
        kernel,
        lake,
        builder,
        project_root=project_root,
        home_root=home_root,
        rule_flavor=rule_flavor,
    )
    manifest_path = root / "manifest.json"
    _write_new(manifest_path, manifest)
    frozen = manifest["artifacts"]
    kernel_path = str(frozen["kernel"]["path"])
    kernel_sha = str(frozen["kernel"]["sha256"])
    base_env = {
        "PATH": os.defpath,
        "TMPDIR": tempfile.gettempdir(),
        "LANG": "C",
        "LC_ALL": "C",
        "TZ": "UTC",
        "METACODES_PROJECT_KERNEL_PATH": kernel_path,
        "METACODES_PROJECT_KERNEL_SHA256": kernel_sha,
    }
    driver_path = str(frozen["driver"]["path"])
    runtime_args = [
        "--root", str(root),
        "--project-root", str(project_root),
        "--home-root", str(home_root),
        "--rule-flavor", rule_flavor,
    ]
    _run([driver_path, "--phase", "prepare", *runtime_args], repo, base_env)
    prepare = _read_json(root / "lifecycle-prepare.json")
    candidate_path = Path(str(prepare.get("candidate_path", "")))
    candidate_id = _identity(prepare.get("candidate_id"), "prepare.candidate_id")
    if not _inside(root, candidate_path):
        raise EvolutionError("candidate path escaped experiment root")
    build_dir = root / "isolated-build"
    _run(
        [
            sys.executable,
            str(frozen["builder"]["path"]),
            "--repo",
            str(repo),
            "--candidate",
            str(candidate_path),
            "--candidate-id",
            candidate_id,
            "--out",
            str(build_dir),
            "--lake",
            str(frozen["lake"]["path"]),
        ],
        repo,
        {"PATH": os.defpath, "TMPDIR": tempfile.gettempdir(), "LANG": "C", "LC_ALL": "C", "TZ": "UTC"},
    )
    common = [
        *runtime_args,
        "--repo",
        str(repo),
        "--build-dir",
        str(build_dir),
        "--lake",
        str(frozen["lake"]["path"]),
        "--kernel",
        kernel_path,
        "--kernel-sha256",
        kernel_sha,
    ]
    _run([driver_path, "--phase", "finalize", *common], repo, base_env)
    # This is intentionally a second process, not a helper call inside finalize.
    _run([driver_path, "--phase", "audit", *common], repo, base_env)
    report = analyze_lifecycle(manifest_path)
    if not report["evolution_lifecycle_passed"]:
        raise EvolutionError("E2 evolution lifecycle gates failed")
    _write_new(root / "report.json", report)
    return report


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    run.add_argument("--repo", type=Path, required=True)
    run.add_argument("--root", type=Path, required=True)
    run.add_argument("--driver", type=Path, required=True)
    run.add_argument("--kernel", type=Path, required=True)
    run.add_argument("--lake", type=Path, required=True)
    run.add_argument("--builder", type=Path, required=True)
    run.add_argument("--project-root", type=Path)
    run.add_argument("--home-root", type=Path)
    run.add_argument("--rule-flavor", choices=sorted(RULE_FLAVORS), default="evolved")
    analyze = sub.add_parser("analyze")
    analyze.add_argument("--manifest", type=Path, required=True)
    analyze.add_argument("--output", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "run":
            report = run_evolution(
                args.repo,
                args.root,
                args.driver,
                args.kernel,
                args.lake,
                args.builder,
                project_root=args.project_root,
                home_root=args.home_root,
                rule_flavor=args.rule_flavor,
            )
        else:
            report = analyze_lifecycle(args.manifest)
            _write_new(args.output, report)
    except (EvolutionError, OSError, subprocess.SubprocessError) as exc:
        print(f"project-Harness evolution evaluation failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
