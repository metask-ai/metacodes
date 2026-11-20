import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from scripts.eval.skill_rsi import (
    CommandAdapter, RSIError, Settings, candidate, digest, features, fit_router,
    main, route, run_rsi, stable, strict_json,
)
from scripts.eval.memory_budget_journal import BudgetAuthority, BudgetJournal


def manifest():
    return {
        "model": "test-model", "seed_instruction": "seed skill",
        "train": [{"id": f"t{i}", "unit_id": f"u{i}", "prompt": f"count {i} items"} for i in range(6)],
        "validation": [{"id": f"v{i}", "unit_id": f"vu{i}", "prompt": f"count {i} items"} for i in range(2)],
    }


class FixtureAdapter:
    def __init__(self):
        self.requests = []

    def __call__(self, request):
        self.requests.append(copy.deepcopy(request))
        response = {"model": request["model"], "input_tokens": 10, "output_tokens": 5, "cost_microusd": 0}
        if request["kind"] == "propose":
            round_index = request["iteration"]
            response.update(instruction=f"evolved skill {round_index}", supporting_task_ids=["t0", "t1"])
        else:
            text = request["instruction"]
            score = 1.0 if "skill 1" in text else 0.5 if text else 0.0
            response.update(score=score, feedback="host-scored fixture")
        return response


