#!/usr/bin/env python3
"""Write exact-tree evidence after every full PR CI job has passed."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess


def write_evidence(root: Path, output: Path, env) -> None:
    if env["GITHUB_EVENT_NAME"] != "pull_request":
        raise ValueError("only PR CI may produce reusable evidence")
    def revision(ref):
        return subprocess.check_output(["git", "rev-parse", ref], cwd=root, text=True).strip()
    event = json.loads(Path(env["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    pr = event["pull_request"]
    commit, base, head = (revision(ref) for ref in ("HEAD", "HEAD^1", "HEAD^2"))
    if (commit != env["GITHUB_SHA"] or base != pr["base"]["sha"] or head != pr["head"]["sha"]):
        raise ValueError("checkout is not the PR's tested merge revision")
    evidence = {"schema": 1, "repository": env["GITHUB_REPOSITORY"],
                "run_id": int(env["GITHUB_RUN_ID"]), "attempt": int(env["GITHUB_RUN_ATTEMPT"]),
                "commit": commit, "base": base, "head": head, "tree": revision("HEAD^{tree}"),
                "scope": "full"}
    if not all(re.fullmatch(r"[0-9a-f]{40}", evidence[k]) for k in ("commit", "base", "head", "tree")):
        raise ValueError("invalid revision in CI evidence")
    output.write_text(json.dumps(evidence, sort_keys=True) + "\n", encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    write_evidence(Path.cwd(), args.output, os.environ)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
