//! AgentCore-owned MCP transport lifecycle and exact-era client.
//!
//! Host code supplies an opaque connector (and therefore owns credentials).
//! AgentCore owns disposable negotiation probes, the real connection,
//! request ordering, protocol state and canonical catalog. `tools/call` is
//! issued exactly once: an indeterminate transport outcome is never replayed.

const std = @import("std");
const core = @import("metacodes-core");
const sync = @import("platform").sync;
const canonical = @import("mcp_canonical.zig");
const modern = @import("mcp_modern.zig");
const classic = @import("mcp_classic.zig");
const negotiation = @import("mcp_negotiation.zig");
const wire = @import("mcp_wire.zig");
const schema = @import("mcp_schema.zig");
const result_stream = core.mcp_result_stream;

pub const ConnectionPurpose = enum(u8) { disposable_probe, actual };

pub const Cancellation = struct {
    ctx: ?*const anyopaque = null,
    is_cancelled_fn: *const fn (?*const anyopaque) bool = neverCancelled,

    pub fn isCancelled(self: Cancellation) bool {
        return self.is_cancelled_fn(self.ctx);
    }

    fn neverCancelled(_: ?*const anyopaque) bool {
        return false;
    }
};

pub const ExchangeOutcome = union(enum) {
    /// Allocated by the allocator passed to `Connection.request`.
    response: []u8,
    timeout,
    network_error,
    auth_error,
    server_error,
    child_exit,
    cancelled,
    /// The request may have reached the server. Callers must not replay it.
    indeterminate,
};

pub const ToolResponseSinkError = error{
    Cancelled,
    ResourceLimit,
    IoFailure,
    Closed,
};

/// Borrowed response-frame sink. The kernel creates the private capture before
/// invoking a streaming connector, so the first Host-produced byte is already
/// subject to Session quota, cancellation and rollback.
pub const ToolResponseSink = struct {
    ctx: *anyopaque,
    write_fn: *const fn (*anyopaque, []const u8) ToolResponseSinkError!void,

    pub fn write(self: ToolResponseSink, chunk: []const u8) ToolResponseSinkError!void {
        return self.write_fn(self.ctx, chunk);
    }
};

pub const ToolStreamExchangeOutcome = enum {
    response,
    timeout,
    network_error,
    auth_error,
    server_error,
    child_exit,
    cancelled,
    indeterminate,
};

pub const ToolRequestExecutor = union(enum) {
    /// Source-only compatibility/testing adapter. Production public AgentCore
    /// connectors are admitted only through the streaming branch.
    completed: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        request: []const u8,
        timeout_ms: u32,
        cancellation: Cancellation,
    ) anyerror!ExchangeOutcome,
    streaming: *const fn (
        ctx: *anyopaque,
        request: []const u8,
        timeout_ms: u32,
        cancellation: Cancellation,
        sink: ToolResponseSink,
    ) anyerror!ToolStreamExchangeOutcome,
};

pub const Connection = struct {
    ctx: *anyopaque,
    request_fn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        request: []const u8,
        timeout_ms: u32,
        cancellation: Cancellation,
    ) anyerror!ExchangeOutcome,
    tool_request: ToolRequestExecutor,
    notify_fn: *const fn (
        ctx: *anyopaque,
        notification: []const u8,
        timeout_ms: u32,
        cancellation: Cancellation,
    ) anyerror!void,
    close_fn: *const fn (ctx: *anyopaque) void,

    pub fn request(
        self: Connection,
        allocator: std.mem.Allocator,
        encoded: []const u8,
        timeout_ms: u32,
        cancellation: Cancellation,
    ) anyerror!ExchangeOutcome {
        return self.request_fn(self.ctx, allocator, encoded, timeout_ms, cancellation);
    }

    pub fn notify(
        self: Connection,
        encoded: []const u8,
        timeout_ms: u32,
        cancellation: Cancellation,
    ) anyerror!void {
        return self.notify_fn(self.ctx, encoded, timeout_ms, cancellation);
    }

    pub fn requestTool(
        self: Connection,
        allocator: std.mem.Allocator,
        encoded: []const u8,
        timeout_ms: u32,
        cancellation: Cancellation,
        sink: ToolResponseSink,
    ) anyerror!ToolRequestOutcome {
        return switch (self.tool_request) {
            .completed => |callback| switch (try callback(
                self.ctx,
                allocator,
                encoded,
                timeout_ms,
                cancellation,
            )) {
                .response => |bytes| .{ .completed_response = bytes },
                .timeout => .timeout,
                .network_error => .network_error,
                .auth_error => .auth_error,
                .server_error => .server_error,
                .child_exit => .child_exit,
                .cancelled => .cancelled,
                .indeterminate => .indeterminate,
            },
            .streaming => |callback| switch (try callback(
                self.ctx,
                encoded,
                timeout_ms,
                cancellation,
                sink,
            )) {
                .response => .streamed_response,
                .timeout => .timeout,
                .network_error => .network_error,
                .auth_error => .auth_error,
                .server_error => .server_error,
                .child_exit => .child_exit,
                .cancelled => .cancelled,
                .indeterminate => .indeterminate,
            },
        };
    }

    pub fn close(self: Connection) void {
        self.close_fn(self.ctx);
    }
};

pub const ToolRequestOutcome = union(enum) {
    completed_response: []u8,
    streamed_response,
    timeout,
    network_error,
    auth_error,
    server_error,
    child_exit,
    cancelled,
    indeterminate,
};

pub const OpenOutcome = union(enum) {
    connection: Connection,
    timeout,
    network_error,
    auth_error,
    server_error,
    child_exit,
};

pub const Connector = struct {
    ctx: *anyopaque,
    open_fn: *const fn (
        ctx: *anyopaque,
        purpose: ConnectionPurpose,
        requested_era: canonical.Era,
    ) anyerror!OpenOutcome,
    retain_fn: *const fn (ctx: *anyopaque) anyerror!void = retainNoop,
    release_fn: *const fn (ctx: *anyopaque) void = releaseNoop,

    pub fn open(
        self: Connector,
        purpose: ConnectionPurpose,
        era: canonical.Era,
    ) anyerror!OpenOutcome {
        return self.open_fn(self.ctx, purpose, era);
    }

    pub fn retain(self: Connector) anyerror!void {
        return self.retain_fn(self.ctx);
    }

    pub fn release(self: Connector) void {
        self.release_fn(self.ctx);
    }

    fn retainNoop(_: *anyopaque) anyerror!void {}
    fn releaseNoop(_: *anyopaque) void {}
};

