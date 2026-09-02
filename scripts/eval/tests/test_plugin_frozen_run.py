"""The frozen-run manifest: a paid run's pre-registration.

A user authority binds to the manifest's hash *before* any provider request;
`run_paid_pair` and `analyze` re-derive every field from the live tree and
refuse to proceed - before opening the authority, before reading rollouts -
if anything the user signed has moved. The path-set digest is what makes a
shrunk pin list a named mismatch rather than a silently narrower freeze.

Arm inventories are patched to constants throughout: they exercise the
wrapper fixtures against a real runtime, which is not what these tests are
about, and their values do not matter here - only that they are frozen.
"""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval.model import ValidationError
from scripts.eval.plugin_pair_analysis import analyze
from scripts.eval.plugin_pair_runner import (
    AUTHORITY_SCHEMA,
    FROZEN_RUN_SCHEMA,
    _arm_identities,
    build_plan,
    freeze_run,
    frozen_run_fields,
    load_user_authority,
    main,
    manifest_sha256_of,
    path_set_digest,
    run_paid_pair,
    verify_frozen_manifest,
)
from scripts.eval.plugin_release_gate import (
    PluginGateError,
    load_protocol,
    refresh_implementation_fingerprint,
)

ROOT = Path(__file__).resolve().parents[3]
PROTOCOL = ROOT / "evals/plugin-v1/protocol.json"
INVENTORIES = mock.patch(
    "scripts.eval.plugin_pair_runner._verify_arm_inventory",
    lambda root, protocol, arm, executable, runtime: "inventory-" + arm,
)


def _frozen_fixture(directory: Path) -> tuple[Path, Path]:
    """A repinned protocol copy whose runtime pin names a fake executable."""
    runtime = directory / "metacodes-release-small"
    runtime.write_bytes(b"fake-release-small")
    os.chmod(runtime, 0o700)
    path = directory / "protocol.json"
    path.write_text(PROTOCOL.read_text(encoding="utf-8"), encoding="utf-8")
    refresh_implementation_fingerprint(ROOT, path)
    value = json.loads(path.read_text(encoding="utf-8"))
    value["coding_pair"]["runtime_binary_sha256"] = hashlib.sha256(runtime.read_bytes()).hexdigest()
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    return path, runtime


def _live_fields(protocol_path: Path, runtime: Path) -> dict:
    protocol = load_protocol(ROOT, protocol_path)
    _, wrapper_hashes, inventory_hashes = _arm_identities(ROOT, protocol, runtime)
    plan = build_plan(ROOT, protocol_path, runtime_binary=runtime)
    return frozen_run_fields(
        ROOT,
        protocol,
        protocol_sha256=hashlib.sha256(protocol_path.read_bytes()).hexdigest(),
        runtime_sha256=hashlib.sha256(runtime.read_bytes()).hexdigest(),
        wrapper_hashes=wrapper_hashes,
        inventory_hashes=inventory_hashes,
        schedule=plan["schedule"],
    )


def _write_private(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value), encoding="utf-8")
    os.chmod(path, 0o600)


@INVENTORIES
class FreezeAndVerifyTest(unittest.TestCase):
    def test_freeze_produces_a_manifest_that_verifies_against_the_same_tree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path, runtime = _frozen_fixture(Path(directory))
            manifest = freeze_run(ROOT, path, runtime)
            self.assertEqual(FROZEN_RUN_SCHEMA, manifest["schema"])
            self.assertEqual(manifest_sha256_of(manifest), manifest["manifest_sha256"])
            self.assertEqual(64, len(manifest["implementation_fingerprint"]))
            self.assertEqual(manifest["manifest_sha256"], verify_frozen_manifest(manifest, _live_fields(path, runtime)))

    def test_every_field_is_load_bearing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path, runtime = _frozen_fixture(Path(directory))
            manifest = freeze_run(ROOT, path, runtime)
            live = _live_fields(path, runtime)
            for key in (k for k in manifest if k not in {"schema", "manifest_sha256"}):
                tampered = dict(manifest)
                tampered[key] = "0" * 64 if isinstance(manifest[key], str) else {"x": "0" * 64}
                tampered["manifest_sha256"] = manifest_sha256_of(tampered)
                with self.assertRaisesRegex(ValidationError, f"drifted: {key}$"):
                    verify_frozen_manifest(tampered, live)
            # A manifest whose hash does not match its own fields is refused
            # even when every field matches the tree.
            forged = dict(manifest, manifest_sha256="0" * 64)
            with self.assertRaisesRegex(ValidationError, "hash does not match"):
                verify_frozen_manifest(forged, live)
            # And an unknown schema, or extra fields, are not silently accepted.
            with self.assertRaisesRegex(ValidationError, "unsupported schema"):
                verify_frozen_manifest(dict(manifest, schema="x"), live)
            with self.assertRaisesRegex(ValidationError, "unsupported or missing fields"):
                verify_frozen_manifest(dict(manifest, extra=1), live)

    def test_a_shrunk_pin_list_is_a_named_mismatch(self) -> None:
        # This is the guard the content fingerprint cannot provide: after a
        # repin nothing in protocol.json remembers the list was longer.
        with tempfile.TemporaryDirectory() as directory:
            path, runtime = _frozen_fixture(Path(directory))
            manifest = freeze_run(ROOT, path, runtime)
            value = json.loads(path.read_text(encoding="utf-8"))
            value["implementation_paths"].remove("src/tools/result_spool.zig")
            path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
            refresh_implementation_fingerprint(ROOT, path)  # the narrower list repins cleanly...
            load_protocol(ROOT, path)  # ...and the strict loader is satisfied by it.
            self.assertNotEqual(manifest["path_set_digest"], path_set_digest(load_protocol(ROOT, path)))
            # Shrinking the list necessarily rewrites protocol.json too, so the
            # protocol hash drifts as well; the digest's job is to *name* the
            # shrink alongside it rather than let it hide behind a generic
            # "protocol changed".
            with self.assertRaisesRegex(ValidationError, r"drifted: .*path_set_digest") as caught:
                verify_frozen_manifest(manifest, _live_fields(path, runtime))
            self.assertIn("protocol_sha256", str(caught.exception))


