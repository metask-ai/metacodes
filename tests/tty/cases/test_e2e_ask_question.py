"""tty 真模型 e2e:AskUserQuestion 像素对齐 + 交互(单选/多问导航/无崩溃)。

为什么真模型:AskUserQuestion 对话框只在模型**真的调工具**时弹出。强后端(napi 端点)
能稳定遵循"立即调 AskUserQuestion"的指令。

守护:① 对话框像素元素(❯ 编号 / Type something / Chat about this / 提示行);
② ↓↓+enter 选项可用 + 返回正确答案;③ 多问 → 切换 + 导航条;④ **无 panic**
(2026-06-07 实测:单问 enter 后 advanceView 推过末尾 → questions[view] OOB 崩溃,已修;
本测试的 _assert_no_crash 守这条回归)。

wait_s 给足(模型要时间调工具):~42s。SKIP=TTY_SKIP_MODEL=1。
"""
import os
import sys
import re
import time
import json
import glob
import shutil

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import run  # noqa: E402
from e2e_helpers import SKIP, SkipTest, fresh_home  # noqa: E402

WAIT = 42


def _no_crash(raw, home):
    for m in (b"panic", b"reached unreachable", b"index out of bounds", b"integer overflow"):
        if m in raw:
            txt = raw.decode("utf-8", "replace")
            i = txt.find(m.decode())
            raise AssertionError("AskUserQuestion 进程 panic(真 regression):...%s...\n  HOME: %s"
                                 % (txt[max(0, i - 80):i + 250], home))


def _answers(home):
    """从 transcript 取 AskUserQuestion 的 tool_result answers。"""
    for path in glob.glob(os.path.join(home, ".cc-zig", "projects", "*", "*", "transcript.jsonl")):
        for line in open(path, encoding="utf-8", errors="replace"):
            if "tool_result" not in line:
                continue
            try:
                m = json.loads(line)
            except json.JSONDecodeError:
                continue
            for b in m.get("blocks", []):
                if b.get("type") == "tool_result" and '"answers"' in (b.get("content") or ""):
                    return b["content"]
    return ""


def _all_tool_results(home):
    """拼接该 HOME 下所有 tool_result content(用于断言哨兵结果/排除字面 label)。"""
    out = []
    for path in glob.glob(os.path.join(home, ".cc-zig", "projects", "*", "*", "transcript.jsonl")):
        for line in open(path, encoding="utf-8", errors="replace"):
            if "tool_result" not in line:
                continue
            try:
                m = json.loads(line)
            except json.JSONDecodeError:
                continue
            for b in m.get("blocks", []):
                if b.get("type") == "tool_result":
                    out.append(b.get("content") or "")
    return "\n".join(out)


def test_e2e_ask_single_select(bin_path):
    """单选:模型调 AskUserQuestion → 对话框像素元素齐 → ↓↓+enter 选第 3 项 → 答案正确 + 不崩。"""
    if SKIP:
        return
    prompt = ('Use the AskUserQuestion tool now: ONE single-select question header "Color" '
              '"Which color?" options Red/Green/Blue, each with a short description. Call immediately.')
    home = fresh_home()
    keys = ["sleep:1.0", "type:" + prompt, "key:enter", "sleep:%d" % WAIT,
            "key:down", "key:down", "sleep:0.5", "key:enter", "sleep:3"]
    raw = run(bin_path, keys, base_url=None, env={"HOME": home},
              permission="bypassPermissions", per_key_drain=0.06, startup_drain=1.2)
    _no_crash(raw, home)
    text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", raw.decode("utf-8", "replace"))
    # 对话框被渲染过(像素元素:❯ + Type something + Chat about this)。漂移(没调工具)→ skip。
    if "Type something" not in text or "Chat about this" not in text:
        shutil.rmtree(home, ignore_errors=True)
        raise SkipTest("模型未调 AskUserQuestion(漂移/超时)。HOME: %s" % home)
    # 像素元素硬断言。
    assert "❯" in text, "缺选中箭头 ❯"
    assert "1. " in text and "2. " in text, "缺选项编号 N."
    assert "Enter to select · ↑/↓ to navigate · Esc to cancel" in text, "提示行未对齐 cc"
    # 选择结果(↓↓ 选第 3 项;模型给的选项名不定,只断言有 answers 输出)。
    ans = _answers(home)
    assert '"answers"' in ans, "未返回 answers(交互未完成)。HOME: %s" % home
    shutil.rmtree(home, ignore_errors=True)


