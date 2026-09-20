"""Mailer (reads its settings at import time)."""

from app import settings

SMTP_HOST = settings.get("mail.smtp_host")
SMTP_PORT = settings.get_int("mail.smtp_port")
SENDER = settings.get("mail.sender")


def describe():
    return "mailer"
