const std = @import("std");
const types = @import("../types.zig");
const util_json = @import("../util/json.zig");
const dialect_mod = @import("dialect.zig");

/// Anthropic Messages API 请求体。
pub const MessagesRequest = struct {
    model: []const u8,
    /// 默认 16384（2^14）。Sonnet 4 支持到 64K，但多数回答用不到这么多。
    /// 上次默认 4096 太小：一次详细的项目解释就会触发 max_tokens stop_reason 截断。
    max_tokens: u32 = 16384,
    messages: []const types.ApiMessage,
    system: ?[]const u8 = null,
    stream: bool = false,
    tools: ?[]const ToolDefinition = null,
    tool_choice: ?ToolChoice = null,
    reasoning_effort: ?types.ReasoningEffort = null,
    /// Prompt caching：顶层 cache_control 自动缓存"最后一个可缓存 block"——
    /// 在常见用法下（稳定的 system + tools + 变化的 conversation）会把 tools + system
    /// 一起写 cache。后续请求只要 prefix（tools + system）字节相同就 read cache，
    /// 约省 70-90% 输入 token 费用 + 显著降低延迟。
    ///
    /// 默认开启：对绝大多数 coding agent 用例都是净收益。
    /// 禁用场景：system 或 tools 每次请求都变（模型不会碰到——本客户端 tools 注册表静态、
    /// system 在 session 生命周期不变）。
    ///
    /// 关键前提：prefix 不能含时间戳/UUID 等易变内容。本客户端的 system prompt 和
    /// tool schema 都是常量，天然满足。
    cache_control: ?CacheControl = .{ .type = "ephemeral" },
};

pub const CacheControl = struct {
    type: []const u8 = "ephemeral",
    /// 可选 TTL："5m"（默认）或 "1h"。1h 写入成本 2x（vs 5m 的 1.25x），
    /// 但跨长间隔仍可读——适合低频请求。默认 null = 5m。
    ttl: ?[]const u8 = null,
};

pub const ToolChoice = struct {
    type: []const u8 = "auto",
    name: ?[]const u8 = null,
};

/// Host-only model-routing metadata. It is deliberately excluded from every
/// provider tool schema: the immutable Runtime uses it to ask a compatible
/// dialect for a first-turn choice, while native dispatch/permission remains
/// the only execution authority.
pub const ModelToolActivation = struct {
    mode: Mode,
    /// Optional exact argument pair used only for deterministic dialect
    /// guidance (for Skill this is `name=<invocation_name>`).
    argument_name: ?[]const u8 = null,
    argument_value: ?[]const u8 = null,
    /// Request-scoped Host state. Runtime/catalog definitions always leave
    /// this false; AgentLoop may set it on a shallow copy after an exact,
    /// successful activation survives outside the provider-visible compact
    /// window. It is never serialized, so tool schemas and cache prefixes are
    /// byte-identical to the original immutable definition.
    satisfied: bool = false,

    pub const Mode = enum {
        required_first,
    };
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema: InputSchema,
    /// Anthropic server tools（web_search_20250305 / code_execution_20250825 等）需要
    /// 在 JSON 里输出 "type" 字段，而不带 description/input_schema。非 null 时切换到
    /// server-tool 序列化路径。
    server_type: ?[]const u8 = null,
    /// 运行期内部标记(不序列化进 API):deferred 工具(MCP 等)默认不进 tools 数组,
    /// 经 ToolSearch 激活后才发。agent_loop 据此过滤。
    deferred: bool = false,
    /// 运行期内部来源标记(不序列化)。非 null 只用于 MCP 注册桥接，
    /// AgentDef.mcpServers 必须按此字段过滤，不能从 `name` 猜来源。
    mcp_server: ?[]const u8 = null,
    /// Runtime/dialect routing metadata; never serialized as part of the tool
    /// declaration and never treated as permission.
    model_activation: ?ModelToolActivation = null,
};

/// 单个参数的 JSON Schema 描述。comptime 友好（纯字面量），用于内置工具表里
/// 静态声明 properties。模型据此知道每个字段的**名字+类型+用途**——否则只能从
/// required 列表反推名字、毫无类型/说明，OpenAI 兼容层行为不稳，触发空参/漏参风暴。
pub const PropSpec = struct {
    name: []const u8,
    /// JSON Schema type: "string" / "integer" / "number" / "boolean" / "array" / "object"
    type: []const u8,
    description: []const u8 = "",
    /// array 元素类型（type=="array" 时输出 "items":{"type":...}）。
    items_type: ?[]const u8 = null,
    /// 枚举取值（输出 "enum":[...]）。
    enum_values: ?[]const []const u8 = null,
    /// array 元素是 object 时,元素对象的字段(输出 "items":{"type":"object","properties":{...}})。
    /// 与 items_type 二选一:有 items_props 则 items 是对象 schema,否则用 items_type 简单类型。
    items_props: ?[]const PropSpec = null,
    /// items_props 里哪些字段必填(array-of-object 的元素 required)。
    items_required: ?[]const []const u8 = null,
    /// type=="object" 时,对象自身的字段(输出 "properties":{...})。支持嵌套对象。
    object_props: ?[]const PropSpec = null,
    /// object_props 里哪些字段必填。
    object_required: ?[]const []const u8 = null,
};

pub const InputSchema = struct {
    type: []const u8 = "object",
    /// 动态工具（MCP/Skill）运行时构造的 properties。与 prop_specs 二选一。
    properties: ?std.json.ObjectMap = null,
    /// 内置工具 comptime 声明的 properties。非 null 时优先于 properties 序列化。
    prop_specs: ?[]const PropSpec = null,
    required: ?[]const []const u8 = null,
    /// Root-object `additionalProperties`, boolean form only (issue #35).
    ///
    /// `null` means the tool declared nothing, and the serialized schema is
    /// byte-identical to what it was before this field existed — provider
    /// prefix caches must not move because a representation gap was closed.
    /// The schema-valued form (`additionalProperties: {...}`) is deliberately
    /// not representable here; a boundary that cannot preserve it must reject
    /// it rather than accept and silently drop it. Nothing in Core enforces
    /// the constraint locally: it is declaration passed through to the model
    /// provider, which remains the authority on JSON Schema semantics.
    additional_properties: ?bool = null,
};

