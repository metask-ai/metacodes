import unittest

from ranges import max_satisfying, satisfies

class RangesApiTest(unittest.TestCase):
    def test_invalid_version(self):
        with self.assertRaises(ValueError):
            satisfies('1.2', '1.x')

    def test_invalid_range(self):
        with self.assertRaises(ValueError):
            satisfies('1.2.3', '>=1.2.3 ||| 2')

    def test_unsupported_operator(self):
        with self.assertRaises(ValueError):
            satisfies('1.2.3', '~>1.2')

    def test_leading_zero_version(self):
        with self.assertRaises(ValueError):
            satisfies('01.2.3', '*')

    def test_max_satisfying(self):
        self.assertEqual(max_satisfying(['1.2.3', '1.2.4', '1.3.0', '2.0.0'], '~1.2.0'), '1.2.4')

    def test_max_satisfying_none(self):
        self.assertEqual(max_satisfying(['1.2.3', '1.2.4'], '^2.0.0'), None)

    def test_max_satisfying_skips_invalid(self):
        self.assertEqual(max_satisfying(['1.2.3', 'banana', '1.5.0'], '^1.0.0'), '1.5.0')

    def test_max_satisfying_skips_prerelease(self):
        self.assertEqual(max_satisfying(['1.2.3', '1.3.0-beta'], '^1.2.3'), '1.2.3')


if __name__ == "__main__":
    unittest.main()
