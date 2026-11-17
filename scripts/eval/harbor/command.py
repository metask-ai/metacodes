"""Harbor-free core of the metacodes Harbor adapter.

Everything here is plain Python (3.9, stdlib only) so the contract tests run
without Harbor installed: the release bundle check, the model split, the shell
command one trial runs, and the conversion of the run's output into the
ATIF-shaped steps Harbor stores.  ``metacodes_agent.py`` wires these into
Harbor's ``BaseInstalledAgent``.
"""

from __future__ import annotations

import json
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
    return flags


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
