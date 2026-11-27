"""#330: the turn phase owns every widget it opens.

A reply and the read after it share one fixed region. Before #298 an agent list
left open by a reply swallowed the next prompt's typing; #298 reset a list of
fields at every boundary, and #330 moved that state into the phase's payload,
which a phase change replaces wholesale. These cases drive the real binary
through the reply -> read boundary with widgets open and assert the next prompt
starts clean. Offline: the reply comes from the local slow mock server.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import READY, WAIT_S, run, submit, wait_for  # noqa: E402
from asserts import TTYAssert  # noqa: E402

# The idle footer once fake agents exist (drawFooter appends the switcher entry).
IDLE_WITH_AGENTS = f"waitline:⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents:{WAIT_S}"
IDLE = f"waitline:⏵⏵ bypass permissions on (shift+tab to cycle):{WAIT_S}"


def _screen_text(raw, rows, cols):
    a = TTYAssert(raw, rows=rows, cols=cols)
    return a, "\n".join(a.final.line_text(r) for r in range(a.final.rows))


def _frame_text(sc):
    return "\n".join(sc.line_text(r) for r in range(sc.rows))


def _box_lines(frame):
    """The prompt rows of a frame (`❯ …`), trimmed."""
    return [line.strip() for line in frame.split("\n") if line.startswith("❯ ")]


def test_agent_list_opened_in_a_reply_does_not_swallow_the_next_prompt(bin_path):
    from slow_mock_server import SlowMockServer, slow_text_then_end

    rows, cols = 34, 100
    with SlowMockServer([slow_text_then_end(n_chunks=10, delay=0.3)]) as srv:
        raw = run(
            bin_path,
            submit("/agent-test-multi", "Running 2 Explore agents")
            + [READY, "type:go", "key:enter", wait_for("esc to interrupt"),
               # `↓ to manage`: the reply's own switcher, opened mid-stream.
               "key:down", wait_for("↑/↓ to select"),
               # The reply ends with the list still open; the idle footer is the
               # sign the next read has its own region.
               "sleep:10", IDLE_WITH_AGENTS,
               "type:hello", wait_for("❯ hello")],
            term_size=(rows, cols),
            base_url=srv.url,
            startup_drain=0.8,
            per_key_drain=0.08,
        )
    a, text = _screen_text(raw, rows, cols)
    opened = [sc for sc in a.frame_screens
              if "↑/↓ to select" in _frame_text(sc) and "esc to interrupt" in _frame_text(sc)]
    assert opened, "the reply never showed its agent list; the case did not reach the boundary:\n" + text
    assert "❯ hello" in text, "the next prompt's typing was swallowed (#298):\n" + text
    assert "↑/↓ to select" not in text, "the reply's agent list reached the next prompt:\n" + text


def test_help_opened_in_a_reply_is_closed_at_the_next_prompt(bin_path):
    from slow_mock_server import SlowMockServer, slow_text_then_end

    rows, cols = 24, 80
    with SlowMockServer([slow_text_then_end(n_chunks=10, delay=0.3)]) as srv:
        raw = run(
            bin_path,
            [READY, "type:go", "key:enter", wait_for("esc to interrupt"),
             "type:?", wait_for("ctrl + o to choose a model"),
             # A help panel left open would replace this footer line, so the
             # wait itself fails if the reply's help reached the prompt.
             "sleep:10", IDLE],
            term_size=(rows, cols),
            base_url=srv.url,
            startup_drain=0.8,
            per_key_drain=0.08,
        )
    a, text = _screen_text(raw, rows, cols)
    # The help panel takes the footer line (where `esc to interrupt` lives), so
    # a frame showing it is the reply's: `?` is typed only after the reply began.
    shown = [sc for sc in a.frame_screens if "ctrl + o to choose a model" in _frame_text(sc)]
    assert shown, "help never opened during the reply; the case did not reach the boundary:\n" + text
    assert "tok9" in text, "the reply has not finished; wrong moment:\n" + text
    assert "ctrl + o to choose a model" not in text, "the reply's help reached the next prompt:\n" + text


def test_reply_draft_survives_a_permission_dialog(bin_path):
    # A permission dialog stops the keyboard watcher and starts a new one when
    # it closes, while the reply (the generating phase) goes on. The draft is
    # the reply's, not the watcher's: after the dialog the box still shows it,
    # the next key extends it, and Enter queues all of it.
    import json
    from tty_driver import case_tmpdir
    from slow_mock_server import SlowMockServer, slow_text_then_tooluse, slow_text_then_end, simple_text

    target = os.path.join(case_tmpdir("cc-tty-draft-perm-"), "draft.txt")
    turns = [
        # Long enough that the draft is typed before the tool asks.
        slow_text_then_tooluse(n_chunks=16, delay=0.4, tool="Write",
                               tool_input=json.dumps({"file_path": target, "content": "x"})),
        slow_text_then_end(n_chunks=12, delay=0.3),
        simple_text("queued draft answered"),
    ]
    with SlowMockServer(turns) as srv:
        raw = run(
            bin_path,
            [READY, "type:go", "key:enter", wait_for("esc to interrupt"),
             "type:keep me", wait_for("❯ keep me"),
             wait_for("Permission required", 20), "strictsleep:0.5", "type:y",
             # The dialog erased the region; the box drawn again after it is the signal.
             wait_for("❯ keep me", 20),
             "type:!", wait_for("❯ keep me!", 10), "key:enter",
             wait_for("queued draft answered", 30), "sleep:2"],
            term_size=(24, 80),
            base_url=srv.url,
            permission="default",
            startup_drain=0.8,
            per_key_drain=0.08,
        )
        requests = list(srv.requests)
    a, text = _screen_text(raw, 24, 80)
    frames = [_frame_text(sc) for sc in a.frame_screens]
    asked = [i for i, f in enumerate(frames) if "Permission required" in f]
    assert asked, "the permission dialog never opened; the case did not reach the boundary:\n" + text
    before = frames[:asked[0]]
    assert any("❯ keep me" in _box_lines(f) for f in before), "the draft was not typed before the dialog:\n" + text
    # The dialog stays in the scrollback, so "after" is every later frame that
    # shows the reply's region again.
    after = [f for f in frames[asked[0] + 1:] if "esc to interrupt" in f]
    assert any("❯ keep me" in _box_lines(f) for f in after), \
        "after the dialog the box lost the draft (or showed stale bytes):\n" + text
    assert any("❯ keep me!" in _box_lines(f) for f in after), "the next key did not extend the draft:\n" + text
    assert os.path.exists(target), "the dialog's 'y' did not reach the tool"
    queued = [m for body in requests[2:] for m in json.loads(body)["messages"] if m.get("role") == "user"]
    sent = json.dumps(queued)
    assert "keep me!" in sent, f"Enter after the dialog did not queue the whole draft: {sent[-300:]}"