pub const Config = struct {
    connector: Connector,
    transport: negotiation.Transport,
    policy: negotiation.Policy = .auto,
    server_binding_identity: [32]u8,
    client: wire.ClientInfo,
    timeout_ms: u32 = 30_000,
    limits: canonical.Limits = .{},
};

pub const ConnectFailure = union(enum) {
    diagnostic: canonical.Diagnostic,
    resource_limit,
    out_of_memory,
};

pub const ConnectOutcome = union(enum) {
    client: *Client,
    failed: ConnectFailure,
};

pub const CallFailure = union(enum) {
    diagnostic: canonical.Diagnostic,
    timeout,
    network_error,
    auth_error,
    server_error,
    child_exit,
    cancelled,
    indeterminate,
    instance_unavailable,
    resource_limit,
    out_of_memory,
};

pub const CallOutcome = union(enum) {
    result: canonical.OwnedCallResult,
    failed: CallFailure,
};

pub const BodyCallOutcome = union(enum) {
    result: core.tool_result.ToolResultBody,
    failed: CallFailure,
};

pub const Client = struct {
    backing: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    connection: Connection,
    mutex: sync.Mutex = .{},
    era: canonical.Era,
    capabilities: canonical.CanonicalCapabilities,
    binding: [32]u8,
    client_info: wire.ClientInfo,
    timeout_ms: u32,
    limits: canonical.Limits,
    next_request_id: u64,
    catalog: canonical.OwnedCatalog,

    pub fn deinit(self: *Client) void {
        const backing = self.backing;
        self.connection.close();
        self.catalog.deinit();
        self.arena.deinit();
        backing.destroy(self);
    }

    pub fn callTool(
        self: *Client,
        result_allocator: std.mem.Allocator,
        tool: *const canonical.Tool,
        arguments_json: []const u8,
        cancellation: Cancellation,
    ) CallOutcome {
        if (!std.mem.eql(u8, &tool.identity.server_binding_identity, &self.binding))
            return .{ .failed = .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_call) } };
        if (schema.validateArguments(result_allocator, arguments_json, .{}) != .valid)
            return .{ .failed = .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_call) } };

        self.mutex.lock();
        defer self.mutex.unlock();
        if (cancellation.isCancelled()) return .{ .failed = .cancelled };
        const request_id = self.takeRequestId() orelse return .{ .failed = .resource_limit };
        var exchange_arena = std.heap.ArenaAllocator.init(self.backing);
        defer exchange_arena.deinit();
        const request = switch (self.era) {
            .modern_2026_07_28 => modern.encodeCallToolRequest(
                exchange_arena.allocator(),
                request_id,
                self.client_info,
                tool.identity.name,
                arguments_json,
                self.limits,
            ),
            .classic_2025_11_25, .classic_2025_06_18 => classic.encodeCallToolRequest(
                exchange_arena.allocator(),
                request_id,
                tool.identity.name,
                arguments_json,
                self.limits,
            ),
        } catch |err| return .{ .failed = if (err == error.OutOfMemory)
            .out_of_memory
        else
            .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_call) } };
        const exchange = self.connection.request(
            exchange_arena.allocator(),
            request,
            self.timeout_ms,
            cancellation,
        ) catch return .{ .failed = .indeterminate };
        const response = switch (exchange) {
            .response => |bytes| bytes,
            .timeout => return .{ .failed = .timeout },
            .network_error => return .{ .failed = .network_error },
            .auth_error => return .{ .failed = .auth_error },
            .server_error => return .{ .failed = .server_error },
            .child_exit => return .{ .failed = .child_exit },
            .cancelled => return .{ .failed = .cancelled },
            .indeterminate => return .{ .failed = .indeterminate },
        };
        const parsed = switch (self.era) {
            .modern_2026_07_28 => modern.parseCallToolResponse(
                result_allocator,
                response,
                request_id,
                self.limits,
            ),
            .classic_2025_11_25, .classic_2025_06_18 => classic.parseCallToolResponse(
                result_allocator,
                response,
                request_id,
                classic.ClassicProfile.forEra(self.era).?,
                self.limits,
            ),
        } catch return .{ .failed = .out_of_memory };
        var result = switch (parsed) {
            .diagnostic => |diagnostic| return .{ .failed = .{ .diagnostic = diagnostic } },
            .value => |value| value,
        };
        if (!result.is_error and tool.output_schema_json != null) {
            if (result.structured_content_json == null) {
                result.deinit();
                return .{ .failed = .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_call) } };
            }
        }
        return .{ .result = result };
    }

    /// Byte-zero MCP tool call. Control-plane requests keep the bounded
    /// completed-response API; only `tools/call` is allowed to use the much
    /// larger artifact data plane.
    pub fn callToolBody(
        self: *Client,
        result_allocator: std.mem.Allocator,
        artifact_root: []const u8,
        tool: *const canonical.Tool,
        arguments_json: []const u8,
        cancellation: Cancellation,
    ) BodyCallOutcome {
        if (artifact_root.len == 0) return .{ .failed = .resource_limit };
        if (!std.mem.eql(u8, &tool.identity.server_binding_identity, &self.binding))
            return .{ .failed = .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_call) } };
        if (schema.validateArguments(result_allocator, arguments_json, .{}) != .valid)
            return .{ .failed = .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_call) } };

        self.mutex.lock();
        defer self.mutex.unlock();
        if (cancellation.isCancelled()) return .{ .failed = .cancelled };
        const request_id = self.takeRequestId() orelse return .{ .failed = .resource_limit };
        var exchange_arena = std.heap.ArenaAllocator.init(self.backing);
        defer exchange_arena.deinit();
        const request = switch (self.era) {
            .modern_2026_07_28 => modern.encodeCallToolRequest(
                exchange_arena.allocator(),
                request_id,
                self.client_info,
                tool.identity.name,
                arguments_json,
                self.limits,
            ),
            .classic_2025_11_25, .classic_2025_06_18 => classic.encodeCallToolRequest(
                exchange_arena.allocator(),
                request_id,
                tool.identity.name,
                arguments_json,
                self.limits,
            ),
        } catch |err| return .{ .failed = if (err == error.OutOfMemory)
            .out_of_memory
        else
            .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_call) } };

        var capture = core.tool_result_artifact.Capture.begin(
            result_allocator,
            artifact_root,
            result_stream.MAX_RESPONSE_BYTES,
        ) catch |err| return .{ .failed = if (err == error.OutOfMemory)
            .out_of_memory
        else
            .resource_limit };
        defer capture.deinit();
        var capture_sink = CaptureSink{
            .capture = &capture,
            .cancellation = cancellation,
        };
        const exchange = self.connection.requestTool(
            exchange_arena.allocator(),
            request,
            self.timeout_ms,
            cancellation,
            capture_sink.interface(),
        ) catch return .{ .failed = .indeterminate };
        switch (exchange) {
            .completed_response => |bytes| capture_sink.write(bytes) catch
                return .{ .failed = capture_sink.failureOutcome() },
            .streamed_response => {},
            .timeout => return .{ .failed = .timeout },
            .network_error => return .{ .failed = .network_error },
            .auth_error => return .{ .failed = .auth_error },
            .server_error => return .{ .failed = .server_error },
            .child_exit => return .{ .failed = .child_exit },
            .cancelled => return .{ .failed = .cancelled },
            .indeterminate => return .{ .failed = .indeterminate },
        }
        capture_sink.closed = true;
        if (capture_sink.failure != null)
            return .{ .failed = capture_sink.failureOutcome() };
        capture.seal() catch |err| return .{ .failed = if (err == error.OutOfMemory)
            .out_of_memory
        else
            .resource_limit };
        const projected = result_stream.project(
            result_allocator,
            &capture,
            artifact_root,
            request_id,
            switch (self.era) {
                .modern_2026_07_28 => .modern_2026_07_28,
                .classic_2025_11_25 => .classic_2025_11_25,
                .classic_2025_06_18 => .classic_2025_06_18,
            },
            .{
                .max_text_bytes = self.limits.max_text_bytes,
                .max_json_depth = self.limits.max_json_depth,
                .max_json_nodes = self.limits.max_json_nodes,
            },
            tool.output_schema_json != null,
            true,
        ) catch return .{ .failed = .out_of_memory };
        return switch (projected) {
            .result => |body| .{ .result = body },
            .diagnostic => |diagnostic| .{ .failed = .{ .diagnostic = .{
                .code = switch (diagnostic.code) {
                    .invalid_json => .invalid_json,
                    .invalid_envelope => .invalid_envelope,
                    .response_id_mismatch => .response_id_mismatch,
                    .remote_error => .remote_error,
                    .method_not_found => .method_not_found,
                    .missing_required_field => .missing_required_field,
                    .invalid_field => .invalid_field,
                    .resource_limit => .resource_limit,
                    .missing_result_type => .missing_result_type,
                    .unsupported_result_type => .unsupported_result_type,
                    .input_required_unsupported => .input_required_unsupported,
                },
                .phase = .tools_call,
                .rpc_code = diagnostic.rpc_code,
            } } },
        };
    }

    fn takeRequestId(self: *Client) ?u64 {
        if (self.next_request_id == std.math.maxInt(u64)) return null;
        const value = self.next_request_id;
        self.next_request_id += 1;
        return value;
    }
};

