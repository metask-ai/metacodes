import unittest

from calc import CalcError, run

class CalcFunctionsTest(unittest.TestCase):
    def test_abs(self):
        self.assertEqual(run('print abs(-3); print abs(-2.5)'), ['3', '2.5'])

    def test_min_max(self):
        self.assertEqual(run('print min(3, 1, 2); print max(3, 1, 2)'), ['1', '3'])

    def test_sqrt(self):
        self.assertEqual(run('print sqrt(16)'), ['4.0'])

    def test_round_half_away_from_zero(self):
        self.assertEqual(run('print round(2.5); print round(-2.5)'), ['3', '-3'])

    def test_round_digits(self):
        self.assertEqual(run('print round(1.005, 2)'), ['1.01'])


if __name__ == "__main__":
    unittest.main()
