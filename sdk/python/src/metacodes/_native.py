"""ctypes projection of the AgentCore C ABI (sdk/metask/agentcore.h).

Only the slice the high-level API uses is declared. Every struct mirrors the
header field for field; the library rejects a wrong ``struct_size`` with
INVALID_ARGUMENT, so a layout drift fails loudly instead of corrupting memory.
The Revision this module speaks is pinned in ``ABI_REVISION``; discovery
refuses any other library.
"""

from __future__ import annotations

import ctypes
import os
import sys
from pathlib import Path
from typing import Optional

ABI_V1 = 1
ABI_REVISION = 27

# Status codes (METASK_AGENTCORE_STATUS_*).
STATUS_NAMES = {
    0: "OK",
    1: "INVALID_ARGUMENT",
    2: "OUT_OF_MEMORY",
    3: "BUSY",
    4: "STALE_RUN",
    5: "TOO_LATE",
    6: "INVALID_STATE",
    7: "CORE_ERROR",
    8: "CALLBACK_FAILED",
    9: "INTERNAL_ERROR",
    10: "RESOURCE_LIMIT",
    11: "SKILL_CATALOG_INVALID",
    12: "STALE_CATALOG",
    13: "SKILL_NOT_FOUND",
    14: "INVALID_SKILL_ARGUMENTS",
    15: "SKILL_POLICY_VIOLATION",
    16: "SKILL_UNAVAILABLE",
    17: "STALE_COMPACT",
    18: "CHECKPOINT_BUDGET_REQUIRED",
    19: "CHECKPOINT_CORRUPT",
    20: "CHECKPOINT_UNSUPPORTED",
    21: "CHECKPOINT_INCOMPATIBLE",
    22: "CHECKPOINT_IO",
    23: "LOGICAL_SESSION_CONFLICT",
    24: "MCP_NOT_REFRESHED",
    25: "INVALID_MCP_SELECTION",
    27: "SKILL_CATALOG_INCOMPLETE",
    28: "IMAGE_INPUT_UNSUPPORTED",
    29: "IMAGE_INPUT_CAPABILITY_UNKNOWN",
    30: "GOAL_CONFLICT",
    31: "MESSAGE_POSITION_OUT_OF_RANGE",
    32: "NOT_USER_MESSAGE",
    33: "MESSAGE_POSITION_COMPACTED",
}
STATUS_OK = 0

PROVIDERS = {"anthropic": 1, "openai": 2, "gemini": 3}
PROTOCOL_DEFAULT = 0
OPENAI_PROTOCOL_RESPONSES = 1
PERMISSION_MODES = {
    "default": 1,
    "accept_edits": 2,
    "auto": 3,
    "dont_ask": 4,
    "full_access": 5,
}
SHELL_POLICIES = {"disabled": 1, "sandboxed": 2, "unrestricted": 3}
ABORT_USER_REQUEST = 1
STOP_REASONS = {
    1: "end_turn",
    2: "max_turns",
    3: "aborted",
    4: "tool_error",
    5: "api_error",
    6: "tool_loop",
    7: "checkpoint_budget_exhausted",
    8: "checkpoint_resource_limit",
}
RUN_INPUT_TEXT = 1
EVENT_CONTINUE = 0
EVENT_FATAL = 1
UI_ANSWERED = 0
UI_UNAVAILABLE = 1
HOST_OK = 0
HOST_FAILED = 1
MAX_TURNS = 1000

BUILTIN_TOOLS = (
    "Read",
    "Write",
    "Edit",
    "Glob",
    "Grep",
    "Bash",
    "BashOutput",
    "KillShell",
    "WebSearch",
    "WebFetch",
    "AskUserQuestion",
)


class BytesView(ctypes.Structure):
    _fields_ = [("ptr", ctypes.c_void_p), ("len", ctypes.c_uint64)]


class OwnedBytes(ctypes.Structure):
    _fields_ = [("ptr", ctypes.c_void_p), ("len", ctypes.c_uint64)]


class RunContext(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("reserved0", ctypes.c_uint32),
        ("session", ctypes.c_void_p),
        ("run_id", ctypes.c_uint64),
        ("session_id", BytesView),
        ("reserved", ctypes.c_uint64 * 2),
    ]


