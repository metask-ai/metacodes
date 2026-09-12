//! 把 MCP server 的 tools 注入到 DynRegistry。
//!
//! 命名空间：`<server_name>__<tool_name>`（双下划线分隔），避免与内建冲突。
//!
//! 每个 MCP tool 注册时：
//! - ctx_ptr 指向 McpToolBinding（含 *McpClient + original name）
//! - execute 函数从 ctx_ptr 恢复 client 调 callTool
//!
//! 注意：McpToolBinding 的生命周期 = McpSession 的生命周期（至少 process 级）。
//! McpSession.deinit 清理所有 binding。

const std = @import("std");
const McpClient = @import("client.zig").McpClient;
const DynRegistry = @import("../tools/dynamic.zig").DynRegistry;
const ToolContext = @import("../tools/context.zig").ToolContext;
const ToolResultBody = @import("../tools/context.zig").ToolResultBody;

/// 持有 MCP client + 它注入到 registry 的 tool bindings 的所有权。
pub const McpSession = struct {
    allocator: std.mem.Allocator,
    client: *McpClient,
    bindings: std.ArrayList(*McpToolBinding),
    /// `tools/list` 的解析结果落在这里:注册进 DynRegistry 的 `input_schema` **借用**本
    /// arena(与插件快照的 borrowed 定义同一约定),随 session 存亡。App 先 deinit session
    /// 再 deinit 注册表,注册表 deinit 只释放自己 dupe 的字符串,不回读借用的 schema。
    schema_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, client: *McpClient) McpSession {
        return .{
            .allocator = allocator,
            .client = client,
            .bindings = .empty,
            .schema_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *McpSession) void {
        self.rollbackBindingsTo(0);
        self.bindings.deinit(self.allocator);
        self.schema_arena.deinit();
    }

    fn rollbackBindingsTo(self: *McpSession, checkpoint: usize) void {
        std.debug.assert(checkpoint <= self.bindings.items.len);
        for (self.bindings.items[checkpoint..]) |b| {
            self.allocator.free(b.mcp_tool_name);
            self.allocator.destroy(b);
        }
        self.bindings.shrinkRetainingCapacity(checkpoint);
    }

    /// 从 MCP server listTools → 注入到 DynRegistry。
    /// server_prefix 是命名空间前缀（如 "github"），最终 name 为 "github__search_issues"。
    pub fn registerTools(
        self: *McpSession,
        registry: *DynRegistry,
        server_prefix: []const u8,
    ) !void {
        const tools_json = try self.client.listTools();
        defer self.allocator.free(tools_json);
        try self.registerToolsFromJson(registry, server_prefix, tools_json);
    }

    /// `tools/list` 结果 → DynRegistry。用 std.json 整体解析(不再手写扫描):
    /// - Python `json.dumps` 默认 `"name": "x"` 带空格——旧的 `"name":"` 定长模式一个都
    ///   匹配不上,整个 server 静默注册 0 个工具、连告警都没有(2026-09-10 真 knowforge
    ///   server 实测,9 个工具只剩内置的 list/read_resource 两个);
    /// - `inputSchema` 原样投影成 provider 可见的 `properties/required/additionalProperties`
    ///   (借用 `schema_arena`),模型拿到参数名而不是空对象;
    /// - 单条畸形(缺 name / 不是对象)记 warn 跳过,其余照常注册;根形状不对才整体报错。
    pub fn registerToolsFromJson(
        self: *McpSession,
        registry: *DynRegistry,
        server_prefix: []const u8,
        tools_json: []const u8,
    ) !void {
        const log = @import("../util/log.zig");
        const registry_checkpoint = registry.entries.items.len;
        const bindings_checkpoint = self.bindings.items.len;
        errdefer {
            registry.rollbackTo(registry_checkpoint);
            self.rollbackBindingsTo(bindings_checkpoint);
        }

        const a = self.schema_arena.allocator();
        const root = std.json.parseFromSliceLeaky(std.json.Value, a, tools_json, .{
            .allocate = .alloc_always,
        }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.MalformedMcpResponse;
        if (root != .object) return error.MalformedMcpResponse;
        const tools_v = root.object.get("tools") orelse return error.MalformedMcpResponse;
        if (tools_v != .array) return error.MalformedMcpResponse;

        for (tools_v.array.items, 0..) |tool_v, index| {
            if (tool_v != .object) {
                log.warn("mcp", "server '{s}': tools[{d}] is not an object, skipped", .{ server_prefix, index });
                continue;
            }
            const name = jsonString(tool_v.object.get("name")) orelse {
                log.warn("mcp", "server '{s}': tools[{d}] has no string name, skipped", .{ server_prefix, index });
                continue;
            };
            const desc = jsonString(tool_v.object.get("description")) orelse "";
            const input_schema = try projectInputSchema(a, tool_v.object.get("inputSchema"));

            const binding = try self.allocator.create(McpToolBinding);
            errdefer self.allocator.destroy(binding);
            binding.* = .{
                .client = self.client,
                .mcp_tool_name = try self.allocator.dupe(u8, name),
            };
            errdefer self.allocator.free(binding.mcp_tool_name);

            const full_name = try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ server_prefix, name });
            defer self.allocator.free(full_name);

            // Reserve the owner slot before publishing ctx_ptr into registry.
            // Once registration succeeds, appendAssumeCapacity cannot strand a
            // registry entry pointing at a freed binding.
            try self.bindings.ensureUnusedCapacity(self.allocator, 1);
            try registry.registerMcpDefinitionBody(.{
                .name = full_name,
                .description = desc,
                .input_schema = input_schema,
                .deferred = true,
                .mcp_server = server_prefix,
            }, executeMcpToolBody, binding, server_prefix);
            self.bindings.appendAssumeCapacity(binding);
        }
    }

    /// 注册本 server 的 resource 访问工具：`<prefix>__list_resources` + `<prefix>__read_resource`。
    /// 复用 McpToolBinding（mcp_tool_name 字段此处不用，置空 dup）。
    pub fn registerResourceTools(
        self: *McpSession,
        registry: *DynRegistry,
        server_prefix: []const u8,
    ) !void {
        const registry_checkpoint = registry.entries.items.len;
        const bindings_checkpoint = self.bindings.items.len;
        errdefer {
            registry.rollbackTo(registry_checkpoint);
            self.rollbackBindingsTo(bindings_checkpoint);
        }
        try self.bindings.ensureUnusedCapacity(self.allocator, 2);
        // list_resources
        {
            const binding = try self.allocator.create(McpToolBinding);
            errdefer self.allocator.destroy(binding);
            binding.* = .{ .client = self.client, .mcp_tool_name = try self.allocator.dupe(u8, "") };
            errdefer self.allocator.free(binding.mcp_tool_name);
            const name = try std.fmt.allocPrint(self.allocator, "{s}__list_resources", .{server_prefix});
            defer self.allocator.free(name);
            try registry.registerMcpBody(name, "List resources exposed by this MCP server.", &.{}, executeListResourcesBody, binding, server_prefix);
            self.bindings.appendAssumeCapacity(binding);
        }
        // read_resource
        {
            const binding = try self.allocator.create(McpToolBinding);
            errdefer self.allocator.destroy(binding);
            binding.* = .{ .client = self.client, .mcp_tool_name = try self.allocator.dupe(u8, "") };
            errdefer self.allocator.free(binding.mcp_tool_name);
            const name = try std.fmt.allocPrint(self.allocator, "{s}__read_resource", .{server_prefix});
            defer self.allocator.free(name);
            const required = [_][]const u8{"uri"};
            try registry.registerMcpBody(name, "Read a resource from this MCP server by uri.", &required, executeReadResourceBody, binding, server_prefix);
            self.bindings.appendAssumeCapacity(binding);
        }
    }
};

