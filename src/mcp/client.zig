//! The one MCP protocol client. Every entry point (the CLI, source-level library
//! consumers, the AgentCore facade through `runtime.zig`) runs this state
//! machine: version negotiation, request correlation, server→client requests,
//! cancellation, MRTR continuation, pagination, tool calls, resource access and
//! result projection. A fix to protocol behaviour belongs here.
//!
//! What differs between entry points is data, not code: a `Profile` (how strict,
//! who owns the probe, whether input can be supplied) and a `Transport` adapter
//! (stdio, Streamable HTTP, HTTP+SSE, a Host connection). doc/MCP_ARCHITECTURE.md
//! lists every retained difference and the test that pins it.
//!
//! Protocol versions (the 2026-07-28 "dual era" client, basic/transports/stdio.mdx
//! "Backward Compatibility"):
//! - `.auto`: send `server/discover`. A DiscoverResult (or a -32022 carrying
//!   `supported`) that lists 2026-07-28 selects Modern: no handshake, every
//!   request carries `_meta["io.modelcontextprotocol/…"]`, results carry
//!   `resultType`, input requests use MRTR. Anything else goes through
//!   `negotiation.selectFromProbeWith`.
//! - Classic: `initialize` asks for 2025-11-25, then `notifications/initialized`.
//!   Answers server→client `ping` and form-mode `elicitation/create`; an
//!   undeclared `roots/list` or `sampling/createMessage` gets method_not_found.
//!
//! A stream transport is one ordered JSON-RPC stream, so one request at a time
//! owns the send/recv loop (`request_mutex`).
//!
//! Replay (requirement 6 of #405). Three things look alike and are not:
//! - a protocol continuation completes the same logical request and may send
//!   more bytes: an MRTR retry with `inputResponses`, an SSE resumption with
//!   `Last-Event-ID`, a POST repeated after a 401 refused it;
//! - a retry known not to have been delivered: a POST on a pooled connection
//!   that failed before its body was fully written;
//! - an indeterminate outcome: the request left and no answer came. It is
//!   reported with `Disposition.indeterminate` and never sent again by this
//!   client. Only the caller can decide what to do with a tool that may have
//!   executed.

const std = @import("std");
const protocol = @import("protocol.zig");
const canonical = @import("canonical.zig");
const wire = @import("wire.zig");
const modern = @import("era_modern.zig");
const classic = @import("era_classic.zig");
const negotiation = @import("negotiation.zig");
const StdioTransport = @import("transport_stdio.zig").StdioTransport;
const transport_mod = @import("transport.zig");
const host = @import("host_transport.zig");
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
const result_stream = @import("result_stream.zig");
const json_util = @import("../util/json.zig");
const util_time = @import("../util/time.zig");

pub const MODERN_VERSION = canonical.MODERN_VERSION;
pub const CLASSIC_VERSION = canonical.CLASSIC_2025_11_VERSION;
/// Classic revisions an interop client speaks, newest first.
pub const CLASSIC_VERSIONS = [_][]const u8{
    canonical.CLASSIC_2025_11_VERSION,
    canonical.CLASSIC_2025_06_VERSION,
    canonical.CLASSIC_2025_03_VERSION,
    canonical.CLASSIC_2024_11_VERSION,
};

/// MRTR rounds one request may take before the client gives up.
const MAX_INPUT_ROUNDS: usize = 8;

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

/// Who owns the discovery probe's connection.
pub const ProbeOwnership = enum {
    /// A connection that answered the probe carries on: no second child, no
    /// second TLS handshake. Only one that died or went silent is replaced.
    reuse,
    /// The probe's connection is always closed, and the real one opened for
    /// the selected era (the Host Connector contract: `purpose` tells the Host
    /// which is which).
    disposable,
};

/// Everything that separates one entry point's use of this client from another's.
pub const Profile = struct {
    conformance: wire.Conformance,
    probe: ProbeOwnership,
    /// Whether a Modern `input_required` result is fulfilled and retried. When
    /// false it is a terminal `input_required_unsupported`, one request, the
    /// connection untouched.
    input_continuation: bool,
    /// What the client declares to the server.
    capabilities: wire.ClientCapabilities,
    limits: canonical.Limits,
    /// `tools/list` bound and what happens at it: silently keep what fits
    /// (`truncate_catalog`), or fail.
    max_list_pages: usize,
    truncate_catalog: bool,

    /// The CLI and source-level consumers: real servers as they are.
    pub const product = Profile{
        .conformance = .interop,
        .probe = .reuse,
        .input_continuation = true,
        .capabilities = .{ .elicitation = true },
        .limits = .{
            .max_frame_bytes = 128 * 1024 * 1024 + 1024 * 1024,
            .max_tools = 2048,
            .max_tool_name_bytes = 64 * 1024,
            .max_text_bytes = 1024 * 1024,
            .max_schema_bytes = 64 * 1024 * 1024,
            .max_json_depth = 256,
            .max_json_nodes = 8 * 1024 * 1024,
            .max_cursor_bytes = 1024 * 1024,
            .max_versions = 64,
        },
        .max_list_pages = 100,
        .truncate_catalog = true,
    };

    /// The AgentCore public contract (doc/AGENTCORE_BINARY_ABI.md): exact eras,
    /// a disposable probe, typed diagnostics, no elicitation until the ABI can
    /// carry one.
    pub fn hostContract(limits: canonical.Limits) Profile {
        return .{
            .conformance = .strict,
            .probe = .disposable,
            .input_continuation = false,
            .capabilities = .{},
            .limits = limits,
            .max_list_pages = limits.max_tools +| 1,
            .truncate_catalog = false,
        };
    }
};