class ProductionEntryPointsVerifyTheManifestFirstTest(unittest.TestCase):
    def setUp(self) -> None:
        # Started here rather than as a class decorator: mock.patch on a class
        # wraps only test* methods, and setUp freezes a manifest - which
        # walks the arm inventories.
        patcher = mock.patch(
            "scripts.eval.plugin_pair_runner._verify_arm_inventory",
            lambda root, protocol, arm, executable, runtime: "inventory-" + arm,
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.temporary = Path(self._tmp.name)
        self.protocol_path, self.runtime = _frozen_fixture(self.temporary)
        self.manifest = freeze_run(ROOT, self.protocol_path, self.runtime)
        self.manifest_path = self.temporary / "frozen.json"
        _write_private(self.manifest_path, self.manifest)

    def test_run_paid_pair_rejects_a_foreign_manifest_before_opening_the_authority(self) -> None:
        foreign = dict(self.manifest, implementation_fingerprint="f" * 64)
        foreign["manifest_sha256"] = manifest_sha256_of(foreign)
        _write_private(self.manifest_path, foreign)
        authority = self.temporary / "authority.json"
        opened = []
        real_open = os.open

        def spy_open(path, *args, **kwargs):
            if str(path) == str(authority):
                opened.append(path)
            return real_open(path, *args, **kwargs)

        with mock.patch("scripts.eval.plugin_pair_runner.os.open", spy_open):
            with self.assertRaisesRegex(ValidationError, "drifted: implementation_fingerprint"):
                run_paid_pair(
                    ROOT,
                    self.protocol_path,
                    runtime_binary=self.runtime,
                    output_dir=self.temporary / "output",
                    budget_journal_path=self.temporary / "budget.jsonl",
                    provider_auth_file=self.temporary / "missing-provider-auth",
                    user_authority_file=authority,
                    frozen_manifest_file=self.manifest_path,
                )
        self.assertEqual([], opened)
        self.assertFalse((self.temporary / "output").exists())

    def test_run_paid_pair_requires_the_authority_to_name_this_manifest(self) -> None:
        authority = self.temporary / "authority.json"
        _write_private(authority, {
            "schema": AUTHORITY_SCHEMA,
            "protocol_sha256": hashlib.sha256(self.protocol_path.read_bytes()).hexdigest(),
            "manifest_sha256": "b" * 64,
            "max_cost_usd": 72.0,
            "max_metered_tokens": 72_000_000,
            "authorized_by_user": True,
        })
        with self.assertRaisesRegex(ValidationError, "another frozen-run manifest"):
            run_paid_pair(
                ROOT,
                self.protocol_path,
                runtime_binary=self.runtime,
                output_dir=self.temporary / "output",
                budget_journal_path=self.temporary / "budget.jsonl",
                provider_auth_file=self.temporary / "missing-provider-auth",
                user_authority_file=authority,
                frozen_manifest_file=self.manifest_path,
            )
        self.assertFalse((self.temporary / "output").exists())

    def test_analyze_rejects_a_foreign_manifest_before_reading_any_evidence(self) -> None:
        foreign = dict(self.manifest, path_set_digest="0" * 64)
        foreign["manifest_sha256"] = manifest_sha256_of(foreign)
        _write_private(self.manifest_path, foreign)
        with self.assertRaisesRegex(ValidationError, "drifted: path_set_digest"):
            analyze(
                ROOT,
                self.protocol_path,
                self.runtime,
                self.temporary / "no-baseline",
                self.temporary / "no-candidate",
                self.temporary / "no-journal",
                frozen_manifest_file=self.manifest_path,
            )


@INVENTORIES
class FreezeCliTest(unittest.TestCase):
    def test_freeze_writes_a_private_manifest_and_refuses_to_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path, runtime = _frozen_fixture(Path(directory))
            out = Path(directory) / "frozen.json"
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(0, main(["--freeze", "--protocol", str(path), "--runtime-binary", str(runtime), "--frozen-manifest", str(out)]))
            self.assertEqual(0o600, stat.S_IMODE(out.stat().st_mode))
            written = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(manifest_sha256_of(written), written["manifest_sha256"])
            with self.assertRaises(SystemExit):
                main(["--freeze", "--protocol", str(path), "--runtime-binary", str(runtime), "--frozen-manifest", str(out)])
            self.assertEqual(written, json.loads(out.read_text(encoding="utf-8")))


if __name__ == "__main__":
    unittest.main()
