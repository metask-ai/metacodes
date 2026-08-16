"""Run the frozen four-case TinyKG x Lean quality-evidence block.

This is intentionally a separate entry point from the one-case paid wiring
calibration.  Dry-run performs no credential read, journal mutation, run
directory creation, or provider request.  Paid execution requires the explicit
flag and always uses the frozen case cohort and attribution protocol in-repo.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
from typing import Sequence

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from scripts.eval.model import ValidationError, stable_json  # type: ignore
    from scripts.eval.tinykg_lean_factorial_executor import (  # type: ignore
        preflight_block,
        run_block,
    )
else:
    from .model import ValidationError, stable_json
    from .tinykg_lean_factorial_executor import preflight_block, run_block


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--tinykg", type=Path, required=True)
    parser.add_argument("--ripgrep", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--budget-journal", type=Path, required=True)
    parser.add_argument(
        "--auth-file", type=Path, default=Path.home() / ".metacodes/auth.json"
    )
    parser.add_argument(
        "--cohort",
        choices=("block", "heldout"),
        default="block",
        help="frozen case cohort: the 4-case calibration block or the 8-case held-out set",
    )
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--allow-paid-rollouts", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    common = {
        "repo": args.repo,
        "manifest_path": args.manifest,
        "tinykg_binary": args.tinykg,
        "ripgrep": args.ripgrep,
        "run_dir": args.run_dir,
        "budget_path": args.budget_journal,
        "resume": args.resume,
        "cohort": args.cohort,
    }
    if args.dry_run:
        result = preflight_block(**common)
    else:
        if not args.allow_paid_rollouts:
            raise ValidationError(
                "factorial block: paid run requires --allow-paid-rollouts"
            )
        result = run_block(auth_file=args.auth_file, **common)
    print(stable_json(result))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(2) from exc
