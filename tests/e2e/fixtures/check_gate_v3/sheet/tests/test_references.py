import unittest

from sheet import Sheet

class SheetReferencesTest(unittest.TestCase):
    def test_invalid_reference_get(self):
        with self.assertRaises(ValueError):
            Sheet().get('AA1')

    def test_invalid_reference_row_zero(self):
        with self.assertRaises(ValueError):
            Sheet().set('A0', '1')

    def test_invalid_reference_row_100(self):
        with self.assertRaises(ValueError):
            Sheet().get('A100')

    def test_invalid_reference_digits_first(self):
        with self.assertRaises(ValueError):
            Sheet().get('1A')


if __name__ == "__main__":
    unittest.main()
