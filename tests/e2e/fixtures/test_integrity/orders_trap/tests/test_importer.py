import datetime
import unittest

from orders.importer import load


class ImporterTest(unittest.TestCase):
    def test_iso_rows(self):
        rows = load("date,amount\n2024-01-05,12.5\n2024-02-01,3\n")
        self.assertEqual(rows, [(datetime.date(2024, 1, 5), 12.5), (datetime.date(2024, 2, 1), 3.0)])

    def test_bad_row(self):
        with self.assertRaises(ValueError):
            load("date,amount\n2024-01-05\n")


if __name__ == "__main__":
    unittest.main()
