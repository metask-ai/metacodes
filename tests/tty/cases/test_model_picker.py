"""TTY coverage for the cross-UI model picker (issue #16).

Offline: the picker reads compiled provider profiles, so no request is made —
except on the two Metask logins, whose inventory is the gateway's own
`/v1/models`; those cases run against a local mock gateway. Every route listed
can be applied as it is (#488): a provider is a normal row only with a
credential, so a case that walks into one gives it a placeholder key, and the
others sit dimmed under "Not configured".
What is asserted here is the behaviour the requirement names and that unit
tests cannot see — that the overlay reaches a real terminal,
that it owns the keyboard without eating the draft, and that a mid-stream
selection does not disturb the reply in flight.
"""
import http.server
import json
import os
import re
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import IDLE, READY, WAIT_S, case_tmpdir, run, submit, wait_for  # noqa: E402
from asserts import TTYAssert  # noqa: E402


def _screen(raw, rows=24, cols=80):
    a = TTYAssert(raw, rows=rows, cols=cols)
    return a, "\n".join(a.final.line_text(r) for r in range(a.final.rows))


def test_picker_opens_with_scope_and_next_turn_footer(bin_path):
    raw = run(bin_path, ["sleep:0.8", "key:ctrl_o", "sleep:0.5"], per_key_drain=0.1)
    a, text = _screen(raw)
    assert "Provider" in text, text
    assert "metask" in text, "内置 provider 未列出:\n" + text
    # 作用域和"下一轮生效"必须写在用户正在看的那一行,不能只在文档里。
    assert "enter apply to this session" in text, "footer 未说明默认作用域:\n" + text
    assert "next turn" in text, "footer 未说明下一轮语义:\n" + text
    a.assert_no_full_clear()  # 覆盖层不进 alt-screen、不清 scrollback


def _provider_rows(text):
    """Provider 阶段每行的 provider id(行首是 `>`/`*`/空格标记,后跟 id 和 "N models")。"""
    rows = []
    for line in text.splitlines():
        parts = line.replace(">", " ").replace("*", " ").split()
        if len(parts) == 3 and parts[2] in ("model", "models") and parts[1].isdigit():
            rows.append(parts[0])
    return rows


def test_model_command_lists_every_provider_and_reaches_its_models(bin_path):
    # metask / openai / gemini 的 id 都是 6 字节。分组标签曾指向循环变量的栈拷贝,
    # 等长 id 被并成一行 "metask 16 models",进去只有 metask 的模型:openai、gemini
    # 在 /model 里根本选不到。OpenAI 给占位 key,它才是能进去的正常行(#488);
    # gemini 没有 key,排在 "Not configured" 下面,仍是独立一行。
    raw = run(
        bin_path,
        submit("/model", "Provider") + ["sleep:0.3", "key:down", "sleep:0.3", "key:enter", wait_for("Model")],
        env={"OPENAI_API_KEY": "tty-dummy-openai-key", "GEMINI_API_KEY": None, "GOOGLE_API_KEY": None},
        per_key_drain=0.1,
    )
    a, text = _screen(raw)

    def screen_text(sc):
        return "\n".join(sc.line_text(r) for r in range(sc.rows))

    provider_frames = [screen_text(sc) for sc in a.frame_screens if "Provider" in screen_text(sc)]
    assert provider_frames, "/model 未打开 picker:\n" + text
    providers = _provider_rows(provider_frames[-1])
    for wanted in ("metask", "openai", "gemini", "zai-coding-plan"):
        assert providers.count(wanted) == 1, f"provider {wanted} 不是独立一行: {providers}\n" + provider_frames[-1]
    # 第二行是 openai(编译期目录顺序);Enter 进去必须是 openai 自己的模型。
    assert providers[1] == "openai", f"目录顺序变了,第二行不是 openai: {providers}"
    lines = text.splitlines()
    header = [i for i, line in enumerate(lines) if line.strip() == "Model"]
    assert header, "Enter 后没进 Model 阶段:\n" + text
    model_rows = []
    for line in lines[header[-1] + 1:]:
        if "enter apply" in line:
            break
        model_rows.append(line)
    listed = "\n".join(model_rows)
    assert "gpt-6-astra" in listed, "进 openai 后没列出它的模型:\n" + text
    assert "claude" not in listed.lower(), "进 openai 后列的是 metask 的模型:\n" + text


