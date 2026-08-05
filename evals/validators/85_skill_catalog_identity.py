#!/usr/bin/env python3
"""Semantic validator for the historical AgentCore Skill identity repair."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    workspace = Path(sys.argv[1])
    paths = {
        "catalog": "src/skills/runtime/catalog.zig",
        "protocol": "sdk/zig/protocol.zig",
        "types": "sdk/zig/types.zig",
        "abi": "src/agentcore/abi_v1.zig",
        "test": "tests/component/agentcore_abi_test.zig",
    }
    texts: dict[str, str] = {}
    try:
        for name, relative in paths.items():
            texts[name] = (workspace / relative).read_text(encoding="utf-8")
    except OSError as exc:
        print(f"cannot read snapshot source: {exc}")
        return 1
    handoff_path = workspace / "HANDOFF.md"
    handoff = handoff_path.read_text(encoding="utf-8") if handoff_path.is_file() else ""
    failures: list[str] = []
    catalog = texts["catalog"]
    protocol = texts["protocol"]

    require(re.search(r"skill_id:\s*\[64\]u8", catalog) is not None, "SkillRecord lacks a stable id", failures)
    require(".skill_id = hashHex(candidate.invocation_name)" in catalog, "id is not derived from invocation name", failures)
    require("validateUniqueSkillIds" in catalog and "CatalogInvalid" in catalog, "duplicate ids are not rejected", failures)
    require('"skill_id"' in catalog or '\\"skill_id\\"' in catalog, "descriptor omits skill_id", failures)
    require('display_name' in catalog, "descriptor omits display_name", failures)
    require("pub const SkillDescriptor" in protocol and "skill_id: []const u8" in protocol, "SDK descriptor lacks identity", failures)
    require("pub fn decodeSkillCatalog" in protocol, "SDK lacks owned catalog decoder", failures)
    require("lowerHex64(skill.skill_id)" in protocol, "SDK does not validate canonical ids", failures)
    require("skill_id: BytesViewV1" in texts["types"], "wire run input lacks skill id", failures)
    require("plan.skill.skill_id" in texts["abi"], "canonical invocation record omits skill id", failures)
    require("workctl" in texts["test"] and "REVIEW_SKILL_SENTINEL" in texts["test"], "two-skill L2 coverage is missing", failures)
    require(
        re.search(r"skill_id[^\n]{0,120}skill_id", texts["test"], re.DOTALL) is not None
        or "workctl_ids.skill_id" in texts["test"],
        "L2 does not distinguish the two ids",
        failures,
    )
    for token in (
        "skill_id=sha256(invocation_name)",
        "catalog_revision=content_addressed",
        "duplicate_ids=reject",
        "descriptor_ownership=consumer",
    ):
        require(token in handoff, f"HANDOFF.md omits {token}", failures)

    if failures:
        print("; ".join(failures))
        return 1
    print("Skill catalog identity is stable across producer, SDK, ABI, and L2")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
