//! metacodes-core — 可复用的 LLM 编码-agent 引擎(无 UI、无 CLI)。
//!
//! 这是库的公共面:把 agent 循环层(引擎 + 工具 + 协议 + 权限 + 参考 backend)按命名
//! 空间 re-export 出来,供其他 Zig 项目经 build.zig.zon 依赖 `@import("metacodes-core")`。
//!
//! **不**导出任何 UI/CLI(repl/、repl/tui/、app.zig、main.zig)。编译器证明不了这条隔离:
//! 模块根在 `src/`,任何文件都可 import;惰性分析也不编译没人调用的函数体与 test 块里的
//! import。真正的检查是 `zig build subsystem:boundary`(scripts/subsystem_boundary_gate.zig,
//! #448):从本文件沿每条 `@import`(含函数体、test 块)走闭包,任何进入应用侧(repl/、web/、
//! daemon/、app/、main.zig、app.zig、session_service.zig、session_intent.zig)的边都失败,
//! 只有该脚本里只减不增的 baseline 例外(现在为空);
//! packages/coding/src/core/ 没有 baseline。
//!
//! 接入方式见 doc/LIB_API.md;最小示例见 example/main.zig。
//!
//! 注意:库经 tools/* 用到 hl-zig 高亮 module(diff 着色);消费方的 build.zig 须给该 module
//! 接 hl-zig(addImport("hl", ...),纯 Zig 零 C 依赖)。Read outline 的符号
//! 来自 LSP(运行时装配,无编译期依赖)。tree-sitter 已于 2026-07-13 整体移除。

const std = @import("std");

pub const VERSION = @import("metacodes-base").version.semver;
pub const util_fs = @import("metacodes-base").util.fs;
pub const plugin = @import("metacodes-coding").plugin.root;

