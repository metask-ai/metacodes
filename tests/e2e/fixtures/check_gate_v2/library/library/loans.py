"""Loans and due dates."""
import datetime
from dataclasses import dataclass

LOAN_DAYS = 14


@dataclass
class Loan:
    member_id: str
    book_id: str
    start: datetime.date


def due_date(loan):
    return loan.start + datetime.timedelta(days=LOAN_DAYS)


def days_late(loan, today):
    return max(0, (today - due_date(loan)).days)