/// 序列化请求为 JSON 字节串。调用方 free。
pub fn serializeMessagesRequest(req: MessagesRequest, allocator: std.mem.Allocator) ![]u8 {
    return serializeMessagesRequestWithDialect(
        req,
        allocator,
        dialect_mod.dialectFor(.anthropic, req.model),
    );
}

/// Provider 中立的 canonical 请求投影(预算记账/journal 身份/token 估算用)。
/// 不是真实 provider 请求:图像能力门属于真实发送路径(与 AgentCore 预检),
/// 投影必须对任意 Session model 可计算——否则非 claude 命名的 vision 模型
/// (如 gpt-*/gemini-*)带图时,记账序列化自己先报 ImageInputUnsupported,
/// 真实请求反而从未发出。故此处强制放行 image 位,始终按 Anthropic base64
/// image source block 形态计字节;text-only 请求字节与 serializeMessagesRequest
/// 完全一致。
pub fn serializeCanonicalRequestProjection(req: MessagesRequest, allocator: std.mem.Allocator) ![]u8 {
    var dialect = dialect_mod.dialectFor(.anthropic, req.model);
    dialect.profileFn = canonicalProjectionProfile;
    return serializeMessagesRequestWithDialect(req, allocator, dialect);
}

fn canonicalProjectionProfile(
    _: *anyopaque,
    kind: @import("dialect.zig").ProviderKind,
    model: []const u8,
) @import("dialect.zig").ModelProfile {
    var profile = @import("model_adapter.zig").profileFor(kind, model);
    profile.supports_image_input = true;
    return profile;
}

/// Runtime-scoped variant. The selected Dialect is pinned by the Session's
/// immutable plugin Snapshot; plugin metadata/generation never enters the
/// serialized request, preserving provider prefix-cache identity.
/// 序列化器对图像 tool_result 的**实际**决定:每命中一个规范图像结果 `image_results += 1`;
/// 走占位分支(方言/profile 不发原生图像块)`image_placeholders += 1` 并记下其 tool_use_id。
/// 客户端据此填 StreamHandle.image_placeholder_ids——送达水位只认序列化器自己的报告,绝不事后重算能力
/// (插件方言可以在 profile 声称支持时仍拒绝发图,默认 Dialect 就是这样 fail-closed)。
pub const SerializationReport = struct {
    image_results: usize = 0,
    image_placeholders: usize = 0,
    /// 走占位分支的每个图像结果的 tool_use_id(借用请求消息里的字节)。客户端把它交给
    /// 流句柄,送达水位据此只保护**模型没看到图**的那些消息——插件方言可能按 MIME 一部分
    /// 发原生块、一部分占位,单个布尔表达不了。
    placeholder_ids: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *SerializationReport, allocator: std.mem.Allocator) void {
        self.placeholder_ids.deinit(allocator);
    }

    pub fn notePlaceholder(self: *SerializationReport, allocator: std.mem.Allocator, tool_use_id: []const u8) !void {
        self.image_placeholders += 1;
        try self.placeholder_ids.append(allocator, tool_use_id);
    }

    pub fn imagesNative(self: SerializationReport) bool {
        return self.image_placeholders == 0;
    }
};

pub fn serializeMessagesRequestWithDialect(
    req: MessagesRequest,
    allocator: std.mem.Allocator,
    dialect: @import("dialect.zig").Dialect,
) ![]u8 {
    var scratch = SerializationReport{};
    defer scratch.deinit(allocator);
    return serializeMessagesRequestWithDialectReport(req, allocator, dialect, &scratch);
}

