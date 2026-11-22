import http.server
import threading
import time

from tty_driver import READY, run, wait_for
from asserts import TTYAssert

PLACEHOLDER = 'Try "fix typecheck errors"'
STARTUP_WAIT_S = 5.0
NEVER_S = 3600


class _SilentGateway(http.server.BaseHTTPRequestHandler):
    silent_models = False
    asked = []
    lock = threading.Lock()

    def log_message(self, fmt, *args):  # noqa: D401
        return

    def do_GET(self):  # noqa: N802
        with self.lock:
            self.asked.append((time.monotonic(), self.path))
        if self.path.startswith("/api/v1/keys") or (self.path == "/v1/models" and self.silent_models):
            time.sleep(NEVER_S)
            return
        if self.path == "/v1/models":
            body = b'{"data":[{"id":"claude-startup-haiku-20260702","max_tokens":4096}]}'
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.send_header("connection", "close")
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)


def _serve(silent_models):
    _SilentGateway.silent_models = silent_models
    _SilentGateway.asked = []
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _SilentGateway)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base_url = f"http://127.0.0.1:{server.server_port}/v1/messages"
    return server, base_url


def test_a_cold_start_shows_the_prompt_when_models_never_answers(bin_path):
    server, base_url = _serve(silent_models=True)
    started = time.monotonic()
    try:
        raw = run(
            bin_path,
            [wait_for(PLACEHOLDER, STARTUP_WAIT_S + 7), "strictsleep:0.3"],
            base_url=base_url,
            env={"METACODES_NO_PROBE": None},
            startup_drain=0,
        )
    finally:
        server.shutdown()

    a = TTYAssert(raw)
    a.assert_box_present()
    if a.final.find_row(PLACEHOLDER) is None:
        a._fail(f"the prompt did not appear within {STARTUP_WAIT_S + 7:.0f}s of a silent /v1/models")
    asked = [path for _, path in _SilentGateway.asked]
    if "/v1/models" not in asked:
        raise AssertionError(f"the start did not ask /v1/models: {asked!r}")
    elapsed = time.monotonic() - started
    if elapsed > STARTUP_WAIT_S + 12:
        raise AssertionError(f"the case took {elapsed:.1f}s: the start held the prompt past its wait")


def test_models_menu_keeps_keys_live_while_the_key_list_never_answers(bin_path):
    server, base_url = _serve(silent_models=False)
    keys_url = base_url.replace("/v1/messages", "/api/v1/keys?page=1&page_size=100")
    try:
        raw = run(
            bin_path,
            [
                READY,
                "type:/models",
                wait_for("(loading)", 5),
                "type: zq",
                wait_for("❯ /models zq", 3),
                "key:ctrl_c",
                wait_for("Press Ctrl-C again to exit", 3),
                "key:ctrl_c",
                "strictsleep:1.0",
                "type:after",
                "strictsleep:0.5",
            ],
            base_url=base_url,
            env={"METACODES_NO_PROBE": None, "METACODE_API_KEYS_URL": keys_url},
            startup_drain=1.2,
            per_key_drain=0.08,
        )
    finally:
        server.shutdown()

    a = TTYAssert(raw)
    if not any(path.startswith("/api/v1/keys") for _, path in _SilentGateway.asked):
        raise AssertionError(f"`/models` did not ask for the key list: {_SilentGateway.asked!r}")
    if not any(sc.find_row("API keys for this account (loading)") is not None for sc in a.frame_screens):
        a._fail("the key menu did not say the list is loading")
    if not any(sc.find_row("❯ /models zq") is not None for sc in a.frame_screens):
        a._fail("keys typed while the list loads were not echoed")
    if not any(sc.find_row("Press Ctrl-C again to exit") is not None for sc in a.frame_screens):
        a._fail("Ctrl+C did nothing while the list loads")
    a.assert_clean_exit()
    if a.final.find_row("after") is not None:
        a._fail("the second Ctrl+C did not end the session")


def test_esc_closes_the_loading_key_menu(bin_path):
    server, base_url = _serve(silent_models=False)
    keys_url = base_url.replace("/v1/messages", "/api/v1/keys?page=1&page_size=100")
    try:
        raw = run(
            bin_path,
            [
                READY,
                "type:/models",
                wait_for("(loading)", 5),
                "key:esc",
                "strictsleep:1.0",
            ],
            base_url=base_url,
            env={"METACODES_NO_PROBE": None, "METACODE_API_KEYS_URL": keys_url},
            startup_drain=1.2,
            per_key_drain=0.08,
        )
    finally:
        server.shutdown()

    a = TTYAssert(raw)
    if not any(sc.find_row("API keys for this account (loading)") is not None for sc in a.frame_screens):
        a._fail("the key menu did not say the list is loading")
    if a.final.find_row("API keys for this account") is not None:
        a._fail("Esc did not close the key menu while the list loads")
