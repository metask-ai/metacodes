//! Immutable Runtime MCP catalog generations for AgentCore Revision 7.
//!
//! A refresh builds a complete candidate snapshot off to the side and only
//! then publishes one new generation. Sessions and Runs retain old snapshots,
//! so refresh never mutates authority already admitted to an active Run.

const std = @import("std");
const sync = @import("platform").sync;
const canonical = @import("mcp_canonical.zig");
const runtime = @import("mcp_runtime.zig");
const schema = @import("mcp_schema.zig");
const util_time = @import("metacodes-core").util_time;

pub const Clock = struct {
    ctx: ?*const anyopaque = null,
    now_fn: *const fn (?*const anyopaque) util_time.Nanos = systemNow,

    pub fn now(self: Clock) util_time.Nanos {
        return self.now_fn(self.ctx);
    }

    fn systemNow(_: ?*const anyopaque) util_time.Nanos {
        return util_time.nowNs();
    }
};

pub const MAX_NAMESPACE_BYTES: usize = 24;

pub const Limits = struct {
    max_servers: usize = 64,
    max_namespace_bytes: usize = MAX_NAMESPACE_BYTES,
    max_issues: usize = 4096,
    legacy_ttl_ms: u64 = 30_000,
    max_ttl_ms: u64 = 300_000,
};

pub const ServerSpec = struct {
    binding: [32]u8,
    namespace: []const u8,
    connector: runtime.Connector,
    transport: @import("mcp_negotiation.zig").Transport,
    policy: @import("mcp_negotiation.zig").Policy = .auto,
    client: @import("mcp_wire.zig").ClientInfo,
    timeout_ms: u32 = 30_000,
    protocol_limits: canonical.Limits = .{},
};

pub const Error = error{
    OutOfMemory,
    InvalidConfig,
    ResourceLimit,
    NotRefreshed,
};

pub const MaterializeError = error{
    OutOfMemory,
    AdmissionInvariantViolation,
};

pub const ToolIssue = union(enum) {
    schema: schema.Issue,
    task_required_unsupported,
};

pub const IssueKind = union(enum) {
    connection: runtime.ConnectFailure,
    tool: ToolIssue,
};

pub const CatalogIssue = struct {
    server_binding_identity: [32]u8,
    tool_name: ?[]const u8 = null,
    kind: IssueKind,
};

pub const ServerRecord = struct {
    namespace: []const u8,
    client: *runtime.Client,
    fingerprint: [32]u8,
    expires_at_ns: util_time.Nanos,
    cache_scope: canonical.CacheScope,
    admitted_tools: []AdmittedTool,

    pub fn isFreshAt(self: ServerRecord, now_ns: util_time.Nanos) bool {
        return now_ns < self.expires_at_ns;
    }
};

pub const MAX_MODEL_TOOL_NAME_BYTES: usize = 64;

/// A Snapshot stores only immutable admission evidence and a pointer to the
/// canonical Tool owned by its retained Runtime Client. Provider projection
/// trees are materialized only for tools selected into a Session View.
pub const AdmittedTool = struct {
    canonical: *const canonical.Tool,
    model_name: []const u8,
    diagnostics: []const schema.ProjectionDiagnostic,
};

pub const ServerDescription = struct {
    server_binding_identity: [32]u8,
    namespace: []const u8,
    era: canonical.Era,
    server_fingerprint: [32]u8,
    cache_scope: canonical.CacheScope,
    fresh: bool,
    ttl_remaining_ms: u64,
    tool_offset: u32,
    tool_count: u32,
};

pub const ToolDescription = struct {
    server_binding_identity: [32]u8,
    canonical_name: []const u8,
    schema_fingerprint: [32]u8,
    permission_binding: [32]u8,
};

pub const IssueDescription = struct {
    issue_id: [32]u8,
    server_binding_identity: [32]u8,
    tool_name: ?[]const u8,
    kind: []const u8,
    detail: []const u8,
};

