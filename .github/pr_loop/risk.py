"""Which PR changes an automatic review may not merge without a human.

The rules live in the watcher's own checkout, never in the PR under review,
so a candidate cannot weaken the gate that judges it. Changing this file is
itself a high-risk change.
"""
from __future__ import annotations

from fnmatch import fnmatchcase


# (pattern, reason). `*` also matches `/`, so a directory prefix covers its tree.
RULES = (
    ("src/core/*", "core runtime (CODEOWNERS)"),
    ("src/agentcore/*", "agentcore ABI and session authority (CODEOWNERS)"),
    ("src/kg/*", "TinyKG admission (CODEOWNERS)"),
    ("sdk/*", "public SDK (CODEOWNERS)"),
    ("control-plane/*", "control plane and formal rules (CODEOWNERS)"),
    ("src/permission/*", "permission kernel boundary"),
    ("src/permission.zig", "permission kernel boundary"),
    ("src/sandbox/*", "sandbox kernel boundary"),
    ("src/sandbox_helper_root.zig", "sandbox kernel boundary"),
    ("src/formal/*", "formal verdict kernel boundary"),
    ("src/plugin/*", "plugin boundary to the kernel"),
    ("src/*credential*", "credential handling"),
    ("src/*oauth*", "authentication"),
    ("src/*auth*", "authentication"),
    ("src/skills/sealed/*", "sealed credentials"),
    ("vendor/*", "pinned third-party binaries"),
    ("build.zig", "build graph and test gates"),
    ("build.zig.zon", "toolchain and dependency pins"),
    ("doc/API.md", "public API contract"),
    (".github/*", "CI, branch policy or this controller"),
    ("AGENTS.md", "agent policy"),
    ("*/AGENTS.md", "agent policy"),
    ("scripts/ci/*", "CI scripts"),
    ("scripts/release*", "release automation"),
    ("scripts/kernel_pins.py", "kernel pins"),
    ("scripts/stage_*_binary.py", "pinned binary staging"),
    ("scripts/build_tinykg_bundle.py", "pinned binary staging"),
)


def classify(paths):
    """Return {reason: [paths]} for every changed path a rule covers."""
    hits = {}
    for path in paths:
        for pattern, reason in RULES:
            if fnmatchcase(path, pattern):
                hits.setdefault(reason, []).append(path)
                break
    return hits


def reasons(paths, report):
    """Path rules and the adversarial reviewer's own risk call, in one list."""
    found = [f"{reason}: {', '.join(sorted(files)[:5])}{' …' if len(files) > 5 else ''}"
             for reason, files in sorted(classify(paths).items())]
    if report["risk"]["level"] == "high":
        found.extend("reviewer: " + reason for reason in report["risk"]["reasons"])
    return found
