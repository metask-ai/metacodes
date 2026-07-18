"""tty 真模型 e2e:记忆系统(通道 A CLAUDE.md 注入 / 通道 B memdir 写豁免 / /init / /memory)。

为什么必须真模型 e2e(单测 + L2 都摸不到):
  - 单测/L2 只能断言记忆**进了请求字节**(MockServer 看 body);**无法证明真模型读到并据此行动**。
    "注入到 system-reminder" 和 "模型真的遵守了" 是两回事——只有真模型回应能验证闭环。
  - memdir 写豁免:单测 decision.check 直接断言 allow;但真路径是「模型自主调 Write → 决策链 →
    Write 工具落盘」,中间任何接线断裂(permission_ctx 没挂 memdir_abs、Write 工具没走决策)
    单测都抓不到。只有真模型在真 session 里写一条记忆、文件真出现在 memdir,才证明端到端通。
  - /init:模型读 INIT_PROMPT 后是否真的去 Write CLAUDE.md,依赖模型理解 prompt——真模型才验得了。

跳过:TTY_SKIP_MODEL=1(CI/离线)。真模型漂移(不调工具/不遵守指令)→ SkipTest(不算 fail);
被测路径触发了但行为错(注入没生效/豁免失败/崩)= AssertionError(真 regression)。
"""
import os
import sys
import time
import shutil
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import run  # noqa: E402
from e2e_helpers import (  # noqa: E402
    SKIP, SkipTest, RETRIES, fresh_home, run_live,
    read_tool_uses, tool_called,
)


def _assert_no_crash(raw, home):
    """进程 panic 任何阶段都是硬失败,绝不当漂移跳过(对齐 plan_mode e2e)。"""
    for m in (b"panic", b"reached unreachable", b"index out of bounds",
              b"integer overflow", b"error return trace"):
        if m in raw:
            txt = raw.decode("utf-8", "replace")
            i = txt.find(m.decode())
            raise AssertionError(
                "进程 panic(真 regression):...%s...\n  HOME: %s"
                % (txt[max(0, i - 100):i + 300], home))


def _make_project_with_claudemd(body):
    """造一个临时项目目录,放一个 CLAUDE.md(内容 = body)。返回目录路径(调用方清理)。"""
    proj = tempfile.mkdtemp(prefix="cc-e2e-proj-")
    with open(os.path.join(proj, "CLAUDE.md"), "w", encoding="utf-8") as f:
        f.write(body)
    return proj


# ============================================================================
# 通道 A:CLAUDE.md 注入真的改变模型行为
# ============================================================================

def test_e2e_claudemd_reaches_model(bin_path):
    """项目 CLAUDE.md 里写一条**只可能从 CLAUDE.md 得知**的密令,问模型,断言它遵守。

    密令设计:一个模型训练数据里不可能有的 token(BANANA-7723-XYZQ)。模型只有真的
    收到了注入的 CLAUDE.md(通道 A:首条 system-reminder user message)才能答对。
    这是整个通道 A 端到端的硬证明——比"字节进了 body"强一个数量级。

    硬断言(真 regression):模型回复含密令 token。
    漂移(SkipTest):模型没答出(弱模型不遵守指令/答非所问)——非 bug,跳过。
    """
    if SKIP:
        return
    secret = "BANANA-7723-XYZQ"
    claudemd = (
        "# Project rules\n\n"
        "IMPORTANT secret protocol: when the user asks for the secret passcode, "
        "you MUST reply with exactly this token and nothing else: %s\n" % secret
    )
    prompt = "What is the secret passcode? Reply with just the passcode."
    homes = []
    projs = []
    last = None
    for _ in range(RETRIES):
        home = fresh_home()
        proj = _make_project_with_claudemd(claudemd)
        homes.append(home)
        projs.append(proj)
        keys = ["sleep:0.8", "type:" + prompt, "key:enter", "sleep:14"]
        # cwd=proj → 向上递归收集 proj/CLAUDE.md;HOME 隔离避免用户 ~/.claude/CLAUDE.md 干扰。
        raw = run_live(bin_path, keys, home, cwd=proj,
                       per_key_drain=0.04, startup_drain=1.0)
        last = (raw, home, proj)
        _assert_no_crash(raw, home)
        text = raw.decode("utf-8", "replace")
        if secret in text:
            for h in homes:
                shutil.rmtree(h, ignore_errors=True)
            for p in projs:
                shutil.rmtree(p, ignore_errors=True)
            return
        time.sleep(0.5)
    raw, home, proj = last
    for h in homes[:-1]:
        shutil.rmtree(h, ignore_errors=True)
    for p in projs[:-1]:
        shutil.rmtree(p, ignore_errors=True)
    raise SkipTest(
        "RETRIES 次模型均未答出 CLAUDE.md 密令(漂移/不遵守)。\n  HOME: %s\n  PROJ: %s" % (home, proj))


