"""Typed boundaries for the contributor PR controller and process adapters."""
from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import Enum
from pathlib import Path
import re


DEFAULT_REPO = "metask-ai/metacodes"
REQUIRED_CHECKS = ("Gates (Linux)", "Gates (macOS)", "Gates (Windows)", "TTY (Linux)")
SHA = re.compile(r"^[0-9a-f]{40}$")
REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


class LoopError(RuntimeError):
    """A failure that requires a human rather than an automatic write retry."""


class Busy(LoopError):
    """The bound worker already has an active turn."""


class AgentUnavailable(LoopError):
    """The agent transport failed; only a read-only invocation may be replayed."""


class ReadUnavailable(LoopError):
    """A transient remote read failed without performing a remote mutation."""


class Verdict(str, Enum):
    PASS = "pass"
    FIX = "fix_required"
    RETRY = "retry"
    DECISION = "needs_decision"


class State(str, Enum):
    PENDING = "pending"
    REVIEWING = "reviewing"
    WORKING = "working"
    VALIDATING = "validating"
    PUSHING = "pushing"
    UPDATING = "updating_base"
    MERGING = "merging"
    # Retained so existing SQLite rows remain readable during migration.
    QUEUEING = "queueing"
    WAITING = "waiting"
    QUEUED = "queued"
    DECISION = "needs_decision"
    MERGED = "merged"
    CLOSED = "closed"


IN_FLIGHT = {State.REVIEWING, State.WORKING, State.VALIDATING, State.PUSHING,
             State.UPDATING, State.MERGING, State.QUEUEING}


@dataclass(frozen=True)
class Binding:
    repo: str
    number: int
    thread: str
    worktree: str
    branch: str
    head_repo: str
    remote: str = "origin"
    max_rounds: int = 5
    max_agent_runs: int = 16
    timeout: int = 1800

    def __post_init__(self):
        if not REPO.fullmatch(self.repo) or not REPO.fullmatch(self.head_repo):
            raise LoopError("repository must be OWNER/REPO")
        if self.number < 1 or min(self.max_rounds, self.max_agent_runs, self.timeout) < 1:
            raise LoopError("PR number, limits and timeout must be positive")
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", self.thread):
            raise LoopError("an explicit Codex thread ID is required")
        if not Path(self.worktree).is_absolute() or not self.branch or self.branch.startswith("-"):
            raise LoopError("an absolute worktree path and a branch are required")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", self.remote) or self.remote.startswith("-"):
            raise LoopError("invalid push remote")


@dataclass(frozen=True)
class Snapshot:
    repo: str
    number: int
    node_id: str
    head: str
    base: str
    branch: str
    base_branch: str
    head_repo: str
    title: str
    body: str
    url: str
    open: bool
    merged: bool
    draft: bool
    mergeable: bool | None
    merge_sha: str | None
    queued: bool = False
    review_decision: str | None = None
    unresolved: bool = False

    @property
    def revision(self):
        return self.head, self.base


REPORT_SCHEMA = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string", "enum": [v.value for v in Verdict]},
        "summary": {"type": "string"},
        "findings": {"type": "array", "items": {
            "type": "object", "properties": {
                "path": {"type": "string"}, "line": {"type": "integer"},
                "reason": {"type": "string"}, "acceptance": {"type": "string"},
            }, "required": ["path", "line", "reason", "acceptance"], "additionalProperties": False,
        }},
        "question": {"type": "string"},
    }, "required": ["verdict", "summary", "findings", "question"], "additionalProperties": False,
}


def validate_report(value: dict) -> dict:
    if not isinstance(value, dict) or set(value) != {"verdict", "summary", "findings", "question"}:
        raise LoopError("reviewer returned an invalid report")
    try:
        verdict = Verdict(value["verdict"])
    except (ValueError, TypeError) as exc:
        raise LoopError("reviewer returned an invalid verdict") from exc
    if not isinstance(value["summary"], str) or not value["summary"].strip():
        raise LoopError("review report has no summary")
    if not isinstance(value["question"], str) or not isinstance(value["findings"], list):
        raise LoopError("invalid findings or question")
    for finding in value["findings"]:
        if not isinstance(finding, dict) or set(finding) != {"path", "line", "reason", "acceptance"}:
            raise LoopError("invalid finding")
        path = finding["path"]
        if (not isinstance(path, str) or not path or Path(path).is_absolute()
                or ".." in path.replace("\\", "/").split("/")
                or type(finding["line"]) is not int or finding["line"] < 1
                or not all(isinstance(finding[k], str) and finding[k].strip() for k in ("reason", "acceptance"))):
            raise LoopError("finding needs a relative path, positive line and actionable evidence")
    if verdict == Verdict.PASS and (value["findings"] or value["question"]):
        raise LoopError("a passing review cannot contain unresolved findings or a question")
    if verdict == Verdict.FIX and (not value["findings"] or value["question"]):
        raise LoopError("a fix verdict needs findings and no decision question")
    if verdict == Verdict.RETRY and (value["findings"] or value["question"]):
        raise LoopError("a retry verdict needs no findings or decision question")
    if verdict == Verdict.DECISION and not value["question"].strip():
        raise LoopError("a decision verdict needs a question")
    return value


def binding_json(binding: Binding):
    return asdict(binding)
