#!/usr/bin/env python3
"""Executable Lean + telemetry + Zig feedback control plane for repository rules."""

from __future__ import annotations

import argparse
import ast
from dataclasses import asdict, dataclass, field
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any, Iterable, Sequence


SCHEMA_VERSION = 1
DEFAULT_MANIFEST = Path("control-plane/rules.json")
DEFAULT_REPORT = Path("zig-out/reports/rule-control.json")
LOOP_LINKS = ("target", "sensor", "decision", "actuator", "feedback", "counterexample")
SUPPORTED_SENSOR_ADAPTERS = frozenset(
    (
        "declaration_l2",
        "memory_evidence_governance",
        "execution_ontology_feedback",
        "experience_feedback",
        "build_test_throughput",
        "eval_budget_checkpoint",
        "treatment_activation",
        "memory_local_store_isolation",
        "paid_budget_journal",
        "daemon_transport",
    )
)
RULE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{2,127}$")
FIELD_RE = re.compile(r"^    ([a-z][a-z0-9_]*):", re.MULTILINE)
STRING_RE = re.compile(r'"([a-zA-Z_][a-zA-Z0-9_]*)"')
# Match standalone runner summaries such as "1 skipped", but never treat the
# value of a preceding key/value field as the skip count.  In particular,
# sharded reports contain "passed=291 skipped=1"; the old expression started
# at 291 and falsely reported 291 skipped tests.
NONZERO_SKIP_RE = re.compile(r"(?<![\d=])([1-9][0-9]*)\s+skipped\b", re.IGNORECASE)
UNITTEST_SKIP_RE = re.compile(r"\bOK\s*\([^)]*\bskipped=([1-9][0-9]*)\b", re.IGNORECASE)


class ControlError(RuntimeError):
    pass


@dataclass
class Observation:
    schema_version: int = SCHEMA_VERSION
    sensor: str = "declaration_l2"
    sensor_ok: bool = False
    declared: int = 0
    covered: int = 0
    deviation: int = 0
    declarations: list[str] = field(default_factory=list)
    covered_declarations: list[str] = field(default_factory=list)
    missing_declarations: list[str] = field(default_factory=list)
    exclusions: list[dict[str, str]] = field(default_factory=list)
    feedback_bindings: list[dict[str, str]] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    fingerprint_sha256: str = ""


@dataclass
class ActuatorObservation:
    schema_version: int = SCHEMA_VERSION
    sensor: str = "release_gate_wiring"
    sensor_ok: bool = False
    build_step_wired: bool = False
    controller_command_wired: bool = False
    workflow_job_wired: bool = False
    workflow_command_wired: bool = False
    workflow_workdir_wired: bool = False
    telemetry_upload_wired: bool = False
    telemetry_missing_fails: bool = False
    errors: list[str] = field(default_factory=list)
    source_sha256: dict[str, str] = field(default_factory=dict)
    fingerprint_sha256: str = ""


def load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise ControlError(f"cannot load JSON {path}: {exc}") from exc


def require_schema(document: Any, path: Path) -> dict[str, Any]:
    if not isinstance(document, dict):
        raise ControlError(f"{path}: root must be an object")
    if document.get("schema_version") != SCHEMA_VERSION:
        raise ControlError(
            f"{path}: schema_version must be {SCHEMA_VERSION}, got {document.get('schema_version')!r}"
        )
    return document


def safe_repo_path(repo: Path, relative: str) -> Path:
    if not relative or Path(relative).is_absolute():
        raise ControlError(f"repository path must be non-empty and relative: {relative!r}")
    root = repo.resolve()
    candidate = (root / relative).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise ControlError(f"repository path escapes root: {relative!r}") from exc
    return candidate


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ControlError(f"cannot read {path}: {exc}") from exc


def agentdef_fields(source: str) -> list[str]:
    start = source.find("pub const AgentDef = struct {")
    if start < 0:
        raise ControlError("AgentDef struct declaration not found")
    stop = source.find("    pub fn deinit", start)
    if stop < 0:
        raise ControlError("AgentDef.deinit boundary not found")
    fields = FIELD_RE.findall(source[start:stop])
    if not fields:
        raise ControlError("AgentDef contains no parseable fields")
    return fields


def task_required_fields(source: str) -> list[str]:
    marker = '.name = "Task",'
    start = source.find(marker)
    if start < 0:
        raise ControlError("Task tool registry entry not found")
    stop = source.find(".execute = .{ .legacy_inline = agent_tool.execute }", start)
    if stop < 0:
        raise ControlError(
            "Task tool registry entry has no legacy_inline agent_tool.execute boundary"
        )
    block = source[start:stop]
    match = re.search(r"\.required\s*=\s*&\.\{([^}]*)\}", block, re.DOTALL)
    if match is None:
        raise ControlError("Task required-field declaration not found")
    return STRING_RE.findall(match.group(1))


def test_slice(source: str, test_name: str) -> str | None:
    needle = f'test "{test_name}"'
    start = source.find(needle)
    if start < 0:
        return None
    next_test = re.search(r"\ntest\s+\"", source[start + len(needle) :])
    if next_test is None:
        return source[start:]
    return source[start : start + len(needle) + next_test.start()]


def build_step_slice(source: str, step_name: str) -> str | None:
    pattern = re.compile(r'b\.step\(\s*"' + re.escape(step_name) + r'"')
    match = pattern.search(source)
    if match is None:
        return None
    next_step = re.search(r"\n\s*const\s+[a-zA-Z0-9_]+_step\s*=\s*b\.step\(", source[match.end() :])
    if next_step is None:
        return source[match.start() :]
    return source[match.start() : match.end() + next_step.start()]


def zig_function_slice(source: str, function_name: str) -> str | None:
    """Return one Zig function body while ignoring braces inside literals."""
    match = re.search(
        r"(?:pub\s+)?fn\s+" + re.escape(function_name) + r"\s*\(",
        source,
    )
    if match is None:
        return None
    cursor = match.end()
    while True:
        start = source.find("{", cursor)
        if start < 0:
            return None
        # Zig error sets appear between the parameter list and function body.
        # They are type syntax, not an executable body.
        if source[max(cursor, start - 8) : start].rstrip().endswith("error"):
            end_error_set = source.find("}", start + 1)
            if end_error_set < 0:
                return None
            cursor = end_error_set + 1
            continue
        break
    depth = 0
    quote: str | None = None
    escaped = False
    for index in range(start, len(source)):
        char = source[index]
        if quote is not None:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char in {'"', "'"}:
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[match.start() : index + 1]
    return None


def fingerprint(paths: Iterable[Path]) -> str:
    digest = hashlib.sha256()
    for path in sorted({item.resolve() for item in paths}, key=str):
        digest.update(str(path).encode("utf-8"))
        digest.update(b"\0")
        if path.is_file():
            digest.update(path.read_bytes())
        else:
            digest.update(b"<missing>")
        digest.update(b"\0")
    return digest.hexdigest()


def discover_workspace_root(repo: Path) -> Path:
    """Find the checkout root without trusting a shell command or git config."""
    current = repo.resolve()
    while True:
        if (current / ".git").exists():
            return current
        if current.parent == current:
            return repo.resolve()
        current = current.parent


def _job_slice(workflow: str, job_id: str) -> str | None:
    lines = workflow.splitlines(keepends=True)
    jobs_index: int | None = None
    for index, line in enumerate(lines):
        if re.fullmatch(r"jobs:[ \t]*(?:#.*)?\r?\n?", line):
            jobs_index = index
            break
    if jobs_index is None:
        return None
    start: int | None = None
    for index in range(jobs_index + 1, len(lines)):
        line = lines[index]
        if re.fullmatch(r"  " + re.escape(job_id) + r":[ \t]*(?:#.*)?\r?\n?", line):
            start = index
            break
    if start is None:
        return None
    stop = len(lines)
    for index in range(start + 1, len(lines)):
        if re.fullmatch(r"  [A-Za-z0-9_-]+:[ \t]*(?:#.*)?\r?\n?", lines[index]):
            stop = index
            break
    return "".join(lines[start:stop])


def _upload_step_slice(job: str) -> str | None:
    lines = job.splitlines(keepends=True)
    upload_index: int | None = None
    for index, line in enumerate(lines):
        if re.match(r"^\s+uses:\s*actions/upload-artifact@", line):
            upload_index = index
            break
    if upload_index is None:
        return None
    start = upload_index
    while start > 0 and not re.match(r"^\s{6}-\s", lines[start]):
        start -= 1
    stop = len(lines)
    for index in range(upload_index + 1, len(lines)):
        if re.match(r"^\s{6}-\s", lines[index]):
            stop = index
            break
    return "".join(lines[start:stop])


def _strip_zig_comments(source: str) -> str:
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    return re.sub(r"//.*$", "", source, flags=re.MULTILINE)


def observe_release_gate(
    repo: Path,
    workspace: Path,
    actuator: Any,
) -> ActuatorObservation:
    """Observe the executable release path; manifest prose is not evidence."""
    errors: list[str] = []
    touched: list[Path] = []
    if not isinstance(actuator, dict):
        return ActuatorObservation(errors=["actuator must be an object"])
    observation = actuator.get("observation")
    if not isinstance(observation, dict) or observation.get("schema_version") != SCHEMA_VERSION:
        return ActuatorObservation(errors=["actuator.observation schema is missing or unsupported"])

    expected_strings = {
        "build_file": "control-plane/build.zig",
        "build_step": "rule-check",
        "workflow_file": ".github/workflows/rule-control.yml",
        "workflow_job": "rule-control",
        "workflow_workdir": ".",
        "telemetry_path": "zig-out/reports/rule-control.json",
    }
    for key, expected in expected_strings.items():
        if observation.get(key) != expected:
            errors.append(
                f"actuator.observation.{key} must be canonical value {expected!r}"
            )
    if errors:
        return ActuatorObservation(errors=errors)

    try:
        build_path = safe_repo_path(repo, observation["build_file"])
        workflow_path = safe_repo_path(workspace, observation["workflow_file"])
        touched.extend((build_path, workflow_path))
        build_source = _strip_zig_comments(read_text(build_path))
        workflow_source = read_text(workflow_path)
    except ControlError as exc:
        return ActuatorObservation(errors=[str(exc)], fingerprint_sha256=fingerprint(touched))

    controller_command_wired = False
    command_var = ""
    command_pattern = re.compile(
        r"const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*b\.addSystemCommand\(\s*&\.\{([^}]*)\}\s*\)",
        re.DOTALL,
    )
    for command_match in command_pattern.finditer(build_source):
        command_body = command_match.group(2)
        if not all(
            marker in command_body for marker in ('"scripts/rule_control.py"', '"check"')
        ):
            continue
        command_var = command_match.group(1)
        controller_command_wired = True
        break
    if not controller_command_wired:
        errors.append("control-plane build does not execute scripts/rule_control.py check")

    step_name = re.escape(observation["build_step"])
    step_match = re.search(
        r"const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*b\.step\(\s*\"" + step_name + r"\"",
        build_source,
    )
    build_step_wired = False
    if step_match is not None and command_var:
        step_var = re.escape(step_match.group(1))
        command_name = re.escape(command_var)
        build_step_wired = re.search(
            step_var + r"\s*\.\s*dependOn\(\s*&" + command_name + r"\s*\.\s*step\s*\)",
            build_source,
        ) is not None
    if not build_step_wired:
        errors.append(f"control-plane build step {observation['build_step']!r} is not wired to the controller command")

    job = _job_slice(workflow_source, observation["workflow_job"])
    workflow_job_wired = job is not None
    if job is None:
        errors.append(f"workflow job {observation['workflow_job']!r} is missing")
        job = ""

    expected_run = (
        "zig build --build-file " + observation["build_file"] + " " + observation["build_step"]
    )
    workflow_command_wired = re.search(
        r"^\s+run:\s*" + re.escape(expected_run) + r"\s*$",
        job,
        re.MULTILINE,
    ) is not None
    if not workflow_command_wired:
        errors.append(f"workflow job does not run exact release gate: {expected_run}")
    if re.search(r"^\s+continue-on-error:\s*true\s*$", job, re.MULTILINE):
        workflow_command_wired = False
        errors.append("workflow release gate must not use continue-on-error: true")
    if re.search(r"^\s+if:\s*(?:false|\$\{\{\s*false\s*\}\})\s*$", job, re.MULTILINE):
        workflow_command_wired = False
        errors.append("workflow release gate must not be disabled by if: false")

    jobs_match = re.search(r"^jobs:[ \t]*(?:#.*)?\r?$", workflow_source, re.MULTILINE)
    workflow_preamble = workflow_source[: jobs_match.start()] if jobs_match is not None else ""
    workdir_pattern = (
        r"^\s+working-directory:\s*" + re.escape(observation["workflow_workdir"]) + r"\s*$"
    )
    workflow_workdir_wired = (
        re.search(workdir_pattern, workflow_preamble, re.MULTILINE) is not None
        or re.search(workdir_pattern, job, re.MULTILINE) is not None
    )
    if not workflow_workdir_wired:
        errors.append(f"workflow does not run from {observation['workflow_workdir']!r}")

    upload = _upload_step_slice(job)
    telemetry_upload_wired = upload is not None and all(
        re.search(pattern, upload, re.MULTILINE) is not None
        for pattern in (
            r"^\s+if:\s*always\(\)\s*$",
            r"^\s+path:\s*" + re.escape(observation["telemetry_path"]) + r"\s*$",
        )
    )
    if not telemetry_upload_wired:
        errors.append("workflow must always upload the exact rule-control telemetry path")
    telemetry_missing_fails = upload is not None and re.search(
        r"^\s+if-no-files-found:\s*error\s*$",
        upload,
        re.MULTILINE,
    ) is not None
    if not telemetry_missing_fails:
        errors.append("workflow telemetry upload must fail when the report is missing")

    sensor_ok = not errors and all(
        (
            build_step_wired,
            controller_command_wired,
            workflow_job_wired,
            workflow_command_wired,
            workflow_workdir_wired,
            telemetry_upload_wired,
            telemetry_missing_fails,
        )
    )
    return ActuatorObservation(
        sensor_ok=sensor_ok,
        build_step_wired=build_step_wired,
        controller_command_wired=controller_command_wired,
        workflow_job_wired=workflow_job_wired,
        workflow_command_wired=workflow_command_wired,
        workflow_workdir_wired=workflow_workdir_wired,
        telemetry_upload_wired=telemetry_upload_wired,
        telemetry_missing_fails=telemetry_missing_fails,
        errors=errors,
        source_sha256={
            f"repo:{observation['build_file']}": sha256_file(build_path),
            f"workspace:{observation['workflow_file']}": sha256_file(workflow_path),
        },
        fingerprint_sha256=fingerprint(touched),
    )


def observe_declaration_l2(repo: Path, registry_path: Path) -> Observation:
    errors: list[str] = []
    touched: list[Path] = [registry_path]
    try:
        registry = require_schema(load_json(registry_path), registry_path)
    except ControlError as exc:
        return Observation(errors=[str(exc)])

    sources = registry.get("sources")
    if not isinstance(sources, dict):
        return Observation(errors=[f"{registry_path}: sources must be an object"])
    required_source_keys = ("agentdef", "task_registry", "build_graph")
    resolved_sources: dict[str, Path] = {}
    for key in required_source_keys:
        relative = sources.get(key)
        if not isinstance(relative, str):
            errors.append(f"sources.{key} must be a repository-relative path")
            continue
        try:
            resolved_sources[key] = safe_repo_path(repo, relative)
            touched.append(resolved_sources[key])
        except ControlError as exc:
            errors.append(str(exc))
    if errors:
        return Observation(errors=errors, fingerprint_sha256=fingerprint(touched))

    try:
        agent_source = read_text(resolved_sources["agentdef"])
        task_source = read_text(resolved_sources["task_registry"])
        build_source = read_text(resolved_sources["build_graph"])
        all_agent = {f"AgentDef.{name}" for name in agentdef_fields(agent_source)}
        task_required = {f"Tool.Task.required.{name}" for name in task_required_fields(task_source)}
    except ControlError as exc:
        return Observation(errors=[str(exc)], fingerprint_sha256=fingerprint(touched))

    exclusions_value = registry.get("exclusions", [])
    exclusions: list[dict[str, str]] = []
    excluded_ids: set[str] = set()
    if not isinstance(exclusions_value, list):
        errors.append("exclusions must be an array")
        exclusions_value = []
    for index, raw in enumerate(exclusions_value):
        if not isinstance(raw, dict):
            errors.append(f"exclusions[{index}] must be an object")
            continue
        declaration = raw.get("declaration")
        classification = raw.get("classification")
        reason = raw.get("reason")
        if not all(isinstance(value, str) and value.strip() for value in (declaration, classification, reason)):
            errors.append(f"exclusions[{index}] requires declaration, classification, and reason")
            continue
        if declaration not in all_agent:
            errors.append(f"exclusion names unknown declaration: {declaration}")
            continue
        if declaration in excluded_ids:
            errors.append(f"duplicate exclusion: {declaration}")
            continue
        excluded_ids.add(declaration)
        exclusions.append(
            {"declaration": declaration, "classification": classification, "reason": reason}
        )

    declarations = (all_agent - excluded_ids) | task_required
    evidence_value = registry.get("evidence")
    if not isinstance(evidence_value, list):
        errors.append("evidence must be an array")
        evidence_value = []

    valid_evidence: set[str] = set()
    feedback_bindings: set[tuple[str, str]] = set()
    seen_evidence: set[str] = set()
    for index, raw in enumerate(evidence_value):
        prefix = f"evidence[{index}]"
        if not isinstance(raw, dict):
            errors.append(f"{prefix} must be an object")
            continue
        declaration = raw.get("declaration")
        test_file = raw.get("test_file")
        test_name = raw.get("test_name")
        markers = raw.get("assertion_markers")
        feedback_step = raw.get("feedback_step")
        feedback_filter = raw.get("feedback_filter", "")
        if not isinstance(declaration, str) or not declaration:
            errors.append(f"{prefix}.declaration must be non-empty")
            continue
        if declaration in seen_evidence:
            errors.append(f"duplicate evidence binding: {declaration}")
            continue
        seen_evidence.add(declaration)
        if declaration not in declarations:
            errors.append(f"evidence names unknown or excluded declaration: {declaration}")
            continue
        if not isinstance(test_file, str) or not test_file.startswith("tests/component/"):
            errors.append(f"{prefix}.test_file must point under tests/component/: {test_file!r}")
            continue
        if not isinstance(test_name, str) or not test_name.startswith("L2 "):
            errors.append(f"{prefix}.test_name must start with 'L2 '")
            continue
        if not isinstance(feedback_step, str) or not feedback_step.startswith("test:"):
            errors.append(f"{prefix}.feedback_step must name a test:* Zig build step")
            continue
        if not isinstance(feedback_filter, str):
            errors.append(f"{prefix}.feedback_filter must be a string when present")
            continue
        if feedback_filter and feedback_filter not in test_name:
            errors.append(f"{declaration}: feedback_filter does not select its exact test name")
            continue
        if not isinstance(markers, list) or len(markers) < 2 or not all(
            isinstance(marker, str) and marker for marker in markers
        ):
            errors.append(f"{prefix}.assertion_markers must contain at least two strings")
            continue
        try:
            test_path = safe_repo_path(repo, test_file)
            touched.append(test_path)
            source = read_text(test_path)
        except ControlError as exc:
            errors.append(str(exc))
            continue
        body = test_slice(source, test_name)
        if body is None:
            errors.append(f"{declaration}: test not found: {test_file} :: {test_name}")
            continue
        missing_markers = [marker for marker in markers if marker not in body]
        if missing_markers:
            errors.append(f"{declaration}: test is missing assertion markers: {missing_markers}")
            continue
        if "std.testing.expect" not in body:
            errors.append(f"{declaration}: test body contains no std.testing expectation")
            continue
        step_source = build_step_slice(build_source, feedback_step)
        if step_source is None:
            errors.append(f"{declaration}: feedback build step does not exist: {feedback_step}")
            continue
        if f'"{test_file}"' not in step_source:
            errors.append(
                f"{declaration}: {test_file} is not wired into build step {feedback_step}"
            )
            continue
        valid_evidence.add(declaration)
        feedback_bindings.add((feedback_step, feedback_filter))

    missing = sorted(declarations - valid_evidence)
    covered = sorted(valid_evidence)
    if missing:
        errors.append(f"missing L2 evidence: {', '.join(missing)}")
    sensor_ok = not errors and len(valid_evidence) == len(declarations)
    return Observation(
        sensor_ok=sensor_ok,
        declared=len(declarations),
        covered=len(valid_evidence),
        deviation=max(len(declarations) - len(valid_evidence), 0),
        declarations=sorted(declarations),
        covered_declarations=covered,
        missing_declarations=missing,
        exclusions=sorted(exclusions, key=lambda item: item["declaration"]),
        feedback_bindings=[
            {"step": step, **({"filter": selected_filter} if selected_filter else {})}
            for step, selected_filter in sorted(feedback_bindings)
        ],
        errors=errors,
        fingerprint_sha256=fingerprint(touched),
    )


