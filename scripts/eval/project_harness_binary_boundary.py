"""Native zero-provider L2 for the production/enforced vs eval/shadow boundary.

The test builds one real promoted rule through the E2 lifecycle, then drives
both complete CLI artifacts through the same loopback Anthropic request.  It
proves that shadow is a compile-time artifact property: the first provider body
is byte-identical, the shadow app records a block but dispatches Write, and the
production app lowers the same requested Write into one Lean-authorized native
exact Edit without another provider-authored repair turn.

This is mechanism evidence only.  The provider is scripted, no credential is
loaded, and the result must never be reported as an E3 model-quality outcome.
"""

from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import socketserver
import subprocess
import tempfile
import threading
from typing import Any, Dict, List, Mapping, Sequence

# Windows portability (see scripts/eval/model.py): os.open text mode must never
# touch artifacts, directory descriptors cannot be opened, and permission bits
# are synthetic there.
_O_BINARY = getattr(os, "O_BINARY", 0)
_POSIX_MODE_BITS = os.name != "nt"


def _fsync_directory(path) -> None:
    if os.name == "nt":
        return
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


if __package__ in {None, ""}:
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from scripts.eval.memory_agent_runtime import _text_sse, _tool_results, _tool_sse  # type: ignore
    from scripts.eval.project_harness_evolution import run_evolution  # type: ignore
else:
    from .memory_agent_runtime import _text_sse, _tool_results, _tool_sse
    from .project_harness_evolution import run_evolution


SCHEMA = "metacodes-project-harness-binary-boundary-v2"
SHADOW_SESSION = "111111111111111111111111"
ENFORCED_SESSION = "222222222222222222222222"
MAX_REQUEST_BYTES = 16 * 1024 * 1024


class BoundaryError(RuntimeError):
    """Fail-closed boundary validation error."""


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _file_sha256(path: Path) -> str:
    return _sha256(path.read_bytes())


def _tool_result_error_flags(body: Mapping[str, Any]) -> Dict[str, bool]:
    """Read provider-visible tool-result protocol flags without inferring from content."""

    result: Dict[str, bool] = {}
    messages = body.get("messages")
    if not isinstance(messages, list):
        raise BoundaryError("provider request has no messages array")
    for message in messages:
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict) or item.get("type") != "tool_result":
                continue
            tool_id = item.get("tool_use_id")
            if not isinstance(tool_id, str):
                raise BoundaryError("provider-visible tool result has no string id")
            raw_is_error = item.get("is_error", False)
            if not isinstance(raw_is_error, bool):
                raise BoundaryError("provider-visible tool result has invalid is_error")
            if tool_id in result:
                raise BoundaryError("provider-visible tool result id is duplicated")
            result[tool_id] = raw_is_error
    return result