/// Value-only Runtime query result. It gives every Host-visible catalog and
/// binding identifier a canonical resolution path without leaking Snapshot,
/// Client or transport pointers.
pub const Description = struct {
    arena: std.heap.ArenaAllocator,
    generation: u64,
    fingerprint: [32]u8,
    servers: []ServerDescription,
    tools: []ToolDescription,
    issues: []IssueDescription,

    pub fn deinit(self: *Description) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Snapshot = struct {
    backing: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    ref_count: std.atomic.Value(u32) = .init(1),
    generation: u64,
    fingerprint: [32]u8,
    refreshed_at_ns: util_time.Nanos,
    clock: Clock,
    servers: []ServerRecord,
    issues: []CatalogIssue,

    pub fn retain(self: *Snapshot) Error!*Snapshot {
        const previous = self.ref_count.fetchAdd(1, .monotonic);
        if (previous == 0 or previous == std.math.maxInt(u32)) {
            _ = self.ref_count.fetchSub(1, .monotonic);
            return error.ResourceLimit;
        }
        return self;
    }

    pub fn release(self: *Snapshot) void {
        const previous = self.ref_count.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous != 1) return;
        const backing = self.backing;
        for (self.servers) |server| server.client.deinit();
        self.arena.deinit();
        backing.destroy(self);
    }

    pub fn findServer(self: *const Snapshot, binding: *const [32]u8) ?*const ServerRecord {
        for (self.servers) |*server|
            if (std.mem.eql(u8, &server.client.binding, binding)) return server;
        return null;
    }

    pub fn now(self: *const Snapshot) util_time.Nanos {
        return self.clock.now();
    }

    pub fn findTool(
        self: *const Snapshot,
        binding: *const [32]u8,
        name: []const u8,
    ) ?struct { server: *const ServerRecord, admitted: *const AdmittedTool } {
        const server = self.findServer(binding) orelse return null;
        for (server.admitted_tools) |*admitted|
            if (std.mem.eql(u8, admitted.canonical.identity.name, name))
                return .{ .server = server, .admitted = admitted };
        return null;
    }

    pub fn describe(
        self: *const Snapshot,
        backing: std.mem.Allocator,
    ) Error!Description {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const a = arena.allocator();
        var tool_count: usize = 0;
        for (self.servers) |server| tool_count = std.math.add(
            usize,
            tool_count,
            server.admitted_tools.len,
        ) catch return error.ResourceLimit;
        const servers = a.alloc(ServerDescription, self.servers.len) catch
            return error.OutOfMemory;
        const tools = a.alloc(ToolDescription, tool_count) catch
            return error.OutOfMemory;
        const issues = a.alloc(IssueDescription, self.issues.len) catch
            return error.OutOfMemory;
        var tool_offset: usize = 0;
        const now_ns = self.now();
        for (self.servers, servers) |server, *description| {
            const remaining_ns = @max(@as(util_time.Nanos, 0), server.expires_at_ns - now_ns);
            description.* = .{
                .server_binding_identity = server.client.binding,
                .namespace = a.dupe(u8, server.namespace) catch
                    return error.OutOfMemory,
                .era = server.client.era,
                .server_fingerprint = server.fingerprint,
                .cache_scope = server.cache_scope,
                .fresh = server.isFreshAt(now_ns),
                .ttl_remaining_ms = @intCast(@divTrunc(remaining_ns, std.time.ns_per_ms)),
                .tool_offset = @intCast(tool_offset),
                .tool_count = @intCast(server.admitted_tools.len),
            };
            const admitted_count = server.admitted_tools.len;
            const destinations = tools[tool_offset..][0..admitted_count];
            for (server.admitted_tools, destinations) |admitted, *target| {
                const tool = admitted.canonical;
                target.* = .{
                    .server_binding_identity = tool.identity.server_binding_identity,
                    .canonical_name = a.dupe(u8, tool.identity.name) catch
                        return error.OutOfMemory,
                    .schema_fingerprint = tool.identity.schema_fingerprint,
                    .permission_binding = tool.identity.permissionBinding(),
                };
            }
            tool_offset += admitted_count;
        }
        for (self.issues, issues) |issue, *description| {
            const parts = issueParts(issue.kind);
            const kind: []const u8 = parts[0];
            const detail: []const u8 = parts[1];
            const owned_tool = if (issue.tool_name) |name|
                a.dupe(u8, name) catch return error.OutOfMemory
            else
                null;
            const owned_kind = a.dupe(u8, kind) catch return error.OutOfMemory;
            const owned_detail = a.dupe(u8, detail) catch return error.OutOfMemory;
            description.* = .{
                .issue_id = deriveIssueId(
                    &issue.server_binding_identity,
                    issue.tool_name,
                    kind,
                    detail,
                ),
                .server_binding_identity = issue.server_binding_identity,
                .tool_name = owned_tool,
                .kind = owned_kind,
                .detail = owned_detail,
            };
        }
        std.debug.assert(tool_offset == tools.len);
        return .{
            .arena = arena,
            .generation = self.generation,
            .fingerprint = self.fingerprint,
            .servers = servers,
            .tools = tools,
            .issues = issues,
        };
    }
};

fn issueParts(kind: IssueKind) struct { []const u8, []const u8 } {
    return switch (kind) {
        .connection => |failure| switch (failure) {
            .diagnostic => |diagnostic| .{ @tagName(diagnostic.code), @tagName(diagnostic.phase) },
            .resource_limit => .{ "server_resource_limit", "" },
            .out_of_memory => .{ "runtime_out_of_memory", "" },
        },
        .tool => |tool_issue| switch (tool_issue) {
            .schema => |schema_issue| .{
                @tagName(schema_issue.code),
                schema_issue.keyword orelse "",
            },
            .task_required_unsupported => .{ "task_required_unsupported", "execution.taskSupport" },
        },
    };
}

