//! MCP 高层客户端(stdio)。
//!
//! 生命周期:connect → (发现协议版本) → listTools / callTool / resources → close。
//!
//! 协议版本(对齐 2026-07-28 规范的"双时代"客户端,见 basic/transports/stdio.mdx
//! "Backward Compatibility"):
//! - `.auto`(默认):先发 `server/discover`。得到 DiscoverResult(或带 `supported`
//!   的 -32022)且支持 2026-07-28 → Modern:无握手,每个请求带
//!   `_meta["io.modelcontextprotocol/…"]`,结果带 `resultType`,输入需求走 MRTR。
//!   其余任何错误 / 超时 / 子进程退出 → Classic(不按某个错误码判定,规范 MUST)。
//!   探测让子进程退出或超时时重启子进程再握手(Rust SDK 一类 server 在
//!   initialize 前收到请求会直接退出)。
//! - Classic:`initialize` 请求 2025-11-25,接受 server 选定的
//!   2025-11-25 / 2025-06-18 / 2025-03-26 / 2024-11-05;其后 `notifications/initialized`。
//!   回应 server→client 的 `ping`、`elicitation/create`(form 模式);未声明的
//!   `roots/list`、`sampling/createMessage` 回 method_not_found。
//!
//! 共通:`tools/list` 按 `nextCursor` 翻页(空串游标也表示还有下一页);中断/超时
//! 发 `notifications/cancelled`;`notifications/tools/list_changed` 记入 `tools_changed`。
//! stdio 是单一有序 JSON-RPC 流,同一时刻只允许一个请求占用收发循环(request_mutex)。

const std = @import("std");
const protocol = @import("protocol.zig");
const StdioTransport = @import("transport_stdio.zig").StdioTransport;
const transport_mod = @import("transport.zig");
const Transport = transport_mod.Transport;
const HttpTransport = transport_mod.HttpTransport;
const SseTransport = transport_mod.SseTransport;
const HttpWire = @import("config.zig").HttpWire;
const TokenSource = @import("oauth.zig").TokenSource;
const platform = @import("platform");
const sync = platform.sync;
const process = platform.process;
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const artifact_store = @import("../core/tool_result_artifact.zig");
const ToolResultBody = @import("../core/tool_result.zig").ToolResultBody;
const tool_error = @import("../core/tool_error.zig");
const ToolError = tool_error.ToolError;
const result_budget = @import("../core/result_budget.zig");
const result_stream = @import("../agentcore/mcp_result_stream.zig");
const json_util = @import("../util/json.zig");
const util_time = @import("../util/time.zig");

pub const MODERN_VERSION = "2026-07-28";
pub const CLASSIC_VERSION = "2025-11-25";
/// Classic revisions this client speaks, newest first.
pub const CLASSIC_VERSIONS = [_][]const u8{ "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05" };

/// The client's capabilities: form-mode elicitation only. (`{}` means form
/// mode from 2025-11-25 on, and plain elicitation support in 2025-06-18.)
const CLIENT_CAPABILITIES_JSON = "{\"elicitation\":{}}";

/// MRTR rounds one request may take before the client gives up.
const MAX_INPUT_ROUNDS: usize = 8;
/// `tools/list` pagination bounds (Codex main: 100 pages, 2048 tools).
const MAX_LIST_PAGES: usize = 100;
const MAX_LISTED_TOOLS: usize = 2048;

/// elicitation 回调:server 请求用户输入时被调(Classic 的 `elicitation/create` 请求与
/// Modern 的 MRTR 输入需求共用)。入参 = elicitation params JSON(含 message/requestedSchema);
/// 返回 = 用户回复的 content 对象 JSON(owned by 传入 allocator)或 null=用户拒绝。
pub const ElicitHandler = struct {
    ctx: *anyopaque,
    handleFn: *const fn (ctx: *anyopaque, params_json: []const u8, alloc: std.mem.Allocator) ?[]u8,
};

/// Frames up to this size are materialized before they are classified: a
/// server→client control frame (elicitation) has to be answered synchronously,
/// and only a parsed frame can be told apart from a response. It is also the
/// ceiling of what this client has ever held inline, which is why the
/// failed-publication fallback retains results up to it rather than only up to
/// `result_budget.PER_RESULT_MAX_BYTES`: the bytes are already in memory.
pub const CONTROL_FRAME_MATERIALIZE_BYTES: usize = 1024 * 1024;

pub const ProtocolPolicy = enum {
    /// Probe `server/discover`, fall back to the `initialize` handshake.
    auto,
    /// Require 2026-07-28.
    modern_only,
    /// Skip the probe and speak the handshake revisions only.
    classic_only,
};

pub const SpawnSpec = struct {
    argv: []const ?[*:0]const u8,
    /// Exact child environment (`KEY=VALUE`); null = `inherit_env` semantics.
    env: ?[]const [:0]const u8 = null,
    inherit_env: bool = false,
    cwd: ?[]const u8 = null,
    /// Descriptor receiving the server's stderr; null discards it.
    stderr_fd: ?c_int = null,

    fn options(self: SpawnSpec) process.PipeSpawnOptions {
        return .{ .env = self.env, .inherit_env = self.inherit_env, .cwd = self.cwd, .stderr_fd = self.stderr_fd };
    }
};

pub const ConnectOptions = struct {
    spawn: SpawnSpec,
    /// Bound on the handshake (probe included). null = unbounded.
    startup_timeout_ms: ?u32 = null,
    /// Bound on each tool call / resource read. null = only the user's interrupt.
    request_timeout_ms: ?u32 = null,
    /// Interrupts the handshake (probe included) and nothing after it: the
    /// connect returns `error.Aborted`. Borrowed for the call only.
    abort: ?*const AbortSignal = null,
    protocol: ProtocolPolicy = .auto,
    /// Bound on the `server/discover` probe in `.auto`. A Classic server
    /// answers an unknown method at once (or exits); one that ignores it
    /// costs this long before the handshake.
    probe_timeout_ms: u32 = 10_000,
};

