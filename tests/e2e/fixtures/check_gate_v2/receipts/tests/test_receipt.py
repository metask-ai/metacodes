import unittest

from shop import receipt
from shop.cart import Cart

EXPECTED = 'Apple         2 x 0.50      1.00\nNotebook      1 x 3.99      3.99\nGreen tea     1 x 3.75      3.75\n--------------------------------\nSubtotal                    8.74\nTax                         1.09\nTotal                       9.83'


class ReceiptTest(unittest.TestCase):
    def test_layout(self):
        cart = Cart()
        cart.add("APL", 2)
        cart.add("NTB")
        cart.add("TEA")
        self.assertEqual(receipt.render(cart), EXPECTED)


if __name__ == "__main__":
    unittest.main()