const CaptureSink = struct {
    capture: *core.tool_result_artifact.Capture,
    cancellation: Cancellation,
    failure: ?ToolResponseSinkError = null,
    closed: bool = false,

    fn interface(self: *CaptureSink) ToolResponseSink {
        return .{ .ctx = self, .write_fn = writeAdapter };
    }

    fn writeAdapter(raw: *anyopaque, chunk: []const u8) ToolResponseSinkError!void {
        const self: *CaptureSink = @ptrCast(@alignCast(raw));
        return self.write(chunk);
    }

    fn write(self: *CaptureSink, chunk: []const u8) ToolResponseSinkError!void {
        if (self.failure) |failure| return failure;
        if (self.closed) return self.latch(error.Closed);
        if (self.cancellation.isCancelled()) return self.latch(error.Cancelled);
        self.capture.write(chunk) catch |err| return self.latch(switch (err) {
            error.ArtifactTooLarge => error.ResourceLimit,
            else => error.IoFailure,
        });
    }

    fn latch(self: *CaptureSink, failure: ToolResponseSinkError) ToolResponseSinkError {
        if (self.failure == null) self.failure = failure;
        return self.failure.?;
    }

    fn failureOutcome(self: *const CaptureSink) CallFailure {
        return switch (self.failure orelse error.IoFailure) {
            error.Cancelled => .cancelled,
            error.ResourceLimit, error.IoFailure, error.Closed => .resource_limit,
        };
    }
};

