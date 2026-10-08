import unittest

from textkit import stats


class CompoundsTest(unittest.TestCase):
    def test_contractions_and_compounds_are_single_words(self):
        self.assertEqual(stats.word_count("Don't stop the well-known show"), 5)
        self.assertIn(("don't", 1), stats.top_words("Don't stop the well-known show", 10))


if __name__ == "__main__":
    unittest.main()
