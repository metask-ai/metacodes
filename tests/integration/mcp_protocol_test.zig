//! MCP client protocol behaviour against the mock server's modes
//! (tests/_harness/mock_mcp_server.zig): revision negotiation (2026-07-28
//! discovery, Classic handshake fallback, restart after a fatal probe),
//! server pings, stale answers, pagination, MRTR, cancellation, and
//! configuration reaching the child process. The same client's behaviour with
//! no process in the way, under both entry-point profiles, is src/mcp/conformance.zig.

const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");

const MOCK: [*:0]const u8 = "zig-out/bin/mock_mcp_server";

fn connectMock(flags: []const [*:0]const u8, options: cc.mcp_client.ConnectOptions) !cc.mcp_client.McpClient {
    var argv: [8]?[*:0]const u8 = .{null} ** 8;
    argv[0] = MOCK;
    for (flags, 1..) |flag, index| argv[index] = flag;
    var resolved = options;
    resolved.spawn = .{ .argv = argv[0 .. flags.len + 2] };
    if (resolved.startup_timeout_ms == null) resolved.startup_timeout_ms = 10_000;
    return cc.mcp_client.McpClient.connectWith(std.testing.allocator, resolved);
}

fn expectTool(tools_json: []const u8, name: []const u8) !void {
    var buffer: [128]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buffer, "\"name\":\"{s}\"", .{name});
    if (std.mem.indexOf(u8, tools_json, needle) == null) {
        std.debug.print("tool {s} missing in {s}\n", .{ name, tools_json });
        return error.TestExpectedTool;
    }
}

test "MCP: a Classic server gets the handshake after the discovery probe" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var client = try connectMock(&.{}, .{ .spawn = undefined });
    defer client.close();
    try std.testing.expect(!client.modern);
    try std.testing.expectEqualStrings("2024-11-05", client.protocol_version);
    const tools = try client.listTools();
    defer std.testing.allocator.free(tools);
    try expectTool(tools, "echo");
}

test "MCP: a 2026-07-28 server is found by server/discover and every request carries _meta" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var client = try connectMock(&.{"--modern"}, .{ .spawn = undefined });
    defer client.close();
    try std.testing.expect(client.modern);
    try std.testing.expectEqualStrings("2026-07-28", client.protocol_version);
    try std.testing.expect(client.capabilities.tools and client.capabilities.resources);
    // The mock rejects any request without `_meta` (and any `initialize`).
    const tools = try client.listTools();
    defer std.testing.allocator.free(tools);
    try expectTool(tools, "mrtr");
    const echoed = try client.callTool("echo", "{\"message\":\"modern\"}");
    defer std.testing.allocator.free(echoed);
    try std.testing.expect(std.mem.indexOf(u8, echoed, "modern") != null);
}

test "MCP: a server that dies on the probe, or ignores it, is restarted for the handshake" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var died = try connectMock(&.{"--die-on-discover"}, .{ .spawn = undefined });
    defer died.close();
    try std.testing.expect(!died.modern);
    const tools = try died.listTools();
    defer std.testing.allocator.free(tools);
    try expectTool(tools, "echo");

    var silent = try connectMock(&.{"--silent-discover"}, .{ .spawn = undefined, .probe_timeout_ms = 300 });
    defer silent.close();
    try std.testing.expect(!silent.modern);
    try std.testing.expectEqualStrings("2024-11-05", silent.protocol_version);
}

test "MCP: Classic version negotiation accepts known revisions and refuses others" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var older = try connectMock(&.{ "--version", "2025-06-18" }, .{ .spawn = undefined });
    defer older.close();
    try std.testing.expectEqualStrings("2025-06-18", older.protocol_version);
    try std.testing.expectError(
        error.UnsupportedProtocolVersion,
        connectMock(&.{ "--version", "1999-01-01" }, .{ .spawn = undefined }),
    );
    try std.testing.expectError(
        error.UnsupportedProtocolVersion,
        connectMock(&.{}, .{ .spawn = undefined, .protocol = .modern_only }),
    );
}