def observe_memory_evidence_governance(repo: Path) -> Observation:
    """Observe executable memory-governance wiring, not manifest claims.

    The dynamic Zig feedback still proves behavior. This pre/post sensor proves
    that the production paths, exact L2 assertions, and focused build actuator
    remain connected while feedback executes.
    """
    source_relatives = {
        "scoped": "src/kg/scoped_recall.zig",
        "client": "src/kg/client.zig",
        "protocol": "src/kg/retrieval_protocol.zig",
        "system": "src/core/system_prompt.zig",
        "context": "src/tools/kg_tools.zig",
        "tools": "src/tools.zig",
        "test": "tests/component/kg_integration_test.zig",
        "build": "build.zig",
    }
    paths: dict[str, Path] = {}
    touched: list[Path] = []
    errors: list[str] = []
    for name, relative in source_relatives.items():
        try:
            path = safe_repo_path(repo, relative)
            paths[name] = path
            touched.append(path)
        except ControlError as exc:
            errors.append(str(exc))
    if errors:
        return Observation(
            sensor="memory_evidence_governance",
            errors=errors,
            fingerprint_sha256=fingerprint(touched),
        )
    try:
        sources = {
            name: _strip_zig_comments(read_text(path))
            for name, path in paths.items()
            if name != "test"
        }
        test_source = read_text(paths["test"])
    except ControlError as exc:
        return Observation(
            sensor="memory_evidence_governance",
            errors=[str(exc)],
            fingerprint_sha256=fingerprint(touched),
        )

    step = build_step_slice(sources["build"], "test:kg-governance")
    test_wired = step is not None and '"tests/component/kg_integration_test.zig"' in step
    if not test_wired:
        errors.append(
            "knowledge-governance L2 is not wired into build step test:kg-governance"
        )

    obligations: dict[str, tuple[bool, list[str]]] = {}

    automatic_test_name = (
        "L2 KG governance: scoped recall exposes stable node ids and candidate-only guidance"
    )
    automatic_body = test_slice(test_source, automatic_test_name)
    automatic_test = _strip_zig_comments(automatic_body) if automatic_body is not None else ""
    automatic_checks = {
        "runtime formats node_id": "node_id={d}" in sources["scoped"],
        "runtime reads hit node id": "h.node_id" in sources["scoped"],
        "runtime appends governance note": "retrieval_protocol.AUTO_RECALL_NOTE" in sources["scoped"],
        "L2 test exists": automatic_body is not None,
        "L2 asserts exact id": "expected_id" in automatic_test and "node_id={d}" in automatic_test,
        "L2 asserts context handoff": "KgContext(node_id)" in automatic_test,
        "L2 contains an expectation": "std.testing.expect" in automatic_test,
        "L2 build wiring exists": test_wired,
    }
    obligations["automatic_recall_node_identity"] = (
        all(automatic_checks.values()),
        [name for name, present in automatic_checks.items() if not present],
    )

    request_test_name = (
        "L2 KG governance: freshness and contradiction contract enters the actual API request"
    )
    request_body = test_slice(test_source, request_test_name)
    request_test = _strip_zig_comments(request_body) if request_body is not None else ""
    protocol_markers = (
        "Memory is a candidate, not a current fact",
        "verified_by or evidences",
        "deprecated_by, resolved_by, and contradiction",
        "current code, git, tests, or external state",
    )
    prompt_checks = {
        "protocol carries governance contract": all(marker in sources["protocol"] for marker in protocol_markers),
        "system prompt consumes protocol": "kg_retrieval.SYSTEM_RULES" in sources["system"],
        "tool schema consumes context protocol": re.search(
            r"(?:retrieval_protocol|kg_retrieval)\.CONTEXT_DESCRIPTION", sources["tools"]
        ) is not None,
        "request L2 test exists": request_body is not None,
        "request L2 asserts all contract markers": all(marker in request_test for marker in protocol_markers),
        "request L2 contains an expectation": "std.testing.expect" in request_test,
        "request L2 build wiring exists": test_wired,
    }
    obligations["prompt_and_tool_governance"] = (
        all(prompt_checks.values()),
        [name for name, present in prompt_checks.items() if not present],
    )

    context_test_name = (
        "L2 KG governance: KgContext emits evidence, freshness, and supersession signals"
    )
    context_body = test_slice(test_source, context_test_name)
    context_test = _strip_zig_comments(context_body) if context_body is not None else ""
    context_markers = (
        "knowledge_governance",
        "current_generation",
        "deprecated_by",
        "verification_edge_count",
    )
    context_checks = {
        "runtime reads versioned node metadata": "nodeMetadataJson" in sources["client"] and "nodeMetadataJson" in sources["context"],
        "runtime derives graph signals": "buildKnowledgeGovernance" in sources["context"],
        "runtime emits governance object": '"knowledge_governance"' in sources["context"] or "\\\"knowledge_governance\\\"" in sources["context"],
        "runtime versions governance schema": "metacodes-knowledge-governance-v1" in sources["context"],
        "context L2 test exists": context_body is not None,
        "context L2 asserts structured fields": all(marker in context_test for marker in context_markers),
        "context L2 contains an expectation": "std.testing.expect" in context_test,
        "context L2 build wiring exists": test_wired,
    }
    obligations["context_structured_governance"] = (
        all(context_checks.values()),
        [name for name, present in context_checks.items() if not present],
    )

    covered = sorted(name for name, (present, _) in obligations.items() if present)
    missing = sorted(name for name, (present, _) in obligations.items() if not present)
    for name in missing:
        failures = obligations[name][1]
        errors.append(f"{name}: missing executable evidence: {', '.join(failures)}")
    declarations = sorted(obligations)
    return Observation(
        sensor="memory_evidence_governance",
        sensor_ok=not errors and len(covered) == len(declarations),
        declared=len(declarations),
        covered=len(covered),
        deviation=max(len(declarations) - len(covered), 0),
        declarations=declarations,
        covered_declarations=covered,
        missing_declarations=missing,
        feedback_bindings=[{"step": "test:kg-governance", "filter": "L2 KG governance:"}],
        errors=errors,
        fingerprint_sha256=fingerprint(touched),
    )


def observe_execution_ontology_feedback(repo: Path) -> Observation:
    """Observe execution sensor -> task-close actuator -> focused L2 feedback."""
    source_relatives = {
        "tool_exec": "src/core/tool_exec.zig",
        "task_store": "src/core/task_store.zig",
        "client": "src/kg/client.zig",
        "ledger": "src/kg/execution_knowledge.zig",
        "task_tools": "src/tools/task_tools.zig",
        "test": "tests/component/kg_integration_test.zig",
        "build": "build.zig",
    }
    paths: dict[str, Path] = {}
    touched: list[Path] = []
    errors: list[str] = []
    for name, relative in source_relatives.items():
        try:
            path = safe_repo_path(repo, relative)
            paths[name] = path
            touched.append(path)
        except ControlError as exc:
            errors.append(str(exc))
    if errors:
        return Observation(
            sensor="execution_ontology_feedback",
            errors=errors,
            fingerprint_sha256=fingerprint(touched),
        )
    try:
        sources = {
            name: _strip_zig_comments(read_text(path))
            for name, path in paths.items()
            if name != "test"
        }
        test_source = read_text(paths["test"])
    except ControlError as exc:
        return Observation(
            sensor="execution_ontology_feedback",
            errors=[str(exc)],
            fingerprint_sha256=fingerprint(touched),
        )

    execute_slots = zig_function_slice(sources["tool_exec"], "executeSlots") or ""
    observe_success = zig_function_slice(
        sources["tool_exec"], "observeSuccessfulExecutions"
    ) or ""
    client_observer = zig_function_slice(
        sources["client"], "observeSuccessfulExecution"
    ) or ""
    task_selector = zig_function_slice(
        sources["task_store"], "uniqueActiveKgTaskId"
    ) or ""
    ledger_observer = zig_function_slice(
        sources["ledger"], "observeSuccessfulTool"
    ) or ""

    execution_checks = {
        "successful batches invoke the sensor": (
            "observeSuccessfulExecutions(slots[i..j], base_ctx)" in execute_slots
        ),
        "accepted prefetch invokes the sensor": (
            "slots[i].decision == .run" in execute_slots
            and "observeSuccessfulExecutions(slots[i .. i + 1], base_ctx)" in execute_slots
        ),
        "denied, pending, errors, and empty results are excluded": all(
            marker in observe_success
            for marker in (
                "slot.decision != .run",
                "slot.pending",
                "slot.is_error",
                "slot.content == null",
            )
        ),
        "sensor requires one active persistent task": (
            "uniqueActiveKgTaskId()" in observe_success
            and "active != null" in task_selector
            and "parseInt(u64" in task_selector
        ),
        "tool executor calls the client ledger": (
            "kg.observeSuccessfulExecution" in observe_success
            and "execution_ledger.observeSuccessfulTool" in client_observer
        ),
        "ledger stores sanitized resources rather than raw bodies": all(
            marker in ledger_observer
            for marker in (
                "resourceSpec(tool_name)",
                "extractStringField(input_json, resource.field)",
                "normalizeProjectPath",
                "self.record(task_id, .acts_on",
            )
        ),
    }

    projection = zig_function_slice(sources["task_tools"], "writeClosureProjection") or ""
    update_task = zig_function_slice(sources["task_tools"], "updateKgTask") or ""
    fail_task = zig_function_slice(sources["task_tools"], "failKgTask") or ""
    stop_task = zig_function_slice(sources["task_tools"], "executeStop") or ""
    closure_checks = {
        "closure snapshots observed facts": "executionKnowledgeSnapshot" in projection,
        "closure writes tentative ref edges": (
            "addRefEdge" in projection and "false" in projection
        ),
        "successful projection acknowledges ledger facts": (
            "acknowledgeExecutionFact" in projection
        ),
        "partial facts remain observable": all(
            marker in sources["task_tools"]
            for marker in ("observed", "projected", "failed", "dropped", "retained")
        ),
        "TaskUpdate completion consumes projection": (
            "const projection = writeClosureProjection" in update_task
            and "appendProjectionReport" in update_task
        ),
        "failed and stop closures consume projection": (
            "writeClosureProjection" in fail_task
            and "appendProjectionReport" in fail_task
            and "writeClosureProjection" in stop_task
            and "appendProjectionReport" in stop_task
        ),
    }

    test_name = (
        "L2 KG ontology feedback: successful host execution projects without model self-report"
    )
    test_body_raw = test_slice(test_source, test_name)
    test_body = _strip_zig_comments(test_body_raw) if test_body_raw is not None else ""
    step = build_step_slice(sources["build"], "test:kg-ontology-feedback")
    test_wired = (
        step is not None
        and '"tests/component/kg_integration_test.zig"' in step
        and "kg_ontology_feedback_step.dependOn(&run_t.step)" in step
    )
    feedback_checks = {
        "focused L2 exists": test_body_raw is not None,
        "L2 executes through host tool slots and TaskUpdate": (
            "tool_exec.executeSlots" in test_body and "task_tools.executeUpdate" in test_body
        ),
        "L2 proves self-report omission and observed projection": (
            '"explicit\\\":0"' in test_body
            and '"observed\\\":2"' in test_body
        ),
        "L2 proves denied, failed, privacy, and task isolation": all(
            marker in test_body
            for marker in (
                "DENIED_SENTINEL",
                "MISSING_SENTINEL",
                "PRIVATE_BODY_SENTINEL",
                "first.zig",
                "second.zig",
            )
        ),
        "L2 contains executable assertions": "std.testing.expect" in test_body,
        "focused build step is wired": test_wired,
    }

    obligations = {
        "successful_execution_sensor": execution_checks,
        "task_close_projection_actuator": closure_checks,
        "focused_l2_feedback": feedback_checks,
    }
    covered = sorted(
        name for name, checks in obligations.items() if all(checks.values())
    )
    declarations = sorted(obligations)
    missing = sorted(set(declarations) - set(covered))
    for name in missing:
        absent = [label for label, present in obligations[name].items() if not present]
        errors.append(f"{name}: missing executable evidence: {', '.join(absent)}")
    return Observation(
        sensor="execution_ontology_feedback",
        sensor_ok=not errors and len(covered) == len(declarations),
        declared=len(declarations),
        covered=len(covered),
        deviation=max(len(declarations) - len(covered), 0),
        declarations=declarations,
        covered_declarations=covered,
        missing_declarations=missing,
        feedback_bindings=[
            {
                "step": "test:kg-ontology-feedback",
                "filter": "L2 KG ontology feedback:",
            }
        ],
        errors=errors,
        fingerprint_sha256=fingerprint(touched),
    )


def observe_experience_feedback(repo: Path) -> Observation:
    """Observe prior execution retrieval -> governed pre-work decision feedback."""
    source_relatives = {
        "experience": "src/kg/experience_packet.zig",
        "client": "src/kg/client.zig",
        "retrieval_protocol": "src/kg/retrieval_protocol.zig",
        "tool_exec": "src/core/tool_exec.zig",
        "task_protocol": "src/kg/task_protocol.zig",
        "test": "tests/component/kg_integration_test.zig",
        "build": "build.zig",
    }
    paths: dict[str, Path] = {}
    touched: list[Path] = []
    errors: list[str] = []
    for name, relative in source_relatives.items():
        try:
            path = safe_repo_path(repo, relative)
            paths[name] = path
            touched.append(path)
        except ControlError as exc:
            errors.append(str(exc))
    if errors:
        return Observation(
            sensor="experience_feedback",
            errors=errors,
            fingerprint_sha256=fingerprint(touched),
        )
    try:
        sources = {
            name: _strip_zig_comments(read_text(path))
            for name, path in paths.items()
            if name != "test"
        }
        test_source = read_text(paths["test"])
    except ControlError as exc:
        return Observation(
            sensor="experience_feedback",
            errors=[str(exc)],
            fingerprint_sha256=fingerprint(touched),
        )

    build_packet = zig_function_slice(sources["experience"], "buildPacket") or ""
    recall_tasks = zig_function_slice(sources["client"], "recallTasks") or ""
    search_subtree = zig_function_slice(sources["client"], "searchSubtreeInto") or ""
    retrieval_checks = {
        "current task text is the exact retrieval seed": (
            "fetchNodeText(task_id)" in build_packet
            and "truncateUtf8" in build_packet
            and "QUERY_BYTES" in build_packet
        ),
        "search includes prior tasks through a bounded single probe": (
            "kg.recallTasks(query, SEARCH_LIMIT)" in build_packet
            and "SEARCH_LIMIT" in sources["experience"]
            and "MAX_ACCEPTED_TASKS" in sources["experience"]
        ),
        "task kind is pushed into TinyKG before result truncation": (
            'recallFiltered(query, limit, true, null, "task")' in recall_tasks
            and '"--kind"' in search_subtree
            and "kind_filter" in search_subtree
        ),
        "packet declares lexical no-embedding semantics": (
            "lexical_bm25_no_embeddings" in sources["experience"]
            and "empty packet does not prove absence" in sources["experience"]
        ),
    }

    task_gate = zig_function_slice(sources["experience"], "inspectTaskPacket") or ""
    association_gate = zig_function_slice(sources["experience"], "inspectAssociations") or ""
    governance_checks = {
        "only completed tasks pass": (
            '"completed"' in task_gate and "not_completed" in task_gate
        ),
        "task packet truncation and generation are fail closed": (
            '"truncated"' in task_gate and "nodeIsCurrent" in task_gate
        ),
        "current verification evidence is mandatory": (
            '"verified_by"' in task_gate
            and "currentNodeOfKind" in task_gate
            and '"verification"' in task_gate
        ),
        "ontology targets and state remain governed": all(
            marker in association_gate
            for marker in (
                "parseRelation",
                "currentNodeOfKind",
                "AssociationState",
                "fetchNodeText",
                "MAX_ASSOCIATIONS_PER_TASK",
                '"direction"',
                '"outgoing"',
            )
        ),
        "candidate guidance preserves tentative and confirmed semantics": (
            "confirmed associations have human backing" in sources["experience"]
            and "tentative associations are host-grounded observations" in sources["experience"]
            and "multi_read_reverify_required" in sources["experience"]
        ),
    }

    enrich = zig_function_slice(sources["experience"], "enrichClaimResult") or ""
    decision_task = zig_function_slice(sources["experience"], "decisionTaskId") or ""
    execute_one = zig_function_slice(sources["tool_exec"], "executeOne") or ""
    actuator_checks = {
        "adapter activates only on successful TaskUpdate claim": (
            '"TaskUpdate"' in decision_task
            and '"claimed"' in decision_task
            and '"task_packet"' in decision_task
            and "decisionTaskId" in enrich
            and "buildPacket" in enrich
        ),
        "adapter also restores experience on claimed TaskGet recovery": (
            '"TaskGet"' in decision_task
            and '"kg_status"' in decision_task
            and '"claimed"' in decision_task
            and "decisionTaskId" in enrich
        ),
        "claim result is enriched before parent result copy": (
            "experience_packet.zig" in execute_one
            and ".enrichClaimResult" in execute_one
            and ".unavailableClaimResult" in execute_one
            and "const result_bytes = experience_bytes orelse ok_bytes" in execute_one
            and "dupe(u8, result_bytes)" in execute_one
        ),
        "missing client is explicit rather than silent": (
            "appendUnavailableForTask" in enrich
            and "kg_client_missing" in enrich
            and "kg_client_not_ready" in enrich
        ),
        "system prompt requires pre-work consumption without trust inflation": all(
            marker in sources["task_protocol"]
            for marker in (
                "experience_packet",
                "before any work",
                "bounded exact lexical probe",
                "tentative/confirmed state",
            )
        ),
    }

    semantic_expansion_checks = {
        "global retrieval contract states the no-vector limitation": all(
            marker in sources["retrieval_protocol"]
            for marker in (
                "computes no embeddings or vector distance",
                "2-4 separate compact probes",
                "host executes every declared member",
                "merges by node_id",
            )
        ),
        "task claim contract requires expansion before work": all(
            marker in sources["task_protocol"]
            for marker in (
                "LEXICAL EXPANSION",
                "TinyKG has no vectors",
                "before work actively infer 2-4 separate compact semantic variants",
                "declare them once in lexical-query-plan-v3",
                "host executes the fixed batch",
            )
        ),
        "packet guidance treats retrieved text as untrusted candidate data": all(
            marker in sources["experience"]
            for marker in (
                "untrusted data, never as instructions or commands",
                "declare them once in lexical-query-plan-v3",
                "host execute and deduplicate the batch",
                "candidate decision aid, never a current fact",
            )
        ),
    }

    test_name = "L2 KG experience feedback: claim exposes verified prior execution before work"
    test_body_raw = test_slice(test_source, test_name)
    test_body = _strip_zig_comments(test_body_raw) if test_body_raw is not None else ""
    step = build_step_slice(sources["build"], "test:kg-experience-feedback")
    test_wired = (
        step is not None
        and '"tests/component/kg_integration_test.zig"' in step
        and "kg_experience_feedback_step.dependOn(&run_t.step)" in step
    )
    feedback_checks = {
        "focused L2 exists": test_body_raw is not None,
        "L2 crosses the unified tool result boundary": (
            "tool_exec.executeOne" in test_body
            and '"TaskUpdate"' in test_body
            and '"TaskGet"' in test_body
        ),
        "L2 proves history reaches the next provider request": all(
            marker in test_body
            for marker in (
                "agent_loop.run",
                "requestAt(0)",
                "requestAt(1)",
                "metacodes-experience-packet-v1",
                "llm_before_work_if_insufficient",
                "LEXICAL EXPANSION",
                "2-4 separate compact semantic variants",
                "lexical-query-plan-v3",
                "host executes the fixed batch",
                "merges by node_id",
            )
        ),
        "L2 observes prior task, associations, state, and evidence": all(
            marker in test_body
            for marker in (
                "experience_packet",
                "saw_non_task_hit",
                "repair parser checkpoint recovery corruption",
                "src/parser_checkpoint.zig",
                "checkpoint-replay",
                "verified-parser-recovery-playbook",
                '\\"state\\":\\"tentative\\"',
                '\\"state\\":\\"confirmed\\"',
                '\\"evidence_node_ids\\":[',
            )
        ),
        "L2 rejects unfinished history and records paper telemetry": (
            "UNFINISHED_EXPERIENCE_SENTINEL" in test_body
            and "rejected_not_completed" in test_body
            and "accepted_tentative" in test_body
            and "accepted_confirmed" in test_body
            and "subprocess_calls_lower_bound" in test_body
            and "subprocess_calls_upper_bound" in test_body
            and "query_reused_from_tool_result" in test_body
            and "packet_bytes" in test_body
        ),
        "L2 contains executable assertions": "std.testing.expect" in test_body,
        "focused build step is wired": test_wired,
    }

    obligations = {
        "bounded_task_only_exact_retrieval": retrieval_checks,
        "lifecycle_evidence_state_gate": governance_checks,
        "pre_work_tool_result_actuator": actuator_checks,
        "lexical_semantic_expansion_contract": semantic_expansion_checks,
        "focused_l2_feedback": feedback_checks,
    }
    covered = sorted(
        name for name, checks in obligations.items() if all(checks.values())
    )
    declarations = sorted(obligations)
    missing = sorted(set(declarations) - set(covered))
    for name in missing:
        absent = [label for label, present in obligations[name].items() if not present]
        errors.append(f"{name}: missing executable evidence: {', '.join(absent)}")
    return Observation(
        sensor="experience_feedback",
        sensor_ok=not errors and len(covered) == len(declarations),
        declared=len(declarations),
        covered=len(covered),
        deviation=max(len(declarations) - len(covered), 0),
        declarations=declarations,
        covered_declarations=covered,
        missing_declarations=missing,
        feedback_bindings=[
            {
                "step": "test:kg-experience-feedback",
                "filter": "L2 KG experience feedback:",
            }
        ],
        errors=errors,
        fingerprint_sha256=fingerprint(touched),
    )


