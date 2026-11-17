"""TTY coverage for the cross-UI model picker (issue #16; one screen since the follow-up to #527).

Offline: the picker reads compiled provider profiles, so no request is made —
except on the Metask logins, whose inventory is the gateway's own
`/v1/models`; those cases run against a local mock gateway. Every route listed
can be applied as it is (#488): a provider is listed, under a heading of its
own, only with a credential, so a case that picks one gives it a placeholder
key; the others are counted on one "Not configured" line at the bottom.
What is asserted here is the behaviour the requirement names and that unit
tests cannot see — that the overlay reaches a real terminal, that it owns the
keyboard without eating the draft, and that a mid-stream selection does not
disturb the reply in flight.
"""
import http.server
import json
import os
import re
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tty_driver import IDLE, READY, case_tmpdir, run, submit, wait_for  # noqa: E402
from asserts import TTYAssert  # noqa: E402
from metask_mock import ACCESS_TOKEN, MetaskMock  # noqa: E402
from test_unbound import KEY_VARIABLES  # noqa: E402

# The picker's header line: the title, then the three scopes.
OPEN = "apply to"


def _screen(raw, rows=24, cols=80):
    a = TTYAssert(raw, rows=rows, cols=cols)
    return a, "\n".join(a.final.line_text(r) for r in range(a.final.rows))


def _frames(a):
    return ["\n".join(sc.line_text(r) for r in range(sc.rows)) for sc in a.frame_screens]


def _headings(screen):
    """The provider headings of one frame, by name: "<name> · … · billed to your <name> account"."""
    return [m.group(1) for m in re.finditer(r"^  (\S[^·\n]*?) ·.*billed to your .* account", screen, re.M)]


def test_picker_opens_with_scope_and_next_turn_footer(bin_path):
    raw = run(bin_path, ["sleep:0.8", "key:ctrl_o", "sleep:0.5"], per_key_drain=0.1)
    a, text = _screen(raw)
    assert "Model" in text, text
    assert "Metask" in _headings(text), "内置 provider 未列出:\n" + text
    # 作用域和"下一轮生效"必须写在用户正在看的地方,不能只在文档里。
    assert "[this session]" in text, "未显示默认作用域:\n" + text
    assert "next turn" in text, "footer 未说明下一轮语义:\n" + text
    a.assert_no_full_clear()  # 覆盖层不进 alt-screen、不清 scrollback


def test_model_command_lists_each_provider_under_its_own_heading(bin_path):
    # metask / openai / gemini 的 id 都是 6 字节。分组标签曾指向循环变量的栈拷贝,
    # 等长 id 被并成一组,openai、gemini 在 /model 里根本选不到。OpenAI 给占位 key,
    # 它有自己的标题和模型(#488);gemini 没有 key,在最下面的 "Not configured" 行里。
    raw = run(
        bin_path,
        # End: the last rows are OpenAI's, under its heading, and the
        # "Not configured" line.
        submit("/model", OPEN) + ["sleep:0.4", "key:end", "sleep:0.4"],
        env={"OPENAI_API_KEY": "tty-dummy-openai-key", "GEMINI_API_KEY": None, "GOOGLE_API_KEY": None},
        term_size=(40, 120),
        per_key_drain=0.1,
    )
    a, text = _screen(raw, rows=40, cols=120)
    # Opened on Metask's models, under its heading; at the end, OpenAI's own.
    opened = [sc for sc in _frames(a) if OPEN in sc and "Metask" in _headings(sc)]
    assert opened and _headings(opened[0]).count("Metask") == 1, "Metask 没有自己的标题:\n" + text
    assert _headings(text).count("OpenAI") == 1, f"标题: {_headings(text)}\n" + text
    lines = text.splitlines()
    start = next(i for i, line in enumerate(lines) if re.match(r"^  OpenAI ·", line))
    rows = []
    for line in lines[start + 1:]:
        if re.match(r"^  \S", line) or "Not configured" in line or "Reasoning" in line:
            break
        rows.append(line)
    listed = "\n".join(rows)
    assert "GPT-6 Astra" in listed, "OpenAI 标题下没列出它的模型:\n" + text
    assert "claude" not in listed.lower(), "OpenAI 标题下列的是 metask 的模型:\n" + text
    not_configured = next((line for line in lines if "Not configured ·" in line), "")
    assert "gemini" in not_configured or "providers" in not_configured, "没 key 的 gemini 应在 Not configured 行:\n" + text


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


