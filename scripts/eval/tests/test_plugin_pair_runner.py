from __future__ import annotations

import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval.model import ValidationError
from scripts.eval.paired_runner import _runner_env, hermetic_env
from scripts.eval.plugin_pair_runner import (
    INVENTORY_IDENTITY,
    _canonical_sha256,
    _inventory,
    _require_scoring_checkpoints,
    _verify_arm_inventory,
    build_plan,
    load_user_authority,
    run_paid_pair,
)
from scripts.eval.plugin_release_gate import (
    PluginGateError,
    load_protocol,
    load_protocol_structure,
    refresh_implementation_fingerprint,
)
from scripts.eval.plugin_pair_analysis import analyze


ROOT = Path(__file__).resolve().parents[3]
PROTOCOL = ROOT / "evals/plugin-v1/protocol.json"


class PluginPairRunnerTest(unittest.TestCase):
    def setUp(self) -> None:
        # build_plan / run_paid_pair load strictly, as production must. The
        # committed pin is stale between freezes by design, so they are fed
        # a copy repinned against the live tree; the live file is read only
        # structurally.
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.protocol_path = Path(self._tmp.name) / "protocol.json"
        self.protocol_path.write_text(PROTOCOL.read_text(encoding="utf-8"), encoding="utf-8")
        refresh_implementation_fingerprint(ROOT, self.protocol_path)

    def test_default_plan_is_zero_provider_and_complete(self) -> None:
        plan = build_plan(ROOT, self.protocol_path)
        self.assertEqual(0, plan["provider_requests"])
        self.assertFalse(plan["quality_evidence"])
        self.assertEqual(36, len(plan["schedule"]))
        self.assertEqual(18, sum(row["arm"] == "baseline" for row in plan["schedule"]))
        self.assertEqual(18, sum(row["arm"] == "candidate" for row in plan["schedule"]))
        self.assertEqual(2.0, plan["fixed_rollout_budget"]["max_cost_usd"])
        self.assertEqual(2000000, plan["fixed_rollout_budget"]["max_metered_tokens"])
        self.assertEqual(8192, plan["fixed_rollout_budget"]["max_output_tokens"])
        self.assertEqual(
            {
                "state": "not_attested",
                "expected_sha256": load_protocol_structure(ROOT, PROTOCOL)["coding_pair"][
                    "runtime_binary_sha256"
                ],
            },
            plan["runtime"],
        )

    def test_plan_attests_only_an_explicit_matching_runtime(self) -> None:
        protocol = load_protocol(ROOT, self.protocol_path)
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            runtime = temporary / "metacodes-release-small"
            runtime.write_bytes(b"explicit-plan-runtime")
            os.chmod(runtime, 0o700)
            protocol["coding_pair"]["runtime_binary_sha256"] = hashlib.sha256(
                runtime.read_bytes()
            ).hexdigest()
            protocol_path = temporary / "protocol.json"
            protocol_path.write_text(json.dumps(protocol), encoding="utf-8")
            plan = build_plan(
                ROOT,
                protocol_path,
                runtime_binary=runtime,
            )
            self.assertEqual("attested", plan["runtime"]["state"])
            self.assertEqual(str(runtime.resolve()), plan["runtime"]["path"])

    def test_paid_pair_rejects_runtime_drift_before_private_authority(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            runtime = temporary / "wrong-runtime"
            runtime.write_bytes(b"wrong-runtime")
            os.chmod(runtime, 0o700)
            with self.assertRaisesRegex(PluginGateError, "ReleaseSmall runtime drifted"):
                run_paid_pair(
                    ROOT,
                    self.protocol_path,
                    runtime_binary=runtime,
                    output_dir=temporary / "output",
                    budget_journal_path=temporary / "budget.jsonl",
                    provider_auth_file=temporary / "missing-provider-auth",
                    user_authority_file=temporary / "missing-user-authority",
                    frozen_manifest_file=temporary / "missing-manifest",
                )

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture required")
    def test_inventory_wrapper_executes_the_explicit_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory) / "runtime.py"
            runtime.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os\n"
                "print(json.dumps({"
                "'schema':'metacodes.plugin-inventory/v1',"
                "'contract_version':1,'plugins':[],"
                "'runtime_marker':'explicit',"
                "'runtime_selector_visible':"
                "'METACODES_PLUGIN_RUNTIME_BINARY' in os.environ}))\n",
                encoding="utf-8",
            )
            os.chmod(runtime, 0o700)
            inventory = _inventory(
                ROOT,
                ROOT / "scripts/eval/fixtures/plugin_baseline.py",
                runtime,
            )
            self.assertEqual("explicit", inventory["runtime_marker"])
            self.assertFalse(inventory["runtime_selector_visible"])

    def test_paid_authority_must_bind_exact_protocol_and_permissions(self) -> None:
        plan = build_plan(ROOT, self.protocol_path)
        manifest = "a" * 64
        value = {
            "schema": "metacodes.plugin-paid-authority/v2",
            "protocol_sha256": plan["protocol_sha256"],
            "manifest_sha256": manifest,
            "max_cost_usd": 30.0,
            "max_metered_tokens": 30000000,
            "authorized_by_user": True,
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "authority.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            os.chmod(path, 0o600)
            observed = load_user_authority(
                path,
                protocol_sha256=plan["protocol_sha256"],
                manifest_sha256=manifest,
                max_cost_usd=30.0,
                max_metered_tokens=30000000,
            )
            self.assertEqual(value, observed)
            # Bound to another manifest: the run the user authorized is not
            # this one.
            with self.assertRaisesRegex(ValidationError, "another frozen-run manifest"):
                load_user_authority(
                    path,
                    protocol_sha256=plan["protocol_sha256"],
                    manifest_sha256="b" * 64,
                    max_cost_usd=30.0,
                    max_metered_tokens=30000000,
                )
            value["protocol_sha256"] = "0" * 64
            path.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaises(ValidationError):
                load_user_authority(
                    path,
                    protocol_sha256=plan["protocol_sha256"],
                    manifest_sha256=manifest,
                    max_cost_usd=30.0,
                    max_metered_tokens=30000000,
                )
            # v1 authorities carry no manifest and are refused outright.
            v1 = {k: v for k, v in value.items() if k != "manifest_sha256"}
            v1["schema"] = "metacodes.plugin-paid-authority/v1"
            v1["protocol_sha256"] = plan["protocol_sha256"]
            path.write_text(json.dumps(v1), encoding="utf-8")
            with self.assertRaisesRegex(ValidationError, "unsupported fields or schema"):
                load_user_authority(
                    path,
                    protocol_sha256=plan["protocol_sha256"],
                    manifest_sha256=manifest,
                    max_cost_usd=30.0,
                    max_metered_tokens=30000000,
                )

    @unittest.skipIf(os.name == "nt", "POSIX permissions required")
    def test_paid_authority_rejects_group_readable_file(self) -> None:
        plan = build_plan(ROOT, self.protocol_path)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "authority.json"
            path.write_text(
                json.dumps(
                    {
                        "schema": "metacodes.plugin-paid-authority/v2",
                        "protocol_sha256": plan["protocol_sha256"],
                        "manifest_sha256": "a" * 64,
                        "max_cost_usd": 30.0,
                        "max_metered_tokens": 30000000,
                        "authorized_by_user": True,
                    }
                ),
                encoding="utf-8",
            )
            os.chmod(path, 0o640)
            with self.assertRaises(ValidationError):
                load_user_authority(
                    path,
                    protocol_sha256=plan["protocol_sha256"],
                    manifest_sha256="a" * 64,
                    max_cost_usd=30.0,
                    max_metered_tokens=30000000,
                )

    def test_paid_inventory_identity_is_location_independent(self) -> None:
        """The runtime reports the plugin root as an absolute realpath. The
        frozen inventory hash must not depend on where the checkout lives -
        only on what the runtime says about the plugin - and the candidate
        root must be the one the protocol declares."""
        protocol = load_protocol_structure(ROOT, PROTOCOL)
        declared = protocol["candidate"]["root"]

        def inventory(source_root: str, generation: int = 1) -> dict:
            return {
                "schema": "metacodes.plugin-inventory/v1",
                "contract_version": 1,
                "generation": generation,
                "plugins": [
                    {
                        "id": "metacodes.benchmark-coding",
                        "version": protocol["candidate"]["plugin_version"],
                        "form": "data_package",
                        "layer": "session",
                        "lifecycle": "active",
                        "capabilities": ["skill_bundle"],
                        "contribution_count": 1,
                        "source_root": source_root,
                    }
                ],
            }

        def digest_of(value: dict) -> str:
            with mock.patch(
                "scripts.eval.plugin_pair_runner._inventory", return_value=value
            ), mock.patch("scripts.eval.plugin_pair_runner.attest_runtime_artifact") as attest:
                digest = _verify_arm_inventory(
                    ROOT, protocol, "candidate", ROOT / "unused-wrapper", ROOT / "unused-runtime"
                )
            self.assertEqual(2, attest.call_count)
            return digest

        canonical = digest_of(inventory(str((ROOT / declared).resolve())))
        self.assertEqual(
            _canonical_sha256(
                {
                    "projection": INVENTORY_IDENTITY,
                    "contract_version": 1,
                    "plugins": [
                        {
                            "id": "metacodes.benchmark-coding",
                            "version": protocol["candidate"]["plugin_version"],
                            "form": "data_package",
                            "layer": "session",
                            "lifecycle": "active",
                            "capabilities": ["skill_bundle"],
                            "contribution_count": 1,
                            "source_root": declared,
                        }
                    ],
                }
            ),
            canonical,
        )
        # The same directory reached through another name, from another
        # runtime generation, is the same identity...
        with tempfile.TemporaryDirectory() as directory:
            alias = Path(directory) / "alias"
            alias.symlink_to((ROOT / declared).resolve(), target_is_directory=True)
            self.assertEqual(canonical, digest_of(inventory(str(alias), generation=7)))
        # ...while a plugin loaded from anywhere else is not this candidate,
        # whatever it calls itself.
        with self.assertRaisesRegex(ValidationError, "not rooted at the frozen candidate root"):
            digest_of(inventory("/private/somewhere-else"))
        # And what the runtime says about the plugin is load-bearing.
        richer = inventory(str((ROOT / declared).resolve()))
        richer["plugins"][0]["contribution_count"] = 2
        self.assertNotEqual(canonical, digest_of(richer))

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture required")
    def test_inventory_runs_the_runtime_under_a_private_home(self) -> None:
        """`--dump-plugins` builds a full App first: under the caller's HOME
        it would leave a session directory behind, read their config (and
        spawn any MCP server in it) and probe the catalog. The preflight
        gives it a throwaway HOME and takes it away afterwards."""
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory) / "runtime.py"
            runtime.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os\n"
                "print(json.dumps({"
                "'schema':'metacodes.plugin-inventory/v1',"
                "'contract_version':1,'plugins':[],"
                "'home':os.environ.get('HOME'),"
                "'no_probe':os.environ.get('METACODES_NO_PROBE')}))\n",
                encoding="utf-8",
            )
            os.chmod(runtime, 0o700)
            with mock.patch.dict(os.environ, {"METACODES_NO_PROBE": "0"}):
                inventory = _inventory(
                    ROOT, ROOT / "scripts/eval/fixtures/plugin_baseline.py", runtime
                )
        self.assertEqual("1", inventory["no_probe"])
        self.assertNotEqual(os.environ.get("HOME"), inventory["home"])
        self.assertIn("metacodes-plugin-inventory-home-", inventory["home"])
        self.assertFalse(Path(inventory["home"]).exists())

    @unittest.skipIf(os.name == "nt", "POSIX executable fixture required")
    def test_inventory_does_not_inherit_shell_or_interpreter_injection_vectors(self) -> None:
        """`BASH_ENV`, exported functions, `PYTHONPATH`, loader preloads: each
        lets the invoking shell change what the child executes without any
        file in the tree changing, so none of them reaches the runtime."""
        injected = {
            "BASH_ENV": "/tmp/hook.sh",
            "BASH_FUNC_awk%%": "() { echo pwned; }",
            "PYTHONPATH": "/tmp/shadow",
            "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib",
            "LD_PRELOAD": "/tmp/x.so",
            "SHELLOPTS": "xtrace",
        }
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory) / "runtime.py"
            runtime.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os\n"
                "print(json.dumps({"
                "'schema':'metacodes.plugin-inventory/v1',"
                "'contract_version':1,'plugins':[],"
                "'seen':sorted(k for k in os.environ if k in %r)}))\n" % sorted(injected),
                encoding="utf-8",
            )
            os.chmod(runtime, 0o700)
            with mock.patch.dict(os.environ, injected):
                inventory = _inventory(
                    ROOT, ROOT / "scripts/eval/fixtures/plugin_baseline.py", runtime
                )
        self.assertEqual([], inventory["seen"])

    def test_child_environments_drop_injection_vectors_and_keep_the_rest(self) -> None:
        base = {
            "HOME": "/h", "PATH": "/usr/bin", "LANG": "C", "TERM": "xterm",
            "BASH_ENV": "/tmp/hook.sh", "ENV": "/tmp/hook.sh", "SHELLOPTS": "xtrace",
            "BASH_FUNC_ls%%": "() { :; }", "PYTHONPATH": "/x", "PYTHONHOME": "/x",
            "LD_PRELOAD": "/x.so", "LD_LIBRARY_PATH": "/x", "DYLD_INSERT_LIBRARIES": "/x",
            "NODE_OPTIONS": "--require /x", "PERL5OPT": "-M/x",
        }
        self.assertEqual(
            {"HOME": "/h", "PATH": "/usr/bin", "LANG": "C", "TERM": "xterm"},
            hermetic_env(base),
        )
        # The rollout side uses the same filter on top of its treatment-knob
        # stripping.
        with mock.patch.dict(os.environ, {"BASH_ENV": "/tmp/hook.sh", "METACODES_X": "1", "KEEP_ME": "1"}):
            env = _runner_env()
        self.assertNotIn("BASH_ENV", env)
        self.assertNotIn("METACODES_X", env)
        self.assertEqual("1", env["KEEP_ME"])

    def test_paid_resume_rejects_persisted_invalid_rollout(self) -> None:
        invalid = {
            "task_id": "02_html_game",
            "trial": 0,
            "judgement": {"valid_for_scoring": False},
            "execution": {
                "invalid_reasons": ["harness_or_provider_error"],
            },
            "evaluator": {"status": "ready"},
        }
        with self.assertRaisesRegex(ValidationError, "fail-closed"):
            _require_scoring_checkpoints(
                {"baseline": [invalid], "candidate": []}
            )




