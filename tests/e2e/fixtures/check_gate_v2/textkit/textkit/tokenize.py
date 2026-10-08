"""Tokenization shared by statistics, search and readability."""
import re

_WORD = re.compile(r"[a-z0-9]+")


def words(text):
    """Lowercase alphanumeric runs: "Don't stop" -> ['don', 't', 'stop']."""
    return _WORD.findall(text.lower())
