"""Text writes pinned to LF on every host.

Fixture bytes take part in SHA-256 contracts, so a Windows text-mode write must
not turn ``"\\n"`` into ``"\\r\\n"``. ``Path.write_text(newline="\\n")`` says exactly
that, but only since Python 3.10, and the suites' floor is the macOS system
``python3`` (3.9) -- see ``scripts/tests/test_python_floor.py`` and issue #59.
"""

from __future__ import annotations

from pathlib import Path


def write_text_lf(path: Path, data: str, *, encoding: str) -> int:
    """``path.write_text(data, encoding=encoding, newline="\\n")``, on 3.9 too."""
    with open(path, "w", encoding=encoding, newline="\n") as handle:
        return handle.write(data)
