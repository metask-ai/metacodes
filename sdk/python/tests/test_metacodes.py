"""End-to-end tests of the Python package against the real AgentCore library.

The library comes from METACODES_AGENTCORE_LIB (or the other lookup paths in
metacodes.candidate_library_paths). Without one the suite skips, unless
METACODES_PY_SDK_REQUIRE_LIB=1, which CI sets so a missing library fails.
"""

from __future__ import annotations

import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

# METACODES_PY_SDK_TEST_INSTALLED=1 tests an installed wheel instead of src/.
if os.environ.get("METACODES_PY_SDK_TEST_INSTALLED") != "1":
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import metacodes  # noqa: E402
from metacodes import _native  # noqa: E402
from mock_provider import MockProvider  # noqa: E402


def _library_available() -> bool:
    return any(path.is_file() for path in metacodes.candidate_library_paths())


REQUIRE = os.environ.get("METACODES_PY_SDK_REQUIRE_LIB") == "1"
if not _library_available() and not REQUIRE:
    raise unittest.SkipTest("AgentCore shared library not found; set METACODES_AGENTCORE_LIB")


class PythonSdkTest(unittest.TestCase):
    def setUp(self) -> None:
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name).resolve()

    def session(self, runtime, provider, **options):
        options.setdefault("workspace", str(self.root))
        options.setdefault("api_key", "test-key")
        return runtime.session("mock-model", base_url=provider.base_url, **options)

    def test_discovery_validates_the_exact_revision(self) -> None:
        library = _native.load()
        self.assertEqual(library.api.abi_revision, metacodes.ABI_REVISION)
        self.assertEqual(library.api.struct_size, 80)

    def test_text_run_returns_final_answer_and_usage(self) -> None:
        events = []
        with MockProvider([("text", "hello from the mock")]) as provider:
            with metacodes.Runtime(tools=()) as runtime:
                session = self.session(runtime, provider)
                result = session.run("say hello", on_event=events.append)
        self.assertEqual(result.text, "hello from the mock")
        self.assertEqual(result.stop_reason, "end_turn")
        self.assertEqual(result.turns, 1)
        self.assertEqual(result.tool_calls, 0)
        self.assertEqual(result.usage["input_tokens"], 11)
        self.assertGreater(result.usage["output_tokens"], 0)
        tags = [next(iter(event)) for event in events]
        self.assertIn("text_chunk", tags)
        self.assertIn("output_segment_end", tags)
        self.assertEqual(result.segments[-1]["disposition"], "final")
        # The prompt reached the provider as the user's message.
        self.assertIn("say hello", str(provider.requests[0]["messages"]))

    def test_a_model_failure_reaches_the_result_and_a_later_success_clears_it(self) -> None:
        events = []
        failure = (
            "status",
            402,
            {"x-request-id": "req-py-1"},
            {"error": {"code": "insufficient_balance", "message": "Balance too low"}},
        )
        with MockProvider([failure, ("text", "fine now")]) as provider:
            with metacodes.Runtime(tools=()) as runtime:
                session = self.session(runtime, provider)
                failed = session.run("fails", on_event=events.append)
                recovered = session.run("succeeds")
        self.assertEqual(failed.stop_reason, "api_error")
        detail = failed.model_error
        self.assertIsInstance(detail, metacodes.ModelError)
        self.assertEqual(detail.category, "payment_required")
        self.assertEqual(detail.code, "insufficient_balance")
        self.assertEqual(detail.message, "Balance too low")
        self.assertEqual(detail.http_status, 402)
        self.assertEqual(detail.request_id, "req-py-1")
        self.assertEqual(detail.retry, "not_retryable")
        self.assertEqual(detail.attempts, 1)
        # It is an ordinary event too, before the terminal run_state.
        tags = [next(iter(event)) for event in events]
        self.assertEqual(tags.count("model_error"), 1)
        self.assertEqual(tags[-1], "run_state")
        self.assertLess(tags.index("model_error"), len(tags) - 1)
        self.assertEqual(recovered.stop_reason, "end_turn")
        self.assertIsNone(recovered.model_error)

    def test_python_tool_result_reaches_the_model(self) -> None:
        calls = []

        @metacodes.tool(
            description="Add two integers.",
            input_schema={
                "type": "object",
                "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}},
                "required": ["a", "b"],
            },
        )
        def add(arguments):
            calls.append((arguments, threading.current_thread().name))
            return str(arguments["a"] + arguments["b"])

        script = [("tool", "add", {"a": 2, "b": 3}), ("echo",)]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=(), host_tools=[add]) as runtime:
                session = self.session(runtime, provider, permission_mode="full_access")
                result = session.run("add 2 and 3")
        self.assertEqual([call[0] for call in calls], [{"a": 2, "b": 3}])
        self.assertEqual(result.text, "saw: 5")
        self.assertEqual(result.tool_calls, 1)
        advertised = [tool["name"] for tool in provider.requests[0].get("tools", [])]
        self.assertIn("add", advertised)

    def test_python_tool_exception_is_a_model_visible_error(self) -> None:
        @metacodes.tool(description="Always fails.")
        def broken(_arguments):
            raise ValueError("disk on fire")

        script = [("tool", "broken", {}), ("echo",)]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=(), host_tools=[broken]) as runtime:
                session = self.session(runtime, provider, permission_mode="full_access")
                result = session.run("try it")
        self.assertIn("disk on fire", result.text)
        self.assertEqual(result.stop_reason, "end_turn")

    def test_builtin_read_tool_reads_the_workspace(self) -> None:
        (self.root / "notes.txt").write_text("the secret is 42\n", encoding="utf-8")
        script = [("tool", "Read", {"file_path": "notes.txt"}), ("echo",)]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=["Read"]) as runtime:
                session = self.session(runtime, provider)
                result = session.run("read notes.txt")
        self.assertIn("the secret is 42", result.text)

    def test_runtime_points_rg_bin_at_the_bundled_ripgrep(self) -> None:
        library = _native.load()
        if library.ripgrep is None:
            self.skipTest("this library ships no ripgrep beside it")
        saved = os.environ.pop("RG_BIN", None)
        try:
            with metacodes.Runtime(tools=["Grep"]):
                self.assertEqual(os.environ.get("RG_BIN"), str(library.ripgrep))
        finally:
            if saved is None:
                os.environ.pop("RG_BIN", None)
            else:
                os.environ["RG_BIN"] = saved

    def test_builtin_grep_finds_text_in_the_workspace(self) -> None:
        (self.root / "src.txt").write_text("alpha\nneedle-7731\nomega\n", encoding="utf-8")
        script = [("tool", "Grep", {"pattern": "needle-[0-9]+", "output_mode": "content"}), ("echo",)]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=["Grep"]) as runtime:
                session = self.session(runtime, provider)
                result = session.run("find the needle")
        self.assertIn("needle-7731", result.text)

    def test_permission_request_reaches_the_handler_and_deny_holds(self) -> None:
        requests = []

        def on_ui_request(request):
            requests.append(request)
            return request.deny_once()

        target = self.root / "out.txt"
        script = [("tool", "Write", {"file_path": str(target), "content": "x"}), ("echo",)]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=["Write"]) as runtime:
                session = self.session(runtime, provider, on_ui_request=on_ui_request)
                result = session.run("write a file")
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0].kind, "permission")
        self.assertEqual(requests[0].data["tool"]["name"], "Write")
        self.assertFalse(target.exists())
        self.assertEqual(result.stop_reason, "end_turn")

    def test_permission_allow_lets_the_write_happen(self) -> None:
        target = self.root / "out.txt"
        script = [("tool", "Write", {"file_path": str(target), "content": "written"}), ("text", "done")]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=["Write"]) as runtime:
                session = self.session(
                    runtime, provider, on_ui_request=lambda request: request.allow_once()
                )
                result = session.run("write a file")
        self.assertEqual(target.read_text(encoding="utf-8"), "written")
        self.assertEqual(result.text, "done")

    def test_no_handler_means_the_write_is_not_allowed(self) -> None:
        target = self.root / "out.txt"
        script = [("tool", "Write", {"file_path": str(target), "content": "x"}), ("text", "ok")]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=["Write"]) as runtime:
                session = self.session(runtime, provider)
                session.run("write a file")
        self.assertFalse(target.exists())

    def test_stream_yields_events_then_result(self) -> None:
        with MockProvider([("text", "streamed")]) as provider:
            with metacodes.Runtime(tools=()) as runtime:
                session = self.session(runtime, provider)
                stream = session.stream("go")
                tags = [next(iter(event)) for event in stream]
        self.assertIn("text_chunk", tags)
        self.assertEqual(stream.result.text, "streamed")

    def test_listener_exception_is_raised_from_run_and_session_survives(self) -> None:
        def explode(_event):
            raise KeyError("listener bug")

        # The abort lands wherever the first event arrives, which may be before
        # the provider request; both script steps are the same so the second
        # Run's answer does not depend on that timing.
        with MockProvider([("text", "answer"), ("text", "answer")]) as provider:
            with metacodes.Runtime(tools=()) as runtime:
                session = self.session(runtime, provider)
                with self.assertRaises(KeyError):
                    session.run("one", on_event=explode)
                result = session.run("two")
        self.assertEqual(result.text, "answer")
        self.assertEqual(result.stop_reason, "end_turn")

    def test_shell_tool_requires_a_shell_policy(self) -> None:
        with MockProvider([]) as provider:
            with metacodes.Runtime(tools=["Bash"]) as runtime:
                with self.assertRaises(metacodes.AgentCoreError) as raised:
                    self.session(runtime, provider, tools=["Bash"], shell="disabled")
        self.assertEqual(raised.exception.status_name, "INVALID_ARGUMENT")

    def test_default_selection_drops_shell_tools_when_shell_is_disabled(self) -> None:
        with MockProvider([("text", "fine")]) as provider:
            with metacodes.Runtime(tools=["Read", "Bash"]) as runtime:
                session = self.session(runtime, provider)
                session.run("hi")
        advertised = [tool["name"] for tool in provider.requests[0].get("tools", [])]
        self.assertIn("Read", advertised)
        self.assertNotIn("Bash", advertised)

    def test_describe_reports_the_model(self) -> None:
        with MockProvider([]) as provider:
            with metacodes.Runtime(tools=()) as runtime:
                session = self.session(runtime, provider)
                description = session.describe()
                session.set_model("mock-model-2")
                self.assertIn("mock-model-2", str(session.describe()))
        self.assertIn("mock-model", str(description))

    # -- Session lifecycle -------------------------------------------------

    def blocking_tool(self, name="wait"):
        """A host tool that signals `started` and holds its Run until `release`."""
        started, release = threading.Event(), threading.Event()

        @metacodes.tool(name=name, description="Waits for the test.")
        def wait(_arguments):
            started.set()
            release.wait(10)
            return "waited"

        return wait, started, release

    def test_leaving_a_stream_early_aborts_the_run_and_closes(self) -> None:
        # `with session: for event in stream: break` leaves the Run going
        # while __exit__ closes the Session: close() aborts it, waits for it
        # and destroys the Session, instead of failing BUSY and dropping the
        # handle (which leaked the Session and made abort() a no-op).
        @metacodes.tool(description="Takes a moment.")
        def slow(_arguments):
            time.sleep(0.3)
            return "slow done"

        script = [("tool", "slow", {}), ("echo",)]
        with MockProvider(script) as provider:
            runtime = metacodes.Runtime(tools=(), host_tools=[slow])
            with self.session(runtime, provider, permission_mode="full_access") as session:
                stream = session.stream("go")
                for _event in stream:
                    break  # the Run's first event: it is still going
            self.assertFalse(session._handle)
            self.assertNotIn(session, runtime._sessions)
            runtime.close()
            self.assertFalse(runtime._handle)
            stream._thread.join(5)
        # The Run was stopped, not finished: it never sent the request that
        # would follow the tool's.
        self.assertEqual(stream.result.stop_reason, "aborted")
        self.assertLessEqual(len(provider.requests), 1)

    def test_close_from_a_callback_is_refused_and_the_session_survives(self) -> None:
        refused = []

        def listener(_event):
            if not refused:
                try:
                    session.close()
                except RuntimeError as error:
                    refused.append(error)

        with MockProvider([("text", "one"), ("text", "two")]) as provider:
            with metacodes.Runtime(tools=()) as runtime:
                session = self.session(runtime, provider)
                self.assertEqual(session.run("first", on_event=listener).text, "one")
                self.assertEqual(len(refused), 1)
                self.assertTrue(session._handle)
                self.assertEqual(session.run("second").text, "two")

    def test_a_tool_can_open_and_close_another_session(self) -> None:
        # Only a Session's own callbacks may not close it; a child Session a
        # tool opens and closes is fine.
        box = {}

        @metacodes.tool(description="Asks a child session.")
        def delegate(_arguments):
            with self.session(box["runtime"], box["provider"]) as child:
                return "child said: " + child.run("sub task").text

        script = [("tool", "delegate", {}), ("text", "child answer"), ("echo",)]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=(), host_tools=[delegate]) as runtime:
                box.update(runtime=runtime, provider=provider)
                session = self.session(runtime, provider, permission_mode="full_access")
                result = session.run("delegate it")
                self.assertEqual(runtime._sessions, [session])
        self.assertEqual(result.text, "saw: child said: child answer")

    def test_a_run_from_a_small_stack_thread_nests_a_child_run(self) -> None:
        # The Run, and the child Run its tool starts, each get their own
        # RUN_STACK_BYTES thread, whatever stack the caller's thread has.
        box = {}

        @metacodes.tool(description="Asks a child session.")
        def delegate(_arguments):
            with self.session(box["runtime"], box["provider"]) as child:
                return "child said: " + child.run("sub task").text

        script = [("tool", "delegate", {}), ("text", "child answer"), ("echo",)]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=(), host_tools=[delegate]) as runtime:
                box.update(runtime=runtime, provider=provider)
                session = self.session(runtime, provider, permission_mode="full_access")
                previous = threading.stack_size(512 * 1024)
                try:
                    caller = threading.Thread(target=lambda: box.update(result=session.run("delegate it")))
                    caller.start()
                finally:
                    threading.stack_size(previous)
                caller.join(30)
        self.assertEqual(box["result"].text, "saw: child said: child answer")

    def test_a_child_runs_callbacks_cannot_close_the_parent_session(self) -> None:
        # The child's Run executes inside the parent's tool, on a thread of
        # its own: closing the parent from the child's callbacks is refused,
        # as from the parent's, and leaves the parent's Run alone. Closing an
        # unrelated Session there works.
        box = {}
        outcomes = []

        def close_parent_then_other(_event):
            if outcomes:
                return
            try:
                box["parent"].close(timeout=2)
                outcomes.append("parent closed")
            except RuntimeError:
                outcomes.append("parent refused")
            except TimeoutError:  # not refused: it aborted the parent's Run and waited
                outcomes.append("parent waited")
            box["other"].close(timeout=2)
            outcomes.append("other closed")

        @metacodes.tool(description="Asks a child session.")
        def delegate(_arguments):
            with self.session(box["runtime"], box["provider"]) as child:
                return "child said: " + child.run("sub task", on_event=close_parent_then_other).text

        script = [("tool", "delegate", {}), ("text", "child answer"), ("echo",)]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=(), host_tools=[delegate]) as runtime:
                box.update(runtime=runtime, provider=provider)
                session = self.session(runtime, provider, permission_mode="full_access")
                other = self.session(runtime, provider)
                box.update(parent=session, other=other)
                result = session.run("delegate it")
                self.assertEqual(outcomes, ["parent refused", "other closed"])
                self.assertTrue(session._handle)
                self.assertFalse(other._handle)
        self.assertEqual(result.stop_reason, "end_turn")
        self.assertEqual(result.text, "saw: child said: child answer")

    def test_close_with_a_timeout_leaves_a_blocked_run_open(self) -> None:
        wait, started, release = self.blocking_tool()
        with MockProvider([("tool", "wait", {}), ("text", "done")]) as provider:
            with metacodes.Runtime(tools=(), host_tools=[wait]) as runtime:
                session = self.session(runtime, provider, permission_mode="full_access")
                thread, box = self.run_in_background(session, "start")
                self.assertTrue(started.wait(10))
                with self.assertRaises(TimeoutError):
                    session.close(timeout=0.2)
                self.assertTrue(session._handle)
                self.assertIn(session, runtime._sessions)
                release.set()
                thread.join(10)
                session.close()
                self.assertFalse(session._handle)
        self.assertNotIn("error", box)
        self.assertEqual(box["result"].stop_reason, "aborted")

    def run_in_background(self, session, prompt):
        box = {}

        def work():
            try:
                box["result"] = session.run(prompt)
            except BaseException as error:  # surfaced by the test
                box["error"] = error

        thread = threading.Thread(target=work)
        thread.start()
        return thread, box

    def test_submit_hands_the_active_run_more_input(self) -> None:
        wait, started, release = self.blocking_tool()
        with MockProvider([("tool", "wait", {}), ("text", "done")]) as provider:
            with metacodes.Runtime(tools=(), host_tools=[wait]) as runtime:
                session = self.session(runtime, provider, permission_mode="full_access")
                thread, box = self.run_in_background(session, "start")
                self.assertTrue(started.wait(10))
                session.submit("and mention the weather")
                release.set()
                thread.join(10)
        self.assertNotIn("error", box)
        result = box["result"]
        self.assertEqual((result.input_accepted, result.input_adopted), (1, 1))
        self.assertIn("and mention the weather", str(provider.requests[1]["messages"]))

    def test_update_credential_from_a_tool_changes_the_next_request(self) -> None:
        @metacodes.tool(
            description="Rotate the provider key.",
            input_schema={"type": "object", "properties": {}, "required": []},
        )
        def rotate(_arguments):
            session.update_credential("rotated-key")
            return "rotated"

        script = [("tool", "rotate", {}), ("text", "done"), ("text", "again")]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=(), host_tools=[rotate]) as runtime:
                session = self.session(runtime, provider, permission_mode="full_access", api_key="first-key")
                result = session.run("rotate the key")
                with self.assertRaises(metacodes.AgentCoreError) as refused:
                    session.update_credential("bad key")
                session.run("once more")
                session.close()
                with self.assertRaises(RuntimeError):
                    session.update_credential("after-close")
        self.assertEqual(result.text, "done")
        self.assertEqual(refused.exception.status_name, "INVALID_ARGUMENT")
        self.assertNotIn("bad key", str(refused.exception))
        # The Run's first request used the creation key; the turn after the
        # tool, and the next Run after the refused update, the rotated one.
        self.assertEqual(
            provider.authorizations, ["Bearer first-key", "Bearer rotated-key", "Bearer rotated-key"]
        )

    def interrupting_join(self, started, interrupts):
        """A _RunThread._join that raises KeyboardInterrupt, as Ctrl+C does
        out of a join, on its first ``interrupts`` calls once the Run is
        inside its tool, and joins for real after that."""
        from metacodes import _client

        real_join = _client._RunThread._join
        calls = []

        def join(run_thread):
            calls.append(run_thread)
            if len(calls) <= interrupts:
                self.assertTrue(started.wait(10))
                raise KeyboardInterrupt
            return real_join(run_thread)

        return mock.patch.object(_client._RunThread, "_join", join), calls

    def test_an_interrupted_wait_aborts_the_run_and_waits_for_it(self) -> None:
        # Ctrl+C while run() waits for its Run thread: the Run is aborted and
        # waited for before the interrupt propagates, so the Session is idle
        # and the next Run works.
        wait, started, release = self.blocking_tool()
        patch, joins = self.interrupting_join(started, interrupts=1)
        with MockProvider([("tool", "wait", {}), ("text", "after")]) as provider:
            with metacodes.Runtime(tools=(), host_tools=[wait]) as runtime:
                session = self.session(runtime, provider, permission_mode="full_access")
                real_abort = session._abort_active

                def abort_then_release():
                    real_abort()
                    release.set()  # the tool returns once the abort is requested

                session._abort_active = abort_then_release
                with patch:
                    with self.assertRaises(KeyboardInterrupt):
                        session.run("start")
                self.assertEqual(session._active_run_id, 0)
                after = session.run("again")
                session.close()
        self.assertEqual(len(joins), 2)
        # The interrupted Run stopped after its tool: one request, then the next Run's.
        self.assertEqual(len(provider.requests), 2)
        self.assertEqual(after.text, "after")

    def test_a_second_interrupt_leaves_the_session_busy_until_the_run_ends(self) -> None:
        # A second Ctrl+C stops the wait while the Run is still in its tool.
        # The Session stays busy, abort still reaches the Run, and close()
        # aborts and waits for it instead of failing BUSY.
        wait, started, release = self.blocking_tool()
        patch, joins = self.interrupting_join(started, interrupts=2)
        with MockProvider([("tool", "wait", {}), ("text", "never asked")]) as provider:
            with metacodes.Runtime(tools=(), host_tools=[wait]) as runtime:
                session = self.session(runtime, provider, permission_mode="full_access")
                with patch:
                    with self.assertRaises(KeyboardInterrupt):
                        session.run("start")
                self.assertNotEqual(session._active_run_id, 0)
                with self.assertRaises(RuntimeError):
                    session.run("too soon")
                release.set()
                session.close()
                self.assertFalse(session._handle)
        self.assertEqual(len(joins), 2)
        self.assertEqual(len(provider.requests), 1)

    def test_abort_stops_the_active_run(self) -> None:
        wait, started, release = self.blocking_tool()
        with MockProvider([("tool", "wait", {}), ("text", "never asked")]) as provider:
            with metacodes.Runtime(tools=(), host_tools=[wait]) as runtime:
                session = self.session(runtime, provider, permission_mode="full_access")
                thread, box = self.run_in_background(session, "start")
                self.assertTrue(started.wait(10))
                session.abort()
                release.set()
                thread.join(10)
        self.assertNotIn("error", box)
        self.assertEqual(box["result"].stop_reason, "aborted")
        self.assertEqual(len(provider.requests), 1)

    # -- Permissions -------------------------------------------------------

    def write_script(self, *names):
        return [("tool", "Write", {"file_path": str(self.root / name), "content": name}) for name in names] + [
            ("text", "done")
        ]

    def test_allow_and_deny_rules_decide_without_asking(self) -> None:
        asked = []

        def on_ui_request(request):
            asked.append(request)
            return request.allow_once()

        with MockProvider(self.write_script("denied.txt")) as provider:
            with metacodes.Runtime(tools=["Write"]) as runtime:
                session = self.session(runtime, provider, deny=["Write"], on_ui_request=on_ui_request)
                session.run("write")
        self.assertFalse((self.root / "denied.txt").exists())
        with MockProvider(self.write_script("allowed.txt")) as provider:
            with metacodes.Runtime(tools=["Write"]) as runtime:
                session = self.session(runtime, provider, allow=["Write"], on_ui_request=on_ui_request)
                session.run("write")
        self.assertTrue((self.root / "allowed.txt").exists())
        self.assertEqual(asked, [])

    def test_set_permission_mode_applies_to_the_next_run(self) -> None:
        with MockProvider(self.write_script("first.txt") + self.write_script("second.txt")) as provider:
            with metacodes.Runtime(tools=["Write"]) as runtime:
                session = self.session(runtime, provider)
                session.run("write one")
                session.set_permission_mode("full_access")
                session.run("write two")
        self.assertFalse((self.root / "first.txt").exists())
        self.assertTrue((self.root / "second.txt").exists())

    def test_allow_session_is_asked_once_per_target(self) -> None:
        # The session-scoped candidate is the file target: writing a.txt
        # again is not asked, a new file is.
        asked = []

        def on_ui_request(request):
            asked.append(request.data["candidate"]["target"])
            return request.allow_session()

        with MockProvider(self.write_script("a.txt", "a.txt", "b.txt")) as provider:
            with metacodes.Runtime(tools=["Write"]) as runtime:
                session = self.session(runtime, provider, on_ui_request=on_ui_request)
                session.run("write three times")
        # AgentCore names Windows paths with forward slashes; compare as paths.
        self.assertEqual([Path(target) for target in asked], [self.root / "a.txt", self.root / "b.txt"])
        self.assertTrue((self.root / "a.txt").exists())
        self.assertTrue((self.root / "b.txt").exists())

    def test_an_ask_question_answer_reaches_the_model(self) -> None:
        asked = []
        question = {
            "question": "Which colour?",
            "header": "Colour",
            "options": [{"label": "Red", "description": "warm"}, {"label": "Blue", "description": "cool"}],
            "multiSelect": False,
        }

        def on_ui_request(request):
            asked.append(request)
            return request.answer(["Blue"])

        script = [("tool", "AskUserQuestion", {"questions": [question]}), ("echo",)]
        with MockProvider(script) as provider:
            with metacodes.Runtime(tools=["AskUserQuestion"]) as runtime:
                session = self.session(runtime, provider, on_ui_request=on_ui_request)
                result = session.run("ask me")
        self.assertEqual([request.kind for request in asked], ["ask_question"])
        self.assertIn("Blue", result.text)

    # -- Providers ---------------------------------------------------------

    def test_the_openai_provider_speaks_chat_completions(self) -> None:
        with MockProvider([("text", "hello over chat completions")]) as provider:
            with metacodes.Runtime(tools=()) as runtime:
                session = runtime.session(
                    "mock-model", provider="openai", base_url=provider.openai_url,
                    api_key="test-key", workspace=str(self.root),
                )
                result = session.run("say hello")
        self.assertEqual(result.text, "hello over chat completions")
        self.assertEqual(result.stop_reason, "end_turn")
        self.assertIn("say hello", str(provider.requests[0]["messages"]))

    def test_unknown_builtin_tool_is_rejected_before_loading(self) -> None:
        with self.assertRaises(ValueError):
            metacodes.Runtime(tools=["Telepathy"])

    def test_missing_library_path_is_reported(self) -> None:
        with self.assertRaises(FileNotFoundError):
            _native.load("/nonexistent/libmetask_agentcore.so")


if __name__ == "__main__":
    unittest.main()
