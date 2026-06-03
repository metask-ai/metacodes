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

/// 动态工具执行函数：多一个 `ctx_ptr` 让闭包式实现能恢复状态。
pub const DynExecuteFn = *const fn (
    ctx: *const ToolContext,
    args: []const u8,
    ctx_ptr: ?*anyopaque,
) anyerror![]u8;

pub const DynToolEntry = struct {
    name: []const u8, // owned
    description: []const u8, // owned
    required_fields: []const []const u8 = &.{}, // owned（每个 entry + slice）
    execute: DynExecuteFn,
    ctx_ptr: ?*anyopaque = null,
    /// deferred(对齐 cc isMcp→defer):MCP 工具 true → 不进默认 tools 数组,经 ToolSearch
    /// 激活才发。Skill 工具 false(它是单个常驻工具)。
    deferred: bool = false,
};

pub const DynRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(DynToolEntry),

    pub fn init(allocator: std.mem.Allocator) DynRegistry {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *DynRegistry) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.name);
            self.allocator.free(e.description);
            for (e.required_fields) |f| self.allocator.free(f);
            self.allocator.free(e.required_fields);
        }
        self.entries.deinit(self.allocator);
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
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return error.ToolAlreadyRegistered;
        }
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        const desc_owned = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_owned);

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
            .execute = execute,
            .ctx_ptr = ctx_ptr,
            .deferred = deferred,
        });
    }

    pub fn find(self: *const DynRegistry, name: []const u8) ?*const DynToolEntry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
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
                .input_schema = .{
                    .type = "object",
                    .properties = null,
                    .required = e.required_fields,
                },
                .deferred = e.deferred,
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

test "DynRegistry: execute dispatches to fn" {
    var r = DynRegistry.init(testing.allocator);
    defer r.deinit();
    try r.register("dummy", "d", &.{}, dummyExec, null, false);
    const e = r.find("dummy").?;
    const ctx = ToolContext.simple(testing.allocator);
    const out = try e.execute(&ctx, "{}", e.ctx_ptr);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("dummy-result", out);
}
