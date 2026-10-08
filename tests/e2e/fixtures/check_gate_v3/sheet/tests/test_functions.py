import unittest

from sheet import Sheet

class SheetFunctionsTest(unittest.TestCase):
    def assertValue(self, got, expected):
        self.assertEqual(got, expected)
        self.assertIs(type(got), type(expected))

    def test_sum_range_skips_text(self):
        sheet = Sheet()
        sheet.set('A1', '1')
        sheet.set('A2', '2')
        sheet.set('A3', 'x')
        sheet.set('B1', '=SUM(A1:A3)')
        self.assertValue(sheet.get('B1'), 3)

    def test_sum_arguments(self):
        sheet = Sheet()
        sheet.set('A1', '=SUM(1, 2.5, 3)')
        self.assertValue(sheet.get('A1'), 6.5)

    def test_average(self):
        sheet = Sheet()
        sheet.set('A1', '1')
        sheet.set('A2', '2')
        sheet.set('B1', '=AVERAGE(A1:A2)')
        self.assertValue(sheet.get('B1'), 1.5)

    def test_average_of_nothing(self):
        sheet = Sheet()
        sheet.set('B1', '=AVERAGE(A1:A3)')
        self.assertValue(sheet.get('B1'), '#DIV/0!')

    def test_min_max_count(self):
        sheet = Sheet()
        sheet.set('A1', '4')
        sheet.set('A2', '-1')
        sheet.set('A3', '9')
        sheet.set('B1', '=MIN(A1:A3)')
        sheet.set('B2', '=MAX(A1:A3)')
        sheet.set('B3', '=COUNT(A1:A3)')
        self.assertValue(sheet.get('B1'), -1)
        self.assertValue(sheet.get('B2'), 9)
        self.assertValue(sheet.get('B3'), 3)

    def test_if(self):
        sheet = Sheet()
        sheet.set('A1', '5')
        sheet.set('B1', '=IF(A1>2, "big", "small")')
        self.assertValue(sheet.get('B1'), 'big')

    def test_abs(self):
        sheet = Sheet()
        sheet.set('A1', '=ABS(-3.5)')
        self.assertValue(sheet.get('A1'), 3.5)

    def test_round_half_away_from_zero(self):
        sheet = Sheet()
        sheet.set('A1', '=ROUND(2.5, 0)')
        sheet.set('A2', '=ROUND(-2.5, 0)')
        self.assertValue(sheet.get('A1'), 3)
        self.assertValue(sheet.get('A2'), -3)

    def test_function_names_case_insensitive(self):
        sheet = Sheet()
        sheet.set('A1', '=sum(1, 2)')
        self.assertValue(sheet.get('A1'), 3)


if __name__ == "__main__":
    unittest.main()