// ── 引擎 ─────────────────────────────────────────────────────────────────
pub const agent_loop = @import("metacodes-coding").core.agent_loop; // run(), Options, RunResult, StopReason
pub const skill_rsi = @import("metacodes-coding").skills.rsi; // frozen procedural instructions and local ridge routing
pub const harnessmm = @import("metacodes-coding").core.harnessmm; // EDG / GDR / native callback certificates
pub const agent_session = @import("metacodes-session").core.agent_session;
pub const tool_catalog = @import("metacodes-coding").core.tool_catalog;
pub const workspace_policy = @import("metacodes-guard").core.workspace_policy;
pub const conversation = @import("metacodes-kernel").conversation;
pub const compact_summary = @import("metacodes-coding").core.compact_summary;
pub const compact_kernel = @import("metacodes-coding").core.compact_kernel;
pub const compaction_control = @import("metacodes-coding").core.compaction_control; // durable-state owner seam into Run compaction (#430)
pub const message = @import("metacodes-kernel").message;
pub const subagent = @import("metacodes-coding").core.subagent;
pub const tool_exec = @import("metacodes-coding").core.tool_exec;
pub const execution_effect = @import("metacodes-guard").core.execution_effect;
pub const response_candidate = @import("metacodes-coding").core.response_candidate; // candidate Provider response -> Conversation commit boundary
pub const run_recovery = @import("metacodes-guard").core.run_recovery;
pub const run_input = @import("metacodes-coding").core.run_input; // Host input submitted to an active Run (#270)
pub const file_reference = @import("metacodes-coding").core.file_reference;
pub const file_change = @import("metacodes-guard").core.file_change; // stable actual-file-modification contract
pub const output_semantics = @import("metacodes-guard").core.output_semantics; // Run output classification (commentary/final/partial)
pub const tool_observation_journal = @import("metacodes-guard").core.tool_observation_journal;
pub const tool_result_artifact = @import("metacodes-guard").core.tool_result_artifact;
pub const tool_result = @import("metacodes-coding").core.tool_result;
pub const result_projection = @import("metacodes-coding").core.result_projection;
pub const result_budget = @import("metacodes-kernel").result_budget;
pub const tool_result_metrics = @import("metacodes-coding").core.tool_result_metrics;
pub const rule_impact_stats = @import("metacodes-guard").core.rule_impact_stats;
pub const rule_impact_operational_observation = @import("metacodes-coding").core.rule_impact_operational_observation;
pub const rule_impact_evidence = @import("metacodes-guard").core.rule_impact_evidence;
pub const rule_impact_receipt = @import("metacodes-guard").core.rule_impact_receipt;
pub const rule_impact_aggregate_receipt = @import("metacodes-guard").core.rule_impact_aggregate_receipt;
pub const ontology_rule_projection = @import("metacodes-coding").core.ontology_rule_projection;
pub const rule_author = @import("metacodes-coding").core.rule_author;
pub const project_rule_evolution = @import("metacodes-coding").core.project_rule_evolution;
pub const project_rule_gate_protocol = @import("metacodes-coding").tools.project_rule_gate;
pub const rule_source_receipt = @import("metacodes-coding").core.rule_source_receipt;
pub const project_rule_spec = @import("metacodes-guard").core.project_rule_spec;
pub const rule_candidate = @import("metacodes-coding").core.rule_candidate;
pub const rule_candidate_source = @import("metacodes-coding").core.rule_candidate_source;
pub const rule_lifecycle = @import("metacodes-coding").core.rule_lifecycle;
pub const rule_build_bundle = @import("metacodes-coding").core.rule_build_bundle;
pub const rule_evaluation = @import("metacodes-coding").core.rule_evaluation;
pub const project_harness_runtime = @import("metacodes-guard").formal.project_harness_runtime;
pub const project_rule_bundle = @import("metacodes-coding").core.project_rule_bundle;
pub const project_rule_gate = @import("metacodes-coding").core.project_rule_gate;
pub const project_rule_activation = @import("metacodes-coding").core.project_rule_activation;
pub const message_repair = @import("metacodes-coding").core.message_repair;
pub const tool_error = @import("metacodes-coding").core.tool_error;
pub const read_state = @import("metacodes-coding").core.read_state;
pub const edit_hl_cache = @import("metacodes-coding").core.edit_hl_cache;
pub const task_store = @import("metacodes-coding").core.task_store;
pub const job_registry = @import("metacodes-coding").core.job_registry;
pub const job_notification = @import("metacodes-coding").core.job_notification;
pub const agent_job_registry = @import("metacodes-coding").core.agent_job_registry;
pub const cron_registry = @import("metacodes-coding").core.cron_registry;
pub const cache_break = @import("metacodes-coding").core.cache_break;
pub const transcript = @import("metacodes-coding").core.transcript;
pub const event_journal = @import("metacodes-coding").core.event_journal; // bounded seq+epoch event log for SSE-style replay
pub const session_host = @import("metacodes-session").core.session_host; // multi-session service over AgentSession for network Hosts
pub const typed_submission = @import("metacodes-coding").core.typed_submission; // a submission's source/kind/key/attributes and its template (#447)
pub const idempotency_ledger = @import("metacodes-coding").core.idempotency_ledger; // one Run per idempotency key, across restarts (#447)
pub const session_id = @import("metacodes-kernel").session_id; // SessionId 值类型(多 Session 基石)
pub const system_prompt = @import("metacodes-coding").core.system_prompt;
pub const prompt_sections = @import("metacodes-guard").core.prompt_sections;
pub const context_blocks = @import("metacodes-coding").core.context_blocks;
pub const time_context = @import("metacodes-coding").core.time_context; // date + time zone for the model (#276)
pub const tool_changes = @import("metacodes-coding").core.tool_changes;
pub const skill_changes = @import("metacodes-coding").core.skill_changes;
pub const goal = @import("metacodes-guard").core.goal; // Session goal state and accounting (#277)
pub const swarm_context = @import("metacodes-coding").swarm.context; // Session team membership (#277)
pub const swarm_team = @import("metacodes-coding").swarm.team;
pub const swarm_mailbox = @import("metacodes-coding").swarm.mailbox;
pub const swarm_tools = @import("metacodes-coding").swarm.tools;
pub const teamwork_types = @import("metacodes-teamwork").types; // Teamwork roles, seats, handoff, SeatDriver (#515)
pub const teamwork_config = @import("metacodes-teamwork").config; // `teamwork` config parse/merge/validate
pub const teamwork_run_dir = @import("metacodes-teamwork").run_dir; // per-run state directory (#519)
pub const teamwork_ledger = @import("metacodes-teamwork").ledger; // run budget ledger (#520)
pub const teamwork_issues = @import("metacodes-teamwork").issues; // open_issues.json reviewer-findings ledger (#517)
pub const teamwork_reviewer = @import("metacodes-teamwork").reviewer; // built-in reviewer: charter, review.json, verification (#517)
pub const teamwork_charters = @import("metacodes-teamwork").charters; // role charters (#515)
pub const teamwork_drivers = @import("metacodes-teamwork").drivers.factory; // seat drivers by harness (#515, #521)
pub const teamwork_audit = @import("metacodes-teamwork").audit; // completion audit seam (#516)
pub const teamwork_merge_back = @import("metacodes-teamwork").merge_back; // implementer worktree and merge-back (#523)
pub const teamwork_runtime = @import("metacodes-teamwork").runtime; // run state machine and operations API (#514, #520, #523)
pub const teamwork_swe_loop = @import("metacodes-teamwork").swe_loop; // built-in deterministic manager (#514)
pub const teamwork_verifier_auditor = @import("metacodes-teamwork").verifier_auditor; // completion audit by the isolated verifier (#516)
pub const teamwork_mcp_server = @import("metacodes-teamwork").mcp_server; // approved runtime operations over MCP (#522)
pub const teamwork_progress = @import("metacodes-teamwork").progress;
pub const teamwork_interview = @import("metacodes-teamwork").interview; // request segments, interviewer draft and approval (#518)
pub const teamwork_judge = @import("metacodes-teamwork").judge; // parallel candidates: judge packet, judgment and pitfall lessons (#525)
pub const answer_queue = @import("metacodes-guard").core.answer_queue;
pub const recorder = @import("metacodes-ai").core.recorder;
pub const context_pressure = @import("metacodes-ai").core.context_pressure;
pub const context_caps = @import("metacodes-coding").core.context_caps;
pub const kg_task_projection = @import("metacodes-coding").kg.task_projection; // pure TinyKG snapshot/Markdown contract
pub const kg_client = @import("metacodes-coding").kg.client; // local daemon/exclusive-store control-plane client
pub const scoped_recall = @import("metacodes-coding").kg.scoped_recall; // deterministic outcome-note + scored recall
pub const kg_transport = @import("metacodes-coding").kg.transport; // authenticated tinykgd HTTP transport
pub const kg_experience_packet = @import("metacodes-coding").kg.experience_packet; // prior execution feedback at claim boundary
pub const kg_lesson = @import("metacodes-coding").kg.lesson; // learning-turn lesson envelope, binding and same-task note
pub const kg_lexical_query_plan = @import("metacodes-coding").kg.lexical_query_plan; // governed vector-free query plans + host ledger
pub const jev_question = @import("metacodes-jev").question; // typed System-One questions (Jev-Mem control plane)
pub const jev_client = @import("metacodes-jev").client; // deadline-bounded System-One transport with breaker
pub const jev_advisor = @import("metacodes-jev").advisor; // kernel-owned shadow/advisory decision seam
pub const jev_runtime = @import("metacodes-jev").runtime; // METACODES_JEV_* wiring, address-stable runtime
pub const jev_excerpt = @import("metacodes-jev").excerpt; // query-focused judge excerpts
pub const kg_memory_migration_adapter = @import("metacodes-coding").kg.memory_migration_adapter; // Metacodes transaction controller over TinyKG snapshot/CAS/receipt primitives
pub const kg_ontology_rule_snapshot_adapter = @import("metacodes-coding").kg.ontology_rule_snapshot_adapter;
pub const kgd_identity = @import("metacodes-coding").kg.kgd.identity; // what the local TinyKG service is, and to whom
pub const kgd_bridge = @import("metacodes-coding").kg.kgd.bridge; // one tinykgd child over NDJSON stdio
pub const kgd_server = @import("metacodes-coding").kg.kgd.server; // the authenticated HTTP contract clients speak
pub const kgd_install = @import("metacodes-coding").kg.kgd.install; // provisioning the store, key and configuration
pub const kgd_runtime = @import("metacodes-coding").kg.kgd.runtime; // `metacodes kgd` wiring
pub const formal_runtime = @import("metacodes-guard").formal.runtime; // precompiled Lean sidecar trust boundary
pub const formal_test_kernel = @import("metacodes-guard").formal.test_kernel; // test-only: staged Lean kernel resolution
pub const formal_artifact_store = @import("metacodes-guard").formal.artifact_store; // immutable research evidence bundles
pub const formal_provenance = @import("metacodes-guard").formal.provenance; // strict sidecar build identity
pub const formal_project_provenance = @import("metacodes-guard").formal.project_provenance; // project kernel sidecar build identity (v6 manifest)
pub const formal_task_audit = @import("metacodes-coding").formal.task_audit; // TinyKG task-audit sensor/receipt
pub const formal_memory_migration = @import("metacodes-guard").formal.memory_migration; // Lean-derived mutating memory gate
pub const formal_artifact_verification = @import("metacodes-guard").formal.artifact_verification; // governed artifact verify/repair lifecycle