def _write_report(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    raw = (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
    temporary = path.parent / f".{path.name}.{os.getpid()}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0) | _O_BINARY
    fd = os.open(temporary, flags, 0o600)
    try:
        offset = 0
        while offset < len(raw):
            wrote = os.write(fd, raw[offset:])
            if wrote <= 0:
                raise BoundaryError("short boundary report write")
            offset += wrote
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        if temporary.exists():
            temporary.unlink()


def _canonical_lake(repo: Path, candidate: Path) -> Path:
    """Resolve elan's multi-link proxy to the single-link frozen toolchain."""

    candidate = candidate.resolve(strict=True)
    if candidate.stat().st_nlink == 1:
        return candidate
    completed = subprocess.run(
        [str(candidate), "env", "which", "lake"],
        cwd=repo / "control-plane/lean",
        env={"PATH": os.defpath, "HOME": str(Path.home()), "LANG": "C", "LC_ALL": "C"},
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        timeout=10,
        check=True,
    )
    resolved = Path(completed.stdout.strip()).resolve(strict=True)
    if not resolved.is_file() or resolved.stat().st_nlink != 1:
        raise BoundaryError("lake toolchain artifact is not a single-link regular file")
    return resolved


class BoundaryProvider:
    """Scripted provider that branches only on the real Write tool result."""

    def __init__(self, target: Path) -> None:
        self.target = target
        self.raw_requests: List[bytes] = []
        self.requests: List[Mapping[str, Any]] = []
        self.tool_results: Dict[str, str] = {}
        self.tool_result_is_errors: Dict[str, bool] = {}
        self._server: socketserver.TCPServer | None = None
        self._thread: threading.Thread | None = None
        self.port: int | None = None

    def __enter__(self) -> "BoundaryProvider":
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args: Any) -> None:
                return

            def do_POST(self) -> None:  # noqa: N802 - stdlib callback name
                try:
                    length = int(self.headers.get("content-length", "0"))
                    if length <= 0 or length > MAX_REQUEST_BYTES:
                        raise BoundaryError("provider request size is invalid")
                    raw = self.rfile.read(length)
                    if len(raw) != length:
                        raise BoundaryError("provider request was truncated")
                    body = json.loads(raw)
                    if not isinstance(body, dict):
                        raise BoundaryError("provider request is not an object")
                    outer.raw_requests.append(raw)
                    outer.requests.append(body)
                    request_id = len(outer.requests)
                    if request_id == 1:
                        response = _tool_sse(
                            [("boundary-write", "Write", {
                                "file_path": str(outer.target),
                                "content": "new-via-edit\n",
                            })],
                            request_id,
                        )
                    else:
                        results = _tool_results(body)
                        # Shadow dispatches the requested Write; production
                        # completes the same tool id through the host rewrite.
                        # In neither arm does this scripted provider author an
                        # Edit or receive a repair contract.
                        if "boundary-write" not in results:
                            raise BoundaryError("provider did not receive the original tool result")
                        outer.tool_results.update(results)
                        outer.tool_result_is_errors.update(_tool_result_error_flags(body))
                        response = _text_sse("boundary-complete", request_id)
                except (BoundaryError, UnicodeError, json.JSONDecodeError, ValueError):
                    self.send_response(400)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.end_headers()
                try:
                    self.wfile.write(response)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return

        socketserver.TCPServer.allow_reuse_address = True
        self._server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
        self.port = int(self._server.server_address[1])
        self._thread = threading.Thread(
            target=self._server.serve_forever,
            name="project-harness-boundary-provider",
            daemon=True,
        )
        self._thread.start()
        return self

    @property
    def url(self) -> str:
        if self.port is None:
            raise BoundaryError("provider has not started")
        return f"http://127.0.0.1:{self.port}/v1/messages"

    def __exit__(self, *_args: Any) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
        if self._thread is not None:
            self._thread.join(timeout=2)


def _journal_events(path: Path) -> List[Mapping[str, Any]]:
    raw = path.read_bytes()
    events: List[Mapping[str, Any]] = []
    for index, line in enumerate(raw.splitlines(keepends=True)):
        if not line.endswith(b"\n"):
            raise BoundaryError("tool observation journal is truncated")
        value = json.loads(line)
        if not isinstance(value, dict) or value.get("sequence") != index:
            raise BoundaryError("tool observation journal sequence drift")
        events.append(value)
    if len(events) < 3:
        raise BoundaryError("tool observation journal is incomplete")
    return events


def _journal_summary(path: Path) -> Dict[str, Any]:
    actuations: set[str] = set()
    blocks: List[str] = []
    dispatches: List[str] = []
    dispatch_pairs: List[Dict[str, str]] = []
    dispatch_finishes: List[Dict[str, Any]] = []
    finished = False
    for record in _journal_events(path):
        event = record.get("event")
        if not isinstance(event, dict):
            raise BoundaryError("journal event is invalid")
        if "run_finished" in event:
            finished = True
        tool_event = event.get("tool_observation")
        if not isinstance(tool_event, dict):
            continue
        batch = tool_event.get("formal_decision_batch")
        if isinstance(batch, dict):
            actuation = batch.get("actuation")
            if isinstance(actuation, str):
                actuations.add(actuation)
            decisions = batch.get("decisions")
            if isinstance(decisions, list) and any(
                isinstance(item, dict) and item.get("result") == "block"
                for item in decisions
            ):
                dispatch_id = batch.get("dispatch_id")
                if isinstance(dispatch_id, str):
                    blocks.append(dispatch_id)
        started = tool_event.get("dispatch_started")
        if isinstance(started, dict) and isinstance(started.get("dispatched_name"), str):
            dispatches.append(str(started["dispatched_name"]))
            requested_name = started.get("requested_name")
            if not isinstance(requested_name, str):
                raise BoundaryError("dispatch start has no requested tool name")
            dispatch_pairs.append({
                "requested_name": requested_name,
                "dispatched_name": str(started["dispatched_name"]),
            })
        finished_event = tool_event.get("dispatch_finished")
        if isinstance(finished_event, dict):
            requested_name = finished_event.get("requested_name")
            dispatched_name = finished_event.get("dispatched_name")
            outcome = finished_event.get("outcome")
            error_code = finished_event.get("error_code")
            effect_valid = finished_event.get("effect_valid")
            if (
                not isinstance(requested_name, str)
                or not isinstance(dispatched_name, str)
                or not isinstance(outcome, str)
                or (error_code is not None and not isinstance(error_code, str))
                or not isinstance(effect_valid, bool)
            ):
                raise BoundaryError("dispatch finish evidence is malformed")
            dispatch_finishes.append({
                "requested_name": requested_name,
                "dispatched_name": dispatched_name,
                "outcome": outcome,
                "error_code": error_code,
                "effect_valid": effect_valid,
            })
    if not finished:
        raise BoundaryError("journal has no durable run_finished event")
    return {
        "actuations": sorted(actuations),
        "blocked_dispatch_ids": blocks,
        "dispatched_tools": dispatches,
        "dispatch_pairs": dispatch_pairs,
        "dispatch_finishes": dispatch_finishes,
        "journal_sha256": _file_sha256(path),
    }


def _run_arm(
    *,
    binary: Path,
    session_id: str,
    project: Path,
    home: Path,
    state_root: Path,
    kernel: Path,
    kernel_sha256: str,
    target: Path,
) -> Dict[str, Any]:
    target.write_text("old\n", encoding="utf-8")
    session_dir = state_root / session_id
    if session_dir.exists():
        raise BoundaryError("boundary session directory already exists")
    with BoundaryProvider(target) as provider:
        env = {
            "PATH": os.defpath,
            "HOME": str(home),
            "TMPDIR": tempfile.gettempdir(),
            "LANG": "C",
            "LC_ALL": "C",
            "TZ": "UTC",
            "METACODES_NO_PROBE": "1",
            "METACODES_NO_AUTO_RECALL": "1",
            "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
            "METACODES_KG_TRANSPORT": "cli-exclusive",
            "METACODES_KG_BIN": "/nonexistent/metacodes-boundary-tinykg",
            "METACODES_PROJECT_KERNEL_PATH": str(kernel),
            "METACODES_PROJECT_KERNEL_SHA256": kernel_sha256,
            # A hostile-looking variable must not turn production into shadow;
            # no source path reads it.  Both arms receive it so it cannot alter
            # the provider-visible prefix comparison.
            "METACODES_PROJECT_HARNESS_SHADOW": "1",
        }
        completed = subprocess.run(
            [
                str(binary),
                "--base-url",
                provider.url,
                "--model",
                "glm-5.2",
                "--api-key",
                "loopback-boundary-only",
                "--permission",
                "bypassPermissions",
                "--session",
                session_id,
                "--no-theme",
                "--max-tokens",
                "128",
                "-p",
                "Update protected.txt to the new value.",
                "--json",
            ],
            cwd=project,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )
    if completed.returncode != 0:
        raise BoundaryError(
            f"boundary app failed ({binary.name}, exit={completed.returncode}): "
            f"{completed.stderr.decode('utf-8', 'replace')[-1000:]}"
        )
    if not provider.raw_requests:
        raise BoundaryError("boundary app made no loopback provider request")
    rows = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
    results = [row for row in rows if isinstance(row, dict) and row.get("type") == "result"]
    if len(results) != 1 or results[0].get("stop_reason") != "end_turn":
        raise BoundaryError(
            "boundary app produced no complete result: "
            f"rows={rows!r} provider_requests={len(provider.raw_requests)} "
            f"stderr={completed.stderr.decode('utf-8', 'replace')[-1000:]!r}"
        )
    journal = session_dir / "tool-observations.jsonl"
    if not journal.is_file():
        raise BoundaryError("boundary app produced no observation journal")
    return {
        "binary_sha256": _file_sha256(binary),
        "first_request": provider.raw_requests[0],
        "provider_requests": len(provider.raw_requests),
        "provider_tool_results": dict(provider.tool_results),
        "provider_tool_result_is_errors": dict(provider.tool_result_is_errors),
        "target_content": target.read_text(encoding="utf-8"),
        "journal": _journal_summary(journal),
    }


def run_boundary(
    repo: Path,
    production: Path,
    shadow: Path,
    driver: Path,
    kernel: Path,
    lake: Path,
    builder: Path,
) -> Dict[str, Any]:
    repo = repo.resolve(strict=True)
    if not repo.is_dir():
        raise BoundaryError("repository root is not a directory")
    production = production.resolve(strict=True)
    shadow = shadow.resolve(strict=True)
    driver = driver.resolve(strict=True)
    kernel = kernel.resolve(strict=True)
    lake = _canonical_lake(repo, lake)
    builder = builder.resolve(strict=True)
    for path in (production, shadow, driver, kernel, lake, builder):
        if not path.is_file():
            raise BoundaryError(f"missing boundary artifact: {path}")
    if production == shadow or _file_sha256(production) == _file_sha256(shadow):
        raise BoundaryError("production and shadow artifacts are not distinct")
    runtime_switch = b"METACODES_PROJECT_HARNESS_SHADOW"
    if any(runtime_switch in path.read_bytes() for path in (repo / "src").rglob("*.zig")):
        raise BoundaryError("production source exposes a runtime shadow environment switch")

    with tempfile.TemporaryDirectory(prefix="metacodes-project-harness-boundary-") as raw_root:
        root = Path(raw_root).resolve() / "lifecycle"
        lifecycle = run_evolution(repo, root, driver, kernel, lake, builder)
        project = root / "project"
        home = root / "home"
        prepare = json.loads((root / "lifecycle-prepare.json").read_text(encoding="utf-8"))
        rules_dir = Path(str(prepare["rules_dir"]))
        state_root = rules_dir.parent
        target = project / "protected.txt"
        kernel_sha256 = _file_sha256(kernel)

        shadow_result = _run_arm(
            binary=shadow,
            session_id=SHADOW_SESSION,
            project=project,
            home=home,
            state_root=state_root,
            kernel=kernel,
            kernel_sha256=kernel_sha256,
            target=target,
        )
        enforced_result = _run_arm(
            binary=production,
            session_id=ENFORCED_SESSION,
            project=project,
            home=home,
            state_root=state_root,
            kernel=kernel,
            kernel_sha256=kernel_sha256,
            target=target,
        )

        first_shadow = shadow_result.pop("first_request")
        first_enforced = enforced_result.pop("first_request")
        if first_shadow != first_enforced:
            raise BoundaryError("provider-visible first request differs across actuation artifacts")
        if shadow_result["journal"]["actuations"] != ["shadow"]:
            raise BoundaryError("shadow artifact did not record shadow actuation")
        if "boundary-write" not in shadow_result["journal"]["blocked_dispatch_ids"]:
            raise BoundaryError("shadow artifact did not observe the expected formal block")
        if "Write" not in shadow_result["journal"]["dispatched_tools"]:
            raise BoundaryError("shadow artifact actuated the block instead of dispatching Write")
        if shadow_result["journal"]["dispatch_pairs"] != [{
            "requested_name": "Write",
            "dispatched_name": "Write",
        }]:
            raise BoundaryError("shadow artifact did not execute exactly one requested Write")
        if shadow_result["journal"]["dispatch_finishes"] != [{
            "requested_name": "Write",
            "dispatched_name": "Write",
            "outcome": "tool_error",
            "error_code": "NotRead",
            # No mutation effect was reported, but the empty effect slot is
            # itself structurally valid rather than corrupt/incomplete.
            "effect_valid": True,
        }]:
            raise BoundaryError("shadow artifact did not durably record the real Write outcome")
        if shadow_result["target_content"] != "old\n":
            raise BoundaryError("shadow Write unexpectedly changed the unread existing file")
        shadow_tool_result = shadow_result["provider_tool_results"].get("boundary-write")
        try:
            shadow_tool_payload = json.loads(shadow_tool_result or "")
        except json.JSONDecodeError as exc:
            raise BoundaryError("shadow provider received a malformed tool result") from exc
        if (
            not isinstance(shadow_tool_payload, dict)
            or not isinstance(shadow_tool_payload.get("error"), dict)
            or shadow_tool_payload["error"].get("code") != "not_read"
        ):
            raise BoundaryError(
                "shadow provider did not receive the real NotRead result: "
                f"{shadow_tool_result!r}"
            )
        if shadow_result["provider_requests"] != 2:
            raise BoundaryError("shadow artifact deviated from the deterministic two-request path")
        if shadow_result["provider_tool_result_is_errors"] != {"boundary-write": True}:
            raise BoundaryError("shadow provider-visible NotRead result was not marked is_error")
        if enforced_result["journal"]["actuations"] != ["enforced"]:
            raise BoundaryError("production artifact did not remain enforced")
        if "boundary-write" not in enforced_result["journal"]["blocked_dispatch_ids"]:
            raise BoundaryError("production artifact did not record the expected block")
        if "Write" in enforced_result["journal"]["dispatched_tools"]:
            raise BoundaryError("production artifact dispatched a formally blocked Write")
        if enforced_result["journal"]["dispatch_pairs"] != [{
            "requested_name": "Write",
            "dispatched_name": "Edit",
        }]:
            raise BoundaryError("production artifact did not execute exactly one host Write-to-Edit rewrite")
        if enforced_result["journal"]["dispatch_finishes"] != [{
            "requested_name": "Write",
            "dispatched_name": "Edit",
            "outcome": "succeeded",
            "error_code": None,
            "effect_valid": True,
        }]:
            raise BoundaryError(
                "production artifact did not durably record the recovered Edit outcome: "
                f"{enforced_result['journal']['dispatch_finishes']!r}"
            )
        if enforced_result["provider_requests"] != 2:
            raise BoundaryError("production artifact added a provider repair round trip")
        if enforced_result["provider_tool_result_is_errors"] != {"boundary-write": False}:
            raise BoundaryError("production provider-visible recovery receipt was marked as an error")
        if enforced_result["target_content"] != "new-via-edit\n":
            raise BoundaryError("production recovery side effect was not re-observed")
        enforced_tool_result = enforced_result["provider_tool_results"].get("boundary-write")
        try:
            enforced_tool_payload = json.loads(enforced_tool_result or "")
        except json.JSONDecodeError as exc:
            raise BoundaryError("production provider received a malformed tool result") from exc
        if (
            not isinstance(enforced_tool_payload, dict)
            or enforced_tool_payload.get("success") is not True
            or enforced_tool_payload.get("recovery") != "lean_authorized_source_cas"
        ):
            raise BoundaryError("production provider did not receive the bounded recovery receipt")

        return {
            "schema_version": SCHEMA,
            "evidence_level": "E2-native-binary-boundary",
            "quality_evidence": False,
            "outcome_superiority_claimed": False,
            "provider_mode": "loopback-scripted",
            "external_provider_requests": 0,
            "paid_cost_usd": 0,
            "first_provider_request_sha256": _sha256(first_shadow),
            "first_provider_request_bytes": len(first_shadow),
            "provider_visible_prefix_equal": True,
            "production_runtime_shadow_switch_absent": True,
            "hostile_shadow_env_did_not_change_production": True,
            "lifecycle_bundle_sha256": lifecycle["bundle_sha256"],
            "shadow": shadow_result,
            "enforced": enforced_result,
        }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--production", type=Path, required=True)
    parser.add_argument("--shadow", type=Path, required=True)
    parser.add_argument("--driver", type=Path, required=True)
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--lake", type=Path)
    parser.add_argument("--builder", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        lake = args.lake
        if lake is None:
            discovered = shutil.which("lake")
            lake = Path(discovered) if discovered else Path.home() / ".elan/bin/lake"
        result = run_boundary(
            args.repo,
            args.production,
            args.shadow,
            args.driver,
            args.kernel,
            lake,
            args.builder,
        )
        if args.output is not None:
            _write_report(args.output.resolve(), result)
    except (BoundaryError, OSError, subprocess.SubprocessError) as exc:
        print(f"project-Harness binary boundary failed: {exc}", file=os.sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
