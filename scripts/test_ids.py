#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ast
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Set, Tuple

ROOT = Path(__file__).resolve().parents[1]
IDS_DIR_ENV = "METACODES_TEST_IDS_DIR"
KINDS = ("zig", "py", "tty")
RAW_STATUSES = ("pass", "skip", "fail")
SET_STATUSES = ("pass", "skip", "listed")
ENFORCED_KINDS = ("zig", "py")
RENAMED = Path("tests/test_ids/renamed.tsv")
REMOVED = Path("tests/test_ids/removed.tsv")
TTY_CASES = Path("tests/tty/cases")
CI_WORKFLOW = "ci.yml"
ARTIFACT = "test-ids"
MIGRATION_LABEL = "migration"
UNNAMED_ZIG_TEST = re.compile(r"\.test_\d+$")
SUMMARY_LIST_LIMIT = 50

Entry = Tuple[str, str, str]
IdCounts = Dict[Entry, int]


class TestIdError(Exception):
    pass


def qualified(root: str, namespace: str) -> str:
    return ".".join(part for part in (root.replace("/", "."), namespace) if part)


def zig_entry(name: str, root: str = "") -> Tuple[str, str]:
    markers = [(name.find(marker), label) for marker, label in ((".test.", ""), (".decltest.", "decltest "))]
    found = [(index, label) for index, label in markers if index >= 0]
    if found:
        index, label = min(found)
        namespace, rest = name[:index], name[index + 1:].split(".", 1)[1]
        test_id = "zig:" + label + rest
    else:
        unnamed = UNNAMED_ZIG_TEST.search(name)
        if unnamed is None:
            return "zig:" + name, qualified(root, "")
        namespace, test_id = name[:unnamed.start()], "zig:<unnamed>"
    return test_id, qualified(root, namespace)


def python_entry(test_id: str, root: str = "") -> Tuple[str, str]:
    parts = test_id.split(".")
    return "py:" + ".".join(parts[-2:]), qualified(root, ".".join(parts[:-2]))


def raw_source(path: Path) -> str:
    stem = path.stem.split("--", 1)[0]
    if stem.startswith("zig-"):
        return re.sub(r"-\d+of\d+$", "", stem)
    if stem.startswith("py-"):
        return stem
    raise TestIdError(f"{path.name}: not a test ID record")


def read_raw(raw_dir: Path) -> Tuple[IdCounts, Dict[str, Counter]]:
    counts: IdCounts = Counter()
    sources: Dict[str, Counter] = {}
    files = sorted(path for path in raw_dir.rglob("*.tsv") if path.is_file())
    if not files:
        raise TestIdError(f"{raw_dir}: no test ID records")
    for path in files:
        source = raw_source(path)
        tally = sources.setdefault(source, Counter())
        root: Optional[str] = None
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not line:
                continue
            status, sep, name = line.partition("\t")
            if status == "root" and sep and number == 1:
                root = name
                continue
            if not sep or status not in RAW_STATUSES or not name:
                raise TestIdError(f"{path.name}:{number}: malformed record {line!r}")
            if root is None:
                raise TestIdError(f"{path.name}: records without the test root they are relative to (METACODES_TEST_ROOT)")
            tally[status] += 1
            test_id, location = zig_entry(name, root) if source.startswith("zig-") else python_entry(name, root)
            counts[(test_id, location, status)] += 1
    failed = sum(tally["fail"] for tally in sources.values())
    if failed:
        raise TestIdError(f"{failed} tests failed: a failed run is not a test ID set")
    return counts, sources