pub const ProtocolPolicy = enum {
    /// Probe `server/discover`, fall back to the `initialize` handshake.
    auto,
    /// Require 2026-07-28.
    modern_only,
    /// Skip the probe and speak the handshake revisions only.
    classic_only,

    fn negotiationPolicy(self: ProtocolPolicy) negotiation.Policy {
        return switch (self) {
            .auto => .auto,
            .modern_only => .modern_only,
            .classic_only => .legacy_only,
        };
    }
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

/// Why a connection could not be established, as the entry points report it.
pub const ConnectFailure = union(enum) {
    diagnostic: canonical.Diagnostic,
    timeout,
    network_error,
    auth_error,
    server_error,
    child_exit,
    cancelled,
    indeterminate,
    fatal,
    resource_limit,
    out_of_memory,
};

/// Why one request failed.
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

pub const BodyFailure = struct {
    failure: CallFailure,
    disposition: canonical.Disposition,
    /// The transport's own error, for a caller that reports by error name.
    /// `error.McpDiagnostic` when `failure` is a diagnostic.
    err: anyerror,
    /// The frame a remote error arrived in, when the profile keeps it for the
    /// model (bounded, owned by the result allocator).
    detail: ?[]u8 = null,
};

pub const BodyOutcome = union(enum) {
    result: ToolResultBody,
    failed: BodyFailure,
};

pub const ToolInvocation = struct {
    /// The server's own name for the tool, not the model-facing alias.
    name: []const u8,
    arguments_json: []const u8,
    artifact_root: []const u8,
    budget: result_budget.Budget,
    abort: ?*const AbortSignal = null,
    /// `Mcp-Param-*` headers (Streamable HTTP; other transports ignore them).
    headers: []const transport_mod.Header = &.{},
    has_output_schema: bool = false,
};

pub const Transport = transport_mod.Transport;

pub const Opener = struct {
    ctx: *anyopaque,
    /// A transport, or the error that says why not: `error.Timeout`,
    /// `error.McpConnectFailed`, `error.McpAuthRequired`,
    /// `error.McpServerError` and `error.McpServerCrashed` are observations;
    /// anything else ends the attempt.
    open_fn: *const fn (ctx: *anyopaque, purpose: host.ConnectionPurpose, era: canonical.Era) anyerror!Transport,

    fn open(self: Opener, purpose: host.ConnectionPurpose, era: canonical.Era) anyerror!Transport {
        return self.open_fn(self.ctx, purpose, era);
    }
};

pub const EstablishConfig = struct {
    opener: Opener,
    transport_kind: negotiation.Transport,
    policy: negotiation.Policy,
    profile: Profile,
    /// Must outlive the client.
    client: wire.ClientInfo,
    startup_deadline_ms: ?i64 = null,
    probe_timeout_ms: u32 = 10_000,
    abort: ?*const AbortSignal = null,
    request_timeout_ms: ?u32 = null,
};

pub const EstablishOutcome = union(enum) {
    connected: McpClient,
    failed: struct { failure: ConnectFailure, err: anyerror },
};

/// Connect: negotiate an era, leave one live connection in the returned client.
pub fn establish(gpa: std.mem.Allocator, config: EstablishConfig) EstablishOutcome {
    var client = McpClient{
        .allocator = gpa,
        .transport = undefined,
        .profile = config.profile,
        .client_info = config.client,
        .request_timeout_ms = config.request_timeout_ms,
    };
    var state = Negotiator{ .gpa = gpa, .config = &config, .client = &client };
    const selected = negotiation.negotiateWith(
        state.driver(),
        config.policy,
        config.transport_kind,
        config.profile.conformance,
    ) catch return connectFailed(&state, .out_of_memory);
    const era = switch (selected) {
        .diagnostic => |diagnostic| return connectFailed(&state, .{ .diagnostic = diagnostic }),
        .value => |value| value,
    };
    const capabilities = state.final_capabilities orelse return connectFailed(&state, .{
        .diagnostic = canonical.Diagnostic.init(.era_revalidation_mismatch, .revalidation),
    });
    client.next_id = state.next_request_id;
    client.adoptEra(era, capabilities);
    client.transport.setDeadline(null);
    client.connection_live = true;
    return .{ .connected = client };
}

fn connectFailed(negotiator: *Negotiator, fallback: ConnectFailure) EstablishOutcome {
    negotiator.closeLive();
    // Over the strict contract a failed probe is reported through its policy
    // (`downgrade_refused`); an interop caller reads the failure itself.
    const interop = negotiator.config.profile.conformance == .interop;
    const reported: ?anyerror = if (negotiator.failure != null)
        negotiator.failure
    else if (interop)
        negotiator.probe_error
    else
        null;
    if (reported) |err|
        return .{ .failed = .{ .failure = connectFailureOf(err), .err = err } };
    return .{ .failed = .{ .failure = fallback, .err = errorForConnectFailure(fallback) } };
}

fn errorForConnectFailure(failure: ConnectFailure) anyerror {
    return switch (failure) {
        .diagnostic => |diagnostic| switch (diagnostic.code) {
            .unsupported_protocol_version, .era_revalidation_mismatch => error.UnsupportedProtocolVersion,
            .connection_failed, .downgrade_refused, .probe_failed => error.McpConnectFailed,
            else => error.McpMalformedResponse,
        },
        .timeout => error.McpRequestTimeout,
        .network_error => error.McpConnectFailed,
        .auth_error => error.McpAuthRequired,
        .server_error => error.McpServerError,
        .child_exit => error.McpServerCrashed,
        .cancelled => error.Aborted,
        .indeterminate => error.McpOutcomeIndeterminate,
        .fatal => error.McpConnectionFatal,
        .resource_limit => error.McpResourceLimit,
        .out_of_memory => error.OutOfMemory,
    };
}

pub fn toolCallParams(allocator: std.mem.Allocator, name: []const u8, arguments_json: []const u8) ![]u8 {
    return protocol.callToolParams(allocator, name, arguments_json);
}

/// `failureOf(...).failure`, for a caller that only reports what happened.
pub fn callFailureOf(err: anyerror) CallFailure {
    return failureOf(err, true, "tools/call").failure;
}

pub fn connectFailureOf(err: anyerror) ConnectFailure {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.Timeout, error.McpRequestTimeout => .timeout,
        error.McpConnectFailed => .network_error,
        error.McpAuthRequired => .auth_error,
        error.McpServerError => .server_error,
        error.McpServerCrashed, error.Eof => .child_exit,
        error.Aborted => .cancelled,
        error.McpOutcomeIndeterminate => .indeterminate,
        error.McpResourceLimit, error.McpLineTooLarge => .resource_limit,
        else => .fatal,
    };
}

