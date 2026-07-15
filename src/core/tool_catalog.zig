//! Immutable built-in tool catalog and per-Session selection.
//!
//! The Runtime owns `Catalog`; each Session owns a `Selection` derived from it.
//! Definitions, admission and dispatch therefore resolve through the same
//! selected `Entry`. Host executors will extend the tagged executor union later
//! without creating a parallel registry.

const std = @import("std");
const json = @import("../json.zig");
const tools = @import("../tools.zig");

pub const CatalogError = error{
    UnknownBuiltinTool,
    DuplicateToolName,
    ToolNotInRuntime,
};

pub const Executor = union(enum) {
    builtin: *const tools.ToolEntry,
};

pub const Entry = struct {
    definition: json.ToolDefinition,
    executor: Executor,
    prefetch_safe: bool,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,

    pub fn initBuiltins(allocator: std.mem.Allocator, names: []const []const u8) !Catalog {
        var entries = try std.ArrayList(Entry).initCapacity(allocator, names.len);
        errdefer entries.deinit(allocator);

        for (names) |name| {
            for (entries.items) |existing| {
                if (std.mem.eql(u8, existing.definition.name, name)) return error.DuplicateToolName;
            }
            const builtin = tools.getTool(name) orelse return error.UnknownBuiltinTool;
            try entries.append(allocator, .{
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
        return .{ .allocator = allocator, .entries = try entries.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *Catalog) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn find(self: *const Catalog, name: []const u8) ?*const Entry {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.definition.name, name)) return entry;
        }
        return null;
    }
};

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
        return .{ .ctx = @ptrCast(self), .dispatchFn = dispatch, .prefetchSafeFn = prefetchSafe, .nameAtFn = nameAt };
    }

    fn dispatch(raw: *const anyopaque, tool_ctx: *const tools.ToolContext, name: []const u8, args: []const u8) anyerror![]u8 {
        const self: *const Selection = @ptrCast(@alignCast(raw));
        const entry = self.find(name) orelse return error.UnknownTool;
        return switch (entry.executor) {
            .builtin => |builtin| blk: {
                try tools.validateRequired(builtin.name, args);
                try tools.validateTypes(builtin.name, args);
                break :blk try builtin.execute(tool_ctx, args);
            },
        };
    }

    fn prefetchSafe(raw: *const anyopaque, name: []const u8) bool {
        const self: *const Selection = @ptrCast(@alignCast(raw));
        const entry = self.find(name) orelse return false;
        return entry.prefetch_safe;
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