HostExecuteFn = ctypes.CFUNCTYPE(
    ctypes.c_uint32,
    ctypes.c_void_p,
    ctypes.POINTER(RunContext),
    BytesView,
    ctypes.POINTER(OwnedBytes),
)
HostReleaseFn = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.POINTER(OwnedBytes))


class HostTool(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("reserved0", ctypes.c_uint32),
        ("ctx", ctypes.c_void_p),
        ("name", BytesView),
        ("description", BytesView),
        ("input_schema_json", BytesView),
        ("execute", HostExecuteFn),
        ("release_result", HostReleaseFn),
        ("reserved", ctypes.c_uint64 * 2),
    ]


class RuntimeConfig(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("reserved0", ctypes.c_uint32),
        ("builtin_tools", ctypes.POINTER(BytesView)),
        ("builtin_tool_count", ctypes.c_uint64),
        ("host_tools", ctypes.POINTER(HostTool)),
        ("host_tool_count", ctypes.c_uint64),
        ("mcp_servers", ctypes.c_void_p),
        ("mcp_server_count", ctypes.c_uint64),
        ("mcp_catalog_limits", ctypes.c_void_p),
        ("enable_teams", ctypes.c_uint64),
        ("reserved", ctypes.c_uint64 * 3),
    ]


OnEventFn = ctypes.CFUNCTYPE(
    ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(RunContext), BytesView
)
OnUiRequestFn = ctypes.CFUNCTYPE(
    ctypes.c_uint32,
    ctypes.c_void_p,
    ctypes.POINTER(RunContext),
    BytesView,
    ctypes.POINTER(OwnedBytes),
)
ReleaseResponseFn = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.POINTER(OwnedBytes))


class SessionCallbacks(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("reserved0", ctypes.c_uint32),
        ("ctx", ctypes.c_void_p),
        ("on_event", OnEventFn),
        ("on_ui_request", OnUiRequestFn),
        ("release_response", ReleaseResponseFn),
        ("reserved", ctypes.c_uint64 * 4),
    ]


class PermissionRuleSet(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("reserved0", ctypes.c_uint32),
        ("allow", ctypes.POINTER(BytesView)),
        ("allow_count", ctypes.c_uint64),
        ("ask", ctypes.POINTER(BytesView)),
        ("ask_count", ctypes.c_uint64),
        ("deny", ctypes.POINTER(BytesView)),
        ("deny_count", ctypes.c_uint64),
        ("reserved", ctypes.c_uint64 * 4),
    ]


class SessionHostConfig(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("provider_kind_code", ctypes.c_uint32),
        ("permission_mode_code", ctypes.c_uint32),
        ("shell_policy_code", ctypes.c_uint32),
        ("api_key", BytesView),
        ("base_url", BytesView),
        ("workspace_root", BytesView),
        ("workspace_home", BytesView),
        ("allowed_tools", ctypes.POINTER(BytesView)),
        ("allowed_tool_count", ctypes.c_uint64),
        ("skill_catalog", ctypes.c_void_p),
        ("skill_policy", ctypes.c_void_p),
        ("permission_rules", ctypes.POINTER(PermissionRuleSet)),
        ("mcp_selection", ctypes.c_void_p),
        ("durable_budget", ctypes.c_void_p),
        ("run_journal_mode_code", ctypes.c_uint32),
        ("protocol_kind_code", ctypes.c_uint32),
        ("model_capabilities", ctypes.c_void_p),
        ("model_capability_count", ctypes.c_uint64),
        ("team", ctypes.c_void_p),
    ]


class SessionCreateConfig(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("reserved0", ctypes.c_uint32),
        ("host", ctypes.POINTER(SessionHostConfig)),
        ("model", BytesView),
        ("prompt_profile", ctypes.c_void_p),
        ("reserved", ctypes.c_uint64 * 3),
    ]


class RunInput(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("kind_code", ctypes.c_uint32),
        ("text", BytesView),
        ("skill_id", BytesView),
        ("catalog_revision", BytesView),
        ("arguments_json", BytesView),
        ("parts", ctypes.c_void_p),
        ("part_count", ctypes.c_uint64),
        ("reserved", ctypes.c_uint64 * 2),
    ]


class RunOptions(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("max_turns", ctypes.c_uint32),
        ("context_blocks", ctypes.c_void_p),
        ("context_block_count", ctypes.c_uint64),
        ("time_context_code", ctypes.c_uint32),
        ("utc_offset_minutes", ctypes.c_int32),
        ("reserved", ctypes.c_uint64 * 1),
    ]


