//! Immutable Runtime MCP catalog generations for AgentCore Revision 7.
//!
//! A refresh builds a complete candidate snapshot off to the side and only
//! then publishes one new generation. Sessions and Runs retain old snapshots,
//! so refresh never mutates authority already admitted to an active Run.

const std = @import("std");
const sync = @import("platform").sync;
const canonical = @import("mcp_canonical.zig");
const runtime = @import("mcp_runtime.zig");
const instance_pool = @import("mcp_instance_pool.zig");
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
    configuration_fingerprint: [32]u8 = [_]u8{0} ** 32,
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
pub const ControlError = Error || error{ReentrantControlCall};

const BuildError = Error || error{CandidateRejected};

pub const ApplyDisposition = enum { applied, superseded, rejected };
pub const Convergence = enum { converged, rejected };

pub const ApplyReport = struct {
    disposition: ApplyDisposition,
    desired_revision: u64,
    active_revision: u64,
    catalog_generation: u64,
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
    server_binding_identity: [32]u8,
    instance_id: instance_pool.InstanceId,
    era: canonical.Era,
    fingerprint: [32]u8,
    expires_at_ns: util_time.Nanos,
    cache_scope: canonical.CacheScope,
    admitted_tools: []AdmittedTool,

    pub fn isFreshAt(self: ServerRecord, now_ns: util_time.Nanos) bool {
        return now_ns < self.expires_at_ns;
    }
};

pub const MAX_MODEL_TOOL_NAME_BYTES: usize = 64;