const OwnedSpec = struct {
    binding: [32]u8,
    namespace: []const u8,
    connector: runtime.Connector,
    transport: @import("mcp_negotiation.zig").Transport,
    policy: @import("mcp_negotiation.zig").Policy,
    client: @import("mcp_wire.zig").ClientInfo,
    timeout_ms: u32,
    protocol_limits: canonical.Limits,

    fn runtimeConfig(self: OwnedSpec) runtime.Config {
        return .{
            .connector = self.connector,
            .transport = self.transport,
            .policy = self.policy,
            .server_binding_identity = self.binding,
            .client = self.client,
            .timeout_ms = self.timeout_ms,
            .limits = self.protocol_limits,
        };
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    limits: Limits,
    clock: Clock,
    specs: []OwnedSpec,
    refresh_mutex: sync.Mutex = .{},
    current_mutex: sync.Mutex = .{},
    current: ?*Snapshot = null,

    pub fn init(
        allocator: std.mem.Allocator,
        specs: []const ServerSpec,
        limits: Limits,
    ) Error!Manager {
        return initWithClock(allocator, specs, limits, .{});
    }

    pub fn initWithClock(
        allocator: std.mem.Allocator,
        specs: []const ServerSpec,
        limits: Limits,
        clock: Clock,
    ) Error!Manager {
        if (limits.max_servers == 0 or limits.max_namespace_bytes == 0 or
            limits.max_issues == 0 or limits.legacy_ttl_ms == 0 or
            limits.max_ttl_ms == 0 or limits.legacy_ttl_ms > limits.max_ttl_ms or
            specs.len > limits.max_servers)
            return error.InvalidConfig;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator().alloc(OwnedSpec, specs.len) catch
            return error.OutOfMemory;
        const effective_namespace_limit = @min(
            limits.max_namespace_bytes,
            MAX_NAMESPACE_BYTES,
        );
        for (specs, owned, 0..) |spec, *destination, index| {
            if (allZero(&spec.binding) or
                !validNamespace(spec.namespace, effective_namespace_limit) or
                spec.timeout_ms == 0 or
                spec.protocol_limits.max_tools > (canonical.Limits{}).max_tools)
                return error.InvalidConfig;
            spec.protocol_limits.validate() catch return error.InvalidConfig;
            for (specs[0..index]) |previous| {
                if (std.mem.eql(u8, &previous.binding, &spec.binding) or
                    std.mem.eql(u8, previous.namespace, spec.namespace))
                    return error.InvalidConfig;
            }
            const namespace = arena.allocator().dupe(u8, spec.namespace) catch
                return error.OutOfMemory;
            const client_name = arena.allocator().dupe(u8, spec.client.name) catch
                return error.OutOfMemory;
            const client_version = arena.allocator().dupe(u8, spec.client.version) catch
                return error.OutOfMemory;
            destination.* = .{
                .binding = spec.binding,
                .namespace = namespace,
                .connector = spec.connector,
                .transport = spec.transport,
                .policy = spec.policy,
                .client = .{ .name = client_name, .version = client_version },
                .timeout_ms = spec.timeout_ms,
                .protocol_limits = spec.protocol_limits,
            };
        }
        return .{
            .allocator = allocator,
            .arena = arena,
            .limits = limits,
            .clock = clock,
            .specs = owned,
        };
    }

    pub fn deinit(self: *Manager) void {
        if (self.current) |snapshot| snapshot.release();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Publish a fresh immutable snapshot. Individual server failures are
    /// catalog issues and do not prevent other servers (or Conversation) from
    /// being usable. Only Runtime-local allocation/global catalog failures
    /// abort publication, leaving the old generation untouched.
    pub fn refresh(self: *Manager) Error!u64 {
        self.refresh_mutex.lock();
        defer self.refresh_mutex.unlock();
        self.current_mutex.lock();
        const generation = if (self.current) |snapshot|
            std.math.add(u64, snapshot.generation, 1) catch {
                self.current_mutex.unlock();
                return error.ResourceLimit;
            }
        else
            1;
        self.current_mutex.unlock();

        const replacement = try self.buildSnapshot(generation);
        self.current_mutex.lock();
        const previous = self.current;
        self.current = replacement;
        self.current_mutex.unlock();
        if (previous) |snapshot| snapshot.release();
        return generation;
    }

    pub fn retainCurrent(self: *Manager) Error!*Snapshot {
        self.current_mutex.lock();
        defer self.current_mutex.unlock();
        const snapshot = self.current orelse return error.NotRefreshed;
        return snapshot.retain();
    }

    pub fn describeCurrent(
        self: *Manager,
        backing: std.mem.Allocator,
    ) Error!Description {
        const snapshot = try self.retainCurrent();
        defer snapshot.release();
        return snapshot.describe(backing);
    }

    fn buildSnapshot(self: *Manager, generation: u64) Error!*Snapshot {
        const snapshot = self.allocator.create(Snapshot) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(snapshot);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var servers: std.ArrayList(ServerRecord) = .empty;
        defer servers.deinit(a);
        var issues: std.ArrayList(CatalogIssue) = .empty;
        defer issues.deinit(a);
        errdefer for (servers.items) |server| server.client.deinit();
        for (self.specs) |spec| {
            const connected = runtime.connectServer(self.allocator, spec.runtimeConfig());
            const client = switch (connected) {
                .client => |value| value,
                .failed => |failure| {
                    switch (failure) {
                        .out_of_memory => return error.OutOfMemory,
                        .resource_limit, .diagnostic => {},
                    }
                    try appendIssue(&issues, a, self.limits, .{
                        .server_binding_identity = spec.binding,
                        .kind = .{ .connection = failure },
                    });
                    continue;
                },
            };
            errdefer client.deinit();
            const namespace = a.dupe(u8, spec.namespace) catch return error.OutOfMemory;
            var admitted_tools: std.ArrayList(AdmittedTool) = .empty;
            defer admitted_tools.deinit(a);
            for (client.catalog.tools) |*tool| {
                const model_name = deriveModelName(
                    a,
                    namespace,
                    &spec.binding,
                    tool.identity.name,
                ) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.InvalidSelection => error.InvalidConfig,
                    error.ResourceLimit => error.ResourceLimit,
                };
                const inspected = try inspectTool(a, self.allocator, model_name, tool);
                switch (inspected) {
                    .admitted => |admitted| admitted_tools.append(a, admitted) catch
                        return error.OutOfMemory,
                    .unavailable => |issue| try appendIssue(&issues, a, self.limits, .{
                        .server_binding_identity = spec.binding,
                        .tool_name = tool.identity.name,
                        .kind = .{ .tool = issue },
                    }),
                }
            }
            const owned_admitted = admitted_tools.toOwnedSlice(a) catch
                return error.OutOfMemory;
            servers.append(a, .{
                .namespace = namespace,
                .client = client,
                .fingerprint = serverFingerprint(self.allocator, client, owned_admitted) catch
                    return error.OutOfMemory,
                .expires_at_ns = try expiresAt(
                    // Protocol TTL starts when this server's complete
                    // discovery/list result has been received, not when the
                    // multi-server refresh began.
                    self.clock.now(),
                    client.catalog.cache.ttl_ms,
                    self.limits,
                ),
                .cache_scope = client.catalog.cache.scope,
                .admitted_tools = owned_admitted,
            }) catch return error.OutOfMemory;
        }
        sortServers(servers.items);
        const owned_servers = servers.toOwnedSlice(a) catch return error.OutOfMemory;
        const owned_issues = issues.toOwnedSlice(a) catch return error.OutOfMemory;
        snapshot.* = .{
            .backing = self.allocator,
            .arena = arena,
            .generation = generation,
            .fingerprint = snapshotFingerprint(owned_servers),
            .refreshed_at_ns = self.clock.now(),
            .clock = self.clock,
            .servers = owned_servers,
            .issues = owned_issues,
        };
        return snapshot;
    }
};

const Inspection = union(enum) {
    admitted: AdmittedTool,
    unavailable: ToolIssue,
};

/// Perform the one authoritative executable admission pass. The temporary
/// PreparedTool proves the complete schema can be parsed and projected under
/// the declared profile; only compact diagnostics survive in the Snapshot.
fn inspectTool(
    snapshot_allocator: std.mem.Allocator,
    scratch_backing: std.mem.Allocator,
    model_name: []const u8,
    tool: *const canonical.Tool,
) error{OutOfMemory}!Inspection {
    if (tool.execution_mode == .task_required)
        return .{ .unavailable = .task_required_unsupported };
    var admission = try schema.prepareTool(scratch_backing, model_name, tool, .{});
    return switch (admission) {
        .unavailable => |issue| .{ .unavailable = .{ .schema = issue } },
        .available => |*prepared| blk: {
            defer prepared.deinit();
            const diagnostics = snapshot_allocator.dupe(
                schema.ProjectionDiagnostic,
                prepared.diagnostics,
            ) catch return error.OutOfMemory;
            break :blk .{ .admitted = .{
                .canonical = tool,
                .model_name = model_name,
                .diagnostics = diagnostics,
            } };
        },
    };
}

/// Rebuild the provider projection only for a Session-selected admitted tool.
/// A non-OOM disagreement means code or immutable data violated Catalog's
/// admission invariant; it is never downgraded into a second admission pass.
pub fn materializeAdmittedTool(
    backing: std.mem.Allocator,
    admitted: *const AdmittedTool,
) MaterializeError!schema.PreparedTool {
    const admission = schema.prepareTool(
        backing,
        admitted.model_name,
        admitted.canonical,
        .{},
    ) catch return error.OutOfMemory;
    return switch (admission) {
        .unavailable => error.AdmissionInvariantViolation,
        .available => |prepared| blk: {
            if (!std.mem.eql(
                schema.ProjectionDiagnostic,
                prepared.diagnostics,
                admitted.diagnostics,
            )) {
                var cleanup = prepared;
                cleanup.deinit();
                return error.AdmissionInvariantViolation;
            }
            break :blk prepared;
        },
    };
}

pub fn deriveModelName(
    allocator: std.mem.Allocator,
    namespace: []const u8,
    binding: *const [32]u8,
    tool_name: []const u8,
) error{ OutOfMemory, InvalidSelection, ResourceLimit }![]u8 {
    if (namespace.len == 0 or namespace.len > MAX_NAMESPACE_BYTES)
        return error.InvalidSelection;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // Public model names remain stable across the Revision 7 era addition.
    hasher.update("agentcore-r6-mcp-model-tool\x00");
    hasher.update(binding);
    hasher.update(tool_name);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const prefix = "mcp__";
    const middle = "__";
    const size = prefix.len + namespace.len + middle.len + 32;
    if (size > MAX_MODEL_TOOL_NAME_BYTES) return error.ResourceLimit;
    const result = allocator.alloc(u8, size) catch return error.OutOfMemory;
    @memcpy(result[0..prefix.len], prefix);
    @memcpy(result[prefix.len .. prefix.len + namespace.len], namespace);
    const middle_start = prefix.len + namespace.len;
    @memcpy(result[middle_start .. middle_start + middle.len], middle);
    const hex = "0123456789abcdef";
    for (digest[0..16], 0..) |byte, index| {
        result[middle_start + middle.len + index * 2] = hex[byte >> 4];
        result[middle_start + middle.len + index * 2 + 1] = hex[byte & 0x0f];
    }
    return result;
}

fn expiresAt(
    refreshed_at_ns: util_time.Nanos,
    protocol_ttl_ms: ?f64,
    limits: Limits,
) Error!util_time.Nanos {
    const requested_ms = protocol_ttl_ms orelse @as(f64, @floatFromInt(limits.legacy_ttl_ms));
    if (!std.math.isFinite(requested_ms) or requested_ms < 0)
        return error.InvalidConfig;
    const bounded_ms = @min(requested_ms, @as(f64, @floatFromInt(limits.max_ttl_ms)));
    const duration_ns: util_time.Nanos = @intFromFloat(@ceil(
        bounded_ms * @as(f64, @floatFromInt(std.time.ns_per_ms)),
    ));
    return std.math.add(util_time.Nanos, refreshed_at_ns, duration_ns) catch
        error.ResourceLimit;
}

fn appendIssue(
    issues: *std.ArrayList(CatalogIssue),
    allocator: std.mem.Allocator,
    limits: Limits,
    issue: CatalogIssue,
) Error!void {
    if (issues.items.len == limits.max_issues) return error.ResourceLimit;
    issues.append(allocator, issue) catch return error.OutOfMemory;
}

fn deriveIssueId(
    binding: *const [32]u8,
    tool_name: ?[]const u8,
    kind: []const u8,
    detail: []const u8,
) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // Stable identity domain; changing the ABI revision is not an issue key.
    hasher.update("agentcore-r6-mcp-catalog-issue\x00");
    hasher.update(binding);
    hashBytes(&hasher, tool_name orelse "");
    hashBytes(&hasher, kind);
    hashBytes(&hasher, detail);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    if (std.mem.allEqual(u8, &result, 0)) result[0] = 1;
    return result;
}

