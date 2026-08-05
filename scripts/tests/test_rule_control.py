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


class MemoryGovernanceSensorTests(unittest.TestCase):
    def make_repo(self) -> tuple[tempfile.TemporaryDirectory[str], Path]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        for directory in ("src/kg", "src/core", "src/tools", "tests/component"):
            (root / directory).mkdir(parents=True, exist_ok=True)
        (root / "src/kg/scoped_recall.zig").write_text(
            'const line = std.fmt.allocPrint(a, "- [node_id={d}]", .{h.node_id});\n'
            'try out.appendSlice(a, retrieval_protocol.AUTO_RECALL_NOTE);\n'
            'const next = "KgContext(node_id)";\n',
            encoding="utf-8",
        )
        (root / "src/kg/client.zig").write_text(
            "pub fn nodeMetadataJson() void {}\n",
            encoding="utf-8",
        )
        (root / "src/kg/retrieval_protocol.zig").write_text(
            'pub const SYSTEM_RULES = "Memory is a candidate, not a current fact; verified_by or evidences; '
            'deprecated_by, resolved_by, and contradiction; current code, git, tests, or external state";\n',
            encoding="utf-8",
        )
        (root / "src/core/system_prompt.zig").write_text(
            "const section = kg_retrieval.SYSTEM_RULES;\n",
            encoding="utf-8",
        )
        (root / "src/tools/kg_tools.zig").write_text(
            'const metadata = kg.nodeMetadataJson(node_id, true);\n'
            'const governance = buildKnowledgeGovernance(parsed.value, node_id);\n'
            'try out.appendSlice(a, ",\\\"knowledge_governance\\\":");\n'
            'const schema = "metacodes-knowledge-governance-v1";\n',
            encoding="utf-8",
        )
        (root / "src/tools.zig").write_text(
            "const context = retrieval_protocol.CONTEXT_DESCRIPTION;\n",
            encoding="utf-8",
        )
        kg_test = (
            'test "L2 KG governance: scoped recall exposes stable node ids and candidate-only guidance" {\n'
            '  const expected_id = "node_id={d}";\n'
            '  try std.testing.expect(injHas(expected_id));\n'
            '  try std.testing.expect(injHas("KgContext(node_id)"));\n'
            '}\n\n'
            'test "L2 KG governance: freshness and contradiction contract enters the actual API request" {\n'
            '  try std.testing.expect(requestHas("Memory is a candidate, not a current fact"));\n'
            '  try std.testing.expect(requestHas("verified_by or evidences"));\n'
            '  try std.testing.expect(requestHas("deprecated_by, resolved_by, and contradiction"));\n'
            '  try std.testing.expect(requestHas("current code, git, tests, or external state"));\n'
            '}\n\n'
            'test "L2 KG governance: KgContext emits evidence, freshness, and supersession signals" {\n'
            '  try std.testing.expect(resultHas("knowledge_governance"));\n'
            '  try std.testing.expect(resultHas("current_generation"));\n'
            '  try std.testing.expect(resultHas("deprecated_by"));\n'
            '  try std.testing.expect(resultHas("verification_edge_count"));\n'
            '}\n'
        )
        (root / "tests/component/kg_integration_test.zig").write_text(kg_test, encoding="utf-8")
        (root / "build.zig").write_text(
            'const kg_governance_step = b.step("test:kg-governance", "fixture");\n'
            'const files = [_][]const u8{\n'
            '  "tests/component/kg_integration_test.zig",\n'
            '};\n'
            'kg_governance_step.dependOn(&run.step);\n'
            'const later_step = b.step("test:later", "boundary");\n',
            encoding="utf-8",
        )
        return temporary, root

    def test_runtime_prompt_result_and_l2_wiring_close_all_governance_obligations(self) -> None:
        temporary, root = self.make_repo()
        self.addCleanup(temporary.cleanup)
        observation = rule_control.observe_memory_evidence_governance(root)
        self.assertTrue(observation.sensor_ok, observation.errors)
        self.assertEqual("memory_evidence_governance", observation.sensor)
        self.assertEqual(3, observation.declared)
        self.assertEqual(3, observation.covered)
        self.assertEqual(
            [{"step": "test:kg-governance", "filter": "L2 KG governance:"}],
            observation.feedback_bindings,
        )

    def test_manifest_cannot_replace_missing_automatic_recall_node_identity(self) -> None:
        temporary, root = self.make_repo()
        self.addCleanup(temporary.cleanup)
        source = root / "src/kg/scoped_recall.zig"
        source.write_text(source.read_text(encoding="utf-8").replace("h.node_id", "0"), encoding="utf-8")
        observation = rule_control.observe_memory_evidence_governance(root)
        self.assertFalse(observation.sensor_ok)
        self.assertIn("automatic_recall_node_identity", observation.missing_declarations)

    def test_commented_governance_actuator_is_not_observed_as_runtime_wiring(self) -> None:
        temporary, root = self.make_repo()
        self.addCleanup(temporary.cleanup)
        source = root / "src/tools/kg_tools.zig"
        source.write_text(
            "// buildKnowledgeGovernance knowledge_governance metacodes-knowledge-governance-v1\n",
            encoding="utf-8",
        )
        observation = rule_control.observe_memory_evidence_governance(root)
        self.assertFalse(observation.sensor_ok)
        self.assertIn("context_structured_governance", observation.missing_declarations)

    def test_unwired_governance_l2_cannot_count_as_feedback(self) -> None:
        temporary, root = self.make_repo()
        self.addCleanup(temporary.cleanup)
        build = root / "build.zig"
        build.write_text(
            'const kg_governance_step = b.step("test:kg-governance", "fixture");\n'
            '// tests/component/kg_integration_test.zig is only an inert comment\n'
            'const later_step = b.step("test:later", "boundary");\n',
            encoding="utf-8",
        )
        observation = rule_control.observe_memory_evidence_governance(root)
        self.assertFalse(observation.sensor_ok)
        self.assertEqual([], observation.covered_declarations)
        self.assertTrue(any("not wired" in error for error in observation.errors))


