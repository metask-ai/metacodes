//! `metacodes kgd`: the Metacodes-owned TinyKG service.
//!
//! It owns one `tinykgd` child (which owns the Store) and serves the
//! authenticated HTTP contract `src/kg/transport.zig` speaks, so a Metacodes
//! session needs nothing but `~/.metacodes/kg/daemon.json` to reach its
//! knowledge graph. The upstream TinyKG Web service serves the same contract
//! for shared deployments; this is the single-user local equivalent, in the
//! product binary, with no Node runtime.
//!
//! Deliberately serial: `tinykgd` answers one request at a time, so accepting
//! and handling one connection at a time removes every cross-request data race
//! at the cost of queueing behind a slow peer, which socket timeouts bound.

const std = @import("std");
const http = @import("../../util/http.zig");
const net = @import("platform").net;
const pfs = @import("platform").fs;
const log = @import("../../util/log.zig");
const time = @import("../../util/time.zig");
const identity_mod = @import("identity.zig");
const bridge_mod = @import("bridge.zig");

/// The HTTP envelope version Metacodes clients speak. Unrelated to the stdio
/// protocol version in `bridge.zig`.
pub const PROTOCOL_VERSION: u32 = 2;
pub const CONTROL_PLANE_VERSION: u32 = 1;
pub const SCHEMA_MODE = "server-canonical";

pub const MAX_HEAD_BYTES: usize = 16 * 1024;
/// Markdown import carries a whole document; everything else is far smaller.
pub const MAX_BODY_BYTES: usize = 16 * 1024 * 1024;
pub const SOCKET_TIMEOUT_MS: u32 = 30_000;
/// Wall-clock budget for reading a request and writing its response. The socket
/// timeout only bounds one read or write, so a peer that dribbles a byte before
/// each timeout could hold this single-threaded server forever. Time spent in
/// the child is bounded separately, by the request's own `timeoutMs`.
pub const SOCKET_IO_DEADLINE_MS: i64 = 30_000;
/// How long one blocking socket read or write may wait before the deadline is
/// re-checked. Keeps a failed `SO_RCVTIMEO` from turning into an infinite wait.
pub const SOCKET_POLL_SLICE_MS: u32 = 250;
/// How long the accept loop waits for a connection before re-reading the stop
/// flag. It bounds shutdown latency, nothing else.
pub const ACCEPT_POLL_SLICE_MS: u32 = 200;
const MAX_REQUEST_ID_BYTES: usize = 128;

pub const Error = error{
    IdentityUnavailable,
    DaemonUnavailable,
    StoreContractUnreadable,
    ListenFailed,
    OutOfMemory,
};

