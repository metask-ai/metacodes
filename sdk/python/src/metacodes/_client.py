"""High-level Python API over the AgentCore C ABI."""

from __future__ import annotations

import ctypes
import json
import os
import queue
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Optional, Sequence

from . import _native as n

DEFAULT_TOOLS = ("Read", "Glob", "Grep")
# The CLI agent loop's own default (src/core/agent_loop.zig Options.max_turns).
DEFAULT_MAX_TURNS = 400

# The AgentCore handles of the Sessions whose callbacks (event, UI request,
# host tool) are running on this thread. close() waits for the Session's
# active Run to return, which a callback of that Run would wait for in turn,
# so it refuses there instead of deadlocking. Closing any other Session from
# a callback (a tool that opens and closes a child Session) is fine. A Run's
# thread starts with the marks of the thread that started it: a child Run that
# a tool starts runs inside that tool's callback, so its callbacks cannot
# close the parent Session either.
_CALLBACK = threading.local()


class _InCallback:
    def __init__(self, handle: Optional[int]) -> None:
        self._handle = handle

    def __enter__(self) -> None:
        if not hasattr(_CALLBACK, "handles"):
            _CALLBACK.handles = []
        _CALLBACK.handles.append(self._handle)

    def __exit__(self, *_: Any) -> None:
        _CALLBACK.handles.pop()


def _in_callback_of(handle: Optional[int]) -> bool:
    return handle is not None and handle in getattr(_CALLBACK, "handles", ())


# The stack each Run executes on, the size the Node addon gives its Run
# threads. A Run needs more than some callers' threads have: on Windows the
# main thread of python.exe reserves 2 MB, and a Run that a host tool starts
# from inside another Run (a child Session) overflowed it. The overflow was a
# structured exception ctypes turned into OSError, leaving the child Session's
# Run unfinished, so it could not be closed. Each Run getting its own thread
# also makes nesting depth independent of the caller's stack.
RUN_STACK_BYTES = 8 * 1024 * 1024
# threading.stack_size() is process-wide and read when a thread starts, so it
# is set and restored around one start() under this lock. A thread that other
# code starts inside that window also gets RUN_STACK_BYTES; that is harmless.
_RUN_THREAD_START = threading.Lock()


class _RunThread:
    """One Run's native call on its own thread with ``RUN_STACK_BYTES`` of
    stack, and who closes the Run when it returns.

    The thread is not a daemon: the native call always runs to its end, as it
    did when it ran on the caller's thread, and the interpreter waits for it
    at exit. The caller waits with ``wait``. If that wait is interrupted
    (Ctrl+C raises KeyboardInterrupt out of the join), ``wait`` asks the Run to
    abort and waits for it to end before re-raising, so the Session never
    reports idle while its Run goes on. If the second wait is interrupted too,
    the Run's own thread closes the Run when the native call returns: until
    then the Session stays busy, ``abort()`` still reaches the Run, and
    ``close()`` aborts and waits for it.
    """

    def __init__(self, call: Callable[[], int], close_interrupted: Callable[[], None], keep: Any) -> None:
        self._call = call
        # The buffers the native call borrows (the prompt's arena, the option
        # and result structs): alive until the call returns, also when the
        # caller stopped waiting for it.
        self._keep = keep
        # Closes the Run when the caller stopped waiting for its result.
        self._close_interrupted = close_interrupted
        self._lock = threading.Lock()
        self._returned = False
        self._abandoned = False
        self.status: Optional[int] = None
        self.error: Optional[BaseException] = None
        # The callbacks the caller is inside, as when the Run executed on its
        # thread (a copy: each thread pushes and pops its own list).
        self._callbacks = list(getattr(_CALLBACK, "handles", ()))
        self._thread = threading.Thread(target=self._run, name="metacodes-run")

    def start(self) -> None:
        with _RUN_THREAD_START:
            previous = threading.stack_size(RUN_STACK_BYTES)
            try:
                self._thread.start()
            finally:
                threading.stack_size(previous)

    def _run(self) -> None:
        _CALLBACK.handles = self._callbacks
        try:
            self.status = self._call()
        except BaseException as error:  # the caller reports it
            self.error = error
        finally:
            with self._lock:
                self._returned = True
                abandoned = self._abandoned
            if abandoned:
                self._close_interrupted()

    def _join(self) -> None:
        self._thread.join()

    def wait(self, abort: Callable[[], None]) -> None:
        """Return once the native call has returned. On an interrupt, abort,
        wait again, close the Run and re-raise; on a second interrupt, leave
        closing to the Run's thread and re-raise."""
        try:
            self._join()
            return
        except BaseException:
            abort()
            try:
                self._join()
            except BaseException:
                with self._lock:
                    self._abandoned = not self._returned
                    abandoned = self._abandoned
                if not abandoned:
                    self._close_interrupted()
                raise
            self._close_interrupted()
            raise


