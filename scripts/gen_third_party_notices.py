"""Render ``THIRD_PARTY_NOTICES.md`` from the dependency manifests (#47).

The notices table used to be typed by hand, so a manifest bump (a new ripgrep
release, a TinyKG commit, a re-vendored highlight-zig, a Lean toolchain) could
leave it stale with no gate noticing. It is now rendered from the manifests
plus ``release/notices.static.md`` -- the prose nothing derives -- and
``--check`` fails with a diff when the committed file differs from what the
inputs say. ``release/doc_facts.json`` asserts the ripgrep and TinyKG versions
in the rendered rows, so their shape is part of the contract.

Python 3.9 (the repository floor, ``scripts/tests/test_python_floor.py``).
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import sys
from pathlib import Path

#: Everything the generator reads, relative to the repository root. Tests copy
#: exactly these files into a temporary tree.
INPUT_FILES = (
    "vendor/ripgrep/manifest.json",
    "vendor/tinykg/manifest.json",
    "deps/tinykg.json",
    "lib/highlight-zig/SOURCE.txt",
    "control-plane/lean/lean-toolchain",
    "release/notices.static.md",
)

OUTPUT_FILE = "THIRD_PARTY_NOTICES.md"

#: The static fragment carries this line once, where the table goes.
TABLE_MARKER = "<!-- table: rendered by scripts/gen_third_party_notices.py from the manifests -->"

TABLE_HEADER = (
    "| Component | Form | Source | License handling |\n"
    "|---|---|---|---|\n"
)

#: Not derivable from any manifest: the Zig toolchain has no in-tree pin.
ZIG_ROW = "| Zig standard library/toolchain | build toolchain | ziglang.org | governed by Zig distribution terms |"

_LEAN_TOOLCHAIN = re.compile(r"^leanprover/lean4:v(\d+\.\d+\.\d+)\s*$")
_SOURCE_LINE = re.compile(r"^(?P<key>[a-z ]+):\s*(?P<value>\S.*?)\s*$")


class NoticesError(Exception):
    """An input is missing or malformed; nothing is written."""


def _read(root: Path, relative: str) -> str:
    path = root / relative
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise NoticesError(f"cannot read {relative}: {error}") from error


def _json(root: Path, relative: str, *keys: str) -> dict:
    try:
        value = json.loads(_read(root, relative))
    except ValueError as error:
        raise NoticesError(f"{relative} is not JSON: {error}") from error
    for key in keys:
        if not isinstance(value.get(key), str) or not value[key]:
            raise NoticesError(f"{relative} lacks a string {key!r}")
    return value


def _source_txt(root: Path) -> dict:
    """``lib/highlight-zig/SOURCE.txt`` is ``key: value`` lines."""
    fields = {}
    for line in _read(root, INPUT_FILES[3]).splitlines():
        match = _SOURCE_LINE.match(line)
        if match:
            fields[match.group("key")] = match.group("value")
    for key in ("vendored from", "commit"):
        if key not in fields:
            raise NoticesError(f"{INPUT_FILES[3]} lacks a {key!r} line")
    return fields


def lean_version(root: Path) -> str:
    text = _read(root, INPUT_FILES[4]).strip()
    match = _LEAN_TOOLCHAIN.match(text)
    if not match:
        raise NoticesError(f"{INPUT_FILES[4]} is not 'leanprover/lean4:vX.Y.Z': {text!r}")
    return match.group(1)


def rows(root: Path) -> list:
    ripgrep = _json(root, INPUT_FILES[0], "upstream_release", "upstream_revision", "license", "source_repository")
    tinykg_bundle = _json(root, INPUT_FILES[1], "source_commit")
    tinykg = _json(root, INPUT_FILES[2], "tinykg_version", "license", "source_repository")
    highlight = _source_txt(root)
    lean = lean_version(root)
    return [
        "| highlight-zig | checked-in Zig source snapshot | `lib/highlight-zig/SOURCE.txt` "
        f"({highlight['vendored from']}, commit `{highlight['commit'][:12]}`) | retain its bundled license |",
        f"| ripgrep {ripgrep['upstream_release']} | checked-in target-specific upstream release binaries, "
        "redistributed as the AgentCore bundle `bin/rg[.exe]` runtime asset | `vendor/ripgrep/manifest.json` "
        f"({ripgrep['source_repository']}, revision `{ripgrep['upstream_revision']}`) | {ripgrep['license']}; "
        "MIT text retained at `vendor/ripgrep/LICENSE-MIT` and shipped with the bundle notice |",
        f"| TinyKG {tinykg['tinykg_version']} | checked-in target-specific CLI binaries | `vendor/tinykg/manifest.json` "
        f"({tinykg['source_repository']}, source commit `{tinykg_bundle['source_commit'][:12]}`) | {tinykg['license']}; "
        "license retained at `vendor/tinykg/LICENSE` |",
        ZIG_ROW,
        f"| Lean 4 toolchain (leanprover/lean4:v{lean}) | build toolchain for the release/formal gates; its runtime is "
        "statically linked into locally built formal-kernel binaries (not checked in) | "
        "`control-plane/lean/lean-toolchain` | Apache-2.0; review before distributing any built kernel binary |",
    ]


def generate(root: Path) -> str:
    """The notices file as the inputs under ``root`` say it should read."""
    static = _read(root, INPUT_FILES[5])
    if static.count(TABLE_MARKER + "\n") != 1:
        raise NoticesError(f"{INPUT_FILES[5]} must carry the table marker exactly once")
    table = TABLE_HEADER + "\n".join(rows(root)) + "\n"
    return static.replace(TABLE_MARKER + "\n", table)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--check", action="store_true", help="exit 1 with a diff when the committed file is stale")
    args = parser.parse_args(argv)
    target = args.root / OUTPUT_FILE
    try:
        rendered = generate(args.root)
    except NoticesError as error:
        print(f"gen_third_party_notices: {error}", file=sys.stderr)
        return 2
    if args.check:
        committed = target.read_text(encoding="utf-8") if target.exists() else ""
        if committed == rendered:
            return 0
        sys.stderr.write(
            "".join(
                difflib.unified_diff(
                    committed.splitlines(True),
                    rendered.splitlines(True),
                    fromfile=OUTPUT_FILE,
                    tofile="generated from the manifests",
                )
            )
        )
        print(f"{OUTPUT_FILE} is stale; run: python scripts/gen_third_party_notices.py", file=sys.stderr)
        return 1
    # LF on every host: the file is part of the release review, not a text-mode artefact.
    with open(target, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
