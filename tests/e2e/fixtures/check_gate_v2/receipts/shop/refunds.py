"""Refund summaries. A refund is (sku, cents refunded) with cents > 0."""
from . import catalog
from .money import format_cents


def render_refunds(refunds):
    lines = []
    total = 0
    for sku, cents in refunds:
        name = catalog.get(sku)[0]
        lines.append("REFUND %-12s %8s" % (name, format_cents(-cents)))
        total += cents
    lines.append("TOTAL REFUNDED      %8s" % format_cents(-total))
    return "\n".join(lines)
