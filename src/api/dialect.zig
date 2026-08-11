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
//! 底层必须比 Dialect 值活得久。

const std = @import("std");
const types = @import("../types.zig");
const model_adapter = @import("model_adapter.zig");
const openai_dialects = @import("dialects/openai.zig");
const claude_dialects = @import("dialects/claude.zig");
const gemini_dialects = @import("dialects/gemini.zig");
const sync = @import("platform").sync;

pub const ProviderKind = model_adapter.ProviderKind;
pub const ModelProfile = model_adapter.ModelProfile;
pub const ReasoningEffort = types.ReasoningEffort;

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
    /// `thinking:{type:adaptive,...}`;Gemini 发 `generation_config.thinkingLevel`。
    /// default = no-op(thinking_mode==.none)。
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

pub const ToolChoiceKind = enum { none, auto, required, function };
pub const ResponseFormatKind = enum { none, json_object, json_schema };

/// 中立 ToolChoice(Anthropic 语义,与 api/request.zig ToolChoice 对齐)。
/// dialect.serializeToolChoice 负责翻译成各家 wire 格式。
pub const ToolChoice = struct {
    /// "auto" / "any"(强制选一个工具) / "tool"(指定 name) / "none"(禁用工具)
    type: []const u8 = "auto",
    /// type=="tool" 时指定工具名;否则 null
    name: ?[]const u8 = null,
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

// ── Registry(运行时留位,comptime 注册走它)─────────────────────────────────
//
// 当前(step 1)无注册项。step 2+ 的 dialect 实现会在 comptime 注册:
//   registry.register(.openai, "glm-5", &glmDialect);
// 未来第三方 dialect 可运行时注册(类似 RequestAbortRegistry)。

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