SHELL_TOOLS = ("Bash", "BashOutput", "KillShell")
_API_KEY_ENV = {
    "anthropic": ("ANTHROPIC_API_KEY",),
    "openai": ("OPENAI_API_KEY",),
    "gemini": ("GEMINI_API_KEY", "GOOGLE_API_KEY"),
}


@dataclass
class Tool:
    """A tool the embedding program implements in Python.

    ``handler`` receives the parsed arguments and returns the result the model
    sees: a ``str``, or any JSON-serialisable value. Raising an exception
    returns its message to the model as an ordinary tool error.
    """

    name: str
    description: str
    handler: Callable[[Dict[str, Any]], Any]
    input_schema: Dict[str, Any] = field(
        default_factory=lambda: {"type": "object", "properties": {}}
    )


def tool(
    name: Optional[str] = None,
    description: Optional[str] = None,
    input_schema: Optional[Dict[str, Any]] = None,
) -> Callable[[Callable[[Dict[str, Any]], Any]], Tool]:
    """Decorator form of :class:`Tool`; the docstring is the default description."""

    def wrap(function: Callable[[Dict[str, Any]], Any]) -> Tool:
        return Tool(
            name=name or function.__name__,
            description=description or (function.__doc__ or "").strip() or function.__name__,
            handler=function,
            input_schema=input_schema or {"type": "object", "properties": {}},
        )

    return wrap


@dataclass
class UiRequest:
    """A request the agent needs answered: a permission or a question."""

    kind: str
    data: Dict[str, Any]

    def _permission(self, choice: str) -> Dict[str, Any]:
        if self.kind != "permission":
            raise ValueError("not a permission request")
        response: Dict[str, Any] = {
            "permission": choice,
            "request_id": self.data["request_id"],
            "policy_generation": self.data["policy_generation"],
        }
        if choice.endswith("_session"):
            candidate = self.data.get("candidate")
            if not candidate:
                raise ValueError("this request offers no session-scoped answer")
            response["rule_id"] = candidate["rule_id"]
        return response

    def allow_once(self) -> Dict[str, Any]:
        return self._permission("allow_once")

    def allow_session(self) -> Dict[str, Any]:
        return self._permission("allow_session")

    def deny_once(self) -> Dict[str, Any]:
        return self._permission("deny_once")

    def deny_session(self) -> Dict[str, Any]:
        return self._permission("deny_session")

    def answer(self, *values: Sequence[str]) -> Dict[str, Any]:
        """Answer an ask_question request: one list of chosen labels per question."""
        if self.kind != "ask_question":
            raise ValueError("not a question request")
        return {"answers": [{"values": list(chosen)} for chosen in values]}


@dataclass
class ModelError:
    """Why a Run stopped with ``stop_reason == "api_error"``.

    ``code`` is the upstream's identifier exactly as sent; the SDK attaches no
    meaning to it. ``message`` is safe to display: redacted and bounded.
    ``retry`` is ``"retryable"``, ``"not_retryable"`` or ``"unknown"``.
    """

    category: str
    message: str
    retry: str
    attempts: int
    code: Optional[str] = None
    type: Optional[str] = None
    http_status: Optional[int] = None
    request_id: Optional[str] = None
    retry_after_ms: Optional[int] = None
    truncated: bool = False


@dataclass
class RunResult:
    text: str
    stop_reason: str
    turns: int
    tool_calls: int
    usage: Dict[str, int]
    segments: List[Dict[str, Any]]
    input_accepted: int = 0
    input_adopted: int = 0
    model_error: Optional[ModelError] = None


