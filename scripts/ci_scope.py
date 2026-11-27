#!/usr/bin/env python3
"""Decide which of CI's suites a change can affect.

Design: doc/CI_DESIGN.md §2, "Change scope". The gate legs, TTY shards and
the result jobs over them (the required checks) always run and report under
their own names; the legs' and shards' expensive steps read the scope decided
here, so a change that cannot affect a suite does not pay for it. Skipping
whole jobs instead would leave a matrix job unnamed and a required check
pending or, for a skipped result job, passing (the `on.pull_request.paths`
filter of #134 blocked PRs the same way).

Scopes, narrowest first:

- `docs`: `doc/**`, top-level Markdown, the sources in
  release/documents.json, and protocol edits confined to documentation
  entries in implementation_paths. Removals and moves remain documents;
  path type changes run in full. Links/facts, version state and gate
  manifest run; suites and TTY do not. Independent doc_references and
  release_docs outputs select protocol path/pin validation and the real
  documents-only release copy/verification steps, respectively.
- `eval`: every changed path is documentation or the Python evaluation
  harness (`scripts/eval/**`, `evals/**`). The gates run in full, since
  `zig build test` runs the harness's suites and smokes against the built
  binary; the TTY suites, which drive the interactive binary and read
  neither, report success without running: `suites=true`, `tty=false`.
- `tests`: every changed path is documentation, the evaluation harness or
  a test: `scripts/tests/test_*.py` (a suite build.zig names runs in
  test:units, on Windows too; `script_tests` names the others),
  `tests/tty/cases/**` (`tty=true`), or another file of the `tests` package in
  layers.zon, which may be a fixture both suites read (`units`, `product`
  and `tty` run). The gate legs run their checks; a suite no changed test
  belongs to reports success without running.
- `packages`: every changed path is one of the above or a file of a product
  package in layers.zon, and every package in the affected set (the changed
  packages and every package that depends on them, directly or not) has no
  entry left in layer_baseline.zon and a `test:<package>` build step. Only
  then is the declared dependency graph the real one, so the unit step runs
  `package_tests` (those steps) instead of `test:units`; integration,
  product, TTY and the contract snapshots still run. A test kept inside a
  product package's directory (`apps/cli/tests/`, in the `tests` package of
  layers.zon) is that package's change: its `test:<package>` runs it.
- `full`: anything else, every manual run, an empty diff, a `migration`
  pull request (its test IDs are compared on a complete run), a package with
  a baseline entry or without its test step anywhere in the affected set,
  and any error: `suites=true`, `tty=true`.

ci.yml: `ci_scope.py --event "$GITHUB_EVENT_NAME" --base <rev> --candidate
HEAD --github-output "$GITHUB_OUTPUT"`, with the base `HEAD^1` on a pull
request (the merge commit's base) and the group's `base_sha` in a merge
queue. It writes scope, suites, tty, units, product, packages,
package_tests, script_tests, complete, doc_references, release_docs and
reason outputs. It always exits 0: a doubt is the full scope, never a red
job. `--event local --run` (`zig build test:affected`) applies the same
decision to the working tree against origin/main and runs what it selects;
`merged` reports the scope each merged pull request's CI run recorded
(`--record`; the nightly run's summary), and `replay` recomputes the
decision for commits already on main, to measure the rules. Python 3.9, stdlib only; tests in scripts/tests/test_ci_scope.py.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass, replace
from pathlib import Path, PurePosixPath
from typing import Callable, Dict, List, Optional, Sequence, Tuple

ROOT = Path(__file__).resolve().parents[1]
# Manual and unknown events always run in full.
DIFF_EVENTS = ("pull_request", "merge_group", "local")
# Defaults for pure-function callers; main reads all release sources from the
# same manifest as build.zig, including licence files outside the doc tree.
RELEASE_DOCS = ("README.md", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md")
PROTOCOL = "evals/plugin-v1/protocol.json"
EVAL_PREFIXES = ("scripts/eval/", "evals/")
LAYERS = "layers.zon"
LAYER_BASELINE = "layer_baseline.zon"
BUILD = "build.zig"
SCRIPT_TESTS = "scripts/tests/"
TTY_TESTS = "tests/tty/"
TTY_DOMAINS = "tests/tty/domains.json"
TESTS_PACKAGE = "tests"
TEST_PACKAGES = ("testing", TESTS_PACKAGE)
CLI_NO_TTY_PREFIXES = ("apps/cli/src/web/", "apps/cli/src/daemon/")
CLI_PROVIDER_TTY_FILES = (
    "apps/cli/src/repl/model_picker.zig",
    "apps/cli/src/repl/model_picker_view.zig",
    "apps/cli/src/repl/next_step.zig",
)
AGENTCORE_SDK_PREFIXES = ("sdk/python/", "sdk/node/", "sdk/rust/")
AGENTCORE_SDK_FILES = (
    "sdk/metask/agentcore.h",
    "sdk/zig/protocol.zig",
    "sdk/zig/root.zig",
    "sdk/zig/build.zig",
)
TEST_STEP = re.compile(r'\bb\.step\(\s*"(test:[\w-]+)"')
BUILD_SCRIPT_SUITE = re.compile(r'"(scripts\.tests\.test_\w+)"')
MIGRATION_LABEL = "migration"
SHOWN = 5


def is_docs(path: str, release_sources: Sequence[str] = RELEASE_DOCS) -> bool:
    if path in release_sources:
        return True
    if path.startswith("doc/"):
        return True
    return "/" not in path and path.endswith(".md")


def is_eval(path: str) -> bool:
    return path.startswith(EVAL_PREFIXES)


def _shown(paths: Sequence[str]) -> str:
    listed = ", ".join(paths[:SHOWN])
    return listed + (f" and {len(paths) - SHOWN} more" if len(paths) > SHOWN else "")


ZON_TOKENS = re.compile(r'//[^\n]*|\s+|\.\{|\}|,|\.[A-Za-z_]\w*\s*=|"(?:[^"\\\n]|\\.)*"|-?\d+|(.)')


def parse_zon(text: str):
    """The subset of ZON layers.zon and layer_baseline.zon use: structs become
    dicts, tuples lists, strings and integers themselves."""
    tokens = []
    for match in ZON_TOKENS.finditer(text):
        if match.group(1) is not None:
            raise ValueError(f"unexpected {match.group(1)!r} in ZON at offset {match.start()}")
        token = match.group()
        if not (token.isspace() or token.startswith("//")):
            tokens.append(token)
    value, end = _zon_value(tokens, 0)
    if end != len(tokens):
        raise ValueError("trailing tokens after the ZON value")
    return value


def _zon_value(tokens: List[str], index: int):
    token = tokens[index]
    if token.startswith('"'):
        return json.loads(token), index + 1
    if token.lstrip("-").isdigit():
        return int(token), index + 1
    if token != ".{":
        raise ValueError(f"unexpected {token!r} in ZON")
    index += 1
    fields: Dict[str, object] = {}
    items: List[object] = []
    while tokens[index] != "}":
        if tokens[index].endswith("="):
            name = tokens[index][1:-1].strip()
            fields[name], index = _zon_value(tokens, index + 1)
        else:
            item, index = _zon_value(tokens, index)
            items.append(item)
        if tokens[index] == ",":
            index += 1
        elif tokens[index] != "}":
            raise ValueError(f"expected ',' or '}}' in ZON, found {tokens[index]!r}")
    if fields and items:
        raise ValueError("a ZON value mixes fields and items")
    return (fields if fields else items), index + 1


@dataclass(frozen=True)
class Layout:
    """layers.zon's packages, the layer_baseline.zon entries charged to each,
    and the `test:*` steps build.zig declares."""
    order: Tuple[str, ...]
    paths: Tuple[Tuple[str, str], ...]
    dependencies: Dict[str, Tuple[str, ...]]
    violations: Dict[str, int]
    test_steps: frozenset
    build_suites: frozenset = frozenset()

    def owner(self, path: str, among: Optional[Sequence[str]] = None) -> Optional[str]:
        best, best_len = None, -1
        for entry, package in self.paths:
            if among is not None and package not in among:
                continue
            matches = path.startswith(entry) if entry.endswith("/") else path == entry
            if matches and len(entry) >= best_len:
                best, best_len = package, len(entry)
        return best

    def package(self, path: str) -> Optional[str]:
        """The product package whose tests a change to `path` selects: its
        owner, or for a test kept inside a product package's directory
        (apps/cli/tests/ in cli's apps/cli/), that package."""
        owner = self.owner(path)
        if owner in TEST_PACKAGES:
            return self.owner(path, among=self.products)
        if owner in self.products:
            return owner
        if "agentcore" in self.products and (path.startswith(AGENTCORE_SDK_PREFIXES) or path in AGENTCORE_SDK_FILES):
            return "agentcore"
        return None

    @property
    def products(self) -> Tuple[str, ...]:
        return tuple(package for package in self.order if package not in TEST_PACKAGES)

    def affected(self, changed: Sequence[str]) -> Tuple[str, ...]:
        """The changed packages and every product package that depends on
        one of them, directly or not, in layers.zon order."""
        found = set(changed)
        grew = True
        while grew:
            grew = False
            for package in self.products:
                if package not in found and found & set(self.dependencies[package]):
                    found.add(package)
                    grew = True
        return tuple(package for package in self.order if package in found)

    def cleared(self) -> "Layout":
        """The layout once every package is out of the baseline and has its
        test step: what the replay reports as the migration's end state."""
        return replace(self, violations={}, test_steps=frozenset(f"test:{package}" for package in self.products))


def load_layout(read: Callable[[str], str]) -> Layout:
    manifest = parse_zon(read(LAYERS))
    baseline = parse_zon(read(LAYER_BASELINE)) or {}
    build = read(BUILD)
    packages = manifest["packages"]
    layout = Layout(
        order=tuple(package["name"] for package in packages),
        paths=tuple((entry, package["name"]) for package in packages for entry in package["paths"]),
        dependencies={package["name"]: tuple(package["allowed_dependencies"]) for package in packages},
        violations={},
        test_steps=frozenset(TEST_STEP.findall(build)),
        build_suites=frozenset(BUILD_SCRIPT_SUITE.findall(build)),
    )
    violations: Counter = Counter()

    def charge(*files: str) -> None:
        for package in {layout.owner(path) for path in files} - {None}:
            violations[package] += 1

    for source, target in list(baseline.get("upward", [])) + list(baseline.get("deep", [])):
        charge(source, target)
    for cycle in baseline.get("cycles", []):
        violations.update(set(cycle))
    for root, _ in baseline.get("wiring", []):
        charge(root)
    for root in baseline.get("wide_roots", []):
        charge(root)
    return replace(layout, violations=dict(violations))


def path_kind(path: str, layout: Optional[Layout], release_sources: Sequence[str] = RELEASE_DOCS,
              document_protocol: bool = False) -> str:
    """docs, eval, script-test, tty-test, suite-test, package or full."""
    if is_docs(path, release_sources) or (path == PROTOCOL and document_protocol):
        return "docs"
    if is_eval(path):
        return "eval"
    if path.startswith(SCRIPT_TESTS):
        name = path[len(SCRIPT_TESTS):]
        return "script-test" if "/" not in name and name.startswith("test_") and name.endswith(".py") else "full"
    if layout is None:
        return "full"
    if layout.package(path) is not None:
        return "package"
    if layout.owner(path) == TESTS_PACKAGE:
        return "tty-test" if path.startswith(TTY_TESTS + "cases/") else "suite-test"
    return "full"


def classify(paths: Sequence[str], deleted: Sequence[str] = (), *,
             document_protocol: bool = False,
             release_sources: Sequence[str] = RELEASE_DOCS,
             layout: Optional[Layout] = None) -> Tuple[str, str]:
    """(scope, reason) for the changed `paths`, of which `deleted` were
    removed or changed type (a rename is a removal plus an addition)."""
    if not paths:
        return "full", "full scope: the change has no paths"
    kinds = {path: path_kind(path, layout, release_sources, document_protocol) for path in paths}
    if all(kind == "docs" for kind in kinds.values()):
        return "docs", f"docs scope: only documents or their protocol paths changed ({_shown(paths)}); references and release documents are checked independently"
    outside = [path for path in paths if kinds[path] not in ("docs", "eval")]
    if not outside:
        return "eval", "eval scope: only documentation and the evaluation harness changed; the TTY suites are skipped"
    unknown = [path for path in outside if kinds[path] == "full"]
    if unknown:
        return "full", f"full scope: {_shown(unknown)} can affect every suite"
    changed = {layout.package(path) for path in outside if kinds[path] == "package"}
    if not changed:
        return "tests", f"tests scope: only tests changed ({_shown(outside)}); only the suites they belong to run"
    affected = layout.affected(sorted(changed))
    uncleared = [package for package in affected if layout.violations.get(package)]
    if uncleared:
        listed = ", ".join(f"{package} ({layout.violations[package]})" for package in uncleared)
        return "full", f"full scope: affected packages still have {LAYER_BASELINE} entries, so their imports are not yet the declared dependencies: {listed}"
    untested = [package for package in affected if f"test:{package}" not in layout.test_steps]
    if untested:
        return "full", f"full scope: affected packages have no test:<package> step in {BUILD}: {', '.join(untested)}"
    ordered = [package for package in layout.order if package in changed]
    if affected == layout.products:
        return "full", f"full scope: {', '.join(ordered)} affects every product package, so the full suite runs"
    return "packages", f"packages scope: {', '.join(ordered)} changed; the affected packages are {', '.join(affected)}"


@dataclass(frozen=True)
class TtyDomains:
    domains: Dict[str, Tuple[str, ...]]
    by_module: Dict[str, Tuple[str, ...]]


def load_tty_domains(read: Callable[[str], str]) -> TtyDomains:
    data = json.loads(read(TTY_DOMAINS))
    if not isinstance(data, dict) or data.get("schema") != "metacodes.tty-domains/v1":
        raise ValueError(f"invalid tty domains schema in {TTY_DOMAINS}")
    raw = data.get("domains")
    if not isinstance(raw, dict) or not raw:
        raise ValueError(f"invalid tty domains mapping in {TTY_DOMAINS}")
    domains: Dict[str, Tuple[str, ...]] = {}
    by_module: Dict[str, List[str]] = {}
    for name, modules in raw.items():
        if not isinstance(name, str) or not name or not isinstance(modules, list) or not modules:
            raise ValueError(f"invalid tty domain entry: {name!r}")
        if not all(isinstance(mod, str) and mod.startswith("test_") for mod in modules):
            raise ValueError(f"invalid module name in tty domain {name!r}")
        if len(modules) != len(set(modules)):
            raise ValueError(f"duplicate module in tty domain {name!r}")
        domains[name] = tuple(modules)
        for mod in modules:
            by_module.setdefault(mod, []).append(name)
    return TtyDomains(
        domains=domains,
        by_module={mod: tuple(sorted(names)) for mod, names in by_module.items()},
    )


def read_optional_tty_domains(root: Path, rev: Optional[str]) -> Optional[TtyDomains]:
    if rev is None:
        if not (root / TTY_DOMAINS).is_file():
            return None
    else:
        listed = git_bytes(root, "ls-tree", "--name-only", rev, "--", TTY_DOMAINS).decode("utf-8").strip()
        if not listed:
            return None
    return load_tty_domains(tree_reader(root, rev))


@dataclass(frozen=True)
class Selection:
    """What a scope runs. `package_tests`, when set, replaces `test:units`."""
    suites: bool
    tty: bool
    units: bool
    product: bool
    sdk: bool = True
    integration: bool = True
    release: bool = True
    packages: Tuple[str, ...] = ()
    package_tests: Tuple[str, ...] = ()
    script_tests: Tuple[str, ...] = ()
    tty_domains: Tuple[str, ...] = ()
    offline_eval: bool = True

    @property
    def complete(self) -> bool:
        """Every Zig and script suite of `zig build test` runs, so the run's
        test IDs are comparable with a full run's (scripts/test_ids.py)."""
        return (self.units and self.integration and self.product
                and self.release and self.offline_eval and not self.package_tests)


def path_tty_domains(
    status: str,
    path: str,
    kind: str,
    layout: Layout,
    tty_domains: Optional[TtyDomains],
) -> Optional[Tuple[str, ...]]:
    if kind in ("docs", "script-test"):
        return ()
    if kind == "tty-test":
        if status != "D" and tty_domains is not None:
            rest = path[len(TTY_TESTS + "cases/"):]
            if "/" not in rest and rest.startswith("test_") and rest.endswith(".py"):
                stem = rest[:-3]
                if stem in tty_domains.by_module:
                    return tty_domains.by_module[stem]
        return None
    if kind in ("suite-test", "eval"):
        return None
    if kind == "package":
        package = layout.package(path)
        if package == "agentcore":
            return ()
        if package == "cli" and path.startswith(CLI_NO_TTY_PREFIXES):
            return ()
        if package in ("lsp", "jev", "telemetry"):
            return ("smoke",)
        if package == "teamwork" or path == "apps/cli/src/repl/teamwork.zig":
            return ("smoke", "teamwork")
        if package == "coding" and path.startswith("packages/coding/src/mcp/"):
            return ("mcp", "smoke")
        if package == "coding" and path.startswith("packages/coding/src/kg/"):
            return ("kg", "smoke")
        if package == "cli" and path in CLI_PROVIDER_TTY_FILES:
            return ("provider", "smoke")
        return None
    return None


def _resolve_tty(
    changes: Sequence["Change"],
    kinds: Dict[str, str],
    layout: Layout,
    tty_domains: Optional[TtyDomains],
) -> Tuple[bool, Tuple[str, ...]]:
    if not changes:
        return True, ()
    selected = set()
    full_tty = False
    for status, path in changes:
        domains = path_tty_domains(status, path, kinds[path], layout, tty_domains)
        if domains is None:
            full_tty = True
            break
        selected.update(domains)
    if full_tty:
        return True, ()
    if not selected:
        return False, ()
    if tty_domains is not None and selected.issubset(tty_domains.domains):
        return True, tuple(sorted(selected))
    return True, ()


def select(scope: str, changes: Sequence["Change"] = (), layout: Optional[Layout] = None,
           release_sources: Sequence[str] = RELEASE_DOCS,
           tty_domains: Optional[TtyDomains] = None) -> Selection:
    if scope == "docs":
        return Selection(suites=False, tty=False, sdk=False, units=False,
                         integration=False, product=False, release=False, offline_eval=False)
    if scope == "eval":
        return Selection(suites=True, tty=False, sdk=False, units=True,
                         integration=True, product=True, release=True)
    if scope not in ("tests", "packages") or layout is None:
        return Selection(suites=True, tty=True, sdk=True, units=True,
                         integration=True, product=True, release=True,
                         packages=layout.products if layout else ())
    kinds = {path: path_kind(path, layout, release_sources) for _, path in changes}
    modules = {"scripts.tests." + PurePosixPath(path).stem
               for status, path in changes if status != "D" and kinds[path] == "script-test"}
    # A shared fixture under tests/ can feed the TTY cases as well as the Zig
    # suites; a script suite build.zig names runs in test:units on every
    # platform, Windows included, so it keeps test:units.
    suites = any(kind in ("suite-test", "eval") for kind in kinds.values())
    units = suites or bool(modules & layout.build_suites)
    if scope == "tests":
        tty_changes = [(status, path) for status, path in changes if kinds[path] in ("tty-test", "suite-test")]
        tty, selected_domains = _resolve_tty(tty_changes, kinds, layout, tty_domains) if tty_changes else (False, ())
        chosen = Selection(suites=True, tty=tty, tty_domains=selected_domains, sdk=suites, units=units,
                           integration=units, product=suites, release=suites)
    else:
        affected = layout.affected(sorted({layout.package(path) for path, kind in kinds.items() if kind == "package"}))
        package_tests = () if units else tuple(f"test:{package}" for package in affected)
        cli_affected = suites or ("cli" in affected) or ("cli" not in layout.products)
        sdk_affected = suites or ("agentcore" in affected) or ("agentcore" not in layout.products)
        tty, selected_domains = _resolve_tty(changes, kinds, layout, tty_domains)
        chosen = Selection(suites=True, tty=tty, tty_domains=selected_domains, sdk=sdk_affected, units=True,
                           integration=cli_affected, product=cli_affected, release=cli_affected,
                           packages=affected, package_tests=package_tests)
    offline_eval = chosen.product and any(
        kind not in ("docs", "script-test", "tty-test") and not path.startswith(("apps/cli/src/repl/tui/", "apps/cli/tests/"))
        for path, kind in kinds.items()
    )
    chosen = replace(chosen, offline_eval=offline_eval)
    if chosen.complete:
        return chosen
    return replace(chosen, script_tests=tuple(sorted(modules - layout.build_suites)))


Change = Tuple[str, str]  # (git status letter, path)


@dataclass(frozen=True)
class DocumentInputs:
    release_sources: frozenset[str]
    protocol_paths: frozenset[str]


def protocol_paths(value: dict) -> list[str]:
    paths = value["implementation_paths"]
    if not isinstance(paths, list) or not paths or not all(isinstance(path, str) for path in paths):
        raise ValueError("invalid protocol implementation_paths")
    if len(paths) != len(set(paths)):
        raise ValueError("duplicate protocol implementation_paths")
    for path in paths:
        parsed = PurePosixPath(path)
        if parsed.is_absolute() or parsed.as_posix() != path or ".." in parsed.parts or "\\" in path:
            raise ValueError(f"unsafe protocol path: {path!r}")
    return paths


def document_inputs(root: Path) -> DocumentInputs:
    from check_release_docs import documents
    release_sources = frozenset(source for source, _ in documents(root))
    protocol = json.loads((root / PROTOCOL).read_text(encoding="utf-8"))
    return DocumentInputs(release_sources, frozenset(protocol_paths(protocol)))


def protocol_documents_only(before: dict, after: dict, release_sources: Sequence[str] = RELEASE_DOCS) -> bool:
    """Only the documentation entries of implementation_paths may change.

    Every other field, including budgets, runtime pins, source inputs and
    the frozen implementation fingerprint, retains its original value.
    """
    old_paths, new_paths = protocol_paths(before), protocol_paths(after)
    old = {key: value for key, value in before.items() if key != "implementation_paths"}
    new = {key: value for key, value in after.items() if key != "implementation_paths"}
    return (json.dumps(old, sort_keys=True) == json.dumps(new, sort_keys=True)
            and ([path for path in old_paths if not is_docs(path, release_sources)]
                 == [path for path in new_paths if not is_docs(path, release_sources)]))


def document_checks(scope: str, changes: Sequence[Change], inputs: DocumentInputs) -> Tuple[bool, bool]:
    if scope != "docs":
        return True, True
    paths = {path for _, path in changes}
    return (PROTOCOL in paths or bool(paths & inputs.protocol_paths), bool(paths & inputs.release_sources))


def git_bytes(root: Path, *argv: str) -> bytes:
    proc = subprocess.run(["git", *argv], cwd=str(root), capture_output=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"git {argv[0]} failed: {proc.stderr.decode('utf-8', 'replace').strip()}")
    return proc.stdout


def changed_paths(root: Path, base: str, candidate: Optional[str]) -> Tuple[Change, ...]:
    """The changes from `base` to `candidate`, or to the working tree and its
    untracked files when `candidate` is None."""
    revs = [base] if candidate is None else [base, candidate]
    out = git_bytes(root, "diff", "--name-status", "--no-renames", "-z", *revs)
    fields = [field for field in out.decode("utf-8").split("\0") if field]
    if len(fields) % 2:
        raise RuntimeError("git diff --name-status output is not status/path pairs")
    found = [(fields[i][:1], fields[i + 1]) for i in range(0, len(fields), 2)]
    if candidate is None:
        untracked = git_bytes(root, "ls-files", "--others", "--exclude-standard", "-z").decode("utf-8")
        found.extend(("A", path) for path in untracked.split("\0") if path)
    return tuple(found)


def tree_reader(root: Path, rev: Optional[str]) -> Callable[[str], str]:
    if rev is None:
        return lambda path: (root / path).read_text(encoding="utf-8")
    return lambda path: git_bytes(root, "show", f"{rev}:{path}").decode("utf-8")


def decide(
    event: str,
    base: str,
    candidate: Optional[str],
    changes: Callable[[str, Optional[str]], Sequence[Change]],
    protocol_change: Optional[Callable[[str, Optional[str]], bool]] = None,
    release_sources: Sequence[str] = RELEASE_DOCS,
    layout: Optional[Callable[[], Layout]] = None,
    labels: Sequence[str] = (),
) -> Tuple[str, str]:
    if event not in DIFF_EVENTS:
        return "full", f"full scope: {event or 'unknown'} run"
    if not base:
        return "full", f"full scope: no base for the {event} run"
    try:
        found = list(changes(base, candidate))
        if MIGRATION_LABEL in labels:
            return "full", f"full scope: a {MIGRATION_LABEL} pull request compares the complete set of executed test IDs"
        if "model-eval" in labels:
            return "full", "full scope: the model-eval label requests full offline evaluation"
        if any(status not in ("A", "M", "D") for status, _ in found):
            return "full", "full scope: a path changed type or has an unknown Git status"
        paths = [path for _, path in found]
        document_protocol = (PROTOCOL in paths and protocol_change is not None
                             and all(path == PROTOCOL or is_docs(path, release_sources) for path in paths)
                             and protocol_change(base, candidate))
        needs_layout = layout is not None and any(not (is_docs(path, release_sources) or is_eval(path)) for path in paths)
        scope, reason = classify(paths, [path for status, path in found if status == "D"],
                                 document_protocol=document_protocol, release_sources=release_sources,
                                 layout=layout() if needs_layout else None)
        return scope, reason
    except Exception as exc:  # any doubt is the full scope, never a red job
        return "full", f"full scope: the scope check failed: {exc}"


def write_summary(destination: str, event: str, base: str, candidate: str,
                  scope: str, reason: str, changes: Sequence[Change], *,
                  selection: Optional[Selection] = None,
                  doc_references: bool = True, release_docs: bool = True,
                  release_sources: Sequence[str] = RELEASE_DOCS,
                  layout: Optional[Layout] = None) -> None:
    """Explain the decision without treating Git paths as Markdown or HTML."""
    def cell(value: str) -> str:
        escaped = html.escape(" ".join(value.split()), quote=True)
        for char in "\\|`[]*_~":
            escaped = escaped.replace(char, f"&#{ord(char)};")
        return escaped

    def run(flag: bool) -> str:
        return "Run" if flag else "Skip"

    chosen = selection or select(scope)
    units = ("Run: " + " ".join(chosen.package_tests) + " instead of test:units") if chosen.units and chosen.package_tests else run(chosen.units)
    tty_label = ("Run (domains: " + ", ".join(chosen.tty_domains) + ")") if chosen.tty and chosen.tty_domains else run(chosen.tty)
    lines = ["### CI change attribution", "", f"Scope: **{scope}**", "", cell(reason), "",
             f"Event: {cell(event)}; base: {cell(base or '(none)')}; candidate: {cell(candidate)}", "",
             f"Packages: {cell(', '.join(chosen.packages) or '(none)')}", "",
             "| Checks | Decision |", "|---|---|",
             "| Documentation, version state, gate manifest, whitespace | Run |",
             f"| Protocol document references and pins | {run(doc_references)} |",
             f"| Release documents, licences and notices | {run(release_docs)} |",
             f"| Build, unit, integration, product, release | {run(chosen.suites)} |",
             f"| Unit suite | {units if chosen.suites else 'Skip'} |",
             f"| Integration suite | {run(chosen.suites and chosen.integration)} |",
             f"| Product suite | {run(chosen.suites and chosen.product)} |",
             f"| Release layout | {run(chosen.suites and chosen.release)} |",
             f"| Offline evaluation | {run(chosen.offline_eval)} |",
             f"| Changed script suites | {cell(' '.join(chosen.script_tests)) or 'None'} |",
             f"| TTY | {tty_label} |",
             f"| SDK bindings | {run(chosen.sdk)} |"]
    lines.extend(["", "| Status | Changed path | Path scope |", "|---|---|---|"])
    for status, path in changes[:200]:
        path_scope, _ = classify([path], [path] if status not in ("A", "M") else [],
                                 document_protocol=path == PROTOCOL and scope == "docs",
                                 release_sources=release_sources, layout=layout)
        lines.append(f"| {cell(status)} | {cell(path)} | {path_scope} |")
    if len(changes) > 200:
        lines.extend(["", f"Showing 200 of {len(changes)} changed paths; the decision uses all paths."])
    with open(destination, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def script_suites(changes: Sequence[Change]) -> Tuple[str, ...]:
    """The changed scripts/tests modules that still exist."""
    return tuple(sorted({"scripts.tests." + PurePosixPath(path).stem for status, path in changes
                         if status != "D" and path_kind(path, None) == "script-test"}))


def local_commands(scope: str, selection: Selection, zig: str = "zig", windows: bool = False,
                   scripts: Sequence[str] = ()) -> List[List[str]]:
    """What `zig build test:affected` runs for a decision: the test part of
    CI's selection, offline (run_local sets TTY_SKIP_MODEL, as CI does), and
    every changed script suite, which CI runs on a checks-leg step of its own
    when build.zig does not. The rest of the AGENTS.md checklist runs on its
    own."""
    if not selection.suites:
        return []
    unittest = [[sys.executable, "-m", "unittest", *scripts]] if scripts else []
    if scope in ("full", "eval"):
        return [[zig, "build", "test"], *unittest]
    steps = []
    if selection.units:
        steps.extend(list(selection.package_tests) or ["test:units"])
    if selection.integration:
        steps.append("test:integration")
    if selection.product:
        steps.append("test:product" if selection.offline_eval else "test:product-runtime")
    steps.append("test:contract")
    commands = [[zig, "build", *steps], *unittest]
    if selection.tty and windows:
        commands.append([zig, "build", "windows:tty", "-Dtarget=x86_64-windows-gnu"])
    elif selection.tty:
        commands.append([zig, "build", "dev", "test:harness"])
        tty_cmd = [sys.executable, "tests/tty/run_tty_tests.py", "--bin", "zig-out/bin/metacodes-debug"]
        if selection.tty_domains:
            tty_cmd.extend(["--domains", ",".join(selection.tty_domains)])
        commands.append(tty_cmd)
    return commands


def run_local(root: Path, scope: str, selection: Selection, zig: str, scripts: Sequence[str] = ()) -> int:
    env = dict(os.environ, TTY_SKIP_MODEL="1")
    if selection.tty_domains:
        env["TTY_DOMAINS"] = ",".join(selection.tty_domains)
    else:
        env.pop("TTY_DOMAINS", None)
    for command in local_commands(scope, selection, zig, windows=os.name == "nt", scripts=scripts):
        print("+ " + " ".join(command), flush=True)
        status = subprocess.run(command, cwd=str(root), env=env, check=False).returncode
        if status:
            return status
    return 0


SUBJECT_PR = re.compile(r"\(#(\d+)\)\s*$")


def replay(root: Path, commits: Sequence[str], rules: Optional[str], cleared: bool,
           release_sources: Sequence[str] = RELEASE_DOCS) -> List[Tuple[str, str, str, Tuple[str, ...], str]]:
    """(commit, subject, scope, packages, reason) for each commit already on
    main against its first parent: what its pull request's scope job decided,
    with layers.zon, layer_baseline.zon and build.zig read at `rules` or, when
    None, at the commit itself."""
    rows = []
    for commit in commits:
        subject = git_bytes(root, "log", "-1", "--format=%s", commit).decode("utf-8").strip()
        read = tree_reader(root, rules or commit)

        def layout() -> Layout:
            found = load_layout(read)
            return found.cleared() if cleared else found

        observed: List[Change] = []

        def changes(base: str, candidate: Optional[str]) -> Sequence[Change]:
            observed.extend(changed_paths(root, base, candidate))
            return observed

        def protocol_change(base: str, candidate: Optional[str]) -> bool:
            def payload(rev: str) -> dict:
                return json.loads(tree_reader(root, rev)(PROTOCOL))
            return protocol_documents_only(payload(base), payload(candidate or commit), release_sources)

        scope, reason = decide("merge_group", f"{commit}^1", commit, changes, protocol_change, release_sources, layout)
        try:
            packages = select(scope, observed, layout(), release_sources).packages if scope == "packages" else ()
        except Exception:
            packages = ()
        rows.append((commit, subject, scope, packages, " ".join(reason.split())))
    return rows


def replay_report(rows: Sequence[Tuple[str, str, str, Tuple[str, ...], str]], title: str) -> str:
    def cell(value: str) -> str:
        return html.escape(value, quote=False).replace("|", "&#124;")

    counts = Counter(scope for _, _, scope, _, _ in rows)
    lines = [f"### {title}", ""]
    if not rows:
        return "\n".join(lines + ["No commits in the window.", ""])
    lines.extend(["| Scope | Commits | Share |", "|---|---|---|"])
    for scope in ("docs", "eval", "tests", "packages", "full") + tuple(
            extra for extra in ("fast-path", "unknown") if counts[extra]):
        lines.append(f"| {scope} | {counts[scope]} | {100 * counts[scope] / len(rows):.0f}% |")
    lines.extend(["", "| Commit | PR | Scope | Packages | Reason |", "|---|---|---|---|---|"])
    for commit, subject, scope, packages, reason in rows:
        match = SUBJECT_PR.search(subject)
        pr = f"#{match.group(1)}" if match else cell(subject[:60])
        lines.append(f"| `{commit[:12]}` | {pr} | {scope} | {', '.join(packages) or '-'} | {cell(reason)} |")
    return "\n".join(lines) + "\n"


CI_WORKFLOW = "ci.yml"
SCOPE_ARTIFACT = "change-scope"
SCOPE_RECORD = "change-scope.json"


def gh_json(path: str):
    return json.loads(subprocess.run(["gh", "api", path], capture_output=True, check=True).stdout)


def download_scope(repository: str, run_id: int) -> Optional[dict]:
    with tempfile.TemporaryDirectory(prefix="metacodes-change-scope-") as tmp:
        proc = subprocess.run(["gh", "run", "download", str(run_id), "--repo", repository, "--name", SCOPE_ARTIFACT,
                               "--dir", tmp], capture_output=True, check=False)
        if proc.returncode:
            return None
        try:
            return json.loads((Path(tmp) / SCOPE_RECORD).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None


def recorded_scope(repository: str, sha: str, query: Callable = gh_json,
                   download: Callable = download_scope) -> Optional[dict]:
    """The scope the newest CI run of the pull request merged as `sha`
    recorded (the scope job's change-scope artifact), or None. Only the
    newest: an older run of the same head may have had other labels."""
    for pr in query(f"repos/{repository}/commits/{sha}/pulls?per_page=100"):
        if not (pr.get("merged_at") and pr.get("merge_commit_sha") == sha):
            continue
        runs = query(f"repos/{repository}/actions/workflows/{CI_WORKFLOW}/runs"
                     f"?head_sha={pr['head']['sha']}&event=pull_request&per_page=20")["workflow_runs"]
        newest = max(runs, key=lambda run: run.get("created_at", ""), default=None)
        return None if newest is None else download(repository, newest["id"])
    return None


def merged(root: Path, commits: Sequence[str], repository: str, query: Callable = gh_json,
           download: Callable = download_scope) -> List[Tuple[str, str, str, Tuple[str, ...], str]]:
    rows = []
    for commit in commits:
        subject = git_bytes(root, "log", "-1", "--format=%s", commit).decode("utf-8").strip()
        try:
            found = recorded_scope(repository, commit, query, download)
        except Exception as exc:
            found, missing = None, f"the lookup failed: {exc}"
        else:
            missing = "its pull request's CI runs recorded no change scope"
        if found is None:
            rows.append((commit, subject, "unknown", (), missing))
        elif found.get("fast_path"):
            rows.append((commit, subject, "fast-path", (),
                         "release fast path: the suites' results were reused from the base's CI run, not run again"))
        else:
            rows.append((commit, subject, str(found.get("scope", "unknown")),
                         tuple(found.get("packages", ())), " ".join(str(found.get("reason", "")).split())))
    return rows


def first_parent_commits(root: Path, ref: str, since: Optional[str], max_count: Optional[int]) -> List[str]:
    log = ["log", "--first-parent", "--format=%H"]
    if since:
        log.append(f"--since={since}")
    if max_count:
        log.append(f"--max-count={max_count}")
    return [line for line in git_bytes(root, *log, ref).decode("utf-8").split() if line]


def merged_main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="ci_scope.py merged",
                                     description="Report the change scope each merged pull request's CI run recorded.")
    parser.add_argument("--since", default="24 hours ago", help="commits after this date (git log --since)")
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--repository", required=True)
    parser.add_argument("--github-summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    parser.add_argument("--repo-root", default=str(ROOT))
    args = parser.parse_args(argv)
    root = Path(args.repo_root)
    rows = merged(root, first_parent_commits(root, args.ref, args.since, None), args.repository)
    report = replay_report(rows, f"Scopes the merges since {args.since} ran")
    print(report, end="")
    if args.github_summary:
        with open(args.github_summary, "a", encoding="utf-8") as handle:
            handle.write(report)
    return 0


def replay_main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(prog="ci_scope.py replay",
                                     description="Report the change scope of commits already on main against their first parent.")
    parser.add_argument("--since", help="only commits after this date (git log --since)")
    parser.add_argument("--max-count", type=int, help="at most this many of the newest commits")
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--rules", help="read layers.zon, layer_baseline.zon and build.zig at this revision instead of at each commit")
    parser.add_argument("--assume-cleared", action="store_true",
                        help="as if every package had left the baseline and had its test step")
    parser.add_argument("--github-summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    parser.add_argument("--repo-root", default=str(ROOT))
    args = parser.parse_args(argv)
    root = Path(args.repo_root)
    commits = first_parent_commits(root, args.ref, args.since, args.max_count)
    try:
        release_sources: Sequence[str] = document_inputs(root).release_sources
    except Exception:
        release_sources = RELEASE_DOCS
    title = "Change scope of the merged commits" + (" (every package cleared)" if args.assume_cleared else "")
    report = replay_report(replay(root, commits, args.rules, args.assume_cleared, release_sources), title)
    print(report, end="")
    if args.github_summary:
        with open(args.github_summary, "a", encoding="utf-8") as handle:
            handle.write(report)
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["replay"]:
        return replay_main(argv[1:])
    if argv[:1] == ["merged"]:
        return merged_main(argv[1:])
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--event", required=True)
    parser.add_argument("--base", default="")
    parser.add_argument("--candidate", default="HEAD", help="a revision, or empty for the working tree")
    parser.add_argument("--github-output")
    parser.add_argument("--github-summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    parser.add_argument("--repo-root", default=str(ROOT))
    parser.add_argument("--run", action="store_true", help="run the selected tests (zig build test:affected)")
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--labels", default="", help="the pull request's labels, comma-separated")
    parser.add_argument("--record", help=f"write the decision as JSON here (the {SCOPE_ARTIFACT} artifact)")
    parser.add_argument("--fast-path", default="", help="the release fast path's decision, recorded with the scope")
    args = parser.parse_args(argv)
    root = Path(args.repo_root)
    candidate = args.candidate or None
    observed: List[Change] = []
    layouts: List[Layout] = []

    def changes(base: str, candidate: Optional[str]) -> Sequence[Change]:
        observed.extend(changed_paths(root, base, candidate))
        return observed

    def layout() -> Layout:
        layouts.append(load_layout(tree_reader(root, candidate)))
        return layouts[-1]

    base = args.base
    if args.event == "local" and base:
        try:
            base = git_bytes(root, "merge-base", base, "HEAD").decode("utf-8").strip()
        except Exception:
            base = ""
    try:
        inputs = document_inputs(root)

        def protocol_change(base: str, candidate: Optional[str]) -> bool:
            def payload(rev: Optional[str]) -> dict:
                return json.loads(tree_reader(root, rev)(PROTOCOL))
            return protocol_documents_only(payload(base), payload(candidate), inputs.release_sources)

        scope, reason = decide(args.event, base, candidate, changes,
                               protocol_change, inputs.release_sources, layout,
                               [label for label in args.labels.split(",") if label])
        doc_references, release_docs = document_checks(scope, observed, inputs)
    except Exception as exc:
        scope, reason = "full", f"full scope: document input attribution failed: {exc}"
        inputs = DocumentInputs(frozenset(RELEASE_DOCS), frozenset())
        doc_references, release_docs = True, True
    try:
        tty_domains = read_optional_tty_domains(root, candidate) if scope in ("tests", "packages") else None
        selection = select(scope, observed, layouts[-1] if layouts else None, inputs.release_sources, tty_domains)
    except Exception as exc:
        scope, reason = "full", f"full scope: the test selection failed: {exc}"
        selection = select(scope)
    reason = " ".join(reason.split())
    print(reason)

    def flag(value: bool) -> str:
        return "true" if value else "false"

    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write(
                f"scope={scope}\nsuites={flag(selection.suites)}\ntty={flag(selection.tty)}\n"
                f"tty_domains={','.join(selection.tty_domains)}\n"
                f"sdk={flag(selection.sdk)}\n"
                f"units={flag(selection.units)}\nintegration={flag(selection.integration)}\n"
                f"product={flag(selection.product)}\nrelease={flag(selection.release)}\n"
                f"offline_eval={flag(selection.offline_eval)}\n"
                f"packages={','.join(selection.packages)}\npackage_tests={' '.join(selection.package_tests)}\n"
                f"script_tests={' '.join(selection.script_tests)}\ncomplete={flag(selection.complete)}\n"
                f"reason={reason}\n"
                f"doc_references={flag(doc_references)}\n"
                f"release_docs={flag(release_docs)}\n"
            )
    if args.record:
        with open(args.record, "w", encoding="utf-8") as handle:
            json.dump({"scope": scope, "packages": list(selection.packages), "reason": reason,
                       "fast_path": args.fast_path == "true"}, handle, sort_keys=True)
            handle.write("\n")
    if args.github_summary:
        write_summary(args.github_summary, args.event, base, args.candidate or "(working tree)", scope, reason, observed,
                      selection=selection, doc_references=doc_references, release_docs=release_docs,
                      release_sources=inputs.release_sources, layout=layouts[-1] if layouts else None)
    if args.run:
        return run_local(root, scope, selection, args.zig, script_suites(observed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
