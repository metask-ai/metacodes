//! ToolSearch:检索并激活 deferred 工具(对齐 cc ToolSearchTool)。
//!
//! deferred 工具默认不进 API tools 数组(只在 system prompt 列名),降低工具菜单
//! 稀释——弱后端(MiniMax)工具过多会乱抓 Bash 改代码的根因。模型调本工具:
//!   - query="select:Name1,Name2" → 直选这些工具
//!   - query="keyword..."        → 按名字/描述关键字匹配 deferred 工具
//! 命中的工具经 activate 回调记入 App 的 activated 集(下一轮进 tools 数组变可调),
//! 并返回它们的完整 schema 文本(<functions> 块),模型据此即可调用。

const std = @import("std");
const common = @import("metacodes-guard").tools.common;
const tools = @import("../tools.zig");
const json_mod = @import("metacodes-ai").json;
const capability = @import("metacodes-ai").api.capability;
const DynRegistry = @import("dynamic.zig").DynRegistry;
const ToolContext = @import("context.zig").ToolContext;
const mcp_session = @import("../core/mcp_session.zig");

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
            if (tools.getTool(name)) |t| {
                if (staticVisible(ctx, t)) try matched.append(allocator, name);
            } else if (ctx.dyn_registry) |dr| {
                if (dr.find(name)) |e| {
                    if (visibleToModel(ctx, name, e.deferred)) try matched.append(allocator, name);
                }
            }
        }
    } else {
        // 关键字匹配:扫 deferred 工具(静态 deferred + dyn/MCP deferred)的 name/description。
        for (tools.registry) |*t| {
            if (!t.deferred) continue;
            if (!staticVisible(ctx, t)) continue;
            if (matched.items.len >= max_results) break;
            if (matchesKeywords(query, t.name, t.description)) try matched.append(allocator, t.name);
        }
        if (ctx.dyn_registry) |dr| {
            var index: usize = 0;
            while (dr.entryAt(index)) |e| : (index += 1) {
                if (!e.deferred or !e.isLive()) continue;
                if (!visibleToModel(ctx, e.name, true)) continue;
                if (matched.items.len >= max_results) break;
                if (matchesKeywords(query, e.name, e.description)) try matched.append(allocator, e.name);
            }
        }
    }

    if (matched.items.len == 0) {
        try setMissDetail(ctx, allocator, query);
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
            try @import("metacodes-ai").api.request.serializeOneTool(def, &b, allocator);
            break :blk try b.toOwnedSlice(allocator);
        };
        defer allocator.free(schema);
        try out.writer.print("<function>{s}</function>\n", .{schema});
    }
    try out.writer.writeAll("</functions>");
    return try out.toOwnedSlice();
}

/// Whether this turn's request showed the model `name`: in its tools array for
/// a resident tool, in its catalog for a deferred one. Every name ToolSearch
/// returns or reports as callable passes it, so a miss never names a tool the
/// request hid (#287).
///
/// With no request at hand (unit tests, direct dispatch) it applies the
/// filters `agent_loop.buildEffectiveToolSet` would: the execution policy, the
/// active Skill's tool pool and the provider capability gate. Without a
/// provider no capability can be confirmed, so a capability-gated tool is not
/// claimed.
fn visibleToModel(ctx: *const ToolContext, name: []const u8, deferred: bool) bool {
    if (ctx.request_tools) |request| {
        return if (deferred) request.offersDeferred(name) else request.advertises(name);
    }
    if (ctx.execution_policy) |policy| if (!policy.allowsTool(name)) return false;
    if (ctx.permission_ctx) |perm| if (perm.active_skill) |skill| if (!skill.allowsTool(name)) return false;
    if (capability.requiredCapability(name)) |cap| {
        const provider = ctx.provider orelse return false;
        if (!provider.supports(cap)) return false;
    }
    return true;
}

/// `visibleToModel` for a built-in. The system prompt lists a deferred TinyKG
/// tool only while the store is ready (`App.kgReady`), so ToolSearch offers
/// none otherwise. With no request at hand the Swarm and TinyKG tools also
/// need their host contexts, standing in for the `tools.toToolDefinitionsFull`
/// gates.
fn staticVisible(ctx: *const ToolContext, t: *const tools.ToolEntry) bool {
    if (!t.previewAllowed(ctx.preview)) return false;
    if (t.tinykg_gated and t.deferred and !kgReady(ctx)) return false;
    if (ctx.request_tools == null) {
        if (t.tinykg_gated and ctx.kg == null) return false;
        if (t.swarm_gated and ctx.swarm == null) return false;
    }
    return visibleToModel(ctx, t.name, t.deferred);
}