pub const Options = struct {
    store_path: []const u8,
    cli_path: []const u8,
    daemon_path: []const u8,
    /// Compared against every request's `x-api-key`. Never logged.
    api_key: []const u8,
    port: u16,
};

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    options: Options,
    identity: identity_mod.Identity,
    /// `identity.capabilities` as the const-of-const slice JSON emission needs.
    capabilities: [][]const u8,
    bridge: bridge_mod.Bridge,
    schema_digest: [64]u8,
    listener: net.Listener,
    request_seq: u64 = 0,
    /// Set when the daemon stopped answering. The service then stops, because
    /// every later request would queue behind a child that will not reply.
    daemon_wedged: bool = false,
    /// Absolute deadline for writing the current response. Set per connection;
    /// a client that reads one byte at a time cannot outlast it.
    response_deadline_ms: i64 = 0,
    /// Set by `stop`; the accept loop's only exit condition.
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn port(self: *const Supervisor) u16 {
        return self.listener.port;
    }

    /// Establish identity, start the daemon, learn the store contract, bind.
    /// Every step fails closed: a supervisor that cannot say what it is must
    /// not answer a client that pins what it expects.
    pub fn start(allocator: std.mem.Allocator, options: Options) Error!*Supervisor {
        var identity = identity_mod.discover(allocator, options.cli_path, options.daemon_path) catch |err| {
            log.err("kgd", "cannot establish TinyKG identity: {s}", .{@errorName(err)});
            return Error.IdentityUnavailable;
        };
        errdefer identity.deinit();

        const capabilities = allocator.alloc([]const u8, identity.capabilities.len) catch return Error.OutOfMemory;
        errdefer allocator.free(capabilities);
        for (identity.capabilities, 0..) |capability, index| capabilities[index] = capability;

        var bridge = bridge_mod.Bridge.start(allocator, options.daemon_path, options.store_path) catch |err| {
            log.err("kgd", "cannot start tinykgd: {s}", .{@errorName(err)});
            return Error.DaemonUnavailable;
        };
        errdefer bridge.stop();

        const self = allocator.create(Supervisor) catch return Error.OutOfMemory;
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .options = options,
            .identity = identity,
            .capabilities = capabilities,
            .bridge = bridge,
            .schema_digest = undefined,
            .listener = undefined,
        };
        self.schema_digest = try self.readStoreContract();

        self.listener = net.listenLoopback(options.port, 16) catch return Error.ListenFailed;
        log.info("kgd", "serving http://127.0.0.1:{d} store={s} build={s}", .{
            self.listener.port,
            options.store_path,
            self.identity.buildId(),
        });
        return self;
    }

    pub fn deinit(self: *Supervisor) void {
        net.closeSocket(self.listener.sock);
        self.bridge.stop();
        self.allocator.free(self.capabilities);
        self.identity.deinit();
        self.allocator.destroy(self);
    }

    /// Asks the accept loop to finish. It only sets a flag: closing the
    /// listening socket from another thread does not reliably wake a blocked
    /// `accept`, and the fd could be reused by a socket this process opens in
    /// the same instant. The loop polls, so it notices within one slice.
    pub fn stop(self: *Supervisor) void {
        self.stopping.store(true, .release);
    }

    pub fn daemonWedged(self: *const Supervisor) bool {
        return self.daemon_wedged;
    }

    pub fn serveForever(self: *Supervisor) void {
        while (!self.stopping.load(.acquire)) {
            // Bounded wait so `stop` is observed without a second wakeup
            // mechanism, and so a signal that interrupts the poll just
            // re-checks the flag.
            if (!net.pollReadable(self.listener.sock, ACCEPT_POLL_SLICE_MS)) continue;
            const conn = net.acceptConn(self.listener.sock) orelse {
                if (self.stopping.load(.acquire)) return;
                // EINTR, ECONNABORTED and EMFILE are transient: a server that
                // exits on the first of them is a server that silently dies.
                time.sleepMs(10);
                continue;
            };
            defer net.closeSocket(conn);
            net.setRecvTimeoutMs(conn, SOCKET_TIMEOUT_MS);
            net.setSendTimeoutMs(conn, SOCKET_TIMEOUT_MS);
            self.handle(conn);
        }
    }

    fn readStoreContract(self: *Supervisor) Error![64]u8 {
        var request_id_buffer: [64]u8 = undefined;
        var response = self.bridge.run(.{
            .request_id = self.nextRequestId(&request_id_buffer),
            .command = "store-info",
        }) catch |err| {
            log.err("kgd", "tinykgd store-info failed: {s}", .{@errorName(err)});
            return Error.StoreContractUnreadable;
        };
        defer response.deinit();
        if (!response.boolean("ok")) {
            log.err("kgd", "tinykgd store-info: {s}", .{response.string("stderr") orelse "unknown error"});
            return Error.StoreContractUnreadable;
        }
        const stdout = response.string("stdout") orelse return Error.StoreContractUnreadable;
        const storage = infoField(stdout, "storage_format_version") orelse return Error.StoreContractUnreadable;
        const schema = infoField(stdout, "schema_version") orelse return Error.StoreContractUnreadable;
        return self.identity.schemaDigest(storage, schema);
    }

    /// Unique per request and valid under the daemon's identifier charset. The
    /// daemon deduplicates replays by id, so two different requests must never
    /// share one.
    fn nextRequestId(self: *Supervisor, buffer: []u8) []const u8 {
        self.request_seq += 1;
        return std.fmt.bufPrint(buffer, "metacodes-kgd-{d}-{d}", .{
            @as(u64, @intCast(@max(0, time.nowMs()))),
            self.request_seq,
        }) catch "metacodes-kgd-fallback";
    }

    fn handle(self: *Supervisor, conn: net.Socket) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const deadline = time.nowMs() +| SOCKET_IO_DEADLINE_MS;
        self.response_deadline_ms = deadline;
        var reader = RequestReader.init(allocator, conn, deadline);
        defer reader.deinit();

        // The head first, then authentication, and only then the body: reading
        // a 16 MB body from a peer that has not proved it may talk to us is
        // exactly the work an unauthenticated peer must not be able to demand.
        const head = reader.readHead() catch |err| {
            self.sendError(conn, statusForRead(err), @errorName(err));
            return;
        };
        const line = http.parseRequestLine(head) orelse {
            self.sendError(conn, 400, "malformed request line");
            return;
        };
        const presented = http.headerValue(head, "x-api-key") orelse "";
        if (!constantTimeEql(presented, self.options.api_key)) {
            self.sendError(conn, 401, "invalid or missing x-api-key");
            return;
        }
        const body = reader.readBody(head) catch |err| {
            self.sendError(conn, statusForRead(err), @errorName(err));
            return;
        };

        if (std.mem.eql(u8, line.method, "GET") and std.mem.eql(u8, line.path, "/api/ready")) {
            self.handleReady(conn, allocator);
            return;
        }
        if (std.mem.eql(u8, line.method, "POST") and std.mem.eql(u8, line.path, "/api/run")) {
            self.handleRun(conn, allocator, body);
            return;
        }
        if (std.mem.eql(u8, line.method, "POST") and std.mem.eql(u8, line.path, "/api/import-markdown")) {
            self.handleImportMarkdown(conn, allocator, body);
            return;
        }
        self.sendError(conn, 404, "no such endpoint");
    }

    fn handleReady(self: *Supervisor, conn: net.Socket, allocator: std.mem.Allocator) void {
        var request_id_buffer: [64]u8 = undefined;
        var response = self.bridge.run(.{
            .request_id = self.nextRequestId(&request_id_buffer),
            .command = "store-info",
        }) catch |err| {
            // Readiness goes through the same handler: a child that died during
            // a health probe is just as terminal as one that died during a run.
            self.reportDaemonFailure(conn, err);
            return;
        };
        defer response.deinit();
        const ok = response.boolean("ok");
        const body = std.fmt.allocPrint(
            allocator,
            "{{\"ok\":{s},\"ready\":{s},\"degraded\":{s}}}",
            .{ boolText(ok), boolText(ok), boolText(!ok) },
        ) catch return;
        self.send(conn, if (ok) 200 else 503, body);
    }

    fn handleRun(self: *Supervisor, conn: net.Socket, allocator: std.mem.Allocator, body: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            self.sendError(conn, 400, "request body is not JSON");
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            self.sendError(conn, 400, "request body is not a JSON object");
            return;
        }
        const root = parsed.value.object;
        if (!self.protocolAccepted(conn, root)) return;
        const request_id = self.requestIdOf(conn, root) orelse return;
        const command = stringOf(root, "command") orelse {
            self.sendError(conn, 400, "command is required");
            return;
        };
        if (!self.capabilitiesSatisfied(conn, root)) return;

        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(allocator);
        if (root.get("args")) |raw| {
            if (raw != .array) {
                self.sendError(conn, 400, "args must be an array of strings");
                return;
            }
            for (raw.array.items) |item| {
                if (item != .string) {
                    self.sendError(conn, 400, "args must be an array of strings");
                    return;
                }
                args.append(allocator, item.string) catch return;
            }
        }

        const session_id = stringOf(root, "sessionId");
        var response = self.bridge.run(.{
            .request_id = request_id,
            .command = command,
            .args = args.items,
            .session_id = session_id,
            .timeout_ms = timeoutOf(root),
        }) catch |err| {
            // Refused here, before the child saw anything: that is the client's
            // request being too large, not the daemon failing to answer.
            if (err == bridge_mod.Error.RequestTooLarge) {
                self.sendError(conn, 413, "the encoded request exceeds the TinyKG request limit");
                return;
            }
            self.reportDaemonFailure(conn, err);
            return;
        };
        defer response.deinit();
        self.sendEnvelope(conn, allocator, request_id, session_id, &response);
    }

    /// Any failure after the request reached the child desynchronizes the pipe
    /// — a timeout, an exit, a malformed line — and the bridge marks itself
    /// broken. Every later request would then fail the same way, so the service
    /// stops and says so instead of answering 503 forever.
    fn reportDaemonFailure(self: *Supervisor, conn: net.Socket, err: anyerror) void {
        log.warn("kgd", "tinykgd request failed: {s}", .{@errorName(err)});
        if (self.bridge.isBroken()) {
            self.daemon_wedged = true;
            self.stop();
        }
        self.sendError(conn, 503, "tinykgd is not answering");
    }

    /// Markdown never reaches the daemon as an argument: the engine ingests a
    /// file, so the bytes are staged in a directory this process owns and the
    /// path is what crosses the boundary. The client's `sourceKey` keeps the
    /// engine's stable-external-key upsert behaviour, so it names the file.
    fn handleImportMarkdown(self: *Supervisor, conn: net.Socket, allocator: std.mem.Allocator, body: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
            self.sendError(conn, 400, "request body is not JSON");
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            self.sendError(conn, 400, "request body is not a JSON object");
            return;
        }
        const root = parsed.value.object;
        if (!self.protocolAccepted(conn, root)) return;
        const request_id = self.requestIdOf(conn, root) orelse return;
        const markdown = stringOf(root, "markdown") orelse {
            self.sendError(conn, 400, "markdown is required");
            return;
        };
        const source_key = stringOf(root, "sourceKey") orelse "";
        if (!sourceKeyValid(source_key)) {
            self.sendError(conn, 400, "sourceKey must be 16 lowercase hexadecimal characters");
            return;
        }

        const staged = self.stageMarkdown(allocator, source_key, markdown) catch {
            self.sendError(conn, 500, "cannot stage the markdown document");
            return;
        };
        defer removeFile(staged);

        var digest_buffer: [71]u8 = undefined;
        @memcpy(digest_buffer[0..7], "sha256:");
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(markdown, &hash, .{});
        _ = std.fmt.bufPrint(digest_buffer[7..], "{x}", .{&hash}) catch unreachable;

        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(allocator);
        args.append(allocator, staged) catch return;
        if (stringOf(root, "sourceLabel")) |label| {
            if (label.len > 0) {
                args.append(allocator, "--source-label") catch return;
                args.append(allocator, label) catch return;
            }
        }

        var response = self.bridge.run(.{
            .request_id = request_id,
            .command = "import-md-doc",
            .args = args.items,
            .content_digest = digest_buffer[0..],
            .timeout_ms = timeoutOf(root),
        }) catch |err| {
            self.reportDaemonFailure(conn, err);
            return;
        };
        defer response.deinit();
        self.sendEnvelope(conn, allocator, request_id, null, &response);
    }

    /// The engine ingests a file, and its stable-external-key upsert wants the
    /// name to be the client's `sourceKey`. That name is predictable, and the
    /// store can sit in a shared directory, so it is never opened directly:
    /// someone could have left a symlink there and an authenticated import
    /// would truncate whatever it points at. The bytes go into an exclusive
    /// randomly named temporary that refuses to follow a link, and a rename
    /// then puts them under the stable name — replacing a planted link itself
    /// rather than writing through it.
    fn stageMarkdown(
        self: *Supervisor,
        allocator: std.mem.Allocator,
        source_key: []const u8,
        markdown: []const u8,
    ) ![]const u8 {
        const dir = try std.fmt.allocPrint(allocator, "{s}.import", .{self.options.store_path});
        try @import("../../util/fs.zig").mkdirParents(dir);
        restrictDirectory(allocator, dir);

        var suffix: [8]u8 = undefined;
        if (!@import("platform").rng.randomBytes(&suffix)) return error.StageFailed;
        var suffix_hex: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&suffix_hex, "{x}", .{&suffix}) catch return error.StageFailed;
        const temporary = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}.{s}.tmp", .{ dir, source_key, suffix_hex }, 0);
        const fd = pfs.open(
            temporary.ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true },
            0o600,
        );
        if (fd < 0) return error.StageFailed;
        errdefer removeFile(temporary);
        var written: usize = 0;
        while (written < markdown.len) {
            const n = pfs.write(fd, markdown[written..]);
            if (n <= 0) {
                _ = pfs.close(fd);
                return error.StageFailed;
            }
            written += @intCast(n);
        }
        _ = pfs.close(fd);

        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}.md", .{ dir, source_key }, 0);
        if (pfs.renameReplace(temporary.ptr, path.ptr) != 0) {
            removeFile(temporary);
            return error.StageFailed;
        }
        return path;
    }

    fn protocolAccepted(self: *Supervisor, conn: net.Socket, root: std.json.ObjectMap) bool {
        const value = root.get("protocolVersion") orelse return true;
        if (value == .integer and value.integer == @as(i64, PROTOCOL_VERSION)) return true;
        self.sendError(conn, 409, "protocol version mismatch");
        return false;
    }

    fn requestIdOf(self: *Supervisor, conn: net.Socket, root: std.json.ObjectMap) ?[]const u8 {
        const value = stringOf(root, "requestId") orelse {
            self.sendError(conn, 400, "requestId is required");
            return null;
        };
        if (!identifierValid(value)) {
            self.sendError(conn, 400, "requestId is not a valid identifier");
            return null;
        }
        return value;
    }

    /// Every capability the client requires must be one the engine declares.
    /// Serving a request whose requirement is unmet would answer with data the
    /// client believes carries a guarantee it does not have.
    fn capabilitiesSatisfied(self: *Supervisor, conn: net.Socket, root: std.json.ObjectMap) bool {
        const raw = root.get("requiredCapabilities") orelse return true;
        if (raw != .array or raw.array.items.len > identity_mod.MAX_CAPABILITIES) {
            self.sendError(conn, 400, "requiredCapabilities must be an array of capability names");
            return false;
        }
        for (raw.array.items) |item| {
            if (item != .string or item.string.len == 0) {
                self.sendError(conn, 400, "requiredCapabilities must be an array of capability names");
                return false;
            }
            if (!self.identity.declares(item.string)) {
                self.sendError(conn, 409, "the TinyKG engine does not declare a required capability");
                return false;
            }
        }
        return true;
    }

    fn sendEnvelope(
        self: *Supervisor,
        conn: net.Socket,
        allocator: std.mem.Allocator,
        request_id: []const u8,
        requested_session: ?[]const u8,
        response: *const bridge_mod.Response,
    ) void {
        const body = self.renderEnvelope(allocator, request_id, requested_session, response) catch {
            self.sendError(conn, 500, "cannot render the response envelope");
            return;
        };
        self.send(conn, 200, body);
    }

    pub fn renderEnvelope(
        self: *const Supervisor,
        allocator: std.mem.Allocator,
        request_id: []const u8,
        requested_session: ?[]const u8,
        response: *const bridge_mod.Response,
    ) ![]u8 {
        const Session = struct { sessionId: []const u8, generation: i64 };
        // A session receipt the client cannot check is worse than none: the
        // client validates `session` only when it is present, so dropping a
        // malformed one would turn a broken receipt into an unbound answer.
        const session: ?Session = blk: {
            const raw = response.parsed.value.object.get("session") orelse break :blk null;
            // The daemon emits `"session":null` for commands that have none.
            // That is an absent session — unless this request asked for one, in
            // which case an answer without a receipt is exactly the unbound
            // result the client's session check exists to refuse.
            if (raw == .null) {
                if (requested_session != null) return error.MalformedSession;
                break :blk null;
            }
            if (raw != .object) return error.MalformedSession;
            const id = raw.object.get("sessionId") orelse return error.MalformedSession;
            const generation = raw.object.get("generation") orelse return error.MalformedSession;
            if (id != .string or generation != .integer) return error.MalformedSession;
            break :blk .{ .sessionId = id.string, .generation = generation.integer };
        };
        const envelope = .{
            .protocolVersion = PROTOCOL_VERSION,
            .controlPlaneVersion = CONTROL_PLANE_VERSION,
            .implementation = identity_mod.SERVICE_IMPLEMENTATION,
            .schemaMode = SCHEMA_MODE,
            .buildId = self.identity.buildId(),
            .requestId = request_id,
            .engine = .{
                .implementation = self.identity.engine_implementation,
                .version = self.identity.engine_version,
                .binarySha256 = self.identity.cli_sha256[0..],
                .metadataValid = true,
            },
            .capabilities = self.capabilities,
            .schemaDigest = self.schema_digest[0..],
            .ok = response.boolean("ok"),
            .code = response.integer("code") orelse 1,
            .stdout = response.string("stdout") orelse "",
            .stderr = response.string("stderr") orelse "",
            .generation = response.integer("generation") orelse 0,
            .commitState = commitStateOf(response),
            .replayed = response.boolean("replayed"),
            .session = session,
        };
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try std.json.Stringify.value(envelope, .{ .emit_null_optional_fields = false }, &out.writer);
        return out.toOwnedSlice();
    }

    fn sendError(self: *Supervisor, conn: net.Socket, status: u16, reason: []const u8) void {
        var buffer: [512]u8 = undefined;
        // The reason is a fixed string chosen here, never client-supplied
        // bytes, so no escaping question arises.
        const body = std.fmt.bufPrint(&buffer, "{{\"ok\":false,\"error\":\"{s}\"}}", .{reason}) catch
            "{\"ok\":false,\"error\":\"request refused\"}";
        self.send(conn, status, body);
    }

    fn send(self: *Supervisor, conn: net.Socket, status: u16, body: []const u8) void {
        var head_buffer: [256]u8 = undefined;
        const head = std.fmt.bufPrint(
            &head_buffer,
            "HTTP/1.1 {d} {s}\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n",
            .{ status, statusText(status), body.len },
        ) catch return;
        const deadline = self.response_deadline_ms;
        sendAll(conn, head, deadline);
        sendAll(conn, body, deadline);
    }
};

