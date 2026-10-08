import unittest

from intervals import merge


class MergeTest(unittest.TestCase):
    def test_overlapping(self):
        self.assertEqual(merge([(1, 3), (2, 6), (8, 10)]), [(1, 6), (8, 10)])

    def test_unsorted_input(self):
        self.assertEqual(merge([(8, 10), (1, 3)]), [(1, 3), (8, 10)])

    def test_reversed_range_raises(self):
        with self.assertRaises(ValueError):
            merge([(5, 1)])


if __name__ == "__main__":
    unittest.main()
