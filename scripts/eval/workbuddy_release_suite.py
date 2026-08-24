"""Repository-owned WorkBuddy tests for the standalone release gate.

The complete adapter module also contains nine installed-checkout integration
tests. Those tests are valuable, but they require a separately acquired and
pinned WorkBuddy checkout. A standalone metacodes release must not silently
skip them or require that external tree, so this suite excludes exactly that
versioned roster and executes every other adapter test fail-closed.
"""

from __future__ import annotations

import unittest

from scripts.eval.tests import test_workbuddy_adapter


EXTERNAL_ONLY_TEST_IDS = frozenset(
    {
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyMemoryContinuityTest.test_accumulation_off_keeps_the_original_contract",
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyMemoryContinuityTest.test_continuity_lifecycle_empty_start_then_chained_import",
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyMemoryContinuityTest.test_outcome_feedback_exports_task_hint_and_outcomes_together",
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyOverlayUpgradeTest.test_installed_a2o_disconnect_before_sender_is_not_provider_attempt",
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyOverlayUpgradeTest.test_installed_adapter_enforced_mode_requires_rule_filter_receipt",
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyOverlayUpgradeTest.test_installed_adapter_post_run_accepts_real_task_list_contract",
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyOverlayUpgradeTest.test_installed_prepare_job_preserves_route_and_injects_backend_identity",
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyOverlayUpgradeTest.test_installed_proxy_persists_terminal_stream_when_client_closes",
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyRequirementLedgerTreatmentTest.test_ledger_enforce_and_observe_are_exclusive_in_the_real_adapter",
    }
)


def _flatten(suite: unittest.TestSuite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from _flatten(item)
        else:
            yield item


class ExternalBoundaryContractTest(unittest.TestCase):
    def test_external_only_roster_is_exact(self) -> None:
        discovered = {
            test.id()
            for test in _flatten(
                unittest.defaultTestLoader.loadTestsFromModule(test_workbuddy_adapter)
            )
        }
        self.assertTrue(EXTERNAL_ONLY_TEST_IDS <= discovered)


def load_tests(
    loader: unittest.TestLoader,
    standard_tests: unittest.TestSuite,
    pattern: str | None,
) -> unittest.TestSuite:
    del standard_tests, pattern
    discovered = loader.loadTestsFromModule(test_workbuddy_adapter)
    selected = unittest.TestSuite()
    selected.addTests(loader.loadTestsFromTestCase(ExternalBoundaryContractTest))
    selected.addTests(
        test for test in _flatten(discovered) if test.id() not in EXTERNAL_ONLY_TEST_IDS
    )
    return selected
