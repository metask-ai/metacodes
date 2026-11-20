#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import sysconfig
from typing import Dict, List, Optional, Sequence, Set

ROOT = Path(__file__).resolve().parents[1]

EXCLUDED_PREFIXES = ("tests/fixtures/", "tests/e2e/fixtures/")
SHELL_SEVERITY = "warning"
SHA256_HEX = re.compile(rb"\b[0-9a-f]{64}\b")
SHELL_SHEBANG = re.compile(rb"^#!\s*(?:/usr/bin/env\s+)?(?:/\S*/)?(?:ba)?sh\b")

TOOLS = {
    "ruff": ("ruff", ["--version"], re.compile(r"\bruff (\S+)")),
    "shellcheck-py": ("shellcheck", ["--version"], re.compile(r"^version: (\S+)", re.M)),
    "actionlint-py": ("actionlint", ["--version"], re.compile(r"^(\d+\.\d+\.\d+)", re.M)),
}


class LintSetupError(Exception):
    pass


def pinned_versions(requirements: Path) -> Dict[str, str]:
    pins = {}
    for line in requirements.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^\s*([A-Za-z0-9_.-]+)==(\S+)", line)
        if match:
            pins[match.group(1).lower()] = match.group(2)
    missing = sorted(set(TOOLS) - set(pins))
    if missing:
        raise LintSetupError("%s pins no version of %s" % (requirements, ", ".join(missing)))
    return pins


def search_path() -> str:
    dirs = [sysconfig.get_path("scripts")]
    try:
        dirs.append(sysconfig.get_path("scripts", "%s_user" % os.name))
    except KeyError:
        pass
    dirs.append(os.environ.get("PATH", ""))
    return os.pathsep.join(d for d in dirs if d)


def resolve_tool(package: str, pin: str) -> str:
    executable, version_args, pattern = TOOLS[package]
    path = shutil.which(executable, path=search_path())
    hint = "install it with: python3 -m pip install -r requirements-lint.txt"
    if path is None:
        raise LintSetupError("%s (from %s==%s) is not installed; %s" % (executable, package, pin, hint))
    output = subprocess.run([path, *version_args], capture_output=True, text=True, check=False).stdout
    match = pattern.search(output)
    found = match.group(1) if match else "unknown"
    if not (pin == found or pin.startswith(found + ".")):
        raise LintSetupError("%s is version %s at %s, but requirements-lint.txt pins %s==%s; %s"
                             % (executable, found, path, package, pin, hint))
    return path


def tracked_files(root: Path) -> List[str]:
    listing = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True).stdout
    return [name for name in listing.decode("utf-8").split("\0") if name and not name.startswith(EXCLUDED_PREFIXES)]


def is_shell_script(root: Path, name: str) -> bool:
    if name.endswith(".sh"):
        return True
    if "." in Path(name).name:
        return False
    path = root / name
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as handle:
        return bool(SHELL_SHEBANG.match(handle.readline()))


def pinned_digests(root: Path, files: Sequence[str]) -> Set[bytes]:
    digests = set()
    for name in files:
        if name.endswith(".json") and (root / name).is_file():
            digests.update(SHA256_HEX.findall((root / name).read_bytes()))
    return digests


def pinned_files(root: Path, files: Sequence[str], lintable: Sequence[str]) -> List[str]:
    digests = pinned_digests(root, files)
    pinned = []
    for name in lintable:
        path = root / name
        if path.is_symlink() or not path.is_file():
            continue
        data = path.read_bytes()
        if data and hashlib.sha256(data).hexdigest().encode() in digests:
            pinned.append(name)
    return pinned


def run(label: str, argv: Sequence[str], root: Path, env: Optional[Dict[str, str]] = None) -> bool:
    print("==> %s" % label, flush=True)
    result = subprocess.run(list(argv), cwd=root, env=env, check=False)
    if result.returncode != 0:
        print("%s failed (exit %d)" % (label, result.returncode), flush=True)
    return result.returncode == 0


def lint(root: Path, requirements: Path) -> int:
    pins = pinned_versions(requirements)
    tools = {package: resolve_tool(package, pin) for package, pin in pins.items() if package in TOOLS}
    files = tracked_files(root)
    python_files = [name for name in files if name.endswith(".py")]
    shell_scripts = [name for name in files if is_shell_script(root, name)]
    pinned = pinned_files(root, files, python_files + shell_scripts)
    if pinned:
        print("skipped %d files whose SHA-256 a tracked JSON document pins:" % len(pinned))
        for name in pinned:
            print("  %s" % name)
    shell_scripts = [name for name in shell_scripts if name not in pinned]
    excludes = [arg for name in pinned if name.endswith(".py") for arg in ("--extend-exclude", name)]
    ok = run("ruff", [tools["ruff"], "check", "--no-cache", *excludes, "."], root)
    if shell_scripts:
        ok = run("shellcheck", [tools["shellcheck-py"], "--external-sources", "--source-path=SCRIPTDIR",
                                "--severity=%s" % SHELL_SEVERITY, *shell_scripts], root) and ok
    workflows = [name for name in files if re.match(r"^\.github/workflows/[^/]+\.ya?ml$", name)]
    if workflows:
        env = dict(os.environ, SHELLCHECK_OPTS="--severity=%s" % SHELL_SEVERITY)
        ok = run("actionlint", [tools["actionlint-py"], "-shellcheck", tools["shellcheck-py"], "-pyflakes", "",
                                *workflows], root, env) and ok
    return 0 if ok else 1


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Lint Python, shell scripts and GitHub Actions workflows.")
    parser.add_argument("--root", type=Path, default=ROOT, help="checkout to lint (default: this repository)")
    parser.add_argument("--requirements", type=Path, default=ROOT / "requirements-lint.txt",
                        help="file that pins the lint tools")
    args = parser.parse_args(argv)
    try:
        return lint(args.root.resolve(), args.requirements)
    except LintSetupError as error:
        print("lint: %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
