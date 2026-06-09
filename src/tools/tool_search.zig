//! ToolSearch:检索并激活 deferred 工具(对齐 cc ToolSearchTool)。
//!
//! deferred 工具默认不进 API tools 数组(只在 system prompt 列名),降低工具菜单
//! 稀释——弱后端(MiniMax)工具过多会乱抓 Bash 改代码的根因。模型调本工具:
//!   - query="select:Name1,Name2" → 直选这些工具
//!   - query="keyword..."        → 按名字/描述关键字匹配 deferred 工具
//! 命中的工具经 activate 回调记入 App 的 activated 集(下一轮进 tools 数组变可调),
//! 并返回它们的完整 schema 文本(<functions> 块),模型据此即可调用。

const std = @import("std");
const common = @import("common.zig");
const tools = @import("../tools.zig");
const json_mod = @import("../json.zig");
const DynRegistry = @import("dynamic.zig").DynRegistry;
const ToolContext = @import("context.zig").ToolContext;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const query = common.extractJsonArg(args, "query") orelse return error.MissingQuery;
    const max_results: usize = blk: {
        if (common.extractJsonArg(args, "max_results")) |s| {
            break :blk std.fmt.parseInt(usize, s, 10) catch 5;
        }
        break :blk 5;
    };

    // 收集 deferred 工具名(静态 registry deferred=true)。
    var matched = std.ArrayList([]const u8).empty;
    defer matched.deinit(allocator);

    const select_prefix = "select:";
    if (std.mem.startsWith(u8, query, select_prefix)) {
        // 直选:逗号分隔的精确名。静态或 dyn(MCP)命中均可。
        var it = std.mem.splitScalar(u8, query[select_prefix.len..], ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            if (name.len == 0) continue;
            if (tools.getTool(name) != null) {
                try matched.append(allocator, name);
            } else if (ctx.dyn_registry) |dr| {
                if (dr.find(name) != null) try matched.append(allocator, name);
            }
        }
    } else {
        // 关键字匹配:扫 deferred 工具(静态 deferred + dyn/MCP deferred)的 name/description。
        for (tools.registry) |*t| {
            if (!t.deferred) continue;
            if (matched.items.len >= max_results) break;
            if (matchesKeywords(query, t.name, t.description)) try matched.append(allocator, t.name);
        }
        if (ctx.dyn_registry) |dr| {
            for (dr.entries.items) |*e| {
                if (!e.deferred) continue;
                if (matched.items.len >= max_results) break;
                if (matchesKeywords(query, e.name, e.description)) try matched.append(allocator, e.name);
            }
        }
    }

    if (matched.items.len == 0) {
        setDetail(ctx, allocator, "No deferred tool matched query \"{s}\". Deferred tools are listed by name in the system prompt; use select:<exact_name> to fetch one.", .{query});
        return error.NoToolMatch;
    }

    // 激活每个命中工具(经 trampoline 写入 App.activated 集),并拼 <functions> schema。
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("<functions>\n");
    for (matched.items) |name| {
        if (ctx.tool_activator) |act| act.activate(name) catch {};
        // 静态工具用 toolSchemaJson;dyn(MCP)工具从 DynRegistry 条目建 schema。
        const schema: []u8 = tools.toolSchemaJson(allocator, name) catch blk: {
            const dr = ctx.dyn_registry orelse return error.UnknownTool;
            const e = dr.find(name) orelse return error.UnknownTool;
            const def = json_mod.ToolDefinition{
                .name = e.name,
                .description = e.description,
                .input_schema = .{ .type = "object", .properties = null, .required = e.required_fields },
            };
            var b: std.ArrayList(u8) = .empty;
            errdefer b.deinit(allocator);
            try @import("../api/request.zig").serializeOneTool(def, &b, allocator);
            break :blk try b.toOwnedSlice(allocator);
        };
        defer allocator.free(schema);
        try out.writer.print("<function>{s}</function>\n", .{schema});
    }
    try out.writer.writeAll("</functions>");
    return try out.toOwnedSlice();
}