pub fn serializeMessagesRequestWithDialectReport(
    req: MessagesRequest,
    allocator: std.mem.Allocator,
    dialect: @import("dialect.zig").Dialect,
    report: *SerializationReport,
) ![]u8 {
    var result: std.ArrayList(u8) = .{ .items = &.{}, .capacity = 0 };
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "{\"model\":");
    try util_json.serializeString(req.model, &result, allocator);

    try result.appendSlice(allocator, ",\"max_tokens\":");
    const mt = try std.fmt.allocPrint(allocator, "{d}", .{req.max_tokens});
    defer allocator.free(mt);
    try result.appendSlice(allocator, mt);

    const profile = dialect.profileFor(.anthropic, req.model);

    try result.appendSlice(allocator, ",\"messages\":");
    try serializeMessages(req.messages, &result, allocator, dialect, profile, report);

    const visible_capabilities = @import("dialect.zig").visibleCapabilities(req.tools);
    var system_buf: std.ArrayList(u8) = .empty;
    defer system_buf.deinit(allocator);
    if (req.system) |s| try system_buf.appendSlice(allocator, s);
    try dialect.injectSystemMods(
        profile,
        req.reasoning_effort,
        &system_buf,
        allocator,
    );
    try dialect.activateCapabilities(
        profile,
        visible_capabilities,
        &system_buf,
        allocator,
    );
    if (system_buf.items.len != 0) {
        try result.appendSlice(allocator, ",\"system\":");
        try util_json.serializeString(system_buf.items, &result, allocator);
    }

    try result.appendSlice(allocator, ",\"stream\":");
    try result.appendSlice(allocator, if (req.stream) "true" else "false");

    if (req.tools) |tools| {
        try result.appendSlice(allocator, ",\"tools\":");
        try serializeTools(tools, &result, allocator);
    }

    // tool_choice:{"type":"auto"} | {"type":"tool","name":"web_search"} 等。
    // 强制工具(forced tool use)由 web_search 子请求用,保证模型必发搜索。
    const route_already_invoked = if (visible_capabilities.required_first) |route|
        route.satisfied or @import("dialect.zig").hasSuccessfulRequiredFirst(req.messages, route)
    else
        false;
    const effective_tool_choice = dialect.routeToolChoice(
        profile,
        visible_capabilities,
        route_already_invoked,
        req.tool_choice,
    );
    if (effective_tool_choice) |tc| {
        try result.appendSlice(allocator, ",\"tool_choice\":{\"type\":");
        try util_json.serializeString(tc.type, &result, allocator);
        if (tc.name) |n| {
            try result.appendSlice(allocator, ",\"name\":");
            try util_json.serializeString(n, &result, allocator);
        }
        try result.append(allocator, '}');
    }

    if (req.reasoning_effort) |effort| {
        // 委托给 ClaudeDialect 序列化 thinking 控制(对齐 metacodes 既有 wire 格式)。
        // dialect 产出 `,"output_config":{"effort":"..."},"thinking":{"type":"adaptive"}` 片段。
        try dialect.serializeThinking(profile, effort, &result, allocator);
    }

    if (req.cache_control) |cc| {
        try result.appendSlice(allocator, ",\"cache_control\":{\"type\":");
        try util_json.serializeString(cc.type, &result, allocator);
        if (cc.ttl) |ttl| {
            try result.appendSlice(allocator, ",\"ttl\":");
            try util_json.serializeString(ttl, &result, allocator);
        }
        try result.append(allocator, '}');
    }

    try result.append(allocator, '}');
    return try result.toOwnedSlice(allocator);
}

fn serializeMessages(
    messages: []const types.ApiMessage,
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    dialect: @import("dialect.zig").Dialect,
    profile: @import("model_adapter.zig").ModelProfile,
    report: *SerializationReport,
) !void {
    try buf.append(allocator, '[');
    for (messages, 0..) |msg, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try buf.appendSlice(allocator, "\"role\":");
        try util_json.serializeString(switch (msg.role) {
            .user => "user",
            .assistant => "assistant",
        }, buf, allocator);
        try buf.appendSlice(allocator, ",\"content\":");
        try serializeContent(msg.content, buf, allocator, dialect, profile, report);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
}

fn serializeContent(
    content: []const types.ApiContent,
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    dialect: @import("dialect.zig").Dialect,
    profile: @import("model_adapter.zig").ModelProfile,
    report: *SerializationReport,
) !void {
    try buf.append(allocator, '[');
    // `first` 而非下标控制逗号:`.reasoning_item` 在本方言里整块跳过(OpenAI
    // Responses 私有的加密续传状态,Anthropic wire 无对应形态),用下标算逗号会
    // 留下多余的 `,`。无 reasoning_item 时输出与旧实现逐字节相同(prompt-cache
    // 前缀契约不变)。**不变式**(buildApiMessages 保证):含 reasoning_item 的
    // 消息一定还有别的 block,故这里不会产出空 `[]`。
    var first = true;
    for (content) |block| {
        if (block == .reasoning_item) continue;
        if (!first) try buf.append(allocator, ',');
        first = false;
        switch (block) {
            .reasoning_item => unreachable, // 上面已 continue
            .text => |t| {
                try buf.append(allocator, '{');
                try buf.appendSlice(allocator, "\"type\":\"text\",\"text\":");
                try util_json.serializeString(t, buf, allocator);
                try buf.append(allocator, '}');
            },
            .thinking => |t| {
                // preserved thinking 回传(Anthropic):thinking block 必须原样、按序回传。
                // 对齐 Claude Opus 4.5+:保留 thinking 提升多轮推理质量。
                try buf.append(allocator, '{');
                try buf.appendSlice(allocator, "\"type\":\"thinking\",\"thinking\":");
                try util_json.serializeString(t, buf, allocator);
                try buf.append(allocator, '}');
            },
            .tool_use => |tu| {
                try buf.append(allocator, '{');
                try buf.appendSlice(allocator, "\"type\":\"tool_use\",\"id\":");
                try util_json.serializeString(tu.id, buf, allocator);
                try buf.appendSlice(allocator, ",\"name\":");
                try util_json.serializeString(tu.name, buf, allocator);
                try buf.appendSlice(allocator, ",\"input\":");
                try buf.appendSlice(allocator, tu.input);
                try buf.append(allocator, '}');
            },
            .tool_result => |tr| {
                try buf.append(allocator, '{');
                try buf.appendSlice(allocator, "\"type\":\"tool_result\",\"tool_use_id\":");
                try util_json.serializeString(tr.tool_use_id, buf, allocator);
                try buf.appendSlice(allocator, ",\"content\":");
                // 图像结果：Read 工具返回 {"type":"image","media_type":..,"data":..}
                // → vision 模型发 content block 数组 [<方言原生图像块>]。Claude 的方言
                //   字节与此前手写形态逐字节相同(prompt cache 前缀契约不变)。
                // 非 vision(如经 Anthropic 网关的 GLM 文本模型,方言返 false)发短
                // 占位文本——绝不把 MB 级 base64(文本或 block 形态)塞给无法看图的模型。
                if (dialect_mod.extractImageResult(tr.content)) |img| image: {
                    report.image_results += 1;
                    const mark = buf.items.len;
                    try buf.append(allocator, '[');
                    if (try dialect.serializeImagePart(profile, img, buf, allocator)) {
                        try buf.append(allocator, ']');
                        break :image;
                    }
                    buf.shrinkRetainingCapacity(mark);
                    try report.notePlaceholder(allocator, tr.tool_use_id);
                    var placeholder: std.ArrayList(u8) = .empty;
                    defer placeholder.deinit(allocator);
                    try dialect_mod.appendImageOmittedPlaceholder(img.media_type, &placeholder, allocator);
                    try util_json.serializeString(placeholder.items, buf, allocator);
                } else {
                    try util_json.serializeString(tr.content, buf, allocator);
                }
                if (tr.is_error) {
                    try buf.appendSlice(allocator, ",\"is_error\":true");
                }
                try buf.append(allocator, '}');
            },
            .image => |img| {
                // 一等图像内容(issue #10):wire 形态委托方言(Claude=base64 source block)。
                // 方言返 false = 该 (provider, model) 不支持图像输入 → 显式能力错误,
                // 绝不静默丢图或降级为文本。
                const emitted = try dialect.serializeImagePart(profile, img, buf, allocator);
                if (!emitted) return error.ImageInputUnsupported;
            },
        }
    }
    try buf.append(allocator, ']');
}

