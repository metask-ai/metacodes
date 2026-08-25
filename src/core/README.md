# core/

内核:固定 agent loop、Conversation 投影、Runtime/Session 生命周期、
压缩、工具结果数据面与治理边界。本目录是 `metacodes-core` 的主体。

代表性入口(完整清单以目录为准,共 80+ 文件):

- `agent_loop.zig` — 固定 agent 循环(send → stream → tool → send;
  stop_reason / max_turns / abort 终止)。
- `agent_session.zig` — `AgentRuntime` / `RuntimeHost` / `AgentSession`
  (不可变 generation 语义,见 [doc/LIB_API.md](../../doc/LIB_API.md))。
- `conversation.zig` — 历史与 token 管理;压缩已完整实现于
  `compact_kernel.zig` + `compact_summary.zig`(非 stub)。
- `message.zig` — Message/Content tagged union。
- `system_prompt.zig` / `tool_catalog.zig` / `tool_exec.zig` — 提示词与
  工具目录/执行链。
- `tool_result.zig` / `tool_result_artifact.zig` — inline/artifact/error
  三态工具结果数据面(CAS/spool)。
- `execution_effect.zig` — 持久执行 effect journal。
- `obligation_gate.zig` / `formal` 邻接 — 治理门。

权威架构文档:[doc/CORE_REFERENCE.md](../../doc/CORE_REFERENCE.md)。
