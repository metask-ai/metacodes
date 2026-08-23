#!/usr/bin/env python3
"""Pinned one-package facade used as the treatment executable by paired_runner."""

from __future__ import annotations

import os
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
os.execv(
    str(ROOT / "zig-out/bin/metacodes"),
    [
        "metacodes",
        "--max-tokens",
        "8192",
        "--plugin-dir",
        str(ROOT / "evals/plugin-v1/coding-plugin"),
        *sys.argv[1:],
    ],
)
