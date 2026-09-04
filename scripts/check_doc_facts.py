#!/usr/bin/env python3
"""Fail-closed check of documented facts against their in-tree authority.

``check_doc_links.py`` proves that a link target exists; it says nothing about
what a sentence claims. That is how the AgentCore ABI revision came to be
stated as 13, 14 and 15 in different documents while ``sdk/zig/types.zig``
alone held the truth. This gate closes that gap: every fact that documents
repeat has exactly one authority in the tree, and every place that repeats it
is a registered assertion point.

The registry is ``release/doc_facts.json``::

    {"schema": "metacodes.doc-facts/v1",
     "facts": [{"id": "abi_revision",
                "source": {"file": "sdk/zig/types.zig", "regex": "..."},
                "assert_in": [{"file": "README.md", "regex": "..."}, ...]}]}

``source`` names the authority: a regex with one capture group that must match
**exactly once** in its file (an authority that cannot be located is a broken
sensor, not a passing check), or a dotted key into a JSON document. Every match
of every ``assert_in`` regex must equal the authority's value, and each pattern
must match at least once - a sentence reworded so that its pattern no longer
matches is reported as a detached sensor rather than silently switching the
check off. Values quoted in historical records (changelogs, "evidence retained
at revision N" tables) are deliberately not registered.

Run from the repository root:  python3 scripts/check_doc_facts.py
Exit status 0 when every fact holds, 1 when anything is reported.
"""
from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path

DEFAULT_FACTS = Path("release/doc_facts.json")
SCHEMA = "metacodes.doc-facts/v1"


class FactsError(ValueError):
    """The registry itself is malformed; the gate fails closed."""


@dataclass(frozen=True)
class Finding:
    """One reported problem: a mismatch, a detached sensor, or a registry fault."""

    file: str
    line: int | None
    fact_id: str
    message: str

    def render(self) -> str:
        location = self.file if self.line is None else f"{self.file}:{self.line}"
        return f"{location}: {self.fact_id}: {self.message}"


def _require_pattern(fact_id: str, spec: object) -> None:
    if not isinstance(spec, dict) or not isinstance(spec.get("file"), str):
        raise FactsError(f"{fact_id}: every source and assertion needs a file")
    if "regex" not in spec:
        return
    try:
        groups = re.compile(spec["regex"]).groups
    except (re.error, TypeError) as exc:
        raise FactsError(f"{fact_id}: regex is invalid: {exc}") from exc
    if groups != 1:
        raise FactsError(f"{fact_id}: regex must have exactly one capture group")


def load_facts(path: Path) -> list[dict]:
    """Parse and validate the registry; anything unexpected is a FactsError."""
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("schema") != SCHEMA:
        raise FactsError(f"registry: schema must be {SCHEMA!r}")
    facts = data.get("facts")
    if not isinstance(facts, list) or not facts:
        raise FactsError("registry: facts must be a non-empty list")
    seen: set[str] = set()
    for fact in facts:
        fact_id = fact.get("id") if isinstance(fact, dict) else None
        if not isinstance(fact_id, str) or not fact_id or fact_id in seen:
            raise FactsError(f"{fact_id!r}: fact id must be a unique non-empty string")
        seen.add(fact_id)
        source = fact.get("source")
        if not isinstance(source, dict) or set(source) not in ({"file", "regex"}, {"file", "json"}):
            raise FactsError(f"{fact_id}: source must be {{file, regex}} or {{file, json}}")
        _require_pattern(fact_id, source)
        assertions = fact.get("assert_in")
        if not isinstance(assertions, list) or not assertions:
            raise FactsError(f"{fact_id}: assert_in must be a non-empty list")
        for spec in assertions:
            _require_pattern(fact_id, spec)
            if "regex" not in spec:
                raise FactsError(f"{fact_id}: every assertion needs a regex")
    return facts


def source_value(root: Path, fact: dict) -> tuple[str, str]:
    """The authority's value and the file it was read from."""
    source = fact["source"]
    text = (root / source["file"]).read_text(encoding="utf-8")
    if "json" in source:
        value = json.loads(text)
        try:
            for key in source["json"].split("."):
                value = value[key]
        except (KeyError, TypeError) as exc:
            raise FactsError(f"{fact['id']}: JSON key {source['json']!r} is missing in {source['file']}") from exc
        return str(value), source["file"]
    matches = list(re.finditer(source["regex"], text, re.MULTILINE))
    if len(matches) != 1:
        raise FactsError(
            f"{fact['id']}: source pattern matched {len(matches)} times in {source['file']}, expected exactly one"
        )
    return matches[0].group(1), source["file"]


def check_fact(root: Path, fact: dict) -> list[Finding]:
    """Every assertion point of one fact against its authority."""
    expected, source_file = source_value(root, fact)
    findings: list[Finding] = []
    for spec in fact["assert_in"]:
        try:
            text = (root / spec["file"]).read_text(encoding="utf-8")
        except OSError:
            findings.append(Finding(spec["file"], None, fact["id"], "file not found"))
            continue
        matches = list(re.finditer(spec["regex"], text, re.MULTILINE))
        if not matches:
            findings.append(
                Finding(
                    spec["file"],
                    None,
                    fact["id"],
                    f"sensor detached: pattern {spec['regex']!r} matches nothing",
                )
            )
        for match in matches:
            if match.group(1) == expected:
                continue
            line = text.count("\n", 0, match.start()) + 1
            findings.append(
                Finding(
                    spec["file"],
                    line,
                    fact["id"],
                    f"expected {expected} (from {source_file}), found {match.group(1)}",
                )
            )
    return findings


def check(root: Path, facts_path: Path) -> list[Finding]:
    """All findings for the registry at ``facts_path`` over the tree at ``root``.

    A registry or authority file that cannot be read or parsed is reported as
    a finding like any other, so the gate always ends with its summary line and
    exit status 1 instead of a traceback.
    """
    try:
        registry = facts_path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        registry = str(facts_path)
    try:
        facts = load_facts(facts_path)
    except FactsError as exc:
        return [Finding(registry, None, "registry", str(exc))]
    except (OSError, ValueError) as exc:
        return [Finding(registry, None, "registry", f"cannot read registry: {exc}")]
    findings: list[Finding] = []
    for fact in facts:
        try:
            findings.extend(check_fact(root, fact))
        except FactsError as exc:
            findings.append(Finding(registry, None, fact["id"], str(exc)))
        except (OSError, ValueError) as exc:
            # The authority itself is missing, unreadable or not the JSON it
            # claims to be: the fact cannot be checked, which is a failure.
            findings.append(Finding(fact["source"]["file"], None, fact["id"], f"cannot read authority: {exc}"))
    return sorted(findings, key=lambda finding: (finding.file, finding.line or 0, finding.fact_id))


def main(argv: list[str] | None = None) -> int:
    default_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="Check documented facts against their in-tree authority.")
    parser.add_argument("--root", type=Path, default=default_root, help="repository root (default: this checkout)")
    parser.add_argument("--facts", type=Path, help=f"registry path (default: <root>/{DEFAULT_FACTS.as_posix()})")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    facts_path = args.facts if args.facts is not None else root / DEFAULT_FACTS

    findings = check(root, facts_path)
    for finding in findings:
        print(finding.render())
    try:
        facts = load_facts(facts_path)
    except (FactsError, OSError, ValueError):
        facts = []
    points = sum(len(fact["assert_in"]) for fact in facts)
    files = {spec["file"] for fact in facts for spec in fact["assert_in"]}
    print(f"checked {len(facts)} facts and {points} assertion points in {len(files)} files")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
