import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval.workbuddy.run_w05 import (
    EXPECTED_PROVIDER_REQUESTS,
    EXPECTED_RUNTIME_CONTRACT,
    TASK_NAME,
    W05Error,
    _clean_environment,
    _control_assertions,
    _fresh_checkout,
    _identity,
    _mock_audit,
    _private_new,
    _proxy_audit,
    _receipt_assertions,
    _runtime_contract_assertions,
    _stable_evidence,
    _wire_json_sha256,
)
from scripts.eval.tests.posix_only import POSIX


class WorkBuddyW05RunnerTest(unittest.TestCase):
    @staticmethod
    def _mock_rows(bodies):
        return [
            {
                "schema_version": "metacodes-workbuddy-mock-provider-v2",
                "scenario": "control-plane-v1",
                "request_number": number,
                "body_sha256": _wire_json_sha256(body),
                "model": body["model"],
                "control_metrics_absent": True,
            }
            for number, body in enumerate(bodies, 1)
        ]

    @staticmethod
    def _proxy_rows(bodies):
        return [
            {
                "seq": number,
                "route": "fixture-run--metacodes-w05-mock",
                "trial_id": f"{TASK_NAME}__fixture",
                "request": {
                    "upstream_url": "http://127.0.0.1:4123/v1/messages",
                    "upstream_body": body,
                },
            }
            for number, body in enumerate(bodies, 1)
        ]

    @staticmethod
    def _bodies():
        return [
            {
                "model": "glm-5.2",
                "stream": True,
                "messages": [{"role": "user", "content": f"turn-{number}"}],
            }
            for number in range(1, EXPECTED_PROVIDER_REQUESTS + 1)
        ]

    def test_mock_and_proxy_audit_bind_all_eight_wire_bodies_in_order(self):
        bodies = self._bodies()
        mock_rows = _mock_audit(self._mock_rows(bodies))
        _proxy_audit(self._proxy_rows(bodies), mock_rows)

        drifted = self._proxy_rows(bodies)
        drifted[3]["request"]["upstream_body"]["messages"][0]["content"] = "drift"
        with self.assertRaisesRegex(W05Error, "drifted at 4"):
            _proxy_audit(drifted, mock_rows)

        drifted = self._proxy_rows(bodies)
        drifted[3]["route"] = "another-run--metacodes-w05-mock"
        with self.assertRaisesRegex(W05Error, "drifted at 4"):
            _proxy_audit(drifted, mock_rows)

    def test_audits_reject_order_drift_and_provider_claimed_control_metrics(self):
        bodies = self._bodies()
        mock_rows = self._mock_rows(bodies)
        mock_rows[1]["request_number"] = 7
        with self.assertRaisesRegex(W05Error, "audit drifted"):
            _mock_audit(mock_rows)

        mock_rows = self._mock_rows(bodies)
        proxy_rows = self._proxy_rows(bodies)
        proxy_rows[0]["request"]["upstream_body"]["messages"].append(
            {"role": "user", "control_metrics": {"forged": True}}
        )
        mock_rows[0]["body_sha256"] = _wire_json_sha256(
            proxy_rows[0]["request"]["upstream_body"]
        )
        with self.assertRaisesRegex(W05Error, "drifted at 1"):
            _proxy_audit(proxy_rows, mock_rows)

    def test_control_assertions_require_exact_dispatch_and_terminal_commit(self):
        metrics = {
            "tool_runtime": {
                "dispatch_started": 7,
                "dispatch_finished": 7,
                "transcript_calls_without_result": 0,
            },
            "tinykg": {
                "used": True,
                "remember_succeeded": 1,
                "recall_succeeded": 1,
                "context_succeeded": 1,
                "task_create_calls": 1,
                "task_update_calls": 2,
                "task_terminal_commits": 1,
            },
            "lean": {"used": True, "checker_calls": 7, "admit": 7},
        }
        _control_assertions(metrics)
        metrics["tinykg"]["task_terminal_commits"] = 0
        with self.assertRaisesRegex(W05Error, "task-DAG evidence"):
            _control_assertions(metrics)

    def test_receipt_is_permanently_non_quality_and_zero_external_provider(self):
        metrics = {
            "tool_runtime": {
                "dispatch_started": 7,
                "dispatch_finished": 7,
                "transcript_calls_without_result": 0,
            },
            "tinykg": {
                "used": True,
                "remember_succeeded": 1,
                "recall_succeeded": 1,
                "context_succeeded": 1,
                "task_create_calls": 1,
                "task_update_calls": 2,
                "task_terminal_commits": 1,
            },
            "lean": {"used": True, "checker_calls": 1, "admit": 1},
        }
        receipt = {
            "schema_version": "metacodes-workbuddy-w05-receipt-v1",
            "quality_evidence": False,
            "verifier_reward": 1,
            "network": {
                "external_paid_provider_requests": 0,
                "mock_scripted_provider_requests": 8,
            },
            "control_metrics": metrics,
        }
        _receipt_assertions(receipt)
        for key, value in (
            ("quality_evidence", True),
            ("verifier_reward", 0),
        ):
            drifted = {**receipt, key: value}
            with self.assertRaisesRegex(W05Error, "receipt classification"):
                _receipt_assertions(drifted)
        drifted = json.loads(json.dumps(receipt))
        drifted["network"]["external_paid_provider_requests"] = 1
        with self.assertRaisesRegex(W05Error, "receipt classification"):
            _receipt_assertions(drifted)

    def test_runtime_contract_is_exact_and_environment_drops_ambient_secrets(self):
        _runtime_contract_assertions(EXPECTED_RUNTIME_CONTRACT)
        drifted = json.loads(json.dumps(EXPECTED_RUNTIME_CONTRACT))
        drifted["local_tinykg"] = False
        with self.assertRaisesRegex(W05Error, "runtime isolation"):
            _runtime_contract_assertions(drifted)

        environment = _clean_environment(
            {
                "PATH": "/fixture",
                "ANTHROPIC_AUTH_TOKEN": "secret",
                "GLM_API_KEY": "secret",
                "TINYKG_REMOTE_CONFIG": "/remote",
                "METACODES_KG_CONFIG": "/local-daemon",
                "METACODES_KG_URL": "http://127.0.0.1:1",
                "METACODES_KG_API_KEY": "must-not-reach-child",
                "METACODES_KG_EXPECTED_BUILD_ID": "sha256:" + "f" * 64,
                "METACODES_KG_EXPECTED_SCHEMA_DIGEST": "e" * 64,
                "METASK_API_KEY": "secret",
            }
        )
        self.assertEqual(environment, {"PATH": "/fixture"})

    def test_private_publication_is_0600_atomic_and_refuses_existing_or_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            output = root / "receipt.json"
            _private_new(output, b'{"complete":true}\n')
            self.assertEqual(output.read_bytes(), b'{"complete":true}\n')
            if POSIX:  # permission bits are synthetic on Windows
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(root.glob(".receipt.json.*.tmp")), [])
            with self.assertRaisesRegex(W05Error, "overwrite"):
                _private_new(output, b"replacement")

            link = root / "linked.json"
            link.symlink_to(output)
            with self.assertRaisesRegex(W05Error, "overwrite"):
                _private_new(link, b"replacement")

    def test_identity_refuses_symlink_hardlink_and_detects_evidence_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            evidence = root / "evidence.json"
            evidence.write_text("{}\n", encoding="utf-8", newline="\n")
            before = {"evidence": _identity(evidence)}
            self.assertEqual(
                before["evidence"]["sha256"],
                hashlib.sha256(b"{}\n").hexdigest(),
            )
            evidence.write_text('{"changed":true}\n', encoding="utf-8", newline="\n")
            with self.assertRaisesRegex(W05Error, "changed during validation"):
                _stable_evidence(before, {"evidence": evidence})

            symlink = root / "symlink.json"
            symlink.symlink_to(evidence)
            with self.assertRaisesRegex(W05Error, "symlink"):
                _identity(symlink)
            hardlink = root / "hardlink.json"
            os.link(evidence, hardlink)
            with self.assertRaisesRegex(W05Error, "single-link"):
                _identity(evidence)

    def test_fresh_checkout_requires_root_pinned_tencent_origin_clean_and_no_env(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()

            def clean_git(_repo, *args):
                values = {
                    ("rev-parse", "--show-toplevel"): str(root),
                    ("rev-parse", "HEAD"): "b516950be5b56eb3be406c2f76ee1c5111dcb57f",
                    ("remote", "get-url", "origin"): "git@github.com:Tencent/WorkBuddy-Bench.git",
                    ("status", "--short", "--untracked-files=all"): "",
                }
                return values[args]

            with mock.patch("scripts.eval.workbuddy.run_w05._git", side_effect=clean_git):
                _fresh_checkout(root)
                (root / ".env").write_text("SECRET=x\n", encoding="utf-8", newline="\n")
                with self.assertRaisesRegex(W05Error, "\.env"):
                    _fresh_checkout(root)

            (root / ".env").unlink()
            with mock.patch(
                "scripts.eval.workbuddy.run_w05._git",
                side_effect=lambda repo, *args: (
                    "dirty" if args[0] == "status" else clean_git(repo, *args)
                ),
            ):
                with self.assertRaisesRegex(W05Error, "fresh WorkBuddy"):
                    _fresh_checkout(root)


if __name__ == "__main__":
    unittest.main()
