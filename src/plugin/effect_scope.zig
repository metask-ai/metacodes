//! Synchronous ownership boundary for trusted static-plugin effects.
//!
//! A plugin may register cleanup only while its immutable Snapshot is being
//! staged. Publication commits the scope; Snapshot destruction disposes every
//! registered effect exactly once in reverse registration order. Activation
//! failure destroys the staging scope, so a partially initialized plugin set
//! is never observable by an AgentRuntime or Session.

const std = @import("std");
const contract = @import("contract.zig");

pub const MAX_EFFECTS: usize = 1024;
pub const MAX_SERVICES: usize = 256;
pub const MAX_SERVICE_NAME_BYTES: usize = 48;

pub const Error = error{
    OutOfMemory,
    InvalidEffect,
    InactiveEffect,
    PluginActivationFailed,
    TooManyEffects,
    TooManyServices,
    InvalidService,
    DuplicateService,
    UndeclaredServiceDependency,
    MissingService,
    ServiceTypeMismatch,
};

pub const CleanupFn = *const fn (ctx: *anyopaque) void;

pub const State = enum {
    staging,
    active,
    disposing,
    disposed,
};

const Record = struct {
    plugin_id: []u8,
    label: []u8,
    ctx: *anyopaque,
    cleanup: CleanupFn,
};

const ServiceRecord = struct {
    provider_id: []u8,
    name: []u8,
    type_name: []const u8,
    value: *anyopaque,
};

/// The registrar is a borrowed activation-phase capability. Retaining it does
/// not extend its authority: `add` checks the Scope state on every call.
pub const Registrar = struct {
    scope: *Scope,
    plugin_id: []const u8,
    dependencies: []const contract.Dependency,

    pub fn add(
        self: *Registrar,
        label: []const u8,
        ctx: *anyopaque,
        cleanup: CleanupFn,
    ) Error!void {
        try self.scope.add(self.plugin_id, label, ctx, cleanup);
    }

    /// Publish one activation-time dependency-injection service owned by this
    /// plugin. The cleanup is automatically registered in the same Scope.
    pub fn provide(
        self: *Registrar,
        comptime T: type,
        name: []const u8,
        value: *T,
        cleanup: CleanupFn,
    ) Error!void {
        try self.scope.provide(self.plugin_id, name, @typeName(T), value, cleanup);
    }

    /// Resolve only self-owned or explicitly declared plugin dependencies.
    /// The returned pointer is captured by the consumer during activation; the
    /// registry itself cannot be queried or mutated after Snapshot commit.
    pub fn require(
        self: *Registrar,
        comptime T: type,
        provider_id: []const u8,
        name: []const u8,
    ) Error!*T {
        if (!std.mem.eql(u8, provider_id, self.plugin_id)) {
            var declared = false;
            for (self.dependencies) |dependency| {
                if (std.mem.eql(u8, dependency.id.bytes, provider_id)) {
                    declared = true;
                    break;
                }
            }
            if (!declared) return error.UndeclaredServiceDependency;
        }
        const raw = try self.scope.require(provider_id, name, @typeName(T));
        return @ptrCast(@alignCast(raw));
    }
};

/// Activation has one intentionally narrow failure vocabulary. Plugin-local
/// initialization errors must be mapped to `PluginActivationFailed`; cleanup
/// is synchronous and infallible so teardown cannot open a second error path.
pub const ActivationFn = *const fn (ctx: *anyopaque, registrar: *Registrar) Error!void;

pub const StaticActivation = struct {
    ctx: *anyopaque,
    activate: ActivationFn,
};