/// Reads one request in two phases so the caller can authenticate between
/// them, under one wall-clock deadline for the whole exchange.
const RequestReader = struct {
    allocator: std.mem.Allocator,
    conn: net.Socket,
    deadline_ms: i64,
    buffer: std.ArrayList(u8) = .empty,
    body_start: usize = 0,

    fn init(allocator: std.mem.Allocator, conn: net.Socket, deadline_ms: i64) RequestReader {
        return .{ .allocator = allocator, .conn = conn, .deadline_ms = deadline_ms };
    }

    fn deinit(self: *RequestReader) void {
        self.buffer.deinit(self.allocator);
    }

    /// The head including its final CRLF, so header parsing sees every header
    /// line and nothing of the body. Returned as its own allocation: reading
    /// the body appends to `buffer`, which can move it, and the caller still
    /// holds the request line and the API key header afterwards.
    fn readHead(self: *RequestReader) ![]const u8 {
        while (true) {
            if (std.mem.indexOf(u8, self.buffer.items, "\r\n\r\n")) |head_end| {
                // Checked here too: a head that crosses the cap inside the same
                // read that completes it would otherwise be accepted.
                if (head_end + 4 > MAX_HEAD_BYTES) return error.HeadTooLarge;
                self.body_start = head_end + 4;
                return try self.allocator.dupe(u8, self.buffer.items[0 .. head_end + 2]);
            }
            if (self.buffer.items.len > MAX_HEAD_BYTES) return error.HeadTooLarge;
            try self.fill();
        }
    }

    fn readBody(self: *RequestReader, head: []const u8) ![]const u8 {
        const content_length = http.parseContentLength(head) orelse 0;
        if (content_length > MAX_BODY_BYTES) return error.BodyTooLarge;
        // Bounded by the check above, so the sum cannot wrap on a hostile
        // content-length.
        while (self.buffer.items.len < self.body_start + content_length) try self.fill();
        return self.buffer.items[self.body_start .. self.body_start + content_length];
    }

    fn fill(self: *RequestReader) !void {
        // Poll in slices rather than trusting SO_RCVTIMEO: if the option did
        // not take, a peer that sends nothing would block `recv` forever and
        // the deadline check above it would never run again.
        while (!net.pollReadable(self.conn, SOCKET_POLL_SLICE_MS)) {
            if (time.nowMs() >= self.deadline_ms) return error.RequestDeadlineExceeded;
        }
        if (time.nowMs() >= self.deadline_ms) return error.RequestDeadlineExceeded;
        var chunk: [8 * 1024]u8 = undefined;
        const n = net.recv(self.conn, &chunk);
        if (n <= 0) return error.ConnectionClosed;
        try self.buffer.appendSlice(self.allocator, chunk[0..@intCast(n)]);
    }
};

