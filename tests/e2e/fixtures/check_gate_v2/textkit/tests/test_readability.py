import unittest

from textkit.readability import avg_sentence_length, sentences


class ReadabilityTest(unittest.TestCase):
    def test_sentences(self):
        self.assertEqual(len(sentences("One two. Three four five! Six?")), 3)

    def test_average(self):
        self.assertEqual(avg_sentence_length("One two. Three four five! Six?"), 2.0)
        self.assertEqual(avg_sentence_length(""), 0.0)


if __name__ == "__main__":
    unittest.main()
