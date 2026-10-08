import datetime
import unittest

from library.loans import Loan
from library.members import load_members
from library.notices import overdue_notice


class PremiumTest(unittest.TestCase):
    def test_premium_notice(self):
        members = load_members('[{"id": "m2", "name": "Bo", "tier": "premium"}]')
        loan = Loan("m2", "B2", datetime.date(2026, 10, 1))
        self.assertEqual(overdue_notice(loan, members["m2"], datetime.date(2026, 11, 1)),
                         "Dear Bo, 'Emma' was due on 2026-10-29. Late fee so far: 0.30.")


if __name__ == "__main__":
    unittest.main()
