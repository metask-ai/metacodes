"""CSV exports for the bookkeeping system."""
from .money import format_cents


def cart_csv(cart):
    rows = ["sku,qty,amount"]
    for item in cart.items():
        rows.append("%s,%d,%s" % (item["sku"], item["qty"], format_cents(item["amount"])))
    return "\n".join(rows) + "\n"


def refunds_csv(refunds):
    rows = ["sku,amount"]
    for sku, cents in refunds:
        rows.append("%s,%s" % (sku, format_cents(-cents)))
    return "\n".join(rows) + "\n"
