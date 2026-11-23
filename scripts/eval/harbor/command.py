"""Harbor-free core of the metacodes Harbor adapter.

Everything here is plain Python (3.9, stdlib only) so the contract tests run
without Harbor installed: the release bundle check, the model split, the shell
command one trial runs, and the conversion of the run's output into the
ATIF-shaped steps Harbor stores.  ``metacodes_agent.py`` wires these into
Harbor's ``BaseInstalledAgent``.
"""

from __future__ import annotations

import json
import re
import shlex
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Tuple

from scripts.eval.workbuddy.trace import TraceError, load_trace_ir

# Where the bundle lands in the task container.  Outside the task's own tree
# (`/app`, `/workspace`, ...) so a verifier diff never sees it.
REMOTE_BUNDLE = "/opt/metacodes"
REMOTE_BINARY = REMOTE_BUNDLE + "/bin/metacodes"
REMOTE_KG_BIN = REMOTE_BUNDLE + "/vendor/tinykg/tinykg"
# Harbor mounts the agent log directory here and copies it back to the host.
REMOTE_LOGS = "/logs/agent"

OUTPUT_FILENAME = "metacodes-output.jsonl"
TRANSCRIPT_FILENAME = "metacodes-transcript.jsonl"
STDERR_FILENAME = "metacodes-stderr.log"

# The executables a release-layout bundle must carry (release/LAYOUT.md).
# Harbor's directory upload does not promise to keep mode bits, so install
# restores the execute bit on exactly these.
BUNDLE_EXECUTABLES = (
    "bin/metacodes",
    "bin/rg",
    "vendor/tinykg/tinykg",
    "vendor/tinykg/tinykgd",
    "libexec/metacodes/metacodes-formal-kernel",
    "libexec/metacodes/metacodes-project-kernel",
)

# Interactive tools a headless benchmark trial has nobody to answer, and the
# multi-agent tools the WorkBuddy runs also keep off.  `disallowed_tools`
# replaces the list; an empty string enables every tool.
DEFAULT_DISALLOWED_TOOLS = (
    "Agent,Task,TaskBatch,TeamCreate,TeamDelete,SendMessage,"
    "EnterPlanMode,ExitPlanMode"
)

# `metacodes --reasoning-effort` accepts exactly these (src/core/types.zig).
REASONING_EFFORTS = ("none", "minimal", "low", "medium", "high", "xhigh", "max")

ADVANCED_FEATURES = {
    "verification_final_gate": {"group": "formal", "flag": "--verification-final-gate",
                                "label": "结束前验证义务（VerificationGate）"},
    "requirement_ledger": {"group": "formal", "flag": "--requirement-ledger",
                           "label": "需求台账闭合（RequirementLedger）"},
    "test_integrity": {"group": "formal", "flag": "--test-integrity",
                       "label": "测试完整性（TestIntegrity）"},
    "delivery_cadence": {"group": "formal", "flag": "--delivery-cadence",
                         "label": "交付节奏提醒（DeliveryCadence）"},
    "stall_gate": {"group": "formal", "flag": "--stall-gate",
                   "label": "停滞门（StallGate）"},
    "execute_code": {"group": "preview", "flag": "--preview=execute_code",
                     "label": "ExecuteCode JavaScript 工具编排"},
    "comment_guard": {"group": "preview", "flag": "--preview=comment_guard",
                      "label": "不写注释约束与编辑检查"},
    "harnessmm": {"group": "preview", "flag": "--harnessmm",
                  "label": "HarnessMM 决策复用与回调证书"},
    # An entry, not a flag of the headless run: the trial runs the task
    # through `metacodes teamwork run` (see teamwork_run_command).
    "teamwork": {"group": "preview", "flag": "--preview=teamwork", "entry": True,
                 "label": "Teamwork 流水线（实现 ⇄ 评审 → 审计 → 合回，单独使用）"},
}

