//! Dialect:模型方言适配层(vtable),管同协议族内的 wire 变体。
//!
//! 架构定位(详见 plan ~/.metacodes/plans/jolly-glacier.md):
//! ```
//! agent_loop → Provider vtable(协议族:HTTP/SSE/认证)
//!                 ↓
//!             Provider 实现(OpenAIClient / AnthropicClient / GeminiClient)
//!                 ↓
//!             Dialect vtable(wire 变体:thinking/tool 序列化)
//!                 ↓
//!             中立 IR(ApiMessage / ToolDefinition / StreamEvent)
//! ```
//! - Dialect 在 Provider vtable 之下,不替代 Provider。Provider 管协议族(Anthropic SSE /
//!   OpenAI chat-completions / Gemini generateContent),Dialect 管同协议族内的 wire 变体
//!   (thinking 控制 / tool 格式 / tool_choice / response_format / prompt_cache_key...)。
//! - 新增厂商 = 加一个 Dialect struct 文件 + 注册一行,既有代码零改动。
//! - 新增特性 = Dialect 接口加方法(给 default 实现,既有 dialect 不强制改)。
//! - 类比:Django ORM 的 SQL dialect。
//!
//! 借用契约(同 Provider):Dialect 值是廉价值(fn-ptr+指针),按值传;ctx 借用底层实例,
//! 底层必须比 Dialect 值活得久。Runtime 插件提供的 callback 还必须是输入确定的纯投影：
//! 不得把时间、随机数、generation、plugin id 或加载路径写入请求，否则会主动破坏
//! provider prefix cache。Snapshot 固定生命周期，但不会替不可信 callback 伪造确定性。

const std = @import("std");
const types = @import("../types.zig");
const model_adapter = @import("model_adapter.zig");
const openai_dialects = @import("dialects/openai.zig");
const claude_dialects = @import("dialects/claude.zig");
const gemini_dialects = @import("dialects/gemini.zig");
const util_json = @import("../util/json.zig");
const sync = @import("platform").sync;

pub const ProviderKind = model_adapter.ProviderKind;
pub const ModelProfile = model_adapter.ModelProfile;
pub const ReasoningEffort = types.ReasoningEffort;

/// Provider-visible, request-scoped capabilities. This is deliberately typed:
/// a dialect must not infer active tools by scraping prose from the system
/// prompt. New fields default false so existing dialect plugins remain source
/// compatible and only opt into presentation changes they understand.
pub const VisibleCapabilities = struct {
    skill_tool: bool = false,
    /// Present only when exactly one visible tool requests deterministic
    /// first-turn routing. Multiple requests fail closed to ordinary model
    /// choice instead of depending on plugin enumeration order.
    required_first: ?RequiredFirst = null,

    pub const RequiredFirst = struct {
        tool_name: []const u8,
        argument_name: ?[]const u8 = null,
        argument_value: ?[]const u8 = null,
        /// Host-only request state; excluded from tool schemas and capability
        /// prompt text. It only releases provider routing after compaction has
        /// removed the paired call/result from the active API window.
        satisfied: bool = false,
    };

    pub fn requiredSkillInvocation(self: VisibleCapabilities) ?[]const u8 {
        const route = self.required_first orelse return null;
        if (!std.mem.eql(u8, route.tool_name, "Skill")) return null;
        if (!std.mem.eql(u8, route.argument_name orelse return null, "name")) return null;
        const value = route.argument_value orelse return null;
        if (!validInvocationName(value)) return null;
        return value;
    }
};

fn validInvocationName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (!std.ascii.isAlphanumeric(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and
            byte != '_' and byte != ':' and byte != '-') return false;
    }
    return true;
}

/// Derive the typed capability projection from any optional ToolDefinition
/// slice without importing a provider-specific request module here.
pub fn visibleCapabilities(tools: anytype) VisibleCapabilities {
    var out: VisibleCapabilities = .{};
    var required_count: usize = 0;
    if (tools) |definitions| for (definitions) |definition| {
        if (std.mem.eql(u8, definition.name, "Skill")) out.skill_tool = true;
        if (definition.model_activation) |activation| switch (activation.mode) {
            .required_first => {
                required_count += 1;
                if (required_count == 1) out.required_first = .{
                    .tool_name = definition.name,
                    .argument_name = activation.argument_name,
                    .argument_value = activation.argument_value,
                    .satisfied = activation.satisfied,
                } else out.required_first = null;
            },
        };
    };
    return out;
}

/// Exact typed route match. `required_first` is a Host invariant, so merely
/// calling the right tool with the wrong Skill name must not release it.
/// Canonical invocation names cannot contain JSON escapes; the lightweight
/// field extractor is therefore exact for the only argument-bearing route
/// currently admitted by the Runtime.
pub fn matchesRequiredFirst(
    route: VisibleCapabilities.RequiredFirst,
    tool_name: []const u8,
    input_json: []const u8,
) bool {
    if (!std.mem.eql(u8, route.tool_name, tool_name)) return false;
    if (route.argument_name == null and route.argument_value == null) return true;
    const argument_name = route.argument_name orelse return false;
    const argument_value = route.argument_value orelse return false;
    const observed = util_json.extractStringField(input_json, argument_name) orelse
        return false;
    return std.mem.eql(u8, observed, argument_value);
}

