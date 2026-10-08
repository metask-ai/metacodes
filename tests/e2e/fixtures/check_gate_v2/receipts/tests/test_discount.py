import unittest

from shop import receipt
from shop.cart import Cart


class DiscountTest(unittest.TestCase):
    def test_save10_on_one_line(self):
        cart = Cart()
        cart.add("NTB", 2)
        cart.apply_code("SAVE10")
        self.assertEqual(cart.discount(), 80)
        lines = receipt.render(cart).splitlines()
        self.assertTrue(lines[-3].startswith("Discount (SAVE10)"))
        self.assertTrue(lines[-3].endswith("(0.80)"))
        self.assertTrue(lines[-1].endswith("8.54"))


if __name__ == "__main__":
    unittest.main()
