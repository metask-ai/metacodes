"""Reviewable, explicit migration of the upstream main ruleset."""
from __future__ import annotations

import argparse
import copy
import json
import re
import subprocess
import sys

DEFAULT_REPO = "metask-ai/metacodes"
REQUIRED_CHECKS = ("Gates (Linux)", "Gates (macOS)", "Gates (Windows)", "TTY (Linux)")
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


class PolicyError(RuntimeError):
    pass


def github_api(path, method="GET", payload=None):
    argv = ["gh", "api", "--method", method, path]
    if payload is not None:
        argv.extend(["--input", "-"])
    response = subprocess.run(argv, input=json.dumps(payload) if payload is not None else "",
                              capture_output=True, text=True, timeout=120)
    if response.returncode:
        raise PolicyError(f"gh exited {response.returncode}: {response.stderr[-4000:]}")
    return json.loads(response.stdout) if response.stdout.strip() else {}


def require_direct_merge(rules):
    if any(rule["type"] == "merge_queue" for rule in rules):
        raise PolicyError("main still requires a merge queue; an administrator must apply the PR-only policy")
    checks = [rule["parameters"] for rule in rules if rule["type"] == "required_status_checks"]
    required = {(name, 15368) for name in REQUIRED_CHECKS}
    if not any(p.get("strict_required_status_checks_policy") is True and required <= {
            (check["context"], check.get("integration_id")) for check in p["required_status_checks"]}
            for p in checks):
        raise PolicyError("main must require up-to-date branches and all four GitHub Actions checks")


def migrate(ruleset):
    conditions = ruleset.get("conditions", {}).get("ref_name", {})
    if (ruleset.get("target") != "branch" or ruleset.get("enforcement") != "active"
            or conditions.get("include") not in (["refs/heads/main"], ["~DEFAULT_BRANCH"])
            or conditions.get("exclude")):
        raise PolicyError("refusing to change a ruleset that does not exclusively protect main")
    payload = {key: copy.deepcopy(ruleset[key]) for key in (
        "name", "target", "enforcement", "conditions", "bypass_actors", "rules") if key in ruleset}
    payload["rules"] = [r for r in payload["rules"] if r["type"] != "merge_queue"]
    for rule in payload["rules"]:
        if rule["type"] == "required_status_checks":
            rule["parameters"]["strict_required_status_checks_policy"] = True
    require_direct_merge(payload["rules"])
    return payload


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--ruleset", type=int, default=23764453)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="write the reviewed migration; requires repository rule administration")
    mode.add_argument("--check", action="store_true", help="verify the effective direct-merge rules on main")
    args = parser.parse_args(argv)
    try:
        if not REPO.fullmatch(args.repo) or args.ruleset < 1:
            raise PolicyError("a repository and a positive ruleset ID are required")
        if args.check:
            require_direct_merge(github_api(f"repos/{args.repo}/rules/branches/main"))
            return 0
        path = f"repos/{args.repo}/rulesets/{args.ruleset}"
        current = github_api(path)
        desired = migrate(current)
        print(json.dumps({"repository": args.repo, "ruleset": args.ruleset,
                          "before": current["rules"], "after": desired["rules"]}, indent=2))
        if args.apply:
            # GitHub omits bypass actors when the caller cannot write rules.
            # Never send a replacement ruleset with that hidden field missing.
            if "bypass_actors" not in current:
                raise PolicyError("GitHub withheld bypass actors: repository rule Administration write permission is required; no rules were changed")
            github_api(path, "PUT", desired)
            require_direct_merge(github_api(f"repos/{args.repo}/rules/branches/main"))
            print("main now requires current-branch PR checks and direct merges")
        return 0
    except (subprocess.TimeoutExpired, PolicyError, OSError, ValueError, KeyError, TypeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