/// A required-first route is satisfied only by an exact call followed by its
/// successful paired tool_result. A guessed/wrong Skill name, permission
/// denial, dispatch error, or orphan tool_use keeps the route active.
pub fn hasSuccessfulRequiredFirst(
    messages: []const types.ApiMessage,
    route: VisibleCapabilities.RequiredFirst,
) bool {
    for (messages, 0..) |message, message_index| {
        for (message.content) |content| {
            const tool_use = switch (content) {
                .tool_use => |value| value,
                else => continue,
            };
            if (!matchesRequiredFirst(route, tool_use.name, tool_use.input)) continue;
            for (messages[message_index + 1 ..]) |later| {
                for (later.content) |later_content| switch (later_content) {
                    .tool_result => |result| {
                        if (std.mem.eql(u8, result.tool_use_id, tool_use.id) and
                            !result.is_error) return true;
                    },
                    else => {},
                };
            }
        }
    }
    return false;
}

/// Shared opt-in route for dialects whose provider wire supports forcing one
/// named function. Caller intent wins; ambiguity has already collapsed to
/// `required_first=null` in `visibleCapabilities`.
pub fn routeRequiredFirst(
    capabilities: VisibleCapabilities,
    already_invoked: bool,
    requested: ?ToolChoice,
) ?ToolChoice {
    if (requested != null or already_invoked) return requested;
    const route = capabilities.required_first orelse return null;
    if (route.satisfied) return null;
    return .{ .type = "tool", .name = route.tool_name };
}

