"""Sales tax, computed per line and rounded half-up to the cent."""
from .money import round_half_up

RATES = {"food": 7, "general": 19}  # percent


def line_tax(amount, category):
    return round_half_up(amount * RATES[category], 100)


def total_tax(items):
    return sum(line_tax(item["amount"], item["category"]) for item in items)
