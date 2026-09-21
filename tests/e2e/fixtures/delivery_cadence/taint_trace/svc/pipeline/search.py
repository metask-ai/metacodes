"""Search chain: the query never reaches a shell."""

from svc.util import index


def run_query(query):
    terms = [t for t in query.split() if t]
    return index.lookup(terms)
