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
const sync = @import("platform").sync;
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
    /// Explicit permission classification. A process tool registers its own
    /// and an MCP tool definition is always `.execute`
    /// (`registerMcpDefinitionBody`). Null keeps the legacy name-based
    /// fallback (`permission/category.zig`): the Skill tool, and the
    /// per-server resource tools `McpSession.registerResourceTools` adds.
    category: ?ToolCategory = null,
    retired: std.atomic.Value(bool) = .init(false),

    pub fn isLive(self: *const DynToolEntry) bool {
        return !self.retired.load(.acquire);
    }

    pub fn definition(self: *const DynToolEntry) json.ToolDefinition {
        return .{
            .name = self.name,
            .description = self.description,
            .input_schema = self.borrowed_input_schema orelse .{
                .type = "object",
                .properties = null,
                .required = self.required_fields,
            },
            .deferred = self.deferred,
            .mcp_server = self.mcp_server,
        };
    }

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
    mutex: sync.Mutex = .{},
    entries: std.ArrayList(*DynToolEntry),

    pub fn init(allocator: std.mem.Allocator) DynRegistry {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *DynRegistry) void {
        for (self.entries.items) |e| self.freeEntry(e);
        self.entries.deinit(self.allocator);
    }

    fn freeEntry(self: *DynRegistry, e: *DynToolEntry) void {
        self.allocator.free(e.name);
        self.allocator.free(e.description);
        if (e.mcp_server) |server| self.allocator.free(server);
        for (e.required_fields) |f| self.allocator.free(f);
        self.allocator.free(e.required_fields);
        self.allocator.destroy(e);
    }

    pub fn len(self: *const DynRegistry) usize {
        const mutable: *DynRegistry = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();
        return self.entries.items.len;
    }

    pub fn entryAt(self: *const DynRegistry, index: usize) ?*const DynToolEntry {
        const mutable: *DynRegistry = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index];
    }

    pub fn rollbackTo(self: *DynRegistry, checkpoint: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(checkpoint <= self.entries.items.len);
        for (self.entries.items[checkpoint..]) |e| e.retired.store(true, .release);
    }

    pub fn retireMcpServer(self: *DynRegistry, server: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var retired: usize = 0;
        for (self.entries.items) |e| {
            const owned = if (e.mcp_server) |name| std.mem.eql(u8, name, server) else false;
            if (owned and e.isLive()) {
                e.retired.store(true, .release);
                retired += 1;
            }
        }
        return retired;
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
        return self.registerImpl(name, description, required_fields, .{ .legacy_inline = execute }, ctx_ptr, deferred, null, .{});
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
        return self.registerImpl(name, description, required_fields, .{ .result_body = execute }, ctx_ptr, deferred, null, .{});
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
        return self.registerImpl(name, description, required_fields, .{ .legacy_inline = execute }, ctx_ptr, true, server_name, .{});
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
        return self.registerImpl(name, description, required_fields, .{ .result_body = execute }, ctx_ptr, true, server_name, .{});
    }

    /// MCP 工具带完整 inputSchema 注册:名字/描述/required 拷贝,`input_schema` 的嵌套
    /// 存储**借用**(由 McpSession 的 schema_arena 持有,随 session 存亡)。deferred 强制
    /// true(MCP 工具经 ToolSearch 激活),mcp_server 标记来源供 AgentDef.mcpServers 过滤。
    ///
    /// The entry is classified `.execute`: an MCP tool is a call into another
    /// process or service, which may change things outside this machine, so
    /// default, acceptEdits and auto ask before it runs and dontAsk denies it.
    /// AgentCore's MCP environment declares the same class
    /// (`agentcore/mcp_session.zig`, `metadata`). The server's annotations
    /// (`readOnlyHint` and the rest) are the server's own claim and never
    /// relax it (#473). An allow rule (`mcp__<server>`) is how a person
    /// trusts a server.
    pub fn registerMcpDefinitionBody(
        self: *DynRegistry,
        definition: json.ToolDefinition,
        execute: DynExecuteBodyFn,
        ctx_ptr: ?*anyopaque,
        server_name: []const u8,
    ) !void {
        if (server_name.len == 0) return error.InvalidMcpServerName;
        if (definition.server_type != null or !std.mem.eql(u8, definition.input_schema.type, "object"))
            return error.InvalidDynamicDefinition;
        try self.registerImpl(
            definition.name,
            definition.description,
            definition.input_schema.required orelse &.{},
            .{ .result_body = execute },
            ctx_ptr,
            true,
            server_name,
            .{ .borrowed_input_schema = definition.input_schema, .category = .execute },
        );
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
            .{ .borrowed_input_schema = definition.input_schema, .category = native_category },
        );
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
            .{ .borrowed_input_schema = definition.input_schema, .category = native_category },
        );
    }

    const Extra = struct {
        borrowed_input_schema: ?json.InputSchema = null,
        category: ?ToolCategory = null,
    };

    fn registerImpl(
        self: *DynRegistry,
        name: []const u8,
        description: []const u8,
        required_fields: []const []const u8,
        executor: DynExecutor,
        ctx_ptr: ?*anyopaque,
        deferred: bool,
        mcp_server: ?[]const u8,
        extra: Extra,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.findLocked(name) != null) return error.ToolAlreadyRegistered;
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const entry = try self.allocator.create(DynToolEntry);
        errdefer self.allocator.destroy(entry);
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

        entry.* = .{
            .name = name_owned,
            .description = desc_owned,
            .required_fields = req_owned,
            .executor = executor,
            .ctx_ptr = ctx_ptr,
            .deferred = deferred,
            .mcp_server = server_owned,
            .borrowed_input_schema = extra.borrowed_input_schema,
            .category = extra.category,
        };
        self.entries.appendAssumeCapacity(entry);
    }

    fn findLocked(self: *const DynRegistry, name: []const u8) ?*DynToolEntry {
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            const e = self.entries.items[index];
            if (e.isLive() and std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    pub fn find(self: *const DynRegistry, name: []const u8) ?*const DynToolEntry {
        const mutable: *DynRegistry = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();
        return self.findLocked(name);
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
        const mutable: *DynRegistry = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();
        for (self.entries.items) |e| {
            if (!e.isLive()) continue;
            try defs.append(allocator, e.definition());
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

test "DynRegistry: retiring one MCP server hides exactly its tools, keeps the others in order, and frees the names" {
    var r = DynRegistry.init(testing.allocator);
    defer r.deinit();
    try r.register("Skill", "skill", &.{}, dummyExec, null, false);
    try r.registerMcp("mcp__a__one", "a1", &.{"x"}, dummyExec, null, "a");
    try r.registerMcp("mcp__b__one", "b1", &.{}, dummyExec, null, "b");
    try r.registerMcp("mcp__a__two", "a2", &.{}, dummyExec, null, "a");
    try r.registerMcp("mcp__ab__one", "ab1", &.{}, dummyExec, null, "ab");
    const before = r.find("mcp__a__one").?;
    try testing.expectEqual(@as(usize, 2), r.retireMcpServer("a"));
    try testing.expect(!before.isLive());
    try testing.expectEqualStrings("a1", before.description);

    var defs = std.ArrayList(json.ToolDefinition).empty;
    defer defs.deinit(testing.allocator);
    try r.appendDefinitions(&defs, testing.allocator);
    try testing.expectEqual(@as(usize, 3), defs.items.len);
    try testing.expectEqualStrings("Skill", defs.items[0].name);
    try testing.expectEqualStrings("mcp__b__one", defs.items[1].name);
    try testing.expectEqualStrings("mcp__ab__one", defs.items[2].name);
    try testing.expect(r.find("mcp__a__one") == null);
    try testing.expectEqual(@as(usize, 0), r.retireMcpServer("missing"));
    try testing.expectEqual(@as(usize, 5), r.len());

    try r.registerMcp("mcp__a__one", "a1 again", &.{}, dummyExec, null, "a");
    try testing.expectEqualStrings("a1 again", r.find("mcp__a__one").?.description);
    try testing.expectEqualStrings("a1", before.description);
}

test "DynRegistry: a rolled-back batch is retired, not freed" {
    var r = DynRegistry.init(testing.allocator);
    defer r.deinit();
    try r.registerMcp("mcp__a__one", "a1", &.{}, dummyExec, null, "a");
    const checkpoint = r.len();
    try r.registerMcp("mcp__a__two", "a2", &.{}, dummyExec, null, "a");
    const found = r.find("mcp__a__two").?;
    r.rollbackTo(checkpoint);
    try testing.expect(r.find("mcp__a__two") == null);
    try testing.expect(r.find("mcp__a__one") != null);
    try testing.expectEqualStrings("a2", found.description);
    try testing.expect(!found.isLive());
}

const LookupRace = struct {
    registry: *DynRegistry,
    stop: std.atomic.Value(bool) = .init(false),
    found: std.atomic.Value(usize) = .init(0),

    fn run(race: *LookupRace) void {
        while (!race.stop.load(.acquire)) {
            if (race.registry.find("mcp__stable__tool")) |entry| {
                if (std.mem.eql(u8, entry.description, "stable")) _ = race.found.fetchAdd(1, .monotonic);
            }
            var index: usize = 0;
            while (race.registry.entryAt(index)) |entry| : (index += 1) std.mem.doNotOptimizeAway(entry.name.len);
        }
    }
};

test "DynRegistry: lookups on other threads stay valid while tools are registered and retired" {
    var r = DynRegistry.init(testing.allocator);
    defer r.deinit();
    try r.registerMcp("mcp__stable__tool", "stable", &.{}, dummyExec, null, "stable");
    var race = LookupRace{ .registry = &r };
    var threads: [3]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, LookupRace.run, .{&race});
    var round: usize = 0;
    var name_buf: [64]u8 = undefined;
    while (round < 200) : (round += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "mcp__churn__tool_{d}", .{round % 7});
        try r.registerMcp(name, "churn", &.{}, dummyExec, null, "churn");
        if (round % 7 == 6) _ = r.retireMcpServer("churn");
    }
    race.stop.store(true, .release);
    for (threads) |thread| thread.join();
    try testing.expect(race.found.load(.monotonic) > 0);
    try testing.expect(r.find("mcp__stable__tool") != null);
}

fn dummyExecBody(_: *const ToolContext, _: []const u8, _: ?*anyopaque) anyerror!ToolResultBody {
    return ToolResultBody.initInline(try testing.allocator.dupe(u8, "dummy-result"));
}

test "DynRegistry: an MCP tool definition is classified execute; Skill and resource tools keep the name fallback (#473)" {
    var r = DynRegistry.init(testing.allocator);
    defer r.deinit();
    try r.registerMcpDefinitionBody(.{
        .name = "mcp__plc__set_line_speed",
        .description = "Set the conveyor speed of line 3 in rpm.",
        .input_schema = .{ .type = "object", .required = &.{} },
        .deferred = true,
        .mcp_server = "plc",
    }, dummyExecBody, null, "plc");
    try testing.expectEqual(@as(?ToolCategory, .execute), r.category("mcp__plc__set_line_speed"));

    // Null still means "classify by name": the Skill tool and the per-server
    // resource tools (`registerMcpBody`) are left as they were.
    try r.register("Skill", "Run a skill", &.{}, dummyExec, null, false);
    try r.registerMcpBody("mcp__plc__list_resources", "List resources", &.{}, dummyExecBody, null, "plc");
    try testing.expect(r.category("Skill") == null);
    try testing.expect(r.category("mcp__plc__list_resources") == null);
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
