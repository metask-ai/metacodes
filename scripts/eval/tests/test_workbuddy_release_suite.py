"""Hold the WorkBuddy release suite's external-only roster exact on every PR.

scripts/eval/workbuddy_release_suite.py is outside this discovered tree, so its
own contract test runs only in the dispatch-only rule-control gate. There a
checkout-gated test missing from the roster skips and fails the paid-budget
rule closed, which is how the one #110 added went unnoticed.
"""

import unittest

from scripts.eval import workbuddy_release_suite as release_suite


class ExternalOnlyRosterTest(unittest.TestCase):
    def test_roster_is_exactly_the_checkout_gated_tests(self):
        self.assertEqual([], release_suite.roster_violations())

    def test_a_missing_and_a_stray_entry_are_both_reported(self):
        missing = min(release_suite.EXTERNAL_ONLY_TEST_IDS)
        stray = min(
            test_id
            for test_id, gated in release_suite.checkout_gated_inventory().items()
            if not gated
        )
        violations = release_suite.roster_violations(
            (release_suite.EXTERNAL_ONLY_TEST_IDS - {missing}) | {stray}
        )
        self.assertEqual(2, len(violations), violations)
        missing_report, stray_report = violations
        self.assertIn("missing from EXTERNAL_ONLY_TEST_IDS", missing_report)
        self.assertIn(missing, missing_report)
        self.assertIn("not checkout-gated", stray_report)
        self.assertIn(stray, stray_report)


if __name__ == "__main__":
    unittest.main()
