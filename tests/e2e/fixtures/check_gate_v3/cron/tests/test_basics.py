import datetime
import unittest

from cronexpr import next_fire

class CronBasicsTest(unittest.TestCase):
    def test_every_minute(self):
        self.assertEqual(next_fire('* * * * *', datetime.datetime(2026, 10, 8, 10, 0, 30)), datetime.datetime(2026, 10, 8, 10, 1))

    def test_result_has_no_seconds(self):
        self.assertEqual(next_fire('* * * * *', datetime.datetime(2026, 10, 8, 10, 0, 59, 900000)), datetime.datetime(2026, 10, 8, 10, 1))

    def test_strictly_after_a_match(self):
        self.assertEqual(next_fire('30 9 * * *', datetime.datetime(2026, 10, 8, 9, 30)), datetime.datetime(2026, 10, 9, 9, 30))

    def test_later_today(self):
        self.assertEqual(next_fire('30 9 * * *', datetime.datetime(2026, 10, 8, 8)), datetime.datetime(2026, 10, 8, 9, 30))

    def test_hourly_quarter(self):
        self.assertEqual(next_fire('15 * * * *', datetime.datetime(2026, 10, 8, 10, 20)), datetime.datetime(2026, 10, 8, 11, 15))

    def test_list(self):
        self.assertEqual(next_fire('0,30 * * * *', datetime.datetime(2026, 10, 8, 10, 10)), datetime.datetime(2026, 10, 8, 10, 30))

    def test_hour_range(self):
        self.assertEqual(next_fire('0 9-17 * * *', datetime.datetime(2026, 10, 8, 17, 30)), datetime.datetime(2026, 10, 9, 9, 0))

    def test_star_step(self):
        self.assertEqual(next_fire('*/15 * * * *', datetime.datetime(2026, 10, 8, 10, 16)), datetime.datetime(2026, 10, 8, 10, 30))

    def test_range_step(self):
        self.assertEqual(next_fire('0 8-18/5 * * *', datetime.datetime(2026, 10, 8, 13)), datetime.datetime(2026, 10, 8, 18, 0))

    def test_value_step(self):
        self.assertEqual(next_fire('5/20 * * * *', datetime.datetime(2026, 10, 8, 10, 26)), datetime.datetime(2026, 10, 8, 10, 45))


if __name__ == "__main__":
    unittest.main()
