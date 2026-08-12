//! Authenticated TinyKG Web transport.
//!
//! This is the only shared-Store transport. It binds every request to a
//! unique id, retries the exact same envelope after an uncertain network
//! outcome, validates the service/build/schema capability pins, and keeps a
//! generation-bound query session. It never accepts a client-selected Store.

const std = @import("std");
const rng = @import("platform").rng;
const time = @import("../util/time.zig");

pub const protocol_version: u32 = 2;
pub const task_hierarchy_capability = "task-hierarchy-canonical-read-v1";
pub const default_timeout_ms: u64 = 35_000;
pub const max_response_bytes: usize = 16 * 1024 * 1024;

pub const Error = error{
    InvalidConfiguration,
    InvalidUrl,
    RequestFailed,
    RequestTimedOut,
    ResponseTooLarge,
    InvalidResponse,
    AuthenticationFailed,
    IncompatibleDaemon,
    RequestIdConflict,
    AmbiguousCommit,
    Backpressure,
    DaemonUnavailable,
    OutOfMemory,
};

pub const Result = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: i32,
    generation: u64,
    commit_state: CommitState,
    replayed: bool,

    pub const CommitState = enum { none, committed, ambiguous };

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const Options = struct {
    io: std.Io,
    url: []const u8,
    api_key: []const u8,
    expected_build_id: []const u8,
    expected_schema_digest: []const u8,
    session_seed: ?[]const u8 = null,
    timeout_ms: u64 = default_timeout_ms,
};

