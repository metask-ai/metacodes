const std = @import("std");
const model_name = @import("metacodes-internal").api.model_name;
const builtin = @import("builtin");
const platform_term = @import("metacodes-internal").platform.terminal;
const terminal_prompt = @import("app/terminal_prompt.zig");
const pfs = @import("metacodes-internal").platform.fs;
const platform_signal = @import("metacodes-internal").platform.signal;
const platform_net = @import("metacodes-internal").platform.net;
const types = @import("metacodes-internal").types;
const client = @import("metacodes-internal").client;
const app_mod = @import("app.zig");
const repl = @import("repl/loop.zig");
const auth = @import("metacodes-internal").core.auth;
const api_keys_mod = @import("metacodes-internal").api.api_keys;
const oauth_login = @import("metacodes-internal").api.oauth_login;
const provider_login = @import("metacodes-internal").api.provider_login;
const openrouter_login = @import("metacodes-internal").api.openrouter_login;
const openrouter_catalog = @import("metacodes-internal").api.openrouter_catalog;
const metask_oauth_mod = @import("metacodes-internal").api.metask_oauth;
const oauth_exchange_mod = @import("metacodes-internal").api.oauth_exchange;
const catalog_mod = @import("metacodes-internal").api.catalog;
const provider_oauth_mod = @import("metacodes-internal").provider.oauth;
const provider_ids_mod = @import("metacodes-internal").provider.ids;
const version_info = @import("metacodes-internal").version_info;
const invocation = @import("app/invocation.zig");
const teammate_route_mod = @import("app/teammate_route.zig");
pub const doctor = @import("metacodes-internal").core.doctor; // pub: component tests build the report by hand
pub const app_state_env = @import("app/state_env.zig"); // pub: component tests read the template and the parser
const state_env_mod = app_state_env;
pub const app_route_state = @import("app/route_state.zig"); // pub: component tests read the banner and the reminder
const route_state_mod = app_route_state;
pub const app_sign_out = @import("app/sign_out.zig"); // pub: component tests sign out in process
const sign_out_mod = app_sign_out;
const app_startup_order = @import("app/startup_order.zig");
const startup_order = app_startup_order;
pub const app_presets = @import("app/presets.zig");
const presets_mod = app_presets;
pub const kgd_server = @import("metacodes-internal").kg.kgd.server; // pub: component tests drive a real supervisor
pub const kgd_install = @import("metacodes-internal").kg.kgd.install;
pub const kgd_runtime_exports = @import("metacodes-internal").kg.kgd.runtime; // pub: the component test exercises the install-to-service handoff
pub const kg_autostart = @import("app/kg_autostart.zig"); // pub: the component test drives the host start against a squatted port
const kgd_runtime = @import("metacodes-internal").kg.kgd.runtime;
const build_options = @import("build_info");

pub const VERSION = @import("metacodes-internal").version.semver;

/// `unexpected_error_tracing`: Debug builds of Zig 0.16.0 print
/// `error.Unexpected NTSTATUS=…` and a stack trace to stderr for every status
/// the Windows network layer does not map. Esc aborts the reply's socket
/// (CONNECTION_ABORTED on the next read) and the trace landed on top of the
/// TUI (#221). The error itself still propagates and is logged where it is
/// handled; only the unconditional print goes. A test binary's root is the
/// test runner, so the evidence is the TTY case
/// `test_refused_endpoint_retries_without_system_error_noise`.
///
/// `signal_stack_size`: std gives every thread a 256 KiB alternate signal
/// stack, a `threadlocal` array that only std's segfault handler runs on, and
/// std installs that handler only in builds with runtime safety. glibc zeroes
/// a thread's whole static TLS block when it sets the thread up, so in the
/// ReleaseSmall binary the unused stack was 256 KiB of RSS in every thread,
/// the main one included (the idle red line of
/// doc/PERF_MEMORY_PRINCIPLES.md §2). Builds that install the handler keep it.
///
/// `allow_stack_tracing`: std defaults it to "built with debug info", and on it
/// links in about 100 KB of std.debug unwinding code. The ReleaseSmall executable never
/// traces. A stripped build already has it off, and is byte-identical with or
/// without this line. With `-Drelease-symbols` the executable links with DWARF
/// for the split symbol file, and this keeps its code within a few bytes of
/// the stripped build's (doc/RELEASE_RUNNER.md, "Debug symbols").
pub const std_options: std.Options = .{
    .unexpected_error_tracing = false,
    .signal_stack_size = if (std.debug.default_enable_segfault_handler) (std.Options{}).signal_stack_size else null,
    .allow_stack_tracing = !builtin.strip_debug_info and builtin.mode != .ReleaseSmall,
};

/// Panics go through the default handler (message, stack trace, abort), after
/// the TUI writes the reply text its merge window still holds (#328) and turns
/// off the terminal modes it turned on.
pub const panic = std.debug.FullPanic(panicAfterPendingOutput);

fn panicAfterPendingOutput(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    _ = tui_render_region.flushPendingOnPanic();
    @import("repl/input.zig").rescueTerminal();
    std.debug.defaultPanic(msg, first_trace_addr);
}

// Public re-exports for tests and future consumers.
pub const api_stream = @import("metacodes-internal").api.stream;
pub const api_provider = @import("metacodes-internal").api.provider;
pub const api_provider_factory = @import("metacodes-internal").api.provider_factory;
pub const api_auth_header = @import("metacodes-internal").api.auth_header;
pub const api_credential_cell = @import("metacodes-internal").api.credential_cell;
pub const api_connection_gate = @import("metacodes-internal").api.connection_gate;
pub const fs_util = @import("metacodes-internal").util.fs;
// issue #16 provider offer kernel — re-exported for L2 component tests and for
// embedders that drive model selection through the control plane.
pub const provider_ids = @import("metacodes-internal").provider.ids;
pub const provider_offer = @import("metacodes-internal").provider.offer;
pub const provider_controls = @import("metacodes-internal").provider.controls;
pub const provider_credential = @import("metacodes-internal").provider.credential;
pub const provider_profile = @import("metacodes-internal").provider.profile;
pub const provider_registry = @import("metacodes-internal").provider.registry;
pub const provider_selection = @import("metacodes-internal").provider.selection;
pub const provider_config_doc = @import("metacodes-internal").provider.config_doc;
pub const provider_config_store = @import("metacodes-internal").provider.config_store;
pub const provider_control_plane = @import("metacodes-internal").provider.control_plane;
pub const provider_runtime_binding = @import("metacodes-internal").provider.runtime_binding;
pub const provider_startup = @import("metacodes-internal").provider.startup;
pub const provider_host = @import("metacodes-internal").provider.host;
pub const provider_alias = @import("metacodes-internal").provider.alias;
pub const provider_custom = @import("metacodes-internal").provider.custom_provider;
pub const provider_oauth = @import("metacodes-internal").provider.oauth;
pub const provider_api_key_store = @import("metacodes-internal").provider.api_key_store;
pub const provider_metask_catalog = @import("metacodes-internal").provider.metask_catalog;
pub const provider_metask_ledger = @import("metacodes-internal").provider.metask_ledger;
pub const kg_provider_audit = @import("metacodes-internal").kg.provider_audit;
pub const api_oauth_exchange = @import("metacodes-internal").api.oauth_exchange;
pub const api_oauth_login = @import("metacodes-internal").api.oauth_login;
pub const api_oauth_revoke = @import("metacodes-internal").api.oauth_revoke; // L2 reads a provider sign-out's revocation outcome
pub const api_provider_login = @import("metacodes-internal").api.provider_login;
pub const api_openrouter_login = @import("metacodes-internal").api.openrouter_login;
pub const api_openrouter_catalog = @import("metacodes-internal").api.openrouter_catalog;
pub const api_login_worker = @import("metacodes-internal").api.login_worker;
pub const api_metask_sign_in = @import("metacodes-internal").api.metask_sign_in; // `/login`'s browser sign-in on a worker (#485)
pub const api_metask_oauth = @import("metacodes-internal").api.metask_oauth;
pub const api_catalog_fetch = @import("metacodes-internal").api.catalog_fetch;
pub const api_capability = @import("metacodes-internal").api.capability;
pub const api_capability_activation = @import("metacodes-internal").api.capability_activation;
pub const api_cache = @import("metacodes-internal").api.cache;
pub const api_http_status = @import("metacodes-internal").api.http_status;
pub const api_http_connection = @import("metacodes-internal").api.http_connection; // L2 send-failure tests drive it on a raw std client
pub const api_openai = @import("metacodes-internal").api.openai_client;
pub const api_gemini = @import("metacodes-internal").api.gemini_client;
pub const api_bedrock = @import("metacodes-internal").api.bedrock_client; // Bedrock Converse + AWS event stream
pub const api_aws_event_stream = @import("metacodes-internal").api.aws_event_stream;
pub const api_dialect = @import("metacodes-internal").api.dialect;
pub const api_request = @import("metacodes-internal").api.request;
pub const api_request_overrides = @import("metacodes-internal").api.request_overrides;
pub const model_adapter = @import("metacodes-internal").api.model_adapter;
pub const time_context = @import("metacodes-internal").core.time_context; // date + time zone for the model (#276)
pub const tool_changes = @import("metacodes-internal").core.tool_changes;
pub const skill_changes = @import("metacodes-internal").core.skill_changes;
pub const image_capability = @import("metacodes-internal").api.image_capability;
pub const model_tiers = @import("metacodes-internal").api.model_tiers;
pub const model_availability = @import("metacodes-internal").api.model_availability; // tier names + provider guard, shared by /model, web/daemon messages and SessionHost (#445)
pub const client_mod = client; // alias for L2 component tests
pub const api_api_keys = api_keys_mod;
pub const api_model_error = @import("metacodes-internal").api.model_error; // L2 provider lifecycle tests read the structured failure detail
pub const api_last_error = @import("metacodes-internal").api.last_error; // L2 stream liveness tests read the TUI-facing error text
pub const task_store = @import("metacodes-internal").core.task_store; // L2 requirement-ledger tests
pub const requirement_ledger = @import("metacodes-internal").core.requirement_ledger; // L2 ledger decide tests
pub const delivery_cadence = @import("metacodes-internal").core.delivery_cadence; // L2 delivery-cadence tests
pub const progress_updates = @import("metacodes-internal").core.progress_updates; // L2 progress-update tests (#114)
pub const check_gate = @import("metacodes-internal").core.check_gate; // L2 host check gate / Stop hook block tests
pub const isolated_verifier = @import("metacodes-internal").core.isolated_verifier; // L2 isolated verifier tests
pub const agent_isolation = @import("metacodes-internal").agents.isolation; // L2 verifier snapshot tests
pub const learning_turn = @import("metacodes-internal").core.learning_turn; // L2 learning turn tests
pub const learning_end_of_run = @import("metacodes-internal").core.learning_end_of_run; // L2 end-of-run learning turn tests
pub const kg_lesson = @import("metacodes-internal").kg.lesson; // lesson envelope (learning turn)
pub const test_integrity = @import("metacodes-internal").core.test_integrity; // L2 test-integrity obligation tests
pub const stall_gate = @import("metacodes-internal").core.stall_gate; // L2 stall-gate tests
pub const types_mod = types;
pub const json_mod = @import("metacodes-internal").json;
pub const util_abort = @import("metacodes-internal").util.abort;
pub const util_fs = @import("metacodes-internal").util.fs;
pub const util_file_lock = @import("metacodes-internal").util.file_lock;
pub const conversation = @import("metacodes-internal").core.conversation;
pub const message = @import("metacodes-internal").core.message;
pub const compact_summary = @import("metacodes-internal").core.compact_summary;
pub const agent_loop = @import("metacodes-internal").core.agent_loop;
pub const harnessmm = @import("metacodes-internal").core.harnessmm;
pub const skill_rsi = @import("metacodes-internal").skills.rsi;
pub const agent_session = @import("metacodes-internal").core.agent_session;
pub const execution_effect = @import("metacodes-internal").core.execution_effect;
pub const response_candidate = @import("metacodes-internal").core.response_candidate;
pub const compaction_control = @import("metacodes-internal").core.compaction_control;
pub const run_recovery = @import("metacodes-internal").core.run_recovery;
pub const run_input = @import("metacodes-internal").core.run_input;
pub const plugin = @import("metacodes-internal").plugin.root;
pub const tool_catalog = @import("metacodes-internal").core.tool_catalog;
pub const workspace_policy = @import("metacodes-internal").core.workspace_policy;
pub const core_subagent = @import("metacodes-internal").core.subagent;
pub const agent_job_registry = @import("metacodes-internal").core.agent_job_registry;
pub const job_registry = @import("metacodes-internal").core.job_registry;
pub const util_time = @import("metacodes-internal").util.time;
pub const models_cache = @import("metacodes-internal").api.models_cache;
pub const util_json = @import("metacodes-internal").util.json;
pub const util_toolchain = @import("metacodes-internal").util.toolchain;
pub const tools = @import("metacodes-internal").tools_root;
pub const tool_prompt_ctx = @import("metacodes-internal").tools.prompt_context;
pub const task_tools = @import("metacodes-internal").tools.task_tools;
pub const task_output_tool = @import("metacodes-internal").tools.task_output;
pub const agent_tool = @import("metacodes-internal").tools.agent;
pub const core_task_store = @import("metacodes-internal").core.task_store;
pub const kg_client = @import("metacodes-internal").kg.client;
pub const scoped_recall = @import("metacodes-internal").kg.scoped_recall;
pub const kg_transport = @import("metacodes-internal").kg.transport;
pub const swarm_team = @import("metacodes-internal").swarm.team;
pub const swarm_mailbox = @import("metacodes-internal").swarm.mailbox;
pub const swarm_teammate = @import("metacodes-internal").swarm.teammate;
pub const swarm_context = @import("metacodes-internal").swarm.context;
pub const swarm_tools = @import("metacodes-internal").swarm.tools;
pub const swarm_teammate_process = @import("metacodes-internal").swarm.teammate_process;
pub const tools_common = @import("metacodes-internal").tools.common;
pub const platform_fs = @import("metacodes-internal").platform.fs;
pub const platform_test_support = @import("metacodes-internal").platform.test_support; // 组件测试的链接/枚举夹具
pub const kg_inject = @import("metacodes-internal").kg.inject;
pub const kg_scoped_recall = @import("metacodes-internal").kg.scoped_recall;
pub const abort = @import("metacodes-internal").util.abort;
pub const kg_plan_commit = @import("metacodes-internal").kg.plan_commit;
pub const kg_plan_view = @import("metacodes-internal").kg.plan_view;
pub const kg_task_projection = @import("metacodes-internal").kg.task_projection;
pub const formal_runtime = @import("metacodes-internal").formal.runtime;
pub const formal_test_kernel = @import("metacodes-internal").formal.test_kernel; // test-only: staged Lean kernel resolution
pub const util_state_root = @import("metacodes-internal").util.state_root;
pub const formal_artifact_store = @import("metacodes-internal").formal.artifact_store;
pub const formal_provenance = @import("metacodes-internal").formal.provenance;
pub const formal_task_audit = @import("metacodes-internal").formal.task_audit;
pub const formal_memory_migration = @import("metacodes-internal").formal.memory_migration;
pub const kg_memory_migration_adapter = @import("metacodes-internal").kg.memory_migration_adapter;
pub const kg_ontology_rule_snapshot_adapter = @import("metacodes-internal").kg.ontology_rule_snapshot_adapter;
pub const formal_artifact_verification = @import("metacodes-internal").formal.artifact_verification;
pub const kg_tools = @import("metacodes-internal").tools.kg_tools;
pub const kg_lexical_query_plan = @import("metacodes-internal").kg.lexical_query_plan;
pub const jev_question = @import("metacodes-internal").jev.question;
pub const jev_client = @import("metacodes-internal").jev.client;
pub const jev_advisor = @import("metacodes-internal").jev.advisor;
pub const jev_runtime = @import("metacodes-internal").jev.runtime;
pub const jev_excerpt = @import("metacodes-internal").jev.excerpt;
pub const telemetry = @import("metacodes-internal").telemetry.telemetry;
pub const core_goal = @import("metacodes-internal").core.goal;
pub const core_auth = auth;
pub const core_read_state = @import("metacodes-internal").core.read_state;
pub const core_context_caps = @import("metacodes-internal").core.context_caps;
pub const core_context_pressure = @import("metacodes-internal").core.context_pressure;
pub const core_edit_hl_cache = @import("metacodes-internal").core.edit_hl_cache;
pub const tool_exec = @import("metacodes-internal").core.tool_exec;
pub const file_change = @import("metacodes-internal").core.file_change;
pub const file_reference = @import("metacodes-internal").core.file_reference;
pub const output_semantics = @import("metacodes-internal").core.output_semantics;
pub const message_repair = @import("metacodes-internal").core.message_repair;
pub const tool_result_artifact = @import("metacodes-internal").core.tool_result_artifact;
pub const tool_result = @import("metacodes-internal").core.tool_result;
pub const result_projection = @import("metacodes-internal").core.result_projection;
pub const result_budget = @import("metacodes-internal").core.result_budget;
pub const tool_result_metrics = @import("metacodes-internal").core.tool_result_metrics;
pub const read_artifact = @import("metacodes-internal").tools.read_artifact;
pub const tools_bash_output = @import("metacodes-internal").tools.bash_output; // 预算常量供 schema 防分叉守卫绑定
pub const result_spool = @import("metacodes-internal").tools.result_spool; // 内联阈值缝合点,供 L2 行为测试直接驱动
pub const cache_break = @import("metacodes-internal").core.cache_break;
pub const core_message = @import("metacodes-internal").core.message;
pub const transcript = @import("metacodes-internal").core.transcript;
pub const repl_headless = @import("repl/headless.zig");
pub const repl_next_step = @import("repl/next_step.zig"); // pub: the component test reads the route a /model pick moved to
pub const repl_stream_json = @import("repl/stream_json_backend.zig");
pub const repl_loop = @import("repl/loop.zig");
pub const app_module = @import("app.zig");
pub const teamwork_command = @import("metacodes-internal").teamwork.command;
pub const teamwork_runtime = @import("metacodes-internal").teamwork.runtime;
pub const teamwork_config = @import("metacodes-internal").teamwork.config;
pub const teamwork_types = @import("metacodes-internal").teamwork.types;
pub const teamwork_progress = @import("metacodes-internal").teamwork.progress;
// Integration binds the MCP server here; all preparation and lifecycle
// ownership remain in teamwork_command (stdin/stdout belong to the callback).
pub const teamwork_mcp_server = @import("metacodes-internal").teamwork.mcp_server;
pub const teamwork_mcp_host: ?teamwork_command.McpHost = .{ .serveFn = serveTeamworkMcp };

fn serveTeamworkMcp(gpa: std.mem.Allocator, run: *@import("metacodes-internal").teamwork.runtime.Run) !void {
    var server = teamwork_mcp_server.Server.init(gpa, run);
    try server.serve();
}
pub const app_route_strings = @import("app/route_strings.zig");
pub const app_mcp_startup = @import("app/mcp_startup.zig");
pub const app_mcp_hotplug = @import("app/mcp_hotplug.zig");
pub const app_install = @import("app/install.zig");
pub const app_update = @import("app/update.zig");
pub const app_release_source = @import("app/release_source.zig");
pub const app_archive_fixture = @import("app/archive_fixture.zig");
pub const tool_context = @import("metacodes-internal").tools.context;
pub const project_rule_gate_protocol = @import("metacodes-internal").tools.project_rule_gate;
pub const tool_error = @import("metacodes-internal").core.tool_error;
pub const bash = @import("metacodes-internal").tools.bash;
pub const read_tool = @import("metacodes-internal").tools.read;
pub const code_map_tool = @import("metacodes-internal").tools.code_map;
pub const find_symbol_tool = @import("metacodes-internal").tools.find_symbol;
pub const symbol_provider = @import("metacodes-internal").tools.symbol_provider;
pub const lsp = @import("metacodes-internal").lsp.lsp;
pub const write_tool = @import("metacodes-internal").tools.write;
pub const edit_tool = @import("metacodes-internal").tools.edit;
pub const mcp_client = @import("metacodes-internal").mcp.client;
pub const mcp_transport_http = @import("metacodes-internal").mcp.transport_http;
pub const mcp_transport_sse = @import("metacodes-internal").mcp.transport_sse;
pub const mcp_transport = @import("metacodes-internal").mcp.transport;
pub const mcp_oauth = @import("metacodes-internal").mcp.oauth;
pub const mcp_url = @import("metacodes-internal").mcp.url;
pub const mcp_protocol = @import("metacodes-internal").mcp.protocol;
pub const mcp_config = @import("metacodes-internal").mcp.config;
pub const mcp_launch = @import("metacodes-internal").mcp.launch;
pub const mcp_naming = @import("metacodes-internal").mcp.naming;
pub const mcp_registry_bridge = @import("metacodes-internal").mcp.registry_bridge;
pub const mcp_session = @import("metacodes-internal").core.mcp_session;
pub const skills = @import("metacodes-internal").skills.skill;
pub const skill_overrides = @import("metacodes-internal").skills.overrides;
pub const skills_runtime = @import("metacodes-internal").skills.runtime.root;
pub const skills_cli_adapter = @import("metacodes-internal").skills.cli_adapter;
pub const skills_sealed_protocol = @import("metacodes-internal").skills.sealed.protocol;
pub const skills_sealed_transport = @import("metacodes-internal").skills.sealed.transport;
pub const skills_sealed_pin = @import("metacodes-internal").skills.sealed.pin;
pub const skills_sealed_ledger = @import("metacodes-internal").skills.sealed.ledger;
pub const skills_sealed_provider = @import("metacodes-internal").skills.sealed.provider;
pub const skills_sealed_gateway = @import("metacodes-internal").skills.sealed.gateway;
pub const skills_sealed_provider_pool = @import("metacodes-internal").skills.sealed.provider_pool;
pub const skills_sealed_credentials = @import("metacodes-internal").skills.sealed.credentials;
pub const skills_sealed_disclosure = @import("metacodes-internal").skills.sealed.disclosure;
pub const skills_tool = @import("metacodes-internal").skills.tool;
pub const skills_render = @import("metacodes-internal").skills.render;
pub const skills_discovery = @import("metacodes-internal").skills.discovery;
pub const active_skill = @import("metacodes-internal").skills.active;
pub const permission = @import("metacodes-internal").permission_root;
pub const permission_session_rules = @import("metacodes-internal").permission.session_rules;
pub const permission_rule_spec = @import("metacodes-internal").permission.rule_spec;
pub const permission_settings = @import("metacodes-internal").permission.settings;
pub const permission_decision = @import("metacodes-internal").permission.decision;
pub const permission_bash_readonly = @import("metacodes-internal").permission.bash_readonly; // L2:Bash 免询问/并发只读判定
pub const permission_hooks = @import("metacodes-internal").permission.hooks;
pub const sandbox_profile = @import("metacodes-internal").sandbox.profile;
pub const sandbox_config = @import("metacodes-internal").sandbox.config; // L2 测试构造 SandboxSettings
pub const sandbox_exec = @import("metacodes-internal").sandbox.exec; // L2:本机是否真有沙箱(autoAllowBashIfSandboxed 期望值)
pub const agents_def = @import("metacodes-internal").agents.def;
pub const agents_set = @import("metacodes-internal").agents.set;
pub const agents_filter = @import("metacodes-internal").agents.filter;
pub const agents_preload = @import("metacodes-internal").agents.preload;
pub const tools_dynamic = @import("metacodes-internal").tools.dynamic;
pub const tools_task_batch = @import("metacodes-internal").tools.task_batch;
pub const system_prompt = @import("metacodes-internal").core.system_prompt;
pub const prompt_sections = @import("metacodes-internal").core.prompt_sections;
pub const user_context = @import("metacodes-internal").core.memory.user_context;
pub const memdir = @import("metacodes-internal").core.memory.memdir;
pub const util_log = @import("metacodes-internal").util.log;
pub const tui_render_region = @import("repl/tui/render_region.zig");
pub const ui_event = @import("metacodes-internal").core.protocol.ui_event;
pub const ui_backend = @import("metacodes-internal").core.protocol.ui_backend;
pub const ui_request = @import("metacodes-internal").core.protocol.ui_request;
pub const wire = @import("metacodes-internal").core.protocol.wire;
pub const frontend_capabilities = @import("metacodes-internal").core.protocol.frontend_capabilities;
pub const session_id = @import("metacodes-internal").core.session_id;
pub const tui_backend = @import("repl/tui/tui_backend.zig");
pub const writer_backend = @import("metacodes-internal").core.writer_backend;
pub const headless_backend = @import("metacodes-internal").core.headless_backend;
pub const suspend_state = @import("metacodes-internal").core.suspend_state;
pub const ui_request_store = @import("metacodes-internal").core.ui_request_store;
pub const tee_backend = @import("metacodes-internal").core.tee_backend;
pub const diagnostics_backend = @import("metacodes-internal").core.diagnostics_backend;
pub const evaluation_backend = @import("metacodes-internal").core.evaluation_backend;
pub const tool_observation_journal = @import("metacodes-internal").core.tool_observation_journal;
pub const rule_impact_stats = @import("metacodes-internal").core.rule_impact_stats;
pub const rule_impact_operational_observation = @import("metacodes-internal").core.rule_impact_operational_observation;
pub const rule_impact_evidence = @import("metacodes-internal").core.rule_impact_evidence;
pub const rule_impact_receipt = @import("metacodes-internal").core.rule_impact_receipt;
pub const rule_impact_aggregate_receipt = @import("metacodes-internal").core.rule_impact_aggregate_receipt;
pub const ontology_rule_projection = @import("metacodes-internal").core.ontology_rule_projection;
pub const rule_author = @import("metacodes-internal").core.rule_author;
pub const project_rule_evolution = @import("metacodes-internal").core.project_rule_evolution;
pub const self_evolution = @import("metacodes-internal").core.self_evolution;
pub const verdict = @import("metacodes-internal").core.verdict;
pub const host_check = @import("metacodes-internal").core.host_check;
pub const obligation_gate = @import("metacodes-internal").core.obligation_gate;
pub const rule_source_receipt = @import("metacodes-internal").core.rule_source_receipt;
pub const project_rule_spec = @import("metacodes-internal").core.project_rule_spec;
pub const rule_candidate = @import("metacodes-internal").core.rule_candidate;
pub const rule_lifecycle = @import("metacodes-internal").core.rule_lifecycle;
pub const rule_build_bundle = @import("metacodes-internal").core.rule_build_bundle;
pub const rule_evaluation = @import("metacodes-internal").core.rule_evaluation;
pub const project_harness_runtime = @import("metacodes-internal").formal.project_harness_runtime;
pub const project_rule_bundle = @import("metacodes-internal").core.project_rule_bundle;
pub const project_rule_gate = @import("metacodes-internal").core.project_rule_gate;
pub const project_rule_activation = @import("metacodes-internal").core.project_rule_activation;
pub const repl_msg_queue = @import("repl/msg_queue.zig");
pub const repl_history = @import("repl/history.zig");
pub const repl_user_echo = @import("repl/user_echo.zig");
pub const repl_replay = @import("repl/replay.zig");
pub const event_journal = @import("metacodes-internal").core.event_journal;
pub const session_host = @import("metacodes-internal").core.session_host;
pub const web_backend = @import("web/backend.zig");
pub const web_server = @import("web/server.zig");
pub const web_session = @import("web/session.zig");
pub const web_submission = @import("web/submission.zig");
pub const session_intent = @import("session_intent.zig"); // U11:UI 中立输入意图(issue #3)
pub const session_service = @import("session_service.zig"); // U11:canonical 会话命令面 + run 装配
pub const daemon_registry = @import("daemon/registry.zig"); // U10:SessionRegistry + SessionHost
pub const daemon_app_driver = @import("daemon/app_driver.zig"); // U10-D:真 App driver
pub const daemon_serve = @import("daemon/serve.zig"); // U10-D:serve(单 session daemon MVP)
pub const daemon_serve_multi = @import("daemon/serve_multi.zig"); // U10-C/#254:multi-session daemon (component tests drive it)
pub const daemon_uds = @import("daemon/uds.zig"); // U10-B:UDS+NDJSON 绑定(组件测试驱动 message op)
pub const core_shutdown = @import("metacodes-internal").core.shutdown; // U9:进程级停机信号
pub const tui_status_bar = @import("repl/tui/widget/status_bar.zig");
pub const tui_verbs = @import("repl/tui/verbs.zig");
pub const tui_ui_state = @import("repl/tui/ui_state.zig");
pub const tui_ui = @import("repl/tui/ui.zig");
pub const tui_event = @import("repl/tui/event.zig");
pub const tui_theme = @import("repl/tui/theme.zig");
pub const tui_term = @import("repl/tui/term.zig");
pub const tool_card = @import("repl/tui/widget/tool_card.zig");
pub const tui_test_capture = @import("repl/tui/test_capture.zig");
pub const repl_input = @import("repl/input.zig");
pub const repl_complete = @import("repl/complete.zig");
pub const repl_model_picker = @import("repl/model_picker.zig");
pub const repl_model_picker_view = @import("repl/model_picker_view.zig");
pub const repl_picker_host = @import("repl/picker_host.zig");
pub const answer_queue = @import("metacodes-internal").core.answer_queue;
pub const recorder = @import("metacodes-internal").core.recorder;

/// 测试钩子:暴露 parseArgs 给 L2(base_url_flag_test 等)。
/// 传入 argv(含 argv[0] 占位),返回解析后的 Config。
/// 注意:不要传 --help(会 std.process.exit 杀测试)。
pub fn parseArgsForTest(argv: []const [*:0]const u8, allocator: std.mem.Allocator) types.Config {
    var config = types.Config{};
    if (builtin.os.tag == .windows) {
        // Windows 的 Args.Vector 是整条 WTF-16 命令行(非 argv 数组):用平台层
        // buildWindowsCmdline 拼接(引号规则与 CommandLineToArgvW 往返一致),
        // 再走 allocator 版迭代器。parseArgsInto 对存入 Config 的字符串都 dupe,
        // 迭代器 deinit 后不悬垂。
        const opt_argv = allocator.alloc(?[*:0]const u8, argv.len) catch @panic("OOM");
        defer allocator.free(opt_argv);
        for (argv, opt_argv) |src, *dst| dst.* = src;
        const cmdline_w = @import("metacodes-internal").platform.process.buildWindowsCmdline(allocator, opt_argv) catch @panic("OOM");
        defer allocator.free(cmdline_w);
        var args = std.process.Args.iterateAllocator(.{ .vector = cmdline_w }, allocator) catch
            @panic("args iterate failed");
        defer args.deinit();
        parseArgsInto(&config, &args, allocator);
    } else {
        var args = std.process.Args.iterate(.{ .vector = argv });
        parseArgsInto(&config, &args, allocator);
    }
    return config;
}

/// 可移植 argv 迭代器。POSIX:`iterate`(vector,零分配);Windows:`iterateAllocator`——
/// `std.process.Args.iterate` 在 Windows 是 @compileError(须 allocator 版解析 WTF-8 命令行)。
/// 返回迭代器的 deinit 在 POSIX 无操作、Windows 释放内部缓冲 → 调用方一律 `defer it.deinit()`。
fn argsIter(init: std.process.Init) std.process.Args.Iterator {
    if (builtin.os.tag == .windows) {
        return std.process.Args.iterateAllocator(init.minimal.args, init.gpa) catch |e|
            std.debug.panic("args init failed: {s}", .{@errorName(e)});
    }
    return std.process.Args.iterate(init.minimal.args);
}

/// 据 model 名前缀推断 provider 协议(纯函数,无 env)。gpt*/o1*/o3* → openai,gemini* → gemini,
/// 其余 anthropic。env METACODES_PROVIDER 在 main 里显式覆盖此推断。
/// Resolve `--provider/--channel/--offer` into a concrete route and apply it.
///
/// The registry owns endpoint construction, protocol choice, wire model id, and
/// the auth scheme, so nothing downstream has to re-derive them. A provider,
/// channel, offer, or `--base-url` the profile rejects exits before any request
/// is built rather than silently degrading to another endpoint.
fn applyProviderRoute(
    config: *types.Config,
    allocator: std.mem.Allocator,
    profile_name: ?[]const u8,
) void {
    const startup = @import("metacodes-internal").provider.startup;
    const host = buildProviderHost(allocator) orelse {
        std.debug.print("error: provider registry initialization failed\n", .{});
        std.process.exit(2);
    };
    defer host.destroy();
    const registry = &host.registry;

    const outcome = startup.resolve(allocator, registry, .{
        .provider = profile_name,
        .channel = config.provider_channel,
        .offer_id = config.provider_offer,
        .model = if (config.model_explicit) config.model else null,
        .base_url = config.base_url,
    }) catch {
        std.debug.print("error: out of memory while resolving the provider route\n", .{});
        std.process.exit(2);
    };

    applyStartupOutcome(config, allocator, outcome);
}

/// Restore the durable global selection committed by a previous `global` scope
/// commit. Nothing is applied when no selection was ever committed, so the
/// historical path stays byte-identical for every installation that has not
/// used the picker.
///
/// A stored pin that no longer resolves is fatal on purpose. The alternative —
/// falling back to model-name inference — would silently run a different vendor
/// than the one the user chose, which is the exact substitution the offer model
/// exists to prevent.
pub fn applyPersistedGlobalSelection(config: *types.Config, allocator: std.mem.Allocator) bool {
    var store = provider_config_store.Store.initHome(allocator, config.state_root) catch return false;
    defer store.deinit();

    var document = store.load() catch |err| {
        // Unreadable is not "absent": say so rather than quietly ignoring a
        // selection that may well be in there.
        std.debug.print(
            "warning: <state root>/config.json could not be read ({s}); " ++
                "any stored provider selection is being ignored\n",
            .{@errorName(err)},
        );
        return false;
    };
    defer document.deinit();
    const selection = document.global_selection orelse return false;

    const host = buildProviderHost(allocator) orelse {
        std.debug.print("error: provider registry initialization failed\n", .{});
        std.process.exit(2);
    };
    defer host.destroy();

    var outcome = resolveStoredSelection(allocator, host, selection);
    if (outcome == .failure and outcome.failure == .unresolved_selection) {
        switch (fetchMissingOpenRouterListing(allocator, config.*)) {
            .skipped => {},
            .kept => {
                _ = openrouter_catalog.adoptKept(host, allocator, config.state_root);
                outcome = resolveStoredSelection(allocator, host, selection);
            },
            .failed => |failure| failMissingOpenRouterListing(allocator, failure),
            .timed_out => failMissingOpenRouterListing(allocator, null),
        }
    }
    applyStartupOutcome(config, allocator, outcome);
    return true;
}

fn resolveStoredSelection(
    allocator: std.mem.Allocator,
    host: *provider_host.Host,
    selection: provider_selection.RuntimeSelection,
) provider_startup.Outcome {
    return provider_startup.resolveSelection(allocator, &host.registry, selection) catch {
        std.debug.print("error: out of memory while resolving the stored provider selection\n", .{});
        std.process.exit(2);
    };
}

pub const MissingListing = union(enum) {
    skipped,
    kept,
    failed: openrouter_catalog.Failure,
    timed_out,
};

pub const MISSING_LISTING_WAIT_MS: u64 = 30_000;

pub fn fetchMissingOpenRouterListing(allocator: std.mem.Allocator, config: types.Config) MissingListing {
    if (std.c.getenv("METACODES_NO_PROBE") != null) return .skipped;
    if (openrouter_catalog.keptAge(allocator, config.state_root) != .none) return .skipped;
    const credential = resolveProviderScopedCredentialReporting(allocator, config, "openrouter", .keys_only) catch return .skipped;
    defer {
        std.crypto.secureZero(u8, credential.secret);
        allocator.free(credential.secret);
    }
    std.debug.print("Downloading OpenRouter's model list for the stored default model…\n", .{});
    const refresh = openrouter_catalog.Refresh.start(credential.secret, config.state_root, .{}) catch return .{ .failed = .other };
    defer refresh.release();
    var waited_ms: u64 = 0;
    while (!refresh.finished()) {
        if (waited_ms >= MISSING_LISTING_WAIT_MS) {
            refresh.supersede();
            return .timed_out;
        }
        util_time.sleepMs(100);
        waited_ms += 100;
    }
    return if (refresh.kept()) .kept else .{ .failed = refresh.failureReason() };
}

fn failMissingOpenRouterListing(allocator: std.mem.Allocator, failure: ?openrouter_catalog.Failure) noreturn {
    const command = invokedCommand(allocator);
    if (failure != null and failure.? == .refused) {
        std.debug.print(
            "error: the stored default model was not found, and OpenRouter refused the key when its model list was requested; sign in again: {s} login --provider openrouter\n",
            .{command},
        );
        std.process.exit(2);
    }
    std.debug.print(
        "error: the stored default model was not found, and OpenRouter's model list, which is not on this machine, could not be downloaded ({s}); `{s} --provider openrouter` starts without that model and downloads the list, or pass --provider/--model to choose another route\n",
        .{ missingListingWords(failure), command },
    );
    std.process.exit(2);
}

fn missingListingWords(failure: ?openrouter_catalog.Failure) []const u8 {
    const known = failure orelse return "no answer within 30 s";
    return switch (known) {
        .connection => "no connection",
        .interrupted => "answer cut off",
        .refused => "key refused",
        .busy => "rate limited",
        .server_error => "server error",
        .not_a_list => "not a model list",
        .too_large => "list too large",
        .other => "unexpected error",
    };
}

/// `<state root>/.env` (#486), read once at startup. The provider runtime
/// that decides which names it may set is built only when there is a file
/// to judge, so a start without one does no extra work. `gpa` owns the
/// result (the read buffer goes back at once); `arena` the allowlist.
fn loadLocalConfig(gpa: std.mem.Allocator, arena: std.mem.Allocator, state_root: []const u8) state_env_mod.Loaded {
    const allowlist: state_env_mod.Allowlist = if (state_env_mod.exists(state_root)) localConfigAllowlist(arena) else .{};
    return state_env_mod.load(gpa, state_root, allowlist) catch {
        std.debug.print("error: out of memory while reading {s}{c}{s}\n", .{ state_root, std.fs.path.sep, state_env_mod.file_name });
        std.process.exit(2);
    };
}

/// The names `<state root>/.env` may set, from the provider runtime a
/// session builds (`buildProviderHost`) and the config.json it read.
fn localConfigAllowlist(arena: std.mem.Allocator) state_env_mod.Allowlist {
    const host = buildProviderHost(arena) orelse return .{};
    defer host.destroy();
    var store = provider_config_store.Store.initHome(arena, hostRoot()) catch
        return state_env_mod.allowlistFrom(arena, host.registry.profiles.items, null, null) catch .{};
    defer store.deinit();
    const text: ?[]u8 = store.readText() catch null;
    defer if (text) |bytes| arena.free(bytes);
    var document: ?provider_config_doc.Document = store.load() catch null;
    defer if (document) |*value| value.deinit();
    return state_env_mod.allowlistFrom(arena, host.registry.profiles.items, if (document) |*value| value else null, text) catch .{};
}

