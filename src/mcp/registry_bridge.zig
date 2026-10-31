//! 把 MCP server 的 tools 注入到 DynRegistry。
//!
//! 命名：`mcp__<server>__<tool>`(Claude Code 的形式,见 naming.zig;非法字符换 `_`,
//! 超长/冲突加稳定哈希后缀)。调用 server 时仍用原始工具名。
//!
//! 每个 MCP tool 注册时：
//! - ctx_ptr 指向 McpToolBinding（含 *McpClient + original name）
//! - execute 函数从 ctx_ptr 恢复 client 调 callTool
//!
//! 注意：McpToolBinding 的生命周期 = McpSession 的生命周期（至少 process 级）。
//! McpSession.deinit 清理所有 binding。

const std = @import("std");
const McpClient = @import("client.zig").McpClient;
const naming = @import("naming.zig");
const param_headers = @import("param_headers.zig");
const tool_invocation = @import("tool_invocation.zig");
const schema = @import("schema.zig");
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
    /// server_prefix 是 server 名（如 "github"），最终 name 为 "mcp__github__search_issues"。
    pub fn registerTools(
        self: *McpSession,
        registry: *DynRegistry,
        server_prefix: []const u8,
    ) !void {
        return self.registerToolsFiltered(registry, server_prefix, .{});
    }

    /// `registerTools` with a server's `enabled_tools` / `disabled_tools`.
    pub fn registerToolsFiltered(
        self: *McpSession,
        registry: *DynRegistry,
        server_prefix: []const u8,
        filter: ToolFilter,
    ) !void {
        const tools_json = try self.client.listTools();
        defer self.allocator.free(tools_json);
        try self.registerToolsFromJsonFiltered(registry, server_prefix, tools_json, filter);
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
        return self.registerToolsFromJsonFiltered(registry, server_prefix, tools_json, .{});
    }

    pub fn registerToolsFromJsonFiltered(
        self: *McpSession,
        registry: *DynRegistry,
        server_prefix: []const u8,
        tools_json: []const u8,
        filter: ToolFilter,
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
            if (!filter.allows(name)) continue;
            const desc = jsonString(tool_v.object.get("description")) orelse "";
            // Streamable HTTP: `x-mcp-header` parameters become `Mcp-Param-*`
            // headers; a tool with an invalid annotation MUST be dropped.
            const headers: []const param_headers.ParamHeader = if (filter.http_param_headers)
                param_headers.collect(a, tool_v.object.get("inputSchema")) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidParamHeader => {
                        log.warn("mcp", "server '{s}': tool '{s}' has an invalid x-mcp-header annotation, skipped", .{ server_prefix, name });
                        continue;
                    },
                }
            else
                &.{};
            const input_schema = try schema.projectInputLenient(a, tool_v.object.get("inputSchema"));

            const binding = try self.allocator.create(McpToolBinding);
            errdefer self.allocator.destroy(binding);
            binding.* = .{
                .client = self.client,
                .mcp_tool_name = try self.allocator.dupe(u8, name),
                .param_headers = headers,
            };
            errdefer self.allocator.free(binding.mcp_tool_name);

            const full_name = try naming.modelToolName(self.allocator, server_prefix, name, RegistryNames{ .registry = registry });
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

    /// 注册本 server 的 resource 访问工具：`mcp__<server>__list_resources` + `mcp__<server>__read_resource`。
    /// CLI 不再调用(统一走 ListMcpResourcesTool / ReadMcpResourceTool),保留给库宿主。
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
            const name = try std.fmt.allocPrint(self.allocator, "mcp__{s}__list_resources", .{server_prefix});
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
            const name = try std.fmt.allocPrint(self.allocator, "mcp__{s}__read_resource", .{server_prefix});
            defer self.allocator.free(name);
            const required = [_][]const u8{"uri"};
            try registry.registerMcpBody(name, "Read a resource from this MCP server by uri.", &required, executeReadResourceBody, binding, server_prefix);
            self.bindings.appendAssumeCapacity(binding);
        }
    }
};

/// Claude Code-style per-server tool selection (Codex `enabled_tools` /
/// `disabled_tools`): raw MCP tool names; deny applies after allow.
pub const ToolFilter = struct {
    enabled: ?[]const []const u8 = null,
    disabled: []const []const u8 = &.{},
    /// The server speaks Streamable HTTP: honour `x-mcp-header`.
    http_param_headers: bool = false,

    pub fn allows(self: ToolFilter, name: []const u8) bool {
        for (self.disabled) |item| if (std.mem.eql(u8, item, name)) return false;
        const enabled = self.enabled orelse return true;
        for (enabled) |item| if (std.mem.eql(u8, item, name)) return true;
        return false;
    }
};

/// Names already in the registry, for collision-free model names.
const RegistryNames = struct {
    registry: *const DynRegistry,

    pub fn contains(self: RegistryNames, name: []const u8) bool {
        return self.registry.find(name) != null;
    }
};

pub const McpToolBinding = struct {
    client: *McpClient,
    mcp_tool_name: []const u8, // owned
    /// `x-mcp-header` parameters (borrowed from the session's schema arena).
    param_headers: []const param_headers.ParamHeader = &.{},
};

fn executeMcpTool(ctx: *const ToolContext, args: []const u8, ctx_ptr: ?*anyopaque) anyerror![]u8 {
    const binding: *McpToolBinding = @ptrCast(@alignCast(ctx_ptr orelse return error.MissingMcpBinding));
    return try binding.client.callToolAbortable(binding.mcp_tool_name, args, ctx.abort);
}

