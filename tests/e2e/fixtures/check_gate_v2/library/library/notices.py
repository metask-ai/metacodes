"""Overdue notices."""
from . import books, fees, loans


def _money(cents):
    return "%d.%02d" % (cents // 100, cents % 100)


def overdue_notice(loan, member, today):
    """The notice text, or None when the loan is not late."""
    late = loans.days_late(loan, today)
    if late == 0:
        return None
    return "Dear %s, '%s' was due on %s. Late fee so far: %s." % (
        member.name, books.title(loan.book_id), loans.due_date(loan).isoformat(),
        _money(fees.late_fee(late)))
