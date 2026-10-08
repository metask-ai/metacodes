"""Readability measures."""
import re

from .tokenize import words


def sentences(text):
    return [part for part in re.split(r"[.!?]+", text) if words(part)]


def avg_sentence_length(text):
    parts = sentences(text)
    if not parts:
        return 0.0
    return round(sum(len(words(part)) for part in parts) / len(parts), 2)
