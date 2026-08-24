#!/usr/bin/env python3
"""Pinned one-package facade used as the treatment executable by paired_runner."""

from __future__ import annotations

import os
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
RUNTIME = os.environ.pop("METACODES_PLUGIN_RUNTIME_BINARY", None)
if not RUNTIME or not os.path.isabs(RUNTIME):
    raise SystemExit("METACODES_PLUGIN_RUNTIME_BINARY must name an absolute artifact")
os.execv(
    RUNTIME,
    [
        "metacodes",
        "--max-tokens",
        "8192",
        "--plugin-dir",
        str(ROOT / "evals/plugin-v1/coding-plugin"),
        *sys.argv[1:],
    ],
)
