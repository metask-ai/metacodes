#!/usr/bin/env python3
"""Executable Lean + telemetry + Zig feedback control plane for repository rules."""

from __future__ import annotations

import argparse
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
from typing import Any, Iterable, Sequence


SCHEMA_VERSION = 1
DEFAULT_MANIFEST = Path("control-plane/rules.json")
DEFAULT_REPORT = Path("zig-out/reports/rule-control.json")
LOOP_LINKS = ("target", "sensor", "decision", "actuator", "feedback", "counterexample")
RULE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{2,127}$")
FIELD_RE = re.compile(r"^    ([a-z][a-z0-9_]*):", re.MULTILINE)
STRING_RE = re.compile(r'"([a-zA-Z_][a-zA-Z0-9_]*)"')
NONZERO_SKIP_RE = re.compile(r"(?<!\d)([1-9][0-9]*)\s+skipped\b", re.IGNORECASE)


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
    stop = source.find(".execute = agent_tool.execute", start)
    if stop < 0:
        raise ControlError("Task tool registry entry has no agent_tool.execute boundary")
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


def strip_lean_comments(source: str) -> str:
    source = re.sub(r"/-.*?-/", "", source, flags=re.DOTALL)
    return re.sub(r"--.*$", "", source, flags=re.MULTILINE)


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
        stripped = strip_lean_comments(combined)
        forbidden = sorted(set(re.findall(r"\b(?:sorry|admit|axiom)\b", stripped)))
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


def link_topology(rule: dict[str, Any], counterexamples_ok: bool) -> tuple[dict[str, bool], list[str]]:
    failures: list[str] = []
    target = rule.get("target")
    target_ok = isinstance(target, dict) and bool(target.get("goal")) and target.get("setpoint") == 0
    sensor = rule.get("sensor")
    sensor_ok = (
        isinstance(sensor, dict)
        and sensor.get("adapter") == "declaration_l2"
        and sensor.get("schema_version") == SCHEMA_VERSION
        and isinstance(sensor.get("evidence_registry"), str)
    )
    decision = rule.get("decision")
    decision_ok = (
        isinstance(decision, dict)
        and decision.get("engine") == "lean"
        and decision.get("kernel") == "MetaCodesControl.ClosedLoop.signal"
        and isinstance(decision.get("theorems"), list)
        and len(decision.get("theorems")) > 0
        and all(isinstance(name, str) and name for name in decision.get("theorems"))
    )
    actuator = rule.get("actuator")
    actuator_ok = (
        isinstance(actuator, dict)
        and actuator.get("kind") == "release_gate"
        and actuator.get("on_violation") == "block"
        and bool(actuator.get("remediation"))
    )
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
    feedback_ok = (
        isinstance(feedback, dict)
        and feedback.get("kind") == "zig_l2_then_reobserve"
        and feedback.get("reobserve") is True
        and commands_are_arrays
        and has_zig_test
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
                case_id,
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
            skipped = sum(int(value) for value in NONZERO_SKIP_RE.findall(output))
            passed = result.returncode == 0 and skipped == 0
            results.append(
                {
                    "command": raw,
                    "exit_code": result.returncode,
                    "skipped_tests": skipped,
                    "passed": passed,
                    "output_tail": output[-12000:],
                }
            )
        except subprocess.TimeoutExpired as exc:
            passed = False
            results.append(
                {
                    "command": raw,
                    "exit_code": None,
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
            counterexamples_ok, counterexample_results, counterexample_errors = verify_counterexamples(
                repo, raw_rule, kernel
            )
            topology, topology_errors = link_topology(raw_rule, counterexamples_ok)
            rule_report["topology"] = topology
            rule_report["counterexamples"] = counterexample_results
            rule_report["violations"].extend(counterexample_errors)
            rule_report["violations"].extend(topology_errors)

            sensor = raw_rule.get("sensor", {})
            registry_relative = sensor.get("evidence_registry") if isinstance(sensor, dict) else None
            if not isinstance(registry_relative, str):
                raise ControlError(f"{rule_id}: sensor evidence_registry is missing")
            registry_path = safe_repo_path(repo, registry_relative)
            before = observe_declaration_l2(repo, registry_path)
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

            after = observe_declaration_l2(repo, registry_path)
            rule_report["observation_after"] = asdict(after)
            stable_observation = before.fingerprint_sha256 == after.fingerprint_sha256
            rule_report["reobserved_after_feedback"] = True
            rule_report["observation_stable_during_feedback"] = stable_observation
            final_feedback = "passed" if feedback_ok and stable_observation else "failed"
            final = kernel.evaluate(
                rule_id,
                topology,
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
