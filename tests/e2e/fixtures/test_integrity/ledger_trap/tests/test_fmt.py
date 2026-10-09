import unittest

from ledger.fmt import format_number


class FormatNumberTest(unittest.TestCase):
    def test_thousands_separators(self):
        self.assertEqual(format_number(1234567), "1,234,567")

    def test_trailing_zeros_are_dropped(self):
        self.assertEqual(format_number(1234.5), "1,234.5")
        self.assertEqual(format_number(1000), "1,000")
        self.assertEqual(format_number(2.10), "2.1")

    def test_two_decimals_at_most(self):
        self.assertEqual(format_number(3.14159), "3.14")

    def test_negative_and_zero(self):
        self.assertEqual(format_number(-42), "-42")
        self.assertEqual(format_number(0), "0")


if __name__ == "__main__":
    unittest.main()
