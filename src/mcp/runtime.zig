//! A connected MCP server as a catalog holds it: the shared client plus the
//! canonical tool catalog read from it.
//!
//! Host code supplies an opaque connector (and therefore owns credentials); the
//! shared client (`client.zig`) owns disposable negotiation probes, the real
//! connection, request ordering and protocol state. `tools/call` is issued
//! exactly once: an indeterminate transport outcome is never replayed.

const std = @import("std");
const canonical = @import("canonical.zig");
const modern = @import("era_modern.zig");
const classic = @import("era_classic.zig");
const negotiation = @import("negotiation.zig");
const wire = @import("wire.zig");
const schema = @import("schema.zig");
const mcp_client = @import("client.zig");
const host = @import("host_transport.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const result_budget = @import("../core/result_budget.zig");
const ToolResultBody = @import("../core/tool_result.zig").ToolResultBody;

pub const McpClient = mcp_client.McpClient;
pub const ConnectionPurpose = host.ConnectionPurpose;
pub const Cancellation = host.Cancellation;
pub const ExchangeResponse = host.ExchangeResponse;
pub const ExchangeOutcome = host.ExchangeOutcome;
pub const ToolResponseSinkError = host.ToolResponseSinkError;
pub const ToolResponseSink = host.ToolResponseSink;
pub const ToolStreamExchangeOutcome = host.ToolStreamExchangeOutcome;
pub const ToolRequestExecutor = host.ToolRequestExecutor;
pub const Connection = host.Connection;
pub const ToolRequestOutcome = host.ToolRequestOutcome;
pub const OpenOutcome = host.OpenOutcome;
pub const Connector = host.Connector;
pub const ConnectFailure = mcp_client.ConnectFailure;
pub const CallFailure = mcp_client.CallFailure;

pub const Config = struct {
    connector: Connector,
    transport: negotiation.Transport,
    policy: negotiation.Policy = .auto,
    server_binding_identity: [32]u8,
    client: wire.ClientInfo,
    timeout_ms: u32 = 30_000,
    limits: canonical.Limits = .{},
    max_catalog_bytes: usize = 64 * 1024 * 1024,
    /// Everything a Host's connection may differ in from the strict contract
    /// is here; the default is what the public ABI promises.
    input_continuation: bool = false,
};

pub const ConnectOutcome = union(enum) {
    client: *Client,
    failed: ConnectFailure,
};

pub const CallOutcome = union(enum) {
    result: canonical.OwnedCallResult,
    failed: CallFailure,
};

pub const BodyCallOutcome = union(enum) {
    result: ToolResultBody,
    failed: CallFailure,
};

pub const Client = struct {
    // deinit is exclusive: the instance pool calls it only after every
    // catalog-owner and dispatch lease has been released.
    backing: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    mcp: McpClient,
    era: canonical.Era,
    capabilities: canonical.CanonicalCapabilities,
    binding: [32]u8,
    limits: canonical.Limits,
    catalog: canonical.OwnedCatalog,

    pub fn deinit(self: *Client) void {
        const backing = self.backing;
        self.mcp.close();
        self.catalog.deinit();
        self.arena.deinit();
        backing.destroy(self);
    }

    pub fn isUsable(self: *const Client) bool {
        return self.mcp.isUsable();
    }

    /// Admission every entry into a Tool shares: the Tool is this server's, and
    /// its arguments are one bounded JSON object.
    fn admitCall(
        self: *const Client,
        scratch: std.mem.Allocator,
        tool: *const canonical.Tool,
        arguments_json: []const u8,
    ) ?CallFailure {
        if (!std.mem.eql(u8, &tool.identity.server_binding_identity, &self.binding))
            return .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_call) };
        return switch (schema.validateArguments(
            scratch,
            arguments_json,
            schema.Limits.fromProtocol(self.limits),
        )) {
            .valid => null,
            .invalid => |issue| switch (issue) {
                .resource_limit => .resource_limit,
                .invalid_json, .not_object => .{
                    .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_call),
                },
            },
            .out_of_memory => .out_of_memory,
        };
    }

    /// Source-level canonical call: a completed response, parsed by its era's
    /// strict parser. Agent execution uses `callToolBody`.
    pub fn callTool(
        self: *Client,
        result_allocator: std.mem.Allocator,
        tool: *const canonical.Tool,
        arguments_json: []const u8,
        abort: ?*const AbortSignal,
    ) CallOutcome {
        if (self.admitCall(result_allocator, tool, arguments_json)) |failure|
            return .{ .failed = failure };
        self.mcp.request_mutex.lock();
        defer self.mcp.request_mutex.unlock();
        if (!self.mcp.isUsable()) return .{ .failed = .instance_unavailable };
        if (abort) |signal| if (signal.isAborted()) return .{ .failed = .cancelled };
        const params = mcp_client.toolCallParams(self.backing, tool.identity.name, arguments_json) catch
            return .{ .failed = .out_of_memory };
        defer self.backing.free(params);
        const answer = self.mcp.exchange("tools/call", params, abort) catch |err| {
            if (err == error.McpConnectionFatal) self.mcp.retire();
            return .{ .failed = mcp_client.callFailureOf(err) };
        };
        defer self.backing.free(answer.frame);
        const parsed = switch (self.era) {
            .modern_2026_07_28 => modern.parseCallToolResponse(
                result_allocator,
                answer.frame,
                answer.id,
                self.limits,
            ),
            else => |era| classic.parseCallToolResponse(
                result_allocator,
                answer.frame,
                answer.id,
                classic.ClassicProfile.forEra(era).?,
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
        budget: result_budget.Budget,
        tool: *const canonical.Tool,
        arguments_json: []const u8,
        abort: ?*const AbortSignal,
    ) BodyCallOutcome {
        if (artifact_root.len == 0) return .{ .failed = .resource_limit };
        if (self.admitCall(result_allocator, tool, arguments_json)) |failure|
            return .{ .failed = failure };
        return switch (self.mcp.invokeTool(result_allocator, .{
            .name = tool.identity.name,
            .arguments_json = arguments_json,
            .artifact_root = artifact_root,
            .budget = budget,
            .abort = abort,
            .has_output_schema = tool.output_schema_json != null,
        })) {
            .result => |body| .{ .result = body },
            .failed => |failed| .{ .failed = failed.failure },
        };
    }
};

pub const HostOpener = struct {
    gpa: std.mem.Allocator,
    connector: Connector,
    transport: negotiation.Transport,
    timeout_ms: u32,

    pub fn interface(self: *HostOpener) mcp_client.Opener {
        return .{ .ctx = self, .open_fn = open };
    }

    fn open(raw: *anyopaque, purpose: ConnectionPurpose, era: canonical.Era) anyerror!mcp_client.Transport {
        const self: *HostOpener = @ptrCast(@alignCast(raw));
        const opened = self.connector.open(purpose, era) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.McpConnectionFatal;
        };
        const connection = switch (opened) {
            .connection => |connection| connection,
            .timeout => return error.Timeout,
            .network_error => return error.McpConnectFailed,
            .auth_error => return error.McpAuthRequired,
            .server_error => return error.McpServerError,
            .child_exit => return error.McpServerCrashed,
        };
        const adapter = host.HostTransport.create(self.gpa, connection, self.transport, self.timeout_ms) catch |err| {
            connection.close();
            return err;
        };
        return .{ .host = adapter };
    }
};

