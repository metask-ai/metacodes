"""Mail Tls (reads its settings at import time)."""

from app import settings

TLS_REQUIRED = settings.get_bool("mail.tls_required")


def describe():
    return "mail_tls"