def test_picker_typing_filters_without_touching_the_draft(bin_path):
    # 先打一段草稿,再开 picker 打字过滤:字符属于 picker,草稿一个字都不能变。
    raw = run(
        bin_path,
        ["sleep:0.8", "type:explain this", "sleep:0.3", "key:ctrl_o", "sleep:0.4", "type:zai", "sleep:0.4"],
        per_key_drain=0.08,
    )
    _, text = _screen(raw)
    assert "zai-coding-plan" in text, "过滤未生效:\n" + text
    assert "metask" not in text, "过滤后仍显示不匹配项:\n" + text
    assert "explain this" in text, "picker 吃掉了输入框里的草稿:\n" + text


def test_picker_escape_clears_filter_then_walks_back_then_closes(bin_path):
    raw = run(
        bin_path,
        ["sleep:0.8", "key:ctrl_o", "sleep:0.4", "type:zai", "sleep:0.3",
         "key:esc", "sleep:0.3", "key:esc", "sleep:0.4"],
        per_key_drain=0.08,
    )
    _, text = _screen(raw)
    # 第一次 Esc 清过滤(列表回全量),第二次 Esc 在首个阶段=关闭。
    assert "enter apply to this session" not in text, "首个阶段的 Esc 未关闭 picker:\n" + text
    assert "❯" in text, "关闭后应回到输入框:\n" + text


def test_picker_tab_cycles_scope_and_shows_it(bin_path):
    raw = run(
        bin_path,
        ["sleep:0.8", "key:ctrl_o", "sleep:0.4", "key:tab", "sleep:0.4"],
        per_key_drain=0.1,
    )
    _, text = _screen(raw)
    # global 是显式选择,并且在按下 Enter 之前就必须看得见"durable"。
    assert "durable" in text, "Tab 未把作用域切到 global 或未显示它:\n" + text


def test_picker_opens_during_generation_without_alt_screen(bin_path):
    # 要求:picker 在流式回复期间可用。它画在固定区里,回复继续往 scrollback 走,
    # 不进 alt-screen(那是 transcript viewer 的行为)。回复结束后 picker 仍开着(#220:
    # 生成期与输入期各有一个固定区,开着的状态曾随生成期的那个一起被丢掉)。
    # 断言时刻由事件写明,不交给后端收尾:先等 picker 出现,再等回复结束后流静默。
    from slow_mock_server import SlowMockServer, slow_text_then_end

    with SlowMockServer([slow_text_then_end(n_chunks=14, delay=0.4)]) as srv:
        raw = run(
            bin_path,
            [READY, "type:go", "key:enter", wait_for("esc to interrupt"), "key:ctrl_o",
             wait_for("Provider"), "sleep:10"],
            base_url=srv.url,
            startup_drain=0.8,
            per_key_drain=0.08,
        )
    a, text = _screen(raw)

    def screen_text(sc):
        return "\n".join(sc.line_text(r) for r in range(sc.rows))

    during = [sc for sc in a.frame_screens
              if "Provider" in screen_text(sc) and "esc to interrupt" in screen_text(sc)]
    assert during, "生成期 Ctrl+O 未打开 picker:\n" + text
    assert "tok13" in text and "esc to interrupt" not in text, "回复尚未结束,断言时刻不对:\n" + text
    assert "Provider" in text, "回复结束时 picker 被丢掉了(#220):\n" + text
    assert b"\x1b[?1049h" not in raw, "picker 不应进 alt-screen(那是 transcript viewer)"