/// Says once what of `<state root>/.env` is not read: a file that cannot be,
/// and the names it sets that are ignored (never a value). To the log only
/// while the TUI owns the terminal; `metacodes doctor` shows the same.
fn warnLocalConfig(allocator: std.mem.Allocator, local: *const state_env_mod.Loaded, to: enum { stderr, log }) void {
    const log = @import("metacodes-internal").util.log;
    const quiet = to == .log;
    const problem: ?[]const u8 = switch (local.status) {
        .unreadable => "cannot be read",
        .not_a_file => "is not a regular file",
        .too_large => "is larger than " ++ std.fmt.comptimePrint("{d}", .{state_env_mod.max_file_bytes / 1024}) ++ " KiB",
        .absent, .read, .no_state_root => null,
    };
    if (problem) |what| {
        if (quiet)
            log.warn("config", "{s} {s}; nothing in it is read", .{ local.path, what })
        else
            std.debug.print("warning: {s} {s}; nothing in it is read\n", .{ local.path, what });
    }
    const summary = (local.ignoredSummary(allocator) catch null) orelse return;
    defer allocator.free(summary);
    if (quiet) log.warn("config", "{s}", .{summary}) else std.debug.print("warning: {s}\n", .{summary});
}

/// Level 7's other way in, after the sign-in hint: where this install's
/// `.env` is, the template beside it when an install wrote one, and which
/// providers' keys the file holds when it names none of them.
fn printLocalConfigHint(local: *const state_env_mod.Loaded, unchosen: []const []const u8) void {
    if (local.path.len == 0) return;
    var template_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    std.debug.print(local_config_hint, .{
        .path = local.path,
        .template = localTemplateNote(local.path, &template_buf),
        .guide = state_env_mod.guide_url,
    });
    if (unchosen.len == 0) return;
    std.debug.print("{s} holds keys for several providers (", .{local.path});
    for (unchosen, 0..) |id, index| std.debug.print("{s}{s}", .{ if (index == 0) "" else ", ", id });
    std.debug.print(") and names none: add {s}=<id> to choose one.\n", .{state_env_mod.provider_variable});
}

/// The notices said once under the banner, one per line; null when none
/// is set. In `arena` (a notice alone is returned as it is).
fn joinNotices(arena: std.mem.Allocator, notices: []const ?[]const u8) ?[]const u8 {
    var first: ?[]const u8 = null;
    var out: std.Io.Writer.Allocating = .init(arena);
    var count: usize = 0;
    for (notices) |maybe| {
        const notice = maybe orelse continue;
        if (count == 0) first = notice;
        if (count > 0) out.writer.writeByte('\n') catch return first;
        out.writer.writeAll(notice) catch return first;
        count += 1;
    }
    return if (count <= 1) first else out.written();
}

/// What the TUI says once under its banner when `.env` holds keys of
/// several providers and names none (#486): which ones, by display name, and
/// that `/model` chooses (`route_state.writeUnchosenLocalNotice`). In `arena`.
fn unchosenLocalNotice(arena: std.mem.Allocator, ids: []const []const u8) ?[]const u8 {
    if (ids.len == 0) return null;
    const names = arena.alloc([]const u8, ids.len) catch return null;
    const host = buildProviderHost(arena);
    defer if (host) |built| built.destroy();
    for (ids, names) |id, *name| {
        const profile = if (host) |built| built.registry.find(id) else null;
        name.* = if (profile) |found| (arena.dupe(u8, found.display_name) catch id) else id;
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    route_state_mod.writeUnchosenLocalNotice(&out.writer, names) catch return null;
    return out.written();
}

/// ` (template: <dir>/.env.example)` when that file exists, else "".
fn localTemplateNote(env_path: []const u8, buf: []u8) []const u8 {
    const dir = std.fs.path.dirname(env_path) orelse return "";
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const template = std.fmt.bufPrintZ(&path_buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, state_env_mod.example_file_name }) catch return "";
    if (!pfs.exists(template.ptr)) return "";
    return std.fmt.bufPrint(buf, " (template: {s})", .{template}) catch "";
}

/// Level 4 of the startup order, judged before it is applied (#485).
const StoredDefault = startup_order.StoredDefault;

/// Whether the default stored by `/model` can serve this start: its route
/// resolves and its provider has a credential (`storedDefaultOn`). Nothing is
/// printed and nothing sent; the strings live in `arena`.
fn storedDefault(arena: std.mem.Allocator, config: types.Config, metask_key_present: bool) StoredDefault {
    var store = provider_config_store.Store.initHome(arena, hostRoot()) catch return .none;
    defer store.deinit();
    var document = store.load() catch return .unreadable;
    defer document.deinit();
    const selection = document.global_selection orelse return .none;
    const host = buildProviderHost(arena) orelse return .{ .usable = .{} };
    defer host.destroy();
    return storedDefaultOn(arena, config, metask_key_present, &host.registry, selection);
}

/// `storedDefault` once the stored selection is read, judged against
/// `registry`. A Metask default needs a Metask device-code session or a Metask
/// key (`metask_key_present`, the historical path's own sign-in): that is what
/// a named Metask route authenticates with. Another provider's needs a key, or
/// its own sign-in, which counts by being stored (`providerSignInStored`), the
/// way the Metask session does: refreshing it here would send a request from
/// `login status` and pass the default over whenever the refresh failed. A
/// start refreshes it when it uses it. Pub for the component test that gives
/// the provider a token endpoint of its own.
pub fn storedDefaultOn(
    arena: std.mem.Allocator,
    config: types.Config,
    metask_key_present: bool,
    registry: *const provider_registry.ProviderRegistry,
    selection: provider_selection.RuntimeSelection,
) StoredDefault {
    const outcome = provider_startup.resolveSelection(arena, registry, selection) catch return .{ .usable = .{} };
    const route = switch (outcome) {
        .failure => return .{ .usable = .{} },
        .route => |value| value,
    };
    const provider_name = if (registry.findById(route.provider_id)) |profile| profile.display_name else route.provider_id.slice();
    const label = std.fmt.allocPrint(arena, "{s} · {s}", .{ provider_name, route.request_model_id }) catch return .{ .usable = .{} };
    const usable: StoredDefault.Usable = .{
        .label = label,
        .provider = arena.dupe(u8, route.provider_id.slice()) catch null,
    };
    if (route.provider_id.eqlText("metask")) {
        if (metask_key_present) return .{ .usable = usable };
        // The browser sign-in's key serves a stored Metask default too
        // (`browserSignInKey`), the way it serves the historical path.
        if (browserSignInKey(arena, config.state_root)) |key| {
            std.crypto.secureZero(u8, key);
            arena.free(key);
            return .{ .usable = usable };
        }
        var session = provider_oauth_mod.Session.initHome(arena, config.state_root, provider_ids_mod.Slug.lit("metask")) catch
            return .{ .lacks_credential = label };
        defer session.deinit();
        return if (session.load() catch false) .{ .usable = usable } else .{ .lacks_credential = label };
    }
    const profile = registry.findById(route.provider_id) orelse return .{ .usable = usable };
    if (resolveProfileCredential(arena, config, profile, .keys_only)) |found| {
        std.crypto.secureZero(u8, found.secret);
        arena.free(found.secret);
        return .{ .usable = usable };
    } else |err| if (err != error.MissingCredentials) return .{ .usable = usable };
    return if (providerSignInStored(arena, config.state_root, profile)) .{ .usable = usable } else .{ .lacks_credential = label };
}

fn keepRuntimeKeyFdFromChildren() void {
    const raw = std.c.getenv(auth.RUNTIME_API_KEY_FD_ENV) orelse return;
    const fd = std.fmt.parseInt(pfs.Fd, std.mem.span(raw), 10) catch return;
    if (fd < 3) return;
    pfs.makeCloseOnExec(fd) catch {};
}

/// `METACODES_AUTH_PRECEDENCE`, which overrides `--auth-precedence`. A start
/// applies it before the startup order; `login status` (#537) does too, so
/// both judge an empty `METASK_API_KEY` the same way under `oauth-first`.
fn applyAuthPrecedenceEnv(config: *types.Config) void {
    if (std.c.getenv("METACODES_AUTH_PRECEDENCE")) |c| {
        if (auth.parsePrecedence(std.mem.span(c))) |p| config.auth_precedence = p;
    }
}

/// What the startup order reads (`startup_order.Facts`), for `config` as the
/// start holds it once its flags and the environment are applied (level 1),
/// `local`, the install's `.env`, and `presets`, what `presetFacts` read.
/// Reads files, sends nothing, changes nothing: a start applies the
/// decision, `login status` shows it.
fn startupFacts(allocator: std.mem.Allocator, config: types.Config, local: *const state_env_mod.Loaded, local_metask_key: ?[]const u8, presets: *const presets_mod.Facts) startup_order.Facts {
    const named = config.provider_profile != null or config.provider_offer != null;
    // A level above the stored default decides: the default is not judged.
    const above_default = named or presets.named == .found or presets.directory_preset == .found;
    const metask_key_requested = config.api_key != null or
        (config.auth_precedence == .api_key_first and (std.c.getenv("METASK_API_KEY") != null or local_metask_key != null));
    return .{
        .named = named,
        .preset = presets.named,
        .directory_preset = presets.directory_preset,
        .stored_default = if (above_default or !presets.global_default) .none else storedDefault(allocator, config, metask_key_requested),
        .metask_key = metaskSignInPresent(allocator, config, local_metask_key),
        .metask_key_requested = metask_key_requested,
        .metask_session = metaskSessionStored(allocator, config.state_root),
        .local_preset = presets.local_preset,
        .local = local.choice(),
        .global_default = presets.global_default,
        .metask_key_handed = config.api_key != null or std.c.getenv(auth.RUNTIME_API_KEY_FD_ENV) != null,
    };
}

/// Levels 2, 3 and 6 of the startup order (#489): the preset `--preset` (or
/// `METACODES_PRESET` in the shell) names, the one the working directory
/// remembers, and `METACODES_PRESET` in `local`, each judged against
/// config.json (`apps/cli/src/app/presets.zig`). `with_routes` names each found
/// preset's route (`login status`), which builds the provider runtime once
/// more. Reads files, sends nothing; everything is in `arena`.
fn presetFacts(arena: std.mem.Allocator, config: types.Config, local: *const state_env_mod.Loaded, with_routes: bool) presets_mod.Facts {
    var inputs: presets_mod.Inputs = .{
        .flag = config.preset,
        .local = local.get(state_env_mod.preset_variable),
        .cwd = @import("metacodes-internal").util.fs.getCwd(arena) catch null,
    };
    var store = provider_config_store.Store.initHome(arena, hostRoot()) catch
        return presets_mod.gather(arena, inputs) catch presetFactsOutOfMemory();
    defer store.deinit();
    inputs.config_path = store.path;
    var loaded = store.load();
    defer if (loaded) |*document| document.deinit() else |_| {};
    if (loaded) |*document| {
        inputs.document = .{ .read = document };
    } else |err| {
        inputs.document = .{ .unreadable = @errorName(err) };
        if (store.readText() catch null) |text| {
            defer arena.free(text);
            inputs.unreadable_global_default = provider_config_doc.globalDefaultIn(arena, text);
        }
    }
    const host: ?*provider_host.Host = if (with_routes and inputs.document == .read) buildProviderHost(arena) else null;
    defer if (host) |value| value.destroy();
    if (host) |value| inputs.registry = &value.registry;
    var facts = presets_mod.gather(arena, inputs) catch presetFactsOutOfMemory();
    facts.config_path = arena.dupe(u8, store.path) catch presetFactsOutOfMemory();
    return facts;
}

fn presetFactsOutOfMemory() noreturn {
    std.debug.print("error: out of memory while reading the presets\n", .{});
    std.process.exit(2);
}

/// A preset this start was asked for that config.json does not define
/// (#489): `-p`, `serve`, `--web` and the rest stop, listing the presets
/// there; the interactive TUI starts as if it had not been named and says so
/// once under its banner (the returned notice).
fn presetNotice(
    allocator: std.mem.Allocator,
    config: types.Config,
    facts: *const presets_mod.Facts,
    unknown: startup_order.Unknown,
    env_path: []const u8,
) ?[]const u8 {
    const report = (presets_mod.unknownReport(allocator, facts, unknown, env_path) catch presetFactsOutOfMemory()) orelse return null;
    if (!(interactiveRepl(config) and platform_term.isatty(0))) {
        std.debug.print("error: {s}\n", .{report});
        std.process.exit(2);
    }
    return std.fmt.allocPrint(allocator, "{s}\nStarted without it.", .{report}) catch report;
}

fn unchosenDirectoryError(arena: std.mem.Allocator, facts: *const presets_mod.Facts) []const u8 {
    const directory = if (facts.directory.len > 0) facts.directory else "the working directory";
    const config_path = if (facts.config_path.len > 0) facts.config_path else "config.json";
    if (facts.unreadable) |why| return std.fmt.allocPrint(arena, "error: {s} cannot be read ({s}), so no preset can be looked up, and it sets \"global_default\": false, so nothing is chosen for this directory.\n" ++
        "Name one for this run with --provider <id> or --offer <id>, or correct {s}.\n", .{ config_path, why, config_path }) catch
        "error: nothing is chosen for this directory (global_default is false in config.json)\n";
    const listed = if (facts.defined.len == 0) "" else std.fmt.allocPrint(arena, " (presets: {s})", .{std.mem.join(arena, ", ", facts.defined) catch ""}) catch "";
    return std.fmt.allocPrint(arena, "error: {s} remembers no preset, and {s} sets \"global_default\": false, so nothing is chosen for this directory.\n" ++
        "Name one for this run with --preset <name>{s}, --provider <id> or --offer <id>, or remember a preset for it under directory_presets.\n", .{ directory, config_path, listed }) catch
        "error: nothing is chosen for this directory (global_default is false in config.json)\n";
}

/// Levels 2, 3 and 6 (#489): the preset that decided names the route the
/// way `--provider`, `--channel`, `--model` (or `--offer`) and
/// `--reasoning-effort` would; a flag the start was given keeps its field.
/// A preset whose route does not resolve stops the start, as a stored
/// default's does. Returns whether a preset decided.
fn applyDecidedPreset(
    config: *types.Config,
    allocator: std.mem.Allocator,
    local: *const state_env_mod.Loaded,
    facts: *const presets_mod.Facts,
    decision: startup_order.Decision,
) bool {
    const found = facts.decided(decision) orelse return false;
    const selection = facts.selection(found.name) orelse return false;
    // `.env`'s METACODES_MODEL is `--model` for the file's own choice.
    if (decision == .local_preset and !config.model_explicit) if (local.get(state_env_mod.model_variable)) |model| {
        config.model = model;
        config.model_explicit = true;
    };
    const host = buildProviderHost(allocator) orelse {
        std.debug.print("error: provider registry initialization failed\n", .{});
        std.process.exit(2);
    };
    defer host.destroy();
    const outcome = presets_mod.apply(allocator, &host.registry, selection.*, config) catch presetFactsOutOfMemory();
    switch (outcome) {
        .refused => |why| {
            std.debug.print("error: {s}\n", .{why.message(allocator, found.name, facts.config_path) catch "the preset cannot be applied"});
            std.process.exit(2);
        },
        .applied => |applied| @import("metacodes-internal").util.log.info("config", "preset {s}: provider {s}", .{ found.name, applied.provider }),
    }
    return true;
}

/// The API key a browser sign-in (`metacodes login`, `/login`) stored in
/// `auth.json`, owned by `arena`; null when there is none. It authenticates a
/// stored Metask default as it authenticates the historical path (#485):
/// a `/model` "every future session" pick of a Metask route, made while
/// signed in in the browser, must not need the device-code session that a
/// named Metask route otherwise reads.
fn browserSignInKey(arena: std.mem.Allocator, state_root: []const u8) ?[]u8 {
    var stored = auth.loadDefault(arena, state_root) catch return null;
    defer stored.deinit(arena);
    // The key as it is sent: blanks around it in the file are not part of it.
    const key = std.mem.trim(u8, stored.api_key orelse return null, " \t\r\n");
    if (key.len == 0) return null;
    return arena.dupe(u8, key) catch null;
}

/// What this start uses instead of a passed-over default, for the notice.
const StartRoute = struct {
    model: []const u8,
    origin: route_state_mod.CredentialOrigin,
};

/// `The default model, DeepSeek · deepseek-v4-pro, has no key or sign-in;
/// this session uses glm-5 · Metask.` (#485, 第四节第 2 级). `instead` is
/// null when nothing else is set up either. In `arena`.
fn skippedDefaultNotice(arena: std.mem.Allocator, label: []const u8, instead: ?StartRoute) ?[]const u8 {
    const route = instead orelse return std.fmt.allocPrint(arena, "The default model, {s}, has no key or sign-in, and nothing else is set up.", .{label}) catch null;
    var buf: [256]u8 = undefined;
    const line = route_state_mod.modelLine(&buf, .{ .bound = route.origin }, route.model);
    return std.fmt.allocPrint(arena, "The default model, {s}, has no key or sign-in; this session uses {s}.", .{ label, line }) catch null;
}

/// Level 5 of the startup order: a Metask sign-in the historical path would
/// use — `--api-key`, a runtime key descriptor, `METASK_API_KEY` (the
/// environment's, or `file_key` from `.env`), or a login stored in
/// `auth.json`. A stored login that cannot be read counts, so the run says
/// why rather than quietly using another provider. The Metask session
/// (`metaskSessionStored`) is level 5 too, after these (#499, #527).
fn metaskSignInPresent(allocator: std.mem.Allocator, config: types.Config, file_key: ?[]const u8) bool {
    if (config.api_key != null) return true;
    if (std.c.getenv(auth.RUNTIME_API_KEY_FD_ENV) != null) return true;
    if (file_key != null or nonEmptyEnv(auth.METASK_API_KEY_ENV) != null) return true;
    const path = auth.authFilePath(allocator, config.state_root) catch return false;
    defer allocator.free(path);
    var stored = auth.loadFromPath(allocator, path) catch |err| return err != error.NotFound;
    defer stored.deinit(allocator);
    return stored.api_key != null or stored.oauth != null;
}

fn loadStartupMetask(slot: *?provider_oauth_mod.Session, allocator: std.mem.Allocator, state_root: []const u8) !*provider_oauth_mod.Session {
    if (slot.* == null) {
        var session = try provider_oauth_mod.Session.initHome(allocator, state_root, provider_ids_mod.Slug.lit("metask"));
        errdefer session.deinit();
        _ = try session.load();
        slot.* = session;
    }
    return &slot.*.?;
}

fn metaskEndpointBase(endpoint: []const u8) []const u8 {
    const url = std.mem.trimEnd(u8, endpoint, "/");
    for ([_][]const u8{ "/v1/messages", "/v1/chat/completions" }) |suffix| {
        if (std.mem.endsWith(u8, url, suffix)) return url[0 .. url.len - suffix.len];
    }
    return url;
}

fn startupMetaskGateway(allocator: std.mem.Allocator, session: *const provider_oauth_mod.Session) !?[]const u8 {
    const stored = if (session.tokens) |tokens| tokens.gateway_url orelse "" else null;
    return metask_oauth_mod.modelGateway(stored) catch |err| {
        std.debug.print("error: Metask requires a valid gateway origin from the stored session or METASK_GATEWAY_URL; run `{s} login --provider metask`\n", .{invokedCommand(allocator)});
        return err;
    };
}

/// Whether `<state root>/oauth/metask.json` holds a Metask session a start
/// can use (#499, #527): what the browser sign-in and the device code store.
fn metaskSessionStored(allocator: std.mem.Allocator, state_root: []const u8) bool {
    var session = provider_oauth_mod.Session.initHome(allocator, state_root, provider_ids_mod.Slug.lit("metask")) catch return false;
    defer session.deinit();
    return session.load() catch false;
}

/// Whether the registry this run builds knows `name` as a provider id or
/// alias. Unknown here means route resolution would refuse it too.
fn providerKnown(allocator: std.mem.Allocator, name: []const u8) bool {
    const host = buildProviderHost(allocator) orelse return true;
    defer host.destroy();
    return host.registry.find(name) != null;
}

/// `name`'s display name in the registry this run builds (`name` itself when
/// it names no provider there); in `arena`.
fn providerDisplayName(arena: std.mem.Allocator, name: []const u8) []const u8 {
    const host = buildProviderHost(arena) orelse return name;
    defer host.destroy();
    const profile = host.registry.find(name) orelse return name;
    return arena.dupe(u8, profile.display_name) catch name;
}

/// `name`'s display name when it is a subscription plan in the registry this
/// run builds (`ProviderProfile.subscription_plan`), else null; in `arena`.
fn subscriptionPlanName(arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const host = buildProviderHost(arena) orelse return null;
    defer host.destroy();
    const profile = host.registry.find(name) orelse return null;
    if (!profile.subscription_plan) return null;
    return arena.dupe(u8, profile.display_name) catch null;
}

/// Whether `name` (a provider id or alias, as `--provider` takes it) is
/// Metask in the registry this run builds.
fn providerIsMetask(allocator: std.mem.Allocator, name: []const u8) bool {
    const host = buildProviderHost(allocator) orelse return std.ascii.eqlIgnoreCase(name, "metask");
    defer host.destroy();
    const profile = host.registry.find(name) orelse return false;
    return profile.id.eqlText("metask");
}

fn shadowedLocalNotice(arena: std.mem.Allocator, local: presets_mod.LocalRoute) ?[]const u8 {
    switch (local) {
        .provider => |chosen| {
            if (providerIsMetask(arena, chosen.name)) return null;
            const name = providerDisplayName(arena, chosen.name);
            return std.fmt.allocPrint(arena, ".env configures {s}; the default is Metask. To use {s}: /model, or /logout", .{ name, name }) catch null;
        },
        .preset => |preset| {
            const route_label: []const u8 = label: {
                const host = buildProviderHost(arena) orelse break :label "";
                defer host.destroy();
                const resolved = (presets_mod.resolveLocal(arena, &host.registry, local) catch null) orelse break :label "";
                const route = resolved.route;
                if (route.provider_id.eqlText("metask")) return null;
                const provider_name = if (host.registry.findById(route.provider_id)) |profile| profile.display_name else route.provider_id.slice();
                break :label std.fmt.allocPrint(arena, " ({s} · {s})", .{ provider_name, route.request_model_id }) catch "";
            };
            return std.fmt.allocPrint(arena, ".env configures the preset {s}{s}; the default is Metask. To use it: /model, or /logout", .{ preset.name, route_label }) catch null;
        },
    }
}

/// `METASK_API_KEY` in `<state root>/.env`, for the historical path: it
/// counts as the environment variable only while the file chooses nothing
/// but Metask (#486, #748): its METACODES_PRESET when config.json defines it,
/// else its METACODES_PROVIDER. A file that says METACODES_PROVIDER=deepseek,
/// or names a DeepSeek preset, chose DeepSeek; a Metask key beside it is there
/// for when Metask is chosen (`--provider metask`, `/model`), and must not
/// sign the start in, take the legacy route, or outrank auth.json.
fn localSignInKey(allocator: std.mem.Allocator, local: *const state_env_mod.Loaded, presets: *const presets_mod.Facts) ?[]const u8 {
    const key = local.get(auth.METASK_API_KEY_ENV) orelse return null;
    switch (presets.local_preset) {
        .none => {},
        .found => |found| return if (localPresetOnMetask(allocator, presets, found.name)) key else null,
        .unknown => if (local.get(state_env_mod.provider_variable) == null) return null,
    }
    const named = local.get(state_env_mod.provider_variable) orelse return key;
    return if (providerIsMetask(allocator, named)) key else null;
}

fn localPresetOnMetask(allocator: std.mem.Allocator, presets: *const presets_mod.Facts, name: []const u8) bool {
    const selection = presets.selection(name) orelse return false;
    const host = buildProviderHost(allocator) orelse return false;
    defer host.destroy();
    const resolved = (presets_mod.resolveLocal(allocator, &host.registry, .{ .preset = .{ .name = name, .selection = selection.* } }) catch return false) orelse return false;
    return resolved.route.provider_id.eqlText("metask");
}

/// An environment variable's value, with an empty one treated as unset.
fn nonEmptyEnv(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    const value = std.mem.span(raw);
    return if (value.len == 0) null else value;
}

fn applyStartupOutcome(
    config: *types.Config,
    allocator: std.mem.Allocator,
    outcome: provider_startup.Outcome,
) void {
    switch (outcome) {
        .failure => |failure| {
            const text = failure.message(allocator) catch "provider route resolution failed";
            std.debug.print("error: {s}\n", .{text});
            std.process.exit(2);
        },
        .route => |resolved| {
            var route = resolved;
            config.provider_kind = route.transport;
            if (!config.openai_protocol_explicit) config.openai_protocol = route.openai_protocol;
            // Ownership of the two strings transfers into Config; the display
            // name is not consumed here.
            config.base_url = route.endpoint_url;
            config.model = route.request_model_id;
            // The route *is* the model decision, so a stored Metask selection
            // must not overwrite it later in startup.
            config.model_explicit = true;
            config.auth_scheme = route.auth_scheme;
            config.dialect = route.dialect;
            const rendered = route.offer_id.render();
            config.selected_offer_id = allocator.dupe(u8, &rendered) catch null;
            config.resolved_provider_id = allocator.dupe(u8, route.provider_id.slice()) catch null;
            // A stored selection names no provider on the command line, so the
            // credential scope has to come from the route itself. Without this
            // the session would fall back to the Metask credential path for a
            // route that is not Metask.
            if (config.provider_profile == null) {
                config.provider_profile = config.resolved_provider_id;
            }
            // Setup/doctor visibility: the selected region, protocol, and
            // endpoint are shown before any request is sent. The endpoint is a
            // channel base URL and carries no credential; the credential itself
            // is never printed or logged.
            @import("metacodes-internal").util.log.info(
                "provider",
                "route provider={s} channel={s} protocol={s} region={s} model={s} endpoint={s} offer={s}",
                .{
                    route.provider_id.slice(),
                    route.channel_id.slice(),
                    route.protocol_id,
                    route.region orelse "-",
                    route.request_model_id,
                    route.endpoint_url,
                    &rendered,
                },
            );
            if (config.verbose) {
                std.debug.print(
                    "provider route: {s}/{s} [{s}] region={s} model={s}\n  endpoint {s}\n  offer    {s}\n",
                    .{
                        route.provider_id.slice(),
                        route.channel_id.slice(),
                        route.protocol_id,
                        route.region orelse "-",
                        route.request_model_id,
                        route.endpoint_url,
                        &rendered,
                    },
                );
            }
            // Only `endpoint_url` and `request_model_id` transfer into Config;
            // everything else this route owns is consumed by the summary above
            // and freed here.
            allocator.free(route.display_name);
            if (route.region) |value| allocator.free(value);
            if (route.plan) |value| allocator.free(value);
        },
    }
}

pub fn inferProviderKind(model: []const u8) types.ProviderKind {
    if (model_name.startsWithIgnoreCase(model, "gpt") or
        model_name.startsWithIgnoreCase(model, "o1") or
        model_name.startsWithIgnoreCase(model, "o3"))
    {
        return .openai;
    }
    if (model_name.startsWithIgnoreCase(model, "gemini")) return .gemini;
    return .anthropic;
}

test "inferProviderKind:model 前缀选 provider 协议" {
    try std.testing.expectEqual(types.ProviderKind.openai, inferProviderKind("gpt-4o"));
    try std.testing.expectEqual(types.ProviderKind.openai, inferProviderKind("gpt-4o-mini"));
    try std.testing.expectEqual(types.ProviderKind.openai, inferProviderKind("o1-preview"));
    try std.testing.expectEqual(types.ProviderKind.openai, inferProviderKind("o3-mini"));
    try std.testing.expectEqual(types.ProviderKind.gemini, inferProviderKind("gemini-2.5-flash"));
    try std.testing.expectEqual(types.ProviderKind.gemini, inferProviderKind("gemini-2.5-pro"));
    try std.testing.expectEqual(types.ProviderKind.anthropic, inferProviderKind("claude-sonnet-4-20250514"));
    try std.testing.expectEqual(types.ProviderKind.anthropic, inferProviderKind("claude-opus-4-1"));
}

test "compact summary module tests are reachable from root" {
    try std.testing.expect(compact_summary.defaultSystemPrompt().len > 0);
}

/// Argv[0], recorded by `main` for `invokedCommand`.
var started_as: ?[]const u8 = null;

/// Argv[0], copied into `allocator`: on Windows the iterator owns its strings.
fn firstArgument(init: std.process.Init, allocator: std.mem.Allocator) ?[]const u8 {
    var args = argsIter(init);
    defer args.deinit();
    const first = args.next() orelse return null;
    return allocator.dupe(u8, first) catch null;
}

/// The command the user ran (`metacodes-dev` for a side-by-side development
/// install), for the hints that tell them what to run next: a hint naming
/// another install's command signs in that install, not this one (#482).
/// Resolved only when a hint is printed; `scratch` holds the launcher while
/// it is checked.
fn invokedCommand(scratch: std.mem.Allocator) []const u8 {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    return invocation.commandName(scratch, .{
        .launcher = @import("metacodes-internal").platform.paths.launcherEnv(),
        .argv0 = started_as,
        .self_exe = @import("metacodes-internal").platform.paths.selfExeRealPath(&exe_buf),
    });
}

/// What a run prints when it finds no credential: the ways to sign in, as
/// commands of the install that printed it (`command`), the default sign-in
/// that a plain launch reads first. `printLocalConfigHint` and
/// `no_token_printed` follow it.
const auth_required_hint =
    \\Authentication required.
    \\Use one of:
    \\  {[command]s} login
    \\  {[command]s} login --oauth-token-json <token-response.json>
    \\  {[command]s} login --provider <id>
    \\  {[command]s} login --provider <id> --oauth-token-json <token-response.json>
    \\  {[command]s} login --api-key <key>
    \\  export METASK_API_KEY=...
    \\
;

/// The other way in after the sign-ins (#486): a provider key in this
/// install's own `<state root>/.env`.
const local_config_hint =
    \\Or use your own provider key: put it in {[path]s}{[template]s}, then start again.
    \\  How to: {[guide]s}
    \\
;

const no_token_printed = "\nNo token value was printed.\n";

/// What a run prints when the stored Metask login has no model selection.
const incomplete_login_hint =
    \\Metask login is incomplete.
    \\Run `{[command]s} login` in a terminal and select a model and reasoning effort.
    \\Use --model and --reasoning-effort only when intentionally overriding the saved selection.
    \\
;

