import json
import os
import secrets
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

from scripts.eval.harbor.bench.share import ManagerSession, peer_key, share
from scripts.eval.harbor.profiling import TimingRelay
from scripts.eval.tests.test_bench_workbench import RotatingGateway


class ModelShareTest(unittest.TestCase):
    def test_share_opens_one_paired_forward_and_reconnects(self):
        cfg = {"executors": [{"name": "B", "kind": "ssh", "host": "node-b"}]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gateway = RotatingGateway(root, lifetime=3600)
            self.addCleanup(gateway.close)
            path = root / "peer.env"
            key = "mcpeer-" + secrets.token_hex(32)
            path.write_text("MODEL_MANAGER_KEY=" + key)
            path.chmod(0o600)
            with patch.dict(os.environ, {"METACODES_OAUTH_DIR": str(gateway.state / "oauth")}), \
                    patch("subprocess.Popen") as ssh, patch("time.sleep") as sleep:
                tunnel = ssh.return_value.__enter__.return_value
                tunnel.wait.side_effect = [255, 0]
                self.assertEqual(share(cfg, "B", path, 23456, gateway.state), 0)
                argv = ssh.call_args.args[0]
                self.assertRegex(argv[argv.index("-R") + 1], r"^127\.0\.0\.1:23456:127\.0\.0\.1:[0-9]+$")
                self.assertIn("StrictHostKeyChecking=yes", argv)
                self.assertIn("node-b", argv)
                self.assertFalse(any(secret in str(ssh.call_args) for secret in [key, *gateway.issued]))
                self.assertEqual(ssh.call_args_list[0], ssh.call_args_list[1])
                sleep.assert_called_once()

    def test_peer_key_is_dedicated_and_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "peer.env"
            key = peer_key(path)
            self.assertNotEqual(peer_key(path.with_name("other.env")), key)
            self.assertEqual(peer_key(path), key)
            if os.name == "posix":
                path.chmod(0o644)
                with self.assertRaises(ValueError):
                    peer_key(path)
                path.chmod(0o600)
            path.write_text('{"access_token": "fixture", "refresh_token": "fixture"}')
            with self.assertRaises(ValueError):
                peer_key(path)

    def test_model_requests_follow_manager_rotation_logout_and_gateway_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gateway = RotatingGateway(root, lifetime=3600)
            self.addCleanup(gateway.close)
            with patch.dict(os.environ, {"METASK_SITE_URL": gateway.url, "METACODES_OAUTH_DIR":
                                         str(gateway.state / "oauth")}):
                manager = ManagerSession(gateway.state)
                with TimingRelay(manager.gateway, manager, root, bind="127.0.0.1", record=False,
                                 model_gateway=True) as relay:
                    def request(path, key=relay.token, body=None):
                        req = urllib.request.Request(relay.url + path, data=body,
                                                     headers={"Authorization": "Bearer " + key})
                        try:
                            with urllib.request.urlopen(req, timeout=5) as response:
                                return response.status, response.read()
                        except urllib.error.HTTPError as error:
                            error.close()
                            return error.code, b""

                    self.assertEqual(request("/v1/models", "other")[0], 401)
                    self.assertEqual(request("/api/oauth/token", body=b"{}")[0], 404)
                    self.assertEqual(request("/v1/models", body=b"{}")[0], 405)
                    self.assertIn(b"session-model", request("/v1/models")[1])
                    self.assertIn(b"message_stop", request("/v1/messages", body=b"{}")[1])
                    gateway.revoke(gateway.current_access)
                    self.assertIn(b"message_stop", request("/v1/messages", body=b"{}")[1])
                    self.assertEqual(len(gateway.refreshes), 1)
                    path = gateway.state / "oauth/metask.json"
                    stored = json.loads(path.read_bytes())
                    path.write_text(json.dumps({**stored, "gateway_url": "https://other.invalid"}))
                    self.assertEqual(request("/v1/models")[0], 401)
                    path.unlink()
                    self.assertEqual(request("/v1/models")[0], 401)
