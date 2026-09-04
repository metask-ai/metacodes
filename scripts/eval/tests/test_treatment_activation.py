from __future__ import annotations

import copy
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from scripts.eval.tests.posix_only import requires_symlinks

from scripts.eval.model import ValidationError, validate_treatment_activation_receipt
from scripts.eval.treatment_activation import (
    attach_treatment_activation,
    attest_treatment_activation,
    reverify_treatment_activation,
)


ROOT = Path(__file__).resolve().parents[3]
TINYKG = Path(os.environ["METACODES_TEST_TINYKG_BIN"]) if os.environ.get(
    "METACODES_TEST_TINYKG_BIN"
) else ROOT / ".missing-explicit-tinykg"


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def committed_projection(content):
    payload = content.encode("utf-8")
    return (
        "[tool result cleared to save context]\n"
        f"[tool-result-commitment original_bytes={len(payload)} "
        f"sha256={hashlib.sha256(payload).hexdigest()}]"
    )


def run_tinykg(binary: Path, *args: str) -> str:
    completed = subprocess.run(
        [str(binary), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=20,
        check=False,
    )
    if completed.returncode != 0:
        raise AssertionError(
            f"TinyKG command failed: {args!r}: {completed.stderr or completed.stdout}"
        )
    return completed.stdout.strip()


def envelope(sequence, event):
    return {
        "schema_version": 3,
        "sequence": sequence,
        "monotonic_elapsed_ns": sequence + 1,
        "session_id": "activation-session",
        "event": event,
    }


def call_events(
    sequence, tool_use_id, name, input_text, result_text, *, trace_id="activation-trace"
):
    input_bytes = input_text.encode()
    result_bytes = result_text.encode()
    return [
        envelope(
            sequence,
            {
                "tool_started": {
                    "trace_id": trace_id,
                    "id": tool_use_id,
                    "name": name,
                    "input_bytes": len(input_bytes),
                    "input_sha256": hashlib.sha256(input_bytes).hexdigest(),
                }
            },
        ),
        envelope(
            sequence + 1,
            {
                "tool_finished": {
                    "trace_id": trace_id,
                    "id": tool_use_id,
                    "name": name,
                    "is_error": False,
                    "error_code": None,
                    "error_category": None,
                    "recoverable": None,
                    "elapsed_ms": 1,
                    "result_bytes": len(result_bytes),
                    "result_sha256": hashlib.sha256(result_bytes).hexdigest(),
                }
            },
        ),
    ]


def transcript_pair(tool_use_id, name, input_text, result_text):
    return [
        {
            "role": "assistant",
            "blocks": [
                {
                    "type": "tool_use",
                    "id": tool_use_id,
                    "name": name,
                    "input": input_text,
                }
            ],
        },
        {
            "role": "user",
            "blocks": [
                {
                    "type": "tool_result",
                    "tool_use_id": tool_use_id,
                    "content": result_text,
                    "is_error": False,
                }
            ],
        },
    ]


def write_jsonl(path: Path, rows) -> None:
    path.write_text(
        "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows),
        encoding="utf-8",
    )


def run_metadata(arm_id):
    return {
        "run_id": f"activation:{arm_id}:0",
        "invocation": 0,
        "trial": 0,
        "suite_id": "activation-suite",
        "task_id": "activation-task",
        "task_fingerprint": "fingerprint",
        "task_fingerprint_provenance": "recorded_at_execution",
        "model_provider": "anthropic",
        "model_id": "glm-5.2",
        "model_fingerprint": "model-fingerprint",
        "runtime_model_provider": "anthropic",
        "runtime_model_id": "glm-5.2",
        "harness_config_id": f"activation:{arm_id}:config",
        "harness_revision": "revision",
        "harness_fingerprint": "harness-fingerprint",
        "permission_mode": "bypass_permissions",
        "runtime_permission_mode": "bypass_permissions",
        "environment_fingerprint": "environment-fingerprint",
        "grader_fingerprint": "grader-fingerprint",
    }


def merged_metadata(arm_id, overrides):
    metadata = run_metadata(arm_id)
    if overrides:
        metadata.update(overrides)
    return metadata


def write_activation_artifacts(
    workspace: Path,
    binary: Path,
    *,
    close_task: bool = True,
    metadata: dict | None = None,
) -> None:
    store = workspace / ".home/.metacodes/kg/store.kg"
    store.parent.mkdir(parents=True)
    run_tinykg(binary, "init", str(store))
    run_tinykg(
        binary,
        "add-node",
        str(store),
        "task",
        "activation task\nprove treatment lifecycle",
        "--schema-type",
        "todo",
    )
    run_tinykg(binary, "task-claim", str(store), "1", "--by", "activation-agent")
    claim_packet = json.loads(
        run_tinykg(
            binary,
            "task-packet",
            str(store),
            "1",
            "--format",
            "json",
            "--meta",
            "--limit",
            "8",
            "--max-nodes",
            "16",
            "--max-edges",
            "24",
            "--max-chars",
            "200000",
        )
    )
    if close_task:
        run_tinykg(
            binary,
            "task-close",
            str(store),
            "1",
            "completed",
            "--by",
            "activation-agent",
            "--evidence-text",
            "activation verified by artifact readback",
        )

    calls = [
        (
            "create-1",
            "TaskCreate",
            compact(
                {
                    "subject": "activation task",
                    "description": "prove treatment lifecycle",
                }
            ),
            compact(
                {
                    "task": {
                        "id": "kg-1",
                        "subject": "activation task",
                        "persisted": True,
                    }
                }
            ),
        ),
        (
            "claim-1",
            "TaskUpdate",
            compact({"taskId": "kg-1", "status": "in_progress"}),
            compact(
                {
                    "ok": True,
                    "claimed": True,
                    "claimed_by": "activation-agent",
                    "task_packet": claim_packet,
                }
            ),
        ),
        (
            "complete-1",
            "TaskUpdate",
            compact(
                {
                    "taskId": "kg-1",
                    "status": "completed",
                    "conclusion": "artifact readback verified",
                }
            ),
            compact({"ok": True, "closed": True, "next": []}),
        ),
    ]
    events = [
        envelope(
            0,
            {
                "run_started": {
                    "trace_id": "activation-trace",
                    "metadata": merged_metadata("tinykg", metadata),
                }
            },
        )
    ]
    transcript = []
    sequence = 1
    for tool_use_id, name, input_text, result_text in calls:
        events.extend(call_events(sequence, tool_use_id, name, input_text, result_text))
        transcript.extend(
            transcript_pair(tool_use_id, name, input_text, result_text)
        )
        sequence += 2
    events.append(
        envelope(
            sequence,
            {
                "run_finished": {
                    "trace_id": "activation-trace",
                    "depth": 0,
                    "turns": 3,
                    "tool_calls": 3,
                    "stop_reason": "end_turn",
                    "wall_time_ms": 10,
                    "dropped_events": 0,
                }
            },
        )
    )
    write_jsonl(workspace / "events.jsonl", events)
    write_jsonl(workspace / "transcript.jsonl", transcript)


def write_baseline_artifacts(
    workspace: Path, arm_id: str = "codex_style", *, metadata: dict | None = None
) -> None:
    events = [
        envelope(
            0,
            {
                "run_started": {
                    "trace_id": "baseline-trace",
                    "metadata": merged_metadata(arm_id, metadata),
                }
            },
        ),
        envelope(
            1,
            {
                "run_finished": {
                    "trace_id": "baseline-trace",
                    "depth": 0,
                    "turns": 1,
                    "tool_calls": 0,
                    "stop_reason": "end_turn",
                    "wall_time_ms": 1,
                    "dropped_events": 0,
                }
            },
        ),
    ]
    write_jsonl(workspace / "events.jsonl", events)
    write_jsonl(
        workspace / "transcript.jsonl",
        [{"role": "assistant", "blocks": [{"type": "text", "text": "done"}]}],
    )


def append_baseline_invocation(
    workspace: Path,
    *,
    arm_id: str,
    invocation: int,
    trace_id: str,
    metadata_overrides: dict | None = None,
) -> None:
    path = workspace / "events.jsonl"
    metadata = merged_metadata(arm_id, metadata_overrides)
    metadata["invocation"] = invocation
    events = [
        envelope(
            0,
            {"run_started": {"trace_id": trace_id, "metadata": metadata}},
        ),
        envelope(
            1,
            {
                "run_finished": {
                    "trace_id": trace_id,
                    "depth": 0,
                    "turns": 1,
                    "tool_calls": 0,
                    "stop_reason": "end_turn",
                    "wall_time_ms": 1,
                    "dropped_events": 0,
                }
            },
        ),
    ]
    with path.open("a", encoding="utf-8") as handle:
        for row in events:
            handle.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")


@unittest.skipUnless(TINYKG.is_file(), "set METACODES_TEST_TINYKG_BIN")
class TreatmentActivationTest(unittest.TestCase):
    def setUp(self):
        self.binary = TINYKG.resolve()
        self.binary_sha256 = hashlib.sha256(self.binary.read_bytes()).hexdigest()

    def test_persistent_lifecycle_is_bound_to_events_transcript_and_store(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_activation_artifacts(workspace, self.binary)
            receipt = attest_treatment_activation(
                workspace, "tinykg", self.binary, self.binary_sha256
            )
            self.assertEqual(receipt["task"], {"id": 1, "kind": "task", "status": "completed"})
            self.assertEqual(
                [row["phase"] for row in receipt["trace"]],
                ["created", "claimed", "completed"],
            )
            self.assertEqual(receipt["store"]["verification_node_ids"], [2])

            rollout = {
                "run_id": "activation:tinykg:0",
                "suite_id": "activation-suite",
                "task_id": "activation-task",
                "trial": 0,
                "harness": {"config_id": "activation:tinykg:config"},
                "artifacts": {"workspace": str(workspace)},
            }
            attach_treatment_activation(
                rollout, "tinykg", self.binary, self.binary_sha256
            )
            reverify_treatment_activation(
                rollout, "tinykg", self.binary, self.binary_sha256
            )

    def test_missing_claim_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_activation_artifacts(workspace, self.binary)
            rows = [
                json.loads(line)
                for line in (workspace / "transcript.jsonl").read_text().splitlines()
            ]
            rows = [
                row
                for row in rows
                if all(
                    block.get("tool_use_id") != "claim-1" and block.get("id") != "claim-1"
                    for block in row["blocks"]
                )
            ]
            write_jsonl(workspace / "transcript.jsonl", rows)
            with self.assertRaisesRegex(ValidationError, "tool-call identities differ"):
                attest_treatment_activation(
                    workspace, "tinykg", self.binary, self.binary_sha256
                )

    def test_transcript_tool_use_without_result_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_activation_artifacts(workspace, self.binary)
            path = workspace / "transcript.jsonl"
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            rows = [
                row
                for row in rows
                if all(
                    block.get("tool_use_id") != "claim-1"
                    for block in row["blocks"]
                )
            ]
            write_jsonl(path, rows)
            with self.assertRaisesRegex(ValidationError, "uses without results"):
                attest_treatment_activation(
                    workspace, "tinykg", self.binary, self.binary_sha256
                )

    def test_transcript_tamper_breaks_native_hash_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_activation_artifacts(workspace, self.binary)
            path = workspace / "transcript.jsonl"
            path.write_text(
                path.read_text(encoding="utf-8").replace(
                    "artifact readback verified", "forged conclusion"
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValidationError, "hash mismatch"):
                attest_treatment_activation(
                    workspace, "tinykg", self.binary, self.binary_sha256
                )

    def test_compacted_lifecycle_results_retain_native_hash_and_store_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_activation_artifacts(workspace, self.binary)
            path = workspace / "transcript.jsonl"
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            for row in rows:
                for block in row["blocks"]:
                    if block.get("type") == "tool_result":
                        block["content"] = committed_projection(block["content"])
            write_jsonl(path, rows)

            receipt = attest_treatment_activation(
                workspace, "tinykg", self.binary, self.binary_sha256
            )

            self.assertEqual(receipt["task"]["status"], "completed")
            self.assertEqual(
                [item["phase"] for item in receipt["trace"]],
                ["created", "claimed", "completed"],
            )

    def test_legacy_compaction_stub_without_commitment_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_activation_artifacts(workspace, self.binary)
            path = workspace / "transcript.jsonl"
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            result = next(
                block
                for row in rows
                for block in row["blocks"]
                if block.get("type") == "tool_result"
            )
            result["content"] = "[tool result cleared to save context]"
            write_jsonl(path, rows)

            with self.assertRaisesRegex(ValidationError, "lacks a byte commitment"):
                attest_treatment_activation(
                    workspace, "tinykg", self.binary, self.binary_sha256
                )

    def test_store_without_verified_completion_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_activation_artifacts(workspace, self.binary, close_task=False)
            with self.assertRaisesRegex(ValidationError, "terminal task"):
                attest_treatment_activation(
                    workspace, "tinykg", self.binary, self.binary_sha256
                )

    @requires_symlinks
    def test_store_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / "workspace"
            workspace.mkdir()
            write_activation_artifacts(workspace, self.binary)
            store = workspace / ".home/.metacodes/kg/store.kg"
            relocated = root / "relocated-store.kg"
            store.rename(relocated)
            store.symlink_to(relocated, target_is_directory=True)
            with self.assertRaisesRegex(ValidationError, "store must be a real directory"):
                attest_treatment_activation(
                    workspace, "tinykg", self.binary, self.binary_sha256
                )

    def test_wrong_frozen_binary_hash_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_activation_artifacts(workspace, self.binary)
            with self.assertRaisesRegex(ValidationError, "differs from frozen"):
                attest_treatment_activation(
                    workspace, "tinykg", self.binary, "0" * 64
                )

    def test_baseline_proves_persistent_treatment_absence(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_baseline_artifacts(workspace)
            receipt = attest_treatment_activation(
                workspace, "codex_style", self.binary, self.binary_sha256
            )
            self.assertEqual(receipt["trace"], [])
            self.assertEqual(receipt["store"], {"present": False})

    def test_baseline_accepts_contiguous_multi_invocation_native_trace(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_baseline_artifacts(workspace)
            append_baseline_invocation(
                workspace,
                arm_id="codex_style",
                invocation=1,
                trace_id="baseline-trace-1",
            )
            append_baseline_invocation(
                workspace,
                arm_id="codex_style",
                invocation=2,
                trace_id="baseline-trace-2",
            )

            receipt = attest_treatment_activation(
                workspace, "codex_style", self.binary, self.binary_sha256
            )

            self.assertEqual(receipt["execution"]["run_id"], "activation:codex_style:0")
            self.assertEqual(receipt["trace"], [])

    def test_multi_invocation_gap_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_baseline_artifacts(workspace)
            append_baseline_invocation(
                workspace,
                arm_id="codex_style",
                invocation=2,
                trace_id="baseline-trace-2",
            )

            with self.assertRaisesRegex(
                ValidationError, "invocation identities are not contiguous"
            ):
                attest_treatment_activation(
                    workspace, "codex_style", self.binary, self.binary_sha256
                )

    def test_sequence_reset_without_new_invocation_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_baseline_artifacts(workspace)
            path = workspace / "events.jsonl"
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            rows.insert(
                1,
                envelope(
                    0,
                    {
                        "turn_started": {
                            "trace_id": "baseline-trace",
                            "depth": 0,
                            "turn": 1,
                        }
                    },
                ),
            )
            write_jsonl(path, rows)

            with self.assertRaisesRegex(
                ValidationError, "not contiguous within trace"
            ):
                attest_treatment_activation(
                    workspace, "codex_style", self.binary, self.binary_sha256
                )

    def test_multi_invocation_identity_drift_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_baseline_artifacts(workspace)
            append_baseline_invocation(
                workspace,
                arm_id="codex_style",
                invocation=1,
                trace_id="baseline-trace-1",
                metadata_overrides={"model_id": "different-model"},
            )

            with self.assertRaisesRegex(ValidationError, "mix execution identities"):
                attest_treatment_activation(
                    workspace, "codex_style", self.binary, self.binary_sha256
                )

    def test_trace_change_within_invocation_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_baseline_artifacts(workspace)
            path = workspace / "events.jsonl"
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            rows[-1]["event"]["run_finished"]["trace_id"] = "different-trace"
            write_jsonl(path, rows)

            with self.assertRaisesRegex(ValidationError, "trace changed"):
                attest_treatment_activation(
                    workspace, "codex_style", self.binary, self.binary_sha256
                )

    def test_dropped_native_events_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_baseline_artifacts(workspace)
            path = workspace / "events.jsonl"
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            rows[-1]["event"]["run_finished"]["dropped_events"] = 1
            write_jsonl(path, rows)

            with self.assertRaisesRegex(ValidationError, "dropped events"):
                attest_treatment_activation(
                    workspace, "codex_style", self.binary, self.binary_sha256
                )

    def test_incomplete_native_invocation_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_baseline_artifacts(workspace)
            path = workspace / "events.jsonl"
            rows = [json.loads(line) for line in path.read_text().splitlines()]
            write_jsonl(path, rows[:-1])

            with self.assertRaisesRegex(ValidationError, "is incomplete"):
                attest_treatment_activation(
                    workspace, "codex_style", self.binary, self.binary_sha256
                )


    def test_baseline_cannot_hide_native_kg_call_by_removing_transcript_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_baseline_artifacts(workspace)
            events_path = workspace / "events.jsonl"
            events = [json.loads(line) for line in events_path.read_text().splitlines()]
            input_text = compact({"query": "hidden"})
            result_text = compact({"hits": []})
            events[1:1] = call_events(
                1,
                "hidden-kg",
                "KgRecall",
                input_text,
                result_text,
                trace_id="baseline-trace",
            )
            events[-1]["sequence"] = 3
            write_jsonl(events_path, events)
            with self.assertRaisesRegex(ValidationError, "tool-call identities differ"):
                attest_treatment_activation(
                    workspace, "codex_style", self.binary, self.binary_sha256
                )

    def test_receipt_schema_rejects_phase_reordering(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory) / "workspace"
            workspace.mkdir()
            write_activation_artifacts(workspace, self.binary)
            receipt = attest_treatment_activation(
                workspace, "tinykg", self.binary, self.binary_sha256
            )
            broken = copy.deepcopy(receipt)
            broken["trace"][1], broken["trace"][2] = (
                broken["trace"][2],
                broken["trace"][1],
            )
            with self.assertRaisesRegex(ValidationError, "sequences|created, claimed"):
                validate_treatment_activation_receipt(
                    broken, expected_arm="tinykg"
                )


if __name__ == "__main__":
    unittest.main()