/// What a `--provider metask` run prints when no usable Metask session is stored.
const metask_session_hint = "Metask session is unavailable or expired; run `{[command]s} login --provider metask` to log in again.\n";

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    // SIGPIPE 全局忽略:向已关闭的 pipe/socket 写(hook 子进程 stdin、web SSE、子进程管道)默认会
    // 收 SIGPIPE 直接杀进程;改成 SIG_IGN → write 返 EPIPE(n<0)由各处的 `n<=0` 分支优雅处理。
    // 必须在任何 spawn/网络之前设一次,覆盖所有模式(TUI/web/headless/subagent)。(Linus H1)
    // 可移植:Windows 无 SIGPIPE → no-op(socket 写返 WSAECONNRESET,各处 n<=0 分支已处理)。
    platform_signal.ignoreBrokenPipe();

    // Windows console 代码页切 UTF-8(任何输出前;否则 GBK 等代码页下启动 banner/日志乱码)。
    // POSIX no-op。正常退出还原;exit()/崩溃路径不还原属可接受残留(Windows Terminal 每 tab 独立)。
    platform_term.initConsoleUtf8();
    defer platform_term.restoreConsoleCp();

    // The release layout resolves rg beside the executable before PATH (#79);
    // the library learns the layout here, before anything — `doctor`
    // included — can resolve it.
    @import("metacodes-internal").util.toolchain.setLayout(if (build_options.release_layout) .release else .development);

    // `metacodes --help` (or `-h`) answers before the rest of startup. The
    // state-dir option, subcommand dispatch and the full Config change nothing
    // about that answer but map code and data the help never uses, and the
    // idle red line is measured on this path (doc/PERF_MEMORY_PRINCIPLES.md
    // §2). `--help` in any later position is still parseArgsInto's.
    if (helpRequestedFirst(init)) {
        printHelp();
        std.process.exit(0);
    }
    keepRuntimeKeyFdFromChildren();
    started_as = firstArgument(init, allocator);

    // `--state-dir` as argv[1] is a global option: it precedes, and applies
    // to, every subcommand below (login, doctor, kg, ...).
    const leading_state_dir = leadingStateDir(init, allocator);
    if (leading_state_dir.value) |dir| applyStateDir(dir);

    if (try maybeRunAuthCommand(init, allocator, leading_state_dir.consumed)) |code| {
        std.process.exit(code);
    }

    var teamwork_host_config: types.Config = .{};
    const teamwork_request = try maybePrepareTeamwork(init, allocator, leading_state_dir.consumed, &teamwork_host_config);
    var config = if (teamwork_request != null) teamwork_host_config else parseArgs(init, allocator);

    if (config.parse_error) |parse_err| {
        std.debug.print("error: {s} (use --help to list supported flags)\n", .{parse_err});
        std.process.exit(2);
    }
    // The web surface's bind address and token (#252/#253): environment
    // fallbacks and the non-loopback refusal, before anything starts.
    if (resolveWebSurface(&config, .{
        .bind = if (std.c.getenv("METACODES_WEB_BIND")) |c| std.mem.span(c) else null,
        .token = if (std.c.getenv("METACODES_WEB_TOKEN")) |c| std.mem.span(c) else null,
    }, allocator)) |refusal| {
        std.debug.print("error: {s}\n", .{refusal});
        std.process.exit(2);
    }
    // The learning turn's print-mode environment and its verdict-source rule.
    if (resolveLearningTurn(&config, .{
        .mode = if (std.c.getenv(learning_turn.MODE_ENV)) |c| std.mem.span(c) else null,
        .host_check_armed = host_check.endOfRunArmedFromEnv(),
    }, allocator)) |refusal| {
        std.debug.print("error: {s} (use --help to list supported flags)\n", .{refusal});
        std.process.exit(2);
    }
    // The isolated verifier's print-mode environment and its pinned-check rule.
    if (resolveVerifier(&config, .{
        .mode = if (std.c.getenv(isolated_verifier.MODE_ENV)) |c| std.mem.span(c) else null,
        .host_check_armed = host_check.endOfRunArmedFromEnv(),
    }, allocator)) |refusal| {
        std.debug.print("error: {s} (use --help to list supported flags)\n", .{refusal});
        std.process.exit(2);
    }
    if (leading_state_dir.value == null) if (config.state_dir) |dir| applyStateDir(dir);

    // Process-mode teammates must bind the complete App initialization to
    // their parent's session. Adopting only after App.init would seed KG,
    // prompts, and provider-visible session state from a random
    // child id, then leave those snapshots stale after the writer switch.
    if (config.teammate_name.len > 0 and (config.teammate_parent_session.len == 0 or config.teammate_lease_id.len == 0)) {
        std.debug.print("error: --teammate requires --parent-session-id and --teammate-lease-id\n", .{});
        std.process.exit(2);
    }
    if (config.teammate_name.len > 0 and config.teammate_parent_session.len > 0) {
        const parent = @import("metacodes-internal").core.session_id.SessionId.fromSlice(config.teammate_parent_session) orelse {
            std.debug.print("error: invalid --parent-session-id\n", .{});
            std.process.exit(2);
        };
        if (@import("metacodes-internal").core.session_id.SessionId.fromSlice(config.teammate_lease_id) == null) {
            std.debug.print("error: invalid --teammate-lease-id\n", .{});
            std.process.exit(2);
        }
        if (config.session_id) |explicit| {
            if (!std.mem.eql(u8, explicit, parent.asSlice())) {
                std.debug.print("error: --session and --parent-session-id must match for a teammate\n", .{});
                std.process.exit(2);
            }
        } else {
            config.session_id = allocator.dupe(u8, parent.asSlice()) catch {
                std.debug.print("error: out of memory while binding teammate session\n", .{});
                std.process.exit(2);
            };
        }
    }
    var teammate_key: ?[]u8 = null;
    defer if (teammate_key) |key| std.crypto.secureZero(u8, key);
    if (config.teammate_key_fd) |fd| {
        if (config.teammate_name.len == 0) {
            std.debug.print("error: --teammate-key-fd is only for a teammate process\n", .{});
            std.process.exit(2);
        }
        if (config.api_key != null or std.c.getenv(auth.RUNTIME_API_KEY_FD_ENV) != null) {
            std.debug.print("error: --teammate-key-fd cannot be combined with --api-key or METACODES_API_KEY_FD\n", .{});
            std.process.exit(2);
        }
        teammate_key = teammate_route_mod.takeHandedKey(allocator, fd) catch |err| {
            std.debug.print("error: the key handed on --teammate-key-fd cannot be used: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        config.api_key = teammate_key.?;
    }

    if (config.show_version) {
        // `--json` is the headless output flag; with `--version` it selects the
        // build identity document (doc/API.md, CLI surface).
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const info = version_info.BuildInfo.fromOptions(build_options);
        const render: *const fn (*std.Io.Writer, []const u8, version_info.BuildInfo) std.Io.Writer.Error!void =
            if (config.json_output) version_info.writeJson else version_info.writeText;
        render(&out.writer, VERSION, info) catch |err| {
            std.debug.print("error: cannot render --version ({s})\n", .{@errorName(err)});
            std.process.exit(1);
        };
        dumpWrite(out.written());
        return;
    }

    // The state root, after `--version` (which needs no state) and before
    // anything that reads or writes some.
    config.state_root = hostStateRoot() catch std.process.exit(2);
    // The CLI does not take the built-in System-One advisor service (#474):
    // a session's request and memory excerpts leave the machine for the
    // advisor only when config.json or METACODES_JEV_URL names one. `doctor`
    // reads the same constant.
    config.jev_builtin_default = @import("metacodes-internal").jev.runtime.CLI_USES_BUILTIN_DEFAULT;
    if (config.state_root.len > 0) {
        // Every subsystem writes beneath the root; create it (and an install's
        // `<prefix>/state` parent chain) once, owner-only, before any of them
        // run. A root that cannot be created (read-only or missing home) is
        // what a missing $HOME always was: each subsystem degrades on its own.
        @import("metacodes-internal").util.fs.mkdirParents(config.state_root) catch |err| {
            std.debug.print("warning: cannot create the state root {s} ({s}); sessions, credentials and memory will not persist\n", .{ config.state_root, @errorName(err) });
        };
        @import("metacodes-internal").core.context_caps.configureStateRoot(config.state_root);
    }

    // `--resume <id>` binds the App to the stored session before it is built,
    // as the daemon's restore does (#254): KG summary, permission routing and
    // the transcript writer start as that session, and no new session
    // directory is made. The conversation loads once the App exists.
    if (config.resume_session) |query| {
        config.session_id = resolveResumeSession(allocator, config.state_root, query) catch std.process.exit(1);
    }

    // 初始化日志：读 METACODES_LOG / METACODES_LOG_FILE 环境变量
    const log = @import("metacodes-internal").util.log;
    log.initFromEnv();
    if (config.verbose) log.enableVerbose();

    const command_line_base_url = config.base_url;
    // --- env fallback:base_url / record_dir(CLI flag 优先,env 兜底)---
    if (config.base_url == null) {
        if (std.c.getenv("METACODES_BASE_URL")) |c| config.base_url = std.mem.span(c);
    }
    applyAuthPrecedenceEnv(&config);
    if (config.record_dir == null) {
        if (std.c.getenv("METACODES_RECORD_DIR")) |c| config.record_dir = std.mem.span(c);
    }
    if (std.c.getenv("METACODES_LONG_HORIZON_ARM")) |c| {
        const value = std.mem.span(c);
        config.long_horizon_arm = types.LongHorizonArm.parse(value) orelse {
            std.debug.print("error: invalid METACODES_LONG_HORIZON_ARM '{s}'\n", .{value});
            std.process.exit(2);
        };
    }

    // `--check-providers` is a dry run: it validates the configuration and
    // prints the routes it produces before any credential is resolved or any
    // request URL is built, which is exactly when a bad definition should be
    // explained.
    if (config.check_providers) {
        std.process.exit(checkProviders(allocator));
    }

    if (interactiveRepl(config)) offerUpdate(init, allocator, config.state_root);

    // --- <state root>/.env (#486) ---
    // The install's local configuration, read once: a layer below the process
    // environment for the names it may set (apps/cli/src/app/state_env.zig), never
    // setenv. It outlives every App built from `config`: they borrow it.
    var local_config = loadLocalConfig(init.gpa, allocator, config.state_root);
    defer local_config.deinit();
    // The TUI gets its warning in the log, once it owns the terminal (below).
    const tui_owns_stderr = interactiveRepl(config) and !config.verbose and platform_term.isatty(2);
    if (!tui_owns_stderr) warnLocalConfig(allocator, &local_config, .stderr);
    config.credential_env_fallback = local_config.lookup();

    // --- provider 选择 ---
    // issue #16:命名一个 provider profile 时走 registry 解析出**真实路由**
    // (endpoint + 协议 + wire model id + auth scheme),不再靠 model 名前缀猜。
    // 没命名 provider 的会话保持历史推断路径,行为零变化。
    //
    // The startup order (#486, #489), first that applies wins:
    //   1. flags and the process environment: --provider, --offer,
    //      METACODES_PROVIDER (--model and METACODES_MODEL pick the model);
    //   2. a preset named at start: --preset, METACODES_PRESET;
    //   3. the preset the working directory remembers;
    //   4. the default stored by /model (config.json `global_selection`);
    //   5. a Metask sign-in: --api-key, METASK_API_KEY, auth.json — the
    //      historical path. The file's METASK_API_KEY counts only while the
    //      file chooses nothing but Metask (its preset or its provider);
    //   6. `<state root>/.env`: its preset, else the provider it configures;
    //   7. none: the historical path stops at credential resolution.
    // A file that simply fed the environment would put its
    // METACODES_PROVIDER in level 1, above a stored default and a sign-in.
    if (config.provider_profile == null) {
        if (std.c.getenv("METACODES_PROVIDER")) |c| config.provider_profile = std.mem.span(c);
    }
    // `METACODES_MODEL` is `--model` from the environment; the flag wins.
    if (!config.model_explicit) if (nonEmptyEnv(state_env_mod.model_variable)) |model| {
        config.model = model;
        config.model_explicit = true;
    };
    // A Metask access token carries the gateway origin. Resolve it before the
    // declarative route so the legacy napi endpoint cannot win when a new
    // session exists. An explicit METASK_GATEWAY_URL is the documented local
    // development override and is an origin, never a /v1/messages URL.
    // The levels, decided once from what they read (apps/cli/src/app/startup_order.zig;
    // `metacodes login status` shows the same decision).
    const preset_facts = presetFacts(allocator, config, &local_config, false);
    // The file's METASK_API_KEY as the historical path reads it: everywhere
    // that path looks (the sign-in check, the legacy route, credential
    // resolution), or nowhere — never only some of them (localSignInKey).
    const local_metask_key = localSignInKey(allocator, &local_config, &preset_facts);
    const startup_facts = startupFacts(allocator, config, &local_config, local_metask_key, &preset_facts);
    const startup_decision = startup_order.decide(startup_facts);
    const metask_legacy_requested = startup_facts.metask_key_requested;
    // Level 4 (#485): a stored default counts only while its provider has a
    // credential; one that lacks it is passed over for the levels below, and
    // the start says so once (`skipped_default_notice`).
    const stored_default: StoredDefault = startup_facts.stored_default;
    // Whether a flag, the shell or a preset named the route: then nothing
    // below is a "default" the start chose for the user.
    const named_at_start = startup_facts.named or startup_decision.byPreset();
    // Level 5 by the Metask session (#499, #527): the browser sign-in
    // (`/login`, `metacodes login`) and the device code both store it, and a
    // plain launch signs in with it the way `--provider metask` does. A key
    // that signs Metask in (`--api-key`, `METASK_API_KEY`, a key in
    // `auth.json`) is the historical path's and keeps serving it.
    const metask_session_sign_in = startup_decision == .metask_session;
    // Level 6. Nothing below a stored default or a sign-in reads the file's
    // choice, and a key that is only in the shell environment never selects
    // a provider: those keys were not put there for metacodes.
    var unchosen_local_providers: []const []const u8 = &.{};
    const local_choice = startup_facts.local;
    if (startup_decision == .local_provider or startup_decision == .local_unchosen) {
        switch (local_choice) {
            .none => {},
            .several => |ids| unchosen_local_providers = ids,
            .provider => |chosen| {
                if (chosen.named and !providerKnown(allocator, chosen.name)) {
                    std.debug.print("error: {s}={s} in {s} names no provider this install has; `{s} --check-providers` lists them\n", .{
                        state_env_mod.provider_variable, chosen.name, local_config.path, invokedCommand(allocator),
                    });
                    std.process.exit(2);
                }
                config.provider_profile = chosen.name;
                if (!config.model_explicit) if (local_config.get(state_env_mod.model_variable)) |model| {
                    config.model = model;
                    config.model_explicit = true;
                };
                log.info("config", "provider {s} from {s}", .{ chosen.name, local_config.path });
            },
        }
    }
    // Levels 2, 3 and 6 by a preset (#489): it names its route as the flags
    // would, so everything below treats it as a named provider. A preset
    // config.json does not define decides nothing (`presetNotice`).
    const preset_notice = presetNotice(allocator, config, &preset_facts, startup_order.unknownPresets(startup_facts, startup_decision), local_config.path);
    const preset_applied = applyDecidedPreset(&config, allocator, &local_config, &preset_facts, startup_decision);
    if (startup_decision == .directory_unchosen and !(config.dump_prompt or config.dump_plugins) and
        !(interactiveRepl(config) and platform_term.isatty(0)))
    {
        std.debug.print("{s}", .{unchosenDirectoryError(allocator, &preset_facts)});
        std.process.exit(2);
    }
    if (metask_session_sign_in) {
        config.provider_profile = "metask";
        // The model and reasoning level the sign-in chose (`auth.json`): the
        // route below is resolved for that model, and decides it from there.
        applyStoredLoginSelection(allocator, &config) catch |err| {
            log.debug("auth", "stored model selection unavailable: {s}", .{@errorName(err)});
        };
    }
    var startup_metask: ?provider_oauth_mod.Session = null;
    defer if (startup_metask) |*session| session.deinit();
    const requested_base_url = config.base_url;
    const infer_metask_gateway = requested_base_url == null and !metask_legacy_requested;
    if (infer_metask_gateway and std.ascii.eqlIgnoreCase(config.provider_profile orelse "", "metask")) {
        const session = try loadStartupMetask(&startup_metask, init.gpa, config.state_root);
        config.base_url = try startupMetaskGateway(allocator, session);
    }
    // Whether level 4 decided the route: a stored Metask default then also
    // takes the browser sign-in's key (`browserSignInKey`).
    var stored_default_applied = false;
    if (config.provider_profile) |profile_name| {
        applyProviderRoute(&config, allocator, profile_name);
    } else if (config.provider_offer != null) {
        // An offer id names its own provider; requiring `--provider` beside it
        // would make a copied offer id unusable on its own.
        applyProviderRoute(&config, allocator, null);
    } else if (stored_default.consulted() and applyPersistedGlobalSelection(&config, allocator)) {
        stored_default_applied = true;
    } else {
        config.provider_kind = inferProviderKind(config.model);
    }

    const saved_selection = stored_default_applied or preset_applied;
    if (stored_default_applied and requested_base_url != null and selectedProfileIsMetask(config)) {
        config.base_url = metaskEndpointBase(requested_base_url.?);
        applyProviderRoute(&config, allocator, "metask");
    } else if (infer_metask_gateway and startup_metask == null and std.ascii.eqlIgnoreCase(config.resolved_provider_id orelse "", "metask")) {
        const session = try loadStartupMetask(&startup_metask, init.gpa, config.state_root);
        if (session.tokens != null) if (try startupMetaskGateway(allocator, session)) |gateway| {
            config.base_url = gateway;
            applyProviderRoute(&config, allocator, "metask");
        };
    }

    // --- OpenAI wire 协议:env METACODES_OPENAI_PROTOCOL 显式覆盖 CLI(同 auth_precedence 约定)。
    // 词表 responses | chat | chat_completions;词表外 fail-closed(不许静默落默认端点)。
    // **绝不从 base_url/model 推断**——协议选择是显式配置。
    if (std.c.getenv("METACODES_OPENAI_PROTOCOL")) |c| {
        const value = std.mem.span(c);
        config.openai_protocol_explicit = true;
        config.openai_protocol = types.OpenAIProtocol.parse(value) orelse {
            std.debug.print("error: invalid METACODES_OPENAI_PROTOCOL '{s}'\n", .{value});
            std.process.exit(2);
        };
    }
    if (std.ascii.eqlIgnoreCase(config.provider_profile orelse "", "metask") and config.openai_protocol_explicit and config.openai_protocol == .responses) {
        std.debug.print("error: Metask exposes the OpenAI chat/completions route, not Responses API\n", .{});
        std.process.exit(2);
    }

    // --- 预置应答队列(Stage 3):--answers-file 优先,METACODES_ANSWERS env 兜底 ---
    if (config.answers_file) |p| {
        answer_queue.loadFromFile(allocator, p) catch |e|
            log.warn("answers", "load answers-file {s} failed: {s}", .{ p, @errorName(e) });
    } else if (std.c.getenv("METACODES_ANSWERS")) |c| {
        answer_queue.loadFromFile(allocator, std.mem.span(c)) catch |e|
            log.warn("answers", "load METACODES_ANSWERS failed: {s}", .{@errorName(e)});
    }

    // --- record/replay cassette 录制目录(Stage 7)---
    if (config.record_dir) |dir| recorder.setDir(dir);

    // 交互式 TUI 拥有终端:禁止日志写 stderr(fd 2),否则 err/warn 与渲染(render_region.flush 也走
    // std.debug.print→fd 2)字节级交错,把固定区写花、滚屏 desync。日志仍写文件(METACODES_LOG_FILE)。
    // **gate 必须查渲染所在的 fd 2**(不是 fd 1):`metacodes >file` 只重定向 stdout、TUI 仍渲染到 fd 2 的
    // 终端,此时也要抑制日志。verbose(用户显式要日志)/ fd 2 非 tty(无终端可写花)不关。
    // **必须在 App.init 之前**:init 期的 warn/err(如 KG 降级告警)否则抢在 gate 前直接打进终端,
    // 留在 TUI 上方成残行,且超宽行在 strict-autowrap 终端还会折行挤歪整屏。
    // 非 TUI 模式(teammate/serve/web/resume/headless/dump)无渲染流,保留 stderr 日志。
    const interactive_tui = interactiveRepl(config);
    const quiet_stderr = interactive_tui and !config.verbose and platform_term.isatty(2);
    if (quiet_stderr) log.setStderrEnabled(false);
    if (quiet_stderr) warnLocalConfig(allocator, &local_config, .log);
    // The REPL shows its prompt while MCP servers connect and TinyKG comes
    // up, and joins both before its first request; every other frontend
    // waits for them in App.init.
    if (interactive_tui) {
        config.mcp_connect = .first_request;
        config.kg_connect = .first_request;
    }

    // Introspection builds the same App/Plugin snapshot but cannot issue a
    // provider request, so it neither requires credentials nor consumes the
    // one-shot runtime FD authority. Every executable Run path still resolves
    // credentials before App/job/tool subprocesses exist.
    const introspection_only = config.dump_prompt or config.dump_plugins;
    // issue #16: a non-Metask provider profile resolves its credential in its
    // own scope. Metask (and every session that names no provider) keeps the
    // historical path unchanged.
    const metask_scope = selectedProfileIsMetask(config);
    // The device session is the default for the named provider. An API key is
    // still available as an explicit compatibility path: `--api-key` or the
    // documented `METASK_API_KEY` alias opts into the historical napi route
    // when no session gateway has been selected. `oauth_first` keeps a stored
    // session authoritative even if that ambient alias is present.
    const metask_legacy_explicit = metask_legacy_requested;
    var provider_secret: ?[]u8 = null;
    var start_key_from_flag = false;
    var runtime_fd_credential: ?auth.ResolvedCredential = null;
    defer if (runtime_fd_credential) |*credential| credential.deinit(allocator);
    var metask_oauth_selected = false;
    // Same handling as `ResolvedCredential.deinit`: zero the bytes before
    // returning them to the allocator so key material does not linger in freed
    // heap or a core dump.
    defer if (provider_secret) |secret| {
        provider_oauth_mod.secureFree(if (metask_oauth_selected) init.gpa else allocator, secret);
    };
    // Where the session's credential came from, for the banner (#484): every
    // credential the Metask scope resolves is Metask's.
    var credential_origin: route_state_mod.CredentialOrigin = .metask;
    // Only the interactive TUI has someone to tell what is missing (#484):
    // `-p`, `-`, `serve`, `--web`, resumed suspensions, teammates and a REPL
    // whose input is a pipe stop at once, non-zero, as scripts expect.
    const may_open_unbound = interactive_tui and platform_term.isatty(0);
    var unbound: ?route_state_mod.Unbound = if (startup_decision == .directory_unchosen and !introspection_only) .{ .directory_unchosen = .{
        .directory = preset_facts.directory,
        .config_path = preset_facts.config_path,
        .presets = preset_facts.defined,
        .unreadable = preset_facts.unreadable,
    } } else null;
    const resolves_credential = !introspection_only and unbound == null;
    const runtime_key_named = startup_decision == .named and std.c.getenv(auth.RUNTIME_API_KEY_FD_ENV) != null;
    if (resolves_credential and metask_scope and config.provider_profile != null and
        std.ascii.eqlIgnoreCase(config.provider_profile.?, "metask") and !metask_legacy_explicit and !runtime_key_named)
    {
        var browser_key = false;
        const session = try loadStartupMetask(&startup_metask, init.gpa, config.state_root);
        provider_secret = resolveMetaskBearer(session, init.io) catch |err| blk: {
            if (err == error.GatewayChanged) {
                std.debug.print("Metask's model gateway changed. Restart the command to use the saved session.\n", .{});
                return err;
            }
            const no_sign_in = err == error.RefreshRejected or err == error.NoTokens or err == error.NoSession;
            // Level 4 (#485): a stored Metask default with no device-code
            // session authenticates with the browser sign-in's key, on the
            // stored route, as the historical path would; so does a Metask
            // preset (#489).
            if (no_sign_in and saved_selection) if (browserSignInKey(allocator, config.state_root)) |key| {
                config.base_url = if (requested_base_url) |url| metaskEndpointBase(url) else null;
                applyProviderRoute(&config, allocator, "metask");
                browser_key = true;
                break :blk key;
            };
            // Level 1 (#485): Metask was named and has no sign-in. The TUI
            // opens on nothing rather than on another provider.
            if (no_sign_in and may_open_unbound) {
                unbound = .{ .missing_credential = provider_ids_mod.Slug.lit("metask") };
                break :blk null;
            }
            if (no_sign_in) {
                std.debug.print(metask_session_hint, .{ .command = invokedCommand(allocator) });
            } else {
                std.debug.print("Metask OAuth refresh failed: {s}\n", .{@errorName(err)});
            }
            return err;
        };
        metask_oauth_selected = provider_secret != null and !browser_key;
        if (metask_oauth_selected) config.metask_session_gateway = try allocator.dupe(u8, session.tokens.?.gateway_url orelse "");
    } else if (resolves_credential and metask_scope and metask_legacy_explicit) {
        const scoped = resolveProviderScopedCredential(allocator, config, "metask") catch |err| return err;
        provider_secret = scoped.secret;
        start_key_from_flag = scoped.origin == .flag;
    } else if (resolves_credential and !metask_scope) {
        // Level 1 (and 2 to 4 and 6, which name their provider the same way): a
        // provider without a key opens the TUI unbound, naming the key it
        // needs (#485, 第十节第 3 条); `-p` and the rest stop with its help.
        const report: CredentialReport = if (may_open_unbound) .quiet else .print_help;
        if (runtime_key_named) {
            runtime_fd_credential = auth.resolveRuntimeCredential(allocator, config.state_root, config.api_key, config.auth_precedence) catch |err| {
                std.debug.print("error: the key passed on METACODES_API_KEY_FD cannot be used: {s}\n", .{@errorName(err)});
                return err;
            };
            config.api_key = runtime_fd_credential.?.bearer_token;
        }
        if (resolveProviderScopedCredentialReporting(allocator, config, config.provider_profile.?, report)) |scoped| {
            provider_secret = scoped.secret;
            credential_origin = scoped.origin;
            start_key_from_flag = scoped.origin == .flag;
        } else |err| {
            if (!may_open_unbound or err != error.MissingCredentials) {
                // Any other refusal (conflicting variables) still stops the
                // start, with the help it always printed.
                if (report == .quiet) {
                    if (resolveProviderScopedCredentialReporting(allocator, config, config.provider_profile.?, .print_help)) |again| {
                        std.crypto.secureZero(u8, again.secret);
                        allocator.free(again.secret);
                    } else |_| {}
                }
                return err;
            }
            const named = provider_ids_mod.Slug.parse(config.resolved_provider_id orelse config.provider_profile.?) catch provider_ids_mod.Slug.lit("unknown");
            unbound = .{ .missing_credential = named };
        }
    }

    // The compiled Metask profile keeps the legacy Messages route so old
    // model-only selections remain unambiguous. Once the caller explicitly
    // asks for the OpenAI Chat wire, switch the transport to the authenticated
    // catalog's chat endpoint; App.init will then construct OpenAIClient and
    // catalog ingestion below can pin the dynamic OpenAI offer.
    if (config.provider_profile) |profile_name| if (std.ascii.eqlIgnoreCase(profile_name, "metask") and config.openai_protocol_explicit) {
        const current = config.base_url orelse {
            std.debug.print("error: Metask gateway route has no endpoint; run `{s} login --provider metask`\n", .{invokedCommand(allocator)});
            std.process.exit(2);
        };
        const origin = app_mod.MetaskKeyRoute.gatewayOriginOf(current) orelse current;
        config.base_url = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{origin});
        allocator.free(current);
        config.provider_kind = .openai;
    };

    // Level 7 of the startup order (#484): with no credential at all, the
    // interactive TUI opens unbound — no model, nothing sent, a reminder of
    // what to set up — instead of exiting (`may_open_unbound`).
    var resolved_credential: ?auth.ResolvedCredential = null;
    if (!introspection_only and provider_secret == null and unbound == null) {
        resolved_credential = auth.resolveRuntimeCredentialWithEnvFallback(allocator, config.state_root, config.api_key, config.auth_precedence, local_metask_key) catch |err| blk: {
            if (may_open_unbound and err == error.MissingCredentials) {
                log.info("auth", "no credential: the TUI opens without a model", .{});
                unbound = .nothing_configured;
                break :blk null;
            }
            @import("metacodes-internal").util.log.err("auth", "credential resolution failed: {s}", .{@errorName(err)});
            std.debug.print(auth_required_hint, .{ .command = invokedCommand(allocator) });
            printLocalConfigHint(&local_config, unchosen_local_providers);
            std.debug.print(no_token_printed, .{});
            return err;
        };
    }
    defer if (resolved_credential) |*credential| credential.deinit(allocator);
    if (resolved_credential) |credential| start_key_from_flag = credential.source == .cli_api_key or credential.source == .fd_api_key;
    config.metask_oauth_selected = metask_oauth_selected;

    // The stored Metask login carries a Metask model and reasoning effort;
    // applying it to another provider's route would silently replace the
    // selected model.
    if (metask_scope and startup_decision != .directory_unchosen) {
        applyStoredLoginSelection(allocator, &config) catch |err| {
            log.debug("auth", "stored model selection unavailable: {s}", .{@errorName(err)});
        };
    }
    if (metask_scope) if (resolved_credential) |credential| if (!isUsableConfiguredSession(config, credential.source)) {
        // A sign-in without a key and model to run: the TUI opens unbound
        // (the reminder says so; `/login` finishes it), anything else stops.
        if (!may_open_unbound) {
            std.debug.print(incomplete_login_hint, .{ .command = invokedCommand(allocator) });
            return error.IncompleteLoginSelection;
        }
        log.info("auth", "Metask login is incomplete: the TUI opens without a model", .{});
        unbound = .metask_login_incomplete;
    };
    // Unbound, the session holds no key at all: none is ever sent.
    const api_key = if (unbound != null)
        ""
    else if (provider_secret) |secret|
        @as([]const u8, secret)
    else if (resolved_credential) |credential|
        @as([]const u8, credential.bearer_token)
    else
        "";
    // Level 4 passed over (#485): said once — in the TUI under its banner,
    // elsewhere on stderr now — with what this start uses instead.
    const skipped_default_notice: ?[]const u8 = switch (stored_default) {
        .lacks_credential => |label| skippedDefaultNotice(allocator, label, if (unbound != null) null else .{
            .model = config.model,
            .origin = credential_origin,
        }),
        else => null,
    };
    if (skipped_default_notice) |notice| if (!interactive_tui) std.debug.print("warning: {s}\n", .{notice});
    // A subscription plan is licensed for a person in a coding tool
    // (`ProviderProfile.subscription_plan`). Said once when nobody is at the
    // keyboard: `-p`, `serve`, a resumed suspension, the REPL reading a pipe.
    // `--web` is a person in a browser and a teammate answers to its lead's
    // session; neither is told. A note, never a refusal.
    const unattended = config.prompt != null or config.serve_port != null or
        config.resume_response != null or (interactive_tui and !may_open_unbound);
    if (unattended and !introspection_only and !metask_scope and provider_secret != null) {
        if (subscriptionPlanName(allocator, config.resolved_provider_id orelse config.provider_profile.?)) |plan|
            std.debug.print("warning: {s} is a subscription plan for interactive use; its terms may not cover -p, serve or CI. Use a pay-as-you-go key for automation.\n", .{plan});
    }
    const local_route = if (startup_facts.global_default) presets_mod.localRoute(&preset_facts, local_choice, local_config.get(state_env_mod.model_variable)) else null;
    // 第七节第 3 条 (#485): `.env` configures a preset or a provider (#489),
    // yet the start is on Metask, which ranks above it (a sign-in or a stored
    // default). Said once under the TUI's banner, with the two ways to the
    // file's route.
    const shadowed_local_notice: ?[]const u8 = shadowed: {
        if (!interactive_tui or named_at_start or unbound != null or credential_origin != .metask) break :shadowed null;
        break :shadowed shadowedLocalNotice(allocator, local_route orelse break :shadowed null);
    };
    // `.env` holds keys of several providers and names none, and nothing
    // above it decided (#486): the TUI opens without a model, as with nothing
    // set up, and says once which providers and that `/model` chooses. `-p`
    // and the rest stopped above, naming them (`printLocalConfigHint`).
    const unchosen_local_notice: ?[]const u8 = unchosen: {
        const reason = unbound orelse break :unchosen null;
        if (!interactive_tui or reason != .nothing_configured) break :unchosen null;
        break :unchosen switch (local_choice) {
            .several => |ids| unchosenLocalNotice(allocator, ids),
            else => null,
        };
    };
    const startup_notice: ?[]const u8 = joinNotices(allocator, &.{ preset_notice, skipped_default_notice, shadowed_local_notice, unchosen_local_notice });

    // The session runs on the general-purpose allocator, never on the process
    // arena `allocator` above: an arena frees nothing, and a session allocates
    // per request, per streamed response and per tool result for hours or
    // days, so on the arena every turn's buffers (and every ArrayList growth
    // step) stayed committed until exit — tens of GB in a multi-day session.
    // Argument and configuration strings stay in the arena; the session reads
    // them and never frees them.
    const gpa = init.gpa;

    // The startup splash plays while App.init runs (MCP connects, catalog
    // fetches), not after it. Only when init's logs cannot reach the
    // terminal: a frame redraws its rows relative to the cursor, and a line
    // written between frames would shift them. The REPL's terminal is settled
    // first, theme and keyboard protocol in one round trip (#327): its query
    // reads stdin, which is the splash's until it ends, and the protocol must
    // be known before the REPL first enters raw mode.
    var splash: repl.Splash = .not_started;
    var init_options: app_mod.App.InitOptions = .{
        .metask_session = &startup_metask,
        .models_cache = interactive_tui,
        .route_state = if (unbound) |why| .{ .unbound = why } else .{ .bound = credential_origin },
        .unchosen_local_providers = switch (local_choice) {
            .several => |ids| ids,
            else => unchosen_local_providers,
        },
        // What `/logout` falls back to (#485): the route `.env` configures,
        // its preset before its provider (#489), whatever this start was
        // decided by.
        .local_route = local_route,
        .startup_notice = startup_notice,
        .command_name = invokedCommand(allocator),
        .command_line_base_url = command_line_base_url,
        .handed_key = if (start_key_from_flag and unbound == null) api_key else null,
    };
    if (interactive_tui) {
        const variant = app_mod.resolveInteractiveTerminal(allocator, config.no_theme, config.state_root);
        init_options.theme_variant = variant;
        if (quiet_stderr or !platform_term.isatty(2)) splash = repl.startSplash(gpa, variant, config.state_root);
    }
    // A Shift+Enter binding `/terminal-setup` put into the terminal (or one
    // that sends the same newline) turns the footer's hint to Shift+Enter.
    if (interactive_tui) @import("repl/input.zig").recordNewlineBinding(@import("app/terminal_setup/setup.zig").bindingLiveHere(gpa, config.state_root));
    const app = app: {
        errdefer repl.stopSplash(splash);
        break :app try app_mod.App.initWithOptions(gpa, init.io, config, api_key, init_options);
    };
    defer app.deinit();
    if (interactive_tui) @import("repl/tui/copy_select.zig").enable(2);

    app.installSigintHandler() catch |err| {
        repl.stopSplash(splash);
        return err;
    };

    if (teamwork_request) |request| {
        const code = teamwork_command.executeWithMcp(allocator, @import("repl/teamwork.zig").appHost(app), request, teamwork_mcp_host) catch |err| {
            std.debug.print("error: teamwork: {s}\n", .{@errorName(err)});
            return err;
        };
        // Return through App.deinit (providers, jobs and IO belong to it).
        if (code != 0) return error.TeamworkRunFailed;
        return;
    }

    log.info("main", "metacodes starting; model={s}", .{config.model});

    // --dump-prompt：打印组装好的 system prompt + 工具 defs(name + description)后退出。
    // 不发网络、不需有效 key。用于验证提示词×工具复刻(工具长描述 + 动态裁剪)。
    if (config.dump_prompt) {
        if (config.dump_prompt_sections) dumpPromptSectionsAndExit(app);
        dumpPromptAndExit(app);
    }
    if (config.dump_plugins) {
        dumpPluginsAndExit(app);
    }

    // SW6 进程外 teammate 模式:`--teammate --agent-name X --team-name Y` → 跑 mailbox 消息循环,
    // 不进 TUI REPL。身份经 CLI args 注入,可 chdir 进 worktree(cwd 隔离)。
    if (config.teammate_name.len > 0) {
        var teammate_host: TeammateHost = .init(app, gpa);
        const code = swarm_teammate_process.run(teammate_host.host(), gpa, .{
            .name = config.teammate_name,
            .team = config.teammate_team,
            .parent_session = config.teammate_parent_session,
            .lease_id = config.teammate_lease_id,
            .cwd = config.teammate_cwd,
        }) catch |err| blk: {
            log.err("swarm", "teammate process failed: {s}", .{@errorName(err)});
            break :blk 1;
        };
        // 所有 run-mode 路径统一:process.exit 跳过 defer app.deinit → MCP/LSP 子进程变孤儿,
        // exit 前显式 deinit(此时 mailbox 循环已退出,App quiescent)。
        app.deinit();
        std.process.exit(code);
    }

    // `GET /health` reports exactly what `--version` prints (#251). The
    // buffer lives in this frame, which every serving path below leaves only
    // through std.process.exit.
    var version_buffer: [version_info.MAX_VERSION_LEN]u8 = undefined;
    const running_version = version_info.fullVersion(&version_buffer, VERSION, version_info.BuildInfo.fromOptions(build_options));

    // U10-D:`serve [port]` daemon 模式 → 经 registry/host/app_driver 跑 session,SIGINT 优雅关停。
    // --sessions N(N ≥ 0)或 --uds → serveMulti(sessions under /s/<id>/*, created and
    // destroyed over HTTP, U10-C/#254)。
    if (config.serve_port) |port| {
        const surface = webSurface(&config, port, running_version);
        if (config.serve_sessions != null or config.uds_path != null) {
            // serveMulti owns `app` from here: a session adopts it, or (N = 0) it is released at once.
            const code = daemon_serve_multi.serveMulti(app, config, api_key, surface, config.serve_sessions orelse 1, multiSessionCap(config), config.uds_path) catch |err| blk: {
                log.err("daemon", "serve-multi failed: {s}", .{@errorName(err)});
                break :blk @as(u8, 1);
            };
            std.process.exit(code);
        }
        const code = @import("daemon/serve.zig").serve(app, gpa, surface) catch |err| blk: {
            log.err("daemon", "serve failed: {s}", .{@errorName(err)});
            break :blk 1;
        };
        // process.exit 跳过 defer app.deinit → MCP/LSP 子进程不 terminate/reap 变孤儿
        // (serve_multi 在 teardownSlot 自行 reap,此路径须显式)。serve 返回时 driver 已 join,安全。
        app.deinit();
        std.process.exit(code);
    }

    // Web 模式:`--web [port]` → 起 HTTP+SSE 服务器驱动 agent loop,不进 TUI REPL。
    if (config.web_port) |port| {
        const code = @import("web/session.zig").run(app, gpa, webSurface(&config, port, running_version)) catch |err| blk: {
            log.err("web", "web session failed: {s}", .{@errorName(err)});
            break :blk 1;
        };
        // 同 serve:exit 前显式 deinit,reap MCP/LSP 子进程。run() 返回时连接线程已 drain,安全。
        app.deinit();
        std.process.exit(code);
    }

    // U8:`--resume-response <json>` → 恢复挂起的 session(read suspend.json→resumeRun),不进 REPL。
    if (config.resume_response) |resp| {
        const code = @import("repl/headless.zig").resumeSuspended(app, gpa, resp, config.json_output) catch |err| blk: {
            std.debug.print("error: headless resume setup failed: {s}\n", .{@errorName(err)});
            break :blk 1;
        };
        app.deinit(); // 同上:reap MCP/LSP 子进程(恢复运行已结束,quiescent)
        std.process.exit(code);
    }

    // Headless 模式：`-p "..."` / stdin pipe → 跑单次 prompt 后退出，不进 REPL。
    if (config.prompt) |p| {
        var model_failure: ?api_model_error.Detail = null;
        const code = @import("repl/headless.zig").run(app, gpa, p, config.images, config.json_output, &model_failure) catch |err| blk: {
            std.debug.print("error: headless setup failed: {s}\n", .{@errorName(err)});
            break :blk 1;
        };
        if (model_failure) |*failure| printNextStep(app, allocator, failure);
        app.deinit(); // 同上:headless 一样跑 MCP/LSP,同款孤儿病(agent loop 已结束,quiescent)
        std.process.exit(code);
    }

    // `--resume <id>`: the App was built as that session (above); load its
    // conversation before the first prompt, or stop before the TUI starts.
    const resumed: ?app_mod.App.ResumedConversation = if (config.resume_session != null)
        app.resumePersistedConversation() catch |err| {
            repl.stopSplash(splash);
            std.debug.print("error: cannot resume session {s}: {s}\n", .{ app.session_id.asSlice(), repl.resumeLoadFailure(err) });
            app.deinit();
            std.process.exit(1);
        }
    else
        null;

    // (stderr 日志 gate 已提前到 App.init 之前——见 interactive_tui;init 期日志同样不得上屏。)
    try repl.run(app, gpa, .{ .resumed = resumed, .splash = splash });
}

pub const TeammateHost = struct {
    app: *app_mod.App,
    gpa: std.mem.Allocator,
    sink: writer_backend.WriterBackend,

    pub fn init(app: *app_mod.App, gpa: std.mem.Allocator) TeammateHost {
        // teammate 权限:绝不读 fd 0(headless 进程 fd 0 可能是 pipe/tty,行为不定)。fail-closed。
        app.permission_ctx.no_interactive_prompt = true;
        // 无 TUI:WriterBackend null-sink 吞流式输出(同 headless.zig),usage 仍累计。
        return .{ .app = app, .gpa = gpa, .sink = .initNullWithUsage(&app.usage) };
    }

    pub fn host(self: *TeammateHost) swarm_teammate_process.Host {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: swarm_teammate_process.Host.VTable = .{
        .adoptSessionIdentity = adoptSessionIdentity,
        .enterWorktree = enterWorktree,
        .stateRoot = stateRoot,
        .isAborted = isAborted,
        .appendUserText = appendUserText,
        .runTurn = runTurn,
    };

    fn of(ctx: *anyopaque) *TeammateHost {
        return @ptrCast(@alignCast(ctx));
    }

    fn adoptSessionIdentity(ctx: *anyopaque, session: session_id.SessionId) anyerror!void {
        return of(ctx).app.adoptSessionIdentity(session);
    }

    fn enterWorktree(ctx: *anyopaque, cwd_abs: ?[]u8, project_dir: ?[]u8) void {
        const self = of(ctx);
        if (cwd_abs) |new_cwd| {
            if (self.app.cwd_abs) |old| self.gpa.free(old);
            self.app.cwd_abs = new_cwd;
        }
        if (project_dir) |new_root| {
            if (self.app.project_dir) |old| self.gpa.free(old);
            self.app.project_dir = new_root;
        }
    }

    fn stateRoot(ctx: *anyopaque) []const u8 {
        return of(ctx).app.stateRoot();
    }

    fn isAborted(ctx: *anyopaque) bool {
        return of(ctx).app.abort.isAborted();
    }

    fn appendUserText(ctx: *anyopaque, text: []const u8) anyerror!void {
        return of(ctx).app.conversation.appendText(.user, text);
    }

    fn runTurn(ctx: *anyopaque, turn: swarm_teammate_process.Host.Turn) anyerror!agent_loop.StopReason {
        const self = of(ctx);
        const app = self.app;
        const backend = self.sink.backend();
        const result = try agent_loop.run(
            &app.conversation,
            app.provider(),
            app.tool_defs,
            &app.permission_ctx,
            loopOptions(app, turn.swarm, turn.session, turn.agent_ident, turn.agent_id),
            &backend,
            self.gpa,
        );
        return result.stop_reason;
    }

    pub fn loopOptions(app: *app_mod.App, sw: *swarm_context.SwarmContext, parent_session: session_id.SessionId, agent_ident: session_id.SessionId, agent_id: []const u8) agent_loop.Options {
        return .{
            .session = parent_session,
            .abort = &app.abort,
            .api_client = app.anthropicClientOrNull(),
            .tool_defs = app.tool_defs,
            .system_prompt = app.system_prompt,
            .preview = app.config.preview.features(),
            .swarm = sw,
            .tasks = &app.tasks,
            .kg = if (app.kg) |*k| k else null,
            .kg_projects_dir = app.kg_projects_dir,
            .dyn_registry = &app.dyn_registry,
            .agents = &app.agents,
            .parent_model = app.activeModel(),
            .project_dir = app.project_dir_or_empty(),
            // task#12(Linus review 第五处):进程外 teammate 的 Bash 也须套 sandbox。此前只传
            // cwd_abs/home_dir/additional_dirs,漏 .sandbox → ctx.sandbox=null → wrapCommand 被跳过,
            // Bash 脱管("共享 App 就以为共享沙箱"的假设缺口)。App 已从 settings 载 sandbox,直接接上。
            .sandbox = app.sandboxPtr(),
            .cwd_abs = app.cwdAbs(),
            .additional_dirs = app.additionalDirs(),
            .home_dir = app.homeDir(),
            .state_root = app.stateRoot(),
            .artifact_root = app.sessionDir() orelse "",
            .tool_result_metrics = &app.tool_result_metrics,
            // agent_ident 仍是进程自己的 24-hex session id，用于通用
            // agent-loop 身份。TinyKG 租约单独使用 name@team，保证宿主自领与
            // 模型后续 TaskUpdate/TaskStop 共用完全相同的 holder 字符串。
            .agent_ident = agent_ident,
            .kg_agent_ident = agent_id,
            .colorize = false,
        };
    }
};

/// `-p`: after the raw error the run printed, one line saying what to do when
/// a retry cannot help — a rejected sign-in or key, or no balance left — with
/// this install's command for `/login` and `--provider` for `/model`
/// (repl/next_step.zig). Nothing for any other failure; the exit code stays.
fn printNextStep(app: *app_mod.App, allocator: std.mem.Allocator, failure: *const api_model_error.Detail) void {
    if (!repl_next_step.applies(failure)) return;
    const line = (repl_next_step.forFailure(allocator, app, failure, .{ .print = invokedCommand(allocator) }) catch return) orelse return;
    std.debug.print("{s}\n", .{line});
}

/// Whether this run ends in the interactive REPL (`repl.run`): no daemon,
/// web, headless, resumed-suspension, teammate or dump frontend was asked
/// for. Only that frontend shows a prompt before its MCP servers connect.
pub fn interactiveRepl(config: types.Config) bool {
    return config.serve_port == null and config.web_port == null and
        config.resume_response == null and config.prompt == null and
        config.teammate_name.len == 0 and !config.dump_prompt and !config.dump_plugins;
}

/// Write pipeable command output directly to stdout, without routing it through
/// stderr-oriented diagnostics or a buffered logger.
fn dumpWrite(bytes: []const u8) void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = pfs.write(1, bytes[pos..][0 .. bytes.len - pos]);
        if (n <= 0) break;
        pos += @as(usize, @intCast(n));
    }
}

fn dumpPromptAndExit(app: *app_mod.App) noreturn {
    dumpWrite("========== SYSTEM PROMPT ==========\n");
    if (app.system_prompt) |sp| {
        dumpWrite(sp);
    } else {
        dumpWrite("(null - build failed)");
    }
    dumpWrite("\n\n========== TOOL DEFINITIONS ==========\n");
    for (app.tool_defs) |d| {
        dumpWrite("\n----- ");
        dumpWrite(d.name);
        dumpWrite(" -----\n");
        dumpWrite(d.description);
        dumpWrite("\n");
    }
    dumpWrite("\n");
    std.process.exit(0);
}

