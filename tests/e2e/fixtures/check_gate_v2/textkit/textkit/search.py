"""A tiny inverted index over documents."""
from .tokenize import words


class Index:
    def __init__(self, documents):
        self._postings = {}
        for doc_id, text in documents.items():
            for word in set(words(text)):
                self._postings.setdefault(word, set()).add(doc_id)

    def query(self, text):
        """Ids of documents containing every word of the query, sorted."""
        terms = words(text)
        if not terms:
            return []
        result = set(self._postings.get(terms[0], ()))
        for term in terms[1:]:
            result &= self._postings.get(term, set())
        return sorted(result)
