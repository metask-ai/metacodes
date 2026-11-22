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
const mcp_config_edit = @import("mcp_config_edit.zig");
const util_time = @import("../util/time.zig");

const USAGE =
    \\usage: metacodes mcp add <name> <url> [--type http|sse] [--header <name>=<value>]... [--force] [--no-check]
    \\       metacodes mcp add <name> [--env <name>=<value>]... [--force] [--no-check] -- <command> [<arg>...]
    \\       metacodes mcp add-json <name> '<json>' [--force] [--no-check]
    \\       metacodes mcp remove <name>
    \\       metacodes mcp login <server> [--no-browser]
    \\       metacodes mcp logout <server>
    \\       metacodes mcp list [--no-check]
    \\
;

const HELP = USAGE ++
    \\
    \\  add       Write a server into "mcpServers" of <state root>/config.json, the
    \\            configuration every session reads first. A URL (or --url) makes an
    \\            HTTP server (Streamable HTTP; --type sse for the older HTTP+SSE
    \\            transport); a command makes a stdio server. Claude Code's and Codex's
    \\            options work too (-t, -e, -H "Name: value", -s user,
    \\            --bearer-token-env-var, --client-id, --callback-port). A name that is
    \\            already configured is refused unless --force. Values may name
    \\            environment variables as ${VAR} or ${VAR:-default}, expanded when a
    \\            session starts, so a token need not be written into the file. The
    \\            server is then connected once to say whether it works (--no-check
    \\            skips that). New sessions connect it; in a running session, run
    \\            /mcp reconnect <name>.
    \\  add-json  The same, with the whole entry given as one JSON object.
    \\  remove    Take a server out of config.json (and forget its stored login).
    \\  login     OAuth login for an HTTP or SSE server; sessions send and refresh
    \\            the stored token.
    \\  logout    Forget a stored login.
    \\  list      Every configured server (from every source), its transport, how it
    \\            authenticates and, unless --no-check, whether it connects.
    \\
;

pub fn run(args: *std.process.Args.Iterator, gpa: std.mem.Allocator, io: std.Io, state_root: []const u8, command: []const u8) u8 {
    const sub = args.next() orelse {
        std.debug.print("{s}", .{USAGE});
        return 2;
    };
    if (isHelp(sub)) {
        stdoutWrite(HELP);
        return 0;
    }
    const is_add = std.mem.eql(u8, sub, "add");
    const is_add_json = std.mem.eql(u8, sub, "add-json");
    const is_remove = std.mem.eql(u8, sub, "remove");
    if (is_add or is_add_json or is_remove) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var rest: std.ArrayList([]const u8) = .empty;
        while (args.next()) |arg| rest.append(arena, arg) catch return 1;
        const parsed = (if (is_remove)
            parseRemove(arena, rest.items)
        else if (is_add)
            parseAdd(arena, rest.items)
        else
            parseAddJson(arena, rest.items)) catch return 1;
        const request = switch (parsed) {
            .ok => |request| request,
            .help => {
                stdoutWrite(HELP);
                return 0;
            },
            .usage => |problem| {
                std.debug.print("error: {s}\n{s}", .{ problem, USAGE });
                return 2;
            },
        };
        if (state_root.len == 0) {
            std.debug.print("error: no state root; pass --state-dir or set METACODES_HOME\n", .{});
            return 1;
        }
        if (is_remove) return remove(gpa, arena, state_root, request.name, command);
        return add(gpa, io, arena, state_root, request, command);
    }
    if (std.mem.eql(u8, sub, "list")) {
        var check_servers = true;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--no-check")) {
                check_servers = false;
            } else if (isHelp(arg)) {
                stdoutWrite(HELP);
                return 0;
            } else return unknownArgument(arg);
        }
        return list(gpa, io, state_root, check_servers, command);
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
        std.debug.print("error: no MCP server named '{s}' is configured here (see `{s} mcp list`)\n", .{ name, command });
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

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
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
    stdoutWrite(loginReport(arena, name, result) catch return 1);
    return 0;
}

fn loginReport(arena: std.mem.Allocator, name: []const u8, result: mcp_oauth.LoginResult) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("Logged in to MCP server '{s}' through {s}", .{ name, result.issuer });
    if (result.scope) |scope| {
        if (std.mem.trim(u8, scope, " ").len == 0)
            try w.writeAll(" (no scope granted)")
        else
            try w.print(" (scope: {s})", .{scope});
    }
    try w.writeAll(".\n");
    switch (result.verification) {
        .accepted => try w.writeAll("The server accepted the token.\n"),
        .unreachable_server => try w.writeAll("Warning: the server could not be reached to check the token; it was stored anyway.\n"),
        .unexpected_status => |status| try w.print("Warning: the server answered HTTP {d} when the token was tried; it was stored anyway.\n", .{status}),
    }
    try w.print("Token stored in {s}; sessions started from now on use it, and a running session does after `/mcp reconnect {s}`.\n", .{ result.path, name });
    return out.written();
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