/// 图像形态 tool_result 的判定单一权威在 `dialect.extractImageResult`——线路层
/// (openai/gemini client) 与投影层(估算/身份/预算)必须用同一嗅探,两份实现会漂移。
/// 这里保留别名:`json.zig` 经此再导出给 agent_loop / conversation / session_budget。
pub const ImageResult = types.ImageBlock;
pub const extractImageResult = dialect_mod.extractImageResult;

fn serializeTools(tools: []const ToolDefinition, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buf.append(allocator, '[');
    for (tools, 0..) |tool, i| {
        if (i > 0) try buf.append(allocator, ',');
        try serializeOneTool(tool, buf, allocator);
    }
    try buf.append(allocator, ']');
}

/// 序列化单个工具为 `{"name","description","input_schema":{...}}`(server tool 形态见内)。
/// ToolSearch 用它把命中工具的完整 schema 喂给模型(<functions> 块)。
pub fn serializeOneTool(tool: ToolDefinition, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buf.append(allocator, '{');
    if (tool.server_type) |st| {
        try buf.appendSlice(allocator, "\"type\":");
        try util_json.serializeString(st, buf, allocator);
        try buf.appendSlice(allocator, ",\"name\":");
        try util_json.serializeString(tool.name, buf, allocator);
        if (tool.description.len > 0) {
            try buf.appendSlice(allocator, ",\"description\":");
            try util_json.serializeString(tool.description, buf, allocator);
        }
    } else {
        try buf.appendSlice(allocator, "\"name\":");
        try util_json.serializeString(tool.name, buf, allocator);
        try buf.appendSlice(allocator, ",\"description\":");
        try util_json.serializeString(tool.description, buf, allocator);
        try buf.appendSlice(allocator, ",\"input_schema\":");
        try serializeInputSchema(tool.input_schema, buf, allocator);
    }
    try buf.append(allocator, '}');
}

pub fn serializeInputSchema(schema: InputSchema, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buf.append(allocator, '{');
    try buf.appendSlice(allocator, "\"type\":");
    try util_json.serializeString(schema.type, buf, allocator);
    // OpenAI-compat JSON Schema 校验器要求 object schema **总是**带 "properties"。
    // Anthropic native API 对 null properties 是宽容的，但 napi.origintask.cn 这类兼容
    // 层会返 400 "object schema missing properties"。无参数工具序列化为 "properties":{}
    // 才能两边都接受。
    //
    // 优先级：prop_specs（内置工具 comptime 声明）> properties（动态工具运行时 ObjectMap）
    // > {}（无参数）。prop_specs 给模型完整的字段名+类型+说明，根治"空参/漏参风暴"。
    if (schema.prop_specs) |specs| {
        try buf.appendSlice(allocator, ",\"properties\":{");
        for (specs, 0..) |spec, i| {
            if (i > 0) try buf.append(allocator, ',');
            try serializePropSpec(spec, buf, allocator);
        }
        try buf.append(allocator, '}');
    } else if (schema.properties) |props| {
        try buf.appendSlice(allocator, ",\"properties\":{");
        var first = true;
        var it = props.iterator();
        while (it.next()) |entry| {
            if (!first) try buf.append(allocator, ',');
            first = false;
            try util_json.serializeString(entry.key_ptr.*, buf, allocator);
            try buf.append(allocator, ':');
            try serializeJsonValue(entry.value_ptr.*, buf, allocator);
        }
        try buf.append(allocator, '}');
    } else {
        try buf.appendSlice(allocator, ",\"properties\":{}");
    }
    if (schema.required) |req| {
        try buf.appendSlice(allocator, ",\"required\":[");
        for (req, 0..) |r, i| {
            if (i > 0) try buf.append(allocator, ',');
            try util_json.serializeString(r, buf, allocator);
        }
        try buf.append(allocator, ']');
    }
    // Emitted only when the tool declared it, so a schema that says nothing
    // about undeclared properties serializes exactly as it did before this
    // field existed.
    if (schema.additional_properties) |additional| {
        try buf.appendSlice(allocator, ",\"additionalProperties\":");
        try buf.appendSlice(allocator, if (additional) "true" else "false");
    }
    try buf.append(allocator, '}');
}

