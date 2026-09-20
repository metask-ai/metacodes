"""Format metadata table."""

TABLE = {
    "pdf": {"mime": "application/pdf", "binary": True},
    "png": {"mime": "image/png", "binary": True},
    "svg": {"mime": "image/svg+xml", "binary": False},
    "txt": {"mime": "text/plain", "binary": False},
}


def is_binary(fmt):
    return TABLE.get(fmt, {}).get("binary", True)