fn list(gpa: std.mem.Allocator, io: std.Io, state_root: []const u8, check_servers: bool, command: []const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const resolved = resolveServers(arena, state_root) catch |err| {
        std.debug.print("error: could not read the MCP configuration ({s})\n", .{@errorName(err)});
        return 1;
    };
    const environment = mcp_config.Environment.fromProcess(arena) catch return 1;
    const checked: ?*mcp_startup.Startup = if (check_servers and resolved.servers.len != 0) blk: {
        std.debug.print("Checking {d} MCP {s}…\n", .{ resolved.servers.len, if (resolved.servers.len == 1) "server" else "servers" });
        break :blk checkServers(arena, io, state_root, .all);
    } else null;
    defer if (checked) |startup| startup.cancelAndJoin();

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (resolved.servers.len == 0) w.print("No MCP servers configured (`{s} mcp add` adds one).\n", .{command}) catch return 1;
    for (resolved.servers) |server| {
        switch (server.transport) {
            .stdio => |stdio| w.print("{s}  stdio  {s}  ({s})\n", .{ server.name, stdio.command, server.origin.label() }) catch return 1,
            .http => |http| {
                const kind = switch (http.wire) {
                    .streamable => "http",
                    .legacy_sse => "sse",
                };
                const auth = authState(gpa, arena, state_root, server.name, http, environment, command);
                w.print("{s}  {s}  {s}  {s}  ({s})\n", .{ server.name, kind, http.url, auth, server.origin.label() }) catch return 1;
            },
        }
        w.print("    configured in {s}\n", .{server.origin_path}) catch return 1;
        if (checked) |startup| for (startup.jobs) |*job| {
            if (!std.mem.eql(u8, job.server.name, server.name)) continue;
            w.writeAll("    status: ") catch return 1;
            writeOutcome(w, arena, job, command) catch return 1;
            w.writeAll("\n") catch return 1;
        };
    }
    for (resolved.pending) |pending| switch (pending.reason) {
        .needs_approval => w.print("{s}  awaiting approval: add \"{s}\" to \"enabledMcpjsonServers\" in {s}/config.json  ({s})\n", .{ pending.name, pending.name, state_root, pending.origin_path }) catch return 1,
        .rejected => w.print("{s}  rejected by disabledMcpjsonServers  ({s})\n", .{ pending.name, pending.origin_path }) catch return 1,
    };
    for (resolved.disabled) |name| w.print("{s}  disabled\n", .{name}) catch return 1;
    for (resolved.problems) |problem| {
        w.print("problem: {s}{s}{s}: {s}\n", .{
            problem.origin_path,
            if (problem.server.len != 0) " / " else "",
            problem.server,
            problem.message,
        }) catch return 1;
    }
    stdoutWrite(out.written());
    return 0;
}

fn checkServers(arena: std.mem.Allocator, io: std.Io, state_root: []const u8, select: mcp_startup.Select) ?*mcp_startup.Startup {
    const status = arena.create(mcp_startup.Status) catch return null;
    status.* = .{};
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = arena.dupe(u8, pfs.getCwd(&cwd_buffer) orelse "") catch return null;
    const workspace_root = @import("../skills/skill.zig").findRepoRoot(arena, cwd) catch cwd;
    const startup = mcp_startup.Startup.begin(arena, status, .{
        .io = io,
        .state_root = state_root,
        .home = paths.homeDir() orelse "",
        .cwd = cwd,
        .workspace_root = workspace_root,
        .codex_home = paths.codexHomeEnv() orelse "",
        .select = select,
        .server_logs = false,
    }) catch return null;
    startup.join();
    return startup;
}

fn writeOutcome(w: *std.Io.Writer, arena: std.mem.Allocator, job: *const mcp_startup.Job, command: []const u8) std.Io.Writer.Error!void {
    switch (job.result) {
        .pending, .kept => try w.writeAll("not checked"),
        .connected => |connected| {
            try w.print("connected, {d} tools (MCP {s})", .{ countTools(arena, connected.tools_json), connected.client.protocol_version });
        },
        .failed => |err| {
            if (err == error.McpAuthRequired) {
                const configured = switch (job.server.transport) {
                    .http => |http| http.bearer_token_env_var != null or sendsAuthorization(http.headers) or sendsAuthorization(http.env_headers),
                    .stdio => false,
                };
                if (configured)
                    try w.writeAll("the server refused the configured credentials (401/403)")
                else
                    try w.print("the server requires authorization (401/403); log in: {s} mcp login {s}", .{ command, job.server.name });
            } else try w.print("could not connect: {s}", .{mcp_startup.failureDetail(err, job)});
        },
    }
}

fn countTools(arena: std.mem.Allocator, tools_json: []const u8) usize {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, tools_json, .{}) catch return 0;
    if (root != .object) return 0;
    const tools = root.object.get("tools") orelse return 0;
    return if (tools == .array) tools.array.items.len else 0;
}