def test_e2e_ask_multi_question_nav(bin_path):
    """多问:导航条 ←  chip  ✔ Submit  → 出现 + → 切到第 2 问 + 不崩(用户点名的左右键交互)。"""
    if SKIP:
        return
    prompt = ('Use AskUserQuestion now with TWO single-select questions in one call: '
              'Q1 header "Color" "Favorite color?" options Red/Blue; '
              'Q2 header "Size" "Preferred size?" options Small/Large. Call immediately.')
    home = fresh_home()
    keys = ["sleep:1.0", "type:" + prompt, "key:enter", "sleep:%d" % WAIT,
            "key:right", "sleep:0.6"]  # → 切第 2 问
    raw = run(bin_path, keys, base_url=None, env={"HOME": home},
              permission="bypassPermissions", per_key_drain=0.06, startup_drain=1.2)
    _no_crash(raw, home)
    text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", raw.decode("utf-8", "replace"))
    if "Submit" not in text or ("☐" not in text and "[ ]" not in text):
        shutil.rmtree(home, ignore_errors=True)
        raise SkipTest("模型未调多问 AskUserQuestion(漂移/超时)。HOME: %s" % home)
    # 导航条元素(← / Submit / →)。
    assert "Submit" in text, "缺导航条 Submit"
    # → 切到 Q2:屏幕应出现第 2 问的问题文本。
    assert "Preferred size?" in text, "→ 未切到第 2 问(导航条左右键未生效)。HOME: %s" % home
    shutil.rmtree(home, ignore_errors=True)


def test_e2e_ask_preview_note_vim(bin_path):
    """preview note 编辑:n 进编辑态 → ctrl+g 唤起 $EDITOR → 编辑器内容回填到 note + 不崩。

    用 fake $EDITOR(写固定串)验证 ctrl+g 唤起编辑器 + raw/cooked termios 往返 + 回填全链。
    模型要带 preview 字段调 AskUserQuestion;漂移(不带 preview/不调)→ skip。
    """
    if SKIP:
        return
    import stat
    ed = os.path.join(fresh_home(), "fake_editor.sh")
    os.makedirs(os.path.dirname(ed), exist_ok=True)
    with open(ed, "w") as f:
        f.write("#!/bin/sh\nprintf 'note from editor' > \"$1\"\n")
    os.chmod(ed, os.stat(ed).st_mode | stat.S_IEXEC)

    prompt = ('Use AskUserQuestion now: ONE single-select header "Layout" "Which layout?" '
              '2 options A and B, EACH with a preview field containing a short ASCII mockup. Call immediately.')
    home = fresh_home()
    keys = ["sleep:1.0", "type:" + prompt, "key:enter", "sleep:%d" % WAIT,
            "type:n", "sleep:0.5", "raw:\\x07", "sleep:1.5"]  # n 进 note 编辑 → ctrl+g 唤起 editor
    raw = run(bin_path, keys, base_url=None, env={"HOME": home, "EDITOR": ed},
              permission="bypassPermissions", per_key_drain=0.06, startup_drain=1.2)
    _no_crash(raw, home)
    text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", raw.decode("utf-8", "replace"))
    if "Notes:" not in text:
        shutil.rmtree(home, ignore_errors=True)
        raise SkipTest("模型未调带 preview 的 AskUserQuestion(漂移/超时)。HOME: %s" % home)
    assert "note from editor" in text, ("ctrl+g 未唤起 $EDITOR 或未回填(应见 'note from editor')。HOME: %s" % home)
    shutil.rmtree(home, ignore_errors=True)


def test_e2e_ask_other_input_focus(bin_path):
    """bug1:↓ 到 'Type something'(Other)→ 出现输入态(光标块 ▏ + 'Type your answer' 提示行 + 可打字)。

    真 tty 实测旧版:选 Other 无任何输入焦点视觉,用户不知能打字。修后:选中即显光标块+输入态提示行。
    """
    if SKIP:
        return
    prompt = ('Use the AskUserQuestion tool now: ONE single-select question header "Color" '
              '"Which color?" options Red/Green, each with a short description. Call immediately.')
    home = fresh_home()
    # 2 真实选项 → Other 在 idx2(第3项)。默认选 idx0,↓↓ 到 Other。再打字验证内联输入。
    keys = ["sleep:1.0", "type:" + prompt, "key:enter", "sleep:%d" % WAIT,
            "key:down", "key:down", "sleep:0.4", "type:hello", "sleep:0.6"]
    raw = run(bin_path, keys, base_url=None, env={"HOME": home},
              permission="bypassPermissions", per_key_drain=0.06, startup_drain=1.2)
    _no_crash(raw, home)
    text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", raw.decode("utf-8", "replace"))
    if "Type something" not in text:
        shutil.rmtree(home, ignore_errors=True)
        raise SkipTest("模型未调 AskUserQuestion(漂移/超时)。HOME: %s" % home)
    # bug1 修复点:Other 选中=输入态,出现专属提示行 + 内联打字生效。
    assert "Type your answer" in text, ("Other 选中未进输入态(缺 'Type your answer' 提示行)。HOME: %s" % home)
    assert "▏" in text, ("Other 选中未显输入光标块 ▏。HOME: %s" % home)
    assert "hello" in text, ("Other 内联打字未回显(输入焦点未生效)。HOME: %s" % home)
    shutil.rmtree(home, ignore_errors=True)