// ── API / client / 配置 ─────────────────────────────────────────────────
pub const client = @import("metacodes-ai").client;
pub const api_stream = @import("metacodes-ai").api.stream;
pub const api_http_status = @import("metacodes-ai").api.http_status;
pub const api_error_class = @import("metacodes-ai").api.error_class;
pub const api_model_error = @import("metacodes-ai").api.model_error; // per-Run structured detail of a model failure (#408)
pub const api_provider = @import("metacodes-ai").api.provider; // 多 provider vtable
pub const api_provider_factory = @import("metacodes-ai").api.provider_factory;
pub const api_credential_cell = @import("metacodes-ai").api.credential_cell; // a Session's replaceable provider credential (#336)
pub const api_metask_oauth = @import("metacodes-ai").api.metask_oauth;
pub const api_login_worker = @import("metacodes-ai").api.login_worker; // `/login`: a prepared login on a worker thread (#67)
pub const api_capability = @import("metacodes-ai").api.capability;
pub const api_capability_activation = @import("metacodes-ai").api.capability_activation;
pub const api_cache = @import("metacodes-ai").api.cache; // 多 provider 缓存扩展点契约
pub const auth = @import("metacodes-ai").core.auth;
pub const api_openai = @import("metacodes-ai").api.openai_client;
pub const api_gemini = @import("metacodes-ai").api.gemini_client; // 第三 provider:Gemini + 有状态缓存
pub const api_bedrock = @import("metacodes-ai").api.bedrock_client; // Bedrock Converse + AWS event stream
pub const api_aws_event_stream = @import("metacodes-ai").api.aws_event_stream;
pub const provider_metask_catalog = @import("metacodes-ai").provider.metask_catalog;
pub const provider_metask_ledger = @import("metacodes-ai").provider.metask_ledger;
pub const api_dialect = @import("metacodes-ai").api.dialect; // 方言 vtable(模型 wire 格式适配)
pub const api_request = @import("metacodes-ai").api.request; // Anthropic 请求序列化
pub const api_request_overrides = @import("metacodes-ai").api.request_overrides; // 方言字段统一配置入口
pub const model_adapter = @import("metacodes-ai").api.model_adapter; // ModelProfile 能力探测
pub const image_capability = @import("metacodes-ai").api.image_capability; // image input + provenance (#273)
pub const model_tiers = @import("metacodes-ai").api.model_tiers; // provider 内 low/mid/high 模型档位表
pub const json = @import("metacodes-ai").json;
pub const types = @import("metacodes-ai").types;
pub const config = @import("metacodes-coding").core.file_config;
/// Build identity rendering for --version (#78); build.zig hands the app the values, the library only formats them.
pub const version_info = @import("metacodes-base").version_info;
/// metacodes doctor (#78): pure resolution report for the runtime binaries.
pub const doctor = @import("metacodes-coding").core.doctor;

