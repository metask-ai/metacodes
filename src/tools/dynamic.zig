//! 动态（运行时）工具注册表。
//!
//! 内建工具（Read/Write/Edit/Glob/Bash/Grep）在 `tools.zig` 是 comptime 常量——
//! 静态已知、零开销。但 MCP / Skill 工具只能运行时加载。本模块承载这种情况。
//!
//! ToolEntry 扩展为带 `ctx_ptr: ?*anyopaque` 以让闭包式执行能从中恢复状态
//! （如 MCP client 实例指针 + tool name）。
//!
//! 生命周期：process 级（启动注册，进程退出释放）。字符串字段全部 owned。

const std = @import("std");
const json = @import("../json.zig");
const ToolContext = @import("context.zig").ToolContext;
const ToolResultBody = @import("context.zig").ToolResultBody;
const ToolCategory = @import("../permission/category.zig").ToolCategory;

/// Legacy dynamic-tool callback. `register` and `registerMcp` are the explicit
/// compatibility adapters that lift its owned bytes into `ToolResultBody`.
pub const DynLegacyExecuteFn = *const fn (
    ctx: *const ToolContext,
    args: []const u8,
    ctx_ptr: ?*anyopaque,
) anyerror![]u8;

/// Typed dynamic-tool callback. It can transfer any legal result state without
/// reconstructing or flattening an artifact envelope.
pub const DynExecuteBodyFn = *const fn (
    ctx: *const ToolContext,
    args: []const u8,
    ctx_ptr: ?*anyopaque,
) anyerror!ToolResultBody;

/// Source compatibility name for callers that still register owned bytes.
pub const DynExecuteFn = DynLegacyExecuteFn;

pub const DynExecutor = union(enum) {
    legacy_inline: DynLegacyExecuteFn,
    result_body: DynExecuteBodyFn,

    pub fn run(
        self: DynExecutor,
        ctx: *const ToolContext,
        args: []const u8,
        ctx_ptr: ?*anyopaque,
    ) anyerror!ToolResultBody {
        return switch (self) {
            .legacy_inline => |execute| ToolResultBody.initInline(try execute(ctx, args, ctx_ptr)),
            .result_body => |execute| execute(ctx, args, ctx_ptr),
        };
    }
};

pub const DynToolEntry = struct {
    name: []const u8, // owned
    description: []const u8, // owned
    required_fields: []const []const u8 = &.{}, // owned（每个 entry + slice）
    executor: DynExecutor,
    ctx_ptr: ?*anyopaque = null,
    /// deferred(对齐 cc isMcp→defer):MCP 工具 true → 不进默认 tools 数组,经 ToolSearch
    /// 激活才发。Skill 工具 false(它是单个常驻工具)。
    deferred: bool = false,
    /// owned when non-null; explicit provenance for AgentDef MCP filtering.
    mcp_server: ?[]const u8 = null,
    /// Optional full schema borrowed from a Runtime snapshot. The registrar
    /// must keep that snapshot alive until this registry is deinitialized.
    borrowed_input_schema: ?json.InputSchema = null,
    /// Explicit native permission classification. Null preserves the legacy
    /// name-based behavior for Skill/MCP tools.
    category: ?ToolCategory = null,

    pub fn execute(
        self: *const DynToolEntry,
        ctx: *const ToolContext,
        args: []const u8,
    ) anyerror!ToolResultBody {
        return self.executor.run(ctx, args, self.ctx_ptr);
    }
};

