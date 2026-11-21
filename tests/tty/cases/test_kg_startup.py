import socket
import threading
import time

from tty_driver import run, READY, wait_for, arrival_time
from asserts import TTYAssert
from slow_mock_server import SlowMockServer, simple_text

PLACEHOLDER = 'Try "fix typecheck errors"'.encode()
PROMPT_BOUND_S = 8.0
EXIT_BOUND_S = 15.0


class SilentKgService:
    def __init__(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(16)
        self.port = self.sock.getsockname()[1]
        self.accepted = 0
        self.conns = []
        self.closed = False
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def _serve(self):
        while not self.closed:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            self.accepted += 1
            self.conns.append(conn)

    def env(self):
        return {
            "METACODES_KG_URL": f"http://127.0.0.1:{self.port}",
            "METACODES_KG_API_KEY": "tty-kg-key",
            "METACODES_KG_EXPECTED_BUILD_ID": "sha256:" + "0" * 64,
        }

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.closed = True
        try:
            self.sock.close()
        except OSError:
            pass
        for conn in self.conns:
            try:
                conn.close()
            except OSError:
                pass


def test_prompt_is_up_while_tinykg_never_answers_and_leaving_does_not_wait(bin_path):
    with SilentKgService() as kg:
        timeline = []
        started = time.monotonic()
        raw = run(bin_path, [READY, "key:ctrl_c", "key:ctrl_c"],
                  env=kg.env(), term_size=(24, 100), timeline=timeline)
        elapsed = time.monotonic() - started
        accepted = kg.accepted
    a = TTYAssert(raw, rows=24, cols=100)
    a.assert_clean_exit()
    if accepted == 0:
        a._fail("the session should have probed the TinyKG service")
    shown = arrival_time(timeline, raw, PLACEHOLDER)
    if shown is None:
        a._fail("the input box never appeared")
    if shown - started > PROMPT_BOUND_S:
        a._fail(f"the input box took {shown - started:.1f}s while TinyKG did not answer")
    if elapsed > EXIT_BOUND_S:
        a._fail(f"leaving took {elapsed:.1f}s while the TinyKG probe was in flight")


def test_first_message_waits_for_tinykg_and_esc_stops_the_wait(bin_path):
    with SilentKgService() as kg, SlowMockServer([simple_text("SHOULD_NOT_REACH")]) as srv:
        raw = run(bin_path, [READY, "type:hello", "key:enter",
                             wait_for("Starting TinyKG", 5), "key:esc",
                             wait_for("Interrupted", 5), READY],
                  env=kg.env(), base_url=srv.url, term_size=(24, 100))
    a = TTYAssert(raw, rows=24, cols=100)
    if b"Starting TinyKG" not in raw:
        a._fail("a message sent before TinyKG settled should wait for it on the spinner")
    if a.final.find_last_row("Interrupted") is None:
        a._fail("Esc while the turn waits for TinyKG should interrupt it")
    assert not srv.requests, "no request may be sent before TinyKG has settled"
