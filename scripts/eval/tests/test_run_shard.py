"""run_shard.py: the evaluation suite's shards partition its modules, and a
module group never spans two of them.

A module no shard selects never runs and never fails, and a group split
across concurrent shards races on what its modules share, so both are
checked on synthetic lists and on the suite itself.
"""
from __future__ import annotations

import subprocess
import sys
import textwrap
import unittest
from pathlib import Path

from scripts.eval.tests.run_shard import group_modules, module_group, parse_shard, select_shard

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
# The modules that share the live checkout's plugin-v1 pinned inputs.
PLUGIN_V1 = {"test_plugin_frozen_run", "test_plugin_pair_analysis", "test_plugin_pair_runner", "test_plugin_release_gate"}


def _module_name(suite) -> str:
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            name = _module_name(item)
            if name:
                return name
        else:
            return type(item).__module__
    return ""


class RunShardTest(unittest.TestCase):
    def test_the_shards_partition_any_list(self) -> None:
        for size in (0, 1, 2, 5, 53):
            items = list(range(size))
            for count in (1, 2, 3, 4, 7):
                with self.subTest(size=size, count=count):
                    picked = [item for index in range(1, count + 1) for item in select_shard(items, index, count)]
                    self.assertEqual(sorted(picked), items)

    def test_a_group_stays_together_in_first_appearance_order(self) -> None:
        items = ["a", "b1", "c", "b2", "d", "b3"]
        groups = group_modules(items, lambda item: item[0])
        self.assertEqual(groups, [["a"], ["b1", "b2", "b3"], ["c"], ["d"]])
        for count in (1, 2, 3):
            shards = [[item for group in select_shard(groups, index, count) for item in group] for index in range(1, count + 1)]
            self.assertEqual(sorted(item for shard in shards for item in shard), sorted(items))
            self.assertEqual(sum(1 for shard in shards if "b1" in shard and "b2" in shard and "b3" in shard), 1)

    def test_the_suite_s_shards_run_every_module_once_and_keep_plugin_v1_together(self) -> None:
        modules = list(unittest.defaultTestLoader.discover(str(HERE)))
        names = [_module_name(module) for module in modules]
        self.assertIn("test_run_shard", names)
        groups = group_modules(modules, module_group)
        for count in (2, 3):
            with self.subTest(count=count):
                shards = [
                    [_module_name(module) for group in select_shard(groups, index, count) for module in group]
                    for index in range(1, count + 1)
                ]
                self.assertEqual(sorted(name for shard in shards for name in shard), sorted(names))
                holding = [shard for shard in shards if PLUGIN_V1 & set(shard)]
                self.assertEqual(len(holding), 1, shards)
                self.assertLessEqual(PLUGIN_V1, set(holding[0]))

    def test_the_shard_spec_is_validated(self) -> None:
        self.assertEqual(parse_shard("1/1"), (1, 1))
        self.assertEqual(parse_shard("2/3"), (2, 3))
        for bad in ("0/3", "4/3", "1/0", "1", "a/b", "1/2/3", "", "-1/2"):
            with self.subTest(bad=bad):
                self.assertIsNone(parse_shard(bad))

    def test_the_watchdog_ends_a_hung_shard_and_names_where_it_hung(self) -> None:
        hung = textwrap.dedent(
            """
            import time
            from scripts.eval.tests.run_shard import arm_watchdog

            def the_hung_case():
                time.sleep(60)

            arm_watchdog(1)
            the_hung_case()
            """
        )
        done = subprocess.run(
            [sys.executable, "-c", hung], cwd=ROOT, capture_output=True, text=True, timeout=30
        )
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("Timeout", done.stderr)
        self.assertIn("the_hung_case", done.stderr)


if __name__ == "__main__":
    unittest.main()