def test_picker_escape_clears_filter_then_closes_and_says_what_was_kept(bin_path):
    raw = run(
        bin_path,
        ["sleep:0.8", "key:ctrl_o", "sleep:0.4", "type:zai", "sleep:0.3",
         "key:esc", "sleep:0.3", "key:esc", "sleep:0.4"],
        per_key_drain=0.08,
    )
    _, text = _screen(raw)
    # 第一次 Esc 清过滤(列表回全量),第二次 Esc 关闭,并在记录里说保持了哪个模型。
    assert "enter apply" not in text, "第二次 Esc 未关闭 picker:\n" + text
    assert "kept claude" in text, "取消后没有留下回执:\n" + text
    assert "❯" in text, "关闭后应回到输入框:\n" + text


def test_picker_tab_cycles_scope_and_shows_it(bin_path):
    raw = run(
        bin_path,
        ["sleep:0.8", "key:ctrl_o", "sleep:0.4", "key:tab", "sleep:0.4"],
        per_key_drain=0.1,
    )
    _, text = _screen(raw)
    # "以后都用"是显式选择,并且在按下 Enter 之前就必须看得见。
    assert "[from now on]" in text, "Tab 未把作用域切到 global 或未显示它:\n" + text


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
             wait_for(OPEN), "sleep:10"],
            base_url=srv.url,
            startup_drain=0.8,
            per_key_drain=0.08,
        )
    a, text = _screen(raw)
    during = [sc for sc in _frames(a) if OPEN in sc and "esc to interrupt" in sc]
    assert during, "生成期 Ctrl+O 未打开 picker:\n" + text
    assert "tok13" in text and "esc to interrupt" not in text, "回复尚未结束,断言时刻不对:\n" + text
    assert OPEN in text, "回复结束时 picker 被丢掉了(#220):\n" + text
    assert b"\x1b[?1049h" not in raw, "picker 不应进 alt-screen(那是 transcript viewer)"


def test_picker_left_open_by_a_reply_keeps_its_place(bin_path):
    # #220:生成期里筛到一半的浏览状态(过滤词)在回复结束后原样还在,而且 picker
    # 仍接收按键:回复结束后按 Esc 清掉过滤,列表回到全量(Metask 的标题回来),picker 仍开着。
    from slow_mock_server import SlowMockServer, slow_text_then_end

    with SlowMockServer([slow_text_then_end(n_chunks=10, delay=0.4)]) as srv:
        raw = run(
            bin_path,
            # 回复结束后先等空闲输入框再按 Esc(生成结束到下次读输入之间的键会被 TCSAFLUSH
            # 丢掉);过滤期间没有标题,Esc 清掉过滤后 Metask 的标题回来,以它为末态标志。
            [READY, "type:go", "key:enter", wait_for("esc to interrupt"), "key:ctrl_o",
             wait_for(OPEN), "type:zai", "sleep:10", IDLE, "key:esc", wait_for("billed to your Metask account")],
            base_url=srv.url,
            startup_drain=0.8,
            per_key_drain=0.08,
        )
    a, text = _screen(raw)
    kept = [sc for sc in _frames(a)
            if "tok9" in sc and "esc to interrupt" not in sc
            and "zai-coding-plan" in sc and "billed to your Metask account" not in sc]
    assert kept, "回复结束后过滤状态丢了(#220):\n" + text
    assert OPEN in text and "billed to your Metask account" in text, "回复结束后 picker 不再接收按键:\n" + text


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
            [READY, "key:ctrl_o", wait_for("Kimi K3"), "type:kimi", "key:enter", wait_for("switched to kimi-k3"),
             READY, "type:ping", "key:enter", wait_for("answered by the gateway")],
            base_url=f"http://127.0.0.1:{server.server_port}/v1/messages",
            env={"HOME": home, "METACODES_NO_PROBE": None, "METASK_API_KEY": None},
            startup_drain=1.2,
            per_key_drain=0.08,
        )
    finally:
        server.shutdown()

    a, text = _screen(raw)
    # The list before the filter is typed: the gateway's models under Metask's heading.
    listings = [sc for sc in _frames(a) if "Kimi K3" in sc and "billed to your Metask account" in sc]
    assert listings, "picker 没列出网关模型:\n" + text
    listing = listings[-1]
    assert re.search(r"\*\s*glm-5\.3-flash", listing), "当前模型 glm-5.3-flash 未标 *:\n" + listing
    assert "Claude" not in listing, "API-key 路由仍列出编译期 Claude 模型:\n" + listing
    assert "switched to kimi-k3 for this session" in text, "选中网关模型后未切换:\n" + text
    assert "sign in" not in text, "选网关模型不该要求登录:\n" + text
    assert _GatewayMock.message_models[-1:] == ["kimi-k3"], _GatewayMock.message_models
    assert _GatewayMock.message_auths[-1:] == [f"Bearer {STORED_KEY}"], "请求没用存储的 key"
    assert STORED_KEY.encode() not in raw, "TTY 输出泄漏了 API key"