pub fn connectServer(backing: std.mem.Allocator, config: Config) ConnectOutcome {
    config.limits.validate() catch return .{ .failed = .resource_limit };
    if (allZero(&config.server_binding_identity) or config.timeout_ms == 0 or
        config.max_catalog_bytes == 0)
        return .{ .failed = .resource_limit };

    const client = backing.create(Client) catch return .{ .failed = .out_of_memory };
    var arena = std.heap.ArenaAllocator.init(backing);
    const client_info = wire.ClientInfo{
        .name = arena.allocator().dupe(u8, config.client.name) catch {
            arena.deinit();
            backing.destroy(client);
            return .{ .failed = .out_of_memory };
        },
        .version = arena.allocator().dupe(u8, config.client.version) catch {
            arena.deinit();
            backing.destroy(client);
            return .{ .failed = .out_of_memory };
        },
    };
    var opener = HostOpener{
        .gpa = backing,
        .connector = config.connector,
        .transport = config.transport,
        .timeout_ms = config.timeout_ms,
    };
    var profile = mcp_client.Profile.hostContract(config.limits);
    profile.input_continuation = config.input_continuation;
    var mcp = switch (mcp_client.establish(backing, .{
        .opener = opener.interface(),
        .transport_kind = config.transport,
        .policy = config.policy,
        .profile = profile,
        .client = client_info,
    })) {
        .connected => |connected| connected,
        .failed => |failed| {
            arena.deinit();
            backing.destroy(client);
            return .{ .failed = failed.failure };
        },
    };
    const capabilities = canonical.CanonicalCapabilities{
        .tool_catalog_available = mcp.tool_catalog_available,
        .resources_available = mcp.capabilities.resources,
        .prompts_available = mcp.capabilities.prompts,
    };
    const catalog = if (mcp.tool_catalog_available)
        listAllTools(backing, &mcp, config) catch |err| {
            mcp.close();
            arena.deinit();
            backing.destroy(client);
            return .{ .failed = switch (err) {
                error.OutOfMemory => .out_of_memory,
                error.ResourceLimit, error.McpResourceLimit => .resource_limit,
                error.ProtocolFailure, error.McpRepeatedCursor => .{ .diagnostic = canonical.Diagnostic.init(.invalid_field, .tools_list) },
                else => mcp_client.connectFailureOf(err),
            } };
        }
    else
        canonical.OwnedCatalog.init(backing, mcp.era);
    client.* = .{
        .backing = backing,
        .arena = arena,
        .mcp = mcp,
        .era = mcp.era,
        .capabilities = capabilities,
        .binding = config.server_binding_identity,
        .limits = config.limits,
        .catalog = catalog,
    };
    return .{ .client = client };
}

