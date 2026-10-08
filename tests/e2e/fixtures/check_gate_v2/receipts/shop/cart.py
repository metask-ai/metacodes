"""A shopping cart: an ordered list of lines (sku, quantity)."""
from . import catalog


class Cart:
    def __init__(self):
        self._lines = []  # [sku, qty] in insertion order

    def add(self, sku, qty=1):
        if not isinstance(qty, int) or isinstance(qty, bool) or qty <= 0:
            raise ValueError("quantity must be a positive integer")
        catalog.get(sku)
        for line in self._lines:
            if line[0] == sku:
                line[1] += qty
                return
        self._lines.append([sku, qty])

    def remove(self, sku):
        for index, line in enumerate(self._lines):
            if line[0] == sku:
                del self._lines[index]
                return
        raise KeyError(sku)

    def items(self):
        """One dict per line: sku, name, unit, qty, amount (unit * qty), category."""
        result = []
        for sku, qty in self._lines:
            name, unit, category = catalog.get(sku)
            result.append({"sku": sku, "name": name, "unit": unit, "qty": qty,
                           "amount": unit * qty, "category": category})
        return result

    def subtotal(self):
        return sum(item["amount"] for item in self.items())
