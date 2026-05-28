const std = @import("std");
const types = @import("types.zig");
const client = @import("client.zig");
const app_mod = @import("app.zig");
const repl = @import("repl/loop.zig");

pub const VERSION = "0.1.0";

// Public re-exports for tests and future consumers.
pub const api_stream = @import("api/stream.zig");
pub const util_abort = @import("util/abort.zig");
pub const conversation = @import("core/conversation.zig");
pub const agent_loop = @import("core/agent_loop.zig");
pub const tools = @import("tools.zig");
pub const bash = @import("tools/bash.zig");
pub const grep = @import("tools/grep.zig");
pub const glob = @import("tools/glob.zig");
pub const read_tool = @import("tools/read.zig");
pub const write_tool = @import("tools/write.zig");
pub const edit_tool = @import("tools/edit.zig");
pub const mcp_client = @import("mcp/client.zig");
pub const mcp_protocol = @import("mcp/protocol.zig");
pub const skills = @import("skills/skill.zig");
pub const skills_tool = @import("skills/tool.zig");
pub const skills_discovery = @import("skills/discovery.zig");
pub const tools_dynamic = @import("tools/dynamic.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const config = parseArgs(init, allocator);

    // 初始化日志：读 METACODES_LOG / METACODES_LOG_FILE 环境变量
    const log = @import("util/log.zig");
    log.initFromEnv();
    if (config.verbose) log.enableVerbose();

    // API key 优先级：CLI `--api-key <k>` > 硬编码 token。
    // 不读 ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN：这个代理后端与硬编码 token 绑定，
    // 读 env 反而会让用户以为切换了 URL/provider（实际 URL 也是硬编码的），造成困惑。
    const api_key = config.api_key orelse client.ANTHROPIC_AUTH_TOKEN;

    const app = try app_mod.App.init(allocator, init.io, config, api_key);
    defer app.deinit();

    try app.installSigintHandler();

    log.info("main", "metacodes starting; model={s}", .{config.model});

    // Headless 模式：`-p "..."` / stdin pipe → 跑单次 prompt 后退出，不进 REPL。
    if (config.prompt) |p| {
        const code = @import("repl/headless.zig").run(app, allocator, p, config.json_output) catch 1;
        std.process.exit(code);
    }

    try repl.run(app, allocator);
}

fn parseArgs(init: std.process.Init, allocator: std.mem.Allocator) types.Config {
    var config = types.Config{};
    var args = std.process.Args.iterate(init.minimal.args);
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--model")) {
            if (args.next()) |m| config.model = allocator.dupe(u8, m) catch m;
        } else if (std.mem.eql(u8, arg, "--api-key")) {
            if (args.next()) |k| config.api_key = allocator.dupe(u8, k) catch k;
        } else if (std.mem.eql(u8, arg, "--permission")) {
            if (args.next()) |m| config.permission_mode = parsePermMode(m);
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
        } else if (std.mem.eql(u8, arg, "-")) {
            // 从 stdin 读全部作为 prompt（headless pipe 模式）
            config.prompt = readAllStdin(allocator) catch null;
        }
    }
    return config;
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
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "prompt")) return .prompt;
    if (std.mem.eql(u8, s, "plan")) return .plan;
    if (std.mem.eql(u8, s, "bypass")) return .bypass;
    return .prompt;
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
        \\  --permission <mode>   auto | prompt | plan | bypass
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
    _ = &@import("repl/history.zig");
    _ = &@import("repl/multiline.zig");
    _ = &@import("repl/render.zig");
    _ = &@import("repl/headless.zig");
    _ = &@import("repl/complete.zig");
    _ = &@import("repl/paste.zig");
    _ = &@import("mcp/protocol.zig");
    _ = &@import("mcp/transport_stdio.zig");
    _ = &@import("mcp/client.zig");
    _ = &@import("mcp/registry_bridge.zig");
    _ = &@import("tools/dynamic.zig");
    _ = &@import("skills/skill.zig");
    _ = &@import("skills/discovery.zig");
    _ = &@import("skills/tool.zig");
    _ = &@import("app/config.zig");
    _ = &@import("core/subagent.zig");
    _ = &@import("core/patch.zig");
}
