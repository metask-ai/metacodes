import unittest

from textkit.tokenize import words


class TokenizeTest(unittest.TestCase):
    def test_splits_on_non_alphanumerics(self):
        self.assertEqual(words("Don't stop"), ["don", "t", "stop"])
        self.assertEqual(words("A well-known fact"), ["a", "well", "known", "fact"])

    def test_empty(self):
        self.assertEqual(words(""), [])


if __name__ == "__main__":
    unittest.main()