pub const Scope = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,
    services: std.ArrayList(ServiceRecord) = .empty,
    state: State = .staging,

    pub fn create(allocator: std.mem.Allocator) Error!*Scope {
        const self = try allocator.create(Scope);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn registrar(
        self: *Scope,
        plugin_id: []const u8,
        dependencies: []const contract.Dependency,
    ) Error!Registrar {
        if (self.state != .staging) return error.InactiveEffect;
        _ = contract.PluginId.parse(plugin_id) catch return error.InvalidEffect;
        return .{ .scope = self, .plugin_id = plugin_id, .dependencies = dependencies };
    }

    fn add(
        self: *Scope,
        plugin_id: []const u8,
        label: []const u8,
        ctx: *anyopaque,
        cleanup: CleanupFn,
    ) Error!void {
        if (self.state != .staging) return error.InactiveEffect;
        if (plugin_id.len == 0 or label.len == 0) return error.InvalidEffect;
        if (self.records.items.len >= MAX_EFFECTS) return error.TooManyEffects;
        const owned_plugin_id = try self.allocator.dupe(u8, plugin_id);
        errdefer self.allocator.free(owned_plugin_id);
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        try self.records.append(self.allocator, .{
            .plugin_id = owned_plugin_id,
            .label = owned_label,
            .ctx = ctx,
            .cleanup = cleanup,
        });
    }

    fn provide(
        self: *Scope,
        provider_id: []const u8,
        name: []const u8,
        type_name: []const u8,
        value: *anyopaque,
        cleanup: CleanupFn,
    ) Error!void {
        if (self.state != .staging) return error.InactiveEffect;
        if (!validServiceName(name) or type_name.len == 0) return error.InvalidService;
        if (self.services.items.len >= MAX_SERVICES) return error.TooManyServices;
        for (self.services.items) |service| {
            if (std.mem.eql(u8, service.provider_id, provider_id) and
                std.mem.eql(u8, service.name, name)) return error.DuplicateService;
        }

        const owned_provider_id = try self.allocator.dupe(u8, provider_id);
        errdefer self.allocator.free(owned_provider_id);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.services.append(self.allocator, .{
            .provider_id = owned_provider_id,
            .name = owned_name,
            .type_name = type_name,
            .value = value,
        });
        self.add(provider_id, name, value, cleanup) catch |err| {
            self.services.items.len -= 1;
            self.allocator.free(owned_name);
            self.allocator.free(owned_provider_id);
            return err;
        };
    }

    fn require(
        self: *Scope,
        provider_id: []const u8,
        name: []const u8,
        type_name: []const u8,
    ) Error!*anyopaque {
        if (self.state != .staging) return error.InactiveEffect;
        if (!validServiceName(name)) return error.InvalidService;
        for (self.services.items) |service| {
            if (!std.mem.eql(u8, service.provider_id, provider_id) or
                !std.mem.eql(u8, service.name, name)) continue;
            if (!std.mem.eql(u8, service.type_name, type_name)) return error.ServiceTypeMismatch;
            return service.value;
        }
        return error.MissingService;
    }

    pub fn commit(self: *Scope) Error!void {
        if (self.state != .staging) return error.InactiveEffect;
        self.state = .active;
    }

    /// Idempotent and reentrancy-safe: the state changes before any plugin
    /// callback runs, and callbacks execute in strict reverse ownership order.
    pub fn dispose(self: *Scope) void {
        if (self.state == .disposing or self.state == .disposed) return;
        self.state = .disposing;
        var index = self.records.items.len;
        while (index != 0) {
            index -= 1;
            const record = self.records.items[index];
            record.cleanup(record.ctx);
            self.allocator.free(record.label);
            self.allocator.free(record.plugin_id);
        }
        self.records.clearRetainingCapacity();
        for (self.services.items) |service| {
            self.allocator.free(service.name);
            self.allocator.free(service.provider_id);
        }
        self.services.clearRetainingCapacity();
        self.state = .disposed;
    }

    pub fn destroy(self: *Scope) void {
        // A cleanup may defensively request owner destruction. The outer
        // disposer remains the sole owner of list storage and finishes it.
        if (self.state == .disposing) return;
        const allocator = self.allocator;
        self.dispose();
        self.records.deinit(allocator);
        self.services.deinit(allocator);
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn count(self: *const Scope) usize {
        return self.records.items.len;
    }

    pub fn serviceCountFor(self: *const Scope, provider_id: []const u8) usize {
        var result: usize = 0;
        for (self.services.items) |service| {
            if (std.mem.eql(u8, service.provider_id, provider_id)) result += 1;
        }
        return result;
    }
};

fn validServiceName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_SERVICE_NAME_BYTES) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    for (name[1..]) |byte| {
        if ((byte < 'a' or byte > 'z') and
            (byte < '0' or byte > '9') and byte != '-') return false;
    }
    return true;
}

