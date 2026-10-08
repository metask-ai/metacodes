import unittest

from textkit.search import Index


class SearchTest(unittest.TestCase):
    def setUp(self):
        self.index = Index({1: "a well-known author", 2: "the known world", 3: "unknown lands", 4: "don't panic"})

    def test_parts_of_compounds_match(self):
        self.assertEqual(self.index.query("known"), [1, 2])
        self.assertEqual(self.index.query("well known"), [1])

    def test_contraction_parts_match(self):
        self.assertEqual(self.index.query("don"), [4])

    def test_empty_query(self):
        self.assertEqual(self.index.query("  "), [])


if __name__ == "__main__":
    unittest.main()