pub const ServerCapabilities = struct {
    tools: bool = false,
    resources: bool = false,
    prompts: bool = false,
};

pub const McpClient = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    next_id: u64 = 1,
    initialized: bool = false,
    /// stdio transport is one ordered JSON-RPC stream. Parallel agent tools
    /// may call the same server concurrently, but only one request may own the
    /// send/recv loop at a time or responses can be consumed by the wrong call.
    request_mutex: sync.Mutex = .{},
    /// server→client elicitation 回调(可选)。未设 → 一律 decline(协议仍正确闭合,server 不卡)。
    elicit: ?ElicitHandler = null,
    /// Negotiated revision (a static string).
    protocol_version: []const u8 = CLASSIC_VERSION,
    /// 2026-07-28: no session; every request carries `_meta`.
    modern: bool = false,
    capabilities: ServerCapabilities = .{},
    request_timeout_ms: ?u32 = null,
    /// Set when the server announces `notifications/tools/list_changed`.
    tools_changed: std.atomic.Value(bool) = .init(false),
    /// `Mcp-Param-*` headers of the call in flight (borrowed; guarded by the
    /// request mutex taken in `requestBody`).
    param_headers: []const transport_mod.Header = &.{},

    /// Historical entry point: empty environment, no deadlines, `.auto` protocol.
    pub fn connect(
        allocator: std.mem.Allocator,
        argv: []const ?[*:0]const u8,
    ) !McpClient {
        return connectWith(allocator, .{ .spawn = .{ .argv = argv } });
    }

    pub fn connectWith(allocator: std.mem.Allocator, options: ConnectOptions) !McpClient {
        var client = McpClient{
            .allocator = allocator,
            .transport = .{ .stdio = try StdioTransport.spawnWith(allocator, options.spawn.argv, options.spawn.options()) },
            .request_timeout_ms = options.request_timeout_ms,
        };
        // Whichever child is current (the probe may have replaced it) is
        // reaped on failure.
        errdefer client.transport.close();
        // request_mutex has not been used yet: McpClient is still a local value
        // that will be moved into caller storage on return. Never lock a pthread
        // mutex before that move.
        const started = util_time.nowMs();
        const startup_deadline: ?i64 = if (options.startup_timeout_ms) |ms| started + ms else null;
        if (options.protocol != .classic_only) {
            const probe_deadline = minDeadline(startup_deadline, started + options.probe_timeout_ms);
            switch (try client.probeModern(probe_deadline, options.abort)) {
                .modern => {
                    client.transport.setDeadline(null);
                    client.initialized = true;
                    return client;
                },
                .classic => {},
                .restart => {
                    // The probe killed or wedged the server: start a fresh one
                    // for the handshake, unless the startup budget is spent.
                    if (startup_deadline) |deadline| {
                        if (util_time.nowMs() >= deadline) return error.McpRequestTimeout;
                    }
                    if (options.abort) |signal| if (signal.isAborted()) return error.Aborted;
                    // Spawn first: if that fails, the errdefer still owns a
                    // valid transport to reap.
                    const replacement = try StdioTransport.spawnWith(allocator, options.spawn.argv, options.spawn.options());
                    client.transport.close();
                    client.transport = .{ .stdio = replacement };
                },
            }
            if (options.protocol == .modern_only) return error.UnsupportedProtocolVersion;
        }
        client.transport.setDeadline(startup_deadline);
        try client.initializeClassic(options.abort);
        client.transport.setDeadline(null);
        return client;
    }

    pub const HttpSpec = struct {
        io: std.Io,
        url: []const u8,
        /// Configured headers, `Authorization` included.
        headers: []const transport_mod.Header = &.{},
        wire: HttpWire = .streamable,
        /// A stored OAuth login, consumed: the transport owns it from here,
        /// and it is destroyed here when the transport cannot be created.
        auth: ?*TokenSource = null,
    };

    /// Streamable HTTP. The probe falls back to the handshake only on a
    /// completed non-Modern answer; a timeout, a network failure or 401/403
    /// is an error, never evidence of an older server.
    ///
    /// HTTP+SSE (`wire = .legacy_sse`): the stream is opened and its
    /// `endpoint` awaited within the startup timeout, then the Classic
    /// handshake runs (that transport predates `server/discover`).
    pub fn connectHttp(allocator: std.mem.Allocator, spec: HttpSpec, options: ConnectOptions) !McpClient {
        const started = util_time.nowMs();
        const startup_deadline: ?i64 = if (options.startup_timeout_ms) |ms| started + ms else null;
        const transport: Transport = switch (spec.wire) {
            .streamable => .{ .http = try HttpTransport.createWithAuth(allocator, spec.io, spec.url, spec.headers, spec.auth) },
            .legacy_sse => .{ .sse = try SseTransport.create(allocator, spec.io, spec.url, spec.headers, .{
                .deadline_ms = startup_deadline,
                .abort = options.abort,
                .auth = spec.auth,
            }) },
        };
        var client = McpClient{
            .allocator = allocator,
            .transport = transport,
            .request_timeout_ms = options.request_timeout_ms,
        };
        errdefer client.transport.close();
        if (spec.wire == .legacy_sse) {
            client.transport.setDeadline(startup_deadline);
            try client.initializeClassic(options.abort);
            client.transport.setDeadline(null);
            return client;
        }
        if (options.protocol != .classic_only) {
            switch (try client.probeModern(minDeadline(startup_deadline, started + options.probe_timeout_ms), options.abort)) {
                .modern => {
                    client.transport.setDeadline(null);
                    client.initialized = true;
                    return client;
                },
                .classic => {},
                .restart => return error.McpConnectFailed,
            }
            if (options.protocol == .modern_only) return error.UnsupportedProtocolVersion;
        }
        client.transport.setDeadline(startup_deadline);
        try client.initializeClassic(options.abort);
        client.transport.setDeadline(null);
        return client;
    }

    pub fn close(self: *McpClient) void {
        self.transport.close();
    }

    fn nextId(self: *McpClient) u64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn setModern(self: *McpClient, modern: bool) void {
        self.modern = modern;
        if (self.transport == .http) {
            self.transport.http.modern = modern;
            self.transport.http.protocol_version = if (modern) MODERN_VERSION else null;
        }
    }

    const ProbeOutcome = enum { modern, classic, restart };

    /// `server/discover` with the Modern `_meta`. Only a Modern answer selects
    /// Modern; every other outcome falls back (never keyed to one error code).
    fn probeModern(self: *McpClient, deadline: i64, abort: ?*const AbortSignal) !ProbeOutcome {
        const id = self.nextId();
        self.setModern(true);
        defer if (!self.initialized) self.setModern(false);
        const params = try self.wireParams(self.allocator, "{}");
        defer self.allocator.free(params);
        const request_bytes = try protocol.serializeRequest(self.allocator, id, "server/discover", params);
        defer self.allocator.free(request_bytes);
        self.transport.setDeadline(deadline);
        defer self.transport.setDeadline(null);
        self.transport.setAbort(abort);
        defer self.transport.setAbort(null);
        const is_http = self.transport.isHttp();
        self.transport.send(request_bytes, .{ .method = "server/discover" }) catch |err| {
            // HTTP: no reply is not evidence of an older server.
            if (is_http) return err;
            return .restart;
        };
        defer self.transport.markAnswered();
        while (true) {
            const line = self.transport.recvLine() catch |err| {
                if (is_http) return if (err == error.Eof) .classic else err;
                return .restart;
            };
            defer self.allocator.free(line);
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const object = parsed.value.object;
            if (object.get("method") != null) continue; // a pre-handshake log notification
            if (responseId(object) != id) continue;
            if (object.get("result")) |result| {
                if (result == .object and listsVersion(result.object.get("supportedVersions"), MODERN_VERSION)) {
                    self.protocol_version = MODERN_VERSION;
                    self.capabilities = parseCapabilities(result.object.get("capabilities"));
                    self.initialized = true;
                    return .modern;
                }
                return .classic;
            }
            if (object.get("error")) |err| {
                // -32022 UnsupportedProtocolVersion carries `data.supported`.
                if (err == .object) if (err.object.get("data")) |data| if (data == .object) {
                    if (listsVersion(data.object.get("supported"), MODERN_VERSION)) {
                        self.protocol_version = MODERN_VERSION;
                        self.capabilities = .{ .tools = true };
                        self.initialized = true;
                        return .modern;
                    }
                };
            }
            return .classic;
        }
    }

    fn initializeClassic(self: *McpClient, abort: ?*const AbortSignal) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try out.writer.print("{{\"protocolVersion\":\"{s}\",\"capabilities\":{s},\"clientInfo\":{{\"name\":\"metacodes\",\"version\":", .{ CLASSIC_VERSION, CLIENT_CAPABILITIES_JSON });
        try json_util.writeJsonString(&out.writer, @import("../version.zig").semver);
        try out.writer.writeAll("}}");
        const params = out.written();

        const result = try self.requestUnlocked("initialize", params, abort);
        defer self.allocator.free(result);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, result, .{}) catch
            return error.McpMalformedResponse;
        defer parsed.deinit();
        if (parsed.value != .object) return error.McpMalformedResponse;
        const chosen = parsed.value.object.get("protocolVersion") orelse return error.McpMalformedResponse;
        if (chosen != .string) return error.McpMalformedResponse;
        // The server picks; disconnect when it picks a revision we do not speak
        // (lifecycle.mdx "Version Negotiation").
        self.protocol_version = for (CLASSIC_VERSIONS) |version| {
            if (std.mem.eql(u8, version, chosen.string)) break version;
        } else return error.UnsupportedProtocolVersion;
        self.capabilities = parseCapabilities(parsed.value.object.get("capabilities"));

        // HTTP: later requests carry the negotiated revision.
        self.transport.setProtocolVersion(self.protocol_version);
        const notif = try protocol.serializeNotification(self.allocator, "notifications/initialized", "{}");
        defer self.allocator.free(notif);
        try self.transport.send(notif, .{ .method = "notifications/initialized" });
        self.initialized = true;
    }

    /// Request params as sent on the wire: Modern requests carry the protocol
    /// version, client capabilities and client info in `_meta`.
    fn wireParams(self: *const McpClient, allocator: std.mem.Allocator, params_json: []const u8) ![]u8 {
        if (!self.modern) return allocator.dupe(u8, params_json);
        const trimmed = std.mem.trim(u8, params_json, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return error.McpInvalidParams;
        const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try out.writer.print(
            "{{\"_meta\":{{\"io.modelcontextprotocol/protocolVersion\":\"{s}\",\"io.modelcontextprotocol/clientCapabilities\":{s},\"io.modelcontextprotocol/clientInfo\":{{\"name\":\"metacodes\",\"version\":",
            .{ MODERN_VERSION, CLIENT_CAPABILITIES_JSON },
        );
        try json_util.writeJsonString(&out.writer, @import("../version.zig").semver);
        try out.writer.writeAll("}}");
        if (inner.len != 0) {
            try out.writer.writeByte(',');
            try out.writer.writeAll(inner);
        }
        try out.writer.writeByte('}');
        return out.toOwnedSlice();
    }

    /// 发请求并返回 result_json（owned，caller free）。失败返 error.McpError。
    fn request(self: *McpClient, method: []const u8, params_json: []const u8, abort: ?*const AbortSignal) ![]u8 {
        self.request_mutex.lock();
        defer self.request_mutex.unlock();
        return self.requestUnlocked(method, params_json, abort);
    }

    /// One logical request, including Modern MRTR rounds (each retry is a new
    /// JSON-RPC id carrying `inputResponses` and the echoed `requestState`).
    fn requestUnlocked(self: *McpClient, method: []const u8, params_json: []const u8, abort: ?*const AbortSignal) ![]u8 {
        var params = try self.allocator.dupe(u8, params_json);
        defer self.allocator.free(params);
        var round: usize = 0;
        while (true) : (round += 1) {
            const result = try self.exchangeUnlocked(method, params, abort);
            if (!self.modern or !isInputRequired(self.allocator, result)) return result;
            defer self.allocator.free(result);
            if (round + 1 >= MAX_INPUT_ROUNDS or !mrtrMethod(method)) return error.McpInputRequired;
            const retry = try self.retryParams(params, result);
            self.allocator.free(params);
            params = retry;
        }
    }

    /// Send one JSON-RPC request and read until its response. Server→client
    /// requests (Classic) are answered in place, notifications recorded.
    fn exchangeUnlocked(self: *McpClient, method: []const u8, params_json: []const u8, abort: ?*const AbortSignal) ![]u8 {
        const id = self.nextId();
        const params = try self.wireParams(self.allocator, params_json);
        defer self.allocator.free(params);
        const req = try protocol.serializeRequest(self.allocator, id, method, params);
        defer self.allocator.free(req);
        self.transport.setAbort(abort);
        defer self.transport.setAbort(null);
        var meta_scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer meta_scratch.deinit();
        self.transport.send(req, try sendMeta(meta_scratch.allocator(), method, params_json)) catch |err| return sendFailure(err);
        defer self.transport.markAnswered();

        while (true) {
            const line = self.transport.recvLine() catch |err| return self.failInFlight(id, err);
            defer self.allocator.free(line);

            // **按顶层字段分类**(不是全文子串扫):JSON-RPC 铁律——请求/通知有顶层 method,响应有顶层
            // result/error 且从不有 method。子串扫会被 params/requestedSchema 里名为 method/result/error
            // 的**嵌套属性**误导(Linus:elicitation 的 requestedSchema 含 "result" 属性 → 死锁)。
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
                return error.McpMalformedResponse;
            };
            defer parsed.deinit();
            if (parsed.value != .object) return error.McpMalformedResponse;
            const obj = parsed.value.object;

            if (try self.handleIncoming(obj, line)) continue;

            // 否则是响应:按顶层 id 匹配;result/error 从原行提取(顶层)。
            const resp_id = responseId(obj);
            if (resp_id != null and resp_id.? != id) continue; // 非本请求(如已取消请求的迟到响应)→ 丢弃
            if (obj.get("error") != null) return error.McpError;
            const resp = protocol.parseResponse(line) catch return error.McpMalformedResponse;
            if (!resp.isSuccess()) return error.McpError;
            if (resp.result_json) |r| return try self.allocator.dupe(u8, r);
            return try self.allocator.dupe(u8, "null");
        }
    }

    /// A message with a top-level `method` is a server request or a
    /// notification, never the awaited response. Returns true when handled.
    fn handleIncoming(self: *McpClient, obj: std.json.ObjectMap, line: []const u8) !bool {
        const method_value = obj.get("method") orelse return false;
        if (method_value != .string) return false;
        if (obj.get("id")) |idv| {
            if (idv == .integer and idv.integer >= 0) {
                self.handleServerRequest(@intCast(idv.integer), method_value.string, line);
            }
            return true;
        }
        if (std.mem.eql(u8, method_value.string, "notifications/tools/list_changed"))
            self.tools_changed.store(true, .release);
        return true;
    }

    /// Interrupted or timed out: tell the server (stdio cancels with a
    /// notification in every revision), then report the failure.
    fn failInFlight(self: *McpClient, id: u64, err: anyerror) anyerror {
        switch (err) {
            error.Aborted, error.Timeout => {
                // HTTP cancels by closing the response stream (already done by
                // the transport); stdio sends notifications/cancelled.
                if (self.transport.isHttp()) return if (err == error.Timeout) error.McpRequestTimeout else err;
                const reason = if (err == error.Aborted) "Interrupted by the user" else "Request timed out";
                const params = std.fmt.allocPrint(self.allocator, "{{\"requestId\":{d},\"reason\":\"{s}\"}}", .{ id, reason }) catch
                    return err;
                defer self.allocator.free(params);
                const note = protocol.serializeNotification(self.allocator, "notifications/cancelled", params) catch return err;
                defer self.allocator.free(note);
                // The request's deadline (or interrupt) must not stop the
                // notice that ends it.
                self.transport.setDeadline(null);
                self.transport.setAbort(null);
                self.transport.send(note, .{ .method = "notifications/cancelled" }) catch {};
                return if (err == error.Timeout) error.McpRequestTimeout else err;
            },
            error.McpAuthRequired, error.McpSessionExpired, error.McpServerError, error.McpRedirected, error.McpConnectFailed, error.McpLineTooLarge, error.McpStreamClosed => return err,
            else => return error.McpServerCrashed,
        }
    }

    /// Fulfil a Modern `InputRequiredResult` and return the retry params:
    /// the original params plus `inputResponses` and the echoed `requestState`.
    fn retryParams(self: *McpClient, params_json: []const u8, result_json: []const u8) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, result_json, .{});
        defer parsed.deinit();
        const result = parsed.value.object;

        var responses: std.Io.Writer.Allocating = .init(self.allocator);
        defer responses.deinit();
        try responses.writer.writeByte('{');
        var first = true;
        if (result.get("inputRequests")) |requests| if (requests == .object) {
            var iterator = requests.object.iterator();
            while (iterator.next()) |entry| {
                const request_value = entry.value_ptr.*;
                if (request_value != .object) return error.McpMalformedResponse;
                const input_method = (request_value.object.get("method") orelse return error.McpMalformedResponse);
                if (input_method != .string) return error.McpMalformedResponse;
                const input_params = request_value.object.get("params");
                if (!first) try responses.writer.writeByte(',');
                first = false;
                try json_util.writeJsonString(&responses.writer, entry.key_ptr.*);
                try responses.writer.writeByte(':');
                if (std.mem.eql(u8, input_method.string, "elicitation/create")) {
                    const answer = try self.elicitationResult(input_params);
                    defer self.allocator.free(answer);
                    try responses.writer.writeAll(answer);
                } else if (std.mem.eql(u8, input_method.string, "roots/list")) {
                    // Roots are not declared; an empty list exposes nothing.
                    try responses.writer.writeAll("{\"roots\":[]}");
                } else {
                    // sampling/createMessage is not declared, so it cannot be fulfilled.
                    return error.McpInputUnsupported;
                }
            }
        };
        try responses.writer.writeByte('}');

        const trimmed = std.mem.trim(u8, params_json, " \t\r\n");
        const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try out.writer.writeByte('{');
        // Strip a previous round's fields: each retry carries only the new ones.
        var wrote = false;
        var original = try std.json.parseFromSlice(std.json.Value, self.allocator, trimmed, .{ .parse_numbers = false });
        defer original.deinit();
        _ = inner;
        var fields = original.value.object.iterator();
        while (fields.next()) |field| {
            if (std.mem.eql(u8, field.key_ptr.*, "inputResponses") or std.mem.eql(u8, field.key_ptr.*, "requestState")) continue;
            if (wrote) try out.writer.writeByte(',');
            wrote = true;
            try json_util.writeJsonString(&out.writer, field.key_ptr.*);
            try out.writer.writeByte(':');
            try std.json.Stringify.value(field.value_ptr.*, .{}, &out.writer);
        }
        if (wrote) try out.writer.writeByte(',');
        try out.writer.writeAll("\"inputResponses\":");
        try out.writer.writeAll(responses.written());
        if (result.get("requestState")) |state| {
            if (state != .string) return error.McpMalformedResponse;
            try out.writer.writeAll(",\"requestState\":");
            try json_util.writeJsonString(&out.writer, state.string);
        }
        try out.writer.writeByte('}');
        return out.toOwnedSlice();
    }

    /// `ElicitResult` JSON for an elicitation request: accept with the
    /// handler's content, or decline. URL mode is not declared, so decline.
    fn elicitationResult(self: *McpClient, params: ?std.json.Value) ![]u8 {
        const params_value = params orelse return self.allocator.dupe(u8, "{\"action\":\"decline\"}");
        if (params_value == .object) if (params_value.object.get("mode")) |mode| {
            if (mode == .string and !std.mem.eql(u8, mode.string, "form"))
                return self.allocator.dupe(u8, "{\"action\":\"decline\"}");
        };
        const handler = self.elicit orelse return self.allocator.dupe(u8, "{\"action\":\"decline\"}");
        const params_json = try std.json.Stringify.valueAlloc(self.allocator, params_value, .{});
        defer self.allocator.free(params_json);
        const content = handler.handleFn(handler.ctx, params_json, self.allocator) orelse
            return self.allocator.dupe(u8, "{\"action\":\"decline\"}");
        defer self.allocator.free(content);
        if (!isValidJson(self.allocator, content)) return self.allocator.dupe(u8, "{\"action\":\"decline\"}");
        return std.fmt.allocPrint(self.allocator, "{{\"action\":\"accept\",\"content\":{s}}}", .{content});
    }

    /// Typed byte-zero request path used by model-visible MCP tools/resources.
    /// Frames up to `CONTROL_FRAME_MATERIALIZE_BYTES` are materialized so
    /// server→client control frames can be classified and elicitation stays
    /// synchronous. A successful result's inline-or-publish disposition follows
    /// `budget.per_result_bytes`; if publication fails, the bytes already in
    /// memory are retained inline up to that same limit, which is what this
    /// path did before the threshold change.
    fn requestBody(
        self: *McpClient,
        method: []const u8,
        params_json: []const u8,
        artifact_root: []const u8,
        budget: result_budget.Budget,
        abort: ?*const AbortSignal,
        require_content: bool,
    ) !ToolResultBody {
        var body: ToolResultBody = undefined;
        try self.requestBodyInto(&body, method, params_json, artifact_root, budget, abort, require_content);
        return body;
    }

    /// `requestBody` writing its result to `out`, as `requestBodyUnlocked`
    /// does: in a function returning a ToolResultBody, each `return error.X`
    /// would copy a 3.7 KiB constant, one per error name
    /// (doc/PERF_MEMORY_PRINCIPLES.md §3g).
    fn requestBodyInto(
        self: *McpClient,
        out: *ToolResultBody,
        method: []const u8,
        params_json: []const u8,
        artifact_root: []const u8,
        budget: result_budget.Budget,
        abort: ?*const AbortSignal,
        require_content: bool,
    ) !void {
        self.request_mutex.lock();
        defer self.request_mutex.unlock();
        self.transport.setDeadline(if (self.request_timeout_ms) |ms| util_time.nowMs() + ms else null);
        defer self.transport.setDeadline(null);
        var params = try self.allocator.dupe(u8, params_json);
        defer self.allocator.free(params);
        var round: usize = 0;
        while (true) : (round += 1) {
            var outcome: BodyOutcome = undefined;
            try self.requestBodyUnlocked(&outcome, method, params, artifact_root, budget, abort, require_content);
            switch (outcome) {
                .body => |body| {
                    out.* = body;
                    return;
                },
                .input_required => |result| {
                    defer self.allocator.free(result);
                    if (round + 1 >= MAX_INPUT_ROUNDS) return error.McpInputRequired;
                    const retry = try self.retryParams(params, result);
                    self.allocator.free(params);
                    params = retry;
                },
            }
        }
    }

    const BodyOutcome = union(enum) {
        body: ToolResultBody,
        /// Modern MRTR: the owned result JSON to fulfil and retry.
        input_required: []u8,
    };

    fn requestBodyUnlocked(
        self: *McpClient,
        out: *BodyOutcome,
        method: []const u8,
        params_json: []const u8,
        artifact_root: []const u8,
        budget: result_budget.Budget,
        abort: ?*const AbortSignal,
        require_content: bool,
    ) !void {
        if (artifact_root.len == 0) return error.ArtifactRootUnavailable;
        const id = self.nextId();
        const params = try self.wireParams(self.allocator, params_json);
        defer self.allocator.free(params);
        const req = try protocol.serializeRequest(self.allocator, id, method, params);
        defer self.allocator.free(req);
        self.transport.setAbort(abort);
        defer self.transport.setAbort(null);
        var meta_scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer meta_scratch.deinit();
        var meta = try sendMeta(meta_scratch.allocator(), method, params_json);
        meta.param_headers = self.param_headers;
        self.transport.send(req, meta) catch |err| return sendFailure(err);
        defer self.transport.markAnswered();

        while (true) {
            var capture = try artifact_store.Capture.begin(
                self.allocator,
                artifact_root,
                result_stream.MAX_RESPONSE_BYTES,
            );
            defer capture.deinit();
            self.transport.recvLineCapture(&capture) catch |err| return self.failInFlight(id, err);
            try capture.seal();

            // Server→client requests are intentionally bounded control-plane
            // frames. Materialize only this small class so elicitation keeps
            // its existing synchronous semantics.
            if (capture.bytes <= CONTROL_FRAME_MATERIALIZE_BYTES) {
                const line = try capture.readRangeAlloc(
                    self.allocator,
                    0,
                    @intCast(capture.bytes),
                );
                defer self.allocator.free(line);
                var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{
                    .duplicate_field_behavior = .@"error",
                }) catch return error.McpMalformedResponse;
                defer parsed.deinit();
                if (parsed.value != .object) return error.McpMalformedResponse;
                const obj = parsed.value.object;
                if (try self.handleIncoming(obj, line)) continue;
                const response_id = responseId(obj);
                if (response_id != null and response_id.? != id) continue;
                if (obj.get("error") != null) {
                    out.* = .{ .body = try self.structuredMcpError(line, .other, .user_error) };
                    return;
                }
                const response = protocol.parseResponse(line) catch
                    return error.McpMalformedResponse;
                if (!response.isSuccess()) {
                    out.* = .{ .body = try self.structuredMcpError(line, .other, .user_error) };
                    return;
                }
                const result = response.result_json orelse "null";
                if (self.modern and isInputRequired(self.allocator, result)) {
                    if (!mrtrMethod(method)) return error.McpInputRequired;
                    out.* = .{ .input_required = try self.allocator.dupe(u8, result) };
                    return;
                }
                if (result.len <= budget.per_result_bytes) {
                    out.* = .{ .body = ToolResultBody.initInline(try self.allocator.dupe(u8, result)) };
                    return;
                }
                out.* = .{
                    .body = sealJsonResult(self.allocator, artifact_root, result) catch |err| {
                        // Keep a complete bounded result renderable when CAS publication fails.
                        if (!result_budget.retainInlineAfterFailedPublish(
                            err,
                            result.len,
                            true,
                            CONTROL_FRAME_MATERIALIZE_BYTES,
                        )) return err;
                        out.* = .{ .body = ToolResultBody.initInline(try self.allocator.dupe(u8, result)) };
                        return;
                    },
                };
                return;
            }

            const projected = try result_stream.project(
                self.allocator,
                &capture,
                artifact_root,
                id,
                if (self.modern) .modern_2026_07_28 else .classic_2025_11_25,
                .{},
                budget,
                false,
                require_content,
            );
            switch (projected) {
                .result => |body| out.* = .{ .body = body },
                .diagnostic => |diagnostic| {
                    if (diagnostic.code == .response_id_mismatch) continue;
                    if (diagnostic.code == .resource_limit) {
                        out.* = .{ .body = try self.structuredMcpError(
                            @tagName(diagnostic.code),
                            .io_error,
                            .system_error,
                        ) };
                    } else {
                        out.* = .{ .body = try self.structuredMcpError(
                            @tagName(diagnostic.code),
                            .other,
                            .user_error,
                        ) };
                    }
                },
            }
            return;
        }
    }

    fn structuredMcpError(
        self: *McpClient,
        detail: []const u8,
        code: tool_error.Code,
        category: tool_error.Category,
    ) !ToolResultBody {
        const bounded = detail[0..@min(detail.len, 64 * 1024)];
        const owned = try self.allocator.dupe(u8, bounded);
        const structured_error = ToolError.init(code, category, owned, true);
        defer structured_error.deinit(self.allocator);
        const encoded = try structured_error.toJson(self.allocator);
        defer self.allocator.free(encoded);
        return ToolResultBody.initStructuredError(self.allocator, encoded);
    }

    /// 处理 server→client 请求并回复(Classic;Modern server 不发请求)。
    /// ping → 空结果(规范 MUST 及时应答);elicitation/create → 回调(或 decline);
    /// 其余(未声明的 roots/sampling 等)→ method_not_found。
    fn handleServerRequest(self: *McpClient, server_id: u64, method: []const u8, line: []const u8) void {
        if (std.mem.eql(u8, method, "ping")) {
            const reply = protocol.serializeResult(self.allocator, server_id, "{}") catch return;
            defer self.allocator.free(reply);
            self.transport.send(reply, .{}) catch {};
            return;
        }
        if (std.mem.eql(u8, method, "elicitation/create")) {
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch return;
            defer parsed.deinit();
            const params = if (parsed.value == .object) parsed.value.object.get("params") else null;
            // An undeclared mode (URL) is invalid params (client/elicitation.mdx).
            if (params) |value| if (value == .object) if (value.object.get("mode")) |mode| {
                if (mode == .string and !std.mem.eql(u8, mode.string, "form")) {
                    const err = protocol.serializeErrorResponse(self.allocator, server_id, @intFromEnum(protocol.ErrorCode.invalid_params), "elicitation mode not supported") catch return;
                    defer self.allocator.free(err);
                    self.transport.send(err, .{}) catch {};
                    return;
                }
            };
            const result = self.elicitationResult(params) catch return;
            defer self.allocator.free(result);
            const reply = protocol.serializeResult(self.allocator, server_id, result) catch return;
            defer self.allocator.free(reply);
            self.transport.send(reply, .{}) catch {};
            return;
        }
        // 其它 server→client 方法未声明 → method_not_found(回错误,不静默)。
        const err = protocol.serializeErrorResponse(self.allocator, server_id, @intFromEnum(protocol.ErrorCode.method_not_found), "not supported") catch return;
        defer self.allocator.free(err);
        self.transport.send(err, .{}) catch {};
    }

    /// 返回 tools 列表 `{"tools":[...]}`(owned JSON string,caller free),跨页聚合。
    pub fn listTools(self: *McpClient) ![]u8 {
        return self.listToolsAbortable(null);
    }

    /// `tools/list` (every page), interruptible as a whole by `abort`.
    pub fn listToolsAbortable(self: *McpClient, abort: ?*const AbortSignal) ![]u8 {
        self.request_mutex.lock();
        defer self.request_mutex.unlock();
        var tools: std.Io.Writer.Allocating = .init(self.allocator);
        defer tools.deinit();
        try tools.writer.writeAll("{\"tools\":[");
        var count: usize = 0;
        var cursor: ?[]u8 = null;
        defer if (cursor) |value| self.allocator.free(value);
        var pages: usize = 0;
        while (pages < MAX_LIST_PAGES) : (pages += 1) {
            const params = if (cursor) |value| blk: {
                var out: std.Io.Writer.Allocating = .init(self.allocator);
                errdefer out.deinit();
                try out.writer.writeAll("{\"cursor\":");
                try json_util.writeJsonString(&out.writer, value);
                try out.writer.writeByte('}');
                break :blk try out.toOwnedSlice();
            } else try self.allocator.dupe(u8, protocol.EMPTY_PARAMS);
            defer self.allocator.free(params);
            const result = try self.requestUnlocked("tools/list", params, abort);
            defer self.allocator.free(result);
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, result, .{ .parse_numbers = false }) catch
                return error.McpMalformedResponse;
            defer parsed.deinit();
            if (parsed.value != .object) return error.McpMalformedResponse;
            const page = parsed.value.object.get("tools") orelse return error.McpMalformedResponse;
            if (page != .array) return error.McpMalformedResponse;
            for (page.array.items) |tool| {
                if (count == MAX_LISTED_TOOLS) break;
                if (count != 0) try tools.writer.writeByte(',');
                try std.json.Stringify.value(tool, .{}, &tools.writer);
                count += 1;
            }
            // Cursors are opaque; "" is a valid cursor, only absence ends the list.
            const next = parsed.value.object.get("nextCursor") orelse break;
            if (next != .string or count == MAX_LISTED_TOOLS) break;
            if (cursor) |previous| {
                if (std.mem.eql(u8, previous, next.string)) return error.McpRepeatedCursor;
                self.allocator.free(previous);
                cursor = null;
            }
            cursor = try self.allocator.dupe(u8, next.string);
        }
        try tools.writer.writeAll("]}");
        return tools.toOwnedSlice();
    }

    /// 调用某个 tool。arguments_json 必须是合法 JSON object。
    pub fn callTool(self: *McpClient, name: []const u8, arguments_json: []const u8) ![]u8 {
        return self.callToolAbortable(name, arguments_json, null);
    }

    pub fn callToolAbortable(self: *McpClient, name: []const u8, arguments_json: []const u8, abort: ?*const AbortSignal) ![]u8 {
        const params = try protocol.callToolParams(self.allocator, name, arguments_json);
        defer self.allocator.free(params);
        return try self.request("tools/call", params, abort);
    }

    pub fn callToolBodyAbortable(
        self: *McpClient,
        name: []const u8,
        arguments_json: []const u8,
        artifact_root: []const u8,
        budget: result_budget.Budget,
        abort: ?*const AbortSignal,
    ) !ToolResultBody {
        return self.callToolBodyWithHeaders(name, arguments_json, artifact_root, budget, abort, &.{});
    }

    /// `callToolBodyAbortable` with the call's `Mcp-Param-*` headers
    /// (Streamable HTTP; stdio ignores them).
    pub fn callToolBodyWithHeaders(
        self: *McpClient,
        name: []const u8,
        arguments_json: []const u8,
        artifact_root: []const u8,
        budget: result_budget.Budget,
        abort: ?*const AbortSignal,
        headers: []const transport_mod.Header,
    ) !ToolResultBody {
        const params = try protocol.callToolParams(self.allocator, name, arguments_json);
        defer self.allocator.free(params);
        self.param_headers = headers;
        defer self.param_headers = &.{};
        return self.requestBody("tools/call", params, artifact_root, budget, abort, true);
    }

    /// 列出 server 暴露的 resources（resources/list）。返回原始 JSON-RPC result。
    pub fn listResources(self: *McpClient) ![]u8 {
        return self.listResourcesAbortable(null);
    }

    pub fn listResourcesAbortable(self: *McpClient, abort: ?*const AbortSignal) ![]u8 {
        return try self.request("resources/list", protocol.EMPTY_PARAMS, abort);
    }

    pub fn listResourcesBodyAbortable(
        self: *McpClient,
        artifact_root: []const u8,
        budget: result_budget.Budget,
        abort: ?*const AbortSignal,
    ) !ToolResultBody {
        return self.requestBody("resources/list", protocol.EMPTY_PARAMS, artifact_root, budget, abort, false);
    }

    /// 读取一个 resource（resources/read）。uri 为 resource 标识。
    pub fn readResource(self: *McpClient, uri: []const u8) ![]u8 {
        return self.readResourceAbortable(uri, null);
    }

    pub fn readResourceAbortable(self: *McpClient, uri: []const u8, abort: ?*const AbortSignal) ![]u8 {
        const params = try protocol.readResourceParams(self.allocator, uri);
        defer self.allocator.free(params);
        return try self.request("resources/read", params, abort);
    }

    pub fn readResourceBodyAbortable(
        self: *McpClient,
        uri: []const u8,
        artifact_root: []const u8,
        budget: result_budget.Budget,
        abort: ?*const AbortSignal,
    ) !ToolResultBody {
        const params = try protocol.readResourceParams(self.allocator, uri);
        defer self.allocator.free(params);
        return self.requestBody("resources/read", params, artifact_root, budget, abort, false);
    }
};