fn authState(gpa: std.mem.Allocator, arena: std.mem.Allocator, state_root: []const u8, name: []const u8, http: mcp_config.Http, environment: mcp_config.Environment, command: []const u8) []const u8 {
    const headers = mcp_startup.httpHeaders(arena, http, environment) catch return "headers: unusable";
    if (mcp_startup.hasAuthorization(headers)) return "auth: configured";
    const not_logged_in = std.fmt.allocPrint(arena, "auth: not logged in (if the server requires it: {s} mcp login {s})", .{ command, name }) catch "auth: not logged in";
    const path = mcp_oauth.storePath(gpa, state_root, name, http.url) catch return not_logged_in;
    defer gpa.free(path);
    var record = (mcp_oauth.loadRecord(gpa, path, http.url) catch null) orelse return not_logged_in;
    defer record.deinit(gpa);
    const now = util_time.nowUnix();
    if (record.expires_at) |expires_at| {
        if (expires_at <= now and record.refresh_token == null)
            return std.fmt.allocPrint(arena, "auth: OAuth login expired (run `{s} mcp login {s}`)", .{ command, name }) catch "auth: OAuth login expired";
    }
    return std.fmt.allocPrint(arena, "auth: OAuth ({s})", .{record.issuer}) catch "auth: OAuth";
}

fn stdoutWrite(bytes: []const u8) void {
    _ = pfs.writeAll(1, bytes);
}

pub const Spec = union(enum) {
    entry: mcp_config_edit.Entry,
    json: []const u8,
};

pub const AddRequest = struct {
    name: []const u8,
    spec: Spec,
    force: bool = false,
    check: bool = true,
};

pub const AddParse = union(enum) {
    ok: AddRequest,
    usage: []const u8,
    help,
};

pub fn parseAdd(arena: std.mem.Allocator, args: []const []const u8) error{OutOfMemory}!AddParse {
    var request: AddRequest = .{ .name = "", .spec = undefined };
    var name: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var type_name: ?[]const u8 = null;
    var command: ?[]const []const u8 = null;
    var bearer: ?[]const u8 = null;
    var client_id: ?[]const u8 = null;
    var callback_port: ?u16 = null;
    var headers: std.ArrayList(mcp_config.KeyValue) = .empty;
    var env: std.ArrayList(mcp_config.KeyValue) = .empty;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            if (command != null) return .{ .usage = "two commands given" };
            command = args[index + 1 ..];
            break;
        }
        if (isHelp(arg)) return .help;
        if (std.mem.eql(u8, arg, "--force")) {
            request.force = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-check")) {
            request.check = false;
            continue;
        }
        if (try takeOption(arena, args, &index)) |option| switch (option) {
            .usage => |problem| return .{ .usage = problem },
            .value => |m| {
                switch (m.option) {
                    .url => {
                        if (url != null) return .{ .usage = "two URLs given" };
                        url = m.value;
                    },
                    .type => type_name = m.value,
                    .scope => if (try scopeProblem(arena, m.value)) |problem| return .{ .usage = problem },
                    .header => {
                        const pair = splitPair(m.value) orelse
                            return .{ .usage = try std.fmt.allocPrint(arena, "--header '{s}' is not <name>=<value> or \"<name>: <value>\"", .{m.value}) };
                        if (!validHeaderName(pair.name)) return .{ .usage = try std.fmt.allocPrint(arena, "'{s}' is not a valid header name", .{pair.name}) };
                        if (std.mem.indexOfAny(u8, pair.value, "\r\n\x00") != null) return .{ .usage = "a header value cannot contain a line break" };
                        for (headers.items) |other| if (std.ascii.eqlIgnoreCase(other.name, pair.name))
                            return .{ .usage = try std.fmt.allocPrint(arena, "header '{s}' given twice", .{pair.name}) };
                        try headers.append(arena, pair);
                    },
                    .env => {
                        const eq = std.mem.indexOfScalar(u8, m.value, '=') orelse
                            return .{ .usage = try std.fmt.allocPrint(arena, "--env '{s}' is not <name>=<value>", .{m.value}) };
                        const pair: mcp_config.KeyValue = .{ .name = m.value[0..eq], .value = m.value[eq + 1 ..] };
                        if (pair.name.len == 0) return .{ .usage = "--env needs a variable name before =" };
                        for (env.items) |other| if (std.mem.eql(u8, other.name, pair.name))
                            return .{ .usage = try std.fmt.allocPrint(arena, "variable '{s}' given twice", .{pair.name}) };
                        try env.append(arena, pair);
                    },
                    .bearer => bearer = m.value,
                    .client_id => client_id = m.value,
                    .callback_port => callback_port = std.fmt.parseInt(u16, m.value, 10) catch
                        return .{ .usage = try std.fmt.allocPrint(arena, "--callback-port '{s}' is not a port number", .{m.value}) },
                    .client_secret => return .{ .usage = "--client-secret is not stored: metacodes logs in as a public client with PKCE (give --client-id, or none for dynamic registration)" },
                }
                continue;
            },
        };
        if (arg.len > 1 and arg[0] == '-') return .{ .usage = try std.fmt.allocPrint(arena, "unknown option '{s}'", .{arg}) };
        if (name == null) {
            name = arg;
            continue;
        }
        if (url == null and command == null and std.mem.indexOf(u8, arg, "://") != null) {
            url = arg;
            continue;
        }
        if (url == null and command == null) {
            command = args[index..];
            break;
        }
        return .{ .usage = try std.fmt.allocPrint(arena, "unexpected argument '{s}'", .{arg}) };
    }

    request.name = name orelse return .{ .usage = "missing the server name" };
    if (!mcp_config.validServerName(request.name))
        return .{ .usage = try std.fmt.allocPrint(arena, "'{s}' is not a valid server name (letters, digits and _ - . : @ /)", .{request.name}) };
    if (url != null and command != null) return .{ .usage = "give either a URL or a command, not both" };
    if (url) |server_url| {
        const wire: mcp_config.HttpWire = if (type_name) |t|
            if (std.ascii.eqlIgnoreCase(t, "http") or std.ascii.eqlIgnoreCase(t, "streamable-http") or std.ascii.eqlIgnoreCase(t, "streamable_http"))
                .streamable
            else if (std.ascii.eqlIgnoreCase(t, "sse"))
                .legacy_sse
            else
                return .{ .usage = try std.fmt.allocPrint(arena, "transport '{s}' does not fit a URL (http or sse)", .{t}) }
        else
            .streamable;
        if (!validServerUrl(server_url))
            return .{ .usage = try std.fmt.allocPrint(arena, "'{s}' is not an http:// or https:// URL", .{server_url}) };
        if (env.items.len != 0) return .{ .usage = "--env sets a command server's environment; an HTTP server takes --header" };
        request.spec = .{ .entry = .{ .url = .{
            .url = server_url,
            .wire = wire,
            .headers = headers.items,
            .bearer_token_env_var = bearer,
            .oauth_client_id = client_id,
            .oauth_callback_port = callback_port,
        } } };
        return .{ .ok = request };
    }
    const argv = command orelse return .{ .usage = "give the server a URL (--url <url>), or its command (after --)" };
    if (argv.len == 0 or argv[0].len == 0) return .{ .usage = "a command must follow --" };
    if (type_name) |t| if (!std.ascii.eqlIgnoreCase(t, "stdio"))
        return .{ .usage = try std.fmt.allocPrint(arena, "transport '{s}' needs a URL; a command server is stdio", .{t}) };
    if (headers.items.len != 0) return .{ .usage = "--header is for an HTTP server (give a URL)" };
    if (bearer != null or client_id != null or callback_port != null) return .{ .usage = "--bearer-token-env-var, --client-id and --callback-port are for an HTTP server (give a URL)" };
    request.spec = .{ .entry = .{ .command = .{
        .command = argv[0],
        .args = argv[1..],
        .env = env.items,
    } } };
    return .{ .ok = request };
}

