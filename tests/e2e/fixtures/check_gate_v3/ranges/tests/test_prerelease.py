import unittest

from ranges import max_satisfying, satisfies

class RangesPrereleaseTest(unittest.TestCase):
    def test_prerelease_excluded_by_default(self):
        self.assertIs(satisfies('1.2.4-beta', '>=1.2.3'), False)

    def test_prerelease_on_same_tuple(self):
        self.assertIs(satisfies('1.2.3-rc.1', '>=1.2.3-beta.2 <1.3.0'), True)

    def test_prerelease_below_bound(self):
        self.assertIs(satisfies('1.2.3-alpha', '>=1.2.3-beta.2'), False)

    def test_prerelease_numeric_order(self):
        self.assertIs(satisfies('1.0.0-beta.11', '>1.0.0-beta.2'), True)


if __name__ == "__main__":
    unittest.main()
