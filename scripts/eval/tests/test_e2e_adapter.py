import json
import os
import tempfile
import unittest
from pathlib import Path

from scripts.eval.e2e_adapter import (
    MAX_NATIVE_EVENT_BYTES,
    MAX_VALIDATOR_OUTPUT_BYTES,
    NATIVE_EVENT_SCHEMA_VERSION,
    _count_policy_violations,
    _debug_tool_inputs,
    _evaluate_check,
    comparison_fingerprints,
    _is_model_tool_failure,
    _is_policy_failure_code,
    _native_trace_metrics,
    finalize_evaluation_fd,
    import_run,
    prepare_runtime_metadata,
    _trajectory_judgement,
)


def suite():
    return {
        "schema_version": 1,
        "suite_id": "adapter-test",
        "tasks": [
            {
                "id": "smoke",
                "scenario": "scenario.txt",
                "layers": ["E", "T", "L", "O", "V"],
                "environment": {"reset": "fresh"},
                "tools": {"profile": "test", "required": ["Write"]},
                "constraints": {"timeout_seconds": 10, "permission_mode": "default"},
                "success": {
                    "checks": [
                        {"type": "contains", "path": "answer.txt", "text": "done"}
                    ]
                },
                "trajectory_constraints": {
                    "required_tools": ["Write"],
                    "max_turns": 2,
                    "max_harness_tool_errors": 0,
                },
                "grader": {"kind": "deterministic_workspace", "version": "v1"},
            }
        ],
    }