pub const McpToolBinding = struct {
    client: *McpClient,
    mcp_tool_name: []const u8, // owned
};

fn executeMcpTool(ctx: *const ToolContext, args: []const u8, ctx_ptr: ?*anyopaque) anyerror![]u8 {
    const binding: *McpToolBinding = @ptrCast(@alignCast(ctx_ptr orelse return error.MissingMcpBinding));
    return try binding.client.callToolAbortable(binding.mcp_tool_name, args, ctx.abort);
}

fn executeMcpToolBody(ctx: *const ToolContext, args: []const u8, ctx_ptr: ?*anyopaque) anyerror!ToolResultBody {
    const binding: *McpToolBinding = @ptrCast(@alignCast(ctx_ptr orelse return error.MissingMcpBinding));
    return binding.client.callToolBodyAbortable(
        binding.mcp_tool_name,
        args,
        ctx.artifact_root,
        ctx.result_budget,
        ctx.abort,
    );
}

fn executeListResources(ctx: *const ToolContext, args: []const u8, ctx_ptr: ?*anyopaque) anyerror![]u8 {
    const binding: *McpToolBinding = @ptrCast(@alignCast(ctx_ptr orelse return error.MissingMcpBinding));
    _ = args;
    return try binding.client.listResourcesAbortable(ctx.abort);
}

