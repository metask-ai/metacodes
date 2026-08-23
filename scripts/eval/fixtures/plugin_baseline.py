#!/usr/bin/env python3
"""Pinned no-plugin facade used as the baseline executable by paired_runner."""

from __future__ import annotations

import os
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
os.execv(
    str(ROOT / "zig-out/bin/metacodes"),
    ["metacodes", "--max-tokens", "8192", *sys.argv[1:]],
)
