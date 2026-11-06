#!/usr/bin/env python3
"""Plain headless says why a failed Run stopped (issue #417).

The installed `metacodes -p` against a loopback mock provider in this process
(no network, no paid call), asserting on the real exit code, stdout and stderr:

  1. every provider response ends on the wire's max-token terminal, on all four
     wires (Chat Completions, Responses, Anthropic, Gemini), with visible text
     and without. Four requests; exit 1; the partial text alone on stdout; one
     exhaustion notice on stderr;
  2. `--json` for the same Runs: the same exit code and an unchanged result
     line, with nothing on stderr;
  3. the same exhaustion through `--resume-response`, which prints its result
     on its own path;
  4. SIGINT and SIGTERM during a response (POSIX): exit 1 with a notice, and
     `--json` stays quiet;
  5. controls: an answer that recovers on the last continuation and a plain
     `end_turn` exit 0 with no notice; an HTTP 402 keeps its own diagnostic and
     does not gain this one.

Run by `zig build test:product` (METACODES_DAEMON_E2E_BIN set by build.zig);
by hand: `zig build && python3 tests/e2e/headless_stop_notice_e2e.py`.
"""

from __future__ import annotations

import http.server
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
EXE = "metacodes.exe" if os.name == "nt" else "metacodes"
BIN = Path(os.environ.get("METACODES_DAEMON_E2E_BIN") or ROOT / "zig-out" / "bin" / EXE)

EXHAUSTED_NOTICE = (
    "error: stopped (max_tokens_exhausted): the reply was still cut off at the output "
    "token limit after 3 continuations, so any text on stdout is incomplete."
)
ABORTED_NOTICE = "error: stopped (aborted): the run was interrupted, so any text on stdout is incomplete."

SEGMENTS = ("alpha-visible ", "beta ", "gamma ", "delta-still-truncated")
TIMEOUT = 120


class Failure(Exception):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise Failure(message)


def sse(*frames: dict) -> bytes:
    return b"".join(b"data: " + json.dumps(frame).encode() + b"\n\n" for frame in frames)


def named_sse(*frames: dict) -> bytes:
    return b"".join(
        f"event: {frame['type']}\n".encode() + b"data: " + json.dumps(frame).encode() + b"\n\n" for frame in frames
    )


def anthropic(text: str, cut: bool) -> bytes:
    frames = [{"type": "message_start", "message": {
        "id": "m", "role": "assistant", "model": "x", "usage": {"input_tokens": 1, "output_tokens": 1}}}]
    if text:
        frames += [
            {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
            {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}},
            {"type": "content_block_stop", "index": 0},
        ]
    frames += [
        {"type": "message_delta", "delta": {"stop_reason": "max_tokens" if cut else "end_turn"},
         "usage": {"output_tokens": 2}},
        {"type": "message_stop"},
    ]
    return sse(*frames)


def chat(text: str, cut: bool) -> bytes:
    return sse(
        {"choices": [{"index": 0, "delta": {"role": "assistant", "content": text}, "finish_reason": None}]},
        {"choices": [{"index": 0, "delta": {}, "finish_reason": "length" if cut else "stop"}]},
    ) + b"data: [DONE]\n\n"


def responses(text: str, cut: bool) -> bytes:
    usage = {"input_tokens": 1, "input_tokens_details": {"cached_tokens": 0}, "output_tokens": 2}
    frames: list[dict] = [{"type": "response.created", "response": {"id": "r"}}]
    if text:
        frames.append({"type": "response.output_text.delta", "item_id": "msg", "output_index": 0, "delta": text})
    if cut:
        frames.append({"type": "response.incomplete", "response": {
            "id": "r", "status": "incomplete", "incomplete_details": {"reason": "max_output_tokens"}, "usage": usage}})
    else:
        frames.append({"type": "response.completed", "response": {"id": "r", "status": "completed", "usage": usage}})
    return named_sse(*frames)


def gemini(text: str, cut: bool) -> bytes:
    return sse({
        "candidates": [{"content": {"role": "model", "parts": [{"text": text}]},
                        "finishReason": "MAX_TOKENS" if cut else "STOP"}],
        "usageMetadata": {"promptTokenCount": 1, "candidatesTokenCount": 2},
    })


# Each wire's response builder and the flags that select it.
WIRES = {
    "chat_completions": (chat, ["--model", "gpt-4o", "--openai-protocol", "chat"]),
    "responses": (responses, ["--model", "gpt-4o", "--openai-protocol", "responses"]),
    "anthropic": (anthropic, []),
    "gemini": (gemini, ["--model", "gemini-2.5-flash"]),
}