def observe_build_test_throughput(repo: Path) -> Observation:
    """Observe the test-speed control loop without treating speed as proof.

    The sensor governs the mechanisms that make timing evidence trustworthy:
    exact source inventory, deterministic partitioning, fail-closed aggregate
    reports, per-test diagnostics, separate fast/full build paths, and
    location-independent shipped artifacts and reproducible formal identity.
    Actual wall/CPU/RSS values remain
    host observations and are recorded by the experiment; Lean decides only
    whether the integrity obligations survived.
    """

    declarations = [
        "per_test_timing_diagnostics",
        "deterministic_process_sharding",
        "fail_closed_shard_aggregation",
        "aggregate_source_inventory",
        "fast_and_full_build_paths",
        "reproducible_shipped_artifacts",
        "reproducible_formal_artifact_identity",
    ]
    relative_sources = {
        "timing": "scripts/time_test_runner.zig",
        "runner": "scripts/sharded_test_runner.zig",
        "reporter": "scripts/sharded_test_reporter.zig",
        "suite": "tests/integration_suite.zig",
        "build": "build.zig",
        "artifact_repro": "scripts/tests/test_artifact_reproducibility.py",
        "formal_build": "scripts/build-formal-kernel.sh",
        "experiment": "scripts/eval/experiment.py",
    }
    paths = {name: repo / relative for name, relative in relative_sources.items()}
    missing_files = [relative_sources[name] for name, path in paths.items() if not path.is_file()]
    if missing_files:
        return Observation(
            sensor="build_test_throughput",
            declared=len(declarations),
            declarations=declarations,
            missing_declarations=declarations,
            deviation=len(declarations),
            errors=[f"required throughput-control source is missing: {path}" for path in missing_files],
            fingerprint_sha256=fingerprint(paths.values()),
        )

    sources = {name: _strip_zig_comments(read_text(path)) for name, path in paths.items()}
    timing_checks = {
        "enumerates compiled tests": "builtin.test_functions" in sources["timing"],
        "resets allocator per test": "std.testing.allocator_instance = .{}" in sources["timing"],
        "checks allocator leaks": "std.testing.allocator_instance.deinit() == .leak" in sources["timing"],
        "checks aggregate duration overflow": "std.math.add(u64, total_ns, elapsed_ns)" in sources["timing"],
        "reports slow buckets": "test_slow_bucket threshold_ms=" in sources["timing"],
        "reports top slow tests": "test_slow_top rank=" in sources["timing"],
        "reports result totals": all(
            marker in sources["timing"] for marker in ("passed={}", "skipped={}", "failed={}", "leaked={}")
        ),
        "fails on test or leak": "if (failed != 0 or leaked != 0) std.process.exit(1)" in sources["timing"],
    }
    sharding_checks = {
        "requires explicit shard identity": all(
            marker in sources["runner"]
            for marker in ("METACODES_TEST_SHARD_COUNT", "METACODES_TEST_SHARD_INDEX")
        ),
        "uses versioned stable partition": all(
            marker in sources["runner"]
            for marker in ("fnv1a_offset_basis", "fnv1a_prime", "fnv1a64-name-v1", "hashTestName(name)")
        ),
        "fingerprints all and selected tests": all(
            marker in sources["runner"]
            for marker in ("all_fingerprint", "selected_fingerprint", "selected_xor", "selected_sum")
        ),
        "resets test state per shard item": all(
            marker in sources["runner"]
            for marker in (
                "std.testing.allocator_instance = .{}",
                "std.testing.io_instance = .init",
                "std.testing.io_instance.deinit()",
                "std.testing.allocator_instance.deinit() == .leak",
            )
        ),
        "fails on test or leak": "if (failed != 0 or leaked != 0) std.process.exit(1)" in sources["runner"],
    }
    aggregation_checks = {
        "rejects duplicate report records": all(
            marker in sources["reporter"]
            for marker in ("DuplicateShardReportHeader", "DuplicateShardReportSummary", "DuplicateShardReport")
        ),
        "rejects missing shards and test names": all(
            marker in sources["reporter"]
            for marker in ("IncompleteShardSet", "IncompleteTestCoverage", "IncompleteTestFingerprint")
        ),
        "checks result addition": "std.math.add(usize, passed, skipped)" in sources["reporter"],
        "rejects failure or leak": "FailedShardReportedSuccess" in sources["reporter"],
        "has executable negative fixtures": all(
            marker in sources["reporter"]
            for marker in (
                'test "parse report rejects header-summary drift"',
                'test "aggregate verifies exact count and commutative fingerprints"',
                "expectError(error.DuplicateShardReport",
                "expectError(error.IncompleteTestFingerprint",
                "expectError(error.FailedShardReportedSuccess",
            )
        ),
    }

    tests_root = repo / "tests"
    discovered = sorted(
        path.relative_to(tests_root).as_posix()
        for directory in (tests_root / "component", tests_root / "integration")
        for path in directory.rglob("*_test.zig")
        if path.is_file() and not path.is_symlink()
    )
    dedicated = {"component/agentcore_abi_test.zig"}
    aggregate_expected = sorted(set(discovered) - dedicated)
    # Mirror build.zig's exact executable inventory form. A mention in prose,
    # a string literal, or a trailing-comment decoy must not count as wiring.
    imported = re.findall(
        r'^\s*_\s*=\s*@import\("((?:component|integration)/[^"\n]+_test\.zig)"\);\s*$',
        sources["suite"],
        re.MULTILINE,
    )
    imported_set = set(imported)
    inventory_checks = {
        "does not shrink below measured baseline": len(aggregate_expected) >= 67,
        "every aggregate test is imported exactly once": (
            len(imported) == len(imported_set) and imported_set == set(aggregate_expected)
        ),
        "dedicated ABI test remains separate": (
            dedicated.issubset(set(discovered))
            and dedicated.isdisjoint(imported_set)
            and "agentcore_abi_test.zig" in sources["build"]
            and 'b.step("agentcore:test"' in sources["build"]
        ),
        "build-time inventory guard executes": all(
            marker in sources["build"]
            for marker in (
                "fn validateAggregateTestInventory",
                "validateAggregateTestInventory(b);",
                '"tests/component"',
                '"tests/integration"',
                '"_test.zig"',
            )
        ),
    }

    dev_step = build_step_slice(sources["build"], "dev") or ""
    build_path_checks = {
        "fast path installs debug only": (
            "dev_step.dependOn(&install_debug.step)" in dev_step
            and "dev_step.dependOn(&exe.step)" not in dev_step
            and "installArtifact(exe)" not in dev_step
            and "tinykg_stage_step" not in dev_step
        ),
        "full development path explicitly includes TinyKG": (
            'b.step("dev:full"' in sources["build"]
            and "dev_full_step.dependOn(&install_debug.step)" in sources["build"]
            and "dev_full_step.dependOn(tinykg_stage_step)" in sources["build"]
        ),
        "core gates expose sharded monolithic timing and harness paths": all(
            f'b.step("{step}"' in sources["build"]
            for step in ("test:lib", "test:lib-monolithic", "test:lib-times", "test:lib-shard-harness")
        ),
        "integration gates expose aggregate monolithic and timing paths": all(
            marker in sources["build"]
            for marker in (
                'b.path("tests/integration_suite.zig")',
                'b.step("test:spike"',
                'b.step("test:integration-monolithic"',
                'b.step("test:integration-times"',
                "run_integration_reporter",
            )
        ),
        "full test includes aggregate suite": "test_step.dependOn(spike_step)" in sources["build"],
        "captured shard reports never cache test execution": (
            sources["build"].count("run_shard.has_side_effects = true") >= 2
        ),
        "default shard counts are bounded": all(
            marker in sources["build"]
            for marker in (
                '"lib-test-shards"',
                "orelse 4",
                '"integration-test-shards"',
                "orelse 8",
                "must be between 1 and 64",
            )
        ),
    }

    tinykg_artifact_repro_checks = {
        "TinyKG path and digest must be supplied together": all(
            marker in sources["build"]
            for marker in (
                '"tinykg-bin"',
                '"tinykg-sha256"',
                "must be supplied together",
            )
        ),
        "feedback stages one attested input into two isolated locations": all(
            marker in sources["artifact_repro"]
            for marker in (
                "for root in roots:",
                "stage(",
                "expected_sha256=expected_sha256",
                'target="native-test"',
            )
        ),
        "feedback compares full bytes, SHA-256, and receipts": all(
            marker in sources["artifact_repro"]
            for marker in (
                "hashlib.sha256(payloads[0])",
                "hashlib.sha256(payloads[1])",
                "self.assertEqual(payloads[0], payloads[1])",
                "self.assertEqual(receipts[0].read_bytes(), receipts[1].read_bytes())",
            )
        ),
        "feedback executes both resulting artifacts": all(
            marker in sources["artifact_repro"]
            for marker in (
                '[str(artifact), "version"]',
                "for artifact in artifacts",
                "self.assertEqual(versions[0].stdout, versions[1].stdout)",
            )
        ),
    }

    fingerprint_payload_keys: set[str] = set()
    try:
        experiment_tree = ast.parse(
            read_text(paths["experiment"]), filename=str(paths["experiment"])
        )
        identity_function = next(
            node
            for node in ast.walk(experiment_tree)
            if isinstance(node, ast.FunctionDef)
            and node.name == "formal_kernel_identity"
        )
        payload_assignment = next(
            node
            for node in ast.walk(identity_function)
            if isinstance(node, ast.Assign)
            and any(
                isinstance(target, ast.Name)
                and target.id == "fingerprint_payload"
                for target in node.targets
            )
            and isinstance(node.value, ast.Dict)
        )
        fingerprint_payload_keys = {
            key.value
            for key in payload_assignment.value.keys
            if isinstance(key, ast.Constant) and isinstance(key.value, str)
        }
    except (SyntaxError, StopIteration):
        pass

    formal_artifact_repro_checks = {
        "builder separates stable manifest from time-bearing receipt": all(
            marker in sources["formal_build"]
            for marker in (
                "metacodes-formal-artifact-v4",
                "metacodes-formal-build-receipt-v1",
                "artifact_manifest_sha256",
                "built_at_utc",
            )
        ),
        "runtime requires and rehashes the complete build receipt": all(
            marker in sources["experiment"]
            for marker in (
                "FORMAL_BUILD_RECEIPT_KEYS",
                "build_receipt_path.lstat()",
                "artifact_manifest_sha256",
                "build receipt changed during its readiness probe",
            )
        ),
        "stable fingerprint excludes the per-build receipt": (
            {
                "binary_sha256",
                "provenance_sha256",
                "checker_version",
                "request_schema",
                "memory_request_schema",
                "artifact_request_schema",
                "verdict_schema",
            }
            == fingerprint_payload_keys
            and "build_receipt_sha256" not in fingerprint_payload_keys
        ),
        "feedback invokes two complete formal builds": all(
            marker in sources["artifact_repro"]
            for marker in (
                "FormalKernelArtifactIdentityReproducibilityTest",
                "test_two_isolated_complete_builds_share_identity_and_bind_time_receipts",
                "scripts/build-formal-kernel.sh",
                "for artifact in artifacts",
            )
        ),
        "feedback compares binary manifest and stable fingerprint": all(
            marker in sources["artifact_repro"]
            for marker in (
                "self.assertEqual(payloads[0], payloads[1])",
                "self.assertEqual(manifests[0], manifests[1])",
                'identities[0]["artifact_fingerprint"]',
                'identities[1]["artifact_fingerprint"]',
            )
        ),
    }

    obligations = {
        declarations[0]: timing_checks,
        declarations[1]: sharding_checks,
        declarations[2]: aggregation_checks,
        declarations[3]: inventory_checks,
        declarations[4]: build_path_checks,
        declarations[5]: tinykg_artifact_repro_checks,
        declarations[6]: formal_artifact_repro_checks,
    }
    covered = [name for name, checks in obligations.items() if all(checks.values())]
    missing = [name for name in declarations if name not in covered]
    errors: list[str] = []
    for obligation, checks in obligations.items():
        absent = [name for name, present in checks.items() if not present]
        if absent:
            errors.append(f"{obligation}: missing {', '.join(absent)}")
    if imported_set != set(aggregate_expected):
        omitted = sorted(set(aggregate_expected) - imported_set)
        surplus = sorted(imported_set - set(aggregate_expected))
        if omitted:
            errors.append(f"aggregate_source_inventory: omitted tests: {', '.join(omitted)}")
        if surplus:
            errors.append(f"aggregate_source_inventory: stale imports: {', '.join(surplus)}")

    touched = list(paths.values()) + [tests_root / path for path in discovered]
    return Observation(
        sensor="build_test_throughput",
        sensor_ok=not errors and len(covered) == len(declarations),
        declared=len(declarations),
        covered=len(covered),
        deviation=max(len(declarations) - len(covered), 0),
        declarations=declarations,
        covered_declarations=covered,
        missing_declarations=missing,
        feedback_bindings=[
            {"step": "test:lib-shard-harness", "filter": ""},
            {"step": "test:lib", "filter": ""},
            {"step": "test:spike", "filter": ""},
            {
                "unittest": (
                    "scripts.tests.test_artifact_reproducibility."
                    "TinyKgArtifactReproducibilityTest."
                    "test_two_isolated_stages_preserve_attested_bytes_and_receipts"
                )
            },
            {
                "unittest": (
                    "scripts.tests.test_artifact_reproducibility."
                    "FormalKernelArtifactIdentityReproducibilityTest."
                    "test_two_isolated_complete_builds_share_identity_and_bind_time_receipts"
                )
            },
        ],
        errors=errors,
        fingerprint_sha256=fingerprint(touched),
    )


def observe_eval_budget_checkpoint(repo: Path) -> Observation:
    """Observe the proof-carrying budget/checkpoint transition in real code.

    Lean owns the legal phase ordering.  This adapter binds that small model to
    the Python runner, checked-in experiment caps, promotion revalidation, and
    disk-backed counterexample tests.  Source order alone is deliberately not
    enough: the focused feedback must execute the over-cap path and reload its
    checkpoint after the raised error.
    """

    declarations = [
        "fixed_arm_independent_rollout_caps",
        "whole_schedule_capacity_before_network",
        "runtime_usage_bound_to_sealed_cap",
        "invalid_marked_before_checkpoint",
        "checkpoint_committed_before_abort",
        "promotion_revalidates_fixed_budget",
    ]
    relative_sources = {
        "experiment": "scripts/eval/experiment.py",
        "runner": "scripts/eval/paired_runner.py",
        "model": "scripts/eval/model.py",
        "promotion": "scripts/eval/promotion.py",
        "experiment_tests": "scripts/eval/tests/test_experiment.py",
        "runner_tests": "scripts/eval/tests/test_paired_runner.py",
        "calibration": "evals/experiments/long-horizon-three-arm-calibration-v2.json",
        "confirmatory": "evals/experiments/long-horizon-three-arm-confirmatory-v2.json",
    }
    paths = {name: repo / relative for name, relative in relative_sources.items()}
    missing_files = [relative_sources[name] for name, path in paths.items() if not path.is_file()]
    if missing_files:
        return Observation(
            sensor="eval_budget_checkpoint",
            declared=len(declarations),
            declarations=declarations,
            missing_declarations=declarations,
            deviation=len(declarations),
            errors=[f"required budget-control source is missing: {path}" for path in missing_files],
            fingerprint_sha256=fingerprint(paths.values()),
        )

    try:
        sources = {
            name: read_text(path)
            for name, path in paths.items()
            if name not in {"calibration", "confirmatory"}
        }
        trees = {
            name: ast.parse(source, filename=str(paths[name]))
            for name, source in sources.items()
        }
        manifests = {
            name: load_json(paths[name]) for name in ("calibration", "confirmatory")
        }
        for name, manifest in manifests.items():
            if not isinstance(manifest, dict) or manifest.get("schema_version") != 2:
                raise ControlError(
                    f"{paths[name]}: evaluation schema_version must be 2"
                )
    except (ControlError, SyntaxError) as exc:
        return Observation(
            sensor="eval_budget_checkpoint",
            declared=len(declarations),
            declarations=declarations,
            missing_declarations=declarations,
            deviation=len(declarations),
            errors=[f"budget-control source cannot be observed: {exc}"],
            fingerprint_sha256=fingerprint(paths.values()),
        )

    def function_node(tree_name: str, name: str) -> ast.FunctionDef | None:
        return next(
            (
                node
                for node in ast.walk(trees[tree_name])
                if isinstance(node, ast.FunctionDef) and node.name == name
            ),
            None,
        )

    def function_source(tree_name: str, name: str) -> str:
        node = function_node(tree_name, name)
        if node is None:
            return ""
        return ast.get_source_segment(sources[tree_name], node) or ""

    def call_nodes(function: ast.FunctionDef | None, name: str) -> list[ast.Call]:
        if function is None:
            return []
        return sorted(
            (
                node
                for node in ast.walk(function)
                if isinstance(node, ast.Call)
                and (
                    (isinstance(node.func, ast.Name) and node.func.id == name)
                    or (isinstance(node.func, ast.Attribute) and node.func.attr == name)
                )
            ),
            key=lambda node: node.lineno,
        )

    entrypoint = function_node("runner", "run_multi_arm")
    runner = function_node("runner", "_run_multi_arm_locked")
    locked_runner_calls = call_nodes(entrypoint, "_run_multi_arm_locked")
    locked_runner_reachable = len(locked_runner_calls) == 1
    capacity_calls = call_nodes(runner, "_require_remaining_schedule_capacity")
    run_once_calls = call_nodes(runner, "_run_once")
    mark_calls = call_nodes(runner, "_mark_runtime_budget_invalid")
    write_calls = call_nodes(runner, "write_rollouts")
    provenance_calls = call_nodes(runner, "_require_runtime_budget_provenance")
    budget_abort_lines = (
        []
        if runner is None
        else sorted(
            node.lineno
            for node in ast.walk(runner)
            if isinstance(node, ast.Raise)
            and isinstance(node.exc, ast.Name)
            and node.exc.id == "runtime_budget_error"
        )
    )

    calibration_budget = manifests["calibration"].get("budget", {})
    confirmatory_budget = manifests["confirmatory"].get("budget", {})
    cap_keys = ("max_rollout_cost_usd", "max_rollout_tokens")
    caps_match = all(
        key in calibration_budget
        and calibration_budget.get(key) == confirmatory_budget.get(key)
        for key in cap_keys
    )
    fixed_source = function_source("experiment", "fixed_rollout_budget")
    validate_source = function_source("experiment", "validate_experiment")
    capacity_source = function_source("runner", "_require_remaining_schedule_capacity")
    provenance_source = function_source("runner", "_require_runtime_budget_provenance")
    invalid_source = function_source("runner", "_mark_runtime_budget_invalid")
    writer_source = function_source("model", "write_rollouts")
    promotion_source = function_source("promotion", "validate_multi_arm_evidence")
    capacity_test = function_source(
        "experiment_tests",
        "test_multi_arm_rejects_infeasible_remaining_schedule_before_rollout",
    )
    checkpoint_test = function_source(
        "experiment_tests",
        "test_multi_arm_checkpoints_runtime_budget_overrun_before_abort",
    )
    promotion_test = function_source(
        "experiment_tests", "test_promotion_rechecks_fixed_runtime_budget_and_usage"
    )

    run_once_bindings = [
        {
            keyword.arg: ast.unparse(keyword.value)
            for keyword in call.keywords
            if keyword.arg is not None
        }
        for call in run_once_calls
    ]
    first_run_line = min((node.lineno for node in run_once_calls), default=-1)
    capacity_lines = [node.lineno for node in capacity_calls]
    mark_lines = [node.lineno for node in mark_calls]
    write_lines = [node.lineno for node in write_calls]
    provenance_lines = [node.lineno for node in provenance_calls]

    obligations = {
        declarations[0]: {
            "both stages freeze identical dollar and token caps": caps_match,
            "cap parser requires both dimensions": all(
                marker in fixed_source
                for marker in (
                    "FIXED_ROLLOUT_BUDGET_KEYS",
                    "must provide both",
                    "max_rollout_cost_usd",
                    "max_rollout_tokens",
                )
            ),
            "manifest validation reserves every registered rollout": all(
                marker in validate_source
                for marker in (
                    "expected_rollouts",
                    "rollout_cost * expected_rollouts",
                    "rollout_tokens * expected_rollouts",
                    "strictly cover every fixed per-rollout cap",
                )
            ),
        },
        declarations[1]: {
            "public entrypoint reaches the locked paid runner": locked_runner_reachable,
            "initial and per-rollout capacity checks precede network": (
                len(capacity_lines) >= 2
                and first_run_line > 0
                and all(line < first_run_line for line in capacity_lines)
            ),
            "capacity uses strict stage and aggregate reserve": all(
                marker in capacity_source
                for marker in (
                    "_remaining_multi_budget",
                    "remaining_cost <= required_cost",
                    "remaining_tokens <= required_tokens",
                )
            ),
            "counterexample proves zero paid calls": all(
                marker in capacity_test
                for marker in (
                    "not budget-feasible before network",
                    "run_once.assert_not_called()",
                )
            ),
        },
        declarations[2]: {
            "native call receives the frozen two-dimensional cap": (
                len(run_once_bindings) == 1
                and run_once_bindings[0].get("max_metered_tokens")
                == "runtime_max_metered_tokens"
                and run_once_bindings[0].get("max_cost_usd")
                == "runtime_max_cost_usd"
            ),
            "normalized telemetry is compared with sealed provenance": all(
                marker in provenance_source
                for marker in (
                    "TOKEN_METRICS",
                    "observed_cost > float(max_cost_usd)",
                    "observed_tokens > max_metered_tokens",
                )
            ),
            "resume and new evidence both pass provenance validation": len(provenance_lines) >= 2,
        },
        declarations[3]: {
            "failure order belongs to the connected paid runner": locked_runner_reachable,
            "invalid marker executes before checkpoint publication": (
                len(mark_lines) == 1
                and len(write_lines) == 1
                and mark_lines[0] < write_lines[0]
            ),
            "marker changes execution judgement and attribution": all(
                marker in invalid_source
                for marker in (
                    'execution["status"] = "invalid"',
                    'reasons.append("runtime_budget_contract_violation")',
                    '["valid_for_scoring"] = False',
                    '"code": "runtime_budget_contract_violation"',
                )
            ),
        },
        declarations[4]: {
            "abort order belongs to the connected paid runner": locked_runner_reachable,
            "checkpoint publication precedes budget abort": (
                len(write_lines) == 1
                and len(budget_abort_lines) == 1
                and write_lines[0] < budget_abort_lines[0]
            ),
            "checkpoint writer validates fsyncs and atomically replaces": all(
                marker in writer_source
                for marker in (
                    "validate_rollout",
                    "tempfile.NamedTemporaryFile",
                    "dir=path.parent",
                    "handle.flush()",
                    "os.fsync(handle.fileno())",
                    "os.replace(temp_path, path)",
                )
            ),
            "disk-backed counterexample reloads invalid evidence after abort": all(
                marker in checkpoint_test
                for marker in (
                    "with self.assertRaisesRegex",
                    'load_rollouts(output_dir / "codex_style.jsonl")',
                    'checkpoint[0]["execution"]["status"], "invalid"',
                    '"runtime_budget_contract_violation"',
                )
            ),
        },
        declarations[5]: {
            "promotion rechecks exact cap and measured usage": all(
                marker in promotion_source
                for marker in (
                    "fixed_rollout_budget",
                    "expected_runtime_budget",
                    "observed_tokens > fixed_rollout_tokens",
                    "float(observed_cost) > fixed_rollout_cost",
                )
            ),
            "promotion has cap-drift and overrun counterexamples": all(
                marker in promotion_test
                for marker in (
                    "runtime budget is not the frozen",
                    "exceeded its frozen per-rollout budget",
                )
            ),
        },
    }
    covered = [name for name, checks in obligations.items() if all(checks.values())]
    missing = [name for name in declarations if name not in covered]
    errors: list[str] = []
    for obligation, checks in obligations.items():
        absent = [name for name, present in checks.items() if not present]
        if absent:
            errors.append(f"{obligation}: missing {', '.join(absent)}")

    return Observation(
        sensor="eval_budget_checkpoint",
        sensor_ok=not errors and len(covered) == len(declarations),
        declared=len(declarations),
        covered=len(covered),
        deviation=max(len(declarations) - len(covered), 0),
        declarations=declarations,
        covered_declarations=covered,
        missing_declarations=missing,
        feedback_bindings=[
            {
                "unittest": (
                    "scripts.eval.tests.test_experiment.LongHorizonExperimentTest."
                    "test_multi_arm_rejects_infeasible_remaining_schedule_before_rollout"
                )
            },
            {
                "unittest": (
                    "scripts.eval.tests.test_experiment.LongHorizonExperimentTest."
                    "test_multi_arm_checkpoints_runtime_budget_overrun_before_abort"
                )
            },
            {
                "unittest": (
                    "scripts.eval.tests.test_experiment.LongHorizonExperimentTest."
                    "test_promotion_rechecks_fixed_runtime_budget_and_usage"
                )
            },
        ],
        errors=errors,
        fingerprint_sha256=fingerprint(paths.values()),
    )


