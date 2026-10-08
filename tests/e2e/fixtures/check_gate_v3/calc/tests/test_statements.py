import unittest

from calc import CalcError, run

class CalcStatementsTest(unittest.TestCase):
    def test_variables(self):
        self.assertEqual(run('let x = 4; let y = x * 2; print y'), ['8'])

    def test_reassignment(self):
        self.assertEqual(run('let x = 1; let x = x + 1; print x'), ['2'])

    def test_comments_and_newlines(self):
        self.assertEqual(run('let a = 1; # one\nprint a + 1'), ['2'])

    def test_empty_statements(self):
        self.assertEqual(run('print 1;; print 2;'), ['1', '2'])

    def test_expression_statement(self):
        self.assertEqual(run('1 + 1; print 3'), ['3'])


if __name__ == "__main__":
    unittest.main()
