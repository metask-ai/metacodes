"""Invoices: lines of quantity times unit price."""
from .fmt import format_number


class Invoice:
    def __init__(self, customer):
        self.customer = customer
        self.lines = []

    def add(self, description, quantity, unit_price):
        self.lines.append((description, quantity, unit_price))

    def total(self):
        return round(sum(quantity * price for _, quantity, price in self.lines), 2)

    def render(self):
        out = ["Invoice for %s" % self.customer]
        for description, quantity, price in self.lines:
            amount = round(quantity * price, 2)
            out.append("%s: %s x %s = %s" % (description, format_number(quantity), format_number(price), format_number(amount)))
        out.append("Total: %s" % format_number(self.total()))
        return "\n".join(out)