/// `--dump-prompt --sections` (#184): the named sections the system prompt joins,
/// in render order, each with its id, order, class, origin, size and digest,
/// then the prompt digest checked against the prompt App actually built.
fn dumpPromptSectionsAndExit(app: *app_mod.App) noreturn {
    const cwd = @import("metacodes-internal").util.fs.getCwd(app.allocator) catch "";
    const listing = app.cliPromptInput(cwd).list(app.allocator) catch |err| {
        var buf: [96]u8 = undefined;
        dumpWrite(std.fmt.bufPrint(&buf, "prompt sections unavailable: {s}\n", .{@errorName(err)}) catch "prompt sections unavailable\n");
        std.process.exit(1);
    };
    var line: [256]u8 = undefined;
    dumpWrite("========== SYSTEM PROMPT SECTIONS ==========\n");
    for (listing.sections) |section| {
        dumpWrite(std.fmt.bufPrint(&line, "\n----- [{d}] {s} ({s}, {s}) {d} bytes sha256={s} -----\n", .{
            section.order,
            section.id,
            @tagName(section.class),
            @tagName(section.origin),
            section.text.len,
            &std.fmt.bytesToHex(prompt_sections.sha256(section.text), .lower),
        }) catch "\n----- (section header too long) -----\n");
        dumpWrite(if (section.text.len == 0) "(empty)" else section.text);
        dumpWrite("\n");
    }
    const built = if (app.system_prompt) |text| prompt_sections.sha256(text) else null;
    const matches = if (built) |digest| std.mem.eql(u8, &digest, &listing.sha256) else false;
    dumpWrite(std.fmt.bufPrint(&line, "\n========== PROMPT sha256={s} ({s}) ==========\n", .{
        &std.fmt.bytesToHex(listing.sha256, .lower),
        if (matches) "matches the built prompt" else "differs from the built prompt",
    }) catch "\n");
    std.process.exit(if (matches) 0 else 1);
}

fn dumpPluginsAndExit(app: *app_mod.App) noreturn {
    const inventory = app.describePlugins(app.allocator) catch {
        dumpWrite("{\"error\":\"plugin inventory unavailable\"}\n");
        std.process.exit(1);
    };
    dumpWrite(inventory);
    dumpWrite("\n");
    std.process.exit(0);
}

const LoginMode = enum { browser, help, status, api_key, oauth_json };

fn metaskUsesDeviceFlow(mode: LoginMode) bool {
    return mode == .browser;
}

/// `metacodes doctor [--json] [--strict]` (#78): where ripgrep, TinyKG, and the
/// Lean kernels resolve from and whether their digests match what this build pinned. Exit 0;
/// with `--strict`, 1 when a binary is unresolved or mismatched; 2 on an
/// Builds the doctor's KG object with the read-only probe (a diagnosis command
/// must never create or migrate a store). Owned strings only; any allocation
/// failure leaves the report without a `kg` object instead of mixing in statics.
pub fn kgDiagnosis(allocator: std.mem.Allocator, kg: ?*@import("metacodes-internal").kg.client.KgClient, state_root: []const u8) error{OutOfMemory}!?doctor.KgDiagnosis {
    const kclient = kg orelse return try kgDiagnosisOwned(allocator, "unconfigured", "unconfigured", "-", @import("metacodes-internal").kg.client.KgClient.hintFor(.unconfigured));
    kclient.ensureReadyReadOnly();
    const state: []const u8 = if (kclient.ready) "ready" else @tagName(kclient.degradedKind() orelse .unconfigured);
    const transport = kclient.transportName();
    const is_cli = std.mem.eql(u8, transport, "cli");
    // `config` names what the daemon binding was read from: the explicit
    // METACODES_KG_CONFIG file, the METACODES_KG_* triple ("env"), or the
    // default daemon.json (whether or not it exists yet).
    const env_config_path: ?[]const u8 = if (std.c.getenv("METACODES_KG_CONFIG")) |p| std.mem.span(p) else null;
    const env_triple = std.c.getenv("METACODES_KG_URL") != null or std.c.getenv("METACODES_KG_API_KEY") != null or
        std.c.getenv("METACODES_KG_EXPECTED_BUILD_ID") != null;
    const default_path: ?[]u8 = if (!is_cli and !env_triple and env_config_path == null and state_root.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/kg/daemon.json", .{state_root})
    else
        null;
    defer if (default_path) |p| allocator.free(p);
    const config: []const u8 = if (is_cli) "-" else if (env_triple) "env" else (env_config_path orelse default_path orelse "-");
    const hint: []const u8 = if (kclient.ready) "-" else kclient.degradedHint();
    var diagnosis = try kgDiagnosisOwned(allocator, state, transport, config, hint);
    if (diagnosis) |*d| d.autostarts = !kclient.ready and !is_cli and
        @import("app/kg_autostart.zig").wouldStart(kclient.degradedKind() orelse .unconfigured);
    return diagnosis;
}

/// The System-One advisor as a CLI session's `App.init` would configure it
/// (METACODES_JEV_* over config.json `jev`, and the built-in default only if
/// the CLI takes it: `jev.CLI_USES_BUILTIN_DEFAULT`), judged without
/// contacting the service. Strings live in `arena`.
fn jevDiagnosis(arena: std.mem.Allocator, io: std.Io, state_root: []const u8) doctor.JevDiagnosis {
    const jev = @import("metacodes-internal").jev.runtime;
    return switch (jev.resolve(arena, io, state_root, jev.CLI_USES_BUILTIN_DEFAULT, jev.rawFromEnv())) {
        .off => |source| .{ .state = "off", .source = @tagName(source) },
        .invalid => |invalid| .{ .state = "invalid", .source = @tagName(invalid.source), .err = @errorName(invalid.err) },
        .on => |on| if (!@import("metacodes-internal").jev.client.validOrigin(std.mem.trimEnd(u8, on.settings.origin, "/")))
            .{ .state = "invalid", .url = on.settings.origin, .source = @tagName(on.source), .err = "InvalidOrigin" }
        else
            .{ .state = @tagName(on.settings.mode), .url = on.settings.origin, .source = @tagName(on.source) },
    };
}

/// The doctor's view of `<state root>/.env`: names and line numbers, never
/// a value. Borrows `local`; the name lists live in `arena`.
fn localConfigDiagnosis(arena: std.mem.Allocator, local: *const state_env_mod.Loaded) error{OutOfMemory}!doctor.LocalConfigDiagnosis {
    const accepted = try arena.alloc([]const u8, local.accepted.len);
    for (local.accepted, accepted) |entry, *name| name.* = entry.name;
    const ignored = try arena.alloc([]const u8, local.ignored.len);
    for (local.ignored, ignored) |entry, *name| name.* = entry.name;
    return .{
        .path = if (local.path.len == 0) null else local.path,
        .state = @tagName(local.status),
        .accepted = accepted,
        .ignored = ignored,
        .malformed_lines = local.malformed,
        .permissions = local.permissions,
    };
}

fn kgDiagnosisOwned(allocator: std.mem.Allocator, state: []const u8, transport: []const u8, config: []const u8, hint: []const u8) error{OutOfMemory}!?doctor.KgDiagnosis {
    const s = try allocator.dupe(u8, state);
    errdefer allocator.free(s);
    const t = try allocator.dupe(u8, transport);
    errdefer allocator.free(t);
    const c = try allocator.dupe(u8, config);
    errdefer allocator.free(c);
    const h = try allocator.dupe(u8, hint);
    return .{ .state = s, .transport = t, .config = c, .hint = h };
}

/// `metacodes kg install [--store PATH] [--port N]`: provision the local
/// TinyKG runtime. Prints what it did; never prints the API key.
fn runKg(args: *std.process.Args.Iterator, allocator: std.mem.Allocator) u8 {
    const sub = args.next() orelse {
        std.debug.print("usage: metacodes kg install [--config <path>] [--store <path>] [--port <port>]\n", .{});
        return 2;
    };
    if (!std.mem.eql(u8, sub, "install")) {
        std.debug.print("error: unknown kg subcommand '{s}'\n", .{sub});
        return 2;
    }
    var options = kgd_install.Options{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            options.config_path = args.next() orelse {
                std.debug.print("error: --config needs a path\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--store")) {
            options.store_path = args.next() orelse {
                std.debug.print("error: --store needs a path\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            const raw = args.next() orelse {
                std.debug.print("error: --port needs a number\n", .{});
                return 2;
            };
            const port = std.fmt.parseInt(u16, raw, 10) catch 0;
            if (port == 0) {
                std.debug.print("error: --port must be a number between 1 and 65535\n", .{});
                return 2;
            }
            options.port = port;
        } else {
            std.debug.print("error: unknown kg install argument '{s}'\n", .{arg});
            return 2;
        }
    }
    var outcome = kgd_install.run(allocator, hostRoot(), options) catch |err| {
        std.debug.print("error: kg install failed ({s}){s}\n", .{ @errorName(err), kgInstallHint(err) });
        return 1;
    };
    defer outcome.deinit(allocator);
    std.debug.print("TinyKG configured.\n  store:   {s}{s}\n  config:  {s} (0600{s})\n  url:     {s}\n  build:   {s}\n", .{
        outcome.store_path,
        if (outcome.created_store) " (created)" else "",
        outcome.config_path,
        if (outcome.reused_api_key) ", existing key kept" else ", new key",
        outcome.url,
        outcome.build_id[0..],
    });
    // A custom `--config` has to appear in the command too, or following this
    // line starts a service that reads the default configuration instead.
    if (options.config_path) |custom| {
        std.debug.print("Start it with: metacodes kgd --config {s}\n", .{custom});
    } else {
        std.debug.print("Start it with: metacodes kgd\n", .{});
    }
    return 0;
}

fn kgInstallHint(err: anyerror) []const u8 {
    return switch (err) {
        error.BinariesMissing => "; the TinyKG bundle is not staged next to this executable, run `zig build tinykg:stage` or install a release",
        error.NoHome => "; no HOME is set",
        else => "",
    };
}

/// `metacodes kgd [--config PATH] [--store PATH]`: run the TinyKG service in
/// the foreground until interrupted. The port and key come from the same
/// daemon.json the sessions read — there is deliberately no `--port`, so the
/// service cannot bind somewhere its clients do not look.
fn runKgd(args: *std.process.Args.Iterator, allocator: std.mem.Allocator) u8 {
    var options = kgd_runtime.LoadOptions{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            options.config_path = args.next() orelse {
                std.debug.print("error: --config needs a path\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--store")) {
            options.store_override = args.next() orelse {
                std.debug.print("error: --store needs a path\n", .{});
                return 2;
            };
        } else {
            // The port is not a flag here: it lives in the configuration the
            // sessions read, so the service cannot bind somewhere its clients
            // do not look. Change it with `kg install --port`.
            std.debug.print("error: unknown kgd argument '{s}'\nusage: metacodes kgd [--config <path>] [--store <path>]\n", .{arg});
            return 2;
        }
    }
    var config = kgd_runtime.loadConfig(allocator, hostRoot(), options) catch |err| {
        std.debug.print("error: cannot read the TinyKG configuration ({s}){s}\n", .{ @errorName(err), kgdConfigHint(err) });
        return 1;
    };
    defer config.deinit(allocator);
    return kgd_runtime.serve(allocator, config);
}

fn kgdConfigHint(err: anyerror) []const u8 {
    return switch (err) {
        error.ConfigUnreadable => "; run `metacodes kg install` first",
        error.ConfigUnsafe => "; the configuration must be a regular non-symlink file with mode 0600",
        error.BinariesMissing => "; the TinyKG bundle is not staged next to this executable",
        else => "",
    };
}

fn runDoctor(args: *std.process.Args.Iterator, allocator: std.mem.Allocator, io: std.Io) u8 {
    var json = false;
    var strict = false;
    var plain = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            strict = true;
        } else if (std.mem.eql(u8, arg, "--plain")) {
            plain = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            dumpWrite("usage: metacodes doctor [--json | --plain] [--strict]\n");
            return 0;
        } else {
            std.debug.print("usage: metacodes doctor [--json | --plain] [--strict]\n", .{});
            return 2;
        }
    }
    var report = doctor.run(allocator, .{
        .ripgrep_sha256 = build_options.ripgrep_expected_sha256,
        .tinykg_sha256 = build_options.tinykg_expected_sha256,
        .tinykgd_sha256 = build_options.tinykgd_expected_sha256,
        .formal_kernel_sha256 = build_options.formal_kernel_expected_sha256,
        .project_kernel_sha256 = build_options.project_kernel_expected_sha256,
    }) catch |err| {
        std.debug.print("error: doctor could not resolve the runtime binaries ({s})\n", .{@errorName(err)});
        return 1;
    };
    const state_dir = hostRoot();
    report.state_root = if (@import("metacodes-internal").util.state_root.resolve()) |resolved|
        .{ .path = resolved.path, .source = resolved.source.label(), .err = null }
    else |err|
        .{ .path = null, .source = null, .err = @errorName(err) };
    const cwd = @import("metacodes-internal").util.fs.getCwd(allocator) catch "";
    defer if (cwd.len > 0) allocator.free(cwd);
    const hash = @import("metacodes-internal").core.transcript.hashCwd(cwd);
    const domain = std.fmt.allocPrint(allocator, "doctor-{s}", .{hash[0..8]}) catch "doctor";
    defer if (!std.mem.eql(u8, domain, "doctor")) allocator.free(domain);
    var kg = @import("metacodes-internal").kg.client.KgClient.init(allocator, .{ .state_root = state_dir, .domain = domain, .io = io }) catch null;
    defer if (kg) |*kclient| kclient.deinit();
    // KG diagnosis is all-or-nothing: KgDiagnosis.deinit frees every field, so
    // no static fallback string may ever be stored in it. OOM → no kg object.
    report.kg = kgDiagnosis(allocator, if (kg) |*kclient| kclient else null, state_dir) catch |err| blk: {
        @import("metacodes-internal").util.log.warn("doctor", "unable to allocate KG diagnosis ({s}); omitting kg object", .{@errorName(err)});
        break :blk null;
    };
    defer report.deinit(allocator);
    var jev_arena = std.heap.ArenaAllocator.init(allocator);
    defer jev_arena.deinit();
    report.jev = jevDiagnosis(jev_arena.allocator(), io, state_dir);
    // `<state root>/.env` judged as a session would judge it (#486), names only.
    var local_config = state_env_mod.load(allocator, state_dir, localConfigAllowlist(allocator)) catch {
        std.debug.print("error: out of memory while reading the local configuration\n", .{});
        return 1;
    };
    defer local_config.deinit();
    report.local_config = localConfigDiagnosis(allocator, &local_config) catch null;
    var version_buf: [version_info.MAX_VERSION_LEN]u8 = undefined;
    report.version = version_info.fullVersion(&version_buf, VERSION, version_info.BuildInfo.fromOptions(build_options));
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (@import("metacodes-internal").platform.paths.selfExeRealPath(&exe_buf)) |exe| report.install_prefix = @import("metacodes-internal").util.state_root.prefixOf(exe);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    // A person at a terminal gets the readable report; a pipe, a script and
    // `--plain` keep one line per check, which callers parse.
    const human = !json and !plain and @import("metacodes-internal").platform.terminal.isatty(1);
    const rendered = if (json)
        doctor.writeJson(&out.writer, &report)
    else if (human)
        doctor.writeHuman(&out.writer, &report, .{
            .color = std.c.getenv("NO_COLOR") == null and !std.mem.eql(u8, if (std.c.getenv("TERM")) |t| std.mem.span(t) else "", "dumb"),
            .home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else null,
        })
    else
        doctor.writeText(&out.writer, &report);
    rendered catch |err| {
        std.debug.print("error: cannot render the doctor report ({s})\n", .{@errorName(err)});
        return 1;
    };
    dumpWrite(out.written());
    return if (strict and !report.healthy()) 1 else 0;
}

const LeadingStateDir = struct { consumed: u8 = 0, value: ?[]const u8 = null };

/// `--state-dir <dir>` / `--state-dir=<dir>` in argv[1]. Exits 2 on a missing value.
fn leadingStateDir(init: std.process.Init, allocator: std.mem.Allocator) LeadingStateDir {
    var args = argsIter(init);
    defer args.deinit();
    _ = args.next();
    const first = args.next() orelse return .{};
    if (std.mem.startsWith(u8, first, "--state-dir=")) {
        const value = first["--state-dir=".len..];
        if (value.len == 0) stateDirUsage();
        return .{ .consumed = 1, .value = allocator.dupe(u8, value) catch stateDirUsage() };
    }
    if (!std.mem.eql(u8, first, "--state-dir")) return .{};
    const value = args.next() orelse stateDirUsage();
    if (value.len == 0) stateDirUsage();
    return .{ .consumed = 2, .value = allocator.dupe(u8, value) catch stateDirUsage() };
}

/// Whether argv[1] is `--help` or `-h`. parseArgsInto stops at that argument
/// too, so every later argument was already ignored.
fn helpRequestedFirst(init: std.process.Init) bool {
    var args = argsIter(init);
    defer args.deinit();
    _ = args.next();
    const first = args.next() orelse return false;
    return std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h");
}

fn stateDirUsage() noreturn {
    std.debug.print("error: --state-dir needs a directory (metacodes --state-dir <dir> [command ...])\n", .{});
    std.process.exit(2);
}

/// Records `--state-dir`, made absolute against the cwd so a relative root
/// cannot drift when a tool or teammate later changes directory.
fn applyStateDir(dir: []const u8) void {
    const state_root = @import("metacodes-internal").util.state_root;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var join_buf: [std.fs.max_path_bytes]u8 = undefined;
    const absolute = if (std.fs.path.isAbsolute(dir)) dir else blk: {
        const cwd = platform_fs.getCwd(&cwd_buf) orelse {
            std.debug.print("error: --state-dir {s}: cannot read the current directory\n", .{dir});
            std.process.exit(2);
        };
        var fba = std.heap.FixedBufferAllocator.init(&join_buf);
        break :blk std.fs.path.join(fba.allocator(), &.{ cwd, dir }) catch {
            std.debug.print("error: --state-dir {s}: path too long\n", .{dir});
            std.process.exit(2);
        };
    };
    state_root.setFlagOverride(absolute) catch |err| {
        std.debug.print("error: --state-dir {s}: {s}\n", .{ dir, @errorName(err) });
        std.process.exit(2);
    };
}

/// The host's one resolution of the state root (util/state_root.zig), handed
/// down explicitly from here. A configured root that does not resolve
/// (relative METACODES_HOME, broken install.json) stops the process with the
/// exit code 2 instead of falling back to another install's state; no
/// root at all (no $HOME) is "" and subsystems degrade as before.
fn hostStateRoot() error{StateRootRejected}![]const u8 {
    const state_root = @import("metacodes-internal").util.state_root;
    const resolved = state_root.resolve() catch |err| {
        switch (err) {
            error.StateRootNotAbsolute => std.debug.print("error: the state root must be an absolute path (--state-dir / {s})\n", .{state_root.env_variable}),
            error.InstallManifestInvalid, error.InstallManifestUnreadable => std.debug.print(
                "error: this install's {s} is {s}; fix it, or override with --state-dir / {s}\n",
                .{ state_root.manifest_relative_path, if (err == error.InstallManifestInvalid) "invalid" else "unreadable", state_root.env_variable },
            ),
            error.NoStateRoot => return "",
            error.PathTooLong => std.debug.print("error: the state root path is too long\n", .{}),
        }
        return error.StateRootRejected;
    };
    return resolved.path;
}

/// The id of the stored session of the working directory that `--resume
/// <query>` names, by the rule `/resume <id>` uses (`transcript.findSession`).
/// Says why on stderr when there is none.
fn resolveResumeSession(allocator: std.mem.Allocator, state_root: []const u8, query: []const u8) error{ResumeTargetNotFound}![]const u8 {
    if (state_root.len == 0) {
        std.debug.print("error: --resume: there is no state root, so no stored sessions (set HOME or --state-dir)\n", .{});
        return error.ResumeTargetNotFound;
    }
    const cwd = fs_util.getCwd(allocator) catch {
        std.debug.print("error: --resume: cannot read the current directory\n", .{});
        return error.ResumeTargetNotFound;
    };
    defer allocator.free(cwd);
    const list = transcript.listSessions(cwd, .{ .path = state_root }, allocator) catch |err| {
        std.debug.print("error: --resume: cannot list the sessions of {s} ({s})\n", .{ cwd, @errorName(err) });
        return error.ResumeTargetNotFound;
    };
    defer transcript.freeSessionList(list, allocator);
    const entry = transcript.findSession(list, query) orelse {
        std.debug.print("error: no session matching '{s}' in {s} (/resume lists them)\n", .{ query, cwd });
        return error.ResumeTargetNotFound;
    };
    return allocator.dupe(u8, entry.id) catch {
        std.debug.print("error: --resume: out of memory\n", .{});
        return error.ResumeTargetNotFound;
    };
}

/// The state root this host resolved at startup ("" when there is none).
/// Host-only: apps/cli/src/main.zig hands it down; library code never reads it.
fn hostRoot() []const u8 {
    const resolved = @import("metacodes-internal").util.state_root.resolve() catch return "";
    return resolved.path;
}

const install_usage =
    \\usage: metacodes install --prefix <dir> [--state-dir <dir>] [--sdk <agentcore-bundle-dir>]
    \\                         [--link <bin-dir> [--link-name <name>]] [--upgrade]
    \\                         [--allow-downgrade] [--force]
    \\                         [--release-base <url> | --checkout <dir>]
    \\
    \\Installs the release unit this executable belongs to at <dir> as one isolated
    \\install: its own state root (default <dir>/state), kernels, TinyKG and, with
    \\--sdk, the AgentCore SDK under <dir>/sdk/agentcore. --link writes a launcher
    \\into a directory on PATH. Ends with the installed `doctor --strict`.
    \\--upgrade replaces another version of this product's install (state kept),
    \\but never a newer one with an older one unless --allow-downgrade;
    \\--force also replaces foreign files and an existing launcher.
    \\--release-base records the releases mirror this unit came from, and
    \\--checkout the checkout that built it, for `metacodes update`; without
    \\either the install keeps the source its record already names.
    \\
;

fn runInstall(args: *std.process.Args.Iterator, allocator: std.mem.Allocator, io: std.Io) u8 {
    const install = @import("app/install.zig");
    var options: install.Options = .{ .prefix = "" };
    while (args.next()) |arg| {
        const value_of = struct {
            fn get(it: *std.process.Args.Iterator, name: []const u8) ?[]const u8 {
                const value = it.next() orelse {
                    std.debug.print("error: {s} needs a value\n{s}", .{ name, install_usage });
                    return null;
                };
                return value;
            }
        };
        if (std.mem.eql(u8, arg, "--prefix")) {
            options.prefix = absolutePath(allocator, value_of.get(args, arg) orelse return 2) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--state-dir")) {
            options.state_dir = absolutePath(allocator, value_of.get(args, arg) orelse return 2) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--sdk")) {
            options.sdk = absolutePath(allocator, value_of.get(args, arg) orelse return 2) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--link")) {
            options.link_dir = absolutePath(allocator, value_of.get(args, arg) orelse return 2) orelse return 2;
        } else if (std.mem.eql(u8, arg, "--link-name")) {
            options.link_name = allocator.dupe(u8, value_of.get(args, arg) orelse return 2) catch return 1;
        } else if (std.mem.eql(u8, arg, "--upgrade")) {
            options.upgrade = true;
        } else if (std.mem.eql(u8, arg, "--allow-downgrade")) {
            options.allow_downgrade = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--release-base") or std.mem.eql(u8, arg, "--checkout")) {
            if (options.update_source != .keep) {
                std.debug.print("error: --release-base and --checkout name one update source; give one\n{s}", .{install_usage});
                return 2;
            }
            const value = value_of.get(args, arg) orelse return 2;
            const release_source = @import("app/release_source.zig");
            const source = if (std.mem.eql(u8, arg, "--checkout"))
                release_source.parseCheckout(allocator, absolutePath(allocator, value) orelse return 2) catch |err| {
                    std.debug.print("error: --checkout {s}: {s}\n", .{ value, @errorName(err) });
                    return 2;
                }
            else
                release_source.parseBase(allocator, value) catch |err| {
                    std.debug.print("error: --release-base {s}: {s} (an https:// URL, http:// only to a loopback host, without user-info, query or fragment)\n", .{ value, @errorName(err) });
                    return 2;
                };
            options.update_source = .{ .set = source };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            dumpWrite(install_usage);
            return 0;
        } else {
            std.debug.print("error: unknown install argument '{s}'\n{s}", .{ arg, install_usage });
            return 2;
        }
    }
    if (options.prefix.len == 0) {
        std.debug.print("error: --prefix is required\n{s}", .{install_usage});
        return 2;
    }
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = @import("metacodes-internal").platform.paths.selfExeRealPath(&exe_buf) orelse {
        std.debug.print("error: cannot locate this executable\n", .{});
        return 1;
    };
    const source_root = @import("metacodes-internal").util.state_root.prefixOf(exe) orelse {
        std.debug.print("error: this executable is not inside a release unit (<root>/bin/metacodes)\n", .{});
        return 1;
    };
    // The template lists this version's built-in providers (#486).
    options.local_config_template = state_env_mod.renderExample(allocator, &provider_registry.BUILTIN_PROFILES) catch {
        std.debug.print("error: out of memory\n", .{});
        return 1;
    };
    var log: std.Io.Writer.Allocating = .init(allocator);
    defer log.deinit();
    const outcome = install.run(allocator, io, source_root, options, &log.writer) catch |err| {
        dumpWrite(log.written());
        const hint: []const u8 = switch (err) {
            error.NotAReleaseUnit => "run `metacodes install` from an unpacked release archive, or stage one from source: `zig build kernels:stage --prefix <u>` then `zig build release:verify -Drelease-layout=true --prefix <u> $(python3 scripts/kernel_pins.py <u>)`",
            error.UnsupportedManifest => "the unit's manifest.json is not a metacodes-cli schema 2 release manifest",
            error.PrefixOccupied => "the prefix holds files that are not a metacodes install; choose another or pass --force",
            error.DifferentVersionInstalled => "another metacodes version is installed there; pass --upgrade to replace it (its state is kept), or choose another prefix",
            error.NewerVersionInstalled => "a newer metacodes version is installed there (above); pass --allow-downgrade to replace it with this older one (install.sh --allow-downgrade, install.ps1 -AllowDowngrade), or choose another prefix",
            error.DigestMismatch => "a file does not match the release manifest; the unit is damaged",
            error.InvalidSdkBundle => "--sdk must name an unpacked AgentCore bundle (its manifest.json says \"agentcore\")",
            error.LinkOccupied => "the launcher name is taken by something else; pass --link-name or --force",
            error.LinkOwnedByAnotherInstall => "that launcher belongs to another metacodes install (above). Update that install instead (a development install: scripts/install.sh --dev from its checkout; a release: --prefix <its prefix>), install this one beside it with --link-name <another name>, or pass --force to point the launcher here",
            error.SelfCheckFailed => "the installed executable's `doctor --strict` failed (output above)",
            else => "",
        };
        std.debug.print("error: install failed ({s}){s}{s}\n", .{ @errorName(err), if (hint.len > 0) ": " else "", hint });
        return 1;
    };
    dumpWrite(log.written());
    var summary: std.Io.Writer.Allocating = .init(allocator);
    defer summary.deinit();
    summary.writer.print("metacodes {s} is installed at {s}\n  run: {s}\n", .{ outcome.version, outcome.prefix, outcome.launcher orelse outcome.executable }) catch {};
    summary.writer.print("  update: {s} update\n", .{outcome.launcher orelse outcome.executable}) catch {};
    if (outcome.launcher == null) summary.writer.print("  add {s}{c}bin to PATH, or reinstall with --link <dir on PATH>\n", .{ outcome.prefix, std.fs.path.sep }) catch {};
    if (outcome.sdk) |sdk| summary.writer.print("  SDK: {s}\n", .{sdk}) catch {};
    writeInstallNextStep(&summary.writer, outcome.state_root, std.fs.path.basename(outcome.launcher orelse outcome.executable)) catch {};
    dumpWrite(summary.written());
    return 0;
}

/// What to do after installing (#484, 第十节第 9 条), while this install's
/// state root has neither a Metask sign-in (`auth.json`) nor a `.env`: start
/// it and `/login`, or put a provider key in its own `.env`.
fn writeInstallNextStep(w: *std.Io.Writer, state_root: []const u8, command: []const u8) !void {
    if (state_root.len == 0) return;
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    for ([_][]const u8{ "auth.json", state_env_mod.file_name }) |name| {
        const path = std.fmt.bufPrintZ(&path_buf, "{s}{c}{s}", .{ state_root, std.fs.path.sep, name }) catch return;
        if (pfs.exists(path.ptr)) return;
    }
    try w.print("  next: run `{s}` and type /login to sign in to Metask,\n", .{command});
    try w.print("        or put your provider key in {s}{c}{s} (template: {s}), then run it\n", .{
        state_root, std.fs.path.sep, state_env_mod.file_name, state_env_mod.example_file_name,
    });
}

const update_usage =
    \\usage: metacodes [--state-dir <dir>] update [--check] [--version X.Y.Z] [--release-base <url>]
    \\                 [--pull] [--allow-downgrade] [--no-sdk] [--ignore-running] [--json]
    \\
    \\Brings this install up to date from where it came from. A release install
    \\moves to the latest published release (or --version), downloaded from the
    \\base its install record names; --release-base names a mirror, and the
    \\record keeps it. A mirror serves both the archives and their sums: using
    \\one trusts it. A development install is rebuilt from the checkout that
    \\built it (--pull fast-forwards that checkout first). Never moves an
    \\install backwards unless --allow-downgrade.
    \\Refuses while sessions run from the install (--ignore-running overrides
    \\that, except on Windows) and stops this install's TinyKG service.
    \\--check reports and changes nothing: exit 0 when there is nothing to do,
    \\3 when there is. --json prints the result as one JSON document.
    \\
;

fn runUpdate(args: *std.process.Args.Iterator, init: std.process.Init, allocator: std.mem.Allocator) u8 {
    const update = @import("app/update.zig");
    var options: update.Options = .{ .prefix = "", .environ = init.environ_map };
    var json = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            options.check = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "--release-base")) {
            const value = args.next() orelse {
                std.debug.print("error: {s} needs a value\n{s}", .{ arg, update_usage });
                return 2;
            };
            if (std.mem.eql(u8, arg, "--version")) options.version = value else options.release_base = value;
        } else if (std.mem.eql(u8, arg, "--pull")) {
            options.pull = true;
        } else if (std.mem.eql(u8, arg, "--allow-downgrade")) {
            options.allow_downgrade = true;
        } else if (std.mem.eql(u8, arg, "--no-sdk")) {
            options.no_sdk = true;
        } else if (std.mem.eql(u8, arg, "--ignore-running")) {
            options.ignore_running = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            dumpWrite(update_usage);
            return 0;
        } else {
            std.debug.print("error: unknown update argument '{s}'\n{s}", .{ arg, update_usage });
            return 2;
        }
    }
    if (leadingStateDir(init, allocator).value) |dir| options.state_dir = absolutePath(allocator, dir) orelse return 2;
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = @import("metacodes-internal").platform.paths.selfExeRealPath(&exe_buf) orelse {
        std.debug.print("error: cannot locate this executable\n", .{});
        return 1;
    };
    options.prefix = @import("metacodes-internal").util.state_root.prefixOf(exe) orelse {
        std.debug.print("error: this executable is not inside an install (<prefix>/bin/metacodes)\n", .{});
        return 1;
    };

    var stderr_buf: [4096]u8 = undefined;
    // Streaming, not positional: stderr may be a file other writers share.
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buf);
    const outcome = update.run(allocator, init.io, options, &stderr_writer.interface) catch |err| {
        stderr_writer.interface.flush() catch {};
        const usage_error = switch (err) {
            error.OptionNotForSource, error.CheckWithPull, error.InvalidVersion, error.InvalidReleaseBase, error.IgnoreRunningUnsupported => true,
            else => false,
        };
        std.debug.print("error: update failed ({s}){s}{s}\n", .{ @errorName(err), if (updateHint(err).len > 0) ": " else "", updateHint(err) });
        if (json) {
            var doc: std.Io.Writer.Allocating = .init(allocator);
            std.json.Stringify.value(.{ .action = "refused", .@"error" = @errorName(err) }, .{}, &doc.writer) catch {};
            doc.writer.writeByte('\n') catch {};
            dumpWrite(doc.written());
        }
        return if (usage_error) 2 else 1;
    };
    stderr_writer.interface.flush() catch {};
    if (json) {
        var doc: std.Io.Writer.Allocating = .init(allocator);
        outcome.writeJson(&doc.writer) catch {};
        dumpWrite(doc.written());
    }
    if (outcome.checked_only and outcome.changes()) return 3;
    return 0;
}

fn offerUpdate(init: std.process.Init, allocator: std.mem.Allocator, state_root: []const u8) void {
    const update_notice = @import("app/update_notice.zig");
    if (state_root.len == 0 or !terminal_prompt.interactive()) return;
    if (std.c.getenv("METACODES_NO_PROBE") != null or std.c.getenv(update_notice.opt_out_env) != null) return;
    const found = update_notice.releaseInstall(allocator, init.io) orelse return;
    var cache = update_notice.readCache(allocator, init.io, state_root);
    if (update_notice.offered(found, cache)) |latest| {
        std.debug.print(
            "metacodes {s} is available (this install is {s}).\n  1. Update now\n  2. Skip\n  3. Skip until the next version\nChoice [2]: ",
            .{ latest, found.version },
        );
        var answer_buf: [16]u8 = undefined;
        const len = terminal_prompt.readLine(&answer_buf) catch 0;
        switch (update_notice.parseChoice(answer_buf[0..len])) {
            .update => if (installOfferedUpdate(init, allocator, found.prefix, state_root)) std.process.exit(0),
            .skip_version => {
                cache.skipped = latest;
                update_notice.writeCache(allocator, state_root, cache);
            },
            .skip => {},
        }
    }
    if (update_notice.due(found, cache, util_time.nowUnix())) update_notice.startCheck(found, state_root, cache);
}

fn installOfferedUpdate(init: std.process.Init, allocator: std.mem.Allocator, prefix: []const u8, state_root: []const u8) bool {
    const update = @import("app/update.zig");
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buf);
    const outcome = update.run(allocator, init.io, .{ .prefix = prefix, .state_dir = state_root, .environ = init.environ_map }, &stderr_writer.interface) catch |err| {
        stderr_writer.interface.flush() catch {};
        std.debug.print("error: update failed ({s}){s}{s}\n", .{ @errorName(err), if (updateHint(err).len > 0) ": " else "", updateHint(err) });
        return false;
    };
    stderr_writer.interface.flush() catch {};
    if (!outcome.changes()) return false;
    std.debug.print("metacodes is now {s}; run `{s}` again to start it.\n", .{ outcome.to, invokedCommand(allocator) });
    return true;
}

fn updateHint(err: anyerror) []const u8 {
    return switch (err) {
        error.NotAnInstall => "this executable has no install record beside it (etc/metacodes/install.json); install with scripts/install.sh, or `metacodes install --prefix <dir>` from a release unit",
        error.InvalidInstallRecord => "the install record is unreadable; reinstall with scripts/install.sh over the same prefix (its state is kept)",
        error.InvalidUpdateSource => "the install record's update_source is not a valid source; reinstall with scripts/install.sh (--release-base <mirror>, or --dev from the checkout) to rewrite it",
        error.NoCheckoutRecorded => "this is a development install that records no checkout; run scripts/install.sh --dev in its checkout once, and update works from then on",
        error.OptionNotForSource => "--pull applies to a development install, --version and --release-base to a release install",
        error.CheckWithPull => "--check changes nothing, so it cannot --pull; run `git pull` in the checkout, then --check",
        error.InvalidVersion => "--version takes a bare published release, X.Y.Z",
        error.InvalidReleaseBase => "--release-base must be an https:// URL (http:// only to a loopback host) without user-info, query or fragment",
        error.UpdateInProgress => "another `metacodes update` of this install is running",
        error.CheckoutUnsupportedOnWindows => "a development install is rebuilt by scripts/install.sh --dev, which needs a POSIX shell",
        error.GitUnavailable => "git is needed to read the checkout's state, and was not found or failed",
        error.PullFailed => "git pull --ff-only failed (above); settle the checkout, or update without --pull",
        error.SessionsRunning => "processes still run from this install (above)",
        error.IgnoreRunningUnsupported => "on Windows a file in use cannot be replaced, so every process from the install must exit first",
        error.ServiceDidNotStop => "this install's TinyKG service did not stop; end it (`metacodes kgd`) and rerun",
        error.DowngradeRefused => "pass --allow-downgrade to move the install backwards",
        error.StagedUnitMismatch => "the downloaded release is not what its name says (above); nothing was changed",
        error.InstallFailed => "the installer failed (above); rerun `metacodes update` to finish",
        error.ProcessScanFailed => "cannot list the running processes, so the update cannot tell whether the install is in use",
        error.NoLatestTag => "the base's /latest does not redirect to a release tag; is --release-base a mirror of the releases page?",
        error.HttpStatus, error.ConnectFailed, error.TransferFailed => "the release could not be fetched (curl's message above); nothing was changed. Behind a proxy set https_proxy; or name a mirror with --release-base",
        error.DigestMismatch => "a download does not match the release's SHA256SUMS; nothing was changed",
        error.NoCliAsset => "the release has no archive for this platform",
        error.AmbiguousSdk => "the release lists more than one AgentCore SDK for this platform; pass --no-sdk",
        error.MalformedSums, error.DuplicateSum => "the release's SHA256SUMS is malformed; nothing was changed",
        error.CurlUnavailable => "downloads go through curl, as scripts/install.sh's do, and none is on PATH",
        error.InvalidUrl => "curl refused a URL or a redirect to anything but https; nothing was changed",
        error.UnsafeMember, error.UnsupportedMember, error.DuplicateMember, error.NotOneRoot, error.EmptyArchive, error.TooManyMembers, error.TooLarge, error.CorruptArchive => "the release archive is malformed (above); nothing was changed",
        else => "",
    };
}

/// `path` made absolute against the cwd; null (after printing why) on failure.
fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path) catch null;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = platform_fs.getCwd(&cwd_buf) orelse {
        std.debug.print("error: cannot read the current directory to resolve {s}\n", .{path});
        return null;
    };
    return std.fs.path.join(allocator, &.{ cwd, path }) catch null;
}

