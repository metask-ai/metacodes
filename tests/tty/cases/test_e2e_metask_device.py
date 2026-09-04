"""tty 真模型 e2e:Metask 设备码登录 → 经 Metask 网关请求真实模型 → 本地账本与平台账单对账。

流程(每步都是产品路径,不走后门):
  1. 隔离 HOME 里跑 `metacodes login --provider metask --no-browser`,从 stderr 取 user_code;
  2. 用测试环境提供的用户网页会话(METASK_WEB_SESSION_TOKEN)调 /api/oauth/device/authorize 代替人在浏览器点确认;
  3. 登录进程领到 访问令牌 + 刷新令牌 后退出;
  4. 起 TTY,`--provider metask --model <M>`,发一句话,等回复出现在屏幕上;
  5. 读 HOME 下账本 metask.ndjson:每条 200 记录都带 server_request_id 与服务端报告的 usage;
  6. scripts/metask_reconcile.py 用同一把凭据查网关 /v1/usage,逐请求比对 tokens 与计费 → 必须零差异。

环境:
  METASK_SITE_URL            控制面(默认 https://metask-ai.com;本地 http://localhost:3000)
  METASK_WEB_SESSION_TOKEN   用户网页会话令牌(InsForge accessToken),只用于程序化确认,不写盘
  METASK_MODELS              逗号分隔的模型列表,每个各发一句(默认 GLM-5.3-Flash)
  TTY_SKIP_MODEL=1           跳过(不烧真实额度)
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from e2e_helpers import SKIP, SkipTest  # noqa: E402
from tty_driver import run  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
SITE = os.environ.get("METASK_SITE_URL", "https://metask-ai.com").rstrip("/")
MODELS = [m.strip() for m in os.environ.get("METASK_MODELS", "GLM-5.3-Flash").split(",") if m.strip()]
MARKER = "METASK_TTY_OK_4711"


def _authorize(user_code, web_token):
    req = urllib.request.Request(
        f"{SITE}/api/oauth/device/authorize",
        data=json.dumps({"user_code": user_code}).encode(),
        headers={"content-type": "application/json", "Authorization": f"Bearer {web_token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise SkipTest("METASK_WEB_SESSION_TOKEN 无效或已过期(网页会话令牌约 1 小时),请重新登录后再跑") from None
        raise AssertionError(f"device authorize failed: HTTP {e.code}") from None


SECRET_RE = re.compile(r"(mrt-[A-Za-z0-9]+|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|sk-[A-Za-z0-9]{20,})")


def _redact(line):
    """登录进程的 stderr 在进入断言消息 / 日志前脱敏:刷新令牌、JWT、长期 key 一律打码。"""
    return SECRET_RE.sub("***", line)


def _device_login(bin_path, home, web_token):
    """跑真正的登录命令;人工确认那一步用网页会话代替。返回登录进程 stderr(已脱敏)。"""
    import queue
    import threading

    env = dict(os.environ, HOME=home, METASK_SITE_URL=SITE, METACODES_LOG="*:warn")
    env.pop("METACODES_OAUTH_DIR", None)
    env.pop("METACODES_LEDGER_DIR", None)
    proc = subprocess.Popen([bin_path, "login", "--provider", "metask", "--no-browser"],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env, text=True)
    q = queue.Queue()

    def pump():
        for raw in proc.stderr:
            q.put(_redact(raw.rstrip()))
        q.put(None)

    threading.Thread(target=pump, daemon=True).start()
    lines, code = [], None
    try:
        deadline = time.monotonic() + 30
        while code is None and time.monotonic() < deadline:
            try:
                line = q.get(timeout=0.5)
            except queue.Empty:
                if proc.poll() is not None:
                    break
                continue
            if line is None:
                break
            lines.append(line)
            m = re.match(r"^METASK_USER_CODE=(\S+)$", line.strip())
            if m:
                code = m.group(1)
        assert code, "login did not print METASK_USER_CODE; stderr=%r" % lines[-5:]
        _authorize(code, web_token)
        try:
            proc.wait(timeout=90)
        except subprocess.TimeoutExpired:
            raise AssertionError("login did not finish after authorization")
        while True:
            try:
                line = q.get(timeout=1.0)
            except queue.Empty:
                break
            if line is None:
                break
            lines.append(line)
        assert proc.returncode == 0, "login exited %s; stderr=%r" % (proc.returncode, lines[-5:])
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=10)
        proc.stderr.close()
    store = os.path.join(home, ".metacodes", "oauth", "metask.json")
    assert os.path.exists(store), "oauth store missing after login"
    if os.name != "nt":  # Windows 的私有性靠 ACL,POSIX 位无意义
        assert (os.stat(store).st_mode & 0o077) == 0, "oauth store must be private (0600)"
    with open(store, encoding="utf-8") as f:
        meta = json.load(f)
    for k in ("access_token", "refresh_token", "gateway_url", "models_url"):
        assert meta.get(k), f"oauth store lacks {k}"
    return lines


def _transcript_replies(home, marker):
    """HOME 下所有会话 transcript 里含 marker 的 assistant 文本条数——屏幕上的 marker 可能只是
    输入回显,不能作为回复证据;按条数计,第 i 次运行后至少 i 条,避免读到上一次的回复。"""
    n = 0
    for root, _dirs, files in os.walk(os.path.join(home, ".metacodes")):
        for name in files:
            if name != "transcript.jsonl":
                continue
            with open(os.path.join(root, name), encoding="utf-8", errors="replace") as f:
                for line in f:
                    try:
                        msg = json.loads(line)
                    except ValueError:
                        continue
                    if msg.get("role") != "assistant":
                        continue
                    for block in msg.get("blocks") or []:
                        if block.get("type") == "text" and marker in (block.get("text") or ""):
                            n += 1
                            break
    return n


def _ledger(home):
    path = os.path.join(home, ".metacodes", "ledger", "metask.ndjson")
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


def test_e2e_metask_device_flow_and_reconcile(bin_path):
    if SKIP:
        return
    web_token = os.environ.get("METASK_WEB_SESSION_TOKEN")
    if not web_token:
        raise SkipTest("需要 METASK_WEB_SESSION_TOKEN(用户网页会话)来程序化确认设备码")
    home = tempfile.mkdtemp(prefix="cc-metask-e2e-")
    try:
        _device_login(bin_path, home, web_token)
        for i, model in enumerate(MODELS, start=1):
            prompt = f"Reply with exactly the text {MARKER} and nothing else."
            # settle 睡眠:生成期间 spinner 每 100ms 重画、输出不静默,静默即 turn 结束;
            # 不用 wait:MARKER —— 输入回显里就有 MARKER,会提前命中并在响应完成前 /exit。
            keys = ["sleep:1.0", "type:" + prompt, "key:enter", "sleep:120", "type:/exit", "key:enter", "sleep:2"]
            raw = run(bin_path, keys, base_url=None,
                      env={"HOME": home, "METACODES_PROVIDER": "metask", "METASK_SITE_URL": SITE,
                           "METACODES_NO_PROBE": None, "METASK_API_KEY": None},
                      extra_args=["--model", model], per_key_drain=0.04, startup_drain=1.5)
            text = raw.decode("utf-8", "replace")
            assert "❯" in text, f"[{model}] REPL never rendered; tail={text[-300:]!r}"
            replies = _transcript_replies(home, MARKER)
            assert replies >= i, f"[{model}] expected >= {i} assistant replies containing {MARKER}, found {replies}; screen tail={text[-400:]!r}"
        rows = _ledger(home)
        # 只有 outcome=completed 的 200 才是可计费请求(客户端可能记录 200 但 client_disconnect)
        ok = [r for r in rows if r.get("http_status") == 200 and r.get("outcome") == "completed"]
        assert len(ok) >= len(MODELS), f"ledger has {len(ok)} completed records, expected >= {len(MODELS)}: {rows}"
        for r in ok:
            assert r["server_request_id"].startswith("req-"), r
            assert r["input_tokens"] > 0 and r["output_tokens"] > 0, r
            assert r["protocol"] in ("anthropic_messages", "openai_chat"), r
        # 平台计费是异步的(计量事件 → 触发器),给几秒再对账。/v1/usage 默认 scope=key 只含本次登录
        # 新建的这一个客户端授权的请求,所以"服务端记录数 == 本地完成数"是精确的。
        time.sleep(4)
        rec = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "metask_reconcile.py"),
                              "--ledger", os.path.join(home, ".metacodes", "ledger", "metask.ndjson"),
                              "--oauth", os.path.join(home, ".metacodes", "oauth", "metask.json"), "--json"],
                             capture_output=True, text=True, timeout=120)
        assert rec.returncode == 0, f"reconcile failed ({rec.returncode}):\n{rec.stdout[-1500:]}\n{rec.stderr[-500:]}"
        report = json.loads(rec.stdout)
        assert report["problems"] == [], report
        assert report["server_records"] == len(ok), report
        print("  metask reconcile: %d requests, server cost %s mU" % (report["server_records"], report["server_cost_mu"]))
    finally:
        if os.environ.get("METASK_TTY_KEEP_HOME") == "1":
            print("  kept HOME for diagnosis:", home)
        else:
            shutil.rmtree(home, ignore_errors=True)  # 轮换后的刷新令牌只存在这里,连同临时 HOME 一起销毁
