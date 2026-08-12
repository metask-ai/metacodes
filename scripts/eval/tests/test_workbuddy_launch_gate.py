import hashlib
import http.server
import json
import os
import sys
import tempfile
import threading
import unittest
import time
from pathlib import Path
from unittest import mock

import yaml

from scripts.eval.memory_budget_journal import (
    BudgetAuthority,
    BudgetJournal,
    BudgetTransaction,
    validate_checkpoint_payload,
)
from scripts.eval.model import ValidationError, stable_json
from scripts.eval.workbuddy.launch_gate import (
    AUTHORIZED_FAILURE_RECEIPT_SCHEMA_VERSION,
    AUTHORIZED_FAILURE_RECEIPT_SCHEMA_VERSION_V1,
    LaunchError,
    PROVIDER_KEY_ENV,
    SCHEMA_VERSION,
    HOST_CONTROL_PLANE_MODULES,
    _artifact_contract,
    _paid_host_guard,
    _official_task_identity,
    _collect_usage,
    _aggregate_control_metrics,
    _validate_control_metrics,
    _receipt_quality_evidence,
    _reobserve_host_control_plane,
    _reobserve_launch_inputs,
    _runtime_contract,
    _validate_trial_project_control,
    execute_launch,
    recover_authorized_failure_receipt,
    validate_authorized_failure_receipt,
    validate_launch_manifest,
)
from scripts.eval.workbuddy.trace import (
    OBSERVATION_JOURNAL_SCHEMA,
    OBSERVATION_FILENAME,
    load_control_metrics,
)
from scripts.eval.workbuddy import WORKBUDDY_PINNED_COMMIT
from scripts.eval.workbuddy.install_overlay import _digest
from scripts.eval.workbuddy.stage_artifacts import stage


def digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


class _Server:
    def __init__(self, journal_path: Path, *, response_status: int = 200):
        self.journal_path = journal_path
        self.response_status = response_status
        self.requests = 0
        self.errors = []
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                return

            def do_POST(self):
                owner.requests += 1
                try:
                    state = validate_checkpoint_payload(owner.journal_path.read_bytes())
                    states = {
                        row["state"] for row in state["transactions"].values()
                    }
                    if "request_authorized" not in states:
                        raise AssertionError(
                            "WorkBuddy provider request preceded durable authorization"
                        )
                    length = int(self.headers.get("content-length", "0"))
                    self.rfile.read(length)
                except BaseException as exc:
                    owner.errors.append(str(exc))
                    self.send_response(500)
                    self.end_headers()
                    return
                self.send_response(owner.response_status)
                self.send_header("content-type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"provider_body":"must-not-enter-receipt"}')

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    @property
    def url(self):
        host, port = self.httpd.server_address
        return f"http://{host}:{port}/provider"

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_args):
        self.httpd.shutdown()
        self.thread.join(timeout=5)
        self.httpd.server_close()