/// 模型方言接口。ctx 是 type-erased 的 dialect 实例指针(如 *GlmDialect)。
/// 方法签名全中立类型(ReasoningEffort / ModelProfile / ArrayList),不出现任何 provider 具体类型。
///
/// **default 转发**:未覆盖的方法走 `defaultDialect` 的 no-op / 查表实现,既有 dialect 加新方法
/// 不强制改(向前兼容)。dialectFor() 永不返回 null——未注册模型走 defaultDialect。
pub const Dialect = struct {
    ctx: *anyopaque,

    /// 请求侧:把 thinking 控制(effort)翻译成 wire 格式,追加到 `out`。
    /// 例如 OpenAI 原生发 `,"reasoning_effort":"high"`;GLM 发 `,"thinking":{"type":"enabled"}`;
    /// K3 发 `,"thinking":{"type":"enabled","keep":"all","effort":"high"}`;Anthropic 发顶层
    /// `thinking:{type:adaptive,...}`;Gemini 发 `"thinking_level":"high"` 片段(进 gen_cfg 合并)。
    /// default = no-op(thinking_mode==.none)。
    /// **`out` 契约**:dialect 自行决定逗号策略 + 追加位置。OpenAI/Claude 追加到主请求体
    /// (前导逗号);Gemini 追加到 gen_cfg 子 ArrayList(片段格式,if 非空加前导逗号)。
    /// 调用方按 dialect 文档传对应 ArrayList——serializeOpenAIRequest 传主请求体,
    /// serializeGeminiRequest 传 gen_cfg。**跨 dialect 传错 ArrayList 会生成错误 JSON**
    /// (如 Gemini 片段进主请求体顶层 → 服务端拒)。dialectFor 已按 model 选对 dialect,
    /// 消费方只需用对应的 serialize*Request 函数。
    serializeThinkingFn: *const fn (
        ctx: *anyopaque,
        profile: ModelProfile,
        effort: ?ReasoningEffort,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
    ) anyerror!void = defaultSerializeThinking,

    /// 请求侧:对 system prompt 做厂商特定改写(如 GLM-5 注入 `<reasoning_effort> high` 标签)。
    /// `system_buf` 是调用方预填的原始 system 内容;本方法可追加/改写。
    /// default = no-op。
    injectSystemModsFn: *const fn (
        ctx: *anyopaque,
        profile: ModelProfile,
        effort: ?ReasoningEffort,
        system_buf: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
    ) anyerror!void = defaultInjectSystemMods,

    /// Request-side capability projection. Unlike `injectSystemModsFn`, this
    /// receives the exact tool surface selected for this request, allowing a
    /// model dialect to add deterministic guidance only when the capability is
    /// actually visible. The default is a no-op.
    activateCapabilitiesFn: *const fn (
        ctx: *anyopaque,
        profile: ModelProfile,
        capabilities: VisibleCapabilities,
        system_buf: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
    ) anyerror!void = defaultActivateCapabilities,

    /// Select a provider-facing tool choice from immutable typed metadata.
    /// Explicit caller choice always remains available to the dialect. The
    /// default returns it unchanged; model-specific dialects may opt into a
    /// required-first route only while the named tool has not been called.
    routeToolChoiceFn: *const fn (
        ctx: *anyopaque,
        profile: ModelProfile,
        capabilities: VisibleCapabilities,
        already_invoked: bool,
        requested: ?ToolChoice,
    ) ?ToolChoice = defaultRouteToolChoice,

    /// 响应侧:从原始 chunk 提取 thinking/reasoning 增量(可为 null)。
    /// 调用方负责 free 返回的非 null slice。
    /// default = 始终返 null(不解析)。
    extractThinkingDeltaFn: *const fn (
        ctx: *anyopaque,
        raw_chunk: []const u8,
        allocator: std.mem.Allocator,
    ) anyerror!?[]u8 = defaultExtractThinkingDelta,

    /// 能力查询:tool_choice 支持(none/auto/required/指定函数)。
    /// default = 查 profile.tool_choice_support。
    supportsToolChoiceFn: *const fn (
        ctx: *anyopaque,
        profile: ModelProfile,
        kind: ToolChoiceKind,
    ) bool = defaultSupportsToolChoice,

    /// 能力查询:response_format 支持(none/json_object/json_schema)。
    /// default = 查 profile.response_format_support。
    supportsResponseFormatFn: *const fn (
        ctx: *anyopaque,
        profile: ModelProfile,
        kind: ResponseFormatKind,
    ) bool = defaultSupportsResponseFormat,

    /// 请求侧:把中立 ToolChoice(Anthropic 语义:type=auto/any/tool/none + name?)翻译成
    /// 厂商 wire 格式,追加到 `out`。返回是否追加了内容(false=该 dialect 不发 tool_choice)。
    /// - OpenAI dialect:auto→"auto",any/required→"required",tool+name→{type:function,function:{name}},
    ///   none→"none";GLM-5 仅 auto(其它 dialect 查 supportsToolChoice 降级或拒)。
    /// - Anthropic dialect:原样透传(已是 Anthropic 语义)。
    /// - Gemini dialect:翻成 function_calling_config.mode(AUTO/ANY/NONE)+ allowed_function_names。
    /// default = 不发(no-op,返回 false)。
    serializeToolChoiceFn: *const fn (
        ctx: *anyopaque,
        profile: ModelProfile,
        tc: ?ToolChoice,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
    ) anyerror!bool = defaultSerializeToolChoice,

    /// 请求侧:把中立 ResponseFormat(json_object/json_schema)翻译成厂商 wire,追加到 `out`。
    /// 返回是否追加了内容。default = 不发(不支持 JSON mode 的 dialect / null 入参)。
    /// **`out` 契约**:dialect 自行决定逗号策略。OpenAI 追加到主请求体(前导逗号),
    /// Gemini 追加到 gen_cfg 子 ArrayList(片段格式,if 非空加前导逗号)。调用方按
    /// dialect 文档传对应 ArrayList。
    /// - OpenAI dialect:`,\"response_format\":{\"type\":\"json_object\"}` 或
    ///   `{\"type\":\"json_schema\",\"json_schema\":{schema}}`。GLM-5 仅 json_object(降级 schema→object)。
    /// - Gemini dialect:`\"response_mime_type\":\"application/json\"` 片段(进 gen_cfg 合并)。
    /// - Anthropic dialect:不发(用 system prompt 指示 JSON)。
    serializeResponseFormatFn: *const fn (
        ctx: *anyopaque,
        profile: ModelProfile,
        rf: ?ResponseFormatRequest,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
    ) anyerror!bool = defaultSerializeResponseFormat,

    /// 请求侧:把 prompt_cache_key 翻译成厂商 wire,追加到 `out`。返回是否追加了内容。
    /// default = 不发。
    /// - OpenAI dialect:`,\"prompt_cache_key\":\"<key>\"`(OpenAI/DeepSeek/Kimi 显式 cache 提示)。
    /// - Anthropic dialect:不发(用 cache_control block,既有 request.zig 路径处理)。
    /// - Gemini dialect:不发(用 cachedContent,既有 gemini_client.zig 路径处理)。
    serializePromptCacheKeyFn: *const fn (
        ctx: *anyopaque,
        profile: ModelProfile,
        key: ?[]const u8,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
    ) anyerror!bool = defaultSerializePromptCacheKey,

    /// 请求侧:把 parallel_tool_calls 翻译成厂商 wire,追加到 `out`。返回是否追加了内容。
    /// default = 不发。
    /// - OpenAI dialect:`,\"parallel_tool_calls\":true/false`(Mistral 独有;OpenAI 原生也有此
    ///   字段但默认 true,通常不需要显式发)。能力守门:profile.supports_parallel_tool_calls=false 不发。
    /// - Anthropic dialect:不发(Claude 默认并行,无此控制)。
    /// - Gemini dialect:不发(Gemini 默认并行,无此控制)。
    serializeParallelToolCallsFn: *const fn (
        ctx: *anyopaque,
        profile: ModelProfile,
        enabled: ?bool,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
    ) anyerror!bool = defaultSerializeParallelToolCalls,

    /// 请求侧:把一个中立 image block 翻译成本方言的 content-part wire JSON 片段,
    /// 追加到 `out`。返回 true=已输出;false=该 (dialect, model) 不支持图像输入——
    /// 调用方(provider 序列化器)必须报显式 error.ImageInputUnsupported,绝不静默
    /// 丢弃或降级为文本(issue #10 铁律)。实现内部先查 profile.supports_image_input。
    /// **`out` 契约**:输出单个 content 块/part 对象,不带外围逗号——数组结构与逗号
    /// 由调用方管理(与 message 序列化其余 block 一致)。
    /// - Claude dialect:{"type":"image","source":{"type":"base64","media_type":..,"data":..}}
    /// - OpenAI dialect:{"type":"image_url","image_url":{"url":"data:<mime>;base64,<data>"}}
    ///   (chat/completions 形态;Responses API 的 input_image 是 responses-local,不经此方法)
    /// - Gemini dialect:{"inline_data":{"mime_type":..,"data":..}}
    /// default = 返回 false(fail-closed:未注册方言/other 协议族不知 wire 格式)。
    serializeImagePartFn: *const fn (
        ctx: *anyopaque,
        profile: ModelProfile,
        image: types.ImageBlock,
        out: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
    ) anyerror!bool = defaultSerializeImagePart,

    /// 暴露纯数据 profile 供 UI/agent_loop 快速问能力。单一真相源收口(step 8 后)。
    /// default = 返回 profileFor 的结果。
    profileFn: *const fn (ctx: *anyopaque, kind: ProviderKind, model: []const u8) ModelProfile = defaultProfile,

    /// 便利转发:inline 调对应方法(免调用方写 `dialect.serializeThinkingFn(dialect.ctx, ...)`)。
    pub fn serializeThinking(self: Dialect, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
        try self.serializeThinkingFn(self.ctx, p, effort, out, a);
    }
    pub fn injectSystemMods(self: Dialect, p: ModelProfile, effort: ?ReasoningEffort, sys: *std.ArrayList(u8), a: std.mem.Allocator) !void {
        try self.injectSystemModsFn(self.ctx, p, effort, sys, a);
    }
    pub fn activateCapabilities(self: Dialect, p: ModelProfile, capabilities: VisibleCapabilities, sys: *std.ArrayList(u8), a: std.mem.Allocator) !void {
        try self.activateCapabilitiesFn(self.ctx, p, capabilities, sys, a);
    }
    pub fn routeToolChoice(self: Dialect, p: ModelProfile, capabilities: VisibleCapabilities, already_invoked: bool, requested: ?ToolChoice) ?ToolChoice {
        return self.routeToolChoiceFn(self.ctx, p, capabilities, already_invoked, requested);
    }
    pub fn extractThinkingDelta(self: Dialect, raw: []const u8, a: std.mem.Allocator) !?[]u8 {
        return try self.extractThinkingDeltaFn(self.ctx, raw, a);
    }
    pub fn supportsToolChoice(self: Dialect, p: ModelProfile, k: ToolChoiceKind) bool {
        return self.supportsToolChoiceFn(self.ctx, p, k);
    }
    pub fn supportsResponseFormat(self: Dialect, p: ModelProfile, k: ResponseFormatKind) bool {
        return self.supportsResponseFormatFn(self.ctx, p, k);
    }
    pub fn serializeToolChoice(self: Dialect, p: ModelProfile, tc: ?ToolChoice, out: *std.ArrayList(u8), a: std.mem.Allocator) !bool {
        return try self.serializeToolChoiceFn(self.ctx, p, tc, out, a);
    }
    pub fn serializeResponseFormat(self: Dialect, p: ModelProfile, rf: ?ResponseFormatRequest, out: *std.ArrayList(u8), a: std.mem.Allocator) !bool {
        return try self.serializeResponseFormatFn(self.ctx, p, rf, out, a);
    }
    pub fn serializePromptCacheKey(self: Dialect, p: ModelProfile, key: ?[]const u8, out: *std.ArrayList(u8), a: std.mem.Allocator) !bool {
        return try self.serializePromptCacheKeyFn(self.ctx, p, key, out, a);
    }
    pub fn serializeParallelToolCalls(self: Dialect, p: ModelProfile, enabled: ?bool, out: *std.ArrayList(u8), a: std.mem.Allocator) !bool {
        return try self.serializeParallelToolCallsFn(self.ctx, p, enabled, out, a);
    }
    pub fn serializeImagePart(self: Dialect, p: ModelProfile, image: types.ImageBlock, out: *std.ArrayList(u8), a: std.mem.Allocator) !bool {
        // 能力守门集中在 wrapper:vendor 覆盖 serializeImagePartFn 也绕不开
        // profile.supports_image_input(issue #10 铁律由构造保证,不靠每个实现自觉)。
        if (!p.supports_image_input) return false;
        return try self.serializeImagePartFn(self.ctx, p, image, out, a);
    }
    pub fn profileFor(self: Dialect, kind: ProviderKind, model: []const u8) ModelProfile {
        return self.profileFn(self.ctx, kind, model);
    }

    /// 返回一个填好 ctx 的副本(供 const dialect 声明在运行时填 ctx)。
    pub fn withCtx(self: Dialect, ctx: *anyopaque) Dialect {
        var copy = self;
        copy.ctx = ctx;
        return copy;
    }
};

