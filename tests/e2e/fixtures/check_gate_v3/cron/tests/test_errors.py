import datetime
import unittest

from cronexpr import next_fire

class CronErrorsTest(unittest.TestCase):
    def test_too_few_fields(self):
        with self.assertRaises(ValueError):
            next_fire('* * * *', datetime.datetime(2026, 10, 8, 10))

    def test_too_many_fields(self):
        with self.assertRaises(ValueError):
            next_fire('* * * * * *', datetime.datetime(2026, 10, 8, 10))

    def test_minute_out_of_range(self):
        with self.assertRaises(ValueError):
            next_fire('60 * * * *', datetime.datetime(2026, 10, 8, 10))

    def test_hour_out_of_range(self):
        with self.assertRaises(ValueError):
            next_fire('0 24 * * *', datetime.datetime(2026, 10, 8, 10))

    def test_day_zero(self):
        with self.assertRaises(ValueError):
            next_fire('0 0 0 * *', datetime.datetime(2026, 10, 8, 10))

    def test_month_thirteen(self):
        with self.assertRaises(ValueError):
            next_fire('0 0 1 13 *', datetime.datetime(2026, 10, 8, 10))

    def test_weekday_eight(self):
        with self.assertRaises(ValueError):
            next_fire('0 0 * * 8', datetime.datetime(2026, 10, 8, 10))

    def test_unknown_name(self):
        with self.assertRaises(ValueError):
            next_fire('0 0 * FOO *', datetime.datetime(2026, 10, 8, 10))

    def test_reversed_range(self):
        with self.assertRaises(ValueError):
            next_fire('5-1 * * * *', datetime.datetime(2026, 10, 8, 10))

    def test_zero_step(self):
        with self.assertRaises(ValueError):
            next_fire('*/0 * * * *', datetime.datetime(2026, 10, 8, 10))

    def test_bad_step(self):
        with self.assertRaises(ValueError):
            next_fire('*/x * * * *', datetime.datetime(2026, 10, 8, 10))

    def test_empty_item(self):
        with self.assertRaises(ValueError):
            next_fire('1,,2 * * * *', datetime.datetime(2026, 10, 8, 10))

    def test_unknown_macro(self):
        with self.assertRaises(ValueError):
            next_fire('@sometimes', datetime.datetime(2026, 10, 8, 10))

    def test_never_fires(self):
        with self.assertRaises(ValueError):
            next_fire('0 0 30 2 *', datetime.datetime(2026, 10, 8, 10))


if __name__ == "__main__":
    unittest.main()