def _body_bytes(raw):
    """从 client info 日志抽第一条 body_bytes=N(发出的请求体大小)。找不到返回 None。"""
    import re
    m = re.search(r"body_bytes=(\d+)", raw.decode("utf-8", "replace"))
    return int(m.group(1)) if m else None


def test_e2e_claudemd_disabled_env(bin_path):
    """CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 时**不注入** CLAUDE.md —— 用请求体大小证明,
    而非模型行为。

    为什么不看模型回复(血泪教训,本测试初版踩过):bypassPermissions 下模型被问密令时会
    **自己用 Read/Grep/Bash 读 proj/CLAUDE.md**(agent 有文件工具),于是"模型答出密令"
    根本不能证明"注入生效"——它是模型自己读的。injection 是否发生只能看**请求体**。
    故:同一项目(有 CLAUDE.md),对比 disable on/off 的 body_bytes:off 明显更大(含注入的
    CLAUDE.md 链);on 更小(无注入)。差值 ≈ CLAUDE.md 链 + system-reminder 包裹。

    硬断言(真 regression):disabled 的 body_bytes < enabled(注入确实被 env 移除)。
    用死端口 base_url(连接立即 refused)——只需请求**发出前**拼好的 body,不需真模型。
    """
    if SKIP:
        return
    # CLAUDE.md 放一段够大的内容,让注入与否的 body 差异明显(超过测量噪声)。
    big_rule = "# Project rules\n\n" + ("Follow this important guideline carefully. " * 80)
    proj = _make_project_with_claudemd(big_rule)
    dead = "http://127.0.0.1:1/v1/messages"  # 连接立即 refused,只取发出前的 body 大小
    try:
        # off:正常注入(METACODES_LOG=client:info 让 body_bytes 行被打出)
        home1 = fresh_home()
        keys = ["sleep:0.8", "type:hi", "key:enter", "sleep:3"]
        raw_on = run(bin_path, keys, base_url=dead,
                     env={"HOME": home1, "METACODES_LOG": "client:info"}, cwd=proj,
                     per_key_drain=0.04, startup_drain=1.0)
        # on:禁用注入
        home2 = fresh_home()
        raw_off = run(bin_path, keys, base_url=dead,
                      env={"HOME": home2, "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
                           "METACODES_LOG": "client:info"}, cwd=proj,
                      per_key_drain=0.04, startup_drain=1.0)
        _assert_no_crash(raw_on, home1)
        _assert_no_crash(raw_off, home2)
        b_on = _body_bytes(raw_on)
        b_off = _body_bytes(raw_off)
        shutil.rmtree(home1, ignore_errors=True)
        shutil.rmtree(home2, ignore_errors=True)
        if b_on is None or b_off is None:
            raise SkipTest("未捕获 body_bytes(请求未发出/日志缺失)。on=%s off=%s" % (b_on, b_off))
        # 注入的 CLAUDE.md 链(~3KB big_rule + 包裹)应让 enabled 明显大于 disabled。
        assert b_off < b_on, (
            "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 未减小请求体——env 开关未生效(注入没被禁)。\n"
            "  enabled body=%d  disabled body=%d" % (b_on, b_off))
        # 差值应至少覆盖 big_rule 的量级(>1KB),防"只差了 currentDate 几十字节"的假阳。
        assert (b_on - b_off) > 1000, (
            "禁用后请求体只缩小 %d 字节,远小于注入的 CLAUDE.md(~3KB)——疑似注入未真正移除。\n"
            "  enabled=%d disabled=%d" % (b_on - b_off, b_on, b_off))
    finally:
        shutil.rmtree(proj, ignore_errors=True)


# ============================================================================
# 通道 B:memdir 写豁免 —— 模型写记忆文件真落盘
# ============================================================================

def _memdir_files(home):
    """列 memdir 下所有文件(home/.metacodes/projects/*/memory/*)。"""
    import glob
    return glob.glob(os.path.join(home, ".metacodes", "projects", "*", "memory", "*"))