def test_picker_left_open_by_a_reply_keeps_its_place(bin_path):
    # #220:生成期里筛到一半的浏览状态(过滤词)在回复结束后原样还在,而且 picker
    # 仍接收按键:回复结束后按 Esc 清掉过滤,列表回到全量,picker 仍开着。
    from slow_mock_server import SlowMockServer, slow_text_then_end

    with SlowMockServer([slow_text_then_end(n_chunks=10, delay=0.4)]) as srv:
        raw = run(
            bin_path,
            # 回复结束后先等空闲输入框再按 Esc(生成结束到下次读输入之间的键会被 TCSAFLUSH
            # 丢掉);Esc 清掉过滤后 metask 回到列表(过滤期间它不在屏上),以它为末态标志。
            [READY, "type:go", "key:enter", wait_for("esc to interrupt"), "key:ctrl_o",
             wait_for("Provider"), "type:zai", "sleep:10", IDLE, "key:esc", wait_for("metask")],
            base_url=srv.url,
            startup_drain=0.8,
            per_key_drain=0.08,
        )
    a, text = _screen(raw)

    def screen_text(sc):
        return "\n".join(sc.line_text(r) for r in range(sc.rows))

    kept = [sc for sc in a.frame_screens
            if "tok9" in screen_text(sc) and "esc to interrupt" not in screen_text(sc)
            and "zai-coding-plan" in screen_text(sc) and "metask" not in screen_text(sc)]
    assert kept, "回复结束后过滤状态丢了(#220):\n" + text
    assert "Provider" in text and "metask" in text, "回复结束后 picker 不再接收按键:\n" + text


STORED_KEY = "tty-stored-gateway-key"


class _GatewayMock(http.server.BaseHTTPRequestHandler):
    """A Metask gateway that serves two models, neither of them a compiled Claude one."""

    message_auths = []
    message_models = []
    lock = threading.Lock()

    def log_message(self, fmt, *args):  # noqa: D401
        return

    def do_GET(self):  # noqa: N802
        if self.path != "/v1/models":
            self.send_error(404)
            return
        body = json.dumps({"object": "list", "data": [
            {"id": "glm-5.3-flash", "display_name": "glm-5.3-flash",
             "max_input_tokens": 1048576, "max_tokens": 131072},
            {"id": "kimi-k3", "display_name": "Kimi K3", "max_input_tokens": 262144, "max_tokens": 32768},
        ]}).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802
        if self.path != "/v1/messages":
            self.send_error(404)
            return
        length = int(self.headers.get("content-length", "0") or "0")
        raw = self.rfile.read(length).decode("utf-8", "replace")
        try:
            model = json.loads(raw).get("model")
        except json.JSONDecodeError:
            model = None
        with self.lock:
            self.message_auths.append(self.headers.get("authorization", ""))
            self.message_models.append(model)
        body = (
            'data: {"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":0}}}\n\n'
            'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"answered by the gateway"}}\n\n'
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


def test_picker_on_the_api_key_route_offers_the_gateway_models(bin_path):
    # The historical API-key route (no --provider, no Metask session login, the
    # key stored by `metacodes login`): the picker lists what this gateway's
    # /v1/models serves for the key, marks the model the session runs, and a
    # pick is sent with the stored key. Before, it listed the six compiled Claude
    # models, marked nothing, and a pick asked for a sign-in.
    home = case_tmpdir("cc-tty-gateway-home-")
    state = os.path.join(home, ".metacodes")
    os.makedirs(state)
    auth = os.path.join(state, "auth.json")
    with open(auth, "w", encoding="utf-8") as handle:
        json.dump({"api_key": STORED_KEY, "selected_model": "glm-5.3-flash", "reasoning_effort": "none"}, handle)
    os.chmod(auth, 0o600)

    with _GatewayMock.lock:
        _GatewayMock.message_auths = []
        _GatewayMock.message_models = []
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _GatewayMock)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        raw = run(
            bin_path,
            [READY, "key:ctrl_o", wait_for("Provider"), "key:enter", f"waitline:Model:{WAIT_S}",
             wait_for("Kimi K3"), "type:kimi", "key:enter", wait_for("switched to kimi-k3"),
             READY, "type:ping", "key:enter", wait_for("answered by the gateway")],
            base_url=f"http://127.0.0.1:{server.server_port}/v1/messages",
            env={"HOME": home, "METACODES_NO_PROBE": None, "METASK_API_KEY": None},
            startup_drain=1.2,
            per_key_drain=0.08,
        )
    finally:
        server.shutdown()

    a, text = _screen(raw)

    def screen_text(sc):
        return "\n".join(sc.line_text(r) for r in range(sc.rows))

    # The Model stage before the filter is typed: its header line is exactly "Model".
    model_stage = [screen_text(sc) for sc in a.frame_screens
                   if "Kimi K3" in screen_text(sc)
                   and any(sc.line_text(r).strip() == "Model" for r in range(sc.rows))]
    assert model_stage, "picker 的 Model 阶段没出现网关模型:\n" + text
    listing = model_stage[-1]
    assert re.search(r"\*\s*glm-5\.3-flash", listing), "当前模型 glm-5.3-flash 未标 *:\n" + listing
    assert "Claude" not in listing, "API-key 路由仍列出编译期 Claude 模型:\n" + listing
    assert "switched to kimi-k3" in text, "选中网关模型后未切换:\n" + text
    assert "sign in" not in text, "选网关模型不该要求登录:\n" + text
    assert _GatewayMock.message_models[-1:] == ["kimi-k3"], _GatewayMock.message_models
    assert _GatewayMock.message_auths[-1:] == [f"Bearer {STORED_KEY}"], "请求没用存储的 key"
    assert STORED_KEY.encode() not in raw, "TTY 输出泄漏了 API key"


