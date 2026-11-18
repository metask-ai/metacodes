"""Read recorded PR evidence without opening an App Server thread."""
from __future__ import annotations

from datetime import datetime
from html import escape
import json


LABELS = {
    "pending": "等待处理", "reviewing": "开始审核", "review_thread": "审核会话",
    "waiting": "等待", "working": "开始修复", "repair_finished": "修复完成",
    "validating": "本地验证", "validation_log": "验证日志",
    "validation_passed": "验证通过", "validation_failed": "验证失败",
    "ci_result": "GitHub CI", "pushing": "开始推送", "pushed": "已推送",
    "updating_base": "同步 main", "merging": "提交合并", "merged": "已合并",
    "closed": "已关闭", "needs_decision": "等待处理决定",
    "needs_human": "等待人工批准", "human_requested": "请求人工批准",
    "human_approved": "人工已批准", "notice_failed": "通知失败",
}


def snapshot(store, repo, number, after):
    row = store.get(repo, number)
    binding = json.loads(row["binding"])
    events = []
    for event in store.events(repo, number, after):
        detail = json.loads(event["detail"])
        # Legacy events included the literal response to a decision. Publishing
        # an audit view does not require republishing the user's answer.
        detail.pop("answer", None)
        detail.pop("state", None)
        if detail.get("report"):
            detail["report"] = json.loads(detail["report"])
        events.append({**dict(event), "detail": detail})
    return {"repo": repo, "number": number, "state": row["state"], "head": row["head"],
            "rounds": row["rounds"], "agent_runs": row["agent_runs"],
            "source_thread": binding["thread"], "worker_thread": row["worker_thread"],
            "events": events, "cursor": events[-1]["id"] if events else after}


def html_fragment(view, utc_offset):
    """A self-contained, in-conversation snapshot; expand each event for evidence."""
    def e(value):
        return escape(str(value))

    def block(text):
        return "<p>" + e(text) + "</p>"

    def session(thread):
        # Only local Codex IDs are allowed in the app deep link.
        if not thread or not all(c.isascii() and (c.isalnum() or c in "-_") for c in thread):
            return ""
        return f'<p><a href="codex://threads/{e(thread)}">打开会话</a></p>'

    def item(event):
        detail = event["detail"]
        report = detail.get("report")
        label = "审核结果 · " + report["verdict"] if report else LABELS.get(event["state"], event["state"])
        at = datetime.fromtimestamp(event["at"], utc_offset).strftime("%m-%d %H:%M:%S")
        lines = [block(detail[key]) for key in ("summary", "reason", "result") if detail.get(key)]
        lines.extend(block(f"{label} {detail[key]}") for key, label in (
            ("head", "提交"), ("base", "基线"), ("checkpoint", "检查点"), ("rounds", "修复轮次"))
            if detail.get(key) is not None)
        if report:
            lines.append(block(report["summary"]))
            if report.get("question"):
                lines.append(block(report["question"]))
            for finding in report["findings"]:
                lines.append(block(f'{finding["path"]}:{finding["line"]} · {finding["reason"]}'))
                lines.append(block(finding["acceptance"]))
        lines.extend(block(check) for check in detail.get("checks", []))
        lines.append(session(detail.get("worker_thread") or detail.get("thread")))
        if detail.get("log"):
            lines.append(block("本地日志 " + detail["log"]))
        evidence = "".join(lines)
        summary = f'<time class="text-muted">{at}</time> <span>{e(label)}</span>'
        if not evidence:
            return "<li>" + summary + "</li>"
        return f'<li><details><summary class="cursor-interaction">{summary}</summary>{evidence}</details></li>'

    count = f'{view["agent_runs"]} 次调用 · {view["rounds"]} 轮修复'
    recent = view["events"][-10:]
    earlier = view["events"][:-10]
    rows = "\n".join(item(event) for event in reversed(recent))
    history = ""
    if earlier:
        old_rows = "\n".join(item(event) for event in reversed(earlier))
        history = f'<details><summary class="cursor-interaction">更早的记录（{len(earlier)}）</summary><ul>{old_rows}</ul></details>'
    return f"""<section id="pr-timeline-{view['number']}" aria-label="PR 流程记录"
 data-repo="{e(view['repo'])}" data-number="{view['number']}">
<style>
#pr-timeline-{view['number']} li {{ margin-block: .55rem; }}
#pr-timeline-{view['number']} li p {{ margin: .4rem 0; overflow-wrap: anywhere; white-space: pre-wrap; }}
#pr-timeline-{view['number']} time {{ font-variant-numeric: tabular-nums; margin-right: .5rem; }}
#pr-timeline-{view['number']} [hidden] {{ display: none; }}
</style>
<div>{e(view['repo'])} #{view['number']} · {e(LABELS.get(view['state'], view['state']))}</div>
<div class="text-muted">{e(count)} · {e((view['head'] or '')[:8])}</div>
<ul>{rows}</ul>
{history}
<button class="btn" type="button" data-refresh hidden>刷新 PR 时间线</button>
<p data-refresh-status aria-live="polite"></p>
</section>
<script>
(() => {{
  const root = document.getElementById("pr-timeline-{view['number']}");
  const button = root.querySelector("[data-refresh]");
  const status = root.querySelector("[data-refresh-status]");
  if (typeof window.openai?.sendFollowUpMessage !== "function") return;
  button.hidden = false;
  button.addEventListener("click", async () => {{
    button.disabled = true;
    status.textContent = "";
    try {{
      await window.openai.sendFollowUpMessage({{
        title: "刷新 PR 时间线",
        prompt: `在当前聊天中重新读取并展示 ${{root.dataset.repo}} #${{root.dataset.number}} 的 PR 时间线。`
      }});
    }} catch {{
      status.textContent = "刷新请求未发送，请重试。";
    }} finally {{
      button.disabled = false;
    }}
  }});
}})();
</script>
"""
