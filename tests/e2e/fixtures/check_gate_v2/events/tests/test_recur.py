import datetime
import unittest

from events.model import Event
from events.recur import occurrences

D = datetime.datetime


class RecurTest(unittest.TestCase):
    def test_daily(self):
        event = Event("Standup", D(2026, 1, 5, 9, 0), 15, "daily")
        self.assertEqual(occurrences(event, D(2026, 1, 6), D(2026, 1, 9)),
                         [D(2026, 1, 6, 9, 0), D(2026, 1, 7, 9, 0), D(2026, 1, 8, 9, 0)])

    def test_weekly(self):
        event = Event("Review", D(2026, 3, 2, 14, 30), 60, "weekly")
        self.assertEqual(occurrences(event, D(2026, 3, 1), D(2026, 3, 20)),
                         [D(2026, 3, 2, 14, 30), D(2026, 3, 9, 14, 30), D(2026, 3, 16, 14, 30)])

    def test_one_off(self):
        event = Event("Launch", D(2026, 5, 1, 12, 0))
        self.assertEqual(occurrences(event, D(2026, 1, 1), D(2027, 1, 1)), [D(2026, 5, 1, 12, 0)])
        self.assertEqual(occurrences(event, D(2026, 6, 1), D(2027, 1, 1)), [])


if __name__ == "__main__":
    unittest.main()