fn executeListResourcesBody(ctx: *const ToolContext, args: []const u8, ctx_ptr: ?*anyopaque) anyerror!ToolResultBody {
    const binding: *McpToolBinding = @ptrCast(@alignCast(ctx_ptr orelse return error.MissingMcpBinding));
    _ = args;
    return binding.client.listResourcesBodyAbortable(ctx.artifact_root, ctx.result_budget, ctx.abort);
}

fn executeReadResource(ctx: *const ToolContext, args: []const u8, ctx_ptr: ?*anyopaque) anyerror![]u8 {
    const binding: *McpToolBinding = @ptrCast(@alignCast(ctx_ptr orelse return error.MissingMcpBinding));
    const uri = extractStringField(args, "uri") orelse return error.MissingUri;
    return try binding.client.readResourceAbortable(uri, ctx.abort);
}

fn executeReadResourceBody(ctx: *const ToolContext, args: []const u8, ctx_ptr: ?*anyopaque) anyerror!ToolResultBody {
    const binding: *McpToolBinding = @ptrCast(@alignCast(ctx_ptr orelse return error.MissingMcpBinding));
    const uri = extractStringField(args, "uri") orelse return error.MissingUri;
    return binding.client.readResourceBodyAbortable(uri, ctx.artifact_root, ctx.result_budget, ctx.abort);
}

// 私有 helpers
fn jsonString(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |text| text,
        else => null,
    };
}

/// MCP `inputSchema` → provider 可见的 InputSchema 投影(与 agentcore/mcp_schema 同一
/// 形状:根 `type` 固定 object,`properties` 原样借用,`required` 只收字符串,
/// `additionalProperties` 只收布尔)。缺失/不是对象 → 空 object schema。所有借用内存
/// 来自 `arena`(session 的 schema_arena)。
fn projectInputSchema(arena: std.mem.Allocator, value: ?std.json.Value) !@import("../json.zig").InputSchema {
    const schema_v = value orelse return .{ .type = "object" };
    if (schema_v != .object) return .{ .type = "object" };
    const obj = schema_v.object;
    const properties: ?std.json.ObjectMap = if (obj.get("properties")) |pv| (if (pv == .object) pv.object else null) else null;
    var required: []const []const u8 = &.{};
    if (obj.get("required")) |rv| if (rv == .array) {
        var names = try arena.alloc([]const u8, rv.array.items.len);
        var n: usize = 0;
        for (rv.array.items) |item| if (item == .string) {
            names[n] = item.string;
            n += 1;
        };
        required = names[0..n];
    };
    const additional: ?bool = if (obj.get("additionalProperties")) |av| (if (av == .bool) av.bool else null) else null;
    return .{
        .type = "object",
        .properties = properties,
        .required = required,
        .additional_properties = additional,
    };
}