/// 检测 tool_result content 是否为 Read 工具的图像形态
/// (`{"type":"image","media_type":..,"data":..}`,见 tools/read.zig readImage)。
/// 仅当内容是下述规范形态时返回;否则 null(当文本处理)。
/// 返回的 slice 借用 content 内部字节(未 unescape)——base64/media_type 无需转义,直接透传。
/// 三个协议族的 tool_result 序列化、Conversation 投影豁免、microcompact 豁免与
/// AgentCore 预算包装共用本检测(单一真相):命中后经 serializeImagePart 发方言
/// 原生图像块;不支持图像输入的模型发短占位文本,**绝不**把含 MB 级 base64 的
/// 原始 JSON 当纯文本发给模型。
///
/// 只认**规范形态**,逐段匹配而非按字段名搜索:
/// `{"type":"image","media_type":"<白名单 MIME>","data":"<标准 base64>"}`,
/// 前后允许空白,对象在 data 之后立即结束。任何偏离(未知 MIME、非 base64、
/// 嵌套/尾随字段、超过 types.MAX_IMAGE_BASE64_BYTES)都返回 null——那样的载荷
/// 没有任何 provider 收得下,当普通文本走投影/截断才是有界的。
pub fn extractImageResult(content: []const u8) ?types.ImageBlock {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const prefix = "{\"type\":\"image\",\"media_type\":\"";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    var rest = trimmed[prefix.len..];
    const mt_end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const mt = rest[0..mt_end];
    if (!types.isSupportedImageMediaType(mt)) return null;
    rest = rest[mt_end..];
    const data_key = "\",\"data\":\"";
    if (!std.mem.startsWith(u8, rest, data_key)) return null;
    rest = rest[data_key.len..];
    const data_end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const data = rest[0..data_end];
    if (data.len > types.MAX_IMAGE_BASE64_BYTES or !types.isStandardBase64(data)) return null;
    if (!std.mem.eql(u8, rest[data_end..], "\"}")) return null;
    return .{ .media_type = mt, .data = data };
}

/// tool_result 图像在不支持图像输入的模型上的显式占位文本(绝不发 base64 原文)。
/// 告知模型:图像已成功读取,但当前模型无图像输入能力。字节形态被 L2 测试锁定。
/// **纯文本契约**:输出未做 JSON 转义;调用方嵌入请求 JSON 时必须经 serializeString
/// (media_type 不受信任,异常字节由该层转义,不会破坏请求结构)。
pub fn appendImageOmittedPlaceholder(media_type: []const u8, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try out.appendSlice(allocator, "[image (");
    try out.appendSlice(allocator, media_type);
    try out.appendSlice(allocator, ") was read successfully but omitted: this model does not support image input]");
}

