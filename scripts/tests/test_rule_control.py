from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

from scripts import rule_control


class DeclarationSensorTests(unittest.TestCase):
    def make_repo(self) -> tuple[tempfile.TemporaryDirectory[str], Path, dict]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        (root / "src/agents").mkdir(parents=True)
        (root / "tests/component").mkdir(parents=True)
        (root / "control-plane").mkdir(parents=True)
        (root / "src/agents/def.zig").write_text(
            "pub const AgentDef = struct {\n"
            "    name: []const u8,\n"
            "    model: []const u8,\n"
            "    pub fn deinit(self: AgentDef) void { _ = self; }\n"
            "};\n",
            encoding="utf-8",
        )
        (root / "src/tools.zig").write_text(
            ".{\n"
            '    .name = "Task",\n'
            '    .input_schema = .{ .required = &.{"prompt"} },\n'
            "    .execute = agent_tool.execute,\n"
            "},\n",
            encoding="utf-8",
        )
        test_path = "tests/component/declaration_test.zig"
        (root / test_path).write_text(
            'test "L2 prompt wiring" {\n'
            "    try std.testing.expect(true);\n"
            '    _ = validateRequired("Task", "{\\"prompt\\":\\"ok\\"}");\n'
            "}\n\n"
            'test "L2 model wiring" {\n'
            "    try std.testing.expect(true);\n"
            "    _ = \"model: haiku\";\n"
            '    _ = jsonField("model");\n'
            "}\n",
            encoding="utf-8",
        )
        (root / "build.zig").write_text(
            'const declaration_step = b.step("test:declaration", "fixture");\n'
            f'const test_file = "{test_path}";\n'
            'const later_step = b.step("test:later", "boundary");\n',
            encoding="utf-8",
        )
        registry = {
            "schema_version": 1,
            "sources": {
                "agentdef": "src/agents/def.zig",
                "task_registry": "src/tools.zig",
                "build_graph": "build.zig",
            },
            "exclusions": [
                {
                    "declaration": "AgentDef.name",
                    "classification": "identity_metadata",
                    "reason": "governed by a separate identity rule",
                }
            ],
            "evidence": [
                {
                    "declaration": "Tool.Task.required.prompt",
                    "test_file": test_path,
                    "test_name": "L2 prompt wiring",
                    "feedback_step": "test:declaration",
                    "assertion_markers": ["validateRequired", "prompt"],
                }
            ],
        }
        return temporary, root, registry

    def write_registry(self, root: Path, registry: dict) -> Path:
        path = root / "control-plane/evidence.json"
        path.write_text(json.dumps(registry), encoding="utf-8")
        return path

    def test_new_runtime_field_without_l2_evidence_is_observed_as_deviation(self) -> None:
        temporary, root, registry = self.make_repo()
        self.addCleanup(temporary.cleanup)
        observation = rule_control.observe_declaration_l2(root, self.write_registry(root, registry))
        self.assertFalse(observation.sensor_ok)
        self.assertEqual(2, observation.declared)
        self.assertEqual(1, observation.covered)
        self.assertEqual(1, observation.deviation)
        self.assertEqual(["AgentDef.model"], observation.missing_declarations)

    def test_adding_exact_wired_l2_evidence_closes_the_observed_deviation(self) -> None:
        temporary, root, registry = self.make_repo()
        self.addCleanup(temporary.cleanup)
        registry["evidence"].append(
            {
                "declaration": "AgentDef.model",
                "test_file": "tests/component/declaration_test.zig",
                "test_name": "L2 model wiring",
                "feedback_step": "test:declaration",
                "assertion_markers": ["model: haiku", 'jsonField("model")'],
            }
        )
        observation = rule_control.observe_declaration_l2(root, self.write_registry(root, registry))
        self.assertTrue(observation.sensor_ok)
        self.assertEqual(2, observation.declared)
        self.assertEqual(2, observation.covered)
        self.assertEqual(0, observation.deviation)

    def test_unwired_test_file_does_not_count_as_evidence(self) -> None:
        temporary, root, registry = self.make_repo()
        self.addCleanup(temporary.cleanup)
        registry["evidence"].append(
            {
                "declaration": "AgentDef.model",
                "test_file": "tests/component/declaration_test.zig",
                "test_name": "L2 model wiring",
                "feedback_step": "test:declaration",
                "assertion_markers": ["model: haiku", 'jsonField("model")'],
            }
        )
        (root / "build.zig").write_text(
            'const declaration_step = b.step("test:declaration", "fixture");\n'
            "// component test path is deliberately absent\n"
            'const later_step = b.step("test:later", "boundary");\n',
            encoding="utf-8",
        )
        observation = rule_control.observe_declaration_l2(root, self.write_registry(root, registry))
        self.assertFalse(observation.sensor_ok)
        self.assertIn("AgentDef.model", observation.missing_declarations)
        self.assertTrue(any("not wired into build step" in error for error in observation.errors))

    def test_silent_or_duplicate_exclusions_fail_closed(self) -> None:
        temporary, root, registry = self.make_repo()
        self.addCleanup(temporary.cleanup)
        registry["exclusions"].append(
            {
                "declaration": "AgentDef.name",
                "classification": "identity_metadata",
                "reason": "duplicate",
            }
        )
        observation = rule_control.observe_declaration_l2(root, self.write_registry(root, registry))
        self.assertFalse(observation.sensor_ok)
        self.assertTrue(any("duplicate exclusion" in error for error in observation.errors))


