import unittest

from calc import CalcError, run

class CalcErrorsTest(unittest.TestCase):
    def test_calc_error_is_an_exception(self):
        self.assertTrue(issubclass(CalcError, Exception))

    def test_unexpected_character(self):
        with self.assertRaises(CalcError) as caught:
            run('print 1 $ 2')
        self.assertEqual(str(caught.exception), "1:9: unexpected character '$'")

    def test_unexpected_token(self):
        with self.assertRaises(CalcError) as caught:
            run('print )')
        self.assertEqual(str(caught.exception), "1:7: unexpected token ')'")

    def test_unexpected_end(self):
        with self.assertRaises(CalcError) as caught:
            run('print 1 +')
        self.assertEqual(str(caught.exception), '1:10: unexpected end of input')

    def test_undefined_variable(self):
        with self.assertRaises(CalcError) as caught:
            run('print x')
        self.assertEqual(str(caught.exception), "1:7: undefined variable 'x'")

    def test_unknown_function(self):
        with self.assertRaises(CalcError) as caught:
            run('print foo(1)')
        self.assertEqual(str(caught.exception), "1:7: unknown function 'foo'")

    def test_arity(self):
        with self.assertRaises(CalcError) as caught:
            run('print sqrt(1, 2)')
        self.assertEqual(str(caught.exception), "1:7: function 'sqrt' expects 1 argument")

    def test_division_by_zero(self):
        with self.assertRaises(CalcError) as caught:
            run('print 1 / 0')
        self.assertEqual(str(caught.exception), '1:9: division by zero')

    def test_sqrt_of_negative(self):
        with self.assertRaises(CalcError) as caught:
            run('print sqrt(-1)')
        self.assertEqual(str(caught.exception), '1:7: math domain error')

    def test_position_on_second_line(self):
        with self.assertRaises(CalcError) as caught:
            run('let a = 1;\nprint b')
        self.assertEqual(str(caught.exception), "2:7: undefined variable 'b'")


if __name__ == "__main__":
    unittest.main()