const DriverState = struct {
    backing: std.mem.Allocator,
    config: Config,
    probe_connection: ?Connection = null,
    actual_connection: ?Connection = null,
    probe_observation: ?negotiation.ProbeObservation = null,
    probe_handshake: ?canonical.OwnedHandshake = null,
    final_capabilities: ?canonical.CanonicalCapabilities = null,
    next_request_id: u64 = 1,

    fn driver(self: *DriverState) negotiation.Driver {
        return .{
            .ctx = self,
            .start_probe_fn = startProbe,
            .observe_probe_fn = observeProbe,
            .finish_probe_fn = finishProbe,
            .connect_fn = connectActual,
            .revalidate_fn = revalidateActual,
            .disconnect_fn = disconnectActual,
        };
    }

    fn cast(raw: ?*anyopaque) *DriverState {
        return @ptrCast(@alignCast(raw.?));
    }

    fn startProbe(raw: ?*anyopaque, _: negotiation.Transport) negotiation.DriverError!void {
        const self = cast(raw);
        if (self.probe_connection != null or self.probe_observation != null)
            return error.TransportFailure;
        const opened = self.config.connector.open(.disposable_probe, .modern_2026_07_28) catch |err|
            return if (err == error.OutOfMemory) error.OutOfMemory else error.TransportFailure;
        switch (opened) {
            .connection => |connection| self.probe_connection = connection,
            .timeout => self.probe_observation = .timeout,
            .network_error => self.probe_observation = .network_error,
            .auth_error => self.probe_observation = .auth_error,
            .server_error => self.probe_observation = .server_error,
            .child_exit => self.probe_observation = .child_exit,
        }
    }

    fn observeProbe(raw: ?*anyopaque) negotiation.DriverError!negotiation.ProbeObservation {
        const self = cast(raw);
        if (self.probe_observation) |observation| return observation;
        const connection = self.probe_connection orelse return error.TransportFailure;
        var arena = std.heap.ArenaAllocator.init(self.backing);
        defer arena.deinit();
        const request = modern.encodeDiscoverRequest(
            arena.allocator(),
            1,
            self.config.client,
            self.config.limits,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidValue, error.ResourceLimit => error.ResourceLimit,
        };
        const exchange = connection.request(
            arena.allocator(),
            request,
            self.config.timeout_ms,
            .{},
        ) catch |err| return if (err == error.OutOfMemory)
            error.OutOfMemory
        else
            error.TransportFailure;
        const response = switch (exchange) {
            .response => |bytes| bytes,
            .timeout => return .timeout,
            .network_error => return .network_error,
            .auth_error => return .auth_error,
            .server_error => return .server_error,
            .child_exit => return .child_exit,
            .cancelled => return .cancelled,
            .indeterminate => return .malformed_response,
        };
        const parsed = modern.parseDiscoverResponse(
            self.backing,
            response,
            1,
            self.config.limits,
        ) catch return error.OutOfMemory;
        return switch (parsed) {
            .value => |handshake| blk: {
                self.probe_handshake = handshake;
                break :blk .{ .discovered_versions = self.probe_handshake.?.supported_versions };
            },
            .diagnostic => |diagnostic| if (diagnostic.code == .method_not_found)
                .method_not_found
            else
                .malformed_response,
        };
    }

    fn finishProbe(raw: ?*anyopaque) void {
        const self = cast(raw);
        if (self.probe_handshake) |*handshake| handshake.deinit();
        self.probe_handshake = null;
        if (self.probe_connection) |connection| connection.close();
        self.probe_connection = null;
        self.probe_observation = null;
    }

    fn connectActual(raw: ?*anyopaque, era: canonical.Era) negotiation.DriverError!void {
        const self = cast(raw);
        if (self.actual_connection != null) return error.TransportFailure;
        const opened = self.config.connector.open(.actual, era) catch |err|
            return if (err == error.OutOfMemory) error.OutOfMemory else error.TransportFailure;
        self.actual_connection = switch (opened) {
            .connection => |connection| connection,
            else => return error.TransportFailure,
        };
    }

    fn revalidateActual(
        raw: ?*anyopaque,
        era: canonical.Era,
    ) negotiation.DriverError!negotiation.RevalidatedProtocol {
        const self = cast(raw);
        const connection = self.actual_connection orelse return error.TransportFailure;
        var arena = std.heap.ArenaAllocator.init(self.backing);
        defer arena.deinit();
        const id = self.next_request_id;
        if (id == std.math.maxInt(u64)) return error.ResourceLimit;
        self.next_request_id += 1;
        const request = switch (era) {
            .modern_2026_07_28 => modern.encodeDiscoverRequest(
                arena.allocator(),
                id,
                self.config.client,
                self.config.limits,
            ),
            .classic_2025_11_25, .classic_2025_06_18 => classic.encodeInitializeRequest(
                arena.allocator(),
                id,
                classic.ClassicProfile.forEra(era).?,
                self.config.client,
                self.config.limits,
            ),
        } catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidValue, error.ResourceLimit => error.ResourceLimit,
        };
        const exchange = connection.request(
            arena.allocator(),
            request,
            self.config.timeout_ms,
            .{},
        ) catch |err| return if (err == error.OutOfMemory)
            error.OutOfMemory
        else
            error.TransportFailure;
        const response = switch (exchange) {
            .response => |bytes| bytes,
            else => return error.TransportFailure,
        };
        var handshake = switch (era) {
            .modern_2026_07_28 => switch (modern.parseDiscoverResponse(
                self.backing,
                response,
                id,
                self.config.limits,
            ) catch return error.OutOfMemory) {
                .value => |value| value,
                .diagnostic => |diagnostic| return if (isUnsupportedRevision(diagnostic))
                    .unsupported_revision
                else
                    error.TransportFailure,
            },
            .classic_2025_11_25, .classic_2025_06_18 => switch (classic.parseInitializeResponse(
                self.backing,
                response,
                id,
                classic.ClassicProfile.forEra(era).?,
                self.config.limits,
            ) catch return error.OutOfMemory) {
                .value => |value| value,
                .diagnostic => |diagnostic| return if (isUnsupportedRevision(diagnostic))
                    .unsupported_revision
                else
                    error.TransportFailure,
            },
        };
        defer handshake.deinit();
        const selected: canonical.Era = if (era == .modern_2026_07_28) blk: {
            var matched = false;
            for (handshake.supported_versions) |version| {
                if (canonical.Era.parseExact(version)) |candidate| {
                    if (candidate == era) matched = true;
                }
            }
            if (!matched) return .unsupported_revision;
            break :blk era;
        } else handshake.era;
        if (selected != era) return .{ .known = selected };
        if (era != .modern_2026_07_28) {
            const notification = try classic.encodeInitializedNotification(arena.allocator());
            connection.notify(notification, self.config.timeout_ms, .{}) catch
                return error.TransportFailure;
        }
        self.final_capabilities = handshake.capabilities;
        return .{ .known = selected };
    }

    fn disconnectActual(raw: ?*anyopaque) void {
        const self = cast(raw);
        if (self.actual_connection) |connection| connection.close();
        self.actual_connection = null;
        self.final_capabilities = null;
    }
};