class _RunState:
    """Rebuilds the final answer from output-segment events (ABI "Visible
    assistant output"): ``final`` completes its group together with earlier
    ``continued`` segments; ``discarded`` bytes are dropped."""

    def __init__(self) -> None:
        self.open_chunks: List[str] = []
        self.pending: Dict[int, List[str]] = {}
        self.final_text = ""
        self.segments: List[Dict[str, Any]] = []
        self.model_error: Optional[ModelError] = None
        self.usage = {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_input_tokens": 0,
            "cache_creation_input_tokens": 0,
        }

    def observe(self, tag: str, payload: Any) -> None:
        if tag == "output_segment_begin":
            self.open_chunks = []
        elif tag == "text_chunk":
            self.open_chunks.append(payload)
        elif tag == "output_segment_end":
            text = "".join(self.open_chunks)
            self.open_chunks = []
            disposition = payload.get("disposition")
            group = payload.get("group", 0)
            self.segments.append({"disposition": disposition, "group": group, "text": text})
            if disposition == "continued":
                self.pending.setdefault(group, []).append(text)
            elif disposition == "final":
                self.final_text = "".join(self.pending.pop(group, [])) + text
        elif tag == "model_error" and isinstance(payload, dict):
            self.model_error = ModelError(
                category=payload["category"],
                message=payload["message"],
                retry=payload["retry"],
                attempts=payload["attempts"],
                code=payload.get("code"),
                type=payload.get("type"),
                http_status=payload.get("http_status"),
                request_id=payload.get("request_id"),
                retry_after_ms=payload.get("retry_after_ms"),
                truncated=bool(payload.get("truncated", False)),
            )
        elif tag == "usage" and isinstance(payload, dict):
            for key in self.usage:
                self.usage[key] += int(payload.get(key, 0) or 0)