pub const DynRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(DynToolEntry),

    pub fn init(allocator: std.mem.Allocator) DynRegistry {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *DynRegistry) void {
        for (self.entries.items) |e| self.freeEntry(e);
        self.entries.deinit(self.allocator);
    }

    fn freeEntry(self: *DynRegistry, e: DynToolEntry) void {
        self.allocator.free(e.name);
        self.allocator.free(e.description);
        if (e.mcp_server) |server| self.allocator.free(server);
        for (e.required_fields) |f| self.allocator.free(f);
        self.allocator.free(e.required_fields);
    }

    /// Transaction checkpoint support for multi-tool registrars such as MCP.
    /// Entries at and after `checkpoint` are owned by this registry and are
    /// fully destroyed. This prevents a failed registration batch from
    /// leaving callable definitions whose ctx_ptr ownership was rolled back.
    pub fn rollbackTo(self: *DynRegistry, checkpoint: usize) void {
        std.debug.assert(checkpoint <= self.entries.items.len);
        for (self.entries.items[checkpoint..]) |e| self.freeEntry(e);
        self.entries.shrinkRetainingCapacity(checkpoint);
    }

    /// 注册（转移字符串所有权）。name 不能与已有冲突。
    /// deferred: MCP 工具传 true(经 ToolSearch 激活才发);Skill 等常驻工具传 false。
    pub fn register(
        self: *DynRegistry,
        name: []const u8,
        description: []const u8,
        required_fields: []const []const u8,
        execute: DynExecuteFn,
        ctx_ptr: ?*anyopaque,
        deferred: bool,
    ) !void {
        return self.registerImpl(name, description, required_fields, .{ .legacy_inline = execute }, ctx_ptr, deferred, null);
    }

    pub fn registerBody(
        self: *DynRegistry,
        name: []const u8,
        description: []const u8,
        required_fields: []const []const u8,
        execute: DynExecuteBodyFn,
        ctx_ptr: ?*anyopaque,
        deferred: bool,
    ) !void {
        return self.registerImpl(name, description, required_fields, .{ .result_body = execute }, ctx_ptr, deferred, null);
    }

    pub fn registerMcp(
        self: *DynRegistry,
        name: []const u8,
        description: []const u8,
        required_fields: []const []const u8,
        execute: DynExecuteFn,
        ctx_ptr: ?*anyopaque,
        server_name: []const u8,
    ) !void {
        if (server_name.len == 0) return error.InvalidMcpServerName;
        return self.registerImpl(name, description, required_fields, .{ .legacy_inline = execute }, ctx_ptr, true, server_name);
    }

    pub fn registerMcpBody(
        self: *DynRegistry,
        name: []const u8,
        description: []const u8,
        required_fields: []const []const u8,
        execute: DynExecuteBodyFn,
        ctx_ptr: ?*anyopaque,
        server_name: []const u8,
    ) !void {
        if (server_name.len == 0) return error.InvalidMcpServerName;
        return self.registerImpl(name, description, required_fields, .{ .result_body = execute }, ctx_ptr, true, server_name);
    }

    /// Register a definition owned by an immutable plugin snapshot. Strings
    /// used for lookup/display are still copied; nested schema storage remains
    /// borrowed so arbitrary JSON Schema can be advertised without a lossy
    /// required-fields projection.
    pub fn registerBorrowedDefinition(
        self: *DynRegistry,
        definition: json.ToolDefinition,
        execute: DynExecuteFn,
        ctx_ptr: ?*anyopaque,
        native_category: ToolCategory,
    ) !void {
        if (definition.server_type != null or definition.deferred or
            !std.mem.eql(u8, definition.input_schema.type, "object"))
            return error.InvalidDynamicDefinition;
        try self.registerImpl(
            definition.name,
            definition.description,
            definition.input_schema.required orelse &.{},
            .{ .legacy_inline = execute },
            ctx_ptr,
            false,
            null,
        );
        const entry = &self.entries.items[self.entries.items.len - 1];
        entry.borrowed_input_schema = definition.input_schema;
        entry.category = native_category;
    }

    pub fn registerBorrowedDefinitionBody(
        self: *DynRegistry,
        definition: json.ToolDefinition,
        execute: DynExecuteBodyFn,
        ctx_ptr: ?*anyopaque,
        native_category: ToolCategory,
    ) !void {
        if (definition.server_type != null or definition.deferred or
            !std.mem.eql(u8, definition.input_schema.type, "object"))
            return error.InvalidDynamicDefinition;
        try self.registerImpl(
            definition.name,
            definition.description,
            definition.input_schema.required orelse &.{},
            .{ .result_body = execute },
            ctx_ptr,
            false,
            null,
        );
        const entry = &self.entries.items[self.entries.items.len - 1];
        entry.borrowed_input_schema = definition.input_schema;
        entry.category = native_category;
    }

    fn registerImpl(
        self: *DynRegistry,
        name: []const u8,
        description: []const u8,
        required_fields: []const []const u8,
        executor: DynExecutor,
        ctx_ptr: ?*anyopaque,
        deferred: bool,
        mcp_server: ?[]const u8,
    ) !void {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return error.ToolAlreadyRegistered;
        }
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        const desc_owned = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_owned);
        const server_owned = if (mcp_server) |server| try self.allocator.dupe(u8, server) else null;
        errdefer if (server_owned) |server| self.allocator.free(server);

        var req_owned = try self.allocator.alloc([]const u8, required_fields.len);
        errdefer self.allocator.free(req_owned);
        var i: usize = 0;
        errdefer for (req_owned[0..i]) |f| self.allocator.free(f);
        while (i < required_fields.len) : (i += 1) {
            req_owned[i] = try self.allocator.dupe(u8, required_fields[i]);
        }

        try self.entries.append(self.allocator, .{
            .name = name_owned,
            .description = desc_owned,
            .required_fields = req_owned,
            .executor = executor,
            .ctx_ptr = ctx_ptr,
            .deferred = deferred,
            .mcp_server = server_owned,
        });
    }

    pub fn find(self: *const DynRegistry, name: []const u8) ?*const DynToolEntry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    pub fn category(self: *const DynRegistry, name: []const u8) ?ToolCategory {
        const entry = self.find(name) orelse return null;
        return entry.category;
    }

    /// 把动态工具的定义追加到 `defs` 列表（给 API tools 参数使用）。
    /// 调用方负责 defs 生命周期；本函数只往里 append。
    pub fn appendDefinitions(
        self: *const DynRegistry,
        defs: *std.ArrayList(json.ToolDefinition),
        allocator: std.mem.Allocator,
    ) !void {
        for (self.entries.items) |e| {
            try defs.append(allocator, .{
                .name = e.name,
                .description = e.description,
                .input_schema = e.borrowed_input_schema orelse .{
                    .type = "object",
                    .properties = null,
                    .required = e.required_fields,
                },
                .deferred = e.deferred,
                .mcp_server = e.mcp_server,
            });
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn dummyExec(_: *const ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
    return try testing.allocator.dupe(u8, "dummy-result");
}

test "DynRegistry: register + find" {
    var r = DynRegistry.init(testing.allocator);
    defer r.deinit();
    try r.register("my_tool", "description", &.{"arg1"}, dummyExec, null, false);
    const e = r.find("my_tool").?;
    try testing.expectEqualStrings("my_tool", e.name);
    try testing.expectEqualStrings("description", e.description);
    try testing.expect(e.required_fields.len == 1);
}

test "DynRegistry: duplicate register errors" {
    var r = DynRegistry.init(testing.allocator);
    defer r.deinit();
    try r.register("t", "d", &.{}, dummyExec, null, false);
    try testing.expectError(error.ToolAlreadyRegistered, r.register("t", "d", &.{}, dummyExec, null, false));
}

test "DynRegistry: find missing returns null" {
    var r = DynRegistry.init(testing.allocator);
    defer r.deinit();
    try testing.expect(r.find("nope") == null);
}

test "DynRegistry: appendDefinitions appends" {
    var r = DynRegistry.init(testing.allocator);
    defer r.deinit();
    try r.register("t1", "desc1", &.{"a"}, dummyExec, null, false);
    try r.register("t2", "desc2", &.{ "a", "b" }, dummyExec, null, false);

    var defs = std.ArrayList(json.ToolDefinition).empty;
    defer defs.deinit(testing.allocator);
    try r.appendDefinitions(&defs, testing.allocator);
    try testing.expect(defs.items.len == 2);
    try testing.expectEqualStrings("t1", defs.items[0].name);
}

test "DynRegistry: borrowed native definition preserves full schema and category" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"text\":{\"type\":\"string\",\"description\":\"payload\"}}",
        .{},
    );
    defer parsed.deinit();
    const required = [_][]const u8{"text"};
    var registry = DynRegistry.init(testing.allocator);
    defer registry.deinit();
    try registry.registerBorrowedDefinition(.{
        .name = "native_process_tool",
        .description = "native process tool",
        .input_schema = .{
            .properties = parsed.value.object,
            .required = &required,
        },
    }, dummyExec, null, .execute);

    try testing.expectEqual(ToolCategory.execute, registry.category("native_process_tool").?);
    var definitions: std.ArrayList(json.ToolDefinition) = .empty;
    defer definitions.deinit(testing.allocator);
    try registry.appendDefinitions(&definitions, testing.allocator);
    try testing.expectEqual(@as(usize, 1), definitions.items.len);
    const text_schema = definitions.items[0].input_schema.properties.?.get("text").?.object;
    try testing.expectEqualStrings("string", text_schema.get("type").?.string);
    try testing.expectEqualStrings("payload", text_schema.get("description").?.string);
    try testing.expectEqualStrings("text", definitions.items[0].input_schema.required.?[0]);
}