/// Drives `negotiation.negotiateWith`. One transport is live at a time, held by
/// the client being built.
const Negotiator = struct {
    gpa: std.mem.Allocator,
    config: *const EstablishConfig,
    client: *McpClient,
    live: bool = false,
    probe_observation: ?negotiation.ProbeObservation = null,
    probe_handshake: ?canonical.OwnedHandshake = null,
    /// What an interop probe learned (Modern was selected on its connection).
    probe_capabilities: ?canonical.CanonicalCapabilities = null,
    /// The probe's connection answered cleanly and may carry the handshake.
    probe_clean: bool = false,
    reuse_ready: bool = false,
    final_capabilities: ?canonical.CanonicalCapabilities = null,
    /// Why the real connection failed.
    failure: ?anyerror = null,
    /// Why the probe failed. Evidence for the policy, and the reason an interop
    /// connect reports when the policy refuses to continue.
    probe_error: ?anyerror = null,
    next_request_id: u64 = 1,

    const modern_listed = [_][]const u8{canonical.MODERN_VERSION};

    fn driver(self: *Negotiator) negotiation.Driver {
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

    fn cast(raw: ?*anyopaque) *Negotiator {
        return @ptrCast(@alignCast(raw.?));
    }

    fn profile(self: *const Negotiator) *const Profile {
        return &self.config.profile;
    }

    fn closeLive(self: *Negotiator) void {
        if (self.live) self.client.transport.close();
        self.live = false;
    }

    fn startProbe(raw: ?*anyopaque, _: negotiation.Transport) negotiation.DriverError!void {
        const self = cast(raw);
        if (self.live or self.probe_observation != null) return error.TransportFailure;
        self.client.transport = self.config.opener.open(.disposable_probe, .modern_2026_07_28) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.probe_observation = observationOf(self, err) orelse {
                self.probe_error = err;
                return error.TransportFailure;
            };
            return;
        };
        self.live = true;
    }

    /// What a failed probe says about the server. Null: it says nothing, the
    /// attempt is over.
    fn observationOf(self: *Negotiator, err: anyerror) ?negotiation.ProbeObservation {
        self.probe_error = err;
        return switch (err) {
            error.Timeout, error.McpRequestTimeout => .timeout,
            error.Aborted => .cancelled,
            error.McpAuthRequired => .auth_error,
            error.McpServerError => .server_error,
            error.McpServerCrashed, error.Eof, error.ReadFailed, error.WriteFailed => .child_exit,
            error.McpMalformedResponse, error.McpOutcomeIndeterminate => .malformed_response,
            error.McpConnectFailed, error.McpRedirected, error.McpSessionExpired => .network_error,
            else => null,
        };
    }

    fn observeProbe(raw: ?*anyopaque) negotiation.DriverError!negotiation.ProbeObservation {
        const self = cast(raw);
        if (self.probe_observation) |observation| return observation;
        if (!self.live) return error.TransportFailure;
        const client = self.client;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const id: u64 = 1;
        const request = modern.encodeDiscoverRequest(
            arena.allocator(),
            id,
            self.config.client,
            self.profile().capabilities,
            self.profile().limits,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidValue, error.ResourceLimit => error.ResourceLimit,
        };
        if (self.profile().probe == .reuse) self.next_request_id = id + 1;
        client.transport.setModern(true, canonical.MODERN_VERSION);
        client.transport.setProbing(true);
        defer client.transport.setProbing(false);
        const started = util_time.nowMs();
        client.transport.setDeadline(minDeadline(self.config.startup_deadline_ms, started + self.config.probe_timeout_ms));
        defer client.transport.setDeadline(null);
        client.transport.setAbort(self.config.abort);
        defer client.transport.setAbort(null);
        client.transport.send(request, .{ .method = "server/discover" }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.observationOf(err) orelse error.TransportFailure;
        };
        defer client.transport.markAnswered();
        return switch (self.profile().conformance) {
            .strict => self.observeStrict(arena.allocator(), id),
            .interop => self.observeInterop(id),
        };
    }

    /// A completed answer is parsed exactly: only a validated DiscoverResult or
    /// -32022 is version evidence. Over HTTP a bare 400 also counts, whatever
    /// its body, unless that body is a typed -32022 that failed validation.
    fn observeStrict(self: *Negotiator, arena: std.mem.Allocator, id: u64) negotiation.DriverError!negotiation.ProbeObservation {
        const client = self.client;
        const frame = while (true) {
            const line = client.transport.recvLine() catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return self.observationOf(err) orelse error.TransportFailure;
            };
            if (client.transport.singleResponse()) break line;
            const kind = wire.classifyFrame(arena, line) catch {
                self.gpa.free(line);
                return error.OutOfMemory;
            };
            switch (kind) {
                .response => break line,
                .malformed => break line,
                .notification, .server_request => self.gpa.free(line),
            }
        };
        defer self.gpa.free(frame);
        const status: u32 = client.transport.lastHttpStatus() orelse
            if (self.config.transport_kind == .streamable_http) 200 else 0;
        const http_400 = self.config.transport_kind == .streamable_http and status == 400;
        if (http_400 and frame.len == 0) return .legacy_http_400;
        const parsed = modern.parseDiscoverProbeResponse(
            self.gpa,
            frame,
            id,
            self.profile().limits,
        ) catch return error.OutOfMemory;
        return switch (parsed) {
            .value => |handshake| blk: {
                self.probe_handshake = handshake;
                break :blk .{ .discovered_versions = self.probe_handshake.?.supported_versions };
            },
            .diagnostic => |diagnostic| if (diagnostic.code == .method_not_found)
                .method_not_found
            else if (http_400 and isLegacyBare400Diagnostic(diagnostic) and
                diagnostic.rpc_code != wire.UNSUPPORTED_PROTOCOL_VERSION)
                .legacy_http_400
            else
                .malformed_response,
        };
    }

    /// Read until the probe's answer, skipping what precedes it (a server may
    /// log before its handshake). Only an answer listing 2026-07-28 selects
    /// Modern; every other completed answer is `.method_not_found`-shaped
    /// evidence for the handshake. A stream ending without an answer over HTTP
    /// is a completed answer too (a 4xx with no JSON-RPC body).
    fn observeInterop(self: *Negotiator, id: u64) negotiation.DriverError!negotiation.ProbeObservation {
        const client = self.client;
        const is_http = client.transport.isHttp();
        while (true) {
            const line = client.transport.recvLine() catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (is_http and err == error.Eof) {
                    self.probe_clean = true;
                    return .method_not_found;
                }
                return self.observationOf(err) orelse error.TransportFailure;
            };
            defer self.gpa.free(line);
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const kind = wire.classifyFrame(a, line) catch return error.OutOfMemory;
            const response_id = switch (kind) {
                .response => |response| response.id,
                .malformed, .notification, .server_request => continue,
            };
            if (response_id != id) continue;
            self.probe_clean = true;
            const parsed = wire.parseResponseEnvelopeWith(a, line, id, .discovery, self.profile().limits, .interop) catch
                return error.OutOfMemory;
            const envelope = switch (parsed) {
                .diagnostic => return .malformed_response,
                .value => |value| value,
            };
            switch (envelope) {
                .result => |result| {
                    if (result == .object and listsVersion(result.object.get("supportedVersions"), canonical.MODERN_VERSION)) {
                        self.probe_capabilities = capabilitiesFrom(result.object.get("capabilities"));
                        return .{ .discovered_versions = &modern_listed };
                    }
                },
                .remote_error => |remote| if (remote.data) |data| if (data == .object) {
                    // -32022 UnsupportedProtocolVersion carries `data.supported`.
                    if (listsVersion(data.object.get("supported"), canonical.MODERN_VERSION)) {
                        self.probe_capabilities = .{ .tool_catalog_available = true };
                        return .{ .discovered_versions = &modern_listed };
                    }
                },
            }
            return .method_not_found;
        }
    }

    fn finishProbe(raw: ?*anyopaque) void {
        const self = cast(raw);
        if (self.probe_handshake) |*handshake| handshake.deinit();
        self.probe_handshake = null;
        self.probe_observation = null;
        if (self.live and self.probe_clean and self.profile().probe == .reuse) {
            self.reuse_ready = true;
        } else {
            self.closeLive();
        }
    }

    fn connectActual(raw: ?*anyopaque, era: canonical.Era) negotiation.DriverError!void {
        const self = cast(raw);
        self.failure = null;
        // The probe's outcome was weighed; it no longer says why this failed.
        self.probe_error = null;
        if (self.reuse_ready) {
            self.reuse_ready = false;
        } else {
            if (self.live) return error.TransportFailure;
            // The probe killed or wedged the server: a fresh one gets what is
            // left of the startup budget.
            if (self.config.startup_deadline_ms) |deadline| {
                if (util_time.nowMs() >= deadline) return self.fail(error.McpRequestTimeout);
            }
            if (self.config.abort) |signal| if (signal.isAborted()) return self.fail(error.Aborted);
            self.client.transport = self.config.opener.open(.actual, era) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return self.fail(err);
            };
            self.live = true;
        }
        self.client.transport.setModern(era.isModern(), canonical.MODERN_VERSION);
        self.client.transport.setDeadline(self.config.startup_deadline_ms);
    }

    fn fail(self: *Negotiator, err: anyerror) negotiation.DriverError {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        self.failure = err;
        return error.TransportFailure;
    }

    fn revalidateActual(
        raw: ?*anyopaque,
        era: canonical.Era,
    ) negotiation.DriverError!negotiation.RevalidatedProtocol {
        const self = cast(raw);
        if (!self.live) return error.TransportFailure;
        if (era.isModern()) return self.revalidateModern();
        return self.handshakeClassic(era);
    }

    fn revalidateModern(self: *Negotiator) negotiation.DriverError!negotiation.RevalidatedProtocol {
        // The connection that answered the probe needs no second discovery.
        if (self.profile().probe == .reuse) if (self.probe_capabilities) |capabilities| {
            self.final_capabilities = capabilities;
            return .{ .known = .modern_2026_07_28 };
        };
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const id = self.takeId() catch return error.ResourceLimit;
        const request = modern.encodeDiscoverRequest(
            arena.allocator(),
            id,
            self.config.client,
            self.profile().capabilities,
            self.profile().limits,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidValue, error.ResourceLimit => error.ResourceLimit,
        };
        const frame = self.client.exchangeEncoded(id, request, .{ .method = "server/discover" }, self.config.abort) catch |err|
            return self.fail(err);
        defer self.gpa.free(frame);
        if (self.profile().conformance == .interop) {
            const parsed = wire.parseResponseEnvelopeWith(arena.allocator(), frame, id, .discovery, self.profile().limits, .interop) catch
                return error.OutOfMemory;
            if (parsed == .value) if (parsed.value == .result) if (parsed.value.result == .object) {
                const result = parsed.value.result.object;
                if (listsVersion(result.get("supportedVersions"), canonical.MODERN_VERSION)) {
                    self.final_capabilities = capabilitiesFrom(result.get("capabilities"));
                    return .{ .known = .modern_2026_07_28 };
                }
            };
            return .unsupported_revision;
        }
        var handshake = switch (modern.parseDiscoverResponse(
            self.gpa,
            frame,
            id,
            self.profile().limits,
        ) catch return error.OutOfMemory) {
            .value => |value| value,
            .diagnostic => |diagnostic| return if (isUnsupportedRevision(diagnostic))
                .unsupported_revision
            else
                error.TransportFailure,
        };
        defer handshake.deinit();
        for (handshake.supported_versions) |version| {
            if (canonical.Era.parseExact(version) == .modern_2026_07_28) {
                self.final_capabilities = handshake.capabilities;
                return .{ .known = .modern_2026_07_28 };
            }
        }
        return .unsupported_revision;
    }

    fn handshakeClassic(self: *Negotiator, era: canonical.Era) negotiation.DriverError!negotiation.RevalidatedProtocol {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const id = self.takeId() catch return error.ResourceLimit;
        const offered = classic.ClassicProfile.forEra(era).?;
        const request = classic.encodeInitializeRequest(
            arena.allocator(),
            id,
            offered,
            self.config.client,
            self.profile().capabilities,
            self.profile().limits,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidValue, error.ResourceLimit => error.ResourceLimit,
        };
        const frame = self.client.exchangeEncoded(id, request, .{ .method = "initialize" }, self.config.abort) catch |err|
            return self.fail(err);
        defer self.gpa.free(frame);
        const conformance = self.profile().conformance;
        var handshake = switch (classic.parseInitializeResponseWith(
            self.gpa,
            frame,
            id,
            offered,
            self.profile().limits,
            conformance,
        ) catch return error.OutOfMemory) {
            .value => |value| value,
            .diagnostic => |diagnostic| {
                if (diagnostic.code == .unsupported_protocol_version or
                    (conformance == .strict and diagnostic.code == .method_not_found))
                    return .unsupported_revision;
                if (conformance == .strict) return error.TransportFailure;
                return self.fail(switch (diagnostic.code) {
                    .remote_error, .method_not_found => error.McpError,
                    else => error.McpMalformedResponse,
                });
            },
        };
        defer handshake.deinit();
        const selected = handshake.era;
        // A strict client never promotes this connection: the negotiator
        // closes it and reopens the era the server selected.
        if (selected != era and conformance == .strict) return .{ .known = selected };
        // HTTP: later requests carry the negotiated revision.
        self.client.transport.setProtocolVersion(selected.version());
        const notification = try classic.encodeInitializedNotification(arena.allocator());
        self.client.transport.send(notification, .{
            .method = "notifications/initialized",
            .kind = .notification,
        }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (conformance == .strict) return error.TransportFailure;
            return self.fail(err);
        };
        self.final_capabilities = handshake.capabilities;
        return .{ .known = selected };
    }

    fn takeId(self: *Negotiator) error{ResourceLimit}!u64 {
        if (self.next_request_id == std.math.maxInt(u64)) return error.ResourceLimit;
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    fn disconnectActual(raw: ?*anyopaque) void {
        const self = cast(raw);
        self.closeLive();
        self.final_capabilities = null;
    }
};

