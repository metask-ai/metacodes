#!/usr/bin/env python3
"""Zero-network smoke for the real long-horizon runtime treatment wiring."""

from __future__ import annotations

import argparse
import json
import re
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict


ARMS = ("codex_style", "claude_style", "tinykg")
KG_TOOL_MARKERS = ("\n----- KgRemember -----\n", "\n----- KgRecall -----\n")
TASK_TOOL_MARKER = "\n----- TaskList -----\n"
FORMAL_TOOL_MARKER = "\n----- FormalAuditTask -----\n"
WORKBUDDY_DISABLED_TOOLS = (
    "Agent,Task,TaskBatch,TeamCreate,TeamDelete,SendMessage,"
    "EnterPlanMode,ExitPlanMode"
)


def _headless_protocol_smoke(binary: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="metacodes-headless-protocol-") as directory:
        root = Path(directory)
        home = root / "home"
        work = root / "work"
        home.mkdir()
        work.mkdir()
        target = work / ".gitignore"
        ready = root / "ready.json"
        request_log = root / "requests.jsonl"
        repo = Path(__file__).resolve().parents[2]
        provider = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "scripts.eval.workbuddy.mock_provider",
                "--ready",
                str(ready),
                "--request-log",
                str(request_log),
                "--scenario",
                "headless-permission-v1",
            ],
            cwd=repo,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        deadline = time.monotonic() + 5
        while not ready.exists() and provider.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        _require(ready.exists(), "headless protocol mock provider did not become ready")
        port = int(json.loads(ready.read_text(encoding="utf-8"))["port"])
        env = _base_env()
        env.update(
            {
                "HOME": str(home),
                "USERPROFILE": str(home),
                "METACODES_NO_PROBE": "1",
            }
        )
        try:
            completed = subprocess.run(
                [
                    str(binary),
                    "--api-key",
                    "metacodes-workbuddy-mock-only",
                    "--base-url",
                    f"http://127.0.0.1:{port}/v1/messages",
                    "--model",
                    "offline",
                    "--permission",
                    "bypassPermissions",
                    "--no-theme",
                    "--json",
                    "-p",
                    "exercise the protected write boundary",
                ],
                cwd=work,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                timeout=20,
                check=False,
            )
        finally:
            provider.terminate()
            try:
                provider.wait(timeout=2)
            except subprocess.TimeoutExpired:
                provider.kill()
                provider.wait(timeout=2)

        requests = request_log.read_text(encoding="utf-8").splitlines()
        _require(
            len(requests) == 2,
            "headless protocol request count drifted: "
            f"{len(requests)}; exit={completed.returncode}; "
            f"stdout={completed.stdout!r}; stderr={completed.stderr[-1000:]!r}; "
            f"target_exists={target.exists()}",
        )
        _require(completed.returncode == 0, f"headless protocol exited {completed.returncode}: {completed.stderr[-1000:]}")
        lines = completed.stdout.splitlines()
        _require(len(lines) == 1, f"headless --json stdout is not exactly one NDJSON event: {completed.stdout!r}")
        try:
            result = json.loads(lines[0])
        except json.JSONDecodeError as exc:
            raise SystemExit("headless --json stdout is not valid NDJSON") from exc
        _require(result.get("type") == "result", "headless --json omitted its result event")
        _require(result.get("text") == "protected write was denied safely", "headless continuation result drifted")
        _require("[Permission]" not in completed.stdout and "Allow?" not in completed.stdout, "permission prompt polluted NDJSON stdout")
        _require("[Permission]" not in completed.stderr and "Allow?" not in completed.stderr, "headless attempted an interactive permission prompt")
        _require(not target.exists(), "protected Write mutated the workspace")


