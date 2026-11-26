"""The policy migration changes only queue admission and strictness."""
import copy
import io
from pathlib import Path
import sys
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github"))
from pr_policy import PolicyError, REQUIRED_CHECKS, main, migrate, require_direct_merge


def ruleset():
    return {"name": "Protect main", "target": "branch", "enforcement": "active",
            "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}},
            "bypass_actors": [], "rules": [{"type": "deletion"},
            {"type": "pull_request", "parameters": {"required_review_thread_resolution": True}},
            {"type": "required_status_checks", "parameters": {
                "strict_required_status_checks_policy": False,
                "required_status_checks": [{"context": name, "integration_id": 15368} for name in REQUIRED_CHECKS]}},
            {"type": "merge_queue", "parameters": {"max_entries_to_build": 5}}]}


class PolicyTest(unittest.TestCase):
    def test_hidden_bypass_actors_prevent_any_policy_write(self):
        limited = ruleset()
        del limited["bypass_actors"]
        with patch("pr_policy.github_api") as api, redirect_stdout(io.StringIO()), patch("sys.stderr", new_callable=io.StringIO):
            api.return_value = limited
            self.assertEqual(main(["--apply"]), 1)
            self.assertEqual(api.call_count, 1)
            self.assertEqual(api.call_args.args[0], "repos/metask-ai/metacodes/rulesets/23764453")

    def test_exact_payload_preserves_all_other_protections_and_is_idempotent(self):
        original = ruleset()
        before = copy.deepcopy(original)
        desired = migrate(original)
        expected = copy.deepcopy(original)
        expected["rules"].pop()
        expected["rules"][2]["parameters"]["strict_required_status_checks_policy"] = True
        self.assertEqual(desired, expected)
        self.assertEqual(original, before)
        self.assertEqual(migrate(desired), desired)

    def test_refuses_broad_inactive_or_incomplete_rules(self):
        for change in (lambda r: r.update(enforcement="disabled"),
                       lambda r: r["conditions"]["ref_name"].update(include=["refs/heads/*"]),
                       lambda r: r["rules"][2]["parameters"]["required_status_checks"].pop(),
                       lambda r: r["rules"][2]["parameters"]["required_status_checks"][0].update(integration_id=1)):
            r = ruleset()
            change(r)
            with self.assertRaises(PolicyError):
                migrate(r)

    def test_cli_preview_never_writes_and_apply_sends_the_exact_payload(self):
        class API:
            def __init__(self):
                self.calls = []
            def api(self, path, method="GET", payload=None):
                self.calls.append((path, method, payload))
                if path.endswith("/rules/branches/main"):
                    return migrate(ruleset())["rules"]
                return ruleset()
        api = API()
        with patch("pr_policy.github_api", side_effect=api.api), redirect_stdout(io.StringIO()):
            self.assertEqual(main([]), 0)
            self.assertEqual([m for _, m, _ in api.calls], ["GET"])
            api.calls.clear()
            self.assertEqual(main(["--apply"]), 0)
        self.assertEqual([m for _, m, _ in api.calls], ["GET", "PUT", "GET"])
        self.assertEqual(api.calls[1][2], migrate(ruleset()))
        require_direct_merge(api.calls[1][2]["rules"])
