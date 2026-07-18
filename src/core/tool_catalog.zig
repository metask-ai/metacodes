//! Immutable Runtime tool catalog and per-Session selection.
//!
//! The Runtime owns `Catalog`; each Session owns a `Selection` derived from it.
//! Definitions, admission and dispatch therefore resolve through the same
//! selected `Entry`. Built-in and Host executors deliberately share this one
//! directory so advertisement, admission and execution cannot drift apart.

const std = @import("std");
const json = @import("../json.zig");
const tools = @import("../tools.zig");

pub const CatalogError = error{
    UnknownBuiltinTool,
    DuplicateToolName,
    ToolNotInRuntime,
    InvalidHostTool,
};

pub const HostToolResult = struct {
    bytes: []const u8,
    release_ctx: *anyopaque,
    releaseFn: *const fn (ctx: *anyopaque, bytes: []const u8) void,

    pub fn release(self: HostToolResult) void {
        self.releaseFn(self.release_ctx, self.bytes);
    }
};

/// Typed Host tool outcome. Zig errors carry no payload, so business-failure
/// detail must live in a union, not an error set. Ownership per branch:
/// `ok` transfers to the caller (released via result.release() after copy);
/// `failed`/`rejected` payloads are optional details, borrowed until the
/// dispatch layer copies them, then released; `fatal` carries nothing —
/// the fatal control flow owns everything downstream.
pub const HostToolOutcome = union(enum) {
    ok: HostToolResult,
    failed: ?HostToolResult,
    rejected: ?HostToolResult,
    fatal,
};

pub const RunIdentity = tools.RunIdentity;
pub const HostRunIdentity = tools.HostRunIdentity;

pub const HostSyncExecuteFn = *const fn (
    ctx: *anyopaque,
    identity: HostRunIdentity,
    args: []const u8,
) error{OutOfMemory}!HostToolOutcome;

/// Runtime copies `definition` recursively. `ctx` remains Host-owned and must
/// outlive the Runtime. The thin library contract accepts completed results
/// only. Callbacks may run concurrently for different Sessions; the Host owns
/// `ctx` locking.
/// `args` is the provider-produced JSON envelope; the Host owns its validation.
/// Session lifecycle locks are not held, but abort is the only supported
/// reentrant AgentSession operation.
pub const HostSyncTool = struct {
    definition: json.ToolDefinition,
    ctx: *anyopaque,
    execute: HostSyncExecuteFn,
};

pub const HostSyncExecutor = struct {
    ctx: *anyopaque,
    execute: HostSyncExecuteFn,
};

pub const Executor = union(enum) {
    builtin: *const tools.ToolEntry,
    host_sync: HostSyncExecutor,
};

pub const Entry = struct {
    definition: json.ToolDefinition,
    executor: Executor,
    prefetch_safe: bool,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    entries: []Entry,

    pub fn initBuiltins(allocator: std.mem.Allocator, names: []const []const u8) !Catalog {
        return init(allocator, names, &.{});
    }

    pub fn init(allocator: std.mem.Allocator, builtin_names: []const []const u8, host_tools: []const HostSyncTool) !Catalog {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = .init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        var entries = try std.ArrayList(Entry).initCapacity(owned, builtin_names.len + host_tools.len);

        for (builtin_names) |name| {
            if (findEntry(entries.items, name) != null) return error.DuplicateToolName;
            const builtin = tools.getTool(name) orelse return error.UnknownBuiltinTool;
            try entries.append(owned, .{
                .definition = .{
                    .name = builtin.name,
                    .description = builtin.description,
                    .input_schema = .{
                        .type = builtin.input_schema.type,
                        .prop_specs = builtin.input_schema.prop_specs,
                        .properties = null,
                        .required = builtin.input_schema.required,
                    },
                    .deferred = builtin.deferred,
                },
                .executor = .{ .builtin = builtin },
                // Preserve the existing AgentLoop prefetch policy for selected
                // built-ins. The extra gate exists only to keep Host and
                // unselected entries out of the prefetch path.
                .prefetch_safe = true,
            });
        }

        for (host_tools) |host| {
            if (host.definition.name.len == 0 or
                !std.mem.eql(u8, host.definition.input_schema.type, "object") or
                host.definition.server_type != null or
                host.definition.deferred) return error.InvalidHostTool;
            if (findEntry(entries.items, host.definition.name) != null) return error.DuplicateToolName;
            try entries.append(owned, .{
                .definition = try cloneDefinition(owned, host.definition),
                .executor = .{ .host_sync = .{ .ctx = host.ctx, .execute = host.execute } },
                .prefetch_safe = false,
            });
        }
        return .{ .allocator = allocator, .arena = arena, .entries = try entries.toOwnedSlice(owned) };
    }

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn find(self: *const Catalog, name: []const u8) ?*const Entry {
        return findEntry(self.entries, name);
    }
};

