import json
import hashlib
import io
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

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
    RULE_FILTER_PROOF,
    OBSERVATION_JOURNAL_SCHEMA,
    TOOL_OBSERVATION_SCHEMA,
    TraceError,
    anthropic_messages_endpoint,
    final_result,
    load_control_metrics,
    project_state_hash,
    read_json_lines,
    transcript_ir,
)


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

    def test_trace_rejects_non_utf8_instead_of_replacing_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trace.jsonl"
            path.write_bytes(b'{"type":"result","text":"\xff"}\n')
            with self.assertRaises(TraceError):
                read_json_lines(path)

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
                "proof": RULE_FILTER_PROOF,
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

    def test_control_metrics_count_tinykg_routing_trust_and_task_commit(self):
        calls = [
            ("recall-hit", "KgRecall", {
                "count": 2,
                "hits": [
                    {"node_id": 1, "seen_before": False},
                    {"node_id": 2, "seen_before": True},
                ],
                "lexical_query_plan": {
                    "schema_version": "lexical-query-plan-v1",
                    "plan_sha256": "4" * 64,
                    "seen_state_verified": True,
                    "ledger_scope": "agent_run_plan",
                    "new_hit_count": 1,
                    "repeated_hit_count": 1,
                },
            }),
            ("recall-miss", "KgRecall", {"count": 0, "hits": []}),
            ("context", "KgContext", {"knowledge_governance": {
                "schema_version": "metacodes-knowledge-governance-v1",
                "trust_state": "evidence_connected_candidate",
            }}),
            ("remember", "KgRemember", {"remembered": {"node_id": 9}}),
            ("task-create", "TaskCreate", {"task": {"id": "kg-10"}}),
            ("task-claim", "TaskUpdate", {
                "claimed": True, "claimed_by": "agent-l2"
            }),
            ("task-complete", "TaskUpdate", {"closed": True}),
        ]
        transcript_rows = [
            {"role": "assistant", "blocks": [
                {"type": "tool_use", "id": call_id, "name": name, "input": {}}
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
        self.assertEqual(tinykg["context_evidence_connected"], 1)
        self.assertEqual(tinykg["remember_succeeded"], 1)
        self.assertEqual(tinykg["task_dag_calls"], 3)
        self.assertEqual(tinykg["task_tinykg_status_results"], 3)
        self.assertEqual(tinykg["task_terminal_commits"], 1)

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
                    r"not owner-writable.*task-b/task\.toml",
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


class WorkBuddyOverlayUpgradeTest(unittest.TestCase):
    def test_adapter_keeps_machine_ndjson_stdout_separate_from_diagnostics(self):
        source = (
            Path(__file__).parents[1]
            / "workbuddy/overlay/src/workbuddy_bench/agents/metacodes_agent.py"
        ).read_text(encoding="utf-8")
        self.assertIn(
            'f"</dev/null | tee {shlex.quote(output_path)}; "',
            source,
        )
        self.assertNotIn(
            'f"2>&1 </dev/null | tee {shlex.quote(output_path)}; "',
            source,
        )

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

    def test_adapter_uses_complete_messages_endpoint_so_proxy_rewrites_model(self):
        source = (
            Path(__file__).parents[1]
            / "workbuddy/overlay/src/workbuddy_bench/agents/metacodes_agent.py"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "escaped_proxy = anthropic_messages_endpoint(self._proxy_url)",
            source,
        )
        self.assertIn('"METACODES_BASE_URL": escaped_proxy', source)
        self.assertLess(
            source.index("escaped_proxy = anthropic_messages_endpoint(self._proxy_url)"),
            source.index('"METACODES_BASE_URL": escaped_proxy'),
        )

    def test_overlay_patches_resolve_and_prepare_with_one_mount_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            fixtures = {
                overlay_installer._ADAPTER_PATH:
                    overlay_installer._ADAPTER_ANCHOR,
                overlay_installer._RESOLVER_PATH: (
                    overlay_installer._DISPATCH_OLD
                    + overlay_installer._GENERIC_ANCHOR
                    + overlay_installer._MODEL_ROUTE_OLD
                    + overlay_installer._RESOLVER_MOUNT_OLD
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
            for relative, content in fixtures.items():
                path = repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            for args in (
                ("init", "-q"),
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
