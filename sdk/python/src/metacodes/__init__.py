"""Embed the metacodes agent runtime in Python.

    import metacodes

    with metacodes.Runtime(tools=["Read", "Glob", "Grep"]) as runtime:
        session = runtime.session("claude-sonnet-4-5", workspace=".")
        result = session.run("Summarize this repository in three lines.")
        print(result.text)

The package talks to the AgentCore C ABI (``libmetask_agentcore``) through
ctypes and has no third-party dependencies. See README.md for the library
lookup order, events, Python tools and permission requests.
"""

from ._client import (
    DEFAULT_TOOLS,
    EventStream,
    ModelError,
    RunResult,
    Runtime,
    Session,
    Tool,
    UiRequest,
    tool,
)
from ._native import ABI_REVISION, BUILTIN_TOOLS, AgentCoreError, candidate_library_paths

__version__ = "0.13.0.dev0"

__all__ = [
    "ABI_REVISION",
    "AgentCoreError",
    "BUILTIN_TOOLS",
    "DEFAULT_TOOLS",
    "EventStream",
    "ModelError",
    "RunResult",
    "Runtime",
    "Session",
    "Tool",
    "UiRequest",
    "candidate_library_paths",
    "tool",
    "__version__",
]