class ProductionEntryPointsStayStrictTest(unittest.TestCase):
    """Every path that plans, executes or judges rejects a stale pin before it
    has any side effect. These exist because the routine tests above feed
    production entry points a repinned copy - which means switching one of
    them to the structural loader would not have turned anything red."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.temporary = Path(self._tmp.name)
        self.stale = self.temporary / "protocol.json"
        self.stale.write_text(PROTOCOL.read_text(encoding="utf-8"), encoding="utf-8")
        refresh_implementation_fingerprint(ROOT, self.stale)
        raw = self.stale.read_text(encoding="utf-8")
        pinned = json.loads(raw)["coding_pair"]["implementation_fingerprint"]
        self.stale.write_text(raw.replace(pinned, "0f" * 32), encoding="utf-8")

    def test_build_plan_rejects_a_stale_pin(self) -> None:
        with self.assertRaisesRegex(PluginGateError, "fingerprint drifted"):
            build_plan(ROOT, self.stale)

    def test_run_paid_pair_rejects_a_stale_pin_before_any_side_effect(self) -> None:
        output_dir = self.temporary / "output"
        with self.assertRaisesRegex(PluginGateError, "fingerprint drifted"):
            run_paid_pair(
                ROOT,
                self.stale,
                runtime_binary=self.temporary / "no-runtime",
                output_dir=output_dir,
                budget_journal_path=self.temporary / "budget.jsonl",
                provider_auth_file=self.temporary / "missing-provider-auth",
                user_authority_file=self.temporary / "missing-user-authority",
                frozen_manifest_file=self.temporary / "no-manifest",
            )
        self.assertFalse(output_dir.exists())
        self.assertFalse((self.temporary / "budget.jsonl").exists())

    def test_analyze_rejects_a_stale_pin(self) -> None:
        with self.assertRaisesRegex(PluginGateError, "fingerprint drifted"):
            analyze(
                ROOT,
                self.stale,
                runtime_binary=self.temporary / "no-runtime",
                baseline_path=self.temporary / "no-baseline",
                candidate_path=self.temporary / "no-candidate",
                budget_journal_path=self.temporary / "no-journal",
                frozen_manifest_file=self.temporary / "no-manifest",
            )

if __name__ == "__main__":
    unittest.main()