fn validNamespace(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes or
        !std.ascii.isAlphabetic(value[0])) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn serverFingerprint(
    allocator: std.mem.Allocator,
    client: *const runtime.Client,
    admitted_tools: []const AdmittedTool,
) error{OutOfMemory}![32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // Stable domain; admitted contents, not the ABI revision, define change.
    hasher.update("agentcore-r6-mcp-server-catalog\x00");
    hasher.update(&client.binding);
    hasher.update(client.era.version());
    const digests = allocator.alloc([32]u8, admitted_tools.len) catch
        return error.OutOfMemory;
    defer allocator.free(digests);
    for (admitted_tools, digests) |admitted, *digest| {
        const tool = admitted.canonical;
        var tool_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hashBytes(&tool_hasher, tool.identity.name);
        tool_hasher.update(&tool.identity.schema_fingerprint);
        tool_hasher.final(digest);
    }
    std.mem.sort([32]u8, digests, {}, digestLessThan);
    for (digests) |digest| hasher.update(&digest);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn snapshotFingerprint(servers: []const ServerRecord) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // Stable domain retained for unchanged Runtime catalog generations.
    hasher.update("agentcore-r6-mcp-runtime-catalog\x00");
    for (servers) |server| {
        hasher.update(&server.client.binding);
        hasher.update(&server.fingerprint);
    }
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn sortServers(servers: []ServerRecord) void {
    std.mem.sort(ServerRecord, servers, {}, struct {
        fn lessThan(_: void, left: ServerRecord, right: ServerRecord) bool {
            return std.mem.order(u8, &left.client.binding, &right.client.binding) == .lt;
        }
    }.lessThan);
}

fn digestLessThan(_: void, left: [32]u8, right: [32]u8) bool {
    return std.mem.order(u8, &left, &right) == .lt;
}

fn hashBytes(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .little);
    hasher.update(&length);
    hasher.update(bytes);
}