pub fn parseRemove(arena: std.mem.Allocator, args: []const []const u8) error{OutOfMemory}!AddParse {
    var name: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelp(arg)) return .help;
        if (try takeOption(arena, args, &index)) |option| switch (option) {
            .usage => |problem| return .{ .usage = problem },
            .value => |m| {
                if (m.option != .scope) return .{ .usage = try std.fmt.allocPrint(arena, "'{s}' is not a remove option", .{arg}) };
                if (try scopeProblem(arena, m.value)) |problem| return .{ .usage = problem };
                continue;
            },
        };
        if (arg.len > 1 and arg[0] == '-') return .{ .usage = try std.fmt.allocPrint(arena, "unknown option '{s}'", .{arg}) };
        if (name != null) return .{ .usage = "mcp remove takes one server name" };
        name = arg;
    }
    return .{ .ok = .{ .name = name orelse return .{ .usage = "mcp remove takes one server name" }, .spec = .{ .json = "" } } };
}

pub fn parseAddJson(arena: std.mem.Allocator, args: []const []const u8) error{OutOfMemory}!AddParse {
    var request: AddRequest = .{ .name = "", .spec = undefined };
    var positional: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isHelp(arg)) return .help;
        if (std.mem.eql(u8, arg, "--force")) {
            request.force = true;
        } else if (std.mem.eql(u8, arg, "--no-check")) {
            request.check = false;
        } else if (try takeOption(arena, args, &index)) |option| switch (option) {
            .usage => |problem| return .{ .usage = problem },
            .value => |m| {
                if (m.option != .scope) return .{ .usage = try std.fmt.allocPrint(arena, "add-json takes the whole entry as JSON; '{s}' is not an add-json option", .{arg}) };
                if (try scopeProblem(arena, m.value)) |problem| return .{ .usage = problem };
            },
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] == '-') {
            return .{ .usage = try std.fmt.allocPrint(arena, "unknown option '{s}'", .{arg}) };
        } else try positional.append(arena, arg);
    }
    if (positional.items.len != 2) return .{ .usage = "add-json takes a server name and its entry as one JSON object" };
    request.name = positional.items[0];
    if (!mcp_config.validServerName(request.name))
        return .{ .usage = try std.fmt.allocPrint(arena, "'{s}' is not a valid server name (letters, digits and _ - . : @ /)", .{request.name}) };
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, positional.items[1], .{}) catch
        return .{ .usage = "the entry is not valid JSON" };
    if (value != .object) return .{ .usage = "the entry is not a JSON object" };
    request.spec = .{ .json = positional.items[1] };
    return .{ .ok = request };
}

const Option = enum { url, type, scope, header, env, bearer, client_id, callback_port, client_secret };

const OPTIONS = [_]struct { flags: []const []const u8, option: Option }{
    .{ .flags = &.{"--url"}, .option = .url },
    .{ .flags = &.{ "--type", "--transport", "-t" }, .option = .type },
    .{ .flags = &.{ "--scope", "-s" }, .option = .scope },
    .{ .flags = &.{ "--header", "-H" }, .option = .header },
    .{ .flags = &.{ "--env", "-e" }, .option = .env },
    .{ .flags = &.{ "--bearer-token-env-var", "--bearer_token_env_var" }, .option = .bearer },
    .{ .flags = &.{"--client-id"}, .option = .client_id },
    .{ .flags = &.{"--callback-port"}, .option = .callback_port },
    .{ .flags = &.{"--client-secret"}, .option = .client_secret },
};

