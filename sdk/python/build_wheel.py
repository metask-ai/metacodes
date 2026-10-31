#!/usr/bin/env python3
"""Build a platform wheel of the `metacodes` Python package from an AgentCore bundle.

    zig build agentcore:bundle -Dtarget=<target> -Doptimize=ReleaseSafe
    python3 sdk/python/build_wheel.py --bundle zig-out/agentcore/<resolved-target> --out dist/

The wheel carries the package sources plus, under ``metacodes/_lib/``, the
bundle's shared library, its ripgrep and their licenses. It is built with the
standard library only (no setuptools/wheel), deterministically: fixed
timestamps, sorted entries, so the same inputs give the same bytes.

The package sources and metadata come from this checkout and the library from
the bundle, so the build refuses unless both are one AgentCore release
(`agentcore_release.verify_package_inputs`). The wheel takes its version from the
bundle's manifest, and `--release` also refuses a development bundle.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import re
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
PACKAGE = "metacodes"
EPOCH = (2026, 1, 1, 0, 0, 0)

sys.path.insert(0, str(REPO / "scripts"))
import agentcore_contract  # noqa: E402  (repository tooling; the wheel does not ship it)
import agentcore_release  # noqa: E402

SUMMARY = "Embed the metacodes agent runtime (AgentCore C ABI) in Python"


def python_version(sdk_version: str) -> str:
    """sdk/VERSION 0.11.0-dev -> PEP 440 0.11.0.dev0."""
    match = re.fullmatch(r"(\d+\.\d+\.\d+)(?:-dev)?", sdk_version.strip())
    if not match:
        raise SystemExit("unsupported sdk/VERSION: %r" % sdk_version)
    return match.group(1) + (".dev0" if sdk_version.strip().endswith("-dev") else "")


def platform_tag(target: dict) -> str:
    """Wheel platform tag for a bundle manifest `target` object."""
    arch, os_name, abi = target["architecture"], target["os"], target["abi"]
    zig_target = target.get("zig_target", "")
    if os_name == "macos":
        found = re.search(r"macos\.(\d+)\.(\d+)", zig_target)
        major, minor = (found.group(1), found.group(2)) if found else ("13", "0")
        return "macosx_%s_%s_%s" % (major, minor, {"aarch64": "arm64"}.get(arch, arch))
    if os_name == "linux":
        if abi.startswith("musl"):
            return "musllinux_1_2_%s" % arch
        found = re.search(r"gnu\.(\d+)\.(\d+)", zig_target)
        major, minor = (found.group(1), found.group(2)) if found else ("2", "28")
        return "manylinux_%s_%s_%s" % (major, minor, arch)
    if os_name == "windows" and arch == "x86_64":
        return "win_amd64"
    if os_name == "windows" and arch == "aarch64":
        return "win_arm64"
    raise SystemExit("no wheel platform tag for target %r" % target)


def record_hash(data: bytes) -> str:
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=")
    return "sha256=" + digest.decode("ascii")


def build(bundle: Path, out_dir: Path, tag_override: str = "", formal: bool = False, root: Path = REPO) -> Path:
    try:
        manifest = agentcore_release.verify_package_inputs(bundle, root, formal)
    except ValueError as error:
        raise SystemExit("cannot package %s: %s" % (bundle, error))
    library = bundle / manifest["shared_library"]["path"]
    base, development = agentcore_contract.base_of_built(manifest["version"])
    version = python_version(base + ("-dev" if development else ""))
    tag = tag_override or platform_tag(manifest["target"])
    source = root / "sdk" / "python" / "src" / PACKAGE

    files = {}
    for path in sorted(source.rglob("*.py")):
        files["%s/%s" % (PACKAGE, path.relative_to(source).as_posix())] = (path.read_bytes(), 0o644)
    files["%s/_lib/%s" % (PACKAGE, library.name)] = (library.read_bytes(), 0o755)
    for asset in sorted((bundle / "bin").glob("*")):
        if asset.is_file():
            mode = 0o755 if asset.name in ("rg", "rg.exe") else 0o644
            files["%s/_lib/%s" % (PACKAGE, asset.name)] = (asset.read_bytes(), mode)

    dist_info = "%s-%s.dist-info" % (PACKAGE, version)
    files["%s/licenses/LICENSE" % dist_info] = ((root / "LICENSE").read_bytes(), 0o644)
    readme = (root / "sdk" / "python" / "README.md").read_text(encoding="utf-8")
    metadata = "\n".join(
        [
            "Metadata-Version: 2.1",
            "Name: %s" % PACKAGE,
            "Version: %s" % version,
            "Summary: %s" % SUMMARY,
            "Home-page: https://github.com/metask-ai/metacodes",
            "Author: Metask Lab",
            "License: MIT",
            "Requires-Python: >=3.9",
            "Classifier: License :: OSI Approved :: MIT License",
            "Classifier: Programming Language :: Python :: 3",
            "Classifier: Topic :: Software Development :: Libraries",
            "Description-Content-Type: text/markdown",
            "",
            readme,
        ]
    )
    files["%s/METADATA" % dist_info] = (metadata.encode("utf-8"), 0o644)
    wheel = "Wheel-Version: 1.0\nGenerator: metacodes build_wheel.py\nRoot-Is-Purelib: false\nTag: py3-none-%s\n" % tag
    files["%s/WHEEL" % dist_info] = (wheel.encode("utf-8"), 0o644)
    record_name = "%s/RECORD" % dist_info
    record_lines = ["%s,%s,%d" % (name, record_hash(data), len(data)) for name, (data, _) in sorted(files.items())]
    record_lines.append("%s,," % record_name)
    files[record_name] = (("\n".join(record_lines) + "\n").encode("utf-8"), 0o644)

    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / ("%s-%s-py3-none-%s.whl" % (PACKAGE, version, tag))
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(files, key=lambda item: (item.startswith(dist_info), item)):
            data, mode = files[name]
            info = zipfile.ZipInfo(name, date_time=EPOCH)
            info.external_attr = (0o100000 | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
    return target


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--bundle", required=True, type=Path, help="AgentCore bundle directory (holds manifest.json)")
    parser.add_argument("--out", required=True, type=Path, help="output directory for the wheel")
    parser.add_argument("--platform-tag", default="", help="override the wheel platform tag")
    parser.add_argument("--release", action="store_true", help="formal release: refuse a development bundle")
    args = parser.parse_args(argv)
    print(build(args.bundle.resolve(), args.out, args.platform_tag, args.release))
    return 0


if __name__ == "__main__":
    sys.exit(main())
