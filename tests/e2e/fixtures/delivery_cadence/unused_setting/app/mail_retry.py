"""Mail Retry (reads its settings at import time)."""

from app import settings

RETRY_LIMIT = settings.get_int("mail.retry_limit")


def describe():
    return "mail_retry"
