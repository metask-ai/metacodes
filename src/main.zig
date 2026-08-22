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

pub const VERSION = "0.1.0";

// Public re-exports for tests and future consumers.
pub const api_stream = @import("api/stream.zig");
pub const api_provider = @import("api/provider.zig");
pub const api_provider_factory = @import("api/provider_factory.zig");
pub const api_capability = @import("api/capability.zig");
pub const api_cache = @import("api/cache.zig");
pub const api_http_status = @import("api/http_status.zig");
pub const api_openai = @import("api/openai_client.zig");
pub const api_gemini = @import("api/gemini_client.zig");
pub const api_dialect = @import("api/dialect.zig");
pub const api_request = @import("api/request.zig");
pub const api_request_overrides = @import("api/request_overrides.zig");
pub const model_adapter = @import("api/model_adapter.zig");
pub const client_mod = client; // alias for L2 component tests
pub const task_store = @import("core/task_store.zig"); // L2 requirement-ledger tests
pub const requirement_ledger = @import("core/requirement_ledger.zig"); // L2 ledger decide tests
pub const types_mod = types;
pub const json_mod = @import("json.zig");
pub const util_abort = @import("util/abort.zig");
pub const util_fs = @import("util/fs.zig");
pub const conversation = @import("core/conversation.zig");
pub const message = @import("core/message.zig");
pub const compact_summary = @import("core/compact_summary.zig");
pub const agent_loop = @import("core/agent_loop.zig");
pub const agent_session = @import("core/agent_session.zig");
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
pub const swarm_file_lock = @import("swarm/file_lock.zig");
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
pub const tool_result_storage = @import("tools/tool_result_storage.zig");
pub const tool_result_artifact = @import("core/tool_result_artifact.zig");
pub const result_projection = @import("core/result_projection.zig");
pub const tool_result_metrics = @import("core/tool_result_metrics.zig");
pub const read_artifact = @import("tools/read_artifact.zig");
pub const cache_break = @import("core/cache_break.zig");
pub const core_message = @import("core/message.zig");
pub const transcript = @import("core/transcript.zig");
pub const repl_headless = @import("repl/headless.zig");
pub const repl_loop = @import("repl/loop.zig");
pub const app_module = @import("app.zig");
pub const tool_context = @import("tools/context.zig");
pub const project_rule_gate_protocol = @import("tools/project_rule_gate.zig");
pub const tool_error = @import("core/tool_error.zig");
pub const bash = @import("tools/bash.zig");
pub const grep = @import("tools/grep.zig");
pub const glob = @import("tools/glob.zig");
pub const read_tool = @import("tools/read.zig");
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

    // --- provider 选择:env METACODES_PROVIDER 显式优先,否则据 model 前缀推断 ---
    // (gpt*/o1*/o3* → openai,gemini* → gemini)。只在此组装层据此选 Client;core/UI 零感知。
    if (std.c.getenv("METACODES_PROVIDER")) |c| {
        const v = std.mem.span(c);
        if (std.mem.eql(u8, v, "openai")) config.provider_kind = .openai;
        if (std.mem.eql(u8, v, "gemini")) config.provider_kind = .gemini;
    } else {
        config.provider_kind = inferProviderKind(config.model);
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

    // Runtime resolution consumes one-shot FD authority before App/job/tool
    // subprocesses exist. Ordinary env auth retains legacy teammate inheritance.
    var resolved_credential = auth.resolveRuntimeCredential(allocator, config.api_key, config.auth_precedence) catch |err| {
        @import("util/log.zig").err("auth", "credential resolution failed: {s}", .{@errorName(err)});
        std.debug.print(
            \\Authentication required.
            \\Use one of:
            \\  metacodes login --oauth-token-json <token-response.json>
            \\  metacodes login --api-key <key>
            \\  export METASK_API_KEY=...
            \\
            \\No token value was printed.
            \\
        , .{});
        return err;
    };
    defer resolved_credential.deinit(allocator);
    const api_key = resolved_credential.bearer_token;

    applyStoredLoginSelection(allocator, &config) catch |err| {
        log.debug("auth", "stored model selection unavailable: {s}", .{@errorName(err)});
    };
    if (!isUsableConfiguredSession(config, resolved_credential.source)) {
        std.debug.print(
            \\Metask login is incomplete.
            \\Run `metacodes login` in a terminal and select an API key, model, and reasoning effort.
            \\Use --model and --reasoning-effort only when intentionally overriding the saved selection.
            \\
        , .{});
        return error.IncompleteLoginSelection;
    }

    const app = try app_mod.App.init(allocator, init.io, config, api_key);
    defer app.deinit();

    try app.installSigintHandler();

    log.info("main", "metacodes starting; model={s}", .{config.model});

    // --dump-prompt：打印组装好的 system prompt + 工具 defs(name + description)后退出。
    // 不发网络、不需有效 key。用于验证提示词×工具复刻(工具长描述 + 动态裁剪)。
    if (config.dump_prompt) {
        dumpPromptAndExit(app);
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
        const code = @import("repl/headless.zig").run(app, allocator, p, config.json_output) catch |err| blk: {
            std.debug.print("error: headless setup failed: {s}\n", .{@errorName(err)});
            break :blk 1;
        };
        app.deinit(); // 同上:headless 一样跑 MCP/LSP,同款孤儿病(agent loop 已结束,quiescent)
        std.process.exit(code);
    }

    // 交互式 TUI 拥有终端:禁止日志写 stderr(fd 2),否则 err/warn 与渲染(render_region.flush 也走
    // std.debug.print→fd 2)字节级交错,把固定区写花、滚屏 desync。日志仍写文件(METACODES_LOG_FILE)。
    // **gate 必须查渲染所在的 fd 2**(不是 fd 1):`metacodes >file` 只重定向 stdout、TUI 仍渲染到 fd 2 的
    // 终端,此时也要抑制日志。verbose(用户显式要日志)/ fd 2 非 tty(无终端可写花)不关。
    if (!config.verbose and platform_term.isatty(2)) {
        log.setStderrEnabled(false);
    }

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
        } else if (std.mem.eql(u8, arg, "--answers-file")) {
            if (args.next()) |s| config.answers_file = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--base-url")) {
            if (args.next()) |s| config.base_url = allocator.dupe(u8, s) catch s;
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
            config.lsp_enabled = true; // Y2:开 LSP 被动诊断(Edit/Write 后附类型诊断)
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
        } else if (std.mem.eql(u8, arg, "-")) {
            // 从 stdin 读全部作为 prompt（headless pipe 模式）
            config.prompt = readAllStdin(allocator) catch null;
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
}