pub const WebTransport = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    run_url: []u8,
    markdown_url: []u8,
    api_key: []u8,
    expected_build_id: []u8,
    expected_schema_digest: []u8,
    session_id: []u8,
    timeout_ms: u64,
    last_generation: u64 = 0,
    last_ambiguous_request_id: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, options: Options) Error!WebTransport {
        if (options.url.len == 0 or options.api_key.len == 0 or
            options.expected_build_id.len == 0 or options.expected_schema_digest.len == 0 or
            options.timeout_ms == 0 or options.timeout_ms > 3_600_000)
        {
            return Error.InvalidConfiguration;
        }
        const base = std.mem.trimEnd(u8, options.url, "/");
        _ = std.Uri.parse(base) catch return Error.InvalidUrl;
        const run_url = std.fmt.allocPrint(allocator, "{s}/api/run", .{base}) catch return Error.OutOfMemory;
        errdefer allocator.free(run_url);
        const markdown_url = std.fmt.allocPrint(allocator, "{s}/api/import-markdown", .{base}) catch return Error.OutOfMemory;
        errdefer allocator.free(markdown_url);
        const api_key = allocator.dupe(u8, options.api_key) catch return Error.OutOfMemory;
        errdefer secureFree(allocator, api_key);
        const build_id = allocator.dupe(u8, options.expected_build_id) catch return Error.OutOfMemory;
        errdefer allocator.free(build_id);
        const schema_digest = allocator.dupe(u8, options.expected_schema_digest) catch return Error.OutOfMemory;
        errdefer allocator.free(schema_digest);
        const session_id = if (options.session_seed) |seed|
            allocator.dupe(u8, seed) catch return Error.OutOfMemory
        else
            makeIdentifier(allocator, "metacodes-session") catch return Error.OutOfMemory;
        errdefer allocator.free(session_id);
        if (!identifierValid(session_id)) return Error.InvalidConfiguration;
        return .{
            .allocator = allocator,
            .http_client = .{ .allocator = allocator, .io = options.io },
            .run_url = run_url,
            .markdown_url = markdown_url,
            .api_key = api_key,
            .expected_build_id = build_id,
            .expected_schema_digest = schema_digest,
            .session_id = session_id,
            .timeout_ms = options.timeout_ms,
        };
    }

    pub fn deinit(self: *WebTransport) void {
        self.http_client.deinit();
        self.allocator.free(self.run_url);
        self.allocator.free(self.markdown_url);
        secureFree(self.allocator, self.api_key);
        self.allocator.free(self.expected_build_id);
        self.allocator.free(self.expected_schema_digest);
        self.allocator.free(self.session_id);
        if (self.last_ambiguous_request_id) |request_id| self.allocator.free(request_id);
    }

    pub fn cloneForSession(self: *const WebTransport, allocator: std.mem.Allocator) Error!WebTransport {
        const base_len = self.run_url.len - "/api/run".len;
        return init(allocator, .{
            .io = self.http_client.io,
            .url = self.run_url[0..base_len],
            .api_key = self.api_key,
            .expected_build_id = self.expected_build_id,
            .expected_schema_digest = self.expected_schema_digest,
            .timeout_ms = self.timeout_ms,
        });
    }

    /// Same-id retry is deliberate: a write that lost its HTTP response is
    /// replayed by StoreActor instead of being executed twice.
    pub fn run(self: *WebTransport, command: []const u8, args: []const []const u8, mutates: bool) Error!Result {
        self.clearAmbiguousRequestId();
        const request_id = try makeIdentifier(self.allocator, "metacodes");
        defer self.allocator.free(request_id);
        const session = if (isQueryCommand(command)) self.session_id else null;
        const required: []const []const u8 = if (requiresTaskHierarchy(command))
            &.{task_hierarchy_capability}
        else
            &.{};
        const envelope = .{
            .protocolVersion = protocol_version,
            .requestId = request_id,
            .command = command,
            .args = args,
            .sessionId = session,
            .timeoutMs = self.timeout_ms,
            .requiredCapabilities = required,
        };
        const body = try stringifyAlloc(self.allocator, envelope);
        defer self.allocator.free(body);
        return self.postWithSameIdRetry(self.run_url, body, request_id, mutates);
    }

    /// Markdown bytes are uploaded to the service; a client path is never
    /// interpreted by the remote host. The service owns its private temp file.
    pub fn importMarkdown(
        self: *WebTransport,
        markdown: []const u8,
        source_key: u64,
        source_label: ?[]const u8,
    ) Error!Result {
        self.clearAmbiguousRequestId();
        const request_id = try makeIdentifier(self.allocator, "metacodes-md");
        defer self.allocator.free(request_id);
        var source_key_buffer: [16]u8 = undefined;
        const source_key_text = std.fmt.bufPrint(&source_key_buffer, "{x:0>16}", .{source_key}) catch unreachable;
        const envelope = .{
            .protocolVersion = protocol_version,
            .requestId = request_id,
            .markdown = markdown,
            .sourceKey = source_key_text,
            .sourceLabel = source_label,
            .timeoutMs = self.timeout_ms,
        };
        const body = try stringifyAlloc(self.allocator, envelope);
        defer self.allocator.free(body);
        return self.postWithSameIdRetry(self.markdown_url, body, request_id, true);
    }

    fn postWithSameIdRetry(
        self: *WebTransport,
        url: []const u8,
        body: []const u8,
        request_id: []const u8,
        mutates: bool,
    ) Error!Result {
        const started_ms = time.nowMs();
        if (started_ms <= 0) return Error.RequestFailed;
        const deadline_ms = @as(i128, started_ms) + @as(i128, self.timeout_ms);
        var attempt: u8 = 0;
        while (attempt < 2) : (attempt += 1) {
            const remaining_ms = remainingTimeoutMs(deadline_ms) orelse {
                if (mutates) {
                    try self.recordAmbiguousRequestId(request_id);
                    return Error.AmbiguousCommit;
                }
                return Error.RequestTimedOut;
            };
            const response = self.postBeforeDeadline(url, body, request_id, remaining_ms) catch |err| {
                if (attempt == 0 and remainingTimeoutMs(deadline_ms) != null) continue;
                if (mutates) {
                    try self.recordAmbiguousRequestId(request_id);
                    return Error.AmbiguousCommit;
                }
                return switch (err) {
                    Error.AuthenticationFailed, Error.IncompatibleDaemon, Error.InvalidResponse, Error.RequestIdConflict, Error.Backpressure, Error.RequestTimedOut => err,
                    else => Error.DaemonUnavailable,
                };
            };
            if (response.commit_state == .ambiguous) {
                response.deinit(self.allocator);
                if (attempt == 0 and remainingTimeoutMs(deadline_ms) != null) continue;
                try self.recordAmbiguousRequestId(request_id);
                return Error.AmbiguousCommit;
            }
            return response;
        }
        unreachable;
    }

    const PostRace = union(enum) {
        response: Error!Result,
        deadline: std.Io.Cancelable!void,
    };

    /// `std.http.Client.request` does not expose an end-to-end timeout in Zig
    /// 0.16. Race the complete POST (connect, send, response head and body)
    /// against an awake-clock deadline. Cancelation joins the losing task, so
    /// no request or borrowed transport state survives this call.
    fn postBeforeDeadline(
        self: *WebTransport,
        url: []const u8,
        body: []const u8,
        request_id: []const u8,
        timeout_ms: u64,
    ) Error!Result {
        var results: [2]PostRace = undefined;
        var race = std.Io.Select(PostRace).init(self.http_client.io, &results);
        errdefer race.cancelDiscard();
        race.concurrent(.response, postTask, .{ self, url, body, request_id }) catch
            return Error.RequestFailed;
        race.concurrent(.deadline, deadlineTask, .{ self.http_client.io, timeout_ms }) catch
            return Error.RequestFailed;

        const first = race.await() catch return Error.RequestFailed;
        switch (first) {
            .response => |response| {
                race.cancelDiscard();
                return response;
            },
            .deadline => |deadline| {
                deadline catch return Error.RequestFailed;
                // The HTTP task can finish at the deadline boundary. Drain a
                // successful late result instead of leaking its owned bytes.
                while (race.cancel()) |late| switch (late) {
                    .response => |response| if (response) |result| {
                        result.deinit(self.allocator);
                    } else |_| {},
                    .deadline => {},
                };
                return Error.RequestTimedOut;
            },
        }
    }

    fn postTask(
        self: *WebTransport,
        url: []const u8,
        body: []const u8,
        request_id: []const u8,
    ) Error!Result {
        return self.post(url, body, request_id);
    }

    fn deadlineTask(io: std.Io, timeout_ms: u64) std.Io.Cancelable!void {
        const bounded: i64 = @intCast(timeout_ms);
        return std.Io.Timeout.sleep(.{ .duration = .{
            .raw = .fromMilliseconds(bounded),
            .clock = .awake,
        } }, io);
    }

    fn post(self: *WebTransport, url: []const u8, body: []const u8, request_id: []const u8) Error!Result {
        const uri = std.Uri.parse(url) catch return Error.InvalidUrl;
        var req = self.http_client.request(.POST, uri, .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "x-api-key", .value = self.api_key },
            },
        }) catch return Error.RequestFailed;
        defer req.deinit();
        req.sendBodyComplete(@constCast(body)) catch return Error.RequestFailed;
        var redirect_buffer: [4096]u8 = undefined;
        const head = req.receiveHead(&redirect_buffer) catch return Error.RequestFailed;
        var transfer_buffer: [8192]u8 = undefined;
        const reader = req.reader.bodyReader(&transfer_buffer, head.head.transfer_encoding, head.head.content_length);
        const bytes = reader.allocRemaining(self.allocator, std.Io.Limit.limited(max_response_bytes)) catch
            return Error.ResponseTooLarge;
        defer self.allocator.free(bytes);
        if (head.head.status == .unauthorized or head.head.status == .forbidden)
            return Error.AuthenticationFailed;
        if (head.head.status == .service_unavailable) return Error.DaemonUnavailable;
        return self.parseResponse(bytes, request_id);
    }

    fn parseResponse(self: *WebTransport, bytes: []const u8, request_id: []const u8) Error!Result {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return Error.InvalidResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return Error.InvalidResponse;
        const object = parsed.value.object;
        if (integer(object.get("protocolVersion")) != protocol_version or
            !stringEquals(object.get("implementation"), "tinykg-web") or
            !stringEquals(object.get("buildId"), self.expected_build_id) or
            !stringEquals(object.get("schemaDigest"), self.expected_schema_digest) or
            !stringEquals(object.get("requestId"), request_id))
        {
            return Error.IncompatibleDaemon;
        }
        const engine = object.get("engine") orelse return Error.IncompatibleDaemon;
        if (engine != .object or !stringEquals(engine.object.get("implementation"), "tinykg-cli"))
            return Error.IncompatibleDaemon;
        const stderr_raw = string(object.get("stderr")) orelse string(object.get("error")) orelse "";
        if (std.mem.indexOf(u8, stderr_raw, "RequestIdConflict") != null) return Error.RequestIdConflict;
        if (std.mem.indexOf(u8, stderr_raw, "DaemonQueueFull") != null) return Error.Backpressure;
        const commit_raw = string(object.get("commitState")) orelse "none";
        const commit_state: Result.CommitState = if (std.mem.eql(u8, commit_raw, "committed"))
            .committed
        else if (std.mem.eql(u8, commit_raw, "ambiguous"))
            .ambiguous
        else if (std.mem.eql(u8, commit_raw, "none"))
            .none
        else
            return Error.InvalidResponse;
        const generation = integer(object.get("generation")) orelse return Error.InvalidResponse;
        if (object.get("session")) |session| {
            if (session != .object or
                !stringEquals(session.object.get("sessionId"), self.session_id) or
                integer(session.object.get("generation")) != generation)
            {
                return Error.IncompatibleDaemon;
            }
        }
        self.last_generation = generation;
        const stdout = self.allocator.dupe(u8, string(object.get("stdout")) orelse "") catch return Error.OutOfMemory;
        errdefer self.allocator.free(stdout);
        const stderr = self.allocator.dupe(u8, stderr_raw) catch return Error.OutOfMemory;
        return .{
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = if (boolean(object.get("ok"))) 0 else @intCast(integer(object.get("code")) orelse 1),
            .generation = generation,
            .commit_state = commit_state,
            .replayed = boolean(object.get("replayed")),
        };
    }

    pub fn ambiguousRequestId(self: *const WebTransport) ?[]const u8 {
        return self.last_ambiguous_request_id;
    }

    fn clearAmbiguousRequestId(self: *WebTransport) void {
        if (self.last_ambiguous_request_id) |request_id| self.allocator.free(request_id);
        self.last_ambiguous_request_id = null;
    }

    fn recordAmbiguousRequestId(self: *WebTransport, request_id: []const u8) Error!void {
        self.clearAmbiguousRequestId();
        self.last_ambiguous_request_id = self.allocator.dupe(u8, request_id) catch return Error.OutOfMemory;
    }
};