/// Immutable, Runtime-scoped dialect lookup. A Provider client borrows this
/// value for its whole lifetime, so a RuntimeHost replacement cannot change
/// the behavior of already-admitted Sessions. The built-in resolver preserves
/// the pre-plugin lookup table for ordinary CLI/App construction.
pub const Resolver = struct {
    ctx: *const anyopaque = @ptrFromInt(@as(usize, 0x1)),
    resolveFn: *const fn (ctx: *const anyopaque, kind: ProviderKind, model: []const u8) Dialect = resolveBuiltin,

    pub fn resolve(self: Resolver, kind: ProviderKind, model: []const u8) Dialect {
        return self.resolveFn(self.ctx, kind, model);
    }

    pub fn builtin() Resolver {
        return .{};
    }
};

fn resolveBuiltin(_: *const anyopaque, kind: ProviderKind, model: []const u8) Dialect {
    return dialectFor(kind, model);
}

pub const ToolChoiceKind = enum { none, auto, required, function };
pub const ResponseFormatKind = enum { none, json_object, json_schema };

/// 中立 ToolChoice。与 `api/request.zig ToolChoice` 同构(单申明源:api/request.zig);
/// 这里 alias 避免重复定义 + 消费方手动 copy 字段(openai_client / gemini_client
/// 可直接传 `json_mod.ToolChoice` 给 dialect,无需 `.type/.name` 拆装)。
pub const ToolChoice = @import("request.zig").ToolChoice;

/// 中立 ResponseFormat 请求(JSON mode)。dialect.serializeResponseFormat 翻译成各家 wire。
/// - json_object:要求模型输出合法 JSON(不指定 schema)
/// - json_schema:要求模型输出符合 schema 的 JSON(OpenAI structured output)
pub const ResponseFormatRequest = struct {
    kind: ResponseFormatKind,
    /// kind==json_schema 时的 JSON schema 字符串(已 JSON 字符串,直接内联)。
    /// null + json_schema → 退化为 json_object(能力降级,如 GLM-5)。
    schema: ?[]const u8 = null,
};

// ── default 实现(未覆盖方法的兜底)──────────────────────────────────────────

fn defaultSerializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
    _ = ctx;
    _ = p;
    _ = effort;
    _ = out;
    _ = a;
    // no-op:thinking_mode==.none 或 dialect 未覆盖 → 不发 thinking wire。
}

fn defaultInjectSystemMods(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, sys: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
    _ = ctx;
    _ = p;
    _ = effort;
    _ = sys;
    _ = a;
    // no-op:不改 system prompt。
}

fn defaultActivateCapabilities(ctx: *anyopaque, p: ModelProfile, capabilities: VisibleCapabilities, sys: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
    _ = ctx;
    _ = p;
    _ = capabilities;
    _ = sys;
    _ = a;
}

fn defaultRouteToolChoice(ctx: *anyopaque, p: ModelProfile, capabilities: VisibleCapabilities, already_invoked: bool, requested: ?ToolChoice) ?ToolChoice {
    _ = ctx;
    _ = p;
    _ = capabilities;
    _ = already_invoked;
    return requested;
}

fn defaultExtractThinkingDelta(ctx: *anyopaque, raw: []const u8, a: std.mem.Allocator) anyerror!?[]u8 {
    _ = ctx;
    _ = raw;
    _ = a;
    return null;
}

fn defaultSupportsToolChoice(ctx: *anyopaque, p: ModelProfile, k: ToolChoiceKind) bool {
    _ = ctx;
    return switch (p.tool_choice_support) {
        .full => k == .auto or k == .none or k == .required or k == .function,
        .auto_only => k == .auto,
    };
}

fn defaultSupportsResponseFormat(ctx: *anyopaque, p: ModelProfile, k: ResponseFormatKind) bool {
    _ = ctx;
    return switch (p.response_format_support) {
        .json_schema => k == .json_object or k == .json_schema,
        .json_object_only => k == .json_object,
    };
}

fn defaultSerializeToolChoice(ctx: *anyopaque, p: ModelProfile, tc: ?ToolChoice, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    _ = p;
    _ = tc;
    _ = out;
    _ = a;
    // no-op:default 不发 tool_choice(由 Provider 自己处理,如 Anthropic request.zig 既有路径)。
    return false;
}

fn defaultSerializeResponseFormat(ctx: *anyopaque, p: ModelProfile, rf: ?ResponseFormatRequest, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    _ = p;
    _ = rf;
    _ = out;
    _ = a;
    return false;
}

fn defaultSerializePromptCacheKey(ctx: *anyopaque, p: ModelProfile, key: ?[]const u8, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    _ = p;
    _ = key;
    _ = out;
    _ = a;
    return false;
}

fn defaultSerializeParallelToolCalls(ctx: *anyopaque, p: ModelProfile, enabled: ?bool, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    _ = p;
    _ = enabled;
    _ = out;
    _ = a;
    return false;
}

fn defaultSerializeImagePart(ctx: *anyopaque, p: ModelProfile, image: types.ImageBlock, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    _ = p;
    _ = image;
    _ = out;
    _ = a;
    // fail-closed:default/other 协议族不知图像 wire 格式 → false,调用方报显式能力错误。
    return false;
}

fn defaultProfile(ctx: *anyopaque, kind: ProviderKind, model: []const u8) ModelProfile {
    _ = ctx;
    return model_adapter.profileFor(kind, model);
}

// ── dialectFor:按 (provider_kind, model) 返回 Dialect ────────────────────────
//
// 当前(step 1)只返 defaultDialect——无 ctx 的空实现,所有方法走 default。
// step 2-4 会加 OpenAI-compatible dialect(glm/kimi/deepseek/qwen/mistral),
// step 6-7 加 ClaudeDialect / GeminiDialect。注册表见下方 Registry。

