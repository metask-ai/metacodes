#!/usr/bin/env python3
"""Fail closed unless the maintainer-supplied TinyKG binary is attested."""

from __future__ import annotations

import os
from pathlib import Path
import sys

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))
from scripts.stage_tinykg_binary import (
    StageError,
    TinyKgContract,
    inspect_binary,
    validate_store_contract,
)


def main() -> int:
    path = os.environ.get("METACODES_TEST_TINYKG_BIN")
    sha256 = os.environ.get("METACODES_TEST_TINYKG_SHA256")
    if not path or not sha256:
        print(
            "verify-tinykg: error: set METACODES_TEST_TINYKG_BIN and "
            "METACODES_TEST_TINYKG_SHA256",
            file=os.sys.stderr,
        )
        return 2
    contract = TinyKgContract.load(PROJECT_ROOT / "deps/tinykg.json")
    try:
        identity = inspect_binary(Path(path), sha256, contract)
        validate_store_contract(identity, contract)
    except StageError as exc:
        print(f"verify-tinykg: error: {exc}", file=os.sys.stderr)
        return 1
    print(f"TinyKG attested: {identity.version_line} sha256={identity.sha256}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