fn isUnsupportedRevision(diagnostic: canonical.Diagnostic) bool {
    return diagnostic.code == .unsupported_protocol_version or
        diagnostic.code == .method_not_found;
}

pub fn connectServer(backing: std.mem.Allocator, config: Config) ConnectOutcome {
    config.limits.validate() catch return .{ .failed = .resource_limit };
    if (allZero(&config.server_binding_identity) or config.timeout_ms == 0)
        return .{ .failed = .resource_limit };
    var state = DriverState{ .backing = backing, .config = config };
    const selected = negotiation.negotiate(
        state.driver(),
        config.policy,
        config.transport,
    ) catch return .{ .failed = .out_of_memory };
    const era = switch (selected) {
        .diagnostic => |diagnostic| return .{ .failed = .{ .diagnostic = diagnostic } },
        .value => |value| value,
    };
    const connection = state.actual_connection orelse
        return .{ .failed = .{ .diagnostic = canonical.Diagnostic.init(.connection_failed, .negotiation) } };
    state.actual_connection = null;
    const capabilities = state.final_capabilities orelse {
        connection.close();
        return .{ .failed = .{ .diagnostic = canonical.Diagnostic.init(.era_revalidation_mismatch, .revalidation) } };
    };
    var catalog = if (capabilities.tool_catalog_available)
        listAllTools(backing, connection, &state, era) catch |err| {
            connection.close();
            return .{ .failed = switch (err) {
                error.OutOfMemory => .out_of_memory,
                error.ResourceLimit => .resource_limit,
                error.ProtocolFailure => .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_list) },
                error.TransportFailure => .{ .diagnostic = canonical.Diagnostic.init(.connection_failed, .tools_list) },
            } };
        }
    else
        canonical.OwnedCatalog.init(backing, era);
    const client = backing.create(Client) catch {
        catalog.deinit();
        connection.close();
        return .{ .failed = .out_of_memory };
    };
    var arena = std.heap.ArenaAllocator.init(backing);
    const name = arena.allocator().dupe(u8, config.client.name) catch {
        arena.deinit();
        catalog.deinit();
        connection.close();
        backing.destroy(client);
        return .{ .failed = .out_of_memory };
    };
    const version = arena.allocator().dupe(u8, config.client.version) catch {
        arena.deinit();
        catalog.deinit();
        connection.close();
        backing.destroy(client);
        return .{ .failed = .out_of_memory };
    };
    client.* = .{
        .backing = backing,
        .arena = arena,
        .connection = connection,
        .era = era,
        .capabilities = capabilities,
        .binding = config.server_binding_identity,
        .client_info = .{ .name = name, .version = version },
        .timeout_ms = config.timeout_ms,
        .limits = config.limits,
        .next_request_id = state.next_request_id,
        .catalog = catalog,
    };
    return .{ .client = client };
}

fn listAllTools(
    backing: std.mem.Allocator,
    connection: Connection,
    state: *DriverState,
    era: canonical.Era,
) error{ OutOfMemory, ResourceLimit, ProtocolFailure, TransportFailure }!canonical.OwnedCatalog {
    var combined = canonical.OwnedCatalog.init(backing, era);
    errdefer combined.deinit();
    const a = combined.allocator();
    var tools: std.ArrayList(canonical.Tool) = .empty;
    defer tools.deinit(a);
    var cursor: ?[]const u8 = null;
    var pages: usize = 0;
    while (true) {
        if (pages == state.config.limits.max_tools + 1) return error.ResourceLimit;
        pages += 1;
        const id = state.next_request_id;
        if (id == std.math.maxInt(u64)) return error.ResourceLimit;
        state.next_request_id += 1;
        var exchange_arena = std.heap.ArenaAllocator.init(backing);
        defer exchange_arena.deinit();
        const request = switch (era) {
            .modern_2026_07_28 => modern.encodeListToolsRequest(
                exchange_arena.allocator(),
                id,
                state.config.client,
                cursor,
                state.config.limits,
            ),
            .classic_2025_11_25, .classic_2025_06_18 => classic.encodeListToolsRequest(
                exchange_arena.allocator(),
                id,
                cursor,
                state.config.limits,
            ),
        } catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.ResourceLimit;
        const exchange = connection.request(
            exchange_arena.allocator(),
            request,
            state.config.timeout_ms,
            .{},
        ) catch return error.TransportFailure;
        const response = switch (exchange) {
            .response => |bytes| bytes,
            else => return error.TransportFailure,
        };
        var page = switch (era) {
            .modern_2026_07_28 => switch (modern.parseListToolsResponse(
                backing,
                response,
                id,
                state.config.server_binding_identity,
                state.config.limits,
            ) catch return error.OutOfMemory) {
                .value => |value| value,
                .diagnostic => return error.ProtocolFailure,
            },
            .classic_2025_11_25, .classic_2025_06_18 => switch (classic.parseListToolsResponse(
                backing,
                response,
                id,
                classic.ClassicProfile.forEra(era).?,
                state.config.server_binding_identity,
                state.config.limits,
            ) catch return error.OutOfMemory) {
                .value => |value| value,
                .diagnostic => return error.ProtocolFailure,
            },
        };
        defer page.deinit();
        if (tools.items.len + page.tools.len > state.config.limits.max_tools)
            return error.ResourceLimit;
        for (page.tools) |tool| {
            for (tools.items) |existing| if (std.mem.eql(u8, existing.identity.name, tool.identity.name))
                return error.ProtocolFailure;
            const value = std.json.parseFromSliceLeaky(std.json.Value, a, tool.raw_json, .{
                .allocate = .alloc_always,
                .duplicate_field_behavior = .@"error",
            }) catch return error.ProtocolFailure;
            var copied = canonical.projectTool(
                a,
                value,
                era,
                state.config.server_binding_identity,
                state.config.limits,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ResourceLimit => error.ResourceLimit,
                error.InvalidValue => error.ProtocolFailure,
            };
            copied.execution_mode = tool.execution_mode;
            tools.append(a, copied) catch return error.OutOfMemory;
        }
        combined.cache = conservativeCache(combined.cache, page.cache, pages == 1);
        if (page.meta_json) |meta| combined.meta_json = a.dupe(u8, meta) catch return error.OutOfMemory;
        cursor = if (page.next_cursor) |next|
            a.dupe(u8, next) catch return error.OutOfMemory
        else
            null;
        if (cursor == null) break;
    }
    combined.tools = tools.toOwnedSlice(a) catch return error.OutOfMemory;
    return combined;
}

