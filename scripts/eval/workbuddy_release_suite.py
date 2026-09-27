"""Repository-owned WorkBuddy tests for the standalone release gate.

The complete adapter module also contains installed-checkout integration tests.
Those tests are valuable, but they require a separately acquired and pinned
WorkBuddy checkout. A standalone metacodes release must not silently skip them
or require that external tree, so this suite excludes exactly that versioned
roster and executes every other adapter test fail-closed.

``roster_violations`` holds the roster to exactly the tests that read
``METACODES_WORKBUDDY_CHECKOUT``. This module is outside the discovered test
tree, so ``zig build test`` runs that check through
``scripts/eval/tests/test_workbuddy_release_suite.py``.
"""

from __future__ import annotations

import ast
from pathlib import Path
import unittest

from scripts.eval.tests import test_workbuddy_adapter


CHECKOUT_ENV = "METACODES_WORKBUDDY_CHECKOUT"
EXTERNAL_ONLY_TEST_IDS = frozenset(
    {
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyMemoryContinuityTest.test_accumulation_off_keeps_the_original_contract",
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyMemoryContinuityTest.test_continuity_lifecycle_empty_start_then_chained_import",
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyMemoryContinuityTest.test_outcome_feedback_exports_task_hint_and_outcomes_together",
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyOverlayUpgradeTest.test_installed_a2o_disconnect_before_sender_is_not_provider_attempt",
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyOverlayUpgradeTest.test_installed_adapter_enforced_mode_requires_rule_filter_receipt",
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyOverlayUpgradeTest.test_installed_adapter_post_run_accepts_real_task_list_contract",
        "scripts.eval.tests.test_workbuddy_adapter.WorkBuddyOverlayUpgradeTest.test_installed_adapter_tolerates_killed_agent_missing_result_event",
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


def _reads_checkout(function: ast.FunctionDef | ast.AsyncFunctionDef) -> bool:
    statements = function.body
    first = statements[0] if statements else None
    if (
        isinstance(first, ast.Expr)
        and isinstance(first.value, ast.Constant)
        and isinstance(first.value.value, str)
    ):
        statements = statements[1:]  # naming the variable in a docstring is not reading it
    return any(
        isinstance(node, ast.Constant) and node.value == CHECKOUT_ENV
        for statement in statements
        for node in ast.walk(statement)
    )


def checkout_gated_inventory() -> dict[str, bool]:
    """Every adapter test id the module defines, and whether it needs the checkout.

    A test is gated when its body reads ``CHECKOUT_ENV`` or it calls a
    same-class ``self.<method>()`` that is gated, as the
    ``WorkBuddyMemoryContinuityTest`` tests are through ``_run_program``.
    """

    path = Path(test_workbuddy_adapter.__file__)
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    inventory: dict[str, bool] = {}
    for owner in (node for node in tree.body if isinstance(node, ast.ClassDef)):
        methods = {
            node.name: node
            for node in owner.body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        }
        callees = {
            name: {
                node.func.attr
                for node in ast.walk(method)
                if isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id == "self"
                and node.func.attr in methods
            }
            for name, method in methods.items()
        }
        gated = {name for name, method in methods.items() if _reads_checkout(method)}
        while True:
            reached = {name for name, called in callees.items() if called & gated} - gated
            if not reached:
                break
            gated |= reached
        for name in methods:
            if name.startswith("test"):
                test_id = f"{test_workbuddy_adapter.__name__}.{owner.name}.{name}"
                inventory[test_id] = name in gated
    return inventory


def roster_violations(roster: frozenset[str] = EXTERNAL_ONLY_TEST_IDS) -> list[str]:
    """Why ``roster`` is not exactly the checkout-gated adapter tests; empty when it is."""

    discovered = {
        test.id()
        for test in _flatten(
            unittest.defaultTestLoader.loadTestsFromModule(test_workbuddy_adapter)
        )
    }
    inventory = checkout_gated_inventory()
    gated = {test_id for test_id, needs_checkout in inventory.items() if needs_checkout}
    differences = (
        # An inherited or generated test the analysis cannot see could skip unexamined.
        ("discovered adapter tests the gating analysis did not see", discovered - set(inventory)),
        ("analysed adapter tests unittest does not discover", set(inventory) - discovered),
        (
            "checkout-gated tests missing from EXTERNAL_ONLY_TEST_IDS, so this suite runs them and they skip",
            gated - roster,
        ),
        (
            "EXTERNAL_ONLY_TEST_IDS entries that are not checkout-gated adapter tests, so this suite drops them",
            roster - gated,
        ),
    )
    return [f"{label}: {sorted(ids)}" for label, ids in differences if ids]


class ExternalBoundaryContractTest(unittest.TestCase):
    def test_external_only_roster_is_exact(self) -> None:
        self.assertEqual([], roster_violations())


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