const TakenOption = union(enum) {
    value: struct { option: Option, value: []const u8 },
    usage: []const u8,
};

fn takeOption(arena: std.mem.Allocator, args: []const []const u8, index: *usize) error{OutOfMemory}!?TakenOption {
    const arg = args[index.*];
    for (OPTIONS) |candidate| for (candidate.flags) |flag| {
        if (std.mem.eql(u8, arg, flag)) {
            if (index.* + 1 == args.len) return .{ .usage = try std.fmt.allocPrint(arena, "{s} needs a value", .{flag}) };
            index.* += 1;
            return .{ .value = .{ .option = candidate.option, .value = args[index.*] } };
        }
        if (std.mem.startsWith(u8, arg, flag) and arg.len > flag.len and arg[flag.len] == '=')
            return .{ .value = .{ .option = candidate.option, .value = arg[flag.len + 1 ..] } };
    };
    return null;
}

fn scopeProblem(arena: std.mem.Allocator, scope: []const u8) error{OutOfMemory}!?[]const u8 {
    if (std.mem.eql(u8, scope, "user") or std.mem.eql(u8, scope, "local")) return null;
    if (std.mem.eql(u8, scope, "project"))
        return "mcp add writes this install's config.json; a project server goes into .mcp.json in the project (metacodes reads it once approved)";
    return try std.fmt.allocPrint(arena, "unknown scope '{s}' (user, local or project)", .{scope});
}

fn splitPair(text: []const u8) ?mcp_config.KeyValue {
    const at = std.mem.indexOfAny(u8, text, "=:") orelse return null;
    return .{
        .name = std.mem.trim(u8, text[0..at], " "),
        .value = std.mem.trim(u8, text[at + 1 ..], " "),
    };
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null) return false;
    }
    return true;
}

fn validServerUrl(url: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return false;
    const scheme = url[0..scheme_end];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return false;
    if (url.len == scheme_end + 3) return false;
    if (std.mem.indexOf(u8, url, "${") != null) return true;
    const uri = std.Uri.parse(url) catch return false;
    const host = uri.host orelse return false;
    return !host.isEmpty();
}

const Elsewhere = struct { path: []const u8, label: []const u8 };

fn configuredElsewhere(resolved: mcp_config.Resolved, name: []const u8) ?Elsewhere {
    for (resolved.servers) |server| {
        if (!std.mem.eql(u8, server.name, name)) continue;
        return switch (server.origin) {
            .metacodes, .metacodes_legacy => null,
            else => .{ .path = server.origin_path, .label = server.origin.label() },
        };
    }
    for (resolved.pending) |pending| {
        if (std.mem.eql(u8, pending.name, name)) return .{ .path = pending.origin_path, .label = "Claude Code project, awaiting approval" };
    }
    return null;
}

fn configPath(arena: std.mem.Allocator, state_root: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ state_root, "config.json" });
}

fn describeEditError(err: mcp_config_edit.EditError) []const u8 {
    return switch (err) {
        error.InvalidJson => "it is not valid JSON; fix it first",
        error.NotAnObject => "it (or its \"mcpServers\") is not a JSON object; fix it first",
        error.LockBusy => "another process is writing it; try again",
        error.PathTooLong => "its path is too long",
        error.ReadFailed => "it could not be read",
        error.WriteFailed => "it could not be written",
        error.OutOfMemory => "out of memory",
    };
}

const Reading = struct {
    server: ?mcp_config.Server = null,
    disabled: bool = false,
    problems: []const []const u8 = &.{},
};

fn readEntry(arena: std.mem.Allocator, path: []const u8, name: []const u8, entry_json: []const u8) error{OutOfMemory}!Reading {
    var document: std.Io.Writer.Allocating = .init(arena);
    var js: std.json.Stringify = .{ .writer = &document.writer };
    js.beginObject() catch return error.OutOfMemory;
    js.objectField(mcp_config_edit.SERVERS_KEY) catch return error.OutOfMemory;
    js.beginObject() catch return error.OutOfMemory;
    js.objectField(name) catch return error.OutOfMemory;
    js.print("{s}", .{entry_json}) catch return error.OutOfMemory;
    js.endObject() catch return error.OutOfMemory;
    js.endObject() catch return error.OutOfMemory;
    const resolved = try mcp_config.resolve(arena, .{
        .metacodes_config = .{ .path = path, .bytes = document.written() },
    }, .{ .cwd = "", .workspace_root = "", .env = try mcp_config.Environment.fromProcess(arena) });
    var reading: Reading = .{};
    for (resolved.servers) |server| {
        if (std.mem.eql(u8, server.name, name)) reading.server = server;
    }
    for (resolved.disabled) |disabled| {
        if (std.mem.eql(u8, disabled, name)) reading.disabled = true;
    }
    var problems: std.ArrayList([]const u8) = .empty;
    for (resolved.problems) |problem| {
        if (problem.server.len == 0 or std.mem.eql(u8, problem.server, name)) try problems.append(arena, problem.message);
    }
    reading.problems = problems.items;
    return reading;
}

