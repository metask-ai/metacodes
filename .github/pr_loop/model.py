"""Typed boundaries for the contributor PR controller and process adapters."""
from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import Enum
import json
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


class Agent(str, Enum):
    """Local agent CLIs the controller can drive as a worker or reviewer."""
    CODEX = "codex"
    CLAUDE = "claude"


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
    # Every automatic gate passed; a high-risk head waits for a human approval
    # bound to its exact SHA. Polling continues so approvals are observed.
    HUMAN = "needs_human"
    # Attended binding: findings wait for the developer's own live session,
    # which edits in front of the developer and answers with `pr-loop reply`.
    AWAITING = "awaiting_session"
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
    timeout: int = 1800
    # Registrations made before multi-agent support were Codex on both sides.
    agent: str = Agent.CODEX.value
    reviewer: str = Agent.CODEX.value
    # Attended: repairs go to the developer's live session, with an unattended
    # fork only after attended_timeout seconds without a reply.
    attended: bool = False
    attended_timeout: int = 3600
    # Mirror reviews, replies and gate events to the PR conversation.
    mirror: bool = False

    def __post_init__(self):
        if not REPO.fullmatch(self.repo) or not REPO.fullmatch(self.head_repo):
            raise LoopError("repository must be OWNER/REPO")
        if self.number < 1 or self.timeout < 1 or self.attended_timeout < 1:
            raise LoopError("PR number and timeout must be positive")
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", self.thread):
            raise LoopError("an explicit worker session or thread ID is required")
        for value in (self.agent, self.reviewer):
            if value not in {a.value for a in Agent}:
                raise LoopError(f"unknown agent {value!r}; expected codex or claude")
        if not Path(self.worktree).is_absolute() or not self.branch or self.branch.startswith("-"):
            raise LoopError("an absolute worktree path and a branch are required")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", self.remote) or self.remote.startswith("-"):
            raise LoopError("invalid push remote")

    @classmethod
    def from_json(cls, source: str) -> Binding:
        value = json.loads(source)
        if not isinstance(value, dict):
            raise LoopError("stored worker binding must be an object")
        # Older registrations included count caps. They no longer control
        # execution; the separate durable counters remain audit evidence.
        value.pop("max_rounds", None)
        value.pop("max_agent_runs", None)
        return cls(**value)


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


FINDING = {
    "type": "object", "properties": {
        "path": {"type": "string"}, "line": {"type": "integer"},
        "reason": {"type": "string"}, "acceptance": {"type": "string"},
    }, "required": ["path", "line", "reason", "acceptance"], "additionalProperties": False,
}

REPORT_SCHEMA = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string", "enum": [v.value for v in Verdict]},
        "summary": {"type": "string"},
        "findings": {"type": "array", "items": FINDING},
        # Pre-existing defects this PR does not cause: a separate session and PR.
        "followups": {"type": "array", "items": FINDING},
        "question": {"type": "string"},
        "risk": {"type": "object", "properties": {
            "level": {"type": "string", "enum": ["normal", "high"]},
            "reasons": {"type": "array", "items": {"type": "string"}},
        }, "required": ["level", "reasons"], "additionalProperties": False},
    }, "required": ["verdict", "summary", "findings", "followups", "question", "risk"], "additionalProperties": False,
}

REPORT_KEYS = frozenset(REPORT_SCHEMA["required"])

WORKER_SCHEMA = {
    "type": "object", "properties": {
        # rerun_ci: the failure is not caused by this change (flaky runner,
        # outage); the controller reruns the failed jobs once per head.
        "result": {"type": "string", "enum": ["updated", "disputed", "rerun_ci", "needs_decision"]},
        "summary": {"type": "string"}, "question": {"type": "string"},
        # A worker answers a finding it believes is wrong with an argument
        # instead of a change; the next adversarial review must rule on it.
        "rebuttals": {"type": "array", "items": {"type": "object", "properties": {
            "finding": {"type": "integer"}, "argument": {"type": "string"},
        }, "required": ["finding", "argument"], "additionalProperties": False}},
    }, "required": ["result", "summary", "question", "rebuttals"], "additionalProperties": False,
}


def validate_report(value: dict) -> dict:
    if not isinstance(value, dict) or set(value) != REPORT_KEYS:
        raise LoopError("reviewer returned an invalid report")
    try:
        verdict = Verdict(value["verdict"])
    except (ValueError, TypeError) as exc:
        raise LoopError("reviewer returned an invalid verdict") from exc
    if not isinstance(value["summary"], str) or not value["summary"].strip():
        raise LoopError("review report has no summary")
    if (not isinstance(value["question"], str) or not isinstance(value["findings"], list)
            or not isinstance(value["followups"], list)):
        raise LoopError("invalid findings, follow-ups or question")
    for finding in value["findings"] + value["followups"]:
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
    risk = value["risk"]
    if (not isinstance(risk, dict) or set(risk) != {"level", "reasons"} or risk["level"] not in ("normal", "high")
            or not isinstance(risk["reasons"], list)
            or not all(isinstance(r, str) and r.strip() for r in risk["reasons"])):
        raise LoopError("review report needs a risk level and string reasons")
    if risk["level"] == "high" and not risk["reasons"]:
        raise LoopError("a high-risk classification needs a reason")
    return value


def upgrade_report(value):
    """A report stored before scope and risk classification, or None.

    Repair evidence stays usable: a cached fix_required report keeps driving
    the (possibly checkpointed) repair, and risk only matters for a pass. A
    cached pass is never upgraded: risk is unknown, so it is reviewed again.
    """
    if not isinstance(value, dict) or set(value) == REPORT_KEYS:
        return value
    if set(value) - REPORT_KEYS or value.get("verdict") == Verdict.PASS.value:
        return None
    upgraded = {"followups": [], "risk": {"level": "normal", "reasons": []}, **value}
    return upgraded if set(upgraded) == REPORT_KEYS else None


def validate_worker(value: dict, findings: int, ci: bool = False) -> dict:
    """Each result kind has exactly one legal shape; contradictions stop the loop."""
    if (not isinstance(value, dict) or set(value) != set(WORKER_SCHEMA["required"])
            or not all(isinstance(value[k], str) for k in ("result", "summary", "question"))
            or not value["summary"].strip() or not isinstance(value["rebuttals"], list)):
        raise LoopError("worker returned an invalid result")
    seen = set()
    for item in value["rebuttals"]:
        if (not isinstance(item, dict) or set(item) != {"finding", "argument"}
                or type(item["finding"]) is not int or not 0 <= item["finding"] < findings
                or item["finding"] in seen or not isinstance(item["argument"], str) or not item["argument"].strip()):
            raise LoopError("a rebuttal must name one existing finding index once and argue it")
        seen.add(item["finding"])
    kind = value["result"]
    if kind == "needs_decision":
        if not value["question"].strip():
            raise LoopError("worker requested a decision without a question")
    elif kind == "rerun_ci":
        if not ci or value["question"] or value["rebuttals"]:
            raise LoopError("rerun_ci answers CI failures only, with evidence in the summary and nothing else")
    elif kind in ("updated", "disputed"):
        if value["question"]:
            raise LoopError(f"worker returned {kind} with an unresolved question")
        if kind == "disputed" and not value["rebuttals"]:
            raise LoopError("a disputed result needs at least one rebuttal")
    else:
        raise LoopError("worker returned an invalid result")
    return value


def binding_json(binding: Binding):
    return asdict(binding)
