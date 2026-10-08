import unittest

from duration import parse_duration


class ParseDurationTest(unittest.TestCase):
    def test_examples(self):
        self.assertEqual(parse_duration("1h30m"), 5400)
        self.assertEqual(parse_duration("90s"), 90)
        self.assertEqual(parse_duration("2d"), 172800)
        self.assertEqual(parse_duration("1.5h"), 5400)

    def test_invalid_input_raises(self):
        for bad in ["", "1h1h", "h"]:
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    parse_duration(bad)


if __name__ == "__main__":
    unittest.main()
