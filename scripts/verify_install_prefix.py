"""Verify the intentionally minimal default installation prefix (#77, B1).

`zig build` installs exactly `bin/metacodes` and the TinyKG bundle; the debug
app and the test harness binaries come from `zig build dev` and
`zig build test:harness`. `ALLOWED_ENTRIES` is the seed of the stage-5
`release:check` whitelist. Python 3.9, stdlib only.
"""
from __future__ import annotations

import sys
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


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: verify_install_prefix.py <prefix>", file=sys.stderr)
        return 2
    findings = check(Path(argv[1]))
    for finding in findings:
        print(finding)
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