class ExecutionOntologySensorTests(unittest.TestCase):
    def make_repo(self) -> tuple[tempfile.TemporaryDirectory[str], Path]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        for relative in (
            "src/core",
            "src/kg",
            "src/tools",
            "tests/component",
        ):
            (root / relative).mkdir(parents=True, exist_ok=True)
        (root / "src/core/tool_exec.zig").write_text(
            "pub fn executeSlots() void {\n"
            "  if (slots[i].decision == .run and slots[i].prefetched)\n"
            "    observeSuccessfulExecutions(slots[i .. i + 1], base_ctx);\n"
            "  observeSuccessfulExecutions(slots[i..j], base_ctx);\n"
            "}\n"
            "fn observeSuccessfulExecutions() void {\n"
            "  const task_id = tasks.uniqueActiveKgTaskId() orelse return;\n"
            "  if (slot.decision != .run or slot.pending or slot.is_error or slot.content == null) continue;\n"
            "  kg.observeSuccessfulExecution(task_id, slot.name, slot.input, project_dir);\n"
            "}\n",
            encoding="utf-8",
        )
        (root / "src/core/task_store.zig").write_text(
            "pub fn uniqueActiveKgTaskId() ?u64 {\n"
            "  const node_id = std.fmt.parseInt(u64, task.id, 10) catch return null;\n"
            "  if (active != null) return null;\n"
            "  return node_id;\n"
            "}\n",
            encoding="utf-8",
        )
        (root / "src/kg/client.zig").write_text(
            "pub fn observeSuccessfulExecution() void {\n"
            "  execution_ledger.observeSuccessfulTool(task_id, tool_name, input_json, project_dir);\n"
            "}\n",
            encoding="utf-8",
        )
        (root / "src/kg/execution_knowledge.zig").write_text(
            "pub fn observeSuccessfulTool() void {\n"
            "  const resource = resourceSpec(tool_name) orelse return;\n"
            "  const raw = extractStringField(input_json, resource.field);\n"
            "  const normalized = normalizeProjectPath(raw, project_dir);\n"
            "  _ = self.record(task_id, .acts_on, normalized);\n"
            "}\n",
            encoding="utf-8",
        )
        (root / "src/tools/task_tools.zig").write_text(
            "const ProjectionReport = struct { observed: usize, projected: usize, failed: usize, dropped: usize, retained: usize };\n"
            "fn writeClosureProjection() void {\n"
            "  const snapshot = executionKnowledgeSnapshot();\n"
            "  addRefEdge(task, relation, concept, false);\n"
            "  acknowledgeExecutionFact(task, relation, value);\n"
            "}\n"
            "fn updateKgTask() void {\n"
            "  const projection = writeClosureProjection(ctx, kg, task, args);\n"
            "  appendProjectionReport(ctx, out, projection);\n"
            "}\n"
            "fn failKgTask() void {\n"
            "  const projection = writeClosureProjection(ctx, kg, task, args);\n"
            "  appendProjectionReport(ctx, out, projection);\n"
            "}\n"
            "pub fn executeStop() void {\n"
            "  const projection = writeClosureProjection(ctx, kg, task, args);\n"
            "  appendProjectionReport(ctx, out, projection);\n"
            "}\n",
            encoding="utf-8",
        )
        (root / "tests/component/kg_integration_test.zig").write_text(
            'test "L2 KG ontology feedback: successful host execution projects without model self-report" {\n'
            '  try cc.tool_exec.executeSlots();\n'
            '  try cc.task_tools.executeUpdate();\n'
            '  try std.testing.expect(has("\\"explicit\\":0"));\n'
            '  try std.testing.expect(has("\\"observed\\":2"));\n'
            '  try std.testing.expect(has("DENIED_SENTINEL"));\n'
            '  try std.testing.expect(has("MISSING_SENTINEL"));\n'
            '  try std.testing.expect(has("PRIVATE_BODY_SENTINEL"));\n'
            '  try std.testing.expect(has("first.zig"));\n'
            '  try std.testing.expect(has("second.zig"));\n'
            '}\n',
            encoding="utf-8",
        )
        (root / "build.zig").write_text(
            'const kg_ontology_feedback_step = b.step("test:kg-ontology-feedback", "fixture");\n'
            'const test_file = "tests/component/kg_integration_test.zig";\n'
            'kg_ontology_feedback_step.dependOn(&run_t.step);\n'
            'const later_step = b.step("test:later", "boundary");\n',
            encoding="utf-8",
        )
        return temporary, root

    def test_execution_sensor_projection_and_feedback_form_three_obligations(self) -> None:
        temporary, root = self.make_repo()
        self.addCleanup(temporary.cleanup)
        observation = rule_control.observe_execution_ontology_feedback(root)
        self.assertTrue(observation.sensor_ok, observation.errors)
        self.assertEqual(3, observation.declared)
        self.assertEqual(3, observation.covered)
        self.assertEqual(
            [{"step": "test:kg-ontology-feedback", "filter": "L2 KG ontology feedback:"}],
            observation.feedback_bindings,
        )

    def test_disconnected_tool_exec_sensor_is_observed(self) -> None:
        temporary, root = self.make_repo()
        self.addCleanup(temporary.cleanup)
        source = root / "src/core/tool_exec.zig"
        source.write_text(
            source.read_text(encoding="utf-8").replace(
                "kg.observeSuccessfulExecution(task_id, slot.name, slot.input, project_dir);",
                "_ = task_id;",
            ),
            encoding="utf-8",
        )
        observation = rule_control.observe_execution_ontology_feedback(root)
        self.assertFalse(observation.sensor_ok)
        self.assertIn("successful_execution_sensor", observation.missing_declarations)

    def test_comment_or_manifest_words_cannot_replace_execution_sensor(self) -> None:
        temporary, root = self.make_repo()
        self.addCleanup(temporary.cleanup)
        (root / "src/core/tool_exec.zig").write_text(
            "// observeSuccessfulExecutions kg.observeSuccessfulExecution uniqueActiveKgTaskId slot.is_error\n",
            encoding="utf-8",
        )
        observation = rule_control.observe_execution_ontology_feedback(root)
        self.assertFalse(observation.sensor_ok)
        self.assertIn("successful_execution_sensor", observation.missing_declarations)

    def test_taskupdate_must_consume_projection(self) -> None:
        temporary, root = self.make_repo()
        self.addCleanup(temporary.cleanup)
        source = root / "src/tools/task_tools.zig"
        source.write_text(
            source.read_text(encoding="utf-8").replace(
                "const projection = writeClosureProjection(ctx, kg, task, args);",
                "const projection = ProjectionReport{};",
                1,
            ),
            encoding="utf-8",
        )
        observation = rule_control.observe_execution_ontology_feedback(root)
        self.assertFalse(observation.sensor_ok)
        self.assertIn("task_close_projection_actuator", observation.missing_declarations)

    def test_unwired_focused_feedback_is_observed(self) -> None:
        temporary, root = self.make_repo()
        self.addCleanup(temporary.cleanup)
        (root / "build.zig").write_text(
            'const kg_ontology_feedback_step = b.step("test:kg-ontology-feedback", "fixture");\n'
            '// tests/component/kg_integration_test.zig and dependOn are inert comments\n'
            'const later_step = b.step("test:later", "boundary");\n',
            encoding="utf-8",
        )
        observation = rule_control.observe_execution_ontology_feedback(root)
        self.assertFalse(observation.sensor_ok)
        self.assertIn("focused_l2_feedback", observation.missing_declarations)