TEAMWORK = "teamwork"
TEAMWORK_EVENTS_FILENAME = "teamwork-events.jsonl"
TEAMWORK_STATUS_FILENAME = "teamwork-status.json"
TEAMWORK_RUN_DIRNAME = "teamwork-run"
# Dollar cap of one teamwork trial by the task's declared difficulty: ample,
# so a trial ends on its result rather than its budget. The ledger charges
# metacodes' price-table estimate, and a model without its own price is
# charged at the Sonnet fallback rates, far above what a cheap model costs.
TEAMWORK_BUDGET_USD = {"easy": 20.0, "medium": 40.0, "hard": 80.0}
TEAMWORK_DEFAULT_BUDGET_USD = 40.0
# The pipeline runs several seats in turn; its trials get this much more of
# the task's agent timeout.
TEAMWORK_TIMEOUT_MULTIPLIER = 3
# Teamwork seats run their commands under bubblewrap and work in a git
# worktree; a task image gets both when it lacks them.
TEAMWORK_PACKAGE_INSTALL = {
    "apt-get": "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y git bubblewrap",
    "dnf": "dnf install -y git bubblewrap",
    "yum": "yum install -y git bubblewrap",
    "apk": "apk add --no-cache git bubblewrap",
}
TEAMWORK_TOOLS_CHECK = "command -v git >/dev/null 2>&1 && command -v bwrap >/dev/null 2>&1"
# `teamwork run` takes no --permission: a headless trial runs with
# bypassPermissions, and teamwork's seats and verifier would otherwise ask,
# with nobody to answer. User-level allow rules in the disposable container
# give them the same; their commands still run under bubblewrap.
TEAMWORK_ALLOWED_TOOLS = ("Bash", "Read", "Edit", "Write", "Glob", "Grep", "WebSearch", "NotebookEdit")
# What a task container needs for bubblewrap to create its namespaces, as
# root (no user namespace: SYS_ADMIN, NET_ADMIN for the loopback) or as
# another user (unconfined seccomp, AppArmor and /proc).
TEAMWORK_CONTAINER = {"cap_add": ["SYS_ADMIN", "NET_ADMIN"],
                      "security_opt": ["seccomp=unconfined", "apparmor=unconfined", "systempaths=unconfined"]}

# A trial must not reach a TinyKG store outside its own container: these
# would point metacodes at a shared or remote store.
REMOTE_TINYKG_ENV = (
    "TINYKG_REMOTE_URL",
    "TINYKG_API_KEY",
    "TINYKG_REMOTE_EXPECTED_BUILD_ID",
    "TINYKG_REMOTE_CONFIG",
    "METACODES_KG_CONFIG",
    "METACODES_KG_URL",
    "METACODES_KG_API_KEY",
    "METACODES_KG_EXPECTED_BUILD_ID",
    "METACODES_KG_EXPECTED_SCHEMA_DIGEST",
)


# Where metacodes looks for the CA bundle: Zig 0.16's
# std.crypto.Certificate.Bundle.rescanLinux, which reads these fixed paths
# and no environment variable.  A task image without any of them (Terminal-
# Bench's write-compressor: Ubuntu 24.04, no ca-certificates) fails every
# provider request with TlsInitializationFailed.
CA_BUNDLE_PATHS = (
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/ca-bundle.pem",
    "/etc/pki/tls/cacert.pem",
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
    "/etc/ssl/cert.pem",
)

# The package that provides it, per package manager Harbor detects.
CA_PACKAGE_INSTALL = {
    "apt-get": "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates",
    "dnf": "dnf install -y ca-certificates",
    "yum": "yum install -y ca-certificates",
    "apk": "apk add --no-cache ca-certificates",
}


def ca_bundle_check() -> str:
    """Shell that exits 0 when the image already has a CA bundle metacodes reads."""

    return " || ".join(f"test -s {shlex.quote(path)}" for path in CA_BUNDLE_PATHS)


def trust_relay_ca(ca_path: str, trust_bundle: str, bundles=CA_BUNDLE_PATHS) -> str:
    """Shell that trusts the run's relay CA in a disposable task image.

    The CA is appended to every system bundle present (metacodes reads those
    paths), and the first non-empty result is copied to `trust_bundle`, one
    fixed, world-readable path for clients that read no system bundle, such
    as an LLM judge's httpx (SSL_CERT_FILE). Exits non-zero when no bundle
    exists or a write fails."""
    paths = " ".join(shlex.quote(p) for p in bundles)
    trust = shlex.quote(trust_bundle)
    parent = shlex.quote(trust_bundle.rsplit("/", 1)[0] or "/")
    return (f"for bundle in {paths}; do "
            f'if [ -f "$bundle" ]; then printf "\\n" >> "$bundle"; '
            f'cat {shlex.quote(ca_path)} >> "$bundle" || exit 1; fi; done; '
            f"mkdir -p {parent} || exit 1; "
            f'for bundle in {paths}; do if [ -s "$bundle" ]; then '
            f'cat "$bundle" > {trust} && chmod 0644 {trust} && exit 0; exit 1; fi; done; exit 1')