test "DynRegistry: MCP provenance is owned and propagated" {
    var r = DynRegistry.init(testing.allocator);
    defer r.deinit();
    var server_buf = [_]u8{ 'a', 'l', 'l', 'o', 'w', 'e', 'd' };
    try r.registerMcp("allowed__probe", "probe", &.{}, dummyExec, null, &server_buf);
    server_buf[0] = 'X';

    const entry = r.find("allowed__probe").?;
    try testing.expectEqualStrings("allowed", entry.mcp_server.?);
    try testing.expect(entry.deferred);

    var defs = std.ArrayList(json.ToolDefinition).empty;
    defer defs.deinit(testing.allocator);
    try r.appendDefinitions(&defs, testing.allocator);
    try testing.expectEqual(@as(usize, 1), defs.items.len);
    try testing.expectEqualStrings("allowed", defs.items[0].mcp_server.?);
}

test "DynRegistry: execute dispatches to fn" {
    var r = DynRegistry.init(testing.allocator);
    defer r.deinit();
    try r.register("dummy", "d", &.{}, dummyExec, null, false);
    const e = r.find("dummy").?;
    const ctx = ToolContext.simple(testing.allocator);
    var out = try e.execute(&ctx, "{}");
    defer out.deinit(testing.allocator);
    try testing.expectEqualStrings("dummy-result", out.@"inline".bytes);
}
