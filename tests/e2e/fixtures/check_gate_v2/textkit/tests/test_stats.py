import unittest

from textkit import stats


class StatsTest(unittest.TestCase):
    def test_counts(self):
        self.assertEqual(stats.word_count("The cat and the hat"), 5)
        self.assertEqual(stats.unique_count("The cat and the hat"), 4)

    def test_top_words(self):
        self.assertEqual(stats.top_words("b a b c a b", 2), [("b", 3), ("a", 2)])
        self.assertEqual(stats.top_words("z y x", 2), [("x", 1), ("y", 1)])


if __name__ == "__main__":
    unittest.main()
