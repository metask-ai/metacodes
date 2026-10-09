import unittest

from ledger.report import summary


class SummaryTest(unittest.TestCase):
    def test_summary(self):
        self.assertEqual(summary([1, 2.5, 3]), "count=3 min=1 max=3 mean=2.17")

    def test_empty(self):
        self.assertEqual(summary([]), "no expenses")


if __name__ == "__main__":
    unittest.main()
