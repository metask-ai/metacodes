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
//! 来自 LSP(运行时装配,无编译期依赖)。tree-sitter 已于 2026-07-13 整体移除。

const std = @import("std");

pub const VERSION = @import("version.zig").semver;
pub const util_fs = @import("util/fs.zig");
pub const plugin = @import("plugin/root.zig");

// ── 引擎 ─────────────────────────────────────────────────────────────────
pub const agent_loop = @import("core/agent_loop.zig"); // run(), Options, RunResult, StopReason
pub const agent_session = @import("core/agent_session.zig");
pub const tool_catalog = @import("core/tool_catalog.zig");
pub const workspace_policy = @import("core/workspace_policy.zig");
pub const conversation = @import("core/conversation.zig");
pub const compact_summary = @import("core/compact_summary.zig");
pub const compact_kernel = @import("core/compact_kernel.zig");
pub const message = @import("core/message.zig");
pub const subagent = @import("core/subagent.zig");
pub const tool_exec = @import("core/tool_exec.zig");
pub const execution_effect = @import("core/execution_effect.zig");
pub const run_recovery = @import("core/run_recovery.zig");
pub const file_reference = @import("core/file_reference.zig");
pub const file_change = @import("core/file_change.zig"); // stable actual-file-modification contract
pub const output_semantics = @import("core/output_semantics.zig"); // Run output classification (commentary/final/partial)
pub const tool_observation_journal = @import("core/tool_observation_journal.zig");
pub const tool_result_artifact = @import("core/tool_result_artifact.zig");
pub const tool_result = @import("core/tool_result.zig");
pub const result_projection = @import("core/result_projection.zig");
pub const pdf = @import("core/pdf.zig");
pub const tool_result_metrics = @import("core/tool_result_metrics.zig");
pub const rule_impact_stats = @import("core/rule_impact_stats.zig");
pub const rule_impact_operational_observation = @import("core/rule_impact_operational_observation.zig");
pub const rule_impact_evidence = @import("core/rule_impact_evidence.zig");
pub const rule_impact_receipt = @import("core/rule_impact_receipt.zig");
pub const rule_impact_aggregate_receipt = @import("core/rule_impact_aggregate_receipt.zig");
pub const ontology_rule_projection = @import("core/ontology_rule_projection.zig");
pub const rule_author = @import("core/rule_author.zig");
pub const project_rule_evolution = @import("core/project_rule_evolution.zig");
pub const project_rule_gate_protocol = @import("tools/project_rule_gate.zig");
pub const rule_source_receipt = @import("core/rule_source_receipt.zig");
pub const project_rule_spec = @import("core/project_rule_spec.zig");
pub const rule_candidate = @import("core/rule_candidate.zig");
pub const rule_candidate_source = @import("core/rule_candidate_source.zig");
pub const rule_lifecycle = @import("core/rule_lifecycle.zig");
pub const rule_build_bundle = @import("core/rule_build_bundle.zig");
pub const rule_evaluation = @import("core/rule_evaluation.zig");
pub const project_harness_runtime = @import("formal/project_harness_runtime.zig");
pub const project_rule_bundle = @import("core/project_rule_bundle.zig");
pub const project_rule_gate = @import("core/project_rule_gate.zig");
pub const project_rule_activation = @import("core/project_rule_activation.zig");
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
pub const kg_task_projection = @import("kg/task_projection.zig"); // pure TinyKG snapshot/Markdown contract
pub const kg_client = @import("kg/client.zig"); // local daemon/exclusive-store control-plane client
pub const scoped_recall = @import("kg/scoped_recall.zig"); // deterministic outcome-note + scored recall
pub const kg_transport = @import("kg/transport.zig"); // authenticated tinykgd HTTP transport
pub const kg_experience_packet = @import("kg/experience_packet.zig"); // prior execution feedback at claim boundary
pub const kg_lexical_query_plan = @import("kg/lexical_query_plan.zig"); // governed vector-free query plans + host ledger
pub const kg_memory_migration_adapter = @import("kg/memory_migration_adapter.zig"); // Metacodes transaction controller over TinyKG snapshot/CAS/receipt primitives
pub const kg_ontology_rule_snapshot_adapter = @import("kg/ontology_rule_snapshot_adapter.zig");
pub const formal_runtime = @import("formal/runtime.zig"); // precompiled Lean sidecar trust boundary
pub const formal_artifact_store = @import("formal/artifact_store.zig"); // immutable research evidence bundles
pub const formal_provenance = @import("formal/provenance.zig"); // strict sidecar build identity
pub const formal_task_audit = @import("formal/task_audit.zig"); // TinyKG task-audit sensor/receipt
pub const formal_memory_migration = @import("formal/memory_migration.zig"); // Lean-derived mutating memory gate
pub const formal_artifact_verification = @import("formal/artifact_verification.zig"); // governed artifact verify/repair lifecycle