const defaultDialect = Dialect{ .ctx = @ptrFromInt(@as(usize, 0x1)) };

/// 按 (provider_kind, model) 返回 Dialect。永不返回 null——未注册模型走 defaultDialect。
/// 借用:返回的 Dialect 值是静态的(defaultDialect)或 ctx 借用底层实例(具体 dialect)。
pub fn dialectFor(kind: ProviderKind, model: []const u8) Dialect {
    return switch (kind) {
        .openai => openai_dialects.openaiDialectFor(model),
        .anthropic => claude_dialects.claudeDialectFor(model),
        .gemini => gemini_dialects.geminiDialectFor(model),
        .other => defaultDialect,
    };
}

// ── Standalone registry utility ───────────────────────────────────────────
//
// Kept for source compatibility and isolated callers, but deliberately not
// consulted by `dialectFor` or Runtime providers. A process-global mutable
// registry would let a hot reload change old Sessions behind their backs.
// Runtime plugins publish dialects through plugin Snapshot + Resolver instead.

pub const DialectRegistry = struct {
    mutex: sync.Mutex = .{},
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        kind: ProviderKind,
        model_prefix: []const u8,
        dialect: Dialect,
    };

    pub fn register(self: *DialectRegistry, allocator: std.mem.Allocator, kind: ProviderKind, model_prefix: []const u8, dialect: Dialect) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.entries.append(allocator, .{ .kind = kind, .model_prefix = model_prefix, .dialect = dialect });
    }

    pub fn lookup(self: *DialectRegistry, kind: ProviderKind, model: []const u8) ?Dialect {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |e| {
            if (e.kind == kind and std.mem.startsWith(u8, model, e.model_prefix)) return e.dialect;
        }
        return null;
    }
};

pub var registry: DialectRegistry = .{};

// ── 测试 ─────────────────────────────────────────────────────────────────────

test "dialectFor: 未注册 OpenAI 模型走 OpenAINative dialect" {
    // step 2-4 后:未注册 OpenAI 模型默认走 OpenAINative dialect(发 reasoning_effort),
    // 不再是 defaultDialect(no-op)。profile.thinking_mode 仍为 .openai_effort。
    const d = dialectFor(.openai, "some-unknown-model");
    const p = d.profileFor(.openai, "some-unknown-model");
    try std.testing.expect(p.thinking_mode == .openai_effort);
}

test "defaultDialect: serializeThinking 走 OpenAINative(effort=high 发 reasoning_effort)" {
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "unknown");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const p = d.profileFor(.openai, "unknown");
    try d.serializeThinking(p, .high, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"reasoning_effort\":\"high\"") != null);
}

test "defaultDialect: extractThinkingDelta OpenAI 原生返 null" {
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "unknown");
    const got = try d.extractThinkingDelta("{\"choices\":[]}", a);
    try std.testing.expect(got == null);
}

test "defaultDialect: supportsToolChoice 查 profile" {
    const d = dialectFor(.openai, "gpt-4o");
    const p = d.profileFor(.openai, "gpt-4o");
    // gpt-4o 默认 tool_choice_support==.full
    try std.testing.expect(d.supportsToolChoice(p, .auto));
    try std.testing.expect(d.supportsToolChoice(p, .required));
    const glm = d.profileFor(.openai, "glm-5.2");
    try std.testing.expect(d.supportsToolChoice(glm, .auto));
    try std.testing.expect(!d.supportsToolChoice(glm, .required));
}

test "defaultDialect: supportsResponseFormat 查 profile" {
    const d = dialectFor(.openai, "gpt-4o");
    const p = d.profileFor(.openai, "gpt-4o");
    try std.testing.expect(d.supportsResponseFormat(p, .json_object));
    const glm = d.profileFor(.openai, "glm-5.2");
    try std.testing.expect(d.supportsResponseFormat(glm, .json_object));
    try std.testing.expect(!d.supportsResponseFormat(glm, .json_schema));
}

test "DialectRegistry: register + lookup" {
    const a = std.testing.allocator;
    var reg: DialectRegistry = .{};
    defer reg.entries.deinit(a);
    const testDialect = Dialect{ .ctx = @ptrFromInt(@as(usize, 0x2)) };
    try reg.register(a, .openai, "test-model-", testDialect);
    const found = reg.lookup(.openai, "test-model-123");
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(usize, 0x2), @intFromPtr(found.?.ctx));
    try std.testing.expect(reg.lookup(.openai, "other-model") == null);
}

// ── M4:response_format 端到端字节断言(声明=接线=测试 DoD)──────────────────────

test "M4 OpenAI dialect: response_format json_object 发 wire" {
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "gpt-4o");
    const p = d.profileFor(.openai, "gpt-4o");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeResponseFormat(p, .{ .kind = .json_object }, &out, a);
    try std.testing.expect(got);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"response_format\":{\"type\":\"json_object\"}") != null);
}

test "M4 OpenAI dialect: response_format json_schema + schema 发完整 wire" {
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "gpt-4o");
    const p = d.profileFor(.openai, "gpt-4o");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeResponseFormat(p, .{ .kind = .json_schema, .schema = "{\"type\":\"object\"}" }, &out, a);
    try std.testing.expect(got);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"response\",\"schema\":{\"type\":\"object\"}}}") != null);
}

test "M4 OpenAI dialect: GLM-5 json_schema 降级为 json_object(能力守门)" {
    // 声明=接线=测试:GLM-5 profile.response_format_support==.json_object_only,
    // json_schema 必须降级为 json_object。不降级 → 服务端 400。
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "glm-5.2");
    const p = d.profileFor(.openai, "glm-5.2");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeResponseFormat(p, .{ .kind = .json_schema, .schema = "{\"type\":\"object\"}" }, &out, a);
    try std.testing.expect(got);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"response_format\":{\"type\":\"json_object\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "json_schema") == null);
}