class BundleError(ValueError):
    """The path given as the metacodes bundle is not a Linux release prefix."""


def check_bundle(path: Path) -> Dict[str, Any]:
    """Validate a release-layout prefix on the host and return its manifest.

    The bundle runs inside a Linux task container, so a macOS or Windows
    prefix is refused here instead of failing later as an exec format error.
    """

    root = Path(path)
    if not root.is_dir():
        raise BundleError(f"metacodes bundle is not a directory: {root}")
    manifest_path = root / "manifest.json"
    if not manifest_path.is_file():
        raise BundleError(
            f"metacodes bundle has no manifest.json (not a release layout): {root}"
        )
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BundleError(f"metacodes bundle manifest is unreadable: {exc}") from exc
    if not isinstance(manifest, dict):
        raise BundleError("metacodes bundle manifest is not a JSON object")
    target = manifest.get("target")
    if not isinstance(target, dict) or target.get("os") != "linux":
        raise BundleError(
            "metacodes bundle targets "
            f"{target.get('id') if isinstance(target, dict) else target!r}, "
            "but Harbor task containers are Linux"
        )
    missing = [rel for rel in BUNDLE_EXECUTABLES if not (root / rel).is_file()]
    if missing:
        raise BundleError(
            "metacodes bundle is missing " + ", ".join(missing)
        )
    return manifest


def split_model(model_name: Optional[str]) -> Tuple[Optional[str], str]:
    """`provider/model` -> (`--provider`, `--model`).

    Harbor names models `provider/model`.  The provider part is a metacodes
    provider id or alias (`deepseek`, `zai-coding-plan`, `openai`, ...) or a
    provider defined in the native config's `custom_providers`.  Only the
    first `/` splits: model ids such as `Qwen/Qwen3-Coder` keep theirs.
    """

    name = (model_name or "").strip()
    if not name:
        raise ValueError("metacodes needs a model: pass -m <provider>/<model>")
    provider, sep, model = name.partition("/")
    if not sep:
        return None, name
    if not provider or not model:
        raise ValueError(f"malformed model name {model_name!r}: expected provider/model")
    return provider, model


def metacodes_flags(
    *,
    provider: Optional[str],
    model: str,
    disallowed_tools: str,
    reasoning_effort: Optional[str],
    max_tokens: Optional[int],
    features: Iterable[str] = (),
) -> List[str]:
    """The metacodes arguments for one headless trial, unquoted."""

    flags: List[str] = []
    if provider is not None:
        flags += ["--provider", provider]
    flags += ["--model", model, "--permission", "bypassPermissions", "--no-theme"]
    if disallowed_tools:
        flags += ["--disallowed-tools", disallowed_tools]
    if reasoning_effort is not None:
        if reasoning_effort not in REASONING_EFFORTS:
            raise ValueError(
                "reasoning_effort must be one of " + "/".join(REASONING_EFFORTS)
            )
        flags += ["--reasoning-effort", reasoning_effort]
    if max_tokens is not None:
        if isinstance(max_tokens, bool) or not isinstance(max_tokens, int) or max_tokens <= 0:
            raise ValueError("max_tokens must be a positive integer")
        flags += ["--max-tokens", str(max_tokens)]
    for feature in features:
        if feature not in ADVANCED_FEATURES:
            raise ValueError(
                "unknown feature " + repr(feature) + "; known: " + ",".join(ADVANCED_FEATURES)
            )
        if ADVANCED_FEATURES[feature].get("entry"):
            raise ValueError(f"feature {feature!r} is an entry, not a flag: use teamwork_run_command")
        flags.append(ADVANCED_FEATURES[feature]["flag"])
    return flags