fn isUnsupportedRevision(diagnostic: canonical.Diagnostic) bool {
    return diagnostic.code == .unsupported_protocol_version or
        diagnostic.code == .method_not_found;
}

fn isLegacyBare400Diagnostic(diagnostic: canonical.Diagnostic) bool {
    return switch (diagnostic.code) {
        .invalid_json, .invalid_envelope, .response_id_mismatch => true,
        else => false,
    };
}

fn listsVersion(value: ?std.json.Value, version: []const u8) bool {
    const list = value orelse return false;
    if (list != .array) return false;
    for (list.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, version)) return true;
    }
    return false;
}

fn capabilitiesFrom(value: ?std.json.Value) canonical.CanonicalCapabilities {
    const object = value orelse return .{ .tool_catalog_available = false };
    if (object != .object) return .{ .tool_catalog_available = false };
    return .{
        .tool_catalog_available = object.object.get("tools") != null,
        .resources_available = object.object.get("resources") != null,
        .prompts_available = object.object.get("prompts") != null,
    };
}

fn minDeadline(first: ?i64, second: i64) i64 {
    return if (first) |value| @min(value, second) else second;
}

const StdioOpener = struct {
    allocator: std.mem.Allocator,
    spec: SpawnSpec,

    fn interface(self: *StdioOpener) Opener {
        return .{ .ctx = self, .open_fn = open };
    }

    fn open(raw: *anyopaque, _: host.ConnectionPurpose, _: canonical.Era) anyerror!Transport {
        const self: *StdioOpener = @ptrCast(@alignCast(raw));
        return .{ .stdio = try StdioTransport.spawnWith(self.allocator, self.spec.argv, self.spec.options()) };
    }
};

const HttpOpener = struct {
    allocator: std.mem.Allocator,
    spec: McpClient.HttpSpec,
    startup_deadline_ms: ?i64,
    abort: ?*const AbortSignal,

    fn interface(self: *HttpOpener) Opener {
        return .{ .ctx = self, .open_fn = open };
    }

    fn open(raw: *anyopaque, _: host.ConnectionPurpose, _: canonical.Era) anyerror!Transport {
        const self: *HttpOpener = @ptrCast(@alignCast(raw));
        // The transport takes the stored login, or destroys it on failure.
        const auth = self.spec.auth;
        self.spec.auth = null;
        return switch (self.spec.wire) {
            .streamable => .{ .http = try HttpTransport.createWithAuth(self.allocator, self.spec.io, self.spec.url, self.spec.headers, auth) },
            .legacy_sse => .{ .sse = try SseTransport.create(self.allocator, self.spec.io, self.spec.url, self.spec.headers, .{
                .deadline_ms = self.startup_deadline_ms,
                .abort = self.abort,
                .auth = auth,
            }) },
        };
    }
};

fn productClientInfo() wire.ClientInfo {
    return .{ .name = "metacodes", .version = @import("../version.zig").semver };
}

fn connectedOrError(outcome: EstablishOutcome) !McpClient {
    return switch (outcome) {
        .connected => |client| client,
        .failed => |failed| failed.err,
    };
}