class Runtime:
    """An AgentCore Runtime: the tool catalog sessions select from.

    ``tools`` names the built-in tools (``Read``, ``Write``, ``Edit``,
    ``Glob``, ``Grep``, ``Bash``, ``BashOutput``, ``KillShell``,
    ``WebSearch``, ``WebFetch``, ``AskUserQuestion``); ``host_tools`` adds
    :class:`Tool` objects implemented in Python.
    """

    def __init__(
        self,
        tools: Sequence[str] = DEFAULT_TOOLS,
        host_tools: Sequence[Tool] = (),
        library: Optional[str] = None,
    ) -> None:
        unknown = [name for name in tools if name not in n.BUILTIN_TOOLS]
        if unknown:
            raise ValueError("unknown built-in tools: %s" % ", ".join(unknown))
        self._lib = n.load(library)
        self.tools = tuple(tools)
        self.host_tools = tuple(host_tools)
        if {"Glob", "Grep"} & set(self.tools) and "RG_BIN" not in os.environ:
            if self._lib.ripgrep is not None:
                os.environ["RG_BIN"] = str(self._lib.ripgrep)
        self._arena = n.ViewArena()
        self._results: Dict[int, Any] = {}
        self._results_lock = threading.Lock()
        self._release_fn = n.HostReleaseFn(self._release_result)
        tool_structs = []
        self._execute_fns = []
        for host_tool in self.host_tools:
            execute = n.HostExecuteFn(self._make_execute(host_tool))
            self._execute_fns.append(execute)
            tool_structs.append(
                n.HostTool(
                    struct_size=ctypes.sizeof(n.HostTool),
                    name=self._arena.view(host_tool.name),
                    description=self._arena.view(host_tool.description),
                    input_schema_json=self._arena.view(json.dumps(host_tool.input_schema)),
                    execute=execute,
                    release_result=self._release_fn,
                )
            )
        builtin, builtin_count = self._arena.views(self.tools)
        config = n.RuntimeConfig(struct_size=ctypes.sizeof(n.RuntimeConfig))
        if builtin_count:
            config.builtin_tools = builtin
            config.builtin_tool_count = builtin_count
        if tool_structs:
            array = self._arena.keep((n.HostTool * len(tool_structs))(*tool_structs))
            config.host_tools = array
            config.host_tool_count = len(tool_structs)
        handle = ctypes.c_void_p()
        diagnostic = n.OwnedBytes()
        status = self._lib.api.runtime.contents.create(
            ctypes.byref(config), None, ctypes.byref(handle), ctypes.byref(diagnostic)
        )
        self._lib.check("runtime.create", status, diagnostic)
        self._handle = handle
        self._sessions: List["Session"] = []

    def _publish(self, owned: n.OwnedBytes, data: bytes) -> None:
        if not data:
            owned.ptr = None
            owned.len = 0
            return
        buffer = ctypes.create_string_buffer(data, len(data))
        address = ctypes.addressof(buffer)
        with self._results_lock:
            self._results[address] = buffer
        owned.ptr = address
        owned.len = len(data)

    def _release_result(self, _ctx: Any, owned: Any) -> None:
        address = owned.contents.ptr
        if address:
            with self._results_lock:
                self._results.pop(address, None)

    def _make_execute(self, host_tool: Tool) -> Callable[..., int]:
        def execute(_ctx: Any, run: Any, arguments: n.BytesView, out: Any) -> int:
            with _InCallback(run.contents.session if run else None):
                return run_tool(arguments, out)

        def run_tool(arguments: n.BytesView, out: Any) -> int:
            try:
                raw = n.view_bytes(arguments)
                parsed = json.loads(raw.decode("utf-8")) if raw else {}
                value = host_tool.handler(parsed)
                text = value if isinstance(value, str) else json.dumps(value)
                self._publish(out.contents, text.encode("utf-8"))
                return n.HOST_OK
            except Exception as error:  # the model sees the message as a tool error
                message = "%s: %s" % (type(error).__name__, error)
                self._publish(out.contents, message.encode("utf-8"))
                return n.HOST_FAILED

        return execute

    def session(self, model: str, **options: Any) -> "Session":
        """Create a :class:`Session`; see its constructor for ``options``."""
        session = Session(self, model, **options)
        self._sessions.append(session)
        return session

    def close(self, timeout: Optional[float] = None) -> None:
        """Close every Session (see :meth:`Session.close`; ``timeout`` applies
        to each), then destroy the Runtime. The handle is kept when AgentCore
        refuses, so ``close()`` can be retried."""
        if not self._handle:
            return
        for session in list(self._sessions):
            session.close(timeout)
        diagnostic = n.OwnedBytes()
        status = self._lib.api.runtime.contents.destroy(self._handle, ctypes.byref(diagnostic))
        if status == n.STATUS_OK:
            self._handle = ctypes.c_void_p()
        self._lib.check("runtime.destroy", status, diagnostic)

    def __enter__(self) -> "Runtime":
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()


