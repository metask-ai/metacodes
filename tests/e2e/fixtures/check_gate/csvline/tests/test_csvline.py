import unittest

from csvline import parse_line


class ParseLineTest(unittest.TestCase):
    def test_plain_fields(self):
        self.assertEqual(parse_line("a,b,c"), ["a", "b", "c"])

    def test_quoted_comma(self):
        self.assertEqual(parse_line('x,"y,z"'), ["x", "y,z"])

    def test_escaped_quote(self):
        self.assertEqual(parse_line('"say ""hi"""'), ['say "hi"'])

    def test_trailing_comma(self):
        self.assertEqual(parse_line("a,"), ["a", ""])


if __name__ == "__main__":
    unittest.main()
