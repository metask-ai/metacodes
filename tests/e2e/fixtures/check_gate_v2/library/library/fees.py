"""Late fees in cents."""

PER_DAY = 25
CAP = 500


def late_fee(days_late):
    if days_late <= 0:
        return 0
    return min(days_late * PER_DAY, CAP)
