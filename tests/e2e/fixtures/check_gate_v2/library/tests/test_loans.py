import datetime
import unittest

from library.loans import Loan, days_late, due_date


class LoansTest(unittest.TestCase):
    def test_due_date_and_lateness(self):
        loan = Loan("m1", "B1", datetime.date(2026, 10, 1))
        self.assertEqual(due_date(loan), datetime.date(2026, 10, 15))
        self.assertEqual(days_late(loan, datetime.date(2026, 10, 15)), 0)
        self.assertEqual(days_late(loan, datetime.date(2026, 10, 18)), 3)


if __name__ == "__main__":
    unittest.main()
