import copy
import hashlib
import http.server
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest
from pathlib import Path
from unittest import mock

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
    validate_checkpoint_payload,
    usd_to_microusd,
)
from scripts.eval.memory_replay import (
    PRODUCTION_ALLOWED_PROVIDER_TOOLS,
    PRODUCTION_PRICING_PROVENANCE,
    PRODUCTION_PROVIDER_ID,
    _artifact_tree_digest,
    load_manifest,
    validate_runtime_artifacts,
    validate_runtime_receipt,
)
from scripts.eval.model import ValidationError, stable_json


ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "evals/memory/fixtures"
TEST_RIPGREP = Path(sys.executable).resolve()
TEST_RIPGREP_SHA256 = hashlib.sha256(TEST_RIPGREP.read_bytes()).hexdigest()


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

    def _write_fake_metacodes(self, path: Path, provider_url: str) -> None:
        script = textwrap.dedent(
            f"""\
            #!/usr/bin/python3 -I
            import json
            import os
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
                "system": "",
                "tools": [],
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
            "  store-info) printf 'nodes=1\\nedges=0\\nstorage_format_version=2\\n"
            "schema_version=3\\n' ;;\n"
            "  *) exit 91 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        path.chmod(0o700)

    def _production(self) -> ProductionRuntimeConfig:
        return ProductionRuntimeConfig(
            api_key="runtime-l2-private-key",
            allow_paid_rollouts=True,
            max_total_cost_usd=3.0,
            max_total_metered_tokens=300_000,
            max_rollout_cost_usd=1.0,
            max_rollout_metered_tokens=100_000,
            max_output_tokens=128,
            ripgrep_binary=TEST_RIPGREP,
            ripgrep_binary_sha256=TEST_RIPGREP_SHA256,
        )

    def _authority(self, manifest) -> BudgetAuthority:
        production = self._production()
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
            production=self._production(),
            budget_journal=journal,
            budget_fault_hook=fault_hook,
        )

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

if __name__ == "__main__":
    unittest.main()