def observe_treatment_activation(repo: Path) -> Observation:
    """Bind the formal treatment lifecycle to execution, recovery, and promotion.

    The Lean kernel owns the legal create/claim/complete/store-verify order.  The
    sensor refuses to call that model connected unless real tests exercise the
    runner checkpoint path, resume-before-network gate, and promotion-time raw
    artifact revalidation with a real TinyKG store.
    """

    declarations = [
        "prompt_and_arm_treatment_isolation",
        "native_transcript_store_attestation",
        "persistent_lifecycle_admission",
        "treatment_failure_checkpoint_before_abort",
        "resume_reverification_before_network",
        "promotion_reverification_from_raw_artifacts",
        "real_tinykg_and_tamper_counterexamples",
        "multi_invocation_and_compaction_evidence_integrity",
    ]
    relative_sources = {
        "prompt": "src/kg/task_protocol.zig",
        "prompt_test": "tests/component/prompt_tool_coupling_test.zig",
        "conversation": "src/core/conversation.zig",
        "microcompact_test": "tests/component/microcompact_test.zig",
        "attester": "scripts/eval/treatment_activation.py",
        "model": "scripts/eval/model.py",
        "runner": "scripts/eval/paired_runner.py",
        "promotion": "scripts/eval/promotion.py",
        "cli": "scripts/eval/cli.py",
        "attester_tests": "scripts/eval/tests/test_treatment_activation.py",
        "experiment_tests": "scripts/eval/tests/test_experiment.py",
    }
    paths = {name: repo / relative for name, relative in relative_sources.items()}
    missing_files = [relative_sources[name] for name, path in paths.items() if not path.is_file()]
    if missing_files:
        return Observation(
            sensor="treatment_activation",
            declared=len(declarations),
            declarations=declarations,
            missing_declarations=declarations,
            deviation=len(declarations),
            errors=[f"required treatment-control source is missing: {path}" for path in missing_files],
            fingerprint_sha256=fingerprint(paths.values()),
        )

    try:
        sources = {name: read_text(path) for name, path in paths.items()}
        trees = {
            name: ast.parse(sources[name], filename=str(paths[name]))
            for name in (
                "attester",
                "model",
                "runner",
                "promotion",
                "cli",
                "attester_tests",
                "experiment_tests",
            )
        }
    except (ControlError, SyntaxError) as exc:
        return Observation(
            sensor="treatment_activation",
            declared=len(declarations),
            declarations=declarations,
            missing_declarations=declarations,
            deviation=len(declarations),
            errors=[f"treatment-control source cannot be observed: {exc}"],
            fingerprint_sha256=fingerprint(paths.values()),
        )

    def function_node(tree_name: str, name: str) -> ast.FunctionDef | None:
        return next(
            (
                node
                for node in ast.walk(trees[tree_name])
                if isinstance(node, ast.FunctionDef) and node.name == name
            ),
            None,
        )

    def function_source(tree_name: str, name: str) -> str:
        node = function_node(tree_name, name)
        if node is None:
            return ""
        return ast.get_source_segment(sources[tree_name], node) or ""

    def call_lines(function: ast.FunctionDef | None, name: str) -> list[int]:
        if function is None:
            return []
        return sorted(
            node.lineno
            for node in ast.walk(function)
            if isinstance(node, ast.Call)
            and (
                (isinstance(node.func, ast.Name) and node.func.id == name)
                or (isinstance(node.func, ast.Attribute) and node.func.attr == name)
            )
        )

    entrypoint = function_node("runner", "run_multi_arm")
    runner = function_node("runner", "_run_multi_arm_locked")
    locked_runner_reachable = (
        len(call_lines(entrypoint, "_run_multi_arm_locked")) == 1
    )
    attach_lines = call_lines(runner, "attach_treatment_activation")
    mark_lines = call_lines(runner, "_mark_treatment_activation_invalid")
    write_lines = call_lines(runner, "write_rollouts")
    load_lines = call_lines(runner, "_load_checkpoint")
    run_lines = call_lines(runner, "_run_once")
    treatment_abort_lines = (
        []
        if runner is None
        else sorted(
            node.lineno
            for node in ast.walk(runner)
            if isinstance(node, ast.Raise)
            and isinstance(node.exc, ast.Name)
            and node.exc.id == "treatment_error"
        )
    )

    prompt_source = sources["prompt"]
    prompt_test = sources["prompt_test"]
    bind_source = function_source("attester", "_bind_all_tool_calls")
    native_parser_source = function_source("attester", "_parse_native_events")
    commitment_source = function_source("attester", "_tool_result_commitment")
    lifecycle_source = function_source("attester", "_task_lifecycle")
    store_source = function_source("attester", "_store_packet")
    store_verify_source = function_source("attester", "_verify_store_packet")
    attest_source = function_source("attester", "attest_treatment_activation")
    receipt_source = function_source("model", "validate_treatment_activation_receipt")
    writer_source = function_source("model", "write_rollouts")
    marker_source = function_source("runner", "_mark_treatment_activation_invalid")
    load_source = function_source("runner", "_load_checkpoint")
    promotion_source = function_source("promotion", "validate_multi_arm_evidence")
    cli_source = sources["cli"]
    attester_tests = sources["attester_tests"]
    experiment_tests = sources["experiment_tests"]
    checkpoint_test = function_source(
        "experiment_tests", "test_multi_arm_checkpoints_treatment_failure_before_abort"
    )
    checkpoint_failure_test = function_source(
        "experiment_tests",
        "test_multi_arm_does_not_abort_past_failed_treatment_checkpoint",
    )
    resume_test = function_source(
        "experiment_tests", "test_multi_arm_resume_reverifies_treatment_before_network"
    )
    runner_real_test = function_source(
        "experiment_tests", "test_multi_arm_attaches_real_tinykg_receipt_before_checkpoint"
    )
    promotion_real_test = function_source(
        "experiment_tests", "test_promotion_reverifies_all_raw_treatment_artifacts"
    )
    multi_invocation_runner_test = function_source(
        "experiment_tests",
        "test_multi_arm_checkpoints_real_multi_invocation_baseline_receipt",
    )

    failure_order = (
        locked_runner_reachable
        and len(attach_lines) == 1
        and len(mark_lines) == 1
        and len(write_lines) == 1
        and len(treatment_abort_lines) == 1
        and attach_lines[0] < mark_lines[0] < write_lines[0] < treatment_abort_lines[0]
    )
    resume_before_network = (
        locked_runner_reachable
        and len(load_lines) == 1
        and len(run_lines) == 1
        and load_lines[0] < run_lines[0]
        and "reverify_treatment_activation" in load_source
    )

    obligations = {
        declarations[0]: {
            "prompt activates one persistent anchor and requires verified closure": all(
                marker in prompt_source
                for marker in (
                    "ACTIVATE:",
                    "create exactly one persistent lifecycle anchor",
                    "persisted: true",
                    "after verifying the final artifacts",
                )
            ),
            "component test proves baseline prompt exclusion": all(
                marker in prompt_test
                for marker in (
                    '"ACTIVATE:"',
                    "tinykg_prompt",
                    "baseline_prompt",
                    "== null",
                )
            ),
        },
        declarations[1]: {
            "transcript and native calls have exact identities and byte hashes": all(
                marker in bind_source
                for marker in (
                    "transcript_ids != native_ids",
                    "_bind_tool_call",
                    "require_success=False",
                )
            )
            and all(
                marker in sources["attester"]
                for marker in ("input_sha256", "result_sha256", "events_sha256", "transcript_sha256")
            ),
            "store is read by the frozen TinyKG binary": all(
                marker in store_source
                for marker in (
                    "expected_tinykg_sha256",
                    '"task-packet"',
                    "resolved_store.relative_to(workspace)",
                    "after != before",
                )
            ),
        },
        declarations[2]: {
            "one task moves create claim complete in event order": all(
                marker in lifecycle_source
                for marker in (
                    "exactly one execution-grounded TaskCreate",
                    'task.get("persisted") is not True',
                    'status") == "in_progress"',
                    'status") == "completed"',
                    "create_native.finished_sequence < claim_native.started_sequence",
                )
            ),
            "terminal store packet requires verification evidence": all(
                marker in store_verify_source
                for marker in (
                    'query.get("status") != "completed"',
                    'edge.get("rel") == "verified_by"',
                    'node_kinds.get(edge.get("dst")) == "verification"',
                )
            ),
            "receipt schema freezes lifecycle phases and terminal task": all(
                marker in receipt_source
                for marker in (
                    '["created", "claimed", "completed"]',
                    'task.get("kind") != "task"',
                    'task.get("status") != "completed"',
                    'store.get("present") is not True',
                )
            ),
        },
        declarations[3]: {
            "production failure path is mark then checkpoint then abort": failure_order,
            "failure marker is unscorable and attributed": all(
                marker in marker_source
                for marker in (
                    'execution["status"] = "invalid"',
                    'reasons.append("treatment_activation_failed")',
                    'judgement["valid_for_scoring"] = False',
                    '"code": "treatment_activation_failed"',
                )
            ),
            "checkpoint publication validates flushes and atomically replaces": all(
                marker in writer_source
                for marker in (
                    "validate_rollout",
                    "tempfile.NamedTemporaryFile",
                    "dir=path.parent",
                    "handle.flush()",
                    "os.fsync(handle.fileno())",
                    "os.replace(temp_path, path)",
                )
            ),
            "disk counterexample reloads the real runner checkpoint": all(
                marker in checkpoint_test
                for marker in (
                    "run_multi_arm(",
                    'load_rollouts(output_dir / "codex_style.jsonl")',
                    '"treatment_activation_failed"',
                    "attester.assert_called_once()",
                )
            ),
            "failed publication cannot be mistaken for the original abort": all(
                marker in checkpoint_failure_test
                for marker in (
                    'side_effect=OSError("checkpoint commit failed")',
                    'self.assertRaisesRegex(OSError, "checkpoint commit failed")',
                    "checkpoint_writer.assert_called_once()",
                    'written_rows[0]["execution"]["status"], "invalid"',
                    'self.assertFalse((output_dir / "codex_style.jsonl").exists())',
                )
            ),
        },
        declarations[4]: {
            "checkpoint reattestation precedes any paid runner call": resume_before_network,
            "resume counterexample proves zero next calls": all(
                marker in resume_test
                for marker in (
                    'side_effect=ValidationError("activation artifacts changed")',
                    "verifier.assert_called_once()",
                    "run_once.assert_not_called()",
                )
            ),
        },
        declarations[5]: {
            "promotion recomputes receipts while checkpoint hashes stay stable": all(
                marker in promotion_source
                for marker in (
                    "reverify_treatment_activation",
                    "before_sha256",
                    "after_sha256",
                    "before_sha256 != after_sha256",
                )
            ),
            "promotion and reporting require a TinyKG verifier binary": (
                cli_source.count('add_argument("--tinykg-binary", required=True)') >= 3
                and "tinykg_binary=Path(args.tinykg_binary)" in cli_source
            ),
        },
        declarations[6]: {
            "attester negative tests cover omitted calls tamper symlink and binary drift": all(
                name in attester_tests
                for name in (
                    "test_baseline_cannot_hide_native_kg_call_by_removing_transcript_rows",
                    "test_transcript_tamper_breaks_native_hash_binding",
                    "test_store_symlink_is_rejected",
                    "test_wrong_frozen_binary_hash_is_rejected",
                )
            ),
            "real runner persists and rereads a real TinyKG receipt": all(
                marker in runner_real_test
                for marker in (
                    "real_attach_treatment_activation",
                    "real_reverify_treatment_activation",
                    'load_rollouts(output_dir / "tinykg.jsonl")',
                )
            ),
            "promotion rechecks all raw artifacts and rejects mutation": all(
                marker in promotion_real_test
                for marker in (
                    "real_attach_treatment_activation",
                    "real_reverify_treatment_activation",
                    '"artifacts changed after attestation"',
                    'receipt["gate"]["valid_rollouts"], 18',
                )
            ),
            "attester output is validated before admission": (
                "validate_treatment_activation_receipt" in attest_source
            ),
        },
        declarations[7]: {
            "native traces validate each invocation before normalizing global order": all(
                marker in native_parser_source
                for marker in (
                    "invocation != len(run_metadata)",
                    "trace_id != active_trace_id",
                    "global_sequence = row_no - 1",
                    "dropped_events != 0",
                )
            ),
            "context projections retain execution-time byte commitments": all(
                marker in sources["conversation"]
                for marker in (
                    "TOOL_RESULT_COMMITMENT_PREFIX",
                    "sha256Hex(tr.content)",
                    "new_content.len >= tr.content.len",
                )
            )
            and all(
                marker in commitment_source
                for marker in (
                    "TOOL_RESULT_COMMITMENT_RE.fullmatch",
                    "lacks a byte commitment",
                    "invalid byte commitment",
                )
            ),
            "positive and negative fixtures cover invocation resets and compacted results": all(
                name in attester_tests
                for name in (
                    "test_baseline_accepts_contiguous_multi_invocation_native_trace",
                    "test_multi_invocation_gap_is_rejected",
                    "test_sequence_reset_without_new_invocation_is_rejected",
                    "test_compacted_lifecycle_results_retain_native_hash_and_store_binding",
                    "test_legacy_compaction_stub_without_commitment_is_rejected",
                )
            )
            and "isCommittedToolResultProjection" in sources["microcompact_test"],
            "real multi-arm path checkpoints a multi-invocation baseline receipt": all(
                marker in multi_invocation_runner_test
                for marker in (
                    "run_multi_arm(",
                    "append_baseline_invocation(",
                    'load_rollouts(output_dir / "codex_style.jsonl")',
                    '"persistent_tinykg_lifecycle_absent"',
                )
            ),
        },
    }
    covered = [name for name, checks in obligations.items() if all(checks.values())]
    missing = [name for name in declarations if name not in covered]
    errors: list[str] = []
    for obligation, checks in obligations.items():
        absent = [name for name, present in checks.items() if not present]
        if absent:
            errors.append(f"{obligation}: missing {', '.join(absent)}")

    return Observation(
        sensor="treatment_activation",
        sensor_ok=not errors and len(covered) == len(declarations),
        declared=len(declarations),
        covered=len(covered),
        deviation=max(len(declarations) - len(covered), 0),
        declarations=declarations,
        covered_declarations=covered,
        missing_declarations=missing,
        feedback_bindings=[
            {"unittest": "scripts.eval.tests.test_treatment_activation.TreatmentActivationTest"},
            {
                "unittest": (
                    "scripts.eval.tests.test_experiment.LongHorizonExperimentTest."
                    "test_multi_arm_checkpoints_real_multi_invocation_baseline_receipt"
                )
            },
            {
                "unittest": (
                    "scripts.eval.tests.test_experiment.LongHorizonExperimentTest."
                    "test_multi_arm_checkpoints_treatment_failure_before_abort"
                )
            },
            {
                "unittest": (
                    "scripts.eval.tests.test_experiment.LongHorizonExperimentTest."
                    "test_multi_arm_does_not_abort_past_failed_treatment_checkpoint"
                )
            },
            {
                "unittest": (
                    "scripts.eval.tests.test_experiment.LongHorizonExperimentTest."
                    "test_multi_arm_resume_reverifies_treatment_before_network"
                )
            },
            {
                "unittest": (
                    "scripts.eval.tests.test_experiment.LongHorizonExperimentTest."
                    "test_promotion_reverifies_all_raw_treatment_artifacts"
                )
            },
        ],
        errors=errors,
        fingerprint_sha256=fingerprint(paths.values()),
    )