fn maybePrepareTeamwork(init: std.process.Init, arena: std.mem.Allocator, leading: u8, host_config: *types.Config) !?teamwork_command.Prepared {
    var args = argsIter(init);
    defer args.deinit();
    _ = args.next();
    for (0..leading) |_| _ = args.next();
    var name = args.next() orelse return null;
    var leading_preview: types.PreviewSetting = .inherit;
    while (leading_preview.applyArg(name) catch return null) {
        name = args.next() orelse return null;
    }
    if (!std.mem.eql(u8, name, "teamwork")) return null;
    var options = teamwork_command.parse(arena, &args) catch |err| {
        std.debug.print("error: teamwork: {s}\n{s}", .{ @errorName(err), teamwork_command.help });
        std.process.exit(2);
    };
    if (options.action == .help) {
        dumpWrite(teamwork_command.help);
        std.process.exit(0);
    }
    const state_root = hostStateRoot() catch std.process.exit(2);
    if (options.action == .status) {
        teamwork_command.status(arena, state_root, options.id.?) catch |err| {
            std.debug.print("error: teamwork status: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        std.process.exit(0);
    }
    const cwd = try @import("metacodes-internal").util.fs.getCwd(arena);
    options.host_config.preview = leading_preview.overlay(options.host_config.preview);
    if (options.approve) options.host_config.preview = try @import("metacodes-internal").core.file_config.resolvePreview(arena, state_root, options.host_config.preview);
    const prepared = teamwork_command.prepare(arena, options, state_root, cwd) catch |err| {
        std.debug.print("error: teamwork: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
    if (options.action == .mcp and teamwork_mcp_host == null) {
        std.debug.print("error: teamwork: McpHostUnavailable\n", .{});
        std.process.exit(2);
    }
    const workspace_z = try arena.dupeZ(u8, prepared.workspace);
    if (@import("metacodes-internal").platform.fs.chdir(workspace_z) != 0) return error.WorkingDirectoryUnavailable;
    host_config.* = options.host_config;
    return prepared;
}

fn maybeRunAuthCommand(init: std.process.Init, allocator: std.mem.Allocator, leading: u8) !?u8 {
    var args = argsIter(init);
    defer args.deinit();
    _ = args.next(); // 跳过 argv[0](程序名)
    for (0..leading) |_| _ = args.next(); // a leading --state-dir, already applied
    const cmd = args.next() orelse return null;
    const subcommands = [_][]const u8{ "bench", "doctor", "install", "kgd", "kg", "ledger", "logout", "login", "mcp", "providers", "sealed", "terminal-setup", "update" };
    for (subcommands) |name| {
        if (std.mem.eql(u8, cmd, name)) break;
    } else return null;
    // `doctor` diagnoses a broken state root instead of refusing to start,
    // `install` creates one, and `update` must be able to repair either:
    // none of them needs this process's own.
    if (std.mem.eql(u8, cmd, "doctor")) return runDoctor(&args, allocator, init.io);
    if (std.mem.eql(u8, cmd, "install")) return runInstall(&args, allocator, init.io);
    // `update` repairs an install whose state root may be broken, like `doctor`.
    if (std.mem.eql(u8, cmd, "update")) return runUpdate(&args, init, allocator);
    const state_dir = hostStateRoot() catch return 2;
    if (std.mem.eql(u8, cmd, "bench")) return @import("app/bench_cli.zig").run(&args, allocator, init.io, state_dir);
    if (state_dir.len > 0) @import("metacodes-internal").core.context_caps.configureStateRoot(state_dir);
    if (std.mem.eql(u8, cmd, "kgd")) return runKgd(&args, allocator);
    if (std.mem.eql(u8, cmd, "kg")) return runKg(&args, allocator);
    if (std.mem.eql(u8, cmd, "sealed")) return @import("app/sealed_cli.zig").run(&args, allocator, init.io, state_dir);
    if (std.mem.eql(u8, cmd, "mcp")) return @import("app/mcp_cli.zig").run(&args, allocator, init.io, state_dir, invokedCommand(allocator));
    if (std.mem.eql(u8, cmd, "providers")) return @import("app/providers_cli.zig").run(&args, allocator, init.io, state_dir, invokedCommand(allocator));
    if (std.mem.eql(u8, cmd, "terminal-setup")) return @import("app/terminal_setup/cli.zig").run(&args, allocator, init.io, state_dir);
    if (std.mem.eql(u8, cmd, "ledger")) {
        const provider = args.next() orelse {
            std.debug.print("usage: metacodes ledger metask\n", .{});
            return 2;
        };
        if (!std.mem.eql(u8, provider, "metask") or args.next() != null) {
            std.debug.print("usage: metacodes ledger metask\n", .{});
            return 2;
        }
        const bytes = @import("metacodes-internal").provider.metask_ledger.read(allocator, state_dir) catch |err| {
            if (err == error.NotFound) return 0;
            std.debug.print("error: could not read Metask ledger ({s})\n", .{@errorName(err)});
            return 1;
        };
        defer allocator.free(bytes);
        dumpWrite(bytes);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "logout")) {
        if (args.next()) |extra| {
            if (std.mem.eql(u8, extra, "--provider")) {
                const name = args.next() orelse {
                    std.debug.print("usage: metacodes logout --provider <id>\n", .{});
                    return 2;
                };
                if (args.next()) |more| {
                    std.debug.print("error: unknown logout argument '{s}'\n", .{more});
                    return 2;
                }
                // Metask's sign-ins are what a plain `logout` removes.
                if (providerIsMetask(allocator, name)) return logoutMetask(allocator, state_dir);
                return logoutProviderKey(allocator, state_dir, name);
            }
            std.debug.print("error: unknown logout argument '{s}'\n", .{extra});
            return 2;
        }
        return logoutMetask(allocator, state_dir);
    }
    if (!std.mem.eql(u8, cmd, "login")) return null;

    var mode: LoginMode = .browser;
    var value: ?[]const u8 = null;
    // `--provider <id>` stores the token against that provider's own OAuth
    // session instead of the Metask credential store, which is what keeps a
    // token for one vendor from ever satisfying another.
    var provider_name: ?[]const u8 = null;
    var open_browser = true;
    // Which grant obtains the first token for a non-Metask provider. Loopback
    // PKCE is the desktop default; a headless or SSH session has no browser to
    // open and no loopback address to be redirected to, so it asks for the
    // device-code flow explicitly.
    var login_method: oauth_login.Method = .loopback;
    // The registered OAuth client this installation presents. Not a secret,
    // but not something the profile can guess either.
    var client_id: ?[]const u8 = null;
    // The guided API-key setup (`ProviderProfile.api_key_setup`): which key
    // page, a key read from stdin instead of a hidden prompt, and storing it
    // without the check.
    var key_page: ?[]const u8 = null;
    var key_from_stdin = false;
    var check_key = true;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--key-page")) {
            key_page = args.next() orelse {
                std.debug.print("usage: metacodes login --provider <id> --key-page <page>\n", .{});
                return 2;
            };
            continue;
        } else if (std.mem.eql(u8, arg, "--api-key-stdin")) {
            key_from_stdin = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--no-check")) {
            check_key = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "status") or std.mem.eql(u8, arg, "--status")) {
            mode = .status;
        } else if (std.mem.eql(u8, arg, "--api-key")) {
            mode = .api_key;
            value = args.next() orelse {
                std.debug.print("usage: metacodes login --api-key <key>\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--oauth-token-json")) {
            mode = .oauth_json;
            value = args.next() orelse {
                std.debug.print("usage: metacodes login --oauth-token-json <file>\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--provider")) {
            provider_name = args.next() orelse {
                std.debug.print("usage: metacodes login --provider <id>\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--no-browser")) {
            open_browser = false;
        } else if (std.mem.eql(u8, arg, "--device-code")) {
            login_method = .device_code;
        } else if (std.mem.eql(u8, arg, "--client-id")) {
            client_id = args.next() orelse {
                std.debug.print("usage: metacodes login --provider <id> --client-id <client>\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            mode = .help;
        } else {
            // auth 面同样 fail-closed(2026-08-17 复审 #1):`login --api-kye X`
            // 曾静默丢掉 typo 的 flag 和密钥,转进浏览器 OAuth 并无限挂起——
            // 非交互环境下这是最恶劣的失败形态。
            std.debug.print("error: unknown login/logout argument '{s}'\n", .{arg});
            return 2;
        }
    }

    // `--client-id` and `--device-code` only mean something for a
    // provider-scoped login. Accepting them silently for the Metask flow would
    // run a login the user did not ask for while dropping the argument that
    // says what they wanted — the same fail-closed rule the unknown-argument
    // branch above exists for.
    if (provider_name == null and mode != .help) {
        if (key_page != null or key_from_stdin or !check_key) {
            std.debug.print("error: --key-page, --api-key-stdin and --no-check require --provider <id>\n", .{});
            return 2;
        }
        if (client_id != null) {
            std.debug.print("error: --client-id requires --provider <id>\n", .{});
            return 2;
        }
        if (login_method != .loopback) {
            std.debug.print("error: --device-code requires --provider <id>\n", .{});
            return 2;
        }
    }

    if (provider_name) |name| {
        // A provider whose own site hands out a key (OpenRouter's key grant)
        // signs in there unless a key is given: in the browser, or with
        // `--device-code` on another device.
        if (mode == .browser and key_page == null and !key_from_stdin and check_key and providerDeclaresKeyGrant(allocator, name)) {
            if (client_id != null) {
                std.debug.print("error: that provider signs in without an OAuth client; drop --client-id\n", .{});
                return 2;
            }
            return runProviderKeyGrantLogin(allocator, init.io, state_dir, name, .{
                .open_browser = open_browser,
                .other_device = login_method == .device_code,
            });
        }
        // A provider without an OAuth grant but with a page to create a key on
        // signs in with a pasted key (`ProviderProfile.api_key_setup`).
        if (providerTakesPastedKey(allocator, name, client_id, login_method) or key_page != null or key_from_stdin or !check_key) {
            if (mode == .oauth_json) {
                std.debug.print("error: --oauth-token-json is for providers that sign in with OAuth\n", .{});
                return 2;
            }
            if (mode == .help) {
                printLoginHelp();
                return 0;
            }
            return runProviderKeyLogin(allocator, init.io, state_dir, name, .{
                .key = if (mode == .api_key) value else null,
                .from_stdin = key_from_stdin,
                .page = key_page,
                .open_browser = open_browser,
                .check = check_key,
            });
        }
        // Metask's control plane uses its JSON device grant by default.  Keep
        // this special case before the generic profile flow: the latter sends
        // form-encoded RFC 8628 requests and would violate the Metask contract.
        if (std.ascii.eqlIgnoreCase(name, "metask") and metaskUsesDeviceFlow(mode)) {
            return runMetaskDeviceLogin(allocator, init.io, state_dir, open_browser);
        }
        switch (mode) {
            // The non-interactive path stays supported: CI and headless
            // recovery need a way in that does not involve a browser or a
            // polling loop, and it is the only path when a token was minted
            // somewhere else entirely.
            .oauth_json => return storeProviderOAuthToken(allocator, name, value.?, client_id),
            .browser => return runProviderOAuthLogin(allocator, init.io, name, .{
                .method = login_method,
                .open_browser = open_browser,
                .client_id = client_id,
            }),
            // `--help` is a request for help wherever it appears, not an
            // argument-combination error.
            .help => {
                printLoginHelp();
                return 0;
            },
            .status => {
                std.debug.print("login status is not provider-scoped yet\n", .{});
                return 2;
            },
            .api_key => {
                std.debug.print(
                    "login --provider accepts the interactive flow or --oauth-token-json\n",
                    .{},
                );
                return 2;
            },
        }
    }

    switch (mode) {
        .browser => {
            // A model has to be chosen at a terminal: ask before the browser.
            requireInteractiveLogin() catch |err| {
                std.debug.print("Login setup needs an interactive terminal: {s}\n", .{@errorName(err)});
                return 1;
            };
            if (open_browser and auth.sshSession()) {
                std.debug.print("This looks like an SSH session: signing in with a code you confirm on any device. (--no-browser keeps the browser sign-in.)\n", .{});
                return runMetaskDeviceLogin(allocator, init.io, state_dir, false);
            }
            const timeout_ms = auth.loginCallbackTimeoutMs();
            var stdin_paste: terminal_prompt.StdinPaste = .{};
            const token_json = auth.loginWithBrowserTokenJson(allocator, .{ .open_browser = open_browser, .timeout_ms = timeout_ms, .paste = stdin_paste.source() }) catch |err| {
                if (err == error.CallbackTimedOut) {
                    var wait_buf: [48]u8 = undefined;
                    std.debug.print("No answer from the browser in {s}; nothing was stored. Signing in on another computer? Run `metacodes login --provider metask`.\n", .{terminal_prompt.waitText(&wait_buf, timeout_ms.?)});
                    return 1;
                }
                std.debug.print("OAuth browser login failed: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer {
                std.crypto.secureZero(u8, token_json);
                allocator.free(token_json);
            }
            return finishMetaskSignIn(allocator, init.io, state_dir, token_json, "Signed in to Metask in the browser");
        },
        .help => {
            printLoginHelp();
            return 0;
        },
        .status => {
            try printLoginStatus(allocator, state_dir);
            return 0;
        },
        .api_key => {
            const k = std.mem.trim(u8, value.?, " \t\r\n");
            if (k.len == 0) {
                std.debug.print("Refusing to store an empty API key.\n", .{});
                return 2;
            }
            var stored = auth.loadDefault(allocator, state_dir) catch |err| switch (err) {
                error.NotFound, error.NoHome => auth.StoredCredentials{},
                else => {
                    std.debug.print("Could not read existing credentials: {s}\n", .{@errorName(err)});
                    return 1;
                },
            };
            defer stored.deinit(allocator);
            if (stored.api_key) |old| {
                @memset(old, 0);
                allocator.free(old);
                stored.api_key = null;
            }
            stored.api_key = try allocator.dupe(u8, k);
            runModelSelectionForStoredApiKey(allocator, init.io, &stored) catch |err| {
                std.debug.print("Login setup failed after API key import: {s}\n", .{@errorName(err)});
                return 1;
            };
            try auth.saveDefault(allocator, state_dir, stored);
            std.debug.print("Stored Metask API key. Model and reasoning effort were selected. Token value was not printed.\n", .{});
            return 0;
        },
        .oauth_json => {
            const body = try readFileArg(allocator, value.?);
            defer {
                std.crypto.secureZero(u8, body);
                allocator.free(body);
            }
            return finishMetaskSignIn(allocator, init.io, state_dir, body, "Stored the Metask sign-in from the token response");
        },
    }
}

fn printLoginHelp() void {
    dumpWrite(
        \\Usage:
        \\  metacodes login
        \\  metacodes login --no-browser
        \\  metacodes login status
        \\  metacodes login --oauth-token-json <token-response.json>
        \\  metacodes login --provider <id> [--client-id <client>] [--device-code] [--no-browser]
        \\  metacodes login --provider <id> --oauth-token-json <token-response.json>
        \\  metacodes login --api-key <key>
        \\  metacodes login --provider <id> [--key-page <page>] [--no-browser]
        \\  metacodes login --provider <id> (--api-key <key> | --api-key-stdin) [--key-page <page>] [--no-check]
        \\  metacodes logout
        \\  metacodes logout --provider <id>
        \\
        \\Default login starts a local browser OAuth flow on /auth/metask/callback.
        \\Use --no-browser to print the URL without launching a browser. In an SSH
        \\session, where the browser cannot come back to this machine, it signs in
        \\with the device code instead (--no-browser keeps the browser sign-in, and
        \\prints the ssh -L forward it needs). It waits for the browser 10 minutes
        \\(METACODES_LOGIN_CALLBACK_TIMEOUT_MS; 0 waits without a limit). A browser
        \\on another computer ends on a page that does not load: paste that page's
        \\address at the prompt to finish the sign-in here (also for --provider
        \\sign-ins that wait for a localhost callback).
        \\
        \\`login --provider <id>` signs in to that provider and stores the token
        \\in its own OAuth session, never the Metask credential store. It uses a
        \\loopback-redirect PKCE flow by default; --device-code is the flow for a
        \\headless or SSH session that cannot open a browser. --client-id supplies
        \\the registered OAuth client when the profile declares none.
        \\`login --provider metask` signs in to Metask with a code confirmed on any
        \\device; at a terminal it then asks for the model and reasoning level, as
        \\the browser sign-in does.
        \\
        \\A provider that signs in with an API key (the GLM Coding Plan) opens the
        \\page the key is created on, reads the pasted key without showing it,
        \\checks it with a request the provider does not bill, and stores it in
        \\<state root>/keys/<provider>.json (0600). --key-page picks the page
        \\(cn-personal, cn-team, global-personal, global-team), --no-check stores
        \\the key unchecked, and `logout --provider <id>` removes it.
        \\
        \\A provider whose site creates the key (OpenRouter) signs in there: the
        \\browser on this machine, or with --device-code on another device, whose
        \\page shows a code to paste back here (the way over SSH, which is taken
        \\unasked there unless --no-browser keeps the browser). The key is your
        \\own account's and is stored like a pasted one; `logout --provider <id>`
        \\removes it from this machine and names the page where you delete it.
        \\--api-key-stdin stores a key you created yourself instead.
        \\
        \\`login status` says which credential a plain start here uses and why:
        \\the step of the startup order that decides, and what each step holds
        \\(names, paths and expiry; never a key or a token).
        \\
        \\OAuth token JSON must match the token endpoint response:
        \\access_token, refresh_token, token_type=Bearer, expires_in, and for
        \\Metask gateway_url and models_url. It remains the path for recovery.
        \\The Metask sign-in is stored as the Metask session in
        \\<state root>/oauth/metask.json; its model and reasoning level, and a key
        \\from `login --api-key`, in <state root>/auth.json. Both are 0600
        \\(see `metacodes doctor`).
        \\
    );
}

/// `metacodes login` in the browser or from `--oauth-token-json`, and
/// `metacodes login --provider metask` at a terminal (#527): the model and
/// reasoning level are chosen from the `/v1/models` of the
/// gateway the token response names, asked with its access token; then the
/// token response is stored as the Metask session (`oauth/metask.json`), and
/// the choice in `auth.json`, replacing a key or an older sign-in there (left
/// there they would outrank the session at the next start). A stored `/model`
/// default is forgotten, and a Metask session it replaced revoked (#560), as
/// `/login` does. Prints `done` (no full stop), the account it signed in as
/// when the server says, on success.
fn finishMetaskSignIn(allocator: std.mem.Allocator, io: std.Io, state_dir: []const u8, token_json: []const u8, done: []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const outcome = provider_oauth_mod.parseTokenResponse(arena.allocator(), token_json) catch |err| {
        std.debug.print("The Metask token response is not usable: {s}\n", .{@errorName(err)});
        return 1;
    };
    const gateway = api_metask_sign_in.gatewayOf(arena.allocator(), token_json) orelse {
        std.debug.print("The Metask token response names no gateway (gateway_url).\n", .{});
        return 1;
    };
    const models_url = std.fmt.allocPrint(arena.allocator(), "{s}/v1/models", .{gateway}) catch return 1;
    const fetched = @import("metacodes-internal").api.catalog_fetch.fetchModelPages(allocator, io, .{ .url = models_url, .bearer = outcome.access_token }) catch |err| {
        std.debug.print("Signed in, but the models could not be listed ({s}); nothing was stored.\n", .{@errorName(err)});
        return 1;
    };
    defer allocator.free(fetched.body);
    // Who signed in, for the line that ends the sign-in; best effort.
    const account = metask_oauth_mod.accountName(allocator, metask_oauth_mod.siteUrl(), outcome.access_token, metask_oauth_mod.ACCOUNT_NAME_WAIT_MS);
    defer if (account) |name| allocator.free(name);
    var catalog = catalog_mod.Catalog.init(allocator);
    defer catalog.deinit();
    catalog.loadFromModelsListJson(fetched.body) catch {};
    // The gateway also lists image and video models: only the ones it serves
    // on `/v1/messages` can run a session.
    catalog.dropMessagesUnsupported();
    const choice = promptModelAndEffort(allocator, &catalog) catch |err| {
        std.debug.print("Login setup failed: {s}; nothing was stored.\n", .{@errorName(err)});
        return 1;
    };

    // The session this one replaces (#560), revoked once the sign-in is stored.
    var replaced = metask_oauth_mod.Replaced.capture(allocator, state_dir);
    defer replaced.deinit();
    var diagnostic: provider_login.ImportDiagnostic = .{};
    provider_login.importTokenResponse(allocator, state_dir, provider_ids_mod.Slug.lit("metask"), token_json, null, &diagnostic) catch |err| {
        std.debug.print("The sign-in was not stored: {s}\n", .{@errorName(diagnostic.cause orelse err)});
        return 1;
    };
    var stored = auth.loadDefault(allocator, state_dir) catch |err| switch (err) {
        error.NotFound, error.NoHome => auth.StoredCredentials{},
        else => {
            std.debug.print("Signed in, but the model choice was not stored: auth.json could not be read ({s}).\n", .{@errorName(err)});
            return 1;
        },
    };
    defer stored.deinit(allocator);
    stored.recordSessionChoice(allocator, catalog.entries.items[choice.model].model_id, choice.effort) catch return 1;
    auth.saveDefault(allocator, state_dir, stored) catch |err| {
        std.debug.print("Signed in, but the model choice was not stored: {s}\n", .{@errorName(err)});
        return 1;
    };
    std.debug.print("{s}{s}{s}. Model {s}, reasoning {s}. Secrets were not printed.\n", .{
        done,
        if (account != null) " as " else "",
        account orelse "",
        catalog.entries.items[choice.model].model_id,
        catalog_mod.effortLabel(catalog.entries.items[choice.model].effort_vocabulary, choice.effort),
    });
    printReplacedNote(replaced.revoke(token_json, metask_oauth_mod.siteUrl(), 5000));
    forgetDefaultForSignIn(allocator, state_dir);
    return 0;
}

/// What a sign-in says about the Metask session it replaced (#560).
fn printReplacedNote(outcome: metask_oauth_mod.ReplacedOutcome) void {
    const note = metask_oauth_mod.replacedNote(outcome) orelse return;
    std.debug.print("{s}{s}\n", .{ if (note.warn) "warning: " else "", note.text });
}

const ModelChoice = struct { model: usize, effort: types.ReasoningEffort };

/// The model and reasoning level, chosen line by line from `catalog`.
fn promptModelAndEffort(allocator: std.mem.Allocator, catalog: *const catalog_mod.Catalog) !ModelChoice {
    try requireInteractiveLogin();
    if (catalog.entries.items.len == 0) return error.NoModels;
    std.debug.print("\nSelect model:\n", .{});
    for (catalog.entries.items, 0..) |entry, i| {
        std.debug.print("  {d}. {s}", .{ i + 1, entry.model_id });
        if (entry.max_input_tokens) |ctx| std.debug.print(" ctx={d}", .{ctx});
        if (entry.max_tokens) |out| std.debug.print(" out={d}", .{out});
        std.debug.print("\n", .{});
    }
    const model_idx = try promptChoice(allocator, catalog.entries.items.len);
    const model = catalog.entries.items[model_idx];
    var effort_buf: catalog_mod.ReasoningOptions = undefined;
    const efforts = catalog_mod.reasoningOptions(model.reasoning_mask, &effort_buf);
    if (efforts.len == 1) {
        std.debug.print("\nReasoning effort: {s} (the only choice {s} offers)\n", .{ catalog_mod.effortLabel(model.effort_vocabulary, efforts[0]), model.model_id });
        return .{ .model = model_idx, .effort = efforts[0] };
    }
    std.debug.print("\nSelect reasoning effort:\n", .{});
    for (efforts, 0..) |effort, i| {
        std.debug.print("  {d}. {s}\n", .{ i + 1, catalog_mod.effortLabel(model.effort_vocabulary, effort) });
    }
    const effort_idx = try promptChoice(allocator, efforts.len);
    return .{ .model = model_idx, .effort = efforts[effort_idx] };
}

/// `metacodes login --api-key`: the key's model and reasoning level, from
/// the `/v1/models` its endpoint answers.
fn runModelSelectionForStoredApiKey(allocator: std.mem.Allocator, io: std.Io, stored: *auth.StoredCredentials) !void {
    try requireInteractiveLogin();
    const key = stored.api_key orelse return error.MissingCredentials;
    var c = client.Client.initWithBaseUrl(allocator, io, key, "model-selection", loginMessagesUrl());
    defer c.deinit();
    c.probeModels();
    const choice = try promptModelAndEffort(allocator, &c.catalog);
    if (stored.selected_model) |old| allocator.free(old);
    stored.selected_model = try allocator.dupe(u8, c.catalog.entries.items[choice.model].model_id);
    stored.reasoning_effort = choice.effort;
}

/// `metacodes login` in the browser, as `/login` (#485): the sign-in is the
/// most recent explicit choice, so a stored `/model` default, which would
/// outrank it at the next start, is forgotten. Says what it did; writes
/// nothing when none is stored.
fn forgetDefaultForSignIn(allocator: std.mem.Allocator, state_dir: []const u8) void {
    var store = provider_config_store.Store.initHome(allocator, state_dir) catch return;
    defer store.deinit();
    var document = store.load() catch |err| {
        std.debug.print("warning: the stored default model could not be read ({s}); the next start may use it\n", .{@errorName(err)});
        return;
    };
    defer document.deinit();
    if (document.global_selection == null) return;
    const outcome = provider_config_store.clearGlobalSelection(&store, null) catch |err| {
        std.debug.print("warning: the stored default model could not be cleared ({s}); the next start may use it\n", .{@errorName(err)});
        return;
    };
    if (outcome.cleared) std.debug.print("Forgot the stored default model: new sessions start on Metask.\n", .{});
}

/// The Messages endpoint `metacodes login --api-key` lists the key's models
/// at: `METACODES_BASE_URL` (a local gateway, a test's mock), else Metask's
/// API-key endpoint.
fn loginMessagesUrl() []const u8 {
    if (std.c.getenv("METACODES_BASE_URL")) |u| {
        const value = std.mem.span(u);
        if (value.len > 0) return value;
    }
    return client.ANTHROPIC_API_URL;
}

/// Fetch and keep OpenRouter's listing with a key just stored, so the next
/// start lists the account's models. A failure costs the list, not the key.
fn fetchOpenRouterListing(allocator: std.mem.Allocator, io: std.Io, state_dir: []const u8, key: []const u8) void {
    const count = openrouter_catalog.refresh(allocator, io, state_dir, key, null) catch |err| {
        std.debug.print("warning: OpenRouter's model list could not be fetched ({s}); `/providers refresh` fetches it again\n", .{@errorName(err)});
        return;
    };
    std.debug.print("{d} OpenRouter models take tools; /model lists them.\n", .{count});
}

/// Whether `name` is a provider that declares a key grant
/// (`ProviderProfile.key_grant`).
fn providerDeclaresKeyGrant(allocator: std.mem.Allocator, name: []const u8) bool {
    const host = buildProviderHost(allocator) orelse return false;
    defer host.destroy();
    const profile = host.registry.find(name) orelse return false;
    return profile.key_grant != null;
}

const KeyGrantRequest = struct {
    open_browser: bool = true,
    /// `--device-code`: the page is opened on another device and shows a
    /// code to paste here.
    other_device: bool = false,
};

/// `metacodes login --provider <id>` for a provider whose site creates a key
/// of the user's own account (OpenRouter): the browser here, or another
/// device and a pasted code. The key ends in the provider's key file, as a
/// pasted one does.
fn runProviderKeyGrantLogin(allocator: std.mem.Allocator, io: std.Io, state_dir: []const u8, name: []const u8, request: KeyGrantRequest) u8 {
    const host = buildProviderHost(allocator) orelse {
        std.debug.print("error: the provider registry is unavailable\n", .{});
        return 1;
    };
    defer host.destroy();
    const profile = host.registry.find(name) orelse {
        std.debug.print("error: unknown provider '{s}'\n", .{name});
        return 2;
    };
    var prepared = provider_login.prepareKeyGrant(profile, .{
        .state_root = state_dir,
        .open_browser = request.open_browser,
    }) orelse {
        std.debug.print("error: {s} declares no sign-in that creates a key\n", .{profile.display_name});
        return 2;
    };
    var other_device = request.other_device;
    // Over SSH a loopback redirect lands on this machine, and the browser
    // that would follow it is on another one.
    if (!other_device and request.open_browser and auth.sshSession()) {
        std.debug.print("This looks like an SSH session: sign in on another device instead. (--no-browser keeps the browser sign-in.)\n", .{});
        other_device = true;
    }
    const previous = openrouter_login.storedKeyManageUrl(allocator, state_dir, profile.id, prepared.origin, prepared.grant);
    defer if (previous) |url| allocator.free(url);
    var retry_buf: [160]u8 = undefined;
    const retry = std.fmt.bufPrint(&retry_buf, "`{s} login --provider {s}`", .{ invokedCommand(allocator), profile.id.slice() }) catch "the login";

    var code_buf: [provider_login.MAX_KEY_LEN]u8 = undefined;
    defer std.crypto.secureZero(u8, &code_buf);
    var pending: ?openrouter_login.Pending = null;
    defer if (pending) |*value| value.deinit();
    if (other_device) {
        requireInteractiveLogin() catch {
            std.debug.print("error: no terminal to paste the code into; pass a key you created at {s}/keys with --api-key-stdin\n", .{prepared.origin});
            return 2;
        };
        pending = openrouter_login.Pending.begin(allocator, prepared.origin, prepared.grant) catch |err| {
            std.debug.print("error: the sign-in could not start ({s})\n", .{@errorName(err)});
            return 1;
        };
        std.debug.print("Open this URL on any device and approve the new API key:\n{s}\n\n", .{pending.?.url});
        var prompt_buf: [160]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf, "Paste the code {s} shows (it is not echoed) and press Enter: ", .{profile.display_name}) catch "Paste the code and press Enter: ";
        const code_len = readSecretLine(prompt, &code_buf) catch |err| {
            std.debug.print("\n", .{});
            if (err == error.Interrupted) {
                std.debug.print("Login interrupted; nothing was stored.\n", .{});
                return 130;
            }
            std.debug.print("error: the code could not be read ({s})\n", .{@errorName(err)});
            return 1;
        };
        std.debug.print("\n", .{});
        if (std.mem.trim(u8, code_buf[0..code_len], " \t\r\n").len == 0) {
            std.debug.print("No code was entered; nothing was stored.\n", .{});
            return 2;
        }
        prepared.pasted = .{ .code = code_buf[0..code_len], .verifier = pending.?.verifier() };
    }
    _ = prepared.run(allocator, io, oauth_login.stderrNotify(), null) catch |err| {
        if (err == error.Aborted) {
            std.debug.print("Login interrupted; nothing was stored.\n", .{});
            return 130;
        }
        var line_buf: [320]u8 = undefined;
        std.debug.print("{s}\n", .{openrouter_login.failureLine(&line_buf, err, profile.display_name, retry)});
        return 1;
    };

    var stored = provider_api_key_store.load(allocator, state_dir, profile.id) catch null;
    defer if (stored) |*value| value.deinit();
    const meta: provider_api_key_store.Meta = if (stored) |value| value.meta else .{};
    var line_buf: [512]u8 = undefined;
    var line: std.Io.Writer = .fixed(&line_buf);
    openrouter_login.writeSignedIn(&line, profile.display_name, meta) catch {};
    std.debug.print("{s}\n", .{line.buffered()});
    const current = if (stored) |value| openrouter_login.manageUrl(allocator, prepared.origin, prepared.grant, value.secret) catch null else null;
    defer if (current) |url| allocator.free(url);
    var notes_buf: [1024]u8 = undefined;
    var notes: std.Io.Writer = .fixed(&notes_buf);
    openrouter_login.writeAfterSignIn(&notes, profile.display_name, prepared.origin, meta, previous, current) catch {};
    std.debug.print("{s}", .{notes.buffered()});
    const key_path = provider_api_key_store.pathFor(allocator, state_dir, profile.id) catch null;
    defer if (key_path) |path| allocator.free(path);
    std.debug.print("The key is stored in {s}.\n", .{key_path orelse "the state root"});
    if (stored) |value| fetchOpenRouterListing(allocator, io, state_dir, value.secret);
    var local_config = loadLocalConfig(allocator, allocator, state_dir);
    defer local_config.deinit();
    if (provider_login.keyShadowedBy(profile, provider_credential.EnvLookup.process(), local_config.lookup())) |shadow| {
        var notice_buf: [std.fs.max_path_bytes + 256]u8 = undefined;
        var notice: std.Io.Writer = .fixed(&notice_buf);
        provider_login.writeKeyShadowNotice(&notice, shadow, local_config.path) catch {};
        std.debug.print("warning: {s}\n", .{notice.buffered()});
    }
    std.debug.print("No secret was printed.\n", .{});
    return 0;
}

const KeyLoginRequest = struct {
    /// `--api-key <key>`.
    key: ?[]const u8 = null,
    /// `--api-key-stdin`: the key is the first line of stdin.
    from_stdin: bool = false,
    /// `--key-page <id>`.
    page: ?[]const u8 = null,
    open_browser: bool = true,
    check: bool = true,
};

/// Whether `name` is a provider whose login is a pasted key: it declares a
/// key page and no OAuth grant this login could run, the rule `/login`
/// follows (`prepareFlow`). OpenAI declares a grant but no client to present
/// with it, so it takes a key unless a client is configured for it. Asking
/// for the grant (`--client-id`, `--device-code`) keeps it for a provider
/// that has one, which then says what it lacks.
fn providerTakesPastedKey(allocator: std.mem.Allocator, name: []const u8, client_id: ?[]const u8, method: oauth_login.Method) bool {
    const host = buildProviderHost(allocator) orelse return false;
    defer host.destroy();
    const profile = host.registry.find(name) orelse return false;
    if (profile.api_key_setup == null) return false;
    provider_login.requireOAuthCapable(profile) catch return true;
    if (client_id != null or method != .loopback) return false;
    _ = provider_login.prepareProfileWith(profile, .{ .state_root = "" }, host.oauthClientIdFor(profile.id)) catch return true;
    return false;
}

/// `metacodes login --provider <id>` for a provider that signs in with an API
/// key: the user picks the plan, the page the key is created on opens, the
/// pasted key is read without echo, checked, and stored in the provider's own
/// key file.
fn runProviderKeyLogin(allocator: std.mem.Allocator, io: std.Io, state_dir: []const u8, name: []const u8, request: KeyLoginRequest) u8 {
    const host = buildProviderHost(allocator) orelse {
        std.debug.print("error: the provider registry is unavailable\n", .{});
        return 1;
    };
    defer host.destroy();
    const profile = host.registry.find(name) orelse {
        std.debug.print("error: unknown provider '{s}'\n", .{name});
        return 2;
    };
    const setup = profile.api_key_setup orelse {
        std.debug.print("error: {s} declares no page to create an API key on; set its environment variable instead\n", .{profile.display_name});
        return 2;
    };
    if (request.key != null and request.from_stdin) {
        std.debug.print("error: pass the key with --api-key or --api-key-stdin, not both\n", .{});
        return 2;
    }
    const interactive = request.key == null and !request.from_stdin;

    var page = if (request.page) |id| profile.keyPage(id) orelse {
        std.debug.print("error: unknown key page '{s}'; {s} has:", .{ id, profile.display_name });
        for (setup.pages) |candidate| std.debug.print(" {s}", .{candidate.id.slice()});
        std.debug.print("\n", .{});
        return 2;
    } else profile.defaultKeyPage(profile.default_channel).?;

    var key_buffer: [provider_login.MAX_KEY_LEN]u8 = undefined;
    var key_len: usize = 0;
    // The whole buffer: a read that fails part way (too long, interrupted)
    // has written bytes past a `key_len` that is still 0.
    defer std.crypto.secureZero(u8, &key_buffer);

    if (interactive) {
        requireInteractiveLogin() catch {
            std.debug.print("error: no terminal to paste the key into; use --api-key-stdin\n", .{});
            return 2;
        };
        if (page.url != null) std.debug.print("Create an API key for {s}.\n", .{profile.display_name});
        if (setup.note) |note| std.debug.print("{s}\n", .{note});
        if (request.page == null and setup.pages.len > 1) {
            std.debug.print("\nWhich plan is the key for?\n", .{});
            var default_index: usize = 0;
            for (setup.pages, 0..) |candidate, i| {
                if (candidate.id.eql(page.id)) default_index = i;
                std.debug.print("  {d}. {s}\n", .{ i + 1, candidate.label });
            }
            std.debug.print("Choose [1-{d}] (Enter = {d}): ", .{ setup.pages.len, default_index + 1 });
            var line_buf: [32]u8 = undefined;
            const n = readLine(&line_buf) catch return 1;
            const answer = std.mem.trim(u8, line_buf[0..n], " \t\r\n");
            if (answer.len > 0) {
                const choice = std.fmt.parseInt(usize, answer, 10) catch 0;
                if (choice < 1 or choice > setup.pages.len) {
                    std.debug.print("error: no plan {s}\n", .{answer});
                    return 2;
                }
                page = setup.pages[choice - 1];
            }
        }
        var prompt_buf: [256]u8 = undefined;
        const prompt = if (page.url) |url| prompt: {
            std.debug.print("\nOpen this page and create a key:\n{s}\n\n", .{url});
            if (request.open_browser) auth.openBrowser(allocator, url) catch {};
            break :prompt "Paste the key (it is not shown) and press Enter: ";
        } else
            // A provider the user configured: the key comes from whoever
            // runs it, and there is no page to open.
            std.fmt.bufPrint(&prompt_buf, "Paste the API key for {s} (it is not shown) and press Enter: ", .{profile.display_name}) catch "Paste the key (it is not shown) and press Enter: ";
        key_len = readSecretLine(prompt, &key_buffer) catch |err| {
            std.debug.print("\n", .{});
            if (err == error.Interrupted) {
                std.debug.print("Login interrupted; nothing was stored.\n", .{});
                return 130;
            }
            std.debug.print("error: the key could not be read ({s})\n", .{@errorName(err)});
            return 1;
        };
        std.debug.print("\n", .{});
    } else if (request.from_stdin) {
        key_len = readLine(&key_buffer) catch {
            std.debug.print("error: the key could not be read from stdin\n", .{});
            return 1;
        };
    } else {
        const given = request.key.?;
        if (given.len > key_buffer.len) {
            std.debug.print("error: that key is longer than any key this login accepts\n", .{});
            return 2;
        }
        @memcpy(key_buffer[0..given.len], given);
        key_len = given.len;
    }

    var prepared = provider_login.prepareApiKey(profile, page.id.slice(), null, key_buffer[0..key_len], .{
        .state_root = state_dir,
        .open_browser = false,
    }) catch |err| {
        std.debug.print("error: {s}\n", .{switch (err) {
            error.EmptyKey => "no key was entered; nothing was stored",
            error.UnknownKeyPage => "unknown key page",
            error.NoKeySetup => "this provider declares no key page",
        }});
        return 2;
    };
    prepared.check = request.check;
    _ = prepared.run(allocator, io, oauth_login.stderrNotify(), null) catch |err| {
        switch (err) {
            error.KeyRefused => std.debug.print(
                "{s} refused this key; nothing was stored. Check that it was copied whole and that it is a key for {s}.\n",
                .{ profile.display_name, page.label },
            ),
            error.KeyCheckFailed => std.debug.print(
                "The key could not be checked (network or provider error); nothing was stored. Retry, or store it unchecked with --no-check.\n",
                .{},
            ),
            else => std.debug.print("error: the key was not stored: {s}\n", .{@errorName(err)}),
        }
        return 1;
    };
    // What a provider whose site creates keys (OpenRouter) said about it.
    if (profile.key_grant != null) {
        var stored = provider_api_key_store.load(allocator, state_dir, profile.id) catch null;
        defer if (stored) |*value| value.deinit();
        if (stored) |value| {
            if (value.meta.described) {
                var line_buf: [512]u8 = undefined;
                var line: std.Io.Writer = .fixed(&line_buf);
                openrouter_login.writeStored(&line, profile.display_name, value.meta) catch {};
                std.debug.print("{s}\n", .{line.buffered()});
                var notes_buf: [512]u8 = undefined;
                var notes: std.Io.Writer = .fixed(&notes_buf);
                openrouter_login.writeAfterSignIn(&notes, profile.display_name, openrouter_login.origin(profile.key_grant.?), value.meta, null, null) catch {};
                std.debug.print("{s}", .{notes.buffered()});
            }
            if (request.check) fetchOpenRouterListing(allocator, io, state_dir, value.secret);
        }
    }
    // A key variable for this provider in the shell or in `.env` is read
    // before the stored key (`credential.resolve`): say so, by name, rather
    // than promise that new sessions use the key just stored.
    var local_config = loadLocalConfig(allocator, allocator, state_dir);
    defer local_config.deinit();
    if (provider_login.keyShadowedBy(profile, provider_credential.EnvLookup.process(), local_config.lookup())) |shadow| {
        var notice_buf: [std.fs.max_path_bytes + 256]u8 = undefined;
        var notice: std.Io.Writer = .fixed(&notice_buf);
        provider_login.writeKeyShadowNotice(&notice, shadow, local_config.path) catch {};
        std.debug.print("warning: {s}\n", .{notice.buffered()});
        std.debug.print("No key was printed.\n", .{});
        return 0;
    }
    std.debug.print("New sessions on {s} use it (`metacodes --provider {s}`, or pick a {s} model in /model). No key was printed.\n", .{ profile.display_name, profile.id.slice(), profile.display_name });
    return 0;
}

/// Shared with `metacodes providers add` (`app/terminal_prompt.zig`).
const readSecretLine = terminal_prompt.readSecretLine;
const readLine = terminal_prompt.readLine;

/// `metacodes logout` (#499 part 2): remove both Metask sign-ins — the
/// browser one in auth.json and the device-code one in oauth/metask.json,
/// refresh token and all — and a stored default that is Metask's, and say
/// which were there. A key in `.env` or the shell is not a sign-in: it is
/// named, never removed.
fn logoutMetask(allocator: std.mem.Allocator, state_dir: []const u8) u8 {
    if (state_dir.len == 0 and std.c.getenv(auth.AUTH_FILE_ENV) == null and std.c.getenv("METACODES_OAUTH_DIR") == null) {
        std.debug.print("No state root (set HOME or --state-dir); no credentials cleared.\n", .{});
        return 1;
    }
    // At the server first (#527): the refresh token is read from the file
    // removed below.
    const revoke = metask_oauth_mod.revokeStoredSession(state_dir, metask_oauth_mod.siteUrl(), 5000);
    const removed = sign_out_mod.removeMetaskSignIns(allocator, state_dir) catch |err| {
        std.debug.print("Logout failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    // A Metask key stored with `login --provider metask --api-key` is a
    // Metask credential too.
    const key_removed = provider_api_key_store.remove(allocator, state_dir, provider_ids_mod.Slug.lit("metask")) catch |err| {
        std.debug.print("Logout failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    var default_cleared = false;
    if (buildProviderHost(allocator)) |host| {
        defer host.destroy();
        default_cleared = (sign_out_mod.clearMetaskDefault(allocator, state_dir, host.kernel.catalogSnapshot()) catch |err| blk: {
            std.debug.print("warning: the stored default could not be checked ({s})\n", .{@errorName(err)});
            break :blk null;
        }) != null;
    }
    if (removed.device) std.debug.print("Removed the Metask sign-in and its refresh token ({s}).\n", .{metaskSessionPathForDisplay(allocator, state_dir)});
    switch (revoke) {
        .revoked => std.debug.print("Metask revoked it too.\n", .{}),
        .nothing_stored => {},
        .failed => std.debug.print("warning: Metask could not revoke it; it stays valid there until it expires.\n", .{}),
        .timed_out => std.debug.print("warning: Metask did not answer the revocation in time; it may stay valid there until it expires.\n", .{}),
    }
    if (removed.browser) std.debug.print("Removed {s} (an older browser sign-in, a key, or the model choice).\n", .{authPathForDisplay(allocator, state_dir)});
    if (key_removed) std.debug.print("Removed the stored key for Metask.\n", .{});
    if (!removed.any() and !key_removed) std.debug.print("No Metask sign-in was stored.\n", .{});
    if (default_cleared) std.debug.print("Forgot the default model, which was a Metask one.\n", .{});
    printRemainingMetaskKeys(allocator, state_dir);
    std.debug.print("Logged out. No secret was printed.\n", .{});
    return 0;
}

/// `<state root>/auth.json` as the removal names it ("auth.json" when it
/// cannot be built).
fn authPathForDisplay(allocator: std.mem.Allocator, state_dir: []const u8) []const u8 {
    return auth.authFilePath(allocator, state_dir) catch "auth.json";
}

fn metaskSessionPathForDisplay(allocator: std.mem.Allocator, state_dir: []const u8) []const u8 {
    var session = provider_oauth_mod.Session.initHome(allocator, state_dir, provider_ids_mod.Slug.lit("metask")) catch return "oauth/metask.json";
    defer session.deinit();
    return allocator.dupe(u8, session.path) catch "oauth/metask.json";
}

/// A `METASK_API_KEY` that signs a plain start in again, though nothing was
/// stored: in the shell, or in this install's `.env` (names only).
fn printRemainingMetaskKeys(allocator: std.mem.Allocator, state_dir: []const u8) void {
    if (nonEmptyEnv(auth.METASK_API_KEY_ENV) != null) {
        std.debug.print("METASK_API_KEY is still set in your shell; a start signs in with it until you unset it.\n", .{});
    }
    var local = state_env_mod.load(allocator, state_dir, .{
        .keys = &.{.{ .name = auth.METASK_API_KEY_ENV, .provider = "metask" }},
    }) catch return;
    defer local.deinit();
    if (local.get(auth.METASK_API_KEY_ENV) != null) {
        std.debug.print("METASK_API_KEY is still set in {s}; remove it there to stay signed out.\n", .{local.path});
    }
}

/// `metacodes logout --provider <id>`: forget the API key stored for it, and
/// its own OAuth sign-in, revoked at the provider first where the profile
/// says (`api/oauth_revoke.zig`).
fn logoutProviderKey(allocator: std.mem.Allocator, state_dir: []const u8, name: []const u8) u8 {
    const host = buildProviderHost(allocator) orelse {
        std.debug.print("error: the provider registry is unavailable\n", .{});
        return 1;
    };
    defer host.destroy();
    const profile = host.registry.find(name) orelse return @import("app/providers_cli.zig").logoutLeftover(allocator, state_dir, name);
    return logoutProviderProfile(allocator, state_dir, profile, @import("metacodes-internal").api.oauth_revoke.DEFAULT_WAIT_MS);
}

/// `logoutProviderKey` for a resolved profile; `revoke_wait_ms` bounds the
/// revocation (a test points the profile's endpoint at its own mock).
pub fn logoutProviderProfile(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    profile: *const provider_profile.ProviderProfile,
    revoke_wait_ms: u64,
) u8 {
    const oauth_revoke = @import("metacodes-internal").api.oauth_revoke;
    // A key a provider's site created (OpenRouter) outlives this file: only
    // its owner can delete it there, so its page is named before the file,
    // which holds the key it is computed from, goes.
    const manage = if (profile.key_grant) |grant|
        openrouter_login.storedKeyManageUrl(allocator, state_dir, profile.id, openrouter_login.origin(grant), grant)
    else
        null;
    defer if (manage) |url| allocator.free(url);
    const removed = provider_api_key_store.remove(allocator, state_dir, profile.id) catch |err| {
        std.debug.print("Logout failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    const sign_in = oauth_revoke.forgetStoredLogin(allocator, state_dir, profile, revoke_wait_ms) catch |err| {
        std.debug.print("Logout failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    if (sign_in.removed) {
        std.debug.print("Signed out of {s}: removed the sign-in and its refresh token.\n", .{profile.display_name});
        switch (sign_in.revoke) {
            .revoked => std.debug.print("{s} revoked it too.\n", .{profile.display_name}),
            .nothing_stored, .not_offered => {},
            .failed => std.debug.print("{s} could not revoke it; it stays valid there until it expires.\n", .{profile.display_name}),
            .timed_out => std.debug.print("{s} did not answer the revocation in time; it may stay valid there until it expires.\n", .{profile.display_name}),
        }
    }
    if (removed and profile.key_grant != null) {
        std.debug.print("Removed the {s} key stored on this machine.\n", .{profile.display_name});
        if (manage) |url| std.debug.print("It still works on {s} until you delete it there: {s}\n", .{ profile.display_name, url });
    } else if (removed) {
        std.debug.print("Removed the stored key for {s}.\n", .{profile.display_name});
    } else if (!sign_in.removed) {
        std.debug.print("{s} is stored for {s}.\n", .{ provider_login.nothingStoredText(profile), profile.display_name });
    }
    return 0;
}

fn requireInteractiveLogin() !void {
    if (!platform_term.isatty(0) or !platform_term.isatty(2)) return error.InteractiveTerminalRequired;
}

fn promptChoice(allocator: std.mem.Allocator, count: usize) !usize {
    _ = allocator;
    while (true) {
        std.debug.print("Choose [1-{d}]: ", .{count});
        var buf: [64]u8 = undefined;
        const n = readLine(&buf) catch return error.InputFailed;
        const s = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (s.len == 0) return 0;
        const v = std.fmt.parseInt(usize, s, 10) catch {
            std.debug.print("Invalid choice.\n", .{});
            continue;
        };
        if (v >= 1 and v <= count) return v - 1;
        std.debug.print("Choice out of range.\n", .{});
    }
}

/// `metacodes login status`: which credential a plain start here uses and
/// why, the startup order's decision (apps/cli/src/app/startup_order.zig, the one
/// `main` applies), then what each of its seven levels holds. Names, paths
/// and an expiry only: never a key or a token.
fn printLoginStatus(allocator: std.mem.Allocator, state_dir: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var local_config = loadLocalConfig(allocator, arena, state_dir);
    defer local_config.deinit();
    // A start with no flag: level 1 is the environment's alone.
    var config: types.Config = .{};
    config.state_root = state_dir;
    config.credential_env_fallback = local_config.lookup();
    applyAuthPrecedenceEnv(&config);
    if (std.c.getenv("METACODES_PROVIDER")) |raw| config.provider_profile = std.mem.span(raw);
    const preset_facts = presetFacts(arena, config, &local_config, true);
    const local_metask_key = localSignInKey(arena, &local_config, &preset_facts);
    const facts = startupFacts(arena, config, &local_config, local_metask_key, &preset_facts);
    const decision = startup_order.decide(facts);

    // Level 5's two stores: the session (#527) and auth.json.
    const session_text: ?[]const u8 = session: {
        var session = provider_oauth_mod.Session.initHome(arena, state_dir, provider_ids_mod.Slug.lit("metask")) catch break :session null;
        defer session.deinit();
        if (!(session.load() catch false)) break :session null;
        const tokens = session.tokens orelse break :session null;
        break :session std.fmt.allocPrint(arena, "the session ({s}; gateway {s}; access token expires_at={d})", .{
            metaskSessionPathForDisplay(arena, state_dir), tokens.gateway_url orelse "not named", tokens.expires_at,
        }) catch null;
    };
    const auth_path = auth.authFilePath(arena, state_dir) catch "auth.json";
    var stored: ?auth.StoredCredentials = null;
    var auth_error: ?[]const u8 = null;
    if (auth.loadFromPath(arena, auth_path)) |value| stored = value else |err| {
        if (err != error.NotFound) auth_error = @errorName(err);
    }
    const chosen_model: ?[]const u8 = if (stored) |value| value.selected_model else null;
    const chosen_effort: ?[]const u8 = if (stored) |value| (if (value.reasoning_effort) |effort| effort.name() else null) else null;
    const metask_model = if (chosen_model) |model|
        (if (chosen_effort) |effort| std.fmt.allocPrint(arena, " · {s} · reasoning {s}", .{ model, effort }) catch "" else std.fmt.allocPrint(arena, " · {s}", .{model}) catch "")
    else
        "";
    const env_model = nonEmptyEnv(state_env_mod.model_variable);

    // The headline: who, then the level that decided.
    const env_path = if (local_config.path.len > 0) local_config.path else ".env";
    switch (decision) {
        .named => std.debug.print("This start uses the provider the shell names: METACODES_PROVIDER={s}{s}{s}.\n", .{
            config.provider_profile orelse "",
            if (env_model != null) " · " else "",
            env_model orelse "",
        }),
        .preset => if (preset_facts.decided(decision)) |found|
            std.debug.print("This start uses the preset {s} ({s} in the shell){s}.\n", .{ found.name, presets_mod.variable, presetRoute(arena, found) }),
        .directory_preset => if (preset_facts.decided(decision)) |found|
            std.debug.print("This start uses the preset {s}, remembered for {s}{s}.\n", .{ found.name, preset_facts.directory, presetRoute(arena, found) }),
        .local_preset => if (preset_facts.decided(decision)) |found|
            std.debug.print("This start uses the preset {s} from {s}{s}.\n", .{ found.name, env_path, presetRoute(arena, found) }),
        .stored_default => switch (facts.stored_default) {
            .usable => |usable| if (usable.label) |name|
                std.debug.print("This start uses the default stored with /model: {s}.\n", .{name})
            else
                std.debug.print("This start uses the default stored with /model.\n", .{}),
            else => {},
        },
        .metask_key => std.debug.print("This start uses Metask with {s}{s}.\n", .{ metaskKeySource(config.auth_precedence, local_metask_key, stored, auth_error), metask_model }),
        .metask_session => std.debug.print("This start uses Metask, signed in{s}.\n", .{metask_model}),
        .local_provider => switch (facts.local) {
            .provider => |chosen| std.debug.print("This start uses {s} from {s}{s}{s}.\n", .{
                providerDisplayName(arena, chosen.name),
                env_path,
                if (local_config.get(state_env_mod.model_variable) != null or env_model != null) " · " else "",
                env_model orelse local_config.get(state_env_mod.model_variable) orelse "",
            }),
            else => {},
        },
        .local_unchosen => switch (facts.local) {
            // The terminal UI opens without a model and says to choose in
            // /model (`route_state.writeUnchosenLocalNotice`); -p stops.
            .several => |ids| std.debug.print("This start uses no provider: {s} holds keys of several ({s}) and names none. Choose one with /model; Tab there applies it to every future session. Or add {s}=<one of them> to it.\n", .{
                env_path, std.mem.join(arena, ", ", ids) catch "", state_env_mod.provider_variable,
            }),
            else => {},
        },
        .nothing => std.debug.print("This start uses no provider: nothing is set up. Sign in with `{s} login`, or put a provider's key in {s}.\n", .{ invokedCommand(arena), env_path }),
        .directory_unchosen => std.debug.print("This start uses no provider: {s} remembers no preset, and global_default is false.\n", .{
            if (preset_facts.directory.len > 0) preset_facts.directory else "the working directory",
        }),
    }
    const no_global_default = !facts.global_default;
    if (no_global_default) std.debug.print("global_default is false in {s}: levels 4 to 6 choose for no directory.\n", .{
        if (preset_facts.config_path.len > 0) preset_facts.config_path else "config.json",
    });
    std.debug.print("Level {d} of {d} decided; the first that applies wins:\n", .{ decision.level(), startup_order.levels });

    const mark = struct {
        fn at(level: u8, decided: startup_order.Decision) []const u8 {
            return if (decided.level() == level) "> " else "  ";
        }
    };
    // 1. Flags and the shell. `login status` takes no flag: the shell's.
    if (facts.named) {
        std.debug.print("{s}1 named at start: METACODES_PROVIDER={s} in the shell\n", .{ mark.at(1, decision), config.provider_profile orelse "" });
    } else {
        std.debug.print("{s}1 named at start: nothing (METACODES_PROVIDER is not set)\n", .{mark.at(1, decision)});
    }
    // 2. A preset named at start: the shell's.
    std.debug.print("{s}2 preset named at start: ", .{mark.at(2, decision)});
    switch (facts.preset) {
        .none => std.debug.print("nothing ({s} is not set)\n", .{presets_mod.variable}),
        .found => |found| std.debug.print("{s}={s} in the shell{s}{s}\n", .{ presets_mod.variable, found.name, presetRoute(arena, found), if (facts.named) " (not consulted, level 1 names a provider)" else "" }),
        .unknown => |name| std.debug.print("{s}={s} in the shell, {s}\n", .{ presets_mod.variable, name, presetMissing(arena, &preset_facts) }),
    }
    // 3. The preset this directory remembers.
    std.debug.print("{s}3 this directory ({s}): ", .{ mark.at(3, decision), if (preset_facts.directory.len > 0) preset_facts.directory else "the working directory cannot be read" });
    switch (facts.directory_preset) {
        .none => std.debug.print("remembers no preset\n", .{}),
        .found => |found| std.debug.print("remembers {s}{s}{s}\n", .{ found.name, presetRoute(arena, found), if (decision.level() < 3) " (not consulted, a level above decides)" else "" }),
        .unknown => |name| std.debug.print("remembers {s}, {s}\n", .{ name, presetMissing(arena, &preset_facts) }),
    }
    // 4. The default stored with /model.
    switch (facts.stored_default) {
        .none => std.debug.print("{s}4 stored default: {s}\n", .{ mark.at(4, decision), if (no_global_default) "not consulted, global_default is false" else if (facts.named) "not consulted, level 1 names a provider" else if (facts.decidedAboveDefault()) "not consulted, a preset above decides" else "none" }),
        .unreadable => std.debug.print("{s}4 stored default: config.json cannot be read\n", .{mark.at(4, decision)}),
        .usable => |usable| std.debug.print("{s}4 stored default: {s}\n", .{ mark.at(4, decision), usable.label orelse "set" }),
        .lacks_credential => |label| std.debug.print("{s}4 stored default: {s}, which has no key or sign-in: passed over\n", .{ mark.at(4, decision), label }),
    }
    // 5. A Metask sign-in: the historical path's key, else the session.
    std.debug.print("{s}5 Metask sign-in: {s}\n", .{ mark.at(5, decision), session_text orelse "no session" });
    if (auth_error) |why| {
        std.debug.print("      {s}: cannot be read ({s})\n", .{ auth_path, why });
    } else if (stored) |value| {
        std.debug.print("      {s}: model {s}, reasoning {s}{s}{s}\n", .{
            auth_path,
            value.selected_model orelse "not chosen",
            chosen_effort orelse "not chosen",
            if (value.api_key != null) "; a key" else "",
            if (value.oauth != null) "; an older browser sign-in" else "",
        });
    } else {
        std.debug.print("      {s}: not stored\n", .{auth_path});
    }
    if (config.auth_precedence == .oauth_first) {
        std.debug.print("      METACODES_AUTH_PRECEDENCE=oauth-first: a sign-in comes before a key\n", .{});
    }
    if (nonEmptyEnv(auth.METASK_API_KEY_ENV) != null) {
        std.debug.print("      METASK_API_KEY: set in the shell\n", .{});
    } else if (local_metask_key != null) {
        std.debug.print("      METASK_API_KEY: set in {s}\n", .{env_path});
    } else if (local_config.get(auth.METASK_API_KEY_ENV) != null) {
        const waits_for: []const u8 = switch (preset_facts.local_preset) {
            .found => |found| std.fmt.allocPrint(arena, "the file's preset {s} is not on Metask", .{found.name}) catch "the file chooses another provider",
            .unknown => |name| if (local_config.get(state_env_mod.provider_variable) != null)
                "the file names another provider"
            else
                std.fmt.allocPrint(arena, "the file names the preset {s}", .{name}) catch "the file names a preset",
            .none => "the file names another provider",
        };
        std.debug.print("      METASK_API_KEY: set in {s}, for when Metask is chosen ({s})\n", .{ env_path, waits_for });
    } else {
        std.debug.print("      METASK_API_KEY: not set\n", .{});
    }
    if (no_global_default and decision.level() != 5) std.debug.print("      not consulted: global_default is false\n", .{});
    // 6. The install's .env: names only. Its preset comes before its provider.
    const diagnosis = localConfigDiagnosis(arena, &local_config) catch return;
    std.debug.print("{s}6 {s}: {s}", .{ mark.at(6, decision), env_path, localStateWords(diagnosis.state) });
    if (diagnosis.accepted.len > 0) std.debug.print("; {s}", .{std.mem.join(arena, ", ", diagnosis.accepted) catch ""});
    if (diagnosis.ignored.len > 0) std.debug.print("; ignored: {s}", .{std.mem.join(arena, ", ", diagnosis.ignored) catch ""});
    switch (facts.local_preset) {
        .none => {},
        .found => |found| {
            std.debug.print("; selects the preset {s}{s}\n", .{ found.name, presetRoute(arena, found) });
        },
        .unknown => |name| std.debug.print("; {s}={s}, {s}", .{ presets_mod.variable, name, presetMissing(arena, &preset_facts) }),
    }
    if (facts.local_preset != .found) switch (facts.local) {
        .none => std.debug.print("; configures no provider\n", .{}),
        .provider => |chosen| std.debug.print("; configures {s}{s}\n", .{ providerDisplayName(arena, chosen.name), if (chosen.named) "" else " (the one provider whose key it holds)" }),
        .several => |ids| std.debug.print("; keys of several providers ({s}) and no {s}\n", .{ std.mem.join(arena, ", ", ids) catch "", state_env_mod.provider_variable }),
    };
    if (no_global_default) std.debug.print("      not consulted: global_default is false\n", .{});
    // 7. Nothing.
    std.debug.print("{s}7 nothing: the TUI opens without a model; -p and the rest stop\n", .{mark.at(7, decision)});

    // Keys only in the shell are not metacodes' to pick up (第四节).
    const chosen_provider: ?[]const u8 = switch (decision) {
        .named => config.provider_profile,
        .preset, .directory_preset, .local_preset => if (preset_facts.decided(decision)) |found| found.provider else null,
        .stored_default => switch (facts.stored_default) {
            .usable => |usable| usable.provider,
            else => null,
        },
        .local_provider => switch (facts.local) {
            .provider => |chosen| chosen.name,
            else => null,
        },
        else => null,
    };
    if (chosen_provider) |name| printKeyGrantKeyStatus(arena, state_dir, name, &local_config);
    const shell_keys = shellOnlyKeys(arena, chosen_provider);
    if (shell_keys.len > 0) std.debug.print("Keys in the shell choose no provider: {s}. To use one: --provider <id>, or put it in {s}.\n", .{ shell_keys, env_path });
    std.debug.print("No secret was printed.\n", .{});
}

/// `: House relay · relay-model`, a found preset's route for `login status`;
/// what a start does instead when it does not resolve.
fn presetRoute(arena: std.mem.Allocator, found: startup_order.Preset.Found) []const u8 {
    const label = found.label orelse return ", whose route does not resolve: a start stops and says why";
    return std.fmt.allocPrint(arena, ": {s}", .{label}) catch "";
}

/// What `login status` says of a preset config.json does not define: why,
/// and that the start passes it over (stopping, outside the TUI).
fn presetMissing(arena: std.mem.Allocator, facts: *const presets_mod.Facts) []const u8 {
    const path = if (facts.config_path.len > 0) facts.config_path else "config.json";
    const why = if (facts.unreadable) |err|
        std.fmt.allocPrint(arena, "which cannot be looked up: {s} cannot be read ({s})", .{ path, err }) catch ""
    else if (facts.defined.len == 0)
        std.fmt.allocPrint(arena, "which {s} does not define (it defines no presets)", .{path}) catch ""
    else
        std.fmt.allocPrint(arena, "which {s} does not define (presets: {s})", .{ path, std.mem.join(arena, ", ", facts.defined) catch "" }) catch "";
    return std.fmt.allocPrint(arena, "{s}: passed over by the TUI, -p and the rest stop", .{why}) catch why;
}

/// `login status` for a provider whose site created its key (OpenRouter),
/// when it is the one this start uses: the stored key's file, how and when it
/// came, what the provider said about it then, where to manage it, and a
/// variable that is read before it. Names, paths and dates only.
fn printKeyGrantKeyStatus(arena: std.mem.Allocator, state_dir: []const u8, name: []const u8, local_config: anytype) void {
    const host = buildProviderHost(arena) orelse return;
    defer host.destroy();
    const profile = host.registry.find(name) orelse return;
    const grant = profile.key_grant orelse return;
    var stored = (provider_api_key_store.load(arena, state_dir, profile.id) catch |err| {
        std.debug.print("{s}: its stored key cannot be read ({s})\n", .{ profile.display_name, @errorName(err) });
        return;
    }) orelse {
        std.debug.print("{s}: no key is stored (`{s} login --provider {s}`)\n", .{ profile.display_name, invokedCommand(arena), profile.id.slice() });
        return;
    };
    defer stored.deinit();
    const path = provider_api_key_store.pathFor(arena, state_dir, profile.id) catch "";
    var line_buf: [std.fs.max_path_bytes + 256]u8 = undefined;
    var line: std.Io.Writer = .fixed(&line_buf);
    openrouter_login.writeKeyStatus(&line, path, &stored) catch {};
    std.debug.print("{s}: {s}\n", .{ profile.display_name, line.buffered() });
    if (openrouter_login.manageUrl(arena, openrouter_login.origin(grant), grant, stored.secret)) |url| {
        std.debug.print("      manage it on {s}: {s}\n", .{ profile.display_name, url });
    } else |_| {}
    if (provider_login.keyShadowedBy(profile, provider_credential.EnvLookup.process(), local_config.lookup())) |shadow| {
        if (shadow.in_local_config) {
            std.debug.print("      {s} in {s} is used before it\n", .{ shadow.name, local_config.path });
        } else {
            std.debug.print("      {s} in the shell is used before it\n", .{shadow.name});
        }
    }
}

/// What signs Metask in on the historical path, in the order it reads them
/// under `precedence` (`auth.resolveCredentialWithEnvFallback`), for the
/// headline.
fn metaskKeySource(precedence: auth.AuthPrecedence, local_metask_key: ?[]const u8, stored: ?auth.StoredCredentials, auth_error: ?[]const u8) []const u8 {
    if (std.c.getenv(auth.RUNTIME_API_KEY_FD_ENV) != null) return "the key passed on a file descriptor";
    if (auth_error != null) return "auth.json, which cannot be read";
    const stored_key = if (stored) |value| value.api_key != null else false;
    const stored_sign_in = if (stored) |value| value.oauth != null else false;
    if (precedence == .oauth_first and stored_sign_in) return "the older browser sign-in in auth.json";
    if (nonEmptyEnv(auth.METASK_API_KEY_ENV) != null) return "METASK_API_KEY from the shell";
    if (local_metask_key != null) return "METASK_API_KEY from .env";
    if (stored_key) return "the key in auth.json";
    if (stored_sign_in) return "the older browser sign-in in auth.json";
    return "a Metask key";
}

/// `<state root>/.env`'s state (`state_env.Status`) in words.
fn localStateWords(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "read")) return "read";
    if (std.mem.eql(u8, state, "absent")) return "no such file";
    if (std.mem.eql(u8, state, "unreadable")) return "cannot be read";
    if (std.mem.eql(u8, state, "not_a_file")) return "not a file, never read";
    if (std.mem.eql(u8, state, "too_large")) return "too large, never read";
    return "no state root";
}

/// The providers' key variables set in the shell, other than Metask's and
/// `chosen`'s: `OPENAI_API_KEY (OpenAI), …`, or "". Names only.
fn shellOnlyKeys(arena: std.mem.Allocator, chosen: ?[]const u8) []const u8 {
    const host = buildProviderHost(arena) orelse return "";
    defer host.destroy();
    const chosen_profile = if (chosen) |name| host.registry.find(name) else null;
    var out: std.ArrayList(u8) = .empty;
    for (host.registry.profiles.items) |profile| {
        if (profile.id.eqlText("metask")) continue;
        if (chosen_profile) |picked| if (picked.id.eql(profile.id)) continue;
        for (profile.env_aliases) |alias| {
            if (!std.mem.endsWith(u8, @tagName(alias.kind), "api_key")) continue;
            var name_buf: [256]u8 = undefined;
            const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{alias.name}) catch continue;
            if (nonEmptyEnv(name_z) == null) continue;
            out.print(arena, "{s}{s} ({s})", .{ if (out.items.len > 0) ", " else "", alias.name, profile.display_name }) catch return "";
        }
    }
    return out.items;
}

fn readFileArg(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, buf[0..buf.len]);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return try out.toOwnedSlice(allocator);
}

fn applyStoredLoginSelection(allocator: std.mem.Allocator, config: *types.Config) !void {
    var stored = auth.loadDefault(allocator, config.state_root) catch |err| switch (err) {
        error.NotFound, error.NoHome => return,
        else => return err,
    };
    defer stored.deinit(allocator);
    if (!config.model_explicit) {
        if (stored.selected_model) |m| {
            config.model = try allocator.dupe(u8, m);
            config.model_explicit = true;
        }
    }
    if (config.reasoning_effort == null) {
        config.reasoning_effort = stored.reasoning_effort;
    }
}

/// True when the selected provider profile is Metask (or none was named).
/// Every other named profile is resolved in its own scope, so a Metask token
/// can never authenticate it.
pub fn selectedProfileIsMetask(config: types.Config) bool {
    // Naming no provider keeps the historical path.
    if (config.provider_profile == null) return true;
    // A named provider always has a resolved id by this point: route
    // resolution runs first and exits on failure. Deliberately not a second
    // registry lookup — a lookup that failed here would silently re-enter the
    // Metask credential path for a non-Metask provider, which is precisely the
    // cross-provider leak this scoping exists to prevent.
    const resolved = config.resolved_provider_id orelse return false;
    return std.mem.eql(u8, resolved, "metask");
}

const MetaskSessionError = provider_oauth_mod.OAuthError || error{NoSession};

fn resolveMetaskBearer(session: *provider_oauth_mod.Session, io: std.Io) MetaskSessionError![]u8 {
    if (session.tokens == null) return error.NoSession;
    return oauth_exchange_mod.metaskAccessToken(session, io, @import("metacodes-internal").util.time.nowUnix());
}

/// Provider-scoped credential resolution (issue #16).
///
/// Only material the profile declares is eligible: its environment aliases and
/// an explicit `--api-key`. The Metask credential store is deliberately not
/// consulted, which is the whole point — an unrelated vendor key must never be
/// selected merely because it exists.
/// `metacodes login --provider <id> --oauth-token-json <file>`.
///
/// Imports a standard RFC 6749 token response into that provider's own OAuth
/// session. The refresh lifecycle then runs itself: the session refreshes
/// before expiry, performs one exchange no matter how many turns notice at
/// once, and persists a rotated refresh token atomically.
fn storeProviderOAuthToken(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    path: []const u8,
    explicit_client_id: ?[]const u8,
) u8 {
    // The same runtime a session builds, so a provider defined in the config —
    // or one that came from a catalog — can be logged into by name.
    const host = buildProviderHost(allocator) orelse return 2;
    defer host.destroy();

    const built = host.registry.find(provider_name) orelse {
        std.debug.print("error: unknown provider '{s}'\n", .{provider_name});
        return 2;
    };

    const text = readFileArg(allocator, path) catch |err| {
        std.debug.print("error: could not read {s}: {s}\n", .{ path, @errorName(err) });
        return 2;
    };
    defer {
        std.crypto.secureZero(u8, text);
        allocator.free(text);
    }

    return loginProviderWithTokenResponse(allocator, built, text, explicit_client_id, host.oauthClientIdFor(built.id));
}

/// Refuse, with the reason, a provider whose stored login could never be used.
/// Both login paths ask this before doing anything the user would have to
/// undo — the token-JSON import before it writes, the interactive flow before
/// it sends anyone to a browser. The decision is `provider_login`'s; this
/// only prints it.
fn requireOAuthCapableProvider(built: *const provider_profile.ProviderProfile) bool {
    provider_login.requireOAuthCapable(built) catch |err| {
        switch (err) {
            error.ProviderHasNoTokenEndpoint => std.debug.print(
                "error: provider '{s}' declares no OAuth token endpoint\n",
                .{built.id.slice()},
            ),
            error.ProviderAcceptsNoOAuthKind => std.debug.print(
                "error: provider '{s}' accepts no OAuth credential kind; " ++
                    "a stored login would never be consulted. Declare one under " ++
                    "credential_kinds (e.g. \"openai_oauth\") for a configured provider.\n",
                .{built.id.slice()},
            ),
        }
        return false;
    };
    return true;
}

/// Finish a provider login from a token response, the way both entry points
/// do. Public so the wiring — not just the parts — is testable against a
/// profile, without a provider host or a home directory.
///
/// `explicit_client_id` is what the user passed on the command line and
/// `configured_client_id` what the installation declared under
/// `providers.<id>.oauth_client_id` (#87); the precedence is the one
/// `provider_login.prepareProfileWith` applies to the interactive grant —
/// explicit, then configured, then the profile's declaration — so an imported
/// login records the same client an interactive one would, and the refresh
/// grant presents the right one. Ignoring a client here while accepting it
/// elsewhere is exactly the defect this function replaced.
pub fn loginProviderWithTokenResponse(
    allocator: std.mem.Allocator,
    built: *const provider_profile.ProviderProfile,
    token_json: []const u8,
    explicit_client_id: ?[]const u8,
    configured_client_id: ?[]const u8,
) u8 {
    if (!requireOAuthCapableProvider(built)) return 2;
    return importProviderTokenResponse(
        allocator,
        built.id,
        token_json,
        explicit_client_id orelse configured_client_id orelse built.oauth_client_id,
    );
}

pub const ProviderLoginOptions = struct {
    method: oauth_login.Method = .loopback,
    open_browser: bool = true,
    /// Overrides the profile's declared client, and supplies one when the
    /// profile declares none.
    client_id: ?[]const u8 = null,
};

fn metaskDeviceNotify(uri: []const u8, code: []const u8) void {
    // Stable, greppable lines are part of the CLI contract; keep them on
    // stderr alongside the human-readable instructions.
    std.debug.print("METASK_VERIFICATION_URI={s}\n", .{uri});
    std.debug.print("METASK_USER_CODE={s}\n", .{code});
    std.debug.print("Open {s} and enter the code {s}\n", .{ uri, code });
}

/// `metacodes login --provider metask`: the device code (#499, #527). At a
/// terminal the model and reasoning level are chosen next, as after the
/// browser sign-in, and the sign-in is stored the same way
/// (`finishMetaskSignIn`): without a model a start on it would run the
/// compiled default, which the gateway does not serve. Without a terminal (a
/// script that confirms the code elsewhere) only the session is stored, as
/// before, and the start that uses it names its model.
fn runMetaskDeviceLogin(allocator: std.mem.Allocator, io: std.Io, state_dir: []const u8, open_browser: bool) u8 {
    const token_json = metask_oauth_mod.acquireDeviceToken(
        allocator,
        io,
        metask_oauth_mod.siteUrl(),
        open_browser,
        metaskDeviceNotify,
    ) catch |err| {
        std.debug.print("error: Metask device login failed ({s})\n", .{@errorName(err)});
        return 1;
    };
    defer {
        std.crypto.secureZero(u8, token_json);
        allocator.free(token_json);
    }
    if (platform_term.isatty(0) and platform_term.isatty(2)) {
        return finishMetaskSignIn(allocator, io, state_dir, token_json, "Signed in to Metask with the device code");
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const outcome = provider_oauth_mod.parseTokenResponse(arena.allocator(), token_json) catch |err| {
        std.debug.print("error: Metask token response malformed ({s})\n", .{@errorName(err)});
        return 1;
    };
    if (outcome.refresh_token == null or outcome.gateway_url == null or outcome.models_url == null) {
        std.debug.print("error: Metask token response is missing refresh_token or gateway_url/models_url\n", .{});
        return 1;
    }
    if (!metask_oauth_mod.isGatewayOrigin(outcome.gateway_url.?)) {
        std.debug.print("error: Metask gateway_url must be an http(s) origin (no /v1 path)\n", .{});
        return 1;
    }
    const provider_id = provider_ids_mod.Slug.lit("metask");
    var session = provider_oauth_mod.Session.initHome(allocator, hostRoot(), provider_id) catch |err| {
        std.debug.print("error: could not open the Metask OAuth store ({s})\n", .{@errorName(err)});
        return 2;
    };
    defer session.deinit();
    session.setClientId(null) catch |err| {
        std.debug.print("error: could not initialize the Metask OAuth store ({s})\n", .{@errorName(err)});
        return 2;
    };
    // The session this one replaces (#560), revoked once it is stored.
    var replaced = metask_oauth_mod.Replaced.capture(allocator, hostRoot());
    defer replaced.deinit();
    session.importOutcome(outcome, @import("metacodes-internal").util.time.nowUnix()) catch |err| {
        std.debug.print("error: could not store the Metask OAuth session ({s})\n", .{@errorName(err)});
        return 2;
    };
    std.debug.print("Stored Metask OAuth session. No secret was printed.\n", .{});
    printReplacedNote(replaced.revoke(token_json, metask_oauth_mod.siteUrl(), 5000));
    std.debug.print("No model was chosen (not at a terminal): start with --model <id>, or choose one with /model.\n", .{});
    return 0;
}

/// `metacodes login --provider <id>` — the interactive path (issue #33).
///
/// Everything downstream of the first token already worked for any provider:
/// refresh, single flight, rotated-refresh persistence, turn-boundary refresh.
/// What was missing was a way to *get* that first token without producing a
/// token response by other means. This runs the RFC 6749 loopback-PKCE grant
/// (or the RFC 8628 device grant for a session with no browser) and then hands
/// the result to exactly the same durable import `--oauth-token-json` uses, so
/// both entry points converge on identical stored state.
fn runProviderOAuthLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider_name: []const u8,
    options: ProviderLoginOptions,
) u8 {
    const host = buildProviderHost(allocator) orelse return 2;
    defer host.destroy();

    const built = host.registry.find(provider_name) orelse {
        std.debug.print("error: unknown provider '{s}'\n", .{provider_name});
        return 2;
    };
    // Every refusal is decided in the kernel before anything is contacted;
    // this only says which one, in the words the CLI has always used.
    var stdin_paste: terminal_prompt.StdinPaste = .{};
    const prepared = provider_login.prepareProfileWith(built, .{
        .method = options.method,
        .open_browser = options.open_browser,
        .client_id = options.client_id,
        .state_root = hostRoot(),
        .paste = if (options.method == .loopback) stdin_paste.source() else null,
    }, host.oauthClientIdFor(built.id)) catch |err| switch (err) {
        error.ProviderHasNoTokenEndpoint, error.ProviderAcceptsNoOAuthKind => {
            _ = requireOAuthCapableProvider(built);
            return 2;
        },
        error.FlowUnavailable => {
            std.debug.print(
                "error: provider '{s}' declares no {s} endpoint; " ++
                    "use `metacodes login --provider {s} --oauth-token-json <file>`\n",
                .{
                    built.id.slice(),
                    switch (options.method) {
                        .loopback => "OAuth authorization",
                        .device_code => "device authorization",
                    },
                    built.id.slice(),
                },
            );
            return 2;
        },
        error.ClientIdMissing => {
            std.debug.print(
                "error: provider '{s}' declares no OAuth client id; " ++
                    "pass --client-id <client> or set providers.{s}.oauth_client_id " ++
                    "in <state root>/config.json\n" ++
                    "(a provider defined under custom_providers can declare " ++
                    "oauth.client_id instead; every one of these is used for refresh too)\n",
                .{ built.id.slice(), built.id.slice() },
            );
            return 2;
        },
    };

    var diagnostic: provider_login.ImportDiagnostic = .{};
    _ = prepared.run(allocator, io, oauth_login.stderrNotify(), &diagnostic) catch |err| switch (err) {
        error.InvalidTokenResponse,
        error.MissingRefreshToken,
        error.MetaskGatewayMissing,
        error.MetaskGatewayNotOrigin,
        error.StoreOpenFailed,
        error.ClientRecordFailed,
        error.TokenStoreFailed,
        => |import_err| return reportImportFailure(@errorCast(import_err), diagnostic),
        else => {
            std.debug.print("error: OAuth login failed ({s})\n", .{@errorName(err)});
            return 1;
        },
    };
    std.debug.print(
        "Stored an OAuth login for provider '{s}'. No secret was printed.\n",
        .{built.id.slice()},
    );
    return 0;
}

/// The one durable import both provider login paths end in
/// (`provider_login.importTokenResponse`). Keeping it single is what makes
/// "logged in interactively" and "imported a token response" indistinguishable
/// to everything downstream; this only reports the outcome.
fn importProviderTokenResponse(
    allocator: std.mem.Allocator,
    provider_id: provider_ids.Slug,
    token_json: []const u8,
    client_id: ?[]const u8,
) u8 {
    // A Metask session this replaces (#560), revoked once it is stored.
    var replaced = if (provider_id.eqlText("metask")) metask_oauth_mod.Replaced.capture(allocator, hostRoot()) else metask_oauth_mod.Replaced.none;
    defer replaced.deinit();
    var diagnostic: provider_login.ImportDiagnostic = .{};
    provider_login.importTokenResponse(allocator, hostRoot(), provider_id, token_json, client_id, &diagnostic) catch |err|
        return reportImportFailure(err, diagnostic);
    std.debug.print(
        "Stored an OAuth login for provider '{s}'. No secret was printed.\n",
        .{provider_id.slice()},
    );
    printReplacedNote(replaced.revoke(token_json, metask_oauth_mod.siteUrl(), 5000));
    return 0;
}

/// The import's refusal in the words the CLI has always used, with the exit
/// code it has always returned: 1 for a token response that cannot be used,
/// 2 for a store that could not be written.
fn reportImportFailure(err: provider_login.ImportError, diagnostic: provider_login.ImportDiagnostic) u8 {
    switch (err) {
        error.InvalidTokenResponse => {
            std.debug.print("error: the token endpoint did not return a token response ({s})\n", .{causeName(diagnostic)});
            return 1;
        },
        error.MissingRefreshToken => {
            std.debug.print("error: the token response carries no refresh_token; it could never be refreshed\n", .{});
            return 1;
        },
        error.MetaskGatewayMissing => {
            std.debug.print("error: the Metask token response must include gateway_url and models_url\n", .{});
            return 1;
        },
        error.MetaskGatewayNotOrigin => {
            std.debug.print("error: Metask gateway_url must be an http(s) origin (no /v1 path)\n", .{});
            return 1;
        },
        error.StoreOpenFailed => {
            std.debug.print("error: could not open the OAuth store ({s})\n", .{causeName(diagnostic)});
            return 2;
        },
        error.ClientRecordFailed => {
            std.debug.print("error: could not record the OAuth client ({s})\n", .{causeName(diagnostic)});
            return 2;
        },
        error.TokenStoreFailed => {
            std.debug.print("error: could not store the token ({s})\n", .{causeName(diagnostic)});
            return 2;
        },
    }
}

fn causeName(diagnostic: provider_login.ImportDiagnostic) []const u8 {
    return if (diagnostic.cause) |cause| @errorName(cause) else "unknown";
}

/// Set once the configuration warning has been shown.
var startup_warning_reported: bool = false;

/// Build the provider runtime the way a session does: built-in profiles, the
/// user's `custom_providers`, any configured catalogs, the credential pool, and
/// the disabled set.
///
/// One construction path for startup route resolution, credential scoping, and
/// `--check-providers`, because three of them assembling *different subsets*
/// is how `--provider openrouter` came to fail for a provider the dry run
/// happily listed. The caller destroys it.
fn buildProviderHost(allocator: std.mem.Allocator) ?*provider_host.Host {
    const host = provider_host.Host.create(allocator) catch return null;
    // `METACODES_OPENROUTER_URL` (development, tests) moves every OpenRouter
    // address, its requests included.
    openrouter_login.applyOriginOverride(host);
    // OpenRouter's models: the listing the last sign-in or refresh kept,
    // whatever its age (no request here).
    _ = openrouter_catalog.adoptKept(host, allocator, hostRoot());
    var store = provider_config_store.Store.initHome(allocator, hostRoot()) catch return host;
    defer store.deinit();
    host.adoptDurableState(&store);
    if (host.startup_warning) |why| {
        // Once per process. Startup builds this runtime more than once — route
        // resolution and credential scoping each need one — and repeating the
        // same warning reads as more than one problem.
        if (!startup_warning_reported) {
            startup_warning_reported = true;
            // Without this, a `custom_providers` section that failed to parse
            // surfaces as `unknown provider 'my-relay'` with nothing connecting
            // the two — which is the report this warning exists to prevent.
            std.debug.print(
                "warning: part of <state root>/config.json did not apply ({s}); " ++
                    "run `metacodes --check-providers` for details\n",
                .{why},
            );
        }
    }
    var shadowed_buf: [256]u8 = undefined;
    if (host.shadowedNotice(&shadowed_buf)) |notice| {
        if (!shadowed_notice_reported) {
            shadowed_notice_reported = true;
            std.debug.print("warning: {s}\n", .{notice});
        }
    }
    return host;
}

/// Set once the notice about a configuration entry that names a built-in
/// provider has been shown.
var shadowed_notice_reported: bool = false;

/// `--check-providers`: validate the configuration and print every route it
/// produces, without any network I/O. This is the dry run — it answers "would
/// this definition work?" before a request is ever built.
pub fn checkProviders(allocator: std.mem.Allocator) u8 {
    // Built the same way a session builds it, so the dry run cannot describe a
    // different set of routes than the one a session will actually get.
    const host = provider_host.Host.create(allocator) catch {
        std.debug.print("error: provider registry initialization failed\n", .{});
        return 2;
    };
    defer host.destroy();

    var status: u8 = 0;
    var store = provider_config_store.Store.initHome(allocator, hostRoot()) catch null;
    defer if (store) |*value| value.deinit();

    if (store) |*value| {
        if (value.readText()) |text| {
            defer allocator.free(text);
            // Reported individually rather than swallowed: the whole point of a
            // dry run is to say which definition is wrong.
            host.adoptCustomProviders(text) catch |err| {
                std.debug.print("custom_providers: INVALID ({s})\n", .{@errorName(err)});
                status = 2;
            };
            host.ingestConfiguredCatalogs(text) catch |err| {
                std.debug.print("provider_catalogs: NOT INGESTED ({s})\n", .{@errorName(err)});
                status = 2;
            };
            var shadowed_buf: [256]u8 = undefined;
            if (host.shadowedNotice(&shadowed_buf)) |notice| std.debug.print("note: {s}\n", .{notice});
            if (value.load()) |loaded| {
                var document = loaded;
                defer document.deinit();
                host.applyProviderConfiguration(&document) catch |err| {
                    std.debug.print("providers: NOT APPLIED ({s})\n", .{@errorName(err)});
                    status = 2;
                };
            } else |err| {
                std.debug.print("config: unparseable ({s})\n", .{@errorName(err)});
                status = 2;
            }
        } else |err| {
            std.debug.print("config: unreadable ({s})\n", .{@errorName(err)});
            status = 2;
        }
    }

    const catalog = host.kernel.catalogSnapshot();
    for (catalog.items()) |item| {
        const rendered = item.offer_id.render();
        std.debug.print("{s}/{s} [{s}] model={s}\n  endpoint {s}\n  offer    {s}\n", .{
            item.provider_id.slice(),
            item.channel_id.slice(),
            item.protocol,
            item.request_model_id,
            item.endpoint_ref,
            &rendered,
        });
        if (item.limits.context_window) |window| {
            std.debug.print("  context  {d}\n", .{window});
        } else {
            std.debug.print("  context  unknown (admission fails closed)\n", .{});
        }
        if (item.quote.priced()) |price| {
            std.debug.print("  price    {s} {s}{s}\n", .{
                price.currency.slice(),
                switch (price.billing_unit) {
                    .per_million_tokens => "per 1M tokens",
                    .per_thousand_tokens => "per 1K tokens",
                    .per_token => "per token",
                    .per_request => "per request",
                    .provider_defined => "provider-defined unit",
                },
                if (price.estimated) " (estimated)" else "",
            });
        } else {
            std.debug.print("  price    unknown\n", .{});
        }
    }
    std.debug.print("{d} route(s); no request was made.\n", .{catalog.items().len});
    return status;
}

pub fn resolveProviderScopedSecret(
    allocator: std.mem.Allocator,
    config: types.Config,
    profile_name: []const u8,
) ![]u8 {
    return (try resolveProviderScopedCredential(allocator, config, profile_name)).secret;
}

/// A provider-scoped credential and where it came from (the banner says it).
pub const ScopedCredential = struct {
    /// Owned by the caller's allocator; zero it before freeing.
    secret: []u8,
    origin: route_state_mod.CredentialOrigin,
};

/// `resolveProviderScopedSecret`, with the credential's origin.
pub fn resolveProviderScopedCredential(
    allocator: std.mem.Allocator,
    config: types.Config,
    profile_name: []const u8,
) !ScopedCredential {
    return resolveProviderScopedCredentialReporting(allocator, config, profile_name, .print_help);
}

/// What a provider-scoped resolution says when it fails, and how far it goes.
/// `print_help` (`-p`, the CLI) prints the provider's credential help;
/// `quiet` (the TUI's reminder) leaves saying it to the caller. Both end
/// with the provider's own sign-in, refreshed when it is due. `keys_only` (a
/// dry check: the startup order, `login status`) is quiet and stops at the
/// keys, so it never refreshes a sign-in and sends nothing.
const CredentialReport = enum { print_help, quiet, keys_only };

fn resolveProviderScopedCredentialReporting(
    allocator: std.mem.Allocator,
    config: types.Config,
    profile_name: []const u8,
    report: CredentialReport,
) !ScopedCredential {
    const host = buildProviderHost(allocator) orelse return error.UnknownProviderProfile;
    defer host.destroy();
    const profile = host.registry.find(profile_name) orelse return error.UnknownProviderProfile;
    return resolveProfileCredential(allocator, config, profile, report);
}

/// `resolveProviderScopedCredentialReporting` for a profile already found.
fn resolveProfileCredential(
    allocator: std.mem.Allocator,
    config: types.Config,
    profile: *const provider_profile.ProviderProfile,
    report: CredentialReport,
) !ScopedCredential {
    const credential_mod = provider_credential;
    const provider_ids_local = provider_ids;

    // The key `login --provider` stored for this provider, in its own file.
    var stored_key = provider_api_key_store.load(allocator, config.state_root, profile.id) catch |err| blk: {
        if (report == .print_help) std.debug.print("warning: the stored key for '{s}' cannot be used ({s}); run `{s} login --provider {s}` again\n", .{ profile.id.slice(), @errorName(err), invokedCommand(allocator), profile.id.slice() });
        break :blk null;
    };
    defer if (stored_key) |*key| key.deinit();

    var reference_buffer: [provider_ids_local.MAX_SLUG_LEN]u8 = undefined;
    const resolved = credential_mod.resolve(.{
        .provider_id = profile.id,
        .accepted_kinds = profile.accepted_credential_kinds,
        .env_aliases = profile.env_aliases,
        .cli_api_key = config.api_key,
        .stored_api_key = if (stored_key) |*key| key.entry() else null,
        .env = credential_mod.EnvLookup.process(),
        // `<state root>/.env` (#486), below the process environment.
        .env_fallback = config.credential_env_fallback orelse credential_mod.EnvLookup.empty(),
    }, &reference_buffer) catch |err| {
        // Below every key in the credential order: the provider's own OAuth
        // sign-in (`login --provider`, `/login <provider>`), refreshed first
        // when it expires within two minutes or already has.
        if (err == error.MissingCredentials and report != .keys_only) {
            if (providerSignInToken(allocator, config.state_root, profile)) |found| {
                if (found) |token| return .{ .secret = token, .origin = .sign_in };
            } else |sign_in_err| {
                if (report == .print_help) std.debug.print(
                    "error: the {s} sign-in could not be used ({s}); sign in again: {s} login --provider {s}\n",
                    .{ profile.display_name, @errorName(sign_in_err), invokedCommand(allocator), profile.id.slice() },
                );
                return error.MissingCredentials;
            }
        }
        if (report != .print_help) return err;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const local_path: []const u8 = if (config.state_root.len == 0) "" else std.fmt.bufPrint(&path_buf, "{s}{c}{s}", .{
            config.state_root, std.fs.path.sep, state_env_mod.file_name,
        }) catch "";
        printProviderCredentialHelp(profile.*, err, invokedCommand(allocator), local_path);
        return err;
    };
    const origin: route_state_mod.CredentialOrigin = switch (resolved.ref.source) {
        .cli, .runtime_fd => .flag,
        .stored => .saved_key,
        // The process environment wins over `.env` (#486): an alias it does
        // not set came from the file.
        .env => if (resolved.alias_used) |name| (if (credential_mod.EnvLookup.process().get(name) != null) .environment else .local_config) else .unknown,
        .interactive, .unknown => .unknown,
    };
    return .{ .secret = try allocator.dupe(u8, resolved.secret), .origin = origin };
}

/// The access token of `profile`'s own OAuth sign-in
/// (`<state root>/oauth/<provider>.json`), refreshed first when it expires
/// within `provider_oauth_mod.REFRESH_MARGIN_SECONDS` (two minutes) or already
/// has, the way a session's turn boundary refreshes it
/// (`App.oauthAccessToken`). Owned; zero it before freeing. Null when the
/// profile declares no OAuth lifecycle, when there is no state root, and
/// when no sign-in is stored. Metask's is its own path
/// (`resolveMetaskBearer`).
pub fn providerSignInToken(
    allocator: std.mem.Allocator,
    state_root: []const u8,
    profile: *const provider_profile.ProviderProfile,
) !?[]u8 {
    if (!signInDeclared(profile)) return null;
    const token_url = profile.oauth_token_url.?;
    var session = provider_oauth_mod.Session.initHome(allocator, state_root, profile.id) catch |err| switch (err) {
        // No state root (no `HOME`, `--state-dir` or `METACODES_HOME`): no
        // sign-in can be stored, so there is none, and the credential help
        // the caller prints for a missing key stands.
        error.NoHome => return null,
        else => return err,
    };
    defer session.deinit();
    if (!(try session.load())) return null;
    var io_runtime = @import("metacodes-internal").platform.signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    // The refresh grant presents the client the sign-in recorded.
    var exchange = oauth_exchange_mod.HttpExchange{
        .allocator = allocator,
        .io = io_runtime.io(),
        .endpoint = .{ .token_url = token_url, .client_id = session.clientIdFor(profile.oauth_client_id) },
    };
    return try session.accessToken(@import("metacodes-internal").util.time.nowUnix(), exchange.exchange());
}

/// Whether a start reads `profile`'s own OAuth sign-in at all: it declares a
/// token endpoint and accepts a credential kind an OAuth token serves.
/// Metask's sign-in is its own path (`resolveMetaskBearer`).
fn signInDeclared(profile: *const provider_profile.ProviderProfile) bool {
    if (profile.id.eqlText("metask") or profile.oauth_token_url == null) return false;
    for (profile.accepted_credential_kinds) |kind| {
        if (provider_oauth_mod.servesKind(kind)) return true;
    }
    return false;
}

/// Whether `profile`'s own OAuth sign-in is stored, judged from the file
/// alone: nothing is refreshed and nothing sent, so one at or past its expiry
/// counts too (a start refreshes it, `providerSignInToken`). False wherever
/// that finds none: no sign-in declared, none stored, one that does not
/// parse, no state root.
fn providerSignInStored(
    allocator: std.mem.Allocator,
    state_root: []const u8,
    profile: *const provider_profile.ProviderProfile,
) bool {
    if (!signInDeclared(profile)) return false;
    var session = provider_oauth_mod.Session.initHome(allocator, state_root, profile.id) catch return false;
    defer session.deinit();
    return session.load() catch false;
}

/// `command` is the command the user ran (`invokedCommand`); `local_path`
/// this install's `<state root>/.env` ("" when it has no state root).
fn printProviderCredentialHelp(
    profile: @import("metacodes-internal").provider.profile.ProviderProfile,
    err: anyerror,
    command: []const u8,
    local_path: []const u8,
) void {
    switch (err) {
        error.AmbiguousCredentialAliases => {
            std.debug.print(
                "Conflicting credentials for provider '{s}'.\n" ++
                    "Several accepted environment variables hold different values; unset all but one.\n",
                .{profile.id.slice()},
            );
            if (local_path.len > 0) std.debug.print(
                "When the environment sets none of them, the ones in {s} are read instead and must agree too.\n",
                .{local_path},
            );
            std.debug.print("No token value was printed.\n", .{});
        },
        else => {
            std.debug.print(
                "Authentication required for provider '{s}'.\n",
                .{profile.id.slice()},
            );
            if (profile.api_key_setup) |setup| {
                // A provider the user defined has no page: its key comes from
                // whoever runs it (`KeyPage.url`).
                const opens_page = for (setup.pages) |page| {
                    if (page.url != null) break true;
                } else false;
                if (opens_page) {
                    std.debug.print("  {s} login --provider {s}   (opens the page the key is created on, then stores it)\n", .{ command, profile.id.slice() });
                } else {
                    std.debug.print("  {s} login --provider {s}   (stores a key you paste; for a server that needs none, paste `{s}`)\n", .{ command, profile.id.slice(), @import("app/providers_cli.zig").no_key_placeholder });
                }
                if (setup.note) |note| std.debug.print("  {s}\n", .{note});
            } else if (profile.declaresInteractiveOAuth() and profile.oauth_client_id != null) {
                std.debug.print("  {s} login --provider {s}   (signs in in the browser, then stores the sign-in)\n", .{ command, profile.id.slice() });
            }
            for (profile.accepted_credential_kinds) |kind| {
                if (profile.canonicalEnvAlias(kind)) |canonical| {
                    std.debug.print("  export {s}=...\n", .{canonical});
                    if (local_path.len > 0) std.debug.print("    or {s}=... in {s} (read when metacodes starts)\n", .{ canonical, local_path });
                }
            }
            // A provider that signs in only (`chatgpt-codex`) takes no key.
            if (profile.takesApiKey()) std.debug.print("  {s} --api-key <key> --provider {s} ...\n", .{ command, profile.id.slice() });
            std.debug.print("No token value was printed.\n", .{});
        },
    }
}

fn isUsableConfiguredSession(config: types.Config, source: auth.CredentialSource) bool {
    return switch (source) {
        .cli_api_key, .fd_api_key, .env_api_key => true,
        .stored_api_key => config.model_explicit and config.reasoning_effort != null,
        .stored_oauth => false,
    };
}

fn parseArgs(init: std.process.Init, allocator: std.mem.Allocator) types.Config {
    var config = types.Config{};
    var args = argsIter(init);
    defer args.deinit();
    parseArgsInto(&config, &args, allocator);
    return config;
}

/// 共享解析逻辑(parseArgs 生产路径 + parseArgsForTest 测试路径都走它)。
fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// 参数错误统一落 config.parse_error(完整人话消息);main 打印后 exit 2。
fn setParseError(
    config: *types.Config,
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    fmt_args: anytype,
) void {
    config.parse_error = std.fmt.allocPrint(allocator, fmt, fmt_args) catch "argument parse error";
}

fn parseArgsInto(config: *types.Config, args: *std.process.Args.Iterator, allocator: std.mem.Allocator) void {
    // argv[0] 是程序名,显式消费。旧实现靠"未匹配即忽略"让它混过循环——
    // 那个静默 else 同时也吞掉了所有拼错的 flag(评估 treatment 参数
    // 拼错 → 无声降级),所以这里改为显式跳过 + 尾部 fail-closed。
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version")) {
            config.show_version = true;
        } else if (std.mem.eql(u8, arg, "--model")) {
            if (args.next()) |m| {
                config.model = allocator.dupe(u8, m) catch m;
                config.model_explicit = true;
            }
        } else if (std.mem.eql(u8, arg, "--model-display-name")) {
            if (args.next()) |name| {
                config.model_display_name = allocator.dupe(u8, name) catch name;
            }
        } else if (std.mem.eql(u8, arg, "--reasoning-effort") or std.mem.eql(u8, arg, "--thinking")) {
            // 值域 fail-closed:拼错的档位静默落自适应 = 评估 treatment 无声降级。
            const e = args.next() orelse {
                setParseError(config, allocator, "missing value for {s}", .{arg});
                return;
            };
            config.reasoning_effort = types.ReasoningEffort.parse(e) orelse {
                setParseError(config, allocator, "invalid value '{s}' for {s}", .{ e, arg });
                return;
            };
        } else if (std.mem.eql(u8, arg, "--temperature")) {
            const s = args.next() orelse {
                setParseError(config, allocator, "missing value for --temperature", .{});
                return;
            };
            config.temperature = std.fmt.parseFloat(f32, s) catch {
                setParseError(config, allocator, "invalid value '{s}' for --temperature", .{s});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--top-p")) {
            const s = args.next() orelse {
                setParseError(config, allocator, "missing value for --top-p", .{});
                return;
            };
            config.top_p = std.fmt.parseFloat(f32, s) catch {
                setParseError(config, allocator, "invalid value '{s}' for --top-p", .{s});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--prompt-cache-key")) {
            if (args.next()) |s| config.prompt_cache_key = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--parallel-tool-calls")) {
            if (args.next()) |s| {
                if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1")) config.parallel_tool_calls = true else if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "0")) config.parallel_tool_calls = false;
            }
        } else if (std.mem.eql(u8, arg, "--response-format")) {
            if (args.next()) |s| {
                if (std.mem.eql(u8, s, "json_object") or std.mem.eql(u8, s, "json_schema")) {
                    config.response_format = allocator.dupe(u8, s) catch s;
                }
            }
        } else if (std.mem.eql(u8, arg, "--api-key")) {
            if (args.next()) |k| config.api_key = allocator.dupe(u8, k) catch k;
        } else if (std.mem.eql(u8, arg, "--permission") or std.mem.eql(u8, arg, "--permission-mode")) {
            // 词表外的 mode 曾静默落 .default(最严档)——评估 harness 传
            // bypassPermissions 拼错时,付费 arm 会在错误权限档下跑完全程。
            const m = args.next() orelse {
                setParseError(config, allocator, "missing value for {s}", .{arg});
                return;
            };
            config.permission_mode = @import("metacodes-internal").permission.mode.parseStrict(m) orelse {
                setParseError(config, allocator, "invalid permission mode '{s}'", .{m});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--settings")) {
            if (args.next()) |s| config.settings_path = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--allowedTools") or std.mem.eql(u8, arg, "--allowed-tools")) {
            if (args.next()) |s| config.allowed_tools = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--disallowedTools") or std.mem.eql(u8, arg, "--disallowed-tools")) {
            if (args.next()) |s| config.disallowed_tools = allocator.dupe(u8, s) catch s;
        } else if (config.preview.applyArg(arg) catch {
            setParseError(config, allocator, "unknown preview feature in '{s}'", .{arg});
            return;
        }) {} else if (std.mem.eql(u8, arg, "--verification-checkpoint")) {
            config.verification_checkpoint = true;
        } else if (std.mem.eql(u8, arg, "--verification-final-gate")) {
            config.verification_final_gate = true;
        } else if (std.mem.eql(u8, arg, "--verification-final-observe")) {
            config.verification_final_observe = true;
        } else if (std.mem.eql(u8, arg, "--requirement-ledger")) {
            config.requirement_ledger = true;
        } else if (std.mem.eql(u8, arg, "--requirement-ledger-observe")) {
            config.requirement_ledger_observe = true;
        } else if (std.mem.eql(u8, arg, "--delivery-cadence")) {
            config.delivery_cadence = true;
        } else if (std.mem.eql(u8, arg, "--delivery-cadence-observe")) {
            config.delivery_cadence_observe = true;
        } else if (std.mem.eql(u8, arg, "--no-progress-updates")) {
            config.progress_updates = false;
        } else if (std.mem.eql(u8, arg, "--progress-updates-observe")) {
            config.progress_updates_observe = true;
        } else if (std.mem.eql(u8, arg, "--host-check")) {
            const s = args.next() orelse {
                setParseError(config, allocator, "missing value for --host-check", .{});
                return;
            };
            if (std.mem.trim(u8, s, " \t\r\n").len == 0 or s.len > check_gate.MAX_COMMAND_BYTES) {
                setParseError(config, allocator, "invalid value for --host-check (need a non-empty command of at most {d} bytes)", .{check_gate.MAX_COMMAND_BYTES});
                return;
            }
            config.host_check_command = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--check-gate")) {
            config.check_gate = true;
        } else if (std.mem.eql(u8, arg, "--check-gate-observe")) {
            config.check_gate_observe = true;
        } else if (std.mem.eql(u8, arg, "--learning-turn")) {
            config.learning_turn = true;
        } else if (std.mem.eql(u8, arg, "--harnessmm")) {
            config.harnessmm = true;
        } else if (std.mem.eql(u8, arg, "--no-harnessmm")) {
            config.harnessmm = false;
        } else if (std.mem.eql(u8, arg, "--rsi")) {
            config.rsi = true;
        } else if (std.mem.eql(u8, arg, "--no-rsi")) {
            config.rsi = false;
        } else if (std.mem.eql(u8, arg, "--rsi-policy")) {
            const path = args.next() orelse {
                setParseError(config, allocator, "missing value for --rsi-policy", .{});
                return;
            };
            if (path.len == 0 or std.mem.startsWith(u8, path, "--")) {
                setParseError(config, allocator, "invalid value for --rsi-policy", .{});
                return;
            }
            config.rsi_policy_path = allocator.dupe(u8, path) catch path;
        } else if (std.mem.eql(u8, arg, "--learning-turn-observe")) {
            config.learning_turn_observe = true;
        } else if (std.mem.eql(u8, arg, "--verifier")) {
            config.verifier = true;
        } else if (std.mem.eql(u8, arg, "--verifier-observe")) {
            config.verifier_observe = true;
        } else if (std.mem.eql(u8, arg, "--verifier-model")) {
            const s = args.next() orelse {
                setParseError(config, allocator, "missing value for --verifier-model", .{});
                return;
            };
            if (std.mem.trim(u8, s, " \t\r\n").len == 0 or std.mem.eql(u8, s, "inherit")) {
                setParseError(config, allocator, "invalid value '{s}' for --verifier-model (expected a model or tier name)", .{s});
                return;
            }
            config.verifier_model = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--test-integrity")) {
            config.test_integrity = true;
        } else if (std.mem.eql(u8, arg, "--test-integrity-observe")) {
            config.test_integrity_observe = true;
        } else if (std.mem.eql(u8, arg, "--stall-gate")) {
            config.stall_gate = .enforce;
        } else if (std.mem.eql(u8, arg, "--stall-gate-observe")) {
            config.stall_gate = .observe;
        } else if (std.mem.eql(u8, arg, "--no-stall-gate")) {
            config.stall_gate = .off;
        } else if (std.mem.eql(u8, arg, "--check-gate-max")) {
            const s = args.next() orelse {
                setParseError(config, allocator, "missing value for --check-gate-max", .{});
                return;
            };
            const n = std.fmt.parseInt(u8, s, 10) catch 0;
            if (n == 0 or n > check_gate.HARD_MAX_CONTINUATIONS) {
                setParseError(config, allocator, "invalid value '{s}' for --check-gate-max (expected 1..{d})", .{ s, check_gate.HARD_MAX_CONTINUATIONS });
                return;
            }
            config.check_gate_max = n;
        } else if (std.mem.eql(u8, arg, "--delivery-cadence-thresholds")) {
            const s = args.next() orelse {
                setParseError(config, allocator, "missing value for --delivery-cadence-thresholds", .{});
                return;
            };
            const comma = std.mem.indexOfScalar(u8, s, ',') orelse {
                setParseError(config, allocator, "invalid value '{s}' for --delivery-cadence-thresholds (expected <first>,<second>)", .{s});
                return;
            };
            const first = std.fmt.parseInt(u32, s[0..comma], 10) catch 0;
            const second = std.fmt.parseInt(u32, s[comma + 1 ..], 10) catch 0;
            if (first == 0 or second <= first) {
                setParseError(config, allocator, "invalid value '{s}' for --delivery-cadence-thresholds (need 0 < first < second)", .{s});
                return;
            }
            config.delivery_cadence_first = first;
            config.delivery_cadence_second = second;
        } else if (std.mem.eql(u8, arg, "--add-dir")) {
            if (args.next()) |s| config.add_dirs = appendNulList(allocator, config.add_dirs, s);
        } else if (std.mem.eql(u8, arg, "--image")) {
            // headless 多模态输入(issue #10):可重复,顺序保留。路径在 headless.run
            // 读取校验(MIME 白名单/大小上限),这里只收集。
            const s = args.next() orelse {
                setParseError(config, allocator, "missing value for --image", .{});
                return;
            };
            config.images = appendNulList(allocator, config.images, s);
        } else if (std.mem.eql(u8, arg, "--plugin-dir")) {
            const s = args.next() orelse {
                setParseError(config, allocator, "missing value for --plugin-dir", .{});
                return;
            };
            config.plugin_dirs = appendNulList(allocator, config.plugin_dirs, s);
        } else if (std.mem.eql(u8, arg, "--process-plugin-dir")) {
            const s = args.next() orelse {
                setParseError(config, allocator, "missing value for --process-plugin-dir", .{});
                return;
            };
            config.process_plugin_dirs = appendNulList(allocator, config.process_plugin_dirs, s);
        } else if (std.mem.eql(u8, arg, "--answers-file")) {
            if (args.next()) |s| config.answers_file = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--base-url")) {
            if (args.next()) |s| config.base_url = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--check-providers")) {
            config.check_providers = true;
        } else if (std.mem.eql(u8, arg, "--provider")) {
            const v = args.next() orelse {
                setParseError(config, allocator, "missing value for --provider", .{});
                return;
            };
            config.provider_profile = allocator.dupe(u8, v) catch v;
        } else if (std.mem.eql(u8, arg, "--channel")) {
            const v = args.next() orelse {
                setParseError(config, allocator, "missing value for --channel", .{});
                return;
            };
            config.provider_channel = allocator.dupe(u8, v) catch v;
        } else if (std.mem.eql(u8, arg, "--offer")) {
            const v = args.next() orelse {
                setParseError(config, allocator, "missing value for --offer", .{});
                return;
            };
            config.provider_offer = allocator.dupe(u8, v) catch v;
        } else if (std.mem.eql(u8, arg, "--preset")) {
            const v = args.next() orelse {
                setParseError(config, allocator, "missing value for --preset", .{});
                return;
            };
            config.preset = allocator.dupe(u8, v) catch v;
        } else if (std.mem.eql(u8, arg, "--openai-protocol")) {
            // 值域 fail-closed:拼错的协议名静默落默认 = 请求打到错误端点还不知情。
            const v = args.next() orelse {
                setParseError(config, allocator, "missing value for --openai-protocol", .{});
                return;
            };
            config.openai_protocol_explicit = true;
            config.openai_protocol = types.OpenAIProtocol.parse(v) orelse {
                setParseError(config, allocator, "invalid value '{s}' for --openai-protocol (chat|chat_completions|responses)", .{v});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--auth-precedence")) {
            if (args.next()) |s| {
                if (auth.parsePrecedence(s)) |p| config.auth_precedence = p;
            }
        } else if (std.mem.eql(u8, arg, "--record")) {
            if (args.next()) |s| config.record_dir = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--state-dir") or std.mem.startsWith(u8, arg, "--state-dir=")) {
            const value = if (arg.len > "--state-dir".len) arg["--state-dir=".len..] else args.next() orelse {
                setParseError(config, allocator, "missing value for --state-dir", .{});
                return;
            };
            if (value.len == 0) {
                setParseError(config, allocator, "empty value for --state-dir", .{});
                return;
            }
            config.state_dir = allocator.dupe(u8, value) catch value;
        } else if (std.mem.eql(u8, arg, "--max-tokens")) {
            const s = args.next() orelse {
                setParseError(config, allocator, "missing value for --max-tokens", .{});
                return;
            };
            config.max_tokens = std.fmt.parseInt(u32, s, 10) catch {
                setParseError(config, allocator, "invalid value '{s}' for --max-tokens", .{s});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--no-theme")) {
            config.no_theme = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, arg, "--lsp")) {
            config.lsp_enabled = true; // 默认已开;保留显式开启(可覆盖前面的 --no-lsp)
        } else if (std.mem.eql(u8, arg, "--no-lsp")) {
            // 默认开之后的逃生口(对齐 --no-theme/--no-browser 的否定式)。后写覆盖先写。
            config.lsp_enabled = false;
        } else if (std.mem.eql(u8, arg, "--agent-teams")) {
            config.agent_teams = true; // SW2:开 teams/teammates(TeamCreate/SendMessage 等)
        } else if (std.mem.eql(u8, arg, "--teammate")) {
            config.agent_teams = true; // SW6:进程外 teammate 模式(隐含 teams 开)
        } else if (std.mem.eql(u8, arg, "--agent-name")) {
            if (args.next()) |v| config.teammate_name = allocator.dupe(u8, v) catch v;
        } else if (std.mem.eql(u8, arg, "--team-name")) {
            if (args.next()) |v| config.teammate_team = allocator.dupe(u8, v) catch v;
        } else if (std.mem.eql(u8, arg, "--parent-session-id")) {
            if (args.next()) |v| config.teammate_parent_session = allocator.dupe(u8, v) catch v;
        } else if (std.mem.eql(u8, arg, "--teammate-lease-id")) {
            if (args.next()) |v| config.teammate_lease_id = allocator.dupe(u8, v) catch v;
        } else if (std.mem.eql(u8, arg, "--teammate-cwd")) {
            if (args.next()) |v| config.teammate_cwd = allocator.dupe(u8, v) catch v;
        } else if (std.mem.eql(u8, arg, "--teammate-key-fd")) {
            const v = args.next() orelse {
                setParseError(config, allocator, "missing value for --teammate-key-fd", .{});
                return;
            };
            config.teammate_key_fd = std.fmt.parseInt(c_int, v, 10) catch {
                setParseError(config, allocator, "invalid value '{s}' for --teammate-key-fd", .{v});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--teammate-mode")) {
            const v = args.next() orelse {
                setParseError(config, allocator, "missing value for --teammate-mode", .{});
                return;
            };
            if (std.mem.eql(u8, v, "process")) {
                config.teammate_out_of_process = true;
            } else if (std.mem.eql(u8, v, "thread") or std.mem.eql(u8, v, "in-process")) {
                // "thread" 是 --help 文档化的进程内档名;in-process 作别名。
                config.teammate_out_of_process = false;
            } else {
                setParseError(config, allocator, "invalid value '{s}' for --teammate-mode (process|thread)", .{v});
                return;
            }
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print")) {
            if (args.next()) |p| config.prompt = allocator.dupe(u8, p) catch p;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.json_output = true;
        } else if (std.mem.eql(u8, arg, "--stream-json")) {
            config.stream_json = true;
        } else if (std.mem.eql(u8, arg, "--web")) {
            // 可选端口参数:下一个 arg 是数字才吃掉(否则它是别的 flag,留给循环)。
            // Iterator 无 peek → 值拷贝试探(POSIX iterator 是纯索引 struct,拷贝安全)。
            config.web_port = 7777;
            var probe = args.*;
            if (probe.next()) |maybe_port| {
                if (std.fmt.parseInt(u16, maybe_port, 10)) |p| {
                    config.web_port = p;
                    _ = args.next();
                } else |_| if (isAllDigits(maybe_port)) {
                    // 纯数字但超出 u16:这是写错的端口,不是别的 flag——
                    // 落到终结 else 会误报 "unknown argument",在此给准确错误。
                    setParseError(config, allocator, "invalid port '{s}' for --web (0-65535)", .{maybe_port});
                    return;
                }
            }
        } else if (std.mem.eql(u8, arg, "serve")) {
            // U10-D:`serve [port]` daemon 模式(位置子命令)。可选端口(下一个 arg 是数字才吃)。
            config.serve_port = 7777;
            var probe = args.*;
            if (probe.next()) |maybe_port| {
                if (std.fmt.parseInt(u16, maybe_port, 10)) |p| {
                    config.serve_port = p;
                    _ = args.next();
                } else |_| if (isAllDigits(maybe_port)) {
                    setParseError(config, allocator, "invalid port '{s}' for serve (0-65535)", .{maybe_port});
                    return;
                }
            }
        } else if (std.mem.eql(u8, arg, "--sessions")) {
            // U10-C/#254:the multi-session daemon, with N sessions built at startup (N ≥ 0).
            const v = args.next() orelse {
                setParseError(config, allocator, "missing value for --sessions", .{});
                return;
            };
            config.serve_sessions = std.fmt.parseInt(usize, v, 10) catch {
                setParseError(config, allocator, "invalid --sessions '{s}' (a session count, 0 or more)", .{v});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--max-sessions")) {
            // #254:the multi-session daemon's cap on live sessions.
            const v = args.next() orelse {
                setParseError(config, allocator, "missing value for --max-sessions", .{});
                return;
            };
            const max = std.fmt.parseInt(usize, v, 10) catch 0;
            if (max == 0) {
                setParseError(config, allocator, "invalid --max-sessions '{s}' (a session count, 1 or more)", .{v});
                return;
            }
            config.serve_max_sessions = max;
        } else if (std.mem.eql(u8, arg, "--uds")) {
            // U10-B:daemon 附加 UDS+NDJSON 绑定(路径)。设置即启用(强制走 serveMulti)。
            const v = args.next() orelse {
                setParseError(config, allocator, "missing value for --uds", .{});
                return;
            };
            config.uds_path = allocator.dupe(u8, v) catch v;
        } else if (std.mem.eql(u8, arg, "--web-bind")) {
            // #253: validated here, so a typo fails before anything starts.
            const v = args.next() orelse {
                setParseError(config, allocator, "missing value for --web-bind", .{});
                return;
            };
            config.web_bind = platform_net.parseIpLiteral(v, 0) catch |err| {
                setParseError(config, allocator, "invalid --web-bind '{s}': {s}", .{ v, webBindHint(err) });
                return;
            };
        } else if (std.mem.eql(u8, arg, "--web-token")) {
            // #252. The value is never echoed, not even in an error.
            const v = args.next() orelse {
                setParseError(config, allocator, "missing value for --web-token", .{});
                return;
            };
            web_server.validateToken(v) catch |err| {
                setParseError(config, allocator, "invalid --web-token: {s}", .{webTokenHint(err)});
                return;
            };
            config.web_token = allocator.dupe(u8, v) catch v;
        } else if (std.mem.eql(u8, arg, "--web-allow-unauth")) {
            config.web_allow_unauth = true;
        } else if (std.mem.eql(u8, arg, "--session")) {
            // task#20:显式 session id(subprocess resume 复用挂起 session 目录)。
            if (args.next()) |v| config.session_id = allocator.dupe(u8, v) catch null;
        } else if (std.mem.eql(u8, arg, "--suspendable")) {
            config.suspendable = true; // task#20:headless 遇 UI 工具挂起(写 suspend.json)而非 NotATty

        } else if (std.mem.eql(u8, arg, "--resume-response")) {
            // U8:值 = 迟来结果 JSON;`@path` 前缀从文件读(大结果/含引号免 shell 转义)。
            if (args.next()) |v| {
                if (v.len > 0 and v[0] == '@') {
                    config.resume_response = readFileAll(allocator, v[1..]) catch |e| blk: {
                        std.debug.print("error: could not read the --resume-response file: {s}\n", .{@errorName(e)});
                        break :blk null;
                    };
                } else {
                    config.resume_response = allocator.dupe(u8, v) catch v;
                }
            }
        } else if (std.mem.eql(u8, arg, "--resume")) {
            // A flag in the id's place means the id was left out.
            const v = args.next() orelse "";
            if (v.len == 0 or v[0] == '-') {
                setParseError(config, allocator, "missing session id for --resume", .{});
                return;
            }
            config.resume_session = allocator.dupe(u8, v) catch v;
        } else if (std.mem.eql(u8, arg, "--dump-prompt")) {
            config.dump_prompt = true;
        } else if (std.mem.eql(u8, arg, "--sections")) {
            config.dump_prompt_sections = true;
        } else if (std.mem.eql(u8, arg, "--dump-plugins")) {
            config.dump_plugins = true;
        } else if (std.mem.eql(u8, arg, "-")) {
            // 从 stdin 读全部作为 prompt（headless pipe 模式）。读失败显式落
            // parse_error——静默 null 会掉进 TUI(或触发误导的 --image 组合报错)。
            config.prompt = readAllStdin(allocator) catch {
                // 与其它 setParseError 站点一致地立即返回:继续解析会让后续错误覆盖
                // 本条(泄漏 allocPrint 串),第二个 `-` 还会对已失败的 stdin 重读。
                setParseError(config, allocator, "failed to read stdin prompt for '-'", .{});
                return;
            };
        } else {
            // 未识别参数一律 fail-closed:记录后停止解析,由 main 报错退出。
            // 绝不静默忽略——flag 面是外部契约(评估 harness 靠它传 treatment)。
            if (arg.len > 0 and arg[0] == '-') {
                setParseError(config, allocator, "unknown flag '{s}'", .{arg});
            } else {
                setParseError(config, allocator, "unexpected positional argument '{s}' (metacodes takes no positionals)", .{arg});
            }
            return;
        }
    }
    // `--image` 只在 headless prompt 模式(-p/--print/stdin `-`)消费;其它任何模式
    // (TUI/serve/web/dump)静默忽略违背 issue #10"图绝不静默丢"铁律与 flag 面
    // fail-closed 契约。统一在 parse 尾部拒绝(parseArgsForTest 可测)。
    if (config.images != null and config.prompt == null and config.parse_error == null) {
        setParseError(config, allocator, "--image requires -p/--print (headless prompt mode)", .{});
    }
    if (config.dump_prompt_sections and !config.dump_prompt and config.parse_error == null) {
        setParseError(config, allocator, "--sections requires --dump-prompt", .{});
    }
    // `--resume` opens a session in the interactive REPL; every other mode
    // would ignore it, and `--session` names a different session identity.
    if (config.resume_session != null and config.parse_error == null) {
        const other: ?[]const u8 = if (config.prompt != null)
            "-p/--print or -"
        else if (config.web_port != null)
            "--web"
        else if (config.serve_port != null)
            "serve"
        else if (config.resume_response != null)
            "--resume-response"
        else if (config.session_id != null)
            "--session"
        else if (config.teammate_name.len > 0)
            "--teammate"
        else if (config.dump_prompt)
            "--dump-prompt"
        else if (config.dump_plugins)
            "--dump-plugins"
        else
            null;
        if (other) |flag| setParseError(config, allocator, "--resume opens the interactive REPL and cannot be combined with {s}", .{flag});
    }
    // The gate without a command would arm a no-op; a lone command would run
    // nothing. Either half alone is a mistyped treatment, so fail closed.
    if ((config.check_gate or config.check_gate_observe) and config.host_check_command == null and config.parse_error == null) {
        setParseError(config, allocator, "--check-gate / --check-gate-observe requires --host-check <cmd>", .{});
    }
    if (config.check_gate_max != null and !config.check_gate and !config.check_gate_observe and config.parse_error == null) {
        setParseError(config, allocator, "--check-gate-max requires --check-gate or --check-gate-observe", .{});
    }
    // The --web-* flags shape the HTTP surface of --web and serve; without
    // either they would configure nothing.
    if ((config.web_bind != null or config.web_token != null or config.web_allow_unauth) and
        config.web_port == null and config.serve_port == null and config.parse_error == null)
    {
        setParseError(config, allocator, "--web-bind / --web-token / --web-allow-unauth require --web or serve", .{});
    }
    // The daemon flags shape `serve`; anywhere else they would configure nothing.
    if ((config.serve_sessions != null or config.serve_max_sessions != null or config.uds_path != null) and
        config.serve_port == null and config.parse_error == null)
    {
        setParseError(config, allocator, "--sessions / --max-sessions / --uds require serve", .{});
    }
    // The cap belongs to the multi-session daemon, which --sessions or --uds selects.
    if (config.serve_max_sessions != null and config.serve_sessions == null and config.uds_path == null and config.parse_error == null) {
        setParseError(config, allocator, "--max-sessions requires --sessions or --uds (the multi-session daemon)", .{});
    }
    if (config.serve_sessions) |initial| if (initial > multiSessionCap(config.*) and config.parse_error == null) {
        setParseError(config, allocator, "--sessions {d} exceeds --max-sessions {d}", .{ initial, multiSessionCap(config.*) });
    };
}

/// The multi-session daemon's live-session cap: `--max-sessions`, else the default.
fn multiSessionCap(config: types.Config) usize {
    return config.serve_max_sessions orelse daemon_serve_multi.DEFAULT_MAX_SESSIONS;
}

fn webBindHint(err: platform_net.AddressError) []const u8 {
    return switch (err) {
        error.InvalidAddress => "expected an IPv4 or IPv6 literal such as 127.0.0.1, 0.0.0.0, ::1 or :: (host names are not resolved)",
        error.ScopedAddress => "IPv6 zone ids (%interface) are not supported",
        error.Ipv4Mapped => "write the IPv4 address itself, not ::ffff:a.b.c.d",
    };
}

fn webTokenHint(err: web_server.TokenError) []const u8 {
    return switch (err) {
        error.EmptyToken => "the token is empty",
        error.TokenTooLong => std.fmt.comptimePrint("the token is longer than {d} bytes", .{web_server.MAX_TOKEN_LEN}),
        error.TokenCharset => "the token may only contain visible ASCII characters (no spaces or control bytes)",
    };
}

/// The learning-turn settings main reads from the environment; tests pass them in.
pub const LearningTurnEnv = struct {
    /// METACODES_LEARNING_TURN (`enforce` or `observe`), honoured in print mode.
    mode: ?[]const u8 = null,
    /// The end-of-run verdict source is armed: METACODES_SELF_EVOLUTION on,
    /// METACODES_HOST_CHECK pinnable and METACODES_TASK_HINT set
    /// (`host_check.endOfRunArmedFromEnv`).
    host_check_armed: bool = false,
};

/// After argument parsing: fill the learning-turn mode from
/// METACODES_LEARNING_TURN where no flag set it (print mode only; a flag
/// wins), then refuse a learning turn with no verdict source — the rule
/// `--check-gate` without `--host-check` follows. The in-run source is the
/// check gate (REPL and print mode); the end-of-run source is the
/// self-evolution host check (print mode only). Returns the message main
/// prints before exiting 2 (owned by `allocator`), or null to go on.
pub fn resolveLearningTurn(config: *types.Config, env: LearningTurnEnv, allocator: std.mem.Allocator) ?[]const u8 {
    const print_mode = config.prompt != null;
    if (!config.learning_turn and !config.learning_turn_observe and print_mode) if (env.mode) |text| {
        const mode = std.meta.stringToEnum(learning_turn.Mode, text) orelse
            return std.fmt.allocPrint(allocator, "invalid {s} '{s}' (expected enforce or observe)", .{ learning_turn.MODE_ENV, text }) catch "invalid " ++ learning_turn.MODE_ENV;
        switch (mode) {
            .enforce => config.learning_turn = true,
            .observe => config.learning_turn_observe = true,
        }
    };
    if (!config.learning_turn and !config.learning_turn_observe) return null;
    const in_run = (config.check_gate or config.check_gate_observe) and config.host_check_command != null;
    if (in_run or (print_mode and env.host_check_armed)) return null;
    return std.fmt.allocPrint(allocator, "--learning-turn / --learning-turn-observe needs a verdict source: " ++
        "--check-gate or --check-gate-observe with --host-check <cmd>, or in print mode " ++
        "METACODES_HOST_CHECK with METACODES_SELF_EVOLUTION=1 and METACODES_TASK_HINT", .{}) catch "--learning-turn needs a verdict source";
}

/// The verifier settings main reads from the environment; tests pass them in.
pub const VerifierEnv = struct {
    /// METACODES_VERIFIER (`enforce` or `observe`), honoured in print mode.
    mode: ?[]const u8 = null,
    /// The end-of-run host check is armed (`host_check.endOfRunArmedFromEnv`).
    host_check_armed: bool = false,
};

/// After argument parsing: fill the verifier mode from METACODES_VERIFIER
/// where no flag set it (print mode only; a flag wins), then refuse a
/// verifier with no pinned check to follow (verifier-only mode is out of
/// scope, design §11), `--verifier-model` without a verifier, and a verifier
/// beside the learning turn (its `contested` grounding is not implemented
/// yet, design §3.4). Returns the message main prints before exiting 2, or
/// null to go on.
pub fn resolveVerifier(config: *types.Config, env: VerifierEnv, allocator: std.mem.Allocator) ?[]const u8 {
    const print_mode = config.prompt != null;
    if (!config.verifier and !config.verifier_observe and print_mode) if (env.mode) |text| {
        const mode = std.meta.stringToEnum(isolated_verifier.Mode, text) orelse
            return std.fmt.allocPrint(allocator, "invalid {s} '{s}' (expected enforce or observe)", .{ isolated_verifier.MODE_ENV, text }) catch "invalid " ++ isolated_verifier.MODE_ENV;
        switch (mode) {
            .enforce => config.verifier = true,
            .observe => config.verifier_observe = true,
        }
    };
    if (!config.verifier and !config.verifier_observe) {
        if (config.verifier_model != null) return "--verifier-model requires --verifier or --verifier-observe";
        return null;
    }
    if (config.learning_turn or config.learning_turn_observe)
        return "--verifier / --verifier-observe cannot be combined with --learning-turn yet (doc/ISOLATED_VERIFIER_DESIGN.md §3.4)";
    const in_run = (config.check_gate or config.check_gate_observe) and config.host_check_command != null;
    if (in_run or (print_mode and env.host_check_armed)) return null;
    return std.fmt.allocPrint(allocator, "--verifier / --verifier-observe needs a pinned check to follow: " ++
        "--check-gate or --check-gate-observe with --host-check <cmd>, or in print mode " ++
        "METACODES_HOST_CHECK with METACODES_SELF_EVOLUTION=1 and METACODES_TASK_HINT", .{}) catch "--verifier needs a pinned check";
}

/// The web-surface settings main reads from the environment; tests pass them in.
pub const WebEnv = struct {
    /// METACODES_WEB_BIND.
    bind: ?[]const u8 = null,
    /// METACODES_WEB_TOKEN.
    token: ?[]const u8 = null,
};

/// #252/#253, after argument parsing and before anything starts: fill
/// `web_bind`/`web_token` from the environment where no flag set them (a flag
/// wins), validate them, and refuse a non-loopback bind without
/// authentication. Returns the message main prints before exiting 2 (owned by
/// `allocator`), or null to go on. Does nothing without --web or serve: the
/// variables configure only that surface. No message quotes the token.
pub fn resolveWebSurface(config: *types.Config, env: WebEnv, allocator: std.mem.Allocator) ?[]const u8 {
    if (config.web_port == null and config.serve_port == null) return null;
    if (config.web_bind == null) {
        if (env.bind) |text| {
            config.web_bind = platform_net.parseIpLiteral(text, 0) catch |err|
                return std.fmt.allocPrint(allocator, "invalid METACODES_WEB_BIND '{s}': {s}", .{ text, webBindHint(err) }) catch "invalid METACODES_WEB_BIND";
        }
    }
    if (config.web_token == null) {
        if (env.token) |token| {
            web_server.validateToken(token) catch |err|
                return std.fmt.allocPrint(allocator, "invalid METACODES_WEB_TOKEN: {s}", .{webTokenHint(err)}) catch "invalid METACODES_WEB_TOKEN";
            config.web_token = token;
        }
    }
    const address = config.web_bind orelse platform_net.loopback(0);
    web_server.checkExposure(address, config.web_token, config.web_allow_unauth) catch {
        // `{f}` prints host:port; the port is not chosen yet, so drop it.
        var buffer: [64]u8 = undefined;
        const host_port = std.fmt.bufPrint(&buffer, "{f}", .{address}) catch "the requested address";
        const host = host_port[0 .. std.mem.lastIndexOfScalar(u8, host_port, ':') orelse host_port.len];
        return std.fmt.allocPrint(allocator, "refusing to serve on {s} without authentication: set METACODES_WEB_TOKEN " ++
            "(preferred; a --web-token value is visible in ps) or pass --web-token, or pass --web-allow-unauth " ++
            "to let anyone who can reach the port use this session", .{host}) catch "refusing to serve on a non-loopback address without authentication";
    };
    return null;
}

/// The HTTP surface `--web`/`serve` start with: the resolved bind address on
/// `port`, the token, the operator's `--web-allow-unauth`, and the text
/// `--version` prints for `GET /health`.
fn webSurface(config: *const types.Config, port: u16, version: []const u8) web_server.Surface {
    var address = config.web_bind orelse platform_net.loopback(port);
    address.setPort(port);
    return .{
        .address = address,
        .token = config.web_token,
        .allow_unauth = config.web_allow_unauth,
        .version = version,
    };
}

/// 读 stdin 全部内容（headless `-` 模式）。EOF 即停;读错误显式报错(不把
/// EINTR/EIO 截断的部分输入当完整 prompt)。
fn readAllStdin(allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(0, chunk[0..chunk.len]);
        if (n < 0) return error.StdinReadFailed;
        if (n == 0) break;
        try buf.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    return buf.toOwnedSlice(allocator);
}

/// U8:读整个文件(--resume-response @path 用)。owned by allocator。
fn readFileAll(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return error.PathTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&pbuf), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = pfs.close(fd);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, chunk[0..chunk.len]);
        if (n <= 0) break;
        try buf.appendSlice(allocator, chunk[0..@intCast(n)]);
    }
    return buf.toOwnedSlice(allocator);
}

fn parsePermMode(s: []const u8) types.PermissionMode {
    return @import("metacodes-internal").permission.mode.parse(s);
}

/// 累加一个 \x00 分隔的列表(--add-dir / --plugin-dir 可重复)。返回新分配的串,
/// 旧串泄漏到 session arena。
fn appendNulList(allocator: std.mem.Allocator, prev: ?[]const u8, item: []const u8) ?[]const u8 {
    if (prev) |p| {
        return std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ p, item }) catch p;
    }
    return allocator.dupe(u8, item) catch item;
}

fn printHelp() void {
    dumpWrite(
        \\metacodes — embeddable agent core and coding CLI
        \\Usage: metacodes [options]
        \\  teamwork run --request-file <file> --approve --budget-usd <cap> [options]
        \\  teamwork status <id> [--json] | teamwork resume <id> --approve
        \\                        Approved SWE loop with required sandbox; teamwork --help for options
        \\  --version             Print version and build identity and exit (--json: one JSON document)
        \\  bench [open|info|list|run|prepare|setup|db] [--url <workbench>] [--no-open]
        \\                        Open Bench workbench; pick a benchmark suite, tasks and model, run evaluations.
        \\                        bench run [--suite <id>] [--executor <name>] --task <name> --wait prints the result link.
        \\                        bench setup prepares an execution machine; bench db status|import|migrate.
        \\  doctor [--json | --plain] [--strict]
        \\                        Report where ripgrep and TinyKG resolve from and whether they match this build
        \\  terminal-setup [--dry-run | --restore] [--terminal <name>] [--keybindings <file>]
        \\                        Bind Shift+Enter to a newline in Apple Terminal or VS Code (and forks),
        \\                        after a backup; --restore undoes it (terminal-setup --help for more)
        \\  mcp add <name> --url <url> | mcp add <name> -- <command> [<arg>...] | mcp remove <name>
        \\  | mcp list | mcp login <server> [--no-browser] | mcp logout <server>
        \\                        Install an MCP server in config.json (checked on the spot), list each
        \\                        server's state, OAuth login for HTTP ones; mcp --help for more
        \\  providers add <id> --base-url <url> --protocol <wire> [--model <id>]... [--probe] | providers probe <id>
        \\  | providers list | providers remove <id>
        \\                        A model API of your own (a relay, a gateway, a local server), in config.json;
        \\                        providers --help for more
        \\  update [--check] [--version X.Y.Z] [--release-base <url>] [--pull] [--allow-downgrade]
        \\         [--no-sdk] [--ignore-running] [--json]
        \\                        Bring this install up to date: the latest release (from its recorded
        \\                        mirror, if any), or a rebuild of the checkout a development install came from
        \\  -p, --print <prompt>  Headless: run one prompt and exit (no REPL)
        \\  -                     Headless: read prompt from stdin
        \\  --json                Headless: emit NDJSON result event
        \\  --stream-json         Headless: also stream per-event NDJSON lines live (text/tool/usage/turn)
        \\  --web [port]          Serve a web UI (HTTP+SSE) instead of the TUI (default port 7777)
        \\  --web-bind <addr>     --web/serve: IPv4 or IPv6 literal to bind (default 127.0.0.1; env
        \\                        METACODES_WEB_BIND). A non-loopback address needs a token or
        \\                        --web-allow-unauth
        \\  --web-token <token>   --web/serve: require 'Authorization: Bearer <token>' on every route but
        \\                        GET /health (a GET may pass ?token=). Prefer env METACODES_WEB_TOKEN:
        \\                        the flag is visible in ps
        \\  --web-allow-unauth    --web/serve: allow a non-loopback --web-bind without a token
        \\  --resume <id>         Start the REPL in a stored session of this directory (an id or id prefix, as
        \\                        /resume takes; an interactive exit prints the command for the current one)
        \\  --resume-response <j> Resume a suspended session with a late tool response (@file to read from a file)
        \\  --model <model>       Model (default: claude-sonnet-4-20250514)
        \\  --model-display-name <name>  Stable actor-visible model identity
        \\  --reasoning-effort <e> none|minimal|low|medium|high|xhigh (alias: max, the Anthropic-route name of the top level)
        \\  --temperature <f>    Override sampling temperature (dialect-gated fields)
        \\  --top-p <f>          Override nucleus sampling top_p
        \\  --prompt-cache-key <k>  Kimi K2.6 cache hint (gated by dialect capability)
        \\  --parallel-tool-calls <bool>  Mistral explicit parallel tools (dialect-gated)
        \\  --response-format <json_object|json_schema>  Structured output (dialect-gated)
        \\  --api-key <key>       API key (overrides stored credentials by default)
        \\  --permission <mode>   default | acceptEdits | auto | dontAsk | bypassPermissions
        \\  --settings <path>     Extra settings JSON (CLI layer)
        \\  --allowedTools <list> Comma-separated allow rules, e.g. "Bash(git *),Read"
        \\  --disallowedTools <l> Comma-separated deny rules
        \\  --preview             Enable every preview feature: execute_code, teamwork, comment_guard, background_watchdog, monitor_events
        \\  --no-preview          Disable every preview feature, overriding config.json
        \\  --preview=<list>      Enable the listed preview features, e.g. --preview=execute_code,teamwork
        \\  --no-preview=<list>   Disable the listed preview features
        \\  --verification-checkpoint  Enable the experimental post-test checkpoint
        \\  --verification-final-gate  Enforce the session-end verification obligation
        \\  --verification-final-observe  Record (not enforce) the session-end verification obligation
        \\  --requirement-ledger  Enforce the requirement-ledger closure obligation
        \\  --requirement-ledger-observe  Record (not enforce) the requirement ledger
        \\  --delivery-cadence    Nudge a run that keeps exploring without writing any deliverable
        \\  --delivery-cadence-observe  Record (not enforce) the delivery-cadence obligation
        \\  --delivery-cadence-thresholds <a>,<b>  Exploration-call counts for the two nudges (default 40,80)
        \\  --host-check <cmd>    Check command the host runs itself for the check gate (pinned for the process)
        \\  --check-gate          After the model changes files and stops, run --host-check; continue on a clean failure
        \\  --check-gate-observe  Run --host-check at the same points and only record the verdict
        \\  --check-gate-max <n>  Continuations the check gate may grant per run (1..8, default 3)
        \\  --harnessmm / --no-harnessmm  Preview: guarded decision reuse and callback certificates (default off)
        \\  --rsi / --no-rsi     Preview: evolved skills and learned routers (default off)
        \\  --rsi-policy <file>  Frozen RSI policy (doc/SKILL_RSI_PROTOCOL.md)
        \\  --learning-turn       After a grounded host verdict, let the model record conditioned lessons
        \\                        for the next attempt (needs --check-gate[-observe], or in print mode
        \\                        METACODES_HOST_CHECK under METACODES_SELF_EVOLUTION with METACODES_TASK_HINT)
        \\  --learning-turn-observe  Only record whether a learning turn would have run
        \\  --verifier            After the pinned check passes, let an isolated read-only verifier audit
        \\                        the work against the task statement; a reproduced FAIL continues the run
        \\                        (needs --check-gate[-observe], or in print mode the self-evolution host check)
        \\  --verifier-observe    Run the isolated verifier at the same points and only record its verdict
        \\  --verifier-model <m>  Model or tier (low/mid/high) for the verifier (default: the session model)
        \\  --test-integrity      When the model stops with tests that existed before the run rewritten,
        \\                        deleted or disabled, ask once to restore them or quote the request
        \\  --test-integrity-observe  Only record and report changes to tests that existed before the run
        \\  --stall-gate          Stop a run whose tool rounds keep returning nothing new (default in
        \\                        the REPL and web sessions; off in print mode unless given)
        \\  --stall-gate-observe  Only record where the stall gate would have stopped the run
        \\  --no-stall-gate       Never stop a run for returning nothing new
        \\  --no-progress-updates  Do not ask the model for a progress note after silent tool rounds
        \\  --progress-updates-observe  Record (not enforce) the progress-update obligation
        \\  --max-tokens <n>      Override max output tokens per request
        \\  --session <id>        Explicit session id (resume a suspended session directory)
        \\  --suspendable         Headless: suspend on UI tools (write suspend.json) instead of failing
        \\  --image <path>        Headless: attach an image (png/jpg/jpeg/gif/webp) to the prompt (repeatable, order kept)
        \\  --dump-prompt         Print the assembled system prompt and exit
        \\  --sections            With --dump-prompt: list the named prompt sections (id, order, class, digest)
        \\  --dump-plugins        Print the immutable plugin inventory JSON and exit
        \\  serve [port]          Daemon mode (HTTP; default port 7777; GET /health is an unauthenticated
        \\                        liveness probe; --web-bind/--web-token apply here too)
        \\  --sessions <n>        Daemon: multi-session mode (sessions under /s/<id>/, created and destroyed
        \\                        over POST /sessions/create and /sessions/<id>/destroy); n sessions (0 or
        \\                        more) are built at startup
        \\  --max-sessions <m>    Daemon: cap on live sessions in multi-session mode (default 32); a create
        \\                        beyond it is refused with 429
        \\  --uds <path>          Daemon: additional UDS+NDJSON binding (implies multi-session mode)
        \\  --add-dir <path>      Extra read/write directory (repeatable)
        \\  --plugin-dir <path>   Enable a manifest-based data plugin package (repeatable)
        \\  --process-plugin-dir <path>  Enable a pinned executable plugin package (repeatable)
        \\  --answers-file <path> Preset answers for permission .ask / AskUserQuestion (non-tty)
        \\  --base-url <url>      Override API endpoint (must end with /v1/messages)
        \\  --provider <id>       Provider profile id or alias (metask | openai | gemini | zai-coding-plan)
        \\  --channel <id>        Channel within the provider (e.g. cn-anthropic, global-openai)
        \\  --offer <offer-id>    Pin one exact model route (offer-...); see --provider output
        \\  --preset <name>       Use a preset from config.json "presets" (env METACODES_PRESET); --provider/--offer
        \\                        set it aside, --model/--channel/--reasoning-effort replace its field for this run
        \\  --check-providers     Validate provider configuration and list every route, then exit (no network)
        \\  --openai-protocol <p> OpenAI wire protocol: chat_completions (default; alias "chat") | responses (env METACODES_OPENAI_PROTOCOL)
        \\  --auth-precedence <p> api-key-first | oauth-first
        \\  --record <dir>        Record requests + SSE responses to dir (cassette)
        \\  --state-dir <dir>     State root for config, credentials, KG store, sessions (first
        \\                        argument to also apply to subcommands; else METACODES_HOME,
        \\                        <prefix>/etc/metacodes/install.json, ~/.metacodes)
        \\  --no-theme            Disable colors
        \\  --verbose             Verbose output
        \\  --lsp                 Enable language server integration (default; overrides an earlier --no-lsp)
        \\  --no-lsp              Disable language server integration (Edit/Write diagnostics, CodeMap,
        \\                        FindSymbol, Read outline). Servers are only started for a language
        \\                        whose server is installed, inside a git project with a build marker.
        \\  --agent-teams         Enable teams/teammates (TeamCreate/SendMessage; delegate to parallel teammate agents)
        \\  --teammate-mode <m>   Teammate spawn backend: "process" (out-of-process, worktree-isolated) or "thread" (default, in-process)
        \\  -h, --help            This help
        \\
    );
}

test "basic" {
    try std.testing.expect(true);
}

test "--resume takes a session id for the REPL and fails closed without one or beside another mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = parseArgsForTest(&[_][*:0]const u8{ "metacodes", "--resume", "000001a16627", "--model", "m" }, a);
    try std.testing.expect(ok.parse_error == null);
    try std.testing.expectEqualStrings("000001a16627", ok.resume_session.?);
    try std.testing.expectEqualStrings("m", ok.model);
    // The id resolves against the stored sessions in main, before App.init.
    try std.testing.expect(ok.session_id == null);

    const missing = [_][]const [*:0]const u8{
        &.{ "metacodes", "--resume" },
        &.{ "metacodes", "--resume", "" },
        &.{ "metacodes", "--resume", "--model", "m" },
    };
    for (missing) |argv| {
        const config = parseArgsForTest(argv, a);
        try std.testing.expectEqualStrings("missing session id for --resume", config.parse_error.?);
    }

    const Conflict = struct { argv: []const [*:0]const u8, flag: []const u8 };
    const conflicts = [_]Conflict{
        .{ .argv = &.{ "metacodes", "--resume", "x", "-p", "hi" }, .flag = "-p/--print or -" },
        .{ .argv = &.{ "metacodes", "--web", "--resume", "x" }, .flag = "--web" },
        .{ .argv = &.{ "metacodes", "serve", "--resume", "x" }, .flag = "serve" },
        .{ .argv = &.{ "metacodes", "--resume", "x", "--resume-response", "{}" }, .flag = "--resume-response" },
        .{ .argv = &.{ "metacodes", "--resume", "x", "--session", "y" }, .flag = "--session" },
        .{ .argv = &.{ "metacodes", "--resume", "x", "--agent-name", "w" }, .flag = "--teammate" },
        .{ .argv = &.{ "metacodes", "--resume", "x", "--dump-prompt" }, .flag = "--dump-prompt" },
        .{ .argv = &.{ "metacodes", "--resume", "x", "--dump-plugins" }, .flag = "--dump-plugins" },
    };
    for (conflicts) |c| {
        const config = parseArgsForTest(c.argv, a);
        const expected = try std.fmt.allocPrint(a, "--resume opens the interactive REPL and cannot be combined with {s}", .{c.flag});
        try std.testing.expectEqualStrings(expected, config.parse_error.?);
    }
}

test "Metask login dispatch uses JSON device flow except token import" {
    try std.testing.expect(metaskUsesDeviceFlow(.browser));
    try std.testing.expect(!metaskUsesDeviceFlow(.help));
    try std.testing.expect(!metaskUsesDeviceFlow(.status));
    try std.testing.expect(!metaskUsesDeviceFlow(.api_key));
    try std.testing.expect(!metaskUsesDeviceFlow(.oauth_json));
}

test "a stored Metask default takes the browser sign-in's key without the blanks around it (#485)" {
    // The variable would point the read at the developer's own auth.json.
    if (std.c.getenv(auth.AUTH_FILE_ENV) != null) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const path = try std.fs.path.joinZ(a, &.{ root, "auth.json" });

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "auth.json", .data = "{\"api_key\":\"  sk-browser-key\\n\"}" });
    _ = pfs.chmod(path.ptr, 0o600);
    try std.testing.expectEqualStrings("sk-browser-key", browserSignInKey(a, root) orelse return error.NoKey);

    // Blanks only: no key.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "auth.json", .data = "{\"api_key\":\" \\t \"}" });
    _ = pfs.chmod(path.ptr, 0o600);
    try std.testing.expect(browserSignInKey(a, root) == null);
}

test "install names the next step while the state root has neither a sign-in nor a .env (#484)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try writeInstallNextStep(&out.writer, root, "metacodes-dev");
    const env_path = try std.fs.path.join(a, &.{ root, ".env" });
    defer a.free(env_path);
    const expected = try std.fmt.allocPrint(a,
        \\  next: run `metacodes-dev` and type /login to sign in to Metask,
        \\        or put your provider key in {s} (template: .env.example), then run it
        \\
    , .{env_path});
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, out.written());

    // Signed in, or configured: nothing to say.
    for ([_][]const u8{ "auth.json", ".env" }) |name| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "{}" });
        var quiet: std.Io.Writer.Allocating = .init(a);
        defer quiet.deinit();
        try writeInstallNextStep(&quiet.writer, root, "metacodes");
        try std.testing.expectEqualStrings("", quiet.written());
        try tmp.dir.deleteFile(std.testing.io, name);
    }
}

