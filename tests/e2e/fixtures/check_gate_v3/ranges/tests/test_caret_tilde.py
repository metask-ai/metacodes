import unittest

from ranges import max_satisfying, satisfies

class RangesCaretTildeTest(unittest.TestCase):
    def test_caret_minor_bump_allowed(self):
        self.assertIs(satisfies('1.9.0', '^1.2.3'), True)

    def test_caret_major_excluded(self):
        self.assertIs(satisfies('2.0.0', '^1.2.3'), False)

    def test_caret_zero_major(self):
        self.assertIs(satisfies('0.2.9', '^0.2.3'), True)

    def test_caret_zero_major_minor_bump_excluded(self):
        self.assertIs(satisfies('0.3.0', '^0.2.3'), False)

    def test_caret_zero_zero(self):
        self.assertIs(satisfies('0.0.4', '^0.0.3'), False)

    def test_tilde_patch_allowed(self):
        self.assertIs(satisfies('1.2.9', '~1.2.3'), True)

    def test_tilde_minor_excluded(self):
        self.assertIs(satisfies('1.3.0', '~1.2.3'), False)

    def test_tilde_major_only(self):
        self.assertIs(satisfies('1.9.0', '~1'), True)


if __name__ == "__main__":
    unittest.main()