pub const McpClient = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    /// False once the connection was closed (`close`, or a connector contract
    /// failure). A retired client refuses further requests.
    connection_live: bool = false,
    usable: std.atomic.Value(bool) = .init(true),
    next_id: u64 = 1,
    /// A stream transport is one ordered JSON-RPC stream. Parallel agent tools
    /// may call the same server concurrently, but only one request may own the
    /// send/recv loop at a time or responses can be consumed by the wrong call.
    request_mutex: sync.Mutex = .{},
    /// server→client elicitation 回调(可选)。未设 → 一律 decline(协议仍正确闭合,server 不卡)。
    elicit: ?ElicitHandler = null,
    profile: Profile,
    client_info: wire.ClientInfo,
    era: canonical.Era = .classic_2025_11_25,
    /// `era.version()`, kept for source-level consumers.
    protocol_version: []const u8 = CLASSIC_VERSION,
    /// `era.isModern()`: no session, every request carries `_meta`.
    modern: bool = false,
    capabilities: ServerCapabilities = .{},
    /// Whether the handshake declared the tool catalog (a Modern server always does).
    tool_catalog_available: bool = false,
    request_timeout_ms: ?u32 = null,
    /// Set when the server announces `notifications/tools/list_changed`.
    tools_changed: std.atomic.Value(bool) = .init(false),

    /// Historical entry point: empty environment, no deadlines, `.auto` protocol.
    pub fn connect(
        allocator: std.mem.Allocator,
        argv: []const ?[*:0]const u8,
    ) !McpClient {
        return connectWith(allocator, .{ .spawn = .{ .argv = argv } });
    }

    pub fn connectWith(allocator: std.mem.Allocator, options: ConnectOptions) !McpClient {
        var opener = StdioOpener{ .allocator = allocator, .spec = options.spawn };
        return connectedOrError(establish(allocator, .{
            .opener = opener.interface(),
            .transport_kind = .stdio,
            .policy = options.protocol.negotiationPolicy(),
            .profile = Profile.product,
            .client = productClientInfo(),
            .startup_deadline_ms = if (options.startup_timeout_ms) |ms| util_time.nowMs() + ms else null,
            .probe_timeout_ms = options.probe_timeout_ms,
            .abort = options.abort,
            .request_timeout_ms = options.request_timeout_ms,
        }));
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
        const startup_deadline: ?i64 = if (options.startup_timeout_ms) |ms| util_time.nowMs() + ms else null;
        var opener = HttpOpener{
            .allocator = allocator,
            .spec = spec,
            .startup_deadline_ms = startup_deadline,
            .abort = options.abort,
        };
        defer if (opener.spec.auth) |source| source.destroy();
        return connectedOrError(establish(allocator, .{
            .opener = opener.interface(),
            .transport_kind = .streamable_http,
            .policy = if (spec.wire == .legacy_sse) .legacy_only else options.protocol.negotiationPolicy(),
            .profile = Profile.product,
            .client = productClientInfo(),
            .startup_deadline_ms = startup_deadline,
            .probe_timeout_ms = options.probe_timeout_ms,
            .abort = options.abort,
            .request_timeout_ms = options.request_timeout_ms,
        }));
    }

    pub fn close(self: *McpClient) void {
        if (self.connection_live) self.transport.close();
        self.connection_live = false;
        self.usable.store(false, .release);
    }

    pub fn isUsable(self: *const McpClient) bool {
        return self.usable.load(.acquire);
    }

    /// The connector broke its contract: nothing it says can be trusted now.
    /// Requires `request_mutex` once the client is shared.
    pub fn retire(self: *McpClient) void {
        if (!self.usable.swap(false, .acq_rel)) return;
        self.transport.close();
        self.connection_live = false;
    }

    fn adoptEra(self: *McpClient, era: canonical.Era, capabilities: canonical.CanonicalCapabilities) void {
        self.era = era;
        self.protocol_version = era.version();
        self.modern = era.isModern();
        self.tool_catalog_available = capabilities.tool_catalog_available;
        self.capabilities = .{
            .tools = capabilities.tool_catalog_available,
            .resources = capabilities.resources_available,
            .prompts = capabilities.prompts_available,
        };
    }

    fn nextId(self: *McpClient) error{McpResourceLimit}!u64 {
        if (self.next_id == std.math.maxInt(u64)) return error.McpResourceLimit;
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn encode(self: *const McpClient, allocator: std.mem.Allocator, id: u64, method: []const u8, params_json: []const u8) ![]u8 {
        return wire.encodeRequest(
            allocator,
            id,
            self.era,
            self.client_info,
            self.profile.capabilities,
            method,
            params_json,
            self.profile.limits,
        ) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ResourceLimit => error.McpResourceLimit,
            error.InvalidValue => error.McpInvalidParams,
        };
    }

    /// Send one encoded request and read until its response frame (owned).
    /// A strict frame is judged by its parser; here it is only correlated.
    pub fn exchangeEncoded(
        self: *McpClient,
        id: u64,
        encoded: []const u8,
        meta: transport_mod.SendMeta,
        abort: ?*const AbortSignal,
    ) ![]u8 {
        self.transport.setAbort(abort);
        defer self.transport.setAbort(null);
        var sent = false;
        self.transport.send(encoded, meta) catch |err| return self.sendFailure(err, &sent);
        defer self.transport.markAnswered();
        const single = self.transport.singleResponse();
        while (true) {
            const line = self.transport.recvLine() catch |err| return self.failInFlight(id, err);
            if (single) return line;
            errdefer self.allocator.free(line);
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const kind = try wire.classifyFrame(arena.allocator(), line);
            switch (kind) {
                .malformed => return error.McpMalformedResponse,
                .notification => |method| {
                    self.noteNotification(method);
                },
                .server_request => |request| {
                    self.handleServerRequest(request.id, request.method, line);
                },
                .response => |response| {
                    // Not this request's (a cancelled request's late answer).
                    if (response.id == null or response.id.? == id) return line;
                },
            }
            self.allocator.free(line);
        }
    }

    /// Encode, send, read one response frame. Requires `request_mutex` once
    /// the client is shared. The caller owns `Answer.frame`.
    pub fn exchange(
        self: *McpClient,
        method: []const u8,
        params_json: []const u8,
        abort: ?*const AbortSignal,
    ) !Answer {
        const id = try self.nextId();
        const request = try self.encode(self.allocator, id, method, params_json);
        defer self.allocator.free(request);
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const meta = try sendMeta(scratch.allocator(), method, params_json);
        return .{ .id = id, .frame = try self.exchangeEncoded(id, request, meta, abort) };
    }

    pub const Answer = struct { id: u64, frame: []u8 };

    fn noteNotification(self: *McpClient, method: []const u8) void {
        if (std.mem.eql(u8, method, "notifications/tools/list_changed"))
            self.tools_changed.store(true, .release);
    }

    /// One logical request materialized as JSON: every MRTR round, the result
    /// re-encoded from the parsed frame (so numbers keep their lexemes and a
    /// string containing `"result":` cannot be mistaken for it).
    fn requestLocked(self: *McpClient, method: []const u8, params_json: []const u8, abort: ?*const AbortSignal) ![]u8 {
        if (!self.usable.load(.acquire)) return error.McpInstanceUnavailable;
        var params = try self.allocator.dupe(u8, params_json);
        defer self.allocator.free(params);
        var round: usize = 0;
        while (true) : (round += 1) {
            const answer = try self.exchange(method, params, abort);
            defer self.allocator.free(answer.frame);
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const parsed = try wire.parseEnvelopeWith(
                arena.allocator(),
                answer.frame,
                answer.id,
                phaseOf(method),
                self.profile.limits,
                self.profile.conformance,
            );
            const result = switch (parsed) {
                .value => |value| value,
                .diagnostic => |diagnostic| return errorForDiagnostic(diagnostic),
            };
            if (self.modern and isInputRequiredValue(result)) {
                if (!self.profile.input_continuation or round + 1 >= MAX_INPUT_ROUNDS or !mrtrMethod(method))
                    return error.McpInputRequired;
                const retry = try self.retryParams(params, result);
                self.allocator.free(params);
                params = retry;
                continue;
            }
            return std.json.Stringify.valueAlloc(self.allocator, result, .{}) catch error.OutOfMemory;
        }
    }

    fn requestJson(self: *McpClient, method: []const u8, params_json: []const u8, abort: ?*const AbortSignal) ![]u8 {
        self.request_mutex.lock();
        defer self.request_mutex.unlock();
        return self.requestLocked(method, params_json, abort) catch |err| {
            if (err == error.McpConnectionFatal) self.retire();
            return err;
        };
    }

    /// Interrupted or timed out: tell the server unless the transport already
    /// did, then report the failure.
    fn failInFlight(self: *McpClient, id: u64, err: anyerror) anyerror {
        switch (err) {
            error.Aborted, error.Timeout => {
                if (self.transport.cancelsItself()) return if (err == error.Timeout) error.McpRequestTimeout else err;
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
                self.transport.send(note, .{ .method = "notifications/cancelled", .kind = .notification }) catch {};
                return if (err == error.Timeout) error.McpRequestTimeout else err;
            },
            error.OutOfMemory,
            error.McpAuthRequired,
            error.McpSessionExpired,
            error.McpServerError,
            error.McpRedirected,
            error.McpConnectFailed,
            error.McpLineTooLarge,
            error.McpStreamClosed,
            error.McpOutcomeIndeterminate,
            error.McpConnectionFatal,
            error.McpResourceLimit,
            error.ArtifactTooLarge,
            => return err,
            else => return error.McpServerCrashed,
        }
    }

    /// A request that did not get its answer from `send`. `sent` records
    /// whether the server may have seen it: a transport that sends and reads
    /// the head in one step can fail after the request is out.
    fn sendFailure(self: *McpClient, err: anyerror, sent: *bool) anyerror {
        sent.* = self.transport.requestWritten();
        return switch (err) {
            error.Timeout => error.McpRequestTimeout,
            error.McpConnectFailed => if (sent.*) error.McpOutcomeIndeterminate else err,
            error.Aborted,
            error.OutOfMemory,
            error.McpAuthRequired,
            error.McpSessionExpired,
            error.McpServerError,
            error.McpRedirected,
            error.McpStreamClosed,
            error.McpConnectionFatal,
            error.McpOutcomeIndeterminate,
            => err,
            else => error.McpServerCrashed,
        };
    }

    /// Fulfil a Modern `InputRequiredResult` and return the retry params:
    /// the original params plus `inputResponses` and the echoed `requestState`.
    fn retryParams(self: *McpClient, params_json: []const u8, result: std.json.Value) ![]u8 {
        if (result != .object) return error.McpMalformedResponse;
        var responses: std.Io.Writer.Allocating = .init(self.allocator);
        defer responses.deinit();
        try responses.writer.writeByte('{');
        var first = true;
        if (result.object.get("inputRequests")) |requests| if (requests == .object) {
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

        var original = try std.json.parseFromSlice(std.json.Value, self.allocator, params_json, .{ .parse_numbers = false });
        defer original.deinit();
        if (original.value != .object) return error.McpInvalidParams;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try out.writer.writeByte('{');
        // Strip a previous round's fields: each retry carries only the new ones.
        var wrote = false;
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
        if (result.object.get("requestState")) |state| {
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

    const BodyOptions = struct {
        headers: []const transport_mod.Header = &.{},
        has_output_schema: bool = false,
        /// `tools/call`: the strict contract requires `content`.
        is_tool: bool,
    };

    /// One byte-zero request: every frame enters a private capture before
    /// anything looks at it, and a successful result's inline-or-seal
    /// disposition follows `budget.per_result_bytes`.
    fn runBody(
        self: *McpClient,
        result_allocator: std.mem.Allocator,
        out: *BodyOutcome,
        method: []const u8,
        params_json: []const u8,
        artifact_root: []const u8,
        budget: result_budget.Budget,
        abort: ?*const AbortSignal,
        options: BodyOptions,
    ) void {
        if (artifact_root.len == 0) {
            out.* = .{ .failed = .{ .failure = .resource_limit, .disposition = .not_delivered, .err = error.ArtifactRootUnavailable } };
            return;
        }
        self.request_mutex.lock();
        defer self.request_mutex.unlock();
        if (!self.usable.load(.acquire)) {
            out.* = .{ .failed = .{ .failure = .instance_unavailable, .disposition = .not_delivered, .err = error.McpInstanceUnavailable } };
            return;
        }
        if (abort) |signal| if (signal.isAborted()) {
            out.* = .{ .failed = .{ .failure = .cancelled, .disposition = .not_delivered, .err = error.Aborted } };
            return;
        };
        self.transport.setDeadline(if (self.request_timeout_ms) |ms| util_time.nowMs() + ms else null);
        defer if (self.connection_live) self.transport.setDeadline(null);
        var params = self.allocator.dupe(u8, params_json) catch {
            out.* = .{ .failed = .{ .failure = .out_of_memory, .disposition = .not_delivered, .err = error.OutOfMemory } };
            return;
        };
        defer self.allocator.free(params);
        var round: usize = 0;
        while (true) : (round += 1) {
            var sent = false;
            var outcome: RoundOutcome = undefined;
            self.bodyRound(result_allocator, &outcome, &sent, method, params, artifact_root, budget, abort, options) catch |err| {
                if (err == error.McpConnectionFatal) self.retire();
                out.* = .{ .failed = failureOf(err, sent, method) };
                return;
            };
            switch (outcome) {
                .body => |body| {
                    out.* = .{ .result = body };
                    return;
                },
                .diagnostic => |diagnostic| {
                    out.* = .{ .failed = .{
                        .failure = .{ .diagnostic = diagnostic.diagnostic },
                        .disposition = .answered,
                        .err = error.McpDiagnostic,
                        .detail = diagnostic.detail,
                    } };
                    return;
                },
                .input_required => |frame| {
                    defer self.allocator.free(frame.bytes);
                    if (round + 1 >= MAX_INPUT_ROUNDS) {
                        out.* = .{ .failed = failureOf(error.McpInputRequired, true, method) };
                        return;
                    }
                    const retry = self.retryParamsFromFrame(params, frame) catch |err| {
                        out.* = .{ .failed = failureOf(err, true, method) };
                        return;
                    };
                    self.allocator.free(params);
                    params = retry;
                },
            }
        }
    }

    fn retryParamsFromFrame(self: *McpClient, params_json: []const u8, frame: InputFrame) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = try wire.parseEnvelopeWith(
            arena.allocator(),
            frame.bytes,
            frame.id,
            .tools_call,
            self.profile.limits,
            self.profile.conformance,
        );
        return switch (parsed) {
            .value => |result| self.retryParams(params_json, result),
            .diagnostic => error.McpMalformedResponse,
        };
    }

    const InputFrame = struct { id: u64, bytes: []u8 };

    const RoundOutcome = union(enum) {
        body: ToolResultBody,
        diagnostic: struct { diagnostic: canonical.Diagnostic, detail: ?[]u8 = null },
        /// Modern MRTR: the owned frame to fulfil and retry.
        input_required: InputFrame,
    };

    /// Writing to `out`: in a function returning a ToolResultBody, each
    /// `return error.X` would copy a 3.7 KiB constant, one per error name
    /// (doc/PERF_MEMORY_PRINCIPLES.md §3g).
    fn bodyRound(
        self: *McpClient,
        result_allocator: std.mem.Allocator,
        out: *RoundOutcome,
        sent: *bool,
        method: []const u8,
        params_json: []const u8,
        artifact_root: []const u8,
        budget: result_budget.Budget,
        abort: ?*const AbortSignal,
        options: BodyOptions,
    ) !void {
        const id = try self.nextId();
        const encoded = try self.encode(self.allocator, id, method, params_json);
        defer self.allocator.free(encoded);
        self.transport.setAbort(abort);
        defer if (self.connection_live) self.transport.setAbort(null);
        var meta_scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer meta_scratch.deinit();
        var meta = try sendMeta(meta_scratch.allocator(), method, params_json);
        meta.param_headers = options.headers;
        self.transport.send(encoded, meta) catch |err| return self.sendFailure(err, sent);
        sent.* = true;
        defer if (self.connection_live) self.transport.markAnswered();

        const single = self.transport.singleResponse();
        const interop = self.profile.conformance == .interop;
        const inspect_frames = !single or self.profile.input_continuation;
        while (true) {
            var capture = try artifact_store.Capture.begin(
                result_allocator,
                artifact_root,
                result_stream.MAX_RESPONSE_BYTES,
            );
            defer capture.deinit();
            self.transport.recvLineCapture(&capture) catch |err| return self.failInFlight(id, err);
            try capture.seal();

            // Server→client requests are intentionally bounded control-plane
            // frames. Materialize only this small class so elicitation keeps
            // its existing synchronous semantics.
            const bounded = capture.bytes <= CONTROL_FRAME_MATERIALIZE_BYTES;
            if (bounded and inspect_frames) {
                const line = try capture.readRangeAlloc(self.allocator, 0, @intCast(capture.bytes));
                defer self.allocator.free(line);
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                switch (try wire.classifyFrame(arena.allocator(), line)) {
                    // Left to the projector under the strict contract, which
                    // reports what is wrong with it.
                    .malformed => if (interop) return error.McpMalformedResponse,
                    .notification => |notification| if (!single) {
                        self.noteNotification(notification);
                        continue;
                    },
                    .server_request => |server_request| if (!single) {
                        self.handleServerRequest(server_request.id, server_request.method, line);
                        continue;
                    },
                    .response => |response| {
                        if (!single and response.id != null and response.id.? != id) continue;
                        // The model reads a remote error's own words.
                        if (response.is_error and interop) {
                            const bounded_detail = line[0..@min(line.len, 64 * 1024)];
                            out.* = .{ .diagnostic = .{
                                .diagnostic = canonical.Diagnostic.init(.remote_error, phaseOf(method)),
                                .detail = try result_allocator.dupe(u8, bounded_detail),
                            } };
                            return;
                        }
                        if (response.input_required and self.modern and self.profile.input_continuation) {
                            if (!mrtrMethod(method)) return error.McpInputRequired;
                            out.* = .{ .input_required = .{ .id = id, .bytes = try self.allocator.dupe(u8, line) } };
                            return;
                        }
                    },
                }
            }

            var limits = self.projectorLimits();
            // The bytes of a bounded frame are already in memory, so a failed
            // publication keeps them; above that it fails closed.
            if (interop and bounded) limits.retain_inline_ceiling = CONTROL_FRAME_MATERIALIZE_BYTES;
            const projected = try result_stream.project(
                result_allocator,
                &capture,
                artifact_root,
                id,
                projectorEra(self.era),
                limits,
                budget,
                options.has_output_schema,
                options.is_tool and !interop,
            );
            switch (projected) {
                .result => |body| out.* = .{ .body = body },
                .diagnostic => |diagnostic| {
                    if (diagnostic.code == .response_id_mismatch and !single) continue;
                    out.* = .{ .diagnostic = .{ .diagnostic = .{
                        .code = projectorDiagnosticCode(diagnostic.code),
                        .phase = phaseOf(method),
                        .rpc_code = diagnostic.rpc_code,
                    } } };
                },
            }
            return;
        }
    }

    fn projectorLimits(self: *const McpClient) result_stream.Limits {
        return .{
            .max_text_bytes = self.profile.limits.max_text_bytes,
            .max_json_depth = self.profile.limits.max_json_depth,
            .max_json_nodes = self.profile.limits.max_json_nodes,
            .interop_envelope = self.profile.conformance == .interop,
        };
    }

    /// A `ToolResultBody`, or how this request failed and what that means for
    /// sending it again. The result allocator owns the body and any `detail`.
    pub fn invokeTool(self: *McpClient, result_allocator: std.mem.Allocator, call: ToolInvocation) BodyOutcome {
        var out: BodyOutcome = undefined;
        const params = protocol.callToolParams(self.allocator, call.name, call.arguments_json) catch |err| {
            out = .{ .failed = failureOf(err, false, "tools/call") };
            return out;
        };
        defer self.allocator.free(params);
        self.runBody(result_allocator, &out, "tools/call", params, call.artifact_root, call.budget, call.abort, .{
            .headers = call.headers,
            .has_output_schema = call.has_output_schema,
            .is_tool = true,
        });
        return out;
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
        var body: ToolResultBody = undefined;
        try admitOutcome(&body, self.allocator, self.invokeTool(self.allocator, .{
            .name = name,
            .arguments_json = arguments_json,
            .artifact_root = artifact_root,
            .budget = budget,
            .abort = abort,
            .headers = headers,
        }));
        return body;
    }

    /// 处理 server→client 请求并回复(Classic;Modern server 不发请求)。
    /// ping → 空结果(规范 MUST 及时应答);elicitation/create → 回调(或 decline);
    /// 其余(未声明的 roots/sampling 等)→ method_not_found。
    fn handleServerRequest(self: *McpClient, server_id: u64, method: []const u8, line: []const u8) void {
        if (std.mem.eql(u8, method, "ping")) {
            const reply = protocol.serializeResult(self.allocator, server_id, "{}") catch return;
            defer self.allocator.free(reply);
            self.transport.send(reply, .{ .kind = .response }) catch {};
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
                    self.transport.send(err, .{ .kind = .response }) catch {};
                    return;
                }
            };
            const result = self.elicitationResult(params) catch return;
            defer self.allocator.free(result);
            const reply = protocol.serializeResult(self.allocator, server_id, result) catch return;
            defer self.allocator.free(reply);
            self.transport.send(reply, .{ .kind = .response }) catch {};
            return;
        }
        // 其它 server→client 方法未声明 → method_not_found(回错误,不静默)。
        const err = protocol.serializeErrorResponse(self.allocator, server_id, @intFromEnum(protocol.ErrorCode.method_not_found), "not supported") catch return;
        defer self.allocator.free(err);
        self.transport.send(err, .{ .kind = .response }) catch {};
    }

    /// `tools/list` across pages. `consumer.page(frame, id)` reads one response
    /// frame and returns its `nextCursor` (null ends the list), which only has
    /// to live until the next page is requested. Requires `request_mutex` once
    /// the client is shared. Cursors are opaque: "" is valid, a repeat is not.
    pub fn paginateTools(self: *McpClient, abort: ?*const AbortSignal, consumer: anytype) !void {
        var cursor: ?[]u8 = null;
        defer if (cursor) |value| self.allocator.free(value);
        var pages: usize = 0;
        while (true) : (pages += 1) {
            if (pages >= self.profile.max_list_pages) {
                if (self.profile.truncate_catalog) return;
                return error.McpResourceLimit;
            }
            const params = if (cursor) |value| blk: {
                var out: std.Io.Writer.Allocating = .init(self.allocator);
                errdefer out.deinit();
                try out.writer.writeAll("{\"cursor\":");
                try json_util.writeJsonString(&out.writer, value);
                try out.writer.writeByte('}');
                break :blk try out.toOwnedSlice();
            } else try self.allocator.dupe(u8, protocol.EMPTY_PARAMS);
            defer self.allocator.free(params);
            const answer = try self.exchange("tools/list", params, abort);
            defer self.allocator.free(answer.frame);
            const next = (try consumer.page(answer.frame, answer.id)) orelse return;
            if (cursor) |previous| {
                if (std.mem.eql(u8, previous, next)) return error.McpRepeatedCursor;
                self.allocator.free(previous);
                cursor = null;
            }
            cursor = try self.allocator.dupe(u8, next);
        }
    }

    /// Keeps every tool object as the server wrote it: admission is the caller's.
    const RawToolPages = struct {
        client: *McpClient,
        tools: *std.Io.Writer.Allocating,
        count: usize = 0,
        arena: std.heap.ArenaAllocator,

        pub fn page(self: *RawToolPages, frame: []const u8, id: u64) !?[]const u8 {
            _ = self.arena.reset(.retain_capacity);
            const a = self.arena.allocator();
            const parsed = try wire.parseEnvelopeWith(a, frame, id, .tools_list, self.client.profile.limits, .interop);
            const result = switch (parsed) {
                .value => |value| value,
                .diagnostic => |diagnostic| return errorForDiagnostic(diagnostic),
            };
            if (result != .object) return error.McpMalformedResponse;
            const listed = result.object.get("tools") orelse return error.McpMalformedResponse;
            if (listed != .array) return error.McpMalformedResponse;
            const limit = self.client.profile.limits.max_tools;
            for (listed.array.items) |tool| {
                if (self.count == limit) break;
                if (self.count != 0) try self.tools.writer.writeByte(',');
                try std.json.Stringify.value(tool, .{}, &self.tools.writer);
                self.count += 1;
            }
            if (self.count == limit) return null;
            const next = result.object.get("nextCursor") orelse return null;
            return if (next == .string) next.string else null;
        }
    };

    /// 返回 tools 列表 `{"tools":[...]}`(owned JSON string,caller free),跨页聚合。
    pub fn listTools(self: *McpClient) ![]u8 {
        return self.listToolsAbortable(null);
    }

    /// `tools/list` (every page), interruptible as a whole by `abort`.
    pub fn listToolsAbortable(self: *McpClient, abort: ?*const AbortSignal) ![]u8 {
        self.request_mutex.lock();
        defer self.request_mutex.unlock();
        if (!self.usable.load(.acquire)) return error.McpInstanceUnavailable;
        var tools: std.Io.Writer.Allocating = .init(self.allocator);
        defer tools.deinit();
        try tools.writer.writeAll("{\"tools\":[");
        var pages = RawToolPages{
            .client = self,
            .tools = &tools,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
        };
        defer pages.arena.deinit();
        try self.paginateTools(abort, &pages);
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
        return try self.requestJson("tools/call", params, abort);
    }

    /// 列出 server 暴露的 resources（resources/list）。返回原始 JSON-RPC result。
    pub fn listResources(self: *McpClient) ![]u8 {
        return self.listResourcesAbortable(null);
    }

    pub fn listResourcesAbortable(self: *McpClient, abort: ?*const AbortSignal) ![]u8 {
        return try self.requestJson("resources/list", protocol.EMPTY_PARAMS, abort);
    }

    pub fn listResourcesBodyAbortable(
        self: *McpClient,
        artifact_root: []const u8,
        budget: result_budget.Budget,
        abort: ?*const AbortSignal,
    ) !ToolResultBody {
        var out: BodyOutcome = undefined;
        self.runBody(self.allocator, &out, "resources/list", protocol.EMPTY_PARAMS, artifact_root, budget, abort, .{ .is_tool = false });
        var body: ToolResultBody = undefined;
        try admitOutcome(&body, self.allocator, out);
        return body;
    }

    /// 读取一个 resource（resources/read）。uri 为 resource 标识。
    pub fn readResource(self: *McpClient, uri: []const u8) ![]u8 {
        return self.readResourceAbortable(uri, null);
    }

    pub fn readResourceAbortable(self: *McpClient, uri: []const u8, abort: ?*const AbortSignal) ![]u8 {
        const params = try protocol.readResourceParams(self.allocator, uri);
        defer self.allocator.free(params);
        return try self.requestJson("resources/read", params, abort);
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
        var out: BodyOutcome = undefined;
        self.runBody(self.allocator, &out, "resources/read", params, artifact_root, budget, abort, .{ .is_tool = false });
        var body: ToolResultBody = undefined;
        try admitOutcome(&body, self.allocator, out);
        return body;
    }
};

