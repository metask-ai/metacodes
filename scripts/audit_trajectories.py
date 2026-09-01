#!/usr/bin/env python3
"""Measure what tool results actually cost, from session transcripts already on disk.

Reading the code tells you a defect exists. It does not tell you how often it
fires, and an unmeasured frequency gets supplied from intuition -- which is how
a tail case ends up described as happening "every time". This reads the
transcripts a session already wrote and answers the questions code review
cannot:

  * how big are tool results really, per tool, against the per-result budget;
  * how many were spilled to an artifact, and how many of those spills were
    ever recovered from -- a spill nobody reads is a round trip bought for
    nothing;
  * how often a Bash command was re-run with a modified command line instead of
    the elided bytes being recovered (the behaviour reported in issue #29).

Privacy: this reports sizes, counts and tool names only. Result *content*,
command text, file paths and prompts are never read into the output, and the
``--json`` form carries the same fields as the table. Transcripts hold real
work; an audit tool that prints them is not usable on a real machine.

Not part of any gate: it reads ``~/.metacodes``, which CI does not have. Run it
against your own history when you want a frequency rather than a guess:

    python3 scripts/audit_trajectories.py
    python3 scripts/audit_trajectories.py --window 200000 --json
    python3 scripts/audit_trajectories.py --root /path/to/projects --top 15
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter, defaultdict
from pathlib import Path

# Mirrors src/core/result_budget.zig. Kept as plain arithmetic rather than
# imported: this script must run against a checkout it was not built from.
PER_RESULT_MIN_BYTES = 8 * 1024
PER_RESULT_MAX_BYTES = 64 * 1024
PER_RESULT_WINDOW_DIVISOR = 8

# Matched as a substring, not an exact prefix. Testing for the literal
# `{"schema_version":"metacodes...` binds the audit to one writer's spacing:
# any other emitter, or a transcript passed through a formatter, would leave
# this silently counting zero. That is the failure mode this whole script
# exists to catch, and it has now been written here twice.
PROJECTION_SCHEMA = "metacodes.tool-result-projection"
BASH_SCHEMA = "metacodes.bash-result.v2"
RECOVERY_TOOLS = {"ReadArtifact", "Grep", "Read"}


def per_result_bytes(max_input_tokens: int) -> int:
    """The budget one result may occupy, as result_budget.perResultBytes."""
    derived = PER_RESULT_MIN_BYTES if max_input_tokens == 0 else max_input_tokens // PER_RESULT_WINDOW_DIVISOR
    return min(max(derived, PER_RESULT_MIN_BYTES), PER_RESULT_MAX_BYTES)


def percentile(sorted_values: list[int], fraction: float) -> int:
    if not sorted_values:
        return 0
    index = min(len(sorted_values) - 1, int(len(sorted_values) * fraction))
    return sorted_values[index]


class Audit:
    def __init__(self, budget: int) -> None:
        self.budget = budget
        self.sessions = 0
        self.sizes: list[int] = []
        self.by_tool: dict[str, list[int]] = defaultdict(list)
        self.tool_calls: Counter[str] = Counter()
        self.spilled = 0
        self.spills_recovered = 0
        self.bash_truncated = 0
        self.over_budget = 0
        self.unattributed = 0
        self.truncated_bash_results = 0
        self.reruns_after_truncation = 0

    # -- transcript walking -------------------------------------------------
    #
    # A tool_result names the tool_use it answers, so the two are paired by id
    # to attribute a size to a tool. Transcripts are append-only and may hold
    # partial or foreign records, so every step is tolerant: an unparseable
    # line is skipped rather than aborting a scan over hundreds of sessions.

    def add_session(self, text: str) -> None:
        self.sessions += 1
        tool_of_use: dict[str, str] = {}
        command_of_use: dict[str, str] = {}
        # Unrecovered spills, counted per artifact id. A single slot held only
        # the most recent one, so `spill A -> spill B -> read A -> read B`
        # reported 1 of 2 recovered: B overwrote A before anything reached for
        # it. Tools that run in one batch routinely spill several results
        # before the model reads any of them, so the single slot made
        # "how many spills were recovered" unusable exactly where spilling
        # matters most.
        pending_spills: Counter[str] = Counter()
        # Command text of the last Bash call whose result came back truncated.
        # Held only to compare against the next Bash command; never reported.
        truncated_command: str | None = None
        for line in text.splitlines():
            if '"tool_use"' not in line and '"tool_result"' not in line:
                continue
            try:
                record = json.loads(line)
            except (ValueError, TypeError):
                continue
            for block in self._blocks(record):
                kind = block.get("type")
                if kind == "tool_use":
                    name = block.get("name")
                    if not isinstance(name, str):
                        continue
                    self.tool_calls[name] += 1
                    if isinstance(block.get("id"), str):
                        tool_of_use[block["id"]] = name
                        command = self._command_of(block)
                        if command:
                            command_of_use[block["id"]] = command
                    if pending_spills and name in RECOVERY_TOOLS:
                        wanted = self._referenced_artifact(block)
                        if wanted is not None:
                            # Resolve *every* pending spill of that id, not one.
                            # The store is content-addressed, so the id is the
                            # content: two calls that produced identical bytes
                            # share an id, and one read hands the model the
                            # content of both. Decrementing by one would leave
                            # the duplicate permanently unrecoverable.
                            self.spills_recovered += pending_spills.pop(wanted, 0)
                    if name == "Bash" and truncated_command is not None:
                        command = self._command_of(block)
                        if command and _is_rerun(truncated_command, command):
                            self.reruns_after_truncation += 1
                        truncated_command = None
                elif kind == "tool_result":
                    content = block.get("content")
                    if not isinstance(content, str):
                        continue
                    use_id = block.get("tool_use_id")
                    self._add_result(content, tool_of_use.get(use_id))
                    recoverable = self._recoverable_artifact_id(content)
                    if recoverable is not None:
                        pending_spills[recoverable] += 1
                    if self._is_truncated_bash(content):
                        self.truncated_bash_results += 1
                        truncated_command = command_of_use.get(use_id)

    @staticmethod
    def _recoverable_artifact_id(content: str) -> str | None:
        """The artifact id of a *recoverable* spill, or None.

        Prefix-matching the schema cannot tell `projection:"artifact"` from
        `projection:"fallback"`, and a fallback is by definition unrecoverable -
        counting it as a spill and then arming the recovery detector meant any
        unrelated `Read` that happened to come next was scored as a recovery.
        """
        if PROJECTION_SCHEMA not in content[:160]:
            return None
        try:
            envelope = json.loads(content)
        except (ValueError, TypeError):
            return None
        if not isinstance(envelope, dict) or envelope.get("projection") != "artifact":
            return None
        artifact_id = envelope.get("artifact_id")
        return artifact_id if isinstance(artifact_id, str) and artifact_id else None

    @staticmethod
    def _referenced_artifact(block: dict) -> str | None:
        """The artifact this call reaches for, or None.

        Adjacency was the old test, which scored any nearby read. With the
        staging path gone, only an explicit `artifact_id` can recover a spill.
        Returns the id rather than testing one, so the caller can look it up
        among all pending spills instead of only the most recent.
        """
        raw = block.get("input")
        if isinstance(raw, str):
            try:
                raw = json.loads(raw)
            except (ValueError, TypeError):
                return None
        if not isinstance(raw, dict):
            return None
        artifact_id = raw.get("artifact_id")
        return artifact_id if isinstance(artifact_id, str) and artifact_id else None

    @staticmethod
    def _command_of(block: dict) -> str | None:
        """The Bash command line, for comparison only - never reported."""
        raw = block.get("input")
        if isinstance(raw, str):
            try:
                raw = json.loads(raw)
            except (ValueError, TypeError):
                return None
        if isinstance(raw, dict):
            command = raw.get("command")
            if isinstance(command, str):
                return command.strip()
        return None

    @staticmethod
    def _is_truncated_bash(content: str) -> bool:
        """Whether this is a Bash envelope reporting an elided channel.

        Parsed rather than substring-matched. The first version tested for the
        literal `"stdout_truncated":true`, which is how the Zig writer happens
        to serialize it today - no spaces - and would silently see nothing from
        any other writer, or from a transcript rewritten by a formatter.
        """
        if BASH_SCHEMA not in content[:96]:
            return False
        try:
            envelope = json.loads(content)
        except (ValueError, TypeError):
            return False
        if not isinstance(envelope, dict):
            return False
        return any(
            envelope.get(f"{channel}_truncated") is True for channel in ("stdout", "stderr")
        )

    def _blocks(self, node: object) -> list[dict]:
        """Every dict in the record, in document order.

        Order matters: the pairing of a spill with the recovery call that
        follows it, and of a truncated Bash result with the next command, both
        read the sequence. A stack-based walk reverses siblings, which put a
        `tool_result` before the `tool_use` it answers whenever both sat on one
        line - rare in real transcripts, which is exactly why it survived until
        a test put them together.
        """
        found: list[dict] = []

        def visit(item: object) -> None:
            if isinstance(item, dict):
                found.append(item)
                for value in item.values():
                    visit(value)
            elif isinstance(item, list):
                for value in item:
                    visit(value)

        visit(node)
        return found

    def _add_result(self, content: str, tool: str | None) -> None:
        # UTF-8 bytes, not characters. `len()` on a str counts code points, so
        # 3000 Chinese characters reported as 3000B against an 8 KiB floor when
        # the transcript actually holds 9000B - a systematic under-count of
        # exactly the results most likely to be over budget.
        size = len(content.encode("utf-8", errors="surrogatepass"))
        self.sizes.append(size)
        if size > self.budget:
            self.over_budget += 1
        if tool is None:
            self.unattributed += 1
        else:
            self.by_tool[tool].append(size)
        if self._recoverable_artifact_id(content) is not None:
            self.spilled += 1
        if self._is_truncated_bash(content):
            self.bash_truncated += 1

    # -- reporting ----------------------------------------------------------

    def report(self, top: int) -> dict:
        ordered = sorted(self.sizes)
        tools = []
        for name, sizes in sorted(self.by_tool.items(), key=lambda kv: -len(kv[1]))[:top]:
            ranked = sorted(sizes)
            tools.append(
                {
                    "tool": name,
                    "results": len(ranked),
                    "median": percentile(ranked, 0.5),
                    "p90": percentile(ranked, 0.90),
                    "max": ranked[-1],
                    "over_budget": sum(1 for value in ranked if value > self.budget),
                }
            )
        return {
            "budget_per_result_bytes": self.budget,
            "sessions": self.sessions,
            "results": len(ordered),
            "unattributed_results": self.unattributed,
            "median": percentile(ordered, 0.5),
            "p90": percentile(ordered, 0.90),
            "p99": percentile(ordered, 0.99),
            "max": ordered[-1] if ordered else 0,
            "over_budget": self.over_budget,
            "spilled_to_artifact": self.spilled,
            "spills_recovered": self.spills_recovered,
            "bash_truncated": self.bash_truncated,
            "reruns_after_truncation": self.reruns_after_truncation,
            "tool_calls": dict(self.tool_calls.most_common(top)),
            "tools": tools,
        }


def _is_rerun(previous: str, current: str) -> bool:
    """Whether `current` re-runs `previous` rather than recovering from it.

    Issue #29's shape: the model re-issues the same command with a filter
    bolted on (``./build.sh`` then ``./build.sh 2>&1 | grep NEEDLE``) instead of
    reading the bytes that were elided. Containment either way catches that and
    the plain repeat, without pretending to parse a shell. Trivially short
    commands are skipped: ``ls`` appearing twice is not evidence of anything.
    """
    if len(previous) < 8 or len(current) < 8:
        return False
    return previous in current or current in previous


def render(summary: dict) -> str:
    lines = [
        f"sessions {summary['sessions']}   tool results {summary['results']}"
        f"   per-result budget {summary['budget_per_result_bytes']}B",
        "",
        f"  size   median {summary['median']}B   p90 {summary['p90']}B"
        f"   p99 {summary['p99']}B   max {summary['max']}B",
    ]
    results = summary["results"] or 1
    share = 100.0 * summary["over_budget"] / results
    lines.append(f"  over budget            {summary['over_budget']} ({share:.1f}%)")
    lines.append(f"  spilled to artifact    {summary['spilled_to_artifact']}")
    # A spill the model never reads back is a round trip bought for nothing;
    # this ratio is the reason to look, not the spill count on its own.
    lines.append(
        f"  ...recovered from      {summary['spills_recovered']}"
        f" of {summary['spilled_to_artifact']}"
    )
    lines.append(f"  Bash results truncated {summary['bash_truncated']}")
    # Issue #29: re-running costs a full round trip and does not return the
    # bytes that were elided. A nonzero count here is the behaviour the tool
    # descriptions are meant to steer away from.
    lines.append(f"  ...re-run instead      {summary['reruns_after_truncation']}")
    if summary["unattributed_results"]:
        lines.append(
            f"  (unattributed to a tool: {summary['unattributed_results']}"
            " - tool_use/tool_result pairing failed)"
        )
    if summary["tools"]:
        lines.append("")
        lines.append(f"  {'tool':<22}{'n':>6}{'median':>9}{'p90':>9}{'max':>10}{'over':>7}")
        for row in summary["tools"]:
            lines.append(
                f"  {row['tool'][:22]:<22}{row['results']:>6}{row['median']:>9}"
                f"{row['p90']:>9}{row['max']:>10}{row['over_budget']:>7}"
            )
    return "\n".join(lines)


def scan(root: Path, budget: int, top: int = 12) -> dict:
    """Audit every transcript under ``root``. Unreadable files are skipped: a
    scan over hundreds of sessions must not abort on one bad permission."""
    audit = Audit(budget)
    for transcript in sorted(root.glob("*/*/transcript.jsonl")):
        try:
            text = transcript.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if text.strip():
            audit.add_session(text)
    return audit.report(top=top)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(os.path.expanduser("~/.metacodes/projects")),
        help="directory holding <project>/<session>/transcript.jsonl",
    )
    parser.add_argument(
        "--window",
        type=int,
        default=200_000,
        help="model context window, for deriving the per-result budget (default 200000)",
    )
    parser.add_argument("--top", type=int, default=12, help="tools to list (default 12)")
    parser.add_argument("--json", action="store_true", help="emit the summary as JSON")
    args = parser.parse_args(argv)

    if not args.root.is_dir():
        print(f"no transcripts at {args.root}", file=sys.stderr)
        return 1

    summary = scan(args.root, per_result_bytes(args.window), top=args.top)

    if summary["results"] == 0:
        print(f"no tool results found under {args.root}", file=sys.stderr)
        return 1
    print(json.dumps(summary, indent=2) if args.json else render(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
