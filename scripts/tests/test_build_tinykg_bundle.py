from __future__ import annotations

import argparse
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from scripts import build_tinykg_bundle as bundle
from scripts.stage_tinykg_binary import BinaryIdentity, TinyKgBundle

PROJECT_ROOT = Path(__file__).resolve().parents[2]
BUILD_TABLE = """// tinykg-bundle-table:begin
const tinykg_bundle_table = [_]BundleTableEntry{
    .{ .key = "stale", .role = "cli", .path = "vendor/tinykg/bin/stale", .sha256 = "%s", .targets = &.{"x86_64-linux"} },
};
// tinykg-bundle-table:end
""" % ("0" * 64)


def manifest_document(artifacts):
    return {
        "bundle_schema": "metacodes.tinykg-bundle/v1",
        "source_commit": "a" * 40,
        "build": {"zig_version": "0.16.0", "optimize": "ReleaseSafe", "strip": True},
        "artifacts": artifacts,
    }


def project_tree(root: Path) -> None:
    """A miniature Metacodes checkout: contract, v1 manifest, build.zig table."""
    (root / "vendor/tinykg/bin").mkdir(parents=True)
    (root / "vendor/tinykg/manifest.json").write_text(
        json.dumps(
            manifest_document(
                [
                    {
                        "key": "linux-x86_64",
                        "path": "bin/tinykg-linux-x86_64",
                        "sha256": "0" * 64,
                        "format": "elf-static",
                        "architectures": ["x86_64"],
                        "targets": ["x86_64-linux"],
                    }
                ]
            )
        ),
        encoding="utf-8",
    )
    (root / "deps").mkdir()
    (root / "deps/tinykg.json").write_text(
        json.dumps(
            {
                "contract_schema": "metacodes.tinykg-binary/v1",
                "license": "Apache-2.0",
                "source_repository": "https://example.invalid",
                "storage_format_version": "3",
                "store_schema_version": "3",
                "tinykg_version": "0.2.0",
            }
        ),
        encoding="utf-8",
    )
    (root / "build.zig").write_text("pub fn build() void {}\n" + BUILD_TABLE, encoding="utf-8")
    source = root / "source"
    source.mkdir()
    (source / "build.zig.zon").write_text(
        '.version = "0.3.0"\n.minimum_zig_version = "0.16.0"\n', encoding="utf-8"
    )


@contextlib.contextmanager
def private_release_root(root: Path):
    """Keep the fixed /tmp export root out of the tests."""
    with mock.patch.object(bundle, "release_root", return_value=root / "export"):
        yield


def arguments(root: Path, **overrides) -> argparse.Namespace:
    values = {
        "source": root / "source",
        "commit": "a" * 40,
        "version": "0.3.0",
        "zig": "zig",
        "dry_run": False,
        "project_root": root,
    }
    values.update(overrides)
    return argparse.Namespace(**values)


def fake_builder(argv, *, cwd=None, dry_run=False):
    """Stands in for zig/lipo: records the command and materializes its output."""
    argv = tuple(str(value) for value in argv)
    print("$ " + bundle.command(argv, cwd))
    if argv[-1] == "version":
        return "0.16.0\n"
    if dry_run:  # the real runner prints and returns without executing
        return ""
    if "build" in argv:
        binaries = Path(argv[argv.index("--prefix") + 1]) / "bin"
        binaries.mkdir(parents=True, exist_ok=True)
        windows = any("windows" in value for value in argv)
        for name in ("tinykg", "tinykgd"):
            target = binaries / (name + (".exe" if windows else ""))
            target.write_bytes(b"executable bytes for " + target.name.encode("ascii"))
        return ""
    if argv[0] == "lipo":
        Path(argv[argv.index("-output") + 1]).write_bytes(b"universal " + argv[1].encode("ascii"))
        return ""
    return ""


