"""TTY coverage: a gateway that lists many models is fully reachable.

The picker once built at most 256 rows per stage and the `/models` menu let
the selection reach only its first 8 entries, so a gateway listing 300 models
showed `[1/256]`, and everything past those limits could be reached only by
typing its name (picker) or not at all (`/models`). These cases drive both
lists to their last entry with the keys a user has: End, ↑ from the first row,
and PgDn.
"""
import http.server
import json
import os
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import READY, WAIT_S, run, wait_for  # noqa: E402
from asserts import TTYAssert  # noqa: E402

COUNT = 300


class _ManyModels(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # noqa: D401
        return

    def do_GET(self):  # noqa: N802
        if not self.path.startswith("/v1/models"):
            self.send_error(404)
            return
        body = json.dumps({"object": "list", "has_more": False, "data": [
            {"id": f"m-{i:03d}", "display_name": f"Model {i:03d}", "max_input_tokens": 200000, "max_tokens": 8192}
            for i in range(1, COUNT + 1)
        ]}).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(body)


def _run(bin_path, events, rows=40, cols=120):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _ManyModels)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        raw = run(
            bin_path,
            events,
            term_size=(rows, cols),
            base_url=f"http://127.0.0.1:{server.server_port}/v1/messages",
            env={"METACODES_NO_PROBE": None, **{name: None for name in VENDOR_KEYS}},
            startup_drain=1.0,
            per_key_drain=0.08,
        )
    finally:
        server.shutdown()
    a = TTYAssert(raw, rows=rows, cols=cols)
    return "\n".join(a.final.line_text(r) for r in range(a.final.rows))


# The picker opens on the models; with no vendor key, no other provider is
# listed (#488), so the last model is the last stop for the cursor.
OPEN_MODEL_STAGE = [READY, "type:/model", "key:enter", wait_for("apply to")]
VENDOR_KEYS = (
    "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "ZAI_API_KEY", "GLM_API_KEY", "Z_AI_API_KEY",
    "DEEPSEEK_API_KEY", "MOONSHOT_API_KEY", "KIMI_CODE_API_KEY", "KIMI_API_KEY", "DASHSCOPE_API_KEY",
    "MINIMAX_API_KEY", "AWS_BEARER_TOKEN_BEDROCK",
)


def test_picker_end_reaches_the_last_of_many_models(bin_path):
    text = _run(bin_path, OPEN_MODEL_STAGE + ["key:end", wait_for(f"[{COUNT}/{COUNT}]")])
    assert f"> Model {COUNT}" in text.replace(">  ", "> "), "End 没有到最后一个模型:\n" + text
    assert f"[{COUNT}/{COUNT}] · PgUp/PgDn page · Home/End · type to filter" in text, "长列表没有说明翻页键:\n" + text
    assert "Not configured" not in text, "没有 key 的厂商不该列出:\n" + text


def test_picker_up_from_the_first_row_commits_the_last_model(bin_path):
    # Up from the first model wraps to the last row: the 300th model.
    text = _run(bin_path, OPEN_MODEL_STAGE + ["key:up", wait_for(f"[{COUNT}/{COUNT}]"), "key:enter",
                                               wait_for(f"switched to m-{COUNT}")])
    assert f"switched to m-{COUNT}" in text, "从第一行上翻绕到最后一个并提交失败:\n" + text


def test_picker_page_down_moves_a_page(bin_path):
    text = _run(bin_path, OPEN_MODEL_STAGE + ["raw:\\x1b[6~", "raw:\\x1b[6~", "sleep:0.5"])
    assert f"/{COUNT}]" in text and f"/256]" not in text, "计数被截断:\n" + text
    assert "[1/" not in text, "PgDn 没有移动:\n" + text


def test_models_menu_reaches_the_last_of_many_models(bin_path):
    # `/models`: the key list (one fallback key here), then the model list.
    text = _run(bin_path, [READY, "type:/models", wait_for("API keys"), "key:enter",
                           wait_for("Models for selected API key"), "key:end", wait_for(f"[{COUNT}/{COUNT}]")])
    assert f"Models for selected API key ({COUNT})" in text, text
    assert f"> m-{COUNT}" in text.replace(">  ", "> "), "/models 选不到最后一个模型:\n" + text
    assert "more from server" not in text, "/models 仍在第 8 项截断:\n" + text