fn findEntry(entries: []const Entry, name: []const u8) ?*const Entry {
    for (entries) |*entry| if (std.mem.eql(u8, entry.definition.name, name)) return entry;
    return null;
}

fn cloneDefinition(allocator: std.mem.Allocator, source: json.ToolDefinition) std.mem.Allocator.Error!json.ToolDefinition {
    return .{
        .name = try allocator.dupe(u8, source.name),
        .description = try allocator.dupe(u8, source.description),
        .input_schema = try cloneInputSchema(allocator, source.input_schema),
        .server_type = null,
        .deferred = false,
    };
}

fn cloneInputSchema(allocator: std.mem.Allocator, source: json.InputSchema) std.mem.Allocator.Error!json.InputSchema {
    return .{
        .type = try allocator.dupe(u8, source.type),
        .properties = if (source.properties) |properties| try cloneObject(allocator, properties) else null,
        .prop_specs = if (source.prop_specs) |specs| try clonePropSpecs(allocator, specs) else null,
        .required = if (source.required) |required| try cloneStrings(allocator, required) else null,
    };
}

fn cloneStrings(allocator: std.mem.Allocator, source: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const out = try allocator.alloc([]const u8, source.len);
    for (source, 0..) |value, i| out[i] = try allocator.dupe(u8, value);
    return out;
}

fn clonePropSpecs(allocator: std.mem.Allocator, source: []const json.PropSpec) std.mem.Allocator.Error![]const json.PropSpec {
    const out = try allocator.alloc(json.PropSpec, source.len);
    for (source, 0..) |spec, i| {
        out[i] = .{
            .name = try allocator.dupe(u8, spec.name),
            .type = try allocator.dupe(u8, spec.type),
            .description = try allocator.dupe(u8, spec.description),
            .items_type = if (spec.items_type) |value| try allocator.dupe(u8, value) else null,
            .enum_values = if (spec.enum_values) |values| try cloneStrings(allocator, values) else null,
            .items_props = if (spec.items_props) |values| try clonePropSpecs(allocator, values) else null,
            .items_required = if (spec.items_required) |values| try cloneStrings(allocator, values) else null,
            .object_props = if (spec.object_props) |values| try clonePropSpecs(allocator, values) else null,
            .object_required = if (spec.object_required) |values| try cloneStrings(allocator, values) else null,
        };
    }
    return out;
}

fn cloneObject(allocator: std.mem.Allocator, source: std.json.ObjectMap) std.mem.Allocator.Error!std.json.ObjectMap {
    var out: std.json.ObjectMap = .empty;
    var it = source.iterator();
    while (it.next()) |item| {
        try out.put(allocator, try allocator.dupe(u8, item.key_ptr.*), try cloneValue(allocator, item.value_ptr.*));
    }
    return out;
}

fn cloneValue(allocator: std.mem.Allocator, source: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    return switch (source) {
        .null => .null,
        .bool => |value| .{ .bool = value },
        .integer => |value| .{ .integer = value },
        .float => |value| .{ .float = value },
        .number_string => |value| .{ .number_string = try allocator.dupe(u8, value) },
        .string => |value| .{ .string = try allocator.dupe(u8, value) },
        .array => |array| blk: {
            var out = std.json.Array.init(allocator);
            for (array.items) |value| try out.append(try cloneValue(allocator, value));
            break :blk .{ .array = out };
        },
        .object => |object| .{ .object = try cloneObject(allocator, object) },
    };
}

