"""Pin the scripts/ Python floor at Python 3.9, the macOS system ``python3`` (issue #59)."""
from __future__ import annotations

import ast
import unittest
from pathlib import Path


FLOOR_MAJOR = 3
FLOOR_MINOR = 9
SCRIPTS_ROOT = Path(__file__).resolve().parents[1]
DEFER_ANNOTATIONS = "from __future__ import annotations"


def _python_files() -> list[Path]:
    """Every Python file under scripts/, tests included: the 3.10-only call the
    issue found was reached from a test's setUp."""
    return sorted(
        path
        for path in SCRIPTS_ROOT.rglob("*.py")
        if "__pycache__" not in path.parts
    )


def _defers_annotations(tree: ast.Module) -> bool:
    """True when the module has ``from __future__ import annotations``.

    The compiler rejects a ``__future__`` import that is not the first statement
    after the docstring, so a scan of the module body is exact."""
    return any(
        isinstance(node, ast.ImportFrom)
        and node.module == "__future__"
        and any(alias.name == "annotations" for alias in node.names)
        for node in tree.body
    )


def _annotations(tree: ast.Module) -> list[ast.expr]:
    """Every annotation expression: parameters, returns, annotated assignments."""
    found: list[ast.expr] = []
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            arguments = node.args
            parameters = arguments.posonlyargs + arguments.args + arguments.kwonlyargs
            parameters += [extra for extra in (arguments.vararg, arguments.kwarg) if extra is not None]
            found.extend(parameter.annotation for parameter in parameters if parameter.annotation is not None)
            if node.returns is not None:
                found.append(node.returns)
        elif isinstance(node, ast.AnnAssign):
            found.append(node.annotation)
    return found


def _is_union(node: ast.AST) -> bool:
    return isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr)


def _outermost_unions(root: ast.AST) -> list[ast.BinOp]:
    """The ``a | b | c`` chains under ``root``, one node per chain."""
    unions = [node for node in ast.walk(root) if _is_union(node)]
    nested = {id(side) for node in unions for side in (node.left, node.right) if _is_union(side)}
    return [node for node in unions if id(node) not in nested]


def _operands(node: ast.expr) -> list[ast.expr]:
    """``a | b | c`` flattened to ``[a, b, c]``."""
    if _is_union(node):
        return _operands(node.left) + _operands(node.right)
    return [node]


def _runtime_evaluated_unions(source: str, filename: str = "<module>") -> list[tuple[int, str]]:
    """``(line, text)`` of every PEP 604 union ``X | Y`` the module evaluates when it runs.

    ``ast.parse(feature_version=(3, 9))`` accepts ``list | None``: the syntax is
    fine at the floor, ``type.__or__`` is not (Python 3.10). An annotation is
    evaluated at definition time unless the module defers annotations with
    ``from __future__ import annotations``. A union outside an annotation - a
    type alias, an ``isinstance`` argument - is evaluated whatever the module
    imports, so it is reported when an operand is ``None``: ``x | None`` raises
    for every non-type ``x`` on every Python, so it cannot be a set or bit union.
    """
    tree = ast.parse(source, filename=filename)
    annotations = _annotations(tree)
    inside_annotation = {id(node) for annotation in annotations for node in ast.walk(annotation)}
    findings: list[tuple[int, str]] = []
    if not _defers_annotations(tree):
        for annotation in annotations:
            findings.extend((node.lineno, ast.unparse(node)) for node in _outermost_unions(annotation))
    for node in _outermost_unions(tree):
        if id(node) in inside_annotation:
            continue
        if any(isinstance(operand, ast.Constant) and operand.value is None for operand in _operands(node)):
            findings.append((node.lineno, ast.unparse(node)))
    return sorted(findings)


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

    def test_no_pep604_union_is_evaluated_at_the_floor(self) -> None:
        """``list | None`` passes test_syntax_parses_at_the_floor and raises at import.

        scripts/eval/tests/test_plugin_release_gate.py carried one in a parameter
        annotation without deferring annotations: the eval-suite discovery in
        ``zig build test`` died at collection on the macOS system python3 while
        CI's newer interpreter never saw it."""
        findings = [
            f"{path}:{line}: `{text}`"
            for path in _python_files()
            for line, text in _runtime_evaluated_unions(path.read_text(encoding="utf-8"), str(path))
        ]
        self.assertEqual(
            findings,
            [],
            "\n" + "\n".join(findings) + "\n"
            f"each `X | Y` above is evaluated when the module runs and needs Python 3.10 (type.__or__); "
            f"defer annotations with `{DEFER_ANNOTATIONS}` at the top of the module (the scripts/ "
            "convention), and spell a union outside an annotation typing.Optional / typing.Union",
        )


class Pep604UnionScanTest(unittest.TestCase):
    """The scanner behind test_no_pep604_union_is_evaluated_at_the_floor, both ways."""

    def test_annotations_are_reported_when_the_module_does_not_defer_them(self) -> None:
        source = (
            "import typing\n"
            "\n"
            "def run(heads: list | None = None, *rest: int | None) -> str | None:\n"
            "    return None\n"
            "\n"
            "class Box:\n"
            "    label: typing.Dict[str, int | str | None] = {}\n"
        )
        self.assertEqual(
            _runtime_evaluated_unions(source),
            [(3, "int | None"), (3, "list | None"), (3, "str | None"), (7, "int | str | None")],
        )

    def test_deferred_annotations_are_not_reported(self) -> None:
        source = (
            '"""A docstring ahead of the future import still defers."""\n'
            "from __future__ import annotations\n"
            "\n"
            "def run(heads: list | None = None) -> str | None:\n"
            "    label: int | None = None\n"
            "    return label\n"
        )
        self.assertEqual(_runtime_evaluated_unions(source), [])

    def test_optional_and_value_unions_are_not_reported(self) -> None:
        source = (
            "from typing import Optional, Union\n"
            "\n"
            "def run(heads: Optional[list] = None, flags: int = 0) -> Union[str, None]:\n"
            "    mask = flags | 0b1\n"
            "    names = {'a'} | {'b'}\n"
            "    return None\n"
        )
        self.assertEqual(_runtime_evaluated_unions(source), [])

    def test_unions_with_none_outside_annotations_are_reported_despite_the_import(self) -> None:
        source = (
            "from __future__ import annotations\n"
            "\n"
            "Heads = list | None\n"
            "\n"
            "def check(value):\n"
            "    return isinstance(value, int | None | str)\n"
        )
        self.assertEqual(
            _runtime_evaluated_unions(source),
            [(3, "list | None"), (6, "int | None | str")],
        )
