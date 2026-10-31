//! MCP server startup: the connect work that runs on worker threads, kept
//! apart from what publishes its outcome.
//!
//! Every configured server connects on a thread of its own (Claude Code and
//! Codex both connect in parallel). A worker touches only its own `Job` and
//! the counters in `Status`: it never sees the dynamic tool registry, the
//! MCP session list, the tool definitions or the system prompt. The App
//! registers the connected clients and builds those from the outcomes after
//! `join`, on the thread that owns them (`App.publishMcpServers`), so a
//! worker can never move memory another thread points into, and the tool
//! list a provider sees is fixed by the outcomes, never by when they arrived.

const std = @import("std");
const pfs = @import("platform").fs;
const mcp_config = @import("../mcp/config.zig");
const mcp_launch = @import("../mcp/launch.zig");
const mcp_transport = @import("../mcp/transport.zig");
const McpClient = @import("../mcp/client.zig").McpClient;
const mcp_oauth = @import("../mcp/oauth.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const util_time = @import("../util/time.zig");

/// What a renderer on any thread may read about the startup: counters only,
/// never a pointer into the startup's memory. Lives in the App.
pub const Status = struct {
    /// Servers being started; set before the first worker runs.
    total: std.atomic.Value(u32) = .init(0),
    /// Servers whose connect has finished, whatever the outcome.
    settled: std.atomic.Value(u32) = .init(0),
    /// Settled without a client (auth-required ones included).
    failed: std.atomic.Value(u32) = .init(0),
    /// Of `failed`: the server answered 401/403.
    needs_auth: std.atomic.Value(u32) = .init(0),
    /// The outcomes are registered and the tool surface reflects them.
    published: std.atomic.Value(bool) = .init(false),
    /// The user has seen the failures (`/mcp`, or a turn started).
    acknowledged: std.atomic.Value(bool) = .init(false),

    pub const Snapshot = struct {
        total: u32,
        settled: u32,
        failed: u32,
        needs_auth: u32,
        published: bool,
        acknowledged: bool,

        pub fn connecting(self: Snapshot) bool {
            return self.settled < self.total;
        }
    };

    pub fn snapshot(self: *const Status) Snapshot {
        return .{
            .total = self.total.load(.acquire),
            .settled = self.settled.load(.acquire),
            .failed = self.failed.load(.acquire),
            .needs_auth = self.needs_auth.load(.acquire),
            .published = self.published.load(.acquire),
            .acknowledged = self.acknowledged.load(.acquire),
        };
    }
};

/// The footer's MCP line: progress while servers connect, then the
/// failures until the user has looked (`/mcp`) or started a turn — the
/// shape of Claude Code's "1 MCP server failed · /mcp" notice.
pub const Notice = struct {
    text: []const u8,
    tone: enum { progress, warning, failure },
};

pub fn notice(s: Status.Snapshot, buf: []u8) ?Notice {
    if (s.total == 0) return null;
    if (s.connecting()) {
        const text = std.fmt.bufPrint(buf, "connecting to MCP servers ({d}/{d})", .{ s.settled, s.total }) catch return null;
        return .{ .text = text, .tone = .progress };
    }
    if (s.acknowledged or s.failed == 0) return null;
    const auth = @min(s.needs_auth, s.failed);
    const other = s.failed - auth;
    var w: std.Io.Writer = .fixed(buf);
    if (other != 0) w.print("{d} MCP {s} failed", .{ other, if (other == 1) "server" else "servers" }) catch return null;
    if (auth != 0) w.print("{s}{d} MCP {s} auth", .{
        if (other != 0) ", " else "",
        auth,
        if (auth == 1) "server needs" else "servers need",
    }) catch return null;
    w.writeAll(" · /mcp") catch return null;
    return .{ .text = w.buffered(), .tone = if (other != 0) .failure else .warning };
}

/// One server's connect, run on its own thread.
pub const Job = struct {
    server: mcp_config.Server,
    io: std.Io,
    launch: ?mcp_launch.Launch = null,
    http_headers: []const mcp_transport.Header = &.{},
    /// Where a stored OAuth login is looked up (`metacodes mcp login`);
    /// empty when the configuration authenticates the server itself.
    oauth_state_root: []const u8 = "",
    log_fd: ?c_int = null,
    log_path: []const u8 = "",
    /// Written by the worker before `state` turns `.settled`; read by the
    /// owner thread only after it has seen `.settled` (or after `join`).
    result: Result = .pending,
    state: std.atomic.Value(State) = .init(.pending),
    started_ms: i64 = 0,
    /// The startup this job belongs to (its cancel signal and counters).
    owner: *Startup = undefined,

    pub const State = enum(u8) { pending, settled };

    pub const Result = union(enum) {
        pending,
        failed: anyerror,
        connected: struct { client: McpClient, tools_json: []u8 },
    };

    fn run(job: *Job) void {
        job.connect();
        job.settle();
    }

    fn connect(job: *Job) void {
        // c_allocator: the client allocates and frees per request for the
        // whole session; an arena could never reclaim that.
        const abort: *const AbortSignal = &job.owner.cancel;
        const options: @import("../mcp/client.zig").ConnectOptions = .{
            .spawn = .{ .argv = &.{} },
            .startup_timeout_ms = job.server.startup_timeout_ms,
            .request_timeout_ms = job.server.tool_timeout_ms,
            .abort = abort,
        };
        var client = switch (job.server.transport) {
            .stdio => blk: {
                const launch = job.launch orelse {
                    job.result = .{ .failed = error.McpLaunchUnavailable };
                    return;
                };
                var stdio_options = options;
                stdio_options.spawn = .{
                    .argv = launch.argv,
                    .env = launch.env,
                    .cwd = launch.cwd,
                    .stderr_fd = job.log_fd,
                };
                break :blk McpClient.connectWith(std.heap.c_allocator, stdio_options);
            },
            .http => |http| blk: {
                // A stored login is read on this worker: it may be refreshed
                // (a network round trip) before the first request.
                const auth = if (job.oauth_state_root.len != 0)
                    mcp_oauth.TokenSource.load(std.heap.c_allocator, job.io, job.oauth_state_root, job.server.name, http.url) catch |err| no_login: {
                        @import("../util/log.zig").warn("mcp", "server '{s}': stored OAuth login unreadable ({s}); connecting without it", .{ job.server.name, @errorName(err) });
                        break :no_login null;
                    }
                else
                    null;
                break :blk McpClient.connectHttp(std.heap.c_allocator, .{
                    .io = job.io,
                    .url = http.url,
                    .headers = job.http_headers,
                    .wire = http.wire,
                    .auth = auth,
                }, options);
            },
        } catch |err| {
            job.result = .{ .failed = err };
            return;
        };
        client.transport.setDeadline(util_time.nowMs() + job.server.startup_timeout_ms);
        const tools_json = client.listToolsAbortable(abort) catch |err| {
            client.close();
            job.result = .{ .failed = err };
            return;
        };
        client.transport.setDeadline(null);
        job.result = .{ .connected = .{ .client = client, .tools_json = tools_json } };
    }

    /// Publish the outcome: counters first, then the state the owner reads.
    fn settle(job: *Job) void {
        const status = job.owner.status;
        switch (job.result) {
            .pending => unreachable,
            .connected => {},
            .failed => |err| {
                _ = status.failed.fetchAdd(1, .release);
                if (err == error.McpAuthRequired) _ = status.needs_auth.fetchAdd(1, .release);
            },
        }
        job.state.store(.settled, .release);
        _ = status.settled.fetchAdd(1, .release);
    }

    pub fn isSettled(job: *const Job) bool {
        return job.state.load(.acquire) == .settled;
    }
};

pub const Startup = struct {
    jobs: []Job,
    threads: []?std.Thread,
    pending: []const mcp_config.Pending,
    disabled: []const []const u8,
    problems: []const mcp_config.Problem,
    /// Stops every connect still in flight (teardown only; never the
    /// session's own abort, which a turn interrupt resets).
    cancel: AbortSignal = AbortSignal.init(),
    status: *Status,

    pub const Inputs = struct {
        io: std.Io,
        state_root: []const u8,
        home: []const u8,
        cwd: []const u8,
        workspace_root: []const u8,
        codex_home: []const u8,
    };

    /// Resolve the configuration, prepare every server and start the
    /// workers. Everything lives in `arena`, which must outlive the startup
    /// (the App's MCP arena). With no server configured the startup has no
    /// jobs and is settled at once.
    pub fn begin(arena: std.mem.Allocator, status: *Status, inputs: Inputs) !*Startup {
        const log = @import("../util/log.zig");
        const environment = try mcp_config.Environment.fromProcess(arena);
        const resolved = try mcp_config.load(arena, .{
            .state_root = inputs.state_root,
            .home = inputs.home,
            .cwd = inputs.cwd,
            .workspace_root = if (inputs.workspace_root.len != 0) inputs.workspace_root else inputs.cwd,
            .codex_home = inputs.codex_home,
            .env = environment,
        });
        for (resolved.problems) |problem| {
            log.warn("mcp", "{s} ({s}){s}{s}: {s}", .{
                problem.origin_path,
                problem.origin.label(),
                if (problem.server.len != 0) " server " else "",
                problem.server,
                problem.message,
            });
        }
        for (resolved.pending) |pending| {
            if (pending.reason == .needs_approval)
                log.warn("mcp", "project server '{s}' in {s} awaits approval (add it to enabledMcpjsonServers)", .{ pending.name, pending.origin_path });
        }

        const startup = try arena.create(Startup);
        startup.* = .{
            .jobs = try arena.alloc(Job, resolved.servers.len),
            .threads = try arena.alloc(?std.Thread, resolved.servers.len),
            .pending = resolved.pending,
            .disabled = resolved.disabled,
            .problems = resolved.problems,
            .status = status,
        };
        const started = util_time.nowMs();
        for (resolved.servers, startup.jobs) |server, *job| {
            job.* = .{ .server = server, .io = inputs.io, .owner = startup, .started_ms = started };
            switch (server.transport) {
                .stdio => |stdio| {
                    job.launch = mcp_launch.prepare(arena, stdio, environment, inputs.cwd) catch |err| {
                        job.result = .{ .failed = if (err == error.CommandNotFound) error.McpCommandNotFound else err };
                        continue;
                    };
                    job.log_path = openLog(arena, inputs.state_root, server.name, &job.log_fd);
                },
                .http => |http| {
                    job.http_headers = httpHeaders(arena, http, environment) catch |err| {
                        job.result = .{ .failed = err };
                        continue;
                    };
                    // Configured credentials win over a stored login.
                    if (!hasAuthorization(job.http_headers)) job.oauth_state_root = try arena.dupe(u8, inputs.state_root);
                },
            }
        }
        status.total.store(@intCast(startup.jobs.len), .release);
        // A server that failed its preparation is settled before any thread
        // runs; a thread that cannot be spawned runs its connect inline.
        for (startup.jobs, startup.threads) |*job, *thread| {
            thread.* = null;
            if (job.result != .pending) {
                job.settle();
                continue;
            }
            thread.* = std.Thread.spawn(.{}, Job.run, .{job}) catch blk: {
                job.run();
                break :blk null;
            };
        }
        return startup;
    }

    /// Every server has reported (the workers may still be exiting).
    pub fn settled(self: *const Startup) bool {
        return self.status.settled.load(.acquire) >= self.jobs.len;
    }

    /// Wait for every worker. Idempotent; owner thread only.
    pub fn join(self: *Startup) void {
        for (self.threads) |*maybe| if (maybe.*) |thread| {
            thread.join();
            maybe.* = null;
        };
        for (self.jobs) |*job| if (job.log_fd) |fd| {
            _ = pfs.close(fd);
            job.log_fd = null;
        };
    }

    /// Teardown before anything was published: stop the connects still in
    /// flight, wait for the workers, and close the clients nobody took.
    pub fn cancelAndJoin(self: *Startup) void {
        self.cancel.abort(.user_interrupt);
        self.join();
        for (self.jobs) |*job| switch (job.result) {
            .connected => |*connected| {
                connected.client.close();
                std.heap.c_allocator.free(connected.tools_json);
                job.result = .{ .failed = error.Aborted };
            },
            else => {},
        };
    }
};

/// Why a server did not connect, for `/mcp` and the log.
pub fn failureDetail(err: anyerror, job: *const Job) []const u8 {
    return switch (err) {
        error.McpCommandNotFound => "command not found on the server's PATH",
        error.SpawnFailed => "could not start the command",
        error.Timeout, error.McpRequestTimeout => "no response before the startup timeout",
        error.McpServerCrashed, error.Eof => if (job.log_path.len != 0) "server exited; see its log" else "server exited",
        error.UnsupportedProtocolVersion => "server speaks no supported MCP revision",
        error.McpAuthRequired => "the server requires authorization (401/403); run `metacodes mcp login <server>`, or configure a bearer token or headers",
        error.McpNotEventStream => "the URL did not answer with an event stream (is it a Streamable HTTP server? use type \"http\")",
        error.McpEndpointOriginMismatch => "the SSE endpoint event names another origin; refused",
        error.McpSessionExpired => "the server no longer knows this session",
        error.McpStreamClosed => "the server closed its SSE event stream; a new session reconnects",
        error.McpBearerTokenUnset => "bearer_token_env_var is not set",
        error.McpConnectFailed => "could not connect to the server URL",
        error.McpInvalidUrl => "invalid server URL",
        error.McpServerError => "the server answered with an HTTP 5xx error",
        error.McpRedirected => "the server URL redirects (3xx); requests carry the configured headers and do not follow redirects, so configure the URL it redirects to",
        error.Aborted => "connection canceled",
        else => @errorName(err),
    };
}

pub fn hasAuthorization(headers: []const mcp_transport.Header) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) return true;
    }
    return false;
}

