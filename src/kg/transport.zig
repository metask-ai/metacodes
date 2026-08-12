//! Authenticated TinyKG Web transport.
//!
//! This is the only shared-Store transport. It binds every request to a
//! unique id, validates the service/build/schema capability pins, and keeps a
//! generation-bound query session. It never accepts a client-selected Store.
//! Reads may be retried within one wall-clock deadline. Writes are attempted
//! exactly once: an uncertain result is returned to the Metacodes transaction
//! controller with its request id and blocks later writes until re-observation.

const std = @import("std");
const rng = @import("platform").rng;
const sync = @import("platform").sync;
const time = @import("../util/time.zig");
const ResponseStatus = @import("../api/http_status.zig").ResponseStatus;

pub const protocol_version: u32 = 2;
pub const control_plane_version: u32 = 1;
pub const task_hierarchy_capability = "task-hierarchy-canonical-read-v1";
pub const ontology_rule_snapshot_capability = "tinykg-ontology-rule-snapshot-v1";
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
    /// Empty means pin the first authenticated response for this session.
    expected_schema_digest: []const u8 = "",
    session_seed: ?[]const u8 = null,
    timeout_ms: u64 = default_timeout_ms,
};

/// Process-local write serialization and ambiguity fence shared by every
/// session cloned from one `KgClient`.  This is deliberately not presented as
/// a distributed transaction: independent Metacodes processes still require a
/// TinyKG expected-generation/CAS primitive for cross-process linearization.
const SharedWriteFence = struct {
    ref_count: std.atomic.Value(u32) = .init(1),
    write_mutex: sync.Mutex = .{},
    schema_mutex: sync.Mutex = .{},
    ambiguous_request_id: [128]u8 = undefined,
    ambiguous_request_id_len: u8 = 0,
    schema_digest: [64]u8 = undefined,
    schema_digest_len: u8 = 0,

    fn create(initial_schema_digest: []const u8) Error!*SharedWriteFence {
        const fence = std.heap.c_allocator.create(SharedWriteFence) catch return Error.OutOfMemory;
        fence.* = .{};
        if (initial_schema_digest.len != 0) {
            std.debug.assert(initial_schema_digest.len == fence.schema_digest.len);
            @memcpy(fence.schema_digest[0..initial_schema_digest.len], initial_schema_digest);
            fence.schema_digest_len = @intCast(initial_schema_digest.len);
        }
        return fence;
    }

    fn retain(self: *SharedWriteFence) Error!*SharedWriteFence {
        const previous = self.ref_count.fetchAdd(1, .monotonic);
        if (previous == 0 or previous == std.math.maxInt(u32)) {
            _ = self.ref_count.fetchSub(1, .monotonic);
            return Error.OutOfMemory;
        }
        return self;
    }

    fn release(self: *SharedWriteFence) void {
        const previous = self.ref_count.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous != 1) return;
        std.heap.c_allocator.destroy(self);
    }

    /// Caller holds `mutex`. Preserve the first uncertain request: replacing
    /// it would destroy the only recovery identity for the earlier write.
    /// The id is copied into fixed storage so crossing into the uncertain
    /// state cannot itself fail allocation and accidentally leave writes open.
    fn recordAmbiguousLocked(self: *SharedWriteFence, request_id: []const u8) void {
        if (self.ambiguous_request_id_len != 0) return;
        std.debug.assert(request_id.len > 0 and request_id.len <= self.ambiguous_request_id.len);
        @memcpy(self.ambiguous_request_id[0..request_id.len], request_id);
        self.ambiguous_request_id_len = @intCast(request_id.len);
    }

    fn ambiguousRequestId(self: *SharedWriteFence) ?[]const u8 {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        // The id is immutable until the last transport releases the fence, so
        // this borrowed diagnostic remains valid for the caller's transport.
        const len = self.ambiguous_request_id_len;
        return if (len == 0) null else self.ambiguous_request_id[0..len];
    }

    /// Pin the first authenticated schema digest for the whole client family.
    /// Cloned subagent/swarm sessions must not independently accept drift.
    fn matchesOrPinsSchema(self: *SharedWriteFence, digest: []const u8) bool {
        self.schema_mutex.lock();
        defer self.schema_mutex.unlock();
        if (self.schema_digest_len == 0) {
            std.debug.assert(digest.len == self.schema_digest.len);
            @memcpy(self.schema_digest[0..digest.len], digest);
            self.schema_digest_len = @intCast(digest.len);
            return true;
        }
        return std.mem.eql(u8, self.schema_digest[0..self.schema_digest_len], digest);
    }
};

