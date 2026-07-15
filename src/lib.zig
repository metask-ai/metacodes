//! metacodes-core — 可复用的 LLM 编码-agent 引擎(无 UI、无 CLI)。
//!
//! 这是库的公共面:把 agent 循环层(引擎 + 工具 + 协议 + 权限 + 参考 backend)按命名
//! 空间 re-export 出来,供其他 Zig 项目经 build.zig.zon 依赖 `@import("metacodes-core")`。
//!
//! **不**导出任何 UI/CLI(repl/、repl/tui/、app.zig、main.zig)。本文件可达的模块图
//! 物理上够不到 UI 层 —— `test { refAllDeclsRecursive }` 编全图即编译器证明此隔离。
//!
//! 接入方式见 doc/LIB_API.md;最小示例见 example/main.zig。
//!
//! 注意:库经 tools/* 用到 hl-zig 高亮 module(diff 着色);消费方的 build.zig 须给该 module
//! 接 hl-zig(addImport("hl", ...),纯 Zig 零 C 依赖)。CodeMap/FindSymbol/Read outline 的符号
//! 来自 LSP(运行时 --lsp,无编译期依赖)。tree-sitter 已于 2026-07-13 整体移除。

const std = @import("std");

pub const VERSION = "0.1.0";

// ── 引擎 ─────────────────────────────────────────────────────────────────
pub const agent_loop = @import("core/agent_loop.zig"); // run(), Options, RunResult, StopReason
pub const conversation = @import("core/conversation.zig");
pub const compact_summary = @import("core/compact_summary.zig");
pub const message = @import("core/message.zig");
pub const subagent = @import("core/subagent.zig");
pub const tool_exec = @import("core/tool_exec.zig");
pub const message_repair = @import("core/message_repair.zig");
pub const tool_error = @import("core/tool_error.zig");
pub const read_state = @import("core/read_state.zig");
pub const edit_hl_cache = @import("core/edit_hl_cache.zig");
pub const task_store = @import("core/task_store.zig");
pub const job_registry = @import("core/job_registry.zig");
pub const agent_job_registry = @import("core/agent_job_registry.zig");
pub const cron_registry = @import("core/cron_registry.zig");
pub const cache_break = @import("core/cache_break.zig");
pub const transcript = @import("core/transcript.zig");
pub const session_id = @import("core/session_id.zig"); // SessionId 值类型(多 Session 基石)
pub const system_prompt = @import("core/system_prompt.zig");
pub const answer_queue = @import("core/answer_queue.zig");
pub const recorder = @import("core/recorder.zig");
pub const context_pressure = @import("core/context_pressure.zig");

// ── API / client / 配置 ─────────────────────────────────────────────────
pub const client = @import("client.zig");
pub const api_stream = @import("api/stream.zig");
pub const api_error_class = @import("api/error_class.zig");
pub const api_provider = @import("api/provider.zig"); // 多 provider vtable
pub const api_capability = @import("api/capability.zig");
pub const api_cache = @import("api/cache.zig"); // 多 provider 缓存扩展点契约
pub const api_openai = @import("api/openai_client.zig");
pub const api_gemini = @import("api/gemini_client.zig"); // 第三 provider:Gemini + 有状态缓存
pub const json = @import("json.zig");
pub const types = @import("types.zig");
pub const config = @import("app/config.zig");

// ── 工具 ─────────────────────────────────────────────────────────────────
pub const tools = @import("tools.zig"); // registry + dispatch
pub const tool_context = @import("tools/context.zig"); // ToolContext
pub const tools_dynamic = @import("tools/dynamic.zig"); // Skill/MCP DynRegistry

// ── 权限 ─────────────────────────────────────────────────────────────────
pub const permission = @import("permission.zig"); // PermissionContext
pub const permission_decision = @import("permission/decision.zig");
pub const permission_settings = @import("permission/settings.zig");
pub const permission_prompt = @import("permission/prompt.zig"); // 断 UI 后纯协议路径
pub const permission_session_rules = @import("permission/session_rules.zig"); // per-session 权限记忆

// ── agents / skills / mcp / sandbox ────────────────────────────────────────
pub const agents_def = @import("agents/def.zig");
pub const agents_set = @import("agents/set.zig");
pub const skills = @import("skills/skill.zig");
pub const skills_tool = @import("skills/tool.zig");
pub const mcp_client = @import("mcp/client.zig");
pub const mcp_protocol = @import("mcp/protocol.zig");
pub const sandbox_config = @import("sandbox/config.zig");

// ── 协议(core ↔ UI 契约;实现自定义前端只需这几个)────────────────────────
pub const protocol = struct {
    pub const ui_backend = @import("core/protocol/ui_backend.zig"); // UiBackend vtable
    pub const ui_event = @import("core/protocol/ui_event.zig"); // CoreEvent, UiEvent, ConfigChange
    pub const ui_request = @import("core/protocol/ui_request.zig"); // UiRequest, UiResponse, UiRequestFn
    pub const PermissionChoice = @import("core/protocol/permission_choice.zig").PermissionChoice;
    pub const CHAT_SENTINEL = @import("core/protocol/chat_sentinel.zig").CHAT_SENTINEL;
};
pub const mcp_session = @import("core/mcp_session.zig"); // McpSessionEntry

// ── 参考 backend(库自带的非-UI 前端,可直接用或当模板)────────────────────
pub const writer_backend = @import("core/writer_backend.zig"); // 打印型 sink
pub const headless_backend = @import("core/headless_backend.zig"); // CoreEvent → JSON
pub const suspend_state = @import("core/suspend_state.zig");
pub const tee_backend = @import("core/tee_backend.zig"); // L4:多路转发 decorator
pub const diagnostics_backend = @import("core/diagnostics_backend.zig"); // L4:诊断 trace 后端

// ── 工具库 ───────────────────────────────────────────────────────────────
pub const util_abort = @import("util/abort.zig"); // AbortSignal
pub const util_log = @import("util/log.zig");
pub const util_time = @import("util/time.zig");

test {
    // 引用所有 re-export → 强制编译每个库模块。若任何模块间接拉到 repl/tui/app(UI 层),
    // 会因路径不存在/循环依赖编译失败。绿 = 库与 UI 物理隔离的编译器证明。
    // (此 std 裁剪版无 refAllDeclsRecursive,用 refAllDecls;顶层 re-export 已覆盖全模块。)
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(protocol);
}