/// query 的每个空白分词都要在 name+description(小写)里出现才算命中(AND 语义,对齐 cc)。
fn matchesKeywords(query: []const u8, name: []const u8, description: []const u8) bool {
    var buf: [512]u8 = undefined;
    const hay = std.fmt.bufPrint(&buf, "{s} {s}", .{ name, description }) catch return false;
    var lower_buf: [512]u8 = undefined;
    const hay_lower = std.ascii.lowerString(lower_buf[0..hay.len], hay);
    var it = std.mem.tokenizeAny(u8, query, " \t,");
    var any = false;
    while (it.next()) |tok| {
        any = true;
        var tb: [64]u8 = undefined;
        if (tok.len > tb.len) return false;
        const tl = std.ascii.lowerString(tb[0..tok.len], tok);
        if (std.mem.indexOf(u8, hay_lower, tl) == null) return false;
    }
    return any;
}

fn setDetail(ctx: *const ToolContext, allocator: std.mem.Allocator, comptime fmt: []const u8, a: anytype) void {
    const slot = ctx.error_detail orelse return;
    slot.* = std.fmt.allocPrint(allocator, fmt, a) catch null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

var test_activated: std.ArrayList([]const u8) = .empty;
fn testActivate(state: *anyopaque, name: []const u8) anyerror!void {
    _ = state;
    try test_activated.append(testing.allocator, name);
}

fn dynExec(_: *const ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
    return testing.allocator.dupe(u8, "ok");
}

test "ToolSearch: select 静态工具返回 schema + 激活" {
    const a = testing.allocator;
    test_activated = .empty;
    defer test_activated.deinit(a);
    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = a,
        .tool_activator = .{ .ctx = @ptrCast(&dummy), .activateFn = &testActivate },
    };
    // select 一个静态工具(Read)即可返回其 schema(select 不要求 deferred)。
    const out = try execute(&ctx, "{\"query\":\"select:Read\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "<functions>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"Read\"") != null);
    try testing.expectEqualStrings("Read", test_activated.items[0]);
}

test "ToolSearch: 关键字 + select 命中 dyn(MCP)deferred 工具" {
    const a = testing.allocator;
    test_activated = .empty;
    defer test_activated.deinit(a);
    var dyn = DynRegistry.init(a);
    defer dyn.deinit();
    // 模拟 MCP 工具(deferred=true)。
    try dyn.register("github__create_issue", "Create a GitHub issue in a repo", &.{}, dynExec, null, true);
    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = a,
        .dyn_registry = &dyn,
        .tool_activator = .{ .ctx = @ptrCast(&dummy), .activateFn = &testActivate },
    };
    // 关键字命中。
    const out1 = try execute(&ctx, "{\"query\":\"github issue\"}");
    defer a.free(out1);
    try testing.expect(std.mem.indexOf(u8, out1, "github__create_issue") != null);
    try testing.expect(std.mem.indexOf(u8, out1, "input_schema") != null);
    // select 命中。
    const out2 = try execute(&ctx, "{\"query\":\"select:github__create_issue\"}");
    defer a.free(out2);
    try testing.expect(std.mem.indexOf(u8, out2, "github__create_issue") != null);
}

test "ToolSearch: 无匹配 → NoToolMatch + detail" {
    const a = testing.allocator;
    var detail: ?[]const u8 = null;
    const ctx = ToolContext{ .allocator = a, .error_detail = &detail };
    try testing.expectError(error.NoToolMatch, execute(&ctx, "{\"query\":\"select:NoSuchToolXYZ\"}"));
    try testing.expect(detail != null);
    if (detail) |d| a.free(d);
}

test "ToolSearch: 关键字不命中常驻内置工具(它们非 deferred)" {
    const a = testing.allocator;
    // 无 dyn registry → 无 deferred 工具;关键字 "edit" 不应命中 core Edit。
    var detail: ?[]const u8 = null;
    const ctx = ToolContext{ .allocator = a, .error_detail = &detail };
    try testing.expectError(error.NoToolMatch, execute(&ctx, "{\"query\":\"edit file\"}"));
    if (detail) |d| a.free(d);
}