fn remainingTimeoutMs(deadline_ms: i128) ?u64 {
    const now_ms = time.nowMs();
    if (now_ms <= 0 or @as(i128, now_ms) >= deadline_ms) return null;
    return @intCast(deadline_ms - @as(i128, now_ms));
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) Error![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    std.json.Stringify.value(value, .{}, &output.writer) catch return Error.OutOfMemory;
    return output.toOwnedSlice() catch return Error.OutOfMemory;
}

fn makeIdentifier(allocator: std.mem.Allocator, prefix: []const u8) Error![]u8 {
    var random: [16]u8 = undefined;
    if (!rng.randomBytes(&random)) return Error.InvalidConfiguration;
    return std.fmt.allocPrint(allocator, "{s}-{x}", .{ prefix, random }) catch Error.OutOfMemory;
}

fn identifierValid(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', ':' => {},
        else => return false,
    };
    return true;
}

fn isQueryCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "query") or std.mem.eql(u8, command, "query-explain");
}

fn requiresTaskHierarchy(command: []const u8) bool {
    const commands = [_][]const u8{ "task-packet", "task-frontier", "task-ancestry", "task-metrics", "task-close" };
    for (commands) |item| if (std.mem.eql(u8, command, item)) return true;
    return false;
}

fn string(value: ?std.json.Value) ?[]const u8 {
    const actual = value orelse return null;
    return if (actual == .string) actual.string else null;
}

fn stringEquals(value: ?std.json.Value, expected: []const u8) bool {
    const actual = string(value) orelse return false;
    return std.mem.eql(u8, actual, expected);
}

fn integer(value: ?std.json.Value) ?u64 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn boolean(value: ?std.json.Value) bool {
    const actual = value orelse return false;
    return actual == .bool and actual.bool;
}

fn secureFree(allocator: std.mem.Allocator, value: []u8) void {
    @memset(value, 0);
    allocator.free(value);
}

test "transport command policies bind sessions and task capabilities" {
    try std.testing.expect(isQueryCommand("query"));
    try std.testing.expect(!isQueryCommand("search"));
    try std.testing.expect(requiresTaskHierarchy("task-close"));
    try std.testing.expect(!requiresTaskHierarchy("stats"));
    try std.testing.expect(identifierValid("metacodes-session-a1"));
    try std.testing.expect(!identifierValid("bad id"));
}
