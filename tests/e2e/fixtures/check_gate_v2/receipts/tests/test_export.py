import unittest

from shop import export
from shop.cart import Cart


class ExportTest(unittest.TestCase):
    def test_cart_csv(self):
        cart = Cart()
        cart.add("PEN", 2)
        self.assertEqual(export.cart_csv(cart), "sku,qty,amount\nPEN,2,2.50\n")

    def test_refunds_csv(self):
        self.assertEqual(export.refunds_csv([("TEA", 375)]), "sku,amount\nTEA,-3.75\n")


if __name__ == "__main__":
    unittest.main()