/// HTTP routing headers for a 2026-07-28 request: `Mcp-Method`, and
/// `Mcp-Name` from `params.name` (tools/call, prompts/get) or `params.uri`
/// (resources/read).
fn sendMeta(arena: std.mem.Allocator, method: []const u8, params_json: []const u8) !transport_mod.SendMeta {
    var meta = transport_mod.SendMeta{ .method = method };
    const key: ?[]const u8 = if (std.mem.eql(u8, method, "tools/call") or std.mem.eql(u8, method, "prompts/get"))
        "name"
    else if (std.mem.eql(u8, method, "resources/read"))
        "uri"
    else
        null;
    if (key) |field| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, params_json, .{}) catch return meta;
        if (parsed == .object) if (parsed.object.get(field)) |value| if (value == .string) {
            meta.name = value.string;
        };
    }
    return meta;
}

/// A request that never left: the deadline expired while the child stopped
/// draining stdin, or the child is gone.
fn sendFailure(err: anyerror) anyerror {
    return switch (err) {
        error.Timeout => error.McpRequestTimeout,
        error.Aborted, error.McpAuthRequired, error.McpSessionExpired, error.McpServerError, error.McpRedirected, error.McpConnectFailed, error.McpStreamClosed => err,
        else => error.McpServerCrashed,
    };
}

