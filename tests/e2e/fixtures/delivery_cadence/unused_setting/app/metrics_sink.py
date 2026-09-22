"""Metrics Sink (reads its settings at import time)."""

from app import settings

NAMESPACE = settings.get("metrics.namespace")
FLUSH_INTERVAL_S = settings.get_int("metrics.flush_interval_s")


def describe():
    return "metrics_sink"