class E2EAdapterTest(unittest.TestCase):
    def test_validator_output_is_killed_and_rejected_above_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / "workspace"
            workspace.mkdir()
            validator = root / "evals/validators/noisy.py"
            validator.parent.mkdir(parents=True)
            validator.write_text(
                f"print('x' * {MAX_VALIDATOR_OUTPUT_BYTES + 1})\n",
                encoding="utf-8",
            )
            result = _evaluate_check(
                {
                    "type": "validator",
                    "validator": "evals/validators/noisy.py",
                    "timeout_seconds": 10,
                },
                workspace,
                "",
                repo_root=root,
            )
        self.assertFalse(result["passed"])
        self.assertIn("output exceeds", result["evaluator_error"])

    def test_debug_tool_input_checks_ignore_thinking_and_target_actual_tool_json(self):
        debug = "\n".join(
            [
                '[DEBUG stream] event: {"thinking_delta":"consider TTL then reject it"}',
                "[INFO stream] tool_use complete id=call_1 name=KgRecall input_bytes=31",
                '[DEBUG stream] tool_use input_json={"query":"orion-k9 mode"}',
                "[INFO agent] tool.exec start(par) name=KgRecall id=call_1",
                "[INFO stream] tool_use complete id=call_2 name=Write input_bytes=40",
                '[DEBUG stream] tool_use input_json={"file_path":"answer.txt",',
                '"content":"done"}',
                "[INFO agent] tool.exec start(par) name=Write id=call_2",
            ]
        )
        self.assertEqual(_debug_tool_inputs(debug, "KgRecall"), ['{"query":"orion-k9 mode"}'])
        self.assertEqual(
            _debug_tool_inputs(debug, "Write"),
            ['{"file_path":"answer.txt",\n"content":"done"}'],
        )
        passed = _evaluate_check(
            {"type": "debug_tool_input_not_contains", "tool": "KgRecall", "text": "TTL"},
            Path("."),
            "",
            debug,
        )
        failed = _evaluate_check(
            {"type": "debug_tool_input_not_contains", "tool": "KgRecall", "text": "orion-k9"},
            Path("."),
            "",
            debug,
        )
        self.assertTrue(passed["passed"])
        self.assertFalse(failed["passed"])

    def test_min_tool_counts_requires_the_requested_multiplicity(self):
        constraints = {"required_tools": ["WebSearch"], "min_tool_counts": {"WebSearch": 3}}
        passed = _trajectory_judgement(
            constraints,
            {"tool_distribution": {"WebSearch": 3}},
        )
        failed = _trajectory_judgement(
            constraints,
            {"tool_distribution": {"WebSearch": 2, "Read": 1}},
        )
        self.assertEqual(passed["status"], "pass")
        self.assertEqual(failed["status"], "fail")
        self.assertIn("WebSearch", failed["checks"][1]["detail"])

    def _native_terminal_rollout(
        self,
        *,
        stop_reason="end_turn",
        dropped_events=0,
        request_outcome="success",
        tool_error_code=None,
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scenario.txt").write_text("write answer", encoding="utf-8")
            binary = root / "metacodes"
            binary.write_bytes(b"candidate-binary")
            run = root / "run-native-terminal"
            workspace = run / "smoke"
            workspace.mkdir(parents=True)
            metadata = prepare_runtime_metadata(
                suite(),
                root,
                "smoke",
                output=workspace / "eval-metadata.json",
                events_path=str(workspace / "events.jsonl"),
                run_id="native:terminal:0",
                trial=0,
                model_provider="test",
                model_id="model-a",
                harness_config_id="candidate",
                harness_revision="abc",
                permission_mode="default",
                binary_path=binary,
            )
            assert metadata is not None
            runtime = {
                **metadata,
                "invocation": 0,
                "task_fingerprint_provenance": "recorded_at_execution",
                "runtime_model_provider": "test",
                "runtime_model_id": "model-a",
                "runtime_permission_mode": "default",
            }
            events = [
                {"run_started": {"trace_id": "trace", "metadata": runtime}},
                {
                    "model_request_finished": {
                        "trace_id": "trace",
                        "depth": 0,
                        "turn": 1,
                        "attempt": 0,
                        "elapsed_ms": 5,
                        "outcome": request_outcome,
                    }
                },
            ]
            if tool_error_code is not None:
                events.extend(
                    [
                        {
                            "policy_decision": {
                                "trace_id": "trace",
                                "depth": 0,
                                "id": "tool-1",
                                "tool": "Write",
                                "decision": "deny",
                                "source": "pre_tool_use_hook",
                                "allowed": False,
                            }
                        },
                        {
                            "tool_started": {
                                "trace_id": "trace",
                                "id": "tool-1",
                                "name": "Write",
                                "input_bytes": 2,
                                "input_sha256": "input",
                            }
                        },
                        {
                            "tool_finished": {
                                "trace_id": "trace",
                                "id": "tool-1",
                                "name": "Write",
                                "is_error": True,
                                "error_code": tool_error_code,
                                "error_category": "safety",
                                "recoverable": False,
                                "elapsed_ms": 1,
                                "result_bytes": 2,
                                "result_sha256": "result",
                            }
                        },
                    ]
                )
                events.append(
                    {
                        "tool_stage_finished": {
                            "trace_id": "trace",
                            "depth": 0,
                            "turn": 1,
                            "tool_calls": 1,
                            "elapsed_ms": 1,
                        }
                    }
                )
            events.append(
                {
                    "run_finished": {
                        "trace_id": "trace",
                        "depth": 0,
                        "turns": 1,
                        "tool_calls": 1 if tool_error_code is not None else 0,
                        "stop_reason": stop_reason,
                        "wall_time_ms": 6,
                        "dropped_events": dropped_events,
                    }
                }
            )
            (workspace / "events.jsonl").write_text(
                "".join(
                    json.dumps(
                        {
                            "schema_version": NATIVE_EVENT_SCHEMA_VERSION,
                            "sequence": index,
                            "monotonic_elapsed_ns": index,
                            "session_id": "single",
                            "event": event,
                        },
                        sort_keys=True,
                    )
                    + "\n"
                    for index, event in enumerate(events)
                ),
                encoding="utf-8",
            )
            (workspace / "answer.txt").write_text("done\n", encoding="utf-8")
            (run / "smoke.log").write_text("finished\n", encoding="utf-8")
            (run / "smoke.debug.log").write_text("native trace\n", encoding="utf-8")
            (run / "REPORT.md").write_text(
                "## 场景: smoke\n\n- session 退出码: `0`\n", encoding="utf-8"
            )
            return import_run(suite(), root, run)[0]

    def test_policy_denials_are_not_harness_tool_failures(self):
        for code in (
            "PermissionDenied",
            "permission_denied",
            "PreToolUseBlocked",
            "pre_tool_use_blocked",
            "ToolPolicyDenied",
        ):
            self.assertTrue(_is_policy_failure_code(code), code)
        self.assertFalse(_is_policy_failure_code("OldLinesNotFound"))

    def test_model_correctable_tool_errors_use_category_with_legacy_fallback(self):
        self.assertTrue(_is_model_tool_failure("OldLinesNotFound"))
        self.assertTrue(_is_model_tool_failure("NoToolMatch"))
        self.assertTrue(_is_model_tool_failure("future_code", "user_error"))
        self.assertFalse(_is_model_tool_failure("HostToolFailed", "system_error"))

    def test_04_and_20_semantic_graders_check_outcomes_not_edit_preference(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            (workspace / "index.html").write_text(
                "const speedBoost = true;", encoding="utf-8"
            )
            boost = _evaluate_check(
                {
                    "type": "contains_any",
                    "path": "index.html",
                    "texts": ["加速", "boost", "speed"],
                },
                workspace,
                "",
            )
            explored_a = _evaluate_check(
                {"type": "log_contains", "text": "red fruit"},
                workspace,
                "apple.txt contains red fruit; banana.txt contains yellow fruit",
            )
            explored_b = _evaluate_check(
                {"type": "log_contains", "text": "yellow fruit"},
                workspace,
                "apple.txt contains red fruit; banana.txt contains yellow fruit",
            )
            self.assertTrue(boost["passed"])
            self.assertTrue(explored_a["passed"])
            self.assertTrue(explored_b["passed"])

            design = workspace / "DESIGN.md"
            design.write_text(
                "Boost Pickup — Acceleration Power-up\n"
                "Trigger Conditions (spawn)\n"
                "Duration: BOOST_MS = 5000ms (5 seconds)\n"
                "Base reward and food score multiplier\n",
                encoding="utf-8",
            )
            semantic_groups = [
                ["加速", "boost", "acceleration", "speed"],
                ["触发", "trigger", "spawn", "appear", "出现"],
                ["持续", "duration", "second", "秒", "BOOST_MS"],
                ["得分", "score", "points", "reward", "奖励"],
            ]
            for texts in semantic_groups:
                result = _evaluate_check(
                    {"type": "contains_any", "path": "DESIGN.md", "texts": texts},
                    workspace,
                    "",
                )
                self.assertTrue(result["passed"], result)

    def test_debug_log_checks_are_separate_from_user_visible_stdout(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            positive = _evaluate_check(
                {"type": "debug_log_contains", "text": "reasoning_effort=high"},
                workspace,
                "user output only",
                "POST model=glm-5.2 reasoning_effort=high",
            )
            negative = _evaluate_check(
                {"type": "debug_log_not_contains", "text": "name=blocked__echo"},
                workspace,
                "name=blocked__echo appears in the user prompt",
                "tool.exec start name=allowed__echo",
            )
            self.assertTrue(positive["passed"])
            self.assertTrue(negative["passed"])

    def test_assistant_check_does_not_accept_user_prompt_echo(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            (workspace / "transcript.jsonl").write_text(
                json.dumps(
                    {
                        "role": "user",
                        "blocks": [{"type": "text", "text": "secret from prompt"}],
                    }
                )
                + "\n"
                + json.dumps(
                    {
                        "role": "assistant",
                        "blocks": [{"type": "text", "text": "verified answer"}],
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            prompt_only = _evaluate_check(
                {"type": "assistant_contains", "text": "secret from prompt"},
                workspace,
                "secret from prompt",
            )
            assistant = _evaluate_check(
                {"type": "assistant_contains", "text": "verified answer"},
                workspace,
                "",
            )
            self.assertFalse(prompt_only["passed"])
            self.assertTrue(assistant["passed"])

    def test_workspace_grader_rejects_symlinks_and_traversal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / "workspace"
            workspace.mkdir()
            outside = root / "outside.txt"
            outside.write_text("secret", encoding="utf-8")
            (workspace / "escape.txt").symlink_to(outside)
            symlink = _evaluate_check(
                {"type": "contains", "path": "escape.txt", "text": "secret"},
                workspace,
                "",
            )
            traversal = _evaluate_check(
                {"type": "contains", "path": "../outside.txt", "text": "secret"},
                workspace,
                "",
            )
            (workspace / "dangling").symlink_to(root / "missing")
            dangling = _evaluate_check(
                {"type": "file_absent", "path": "dangling"}, workspace, ""
            )
            for result in (symlink, traversal, dangling):
                self.assertFalse(result["passed"])
                self.assertIsNotNone(result["evaluator_error"])

            if hasattr(os, "mkfifo"):
                os.mkfifo(workspace / "blocked")
                fifo = _evaluate_check(
                    {"type": "contains", "path": "blocked", "text": "never"},
                    workspace,
                    "",
                )
                self.assertFalse(fifo["passed"])
                self.assertIn("not a regular file", fifo["evaluator_error"])

    def test_missing_expected_file_is_outcome_failure_not_evaluator_error(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            for check in (
                {"type": "contains", "path": "missing.txt", "text": "proof"},
                {"type": "contains_any", "path": "missing.txt", "texts": ["proof"]},
                {"type": "min_lines", "path": "missing.txt", "minimum": 1},
                {"type": "not_contains", "path": "missing.txt", "text": "forbidden"},
            ):
                result = _evaluate_check(check, workspace, "")
                self.assertFalse(result["passed"])
                self.assertIsNone(result["evaluator_error"])

    def test_native_trace_reader_rejects_links_special_files_and_oversize(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            regular = root / "regular.jsonl"
            regular.write_text("{}\n", encoding="utf-8")
            link = root / "events-link.jsonl"
            link.symlink_to(regular)
            native, error = _native_trace_metrics(link)
            self.assertIsNone(native)
            self.assertIn("forbidden symlink", error)

            oversized = root / "oversized.jsonl"
            with oversized.open("wb") as handle:
                handle.truncate(MAX_NATIVE_EVENT_BYTES + 1)
            native, error = _native_trace_metrics(oversized)
            self.assertIsNone(native)
            self.assertIn("byte limit", error)

            if hasattr(os, "mkfifo"):
                fifo = root / "events.fifo"
                os.mkfifo(fifo)
                native, error = _native_trace_metrics(fifo)
                self.assertIsNone(native)
                self.assertIn("not a regular file", error)

    def test_finalize_evaluation_fd_is_bounded_and_never_replaces_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "events.jsonl"
            with tempfile.TemporaryFile() as artifact:
                artifact.write(b'{"event":"trusted"}\n')
                artifact.flush()
                finalize_evaluation_fd(artifact.fileno(), output)
            self.assertEqual(output.read_bytes(), b'{"event":"trusted"}\n')

            with tempfile.TemporaryFile() as replacement:
                replacement.write(b'{"event":"forged"}\n')
                replacement.flush()
                with self.assertRaises(FileExistsError):
                    finalize_evaluation_fd(replacement.fileno(), output)
            self.assertEqual(output.read_bytes(), b'{"event":"trusted"}\n')

    def test_native_trace_rejects_unpaired_and_out_of_order_lifecycles(self):
        metadata = {
            "run_id": "run",
            "invocation": 0,
            "trial": 0,
            "suite_id": "suite",
            "task_id": "task",
            "task_fingerprint": "task-fp",
            "model_provider": "test",
            "model_id": "model",
            "model_fingerprint": "model-fp",
            "runtime_model_provider": "test",
            "runtime_model_id": "model",
            "harness_config_id": "candidate",
            "harness_revision": "abc",
            "harness_fingerprint": "harness-fp",
            "permission_mode": "default",
            "runtime_permission_mode": "default",
            "environment_fingerprint": "environment-fp",
            "grader_fingerprint": "grader-fp",
        }
        events = [
            {"run_started": {"trace_id": "trace", "metadata": metadata}},
            {
                "tool_finished": {
                    "trace_id": "trace",
                    "id": "tool-1",
                    "name": "Write",
                    "is_error": False,
                    "elapsed_ms": 1,
                    "result_bytes": 1,
                }
            },
            {
                "tool_started": {
                    "trace_id": "trace",
                    "id": "tool-1",
                    "name": "Write",
                    "input_bytes": 1,
                }
            },
            {
                "run_finished": {
                    "trace_id": "trace",
                    "depth": 0,
                    "turns": 1,
                    "tool_calls": 1,
                    "stop_reason": "end_turn",
                    "wall_time_ms": 2,
                    "dropped_events": 0,
                }
            },
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            path.write_text(
                "".join(
                    json.dumps(
                        {
                            "schema_version": NATIVE_EVENT_SCHEMA_VERSION,
                            "sequence": index,
                            "monotonic_elapsed_ns": index,
                            "session_id": "single",
                            "event": event,
                        }
                    )
                    + "\n"
                    for index, event in enumerate(events)
                ),
                encoding="utf-8",
            )
            native, error = _native_trace_metrics(path)
            self.assertIsNone(native)
            self.assertIn("tool finished before start", error)

    def test_native_trace_rejects_orphan_policy_and_impossible_latency(self):
        metadata = {
            "run_id": "run",
            "invocation": 0,
            "trial": 0,
            "suite_id": "suite",
            "task_id": "task",
            "task_fingerprint": "task-fp",
            "model_provider": "test",
            "model_id": "model",
            "model_fingerprint": "model-fp",
            "runtime_model_provider": "test",
            "runtime_model_id": "model",
            "harness_config_id": "candidate",
            "harness_revision": "abc",
            "harness_fingerprint": "harness-fp",
            "permission_mode": "default",
            "runtime_permission_mode": "default",
            "environment_fingerprint": "environment-fp",
            "grader_fingerprint": "grader-fp",
        }

        def write(events, path):
            path.write_text(
                "".join(
                    json.dumps(
                        {
                            "schema_version": NATIVE_EVENT_SCHEMA_VERSION,
                            "sequence": index,
                            "monotonic_elapsed_ns": index,
                            "session_id": "single",
                            "event": event,
                        }
                    )
                    + "\n"
                    for index, event in enumerate(events)
                ),
                encoding="utf-8",
            )

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            write(
                [
                    {"run_started": {"trace_id": "trace", "metadata": metadata}},
                    {
                        "policy_decision": {
                            "trace_id": "trace",
                            "depth": 0,
                            "id": "ghost",
                            "tool": "Write",
                            "decision": "allow",
                            "source": "permission_chain",
                            "allowed": True,
                        }
                    },
                    {
                        "run_finished": {
                            "trace_id": "trace",
                            "depth": 0,
                            "turns": 1,
                            "tool_calls": 0,
                            "stop_reason": "end_turn",
                            "wall_time_ms": 10,
                            "dropped_events": 0,
                        }
                    },
                ],
                path,
            )
            native, error = _native_trace_metrics(path)
            self.assertIsNone(native)
            self.assertIn("policy decision has no tool attempt", error)

            write(
                [
                    {"run_started": {"trace_id": "trace", "metadata": metadata}},
                    {
                        "model_request_finished": {
                            "trace_id": "trace",
                            "depth": 0,
                            "turn": 1,
                            "attempt": 0,
                            "elapsed_ms": 9,
                            "outcome": "success",
                        }
                    },
                    {
                        "tool_stage_finished": {
                            "trace_id": "trace",
                            "depth": 0,
                            "turn": 1,
                            "tool_calls": 0,
                            "elapsed_ms": 5,
                        }
                    },
                    {
                        "run_finished": {
                            "trace_id": "trace",
                            "depth": 0,
                            "turns": 1,
                            "tool_calls": 0,
                            "stop_reason": "end_turn",
                            "wall_time_ms": 10,
                            "dropped_events": 0,
                        }
                    },
                ],
                path,
            )
            native, error = _native_trace_metrics(path)
            self.assertIsNone(native)
            self.assertIn("latency spans exceed run wall time", error)

    def test_native_trace_rejects_denied_tool_reported_as_success(self):
        metadata = {
            "run_id": "run",
            "invocation": 0,
            "trial": 0,
            "suite_id": "suite",
            "task_id": "task",
            "task_fingerprint": "task-fp",
            "model_provider": "test",
            "model_id": "model",
            "model_fingerprint": "model-fp",
            "runtime_model_provider": "test",
            "runtime_model_id": "model",
            "harness_config_id": "candidate",
            "harness_revision": "abc",
            "harness_fingerprint": "harness-fp",
            "permission_mode": "default",
            "runtime_permission_mode": "default",
            "environment_fingerprint": "environment-fp",
            "grader_fingerprint": "grader-fp",
        }
        events = [
            {"run_started": {"trace_id": "trace", "metadata": metadata}},
            {
                "policy_decision": {
                    "trace_id": "trace",
                    "depth": 0,
                    "id": "tool-1",
                    "tool": "Write",
                    "decision": "deny",
                    "source": "permission_chain",
                    "allowed": False,
                }
            },
            {
                "tool_started": {
                    "trace_id": "trace",
                    "id": "tool-1",
                    "name": "Write",
                    "input_bytes": 1,
                    "input_sha256": "input",
                }
            },
            {
                "tool_finished": {
                    "trace_id": "trace",
                    "id": "tool-1",
                    "name": "Write",
                    "is_error": False,
                    "error_code": None,
                    "elapsed_ms": 1,
                    "result_bytes": 1,
                    "result_sha256": "result",
                }
            },
            {
                "run_finished": {
                    "trace_id": "trace",
                    "depth": 0,
                    "turns": 1,
                    "tool_calls": 1,
                    "stop_reason": "end_turn",
                    "wall_time_ms": 2,
                    "dropped_events": 0,
                }
            },
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            path.write_text(
                "".join(
                    json.dumps(
                        {
                            "schema_version": NATIVE_EVENT_SCHEMA_VERSION,
                            "sequence": index,
                            "monotonic_elapsed_ns": index,
                            "session_id": "single",
                            "event": event,
                        }
                    )
                    + "\n"
                    for index, event in enumerate(events)
                ),
                encoding="utf-8",
            )
            native, error = _native_trace_metrics(path)
            self.assertIsNone(native)
            self.assertIn("denied tool did not finish as policy failure", error)

    def test_native_api_error_with_zero_exit_is_invalid(self):
        rollout = self._native_terminal_rollout(
            stop_reason="api_error", request_outcome="api_error"
        )
        self.assertEqual(rollout["outcome"]["status"], "pass")
        self.assertEqual(rollout["execution"]["status"], "invalid")
        self.assertEqual(rollout["metrics"]["harness_errors"], 1)
        self.assertEqual(rollout["metrics"]["network_errors"], 1)
        self.assertFalse(rollout["judgement"]["trustworthy_success"])

    def test_native_dropped_events_are_invalid(self):
        rollout = self._native_terminal_rollout(dropped_events=3)
        self.assertEqual(rollout["execution"]["status"], "invalid")
        self.assertIn("native_events_dropped:3", rollout["execution"]["invalid_reasons"])
        self.assertFalse(rollout["judgement"]["trustworthy_success"])

    def test_native_pre_tool_hook_block_is_policy_not_harness_failure(self):
        rollout = self._native_terminal_rollout(
            tool_error_code="permission_denied"
        )
        self.assertEqual(rollout["metrics"]["permission_denials"], 1)
        self.assertEqual(rollout["metrics"]["harness_tool_errors"], 0)
        self.assertEqual(rollout["metrics"]["policy_violations"], 0)

    def test_policy_completeness_pairs_exact_tool_use_id_not_tool_name(self):
        tool_starts = [
            {"trace_id": "trace", "id": "tu-1", "name": "Write"},
            {"trace_id": "trace", "id": "tu-2", "name": "Write"},
        ]
        policies = [
            {"trace_id": "trace", "id": "tu-1", "tool": "Write"},
            {"trace_id": "trace", "id": "tu-1", "tool": "Write"},
        ]
        self.assertEqual(_count_policy_violations(tool_starts, policies), 1)

    def test_task_fingerprint_covers_companion_conf_and_declared_fixtures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scenario.txt").write_text("prompt", encoding="utf-8")
            (root / "scenario.conf").write_text("PERMISSION=default\n", encoding="utf-8")
            (root / "agent.md").write_text("name: fixture\n", encoding="utf-8")
            binary = root / "metacodes"
            binary.write_bytes(b"binary")
            task = suite()["tasks"][0]
            task["environment"]["fixtures"] = ["agent.md"]

            before = comparison_fingerprints(
                task,
                root,
                model_provider="openai",
                model_id="glm-5.2",
                harness_config_id="candidate",
                harness_revision="abc",
                permission_mode="default",
                binary_path=binary,
            )
            (root / "agent.md").write_text("name: changed\n", encoding="utf-8")
            after_fixture = comparison_fingerprints(
                task,
                root,
                model_provider="openai",
                model_id="glm-5.2",
                harness_config_id="candidate",
                harness_revision="abc",
                permission_mode="default",
                binary_path=binary,
            )
            self.assertNotEqual(before["task_fingerprint"], after_fixture["task_fingerprint"])
            self.assertNotEqual(before["environment_fingerprint"], after_fixture["environment_fingerprint"])

            (root / "scenario.conf").write_text("PERMISSION=default\nGIT_INIT=1\n", encoding="utf-8")
            after_conf = comparison_fingerprints(
                task,
                root,
                model_provider="openai",
                model_id="glm-5.2",
                harness_config_id="candidate",
                harness_revision="abc",
                permission_mode="default",
                binary_path=binary,
            )
            self.assertNotEqual(after_fixture["task_fingerprint"], after_conf["task_fingerprint"])

    def test_native_events_use_execution_time_grounding_and_policy_telemetry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scenario.txt").write_text("write answer", encoding="utf-8")
            binary = root / "metacodes"
            binary.write_bytes(b"candidate-binary")
            run = root / "run-native"
            workspace = run / "smoke"
            workspace.mkdir(parents=True)
            metadata = prepare_runtime_metadata(
                suite(),
                root,
                "smoke",
                output=workspace / "eval-metadata.json",
                events_path=str(workspace / "events.jsonl"),
                run_id="native:smoke:0",
                trial=0,
                model_provider="test",
                model_id="model-a",
                harness_config_id="candidate",
                harness_revision="abc",
                permission_mode="default",
                binary_path=binary,
            )
            self.assertIsNotNone(metadata)
            assert metadata is not None
            runtime = {
                **metadata,
                "invocation": 0,
                "task_fingerprint_provenance": "recorded_at_execution",
                "runtime_model_provider": "test",
                "runtime_model_id": "model-a",
                "runtime_permission_mode": "default",
            }
            events = [
                {"run_started": {"trace_id": "trace", "metadata": runtime}},
                {"turn_started": {"trace_id": "trace", "depth": 0, "turn": 1}},
                {
                    "model_request_finished": {
                        "trace_id": "trace",
                        "depth": 0,
                        "turn": 1,
                        "attempt": 0,
                        "elapsed_ms": 30,
                        "outcome": "success",
                    }
                },
                {
                    "policy_decision": {
                        "trace_id": "trace",
                        "depth": 0,
                        "id": "tu-1",
                        "tool": "Write",
                        "decision": "allow",
                        "source": "permission_chain",
                        "allowed": True,
                    }
                },
                {
                    "tool_started": {
                        "trace_id": "trace",
                        "id": "tu-1",
                        "name": "Write",
                        "input_bytes": 12,
                        "input_sha256": "abc",
                    }
                },
                {
                    "tool_finished": {
                        "trace_id": "trace",
                        "id": "tu-1",
                        "name": "Write",
                        "is_error": False,
                        "error_code": None,
                        "error_category": None,
                        "recoverable": None,
                        "elapsed_ms": 5,
                        "result_bytes": 2,
                        "result_sha256": "def",
                    }
                },
                {
                    "usage": {
                        "trace_id": "trace",
                        "input_tokens": 100,
                        "output_tokens": 20,
                        "cache_read_tokens": 10,
                        "cache_write_tokens": 0,
                        "estimated_cost_usd": 0.001,
                        "pricing_provenance": "test",
                    }
                },
                {
                    "tool_stage_finished": {
                        "trace_id": "trace",
                        "depth": 0,
                        "turn": 1,
                        "tool_calls": 1,
                        "elapsed_ms": 5,
                    }
                },
                {
                    "run_finished": {
                        "trace_id": "trace",
                        "depth": 0,
                        "turns": 1,
                        "tool_calls": 1,
                        "stop_reason": "end_turn",
                        "wall_time_ms": 42,
                        "dropped_events": 0,
                    }
                },
            ]
            (workspace / "events.jsonl").write_text(
                "".join(
                    json.dumps(
                        {
                            "schema_version": NATIVE_EVENT_SCHEMA_VERSION,
                            "sequence": index,
                            "monotonic_elapsed_ns": index,
                            "session_id": "single",
                            "event": event,
                        },
                        sort_keys=True,
                    )
                    + "\n"
                    for index, event in enumerate(events)
                ),
                encoding="utf-8",
            )
            (workspace / "answer.txt").write_text("done\n", encoding="utf-8")
            (run / "smoke.log").write_text("finished\n", encoding="utf-8")
            (run / "smoke.debug.log").write_text("native trace\n", encoding="utf-8")
            (run / "REPORT.md").write_text(
                "## 场景: smoke\n\n- session 退出码: `0`\n", encoding="utf-8"
            )

            rollout = import_run(suite(), root, run)[0]
            self.assertEqual(
                rollout["task_fingerprint_provenance"], "recorded_at_execution"
            )
            self.assertEqual(rollout["run_id"], "native:smoke:0")
            self.assertEqual(rollout["model"]["fingerprint"], metadata["model_fingerprint"])
            self.assertEqual(rollout["metrics"]["cost_usd"], 0.001)
            self.assertEqual(rollout["metrics"]["wall_time_ms"], 42)
            self.assertEqual(rollout["metrics"]["model_request_time_ms"], 30)
            self.assertEqual(rollout["metrics"]["tool_stage_time_ms"], 5)
            self.assertEqual(rollout["metrics"]["harness_time_ms"], 7)
            self.assertEqual(rollout["metrics"]["model_request_outcomes"], {"success": 1})
            self.assertEqual(rollout["metrics"]["policy_violations"], 0)
            self.assertTrue(rollout["judgement"]["trustworthy_success"])

    def test_old_native_events_remain_importable_and_old_lines_is_model_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scenario.txt").write_text("write answer", encoding="utf-8")
            binary = root / "metacodes"
            binary.write_bytes(b"candidate-binary")
            run = root / "run-legacy"
            workspace = run / "smoke"
            workspace.mkdir(parents=True)
            metadata = prepare_runtime_metadata(
                suite(), root, "smoke",
                output=workspace / "eval-metadata.json",
                events_path=str(workspace / "events.jsonl"),
                run_id="legacy:smoke:0", trial=0,
                model_provider="test", model_id="model-a",
                harness_config_id="candidate", harness_revision="abc",
                permission_mode="default", binary_path=binary,
            )
            assert metadata is not None
            runtime = {
                **metadata,
                "invocation": 0,
                "task_fingerprint_provenance": "recorded_at_execution",
                "runtime_model_id": "model-a",
                "runtime_permission_mode": "default",
            }
            events = [
                {"run_started": {"trace_id": "trace", "metadata": runtime}},
                {"tool_started": {"trace_id": "trace", "id": "tu-1", "name": "ApplyPatch", "input_bytes": 1, "input_sha256": "a"}},
                {"tool_finished": {"trace_id": "trace", "id": "tu-1", "name": "ApplyPatch", "is_error": True, "error_code": "OldLinesNotFound", "elapsed_ms": 1, "result_bytes": 1, "result_sha256": "b"}},
                {"run_finished": {"trace_id": "trace", "depth": 0, "turns": 1, "tool_calls": 1, "stop_reason": "end_turn", "wall_time_ms": 10, "dropped_events": 0}},
            ]
            (workspace / "events.jsonl").write_text(
                "".join(json.dumps({"schema_version": NATIVE_EVENT_SCHEMA_VERSION, "sequence": index, "monotonic_elapsed_ns": index, "session_id": "single", "event": event}, sort_keys=True) + "\n" for index, event in enumerate(events)),
                encoding="utf-8",
            )
            (workspace / "answer.txt").write_text("done\n", encoding="utf-8")
            (run / "smoke.log").write_text("finished\n", encoding="utf-8")
            (run / "smoke.debug.log").write_text("legacy native trace\n", encoding="utf-8")
            (run / "REPORT.md").write_text("## 场景: smoke\n\n- session 退出码: `0`\n", encoding="utf-8")

            rollout = import_run(suite(), root, run)[0]
            self.assertEqual(rollout["metrics"]["model_tool_errors"], 1)
            self.assertEqual(rollout["metrics"]["harness_tool_errors"], 0)
            self.assertIsNone(rollout["metrics"]["model_request_time_ms"])
            self.assertIsNone(rollout["metrics"]["harness_time_ms"])

    def test_import_separates_outcome_trajectory_and_evaluator(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scenario.txt").write_text("write answer", encoding="utf-8")
            run = root / "run-1"
            workspace = run / "smoke"
            workspace.mkdir(parents=True)
            (workspace / "answer.txt").write_text("done\n", encoding="utf-8")
            (run / "smoke.log").write_text("finished\n", encoding="utf-8")
            (run / "smoke.debug.log").write_text(
                "\n".join(
                    [
                        "metacodes starting; model=model-a",
                        "turn 1/50 starting (msgs=1)",
                        "[INFO agent] usage in=100 out=20 cache_r=10 cache_w=0",
                        "tool.exec start name=Write id=1",
                        "tool.exec done name=Write output_bytes=2 duration_ms=3",
                    ]
                ),
                encoding="utf-8",
            )
            (run / "REPORT.md").write_text(
                "## 场景: smoke\n\n- session 退出码: `0`\n",
                encoding="utf-8",
            )

            rollout = import_run(
                suite(),
                root,
                run,
                {
                    "model": {"provider": "test", "id": "model-a"},
                    "harness": {"config_id": "harness-a", "revision": "abc"},
                },
            )[0]
            self.assertEqual(rollout["execution"]["status"], "completed")
            self.assertEqual(rollout["outcome"]["status"], "pass")
            self.assertEqual(rollout["trajectory"]["status"], "pass")
            self.assertEqual(rollout["evaluator"]["status"], "ready")
            self.assertTrue(rollout["judgement"]["trustworthy_success"])
            self.assertEqual(rollout["metrics"]["input_tokens"], 100)
            self.assertEqual(rollout["metrics"]["tool_time_ms"], 3)

    def test_infrastructure_failure_is_invalid_not_agent_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scenario.txt").write_text("write answer", encoding="utf-8")
            run = root / "run-2"
            workspace = run / "smoke"
            workspace.mkdir(parents=True)
            (workspace / "answer.txt").write_text("done\n", encoding="utf-8")
            (run / "smoke.log").write_text("", encoding="utf-8")
            (run / "smoke.debug.log").write_text(
                "metacodes starting; model=model-a\n[ERROR client] ApiError provider unavailable\n",
                encoding="utf-8",
            )
            (run / "REPORT.md").write_text(
                "## 场景: smoke\n\n- session 退出码: `1`\n",
                encoding="utf-8",
            )
            rollout = import_run(suite(), root, run)[0]
            self.assertEqual(rollout["execution"]["status"], "invalid")
            self.assertEqual(rollout["outcome"]["status"], "pass")
            self.assertFalse(rollout["judgement"]["valid_for_scoring"])
            self.assertIn("E", {item["source"] for item in rollout["attribution"]})


if __name__ == "__main__":
    unittest.main()