def test_picker_reasoning_line_changes_with_arrows_and_enter_applies_it(bin_path):
    # GLM-5.3 declares reasoning_effort (low/high/max). The level is a line under
    # the list, changed with ←/→ from the model's own row, and Enter applies the
    # model with the level shown.
    raw = run(
        bin_path,
        submit("/model", OPEN) + [
            "type:glm-5.3", wait_for("Reasoning effort"), "key:home",
            "key:right", "key:right", wait_for("[high]"),
            "key:enter", wait_for("switched to glm-5.3"),
        ],
        env={"ZAI_API_KEY": "tty-dummy-zai-key"},
        term_size=(30, 120),
        per_key_drain=0.1,
    )
    a, text = _screen(raw, rows=30, cols=120)
    lines = [sc for sc in _frames(a) if "Reasoning effort" in sc and "[high]" in sc]
    assert lines, "→ 没有把推理强度改到 high:\n" + text
    assert any("←/→ reasoning" in sc for sc in lines), "footer 没说明改推理强度的键:\n" + lines[-1]
    flat = " ".join(text.split())
    assert "switched to glm-5.3 for this session · reasoning high" in flat, "Enter 没有应用线路或强度:\n" + text
    # Metask to the GLM plan: the bill moves, and the notice says where (#488).
    assert "from now on billed to your Z.AI GLM Coding Plan account" in flat, "切到另一家没写明扣钱的一方:\n" + text


def test_picker_lists_a_models_routes_under_it_and_enter_on_one_takes_it(bin_path):
    # DeepSeek serves each model on two wires. The routes are listed under the
    # model the cursor is on, in words; Enter on the model takes the preferred
    # one, Enter on a route takes that route.
    raw = run(
        bin_path,
        submit("/model", OPEN) + [
            "type:deepseek-v4-pro", wait_for("Anthropic Messages API"),
            "key:down", "key:down", "sleep:0.3", "key:enter", wait_for("switched to deepseek-v4-pro"),
        ],
        env={"DEEPSEEK_API_KEY": "tty-dummy-deepseek-key"},
        term_size=(30, 120),
        per_key_drain=0.1,
    )
    a, text = _screen(raw, rows=30, cols=120)
    routes = [sc for sc in _frames(a) if "Anthropic Messages API" in sc]
    assert routes, "多线路模型没在光标处展开线路:\n" + text
    listing = routes[0]
    assert re.search(r"├ default\s+OpenAI Chat API\s+preferred", listing), listing
    assert re.search(r"└ anthropic\s+Anthropic Messages API", listing), listing
    assert "openai_chat" not in listing and "price=?" not in listing, "默认画面露出了工程字段:\n" + listing
    flat = " ".join(text.split())
    assert "switched to deepseek-v4-pro for this session" in flat, text


def test_picker_lists_providers_with_a_credential_and_counts_the_rest_on_one_line(bin_path):
    # #488: with no vendor key, only Metask (the session's own key) has a
    # heading; every vendor is counted on the "Not configured" line, last, and
    # Enter there lists them. A key gives its vendor a heading of its own.
    events = submit("/model", OPEN) + ["sleep:0.4", "key:end", "sleep:0.3", "key:enter", wait_for("enter shows where its credential goes")]
    raw = run(bin_path, events, term_size=(40, 120), env=_no_vendor_keys(), per_key_drain=0.1)
    a, text = _screen(raw, rows=40, cols=120)
    lists = [sc for sc in _frames(a) if OPEN in sc]
    assert lists, "/model 没打开:\n" + text
    assert _headings(lists[-1]) == ["Metask"], f"没有 key 时只该有 Metask 的标题:{_headings(lists[-1])}\n" + lists[-1]
    assert "Not configured ·" in lists[-1], lists[-1]
    for vendor in ("openai", "gemini", "zai-coding-plan", "deepseek", "kimi", "kimi-code"):
        assert re.search(rf"^\s+[> ][* ] {re.escape(vendor)}\s", text, re.M), f"{vendor} 应在 Not configured 列表里:\n" + text

    keyed = run(bin_path, submit("/model", OPEN) + ["sleep:0.4"], term_size=(40, 120),
                env=_no_vendor_keys(DEEPSEEK_API_KEY="tty-dummy-deepseek-key"), per_key_drain=0.1)
    _, keyed_text = _screen(keyed, rows=40, cols=120)
    assert _headings(keyed_text) == ["Metask", "DeepSeek"], f"有 DEEPSEEK_API_KEY 时 DeepSeek 应有标题:{_headings(keyed_text)}\n" + keyed_text


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