/// 读 stdin 全部内容（headless `-` 模式）。EOF 即停。
fn readAllStdin(allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(0, chunk[0..chunk.len]);
        if (n <= 0) break;
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

/// 累加一个 \x00 分隔的列表(--add-dir 可重复)。返回新分配的串,旧串泄漏到 arena。
fn appendNulList(allocator: std.mem.Allocator, prev: ?[]const u8, item: []const u8) ?[]const u8 {
    if (prev) |p| {
        return std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ p, item }) catch p;
    }
    return allocator.dupe(u8, item) catch item;
}

fn printHelp() void {
    std.debug.print(
        \\Metacode Super
        \\Usage: metacodes [options]
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
        \\  --dump-prompt         Print the assembled system prompt and exit
        \\  serve [port]          Daemon mode (HTTP; default port 7777)
        \\  --sessions <n>        Daemon: static session count (>1 enables multi-session)
        \\  --uds <path>          Daemon: additional UDS+NDJSON binding
        \\  --add-dir <path>      Extra read/write directory (repeatable)
        \\  --answers-file <path> Preset answers for permission .ask / AskUserQuestion (non-tty)
        \\  --base-url <url>      Override API endpoint (must end with /v1/messages)
        \\  --auth-precedence <p> api-key-first | oauth-first
        \\  --record <dir>        Record requests + SSE responses to dir (cassette)
        \\  --no-theme            Disable colors
        \\  --verbose             Verbose output
        \\  --lsp                 Enable LSP passive diagnostics on Edit/Write (needs zls/pyright/etc on PATH)
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
    _ = &@import("swarm/file_lock.zig");
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
    _ = &@import("session_service.zig");
    _ = &@import("repl/loop.zig");
    _ = &@import("util/abort.zig");
    _ = &@import("util/toolchain.zig");
    _ = &@import("util/log.zig");
    _ = &@import("util/model.zig");
    _ = &@import("util/path.zig");
    _ = &@import("api/catalog.zig");
    _ = &@import("tools/context.zig");
    _ = &@import("repl/input.zig");
    _ = &@import("repl/model_command.zig");
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