fn minDeadline(first: ?i64, second: i64) i64 {
    return if (first) |value| @min(value, second) else second;
}

fn responseId(object: std.json.ObjectMap) ?u64 {
    const value = object.get("id") orelse return null;
    return if (value == .integer and value.integer >= 0) @intCast(value.integer) else null;
}

fn listsVersion(value: ?std.json.Value, version: []const u8) bool {
    const list = value orelse return false;
    if (list != .array) return false;
    for (list.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, version)) return true;
    }
    return false;
}

fn parseCapabilities(value: ?std.json.Value) ServerCapabilities {
    const object = (value orelse return .{});
    if (object != .object) return .{};
    return .{
        .tools = object.object.get("tools") != null,
        .resources = object.object.get("resources") != null,
        .prompts = object.object.get("prompts") != null,
    };
}

/// Only `tools/call`, `resources/read` and `prompts/get` may return
/// `input_required` (2026-07-28 MRTR).
fn mrtrMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "tools/call") or std.mem.eql(u8, method, "resources/read") or
        std.mem.eql(u8, method, "prompts/get");
}

/// A 2026-07-28 result whose `resultType` is `input_required`. An absent
/// `resultType` means `complete`.
fn isInputRequired(allocator: std.mem.Allocator, result_json: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, result_json, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const result_type = parsed.value.object.get("resultType") orelse return false;
    return result_type == .string and std.mem.eql(u8, result_type.string, "input_required");
}