class TopologyTests(unittest.TestCase):
    def actuator_config(self) -> dict:
        return {
            "kind": "release_gate",
            "on_violation": "block",
            "remediation": "repair executable wiring",
            "observation": {
                "schema_version": 1,
                "build_file": "control-plane/build.zig",
                "build_step": "rule-check",
                "workflow_file": ".github/workflows/cross-platform.yml",
                "workflow_job": "rule-control",
                "workflow_workdir": "metacodes",
                "telemetry_path": "metacodes/zig-out/reports/rule-control.json",
            },
        }

    def make_actuator_workspace(self) -> tuple[tempfile.TemporaryDirectory[str], Path, Path, dict]:
        temporary = tempfile.TemporaryDirectory()
        workspace = Path(temporary.name)
        repo = workspace / "metacodes"
        (workspace / ".git").mkdir()
        (workspace / ".github/workflows").mkdir(parents=True)
        (repo / "control-plane").mkdir(parents=True)
        (repo / "control-plane/build.zig").write_text(
            "const check = b.addSystemCommand(&.{ python, \"scripts/rule_control.py\", \"check\" });\n"
            "const rule_step = b.step(\"rule-check\", \"closed loop\");\n"
            "rule_step.dependOn(&check.step);\n",
            encoding="utf-8",
        )
        (workspace / ".github/workflows/cross-platform.yml").write_text(
            "defaults:\n"
            "  run:\n"
            "    working-directory: metacodes\n"
            "jobs:\n"
            "  rule-control:\n"
            "    runs-on: ubuntu-latest\n"
            "    steps:\n"
            "      - name: Run gate\n"
            "        run: zig build --build-file control-plane/build.zig rule-check\n"
            "      - name: Upload telemetry\n"
            "        if: always()\n"
            "        uses: actions/upload-artifact@v4\n"
            "        with:\n"
            "          path: metacodes/zig-out/reports/rule-control.json\n"
            "          if-no-files-found: error\n",
            encoding="utf-8",
        )
        return temporary, workspace, repo, self.actuator_config()

    def complete_rule(self) -> dict:
        return {
            "target": {"goal": "zero deviation", "setpoint": 0},
            "sensor": {
                "adapter": "declaration_l2",
                "schema_version": 1,
                "evidence_registry": "evidence.json",
            },
            "decision": {
                "engine": "lean",
                "kernel": "MetaCodesControl.ClosedLoop.signal",
                "theorems": ["missing_evidence_blocks"],
            },
            "actuator": self.actuator_config(),
            "feedback": {
                "kind": "zig_l2_then_reobserve",
                "reobserve": True,
                "commands": [["zig", "build", "test:declaration"]],
            },
            "counterexample": {"required": True, "fixture": "cases.json"},
        }

    def test_missing_actuator_is_a_formalization_orphan(self) -> None:
        rule = self.complete_rule()
        del rule["actuator"]
        topology, errors = rule_control.link_topology(
            rule,
            counterexamples_ok=True,
            actuator_observed=False,
        )
        self.assertFalse(topology["actuator"])
        self.assertTrue(any("formalization orphan" in error for error in errors))

    def test_release_gate_is_observed_from_build_ci_and_telemetry_wiring(self) -> None:
        temporary, workspace, repo, actuator = self.make_actuator_workspace()
        self.addCleanup(temporary.cleanup)
        observation = rule_control.observe_release_gate(repo, workspace, actuator)
        self.assertTrue(observation.sensor_ok, observation.errors)
        self.assertTrue(observation.build_step_wired)
        self.assertTrue(observation.workflow_command_wired)
        self.assertTrue(observation.telemetry_upload_wired)
        self.assertTrue(observation.telemetry_missing_fails)
        self.assertEqual(2, len(observation.source_sha256))

    def test_manifest_actuator_cannot_hide_a_disconnected_ci_gate(self) -> None:
        temporary, workspace, repo, actuator = self.make_actuator_workspace()
        self.addCleanup(temporary.cleanup)
        workflow = workspace / ".github/workflows/cross-platform.yml"
        workflow.write_text(
            workflow.read_text(encoding="utf-8").replace(
                "run: zig build --build-file control-plane/build.zig rule-check",
                "run: zig build test",
            ),
            encoding="utf-8",
        )
        observation = rule_control.observe_release_gate(repo, workspace, actuator)
        self.assertFalse(observation.sensor_ok)
        self.assertFalse(observation.workflow_command_wired)
        topology, errors = rule_control.link_topology(
            self.complete_rule(),
            counterexamples_ok=True,
            actuator_observed=observation.sensor_ok,
        )
        self.assertFalse(topology["actuator"])
        self.assertTrue(any("formalization orphan" in error for error in errors))

    def test_release_gate_rejects_manifest_redirect_to_decoy_files(self) -> None:
        temporary, workspace, repo, actuator = self.make_actuator_workspace()
        self.addCleanup(temporary.cleanup)
        actuator["observation"]["workflow_file"] = "decoy.yml"
        observation = rule_control.observe_release_gate(repo, workspace, actuator)
        self.assertFalse(observation.sensor_ok)
        self.assertTrue(any("canonical value" in error for error in observation.errors))

    def test_commented_build_wiring_is_not_an_observed_actuator(self) -> None:
        temporary, workspace, repo, actuator = self.make_actuator_workspace()
        self.addCleanup(temporary.cleanup)
        build = repo / "control-plane/build.zig"
        build.write_text(
            "// const check = b.addSystemCommand(&.{ python, \"scripts/rule_control.py\", \"check\" });\n"
            "// const rule_step = b.step(\"rule-check\", \"closed loop\");\n"
            "// rule_step.dependOn(&check.step);\n",
            encoding="utf-8",
        )
        observation = rule_control.observe_release_gate(repo, workspace, actuator)
        self.assertFalse(observation.sensor_ok)
        self.assertFalse(observation.controller_command_wired)
        self.assertFalse(observation.build_step_wired)

    def test_missing_telemetry_must_fail_the_ci_job(self) -> None:
        temporary, workspace, repo, actuator = self.make_actuator_workspace()
        self.addCleanup(temporary.cleanup)
        workflow = workspace / ".github/workflows/cross-platform.yml"
        workflow.write_text(
            workflow.read_text(encoding="utf-8").replace(
                "if-no-files-found: error",
                "if-no-files-found: ignore",
            ),
            encoding="utf-8",
        )
        observation = rule_control.observe_release_gate(repo, workspace, actuator)
        self.assertFalse(observation.sensor_ok)
        self.assertFalse(observation.telemetry_missing_fails)

    def test_rule_control_label_outside_jobs_is_not_a_ci_actuator(self) -> None:
        temporary, workspace, repo, actuator = self.make_actuator_workspace()
        self.addCleanup(temporary.cleanup)
        workflow = workspace / ".github/workflows/cross-platform.yml"
        workflow.write_text(
            workflow.read_text(encoding="utf-8").replace(
                "jobs:\n  rule-control:",
                "metadata:\n  rule-control:",
            ),
            encoding="utf-8",
        )
        observation = rule_control.observe_release_gate(repo, workspace, actuator)
        self.assertFalse(observation.sensor_ok)
        self.assertFalse(observation.workflow_job_wired)

    def test_counterexample_must_execute_successfully(self) -> None:
        topology, errors = rule_control.link_topology(
            self.complete_rule(),
            counterexamples_ok=False,
            actuator_observed=True,
        )
        self.assertFalse(topology["counterexample"])
        self.assertTrue(errors)

    def test_feedback_must_execute_every_observed_build_binding(self) -> None:
        observation = rule_control.Observation(
            sensor_ok=True,
            feedback_bindings=[
                {"step": "test:agentdef-fields"},
                {"step": "test:new", "filter": "L2 schema: Task"},
            ],
        )
        feedback = {"commands": [["zig", "build", "test:agentdef-fields"]]}
        errors = rule_control.feedback_binding_errors(observation, feedback)
        self.assertEqual(1, len(errors))
        self.assertIn("test:new", errors[0])

    def test_early_failure_writes_a_blocked_report_before_returning(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = root / "bad-rules.json"
            report = root / "reports/rule-control.json"
            manifest.write_text('{"schema_version":999,"rules":[]}', encoding="utf-8")
            with contextlib.redirect_stderr(io.StringIO()):
                exit_code = rule_control.run_check(root, manifest, report)
            self.assertEqual(1, exit_code)
            self.assertTrue(report.is_file())
            self.assertEqual("blocked", json.loads(report.read_text(encoding="utf-8"))["status"])


if __name__ == "__main__":
    unittest.main()
