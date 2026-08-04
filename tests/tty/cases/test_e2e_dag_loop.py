"""真模型 e2e:任务 DAG 闭环全链 —— frontier(深遍历)→ claim(租约)→ fan-out(subagent)→ task-close 闭合 → 波前前进。

场景(预置进 kg store,不靠模型建图):
    root(1) ─contains→ A(2) / B(3) / C(4);C depends_on A、C depends_on B
    ⇒ 初始 frontier:A、B ready(互相独立 → TaskList 出 parallel_hint),C missing_dependencies。

真模型驱动:主 agent 看 TaskList → 起两个 subagent(Task 工具),每个 subagent 用
TaskUpdate(in_progress) 认领(claim 租约,身份=subagent 自己的 agent_ident,程序注入)→
TaskUpdate(completed) 闭合。

权威断言(店内,不依赖模型措辞):
    - A、B 出 frontier，但原 id 仍是 kind=task,status=completed，task-packet 可调用
    - C 变 ready(depends_on 链解锁 = 波前前进)
transcript 断言:主 agent 真调了 ≥2 次 Task(fan-out 而非自己顺序做)。
claim 证据(软):subagent 被要求把认领返回的 JSON 转述进 final_text → 父 transcript
的 TaskOutput 结果里可见 "claimed"(模型转述可能丢,不作硬断言,打印实况)。

凭证:HOME 隔离会挡掉 ~/.metacodes/auth.json(OAuth)——本用例把它播种进 fresh HOME。
无 auth.json → SkipTest(环境无真模型凭证)。
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from e2e_helpers import RETRIES, SKIP, SkipTest, fresh_home, keep_home, read_tool_uses, run_live  # noqa: E402
from tty_driver import run as _run  # noqa: E402

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # tests/tty
CCZIG_ROOT = os.path.dirname(os.path.dirname(HERE))  # cc-zig/
TINYKG = os.path.join(CCZIG_ROOT, "zig-out", "vendor", "tinykg", "tinykg")

REAL_AUTH = os.path.expanduser("~/.metacodes/auth.json")

PROMPT = (
    "Call TaskList now. It shows two ready persistent tasks whose ids start with kg- "
    "(they are independent; note the parallel_hint). For EACH of the two kg- tasks, launch "
    "one subagent via the Task tool (subagent_type: general-purpose, run_in_background: true) "
    "with this exact brief: 'Call TaskUpdate with taskId <the kg- id> and status in_progress "
    "to claim it. Then call TaskUpdate with the same taskId, status completed, and evidence "
    "\"done by subagent\". In your final message, quote the exact JSON returned by the first "
    "TaskUpdate call.' Poll both subagents with TaskOutput until they finish, then call "
    "TaskList once more and tell me which task remains."
)


def _tinykg(store, *args):
    out = subprocess.run([TINYKG] + list(args[:1]) + [store] + list(args[1:]),
                         capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise AssertionError(f"tinykg {args[0]} failed: {out.stderr.strip()[:200]}")
    return out.stdout


def _seed_home():
    """fresh HOME + auth 播种。返回 home。"""
    home = fresh_home()
    os.makedirs(os.path.join(home, ".metacodes"), exist_ok=True)
    shutil.copy(REAL_AUTH, os.path.join(home, ".metacodes", "auth.json"))
    return home


def _node_id(stdout):
    """`node <id>[ ...]` → id(兼容 add-node / ensure-node 输出)。"""
    line = stdout.strip().splitlines()[0]
    assert line.startswith("node "), stdout
    return line.split()[1]


def _frontier_row(fr, needle):
    for line in fr.splitlines():
        if needle in line:
            return line
    raise AssertionError(f"frontier 缺行 {needle!r}:\n{fr}")


def _seed_plan(home, bin_path, proj):
    """离线空跑一次让 App 建 projects/<hash> 目录,再按**生产形状**预置计划图:
    project 节点(ensure-node,domain 命名与真会话 computeKgDomain 一致)─contain→
    每个任务节点(govern-node --parent,即 attachToProject 的底层调用;不挂 = 孤儿,
    --project 召回静默丢失——真会话绝不产孤儿任务,e2e 播种必须同形)。任务分解仍走
    contains/depends_on。写 kg_root 指针。返回 (store, root_id)。"""
    _run(bin_path, ["sleep:1.5", "type:/exit", "key:enter", "sleep:0.5"],
         env={"HOME": home}, cwd=proj)  # 默认死端口 base_url,零模型调用
    proj_dirs = glob.glob(os.path.join(home, ".metacodes", "projects", "*"))
    if len(proj_dirs) != 1:
        raise AssertionError(f"期望 1 个 projects/<hash> 目录,实际 {proj_dirs}")
    store = os.path.join(home, ".metacodes", "kg", "store.kg")
    os.makedirs(os.path.dirname(store), exist_ok=True)
    if not os.path.isdir(store):
        _tinykg(store, "init")

    # project 节点:名字复刻 computeKgDomain = "<basename(anchor)>-<anchor_hash[0..8]>"
    # (hash 即 projects/<hash> 目录名)——真会话 ensure 同名节点会 find 而非重复创建。
    anchor_hash = os.path.basename(proj_dirs[0])
    domain = f"{os.path.basename(proj)}-{anchor_hash[:8]}"
    pid = _node_id(_tinykg(store, "ensure-node", "project", domain, "--schema-type", "project"))
    # 锚形状(乙方案生产同形):project ─contain→ task_anchor ─contains→ root ─contains→ 步骤。
    # 成员挂根不直挂 project(拍平是反模式;membership 靠下钻)。
    aid = _node_id(_tinykg(store, "ensure-anchor", pid, "task"))

    ids = {}
    for key, text in [("root", "发布演示 v1"), ("A", "整理甲清单"), ("B", "整理乙清单"), ("C", "汇总收尾")]:
        ids[key] = _node_id(_tinykg(store, "add-node", "task", text, "--schema-type", "plan_step"))
    _tinykg(store, "add-edge", aid, "contains", ids["root"])
    _tinykg(store, "add-edge", ids["root"], "contains", ids["A"])
    _tinykg(store, "add-edge", ids["root"], "contains", ids["B"])
    _tinykg(store, "add-edge", ids["root"], "contains", ids["C"])
    _tinykg(store, "add-edge", ids["C"], "depends_on", ids["A"])
    _tinykg(store, "add-edge", ids["C"], "depends_on", ids["B"])
    with open(os.path.join(proj_dirs[0], "kg_root"), "w") as f:
        f.write(ids["root"] + "\n")
    # 12b 单入口:锚指针在则 TaskList/inject 从锚深遍历(root 变 branch 行,叶子带 path)。
    with open(os.path.join(proj_dirs[0], "kg_task_anchor"), "w") as f:
        f.write(aid + "\n")

    # 预检①:图完整性——全部任务经锚可达(list-recent --project 下钻,不许孤儿)。
    lr = _tinykg(store, "list-recent", "--project", pid, "--limit", "10")
    for text in ("发布演示 v1", "整理甲清单", "整理乙清单", "汇总收尾"):
        assert text in lr, f"任务不在 project 子树可达域(孤儿):{text}\n{lr}"
    # 预检②:frontier 形状 A/B ready + C missing(播种错就别烧模型)。
    fr = _tinykg(store, "task-frontier", ids["root"], "--limit", "10")
    assert "readiness=ready" in _frontier_row(fr, "整理甲清单"), fr
    assert "readiness=ready" in _frontier_row(fr, "整理乙清单"), fr
    assert "readiness=missing_dependencies" in _frontier_row(fr, "汇总收尾"), fr
    return store, ids


def test_e2e_dag_closed_loop(bin_path):
    if SKIP:
        return
    if not os.path.exists(REAL_AUTH):
        raise SkipTest("无 ~/.metacodes/auth.json,真模型凭证不可得")
    if not os.path.exists(TINYKG):
        raise SkipTest("vendor/tinykg/tinykg 缺失")

    diags = []
    for attempt in range(RETRIES):
        home = _seed_home()
        proj = tempfile.mkdtemp(prefix="cc-e2e-dagproj-")
        store, ids = _seed_plan(home, bin_path, proj)

        run_live(bin_path,
                 ["sleep:1.2", "type:" + PROMPT, "key:enter", "sleep:150"],
                 home, cwd=proj, per_key_drain=0.02, startup_drain=1.5)

        # ── 权威层:店内波前 ──
        fr = _tinykg(store, "task-frontier", ids["root"], "--limit", "10")
        a_closed = "整理甲清单" not in fr
        b_closed = "整理乙清单" not in fr
        c_ready = "汇总收尾" in fr and "readiness=ready" in _frontier_row(fr, "汇总收尾") if "汇总收尾" in fr else False
        a_packet = _tinykg(store, "task-packet", ids["A"], "--limit", "10")
        b_packet = _tinykg(store, "task-packet", ids["B"], "--limit", "10")
        a_stable = (f"task_packet\t{ids['A']}\tstatus=completed" in a_packet and
                    f"task\t{ids['A']}\ttask\t整理甲清单" in a_packet and
                    "verified_by_out" in a_packet)
        b_stable = (f"task_packet\t{ids['B']}\tstatus=completed" in b_packet and
                    f"task\t{ids['B']}\ttask\t整理乙清单" in b_packet and
                    "verified_by_out" in b_packet)

        # ── transcript 层:fan-out + claim 转述 ──
        uses = read_tool_uses(home)
        task_spawns = [u for u in uses if u.get("name") == "Task"]
        claims_relayed = any("claimed" in (u.get("input") or "") for u in uses)
        # TaskOutput 结果(subagent final_text)在 tool_result 里,read_tool_uses 只收 tool_use;
        # 粗查 transcript 全文找 "claimed"。
        if not claims_relayed:
            for path in glob.glob(os.path.join(home, ".metacodes", "projects", "*", "*", "transcript.jsonl")):
                with open(path, encoding="utf-8", errors="replace") as f:
                    if "claimed" in f.read():
                        claims_relayed = True
                        break

        diag = (f"attempt{attempt}: a_closed={a_closed} b_closed={b_closed} c_ready={c_ready} "
                f"a_stable={a_stable} b_stable={b_stable} "
                f"task_spawns={len(task_spawns)} claims_relayed={claims_relayed} "
                f"tools={[u.get('name') for u in uses]} home={home}")
        diags.append(diag)
        print("    " + diag)

        if a_closed and b_closed and c_ready and a_stable and b_stable and len(task_spawns) >= 2:
            return  # 闭环全链 PASS
        # A/B 闭合但没 fan-out(模型自己顺序做了)→ 漂移方向,重试。
        # 什么都没动 → 也重试。

    # 全部 attempt 后:若任一 attempt 闭合发生但 fan-out 从未出现 → 漂移(路径未触发)。
    # (漂移 skip 不保留 home——凭证拷贝不留;硬失败保留最后一个供验尸,其余交 atexit janitor。)
    if any("a_closed=True b_closed=True" in d and "task_spawns=0" in d for d in diags):
        raise SkipTest("模型漂移:任务被闭合但未用 Task fan-out(顺序自做)。\n" + "\n".join(diags))
    keep_home(home)
    raise AssertionError("DAG 闭环 e2e 全部 attempt 失败:\n" + "\n".join(diags))
