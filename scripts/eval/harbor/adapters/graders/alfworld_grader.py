"""ALFWorld verifier: reward from the environment's own record, never the agent's.

Runs in the separate verifier container. Its only input besides spec.json is
/var/lib/alfworld/result.json, which the alfworld-env sidecar writes after
every action and Harbor collects from that sidecar (not from the agent's
container) after the collect hook froze the episode. Python 3.9+, stdlib.

Reward 1 iff the record is for this task's game (task id and game SHA-256
match spec.json), it was frozen by the collect hook, the trajectory is
consistent with the step count, and the environment's `won` flag became true
on the last recorded action, within the step budget. Anything else, including
a missing or malformed record, is 0.

Usage:
  alfworld_grader.py --spec spec.json --result result.json --reward reward.txt [--details grade.json]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple


def check(spec: Dict[str, object], record: Dict[str, object]) -> Tuple[bool, str]:
    if record.get("schema") != 1:
        return False, "unknown record schema"
    if record.get("task_id") != spec["task_id"] or record.get("game_sha256") != spec["game_sha256"]:
        return False, "the record is for a different game"
    if record.get("max_steps") != spec["max_steps"]:
        return False, "the record has a different step budget"
    if record.get("finalized") is not True:
        return False, "the episode was not frozen by the collect hook"
    trajectory = record.get("trajectory")
    if not isinstance(trajectory, list) or record.get("steps") != len(trajectory):
        return False, "the trajectory does not match the step count"
    if len(trajectory) > int(spec["max_steps"]):  # type: ignore[arg-type]
        return False, "more actions than the budget"
    won_at = [index for index, step in enumerate(trajectory) if isinstance(step, dict) and step.get("won") is True]
    if record.get("won") is not True or not won_at:
        return False, "the environment did not report the task complete"
    if won_at[0] != len(trajectory) - 1:
        return False, "actions were recorded after the task completed"
    return True, "the environment reported the task complete after %d actions" % len(trajectory)


def grade(spec_path: Path, result_path: Path) -> Tuple[int, Dict[str, object]]:
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    try:
        record = json.loads(result_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 0, {"error": "no environment record was collected"}
    if not isinstance(record, dict):
        return 0, {"error": "malformed environment record"}
    ok, reason = check(spec, record)
    return (1 if ok else 0), {
        "reason": reason,
        "won": record.get("won"),
        "steps": record.get("steps"),
        "oracle_used": record.get("oracle_used"),
    }


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--reward", type=Path, required=True)
    parser.add_argument("--details", type=Path)
    args = parser.parse_args(argv)
    reward, details = grade(args.spec, args.result)
    args.reward.parent.mkdir(parents=True, exist_ok=True)
    args.reward.write_text("%d\n" % reward, encoding="utf-8")
    if args.details:
        args.details.write_text(json.dumps(details, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    print("reward=%d" % reward)
    return 0


if __name__ == "__main__":
    sys.exit(main())