def teamwork_flags(*, provider: Optional[str], model: str, reasoning_effort: Optional[str]) -> List[str]:
    """The `teamwork run` arguments for one trial's model: provider and
    model, and the reasoning effort on the seats that take one (implementer
    and reviewer; the verifier resolves its own)."""

    flags = (["--provider", provider] if provider is not None else []) + ["--model", model]
    if reasoning_effort is not None:
        if reasoning_effort not in REASONING_EFFORTS:
            raise ValueError("reasoning_effort must be one of " + "/".join(REASONING_EFFORTS))
        seats = {role: {"effort": reasoning_effort} for role in ("implementer", "reviewer")}
        flags += ["--config-json", json.dumps({"seats": seats}, separators=(",", ":"))]
    return flags


def checked_features(features: Iterable[str]) -> List[str]:
    """The features of one trial; teamwork runs alone, since `teamwork run`
    takes none of the other features' flags."""

    names = list(features)
    for name in names:
        if name not in ADVANCED_FEATURES:
            raise ValueError("unknown feature " + repr(name) + "; known: " + ",".join(ADVANCED_FEATURES))
    if TEAMWORK in names and len(names) > 1:
        raise ValueError("teamwork runs alone: `teamwork run` takes no other feature flag")
    return names


def task_difficulty(trial_dir: Path) -> str:
    """The `difficulty` a trial's task.toml declares (Harbor's trial
    config.json names the task directory), or "unknown"."""

    try:
        config = json.loads((Path(trial_dir) / "config.json").read_text(encoding="utf-8"))
        text = (Path(config["task"]["path"]) / "task.toml").read_text(encoding="utf-8")
    except (OSError, ValueError, KeyError, TypeError):
        return "unknown"
    match = re.search(r'^difficulty\s*=\s*"([A-Za-z]+)"', text, re.MULTILINE)
    return match.group(1).lower() if match else "unknown"


def teamwork_budget(difficulty: str) -> float:
    return TEAMWORK_BUDGET_USD.get(difficulty, TEAMWORK_DEFAULT_BUDGET_USD)


def mcp_servers_config(servers: Iterable[Any]) -> Dict[str, Dict[str, Any]]:
    """metacodes `mcpServers` entries for the MCP servers a Harbor task declares.

    Harbor passes a task's `[[environment.mcp_servers]]` (MCPServerConfig:
    name, transport sse/streamable-http/stdio, url, command, args, headers)
    to the agent; GAIA2's CLI mode serves its environment that way. Without
    them the agent would see none of the task's tools.
    """

    result: Dict[str, Dict[str, Any]] = {}
    for server in servers:
        get = server.get if isinstance(server, Mapping) else (lambda key, s=server: getattr(s, key, None))
        name, transport = get("name"), get("transport") or "sse"
        if not isinstance(name, str) or not name:
            raise ValueError("MCP server without a name")
        if transport in ("streamable-http", "sse"):
            if not get("url"):
                raise ValueError(f"MCP server {name} has no url")
            entry: Dict[str, Any] = {"type": "http" if transport == "streamable-http" else "sse", "url": get("url")}
            if get("headers"):
                entry["headers"] = dict(get("headers"))
        elif transport == "stdio":
            if not get("command"):
                raise ValueError(f"MCP server {name} has no command")
            entry = {"type": "stdio", "command": get("command"), "args": list(get("args") or [])}
        else:
            raise ValueError(f"MCP server {name}: unsupported transport {transport}")
        result[name] = entry
    return result


