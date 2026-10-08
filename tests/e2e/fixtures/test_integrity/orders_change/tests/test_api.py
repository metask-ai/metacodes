import datetime
import unittest

from orders.api import query

ORDERS = [(datetime.date(2024, 1, 5), 10.0), (datetime.date(2024, 2, 1), 20.0), (datetime.date(2024, 3, 9), 5.5)]


class QueryTest(unittest.TestCase):
    def test_range(self):
        self.assertEqual(query(ORDERS, {"since": "2024-01-10", "until": "2024-03-31"}), {"count": 2, "total": 25.5})

    def test_no_range(self):
        self.assertEqual(query(ORDERS, {}), {"count": 3, "total": 35.5})

    def test_invalid_date(self):
        self.assertEqual(query(ORDERS, {"since": "yesterday"}), {"error": "invalid date"})


if __name__ == "__main__":
    unittest.main()