fn allZero(value: []const u8) bool {
    for (value) |byte| if (byte != 0) return false;
    return true;
}

const Fake = struct {
    opens: u8 = 0,
    closes: u8 = 0,
    ttl_ms: u64 = 1000,
    tool_count: u8 = 1,
    paginate: bool = false,
    required_task: bool = false,
    fail_open_oom: bool = false,

    const Conn = struct { owner: *Fake };

    fn connector(self: *Fake) runtime.Connector {
        return .{ .ctx = self, .open_fn = open };
    }

    fn open(raw: *anyopaque, _: runtime.ConnectionPurpose, _: canonical.Era) anyerror!runtime.OpenOutcome {
        const self: *Fake = @ptrCast(@alignCast(raw));
        if (self.fail_open_oom) return error.OutOfMemory;
        const connection = try std.heap.c_allocator.create(Conn);
        connection.* = .{ .owner = self };
        self.opens += 1;
        return .{ .connection = .{
            .ctx = connection,
            .request_fn = request,
            .notify_fn = notify,
            .close_fn = close,
        } };
    }

    fn request(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        encoded: []const u8,
        _: u32,
        _: runtime.Cancellation,
    ) anyerror!runtime.ExchangeOutcome {
        const connection: *Conn = @ptrCast(@alignCast(raw));
        const id = requestId(encoded) orelse return .server_error;
        const response = if (std.mem.indexOf(u8, encoded, "server/discover") != null)
            try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{{}},\"ttlMs\":{d},\"cacheScope\":\"private\"}}}}",
                .{ id, connection.owner.ttl_ms },
            )
        else if (std.mem.indexOf(u8, encoded, "tools/list") != null)
            if (connection.owner.paginate)
                try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\"}}}}],\"nextCursor\":\"again\",\"ttlMs\":{d},\"cacheScope\":\"private\"}}}}",
                    .{ id, connection.owner.ttl_ms },
                )
            else if (connection.owner.required_task)
                try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"tasked\",\"inputSchema\":{{\"type\":\"object\"}},\"execution\":{{\"taskSupport\":\"required\"}}}}],\"ttlMs\":{d},\"cacheScope\":\"private\"}}}}",
                    .{ id, connection.owner.ttl_ms },
                )
            else if (connection.owner.tool_count == 1)
                try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"city\":{{\"type\":\"string\"}}}}}}}}],\"ttlMs\":{d},\"cacheScope\":\"private\"}}}}",
                    .{ id, connection.owner.ttl_ms },
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\"}}}},{{\"name\":\"alerts\",\"inputSchema\":{{\"type\":\"object\"}}}}],\"ttlMs\":{d},\"cacheScope\":\"private\"}}}}",
                    .{ id, connection.owner.ttl_ms },
                )
        else
            return .server_error;
        return .{ .response = response };
    }

    fn notify(_: *anyopaque, _: []const u8, _: u32, _: runtime.Cancellation) anyerror!void {}

    fn close(raw: *anyopaque) void {
        const connection: *Conn = @ptrCast(@alignCast(raw));
        connection.owner.closes += 1;
        std.heap.c_allocator.destroy(connection);
    }

    fn requestId(encoded: []const u8) ?u64 {
        const marker = "\"id\":";
        const start = (std.mem.indexOf(u8, encoded, marker) orelse return null) + marker.len;
        var end = start;
        while (end < encoded.len and std.ascii.isDigit(encoded[end])) : (end += 1) {}
        return std.fmt.parseInt(u64, encoded[start..end], 10) catch null;
    }
};