class RunResult(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("stop_reason_code", ctypes.c_uint32),
        ("turns", ctypes.c_uint32),
        ("tool_calls", ctypes.c_uint32),
        ("checkpoint_outcome_code", ctypes.c_uint32),
        ("result_flags", ctypes.c_uint32),
        ("durable_usage_bytes", ctypes.c_uint64),
        ("required_checkpoint_bytes", ctypes.c_uint64),
        ("input_accepted_count", ctypes.c_uint32),
        ("input_adopted_count", ctypes.c_uint32),
        ("reserved", ctypes.c_uint64 * 3),
    ]


class SubmittedInput(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("reserved0", ctypes.c_uint32),
        ("input_id", ctypes.c_uint64),
        ("text", BytesView),
        ("reserved", ctypes.c_uint64 * 2),
    ]


class InputReceipt(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("sequence", ctypes.c_uint32),
        ("reserved", ctypes.c_uint64 * 2),
    ]


_P = ctypes.c_void_p
_DIAG = ctypes.POINTER(OwnedBytes)

RuntimeCreateFn = ctypes.CFUNCTYPE(
    ctypes.c_uint32,
    ctypes.POINTER(RuntimeConfig),
    _P,
    ctypes.POINTER(ctypes.c_void_p),
    _DIAG,
)
RuntimeDestroyFn = ctypes.CFUNCTYPE(ctypes.c_uint32, _P, _DIAG)
SessionCreateFn = ctypes.CFUNCTYPE(
    ctypes.c_uint32,
    _P,
    ctypes.POINTER(SessionCreateConfig),
    ctypes.POINTER(SessionCallbacks),
    ctypes.POINTER(ctypes.c_void_p),
    _DIAG,
)
SessionDestroyFn = ctypes.CFUNCTYPE(ctypes.c_uint32, _P, _DIAG)
SessionRunInputFn = ctypes.CFUNCTYPE(
    ctypes.c_uint32,
    _P,
    ctypes.c_uint64,
    ctypes.POINTER(RunInput),
    ctypes.POINTER(RunOptions),
    ctypes.POINTER(RunResult),
    _DIAG,
)
SessionAbortFn = ctypes.CFUNCTYPE(ctypes.c_uint32, _P, ctypes.c_uint64, ctypes.c_uint32, _DIAG)
SessionSubmitInputFn = ctypes.CFUNCTYPE(
    ctypes.c_uint32,
    _P,
    ctypes.c_uint64,
    ctypes.POINTER(SubmittedInput),
    ctypes.POINTER(InputReceipt),
    _DIAG,
)
SessionUpdateCredentialFn = ctypes.CFUNCTYPE(ctypes.c_uint32, _P, BytesView, _DIAG)
SessionDescribeFn = ctypes.CFUNCTYPE(ctypes.c_uint32, _P, ctypes.POINTER(OwnedBytes), _DIAG)
SessionSetModelFn = ctypes.CFUNCTYPE(ctypes.c_uint32, _P, BytesView, _DIAG)
SessionUpdateRulesFn = ctypes.CFUNCTYPE(
    ctypes.c_uint32, _P, ctypes.POINTER(PermissionRuleSet), _DIAG
)
SessionUpdateModeFn = ctypes.CFUNCTYPE(ctypes.c_uint32, _P, ctypes.c_uint32, _DIAG)
SessionRewindFn = ctypes.CFUNCTYPE(ctypes.c_uint32, _P, ctypes.c_uint64, _DIAG)
BufferReleaseFn = ctypes.CFUNCTYPE(None, ctypes.POINTER(OwnedBytes))


class RuntimeApi(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("reserved0", ctypes.c_uint32),
        ("create", RuntimeCreateFn),
        ("destroy", RuntimeDestroyFn),
    ]


class SessionApi(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("reserved0", ctypes.c_uint32),
        ("create", SessionCreateFn),
        ("destroy", SessionDestroyFn),
        ("run_input", SessionRunInputFn),
        ("abort", SessionAbortFn),
        ("submit_input", SessionSubmitInputFn),
        ("update_credential", SessionUpdateCredentialFn),
    ]