def run_command(
    *,
    state_dir: str,
    instruction_path: str,
    flags: Iterable[str],
    config_path: Optional[str] = None,
    binary: str = REMOTE_BINARY,
    kg_bin: str = REMOTE_KG_BIN,
    logs_dir: str = REMOTE_LOGS,
) -> str:
    """The bash script one trial runs inside the task container.

    - The instruction reaches metacodes on stdin from an uploaded file, never
      through argv: a task's own `pkill -f <name>` matches every process whose
      command line carries the name, the agent's included.
    - `--state-dir` gives the trial its own config and sessions without
      changing `HOME`, which the task's own commands still use.
    - TinyKG runs in the exclusive CLI mode on a fresh store in the state dir
      (doc/TINYKG_INTEGRATION.md, "Runtime modes": the mode for an isolated
      benchmark store).  The default shared-store mode would autostart a
      `kgd` that outlives the trial, and that daemon keeps every descriptor
      metacodes inherited beyond 0-2, so a pipe the caller handed metacodes
      never reaches EOF.
    - stdout (NDJSON, `--json --stream-json`) and stderr go straight to files
      on the log mount, no pipes: nothing a child keeps open can hold the
      trial, and the single `result` event stays apart from diagnostics.
    - The session transcript is copied to the log mount even when metacodes
      fails, then metacodes' own exit status is returned.
    """

    state = shlex.quote(state_dir)
    logs = shlex.quote(logs_dir)
    unset_remote = " ".join(REMOTE_TINYKG_ENV)
    lines = [
        "set -u",
        f"state={state}",
        'test ! -e "$state" || { echo "metacodes state dir already exists: $state" >&2; exit 70; }',
        'mkdir -p "$state" && chmod 700 "$state" || exit 70',
    ]
    if config_path is not None:
        lines.append(
            f'install -m 600 {shlex.quote(config_path)} "$state/config.json" || exit 71'
        )
    lines += [
        f"unset {unset_remote}",
        "export METACODES_KG_TRANSPORT=cli-exclusive METACODES_KG_AUTOSTART=0",
        f"export METACODES_KG_BIN={shlex.quote(kg_bin)}",
        'export METACODES_KG_STORE="$state/kg-store"',
        f"mkdir -p {logs} || exit 72",
        f"{shlex.quote(binary)} --state-dir \"$state\" "
        + " ".join(shlex.quote(flag) for flag in flags)
        + " - --json --stream-json"
        + f" <{shlex.quote(instruction_path)}"
        + f" >{logs}/{OUTPUT_FILENAME} 2>{logs}/{STDERR_FILENAME}",
        "status=$?",
        # A read loop, not `mapfile`: that builtin is bash 4, and macOS ships 3.2.
        "transcripts=()",
        'while IFS= read -r found; do transcripts+=("$found"); done'
        ' < <(find "$state" -type f -name transcript.jsonl 2>/dev/null)',
        'if [ "${#transcripts[@]}" -eq 1 ]; then',
        f'  cp -- "${{transcripts[0]}}" {logs}/{TRANSCRIPT_FILENAME}',
        "else",
        '  echo "expected one metacodes transcript, found ${#transcripts[@]}" >&2',
        '  if [ "$status" -eq 0 ]; then status=73; fi',
        "fi",
        'exit "$status"',
    ]
    return "\n".join(lines) + "\n"