/// Reads each page with its era's strict parser and admits it into one catalog.
const CatalogPages = struct {
    backing: std.mem.Allocator,
    config: Config,
    era: canonical.Era,
    combined: *canonical.OwnedCatalog,
    tools: *std.ArrayList(canonical.Tool),
    pages: usize = 0,
    retained_bytes: usize = @sizeOf(canonical.OwnedCatalog),

    pub fn page(self: *CatalogPages, frame: []const u8, id: u64) !?[]const u8 {
        const a = self.combined.allocator();
        const limits = self.config.limits;
        self.pages += 1;
        var parsed = switch (self.era) {
            .modern_2026_07_28 => switch (try modern.parseListToolsResponse(
                self.backing,
                frame,
                id,
                self.config.server_binding_identity,
                limits,
            )) {
                .value => |value| value,
                .diagnostic => return error.ProtocolFailure,
            },
            else => |era| switch (try classic.parseListToolsResponse(
                self.backing,
                frame,
                id,
                classic.ClassicProfile.forEra(era).?,
                self.config.server_binding_identity,
                limits,
            )) {
                .value => |value| value,
                .diagnostic => return error.ProtocolFailure,
            },
        };
        defer parsed.deinit();
        if (self.tools.items.len + parsed.tools.len > limits.max_tools)
            return error.ResourceLimit;
        for (parsed.tools) |tool| {
            for (self.tools.items) |existing| if (std.mem.eql(u8, existing.identity.name, tool.identity.name))
                return error.ProtocolFailure;
            const value = std.json.parseFromSliceLeaky(std.json.Value, a, tool.raw_json, .{
                .allocate = .alloc_always,
                .duplicate_field_behavior = .@"error",
            }) catch return error.ProtocolFailure;
            var copied = canonical.projectTool(
                a,
                value,
                self.era,
                self.config.server_binding_identity,
                limits,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ResourceLimit => error.ResourceLimit,
                error.InvalidValue => error.ProtocolFailure,
            };
            copied.execution_mode = tool.execution_mode;
            try self.charge(toolLogicalBytes(copied));
            try self.tools.append(a, copied);
        }
        self.combined.cache = conservativeCache(self.combined.cache, parsed.cache, self.pages == 1);
        if (parsed.meta_json) |meta| {
            try self.charge(meta.len);
            self.combined.meta_json = try a.dupe(u8, meta);
        }
        const next = parsed.next_cursor orelse return null;
        try self.charge(next.len);
        return try a.dupe(u8, next);
    }

    fn charge(self: *CatalogPages, bytes: usize) error{ResourceLimit}!void {
        self.retained_bytes = std.math.add(usize, self.retained_bytes, bytes) catch
            return error.ResourceLimit;
        if (self.retained_bytes > self.config.max_catalog_bytes)
            return error.ResourceLimit;
    }
};

