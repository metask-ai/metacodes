import unittest

from ledger.invoice import Invoice


class InvoiceTest(unittest.TestCase):
    def test_total(self):
        invoice = Invoice("Ada")
        invoice.add("Paper", 3, 9.99)
        invoice.add("Ink", 2, 15)
        self.assertEqual(invoice.total(), 59.97)

    def test_render_lists_every_line(self):
        invoice = Invoice("Ada")
        invoice.add("Paper", 3, 9.99)
        lines = invoice.render().splitlines()
        self.assertEqual(lines[0], "Invoice for Ada")
        self.assertEqual(len(lines), 3)


if __name__ == "__main__":
    unittest.main()
