# api/

HTTP / Anthropic Messages API 层。

| 文件 | 职责 | 来源（迁移后） |
|---|---|---|
| `client.zig` | `Client.send` / `Client.stream` / `Client.sendWithRetry`；状态码分类；连接生命周期 | `src/client.zig:23-168, 424-451` |
| `stream.zig` | **真流式** `EventIterator`（基于 `*std.Io.Reader`）；Event tagged union；跨 chunk 行累积 | `src/client.zig:185-294` 重写 + `src/json.zig` SSE 部分 |
| `request.zig` | 请求构造：messages / system / tools / tool_choice 序列化 | `src/json.zig:83-192` |
| `response.zig` | 非流式响应解析（如保留） | `src/client.zig:171-345` |

占位目录 — M0.3 拆 json.zig，M1 重写 stream.zig 为真流式。
