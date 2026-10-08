import unittest

from roman import from_roman, to_roman


class RomanTest(unittest.TestCase):
    def test_to_roman(self):
        self.assertEqual(to_roman(1994), "MCMXCIV")
        self.assertEqual(to_roman(4), "IV")

    def test_from_roman(self):
        self.assertEqual(from_roman("MCMXCIV"), 1994)

    def test_out_of_range_raises(self):
        with self.assertRaises(ValueError):
            to_roman(0)

    def test_non_canonical_raises(self):
        with self.assertRaises(ValueError):
            from_roman("IIII")


if __name__ == "__main__":
    unittest.main()