fn conservativeCache(
    current: canonical.CachePolicy,
    next: canonical.CachePolicy,
    first: bool,
) canonical.CachePolicy {
    if (first) return next;
    return .{
        .ttl_ms = if (current.ttl_ms) |left|
            if (next.ttl_ms) |right| @min(left, right) else null
        else
            null,
        .scope = if (current.scope == .private or next.scope == .private) .private else .public,
    };
}

fn allZero(value: []const u8) bool {
    for (value) |byte| if (byte != 0) return false;
    return true;
}

const FakeConnector = struct {
    era: canonical.Era,
    advertise_tools: bool = true,
    advertise_tools_2025_11: ?bool = null,
    advertise_tools_2025_06: ?bool = null,
    indeterminate_call: bool = false,
    business_error: bool = false,
    input_required_once: bool = false,
    typed_content: bool = false,
    optional_task: bool = false,
    paginate_tools: bool = false,
    list_requests: u8 = 0,
    saw_second_page_cursor: bool = false,
    opens: u8 = 0,
    closes: u8 = 0,
    requests: u8 = 0,
    notifications: u8 = 0,

    const FakeConnection = struct {
        owner: *FakeConnector,
        purpose: ConnectionPurpose,
        requested_era: canonical.Era,
        closed: bool = false,
    };

    fn connector(self: *FakeConnector) Connector {
        return .{ .ctx = self, .open_fn = open };
    }

    fn open(raw: *anyopaque, purpose: ConnectionPurpose, requested_era: canonical.Era) anyerror!OpenOutcome {
        const self: *FakeConnector = @ptrCast(@alignCast(raw));
        const connection = try std.heap.c_allocator.create(FakeConnection);
        connection.* = .{
            .owner = self,
            .purpose = purpose,
            .requested_era = requested_era,
        };
        self.opens += 1;
        return .{ .connection = .{
            .ctx = connection,
            .request_fn = request,
            .tool_request = .{ .completed = request },
            .notify_fn = notify,
            .close_fn = close,
        } };
    }

    fn request(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        encoded: []const u8,
        _: u32,
        _: Cancellation,
    ) anyerror!ExchangeOutcome {
        const connection: *FakeConnection = @ptrCast(@alignCast(raw));
        const self = connection.owner;
        self.requests += 1;
        if (std.mem.indexOf(u8, encoded, "tools/call") != null and self.indeterminate_call)
            return .indeterminate;
        const id = requestId(encoded) orelse return .server_error;
        const response = if (std.mem.indexOf(u8, encoded, "server/discover") != null)
            if (self.era == .modern_2026_07_28) try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{{}},\"ttlMs\":1000,\"cacheScope\":\"private\"}}}}",
                .{id},
            ) else try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}",
                .{id},
            )
        else if (std.mem.indexOf(u8, encoded, "initialize") != null)
            try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{s},\"serverInfo\":{{\"name\":\"fake\",\"version\":\"1\"}}}}}}",
                .{
                    id,
                    self.era.version(),
                    if (self.advertisesTools(connection.requested_era)) "{\"tools\":{}}" else "{}",
                },
            )
        else if (std.mem.indexOf(u8, encoded, "tools/list") != null)
            if (self.era == .modern_2026_07_28 and self.paginate_tools) blk: {
                self.list_requests += 1;
                if (self.list_requests == 1) break :blk try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\"}}}}],\"nextCursor\":\"page-2\",\"ttlMs\":5000,\"cacheScope\":\"public\"}}}}",
                    .{id},
                );
                self.saw_second_page_cursor = std.mem.indexOf(
                    u8,
                    encoded,
                    "\"cursor\":\"page-2\"",
                ) != null;
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"alerts\",\"inputSchema\":{{\"type\":\"object\"}}}}],\"ttlMs\":1000,\"cacheScope\":\"private\"}}}}",
                    .{id},
                );
            } else if (self.era == .modern_2026_07_28) blk: {
                self.list_requests += 1;
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"city\":{{\"type\":\"string\"}}}},\"required\":[\"city\"]}},\"outputSchema\":{{\"type\":\"object\"}}}}],\"ttlMs\":1000,\"cacheScope\":\"private\"}}}}",
                    .{id},
                );
            } else blk: {
                self.list_requests += 1;
                const execution = if (self.optional_task and self.era == .classic_2025_11_25)
                    ",\"execution\":{\"taskSupport\":\"optional\"}"
                else
                    "";
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"city\":{{\"type\":\"string\"}}}},\"required\":[\"city\"]}},\"outputSchema\":{{\"type\":\"object\"}}{s}}}]}}}}",
                    .{ id, execution },
                );
            }
        else if (std.mem.indexOf(u8, encoded, "tools/call") != null)
            if (self.input_required_once and self.era == .modern_2026_07_28) blk: {
                self.input_required_once = false;
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"input_required\",\"requestState\":\"opaque\"}}}}",
                    .{id},
                );
            } else if (self.typed_content and self.era == .modern_2026_07_28)
                try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"content\":[{{\"type\":\"text\",\"text\":\"ok\"}},{{\"type\":\"image\",\"data\":\"AA==\",\"mimeType\":\"image/png\"}},{{\"type\":\"audio\",\"data\":\"AA==\",\"mimeType\":\"audio/wav\"}},{{\"type\":\"resource_link\",\"uri\":\"file:///tmp/a\",\"name\":\"a\"}},{{\"type\":\"resource\",\"resource\":{{\"uri\":\"file:///tmp/b\",\"mimeType\":\"text/plain\",\"text\":\"body\"}}}}],\"structuredContent\":{{\"ok\":true}}}}}}",
                    .{id},
                )
            else if (self.business_error and self.era == .modern_2026_07_28)
                try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"content\":[{{\"type\":\"text\",\"text\":\"city unavailable\"}}],\"isError\":true}}}}",
                    .{id},
                )
            else if (self.era == .modern_2026_07_28)
                try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"content\":[],\"structuredContent\":{{\"ok\":true}}}}}}",
                    .{id},
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[],\"structuredContent\":{{\"ok\":true}}}}}}",
                    .{id},
                )
        else
            return .server_error;
        return .{ .response = response };
    }

    fn notify(raw: *anyopaque, _: []const u8, _: u32, _: Cancellation) anyerror!void {
        const connection: *FakeConnection = @ptrCast(@alignCast(raw));
        connection.owner.notifications += 1;
    }

    fn close(raw: *anyopaque) void {
        const connection: *FakeConnection = @ptrCast(@alignCast(raw));
        std.debug.assert(!connection.closed);
        connection.closed = true;
        connection.owner.closes += 1;
        std.heap.c_allocator.destroy(connection);
    }

    fn advertisesTools(self: *const FakeConnector, requested_era: canonical.Era) bool {
        return switch (requested_era) {
            .modern_2026_07_28 => self.advertise_tools,
            .classic_2025_11_25 => self.advertise_tools_2025_11 orelse self.advertise_tools,
            .classic_2025_06_18 => self.advertise_tools_2025_06 orelse self.advertise_tools,
        };
    }

    fn requestId(encoded: []const u8) ?u64 {
        const marker = "\"id\":";
        const start = (std.mem.indexOf(u8, encoded, marker) orelse return null) + marker.len;
        var end = start;
        while (end < encoded.len and std.ascii.isDigit(encoded[end])) : (end += 1) {}
        return std.fmt.parseInt(u64, encoded[start..end], 10) catch null;
    }
};

