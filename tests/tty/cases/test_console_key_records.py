"""Keys as a Windows console sends them with win32-input-mode on (#386).

The REPL turns win32-input-mode on so that Shift+Enter is not Enter. From then
on the console sends every key as a record `CSI Vk;Sc;Uc;Kd;Cs;Rc _`, key-ups
and modifier keys included, and every reader of the console input must read
the keys the records stand for, not the records: the permission dialog and the
question dialog each read keys outside the prompt's own key parser. These cases
press keys as records on Windows (the pseudo console
takes records written to it, as Windows Terminal sends them) and as the VT
bytes the same keys send everywhere else, and expect the same outcome.

`key:` and `type:` events would not do on Windows: ConPTY hands bytes a
terminal writes in one go to the program as those bytes, without making
records of them, so they never reach the decoder.
"""
import json
import os
import sys

from tty_driver import READY, case_tmpdir, run, wait_for
from asserts import TTYAssert
from slow_mock_server import SlowMockServer, slow_text_then_end, slow_text_then_tooluse

WINDOWS = sys.platform == "win32"

# What Windows Terminal 1.24 sends for each key (measured), down and up.
_RECORDS = {
    "enter": ["13;28;13;1;32;1", "13;28;13;0;32;1"],
    "down": ["40;80;0;1;288;1", "40;80;0;0;288;1"],
    "esc": ["27;1;27;1;32;1", "27;1;27;0;32;1"],
    "ctrl_c": ["17;29;0;1;40;1", "67;46;3;1;40;1", "67;46;3;0;40;1", "17;29;0;0;32;1"],
}


def press(*keys):
    """Events pressing `keys`: key names (enter, down, esc, ctrl_c) or text.
    Records on Windows, VT bytes elsewhere."""
    events = []
    for key in keys:
        if not WINDOWS:
            events.append(f"key:{key}" if key in _RECORDS else f"type:{key}")
            continue
        if key in _RECORDS:
            records = _RECORDS[key]
        else:
            records = []
            for c in key:
                vk = ord(c.upper()) if c.isalnum() else 0
                records += [f"{vk};0;{ord(c)};1;32;1", f"{vk};0;{ord(c)};0;32;1"]
        events.append("raw:" + "".join(f"\\x1b[{r}_" for r in records))
        events.append("sleep:0.15")
    return events


def _tool_result(request_body):
    for message in json.loads(request_body)["messages"]:
        content = message.get("content")
        if isinstance(content, list):
            for block in content:
                if block.get("type") == "tool_result" and block.get("tool_use_id") == "t1":
                    return block
    return None


def _result_text(result):
    content = result.get("content")
    if isinstance(content, list):
        return "".join(part.get("text", "") for part in content if isinstance(part, dict))
    return str(content)


def _answer_dialog(bin_path, tool, tool_input, dialog_marker, answer):
    """One tool call whose dialog takes `answer`; the tool_result the next
    request carried (None if there was none) and the final screen. The
    session runs in a directory of its own: "Yes, always" keeps its rule in
    the project's `.claude/settings.local.json`."""
    turns = [
        slow_text_then_tooluse(n_chunks=1, delay=0.1, tool=tool, tool_input=tool_input),
        slow_text_then_end(n_chunks=1, delay=0.1),
    ]
    with SlowMockServer(turns) as srv:
        raw = run(
            bin_path,
            [READY, "type:go", "key:enter", wait_for(dialog_marker, 15), "strictsleep:0.5"]
            + answer + ["sleep:2.0"],
            base_url=srv.url,
            permission="default",
            cwd=case_tmpdir("cc-tty-records-project-"),
            startup_drain=0.8,
            per_key_drain=0.05,
        )
        requests = list(srv.requests)
    a = TTYAssert(raw)
    result = _tool_result(requests[1]) if len(requests) >= 2 else None
    return a, result


def _write_permission(bin_path, answer):
    target = os.path.join(case_tmpdir("cc-tty-records-perm-"), "answer.txt")
    a, result = _answer_dialog(
        bin_path, "Write", json.dumps({"file_path": target, "content": "x"}), "Permission required", answer)
    if result is None:
        a._fail("the permission dialog never answered: no tool_result reached the model")
    return a, result, os.path.exists(target)


def test_permission_dialog_reads_y_and_n_records(bin_path):
    a, result, written = _write_permission(bin_path, press("y"))
    if not written or result.get("is_error"):
        a._fail(f"y did not allow the write: tool_result={_result_text(result)!r}")
    a, result, written = _write_permission(bin_path, press("n"))
    if written:
        a._fail("n allowed the write")
    if not result.get("is_error") and "declined" not in _result_text(result):
        a._fail(f"n was not a refusal: tool_result={_result_text(result)!r}")


def test_permission_dialog_reads_arrow_enter_and_ctrl_c_records(bin_path):
    # Down then Enter: the second option, "Yes, always".
    a, result, written = _write_permission(bin_path, press("down", "enter"))
    if not written or result.get("is_error"):
        a._fail(f"Down, Enter did not allow the write: tool_result={_result_text(result)!r}")
    # Ctrl+C refuses, and the dialog closes instead of waiting for a key it can read.
    a, result, written = _write_permission(bin_path, press("ctrl_c"))
    if written:
        a._fail("Ctrl+C allowed the write")
    if not result.get("is_error") and "declined" not in _result_text(result):
        a._fail(f"Ctrl+C was not a refusal: tool_result={_result_text(result)!r}")


_QUESTION = json.dumps({
    "questions": [{
        "question": "Which colour?",
        "header": "Colour",
        "multiSelect": False,
        "options": [
            {"label": "Teal", "description": "the first"},
            {"label": "Amber", "description": "the second"},
        ],
    }],
})


def _answer_question(bin_path, answer):
    return _answer_dialog(bin_path, "AskUserQuestion", _QUESTION, "Which colour?", answer)


def test_question_dialog_reads_arrow_enter_and_digit_records(bin_path):
    for answer, label in ((press("down", "enter"), "Amber"), (press("2"), "Amber"), (press("enter"), "Teal")):
        a, result = _answer_question(bin_path, answer)
        if result is None:
            a._fail(f"{answer}: the question was never answered")
        text = _result_text(result)
        other = "Teal" if label == "Amber" else "Amber"
        if result.get("is_error") or label not in text or other in text:
            a._fail(f"{answer}: expected {label}, tool_result={text!r}")


def test_question_dialog_ctrl_c_record_cancels(bin_path):
    # The records' digits once picked option 1, and Ctrl+C's `_` was typed into "Type something".
    a, result = _answer_question(bin_path, press("ctrl_c"))
    text = _result_text(result) if result is not None else ""
    if "InputAborted" not in text or "Teal" in text or "Amber" in text:
        a._fail(f"Ctrl+C did not cancel the question: tool_result={text!r}")