// ── 工具 ─────────────────────────────────────────────────────────────────
pub const tools = @import("metacodes-coding").tools_root; // registry + dispatch
pub const tool_read = @import("metacodes-coding").tools.read; // 图像上限/MIME 判定(多模态输入共用)
pub const tool_context = @import("metacodes-coding").tools.context; // ToolContext
pub const tool_file_target = @import("metacodes-coding").tools.file_target; // Write/Edit 目标文件(AgentCore 按文件授权共用)
pub const tool_args = @import("metacodes-guard").tools.common; // tool-argument admission (#494): canonicalizeArgs / sameArgs
pub const read_artifact = @import("metacodes-coding").tools.read_artifact;
pub const tools_bash_output = @import("metacodes-coding").tools.bash_output; // 预算常量供 schema 防分叉守卫绑定
pub const tools_dynamic = @import("metacodes-coding").tools.dynamic; // Skill/MCP DynRegistry

// ── 权限 ─────────────────────────────────────────────────────────────────
pub const permission = @import("metacodes-guard").permission_root; // PermissionContext
pub const permission_decision = @import("metacodes-guard").permission.decision;
pub const permission_rule_spec = @import("metacodes-guard").permission.rule_spec;
pub const permission_settings = @import("metacodes-guard").permission.settings;
pub const permission_prompt = @import("metacodes-guard").permission.prompt; // 断 UI 后纯协议路径
pub const permission_session_rules = @import("metacodes-guard").permission.session_rules; // per-session 权限记忆