test "M4 OpenAI dialect: response_format null 不发" {
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "gpt-4o");
    const p = d.profileFor(.openai, "gpt-4o");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeResponseFormat(p, null, &out, a);
    try std.testing.expect(!got);
    try std.testing.expect(out.items.len == 0);
}

test "M4 OpenAI dialect: response_format none 不发" {
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "gpt-4o");
    const p = d.profileFor(.openai, "gpt-4o");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeResponseFormat(p, .{ .kind = .none }, &out, a);
    try std.testing.expect(!got);
    try std.testing.expect(out.items.len == 0);
}

test "M4 OpenAI dialect: json_schema 缺 schema 退到 json_object" {
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "gpt-4o");
    const p = d.profileFor(.openai, "gpt-4o");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeResponseFormat(p, .{ .kind = .json_schema, .schema = null }, &out, a);
    try std.testing.expect(got);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"response_format\":{\"type\":\"json_object\"}") != null);
}

test "M4 Gemini dialect: response_format json_object → response_mime_type 片段" {
    // 片段格式:不带 ,"generation_config":{ 包裹(由 serializeGeminiRequest 合并)。
    const a = std.testing.allocator;
    const d = dialectFor(.gemini, "gemini-2.5-pro");
    const p = d.profileFor(.gemini, "gemini-2.5-pro");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeResponseFormat(p, .{ .kind = .json_object }, &out, a);
    try std.testing.expect(got);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"response_mime_type\":\"application/json\"") != null);
    // 不带 generation_config 包裹(片段格式)
    try std.testing.expect(std.mem.indexOf(u8, out.items, "generation_config") == null);
}

test "M4 Gemini dialect: response_format json_schema 降级为 response_mime_type(无 schema 字段)" {
    // Gemini 当前只接 response_mime_type,json_schema 降级为 json_object(同样输出 mime_type)。
    const a = std.testing.allocator;
    const d = dialectFor(.gemini, "gemini-2.5-pro");
    const p = d.profileFor(.gemini, "gemini-2.5-pro");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeResponseFormat(p, .{ .kind = .json_schema, .schema = "{\"type\":\"object\"}" }, &out, a);
    try std.testing.expect(got);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"response_mime_type\":\"application/json\"") != null);
    // Gemini 不发 schema 字段(降级)
    try std.testing.expect(std.mem.indexOf(u8, out.items, "response_schema") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "json_schema") == null);
}

test "M4 Claude dialect: response_format 不发(用 system prompt 指示 JSON)" {
    const a = std.testing.allocator;
    const d = dialectFor(.anthropic, "claude-opus-4");
    const p = d.profileFor(.anthropic, "claude-opus-4");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeResponseFormat(p, .{ .kind = .json_object }, &out, a);
    try std.testing.expect(!got);
    try std.testing.expect(out.items.len == 0);
}

// ── M5:prompt_cache_key 端到端字节断言(声明=接线=测试 DoD)─────────────────────

test "M5 OpenAI dialect: prompt_cache_key Kimi 发 wire" {
    // Kimi K3 profile.supports_prompt_cache_key=true,显式 cache 提示。
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "kimi-k2");
    const p = d.profileFor(.openai, "kimi-k2");
    try std.testing.expect(p.supports_prompt_cache_key);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializePromptCacheKey(p, "session-abc-123", &out, a);
    try std.testing.expect(got);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"prompt_cache_key\":\"session-abc-123\"") != null);
}

test "M5 OpenAI dialect: prompt_cache_key GPT-4o 不发(OpenAI 原生不经此字段,走自动 prefix cache)" {
    // OpenAI 原生自动 prefix cache(服务端自动,不显式 prompt_cache_key),
    // profile.supports_prompt_cache_key=false(只有 Kimi 设 true)。
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "gpt-4o");
    const p = d.profileFor(.openai, "gpt-4o");
    try std.testing.expect(!p.supports_prompt_cache_key);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializePromptCacheKey(p, "key-xyz", &out, a);
    try std.testing.expect(!got);
    try std.testing.expect(out.items.len == 0);
}

test "M5 OpenAI dialect: GLM-5 不支持 prompt_cache_key(能力守门)" {
    // GLM-5 profile.supports_prompt_cache_key=false,不发(能力探测诚实)。
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "glm-5.2");
    const p = d.profileFor(.openai, "glm-5.2");
    try std.testing.expect(!p.supports_prompt_cache_key);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializePromptCacheKey(p, "key", &out, a);
    try std.testing.expect(!got);
    try std.testing.expect(out.items.len == 0);
}

test "M5 OpenAI dialect: prompt_cache_key null 不发" {
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "kimi-k2");
    const p = d.profileFor(.openai, "kimi-k2");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializePromptCacheKey(p, null, &out, a);
    try std.testing.expect(!got);
    try std.testing.expect(out.items.len == 0);
}

test "M5 Claude dialect: prompt_cache_key 不发(用 cache_control block)" {
    const a = std.testing.allocator;
    const d = dialectFor(.anthropic, "claude-opus-4");
    const p = d.profileFor(.anthropic, "claude-opus-4");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializePromptCacheKey(p, "key", &out, a);
    try std.testing.expect(!got);
    try std.testing.expect(out.items.len == 0);
}

test "M5 Gemini dialect: prompt_cache_key 不发(用 cachedContent)" {
    const a = std.testing.allocator;
    const d = dialectFor(.gemini, "gemini-2.5-pro");
    const p = d.profileFor(.gemini, "gemini-2.5-pro");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializePromptCacheKey(p, "key", &out, a);
    try std.testing.expect(!got);
    try std.testing.expect(out.items.len == 0);
}

