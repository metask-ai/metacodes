import asyncio
import importlib
import importlib.util
import sys
import types
import ast
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

try:
    import yaml
except ImportError as error:  # pragma: no cover - environment, not logic
    raise ImportError(
        "PyYAML is required here: python3 -m pip install -r requirements-dev.txt"
    ) from error

from scripts.eval.workbuddy import WORKBUDDY_PINNED_COMMIT
from scripts.eval.workbuddy.cohort_manifest import (
    CohortError,
    SUBSETS,
    build_manifest,
)
from scripts.eval.workbuddy.stage_artifacts import StageError, stage
from scripts.eval.workbuddy.environment_preflight import (
    EnvironmentPreflightError,
    prebuild,
    validate_receipt,
)
from scripts.eval.workbuddy.install_overlay import _digest
from scripts.eval.workbuddy import install_overlay as overlay_installer
from scripts.eval.workbuddy.key_fd import (
    CredentialFdError,
    _SECRET_CACHE,
    resolve_secret_env,
)
from scripts.eval.workbuddy.trace import (
    CONTROL_METRICS_SCHEMA,
    CURRENT_FORMAL_BATCH_SCHEMA,
    FILTER_BINDING_BATCH_SCHEMAS,
    RULE_FILTER_PROOFS,
    OBSERVATION_JOURNAL_SCHEMA,
    CURRENT_OBSERVATION_JOURNAL_SCHEMA,
    TOOL_OBSERVATION_SCHEMA,
    EXECUTION_EFFECT_SCHEMA,
    _provider_attempt_id,
    TraceError,
    anthropic_messages_endpoint,
    final_result,
    load_control_metrics,
    load_trace_ir,
    project_state_hash,
    read_json_lines,
    transcript_ir,
)
from scripts.eval.workbuddy.progress_analysis import analyze_progress
from scripts.eval.tests.posix_only import POSIX, requires_symlinks


ZERO_COMMIT = "0" * 40
ONE_COMMIT = "1" * 40


