#!/usr/bin/env python3
"""Verify a staged metacodes CLI release unit against its manifest (#80).

Implements the fail-closed checks of the release review (#47 §5.4). The static
checks run anywhere, for any target:

  1. manifest self-consistency — the document matches release/manifest.schema.json,
     every listed file exists as a regular file with the listed SHA-256, and the
     prefix holds nothing the manifest does not name (symlinks are refused);
  7. licences — every component's license_path exists and is non-empty, and the
     third-party notices name every runtime asset.

With `--native` the executables are run as well, always from a temporary
working directory outside the prefix (check 5: nothing may depend on a
repository-relative path) and with `RG_BIN` / `METACODES_KG_BIN` removed:

  2. `bin/metacodes --version --json` agrees with the manifest field by field;
  3. `vendor/tinykg/tinykg version` names the declared version and a fresh store
     reports the declared storage format and store schema;
  4. `bin/metacodes doctor --json --strict` exits 0 and resolves ripgrep and
     TinyKG to the files inside the prefix, with the manifest's digests. The
     Lean kernel checks are held to the same bar when the report carries them:
     a kernel the executable pins must sit under `libexec/metacodes/`, match,
     and carry a provenance sidecar its own loader accepts; a pin without a
     shipped kernel fails, as does a report without the kernel checks; the
     TinyKG daemon check is held to the same pinned-must-ship rule. The
     layout ships no kernel today (release/LAYOUT.md), so a release executable
     pins none and both checks stay unresolved. The kernel environment pairs are
     stripped like `RG_BIN` so the bundle is judged on its own contents.

Check 6 (byte-identical archives) belongs to `release:archive` (#81).

`--self-test` builds a fixture bundle in a temporary directory and proves the
static checks accept it and name each deviation. Python 3.9, stdlib only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = PROJECT_ROOT / "release" / "manifest.schema.json"
sys.path.insert(0, str(PROJECT_ROOT))
from scripts.stage_tinykg_binary import _parse_store_info  # noqa: E402


class BundleError(Exception):
    """One named deviation; the message is the finding."""


# ── schema (a small draft-07 subset, enough for release/manifest.schema.json) ──


def validate_schema(instance: object, schema: dict, root: dict, path: str = "$") -> None:
    if "$ref" in schema:
        target = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            target = target[part]
        validate_schema(instance, target, root, path)
        return
    if "const" in schema and instance != schema["const"]:
        raise BundleError(f"{path}: expected {schema['const']!r}, found {instance!r}")
    if "enum" in schema and instance not in schema["enum"]:
        raise BundleError(f"{path}: {instance!r} is not one of {schema['enum']!r}")
    if "type" in schema:
        allowed = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_is_type(instance, kind) for kind in allowed):
            raise BundleError(f"{path}: expected {allowed!r}, found {type(instance).__name__}")
    if isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                raise BundleError(f"{path}: missing required key {key!r}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in instance:
                if key not in properties:
                    raise BundleError(f"{path}: unexpected key {key!r}")
        for key, value in instance.items():
            if key in properties:
                validate_schema(value, properties[key], root, f"{path}.{key}")
    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            raise BundleError(f"{path}: fewer than {schema['minItems']} items")
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            raise BundleError(f"{path}: more than {schema['maxItems']} items")
        if "items" in schema:
            for index, item in enumerate(instance):
                validate_schema(item, schema["items"], root, f"{path}[{index}]")
    if isinstance(instance, str) and "pattern" in schema and re.search(schema["pattern"], instance) is None:
        raise BundleError(f"{path}: {instance!r} does not match {schema['pattern']!r}")
    if isinstance(instance, int) and not isinstance(instance, bool) and "minimum" in schema and instance < schema["minimum"]:
        raise BundleError(f"{path}: {instance} is below {schema['minimum']}")


def _is_type(instance: object, kind: str) -> bool:
    if kind == "object":
        return isinstance(instance, dict)
    if kind == "array":
        return isinstance(instance, list)
    if kind == "string":
        return isinstance(instance, str)
    if kind == "integer":
        return isinstance(instance, int) and not isinstance(instance, bool)
    if kind == "boolean":
        return isinstance(instance, bool)
    if kind == "null":
        return instance is None
    raise BundleError(f"schema uses an unsupported type {kind!r}")


# ── static checks ─────────────────────────────────────────────────────────────


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest(prefix: Path, schema_path: Path = SCHEMA_PATH) -> dict:
    manifest_path = prefix / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise BundleError("manifest.json is missing or not a regular file")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise BundleError(f"manifest.json is not valid JSON: {exc}") from exc
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    validate_schema(manifest, schema, schema)
    return manifest


def check_files(prefix: Path, manifest: dict) -> None:
    """Check 1: the listed files are exactly the prefix, digests included."""
    listed = {entry["path"]: entry["sha256"] for entry in manifest["files"]}
    if [entry["path"] for entry in manifest["files"]] != sorted(listed):
        raise BundleError("files[] is not sorted by path, or lists a path twice")
    present: dict[str, Path] = {}
    for path in sorted(prefix.rglob("*")):
        relative = path.relative_to(prefix).as_posix()
        if path.is_symlink():
            raise BundleError(f"symlink inside the bundle: {relative}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise BundleError(f"non-regular entry inside the bundle: {relative}")
        if relative == "manifest.json":
            continue
        present[relative] = path
    for relative in sorted(set(present) - set(listed)):
        raise BundleError(f"file not named by the manifest: {relative}")
    for relative in sorted(set(listed) - set(present)):
        raise BundleError(f"manifest names a missing file: {relative}")
    for relative, expected in sorted(listed.items()):
        actual = sha256_file(present[relative])
        if actual != expected:
            raise BundleError(f"digest mismatch for {relative}: manifest {expected}, file {actual}")
    for component in manifest["components"]:
        if listed.get(component["path"]) != component["sha256"]:
            raise BundleError(f"component {component['name']} digest disagrees with files[] for {component['path']}")


def check_licenses(prefix: Path, manifest: dict) -> None:
    """Check 7: licence texts ship and the notices cover every runtime asset."""
    for component in manifest["components"]:
        license_path = component.get("license_path")
        if component["role"] == "runtime_asset" and license_path is None:
            raise BundleError(f"runtime asset {component['name']} declares no license_path")
        if license_path is not None:
            candidate = prefix / license_path
            if not candidate.is_file() or candidate.stat().st_size == 0:
                raise BundleError(f"licence for {component['name']} is missing or empty: {license_path}")
    notices = prefix / "share" / "licenses" / "THIRD_PARTY_NOTICES.md"
    if not notices.is_file():
        raise BundleError("share/licenses/THIRD_PARTY_NOTICES.md is missing")
    text = notices.read_text(encoding="utf-8").lower()
    for component in manifest["components"]:
        if component["role"] == "runtime_asset" and component["name"].lower() not in text:
            raise BundleError(f"third-party notices do not mention {component['name']}")
    if manifest["release"]["channel"] == "stable" and not (prefix / "share" / "licenses" / "metacodes-LICENSE").is_file():
        raise BundleError("a stable release ships share/licenses/metacodes-LICENSE")


# ── native checks ─────────────────────────────────────────────────────────────


def _component(manifest: dict, name: str) -> dict:
    for component in manifest["components"]:
        if component["name"] == name:
            return component
    raise BundleError(f"manifest has no component {name!r}")


# Everything the executables read from the environment to find a runtime asset
# or a kernel; stripped so the bundle is judged on its own contents.
NEUTRALIZED_ENV = (
    "RG_BIN",
    "METACODES_KG_BIN",
    "METACODES_FORMAL_KERNEL_PATH",
    "METACODES_FORMAL_KERNEL_SHA256",
    "METACODES_FORMAL_KERNEL_TIMEOUT_MS",
    "METACODES_PROJECT_KERNEL_PATH",
    "METACODES_PROJECT_KERNEL_SHA256",
    "METACODES_PROJECT_KERNEL_TIMEOUT_MS",
)


def _run(argv: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    env = {key: value for key, value in os.environ.items() if key not in NEUTRALIZED_ENV}
    return subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, encoding="utf-8", timeout=120)


def check_version_identity(prefix: Path, manifest: dict, cwd: Path) -> None:
    """Check 2: the executable describes itself exactly as the manifest does."""
    executable = prefix / _component(manifest, "metacodes")["path"]
    completed = _run([str(executable), "--version", "--json"], cwd)
    if completed.returncode != 0:
        raise BundleError(f"--version --json exited {completed.returncode}: {completed.stderr.strip()[:200]}")
    try:
        identity = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise BundleError(f"--version --json is not JSON: {completed.stdout[:200]!r}") from exc
    expectations = {
        "version": manifest["release"]["version"],
        "commit": manifest["source"]["commit"],
        "dirty": manifest["source"]["dirty"],
        "zig": manifest["toolchain"]["zig_version"],
        "target": manifest["target"]["zig_target"],
        "optimize": manifest["build"]["optimize"],
        "release_layout": True,
    }
    for key, expected in expectations.items():
        if identity.get(key) != expected:
            raise BundleError(f"--version --json {key}={identity.get(key)!r}, manifest says {expected!r}")
    contract = identity.get("contract") or {}
    for key in ("binary_abi_version", "binary_abi_revision", "config_schema_version"):
        if contract.get(key) != manifest["contract"][key]:
            raise BundleError(f"--version --json contract.{key}={contract.get(key)!r}, manifest says {manifest['contract'][key]!r}")
    assets = {asset["name"]: asset for asset in identity.get("expected_runtime_assets") or []}
    for name in ("ripgrep", "tinykg"):
        component = _component(manifest, name)
        if assets.get(name, {}).get("sha256") != component["sha256"]:
            raise BundleError(f"--version --json expects {name} {assets.get(name, {}).get('sha256')!r}, manifest ships {component['sha256']}")
        if assets.get(name, {}).get("version") != component["version"]:
            raise BundleError(f"--version --json expects {name} {assets.get(name, {}).get('version')!r}, manifest ships {component['version']}")


def check_tinykg(prefix: Path, manifest: dict, cwd: Path) -> None:
    """Check 3: the shipped TinyKG is the declared version with the declared store contract."""
    component = _component(manifest, "tinykg")
    binary = prefix / component["path"]
    version = _run([str(binary), "version"], cwd)
    if version.returncode != 0 or version.stdout.strip() != f"tinykg {component['version']}":
        raise BundleError(f"tinykg version reported {version.stdout.strip()!r}, manifest says {component['version']!r}")
    with tempfile.TemporaryDirectory() as directory:
        store = Path(directory) / "probe.kg"
        initialized = _run([str(binary), "init", str(store)], cwd)
        if initialized.returncode != 0:
            raise BundleError(f"tinykg init failed: {initialized.stdout.strip()[:200]}")
        inspected = _run([str(binary), "store-info", str(store)], cwd)
        if inspected.returncode != 0:
            raise BundleError(f"tinykg store-info failed: {inspected.stdout.strip()[:200]}")
        fields = _parse_store_info(inspected.stdout)
    compat = component["compat"]
    # store-info prints the store schema as `schema_version` (stage_tinykg_binary.py reads the same key)
    observed = (fields.get("storage_format_version"), fields.get("schema_version"))
    declared = (compat["storage_format_version"], compat["store_schema_version"])
    if observed != declared:
        raise BundleError(f"tinykg fresh store reports {observed!r}, manifest declares {declared!r}")


KERNEL_CHECKS = ("formal_kernel", "project_kernel")


def check_doctor(prefix: Path, manifest: dict, cwd: Path) -> None:
    """Check 4: doctor resolves both runtime assets inside the prefix, digests matching."""
    executable = prefix / _component(manifest, "metacodes")["path"]
    completed = _run([str(executable), "doctor", "--json", "--strict"], cwd)
    try:
        report = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        if completed.returncode != 0:
            raise BundleError(f"doctor --strict exited {completed.returncode}: {completed.stdout.strip()[:200]}") from exc
        raise BundleError(f"doctor --json is not JSON: {completed.stdout[:200]!r}") from exc
    if completed.returncode != 0:
        # The report precedes the exit code: name the check that failed strict.
        try:
            evaluate_doctor_report(report, prefix, manifest)
        except BundleError as exc:
            raise BundleError(f"doctor --strict exited {completed.returncode}: {exc}") from exc
        raise BundleError(f"doctor --strict exited {completed.returncode} on a check this verifier does not evaluate: {completed.stdout.strip()[:200]}")
    evaluate_doctor_report(report, prefix, manifest)


def evaluate_doctor_report(report: object, prefix: Path, manifest: dict) -> None:
    """The judgement of check 4 over a parsed `doctor --json` document."""
    checks = {check.get("name"): check for check in (report.get("checks") if isinstance(report, dict) else None) or [] if isinstance(check, dict)}
    for name in ("ripgrep", "tinykg"):
        check = checks.get(name)
        if check is None:
            raise BundleError(f"doctor reports no {name} check")
        resolved = check.get("resolved_path")
        if not isinstance(resolved, str):
            raise BundleError(f"doctor did not resolve {name}")
        expected_path = (prefix / _component(manifest, name)["path"]).resolve()
        if Path(resolved).resolve() != expected_path:
            raise BundleError(f"doctor resolved {name} to {resolved}, outside the bundle ({expected_path})")
        if check.get("sha256") != _component(manifest, name)["sha256"] or check.get("match") is not True:
            raise BundleError(f"doctor sees {name} digest {check.get('sha256')!r}, manifest ships {_component(manifest, name)['sha256']}")
    kernel_dir = (prefix / "libexec" / "metacodes").resolve()
    for name in KERNEL_CHECKS:
        check = checks.get(name)
        if check is None:
            raise BundleError(f"doctor reports no {name} check")
        resolved = check.get("resolved_path")
        expected = check.get("expected_sha256")
        if resolved is None:
            if expected is not None:
                raise BundleError(f"doctor pins {name} ({expected}) but the bundle ships no kernel under libexec/metacodes")
            continue
        if not isinstance(resolved, str) or Path(resolved).resolve().parent != kernel_dir:
            raise BundleError(f"doctor resolved {name} to {resolved}, outside the bundle's libexec/metacodes")
        if check.get("match") is not True:
            raise BundleError(f"doctor sees {name} digest {check.get('sha256')!r}, the executable pins {expected}")
        if check.get("provenance") is not True:
            raise BundleError(f"doctor rejects the {name} provenance sidecar (provenance={check.get('provenance')!r}); it must satisfy the {name} loader")
    daemon = checks.get("tinykgd")
    if daemon is None:
        raise BundleError("doctor reports no tinykgd check")
    resolved = daemon.get("resolved_path")
    expected = daemon.get("expected_sha256")
    if resolved is None:
        if expected is not None:
            raise BundleError(f"doctor pins tinykgd ({expected}) but the bundle ships no daemon under vendor/tinykg")
    else:
        vendored_dir = (prefix / "vendor" / "tinykg").resolve()
        if not isinstance(resolved, str) or Path(resolved).resolve().parent != vendored_dir:
            raise BundleError(f"doctor resolved tinykgd to {resolved}, outside the bundle's vendor/tinykg")
        if daemon.get("match") is not True:
            raise BundleError(f"doctor sees tinykgd digest {daemon.get('sha256')!r}, the executable pins {expected}")


def verify(prefix: Path, native: bool) -> list[str]:
    """Every finding, in check order; an empty list is a verified bundle."""
    findings: list[str] = []
    try:
        manifest = load_manifest(prefix)
    except BundleError as exc:
        return [f"check 1 (manifest): {exc}"]
    for label, check in (("check 1 (files)", check_files), ("check 7 (licences)", check_licenses)):
        try:
            check(prefix, manifest)
        except BundleError as exc:
            findings.append(f"{label}: {exc}")
    if native and not findings:
        with tempfile.TemporaryDirectory() as outside:
            cwd = Path(outside)
            for label, check in (
                ("check 2 (--version --json)", check_version_identity),
                ("check 3 (tinykg)", check_tinykg),
                ("check 4 (doctor)", check_doctor),
            ):
                try:
                    check(prefix, manifest, cwd)
                except BundleError as exc:
                    findings.append(f"{label}, run from outside the bundle: {exc}")
    return findings


# ── self-test ─────────────────────────────────────────────────────────────────


def _write(root: Path, relative: str, data: bytes) -> str:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return hashlib.sha256(data).hexdigest()


def _fixture(root: Path) -> dict:
    commit = "0123456789abcdef0123456789abcdef01234567"
    digests = {
        "bin/metacodes": _write(root, "bin/metacodes", b"metacodes"),
        "bin/rg": _write(root, "bin/rg", b"rg"),
        "vendor/tinykg/tinykg": _write(root, "vendor/tinykg/tinykg", b"tinykg"),
        "vendor/tinykg/tinykg.provenance.json": _write(root, "vendor/tinykg/tinykg.provenance.json", b"{}"),
        "share/licenses/metacodes-LICENSE": _write(root, "share/licenses/metacodes-LICENSE", b"MIT"),
        "share/licenses/ripgrep-LICENSE-MIT": _write(root, "share/licenses/ripgrep-LICENSE-MIT", b"MIT"),
        "share/licenses/tinykg-LICENSE": _write(root, "share/licenses/tinykg-LICENSE", b"Apache"),
        "share/licenses/THIRD_PARTY_NOTICES.md": _write(root, "share/licenses/THIRD_PARTY_NOTICES.md", b"ripgrep and TinyKG"),
        "share/doc/README.md": _write(root, "share/doc/README.md", b"# metacodes"),
        "share/doc/CHANGELOG-0.1.0.md": _write(root, "share/doc/CHANGELOG-0.1.0.md", b"# changelog"),
    }
    manifest = {
        "schema_version": 1,
        "vendor": "metask",
        "name": "metacodes-cli",
        "release": {"version": "0.1.0", "channel": "stable", "tag": "0.1.0"},
        "source": {"commit": commit, "dirty": False},
        "toolchain": {"zig_version": "0.16.0"},
        "target": {"id": "x86_64-linux-gnu", "architecture": "x86_64", "os": "linux", "abi": "gnu", "zig_target": "x86_64-linux-gnu"},
        "build": {"optimize": "ReleaseSafe", "strip": True},
        "contract": {"cli_surface_version": 1, "binary_abi_status": "experimental", "binary_abi_version": 1, "binary_abi_revision": 15, "config_schema_version": 1},
        "components": [
            {"role": "primary_executable", "name": "metacodes", "path": "bin/metacodes", "sha256": digests["bin/metacodes"], "version": "0.1.0"},
            {
                "role": "runtime_asset", "name": "ripgrep", "path": "bin/rg", "sha256": digests["bin/rg"], "version": "15.2.0",
                "revision": "e89fff89ac", "upstream": "https://github.com/BurntSushi/ripgrep", "license": "MIT OR Unlicense",
                "license_path": "share/licenses/ripgrep-LICENSE-MIT", "purpose": "Glob/Grep execution dependency",
            },
            {
                "role": "runtime_asset", "name": "tinykg", "path": "vendor/tinykg/tinykg", "sha256": digests["vendor/tinykg/tinykg"], "version": "0.2.0",
                "source_commit": commit, "upstream": "https://github.com/metask-ai/tinykg", "license": "Apache-2.0",
                "license_path": "share/licenses/tinykg-LICENSE", "provenance_path": "vendor/tinykg/tinykg.provenance.json",
                "compat": {"storage_format_version": "3", "store_schema_version": "3"}, "purpose": "memory / task control plane",
            },
        ],
        "compatibility": {
            "requires": [{"component": "tinykg", "cli_version": "0.2.x", "storage_format_version": "3", "store_schema_version": "3"}],
            "fails_without": [{"component": "ripgrep", "effect": "Grep / Glob unavailable"}],
            "degraded_without": [{"component": "tinykg", "effect": "KG memory/task degrade; agent loop unaffected"}],
        },
        "files": [{"path": path, "sha256": digest} for path, digest in sorted(digests.items())],
    }
    return manifest


def _write_manifest(root: Path, manifest: dict) -> None:
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _expect(findings: list[str], needle: str) -> None:
    if not any(needle in finding for finding in findings):
        raise SystemExit(f"self-test: expected a finding containing {needle!r}, got {findings!r}")


def _expect_bundle_error(action, needle: str) -> None:
    try:
        action()
    except BundleError as exc:
        if needle in str(exc):
            return
        raise SystemExit(f"self-test: expected an error containing {needle!r}, got {exc!r}")
    raise SystemExit(f"self-test: expected an error containing {needle!r}, got none")


def _doctor_report(root: Path, manifest: dict, **project_kernel) -> dict:
    """A `doctor --json` document for the fixture bundle; `project_kernel`
    overrides the project kernel entry (unpinned and unresolved by default)."""
    kernel = {"name": "project_kernel", "resolved_path": None, "sha256": None, "expected_sha256": None, "match": None, "source": None, "provenance": None}
    kernel.update(project_kernel)
    return {"checks": [
        {"name": "ripgrep", "resolved_path": str(root / "bin/rg"), "sha256": _component(manifest, "ripgrep")["sha256"], "match": True, "source": "adjacent", "provenance": None},
        {"name": "tinykg", "resolved_path": str(root / "vendor/tinykg/tinykg"), "sha256": _component(manifest, "tinykg")["sha256"], "match": True, "source": "adjacent", "provenance": None},
        {"name": "formal_kernel", "resolved_path": None, "sha256": None, "expected_sha256": None, "match": None, "source": None, "provenance": None},
        kernel,
        {"name": "tinykgd", "resolved_path": None, "sha256": None, "expected_sha256": None, "match": None, "source": None, "provenance": None},
    ]}


def self_test() -> int:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory) / "bundle"
        manifest = _fixture(root)
        _write_manifest(root, manifest)
        findings = verify(root, native=False)
        if findings:
            raise SystemExit(f"self-test: the fixture bundle must verify, got {findings!r}")

        (root / "share" / "doc" / "EXTRA.md").write_bytes(b"x")
        _expect(verify(root, native=False), "file not named by the manifest: share/doc/EXTRA.md")
        (root / "share" / "doc" / "EXTRA.md").unlink()

        (root / "bin" / "rg").write_bytes(b"tampered")
        _expect(verify(root, native=False), "digest mismatch for bin/rg")
        _write(root, "bin/rg", b"rg")

        (root / "share" / "licenses" / "tinykg-LICENSE").unlink()
        _expect(verify(root, native=False), "manifest names a missing file: share/licenses/tinykg-LICENSE")
        _write(root, "share/licenses/tinykg-LICENSE", b"Apache")

        _write(root, "share/licenses/tinykg-LICENSE", b"")
        _expect(verify(root, native=False), "licence for tinykg is missing or empty")
        _write(root, "share/licenses/tinykg-LICENSE", b"Apache")
        # digest of the licence changed with its content; restore the manifest entry
        _write_manifest(root, manifest)

        broken = json.loads(json.dumps(manifest))
        broken["files"][0], broken["files"][1] = broken["files"][1], broken["files"][0]
        _write_manifest(root, broken)
        _expect(verify(root, native=False), "not sorted by path")

        broken = json.loads(json.dumps(manifest))
        broken["release"]["channel"] = "nightly"
        _write_manifest(root, broken)
        _expect(verify(root, native=False), "$.release.channel")

        broken = json.loads(json.dumps(manifest))
        broken["unexpected"] = 1
        _write_manifest(root, broken)
        _expect(verify(root, native=False), "unexpected key 'unexpected'")

        broken = json.loads(json.dumps(manifest))
        broken["components"][1]["sha256"] = "0" * 64
        _write_manifest(root, broken)
        _expect(verify(root, native=False), "component ripgrep digest disagrees")

        _write_manifest(root, manifest)
        _write(root, "share/licenses/THIRD_PARTY_NOTICES.md", b"only ripgrep here")
        _expect(verify(root, native=False), "third-party notices do not mention tinykg")
        _write(root, "share/licenses/THIRD_PARTY_NOTICES.md", b"ripgrep and TinyKG")

        # Check 4's judgement over the report shape doctor prints. The layout
        # ships no kernel, so an unpinned, unresolved kernel is the healthy case.
        evaluate_doctor_report(_doctor_report(root, manifest), root, manifest)
        _expect_bundle_error(lambda: evaluate_doctor_report(_doctor_report(root, manifest, expected_sha256="ab" * 32), root, manifest), "pins project_kernel")
        shipped = {"resolved_path": str(root / "libexec/metacodes/metacodes-project-kernel"), "sha256": "ab" * 32, "expected_sha256": "ab" * 32, "match": True, "source": "adjacent", "provenance": True}
        evaluate_doctor_report(_doctor_report(root, manifest, **shipped), root, manifest)
        _expect_bundle_error(lambda: evaluate_doctor_report(_doctor_report(root, manifest, **dict(shipped, provenance=False)), root, manifest), "rejects the project_kernel provenance sidecar")
        _expect_bundle_error(lambda: evaluate_doctor_report(_doctor_report(root, manifest, **dict(shipped, match=False)), root, manifest), "the executable pins")
        _expect_bundle_error(lambda: evaluate_doctor_report(_doctor_report(root, manifest, **dict(shipped, resolved_path="/elsewhere/metacodes-project-kernel")), root, manifest), "outside the bundle's libexec/metacodes")
        _expect_bundle_error(lambda: evaluate_doctor_report({"checks": []}, root, manifest), "no ripgrep check")
        without_kernels = _doctor_report(root, manifest)
        without_kernels["checks"] = [check for check in without_kernels["checks"] if check["name"] not in KERNEL_CHECKS]
        _expect_bundle_error(lambda: evaluate_doctor_report(without_kernels, root, manifest), "no formal_kernel check")
        pinned_daemon = _doctor_report(root, manifest)
        pinned_daemon["checks"][4]["expected_sha256"] = "ab" * 32
        _expect_bundle_error(lambda: evaluate_doctor_report(pinned_daemon, root, manifest), "pins tinykgd")
        pinned_daemon["checks"][4].update({"resolved_path": str(root / "vendor/tinykg/tinykgd"), "sha256": "ab" * 32, "match": True, "source": "adjacent"})
        evaluate_doctor_report(pinned_daemon, root, manifest)
        pinned_daemon["checks"][4]["match"] = False
        _expect_bundle_error(lambda: evaluate_doctor_report(pinned_daemon, root, manifest), "the executable pins")
    print("verify_release_bundle: self-test ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("prefix", nargs="?", type=Path, help="staged release prefix (holds manifest.json)")
    parser.add_argument("--native", action="store_true", help="also run the executables (native target only)")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.prefix is None:
        parser.error("prefix is required unless --self-test is given")
    findings = verify(args.prefix, args.native)
    for finding in findings:
        print(finding)
    if not findings:
        mode = "native" if args.native else "static"
        print(f"verify_release_bundle: ok ({mode}) {args.prefix}")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
