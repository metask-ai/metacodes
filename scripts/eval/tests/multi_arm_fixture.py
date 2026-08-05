"""Test-only builders for complete, execution-grounded multi-arm checkpoints."""

from __future__ import annotations

import copy
import hashlib
from pathlib import Path
from typing import Any, Dict

from scripts.eval.e2e_adapter import grounding_fingerprints
from scripts.eval.experiment import ARM_IDS, arm_config_ids
from scripts.eval.model import stable_json, write_rollouts
from scripts.eval.tests.test_analysis import rollout


def write_multi_arm_checkpoints(
    directory: Path,
    experiment: Dict[str, Any],
    suite: Dict[str, Any],
    repo_root: Path,
    *,
    metacodes_sha256: str,
    tinykg_sha256: str,
    formal_kernel_fingerprint: str,
    revision: str,
) -> Dict[str, Path]:
    directory.mkdir(parents=True, exist_ok=True)
    config_ids = arm_config_ids(
        experiment,
        suite,
        metacodes_sha256,
        tinykg_sha256,
        formal_kernel_fingerprint,
    )
    model = experiment["model"]
    model_fingerprint = hashlib.sha256(
        stable_json(model).encode("utf-8")
    ).hexdigest()[:16]
    paths: Dict[str, Path] = {}
    for arm_id in ARM_IDS:
        rows = []
        for trial in range(experiment["trials"]):
            for task in suite["tasks"]:
                identity = grounding_fingerprints(task, repo_root)
                item = copy.deepcopy(rollout(task["id"], True, config_ids[arm_id]))
                item["run_id"] = f"{arm_id}:{task['id']}:{trial}"
                item["suite_id"] = suite["suite_id"]
                item["task_fingerprint"] = identity["task_fingerprint"]
                item["trial"] = trial
                item["layers"] = task["layers"]
                item["model"] = {**model, "fingerprint": model_fingerprint}
                item["harness"].update(
                    {
                        "config_id": config_ids[arm_id],
                        "revision": revision,
                        "fingerprint": f"{arm_id}:{task['id']}",
                        "environment_fingerprint": identity[
                            "environment_fingerprint"
                        ],
                        "permission_mode": identity["permission_mode"],
                    }
                )
                item["evaluator"]["fingerprint"] = identity["grader_fingerprint"]
                rows.append(item)
        path = directory / f"{arm_id}.jsonl"
        write_rollouts(path, rows)
        paths[arm_id] = path
    return paths