pub const WebTransport = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    run_url: []u8,
    markdown_url: []u8,
    api_key: []u8,
    expected_build_id: []u8,
    session_id: []u8,
    timeout_ms: u64,
    last_generation: u64 = 0,
    write_fence: *SharedWriteFence,
    /// `KgClient` can be shared by the lead loop and in-process subagents.
    /// std.http.Client, schema pinning, generation and the ambiguity latch are
    /// one mutable transport session, so every request/state transition must
    /// be serialized locally as well as by tinykgd's StoreActor.
    request_mu: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, options: Options) Error!WebTransport {
        if (options.url.len == 0 or options.api_key.len == 0 or
            options.expected_build_id.len == 0 or
            options.timeout_ms == 0 or options.timeout_ms > 3_600_000)
        {
            return Error.InvalidConfiguration;
        }
        const base = std.mem.trimEnd(u8, options.url, "/");
        const uri = std.Uri.parse(base) catch return Error.InvalidUrl;
        if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or
            uri.host == null or uri.user != null or uri.password != null or
            uri.query != null or uri.fragment != null or containsControl(base) or
            containsControl(options.api_key) or !buildIdValid(options.expected_build_id) or
            (options.expected_schema_digest.len != 0 and !lowerHexDigestValid(options.expected_schema_digest)))
        {
            return Error.InvalidConfiguration;
        }
        const run_url = std.fmt.allocPrint(allocator, "{s}/api/run", .{base}) catch return Error.OutOfMemory;
        errdefer allocator.free(run_url);
        const markdown_url = std.fmt.allocPrint(allocator, "{s}/api/import-markdown", .{base}) catch return Error.OutOfMemory;
        errdefer allocator.free(markdown_url);
        const api_key = allocator.dupe(u8, options.api_key) catch return Error.OutOfMemory;
        errdefer secureFree(allocator, api_key);
        const build_id = allocator.dupe(u8, options.expected_build_id) catch return Error.OutOfMemory;
        errdefer allocator.free(build_id);
        const session_id = if (options.session_seed) |seed|
            allocator.dupe(u8, seed) catch return Error.OutOfMemory
        else
            makeIdentifier(allocator, "metacodes-session") catch return Error.OutOfMemory;
        errdefer allocator.free(session_id);
        if (!identifierValid(session_id)) return Error.InvalidConfiguration;
        const write_fence = try SharedWriteFence.create(options.expected_schema_digest);
        errdefer write_fence.release();
        return .{
            .allocator = allocator,
            .http_client = .{ .allocator = allocator, .io = options.io },
            .run_url = run_url,
            .markdown_url = markdown_url,
            .api_key = api_key,
            .expected_build_id = build_id,
            .session_id = session_id,
            .timeout_ms = options.timeout_ms,
            .write_fence = write_fence,
        };
    }

    pub fn deinit(self: *WebTransport) void {
        self.http_client.deinit();
        self.allocator.free(self.run_url);
        self.allocator.free(self.markdown_url);
        secureFree(self.allocator, self.api_key);
        self.allocator.free(self.expected_build_id);
        self.allocator.free(self.session_id);
        self.write_fence.release();
    }

    pub fn cloneForSession(self: *const WebTransport, allocator: std.mem.Allocator) Error!WebTransport {
        const base_len = self.run_url.len - "/api/run".len;
        var cloned = try init(allocator, .{
            .io = self.http_client.io,
            .url = self.run_url[0..base_len],
            .api_key = self.api_key,
            .expected_build_id = self.expected_build_id,
            .expected_schema_digest = "",
            .timeout_ms = self.timeout_ms,
        });
        errdefer cloned.deinit();
        const shared_fence = try self.write_fence.retain();
        cloned.write_fence.release();
        cloned.write_fence = shared_fence;
        return cloned;
    }

    /// Authenticated, configuration-pinned TinyKG build identity.  This is
    /// the daemon-mode equivalent of hashing the exclusive local executable;
    /// callers still validate every response against the same build id.
    pub fn buildSha256(self: *const WebTransport) Error![64]u8 {
        const prefix = "sha256:";
        if (!std.mem.startsWith(u8, self.expected_build_id, prefix))
            return Error.InvalidConfiguration;
        const raw = self.expected_build_id[prefix.len..];
        if (!lowerHexDigestValid(raw)) return Error.InvalidConfiguration;
        var out: [64]u8 = undefined;
        @memcpy(&out, raw);
        return out;
    }

    /// Generate a fresh request identity. Non-idempotent callers that persist
    /// their own transaction id use `runWithRequestId` instead.
    pub fn run(self: *WebTransport, command: []const u8, args: []const []const u8, mutates: bool) Error!Result {
        const request_id = try makeIdentifier(self.allocator, "metacodes");
        defer self.allocator.free(request_id);
        return self.runWithRequestId(command, args, mutates, request_id);
    }

    /// Execute exactly one semantic request identity. This method never
    /// retries a write. Once a result becomes ambiguous, this client family is
    /// intentionally poisoned for writes; a fresh process must first recover
    /// that request id through an application-specific inspect/rollback path.
    pub fn runWithRequestId(
        self: *WebTransport,
        command: []const u8,
        args: []const []const u8,
        mutates: bool,
        request_id: []const u8,
    ) Error!Result {
        self.request_mu.lockUncancelable(self.http_client.io);
        defer self.request_mu.unlock(self.http_client.io);
        if (!identifierValid(request_id)) return Error.InvalidConfiguration;
        if (mutates) {
            // Serialize the check and complete write attempt across the lead,
            // subagents and in-process swarm sessions cloned from this client.
            self.write_fence.write_mutex.lock();
            defer self.write_fence.write_mutex.unlock();
            if (self.write_fence.ambiguous_request_id_len != 0)
                return Error.AmbiguousCommit;
        }
        const session = if (isQueryCommand(command)) self.session_id else null;
        const required: []const []const u8 = if (std.mem.eql(u8, command, "ontology-rule-snapshot"))
            &.{ task_hierarchy_capability, ontology_rule_snapshot_capability }
        else
            &.{task_hierarchy_capability};
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
        return self.postWithPolicy(self.run_url, body, request_id, mutates);
    }

    /// Markdown bytes are uploaded to the service; a client path is never
    /// interpreted by the remote host. The service owns its private temp file.
    pub fn importMarkdown(
        self: *WebTransport,
        markdown: []const u8,
        source_key: u64,
        source_label: ?[]const u8,
    ) Error!Result {
        self.request_mu.lockUncancelable(self.http_client.io);
        defer self.request_mu.unlock(self.http_client.io);
        self.write_fence.write_mutex.lock();
        defer self.write_fence.write_mutex.unlock();
        if (self.write_fence.ambiguous_request_id_len != 0) return Error.AmbiguousCommit;
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
        return self.postWithPolicy(self.markdown_url, body, request_id, true);
    }

    fn postWithPolicy(
        self: *WebTransport,
        url: []const u8,
        body: []const u8,
        request_id: []const u8,
        mutates: bool,
    ) Error!Result {
        const started_ms = time.nowMs();
        if (started_ms <= 0) return Error.RequestFailed;
        const deadline_ms = @as(i128, started_ms) + @as(i128, self.timeout_ms);
        const max_attempts: u8 = if (mutates) 1 else 2;
        var attempt: u8 = 0;
        while (attempt < max_attempts) : (attempt += 1) {
            const remaining_ms = remainingTimeoutMs(deadline_ms) orelse {
                if (mutates) {
                    self.recordAmbiguousRequestId(request_id);
                    return Error.AmbiguousCommit;
                }
                return Error.RequestTimedOut;
            };
            const response = self.postBeforeDeadline(url, body, request_id, remaining_ms) catch |err| {
                if (mutates and provesNoCommit(err)) return err;
                if (!mutates) {
                    if (attempt + 1 < max_attempts and remainingTimeoutMs(deadline_ms) != null) continue;
                    return normalizeReadFailure(err);
                }
                self.recordAmbiguousRequestId(request_id);
                return Error.AmbiguousCommit;
            };
            if (response.commit_state == .ambiguous) {
                response.deinit(self.allocator);
                self.recordAmbiguousRequestId(request_id);
                return Error.AmbiguousCommit;
            }
            if (mutates and ((response.commit_state == .committed and response.exit_code != 0) or
                (response.commit_state == .none and response.exit_code == 0)))
            {
                // Either the write committed but its post-commit path failed,
                // or the daemon acknowledged success without a commit receipt.
                // Both require application-level re-observation before another
                // mutation may be admitted.
                response.deinit(self.allocator);
                self.recordAmbiguousRequestId(request_id);
                return Error.AmbiguousCommit;
            }
            if (!mutates and response.commit_state != .none) {
                response.deinit(self.allocator);
                return Error.IncompatibleDaemon;
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
        const status = ResponseStatus.capture(&head);
        var transfer_buffer: [8192]u8 = undefined;
        const reader = req.reader.bodyReader(&transfer_buffer, head.head.transfer_encoding, head.head.content_length);
        const bytes = reader.allocRemaining(self.allocator, std.Io.Limit.limited(max_response_bytes)) catch
            return Error.ResponseTooLarge;
        defer self.allocator.free(bytes);
        if (status.code == 401 or status.code == 403)
            return Error.AuthenticationFailed;
        if (status.code == 503) return Error.DaemonUnavailable;
        if (!status.isOk()) return Error.InvalidResponse;
        return self.parseResponse(bytes, request_id);
    }

    fn parseResponse(self: *WebTransport, bytes: []const u8, request_id: []const u8) Error!Result {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return Error.InvalidResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return Error.InvalidResponse;
        const object = parsed.value.object;
        if (integer(object.get("protocolVersion")) != protocol_version or
            integer(object.get("controlPlaneVersion")) != control_plane_version or
            !stringEquals(object.get("implementation"), "tinykg-web") or
            !stringEquals(object.get("schemaMode"), "server-canonical") or
            !stringEquals(object.get("buildId"), self.expected_build_id) or
            !stringEquals(object.get("requestId"), request_id))
        {
            return Error.IncompatibleDaemon;
        }
        const engine = object.get("engine") orelse return Error.IncompatibleDaemon;
        if (engine != .object or !stringEquals(engine.object.get("implementation"), "tinykg-cli") or
            (string(engine.object.get("version")) orelse @as([]const u8, "")).len == 0 or
            !lowerHexDigestValid(string(engine.object.get("binarySha256")) orelse @as([]const u8, "")) or
            !boolean(engine.object.get("metadataValid")) or
            !capabilitiesValid(object.get("capabilities")))
            return Error.IncompatibleDaemon;
        const schema_digest = string(object.get("schemaDigest")) orelse return Error.IncompatibleDaemon;
        if (!lowerHexDigestValid(schema_digest)) return Error.IncompatibleDaemon;
        if (!self.write_fence.matchesOrPinsSchema(schema_digest)) {
            return Error.IncompatibleDaemon;
        }
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
        const replayed = boolean(object.get("replayed"));
        if (generation < self.last_generation or
            (commit_state == .committed and generation <= self.last_generation and !replayed))
            return Error.IncompatibleDaemon;
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
            .replayed = replayed,
        };
    }

    pub fn ambiguousRequestId(self: *const WebTransport) ?[]const u8 {
        return self.write_fence.ambiguousRequestId();
    }

    fn recordAmbiguousRequestId(self: *WebTransport, request_id: []const u8) void {
        // Mutating callers hold the shared fence across the complete attempt.
        self.write_fence.recordAmbiguousLocked(request_id);
    }
};

