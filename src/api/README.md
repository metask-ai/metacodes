# api/

Provider/HTTP 层:请求构造、SSE 流式解析、provider 方言与能力面。

关键入口(完整清单以目录为准):

- `provider.zig` / `provider_factory.zig` — 中立 Provider 接口与构造;
  HTTP client 本体在上层 `src/client.zig`(不在本目录)。
- `dialect.zig` + `dialects/` — provider 方言(anthropic/openai/gemini 等)的
  确定性请求/响应适配。
- `request.zig` — messages/system/tools/tool_choice 序列化。
- `stream.zig` — 真流式 SSE `EventIterator`(基于 `*std.Io.Reader`)。
- `capability.zig` / `capability_activation.zig` — 请求可见能力面。
- `catalog.zig` / `model_adapter.zig` — 模型目录与 max_tokens/上下文解析。
- `openai_client.zig` / `gemini_client.zig` — 非 Anthropic 协议的具体后端。

架构边界见 [doc/CORE_REFERENCE.md](../../doc/CORE_REFERENCE.md);
prompt-cache 字节契约见 [doc/API.md](../../doc/API.md)。