test "the sign-in hints name the command that was run, the default sign-in first (#482)" {
    const a = std.testing.allocator;
    const cases = [_]struct { argv0: []const u8, command: []const u8 }{
        .{ .argv0 = "metacodes", .command = "metacodes" },
        .{ .argv0 = "metacodes-dev", .command = "metacodes-dev" },
        .{ .argv0 = "/Users/someone/.local/bin/metacodes-dev", .command = "metacodes-dev" },
    };
    for (cases) |case| {
        const command = invocation.commandName(a, .{ .argv0 = case.argv0 });
        try std.testing.expectEqualStrings(case.command, command);
        const login = try std.fmt.allocPrint(a, "  {s} login", .{command});
        defer a.free(login);

        const hint = try std.fmt.allocPrint(a, auth_required_hint, .{ .command = command });
        defer a.free(hint);
        // Every sign-in line but the environment variable runs this command,
        // and the first is the bare `login` a plain launch reads.
        var lines = std.mem.splitScalar(u8, hint, '\n');
        var sign_ins: usize = 0;
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "  ")) continue;
            if (std.mem.eql(u8, line, "  export METASK_API_KEY=...")) continue;
            try std.testing.expect(std.mem.startsWith(u8, line, login));
            if (sign_ins == 0) try std.testing.expectEqualStrings(login, line);
            sign_ins += 1;
        }
        try std.testing.expectEqual(@as(usize, 5), sign_ins);

        const incomplete = try std.fmt.allocPrint(a, incomplete_login_hint, .{ .command = command });
        defer a.free(incomplete);
        const run_login = try std.fmt.allocPrint(a, "Run `{s} login` in a terminal", .{command});
        defer a.free(run_login);
        try std.testing.expect(std.mem.indexOf(u8, incomplete, run_login) != null);
        try std.testing.expect(std.mem.indexOf(u8, incomplete, "select a model and reasoning effort") != null);
        try std.testing.expect(std.mem.indexOf(u8, incomplete, "API key") == null);

        const session = try std.fmt.allocPrint(a, metask_session_hint, .{ .command = command });
        defer a.free(session);
        const run_metask = try std.fmt.allocPrint(a, "run `{s} login --provider metask` to log in again", .{command});
        defer a.free(run_metask);
        try std.testing.expect(std.mem.indexOf(u8, session, run_metask) != null);
    }

    const dev = try std.fmt.allocPrint(a, auth_required_hint ++ no_token_printed, .{ .command = "metacodes-dev" });
    defer a.free(dev);
    try std.testing.expectEqualStrings(
        \\Authentication required.
        \\Use one of:
        \\  metacodes-dev login
        \\  metacodes-dev login --oauth-token-json <token-response.json>
        \\  metacodes-dev login --provider <id>
        \\  metacodes-dev login --provider <id> --oauth-token-json <token-response.json>
        \\  metacodes-dev login --api-key <key>
        \\  export METASK_API_KEY=...
        \\
        \\No token value was printed.
        \\
    , dev);
}