class SessionControlApi(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("reserved0", ctypes.c_uint32),
        ("restore", ctypes.c_void_p),
        ("describe", SessionDescribeFn),
        ("set_model", SessionSetModelFn),
        ("update_permission_rules", SessionUpdateRulesFn),
        ("compact", ctypes.c_void_p),
        ("abort_compact", ctypes.c_void_p),
        ("export_checkpoint", ctypes.c_void_p),
        ("set_prompt_profile", ctypes.c_void_p),
        ("update_permission_mode", SessionUpdateModeFn),
        ("rewind_to_user_message", SessionRewindFn),
    ]


def _slot_table(name: str, slots: int) -> type:
    fields = [("struct_size", ctypes.c_uint32), ("reserved0", ctypes.c_uint32)]
    fields += [("slot%d" % index, ctypes.c_void_p) for index in range(slots)]
    return type(name, (ctypes.Structure,), {"_fields_": fields})


# Tables this module does not call; they are validated for size and non-null
# slots exactly like the header's metask_agentcore_api_v1_is_compatible.
SkillApi = _slot_table("SkillApi", 3)
McpApi = _slot_table("McpApi", 4)
GoalApi = _slot_table("GoalApi", 4)
TeamApi = _slot_table("TeamApi", 2)


class ApiV1(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("abi_version", ctypes.c_uint32),
        ("abi_revision", ctypes.c_uint32),
        ("reserved0", ctypes.c_uint32),
        ("buffer_release", BufferReleaseFn),
        ("runtime", ctypes.POINTER(RuntimeApi)),
        ("session", ctypes.POINTER(SessionApi)),
        ("session_control", ctypes.POINTER(SessionControlApi)),
        ("skill", ctypes.POINTER(SkillApi)),
        ("mcp", ctypes.POINTER(McpApi)),
        ("goal", ctypes.POINTER(GoalApi)),
        ("team", ctypes.POINTER(TeamApi)),
    ]


assert ctypes.sizeof(ApiV1) == 80, "AgentCore Revision 27 root is 80 bytes"
assert ctypes.sizeof(SessionApi) == 56, "AgentCore Revision 27 Session table is 56 bytes"
assert ctypes.sizeof(SessionControlApi) == 88, "AgentCore Revision 27 Session Control table is 88 bytes"


class AgentCoreError(RuntimeError):
    """An AgentCore call returned a non-OK status."""

    def __init__(self, operation: str, status: int, diagnostic: str = "") -> None:
        self.operation = operation
        self.status = status
        self.status_name = STATUS_NAMES.get(status, "UNKNOWN_%d" % status)
        self.diagnostic = diagnostic
        message = "%s failed: %s" % (operation, self.status_name)
        if diagnostic:
            message += ": " + diagnostic
        super().__init__(message)


def _library_file_name() -> str:
    if sys.platform == "darwin":
        return "libmetask_agentcore.dylib"
    if sys.platform == "win32":
        return "metask_agentcore.dll"
    return "libmetask_agentcore.so"


def _rg_file_name() -> str:
    return "rg.exe" if sys.platform == "win32" else "rg"


def candidate_library_paths(explicit: Optional[str] = None) -> list:
    """Where the shared library is looked for, in order."""
    name = _library_file_name()
    if explicit:
        return [Path(explicit)]
    paths = []
    env = os.environ.get("METACODES_AGENTCORE_LIB")
    if env:
        paths.append(Path(env))
    paths.append(Path(__file__).resolve().parent / "_lib" / name)
    sdk = os.environ.get("METACODES_AGENTCORE_SDK")
    if sdk:
        paths.append(Path(sdk) / "lib" / name)
    home = Path.home() / ".local" / "opt"
    paths.append(home / "metacodes" / "sdk" / "agentcore" / "lib" / name)
    paths.append(home / "metacodes-dev" / "sdk" / "agentcore" / "lib" / name)
    return paths


def _bundled_ripgrep(library_path: Path) -> Optional[Path]:
    """The rg that ships beside the library: wheel `_lib/rg` or bundle `bin/rg`."""
    for candidate in (
        library_path.parent / _rg_file_name(),
        library_path.parent.parent / "bin" / _rg_file_name(),
    ):
        if candidate.is_file():
            return candidate
    return None


