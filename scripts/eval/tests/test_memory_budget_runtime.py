import copy
import hashlib
import http.server
import json
import os
import platform
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest
from pathlib import Path
from unittest import mock

import scripts.eval.memory_agent_runtime as memory_runtime
import scripts.eval.memory_agent_runtime_pilot as memory_pilot

from scripts.eval.e2e_adapter import NATIVE_EVENT_SCHEMA_VERSION
from scripts.eval.memory_agent_runtime import (
    PRODUCTION_MODEL_FINGERPRINT,
    ProductionRuntimeConfig,
    run_memory_agent_schedule,
)
from scripts.eval.memory_benchmark import file_sha256
from scripts.eval.memory_budget_journal import (
    BudgetAuthority,
    BudgetJournal,
    BudgetTransaction,
    validate_checkpoint_payload,
    usd_to_microusd,
)
from scripts.eval.memory_replay import (
    PRODUCTION_ALLOWED_PROVIDER_TOOLS,
    PRODUCTION_PRICING_PROVENANCE,
    PRODUCTION_PROVIDER_ID,
    PRODUCTION_RIPGREP_SNAPSHOT_PATH,
    _artifact_tree_digest,
    load_manifest,
    validate_runtime_artifacts,
    validate_runtime_receipt,
)
from scripts.eval.model import ValidationError, stable_json
from scripts.eval.tests.posix_only import requires_posix_budget_journal


ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "evals/memory/fixtures"
TEST_RIPGREP = Path(sys.executable).resolve()
TEST_RIPGREP_SHA256 = hashlib.sha256(TEST_RIPGREP.read_bytes()).hexdigest()
REAL_TINYKG = Path(os.environ["METACODES_TEST_TINYKG_BIN"]) if os.environ.get(
    "METACODES_TEST_TINYKG_BIN"
) else ROOT / ".missing-explicit-tinykg"


class _AuthorizationObservingServer:
    def __init__(self, journal_path: Path) -> None:
        self.journal_path = journal_path
        self.requests = 0
        self.observed_states: list[str] = []
        self.errors: list[str] = []
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    self.rfile.read(length)
                    state = validate_checkpoint_payload(owner.journal_path.read_bytes())
                    states = [
                        str(transaction["state"])
                        for transaction in state["transactions"].values()
                    ]
                    owner.requests += 1
                    owner.observed_states.extend(states)
                    if "request_authorized" not in states:
                        raise AssertionError("provider request preceded durable authorization")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(b'{"ok":true}')
                except BaseException as exc:
                    owner.errors.append(str(exc))
                    self.send_response(500)
                    self.end_headers()

            def log_message(self, _format, *_args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def url(self) -> str:
        host, port = self.server.server_address
        return f"http://{host}:{port}/v1/messages"

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, _exc_type, _exc, _traceback):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


