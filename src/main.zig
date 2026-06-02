const std = @import("std");
const types = @import("types.zig");
const client = @import("client.zig");
const app_mod = @import("app.zig");
const repl = @import("repl/loop.zig");

pub const VERSION = "0.1.0";

// Public re-exports for tests and future consumers.
pub const api_stream = @import("api/stream.zig");
pub const client_mod = client; // alias for L2 component tests
pub const types_mod = types;
pub const json_mod = @import("json.zig");
pub const util_abort = @import("util/abort.zig");
pub const conversation = @import("core/conversation.zig");
pub const agent_loop = @import("core/agent_loop.zig");
pub const core_subagent = @import("core/subagent.zig");
pub const agent_job_registry = @import("core/agent_job_registry.zig");
pub const util_time = @import("util/time.zig");
pub const tools = @import("tools.zig");
pub const task_tools = @import("tools/task_tools.zig");
pub const task_output_tool = @import("tools/task_output.zig");
pub const agent_tool = @import("tools/agent.zig");
pub const core_task_store = @import("core/task_store.zig");
pub const core_read_state = @import("core/read_state.zig");
pub const tool_exec = @import("core/tool_exec.zig");
pub const transcript = @import("core/transcript.zig");
pub const repl_headless = @import("repl/headless.zig");
pub const app_module = @import("app.zig");
pub const tool_context = @import("tools/context.zig");
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
pub const skills = @import("skills/skill.zig");
pub const skills_tool = @import("skills/tool.zig");
pub const skills_render = @import("skills/render.zig");
pub const skills_discovery = @import("skills/discovery.zig");
pub const active_skill = @import("skills/active.zig");
pub const permission = @import("permission.zig");
pub const permission_rule_spec = @import("permission/rule_spec.zig");
pub const permission_settings = @import("permission/settings.zig");
pub const permission_decision = @import("permission/decision.zig");
pub const permission_hooks = @import("permission/hooks.zig");
pub const agents_def = @import("agents/def.zig");
pub const agents_set = @import("agents/set.zig");
pub const agents_filter = @import("agents/filter.zig");
pub const agents_preload = @import("agents/preload.zig");
pub const tools_dynamic = @import("tools/dynamic.zig");
pub const system_prompt = @import("core/system_prompt.zig");
pub const util_log = @import("util/log.zig");
pub const tui_render_region = @import("repl/tui/render_region.zig");
pub const tui_status_bar = @import("repl/tui/widget/status_bar.zig");
pub const tui_verbs = @import("repl/tui/verbs.zig");
pub const answer_queue = @import("core/answer_queue.zig");
pub const recorder = @import("core/recorder.zig");