fn add(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, state_root: []const u8, request: AddRequest, command: []const u8) u8 {
    const name = request.name;
    const path = configPath(arena, state_root) catch return 1;
    const entry_json = switch (request.spec) {
        .entry => |entry| entry.toJson(arena) catch return 1,
        .json => |json| json,
    };
    const reading = readEntry(arena, path, name, entry_json) catch return 1;
    if (reading.server == null and !reading.disabled) {
        std.debug.print("error: no session could use this entry for '{s}'", .{name});
        for (reading.problems) |problem| std.debug.print("; {s}", .{problem});
        std.debug.print("\n", .{});
        return 2;
    }
    const resolved = resolveServers(arena, state_root) catch null;
    const elsewhere = if (resolved) |r| configuredElsewhere(r, name) else null;
    if (elsewhere) |other| if (!request.force) {
        std.debug.print("error: an MCP server named '{s}' is already configured in {s} ({s}); pass --force to define it in {s} instead, which takes precedence\n", .{ name, other.path, other.label, path });
        return 1;
    };
    const outcome = mcp_config_edit.change(gpa, path, name, .{ .put = .{ .entry_json = entry_json, .replace = request.force } }) catch |err| {
        std.debug.print("error: could not update {s}: {s}\n", .{ path, describeEditError(err) });
        return 1;
    };
    if (!outcome.written) {
        std.debug.print("error: an MCP server named '{s}' is already configured in {s}{s}; pass --force to replace it\n", .{
            name,
            path,
            if (outcome.before.servers) "" else " (legacy \"mcp_servers\" array)",
        });
        return 1;
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    addReport(w, io, arena, state_root, path, request, reading, outcome, elsewhere, command) catch return 1;
    stdoutWrite(out.written());
    return 0;
}

fn addReport(
    w: *std.Io.Writer,
    io: std.Io,
    arena: std.mem.Allocator,
    state_root: []const u8,
    path: []const u8,
    request: AddRequest,
    reading: Reading,
    outcome: mcp_config_edit.Outcome,
    elsewhere: ?Elsewhere,
    command: []const u8,
) std.Io.Writer.Error!void {
    const name = request.name;
    try w.print("{s} MCP server '{s}' ", .{ if (outcome.before.servers) "Replaced" else "Added", name });
    if (reading.server) |server| switch (server.transport) {
        .http => |http| try w.print("({s} {s})", .{ switch (http.wire) {
            .streamable => "http",
            .legacy_sse => "sse",
        }, http.url }),
        .stdio => |stdio| try w.print("(stdio: {s})", .{stdio.command}),
    } else try w.writeAll("(disabled)");
    try w.print(" in {s}.\n", .{path});
    for (reading.problems) |problem| try w.print("Note: {s}.\n", .{problem});
    if (outcome.before.legacy) try w.print("It takes precedence over the '{s}' entry of the legacy \"mcp_servers\" array there.\n", .{name});
    if (elsewhere) |other| try w.print("It takes precedence over '{s}' in {s} ({s}).\n", .{ name, other.path, other.label });
    const server = reading.server orelse return;
    if (request.check) {
        std.debug.print("Checking '{s}'…\n", .{name});
        if (checkServers(arena, io, state_root, .{ .one = name })) |startup| {
            defer startup.cancelAndJoin();
            for (startup.jobs) |*job| {
                if (job.result == .kept) continue;
                try w.writeAll("Checked: ");
                try writeOutcome(w, arena, job, command);
                try w.writeAll(".\n");
            }
        }
    } else switch (server.transport) {
        .http => |http| if (http.bearer_token_env_var == null and !sendsAuthorization(http.headers) and !sendsAuthorization(http.env_headers))
            try w.print("If the server requires authorization, log in next: {s} mcp login {s}\n", .{ command, name }),
        .stdio => {},
    }
    try w.print("New sessions connect it; in a running session, run /mcp reconnect {s}\n", .{name});
}

fn sendsAuthorization(headers: []const mcp_config.KeyValue) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) return true;
    }
    return false;
}