/// 序列化单个 PropSpec 为 `"name":{"type":...,"description":...,...}`。
/// 支持嵌套:array-of-object(items_props)、object(object_props)递归输出完整 JSON Schema。
fn serializePropSpec(spec: PropSpec, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try util_json.serializeString(spec.name, buf, allocator);
    try buf.appendSlice(allocator, ":{\"type\":");
    try util_json.serializeString(spec.type, buf, allocator);
    if (spec.description.len > 0) {
        try buf.appendSlice(allocator, ",\"description\":");
        try util_json.serializeString(spec.description, buf, allocator);
    }
    // array 元素:优先 items_props(对象 schema),否则 items_type(简单类型)。
    if (spec.items_props) |iprops| {
        try buf.appendSlice(allocator, ",\"items\":{\"type\":\"object\",\"properties\":{");
        for (iprops, 0..) |p, i| {
            if (i > 0) try buf.append(allocator, ',');
            try serializePropSpec(p, buf, allocator);
        }
        try buf.append(allocator, '}');
        try serializeRequired(spec.items_required, buf, allocator);
        try buf.append(allocator, '}');
    } else if (spec.items_type) |it| {
        try buf.appendSlice(allocator, ",\"items\":{\"type\":");
        try util_json.serializeString(it, buf, allocator);
        try buf.append(allocator, '}');
    }
    // object 自身字段(嵌套对象)。
    if (spec.object_props) |oprops| {
        try buf.appendSlice(allocator, ",\"properties\":{");
        for (oprops, 0..) |p, i| {
            if (i > 0) try buf.append(allocator, ',');
            try serializePropSpec(p, buf, allocator);
        }
        try buf.append(allocator, '}');
        try serializeRequired(spec.object_required, buf, allocator);
    }
    if (spec.enum_values) |vals| {
        try buf.appendSlice(allocator, ",\"enum\":[");
        for (vals, 0..) |v, i| {
            if (i > 0) try buf.append(allocator, ',');
            try util_json.serializeString(v, buf, allocator);
        }
        try buf.append(allocator, ']');
    }
    try buf.append(allocator, '}');
}

/// 输出 `,"required":["a","b"]`(若非空)。
fn serializeRequired(req: ?[]const []const u8, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const r = req orelse return;
    if (r.len == 0) return;
    try buf.appendSlice(allocator, ",\"required\":[");
    for (r, 0..) |name, i| {
        if (i > 0) try buf.append(allocator, ',');
        try util_json.serializeString(name, buf, allocator);
    }
    try buf.append(allocator, ']');
}

fn serializeJsonValue(value: std.json.Value, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    switch (value) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .number_string => |s| try buf.appendSlice(allocator, s),
        .string => |s| try util_json.serializeString(s, buf, allocator),
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buf.append(allocator, ',');
                try serializeJsonValue(item, buf, allocator);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try util_json.serializeString(entry.key_ptr.*, buf, allocator);
                try buf.append(allocator, ':');
                try serializeJsonValue(entry.value_ptr.*, buf, allocator);
            }
            try buf.append(allocator, '}');
        },
    }
}

test "serializeMessagesRequest minimal" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{ .model = "claude-x", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"claude-x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
}

test "serializeMessagesRequest with system prompt" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{ .model = "claude-x", .messages = &.{msg}, .system = "You are X." };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":\"You are X.\"") != null);
}

test "Anthropic GLM dialect activates visible Skill with stable request bytes" {
    const allocator = std.testing.allocator;
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const skill_tool = ToolDefinition{
        .name = "Skill",
        .description = "invoke one bound skill",
        .input_schema = .{},
        .model_activation = .{
            .mode = .required_first,
            .argument_name = "name",
            .argument_value = "verify-change",
        },
    };
    const req = MessagesRequest{
        .model = "glm-5.2",
        .messages = &.{msg},
        .system = "base",
        .tools = &.{skill_tool},
    };

    const first = try serializeMessagesRequest(req, allocator);
    defer allocator.free(first);
    const second = try serializeMessagesRequest(req, allocator);
    defer allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "Model-specific capability activation") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "blocking requirement") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "`verify-change`") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        first,
        "\"tool_choice\":{\"type\":\"tool\",\"name\":\"Skill\"}",
    ) != null);

    const continued_messages = [_]types.ApiMessage{
        msg,
        .{ .role = .assistant, .content = &.{.{ .tool_use = .{
            .id = "skill_1",
            .name = "Skill",
            .input = "{\"name\":\"verify-change\"}",
        } }} },
        .{ .role = .user, .content = &.{.{ .tool_result = .{
            .tool_use_id = "skill_1",
            .content = "instructions",
        } }} },
    };
    const continued = try serializeMessagesRequest(.{
        .model = "glm-5.2",
        .messages = &continued_messages,
        .system = "base",
        .tools = &.{skill_tool},
    }, allocator);
    defer allocator.free(continued);
    try std.testing.expect(std.mem.indexOf(u8, continued, "\"tool_choice\"") == null);

    // Compaction hides the old call/result from provider messages, but the
    // Host carries satisfaction in non-wire metadata. Capability prompt and
    // tool schema remain byte-stable; only the no-longer-needed routing field
    // disappears.
    var satisfied_skill_tool = skill_tool;
    satisfied_skill_tool.model_activation.?.satisfied = true;
    const compacted = try serializeMessagesRequest(.{
        .model = "glm-5.2",
        .messages = &.{msg},
        .system = "base",
        .tools = &.{satisfied_skill_tool},
    }, allocator);
    defer allocator.free(compacted);
    try std.testing.expect(std.mem.indexOf(u8, compacted, "\"tool_choice\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, compacted, "blocking requirement") != null);
    try std.testing.expect(std.mem.indexOf(u8, compacted, "`verify-change`") != null);

    var original_schema: std.ArrayList(u8) = .empty;
    defer original_schema.deinit(allocator);
    var satisfied_schema: std.ArrayList(u8) = .empty;
    defer satisfied_schema.deinit(allocator);
    try serializeOneTool(skill_tool, &original_schema, allocator);
    try serializeOneTool(satisfied_skill_tool, &satisfied_schema, allocator);
    try std.testing.expectEqualStrings(original_schema.items, satisfied_schema.items);

    const wrong_or_failed_messages = [_]types.ApiMessage{
        msg,
        .{ .role = .assistant, .content = &.{.{ .tool_use = .{
            .id = "skill_wrong",
            .name = "Skill",
            .input = "{\"name\":\"another-skill\"}",
        } }} },
        .{ .role = .user, .content = &.{.{ .tool_result = .{
            .tool_use_id = "skill_wrong",
            .content = "not the required route",
        } }} },
        .{ .role = .assistant, .content = &.{.{ .tool_use = .{
            .id = "skill_failed",
            .name = "Skill",
            .input = "{\"name\":\"verify-change\"}",
        } }} },
        .{ .role = .user, .content = &.{.{ .tool_result = .{
            .tool_use_id = "skill_failed",
            .content = "activation failed",
            .is_error = true,
        } }} },
    };
    const still_required = try serializeMessagesRequest(.{
        .model = "glm-5.2",
        .messages = &wrong_or_failed_messages,
        .system = "base",
        .tools = &.{skill_tool},
    }, allocator);
    defer allocator.free(still_required);
    try std.testing.expect(std.mem.indexOf(
        u8,
        still_required,
        "\"tool_choice\":{\"type\":\"tool\",\"name\":\"Skill\"}",
    ) != null);
}

test "Anthropic model-specific activation is absent without visible Skill capability" {
    const allocator = std.testing.allocator;
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{
        .model = "glm-5.2",
        .messages = &.{msg},
        .system = "base",
    };
    const body = try serializeMessagesRequest(req, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "Model-specific capability activation") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":\"base\"") != null);
}

