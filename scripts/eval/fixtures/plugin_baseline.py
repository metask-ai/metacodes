#!/usr/bin/env python3
"""Pinned no-plugin facade used as the baseline executable by paired_runner."""

from __future__ import annotations

import os
import sys


RUNTIME = os.environ.pop("METACODES_PLUGIN_RUNTIME_BINARY", None)
if not RUNTIME or not os.path.isabs(RUNTIME):
    raise SystemExit("METACODES_PLUGIN_RUNTIME_BINARY must name an absolute artifact")
os.execv(
    RUNTIME,
    ["metacodes", "--max-tokens", "8192", *sys.argv[1:]],
)