test "MCP: a server ping is answered and pagination follows an empty-string cursor" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var pinging = try connectMock(&.{"--ping"}, .{ .spawn = undefined });
    defer pinging.close();
    // Without a ping reply the mock never sends the list: bound the wait.
    pinging.transport.setDeadline(@import("cc").util_time.nowMs() + 5_000);
    const listed = try pinging.listTools();
    defer std.testing.allocator.free(listed);
    try expectTool(listed, "echo");

    var paged = try connectMock(&.{"--paginate"}, .{ .spawn = undefined });
    defer paged.close();
    const pages = try paged.listTools();
    defer std.testing.allocator.free(pages);
    try expectTool(pages, "echo");
    try expectTool(pages, "page.two");
}

fn acceptElicitation(ctx: *anyopaque, params_json: []const u8, alloc: std.mem.Allocator) ?[]u8 {
    const seen: *bool = @ptrCast(@alignCast(ctx));
    seen.* = std.mem.indexOf(u8, params_json, "who are you") != null;
    return alloc.dupe(u8, "{\"name\":\"metacodes\"}") catch null;
}

test "MCP: 2026-07-28 input_required is fulfilled and retried with the echoed state" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var client = try connectMock(&.{"--modern"}, .{ .spawn = undefined });
    defer client.close();
    const declined = try client.callTool("mrtr", "{}");
    defer std.testing.allocator.free(declined);
    if (std.mem.indexOf(u8, declined, "mrtr:decline:state=true") == null) {
        std.debug.print("declined result: {s}\n", .{declined});
        return error.TestUnexpectedResult;
    }

    var seen = false;
    client.elicit = .{ .ctx = @ptrCast(&seen), .handleFn = acceptElicitation };
    const accepted = try client.callTool("mrtr", "{}");
    defer std.testing.allocator.free(accepted);
    try std.testing.expect(seen);
    try std.testing.expect(std.mem.indexOf(u8, accepted, "mrtr:accept:state=true") != null);
}

test "MCP: a timed-out call is cancelled with notifications/cancelled" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var client = try connectMock(&.{}, .{ .spawn = undefined, .request_timeout_ms = 300 });
    defer client.close();
    try std.testing.expectError(
        error.McpRequestTimeout,
        client.callToolBodyAbortable("hang", "{}", root, .{}, null),
    );
    const report = try client.callTool("cancelled", "{}");
    defer std.testing.allocator.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "cancelled:0") == null);
    try std.testing.expect(std.mem.indexOf(u8, report, "cancelled:") != null);
}

test "MCP: a stale answer is skipped and tools/list_changed is recorded, on both call paths" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var client = try connectMock(&.{}, .{ .spawn = undefined });
    defer client.close();
    try std.testing.expect(!client.tools_changed.load(.acquire));
    const called = try client.callTool("noise", "{}");
    defer std.testing.allocator.free(called);
    try std.testing.expect(std.mem.indexOf(u8, called, "noise-done") != null);
    try std.testing.expect(std.mem.indexOf(u8, called, "stale") == null);
    try std.testing.expect(client.tools_changed.load(.acquire));

    client.tools_changed.store(false, .release);
    var body = try client.callToolBodyAbortable("noise", "{}", root, .{}, null);
    defer body.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, body.@"inline".bytes, "noise-done") != null);
    try std.testing.expect(client.tools_changed.load(.acquire));
}

