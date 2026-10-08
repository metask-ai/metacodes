import unittest

from sheet import Sheet

class SheetErrorsTest(unittest.TestCase):
    def assertValue(self, got, expected):
        self.assertEqual(got, expected)
        self.assertIs(type(got), type(expected))

    def test_division_by_zero(self):
        sheet = Sheet()
        sheet.set('A1', '=1/0')
        self.assertValue(sheet.get('A1'), '#DIV/0!')

    def test_text_in_arithmetic(self):
        sheet = Sheet()
        sheet.set('A1', '="a"+1')
        self.assertValue(sheet.get('A1'), '#VALUE!')

    def test_unknown_function(self):
        sheet = Sheet()
        sheet.set('A1', '=FOO(1)')
        self.assertValue(sheet.get('A1'), '#NAME?')

    def test_bad_reference(self):
        sheet = Sheet()
        sheet.set('A1', '=AA1')
        sheet.set('A2', '=A100')
        self.assertValue(sheet.get('A1'), '#REF!')
        self.assertValue(sheet.get('A2'), '#REF!')

    def test_syntax_error(self):
        sheet = Sheet()
        sheet.set('A1', '=1+')
        self.assertValue(sheet.get('A1'), '#ERROR!')

    def test_no_real_power(self):
        sheet = Sheet()
        sheet.set('A1', '=(-8)^0.5')
        self.assertValue(sheet.get('A1'), '#NUM!')

    def test_error_propagates(self):
        sheet = Sheet()
        sheet.set('A1', '=1/0')
        sheet.set('A2', '=A1+1')
        self.assertValue(sheet.get('A2'), '#DIV/0!')

    def test_left_error_wins(self):
        sheet = Sheet()
        sheet.set('A1', '=1/0')
        sheet.set('A2', '=A1+"x"')
        sheet.set('A3', '="x"+A1')
        self.assertValue(sheet.get('A2'), '#DIV/0!')
        self.assertValue(sheet.get('A3'), '#DIV/0!')

    def test_cycle(self):
        sheet = Sheet()
        sheet.set('A1', '=B1')
        sheet.set('B1', '=A1')
        self.assertValue(sheet.get('A1'), '#CYCLE!')
        self.assertValue(sheet.get('B1'), '#CYCLE!')

    def test_depends_on_cycle(self):
        sheet = Sheet()
        sheet.set('A1', '=B1')
        sheet.set('B1', '=A1')
        sheet.set('C1', '=A1+1')
        self.assertValue(sheet.get('C1'), '#CYCLE!')

    def test_self_reference(self):
        sheet = Sheet()
        sheet.set('A1', '=A1+1')
        self.assertValue(sheet.get('A1'), '#CYCLE!')

    def test_range_outside_function(self):
        sheet = Sheet()
        sheet.set('A1', '1')
        sheet.set('A2', '=A1:A1')
        self.assertValue(sheet.get('A2'), '#ERROR!')


if __name__ == "__main__":
    unittest.main()
