"""Published results of other agents and models on the suites the workbench runs.

`leaderboards.json` holds one board per published source: the suites whose
tasks it scored, where and when it was read, what its score means, and its
entries (score in percent). The workbench places its own jobs among them.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import List

DATA = Path(__file__).with_name("leaderboards.json")


def boards() -> List[dict]:
    return json.loads(DATA.read_text(encoding="utf-8"))["boards"]