fn kgReady(ctx: *const ToolContext) bool {
    const kg = ctx.kg orelse return false;
    return kg.ready;
}

/// 本 session 当前可激活的 deferred 工具名(静态 deferred 受执行策略/TinyKG 门控;动态
/// deferred = MCP/插件)。逗号分隔,超过 `MAX_LISTED_NAMES` 个只给前面的加计数。owned。
pub const MAX_LISTED_NAMES: usize = 40;

const Listing = union(enum) {
    deferred,
    /// Tools already in the request: callable without ToolSearch.
    resident,
    /// Resident tools whose name contains one of the query's keywords.
    resident_named: []const u8,

    fn admits(self: Listing, deferred: bool, name: []const u8) bool {
        // ToolSearch itself is the discovery mechanism, not a resident tool
        // the model should retry after a failed search.
        const resident = !deferred and !std.mem.eql(u8, name, "ToolSearch");
        return switch (self) {
            .deferred => deferred,
            .resident => resident,
            .resident_named => |query| resident and nameHasKeyword(query, name),
        };
    }
};

fn listNames(ctx: *const ToolContext, allocator: std.mem.Allocator, listing: Listing) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var count: usize = 0;
    var omitted: usize = 0;
    for (tools.registry) |*t| {
        if (!listing.admits(t.deferred, t.name)) continue;
        if (!staticVisible(ctx, t)) continue;
        try appendName(allocator, &out, t.name, &count, &omitted);
    }
    if (ctx.dyn_registry) |dr| {
        var index: usize = 0;
        while (dr.entryAt(index)) |e| : (index += 1) {
            if (!e.isLive()) continue;
            if (!listing.admits(e.deferred, e.name)) continue;
            if (!visibleToModel(ctx, e.name, e.deferred)) continue;
            try appendName(allocator, &out, e.name, &count, &omitted);
        }
    }
    if (omitted > 0) try out.print(allocator, ", … ({d} more)", .{omitted});
    return try out.toOwnedSlice(allocator);
}