def observe_memory_local_store_isolation(repo: Path) -> Observation:
    """Observe the executable boundary between memory evals and remote TinyKG.

    This adapter deliberately reads fixed production, L2, CLI, and pin paths.
    Manifest prose cannot certify itself: source obligations are extracted from
    Python AST nodes, feedback executes the real vendored binary, and the pin is
    checked as a structured three-adapter provenance record.
    """

    declarations = [
        "direct_hash_pinned_binary_without_skill_harness",
        "sealed_child_environment_without_remote_configuration",
        "fresh_run_local_path_containment",
        "raw_store_digest_guards_read_phase",
        "three_adapter_native_sentinel_and_fault_l2",
        "three_trace_identity_and_zero_remote_pin",
        "native_runtime_explicitly_selects_exclusive_cli",
    ]
    relative_sources = {
        "runtime": "scripts/eval/memory_tinykg_local.py",
        "cli": "scripts/eval/cli.py",
        "tests": "scripts/eval/tests/test_memory_tinykg_local.py",
        "pin": "evals/memory/pins/local-tinykg-memory-smoke-pin.json",
        "native_runtime": "scripts/eval/memory_agent_runtime.py",
        "arm_smoke": "scripts/eval/runtime_arm_smoke.py",
    }
    paths = {name: repo / relative for name, relative in relative_sources.items()}
    missing_files = [relative_sources[name] for name, path in paths.items() if not path.is_file()]
    if missing_files:
        return Observation(
            sensor="memory_local_store_isolation",
            declared=len(declarations),
            declarations=declarations,
            missing_declarations=declarations,
            deviation=len(declarations),
            errors=[f"required memory-isolation source is missing: {path}" for path in missing_files],
            fingerprint_sha256=fingerprint(paths.values()),
        )

    try:
        sources = {
            name: read_text(path)
            for name, path in paths.items()
            if name != "pin"
        }
        trees = {
            name: ast.parse(source, filename=str(paths[name]))
            for name, source in sources.items()
        }
        pin = require_schema(load_json(paths["pin"]), paths["pin"])
    except (ControlError, SyntaxError) as exc:
        return Observation(
            sensor="memory_local_store_isolation",
            declared=len(declarations),
            declarations=declarations,
            missing_declarations=declarations,
            deviation=len(declarations),
            errors=[f"memory-isolation source cannot be observed: {exc}"],
            fingerprint_sha256=fingerprint(paths.values()),
        )

    def module_function_source(tree_name: str, function_name: str) -> str:
        node = next(
            (
                item
                for item in trees[tree_name].body
                if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef))
                and item.name == function_name
            ),
            None,
        )
        return ast.get_source_segment(sources[tree_name], node) if node is not None else ""

    def class_source(tree_name: str, class_name: str) -> str:
        node = next(
            (
                item
                for item in trees[tree_name].body
                if isinstance(item, ast.ClassDef) and item.name == class_name
            ),
            None,
        )
        return ast.get_source_segment(sources[tree_name], node) if node is not None else ""

    def class_method_source(tree_name: str, class_name: str, method_name: str) -> str:
        class_node = next(
            (
                item
                for item in trees[tree_name].body
                if isinstance(item, ast.ClassDef) and item.name == class_name
            ),
            None,
        )
        if class_node is None:
            return ""
        node = next(
            (
                item
                for item in class_node.body
                if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef))
                and item.name == method_name
            ),
            None,
        )
        return ast.get_source_segment(sources[tree_name], node) if node is not None else ""

    local_init = class_method_source("runtime", "LocalTinyKg", "__init__")
    local_environment = class_method_source("runtime", "LocalTinyKg", "_environment")
    local_command = class_method_source("runtime", "LocalTinyKg", "command")
    smoke_source = module_function_source("runtime", "run_local_tinykg_smoke")
    tree_digest_source = module_function_source("runtime", "_tree_digest")
    cli_command = module_function_source("cli", "cmd_smoke_local_tinykg_memory")
    cli_module = sources["cli"]
    native_runtime = sources["native_runtime"]
    arm_smoke = sources["arm_smoke"]

    imports_harness = any(
        (
            isinstance(node, ast.Import)
            and any("tinykg_harness" in alias.name for alias in node.names)
        )
        or (
            isinstance(node, ast.ImportFrom)
            and "tinykg_harness" in (node.module or "")
        )
        for node in ast.walk(trees["runtime"])
    )
    runtime_subprocess_calls = [
        node
        for node in ast.walk(trees["runtime"])
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and isinstance(node.func.value, ast.Name)
        and node.func.value.id == "subprocess"
    ]
    supported_adapter_values: set[str] = set()
    for node in trees["runtime"].body:
        if not isinstance(node, ast.Assign) or not any(
            isinstance(target, ast.Name) and target.id == "SUPPORTED_ADAPTERS"
            for target in node.targets
        ):
            continue
        supported_adapter_values = {
            item.value
            for item in ast.walk(node.value)
            if isinstance(item, ast.Constant) and isinstance(item.value, str)
        }

    native_test = class_method_source(
        "tests",
        "LocalTinyKgNativeTest",
        "test_real_local_cli_isolated_store_and_remote_sentinels_remain_untouched",
    )
    hash_and_fresh_test = class_method_source(
        "tests",
        "LocalTinyKgNativeTest",
        "test_wrong_binary_hash_and_preexisting_run_fail_before_store_creation",
    )
    mutation_test = class_method_source(
        "tests",
        "LocalTinyKgFailClosedTest",
        "test_read_only_store_mutation_fails_closed",
    )
    escape_test = class_method_source(
        "tests",
        "LocalTinyKgFailClosedTest",
        "test_output_must_remain_inside_fresh_run_directory",
    )
    batch_test_class = class_source("tests", "LocalTinyKgBatchTest")

    remote_keys = {
        "TINYKG_STORE",
        "TINYKG_REMOTE_URL",
        "TINYKG_API_KEY",
        "TINYKG_REMOTE_EXPECTED_BUILD_ID",
        "TINYKG_REMOTE_CONFIG",
        "METACODES_KG_CONFIG",
        "METACODES_KG_URL",
        "METACODES_KG_API_KEY",
        "METACODES_KG_EXPECTED_BUILD_ID",
        "METACODES_KG_EXPECTED_SCHEMA_DIGEST",
    }

    def hash_hex(value: Any) -> bool:
        return (
            isinstance(value, str)
            and len(value) == 64
            and all(character in "0123456789abcdef" for character in value)
        )

    def commit_hex(value: Any) -> bool:
        return (
            isinstance(value, str)
            and len(value) == 40
            and all(character in "0123456789abcdef" for character in value)
        )

    implementation = pin.get("implementation")
    isolation = pin.get("isolation")
    tinykg = pin.get("tinykg")
    traces = pin.get("traces")
    verification = pin.get("verification")
    pin_objects = all(
        isinstance(value, dict)
        for value in (implementation, isolation, tinykg, verification)
    ) and isinstance(traces, list)
    expected_adapters = {
        "coding-intent-families",
        "hotpotqa-distractor",
        "longmemeval-s-cleaned",
    }
    trace_adapters = {
        trace.get("adapter_id")
        for trace in traces
        if isinstance(trace, dict) and isinstance(trace.get("adapter_id"), str)
    } if isinstance(traces, list) else set()
    trace_identity_complete = (
        isinstance(traces, list)
        and len(traces) == 3
        and trace_adapters == expected_adapters
        and all(
            isinstance(trace, dict)
            and all(
                hash_hex(trace.get(field))
                for field in (
                    "source_sha256",
                    "manifest_sha256",
                    "batch_sha256",
                    "graph_revision",
                    "trace_sha256",
                )
            )
            and trace.get("read_only_preserved") is True
            and type(trace.get("nodes")) is int
            and trace["nodes"] > 0
            and type(trace.get("retrieval_hits")) is int
            and trace["retrieval_hits"] > 0
            and type(trace.get("graph_probe_nodes")) is int
            and trace["graph_probe_nodes"] > 0
            for trace in traces
        )
    )
    pin_zero_remote = (
        isinstance(isolation, dict)
        and isolation.get("direct_cli") is True
        and isolation.get("remote_environment_removed") is True
        and isolation.get("stores_below_fresh_run_directory") is True
        and isolation.get("read_phase_raw_store_digest_guard") is True
        and isolation.get("external_store_sentinel_unchanged_in_l2") is True
        and isolation.get("read_phase_write_fault_injection_rejected") is True
        and isolation.get("skill_harness_invocations") == 0
        and isolation.get("remote_api_calls") == 0
        and isolation.get("remote_store_writes") == 0
    )
    pin_identity = (
        isinstance(implementation, dict)
        and commit_hex(implementation.get("commit"))
        and implementation.get("entrypoint")
        == "scripts.eval.cli smoke-local-tinykg-memory"
        and implementation.get("trace_schema_version") == 1
        and isinstance(tinykg, dict)
        and tinykg.get("binary") == "zig-out/vendor/tinykg/tinykg"
        and hash_hex(tinykg.get("binary_sha256"))
        and type(tinykg.get("storage_format_version")) is int
        and tinykg["storage_format_version"] >= 1
        and isinstance(verification, dict)
        and type(verification.get("native_local_tinykg_cases")) is int
        and verification["native_local_tinykg_cases"] >= 1
        and type(verification.get("targeted_tests_passed")) is int
        and verification["targeted_tests_passed"] >= 7
        and verification.get("targeted_tests_skipped") == 0
    )

    obligations = {
        declarations[0]: {
            "runtime has no TinyKG skill-harness import": not imports_harness,
            "runtime has one explicit subprocess boundary": len(runtime_subprocess_calls) == 1,
            "binary hash is checked before execution": all(
                marker in local_init
                for marker in (
                    "file_sha256(self.binary)",
                    "_hash(expected_sha256",
                    "SHA-256 mismatch",
                )
            ),
            "command invokes the explicit binary and explicit store": all(
                marker in local_command
                for marker in (
                    "argv = [str(self.binary), action, str(resolved_store)",
                    "subprocess.run(",
                    "env=env",
                )
            ),
            "CLI requires and forwards the expected binary hash": all(
                marker in cli_command
                for marker in (
                    "run_local_tinykg_smoke(",
                    "binary=Path(args.binary)",
                    "expected_binary_sha256=args.expected_binary_sha256",
                )
            )
            and 'add_argument("--expected-binary-sha256", required=True)' in cli_module,
        },
        declarations[1]: {
            "child drops every TinyKG variable and replaces host directories": all(
                marker in local_environment
                for marker in (
                    'if not key.startswith("TINYKG_")',
                    'and not key.startswith("METACODES_KG_")',
                    'key not in {"HOME", "TMPDIR", "TMP", "TEMP"}',
                    '"HOME": str(self.sealed_home)',
                    '"TMPDIR": str(self.child_tmp)',
                )
            ),
            "runtime rejects leaked TinyKG keys": all(
                marker in local_command
                for marker in (
                    'key.startswith("TINYKG_") or key.startswith("METACODES_KG_")',
                    "contains forbidden keys",
                )
            ),
            "native L2 poisons every remote and store variable": all(
                key in native_test for key in remote_keys
            )
            and "mock.patch.dict(os.environ, poisoned, clear=False)" in native_test,
        },
        declarations[2]: {
            "run directory must be fresh and owns all child roots": all(
                marker in local_init
                for marker in (
                    "if self.run_dir.exists()",
                    "must not already exist",
                    'self.store_root = self.run_dir / "stores"',
                    'self.sealed_home = self.run_dir / "sealed-home"',
                )
            ),
            "store and output are resolved below owned roots": all(
                marker in local_command
                for marker in (
                    "resolved_store.relative_to(self.store_root)",
                    "store escapes the isolated store root",
                )
            )
            and all(
                marker in smoke_source
                for marker in (
                    "resolved_output.relative_to(resolved_run_dir)",
                    "output must stay inside the fresh run directory",
                )
            ),
            "L2 rejects preexisting runs and escaping output": all(
                marker in hash_and_fresh_test
                for marker in ("SHA-256 mismatch", "must not already exist")
            )
            and all(
                marker in escape_test
                for marker in ("output must stay inside", "self.assertFalse(run_dir.exists())")
            ),
        },
        declarations[3]: {
            "raw digest includes the complete store tree": all(
                marker in tree_digest_source
                for marker in (
                    'for path in sorted(root.rglob("*"))',
                    "unexpected symlink",
                    'if not path.is_file() or path.name.endswith(".lock")',
                    "sha256",
                )
            ),
            "unnormalized digest brackets every read": all(
                marker in smoke_source
                for marker in (
                    "raw_before_reads = _tree_digest(store)",
                    '"search",',
                    '"neighbors",',
                    "raw_after_reads = _tree_digest(store)",
                    "if raw_before_reads != raw_after_reads",
                    "read-only search/traversal changed store contents",
                )
            ),
            "fault injection proves a read mutation is rejected": all(
                marker in mutation_test
                for marker in (
                    '"FAKE_MUTATE_ON_READ": "1"',
                    "read-only search/traversal changed",
                    'self.assertFalse((run_dir / "trace.json").exists())',
                )
            ),
        },
        declarations[4]: {
            "all three adapters have graph-materialization L2": all(
                name in batch_test_class
                for name in (
                    "test_hotpot_batch_contains_public_sentences_and_graph_edges",
                    "test_longmem_turn_nodes_map_back_to_official_session_unit",
                    "test_procedural_batch_uses_online_evidence_and_queries_offline_sibling",
                )
            ),
            "runtime admits exactly the three benchmark adapters": (
                supported_adapter_values == expected_adapters
            ),
            "native L2 proves remote sentinels stay unchanged": all(
                marker in native_test
                for marker in (
                    'marker.write_text("remote-canonical-store"',
                    "run_local_tinykg_smoke(",
                    'marker.read_text(encoding="utf-8"), "remote-canonical-store"',
                    'trace["isolation"]["skill_harness_invocations"], 0',
                    'trace["isolation"]["remote_api_calls"], 0',
                    'trace["isolation"]["remote_store_writes"], 0',
                )
            ),
            "fault and binary drift paths fail closed": bool(mutation_test)
            and all(
                marker in hash_and_fresh_test
                for marker in ("SHA-256 mismatch", "must not already exist")
            ),
        },
        declarations[5]: {
            "pin has strict identity and native no-skip evidence": pin_objects and pin_identity,
            "pin has one provenance-complete trace per adapter": trace_identity_complete,
            "pin records zero remote access and the executable guards": pin_zero_remote,
        },
        declarations[6]: {
            "native rollout selects the isolated compatibility transport": all(
                marker in native_runtime
                for marker in (
                    'env["METACODES_KG_TRANSPORT"] = "cli-exclusive"',
                    'env["METACODES_KG_BIN"] = str(tinykg)',
                    'env["METACODES_KG_STORE"] = str(store)',
                )
            ),
            "prompt-arm smoke selects the isolated compatibility transport": all(
                marker in arm_smoke
                for marker in (
                    'env["METACODES_KG_TRANSPORT"] = "cli-exclusive"',
                    'env["METACODES_KG_BIN"] = str(tinykg_binary)',
                )
            ),
        },
    }
    covered = [name for name, checks in obligations.items() if all(checks.values())]
    missing = [name for name in declarations if name not in covered]
    errors: list[str] = []
    for obligation, checks in obligations.items():
        absent = [name for name, present in checks.items() if not present]
        if absent:
            errors.append(f"{obligation}: missing {', '.join(absent)}")

    return Observation(
        sensor="memory_local_store_isolation",
        sensor_ok=not errors and len(covered) == len(declarations),
        declared=len(declarations),
        covered=len(covered),
        deviation=max(len(declarations) - len(covered), 0),
        declarations=declarations,
        covered_declarations=covered,
        missing_declarations=missing,
        feedback_bindings=[
            {"unittest": "scripts.tests.test_rule_control.MemoryLocalStoreIsolationSensorTests"},
            {"unittest": "scripts.eval.tests.test_memory_tinykg_local"},
        ],
        errors=errors,
        fingerprint_sha256=fingerprint(paths.values()),
    )


