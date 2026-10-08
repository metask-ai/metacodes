"""The product catalog: sku -> (name, unit price in cents, tax category)."""

PRODUCTS = {
    "APL": ("Apple", 50, "food"),
    "BRD": ("Bread", 249, "food"),
    "NTB": ("Notebook", 399, "general"),
    "PEN": ("Pen", 125, "general"),
    "TEA": ("Green tea", 375, "food"),
}


def get(sku):
    try:
        return PRODUCTS[sku]
    except KeyError:
        raise KeyError("unknown sku %r" % sku) from None
