from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.eval.e2e_adapter import NATIVE_EVENT_SCHEMA_VERSION
from scripts.eval.cli import main
from scripts.eval.memory_replay import (
    _native_warm_cache_metrics,
    render_warm_context_cache_markdown,
    summarize_warm_context_cache,
)
from scripts.eval.model import ValidationError, stable_json


def _metadata(run_id: str) -> dict:
    digest = hashlib.sha256(run_id.encode("utf-8")).hexdigest()
    return {
        "run_id": run_id,
        "invocation": 0,
        "trial": 0,
        "suite_id": "cache-test",
        "task_id": "cache-test-task",
        "task_fingerprint": digest,
        "task_fingerprint_provenance": "recorded_at_execution",
        "model_provider": "anthropic",
        "model_id": "glm-5.2",
        "model_fingerprint": digest,
        "runtime_model_provider": "anthropic",
        "runtime_model_id": "glm-5.2",
        "harness_config_id": "cache-test",
        "harness_revision": "cache-test",
        "harness_fingerprint": digest,
        "permission_mode": "bypass_permissions",
        "runtime_permission_mode": "bypass_permissions",
        "environment_fingerprint": digest,
        "grader_fingerprint": digest,
        "max_metered_tokens": 100_000,
        "max_cost_usd": 1.0,
    }


def _native_events(path: Path, *, normal: list[int], finalization: list[int] | None = None) -> None:
    trace = "cache-test-trace"
    events = [{"run_started": {"trace_id": trace, "metadata": _metadata("cache-test")}}]
    request_count = len(normal)
    for index, cache_read in enumerate(normal, 1):
        events.extend(
            [
                {"turn_started": {"trace_id": trace, "depth": 0, "turn": index}},
                {
                    "usage": {
                        "trace_id": trace,
                        "input_tokens": 0,
                        "output_tokens": 0,
                        "cache_read_tokens": 0,
                        "cache_write_tokens": 0,
                        "estimated_cost_usd": 0.0,
                        "pricing_provenance": "test",
                    }
                },
                {
                    "usage": {
                        "trace_id": trace,
                        "input_tokens": 100,
                        "output_tokens": 10,
                        "cache_read_tokens": cache_read,
                        "cache_write_tokens": 0,
                        "estimated_cost_usd": 0.01,
                        "pricing_provenance": "test",
                    }
                },
                {
                    "model_request_finished": {
                        "trace_id": trace,
                        "depth": 0,
                        "turn": index,
                        "attempt": 0,
                        "elapsed_ms": 1,
                        "outcome": "success",
                    }
                },
                {
                    "turn_finished": {
                        "trace_id": trace,
                        "depth": 0,
                        "turn": index,
                        "tool_calls": 0,
                    }
                },
            ]
        )
    for index, _input_tokens in enumerate(finalization or [], request_count + 1):
        events.append(
            {
                "usage": {
                    "trace_id": trace,
                    "input_tokens": 900,
                    "output_tokens": 5,
                    "cache_read_tokens": 0,
                    "cache_write_tokens": 0,
                    "estimated_cost_usd": 0.02,
                    "pricing_provenance": "test",
                }
            }
        )
    events.append(
        {
            "run_finished": {
                "trace_id": trace,
                "depth": 0,
                "turns": request_count,
                "tool_calls": 0,
                "stop_reason": "end_turn",
                "wall_time_ms": 100,
                "dropped_events": 0,
            }
        }
    )
    path.write_text(
        "".join(
            stable_json(
                {
                    "schema_version": NATIVE_EVENT_SCHEMA_VERSION,
                    "sequence": index,
                    "monotonic_elapsed_ns": index,
                    "session_id": "cache-test-session",
                    "event": event,
                }
            )
            + "\n"
            for index, event in enumerate(events)
        ),
        encoding="utf-8",
    )