pub const Selection = struct {
    allocator: std.mem.Allocator,
    entries: []*const Entry,
    definitions: []json.ToolDefinition,

    pub fn init(allocator: std.mem.Allocator, catalog: *const Catalog, allowlist: []const []const u8) !Selection {
        var selected = try std.ArrayList(*const Entry).initCapacity(allocator, allowlist.len);
        errdefer selected.deinit(allocator);
        var definitions = try std.ArrayList(json.ToolDefinition).initCapacity(allocator, allowlist.len);
        errdefer definitions.deinit(allocator);

        for (allowlist) |name| {
            for (selected.items) |existing| {
                if (std.mem.eql(u8, existing.definition.name, name)) return error.DuplicateToolName;
            }
            const entry = catalog.find(name) orelse return error.ToolNotInRuntime;
            try selected.append(allocator, entry);
            try definitions.append(allocator, entry.definition);
        }

        const entries_owned = try selected.toOwnedSlice(allocator);
        errdefer allocator.free(entries_owned);
        const definitions_owned = try definitions.toOwnedSlice(allocator);
        return .{
            .allocator = allocator,
            .entries = entries_owned,
            .definitions = definitions_owned,
        };
    }

    pub fn deinit(self: *Selection) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.definitions);
        self.* = undefined;
    }

    pub fn find(self: *const Selection, name: []const u8) ?*const Entry {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.definition.name, name)) return entry;
        }
        return null;
    }

    pub fn contains(self: *const Selection, name: []const u8) bool {
        return self.find(name) != null;
    }

    pub fn dispatcher(self: *const Selection) tools.ToolDispatcher {
        return .{ .ctx = @ptrCast(self), .dispatchFn = dispatch, .prefetchSafeFn = prefetchSafe, .nameAtFn = nameAt, .hostSyncFn = hostSync };
    }

    fn dispatch(raw: *const anyopaque, tool_ctx: *const tools.ToolContext, name: []const u8, args: []const u8) anyerror!tools.ToolDispatchOutcome {
        const self: *const Selection = @ptrCast(@alignCast(raw));
        const entry = self.find(name) orelse return error.UnknownTool;
        switch (entry.executor) {
            .builtin => |builtin| {
                try tools.validateRequired(builtin.name, args);
                try tools.validateTypes(builtin.name, args);
                return .{ .ok = try builtin.execute(tool_ctx, args) };
            },
            .host_sync => |host| {
                // Identity is admission-fixed and passed by value; a selected
                // Host tool without identity is a wiring bug, not a tool error.
                const identity = tool_ctx.host_run orelse return error.HostRunIdentityMissing;
                const outcome = try host.execute(host.ctx, identity, args);
                // Ownership chain: Host descriptor is copied into
                // tool_ctx.allocator and released here exactly once — on the
                // success path, the detail paths and the copy-OOM path alike.
                switch (outcome) {
                    .ok => |result| {
                        defer result.release();
                        return .{ .ok = try tool_ctx.allocator.dupe(u8, result.bytes) };
                    },
                    .failed => |maybe| {
                        const detail = try copyDetail(tool_ctx.allocator, maybe);
                        return .{ .host_failed = detail };
                    },
                    .rejected => |maybe| {
                        const detail = try copyDetail(tool_ctx.allocator, maybe);
                        return .{ .host_rejected = detail };
                    },
                    .fatal => return .host_fatal,
                }
            },
        }
    }

    /// Copies an optional Host detail into the caller allocator and releases
    /// the Host descriptor exactly once, including on copy failure.
    fn copyDetail(allocator: std.mem.Allocator, maybe: ?HostToolResult) error{OutOfMemory}!?[]u8 {
        const result = maybe orelse return null;
        defer result.release();
        return try allocator.dupe(u8, result.bytes);
    }

    fn prefetchSafe(raw: *const anyopaque, name: []const u8) bool {
        const self: *const Selection = @ptrCast(@alignCast(raw));
        const entry = self.find(name) orelse return false;
        return entry.prefetch_safe;
    }

    fn hostSync(raw: *const anyopaque, name: []const u8) bool {
        const self: *const Selection = @ptrCast(@alignCast(raw));
        const entry = self.find(name) orelse return false;
        return entry.executor == .host_sync;
    }

    fn nameAt(raw: *const anyopaque, index: usize) ?[]const u8 {
        const self: *const Selection = @ptrCast(@alignCast(raw));
        if (index >= self.entries.len) return null;
        return self.entries[index].definition.name;
    }
};

