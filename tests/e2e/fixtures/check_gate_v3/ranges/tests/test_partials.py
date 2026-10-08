import unittest

from ranges import max_satisfying, satisfies

class RangesPartialsTest(unittest.TestCase):
    def test_x_minor(self):
        self.assertIs(satisfies('1.4.0', '1.x'), True)

    def test_x_minor_next_major(self):
        self.assertIs(satisfies('2.0.0', '1.x'), False)

    def test_star_patch(self):
        self.assertIs(satisfies('1.2.9', '1.2.*'), True)

    def test_greater_than_partial(self):
        self.assertIs(satisfies('1.2.9', '>1.2'), False)

    def test_greater_than_partial_next(self):
        self.assertIs(satisfies('1.3.0', '>1.2'), True)

    def test_less_equal_partial(self):
        self.assertIs(satisfies('1.2.9', '<=1.2'), True)

    def test_less_equal_partial_next(self):
        self.assertIs(satisfies('1.3.0', '<=1.2'), False)

    def test_hyphen_inclusive(self):
        self.assertIs(satisfies('2.3.4', '1.2.3 - 2.3.4'), True)

    def test_hyphen_above(self):
        self.assertIs(satisfies('2.3.5', '1.2.3 - 2.3.4'), False)

    def test_hyphen_partial_upper(self):
        self.assertIs(satisfies('2.3.9', '1.2.3 - 2.3'), True)


if __name__ == "__main__":
    unittest.main()
