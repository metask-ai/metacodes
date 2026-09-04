"""Pin the scripts/ Python floor at Python 3.9, the macOS system ``python3`` (issue #59)."""
from __future__ import annotations

import ast
import unittest
from pathlib import Path


FLOOR_MAJOR = 3
FLOOR_MINOR = 9
SCRIPTS_ROOT = Path(__file__).resolve().parents[1]


def _python_files() -> list[Path]:
    """Every Python file under scripts/, tests included: the 3.10-only call the
    issue found was reached from a test's setUp."""
    return sorted(
        path
        for path in SCRIPTS_ROOT.rglob("*.py")
        if "__pycache__" not in path.parts
    )


class PythonFloorTest(unittest.TestCase):
    def test_syntax_parses_at_the_floor(self) -> None:
        for path in _python_files():
            source = path.read_text(encoding="utf-8")
            try:
                ast.parse(source, filename=str(path), feature_version=(FLOOR_MAJOR, FLOOR_MINOR))
            except SyntaxError as error:
                self.fail(f"{path}: {error}")

    def test_write_text_never_passes_newline(self) -> None:
        for path in _python_files():
            tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
                    continue
                if node.func.attr == "write_text" and any(keyword.arg == "newline" for keyword in node.keywords):
                    self.fail(
                        f"{path}:{node.lineno}: Path.write_text(newline=) needs Python 3.10; "
                        "use open(path, 'w', newline=...) so the macOS system python3 (3.9) still runs this"
                    )