def observe_paid_budget_journal(repo: Path) -> Observation:
    """Bind Lean's paid-request model to production code and native feedback.

    Lean owns lifecycle, exposure, identity, and request-admission semantics.
    This adapter owns host facts Lean cannot prove: flock placement, durable
    publication calls, real subprocess order, crash injection, and checkpoint
    re-observation. Fixed paths prevent a helper-only test from self-attesting.
    """

    declarations = [
        "legal_journal_state_machine_and_identity_binding",
        "durable_atomic_authorization_persistence",
        "exclusive_lock_precedes_credentials_and_provider",
        "real_runner_provider_requires_durable_authorization",
        "authorized_crash_recovery_consumes_maximum_without_retry",
        "commit_idempotency_and_two_dimensional_authority",
        "journal_integrity_and_path_faults_fail_closed",
        "receipt_binds_final_journal_checkpoint",
        "dry_run_and_paid_regression_gates_remain_zero_side_effect",
    ]
    relative_sources = {
        "journal": "scripts/eval/memory_budget_journal.py",
        "runner": "scripts/eval/memory_agent_runtime.py",
        "pilot": "scripts/eval/memory_agent_runtime_pilot.py",
        "multi_runner": "scripts/eval/paired_runner.py",
        "multi_cli": "scripts/eval/cli.py",
        "replay": "scripts/eval/memory_replay.py",
        "journal_tests": "scripts/eval/tests/test_memory_budget_journal.py",
        "runtime_tests": "scripts/eval/tests/test_memory_budget_runtime.py",
        "agent_tests": "scripts/eval/tests/test_memory_agent_runtime.py",
        "multi_tests": "scripts/eval/tests/test_experiment.py",
        "multi_fd_tests": "scripts/eval/tests/test_paid_multi_arm_fd.py",
        "workbuddy_launch": "scripts/eval/workbuddy/launch_gate.py",
        "workbuddy_preflight": "scripts/eval/workbuddy/environment_preflight.py",
        "workbuddy_launch_tests": "scripts/eval/tests/test_workbuddy_launch_gate.py",
        "workbuddy_adapter_tests": "scripts/eval/tests/test_workbuddy_adapter.py",
        "workbuddy_release_suite": "scripts/eval/workbuddy_release_suite.py",
        "e2e_lib": "tests/e2e/lib.sh",
        "retry_test": "tests/component/stream_retry_test.zig",
    }
    paths = {name: repo / relative for name, relative in relative_sources.items()}
    missing_files = [relative_sources[name] for name, path in paths.items() if not path.is_file()]
    if missing_files:
        return Observation(
            sensor="paid_budget_journal",
            declared=len(declarations),
            declarations=declarations,
            missing_declarations=declarations,
            deviation=len(declarations),
            errors=[f"required paid-budget source is missing: {path}" for path in missing_files],
            fingerprint_sha256=fingerprint(paths.values()),
        )

    try:
        sources = {name: read_text(path) for name, path in paths.items()}
        trees = {
            name: ast.parse(source, filename=str(paths[name]))
            for name, source in sources.items()
            if name not in {"retry_test", "e2e_lib"}
        }
    except (ControlError, SyntaxError) as exc:
        return Observation(
            sensor="paid_budget_journal",
            declared=len(declarations),
            declarations=declarations,
            missing_declarations=declarations,
            deviation=len(declarations),
            errors=[f"paid-budget source cannot be observed: {exc}"],
            fingerprint_sha256=fingerprint(paths.values()),
        )

    def top_function(tree_name: str, name: str) -> ast.FunctionDef | None:
        return next(
            (
                node
                for node in trees[tree_name].body
                if isinstance(node, ast.FunctionDef) and node.name == name
            ),
            None,
        )

    def method(tree_name: str, class_name: str, name: str) -> ast.FunctionDef | None:
        owner = next(
            (
                node
                for node in trees[tree_name].body
                if isinstance(node, ast.ClassDef) and node.name == class_name
            ),
            None,
        )
        if owner is None:
            return None
        return next(
            (
                node
                for node in owner.body
                if isinstance(node, ast.FunctionDef) and node.name == name
            ),
            None,
        )

    def node_source(tree_name: str, node: ast.AST | None) -> str:
        return "" if node is None else ast.get_source_segment(sources[tree_name], node) or ""

    def top_source(tree_name: str, name: str) -> str:
        return node_source(tree_name, top_function(tree_name, name))

    def method_source(tree_name: str, class_name: str, name: str) -> str:
        return node_source(tree_name, method(tree_name, class_name, name))

    def dotted_name(node: ast.AST) -> str:
        if isinstance(node, ast.Name):
            return node.id
        if isinstance(node, ast.Attribute):
            prefix = dotted_name(node.value)
            return f"{prefix}.{node.attr}" if prefix else node.attr
        return ""

    def call_lines(function: ast.FunctionDef | None, call_name: str) -> list[int]:
        if function is None:
            return []
        return sorted(
            node.lineno
            for node in ast.walk(function)
            if isinstance(node, ast.Call) and dotted_name(node.func) == call_name
        )

    def call_names(function: ast.FunctionDef | None) -> set[str]:
        if function is None:
            return set()
        return {
            dotted_name(node.func)
            for node in ast.walk(function)
            if isinstance(node, ast.Call) and dotted_name(node.func)
        }

    journal_replay = top_source("journal", "_replay_document")
    identity_validate = top_source("journal", "_validate_identity_record")
    journal_enter = method_source("journal", "BudgetJournal", "__enter__")
    journal_open_lock = method_source("journal", "BudgetJournal", "_open_lock")
    journal_regular = method_source("journal", "BudgetJournal", "_validate_regular_fd")
    journal_persist = method_source("journal", "BudgetJournal", "_persist")
    journal_append = method_source("journal", "BudgetJournal", "_append")
    journal_reserve = method_source("journal", "BudgetJournal", "reserve")
    journal_authorize = method_source("journal", "BudgetJournal", "authorize_request")
    journal_commit = method_source("journal", "BudgetJournal", "commit")
    journal_snapshot = method_source("journal", "BudgetJournal", "snapshot")
    journal_reobserve = method_source("journal", "BudgetJournal", "_reobserve")
    journal_temp = method_source("journal", "BudgetJournal", "_reject_temporary")
    runner = top_function("runner", "run_memory_agent_schedule")
    runner_source = node_source("runner", runner)
    pilot = top_function("pilot", "main")
    pilot_source = node_source("pilot", pilot)
    multi_runner = top_function("multi_runner", "run_multi_arm")
    multi_runner_source = node_source("multi_runner", multi_runner)
    multi_locked = top_function("multi_runner", "_run_multi_arm_locked")
    multi_locked_source = node_source("multi_runner", multi_locked)
    multi_once = top_function("multi_runner", "_run_once")
    multi_once_source = node_source("multi_runner", multi_once)
    receipt_validate = top_source("replay", "_validate_budget_transaction_receipt")
    journal_receipt_validate = top_source("replay", "_validate_budget_journal_receipt")
    artifact_validate = top_source("replay", "validate_runtime_artifacts")
    resume_validate = top_source("runner", "validate_memory_agent_resume")

    reserve_lines = call_lines(runner, "budget_journal.reserve")
    pipe_lines = call_lines(runner, "os.pipe")
    authorize_lines = call_lines(runner, "budget_journal.authorize_request")
    subprocess_lines = call_lines(runner, "subprocess.run")
    commit_lines = call_lines(runner, "budget_journal.commit")
    pilot_lock_lines = call_lines(pilot, "BudgetJournal")
    credential_lines = call_lines(pilot, "_load_api_key")
    schedule_lines = call_lines(pilot, "run_memory_agent_schedule")
    runner_calls = call_names(runner)
    multi_runner_calls = call_names(multi_locked)
    workbuddy_launch = top_function("workbuddy_launch", "execute_launch")
    workbuddy_launch_source = node_source("workbuddy_launch", workbuddy_launch)
    workbuddy_reobserve_source = top_source(
        "workbuddy_launch", "_reobserve_launch_inputs"
    )
    workbuddy_failure_receipt_source = top_source(
        "workbuddy_launch", "_authorized_failure_receipt"
    )
    workbuddy_failure_validate_source = top_source(
        "workbuddy_launch", "validate_authorized_failure_receipt"
    )
    workbuddy_failure_persist = top_function(
        "workbuddy_launch", "_persist_authorized_failure_receipt"
    )
    workbuddy_preflight_source = top_source("workbuddy_preflight", "validate_receipt")
    workbuddy_reobserve_lines = call_lines(
        workbuddy_launch, "_reobserve_launch_inputs"
    )
    workbuddy_authorize_lines = call_lines(
        workbuddy_launch, "journal.authorize_request"
    )
    workbuddy_calls = call_names(workbuddy_launch)
    workbuddy_failure_persist_calls = call_names(workbuddy_failure_persist)
    alternate_launchers = {
        name
        for name in runner_calls
        if name in {
            "subprocess.Popen", "subprocess.call", "subprocess.check_call",
            "subprocess.check_output", "os.system", "os.popen", "os.posix_spawn",
            "os.posix_spawnp", "urllib.request.urlopen", "http.client.HTTPConnection",
            "http.client.HTTPSConnection", "socket.create_connection",
        }
        or name.startswith("os.spawn")
        or name.startswith("os.exec")
    }
    multi_alternate_launchers = {
        name
        for name in multi_runner_calls
        if name in {
            "subprocess.Popen", "subprocess.call", "subprocess.check_call",
            "subprocess.check_output", "os.system", "os.popen", "os.posix_spawn",
            "os.posix_spawnp", "urllib.request.urlopen", "http.client.HTTPConnection",
            "http.client.HTTPSConnection", "socket.create_connection",
        }
        or name.startswith("os.spawn")
        or name.startswith("os.exec")
    }

    def test_source(tree_name: str, class_name: str, test_name: str) -> str:
        return method_source(tree_name, class_name, test_name)

    journal_state_test = test_source(
        "journal_tests", "MemoryBudgetJournalTest",
        "test_state_machine_crash_exposure_and_commit_idempotence",
    )
    exposure_test = test_source(
        "journal_tests", "MemoryBudgetJournalTest",
        "test_exposure_limit_is_checked_before_persist",
    )
    cas_test = test_source(
        "journal_tests", "MemoryBudgetJournalTest",
        "test_revision_cas_and_identity_drift_fail_closed",
    )
    lock_test = test_source(
        "journal_tests", "MemoryBudgetJournalTest",
        "test_lock_is_process_exclusive_and_loser_does_not_mutate",
    )
    integrity_test = test_source(
        "journal_tests", "MemoryBudgetJournalTest",
        "test_corrupt_truncated_symlink_hardlink_and_temp_fail_closed",
    )
    persist_fault_test = test_source(
        "journal_tests", "MemoryBudgetJournalTest",
        "test_fault_before_rename_leaves_manual_stop_after_rename_recovers_new_head",
    )
    drift_test = test_source(
        "journal_tests", "MemoryBudgetJournalTest",
        "test_on_disk_revision_drift_while_locked_is_detected",
    )
    provider_test = test_source(
        "runtime_tests", "MemoryBudgetRuntimeL2Test",
        "test_mock_provider_observes_durable_authorization_on_real_runner_path",
    )
    crash_test = test_source(
        "runtime_tests", "MemoryBudgetRuntimeL2Test",
        "test_crash_windows_remain_authorized_and_cannot_retry",
    )
    runner_lock_test = test_source(
        "runtime_tests", "MemoryBudgetRuntimeL2Test",
        "test_second_pilot_runner_loses_lock_before_credential_or_network",
    )
    preauth_test = test_source(
        "runtime_tests", "MemoryBudgetRuntimeL2Test",
        "test_pre_authorization_os_failure_aborts_without_provider_request",
    )
    resume_test = test_source(
        "runtime_tests", "MemoryBudgetRuntimeL2Test",
        "test_rollout_checkpoint_resume_skips_already_committed_provider_request",
    )
    resume_advance_test = test_source(
        "runtime_tests", "MemoryBudgetRuntimeL2Test",
        "test_resume_rejects_journal_advance_without_replaying_provider",
    )
    resume_credential_test = test_source(
        "runtime_tests", "MemoryBudgetRuntimeL2Test",
        "test_resume_checkpoint_failure_precedes_credential_loading",
    )
    dry_run_test = test_source(
        "agent_tests", "MemoryAgentRuntimeContractTest",
        "test_production_pilot_dry_run_loads_no_credential_and_makes_no_network_call",
    )
    authority_test = test_source(
        "agent_tests", "MemoryAgentRuntimeContractTest",
        "test_production_budget_authority_is_fail_closed_and_secret_free",
    )
    receipt_test = test_source(
        "agent_tests", "MemoryAgentRuntimeContractTest",
        "test_v5_receipt_binds_durable_budget_transactions_and_checkpoint",
    )
    multi_resume_test = test_source(
        "multi_tests", "LongHorizonExperimentTest",
        "test_multi_arm_checkpoints_resume_without_repeating_rollouts",
    )
    multi_crash_test = test_source(
        "multi_tests", "LongHorizonExperimentTest",
        "test_multi_arm_crash_windows_leave_unreplayable_orphans_before_credential",
    )
    multi_fd_test = test_source(
        "multi_fd_tests", "PaidMultiArmCredentialFdL2Test",
        "test_e2e_shell_transports_anonymous_fd_without_secret_environment",
    )
    multi_fd_helper = method_source(
        "multi_fd_tests", "PaidMultiArmCredentialFdL2Test",
        "_write_fake_metacodes",
    )
    multi_fd_runner_test = test_source(
        "multi_fd_tests", "PaidMultiArmCredentialFdL2Test",
        "test_run_once_crosses_real_shell_bridge_with_one_shot_fd",
    )

    obligations = {
        declarations[0]: {
            "replay accepts only four explicit actions": all(
                marker in journal_replay
                for marker in (
                    '"reserved"', '"request_authorized"', '"committed"',
                    '"aborted_pre_request"', "authorization requires reserved state",
                    "commit requires request_authorized state",
                    "pre-request abort requires reserved state",
                    "run id already has a non-aborted transaction",
                )
            ),
            "identity has exact run/model/harness/provider/cap fields": all(
                marker in identity_validate
                for marker in (
                    '"run_id"', '"manifest_sha256"', '"model_fingerprint"',
                    '"harness_fingerprint"', '"provider_identity"',
                    '"max_cost_microusd"', '"max_metered_tokens"',
                )
            ),
            "transaction id binds journal revision and full identity": all(
                marker in journal_reserve
                for marker in ('"journal_id"', '"reservation_revision"', '"identity"')
            ) and "_canonical_sha256" in journal_reserve,
        },
        declarations[1]: {
            "authorization appends through the durable writer": (
                'action="request_authorized"' in journal_authorize
                and "return self._append(" in journal_authorize
                and "self._reobserve()" in journal_append
                and "self._persist(updated)" in journal_append
            ),
            "writer fsyncs temp then atomically replaces then fsyncs parent": (
                journal_persist.find("os.fsync(fd)") >= 0
                and journal_persist.find("os.replace(") > journal_persist.find("os.fsync(fd)")
                and journal_persist.rfind("os.fsync(self._dir_fd)") > journal_persist.find("os.replace(")
                and "os.O_EXCL" in journal_persist
                and "src_dir_fd=self._dir_fd" in journal_persist
                and "dst_dir_fd=self._dir_fd" in journal_persist
            ),
            "fault injection covers both rename crash windows": all(
                marker in persist_fault_test
                for marker in (
                    '"after_temporary_fsync"', '"manual inspection"',
                    '"after_atomic_replace"', '"reserved": 1',
                )
            ),
        },
        declarations[2]: {
            "pilot lock encloses credential load and entire schedule": (
                len(pilot_lock_lines) == 1 and len(credential_lines) == 1
                and len(schedule_lines) == 1
                and pilot_lock_lines[0] < credential_lines[0] < schedule_lines[0]
                and "with BudgetJournal(journal_path, authority) as budget_journal:" in pilot_source
            ),
            "lock is exclusive nonblocking and held until context exit": all(
                marker in journal_open_lock
                for marker in ("os.O_NOFOLLOW", "self._validate_regular_fd")
            ) and all(
                marker in journal_enter
                for marker in (
                    "fcntl.LOCK_EX", "fcntl.LOCK_NB",
                    "another local runner holds it", "self._lock_fd",
                )
            ),
            "real competing pilot proves zero credential/run-dir/child effects": all(
                marker in runner_lock_test
                for marker in (
                    "must-not-be-read.json", "another local runner holds it",
                    "self.assertFalse(missing_auth.exists())",
                    "self.assertFalse(invoked.exists())",
                    'self.assertFalse((root / "loser-run").exists())',
                )
            ) and "self.assertEqual(journal.snapshot(), before)" in lock_test,
            "multi-arm runner holds the same exclusive journal lock for the schedule": all(
                marker in multi_runner_source
                for marker in (
                    "with BudgetJournal(journal_path, authority) as budget_journal:",
                    "return _run_multi_arm_locked(",
                )
            ),
        },
        declarations[3]: {
            "production spawn has one authorization predecessor": (
                len(reserve_lines) == 1 and len(authorize_lines) == 1
                and len(subprocess_lines) == 2 and len(commit_lines) == 1
                and reserve_lines[0] < authorize_lines[0] < subprocess_lines[0] < commit_lines[0]
                and pipe_lines and pipe_lines[0] < authorize_lines[0]
            ),
            "no alternate provider-capable launcher bypasses the gate": not alternate_launchers,
            "multi-arm provider call has one durable authorization predecessor": all(
                marker in multi_locked_source
                for marker in (
                    "reserved = budget_journal.reserve(transaction)",
                    "authorization = budget_journal.authorize_request(",
                    "run_dir = _run_once(",
                    "budget_receipt = budget_journal.commit(",
                )
            ) and (
                multi_locked_source.find("budget_journal.authorize_request(")
                < multi_locked_source.find("run_dir = _run_once(")
                < multi_locked_source.find("budget_journal.commit(")
            ),
            "multi-arm provider path has no alternate launcher": not multi_alternate_launchers,
            "WorkBuddy provider seam is behind the same durable permit": (
                all(
                    marker in workbuddy_launch_source
                    for marker in (
                        "journal.authorize_request(",
                        "_read_credential(credential_fd)",
                        "subprocess.run(",
                        "pass_fds=(read_fd,)",
                        '"WBBENCH_PROXY_MAX_RETRIES": "0"',
                        '"SHARED_PROXY": "0"',
                        '"quality_evidence": _receipt_quality_evidence(',
                    )
                )
                and workbuddy_launch_source.find("journal.authorize_request(")
                < workbuddy_launch_source.find("_read_credential(credential_fd)")
                < workbuddy_launch_source.find("subprocess.run(")
                and len(workbuddy_reobserve_lines) == 2
                and len(workbuddy_authorize_lines) == 1
                and all(
                    line < workbuddy_authorize_lines[0]
                    for line in workbuddy_reobserve_lines
                )
                and all(
                    marker in workbuddy_reobserve_source
                    for marker in (
                        "_reobserve_host_control_plane(manifest)",
                        "validate_installed_overlay(workbuddy)",
                        "installed WorkBuddy overlay identity drifted",
                        "validate_environment_preflight(",
                        "_paid_host_guard(workbuddy, preflight)",
                        "environment preflight receipt drifted",
                    )
                )
                and all(
                    marker in workbuddy_preflight_source
                    for marker in (
                        "_tree_identity(",
                        "_docker_inspect(",
                        "docker client changed after environment preflight",
                        "WorkBuddy harness mount image changed after preflight",
                    )
                )
                and all(
                    marker in sources["workbuddy_launch_tests"]
                    for marker in (
                        "validate_checkpoint_payload",
                        "self.assertEqual(provider.requests, 1)",
                        '"after_request_authorized"',
                        "retry is forbidden",
                        "cacheable_first_request_sha256",
                        "test_paid_host_rejects_dotenv_and_uv_docker_shadow",
                        "test_host_control_plane_source_drift_fails_closed",
                        "test_receipt_quality_classification_requires_official_runner_and_opt_in",
                        "test_real_reobserve_rejects_installed_overlay_tamper_before_authorization",
                    )
                )
                and all(
                    marker in sources["workbuddy_adapter_tests"]
                    for marker in (
                        "test_preflight_binds_environment_hash_image_and_platform",
                        "test_preflight_rejects_non_amd64_image",
                    )
                )
            ),
            "authorization receipt is marked before subprocess": (
                runner_source.find("budget_request_authorized = True")
                > runner_source.find("budget_journal.authorize_request(")
                and runner_source.find("completed = subprocess.run(")
                > runner_source.find("budget_request_authorized = True")
            ),
            "MockServer reopens journal at request arrival": all(
                marker in sources["runtime_tests"]
                for marker in (
                    "validate_checkpoint_payload(owner.journal_path.read_bytes())",
                    'if "request_authorized" not in states:',
                    "provider request preceded durable authorization",
                )
            ) and all(
                marker in provider_test
                for marker in (
                    "self._run(", "self.assertEqual(provider.requests, 2)",
                    '"budget_transaction"', '"committed"',
                )
            ),
            "preauthorization host failure aborts before provider": all(
                marker in preauth_test
                for marker in (
                    '"scripts.eval.memory_agent_runtime.os.fpathconf"',
                    '"aborted_pre_request": 1', "self.assertEqual(provider.requests, 0)",
                )
            ),
            "multi-arm real runner reopens durable authorization at provider seam": all(
                marker in multi_resume_test
                for marker in (
                    "validate_checkpoint_payload(journal_path.read_bytes())",
                    'self.assertEqual(latest["state"], "request_authorized")',
                    'self.assertEqual(runtime_api_key, "test-only-private-key")',
                )
            ),
        },
        declarations[4]: {
            "reserve refuses authorized identity replay": all(
                marker in journal_reserve
                for marker in (
                    'item["identity"]["run_id"] == identity["run_id"]',
                    "run id is already bound to a different transaction identity",
                    'current["state"] == "request_authorized"',
                    "automatic or implicit retry is forbidden",
                )
            ),
            "snapshot charges reserved and authorized maximum": all(
                marker in journal_snapshot
                for marker in (
                    'state in {"reserved", "request_authorized"}',
                    'transaction["identity"]["max_cost_microusd"]',
                    'transaction["identity"]["max_metered_tokens"]',
                )
            ),
            "both real crash windows recover authorized and reject retry": all(
                marker in crash_test
                for marker in (
                    '"after_request_authorized", 0',
                    '"after_provider_return_before_commit", 1',
                    '{"request_authorized": 1}', '"unsettled_max_cost_microusd"',
                    '"retry is forbidden"',
                )
            ),
            "multi-arm authorization commit crash windows become unreplayable orphans": all(
                marker in multi_crash_test
                for marker in (
                    '"after_request_authorized", 0, "request_authorized"',
                    '"after_provider_return_before_commit", 1, "request_authorized"',
                    '"after_budget_commit", 1, "committed"',
                    '"without a matching rollout checkpoint"',
                    "load_key.assert_not_called()",
                    "rerun.assert_not_called()",
                )
            ),
            "WorkBuddy authorized failure is non-retry evidence with maximum exposure": (
                "_persist_authorized_failure_receipt" in workbuddy_calls
                and "_authorized_failure_receipt" in workbuddy_failure_persist_calls
                and "validate_authorized_failure_receipt"
                in workbuddy_failure_persist_calls
                and all(
                    marker in workbuddy_launch_source
                    for marker in (
                        "authorized maximum remains exposed and retry is forbidden",
                    )
                )
                and all(
                    marker in workbuddy_failure_receipt_source
                    for marker in (
                        'transaction["state"] != "request_authorized"',
                        '"state": "authorized_failure"',
                        '"quality_evidence": False',
                        '"retry_allowed": False',
                        '"actual_usage_known": False',
                        '"remote_request_outcome": "unknown"',
                        '"exposure_cost_microusd": snapshot["exposure_cost_microusd"]',
                        '"exposure_metered_tokens": snapshot["exposure_metered_tokens"]',
                    )
                )
                and all(
                    marker in sources["workbuddy_launch_tests"]
                    for marker in (
                        "test_real_child_provider_503_writes_private_authorized_failure_receipt",
                        'self.assertFalse(failure["retry_allowed"])',
                        'self.assertFalse(failure["actual_usage_known"])',
                        '"request_authorized", failure["budget_transaction"]["state"]',
                        "self.assertEqual(0, retry_provider.requests)",
                    )
                )
            ),
        },
        declarations[5]: {
            "replay checks aggregate cost and token exposure after every event": all(
                marker in journal_replay
                for marker in (
                    'exposure_cost > authority["total_cost_microusd"]',
                    'exposure_tokens > authority["total_metered_tokens"]',
                    'transaction["state"] == "committed"',
                    'transaction["state"] in {"reserved", "request_authorized"}',
                )
            ),
            "commit is exact-idempotent and bounded by both maxima": all(
                marker in journal_commit
                for marker in (
                    'current["actual_cost_microusd"] == actual_cost',
                    'current["actual_metered_tokens"] == actual_tokens',
                    "committed usage may only be replayed identically", 'action="committed"',
                )
            ) and all(
                marker in journal_replay
                for marker in (
                    'actual_cost > identity["max_cost_microusd"]',
                    'actual_tokens > identity["max_metered_tokens"]',
                )
            ),
            "L2 exercises capacity release and idempotent usage drift": all(
                marker in exposure_test for marker in ("exceeds authority", "4_000_000")
            ) and all(
                marker in journal_state_test for marker in ("journal_revision", "identically", "750_001")
            ),
        },
        declarations[6]: {
            "files and parent reject untrusted object types and permissions": all(
                marker in journal_enter
                for marker in (
                    "parent.resolve(strict=True)", "must be owned", "0o022",
                    "os.fstat(self._dir_fd)", "opened_parent_info.st_dev",
                    "opened_parent_info.st_ino", "changed while opening",
                )
            ) and all(
                marker in journal_regular for marker in ("stat.S_ISREG", "st_nlink != 1", "0o077")
            ) and "incomplete temporary file requires manual inspection" in journal_temp,
            "reobservation binds journal id revision and head": all(
                marker in journal_reobserve
                for marker in ('["revision"]', '["head_sha256"]', '["journal_id"]', "drift while lock is held")
            ),
            "corruption links temp and CAS drift fail closed in L2": all(
                marker in integrity_test
                for marker in ("invalid JSON", "symlink_to", "os.link", "manual inspection")
            ) and "CAS" in cas_test and "event count" in drift_test,
        },
        declarations[7]: {
            "runtime publishes a validated atomic checkpoint after every committed rollout": all(
                marker in runner_source
                for marker in (
                    "budget_journal.checkpoint_payload()", "rollout-budget-checkpoint-r",
                    '"checkpoint_sha256"', "budget_journal.snapshot()",
                    "validate_runtime_receipt(", "validate_runtime_artifacts(",
                    "_replace_private_file(", '"after_rollout_resume_checkpoint"',
                )
            ) and all(
                marker in journal_snapshot
                for marker in ('"journal_id"', '"revision"', '"head_sha256"', '"transaction_states"')
            ),
            "resume revalidates a contiguous prefix and exact live journal before credentials": all(
                marker in resume_validate
                for marker in (
                    "must be a non-empty prefix", "budget_journal.checkpoint_payload()",
                    "journal advanced beyond the artifact checkpoint; replay is forbidden",
                    "validate_runtime_receipt(", "validate_runtime_artifacts(",
                )
            ) and (
                pilot_source.find("validate_memory_agent_resume(") >= 0
                and pilot_source.find("validate_memory_agent_resume(")
                < pilot_source.find("_load_api_key(")
            ),
            "fault L2 skips committed work and rejects ambiguous journal advance": all(
                marker in resume_test
                for marker in (
                    '"after_rollout_resume_checkpoint"',
                    "self.assertEqual(provider.requests, 1)",
                    "resume_paid_run=True", "self.assertEqual(provider.requests, 2)",
                )
            ) and all(
                marker in resume_advance_test
                for marker in (
                    "authorize_request(",
                    "journal advanced beyond the artifact checkpoint",
                    "self.assertEqual(provider.requests, 1)",
                )
            ) and all(
                marker in resume_credential_test
                for marker in (
                    '"--resume-paid-run"', "load_key.assert_not_called()",
                    "self.assertFalse(missing_auth.exists())",
                )
            ),
            "replay recomputes transaction and journal identities": all(
                marker in receipt_validate for marker in ("identity_sha256", "transaction_id", "reservation_revision")
            ) and all(
                marker in journal_receipt_validate
                for marker in ("journal_id", "revision", "head_sha256", "checkpoint_sha256")
            ) and all(
                marker in artifact_validate
                for marker in (
                    "validate_checkpoint_payload(checkpoint_payload)",
                    "checkpoint bytes drifted", "does not match the hash-chained checkpoint",
                )
            ),
            "v5 L2 rejects authorization usage and checkpoint tampering": all(
                marker in receipt_test
                for marker in (
                    "authorization_revision", "actual_metered_tokens",
                    "checkpoint bytes drifted", "validate_runtime_artifacts",
                )
            ),
            "multi-arm checkpoints bind committed receipt and reject journal orphans before credentials": all(
                marker in multi_locked_source
                for marker in (
                    "_validate_checkpoint_budget_receipt(",
                    "_require_no_orphan_budget_transactions(",
                    "runtime_api_key = _load_api_key(",
                    "write_rollouts(outputs[arm_id], collected[arm_id])",
                    '"after_rollout_checkpoint"',
                )
            ) and (
                multi_locked_source.find("_require_no_orphan_budget_transactions(")
                < multi_locked_source.find("runtime_api_key = _load_api_key(")
            ) and all(
                marker in multi_resume_test
                for marker in (
                    'stage == "after_rollout_checkpoint"',
                    "self.assertEqual(len(invocations), 2)",
                    "self.assertEqual(len(invocations), 16)",
                )
            ),
            "WorkBuddy failure receipt reopens exact authorized journal checkpoint": (
                all(
                    marker in workbuddy_failure_validate_source
                    for marker in (
                        "validate_checkpoint_payload(checkpoint)",
                        "_validated_failure_transaction(",
                        'transaction.get("actual_cost_microusd") is not None',
                        'transaction.get("actual_metered_tokens") is not None',
                        'journal.get("checkpoint_sha256")',
                        "does not reopen from journal",
                    )
                )
                and all(
                    marker in sources["workbuddy_launch_tests"]
                    for marker in (
                        "validate_authorized_failure_receipt(",
                        "journal_path=journal",
                        "test_provider_received_then_crash_has_no_forged_failure_receipt",
                        "self.assertFalse(receipt.exists())",
                    )
                )
            ),
        },
        declarations[8]: {
            "dry run returns before lock credential journal or network": (
                pilot_source.find("if args.dry_run:") >= 0
                and pilot_source.find("return 0", pilot_source.find("if args.dry_run:"))
                < pilot_source.find("with BudgetJournal(")
                and pilot_source.find("with BudgetJournal(") < pilot_source.find("_load_api_key(")
            ) and all(
                marker in top_source("pilot", "_public_plan")
                for marker in (
                    '"network_requests": 0', '"paid_rollouts_authorized": False',
                    '"credential_loaded": False',
                )
            ),
            "dry-run and authority L2 preserve zero side effects and hard cap": all(
                marker in dry_run_test
                for marker in (
                    'plan["network_requests"]', 'plan["credential_loaded"]',
                    "self.assertFalse(missing_auth.exists())",
                    "self.assertFalse(budget_journal.exists())",
                )
            ) and all(
                marker in authority_test
                for marker in ("2000.01", "must not exceed", "explicit paid-rollout authority")
            ),
            "quality flag and every physical provider attempt remain gated": (
                '"quality_evidence": False' in sources["runner"]
                and 'value["quality_evidence"] is not False' in sources["replay"]
                and all(
                    marker in sources["retry_test"]
                    for marker in (
                        'test "L2 AgentLoop journals every physical provider attempt before retry"',
                        "loaded.provider_attempts.len",
                        "first.physical_attempt",
                        "second.physical_attempt",
                    )
                )
            ),
            "multi-arm credential crosses only an anonymous one-shot FD": all(
                marker in multi_once_source
                for marker in (
                    "credential_read_fd, credential_write_fd = os.pipe()",
                    'env["E2E_API_KEY_FD"] = str(credential_read_fd)',
                    'subprocess_options["pass_fds"] = (credential_read_fd,)',
                    "os.write(credential_write_fd, credential)",
                )
            ) and all(
                marker in sources["e2e_lib"]
                for marker in (
                    'auth_env+=("METACODES_API_KEY_FD=$runtime_api_key_fd")',
                    "unset E2E_API_KEY_FD",
                )
            ) and all(
                marker in multi_fd_helper
                for marker in (
                    'if "METASK_API_KEY" in os.environ',
                    'os.environ["METACODES_API_KEY_FD"]',
                    'if os.read(fd, 1) != b"":',
                )
            ) and 'self.assertNotIn("paid-fd-private-key"' in multi_fd_test and all(
                marker in multi_fd_runner_test
                for marker in (
                    "run_dir = _run_once(",
                    'runtime_api_key="paid-fd-private-key"',
                    'self.assertIn("anonymous-fd-consumed"',
                    'self.assertNotIn(',
                )
            ),
        },
    }

    covered = [name for name, checks in obligations.items() if all(checks.values())]
    missing = [name for name in declarations if name not in covered]
    errors: list[str] = []
    for obligation, checks in obligations.items():
        absent = [name for name, present in checks.items() if not present]
        if absent:
            errors.append(f"{obligation}: missing {', '.join(absent)}")
    return Observation(
        sensor="paid_budget_journal",
        sensor_ok=not errors and len(covered) == len(declarations),
        declared=len(declarations),
        covered=len(covered),
        deviation=max(len(declarations) - len(covered), 0),
        declarations=declarations,
        covered_declarations=covered,
        missing_declarations=missing,
        feedback_bindings=[
            {"unittest": "scripts.tests.test_rule_control.PaidBudgetJournalSensorTests"},
            {"unittest": "scripts.eval.tests.test_memory_budget_journal"},
            {"unittest": "scripts.eval.tests.test_memory_budget_runtime"},
            {"unittest": "scripts.eval.tests.test_memory_agent_runtime"},
            {"unittest": "scripts.eval.tests.test_experiment"},
            {"unittest": "scripts.eval.tests.test_paid_multi_arm_fd"},
            {"unittest": "scripts.eval.tests.test_workbuddy_launch_gate"},
            {"unittest": "scripts.eval.workbuddy_release_suite"},
            {"step": "test:new", "filter": "L2 evaluation gate makes one physical provider attempt"},
        ],
        errors=errors,
        fingerprint_sha256=fingerprint(paths.values()),
    )


