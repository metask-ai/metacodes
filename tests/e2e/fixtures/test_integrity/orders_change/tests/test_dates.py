import datetime
import unittest

from orders.dates import parse_date


class ParseDateTest(unittest.TestCase):
    def test_iso(self):
        self.assertEqual(parse_date("2024-01-05"), datetime.date(2024, 1, 5))

    def test_surrounding_space(self):
        self.assertEqual(parse_date(" 2024-12-31 "), datetime.date(2024, 12, 31))

    def test_other_formats_are_rejected(self):
        for text in ("05/01/2024", "2024/01/05", "20240105", "2024-1-5"):
            with self.assertRaises(ValueError):
                parse_date(text)

    def test_impossible_dates_are_rejected(self):
        with self.assertRaises(ValueError):
            parse_date("2024-02-30")


if __name__ == "__main__":
    unittest.main()
