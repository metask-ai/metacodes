import unittest

from sheet import Sheet

class SheetCellsTest(unittest.TestCase):
    def assertValue(self, got, expected):
        self.assertEqual(got, expected)
        self.assertIs(type(got), type(expected))

    def test_raw_int(self):
        sheet = Sheet()
        sheet.set('A1', '42')
        self.assertValue(sheet.get('A1'), 42)

    def test_raw_negative_int(self):
        sheet = Sheet()
        sheet.set('A1', '-7')
        self.assertValue(sheet.get('A1'), -7)

    def test_raw_float(self):
        sheet = Sheet()
        sheet.set('A1', '2.5')
        self.assertValue(sheet.get('A1'), 2.5)

    def test_raw_text(self):
        sheet = Sheet()
        sheet.set('A1', 'hello')
        self.assertValue(sheet.get('A1'), 'hello')

    def test_empty_cell_is_none(self):
        sheet = Sheet()
        self.assertValue(sheet.get('C3'), None)

    def test_references_are_case_insensitive(self):
        sheet = Sheet()
        sheet.set('b2', '5')
        self.assertValue(sheet.get('B2'), 5)

    def test_setting_empty_clears(self):
        sheet = Sheet()
        sheet.set('A1', '5')
        sheet.set('A1', '')
        self.assertValue(sheet.get('A1'), None)


if __name__ == "__main__":
    unittest.main()
