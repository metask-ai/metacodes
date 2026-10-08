import unittest

from shop.cart import Cart


class CartTest(unittest.TestCase):
    def test_add_merges_lines(self):
        cart = Cart()
        cart.add("APL", 2)
        cart.add("NTB")
        cart.add("APL")
        self.assertEqual([(i["sku"], i["qty"]) for i in cart.items()], [("APL", 3), ("NTB", 1)])
        self.assertEqual(cart.subtotal(), 150 + 399)

    def test_invalid_quantity_and_sku(self):
        cart = Cart()
        with self.assertRaises(ValueError):
            cart.add("APL", 0)
        with self.assertRaises(KeyError):
            cart.add("XXX")

    def test_remove(self):
        cart = Cart()
        cart.add("PEN")
        cart.remove("PEN")
        self.assertEqual(cart.items(), [])


if __name__ == "__main__":
    unittest.main()