/// content 是否可解析为合法 JSON 值(elicitation accept 前校验,防裸拼破帧)。
fn isValidJson(alloc: std.mem.Allocator, s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return false;
    var p = std.json.parseFromSlice(std.json.Value, alloc, t, .{}) catch return false;
    p.deinit();
    return true;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "McpClient: connect to nonexistent command fails at spawn, before any handshake" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const argv = [_]?[*:0]const u8{ "/nonexistent/mcp-server", null };
    // 子进程报告通道让 exec 失败在 spawn 处就返回;过去是 spawn "成功"、server 立刻死、
    // 握手再撞 McpServerCrashed/McpMalformedResponse,失败原因全程无人知道。
    try testing.expectError(error.SpawnFailed, McpClient.connect(testing.allocator, argv[0..]));
}

/// An oversized JSON result, sealed but not published: the file is validated
/// and its receipt fixed, and the agent loop publishes it at the batch commit
/// boundary (#65). Before #65 this published during the call, so a fatal
/// sibling in the same batch left an unreferenced blob in the CAS.
fn sealJsonResult(
    allocator: std.mem.Allocator,
    artifact_root: []const u8,
    result: []const u8,
) !ToolResultBody {
    var spool = try artifact_store.Spool.begin(allocator, artifact_root);
    defer spool.deinit(); // a no-op once `seal` has taken the buffers
    try spool.write(result);
    const sealed = try spool.seal();
    return .{
        .sealed = .{
            .spool = sealed,
            .media_type = .json,
            .capture_complete = true,
            // The bytes were materialized in memory up to the frame limit, so a
            // failed publication at the commit boundary keeps them inline exactly
            // as the execution-time policy did.
            .retain_inline_ceiling = CONTROL_FRAME_MATERIALIZE_BYTES,
        },
    };
}

