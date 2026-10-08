"""The catalog: book id -> title."""

CATALOG = {"B1": "Dune", "B2": "Emma", "B3": "Ulysses"}


def title(book_id):
    return CATALOG[book_id]