fn remove(gpa: std.mem.Allocator, arena: std.mem.Allocator, state_root: []const u8, name: []const u8, command: []const u8) u8 {
    const path = configPath(arena, state_root) catch return 1;
    const before = resolveServers(arena, state_root) catch null;
    const removed_url: ?[]const u8 = if (before) |r| for (r.servers) |server| {
        if (!std.mem.eql(u8, server.name, name) or server.origin != .metacodes) continue;
        break switch (server.transport) {
            .http => |http| http.url,
            .stdio => null,
        };
    } else null else null;

    const outcome = mcp_config_edit.change(gpa, path, name, .remove) catch |err| {
        std.debug.print("error: could not update {s}: {s}\n", .{ path, describeEditError(err) });
        return 1;
    };
    if (!outcome.written) {
        if (outcome.before.legacy) {
            std.debug.print("error: '{s}' is an entry of the legacy \"mcp_servers\" array in {s}; `mcp remove` edits only \"mcpServers\", so delete that entry by hand\n", .{ name, path });
        } else if (if (before) |r| configuredElsewhere(r, name) else null) |other| {
            std.debug.print("error: '{s}' is configured in {s} ({s}), which metacodes does not edit; to turn it off for metacodes, add \"{s}\": {{\"enabled\": false}} to \"mcpServers\" in {s}\n", .{ name, other.path, other.label, name, path });
        } else {
            std.debug.print("error: no MCP server named '{s}' in {s} (see `{s} mcp list`)\n", .{ name, path, command });
        }
        return 1;
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print("Removed MCP server '{s}' from {s}.\n", .{ name, path }) catch return 1;
    const after = resolveServers(arena, state_root) catch null;
    const still: ?mcp_config.Server = if (after) |r| for (r.servers) |server| {
        if (std.mem.eql(u8, server.name, name)) break server;
    } else null else null;
    if (still) |server| w.print("'{s}' is still configured in {s} ({s}), which applies from now on.\n", .{ name, server.origin_path, server.origin.label() }) catch return 1;
    if (removed_url) |url| {
        const kept = if (still) |server| switch (server.transport) {
            .http => |http| std.mem.eql(u8, http.url, url),
            .stdio => false,
        } else false;
        if (!kept) {
            const login_path = mcp_oauth.storePath(gpa, state_root, name, url) catch return 1;
            defer gpa.free(login_path);
            if (mcp_oauth.removeRecord(gpa, login_path) catch false)
                w.print("Its stored OAuth login is removed too.\n", .{}) catch return 1;
        }
    }
    w.writeAll("New sessions no longer connect it; a running session keeps it until it ends.\n") catch return 1;
    stdoutWrite(out.written());
    return 0;
}

const testing = std.testing;

fn expectUsage(args: []const []const u8, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    switch (try parseAdd(arena.allocator(), args)) {
        .ok, .help => return error.TestExpectedUsageError,
        .usage => |problem| {
            errdefer std.debug.print("usage problem: {s}\n", .{problem});
            try testing.expect(std.mem.indexOf(u8, problem, needle) != null);
        },
    }
}

test "parseAdd: an HTTP server with headers in either form, sse, --force and --no-check" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const http = (try parseAdd(a, &.{ "suno", "--url", "https://mcp.suno.example/mcp", "--header", "Authorization=Bearer ${SUNO_TOKEN}", "-H", "X-Org: acme=1" })).ok;
    try testing.expectEqualStrings("suno", http.name);
    try testing.expect(!http.force and http.check);
    const url = http.spec.entry.url;
    try testing.expectEqualStrings("https://mcp.suno.example/mcp", url.url);
    try testing.expectEqual(mcp_config.HttpWire.streamable, url.wire);
    try testing.expectEqual(@as(usize, 2), url.headers.len);
    try testing.expectEqualStrings("Bearer ${SUNO_TOKEN}", url.headers[0].value);
    try testing.expectEqualStrings("X-Org", url.headers[1].name);
    try testing.expectEqualStrings("acme=1", url.headers[1].value);
    const sse = (try parseAdd(a, &.{ "--force", "--no-check", "--type=sse", "--url=http://127.0.0.1:8080/sse", "linear" })).ok;
    try testing.expect(sse.force and !sse.check);
    try testing.expectEqualStrings("linear", sse.name);
    try testing.expectEqual(mcp_config.HttpWire.legacy_sse, sse.spec.entry.url.wire);
}

test "parseAdd: Claude Code's and Codex's spellings mean the same server" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const claude_http = (try parseAdd(a, &.{ "--transport", "http", "-s", "user", "suno", "https://mcp.suno.example/mcp", "--header", "X-Key: k" })).ok;
    try testing.expectEqualStrings("https://mcp.suno.example/mcp", claude_http.spec.entry.url.url);
    try testing.expectEqualStrings("k", claude_http.spec.entry.url.headers[0].value);
    try testing.expectEqual(mcp_config.HttpWire.legacy_sse, (try parseAdd(a, &.{ "-t", "SSE", "linear", "https://mcp.linear.example/sse" })).ok.spec.entry.url.wire);
    const claude_stdio = (try parseAdd(a, &.{ "fs", "-e", "ROOT=/srv", "npx", "-y", "@scope/server", "--force" })).ok;
    try testing.expectEqualStrings("npx", claude_stdio.spec.entry.command.command);
    try testing.expectEqual(@as(usize, 3), claude_stdio.spec.entry.command.args.len);
    try testing.expectEqualStrings("--force", claude_stdio.spec.entry.command.args[2]);
    try testing.expect(!claude_stdio.force);
    const codex = (try parseAdd(a, &.{ "docs", "--url", "https://docs.example/mcp", "--bearer-token-env-var", "DOCS_TOKEN" })).ok;
    try testing.expectEqualStrings("DOCS_TOKEN", codex.spec.entry.url.bearer_token_env_var.?);
    const oauth = (try parseAdd(a, &.{ "tracker", "https://t.example/mcp", "--client-id", "cli", "--callback-port=8765" })).ok;
    try testing.expectEqualStrings("cli", oauth.spec.entry.url.oauth_client_id.?);
    try testing.expectEqual(@as(?u16, 8765), oauth.spec.entry.url.oauth_callback_port);
    try testing.expect((try parseAdd(a, &.{ "suno", "--help" })) == .help);
}

