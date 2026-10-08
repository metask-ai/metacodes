import datetime
import unittest

from library.loans import Loan
from library.members import Member
from library.notices import overdue_notice


class NoticesTest(unittest.TestCase):
    def test_standard_notice(self):
        loan = Loan("m1", "B1", datetime.date(2026, 10, 1))
        member = Member("m1", "Ann")
        self.assertEqual(overdue_notice(loan, member, datetime.date(2026, 10, 18)),
                         "Dear Ann, 'Dune' was due on 2026-10-15. Late fee so far: 0.75.")
        self.assertIsNone(overdue_notice(loan, member, datetime.date(2026, 10, 10)))


if __name__ == "__main__":
    unittest.main()
