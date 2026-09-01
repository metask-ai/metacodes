"""TTY coverage for `/model` (route picker, issue #16) and `/models` (account keys)."""

import http.server
import threading
import json

from tty_driver import run
from asserts import TTYAssert


KEY_PROD = "KEY_PROD_1234"
KEY_DEV = "KEY_DEV_5678"
DEV_MODEL = "claude-dev-sonnet-20260702"


class _ModelsTwoStepMock(http.server.BaseHTTPRequestHandler):
    model_auths = []
    message_auths = []
    message_models = []
    message_bodies = []
    lock = threading.Lock()

    def log_message(self, fmt, *args):  # noqa: D401
        return

    @classmethod
    def reset(cls):
        with cls.lock:
            cls.model_auths = []
            cls.message_auths = []
            cls.message_models = []
            cls.message_bodies = []

    def _send_json(self, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _send_sse(self, text):
        safe = text.replace("\\", "\\\\").replace('"', '\\"')
        body = (
            'data: {"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":0}}}\n\n'
            'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
            f'data: {{"type":"content_block_delta","index":0,"delta":{{"type":"text_delta","text":"{safe}"}}}}\n\n'
            'data: {"type":"content_block_stop","index":0}\n\n'
            'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}\n\n'
            'data: {"type":"message_stop"}\n\n'
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        auth = self.headers.get("authorization", "")
        if self.path == "/api/v1/keys?page=1&page_size=100":
            self._send_json({
                "code": 0,
                "message": "success",
                "data": {
                    "items": [
                        {"id": 1, "name": "Prod key", "key": KEY_PROD, "status": "active", "group": {"name": "Prod-Claude"}},
                        {"id": 2, "name": "Dev key", "key": KEY_DEV, "status": "active", "group": {"name": "Dev-GPT"}},
                    ],
                },
            })
            return

        if self.path == "/v1/models":
            with self.lock:
                self.model_auths.append(auth)
            if auth == f"Bearer {KEY_DEV}":
                self._send_json({
                    "data": [
                        {
                            "id": DEV_MODEL,
                            "max_tokens": 8192,
                            "max_input_tokens": 200000,
                            "capabilities": {
                                "effort": {
                                    "low": {"supported": True},
                                    "medium": {"supported": True},
                                    "high": {"supported": True},
                                },
                            },
                        },
                    ],
                })
                return
            if auth == f"Bearer {KEY_PROD}":
                self._send_json({
                    "data": [
                        {"id": "claude-prod-opus-20260702", "max_tokens": 4096, "max_input_tokens": 100000},
                    ],
                })
                return
            self._send_json({"data": [{"id": "claude-startup-haiku-20260702"}]})
            return

        self.send_error(404)

    def do_POST(self):  # noqa: N802
        if self.path != "/v1/messages":
            self.send_error(404)
            return
        auth = self.headers.get("authorization", "")
        length = int(self.headers.get("content-length", "0") or "0")
        body = self.rfile.read(length).decode("utf-8", "replace")
        try:
            model = json.loads(body).get("model")
        except json.JSONDecodeError:
            model = None
        with self.lock:
            self.message_auths.append(auth)
            self.message_models.append(model)
            self.message_bodies.append(body)
        self._send_sse("answer ok from selected key")


def _start_two_step_mock():
    _ModelsTwoStepMock.reset()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _ModelsTwoStepMock)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, f"http://127.0.0.1:{server.server_port}/v1/messages"


def _menu_between_box_and_footer(raw):
    a = TTYAssert(raw)
    a.assert_box_present()
    bot = a.box_bottom_row()
    foot = a.footer_row()
    if bot is None or foot is None:
        a._fail("缺边框/footer")
    return a, "\n".join(
        a.final.line_text(r)
        for r in range(bot + 1, foot)
        if a.final.line_text(r).strip()
    )


def test_tty_model_command_opens_the_route_picker(bin_path):
    # issue #16:`/model` 选的是**路由**(provider → model → channel/offer),提交后
    # 开跨 UI picker。账号 API key 是另一个问题,留在 `/models`——把两者合并会让
    # "换账号"和"换模型"互相顶掉。
    server, base_url = _start_two_step_mock()
    try:
        raw = run(
            bin_path,
            ["sleep:1.0", "type:/model", "key:enter", "sleep:0.6"],
            base_url=base_url,
            env={"METACODES_NO_PROBE": None},
            startup_drain=1.2,
            per_key_drain=0.08,
        )
    finally:
        server.shutdown()

    a, menu = _menu_between_box_and_footer(raw)
    if "Provider" not in menu:
        a._fail(f"`/model` 提交后应打开 picker 的 provider 阶段:\n{menu}")
    if "enter apply to this session" not in menu:
        a._fail(f"picker footer 应说明默认作用域:\n{menu}")
    if "API keys for this account" in menu:
        a._fail(f"`/model` 不应再进账号 key 菜单(那是 /models):\n{menu}")


def test_tty_model_picker_commits_a_route_and_switches(bin_path):
    # provider(Enter)→ model(Enter)。metask 的每个 canonical model 只有一条路由,
    # 所以 channel 阶段被跳过、直接提交——正是"只有一个 offer 时跳过 channel 步"。
    server, base_url = _start_two_step_mock()
    try:
        raw = run(
            bin_path,
            [
                "sleep:1.0",
                "type:/model",
                "key:enter",
                "sleep:0.6",
                "key:enter",
                "sleep:0.4",
                "key:enter",
                "sleep:0.8",
            ],
            base_url=base_url,
            env={"METACODES_NO_PROBE": None},
            startup_drain=1.2,
            per_key_drain=0.08,
        )
    finally:
        server.shutdown()

    a = TTYAssert(raw)
    text = "\n".join(a.final.line_text(r) for r in range(a.final.rows))
    if "switched to" not in text:
        a._fail(f"picker 提交后应回报切换结果:\n{text}")
    # 默认作用域是 session,提交不写任何持久状态。
    if "for session" not in text:
        a._fail(f"提交回报应写明作用域:\n{text}")


def test_tty_models_after_model_selection_shows_reasoning_default_none(bin_path):
    # 思考深度菜单属于 `/models` 的账号 → 模型 → effort 流程(凭证侧),issue #16
    # 没有动它。
    server, base_url = _start_two_step_mock()
    try:
        raw = run(
            bin_path,
            [
                "sleep:1.0",
                "type:/models",
                "key:down",
                "key:enter",
                "sleep:0.4",
                "key:enter",
                "sleep:0.5",
            ],
            base_url=base_url,
            env={"METACODES_NO_PROBE": None},
            startup_drain=1.2,
            per_key_drain=0.08,
        )
    finally:
        server.shutdown()

    a, menu = _menu_between_box_and_footer(raw)
    if "Reasoning effort" not in menu:
        a._fail(f"选择模型后应进入思考深度菜单:\n{menu}")
    if "> none" not in menu:
        a._fail(f"思考深度菜单默认应选中 none:\n{menu}")
    if "low" not in menu or "medium" not in menu or "high" not in menu:
        a._fail(f"思考深度菜单应追加服务端支持的 effort:\n{menu}")


def test_tty_models_first_shows_account_api_keys_not_model_list(bin_path):
    server, base_url = _start_two_step_mock()
    try:
        raw = run(
            bin_path,
            ["sleep:1.0", "type:/models", "sleep:0.5"],
            base_url=base_url,
            env={"METACODES_NO_PROBE": None},
            startup_drain=1.2,
            per_key_drain=0.08,
        )
    finally:
        server.shutdown()

    a, menu = _menu_between_box_and_footer(raw)
    if "API keys for this account" not in menu:
        a._fail(f"`/models` 第一屏应显示当前账号 API key 列表:\n{menu}")
    if "Prod key" not in menu or "Dev key" not in menu:
        a._fail(f"`/models` 第一屏应显示 API key label:\n{menu}")
    if "Prod-Claude" not in menu or "Dev-GPT" not in menu:
        a._fail(f"`/models` 第一屏应显示 API key 分组名:\n{menu}")
    if DEV_MODEL in menu:
        a._fail(f"`/models` 第一屏不应直接显示 /v1/models 模型:\n{menu}")
    if "/models       Select account API key and model" in menu:
        a._fail(f"`/models` 两级菜单不应混入普通 slash 菜单:\n{menu}")
    if KEY_PROD.encode() in raw or KEY_DEV.encode() in raw:
        a._fail("TTY 输出泄漏了完整 API key secret")


def test_tty_models_selects_api_key_then_model_and_answers_with_selected_key(bin_path):
    server, base_url = _start_two_step_mock()
    try:
        raw = run(
            bin_path,
            [
                "sleep:1.0",
                "type:/models",
                "sleep:0.3",
                "key:down",
                "key:enter",
                "sleep:0.5",
                "key:enter",
                "sleep:0.5",
                "key:enter",
                "sleep:0.5",
                "type:ping",
                "key:enter",
                "sleep:1.5",
            ],
            base_url=base_url,
            env={"METACODES_NO_PROBE": None},
            startup_drain=1.2,
            per_key_drain=0.08,
        )
    finally:
        server.shutdown()

    a = TTYAssert(raw)
    a.assert_prose_contains(f"/model use {DEV_MODEL}")
    a.assert_prose_contains("switched to ")
    a.assert_prose_contains(DEV_MODEL)
    a.assert_prose_contains("answer ok from selected key")
    if KEY_PROD.encode() in raw or KEY_DEV.encode() in raw:
        a._fail("TTY 输出泄漏了完整 API key secret")

    if f"Bearer {KEY_DEV}" not in _ModelsTwoStepMock.model_auths:
        raise AssertionError(f"/v1/models 未使用选中的 dev key: {_ModelsTwoStepMock.model_auths!r}")
    if _ModelsTwoStepMock.message_auths[-1:] != [f"Bearer {KEY_DEV}"]:
        raise AssertionError(f"/v1/messages 未使用选中的 dev key: {_ModelsTwoStepMock.message_auths!r}")
    if _ModelsTwoStepMock.message_models[-1:] != [DEV_MODEL]:
        raise AssertionError(f"/v1/messages 未使用选中的模型: {_ModelsTwoStepMock.message_models!r}")
    body = _ModelsTwoStepMock.message_bodies[-1]
    if '"output_config"' in body or '"thinking"' in body:
        raise AssertionError(f"reasoning=none 时 /v1/messages 不应带 thinking/output_config: {body!r}")
