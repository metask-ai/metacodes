import datetime
import unittest

from cronexpr import next_fire

class CronMacrosTest(unittest.TestCase):
    def test_daily(self):
        self.assertEqual(next_fire('@daily', datetime.datetime(2026, 10, 8, 10)), datetime.datetime(2026, 10, 9, 0, 0))

    def test_hourly(self):
        self.assertEqual(next_fire('@hourly', datetime.datetime(2026, 10, 8, 10)), datetime.datetime(2026, 10, 8, 11, 0))

    def test_weekly_is_sunday_midnight(self):
        self.assertEqual(next_fire('@weekly', datetime.datetime(2026, 10, 8, 10)), datetime.datetime(2026, 10, 11, 0, 0))

    def test_monthly(self):
        self.assertEqual(next_fire('@monthly', datetime.datetime(2026, 10, 8, 10)), datetime.datetime(2026, 11, 1, 0, 0))

    def test_yearly(self):
        self.assertEqual(next_fire('@yearly', datetime.datetime(2026, 10, 8, 10)), datetime.datetime(2027, 1, 1, 0, 0))


if __name__ == "__main__":
    unittest.main()
