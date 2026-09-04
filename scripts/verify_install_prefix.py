"""Verify the intentionally minimal default installation prefix (#77, B1).

`zig build` installs exactly `bin/metacodes` and the TinyKG bundle; the debug
app and the test harness binaries come from `zig build dev` and
`zig build test:harness`. `ALLOWED_ENTRIES` is the seed of the stage-5
`release:check` whitelist. `--doctor` additionally runs the installed
`bin/metacodes doctor --json` from a neutral directory with no environment
override and requires the TinyKG check to resolve to the adjacent vendored
binary with a matching digest (#78). Python 3.9, stdlib only.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ALLOWED_ENTRIES = frozenset(("bin", "bin/metacodes", "bin/metacodes.exe", "vendor", "vendor/tinykg", "vendor/tinykg/tinykg", "vendor/tinykg/tinykg.exe", "vendor/tinykg/tinykg.provenance.json"))


def check(prefix: Path) -> list[str]:
    actual = set()
    if prefix.exists():
        for path in prefix.rglob("*"):
            actual.add(path.relative_to(prefix).as_posix())
    expected = set(ALLOWED_ENTRIES)
    if any(p.endswith(".exe") for p in actual if p.startswith("bin/")):
        expected.remove("bin/metacodes")
    else:
        expected.remove("bin/metacodes.exe")
    if any(p.endswith(".exe") for p in actual if p.startswith("vendor/tinykg/")):
        expected.remove("vendor/tinykg/tinykg")
    else:
        expected.remove("vendor/tinykg/tinykg.exe")
    findings = ["missing: " + entry for entry in sorted(expected - actual)]
    findings.extend("unexpected: " + entry for entry in sorted(actual - expected))
    return findings


def evaluate_doctor(report: object, prefix: Path) -> list[str]:
    """Findings for a `metacodes doctor --json` document produced from `prefix`
    with no environment override: TinyKG must be the adjacent vendored binary
    and match the digest the build pinned; a ripgrep check must exist (its
    source is not constrained until the release layout stages the binary)."""
    checks = report.get("checks") if isinstance(report, dict) else None
    if not isinstance(checks, list):
        return ["doctor: report has no checks array"]
    by_name = {check.get("name"): check for check in checks if isinstance(check, dict)}
    findings: list[str] = []
    if "ripgrep" not in by_name:
        findings.append("doctor: no ripgrep check")
    tinykg = by_name.get("tinykg")
    if tinykg is None:
        findings.append("doctor: no tinykg check")
        return findings
    resolved = tinykg.get("resolved_path")
    vendored_dir = (prefix / "vendor" / "tinykg").resolve()
    if not isinstance(resolved, str) or Path(resolved).resolve().parent != vendored_dir:
        findings.append(f"doctor: tinykg resolved to {resolved!r}, not under {vendored_dir}")
    if tinykg.get("source") != "adjacent":
        findings.append(f"doctor: tinykg source is {tinykg.get('source')!r}, expected 'adjacent'")
    if tinykg.get("match") is not True:
        findings.append(f"doctor: tinykg match is {tinykg.get('match')!r}, expected true")
    return findings


def run_doctor(prefix: Path) -> list[str]:
    """Run the installed executable's doctor and evaluate its report."""
    exe = prefix / "bin" / ("metacodes.exe" if os.name == "nt" else "metacodes")
    env = {key: value for key, value in os.environ.items() if key not in ("METACODES_KG_BIN", "RG_BIN")}
    with tempfile.TemporaryDirectory() as neutral_cwd:
        completed = subprocess.run(
            [str(exe), "doctor", "--json"],
            cwd=neutral_cwd,
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=120,
        )
    if completed.returncode != 0:
        return [f"doctor: exited {completed.returncode}: {completed.stderr.strip()[:200]}"]
    try:
        report = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return [f"doctor: stdout is not JSON: {completed.stdout[:200]!r}"]
    return evaluate_doctor(report, prefix)


def main(argv: list[str]) -> int:
    positional = [argument for argument in argv[1:] if argument != "--doctor"]
    doctor = len(positional) != len(argv) - 1
    if len(positional) != 1:
        print("usage: verify_install_prefix.py <prefix> [--doctor]", file=sys.stderr)
        return 2
    prefix = Path(positional[0])
    findings = check(prefix)
    if doctor and not findings:
        findings.extend(run_doctor(prefix))
    for finding in findings:
        print(finding)
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