def teamwork_run_command(
    *,
    state_dir: str,
    instruction_path: str,
    run_id: str,
    budget_usd: float,
    flags: Iterable[str],
    config_path: Optional[str] = None,
    binary: str = REMOTE_BINARY,
    kg_bin: str = REMOTE_KG_BIN,
    logs_dir: str = REMOTE_LOGS,
) -> str:
    """The bash script of one teamwork trial: the same state dir, config and
    TinyKG setup as run_command, then `teamwork run` on the task's working
    directory, approved with the trial's dollar cap.

    - Teamwork works in a git worktree and merges back into the repository,
      so a working directory outside any repository with a commit becomes one
      first: a snapshot commit of what the task image put there.
    - The instruction is the approved request, read from a file; a leading
      `[` would be parsed as an option segment, so such text gets a heading.
    - The run directory (ledger, seat records and logs, without worktrees)
      and `teamwork status --json` go to the log mount whatever the run's
      outcome, and the script exits 0 once that status exists: a failed or
      unmerged run is the task's result for the verifier to score, while
      `teamwork_problem` turns a run that never dispatched work into an
      error."""

    state = shlex.quote(state_dir)
    logs = shlex.quote(logs_dir)
    run = shlex.quote(binary) + ' --state-dir "$state"'
    identity = "-c user.name=metacodes-bench -c user.email=bench@metacodes.invalid"
    lines = [
        "set -u",
        f"state={state}",
        'test ! -e "$state" || { echo "metacodes state dir already exists: $state" >&2; exit 70; }',
        'mkdir -p "$state" && chmod 700 "$state" || exit 70',
    ]
    if config_path is not None:
        lines.append(f'install -m 600 {shlex.quote(config_path)} "$state/config.json" || exit 71')
    lines += [
        f"unset {' '.join(REMOTE_TINYKG_ENV)}",
        "export METACODES_KG_TRANSPORT=cli-exclusive METACODES_KG_AUTOSTART=0",
        f"export METACODES_KG_BIN={shlex.quote(kg_bin)}",
        'export METACODES_KG_STORE="$state/kg-store"',
        f"mkdir -p {logs} || exit 72",
        'test "$(pwd)" != / || { echo "teamwork needs a task working directory, not /" >&2; exit 74; }',
        "git config --global --add safe.directory '*' 2>/dev/null || true",
        "if ! git rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1; then",
        "  { git rev-parse --show-toplevel >/dev/null 2>&1 || git init -q; } &&",
        f"  git add -A && git {identity} commit -q --allow-empty -m 'bench snapshot before teamwork' || exit 75",
        "fi",
        'settings="${HOME:-/root}/.claude/settings.json"',
        'if [ -e "$settings" ]; then',
        f'  echo "keeping the image\'s own $settings: teamwork seats may ask for permissions" >>{logs}/{STDERR_FILENAME}',
        "else",
        '  mkdir -p "$(dirname "$settings")" &&'
        f' printf %s {shlex.quote(json.dumps({"permissions": {"allow": list(TEAMWORK_ALLOWED_TOOLS)}}))} > "$settings" || exit 78',
        "fi",
        'request="$state/request.md"',
        f'{{ if [ "$(head -c 1 {shlex.quote(instruction_path)})" = "[" ]; then printf "Task:\\n\\n"; fi;'
        f' cat {shlex.quote(instruction_path)}; }} > "$request" || exit 76',
        f'{run} --preview=teamwork teamwork run --request-file "$request" --approve'
        f" --budget-usd {budget_usd:g} --id {shlex.quote(run_id)} --events "
        + " ".join(shlex.quote(flag) for flag in flags)
        + f" >{logs}/{TEAMWORK_EVENTS_FILENAME} 2>>{logs}/{STDERR_FILENAME}",
        f'echo "teamwork run exited $?" >>{logs}/{STDERR_FILENAME}',
        teamwork_keep_run_command(state_dir=state_dir, run_id=run_id, logs_dir=logs_dir),
        f"{run} teamwork status {shlex.quote(run_id)} --json"
        f" >{logs}/{TEAMWORK_STATUS_FILENAME} 2>>{logs}/{STDERR_FILENAME} || exit 77",
    ]
    return "\n".join(lines) + "\n"


def parse_teamwork_status(text: str) -> Optional[Dict[str, Any]]:
    try:
        value = json.loads(text)
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


def teamwork_keep_run_command(*, state_dir: str, run_id: str, logs_dir: str = REMOTE_LOGS) -> str:
    """Shell that copies a teamwork run directory, without worktrees, to the
    log mount as `teamwork-run/` (the ledger, seat records and seat logs)."""

    run_dir = shlex.quote(f"{state_dir}/teamwork/{run_id}")
    kept = shlex.quote(f"{logs_dir}/{TEAMWORK_RUN_DIRNAME}")
    return (f"if [ -d {run_dir} ] && command -v tar >/dev/null 2>&1; then mkdir -p {kept} &&"
            f" tar -C {run_dir} --exclude=worktree -cf - . | tar -C {kept} -xf -"
            f" 2>>{shlex.quote(logs_dir + '/' + STDERR_FILENAME)}; fi")


def teamwork_status(logs_dir: Path) -> Optional[Dict[str, Any]]:
    try:
        return parse_teamwork_status((Path(logs_dir) / TEAMWORK_STATUS_FILENAME).read_text(encoding="utf-8"))
    except OSError:
        return None


