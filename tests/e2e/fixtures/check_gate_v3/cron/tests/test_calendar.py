import datetime
import unittest

from cronexpr import next_fire

class CronCalendarTest(unittest.TestCase):
    def test_month_names(self):
        self.assertEqual(next_fire('0 0 1 JAN,jul *', datetime.datetime(2026, 2, 1)), datetime.datetime(2026, 7, 1, 0, 0))

    def test_weekday_range_names(self):
        self.assertEqual(next_fire('0 9 * * mon-fri', datetime.datetime(2026, 10, 9, 10)), datetime.datetime(2026, 10, 12, 9, 0))

    def test_seven_is_sunday(self):
        self.assertEqual(next_fire('0 12 * * 7', datetime.datetime(2026, 10, 8)), datetime.datetime(2026, 10, 11, 12, 0))

    def test_day_of_month_or_weekday(self):
        self.assertEqual(next_fire('0 0 13 * FRI', datetime.datetime(2026, 10, 10)), datetime.datetime(2026, 10, 13, 0, 0))

    def test_star_step_day_of_month_and_weekday(self):
        self.assertEqual(next_fire('0 0 */2 * MON', datetime.datetime(2026, 10, 8)), datetime.datetime(2026, 10, 19, 0, 0))

    def test_month_rollover(self):
        self.assertEqual(next_fire('0 0 1 * *', datetime.datetime(2026, 10, 31, 23, 59)), datetime.datetime(2026, 11, 1, 0, 0))

    def test_year_rollover(self):
        self.assertEqual(next_fire('0 0 1 1 *', datetime.datetime(2026, 6, 1)), datetime.datetime(2027, 1, 1, 0, 0))

    def test_leap_day(self):
        self.assertEqual(next_fire('0 0 29 2 *', datetime.datetime(2026, 3, 1)), datetime.datetime(2028, 2, 29, 0, 0))


if __name__ == "__main__":
    unittest.main()
