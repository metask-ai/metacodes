import unittest

from wrap import wrap


class WrapTest(unittest.TestCase):
    def test_greedy_fill(self):
        self.assertEqual(wrap("the quick brown fox", 10), "the quick\nbrown fox")

    def test_paragraphs_are_kept(self):
        self.assertEqual(wrap("a b\n\nc", 10), "a b\n\nc")

    def test_width_below_one_raises(self):
        with self.assertRaises(ValueError):
            wrap("a", 0)


if __name__ == "__main__":
    unittest.main()