/// The binding behind a registered MCP tool. Its own function so that the
/// missing case is not a literal `return error.X` in a function returning a
/// ToolResultBody, which would copy a 3.7 KiB constant
/// (doc/PERF_MEMORY_PRINCIPLES.md §3g).
fn mcpToolBinding(ctx_ptr: ?*anyopaque) error{MissingMcpBinding}!*McpToolBinding {
    return @ptrCast(@alignCast(ctx_ptr orelse return error.MissingMcpBinding));
}

fn executeMcpToolBody(ctx: *const ToolContext, args: []const u8, ctx_ptr: ?*anyopaque) anyerror!ToolResultBody {
    const binding = try mcpToolBinding(ctx_ptr);
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    const headers = try param_headers.headersForCall(scratch.allocator(), binding.param_headers, args);
    var body: ToolResultBody = undefined;
    try tool_invocation.execute(&body, binding.client, ctx, .{
        .name = binding.mcp_tool_name,
        .arguments_json = args,
        .headers = headers,
    });
    return body;
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
        var escaped = false;
        while (e < data.len) : (e += 1) {
            const byte = data[e];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (byte == '\\') {
                escaped = true;
                continue;
            }
            if (byte == '"') break;
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

    const search = reg.find("mcp__knowforge__search") orelse return error.TestExpectedTool;
    try testing.expect(search.deferred);
    try testing.expectEqualStrings("knowforge", search.mcp_server.?);
    try testing.expectEqualStrings("智能搜索(向量+关键字+图扩展)。", search.description);
    try testing.expectEqual(@as(usize, 1), search.required_fields.len);
    try testing.expectEqualStrings("query", search.required_fields[0]);
    const projected = search.borrowed_input_schema orelse return error.TestExpectedSchema;
    try testing.expect(projected.properties.?.get("query") != null);
    try testing.expect(projected.properties.?.get("topk") != null);
    try testing.expectEqual(@as(?bool, false), projected.additional_properties);
    // binding 指回 server 侧的裸工具名。
    try testing.expectEqualStrings("search", session.bindings.items[1].mcp_tool_name);

    const listing = reg.find("mcp__knowforge__list_knowledge_bases") orelse return error.TestExpectedTool;
    try testing.expectEqual(@as(usize, 0), listing.required_fields.len);
    try testing.expect(listing.borrowed_input_schema.?.properties != null);

    // 缺描述 → 空描述;required 里的非字符串被丢弃,不拖垮整条。
    const download = reg.find("mcp__knowforge__download") orelse return error.TestExpectedTool;
    try testing.expectEqualStrings("", download.description);
    try testing.expectEqual(@as(usize, 1), download.required_fields.len);
    try testing.expectEqualStrings("fragment_id", download.required_fields[0]);

    // 序列化成 provider tools 条目时 properties 真的到 wire。
    var defs: std.ArrayList(@import("../json.zig").ToolDefinition) = .empty;
    defer defs.deinit(testing.allocator);
    try reg.appendDefinitions(&defs, testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (defs.items) |d| if (std.mem.eql(u8, d.name, "mcp__knowforge__search")) {
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
}

test "registerToolsFromJson: names collide-free, filters apply to raw names" {
    var fake_client: McpClient = undefined;
    var session = McpSession.init(testing.allocator, &fake_client);
    defer session.deinit();
    var reg = DynRegistry.init(testing.allocator);
    defer reg.deinit();
    // An existing name gets a hashed sibling instead of failing the batch.
    try reg.registerMcp("mcp__s__b", "preexisting", &.{}, executeReadResource, null, "s");
    try session.registerToolsFromJsonFiltered(
        &reg,
        "s",
        "{\"tools\":[{\"name\":\"a\"},{\"name\":\"b\"},{\"name\":\"dotted.name\"},{\"name\":\"hidden\"}]}",
        .{ .disabled = &.{"hidden"} },
    );
    try testing.expect(reg.find("mcp__s__a") != null);
    try testing.expect(reg.find("mcp__s__dotted_name") != null);
    try testing.expect(reg.find("mcp__s__hidden") == null);
    try testing.expectEqual(@as(usize, 4), reg.entries.items.len);
    for (reg.entries.items) |entry| try testing.expect(naming.isProviderSafe(entry.name));
    // The binding keeps the raw MCP name for tools/call.
    try testing.expectEqualStrings("dotted.name", session.bindings.items[2].mcp_tool_name);

    var only = McpSession.init(testing.allocator, &fake_client);
    defer only.deinit();
    var only_reg = DynRegistry.init(testing.allocator);
    defer only_reg.deinit();
    try only.registerToolsFromJsonFiltered(&only_reg, "s", "{\"tools\":[{\"name\":\"a\"},{\"name\":\"b\"}]}", .{ .enabled = &.{"b"} });
    try testing.expectEqual(@as(usize, 1), only_reg.entries.items.len);
    try testing.expect(only_reg.find("mcp__s__b") != null);
}

test "registerResourceTools registers list + read tools" {
    // 用一个假 client 指针即可（不会真调用，只校验注册）
    var fake_client: McpClient = undefined;
    var session = McpSession.init(testing.allocator, &fake_client);
    defer session.deinit();

    var reg = DynRegistry.init(testing.allocator);
    defer reg.deinit();
    try session.registerResourceTools(&reg, "myserver");

    try testing.expect(reg.find("mcp__myserver__list_resources") != null);
    try testing.expect(reg.find("mcp__myserver__read_resource") != null);
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
        "mcp__myserver__read_resource",
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
    try testing.expect(reg.find("mcp__myserver__list_resources") == null);
    try testing.expect(reg.find("mcp__myserver__read_resource") != null);
    try testing.expectEqual(@as(usize, 1), reg.entries.items.len);
    try testing.expectEqual(@as(usize, 0), session.bindings.items.len);
}
