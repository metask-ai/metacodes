import unittest

from semver import compare


class CompareTest(unittest.TestCase):
    def test_core_numbers_compare_numerically(self):
        self.assertEqual(compare("1.2.3", "1.2.3"), 0)
        self.assertEqual(compare("1.10.0", "1.9.0"), 1)
        self.assertEqual(compare("2.0.0", "10.0.0"), -1)

    def test_prerelease_is_lower_than_release(self):
        self.assertEqual(compare("1.0.0-alpha", "1.0.0"), -1)
        self.assertEqual(compare("1.0.0", "1.0.0-rc.1"), 1)

    def test_numeric_identifiers_compare_numerically(self):
        self.assertEqual(compare("1.0.0-beta.2", "1.0.0-beta.11"), -1)

    def test_build_metadata_is_ignored(self):
        self.assertEqual(compare("1.0.0+build.1", "1.0.0+build.2"), 0)

    def test_invalid_input_raises(self):
        for bad in ["", "1.0", "1.0.x", "01.0.0"]:
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    compare(bad, "1.0.0")


if __name__ == "__main__":
    unittest.main()