class BuildTinyKgBundleTest(unittest.TestCase):
    def test_argument_validation_rejects_a_malformed_commit(self) -> None:
        with self.assertRaises(bundle.BundleError):
            bundle.verify_source(Path("/missing"), "bad")

    def test_scan_rejects_a_personal_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "binary"
            path.write_bytes(b"prefix /Users/alice/private suffix")
            with self.assertRaisesRegex(bundle.BundleError, "personal"):
                bundle.scan(path)

    def test_the_rendered_table_equals_the_one_committed_in_build_zig(self) -> None:
        # The build table is the second authority staging compares the manifest
        # against. If the renderer and the committed table ever disagree, a
        # regenerated bundle would silently stop being cross-checked.
        committed = (PROJECT_ROOT / "build.zig").read_text(encoding="utf-8")
        start = committed.index(bundle.BUILD_TABLE_BEGIN) + len(bundle.BUILD_TABLE_BEGIN)
        table = committed[start : committed.index(bundle.BUILD_TABLE_END)]
        manifest = TinyKgBundle.load(PROJECT_ROOT / "vendor/tinykg/manifest.json")
        self.assertEqual(table.strip(), bundle.render_build_table(manifest.artifacts).strip())

    def test_update_build_table_requires_exactly_one_marker_pair(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            build_zig = Path(directory) / "build.zig"
            build_zig.write_text("pub fn build() void {}\n", encoding="utf-8")
            with self.assertRaisesRegex(bundle.BundleError, "marker"):
                bundle.update_build_table(build_zig, ())

    def test_dry_run_prints_build_commands_without_touching_the_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project_tree(root)
            before = (root / "vendor/tinykg/manifest.json").read_text(encoding="utf-8")
            with private_release_root(root), mock.patch.object(bundle, "verify_source"), mock.patch.object(
                bundle, "run", side_effect=fake_builder
            ), mock.patch.object(bundle.platform, "system", return_value="Darwin"), mock.patch.object(
                bundle.platform, "machine", return_value="arm64"
            ), mock.patch.object(
                bundle, "export_source"
            ), mock.patch.object(
                bundle.subprocess, "run", side_effect=AssertionError("no subprocess in a dry run")
            ):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(bundle.build(arguments(root, dry_run=True)), 0)
            printed = output.getvalue()
            self.assertIn("-Dtarget=x86_64-linux-musl", printed)
            self.assertIn("lipo -create", printed)
            self.assertEqual(before, (root / "vendor/tinykg/manifest.json").read_text(encoding="utf-8"))
            self.assertIn('"stale"', (root / "build.zig").read_text(encoding="utf-8"))

    def test_generates_a_v2_manifest_with_both_roles_and_repins_the_build_table(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project_tree(root)
            identity = BinaryIdentity(root / "probe", "0" * 64, "tinykg 0.3.0")
            with private_release_root(root), mock.patch.object(bundle, "verify_source"), mock.patch.object(
                bundle, "run", side_effect=fake_builder
            ), mock.patch.object(bundle.platform, "system", return_value="Darwin"), mock.patch.object(
                bundle.platform, "machine", return_value="arm64"
            ), mock.patch.object(
                bundle, "export_source", side_effect=lambda *_: None
            ), mock.patch.object(
                bundle, "inspect_binary", return_value=identity
            ), mock.patch.object(
                bundle, "validate_store_contract"
            ), mock.patch.object(
                bundle, "validate_bundle_bytes"
            ), mock.patch.object(
                bundle, "attest_native", return_value=[]
            ):
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(bundle.build(arguments(root)), 0)

            generated = json.loads((root / "vendor/tinykg/manifest.json").read_text(encoding="utf-8"))
            self.assertEqual("metacodes.tinykg-bundle/v2", generated["bundle_schema"])
            self.assertEqual(8, len(generated["artifacts"]))
            roles = {(entry["key"], entry["role"]) for entry in generated["artifacts"]}
            self.assertIn(("macos-universal", "cli"), roles)
            self.assertIn(("macos-universal-daemon", "daemon"), roles)
            for entry in generated["artifacts"]:
                published = root / "vendor/tinykg" / entry["path"]
                self.assertTrue(published.is_file(), entry["path"])
                self.assertEqual(entry["sha256"], bundle.sha256_file(published))
            deps = json.loads((root / "deps/tinykg.json").read_text(encoding="utf-8"))
            self.assertEqual("0.3.0", deps["tinykg_version"])
            self.assertEqual("3", deps["storage_format_version"])

            # The build table must now carry every generated digest, so the next
            # `tinykg:stage` still compares two independently committed files.
            table = (root / "build.zig").read_text(encoding="utf-8")
            self.assertNotIn('"stale"', table)
            for entry in generated["artifacts"]:
                self.assertIn(entry["sha256"], table)
                self.assertIn('.role = "%s"' % entry["role"], table)


if __name__ == "__main__":
    unittest.main()