/// 从工具参数 JSON 里取一个字符串字段。容忍键与值之间的空白(模型/服务端产出的 JSON
/// 常见 `"uri": "x"`),值里的转义引号不截断。
fn extractStringField(data: []const u8, field: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (field.len > 200) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    const key = buf[0 .. 2 + field.len];
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, data, search, key)) |idx| {
        var pos = idx + key.len;
        while (pos < data.len and isJsonWs(data[pos])) : (pos += 1) {}
        if (pos >= data.len or data[pos] != ':') {
            search = idx + 1;
            continue;
        }
        pos += 1;
        while (pos < data.len and isJsonWs(data[pos])) : (pos += 1) {}
        if (pos >= data.len or data[pos] != '"') return null;
        const s = pos + 1;
        var e = s;
        while (e < data.len) : (e += 1) {
            if (data[e] == '"' and data[e - 1] != '\\') break;
        }
        return data[s..e];
    }
    return null;
}

fn isJsonWs(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t';
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "extractStringField works" {
    try testing.expectEqualStrings("foo", extractStringField("{\"name\":\"foo\"}", "name").?);
    // 键值之间的空白(Python json.dumps / 模型手写 JSON 的常态)不再是匹配失败。
    try testing.expectEqualStrings("mock://x", extractStringField("{\"server\": \"a\", \"uri\": \"mock://x\"}", "uri").?);
    try testing.expectEqualStrings("y", extractStringField("{ \"uri\"\n  :\t\"y\" }", "uri").?);
    // 键名只是别的字符串值的一部分时不误命中。
    try testing.expect(extractStringField("{\"note\":\"uri\",\"other\":1}", "uri") == null);
    try testing.expect(extractStringField("{\"uri\": 42}", "uri") == null);
}

/// 真 knowforge server(Python `json.dumps` 默认分隔符)的 tools/list 形状缩样:键值之间
/// 带空格、中文描述、嵌套 inputSchema、annotations 额外字段;外加一条没有 name 的畸形条目。
const SPACED_TOOLS_LIST =
    \\{"tools": [
    \\  {"name": "list_knowledge_bases", "description": "列出当前可访问的所有知识库。", "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": true}},
    \\  {"name": "search", "description": "智能搜索(向量+关键字+图扩展)。", "inputSchema": {"type": "object", "properties": {"resource_package_uuid": {"type": "string"}, "query": {"type": "string", "description": "查询关键词"}, "topk": {"type": "integer", "description": "返回条数，默认 8"}}, "required": ["query"], "additionalProperties": false}},
    \\  {"description": "no name here", "inputSchema": {"type": "object"}},
    \\  {"name": "download", "inputSchema": {"type": "object", "properties": {"fragment_id": {"type": "string"}}, "required": ["fragment_id", 7]}}
    \\]}
;

test "registerToolsFromJson: Python 风格带空格的 tools/list 全部注册,inputSchema 投影可见" {
    var fake_client: McpClient = undefined;
    var session = McpSession.init(testing.allocator, &fake_client);
    defer session.deinit();
    var reg = DynRegistry.init(testing.allocator);
    defer reg.deinit();

    try session.registerToolsFromJson(&reg, "knowforge", SPACED_TOOLS_LIST);
    try testing.expectEqual(@as(usize, 3), reg.entries.items.len);
    try testing.expectEqual(@as(usize, 3), session.bindings.items.len);

    const search = reg.find("knowforge__search") orelse return error.TestExpectedTool;
    try testing.expect(search.deferred);
    try testing.expectEqualStrings("knowforge", search.mcp_server.?);
    try testing.expectEqualStrings("智能搜索(向量+关键字+图扩展)。", search.description);
    try testing.expectEqual(@as(usize, 1), search.required_fields.len);
    try testing.expectEqualStrings("query", search.required_fields[0]);
    const schema = search.borrowed_input_schema orelse return error.TestExpectedSchema;
    try testing.expect(schema.properties.?.get("query") != null);
    try testing.expect(schema.properties.?.get("topk") != null);
    try testing.expectEqual(@as(?bool, false), schema.additional_properties);
    // binding 指回 server 侧的裸工具名。
    try testing.expectEqualStrings("search", session.bindings.items[1].mcp_tool_name);

    const listing = reg.find("knowforge__list_knowledge_bases") orelse return error.TestExpectedTool;
    try testing.expectEqual(@as(usize, 0), listing.required_fields.len);
    try testing.expect(listing.borrowed_input_schema.?.properties != null);

    // 缺描述 → 空描述;required 里的非字符串被丢弃,不拖垮整条。
    const download = reg.find("knowforge__download") orelse return error.TestExpectedTool;
    try testing.expectEqualStrings("", download.description);
    try testing.expectEqual(@as(usize, 1), download.required_fields.len);
    try testing.expectEqualStrings("fragment_id", download.required_fields[0]);

    // 序列化成 provider tools 条目时 properties 真的到 wire。
    var defs: std.ArrayList(@import("../json.zig").ToolDefinition) = .empty;
    defer defs.deinit(testing.allocator);
    try reg.appendDefinitions(&defs, testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (defs.items) |d| if (std.mem.eql(u8, d.name, "knowforge__search")) {
        try @import("../api/request.zig").serializeOneTool(d, &buf, testing.allocator);
    };
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"query\":{\"type\":\"string\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"required\":[\"query\"]") != null);
}