def _workbuddy_tool_policy_smoke(binary: Path, tinykg_binary: Path) -> None:
    """Exercise the actual CLI-to-provider schema used by WorkBuddy."""

    with tempfile.TemporaryDirectory(prefix="metacodes-workbuddy-tool-policy-") as directory:
        root = Path(directory)
        ready = root / "ready.json"
        request_log = root / "requests.jsonl"
        repo = Path(__file__).resolve().parents[2]
        provider = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "scripts.eval.workbuddy.mock_provider",
                "--ready",
                str(ready),
                "--request-log",
                str(request_log),
                "--scenario",
                "guessed-disabled-tool-v1",
            ],
            cwd=repo,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        )
        deadline = time.monotonic() + 5
        while not ready.exists() and provider.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        _require(ready.exists(), "WorkBuddy tool-policy provider did not become ready")
        port = int(json.loads(ready.read_text(encoding="utf-8"))["port"])
        try:
            for run in range(2):
                home = root / f"home-{run}"
                work = root / "work"
                home.mkdir()
                work.mkdir(exist_ok=True)
                env = _base_env()
                env.update(
                    {
                        "HOME": str(home),
                        "USERPROFILE": str(home),
                        "METACODES_LONG_HORIZON_ARM": "tinykg",
                        "METACODES_KG_TRANSPORT": "cli-exclusive",
                        "METACODES_KG_BIN": str(tinykg_binary),
                        "METACODES_KG_STORE": str(home / "tinykg-store"),
                        "METACODES_NO_PROBE": "1",
                    }
                )
                completed = subprocess.run(
                    [
                        str(binary),
                        "--api-key",
                        "metacodes-workbuddy-mock-only",
                        "--base-url",
                        f"http://127.0.0.1:{port}/v1/messages",
                        "--model",
                        "offline",
                        "--permission",
                        "bypassPermissions",
                        "--disallowed-tools",
                        WORKBUDDY_DISABLED_TOOLS,
                        "--no-theme",
                        "--json",
                        "-p",
                        "inspect the task and finish",
                    ],
                    cwd=work,
                    env=env,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    encoding="utf-8",
                    timeout=20,
                    check=False,
                )
                _require(
                    completed.returncode == 0,
                    "WorkBuddy tool-policy run failed: " + completed.stderr[-1000:],
                )
        finally:
            provider.terminate()
            try:
                provider.wait(timeout=2)
            except subprocess.TimeoutExpired:
                provider.kill()
                provider.wait(timeout=2)

        rows = [
            json.loads(line)
            for line in request_log.read_text(encoding="utf-8").splitlines()
        ]
        _require(len(rows) == 4, "WorkBuddy tool-policy request count drifted")
        hidden = set(WORKBUDDY_DISABLED_TOOLS.split(","))
        required = {"KgRecall", "KgContext", "KgRemember", "TaskCreate", "TaskList", "TaskUpdate"}
        for row in rows:
            exposed = set(row.get("tool_names", []))
            _require(exposed.isdisjoint(hidden), "WorkBuddy exposed a disabled interactive/swarm tool")
            _require(required <= exposed, "WorkBuddy tool policy disabled TinyKG task/memory tools")
        schema_hashes = {row.get("tool_schema_sha256") for row in rows}
        _require(
            len(schema_hashes) == 1,
            "WorkBuddy tool schema drifted within or across identical fresh runs",
        )


def _base_env() -> Dict[str, str]:
    return {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("METACODES_")
        and not key.startswith("TINYKG_")
        and not key.startswith("CLAUDE_CODE_")
        and key != "RG_BIN"
    }