def teamwork_problem(status: Optional[Dict[str, Any]]) -> Optional[str]:
    """Why a teamwork trial does not measure teamwork, or None: no status
    (the run never started), or no implementer seat that finished its work
    (every one failed, as on a provider or sandbox error), which the
    headless run counts as invalid too. A run that spent its budget worked
    on the task, so it is scored."""

    if status is None:
        return "teamwork wrote no status: the run did not start (see " + STDERR_FILENAME + ")"
    if status.get("state") == "budget_exhausted":
        return None
    seats = status.get("seats") if isinstance(status.get("seats"), list) else []
    if not any(isinstance(s, dict) and s.get("role") == "implementer" and s.get("status") == "done" for s in seats):
        return f"no teamwork implementer seat finished (state {status.get('state')}, detail {status.get('detail')})"
    return None


def teamwork_trace(logs_dir: Path) -> Dict[str, Any]:
    """A teamwork trial's trace: one step summarizing the run, and its spend
    from the run's budget ledger (seats report no per-request usage here)."""

    status = teamwork_status(logs_dir) or {}
    budget = status.get("budget") if isinstance(status.get("budget"), dict) else {}
    spent = float(budget.get("spent_usd") or 0.0)
    state = str(status.get("state") or "unknown")
    summary = {k: status.get(k) for k in ("state", "detail", "dispatched", "audits", "merge_conflicts")}
    return {
        "result": {"stop_reason": "teamwork_" + state, "turns": 0, "tool_calls": 0, "input_tokens": 0,
                   "output_tokens": 0, "cost_usd": spent, "text": "", "cache_read_input_tokens": 0,
                   "cache_creation_input_tokens": 0},
        "steps": [{"step_id": 1, "source": "agent", "message": "teamwork run " + state,
                   "reasoning_content": None, "tool_calls": [], "observations": [],
                   "extra": {"teamwork": summary, "budget": budget}}],
    }


def killed_trace() -> Dict[str, Any]:
    """The trace of a trial Harbor stopped before metacodes reported a result.

    A timeout (SIGTERM) or OOM kill tears metacodes down before its single
    terminal `result` event.  That is a failed trial worth zero reward, not a
    harness fault, so it gets a one-step marker trajectory.
    """

    return {
        "result": {
            "stop_reason": "killed_no_result",
            "turns": 0,
            "tool_calls": 0,
            "input_tokens": 0,
            "output_tokens": 0,
            "cost_usd": 0.0,
            "text": "",
            "cache_read_input_tokens": 0,
            "cache_creation_input_tokens": 0,
        },
        "steps": [
            {
                "step_id": 1,
                "source": "agent",
                "message": (
                    "metacodes was stopped before it reported a result "
                    "(timeout, SIGTERM or OOM)."
                ),
                "reasoning_content": None,
                "tool_calls": [],
                "observations": [],
                "extra": {"killed_no_result": True},
            }
        ],
    }


def load_trace(logs_dir: Path) -> Dict[str, Any]:
    """Read the trial's NDJSON output and transcript from the host log dir.

    Exactly the no-result case (a killed trial, or no output at all) becomes
    `killed_trace()`; any other defect in what metacodes wrote is raised.
    """

    output = Path(logs_dir) / OUTPUT_FILENAME
    transcript = Path(logs_dir) / TRANSCRIPT_FILENAME
    if not output.is_file():
        return killed_trace()
    try:
        return load_trace_ir(output, transcript)
    except FileNotFoundError:
        return killed_trace()
    except TraceError as exc:
        if "result event, found 0" in str(exc):
            return killed_trace()
        raise


def final_metrics_fields(result: Mapping[str, Any]) -> Dict[str, Any]:
    """ATIF final metrics from metacodes' `result` event.

    metacodes reports `input_tokens` without the cached part, as the
    Anthropic usage does; ATIF's prompt tokens include it.
    """

    cache_read = int(result.get("cache_read_input_tokens") or 0)
    cache_creation = int(result.get("cache_creation_input_tokens") or 0)
    cost = float(result["cost_usd"])
    return {
        "total_prompt_tokens": int(result["input_tokens"]) + cache_read + cache_creation,
        "total_completion_tokens": int(result["output_tokens"]),
        "total_cached_tokens": cache_read,
        "total_cost_usd": cost if cost > 0 else None,
        "extra": {
            "metacodes_turns": int(result["turns"]),
            "metacodes_tool_calls": int(result["tool_calls"]),
            "metacodes_stop_reason": str(result["stop_reason"]),
            "cache_creation_input_tokens": cache_creation,
        },
    }