class Library:
    """A loaded, validated AgentCore shared library."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._dll = ctypes.CDLL(str(path))
        get_api = self._dll.metask_agentcore_get_api
        get_api.argtypes = [ctypes.c_uint32]
        get_api.restype = ctypes.c_void_p
        raw = get_api(ABI_V1)
        if not raw:
            raise AgentCoreError("metask_agentcore_get_api", 1, "library returned no ABI v1 table")
        self.api = ctypes.cast(raw, ctypes.POINTER(ApiV1)).contents
        self._validate()
        self.ripgrep = _bundled_ripgrep(path)

    def _validate(self) -> None:
        api = self.api
        problems = []
        if api.struct_size != ctypes.sizeof(ApiV1):
            problems.append("root struct_size %d" % api.struct_size)
        if api.abi_version != ABI_V1 or api.abi_revision != ABI_REVISION:
            problems.append(
                "ABI v%d revision %d (this package speaks v%d revision %d)"
                % (api.abi_version, api.abi_revision, ABI_V1, ABI_REVISION)
            )
        if not api.buffer_release:
            problems.append("null buffer_release")
        tables = (
            ("runtime", RuntimeApi),
            ("session", SessionApi),
            ("session_control", SessionControlApi),
            ("skill", SkillApi),
            ("mcp", McpApi),
            ("goal", GoalApi),
            ("team", TeamApi),
        )
        for name, layout in tables:
            pointer = getattr(api, name)
            if not pointer:
                problems.append("null %s table" % name)
                continue
            table = pointer.contents
            if table.struct_size != ctypes.sizeof(layout) or table.reserved0 != 0:
                problems.append("%s table size %d" % (name, table.struct_size))
                continue
            for field, _ in layout._fields_[2:]:
                slot = getattr(table, field)
                if not slot:
                    problems.append("null %s.%s" % (name, field))
        if problems:
            raise AgentCoreError(
                "AgentCore discovery",
                1,
                "%s is not a compatible library: %s" % (self.path, "; ".join(problems)),
            )

    def take_diagnostic(self, diagnostic: OwnedBytes) -> str:
        """Read and release one library-owned diagnostic buffer."""
        if not diagnostic.ptr or diagnostic.len == 0:
            return ""
        try:
            return ctypes.string_at(diagnostic.ptr, diagnostic.len).decode("utf-8", "replace")
        finally:
            self.api.buffer_release(ctypes.byref(diagnostic))
            diagnostic.ptr = None
            diagnostic.len = 0

    def take_bytes(self, owned: OwnedBytes) -> bytes:
        """Copy and release one library-owned output buffer."""
        if not owned.ptr or owned.len == 0:
            return b""
        try:
            return ctypes.string_at(owned.ptr, owned.len)
        finally:
            self.api.buffer_release(ctypes.byref(owned))
            owned.ptr = None
            owned.len = 0

    def check(self, operation: str, status: int, diagnostic: OwnedBytes) -> None:
        text = self.take_diagnostic(diagnostic)
        if status != STATUS_OK:
            raise AgentCoreError(operation, status, text)


_loaded: Optional[Library] = None


def load(library: Optional[str] = None) -> Library:
    """Load the first library found by `candidate_library_paths`."""
    global _loaded
    if library is None and _loaded is not None:
        return _loaded
    tried = []
    for path in candidate_library_paths(library):
        if path.is_file():
            loaded = Library(path)
            if library is None:
                _loaded = loaded
            return loaded
        tried.append(str(path))
    raise FileNotFoundError(
        "AgentCore shared library not found. Install a wheel that bundles it, "
        "install metacodes with its SDK, or set METACODES_AGENTCORE_LIB. Tried: "
        + ", ".join(tried)
    )


class ViewArena:
    """Keeps Python bytes alive while C borrows views of them."""

    def __init__(self) -> None:
        self._keep = []

    def view(self, value) -> BytesView:
        if value is None:
            return BytesView(None, 0)
        data = value.encode("utf-8") if isinstance(value, str) else bytes(value)
        if not data:
            return BytesView(None, 0)
        buffer = ctypes.create_string_buffer(data, len(data))
        self._keep.append(buffer)
        return BytesView(ctypes.cast(buffer, ctypes.c_void_p), len(data))

    def views(self, values):
        items = list(values or ())
        if not items:
            return None, 0
        array = (BytesView * len(items))(*[self.view(item) for item in items])
        self._keep.append(array)
        return array, len(items)

    def keep(self, value):
        self._keep.append(value)
        return value


def view_bytes(view: BytesView) -> bytes:
    if not view.ptr or view.len == 0:
        return b""
    return ctypes.string_at(view.ptr, view.len)
