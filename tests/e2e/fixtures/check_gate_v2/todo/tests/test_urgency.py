import unittest

from todo import cli
from todo.store import TaskStore


class UrgencyTest(unittest.TestCase):
    def test_priority_then_due_date(self):
        store = TaskStore()
        out = []
        cli.main(["add", "Sort photos", "low"], store, out)
        cli.main(["add", "Pay rent", "high"], store, out)
        cli.main(["add", "Book flights", "normal", "2026-12-01"], store, out)
        cli.main(["add", "Renew passport", "normal", "2026-10-20"], store, out)
        out.clear()
        cli.main(["list"], store, out)
        self.assertEqual([line.split()[2] for line in out], ["2", "4", "3", "1"])


if __name__ == "__main__":
    unittest.main()