/// The product view of an outcome: a remote error is a structured error body
/// (the model reads it and may correct itself), a failure of the request is the
/// transport's error. `allocator` owns `outcome`'s body and detail.
pub fn admitOutcome(out: *ToolResultBody, allocator: std.mem.Allocator, outcome: BodyOutcome) !void {
    switch (outcome) {
        .result => |body| out.* = body,
        .failed => |failed| {
            defer if (failed.detail) |detail| allocator.free(detail);
            switch (failed.failure) {
                .diagnostic => |diagnostic| {
                    if (failed.err != error.McpDiagnostic) return failed.err;
                    const text = failed.detail orelse @tagName(diagnostic.code);
                    out.* = if (diagnostic.code == .resource_limit)
                        try structuredMcpError(allocator, text, .io_error, .system_error)
                    else
                        try structuredMcpError(allocator, text, .other, .user_error);
                },
                else => return failed.err,
            }
        },
    }
}

/// What a request's error means, given whether it left. An auth refusal or a
/// redirect is the server (or its gateway) declining to process the request.
fn failureOf(err: anyerror, sent: bool, method: []const u8) BodyFailure {
    const phase = phaseOf(method);
    const failure: CallFailure = switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.McpRequestTimeout, error.Timeout => .timeout,
        error.Aborted => .cancelled,
        error.McpAuthRequired => .auth_error,
        error.McpServerError, error.McpSessionExpired, error.McpRedirected => .server_error,
        error.McpConnectFailed, error.McpStreamClosed => .network_error,
        error.McpServerCrashed => .child_exit,
        error.McpOutcomeIndeterminate, error.McpConnectionFatal => .indeterminate,
        error.McpInstanceUnavailable => .instance_unavailable,
        error.McpResourceLimit, error.McpLineTooLarge, error.ArtifactTooLarge => .resource_limit,
        error.McpInputRequired => .{ .diagnostic = canonical.Diagnostic.init(.input_required_unsupported, phase) },
        error.McpInvalidParams => .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, phase) },
        error.McpMalformedResponse, error.McpInputUnsupported => .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, phase) },
        // A local failure capturing the answer: the capture's disk, its quota.
        else => .resource_limit,
    };
    const disposition: canonical.Disposition = if (!sent)
        .not_delivered
    else switch (err) {
        error.McpAuthRequired, error.McpRedirected, error.McpSessionExpired => .not_delivered,
        error.McpInputRequired, error.McpInputUnsupported, error.McpMalformedResponse => .answered,
        else => .indeterminate,
    };
    return .{ .failure = failure, .disposition = disposition, .err = err };
}