test "parseAdd: a stdio server takes everything after -- as its command, --help included" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const request = (try parseAdd(arena.allocator(), &.{ "fs", "-e", "ROOT=/srv", "--", "npx", "-y", "@scope/server", "--url", "--help" })).ok;
    try testing.expectEqualStrings("npx", request.spec.entry.command.command);
    try testing.expectEqual(@as(usize, 4), request.spec.entry.command.args.len);
    try testing.expectEqualStrings("--help", request.spec.entry.command.args[3]);
    try testing.expectEqualStrings("ROOT", request.spec.entry.command.env[0].name);
}

test "parseAdd: what does not make one server is a usage error that says why" {
    try expectUsage(&.{}, "missing the server name");
    try expectUsage(&.{"suno"}, "give the server a URL");
    try expectUsage(&.{ "suno", "--url", "https://x/mcp", "--", "npx" }, "not both");
    try expectUsage(&.{ "suno", "https://x/mcp", "https://y/mcp" }, "unexpected argument 'https://y/mcp'");
    try expectUsage(&.{ "suno", "--url", "ftp://x/mcp" }, "not an http:// or https:// URL");
    try expectUsage(&.{ "suno", "--url", "https://" }, "not an http:// or https:// URL");
    try expectUsage(&.{ "suno", "--url" }, "--url needs a value");
    try expectUsage(&.{ "suno", "--url", "https://x/mcp", "--type", "stdio" }, "does not fit a URL");
    try expectUsage(&.{ "suno", "--url", "https://x/mcp", "--header", "NoSeparator" }, "is not <name>=<value>");
    try expectUsage(&.{ "suno", "--url", "https://x/mcp", "--header", "Bad Name=v" }, "not a valid header name");
    try expectUsage(&.{ "suno", "--url", "https://x/mcp", "-H", "A=1", "-H", "a: 2" }, "given twice");
    try expectUsage(&.{ "suno", "--url", "https://x/mcp", "--env", "K=V" }, "--header");
    try expectUsage(&.{ "suno", "--url", "https://x/mcp", "--client-secret", "s" }, "public client");
    try expectUsage(&.{ "suno", "--url", "https://x/mcp", "--callback-port", "port" }, "not a port number");
    try expectUsage(&.{ "suno", "-s", "project", "--url", "https://x/mcp" }, ".mcp.json");
    try expectUsage(&.{ "fs", "--header", "A=1", "--", "npx" }, "--header is for an HTTP server");
    try expectUsage(&.{ "fs", "--bearer-token-env-var", "T", "--", "npx" }, "are for an HTTP server");
    try expectUsage(&.{ "fs", "--type", "http", "--", "npx" }, "needs a URL");
    try expectUsage(&.{ "fs", "--" }, "a command must follow --");
    try expectUsage(&.{ "bad name", "--", "npx" }, "not a valid server name");
    try expectUsage(&.{ "fs", "--verbose", "--", "npx" }, "unknown option '--verbose'");
}

test "parseAddJson and parseRemove: Claude Code's add-json and remove forms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = (try parseAddJson(a, &.{ "suno", "{\"type\":\"http\",\"url\":\"https://x/mcp\",\"unknownKey\":1}", "-s", "user" })).ok;
    try testing.expectEqualStrings("suno", json.name);
    try testing.expect(std.mem.indexOf(u8, json.spec.json, "unknownKey") != null);
    try testing.expectEqualStrings("the entry is not valid JSON", (try parseAddJson(a, &.{ "suno", "{" })).usage);
    try testing.expectEqualStrings("the entry is not a JSON object", (try parseAddJson(a, &.{ "suno", "[]" })).usage);
    try testing.expect((try parseAddJson(a, &.{"suno"})) == .usage);
    try testing.expectEqualStrings("suno", (try parseRemove(a, &.{ "suno", "--scope", "local" })).ok.name);
    try testing.expect((try parseRemove(a, &.{ "a", "b" })) == .usage);
    try testing.expect((try parseRemove(a, &.{"--help"})) == .help);
}

test "a URL with ${VAR} placeholders is checked for its scheme only" {
    try testing.expect(validServerUrl("https://${HOST}/mcp"));
    try testing.expect(validServerUrl("HTTPS://mcp.example.com"));
    try testing.expect(!validServerUrl("${URL}"));
    try testing.expect(!validServerUrl("mcp.example.com/mcp"));
}

test "an entry is read as sessions read it: unset variables are notes, a bad entry is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const http = try readEntry(a, "/state/config.json", "x", "{\"type\":\"http\",\"url\":\"https://${METACODES_TEST_SURELY_UNSET_HOST}/mcp\",\"futureKey\":true}");
    try testing.expect(http.server != null);
    try testing.expect(std.mem.indexOf(u8, http.problems[0], "METACODES_TEST_SURELY_UNSET_HOST") != null);
    const bad = try readEntry(a, "/state/config.json", "x", "{\"type\":\"http\"}");
    try testing.expect(bad.server == null and !bad.disabled);
    try testing.expect(std.mem.indexOf(u8, bad.problems[0], "no url") != null);
    try testing.expect((try readEntry(a, "/state/config.json", "x", "{\"enabled\":false}")).disabled);
}
