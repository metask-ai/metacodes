import unittest

from sheet import Sheet

class SheetFormulasTest(unittest.TestCase):
    def assertValue(self, got, expected):
        self.assertEqual(got, expected)
        self.assertIs(type(got), type(expected))

    def test_precedence(self):
        sheet = Sheet()
        sheet.set('A1', '=1+2*3')
        self.assertValue(sheet.get('A1'), 7)

    def test_parentheses(self):
        sheet = Sheet()
        sheet.set('A1', '=(1+2)*3')
        self.assertValue(sheet.get('A1'), 9)

    def test_power_is_right_associative(self):
        sheet = Sheet()
        sheet.set('A1', '=2^3^2')
        self.assertValue(sheet.get('A1'), 512)

    def test_unary_minus_binds_tighter_than_power(self):
        sheet = Sheet()
        sheet.set('A1', '=-2^2')
        self.assertValue(sheet.get('A1'), 4)

    def test_division_float(self):
        sheet = Sheet()
        sheet.set('A1', '=7/2')
        self.assertValue(sheet.get('A1'), 3.5)

    def test_division_whole_is_int(self):
        sheet = Sheet()
        sheet.set('A1', '=6/2')
        self.assertValue(sheet.get('A1'), 3)

    def test_reference(self):
        sheet = Sheet()
        sheet.set('A1', '3')
        sheet.set('A2', '=A1*2')
        self.assertValue(sheet.get('A2'), 6)

    def test_recalculation(self):
        sheet = Sheet()
        sheet.set('A1', '3')
        sheet.set('A2', '=A1*2')
        sheet.set('A1', '10')
        self.assertValue(sheet.get('A2'), 20)

    def test_empty_reference_is_zero(self):
        sheet = Sheet()
        sheet.set('A1', '=B9+1')
        self.assertValue(sheet.get('A1'), 1)

    def test_plain_empty_reference(self):
        sheet = Sheet()
        sheet.set('A1', '=B9')
        self.assertValue(sheet.get('A1'), 0)

    def test_concatenation(self):
        sheet = Sheet()
        sheet.set('A1', '="a"&1&TRUE')
        self.assertValue(sheet.get('A1'), 'a1TRUE')

    def test_concatenation_with_empty(self):
        sheet = Sheet()
        sheet.set('A1', '=B9&"x"')
        self.assertValue(sheet.get('A1'), 'x')

    def test_string_escape(self):
        sheet = Sheet()
        sheet.set('A1', '="say ""hi"""')
        self.assertValue(sheet.get('A1'), 'say "hi"')

    def test_comparison_numbers(self):
        sheet = Sheet()
        sheet.set('A1', '=2>1')
        self.assertValue(sheet.get('A1'), True)

    def test_comparison_text_case_insensitive(self):
        sheet = Sheet()
        sheet.set('A1', '="abc"="ABC"')
        self.assertValue(sheet.get('A1'), True)

    def test_number_less_than_text(self):
        sheet = Sheet()
        sheet.set('A1', '=1<"a"')
        self.assertValue(sheet.get('A1'), True)

    def test_booleans_in_arithmetic(self):
        sheet = Sheet()
        sheet.set('A1', '=TRUE+1')
        self.assertValue(sheet.get('A1'), 2)


if __name__ == "__main__":
    unittest.main()