/// The failure a materialized request reports for a frame the parser refused.
fn errorForDiagnostic(diagnostic: canonical.Diagnostic) anyerror {
    return switch (diagnostic.code) {
        .remote_error, .method_not_found, .unsupported_protocol_version => error.McpError,
        .resource_limit => error.McpResourceLimit,
        else => error.McpMalformedResponse,
    };
}

fn phaseOf(method: []const u8) canonical.Phase {
    if (std.mem.eql(u8, method, "tools/call")) return .tools_call;
    if (std.mem.eql(u8, method, "tools/list")) return .tools_list;
    if (std.mem.eql(u8, method, "resources/list")) return .resources_list;
    if (std.mem.eql(u8, method, "resources/read")) return .resources_read;
    return .envelope_decode;
}

fn projectorEra(era: canonical.Era) result_stream.Era {
    return switch (era) {
        .modern_2026_07_28 => .modern_2026_07_28,
        .classic_2025_11_25 => .classic_2025_11_25,
        .classic_2025_06_18 => .classic_2025_06_18,
        .classic_2025_03_26 => .classic_2025_03_26,
        .classic_2024_11_05 => .classic_2024_11_05,
    };
}

fn projectorDiagnosticCode(code: result_stream.DiagnosticCode) canonical.DiagnosticCode {
    return switch (code) {
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
    };
}