class MemoryCacheTest(unittest.TestCase):
    def test_warm_metric_excludes_first_request(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "native-events.jsonl"
            _native_events(path, normal=[0, 80, 100])
            observed = _native_warm_cache_metrics(
                path,
                {"normal_request_count": 3, "tool_less_finalization_request_count": 0},
            )
            self.assertEqual(observed["cold_start"]["cache_read_tokens"], 0)
            self.assertEqual(observed["warm"]["cache_read_tokens"], 180)
            self.assertEqual(observed["warm_request_count"], 2)
            self.assertAlmostEqual(180 / (200 + 180), observed["warm_cache_reuse_ratio"])

    def test_toolless_finalization_is_not_a_warm_request(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "native-events.jsonl"
            _native_events(path, normal=[0, 80], finalization=[1])
            observed = _native_warm_cache_metrics(
                path,
                {"normal_request_count": 2, "tool_less_finalization_request_count": 1},
            )
            self.assertEqual(observed["warm_request_count"], 1)
            self.assertEqual(observed["warm"]["cache_read_tokens"], 80)
            self.assertEqual(observed["finalization"]["input_tokens"], 900)

    def test_usage_timeline_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "native-events.jsonl"
            _native_events(path, normal=[0, 80])
            with self.assertRaisesRegex(ValidationError, "does not match"):
                _native_warm_cache_metrics(
                    path,
                    {"normal_request_count": 3, "tool_less_finalization_request_count": 0},
                )

    def test_summary_binds_native_artifact_and_renders_diagnostic(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            events = root / "rollouts" / "0" / "native-events.jsonl"
            events.parent.mkdir(parents=True)
            _native_events(events, normal=[0, 80, 100])
            digest = hashlib.sha256(events.read_bytes()).hexdigest()
            receipt = {
                "schema_version": 9,
                "context_cache_summary": {"context_cache_claim_gate_passed": False},
                "rollouts": [
                    {
                        "sequence": 0,
                        "arm": "no_memory",
                        "run_id": "cache-test",
                        "artifact_paths": {"native_events": "rollouts/0/native-events.jsonl"},
                        "native_events_sha256": digest,
                        "context_cache": {
                            "normal_request_count": 3,
                            "tool_less_finalization_request_count": 0,
                        },
                    }
                ],
            }
            summary = summarize_warm_context_cache(
                receipt,
                root,
                runtime_receipt_sha256="a" * 64,
            )
            self.assertEqual(summary["by_arm"]["no_memory"]["warm_request_count"], 2)
            self.assertFalse(summary["warm_cache_diagnostic_gate_passed"])
            self.assertIn("receipt_context_cache_claim_gate_not_passed", summary["claim_blockers"])
            self.assertIn("warm-cache diagnostic", render_warm_context_cache_markdown(summary))

    def test_cli_writes_receipt_bound_warm_cache_sidecar(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            events = root / "rollouts" / "0" / "native-events.jsonl"
            events.parent.mkdir(parents=True)
            _native_events(events, normal=[0, 80, 100])
            receipt = {
                "schema_version": 9,
                "context_cache_summary": {"context_cache_claim_gate_passed": False},
                "rollouts": [
                    {
                        "sequence": 0,
                        "arm": "no_memory",
                        "run_id": "cache-test",
                        "artifact_paths": {"native_events": "rollouts/0/native-events.jsonl"},
                        "native_events_sha256": hashlib.sha256(events.read_bytes()).hexdigest(),
                        "context_cache": {
                            "normal_request_count": 3,
                            "tool_less_finalization_request_count": 0,
                        },
                    }
                ],
            }
            receipt_path = root / "receipt.json"
            receipt_path.write_text(json.dumps(receipt) + "\n", encoding="utf-8")
            output_path = root / "warm-cache.json"
            markdown_path = root / "warm-cache.md"
            self.assertEqual(
                main(
                    [
                        "report-memory-cache",
                        "--runtime-receipt",
                        str(receipt_path),
                        "--artifact-root",
                        str(root),
                        "--json",
                        str(output_path),
                        "--markdown",
                        str(markdown_path),
                    ]
                ),
                0,
            )
            self.assertEqual(
                json.loads(output_path.read_text(encoding="utf-8"))["schema_version"],
                1,
            )
            self.assertIn("Diagnostic only", markdown_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