test "modern client owns disposable probe actual lifecycle catalog and call" {
    var fake = FakeConnector{ .era = .modern_2026_07_28 };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .stdio,
        .server_binding_identity = [_]u8{1} ** 32,
        .client = .{ .name = "agentcore-test", .version = "1" },
    });
    var client = switch (connected) {
        .client => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer client.deinit();
    try std.testing.expectEqual(canonical.Era.modern_2026_07_28, client.era);
    try std.testing.expectEqual(@as(usize, 1), client.catalog.tools.len);
    try std.testing.expectEqual(@as(u8, 2), fake.opens);
    try std.testing.expectEqual(@as(u8, 1), fake.closes);
    var called = client.callTool(
        std.testing.allocator,
        &client.catalog.tools[0],
        "{\"city\":\"Paris\"}",
        .{},
    );
    defer if (called == .result) called.result.deinit();
    try std.testing.expect(called == .result);
    try std.testing.expect(called.result.structured_content_json != null);
}

test "modern tools list merges successful pages and conservative cache policy" {
    var fake = FakeConnector{
        .era = .modern_2026_07_28,
        .paginate_tools = true,
    };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .stdio,
        .server_binding_identity = [_]u8{6} ** 32,
        .client = .{ .name = "agentcore-test", .version = "1" },
    });
    const client = switch (connected) {
        .client => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer client.deinit();

    try std.testing.expectEqual(@as(u8, 2), fake.list_requests);
    try std.testing.expect(fake.saw_second_page_cursor);
    try std.testing.expectEqual(@as(usize, 2), client.catalog.tools.len);
    try std.testing.expectEqualStrings("weather", client.catalog.tools[0].identity.name);
    try std.testing.expectEqualStrings("alerts", client.catalog.tools[1].identity.name);
    try std.testing.expectEqual(@as(f64, 1000), client.catalog.cache.ttl_ms.?);
    try std.testing.expectEqual(canonical.CacheScope.private, client.catalog.cache.scope);
}

test "Classic client performs initialized notification and indeterminate call is never replayed" {
    var fake = FakeConnector{ .era = .classic_2025_11_25, .indeterminate_call = true };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .stdio,
        .policy = .legacy_only,
        .server_binding_identity = [_]u8{2} ** 32,
        .client = .{ .name = "agentcore-test", .version = "1" },
    });
    const client = switch (connected) {
        .client => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer client.deinit();
    try std.testing.expectEqual(@as(u8, 1), fake.notifications);
    const before = fake.requests;
    const called = client.callTool(
        std.testing.allocator,
        &client.catalog.tools[0],
        "{\"city\":\"Paris\"}",
        .{},
    );
    try std.testing.expect(called == .failed and called.failed == .indeterminate);
    try std.testing.expectEqual(before + 1, fake.requests);
}

test "Classic optional task metadata keeps ordinary tools call semantics" {
    var fake = FakeConnector{
        .era = .classic_2025_11_25,
        .optional_task = true,
    };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .stdio,
        .policy = .legacy_only,
        .server_binding_identity = [_]u8{0x29} ** 32,
        .client = .{ .name = "agentcore-test", .version = "1" },
    });
    const client = switch (connected) {
        .client => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer client.deinit();
    try std.testing.expectEqual(
        canonical.ExecutionMode.task_optional,
        client.catalog.tools[0].execution_mode,
    );

    const before = fake.requests;
    var called = client.callTool(
        std.testing.allocator,
        &client.catalog.tools[0],
        "{\"city\":\"Paris\"}",
        .{},
    );
    defer if (called == .result) called.result.deinit();
    try std.testing.expect(called == .result);
    try std.testing.expectEqual(before + 1, fake.requests);
}

test "AUTO promotes only the final exact 2025-06 connection" {
    var fake = FakeConnector{ .era = .classic_2025_06_18 };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .stdio,
        .policy = .auto,
        .server_binding_identity = [_]u8{0x26} ** 32,
        .client = .{ .name = "agentcore-test", .version = "1" },
    });
    const client = switch (connected) {
        .client => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer client.deinit();
    try std.testing.expectEqual(canonical.Era.classic_2025_06_18, client.era);
    try std.testing.expect(client.capabilities.tool_catalog_available);
    try std.testing.expectEqual(@as(u8, 3), fake.opens);
    try std.testing.expectEqual(@as(u8, 2), fake.closes);
    try std.testing.expectEqual(@as(u8, 1), fake.notifications);
    try std.testing.expectEqual(@as(u8, 1), fake.list_requests);
}