test {
    _ = &@import("repl/stream_json_backend.zig");
    _ = &@import("repl/teamwork.zig");
    _ = &@import("app.zig");
    _ = &@import("app/route_strings.zig");
    _ = &@import("app/mcp_startup.zig");
    _ = &@import("app/mcp_hotplug.zig");
    _ = &@import("app/install.zig");
    _ = &@import("app/invocation.zig");
    _ = &@import("app/state_env.zig");
    _ = &@import("app/route_state.zig");
    _ = &@import("app/sign_out.zig");
    _ = &@import("app/startup_order.zig");
    _ = &@import("app/presets.zig");
    _ = &@import("app/teammate_route.zig");
    _ = &@import("app/release_source.zig");
    _ = &@import("app/unit_archive.zig");
    _ = &@import("app/release_fetch.zig");
    _ = &@import("app/update.zig");
    _ = &@import("app/update_notice.zig");
    _ = &@import("app/kg_autostart.zig");
    _ = &@import("app/terminal_setup/jsonc.zig");
    _ = &@import("app/terminal_setup/files.zig");
    _ = &@import("app/terminal_setup/vscode.zig");
    _ = &@import("app/terminal_setup/apple_terminal.zig");
    _ = &@import("app/terminal_setup/setup.zig");
    _ = &@import("app/terminal_setup/cli.zig");
    _ = &@import("session_service.zig");
    _ = &@import("repl/loop.zig");
    _ = &@import("repl/replay.zig");
    _ = &@import("repl/input.zig");
    _ = &@import("repl/model_command.zig");
    _ = &@import("repl/model_picker.zig");
    _ = &@import("repl/model_picker_view.zig");
    _ = &@import("repl/picker_host.zig");
    _ = &@import("repl/msg_queue.zig");
    _ = &@import("repl/history.zig");
    _ = &@import("repl/user_echo.zig");
    _ = &@import("repl/cmd_output.zig");
    _ = &@import("repl/dialogs.zig");
    _ = &@import("repl/tui/dialog/pane.zig");
    _ = &@import("repl/multiline.zig");
    _ = &@import("repl/render.zig");
    _ = &@import("repl/headless.zig");
    _ = &@import("repl/next_step.zig");
    _ = &@import("repl/complete.zig");
    _ = &@import("repl/paste.zig");
    _ = &@import("repl/transcript_viewer.zig");
    _ = &@import("repl/vim.zig");
    _ = &@import("repl/tui/ansi.zig");
    _ = &@import("repl/tui/term.zig");
    _ = &@import("repl/tui/overlay.zig");
    _ = &@import("repl/tui/screen_mirror.zig");
    _ = &@import("repl/tui/zero_width.zig");
    _ = &@import("repl/tui/copy_select.zig");
    _ = &@import("repl/tui/theme.zig");
    _ = &@import("repl/tui/bg_probe.zig");
    _ = &@import("repl/tui/splash.zig");
    _ = &@import("repl/tui/splash_player.zig");
    _ = &@import("repl/tui/layout.zig");
    _ = &@import("repl/tui/test_capture.zig");
    _ = &@import("repl/tui/render_region.zig");
    _ = &@import("repl/tui/tui_backend.zig");
    _ = &@import("repl/tui/ui_state.zig");
    _ = &@import("repl/tui/ui.zig");
    _ = &@import("repl/tui/event.zig");
    _ = &@import("repl/tui/dialog/permission.zig");
    _ = &@import("repl/tui/widget/tool_card.zig");
    _ = &@import("repl/tui/widget/agent_tree.zig");
    _ = &@import("repl/tui/widget/thinking.zig");
    _ = &@import("repl/tui/widget/pager.zig");
    _ = &@import("repl/tui/config.zig");
    _ = &@import("app/mcp_cli.zig");
    _ = &@import("app/mcp_config_edit.zig");
    _ = &@import("app/terminal_prompt.zig");
    _ = &@import("app/providers_cli.zig");
    _ = &@import("web/backend.zig");
    _ = &@import("web/server.zig");
    _ = &@import("web/session.zig");
    _ = &@import("web/submission.zig");
    _ = &@import("daemon/registry.zig"); // U10:否则其 test 被 lazy analysis 跳过(Linus 抓的"测试从不跑")
    _ = &@import("daemon/app_driver.zig"); // U10-D:强制编译分析(否则死代码藏编译错)
    _ = &@import("daemon/serve.zig"); // U10-D
    _ = &@import("daemon/serve_multi.zig"); // U10-C:强制编译分析(否则死代码藏编译错)
    _ = &@import("daemon/uds.zig"); // U10-B:UDS+NDJSON 绑定
}