fn remainingTimeoutMs(deadline_ms: i128) ?u64 {
    const now_ms = time.nowMs();
    if (now_ms <= 0 or @as(i128, now_ms) >= deadline_ms) return null;
    return @intCast(deadline_ms - @as(i128, now_ms));
}

fn provesNoCommit(err: Error) bool {
    return switch (err) {
        Error.InvalidConfiguration,
        Error.InvalidUrl,
        Error.AuthenticationFailed,
        Error.RequestIdConflict,
        Error.Backpressure,
        => true,
        else => false,
    };
}

fn normalizeReadFailure(err: Error) Error {
    return switch (err) {
        Error.RequestFailed, Error.ResponseTooLarge => Error.DaemonUnavailable,
        else => err,
    };
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

fn lowerHexDigestValid(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn buildIdValid(value: []const u8) bool {
    return value.len == "sha256:".len + 64 and
        std.mem.startsWith(u8, value, "sha256:") and lowerHexDigestValid(value["sha256:".len..]);
}

fn containsControl(value: []const u8) bool {
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f) return true;
    return false;
}

fn capabilitiesValid(value: ?std.json.Value) bool {
    const actual = value orelse return false;
    if (actual != .array) return false;
    var found_task_hierarchy = false;
    for (actual.array.items, 0..) |item, index| {
        if (item != .string or item.string.len == 0) return false;
        for (actual.array.items[0..index]) |prior| {
            if (prior == .string and std.mem.eql(u8, prior.string, item.string)) return false;
        }
        if (std.mem.eql(u8, item.string, task_hierarchy_capability)) found_task_hierarchy = true;
    }
    return found_task_hierarchy;
}

fn isQueryCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "query") or std.mem.eql(u8, command, "query-explain");
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
    try std.testing.expect(identifierValid("metacodes-session-a1"));
    try std.testing.expect(!identifierValid("bad id"));
    try std.testing.expect(lowerHexDigestValid("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try std.testing.expect(!lowerHexDigestValid("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
    try std.testing.expect(buildIdValid("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try std.testing.expect(!buildIdValid("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try std.testing.expect(!containsControl("api-key"));
    try std.testing.expect(containsControl("bad key"));
    try std.testing.expect(provesNoCommit(Error.AuthenticationFailed));
    try std.testing.expect(provesNoCommit(Error.Backpressure));
    try std.testing.expect(!provesNoCommit(Error.RequestTimedOut));
}