def _dump(binary: Path, tinykg_binary: Path, arm: str) -> str:
    with tempfile.TemporaryDirectory(prefix=f"metacodes-{arm}-") as directory:
        root = Path(directory)
        home = root / "home"
        work = root / "work"
        home.mkdir()
        work.mkdir()
        env = _base_env()
        env.update(
            {
                "HOME": str(home),
                "USERPROFILE": str(home),
                "METACODES_LONG_HORIZON_ARM": arm,
                "METACODES_NO_PROBE": "1",
            }
        )
        if arm == "tinykg":
            # Rule 8: benchmark memory is an isolated, single-run local Store.
            # Setting only the binary path must not accidentally opt production
            # Metacodes out of its daemon-default shared-Store boundary.
            env["METACODES_KG_TRANSPORT"] = "cli-exclusive"
            env["METACODES_KG_BIN"] = str(tinykg_binary)
        try:
            completed = subprocess.run(
                [
                    str(binary),
                    "--api-key",
                    "sk-offline-runtime-arm-smoke",
                    "--dump-prompt",
                    "--no-theme",
                ],
                cwd=work,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                timeout=20,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise SystemExit(f"{arm}: --dump-prompt timed out") from exc
    if completed.returncode != 0:
        raise SystemExit(
            f"{arm}: --dump-prompt exited {completed.returncode}: "
            f"{completed.stderr[-1000:]}"
        )
    return completed.stdout


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def _run_version(binary: Path, extra: "list[str]") -> "subprocess.CompletedProcess[str]":
    completed = subprocess.run(
        [str(binary), "--version", *extra],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=30,
    )
    _require(
        completed.returncode == 0,
        f"--version {' '.join(extra)} exited {completed.returncode}: {completed.stderr[:200]}",
    )
    return completed


def _version_line_matches(line: str, expected_semver: str) -> bool:
    """`metacodes <semver>` exactly; a `-dev` pre-release additionally allows the
    `+<commit12>` build metadata (`.dirty` appended for a dirty tree) that
    `--version` and the release manifest append (#80)."""
    if line == f"metacodes {expected_semver}":
        return True
    if "-" not in expected_semver:
        return False
    return re.fullmatch(re.escape(f"metacodes {expected_semver}") + r"\+[0-9a-f]{12}(\.dirty)?", line) is not None


def _version_output_smoke(binary: Path, expected_semver: str) -> None:
    """`--version` is a documented public surface (doc/API.md): the real binary
    prints exactly `metacodes <semver>` as its first stdout line (the build
    identity follows, #78) and exits 0.  The expected value comes from
    build.zig.zon via build.zig, so a version bump that misses src/version.zig
    (or vice versa) fails here instead of shipping a binary that mislabels
    itself."""
    completed = _run_version(binary, [])
    first_line = completed.stdout.split("\n", 1)[0]
    expected = f"metacodes {expected_semver}"
    _require(
        _version_line_matches(first_line, expected_semver),
        f"--version first line {first_line!r} != {expected!r} "
        "(src/version.zig and build.zig.zon must agree; a -dev version may carry +<commit12>[.dirty])",
    )
    _require(
        "\ncommit " in completed.stdout and "\nlayout " in completed.stdout,
        f"--version lacks the build identity lines: {completed.stdout!r}",
    )


def _version_json_smoke(binary: Path, expected_semver: str, repo_root: Path) -> None:
    """`--version --json` must describe the sources this checkout builds from
    (#78): the semver, the AgentCore ABI revision `sdk/zig/types.zig`
    declares, the TinyKG version `deps/tinykg.json` pins, and the TinyKG
    digest `vendor/tinykg/manifest.json` pins for the binary's own target.
    The sources are read here, independently of build.zig, so a baked value
    that drifts from its source fails on the real binary."""
    completed = _run_version(binary, ["--json"])
    try:
        document = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"--version --json stdout is not JSON: {completed.stdout[:200]!r}") from exc
    _require(
        document.get("name") == "metacodes" and _version_line_matches(f"metacodes {document.get('version')}", expected_semver),
        f"--version --json identity {document.get('name')!r} {document.get('version')!r} != metacodes {expected_semver}",
    )
    abi = re.search(
        r"^pub const ABI_REVISION: u32 = (\d+);$",
        (repo_root / "sdk" / "zig" / "types.zig").read_text(encoding="utf-8"),
        re.M,
    )
    _require(abi is not None, "sdk/zig/types.zig no longer declares ABI_REVISION")
    contract = document.get("contract") or {}
    _require(
        contract.get("binary_abi_version") == 1 and contract.get("binary_abi_revision") == int(abi.group(1)),
        f"--version --json contract {contract!r} != ABI v1 revision {abi.group(1)}",
    )
    _require(isinstance(contract.get("config_schema_version"), int), "contract.config_schema_version is not an integer")
    assets = {asset.get("name"): asset for asset in document.get("expected_runtime_assets") or []}
    _require(set(assets) == {"ripgrep", "tinykg"}, f"expected_runtime_assets names {sorted(assets)!r}")
    tinykg_contract = json.loads((repo_root / "deps" / "tinykg.json").read_text(encoding="utf-8"))
    _require(
        assets["tinykg"].get("version") == tinykg_contract["tinykg_version"],
        f"tinykg version {assets['tinykg'].get('version')!r} != deps/tinykg.json {tinykg_contract['tinykg_version']!r}",
    )
    family = "-".join(str(document.get("target", "")).split("-")[:2])
    manifest = json.loads((repo_root / "vendor" / "tinykg" / "manifest.json").read_text(encoding="utf-8"))
    pinned = None
    for artifact in manifest["artifacts"]:
        if family in artifact["targets"]:
            pinned = artifact["sha256"]
    _require(
        assets["tinykg"].get("sha256") == pinned,
        f"tinykg sha256 {assets['tinykg'].get('sha256')!r} != manifest value {pinned!r} for {family}",
    )