const TestProbe = struct {
    scope: *Scope,
    order: [3]u8 = .{ 0, 0, 0 },
    count: usize = 0,

    fn cleanupOne(raw: *anyopaque) void {
        const self: *TestProbe = @ptrCast(@alignCast(raw));
        self.order[self.count] = 1;
        self.count += 1;
    }

    fn cleanupTwo(raw: *anyopaque) void {
        const self: *TestProbe = @ptrCast(@alignCast(raw));
        self.order[self.count] = 2;
        self.count += 1;
        self.scope.destroy();
    }
};

test "effect scope disposes in reverse exactly once under reentry" {
    const scope = try Scope.create(std.testing.allocator);
    var probe = TestProbe{ .scope = scope };
    var registrar_value = try scope.registrar("acme.review", &.{});
    try registrar_value.add("first", &probe, TestProbe.cleanupOne);
    try registrar_value.add("second", &probe, TestProbe.cleanupTwo);
    try std.testing.expectEqual(@as(usize, 2), scope.count());
    try scope.commit();

    scope.dispose();
    scope.dispose();
    try std.testing.expectEqualSlices(u8, &.{ 2, 1 }, probe.order[0..2]);
    try std.testing.expectEqual(@as(usize, 2), probe.count);
    try std.testing.expectEqual(State.disposed, scope.state);
    scope.destroy();
}

test "effect registrar authority expires at commit" {
    const scope = try Scope.create(std.testing.allocator);
    defer scope.destroy();
    var marker: u8 = 0;
    var registrar_value = try scope.registrar("acme.review", &.{});
    try std.testing.expectError(
        error.InvalidEffect,
        registrar_value.add("", &marker, TestProbe.cleanupOne),
    );
    try scope.commit();
    try std.testing.expectError(
        error.InactiveEffect,
        registrar_value.add("late", &marker, TestProbe.cleanupOne),
    );
}

test "typed service graph enforces declared dependency and exact type" {
    const Service = struct { value: u32 };
    const Wrong = struct { value: u32 };
    const scope = try Scope.create(std.testing.allocator);
    defer scope.destroy();
    var service = Service{ .value = 42 };
    var provider = try scope.registrar("acme.provider", &.{});
    try provider.provide(Service, "review-store", &service, noCleanup);

    var undeclared = try scope.registrar("acme.consumer", &.{});
    try std.testing.expectError(
        error.UndeclaredServiceDependency,
        undeclared.require(Service, "acme.provider", "review-store"),
    );
    const dependencies = [_]contract.Dependency{.{
        .id = try contract.PluginId.parse("acme.provider"),
        .minimum = try contract.Version.parse("1.0.0"),
    }};
    var consumer = try scope.registrar("acme.consumer", &dependencies);
    try std.testing.expectError(
        error.ServiceTypeMismatch,
        consumer.require(Wrong, "acme.provider", "review-store"),
    );
    const resolved = try consumer.require(Service, "acme.provider", "review-store");
    try std.testing.expectEqual(@as(u32, 42), resolved.value);
    try std.testing.expectError(
        error.DuplicateService,
        provider.provide(Service, "review-store", &service, noCleanup),
    );
}

fn noCleanup(_: *anyopaque) void {}