fn testCountDirectory(allocator: std.mem.Allocator, directory: []const u8) !usize {
    const pdir = @import("platform").dir;
    const directory_z = try allocator.dupeZ(u8, directory);
    defer allocator.free(directory_z);
    var iterator = pdir.open(directory_z.ptr) orelse return 0;
    defer pdir.close(&iterator);
    var count: usize = 0;
    while (pdir.next(&iterator)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        count += 1;
    }
    return count;
}

test "McpClient: an oversized result is sealed, not published, until the batch commits (#65)" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &b);
    const root = b[0..n];
    const cas = try std.fmt.allocPrint(a, "{s}/tool-results/sha256", .{root});
    defer a.free(cas);
    const result = "{\"rows\":[" ++ ("{\"k\":\"vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv\"}," ** 64) ++ "null]}";

    var body = try sealJsonResult(a, root, result);
    defer body.deinit(a);
    try testing.expect(body == .sealed);
    try testing.expect(body.sealed.media_type == .json);
    try testing.expectEqual(@as(usize, 0), try testCountDirectory(a, cas));
    var before = try body.render(a);
    defer before.deinit(a);
    var sealed = body.takeSealed().?;
    defer sealed.spool.deinit();
    const completed = try sealed.spool.publish();
    try testing.expectEqual(@as(usize, 1), try testCountDirectory(a, cas));
    try testing.expectEqual(@as(u64, result.len), completed.receipt.bytes);
    // The envelope the model saw before publication names the blob that exists after it.
    try testing.expect(std.mem.indexOf(u8, before.bytes, completed.receipt.id()) != null);
    var chunk = try artifact_store.readChunk(a, root, completed.receipt.id(), 0, 8);
    defer chunk.deinit();
    try testing.expectEqualSlices(u8, result[0..8], chunk.bytes);
}