// ── agents / skills / mcp / sandbox ────────────────────────────────────────
pub const agents_def = @import("metacodes-coding").agents.def;
pub const agents_set = @import("metacodes-coding").agents.set;
pub const skills = @import("metacodes-coding").skills.skill;
pub const skills_runtime = @import("metacodes-coding").skills.runtime.root;
// Sealed Skill Protocol (doc/SEALED_SKILL_PROTOCOL.md): wire objects, HTTP
// transport, the client-side provider, pins, and the usage ledger.
pub const skills_sealed_protocol = @import("metacodes-coding").skills.sealed.protocol;
pub const skills_sealed_transport = @import("metacodes-coding").skills.sealed.transport;
pub const skills_sealed_pin = @import("metacodes-coding").skills.sealed.pin;
pub const skills_sealed_ledger = @import("metacodes-coding").skills.sealed.ledger;
pub const skills_sealed_provider = @import("metacodes-coding").skills.sealed.provider;
pub const skills_sealed_gateway = @import("metacodes-coding").skills.sealed.gateway;
pub const skills_sealed_provider_pool = @import("metacodes-coding").skills.sealed.provider_pool;
pub const skills_sealed_credentials = @import("metacodes-coding").skills.sealed.credentials;
pub const skills_sealed_disclosure = @import("metacodes-coding").skills.sealed.disclosure;
pub const skills_tool = @import("metacodes-coding").skills.tool;
pub const skills_render = @import("metacodes-coding").skills.render;
pub const mcp_client = @import("metacodes-coding").mcp.client;
pub const mcp_protocol = @import("metacodes-coding").mcp.protocol;
pub const mcp_config = @import("metacodes-coding").mcp.config;
pub const mcp_launch = @import("metacodes-coding").mcp.launch;
pub const mcp_naming = @import("metacodes-guard").mcp.naming;
pub const mcp_oauth = @import("metacodes-coding").mcp.oauth;
pub const mcp_url = @import("metacodes-coding").mcp.url;
pub const mcp_result_stream = @import("metacodes-coding").mcp.result_stream;
pub const mcp_canonical = @import("metacodes-coding").mcp.canonical;
pub const mcp_wire = @import("metacodes-coding").mcp.wire;
pub const mcp_negotiation = @import("metacodes-coding").mcp.negotiation;
pub const mcp_schema = @import("metacodes-coding").mcp.schema;
pub const mcp_host_transport = @import("metacodes-coding").mcp.host_transport;
pub const mcp_runtime = @import("metacodes-coding").mcp.runtime;
pub const mcp_instance_pool = @import("metacodes-coding").mcp.instance_pool;
pub const mcp_catalog = @import("metacodes-coding").mcp.catalog;
pub const mcp_test_support = @import("metacodes-coding").mcp.test_support;
pub const mcp_conformance = @import("metacodes-coding").mcp.conformance;
pub const mcp_tool_invocation = @import("metacodes-coding").mcp.tool_invocation;
pub const mcp_registry_bridge = @import("metacodes-coding").mcp.registry_bridge;
pub const mcp_result_commit_test = @import("metacodes-coding").mcp.result_commit_test;
pub const sandbox_config = @import("metacodes-guard").sandbox.config;
/// Platform sandbox discovery used by embedded hosts at Session admission.
pub const sandbox_exec = @import("metacodes-guard").sandbox.exec;

