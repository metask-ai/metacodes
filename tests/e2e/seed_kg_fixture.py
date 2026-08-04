#!/usr/bin/env python3
"""Seed a fresh E2E TinyKG store from a small, fingerprinted JSON fixture."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


def run(binary: Path, *args: str) -> str:
    completed = subprocess.run(
        [str(binary), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout.strip()


def node_id(output: str) -> str:
    fields = output.split()
    if len(fields) < 2 or fields[0] != "node" or not fields[1].isdigit():
        raise ValueError(f"unparseable TinyKG node output: {output!r}")
    return fields[1]


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit("usage: seed_kg_fixture.py <tinykg-bin> <store> <fixture.json>")
    binary, store, fixture = map(Path, sys.argv[1:])
    if not binary.is_file() or not fixture.is_file():
        raise SystemExit("TinyKG binary or fixture is missing")

    payload = json.loads(fixture.read_text(encoding="utf-8"))
    if payload.get("schema_version") != 1:
        raise ValueError("fixture.schema_version must be 1")
    nodes = payload.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        raise ValueError("fixture.nodes must be a non-empty list")

    store.parent.mkdir(parents=True, exist_ok=True)
    run(binary, "init", str(store))
    global_project = node_id(
        run(binary, "ensure-node", str(store), "project", "global", "--schema-type", "project")
    )
    memory_anchor = node_id(run(binary, "ensure-anchor", str(store), global_project, "memory"))

    for index, item in enumerate(nodes):
        if not isinstance(item, dict):
            raise ValueError(f"fixture.nodes[{index}] must be an object")
        kind = item.get("kind")
        schema_type = item.get("schema_type")
        text = item.get("text")
        if not all(isinstance(value, str) and value for value in (kind, schema_type, text)):
            raise ValueError(f"fixture.nodes[{index}] has invalid kind/schema_type/text")
        created = node_id(
            run(binary, "add-node", str(store), kind, text, "--schema-type", schema_type)
        )
        run(
            binary,
            "govern-node",
            str(store),
            created,
            "--parent",
            memory_anchor,
            "--schema-type",
            schema_type,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