fn listAllTools(
    backing: std.mem.Allocator,
    mcp: *McpClient,
    config: Config,
) anyerror!canonical.OwnedCatalog {
    var combined = canonical.OwnedCatalog.init(backing, mcp.era);
    errdefer combined.deinit();
    var tools: std.ArrayList(canonical.Tool) = .empty;
    defer tools.deinit(combined.allocator());
    var pages = CatalogPages{
        .backing = backing,
        .config = config,
        .era = mcp.era,
        .combined = &combined,
        .tools = &tools,
    };
    try mcp.paginateTools(null, &pages);
    combined.tools = try tools.toOwnedSlice(combined.allocator());
    return combined;
}

fn optionalLen(value: ?[]const u8) usize {
    return if (value) |bytes| bytes.len else 0;
}

fn toolLogicalBytes(tool: canonical.Tool) usize {
    return @sizeOf(canonical.Tool) +|
        tool.identity.name.len +|
        optionalLen(tool.title) +|
        optionalLen(tool.description) +|
        tool.input_schema_json.len +|
        optionalLen(tool.output_schema_json) +|
        optionalLen(tool.annotations_json) +|
        optionalLen(tool.icons_json) +|
        optionalLen(tool.meta_json) +|
        optionalLen(tool.execution_json) +|
        tool.raw_json.len;
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
    fatal_call: bool = false,
    business_error: bool = false,
    input_required_once: bool = false,
    typed_content: bool = false,
    optional_task: bool = false,
    paginate_tools: bool = false,
    probe_response_body: ?[]const u8 = null,
    probe_http_status: u32 = 0,
    actual_http_status: u32 = 0,
    call_http_status: ?u32 = null,
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
        if (std.mem.indexOf(u8, encoded, "tools/call") != null and self.fatal_call)
            return .fatal;
        if (std.mem.indexOf(u8, encoded, "tools/call") != null and self.indeterminate_call)
            return .indeterminate;
        const id = requestId(encoded) orelse return .server_error;
        const response = if (std.mem.indexOf(u8, encoded, "server/discover") != null)
            if (connection.purpose == .disposable_probe and self.probe_response_body != null)
                try allocator.dupe(u8, self.probe_response_body.?)
            else if (self.era == .modern_2026_07_28) try std.fmt.allocPrint(
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
        return .{ .response = .{
            .http_status = if (connection.purpose == .disposable_probe)
                self.probe_http_status
            else if (std.mem.indexOf(u8, encoded, "tools/call") != null)
                self.call_http_status orelse self.actual_http_status
            else
                self.actual_http_status,
            .body = response,
        } };
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
            .classic_2025_03_26, .classic_2024_11_05 => self.advertise_tools,
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

test "Streamable HTTP AUTO treats bare 400 variants as Classic evidence and revalidates exact" {
    const bodies = [_][]const u8{
        "",
        "<html>legacy endpoint</html>",
        "{\"jsonrpc\":\"2.0\"",
        "{\"jsonrpc\":\"2.0\",\"id\":99,\"error\":{\"code\":-32601,\"message\":\"not found\"}}",
    };
    for (bodies, 0..) |body, index| {
        var fake = FakeConnector{
            .era = .classic_2025_11_25,
            .probe_response_body = body,
            .probe_http_status = 400,
            .actual_http_status = 200,
        };
        const connected = connectServer(std.testing.allocator, .{
            .connector = fake.connector(),
            .transport = .streamable_http,
            .server_binding_identity = [_]u8{@intCast(0x41 + index)} ** 32,
            .client = .{ .name = "agentcore-test", .version = "9" },
        });
        const client = switch (connected) {
            .client => |value| value,
            .failed => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(canonical.Era.classic_2025_11_25, client.era);
        try std.testing.expectEqual(@as(u8, 2), fake.opens);
        try std.testing.expectEqual(@as(u8, 1), fake.closes);
        client.deinit();
    }
}

test "Streamable HTTP AUTO strictly consumes supported versions from 400 -32022" {
    var fake = FakeConnector{
        .era = .classic_2025_06_18,
        .probe_response_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"requested\":\"2026-07-28\",\"supported\":[\"2025-06-18\"]}}}",
        .probe_http_status = 400,
        .actual_http_status = 200,
    };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .streamable_http,
        .server_binding_identity = [_]u8{0x42} ** 32,
        .client = .{ .name = "agentcore-test", .version = "9" },
    });
    const client = switch (connected) {
        .client => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer client.deinit();
    try std.testing.expectEqual(canonical.Era.classic_2025_06_18, client.era);
    try std.testing.expectEqual(@as(u8, 2), fake.opens);
}

test "Streamable HTTP AUTO accepts validated negotiation evidence on HTTP 200 or 400" {
    const cases = [_]struct {
        era: canonical.Era,
        status: u32,
        body: []const u8,
    }{
        .{
            .era = .classic_2025_11_25,
            .status = 200,
            .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"not found\"}}",
        },
        .{
            .era = .classic_2025_06_18,
            .status = 200,
            .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"requested\":\"2026-07-28\",\"supported\":[\"2025-06-18\"]}}}",
        },
        .{
            .era = .modern_2026_07_28,
            .status = 400,
            .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{},\"ttlMs\":1000,\"cacheScope\":\"private\"}}",
        },
    };
    for (cases, 0..) |case, index| {
        var fake = FakeConnector{
            .era = case.era,
            .probe_response_body = case.body,
            .probe_http_status = case.status,
            .actual_http_status = 200,
        };
        const connected = connectServer(std.testing.allocator, .{
            .connector = fake.connector(),
            .transport = .streamable_http,
            .server_binding_identity = [_]u8{@intCast(0x48 + index)} ** 32,
            .client = .{ .name = "agentcore-test", .version = "9" },
        });
        const client = switch (connected) {
            .client => |value| value,
            .failed => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(case.era, client.era);
        client.deinit();
    }
}

test "Streamable HTTP AUTO refuses unlisted status and malformed typed -32022" {
    const cases = [_]struct {
        status: u32,
        body: []const u8,
        expected: canonical.DiagnosticCode,
    }{
        .{ .status = 422, .body = "not acceptable", .expected = .downgrade_refused },
        .{
            .status = 400,
            .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"Unsupported protocol version\",\"data\":{\"requested\":7,\"supported\":[\"2025-11-25\"]}}}",
            .expected = .probe_failed,
        },
    };
    for (cases, 0..) |case, index| {
        var fake = FakeConnector{
            .era = .classic_2025_11_25,
            .probe_response_body = case.body,
            .probe_http_status = case.status,
            .actual_http_status = 200,
        };
        const connected = connectServer(std.testing.allocator, .{
            .connector = fake.connector(),
            .transport = .streamable_http,
            .server_binding_identity = [_]u8{@intCast(0x50 + index)} ** 32,
            .client = .{ .name = "agentcore-test", .version = "9" },
        });
        switch (connected) {
            .client => |client| {
                client.deinit();
                return error.TestUnexpectedResult;
            },
            .failed => |failure| switch (failure) {
                .diagnostic => |diagnostic| try std.testing.expectEqual(case.expected, diagnostic.code),
                else => return error.TestUnexpectedResult,
            },
        }
        try std.testing.expectEqual(@as(u8, 1), fake.opens);
        try std.testing.expectEqual(@as(u8, 1), fake.closes);
    }
}

test "Streamable HTTP actual request maps status before protocol parsing without replay" {
    const cases = [_]struct { status: u32, auth: bool }{
        .{ .status = 401, .auth = true },
        .{ .status = 500, .auth = false },
    };
    for (cases, 0..) |case, index| {
        var fake = FakeConnector{
            .era = .modern_2026_07_28,
            .probe_http_status = 200,
            .actual_http_status = 200,
            .call_http_status = case.status,
        };
        const connected = connectServer(std.testing.allocator, .{
            .connector = fake.connector(),
            .transport = .streamable_http,
            .server_binding_identity = [_]u8{@intCast(0x60 + index)} ** 32,
            .client = .{ .name = "agentcore-test", .version = "9" },
        });
        const client = switch (connected) {
            .client => |value| value,
            .failed => return error.TestUnexpectedResult,
        };
        const before = fake.requests;
        const called = client.callTool(
            std.testing.allocator,
            &client.catalog.tools[0],
            "{\"city\":\"Paris\"}",
            null,
        );
        try std.testing.expect(called == .failed);
        if (case.auth)
            try std.testing.expect(called.failed == .auth_error)
        else
            try std.testing.expect(called.failed == .server_error);
        try std.testing.expectEqual(before + 1, fake.requests);
        client.deinit();
    }
}

test "Streamable HTTP connection revalidation preserves authentication failure" {
    var fake = FakeConnector{
        .era = .modern_2026_07_28,
        .actual_http_status = 401,
    };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .streamable_http,
        .policy = .modern_only,
        .server_binding_identity = [_]u8{0x69} ** 32,
        .client = .{ .name = "agentcore-test", .version = "9" },
    });
    switch (connected) {
        .client => |client| {
            client.deinit();
            return error.TestUnexpectedResult;
        },
        .failed => |failure| try std.testing.expect(failure == .auth_error),
    }
    try std.testing.expectEqual(@as(u8, 1), fake.opens);
    try std.testing.expectEqual(@as(u8, 1), fake.closes);
}

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
        null,
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
        null,
    );
    try std.testing.expect(called == .failed and called.failed == .indeterminate);
    try std.testing.expectEqual(before + 1, fake.requests);
}

