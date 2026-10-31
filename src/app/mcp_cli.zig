//! `metacodes mcp …`: OAuth logins for HTTP MCP servers (mcp/oauth.zig).
//!
//! - `login <server> [--no-browser]` runs discovery, client registration and
//!   the authorization code flow for a configured HTTP or SSE server and
//!   stores the token under `<state root>/mcp-oauth/`; the next session uses
//!   it and refreshes it.
//! - `logout <server>` forgets the stored login.
//! - `list` shows every configured server, its transport and, for URL
//!   servers, how it authenticates.
//!
//! Servers are resolved exactly as a session resolves them (mcp/config.zig,
//! from the current directory), so `login` names what `/mcp` lists.

const std = @import("std");
const pfs = @import("platform").fs;
const paths = @import("platform").paths;
const mcp_config = @import("../mcp/config.zig");
const mcp_oauth = @import("../mcp/oauth.zig");
const mcp_startup = @import("mcp_startup.zig");
const util_time = @import("../util/time.zig");

const USAGE =
    \\usage: metacodes mcp login <server> [--no-browser]
    \\       metacodes mcp logout <server>
    \\       metacodes mcp list
    \\
;

pub fn run(args: *std.process.Args.Iterator, gpa: std.mem.Allocator, io: std.Io, state_root: []const u8) u8 {
    const sub = args.next() orelse {
        std.debug.print("{s}", .{USAGE});
        return 2;
    };
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        stdoutWrite(USAGE);
        return 0;
    }
    if (std.mem.eql(u8, sub, "list")) {
        if (args.next()) |extra| return unknownArgument(extra);
        return list(gpa, state_root);
    }
    const is_login = std.mem.eql(u8, sub, "login");
    if (!is_login and !std.mem.eql(u8, sub, "logout")) {
        std.debug.print("error: unknown mcp subcommand '{s}'\n{s}", .{ sub, USAGE });
        return 2;
    }
    const name = args.next() orelse {
        std.debug.print("{s}", .{USAGE});
        return 2;
    };
    var open_browser = true;
    while (args.next()) |arg| {
        if (is_login and std.mem.eql(u8, arg, "--no-browser")) {
            open_browser = false;
        } else return unknownArgument(arg);
    }
    if (state_root.len == 0) {
        std.debug.print("error: no state root; pass --state-dir or set METACODES_HOME\n", .{});
        return 1;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const resolved = resolveServers(arena, state_root) catch |err| {
        std.debug.print("error: could not read the MCP configuration ({s})\n", .{@errorName(err)});
        return 1;
    };
    const server = for (resolved.servers) |server| {
        if (std.mem.eql(u8, server.name, name)) break server;
    } else {
        std.debug.print("error: no MCP server named '{s}' is configured here (see `metacodes mcp list`)\n", .{name});
        return 1;
    };
    const http = switch (server.transport) {
        .http => |http| http,
        .stdio => {
            std.debug.print("error: '{s}' is a stdio server; OAuth applies to HTTP and SSE servers\n", .{name});
            return 1;
        },
    };
    if (is_login) return login(gpa, io, arena, state_root, server.name, http, open_browser);
    return logout(gpa, state_root, server.name, http.url);
}

fn unknownArgument(arg: []const u8) u8 {
    std.debug.print("error: unknown mcp argument '{s}'\n{s}", .{ arg, USAGE });
    return 2;
}

fn resolveServers(arena: std.mem.Allocator, state_root: []const u8) !mcp_config.Resolved {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try arena.dupe(u8, pfs.getCwd(&cwd_buffer) orelse "");
    const workspace_root = @import("../skills/skill.zig").findRepoRoot(arena, cwd) catch cwd;
    return mcp_config.load(arena, .{
        .state_root = state_root,
        .home = paths.homeDir() orelse "",
        .cwd = cwd,
        .workspace_root = workspace_root,
        .codex_home = paths.codexHomeEnv() orelse "",
        .env = try mcp_config.Environment.fromProcess(arena),
    });
}

fn stderrSay(_: *anyopaque, text: []const u8) void {
    std.debug.print("{s}", .{text});
}

var notify_ctx: u8 = 0;

