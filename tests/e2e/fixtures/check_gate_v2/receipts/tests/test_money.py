import unittest

from shop.money import format_cents, parse_amount, round_half_up


class MoneyTest(unittest.TestCase):
    def test_format(self):
        self.assertEqual(format_cents(12345), "123.45")
        self.assertEqual(format_cents(5), "0.05")
        self.assertEqual(format_cents(0), "0.00")

    def test_format_negative(self):
        self.assertEqual(format_cents(-150), "-1.50")

    def test_parse(self):
        self.assertEqual(parse_amount("12.34"), 1234)
        self.assertEqual(parse_amount("12.3"), 1230)
        self.assertEqual(parse_amount("-1.50"), -150)
        with self.assertRaises(ValueError):
            parse_amount("1.234")

    def test_round_half_up(self):
        self.assertEqual(round_half_up(15, 10), 2)
        self.assertEqual(round_half_up(14, 10), 1)
        self.assertEqual(round_half_up(-15, 10), -2)


if __name__ == "__main__":
    unittest.main()