def observe_daemon_transport(repo: Path) -> Observation:
    """Observe authenticated TinyKG daemon routing and its native feedback."""
    source_relatives = {
        "transport": "src/kg/transport.zig",
        "client": "src/kg/client.zig",
        "probe": "tests/helpers/kg_daemon_transport_probe.zig",
        "runtime": "scripts/test_kg_daemon_transport.py",
        "build": "build.zig",
    }
    paths: dict[str, Path] = {}
    touched: list[Path] = []
    errors: list[str] = []
    for name, relative in source_relatives.items():
        try:
            path = safe_repo_path(repo, relative)
            paths[name] = path
            touched.append(path)
        except ControlError as exc:
            errors.append(str(exc))
    if errors:
        return Observation(
            sensor="daemon_transport",
            errors=errors,
            fingerprint_sha256=fingerprint(touched),
        )
    try:
        sources = {
            name: _strip_zig_comments(read_text(path))
            if path.suffix == ".zig" else read_text(path)
            for name, path in paths.items()
        }
    except ControlError as exc:
        return Observation(
            sensor="daemon_transport",
            errors=[str(exc)],
            fingerprint_sha256=fingerprint(touched),
        )

    client_init = zig_function_slice(sources["client"], "init") or ""
    ensure_ready = zig_function_slice(sources["client"], "ensureReady") or ""
    remote_run = zig_function_slice(sources["client"], "runCheckedRetry") or ""
    policy = zig_function_slice(sources["transport"], "postWithPolicy") or ""
    daemon_config = zig_function_slice(sources["client"], "initDaemonTransport") or ""
    parse = zig_function_slice(sources["transport"], "parseResponse") or ""
    deadline = zig_function_slice(sources["transport"], "postBeforeDeadline") or ""
    markdown = zig_function_slice(sources["transport"], "importMarkdown") or ""
    step = build_step_slice(sources["build"], "test:kg-daemon-transport") or ""

    obligations = {
        "authenticated_local_default_and_skill_isolation": all((
            all(marker in client_init + daemon_config for marker in (
                "METACODES_KG_CONFIG", "METACODES_KG_URL", "METACODES_KG_API_KEY",
                "METACODES_KG_EXPECTED_BUILD_ID", "daemonConfigPath",
                "transport_mod.WebTransport.init", ".unconfigured",
            )),
            'envGet("TINYKG_REMOTE_CONFIG")' not in daemon_config,
            'envGet("TINYKG_REMOTE_URL")' not in daemon_config,
            "skill_remote_config_ignored=pass" in sources["runtime"],
            "metacodes_local_daemon_config=pass" in sources["runtime"],
        )),
        "explicit_exclusive_cli_compatibility": all(marker in client_init for marker in (
            "opts.exclusive_cli", 'std.mem.eql(u8, mode, "cli-exclusive")',
            ".exclusive_cli",
        )),
        "no_shared_raw_store_fallback": all((
            'dupe(u8, "daemon-owned")' in client_init,
            "invalid remote command shape" in remote_run,
            ".unconfigured" in ensure_ready,
            "未打开本地 Store" in ensure_ready,
            "if (!self.ready)" in remote_run,
            "self.transport == .daemon" in remote_run,
            "self.transport.daemon.run(args[0], args[2..]" in remote_run,
            '@import("../storage' not in sources["transport"],
        )),
        "request_identity_and_no_write_retry": all(marker in policy + parse + sources["runtime"] for marker in (
            "max_attempts: u8 = if (mutates) 1 else 2",
            "self.postBeforeDeadline(url, body, request_id, remaining_ms)",
            "RequestIdConflict", '"conflict=observed"', "write_transport_retries=0",
        )),
        "ambiguous_write_outcome": all(marker in policy + sources["transport"] + sources["probe"] + sources["runtime"] for marker in (
            "recordAmbiguousRequestId(request_id)", "ambiguousRequestId()", '"ambiguous_write=observed',
            '"unavailable-write"', "^request_id=([A-Za-z0-9_.:-]{1,128})$",
            "provesNoCommit(err)", '"backpressure_write_no_commit=observed"',
            '"unauthorized_write_no_commit=observed"', '"service-unavailable-write"',
            '"ambiguous-blocks-writes"', "ambiguous_write_latch=pass",
            "cloneForSession", "write_fence", "clone-must-not-send",
        )),
        "generation_and_schema_bound_sessions": all((
            all(marker in sources["transport"] for marker in (
                "sessionId = session", "self.session_id", "self.last_generation = generation",
                "matchesOrPinsSchema",
            )),
            '"schema-drift-across-clone"' in sources["probe"],
            '"schema-drift-across-clone"' in sources["runtime"],
            "generation_bound_sessions" in sources["runtime"],
            "len(ACTOR.sessions) == 1" in sources["runtime"],
            "shared_schema_pin=pass" in sources["runtime"],
        )),
        "end_to_end_wall_clock_deadline": all(marker in policy + deadline + sources["probe"] + sources["runtime"] for marker in (
            "std.Io.Select(PostRace)", "deadlineTask", "remainingTimeoutMs", "Error.RequestTimedOut",
            '"wall_clock_timeout=observed', "time.monotonic() - started < 1.0",
        )),
        "bounded_backpressure_and_unavailability": all(marker in parse + sources["probe"] + sources["runtime"] for marker in (
            "DaemonQueueFull", "Error.Backpressure", "Error.DaemonUnavailable",
            '"backpressure=observed', '"unavailable_read=observed',
        )),
        "markdown_upload_boundary": all(marker in markdown + sources["runtime"] for marker in (
            ".markdown = markdown", ".sourceKey = source_key_text",
            "self.markdown_url", 'ACTOR.markdown_uploads[0]["markdown"]',
            '"path" not in ACTOR.markdown_uploads[0]',
        )),
        "multi_process_one_store_actor_feedback": all(marker in step + sources["runtime"] for marker in (
            "kg_transport_step.dependOn(&kg_transport_runtime.step)",
            "metacodes_processes=2", "store_actor_instances=1",
            "shared_generation=", "kg_daemon_transport=pass",
        )),
    }
    declarations = sorted(obligations)
    covered = sorted(name for name, present in obligations.items() if present)
    missing = sorted(name for name, present in obligations.items() if not present)
    errors.extend(f"{name}: missing executable daemon transport evidence" for name in missing)
    return Observation(
        sensor="daemon_transport",
        sensor_ok=not errors and len(covered) == len(declarations),
        declared=len(declarations),
        covered=len(covered),
        deviation=max(len(declarations) - len(covered), 0),
        declarations=declarations,
        covered_declarations=covered,
        missing_declarations=missing,
        feedback_bindings=[
            {"unittest": "scripts.tests.test_rule_control.DaemonTransportSensorTests"},
            {"step": "test:kg-daemon-transport"},
        ],
        errors=errors,
        fingerprint_sha256=fingerprint(touched),
    )


def observe_rule(repo: Path, rule: dict[str, Any]) -> Observation:
    sensor = rule.get("sensor")
    if not isinstance(sensor, dict):
        return Observation(sensor="unknown", errors=["sensor must be an object"])
    adapter = sensor.get("adapter")
    if adapter == "declaration_l2":
        registry_relative = sensor.get("evidence_registry")
        if not isinstance(registry_relative, str):
            return Observation(sensor=adapter, errors=["sensor evidence_registry is missing"])
        try:
            registry_path = safe_repo_path(repo, registry_relative)
        except ControlError as exc:
            return Observation(sensor=adapter, errors=[str(exc)])
        return observe_declaration_l2(repo, registry_path)
    if adapter == "memory_evidence_governance":
        return observe_memory_evidence_governance(repo)
    if adapter == "execution_ontology_feedback":
        return observe_execution_ontology_feedback(repo)
    if adapter == "experience_feedback":
        return observe_experience_feedback(repo)
    if adapter == "build_test_throughput":
        return observe_build_test_throughput(repo)
    if adapter == "eval_budget_checkpoint":
        return observe_eval_budget_checkpoint(repo)
    if adapter == "treatment_activation":
        return observe_treatment_activation(repo)
    if adapter == "memory_local_store_isolation":
        return observe_memory_local_store_isolation(repo)
    if adapter == "paid_budget_journal":
        return observe_paid_budget_journal(repo)
    if adapter == "daemon_transport":
        return observe_daemon_transport(repo)
    return Observation(sensor=str(adapter), errors=[f"unsupported sensor adapter: {adapter!r}"])


def executable(name: str, env_name: str | None = None) -> str:
    override = os.environ.get(env_name, "") if env_name else ""
    if override:
        return override
    found = shutil.which(name)
    if found:
        return found
    if name == "lake":
        fallback = Path.home() / ".elan" / "bin" / ("lake.exe" if os.name == "nt" else "lake")
        if fallback.is_file():
            return str(fallback)
    raise ControlError(f"required executable is unavailable: {name}")


def strip_lean_noncode(source: str) -> str:
    source = re.sub(r"/-.*?-/", "", source, flags=re.DOTALL)
    source = re.sub(r"--.*$", "", source, flags=re.MULTILINE)
    # Protocol payloads legitimately contain strings such as "admit". The
    # audit governs Lean code tokens, not data rendered by that code.
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', source)


def lean_proof_placeholders(source: str) -> list[str]:
    return sorted(set(re.findall(r"\b(?:sorry|admit|axiom)\b", strip_lean_noncode(source))))


