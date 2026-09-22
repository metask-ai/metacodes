"""Billing Rates (reads its settings at import time)."""

from app import settings

CURRENCY = settings.get("billing.currency")
TAX_RATE = settings.get("billing.tax_rate")


def describe():
    return "billing_rates"