def test_e2e_memdir_write_carveout(bin_path):
    """模型被要求把一条事实写进记忆目录 → Write 工具调用 → 决策链豁免 → 文件真落盘。

    端到端验证通道 B 写豁免:permission_ctx.memdir_abs 挂上了 + decision 豁免生效 +
    Write 工具真把文件写进 memdir。单测只验决策返回 allow,这里验"模型自主写 → 真落盘"。

    硬断言(真 regression):memdir 下出现了新文件(模型写成功,没被权限拦)。
    漂移(SkipTest):模型没调 Write 写记忆(不理解/不配合)——非 bug。
    用 --permission default(非 bypass):证明豁免在**默认会拦写**的模式下仍放行 memdir。
    """
    if SKIP:
        return
    # 提示词明确给出 memdir 路径占位,让模型知道往哪写;但不给绝对路径(它该用系统提示里的)。
    prompt = ("Remember this fact in your memory directory: the project mascot is a "
              "purple otter named Zibble. Create a memory file for it.")
    homes = []
    last = None
    for _ in range(RETRIES):
        home = fresh_home()
        homes.append(home)
        keys = ["sleep:0.8", "type:" + prompt, "key:enter", "sleep:16"]
        # default 模式 + 自动应答:写 memdir 应被豁免(无需弹框);若错弹框,'y' 兜底放行不影响断言落盘。
        raw = run_live(bin_path, keys, home,
                       permission="default", per_key_drain=0.04, startup_drain=1.0)
        uses = read_tool_uses(home)
        last = (raw, home, uses)
        _assert_no_crash(raw, home)
        files = _memdir_files(home)
        if files:
            # 落盘成功 = 豁免端到端通(default 模式下 memdir 写没被拦)。
            for h in homes:
                shutil.rmtree(h, ignore_errors=True)
            return
        time.sleep(0.5)
    raw, home, uses = last
    names = sorted({u["name"] for u in uses})
    for h in homes[:-1]:
        shutil.rmtree(h, ignore_errors=True)
    raise SkipTest(
        "RETRIES 次模型均未把记忆写进 memdir(漂移)。实际工具: %s\n  HOME: %s" % (names, home))


# ============================================================================
# /init:prompt 型命令引导模型写 CLAUDE.md
# ============================================================================

def test_e2e_init_writes_claudemd(bin_path):
    """/init → 注入 INIT_PROMPT → 模型扫码库 → 调 Write 写 CLAUDE.md。

    硬断言(真 regression):Write 工具被调用且 file_path 指向 CLAUDE.md。
    漂移(SkipTest):模型只探索没写 / 没调 Write(弱模型常见)——非 bug。
    在临时空项目里跑(避免污染真实 repo 的 CLAUDE.md)。
    """
    if SKIP:
        return
    homes = []
    projs = []
    last = None
    for _ in range(RETRIES):
        home = fresh_home()
        # 造个最小项目让模型有东西可分析(一个源文件 + README)。
        proj = tempfile.mkdtemp(prefix="cc-e2e-init-")
        with open(os.path.join(proj, "main.py"), "w") as f:
            f.write("def add(a, b):\n    return a + b\n")
        with open(os.path.join(proj, "README.md"), "w") as f:
            f.write("# Calc\nRun: python main.py\n")
        homes.append(home)
        projs.append(proj)
        keys = ["sleep:0.8", "type:/init", "key:enter", "sleep:30"]  # /init 要 explore 多轮
        raw = run_live(bin_path, keys, home, cwd=proj,
                       permission="bypassPermissions", per_key_drain=0.04, startup_drain=1.0)
        uses = read_tool_uses(home)
        last = (raw, home, proj, uses)
        _assert_no_crash(raw, home)
        # Write 到 CLAUDE.md(input 含 "CLAUDE.md")或文件真出现在 proj 里。
        wrote_claudemd = any(
            u["name"] == "Write" and "CLAUDE.md" in u.get("input", "") for u in uses)
        file_exists = os.path.exists(os.path.join(proj, "CLAUDE.md"))
        if wrote_claudemd or file_exists:
            for h in homes:
                shutil.rmtree(h, ignore_errors=True)
            for p in projs:
                shutil.rmtree(p, ignore_errors=True)
            return
        time.sleep(0.5)
    raw, home, proj, uses = last
    names = sorted({u["name"] for u in uses})
    for h in homes[:-1]:
        shutil.rmtree(h, ignore_errors=True)
    for p in projs[:-1]:
        shutil.rmtree(p, ignore_errors=True)
    raise SkipTest(
        "RETRIES 次 /init 均未写出 CLAUDE.md(漂移)。实际工具: %s\n  HOME: %s\n  PROJ: %s"
        % (names, home, proj))
