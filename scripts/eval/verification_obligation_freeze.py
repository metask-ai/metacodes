"""Freeze the verification-obligation family manifest.

Thin CLI over ``tinykg_lean_factorial_executor.freeze_verification_manifest``.
Zero-paid: this only pins the repository commit, artifacts, and the authored
case cohort into a content-addressed manifest under a fresh private root.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .tinykg_lean_factorial_executor import freeze_verification_manifest


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--production-binary", type=Path, required=True)
    parser.add_argument("--ripgrep", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--max-rollout-cost-usd", type=float, default=0.9)
    parser.add_argument("--max-rollout-metered-tokens", type=int, default=300_000)
    parser.add_argument("--max-total-cost-usd", type=float, default=60.0)
    parser.add_argument("--max-total-metered-tokens", type=int, default=25_000_000)
    parser.add_argument("--max-output-tokens", type=int, default=4_096)
    args = parser.parse_args(argv)
    manifest = freeze_verification_manifest(
        repo=args.repo,
        production_binary=args.production_binary,
        ripgrep=args.ripgrep,
        root=args.root,
        max_rollout_cost_usd=args.max_rollout_cost_usd,
        max_rollout_metered_tokens=args.max_rollout_metered_tokens,
        max_total_cost_usd=args.max_total_cost_usd,
        max_total_metered_tokens=args.max_total_metered_tokens,
        max_output_tokens=args.max_output_tokens,
    )
    print(json.dumps({
        "manifest_id": manifest["manifest_id"],
        "root": manifest["root"],
        "cases": len(manifest["cases"]),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
