"""Run the built executable's `doctor` against real Lean kernel artifacts and
require that each kernel's provenance sidecar is accepted by the loader that
owns it.

`zig build test` proves both loaders against hand-written manifests; this
script closes the other half of the contract: the sidecar that
`scripts/build-formal-kernel.sh` / `scripts/build-project-harness-kernel.sh`
actually writes must be the document the product reads. The two halves drifted
once — the project kernel's v6 sidecar was validated with the formal kernel's
v4 loader, so `doctor --strict` failed on every pinned project kernel
(2026-09-21) — and no CI step ran a real sidecar through doctor.

The executable need not pin the kernels: each kernel is handed to doctor
through its environment pair (`METACODES_<KIND>_KERNEL_PATH` plus `_SHA256`,
the digest computed here), which resolves it with `source=env`, holds the file
to the pair's digest (`expected_sha256` / `match`) and validates the sidecar
exactly as an adjacent, pinned kernel would be. Python 3.9, stdlib only.

usage: verify_kernel_provenance.py <metacodes-exe> [--formal <kernel>] [--project <kernel>]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

# kind -> (doctor check name, path variable, digest variable)
KINDS = {
    "formal": ("formal_kernel", "METACODES_FORMAL_KERNEL_PATH", "METACODES_FORMAL_KERNEL_SHA256"),
    "project": ("project_kernel", "METACODES_PROJECT_KERNEL_PATH", "METACODES_PROJECT_KERNEL_SHA256"),
}
KERNEL_ENV = tuple(variable for _, path_var, sha_var in KINDS.values() for variable in (path_var, sha_var))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def evaluate(report: object, kernels: dict[str, tuple[Path, str]]) -> list[str]:
    """Findings for a `doctor --json` document run with `kernels` (kind ->
    (absolute path, sha256)) in the environment: each named kernel must have
    resolved from the environment at that path, be held to that digest and
    match it, and its sidecar must have been accepted (`provenance: true`)."""
    checks = report.get("checks") if isinstance(report, dict) else None
    if not isinstance(checks, list):
        return ["doctor: report has no checks array"]
    by_name = {check.get("name"): check for check in checks if isinstance(check, dict)}
    findings: list[str] = []
    for kind, (path, digest) in kernels.items():
        name = KINDS[kind][0]
        check = by_name.get(name)
        if check is None:
            findings.append(f"{name}: doctor reports no such check")
            continue
        resolved = check.get("resolved_path")
        if not isinstance(resolved, str) or Path(resolved).resolve() != path.resolve():
            findings.append(f"{name}: resolved to {resolved!r}, expected {path}")
        if check.get("source") != "env":
            findings.append(f"{name}: source is {check.get('source')!r}, expected 'env'")
        if check.get("sha256") != digest:
            findings.append(f"{name}: doctor hashed {check.get('sha256')!r}, the file is {digest}")
        if check.get("expected_sha256") != digest or check.get("match") is not True:
            findings.append(f"{name}: doctor holds the file to {check.get('expected_sha256')!r} with match={check.get('match')!r}, expected the pair's digest and true")
        if check.get("provenance") is not True:
            findings.append(
                f"{name}: provenance is {check.get('provenance')!r}, expected true "
                f"({path}.provenance.json was rejected by the {name} loader)"
            )
    return findings


def run(executable: Path, kernels: dict[str, tuple[Path, str]]) -> list[str]:
    env = {key: value for key, value in os.environ.items() if key not in KERNEL_ENV}
    for kind, (path, digest) in kernels.items():
        _, path_var, sha_var = KINDS[kind]
        env[path_var] = str(path.resolve())
        env[sha_var] = digest
    with tempfile.TemporaryDirectory() as neutral_cwd:
        completed = subprocess.run(
            [str(executable), "doctor", "--json"],
            cwd=neutral_cwd,
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=120,
        )
    if completed.returncode != 0:
        return [f"doctor exited {completed.returncode}: {completed.stderr.strip()[:200]}"]
    try:
        report = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return [f"doctor stdout is not JSON: {completed.stdout[:200]!r}"]
    return evaluate(report, kernels)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("executable", type=Path, help="the built bin/metacodes")
    parser.add_argument("--formal", type=Path, help="the formal kernel binary (its .provenance.json and .build-receipt.json sit beside it)")
    parser.add_argument("--project", type=Path, help="the project kernel binary (its .provenance.json sits beside it)")
    args = parser.parse_args(argv[1:])
    if not args.executable.is_file():
        print(f"{args.executable} is not a file", file=sys.stderr)
        return 2
    # doctor runs from a neutral directory, so the path must survive the chdir.
    executable = args.executable.resolve()
    kernels: dict[str, tuple[Path, str]] = {}
    for kind in KINDS:
        path = getattr(args, kind)
        if path is None:
            continue
        if not path.is_file():
            print(f"{KINDS[kind][0]}: {path} is not a file", file=sys.stderr)
            return 2
        kernels[kind] = (path.resolve(), sha256_file(path))
    if not kernels:
        parser.error("name at least one kernel (--formal / --project)")
    findings = run(executable, kernels)
    for finding in findings:
        print(finding)
    if not findings:
        for kind, (path, digest) in kernels.items():
            print(f"{KINDS[kind][0]} {path} sha256={digest} provenance=true")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
