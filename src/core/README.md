# core/

对话核心：消息类型、历史管理、主 agent 循环。

| 文件 | 职责 | 来源（迁移后） |
|---|---|---|
| `message.zig` | Message / Content (tagged union `.text \| .tool_use \| .tool_result`) / ToolUse / ToolResult | `src/types.zig:12-52` 重构 |
| `conversation.zig` | 历史管理、token 估算、compact 接口（compact 本期仅 stub） | `src/types.zig::App.messages` + `src/client.zig::estimateTokens` |
| `agent_loop.zig` | `AgentLoop.run`：send → stream → tool_use → tool_result → send。停止条件：stop_reason / max_turns / abort | `src/main.zig:225-345 runSession` 重写 |
| `system_prompt.zig` | system prompt 常量 | `src/main.zig:160-223` |

占位目录 — M0.4/M0.5 开始填充。**禁止**使用 `__TOOL_RESULT__:` 字符串前缀（现状 hack）。