test "Selection rejects names outside Runtime and dispatches only selected entries" {
    var catalog = try Catalog.initBuiltins(std.testing.allocator, &.{ "Read", "Grep" });
    defer catalog.deinit();
    var selection = try Selection.init(std.testing.allocator, &catalog, &.{"Read"});
    defer selection.deinit();

    try std.testing.expect(selection.contains("Read"));
    try std.testing.expect(!selection.contains("Grep"));
    try std.testing.expectError(error.ToolNotInRuntime, Selection.init(std.testing.allocator, &catalog, &.{"Bash"}));

    var ctx = tools.ToolContext{ .allocator = std.testing.allocator, .tool_dispatcher = selection.dispatcher() };
    try std.testing.expectError(error.UnknownTool, tools.dispatch(&ctx, "Grep", "{}"));
    const names = try tools.availableToolNames(&ctx, std.testing.allocator);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqualStrings("Read", names);
    try std.testing.expect(tools.suggestToolName(&ctx, "Grepp") == null);
}

const HostProbe = struct {
    calls: usize = 0,
    releases: usize = 0,
    last_session: SessionIdT = SessionIdT.single,
    last_run_id: u64 = 0,
    last_host_ctx: ?*anyopaque = null,

    const SessionIdT = @import("session_id.zig").SessionId;

    fn execute(raw: *anyopaque, identity: HostRunIdentity, args: []const u8) error{OutOfMemory}!HostToolOutcome {
        const self: *HostProbe = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.last_session = identity.identity.session_id;
        self.last_run_id = identity.identity.run_id;
        self.last_host_ctx = identity.host_session_ctx;
        return .{ .ok = .{ .bytes = args, .release_ctx = raw, .releaseFn = release } };
    }

    fn release(raw: *anyopaque, _: []const u8) void {
        const self: *HostProbe = @ptrCast(@alignCast(raw));
        self.releases += 1;
    }
};

fn testIdentity(anchor: *anyopaque) HostRunIdentity {
    return .{
        .identity = .{ .session_id = @import("session_id.zig").SessionId.single, .run_id = 7 },
        .host_session_ctx = anchor,
    };
}

fn hostTool(name: []const u8, probe: *HostProbe) HostSyncTool {
    return .{
        .definition = .{
            .name = name,
            .description = "Host echo",
            .input_schema = .{
                .type = "object",
                .prop_specs = &.{.{ .name = "text", .type = "string" }},
                .required = &.{"text"},
            },
        },
        .ctx = probe,
        .execute = HostProbe.execute,
    };
}

test "Host sync entry is Runtime-owned, selected once and released once" {
    var probe = HostProbe{};
    var name = [_]u8{ 'H', 'o', 's', 't', 'E', 'c', 'h', 'o' };
    var catalog = try Catalog.init(std.testing.allocator, &.{"Read"}, &.{hostTool(&name, &probe)});
    defer catalog.deinit();
    name[0] = 'X';

    var selection = try Selection.init(std.testing.allocator, &catalog, &.{"HostEcho"});
    defer selection.deinit();
    const dispatcher = selection.dispatcher();
    try std.testing.expect(!dispatcher.prefetchSafe("HostEcho"));
    try std.testing.expect(dispatcher.isHostSync("HostEcho"));
    var ctx = tools.ToolContext{
        .allocator = std.testing.allocator,
        .session_id = "session-a",
        .host_run = testIdentity(@ptrCast(&probe)),
        .tool_dispatcher = dispatcher,
    };
    var outcome = try tools.dispatch(&ctx, "HostEcho", "{\"text\":\"ok\"}");
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\"text\":\"ok\"}", outcome.ok);
    try std.testing.expectEqual(@as(u64, 7), probe.last_run_id);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&probe)), probe.last_host_ctx);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);
    // 身份缺失是接线 bug,不是工具错误——独立错误码,不落模型可见面。
    ctx.host_run = null;
    try std.testing.expectError(error.HostRunIdentityMissing, tools.dispatch(&ctx, "HostEcho", "{\"text\":\"x\"}"));
}