test "Anthropic Claude dialect does not inherit GLM capability activation" {
    const allocator = std.testing.allocator;
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{
        .model = "claude-sonnet-4-5",
        .messages = &.{msg},
        .system = "# Available skills\n- verify: bounded review",
    };
    const body = try serializeMessagesRequest(req, allocator);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "Model-specific capability activation") == null);
}

test "serializeOneTool: 嵌套 PropSpec(array-of-object + object_props)递归输出" {
    const a = std.testing.allocator;
    // 模拟 AskUserQuestion:questions[].options[] 两层 array-of-object 嵌套。
    const tool = ToolDefinition{
        .name = "AskUserQuestion",
        .description = "ask",
        .input_schema = .{
            .type = "object",
            .prop_specs = &.{
                .{
                    .name = "questions",
                    .type = "array",
                    .items_props = &.{
                        .{ .name = "question", .type = "string" },
                        .{ .name = "options", .type = "array", .items_props = &.{
                            .{ .name = "label", .type = "string" },
                            .{ .name = "description", .type = "string" },
                        }, .items_required = &.{ "label", "description" } },
                        .{ .name = "multiSelect", .type = "boolean" },
                    },
                    .items_required = &.{ "question", "options" },
                },
            },
            .required = &.{"questions"},
        },
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serializeOneTool(tool, &buf, a);
    const out = buf.items;
    // 关键断言:嵌套结构真的序列化出来了(模型才能收到正确 schema)。
    try std.testing.expect(std.mem.indexOf(u8, out, "\"items\":{\"type\":\"object\",\"properties\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"label\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"description\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"multiSelect\":{\"type\":\"boolean\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"required\":[\"label\",\"description\"]") != null);
    // options 不再是被当字符串数组(无 items:{"type":"string"} 在 options 位置)。
}

test "serializeMessagesRequest with stream=true" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg}, .stream = true };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}

test "serializeMessagesRequest with forced tool_choice" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{
        .model = "m",
        .messages = &.{msg},
        .tool_choice = .{ .type = "tool", .name = "web_search" },
    };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    // 端到端字节断言:声明的 tool_choice 字段真序列化进请求体(防"声明了未接线")。
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":{\"type\":\"tool\",\"name\":\"web_search\"}") != null);
}

test "serializeMessagesRequest omits tool_choice when null" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "tool_choice") == null);
}

test "serializeMessagesRequest with tool_use content" {
    const msg = types.ApiMessage{
        .role = .assistant,
        .content = &.{.{ .tool_use = .{
            .id = "t1",
            .name = "Read",
            .input = "{\"path\":\"/x\"}",
        } }},
    };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_use\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":\"t1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"Read\"") != null);
}

test "serializeMessagesRequest with tool_result content" {
    const msg = types.ApiMessage{
        .role = .user,
        .content = &.{.{ .tool_result = .{
            .tool_use_id = "t1",
            .content = "ok",
            .is_error = false,
        } }},
    };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_use_id\":\"t1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"is_error\"") == null); // false 不输出
}

test "serializeMessagesRequest with tool_result is_error=true" {
    const msg = types.ApiMessage{
        .role = .user,
        .content = &.{.{ .tool_result = .{
            .tool_use_id = "t1",
            .content = "err",
            .is_error = true,
        } }},
    };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"is_error\":true") != null);
}

test "serializeMessagesRequest with image tool_result emits content block array" {
    const msg = types.ApiMessage{
        .role = .user,
        .content = &.{.{ .tool_result = .{
            .tool_use_id = "t1",
            .content = "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"iVBORw==\"}",
            .is_error = false,
        } }},
    };
    const req = MessagesRequest{ .model = "claude-sonnet-4-20250514", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":[{\"type\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"source\":{\"type\":\"base64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"media_type\":\"image/png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"data\":\"iVBORw==\"") != null);
}

test "serializeMessagesRequest: 非 vision 模型的图像 tool_result → 占位文本(不发 base64)" {
    // 经 Anthropic 网关的 GLM 文本模型:tool_result 图像不能发 image block(网关拒收),
    // 更不能把 base64 当文本发(token 爆炸)。显式短占位,模型知道读到了图但看不了。
    const msg = types.ApiMessage{
        .role = .user,
        .content = &.{.{ .tool_result = .{
            .tool_use_id = "t1",
            .content = "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"iVBORw==\"}",
            .is_error = false,
        } }},
    };
    const req = MessagesRequest{ .model = "glm-5.2", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"[image (image/png) was read successfully but omitted: this model does not support image input]\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "iVBORw==") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"image\"") == null);
}

