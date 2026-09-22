"""In-memory search index."""

_INDEX = {}


def add(term, doc_id):
    _INDEX.setdefault(term, set()).add(doc_id)


def lookup(terms):
    hits = None
    for term in terms:
        found = _INDEX.get(term, set())
        hits = found if hits is None else hits & found
    return sorted(hits or [])