test "AUTO publishes only capabilities from the final exact 2025-06 handshake" {
    var fake = FakeConnector{
        .era = .classic_2025_06_18,
        .advertise_tools_2025_11 = true,
        .advertise_tools_2025_06 = false,
    };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .stdio,
        .policy = .auto,
        .server_binding_identity = [_]u8{0x25} ** 32,
        .client = .{ .name = "agentcore-test", .version = "1" },
    });
    const client = switch (connected) {
        .client => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer client.deinit();
    try std.testing.expectEqual(canonical.Era.classic_2025_06_18, client.era);
    try std.testing.expect(!client.capabilities.tool_catalog_available);
    try std.testing.expectEqual(@as(usize, 0), client.catalog.tools.len);
    try std.testing.expectEqual(@as(u8, 0), fake.list_requests);
    try std.testing.expectEqual(@as(u8, 1), fake.notifications);
}

test "exact Modern policy classifies MethodNotFound as unsupported revision" {
    var fake = FakeConnector{ .era = .classic_2025_11_25 };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .stdio,
        .policy = .modern_only,
        .server_binding_identity = [_]u8{0x24} ** 32,
        .client = .{ .name = "agentcore-test", .version = "1" },
    });
    try std.testing.expect(connected == .failed);
    try std.testing.expectEqual(
        canonical.DiagnosticCode.unsupported_protocol_version,
        connected.failed.diagnostic.code,
    );
    try std.testing.expectEqual(@as(u8, 1), fake.opens);
    try std.testing.expectEqual(@as(u8, 1), fake.closes);
    try std.testing.expectEqual(@as(u8, 0), fake.list_requests);
}

test "exact 2025-11 policy does not accept a 2025-06 selection" {
    var fake = FakeConnector{ .era = .classic_2025_06_18 };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .stdio,
        .policy = .legacy_only,
        .server_binding_identity = [_]u8{0x27} ** 32,
        .client = .{ .name = "agentcore-test", .version = "1" },
    });
    try std.testing.expect(connected == .failed);
    try std.testing.expectEqual(
        canonical.DiagnosticCode.era_revalidation_mismatch,
        connected.failed.diagnostic.code,
    );
    try std.testing.expectEqual(@as(u8, 1), fake.opens);
    try std.testing.expectEqual(@as(u8, 1), fake.closes);
    try std.testing.expectEqual(@as(u8, 0), fake.list_requests);
}

test "Classic server without tools capability never receives tools list" {
    var fake = FakeConnector{
        .era = .classic_2025_11_25,
        .advertise_tools = false,
    };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .stdio,
        .policy = .legacy_only,
        .server_binding_identity = [_]u8{0x28} ** 32,
        .client = .{ .name = "agentcore-test", .version = "1" },
    });
    const client = switch (connected) {
        .client => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer client.deinit();
    try std.testing.expect(!client.capabilities.tool_catalog_available);
    try std.testing.expectEqual(@as(usize, 0), client.catalog.tools.len);
    try std.testing.expectEqual(@as(u8, 0), fake.list_requests);
}

test "server remains schema authority and its Tool error is preserved" {
    var fake = FakeConnector{
        .era = .modern_2026_07_28,
        .business_error = true,
    };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .stdio,
        .server_binding_identity = [_]u8{3} ** 32,
        .client = .{ .name = "agentcore-test", .version = "1" },
    });
    const client = switch (connected) {
        .client => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer client.deinit();
    var called = client.callTool(
        std.testing.allocator,
        &client.catalog.tools[0],
        "{\"city\":7}",
        .{},
    );
    defer if (called == .result) called.result.deinit();
    try std.testing.expect(called == .result);
    try std.testing.expect(called.result.is_error);
    try std.testing.expect(called.result.structured_content_json == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        called.result.raw_result_json,
        "city unavailable",
    ) != null);
}

test "input_required is terminal for one call without retrying or poisoning the client" {
    var fake = FakeConnector{
        .era = .modern_2026_07_28,
        .input_required_once = true,
    };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .stdio,
        .server_binding_identity = [_]u8{4} ** 32,
        .client = .{ .name = "agentcore-test", .version = "1" },
    });
    const client = switch (connected) {
        .client => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer client.deinit();

    const before = fake.requests;
    const unsupported = client.callTool(
        std.testing.allocator,
        &client.catalog.tools[0],
        "{\"city\":\"Paris\"}",
        .{},
    );
    try std.testing.expect(unsupported == .failed);
    try std.testing.expectEqual(
        canonical.DiagnosticCode.input_required_unsupported,
        unsupported.failed.diagnostic.code,
    );
    try std.testing.expectEqual(before + 1, fake.requests);
    try std.testing.expectEqual(@as(u8, 2), fake.opens);

    var completed = client.callTool(
        std.testing.allocator,
        &client.catalog.tools[0],
        "{\"city\":\"Paris\"}",
        .{},
    );
    defer if (completed == .result) completed.result.deinit();
    try std.testing.expect(completed == .result);
    try std.testing.expectEqual(before + 2, fake.requests);
    try std.testing.expectEqual(@as(u8, 2), fake.opens);
}

test "modern typed content remains lossless in the canonical result" {
    var fake = FakeConnector{
        .era = .modern_2026_07_28,
        .typed_content = true,
    };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .stdio,
        .server_binding_identity = [_]u8{5} ** 32,
        .client = .{ .name = "agentcore-test", .version = "1" },
    });
    const client = switch (connected) {
        .client => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer client.deinit();
    var called = client.callTool(
        std.testing.allocator,
        &client.catalog.tools[0],
        "{\"city\":\"Paris\"}",
        .{},
    );
    defer if (called == .result) called.result.deinit();
    try std.testing.expect(called == .result);
    inline for (.{ "text", "image", "audio", "resource_link", "resource" }) |kind| {
        const needle = try std.fmt.allocPrint(
            std.testing.allocator,
            "\"type\":\"{s}\"",
            .{kind},
        );
        defer std.testing.allocator.free(needle);
        try std.testing.expect(std.mem.indexOf(
            u8,
            called.result.content_json,
            needle,
        ) != null);
    }
}