test "serializeMessagesRequest: 一等 image block 发 Anthropic base64 source(顺序保持)" {
    // issue #10 验收:text 与 image 按原始顺序到达最终请求;MIME/base64 原样。
    const msg = types.ApiMessage{ .role = .user, .content = &.{
        .{ .text = "看这两张图" },
        .{ .image = .{ .media_type = "image/png", .data = "UE5HREFUQQ==" } },
        .{ .text = "中间的文字" },
        .{ .image = .{ .media_type = "image/jpeg", .data = "SlBFR0RBVEE=" } },
    } };
    const req = MessagesRequest{ .model = "claude-sonnet-4", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    const first_img = std.mem.indexOf(u8, body, "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"UE5HREFUQQ==\"}}").?;
    const mid_text = std.mem.indexOf(u8, body, "中间的文字").?;
    const second_img = std.mem.indexOf(u8, body, "\"media_type\":\"image/jpeg\",\"data\":\"SlBFR0RBVEE=\"").?;
    const lead_text = std.mem.indexOf(u8, body, "看这两张图").?;
    try std.testing.expect(lead_text < first_img);
    try std.testing.expect(first_img < mid_text);
    try std.testing.expect(mid_text < second_img);
}

test "serializeMessagesRequest: 不支持 vision 的模型带 image → 显式能力错误" {
    // 经 Anthropic 网关的 GLM 文本模型 profile.supports_image_input=false:
    // 绝不静默丢图/降级为文本,必须显式 error.ImageInputUnsupported。
    const msg = types.ApiMessage{ .role = .user, .content = &.{
        .{ .image = .{ .media_type = "image/png", .data = "QUJD" } },
    } };
    const req = MessagesRequest{ .model = "glm-5.2", .messages = &.{msg} };
    try std.testing.expectError(
        error.ImageInputUnsupported,
        serializeMessagesRequest(req, std.testing.allocator),
    );
}

test "serializeMessagesRequest escapes special chars in text" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "line1\nline2\"quoted\"" }} };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"") != null);
}

test "serializeMessagesRequest includes cache_control by default" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg} };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
}

test "serializeMessagesRequest cache_control with ttl" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{
        .model = "m",
        .messages = &.{msg},
        .cache_control = .{ .type = "ephemeral", .ttl = "1h" },
    };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ttl\":\"1h\"") != null);
}

test "serializeMessagesRequest no cache_control when disabled" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg}, .cache_control = null };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "cache_control") == null);
}

test "serializeMessagesRequest with reasoning effort emits output_config and adaptive thinking" {
    const msg = types.ApiMessage{ .role = .user, .content = &.{.{ .text = "hi" }} };
    const req = MessagesRequest{ .model = "m", .messages = &.{msg}, .reasoning_effort = .high };
    const body = try serializeMessagesRequest(req, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"output_config\":{\"effort\":\"high\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"adaptive\"}") != null);
}

test "serializeInputSchema emits empty properties for zero-arg tool" {
    // Regression: OpenAI-compat layers (napi.origintask.cn 等) 对缺失 "properties" 的 object
    // schema 返 HTTP 400 "object schema missing properties"。本测试锁定行为：
    // 即便 properties=null（无命名参数），序列化输出也要带 "properties":{}。
    const schema = InputSchema{ .type = "object", .properties = null, .required = &.{} };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serializeInputSchema(schema, &buf, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"properties\":{}") != null);
}

test "serializeTools: server tool 带非空 description 会序列化(让模型形成真 query)" {
    const defs = [_]ToolDefinition{.{
        .name = "web_search",
        .description = "Derive a concise query.",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{} },
        .server_type = "web_search_20250305",
    }};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serializeTools(&defs, &buf, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"type\":\"web_search_20250305\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"description\":\"Derive a concise query.\"") != null);
}

test "serializeTools: server tool 空 description 不序列化 description 字段" {
    const defs = [_]ToolDefinition{.{
        .name = "web_search",
        .description = "",
        .input_schema = .{ .type = "object", .properties = null, .required = &.{} },
        .server_type = "web_search_20250305",
    }};
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serializeTools(&defs, &buf, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"description\"") == null);
}

test "serializeInputSchema with required fields still emits properties" {
    // 另一个常见 case：required=["taskId"] 但我们的 InputSchema 没定义
    // properties map。OpenAI 兼容层对这种"声明 required 字段但没在 properties 里"本来
    // 就会抱怨——那是另一个 bug；这里至少保证 properties 字段存在，不漏出 schema-missing
    // properties 的 400。
    const schema = InputSchema{ .type = "object", .properties = null, .required = &.{"taskId"} };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serializeInputSchema(schema, &buf, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"properties\":{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"required\":[\"taskId\"]") != null);
}

test "serializeInputSchema: prop_specs 输出具名字段+类型+说明(根治空 properties)" {
    // 核心回归:有 prop_specs 时 properties 必须含真实字段定义,而非空 {}。
    // 这是 TaskCreate MissingRequiredField bug 的根因——模型拿不到字段名。
    const schema = InputSchema{
        .type = "object",
        .prop_specs = &.{
            .{ .name = "subject", .type = "string", .description = "A brief title for the task" },
            .{ .name = "description", .type = "string", .description = "What needs to be done" },
        },
        .required = &.{ "subject", "description" },
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serializeInputSchema(schema, &buf, std.testing.allocator);
    // 不再是空 properties
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"properties\":{}") == null);
    // 含具名字段 + 类型 + 说明
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"subject\":{\"type\":\"string\",\"description\":\"A brief title for the task\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"description\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"required\":[\"subject\",\"description\"]") != null);
}