ASK_USER = anthropic("", False).replace(b'"end_turn"', b'"tool_use"').replace(
    b'data: {"type": "message_delta"',
    b'data: {"type": "content_block_start", "index": 0, "content_block": '
    b'{"type": "tool_use", "id": "tu1", "name": "AskUserQuestion", "input": {}}}\n\n'
    b'data: {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": '
    + json.dumps(json.dumps({"questions": [{"question": "Pick?", "header": "H", "options": [
        {"label": "Aaa", "description": "a"}, {"label": "Bbb", "description": "b"}]}]})).encode()
    + b'}}\n\ndata: {"type": "content_block_stop", "index": 0}\n\n'
    b'data: {"type": "message_delta"',
)
PAYMENT_REQUIRED = {"error": {"code": "insufficient_balance", "message": "Balance too low"}}


class Mock(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), Handler)
        self.script: list = []
        self.requests = 0
        self.lock = threading.Lock()
        self.responding = threading.Event()
        self.release = threading.Event()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server_address[1]}/v1/messages"

    def play(self, script: list) -> None:
        """Answer the next requests from `script`; the last entry repeats."""
        self.script = script
        self.requests = 0
        self.responding.clear()
        self.release.clear()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        server: Mock = self.server  # type: ignore[assignment]
        with server.lock:
            index = min(server.requests, len(server.script) - 1)
            server.requests += 1
            entry = server.script[index]
        if isinstance(entry, dict):  # an HTTP error body
            body = json.dumps(entry).encode()
            self.send_response(402)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        if isinstance(entry, tuple):  # bytes to send, then hold the stream open
            self.wfile.write(entry[0])
            self.wfile.flush()
            server.responding.set()
            server.release.wait(TIMEOUT)
            return
        self.wfile.write(entry)

    def log_message(self, *_args) -> None:
        pass