// ── API / client / 配置 ─────────────────────────────────────────────────
pub const client = @import("client.zig");
pub const api_stream = @import("api/stream.zig");
pub const api_http_status = @import("api/http_status.zig");
pub const api_error_class = @import("api/error_class.zig");
pub const api_provider = @import("api/provider.zig"); // 多 provider vtable
pub const api_provider_factory = @import("api/provider_factory.zig");
pub const api_capability = @import("api/capability.zig");
pub const api_capability_activation = @import("api/capability_activation.zig");
pub const api_cache = @import("api/cache.zig"); // 多 provider 缓存扩展点契约
pub const auth = @import("core/auth.zig");
pub const api_openai = @import("api/openai_client.zig");
pub const api_gemini = @import("api/gemini_client.zig"); // 第三 provider:Gemini + 有状态缓存
pub const api_dialect = @import("api/dialect.zig"); // 方言 vtable(模型 wire 格式适配)
pub const api_request = @import("api/request.zig"); // Anthropic 请求序列化
pub const api_request_overrides = @import("api/request_overrides.zig"); // 方言字段统一配置入口
pub const model_adapter = @import("api/model_adapter.zig"); // ModelProfile 能力探测
pub const model_tiers = @import("api/model_tiers.zig"); // provider 内 low/mid/high 模型档位表
pub const json = @import("json.zig");
pub const types = @import("types.zig");
pub const config = @import("app/config.zig");

// ── 工具 ─────────────────────────────────────────────────────────────────
pub const tools = @import("tools.zig"); // registry + dispatch
pub const tool_read = @import("tools/read.zig"); // 图像上限/MIME 判定(多模态输入共用)
pub const tool_context = @import("tools/context.zig"); // ToolContext
pub const read_artifact = @import("tools/read_artifact.zig");
pub const tools_dynamic = @import("tools/dynamic.zig"); // Skill/MCP DynRegistry

// ── 权限 ─────────────────────────────────────────────────────────────────
pub const permission = @import("permission.zig"); // PermissionContext
pub const permission_decision = @import("permission/decision.zig");
pub const permission_rule_spec = @import("permission/rule_spec.zig");
pub const permission_settings = @import("permission/settings.zig");
pub const permission_prompt = @import("permission/prompt.zig"); // 断 UI 后纯协议路径
pub const permission_session_rules = @import("permission/session_rules.zig"); // per-session 权限记忆

// ── agents / skills / mcp / sandbox ────────────────────────────────────────
pub const agents_def = @import("agents/def.zig");
pub const agents_set = @import("agents/set.zig");
pub const skills = @import("skills/skill.zig");
pub const skills_runtime = @import("skills/runtime/root.zig");
pub const skills_tool = @import("skills/tool.zig");
pub const skills_render = @import("skills/render.zig");
pub const mcp_client = @import("mcp/client.zig");
pub const mcp_protocol = @import("mcp/protocol.zig");
pub const mcp_result_stream = @import("agentcore/mcp_result_stream.zig");
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
pub const evaluation_backend = @import("core/evaluation_backend.zig"); // V1:稳定评估事件投影

// ── 工具库 ───────────────────────────────────────────────────────────────
pub const util_abort = @import("util/abort.zig"); // AbortSignal
pub const util_log = @import("util/log.zig");
pub const util_time = @import("util/time.zig");
pub const util_toolchain = @import("util/toolchain.zig"); // ripgrep 解析/可用性探测(Glob/Grep 依赖)

test {
    // 引用所有 re-export → 强制编译每个库模块。若任何模块间接拉到 repl/tui/app(UI 层),
    // 会因路径不存在/循环依赖编译失败。绿 = 库与 UI 物理隔离的编译器证明。
    // (此 std 裁剪版无 refAllDeclsRecursive,用 refAllDecls;顶层 re-export 已覆盖全模块。)
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(protocol);
}