fn statusForRead(err: anyerror) u16 {
    return switch (err) {
        error.BodyTooLarge, error.HeadTooLarge => 413,
        error.RequestDeadlineExceeded => 408,
        else => 400,
    };
}

/// Writes until done, the peer goes away, or the deadline passes.
///
/// The socket is non-blocking for this: writability only promises that *some*
/// space exists, while `send` is handed the whole remainder, so a blocking
/// write can still park inside the kernel after the poll said yes. With
/// `would_block` bouncing back to the poll, the deadline is the only thing that
/// decides how long this thread stays here.
fn sendAll(conn: net.Socket, bytes: []const u8, deadline_ms: i64) void {
    _ = net.setNonblocking(conn, true);
    defer _ = net.setNonblocking(conn, false);
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (time.nowMs() >= deadline_ms) return;
        switch (net.sendSome(conn, bytes[offset..])) {
            .sent => |n| offset += n,
            .failed => return,
            .would_block => {
                // Waits for space or for the peer to fail; either way the next
                // iteration re-checks the clock.
                _ = net.pollWritable(conn, SOCKET_POLL_SLICE_MS);
            },
        }
    }
}

/// Compares in time independent of how many leading bytes match, so a peer
/// cannot discover the key one byte at a time.
pub fn constantTimeEql(presented: []const u8, expected: []const u8) bool {
    if (presented.len != expected.len or expected.len == 0) return false;
    var diff: u8 = 0;
    for (presented, expected) |a, b| diff |= a ^ b;
    return diff == 0;
}