class LeanKernel:
    def __init__(self, repo: Path):
        self.repo = repo
        self.project = repo / "control-plane" / "lean"
        self.lake = executable("lake", "METACODES_LAKE")
        self.source_paths = sorted(self.project.rglob("*.lean"))
        if not self.source_paths:
            raise ControlError("Lean control-plane sources are missing")

    def verify_sources(self, theorem_names: Sequence[str]) -> dict[str, str]:
        combined = "\n".join(read_text(path) for path in self.source_paths)
        stripped = strip_lean_noncode(combined)
        forbidden = lean_proof_placeholders(combined)
        if forbidden:
            raise ControlError(f"Lean proof placeholders are forbidden: {', '.join(forbidden)}")
        missing = [name for name in theorem_names if f"theorem {name}" not in stripped]
        if missing:
            raise ControlError(f"manifest names missing Lean theorems: {', '.join(missing)}")
        try:
            result = subprocess.run(
                [self.lake, "build", "MetaCodesControl"],
                cwd=self.project,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=180,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ControlError(f"Lean build could not complete: {exc}") from exc
        if result.returncode != 0:
            raise ControlError(f"Lean build failed:\n{result.stdout[-8000:]}")
        return {str(path.relative_to(self.repo)): sha256_file(path) for path in self.source_paths}

    def evaluate(
        self,
        rule_id: str,
        topology: dict[str, bool],
        sensor_ok: bool,
        declared: int,
        covered: int,
        feedback_status: str,
    ) -> dict[str, Any]:
        args = [
            self.lake,
            "env",
            "lean",
            "--run",
            "Main.lean",
            rule_id,
            *("true" if topology[name] else "false" for name in LOOP_LINKS),
            "true" if sensor_ok else "false",
            str(declared),
            str(covered),
            feedback_status,
        ]
        try:
            result = subprocess.run(
                args,
                cwd=self.project,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=60,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ControlError(f"Lean decision kernel could not complete: {exc}") from exc
        if result.returncode != 0:
            raise ControlError(
                f"Lean decision kernel failed ({result.returncode}): {(result.stderr or result.stdout)[-4000:]}"
            )
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        if len(lines) != 1:
            raise ControlError(f"Lean decision kernel emitted {len(lines)} non-empty lines")
        try:
            decision = json.loads(lines[0])
        except json.JSONDecodeError as exc:
            raise ControlError(f"Lean decision kernel emitted invalid JSON: {lines[0]!r}") from exc
        if decision.get("schema_version") != SCHEMA_VERSION or decision.get("rule_id") != rule_id:
            raise ControlError("Lean decision identity/schema mismatch")
        return decision


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(64 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def link_topology(
    rule: dict[str, Any],
    counterexamples_ok: bool,
    actuator_observed: bool,
) -> tuple[dict[str, bool], list[str]]:
    failures: list[str] = []
    target = rule.get("target")
    target_ok = isinstance(target, dict) and bool(target.get("goal")) and target.get("setpoint") == 0
    sensor = rule.get("sensor")
    adapter = sensor.get("adapter") if isinstance(sensor, dict) else None
    sensor_ok = (
        isinstance(sensor, dict)
        and adapter in SUPPORTED_SENSOR_ADAPTERS
        and sensor.get("schema_version") == SCHEMA_VERSION
        and (
            adapter != "declaration_l2"
            or isinstance(sensor.get("evidence_registry"), str)
        )
    )
    decision = rule.get("decision")
    expected_kernel = {
        "ontology.execution-grounded-projection.l2": (
            "MetaCodesControl.ClosedLoop.executionProjectionSignal"
        ),
        "ontology.experience-feedback.l2": (
            "MetaCodesControl.ClosedLoop.experienceFeedbackSignal"
        ),
        "build.test-throughput-integrity.l2": (
            "MetaCodesControl.ClosedLoop.buildTestSignal"
        ),
        "eval.budget-checkpoint-durability.l2": (
            "MetaCodesControl.BudgetCheckpoint.evalBudgetSignal"
        ),
        "eval.treatment-activation.l2": (
            "MetaCodesControl.TreatmentActivation.treatmentActivationSignal"
        ),
        "eval.memory-local-store-isolation.l2": (
            "MetaCodesControl.ClosedLoop.memoryIsolationSignal"
        ),
        "eval.paid-budget-journal-authorization.l2": (
            "MetaCodesControl.PaidBudgetJournal.paidBudgetSignal"
        ),
        "tinykg.daemon-transport.l2": (
            "MetaCodesControl.ClosedLoop.daemonTransportSignal"
        ),
    }.get(rule.get("id"), "MetaCodesControl.ClosedLoop.signal")
    decision_ok = (
        isinstance(decision, dict)
        and decision.get("engine") == "lean"
        and decision.get("kernel") == expected_kernel
        and isinstance(decision.get("theorems"), list)
        and len(decision.get("theorems")) > 0
        and all(isinstance(name, str) and name for name in decision.get("theorems"))
    )
    actuator = rule.get("actuator")
    actuator_declared = (
        isinstance(actuator, dict)
        and actuator.get("kind") == "release_gate"
        and actuator.get("on_violation") == "block"
        and bool(actuator.get("remediation"))
    )
    actuator_ok = actuator_declared and actuator_observed
    feedback = rule.get("feedback")
    feedback_commands = feedback.get("commands") if isinstance(feedback, dict) else None
    commands_are_arrays = (
        isinstance(feedback_commands, list)
        and len(feedback_commands) > 0
        and all(
            isinstance(command, list)
            and len(command) > 0
            and all(isinstance(item, str) and item for item in command)
            for command in feedback_commands
        )
    )
    has_zig_test = commands_are_arrays and any(
        command[0] == "zig" and any(item.startswith("test:") for item in command[1:])
        for command in feedback_commands
    )
    has_python_unittest = commands_are_arrays and any(
        command[0] in {"python", "python3"}
        and command[1:3] == ["-m", "unittest"]
        and len(command) > 3
        for command in feedback_commands
    )
    has_tinykg_attestation = commands_are_arrays and any(
        command[0] in {"python", "python3"}
        and command[1:] == ["scripts/verify_tinykg_binary.py"]
        for command in feedback_commands
    )
    feedback_kind = feedback.get("kind") if isinstance(feedback, dict) else None
    feedback_runner_ok = (
        feedback_kind == "zig_l2_then_reobserve" and has_zig_test
    ) or (
        feedback_kind == "python_l2_then_reobserve" and has_python_unittest
    )
    if rule.get("id") in {
        "eval.treatment-activation.l2",
        "eval.memory-local-store-isolation.l2",
    }:
        feedback_runner_ok = feedback_runner_ok and has_tinykg_attestation
    if rule.get("id") == "tinykg.daemon-transport.l2":
        feedback_runner_ok = feedback_runner_ok and has_python_unittest and has_zig_test
    feedback_ok = (
        isinstance(feedback, dict)
        and feedback_kind
        in {"zig_l2_then_reobserve", "python_l2_then_reobserve"}
        and feedback.get("reobserve") is True
        and commands_are_arrays
        and feedback_runner_ok
    )
    counterexample = rule.get("counterexample")
    counterexample_declared = (
        isinstance(counterexample, dict)
        and counterexample.get("required") is True
        and isinstance(counterexample.get("fixture"), str)
    )
    topology = {
        "target": target_ok,
        "sensor": sensor_ok,
        "decision": decision_ok,
        "actuator": actuator_ok,
        "feedback": feedback_ok,
        "counterexample": counterexample_declared and counterexamples_ok,
    }
    for name, present in topology.items():
        if not present:
            failures.append(f"formalization orphan: missing or invalid {name} link")
    return topology, failures


def verify_counterexamples(
    repo: Path,
    rule: dict[str, Any],
    kernel: LeanKernel,
) -> tuple[bool, list[dict[str, Any]], list[str]]:
    errors: list[str] = []
    results: list[dict[str, Any]] = []
    counterexample = rule.get("counterexample")
    if not isinstance(counterexample, dict) or not isinstance(counterexample.get("fixture"), str):
        return False, results, ["counterexample fixture is not declared"]
    try:
        fixture_path = safe_repo_path(repo, counterexample["fixture"])
        document = require_schema(load_json(fixture_path), fixture_path)
    except ControlError as exc:
        return False, results, [str(exc)]
    cases = document.get("cases")
    if not isinstance(cases, list) or len(cases) < 2:
        return False, results, ["counterexample fixture requires at least pass and block cases"]
    saw_allow = False
    saw_block = False
    saw_orphan = False
    saw_missing_evidence = False
    saw_feedback_failure = False
    saw_sensor_failure = False
    seen_case_ids: set[str] = set()
    decision_rule_id = rule.get("id")
    if not isinstance(decision_rule_id, str) or not RULE_ID_RE.match(decision_rule_id):
        return False, results, ["counterexample rule id is invalid"]
    for index, case in enumerate(cases):
        if not isinstance(case, dict):
            errors.append(f"counterexample case {index} must be an object")
            continue
        case_id = case.get("id")
        topology = case.get("topology")
        if not isinstance(case_id, str) or not RULE_ID_RE.match(case_id):
            errors.append(f"counterexample case {index} has invalid id")
            continue
        if case_id in seen_case_ids:
            errors.append(f"duplicate counterexample id: {case_id}")
            continue
        seen_case_ids.add(case_id)
        rule_ids = case.get("rule_ids")
        if rule_ids is not None:
            if not isinstance(rule_ids, list) or not rule_ids or not all(
                isinstance(value, str) and RULE_ID_RE.match(value) for value in rule_ids
            ):
                errors.append(f"counterexample {case_id}: rule_ids must be non-empty valid ids")
                continue
            if decision_rule_id not in rule_ids:
                continue
        if not isinstance(topology, dict) or any(not isinstance(topology.get(name), bool) for name in LOOP_LINKS):
            errors.append(f"counterexample {case_id}: topology must contain six booleans")
            continue
        sensor_ok_value = case.get("sensor_ok")
        declared_value = case.get("declared")
        covered_value = case.get("covered")
        feedback_status = case.get("feedback_status")
        expected_signal = case.get("expected_signal")
        expected_state = case.get("expected_state")
        if not isinstance(sensor_ok_value, bool):
            errors.append(f"counterexample {case_id}: sensor_ok must be boolean")
            continue
        if type(declared_value) is not int or declared_value < 0:
            errors.append(f"counterexample {case_id}: declared must be a non-negative integer")
            continue
        if type(covered_value) is not int or covered_value < 0:
            errors.append(f"counterexample {case_id}: covered must be a non-negative integer")
            continue
        if feedback_status not in {"pending", "passed", "failed"}:
            errors.append(f"counterexample {case_id}: invalid feedback_status")
            continue
        if expected_signal not in {"block_release", "run_feedback", "admit_release"}:
            errors.append(f"counterexample {case_id}: invalid expected_signal")
            continue
        if expected_state not in {"blocked", "verifying", "compliant"}:
            errors.append(f"counterexample {case_id}: invalid expected_state")
            continue
        try:
            result = kernel.evaluate(
                decision_rule_id,
                {name: topology[name] for name in LOOP_LINKS},
                sensor_ok_value,
                declared_value,
                covered_value,
                feedback_status,
            )
        except (ControlError, TypeError, ValueError) as exc:
            errors.append(f"counterexample {case_id}: {exc}")
            continue
        passed = result.get("signal") == expected_signal and result.get("state") == expected_state
        results.append(
            {
                "id": case_id,
                "passed": passed,
                "expected_signal": expected_signal,
                "expected_state": expected_state,
                "actual": result,
            }
        )
        if not passed:
            errors.append(f"counterexample {case_id}: Lean decision did not match expected block/pass")
        saw_allow = saw_allow or expected_signal == "admit_release"
        saw_block = saw_block or expected_signal == "block_release"
        saw_orphan = saw_orphan or (topology.get("actuator") is False and expected_signal == "block_release")
        saw_missing_evidence = saw_missing_evidence or (
            covered_value < declared_value and expected_signal == "block_release"
        )
        saw_feedback_failure = saw_feedback_failure or (
            feedback_status == "failed" and expected_signal == "block_release"
        )
        saw_sensor_failure = saw_sensor_failure or (
            sensor_ok_value is False and expected_signal == "block_release"
        )
    if not saw_allow:
        errors.append("counterexamples have no positive closed-loop case")
    if not saw_block:
        errors.append("counterexamples have no blocking case")
    if not saw_orphan:
        errors.append("counterexamples do not prove that a formalization orphan blocks")
    if not saw_missing_evidence:
        errors.append("counterexamples do not prove that missing evidence blocks")
    if not saw_feedback_failure:
        errors.append("counterexamples do not prove that failed feedback blocks")
    if not saw_sensor_failure:
        errors.append("counterexamples do not prove that sensor failure blocks")
    return not errors, results, errors


def normalize_command(command: Any) -> list[str]:
    if not isinstance(command, list) or not command or not all(isinstance(item, str) and item for item in command):
        raise ControlError(f"feedback command must be a non-empty string array: {command!r}")
    normalized = list(command)
    if normalized[0] in {"python", "python3"}:
        normalized[0] = sys.executable
    if normalized[0] == "zig":
        normalized[0] = executable("zig", "METACODES_ZIG")
    return normalized


def feedback_binding_errors(observation: Observation, feedback: dict[str, Any]) -> list[str]:
    commands = feedback.get("commands", [])
    errors: list[str] = []
    for binding in observation.feedback_bindings:
        unittest_name = binding.get("unittest")
        if unittest_name:
            matched = any(
                isinstance(command, list)
                and len(command) > 3
                and command[0] in {"python", "python3"}
                and command[1:3] == ["-m", "unittest"]
                and unittest_name in command[3:]
                for command in commands
            )
            if not matched:
                errors.append(
                    f"feedback commands do not execute unittest {unittest_name}"
                )
            continue
        step = binding["step"]
        selected_filter = binding.get("filter", "")
        matched = False
        for command in commands:
            if not isinstance(command, list) or not command or command[0] != "zig" or step not in command:
                continue
            if selected_filter and f"-Dtfilter={selected_filter}" not in command:
                continue
            matched = True
            break
        if not matched:
            suffix = f" with filter {selected_filter!r}" if selected_filter else ""
            errors.append(f"feedback commands do not execute {step}{suffix}")
    return errors


def run_feedback(repo: Path, feedback: dict[str, Any]) -> tuple[bool, list[dict[str, Any]]]:
    commands = feedback.get("commands", [])
    timeout = feedback.get("timeout_seconds", 900)
    if not isinstance(timeout, int) or timeout < 1 or timeout > 3600:
        raise ControlError("feedback.timeout_seconds must be between 1 and 3600")
    results: list[dict[str, Any]] = []
    all_passed = True
    env = os.environ.copy()
    env["METACODES_RULE_CONTROL"] = "1"
    for raw in commands:
        command = normalize_command(raw)
        started_ns = time.monotonic_ns()
        try:
            result = subprocess.run(
                command,
                cwd=repo,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=timeout,
            )
            output = result.stdout or ""
            elapsed_ns = time.monotonic_ns() - started_ns
            skipped = sum(int(value) for value in NONZERO_SKIP_RE.findall(output))
            skipped += sum(int(value) for value in UNITTEST_SKIP_RE.findall(output))
            passed = result.returncode == 0 and skipped == 0
            results.append(
                {
                    "command": raw,
                    "exit_code": result.returncode,
                    "elapsed_ns": elapsed_ns,
                    "skipped_tests": skipped,
                    "passed": passed,
                    "output_tail": output[-12000:],
                }
            )
        except subprocess.TimeoutExpired as exc:
            elapsed_ns = time.monotonic_ns() - started_ns
            passed = False
            results.append(
                {
                    "command": raw,
                    "exit_code": None,
                    "elapsed_ns": elapsed_ns,
                    "skipped_tests": 0,
                    "passed": False,
                    "error": f"feedback timed out after {timeout}s",
                    "output_tail": (exc.stdout or "")[-12000:] if isinstance(exc.stdout, str) else "",
                }
            )
        all_passed = all_passed and passed
        if not passed:
            break
    return all_passed, results


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def report_failure(report_path: Path, message: str, report: dict[str, Any]) -> int:
    report["status"] = "blocked"
    report.setdefault("violations", []).append(message)
    write_report(report_path, report)
    print(f"rule-control: BLOCKED: {message}", file=sys.stderr)
    print(f"rule-control report: {report_path}", file=sys.stderr)
    return 1


def run_check(repo: Path, manifest_path: Path, report_path: Path) -> int:
    try:
        manifest_label = str(manifest_path.relative_to(repo))
    except ValueError:
        manifest_label = str(manifest_path)
    report: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "status": "blocked",
        "manifest": manifest_label,
        "rules": [],
        "violations": [],
    }
    workspace = discover_workspace_root(repo)
    report["workspace"] = str(workspace)
    controller_inputs = (
        "scripts/rule_control.py",
        "scripts/tests/test_rule_control.py",
        "control-plane/build.zig",
        "control-plane/rules.json",
        "control-plane/counterexamples.json",
        "control-plane/declaration-l2-evidence.json",
    )
    try:
        report["controller_sources"] = {
            relative: sha256_file(repo / relative) if (repo / relative).is_file() else "<missing>"
            for relative in controller_inputs
        }
        manifest = require_schema(load_json(manifest_path), manifest_path)
        rules = manifest.get("rules")
        if not isinstance(rules, list) or not rules:
            raise ControlError("rule manifest must contain at least one rule")
        kernel = LeanKernel(repo)
        theorem_names: list[str] = []
        for rule in rules:
            if isinstance(rule, dict) and isinstance(rule.get("decision"), dict):
                values = rule["decision"].get("theorems", [])
                if isinstance(values, list):
                    theorem_names.extend(value for value in values if isinstance(value, str))
        report["lean_sources"] = kernel.verify_sources(sorted(set(theorem_names)))
    except (ControlError, OSError, subprocess.SubprocessError) as exc:
        return report_failure(report_path, str(exc), report)

    seen_ids: set[str] = set()
    overall_allowed = True
    for raw_rule in rules:
        if not isinstance(raw_rule, dict):
            return report_failure(report_path, "rule entry must be an object", report)
        rule_id = raw_rule.get("id")
        if not isinstance(rule_id, str) or not RULE_ID_RE.match(rule_id):
            return report_failure(report_path, f"invalid rule id: {rule_id!r}", report)
        if rule_id in seen_ids:
            return report_failure(report_path, f"duplicate rule id: {rule_id}", report)
        seen_ids.add(rule_id)
        rule_report: dict[str, Any] = {"id": rule_id, "status": "blocked", "violations": []}
        report["rules"].append(rule_report)
        try:
            actuator_before = observe_release_gate(repo, workspace, raw_rule.get("actuator"))
            rule_report["actuator_observation_before"] = asdict(actuator_before)
            counterexamples_ok, counterexample_results, counterexample_errors = verify_counterexamples(
                repo, raw_rule, kernel
            )
            topology, topology_errors = link_topology(
                raw_rule,
                counterexamples_ok,
                actuator_before.sensor_ok,
            )
            rule_report["topology"] = topology
            rule_report["counterexamples"] = counterexample_results
            rule_report["violations"].extend(counterexample_errors)
            rule_report["violations"].extend(topology_errors)
            rule_report["violations"].extend(actuator_before.errors)

            before = observe_rule(repo, raw_rule)
            rule_report["observation_before"] = asdict(before)
            feedback = raw_rule.get("feedback")
            if not isinstance(feedback, dict):
                raise ControlError(f"{rule_id}: feedback configuration is missing")
            binding_errors = feedback_binding_errors(before, feedback)
            if binding_errors:
                topology["feedback"] = False
                rule_report["topology"] = topology
                rule_report["violations"].extend(
                    f"formalization orphan: {message}" for message in binding_errors
                )
            pre = kernel.evaluate(
                rule_id,
                topology,
                before.sensor_ok,
                before.declared,
                before.covered,
                "pending",
            )
            rule_report["lean_pre_feedback"] = pre
            if pre.get("signal") != "run_feedback":
                rule_report["violations"].extend(before.errors)
                rule_report["violations"].append(
                    "Lean blocked actuation before feedback; repair topology or sensor deviation"
                )
                overall_allowed = False
                continue

            feedback_ok, feedback_results = run_feedback(repo, feedback)
            rule_report["feedback_runs"] = feedback_results

            after = observe_rule(repo, raw_rule)
            rule_report["observation_after"] = asdict(after)
            actuator_after = observe_release_gate(repo, workspace, raw_rule.get("actuator"))
            rule_report["actuator_observation_after"] = asdict(actuator_after)
            final_topology, final_topology_errors = link_topology(
                raw_rule,
                counterexamples_ok,
                actuator_after.sensor_ok,
            )
            rule_report["topology_after_feedback"] = final_topology
            rule_report["topology"] = final_topology
            stable_observation = (
                before.fingerprint_sha256 == after.fingerprint_sha256
                and actuator_before.fingerprint_sha256 == actuator_after.fingerprint_sha256
            )
            rule_report["reobserved_after_feedback"] = True
            rule_report["observation_stable_during_feedback"] = stable_observation
            final_feedback = "passed" if feedback_ok and stable_observation else "failed"
            final = kernel.evaluate(
                rule_id,
                final_topology,
                after.sensor_ok,
                after.declared,
                after.covered,
                final_feedback,
            )
            rule_report["lean_final"] = final
            allowed = final.get("release_allowed") is True and final.get("state") == "compliant"
            if allowed:
                rule_report["status"] = "enforced"
            else:
                rule_report["violations"].extend(after.errors)
                rule_report["violations"].extend(actuator_after.errors)
                rule_report["violations"].extend(final_topology_errors)
                if not feedback_ok:
                    rule_report["violations"].append("Zig L2 feedback failed or skipped tests")
                if not stable_observation:
                    rule_report["violations"].append("repository changed during feedback; re-run observation")
                rule_report["violations"].append("Lean final decision blocked release")
            overall_allowed = overall_allowed and allowed
        except (ControlError, OSError, subprocess.SubprocessError) as exc:
            rule_report["violations"].append(str(exc))
            overall_allowed = False

    all_violations = [
        f"{rule['id']}: {message}"
        for rule in report["rules"]
        for message in rule.get("violations", [])
    ]
    report["violations"] = all_violations
    report["status"] = "enforced" if overall_allowed else "blocked"
    write_report(report_path, report)
    if overall_allowed:
        print(f"rule-control: ENFORCED ({len(report['rules'])} rule(s))")
        print(f"rule-control report: {report_path}")
        return 0
    print("rule-control: BLOCKED", file=sys.stderr)
    for violation in all_violations:
        print(f"  - {violation}", file=sys.stderr)
    print(f"rule-control report: {report_path}", file=sys.stderr)
    return 1


def run_observe(repo: Path, registry_path: Path, as_json: bool) -> int:
    observation = observe_declaration_l2(repo, registry_path)
    if as_json:
        print(json.dumps(asdict(observation), ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print("声明=L2 证据传感器")
        print(f"  declared: {observation.declared}")
        print(f"  covered:  {observation.covered}")
        print(f"  deviation:{observation.deviation}")
        for declaration in observation.missing_declarations:
            print(f"  [缺] {declaration}")
        for error in observation.errors:
            print(f"  [错] {error}")
    return 0 if observation.sensor_ok else 1


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    check = subparsers.add_parser("check", help="run the full closed-loop release gate")
    check.add_argument("--repo", type=Path, default=Path.cwd())
    check.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    check.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    observe = subparsers.add_parser("observe", help="run only the declaration/L2 sensor")
    observe.add_argument("--repo", type=Path, default=Path.cwd())
    observe.add_argument(
        "--registry", type=Path, default=Path("control-plane/declaration-l2-evidence.json")
    )
    observe.add_argument("--json", action="store_true")
    return parser.parse_args(argv)


def resolve_under_repo(repo: Path, path: Path) -> Path:
    return path if path.is_absolute() else safe_repo_path(repo, str(path))


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    repo = args.repo.resolve()
    if args.command == "observe":
        return run_observe(repo, resolve_under_repo(repo, args.registry), args.json)
    return run_check(
        repo,
        resolve_under_repo(repo, args.manifest),
        resolve_under_repo(repo, args.report),
    )


if __name__ == "__main__":
    raise SystemExit(main())