class WorkBuddyTraceTest(unittest.TestCase):
    @staticmethod
    def _write_jsonl(path: Path, rows) -> None:
        path.write_text(
            "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows),
            encoding="utf-8",
        )

    @staticmethod
    def _journal(*events):
        payloads = [{"run_started": {}}, *events, {"run_finished": {}}]
        return [
            {
                "schema_version": OBSERVATION_JOURNAL_SCHEMA,
                "sequence": sequence,
                "monotonic_elapsed_ns": sequence,
                "session_id": "session-control-l2",
                "run_id": "run-control-l2",
                "event": payload,
            }
            for sequence, payload in enumerate(payloads)
        ]

    def test_project_state_hash_matches_zig_xxhash64(self):
        self.assertEqual(project_state_hash("/workspace"), "5807156ecf67bb70")

    def test_proxy_origin_becomes_complete_anthropic_messages_endpoint(self):
        for source in (
            "http://host.docker.internal:3456",
            "http://host.docker.internal:3456/",
            "http://host.docker.internal:3456/v1/messages",
            "http://host.docker.internal:3456/v1/messages/",
        ):
            self.assertEqual(
                anthropic_messages_endpoint(source),
                "http://host.docker.internal:3456/v1/messages",
            )
        for invalid in (
            "",
            "host.docker.internal:3456",
            "http://host.docker.internal:3456/other",
            "http://host.docker.internal:3456/?route=glm",
            "http://host.docker.internal:3456/#fragment",
            "http://host.docker.internal:3456\n/v1/messages",
        ):
            with self.subTest(invalid=invalid), self.assertRaises(TraceError):
                anthropic_messages_endpoint(invalid)

    def test_transcript_maps_calls_results_and_cache_metrics_without_dropping_provenance(self):
        result = final_result(
            [
                {
                    "type": "result",
                    "stop_reason": "end_turn",
                    "turns": 2,
                    "tool_calls": 1,
                    "input_tokens": 120,
                    "output_tokens": 30,
                    "cache_read_input_tokens": 80,
                    "cache_creation_input_tokens": 10,
                    "cost_usd": 0.01,
                    "text": "done",
                }
            ]
        )
        steps = transcript_ir(
            [
                {"role": "user", "blocks": [{"type": "text", "text": "fix it"}]},
                {
                    "role": "assistant",
                    "blocks": [
                        {"type": "thinking", "thinking": "inspect"},
                        {
                            "type": "tool_use",
                            "id": "call-1",
                            "name": "Read",
                            "input": '{"file_path":"a.txt"}',
                        },
                    ],
                },
                {
                    "role": "user",
                    "blocks": [
                        {
                            "type": "tool_result",
                            "tool_use_id": "call-1",
                            "content": "old",
                            "is_error": False,
                        }
                    ],
                },
                {
                    "role": "assistant",
                    "blocks": [{"type": "text", "text": "done"}],
                },
            ],
            result=result,
        )
        self.assertEqual([row["source"] for row in steps], ["user", "agent", "agent"])
        self.assertEqual(steps[1]["tool_calls"][0]["arguments"], {"file_path": "a.txt"})
        self.assertEqual(
            steps[1]["observations"][0],
            {
                "source_call_id": "call-1",
                "content": "old",
                "extra": {"is_error": False},
            },
        )
        self.assertEqual(result["cache_read_input_tokens"], 80)
        self.assertEqual(result["cache_creation_input_tokens"], 10)

    def test_result_is_exactly_once_and_fail_closed(self):
        row = {
            "type": "result",
            "stop_reason": "end_turn",
            "turns": 1,
            "tool_calls": 0,
            "input_tokens": 1,
            "output_tokens": 1,
            "cost_usd": 0,
            "text": "ok",
        }
        with self.assertRaises(TraceError):
            final_result([])
        with self.assertRaises(TraceError):
            final_result([row, row])
        # --stream-json 增量事件行(text/tool/usage/turn)与 result 行同栖一个
        # NDJSON 流:过滤按 type=="result",事件行不得影响 exactly-once 语义。
        stream_events = [
            {"type": "turn_begin", "turn": 1},
            {"type": "tool_start", "id": "t1", "name": "Bash", "input": "{}", "input_bytes": 2},
            {"type": "text", "text": "hi"},
            {"type": "usage", "input_tokens": 5, "output_tokens": 2,
             "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0},
            row,
            {"type": "run_end", "turns": 1, "tool_calls": 1, "stop_reason": "end_turn"},
        ]
        self.assertEqual(final_result(stream_events)["stop_reason"], row["stop_reason"])

    def test_trace_reads_non_utf8_tolerantly_but_still_rejects_malformed_json(self):
        # metacodes' transcript writer (src/core/transcript.zig) echoes a
        # tool_result's content through std.json.Stringify with default options,
        # which pass raw 0x80..0xFF through verbatim; a Read of a generated
        # .pptx/.pdf therefore lands raw non-UTF-8 bytes in the transcript. #109
        # fixed the --stream-json/--json *output* encoder but not the transcript
        # writer, and load_trace_ir reads the transcript through read_json_lines
        # *before* load_control_metrics, so a strict decode aborts the whole
        # harbor cohort. Decode tolerantly with U+FFFD -- but only the byte
        # decode is relaxed: a structurally malformed line must still fail
        # closed, and callers bind evidence over the raw bytes.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tolerant = root / "trace.jsonl"
            tolerant.write_bytes(b'{"type":"result","text":"pdf \xbb marker"}\n')
            rows = read_json_lines(tolerant)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["type"], "result")
            self.assertEqual(rows[0]["text"], "pdf � marker")
            malformed = root / "malformed.jsonl"
            malformed.write_bytes(b'{"type":"result",\xbb not json}\n')
            with self.assertRaises(TraceError):
                read_json_lines(malformed)

    def test_load_trace_ir_tolerates_non_utf8_transcript(self):
        # load_trace_ir reads the transcript through read_json_lines *before*
        # populate_context_post_run reaches load_control_metrics, so a non-UTF-8
        # transcript (a .pptx/.pdf read back into a tool result) aborts the whole
        # cohort here first unless this read is tolerant.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "metacodes-output.jsonl"
            transcript = root / "metacodes-transcript.jsonl"
            output.write_bytes(
                b'{"type":"result","stop_reason":"end_turn","turns":1,'
                b'"tool_calls":0,"input_tokens":1,"output_tokens":1,'
                b'"cost_usd":0.0,"text":"ok"}\n'
            )
            transcript.write_bytes(
                b'{"role":"user","blocks":[{"type":"text",'
                b'"text":"open the \xbb deck"}]}\n'
            )
            trace = load_trace_ir(output, transcript)
        self.assertEqual(trace["result"]["stop_reason"], "end_turn")
        self.assertEqual(len(trace["steps"]), 1)
        self.assertEqual(trace["steps"][0]["source"], "user")

    def test_control_metrics_tolerate_non_utf8_control_evidence(self):
        # office-sealed 2026-09-05 (html-report-quadrant-ppt, byte 0xbb): a task
        # read a generated .pptx back into a tool result, so raw non-UTF-8 bytes
        # reached the transcript journal. load_control_metrics decoded both
        # journals with errors="strict", raised "control evidence is not UTF-8",
        # and populate_context_post_run turned that into a RuntimeError that
        # aborted the whole harbor cohort at 17/30. Both decodes must be tolerant
        # and succeed; the source hashes are taken over the raw bytes, so U+FFFD
        # replacement never disturbs evidence binding.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            transcript.write_bytes(
                b'{"role":"assistant","blocks":[{"type":"tool_use",'
                b'"id":"r","name":"Read","input":{"file_path":"deck.pptx"}}]}\n'
                b'{"role":"user","blocks":[{"type":"tool_result",'
                b'"tool_use_id":"r","content":"PK \xbb pptx","is_error":false}]}\n'
            )
            # Also exercise the observation-journal decode path: a raw 0xbb in
            # the hash-only, consistency-checked session id (identical in every
            # row) decodes to a consistent U+FFFD.
            observation.write_bytes(
                "".join(
                    json.dumps(row, sort_keys=True) + "\n" for row in self._journal()
                )
                .encode("utf-8")
                .replace(b"session-control-l2", b"session-control-l\xbb2")
            )
            metrics = load_control_metrics(transcript, observation)
            # Bind evidence over the raw bytes while the fixtures still exist.
            transcript_digest = hashlib.sha256(transcript.read_bytes()).hexdigest()
            observation_digest = hashlib.sha256(observation.read_bytes()).hexdigest()
        self.assertEqual(metrics["schema_version"], CONTROL_METRICS_SCHEMA)
        self.assertEqual(metrics["source"]["observation_journal_records"], 2)
        self.assertEqual(metrics["tool_runtime"]["transcript_tool_calls"], 1)
        self.assertEqual(metrics["tool_runtime"]["transcript_tool_results"], 1)
        self.assertEqual(metrics["source"]["transcript_sha256"], transcript_digest)
        self.assertEqual(
            metrics["source"]["observation_journal_sha256"], observation_digest
        )

    def test_truncated_output_stream_raises_the_no_result_sentinel_the_adapter_keys_on(self):
        # A killed/timed-out agent (harbor SIGTERM -> exit 143, OOM) is torn
        # down before it emits its single terminal `result` event, so
        # load_trace_ir -> final_result raises. The adapter's
        # populate_context_post_run tolerates *exactly* this case by substring
        # matching the message, so the "result event, found 0" wording is a
        # contract: if it drifts, the adapter re-raises and one killed trial
        # again cancels every sibling in the harbor TaskGroup.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "metacodes-output.jsonl"
            transcript = root / "metacodes-transcript.jsonl"
            # Realistic truncation: live stream events, no terminal result.
            self._write_jsonl(
                output,
                [
                    {"type": "turn_begin", "turn": 1},
                    {"type": "text", "text": "starting"},
                ],
            )
            self._write_jsonl(
                transcript,
                [{"role": "user", "blocks": [{"type": "text", "text": "task"}]}],
            )
            with self.assertRaises(TraceError) as caught:
                load_trace_ir(output, transcript)
        self.assertIn("result event, found 0", str(caught.exception))

    def test_control_metrics_accept_complete_no_tool_run_and_bind_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(
                transcript,
                [{"role": "user", "blocks": [{"type": "text", "text": "task"}]}],
            )
            self._write_jsonl(observation, self._journal())
            metrics = load_control_metrics(transcript, observation)
        self.assertEqual(metrics["schema_version"], CONTROL_METRICS_SCHEMA)
        self.assertFalse(metrics["lean"]["used"])
        self.assertFalse(metrics["tinykg"]["used"])
        self.assertEqual(metrics["tool_runtime"]["dispatch_started"], 0)
        self.assertEqual(metrics["source"]["observation_journal_records"], 2)
        self.assertEqual(
            metrics["privacy"],
            {
                "tool_arguments_retained": False,
                "tool_results_retained": False,
                "memory_text_retained": False,
            },
        )

    def test_progress_analysis_derives_green_checkpoint_without_retaining_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            calls = [
                ("w", "Write", {"file_path": "/secret/project/a.py", "content": "secret"}, "ok"),
                (
                    "t",
                    "Bash",
                    json.dumps({"command": "cd /workspace && python -m pytest -q"}),
                    json.dumps({"stdout": "secret test output", "stderr": "", "exit_code": 0}),
                ),
                ("e", "Edit", {"file_path": "/secret/project/a.py"}, "ok"),
            ]
            rows = []
            for call_id, name, arguments, result in calls:
                rows.extend(
                    [
                        {
                            "role": "assistant",
                            "blocks": [
                                {
                                    "type": "tool_use",
                                    "id": call_id,
                                    "name": name,
                                    "input": arguments,
                                }
                            ],
                        },
                        {
                            "role": "user",
                            "blocks": [
                                {
                                    "type": "tool_result",
                                    "tool_use_id": call_id,
                                    "content": result,
                                    "is_error": False,
                                }
                            ],
                        },
                    ]
                )
            self._write_jsonl(transcript, rows)
            effect = {
                "file_mutation_v2": {
                    "mutation": {"change": "changed"},
                    "reobservation": {"state": "matched"},
                }
            }
            events = []
            for index, (call_id, name, _arguments, _result) in enumerate(calls):
                events.append(
                    {
                        "tool_observation": {
                            "dispatch_finished": {
                                "id": call_id,
                                "requested_name": name,
                                "dispatched_name": name,
                                "origin": "authoritative",
                                "agent_depth": 0,
                                "outcome": "succeeded",
                                "effect": effect if name in {"Write", "Edit"} else None,
                                "effect_valid": True,
                            }
                        }
                    }
                )
            journal = self._journal(*events)
            for index, row in enumerate(journal):
                row["monotonic_elapsed_ns"] = index * 1_000_000_000
            self._write_jsonl(observation, journal)
            metrics = analyze_progress(transcript, observation)
        self.assertEqual(metrics["progress"]["first_mutation_call"], 1)
        self.assertEqual(metrics["progress"]["first_successful_verification_call"], 2)
        self.assertEqual(metrics["progress"]["calls_after_first_successful_verification"], 1)
        self.assertEqual(metrics["progress"]["mutations_after_first_successful_verification"], 1)
        encoded = json.dumps(metrics, sort_keys=True)
        self.assertNotIn("secret", encoded)
        self.assertFalse(metrics["privacy"]["tool_arguments_retained"])

    def test_progress_analysis_rejects_transcript_observation_identity_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(
                transcript,
                [
                    {"role": "assistant", "blocks": [{
                        "type": "tool_use", "id": "call", "name": "Bash",
                        "input": {"command": "pytest -q"},
                    }]},
                    {"role": "user", "blocks": [{
                        "type": "tool_result", "tool_use_id": "call",
                        "content": "{\"exit_code\":0}", "is_error": False,
                    }]},
                ],
            )
            self._write_jsonl(observation, self._journal())
            with self.assertRaises(TraceError):
                analyze_progress(transcript, observation)

    def _blocked_call_transcript_rows(self, call_id):
        return [
            {"role": "assistant", "blocks": [{
                "type": "tool_use", "id": call_id, "name": "Write",
                "input": {"file_path": "/workspace/out.json", "content": "x"},
            }]},
            {"role": "user", "blocks": [{
                "type": "tool_result", "tool_use_id": call_id,
                "content": "{\"error\":{\"code\":\"project_rule_blocked\"}}",
                "is_error": True,
            }]},
        ]

    def _formal_block_event(self, call_id, *, actuation="enforced", phase="pre"):
        return {
            "tool_observation": {
                "formal_decision_batch": {
                    "dispatch_id": call_id,
                    "phase": phase,
                    "actuation": actuation,
                    "decisions": [{"operation": "pre_decision", "result": "block"}],
                }
            }
        }

    def test_progress_analysis_accepts_enforced_pre_blocked_call_without_dispatch(self):
        # A pre-dispatch enforced formal block consumes the model's tool call
        # without dispatching it: the transcript records the denial while the
        # observation journal has no dispatch rows for that id.  That is the
        # one legitimate identity mismatch, and the blocked call must not be
        # counted as a dispatch in progress metrics.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            rows = self._blocked_call_transcript_rows("call_blocked")
            rows.extend([
                {"role": "assistant", "blocks": [{
                    "type": "tool_use", "id": "call_bash", "name": "Bash",
                    "input": {"command": "ls"},
                }]},
                {"role": "user", "blocks": [{
                    "type": "tool_result", "tool_use_id": "call_bash",
                    "content": "{\"exit_code\":0}", "is_error": False,
                }]},
            ])
            self._write_jsonl(transcript, rows)
            journal = self._journal(
                self._formal_block_event("call_blocked"),
                {"tool_observation": {"dispatch_finished": {
                    "id": "call_bash", "requested_name": "Bash",
                    "dispatched_name": "Bash", "origin": "authoritative",
                    "agent_depth": 0, "outcome": "succeeded",
                    "effect": None, "effect_valid": True,
                }}},
            )
            for index, row in enumerate(journal):
                row["monotonic_elapsed_ns"] = index * 1_000_000_000
            self._write_jsonl(observation, journal)
            metrics = analyze_progress(transcript, observation)
        self.assertEqual(metrics["progress"]["tool_calls"], 1)
        self.assertEqual(metrics["progress"]["mutation_calls"], 0)

    def test_progress_analysis_rejects_shadow_block_as_dispatch_justification(self):
        # Shadow-mode blocks actuate as admit, so the dispatch must exist; a
        # shadow block cannot explain a missing dispatch observation.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(
                transcript, self._blocked_call_transcript_rows("call_blocked")
            )
            journal = self._journal(
                self._formal_block_event("call_blocked", actuation="shadow")
            )
            for index, row in enumerate(journal):
                row["monotonic_elapsed_ns"] = index * 1_000_000_000
            self._write_jsonl(observation, journal)
            with self.assertRaises(TraceError):
                analyze_progress(transcript, observation)

    def test_progress_analysis_rejects_post_phase_block_as_dispatch_justification(self):
        # A post-phase decision happens after a dispatch; it can never explain
        # a missing dispatch observation.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(
                transcript, self._blocked_call_transcript_rows("call_blocked")
            )
            journal = self._journal(
                self._formal_block_event("call_blocked", phase="post")
            )
            for index, row in enumerate(journal):
                row["monotonic_elapsed_ns"] = index * 1_000_000_000
            self._write_jsonl(observation, journal)
            with self.assertRaises(TraceError):
                analyze_progress(transcript, observation)

    def test_progress_analysis_same_turn_mutation_and_green_is_not_causal_progress(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(
                transcript,
                [
                    {
                        "role": "assistant",
                        "blocks": [
                            {"type": "tool_use", "id": "w", "name": "Write", "input": {}},
                            {
                                "type": "tool_use",
                                "id": "t",
                                "name": "Bash",
                                "input": {"command": "pytest -q"},
                            },
                        ],
                    },
                    {
                        "role": "user",
                        "blocks": [
                            {
                                "type": "tool_result",
                                "tool_use_id": "w",
                                "content": "ok",
                                "is_error": False,
                            },
                            {
                                "type": "tool_result",
                                "tool_use_id": "t",
                                "content": json.dumps(
                                    {"stdout": "1 passed", "stderr": "", "exit_code": 0}
                                ),
                                "is_error": False,
                            },
                        ],
                    },
                ],
            )
            effect = {
                "file_mutation_v2": {
                    "mutation": {"change": "changed"},
                    "reobservation": {"state": "matched"},
                }
            }
            self._write_jsonl(
                observation,
                self._journal(
                    {"tool_observation": {"dispatch_finished": {
                        "id": "w", "requested_name": "Write", "dispatched_name": "Write",
                        "origin": "authoritative", "agent_depth": 0, "outcome": "succeeded",
                        "effect": effect, "effect_valid": True,
                    }}},
                    {"tool_observation": {"dispatch_finished": {
                        "id": "t", "requested_name": "Bash", "dispatched_name": "Bash",
                        "origin": "authoritative", "agent_depth": 0, "outcome": "succeeded",
                        "effect": None, "effect_valid": True,
                    }}},
                ),
            )
            metrics = analyze_progress(transcript, observation)
        self.assertEqual(1, metrics["progress"]["successful_verifications"])
        self.assertIsNone(metrics["progress"]["first_successful_verification_call"])

    def test_progress_analysis_excludes_same_green_turn_parallel_tail_from_after_metrics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            calls = [
                ("w1", "Write", {}),
                ("t", "Bash", {"command": "pytest -q"}),
                ("w2", "Write", {}),
            ]
            self._write_jsonl(
                transcript,
                [
                    {"role": "assistant", "blocks": [{
                        "type": "tool_use", "id": "w1", "name": "Write", "input": {},
                    }]},
                    {"role": "user", "blocks": [{
                        "type": "tool_result", "tool_use_id": "w1", "content": "ok",
                        "is_error": False,
                    }]},
                    {"role": "assistant", "blocks": [
                        {"type": "tool_use", "id": call_id, "name": name, "input": args}
                        for call_id, name, args in calls[1:]
                    ]},
                    {"role": "user", "blocks": [
                        {"type": "tool_result", "tool_use_id": "t", "content": json.dumps({
                            "stdout": "1 passed", "stderr": "", "exit_code": 0,
                        }), "is_error": False},
                        {"type": "tool_result", "tool_use_id": "w2", "content": "ok",
                         "is_error": False},
                    ]},
                ],
            )
            effect = {"file_mutation_v2": {
                "mutation": {"change": "changed"},
                "reobservation": {"state": "matched"},
            }}
            self._write_jsonl(
                observation,
                self._journal(*[
                    {"tool_observation": {"dispatch_finished": {
                        "id": call_id, "requested_name": name, "dispatched_name": name,
                        "origin": "authoritative", "agent_depth": 0, "outcome": "succeeded",
                        "effect": effect if name == "Write" else None, "effect_valid": True,
                    }}}
                    for call_id, name, _args in calls
                ]),
            )
            metrics = analyze_progress(transcript, observation)["progress"]
        self.assertEqual(2, metrics["first_successful_verification_call"])
        self.assertEqual(0, metrics["calls_after_first_successful_verification"])
        self.assertEqual(0, metrics["mutations_after_first_successful_verification"])

    def test_progress_analysis_counts_injected_checkpoint_only_in_bound_result_turn(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(
                transcript,
                [
                    {"role": "assistant", "blocks": [{
                        "type": "tool_use", "id": "w", "name": "Write", "input": {},
                    }]},
                    {"role": "user", "blocks": [{
                        "type": "tool_result", "tool_use_id": "w", "content": "ok",
                        "is_error": False,
                    }]},
                    {"role": "assistant", "blocks": [{
                        "type": "tool_use", "id": "t", "name": "Bash",
                        "input": {"command": "pytest -q"},
                    }]},
                    {"role": "user", "blocks": [
                        {"type": "tool_result", "tool_use_id": "t", "content": json.dumps({
                            "stdout": "1 passed", "stderr": "", "exit_code": 0,
                        }), "is_error": False},
                        {"type": "text", "text": "[verification checkpoint]\nfinish"},
                    ]},
                ],
            )
            effect = {"file_mutation_v2": {
                "mutation": {"change": "changed"},
                "reobservation": {"state": "matched"},
            }}
            self._write_jsonl(
                observation,
                self._journal(
                    {"tool_observation": {"dispatch_finished": {
                        "id": "w", "requested_name": "Write", "dispatched_name": "Write",
                        "origin": "authoritative", "agent_depth": 0, "outcome": "succeeded",
                        "effect": effect, "effect_valid": True,
                    }}},
                    {"tool_observation": {"dispatch_finished": {
                        "id": "t", "requested_name": "Bash", "dispatched_name": "Bash",
                        "origin": "authoritative", "agent_depth": 0, "outcome": "succeeded",
                        "effect": None, "effect_valid": True,
                    }}},
                ),
            )
            metrics = analyze_progress(transcript, observation)
        self.assertEqual(1, metrics["progress"]["checkpoint_messages"])
        self.assertEqual(
            1,
            metrics["progress"][
                "checkpoint_messages_after_successful_verification"
            ],
        )

    def test_control_metrics_count_formal_batch_dispatch_and_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(
                transcript,
                [
                    {"role": "assistant", "blocks": [{
                        "type": "tool_use", "id": "call-1", "name": "Read",
                        "input": {"file_path": "README.md"},
                    }]},
                    {"role": "user", "blocks": [{
                        "type": "tool_result", "tool_use_id": "call-1",
                        "content": "ok", "is_error": False,
                    }]},
                ],
            )
            formal = {
                "schema_version": "metacodes-project-formal-decision-batch-v4",
                "phase": "pre",
                "actuation": "enforced",
                "kernel_sha256": "1" * 64,
                "bundle_sha256": "2" * 64,
                "checker_call_sha256": "3" * 64,
                "checker_batch_size": 3,
                "checker_elapsed_ns": 7000,
                "checker_bytes": 4096,
                "decisions": [
                    {"operation": "pre_decision", "result": "admit", "recovery_action": "none"},
                    {"operation": "recovery_pre_decision", "result": "block", "recovery_action": "edit_existing_file_exact"},
                    {"operation": "pre_decision", "result": "fault", "recovery_action": "none"},
                ],
            }
            dispatch_start = {
                "schema_version": TOOL_OBSERVATION_SCHEMA,
                "id": "dispatch-1",
                "requested_name": "Read",
                "dispatched_name": "Read",
                "origin": "authoritative",
                "agent_depth": 0,
            }
            dispatch_finish = {
                **dispatch_start,
                "outcome": "succeeded",
            }
            self._write_jsonl(
                observation,
                self._journal(
                    {"tool_observation": {"formal_decision_batch": formal}},
                    {"tool_observation": {"dispatch_started": dispatch_start}},
                    {"tool_observation": {"dispatch_finished": dispatch_finish}},
                ),
            )
            metrics = load_control_metrics(transcript, observation)
        self.assertEqual(metrics["tool_runtime"]["dispatch_started"], 1)
        self.assertEqual(metrics["tool_runtime"]["dispatch_outcomes"]["succeeded"], 1)
        self.assertTrue(metrics["lean"]["used"])
        self.assertEqual(metrics["lean"]["checker_calls"], 1)
        self.assertEqual(metrics["lean"]["admit"], 1)
        self.assertEqual(metrics["lean"]["block"], 1)
        self.assertEqual(metrics["lean"]["fault"], 1)
        self.assertEqual(metrics["lean"]["enforced_blocks"], 1)
        self.assertEqual(metrics["lean"]["recovery_directions"], 1)
        self.assertEqual(metrics["lean"]["checker_elapsed_ns"], 7000)

    def test_control_metrics_count_zero_checker_rule_filters(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(transcript, [{"role": "user", "blocks": []}])
            identity = {
                "schema_version": "metacodes-project-rule-filter-v1",
                "operation": "ordinary",
                "project_sha256": "1" * 64,
                "bundle_sha256": "2" * 64,
                "bundle_revision": 7,
                "kernel_sha256": "3" * 64,
                "active_rule_count": 2,
                "checker_rule_count": 0,
                "statically_pruned_rule_count": 2,
                "proof": sorted(RULE_FILTER_PROOFS)[0],
            }
            start = {
                "schema_version": TOOL_OBSERVATION_SCHEMA,
                "id": "filtered-read",
                "requested_name": "Read",
                "dispatched_name": "Read",
                "origin": "authoritative",
                "agent_depth": 0,
            }
            self._write_jsonl(
                observation,
                self._journal(
                    {"tool_observation": {"rule_filter": {
                        **identity, "dispatch_id": "filtered-read", "phase": "pre",
                    }}},
                    {"tool_observation": {"dispatch_started": start}},
                    {"tool_observation": {"rule_filter": {
                        **identity, "dispatch_id": "filtered-read", "phase": "post",
                    }}},
                    {"tool_observation": {"dispatch_finished": {
                        **start, "outcome": "succeeded",
                    }}},
                ),
            )
            metrics = load_control_metrics(transcript, observation)
        self.assertTrue(metrics["lean"]["used"])
        self.assertEqual(metrics["lean"]["checker_calls"], 0)
        self.assertEqual(metrics["lean"]["rule_filter_events"], 2)
        self.assertEqual(metrics["lean"]["active_rule_phases"], 4)
        self.assertEqual(metrics["lean"]["checker_rule_phases"], 0)
        self.assertEqual(metrics["lean"]["statically_pruned_rule_phases"], 4)

    def test_current_batch_schema_matches_zig_emitter(self):
        # The strict filter-binding invariant only consumes batches whose
        # schema equals CURRENT_FORMAL_BATCH_SCHEMA, so a binary emitting a
        # newer version than this constant turns every checker-backed rule
        # filter into a fatal "bypassed its formal batch" TraceError at
        # runtime while every fixture-driven test stays green.  Pin the
        # constant to the schema the Zig emitter actually ships.
        zig = (
            Path(__file__).resolve().parents[3] / "src" / "tools" / "observation.zig"
        ).read_text(encoding="utf-8")
        emitted = None
        for line in zig.splitlines():
            if line.startswith("pub const FORMAL_BATCH_SCHEMA_VERSION ="):
                emitted = line.split('"')[1]
        self.assertEqual(CURRENT_FORMAL_BATCH_SCHEMA, emitted)
        self.assertIn(CURRENT_FORMAL_BATCH_SCHEMA, FILTER_BINDING_BATCH_SCHEMAS)

    def test_every_current_zig_schema_constant_is_known_to_the_auditor(self):
        # Table-driven generalization of the pin above (harness review
        # 2026-08-17: 16 emitter constants had no lockstep guard, so any
        # version bump only surfaced inside a paid run). Every CURRENT
        # emitter schema constant — the unversioned names; the _V<n>
        # suffixed ones are explicitly-historical roster entries — must
        # appear verbatim in trace.py, as a constant or roster literal.
        root = Path(__file__).resolve().parents[3]
        pattern = re.compile(r'pub const ([A-Z0-9_]+) = "(metacodes[^"]+)";')
        # Keyed by (file, name): both sources define a bare SCHEMA_VERSION
        # with different values, and a name-keyed dict silently drops one
        # of them — the exact vacuous-guard failure this test exists to
        # prevent.
        constants: dict[tuple[str, str], str] = {}
        for source in (
            root / "src" / "tools" / "observation.zig",
            root / "src" / "core" / "tool_observation_journal.zig",
        ):
            for name, value in pattern.findall(source.read_text(encoding="utf-8")):
                if re.search(r"_V\d+$", name):
                    continue
                constants[(source.name, name)] = value
        # Floor guards against the regex silently matching nothing, and the
        # journal schema must have survived alongside observation's twin.
        self.assertGreaterEqual(len(constants), 9, constants)
        self.assertIn(
            ("tool_observation_journal.zig", "SCHEMA_VERSION"), constants
        )
        self.assertIn(("observation.zig", "SCHEMA_VERSION"), constants)
        trace_source = (
            root / "scripts" / "eval" / "workbuddy" / "trace.py"
        ).read_text(encoding="utf-8")
        missing = {
            key: value
            for key, value in constants.items()
            if value not in trace_source
        }
        self.assertEqual(missing, {})

    def test_current_journal_validates_provider_attempt_pairs(self):
        attempt_id = _provider_attempt_id("1" * 24, "b" * 64, 1, 0, 1)
        started = {
            "schema_version": EXECUTION_EFFECT_SCHEMA,
            "attempt_id": attempt_id,
            "actor_id": "1" * 24,
            "request_sha256": "b" * 64,
            "logical_turn": 1,
            "context_generation": 0,
            "physical_attempt": 1,
            "max_attempts": 1,
        }
        finished = {
            "schema_version": EXECUTION_EFFECT_SCHEMA,
            "attempt_id": attempt_id,
            "outcome": "succeeded",
            "metering": {
                "known": {
                    "input_tokens": 2,
                    "output_tokens": 1,
                    "cache_read_input_tokens": 0,
                    "cache_creation_input_tokens": 0,
                }
            },
        }
        events = [
            {"run_started": {}},
            {"provider_attempt": {"started": started}},
            {"provider_attempt": {"finished": finished}},
            {"run_finished": {}},
        ]
        rows = [
            {
                "schema_version": CURRENT_OBSERVATION_JOURNAL_SCHEMA,
                "sequence": sequence,
                "monotonic_elapsed_ns": sequence,
                "session_id": "1" * 24,
                "run_id": "2" * 24,
                "event": event,
            }
            for sequence, event in enumerate(events)
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            transcript.write_text("", encoding="utf-8")
            self._write_jsonl(observation, rows)
            metrics = load_control_metrics(transcript, observation)
            self.assertEqual(metrics["source"]["observation_journal_records"], 4)
            self.assertEqual(metrics["tool_runtime"]["dispatch_started"], 0)
            self._write_jsonl(observation, [rows[0], rows[1], rows[3]])
            with self.assertRaises(TraceError):
                load_control_metrics(transcript, observation)

            forged_rows = json.loads(json.dumps(rows))
            forged_rows[1]["event"]["provider_attempt"]["started"]["attempt_id"] = "a" * 64
            forged_rows[2]["event"]["provider_attempt"]["finished"]["attempt_id"] = "a" * 64
            self._write_jsonl(observation, forged_rows)
            with self.assertRaises(TraceError):
                load_control_metrics(transcript, observation)

            legacy_rows = json.loads(json.dumps(rows))
            for row in legacy_rows:
                row["schema_version"] = OBSERVATION_JOURNAL_SCHEMA
            self._write_jsonl(observation, legacy_rows)
            with self.assertRaises(TraceError):
                load_control_metrics(transcript, observation)

    def test_zig_rule_filter_proof_literal_is_in_the_python_roster(self):
        zig = (
            Path(__file__).resolve().parents[3] / "src" / "tools" / "observation.zig"
        ).read_text(encoding="utf-8")
        proofs = set(re.findall(r'"(MetaCodesControl\.[A-Za-z0-9_.]+)"', zig))
        self.assertGreaterEqual(len(proofs), 1)
        for proof in proofs:
            self.assertIn(proof, RULE_FILTER_PROOFS)

    def test_every_zig_effect_union_tag_is_handled_by_progress_analysis(self):
        zig = (
            Path(__file__).resolve().parents[3] / "src" / "tools" / "observation.zig"
        ).read_text(encoding="utf-8")
        match = re.search(
            r"pub const Effect = union\(enum\) \{\n(.*?)\n\};", zig, re.S
        )
        self.assertIsNotNone(match)
        tags = re.findall(r"^\s+(\w+):", match.group(1), re.M)
        self.assertGreaterEqual(len(tags), 2, tags)
        analysis_source = (
            Path(__file__).resolve().parents[3]
            / "scripts" / "eval" / "workbuddy" / "progress_analysis.py"
        ).read_text(encoding="utf-8")
        for tag in tags:
            self.assertIn(f'"{tag}"', analysis_source)

    @staticmethod
    def _checker_backed_filter_events(*, include_batch: bool):
        identity = {
            "project_sha256": "1" * 64,
            "bundle_sha256": "2" * 64,
            "bundle_revision": 1,
            "kernel_sha256": "3" * 64,
        }
        def rule_filter(phase):
            return {
                "schema_version": "metacodes-project-rule-filter-v1",
                "dispatch_id": "checker-read",
                "phase": phase,
                "operation": "ordinary",
                **identity,
                "active_rule_count": 1,
                "checker_rule_count": 1,
                "statically_pruned_rule_count": 0,
                "proof": sorted(RULE_FILTER_PROOFS)[0],
            }

        def batch(phase, call_sha):
            return {
                "schema_version": CURRENT_FORMAL_BATCH_SCHEMA,
                "dispatch_id": "checker-read",
                "phase": phase,
                "actuation": "enforced",
                **identity,
                "checker_call_sha256": call_sha,
                "checker_batch_size": 1,
                "checker_elapsed_ns": 7000,
                "checker_bytes": 4096,
                "decisions": [
                    {
                        "operation": f"{phase}_decision",
                        "result": "admit",
                        "recovery_action": "none",
                    },
                ],
            }

        start = {
            "schema_version": TOOL_OBSERVATION_SCHEMA,
            "id": "checker-read",
            "requested_name": "Read",
            "dispatched_name": "Read",
            "origin": "authoritative",
            "agent_depth": 0,
        }
        events = [{"tool_observation": {"rule_filter": rule_filter("pre")}}]
        if include_batch:
            events.append(
                {"tool_observation": {"formal_decision_batch": batch("pre", "4" * 64)}}
            )
        events.append({"tool_observation": {"dispatch_started": start}})
        events.append({"tool_observation": {"rule_filter": rule_filter("post")}})
        if include_batch:
            events.append(
                {"tool_observation": {"formal_decision_batch": batch("post", "5" * 64)}}
            )
        events.append(
            {"tool_observation": {"dispatch_finished": {**start, "outcome": "succeeded"}}}
        )
        return events

    def test_control_metrics_bind_checker_backed_filter_to_current_batch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(transcript, [{"role": "user", "blocks": []}])
            self._write_jsonl(
                observation,
                self._journal(*self._checker_backed_filter_events(include_batch=True)),
            )
            metrics = load_control_metrics(transcript, observation)
        self.assertTrue(metrics["lean"]["used"])
        self.assertEqual(metrics["lean"]["checker_calls"], 2)
        self.assertEqual(metrics["lean"]["admit"], 2)
        self.assertEqual(metrics["lean"]["checker_rule_phases"], 2)

    def test_control_metrics_reject_checker_backed_filter_without_batch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(transcript, [{"role": "user", "blocks": []}])
            self._write_jsonl(
                observation,
                self._journal(*self._checker_backed_filter_events(include_batch=False)),
            )
            with self.assertRaises(TraceError) as caught:
                load_control_metrics(transcript, observation)
        self.assertIn("bypassed its formal batch", str(caught.exception))

    def test_weakening_candidate_counted_and_schema_pinned(self):
        # PO-V2 M2 observe-only signal: counters split plain vs hot
        # (assert tokens touched while the latest verification had failed);
        # unknown schema versions fail closed like every journal kind.
        def candidate(assert_tokens, last_failed, schema="metacodes-test-weakening-candidate-v1"):
            return {"tool_observation": {"test_weakening_candidate": {
                "schema_version": schema,
                "dispatch_id": "d-1",
                "path_sha256": "a" * 64,
                "tool": "Write",
                "assert_tokens_touched": assert_tokens,
                "last_verification_failed": last_failed,
            }}}

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(transcript, [{"role": "user", "blocks": []}])
            self._write_jsonl(
                observation,
                self._journal(
                    candidate(True, True),
                    candidate(True, False),
                    candidate(False, True),
                ),
            )
            metrics = load_control_metrics(transcript, observation)
        self.assertEqual(metrics["lean"]["test_weakening_candidates"], 3)
        self.assertEqual(metrics["lean"]["test_weakening_hot_candidates"], 1)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(transcript, [{"role": "user", "blocks": []}])
            self._write_jsonl(
                observation,
                self._journal(candidate(True, True, schema="metacodes-test-weakening-candidate-v2")),
            )
            with self.assertRaisesRegex(TraceError, "weakening candidate"):
                load_control_metrics(transcript, observation)

    def test_control_metrics_count_tinykg_routing_trust_and_task_commit(self):
        calls = [
            ("recall-hit", "KgRecall", {
                "count": 2,
                "hits": [
                    {"node_id": 1, "seen_before": False},
                    {"node_id": 2, "seen_before": True},
                ],
                "lexical_query_plan": {
                    "schema_version": "lexical-query-plan-v3",
                    "plan_sha256": "4" * 64,
                    "intent": "fact_lookup",
                    "stage": "seed",
                    "variant_count": 1,
                    "seen_state_verified": True,
                    "ledger_scope": "agent_run_batch",
                    "execution": "host_batch_all",
                    "all_variants_executed": True,
                    "executed_variant_count": 1,
                    "merged_hit_count": 2,
                    "merged_new_hit_count": 1,
                    "merged_previously_seen_count": 1,
                    "probe_new_hit_count": 1,
                    "probe_repeated_hit_count": 1,
                    "variant_receipts": [{
                        "variant_index": 0,
                        "variant_kind": "exact",
                        "node_ids": [1, 2],
                        "new_hit_count": 1,
                        "repeated_hit_count": 1,
                    }],
                },
            }),
            ("recall-miss", "KgRecall", {"count": 0, "hits": []}),
            ("context", "KgContext", {"knowledge_governance": {
                "schema_version": "metacodes-knowledge-governance-v1",
                "trust_state": "evidence_connected_candidate",
            }}),
            ("remember", "KgRemember", {"remembered": {"node_id": 9}}),
            ("task-create", "TaskCreate", {"task": {"id": "kg-10"}}),
            ("task-list", "TaskList", [
                {
                    "id": "kg-10", "subject": "Persist result", "status": "pending",
                    "kg_status": "open", "readiness": "ready", "plan_step": True,
                },
                {"parallel_hint": "2 ready tasks can run in parallel"},
            ]),
            ("task-claim", "TaskUpdate", {
                "claimed": True, "claimed_by": "agent-l2"
            }),
            ("task-complete", "TaskUpdate", {"closed": True}),
        ]
        transcript_rows = [
            {"role": "assistant", "blocks": [
                {
                    "type": "tool_use",
                    "id": call_id,
                    "name": name,
                    "input": (
                        {
                            "query": "control memory",
                            "lexical_plan": {
                                "schema_version": "lexical-query-plan-v3",
                                "intent": "fact_lookup",
                                "stage": "seed",
                                "variants": [
                                    {"kind": "exact", "text": "control memory"}
                                ],
                            },
                        }
                        if call_id == "recall-hit"
                        else {}
                    ),
                }
                for call_id, name, _ in calls
            ]},
            {"role": "user", "blocks": [
                {"type": "tool_result", "tool_use_id": call_id,
                 "content": json.dumps(result), "is_error": False}
                for call_id, _, result in calls
            ]},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(transcript, transcript_rows)
            self._write_jsonl(observation, self._journal())
            metrics = load_control_metrics(transcript, observation)
        tinykg = metrics["tinykg"]
        self.assertTrue(tinykg["used"])
        self.assertEqual(tinykg["recall_hit_calls"], 1)
        self.assertEqual(tinykg["recall_miss_calls"], 1)
        self.assertEqual(tinykg["recall_new_nodes"], 1)
        self.assertEqual(tinykg["recall_repeated_nodes"], 1)
        self.assertEqual(tinykg["auto_context_succeeded"], 0)
        self.assertEqual(tinykg["context_observations"], 1)
        self.assertEqual(tinykg["context_evidence_connected"], 1)
        self.assertEqual(tinykg["remember_succeeded"], 1)
        self.assertEqual(tinykg["task_dag_calls"], 4)
        self.assertEqual(tinykg["task_list_calls"], 1)
        self.assertEqual(tinykg["task_tinykg_status_results"], 4)
        self.assertEqual(tinykg["task_terminal_commits"], 1)

    def test_control_metrics_accept_serialized_tool_use_input(self):
        # The metacodes transcript stores tool_use input as the raw JSON string;
        # batch coverage checks must see the parsed arguments, not the encoding.
        payload = {
            "count": 0,
            "hits": [],
            "lexical_query_plan": {
                "schema_version": "lexical-query-plan-v3",
                "plan_sha256": "5" * 64,
                "intent": "task_recovery",
                "stage": "seed",
                "variant_count": 1,
                "seen_state_verified": True,
                "ledger_scope": "agent_run_batch",
                "execution": "host_batch_all",
                "all_variants_executed": True,
                "executed_variant_count": 1,
                "merged_hit_count": 0,
                "merged_new_hit_count": 0,
                "merged_previously_seen_count": 0,
                "probe_new_hit_count": 0,
                "probe_repeated_hit_count": 0,
                "variant_receipts": [{
                    "variant_index": 0,
                    "variant_kind": "exact",
                    "node_ids": [],
                    "new_hit_count": 0,
                    "repeated_hit_count": 0,
                }],
            },
        }
        tool_input = {
            "query": "header passthrough",
            "lexical_plan": {
                "schema_version": "lexical-query-plan-v3",
                "intent": "task_recovery",
                "stage": "seed",
                "variants": [{"kind": "exact", "text": "header passthrough"}],
            },
        }
        transcript_rows = [
            {"role": "assistant", "blocks": [{
                "type": "tool_use",
                "id": "recall-serialized",
                "name": "KgRecall",
                "input": json.dumps(tool_input),
            }]},
            {"role": "user", "blocks": [{
                "type": "tool_result",
                "tool_use_id": "recall-serialized",
                "content": json.dumps(payload),
                "is_error": False,
            }]},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(transcript, transcript_rows)
            self._write_jsonl(observation, self._journal())
            metrics = load_control_metrics(transcript, observation)
        tinykg = metrics["tinykg"]
        self.assertEqual(tinykg["recall_calls"], 1)
        self.assertEqual(tinykg["recall_succeeded"], 1)
        self.assertEqual(tinykg["recall_miss_calls"], 1)
        self.assertEqual(tinykg["recall_governed_calls"], 1)

    def _rewrite_recall_rows(self, *, all_executed=False, with_auto_context=False):
        # Shape mirrors src/tools/kg_tools.zig appendSeedShapeRewriteReceipt:
        # the host executed only the seed anchor and left every declared
        # semantic variant explicitly unexecuted, with a proof-carrying
        # rewrite object binding input and effective plans.
        payload = {
            "count": 1,
            "hits": [{"node_id": 7, "seen_before": False}],
            "lexical_query_plan": {
                "schema_version": "lexical-query-plan-v3",
                "plan_sha256": "6" * 64,
                "intent": "enumeration",
                "stage": "semantic_expansion",
                "variant_count": 3,
                "executed_variant_count": 1,
                "all_variants_executed": all_executed,
                "seen_node_count": 0,
                "seen_state_verified": True,
                "ledger_scope": "agent_run_batch",
                "merged_hit_count": 1,
                "merged_new_hit_count": 1,
                "merged_previously_seen_count": 0,
                "probe_new_hit_count": 1,
                "probe_repeated_hit_count": 0,
                "variant_receipts": [{
                    "variant_index": 0,
                    "variant_kind": "exact",
                    "node_ids": [7],
                    "new_hit_count": 1,
                    "repeated_hit_count": 0,
                }],
                "execution": "host_seed_shape_rewrite",
                "rewrite": {
                    "schema_version": "metacodes-seed-shape-rewrite-v1",
                    "reason": "seed_prefixed_semantic_expansion",
                    "input_plan_sha256": "7" * 64,
                    "effective_plan_sha256": "6" * 64,
                    "effective_seed_sha256": "8" * 64,
                    "input_stage": "semantic_expansion",
                    "effective_stage": "seed",
                    "declared_variant_count": 3,
                    "executed_variant_count": 1,
                    "unexecuted_semantic_variant_count": 2,
                },
            },
        }
        if with_auto_context:
            payload["auto_context"] = {"schema_version": "metacodes-auto-context-v1"}
        tool_input = {
            "query": "rollback ledger",
            "lexical_plan": {
                "schema_version": "lexical-query-plan-v3",
                "intent": "enumeration",
                "stage": "semantic_expansion",
                "variants": [
                    {"kind": "exact", "text": "rollback ledger"},
                    {"kind": "synonym", "text": "undo journal"},
                    {"kind": "mechanism", "text": "compensating transaction"},
                ],
            },
        }
        return [
            {"role": "assistant", "blocks": [{
                "type": "tool_use", "id": "recall-rewrite", "name": "KgRecall",
                "input": json.dumps(tool_input),
            }]},
            {"role": "user", "blocks": [{
                "type": "tool_result", "tool_use_id": "recall-rewrite",
                "content": json.dumps(payload), "is_error": False,
            }]},
        ]

    def test_control_metrics_accept_seed_shape_rewrite_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(transcript, self._rewrite_recall_rows())
            self._write_jsonl(observation, self._journal())
            metrics = load_control_metrics(transcript, observation)
        tinykg = metrics["tinykg"]
        self.assertEqual(tinykg["recall_governed_calls"], 1)
        self.assertEqual(tinykg["recall_new_nodes"], 1)
        self.assertEqual(tinykg["auto_context_succeeded"], 0)

    def test_control_metrics_reject_rewrite_claiming_full_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(
                transcript, self._rewrite_recall_rows(all_executed=True)
            )
            self._write_jsonl(observation, self._journal())
            with self.assertRaisesRegex(TraceError, "batch coverage"):
                load_control_metrics(transcript, observation)

    def test_control_metrics_reject_rewrite_smuggling_auto_context(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(
                transcript, self._rewrite_recall_rows(with_auto_context=True)
            )
            self._write_jsonl(observation, self._journal())
            with self.assertRaisesRegex(TraceError, "batch coverage"):
                load_control_metrics(transcript, observation)

    def test_control_metrics_accept_historical_rule_filter_proof(self):
        self.assertIn(
            "MetaCodesControl.ProjectRule.target_tool_mismatch_admits_both",
            RULE_FILTER_PROOFS,
        )
        self.assertIn(
            "MetaCodesControl.ProjectRule.target_mismatch_admits_both",
            RULE_FILTER_PROOFS,
        )

    def test_task_list_tolerates_empty_subject(self):
        rows = [
            {"role": "assistant", "blocks": [{
                "type": "tool_use", "id": "list-1", "name": "TaskList",
                "input": "{}",
            }]},
            {"role": "user", "blocks": [{
                "type": "tool_result", "tool_use_id": "list-1",
                "content": json.dumps([
                    {"id": "kg-9", "subject": "", "status": "pending",
                     "kg_status": "open"},
                ]),
                "is_error": False,
            }]},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(transcript, rows)
            self._write_jsonl(observation, self._journal())
            metrics = load_control_metrics(transcript, observation)
        self.assertEqual(metrics["tinykg"]["task_tinykg_status_results"], 1)

    def test_control_metrics_count_bound_auto_context_as_real_observation(self):
        tool_input = {
            "query": "commencement attendance",
            "lexical_plan": {
                "schema_version": "lexical-query-plan-v3",
                "intent": "enumeration",
                "stage": "semantic_expansion",
                "variants": [
                    {"kind": "synonym", "text": "commencement attendance"},
                    {"kind": "relation", "text": "graduation ceremonies attended"},
                ],
            },
        }
        payload = {
            "count": 1,
            "hits": [{
                "node_id": 7,
                "type": "evidence",
                "seen_before": False,
                "text": "attended commencement",
            }],
            "lexical_query_plan": {
                "schema_version": "lexical-query-plan-v3",
                "plan_sha256": "4" * 64,
                "intent": "enumeration",
                "stage": "semantic_expansion",
                "variant_count": 2,
                "executed_variant_count": 2,
                "all_variants_executed": True,
                "seen_state_verified": True,
                "ledger_scope": "agent_run_batch",
                "execution": "host_batch_all",
                "merged_hit_count": 1,
                "merged_new_hit_count": 1,
                "merged_previously_seen_count": 0,
                "probe_new_hit_count": 1,
                "probe_repeated_hit_count": 1,
                "variant_receipts": [
                    {
                        "variant_index": 0,
                        "variant_kind": "synonym",
                        "node_ids": [7],
                        "new_hit_count": 1,
                        "repeated_hit_count": 0,
                    },
                    {
                        "variant_index": 1,
                        "variant_kind": "relation",
                        "node_ids": [7],
                        "new_hit_count": 0,
                        "repeated_hit_count": 1,
                    },
                ],
            },
            "auto_context": {
                "schema_version": "metacodes-auto-context-v1",
                "selection_policy": "first_new_evidence_then_new_then_merged_v1",
                "context": {
                    "node_id": 7,
                    "graph": {"query": {"root_id": 7}},
                    "knowledge_governance": {
                        "schema_version": "metacodes-knowledge-governance-v1",
                        "trust_state": "evidence_connected_candidate",
                    },
                },
            },
        }
        rows = [
            {"role": "assistant", "blocks": [{
                "type": "tool_use", "id": "recall", "name": "KgRecall",
                "input": tool_input,
            }]},
            {"role": "user", "blocks": [{
                "type": "tool_result", "tool_use_id": "recall",
                "content": json.dumps(payload), "is_error": False,
            }]},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(transcript, rows)
            self._write_jsonl(observation, self._journal())
            tinykg = load_control_metrics(transcript, observation)["tinykg"]
        self.assertEqual(tinykg["context_calls"], 0)
        self.assertEqual(tinykg["context_succeeded"], 0)
        self.assertEqual(tinykg["auto_context_succeeded"], 1)
        self.assertEqual(tinykg["context_observations"], 1)
        self.assertEqual(tinykg["context_evidence_connected"], 1)

    def test_control_metrics_reject_v3_variant_receipt_unbound_to_input_or_hits(self):
        tool_input = {
            "query": "control memory",
            "lexical_plan": {
                "schema_version": "lexical-query-plan-v3",
                "intent": "fact_lookup",
                "stage": "seed",
                "variants": [{"kind": "exact", "text": "control memory"}],
            },
        }
        payload = {
            "count": 1,
            "hits": [{"node_id": 1, "seen_before": False}],
            "lexical_query_plan": {
                "schema_version": "lexical-query-plan-v3",
                "plan_sha256": "4" * 64,
                "intent": "fact_lookup",
                "stage": "seed",
                "variant_count": 1,
                "executed_variant_count": 1,
                "all_variants_executed": True,
                "seen_state_verified": True,
                "ledger_scope": "agent_run_batch",
                "execution": "host_batch_all",
                "merged_hit_count": 1,
                "merged_new_hit_count": 1,
                "merged_previously_seen_count": 0,
                "probe_new_hit_count": 1,
                "probe_repeated_hit_count": 0,
                "variant_receipts": [{
                    "variant_index": 0,
                    "variant_kind": "exact",
                    "node_ids": [2],
                    "new_hit_count": 1,
                    "repeated_hit_count": 0,
                }],
            },
        }
        rows = [
            {"role": "assistant", "blocks": [{
                "type": "tool_use", "id": "recall", "name": "KgRecall", "input": tool_input,
            }]},
            {"role": "user", "blocks": [{
                "type": "tool_result", "tool_use_id": "recall",
                "content": json.dumps(payload), "is_error": False,
            }]},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(transcript, rows)
            self._write_jsonl(observation, self._journal())
            with self.assertRaisesRegex(TraceError, "unmerged node"):
                load_control_metrics(transcript, observation)

    def test_control_metrics_reject_malformed_task_list_array(self):
        cases = (
            {"tasks": []},
            ["not-an-object"],
            [{"parallel_hint": ""}],
            [{"id": "kg-1", "subject": "Task", "status": "pending",
              "kg_status": "unknown"}],
        )
        for payload in cases:
            transcript_rows = [
                {"role": "assistant", "blocks": [{
                    "type": "tool_use", "id": "list", "name": "TaskList", "input": {}
                }]},
                {"role": "user", "blocks": [{
                    "type": "tool_result", "tool_use_id": "list",
                    "content": json.dumps(payload), "is_error": False,
                }]},
            ]
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                transcript = root / "transcript.jsonl"
                observation = root / "tool-observations.jsonl"
                self._write_jsonl(transcript, transcript_rows)
                self._write_jsonl(observation, self._journal())
                with self.assertRaises(TraceError):
                    load_control_metrics(transcript, observation)

    def test_control_metrics_accept_empty_and_local_task_lists_without_kg_evidence(self):
        calls = (
            ("empty", []),
            ("local", [{
                "id": "1", "subject": "Session task", "status": "in_progress",
                "blockedBy": [],
            }]),
        )
        transcript_rows = [
            {"role": "assistant", "blocks": [
                {"type": "tool_use", "id": call_id, "name": "TaskList", "input": {}}
                for call_id, _ in calls
            ]},
            {"role": "user", "blocks": [
                {"type": "tool_result", "tool_use_id": call_id,
                 "content": json.dumps(payload), "is_error": False}
                for call_id, payload in calls
            ]},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "tool-observations.jsonl"
            self._write_jsonl(transcript, transcript_rows)
            self._write_jsonl(observation, self._journal())
            metrics = load_control_metrics(transcript, observation)
        self.assertEqual(metrics["tinykg"]["task_list_calls"], 2)
        self.assertEqual(metrics["tinykg"]["task_tinykg_status_results"], 0)

    def test_control_metrics_reject_sequence_identity_pairing_and_recall_drift(self):
        cases = []
        sequence_gap = self._journal()
        sequence_gap[1]["sequence"] = 2
        cases.append(("sequence", sequence_gap, [{"role": "user", "blocks": []}]))
        identity_drift = self._journal()
        identity_drift[1]["run_id"] = "different-run"
        cases.append(("identity", identity_drift, [{"role": "user", "blocks": []}]))
        unpaired = self._journal({"tool_observation": {"dispatch_started": {
            "schema_version": TOOL_OBSERVATION_SCHEMA,
            "id": "dispatch-1", "requested_name": "Read", "dispatched_name": "Read",
            "origin": "authoritative", "agent_depth": 0,
        }}})
        cases.append(("dispatch", unpaired, [{"role": "user", "blocks": []}]))
        malformed_recall = [
            {"role": "assistant", "blocks": [{"type": "tool_use", "id": "r", "name": "KgRecall", "input": {}}]},
            {"role": "user", "blocks": [{"type": "tool_result", "tool_use_id": "r", "content": json.dumps({"count": 2, "hits": [{"id": 1}]}), "is_error": False}]},
        ]
        cases.append(("recall", self._journal(), malformed_recall))
        for label, journal, transcript_rows in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                transcript = root / "transcript.jsonl"
                observation = root / "tool-observations.jsonl"
                self._write_jsonl(transcript, transcript_rows)
                self._write_jsonl(observation, journal)
                with self.assertRaises(TraceError):
                    load_control_metrics(transcript, observation)

    @requires_symlinks
    def test_control_metrics_reject_symlink_and_hardlink_observation_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            target = root / "target.jsonl"
            self._write_jsonl(transcript, [{"role": "user", "blocks": []}])
            self._write_jsonl(target, self._journal())
            symlink = root / "symlink.jsonl"
            symlink.symlink_to(target)
            with self.assertRaises(TraceError):
                load_control_metrics(transcript, symlink)
            hardlink = root / "hardlink.jsonl"
            os.link(target, hardlink)
            with self.assertRaisesRegex(TraceError, "hard links"):
                load_control_metrics(transcript, hardlink)


class WorkBuddyArtifactStageTest(unittest.TestCase):
    @staticmethod
    def _elf(machine: int) -> bytes:
        header = bytearray(64)
        header[:7] = b"\x7fELF\x02\x01\x01"
        header[18:20] = machine.to_bytes(2, "little")
        return bytes(header)

    def test_synthetic_stage_binds_all_hashes_and_licenses(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "fixture-bin"
            executable.write_bytes(b"#!/bin/sh\nexit 0\n")
            license_file = root / "LICENSE"
            license_file.write_text("fixture license\n", encoding="utf-8")
            output = root / "stage"
            manifest = stage(
                output=output,
                metacodes=executable,
                tinykg=executable,
                formal_kernel=executable,
                metacodes_commit=ZERO_COMMIT,
                tinykg_commit=ONE_COMMIT,
                licenses=(
                    ("metacodes", "NOASSERTION", license_file),
                    ("tinykg", "Apache-2.0", license_file),
                    ("lean4", "Apache-2.0", license_file),
                ),
                allow_synthetic_fixtures=True,
            )
            self.assertFalse(manifest["quality_evidence"])
            self.assertTrue(manifest["synthetic_fixture"])
            self.assertEqual(
                set(manifest["executables"]),
                {"metacodes", "tinykg", "metacodes-formal-kernel"},
            )
            sums = (output / "share/metacodes/SHA256SUMS").read_text(encoding="ascii")
            self.assertIn("bin/metacodes", sums)
            self.assertIn("share/licenses/tinykg/LICENSE", sums)
            on_disk = json.loads(
                (output / "share/metacodes/artifact-manifest.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(on_disk, manifest)
            self.assertEqual(manifest["target_platform"], "test-fixture")
            with self.assertRaises(StageError):
                stage(
                    output=output,
                    metacodes=executable,
                    tinykg=executable,
                    formal_kernel=executable,
                    metacodes_commit=ZERO_COMMIT,
                    tinykg_commit=ONE_COMMIT,
                    licenses=(
                        ("metacodes", "NOASSERTION", license_file),
                        ("tinykg", "Apache-2.0", license_file),
                        ("lean4", "Apache-2.0", license_file),
                    ),
                    allow_synthetic_fixtures=True,
                )

    def test_stage_binds_optional_project_control_template(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "fixture-bin"
            executable.write_bytes(b"fixture project kernel\n")
            license_file = root / "LICENSE"
            license_file.write_text("fixture license\n", encoding="utf-8")
            rules = root / "project-rules"
            rules.mkdir()
            project_sha = hashlib.sha256(
                b"metacodes-project-identity-v1\x00/workspace"
            ).hexdigest()
            kernel_sha = hashlib.sha256(executable.read_bytes()).hexdigest()
            (rules / "active.json").write_text(
                json.dumps(
                    {
                        "body": {
                            "project_sha256": project_sha,
                            "kernel_sha256": kernel_sha,
                        }
                    }
                ),
                encoding="utf-8",
            )
            (rules / "bundle.json").write_text("{}\n", encoding="utf-8")
            output = root / "stage"
            manifest = stage(
                output=output,
                metacodes=executable,
                tinykg=executable,
                formal_kernel=executable,
                project_kernel=executable,
                project_rules=rules,
                metacodes_commit=ZERO_COMMIT,
                tinykg_commit=ONE_COMMIT,
                licenses=(
                    ("metacodes", "NOASSERTION", license_file),
                    ("tinykg", "Apache-2.0", license_file),
                    ("lean4", "Apache-2.0", license_file),
                ),
                allow_synthetic_fixtures=True,
            )
            control = manifest["project_control"]
            self.assertEqual(control["kernel"]["sha256"], kernel_sha)
            self.assertEqual(control["rules"]["project_sha256"], project_sha)
            self.assertEqual(control["rules"]["files"], 2)
            sums = (output / "share/metacodes/SHA256SUMS").read_text(
                encoding="ascii"
            )
            self.assertIn("libexec/metacodes-project-kernel", sums)
            self.assertIn("workbuddy-w05/project-rules/active.json", sums)

            with self.assertRaisesRegex(StageError, "together"):
                stage(
                    output=root / "missing-rules",
                    metacodes=executable,
                    tinykg=executable,
                    formal_kernel=executable,
                    project_kernel=executable,
                    metacodes_commit=ZERO_COMMIT,
                    tinykg_commit=ONE_COMMIT,
                    licenses=(
                        ("metacodes", "NOASSERTION", license_file),
                        ("tinykg", "Apache-2.0", license_file),
                        ("lean4", "Apache-2.0", license_file),
                    ),
                    allow_synthetic_fixtures=True,
                )

    def test_stage_rejects_non_hex_commit_and_duplicate_license_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "fixture-bin"
            executable.write_bytes(b"fixture")
            license_file = root / "LICENSE"
            license_file.write_text("license\n", encoding="utf-8")
            with self.assertRaisesRegex(StageError, "40-hex"):
                stage(
                    output=root / "bad-commit",
                    metacodes=executable,
                    tinykg=executable,
                    formal_kernel=executable,
                    metacodes_commit="z" * 40,
                    tinykg_commit=ONE_COMMIT,
                    licenses=(("metacodes", "NOASSERTION", license_file),),
                    allow_synthetic_fixtures=True,
                )

    def test_production_stage_rejects_non_elf(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "not-elf"
            executable.write_text("not an ELF\n", encoding="utf-8")
            license_file = root / "LICENSE"
            license_file.write_text("license\n", encoding="utf-8")
            with self.assertRaisesRegex(StageError, "not a Linux ELF"):
                stage(
                    output=root / "stage",
                    metacodes=executable,
                    tinykg=executable,
                    formal_kernel=executable,
                    metacodes_commit=ZERO_COMMIT,
                    tinykg_commit=ONE_COMMIT,
                    licenses=(
                        ("metacodes", "NOASSERTION", license_file),
                        ("tinykg", "Apache-2.0", license_file),
                        ("lean4", "Apache-2.0", license_file),
                    ),
                )
            with self.assertRaisesRegex(StageError, "exactly"):
                stage(
                    output=root / "duplicate-license",
                    metacodes=executable,
                    tinykg=executable,
                    formal_kernel=executable,
                    metacodes_commit=ZERO_COMMIT,
                    tinykg_commit=ONE_COMMIT,
                    licenses=(
                        ("metacodes", "NOASSERTION", license_file),
                        ("tinykg", "Apache-2.0", license_file),
                        ("lean4", "Apache-2.0", license_file),
                        ("lean4", "Apache-2.0", license_file),
                    ),
                    allow_synthetic_fixtures=True,
                )

    def test_production_stage_requires_x86_64_and_records_elf_machine(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            x86 = root / "x86"
            x86.write_bytes(self._elf(62))
            arm = root / "arm"
            arm.write_bytes(self._elf(183))
            license_file = root / "LICENSE"
            license_file.write_text("license\n", encoding="utf-8")
            licenses = (
                ("metacodes", "NOASSERTION", license_file),
                ("tinykg", "Apache-2.0", license_file),
                ("lean4", "Apache-2.0", license_file),
            )
            manifest = stage(
                output=root / "x86-stage",
                metacodes=x86,
                tinykg=x86,
                formal_kernel=x86,
                metacodes_commit=ZERO_COMMIT,
                tinykg_commit=ONE_COMMIT,
                licenses=licenses,
            )
            self.assertEqual(manifest["target_platform"], "linux/amd64")
            self.assertEqual(
                {row["elf_machine"] for row in manifest["executables"].values()},
                {62},
            )
            with self.assertRaisesRegex(StageError, "does not match linux/amd64"):
                stage(
                    output=root / "arm-stage",
                    metacodes=arm,
                    tinykg=arm,
                    formal_kernel=arm,
                    metacodes_commit=ZERO_COMMIT,
                    tinykg_commit=ONE_COMMIT,
                    licenses=licenses,
                )
            self.assertFalse((root / "arm-stage").exists())


class WorkBuddyEnvironmentPreflightTest(unittest.TestCase):
    @staticmethod
    def _fake_run(architecture: str = "amd64"):
        def run(argv, **_kwargs):
            args = [str(item) for item in argv]
            if args[0] == "git" and args[-2:] == ["rev-parse", "HEAD"]:
                return subprocess.CompletedProcess(
                    args, 0, WORKBUDDY_PINNED_COMMIT + "\n", ""
                )
            if "buildx" in args and "build" in args:
                return subprocess.CompletedProcess(args, 0, "built\n", "")
            if args[1:3] == ["image", "inspect"]:
                row = {
                    "Id": "sha256:" + "a" * 64,
                    "Architecture": architecture,
                    "Os": "linux",
                }
                return subprocess.CompletedProcess(args, 0, json.dumps(row), "")
            if args[1:3] == ["version", "--format"]:
                return subprocess.CompletedProcess(
                    args, 0, '{"Version":"test"}\n', ""
                )
            raise AssertionError(f"unexpected preflight command: {args}")

        return run

    def test_preflight_binds_environment_hash_image_and_platform(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            workbuddy = root / "workbuddy"
            harness = workbuddy / "configs/harnesses/metacodes/docker"
            harness.mkdir(parents=True)
            (harness / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
            environment = workbuddy / "datasets/code/tasks/task-a/environment"
            environment.mkdir(parents=True)
            (environment.parent / "task.toml").write_text(
                "[task]\nname = 'task-a'\n", encoding="utf-8"
            )
            (environment / "Dockerfile").write_text(
                "FROM scratch\n", encoding="utf-8"
            )
            docker = root / "docker"
            docker.write_text("fixture\n", encoding="utf-8")
            docker.chmod(0o755)
            receipt = root / "preflight.json"
            with mock.patch(
                "scripts.eval.workbuddy.environment_preflight._run",
                side_effect=self._fake_run(),
            ):
                built = prebuild(
                    workbuddy=workbuddy,
                    dataset="datasets/code/tasks",
                    selected_tasks=["task-a"],
                    output=receipt,
                    docker=docker,
                )
                observed = validate_receipt(
                    receipt,
                    workbuddy=workbuddy,
                    dataset="datasets/code/tasks",
                    selected_tasks=["task-a"],
                    inspect_images=True,
                )
            self.assertEqual(built, observed)
            self.assertEqual(built["target_platform"], "linux/amd64")
            self.assertEqual(built["tasks"]["task-a"]["architecture"], "amd64")
            self.assertEqual(built["dataset_staging"]["task_count"], 1)
            self.assertTrue(built["dataset_staging"]["owner_writable"])
            if POSIX:  # permission bits are synthetic on Windows
                self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)

            (environment / "Dockerfile").write_text(
                "FROM busybox\n", encoding="utf-8"
            )
            with mock.patch(
                "scripts.eval.workbuddy.environment_preflight._run",
                side_effect=self._fake_run(),
            ):
                with self.assertRaisesRegex(
                    EnvironmentPreflightError, "changed after preflight"
                ):
                    validate_receipt(
                        receipt,
                        workbuddy=workbuddy,
                        dataset="datasets/code/tasks",
                        selected_tasks=["task-a"],
                        inspect_images=True,
                    )

    def test_preflight_rejects_non_amd64_image(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            workbuddy = root / "workbuddy"
            harness = workbuddy / "configs/harnesses/metacodes/docker"
            harness.mkdir(parents=True)
            (harness / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
            environment = workbuddy / "datasets/code/tasks/task-a/environment"
            environment.mkdir(parents=True)
            (environment.parent / "task.toml").write_text(
                "[task]\nname = 'task-a'\n", encoding="utf-8"
            )
            (environment / "Dockerfile").write_text(
                "FROM scratch\n", encoding="utf-8"
            )
            docker = root / "docker"
            docker.write_text("fixture\n", encoding="utf-8")
            docker.chmod(0o755)
            with mock.patch(
                "scripts.eval.workbuddy.environment_preflight._run",
                side_effect=self._fake_run("arm64"),
            ):
                with self.assertRaisesRegex(
                    EnvironmentPreflightError, "expected linux/amd64"
                ):
                    prebuild(
                        workbuddy=workbuddy,
                        dataset="datasets/code/tasks",
                        selected_tasks=["task-a"],
                        output=root / "preflight.json",
                        docker=docker,
                    )

    def test_preflight_rejects_unselected_readonly_task_before_docker_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            workbuddy = root / "workbuddy"
            harness = workbuddy / "configs/harnesses/metacodes/docker"
            harness.mkdir(parents=True)
            (harness / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
            for task in ("task-a", "task-b"):
                environment = workbuddy / f"datasets/code/tasks/{task}/environment"
                environment.mkdir(parents=True)
                (environment / "Dockerfile").write_text(
                    "FROM scratch\n", encoding="utf-8"
                )
                (environment.parent / "task.toml").write_text(
                    f"[task]\nname = '{task}'\n", encoding="utf-8"
                )
            unselected = workbuddy / "datasets/code/tasks/task-b/task.toml"
            unselected.chmod(0o444)
            calls: list[list[str]] = []

            def observe_run(argv, **kwargs):
                calls.append([str(item) for item in argv])
                return self._fake_run()(argv, **kwargs)

            docker = root / "docker"
            docker.write_text("fixture\n", encoding="utf-8")
            docker.chmod(0o755)
            with mock.patch(
                "scripts.eval.workbuddy.environment_preflight._run",
                side_effect=observe_run,
            ):
                with self.assertRaisesRegex(
                    EnvironmentPreflightError,
                    r"not owner-writable.*task-b[/\\]task\.toml",
                ):
                    prebuild(
                        workbuddy=workbuddy,
                        dataset="datasets/code/tasks",
                        selected_tasks=["task-a"],
                        output=root / "preflight.json",
                        docker=docker,
                    )
            self.assertFalse(
                any("buildx" in call and "build" in call for call in calls)
            )
            self.assertFalse((root / "preflight.json").exists())

    @requires_symlinks
    def test_preflight_reobserves_unselected_task_toml_and_rejects_links(self):
        for mutation in ("content", "symlink", "hardlink"):
            with self.subTest(
                mutation=mutation
            ), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                os.chmod(root, 0o700)
                workbuddy = root / "workbuddy"
                harness = workbuddy / "configs/harnesses/metacodes/docker"
                harness.mkdir(parents=True)
                (harness / "Dockerfile").write_text(
                    "FROM scratch\n", encoding="utf-8"
                )
                for task in ("task-a", "task-b"):
                    environment = (
                        workbuddy / f"datasets/code/tasks/{task}/environment"
                    )
                    environment.mkdir(parents=True)
                    (environment / "Dockerfile").write_text(
                        "FROM scratch\n", encoding="utf-8"
                    )
                    (environment.parent / "task.toml").write_text(
                        f"[task]\nname = '{task}'\n", encoding="utf-8"
                    )
                docker = root / "docker"
                docker.write_text("fixture\n", encoding="utf-8")
                docker.chmod(0o755)
                receipt = root / "preflight.json"
                with mock.patch(
                    "scripts.eval.workbuddy.environment_preflight._run",
                    side_effect=self._fake_run(),
                ):
                    built = prebuild(
                        workbuddy=workbuddy,
                        dataset="datasets/code/tasks",
                        selected_tasks=["task-a"],
                        output=receipt,
                        docker=docker,
                    )
                self.assertEqual(built["dataset_staging"]["task_count"], 2)
                target = workbuddy / "datasets/code/tasks/task-b/task.toml"
                if mutation == "content":
                    target.write_text(
                        "[task]\nname = 'task-b-drifted'\n", encoding="utf-8"
                    )
                    expected = "staging contract changed"
                else:
                    original = target.read_bytes()
                    target.unlink()
                    source = root / f"{mutation}-source.toml"
                    source.write_bytes(original)
                    if mutation == "symlink":
                        target.symlink_to(source)
                        expected = "task.toml is a symlink"
                    else:
                        os.link(source, target)
                        expected = "single-link regular file"
                with mock.patch(
                    "scripts.eval.workbuddy.environment_preflight._run",
                    side_effect=self._fake_run(),
                ):
                    with self.assertRaisesRegex(
                        EnvironmentPreflightError, expected
                    ):
                        validate_receipt(
                            receipt,
                            workbuddy=workbuddy,
                            dataset="datasets/code/tasks",
                            selected_tasks=["task-a"],
                            inspect_images=True,
                        )

    def test_preflight_rejects_missing_selected_task_before_docker_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            workbuddy = root / "workbuddy"
            harness = workbuddy / "configs/harnesses/metacodes/docker"
            harness.mkdir(parents=True)
            (harness / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
            task = workbuddy / "datasets/code/tasks/task-a"
            (task / "environment").mkdir(parents=True)
            (task / "environment/Dockerfile").write_text(
                "FROM scratch\n", encoding="utf-8"
            )
            (task / "task.toml").write_text(
                "[task]\nname = 'task-a'\n", encoding="utf-8"
            )
            docker = root / "docker"
            docker.write_text("fixture\n", encoding="utf-8")
            docker.chmod(0o755)
            calls: list[list[str]] = []

            def observe_run(argv, **kwargs):
                calls.append([str(item) for item in argv])
                return self._fake_run()(argv, **kwargs)

            with mock.patch(
                "scripts.eval.workbuddy.environment_preflight._run",
                side_effect=observe_run,
            ):
                with self.assertRaisesRegex(
                    EnvironmentPreflightError,
                    "selected WorkBuddy task is absent.*task-missing",
                ):
                    prebuild(
                        workbuddy=workbuddy,
                        dataset="datasets/code/tasks",
                        selected_tasks=["task-missing"],
                        output=root / "preflight.json",
                        docker=docker,
                    )
            self.assertFalse(
                any("buildx" in call and "build" in call for call in calls)
            )

    def test_preflight_rejects_incomplete_official_composite_dataset_before_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            workbuddy = root / "workbuddy"
            harness = workbuddy / "configs/harnesses/metacodes/docker"
            harness.mkdir(parents=True)
            (harness / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
            environment = (
                workbuddy
                / "datasets/wb-bench-code-v1.0/tasks/task-a/environment"
            )
            environment.mkdir(parents=True)
            (environment / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
            (environment.parent / "task.toml").write_text(
                "[task]\nname = 'task-a'\n", encoding="utf-8"
            )
            docker = root / "docker"
            docker.write_text("fixture\n", encoding="utf-8")
            docker.chmod(0o755)
            calls: list[list[str]] = []

            def observe_run(argv, **kwargs):
                calls.append([str(item) for item in argv])
                return self._fake_run()(argv, **kwargs)

            with mock.patch(
                "scripts.eval.workbuddy.environment_preflight._run",
                side_effect=observe_run,
            ):
                with self.assertRaisesRegex(
                    EnvironmentPreflightError, "missing dataset.toml"
                ):
                    prebuild(
                        workbuddy=workbuddy,
                        dataset="datasets/wb-bench-code-v1.0/tasks",
                        selected_tasks=["task-a"],
                        output=root / "preflight.json",
                        docker=docker,
                    )
            self.assertFalse(any("buildx" in call for call in calls))

            dataset_root = workbuddy / "datasets/wb-bench-code-v1.0"
            (dataset_root / "dataset.toml").write_text(
                '[verifier]\nschema = "workbuddy.verifier.v1"\nengine = "composite"\ntimeout_sec = 600.0\n',
                encoding="utf-8",
            )
            calls.clear()
            with mock.patch(
                "scripts.eval.workbuddy.environment_preflight._run",
                side_effect=observe_run,
            ):
                with self.assertRaisesRegex(
                    EnvironmentPreflightError,
                    "composite verifier implementation is missing",
                ):
                    prebuild(
                        workbuddy=workbuddy,
                        dataset="datasets/wb-bench-code-v1.0/tasks",
                        selected_tasks=["task-a"],
                        output=root / "preflight.json",
                        docker=docker,
                    )
            self.assertFalse(any("buildx" in call for call in calls))

    def test_preflight_binds_and_reobserves_composite_verifier(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            workbuddy = root / "workbuddy"
            harness = workbuddy / "configs/harnesses/metacodes/docker"
            harness.mkdir(parents=True)
            (harness / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
            dataset_root = workbuddy / "datasets/wb-bench-code-v1.0"
            environment = dataset_root / "tasks/task-a/environment"
            environment.mkdir(parents=True)
            (environment / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
            (environment.parent / "task.toml").write_text(
                "[task]\nname = 'task-a'\n", encoding="utf-8"
            )
            (dataset_root / "dataset.toml").write_text(
                '[verifier]\nschema = "workbuddy.verifier.v1"\nengine = "composite"\n',
                encoding="utf-8",
            )
            shared = dataset_root / "shared/verifier"
            shared.mkdir(parents=True)
            plugin = shared / "plugin.py"
            plugin.write_text("VALUE = 1\n", encoding="utf-8")
            docker = root / "docker"
            docker.write_text("fixture\n", encoding="utf-8")
            docker.chmod(0o755)
            receipt = root / "preflight.json"
            with mock.patch(
                "scripts.eval.workbuddy.environment_preflight._run",
                side_effect=self._fake_run(),
            ):
                built = prebuild(
                    workbuddy=workbuddy,
                    dataset="datasets/wb-bench-code-v1.0/tasks",
                    selected_tasks=["task-a"],
                    output=receipt,
                    docker=docker,
                )
            self.assertEqual(
                built["dataset_execution"]["shared_verifier"]["files"], 1
            )
            plugin.write_text("VALUE = 2\n", encoding="utf-8")
            with mock.patch(
                "scripts.eval.workbuddy.environment_preflight._run",
                side_effect=self._fake_run(),
            ):
                with self.assertRaisesRegex(
                    EnvironmentPreflightError, "execution contract changed"
                ):
                    validate_receipt(
                        receipt,
                        workbuddy=workbuddy,
                        dataset="datasets/wb-bench-code-v1.0/tasks",
                        selected_tasks=["task-a"],
                        inspect_images=True,
                    )

    @requires_symlinks
    def test_preflight_rejects_composite_verifier_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            workbuddy = root / "workbuddy"
            harness = workbuddy / "configs/harnesses/metacodes/docker"
            harness.mkdir(parents=True)
            (harness / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
            dataset_root = workbuddy / "datasets/wb-bench-code-v1.0"
            environment = dataset_root / "tasks/task-a/environment"
            environment.mkdir(parents=True)
            (environment / "Dockerfile").write_text("FROM scratch\n", encoding="utf-8")
            (environment.parent / "task.toml").write_text(
                "[task]\nname = 'task-a'\n", encoding="utf-8"
            )
            (dataset_root / "dataset.toml").write_text(
                '[verifier]\nschema = "workbuddy.verifier.v1"\nengine = "composite"\n',
                encoding="utf-8",
            )
            external = root / "external-verifier"
            external.mkdir()
            (external / "plugin.py").write_text("VALUE = 1\n", encoding="utf-8")
            shared = dataset_root / "shared"
            shared.mkdir()
            (shared / "verifier").symlink_to(external, target_is_directory=True)
            docker = root / "docker"
            docker.write_text("fixture\n", encoding="utf-8")
            docker.chmod(0o755)
            calls: list[list[str]] = []

            def observe_run(argv, **kwargs):
                calls.append([str(item) for item in argv])
                return self._fake_run()(argv, **kwargs)

            with mock.patch(
                "scripts.eval.workbuddy.environment_preflight._run",
                side_effect=observe_run,
            ):
                with self.assertRaisesRegex(
                    EnvironmentPreflightError,
                    "composite verifier implementation is unsafe",
                ):
                    prebuild(
                        workbuddy=workbuddy,
                        dataset="datasets/wb-bench-code-v1.0/tasks",
                        selected_tasks=["task-a"],
                        output=root / "preflight.json",
                        docker=docker,
                    )
            self.assertFalse(any("buildx" in call for call in calls))


def _materialize_pinned_upstream(repo: Path) -> None:
    """Commit a stand-in for the pinned WorkBuddy checkout.

    It carries exactly the upstream anchor text the installer patches plus the
    package skeleton the shipped modules are copied into, so the real installer
    can run end to end in a temporary directory without the Tencent clone.
    """
    fixtures = {
        Path("src/workbuddy_bench/__init__.py"): "",
        Path("src/workbuddy_bench/agents/__init__.py"): "",
        Path("src/workbuddy_bench/proxy/__init__.py"): "",
        Path("src/workbuddy_bench/proxy/interceptors/__init__.py"): "",
        Path("src/workbuddy_bench/runner/__init__.py"): "",
        overlay_installer._ADAPTER_PATH:
            overlay_installer._ADAPTER_ANCHOR,
        overlay_installer._RESOLVER_PATH: (
            overlay_installer._DISPATCH_OLD
            + overlay_installer._GENERIC_ANCHOR
            + overlay_installer._MODEL_ROUTE_OLD
            + overlay_installer._RESOLVER_MOUNT_OLD
            + overlay_installer._RESUME_SUBSET_OLD
        ),
        overlay_installer._PREPARE_JOB_PATH:
            (
                overlay_installer._PREPARE_AGENT_IDENTITY_OLD
                + overlay_installer._PREPARE_MOUNT_OLD
            ),
        overlay_installer._PROXY_CONFIG_PATH: (
            overlay_installer._PROXY_IMPORT_ANCHOR
            + overlay_installer._PROXY_KEY_OLD
        ),
        overlay_installer._PROXY_LOGGER_PATH: (
            overlay_installer._PROXY_LOGGER_INIT_OLD
            + overlay_installer._PROXY_LOGGER_REQUEST_OLD
            + overlay_installer._PROXY_LOGGER_DISCARD_OLD
            + overlay_installer._PROXY_LOGGER_SEQ_OLD
            + overlay_installer._PROXY_LOGGER_RECORD_SEQ_OLD
        ),
        overlay_installer._PROXY_PIPELINE_PATH: (
            overlay_installer._PROXY_PIPELINE_A2O_SIGNATURE_OLD
            + overlay_installer._PROXY_PIPELINE_PASSTHROUGH_SIGNATURE_OLD
            + overlay_installer._PROXY_PIPELINE_A2O_SENDER_OLD
            + overlay_installer._PROXY_PIPELINE_PASSTHROUGH_SENDER_OLD
            + overlay_installer._PROXY_PIPELINE_SUBSTREAM_CALLS_OLD
            + overlay_installer._PROXY_PIPELINE_A2O_START_OLD
            + overlay_installer._PROXY_PIPELINE_A2O_EVENTS_OLD
            + overlay_installer._PROXY_PIPELINE_A2O_FINISH_OLD
            + overlay_installer._PROXY_PIPELINE_PASSTHROUGH_OLD
            + overlay_installer._PROXY_PIPELINE_REWRITE_OLD
            + overlay_installer._PROXY_PIPELINE_REWRITE_TAIL_OLD
            + overlay_installer._PROXY_PIPELINE_STREAM_STATE_OLD
            + overlay_installer._PROXY_PIPELINE_STREAM_LOOP_OLD
            + overlay_installer._PROXY_PIPELINE_FINALLY_OLD
        ),
    }
    # Bytes, not text: the installer compares the file on disk with the HEAD
    # blob byte-for-byte before patching.  A text-mode write on Windows lands
    # CRLF while Git for Windows (core.autocrlf=true) commits LF, and the
    # installer then refuses the fixture as "modified independently".  The
    # pinned checkout is LF on every host, so the fixture is too, and the
    # repository-local setting keeps the installer's own git calls from
    # renormalizing behind it.
    for relative, content in fixtures.items():
        path = repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content.encode("utf-8"))
    for args in (
        ("init", "-q"),
        ("config", "core.autocrlf", "false"),
        ("add", "."),
        (
            "-c", "user.name=metacodes-test",
            "-c", "user.email=metacodes-test@example.invalid",
            "commit", "-qm", "fixture",
        ),
    ):
        subprocess.run(
            ["git", "-C", str(repo), *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )


def _install_overlay_into(repo: Path) -> dict:
    """Run the real installer against a materialized fixture checkout.

    Only the two identity probes the fixture cannot satisfy (pinned HEAD and
    the Tencent origin) are answered for it; diff, ls-files and show run for
    real so the dirty-path and upstream-patch logic is exercised.
    """
    real_run = overlay_installer._run

    def run(target, *args):
        if args == ("rev-parse", "HEAD"):
            return WORKBUDDY_PINNED_COMMIT + "\n"
        if args == ("remote", "get-url", "origin"):
            return "https://github.com/Tencent/WorkBuddy-Bench.git\n"
        return real_run(target, *args)

    with mock.patch.object(overlay_installer, "_run", side_effect=run):
        return overlay_installer.install(repo)


# Imports the shipped private modules the way Harbor does: as members of the
# workbuddy_bench package, in a fresh isolated interpreter whose only extra
# sys.path entry is the checkout's src/.  Nothing from this repository is
# importable there, so a copied module that still reaches for a metacodes
# sibling fails exactly as it does inside a trial.
_INSTALLED_OVERLAY_IMPORT_PROBE = r'''
import json, sys
sys.path.insert(0, sys.argv[1])
import workbuddy_bench._metacodes_model as model
import workbuddy_bench.agents._metacodes_trace as trace
import workbuddy_bench.proxy._metacodes_key_fd as key_fd
print(json.dumps({
    "modules": [module.__name__ for module in (model, trace, key_fd)],
    "trace_file": trace.__file__,
    "trace_uses_shipped_open_nofollow": trace.open_nofollow is model.open_nofollow,
}))
'''


def _probe_installed_overlay_imports(repo: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            sys.executable,
            "-I",
            "-c",
            _INSTALLED_OVERLAY_IMPORT_PROBE,
            str(repo / "src"),
        ],
        cwd=repo,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )


class WorkBuddyOverlayUpgradeTest(unittest.TestCase):
    def test_workbuddy_headless_policy_hides_interactive_plan_without_disabling_tinykg(self):
        overlay = Path(__file__).parents[1] / "workbuddy/overlay"
        defaults = yaml.safe_load(
            (overlay / "configs/harnesses/metacodes/_defaults.yaml").read_text(
                encoding="utf-8"
            )
        )
        configured = set(
            defaults["harness"]["params"]["METACODES_DISALLOWED_TOOLS"].split(",")
        )

        adapter_path = overlay / "src/workbuddy_bench/agents/metacodes_agent.py"
        tree = ast.parse(adapter_path.read_text(encoding="utf-8"))
        adapter_default = None
        for node in tree.body:
            if not isinstance(node, ast.Assign):
                continue
            if any(
                isinstance(target, ast.Name)
                and target.id == "_DEFAULT_DISABLED_TOOLS"
                for target in node.targets
            ):
                adapter_default = ast.literal_eval(node.value)
                break
        self.assertIsInstance(adapter_default, str)
        self.assertEqual(configured, set(adapter_default.split(",")))
        self.assertTrue(
            {
                "Agent", "Task", "TaskBatch", "TeamCreate", "TeamDelete",
                "SendMessage", "EnterPlanMode", "ExitPlanMode",
            }.issubset(configured)
        )
        self.assertTrue(
            {
                "KgRecall", "KgContext", "KgRemember",
                "TaskCreate", "TaskList", "TaskUpdate",
            }
            .isdisjoint(configured)
        )

    def test_installed_adapter_post_run_accepts_real_task_list_contract(self):
        checkout_raw = os.environ.get("METACODES_WORKBUDDY_CHECKOUT")
        if not checkout_raw:
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        checkout = Path(checkout_raw).resolve()
        if not checkout.is_dir():
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        overlay_installer.validate_installed_overlay(checkout)
        program = r'''
import json, tempfile
from pathlib import Path
from harbor.models.agent.context import AgentContext
from workbuddy_bench.agents._metacodes_trace import (
    OBSERVATION_JOURNAL_SCHEMA, OBSERVATION_FILENAME,
)
from workbuddy_bench.agents.metacodes_agent import MetacodesAgent

def write_jsonl(path, rows):
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")

with tempfile.TemporaryDirectory() as directory:
    logs = Path(directory) / "trial" / "agent"
    logs.mkdir(parents=True)
    write_jsonl(logs / "metacodes-output.jsonl", [{
        "type": "result", "stop_reason": "end_turn", "turns": 1,
        "tool_calls": 1, "input_tokens": 120, "output_tokens": 30,
        "cache_read_input_tokens": 80, "cache_creation_input_tokens": 10,
        "cost_usd": 0.01, "text": "done",
    }])
    write_jsonl(logs / "metacodes-transcript.jsonl", [
        {"role": "assistant", "blocks": [{
            "type": "tool_use", "id": "list-1", "name": "TaskList", "input": {}
        }]},
        {"role": "user", "blocks": [{
            "type": "tool_result", "tool_use_id": "list-1", "is_error": False,
            "content": json.dumps([
                {"id": "kg-1", "subject": "Task", "status": "pending",
                 "kg_status": "open", "readiness": "ready", "plan_step": True},
                {"parallel_hint": "2 ready tasks can run in parallel"},
            ]),
        }]},
        {"role": "assistant", "blocks": [{"type": "text", "text": "done"}]},
    ])
    write_jsonl(logs / OBSERVATION_FILENAME, [
        {"schema_version": OBSERVATION_JOURNAL_SCHEMA, "sequence": 0,
         "monotonic_elapsed_ns": 0, "session_id": "session-l2", "run_id": "run-l2",
         "event": {"run_started": {}}},
        {"schema_version": OBSERVATION_JOURNAL_SCHEMA, "sequence": 1,
         "monotonic_elapsed_ns": 1, "session_id": "session-l2", "run_id": "run-l2",
         "event": {"run_finished": {}}},
    ])
    agent = MetacodesAgent(
        logs, model_name="route-l2", model_params={},
        METACODES_MODEL_DISPLAY_NAME="glm-5.2",
        connection={"mode": "local_proxy", "proxy_url": "http://127.0.0.1:1"},
    )
    context = AgentContext()
    agent.populate_context_post_run(context)
    trajectory = json.loads((logs / "trajectory.json").read_text(encoding="utf-8"))
    control = trajectory["final_metrics"]["extra"]["control_metrics"]
    assert control["tinykg"]["task_list_calls"] == 1
    assert control["tinykg"]["task_tinykg_status_results"] == 1
    assert context.n_input_tokens == 120
    assert context.n_cache_tokens == 80
    assert context.n_output_tokens == 30
    assert context.cost_usd == 0.01
'''
        env = dict(os.environ)
        env["PYTHONPATH"] = str(checkout / "src")
        subprocess.run(
            [str(checkout / ".venv/bin/python"), "-c", program],
            cwd=checkout,
            env=env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_installed_adapter_tolerates_killed_agent_missing_result_event(self):
        # A killed or timed-out trial (harbor SIGTERM -> exit 143, OOM) is torn
        # down before it emits its single terminal `result` event. load_trace_ir
        # then raises "found 0"; populate_context_post_run must record a
        # degenerate failed zero-reward trajectory that *validates against the
        # real harbor Trajectory/Step/FinalMetrics models* instead of raising,
        # because a raise here propagates through harbor's TaskGroup and cancels
        # every sibling trial (kunshan security-sealed, 2026-09-05, died at
        # 3/24). This is the model-validation the pure-Python suite cannot do.
        checkout_raw = os.environ.get("METACODES_WORKBUDDY_CHECKOUT")
        if not checkout_raw:
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        checkout = Path(checkout_raw).resolve()
        if not checkout.is_dir():
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        installed_agent = checkout / "src/workbuddy_bench/agents/metacodes_agent.py"
        if "killed_no_result" not in installed_agent.read_text(encoding="utf-8"):
            self.skipTest(
                "installed overlay predates the killed-agent tolerance; "
                "reinstall the overlay to activate this gate"
            )
        overlay_installer.validate_installed_overlay(checkout)
        program = r'''
import json, tempfile
from pathlib import Path
from harbor.models.agent.context import AgentContext
from workbuddy_bench.agents._metacodes_trace import (
    OBSERVATION_JOURNAL_SCHEMA, OBSERVATION_FILENAME,
)
from workbuddy_bench.agents.metacodes_agent import MetacodesAgent

def write_jsonl(path, rows):
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")

with tempfile.TemporaryDirectory() as directory:
    logs = Path(directory) / "trial" / "agent"
    logs.mkdir(parents=True)
    # Truncated output: live stream events, no terminal `result` event.
    write_jsonl(logs / "metacodes-output.jsonl", [
        {"type": "turn_begin", "turn": 1},
        {"type": "text", "text": "starting"},
    ])
    write_jsonl(logs / "metacodes-transcript.jsonl", [
        {"role": "user", "blocks": [{"type": "text", "text": "task"}]},
    ])
    write_jsonl(logs / OBSERVATION_FILENAME, [
        {"schema_version": OBSERVATION_JOURNAL_SCHEMA, "sequence": 0,
         "monotonic_elapsed_ns": 0, "session_id": "s-l2", "run_id": "r-l2",
         "event": {"run_started": {}}},
        {"schema_version": OBSERVATION_JOURNAL_SCHEMA, "sequence": 1,
         "monotonic_elapsed_ns": 1, "session_id": "s-l2", "run_id": "r-l2",
         "event": {"run_finished": {}}},
    ])
    agent = MetacodesAgent(
        logs, model_name="route-l2", model_params={},
        METACODES_MODEL_DISPLAY_NAME="glm-5.2",
        connection={"mode": "local_proxy", "proxy_url": "http://127.0.0.1:1"},
    )
    context = AgentContext()
    # Must not raise: a raise here cancels every sibling trial in the cohort.
    agent.populate_context_post_run(context)
    trajectory = json.loads((logs / "trajectory.json").read_text(encoding="utf-8"))
    # Degenerate single-step zero trajectory that validated against the real
    # harbor models (the to_json_dict write would have raised otherwise).
    assert len(trajectory["steps"]) == 1, trajectory["steps"]
    extra = trajectory["final_metrics"]["extra"]
    assert extra["metacodes_stop_reason"] == "killed_no_result", extra
    assert extra["control_metrics"] == {"killed_no_result": True}, extra
    # Recorded as a failed zero-reward run; it never reaches the verifier.
    assert context.n_input_tokens == 0
    assert context.n_output_tokens == 0
    assert context.cost_usd == 0
'''
        env = dict(os.environ)
        env["PYTHONPATH"] = str(checkout / "src")
        subprocess.run(
            [str(checkout / ".venv/bin/python"), "-c", program],
            cwd=checkout,
            env=env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_installed_adapter_enforced_mode_requires_rule_filter_receipt(self):
        # Runtime receipt for the enforced arm (harness review 2026-08-17
        # finding #2): a dispatching enforced run whose journal has zero
        # rule_filter events means the binary never loaded the staged
        # bundle — the trial must die loudly, not score with rules off.
        checkout_raw = os.environ.get("METACODES_WORKBUDDY_CHECKOUT")
        if not checkout_raw:
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        checkout = Path(checkout_raw).resolve()
        if not checkout.is_dir():
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        installed_agent = (
            checkout / "src/workbuddy_bench/agents/metacodes_agent.py"
        )
        if "no rule_filter" not in installed_agent.read_text(encoding="utf-8"):
            self.skipTest(
                "installed overlay predates the enforced rule-load receipt; "
                "reinstall the overlay to activate this gate"
            )
        overlay_installer.validate_installed_overlay(checkout)
        program = r'''
import json, tempfile
from pathlib import Path
from workbuddy_bench.agents._metacodes_trace import (
    OBSERVATION_JOURNAL_SCHEMA, OBSERVATION_FILENAME,
    TOOL_OBSERVATION_SCHEMA, RULE_FILTER_PROOFS,
)
from workbuddy_bench.agents.metacodes_agent import MetacodesAgent
from harbor.models.agent.context import AgentContext

def journal_rows(events):
    payloads = [{"run_started": {}}, *events, {"run_finished": {}}]
    return [
        {"schema_version": OBSERVATION_JOURNAL_SCHEMA, "sequence": seq,
         "monotonic_elapsed_ns": seq, "session_id": "s-l2", "run_id": "r-l2",
         "event": payload}
        for seq, payload in enumerate(payloads)
    ]

start = {"schema_version": TOOL_OBSERVATION_SCHEMA, "id": "d-1",
         "requested_name": "Read", "dispatched_name": "Read",
         "origin": "authoritative", "agent_depth": 0}
finish = {**start, "outcome": "succeeded"}
identity = {
    "schema_version": "metacodes-project-rule-filter-v1", "operation": "ordinary",
    "project_sha256": "1" * 64, "bundle_sha256": "2" * 64, "bundle_revision": 1,
    "kernel_sha256": "3" * 64, "active_rule_count": 1, "checker_rule_count": 0,
    "statically_pruned_rule_count": 1, "proof": sorted(RULE_FILTER_PROOFS)[0],
}

def run_trial(directory, with_filters):
    logs = Path(directory) / "trial" / "agent"
    logs.mkdir(parents=True)
    for name, rows in (
        ("metacodes-output.jsonl", [{
            "type": "result", "stop_reason": "end_turn", "turns": 1,
            "tool_calls": 1, "input_tokens": 10, "output_tokens": 5,
            "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
            "cost_usd": 0.001, "text": "done"}]),
        ("metacodes-transcript.jsonl", [
            {"role": "assistant", "blocks": [{"type": "text", "text": "done"}]}]),
    ):
        (logs / name).write_text(
            "".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    events = []
    if with_filters:
        events.append({"tool_observation": {"rule_filter": {
            **identity, "dispatch_id": "d-1", "phase": "pre"}}})
    events.append({"tool_observation": {"dispatch_started": start}})
    if with_filters:
        events.append({"tool_observation": {"rule_filter": {
            **identity, "dispatch_id": "d-1", "phase": "post"}}})
    events.append({"tool_observation": {"dispatch_finished": finish}})
    (logs / OBSERVATION_FILENAME).write_text(
        "".join(json.dumps(r) + "\n" for r in journal_rows(events)),
        encoding="utf-8")
    agent = MetacodesAgent(
        logs, model_name="route-l2", model_params={},
        METACODES_MODEL_DISPLAY_NAME="glm-5.2",
        METACODES_PROJECT_RULES_RELATIVE="share/metacodes/project-rules",
        METACODES_PROJECT_KERNEL_RELATIVE="share/metacodes/kernel",
        METACODES_PROJECT_CONTROL_MODE="enforced",
        connection={"mode": "local_proxy", "proxy_url": "http://127.0.0.1:1"},
    )
    agent.populate_context_post_run(AgentContext())

with tempfile.TemporaryDirectory() as directory:
    run_trial(directory, with_filters=True)   # receipt present: must pass
failed = False
try:
    with tempfile.TemporaryDirectory() as directory:
        run_trial(directory, with_filters=False)
except RuntimeError as exc:
    failed = "no rule_filter" in str(exc)
assert failed, "enforced run without rule_filter events must fail loudly"
'''
        env = dict(os.environ)
        env["PYTHONPATH"] = str(checkout / "src")
        subprocess.run(
            [str(checkout / ".venv/bin/python"), "-c", program],
            cwd=checkout,
            env=env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_adapter_keeps_machine_ndjson_stdout_separate_from_diagnostics(self):
        source = (
            Path(__file__).parents[1]
            / "workbuddy/overlay/src/workbuddy_bench/agents/metacodes_agent.py"
        ).read_text(encoding="utf-8")
        # stderr 落 /logs/agent 自己的文件并透传 fd2(p3 取证:Harbor stderr
        # 流不进任何导出物,warn 诊断链进虚空)——但绝不许并进 NDJSON stdout。
        self.assertIn(
            '"</dev/null 2> >(tee /logs/agent/metacodes-stderr.log >&2) "',
            source,
        )
        self.assertIn(
            'f"| tee {shlex.quote(output_path)}; "',
            source,
        )
        self.assertNotIn("2>&1", source)

    def test_adapter_remote_environment_assertion_is_one_shell_operand(self):
        source = (
            Path(__file__).parents[1]
            / "workbuddy/overlay/src/workbuddy_bench/agents/metacodes_agent.py"
        ).read_text(encoding="utf-8")
        compiled = compile(source, "<metacodes-agent>", "exec")
        strings = []

        def collect(code):
            for value in code.co_consts:
                if isinstance(value, str):
                    strings.append(value)
                elif hasattr(value, "co_consts"):
                    collect(value)

        collect(compiled)
        command_fragment = next(
            value for value in strings if "TINYKG_REMOTE_URL+x" in value
        )
        self.assertIn(
            'test -z "${TINYKG_REMOTE_URL+x}${TINYKG_API_KEY+x}'
            '${TINYKG_REMOTE_EXPECTED_BUILD_ID+x}${TINYKG_REMOTE_CONFIG+x}'
            '${METACODES_KG_CONFIG+x}${METACODES_KG_URL+x}${METACODES_KG_API_KEY+x}'
            '${METACODES_KG_EXPECTED_BUILD_ID+x}${METACODES_KG_EXPECTED_SCHEMA_DIGEST+x}'
            '${METASK_API_KEY+x}" || exit 84',
            command_fragment,
        )
        self.assertIn("remote_tinykg_env_absent", source)
        self.assertIn("export METACODES_KG_TRANSPORT=cli-exclusive", source)
        self.assertIn(
            'raise ValueError("metacodes WorkBuddy trial received remote TinyKG authority")',
            source,
        )

    def test_adapter_command_uses_distinct_fresh_home_per_step(self):
        # Load the overlay adapter with narrow test doubles for WorkBuddy's
        # runtime types so this L2 check exercises the command actually built
        # by MetacodesAgent, even when a pinned WorkBuddy checkout is absent.
        module_names = (
            "harbor",
            "harbor.agents",
            "harbor.agents.installed",
            "harbor.environments",
            "harbor.models",
            "harbor.models.agent",
            "harbor.models.trajectories",
            "workbuddy_bench",
            "workbuddy_bench.agents",
        )
        modules = {name: types.ModuleType(name) for name in module_names}

        class BaseInstalledAgent:
            def __init__(self, logs_dir, *_args, **_kwargs):
                self.logs_dir = logs_dir

        modules["harbor.agents.installed.base"] = types.ModuleType(
            "harbor.agents.installed.base"
        )
        modules["harbor.agents.installed.base"].BaseInstalledAgent = BaseInstalledAgent
        modules["harbor.environments.base"] = types.ModuleType(
            "harbor.environments.base"
        )
        modules["harbor.environments.base"].BaseEnvironment = type(
            "BaseEnvironment", (), {}
        )
        modules["harbor.models.agent.context"] = types.ModuleType(
            "harbor.models.agent.context"
        )
        modules["harbor.models.agent.context"].AgentContext = type(
            "AgentContext", (), {}
        )
        for name, class_name in (
            ("agent", "Agent"),
            ("final_metrics", "FinalMetrics"),
            ("observation", "Observation"),
            ("observation_result", "ObservationResult"),
            ("step", "Step"),
            ("tool_call", "ToolCall"),
            ("trajectory", "Trajectory"),
        ):
            modules[f"harbor.models.trajectories.{name}"] = types.ModuleType(
                f"harbor.models.trajectories.{name}"
            )
            setattr(
                modules[f"harbor.models.trajectories.{name}"],
                class_name,
                type(class_name, (), {}),
            )
        modules["workbuddy_bench.agents._agent_user"] = types.ModuleType(
            "workbuddy_bench.agents._agent_user"
        )
        modules["workbuddy_bench.agents._agent_user"].ensure_agent_user = lambda *args, **kwargs: None
        trace_module = types.ModuleType("workbuddy_bench.agents._metacodes_trace")
        trace_module.OBSERVATION_FILENAME = "tool-observations.jsonl"
        trace_module.TraceError = type("TraceError", (Exception,), {})
        trace_module.anthropic_messages_endpoint = lambda url: url + "/v1/messages"
        trace_module.load_control_metrics = lambda *_args: {}
        trace_module.load_trace_ir = lambda *_args: {}
        trace_module.project_state_hash = lambda *_args: "project-hash"
        modules["workbuddy_bench.agents._metacodes_trace"] = trace_module

        adapter_path = (
            Path(__file__).parents[1]
            / "workbuddy/overlay/src/workbuddy_bench/agents/metacodes_agent.py"
        )
        with mock.patch.dict(sys.modules, modules, clear=False):
            spec = importlib.util.spec_from_file_location(
                "workbuddy_bench.agents.metacodes_agent_l2", adapter_path
            )
            adapter = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(adapter)

            async def capture_command(logs_dir, instruction="instruction"):
                agent = adapter.MetacodesAgent.__new__(adapter.MetacodesAgent)
                agent.logs_dir = logs_dir
                agent.model_name = "route-l2"
                agent._model_display_name = "model-l2"
                agent._model_params = {}
                agent._mount_path = "/opt/metacodes"
                agent._disabled_tools = "Agent"
                agent._proxy_url = "http://127.0.0.1:1"
                agent._session_id = ""
                agent._max_output_tokens = None
                agent._verification_checkpoint = False
                agent._verification_final_gate = False
                agent._verification_final_observe = False
                agent._requirement_ledger = False
                agent._requirement_ledger_observe = False
                agent._project_kernel_relative = None
                agent._project_rules_relative = None
                agent._project_control_mode = "absent"
                agent._memory_accumulation = False
                agent._self_evolution = False
                agent._outcome_feedback = False
                agent._continuity_seed_sha256 = None
                agent._context_window = None
                agent._context_compact_pct = None
                captured = {}
                agent.render_instruction = lambda instruction: instruction

                async def fake_exec(_environment, command, **_kwargs):
                    captured["command"] = command

                agent.exec_as_agent = fake_exec
                await agent.run(instruction, object(), None)
                return captured["command"]

            with tempfile.TemporaryDirectory() as directory:
                first_logs = Path(directory) / "trial" / "steps" / "find-vuln" / "agent"
                second_logs = Path(directory) / "trial" / "steps" / "poc-verify" / "agent"
                first_logs.mkdir(parents=True)
                second_logs.mkdir(parents=True)
                # Real multi-step shape: harbor reuses the SAME logs_dir for both
                # steps; only the rendered instruction differs.  Both must yield
                # a DIFFERENT, deterministic HOME so step 2 does not trip the
                # fresh-HOME guard.
                commands = [
                    asyncio.run(capture_command(first_logs, "audit for the vulnerability")),
                    asyncio.run(capture_command(first_logs, "write the proof of concept")),
                ]
                det_command = asyncio.run(
                    capture_command(first_logs, "audit for the vulnerability")
                )

                missing_logs = Path(directory) / "trial" / "steps" / "setup-failed" / "agent"
                missing_logs.mkdir(parents=True)
                missing_agent = adapter.MetacodesAgent.__new__(adapter.MetacodesAgent)
                missing_agent.logs_dir = missing_logs
                missing_agent._project_control_mode = "absent"
                captured_trace = {}

                def missing_trace(*_args):
                    raise FileNotFoundError("metacodes-output.jsonl")

                class MarkerTrajectory:
                    final_metrics = None

                    def to_json_dict(self):
                        return {"marker": "killed-no-result"}

                def build_marker_trajectory(trace):
                    captured_trace["trace"] = trace
                    return MarkerTrajectory()

                adapter.load_trace_ir = missing_trace
                missing_agent._build_trajectory = build_marker_trajectory
                missing_agent.populate_context_post_run(types.SimpleNamespace())
                missing_trajectory = json.loads(
                    (missing_logs / "trajectory.json").read_text(encoding="utf-8")
                )

        homes = [re.search(r'run_home="([^"]+)";', command).group(1) for command in commands]
        self.assertNotEqual(homes[0], homes[1])
        self.assertTrue(all(home.startswith("/tmp/") for home in homes))
        det_home = re.search(r'run_home="([^"]+)";', det_command).group(1)
        # Same logs_dir + different instruction -> different HOME (the multi-step fix).
        self.assertNotEqual(homes[0], homes[1])
        # Deterministic for a given (logs_dir, instruction).
        self.assertEqual(homes[0], det_home)
        for home in homes:
            self.assertTrue(home.startswith("/tmp/metacodes-workbuddy-home-"))
        for command in commands:
            # The fresh-HOME guard must survive per step: it is what proves the
            # HOME was created empty for this step (not reused from a prior one).
            self.assertIn(
                'test ! -e "$run_home" || { echo "fresh HOME already exists" >&2; exit 70; };',
                command,
            )
            self.assertIn(
                'mkdir -p "$run_home" || exit 70; export HOME="$run_home";',
                command,
            )
            self.assertIn("umask 077;", command)
            self.assertIn('"fresh_home":true', command)
        self.assertEqual(
            captured_trace["trace"]["result"]["stop_reason"],
            "killed_no_result",
        )
        self.assertEqual(
            missing_trajectory,
            {"marker": "killed-no-result"},
        )

    def test_adapter_routes_through_custom_provider_not_base_url(self):
        # Since metacodes EndpointPolicy defaults to require_tls=True, a plaintext
        # --base-url override to the WorkBuddy job proxy is rejected
        # (InsecureEndpoint).  The adapter therefore writes a `workbuddy-proxy`
        # custom_provider (endpoint_policy.require_tls=False, route-token via env
        # alias) and selects it with METACODES_PROVIDER, instead of injecting
        # METACODES_BASE_URL.  Guard that contract so a regression back to the
        # base-url path is caught.
        source = (
            Path(__file__).parents[1]
            / "workbuddy/overlay/src/workbuddy_bench/agents/metacodes_agent.py"
        ).read_text(encoding="utf-8")
        self.assertIn('"custom_providers": {', source)
        self.assertIn('"METACODES_PROVIDER": _PROXY_PROVIDER_ID', source)
        self.assertIn('anthropic_messages_endpoint(self._proxy_url)', source)
        # The plaintext base-url override must NOT be reintroduced.
        self.assertNotIn('"METACODES_BASE_URL": escaped_proxy', source)

    def test_overlay_patches_resolve_and_prepare_with_one_mount_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            _materialize_pinned_upstream(repo)
            patched = overlay_installer._patched_upstream(repo)
            resolver = patched[overlay_installer._RESOLVER_PATH].decode("utf-8")
            prepare = patched[overlay_installer._PREPARE_JOB_PATH].decode("utf-8")
            self.assertIn(overlay_installer._RESOLVER_MOUNT_NEW, resolver)
            self.assertIn(overlay_installer._MODEL_ROUTE_NEW, resolver)
            self.assertIn(overlay_installer._PREPARE_MOUNT_NEW, prepare)
            self.assertIn(overlay_installer._PREPARE_AGENT_IDENTITY_NEW, prepare)
            proxy_logger = patched[overlay_installer._PROXY_LOGGER_PATH].decode("utf-8")
            proxy_pipeline = patched[overlay_installer._PROXY_PIPELINE_PATH].decode("utf-8")
            self.assertIn(overlay_installer._PROXY_LOGGER_REQUEST_NEW, proxy_logger)
            self.assertIn(overlay_installer._PROXY_LOGGER_DISCARD_NEW, proxy_logger)
            self.assertIn(overlay_installer._PROXY_PIPELINE_FINALLY_NEW, proxy_pipeline)
            self.assertIn(overlay_installer._PROXY_PIPELINE_PASSTHROUGH_NEW, proxy_pipeline)
            self.assertIn('"actor_model_identity": backend_model_name', resolver)
            self.assertIn(
                '"transport_model_is_route": connection_mode == "local_proxy"',
                resolver,
            )
            self.assertNotIn(overlay_installer._RESOLVER_MOUNT_OLD, resolver)
            self.assertNotIn(overlay_installer._MODEL_ROUTE_OLD, resolver)
            self.assertNotIn(overlay_installer._PREPARE_MOUNT_OLD, prepare)
            self.assertNotIn(overlay_installer._PREPARE_AGENT_IDENTITY_OLD, prepare)

    def test_installed_overlay_modules_import_from_materialized_checkout(self):
        # Regression: since 94dd15d trace.py imports ``..model``.  Copied
        # byte-for-byte into workbuddy_bench.agents that resolved to the
        # non-existent workbuddy_bench.model and every Harbor trial died at
        # agent import.  The installer must ship model.py beside the package
        # and repoint the copy; this proves it by importing the installed
        # modules from a materialized checkout, not by reading the sources.
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            _materialize_pinned_upstream(repo)
            manifest = _install_overlay_into(repo)
            self.assertEqual(
                {
                    path
                    for path in manifest["installed_paths"]
                    if Path(path).name.startswith("_metacodes_")
                },
                {
                    overlay_installer._MODEL_PATH.as_posix(),
                    overlay_installer._TRACE_PATH.as_posix(),
                    overlay_installer._KEY_FD_PATH.as_posix(),
                },
            )
            self.assertEqual(
                (repo / overlay_installer._MODEL_PATH).read_bytes(),
                (Path(__file__).parents[1] / "model.py").read_bytes(),
            )
            installed_trace = (repo / overlay_installer._TRACE_PATH).read_bytes()
            self.assertNotIn(overlay_installer._TRACE_MODEL_IMPORT_OLD, installed_trace)
            self.assertEqual(
                installed_trace.count(overlay_installer._TRACE_MODEL_IMPORT_NEW), 1
            )
            self.assertEqual(
                overlay_installer.validate_installed_overlay(repo)["overlay_sha256"],
                manifest["overlay_sha256"],
            )

            probe = _probe_installed_overlay_imports(repo)
            self.assertEqual(probe.returncode, 0, probe.stderr)
            observed = json.loads(probe.stdout)
            self.assertEqual(
                observed["modules"],
                [
                    "workbuddy_bench._metacodes_model",
                    "workbuddy_bench.agents._metacodes_trace",
                    "workbuddy_bench.proxy._metacodes_key_fd",
                ],
            )
            self.assertEqual(
                Path(observed["trace_file"]).resolve(),
                (repo / overlay_installer._TRACE_PATH).resolve(),
            )
            self.assertTrue(observed["trace_uses_shipped_open_nofollow"])

    def test_unrewritten_trace_copy_fails_to_import_inside_workbuddy_package(self):
        # The probe above has to be able to fail.  Replay the pre-fix installer
        # (a verbatim copy of trace.py) and require the exact failure the
        # Linux trials reported, so a future byte-copy regression is caught by
        # the positive test rather than passing vacuously.
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory).resolve()
            _materialize_pinned_upstream(repo)
            with mock.patch.object(
                overlay_installer,
                "_TRACE_MODEL_IMPORT_NEW",
                overlay_installer._TRACE_MODEL_IMPORT_OLD,
            ):
                _install_overlay_into(repo)
            probe = _probe_installed_overlay_imports(repo)
            self.assertNotEqual(probe.returncode, 0)
            self.assertIn("No module named 'workbuddy_bench.model'", probe.stderr)

    def test_overlay_sources_fail_closed_when_trace_model_import_anchor_drifts(self):
        # If trace.py stops importing ``..model`` on that exact line, the
        # installer must refuse rather than ship whatever the new import is.
        with mock.patch.object(
            overlay_installer,
            "_TRACE_MODEL_IMPORT_OLD",
            b"from ..model import open_nofollow, fsync_directory\n",
        ):
            with self.assertRaisesRegex(
                overlay_installer.OverlayError, "model-import anchor drifted"
            ):
                overlay_installer._overlay_sources()

    def test_adapter_passes_stable_backend_identity_separately_from_route(self):
        source = (
            Path(__file__).parents[1]
            / "workbuddy/overlay/src/workbuddy_bench/agents/metacodes_agent.py"
        ).read_text(encoding="utf-8")
        self.assertIn('kwargs.pop("METACODES_MODEL_DISPLAY_NAME", "")', source)
        self.assertIn('"--model", escaped_model', source)
        self.assertIn('"--model-display-name", escaped_model_display_name', source)
        self.assertIn('"transport_model_is_route": True', source)
        self.assertIn('"actor_model_identity": self._model_display_name', source)
        self.assertIn(
            'kwargs["METACODES_MODEL_DISPLAY_NAME"] = backend_model_name',
            overlay_installer._PREPARE_AGENT_IDENTITY_NEW,
        )

    def test_installed_prepare_job_preserves_route_and_injects_backend_identity(self):
        checkout_raw = os.environ.get("METACODES_WORKBUDDY_CHECKOUT")
        if not checkout_raw:
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        checkout = Path(checkout_raw)
        if not checkout.is_dir():
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        source = checkout / "src/workbuddy_bench/runner/prepare_job.py"
        if not source.is_file():
            self.skipTest("WorkBuddy prepare_job is unavailable")
        route = "paired-control-run--metacodes-glm52"
        program = r'''
import json
from workbuddy_bench.runner.prepare_job import _build_agent_block
row = _build_agent_block(
            harness={
                "name": "metacodes",
                "import_path": "workbuddy_bench.agents.metacodes_agent:MetacodesAgent",
                "params": {},
            },
            model_slug="metacodes-glm52",
            model={"name": "glm-5.2", "params": {}},
            job={},
            manifest={
                "connection": {
                    "effective": "local_proxy",
                    "proxy_url": "http://host.docker.internal:1234",
                },
                "model_connection": "local_proxy",
                "model_route": "paired-control-run--metacodes-glm52",
                "backend_model_name": "glm-5.2",
                "instance_id": "paired-control-run",
            },
        )
print(json.dumps(row))
'''
        env = dict(os.environ)
        env["PYTHONPATH"] = str(checkout / "src")
        completed = subprocess.run(
            [str(checkout / ".venv/bin/python"), "-c", program],
            cwd=checkout,
            env=env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        row = json.loads(completed.stdout)
        self.assertEqual(row["model_name"], route)
        self.assertEqual(
            row["kwargs"]["connection"]["model_route"], route
        )
        self.assertEqual(
            row["kwargs"]["METACODES_MODEL_DISPLAY_NAME"], "glm-5.2"
        )

    def test_installed_proxy_persists_terminal_stream_when_client_closes(self):
        checkout_raw = os.environ.get("METACODES_WORKBUDDY_CHECKOUT")
        if not checkout_raw:
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        checkout = Path(checkout_raw).resolve()
        if not checkout.is_dir():
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        overlay_installer.validate_installed_overlay(checkout)
        program = r'''
import asyncio, json, tempfile
from pathlib import Path
from workbuddy_bench.proxy.config import BackendConfig, ProxyConfig, ProxyMode, RouteConfig
from workbuddy_bench.proxy.interceptors import RequestContext
from workbuddy_bench.proxy.pipeline import Pipeline

TERMINAL = (
    b'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":1}}}\n\n'
    b'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n'
    b'event: message_stop\ndata: {"type":"message_stop"}\n\n'
)

class Sender:
    async def send_stream_raw(self, *args, **kwargs):
        yield TERMINAL

async def main():
    with tempfile.TemporaryDirectory() as directory:
        config = ProxyConfig(log_dir=directory, log_enabled=True)
        route = RouteConfig(
            slug="route", mode=ProxyMode.PASSTHROUGH,
            backend=BackendConfig(url="http://provider.invalid/v1/messages"),
            backend_model="glm-5.2", client_protocol="anthropic",
            backend_protocol="anthropic", interceptors=["log"], instance_id="run-l2",
        )
        config.routes[route.slug] = route
        pipeline = Pipeline(config)
        pipeline.sender = Sender()
        body = {
            "model": "route", "system": "stable",
            "messages": [{"role": "user", "content": "task"}], "stream": True,
        }
        context = RequestContext(
            path="/v1/messages", raw_body=json.dumps(body).encode(),
            parsed_body=dict(body), route=route,
        )
        stream = pipeline.handle_stream(context)
        assert await anext(stream) == TERMINAL
        await stream.aclose()
        rows = [
            json.loads(line)
            for line in (Path(directory) / "run-l2.jsonl").read_text().splitlines()
        ]
        assert len(rows) == 1
        assert rows[0]["seq"] == 1
        assert rows[0]["response"]["status"] == 200
        assert rows[0]["response"]["stop_reason"] == "end_turn"

asyncio.run(main())
'''
        env = dict(os.environ)
        env["PYTHONPATH"] = str(checkout / "src")
        subprocess.run(
            [str(checkout / ".venv/bin/python"), "-c", program],
            cwd=checkout,
            env=env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_installed_a2o_disconnect_before_sender_is_not_provider_attempt(self):
        checkout_raw = os.environ.get("METACODES_WORKBUDDY_CHECKOUT")
        if not checkout_raw:
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        checkout = Path(checkout_raw).resolve()
        if not checkout.is_dir():
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        overlay_installer.validate_installed_overlay(checkout)
        program = r'''
import asyncio, json, tempfile
from pathlib import Path
from workbuddy_bench.proxy.config import BackendConfig, ProxyConfig, ProxyMode, RouteConfig
from workbuddy_bench.proxy.interceptors import RequestContext
from workbuddy_bench.proxy.pipeline import Pipeline

class Sender:
    calls = 0
    async def send_stream(self, *args, **kwargs):
        self.calls += 1
        raise AssertionError("provider sender must not start")
        yield

async def main():
    with tempfile.TemporaryDirectory() as directory:
        config = ProxyConfig(log_dir=directory, log_enabled=True)
        route = RouteConfig(
            slug="route", mode=ProxyMode.A2O,
            backend=BackendConfig(url="http://provider.invalid/v1"),
            backend_model="glm-5.2", client_protocol="anthropic",
            backend_protocol="openai", interceptors=["log"], instance_id="run-l2",
        )
        config.routes[route.slug] = route
        pipeline = Pipeline(config)
        pipeline.sender = Sender()
        body = {
            "model": "route", "system": "stable",
            "messages": [{"role": "user", "content": "task"}], "stream": True,
        }
        context = RequestContext(
            path="/v1/messages", raw_body=json.dumps(body).encode(),
            parsed_body=dict(body), route=route,
        )
        stream = pipeline.handle_stream(context)
        first = await anext(stream)
        assert b"message_start" in first
        await stream.aclose()
        assert pipeline.sender.calls == 0
        log_path = Path(directory) / "run-l2.jsonl"
        assert not log_path.exists() or not log_path.read_text().strip()

asyncio.run(main())
'''
        env = dict(os.environ)
        env["PYTHONPATH"] = str(checkout / "src")
        subprocess.run(
            [str(checkout / ".venv/bin/python"), "-c", program],
            cwd=checkout,
            env=env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_digest_detects_changes_before_owned_overlay_replacement(self):
        rows = [(Path("a"), b"one"), (Path("b"), b"two")]
        before = _digest(rows, {})
        self.assertEqual(before, _digest(list(reversed(rows)), {}))
        self.assertNotEqual(before, _digest([(Path("a"), b"changed"), rows[1]], {}))

    def test_w0_uses_native_no_network_compose(self):
        root = Path(__file__).parents[1] / "workbuddy/overlay/datasets"
        task = root / "metacodes-w0-synthetic/tasks/metacodes-w0-artifact"
        compose = (task / "environment/docker-compose.yaml").read_text(encoding="utf-8")
        config = (task / "task.toml").read_text(encoding="utf-8")
        self.assertIn("network_mode: none", compose)
        self.assertEqual(config.count('network_mode = "public"'), 3)

    def test_w05_uses_docker_supported_public_network_for_loopback_proxy(self):
        task = (
            Path(__file__).parents[1]
            / "workbuddy/overlay/datasets/metacodes-w05-synthetic/tasks"
            / "metacodes-w05-control/task.toml"
        )
        config = task.read_text(encoding="utf-8")
        self.assertEqual(config.count('network_mode = "public"'), 3)
        self.assertNotIn('network_mode = "no-network"', config)
        self.assertNotIn('network_mode = "allowlist"', config)

    def test_paid_code_canary_is_frozen_to_first_three_code_dev_tasks(self):
        root = Path(__file__).parents[1] / "workbuddy"
        overlay = root / "overlay"
        job = yaml.safe_load(
            (overlay / "configs/jobs/metacodes-glm52-code-3-canary.yaml").read_text(
                encoding="utf-8"
            )
        )
        model = yaml.safe_load(
            (overlay / "configs/models/metacodes-glm52.yaml").read_text(
                encoding="utf-8"
            )
        )["model"]
        cohort = json.loads(
            (root / "manifests/workbuddy-v1-cohorts.json").read_text(encoding="utf-8")
        )
        expected = cohort["subsets"]["code"]["cohorts"]["dev"][
            "task_selection"
        ]["names"][:3]
        self.assertEqual(job["task_selection"], {"mode": "name", "names": expected})
        self.assertEqual(job["dataset"], cohort["subsets"]["code"]["dataset"])
        self.assertEqual(job["n_attempts"], 1)
        self.assertTrue(job["record_full_io"])
        self.assertEqual(job["orchestrator_override"]["n_concurrent_trials"], 1)
        self.assertEqual(
            job["harness_params_override"],
            {
                "METACODES_VERIFICATION_CHECKPOINT": False,
                "METACODES_PROJECT_CONTROL_MODE": "enforced",
                "METACODES_PROJECT_RULES_RELATIVE": (
                    "share/metacodes/workbuddy-w05/project-rules"
                ),
                "METACODES_PROJECT_KERNEL_RELATIVE": (
                    "libexec/metacodes-project-kernel"
                ),
            },
        )
        self.assertEqual(model["name"], "glm-5.2")
        self.assertEqual(model["protocols"], ["anthropic"])
        self.assertEqual(
            model["backend_key_env"],
            "METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF",
        )
        self.assertEqual(model["max_concurrent"], 1)
        self.assertEqual(model["context_window"], job["context_window"])

    def test_paid_code_baseline_differs_only_by_control_actuation_and_result_root(self):
        root = Path(__file__).parents[1] / "workbuddy/overlay/configs/jobs"
        baseline = yaml.safe_load(
            (root / "metacodes-glm52-code-3-baseline.yaml").read_text(
                encoding="utf-8"
            )
        )
        treatment = yaml.safe_load(
            (root / "metacodes-glm52-code-3-canary.yaml").read_text(
                encoding="utf-8"
            )
        )
        baseline_root = baseline.pop("jobs_dir")
        treatment_root = treatment.pop("jobs_dir")
        self.assertNotEqual(baseline_root, treatment_root)
        baseline_mode = baseline["harness_params_override"].pop(
            "METACODES_PROJECT_CONTROL_MODE"
        )
        treatment_mode = treatment["harness_params_override"].pop(
            "METACODES_PROJECT_CONTROL_MODE"
        )
        self.assertEqual("disabled", baseline_mode)
        self.assertEqual("enforced", treatment_mode)
        self.assertEqual(treatment, baseline)

    def test_checkpoint_pair_differs_only_by_explicit_boolean_and_result_root(self):
        root = Path(__file__).parents[1] / "workbuddy/overlay/configs/jobs"
        baseline = yaml.safe_load(
            (root / "metacodes-glm52-code-1-checkpoint-baseline.yaml").read_text(
                encoding="utf-8"
            )
        )
        treatment = yaml.safe_load(
            (root / "metacodes-glm52-code-1-checkpoint-treatment.yaml").read_text(
                encoding="utf-8"
            )
        )
        self.assertNotEqual(baseline.pop("jobs_dir"), treatment.pop("jobs_dir"))
        baseline_checkpoint = baseline["harness_params_override"].pop(
            "METACODES_VERIFICATION_CHECKPOINT"
        )
        treatment_checkpoint = treatment["harness_params_override"].pop(
            "METACODES_VERIFICATION_CHECKPOINT"
        )
        self.assertIs(baseline_checkpoint, False)
        self.assertIs(treatment_checkpoint, True)
        self.assertEqual(
            "disabled",
            baseline["harness_params_override"]["METACODES_PROJECT_CONTROL_MODE"],
        )
        self.assertEqual(treatment, baseline)

    def test_adapter_runtime_contract_reobserves_disabled_active_bundle_absence(self):
        source = (
            Path(__file__).parents[1]
            / "workbuddy/overlay/src/workbuddy_bench/agents/metacodes_agent.py"
        ).read_text(encoding="utf-8")
        self.assertIn('test -d "$project_source" || exit 78', source)
        self.assertIn('test -x "$project_kernel" || exit 83', source)
        self.assertIn(
            '/project-rules/active.json" || exit 88',
            source,
        )
        self.assertIn("project_setup += disabled_bundle_check", source)
        self.assertIn("project_postcheck = disabled_bundle_check", source)
        self.assertIn(
            "unset METACODES_PROJECT_KERNEL_PATH METACODES_PROJECT_KERNEL_SHA256",
            source,
        )
        self.assertIn('"artifacts_verified": True', source)
        self.assertIn('"runtime_active_bundle_absent": (', source)

    def test_adapter_repairs_only_the_task_workdir_for_the_non_root_agent(self):
        source = (
            Path(__file__).parents[1]
            / "workbuddy/overlay/src/workbuddy_bench/agents/metacodes_agent.py"
        ).read_text(encoding="utf-8")
        install = source[source.index("    async def install("):source.index(
            "    def _collect_outcomes", source.index("    async def install(")
        )]
        repair = install[install.index("await ensure_agent_user"):]
        self.assertIn('getattr(environment, "default_user", None)', repair)
        self.assertIn('getattr(environment, "task_env_config", None)', repair)
        self.assertIn('target="$(pwd)"', repair)
        self.assertIn("chown", repair)
        self.assertIn("chmod u+rwx", repair)
        self.assertIn("|| true", repair)
        self.assertIn("/tests|/tests/*", repair)
        self.assertIn("/logs/verifier|/logs/verifier/*", repair)
        self.assertIn("*/verifier|*/verifier/*", repair)
        self.assertIn("*/grading|*/grading/*", repair)
        self.assertNotIn("chown -R", repair)

    def test_paid_code_probe_is_frozen_to_first_code_dev_task(self):
        root = Path(__file__).parents[1] / "workbuddy"
        overlay = root / "overlay"
        job = yaml.safe_load(
            (overlay / "configs/jobs/metacodes-glm52-code-1-probe.yaml").read_text(
                encoding="utf-8"
            )
        )
        cohort = json.loads(
            (root / "manifests/workbuddy-v1-cohorts.json").read_text(encoding="utf-8")
        )
        expected = cohort["subsets"]["code"]["cohorts"]["dev"][
            "task_selection"
        ]["names"][:1]
        self.assertEqual(job["task_selection"], {"mode": "name", "names": expected})
        self.assertEqual(job["n_attempts"], 1)
        self.assertEqual(job["orchestrator_override"]["n_concurrent_trials"], 1)
        self.assertTrue(job["record_full_io"])
        self.assertEqual(
            job["harness_params_override"],
            {
                "METACODES_VERIFICATION_CHECKPOINT": False,
                "METACODES_PROJECT_CONTROL_MODE": "enforced",
                "METACODES_PROJECT_RULES_RELATIVE": (
                    "share/metacodes/workbuddy-w05/project-rules"
                ),
                "METACODES_PROJECT_KERNEL_RELATIVE": (
                    "libexec/metacodes-project-kernel"
                ),
            },
        )


class WorkBuddyCredentialFdTest(unittest.TestCase):
    def setUp(self):
        _SECRET_CACHE.clear()

    def tearDown(self):
        _SECRET_CACHE.clear()

    def test_fd_reference_consumes_once_clears_environment_and_supports_shared_routes(self):
        read_fd, write_fd = os.pipe()
        os.write(write_fd, b"private-test-key")
        os.close(write_fd)
        with mock.patch.dict(os.environ, {"WB_TEST_KEY": f"fd://{read_fd}"}, clear=False):
            first = resolve_secret_env("", "WB_TEST_KEY")
            second = resolve_secret_env("", "WB_TEST_KEY")
            self.assertEqual(first, "private-test-key")
            self.assertEqual(second, first)
            self.assertNotIn("WB_TEST_KEY", os.environ)
            with self.assertRaises(OSError):
                os.fstat(read_fd)

    def test_normal_workbuddy_environment_key_remains_compatible(self):
        with mock.patch.dict(os.environ, {"WB_TEST_PLAIN": "ordinary-test-key"}):
            self.assertEqual(resolve_secret_env("", "WB_TEST_PLAIN"), "ordinary-test-key")
        with mock.patch.dict(
            os.environ,
            {"METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF": "raw-key-is-forbidden"},
        ):
            with self.assertRaisesRegex(CredentialFdError, "requires an anonymous"):
                resolve_secret_env("", "METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF")

    def test_invalid_or_oversized_descriptor_fails_closed(self):
        with mock.patch.dict(os.environ, {"WB_TEST_BAD": "fd://not-a-number"}):
            with self.assertRaisesRegex(CredentialFdError, "invalid"):
                resolve_secret_env("", "WB_TEST_BAD")
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "oversized-key"
            source.write_bytes(b"x" * (16 * 1024 + 1))
            read_fd = os.open(source, os.O_RDONLY)
            with mock.patch.dict(os.environ, {"WB_TEST_LARGE": f"fd://{read_fd}"}):
                with self.assertRaisesRegex(CredentialFdError, "exceeds"):
                    resolve_secret_env("", "WB_TEST_LARGE")


class WorkBuddyCohortManifestTest(unittest.TestCase):
    @staticmethod
    def _archive(path: Path, dataset_id: str, slugs: list[str], *, reverse: bool = False):
        ordered = list(reversed(slugs)) if reverse else slugs
        with tarfile.open(path, "w:gz") as archive:
            for slug in ordered:
                payload = b"\xff\x00body-must-not-be-parsed"
                member = tarfile.TarInfo(f"{dataset_id}/tasks/{slug}/task.toml")
                member.size = len(payload)
                archive.addfile(member, io.BytesIO(payload))
                instruction = tarfile.TarInfo(
                    f"{dataset_id}/tasks/{slug}/instruction.md"
                )
                instruction.size = 7
                archive.addfile(instruction, io.BytesIO(b"private"))

    def _fixtures(self, root: Path, *, reverse: bool = False):
        archives = {}
        sums = {}
        for subset in SUBSETS:
            path = root / subset.archive
            slugs = [f"{subset.name}-task-{index:03}" for index in range(subset.task_count)]
            self._archive(path, subset.dataset_id, slugs, reverse=reverse)
            archives[subset.name] = path
            sums[subset.archive] = hashlib.sha256(path.read_bytes()).hexdigest()
        return archives, sums

    def test_fixed_split_is_exhaustive_disjoint_and_workbuddy_consumable(self):
        with tempfile.TemporaryDirectory() as directory:
            archives, sums = self._fixtures(Path(directory))
            manifest = build_manifest(archives=archives, expected_sums=sums)
        self.assertFalse(manifest["quality_evidence"])
        self.assertFalse(
            manifest["contamination_boundary"]["task_payload_exposed_to_generator"]
        )
        self.assertEqual(
            manifest["cohort_totals"],
            {"dev": 52, "promotion_a": 26, "promotion_b": 26, "sealed": 156},
        )
        for subset in SUBSETS:
            rows = manifest["subsets"][subset.name]
            assigned = []
            for cohort, expected_count in subset.cohort_counts:
                selection = rows["cohorts"][cohort]["task_selection"]
                self.assertEqual(selection["mode"], "name")
                self.assertEqual(len(selection["names"]), expected_count)
                assigned.extend(selection["names"])
            self.assertEqual(len(assigned), len(set(assigned)))
            self.assertEqual(len(assigned), subset.task_count)

    def test_member_order_cannot_change_partition(self):
        with tempfile.TemporaryDirectory() as first_dir, tempfile.TemporaryDirectory() as second_dir:
            first, first_sums = self._fixtures(Path(first_dir))
            second, second_sums = self._fixtures(Path(second_dir), reverse=True)
            a = build_manifest(archives=first, expected_sums=first_sums)
            b = build_manifest(archives=second, expected_sums=second_sums)
        for subset in SUBSETS:
            self.assertEqual(
                a["subsets"][subset.name]["cohorts"],
                b["subsets"][subset.name]["cohorts"],
            )

    def test_checksum_mismatch_and_linked_task_metadata_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archives, sums = self._fixtures(root)
            sums[SUBSETS[0].archive] = "0" * 64
            with self.assertRaisesRegex(CohortError, "checksum mismatch"):
                build_manifest(archives=archives, expected_sums=sums)

            subset = SUBSETS[0]
            linked = root / "linked.tar.gz"
            with tarfile.open(linked, "w:gz") as archive:
                for index in range(subset.task_count):
                    member = tarfile.TarInfo(
                        f"{subset.dataset_id}/tasks/code-task-{index:03}/task.toml"
                    )
                    member.type = tarfile.SYMTYPE
                    member.linkname = "elsewhere"
                    archive.addfile(member)
            archives[subset.name] = linked
            sums[subset.archive] = hashlib.sha256(linked.read_bytes()).hexdigest()
            with self.assertRaisesRegex(CohortError, "not a regular file"):
                build_manifest(archives=archives, expected_sums=sums)

if __name__ == "__main__":
    unittest.main()


class WorkBuddyGateRecordTest(unittest.TestCase):
    """The gate record is a closed two-era roster (v1 outcome, v2 tiers)."""

    def _metrics(self, gate):
        rows = [
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 0, "monotonic_elapsed_ns": 1,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"run_started": {}}},
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 1, "monotonic_elapsed_ns": 2,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"tool_observation": {"verification_final_gate": gate}}},
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 2, "monotonic_elapsed_ns": 3,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"run_finished": {}}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "observation.jsonl"
            transcript.write_text("", encoding="utf-8")
            observation.write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )
            return load_control_metrics(transcript, observation)

    def test_v1_gate_record_stays_readable(self):
        lean = self._metrics({
            "schema_version": "metacodes-verification-final-gate-v1",
            "enforced": True, "mutations_occurred": True,
            "obligation_met": False, "nudges": 2, "max_nudges": 2,
        })["lean"]
        self.assertEqual(lean["verification_final_gate_records"], 1)
        self.assertEqual(lean["verification_nudges"], 2)
        self.assertNotIn("verification_tier1_verifications", lean)

    def test_v2_gate_record_exports_tier_and_churn_counters(self):
        lean = self._metrics({
            "schema_version": "metacodes-verification-final-gate-v2",
            "enforced": True, "mutations_occurred": True,
            "obligation_met": True, "nudges": 1, "max_nudges": 2,
            "tier1_verifications": 0, "tier2_verifications": 2,
            "reopened_after_verification": 1, "known_failing": False,
        })["lean"]
        self.assertEqual(lean["verification_tier1_verifications"], 0)
        self.assertEqual(lean["verification_tier2_verifications"], 2)
        self.assertEqual(lean["verification_reopened_after_verification"], 1)
        self.assertEqual(lean["verification_known_failing"], 0)

    def test_v3_gate_record_exports_freshness_sensors(self):
        # PO-V2 M4 observe sensors: green-rerun count + closing evidence tier.
        lean = self._metrics({
            "schema_version": "metacodes-verification-final-gate-v3",
            "enforced": True, "mutations_occurred": True,
            "obligation_met": True, "nudges": 0, "max_nudges": 2,
            "tier1_verifications": 2, "tier2_verifications": 0,
            "reopened_after_verification": 0, "known_failing": False,
            "redundant_verifications": 1, "final_closure_tier": 1,
        })["lean"]
        self.assertEqual(lean["verification_tier1_verifications"], 2)
        self.assertEqual(lean["verification_redundant_verifications"], 1)
        self.assertEqual(lean["verification_final_closure_tier"], 1)

    def test_v3_gate_record_missing_sensors_fails_loudly(self):
        with self.assertRaisesRegex(TraceError, "freshness sensors are invalid"):
            self._metrics({
                "schema_version": "metacodes-verification-final-gate-v3",
                "enforced": True, "mutations_occurred": True,
                "obligation_met": True, "nudges": 0, "max_nudges": 2,
                "tier1_verifications": 1, "tier2_verifications": 0,
                "reopened_after_verification": 0, "known_failing": False,
            })

    def test_v2_gate_record_with_bad_tier_count_fails_loudly(self):
        with self.assertRaisesRegex(TraceError, "tier-2 count is invalid"):
            self._metrics({
                "schema_version": "metacodes-verification-final-gate-v2",
                "enforced": True, "mutations_occurred": True,
                "obligation_met": True, "nudges": 0, "max_nudges": 2,
                "tier1_verifications": 0, "tier2_verifications": "two",
                "reopened_after_verification": 0, "known_failing": False,
            })


class WorkBuddyMemoryContinuityTest(unittest.TestCase):
    """Arm-level TinyKG store continuity (V7): empty start, hash-chained
    ledger, single-transaction rotation, fail-loud on a broken chain."""

    def _run_program(self, program: str) -> None:
        checkout_raw = os.environ.get("METACODES_WORKBUDDY_CHECKOUT")
        if not checkout_raw:
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        checkout = Path(checkout_raw).resolve()
        if not checkout.is_dir():
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        # The checkout's installed overlay is the code under test (the repo
        # source tree is a namespace portion that a regular installed package
        # would shadow anyway); installation identity is verified first.
        overlay_installer.validate_installed_overlay(checkout)
        env = dict(os.environ)
        env["PYTHONPATH"] = str(checkout / "src")
        subprocess.run(
            [str(checkout / ".venv/bin/python"), "-c", program],
            cwd=checkout,
            env=env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_continuity_lifecycle_empty_start_then_chained_import(self):
        self._run_program(r'''
import asyncio, hashlib, json, tarfile, tempfile
from pathlib import Path
from workbuddy_bench.agents import metacodes_agent as module
from workbuddy_bench.agents.metacodes_agent import MetacodesAgent

class StubEnvironment:
    """The continuity channel is the /logs/agent bind mount; the environment
    object needs no transfer API at all."""

def make_agent(logs, **extra):
    return MetacodesAgent(
        logs, model_name="route-l2", model_params={},
        METACODES_MODEL_DISPLAY_NAME="glm-5.2",
        connection={"mode": "local_proxy", "proxy_url": "http://127.0.0.1:1"},
        METACODES_MEMORY_ACCUMULATION=True, **extra,
    )

def store_tar(payload: bytes) -> bytes:
    with tempfile.TemporaryDirectory() as d:
        store = Path(d) / "store"
        store.mkdir()
        (store / "events.bin").write_bytes(payload)
        out = Path(d) / "out.tar"
        with tarfile.open(out, "w") as tar:
            tar.add(store, arcname="store")
        return out.read_bytes()

with tempfile.TemporaryDirectory() as directory:
    jobs = Path(directory) / "results" / "arm-slug"
    logs1 = jobs / "batch-1" / "task-a__x1" / "agent"
    logs1.mkdir(parents=True)
    export1 = store_tar(b"first-trial-store")
    exports = {}
    captured = {}
    def exec_for(logs):
        async def fake_exec(environment, command, env, cwd):
            captured["command"] = command
            # The container-side export lands on the bind mount.
            (logs / "kg-export.tar").write_bytes(exports[logs])
        return fake_exec
    agent1 = make_agent(logs1)
    exports[logs1] = export1
    agent1.exec_as_agent = exec_for(logs1)
    asyncio.run(agent1.run("instruction", StubEnvironment(), None))
    command1 = captured["command"]
    # Empty start keeps the absent-store assertion and stages no import.
    assert 'test ! -e "$METACODES_KG_STORE" || exit 85' in command1
    assert "kg-import.tar" not in command1
    assert not (logs1 / "kg-import.tar").exists()
    assert "tar -cf /logs/agent/kg-export.tar" in command1
    contract = json.loads((logs1 / "metacodes-runtime-contract.json").read_text()) if (logs1 / "metacodes-runtime-contract.json").exists() else None
    root = jobs / "kg-store-continuity"
    ledger = [json.loads(l) for l in (root / "ledger.jsonl").read_text().splitlines()]
    assert len(ledger) == 1 and ledger[0]["import_sha256"] == "empty"
    sha1 = hashlib.sha256(export1).hexdigest()
    assert ledger[0]["export_sha256"] == sha1
    assert (root / "store-latest.tar").read_bytes() == export1

    # Trial 2 imports the chained tar with a hash witness in the command.
    logs2 = jobs / "batch-1" / "task-b__x2" / "agent"
    logs2.mkdir(parents=True)
    export2 = store_tar(b"second-trial-store")
    agent2 = make_agent(logs2)
    exports[logs2] = export2
    agent2.exec_as_agent = exec_for(logs2)
    asyncio.run(agent2.run("instruction", StubEnvironment(), None))
    command2 = captured["command"]
    assert sha1 in command2
    assert "tar -xf /logs/agent/kg-import.tar" in command2
    assert 'test ! -e "$METACODES_KG_STORE" || exit 85' not in command2
    assert (logs2 / "kg-import.tar").read_bytes() == export1
    ledger = [json.loads(l) for l in (root / "ledger.jsonl").read_text().splitlines()]
    assert len(ledger) == 2 and ledger[1]["import_sha256"] == sha1
    assert (root / "store-latest.tar").read_bytes() == export2

    # A tampered tar breaks the chain and fails loud before any upload.
    (root / "store-latest.tar").write_bytes(b"tampered")
    logs3 = jobs / "batch-1" / "task-c__x3" / "agent"
    logs3.mkdir(parents=True)
    agent3 = make_agent(logs3)
    exports[logs3] = b""
    agent3.exec_as_agent = exec_for(logs3)
    try:
        asyncio.run(agent3.run("instruction", StubEnvironment(), None))
    except ValueError as error:
        assert "chain is broken" in str(error)
    else:
        raise AssertionError("broken continuity chain was accepted")
''')

    def test_outcome_feedback_exports_task_hint_and_outcomes_together(self):
        """p3/p4 生产事故回归钉:TASK_OUTCOMES 的 `outcomes_env = (...)` 赋值
        把先前追加的 METACODES_TASK_HINT 导出整个覆盖,确定性同题注入从未
        发生。两个导出必须共存,且 hint 取 config.json task.path 的 basename,
        结局文件带结构化错题名。"""
        self._run_program(r'''
import asyncio, json, tempfile
from pathlib import Path
from workbuddy_bench.agents.metacodes_agent import MetacodesAgent

class StubEnvironment:
    pass

with tempfile.TemporaryDirectory() as directory:
    jobs = Path(directory) / "results" / "arm-slug"
    # 已完成的兄弟 trial:_collect_outcomes 的素材(结构化 tests[] 名字)。
    done = jobs / "batch-1" / "etag_task__prev1"
    (done / "verifier").mkdir(parents=True)
    (done / "result.json").write_text(json.dumps({"task_name": "workbuddy/feature-medium-etag_header_for_static"}))
    (done / "verifier" / "score.json").write_text(json.dumps({
        "reward": 0.27, "tests_passed": 3, "tests_total": 11,
        "judges": [{"metadata": {"raw": {"tests": [
            {"name": "etag present", "passed": False},
            {"name": "cache hit 304", "passed": False},
            {"name": "cli exits", "passed": True},
        ]}}}],
    }))
    # 结构化名是散文名(非 node id):理由匹配走 ("", name) 回退键。
    (done / "verifier" / "results.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?><testsuites><testsuite>'
        '<testcase classname="suite" name="etag present">'
        '<failure message="assert 66 == 18, shape">'
        'self = x\n&gt;           etag = calc(Path(f.name))\nE  TypeError'
        '</failure></testcase>'
        '</testsuite></testsuites>'
    )
    # pytest 面兄弟 trial:无结构化 tests[],走 FAILED/SKIPPED 行回退
    # (p4 etag 取证:SKIPPED=实现不在预期位置,此前被当无名丢弃)。
    done2 = jobs / "batch-1" / "pytest_task__prev2"
    (done2 / "verifier").mkdir(parents=True)
    (done2 / "result.json").write_text(json.dumps({"task_name": "workbuddy/bugfix-pytest-task"}))
    (done2 / "verifier" / "score.json").write_text(json.dumps({
        "reward": 0.27, "tests_passed": 3, "tests_total": 11, "judges": [],
    }))
    (done2 / "verifier" / "test_output.txt").write_text(
        "FAILED testing/test_x.py::test_a\n"
        "tests/test_y.py::TestM::test_module_exists SKIPPED [  9%]\n"
    )
    # 理由通道(p11 取证:skip message 携带名字推不出的模块路径;失败
    # message 携带断言形状)。消息里的方括号/逗号必须被清洗(failing=[...]
    # 括号定界 + ", " 列表分割)。
    (done2 / "verifier" / "results.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?><testsuites><testsuite>'
        '<testcase classname="tests.test_y.TestM" name="test_module_exists">'
        '<skipped type="pytest.skip" message="widget._helpers not available, create [it] first"/></testcase>'
        '</testsuite></testsuites>'
    )
    # 自我历史对质:上次 transcript 的收尾结论进结局行(单行化+剥方括号)。
    (done2 / "agent").mkdir()
    (done2 / "agent" / "metacodes-transcript.jsonl").write_text(
        json.dumps({"role": "assistant", "blocks": [{"type": "text",
            "text": "Done. I concluded the [skipped] file was stale\nand kept my approach unchanged for now, see summary."}]}) + "\n"
    )
    # 当前 trial:config.json 是任务全名的权威来源。
    trial = jobs / "batch-1" / "etag_task__now1"
    logs = trial / "agent"
    logs.mkdir(parents=True)
    (trial / "config.json").write_text(json.dumps({
        "task": {"path": ".workspace/staged/wb/tasks/feature-medium-etag_header_for_static", "source": "tasks"},
    }))
    captured = {}
    async def fake_exec(environment, command, env, cwd):
        captured["command"] = command
        (logs / "kg-export.tar").write_bytes(b"")
    agent = MetacodesAgent(
        logs, model_name="route-l2", model_params={},
        METACODES_MODEL_DISPLAY_NAME="glm-5.2",
        connection={"mode": "local_proxy", "proxy_url": "http://127.0.0.1:1"},
        METACODES_MEMORY_ACCUMULATION=True,
        METACODES_SELF_EVOLUTION=True,
        METACODES_OUTCOME_FEEDBACK=True,
        METACODES_PROJECT_CONTROL_MODE="enforced",
        METACODES_PROJECT_RULES_RELATIVE="share/metacodes/workbuddy-w05/project-rules",
        METACODES_PROJECT_KERNEL_RELATIVE="libexec/metacodes-project-kernel",
    )
    agent.exec_as_agent = fake_exec
    asyncio.run(agent.run("instruction", StubEnvironment(), None))
    command = captured["command"]
    assert "export METACODES_TASK_HINT=feature-medium-etag_header_for_static; " in command, command[:2000]
    assert "export METACODES_TASK_OUTCOMES=/logs/agent/task-outcomes.json; " in command
    # stderr 必须落到 trial 导出的 bind mount(p3 取证:warn 诊断链进虚空)。
    assert "2> >(tee /logs/agent/metacodes-stderr.log >&2)" in command
    # 运行期实时事件流:output.jsonl 必须边跑边长,外部看护才能止损
    # (p10 值守只能靠 proxy 日志/容器 CPU 侧写)。result 行消费侧
    # (trace.final_result)按 type=="result" 过滤,增量行前向兼容。
    assert " --json --stream-json " in command
    rows = json.loads((logs / "task-outcomes.json").read_text())["outcomes"]
    by_task = {r["task"]: r for r in rows}
    assert set(by_task) == {"feature-medium-etag_header_for_static", "bugfix-pytest-task"}, rows
    assert by_task["feature-medium-etag_header_for_static"]["failing_tests"] == [
        "etag present (failed: assert 66 == 18; shape AT test code: etag = calc(Path(f.name)))",
        "cache hit 304",
    ], rows
    assert by_task["bugfix-pytest-task"]["failing_tests"] == [
        "testing/test_x.py::test_a",
        "tests/test_y.py::TestM::test_module_exists (skipped: widget._helpers not available; create (it) first)",
    ], rows
    note = by_task["bugfix-pytest-task"]["final_note"]
    assert "(skipped) file was stale and kept my approach" in note and "[" not in note, note
    assert "final_note" not in by_task["feature-medium-etag_header_for_static"], rows
''')

    def test_accumulation_off_keeps_the_original_contract(self):
        self._run_program(r'''
import asyncio, json, tempfile
from pathlib import Path
from workbuddy_bench.agents.metacodes_agent import MetacodesAgent

with tempfile.TemporaryDirectory() as directory:
    logs = Path(directory) / "results" / "arm" / "batch" / "task__x" / "agent"
    logs.mkdir(parents=True)
    agent = MetacodesAgent(
        logs, model_name="route-l2", model_params={},
        METACODES_MODEL_DISPLAY_NAME="glm-5.2",
        connection={"mode": "local_proxy", "proxy_url": "http://127.0.0.1:1"},
    )
    captured = {}
    async def fake_exec(environment, command, env, cwd):
        captured["command"] = command
    agent.exec_as_agent = fake_exec
    class StubEnvironment:
        pass
    asyncio.run(agent.run("instruction", StubEnvironment(), None))
    command = captured["command"]
    assert 'test ! -e "$METACODES_KG_STORE" || exit 85' in command
    assert "kg-export.tar" not in command and "kg-import.tar" not in command
    assert not (Path(directory) / "results" / "arm" / "kg-store-continuity").exists()
''')


class WorkBuddyProgressRejectionTest(unittest.TestCase):
    """Pre-dispatch rejections (permission denials) legitimately appear only
    in the transcript; a transcript-only call with a SUCCESS result stays a
    fail-closed ledger hole."""

    def _run(self, result_content, is_error=True):
        from scripts.eval.workbuddy.progress_analysis import analyze_progress
        rows = [
            {"role": "assistant", "blocks": [{
                "type": "tool_use", "id": "denied-1", "name": "Task",
                "input": "{}",
            }]},
            {"role": "user", "blocks": [{
                "type": "tool_result", "tool_use_id": "denied-1",
                "content": result_content, "is_error": is_error,
            }]},
        ]
        journal = [
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 0, "monotonic_elapsed_ns": 1,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"run_started": {}}},
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 1, "monotonic_elapsed_ns": 2,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"run_finished": {}}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "t.jsonl"
            observation = root / "o.jsonl"
            self._write(transcript, rows)
            self._write(observation, journal)
            return analyze_progress(transcript, observation)

    @staticmethod
    def _write(path, rows):
        path.write_text(
            "".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8"
        )

    def test_permission_denied_call_is_a_legitimate_non_dispatch(self):
        metrics = self._run(json.dumps({
            "error": {"code": "permission_denied", "category": "safety",
                      "detail": "tool 'Task' denied", "recoverable": False},
        }))
        self.assertEqual(metrics["progress"]["tool_calls"], 0)

    def test_successful_transcript_only_call_stays_a_ledger_hole(self):
        with self.assertRaisesRegex(TraceError, "identities differ"):
            self._run(json.dumps({"ok": True}), is_error=False)

    def test_invalid_args_rejection_is_a_legitimate_non_dispatch(self):
        metrics = self._run(json.dumps({
            "error": {"code": "invalid_args", "category": "user_error",
                      "detail": "Write failed with MissingFilePath",
                      "recoverable": True},
        }))
        self.assertEqual(metrics["progress"]["tool_calls"], 0)

    def test_unrecognized_error_shape_stays_fail_closed(self):
        with self.assertRaisesRegex(TraceError, "identities differ"):
            self._run(json.dumps({
                "error": {"code": "other", "category": "system_error",
                          "detail": "x", "recoverable": True},
            }))


class WorkBuddyRequirementLedgerRecordTest(unittest.TestCase):
    """Field-level contract for the requirement-ledger journal record (the
    union-roster probe only proves the KIND is known)."""

    def _metrics(self, ledger):
        rows = [
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 0, "monotonic_elapsed_ns": 1,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"run_started": {}}},
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 1, "monotonic_elapsed_ns": 2,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"tool_observation": {"requirement_ledger": ledger}}},
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 2, "monotonic_elapsed_ns": 3,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"run_finished": {}}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "t.jsonl"
            observation = root / "o.jsonl"
            transcript.write_text("", encoding="utf-8")
            observation.write_text(
                "".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8"
            )
            return load_control_metrics(transcript, observation)

    def _valid(self):
        return {
            "schema_version": "metacodes-requirement-ledger-v1",
            "enforced": True, "prompt_emitted": True,
            "items_total": 3, "items_open_at_final": 1,
            "mutations_occurred": True, "nudges": 2, "max_nudges": 2,
        }

    def test_valid_record_exports_counters(self):
        lean = self._metrics(self._valid())["lean"]
        self.assertEqual(lean["requirement_ledger_records"], 1)
        self.assertEqual(lean["requirement_ledger_enforced"], 1)
        self.assertEqual(lean["requirement_ledger_prompted"], 1)
        self.assertEqual(lean["requirement_ledger_items_total"], 3)
        self.assertEqual(lean["requirement_ledger_items_open_at_final"], 1)
        self.assertEqual(lean["requirement_ledger_nudges"], 2)

    def test_malformed_count_fails_loudly(self):
        bad = self._valid()
        bad["items_open_at_final"] = "one"
        with self.assertRaisesRegex(TraceError, "ledger open count"):
            self._metrics(bad)

    def test_wrong_schema_fails_loudly(self):
        bad = self._valid()
        bad["schema_version"] = "metacodes-requirement-ledger-v0"
        with self.assertRaisesRegex(TraceError, "requirement ledger record"):
            self._metrics(bad)


class WorkBuddyDeliveryCadenceRecordTest(unittest.TestCase):
    """Field-level contract for the delivery-cadence journal record (the
    union-roster probe only proves the KIND is known)."""

    def _metrics(self, cadence):
        rows = [
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 0, "monotonic_elapsed_ns": 1,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"run_started": {}}},
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 1, "monotonic_elapsed_ns": 2,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"tool_observation": {"delivery_cadence": cadence}}},
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 2, "monotonic_elapsed_ns": 3,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"run_finished": {}}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "t.jsonl"
            observation = root / "o.jsonl"
            transcript.write_text("", encoding="utf-8")
            observation.write_text(
                "".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8"
            )
            return load_control_metrics(transcript, observation)

    def _valid(self):
        return {
            "schema_version": "metacodes-delivery-cadence-v1",
            "enforced": True, "exploration_calls": 57,
            "mutations_occurred": False, "levels_reached": 2,
            "nudges": 2, "max_nudges": 2,
            "first_threshold": 40, "second_threshold": 80,
        }

    def test_valid_record_exports_counters(self):
        lean = self._metrics(self._valid())["lean"]
        self.assertEqual(lean["delivery_cadence_records"], 1)
        self.assertEqual(lean["delivery_cadence_enforced"], 1)
        self.assertEqual(lean["delivery_cadence_mutations_occurred"], 0)
        self.assertEqual(lean["delivery_cadence_exploration_calls"], 57)
        self.assertEqual(lean["delivery_cadence_levels_reached"], 2)
        self.assertEqual(lean["delivery_cadence_nudges"], 2)
        self.assertEqual(lean["delivery_cadence_max_nudges"], 2)
        self.assertEqual(lean["delivery_cadence_first_threshold"], 40)
        self.assertEqual(lean["delivery_cadence_second_threshold"], 80)

    def test_observe_record_exports_zero_nudges_with_crossings(self):
        record = self._valid()
        record["enforced"] = False
        record["nudges"] = 0
        lean = self._metrics(record)["lean"]
        self.assertEqual(lean["delivery_cadence_enforced"], 0)
        self.assertEqual(lean["delivery_cadence_levels_reached"], 2)
        self.assertEqual(lean["delivery_cadence_nudges"], 0)

    def test_malformed_count_fails_loudly(self):
        bad = self._valid()
        bad["exploration_calls"] = "many"
        with self.assertRaisesRegex(TraceError, "exploration calls"):
            self._metrics(bad)

    def test_wrong_schema_fails_loudly(self):
        bad = self._valid()
        bad["schema_version"] = "metacodes-delivery-cadence-v0"
        with self.assertRaisesRegex(TraceError, "delivery cadence record"):
            self._metrics(bad)

    def test_duplicate_record_fails_loudly(self):
        rows_record = self._valid()
        rows = [
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 0, "monotonic_elapsed_ns": 1,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"run_started": {}}},
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 1, "monotonic_elapsed_ns": 2,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"tool_observation": {"delivery_cadence": rows_record}}},
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 2, "monotonic_elapsed_ns": 3,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"tool_observation": {"delivery_cadence": rows_record}}},
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 3, "monotonic_elapsed_ns": 4,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"run_finished": {}}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "t.jsonl"
            observation = root / "o.jsonl"
            transcript.write_text("", encoding="utf-8")
            observation.write_text(
                "".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8"
            )
            with self.assertRaisesRegex(TraceError, "duplicate delivery cadence"):
                load_control_metrics(transcript, observation)


class WorkBuddyRequirementLedgerTreatmentTest(unittest.TestCase):
    """The requirement-ledger treatment kwargs are wired end to end: the
    adapter validates them, emits the CLI flags, and discloses them in the
    runtime contract."""

    @staticmethod
    def _source() -> str:
        return (
            Path(__file__).parents[1]
            / "workbuddy/overlay/src/workbuddy_bench/agents/metacodes_agent.py"
        ).read_text(encoding="utf-8")

    def test_ledger_kwargs_reach_flags_and_runtime_contract(self):
        source = self._source()
        self.assertIn('kwargs.pop("METACODES_REQUIREMENT_LEDGER", False)', source)
        self.assertIn(
            'kwargs.pop("METACODES_REQUIREMENT_LEDGER_OBSERVE", False)', source
        )
        self.assertIn('flags.append("--requirement-ledger")', source)
        self.assertIn('flags.append("--requirement-ledger-observe")', source)
        self.assertIn(
            '"requirement_ledger": self._requirement_ledger,', source
        )
        self.assertIn(
            '"requirement_ledger_observe": self._requirement_ledger_observe,',
            source,
        )

    def test_ledger_enforce_and_observe_are_exclusive_in_the_real_adapter(self):
        checkout_raw = os.environ.get("METACODES_WORKBUDDY_CHECKOUT")
        if not checkout_raw:
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        checkout = Path(checkout_raw).resolve()
        if not checkout.is_dir():
            self.skipTest("pinned WorkBuddy checkout is unavailable")
        overlay_installer.validate_installed_overlay(checkout)
        program = r'''
import tempfile
from pathlib import Path
from workbuddy_bench.agents.metacodes_agent import MetacodesAgent

with tempfile.TemporaryDirectory() as directory:
    logs = Path(directory) / "trial" / "agent"
    logs.mkdir(parents=True)
    common = dict(
        model_name="route-l2", model_params={},
        METACODES_MODEL_DISPLAY_NAME="glm-5.2",
        connection={"mode": "local_proxy", "proxy_url": "http://127.0.0.1:1"},
    )
    agent = MetacodesAgent(
        logs, METACODES_REQUIREMENT_LEDGER=True, **common,
    )
    assert agent._requirement_ledger is True
    assert agent._requirement_ledger_observe is False
    try:
        MetacodesAgent(
            logs,
            METACODES_REQUIREMENT_LEDGER=True,
            METACODES_REQUIREMENT_LEDGER_OBSERVE=True,
            **common,
        )
    except ValueError as error:
        assert "mutually exclusive" in str(error), error
    else:
        raise AssertionError("exclusive ledger modes were accepted")
    try:
        MetacodesAgent(
            logs, METACODES_REQUIREMENT_LEDGER="yes", **common,
        )
    except ValueError as error:
        assert "explicit booleans" in str(error), error
    else:
        raise AssertionError("non-boolean ledger treatment was accepted")
'''
        env = dict(os.environ)
        env["PYTHONPATH"] = str(checkout / "src")
        subprocess.run(
            [str(checkout / ".venv/bin/python"), "-c", program],
            cwd=checkout,
            env=env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )


class ContinuityExportGateTest(unittest.TestCase):
    """v42 导出门:只有通过容器内深探针的导出才推进 store-latest.tar。

    p41 取证:trial 1 的 GC 删除把店写进引擎读不回的状态,无门导出把毒店
    推进链头,整臂 + 以其为种子的后代 trial 的记忆系统静默死亡(15/16
    InvalidRecord 全灭)。这里对提取出的 `_advance_continuity_chain` 真实
    代码对象做行为断言:探针不过/收据缺失 → 链不推进 + 降级账本行保持
    链头 = 保留 tar 的 sha(下一 trial 的导入见证仍闭合)。
    """

    @staticmethod
    def _helpers():
        source = (
            Path(__file__).parents[1]
            / "workbuddy/overlay/src/workbuddy_bench/agents/metacodes_agent.py"
        ).read_text(encoding="utf-8")
        tree = ast.parse(source)
        wanted = {"_advance_continuity_chain", "_read_continuity_ledger"}
        consts = {
            "_CONTINUITY_DIRNAME",
            "_CONTINUITY_TAR",
            "_CONTINUITY_LEDGER",
            "_MAX_CONTINUITY_TAR_BYTES",
        }
        body = []
        for node in tree.body:
            if isinstance(node, ast.FunctionDef) and node.name in wanted:
                body.append(node)
            elif isinstance(node, ast.Assign) and any(
                getattr(target, "id", None) in consts for target in node.targets
            ):
                body.append(node)
        module = ast.Module(body=body, type_ignores=[])
        namespace = {"hashlib": hashlib, "json": json, "os": os, "Path": Path}
        exec(compile(module, "<continuity-gate>", "exec"), namespace)
        return namespace

    def _dirs(self):
        holder = tempfile.TemporaryDirectory()
        self.addCleanup(holder.cleanup)
        base = Path(holder.name)
        logs = base / "logs"
        logs.mkdir()
        croot = base / "kg-store-continuity"
        croot.mkdir()
        return logs, croot

    def test_export_probe_pass_advances_chain(self):
        ns = self._helpers()
        logs, croot = self._dirs()
        (logs / "kg-export.tar").write_bytes(b"TAR-ONE")
        (logs / "kg-export-probe.rc").write_text("0", encoding="utf-8")
        ns["_advance_continuity_chain"](logs, croot, "trialA", None)
        self.assertEqual((croot / "store-latest.tar").read_bytes(), b"TAR-ONE")
        rows = [
            json.loads(line)
            for line in (croot / "ledger.jsonl").read_text().splitlines()
        ]
        self.assertEqual(len(rows), 1)
        self.assertEqual(
            rows[0]["export_sha256"], hashlib.sha256(b"TAR-ONE").hexdigest()
        )
        self.assertEqual(rows[0]["import_sha256"], "empty")
        self.assertNotIn("degraded", rows[0])

    def test_export_probe_failure_keeps_previous_tar_and_writes_degraded_row(self):
        ns = self._helpers()
        logs, croot = self._dirs()
        good_sha = hashlib.sha256(b"GOOD-TAR").hexdigest()
        (croot / "store-latest.tar").write_bytes(b"GOOD-TAR")
        (croot / "ledger.jsonl").write_text(
            json.dumps(
                {
                    "trial": "prev",
                    "import_sha256": "empty",
                    "export_sha256": good_sha,
                    "bytes": 8,
                }
            )
            + "\n",
            encoding="utf-8",
        )
        (logs / "kg-export.tar").write_bytes(b"BAD-TAR")
        (logs / "kg-export-probe.rc").write_text("1", encoding="utf-8")
        ns["_advance_continuity_chain"](logs, croot, "trialB", good_sha)
        # 链不推进:保留的 tar 原字节原位。
        self.assertEqual((croot / "store-latest.tar").read_bytes(), b"GOOD-TAR")
        rows = [
            json.loads(line)
            for line in (croot / "ledger.jsonl").read_text().splitlines()
        ]
        self.assertEqual(len(rows), 2)
        degraded = rows[-1]
        self.assertTrue(degraded["degraded"])
        self.assertEqual(degraded["export_probe_rc"], 1)
        self.assertEqual(
            degraded["rejected_export_sha256"],
            hashlib.sha256(b"BAD-TAR").hexdigest(),
        )
        # 链头见证闭合:账本头 sha == 保留 tar 的 sha(下一 trial 导入校验用)。
        self.assertEqual(degraded["export_sha256"], good_sha)
        self.assertEqual(
            hashlib.sha256((croot / "store-latest.tar").read_bytes()).hexdigest(),
            degraded["export_sha256"],
        )

    def test_export_probe_receipt_missing_fails_closed(self):
        ns = self._helpers()
        logs, croot = self._dirs()
        good_sha = hashlib.sha256(b"GOOD-TAR").hexdigest()
        (croot / "store-latest.tar").write_bytes(b"GOOD-TAR")
        (croot / "ledger.jsonl").write_text(
            json.dumps(
                {
                    "trial": "prev",
                    "import_sha256": "empty",
                    "export_sha256": good_sha,
                    "bytes": 8,
                }
            )
            + "\n",
            encoding="utf-8",
        )
        (logs / "kg-export.tar").write_bytes(b"UNPROVEN")
        ns["_advance_continuity_chain"](logs, croot, "trialC", good_sha)
        self.assertEqual((croot / "store-latest.tar").read_bytes(), b"GOOD-TAR")
        rows = [
            json.loads(line)
            for line in (croot / "ledger.jsonl").read_text().splitlines()
        ]
        self.assertTrue(rows[-1]["degraded"])
        self.assertEqual(rows[-1]["export_sha256"], good_sha)

    def test_adapter_command_probes_store_before_export(self):
        source = (
            Path(__file__).parents[1]
            / "workbuddy/overlay/src/workbuddy_bench/agents/metacodes_agent.py"
        ).read_text(encoding="utf-8")
        self.assertIn(
            '\'"$METACODES_KG_BIN" list-recent "$METACODES_KG_STORE" \'',
            source,
        )
        self.assertIn(
            'printf "%s" "$?" > /logs/agent/kg-export-probe.rc',
            source,
        )
        # 空店按探针通过记:空导出无毒,importer 只会 init fresh。
        self.assertIn(
            'else printf "0" > /logs/agent/kg-export-probe.rc; fi',
            source,
        )


class BestArtifactMultiFileTest(unittest.TestCase):
    """v43 多文件工件:新建文件递送全文,修改型文件递送 diff hunks。

    p32etag 取证:1.0 方案 = 新建模块 + 既有文件的接线 hunks;旧通道只取
    new-file → 接线整个丢失 → 声明 1.0 的重放永远 5/11(0.4545 平台自锁)。
    """

    @staticmethod
    def _extract():
        source = (
            Path(__file__).parents[1]
            / "workbuddy/overlay/src/workbuddy_bench/agents/metacodes_agent.py"
        ).read_text(encoding="utf-8")
        tree = ast.parse(source)
        body = [
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "_best_artifact"
        ]
        module = ast.Module(body=body, type_ignores=[])
        namespace = {"Path": Path}
        exec(compile(module, "<best-artifact>", "exec"), namespace)
        return namespace["_best_artifact"]

    def _trial(self, patch_text):
        holder = tempfile.TemporaryDirectory()
        self.addCleanup(holder.cleanup)
        trial = Path(holder.name)
        (trial / "verifier").mkdir()
        (trial / "verifier" / "agent.patch").write_text(patch_text, encoding="utf-8")
        return trial

    PATCH = (
        "diff --git a/pkg/newmod.py b/pkg/newmod.py\n"
        "new file mode 100644\n"
        "--- /dev/null\n"
        "+++ b/pkg/newmod.py\n"
        "@@ -0,0 +1,2 @@\n"
        "+def make_tag(body):\n"
        "+    return body[:16]\n"
        "diff --git a/pkg/asgi.py b/pkg/asgi.py\n"
        "index 111..222 100644\n"
        "--- a/pkg/asgi.py\n"
        "+++ b/pkg/asgi.py\n"
        "@@ -10,3 +10,4 @@\n"
        " import os\n"
        "+from pkg.newmod import make_tag\n"
        " def handler():\n"
        "diff --git a/tests/test_new.py b/tests/test_new.py\n"
        "new file mode 100644\n"
        "--- /dev/null\n"
        "+++ b/tests/test_new.py\n"
        "@@ -0,0 +1,1 @@\n"
        "+def test_x(): pass\n"
    )

    def test_modified_file_hunks_are_delivered_with_apply_diff_tag(self):
        artifact = self._extract()(self._trial(self.PATCH))
        # 新建段:全文、原定界、在前。
        self.assertIn("--- pkg/newmod.py ---\ndef make_tag(body):", artifact)
        # 修改段:apply-diff 定界 + hunk 头 + 接线行(旧通道整个丢弃这段)。
        self.assertIn("--- pkg/asgi.py (apply-diff) ---", artifact)
        self.assertIn("@@ -10,3 +10,4 @@", artifact)
        self.assertIn("+from pkg.newmod import make_tag", artifact)
        # 新建段先于修改段;tests/ 照旧跳过。
        self.assertLess(
            artifact.index("pkg/newmod.py"), artifact.index("pkg/asgi.py")
        )
        self.assertNotIn("tests/test_new.py", artifact)

    def test_truncation_is_labelled_and_capped(self):
        big = self.PATCH.replace(
            "+    return body[:16]\n",
            "".join(f"+    x{i} = {i}\n" for i in range(400)),
        )
        artifact = self._extract()(self._trial(big))
        self.assertLessEqual(len(artifact), 4096 + 400)
        self.assertIn("HOST-TRUNCATED", artifact)