def tty_cases(cases_dir: Path) -> List[Tuple[str, str]]:
    cases = []
    for path in sorted(cases_dir.glob("test_*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        cases.extend((node.name, path.stem) for node in tree.body
                     if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith("test_"))
    return cases


def collect(raw_dir: Path, cases_dir: Optional[Path]) -> Tuple[IdCounts, Dict[str, Counter]]:
    counts, sources = read_raw(raw_dir)
    if cases_dir is not None:
        cases = tty_cases(cases_dir)
        for name, location in cases:
            counts[("tty:" + name, location, "listed")] += 1
        sources["tty-cases"] = Counter(listed=len(cases))
    return counts, sources


def format_ids(counts: IdCounts) -> str:
    return "".join(f"{test_id}\t{location}\t{status}\t{count}\n"
                   for (test_id, location, status), count in sorted(counts.items()) if count)


def parse_ids(text: str, origin: str = "test IDs") -> IdCounts:
    counts: IdCounts = Counter()
    for number, line in enumerate(text.splitlines(), 1):
        if not line:
            continue
        fields = line.split("\t")
        if (len(fields) != 4 or fields[0].split(":", 1)[0] not in KINDS or fields[2] not in SET_STATUSES
                or not fields[3].isdigit() or int(fields[3]) == 0):
            raise TestIdError(f"{origin}:{number}: malformed line {line!r}")
        entry = (fields[0], fields[1], fields[2])
        if entry in counts:
            raise TestIdError(f"{origin}:{number}: duplicate {fields[0]} in {fields[1]!r} {fields[2]}")
        counts[entry] = int(fields[3])
    return counts


def format_sources(sources: Dict[str, Counter]) -> str:
    return "".join(f"{source}: " + " ".join(f"{status}={tally[status]}" for status in sorted(tally)) + "\n"
                   for source, tally in sorted(sources.items()))


def parse_pairs(text: str, origin: str, what: str, allow_moves: bool = False) -> List[Tuple[str, str]]:
    pairs = []
    seen = set()
    for number, line in enumerate(text.splitlines(), 1):
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 2 or not all(f.strip() == f and f for f in fields):
            raise TestIdError(f"{origin}:{number}: expected <key><TAB><{what}>")
        if fields[0].split(":", 1)[0] not in KINDS and not (allow_moves and fields[0].startswith("@")):
            raise TestIdError(f"{origin}:{number}: {fields[0]!r} does not start with one of {', '.join(k + ':' for k in KINDS)}")
        if fields[0] in seen:
            raise TestIdError(f"{origin}:{number}: {fields[0]} is listed twice")
        seen.add(fields[0])
        pairs.append((fields[0], fields[1]))
    return pairs


def file_at(root: Path, rev: Optional[str], rel: Path) -> str:
    if rev is None:
        path = root / rel
        return path.read_text(encoding="utf-8") if path.exists() else ""
    proc = subprocess.run(["git", "show", f"{rev}:{rel.as_posix()}"], cwd=str(root), capture_output=True, check=False)
    return proc.stdout.decode("utf-8") if proc.returncode == 0 else ""


def read_explanations(root: Path, since: Optional[str] = None) -> Tuple[List[Tuple[str, str]], Dict[str, str]]:
    def pairs(rel: Path, what: str, rev: Optional[str]) -> List[Tuple[str, str]]:
        return parse_pairs(file_at(root, rev, rel), rel.as_posix() + (f"@{rev}" if rev else ""), what, rel == RENAMED)

    renamed = pairs(RENAMED, "new key", None)
    removed = pairs(REMOVED, "reason", None)
    for old, new in renamed:
        if old == new:
            raise TestIdError(f"{RENAMED.as_posix()}: {old} is renamed to itself")
        if old.startswith("@") != new.startswith("@"):
            raise TestIdError(f"{RENAMED.as_posix()}: {old} → {new} mixes a namespace move with a test key")
        if not old.startswith("@") and old.split(":", 1)[0] != new.split(":", 1)[0]:
            raise TestIdError(f"{RENAMED.as_posix()}: {old} and {new} are different kinds of test")
    if since is not None:
        renamed_before, removed_before = set(pairs(RENAMED, "new key", since)), set(pairs(REMOVED, "reason", since))
        renamed = [pair for pair in renamed if pair not in renamed_before]
        removed = [pair for pair in removed if pair not in removed_before]
    return renamed, dict(removed)


@dataclass
class Change:
    key: str
    base: Tuple[int, int]
    head: Tuple[int, int]
    note: str = ""

    def describe(self) -> str:
        text = f"`{self.key}`: {self.base[0]} pass / {self.base[1]} skip → {self.head[0]} pass / {self.head[1]} skip"
        return text + (f" ({self.note})" if self.note else "")


@dataclass
class Comparison:
    missing: List[Change] = field(default_factory=list)
    removed: List[Change] = field(default_factory=list)
    renamed: List[Change] = field(default_factory=list)
    added: List[Change] = field(default_factory=list)
    tty_missing: List[str] = field(default_factory=list)
    tty_added: List[str] = field(default_factory=list)
    unused: List[str] = field(default_factory=list)


def locations(counts: IdCounts) -> Dict[str, Set[str]]:
    found: Dict[str, Set[str]] = {}
    for (test_id, location, _), count in counts.items():
        if count:
            found.setdefault(test_id, set()).add(location)
    return found


def keyed(counts: IdCounts, key: Callable[[str, str], str]) -> Dict[str, List[int]]:
    table: Dict[str, List[int]] = {}
    for (test_id, location, status), count in counts.items():
        if test_id.split(":", 1)[0] in ENFORCED_KINDS:
            table.setdefault(key(test_id, location), [0, 0])[0 if status == "pass" else 1] += count
    return table


def apply_moves(location: str, moves: Sequence[Tuple[str, str]], used: Set[Tuple[str, str]]) -> str:
    for old, new in moves:
        if is_segment_prefix(new[1:], location):
            used.add((old, new))
            return old[1:] + location[len(new) - 1:]
    return location


def is_segment_prefix(prefix: str, namespace: str) -> bool:
    return namespace == prefix or namespace.startswith(prefix + ".")


def compare(base: IdCounts, head: IdCounts, renamed: Sequence[Tuple[str, str]], removed: Dict[str, str]) -> Comparison:
    result = Comparison()
    moves = [pair for pair in renamed if pair[0].startswith("@")]
    renamed = [pair for pair in renamed if not pair[0].startswith("@")]
    used_moves: Set[Tuple[str, str]] = set()
    moved: IdCounts = Counter()
    for (test_id, location, status), count in head.items():
        moved[(test_id, apply_moves(location, moves, used_moves), status)] += count
    head = moved
    result.unused.extend(f"{RENAMED.as_posix()}: {old} → {new}" for old, new in moves if (old, new) not in used_moves)
    base_locations, head_locations = locations(base), locations(head)

    def key(test_id: str, location: str) -> str:
        if len(base_locations.get(test_id, ())) <= 1 and len(head_locations.get(test_id, ())) <= 1:
            return test_id
        return f"{test_id} @{location}"

    base_table = keyed(base, key)
    head_table = keyed(head, key)
    original_head = {test_key: tuple(pair) for test_key, pair in head_table.items()}
    renamed_from: Dict[str, str] = {}
    for old, new in renamed:
        old_base = base_table.get(old, [0, 0])
        old_head = head_table.setdefault(old, [0, 0])
        new_base = base_table.get(new, [0, 0])
        new_head = head_table.get(new, [0, 0])
        moved = [max(0, min(new_head[i] - new_base[i], old_base[i] - old_head[i])) for i in range(2)]
        if not any(moved):
            result.unused.append(f"{RENAMED.as_posix()}: {old} → {new}")
            continue
        for i in range(2):
            old_head[i] += moved[i]
            new_head[i] -= moved[i]
        head_table[new] = new_head
        renamed_from[old] = new
    used_removed = set()
    for test_key in sorted(set(base_table) | set(head_table)):
        base_pair = tuple(base_table.get(test_key, (0, 0)))
        head_pair = tuple(head_table.get(test_key, (0, 0)))
        shown_head = original_head.get(test_key, (0, 0))
        lost_runs = base_pair[0] > head_pair[0]
        lost_tests = sum(base_pair) > sum(head_pair)
        if lost_runs or lost_tests:
            note = "no longer runs" if lost_runs and not lost_tests else ""
            if test_key in removed:
                used_removed.add(test_key)
                result.removed.append(Change(test_key, base_pair, shown_head, removed[test_key]))
            else:
                result.missing.append(Change(test_key, base_pair, shown_head, note))
        elif test_key in renamed_from:
            new = renamed_from[test_key]
            result.renamed.append(Change(test_key, base_pair, original_head.get(new, (0, 0)), f"now `{new}`"))
        elif sum(head_pair) > sum(base_pair) or head_pair[0] > base_pair[0]:
            result.added.append(Change(test_key, base_pair, shown_head))
    result.unused.extend(f"{REMOVED.as_posix()}: {test_key}" for test_key in sorted(set(removed) - used_removed))
    base_tty = {test_id for (test_id, _, _), count in base.items() if test_id.startswith("tty:") and count}
    head_tty = {test_id for (test_id, _, _), count in head.items() if test_id.startswith("tty:") and count}
    result.tty_missing = sorted(base_tty - head_tty)
    result.tty_added = sorted(head_tty - base_tty)
    return result


def kind_totals(counts: IdCounts) -> Dict[Tuple[str, str], int]:
    totals: Dict[Tuple[str, str], int] = Counter()
    for (test_id, _, status), count in counts.items():
        totals[(test_id.split(":", 1)[0], status)] += count
    return totals


def bullet_list(title: str, items: Sequence[str]) -> List[str]:
    if not items:
        return []
    lines = [f"**{title}** ({len(items)})", ""]
    lines.extend(f"- {item}" for item in items[:SUMMARY_LIST_LIMIT])
    if len(items) > SUMMARY_LIST_LIMIT:
        lines.append(f"- … and {len(items) - SUMMARY_LIST_LIMIT} more")
    return lines + [""]


def render(comparison: Comparison, base: IdCounts, head: IdCounts, base_note: str, enforced: bool) -> str:
    base_totals, head_totals = kind_totals(base), kind_totals(head)
    lines = ["## Executed test IDs", "", base_note, "",
             "| kind | status | base | head |", "|---|---|---|---|"]
    for kind in KINDS:
        for status in SET_STATUSES:
            if base_totals[(kind, status)] or head_totals[(kind, status)]:
                lines.append(f"| {kind} | {status} | {base_totals[(kind, status)]} | {head_totals[(kind, status)]} |")
    lines.append("")
    if comparison.missing:
        verdict = "fails: this is a migration PR" if enforced else "report only: the PR has no `migration` label"
        lines += [f"Tests that no longer run, unexplained — {verdict}. Add each key below to `{RENAMED.as_posix()}` or `{REMOVED.as_posix()}` in this PR.", ""]
    else:
        lines += ["Every test the base ran still runs, or this PR explains why not.", ""]
    lines += bullet_list("Missing", [change.describe() for change in comparison.missing])
    lines += bullet_list("Removed (explained in this PR)", [change.describe() for change in comparison.removed])
    lines += bullet_list("Renamed", [change.describe() for change in comparison.renamed])
    lines += bullet_list("Added", [change.describe() for change in comparison.added])
    lines += bullet_list("TTY cases gone (not enforced)", comparison.tty_missing)
    lines += bullet_list("TTY cases added", comparison.tty_added)
    lines += bullet_list("Explanations this PR adds that explain nothing", comparison.unused)
    return "\n".join(lines) + "\n"


def recording_result_class(source: str, root: str = ""):
    directory = os.environ.get(IDS_DIR_ENV)
    if not directory:
        return None

    class RecordingResult(unittest.TextTestResult):
        def startTestRun(self):
            super().startTestRun()
            handle, path = tempfile.mkstemp(prefix=f"py-{source}--", suffix=".tsv", dir=directory)
            self._test_ids = os.fdopen(handle, "w", encoding="utf-8")
            self._test_ids.write(f"root\t{root}\n")

        def stopTestRun(self):
            self._test_ids.close()
            super().stopTestRun()

        def _record(self, status, test):
            self._test_ids.write(f"{status}\t{test.id()}\n")
            self._test_ids.flush()

        def addSuccess(self, test):
            super().addSuccess(test)
            self._record("pass", test)

        def addExpectedFailure(self, test, err):
            super().addExpectedFailure(test, err)
            self._record("pass", test)

        def addSkip(self, test, reason):
            super().addSkip(test, reason)
            self._record("skip", test)

        def addFailure(self, test, err):
            super().addFailure(test, err)
            self._record("fail", test)

        def addError(self, test, err):
            super().addError(test, err)
            self._record("fail", test)

        def addUnexpectedSuccess(self, test):
            super().addUnexpectedSuccess(test)
            self._record("fail", test)

    return RecordingResult


def record_unittest_results(source: str) -> None:
    result_class = recording_result_class(source)
    if result_class is not None:
        unittest.TextTestRunner.resultclass = result_class


def github_json(path: str):
    proc = subprocess.run(["gh", "api", path], capture_output=True, check=True)
    return json.loads(proc.stdout)


def download_ids(repository: str, run_id: int) -> Optional[Tuple[IdCounts, dict]]:
    with tempfile.TemporaryDirectory(prefix="metacodes-test-ids-") as tmp:
        proc = subprocess.run(["gh", "run", "download", str(run_id), "--repo", repository, "--name", ARTIFACT, "--dir", tmp],
                              capture_output=True, check=False)
        if proc.returncode:
            return None
        try:
            meta = json.loads((Path(tmp) / "test-ids-meta.json").read_text(encoding="utf-8"))
            return parse_ids((Path(tmp) / "test-ids.tsv").read_text(encoding="utf-8")), meta
        except (OSError, ValueError, TestIdError):
            return None


def candidate_runs(repository: str, sha: str, query: Callable = github_json) -> Iterable[dict]:
    for pr in query(f"repos/{repository}/commits/{sha}/pulls?per_page=100"):
        if pr.get("merged_at") and pr.get("merge_commit_sha") == sha:
            yield from query(f"repos/{repository}/actions/workflows/{CI_WORKFLOW}/runs?head_sha={pr['head']['sha']}&event=pull_request&per_page=20")["workflow_runs"]
    for event in ("schedule", "workflow_dispatch"):
        yield from query(f"repos/{repository}/actions/workflows/{CI_WORKFLOW}/runs?branch=main&event={event}&head_sha={sha}&per_page=20")["workflow_runs"]


def latest_main_runs(repository: str, query: Callable = github_json) -> List[dict]:
    runs = []
    for event in ("schedule", "workflow_dispatch"):
        runs.extend(query(f"repos/{repository}/actions/workflows/{CI_WORKFLOW}/runs?branch=main&event={event}&status=completed&per_page=10")["workflow_runs"])
    return sorted(runs, key=lambda run: run.get("created_at", ""), reverse=True)


@dataclass
class Base:
    counts: Optional[IdCounts]
    note: str
    exact: bool


def find_base(repository: str, sha: str, tree: str, query: Callable = github_json,
              download: Callable = download_ids) -> Base:
    for run in candidate_runs(repository, sha, query):
        found = download(repository, run["id"])
        if found is not None and found[1].get("tree") == tree:
            return Base(found[0], f"Base: `{sha[:12]}`, IDs from run {run['id']} on the same tree.", True)
    for run in latest_main_runs(repository, query):
        found = download(repository, run["id"])
        if found is not None:
            return Base(found[0], (f"Base: `{sha[:12]}` has no recorded IDs; comparing with main's run {run['id']} on "
                                   f"`{str(found[1].get('commit', ''))[:12]}` instead, which is only good for a report."), False)
    return Base(None, f"Base: `{sha[:12]}` has no recorded IDs and main has no run with them; nothing to compare.", False)


def git(*argv: str) -> str:
    return subprocess.check_output(["git", *argv], cwd=str(ROOT), text=True).strip()


def pr_labels(repository: str, pr: int, query: Callable = github_json) -> List[str]:
    return [label["name"] for label in query(f"repos/{repository}/issues/{pr}/labels?per_page=100")]


def ci_report(head: IdCounts, base: Base, renamed, removed, enforced: bool) -> Tuple[str, bool]:
    if base.counts is not None and (base.exact or not enforced):
        comparison = compare(base.counts, head, renamed, removed)
        return render(comparison, base.counts, head, base.note, enforced), enforced and bool(comparison.missing)
    report = f"## Executed test IDs\n\n{base.note}\n"
    if enforced:
        report += ("\nA migration PR is compared only with IDs recorded on its base's own tree, so this fails. "
                   "Run CI on main (`gh workflow run ci.yml --ref main`) once main's head is the PR's base, "
                   "or merge main into the PR after a main run recorded its IDs, then re-run this job.\n")
    return report, enforced


def judge(head: IdCounts, base_sha: str, repository: str, enforced: bool, root: Path = ROOT,
          base_finder: Callable = find_base) -> Tuple[str, bool]:
    renamed, removed = read_explanations(root, base_sha)
    tree = subprocess.check_output(["git", "rev-parse", base_sha + "^{tree}"], cwd=str(root), text=True).strip()
    return ci_report(head, base_finder(repository, base_sha, tree), renamed, removed, enforced)


def cmd_collect(args) -> int:
    counts, sources = collect(Path(args.raw), Path(args.tty) if args.tty else None)
    text = format_ids(counts)
    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_bytes(text.encode("utf-8"))
        sys.stderr.write(format_sources(sources))
    else:
        sys.stdout.flush()
        sys.stdout.buffer.write(text.encode("utf-8"))
    if args.meta:
        meta = {"commit": git("rev-parse", "HEAD"), "tree": git("rev-parse", "HEAD^{tree}")}
        Path(args.meta).write_text(json.dumps(meta, sort_keys=True) + "\n", encoding="utf-8")
    return 0


def cmd_compare(args) -> int:
    base = parse_ids(Path(args.base).read_text(encoding="utf-8"), args.base)
    head = parse_ids(Path(args.head).read_text(encoding="utf-8"), args.head)
    renamed, removed = read_explanations(Path(args.root), args.since)
    comparison = compare(base, head, renamed, removed)
    sys.stdout.write(render(comparison, base, head, f"Base: `{args.base}`.", args.enforce))
    return 1 if args.enforce and comparison.missing else 0


def write_report(report: str, summary: Optional[str]) -> None:
    sys.stdout.write(report)
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(report)


def cmd_ci_compare(args) -> int:
    head = parse_ids(Path(args.head).read_text(encoding="utf-8"), args.head)
    enforced = MIGRATION_LABEL in pr_labels(args.repository, args.pr)
    report, failed = judge(head, git("rev-parse", args.base), args.repository, enforced)
    write_report(report, args.summary)
    return 1 if failed else 0


def cmd_check(args) -> int:
    read_explanations(Path(args.root))
    return 0


def cmd_run(args) -> int:
    command = args.command or ["zig", "build", "test"]
    with tempfile.TemporaryDirectory(prefix="metacodes-test-ids-") as tmp:
        status = subprocess.run(command, cwd=str(ROOT), env={**os.environ, IDS_DIR_ENV: tmp}, check=False).returncode
        if status:
            sys.stderr.write(f"{' '.join(command)} exited with {status}\n")
            return status
        args.raw, args.tty, args.meta = tmp, str(ROOT / TTY_CASES), None
        return cmd_collect(args)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="List the tests a run executed by an ID that survives moving files, and compare two lists.")
    commands = parser.add_subparsers(dest="command_name", required=True)
    run = commands.add_parser("run", help=f"run `zig build test` (or the command after --) with {IDS_DIR_ENV} set and print the IDs")
    run.add_argument("--output")
    run.add_argument("command", nargs=argparse.REMAINDER)
    run.set_defaults(handler=cmd_run)
    collect_parser = commands.add_parser("collect", help=f"turn the records written under {IDS_DIR_ENV} into an ID list")
    collect_parser.add_argument("--raw", required=True)
    collect_parser.add_argument("--tty")
    collect_parser.add_argument("--output")
    collect_parser.add_argument("--meta")
    collect_parser.set_defaults(handler=cmd_collect)
    compare_parser = commands.add_parser("compare", help="compare a base and a head ID list")
    compare_parser.add_argument("--base", required=True)
    compare_parser.add_argument("--head", required=True)
    compare_parser.add_argument("--root", default=str(ROOT))
    compare_parser.add_argument("--since", help="count only the explanations added after this revision")
    compare_parser.add_argument("--enforce", action="store_true")
    compare_parser.set_defaults(handler=cmd_compare)
    ci = commands.add_parser("ci-compare", help="compare with the base's recorded IDs; enforced on migration PRs")
    ci.add_argument("--head", required=True)
    ci.add_argument("--base", required=True)
    ci.add_argument("--repository", required=True)
    ci.add_argument("--pr", type=int, required=True)
    ci.add_argument("--summary")
    ci.set_defaults(handler=cmd_ci_compare)
    check = commands.add_parser("check", help=f"check the format of {RENAMED.as_posix()} and {REMOVED.as_posix()}")
    check.add_argument("--root", default=str(ROOT))
    check.set_defaults(handler=cmd_check)
    args = parser.parse_args(argv)
    if args.command_name == "run" and args.command[:1] == ["--"]:
        args.command = args.command[1:]
    try:
        return args.handler(args)
    except TestIdError as exc:
        sys.stderr.write(f"test_ids: {exc}\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
