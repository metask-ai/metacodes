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
            if (ctx.execution_policy) |policy| {
                if (!policy.allowsTool(name)) continue;
            }
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
            if (ctx.execution_policy) |policy| {
                if (!policy.allowsTool(t.name)) continue;
            }
            if (matched.items.len >= max_results) break;
            if (matchesKeywords(query, t.name, t.description)) try matched.append(allocator, t.name);
        }
        if (ctx.dyn_registry) |dr| {
            for (dr.entries.items) |*e| {
                if (!e.deferred) continue;
                if (ctx.execution_policy) |policy| {
                    if (!policy.allowsTool(e.name)) continue;
                }
                if (matched.items.len >= max_results) break;
                if (matchesKeywords(query, e.name, e.description)) try matched.append(allocator, e.name);
            }
        }
    }

    if (matched.items.len == 0) {
        // 落空时把现在真能激活的 deferred 名单直接给模型:比"去 system prompt 找"有用——
        // 动态(MCP)工具的名字模型未必记得,关键字匹配又是 AND 语义,一次猜错就该有出路。
        const available = try availableDeferredNames(ctx, allocator);
        defer allocator.free(available);
        if (available.len > 0) {
            setDetail(ctx, allocator, "No deferred tool matched query \"{s}\". Deferred tools available right now: {s}. Use select:<exact_name> to fetch one, or fewer keywords (every keyword must appear in one tool's name or description).", .{ query, available });
        } else {
            setDetail(ctx, allocator, "No deferred tool matched query \"{s}\": no deferred tools are registered in this session (no MCP server or plugin tool is connected). Use the tools already in your tool list.", .{query});
        }
        return error.NoToolMatch;
    }

    // 激活每个命中工具(经 trampoline 写入 App.activated 集),并拼 <functions> schema。
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("<functions>\n");
    for (matched.items) |name| {
        // 激活失败安全吞:下一轮该工具没进 tools 数组,模型最多重试一次,无正确性损失
        // (区别于 skill 激活——那个 catch 记 log,因激活态影响权限判定)。
        if (ctx.host_services) |hs| hs.activateTool(name) catch {};
        // 静态工具用 toolSchemaJson;dyn(MCP)工具从 DynRegistry 条目建 schema。
        const schema: []u8 = tools.toolSchemaJson(allocator, name) catch blk: {
            const dr = ctx.dyn_registry orelse return error.UnknownTool;
            const e = dr.find(name) orelse return error.UnknownTool;
            // 有借用的完整 schema(MCP inputSchema / 插件定义)就给模型完整参数;
            // 只有 required 名单的旧式注册才退化成空 properties。
            const def = json_mod.ToolDefinition{
                .name = e.name,
                .description = e.description,
                .input_schema = e.borrowed_input_schema orelse .{ .type = "object", .properties = null, .required = e.required_fields },
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

/// 本 session 当前可激活的 deferred 工具名(静态 deferred 受执行策略/TinyKG 门控;动态
/// deferred = MCP/插件)。逗号分隔,超过 `MAX_LISTED_NAMES` 个只给前面的加计数。owned。
pub const MAX_LISTED_NAMES: usize = 40;

fn availableDeferredNames(ctx: *const ToolContext, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var count: usize = 0;
    var omitted: usize = 0;
    for (tools.registry) |*t| {
        if (!t.deferred) continue;
        if (t.tinykg_gated and ctx.kg == null) continue;
        if (ctx.execution_policy) |policy| if (!policy.allowsTool(t.name)) continue;
        try appendName(allocator, &out, t.name, &count, &omitted);
    }
    if (ctx.dyn_registry) |dr| {
        for (dr.entries.items) |*e| {
            if (!e.deferred) continue;
            if (ctx.execution_policy) |policy| if (!policy.allowsTool(e.name)) continue;
            try appendName(allocator, &out, e.name, &count, &omitted);
        }
    }
    if (omitted > 0) try out.print(allocator, ", … ({d} more)", .{omitted});
    return try out.toOwnedSlice(allocator);
}

fn appendName(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, count: *usize, omitted: *usize) !void {
    if (count.* >= MAX_LISTED_NAMES) {
        omitted.* += 1;
        return;
    }
    if (count.* > 0) try out.appendSlice(allocator, ", ");
    try out.appendSlice(allocator, name);
    count.* += 1;
}

/// query 的每个空白分词都要在 name 或 description 里出现(忽略大小写)才算命中(AND 语义,
/// 对齐 cc)。不经定长栈缓冲:MCP server 的描述动辄上 KB,旧实现 512 字节的 bufPrint 一
/// 溢出就整条返回 false——描述越详尽的工具越搜不到。
fn matchesKeywords(query: []const u8, name: []const u8, description: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, query, " \t,");
    var any = false;
    while (it.next()) |tok| {
        any = true;
        if (std.ascii.indexOfIgnoreCase(name, tok) == null and
            std.ascii.indexOfIgnoreCase(description, tok) == null) return false;
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

fn dynExecBody(_: *const ToolContext, _: []const u8, _: ?*anyopaque) anyerror!@import("context.zig").ToolResultBody {
    return @import("context.zig").ToolResultBody.initInline(try testing.allocator.dupe(u8, "ok"));
}

test "ToolSearch: select 静态工具返回 schema + 激活" {
    const a = testing.allocator;
    test_activated = .empty;
    defer test_activated.deinit(a);
    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = a,
        .host_services = .{ .ctx = @ptrCast(&dummy), .activateToolFn = &testActivate },
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
        .host_services = .{ .ctx = @ptrCast(&dummy), .activateToolFn = &testActivate },
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

test "ToolSearch: 落空时 detail 列出当前可激活的 deferred 工具名(含 MCP)" {
    const a = testing.allocator;
    var dyn = DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("knowforge__search", "Search the knowledge base", &.{}, dynExec, null, true);
    try dyn.register("knowforge__overview", "Knowledge base overview", &.{}, dynExec, null, true);
    try dyn.register("skill__resident", "resident tool, not deferred", &.{}, dynExec, null, false);
    var detail: ?[]const u8 = null;
    defer if (detail) |d| a.free(d);
    const ctx = ToolContext{ .allocator = a, .dyn_registry = &dyn, .error_detail = &detail };
    // AND 语义:一个工具名里不可能同时含 list_knowledge_bases 和 overview → 落空。
    try testing.expectError(error.NoToolMatch, execute(&ctx, "{\"query\":\"knowforge list_knowledge_bases overview\"}"));
    const d = detail orelse return error.TestExpectedDetail;
    try testing.expect(std.mem.indexOf(u8, d, "knowforge__search") != null);
    try testing.expect(std.mem.indexOf(u8, d, "knowforge__overview") != null);
    try testing.expect(std.mem.indexOf(u8, d, "skill__resident") == null);
    try testing.expect(std.mem.indexOf(u8, d, "select:<exact_name>") != null);
    // 静态 deferred 受同样的门控:唯一的静态 deferred(FormalAuditTask)是 TinyKG 门控,
    // 本 ctx 没有 kg → 不列(列了模型也激活不了)。
    try testing.expect(std.mem.indexOf(u8, d, "FormalAuditTask") == null);
}

test "ToolSearch: select MCP 工具时 <function> 块带完整 inputSchema(properties/required)" {
    const a = testing.allocator;
    test_activated = .empty;
    defer test_activated.deinit(a);
    var dyn = DynRegistry.init(a);
    defer dyn.deinit();
    var inner: std.json.ObjectMap = .empty;
    defer inner.deinit(a);
    try inner.put(a, "type", .{ .string = "string" });
    var props: std.json.ObjectMap = .empty;
    defer props.deinit(a);
    try props.put(a, "query", .{ .object = inner });
    const required = [_][]const u8{"query"};
    try dyn.registerMcpDefinitionBody(.{
        .name = "knowforge__search",
        .description = "Search a knowledge base",
        .input_schema = .{ .type = "object", .properties = props, .required = &required },
        .deferred = true,
        .mcp_server = "knowforge",
    }, dynExecBody, null, "knowforge");
    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = a,
        .dyn_registry = &dyn,
        .host_services = .{ .ctx = @ptrCast(&dummy), .activateToolFn = &testActivate },
    };
    const out = try execute(&ctx, "{\"query\":\"select:knowforge__search\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"query\":{\"type\":\"string\"}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"required\":[\"query\"]") != null);
    try testing.expectEqualStrings("knowforge__search", test_activated.items[0]);
}

test "ToolSearch: 长描述(>512B)的 MCP 工具关键字仍可命中" {
    const a = testing.allocator;
    test_activated = .empty;
    defer test_activated.deinit(a);
    var dyn = DynRegistry.init(a);
    defer dyn.deinit();
    const long_desc = "Search fragments in a knowledge base by keyword. " ++ ("Lorem ipsum dolor sit amet, consectetur adipiscing elit. " ** 12) ++ " Returns matching fragments with source file names.";
    comptime std.debug.assert(long_desc.len > 512);
    try dyn.register("knowforge__search", long_desc, &.{}, dynExec, null, true);
    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = a,
        .dyn_registry = &dyn,
        .host_services = .{ .ctx = @ptrCast(&dummy), .activateToolFn = &testActivate },
    };
    const out = try execute(&ctx, "{\"query\":\"KNOWFORGE fragments\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "knowforge__search") != null);
}

test "ToolSearch: 关键字不命中常驻内置工具(它们非 deferred)" {
    const a = testing.allocator;
    // 无 dyn registry → 无 deferred 工具;关键字 "edit" 不应命中 core Edit。
    var detail: ?[]const u8 = null;
    const ctx = ToolContext{ .allocator = a, .error_detail = &detail };
    try testing.expectError(error.NoToolMatch, execute(&ctx, "{\"query\":\"edit file\"}"));
    if (detail) |d| a.free(d);
}
