//! Immutable Runtime MCP catalog generations for AgentCore Revision 6.
//!
//! A refresh builds a complete candidate snapshot off to the side and only
//! then publishes one new generation. Sessions and Runs retain old snapshots,
//! so refresh never mutates authority already admitted to an active Run.

const std = @import("std");
const sync = @import("platform").sync;
const canonical = @import("mcp_canonical.zig");
const runtime = @import("mcp_runtime.zig");
const schema = @import("mcp_schema.zig");

pub const Limits = struct {
    max_servers: usize = 64,
    max_namespace_bytes: usize = 24,
    max_issues: usize = 4096,
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

pub const IssueKind = union(enum) {
    connection: runtime.ConnectFailure,
    schema: schema.Issue,
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
};

pub const Snapshot = struct {
    backing: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    ref_count: std.atomic.Value(u32) = .init(1),
    generation: u64,
    fingerprint: [32]u8,
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

    pub fn findTool(
        self: *const Snapshot,
        binding: *const [32]u8,
        name: []const u8,
    ) ?struct { server: *const ServerRecord, tool: *const canonical.Tool } {
        const server = self.findServer(binding) orelse return null;
        for (server.client.catalog.tools) |*tool|
            if (std.mem.eql(u8, tool.identity.name, name))
                return .{ .server = server, .tool = tool };
        return null;
    }
};

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
    specs: []OwnedSpec,
    refresh_mutex: sync.Mutex = .{},
    current_mutex: sync.Mutex = .{},
    current: ?*Snapshot = null,

    pub fn init(
        allocator: std.mem.Allocator,
        specs: []const ServerSpec,
        limits: Limits,
    ) Error!Manager {
        if (limits.max_servers == 0 or limits.max_namespace_bytes == 0 or
            limits.max_issues == 0 or specs.len > limits.max_servers)
            return error.InvalidConfig;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator().alloc(OwnedSpec, specs.len) catch
            return error.OutOfMemory;
        for (specs, owned, 0..) |spec, *destination, index| {
            if (allZero(&spec.binding) or
                !validNamespace(spec.namespace, limits.max_namespace_bytes) or
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
    /// being usable. Allocation/resource failures abort publication, leaving
    /// the old generation untouched.
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
                        .resource_limit => return error.ResourceLimit,
                        .diagnostic => {},
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
            for (client.catalog.tools) |*tool| {
                var admission = schema.prepareTool(a, "mcp__catalog_probe", tool, .{}) catch
                    return error.OutOfMemory;
                switch (admission) {
                    .available => |*prepared| prepared.deinit(),
                    .unavailable => |issue| try appendIssue(&issues, a, self.limits, .{
                        .server_binding_identity = spec.binding,
                        .tool_name = tool.identity.name,
                        .kind = .{ .schema = issue },
                    }),
                }
            }
            servers.append(a, .{
                .namespace = namespace,
                .client = client,
                .fingerprint = serverFingerprint(client),
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
            .servers = owned_servers,
            .issues = owned_issues,
        };
        return snapshot;
    }
};

fn appendIssue(
    issues: *std.ArrayList(CatalogIssue),
    allocator: std.mem.Allocator,
    limits: Limits,
    issue: CatalogIssue,
) Error!void {
    if (issues.items.len == limits.max_issues) return error.ResourceLimit;
    issues.append(allocator, issue) catch return error.OutOfMemory;
}

fn validNamespace(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes or
        !std.ascii.isAlphabetic(value[0])) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn serverFingerprint(client: *const runtime.Client) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("agentcore-r6-mcp-server-catalog\x00");
    hasher.update(&client.binding);
    hasher.update(client.era.version());
    var digests: [1024][32]u8 = undefined;
    std.debug.assert(client.catalog.tools.len <= digests.len);
    for (client.catalog.tools, digests[0..client.catalog.tools.len]) |tool, *digest| {
        var tool_hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hashBytes(&tool_hasher, tool.identity.name);
        tool_hasher.update(&tool.identity.schema_fingerprint);
        tool_hasher.final(digest);
    }
    std.mem.sort([32]u8, digests[0..client.catalog.tools.len], {}, digestLessThan);
    for (digests[0..client.catalog.tools.len]) |digest| hasher.update(&digest);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn snapshotFingerprint(servers: []const ServerRecord) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
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

    const Conn = struct { owner: *Fake };

    fn connector(self: *Fake) runtime.Connector {
        return .{ .ctx = self, .open_fn = open };
    }

    fn open(raw: *anyopaque, _: runtime.ConnectionPurpose, _: canonical.Era) anyerror!runtime.OpenOutcome {
        const self: *Fake = @ptrCast(@alignCast(raw));
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
        _ = raw;
        const id = requestId(encoded) orelse return .server_error;
        const response = if (std.mem.indexOf(u8, encoded, "server/discover") != null)
            try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{{}},\"ttlMs\":1000,\"cacheScope\":\"private\"}}}}",
                .{id},
            )
        else if (std.mem.indexOf(u8, encoded, "tools/list") != null)
            try std.fmt.allocPrint(
                allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"weather\",\"inputSchema\":{{\"type\":\"object\",\"properties\":{{\"city\":{{\"type\":\"string\"}}}}}}}}],\"ttlMs\":1000,\"cacheScope\":\"private\"}}}}",
                .{id},
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
    try std.testing.expectEqual(@as(u8, 4), fake.opens);
    // Each disposable probe and the Manager's released generation-1 owner are
    // closed; the explicit `first` retain keeps its actual connection alive.
    try std.testing.expectEqual(@as(u8, 2), fake.closes);
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
}