fn login(
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    state_root: []const u8,
    name: []const u8,
    http: mcp_config.Http,
    open_browser: bool,
) u8 {
    const environment = mcp_config.Environment.fromProcess(arena) catch return 1;
    const headers = mcp_startup.httpHeaders(arena, http, environment) catch |err| {
        std.debug.print("error: the server's configured headers are unusable ({s})\n", .{@errorName(err)});
        return 1;
    };
    if (mcp_startup.hasAuthorization(headers)) {
        std.debug.print("error: '{s}' already sends an Authorization header from its configuration; remove it (or bearerTokenEnvVar) to use an OAuth login\n", .{name});
        return 1;
    }
    var std_headers: std.ArrayList(std.http.Header) = .empty;
    for (headers) |header| std_headers.append(arena, .{ .name = header.name, .value = header.value }) catch return 1;
    var result = mcp_oauth.login(gpa, io, state_root, .{
        .name = name,
        .target = .{ .url = http.url, .wire = http.wire, .headers = std_headers.items },
        .settings = http.oauth,
    }, .{
        .open_browser = open_browser,
        .notify = .{ .ctx = &notify_ctx, .write = stderrSay },
    }) catch |err| {
        std.debug.print("error: login to '{s}' failed: {s}\n", .{ name, mcp_oauth.describe(err) });
        return 1;
    };
    defer result.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.print("Logged in to MCP server '{s}' through {s}", .{ name, result.issuer }) catch return 1;
    if (result.scope) |scope| out.writer.print(" (scope: {s})", .{scope}) catch return 1;
    out.writer.print(".\nToken stored in {s}; sessions started from now on use it.\n", .{result.path}) catch return 1;
    stdoutWrite(out.written());
    return 0;
}

fn logout(gpa: std.mem.Allocator, state_root: []const u8, name: []const u8, url: []const u8) u8 {
    const path = mcp_oauth.storePath(gpa, state_root, name, url) catch return 1;
    defer gpa.free(path);
    const removed = mcp_oauth.removeRecord(gpa, path) catch |err| {
        std.debug.print("error: could not remove {s}: {s}\n", .{ path, mcp_oauth.describe(err) });
        return 1;
    };
    if (removed) {
        var buffer: [512]u8 = undefined;
        stdoutWrite(std.fmt.bufPrint(&buffer, "Logged out of MCP server '{s}'.\n", .{name}) catch "Logged out.\n");
    } else {
        var buffer: [512]u8 = undefined;
        stdoutWrite(std.fmt.bufPrint(&buffer, "No stored login for MCP server '{s}'.\n", .{name}) catch "No stored login.\n");
    }
    return 0;
}

fn list(gpa: std.mem.Allocator, state_root: []const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const resolved = resolveServers(arena, state_root) catch |err| {
        std.debug.print("error: could not read the MCP configuration ({s})\n", .{@errorName(err)});
        return 1;
    };
    const environment = mcp_config.Environment.fromProcess(arena) catch return 1;
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (resolved.servers.len == 0) w.writeAll("No MCP servers configured.\n") catch return 1;
    for (resolved.servers) |server| {
        switch (server.transport) {
            .stdio => |stdio| w.print("{s}  stdio  {s}  ({s})\n", .{ server.name, stdio.command, server.origin.label() }) catch return 1,
            .http => |http| {
                const kind = switch (http.wire) {
                    .streamable => "http",
                    .legacy_sse => "sse",
                };
                const auth = authState(gpa, arena, state_root, server.name, http, environment);
                w.print("{s}  {s}  {s}  {s}  ({s})\n", .{ server.name, kind, http.url, auth, server.origin.label() }) catch return 1;
            },
        }
    }
    stdoutWrite(out.written());
    return 0;
}

fn authState(gpa: std.mem.Allocator, arena: std.mem.Allocator, state_root: []const u8, name: []const u8, http: mcp_config.Http, environment: mcp_config.Environment) []const u8 {
    const headers = mcp_startup.httpHeaders(arena, http, environment) catch return "headers: unusable";
    if (mcp_startup.hasAuthorization(headers)) return "auth: configured";
    const path = mcp_oauth.storePath(gpa, state_root, name, http.url) catch return "auth: none";
    defer gpa.free(path);
    var record = (mcp_oauth.loadRecord(gpa, path, http.url) catch null) orelse return "auth: none";
    defer record.deinit(gpa);
    const now = util_time.nowUnix();
    if (record.expires_at) |expires_at| {
        if (expires_at <= now and record.refresh_token == null) return "auth: OAuth login expired (run `metacodes mcp login`)";
    }
    return std.fmt.allocPrint(arena, "auth: OAuth ({s})", .{record.issuer}) catch "auth: OAuth";
}

fn stdoutWrite(bytes: []const u8) void {
    _ = pfs.writeAll(1, bytes);
}
