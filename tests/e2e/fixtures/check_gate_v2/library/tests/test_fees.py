import unittest

from library.fees import late_fee


class FeesTest(unittest.TestCase):
    def test_per_day_and_cap(self):
        self.assertEqual(late_fee(0), 0)
        self.assertEqual(late_fee(3), 75)
        self.assertEqual(late_fee(30), 500)


if __name__ == "__main__":
    unittest.main()