test "registerToolsFromJson: 根形状不对整体报错,不留半注册" {
    var fake_client: McpClient = undefined;
    var session = McpSession.init(testing.allocator, &fake_client);
    defer session.deinit();
    var reg = DynRegistry.init(testing.allocator);
    defer reg.deinit();
    try testing.expectError(error.MalformedMcpResponse, session.registerToolsFromJson(&reg, "s", "{\"tools\": \"nope\"}"));
    try testing.expectError(error.MalformedMcpResponse, session.registerToolsFromJson(&reg, "s", "not json"));
    try testing.expectError(error.MalformedMcpResponse, session.registerToolsFromJson(&reg, "s", "[]"));
    try testing.expectEqual(@as(usize, 0), reg.entries.items.len);
    try testing.expectEqual(@as(usize, 0), session.bindings.items.len);
    // 名字冲突时回滚到本批之前(前面已注册的同批条目一起撤)。
    try reg.registerMcp("s__b", "preexisting", &.{}, executeReadResource, null, "s");
    try testing.expectError(
        error.ToolAlreadyRegistered,
        session.registerToolsFromJson(&reg, "s", "{\"tools\":[{\"name\":\"a\"},{\"name\":\"b\"}]}"),
    );
    try testing.expect(reg.find("s__a") == null);
    try testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    try testing.expectEqual(@as(usize, 0), session.bindings.items.len);
}

test "registerResourceTools registers list + read tools" {
    // 用一个假 client 指针即可（不会真调用，只校验注册）
    var fake_client: McpClient = undefined;
    var session = McpSession.init(testing.allocator, &fake_client);
    defer session.deinit();

    var reg = DynRegistry.init(testing.allocator);
    defer reg.deinit();
    try session.registerResourceTools(&reg, "myserver");

    try testing.expect(reg.find("myserver__list_resources") != null);
    try testing.expect(reg.find("myserver__read_resource") != null);
}

test "registerResourceTools rolls back registry and bindings on partial failure" {
    var fake_client: McpClient = undefined;
    var session = McpSession.init(testing.allocator, &fake_client);
    defer session.deinit();

    var reg = DynRegistry.init(testing.allocator);
    defer reg.deinit();
    // Force the second resource registration to fail after the first one has
    // already been published. The batch must leave neither its first tool nor
    // any binding behind.
    try reg.registerMcp(
        "myserver__read_resource",
        "preexisting",
        &.{},
        executeReadResource,
        null,
        "myserver",
    );
    try testing.expectError(
        error.ToolAlreadyRegistered,
        session.registerResourceTools(&reg, "myserver"),
    );
    try testing.expect(reg.find("myserver__list_resources") == null);
    try testing.expect(reg.find("myserver__read_resource") != null);
    try testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    try testing.expectEqual(@as(usize, 0), session.bindings.items.len);
}
