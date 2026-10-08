import unittest

from shop.refunds import render_refunds

EXPECTED = 'REFUND Apple           -0.50\nREFUND Notebook        -3.99\nTOTAL REFUNDED         -4.49'


class RefundsTest(unittest.TestCase):
    def test_summary(self):
        self.assertEqual(render_refunds([("APL", 50), ("NTB", 399)]), EXPECTED)


if __name__ == "__main__":
    unittest.main()
