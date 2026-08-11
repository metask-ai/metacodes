import hashlib
import http.server
import json
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval.memory_budget_journal import validate_checkpoint_payload
from scripts.eval.model import ValidationError, stable_json
from scripts.eval.workbuddy.launch_gate import (
    LaunchError,
    PROVIDER_KEY_ENV,
    SCHEMA_VERSION,
    _paid_host_guard,
    _reobserve_launch_inputs,
    execute_launch,
    validate_launch_manifest,
)
from scripts.eval.workbuddy import WORKBUDDY_PINNED_COMMIT
from scripts.eval.workbuddy.install_overlay import _digest


def digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


class _Server:
    def __init__(self, journal_path: Path):
        self.journal_path = journal_path
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
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"ok":true}')

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
    def _manifest(self, root: Path) -> Path:
        workbuddy = root / "workbuddy"
        workbuddy.mkdir(mode=0o700)
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "quality_evidence": False,
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
            "budget": {
                "total_cost_microusd": 1_000_000,
                "total_metered_tokens": 100_000,
                "max_cost_microusd": 500_000,
                "max_metered_tokens": 50_000,
                "prior_exposure_microusd": 0,
                "user_authority_microusd": 1_000_000_000,
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
secret = resolve_secret_env("", "METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF")
assert secret == "private-workbuddy-test-key"
assert "METACODES_WORKBUDDY_PROVIDER_KEY_FD_REF" not in os.environ
request = urllib.request.Request(sys.argv[2], data=b"{}", method="POST")
with urllib.request.urlopen(request, timeout=5) as response:
    assert response.status == 200
agent = Path(sys.argv[3]) / "results/metacodes-code-l2/run/code-task-a__1/agent"
agent.mkdir(parents=True)
trajectory = {
  "final_metrics": {
    "total_prompt_tokens": 120,
    "total_completion_tokens": 30,
    "total_cached_tokens": 80,
    "total_cost_usd": 0.01,
    "extra": {"cache_creation_input_tokens": 10}
  }
}
(agent / "trajectory.json").write_text(json.dumps(trajectory) + "\n")
record = {"request": {"body": {"model": "volatile-route", "system": "stable", "messages": [{"role": "user", "content": "task"}]}}}
(agent / "requests.jsonl").write_text(json.dumps(record) + "\n")
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
            self.assertEqual(result["usage"]["metered_tokens"], 150)
            self.assertEqual(result["usage"]["provider_requests"], 1)
            task = result["usage"]["tasks"]["code-task-a"]
            self.assertEqual(task["cache_read_input_tokens"], 80)
            self.assertEqual(task["cache_creation_input_tokens"], 10)
            self.assertEqual(len(task["cacheable_first_request_sha256"]), 64)
            self.assertTrue(receipt.is_file())
            self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)
            self.assertNotIn("private-workbuddy-test-key", receipt.read_text())

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
                "scripts.eval.workbuddy.launch_gate._git",
                side_effect=[WORKBUDDY_PINNED_COMMIT, "https://github.com/Tencent/WorkBuddy-Bench"],
            ):
                with self.assertRaisesRegex(
                    LaunchError, "installed overlay files changed"
                ):
                    _reobserve_launch_inputs(manifest)


if __name__ == "__main__":
    unittest.main()