test "fatal tools call retires the connection and the instance cannot be reused" {
    var fake = FakeConnector{ .era = .classic_2025_11_25, .fatal_call = true };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .stdio,
        .policy = .legacy_only,
        .server_binding_identity = [_]u8{0x72} ** 32,
        .client = .{ .name = "agentcore-test", .version = "1" },
    });
    const client = switch (connected) {
        .client => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer client.deinit();
    const before = fake.requests;
    const closes_before = fake.closes;
    const first = client.callTool(
        std.testing.allocator,
        &client.catalog.tools[0],
        "{\"city\":\"Paris\"}",
        null,
    );
    try std.testing.expect(first == .failed and first.failed == .indeterminate);
    try std.testing.expect(!client.isUsable());
    try std.testing.expectEqual(closes_before + 1, fake.closes);
    const second = client.callTool(
        std.testing.allocator,
        &client.catalog.tools[0],
        "{\"city\":\"Paris\"}",
        null,
    );
    try std.testing.expect(second == .failed and second.failed == .instance_unavailable);
    try std.testing.expectEqual(before + 1, fake.requests);
}

test "tools call uses the configured protocol limits and preserves resource classification" {
    var fake = FakeConnector{ .era = .classic_2025_11_25 };
    const connected = connectServer(std.testing.allocator, .{
        .connector = fake.connector(),
        .transport = .stdio,
        .policy = .legacy_only,
        .server_binding_identity = [_]u8{0x73} ** 32,
        .client = .{ .name = "agentcore-test", .version = "1" },
        .limits = .{ .max_json_depth = 12 },
    });
    const client = switch (connected) {
        .client => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer client.deinit();
    const before = fake.requests;
    const called = client.callTool(
        std.testing.allocator,
        &client.catalog.tools[0],
        "{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":{\"a\":0}}}}}}}}}}}}}",
        null,
    );
    try std.testing.expect(called == .failed and called.failed == .resource_limit);
    try std.testing.expectEqual(before, fake.requests);
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
        null,
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
        null,
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
        null,
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
        null,
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
        null,
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
