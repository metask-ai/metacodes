#!/usr/bin/env python3
"""The capability exchange end to end (doc/WIRE_PROTOCOL.md §2).

The installed `metacodes serve` (one session) against the loopback mock
provider (tests/e2e/daemon_mock_provider.py: no network, no paid call). This
script is the second process: a frontend adapter that speaks only the wire
protocol over HTTP, as a GUI or IDE frontend would. It declares what it
renders with `POST /capabilities`, reads `/events`, answers `/respond`, and
checks that the declaration, and nothing else, changes what it is asked:

  1. undeclared: an AskUserQuestion is announced and answered (legacy rule);
  2. a v2 frame is refused with core's version; nothing is installed;
  3. declared without ask_question: the question is never announced, the
     journal says `ui_request_unavailable`, the turn still ends, and the
     model is told the frontend cannot render questions (not NotATty);
  4. declared nothing: a Write permission prompt is unavailable, so denied,
     the file is not written, and the model is told it was denied without
     asking (not that the user declined);
  5. declared both: the same question and the same Write are announced,
     answered, and the file is written;
  6. a real refusal of the declared prompt keeps "user declined ... via
     prompt".

Run by `zig build test:product` (METACODES_DAEMON_E2E_BIN set by build.zig);
by hand: `zig build && python3 tests/e2e/frontend_capabilities_e2e.py`.
"""

from __future__ import annotations

import http.client
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

E2E_DIR = Path(__file__).resolve().parent
ROOT = E2E_DIR.parent.parent
EXE = "metacodes.exe" if os.name == "nt" else "metacodes"
BIN = Path(os.environ.get("METACODES_DAEMON_E2E_BIN") or ROOT / "zig-out" / "bin" / EXE)
LISTENING = re.compile(r"(http://\S+)  \(Ctrl\+C to quit\)")
# Every variable a developer's shell may point at a real store, token or bind.
SCRUBBED = (
    "METACODES_WEB_TOKEN", "METACODES_WEB_BIND", "METACODES_KG_BIN", "METACODES_KG_STORE",
    "METACODES_KG_TRANSPORT", "METACODES_KG_CONFIG", "METACODES_KG_URL", "METACODES_KG_API_KEY",
    "METACODES_KG_EXPECTED_BUILD_ID", "METACODES_KG_EXPECTED_SCHEMA_DIGEST", "METACODES_AUTH_FILE",
)


class Failure(Exception):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def wait_for(predicate, what: str, timeout: float = 60.0, proc: subprocess.Popen | None = None):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        if proc is not None and proc.poll() is not None:
            raise Failure(f"{what}: process exited {proc.returncode}")
        time.sleep(0.05)
    raise Failure(f"timed out waiting for {what}")


class Frontend:
    """The second-process frontend: HTTP in, wire lines out, nothing else."""

    def __init__(self, url: str) -> None:
        match = re.fullmatch(r"http://([^:/]+):(\d+)", url)
        check(match is not None, f"unexpected daemon URL {url}")
        self.host, self.port, self.origin = match.group(1), int(match.group(2)), url

    def call(self, method: str, path: str, body: object | None = None) -> tuple[int, str]:
        conn = http.client.HTTPConnection(self.host, self.port, timeout=10)
        try:
            payload = None if body is None else (body if isinstance(body, str) else json.dumps(body))
            headers = {"Origin": self.origin} if method == "POST" else {}
            conn.request(method, path, body=payload, headers=headers)
            response = conn.getresponse()
            return response.status, response.read().decode("utf-8")
        finally:
            conn.close()

    def declare(self, frame: object) -> tuple[int, str]:
        return self.call("POST", "/capabilities", frame)

    def state(self) -> dict:
        status, body = self.call("GET", "/state")
        check(status == 200, f"GET /state answered {status}: {body}")
        return json.loads(body)

    def send(self, text: str) -> None:
        status, body = self.call("POST", "/message", {"text": text})
        check(status == 200 and '"ok":true' in body, f"/message refused: {status} {body}")

    def respond(self, answer: dict) -> None:
        status, body = self.call("POST", "/respond", answer)
        check(status == 200, f"/respond answered {status}: {body}")

    def journal(self, until, timeout: float = 30.0) -> list[dict]:
        """The journal replayed from its start, read until `until(lines)` holds."""
        deadline = time.monotonic() + timeout
        lines: list[dict] = []
        while time.monotonic() < deadline:
            lines = self._replay(min(2.0, max(0.1, deadline - time.monotonic())), until)
            if until(lines):
                return lines
        raise Failure("journal never satisfied the wait; last lines:\n" + "\n".join(map(json.dumps, lines[-15:])))

    def _replay(self, seconds: float, until) -> list[dict]:
        conn = http.client.HTTPConnection(self.host, self.port, timeout=seconds)
        lines: list[dict] = []
        try:
            conn.request("GET", "/events?since=0")
            response = conn.getresponse()
            while True:
                raw = response.fp.readline()
                if not raw:
                    break
                if raw.startswith(b"data: "):
                    try:
                        lines.append(json.loads(raw[len(b"data: "):]))
                    except ValueError:
                        continue
                    if until(lines):
                        break
        except OSError:  # the read timeout ends one replay; the caller retries
            pass
        finally:
            conn.close()
        return lines


