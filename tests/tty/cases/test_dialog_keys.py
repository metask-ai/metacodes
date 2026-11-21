import json
import os

from tty_driver import READY, case_tmpdir, run, wait_for
from asserts import TTYAssert
from slow_mock_server import SlowMockServer, slow_text_then_end, slow_text_then_tooluse

CSI_U_ESC = "raw:\\x1b[27u"
CSI_U_CTRL_C = "raw:\\x1b[99;5u"
CAPS_LOCK_DOWN = "raw:\\x1b[1;65B"

QUESTION = json.dumps({
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


def _answer_dialog(bin_path, tool, tool_input, marker, keys):
    turns = [
        slow_text_then_tooluse(n_chunks=1, delay=0.1, tool=tool, tool_input=tool_input),
        slow_text_then_end(n_chunks=1, delay=0.1),
    ]
    with SlowMockServer(turns) as srv:
        raw = run(
            bin_path,
            [READY, "type:go", "key:enter", wait_for(marker, 15), "strictsleep:0.5"] + keys + ["sleep:2.5"],
            base_url=srv.url,
            permission="default",
            cwd=case_tmpdir("cc-tty-dialog-keys-project-"),
            startup_drain=0.8,
            per_key_drain=0.05,
        )
        requests = list(srv.requests)
    a = TTYAssert(raw)
    if marker.encode() not in raw:
        a._fail(f"the dialog never showed {marker!r}")
    result = _tool_result(requests[1]) if len(requests) >= 2 else None
    return a, result


def _write(bin_path, keys):
    target = os.path.join(case_tmpdir("cc-tty-dialog-keys-write-"), "answer.txt")
    a, result = _answer_dialog(
        bin_path, "Write", json.dumps({"file_path": target, "content": "x"}), "Permission required", keys)
    if result is None:
        a._fail(f"{keys}: the permission dialog never answered, no tool_result reached the model")
    return a, result, os.path.exists(target)


def _expect_refused(bin_path, keys):
    a, result, written = _write(bin_path, keys)
    text = _result_text(result)
    if written or not result.get("is_error") or "declined" not in text:
        a._fail(f"{keys}: expected the write refused, written={written} tool_result={text!r}")


def _question(bin_path, keys):
    a, result = _answer_dialog(bin_path, "AskUserQuestion", QUESTION, "Which colour?", keys)
    if result is None:
        a._fail(f"{keys}: the question dialog never closed, no tool_result reached the model")
    return a, _result_text(result)


def _expect_cancelled(bin_path, keys):
    a, text = _question(bin_path, keys)
    if "InputAborted" not in text or "Teal" in text or "Amber" in text:
        a._fail(f"{keys}: expected the question cancelled, tool_result={text!r}")


def _expect_answer(bin_path, keys, answer):
    a, text = _question(bin_path, keys)
    if json.loads(text) != {"answers": [answer]}:
        a._fail(f"{keys}: expected the answer {answer!r}, tool_result={text!r}")


def test_permission_dialog_refuses_on_ctrl_c_sent_as_csi_u(bin_path):
    _expect_refused(bin_path, [CSI_U_CTRL_C])


def test_permission_dialog_down_down_enter_still_picks_no(bin_path):
    _expect_refused(bin_path, ["key:down", "key:down", "key:enter"])


def test_permission_dialog_down_down_enter_with_caps_lock_on_picks_no(bin_path):
    _expect_refused(bin_path, [CAPS_LOCK_DOWN, CAPS_LOCK_DOWN, "key:enter"])


def test_permission_dialog_does_not_answer_from_pasted_text(bin_path):
    _expect_refused(bin_path, ["raw:\\x1b[200~yes\\x1b[201~", "strictsleep:0.6", "type:n"])


def test_question_dialog_cancels_on_esc_sent_as_csi_u(bin_path):
    _expect_cancelled(bin_path, [CSI_U_ESC])


def test_question_dialog_cancels_on_ctrl_c_sent_as_csi_u(bin_path):
    _expect_cancelled(bin_path, [CSI_U_CTRL_C])


def test_question_dialog_down_enter_still_picks_the_second_option(bin_path):
    _expect_answer(bin_path, ["key:down", "key:enter"], "Amber")


def test_question_dialog_down_enter_with_caps_lock_on_picks_the_second_option(bin_path):
    _expect_answer(bin_path, [CAPS_LOCK_DOWN, "key:enter"], "Amber")


def test_question_dialog_keeps_every_character_written_to_other_at_once(bin_path):
    _expect_answer(bin_path, ["key:down", "key:down", "raw:abc", "key:enter"], "abc")


def test_question_dialog_takes_a_paste_into_other_with_its_line_breaks_as_spaces(bin_path):
    _expect_answer(bin_path, ["key:down", "key:down", "raw:\\x1b[200~ab\\rcd\\x1b[201~", "key:enter"], "ab cd")


def test_question_dialog_does_not_pick_an_option_from_pasted_text(bin_path):
    _expect_answer(bin_path, ["raw:\\x1b[200~2\\x1b[201~", "strictsleep:0.6", "key:enter"], "Teal")