class SkillRSITest(unittest.TestCase):
    def test_disabled_features_make_no_calls_and_need_no_dataset(self):
        adapter = FixtureAdapter()
        policy, report = run_rsi({"model": "test-model", "seed_instruction": "seed"}, adapter)
        self.assertEqual(adapter.requests, [])
        self.assertIsNone(policy["evolved"])
        self.assertIsNone(policy["seed"]["router"])
        self.assertEqual(report["status"], "disabled")

    def test_evolution_feedback_and_frozen_validation_selection(self):
        adapter = FixtureAdapter()
        policy, report = run_rsi(manifest(), adapter, Settings(evolution=True))
        self.assertEqual(policy["evolved"]["instruction"], "evolved skill 1")
        self.assertIsNone(policy["evolved"]["router"])
        proposals = [row for row in adapter.requests if row["kind"] == "propose"]
        self.assertEqual(len(proposals), 2)
        self.assertEqual(len(proposals[1]["previous_candidates"]), 2)
        self.assertEqual(proposals[1]["previous_candidates"][1]["instruction"], "evolved skill 0")
        self.assertEqual(set(proposals[1]["previous_candidates"][1]["results"]), {f"t{i}" for i in range(6)})
        validation_start = next(i for i, row in enumerate(adapter.requests) if row["phase"] == "validation")
        self.assertTrue(all(row["kind"] == "evaluate" for row in adapter.requests[validation_start:]))
        self.assertTrue(all(not task["id"].startswith("v") for row in proposals for task in row["tasks"]))
        self.assertEqual(report["deployment_policy_sha256"], digest(stable(policy)))

    def test_routing_without_evolution_trains_seed_without_proposer_calls(self):
        adapter = FixtureAdapter()
        policy, report = run_rsi(manifest(), adapter, Settings(routing=True))
        self.assertFalse(any(row["kind"] == "propose" for row in adapter.requests))
        self.assertIsNone(policy["evolved"])
        self.assertIsNotNone(policy["seed"]["router"])
        self.assertEqual(route(policy["seed"], "count 1 items", True), "seed skill")
        self.assertEqual(route(policy["seed"], "read", True), "")
        self.assertEqual(report["selected_sha256"], policy["seed"]["sha256"])

    def test_every_candidate_has_its_own_instruction_bound_head(self):
        adapter = FixtureAdapter()
        policy, report = run_rsi(manifest(), adapter, Settings(evolution=True, routing=True))
        self.assertEqual(len(report["candidates"]), 3)
        for item in report["candidates"]:
            self.assertEqual(item["router"]["instruction_sha256"], item["sha256"])
        self.assertEqual(policy["seed"]["router"]["instruction_sha256"], policy["seed"]["sha256"])
        self.assertEqual(policy["evolved"]["router"]["instruction_sha256"], policy["evolved"]["sha256"])
        self.assertNotEqual(policy["seed"]["router"], policy["evolved"]["router"])

    def test_degrading_candidate_retains_empty_baseline(self):
        def call(request):
            result = FixtureAdapter()(request)
            if request["kind"] == "evaluate":
                result["score"] = 0.0 if request["instruction"] else 1.0
            return result
        policy, report = run_rsi(manifest(), call, Settings(evolution=True, routing=True))
        self.assertEqual(policy["evolved"]["instruction"], "")
        self.assertTrue(all(row["fit"]["status"] != "admitted" for row in report["candidates"]))

    def test_split_leakage_rejected_before_any_call(self):
        for change in ("unit", "id", "test"):
            data = manifest()
            if change == "unit":
                data["validation"][0]["unit_id"] = "u0"
            elif change == "id":
                data["validation"][0]["id"] = "t0"
            else:
                data["test"] = []
            adapter = FixtureAdapter()
            with self.assertRaises(RSIError):
                run_rsi(data, adapter, Settings(evolution=True))
            self.assertEqual(adapter.requests, [])

    def test_bad_scores_support_and_unknown_usage_fail_closed(self):
        for mode in ("score", "support", "usage"):
            def call(request):
                response = FixtureAdapter()(request)
                if mode == "score" and request["kind"] == "evaluate":
                    response["score"] = None
                if mode == "support" and request["kind"] == "propose":
                    response["supporting_task_ids"] = ["v0", "v1"]
                if mode == "usage":
                    response["input_tokens"] = None
                return response
            with self.assertRaises(RSIError):
                run_rsi(manifest(), call, Settings(evolution=True))

    def test_grouped_router_requires_independent_support_and_abstains_on_harm(self):
        tasks = manifest()["train"]
        before = {t["id"]: {"score": 1.0, "tokens": 100} for t in tasks}
        after = {t["id"]: {"score": 0.0, "tokens": 10} for t in tasks}
        head, report = fit_router(tasks, before, after, "harmful")
        self.assertIsNone(head)
        self.assertEqual(report["status"], "no_supported_positive_oof_advantage")
        for task in tasks:
            task["unit_id"] = "all-one-task"
        head, report = fit_router(tasks, before, after, "harmful")
        self.assertIsNone(head)
        self.assertEqual(report["status"], "insufficient_independent_units")

    def test_portable_features_and_strict_json(self):
        self.assertEqual(features("Count 'items' before 总数 please"), [34 / 4096, 4 / 512, 1, 1, 1])
        self.assertEqual(features("İ K")[1], 0)  # ASCII matching precedes case folding.
        for raw in ('{"a":1,"a":2}', '{"a":NaN}'):
            with self.assertRaises(RSIError):
                strict_json(raw)

    def test_enabled_cli_refuses_without_budget_before_creating_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "manifest.json"
            source.write_bytes(stable({**manifest(), "evaluator_command": ["unused"], "proposer_command": ["unused"]}))
            with self.assertRaises(SystemExit) as raised:
                main(["--manifest", str(source), "--output-dir", str(root / "run"), "--evolution"])
            self.assertEqual(raised.exception.code, 2)
            self.assertFalse((root / "run").exists())

    @unittest.skipIf(os.name == "nt", "durable paid journal uses POSIX flock")
    def test_actual_adapter_process_is_journaled_and_cli_publishes_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            adapter = root / "adapter.py"
            adapter.write_text(
                "import json,sys\n"
                "r=json.load(sys.stdin)\n"
                "assert r['budget_authorization']['max_metered_tokens']==100\n"
                "out={'model':r['model'],'input_tokens':10,'output_tokens':5,'cost_microusd':0}\n"
                "if r['kind']=='propose': out.update(instruction='measured skill',supporting_task_ids=['t0','t1'])\n"
                "else: out.update(score=1.0 if r['instruction']=='measured skill' else 0.5 if r['instruction'] else 0.0)\n"
                "print(json.dumps(out))\n", encoding="utf-8")
            data = manifest()
            data.update(evaluator_command=[sys.executable, str(adapter)], proposer_command=[sys.executable, str(adapter)])
            source = root / "manifest.json"
            source.write_bytes(stable(data))
            run = root / "run"
            self.assertEqual(main(["--manifest", str(source), "--output-dir", str(run),
                "--evolution", "--routing", "--rounds", "1", "--max-cost-usd", "1",
                "--max-tokens", "10000", "--call-max-cost-usd", "0.01", "--call-max-tokens", "100"]), 0)
            policy = strict_json((run / "policy.json").read_bytes())
            report = strict_json((run / "report.json").read_bytes())
            self.assertEqual(policy["evolved"]["instruction"], "measured skill")
            self.assertEqual(len(report["calls"]), 25)
            self.assertEqual(report["budget_checkpoint"]["authority"]["total_cost_microusd"], 1_000_000)
            self.assertTrue((run / "budget.json").exists())

    @unittest.skipIf(os.name == "nt", "durable paid journal uses POSIX flock")
    def test_adapter_timeout_keeps_authorized_exposure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            data = {"evaluator_command": [sys.executable, "-c", "import time;time.sleep(1)"]}
            sha = digest(b"manifest")
            authority = BudgetAuthority(sha, digest(b"test-model"), "skill-rsi-explicit-adapter-v1", 1000, 1000)
            with BudgetJournal(root / "budget.json", authority) as journal:
                adapter = CommandAdapter(data, journal, sha, 100, 100, 0.05)
                with self.assertRaises(subprocess.TimeoutExpired):
                    adapter({"model": "test-model", "kind": "evaluate", "call_index": 0})
                snapshot = journal.snapshot()
                self.assertEqual(snapshot["unsettled_max_cost_microusd"], 100)
                self.assertEqual(snapshot["committed_cost_microusd"], 0)


if __name__ == "__main__":
    unittest.main()
