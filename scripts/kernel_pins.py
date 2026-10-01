"""Print the `zig build` options that pin the Lean kernels staged in a prefix.

A release executable pins the digest of every kernel it ships
(doc/INSTALL_DESIGN.md §2), but the digest only exists once the kernel is
built, so a release build is two invocations:

    zig build kernels:stage --prefix <dir>
    zig build release:verify -Drelease-layout=true --prefix <dir> $(python3 scripts/kernel_pins.py <dir>)

This hashes `<dir>/libexec/metacodes/metacodes-{formal,project}-kernel[.exe]`
and refuses to print anything when a kernel is missing or disagrees with the
`binary_sha256` of the provenance sidecar its build script wrote beside it.

Python 3.9, stdlib only.
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

KERNELS = (
    ("formal-kernel-sha256", "metacodes-formal-kernel"),
    ("project-kernel-sha256", "metacodes-project-kernel"),
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def kernel_path(prefix: Path, stem: str) -> Path:
    base = prefix / "libexec" / "metacodes"
    exe = base / (stem + ".exe")
    return exe if exe.is_file() else base / stem


def pins(prefix: Path) -> list[str]:
    """`-D<option>=<sha256>` for each kernel; raises ValueError on any doubt."""
    options = []
    for option, stem in KERNELS:
        binary = kernel_path(prefix, stem)
        if not binary.is_file():
            raise ValueError(f"{binary} is missing: run `zig build kernels:stage --prefix {prefix}` first")
        sidecar = binary.with_name(binary.name + ".provenance.json")
        try:
            recorded = json.loads(sidecar.read_text(encoding="utf-8")).get("binary_sha256")
        except (OSError, ValueError) as error:
            raise ValueError(f"{sidecar}: unreadable provenance sidecar ({error})") from error
        actual = _sha256(binary)
        if recorded != actual:
            raise ValueError(f"{binary}: digest {actual} differs from its sidecar's binary_sha256 {recorded!r}")
        options.append(f"-D{option}={actual}")
    return options


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: kernel_pins.py <prefix>", file=sys.stderr)
        return 2
    try:
        print(" ".join(pins(Path(argv[1]))))
    except ValueError as error:
        print(f"kernel_pins: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