/// 测试钩子:暴露 parseArgs 给 L2(base_url_flag_test 等)。
/// 传入 argv(含 argv[0] 占位),返回解析后的 Config。
/// 注意:不要传 --help(会 std.process.exit 杀测试)。
pub fn parseArgsForTest(argv: []const [*:0]const u8, allocator: std.mem.Allocator) types.Config {
    var config = types.Config{};
    var args = std.process.Args.iterate(.{ .vector = argv });
    parseArgsInto(&config, &args, allocator);
    return config;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var config = parseArgs(init, allocator);

    // 初始化日志：读 METACODES_LOG / METACODES_LOG_FILE 环境变量
    const log = @import("util/log.zig");
    log.initFromEnv();
    if (config.verbose) log.enableVerbose();

    // --- env fallback:base_url / record_dir(CLI flag 优先,env 兜底)---
    if (config.base_url == null) {
        if (std.c.getenv("METACODES_BASE_URL")) |c| config.base_url = std.mem.span(c);
    }
    if (config.record_dir == null) {
        if (std.c.getenv("METACODES_RECORD_DIR")) |c| config.record_dir = std.mem.span(c);
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

    // API key 优先级：CLI `--api-key <k>` > 硬编码 token。
    // 不读 ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN：这个代理后端与硬编码 token 绑定，
    // 读 env 反而会让用户以为切换了 URL/provider（实际 URL 也是硬编码的），造成困惑。
    const api_key = config.api_key orelse client.ANTHROPIC_AUTH_TOKEN;

    const app = try app_mod.App.init(allocator, init.io, config, api_key);
    defer app.deinit();

    try app.installSigintHandler();

    log.info("main", "metacodes starting; model={s}", .{config.model});

    // --dump-prompt：打印组装好的 system prompt + 工具 defs(name + description)后退出。
    // 不发网络、不需有效 key。用于验证提示词×工具复刻(工具长描述 + 动态裁剪)。
    if (config.dump_prompt) {
        dumpPromptAndExit(app);
    }

    // Headless 模式：`-p "..."` / stdin pipe → 跑单次 prompt 后退出，不进 REPL。
    if (config.prompt) |p| {
        const code = @import("repl/headless.zig").run(app, allocator, p, config.json_output) catch 1;
        std.process.exit(code);
    }

    try repl.run(app, allocator);
}

/// 打印组装好的 system prompt + 工具 defs(name + 完整 description),然后退出。
/// 走 std.c.write(1,...) 直出 stdout——不经日志(避免 8192 截断),不发网络。
fn dumpWrite(bytes: []const u8) void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = std.c.write(1, bytes.ptr + pos, bytes.len - pos);
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

fn parseArgs(init: std.process.Init, allocator: std.mem.Allocator) types.Config {
    var config = types.Config{};
    var args = std.process.Args.iterate(init.minimal.args);
    parseArgsInto(&config, &args, allocator);
    return config;
}

/// 共享解析逻辑(parseArgs 生产路径 + parseArgsForTest 测试路径都走它)。
fn parseArgsInto(config: *types.Config, args: *std.process.Args.Iterator, allocator: std.mem.Allocator) void {
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--model")) {
            if (args.next()) |m| config.model = allocator.dupe(u8, m) catch m;
        } else if (std.mem.eql(u8, arg, "--api-key")) {
            if (args.next()) |k| config.api_key = allocator.dupe(u8, k) catch k;
        } else if (std.mem.eql(u8, arg, "--permission") or std.mem.eql(u8, arg, "--permission-mode")) {
            if (args.next()) |m| config.permission_mode = parsePermMode(m);
        } else if (std.mem.eql(u8, arg, "--settings")) {
            if (args.next()) |s| config.settings_path = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--allowedTools") or std.mem.eql(u8, arg, "--allowed-tools")) {
            if (args.next()) |s| config.allowed_tools = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--disallowedTools") or std.mem.eql(u8, arg, "--disallowed-tools")) {
            if (args.next()) |s| config.disallowed_tools = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--add-dir")) {
            if (args.next()) |s| config.add_dirs = appendNulList(allocator, config.add_dirs, s);
        } else if (std.mem.eql(u8, arg, "--answers-file")) {
            if (args.next()) |s| config.answers_file = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--base-url")) {
            if (args.next()) |s| config.base_url = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--record")) {
            if (args.next()) |s| config.record_dir = allocator.dupe(u8, s) catch s;
        } else if (std.mem.eql(u8, arg, "--max-tokens")) {
            if (args.next()) |s| {
                config.max_tokens = std.fmt.parseInt(u32, s, 10) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--no-theme")) {
            config.no_theme = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print")) {
            if (args.next()) |p| config.prompt = allocator.dupe(u8, p) catch p;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.json_output = true;
        } else if (std.mem.eql(u8, arg, "--dump-prompt")) {
            config.dump_prompt = true;
        } else if (std.mem.eql(u8, arg, "-")) {
            // 从 stdin 读全部作为 prompt（headless pipe 模式）
            config.prompt = readAllStdin(allocator) catch null;
        }
    }
}

/// 读 stdin 全部内容（headless `-` 模式）。EOF 即停。
fn readAllStdin(allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &chunk, chunk.len);
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
        \\  --model <model>       Model (default: claude-sonnet-4-20250514)
        \\  --api-key <key>       API key (overrides built-in token)
        \\  --permission <mode>   default | acceptEdits | plan | auto | dontAsk | bypassPermissions
        \\  --settings <path>     Extra settings JSON (CLI layer)
        \\  --allowedTools <list> Comma-separated allow rules, e.g. "Bash(git *),Read"
        \\  --disallowedTools <l> Comma-separated deny rules
        \\  --add-dir <path>      Extra read/write directory (repeatable)
        \\  --answers-file <path> Preset answers for permission .ask / AskUserQuestion (non-tty)
        \\  --base-url <url>      Override API endpoint (must end with /v1/messages)
        \\  --record <dir>        Record requests + SSE responses to dir (cassette)
        \\  --no-theme            Disable colors
        \\  --verbose             Verbose output
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
    _ = &@import("app.zig");
    _ = &@import("repl/loop.zig");
    _ = &@import("util/abort.zig");
    _ = &@import("util/toolchain.zig");
    _ = &@import("util/log.zig");
    _ = &@import("util/model.zig");
    _ = &@import("api/catalog.zig");
    _ = &@import("tools/context.zig");
    _ = &@import("repl/input.zig");
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
    _ = &@import("repl/tui/layout.zig");
    _ = &@import("repl/tui/test_capture.zig");
    _ = &@import("repl/tui/dialog/permission.zig");
    _ = &@import("repl/tui/widget/tool_card.zig");
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
}
