import unittest

from ranges import max_satisfying, satisfies

class RangesBasicTest(unittest.TestCase):
    def test_exact_match(self):
        self.assertIs(satisfies('1.2.3', '1.2.3'), True)

    def test_exact_mismatch(self):
        self.assertIs(satisfies('1.2.4', '1.2.3'), False)

    def test_and_set_inside(self):
        self.assertIs(satisfies('1.5.0', '>=1.2.0 <2.0.0'), True)

    def test_and_set_upper_bound(self):
        self.assertIs(satisfies('2.0.0', '>=1.2.0 <2.0.0'), False)

    def test_or_sets(self):
        self.assertIs(satisfies('3.1.0', '1.x || >=3.0.0'), True)

    def test_star_matches_releases(self):
        self.assertIs(satisfies('0.0.1', '*'), True)

    def test_empty_range_matches_releases(self):
        self.assertIs(satisfies('5.0.0', ''), True)


if __name__ == "__main__":
    unittest.main()