def _doctor_smoke(binary: Path, tinykg_binary: Path) -> None:
    """`metacodes doctor --json` (#78) reports the TinyKG binary the environment
    names — the build artifact has no install tree around it here, so the
    adjacent layout is checked by `verify_install_prefix.py --doctor` on the
    installed prefix — with a digest matching the pinned one, and `--strict`
    agrees with its own report."""
    env = dict(os.environ)
    env["METACODES_KG_BIN"] = str(tinykg_binary)
    daemon_binary = os.environ.get("METACODES_TEST_TINYKGD_BIN")
    if daemon_binary:
        env["METACODES_KGD_BIN"] = daemon_binary
    completed = subprocess.run(
        [str(binary), "doctor", "--json"],
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=60,
    )
    _require(completed.returncode == 0, f"doctor --json exited {completed.returncode}: {completed.stderr[:200]}")
    try:
        report = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"doctor --json stdout is not JSON: {completed.stdout[:200]!r}") from exc
    checks = {check.get("name"): check for check in report.get("checks") or []}
    _require(
        set(checks) == {"ripgrep", "tinykg", "tinykgd", "formal_kernel", "project_kernel"},
        f"doctor checks {sorted(checks)!r}",
    )
    tinykg = checks["tinykg"]
    _require(
        tinykg.get("source") == "env" and Path(str(tinykg.get("resolved_path"))).resolve() == tinykg_binary.resolve(),
        f"doctor tinykg {tinykg!r} did not come from METACODES_KG_BIN",
    )
    _require(tinykg.get("match") is True, f"doctor tinykg digest did not match the pinned one: {tinykg!r}")
    daemon = checks["tinykgd"]
    if daemon_binary:
        _require(daemon.get("source") == "env" and Path(str(daemon.get("resolved_path"))).resolve() == Path(daemon_binary).resolve(), f"doctor tinykgd {daemon!r} did not come from METACODES_KGD_BIN")
        _require(daemon.get("match") is True, f"doctor tinykgd digest did not match the pinned one: {daemon!r}")
    else:
        _require(daemon.get("resolved_path") is None, f"doctor tinykgd unexpectedly resolved without a test daemon: {daemon!r}")
    strict = subprocess.run(
        [str(binary), "doctor", "--strict"],
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=60,
    )
    def check_healthy(name: str, check: dict) -> bool:
        # Mirrors doctor.zig Report.healthy(): a binary this build never pinned
        # may be absent. Without tinykgd here the strict-exit assertion below
        # fails on every build whose bundle has no daemon artifact.
        if name in {"formal_kernel", "project_kernel", "tinykgd"}:
            if check.get("resolved_path") is None and check.get("expected_sha256") is None:
                return True
            if name == "tinykgd":
                return check.get("resolved_path") is not None and check.get("match") in (None, True)
            return (
                check.get("resolved_path") is not None
                and check.get("match") in (None, True)
                and check.get("provenance") is True
            )
        return check.get("resolved_path") is not None and check.get("match") in (None, True)

    healthy = all(check_healthy(name, check) for name, check in checks.items())
    _require(
        strict.returncode == (0 if healthy else 1),
        f"doctor --strict exited {strict.returncode} for a report that is {'healthy' if healthy else 'unhealthy'}",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--tinykg-binary", required=True, type=Path)
    parser.add_argument(
        "--expected-version",
        required=True,
        help="semver declared by build.zig.zon; asserted against `--version` output",
    )
    args = parser.parse_args()
    binary = args.binary.resolve()
    tinykg_binary = args.tinykg_binary.resolve()
    for label, path in (("metacodes", binary), ("TinyKG", tinykg_binary)):
        _require(path.is_file() and os.access(path, os.X_OK), f"{label} is not executable: {path}")

    _version_output_smoke(binary, args.expected_version)
    _version_json_smoke(binary, args.expected_version, Path(__file__).resolve().parents[2])
    _doctor_smoke(binary, tinykg_binary)

    dumps = {arm: _dump(binary, tinykg_binary, arm) for arm in ARMS}
    for arm, output in dumps.items():
        _require(TASK_TOOL_MARKER in output, f"{arm}: common TaskList tool is missing")

    codex = dumps["codex_style"]
    _require("# Memory" not in codex, "codex_style: Markdown memory leaked into prompt")
    _require("# Knowledge Graph" not in codex, "codex_style: TinyKG prompt leaked")
    _require(not any(marker in codex for marker in KG_TOOL_MARKERS), "codex_style: TinyKG tools leaked")
    _require(FORMAL_TOOL_MARKER not in codex, "codex_style: formal TinyKG audit tool leaked")
    _require(
        "TinyKG" not in codex and "kg-*" not in codex and "task_packet" not in codex,
        "codex_style: persistent task-DAG affordances leaked",
    )

    claude = dumps["claude_style"]
    _require("# Memory" in claude, "claude_style: Markdown memory prompt is missing")
    _require("# Knowledge Graph" not in claude, "claude_style: TinyKG prompt leaked")
    _require(not any(marker in claude for marker in KG_TOOL_MARKERS), "claude_style: TinyKG tools leaked")
    _require(FORMAL_TOOL_MARKER not in claude, "claude_style: formal TinyKG audit tool leaked")
    _require(
        "automatically imported into the knowledge graph" not in claude
        and "KgRemember" not in claude
        and "/kg sync" not in claude,
        "claude_style: Markdown-only instructions mention TinyKG",
    )
    _require(
        "TinyKG" not in claude and "kg-*" not in claude and "task_packet" not in claude,
        "claude_style: persistent task-DAG affordances leaked",
    )

    tinykg = dumps["tinykg"]
    _require("# Memory" in tinykg, "tinykg: Markdown memory prompt is missing")
    _require("# Knowledge Graph" in tinykg, "tinykg: knowledge-graph prompt is missing")
    _require(all(marker in tinykg for marker in KG_TOOL_MARKERS), "tinykg: KG tools are missing")
    _require(FORMAL_TOOL_MARKER in tinykg, "tinykg: formal TinyKG audit tool is missing")
    _require(
        "automatically imported into the knowledge graph" in tinykg,
        "tinykg: Markdown-to-graph projection contract is missing",
    )
    _require(
        "persistent task in TinyKG" in tinykg,
        "tinykg: TaskCreate still advertises session-only storage",
    )
    _headless_protocol_smoke(binary)
    _workbuddy_tool_policy_smoke(binary, tinykg_binary)
    print(
        "runtime arm smoke: codex_style/claude_style/tinykg + headless NDJSON "
        "permission + WorkBuddy provider-schema boundaries PASS "
        "(paid=0, external_network=0)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