/// A Snapshot stores immutable canonical Tool identity and provider alias.
/// Provider projection trees are materialized only for tools selected into a
/// Run View.
pub const AdmittedTool = struct {
    canonical: canonical.Tool,
    model_name: []const u8,
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
    desired_revision: u64,
    active_revision: u64,
    convergence: Convergence,
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
    instances: *instance_pool.Pool,
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
        for (self.servers) |server| self.instances.releaseId(server.instance_id);
        self.arena.deinit();
        backing.destroy(self);
    }

    pub fn findServer(self: *const Snapshot, binding: *const [32]u8) ?*const ServerRecord {
        for (self.servers) |*server|
            if (std.mem.eql(u8, &server.server_binding_identity, binding)) return server;
        return null;
    }

    pub fn retainInstance(
        self: *const Snapshot,
        id: instance_pool.InstanceId,
    ) instance_pool.Error!instance_pool.Lease {
        return self.instances.retain(id);
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
                .server_binding_identity = server.server_binding_identity,
                .namespace = a.dupe(u8, server.namespace) catch
                    return error.OutOfMemory,
                .era = server.era,
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
            .desired_revision = 0,
            .active_revision = 0,
            .convergence = .converged,
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
    configuration_fingerprint: [32]u8,
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

fn ownSpecs(
    allocator: std.mem.Allocator,
    specs: []const ServerSpec,
    limits: Limits,
) Error![]OwnedSpec {
    if (specs.len > limits.max_servers) return error.InvalidConfig;
    const owned = allocator.alloc(OwnedSpec, specs.len) catch
        return error.OutOfMemory;
    var initialized: usize = 0;
    errdefer for (owned[0..initialized]) |spec| spec.connector.release();
    const namespace_limit = @min(limits.max_namespace_bytes, MAX_NAMESPACE_BYTES);
    for (specs, owned, 0..) |spec, *destination, index| {
        if (allZero(&spec.binding) or
            !validNamespace(spec.namespace, namespace_limit) or
            spec.timeout_ms == 0 or
            spec.protocol_limits.max_tools > (canonical.Limits{}).max_tools)
            return error.InvalidConfig;
        spec.protocol_limits.validate() catch return error.InvalidConfig;
        for (specs[0..index]) |previous| {
            if (std.mem.eql(u8, &previous.binding, &spec.binding) or
                std.mem.eql(u8, previous.namespace, spec.namespace))
                return error.InvalidConfig;
        }
        destination.* = .{
            .binding = spec.binding,
            .namespace = allocator.dupe(u8, spec.namespace) catch
                return error.OutOfMemory,
            .configuration_fingerprint = spec.configuration_fingerprint,
            .connector = spec.connector,
            .transport = spec.transport,
            .policy = spec.policy,
            .client = .{
                .name = allocator.dupe(u8, spec.client.name) catch
                    return error.OutOfMemory,
                .version = allocator.dupe(u8, spec.client.version) catch
                    return error.OutOfMemory,
            },
            .timeout_ms = spec.timeout_ms,
            .protocol_limits = spec.protocol_limits,
        };
        spec.connector.retain() catch return error.ResourceLimit;
        initialized += 1;
    }
    return owned;
}

fn releaseOwnedSpecs(specs: []const OwnedSpec) void {
    for (specs) |spec| spec.connector.release();
}

fn findOwnedSpec(specs: []const OwnedSpec, binding: *const [32]u8) ?*const OwnedSpec {
    for (specs) |*spec|
        if (std.mem.eql(u8, &spec.binding, binding)) return spec;
    return null;
}

fn snapshotCoversSpecs(snapshot: ?*const Snapshot, specs: []const OwnedSpec) bool {
    const current = snapshot orelse return false;
    for (specs) |spec|
        if (current.findServer(&spec.binding) == null) return false;
    return true;
}

fn ownedSpecSetsEqual(a: []const OwnedSpec, b: []const OwnedSpec) bool {
    if (a.len != b.len) return false;
    for (a) |left| {
        const right = findOwnedSpec(b, &left.binding) orelse return false;
        if (!desiredSpecEqual(left, right.*)) return false;
    }
    return true;
}

fn instanceSpecEqual(a: OwnedSpec, b: OwnedSpec) bool {
    const explicit_identity = !allZero(&a.configuration_fingerprint) or
        !allZero(&b.configuration_fingerprint);
    const connector_equal = if (explicit_identity)
        true
    else
        a.connector.ctx == b.connector.ctx and
            a.connector.open_fn == b.connector.open_fn;
    return std.mem.eql(u8, &a.binding, &b.binding) and
        std.mem.eql(u8, a.namespace, b.namespace) and
        std.mem.eql(u8, &a.configuration_fingerprint, &b.configuration_fingerprint) and
        connector_equal and
        a.transport == b.transport and
        a.policy == b.policy and
        std.mem.eql(u8, a.client.name, b.client.name) and
        std.mem.eql(u8, a.client.version, b.client.version) and
        a.timeout_ms == b.timeout_ms and
        std.meta.eql(a.protocol_limits, b.protocol_limits);
}

fn desiredSpecEqual(a: OwnedSpec, b: OwnedSpec) bool {
    return instanceSpecEqual(a, b);
}

/// Runtime-local catalog and instance control plane.
///
/// Public operations are thread-safe. `deinit` is an exclusive terminal
/// operation: the Host must first join control-plane callers and release every
/// retained Snapshot, View, and dispatch Lease.
pub const Manager = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Heap-pinned because published Snapshots retain this address even if a
    /// caller moves the Manager value before destruction.
    instances: *instance_pool.Pool,
    limits: Limits,
    clock: Clock,
    specs: []OwnedSpec,
    reconcile_mutex: sync.Mutex = .{},
    reconcile_condition: sync.Condition = .{},
    reconcile_active: bool = false,
    reconcile_owner: ?std.Thread.Id = null,
    current_mutex: sync.Mutex = .{},
    current: ?*Snapshot = null,
    desired_revision: u64 = 0,
    active_revision: u64 = 0,
    convergence: Convergence = .converged,

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
        const owned = try ownSpecs(arena.allocator(), specs, limits);
        errdefer releaseOwnedSpecs(owned);
        const instances = allocator.create(instance_pool.Pool) catch
            return error.OutOfMemory;
        instances.* = instance_pool.Pool.init(allocator);
        return .{
            .allocator = allocator,
            .arena = arena,
            .instances = instances,
            .limits = limits,
            .clock = clock,
            .specs = owned,
        };
    }

    pub fn deinit(self: *Manager) void {
        if (self.current) |snapshot| snapshot.release();
        self.instances.deinit();
        self.allocator.destroy(self.instances);
        releaseOwnedSpecs(self.specs);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Publish a fresh immutable snapshot. Individual server failures are
    /// catalog issues and do not prevent other servers (or Conversation) from
    /// being usable. Only Runtime-local allocation/global catalog failures
    /// abort publication, leaving the old generation untouched.
    pub fn refresh(self: *Manager) ControlError!u64 {
        try self.beginReconcile();
        defer self.finishReconcile();
        self.current_mutex.lock();
        const generation = if (self.current) |snapshot|
            std.math.add(u64, snapshot.generation, 1) catch {
                self.current_mutex.unlock();
                return error.ResourceLimit;
            }
        else
            1;
        self.current_mutex.unlock();

        const replacement = self.buildSnapshot(
            self.specs,
            generation,
            null,
            false,
        ) catch |err| switch (err) {
            error.CandidateRejected => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConfig => return error.InvalidConfig,
            error.ResourceLimit => return error.ResourceLimit,
            error.NotRefreshed => return error.NotRefreshed,
        };
        self.current_mutex.lock();
        const previous = self.current;
        self.current = replacement;
        self.current_mutex.unlock();
        if (previous) |snapshot| snapshot.release();
        return generation;
    }

    /// Apply one complete desired server set. Candidate construction is
    /// off-side and strict: a changed server that cannot connect rejects the
    /// candidate and leaves the last-known-good specs and catalog untouched.
    /// Unchanged healthy servers retain their exact instance and copied
    /// discovery values instead of reconnecting.
    pub fn apply(
        self: *Manager,
        desired_revision: u64,
        specs: []const ServerSpec,
    ) ControlError!ApplyReport {
        if (desired_revision == 0) return error.InvalidConfig;
        var candidate_arena = std.heap.ArenaAllocator.init(self.allocator);
        var candidate_transferred = false;
        defer if (!candidate_transferred) candidate_arena.deinit();
        const candidate_specs = try ownSpecs(
            candidate_arena.allocator(),
            specs,
            self.limits,
        );
        var candidate_specs_owned = true;
        defer if (candidate_specs_owned) releaseOwnedSpecs(candidate_specs);
        try self.beginReconcile();
        defer self.finishReconcile();

        self.current_mutex.lock();
        const published_desired = self.desired_revision;
        const published_active = self.active_revision;
        const published_convergence = self.convergence;
        const published_generation = if (self.current) |snapshot| snapshot.generation else 0;
        const current_covers_desired = snapshotCoversSpecs(self.current, candidate_specs);
        self.current_mutex.unlock();
        if (desired_revision < published_desired) {
            return .{
                .disposition = .superseded,
                .desired_revision = published_desired,
                .active_revision = published_active,
                .catalog_generation = published_generation,
            };
        }
        if (desired_revision == published_desired and published_convergence != .rejected) {
            if (!ownedSpecSetsEqual(self.specs, candidate_specs))
                return error.InvalidConfig;
            if (current_covers_desired) return .{
                .disposition = .applied,
                .desired_revision = published_desired,
                .active_revision = published_active,
                .catalog_generation = published_generation,
            };
        }
        if (ownedSpecSetsEqual(self.specs, candidate_specs) and current_covers_desired) {
            self.current_mutex.lock();
            self.desired_revision = desired_revision;
            self.active_revision = desired_revision;
            self.convergence = .converged;
            const generation = if (self.current) |snapshot| snapshot.generation else 0;
            self.current_mutex.unlock();
            return .{
                .disposition = .applied,
                .desired_revision = desired_revision,
                .active_revision = desired_revision,
                .catalog_generation = generation,
            };
        }

        self.current_mutex.lock();
        const previous = self.current;
        const generation = if (previous) |snapshot|
            std.math.add(u64, snapshot.generation, 1) catch {
                self.current_mutex.unlock();
                return error.ResourceLimit;
            }
        else
            1;
        self.current_mutex.unlock();
        const replacement = self.buildSnapshot(
            candidate_specs,
            generation,
            previous,
            true,
        ) catch |err| switch (err) {
            error.CandidateRejected => {
                self.current_mutex.lock();
                self.desired_revision = desired_revision;
                self.convergence = .rejected;
                const active_revision = self.active_revision;
                const current_generation = if (self.current) |snapshot| snapshot.generation else 0;
                self.current_mutex.unlock();
                return .{
                    .disposition = .rejected,
                    .desired_revision = desired_revision,
                    .active_revision = active_revision,
                    .catalog_generation = current_generation,
                };
            },
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidConfig => return error.InvalidConfig,
            error.ResourceLimit => return error.ResourceLimit,
            error.NotRefreshed => return error.NotRefreshed,
        };

        self.current_mutex.lock();
        const retired = self.current;
        self.current = replacement;
        self.desired_revision = desired_revision;
        self.active_revision = desired_revision;
        self.convergence = .converged;
        self.current_mutex.unlock();
        var retired_arena = self.arena;
        const retired_specs = self.specs;
        self.arena = candidate_arena;
        candidate_transferred = true;
        self.specs = candidate_specs;
        candidate_specs_owned = false;
        if (retired) |snapshot| snapshot.release();
        releaseOwnedSpecs(retired_specs);
        retired_arena.deinit();
        return .{
            .disposition = .applied,
            .desired_revision = desired_revision,
            .active_revision = desired_revision,
            .catalog_generation = generation,
        };
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
        self.current_mutex.lock();
        const snapshot = self.current orelse {
            self.current_mutex.unlock();
            return error.NotRefreshed;
        };
        const retained = snapshot.retain() catch |err| {
            self.current_mutex.unlock();
            return err;
        };
        const desired_revision = self.desired_revision;
        const active_revision = self.active_revision;
        const convergence = self.convergence;
        self.current_mutex.unlock();
        defer retained.release();
        var description = try retained.describe(backing);
        description.desired_revision = desired_revision;
        description.active_revision = active_revision;
        description.convergence = convergence;
        return description;
    }

    fn beginReconcile(self: *Manager) ControlError!void {
        const current_thread = std.Thread.getCurrentId();
        self.reconcile_mutex.lock();
        defer self.reconcile_mutex.unlock();
        if (self.reconcile_active and self.reconcile_owner.? == current_thread)
            return error.ReentrantControlCall;
        while (self.reconcile_active)
            self.reconcile_condition.wait(&self.reconcile_mutex);
        self.reconcile_active = true;
        self.reconcile_owner = current_thread;
    }

    fn finishReconcile(self: *Manager) void {
        self.reconcile_mutex.lock();
        std.debug.assert(self.reconcile_active);
        std.debug.assert(self.reconcile_owner.? == std.Thread.getCurrentId());
        self.reconcile_active = false;
        self.reconcile_owner = null;
        self.reconcile_condition.broadcast();
        self.reconcile_mutex.unlock();
    }

    fn buildSnapshot(
        self: *Manager,
        specs: []const OwnedSpec,
        generation: u64,
        reuse_from: ?*const Snapshot,
        strict_candidate: bool,
    ) BuildError!*Snapshot {
        const snapshot = self.allocator.create(Snapshot) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(snapshot);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var servers: std.ArrayList(ServerRecord) = .empty;
        defer servers.deinit(a);
        var issues: std.ArrayList(CatalogIssue) = .empty;
        defer issues.deinit(a);
        // Keep instance ownership independent from the arena-backed Server
        // ArrayList. `toOwnedSlice` empties that list, so it cannot serve as
        // the rollback ledger for a later allocation failure.
        var instance_owners: std.ArrayList(instance_pool.InstanceId) = .empty;
        defer instance_owners.deinit(self.allocator);
        errdefer for (instance_owners.items) |id|
            self.instances.releaseId(id);
        for (specs) |spec| {
            var strict_server = strict_candidate;
            if (reuse_from) |previous| {
                const prior_spec = findOwnedSpec(self.specs, &spec.binding);
                const prior_server = previous.findServer(&spec.binding);
                const unchanged = prior_spec != null and
                    instanceSpecEqual(prior_spec.?.*, spec);
                if (unchanged and prior_server != null) {
                    const cloned = try cloneServerRecord(
                        a,
                        prior_server.?,
                        spec.namespace,
                    );
                    self.instances.retainId(cloned.instance_id) catch |err|
                        return switch (err) {
                            error.OutOfMemory => error.OutOfMemory,
                            error.InstanceUnavailable => error.CandidateRejected,
                            error.ResourceLimit => error.ResourceLimit,
                        };
                    instance_owners.append(
                        self.allocator,
                        cloned.instance_id,
                    ) catch {
                        self.instances.releaseId(cloned.instance_id);
                        return error.OutOfMemory;
                    };
                    servers.append(a, cloned) catch return error.OutOfMemory;
                    continue;
                }
                // A server may be absent from the previous generation because
                // its last refresh failed. It is still an unchanged desired
                // definition, so another transient failure remains a
                // server-scoped issue and cannot reject unrelated additions.
                if (unchanged) strict_server = false;
            }
            const connected = runtime.connectServer(self.allocator, spec.runtimeConfig());
            const client = switch (connected) {
                .client => |value| value,
                .failed => |failure| {
                    switch (failure) {
                        .out_of_memory => return error.OutOfMemory,
                        .resource_limit, .diagnostic => {},
                    }
                    if (strict_server) return error.CandidateRejected;
                    try appendIssue(&issues, a, self.limits, .{
                        .server_binding_identity = spec.binding,
                        .kind = .{ .connection = failure },
                    });
                    continue;
                },
            };
            const instance_id = self.instances.adopt(client) catch |err| {
                client.deinit();
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.ResourceLimit, error.InstanceUnavailable => error.ResourceLimit,
                };
            };
            instance_owners.append(self.allocator, instance_id) catch {
                self.instances.releaseId(instance_id);
                return error.OutOfMemory;
            };
            const namespace = a.dupe(u8, spec.namespace) catch return error.OutOfMemory;
            var admitted_tools: std.ArrayList(AdmittedTool) = .empty;
            defer admitted_tools.deinit(a);
            for (client.catalog.tools) |*source_tool| {
                const tool = cloneTool(a, source_tool) catch
                    return error.OutOfMemory;
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
                const inspected = try inspectTool(self.allocator, model_name, tool);
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
                .server_binding_identity = spec.binding,
                .instance_id = instance_id,
                .era = client.era,
                .fingerprint = serverFingerprint(
                    self.allocator,
                    &spec.binding,
                    client.era,
                    owned_admitted,
                ) catch
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
            .instances = self.instances,
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

fn cloneServerRecord(
    allocator: std.mem.Allocator,
    source: *const ServerRecord,
    namespace: []const u8,
) error{OutOfMemory}!ServerRecord {
    const admitted_tools = allocator.alloc(
        AdmittedTool,
        source.admitted_tools.len,
    ) catch return error.OutOfMemory;
    for (source.admitted_tools, admitted_tools) |admitted, *destination| {
        destination.* = .{
            .canonical = try cloneTool(allocator, &admitted.canonical),
            .model_name = allocator.dupe(u8, admitted.model_name) catch
                return error.OutOfMemory,
        };
    }
    return .{
        .namespace = allocator.dupe(u8, namespace) catch
            return error.OutOfMemory,
        .server_binding_identity = source.server_binding_identity,
        .instance_id = source.instance_id,
        .era = source.era,
        .fingerprint = source.fingerprint,
        .expires_at_ns = source.expires_at_ns,
        .cache_scope = source.cache_scope,
        .admitted_tools = admitted_tools,
    };
}

fn cloneTool(
    allocator: std.mem.Allocator,
    source: *const canonical.Tool,
) error{OutOfMemory}!canonical.Tool {
    return .{
        .identity = .{
            .server_binding_identity = source.identity.server_binding_identity,
            .name = allocator.dupe(u8, source.identity.name) catch
                return error.OutOfMemory,
            .schema_fingerprint = source.identity.schema_fingerprint,
        },
        .title = try cloneOptional(allocator, source.title),
        .description = try cloneOptional(allocator, source.description),
        .input_schema_json = allocator.dupe(u8, source.input_schema_json) catch
            return error.OutOfMemory,
        .output_schema_json = try cloneOptional(allocator, source.output_schema_json),
        .annotations_json = try cloneOptional(allocator, source.annotations_json),
        .icons_json = try cloneOptional(allocator, source.icons_json),
        .meta_json = try cloneOptional(allocator, source.meta_json),
        .execution_json = try cloneOptional(allocator, source.execution_json),
        .execution_mode = source.execution_mode,
        .raw_json = allocator.dupe(u8, source.raw_json) catch
            return error.OutOfMemory,
    };
}

fn cloneOptional(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) error{OutOfMemory}!?[]const u8 {
    const bytes = value orelse return null;
    return allocator.dupe(u8, bytes) catch error.OutOfMemory;
}

/// Perform the one authoritative executable admission pass. The temporary
/// PreparedTool proves the bounded MCP envelope can be projected for model
/// providers; JSON Schema dialect and keyword semantics remain server-owned.
fn inspectTool(
    scratch_backing: std.mem.Allocator,
    model_name: []const u8,
    tool: canonical.Tool,
) error{OutOfMemory}!Inspection {
    if (tool.execution_mode == .task_required)
        return .{ .unavailable = .task_required_unsupported };
    var admission = try schema.prepareTool(scratch_backing, model_name, &tool, .{});
    return switch (admission) {
        .unavailable => |issue| .{ .unavailable = .{ .schema = issue } },
        .available => |*prepared| blk: {
            defer prepared.deinit();
            break :blk .{ .admitted = .{
                .canonical = tool,
                .model_name = model_name,
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
        &admitted.canonical,
        .{},
    ) catch return error.OutOfMemory;
    return switch (admission) {
        .unavailable => error.AdmissionInvariantViolation,
        .available => |prepared| prepared,
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
    binding: *const [32]u8,
    era: canonical.Era,
    admitted_tools: []const AdmittedTool,
) error{OutOfMemory}![32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // Stable domain; admitted contents, not the ABI revision, define change.
    hasher.update("agentcore-r6-mcp-server-catalog\x00");
    hasher.update(binding);
    hasher.update(era.version());
    const digests = allocator.alloc([32]u8, admitted_tools.len) catch
        return error.OutOfMemory;
    defer allocator.free(digests);
    for (admitted_tools, digests) |admitted, *digest| {
        const tool = &admitted.canonical;
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
        hasher.update(&server.server_binding_identity);
        hasher.update(&server.fingerprint);
    }
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn sortServers(servers: []ServerRecord) void {
    std.mem.sort(ServerRecord, servers, {}, struct {
        fn lessThan(_: void, left: ServerRecord, right: ServerRecord) bool {
            return std.mem.order(
                u8,
                &left.server_binding_identity,
                &right.server_binding_identity,
            ) == .lt;
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
    fail_open: bool = false,
    reenter_manager: ?*Manager = null,
    saw_reentrant_rejection: bool = false,
    block_mutex: sync.Mutex = .{},
    block_condition: sync.Condition = .{},
    block_open: bool = false,
    open_waiting: bool = false,

    const Conn = struct { owner: *Fake };

    fn connector(self: *Fake) runtime.Connector {
        return .{ .ctx = self, .open_fn = open };
    }

    fn open(raw: *anyopaque, _: runtime.ConnectionPurpose, _: canonical.Era) anyerror!runtime.OpenOutcome {
        const self: *Fake = @ptrCast(@alignCast(raw));
        if (self.reenter_manager) |manager| {
            self.reenter_manager = null;
            _ = manager.apply(99, &.{}) catch |err| {
                self.saw_reentrant_rejection = err == error.ReentrantControlCall;
            };
        }
        self.block_mutex.lock();
        if (self.block_open) {
            self.open_waiting = true;
            self.block_condition.broadcast();
            while (self.block_open)
                self.block_condition.wait(&self.block_mutex);
        }
        self.block_mutex.unlock();
        if (self.fail_open_oom) return error.OutOfMemory;
        if (self.fail_open) return .server_error;
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
    try std.testing.expect(first.servers[0].instance_id != second.servers[0].instance_id);
    var first_instance = try first.retainInstance(first.servers[0].instance_id);
    defer first_instance.deinit();
    var second_instance = try second.retainInstance(second.servers[0].instance_id);
    defer second_instance.deinit();
    try std.testing.expect(first_instance.client() != second_instance.client());
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

test "Connector callback reentry is rejected instead of deadlocking" {
    var fake = Fake{};
    const specs = [_]ServerSpec{.{
        .binding = [_]u8{0xaf} ** 32,
        .namespace = "reentrant",
        .connector = fake.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var manager = try Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    fake.reenter_manager = &manager;
    _ = try manager.refresh();
    try std.testing.expect(fake.saw_reentrant_rejection);
}

test "describe does not wait for an in-flight Connector handshake" {
    const RefreshWorker = struct {
        manager: *Manager,
        failed: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            _ = self.manager.refresh() catch {
                self.failed.store(true, .release);
                return;
            };
        }
    };
    const DescribeWorker = struct {
        manager: *Manager,
        completed: *std.atomic.Value(bool),
        failed: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            var description = self.manager.describeCurrent(std.heap.c_allocator) catch {
                self.failed.store(true, .release);
                self.completed.store(true, .release);
                return;
            };
            description.deinit();
            self.completed.store(true, .release);
        }
    };

    var fake = Fake{};
    const specs = [_]ServerSpec{.{
        .binding = [_]u8{0xb0} ** 32,
        .namespace = "nonblocking",
        .connector = fake.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var manager = try Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    _ = try manager.refresh();

    fake.block_mutex.lock();
    fake.block_open = true;
    fake.open_waiting = false;
    fake.block_mutex.unlock();
    var refresh_failed = std.atomic.Value(bool).init(false);
    var refresh_worker = RefreshWorker{
        .manager = &manager,
        .failed = &refresh_failed,
    };
    const refresh_thread = try std.Thread.spawn(.{}, RefreshWorker.run, .{&refresh_worker});
    var refresh_joined = false;
    defer if (!refresh_joined) refresh_thread.join();

    var observed_blocked_handshake = false;
    for (0..1_000) |_| {
        fake.block_mutex.lock();
        observed_blocked_handshake = fake.open_waiting;
        fake.block_mutex.unlock();
        if (observed_blocked_handshake) break;
        sync.sleepMs(1);
    }

    var describe_completed = std.atomic.Value(bool).init(false);
    var describe_failed = std.atomic.Value(bool).init(false);
    var describe_worker = DescribeWorker{
        .manager = &manager,
        .completed = &describe_completed,
        .failed = &describe_failed,
    };
    const describe_thread = try std.Thread.spawn(.{}, DescribeWorker.run, .{&describe_worker});
    var describe_joined = false;
    defer if (!describe_joined) describe_thread.join();

    var completed_before_unblock = false;
    for (0..1_000) |_| {
        if (describe_completed.load(.acquire)) {
            completed_before_unblock = true;
            break;
        }
        sync.sleepMs(1);
    }

    // Always release the Connector before asserting so a failed regression
    // test cannot strand either worker thread.
    fake.block_mutex.lock();
    fake.block_open = false;
    fake.block_condition.broadcast();
    fake.block_mutex.unlock();
    refresh_thread.join();
    refresh_joined = true;
    describe_thread.join();
    describe_joined = true;

    try std.testing.expect(observed_blocked_handshake);
    try std.testing.expect(completed_before_unblock);
    try std.testing.expect(!describe_failed.load(.acquire));
    try std.testing.expect(!refresh_failed.load(.acquire));
}

test "declarative apply reuses unchanged instances and rejects failed candidates" {
    var stable = Fake{};
    var added = Fake{};
    var failing = Fake{ .fail_open = true };
    const stable_binding = [_]u8{0xa1} ** 32;
    const added_binding = [_]u8{0xa2} ** 32;
    const initial = [_]ServerSpec{.{
        .binding = stable_binding,
        .namespace = "stable",
        .connector = stable.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var manager = try Manager.init(std.testing.allocator, &initial, .{});
    defer manager.deinit();
    try std.testing.expectEqual(@as(u64, 1), try manager.refresh());
    const first = try manager.retainCurrent();
    defer first.release();
    const stable_instance = first.servers[0].instance_id;

    const no_op = try manager.apply(1, &initial);
    try std.testing.expectEqual(ApplyDisposition.applied, no_op.disposition);
    try std.testing.expectEqual(@as(u64, 1), no_op.catalog_generation);
    try std.testing.expectEqual(@as(u8, 2), stable.opens);

    const expanded = [_]ServerSpec{
        initial[0],
        .{
            .binding = added_binding,
            .namespace = "added",
            .connector = added.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
    };
    const applied = try manager.apply(2, &expanded);
    try std.testing.expectEqual(ApplyDisposition.applied, applied.disposition);
    try std.testing.expectEqual(@as(u64, 2), applied.catalog_generation);
    const second = try manager.retainCurrent();
    defer second.release();
    try std.testing.expectEqual(
        stable_instance,
        second.findServer(&stable_binding).?.instance_id,
    );
    try std.testing.expectEqual(@as(u8, 2), stable.opens);
    try std.testing.expectEqual(@as(u8, 2), added.opens);

    const rejected_specs = [_]ServerSpec{
        .{
            .binding = stable_binding,
            .namespace = "stable",
            .connector = failing.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
        expanded[1],
    };
    const rejected = try manager.apply(3, &rejected_specs);
    try std.testing.expectEqual(ApplyDisposition.rejected, rejected.disposition);
    try std.testing.expectEqual(@as(u64, 2), rejected.active_revision);
    try std.testing.expectEqual(@as(u64, 2), rejected.catalog_generation);
    var rejected_description = try manager.describeCurrent(std.testing.allocator);
    defer rejected_description.deinit();
    try std.testing.expectEqual(@as(u64, 3), rejected_description.desired_revision);
    try std.testing.expectEqual(@as(u64, 2), rejected_description.active_revision);
    try std.testing.expectEqual(Convergence.rejected, rejected_description.convergence);
    const after_rejection = try manager.retainCurrent();
    defer after_rejection.release();
    try std.testing.expectEqual(
        stable_instance,
        after_rejection.findServer(&stable_binding).?.instance_id,
    );

    failing.fail_open = false;
    const retried = try manager.apply(3, &rejected_specs);
    try std.testing.expectEqual(ApplyDisposition.applied, retried.disposition);
    try std.testing.expectEqual(@as(u64, 3), retried.active_revision);
    const after_retry = try manager.retainCurrent();
    defer after_retry.release();
    const retried_stable_instance = after_retry.findServer(&stable_binding).?.instance_id;
    try std.testing.expect(retried_stable_instance != stable_instance);

    const retained_after_remove = [_]ServerSpec{rejected_specs[0]};
    const removed = try manager.apply(4, &retained_after_remove);
    try std.testing.expectEqual(ApplyDisposition.applied, removed.disposition);
    try std.testing.expectEqual(@as(u64, 4), removed.catalog_generation);
    const final = try manager.retainCurrent();
    defer final.release();
    try std.testing.expectEqual(@as(usize, 1), final.servers.len);
    try std.testing.expectEqual(retried_stable_instance, final.servers[0].instance_id);
}

test "unchanged unavailable server does not reject an unrelated addition" {
    var healthy = Fake{};
    var unavailable = Fake{ .fail_open = true };
    var added = Fake{};
    const initial = [_]ServerSpec{
        .{
            .binding = [_]u8{0xc1} ** 32,
            .namespace = "healthy",
            .connector = healthy.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
        .{
            .binding = [_]u8{0xc2} ** 32,
            .namespace = "unavailable",
            .connector = unavailable.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
    };
    var manager = try Manager.init(std.testing.allocator, &initial, .{});
    defer manager.deinit();
    _ = try manager.refresh();
    const expanded = [_]ServerSpec{
        initial[0],
        initial[1],
        .{
            .binding = [_]u8{0xc3} ** 32,
            .namespace = "added",
            .connector = added.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
    };
    const report = try manager.apply(1, &expanded);
    try std.testing.expectEqual(ApplyDisposition.applied, report.disposition);
    var description = try manager.describeCurrent(std.testing.allocator);
    defer description.deinit();
    try std.testing.expectEqual(@as(usize, 2), description.servers.len);
    try std.testing.expectEqual(@as(usize, 1), description.issues.len);
    try std.testing.expectEqual(@as(u32, 2), added.opens);
}

test "reapplying an unchanged desired set reconnects a missing server" {
    var server = Fake{ .fail_open = true };
    const binding = [_]u8{0xc4} ** 32;
    const specs = [_]ServerSpec{.{
        .binding = binding,
        .namespace = "recovering",
        .connector = server.connector(),
        .transport = .stdio,
        .client = .{ .name = "agentcore-test", .version = "1" },
    }};
    var manager = try Manager.init(std.testing.allocator, &specs, .{});
    defer manager.deinit();
    _ = try manager.refresh();
    var missing = try manager.describeCurrent(std.testing.allocator);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.servers.len);
    try std.testing.expectEqual(@as(usize, 1), missing.issues.len);

    server.fail_open = false;
    const report = try manager.apply(1, &specs);
    try std.testing.expectEqual(ApplyDisposition.applied, report.disposition);
    try std.testing.expectEqual(@as(u64, 2), report.catalog_generation);
    var recovered = try manager.describeCurrent(std.testing.allocator);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(usize, 1), recovered.servers.len);
    try std.testing.expectEqual(@as(usize, 0), recovered.issues.len);
    try std.testing.expectEqualSlices(
        u8,
        &binding,
        &recovered.servers[0].server_binding_identity,
    );
}

test "rejected candidate releases instances acquired before the failure" {
    var admitted_first = Fake{};
    var rejected_second = Fake{ .fail_open = true };
    var manager = try Manager.init(std.testing.allocator, &.{}, .{});
    defer manager.deinit();
    _ = try manager.refresh();
    const candidate = [_]ServerSpec{
        .{
            .binding = [_]u8{0xc5} ** 32,
            .namespace = "admitted",
            .connector = admitted_first.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
        .{
            .binding = [_]u8{0xc6} ** 32,
            .namespace = "rejected",
            .connector = rejected_second.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
    };
    const report = try manager.apply(1, &candidate);
    try std.testing.expectEqual(ApplyDisposition.rejected, report.disposition);
    try std.testing.expectEqual(@as(u64, 1), report.catalog_generation);
    try std.testing.expect(admitted_first.opens != 0);
    try std.testing.expectEqual(admitted_first.opens, admitted_first.closes);
    var current = try manager.describeCurrent(std.testing.allocator);
    defer current.deinit();
    try std.testing.expectEqual(@as(usize, 0), current.servers.len);
}

test "catalog generations contain values and opaque ids, never Clients" {
    try std.testing.expect(!@hasField(ServerRecord, "client"));
    try std.testing.expect(!@hasField(AdmittedTool, "client"));
    try std.testing.expect(@hasField(ServerRecord, "instance_id"));
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

fn catalogRefreshAllocationFailure(allocator: std.mem.Allocator) !void {
    var healthy = Fake{};
    var unavailable = Fake{ .fail_open = true };
    const specs = [_]ServerSpec{
        .{
            .binding = [_]u8{0x44} ** 32,
            .namespace = "healthy",
            .connector = healthy.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
        .{
            .binding = [_]u8{0x45} ** 32,
            .namespace = "unavailable",
            .connector = unavailable.connector(),
            .transport = .stdio,
            .client = .{ .name = "agentcore-test", .version = "1" },
        },
    };
    var manager = try Manager.init(allocator, &specs, .{});
    defer manager.deinit();
    _ = try manager.refresh();
}

test "catalog construction closes every instance at every allocation seam" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        catalogRefreshAllocationFailure,
        .{},
    );
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

test "Catalog excludes broken Provider projections and required-task tools" {
    const fixture = @import("mcp_test_support.zig");
    var opaque_schema = fixture.Server{
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"x\":{\"$ref\":\"#/$defs/x\"}}}",
    };
    var required_task = Fake{ .required_task = true };
    const invalid_binding = [_]u8{0x51} ** 32;
    const required_binding = [_]u8{0x52} ** 32;
    const specs = [_]ServerSpec{
        .{
            .binding = invalid_binding,
            .namespace = "invalid",
            .connector = opaque_schema.connector(),
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
    try std.testing.expectEqual(@as(usize, 0), required_server.admitted_tools.len);
    try std.testing.expect(snapshot.findTool(&required_binding, "tasked") == null);

    var description = try snapshot.describe(std.testing.allocator);
    defer description.deinit();
    try std.testing.expectEqual(@as(usize, 0), description.tools.len);
    try std.testing.expectEqual(@as(usize, 2), description.issues.len);
    var saw_projection_loss = false;
    var saw_required_task = false;
    for (description.issues) |issue| {
        if (std.mem.eql(u8, issue.kind, "provider_critical_projection_loss"))
            saw_projection_loss = true;
        if (std.mem.eql(u8, issue.kind, "task_required_unsupported"))
            saw_required_task = true;
    }
    try std.testing.expect(saw_projection_loss and saw_required_task);
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