def of_type(lines: list[dict], line_type: str) -> list[dict]:
    return [line for line in lines if line.get("v") == 1 and line.get("type") == line_type]


def writes(lines: list[dict]) -> list[dict]:
    """The Write tool_result lines, in order."""
    return [line for line in of_type(lines, "tool_result") if line["data"]["name"] == "Write"]


def runs_done(lines: list[dict]) -> int:
    return len(of_type(lines, "run_done"))


def pending_request(lines: list[dict], kind: str, after: int) -> dict | None:
    """The `ui_request` of `kind` with id > `after`, if journaled."""
    for line in of_type(lines, "ui_request"):
        if line["kind"] == kind and line["id"] > after:
            return line
    return None


def start_daemon(tmp: Path, base_url: str) -> tuple[subprocess.Popen, Path, object]:
    env = {key: value for key, value in os.environ.items() if key not in SCRUBBED}
    home = tmp / "home"
    env.update({
        "HOME": str(home), "USERPROFILE": str(home), "METACODES_HOME": str(tmp / "state"),
        "METACODES_NO_PROBE": "1", "METACODES_KG_AUTOSTART": "0", "METACODES_JEV_URL": "off",
    })
    log_path = tmp / "daemon.out"
    log = open(log_path, "wb")
    proc = subprocess.Popen(
        [str(BIN), "serve", "0", "--api-key", "test", "--base-url", base_url],
        cwd=tmp / "work", env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
    )
    return proc, log_path, log


def stop(proc: subprocess.Popen | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=10)


