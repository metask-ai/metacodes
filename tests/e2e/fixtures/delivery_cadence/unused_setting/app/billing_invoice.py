"""Billing Invoice (reads its settings at import time)."""

from app import settings

INVOICE_PREFIX = settings.get("billing.invoice_prefix")


def describe():
    return "billing_invoice"
