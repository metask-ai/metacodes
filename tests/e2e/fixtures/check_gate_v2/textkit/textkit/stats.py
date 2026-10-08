"""Word statistics."""
from collections import Counter

from .tokenize import words


def word_count(text):
    return len(words(text))


def unique_count(text):
    return len(set(words(text)))


def top_words(text, n):
    """The n most frequent words as (word, count): most frequent first, ties alphabetical."""
    counts = Counter(words(text))
    return sorted(counts.items(), key=lambda pair: (-pair[1], pair[0]))[:n]