/// Static headers, `Authorization: Bearer $bearer_token_env_var` and
/// `env_http_headers` for an HTTP server. A missing bearer variable is an
/// error (Codex); a missing header variable drops that header.
pub fn httpHeaders(
    arena: std.mem.Allocator,
    http: mcp_config.Http,
    environment: mcp_config.Environment,
) ![]const mcp_transport.Header {
    var headers: std.ArrayList(mcp_transport.Header) = .empty;
    for (http.headers) |header| try headers.append(arena, .{ .name = header.name, .value = header.value });
    for (http.env_headers) |header| {
        const value = environment.get(header.value) orelse continue;
        if (value.len == 0) continue;
        try headers.append(arena, .{ .name = header.name, .value = value });
    }
    if (http.bearer_token_env_var) |variable| {
        const token = environment.get(variable) orelse return error.McpBearerTokenUnset;
        if (token.len == 0) return error.McpBearerTokenUnset;
        try headers.append(arena, .{ .name = "Authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{token}) });
    }
    return headers.toOwnedSlice(arena);
}

/// `<state root>/logs/mcp/<server>.log`, truncated per session: the
/// server's stderr (startup errors, crashes) lands where `/mcp` points.
fn openLog(arena: std.mem.Allocator, state_root: []const u8, server: []const u8, fd_out: *?c_int) []const u8 {
    fd_out.* = null;
    if (state_root.len == 0) return "";
    const name = mcp_launch.logFileName(arena, server) catch return "";
    const dir = std.fs.path.join(arena, &.{ state_root, "logs", "mcp" }) catch return "";
    @import("../util/fs.zig").mkdirParents(dir) catch return "";
    const path = std.fs.path.join(arena, &.{ dir, name }) catch return "";
    const path_z = arena.dupeZ(u8, path) catch return "";
    // Close-on-exec: every log is open while the servers start in
    // parallel, and each server gets its own as fd 2 through dup2. Without
    // the flag each server, and anything else spawned meanwhile, would
    // also hold every other server's log open. The fork lock keeps a
    // concurrent spawn out of the gap between open and fcntl.
    const process = @import("platform").process;
    process.forkSerialLock();
    defer process.forkSerialUnlock();
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return "";
    pfs.makeCloseOnExec(fd) catch {
        _ = pfs.close(fd);
        return "";
    };
    fd_out.* = fd;
    return path;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn snap(total: u32, settled_count: u32, failed: u32, needs_auth: u32, acknowledged: bool) Status.Snapshot {
    return .{ .total = total, .settled = settled_count, .failed = failed, .needs_auth = needs_auth, .published = false, .acknowledged = acknowledged };
}

test "notice: progress while servers connect, nothing without servers" {
    var buf: [96]u8 = undefined;
    try testing.expect(notice(snap(0, 0, 0, 0, false), &buf) == null);
    const n = notice(snap(4, 1, 1, 0, false), &buf).?;
    try testing.expectEqualStrings("connecting to MCP servers (1/4)", n.text);
    try testing.expectEqual(.progress, n.tone);
    // Still connecting: progress wins over failures already in.
    try testing.expectEqual(.progress, notice(snap(4, 3, 2, 1, true), &buf).?.tone);
}

test "notice: failures until acknowledged, auth told apart" {
    var buf: [96]u8 = undefined;
    try testing.expect(notice(snap(3, 3, 0, 0, false), &buf) == null);
    const auth_only = notice(snap(2, 2, 1, 1, false), &buf).?;
    try testing.expectEqualStrings("1 MCP server needs auth · /mcp", auth_only.text);
    try testing.expectEqual(.warning, auth_only.tone);
    const both = notice(snap(5, 5, 3, 1, false), &buf).?;
    try testing.expectEqualStrings("2 MCP servers failed, 1 MCP server needs auth · /mcp", both.text);
    try testing.expectEqual(.failure, both.tone);
    try testing.expect(notice(snap(5, 5, 3, 1, true), &buf) == null);
}
