"""Budgets: how much is left to spend."""
from .fmt import format_number


def remaining(limit, spent):
    left = round(limit - sum(spent), 2)
    if left < 0:
        return "over budget by %s" % format_number(-left)
    return "%s left" % format_number(left)