pub fn identifierValid(value: []const u8) bool {
    if (value.len == 0 or value.len > MAX_REQUEST_ID_BYTES) return false;
    for (value) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', ':' => {},
        else => return false,
    };
    return true;
}

pub fn sourceKeyValid(value: []const u8) bool {
    if (value.len != 16) return false;
    for (value) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn commitStateOf(response: *const bridge_mod.Response) []const u8 {
    const raw = response.string("commitState") orelse return "none";
    if (std.mem.eql(u8, raw, "committed")) return "committed";
    if (std.mem.eql(u8, raw, "ambiguous")) return "ambiguous";
    return "none";
}

fn timeoutOf(root: std.json.ObjectMap) u64 {
    const value = root.get("timeoutMs") orelse return 180_000;
    if (value != .integer or value.integer <= 0 or value.integer > 3_600_000) return 180_000;
    return @intCast(value.integer);
}

fn stringOf(root: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = root.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

/// `key=value` lines, as every TinyKG CLI informational command prints them.
fn infoField(stdout: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (std.mem.eql(u8, trimmed[0..eq], name)) return trimmed[eq + 1 ..];
    }
    return null;
}

/// Best effort: the directory may predate this build with looser bits, and a
/// failure here is not a reason to refuse an import that is otherwise safe
/// because of the exclusive temporary above.
fn restrictDirectory(allocator: std.mem.Allocator, path: []const u8) void {
    if (@import("builtin").os.tag == .windows) return;
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);
    _ = std.c.chmod(path_z.ptr, 0o700);
}