pub fn structuredMcpError(
    allocator: std.mem.Allocator,
    detail: []const u8,
    code: tool_error.Code,
    category: tool_error.Category,
) !ToolResultBody {
    const bounded = detail[0..@min(detail.len, 64 * 1024)];
    const owned = try allocator.dupe(u8, bounded);
    const structured_error = ToolError.init(code, category, owned, true);
    defer structured_error.deinit(allocator);
    const encoded = try structured_error.toJson(allocator);
    defer allocator.free(encoded);
    return ToolResultBody.initStructuredError(allocator, encoded);
}

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

/// Only `tools/call`, `resources/read` and `prompts/get` may return
/// `input_required` (2026-07-28 MRTR).
fn mrtrMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "tools/call") or std.mem.eql(u8, method, "resources/read") or
        std.mem.eql(u8, method, "prompts/get");
}

/// A 2026-07-28 result whose `resultType` is `input_required`. An absent
/// `resultType` means `complete`.
fn isInputRequiredValue(result: std.json.Value) bool {
    if (result != .object) return false;
    const result_type = result.object.get("resultType") orelse return false;
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

test "McpClient: connect to nonexistent command fails at spawn, before any handshake" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const argv = [_]?[*:0]const u8{ "/nonexistent/mcp-server", null };
    // 子进程报告通道让 exec 失败在 spawn 处就返回;过去是 spawn "成功"、server 立刻死、
    // 握手再撞 McpServerCrashed/McpMalformedResponse,失败原因全程无人知道。
    try std.testing.expectError(error.SpawnFailed, McpClient.connect(std.testing.allocator, argv[0..]));
}