/// The miss diagnostic. A tool-search-first model reads a bare miss as "these
/// tools do not exist" (#287), so it says that ToolSearch only covers deferred
/// tools, names the loaded tools the keywords were after, and lists the loaded
/// tools and the deferred ones it can still fetch.
fn setMissDetail(ctx: *const ToolContext, allocator: std.mem.Allocator, query: []const u8) !void {
    const slot = ctx.error_detail orelse return;
    // 落空时把现在真能激活的 deferred 名单直接给模型:动态(MCP)工具的名字模型未必记得,
    // 关键字匹配又是 AND 语义,一次猜错就该有出路。
    const deferred = try listNames(ctx, allocator, .deferred);
    defer allocator.free(deferred);
    const resident = try listNames(ctx, allocator, .resident);
    defer allocator.free(resident);
    const named = try listNames(ctx, allocator, .{ .resident_named = query });
    defer allocator.free(named);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.print("No deferred tool matched query \"{s}\"", .{query});
    if (deferred.len == 0) {
        try w.writeAll(": no deferred tools are registered in this session (no MCP server or plugin tool is connected).");
    } else {
        try w.writeAll(".");
    }
    if (resident.len > 0) {
        try w.writeAll(" ToolSearch only searches deferred tools; the tools already in your tool list are directly callable without it.");
        if (named.len > 0) try w.print(" Already in your tool list and matching your keywords: {s}. Call them directly.", .{named});
        try w.print(" Available directly: {s}.", .{resident});
    } else if (deferred.len == 0) {
        try w.writeAll(" Use the tools already in your tool list.");
    }
    if (deferred.len > 0) try w.print(" Deferred tools available right now: {s}. Use select:<exact_name> to fetch one, or fewer keywords (every keyword must appear in one tool's name or description).", .{deferred});
    var late_arena = std.heap.ArenaAllocator.init(allocator);
    defer late_arena.deinit();
    const late = if (ctx.mcp_late) |probe| probe.late(late_arena.allocator()) else &.{};
    try mcp_session.writeNotice(w, ctx.mcp_unavailable, late);
    slot.* = try out.toOwnedSlice();
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

/// Some keyword of `query` (a `select:` list included) of at least three bytes
/// appears in `name`, ignoring case. Unlike `matchesKeywords` this is OR over
/// names only: "read write bash" should point at Read, Write and Bash, and a
/// one- or two-letter token would point at nearly every tool.
fn nameHasKeyword(query: []const u8, name: []const u8) bool {
    const select_prefix = "select:";
    const terms = if (std.mem.startsWith(u8, query, select_prefix)) query[select_prefix.len..] else query;
    var it = std.mem.tokenizeAny(u8, terms, " \t,");
    while (it.next()) |tok| {
        if (tok.len < 3) continue;
        if (std.ascii.indexOfIgnoreCase(name, tok) != null) return true;
    }
    return false;
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

test "ToolSearch: a miss names the configured MCP servers that did not connect and why" {
    const a = testing.allocator;
    var detail: ?[]const u8 = null;
    defer if (detail) |d| a.free(d);
    const unavailable = [_]@import("../core/mcp_session.zig").McpUnavailable{
        .{ .name = "suno", .detail = "the server requires authorization (401/403); run `metacodes mcp login suno`" },
    };
    const ctx = ToolContext{ .allocator = a, .error_detail = &detail, .mcp_unavailable = &unavailable };
    try testing.expectError(error.NoToolMatch, execute(&ctx, "{\"query\":\"suno\"}"));
    const d = detail orelse return error.TestExpectedDetail;
    try testing.expect(std.mem.indexOf(u8, d, "No deferred tool matched query \"suno\"") != null);
    try testing.expect(std.mem.indexOf(u8, d, "'suno' (the server requires authorization (401/403); run `metacodes mcp login suno`)") != null);

    var plain_detail: ?[]const u8 = null;
    defer if (plain_detail) |pd| a.free(pd);
    const plain = ToolContext{ .allocator = a, .error_detail = &plain_detail };
    try testing.expectError(error.NoToolMatch, execute(&plain, "{\"query\":\"suno\"}"));
    try testing.expect(std.mem.indexOf(u8, plain_detail.?, "did not connect") == null);
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
    try testing.expect(std.mem.indexOf(u8, d, "skill__resident") != null);
    try testing.expect(std.mem.indexOf(u8, d, "select:<exact_name>") != null);
    // A miss in the deferred pool must not imply that the core tools vanished;
    // they are already callable without another ToolSearch round trip.
    try testing.expect(std.mem.indexOf(u8, d, "ToolSearch only searches deferred tools") != null);
    try testing.expect(std.mem.indexOf(u8, d, "directly callable") != null);
    try testing.expect(std.mem.indexOf(u8, d, "Read") != null);
    try testing.expect(std.mem.indexOf(u8, d, "Bash") != null);
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
    const d = detail orelse return error.TestExpectedDetail;
    defer a.free(d);
    try testing.expect(std.mem.indexOf(u8, d, "ToolSearch only searches deferred tools") != null);
    try testing.expect(std.mem.indexOf(u8, d, "directly callable") != null);
    try testing.expect(std.mem.indexOf(u8, d, "Read") != null);
    try testing.expect(std.mem.indexOf(u8, d, "Write") != null);
    try testing.expect(std.mem.indexOf(u8, d, "Bash") != null);
}

/// The text of `detail` between `start` and the next `end`; "" when absent.
fn segment(detail: []const u8, start: []const u8, end: []const u8) []const u8 {
    const from = (std.mem.indexOf(u8, detail, start) orelse return "") + start.len;
    const to = std.mem.indexOfPos(u8, detail, from, end) orelse return "";
    return detail[from..to];
}

fn listHas(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeSequence(u8, list, ", ");
    while (it.next()) |entry| if (std.mem.eql(u8, entry, name)) return true;
    return false;
}

const NAMED_START = "matching your keywords: ";
const NAMED_END = ". Call them directly.";
const LOADED_START = "Available directly: ";

test "ToolSearch: a miss names the loaded tools its keywords were after (#287)" {
    const a = testing.allocator;
    var dyn = DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("knowforge__search", "Search the knowledge base", &.{}, dynExec, null, true);
    var detail: ?[]const u8 = null;
    defer if (detail) |d| a.free(d);
    const ctx = ToolContext{ .allocator = a, .dyn_registry = &dyn, .error_detail = &detail };
    // The query from the issue's transcript. Keywords are ANDed over the
    // deferred pool, so it misses there.
    try testing.expectError(error.NoToolMatch, execute(&ctx, "{\"query\":\"file read write edit bash glob grep search\",\"max_results\":10}"));
    const d = detail orelse return error.TestExpectedDetail;
    const named = segment(d, NAMED_START, NAMED_END);
    for ([_][]const u8{ "Read", "Write", "Edit", "Bash", "Glob", "Grep" }) |name| {
        try testing.expect(listHas(named, name));
    }
    try testing.expect(!listHas(named, "TaskCreate"));
    try testing.expect(!listHas(named, "ToolSearch"));
    try testing.expect(!listHas(named, "knowforge__search"));
    try testing.expect(listHas(segment(d, "Deferred tools available right now: ", ". Use select:"), "knowforge__search"));
    // No provider confirms web search, so WebSearch is not called loaded
    // although "search" is in its name.
    try testing.expect(std.mem.indexOf(u8, d, "WebSearch") == null);
}

test "ToolSearch: only tools the active Skill leaves in the request are reported or selected" {
    const a = testing.allocator;
    const PolicyFrame = @import("metacodes-guard").skills.runtime.policy_frame.PolicyFrame;
    const session_tools = [_][]const u8{ "Read", "Write", "Bash" };
    const root = try PolicyFrame.createRoot(a, &session_tools, .unrestricted, .default, .{ .alloc = a });
    defer root.release();
    const child = try PolicyFrame.derive(root, &.{"Read"}, &.{});
    defer child.release();
    const active = @import("metacodes-guard").skills.active.ActiveSkillState.borrowFromPolicyFrame("read-only", child);
    var perm = @import("metacodes-guard").permission_root.PermissionContext{ .allocator = a, .active_skill = &active };

    var detail: ?[]const u8 = null;
    defer if (detail) |d| a.free(d);
    const ctx = ToolContext{ .allocator = a, .permission_ctx = &perm, .error_detail = &detail };
    try testing.expectError(error.NoToolMatch, execute(&ctx, "{\"query\":\"read write bash\"}"));
    const d = detail orelse return error.TestExpectedDetail;
    const named = segment(d, NAMED_START, NAMED_END);
    try testing.expect(listHas(named, "Read"));
    try testing.expect(!listHas(named, "Write"));
    try testing.expect(!listHas(named, "Bash"));
    const loaded = segment(d, LOADED_START, ".");
    try testing.expect(listHas(loaded, "Read"));
    try testing.expect(!listHas(loaded, "Write"));
    try testing.expect(!listHas(loaded, "Bash"));

    // select: hands out no schema for a tool the Skill hid from the request.
    var select_detail: ?[]const u8 = null;
    defer if (select_detail) |sd| a.free(sd);
    const select_ctx = ToolContext{ .allocator = a, .permission_ctx = &perm, .error_detail = &select_detail };
    try testing.expectError(error.NoToolMatch, execute(&select_ctx, "{\"query\":\"select:Bash\"}"));
    const out = try execute(&select_ctx, "{\"query\":\"select:Read\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"Read\"") != null);
}

test "ToolSearch: WebSearch is reported as loaded only when the provider can search" {
    const a = testing.allocator;
    const provider_mod = @import("metacodes-ai").api.provider;
    const Fake = struct {
        fn model(_: *anyopaque) []const u8 {
            return "fake";
        }
        fn maxTokens(_: *anyopaque) u32 {
            return 1024;
        }
        fn reasoningEffort(_: *anyopaque) ?@import("metacodes-ai").types.ReasoningEffort {
            return null;
        }
        fn supports(state: *anyopaque, cap: provider_mod.Capability) bool {
            const web_search: *const bool = @ptrCast(state);
            return cap == .web_search and web_search.*;
        }
    };
    var web_search = false;
    const provider = provider_mod.Provider{
        .ctx = @ptrCast(&web_search),
        .modelFn = Fake.model,
        .sendStreamFn = undefined,
        .sendStreamRetryFn = undefined,
        .sendFn = undefined,
        .maxTokensFn = Fake.maxTokens,
        .maxInputTokensFn = Fake.maxTokens,
        .reasoningEffortFn = Fake.reasoningEffort,
        .supportsFn = Fake.supports,
    };
    for ([_]bool{ false, true }) |supported| {
        web_search = supported;
        var detail: ?[]const u8 = null;
        defer if (detail) |d| a.free(d);
        const ctx = ToolContext{ .allocator = a, .provider = provider, .error_detail = &detail };
        try testing.expectError(error.NoToolMatch, execute(&ctx, "{\"query\":\"web search\"}"));
        const d = detail orelse return error.TestExpectedDetail;
        try testing.expectEqual(supported, listHas(segment(d, NAMED_START, NAMED_END), "WebSearch"));
        try testing.expectEqual(supported, std.mem.indexOf(u8, d, "WebSearch") != null);
    }
}

test "ToolSearch: with a request at hand, it answers from the request's own tools" {
    const a = testing.allocator;
    var dyn = DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("knowforge__search", "Search the knowledge base", &.{}, dynExec, null, true);
    try dyn.register("hidden__search", "Search something the request left out", &.{}, dynExec, null, true);
    const schema: json_mod.InputSchema = .{ .type = "object", .properties = null, .required = &.{} };
    // Teams are on and TinyKG tools are advertised while neither host context
    // is attached here, and Bash is left out: the request decides, not the
    // registry gates.
    const advertised = [_]json_mod.ToolDefinition{
        .{ .name = "Read", .description = "", .input_schema = schema },
        .{ .name = "TeamCreate", .description = "", .input_schema = schema },
        .{ .name = "KgRecall", .description = "", .input_schema = schema },
        .{ .name = "ToolSearch", .description = "", .input_schema = schema },
    };
    const catalog = advertised ++ [_]json_mod.ToolDefinition{
        .{ .name = "knowforge__search", .description = "", .input_schema = schema, .deferred = true },
    };
    var detail: ?[]const u8 = null;
    defer if (detail) |d| a.free(d);
    const ctx = ToolContext{
        .allocator = a,
        .dyn_registry = &dyn,
        .error_detail = &detail,
        .request_tools = .{ .advertised = &advertised, .catalog = &catalog },
    };
    try testing.expectError(error.NoToolMatch, execute(&ctx, "{\"query\":\"read team bash send recall\"}"));
    const d = detail orelse return error.TestExpectedDetail;
    const named = segment(d, NAMED_START, NAMED_END);
    try testing.expect(listHas(named, "Read"));
    try testing.expect(listHas(named, "TeamCreate"));
    try testing.expect(listHas(named, "KgRecall"));
    try testing.expect(!listHas(named, "Bash"));
    try testing.expect(!listHas(named, "SendMessage"));
    const loaded = segment(d, LOADED_START, ".");
    try testing.expect(listHas(loaded, "TeamCreate"));
    try testing.expect(!listHas(loaded, "Bash"));
    try testing.expect(!listHas(loaded, "TeamDelete"));
    const offered = segment(d, "Deferred tools available right now: ", ". Use select:");
    try testing.expect(listHas(offered, "knowforge__search"));
    try testing.expect(!listHas(offered, "hidden__search"));

    var select_detail: ?[]const u8 = null;
    defer if (select_detail) |sd| a.free(sd);
    const select_ctx = ToolContext{
        .allocator = a,
        .dyn_registry = &dyn,
        .error_detail = &select_detail,
        .request_tools = .{ .advertised = &advertised, .catalog = &catalog },
    };
    try testing.expectError(error.NoToolMatch, execute(&select_ctx, "{\"query\":\"select:Bash\"}"));
    if (select_detail) |sd| a.free(sd);
    select_detail = null;
    try testing.expectError(error.NoToolMatch, execute(&select_ctx, "{\"query\":\"select:hidden__search\"}"));
    const out = try execute(&select_ctx, "{\"query\":\"select:TeamCreate,knowforge__search\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"TeamCreate\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "knowforge__search") != null);
}