fn removeFile(path: []const u8) void {
    var buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buffer.len) return;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    _ = std.c.unlink(&buffer);
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn statusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        409 => "Conflict",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "Error",
    };
}

const testing = std.testing;

test "KgdServer: the api key comparison is length-safe and constant-time shaped" {
    try testing.expect(constantTimeEql("abc", "abc"));
    try testing.expect(!constantTimeEql("abc", "abd"));
    try testing.expect(!constantTimeEql("ab", "abc"));
    // An empty configured key must never authenticate anyone, including a peer
    // that sends no header at all (which arrives here as "").
    try testing.expect(!constantTimeEql("", ""));
}

test "KgdServer: identifiers and source keys reject what the daemon would" {
    try testing.expect(identifierValid("metacodes-kgd-1.2:3_4"));
    try testing.expect(!identifierValid(""));
    try testing.expect(!identifierValid("has space"));
    try testing.expect(!identifierValid("has/slash"));
    try testing.expect(!identifierValid("x" ** 129));
    try testing.expect(sourceKeyValid("0123456789abcdef"));
    try testing.expect(!sourceKeyValid("0123456789ABCDEF"));
    try testing.expect(!sourceKeyValid("0123456789abcde"));
}

test "KgdServer: informational fields are read by exact key" {
    const stdout = "db=/tmp/x\nstorage_format_version=3\nschema_version=3\nnodes=0\n";
    try testing.expectEqualStrings("3", infoField(stdout, "storage_format_version").?);
    try testing.expectEqualStrings("3", infoField(stdout, "schema_version").?);
    try testing.expectEqualStrings("/tmp/x", infoField(stdout, "db").?);
    try testing.expect(infoField(stdout, "version") == null);
    try testing.expect(infoField(stdout, "nodes_total") == null);
}

test "KgdServer: a timeout outside the daemon's range falls back to the default" {
    const a = testing.allocator;
    for ([_][]const u8{
        "{\"timeoutMs\":0}",
        "{\"timeoutMs\":-1}",
        "{\"timeoutMs\":3600001}",
        "{\"timeoutMs\":\"soon\"}",
        "{}",
    }) |body| {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        try testing.expectEqual(@as(u64, 180_000), timeoutOf(parsed.value.object));
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"timeoutMs\":35000}", .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(u64, 35_000), timeoutOf(parsed.value.object));
}