class Runner:
    def __init__(self, tmp: Path, mock: Mock) -> None:
        self.tmp = tmp
        self.mock = mock
        home = tmp / "home"
        self.env = {key: value for key, value in os.environ.items() if not key.startswith(
            ("METACODES_", "ANTHROPIC_", "OPENAI_", "GEMINI_", "GOOGLE_"))}
        self.env.update({
            "HOME": str(home), "USERPROFILE": str(home), "METACODES_HOME": str(tmp / "state"),
            "METACODES_NO_PROBE": "1", "METACODES_KG_AUTOSTART": "0", "METACODES_JEV_URL": "off",
        })

    def argv(self, *args: str) -> list[str]:
        return [str(BIN), *args, "--api-key", "test", "--base-url", self.mock.url]

    def popen(self, *args: str) -> subprocess.Popen:
        return subprocess.Popen(self.argv(*args), cwd=self.tmp / "work", env=self.env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def run(self, script: list, *args: str) -> tuple[int, str, str]:
        self.mock.play(script)
        return self.wait(self.popen(*args))

    @staticmethod
    def wait(proc: subprocess.Popen) -> tuple[int, str, str]:
        try:
            out, err = proc.communicate(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            raise Failure("metacodes did not exit") from None
        # Text-mode stdio on Windows turns "\n" into "\r\n".
        return (proc.returncode, out.decode("utf-8", "replace").replace("\r\n", "\n"),
                err.decode("utf-8", "replace").replace("\r\n", "\n"))


def exhausting(build, visible: bool) -> list:
    return [build(text if visible else "", True) for text in SEGMENTS]


def check_exhausted_plain(label: str, code: int, out: str, err: str, requests: int, visible: bool) -> None:
    expected = "".join(SEGMENTS) + "\n" if visible else "\n"
    check(requests == 4, f"{label}: {requests} requests, expected the initial one and 3 continuations")
    check(code == 1, f"{label}: exit {code}, expected 1")
    check(out == expected, f"{label}: stdout {out!r}, expected {expected!r}")
    check(err.count(EXHAUSTED_NOTICE + "\n") == 1, f"{label}: no exhaustion notice on stderr: {err!r}")


def exhaustion_plain_and_json(runner: Runner) -> None:
    for wire, (build, flags) in WIRES.items():
        for visible in (False, True):
            label = f"{wire} {'visible text' if visible else 'no visible text'}"
            script = exhausting(build, visible)

            code, out, err = runner.run(script, "-p", "write the report", *flags)
            check_exhausted_plain(label, code, out, err, runner.mock.requests, visible)

            code, out, err = runner.run(script, "-p", "write the report", "--json", *flags)
            check(code == 1, f"{label} --json: exit {code}, expected 1")
            check(err == "", f"{label} --json: stderr changed: {err!r}")
            check(out.count("\n") == 1, f"{label} --json: not one result line: {out!r}")
            line = json.loads(out)
            check(line["stop_reason"] == "max_tokens_exhausted", f"{label} --json: {line}")
            check(line["text_kind"] == "partial", f"{label} --json: {line}")
            check(line["text"] == ("".join(SEGMENTS) if visible else ""), f"{label} --json: {line}")
            check(line["continuations"] == 3, f"{label} --json: {line}")
            print(f"ok: {label}")


def resume_session(runner: Runner) -> str:
    """Suspend a Run on AskUserQuestion; the id of the session to resume."""
    code, _out, err = runner.run([ASK_USER], "-p", "please ask", "--suspendable")
    check(code == 2, f"resume setup: exit {code}, expected the suspended 2: {err!r}")
    found = re.search(r"session dir: (.+)", err)
    check(found is not None, f"resume setup: no session dir: {err!r}")
    assert found is not None
    return Path(found.group(1).strip()).name


def exhaustion_on_resume(runner: Runner) -> None:
    answer = '{"choice":"Aaa"}'
    for visible in (False, True):
        label = f"resume {'visible text' if visible else 'no visible text'}"
        script = exhausting(anthropic, visible)
        session = resume_session(runner)
        code, out, err = runner.run(script, "--session", session, "--resume-response", answer)
        check_exhausted_plain(label, code, out, err, runner.mock.requests, visible)

        session = resume_session(runner)
        code, out, err = runner.run(script, "--session", session, "--resume-response", answer, "--json")
        check(code == 1, f"{label} --json: exit {code}, expected 1")
        check(err == "", f"{label} --json: stderr changed: {err!r}")
        check(json.loads(out)["stop_reason"] == "max_tokens_exhausted", f"{label} --json: {out!r}")
        print(f"ok: {label}")


def interrupted(runner: Runner) -> None:
    if os.name == "nt":  # no way to deliver SIGINT/SIGTERM to one child here
        print("skip: interrupted (POSIX signals)")
        return
    # A signal does not wake a blocked stream read: the abort is seen when the
    # read returns. So the mock holds the response through the signal, then
    # closes it. The text may or may not have been read by then.
    held = anthropic("parti", False).split(b'data: {"type": "message_delta"')[0]
    for sig in (signal.SIGINT, signal.SIGTERM):
        for extra in ((), ("--json",)):
            label = f"{sig.name} {' '.join(extra) or 'plain'}"
            runner.mock.play([(held,)])
            proc = runner.popen("-p", "write the report", *extra)
            try:
                check(runner.mock.responding.wait(TIMEOUT), f"{label}: no request reached the mock")
                time.sleep(0.5)
                proc.send_signal(sig)
                time.sleep(0.5)
                runner.mock.release.set()
                code, out, err = runner.wait(proc)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.communicate()
            check(code == 1, f"{label}: exit {code}, expected 1")
            if extra:
                check(err == "", f"{label}: stderr changed: {err!r}")
                check(json.loads(out)["stop_reason"] == "aborted", f"{label}: {out!r}")
            else:
                check(out in ("parti\n", "\n"), f"{label}: stdout {out!r}")
                check(err.count(ABORTED_NOTICE + "\n") == 1, f"{label}: no notice on stderr: {err!r}")
            print(f"ok: {label}")


def controls(runner: Runner) -> None:
    for wire, (build, flags) in WIRES.items():
        script = [build(text, index + 1 < len(SEGMENTS)) for index, text in enumerate(SEGMENTS)]
        code, out, err = runner.run(script, "-p", "write the report", *flags)
        check(code == 0, f"{wire} recovered: exit {code}: {err!r}")
        check(out == "".join(SEGMENTS) + "\n", f"{wire} recovered: stdout {out!r}")
        check("stopped (" not in err, f"{wire} recovered: a stop notice: {err!r}")

        code, out, err = runner.run([build("done", False)], "-p", "write the report", *flags)
        check(code == 0 and out == "done\n", f"{wire} end_turn: exit {code} stdout {out!r}")
        check("stopped (" not in err, f"{wire} end_turn: a stop notice: {err!r}")
        print(f"ok: {wire} controls")

    code, _out, err = runner.run([PAYMENT_REQUIRED], "-p", "write the report")
    check(code == 1, f"HTTP 402: exit {code}, expected 1")
    check("HTTP 402" in err and "insufficient_balance" in err, f"HTTP 402: diagnostic lost: {err!r}")
    check("stopped (" not in err, f"HTTP 402: a stop notice on top of the diagnostic: {err!r}")
    print("ok: HTTP 402 control")


def main() -> int:
    if not BIN.is_file():
        print(f"FAIL: {BIN} not found (zig build first)", file=sys.stderr)
        return 1
    tmp = Path(tempfile.mkdtemp(prefix="headless-stop-notice."))
    for sub in ("home", "state", "work"):
        (tmp / sub).mkdir()
    mock = Mock()
    threading.Thread(target=mock.serve_forever, daemon=True).start()
    status = 1
    try:
        runner = Runner(tmp, mock)
        exhaustion_plain_and_json(runner)
        exhaustion_on_resume(runner)
        interrupted(runner)
        controls(runner)
        print("headless stop notice e2e: OK")
        status = 0
    except Failure as failure:
        print(f"FAIL: {failure}", file=sys.stderr)
    finally:
        mock.release.set()
        mock.shutdown()
        mock.server_close()
        shutil.rmtree(tmp, ignore_errors=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
