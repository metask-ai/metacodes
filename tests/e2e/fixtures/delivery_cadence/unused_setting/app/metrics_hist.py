"""Metrics Hist (reads its settings at import time)."""

from app import settings

HISTOGRAM_BUCKETS = settings.get("metrics.histogram_buckets")
TAGS = settings.get("metrics.tags")


def describe():
    return "metrics_hist"