def scenario(frontend: Frontend, work: Path) -> None:
    ack_permission = {
        "v": 1, "type": "capabilities_accepted", "ui_requests": ["permission"], "custom": [], "events": None,
        "ignored": {"ui_requests": [], "events": []},
    }

    # 1. Undeclared: the legacy frontend is asked, exactly as before.
    check(frontend.state().get("frontend_capabilities", "absent") is None, "a fresh session is not undeclared")
    frontend.send("CAPS_ASK while undeclared")
    lines = frontend.journal(lambda ls: pending_request(ls, "ask_question", 0) is not None)
    first = pending_request(lines, "ask_question", 0)
    frontend.respond({"id": first["id"], "answers": ["Red"]})
    lines = frontend.journal(lambda ls: runs_done(ls) >= 1)
    check({"v": 1, "type": "ui_request_closed", "id": first["id"], "outcome": "answered"} in lines,
          "the undeclared question was not answered")

    # 2. A frame of another version: refused with core's version, nothing installed.
    status, body = frontend.declare({"v": 2, "type": "capabilities", "ui_requests": ["permission", "ask_question"]})
    check(status == 400, f"a v2 frame answered {status}")
    check(json.loads(body) == {"v": 1, "type": "capabilities_refused", "reason": "SchemaVersionMismatch"}, body)
    check(frontend.state()["frontend_capabilities"] is None, "a refused frame was installed")

    # 3. Declared without ask_question: the question never reaches this frontend.
    status, body = frontend.declare({"v": 1, "type": "capabilities", "ui_requests": ["permission"]})
    check(status == 200 and json.loads(body) == ack_permission, f"declaration not accepted: {status} {body}")
    check(frontend.state()["frontend_capabilities"] == ack_permission, "/state does not report the declaration")
    frontend.send("CAPS_ASK while declared without questions")
    lines = frontend.journal(lambda ls: runs_done(ls) >= 2)
    check({"v": 1, "type": "ui_request_unavailable", "kind": "ask_question", "reason": "kind_not_declared"} in lines,
          "no ui_request_unavailable for the undeclared kind")
    check(len(of_type(lines, "ui_request")) == 1, "the undeclared kind was announced anyway")
    asked = [line for line in of_type(lines, "tool_result") if line["data"]["name"] == "AskUserQuestion"]
    check(len(asked) == 2 and asked[1]["data"]["is_error"], "AskUserQuestion did not fall back")
    told = asked[1]["data"]["content"]  # what the model reads
    check("cannot render questions" in told and "not an answer or a refusal from the user" in told
          and "NotATty" not in told, f"the model was not told the frontend cannot render questions: {told}")

    # 4. Declared nothing: a permission prompt is unavailable, which is a denial.
    status, body = frontend.declare({"v": 1, "type": "capabilities", "ui_requests": []})
    check(status == 200, f"empty declaration refused: {status} {body}")
    denied = work / "denied.txt"
    frontend.send(f"CAPS_WRITE:{denied.as_posix()}")
    lines = frontend.journal(lambda ls: runs_done(ls) >= 3)
    check({"v": 1, "type": "ui_request_unavailable", "kind": "permission", "reason": "kind_not_declared"} in lines,
          "no ui_request_unavailable for the permission prompt")
    check(len(of_type(lines, "ui_request")) == 1, "the permission prompt was announced anyway")
    check(not denied.exists(), "an unavailable permission prompt let Write run")
    told = writes(lines)[-1]["data"]["content"]
    check("denied without asking" in told and "cannot render permission prompts" in told
          and "user declined" not in told, f"the model was told the user declined: {told}")

    # 5. Declared both: the same requests are announced and answered.
    status, body = frontend.declare({"v": 1, "type": "capabilities", "ui_requests": ["permission", "ask_question"],
                                     "events": ["text_chunk", "tool_result", "hologram"]})
    accepted = json.loads(body)
    check(status == 200 and accepted["ui_requests"] == ["ask_question", "permission"], body)
    check(accepted["events"] == ["text_chunk", "tool_result"], body)  # CoreEvent tag order
    check(accepted["ignored"] == {"ui_requests": [], "events": ["hologram"]}, body)
    frontend.send("CAPS_ASK while declared")
    lines = frontend.journal(lambda ls: pending_request(ls, "ask_question", first["id"]) is not None)
    second = pending_request(lines, "ask_question", first["id"])
    frontend.respond({"id": second["id"], "answers": ["Blue"]})
    frontend.journal(lambda ls: runs_done(ls) >= 4)
    allowed = work / "allowed.txt"
    frontend.send(f"CAPS_WRITE:{allowed.as_posix()}")
    lines = frontend.journal(lambda ls: pending_request(ls, "permission", second["id"]) is not None)
    prompt = pending_request(lines, "permission", second["id"])
    frontend.respond({"id": prompt["id"], "choice": "allow_once"})
    lines = frontend.journal(lambda ls: runs_done(ls) >= 5)
    check(allowed.exists(), "Write did not run after the declared prompt was granted")

    # 6. A real refusal still reads as the user's refusal.
    declined = work / "declined.txt"
    frontend.send(f"CAPS_WRITE:{declined.as_posix()}")
    lines = frontend.journal(lambda ls: pending_request(ls, "permission", prompt["id"]) is not None)
    refusal = pending_request(lines, "permission", prompt["id"])
    frontend.respond({"id": refusal["id"], "choice": "deny_once"})
    lines = frontend.journal(lambda ls: runs_done(ls) >= 6)
    check(not declined.exists(), "a declined Write ran")
    told = writes(lines)[-1]["data"]["content"]
    check("user declined 'Write' via prompt" in told and "without asking" not in told, told)
    check(len(of_type(lines, "ui_request")) == 4, "unexpected number of announced requests")
    check(len(of_type(lines, "capabilities_accepted")) == 3, "every accepted declaration is journaled")
    check(all(line.get("v") == 1 for line in lines if "type" in line), "a wire line without v=1")
    if os.environ.get("CAPS_E2E_DUMP"):  # the whole journal, for a reviewer
        Path(os.environ["CAPS_E2E_DUMP"]).write_text("".join(json.dumps(line) + "\n" for line in lines), encoding="utf-8")


def main() -> int:
    if not BIN.is_file():
        print(f"missing metacodes binary: {BIN} (zig build first)", file=sys.stderr)
        return 2
    tmp = Path(tempfile.mkdtemp(prefix="caps-e2e-")).resolve()
    for sub in ("home", "state", "work"):
        (tmp / sub).mkdir()
    mock = daemon = None
    log = None
    status = 1
    try:
        url_file = tmp / "mock.url"
        mock = subprocess.Popen([sys.executable, str(E2E_DIR / "daemon_mock_provider.py"), str(url_file)],
                                stdin=subprocess.DEVNULL)
        wait_for(lambda: url_file.is_file(), "the mock provider", proc=mock)
        base_url = url_file.read_text(encoding="utf-8").strip()

        daemon, log_path, log = start_daemon(tmp, base_url)
        found = wait_for(lambda: LISTENING.search(log_path.read_text(encoding="utf-8", errors="replace")),
                         "the daemon's listening line", proc=daemon)
        scenario(Frontend(found.group(1)), tmp / "work")
        print("frontend capabilities e2e: OK")
        status = 0
    except Failure as failure:
        print(f"FAIL: {failure}", file=sys.stderr)
        log_path = tmp / "daemon.out"
        if log_path.is_file():
            print("--- daemon.out (tail)", file=sys.stderr)
            print("\n".join(log_path.read_text(encoding="utf-8", errors="replace").splitlines()[-40:]), file=sys.stderr)
    finally:
        stop(daemon)
        stop(mock)
        if log is not None:
            log.close()
        if os.environ.get("KEEP_CAPS_E2E_TMP") == "1":
            print(f"kept: {tmp}", file=sys.stderr)
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