class FeedbackExecutionTests(unittest.TestCase):
    def test_zero_exit_with_skipped_feedback_fails_closed(self) -> None:
        passed, results = rule_control.run_feedback(
            Path.cwd(),
            {"commands": [["python", "-c", "print('1 skipped')"]], "timeout_seconds": 30},
        )
        self.assertFalse(passed)
        self.assertEqual(1, results[0]["skipped_tests"])

    def test_nonzero_feedback_fails_closed(self) -> None:
        passed, results = rule_control.run_feedback(
            Path.cwd(),
            {"commands": [["python", "-c", "raise SystemExit(7)"]], "timeout_seconds": 30},
        )
        self.assertFalse(passed)
        self.assertEqual(7, results[0]["exit_code"])


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

    def test_memory_governance_adapter_is_a_supported_sensor_link(self) -> None:
        rule = self.complete_rule()
        rule["sensor"] = {
            "adapter": "memory_evidence_governance",
            "schema_version": 1,
        }
        topology, errors = rule_control.link_topology(
            rule,
            counterexamples_ok=True,
            actuator_observed=True,
        )
        self.assertTrue(topology["sensor"], errors)

    def test_execution_ontology_rule_requires_its_runtime_lean_kernel(self) -> None:
        rule = self.complete_rule()
        rule["id"] = "ontology.execution-grounded-projection.l2"
        rule["sensor"] = {
            "adapter": "execution_ontology_feedback",
            "schema_version": 1,
        }
        rule["decision"]["kernel"] = "MetaCodesControl.ClosedLoop.executionProjectionSignal"
        topology, errors = rule_control.link_topology(
            rule,
            counterexamples_ok=True,
            actuator_observed=True,
        )
        self.assertTrue(topology["decision"], errors)
        rule["decision"]["kernel"] = "MetaCodesControl.ClosedLoop.signal"
        weakened, _ = rule_control.link_topology(
            rule,
            counterexamples_ok=True,
            actuator_observed=True,
        )
        self.assertFalse(weakened["decision"])

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
