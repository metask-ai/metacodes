import unittest

from calc import CalcError, run

class CalcArithmeticTest(unittest.TestCase):
    def test_print_sum(self):
        self.assertEqual(run('print 1 + 2'), ['3'])

    def test_precedence(self):
        self.assertEqual(run('print 2 + 3 * 4'), ['14'])

    def test_parentheses(self):
        self.assertEqual(run('print (2 + 3) * 4'), ['20'])

    def test_true_division(self):
        self.assertEqual(run('print 7 / 2'), ['3.5'])

    def test_true_division_whole(self):
        self.assertEqual(run('print 6 / 2'), ['3.0'])

    def test_floor_division_and_modulo(self):
        self.assertEqual(run('print 7 // 2; print -7 // 2; print 7 % 3; print -7 % 3'), ['3', '-4', '1', '2'])

    def test_power_right_associative(self):
        self.assertEqual(run('print 2 ^ 3 ^ 2'), ['512'])

    def test_unary_minus_and_power(self):
        self.assertEqual(run('print -2 ^ 2'), ['-4'])

    def test_negative_exponent(self):
        self.assertEqual(run('print 2 ^ -1'), ['0.5'])

    def test_float_repr(self):
        self.assertEqual(run('print 0.1 + 0.2'), ['0.30000000000000004'])


if __name__ == "__main__":
    unittest.main()
