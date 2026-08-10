from __future__ import annotations

import http.server
import json
import os
from pathlib import Path
import platform
import shutil
import socketserver
import tempfile
import threading
import time
import unittest

from scripts.eval.memory_agent_runtime import _text_sse, _tool_results, _tool_sse
from scripts.eval.memory_benchmark import file_sha256
from scripts.eval.memory_budget_journal import (
    BudgetAuthority,
    BudgetJournal,
    usd_to_microusd,
)
from scripts.eval.memory_replay import (
    PRODUCTION_MODEL_ID,
    PRODUCTION_MODEL_PROVIDER,
    PRODUCTION_PROVIDER_ID,
)
from scripts.eval.project_harness_e3_experiment import (
    ARMS,
    ARM_CONFIG,
    ANALYSIS_PLAN,
    CASE_BY_ID,
    E3_ALLOWED_TOOLS,
    E3_DISALLOWED_TOOLS,
    E3Error,
    _canonical_sha256,
    _kernel_runtime_dependencies,
)
from scripts.eval.project_harness_e3_pilot import (
    MAX_TIMEOUT_STREAM_BYTES,
    _bounded_timeout_stream,
    _rollout_window,
    _run_one,
)
from scripts.eval.project_harness_e3_templates import build_templates


class _Provider:
    def __init__(self, workspace: Path) -> None:
        self.workspace = workspace
        self.requests: list[dict] = []
        self.recovery_contracts: list[dict] = []
        self.server: socketserver.TCPServer | None = None
        self.thread: threading.Thread | None = None

    def __enter__(self) -> "_Provider":
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args: object) -> None:
                return

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("content-length", "0"))
                body = json.loads(self.rfile.read(length))
                outer.requests.append(body)
                index = len(outer.requests)
                if index == 1:
                    response = _tool_sse(
                        [("read-cluster", "Read", {"file_path": str(outer.workspace / "cluster.txt")})],
                        index,
                    )
                elif index == 2:
                    response = _tool_sse(
                        [("write-summary", "Write", {
                            "file_path": str(outer.workspace / "DEPLOY_SUMMARY.md"),
                            "content": "# Deployment\n\n- Cluster: CLUSTER-VIOLET-2\n- Window: 23:10-23:25Z\n",
                        })],
                        index,
                    )
                elif index == 3:
                    response = _tool_sse(
                        [("verify-summary", "Read", {"file_path": str(outer.workspace / "DEPLOY_SUMMARY.md")})],
                        index,
                    )
                else:
                    response = _text_sse("completed", index)
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.end_headers()
                self.wfile.write(response)

        socketserver.TCPServer.allow_reuse_address = True
        self.server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        return self

    @property
    def url(self) -> str:
        assert self.server is not None
        return f"http://127.0.0.1:{self.server.server_address[1]}/v1/messages"

    def __exit__(self, *_args: object) -> None:
        assert self.server is not None and self.thread is not None
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


