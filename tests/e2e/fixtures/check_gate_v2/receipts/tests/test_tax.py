import unittest

from shop import tax
from shop.cart import Cart


class TaxTest(unittest.TestCase):
    def test_line_tax_rounds_half_up(self):
        self.assertEqual(tax.line_tax(250, "food"), 18)
        self.assertEqual(tax.line_tax(399, "general"), 76)

    def test_total_tax_is_per_line(self):
        cart = Cart()
        cart.add("BRD")
        cart.add("PEN", 3)
        self.assertEqual(tax.total_tax(cart.items()), 17 + 71)


if __name__ == "__main__":
    unittest.main()