class Session:
    """One agent conversation. Runs are synchronous and one at a time.

    ``provider`` is ``anthropic``, ``openai`` or ``gemini``. ``base_url`` is the
    full endpoint (empty means the provider's official one); ``api_key``
    defaults to the provider's usual environment variable, then
    ``METACODES_API_KEY``. ``tools`` selects from the Runtime's tools (default:
    all of them, minus shell tools when ``shell`` is ``disabled``).
    ``permission_mode`` is ``default``, ``accept_edits``, ``auto``,
    ``dont_ask`` or ``full_access``; ``shell`` is ``disabled``, ``sandboxed``
    or ``unrestricted``. ``on_ui_request`` receives a :class:`UiRequest` and
    returns its answer (for example ``request.allow_once()``), or ``None``
    when no answer is available.
    """

    def __init__(
        self,
        runtime: Runtime,
        model: str,
        *,
        provider: str = "anthropic",
        api_key: Optional[str] = None,
        base_url: Optional[str] = None,
        workspace: str = ".",
        workspace_home: Optional[str] = None,
        tools: Optional[Sequence[str]] = None,
        permission_mode: str = "default",
        shell: str = "disabled",
        openai_protocol: Optional[str] = None,
        allow: Sequence[str] = (),
        ask: Sequence[str] = (),
        deny: Sequence[str] = (),
        on_event: Optional[Callable[[Dict[str, Any]], None]] = None,
        on_ui_request: Optional[Callable[[UiRequest], Optional[Dict[str, Any]]]] = None,
    ) -> None:
        if provider not in n.PROVIDERS:
            raise ValueError("provider must be one of %s" % ", ".join(n.PROVIDERS))
        if permission_mode not in n.PERMISSION_MODES:
            raise ValueError("permission_mode must be one of %s" % ", ".join(n.PERMISSION_MODES))
        if shell not in n.SHELL_POLICIES:
            raise ValueError("shell must be one of %s" % ", ".join(n.SHELL_POLICIES))
        protocol = n.PROTOCOL_DEFAULT
        if openai_protocol not in (None, "chat_completions", "responses"):
            raise ValueError("openai_protocol must be chat_completions or responses")
        if openai_protocol == "responses":
            if provider != "openai":
                raise ValueError("openai_protocol applies to provider='openai' only")
            protocol = n.OPENAI_PROTOCOL_RESPONSES
        if api_key is None:
            for name in _API_KEY_ENV[provider] + ("METACODES_API_KEY",):
                if os.environ.get(name):
                    api_key = os.environ[name]
                    break
        if tools is None:
            tools = list(runtime.tools) + [host_tool.name for host_tool in runtime.host_tools]
            if shell == "disabled":
                tools = [name for name in tools if name not in SHELL_TOOLS]
        self._runtime = runtime
        self._lib = runtime._lib
        self.model = model
        self._on_event = on_event
        self._on_ui_request = on_ui_request
        self._run_lock = threading.Lock()
        # Held around update_credential's call and around destroy, so a
        # credential update never races the handle's release.
        self._handle_lock = threading.Lock()
        self._next_run_id = 1
        self._active_run_id = 0
        self._next_input_id = 1
        self._state: Optional[_RunState] = None
        self._run_on_event: Optional[Callable[[Dict[str, Any]], None]] = None
        self._callback_error: Optional[BaseException] = None
        self._responses: Dict[int, Any] = {}
        self._responses_lock = threading.Lock()

        arena = n.ViewArena()
        host = n.SessionHostConfig(struct_size=ctypes.sizeof(n.SessionHostConfig))
        host.provider_kind_code = n.PROVIDERS[provider]
        host.protocol_kind_code = protocol
        host.permission_mode_code = n.PERMISSION_MODES[permission_mode]
        host.shell_policy_code = n.SHELL_POLICIES[shell]
        host.api_key = arena.view(api_key or "")
        host.base_url = arena.view(base_url or "")
        host.workspace_root = arena.view(str(Path(workspace).resolve()))
        host.workspace_home = arena.view(str(Path(workspace_home).resolve()) if workspace_home else "")
        selected, selected_count = arena.views(tools)
        if selected_count:
            host.allowed_tools = selected
            host.allowed_tool_count = selected_count
        if allow or ask or deny:
            rules = n.PermissionRuleSet(struct_size=ctypes.sizeof(n.PermissionRuleSet))
            rules.allow, rules.allow_count = arena.views(allow)
            rules.ask, rules.ask_count = arena.views(ask)
            rules.deny, rules.deny_count = arena.views(deny)
            host.permission_rules = ctypes.pointer(arena.keep(rules))
        config = n.SessionCreateConfig(struct_size=ctypes.sizeof(n.SessionCreateConfig))
        config.host = ctypes.pointer(host)
        config.model = arena.view(model)

        self._event_fn = n.OnEventFn(self._event)
        self._ui_fn = n.OnUiRequestFn(self._ui_request)
        self._release_fn = n.ReleaseResponseFn(self._release_response)
        callbacks = n.SessionCallbacks(struct_size=ctypes.sizeof(n.SessionCallbacks))
        callbacks.on_event = self._event_fn
        callbacks.on_ui_request = self._ui_fn
        callbacks.release_response = self._release_fn
        handle = ctypes.c_void_p()
        diagnostic = n.OwnedBytes()
        status = self._lib.api.session.contents.create(
            runtime._handle,
            ctypes.byref(config),
            ctypes.byref(callbacks),
            ctypes.byref(handle),
            ctypes.byref(diagnostic),
        )
        self._lib.check("session.create", status, diagnostic)
        self._handle = handle

    # Callbacks run on AgentCore threads; ctypes takes the GIL for them.

    def _event(self, _ctx: Any, _run: Any, view: n.BytesView) -> int:
        with _InCallback(self._handle.value):
            return self._dispatch_event(view)

    def _dispatch_event(self, view: n.BytesView) -> int:
        try:
            event = json.loads(n.view_bytes(view).decode("utf-8"))
            if isinstance(event, dict) and len(event) == 1:
                tag, payload = next(iter(event.items()))
                if self._state is not None:
                    self._state.observe(tag, payload)
            for listener in (self._on_event, self._run_on_event):
                if listener is not None:
                    listener(event)
        except BaseException as error:
            # A broken listener must not poison the Session: stop the Run and
            # re-raise from run() once AgentCore has returned.
            if self._callback_error is None:
                self._callback_error = error
            self._abort_active()
        return n.EVENT_CONTINUE

    def _ui_request(self, _ctx: Any, _run: Any, view: n.BytesView, out: Any) -> int:
        with _InCallback(self._handle.value):
            return self._answer_ui_request(view, out)

    def _answer_ui_request(self, view: n.BytesView, out: Any) -> int:
        out.contents.ptr = None
        out.contents.len = 0
        if self._on_ui_request is None:
            return n.UI_UNAVAILABLE
        try:
            data = json.loads(n.view_bytes(view).decode("utf-8"))
            if "ask_question" in data:
                request = UiRequest("ask_question", {"questions": data["ask_question"]})
            else:
                request = UiRequest("permission", data.get("permission", data))
            answer = self._on_ui_request(request)
            if answer is None:
                return n.UI_UNAVAILABLE
            encoded = json.dumps(answer).encode("utf-8")
            buffer = ctypes.create_string_buffer(encoded, len(encoded))
            address = ctypes.addressof(buffer)
            with self._responses_lock:
                self._responses[address] = buffer
            out.contents.ptr = address
            out.contents.len = len(encoded)
            return n.UI_ANSWERED
        except BaseException as error:
            if self._callback_error is None:
                self._callback_error = error
            return n.UI_UNAVAILABLE

    def _release_response(self, _ctx: Any, owned: Any) -> None:
        address = owned.contents.ptr
        if address:
            with self._responses_lock:
                self._responses.pop(address, None)

    def _abort_active(self) -> None:
        run_id = self._active_run_id
        if run_id and self._handle:
            diagnostic = n.OwnedBytes()
            self._lib.api.session.contents.abort(
                self._handle, run_id, n.ABORT_USER_REQUEST, ctypes.byref(diagnostic)
            )
            self._lib.take_diagnostic(diagnostic)

    def _finish_run(self) -> None:
        """End the active Run's bookkeeping and free the Session for the next
        Run or close(). Called exactly once per Run, after its native call
        returned."""
        self._active_run_id = 0
        self._run_on_event = None
        self._state = None
        self._callback_error = None
        self._run_lock.release()

    def run(
        self,
        prompt: str,
        *,
        max_turns: Optional[int] = None,
        on_event: Optional[Callable[[Dict[str, Any]], None]] = None,
    ) -> RunResult:
        """Run one prompt to completion and return the final answer.

        The Run executes on its own thread (``RUN_STACK_BYTES`` of stack);
        this call waits for it. An interrupt while waiting (Ctrl+C) aborts the
        Run and waits for it to end before it propagates; a second interrupt
        stops the wait, and the Session stays busy until the Run ends.
        """
        if not self._handle:
            raise RuntimeError("session is closed")
        if not self._run_lock.acquire(blocking=False):
            raise RuntimeError("a Run is already active on this session")
        started = False
        try:
            arena = n.ViewArena()
            run_input = n.RunInput(struct_size=ctypes.sizeof(n.RunInput), kind_code=n.RUN_INPUT_TEXT)
            run_input.text = arena.view(prompt)
            options = n.RunOptions(struct_size=ctypes.sizeof(n.RunOptions))
            turns = DEFAULT_MAX_TURNS if max_turns is None else int(max_turns)
            if not 1 <= turns <= n.MAX_TURNS:
                raise ValueError("max_turns must be between 1 and %d" % n.MAX_TURNS)
            options.max_turns = turns
            result = n.RunResult(struct_size=ctypes.sizeof(n.RunResult))
            diagnostic = n.OwnedBytes()
            run_id = self._next_run_id
            self._next_run_id += 1
            self._state = _RunState()
            self._run_on_event = on_event
            self._callback_error = None
            self._active_run_id = run_id
            handle = self._handle

            def close_interrupted() -> None:
                self._lib.take_diagnostic(diagnostic)  # nobody reads this Run's result
                self._finish_run()

            call = _RunThread(
                lambda: self._lib.api.session.contents.run_input(
                    handle,
                    run_id,
                    ctypes.byref(run_input),
                    ctypes.byref(options),
                    ctypes.byref(result),
                    ctypes.byref(diagnostic),
                ),
                close_interrupted,
                keep=(arena, run_input, options, result, diagnostic),
            )
            call.start()
            started = True
        finally:
            if not started:
                self._finish_run()
        # From here the Run is closed exactly once: by _RunThread on an
        # interrupt, otherwise below.
        call.wait(self._abort_active)
        try:
            state = self._state
            callback_error = self._callback_error
        finally:
            self._finish_run()
        if call.error is not None:
            self._lib.take_diagnostic(diagnostic)
            raise call.error
        if callback_error is not None:
            self._lib.take_diagnostic(diagnostic)
            raise callback_error
        self._lib.check("session.run_input", call.status, diagnostic)
        return RunResult(
            text=state.final_text,
            stop_reason=n.STOP_REASONS.get(result.stop_reason_code, str(result.stop_reason_code)),
            turns=result.turns,
            tool_calls=result.tool_calls,
            usage=state.usage,
            segments=state.segments,
            input_accepted=result.input_accepted_count,
            input_adopted=result.input_adopted_count,
            model_error=state.model_error,
        )

    def stream(self, prompt: str, *, max_turns: Optional[int] = None) -> "EventStream":
        """Run ``prompt`` on a background thread and iterate over its events.

        Iterating yields each event dict as it arrives; afterwards
        ``stream.result`` holds the :class:`RunResult`.
        """
        return EventStream(self, prompt, max_turns)

    def abort(self) -> None:
        """Ask the active Run to stop; it returns with stop_reason 'aborted'."""
        self._abort_active()

    def submit(self, text: str) -> int:
        """Hand the active Run more user text; returns its acceptance sequence."""
        run_id = self._active_run_id
        if not run_id:
            raise RuntimeError("no active Run")
        arena = n.ViewArena()
        submitted = n.SubmittedInput(struct_size=ctypes.sizeof(n.SubmittedInput))
        submitted.input_id = self._next_input_id
        self._next_input_id += 1
        submitted.text = arena.view(text)
        receipt = n.InputReceipt(struct_size=ctypes.sizeof(n.InputReceipt))
        diagnostic = n.OwnedBytes()
        status = self._lib.api.session.contents.submit_input(
            self._handle, run_id, ctypes.byref(submitted), ctypes.byref(receipt), ctypes.byref(diagnostic)
        )
        self._lib.check("session.submit_input", status, diagnostic)
        return receipt.sequence

    def update_credential(self, api_key: str) -> None:
        """Replace the provider credential in place (AgentCore Revision 25).

        Every request sent after this returns uses ``api_key``: the next turn
        of a Run already going, a retry, a compaction, a Skill, a request
        still waiting for a connection. A request already sent keeps the old
        key and is not interrupted. Safe from any thread and from this Session's own
        callbacks (a host tool, ``on_event``, ``on_ui_request``). The provider,
        endpoint and model stay. ``api_key`` is 1 to 16384 bytes of printable
        ASCII; anything else raises AgentCoreError and keeps the previous key.
        """
        arena = n.ViewArena()
        diagnostic = n.OwnedBytes()
        with self._handle_lock:
            if not self._handle:
                raise RuntimeError("the Session is closed")
            status = self._lib.api.session.contents.update_credential(
                self._handle, arena.view(api_key), ctypes.byref(diagnostic)
            )
        self._lib.check("session.update_credential", status, diagnostic)

    def describe(self) -> Dict[str, Any]:
        """The Session's description as AgentCore reports it (JSON)."""
        output = n.OwnedBytes()
        diagnostic = n.OwnedBytes()
        status = self._lib.api.session_control.contents.describe(
            self._handle, ctypes.byref(output), ctypes.byref(diagnostic)
        )
        if status != n.STATUS_OK:
            self._lib.take_bytes(output)
        self._lib.check("session.describe", status, diagnostic)
        return json.loads(self._lib.take_bytes(output).decode("utf-8"))

    def set_model(self, model: str) -> None:
        arena = n.ViewArena()
        diagnostic = n.OwnedBytes()
        status = self._lib.api.session_control.contents.set_model(
            self._handle, arena.view(model), ctypes.byref(diagnostic)
        )
        self._lib.check("session.set_model", status, diagnostic)
        self.model = model

    def set_permission_mode(self, mode: str) -> None:
        if mode not in n.PERMISSION_MODES:
            raise ValueError("permission_mode must be one of %s" % ", ".join(n.PERMISSION_MODES))
        diagnostic = n.OwnedBytes()
        status = self._lib.api.session_control.contents.update_permission_mode(
            self._handle, n.PERMISSION_MODES[mode], ctypes.byref(diagnostic)
        )
        self._lib.check("session.update_permission_mode", status, diagnostic)

    def close(self, timeout: Optional[float] = None) -> None:
        """Destroy the Session.

        A Run still going (a :meth:`stream` the caller stopped iterating, or a
        :meth:`run` on another thread) is aborted and waited for first, since
        AgentCore refuses to destroy a Session with an active Run. Abort is
        cooperative: a host tool or ``on_ui_request`` that blocks keeps the
        Run, and so ``close()``, waiting. With ``timeout`` (seconds) a Run
        that has not returned by then raises TimeoutError and the Session
        stays open; the abort stays requested, so that Run still ends
        ``aborted``. The handle is dropped only once AgentCore has destroyed
        the Session; on a refusal it is kept, so the Session stays usable and
        ``close()`` can be retried. Calling it from one of this Session's own
        callbacks, or from a callback of a child Session's Run that one of
        them started, raises RuntimeError: that callback's Run could never
        return.
        """
        if not self._handle:
            return
        if _in_callback_of(self._handle.value):
            raise RuntimeError("Session.close() cannot be called from one of the Session's own callbacks")
        deadline = None if timeout is None else time.monotonic() + timeout
        # Abort until the active run() returns and releases the lock: a Run
        # started on another thread in between is aborted too.
        while not self._run_lock.acquire(timeout=0.05):
            self._abort_active()
            if deadline is not None and time.monotonic() >= deadline:
                raise TimeoutError("the active Run did not return within %ss; the Session stays open" % timeout)
        try:
            if not self._handle:
                return
            diagnostic = n.OwnedBytes()
            with self._handle_lock:
                status = self._lib.api.session.contents.destroy(self._handle, ctypes.byref(diagnostic))
                if status == n.STATUS_OK:
                    self._handle = ctypes.c_void_p()
            if status == n.STATUS_OK:
                if self in self._runtime._sessions:
                    self._runtime._sessions.remove(self)
            self._lib.check("session.destroy", status, diagnostic)
        finally:
            self._run_lock.release()

    def __enter__(self) -> "Session":
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()


_DONE = object()


class EventStream:
    """Iterator over one Run's events; ``result`` is set when it ends."""

    def __init__(self, session: Session, prompt: str, max_turns: Optional[int]) -> None:
        self.result: Optional[RunResult] = None
        self._queue: "queue.Queue[Any]" = queue.Queue()
        self._error: Optional[BaseException] = None
        self._session = session

        def work() -> None:
            try:
                self.result = session.run(prompt, max_turns=max_turns, on_event=self._queue.put)
            except BaseException as error:
                self._error = error
            finally:
                self._queue.put(_DONE)

        self._thread = threading.Thread(target=work, name="metacodes-run", daemon=True)
        self._thread.start()

    def __iter__(self) -> Iterator[Dict[str, Any]]:
        while True:
            item = self._queue.get()
            if item is _DONE:
                break
            yield item
        self._thread.join()
        if self._error is not None:
            raise self._error

    def abort(self) -> None:
        self._session.abort()