def test_e2e_ask_chat_about_free_response(bin_path):
    """bug2:↓ 到 'Chat about this' + enter → 不把字面 label 当答案,转自由回复(模型不收到 'Chat about this')。

    真 tty 实测旧版:选 Chat 把 'Chat about this' 当答案塞模型。修后:返回 user_chose_free_response 哨兵结果。
    """
    if SKIP:
        return
    prompt = ('Use the AskUserQuestion tool now: ONE single-select question header "Color" '
              '"Which color?" options Red/Green, each with a short description. Call immediately.')
    home = fresh_home()
    # Chat about this 在 idx3(第4项=最后)。↓↓↓ 到 Chat,enter 提交。
    keys = ["sleep:1.0", "type:" + prompt, "key:enter", "sleep:%d" % WAIT,
            "key:down", "key:down", "key:down", "sleep:0.4", "key:enter", "sleep:3"]
    raw = run(bin_path, keys, base_url=None, env={"HOME": home},
              permission="bypassPermissions", per_key_drain=0.06, startup_drain=1.2)
    _no_crash(raw, home)
    text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", raw.decode("utf-8", "replace"))
    if "Chat about this" not in text:
        shutil.rmtree(home, ignore_errors=True)
        raise SkipTest("模型未调 AskUserQuestion(漂移/超时)。HOME: %s" % home)
    # bug2 修复点:tool_result 是自由回复哨兵结果,不含字面 answers=["Chat about this"]。
    blob = _all_tool_results(home)
    assert '"Chat about this"' not in blob, ("Chat 被当字面答案塞模型(应转自由回复)。HOME: %s" % home)
    assert "user_chose_free_response" in blob, ("Chat 未转自由回复哨兵结果(缺 user_chose_free_response)。HOME: %s" % home)
    shutil.rmtree(home, ignore_errors=True)


def test_e2e_ask_too_many_questions(bin_path):
    """超限(> MAX_QUESTIONS=9)→ 工具层 TooManyQuestions,不漏进 dialog 变 InputAborted。

    **此 e2e 已退化为弱验证(2026-06-09)**:核心不变量由离线确定性单测守
    (src/tools/ask_user.zig:235 `>9 问 → TooManyQuestions`、:260 `0 问 → TooManyQuestions`)——
    那是确定的、可靠的。真模型 e2e **测不准**此路径:模型几乎总把问题数压到 ≤9(合法区,
    用户放宽 MAX_QUESTIONS=9 自 cc 的 4),≤9 问合法 → 进 dialog 等输入 → e2e 不喂答案 → 超时
    InputAborted(**正常**,非 bug)。故本 e2e 只做"软存在性"检查:若模型恰好传了 >9 问触发工具层
    拦截,则验 TooManyQuestions;否则 skip(模型未触发超限路径,非 bug)。多问 dialog 正常路径由
    test_e2e_ask_multi_question_nav 覆盖。
    """
    if SKIP:
        return
    days = "/".join("D%d-%s" % (d, m) for d in range(1, 5) for m in ("早", "午", "晚"))  # 12 个
    prompt = ('用 AskUserQuestion 工具,一次调用传 12 个独立问题(%s),每问选项米饭/面条/拌汤。'
              '必须一次调用传全部 12 个问题,不要拆成多次调用,不要压缩,不要用 Task。' % days)
    home = fresh_home()
    keys = ["sleep:1.0", "type:" + prompt, "key:enter", "sleep:%d" % WAIT]
    raw = run(bin_path, keys, base_url=None, env={"HOME": home},
              permission="bypassPermissions", per_key_drain=0.06, startup_drain=1.2)
    _no_crash(raw, home)
    blob = _all_tool_results(home)
    # 只有当工具层真触发了 TooManyQuestions(模型传 >9)才算命中被测路径并验证;
    # 其余一切(模型压到 ≤9 合法 → InputAborted 超时 / 走 Task / 漂移)→ skip(非 bug)。
    if "TooManyQuestions" in blob:
        shutil.rmtree(home, ignore_errors=True)
        return  # 命中超限拦截:工具层清晰报错,绿。
    shutil.rmtree(home, ignore_errors=True)
    raise SkipTest("模型未传 >9 问触发超限(压到 ≤9 合法/走 Task/漂移);核心不变量由离线单测守")

