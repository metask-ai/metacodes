const std = @import("std");
const builtin = @import("builtin");
const platform_term = @import("platform").terminal;
const pfs = @import("platform").fs;
const platform_signal = @import("platform").signal;
const types = @import("types.zig");
const client = @import("client.zig");
const app_mod = @import("app.zig");
const repl = @import("repl/loop.zig");
const auth = @import("core/auth.zig");
const api_keys_mod = @import("api/api_keys.zig");
const catalog_mod = @import("api/catalog.zig");

pub const VERSION = @import("version.zig").semver;

// Public re-exports for tests and future consumers.
pub const api_stream = @import("api/stream.zig");
pub const api_provider = @import("api/provider.zig");
pub const api_provider_factory = @import("api/provider_factory.zig");
pub const api_auth_header = @import("api/auth_header.zig");
pub const fs_util = @import("util/fs.zig");
// issue #16 provider offer kernel — re-exported for L2 component tests and for
// embedders that drive model selection through the control plane.
pub const provider_ids = @import("provider/ids.zig");
pub const provider_offer = @import("provider/offer.zig");
pub const provider_controls = @import("provider/controls.zig");
pub const provider_credential = @import("provider/credential.zig");
pub const provider_profile = @import("provider/profile.zig");
pub const provider_registry = @import("provider/registry.zig");
pub const provider_selection = @import("provider/selection.zig");
pub const provider_config_doc = @import("provider/config_doc.zig");
pub const provider_config_store = @import("provider/config_store.zig");
pub const provider_control_plane = @import("provider/control_plane.zig");
pub const provider_runtime_binding = @import("provider/runtime_binding.zig");
pub const provider_startup = @import("provider/startup.zig");
pub const provider_host = @import("provider/host.zig");
pub const provider_alias = @import("provider/alias.zig");
pub const provider_custom = @import("provider/custom_provider.zig");
pub const provider_oauth = @import("provider/oauth.zig");
pub const kg_provider_audit = @import("kg/provider_audit.zig");
pub const api_oauth_exchange = @import("api/oauth_exchange.zig");
pub const api_catalog_fetch = @import("api/catalog_fetch.zig");
pub const api_capability = @import("api/capability.zig");
pub const api_capability_activation = @import("api/capability_activation.zig");
pub const api_cache = @import("api/cache.zig");
pub const api_http_status = @import("api/http_status.zig");
pub const api_openai = @import("api/openai_client.zig");
pub const api_gemini = @import("api/gemini_client.zig");
pub const api_dialect = @import("api/dialect.zig");
pub const api_request = @import("api/request.zig");
pub const api_request_overrides = @import("api/request_overrides.zig");
pub const model_adapter = @import("api/model_adapter.zig");
pub const model_tiers = @import("api/model_tiers.zig");
pub const client_mod = client; // alias for L2 component tests
pub const task_store = @import("core/task_store.zig"); // L2 requirement-ledger tests
pub const requirement_ledger = @import("core/requirement_ledger.zig"); // L2 ledger decide tests
pub const types_mod = types;
pub const json_mod = @import("json.zig");
pub const util_abort = @import("util/abort.zig");
pub const util_fs = @import("util/fs.zig");
pub const util_file_lock = @import("util/file_lock.zig");
pub const conversation = @import("core/conversation.zig");
pub const message = @import("core/message.zig");
pub const compact_summary = @import("core/compact_summary.zig");
pub const agent_loop = @import("core/agent_loop.zig");
pub const agent_session = @import("core/agent_session.zig");
pub const execution_effect = @import("core/execution_effect.zig");
pub const run_recovery = @import("core/run_recovery.zig");
pub const plugin = @import("plugin/root.zig");
pub const tool_catalog = @import("core/tool_catalog.zig");
pub const workspace_policy = @import("core/workspace_policy.zig");
pub const core_subagent = @import("core/subagent.zig");
pub const agent_job_registry = @import("core/agent_job_registry.zig");
pub const job_registry = @import("core/job_registry.zig");
pub const util_time = @import("util/time.zig");
pub const tools = @import("tools.zig");
pub const tool_prompt_ctx = @import("tools/prompt_context.zig");
pub const task_tools = @import("tools/task_tools.zig");
pub const task_output_tool = @import("tools/task_output.zig");
pub const agent_tool = @import("tools/agent.zig");
pub const core_task_store = @import("core/task_store.zig");
pub const kg_client = @import("kg/client.zig");
pub const scoped_recall = @import("kg/scoped_recall.zig");
pub const kg_transport = @import("kg/transport.zig");
pub const swarm_team = @import("swarm/team.zig");
pub const swarm_mailbox = @import("swarm/mailbox.zig");
pub const swarm_teammate = @import("swarm/teammate.zig");
pub const swarm_context = @import("swarm/context.zig");
pub const swarm_tools = @import("swarm/tools.zig");
pub const swarm_teammate_process = @import("swarm/teammate_process.zig");
pub const tools_common = @import("tools/common.zig");
pub const platform_fs = @import("platform").fs;
pub const kg_inject = @import("kg/inject.zig");
pub const kg_scoped_recall = @import("kg/scoped_recall.zig");
pub const abort = @import("util/abort.zig");
pub const kg_plan_commit = @import("kg/plan_commit.zig");
pub const kg_plan_view = @import("kg/plan_view.zig");
pub const kg_task_projection = @import("kg/task_projection.zig");
pub const formal_runtime = @import("formal/runtime.zig");
pub const formal_artifact_store = @import("formal/artifact_store.zig");
pub const formal_provenance = @import("formal/provenance.zig");
pub const formal_task_audit = @import("formal/task_audit.zig");
pub const formal_memory_migration = @import("formal/memory_migration.zig");
pub const kg_memory_migration_adapter = @import("kg/memory_migration_adapter.zig");
pub const kg_ontology_rule_snapshot_adapter = @import("kg/ontology_rule_snapshot_adapter.zig");
pub const formal_artifact_verification = @import("formal/artifact_verification.zig");
pub const kg_tools = @import("tools/kg_tools.zig");
pub const kg_lexical_query_plan = @import("kg/lexical_query_plan.zig");
pub const core_goal = @import("core/goal.zig");
pub const core_auth = auth;
pub const core_read_state = @import("core/read_state.zig");
pub const core_edit_hl_cache = @import("core/edit_hl_cache.zig");
pub const tool_exec = @import("core/tool_exec.zig");
pub const file_change = @import("core/file_change.zig");
pub const file_reference = @import("core/file_reference.zig");
pub const output_semantics = @import("core/output_semantics.zig");
pub const message_repair = @import("core/message_repair.zig");
pub const tool_result_artifact = @import("core/tool_result_artifact.zig");
pub const tool_result = @import("core/tool_result.zig");
pub const result_projection = @import("core/result_projection.zig");
pub const pdf = @import("core/pdf.zig");
pub const tool_result_metrics = @import("core/tool_result_metrics.zig");
pub const read_artifact = @import("tools/read_artifact.zig");
pub const cache_break = @import("core/cache_break.zig");
pub const core_message = @import("core/message.zig");
pub const transcript = @import("core/transcript.zig");
pub const repl_headless = @import("repl/headless.zig");
pub const repl_loop = @import("repl/loop.zig");
pub const app_module = @import("app.zig");
pub const app_route_strings = @import("app/route_strings.zig");
pub const tool_context = @import("tools/context.zig");
pub const project_rule_gate_protocol = @import("tools/project_rule_gate.zig");
pub const tool_error = @import("core/tool_error.zig");
pub const bash = @import("tools/bash.zig");
pub const grep = @import("tools/grep.zig");
pub const glob = @import("tools/glob.zig");
pub const read_tool = @import("tools/read.zig");
pub const find_symbol_tool = @import("tools/find_symbol.zig");
pub const code_map_tool = @import("tools/code_map.zig");
pub const symbol_provider = @import("tools/symbol_provider.zig");
pub const lsp = @import("lsp/lsp.zig");
pub const write_tool = @import("tools/write.zig");
pub const edit_tool = @import("tools/edit.zig");
pub const mcp_client = @import("mcp/client.zig");
pub const mcp_protocol = @import("mcp/protocol.zig");
pub const mcp_registry_bridge = @import("mcp/registry_bridge.zig");
pub const mcp_session = @import("core/mcp_session.zig");
pub const skills = @import("skills/skill.zig");
pub const skills_runtime = @import("skills/runtime/root.zig");
pub const skills_cli_adapter = @import("skills/cli_adapter.zig");
pub const skills_tool = @import("skills/tool.zig");
pub const skills_render = @import("skills/render.zig");
pub const skills_discovery = @import("skills/discovery.zig");
pub const active_skill = @import("skills/active.zig");
pub const permission = @import("permission.zig");
pub const permission_rule_spec = @import("permission/rule_spec.zig");
pub const permission_settings = @import("permission/settings.zig");
pub const permission_decision = @import("permission/decision.zig");
pub const permission_hooks = @import("permission/hooks.zig");
pub const sandbox_profile = @import("sandbox/profile.zig");
pub const sandbox_config = @import("sandbox/config.zig"); // L2 测试构造 SandboxSettings
pub const agents_def = @import("agents/def.zig");
pub const agents_set = @import("agents/set.zig");
pub const agents_filter = @import("agents/filter.zig");
pub const agents_preload = @import("agents/preload.zig");
pub const tools_dynamic = @import("tools/dynamic.zig");
pub const tools_task_batch = @import("tools/task_batch.zig");
pub const system_prompt = @import("core/system_prompt.zig");
pub const user_context = @import("core/memory/user_context.zig");
pub const memdir = @import("core/memory/memdir.zig");
pub const util_log = @import("util/log.zig");
pub const tui_render_region = @import("repl/tui/render_region.zig");
pub const ui_event = @import("core/protocol/ui_event.zig");
pub const ui_backend = @import("core/protocol/ui_backend.zig");
pub const ui_request = @import("core/protocol/ui_request.zig");
pub const session_id = @import("core/session_id.zig");
pub const tui_backend = @import("repl/tui/tui_backend.zig");
pub const writer_backend = @import("core/writer_backend.zig");
pub const headless_backend = @import("core/headless_backend.zig");
pub const suspend_state = @import("core/suspend_state.zig");
pub const tee_backend = @import("core/tee_backend.zig");
pub const diagnostics_backend = @import("core/diagnostics_backend.zig");
pub const evaluation_backend = @import("core/evaluation_backend.zig");
pub const tool_observation_journal = @import("core/tool_observation_journal.zig");
pub const rule_impact_stats = @import("core/rule_impact_stats.zig");
pub const rule_impact_operational_observation = @import("core/rule_impact_operational_observation.zig");
pub const rule_impact_evidence = @import("core/rule_impact_evidence.zig");
pub const rule_impact_receipt = @import("core/rule_impact_receipt.zig");
pub const rule_impact_aggregate_receipt = @import("core/rule_impact_aggregate_receipt.zig");
pub const ontology_rule_projection = @import("core/ontology_rule_projection.zig");
pub const rule_author = @import("core/rule_author.zig");
pub const project_rule_evolution = @import("core/project_rule_evolution.zig");
pub const self_evolution = @import("core/self_evolution.zig");
pub const verdict = @import("core/verdict.zig");
pub const host_check = @import("core/host_check.zig");
pub const obligation_gate = @import("core/obligation_gate.zig");
pub const rule_source_receipt = @import("core/rule_source_receipt.zig");
pub const project_rule_spec = @import("core/project_rule_spec.zig");
pub const rule_candidate = @import("core/rule_candidate.zig");
pub const rule_lifecycle = @import("core/rule_lifecycle.zig");
pub const rule_build_bundle = @import("core/rule_build_bundle.zig");
pub const rule_evaluation = @import("core/rule_evaluation.zig");
pub const project_harness_runtime = @import("formal/project_harness_runtime.zig");
pub const project_rule_bundle = @import("core/project_rule_bundle.zig");
pub const project_rule_gate = @import("core/project_rule_gate.zig");
pub const project_rule_activation = @import("core/project_rule_activation.zig");
pub const repl_msg_queue = @import("repl/msg_queue.zig");
pub const web_journal = @import("web/journal.zig");
pub const web_backend = @import("web/backend.zig");
pub const web_server = @import("web/server.zig");
pub const web_session = @import("web/session.zig");
pub const session_intent = @import("session_intent.zig"); // U11:UI 中立输入意图(issue #3)
pub const session_service = @import("session_service.zig"); // U11:canonical 会话命令面 + run 装配
pub const daemon_registry = @import("daemon/registry.zig"); // U10:SessionRegistry + SessionHost
pub const daemon_app_driver = @import("daemon/app_driver.zig"); // U10-D:真 App driver
pub const daemon_serve = @import("daemon/serve.zig"); // U10-D:serve(单 session daemon MVP)
pub const core_shutdown = @import("core/shutdown.zig"); // U9:进程级停机信号
pub const tui_status_bar = @import("repl/tui/widget/status_bar.zig");
pub const tui_verbs = @import("repl/tui/verbs.zig");
pub const tui_ui_state = @import("repl/tui/ui_state.zig");
pub const tui_ui = @import("repl/tui/ui.zig");
pub const tui_event = @import("repl/tui/event.zig");
pub const tui_theme = @import("repl/tui/theme.zig");
pub const tool_card = @import("repl/tui/widget/tool_card.zig");
pub const tui_test_capture = @import("repl/tui/test_capture.zig");
pub const repl_input = @import("repl/input.zig");
pub const repl_complete = @import("repl/complete.zig");
pub const repl_model_picker = @import("repl/model_picker.zig");
pub const repl_model_picker_view = @import("repl/model_picker_view.zig");
pub const repl_picker_host = @import("repl/picker_host.zig");
pub const answer_queue = @import("core/answer_queue.zig");
pub const recorder = @import("core/recorder.zig");

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
        const cmdline_w = @import("platform").process.buildWindowsCmdline(allocator, opt_argv) catch @panic("OOM");
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
    const startup = @import("provider/startup.zig");
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
    var store = provider_config_store.Store.initHome(allocator) catch return false;
    defer store.deinit();

    var document = store.load() catch |err| {
        // Unreadable is not "absent": say so rather than quietly ignoring a
        // selection that may well be in there.
        std.debug.print(
            "warning: ~/.metacodes/config.json could not be read ({s}); " ++
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

    const outcome = provider_startup.resolveSelection(allocator, &host.registry, selection) catch {
        std.debug.print("error: out of memory while resolving the stored provider selection\n", .{});
        std.process.exit(2);
    };
    applyStartupOutcome(config, allocator, outcome);
    return true;
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
            @import("util/log.zig").info(
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
    if (std.mem.startsWith(u8, model, "gpt") or
        std.mem.startsWith(u8, model, "o1") or
        std.mem.startsWith(u8, model, "o3"))
    {
        return .openai;
    }
    if (std.mem.startsWith(u8, model, "gemini")) return .gemini;
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

    if (try maybeRunAuthCommand(init, allocator)) |code| {
        std.process.exit(code);
    }

    var config = parseArgs(init, allocator);

    if (config.parse_error) |parse_err| {
        std.debug.print("error: {s} (use --help to list supported flags)\n", .{parse_err});
        std.process.exit(2);
    }

    if (config.show_version) {
        dumpWrite("metacodes " ++ VERSION ++ "\n");
        return;
    }

    // 捕获 argv[0] 解析可执行文件目录(供 KgClient 定位 vendor/tinykg;H1)。
    // argv[0] 含 '/' 才可定位;裸命令名(PATH 启动)→ null,回落 env/dev。realpath 解 symlink。
    {
        var a0_it = argsIter(init);
        defer a0_it.deinit();
        if (a0_it.next()) |argv0| {
            if (std.mem.indexOfScalar(u8, argv0, '/') != null) {
                const z = allocator.dupeZ(u8, argv0) catch null;
                if (z) |zz| {
                    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
                    const resolved = pfs.realpath(zz.ptr, &rbuf);
                    const full = if (resolved != null) std.mem.span(resolved.?) else argv0;
                    if (std.fs.path.dirname(full)) |d| config.exe_dir = allocator.dupe(u8, d) catch null;
                }
            }
        }
    }

    // 初始化日志：读 METACODES_LOG / METACODES_LOG_FILE 环境变量
    const log = @import("util/log.zig");
    log.initFromEnv();
    if (config.verbose) log.enableVerbose();

    // --- env fallback:base_url / record_dir(CLI flag 优先,env 兜底)---
    if (config.base_url == null) {
        if (std.c.getenv("METACODES_BASE_URL")) |c| config.base_url = std.mem.span(c);
    }
    if (std.c.getenv("METACODES_AUTH_PRECEDENCE")) |c| {
        if (auth.parsePrecedence(std.mem.span(c))) |p| config.auth_precedence = p;
    }
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

    // --- provider 选择 ---
    // issue #16:命名一个 provider profile 时走 registry 解析出**真实路由**
    // (endpoint + 协议 + wire model id + auth scheme),不再靠 model 名前缀猜。
    // 没命名 provider 的会话保持历史推断路径,行为零变化。
    if (config.provider_profile == null) {
        if (std.c.getenv("METACODES_PROVIDER")) |c| config.provider_profile = std.mem.span(c);
    }
    if (config.provider_profile) |profile_name| {
        applyProviderRoute(&config, allocator, profile_name);
    } else if (config.provider_offer != null) {
        // An offer id names its own provider; requiring `--provider` beside it
        // would make a copied offer id unusable on its own.
        applyProviderRoute(&config, allocator, null);
    } else if (!applyPersistedGlobalSelection(&config, allocator)) {
        config.provider_kind = inferProviderKind(config.model);
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
    const interactive_tui = config.serve_port == null and config.web_port == null and
        config.resume_response == null and config.prompt == null and
        config.teammate_name.len == 0 and !config.dump_prompt and !config.dump_plugins;
    if (interactive_tui and !config.verbose and platform_term.isatty(2)) {
        log.setStderrEnabled(false);
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
    var provider_secret: ?[]u8 = null;
    if (!introspection_only and !metask_scope) {
        provider_secret = try resolveProviderScopedSecret(
            allocator,
            config,
            config.provider_profile.?,
        );
    }
    // Same handling as `ResolvedCredential.deinit`: zero the bytes before
    // returning them to the allocator so key material does not linger in freed
    // heap or a core dump.
    defer if (provider_secret) |secret| {
        std.crypto.secureZero(u8, secret);
        allocator.free(secret);
    };

    var resolved_credential: ?auth.ResolvedCredential = null;
    if (!introspection_only and provider_secret == null) {
        resolved_credential = auth.resolveRuntimeCredential(allocator, config.api_key, config.auth_precedence) catch |err| {
            @import("util/log.zig").err("auth", "credential resolution failed: {s}", .{@errorName(err)});
            std.debug.print(
                \\Authentication required.
                \\Use one of:
                \\  metacodes login --oauth-token-json <token-response.json>
                \\  metacodes login --provider <id> --oauth-token-json <token-response.json>
                \\  metacodes login --api-key <key>
                \\  export METASK_API_KEY=...
                \\
                \\No token value was printed.
                \\
            , .{});
            return err;
        };
    }
    defer if (resolved_credential) |*credential| credential.deinit(allocator);
    const api_key = if (provider_secret) |secret|
        @as([]const u8, secret)
    else if (resolved_credential) |credential|
        @as([]const u8, credential.bearer_token)
    else
        "";

    // The stored Metask login carries a Metask model and reasoning effort;
    // applying it to another provider's route would silently replace the
    // selected model.
    if (metask_scope) {
        applyStoredLoginSelection(allocator, &config) catch |err| {
            log.debug("auth", "stored model selection unavailable: {s}", .{@errorName(err)});
        };
    }
    if (metask_scope) if (resolved_credential) |credential| if (!isUsableConfiguredSession(config, credential.source)) {
        std.debug.print(
            \\Metask login is incomplete.
            \\Run `metacodes login` in a terminal and select an API key, model, and reasoning effort.
            \\Use --model and --reasoning-effort only when intentionally overriding the saved selection.
            \\
        , .{});
        return error.IncompleteLoginSelection;
    };

    const app = try app_mod.App.init(allocator, init.io, config, api_key);
    defer app.deinit();

    try app.installSigintHandler();

    log.info("main", "metacodes starting; model={s}", .{config.model});

    // --dump-prompt：打印组装好的 system prompt + 工具 defs(name + description)后退出。
    // 不发网络、不需有效 key。用于验证提示词×工具复刻(工具长描述 + 动态裁剪)。
    if (config.dump_prompt) {
        dumpPromptAndExit(app);
    }
    if (config.dump_plugins) {
        dumpPluginsAndExit(app);
    }

    // SW6 进程外 teammate 模式:`--teammate --agent-name X --team-name Y` → 跑 mailbox 消息循环,
    // 不进 TUI REPL。身份经 CLI args 注入,可 chdir 进 worktree(cwd 隔离)。
    if (config.teammate_name.len > 0) {
        const code = @import("swarm/teammate_process.zig").run(app, allocator, .{
            .name = config.teammate_name,
            .team = config.teammate_team,
            .parent_session = config.teammate_parent_session,
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

    // U10-D:`serve [port]` daemon 模式 → 经 registry/host/app_driver 跑 session,SIGINT 优雅关停。
    // --sessions N>1 → serveMulti(N 个独立 session,WebServer resolver 按 /s/<id>/* 路由,U10-C)。
    if (config.serve_port) |port| {
        // serve-multi 路径:N>1(多 session)或设了 --uds(附加 UDS 绑定,即便 N=1)。
        if (config.serve_sessions > 1 or config.uds_path != null) {
            const code = @import("daemon/serve_multi.zig").serveMulti(app, allocator, config, api_key, port, config.serve_sessions, config.uds_path) catch |err| blk: {
                log.err("daemon", "serve-multi failed: {s}", .{@errorName(err)});
                break :blk @as(u8, 1);
            };
            std.process.exit(code);
        }
        const code = @import("daemon/serve.zig").serve(app, allocator, port) catch |err| blk: {
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
        const code = @import("web/session.zig").run(app, allocator, port) catch |err| blk: {
            log.err("web", "web session failed: {s}", .{@errorName(err)});
            break :blk 1;
        };
        // 同 serve:exit 前显式 deinit,reap MCP/LSP 子进程。run() 返回时连接线程已 drain,安全。
        app.deinit();
        std.process.exit(code);
    }

    // U8:`--resume-response <json>` → 恢复挂起的 session(read suspend.json→resumeRun),不进 REPL。
    if (config.resume_response) |resp| {
        const code = @import("repl/headless.zig").resumeSuspended(app, allocator, resp, config.json_output) catch |err| blk: {
            std.debug.print("error: headless resume setup failed: {s}\n", .{@errorName(err)});
            break :blk 1;
        };
        app.deinit(); // 同上:reap MCP/LSP 子进程(恢复运行已结束,quiescent)
        std.process.exit(code);
    }

    // Headless 模式：`-p "..."` / stdin pipe → 跑单次 prompt 后退出，不进 REPL。
    if (config.prompt) |p| {
        const code = @import("repl/headless.zig").run(app, allocator, p, config.images, config.documents, config.json_output) catch |err| blk: {
            std.debug.print("error: headless setup failed: {s}\n", .{@errorName(err)});
            break :blk 1;
        };
        app.deinit(); // 同上:headless 一样跑 MCP/LSP,同款孤儿病(agent loop 已结束,quiescent)
        std.process.exit(code);
    }

    // (stderr 日志 gate 已提前到 App.init 之前——见 interactive_tui;init 期日志同样不得上屏。)
    try repl.run(app, allocator);
}

/// 打印组装好的 system prompt + 工具 defs(name + 完整 description),然后退出。
/// 走 std.c.write(1,...) 直出 stdout——不经日志(避免 8192 截断),不发网络。
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

fn dumpPluginsAndExit(app: *app_mod.App) noreturn {
    const inventory = app.describePlugins(app.allocator) catch {
        dumpWrite("{\"error\":\"plugin inventory unavailable\"}\n");
        std.process.exit(1);
    };
    dumpWrite(inventory);
    dumpWrite("\n");
    std.process.exit(0);
}

fn maybeRunAuthCommand(init: std.process.Init, allocator: std.mem.Allocator) !?u8 {
    var args = argsIter(init);
    defer args.deinit();
    _ = args.next(); // 跳过 argv[0](程序名)
    const cmd = args.next() orelse return null;
    if (std.mem.eql(u8, cmd, "logout")) {
        if (args.next()) |extra| {
            std.debug.print("error: unknown logout argument '{s}'\n", .{extra});
            return 2;
        }
        auth.clearDefault(allocator) catch |err| switch (err) {
            error.NoHome => {
                std.debug.print("No HOME set; no credentials cleared.\n", .{});
                return 1;
            },
            else => {
                std.debug.print("Logout failed: {s}\n", .{@errorName(err)});
                return 1;
            },
        };
        std.debug.print("Logged out. Local credentials cleared.\n", .{});
        return 0;
    }
    if (!std.mem.eql(u8, cmd, "login")) return null;

    var mode: enum { browser, help, status, api_key, oauth_json } = .browser;
    var value: ?[]const u8 = null;
    // `--provider <id>` stores the token against that provider's own OAuth
    // session instead of the Metask credential store, which is what keeps a
    // token for one vendor from ever satisfying another.
    var provider_name: ?[]const u8 = null;
    var open_browser = true;
    while (args.next()) |arg| {
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
                std.debug.print("usage: metacodes login --provider <id> --oauth-token-json <file>\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--no-browser")) {
            mode = .browser;
            open_browser = false;
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

    if (provider_name) |name| {
        if (mode != .oauth_json) {
            std.debug.print(
                "login --provider currently accepts only --oauth-token-json; " ++
                    "the interactive flow is Metask-only\n",
                .{},
            );
            return 2;
        }
        return storeProviderOAuthToken(allocator, name, value.?);
    }

    switch (mode) {
        .browser => {
            var imported = auth.loginWithBrowser(allocator, .{ .open_browser = open_browser }) catch |err| {
                std.debug.print("OAuth browser login failed: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer imported.deinit(allocator);
            var stored = auth.loadDefault(allocator) catch |err| switch (err) {
                error.NotFound, error.NoHome => auth.StoredCredentials{},
                else => {
                    std.debug.print("Could not read existing credentials: {s}\n", .{@errorName(err)});
                    return 1;
                },
            };
            defer stored.deinit(allocator);
            if (stored.oauth) |*old| {
                old.deinit(allocator);
                stored.oauth = null;
            }
            stored.oauth = imported.oauth;
            imported.oauth = null;
            runLoginSelectionWizard(allocator, init.io, &stored) catch |err| {
                std.debug.print("Login setup failed after OAuth: {s}\n", .{@errorName(err)});
                return 1;
            };
            try auth.saveDefault(allocator, stored);
            std.debug.print("Successfully logged in with Metask OAuth. API key, model, and reasoning effort were selected. Secrets were not printed.\n", .{});
            return 0;
        },
        .help => {
            printLoginHelp();
            return 0;
        },
        .status => {
            try printLoginStatus(allocator);
            return 0;
        },
        .api_key => {
            const k = std.mem.trim(u8, value.?, " \t\r\n");
            if (k.len == 0) {
                std.debug.print("Refusing to store an empty API key.\n", .{});
                return 2;
            }
            var stored = auth.loadDefault(allocator) catch |err| switch (err) {
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
            try auth.saveDefault(allocator, stored);
            std.debug.print("Stored Metask API key. Model and reasoning effort were selected. Token value was not printed.\n", .{});
            return 0;
        },
        .oauth_json => {
            const body = try readFileArg(allocator, value.?);
            defer allocator.free(body);
            var imported = auth.importOAuthTokenResponse(allocator, body, @import("util/time.zig").nowUnix()) catch |err| {
                std.debug.print("OAuth token import failed: {s}\n", .{@errorName(err)});
                return 1;
            };
            defer imported.deinit(allocator);
            var stored = auth.loadDefault(allocator) catch |err| switch (err) {
                error.NotFound, error.NoHome => auth.StoredCredentials{},
                else => {
                    std.debug.print("Could not read existing credentials: {s}\n", .{@errorName(err)});
                    return 1;
                },
            };
            defer stored.deinit(allocator);
            if (stored.oauth) |*old| {
                old.deinit(allocator);
                stored.oauth = null;
            }
            stored.oauth = imported.oauth;
            imported.oauth = null;
            runLoginSelectionWizard(allocator, init.io, &stored) catch |err| {
                std.debug.print("Login setup failed after OAuth import: {s}\n", .{@errorName(err)});
                return 1;
            };
            try auth.saveDefault(allocator, stored);
            std.debug.print("Stored Metask OAuth credentials. API key, model, and reasoning effort were selected. Secrets were not printed.\n", .{});
            return 0;
        },
    }
}

fn printLoginHelp() void {
    std.debug.print(
        \\Usage:
        \\  metacodes login
        \\  metacodes login --no-browser
        \\  metacodes login status
        \\  metacodes login --oauth-token-json <token-response.json>
        \\  metacodes login --provider <id> --oauth-token-json <token-response.json>
        \\  metacodes login --api-key <key>
        \\  metacodes logout
        \\
        \\Default login starts a local browser OAuth flow on /auth/callback.
        \\Use --no-browser to print the URL without launching a browser.
        \\OAuth token JSON must match the Metask token endpoint response:
        \\access_token, refresh_token, token_type=Bearer, expires_in.
        \\Secrets are stored in ~/.metacodes/auth.json with 0600 permissions.
        \\
    , .{});
}

fn runLoginSelectionWizard(allocator: std.mem.Allocator, io: std.Io, stored: *auth.StoredCredentials) !void {
    try requireInteractiveLogin();
    const oauth_cred = &(stored.oauth orelse return error.MissingOAuth);
    const messages_url = loginMessagesUrl();
    var keys = api_keys_mod.Catalog.init(allocator);
    defer keys.deinit();
    try api_keys_mod.fetchInto(&keys, allocator, io, messages_url, oauth_cred.access_token);
    if (keys.entries.items.len == 0) return error.NoApiKeys;

    std.debug.print("\nSelect API key / model group:\n", .{});
    for (keys.entries.items, 0..) |entry, i| {
        std.debug.print("  {d}. {s}", .{ i + 1, entry.label });
        if (entry.group.len > 0) std.debug.print(" [{s}]", .{entry.group});
        std.debug.print(" (...{s})\n", .{entry.suffix});
    }
    const key_idx = try promptChoice(allocator, keys.entries.items.len);
    const selected = keys.entries.items[key_idx];
    replaceStoredApiKey(allocator, stored, selected.secret) catch return error.OutOfMemory;
    try runModelSelectionForStoredApiKey(allocator, io, stored);
}

fn runModelSelectionForStoredApiKey(allocator: std.mem.Allocator, io: std.Io, stored: *auth.StoredCredentials) !void {
    try requireInteractiveLogin();
    const key = stored.api_key orelse return error.MissingCredentials;
    var c = client.Client.initWithBaseUrl(allocator, io, key, "model-selection", loginMessagesUrl());
    defer c.deinit();
    c.probeModels();
    if (c.catalog.entries.items.len == 0) return error.NoModels;

    std.debug.print("\nSelect model:\n", .{});
    for (c.catalog.entries.items, 0..) |entry, i| {
        std.debug.print("  {d}. {s}", .{ i + 1, entry.model_id });
        if (entry.max_input_tokens) |ctx| std.debug.print(" ctx={d}", .{ctx});
        if (entry.max_tokens) |out| std.debug.print(" out={d}", .{out});
        std.debug.print("\n", .{});
    }
    const model_idx = try promptChoice(allocator, c.catalog.entries.items.len);
    const model = c.catalog.entries.items[model_idx];
    if (stored.selected_model) |old| allocator.free(old);
    stored.selected_model = try allocator.dupe(u8, model.model_id);

    var effort_buf: [5]types.ReasoningEffort = undefined;
    const efforts = reasoningOptionsForMask(model.reasoning_mask, &effort_buf);
    std.debug.print("\nSelect reasoning effort:\n", .{});
    for (efforts, 0..) |effort, i| {
        std.debug.print("  {d}. {s}\n", .{ i + 1, effort.name() });
    }
    const effort_idx = try promptChoice(allocator, efforts.len);
    stored.reasoning_effort = efforts[effort_idx];
}

fn loginMessagesUrl() []const u8 {
    if (std.c.getenv("METACODES_BASE_URL")) |u| return std.mem.span(u);
    return client.ANTHROPIC_API_URL;
}

fn replaceStoredApiKey(allocator: std.mem.Allocator, stored: *auth.StoredCredentials, key: []const u8) !void {
    if (stored.api_key) |old| {
        @memset(old, 0);
        allocator.free(old);
    }
    stored.api_key = try allocator.dupe(u8, key);
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

fn readLine(buf: []u8) !usize {
    var len: usize = 0;
    while (len < buf.len) {
        var ch: [1]u8 = undefined;
        const n = pfs.read(0, ch[0..1]);
        if (n < 0) return error.InputFailed;
        if (n == 0) break;
        if (ch[0] == '\n' or ch[0] == '\r') break;
        buf[len] = ch[0];
        len += 1;
    }
    return len;
}

fn reasoningOptionsForMask(mask: u8, buf: *[5]types.ReasoningEffort) []const types.ReasoningEffort {
    const ordered = [_]types.ReasoningEffort{ .low, .medium, .high, .xhigh };
    buf[0] = .none;
    var n: usize = 1;
    for (ordered) |effort| {
        if ((mask & catalog_mod.reasoningBit(effort)) != 0) {
            buf[n] = effort;
            n += 1;
        }
    }
    return buf[0..n];
}

fn printLoginStatus(allocator: std.mem.Allocator) !void {
    const path = auth.authFilePath(allocator) catch |err| {
        std.debug.print("No credential file path: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(path);
    var stored = auth.loadFromPath(allocator, path) catch |err| switch (err) {
        error.NotFound => {
            std.debug.print("Not logged in. Credential file: {s}\n", .{path});
            if (std.c.getenv(auth.METASK_API_KEY_ENV) != null) {
                std.debug.print("METASK_API_KEY override is set.\n", .{});
            }
            return;
        },
        else => {
            std.debug.print("Credential status unavailable: {s}\n", .{@errorName(err)});
            return;
        },
    };
    defer stored.deinit(allocator);
    std.debug.print("Credential file: {s}\n", .{path});
    if (stored.oauth) |o| {
        std.debug.print("Stored OAuth: yes (expires_at={d}", .{o.expires_at});
        if (o.account_id != null) std.debug.print(", account_id set", .{});
        if (o.profile != null) std.debug.print(", profile set", .{});
        std.debug.print(")\n", .{});
    } else {
        std.debug.print("Stored OAuth: no\n", .{});
    }
    std.debug.print("Stored API key: {s}\n", .{if (stored.api_key != null) "yes" else "no"});
    std.debug.print("Selected model: {s}\n", .{stored.selected_model orelse "no"});
    std.debug.print("Reasoning effort: {s}\n", .{if (stored.reasoning_effort) |e| e.name() else "no"});
    if (std.c.getenv(auth.METASK_API_KEY_ENV) != null) {
        std.debug.print("METASK_API_KEY override is set and wins unless --auth-precedence oauth-first is used.\n", .{});
    }
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
    var stored = auth.loadDefault(allocator) catch |err| switch (err) {
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
///
/// Metask keeps the historical credential path — stored OAuth, stored API key,
/// and the one-shot runtime descriptor — byte for byte. Every other profile is
/// resolved in its own scope, so a Metask token can never authenticate it.
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
) u8 {
    // The same runtime a session builds, so a provider defined in the config —
    // or one that came from a catalog — can be logged into by name.
    const host = buildProviderHost(allocator) orelse return 2;
    defer host.destroy();

    const built = host.registry.find(provider_name) orelse {
        std.debug.print("error: unknown provider '{s}'\n", .{provider_name});
        return 2;
    };
    if (built.oauth_token_url == null) {
        std.debug.print(
            "error: provider '{s}' declares no OAuth token endpoint\n",
            .{built.id.slice()},
        );
        return 2;
    }

    const text = readFileArg(allocator, path) catch |err| {
        std.debug.print("error: could not read {s}: {s}\n", .{ path, @errorName(err) });
        return 2;
    };
    defer {
        std.crypto.secureZero(u8, text);
        allocator.free(text);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const outcome = provider_oauth.parseTokenResponse(arena.allocator(), text) catch |err| {
        std.debug.print("error: {s} is not a token response ({s})\n", .{ path, @errorName(err) });
        return 2;
    };
    if (outcome.refresh_token == null) {
        std.debug.print("error: the token response carries no refresh_token; it could never be refreshed\n", .{});
        return 2;
    }

    var session = provider_oauth.Session.initHome(allocator, built.id) catch |err| {
        std.debug.print("error: could not open the OAuth store ({s})\n", .{@errorName(err)});
        return 2;
    };
    defer session.deinit();

    session.importOutcome(outcome, @import("util/time.zig").nowUnix()) catch |err| {
        std.debug.print("error: could not store the token ({s})\n", .{@errorName(err)});
        return 2;
    };
    std.debug.print(
        "Stored an OAuth login for provider '{s}'. No secret was printed.\n",
        .{built.id.slice()},
    );
    return 0;
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
    var store = provider_config_store.Store.initHome(allocator) catch return host;
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
                "warning: part of ~/.metacodes/config.json did not apply ({s}); " ++
                    "run `metacodes --check-providers` for details\n",
                .{why},
            );
        }
    }
    return host;
}

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
    var store = provider_config_store.Store.initHome(allocator) catch null;
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
    const credential_mod = provider_credential;
    const provider_ids_mod = provider_ids;
    const host = buildProviderHost(allocator) orelse return error.UnknownProviderProfile;
    defer host.destroy();
    const profile = host.registry.find(profile_name) orelse return error.UnknownProviderProfile;

    var reference_buffer: [provider_ids_mod.MAX_SLUG_LEN]u8 = undefined;
    const resolved = credential_mod.resolve(.{
        .provider_id = profile.id,
        .accepted_kinds = profile.accepted_credential_kinds,
        .env_aliases = profile.env_aliases,
        .cli_api_key = config.api_key,
        .env = credential_mod.EnvLookup.process(),
    }, &reference_buffer) catch |err| {
        printProviderCredentialHelp(profile.*, err);
        return err;
    };
    return allocator.dupe(u8, resolved.secret);
}

fn printProviderCredentialHelp(
    profile: @import("provider/profile.zig").ProviderProfile,
    err: anyerror,
) void {
    switch (err) {
        error.AmbiguousCredentialAliases => {
            std.debug.print(
                "Conflicting credentials for provider '{s}'.\n" ++
                    "Several accepted environment variables hold different values; unset all but one.\n" ++
                    "No token value was printed.\n",
                .{profile.id.slice()},
            );
        },
        else => {
            std.debug.print(
                "Authentication required for provider '{s}'.\n",
                .{profile.id.slice()},
            );
            for (profile.accepted_credential_kinds) |kind| {
                if (profile.canonicalEnvAlias(kind)) |canonical| {
                    std.debug.print("  export {s}=...\n", .{canonical});
                }
            }
            std.debug.print("  metacodes --api-key <key> --provider {s} ...\n", .{profile.id.slice()});
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
            config.permission_mode = @import("permission/mode.zig").parseStrict(m) orelse {
                setParseError(config, allocator, "invalid permission mode '{s}'", .{m});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--settings")) {
            if (args.next()) |s| config.settings_path = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--allowedTools") or std.mem.eql(u8, arg, "--allowed-tools")) {
            if (args.next()) |s| config.allowed_tools = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--disallowedTools") or std.mem.eql(u8, arg, "--disallowed-tools")) {
            if (args.next()) |s| config.disallowed_tools = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--verification-checkpoint")) {
            config.verification_checkpoint = true;
        } else if (std.mem.eql(u8, arg, "--verification-final-gate")) {
            config.verification_final_gate = true;
        } else if (std.mem.eql(u8, arg, "--verification-final-observe")) {
            config.verification_final_observe = true;
        } else if (std.mem.eql(u8, arg, "--requirement-ledger")) {
            config.requirement_ledger = true;
        } else if (std.mem.eql(u8, arg, "--requirement-ledger-observe")) {
            config.requirement_ledger_observe = true;
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
        } else if (std.mem.eql(u8, arg, "--pdf")) {
            // headless 文档输入(issue #25):可重复,顺序保留。路径在 headless.run
            // 读取并做 PDF 准入(真 PDF / 未加密 / 字节与页数上限),这里只收集。
            const s = args.next() orelse {
                setParseError(config, allocator, "missing value for --pdf", .{});
                return;
            };
            config.documents = appendNulList(allocator, config.documents, s);
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
        } else if (std.mem.eql(u8, arg, "--teammate-cwd")) {
            if (args.next()) |v| config.teammate_cwd = allocator.dupe(u8, v) catch v;
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
            // U10-C:daemon 静态 session 数(>1 → serveMulti)。
            if (args.next()) |v| {
                config.serve_sessions = std.fmt.parseInt(usize, v, 10) catch 1;
                if (config.serve_sessions < 1) config.serve_sessions = 1;
            }
        } else if (std.mem.eql(u8, arg, "--uds")) {
            // U10-B:daemon 附加 UDS+NDJSON 绑定(路径)。设置即启用(强制走 serveMulti)。
            if (args.next()) |v| config.uds_path = allocator.dupe(u8, v) catch null;
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
                        std.debug.print("error: 读 --resume-response 文件失败: {s}\n", .{@errorName(e)});
                        break :blk null;
                    };
                } else {
                    config.resume_response = allocator.dupe(u8, v) catch v;
                }
            }
        } else if (std.mem.eql(u8, arg, "--dump-prompt")) {
            config.dump_prompt = true;
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
    if (config.documents != null and config.prompt == null and config.parse_error == null) {
        setParseError(config, allocator, "--pdf requires -p/--print (headless prompt mode)", .{});
    }
    if (config.images != null and config.prompt == null and config.parse_error == null) {
        setParseError(config, allocator, "--image requires -p/--print (headless prompt mode)", .{});
    }
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
    return @import("permission/mode.zig").parse(s);
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
    std.debug.print(
        \\metacodes — embeddable agent core and coding CLI
        \\Usage: metacodes [options]
        \\  --version             Print version and exit
        \\  -p, --print <prompt>  Headless: run one prompt and exit (no REPL)
        \\  -                     Headless: read prompt from stdin
        \\  --json                Headless: emit NDJSON result event
        \\  --stream-json         Headless: also stream per-event NDJSON lines live (text/tool/usage/turn)
        \\  --web [port]          Serve a web UI (HTTP+SSE) instead of the TUI (default port 7777)
        \\  --resume-response <j> Resume a suspended session with a late tool response (@file to read from a file)
        \\  --model <model>       Model (default: claude-sonnet-4-20250514)
        \\  --model-display-name <name>  Stable actor-visible model identity
        \\  --reasoning-effort <e> none|minimal|low|medium|high|xhigh
        \\  --temperature <f>    Override sampling temperature (dialect-gated fields)
        \\  --top-p <f>          Override nucleus sampling top_p
        \\  --prompt-cache-key <k>  Kimi K2.6 cache hint (gated by dialect capability)
        \\  --parallel-tool-calls <bool>  Mistral explicit parallel tools (dialect-gated)
        \\  --response-format <json_object|json_schema>  Structured output (dialect-gated)
        \\  --api-key <key>       API key (overrides stored credentials by default)
        \\  --permission <mode>   default | acceptEdits | plan | auto | dontAsk | bypassPermissions
        \\  --settings <path>     Extra settings JSON (CLI layer)
        \\  --allowedTools <list> Comma-separated allow rules, e.g. "Bash(git *),Read"
        \\  --disallowedTools <l> Comma-separated deny rules
        \\  --verification-checkpoint  Enable the experimental post-test checkpoint
        \\  --verification-final-gate  Enforce the session-end verification obligation
        \\  --verification-final-observe  Record (not enforce) the session-end verification obligation
        \\  --requirement-ledger  Enforce the requirement-ledger closure obligation
        \\  --requirement-ledger-observe  Record (not enforce) the requirement ledger
        \\  --max-tokens <n>      Override max output tokens per request
        \\  --session <id>        Explicit session id (resume a suspended session directory)
        \\  --suspendable         Headless: suspend on UI tools (write suspend.json) instead of failing
        \\  --image <path>        Headless: attach an image (png/jpg/jpeg/gif/webp) to the prompt (repeatable, order kept)
        \\  --pdf <path>          Headless: attach a PDF document to the prompt (repeatable, order kept; needs a model with pdf_input)
        \\  --dump-prompt         Print the assembled system prompt and exit
        \\  --dump-plugins        Print the immutable plugin inventory JSON and exit
        \\  serve [port]          Daemon mode (HTTP; default port 7777)
        \\  --sessions <n>        Daemon: static session count (>1 enables multi-session)
        \\  --uds <path>          Daemon: additional UDS+NDJSON binding
        \\  --add-dir <path>      Extra read/write directory (repeatable)
        \\  --plugin-dir <path>   Enable a manifest-based data plugin package (repeatable)
        \\  --process-plugin-dir <path>  Enable a pinned executable plugin package (repeatable)
        \\  --answers-file <path> Preset answers for permission .ask / AskUserQuestion (non-tty)
        \\  --base-url <url>      Override API endpoint (must end with /v1/messages)
        \\  --provider <id>       Provider profile id or alias (metask | openai | gemini | zai-coding-plan)
        \\  --channel <id>        Channel within the provider (e.g. cn-anthropic, global-openai)
        \\  --offer <offer-id>    Pin one exact model route (offer-...); see --provider output
        \\  --check-providers     Validate provider configuration and list every route, then exit (no network)
        \\  --openai-protocol <p> OpenAI wire protocol: chat_completions (default; alias "chat") | responses (env METACODES_OPENAI_PROTOCOL)
        \\  --auth-precedence <p> api-key-first | oauth-first
        \\  --record <dir>        Record requests + SSE responses to dir (cassette)
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
    , .{});
}

test "basic" {
    try std.testing.expect(true);
}

test {
    _ = &@import("json.zig");
    _ = &@import("client.zig");
    _ = &@import("tools.zig");
    _ = &@import("symbols/symbol.zig");
    _ = &@import("tools/symbol_provider.zig");
    _ = &@import("core/edit_hl_cache.zig");
    _ = &@import("core/goal.zig");
    _ = &@import("core/auth.zig");
    _ = &@import("permission.zig");
    _ = &@import("permission/rule_spec.zig");
    _ = &@import("permission/bash_parser.zig");
    _ = &@import("permission/settings.zig");
    _ = &@import("permission/loader.zig");
    _ = &@import("permission/hooks.zig");
    _ = &@import("permission/settings_writer.zig");
    _ = &@import("sandbox/profile.zig");
    _ = &@import("sandbox/config.zig");
    _ = &@import("sandbox/exec.zig");
    _ = &@import("core/message.zig");
    _ = &@import("core/conversation.zig");
    _ = &@import("core/agent_loop.zig");
    _ = &@import("repl/stream_json_backend.zig");
    _ = &@import("core/verdict.zig");
    _ = &@import("core/host_check.zig");
    _ = &@import("core/proposed_plan.zig");
    _ = &@import("core/plan_file.zig");
    _ = &@import("swarm/team.zig");
    _ = &@import("swarm/mailbox.zig");
    _ = &@import("swarm/teammate.zig");
    _ = &@import("swarm/context.zig");
    _ = &@import("swarm/tools.zig");
    _ = &@import("swarm/teammate_process.zig");
    _ = &@import("core/memory/import.zig");
    _ = &@import("core/memory/claudemd.zig");
    _ = &@import("core/memory/user_context.zig");
    _ = &@import("core/memory/memdir.zig");
    _ = &@import("core/memory/memory_section.zig");
    _ = &@import("app.zig");
    _ = &@import("app/route_strings.zig");
    _ = &@import("session_service.zig");
    _ = &@import("repl/loop.zig");
    _ = &@import("util/abort.zig");
    _ = &@import("util/file_lock.zig");
    _ = &@import("util/toolchain.zig");
    _ = &@import("util/log.zig");
    _ = &@import("util/model.zig");
    _ = &@import("util/path.zig");
    _ = &@import("api/catalog.zig");
    _ = &@import("tools/context.zig");
    _ = &@import("repl/input.zig");
    _ = &@import("repl/model_command.zig");
    _ = &@import("repl/model_picker.zig");
    _ = &@import("repl/model_picker_view.zig");
    _ = &@import("repl/picker_host.zig");
    _ = &@import("provider/host.zig");
    _ = &@import("provider/alias.zig");
    _ = &@import("provider/custom_provider.zig");
    _ = &@import("provider/oauth.zig");
    _ = &@import("kg/provider_audit.zig");
    _ = &@import("api/oauth_exchange.zig");
    _ = &@import("api/catalog_fetch.zig");
    _ = &@import("repl/msg_queue.zig");
    _ = &@import("repl/history.zig");
    _ = &@import("repl/multiline.zig");
    _ = &@import("repl/render.zig");
    _ = &@import("repl/headless.zig");
    _ = &@import("repl/complete.zig");
    _ = &@import("repl/paste.zig");
    _ = &@import("repl/transcript_viewer.zig");
    _ = &@import("repl/vim.zig");
    _ = &@import("repl/tui/ansi.zig");
    _ = &@import("repl/tui/term.zig");
    _ = &@import("repl/tui/overlay.zig");
    _ = &@import("repl/tui/theme.zig");
    _ = &@import("repl/tui/bg_probe.zig");
    _ = &@import("repl/tui/layout.zig");
    _ = &@import("repl/tui/test_capture.zig");
    _ = &@import("repl/tui/render_region.zig");
    _ = &@import("core/protocol/ui_event.zig");
    _ = &@import("core/protocol/ui_backend.zig");
    _ = &@import("core/protocol/ui_request.zig");
    _ = &@import("repl/tui/tui_backend.zig");
    _ = &@import("core/writer_backend.zig");
    _ = &@import("core/headless_backend.zig");
    _ = &@import("core/tee_backend.zig");
    _ = &@import("core/diagnostics_backend.zig");
    _ = &@import("core/suspend_state.zig");
    _ = &@import("repl/tui/ui_state.zig");
    _ = &@import("repl/tui/ui.zig");
    _ = &@import("repl/tui/event.zig");
    _ = &@import("repl/tui/dialog/permission.zig");
    _ = &@import("repl/tui/widget/tool_card.zig");
    _ = &@import("repl/tui/widget/agent_tree.zig");
    _ = &@import("repl/tui/widget/thinking.zig");
    _ = &@import("repl/tui/widget/pager.zig");
    _ = &@import("repl/tui/config.zig");
    _ = &@import("mcp/protocol.zig");
    _ = &@import("mcp/transport_stdio.zig");
    _ = &@import("mcp/client.zig");
    _ = &@import("mcp/registry_bridge.zig");
    _ = &@import("tools/dynamic.zig");
    _ = &@import("skills/skill.zig");
    _ = &@import("skills/tool_pool_filter.zig");
    _ = &@import("skills/render.zig");
    _ = &@import("skills/discovery.zig");
    _ = &@import("agents/def.zig");
    _ = &@import("agents/set.zig");
    _ = &@import("agents/filter.zig");
    _ = &@import("agents/preload.zig");
    _ = &@import("tools/monitor.zig");
    _ = &@import("tools/notebook_edit.zig");
    _ = &@import("tools/tool_search.zig");
    _ = &@import("tools/web_search.zig");
    _ = &@import("tools/worktree.zig");
    _ = &@import("tools/mcp_resources.zig");
    _ = &@import("tools/push_notification.zig");
    _ = &@import("tools/cron.zig");
    _ = &@import("tools/prompt_context.zig");
    _ = &@import("tools/descriptions.zig");
    _ = &@import("core/cron_registry.zig");
    _ = &@import("skills/tool.zig");
    _ = &@import("app/config.zig");
    _ = &@import("core/subagent.zig");
    _ = &@import("core/patch.zig");
    _ = &@import("web/journal.zig");
    _ = &@import("web/backend.zig");
    _ = &@import("web/server.zig");
    _ = &@import("web/session.zig");
    _ = &@import("daemon/registry.zig"); // U10:否则其 test 被 lazy analysis 跳过(Linus 抓的"测试从不跑")
    _ = &@import("daemon/app_driver.zig"); // U10-D:强制编译分析(否则死代码藏编译错)
    _ = &@import("daemon/serve.zig"); // U10-D
    _ = &@import("daemon/serve_multi.zig"); // U10-C:强制编译分析(否则死代码藏编译错)
    _ = &@import("daemon/uds.zig"); // U10-B:UDS+NDJSON 绑定
    _ = &@import("core/shutdown.zig");
}