test "Host sync names cannot duplicate built-ins or each other" {
    var first = HostProbe{};
    var second = HostProbe{};
    try std.testing.expectError(error.DuplicateToolName, Catalog.init(std.testing.allocator, &.{"Read"}, &.{hostTool("Read", &first)}));
    try std.testing.expectError(error.DuplicateToolName, Catalog.init(std.testing.allocator, &.{}, &.{ hostTool("HostEcho", &first), hostTool("HostEcho", &second) }));
}

test "Host sync registration rejects non-object tool schemas" {
    var probe = HostProbe{};
    var invalid = hostTool("HostArray", &probe);
    invalid.definition.input_schema.type = "array";
    try std.testing.expectError(error.InvalidHostTool, Catalog.init(std.testing.allocator, &.{}, &.{invalid}));
}

test "Host sync selections sharing one Runtime keep executors isolated" {
    var first = HostProbe{};
    var second = HostProbe{};
    var catalog = try Catalog.init(std.testing.allocator, &.{}, &.{ hostTool("HostA", &first), hostTool("HostB", &second) });
    defer catalog.deinit();
    var selection_a = try Selection.init(std.testing.allocator, &catalog, &.{"HostA"});
    defer selection_a.deinit();
    var selection_b = try Selection.init(std.testing.allocator, &catalog, &.{"HostB"});
    defer selection_b.deinit();

    var ctx_a = tools.ToolContext{ .allocator = std.testing.allocator, .host_run = testIdentity(@ptrCast(&first)), .tool_dispatcher = selection_a.dispatcher() };
    var ctx_b = tools.ToolContext{ .allocator = std.testing.allocator, .host_run = testIdentity(@ptrCast(&second)), .tool_dispatcher = selection_b.dispatcher() };
    var outcome_a = try tools.dispatch(&ctx_a, "HostA", "{\"text\":\"a\"}");
    defer outcome_a.deinit(std.testing.allocator);
    var outcome_b = try tools.dispatch(&ctx_b, "HostB", "{\"text\":\"b\"}");
    defer outcome_b.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnknownTool, tools.dispatch(&ctx_a, "HostB", "{\"text\":\"x\"}"));
    try std.testing.expectEqual(@as(usize, 1), first.calls);
    try std.testing.expectEqual(@as(usize, 1), second.calls);
}

test "Host outcome detail is copied, released once and typed through dispatch" {
    const DetailProbe = struct {
        releases: usize = 0,
        mode: enum { failed_with_detail, rejected_null, fatal } = .failed_with_detail,

        fn execute(raw: *anyopaque, _: HostRunIdentity, _: []const u8) error{OutOfMemory}!HostToolOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return switch (self.mode) {
                .failed_with_detail => .{ .failed = .{ .bytes = "field 'x' is invalid", .release_ctx = raw, .releaseFn = release } },
                .rejected_null => .{ .rejected = null },
                .fatal => .fatal,
            };
        }

        fn release(raw: *anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.releases += 1;
        }
    };
    var probe = DetailProbe{};
    var catalog = try Catalog.init(std.testing.allocator, &.{}, &.{.{
        .definition = .{
            .name = "HostDetail",
            .description = "detail probe",
            .input_schema = .{ .type = "object", .prop_specs = &.{}, .required = &.{} },
        },
        .ctx = &probe,
        .execute = DetailProbe.execute,
    }});
    defer catalog.deinit();
    var selection = try Selection.init(std.testing.allocator, &catalog, &.{"HostDetail"});
    defer selection.deinit();
    var ctx = tools.ToolContext{ .allocator = std.testing.allocator, .host_run = testIdentity(@ptrCast(&probe)), .tool_dispatcher = selection.dispatcher() };

    var failed = try tools.dispatch(&ctx, "HostDetail", "{}");
    defer failed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("field 'x' is invalid", failed.host_failed.?);
    try std.testing.expectEqual(@as(usize, 1), probe.releases); // 详情复制后恰好释放一次

    probe.mode = .rejected_null;
    var rejected = try tools.dispatch(&ctx, "HostDetail", "{}");
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expect(rejected.host_rejected == null);
    try std.testing.expectEqual(@as(usize, 1), probe.releases); // null 详情无描述符可释放

    probe.mode = .fatal;
    const fatal = try tools.dispatch(&ctx, "HostDetail", "{}");
    try std.testing.expect(fatal == .host_fatal); // fatal 无 payload
}