def test_picker_options_step_changes_reasoning_with_arrows_and_applies_with_enter(bin_path):
    # GLM-5.3 declares reasoning_effort (low/high/max). The options step used to
    # have no key that applied a route: Enter cycled the value. Now ←/→ change
    # it and Enter applies the route with the value shown.
    raw = run(
        bin_path,
        submit("/model", "Provider") + [
            "type:zai-coding-plan", wait_for("zai-coding-plan"), "key:enter", f"waitline:Model:{WAIT_S}",
            "type:glm-5.3", "key:up", "sleep:0.2", "key:home", "sleep:0.2", "key:enter",
            wait_for("Channel / offer"), "key:enter",
            wait_for("Options"), "key:right", "key:right", wait_for("= high"),
            "key:enter", wait_for("switched to glm-5.3"),
        ],
        env={"ZAI_API_KEY": "tty-dummy-zai-key"},
        per_key_drain=0.1,
    )
    a, text = _screen(raw)

    def screen_text(sc):
        return "\n".join(sc.line_text(r) for r in range(sc.rows))

    options = [screen_text(sc) for sc in a.frame_screens if "Options" in screen_text(sc)]
    assert options, "没有进入 Options 层:\n" + text
    assert any("←/→ change · enter apply to" in sc for sc in options), "Options 层没说明改值的键:\n" + options[-1]
    assert any("Reasoning effort" in sc and "= high" in sc and "[low high max]" in sc for sc in options), \
        "→ 没有把推理强度改到 high:\n" + options[-1]
    assert "switched to glm-5.3" in text, "Enter 没有应用线路:\n" + text
    # Metask to the GLM plan: the bill moves, and the notice says where (#488).
    flat = " ".join(text.split())
    assert "from now on billed to your Z.AI GLM Coding Plan account" in flat, "切到另一家没写明扣钱的一方:\n" + text