def test_picker_names_the_variable_and_the_env_file_for_a_provider_without_a_key(bin_path):
    # #483, #488: Kimi on Moonshot's open platform has no sign-in and no key
    # page. A route chosen without MOONSHOT_API_KEY ended in a bare
    # "switch failed (MissingCredentials)". Now a filter finds its models dim,
    # and Enter on one shows the variable, this install's .env and the guide,
    # and nothing to type. KIMI_API_KEY is Kimi Code's (#487).
    home = case_tmpdir("cc-tty-nokey-home-")
    env_file = os.path.join(home, ".metacodes", ".env")
    raw = run(
        bin_path,
        submit("/model", OPEN) + [
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


def test_picker_filter_lists_whole_matches_before_scattered_ones(bin_path):
    # The filter also matches letters in order, so `glm` matches
    # `google/gemini-…` (g…l…m) as well as GLM-5.3. The models that hold the
    # typed text whole come first, and the cursor starts on one of them.
    raw = run(
        bin_path,
        submit("/model", OPEN) + ["type:glm", wait_for("GLM-5.3"), "sleep:0.3"],
        term_size=(30, 160),
        env=_no_vendor_keys(HOME=case_tmpdir("cc-tty-rank-home-")),
        per_key_drain=0.1,
    )
    _, text = _screen(raw, rows=30, cols=160)
    rows = [line for line in text.split("\n") if re.match(r"^  [> ][* ] \S", line)]
    names = [("glm" if "GLM" in row else "gemini" if "Gemini" in row else "other") for row in rows]
    assert "glm" in names and "gemini" in names, "expected GLM and Gemini matches:\n" + text
    assert names.index("gemini") > len(names) - 1 - names[::-1].index("glm"), \
        "a scattered match (Gemini) is listed before a whole one (GLM):\n" + text
    assert rows[0].startswith("  >") and "GLM" in rows[0], "the cursor should start on a GLM model:\n" + text


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
            submit("/model", OPEN) + [wait_for("Device Model B")],
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
    listings = [sc for sc in _frames(a) if "Device Model B" in sc and OPEN in sc]
    assert listings, "设备码登录的 picker 没列出网关模型:\n" + text
    listing = listings[-1]
    assert "Device Model A" in listing, listing
    assert "Claude" not in listing, "设备码登录仍列出编译期 Claude 模型:\n" + listing
    assert ("/v1/models", "Bearer tty-device-access") in _DeviceGatewayMock.seen, _DeviceGatewayMock.seen
    assert b"tty-device-access" not in raw and b"tty-device-refresh" not in raw, "TTY 输出泄漏了令牌"


def _session_case(mock):
    """A state root signed in to the www gateway mock (the Metask session and the model it chose)."""
    home = case_tmpdir("cc-tty-picker-session-")
    state = os.path.join(home, ".metacodes")
    os.makedirs(state, exist_ok=True)
    mock.write_session(state)
    env = {name: None for name in KEY_VARIABLES}
    env.update({"HOME": home, "METACODES_HOME": None, "METACODES_JEV_URL": "off"})
    env.update(mock.env(home))
    return env


def test_picker_on_the_session_lists_only_chat_models_with_the_gateways_reasoning_levels(bin_path):
    # The www gateway (#527) lists an image model beside the chat ones, and
    # names the reasoning levels each takes (`capabilities.reasoning.efforts`).
    # /model offers only what it serves on /v1/messages, with those levels.
    with MetaskMock() as mock:
        env = _session_case(mock)
        work = case_tmpdir("cc-tty-picker-work-")
        raw = run(
            bin_path,
            submit("/model", OPEN) + [wait_for("Reasoning effort"), "key:right", wait_for("[high]"),
                                      "key:enter", wait_for("switched to glm-5")],
            env=env,
            base_url=None,
            cwd=work,
            term_size=(30, 120),
            per_key_drain=0.1,
        )
        a, text = _screen(raw, rows=30, cols=120)
        listings = [sc for sc in _frames(a) if OPEN in sc and "glm-5-air" in sc]
        assert listings, "会话路线的 picker 没列出网关模型:\n" + text
        listing = listings[0]
        assert "image-model-only" not in listing, "网关的生图模型不该出现在 /model:\n" + listing
        # The heading says where the credential comes from: the sign-in.
        assert "Metask · signed in · billed to your Metask account" in listing, listing
        # The session runs glm-5 at low (auth.json); the line starts there.
        assert re.search(r"Reasoning effort\s+default\s+\[low\]\s+high", listing), listing
        flat = " ".join(text.split())
        assert "switched to glm-5 for this session · reasoning high" in flat, text
        # The level reached the gateway with the session's own token.
        assert mock.messages == [] or all(auth == f"Bearer {ACCESS_TOKEN}" for auth, _ in mock.messages)