test "MCP: a tool's isError reaches the model as a tool error through the registry" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var client = try connectMock(&.{}, .{ .spawn = undefined });
    defer client.close();
    var registry = cc.tools_dynamic.DynRegistry.init(a);
    defer registry.deinit();
    var session = cc.mcp_registry_bridge.McpSession.init(a, &client);
    defer session.deinit();
    try session.registerToolsFromJson(&registry, "m", "{\"tools\":[{\"name\":\"toolerror\"}]}");
    var ctx = cc.tools.ToolContext.simple(a);
    ctx.artifact_root = root;
    var body = try registry.find("mcp__m__toolerror").?.execute(&ctx, "{}");
    defer body.deinit(a);
    try std.testing.expect(body == .structured_error);
    try std.testing.expect(std.mem.indexOf(u8, body.structured_error.encoded, "tool said no") != null);
}

test "L2 MCP config: env, env_vars, the allowlist, cwd and enabled_tools reach the server" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const repo_cwd = try cc.util_fs.getCwd(arena.allocator());
    const mock_abs = try std.fs.path.join(arena.allocator(), &.{ repo_cwd, "zig-out/bin/mock_mcp_server" });

    const config_json = try std.fmt.allocPrint(arena.allocator(),
        \\{{"mcpServers":{{"probe":{{"command":"{s}","env":{{"CONFIGURED":"${{FROM_PARENT}}-x"}},
        \\  "envVars":["PASSED_THROUGH"],"cwd":"{s}","enabledTools":["env","cwd"]}}}}}}
    , .{ mock_abs, root });
    const environment = cc.mcp_config.Environment{ .entries = &.{
        "PATH=/usr/bin:/bin", "HOME=/home/test", "FROM_PARENT=parent", "PASSED_THROUGH=yes", "NOT_ALLOWED=secret",
    } };
    const resolved = try cc.mcp_config.resolve(arena.allocator(), .{
        .metacodes_config = .{ .path = "/state/config.json", .bytes = config_json },
    }, .{ .cwd = repo_cwd, .workspace_root = repo_cwd, .env = environment });
    try std.testing.expectEqual(@as(usize, 1), resolved.servers.len);
    const server = resolved.servers[0];
    const launch = try cc.mcp_launch.prepare(arena.allocator(), server.transport.stdio, environment, repo_cwd);
    var client = try cc.mcp_client.McpClient.connectWith(a, .{
        .spawn = .{ .argv = launch.argv, .env = launch.env, .cwd = launch.cwd },
        .startup_timeout_ms = 10_000,
    });
    defer client.close();

    const expectCall = struct {
        fn run(c: *cc.mcp_client.McpClient, tool: []const u8, args: []const u8, needle: []const u8) !void {
            const out = try c.callTool(tool, args);
            defer std.testing.allocator.free(out);
            if (std.mem.indexOf(u8, out, needle) == null) {
                std.debug.print("{s}: expected {s} in {s}\n", .{ tool, needle, out });
                return error.TestUnexpectedResult;
            }
        }
    }.run;
    try expectCall(&client, "env", "{\"name\":\"CONFIGURED\"}", "env:CONFIGURED=parent-x");
    try expectCall(&client, "env", "{\"name\":\"PASSED_THROUGH\"}", "env:PASSED_THROUGH=yes");
    try expectCall(&client, "env", "{\"name\":\"HOME\"}", "env:HOME=/home/test");
    try expectCall(&client, "env", "{\"name\":\"NOT_ALLOWED\"}", "env:NOT_ALLOWED=<unset>");
    const cwd_needle = try std.fmt.allocPrint(arena.allocator(), "cwd:{s}", .{root});
    try expectCall(&client, "cwd", "{}", cwd_needle);

    var registry = cc.tools_dynamic.DynRegistry.init(a);
    defer registry.deinit();
    var session = cc.mcp_registry_bridge.McpSession.init(a, &client);
    defer session.deinit();
    try session.registerToolsFiltered(&registry, server.name, .{ .enabled = server.enabled_tools, .disabled = server.disabled_tools });
    try std.testing.expectEqual(@as(usize, 2), registry.entries.items.len);
    try std.testing.expect(registry.find("mcp__probe__env") != null);
    try std.testing.expect(registry.find("mcp__probe__echo") == null);
}
