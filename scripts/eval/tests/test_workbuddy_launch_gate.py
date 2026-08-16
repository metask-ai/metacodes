import hashlib
import http.server
import json
import os
import shutil
import subprocess
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
from scripts.eval.workbuddy import launch_gate
from scripts.eval.workbuddy.launch_gate import (
    AUTHORIZED_FAILURE_RECEIPT_SCHEMA_VERSION,
    AUTHORIZED_FAILURE_RECEIPT_SCHEMA_VERSION_V1,
    LaunchError,
    PROVIDER_KEY_ENV,
    PAIRED_SCHEMA_VERSION,
    SCHEMA_VERSION,
    HOST_CONTROL_PLANE_MODULES,
    _artifact_contract,
    _expected_project_control,
    _paid_host_guard,
    _official_task_identity,
    _collect_usage,
    _cacheable_first_request_sha256,
    _aggregate_control_metrics,
    _validate_control_metrics,
    _receipt_quality_evidence,
    _reobserve_host_control_plane,
    _reobserve_launch_inputs,
    _runtime_contract,
    _validate_trial_project_control,
    _validate_launch_manifest,
    build_launch_manifest,
    execute_launch,
    recover_authorized_failure_receipt,
    validate_authorized_failure_receipt,
    validate_launch_manifest,
)
from scripts.eval.workbuddy.trace import (
    LEGACY_CONTROL_METRICS_SCHEMA,
    OBSERVATION_JOURNAL_SCHEMA,
    OBSERVATION_FILENAME,
    PROJECT_RULE_CONTROL_METRICS_SCHEMA,
    load_control_metrics,
)
from scripts.eval.workbuddy import WORKBUDDY_PINNED_COMMIT
from scripts.eval.workbuddy.install_overlay import _digest
from scripts.eval.workbuddy.environment_preflight import prebuild as prebuild_environment
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
    def test_cacheable_first_request_hash_ignores_only_transport_route(self):
        baseline = {
            "model": "baseline-run--metacodes-glm52",
            "system": "You are powered by the model glm-5.2.",
            "messages": [{"role": "user", "content": "task"}],
            "tools": [{"name": "Read", "description": "read"}],
            "stream": True,
        }
        treatment = dict(baseline)
        treatment["model"] = "treatment-run--metacodes-glm52"
        self.assertEqual(
            _cacheable_first_request_sha256(baseline),
            _cacheable_first_request_sha256(treatment),
        )

        drifted = dict(treatment)
        drifted["system"] = "You are powered by a run-specific route."
        self.assertNotEqual(
            _cacheable_first_request_sha256(baseline),
            _cacheable_first_request_sha256(drifted),
        )

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
            "evaluation_treatment": {
                "project_control": "absent",
                "actor_prompt_changed": False,
                "tool_schema_changed": False,
                "provider_cache_prefix_changed_by_control_plane": False,
            },
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
                "backend_model_name": "glm-5.2",
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
        covariates = {"fixture": "workbuddy-paid-launch-l2"}
        manifest["comparison"] = (
            {
                "schema_version": (
                    "metacodes-workbuddy-project-control-comparison-v1"
                ),
                "comparison_id": "workbuddy-l2-comparison",
                "covariates_sha256": hashlib.sha256(
                    stable_json(covariates).encode("utf-8")
                ).hexdigest(),
                "covariates": covariates,
            }
            if quality_evidence_on_commit
            else None
        )
        manifest["content_sha256"] = hashlib.sha256(
            stable_json(manifest).encode("utf-8")
        ).hexdigest()
        path = root / "launch.json"
        path.write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(path, 0o600)
        return path

    def test_manifest_builder_persists_actor_model_identity_for_runtime_audit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            workbuddy = root / "workbuddy"
            job_path = workbuddy / "configs/jobs/identity-l2.yaml"
            model_path = workbuddy / "configs/models/model-l2.yaml"
            split_manifest = (
                workbuddy
                / "configs/harnesses/metacodes/docker/artifacts/share/metacodes/artifact-manifest.json"
            )
            preflight = root / "preflight.json"
            cohort_manifest = root / "cohorts.json"
            for path in (job_path, model_path, split_manifest, preflight, cohort_manifest):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture\n", encoding="utf-8")
            job_path.write_text(
                yaml.safe_dump(
                    {
                        "model": "model-l2",
                        "harness": "metacodes/0.1.0",
                        "dataset": "datasets/wb-bench-code-v1.0/tasks",
                        "model_connection": "local_proxy",
                        "record_full_io": True,
                        "n_attempts": 1,
                        "harness_params_override": {
                            "METACODES_VERIFICATION_CHECKPOINT": False
                        },
                        "task_selection": {"mode": "name", "names": ["task-a"]},
                        "orchestrator_override": {"n_concurrent_trials": 1},
                    }
                ),
                encoding="utf-8",
            )
            model_path.write_text(
                yaml.safe_dump(
                    {
                        "model": {
                            "name": "glm-5.2",
                            "backend_url_env": "TEST_WORKBUDDY_BASE_URL",
                            "backend_key_env": PROVIDER_KEY_ENV,
                        }
                    }
                ),
                encoding="utf-8",
            )
            cohort = {
                "subset": "code",
                "cohort": "dev",
                "dataset": "datasets/wb-bench-code-v1.0/tasks",
                "take": 1,
                "selected_tasks": ["task-a"],
                "selected_tasks_sha256": digest("task-a"),
                "manifest": {"path": str(cohort_manifest), "bytes": 8, "sha256": digest("cohort")},
                "content_sha256": digest("cohort-content"),
            }
            artifact = {
                "manifest": {"path": str(split_manifest), "bytes": 8, "sha256": digest("artifact")},
                "executables": {},
                "target_platform": "linux/amd64",
            }
            preflight_row = {
                "content_sha256": digest("preflight-content"),
                "target_platform": "linux/amd64",
            }
            file_identity = lambda path: {
                "path": str(Path(path).resolve()),
                "bytes": Path(path).stat().st_size,
                "sha256": hashlib.sha256(Path(path).read_bytes()).hexdigest(),
            }
            runner_tools = {
                "bash": {"path": "/fixture/bash", "bytes": 1, "sha256": digest("bash"), "version_first_line": "bash", "version_sha256": digest("bash-version")},
                "uv": {"path": "/fixture/uv", "bytes": 1, "sha256": digest("uv"), "version_first_line": "uv", "version_sha256": digest("uv-version")},
            }
            host = {
                name: {"path": f"/fixture/{name}.py", "bytes": 1, "sha256": digest(name)}
                for name in HOST_CONTROL_PLANE_MODULES
            }
            overlay = {
                "overlay_sha256": digest("overlay-content"),
                "quality_evidence": False,
            }
            overlay_path = workbuddy / "configs/harnesses/metacodes/OVERLAY.json"
            overlay_path.parent.mkdir(parents=True, exist_ok=True)
            overlay_path.write_text("{}\n", encoding="utf-8")
            with mock.patch.dict(
                os.environ,
                {"TEST_WORKBUDDY_BASE_URL": "https://provider.invalid/v1/messages"},
            ), mock.patch(
                "scripts.eval.workbuddy.launch_gate._git",
                side_effect=[WORKBUDDY_PINNED_COMMIT, "https://github.com/Tencent/workbuddy-bench"],
            ), mock.patch(
                "scripts.eval.workbuddy.launch_gate.validate_installed_overlay",
                return_value=overlay,
            ), mock.patch(
                "scripts.eval.workbuddy.launch_gate._cohort", return_value=cohort
            ), mock.patch(
                "scripts.eval.workbuddy.launch_gate._artifact_contract",
                return_value=artifact,
            ), mock.patch(
                "scripts.eval.workbuddy.launch_gate.validate_environment_preflight",
                return_value=preflight_row,
            ), mock.patch(
                "scripts.eval.workbuddy.launch_gate._runner_tool",
                side_effect=[runner_tools["bash"], runner_tools["uv"]],
            ), mock.patch(
                "scripts.eval.workbuddy.launch_gate._host_control_plane", return_value=host
            ), mock.patch(
                "scripts.eval.workbuddy.launch_gate._identity",
                side_effect=file_identity,
            ):
                manifest = build_launch_manifest(
                    run_id="workbuddy-actor-identity-l2",
                    workbuddy_checkout=workbuddy,
                    cohort_manifest=cohort_manifest,
                    subset="code",
                    cohort="dev",
                    take=1,
                    split_mount_manifest=split_manifest,
                    environment_preflight_receipt=preflight,
                    job_config=job_path,
                    model_config=model_path,
                    runner_bash=Path("/fixture/bash"),
                    runner_uv=Path("/fixture/uv"),
                    provider_identity="provider-l2",
                    total_cost_microusd=1_000_000,
                    total_metered_tokens=100_000,
                    max_cost_microusd=500_000,
                    max_metered_tokens=50_000,
                )
            self.assertEqual("glm-5.2", manifest["model"]["backend_model_name"])
            self.assertEqual(
                "glm-5.2",
                _validate_launch_manifest(dict(manifest))["model"]["backend_model_name"],
            )

            missing = dict(manifest)
            missing["model"] = dict(manifest["model"])
            missing["model"].pop("backend_model_name")
            missing["content_sha256"] = hashlib.sha256(
                stable_json({key: value for key, value in missing.items() if key != "content_sha256"}).encode("utf-8")
            ).hexdigest()
            with self.assertRaisesRegex(LaunchError, "actor model identity is incomplete"):
                _validate_launch_manifest(missing)

            previous = dict(missing)
            previous["schema_version"] = PAIRED_SCHEMA_VERSION
            previous["content_sha256"] = hashlib.sha256(
                stable_json(
                    {
                        key: value
                        for key, value in previous.items()
                        if key != "content_sha256"
                    }
                ).encode("utf-8")
            ).hexdigest()
            self.assertNotIn(
                "backend_model_name",
                _validate_launch_manifest(previous)["model"],
            )

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
    "extra": {"cache_creation_input_tokens": 10, "control_metrics": control_metrics,
              "metacodes_turns": 1}
  }
}
(agent / "trajectory.json").write_text(json.dumps(trajectory) + "\n")
record = {"seq": 1, "request": {"body": {"model": "volatile-route", "system": "stable", "messages": [{"role": "user", "content": "task"}]}}, "response": {"status": 200}, "error": None}
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

    def test_historical_control_metrics_preserve_versioned_compatibility(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "metacodes-transcript.jsonl"
            observation = root / OBSERVATION_FILENAME
            trajectory = root / "trajectory.json"
            transcript.write_text(
                json.dumps({"role": "user", "blocks": []}) + "\n",
                encoding="utf-8",
            )
            rows = [
                {"schema_version": OBSERVATION_JOURNAL_SCHEMA, "sequence": 0,
                 "session_id": "legacy-session", "run_id": "legacy-run",
                 "monotonic_elapsed_ns": 0, "event": {"run_started": {}}},
                {"schema_version": OBSERVATION_JOURNAL_SCHEMA, "sequence": 1,
                 "session_id": "legacy-session", "run_id": "legacy-run",
                 "monotonic_elapsed_ns": 1, "event": {"run_finished": {}}},
            ]
            observation.write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )
            trajectory.write_text("{}\n", encoding="utf-8")
            current = load_control_metrics(transcript, observation)
            project_rule = json.loads(json.dumps(current))
            project_rule["schema_version"] = PROJECT_RULE_CONTROL_METRICS_SCHEMA
            for name in ("auto_context_succeeded", "context_observations"):
                project_rule["tinykg"].pop(name)
            self.assertEqual(
                _validate_control_metrics(
                    project_rule,
                    trajectory_path=trajectory,
                    transcript_path=transcript,
                    observation_path=observation,
                ),
                current,
            )

            legacy = json.loads(json.dumps(current))
            legacy["schema_version"] = LEGACY_CONTROL_METRICS_SCHEMA
            for name in ("auto_context_succeeded", "context_observations"):
                legacy["tinykg"].pop(name)
            for name in (
                "rule_filter_events",
                "active_rule_phases",
                "checker_rule_phases",
                "statically_pruned_rule_phases",
            ):
                legacy["lean"].pop(name)
            normalized = _validate_control_metrics(
                legacy,
                trajectory_path=trajectory,
                transcript_path=transcript,
                observation_path=observation,
            )
            self.assertEqual(normalized, current)

            filtered = json.loads(json.dumps(current))
            filtered["lean"]["rule_filter_events"] = 1
            filtered["lean"]["active_rule_phases"] = 1
            with mock.patch(
                "scripts.eval.workbuddy.launch_gate.load_control_metrics",
                return_value=filtered,
            ):
                with self.assertRaisesRegex(LaunchError, "cannot represent"):
                    _validate_control_metrics(
                        legacy,
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

    def test_dataset_staging_drift_on_real_launch_path_precedes_budget_and_runner(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            manifest_path = self._manifest(root)
            workbuddy = root / "workbuddy"
            harness = workbuddy / "configs/harnesses/metacodes/docker"
            harness.mkdir(parents=True)
            (harness / "Dockerfile").write_text(
                "FROM scratch\n", encoding="utf-8"
            )
            for task in ("code-task-a", "code-task-b"):
                environment = (
                    workbuddy
                    / f"datasets/wb-bench-code-v1.0/tasks/{task}/environment"
                )
                environment.mkdir(parents=True)
                (environment / "Dockerfile").write_text(
                    "FROM scratch\n", encoding="utf-8"
                )
                (environment.parent / "task.toml").write_text(
                    f"[task]\nname = '{task}'\n", encoding="utf-8"
                )
            dataset_root = workbuddy / "datasets/wb-bench-code-v1.0"
            (dataset_root / "dataset.toml").write_text(
                '[verifier]\nschema = "workbuddy.verifier.v1"\nengine = "composite"\n',
                encoding="utf-8",
            )
            shared = dataset_root / "shared/verifier"
            shared.mkdir(parents=True)
            (shared / "plugin.py").write_text("VALUE = 1\n", encoding="utf-8")
            docker = root / "docker"
            docker.write_text("fixture\n", encoding="utf-8")
            docker.chmod(0o755)
            preflight_path = root / "environment-preflight.json"

            def fake_environment_run(argv, **_kwargs):
                args = [str(item) for item in argv]
                if args[0] == "git":
                    return subprocess.CompletedProcess(
                        args, 0, WORKBUDDY_PINNED_COMMIT + "\n", ""
                    )
                if "buildx" in args and "build" in args:
                    return subprocess.CompletedProcess(args, 0, "built\n", "")
                if args[1:3] == ["image", "inspect"]:
                    row = {
                        "Id": "sha256:" + "a" * 64,
                        "Architecture": "amd64",
                        "Os": "linux",
                    }
                    return subprocess.CompletedProcess(
                        args, 0, json.dumps(row), ""
                    )
                if args[1:3] == ["version", "--format"]:
                    return subprocess.CompletedProcess(
                        args, 0, '{"Version":"test"}\n', ""
                    )
                raise AssertionError(f"unexpected environment command: {args}")

            with mock.patch(
                "scripts.eval.workbuddy.environment_preflight._run",
                side_effect=fake_environment_run,
            ):
                preflight = prebuild_environment(
                    workbuddy=workbuddy,
                    dataset="datasets/wb-bench-code-v1.0/tasks",
                    selected_tasks=["code-task-a"],
                    output=preflight_path,
                    docker=docker,
                )

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["cohort"]["manifest"] = {
                "path": "/fixture/cohort.json",
                "bytes": 1,
                "sha256": digest("cohort"),
            }
            manifest["artifacts"]["executables"] = {}
            manifest["environment_preflight"] = {
                "receipt": {
                    "path": str(preflight_path),
                    "bytes": len(preflight_path.read_bytes()),
                    "sha256": hashlib.sha256(preflight_path.read_bytes()).hexdigest(),
                },
                "content_sha256": preflight["content_sha256"],
                "target_platform": "linux/amd64",
            }
            manifest["model"]["backend_url_env"] = "WORKBUDDY_L2_UNUSED_URL"
            manifest["model"]["backend_url_sha256"] = hashlib.sha256(b"").hexdigest()
            manifest.pop("content_sha256")
            manifest["content_sha256"] = hashlib.sha256(
                stable_json(manifest).encode("utf-8")
            ).hexdigest()
            manifest_path.write_text(
                json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8"
            )
            os.chmod(manifest_path, 0o600)

            # WorkBuddy stages and prepares the complete dataset before task
            # selection. Drift an unselected task after receipt publication.
            (workbuddy / "datasets/wb-bench-code-v1.0/tasks/code-task-b/task.toml").write_text(
                "[task]\nname = 'drifted'\n", encoding="utf-8"
            )
            journal = root / "budget.json"
            receipt = root / "receipt.json"
            credential_fd = self._credential_fd()
            try:
                with mock.patch(
                    "scripts.eval.workbuddy.launch_gate._reobserve_host_control_plane"
                ), mock.patch(
                    "scripts.eval.workbuddy.launch_gate._git",
                    return_value=WORKBUDDY_PINNED_COMMIT,
                ), mock.patch(
                    "scripts.eval.workbuddy.launch_gate._reobserve_identity"
                ), mock.patch(
                    "scripts.eval.workbuddy.launch_gate.validate_installed_overlay",
                    return_value={
                        "overlay_sha256": manifest["workbuddy"][
                            "overlay_content_sha256"
                        ]
                    },
                ), mock.patch(
                    "scripts.eval.workbuddy.launch_gate._paid_host_guard"
                ), mock.patch(
                    "scripts.eval.workbuddy.launch_gate._runner_tool",
                    side_effect=lambda path, *_args, **_kwargs: manifest["execution"][
                        "runner_tools"
                    ][Path(path).name],
                ), mock.patch(
                    "scripts.eval.workbuddy.environment_preflight._run",
                    side_effect=fake_environment_run,
                ), mock.patch(
                    "scripts.eval.workbuddy.launch_gate.subprocess.run"
                ) as runner:
                    with self.assertRaisesRegex(
                        LaunchError, "dataset staging contract changed"
                    ):
                        execute_launch(
                            manifest_path=manifest_path,
                            journal_path=journal,
                            receipt_path=receipt,
                            credential_fd=credential_fd,
                        )
                runner.assert_not_called()
                self.assertFalse(journal.exists())
                self.assertFalse(receipt.exists())
            finally:
                os.close(credential_fd)

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

    def _official_usage_fixture(self, root: Path, reward: object) -> dict:
        workbuddy = root / "workbuddy"
        run_id = "workbuddy-official-reward-l2"
        job_slug = "metacodes-official-reward-l2"
        model_slug = "test-model"
        model_route = run_id + "--" + model_slug
        task = "code-task-a"
        trial = workbuddy / "results" / job_slug / "run" / (task + "__1")
        agent = trial / "agent"
        agent.mkdir(parents=True)
        transcript = agent / "metacodes-transcript.jsonl"
        observation = agent / OBSERVATION_FILENAME
        transcript.write_text(
            json.dumps({"role": "user", "blocks": [{"type": "text", "text": "task"}]})
            + "\n",
            encoding="utf-8",
        )
        observation.write_text(
            json.dumps(
                {
                    "schema_version": OBSERVATION_JOURNAL_SCHEMA,
                    "sequence": 0,
                    "session_id": "session-official-reward-l2",
                    "run_id": "run-official-reward-l2",
                    "monotonic_elapsed_ns": 0,
                    "event": {"run_started": {}},
                }
            )
            + "\n"
            + json.dumps(
                {
                    "schema_version": OBSERVATION_JOURNAL_SCHEMA,
                    "sequence": 1,
                    "session_id": "session-official-reward-l2",
                    "run_id": "run-official-reward-l2",
                    "monotonic_elapsed_ns": 1,
                    "event": {"run_finished": {}},
                }
            )
            + "\n",
            encoding="utf-8",
        )
        control = load_control_metrics(transcript, observation)
        (agent / "trajectory.json").write_text(
            json.dumps(
                {
                    "final_metrics": {
                        "total_prompt_tokens": 10,
                        "total_completion_tokens": 2,
                        "total_cached_tokens": 3,
                        "total_cost_usd": 0.001,
                        "extra": {
                            "cache_creation_input_tokens": 4,
                            "control_metrics": control,
                        },
                    }
                }
            )
            + "\n",
            encoding="utf-8",
        )
        (agent / "requests.jsonl").write_text(
            json.dumps(
                {
                    "request": {
                        "body": {
                            "model": model_route,
                            "system": "stable",
                            "messages": [{"role": "user", "content": "task"}],
                        }
                    }
                }
            )
            + "\n",
            encoding="utf-8",
        )
        (trial / "config.json").write_text(
            json.dumps(
                {
                    "agent": {
                        "kwargs": {"METACODES_MODEL_DISPLAY_NAME": "glm-5.2"}
                    }
                }
            )
            + "\n",
            encoding="utf-8",
        )
        (agent / "metacodes-runtime-contract.json").write_text(
            json.dumps(
                {
                    "project_control": {
                        "staged": False,
                        "mode": "absent",
                        "configured": False,
                        "project_state_hash": None,
                        "artifacts_verified": False,
                        "runtime_active_bundle_absent": True,
                    },
                    "transport_model_is_route": True,
                    "actor_model_identity": "glm-5.2",
                }
            )
            + "\n",
            encoding="utf-8",
        )
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
            "trial_uri": trial.resolve().as_uri(),
            "task_checksum": digest("official-task-checksum"),
            "exception_info": None,
            "agent_info": {
                "name": "metacodes",
                "model_info": {"name": model_route},
            },
            "verifier_result": {"rewards": {"reward": reward}},
        }
        (trial / "result.json").write_text(
            json.dumps(result, sort_keys=True) + "\n", encoding="utf-8"
        )

        instance = workbuddy / "scripts/logs/instances" / run_id
        runtime_jobs = workbuddy / ".workspace/data/generated/jobs"
        proxy_logs = workbuddy / "scripts/logs/proxy"
        for path in (instance, runtime_jobs, proxy_logs):
            path.mkdir(parents=True, exist_ok=True)
        (instance / "manifest.json").write_text(
            json.dumps(
                {
                    "selected_tasks": [task],
                    "model_connection": "local_proxy",
                    "record_full_io": True,
                    "harness_resolved_slug": "metacodes/0.1.0",
                    "model_slug": model_slug,
                    "model_route": model_route,
                    "backend_model_name": "glm-5.2",
                    "harness_runtime_config": {
                        "project_control_staged": False,
                        "project_control_mode": "absent",
                        "project_control_configured": False,
                        "transport_model_is_route": True,
                        "actor_model_identity": "glm-5.2",
                        "translated_env": {},
                    },
                },
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        (instance / "proxy.yaml").write_text(
            "proxy:\n  backend_retries: 0\n  routes: []\n", encoding="utf-8"
        )
        (runtime_jobs / f"{job_slug}.yaml").write_text(
            yaml.safe_dump(
                {
                    "agents": [
                        {
                            "kwargs": {
                                "METACODES_MODEL_DISPLAY_NAME": "glm-5.2"
                            }
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        return {
            "run_id": run_id,
            "workbuddy": {"checkout": str(workbuddy)},
            "cohort": {
                "dataset": "datasets/wb-bench-code-v1.0/tasks",
                "selected_tasks": [task],
            },
            "job": {"slug": job_slug},
            "model": {
                "slug": model_slug,
                "backend_model_name": "glm-5.2",
            },
            "artifacts": {},
        }

    def test_official_collect_usage_reads_authoritative_reward_and_rejects_bad_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = self._official_usage_fixture(root, 0.75)
            usage = _collect_usage(manifest, started_ns=0, official_runner=True)
            self.assertEqual(0.75, usage["tasks"]["code-task-a"]["verifier_reward"])
            self.assertEqual(0.75, usage["quality"]["mean_verifier_reward"])
            self.assertFalse(usage["tasks"]["code-task-a"]["full_pass"])

        for reward in (None, True, float("nan"), -0.1, 1.1):
            with self.subTest(reward=reward), tempfile.TemporaryDirectory() as directory:
                manifest = self._official_usage_fixture(Path(directory), reward)
                with self.assertRaisesRegex(LaunchError, "invalid verifier reward"):
                    _collect_usage(manifest, started_ns=0, official_runner=True)

    def test_v3_usage_rejects_missing_or_out_of_order_provider_request_audit(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self._official_usage_fixture(Path(directory), 1.0)
            manifest["schema_version"] = SCHEMA_VERSION
            workbuddy = Path(manifest["workbuddy"]["checkout"])
            request_log = next(
                workbuddy.rglob("agent/requests.jsonl")
            )
            trajectory_path = request_log.with_name("trajectory.json")
            trajectory = json.loads(trajectory_path.read_text(encoding="utf-8"))
            trajectory["final_metrics"]["extra"]["metacodes_turns"] = 2
            trajectory_path.write_text(
                json.dumps(trajectory) + "\n", encoding="utf-8"
            )
            row = json.loads(request_log.read_text(encoding="utf-8"))
            row.update({"seq": 2, "response": {"status": 200}, "error": None})
            request_log.write_text(json.dumps(row) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(
                LaunchError, "provider request audit is incomplete or out of order"
            ):
                _collect_usage(manifest, started_ns=0, official_runner=True)
            trajectory["final_metrics"]["extra"]["metacodes_turns"] = 1
            trajectory_path.write_text(
                json.dumps(trajectory) + "\n", encoding="utf-8"
            )
            row.update({"seq": 1, "response": {"status": 499}})
            request_log.write_text(json.dumps(row) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(
                LaunchError, "provider request audit is incomplete or out of order"
            ):
                _collect_usage(manifest, started_ns=0, official_runner=True)

    def test_v3_usage_accepts_wave_global_sequences_across_tasks(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self._official_usage_fixture(Path(directory), 1.0)
            manifest["schema_version"] = SCHEMA_VERSION
            workbuddy = Path(manifest["workbuddy"]["checkout"])
            first_agent = next(workbuddy.rglob("agent/trajectory.json")).parent
            first_trajectory = json.loads(
                (first_agent / "trajectory.json").read_text(encoding="utf-8")
            )
            first_trajectory["final_metrics"]["extra"]["metacodes_turns"] = 1
            (first_agent / "trajectory.json").write_text(
                json.dumps(first_trajectory) + "\n", encoding="utf-8"
            )
            first_request = json.loads(
                (first_agent / "requests.jsonl").read_text(encoding="utf-8")
            )
            first_request.update(
                {"seq": 1, "response": {"status": 200}, "error": None}
            )
            (first_agent / "requests.jsonl").write_text(
                json.dumps(first_request) + "\n", encoding="utf-8"
            )

            first_trial = first_agent.parent
            second_task = "code-task-b"
            second_trial = first_trial.parent / (second_task + "__2")
            shutil.copytree(first_trial, second_trial)
            second_agent = second_trial / "agent"
            second_request = dict(first_request)
            second_request["seq"] = 2
            (second_agent / "requests.jsonl").write_text(
                json.dumps(second_request) + "\n", encoding="utf-8"
            )
            result_path = second_trial / "result.json"
            result = json.loads(result_path.read_text(encoding="utf-8"))
            result["task_name"] = f"workbuddy/{second_task}"
            result["task_id"]["path"] = result["task_id"]["path"].replace(
                "code-task-a", second_task
            )
            result["trial_uri"] = second_trial.resolve().as_uri()
            result_path.write_text(
                json.dumps(result, sort_keys=True) + "\n", encoding="utf-8"
            )
            manifest["cohort"]["selected_tasks"].append(second_task)
            run_manifest = (
                workbuddy
                / "scripts/logs/instances"
                / manifest["run_id"]
                / "manifest.json"
            )
            resolved = json.loads(run_manifest.read_text(encoding="utf-8"))
            resolved["selected_tasks"].append(second_task)
            run_manifest.write_text(
                json.dumps(resolved, sort_keys=True) + "\n", encoding="utf-8"
            )

            usage = _collect_usage(manifest, started_ns=0, official_runner=True)
            self.assertEqual(2, usage["provider_requests"])
            self.assertEqual({"code-task-a", second_task}, set(usage["tasks"]))
            second_request["seq"] = 3
            (second_agent / "requests.jsonl").write_text(
                json.dumps(second_request) + "\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(
                LaunchError, "provider request audit has a missing or duplicate wave sequence"
            ):
                _collect_usage(manifest, started_ns=0, official_runner=True)

    def test_v3_usage_hashes_complete_request_audit_above_default_identity_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self._official_usage_fixture(Path(directory), 1.0)
            manifest["schema_version"] = SCHEMA_VERSION
            request_log = next(
                Path(manifest["workbuddy"]["checkout"]).rglob(
                    "agent/requests.jsonl"
                )
            )
            trajectory_path = request_log.with_name("trajectory.json")
            trajectory = json.loads(trajectory_path.read_text(encoding="utf-8"))
            trajectory["final_metrics"]["extra"]["metacodes_turns"] = 1
            trajectory_path.write_text(
                json.dumps(trajectory) + "\n", encoding="utf-8"
            )
            row = json.loads(request_log.read_text(encoding="utf-8"))
            row.update({"seq": 1, "response": {"status": 200}, "error": None})
            # Keep one valid JSONL record while making it larger than _identity's
            # generic 16 MiB default and smaller than the request-audit 64 MiB cap.
            row["request"]["body"]["padding"] = "x" * (17 * 1024 * 1024)
            request_log.write_text(json.dumps(row) + "\n", encoding="utf-8")

            usage = _collect_usage(manifest, started_ns=0, official_runner=True)
            task = next(iter(usage["tasks"].values()))
            self.assertEqual(
                hashlib.sha256(request_log.read_bytes()).hexdigest(),
                task["requests_sha256"],
            )

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
                    "project_control_staged": True,
                    "project_control_mode": "enforced",
                    "project_control_configured": True,
                    "transport_model_is_route": True,
                    "actor_model_identity": "glm-5.2",
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
                "METACODES_PROJECT_CONTROL_MODE": "enforced",
                "METACODES_PROJECT_RULES_RELATIVE": rules_relative,
                "METACODES_PROJECT_KERNEL_RELATIVE": kernel_relative,
                "METACODES_MODEL_DISPLAY_NAME": "glm-5.2",
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
                "model": {
                    "slug": "test-model",
                    "backend_model_name": "glm-5.2",
                },
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
                            "staged": True,
                            "mode": "enforced",
                            "configured": True,
                            "project_state_hash": "5807156ecf67bb70",
                            "artifacts_verified": True,
                            "runtime_active_bundle_absent": False,
                        },
                        "transport_model_is_route": True,
                        "actor_model_identity": "glm-5.2",
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

    def test_disabled_project_control_is_staged_but_has_no_runtime_active_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            project_sha = hashlib.sha256(
                b"metacodes-project-identity-v1\x00/workspace"
            ).hexdigest()
            rules_relative = "share/metacodes/workbuddy-w05/project-rules"
            kernel_relative = "libexec/metacodes-project-kernel"
            manifest = {
                "model": {"backend_model_name": "glm-5.2"},
                "evaluation_treatment": {"project_control": "disabled"},
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
            expected = {
                "staged": True,
                "mode": "disabled",
                "configured": False,
                "project_root": "/workspace",
                "project_sha256": project_sha,
                "project_state_hash": None,
                "rules_relative_path": rules_relative,
                "kernel_relative_path": kernel_relative,
                "artifacts_verified": True,
                "runtime_active_bundle_absent": True,
            }
            self.assertEqual(expected, _expected_project_control(manifest))
            trial = root / "trial"
            (trial / "agent").mkdir(parents=True)
            kwargs = {
                "METACODES_PROJECT_CONTROL_MODE": "disabled",
                "METACODES_PROJECT_RULES_RELATIVE": rules_relative,
                "METACODES_PROJECT_KERNEL_RELATIVE": kernel_relative,
                "METACODES_MODEL_DISPLAY_NAME": "glm-5.2",
            }
            (trial / "config.json").write_text(
                json.dumps({"agent": {"kwargs": kwargs}}) + "\n", encoding="utf-8"
            )
            (trial / "agent/metacodes-runtime-contract.json").write_text(
                json.dumps(
                    {
                        "project_control": {
                            "staged": True,
                            "mode": "disabled",
                            "configured": False,
                            "project_state_hash": None,
                            "artifacts_verified": True,
                            "runtime_active_bundle_absent": True,
                        },
                        "transport_model_is_route": True,
                        "actor_model_identity": "glm-5.2",
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            _validate_trial_project_control(trial, manifest)
            forged = json.loads(
                (trial / "agent/metacodes-runtime-contract.json").read_text()
            )
            forged["project_control"]["runtime_active_bundle_absent"] = False
            (trial / "agent/metacodes-runtime-contract.json").write_text(
                json.dumps(forged) + "\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(LaunchError, "runtime project control drifted"):
                _validate_trial_project_control(trial, manifest)


if __name__ == "__main__":
    unittest.main()


class RunnerToolLocaleTest(unittest.TestCase):
    """A localized version banner must not reject a valid GNU Bash runner."""

    def _fake_bash(self, directory: Path) -> Path:
        # Prints the zh_CN banner unless the caller forces a C locale, which
        # is exactly how a real bash behaves on a Chinese-locale host.
        path = directory / "bash"
        path.write_text(
            "#!/bin/sh\n"
            'if [ "${LC_ALL:-}" = "C" ] || [ "${LANG:-}" = "C" ]; then\n'
            '  echo "GNU bash, version 5.3.15(1)-release (aarch64-apple-darwin25.4.0)"\n'
            "else\n"
            '  echo "GNU bash，版本 5.3.15(1)-release (aarch64-apple-darwin25.4.0)"\n'
            "fi\n",
            encoding="utf-8",
        )
        path.chmod(0o755)
        return path

    def test_localized_bash_banner_is_still_identified(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wb-locale-") as temporary:
            directory = Path(temporary)
            probed = launch_gate._runner_tool(
                self._fake_bash(directory), ("--version",), bash=True
            )
        # The recorded banner is the C-locale spelling, so the launch
        # manifest identity is host-locale independent too.
        self.assertIn("GNU bash, version 5.3.15", str(probed["version_first_line"]))

    def test_bash_3_is_still_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wb-locale-old-") as temporary:
            directory = Path(temporary)
            path = directory / "bash"
            path.write_text(
                "#!/bin/sh\necho 'GNU bash, version 3.2.57(1)-release'\n",
                encoding="utf-8",
            )
            path.chmod(0o755)
            with self.assertRaisesRegex(launch_gate.LaunchError, "GNU Bash 4 or newer"):
                launch_gate._runner_tool(path, ("--version",), bash=True)


class WorkBuddyEvidenceFreezerTest(unittest.TestCase):
    """The freezer is part of the auditor: what it cannot freeze it must name.

    The one real firing of the old silent-skip path dropped the exact 88MB
    request log whose size had just killed the post-run audit, leaving a
    nameless unsafe_entries counter as the only trace."""

    def _manifest(self, checkout: Path) -> dict:
        return {"workbuddy": {"checkout": str(checkout)}, "job": {"slug": "job-x"}}

    def test_freezer_names_skipped_oversized_artifact(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wb-freeze-") as temporary:
            checkout = Path(temporary)
            trial = checkout / "results" / "job-x" / "run" / "task__abc" / "agent"
            trial.mkdir(parents=True)
            (trial / "trial.log").write_text("ok\n", encoding="utf-8")
            (trial / "requests.jsonl").write_text("x" * 4096, encoding="utf-8")
            with mock.patch.object(launch_gate, "MAX_FAILURE_ARTIFACT_BYTES", 1024):
                evidence = launch_gate._authorized_failure_artifacts(
                    self._manifest(checkout), started_ns=0, official_runner=False
                )
        frozen = {row["relative_path"] for row in evidence["artifacts"]}
        self.assertIn("results/job-x/run/task__abc/agent/trial.log", frozen)
        skipped = evidence["skipped_artifacts"]
        self.assertEqual(len(skipped), 1)
        self.assertEqual(
            skipped[0]["relative_path"],
            "results/job-x/run/task__abc/agent/requests.jsonl",
        )
        self.assertEqual(skipped[0]["reason"], "exceeds per-artifact freeze bound")
        self.assertEqual(skipped[0]["bytes"], 4096)
        self.assertEqual(evidence["unsafe_entries"], 1)

    def test_audit_read_bound_dominates_producer_and_freezer(self) -> None:
        # The audit's request-log read bound must dominate what a trial can
        # actually produce under the standard arm authorization (40M metered
        # tokens x ~4 bytes/token x ~2x JSON escaping), and the freezer must
        # be able to freeze anything the audit reads — otherwise the file
        # that kills the audit is the file missing from the evidence.
        standard_arm_metered_tokens = 40_000_000
        producer_worst_case = standard_arm_metered_tokens * 4 * 2
        self.assertGreaterEqual(
            launch_gate.MAX_REQUEST_LOG_BYTES, producer_worst_case
        )
        self.assertGreaterEqual(
            launch_gate.MAX_FAILURE_ARTIFACT_BYTES,
            launch_gate.MAX_REQUEST_LOG_BYTES,
        )
        self.assertGreaterEqual(
            launch_gate.MAX_FAILURE_ARTIFACT_TOTAL_BYTES,
            4 * launch_gate.MAX_FAILURE_ARTIFACT_BYTES,
        )


class WorkBuddyResumeAuditTest(WorkBuddyPaidLaunchGateL2Test):
    """Faithful reenactment of the 88MB incident and its governed recovery.

    A fully valid paid run fails only its post-run audit because the audit's
    read bound is smaller than a legitimate artifact.  The money is spent and
    the runner exited 0; after the instrument is fixed, resume-audit must
    verify the failure receipt's evidence freeze byte-for-byte, re-run the
    audit offline (no credential, no runner), and commit actual usage.
    """

    def test_resume_audit_commits_after_instrument_fix(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            manifest = self._manifest(root)
            journal = root / "budget.json"
            failure_receipt = root / "audit-failure.json"
            committed_receipt = root / "receipt.json"
            repo = Path(__file__).resolve().parents[3]
            started_ns = time.time_ns()
            with _Server(journal) as provider:
                with mock.patch.object(launch_gate, "MAX_REQUEST_LOG_BYTES", 8):
                    with self.assertRaisesRegex(
                        LaunchError,
                        "post-run evidence audit failed after runner exit 0",
                    ):
                        execute_launch(
                            manifest_path=manifest,
                            journal_path=journal,
                            receipt_path=failure_receipt,
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
            failure = validate_authorized_failure_receipt(
                failure_receipt, journal_path=journal
            )
            self.assertEqual(failure["failure_stage"], "post_run_evidence_audit")
            self.assertEqual(failure["runner"]["returncode"], 0)
            self.assertFalse(failure["retry_allowed"])

            result = launch_gate.resume_post_run_audit(
                manifest_path=manifest,
                journal_path=journal,
                failure_receipt_path=failure_receipt,
                receipt_path=committed_receipt,
                started_ns=started_ns,
            )
            self.assertEqual(result["budget_transaction"]["state"], "committed")
            self.assertEqual(result["usage"]["cost_microusd"], 10_000)
            self.assertEqual(result["usage"]["metered_tokens"], 240)
            disclosure = result["resume_audit"]
            self.assertGreater(disclosure["evidence_verified"], 0)
            self.assertEqual(
                disclosure["original_failure_stage"], "post_run_evidence_audit"
            )
            self.assertIn("launch_gate", disclosure["auditor"])
            self.assertTrue(committed_receipt.is_file())
            self.assertEqual(committed_receipt.stat().st_mode & 0o777, 0o600)

    def test_resume_audit_rejects_drifted_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            manifest = self._manifest(root)
            journal = root / "budget.json"
            failure_receipt = root / "audit-failure.json"
            repo = Path(__file__).resolve().parents[3]
            started_ns = time.time_ns()
            with _Server(journal) as provider:
                with mock.patch.object(launch_gate, "MAX_REQUEST_LOG_BYTES", 8):
                    with self.assertRaisesRegex(LaunchError, "post-run evidence audit"):
                        execute_launch(
                            manifest_path=manifest,
                            journal_path=journal,
                            receipt_path=failure_receipt,
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
            failure = validate_authorized_failure_receipt(
                failure_receipt, journal_path=journal
            )
            # Tamper with one frozen artifact: resumption must fail closed.
            frozen = failure["failure_evidence"]["artifacts"]
            target = root / "workbuddy" / frozen[0]["relative_path"]
            target.write_bytes(target.read_bytes() + b"\n# tampered\n")
            with self.assertRaisesRegex(
                LaunchError, "evidence drifted since the failure freeze"
            ):
                launch_gate.resume_post_run_audit(
                    manifest_path=manifest,
                    journal_path=journal,
                    failure_receipt_path=failure_receipt,
                    receipt_path=root / "receipt.json",
                    started_ns=started_ns,
                )



class WorkBuddyRequestAuditRetryTest(unittest.TestCase):
    """The provider request ledger legitimately contains failed attempts the
    runtime retried; the REAL _collect_usage predicate must accept them,
    keep exact success accounting, and bound failures by the retry budget."""

    def _with_extra_records(self, extra_records, turns=None):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self._fixture(Path(directory))
            workbuddy = Path(manifest["workbuddy"]["checkout"])
            request_log = next(workbuddy.rglob("agent/requests.jsonl"))
            rows = [
                json.loads(line)
                for line in request_log.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            merged = [dict(record) for record in extra_records] + rows
            for seq, record in enumerate(merged, start=1):
                record["seq"] = seq
                record.setdefault("response", {"status": 200})
                record.setdefault("error", None)
            request_log.write_text(
                "".join(json.dumps(row) + "\n" for row in merged),
                encoding="utf-8",
            )
            if turns is not None:
                trajectory_path = request_log.with_name("trajectory.json")
                trajectory = json.loads(trajectory_path.read_text(encoding="utf-8"))
                trajectory["final_metrics"]["extra"]["metacodes_turns"] = turns
                trajectory_path.write_text(
                    json.dumps(trajectory) + "\n", encoding="utf-8"
                )
            return _collect_usage(manifest, started_ns=0, official_runner=True)

    def _fixture(self, root):
        manifest = self._official_usage_fixture(root, 1.0)
        manifest["schema_version"] = SCHEMA_VERSION
        return manifest

    _official_usage_fixture = (
        WorkBuddyPaidLaunchGateL2Test.__dict__["_official_usage_fixture"]
    )

    @staticmethod
    def _failed_record():
        return {
            "request": {"body": {}},
            "response": {"status": 502, "raw_bytes": 3},
            "error": "bad gateway",
            "duration_ms": 5.0,
        }

    def test_retried_failure_before_success_is_legal(self):
        usage = self._with_extra_records([self._failed_record()], turns=1)
        self.assertEqual(usage["quality"]["mean_verifier_reward"], 1.0)

    def test_failures_beyond_the_retry_budget_are_rejected(self):
        records = [self._failed_record() for _ in range(3)]
        with self.assertRaisesRegex(LaunchError, "incomplete or out of order"):
            self._with_extra_records(records, turns=1)