class _HazardProvider(_Provider):
    def __enter__(self) -> "_HazardProvider":
        outer = self
        old = "service: atlas\nstrategy: recreate\nreplicas: 1\n"
        new = "# managed deployment\nservice: atlas\nreplicas: 3\nstrategy: rolling\n"

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args: object) -> None:
                return

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("content-length", "0"))
                body = json.loads(self.rfile.read(length))
                outer.requests.append(body)
                index = len(outer.requests)
                results = _tool_results(body)
                if index == 1:
                    response = _tool_sse(
                        [("read-deploy", "Read", {"file_path": str(outer.workspace / "deploy.yaml")})],
                        index,
                    )
                elif index == 2:
                    response = _tool_sse(
                        [("write-deploy", "Write", {
                            "file_path": str(outer.workspace / "deploy.yaml"),
                            "content": new,
                        })],
                        index,
                    )
                elif "verify-deploy" in results:
                    response = _text_sse("completed", index)
                elif "edit-deploy" in results:
                    response = _tool_sse(
                        [("verify-deploy", "Read", {"file_path": str(outer.workspace / "deploy.yaml")})],
                        index,
                    )
                elif "project_rule_blocked" in results.get("write-deploy", ""):
                    try:
                        error = json.loads(results["write-deploy"])["error"]
                        recovery = error["recovery"]
                        valid_recovery = (
                            error["recoverable"] is False
                            and recovery["task_recoverable"] is True
                            and recovery["action"] == "edit_existing_file_exact"
                            and any(
                                "ends with a newline" in requirement
                                for requirement in recovery["requirements"]
                            )
                        )
                    except (KeyError, TypeError, json.JSONDecodeError):
                        valid_recovery = False
                    if valid_recovery:
                        outer.recovery_contracts.append(recovery)
                        response = _tool_sse(
                            [("edit-deploy", "Edit", {
                                "file_path": str(outer.workspace / "deploy.yaml"),
                                "old_string": old,
                                "new_string": new,
                            })],
                            index,
                        )
                    else:
                        response = _text_sse("missing governed recovery contract", index)
                else:
                    response = _text_sse("completed", index)
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.end_headers()
                self.wfile.write(response)

        socketserver.TCPServer.allow_reuse_address = True
        self.server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        return self