const TestClock = struct {
    now_ns: util_time.Nanos,

    fn read(raw: ?*const anyopaque) util_time.Nanos {
        const self: *const TestClock = @ptrCast(@alignCast(raw.?));
        return self.now_ns;
    }

    fn clock(self: *const TestClock) Clock {
        return .{ .ctx = self, .now_fn = read };
    }
};

test "catalog refresh publishes generations while retained Run snapshot remains live" {
    var fake = Fake{};
    const specs = [_]ServerSpec{.{
        .binding = [_]u8{7} ** 32,
        .namespace = "weather",
        .connector = fake.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var manager = try Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    try std.testing.expectEqual(@as(u64, 1), try manager.refresh());
    const first = try manager.retainCurrent();
    defer first.release();
    try std.testing.expectEqual(@as(usize, 1), first.servers.len);
    try std.testing.expectEqual(@as(u64, 2), try manager.refresh());
    const second = try manager.retainCurrent();
    defer second.release();
    try std.testing.expectEqual(@as(u64, 1), first.generation);
    try std.testing.expectEqual(@as(u64, 2), second.generation);
    try std.testing.expect(first.findTool(&specs[0].binding, "weather") != null);
    var description = try manager.describeCurrent(std.testing.allocator);
    defer description.deinit();
    try std.testing.expectEqual(@as(u64, 2), description.generation);
    try std.testing.expectEqual(@as(usize, 1), description.servers.len);
    try std.testing.expectEqual(@as(usize, 1), description.tools.len);
    try std.testing.expectEqualStrings("weather", description.servers[0].namespace);
    try std.testing.expectEqualStrings("weather", description.tools[0].canonical_name);
    try std.testing.expectEqualSlices(
        u8,
        &specs[0].binding,
        &description.tools[0].server_binding_identity,
    );
    try std.testing.expect(!std.mem.allEqual(
        u8,
        &description.tools[0].permission_binding,
        0,
    ));
    try std.testing.expectEqual(@as(u8, 4), fake.opens);
    // Each disposable probe and the Manager's released generation-1 owner are
    // closed; the explicit `first` retain keeps its actual connection alive.
    try std.testing.expectEqual(@as(u8, 2), fake.closes);
}

test "catalog description uses an exact destination window for every server" {
    var first = Fake{};
    var second = Fake{};
    const specs = [_]ServerSpec{
        .{
            .binding = [_]u8{0x17} ** 32,
            .namespace = "first",
            .connector = first.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
        .{
            .binding = [_]u8{0x18} ** 32,
            .namespace = "second",
            .connector = second.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
    };
    var manager = try Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    _ = try manager.refresh();

    var description = try manager.describeCurrent(std.testing.allocator);
    defer description.deinit();
    try std.testing.expectEqual(@as(usize, 2), description.servers.len);
    try std.testing.expectEqual(@as(usize, 2), description.tools.len);
    for (description.servers, 0..) |server, index| {
        try std.testing.expectEqual(@as(u64, 1), server.tool_count);
        try std.testing.expectEqual(@as(u64, @intCast(index)), server.tool_offset);
        try std.testing.expectEqualSlices(
            u8,
            &server.server_binding_identity,
            &description.tools[index].server_binding_identity,
        );
    }
}

test "catalog freshness is clocked bounded and visible through description" {
    var fake = Fake{ .ttl_ms = 1000 };
    var clock = TestClock{ .now_ns = 10 * std.time.ns_per_s };
    const specs = [_]ServerSpec{.{
        .binding = [_]u8{0x37} ** 32,
        .namespace = "weather",
        .connector = fake.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var manager = try Manager.initWithClock(
        std.testing.allocator,
        &specs,
        .{},
        clock.clock(),
    );
    defer manager.deinit();
    _ = try manager.refresh();

    var fresh = try manager.describeCurrent(std.testing.allocator);
    defer fresh.deinit();
    try std.testing.expect(fresh.servers[0].fresh);
    try std.testing.expectEqual(canonical.CacheScope.private, fresh.servers[0].cache_scope);
    try std.testing.expectEqual(@as(u64, 1000), fresh.servers[0].ttl_remaining_ms);

    clock.now_ns += 1001 * std.time.ns_per_ms;
    var expired = try manager.describeCurrent(std.testing.allocator);
    defer expired.deinit();
    try std.testing.expect(!expired.servers[0].fresh);
    try std.testing.expectEqual(@as(u64, 0), expired.servers[0].ttl_remaining_ms);
}

test "one server resource limit does not suppress unrelated catalog entries" {
    var over_limit = Fake{ .paginate = true };
    var healthy = Fake{};
    const specs = [_]ServerSpec{
        .{
            .binding = [_]u8{0x41} ** 32,
            .namespace = "oversized",
            .connector = over_limit.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
            .protocol_limits = .{ .max_tools = 1 },
        },
        .{
            .binding = [_]u8{0x42} ** 32,
            .namespace = "healthy",
            .connector = healthy.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
    };
    var manager = try Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    try std.testing.expectEqual(@as(u64, 1), try manager.refresh());
    var description = try manager.describeCurrent(std.testing.allocator);
    defer description.deinit();
    try std.testing.expectEqual(@as(usize, 1), description.servers.len);
    try std.testing.expectEqualStrings("healthy", description.servers[0].namespace);
    try std.testing.expectEqual(@as(usize, 1), description.tools.len);
    try std.testing.expectEqual(@as(usize, 1), description.issues.len);
    try std.testing.expectEqualStrings("server_resource_limit", description.issues[0].kind);
}

test "Runtime-local allocation failure preserves the previous Snapshot" {
    var fake = Fake{};
    const binding = [_]u8{0x43} ** 32;
    const specs = [_]ServerSpec{.{
        .binding = binding,
        .namespace = "stable",
        .connector = fake.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var manager = try Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    try std.testing.expectEqual(@as(u64, 1), try manager.refresh());
    fake.fail_open_oom = true;
    try std.testing.expectError(error.OutOfMemory, manager.refresh());
    const retained = try manager.retainCurrent();
    defer retained.release();
    try std.testing.expectEqual(@as(u64, 1), retained.generation);
    try std.testing.expect(retained.findTool(&binding, "weather") != null);
}

test "catalog TTL policy supplies legacy default and caps modern duration" {
    const limits = Limits{ .legacy_ttl_ms = 30_000, .max_ttl_ms = 300_000 };
    try std.testing.expectEqual(
        @as(util_time.Nanos, 30_000 * std.time.ns_per_ms),
        try expiresAt(0, null, limits),
    );
    try std.testing.expectEqual(
        @as(util_time.Nanos, 300_000 * std.time.ns_per_ms),
        try expiresAt(0, 900_000, limits),
    );
    try std.testing.expectEqual(
        @as(util_time.Nanos, 0),
        try expiresAt(0, 0, limits),
    );
}

test "catalog description resolves stable issue identity without live handles" {
    const Failing = struct {
        fn open(
            _: *anyopaque,
            _: runtime.ConnectionPurpose,
            _: canonical.Era,
        ) anyerror!runtime.OpenOutcome {
            return .auth_error;
        }
    };
    var marker: u8 = 0;
    const binding = [_]u8{9} ** 32;
    const specs = [_]ServerSpec{.{
        .binding = binding,
        .namespace = "private",
        .connector = .{ .ctx = &marker, .open_fn = Failing.open },
        .transport = .streamable_http,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var manager = try Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    try std.testing.expectEqual(@as(u64, 1), try manager.refresh());

    var first = try manager.describeCurrent(std.testing.allocator);
    defer first.deinit();
    var second = try manager.describeCurrent(std.testing.allocator);
    defer second.deinit();
    try std.testing.expectEqual(@as(usize, 0), first.servers.len);
    try std.testing.expectEqual(@as(usize, 1), first.issues.len);
    try std.testing.expectEqualSlices(
        u8,
        &binding,
        &first.issues[0].server_binding_identity,
    );
    try std.testing.expect(first.issues[0].kind.len != 0);
    try std.testing.expect(!std.mem.allEqual(u8, &first.issues[0].issue_id, 0));
    try std.testing.expectEqualSlices(
        u8,
        &first.issues[0].issue_id,
        &second.issues[0].issue_id,
    );
}

test "Catalog is the sole admission authority for schema and required-task tools" {
    const fixture = @import("mcp_test_support.zig");
    var invalid_schema = fixture.Server{
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"x\":{\"$ref\":\"#/$defs/x\"}}}",
    };
    var required_task = Fake{ .required_task = true };
    const invalid_binding = [_]u8{0x51} ** 32;
    const required_binding = [_]u8{0x52} ** 32;
    const specs = [_]ServerSpec{
        .{
            .binding = invalid_binding,
            .namespace = "invalid",
            .connector = invalid_schema.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
        .{
            .binding = required_binding,
            .namespace = "tasked",
            .connector = required_task.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
    };
    var manager = try Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    _ = try manager.refresh();
    const snapshot = try manager.retainCurrent();
    defer snapshot.release();
    try std.testing.expect(snapshot.findTool(&invalid_binding, "weather") == null);
    const required_server = snapshot.findServer(&required_binding) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        canonical.ExecutionMode.task_required,
        required_server.client.catalog.tools[0].execution_mode,
    );
    try std.testing.expect(snapshot.findTool(&required_binding, "tasked") == null);

    var description = try snapshot.describe(std.testing.allocator);
    defer description.deinit();
    try std.testing.expectEqual(@as(usize, 0), description.tools.len);
    try std.testing.expectEqual(@as(usize, 2), description.issues.len);
    var saw_schema = false;
    var saw_task = false;
    for (description.issues) |issue| {
        if (std.mem.eql(u8, issue.kind, "unsupported_reference")) saw_schema = true;
        if (std.mem.eql(u8, issue.kind, "task_required_unsupported")) saw_task = true;
    }
    try std.testing.expect(saw_schema);
    try std.testing.expect(saw_task);
}

test "catalog configuration rejects duplicate identity and unsafe namespace" {
    var fake = Fake{};
    const duplicate = [_]ServerSpec{
        .{ .binding = [_]u8{1} ** 32, .namespace = "one", .connector = fake.connector(), .transport = .stdio, .client = .{ .name = "x", .version = "1" } },
        .{ .binding = [_]u8{1} ** 32, .namespace = "two", .connector = fake.connector(), .transport = .stdio, .client = .{ .name = "x", .version = "1" } },
    };
    try std.testing.expectError(error.InvalidConfig, Manager.init(std.testing.allocator, &duplicate, .{}));
    const unsafe = [_]ServerSpec{.{
        .binding = [_]u8{2} ** 32,
        .namespace = "bad-name",
        .connector = fake.connector(),
        .transport = .stdio,
        .client = .{ .name = "x", .version = "1" },
    }};
    try std.testing.expectError(error.InvalidConfig, Manager.init(std.testing.allocator, &unsafe, .{}));

    var boundary_fake = Fake{};
    const boundary_namespace = "abcdefghijklmnopqrstuvwx";
    try std.testing.expectEqual(MAX_NAMESPACE_BYTES, boundary_namespace.len);
    const boundary = [_]ServerSpec{.{
        .binding = [_]u8{4} ** 32,
        .namespace = boundary_namespace,
        .connector = boundary_fake.connector(),
        .transport = .stdio,
        .client = .{ .name = "x", .version = "1" },
    }};
    var boundary_manager = try Manager.init(
        std.testing.allocator,
        &boundary,
        .{ .max_namespace_bytes = MAX_NAMESPACE_BYTES + 8 },
    );
    defer boundary_manager.deinit();
    try std.testing.expectEqual(@as(u64, 1), try boundary_manager.refresh());

    const oversized_namespace = "abcdefghijklmnopqrstuvwxy";
    try std.testing.expectEqual(MAX_NAMESPACE_BYTES + 1, oversized_namespace.len);
    const oversized = [_]ServerSpec{.{
        .binding = [_]u8{3} ** 32,
        .namespace = oversized_namespace,
        .connector = fake.connector(),
        .transport = .stdio,
        .client = .{ .name = "x", .version = "1" },
    }};
    try std.testing.expectError(
        error.InvalidConfig,
        Manager.init(
            std.testing.allocator,
            &oversized,
            .{ .max_namespace_bytes = MAX_NAMESPACE_BYTES + 8 },
        ),
    );
    try std.testing.expectEqual(@as(u8, 0), fake.opens);
}