class MemoryBudgetRuntimeL2Test(unittest.TestCase):
    def _materialize_contract(self, root: Path):
        manifest = copy.deepcopy(load_manifest(FIXTURES / "smoke-manifest.json"))
        case = copy.deepcopy(manifest["cases"][0])
        arm = copy.deepcopy(manifest["execution"]["arms"][0])
        second_arm = {
            "id": "codex_style",
            "fingerprint": hashlib.sha256(b"budget-runtime-second-control").hexdigest(),
        }
        source = {
            "adapter_id": manifest["dataset"]["adapter_id"],
            "adapter_revision": manifest["dataset"]["adapter_revision"],
            "cases": [{"id": case["id"]}],
        }
        source_path = root / "source.json"
        source_path.write_text(stable_json(source) + "\n", encoding="utf-8")
        manifest["dataset"]["source_sha256"] = file_sha256(source_path)
        manifest["execution"]["model_id"] = "glm-5.2"
        manifest["execution"]["model_fingerprint"] = PRODUCTION_MODEL_FINGERPRINT
        manifest["execution"]["harness_revision"] = "budget-runtime-l2-v1"
        manifest["execution"]["arms"] = [arm, second_arm]
        manifest["execution"]["trials"] = 1
        manifest["cases"] = [case]
        manifest["schedule"] = [
            {"sequence": 0, "case_id": case["id"], "trial": 0, "arm": arm["id"]},
            {
                "sequence": 1,
                "case_id": case["id"],
                "trial": 0,
                "arm": second_arm["id"],
            },
        ]
        manifest_path = root / "manifest.json"
        manifest_path.write_text(stable_json(manifest) + "\n", encoding="utf-8")
        manifest = load_manifest(manifest_path)
        return source_path, manifest_path, manifest

    def _write_fake_metacodes(
        self,
        path: Path,
        provider_url: str,
        *,
        crash_after_provider: bool = False,
    ) -> None:
        crash_line = (
            "os.kill(os.getpid(), signal.SIGTERM)"
            if crash_after_provider
            else "pass"
        )
        script = textwrap.dedent(
            f"""\
            #!/usr/bin/python3 -I
            import json
            import os
            import signal
            import urllib.request

            def stable(value):
                return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

            metadata_fd = int(os.environ["METACODES_EVAL_METADATA_FD"])
            events_fd = int(os.environ["METACODES_EVAL_FD"])
            credential_fd = int(os.environ["METACODES_API_KEY_FD"])
            metadata = json.loads(os.read(metadata_fd, 1024 * 1024).decode("utf-8"))
            credential = os.read(credential_fd, 8192)
            if credential != b"runtime-l2-private-key":
                raise SystemExit(41)
            record_dir = os.environ["METACODES_RECORD_DIR"]
            request_body = {{
                "model": "glm-5.2",
                "system": "budget-runtime-l2-system",
                "tools": [],
                "cache_control": {{"type": "ephemeral"}},
                "messages": [{{
                    "role": "user",
                    "content": [{{"type": "text", "text": "budget-runtime-l2"}}],
                }}],
            }}
            with open(os.path.join(record_dir, "req-001.json"), "w", encoding="utf-8") as handle:
                handle.write(stable(request_body) + "\\n")
            request = urllib.request.Request(
                {provider_url!r},
                data=stable(request_body).encode("utf-8"),
                headers={{"Content-Type": "application/json"}},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=5) as response:
                if response.status != 200:
                    raise SystemExit(42)
            {crash_line}

            runtime_metadata = dict(metadata)
            runtime_metadata.update({{
                "invocation": 0,
                "task_fingerprint_provenance": "recorded_at_execution",
                "runtime_model_provider": "anthropic",
                "runtime_model_id": "glm-5.2",
                "runtime_permission_mode": "bypass_permissions",
            }})
            trace = "budget-runtime-l2-trace"
            events = [
                {{"run_started": {{"trace_id": trace, "metadata": runtime_metadata}}}},
                {{"turn_started": {{"trace_id": trace, "depth": 0, "turn": 1}}}},
                {{"model_request_finished": {{
                    "trace_id": trace,
                    "depth": 0,
                    "turn": 1,
                    "attempt": 0,
                    "elapsed_ms": 1,
                    "outcome": "success",
                }}}},
                {{"turn_finished": {{
                    "trace_id": trace,
                    "depth": 0,
                    "turn": 1,
                    "tool_calls": 0,
                }}}},
                {{"usage": {{
                    "trace_id": trace,
                    "input_tokens": 1,
                    "output_tokens": 0,
                    "cache_read_tokens": 0,
                    "cache_write_tokens": 0,
                    "estimated_cost_usd": 0.000003,
                    "pricing_provenance": {PRODUCTION_PRICING_PROVENANCE!r},
                }}}},
                {{"run_finished": {{
                    "trace_id": trace,
                    "depth": 0,
                    "turns": 1,
                    "tool_calls": 0,
                    "stop_reason": "end_turn",
                    "wall_time_ms": 2,
                    "dropped_events": 0,
                }}}},
            ]
            for sequence, event in enumerate(events):
                row = {{
                    "schema_version": {NATIVE_EVENT_SCHEMA_VERSION},
                    "sequence": sequence,
                    "monotonic_elapsed_ns": sequence,
                    "session_id": "budget-runtime-l2",
                    "event": event,
                }}
                os.write(events_fd, (stable(row) + "\\n").encode("utf-8"))
            print(stable({{
                "type": "result",
                "stop_reason": "end_turn",
                "turns": 1,
                "tool_calls": 0,
                "input_tokens": 1,
                "output_tokens": 0,
                "cost_usd": 0.000003,
                "text": "amber",
            }}))
            """
        )
        path.write_text(script, encoding="utf-8")
        path.chmod(0o700)

    def _write_compatible_fake_tinykg(self, path: Path) -> None:
        path.write_text(
            "#!/bin/sh\n"
            "case \"$1\" in\n"
            "  init) mkdir \"$2\" ;;\n"
            "  apply) printf 'apply version=1 nodes_created=1 nodes_existing=0 "
            "edges_created=0 edges_existing=0\\n' ;;\n"
            "  rebuild-text) : ;;\n"
            "  store-info) printf 'nodes=1\\nedges=0\\nstorage_format_version=3\\n"
            "schema_version=3\\ntext_current=1\\ntext_stale=0\\n' ;;\n"
            "  *) exit 91 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        path.chmod(0o700)

    def _production(self, ripgrep_binary: Path = TEST_RIPGREP) -> ProductionRuntimeConfig:
        return ProductionRuntimeConfig(
            api_key="runtime-l2-private-key",
            allow_paid_rollouts=True,
            max_total_cost_usd=3.0,
            max_total_metered_tokens=300_000,
            max_rollout_cost_usd=1.0,
            max_rollout_metered_tokens=100_000,
            max_output_tokens=128,
            ripgrep_binary=ripgrep_binary,
            ripgrep_binary_sha256=hashlib.sha256(ripgrep_binary.read_bytes()).hexdigest(),
        )

    def _authority(
        self,
        manifest,
        production=None,
    ) -> BudgetAuthority:
        production = production or self._production()
        return BudgetAuthority(
            manifest_sha256=hashlib.sha256(
                stable_json(manifest).encode("utf-8")
            ).hexdigest(),
            model_fingerprint=manifest["execution"]["model_fingerprint"],
            provider_identity=PRODUCTION_PROVIDER_ID,
            total_cost_microusd=usd_to_microusd(production.max_total_cost_usd),
            total_metered_tokens=production.max_total_metered_tokens,
        )

    def _run(
        self,
        root: Path,
        journal: BudgetJournal,
        fake: Path,
        source_path: Path,
        manifest_path: Path,
        *,
        run_name: str,
        fault_hook=None,
        production=None,
        resume_paid_run=False,
    ):
        run_dir = root / run_name
        return run_memory_agent_schedule(
            metacodes_binary=fake,
            expected_metacodes_sha256=file_sha256(fake),
            tinykg_binary=Path("/bin/echo"),
            expected_tinykg_sha256=file_sha256(Path("/bin/echo")),
            source_path=source_path,
            manifest_path=manifest_path,
            run_dir=run_dir,
            observations_path=run_dir / "observations.jsonl",
            runtime_receipt_path=run_dir / "runtime-receipt.json",
            timeout_seconds=10,
            production=production or self._production(),
            budget_journal=journal,
            budget_fault_hook=fault_hook,
            resume_paid_run=resume_paid_run,
        )

    @unittest.skipUnless(platform.system() == "Darwin", "requires macOS production Seatbelt")
    def test_mock_provider_observes_durable_authorization_on_real_runner_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path, manifest_path, manifest = self._materialize_contract(root)
            journal_path = root / "budget-control" / "journal.json"
            journal_path.parent.mkdir(mode=0o700)
            with _AuthorizationObservingServer(journal_path) as provider:
                fake = root / "fake-metacodes"
                self._write_fake_metacodes(fake, provider.url)
                with BudgetJournal(journal_path, self._authority(manifest)) as journal:
                    observations, receipt = self._run(
                        root,
                        journal,
                        fake,
                        source_path,
                        manifest_path,
                        run_name="run-success",
                    )
                self.assertEqual(provider.requests, 2)
                self.assertFalse(provider.errors)
                self.assertIn("request_authorized", provider.observed_states)
                self.assertEqual(receipt["rollouts"][0]["budget_transaction"]["state"], "committed")
                self.assertEqual(
                    receipt["allowed_provider_tools"],
                    list(PRODUCTION_ALLOWED_PROVIDER_TOOLS),
                )
                self.assertNotIn("Task", receipt["allowed_provider_tools"])
                self.assertEqual(receipt["ripgrep_binary_sha256"], TEST_RIPGREP_SHA256)
                validate_runtime_receipt(
                    receipt,
                    manifest,
                    observations,
                    manifest["dataset"]["source_sha256"],
                )
                validate_runtime_artifacts(receipt, root / "run-success")

                cassette = root / "run-success" / receipt["rollouts"][0]["artifact_paths"]["cassette"]
                request_path = cassette / "req-001.json"
                request = json.loads(request_path.read_text(encoding="utf-8"))
                request["tools"].append(
                    {"name": "Task", "description": "forged", "input_schema": {"type": "object"}}
                )
                request_path.write_text(stable_json(request) + "\n", encoding="utf-8")
                forged = copy.deepcopy(receipt)
                forged["rollouts"][0]["cassette_sha256"] = _artifact_tree_digest(cassette)
                with self.assertRaisesRegex(ValidationError, "out-of-policy tool 'Task'"):
                    validate_runtime_artifacts(forged, root / "run-success")

    @unittest.skipUnless(platform.system() == "Darwin", "requires macOS production Seatbelt")
    def test_crash_windows_remain_authorized_and_cannot_retry(self):
        for crash_stage, expected_requests in (
            ("after_request_authorized", 0),
            ("after_provider_return_before_commit", 1),
        ):
            with self.subTest(crash_stage=crash_stage):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    source_path, manifest_path, manifest = self._materialize_contract(root)
                    journal_path = root / "budget-control" / "journal.json"
                    journal_path.parent.mkdir(mode=0o700)
                    with _AuthorizationObservingServer(journal_path) as provider:
                        fake = root / "fake-metacodes"
                        self._write_fake_metacodes(fake, provider.url)

                        def crash(stage, _receipt):
                            if stage == crash_stage:
                                raise RuntimeError(f"injected crash at {stage}")

                        with BudgetJournal(journal_path, self._authority(manifest)) as journal:
                            with self.assertRaisesRegex(RuntimeError, "injected crash"):
                                self._run(
                                    root,
                                    journal,
                                    fake,
                                    source_path,
                                    manifest_path,
                                    run_name="run-crash",
                                    fault_hook=crash,
                                )
                        self.assertEqual(provider.requests, expected_requests)

                        with BudgetJournal(
                            journal_path, self._authority(manifest)
                        ) as recovered:
                            snapshot = recovered.snapshot()
                            self.assertEqual(
                                snapshot["transaction_states"],
                                {"request_authorized": 1},
                            )
                            self.assertEqual(
                                snapshot["unsettled_max_cost_microusd"],
                                usd_to_microusd(1.0),
                            )
                            with self.assertRaisesRegex(
                                ValidationError, "retry is forbidden"
                            ):
                                self._run(
                                    root,
                                    recovered,
                                    fake,
                                    source_path,
                                    manifest_path,
                                    run_name="run-retry",
                                )
                        self.assertEqual(provider.requests, expected_requests)

    @unittest.skipUnless(platform.system() == "Darwin", "requires macOS production Seatbelt")
    def test_rollout_checkpoint_resume_skips_already_committed_provider_request(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path, manifest_path, manifest = self._materialize_contract(root)
            journal_path = root / "budget-control" / "journal.json"
            journal_path.parent.mkdir(mode=0o700)
            run_name = "run-resume"
            checkpoint_faults = 0

            def crash_after_first_checkpoint(stage, receipt):
                nonlocal checkpoint_faults
                if (
                    stage == "after_rollout_resume_checkpoint"
                    and len(receipt["completed_sequences"]) == 1
                    and checkpoint_faults == 0
                ):
                    checkpoint_faults += 1
                    raise RuntimeError("injected crash after durable rollout checkpoint")

            with _AuthorizationObservingServer(journal_path) as provider:
                fake = root / "fake-metacodes"
                self._write_fake_metacodes(fake, provider.url)
                with BudgetJournal(journal_path, self._authority(manifest)) as journal:
                    with self.assertRaisesRegex(RuntimeError, "durable rollout checkpoint"):
                        self._run(
                            root,
                            journal,
                            fake,
                            source_path,
                            manifest_path,
                            run_name=run_name,
                            fault_hook=crash_after_first_checkpoint,
                        )
                    self.assertEqual(
                        journal.snapshot()["transaction_states"],
                        {"committed": 1},
                    )
                self.assertEqual(provider.requests, 1)
                checkpoint = json.loads(
                    (root / run_name / "rollout-resume-checkpoint.json").read_text(
                        encoding="utf-8"
                    )
                )
                self.assertEqual(checkpoint["status"], "partial")
                self.assertEqual(checkpoint["completed_sequences"], [0])

                with BudgetJournal(journal_path, self._authority(manifest)) as recovered:
                    observations, receipt = self._run(
                        root,
                        recovered,
                        fake,
                        source_path,
                        manifest_path,
                        run_name=run_name,
                        resume_paid_run=True,
                    )
                    self.assertEqual(
                        recovered.snapshot()["transaction_states"],
                        {"committed": 2},
                    )
            self.assertEqual(provider.requests, 2)
            self.assertEqual([item["sequence"] for item in receipt["rollouts"]], [0, 1])
            self.assertEqual(len(observations), 2)
            validate_runtime_artifacts(receipt, root / run_name)

    @unittest.skipUnless(platform.system() == "Darwin", "requires macOS production Seatbelt")
    def test_resume_rejects_journal_advance_without_replaying_provider(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path, manifest_path, manifest = self._materialize_contract(root)
            journal_path = root / "budget-control" / "journal.json"
            journal_path.parent.mkdir(mode=0o700)
            run_name = "run-ambiguous"

            def stop_after_checkpoint(stage, receipt):
                if stage == "after_rollout_resume_checkpoint" and len(
                    receipt["completed_sequences"]
                ) == 1:
                    raise RuntimeError("checkpoint stop")

            with _AuthorizationObservingServer(journal_path) as provider:
                fake = root / "fake-metacodes"
                self._write_fake_metacodes(fake, provider.url)
                with BudgetJournal(journal_path, self._authority(manifest)) as journal:
                    with self.assertRaisesRegex(RuntimeError, "checkpoint stop"):
                        self._run(
                            root,
                            journal,
                            fake,
                            source_path,
                            manifest_path,
                            run_name=run_name,
                            fault_hook=stop_after_checkpoint,
                        )
                self.assertEqual(provider.requests, 1)

                with BudgetJournal(journal_path, self._authority(manifest)) as advanced:
                    reservation = advanced.reserve(
                        BudgetTransaction(
                            run_id="ambiguous-provider-attempt",
                            manifest_sha256=hashlib.sha256(
                                stable_json(manifest).encode("utf-8")
                            ).hexdigest(),
                            model_fingerprint=manifest["execution"]["model_fingerprint"],
                            harness_fingerprint=hashlib.sha256(b"ambiguous").hexdigest(),
                            provider_identity=PRODUCTION_PROVIDER_ID,
                            max_cost_microusd=usd_to_microusd(1.0),
                            max_metered_tokens=100_000,
                        )
                    )
                    advanced.authorize_request(
                        reservation["transaction_id"],
                        expected_revision=reservation["journal_revision"],
                        expected_head_sha256=reservation["journal_head_sha256"],
                    )

                with BudgetJournal(journal_path, self._authority(manifest)) as recovered:
                    with self.assertRaisesRegex(
                        ValidationError,
                        "journal advanced beyond the artifact checkpoint",
                    ):
                        self._run(
                            root,
                            recovered,
                            fake,
                            source_path,
                            manifest_path,
                            run_name=run_name,
                            resume_paid_run=True,
                        )
                self.assertEqual(provider.requests, 1)

    @unittest.skipUnless(platform.system() == "Darwin", "requires macOS production Seatbelt")
    def test_external_ripgrep_may_disappear_after_run_snapshot_without_spending_gap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path, manifest_path, manifest = self._materialize_contract(root)
            journal_path = root / "budget-control" / "journal.json"
            journal_path.parent.mkdir(mode=0o700)
            external_ripgrep = root / "ephemeral-rg"
            external_ripgrep.write_bytes(TEST_RIPGREP.read_bytes())
            external_ripgrep.chmod(0o700)
            production = self._production(external_ripgrep)
            removed = False

            def remove_external_after_provider(stage, _receipt):
                nonlocal removed
                if stage == "after_provider_return_before_commit" and not removed:
                    external_ripgrep.unlink()
                    removed = True

            with _AuthorizationObservingServer(journal_path) as provider:
                fake = root / "fake-metacodes"
                self._write_fake_metacodes(fake, provider.url)
                with BudgetJournal(
                    journal_path,
                    self._authority(manifest, production),
                ) as journal:
                    observations, receipt = self._run(
                        root,
                        journal,
                        fake,
                        source_path,
                        manifest_path,
                        run_name="run-snapshotted-toolchain",
                        fault_hook=remove_external_after_provider,
                        production=production,
                    )
            self.assertTrue(removed)
            self.assertFalse(external_ripgrep.exists())
            self.assertEqual(provider.requests, 2)
            self.assertEqual(receipt["ripgrep_snapshot_path"], PRODUCTION_RIPGREP_SNAPSHOT_PATH)
            snapshot = root / "run-snapshotted-toolchain" / receipt["ripgrep_snapshot_path"]
            self.assertTrue(snapshot.is_file())
            self.assertTrue(os.access(snapshot, os.X_OK))
            self.assertEqual(hashlib.sha256(snapshot.read_bytes()).hexdigest(), TEST_RIPGREP_SHA256)
            validate_runtime_receipt(
                receipt,
                manifest,
                observations,
                manifest["dataset"]["source_sha256"],
            )
            validate_runtime_artifacts(receipt, root / "run-snapshotted-toolchain")

            forged = copy.deepcopy(receipt)
            forged["ripgrep_snapshot_path"] = receipt["rollouts"][0]["artifact_paths"][
                "transcript"
            ] + "/.metacodes/toolchain/rg"
            with self.assertRaisesRegex(ValidationError, "canonical host snapshot"):
                validate_runtime_receipt(
                    forged,
                    manifest,
                    observations,
                    manifest["dataset"]["source_sha256"],
                )

            snapshot.chmod(0o400)
            with self.assertRaisesRegex(ValidationError, "permissions must remain 0500"):
                validate_runtime_artifacts(receipt, root / "run-snapshotted-toolchain")

    @unittest.skipUnless(platform.system() == "Darwin", "requires macOS production Seatbelt")
    def test_hard_child_signal_after_provider_persists_authorized_diagnostic(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path, manifest_path, manifest = self._materialize_contract(root)
            journal_path = root / "budget-control" / "journal.json"
            journal_path.parent.mkdir(mode=0o700)
            with _AuthorizationObservingServer(journal_path) as provider:
                fake = root / "fake-metacodes"
                self._write_fake_metacodes(
                    fake,
                    provider.url,
                    crash_after_provider=True,
                )
                with BudgetJournal(journal_path, self._authority(manifest)) as journal:
                    with self.assertRaisesRegex(ValidationError, "SIGTERM"):
                        self._run(
                            root,
                            journal,
                            fake,
                            source_path,
                            manifest_path,
                            run_name="run-hard-exit",
                        )
                    self.assertEqual(
                        journal.snapshot()["transaction_states"],
                        {"request_authorized": 1},
                    )
            self.assertEqual(provider.requests, 1)
            rollouts = list((root / "run-hard-exit" / "rollouts").iterdir())
            self.assertEqual(len(rollouts), 1)
            diagnostic = json.loads(
                (rollouts[0] / "child-process-failure.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(diagnostic["returncode"], -signal.SIGTERM)
            self.assertEqual(diagnostic["signal"], signal.SIGTERM)
            self.assertEqual(diagnostic["signal_name"], "SIGTERM")
            self.assertEqual(
                diagnostic["budget_transaction"]["state"],
                "request_authorized",
            )
            self.assertIsNone(diagnostic["budget_transaction"]["commit_revision"])
            self.assertTrue((rollouts[0] / "stdout.ndjson").is_file())
            self.assertTrue((rollouts[0] / "stderr.log").is_file())

    @requires_posix_budget_journal
    def test_second_pilot_runner_loses_lock_before_credential_or_network(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path, manifest_path, manifest = self._materialize_contract(root)
            journal_path = root / "budget-control" / "journal.json"
            journal_path.parent.mkdir(mode=0o700)
            invoked = root / "provider-capable-child-was-invoked"
            fake = root / "fake-metacodes"
            fake.write_text(
                f"#!/bin/sh\n/bin/echo invoked > {str(invoked)!r}\nexit 99\n",
                encoding="utf-8",
            )
            fake.chmod(0o700)
            tinykg = root / "fake-tinykg"
            self._write_compatible_fake_tinykg(tinykg)
            missing_auth = root / "must-not-be-read.json"
            command = [
                sys.executable,
                "-m",
                "scripts.eval.memory_agent_runtime_pilot",
                "--binary",
                str(fake),
                "--tinykg-binary",
                str(tinykg),
                "--ripgrep-binary",
                str(TEST_RIPGREP),
                "--source",
                str(source_path),
                "--manifest",
                str(manifest_path),
                "--run-dir",
                str(root / "loser-run"),
                "--budget-journal",
                str(journal_path),
                "--auth-file",
                str(missing_auth),
                "--max-total-cost-usd",
                "3.0",
                "--max-total-metered-tokens",
                "300000",
                "--max-rollout-cost-usd",
                "1.0",
                "--max-rollout-metered-tokens",
                "100000",
                "--allow-paid-rollouts",
            ]
            with BudgetJournal(journal_path, self._authority(manifest)):
                completed = subprocess.run(
                    command,
                    cwd=ROOT,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=10,
                    check=False,
                )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("another local runner holds it", completed.stderr)
            self.assertFalse(missing_auth.exists())
            self.assertFalse(invoked.exists())
            self.assertFalse((root / "loser-run").exists())

    @requires_posix_budget_journal
    def test_resume_checkpoint_failure_precedes_credential_loading(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path, manifest_path, _manifest = self._materialize_contract(root)
            run_dir = root / "corrupt-resume-run"
            run_dir.mkdir(mode=0o700)
            checkpoint = run_dir / "rollout-resume-checkpoint.json"
            checkpoint.write_text("{}\n", encoding="utf-8")
            checkpoint.chmod(0o600)
            journal_path = root / "budget-control" / "journal.json"
            journal_path.parent.mkdir(mode=0o700)
            fake = root / "fake-metacodes"
            fake.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
            fake.chmod(0o700)
            tinykg = root / "fake-tinykg"
            self._write_compatible_fake_tinykg(tinykg)
            missing_auth = root / "credential-must-not-be-opened.json"
            arguments = [
                "--binary",
                str(fake),
                "--tinykg-binary",
                str(tinykg),
                "--ripgrep-binary",
                str(TEST_RIPGREP),
                "--source",
                str(source_path),
                "--manifest",
                str(manifest_path),
                "--run-dir",
                str(run_dir),
                "--budget-journal",
                str(journal_path),
                "--auth-file",
                str(missing_auth),
                "--max-total-cost-usd",
                "3.0",
                "--max-total-metered-tokens",
                "300000",
                "--max-rollout-cost-usd",
                "1.0",
                "--max-rollout-metered-tokens",
                "100000",
                "--allow-paid-rollouts",
                "--resume-paid-run",
            ]
            with mock.patch.object(
                memory_pilot,
                "_probe_tinykg_compatibility",
                return_value={"commands": [], "storage_format_version": 3, "schema_version": 3},
            ), mock.patch.object(memory_pilot, "_load_api_key") as load_key:
                with self.assertRaisesRegex(ValidationError, "field set drift"):
                    memory_pilot.main(arguments)
            load_key.assert_not_called()
            self.assertFalse(missing_auth.exists())

    @unittest.skipUnless(platform.system() == "Darwin", "requires macOS production Seatbelt")
    def test_pre_authorization_os_failure_aborts_without_provider_request(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path, manifest_path, manifest = self._materialize_contract(root)
            journal_path = root / "budget-control" / "journal.json"
            journal_path.parent.mkdir(mode=0o700)
            with _AuthorizationObservingServer(journal_path) as provider:
                fake = root / "fake-metacodes"
                self._write_fake_metacodes(fake, provider.url)
                with BudgetJournal(journal_path, self._authority(manifest)) as journal:
                    with mock.patch(
                        "scripts.eval.memory_agent_runtime.os.fpathconf",
                        side_effect=OSError("injected pre-authorization failure"),
                    ):
                        with self.assertRaisesRegex(
                            ValidationError, "injected pre-authorization failure"
                        ):
                            self._run(
                                root,
                                journal,
                                fake,
                                source_path,
                                manifest_path,
                                run_name="run-preauth-failure",
                            )
                    self.assertEqual(
                        journal.snapshot()["transaction_states"],
                        {"aborted_pre_request": 1},
                    )
                    self.assertEqual(journal.snapshot()["exposure_cost_microusd"], 0)
                self.assertEqual(provider.requests, 0)

    @unittest.skipUnless(
        platform.system() == "Darwin" and REAL_TINYKG.is_file(),
        "requires macOS Seatbelt and the pinned TinyKG binary",
    )
    def test_real_tinykg_catalog_publication_and_probe_precede_authorization(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = copy.deepcopy(load_manifest(FIXTURES / "smoke-manifest.json"))
            case = copy.deepcopy(manifest["cases"][0])
            arm = next(
                copy.deepcopy(item)
                for item in manifest["execution"]["arms"]
                if item["id"] == "tinykg_lexical"
            )
            control_arm = next(
                copy.deepcopy(item)
                for item in manifest["execution"]["arms"]
                if item["id"] == "no_memory"
            )
            manifest["dataset"]["adapter_id"] = "longmemeval-s-cleaned"
            manifest["dataset"]["adapter_revision"] = "real-tinykg-preauth-l2-v1"
            source = {
                "adapter_id": manifest["dataset"]["adapter_id"],
                "adapter_revision": manifest["dataset"]["adapter_revision"],
                "cases": [
                    {
                        "id": case["id"],
                        "sessions": [
                            {
                                "id": "session:warning-labels",
                                "source_position": 0,
                                "date": "2026/08/13 (Thu) 09:00",
                                "turns": [
                                    {
                                        "id": "turn:warning-labels:0",
                                        "turn_index": 0,
                                        "role": "user",
                                        "content": "The user chose amber for routine warning labels.",
                                    }
                                ],
                            }
                        ],
                    }
                ],
            }
            source_path = root / "source.json"
            source_path.write_text(stable_json(source) + "\n", encoding="utf-8")
            manifest["dataset"]["source_sha256"] = file_sha256(source_path)
            manifest["execution"]["model_id"] = "glm-5.2"
            manifest["execution"]["model_fingerprint"] = PRODUCTION_MODEL_FINGERPRINT
            manifest["execution"]["harness_revision"] = "real-tinykg-preauth-l2-v1"
            manifest["execution"]["arms"] = [arm, control_arm]
            manifest["execution"]["trials"] = 1
            manifest["cases"] = [case]
            manifest["schedule"] = [
                {
                    "sequence": 0,
                    "case_id": case["id"],
                    "trial": 0,
                    "arm": arm["id"],
                },
                {
                    "sequence": 1,
                    "case_id": case["id"],
                    "trial": 0,
                    "arm": control_arm["id"],
                },
            ]
            manifest_path = root / "manifest.json"
            manifest_path.write_text(stable_json(manifest) + "\n", encoding="utf-8")
            manifest = load_manifest(manifest_path)
            failed_journal_path = root / "budget-control-failed" / "journal.json"
            failed_journal_path.parent.mkdir(mode=0o700)
            original_command = memory_runtime.LocalTinyKg.command

            def fail_catalog_publication(local, action, store, extra):
                if action == "rebuild-text":
                    raise ValidationError("injected TinyKG catalog publication failure")
                return original_command(local, action, store, extra)

            with _AuthorizationObservingServer(failed_journal_path) as failed_provider:
                failed_fake = root / "fake-metacodes-rebuild-failure"
                self._write_fake_metacodes(failed_fake, failed_provider.url)
                with BudgetJournal(
                    failed_journal_path,
                    self._authority(manifest),
                ) as failed_journal:
                    with mock.patch.object(
                        memory_runtime.LocalTinyKg,
                        "command",
                        new=fail_catalog_publication,
                    ):
                        with self.assertRaisesRegex(
                            ValidationError,
                            "injected TinyKG catalog publication failure",
                        ):
                            failed_run = root / "run-real-tinykg-rebuild-failure"
                            run_memory_agent_schedule(
                                metacodes_binary=failed_fake,
                                expected_metacodes_sha256=file_sha256(failed_fake),
                                tinykg_binary=REAL_TINYKG,
                                expected_tinykg_sha256=file_sha256(REAL_TINYKG),
                                source_path=source_path,
                                manifest_path=manifest_path,
                                run_dir=failed_run,
                                observations_path=failed_run / "observations.jsonl",
                                runtime_receipt_path=failed_run / "runtime-receipt.json",
                                timeout_seconds=30,
                                production=self._production(),
                                budget_journal=failed_journal,
                            )
                    failed_snapshot = failed_journal.snapshot()
                    self.assertEqual(failed_snapshot["transaction_states"], {})
                    self.assertEqual(failed_snapshot["exposure_cost_microusd"], 0)
                    self.assertEqual(failed_snapshot["exposure_metered_tokens"], 0)
                self.assertEqual(failed_provider.requests, 0)
                self.assertFalse(failed_provider.errors)

            journal_path = root / "budget-control" / "journal.json"
            journal_path.parent.mkdir(mode=0o700)
            production = self._production()
            observed_probe = []
            prepared_store_digests = []
            original_probe = memory_runtime._run_production_sandbox_probe

            def fail_after_real_probe(*args, **kwargs):
                kwargs["read_only_probes"] = tuple(
                    item for item in kwargs["read_only_probes"] if item[1].exists()
                )
                probe_binary, probe_store, _probe_query = kwargs["tinykg_read_probe"]
                store_info = subprocess.run(
                    [str(probe_binary), "store-info", str(probe_store)],
                    env={"PATH": os.defpath, "LC_ALL": "C", "LANG": "C"},
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=30,
                    check=False,
                )
                self.assertEqual(store_info.returncode, 0, store_info.stderr)
                self.assertIn("text_current=1", store_info.stdout)
                self.assertIn("text_stale=0", store_info.stdout)
                prepared_store_digests.append(_artifact_tree_digest(probe_store))
                evidence = original_probe(*args, **kwargs)
                self.assertEqual(
                    _artifact_tree_digest(probe_store), prepared_store_digests[-1]
                )
                observed_probe.append(evidence)
                raise ValidationError("injected after real TinyKG read probe")

            with _AuthorizationObservingServer(journal_path) as provider:
                fake = root / "fake-metacodes"
                self._write_fake_metacodes(fake, provider.url)
                with BudgetJournal(
                    journal_path,
                    self._authority(manifest, production),
                ) as journal:
                    with mock.patch(
                        "scripts.eval.memory_agent_runtime._run_production_sandbox_probe",
                        side_effect=fail_after_real_probe,
                    ):
                        with self.assertRaisesRegex(
                            ValidationError, "injected after real TinyKG read probe"
                        ):
                            run_dir = root / "run-real-tinykg-preauth"
                            run_memory_agent_schedule(
                                metacodes_binary=fake,
                                expected_metacodes_sha256=file_sha256(fake),
                                tinykg_binary=REAL_TINYKG,
                                expected_tinykg_sha256=file_sha256(REAL_TINYKG),
                                source_path=source_path,
                                manifest_path=manifest_path,
                                run_dir=run_dir,
                                observations_path=run_dir / "observations.jsonl",
                                runtime_receipt_path=run_dir / "runtime-receipt.json",
                                timeout_seconds=30,
                                production=production,
                                budget_journal=journal,
                            )
                    snapshot = journal.snapshot()
                    self.assertEqual(snapshot["transaction_states"], {})
                    self.assertEqual(snapshot["exposure_cost_microusd"], 0)
                    self.assertEqual(snapshot["exposure_metered_tokens"], 0)
                self.assertEqual(provider.requests, 0)
                self.assertEqual(len(observed_probe), 1)
                self.assertEqual(len(prepared_store_digests), 1)
                self.assertTrue(observed_probe[0]["tinykg_read_probe_performed"])
                self.assertTrue(observed_probe[0]["tinykg_store_unchanged"])
                self.assertTrue(observed_probe[0]["tinykg_lock_path_clean"])

if __name__ == "__main__":
    unittest.main()