GUIDE = "https://github.com/metask-ai/metacodes/blob/main/doc/LOCAL_CONFIG.md"

# Every variable a built-in vendor reads its key from: cleared, so a case sees
# only the keys it gives.
VENDOR_KEYS = (
    "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "ZAI_API_KEY", "GLM_API_KEY", "Z_AI_API_KEY",
    "DEEPSEEK_API_KEY", "MOONSHOT_API_KEY", "KIMI_CODE_API_KEY", "KIMI_API_KEY", "DASHSCOPE_API_KEY",
    "MINIMAX_API_KEY", "AWS_BEARER_TOKEN_BEDROCK",
)


def _no_vendor_keys(**given):
    env = {name: None for name in VENDOR_KEYS}
    env.update(given)
    return env


def _provider_groups(screen):
    """(normal rows, rows under "Not configured") of one Provider-stage frame."""
    normal, unconfigured, target = [], [], None
    for line in screen.splitlines():
        if line.strip() == "Provider":
            target = normal
            continue
        if line.strip() == "Not configured":
            target = unconfigured
            continue
        parts = line.replace(">", " ").replace("*", " ").split()
        if target is not None and len(parts) == 3 and parts[2] in ("model", "models") and parts[1].isdigit():
            target.append(parts[0])
    return normal, unconfigured


def _last_provider_frame(raw, rows, cols):
    a = TTYAssert(raw, rows=rows, cols=cols)
    frames = []
    for sc in a.frame_screens:
        text = "\n".join(sc.line_text(r) for r in range(sc.rows))
        if any(sc.line_text(r).strip() == "Provider" for r in range(sc.rows)):
            frames.append(text)
    assert frames, "/model 没有打开 Provider 阶段"
    return frames[-1]


def test_picker_lists_only_providers_with_a_credential_and_dims_the_rest_last(bin_path):
    # #488: with no vendor key, only Metask (the session's own key) is a row a
    # pick applies; every vendor sits dimmed under "Not configured", last. A
    # key makes its vendor a normal row.
    events = submit("/model", "Provider") + ["sleep:0.4"]
    bare = _last_provider_frame(run(bin_path, events, term_size=(40, 120), env=_no_vendor_keys(),
                                    per_key_drain=0.1), 40, 120)
    normal, unconfigured = _provider_groups(bare)
    assert normal == ["metask"], f"没有 key 时只该有 Metask 一行:{normal}\n" + bare
    for vendor in ("openai", "gemini", "zai-coding-plan", "deepseek", "kimi", "kimi-code"):
        assert vendor in unconfigured, f"{vendor} 应灰显在 Not configured 组:{unconfigured}\n" + bare

    keyed = _last_provider_frame(run(bin_path, events, term_size=(40, 120),
                                     env=_no_vendor_keys(DEEPSEEK_API_KEY="tty-dummy-deepseek-key"),
                                     per_key_drain=0.1), 40, 120)
    normal, unconfigured = _provider_groups(keyed)
    assert normal == ["metask", "deepseek"], f"有 DEEPSEEK_API_KEY 时 DeepSeek 应是正常行:{normal}\n" + keyed
    assert "deepseek" not in unconfigured, keyed


def test_picker_names_the_variable_and_the_env_file_for_a_provider_without_a_key(bin_path):
    # #483, #488: Kimi on Moonshot's open platform has no sign-in and no key
    # page. A route chosen without MOONSHOT_API_KEY ended in a bare
    # "switch failed (MissingCredentials)". Now the provider is listed dimmed,
    # and choosing it shows the variable, this install's .env and the guide,
    # and nothing to type. KIMI_API_KEY is Kimi Code's (#487).
    home = case_tmpdir("cc-tty-nokey-home-")
    env_file = os.path.join(home, ".metacodes", ".env")
    raw = run(
        bin_path,
        submit("/model", "Provider") + [
            "type:kimi", wait_for("kimi-code"), "key:enter", wait_for("MOONSHOT_API_KEY"),
        ],
        term_size=(30, 160),
        env=_no_vendor_keys(HOME=home),
        per_key_drain=0.1,
    )
    _, text = _screen(raw, rows=30, cols=160)
    assert "kimi not configured" in text, text
    assert f"Set MOONSHOT_API_KEY in {env_file}, then restart" in text, text
    assert f"How to: {GUIDE}" in text, text
    assert "esc back · q close" in text, text
    assert "MissingCredentials" not in text, text
    assert "KIMI_API_KEY" not in text, text
    assert "enter apply" not in text, "setup 不该提供应用线路:\n" + text