// ── 协议(core ↔ UI 契约;实现自定义前端只需这几个)────────────────────────
pub const protocol = struct {
    pub const ui_backend = @import("metacodes-guard").core.protocol.ui_backend; // UiBackend vtable
    pub const ui_event = @import("metacodes-guard").core.protocol.ui_event; // CoreEvent, UiEvent, ConfigChange
    pub const ui_request = @import("metacodes-guard").core.protocol.ui_request; // UiRequest, UiResponse, UiRequestFn
    pub const wire = @import("metacodes-coding").core.protocol.wire; // versioned JSON lines for out-of-process Hosts
    pub const frontend_capabilities = @import("metacodes-coding").core.protocol.frontend_capabilities; // what a cross-process frontend renders; request routing
    pub const PermissionChoice = @import("metacodes-guard").core.protocol.permission_choice.PermissionChoice;
    pub const CHAT_SENTINEL = @import("metacodes-coding").core.protocol.chat_sentinel.CHAT_SENTINEL;
};
pub const mcp_session = @import("metacodes-coding").core.mcp_session; // McpSessionEntry

// ── 参考 backend(库自带的非-UI 前端,可直接用或当模板)────────────────────
pub const writer_backend = @import("metacodes-coding").core.writer_backend; // 打印型 sink
pub const headless_backend = @import("metacodes-coding").core.headless_backend; // CoreEvent → JSON
pub const suspend_state = @import("metacodes-coding").core.suspend_state;
pub const ui_request_store = @import("metacodes-coding").core.ui_request_store; // a SessionHost Session's request ids and suspended request (#446)
pub const tee_backend = @import("metacodes-coding").core.tee_backend; // L4:多路转发 decorator
pub const diagnostics_backend = @import("metacodes-coding").core.diagnostics_backend; // L4:诊断 trace 后端
pub const evaluation_backend = @import("metacodes-coding").core.evaluation_backend; // V1:稳定评估事件投影
pub const telemetry = @import("metacodes-telemetry").telemetry; // OpenTelemetry spans: recorder, OTLP exporter, session store

// ── 工具库 ───────────────────────────────────────────────────────────────
pub const util_abort = @import("metacodes-base").util.abort; // AbortSignal
pub const util_log = @import("metacodes-base").util.log;
pub const util_time = @import("metacodes-base").util.time;
pub const util_json = @import("metacodes-base").util.json;
pub const util_toolchain = @import("metacodes-base").util.toolchain; // ripgrep 解析/可用性探测(Glob/Grep 依赖)
pub const util_state_root = @import("metacodes-base").util.state_root; // per-install state root (--state-dir / METACODES_HOME / install.json / ~/.metacodes)

test {
    // 引用所有 re-export → 编译每个库模块的公开声明及其测试。这证明库能单独编译,
    // **不**证明它与 UI 隔离:refAllDecls 不递归,惰性分析也跳过没人调用的 import;
    // 隔离由 `zig build subsystem:boundary` 在源码层检查(见文件头)。
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(protocol);
    // Test-only: no re-export reaches it (see the file's header).
    _ = &@import("metacodes-coding").api.model_name_consumers_test;
    _ = &@import("metacodes-teamwork").stub_driver;
    _ = &@import("metacodes-teamwork").drivers.common;
    _ = &@import("metacodes-teamwork").drivers.write_scope;
    _ = &@import("metacodes-teamwork").drivers.metacodes;
    _ = &@import("metacodes-teamwork").drivers.claude_code;
    _ = &@import("metacodes-teamwork").drivers.drivers_test;
    _ = &@import("metacodes-teamwork").runtime_test;
    _ = &@import("metacodes-teamwork").interview;
    _ = &@import("metacodes-teamwork").progress;
    // Reached through the Bash tool, not re-exported: name it so its own tests run.
    _ = &@import("metacodes-coding").core.command_file_changes;
}
