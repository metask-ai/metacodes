"""Expense statistics."""
from .fmt import format_number


def summary(values):
    if not values:
        return "no expenses"
    mean = sum(values) / len(values)
    return "count=%d min=%s max=%s mean=%s" % (
        len(values), format_number(min(values)), format_number(max(values)), format_number(mean))
