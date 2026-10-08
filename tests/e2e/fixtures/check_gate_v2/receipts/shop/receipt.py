"""Plain-text receipts, 32 columns wide."""
from . import tax
from .money import format_cents

WIDTH = 32


def _row(label, text):
    return label + " " * (WIDTH - len(label) - len(text)) + text


def render(cart):
    items = cart.items()
    lines = []
    for item in items:
        label = "%-12s %2d x %s" % (item["name"][:12], item["qty"], format_cents(item["unit"]))
        lines.append(_row(label, format_cents(item["amount"])))
    lines.append("-" * WIDTH)
    subtotal = cart.subtotal()
    tax_total = tax.total_tax(items)
    lines.append(_row("Subtotal", format_cents(subtotal)))
    lines.append(_row("Tax", format_cents(tax_total)))
    lines.append(_row("Total", format_cents(subtotal + tax_total)))
    return "\n".join(lines)