// ── M6:parallel_tool_calls 端到端字节断言(声明=接线=测试 DoD)────────────────────

test "M6 OpenAI dialect: parallel_tool_calls Mistral true 发 wire" {
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "mistral-large");
    const p = d.profileFor(.openai, "mistral-large");
    try std.testing.expect(p.supports_parallel_tool_calls);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeParallelToolCalls(p, true, &out, a);
    try std.testing.expect(got);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"parallel_tool_calls\":true") != null);
}

test "M6 OpenAI dialect: parallel_tool_calls Mistral false 发 wire" {
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "mistral-large");
    const p = d.profileFor(.openai, "mistral-large");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeParallelToolCalls(p, false, &out, a);
    try std.testing.expect(got);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"parallel_tool_calls\":false") != null);
}

test "M6 OpenAI dialect: GPT-4o 不支持 parallel_tool_calls(能力守门)" {
    // GPT-4o profile.supports_parallel_tool_calls=false(OpenAI 原生默认 true,无需显式发)。
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "gpt-4o");
    const p = d.profileFor(.openai, "gpt-4o");
    try std.testing.expect(!p.supports_parallel_tool_calls);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeParallelToolCalls(p, true, &out, a);
    try std.testing.expect(!got);
    try std.testing.expect(out.items.len == 0);
}

test "M6 OpenAI dialect: parallel_tool_calls null 不发" {
    const a = std.testing.allocator;
    const d = dialectFor(.openai, "mistral-large");
    const p = d.profileFor(.openai, "mistral-large");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeParallelToolCalls(p, null, &out, a);
    try std.testing.expect(!got);
    try std.testing.expect(out.items.len == 0);
}

test "M6 Claude dialect: parallel_tool_calls 不发(Claude 默认并行)" {
    const a = std.testing.allocator;
    const d = dialectFor(.anthropic, "claude-opus-4");
    const p = d.profileFor(.anthropic, "claude-opus-4");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeParallelToolCalls(p, true, &out, a);
    try std.testing.expect(!got);
    try std.testing.expect(out.items.len == 0);
}

test "M6 Gemini dialect: parallel_tool_calls 不发(Gemini 默认并行)" {
    const a = std.testing.allocator;
    const d = dialectFor(.gemini, "gemini-2.5-pro");
    const p = d.profileFor(.gemini, "gemini-2.5-pro");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeParallelToolCalls(p, true, &out, a);
    try std.testing.expect(!got);
    try std.testing.expect(out.items.len == 0);
}

test "extractImageResult: 命中 Read 图像形态,忽略普通文本/JSON" {
    try std.testing.expect(extractImageResult("just text") == null);
    try std.testing.expect(extractImageResult("{\"stdout\":\"x\"}") == null);
    const img = extractImageResult("{\"type\":\"image\",\"media_type\":\"image/gif\",\"data\":\"AAAA\"}").?;
    try std.testing.expectEqualStrings("image/gif", img.media_type);
    try std.testing.expectEqualStrings("AAAA", img.data);
    // 前后空白容忍(SSE/transcript 回放可能带换行)。
    const padded = extractImageResult("\n {\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"AA==\"}\n").?;
    try std.testing.expectEqualStrings("AA==", padded.data);
}

test "extractImageResult: 只认规范形态——非白名单 MIME / 非 base64 / 尾随或嵌套字段 / 超限都不是图像" {
    // 非白名单 MIME:方言层发出去 provider 会拒收,当文本走投影才有界。
    try std.testing.expect(extractImageResult("{\"type\":\"image\",\"media_type\":\"image/svg+xml\",\"data\":\"AAAA\"}") == null);
    // 非标准 base64。
    try std.testing.expect(extractImageResult("{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"not base64!!\"}") == null);
    try std.testing.expect(extractImageResult("{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"\"}") == null);
    // 尾随字段:一个插件把 500 KiB 别的东西挂在 data 后面,不能靠前缀混过豁免。
    try std.testing.expect(extractImageResult("{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"AAAA\",\"extra\":\"x\"}") == null);
    // 字段顺序/嵌套:按字段名搜索会命中,逐段匹配不会。
    try std.testing.expect(extractImageResult("{\"type\":\"image\",\"data\":\"AAAA\",\"media_type\":\"image/png\"}") == null);
    try std.testing.expect(extractImageResult("{\"type\":\"image\",\"meta\":{\"media_type\":\"image/png\",\"data\":\"AAAA\"}}") == null);
    // 超过任何 provider 都收不下的尺寸:不是图像。
    const a = std.testing.allocator;
    const oversized = try a.alloc(u8, types.MAX_IMAGE_BASE64_BYTES + 4);
    defer a.free(oversized);
    @memset(oversized, 'A');
    const huge = try std.fmt.allocPrint(a, "{{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"{s}\"}}", .{oversized});
    defer a.free(huge);
    try std.testing.expect(extractImageResult(huge) == null);
    // 正好在上限内的规范形态仍是图像。
    const at_limit = try std.fmt.allocPrint(a, "{{\"type\":\"image\",\"media_type\":\"image/png\",\"data\":\"{s}\"}}", .{oversized[0..types.MAX_IMAGE_BASE64_BYTES]});
    defer a.free(at_limit);
    try std.testing.expect(extractImageResult(at_limit) != null);
}

test "appendImageOmittedPlaceholder: 纯文本占位含 MIME,不含 base64" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendImageOmittedPlaceholder("image/png", &out, a);
    try std.testing.expectEqualStrings(
        "[image (image/png) was read successfully but omitted: this model does not support image input]",
        out.items,
    );
}