test "serializeInputSchema emits a declared boolean additionalProperties" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    const closed = InputSchema{
        .type = "object",
        .prop_specs = &.{.{ .name = "text", .type = "string" }},
        .required = &.{"text"},
        .additional_properties = false,
    };
    try serializeInputSchema(closed, &buf, std.testing.allocator);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}," ++
            "\"required\":[\"text\"],\"additionalProperties\":false}",
        buf.items,
    );

    buf.clearRetainingCapacity();
    try serializeInputSchema(
        .{ .type = "object", .additional_properties = true },
        &buf,
        std.testing.allocator,
    );
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":true}",
        buf.items,
    );
}

test "serializeInputSchema omits additionalProperties when the tool declared none" {
    // Provider-visible bytes are a cache contract: adding the field to the
    // type must not move one byte of a schema that never mentions it.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serializeInputSchema(
        .{ .type = "object", .prop_specs = &.{.{ .name = "text", .type = "string" }}, .required = &.{"text"} },
        &buf,
        std.testing.allocator,
    );
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}",
        buf.items,
    );
}

test "serializeInputSchema: prop_specs 支持 array items 与 enum" {
    const schema = InputSchema{
        .type = "object",
        .prop_specs = &.{
            .{ .name = "tags", .type = "array", .items_type = "string" },
            .{ .name = "mode", .type = "string", .enum_values = &.{ "a", "b" } },
        },
        .required = &.{},
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serializeInputSchema(schema, &buf, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"items\":{\"type\":\"string\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"enum\":[\"a\",\"b\"]") != null);
}

test "canonical 投影:非 claude 命名的 vision 模型带图可计量,text-only 与普通序列化字节一致" {
    const a = std.testing.allocator;
    const image_messages = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{
            .{ .text = "look" },
            .{ .image = .{ .media_type = "image/png", .data = "UE5H" } },
        } },
    };
    // 普通(真实请求)序列化按**模型家族**守门(issue #112):gpt-5.2 是已知 vision 家族,
    // 经 Anthropic 兼容路由照样发原生 image block;glm-5.2 是文本家族 → 显式能力错误。
    const real = try serializeMessagesRequest(.{ .model = "gpt-5.2", .messages = &image_messages }, a);
    defer a.free(real);
    try std.testing.expect(std.mem.indexOf(u8, real, "{\"type\":\"image\",\"source\":{\"type\":\"base64\"") != null);
    try std.testing.expectError(
        error.ImageInputUnsupported,
        serializeMessagesRequest(
            .{ .model = "glm-5.2", .messages = &image_messages },
            a,
        ),
    );
    // canonical 投影对文本家族同样可计量(记账/身份用,不问能力)。
    const projected_text_family = try serializeCanonicalRequestProjection(
        .{ .model = "glm-5.2", .messages = &image_messages },
        a,
    );
    defer a.free(projected_text_family);
    try std.testing.expect(std.mem.indexOf(u8, projected_text_family, "\"type\":\"image\",\"source\"") != null);
    // canonical 投影是记账/身份用的 provider 中立形态:必须对任意模型可计算。
    const projected = try serializeCanonicalRequestProjection(
        .{ .model = "gpt-5.2", .messages = &image_messages },
        a,
    );
    defer a.free(projected);
    try std.testing.expect(std.mem.indexOf(
        u8,
        projected,
        "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"UE5H\"}}",
    ) != null);
    // text-only:投影与普通序列化逐字节一致(记账不改变既有字节)。
    const text_messages = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hello" }} },
    };
    const plain = try serializeMessagesRequest(.{ .model = "gpt-5.2", .messages = &text_messages }, a);
    defer a.free(plain);
    const canonical = try serializeCanonicalRequestProjection(.{ .model = "gpt-5.2", .messages = &text_messages }, a);
    defer a.free(canonical);
    try std.testing.expectEqualStrings(plain, canonical);
}

test "SerializationReport: fail-closed 方言把图像结果计入占位,内建 vision 方言不计" {
    const a = std.testing.allocator;
    const tool_use = [_]types.ApiContent{.{ .tool_use = .{ .id = "t1", .name = "Read", .input = "{}" } }};
    const tool_result = [_]types.ApiContent{.{ .tool_result = .{ .tool_use_id = "t1", .content = "{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"QUJD\"}" } }};
    const msgs = [_]types.ApiMessage{ .{ .role = .assistant, .content = &tool_use }, .{ .role = .user, .content = &tool_result } };
    const req = MessagesRequest{ .model = "claude-sonnet-4-20250514", .max_tokens = 16, .messages = &msgs };
    // 默认 Dialect:profile 是内建(支持 vision),serializeImagePart 却 fail-closed 返回 false。
    var closed = SerializationReport{};
    defer closed.deinit(a);
    const body_closed = try serializeMessagesRequestWithDialectReport(req, a, .{ .ctx = undefined }, &closed);
    defer a.free(body_closed);
    try std.testing.expectEqual(@as(usize, 1), closed.image_results);
    try std.testing.expectEqual(@as(usize, 1), closed.image_placeholders);
    try std.testing.expect(!closed.imagesNative());
    try std.testing.expectEqual(@as(usize, 1), closed.placeholder_ids.items.len);
    try std.testing.expectEqualStrings("t1", closed.placeholder_ids.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, body_closed, "was read successfully but omitted") != null);
    var native = SerializationReport{};
    defer native.deinit(a);
    const body_native = try serializeMessagesRequestWithDialectReport(req, a, dialect_mod.Resolver.builtin().resolve(.anthropic, req.model), &native);
    defer a.free(body_native);
    try std.testing.expectEqual(@as(usize, 1), native.image_results);
    try std.testing.expectEqual(@as(usize, 0), native.image_placeholders);
    try std.testing.expect(native.imagesNative());
}