class WorkBuddyPaidLaunchGateL2Test(unittest.TestCase):
    def test_artifact_contract_recomputes_project_kernel_and_rule_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            elf = root / "fixture-elf"
            header = bytearray(20)
            header[:7] = b"\x7fELF\x02\x01\x01"
            header[18:20] = (62).to_bytes(2, "little")
            elf.write_bytes(header + b"fixture\n")
            elf.chmod(0o755)
            license_file = root / "LICENSE"
            license_file.write_text("fixture license\n", encoding="utf-8")
            rules = root / "rules"
            rules.mkdir()
            kernel_sha = hashlib.sha256(elf.read_bytes()).hexdigest()
            project_sha = hashlib.sha256(
                b"metacodes-project-identity-v1\x00/workspace"
            ).hexdigest()
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
            stage(
                output=output,
                metacodes=elf,
                tinykg=elf,
                formal_kernel=elf,
                project_kernel=elf,
                project_rules=rules,
                metacodes_commit="0" * 40,
                tinykg_commit="1" * 40,
                licenses=(
                    ("metacodes", "NOASSERTION", license_file),
                    ("tinykg", "Apache-2.0", license_file),
                    ("lean4", "Apache-2.0", license_file),
                ),
            )
            manifest = output / "share/metacodes/artifact-manifest.json"
            observed = _artifact_contract(manifest)
            self.assertEqual(observed["project_control"]["kernel"]["sha256"], kernel_sha)
            self.assertEqual(observed["project_control"]["rules"]["files"], 2)
            self.assertEqual(
                observed["project_control"]["rules"]["project_root"],
                "/workspace",
            )
            self.assertEqual(
                observed["project_control"]["kernel"]["relative_path"],
                "libexec/metacodes-project-kernel",
            )
            self.assertEqual(
                observed["project_control"]["rules"]["relative_path"],
                "share/metacodes/workbuddy-w05/project-rules",
            )

            staged_bundle = (
                output
                / "share/metacodes/workbuddy-w05/project-rules/bundle.json"
            )
            staged_bundle.write_text('{"tampered":true}\n', encoding="utf-8")
            with self.assertRaisesRegex(LaunchError, "tree identity drifted"):
                _artifact_contract(manifest)

    def _manifest(
        self, root: Path, *, quality_evidence_on_commit: bool = False
    ) -> Path:
        workbuddy = root / "workbuddy"
        workbuddy.mkdir(mode=0o700)
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "quality_evidence": False,
            "quality_evidence_on_commit": quality_evidence_on_commit,
            "run_id": "workbuddy-l2-run-1",
            "workbuddy": {
                "checkout": str(workbuddy),
                "commit": WORKBUDDY_PINNED_COMMIT,
                "overlay": {"sha256": digest("overlay")},
                "overlay_content_sha256": digest("installed-overlay"),
            },
            "cohort": {
                "subset": "code",
                "cohort": "dev",
                "dataset": "datasets/wb-bench-code-v1.0/tasks",
                "take": 1,
                "selected_tasks": ["code-task-a"],
                "selected_tasks_sha256": digest("tasks"),
            },
            "artifacts": {"manifest": {"sha256": digest("artifacts")}},
            "environment_preflight": {
                "receipt": {
                    "path": "/fixture/environment-preflight.json",
                    "bytes": 1,
                    "sha256": digest("environment-preflight-receipt"),
                },
                "content_sha256": digest("environment-preflight-content"),
                "target_platform": "linux/amd64",
            },
            "job": {"slug": "metacodes-code-l2", "config": {"sha256": digest("job")}},
            "model": {
                "slug": "test-model",
                "config": {"sha256": digest("model-config")},
                "provider_identity": "workbuddy-l2-mock-provider",
                "fingerprint": digest("model"),
            },
            "harness_fingerprint": digest("harness"),
            "host_control_plane": {
                name: {
                    "path": f"/fixture/{name}.py",
                    "bytes": 1,
                    "sha256": digest(name),
                }
                for name in HOST_CONTROL_PLANE_MODULES
            },
            "budget": {
                "total_cost_microusd": 1_000_000,
                "total_metered_tokens": 100_000,
                "max_cost_microusd": 500_000,
                "max_metered_tokens": 50_000,
                "prior_exposure_microusd": 0,
                "user_authority_microusd": 2_000_000_000,
            },
            "execution": {
                "n_attempts": 1,
                "n_concurrent_trials": 1,
                "shards": 1,
                "proxy_max_retries": 0,
                "shared_proxy": False,
                "credential_delivery": "anonymous-fd",
                "provider_key_env": PROVIDER_KEY_ENV,
                "remote_tinykg_env_cleared": True,
                "local_tinykg": "fresh-home-per-trial",
                "cacheable_first_request_hash_required": True,
                "target_platform": "linux/amd64",
                "docker_default_platform": "linux/amd64",
                "environment_preflight_required": True,
                "harbor_force_build": False,
                "runner_tools": {
                    "bash": {
                        "path": "/fixture/bash",
                        "sha256": digest("bash"),
                        "version_sha256": digest("bash-version"),
                    },
                    "uv": {
                        "path": "/fixture/uv",
                        "sha256": digest("uv"),
                        "version_sha256": digest("uv-version"),
                    },
                },
                "runner": [
                    "/fixture/uv", "run", "--frozen", "/fixture/bash", "scripts/run.sh", "--job",
                    "metacodes-code-l2",
                ],
            },
            "dry_run": {
                "network_requests": 0,
                "credential_loaded": False,
                "journal_mutations": 0,
                "paid_rollouts_authorized": False,
            },
        }
        manifest["content_sha256"] = hashlib.sha256(
            stable_json(manifest).encode("utf-8")
        ).hexdigest()
        path = root / "launch.json"
        path.write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(path, 0o600)
        return path

    @staticmethod
    def _runner_code() -> str:
        return r'''
import json, os, sys, urllib.request
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from scripts.eval.workbuddy.key_fd import resolve_secret_env
from scripts.eval.workbuddy.trace import OBSERVATION_JOURNAL_SCHEMA, load_control_metrics
secret = resolve_secret_env("", "METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF")
assert secret == "private-workbuddy-test-key"
assert "METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF" not in os.environ
request = urllib.request.Request(sys.argv[2], data=b"{}", method="POST")
with urllib.request.urlopen(request, timeout=5) as response:
    assert response.status == 200
agent = Path(sys.argv[3]) / "results/metacodes-code-l2/run/code-task-a__1/agent"
agent.mkdir(parents=True)
transcript = agent / "metacodes-transcript.jsonl"
transcript.write_text(json.dumps({"role": "user", "blocks": [{"type": "text", "text": "task"}]}) + "\n")
observation = agent / "metacodes-tool-observations.jsonl"
observation.write_text(
    json.dumps({"schema_version": OBSERVATION_JOURNAL_SCHEMA, "sequence": 0,
                "session_id": "session-l2", "run_id": "run-l2",
                "monotonic_elapsed_ns": 0, "event": {"run_started": {}}}) + "\n"
    + json.dumps({"schema_version": OBSERVATION_JOURNAL_SCHEMA, "sequence": 1,
                  "session_id": "session-l2", "run_id": "run-l2",
                  "monotonic_elapsed_ns": 1, "event": {"run_finished": {}}}) + "\n"
)
control_metrics = load_control_metrics(transcript, observation)
trajectory = {
  "final_metrics": {
    "total_prompt_tokens": 120,
    "total_completion_tokens": 30,
    "total_cached_tokens": 80,
    "total_cost_usd": 0.01,
    "extra": {"cache_creation_input_tokens": 10, "control_metrics": control_metrics}
  }
}
(agent / "trajectory.json").write_text(json.dumps(trajectory) + "\n")
record = {"request": {"body": {"model": "volatile-route", "system": "stable", "messages": [{"role": "user", "content": "task"}]}}}
(agent / "requests.jsonl").write_text(json.dumps(record) + "\n")
'''

    @staticmethod
    def _failure_runner_code() -> str:
        return r'''
import json, os, sys, urllib.error, urllib.request
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from scripts.eval.workbuddy.key_fd import resolve_secret_env
secret = resolve_secret_env("", "METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF")
assert secret == "private-workbuddy-test-key"
assert "METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF" not in os.environ
request = urllib.request.Request(
    sys.argv[2], data=b'{"secret_prompt":"must-not-enter-receipt"}', method="POST"
)
status = 0
try:
    urllib.request.urlopen(request, timeout=5)
except urllib.error.HTTPError as error:
    status = error.code
assert status == 503
agent = Path(sys.argv[3]) / "results/metacodes-code-l2/run/code-task-a__1/agent"
agent.mkdir(parents=True)
record = {
    "duration_ms": 12.5,
    "error": "Backend returned 503 with secret_prompt and private-workbuddy-test-key",
    "request": {"body": {"prompt": "must-not-enter-receipt"}},
    "response": {
        "status": 503,
        "raw_bytes": 51,
        "content_len": 51,
        "tool_calls_count": 0,
        "upstream_error_body": "must-not-enter-receipt",
    },
}
(agent / "requests.jsonl").write_text(json.dumps(record) + "\n")
(agent.parent / "exception.txt").write_text(
    "private-workbuddy-test-key must-not-enter-receipt\n"
)
raise SystemExit(23)
'''

    @staticmethod
    def _credential_fd():
        read_fd, write_fd = os.pipe()
        os.write(write_fd, b"private-workbuddy-test-key")
        os.close(write_fd)
        return read_fd

    def test_real_child_provider_observes_authorized_journal_and_receipt_binds_usage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            manifest = self._manifest(root)
            journal = root / "budget.json"
            receipt = root / "receipt.json"
            repo = Path(__file__).resolve().parents[3]
            with _Server(journal) as provider:
                result = execute_launch(
                    manifest_path=manifest,
                    journal_path=journal,
                    receipt_path=receipt,
                    credential_fd=self._credential_fd(),
                    runner_argv=[
                        sys.executable,
                        "-c",
                        self._runner_code(),
                        str(repo),
                        provider.url,
                        str(root / "workbuddy"),
                    ],
                )
            self.assertEqual(provider.requests, 1)
            self.assertFalse(provider.errors)
            self.assertFalse(result["quality_evidence"])
            self.assertEqual(result["budget_transaction"]["state"], "committed")
            self.assertEqual(result["usage"]["cost_microusd"], 10_000)
            self.assertEqual(result["usage"]["metered_tokens"], 240)
            self.assertEqual(result["usage"]["provider_requests"], 1)
            task = result["usage"]["tasks"]["code-task-a"]
            self.assertEqual(task["cache_read_input_tokens"], 80)
            self.assertEqual(task["cache_creation_input_tokens"], 10)
            self.assertEqual(task["metered_tokens"], 240)
            self.assertEqual(len(task["cacheable_first_request_sha256"]), 64)
            self.assertFalse(task["control_metrics"]["lean"]["used"])
            self.assertFalse(task["control_metrics"]["tinykg"]["used"])
            self.assertEqual(result["usage"]["control_metrics"]["tasks"], 1)
            self.assertEqual(result["usage"]["control_metrics"]["lean_used_tasks"], 0)
            self.assertEqual(len(task["control_metrics"]["source"]["transcript_sha256"]), 64)
            self.assertEqual(
                len(task["control_metrics"]["source"]["observation_journal_sha256"]),
                64,
            )
            self.assertTrue(receipt.is_file())
            self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)
            self.assertNotIn("private-workbuddy-test-key", receipt.read_text())

    def test_real_child_provider_503_writes_private_authorized_failure_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            manifest = self._manifest(root)
            journal = root / "budget.json"
            receipt = root / "authorized-failure.json"
            repo = Path(__file__).resolve().parents[3]
            with _Server(journal, response_status=503) as provider:
                with self.assertRaisesRegex(
                    LaunchError, "runner exited 23.*retry is forbidden"
                ):
                    execute_launch(
                        manifest_path=manifest,
                        journal_path=journal,
                        receipt_path=receipt,
                        credential_fd=self._credential_fd(),
                        runner_argv=[
                            sys.executable,
                            "-c",
                            self._failure_runner_code(),
                            str(repo),
                            provider.url,
                            str(root / "workbuddy"),
                        ],
                    )
            self.assertEqual(1, provider.requests)
            self.assertFalse(provider.errors)
            self.assertEqual(0o600, receipt.stat().st_mode & 0o777)
            failure = validate_authorized_failure_receipt(
                receipt, journal_path=journal
            )
            self.assertEqual(
                AUTHORIZED_FAILURE_RECEIPT_SCHEMA_VERSION,
                failure["schema_version"],
            )
            self.assertEqual("authorized_failure", failure["state"])
            self.assertEqual("runner_nonzero", failure["failure_stage"])
            self.assertEqual("in_band", failure["receipt_mode"])
            self.assertFalse(failure["quality_evidence"])
            self.assertFalse(failure["retry_allowed"])
            self.assertFalse(failure["actual_usage_known"])
            self.assertEqual(
                "request_authorized", failure["budget_transaction"]["state"]
            )
            self.assertIsNone(
                failure["budget_transaction"]["actual_cost_microusd"]
            )
            self.assertIsNone(
                failure["budget_transaction"]["actual_metered_tokens"]
            )
            self.assertEqual(500_000, failure["journal"]["exposure_cost_microusd"])
            self.assertEqual(50_000, failure["journal"]["exposure_metered_tokens"])
            self.assertEqual(23, failure["runner"]["returncode"])
            self.assertEqual(
                {"503": 1},
                failure["failure_evidence"]["request_audit"][
                    "response_status_counts"
                ],
            )
            self.assertGreaterEqual(
                failure["failure_evidence"]["artifact_count"], 2
            )
            receipt_text = receipt.read_text(encoding="utf-8")
            for forbidden in (
                "private-workbuddy-test-key",
                "secret_prompt",
                "must-not-enter-receipt",
                "upstream_error_body",
            ):
                self.assertNotIn(forbidden, receipt_text)

            legacy_path = root / "legacy-authorized-failure.json"
            legacy = dict(failure)
            legacy["schema_version"] = AUTHORIZED_FAILURE_RECEIPT_SCHEMA_VERSION_V1
            legacy.pop("failure_stage")
            legacy.pop("receipt_mode")
            legacy["runner"].pop("elapsed_seconds_semantics")
            legacy_path.write_text(
                json.dumps(legacy, sort_keys=True) + "\n", encoding="utf-8"
            )
            os.chmod(legacy_path, 0o600)
            self.assertEqual(
                AUTHORIZED_FAILURE_RECEIPT_SCHEMA_VERSION_V1,
                validate_authorized_failure_receipt(
                    legacy_path, journal_path=journal
                )["schema_version"],
            )

            # A fresh receipt path does not mask the durable journal rule: the
            # same run is rejected before another provider request.
            with _Server(journal, response_status=503) as retry_provider:
                with self.assertRaisesRegex(ValidationError, "retry is forbidden"):
                    execute_launch(
                        manifest_path=manifest,
                        journal_path=journal,
                        receipt_path=root / "forbidden-retry.json",
                        credential_fd=self._credential_fd(),
                        runner_argv=[sys.executable, "-c", "raise SystemExit(99)"],
                    )
            self.assertEqual(0, retry_provider.requests)

    def test_runner_zero_with_invalid_post_run_evidence_writes_failure_receipt(self):
        """Harbor may return zero even when every agent trial failed.

        The real provider path must still leave a durable, non-retryable
        receipt when the subsequent trajectory/identity audit rejects the run.
        This covers the production Code-3 failure mode that a helper-only test
        cannot establish.
        """

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            manifest = self._manifest(root)
            journal = root / "budget.json"
            receipt = root / "post-run-audit-failure.json"
            repo = Path(__file__).resolve().parents[3]
            runner = r'''
import os, sys, urllib.request
sys.path.insert(0, sys.argv[1])
from scripts.eval.workbuddy.key_fd import resolve_secret_env
secret = resolve_secret_env("", "METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF")
assert secret == "private-workbuddy-test-key"
with urllib.request.urlopen(
    urllib.request.Request(sys.argv[2], data=b"{}", method="POST"), timeout=5
) as response:
    assert response.status == 200
# Deliberately return zero without the required bound trajectory.  This is the
# shape of a batch runner that completed orchestration while its trial failed.
'''
            with _Server(journal) as provider:
                with self.assertRaisesRegex(
                    LaunchError,
                    "post-run evidence audit failed after runner exit 0.*retry is forbidden",
                ):
                    execute_launch(
                        manifest_path=manifest,
                        journal_path=journal,
                        receipt_path=receipt,
                        credential_fd=self._credential_fd(),
                        runner_argv=[
                            sys.executable,
                            "-c",
                            runner,
                            str(repo),
                            provider.url,
                        ],
                    )
            self.assertEqual(1, provider.requests)
            self.assertFalse(provider.errors)
            failure = validate_authorized_failure_receipt(
                receipt, journal_path=journal
            )
            self.assertEqual(0, failure["runner"]["returncode"])
            self.assertEqual(
                "post_run_evidence_audit", failure["failure_stage"]
            )
            self.assertEqual("in_band", failure["receipt_mode"])
            self.assertEqual(
                "request_authorized", failure["budget_transaction"]["state"]
            )
            self.assertFalse(failure["retry_allowed"])
            self.assertFalse(failure["quality_evidence"])
            self.assertEqual(0o600, receipt.stat().st_mode & 0o777)

            contradictory_path = root / "contradictory-failure.json"
            contradictory = dict(failure)
            contradictory["failure_stage"] = "runner_nonzero"
            contradictory_path.write_text(
                json.dumps(contradictory, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(LaunchError, "stage contradicts"):
                validate_authorized_failure_receipt(contradictory_path)

    def test_offline_failure_recovery_reopens_authorized_without_provider(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            manifest_path = self._manifest(root)
            manifest = validate_launch_manifest(manifest_path)
            journal_path = root / "budget.json"
            receipt_path = root / "offline-failure.json"
            budget = manifest["budget"]
            model = manifest["model"]
            authority = BudgetAuthority(
                manifest_sha256=manifest["content_sha256"],
                model_fingerprint=model["fingerprint"],
                provider_identity=model["provider_identity"],
                total_cost_microusd=budget["total_cost_microusd"],
                total_metered_tokens=budget["total_metered_tokens"],
            )
            transaction = BudgetTransaction(
                run_id=manifest["run_id"],
                manifest_sha256=manifest["content_sha256"],
                model_fingerprint=model["fingerprint"],
                harness_fingerprint=manifest["harness_fingerprint"],
                provider_identity=model["provider_identity"],
                max_cost_microusd=budget["max_cost_microusd"],
                max_metered_tokens=budget["max_metered_tokens"],
            )
            started_ns = time.time_ns() - 1_000_000
            with BudgetJournal(journal_path, authority) as journal:
                reserved = journal.reserve(transaction)
                authorized = journal.authorize_request(
                    reserved["transaction_id"],
                    expected_revision=reserved["journal_revision"],
                    expected_head_sha256=reserved["journal_head_sha256"],
                )
                head_before = authorized["journal_head_sha256"]

            receipt = recover_authorized_failure_receipt(
                manifest_path=manifest_path,
                journal_path=journal_path,
                receipt_path=receipt_path,
                runner_returncode=0,
                failure_stage="post_run_evidence_audit",
                started_ns=started_ns,
            )
            self.assertEqual("offline_recovery", receipt["receipt_mode"])
            self.assertEqual(
                "authorization_to_receipt_upper_bound",
                receipt["runner"]["elapsed_seconds_semantics"],
            )
            self.assertEqual(head_before, receipt["journal"]["head_sha256"])
            self.assertEqual(
                "request_authorized", receipt["budget_transaction"]["state"]
            )
            self.assertFalse(receipt["retry_allowed"])
            self.assertFalse(receipt["quality_evidence"])
            self.assertEqual(0o600, receipt_path.stat().st_mode & 0o777)

            with self.assertRaisesRegex(LaunchError, "already occupied"):
                recover_authorized_failure_receipt(
                    manifest_path=manifest_path,
                    journal_path=journal_path,
                    receipt_path=receipt_path,
                    runner_returncode=0,
                    failure_stage="post_run_evidence_audit",
                    started_ns=started_ns,
                )

    def test_injected_runner_cannot_create_quality_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            manifest = self._manifest(root, quality_evidence_on_commit=True)
            journal = root / "budget.json"
            repo = Path(__file__).resolve().parents[3]
            with _Server(journal) as provider:
                result = execute_launch(
                    manifest_path=manifest,
                    journal_path=journal,
                    receipt_path=root / "receipt.json",
                    credential_fd=self._credential_fd(),
                    runner_argv=[
                        sys.executable,
                        "-c",
                        self._runner_code(),
                        str(repo),
                        provider.url,
                        str(root / "workbuddy"),
                    ],
                )
            self.assertFalse(result["quality_evidence"])

    def test_receipt_quality_classification_requires_official_runner_and_opt_in(self):
        self.assertFalse(
            _receipt_quality_evidence(
                {"quality_evidence_on_commit": False}, official_runner=True
            )
        )
        self.assertFalse(
            _receipt_quality_evidence(
                {"quality_evidence_on_commit": True}, official_runner=False
            )
        )
        self.assertTrue(
            _receipt_quality_evidence(
                {"quality_evidence_on_commit": True}, official_runner=True
            )
        )

    def test_usage_rejects_boolean_token_counts(self):
        for field, value in (
            ("total_prompt_tokens", False),
            ("total_cached_tokens", False),
        ):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                agent = root / "results/job/run/code-task-a__1/agent"
                agent.mkdir(parents=True)
                metrics = {
                    "total_prompt_tokens": 1,
                    "total_completion_tokens": 1,
                    "total_cached_tokens": 1,
                    "total_cost_usd": 0.0,
                    "extra": {"cache_creation_input_tokens": 1},
                }
                metrics[field] = value
                (agent / "metacodes-transcript.jsonl").write_text(
                    json.dumps({"role": "user", "blocks": [{"type": "text", "text": "task"}]})
                    + "\n",
                    encoding="utf-8",
                )
                (agent / OBSERVATION_FILENAME).write_text(
                    json.dumps({"schema_version": OBSERVATION_JOURNAL_SCHEMA, "sequence": 0,
                                "session_id": "session-l2", "run_id": "run-l2",
                                "monotonic_elapsed_ns": 0, "event": {"run_started": {}}})
                    + "\n"
                    + json.dumps({"schema_version": OBSERVATION_JOURNAL_SCHEMA, "sequence": 1,
                                  "session_id": "session-l2", "run_id": "run-l2",
                                  "monotonic_elapsed_ns": 1, "event": {"run_finished": {}}})
                    + "\n",
                    encoding="utf-8",
                )
                metrics["extra"]["control_metrics"] = load_control_metrics(
                    agent / "metacodes-transcript.jsonl", agent / OBSERVATION_FILENAME
                )
                (agent / "trajectory.json").write_text(
                    json.dumps({"final_metrics": metrics}) + "\n", encoding="utf-8"
                )
                (agent / "requests.jsonl").write_text(
                    json.dumps({"request": {"body": {"model": "route"}}}) + "\n",
                    encoding="utf-8",
                )
                manifest = {
                    "workbuddy": {"checkout": str(root)},
                    "job": {"slug": "job"},
                    "cohort": {"selected_tasks": ["code-task-a"]},
                }
                with self.assertRaisesRegex(LaunchError, "invalid .*token usage"):
                    _collect_usage(manifest, started_ns=0, official_runner=False)

    def test_control_metrics_are_recomputed_and_hash_privacy_drift_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "metacodes-transcript.jsonl"
            observation = root / OBSERVATION_FILENAME
            trajectory = root / "trajectory.json"
            transcript.write_text(
                json.dumps({"role": "user", "blocks": []}) + "\n", encoding="utf-8"
            )
            observation.write_text(
                json.dumps({"schema_version": OBSERVATION_JOURNAL_SCHEMA, "sequence": 0,
                            "session_id": "session-l2", "run_id": "run-l2",
                            "monotonic_elapsed_ns": 0, "event": {"run_started": {}}})
                + "\n"
                + json.dumps({"schema_version": OBSERVATION_JOURNAL_SCHEMA, "sequence": 1,
                              "session_id": "session-l2", "run_id": "run-l2",
                              "monotonic_elapsed_ns": 1, "event": {"run_finished": {}}})
                + "\n",
                encoding="utf-8",
            )
            trajectory.write_text("{}\n", encoding="utf-8")
            metrics = load_control_metrics(transcript, observation)
            _validate_control_metrics(
                metrics,
                trajectory_path=trajectory,
                transcript_path=transcript,
                observation_path=observation,
            )

            forged = json.loads(json.dumps(metrics))
            forged["tinykg"]["recall_hit_calls"] = 99
            with self.assertRaisesRegex(LaunchError, "do not match"):
                _validate_control_metrics(
                    forged,
                    trajectory_path=trajectory,
                    transcript_path=transcript,
                    observation_path=observation,
                )

            bad_hash = json.loads(json.dumps(metrics))
            bad_hash["source"]["transcript_sha256"] = "0" * 64
            with self.assertRaisesRegex(LaunchError, "transcript hash"):
                _validate_control_metrics(
                    bad_hash,
                    trajectory_path=trajectory,
                    transcript_path=transcript,
                    observation_path=observation,
                )

            bad_privacy = json.loads(json.dumps(metrics))
            bad_privacy["privacy"]["memory_text_retained"] = True
            with self.assertRaisesRegex(LaunchError, "privacy"):
                _validate_control_metrics(
                    bad_privacy,
                    trajectory_path=trajectory,
                    transcript_path=transcript,
                    observation_path=observation,
                )

            observation.write_text(observation.read_text() + "\n", encoding="utf-8")
            with self.assertRaisesRegex(LaunchError, "observation hash"):
                _validate_control_metrics(
                    metrics,
                    trajectory_path=trajectory,
                    transcript_path=transcript,
                    observation_path=observation,
                )

    def test_control_metrics_wave_aggregation_sums_counts_but_preserves_maxima(self):
        def row(*, elapsed: int, maximum: int, kernel: str, used: bool):
            return {
                "tool_runtime": {
                    "transcript_tool_calls": 1,
                    "transcript_tool_results": 1,
                    "transcript_calls_without_result": 0,
                    "dispatch_started": 1,
                    "dispatch_finished": 1,
                    "dispatch_outcomes": {
                        "succeeded": 1,
                        "tool_error": 0,
                        "pending": 0,
                        "host_failed": 0,
                        "host_rejected": 0,
                        "host_fatal": 0,
                    },
                },
                "tinykg": {"used": used, "calls": int(used)},
                "lean": {
                    "used": True,
                    "checker_calls": 1,
                    "checker_elapsed_ns": elapsed,
                    "checker_elapsed_ns_max": maximum,
                    "checker_bytes_max": maximum * 10,
                    "kernel_sha256s": [kernel],
                    "bundle_sha256s": ["b" * 64],
                    "actuations": ["enforced"],
                },
            }

        aggregate = _aggregate_control_metrics({
            "task-a": row(elapsed=7, maximum=7, kernel="1" * 64, used=True),
            "task-b": row(elapsed=5, maximum=5, kernel="2" * 64, used=False),
        })
        self.assertEqual(aggregate["tasks"], 2)
        self.assertEqual(aggregate["tinykg_used_tasks"], 1)
        self.assertEqual(aggregate["lean"]["checker_elapsed_ns"], 12)
        self.assertEqual(aggregate["lean"]["checker_elapsed_ns_max"], 7)
        self.assertEqual(aggregate["lean"]["checker_bytes_max"], 70)
        self.assertEqual(aggregate["lean"]["kernel_sha256s"], ["1" * 64, "2" * 64])

    def test_authorization_crash_consumes_maximum_and_same_run_cannot_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            manifest = self._manifest(root)
            journal = root / "budget.json"
            receipt = root / "receipt.json"

            def crash(stage, _receipt):
                if stage == "after_request_authorized":
                    raise RuntimeError("injected crash")

            with self.assertRaisesRegex(RuntimeError, "injected crash"):
                execute_launch(
                    manifest_path=manifest,
                    journal_path=journal,
                    receipt_path=receipt,
                    credential_fd=self._credential_fd(),
                    runner_argv=[sys.executable, "-c", "raise SystemExit(99)"],
                    fault_hook=crash,
                )
            state = validate_checkpoint_payload(journal.read_bytes())
            latest = next(iter(state["transactions"].values()))
            self.assertEqual(latest["state"], "request_authorized")
            self.assertFalse(receipt.exists())
            with self.assertRaisesRegex(ValidationError, "retry is forbidden"):
                execute_launch(
                    manifest_path=manifest,
                    journal_path=journal,
                    receipt_path=receipt,
                    credential_fd=self._credential_fd(),
                    runner_argv=[sys.executable, "-c", "raise SystemExit(98)"],
                )

    def test_provider_received_then_crash_has_no_forged_failure_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            manifest = self._manifest(root)
            journal = root / "budget.json"
            receipt = root / "receipt.json"
            repo = Path(__file__).resolve().parents[3]

            def crash(stage, _authorization):
                if stage == "after_provider_return_before_commit":
                    raise RuntimeError("injected post-provider crash")

            with _Server(journal) as provider:
                with self.assertRaisesRegex(
                    RuntimeError, "injected post-provider crash"
                ):
                    execute_launch(
                        manifest_path=manifest,
                        journal_path=journal,
                        receipt_path=receipt,
                        credential_fd=self._credential_fd(),
                        runner_argv=[
                            sys.executable,
                            "-c",
                            self._runner_code(),
                            str(repo),
                            provider.url,
                            str(root / "workbuddy"),
                        ],
                        fault_hook=crash,
                    )
            self.assertEqual(1, provider.requests)
            self.assertFalse(receipt.exists())
            state = validate_checkpoint_payload(journal.read_bytes())
            transaction = next(iter(state["transactions"].values()))
            self.assertEqual("request_authorized", transaction["state"])

    def test_existing_or_linked_receipt_target_fails_before_provider(self):
        for kind in ("regular", "symlink", "hardlink", "temporary"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                os.chmod(root, 0o700)
                manifest = self._manifest(root)
                journal = root / "budget.json"
                receipt = root / "receipt.json"
                source = root / "source"
                source.write_text("occupied\n", encoding="utf-8")
                if kind == "regular":
                    receipt.write_text("occupied\n", encoding="utf-8")
                elif kind == "symlink":
                    receipt.symlink_to(source)
                elif kind == "hardlink":
                    os.link(source, receipt)
                else:
                    receipt.with_name(receipt.name + ".tmp").write_text(
                        "incomplete\n", encoding="utf-8"
                    )
                with _Server(journal) as provider:
                    with self.assertRaisesRegex(
                        LaunchError, "occupied or incomplete"
                    ):
                        execute_launch(
                            manifest_path=manifest,
                            journal_path=journal,
                            receipt_path=receipt,
                            credential_fd=self._credential_fd(),
                            runner_argv=[sys.executable, "-c", "raise SystemExit(0)"],
                        )
                self.assertEqual(0, provider.requests)
                self.assertFalse(journal.exists())

    def test_receipt_cannot_collide_with_journal_internal_paths(self):
        for suffix in ("", ".lock", ".tmp"):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                os.chmod(root, 0o700)
                manifest = self._manifest(root)
                journal = root / "budget.json"
                with _Server(journal) as provider:
                    with self.assertRaisesRegex(LaunchError, "journal internals"):
                        execute_launch(
                            manifest_path=manifest,
                            journal_path=journal,
                            receipt_path=journal.with_name(journal.name + suffix),
                            credential_fd=self._credential_fd(),
                            runner_argv=[sys.executable, "-c", "raise SystemExit(0)"],
                        )
                self.assertEqual(0, provider.requests)
                self.assertFalse(journal.exists())

    def test_untrusted_receipt_parent_fails_before_provider(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            manifest = self._manifest(root)
            journal = root / "budget.json"
            untrusted = root / "untrusted"
            untrusted.mkdir(mode=0o777)
            os.chmod(untrusted, 0o777)
            with _Server(journal) as provider:
                with self.assertRaisesRegex(LaunchError, "private directory"):
                    execute_launch(
                        manifest_path=manifest,
                        journal_path=journal,
                        receipt_path=untrusted / "receipt.json",
                        credential_fd=self._credential_fd(),
                        runner_argv=[sys.executable, "-c", "raise SystemExit(0)"],
                    )
            self.assertEqual(0, provider.requests)
            self.assertFalse(journal.exists())

    def test_receipt_parent_rejects_direct_symlink_but_allows_system_alias(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            manifest = self._manifest(root)
            journal = root / "budget.json"
            real_parent = root / "private"
            real_parent.mkdir(mode=0o700)
            linked_parent = root / "linked"
            linked_parent.symlink_to(real_parent, target_is_directory=True)
            with _Server(journal) as provider:
                with self.assertRaisesRegex(LaunchError, "must not be a symlink"):
                    execute_launch(
                        manifest_path=manifest,
                        journal_path=journal,
                        receipt_path=linked_parent / "receipt.json",
                        credential_fd=self._credential_fd(),
                        runner_argv=[sys.executable, "-c", "raise SystemExit(0)"],
                    )
            self.assertEqual(0, provider.requests)
            self.assertFalse(journal.exists())

            # macOS commonly exposes /var as a system symlink to /private/var.
            # A symlink in an ancestor is acceptable because publication uses
            # the resolved, ownership-checked directory fd rather than the path.
            alias_root = Path("/var")
            resolved_root = root.resolve()
            if alias_root.is_symlink() and str(resolved_root).startswith(
                "/private/var/"
            ):
                alias = Path("/var") / resolved_root.relative_to("/private/var")
                with _Server(journal) as provider:
                    with self.assertRaisesRegex(LaunchError, "runner exited 17"):
                        execute_launch(
                            manifest_path=manifest,
                            journal_path=journal,
                            receipt_path=alias / "alias-receipt.json",
                            credential_fd=self._credential_fd(),
                            runner_argv=[
                                sys.executable,
                                "-c",
                                "raise SystemExit(17)",
                            ],
                        )
                self.assertEqual(0, provider.requests)
                self.assertTrue((root / "alias-receipt.json").is_file())

    def test_failure_receipt_ignores_unrelated_new_result_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            manifest = self._manifest(root)
            journal = root / "budget.json"
            receipt = root / "receipt.json"
            unrelated = (
                root
                / "workbuddy/results/metacodes-code-l2/unrelated/other/requests.jsonl"
            )
            unrelated.parent.mkdir(parents=True)
            unrelated.write_text(
                json.dumps(
                    {
                        "response": {"status": 418},
                        "error": "unrelated-secret-marker",
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            # The injected path uses isolated-test-time attribution. Make the
            # unrelated root provably older than the child start boundary.
            old_ns = time.time_ns() - 10_000_000_000
            os.utime(unrelated.parent.parent, ns=(old_ns, old_ns))
            repo = Path(__file__).resolve().parents[3]
            with _Server(journal, response_status=503) as provider:
                with self.assertRaises(LaunchError):
                    execute_launch(
                        manifest_path=manifest,
                        journal_path=journal,
                        receipt_path=receipt,
                        credential_fd=self._credential_fd(),
                        runner_argv=[
                            sys.executable,
                            "-c",
                            self._failure_runner_code(),
                            str(repo),
                            provider.url,
                            str(root / "workbuddy"),
                        ],
                    )
            failure = validate_authorized_failure_receipt(
                receipt, journal_path=journal
            )
            self.assertEqual(
                {"503": 1},
                failure["failure_evidence"]["request_audit"][
                    "response_status_counts"
                ],
            )
            self.assertNotIn("unrelated-secret-marker", receipt.read_text())

    def test_manifest_drift_fails_before_journal_or_credential(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            manifest = self._manifest(root)
            value = json.loads(manifest.read_text())
            value["execution"]["proxy_max_retries"] = 1
            manifest.write_text(json.dumps(value) + "\n")
            with self.assertRaisesRegex(LaunchError, "content hash mismatch"):
                validate_launch_manifest(manifest)
            self.assertFalse((root / "budget.json").exists())

    def test_manifest_requires_current_two_thousand_dollar_authority(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            manifest = self._manifest(root)
            value = json.loads(manifest.read_text())
            value["budget"]["user_authority_microusd"] = 1_000_000_000
            value["content_sha256"] = hashlib.sha256(
                stable_json({key: row for key, row in value.items() if key != "content_sha256"}).encode(
                    "utf-8"
                )
            ).hexdigest()
            manifest.write_text(json.dumps(value, sort_keys=True) + "\n")
            with self.assertRaisesRegex(LaunchError, "budget authority is inconsistent"):
                validate_launch_manifest(manifest)

    def test_paid_host_rejects_dotenv_and_uv_docker_shadow(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            docker = root / "docker"
            docker.write_text("bound\n", encoding="utf-8")
            docker.chmod(0o755)
            preflight = {"docker": {"path": str(docker)}}
            with mock.patch(
                "scripts.eval.workbuddy.launch_gate.shutil.which",
                return_value=str(docker),
            ):
                _paid_host_guard(root, preflight)
                (root / ".env").write_text("NO_FORCE_BUILD=0\n", encoding="utf-8")
                with self.assertRaisesRegex(LaunchError, "unbound .env"):
                    _paid_host_guard(root, preflight)
                (root / ".env").unlink()
                shadow = root / ".venv/bin/docker"
                shadow.parent.mkdir(parents=True)
                shadow.write_text("shadow\n", encoding="utf-8")
                shadow.chmod(0o755)
                with self.assertRaisesRegex(LaunchError, "shadows"):
                    _paid_host_guard(root, preflight)

    def test_host_control_plane_source_drift_fails_closed(self):
        bound = {
            name: {
                "path": f"/fixture/{name}.py",
                "bytes": 1,
                "sha256": digest(name),
            }
            for name in HOST_CONTROL_PLANE_MODULES
        }
        with mock.patch(
            "scripts.eval.workbuddy.launch_gate._host_control_plane",
            return_value={**bound, "launch_gate": {**bound["launch_gate"], "bytes": 2}},
        ):
            with self.assertRaisesRegex(LaunchError, "host control plane changed"):
                _reobserve_host_control_plane({"host_control_plane": bound})

    def test_real_reobserve_rejects_installed_overlay_tamper_before_authorization(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workbuddy = root / "workbuddy"
            installed = workbuddy / "src/installed.py"
            installed.parent.mkdir(parents=True)
            installed.write_text("trusted\n", encoding="utf-8")
            overlay = {
                "schema_version": "metacodes-workbuddy-overlay-v1",
                "workbuddy_commit": WORKBUDDY_PINNED_COMMIT,
                "overlay_sha256": _digest(
                    [(Path("src/installed.py"), b"trusted\n")], {}
                ),
                "quality_evidence": False,
                "installed_paths": ["src/installed.py"],
            }
            overlay_path = workbuddy / "configs/harnesses/metacodes/OVERLAY.json"
            overlay_path.parent.mkdir(parents=True)
            overlay_path.write_text(
                json.dumps(overlay, sort_keys=True) + "\n", encoding="utf-8"
            )
            installed.write_text("tampered\n", encoding="utf-8")
            manifest = {
                "workbuddy": {
                    "checkout": str(workbuddy),
                    "overlay": {
                        "path": str(overlay_path.resolve()),
                        "bytes": overlay_path.stat().st_size,
                        "sha256": hashlib.sha256(overlay_path.read_bytes()).hexdigest(),
                    },
                    "overlay_content_sha256": overlay["overlay_sha256"],
                }
            }
            with mock.patch(
                "scripts.eval.workbuddy.launch_gate._reobserve_host_control_plane"
            ), mock.patch(
                "scripts.eval.workbuddy.launch_gate._git",
                side_effect=[WORKBUDDY_PINNED_COMMIT, "https://github.com/Tencent/WorkBuddy-Bench"],
            ):
                with self.assertRaisesRegex(
                    LaunchError, "installed overlay files changed"
                ):
                    _reobserve_launch_inputs(manifest)

    def test_official_task_identity_uses_result_not_truncated_trial_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            trial = root / "data_quality-hard-label_conflict__random"
            trajectory = trial / "agent/trajectory.json"
            trajectory.parent.mkdir(parents=True)
            trajectory.write_text("{}\n", encoding="utf-8")
            task = "data_quality-hard-label_conflicts"
            run_id = "workbuddy-authoritative-task-l2"
            route = run_id + "--metacodes-glm52"
            result = {
                "task_name": f"workbuddy/{task}",
                "task_id": {
                    "path": str(
                        Path(".workspace/tmp/staged")
                        / run_id
                        / "wb-bench-code-v1.0/tasks"
                        / task
                    )
                },
                "source": "tasks",
                "trial_uri": trial.as_uri(),
                "task_checksum": digest("task-checksum"),
                "exception_info": None,
                "agent_info": {
                    "name": "metacodes",
                    "model_info": {"name": route},
                },
            }
            (trial / "result.json").write_text(
                json.dumps(result, sort_keys=True) + "\n", encoding="utf-8"
            )
            manifest = {
                "run_id": run_id,
                "cohort": {"dataset": "datasets/wb-bench-code-v1.0/tasks"},
            }
            observed, result_path, loaded = _official_task_identity(
                trajectory, manifest, [task], route
            )
            self.assertEqual(task, observed)
            self.assertEqual(trial / "result.json", result_path)
            self.assertEqual(result, loaded)

            result["task_id"]["path"] = result["task_id"]["path"].replace(
                task, "different-task"
            )
            (trial / "result.json").write_text(
                json.dumps(result, sort_keys=True) + "\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(LaunchError, "identity is incomplete"):
                _official_task_identity(trajectory, manifest, [task], route)

    def test_resolved_prepared_and_trial_project_control_are_bound(self):
        """Bind job YAML through resolver, prepare_job and the trial runtime."""

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            workbuddy = root / "workbuddy"
            run_id = "workbuddy-project-control-l2"
            job_slug = "metacodes-code-l2"
            instance = workbuddy / "scripts/logs/instances" / run_id
            runtime_jobs = workbuddy / ".workspace/data/generated/jobs"
            proxy_logs = workbuddy / "scripts/logs/proxy"
            for path in (instance, runtime_jobs, proxy_logs):
                path.mkdir(parents=True)
            project_sha = hashlib.sha256(
                b"metacodes-project-identity-v1\x00/workspace"
            ).hexdigest()
            rules_relative = "share/metacodes/workbuddy-w05/project-rules"
            kernel_relative = "libexec/metacodes-project-kernel"
            resolved = {
                "selected_tasks": ["code-task-a"],
                "model_connection": "local_proxy",
                "record_full_io": True,
                "harness_resolved_slug": "metacodes/0.1.0",
                "model_slug": "test-model",
                "harness_runtime_config": {
                    "project_control_configured": True,
                    "translated_env": {
                        "METACODES_PROJECT_RULES_SOURCE": (
                            "/opt/metacodes/" + rules_relative
                        ),
                        "METACODES_PROJECT_KERNEL_PATH": (
                            "/opt/metacodes/" + kernel_relative
                        ),
                    },
                },
            }
            (instance / "manifest.json").write_text(
                json.dumps(resolved, sort_keys=True) + "\n", encoding="utf-8"
            )
            (instance / "proxy.yaml").write_text(
                "proxy:\n  backend_retries: 0\n  routes: []\n",
                encoding="utf-8",
            )
            agent_kwargs = {
                "METACODES_PROJECT_RULES_RELATIVE": rules_relative,
                "METACODES_PROJECT_KERNEL_RELATIVE": kernel_relative,
            }
            runtime_job = runtime_jobs / f"{job_slug}.yaml"
            runtime_job.write_text(
                yaml.safe_dump({"agents": [{"kwargs": agent_kwargs}]}),
                encoding="utf-8",
            )
            manifest = {
                "run_id": run_id,
                "workbuddy": {"checkout": str(workbuddy)},
                "cohort": {"selected_tasks": ["code-task-a"]},
                "job": {"slug": job_slug},
                "model": {"slug": "test-model"},
                "artifacts": {
                    "project_control": {
                        "rules": {
                            "project_root": "/workspace",
                            "project_sha256": project_sha,
                            "relative_path": rules_relative,
                        },
                        "kernel": {"relative_path": kernel_relative},
                    }
                },
            }
            contract = _runtime_contract(manifest)
            self.assertTrue(contract["project_control"]["configured"])
            self.assertEqual(
                "5807156ecf67bb70",
                contract["project_control"]["project_state_hash"],
            )
            self.assertEqual(
                hashlib.sha256(runtime_job.read_bytes()).hexdigest(),
                contract["runtime_job_config"]["sha256"],
            )

            trial = root / "trial"
            (trial / "agent").mkdir(parents=True)
            (trial / "config.json").write_text(
                json.dumps({"agent": {"kwargs": agent_kwargs}}) + "\n",
                encoding="utf-8",
            )
            (trial / "agent/metacodes-runtime-contract.json").write_text(
                json.dumps(
                    {
                        "project_control": {
                            "configured": True,
                            "project_state_hash": "5807156ecf67bb70",
                        }
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            _validate_trial_project_control(trial, manifest)

            runtime_job.write_text(
                yaml.safe_dump({"agents": [{"kwargs": {}}]}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(LaunchError, "runtime job project control"):
                _runtime_contract(manifest)


if __name__ == "__main__":
    unittest.main()