class _StallingProvider(_Provider):
    def __enter__(self) -> "_StallingProvider":
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args: object) -> None:
                return

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("content-length", "0"))
                outer.requests.append(json.loads(self.rfile.read(length)))
                # The real native client has crossed the durable authorization
                # boundary and reached a provider socket. Keep that socket open
                # beyond the host timeout so _run_one exercises its actual
                # subprocess.TimeoutExpired path.
                time.sleep(5)

        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True

        self.server = Server(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        return self


class ProjectHarnessE3RuntimeTest(unittest.TestCase):
    def test_rollout_window_pauses_without_reordering_resume_prefix(self) -> None:
        schedule = [{"sequence": index} for index in range(4)]
        self.assertEqual([{"sequence": 1}], _rollout_window(schedule, 1, 1))
        self.assertEqual(
            [{"sequence": 2}, {"sequence": 3}],
            _rollout_window(schedule, 2, None),
        )
        for invalid in (True, 0, -1):
            with self.assertRaisesRegex(E3Error, "integer > 0"):
                _rollout_window(schedule, 0, invalid)

    def test_timeout_capture_is_bounded_and_redacts_credential(self) -> None:
        secret = "private-e3-test-key"
        raw = b"prefix:" + secret.encode() + b":" + (b"x" * (MAX_TIMEOUT_STREAM_BYTES + 128))
        persisted, evidence = _bounded_timeout_stream(raw, api_key=secret)
        self.assertLessEqual(len(persisted), MAX_TIMEOUT_STREAM_BYTES)
        self.assertNotIn(secret.encode(), persisted)
        self.assertIn(b"[REDACTED_CREDENTIAL]", persisted)
        self.assertTrue(evidence["truncated"])
        self.assertEqual(1, evidence["credential_redactions"])
        self.assertEqual(len(raw), evidence["captured_bytes"])

    def test_real_signal_runner_crosses_authorization_provider_and_journal(self) -> None:
        binary_raw = os.environ.get("METACODES_TEST_PROJECT_HARNESS_PRODUCTION_BIN")
        kernel_raw = os.environ.get("METACODES_TEST_PROJECT_KERNEL_PATH")
        if platform.system() != "Darwin" or not binary_raw or not kernel_raw:
            self.skipTest("native macOS production binary/kernel not configured")
        repo = Path(__file__).resolve().parents[3]
        binary = Path(binary_raw).resolve(strict=True)
        kernel = Path(kernel_raw).resolve(strict=True)
        ripgrep_raw = os.environ.get("METACODES_TEST_RIPGREP") or shutil.which("rg")
        if not ripgrep_raw:
            self.skipTest("native ripgrep is unavailable")
        ripgrep = Path(ripgrep_raw).resolve(strict=True)
        case = CASE_BY_ID["create_deploy_summary"]
        with tempfile.TemporaryDirectory(prefix="metacodes-e3-runtime-") as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            run_dir = root / "run"
            workspace.mkdir()
            run_dir.mkdir()
            manifest = {
                "manifest_id": "1" * 64,
                "analysis_plan": ANALYSIS_PLAN,
                "cases": [case],
                "root": str(root),
                "project_root": str(workspace),
                "project_sha256": "2" * 64,
                "repository": {"commit": "3" * 40, "dirty": False},
                "artifacts": {
                    "production_binary": {"path": str(binary), "sha256": file_sha256(binary)},
                    "shadow_binary": {"path": str(binary), "sha256": file_sha256(binary)},
                    "kernel": {
                        "path": str(kernel),
                        "sha256": file_sha256(kernel),
                        "runtime_dependencies": _kernel_runtime_dependencies(kernel),
                    },
                },
                "execution": {
                    "provider_identity": PRODUCTION_PROVIDER_ID,
                    "model_provider": PRODUCTION_MODEL_PROVIDER,
                    "model_id": PRODUCTION_MODEL_ID,
                    "model_fingerprint": "4" * 64,
                    "allowed_tools": list(E3_ALLOWED_TOOLS),
                    "disallowed_tools": list(E3_DISALLOWED_TOOLS),
                    "max_output_tokens": 4096,
                    "max_rollout_cost_usd": 0.9,
                    "max_rollout_metered_tokens": 300_000,
                    "max_total_cost_usd": 2.0,
                    "max_total_metered_tokens": 600_001,
                },
                "arms": {
                    arm: {
                        "binary": "production_binary",
                        "rule_flavor": None,
                        "actuation": "none",
                    }
                    for arm in ARMS
                },
            }
            templates = {"templates": {}}
            schedule = {
                "sequence": 0,
                "case_id": case["id"],
                "trial": 0,
                "position": 0,
                "arm": "signal_only",
            }
            authority = BudgetAuthority(
                manifest_sha256=_canonical_sha256(manifest),
                model_fingerprint="4" * 64,
                provider_identity=PRODUCTION_PROVIDER_ID,
                total_cost_microusd=usd_to_microusd(2.0),
                total_metered_tokens=600_001,
            )
            with _Provider(workspace) as provider, BudgetJournal(root / "budget.json", authority) as budget:
                item = _run_one(
                    repo=repo,
                    manifest=manifest,
                    templates=templates,
                    schedule=schedule,
                    run_dir=run_dir,
                    ripgrep=ripgrep,
                    ripgrep_sha256=file_sha256(ripgrep),
                    api_key="loopback-secret-not-for-production",
                    budget=budget,
                    timeout_seconds=30,
                    test_base_url=provider.url,
                )
                snapshot = budget.snapshot()
            receipt = json.loads(Path(item["receipt_path"]).read_text(encoding="utf-8"))
            self.assertEqual("E2-loopback-runner-boundary", receipt["evidence_level"])
            self.assertFalse(receipt["quality_evidence"])
            self.assertTrue(receipt["grader"]["passed"])
            self.assertTrue(receipt["governance"]["task_success"])
            self.assertEqual(0, receipt["governance"]["formal_decisions"])
            self.assertEqual(3, receipt["governance"]["dispatcher_entries"])
            self.assertEqual(1, receipt["governance"]["authoritative_dispatches"])
            self.assertEqual(2, receipt["governance"]["speculative_prefetch_dispatches"])
            self.assertEqual(4, receipt["provider_requests"])
            self.assertEqual(1, snapshot["transaction_states"]["committed"])
            first_system = provider.requests[0]["system"]
            self.assertNotIn("# Memory", first_system)
            self.assertNotIn("# Knowledge Graph", first_system)
            self.assertNotIn(str(run_dir), first_system)

    def test_real_evolved_runner_blocks_before_dispatch_and_recovers(self) -> None:
        binary_raw = os.environ.get("METACODES_TEST_PROJECT_HARNESS_PRODUCTION_BIN")
        driver_raw = os.environ.get("METACODES_TEST_PROJECT_HARNESS_LIFECYCLE_DRIVER")
        kernel_raw = os.environ.get("METACODES_TEST_PROJECT_KERNEL_PATH")
        lake_raw = os.environ.get("METACODES_TEST_PROJECT_LAKE_PATH")
        if platform.system() != "Darwin" or not all((binary_raw, driver_raw, kernel_raw, lake_raw)):
            self.skipTest("native macOS lifecycle artifacts are not configured")
        repo = Path(__file__).resolve().parents[3]
        binary = Path(str(binary_raw)).resolve(strict=True)
        kernel = Path(str(kernel_raw)).resolve(strict=True)
        driver = Path(str(driver_raw)).resolve(strict=True)
        lake = Path(str(lake_raw)).resolve(strict=True)
        ripgrep_raw = os.environ.get("METACODES_TEST_RIPGREP") or shutil.which("rg")
        if not ripgrep_raw:
            self.skipTest("native ripgrep is unavailable")
        ripgrep = Path(ripgrep_raw).resolve(strict=True)
        case = CASE_BY_ID["canonicalize_deploy_yaml"]
        with tempfile.TemporaryDirectory(prefix="metacodes-e3-evolved-runtime-") as temporary:
            root = Path(temporary) / "experiment"
            templates = build_templates(
                repo=repo,
                root=root,
                driver=driver,
                kernel=kernel,
                lake=lake,
                builder=repo / "scripts/build_project_rule.py",
                allow_dirty=True,
            )
            workspace = Path(templates["project_root"])
            run_dir = root / "run"
            run_dir.mkdir()
            manifest = {
                "manifest_id": "a" * 64,
                "analysis_plan": ANALYSIS_PLAN,
                "cases": [case],
                "root": str(root),
                "project_root": str(workspace),
                "project_sha256": templates["project_sha256"],
                "repository": {"commit": "b" * 40, "dirty": False},
                "artifacts": {
                    "production_binary": {"path": str(binary), "sha256": file_sha256(binary)},
                    "shadow_binary": {"path": str(binary), "sha256": file_sha256(binary)},
                    "kernel": {
                        "path": str(kernel),
                        "sha256": file_sha256(kernel),
                        "runtime_dependencies": _kernel_runtime_dependencies(kernel),
                    },
                },
                "execution": {
                    "provider_identity": PRODUCTION_PROVIDER_ID,
                    "model_provider": PRODUCTION_MODEL_PROVIDER,
                    "model_id": PRODUCTION_MODEL_ID,
                    "model_fingerprint": "c" * 64,
                    "allowed_tools": list(E3_ALLOWED_TOOLS),
                    "disallowed_tools": list(E3_DISALLOWED_TOOLS),
                    "max_output_tokens": 4096,
                    "max_rollout_cost_usd": 0.9,
                    "max_rollout_metered_tokens": 300_000,
                    "max_total_cost_usd": 2.0,
                    "max_total_metered_tokens": 600_001,
                },
                "arms": ARM_CONFIG,
            }
            signal_schedule = {
                "sequence": 0,
                "case_id": case["id"],
                "trial": 0,
                "position": 0,
                "arm": "signal_only",
            }
            evolved_schedule = {
                "sequence": 1,
                "case_id": case["id"],
                "trial": 0,
                "position": 3,
                "arm": "evolved_enforced",
            }
            authority = BudgetAuthority(
                manifest_sha256=_canonical_sha256(manifest),
                model_fingerprint="c" * 64,
                provider_identity=PRODUCTION_PROVIDER_ID,
                total_cost_microusd=usd_to_microusd(2.0),
                total_metered_tokens=600_001,
            )
            with BudgetJournal(root / "budget.json", authority) as budget:
                with _HazardProvider(workspace) as signal_provider:
                    _run_one(
                        repo=repo,
                        manifest=manifest,
                        templates=templates,
                        schedule=signal_schedule,
                        run_dir=run_dir,
                        ripgrep=ripgrep,
                        ripgrep_sha256=file_sha256(ripgrep),
                        api_key="loopback-secret-not-for-production",
                        budget=budget,
                        timeout_seconds=30,
                        test_base_url=signal_provider.url,
                    )
                with _HazardProvider(workspace) as provider:
                    item = _run_one(
                        repo=repo,
                        manifest=manifest,
                        templates=templates,
                        schedule=evolved_schedule,
                        run_dir=run_dir,
                        ripgrep=ripgrep,
                        ripgrep_sha256=file_sha256(ripgrep),
                        api_key="loopback-secret-not-for-production",
                        budget=budget,
                        timeout_seconds=30,
                        test_base_url=provider.url,
                    )
            self.assertEqual(signal_provider.requests[0], provider.requests[0])
            self.assertEqual(
                ["edit_existing_file_exact"],
                [item["action"] for item in provider.recovery_contracts],
            )
            receipt = json.loads(Path(item["receipt_path"]).read_text(encoding="utf-8"))
            governance = receipt["governance"]
            self.assertTrue(receipt["grader"]["passed"])
            self.assertTrue(governance["formal_block"])
            self.assertTrue(governance["existing_file_write_recurrence"])
            self.assertFalse(governance["existing_file_write_dispatch"])
            self.assertFalse(governance["realized_existing_file_write_effect"])
            self.assertEqual(1, governance["exact_edit_recovery_directions"])
            self.assertTrue(governance["recovery_after_block"])
            self.assertTrue(governance["trustworthy_task_success"])

    def test_real_runner_timeout_persists_authorized_failure_without_retry(self) -> None:
        binary_raw = os.environ.get("METACODES_TEST_PROJECT_HARNESS_PRODUCTION_BIN")
        kernel_raw = os.environ.get("METACODES_TEST_PROJECT_KERNEL_PATH")
        if platform.system() != "Darwin" or not binary_raw or not kernel_raw:
            self.skipTest("native macOS production binary/kernel not configured")
        repo = Path(__file__).resolve().parents[3]
        binary = Path(binary_raw).resolve(strict=True)
        kernel = Path(kernel_raw).resolve(strict=True)
        ripgrep_raw = os.environ.get("METACODES_TEST_RIPGREP") or shutil.which("rg")
        if not ripgrep_raw:
            self.skipTest("native ripgrep is unavailable")
        ripgrep = Path(ripgrep_raw).resolve(strict=True)
        case = CASE_BY_ID["canonicalize_deploy_yaml"]
        with tempfile.TemporaryDirectory(prefix="metacodes-e3-timeout-") as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            run_dir = root / "run"
            workspace.mkdir()
            run_dir.mkdir()
            manifest = {
                "manifest_id": "d" * 64,
                "analysis_plan": ANALYSIS_PLAN,
                "cases": [case],
                "root": str(root),
                "project_root": str(workspace),
                "project_sha256": "e" * 64,
                "repository": {"commit": "f" * 40, "dirty": False},
                "artifacts": {
                    "production_binary": {"path": str(binary), "sha256": file_sha256(binary)},
                    "shadow_binary": {"path": str(binary), "sha256": file_sha256(binary)},
                    "kernel": {
                        "path": str(kernel),
                        "sha256": file_sha256(kernel),
                        "runtime_dependencies": _kernel_runtime_dependencies(kernel),
                    },
                },
                "execution": {
                    "provider_identity": PRODUCTION_PROVIDER_ID,
                    "model_provider": PRODUCTION_MODEL_PROVIDER,
                    "model_id": "glm-5.2",
                    "model_fingerprint": "9" * 64,
                    "allowed_tools": list(E3_ALLOWED_TOOLS),
                    "disallowed_tools": list(E3_DISALLOWED_TOOLS),
                    "max_output_tokens": 4096,
                    "max_rollout_cost_usd": 0.9,
                    "max_rollout_metered_tokens": 300_000,
                    "max_total_cost_usd": 2.0,
                    "max_total_metered_tokens": 600_001,
                },
                "arms": {
                    arm: {
                        "binary": "production_binary",
                        "rule_flavor": None,
                        "actuation": "none",
                    }
                    for arm in ARMS
                },
            }
            schedule = {
                "sequence": 0,
                "case_id": case["id"],
                "trial": 0,
                "position": 0,
                "arm": "signal_only",
            }
            authority = BudgetAuthority(
                manifest_sha256=_canonical_sha256(manifest),
                model_fingerprint="9" * 64,
                provider_identity=PRODUCTION_PROVIDER_ID,
                total_cost_microusd=usd_to_microusd(2.0),
                total_metered_tokens=600_001,
            )
            api_key = "loopback-timeout-secret"
            with _StallingProvider(workspace) as provider, BudgetJournal(
                root / "budget.json", authority
            ) as budget:
                with self.assertRaisesRegex(E3Error, "automatic retry is forbidden"):
                    _run_one(
                        repo=repo,
                        manifest=manifest,
                        templates={"templates": {}},
                        schedule=schedule,
                        run_dir=run_dir,
                        ripgrep=ripgrep,
                        ripgrep_sha256=file_sha256(ripgrep),
                        api_key=api_key,
                        budget=budget,
                        timeout_seconds=1,
                        test_base_url=provider.url,
                    )
                budget_snapshot = budget.snapshot()
            self.assertEqual(1, len(provider.requests))
            self.assertEqual({"request_authorized": 1}, budget_snapshot["transaction_states"])
            self.assertEqual(900_000, budget_snapshot["exposure_cost_microusd"])
            self.assertEqual(300_000, budget_snapshot["exposure_metered_tokens"])
            rollout = (
                run_dir
                / "rollouts"
                / "00000-canonicalize_deploy_yaml-signal_only"
            )
            diagnostic_path = rollout / "child-timeout.json"
            diagnostic = json.loads(diagnostic_path.read_text(encoding="utf-8"))
            self.assertEqual(
                "metacodes-project-harness-e3-child-timeout-v1",
                diagnostic["schema_version"],
            )
            self.assertFalse(diagnostic["quality_evidence"])
            self.assertTrue(diagnostic["direct_child_killed_and_reaped"])
            self.assertTrue(diagnostic["automatic_retry_forbidden"])
            self.assertEqual("unknown", diagnostic["remote_request_outcome"])
            self.assertEqual(1, diagnostic["cassette"]["request_files"])
            self.assertEqual(0, diagnostic["cassette"]["response_files"])
            self.assertEqual(
                "request_authorized",
                diagnostic["budget_transaction"]["state"],
            )
            self.assertEqual(
                {"request_authorized": 1},
                diagnostic["budget_journal"]["transaction_states"],
            )
            self.assertTrue((rollout / "stdout.ndjson").is_file())
            self.assertTrue((rollout / "stderr.log").is_file())
            self.assertTrue((rollout / "native-events.jsonl").is_file())
            self.assertFalse((rollout / "rollout-receipt.json").exists())
            self.assertNotIn(api_key.encode(), diagnostic_path.read_bytes())
            self.assertEqual(
                case["initial_files"]["deploy.yaml"],
                (workspace / "deploy.yaml").read_text(),
            )


if __name__ == "__main__":
    unittest.main()
