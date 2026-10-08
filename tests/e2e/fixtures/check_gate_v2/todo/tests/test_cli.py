import unittest

from todo import cli
from todo.store import TaskStore


class CliTest(unittest.TestCase):
    def test_add_list_done(self):
        store = TaskStore()
        out = []
        cli.main(["add", "Write report", "high", "2026-10-09"], store, out)
        cli.main(["add", "Buy milk"], store, out)
        cli.main(["done", "2"], store, out)
        out.clear()
        cli.main(["list"], store, out)
        self.assertEqual(out, ["[ ] 1 Write report (high, due 2026-10-09)", "[x] 2 Buy milk (normal)"])

    def test_unknown_command(self):
        with self.assertRaises(ValueError):
            cli.main(["frobnicate"], TaskStore(), [])


if __name__ == "__main__":
    unittest.main()