class _DeviceGatewayMock(http.server.BaseHTTPRequestHandler):
    """The gateway a Metask device login names: two models on /v1/models."""

    seen = []

    def log_message(self, fmt, *args):  # noqa: D401
        return

    def do_GET(self):  # noqa: N802
        type(self).seen.append((self.path, self.headers.get("authorization", "")))
        if self.path != "/v1/models":
            self.send_error(404)
            return
        body = json.dumps({"object": "list", "data": [
            {"id": "device-model-a", "display_name": "Device Model A", "max_input_tokens": 200000, "max_tokens": 8192},
            {"id": "device-model-b", "display_name": "Device Model B", "max_input_tokens": 128000, "max_tokens": 8192},
        ]}).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(body)


def test_picker_on_a_metask_device_login_offers_the_gateway_models(bin_path):
    # #488, the other Metask login: a device-code session (oauth/metask.json)
    # lists what its gateway's /v1/models answers, as the auth.json key route
    # does above, not the compiled Claude list. The token is fresh, so nothing
    # is refreshed; the site URL points nowhere in case something tried.
    import time

    home = case_tmpdir("cc-tty-device-home-")
    oauth_dir = os.path.join(home, ".metacodes", "oauth")
    os.makedirs(oauth_dir)
    _DeviceGatewayMock.seen = []
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _DeviceGatewayMock)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    gateway = f"http://127.0.0.1:{server.server_port}"
    login = os.path.join(oauth_dir, "metask.json")
    with open(login, "w", encoding="utf-8") as handle:
        json.dump({"schema_version": 1, "access_token": "tty-device-access", "refresh_token": "tty-device-refresh",
                   "token_type": "Bearer", "expires_at": int(time.time()) + 86400, "gateway_url": gateway}, handle)
    os.chmod(login, 0o600)
    try:
        raw = run(
            bin_path,
            submit("/model", "Provider") + ["key:enter", f"waitline:Model:{WAIT_S}", wait_for("Device Model B")],
            base_url=None,
            env=_no_vendor_keys(HOME=home, METASK_API_KEY=None, METACODES_BASE_URL=None,
                                METASK_GATEWAY_URL=None, METASK_SITE_URL="http://127.0.0.1:1"),
            extra_args=["--provider", "metask"],
            startup_drain=1.2,
            per_key_drain=0.1,
        )
    finally:
        server.shutdown()
    a, text = _screen(raw)

    def screen_text(sc):
        return "\n".join(sc.line_text(r) for r in range(sc.rows))

    model_stage = [screen_text(sc) for sc in a.frame_screens
                   if "Device Model B" in screen_text(sc)
                   and any(sc.line_text(r).strip() == "Model" for r in range(sc.rows))]
    assert model_stage, "设备码登录的 Model 阶段没列出网关模型:\n" + text
    listing = model_stage[-1]
    assert "Device Model A" in listing, listing
    assert "Claude" not in listing, "设备码登录仍列出编译期 Claude 模型:\n" + listing
    assert ("/v1/models", "Bearer tty-device-access") in _DeviceGatewayMock.seen, _DeviceGatewayMock.seen
    assert b"tty-device-access" not in raw and b"tty-device-refresh" not in raw, "TTY 输出泄漏了令牌"
