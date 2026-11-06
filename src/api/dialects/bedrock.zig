//! # Amazon Bedrock(Converse)接入
//!
//! Bedrock 原生 Converse / ConverseStream wire 的方言。Bedrock 上所有厂商的模型共用
//! 一种请求格式;厂商专有的参数(思考、档位)放进 `additionalModelRequestFields`,
//! 所以这个文件按**模型所属厂商**分支,而不是按 Bedrock 本身。
//!
//! ## 接入点
//!
//! - Provider:`src/provider/profiles/bedrock.zig`,每个区域一个渠道,
//!   `https://bedrock-runtime.<region>.amazonaws.com`(默认 `us-east-1`)。传输层拼
//!   `/model/{modelId}/converse-stream`(modelId 做百分号编码)。
//! - 模型目录:`provider_catalogs` 里声明 `"kind": "bedrock"`,导入 ListFoundationModels
//!   与 ListInferenceProfiles 的结果(`src/provider/bedrock_catalog.zig`),每个模型 ×
//!   区域一条 offer;offer 按目录里的 providerName 声明方言(Anthropic → `.claude` 等)。
//! - 鉴权:Bedrock API Key,环境变量 `AWS_BEARER_TOKEN_BEDROCK`,发
//!   `Authorization: Bearer <key>`。SigV4 签名未实现。
//!
//! ## 协议
//!
//! - `bedrock_converse`:请求是 JSON(`messages` / `system` / `inferenceConfig` /
//!   `toolConfig` / `additionalModelRequestFields`),响应是 **AWS event stream 二进制分帧**
//!   (`application/vnd.amazon.eventstream`,`src/api/aws_event_stream.zig`),不是 SSE。
//! - 事件:`messageStart`、`contentBlockStart`(toolUse 的 id 与 name)、
//!   `contentBlockDelta`(text / toolUse.input 片段 / reasoningContent)、`contentBlockStop`、
//!   `messageStop`(stopReason)、`metadata`(usage);异常帧 `:message-type exception`。
//!
//! ## 思考与推理
//!
//! 由本方言写进 `additionalModelRequestFields` 的成员(片段;客户端包外层对象)。Claude 按
//! 型号代际(`claudeVersion`)走五种合同之一:
//!
//! | Claude 型号 | 选了档位 | none / minimal | 未指定 | 与采样参数、强制工具冲突时 |
//! |---|---|---|---|---|
//! | Opus 5.5、Sonnet 5.5、Fable、Mythos、认不出的更新代际(不能关) | `thinking:{type:adaptive}` + `output_config:{effort}` | 不发 | 不发(服务端默认自适应) | 思考照发,`temperature` / `topP` / 强制 `toolChoice` 不发 |
//! | Sonnet 5、Opus 5、Haiku 5.5(默认开,能关) | 同上 | `thinking:{type:disabled}` | 不发 | 发 `disabled` |
//! | Opus / Sonnet 4.6、Opus 4.7、4.8(默认关,能关) | 同上 | `thinking:{type:disabled}` | 不发 | 不发思考 |
//! | 3.7 Sonnet、Claude 4.0 – 4.5 | `thinking:{type:enabled,budget_tokens:N}` | 不发 | 不发 | 不发思考 |
//! | 3.x 其它、认不出的名字 | 不发 | 不发 | 不发 | — |
//!
//! | 其它厂商 | 选了档位 | none / minimal | 未指定 |
//! |---|---|---|---|
//! | OpenAI gpt-oss | `reasoning_effort`:low / medium / high | 不发 | 不发 |
//! | 其它(含 gpt-oss 以外的 `openai.*`) | 不发 | 不发 | 不发 |
//!
//! - Claude 的 effort 词汇:low / medium / high / xhigh / max;xhigh 只有 4.7 起与 5.x
//!   认,4.6 上发成 max。
//! - 旧 Claude 的预算:low 2048、medium 8192、high 16384、xhigh / max 24576,夹在
//!   `[1024, inferenceConfig.maxTokens - 1]`;`maxTokens` 不超过 1024 时不发思考。
//! - AWS:思考与 `temperature`、`top_p`、`top_k` 以及强制工具(`any` / 指定工具)不兼容。
//!   本方言只按请求形状选字段(`RequestShape` → `Plan`),客户端照 `Plan` 决定发不发
//!   采样参数和强制 `toolChoice`。Claude 的思考字段依赖 `maxTokens` 和请求形状,所以
//!   客户端直接调 `serializeAdditionalFields`,不经 vtable 的 `serializeThinking`
//!   (vtable 版本按"无冲突、无上限"的形状算,供只拿到方言的调用方使用)。
//! - gpt-oss:模型卡写了 effort 可配 low / medium / high;Converse 里的键名
//!   `reasoning_effort` 在 AWS 文档里**没有核实到**(只写了"其它字段放进
//!   additionalModelRequestFields"),沿用 OpenAI 的名字。
//! - 不发 `thinking.display`:Claude 5 起默认 `omitted`(思考文本为空、只有签名),但
//!   Sonnet 5.5 拒收 `display`,`disabled` 时也不能带;要按型号细分才安全,暂不做。
//!
//! ## 回传与缓存
//!
//! - **带工具时必须回传上一条 assistant 的 thinking 块(含签名)**,不得改动或重排。
//!   签名随会话保存:流把每个带签名的 reasoningContent 块(文本 + 签名,或
//!   redactedContent)原样作为一个 `reasoning_item`(`{"reasoningContent":{...}}`,模型名
//!   为门)交给 agent loop,按到达顺序存进 assistant 消息开头,随 transcript /
//!   checkpoint 持久化,resume 之后照样回传。序列化器只回传同一模型、形如
//!   `{"reasoningContent":` 的项,按会话里的位置原样写出。
//! - 只回传位于正文与工具调用**之前**的那一串思考块:那正是它们在响应里的位置。若某个
//!   响应在正文或工具调用之后又出现思考块,它和其后的思考块都不回传(挪到前面就是
//!   重排;AWS 文档说从头或从尾去掉思考块是合法的,从中间去掉会让其后的块失效)。
//! - 每条 assistant 消息的思考都回传,而不是只回传最后一条:消息一旦写出,字节就不再
//!   变,缓存前缀才稳定。**未核实**:压缩或图片 stub 改写了更早的消息之后,5.5 / 5.1
//!   会不会拒收保留下来的签名(AWS 的 thinking-block-binding 页说签名绑定更早的消息)。
//! - 缓存:Claude 型号在 system 末尾、tools 末尾和最后一条消息末尾各放一个
//!   `{"cachePoint":{"type":"default"}}`(AWS 上限每请求 4 个);其它厂商不放(不支持的
//!   型号会拒绝)。
//!
//! ## 已知差异
//!
//! - 图像:`{"image":{"format":"png|jpeg|gif|webp","source":{"bytes":"<base64>"}}}`,
//!   其它 MIME 报能力错误。
//! - `tool_choice`:auto → `{"auto":{}}`,any → `{"any":{}}`,指定工具 →
//!   `{"tool":{"name":...}}`;none 不发 toolChoice(Converse 没有 none)。Claude 思考时
//!   不支持强制工具,见上表最后一列。
//! - 相邻的同角色消息合并成一条(某条消息在这条 wire 上没有可发的块、被跳过之后会出现)。
//!   Converse 是否拒收相邻同角色消息,AWS 文档**没有写**;合并在任何情况下都合法。
//! - 型号代际只能从 ID 里读:application inference profile 的 ARN 不含型号名,即使目录
//!   声明它是 Claude(缓存点照放),也按"认不出"处理,不发思考字段。
//! - 非 Claude 型号(DeepSeek、Qwen、Kimi、MiniMax 等)在 Bedrock 上的思考参数没有接:
//!   它们按型号默认行为思考,思考文本照常从 reasoningContent 解析。
//! - 无 SigV4、无 AWS profile 文件:只有 API Key。
//!
//! ## 来源
//!
//! - https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_ConverseStream.html
//!   (2026-11 核对:请求与事件形态)
//! - https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-use.html(2026-11 核对:
//!   `AWS_BEARER_TOKEN_BEDROCK`、Bearer 头)
//! - https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-adaptive-thinking.html
//!   (2026-11 核对:自适应思考、effort、Converse 里的位置、各型号能否关闭)
//! - https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-extended-thinking.html
//!   (2026-11 核对:旧型号的 budget_tokens 至少 1024 且小于 max_tokens、工具回合必须回传
//!   thinking 块且不得重排、与 temperature / top_p / 强制工具不兼容)
//! - https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-thinking-block-binding.html
//!   (2026-11 核对:签名绑定更早的消息;从头或从尾去掉思考块合法)
//! - https://docs.aws.amazon.com/bedrock/latest/userguide/prompt-caching.html(2026-11 核对:
//!   cachePoint 可放在 system / messages / tools,每请求最多 4 个)
//! - https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-4-6.html
//!   与 model-card-anthropic-claude-opus-4-6.html(2026-11 核对:各渠道的推理 profile ID)

const std = @import("std");
const types = @import("../../types.zig");
const util_json = @import("../../util/json.zig");
const model_adapter = @import("../model_adapter.zig");
const model_name = @import("../model_name.zig");
const dialect_mod = @import("../dialect.zig");
const compat = @import("openai_compat.zig");
const Vendor = @import("../../provider/vendor.zig").Vendor;

const Dialect = dialect_mod.Dialect;
const ModelProfile = model_adapter.ModelProfile;
const ReasoningEffort = types.ReasoningEffort;
const hasSubstr = model_adapter.hasSubstr;

/// The Converse dialect for `model`: the route's declared vendor, else the
/// vendor named by the model id.
pub fn dialectFor(declared: ?Vendor, model: []const u8) Dialect {
    return compat.ready(if (vendorOf(declared, model)) |v| switch (v) {
        .claude => claudeDialect(model),
        // Only gpt-oss documents a configurable effort on Bedrock; the GPT-5
        // line takes Responses-style fields this dialect does not write.
        .openai => if (isGptOss(model)) GptOss.dialect else plain,
        else => plain,
    } else plain);
}

/// The vendor whose fields a request for `model` carries: the declaration,
/// else the vendor named by the model id.
pub fn vendorOf(declared: ?Vendor, model: []const u8) ?Vendor {
    return declared orelse familyOf(model);
}

fn isGptOss(model: []const u8) bool {
    return hasSubstr(model, "gpt-oss");
}

/// Whether a request for `model` can carry thinking fields at all (the
/// `extended_thinking` capability).
pub fn supportsThinking(declared: ?Vendor, model: []const u8) bool {
    const vendor = vendorOf(declared, model) orelse return false;
    return switch (vendor) {
        .claude => claudeVersion(model).generation != .none,
        .openai => isGptOss(model),
        else => false,
    };
}

/// The vendor of a Bedrock model id: `[geo.]provider.model[:version]`, or an
/// ARN ending in one. Null for a provider this repository has no dialect for.
pub fn familyOf(model: []const u8) ?Vendor {
    const provider = providerSegment(model);
    const table = [_]struct { []const u8, Vendor }{
        .{ "anthropic", .claude },
        .{ "deepseek", .deepseek },
        .{ "qwen", .qwen },
        .{ "moonshot", .kimi },
        .{ "moonshotai", .kimi },
        .{ "minimax", .minimax },
        .{ "mistral", .mistral },
        .{ "openai", .openai },
        .{ "zai", .glm },
    };
    for (table) |row| if (model_name.eqlIgnoreCase(provider, row[0])) return row[1];
    return null;
}

/// The model name without the Bedrock wrapping: `us.anthropic.claude-sonnet-4-6`
/// → `claude-sonnet-4-6`, for tables keyed by the vendor's own names.
pub fn bareModel(model: []const u8) []const u8 {
    var id = model;
    if (std.mem.lastIndexOfScalar(u8, id, '/')) |slash| id = id[slash + 1 ..];
    var parts = std.mem.splitScalar(u8, id, '.');
    const first = parts.first();
    var rest_start: usize = first.len + 1;
    for (GEO_PREFIXES) |geo| {
        if (model_name.eqlIgnoreCase(first, geo)) {
            const provider = parts.next() orelse return id;
            rest_start += provider.len + 1;
            break;
        }
    }
    return if (rest_start <= id.len) id[rest_start..] else id;
}

/// Geographic prefixes of cross-region inference profile ids.
const GEO_PREFIXES = [_][]const u8{ "global", "us", "us-gov", "eu", "apac", "jp", "au", "ca" };

fn providerSegment(model: []const u8) []const u8 {
    var id = model;
    if (std.mem.lastIndexOfScalar(u8, id, '/')) |slash| id = id[slash + 1 ..];
    var parts = std.mem.splitScalar(u8, id, '.');
    const first = parts.first();
    for (GEO_PREFIXES) |geo| {
        if (model_name.eqlIgnoreCase(first, geo)) return parts.next() orelse "";
    }
    return first;
}

/// Bedrock Converse image formats.
pub fn imageFormat(media_type: []const u8) ?[]const u8 {
    const table = [_][2][]const u8{
        .{ "image/png", "png" },
        .{ "image/jpeg", "jpeg" },
        .{ "image/gif", "gif" },
        .{ "image/webp", "webp" },
    };
    for (table) |row| if (std.ascii.eqlIgnoreCase(media_type, row[0])) return row[1];
    return null;
}

fn serializeImagePart(ctx: *anyopaque, p: ModelProfile, image: types.ImageBlock, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    _ = p;
    const format = imageFormat(image.media_type) orelse return false;
    try out.appendSlice(a, "{\"image\":{\"format\":\"");
    try out.appendSlice(a, format);
    try out.appendSlice(a, "\",\"source\":{\"bytes\":");
    try util_json.serializeString(image.data, out, a);
    try out.appendSlice(a, "}}}");
    return true;
}

fn bedrockProfile(ctx: *anyopaque, kind: dialect_mod.ProviderKind, model: []const u8) ModelProfile {
    _ = ctx;
    _ = kind;
    return model_adapter.profileFor(.bedrock, model);
}

/// Every Bedrock dialect writes images and answers its profile the same way.
const plain = Dialect{
    .ctx = undefined,
    .serializeImagePartFn = serializeImagePart,
    .profileFn = bedrockProfile,
};

/// Members are written comma-separated, a leading comma only when `out`
/// already holds one (the same fragment contract as Gemini's gen_cfg).
fn member(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8) !void {
    if (out.items.len > 0) try out.append(a, ',');
    try out.appendSlice(a, text);
}

pub const ClaudeGeneration = enum {
    /// No thinking fields: Claude 3 (bar 3.7 Sonnet), 3.5, and any name this
    /// table does not know.
    none,
    /// `type: enabled` + `budget_tokens`; off when omitted (3.7 Sonnet, 4.0 – 4.5).
    budgeted,
    /// Adaptive, `disabled` accepted, off when omitted (Opus/Sonnet 4.6, Opus 4.7, 4.8).
    adaptive,
    /// Adaptive, `disabled` accepted, adaptive when omitted (Sonnet 5, Opus 5, Haiku 5.5).
    adaptive_default_on,
    /// Adaptive and always on: `enabled` and `disabled` are 400 (Opus 5.5,
    /// Sonnet 5.5, Fable, Mythos, and any later generation this table does
    /// not know yet — omitting the field is valid on every adaptive model,
    /// `disabled` is not).
    adaptive_only,
};

pub const ClaudeVersion = struct { generation: ClaudeGeneration, accepts_xhigh: bool };

const Line = enum { opus, sonnet, haiku };

/// Which thinking contract a Claude model id on Bedrock speaks.
pub fn claudeVersion(model: []const u8) ClaudeVersion {
    if (hasSubstr(model, "fable") or hasSubstr(model, "mythos")) return .{ .generation = .adaptive_only, .accepts_xhigh = true };
    const lines = [_]struct { []const u8, Line }{ .{ "opus-", .opus }, .{ "sonnet-", .sonnet }, .{ "haiku-", .haiku } };
    for (lines) |row| {
        const at = std.ascii.indexOfIgnoreCase(model, row[0]) orelse continue;
        const rest = model[at + row[0].len ..];
        var i: usize = 0;
        var major: u32 = 0;
        while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) major = major * 10 + (rest[i] - '0');
        // A generation is one or two digits; `claude-3-7-sonnet-20250219`
        // puts a date after the line name.
        if (i == 0 or i > 2) continue;
        // A minor is one or two digits after `-` or `.`; eight digits is a date.
        var minor: u32 = 0;
        if (i + 1 < rest.len and (rest[i] == '-' or rest[i] == '.')) {
            var j = i + 1;
            var digits: usize = 0;
            var value: u32 = 0;
            while (j < rest.len and std.ascii.isDigit(rest[j])) : (j += 1) {
                value = value * 10 + (rest[j] - '0');
                digits += 1;
            }
            if (digits >= 1 and digits <= 2) minor = value;
        }
        return versionOf(row[1], major, minor);
    }
    // The 3.x naming puts the generation before the line name.
    if (std.ascii.indexOfIgnoreCase(model, "claude-3-7") != null) return .{ .generation = .budgeted, .accepts_xhigh = false };
    return .{ .generation = .none, .accepts_xhigh = false };
}

fn versionOf(line: Line, major: u32, minor: u32) ClaudeVersion {
    const always_on: ClaudeVersion = .{ .generation = .adaptive_only, .accepts_xhigh = true };
    if (major >= 6) return always_on;
    if (major == 5) {
        if (minor == 0) return .{ .generation = .adaptive_default_on, .accepts_xhigh = true };
        if (minor == 5 and line == .haiku) return .{ .generation = .adaptive_default_on, .accepts_xhigh = true };
        return always_on;
    }
    if (major == 4) {
        if (minor >= 7) return .{ .generation = .adaptive, .accepts_xhigh = true };
        if (minor == 6) return .{ .generation = .adaptive, .accepts_xhigh = false };
        return .{ .generation = .budgeted, .accepts_xhigh = false };
    }
    return .{ .generation = .none, .accepts_xhigh = false };
}

/// The thinking budget an older Claude model gets for a neutral level, before
/// `budgetFor` fits it under the request's `maxTokens`.
pub fn budgetTokens(effort: ReasoningEffort) u32 {
    return switch (effort) {
        .none, .minimal => 0,
        .low => 2048,
        .medium => 8192,
        .high => 16384,
        .xhigh, .max => 24576,
    };
}

/// AWS: `budget_tokens` is at least 1,024.
pub const MIN_BUDGET_TOKENS: u32 = 1024;

/// The budget for `effort` under a request whose `maxTokens` is `max_tokens`:
/// at least `MIN_BUDGET_TOKENS`, below `max_tokens`. Null when no budget fits.
pub fn budgetFor(effort: ReasoningEffort, max_tokens: u32) ?u32 {
    if (max_tokens <= MIN_BUDGET_TOKENS) return null;
    return std.math.clamp(budgetTokens(effort), MIN_BUDGET_TOKENS, max_tokens - 1);
}

/// What the rest of a Converse request carries that thinking cannot share it
/// with, and the bound a budget has to fit under.
pub const RequestShape = struct {
    max_tokens: u32 = std.math.maxInt(u32),
    /// `inferenceConfig.temperature` or `topP` is set.
    sampling: bool = false,
    /// `toolChoice` is `any` or a named tool.
    forced_tool: bool = false,
};

/// Which of the caller's members may go out beside the thinking fields the
/// dialect wrote. A Claude model that thinks whatever is sent keeps sampling
/// parameters and a forced tool choice home instead.
pub const Plan = struct {
    sampling: bool = true,
    forced_tool: bool = true,
};

/// Claude's `additionalModelRequestFields` members for one request.
pub fn claudeFields(version: ClaudeVersion, effort: ?ReasoningEffort, shape: RequestShape, out: *std.ArrayList(u8), a: std.mem.Allocator) !Plan {
    const conflict = shape.sampling or shape.forced_tool;
    switch (version.generation) {
        .none => return .{},
        .budgeted => {
            // Off when omitted: a conflicting request simply does not think.
            if (conflict) return .{};
            const e = effort orelse return .{};
            if (!e.active()) return .{};
            const budget = budgetFor(e, shape.max_tokens) orelse return .{};
            var buf: [96]u8 = undefined;
            try member(out, a, try std.fmt.bufPrint(&buf, "\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{budget}));
            return .{};
        },
        .adaptive => {
            if (conflict) return .{};
            const e = effort orelse return .{};
            if (!e.active()) {
                try member(out, a, "\"thinking\":{\"type\":\"disabled\"}");
                return .{};
            }
            try adaptive(version, e, out, a);
            return .{};
        },
        .adaptive_default_on => {
            // On when omitted: a conflicting request switches it off.
            if (conflict) {
                try member(out, a, "\"thinking\":{\"type\":\"disabled\"}");
                return .{};
            }
            const e = effort orelse return .{};
            if (!e.active()) {
                try member(out, a, "\"thinking\":{\"type\":\"disabled\"}");
                return .{};
            }
            try adaptive(version, e, out, a);
            return .{};
        },
        .adaptive_only => {
            const plan: Plan = .{ .sampling = false, .forced_tool = false };
            const e = effort orelse return plan;
            if (!e.active()) return plan;
            try adaptive(version, e, out, a);
            return plan;
        },
    }
}

fn adaptive(version: ClaudeVersion, e: ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    try member(out, a, "\"thinking\":{\"type\":\"adaptive\"},\"output_config\":{\"effort\":");
    const name = switch (e) {
        .xhigh => if (version.accepts_xhigh) "xhigh" else "max",
        else => e.name(),
    };
    try util_json.serializeString(name, out, a);
    try out.append(a, '}');
}

/// One Claude dialect per thinking contract: `serializeThinking` has no model
/// argument, so the contract is chosen when the dialect is. The vtable form
/// knows no request shape; the client calls `serializeAdditionalFields`.
fn ClaudeFor(comptime version: ClaudeVersion) type {
    return struct {
        fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
            _ = ctx;
            _ = p;
            _ = try claudeFields(version, effort, .{}, out, a);
        }

        const dialect = blk: {
            var d = plain;
            d.serializeThinkingFn = serializeThinking;
            break :blk d;
        };
    };
}

fn claudeDialect(model: []const u8) Dialect {
    const v = claudeVersion(model);
    return switch (v.generation) {
        .none => plain,
        .budgeted => ClaudeFor(.{ .generation = .budgeted, .accepts_xhigh = false }).dialect,
        .adaptive => if (v.accepts_xhigh)
            ClaudeFor(.{ .generation = .adaptive, .accepts_xhigh = true }).dialect
        else
            ClaudeFor(.{ .generation = .adaptive, .accepts_xhigh = false }).dialect,
        .adaptive_default_on => ClaudeFor(.{ .generation = .adaptive_default_on, .accepts_xhigh = true }).dialect,
        .adaptive_only => ClaudeFor(.{ .generation = .adaptive_only, .accepts_xhigh = true }).dialect,
    };
}

const GptOss = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        const e = effort orelse return;
        if (!e.active()) return;
        const name: []const u8 = switch (e) {
            .low => "low",
            .medium => "medium",
            else => "high",
        };
        try member(out, a, "\"reasoning_effort\":");
        try util_json.serializeString(name, out, a);
    }

    const dialect = blk: {
        var d = plain;
        d.serializeThinkingFn = serializeThinking;
        break :blk d;
    };
};

/// Write the members of `additionalModelRequestFields` for `model` (no outer
/// braces; empty when the dialect has nothing to say), and say which of the
/// request's own members may go beside them. Claude's fields depend on the
/// request (`shape`) and are computed here; any other vendor's come from the
/// dialect `d`.
pub fn serializeAdditionalFields(d: Dialect, declared: ?Vendor, model: []const u8, effort: ?ReasoningEffort, shape: RequestShape, out: *std.ArrayList(u8), a: std.mem.Allocator) !Plan {
    if (vendorOf(declared, model) == .claude) return claudeFields(claudeVersion(model), effort, shape, out, a);
    try d.serializeThinking(d.profileFor(.bedrock, model), effort, out, a);
    return .{};
}

/// Prompt-cache points are a Claude feature on Bedrock (and Nova, which has
/// no dialect here); other vendors reject the block.
pub fn supportsCachePoints(declared: ?Vendor, model: []const u8) bool {
    return vendorOf(declared, model) == .claude;
}

// ── tests ────────────────────────────────────────────────────────────────────

fn fields(model: []const u8, effort: ?ReasoningEffort, out: *std.ArrayList(u8)) !void {
    _ = try shaped(model, effort, .{}, out);
}

fn shaped(model: []const u8, effort: ?ReasoningEffort, shape: RequestShape, out: *std.ArrayList(u8)) !Plan {
    out.clearRetainingCapacity();
    return serializeAdditionalFields(dialectFor(null, model), null, model, effort, shape, out, std.testing.allocator);
}

test "Bedrock: bare model names for vendor-keyed tables" {
    try std.testing.expectEqualStrings("claude-sonnet-4-6", bareModel("us.anthropic.claude-sonnet-4-6"));
    try std.testing.expectEqualStrings("claude-opus-4-6-v1", bareModel("anthropic.claude-opus-4-6-v1"));
    try std.testing.expectEqualStrings("claude-sonnet-4-6", bareModel("arn:aws:bedrock:us-east-1:1:inference-profile/global.anthropic.claude-sonnet-4-6"));
    try std.testing.expectEqualStrings("plain", bareModel("plain"));
}

test "Bedrock: the vendor is read from the model id, geo prefix and ARN included" {
    try std.testing.expectEqual(Vendor.claude, familyOf("anthropic.claude-sonnet-4-6").?);
    try std.testing.expectEqual(Vendor.claude, familyOf("us.anthropic.claude-opus-4-6-v1").?);
    try std.testing.expectEqual(Vendor.claude, familyOf("global.anthropic.claude-haiku-4-5-20251001-v1:0").?);
    try std.testing.expectEqual(Vendor.claude, familyOf("arn:aws:bedrock:us-east-1:123456789012:inference-profile/us.anthropic.claude-sonnet-4-6").?);
    try std.testing.expectEqual(Vendor.deepseek, familyOf("deepseek.v3-v1:0").?);
    try std.testing.expectEqual(Vendor.openai, familyOf("openai.gpt-oss-120b-1:0").?);
    try std.testing.expect(familyOf("amazon.nova-pro-v1:0") == null);
    try std.testing.expect(familyOf("meta.llama3-3-70b-instruct-v1:0") == null);
}

test "Bedrock Claude: adaptive thinking with effort on 4.6+, xhigh only from 4.7" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try fields("us.anthropic.claude-sonnet-4-6", .high, &out);
    try std.testing.expectEqualStrings("\"thinking\":{\"type\":\"adaptive\"},\"output_config\":{\"effort\":\"high\"}", out.items);
    try fields("us.anthropic.claude-opus-4-6-v1", .xhigh, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"effort\":\"max\"") != null);
    try fields("anthropic.claude-opus-4-7", .xhigh, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"effort\":\"xhigh\"") != null);
    try fields("anthropic.claude-sonnet-5", .none, &out);
    try std.testing.expectEqualStrings("\"thinking\":{\"type\":\"disabled\"}", out.items);
    try fields("anthropic.claude-sonnet-5", null, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "Bedrock Claude: the generation table follows the AWS adaptive-thinking page" {
    const cases = [_]struct { []const u8, ClaudeGeneration }{
        .{ "us.anthropic.claude-opus-5-5", .adaptive_only },
        .{ "global.anthropic.claude-sonnet-5-5", .adaptive_only },
        .{ "anthropic.claude-fable-5-1", .adaptive_only },
        .{ "anthropic.claude-mythos-5", .adaptive_only },
        .{ "anthropic.claude-opus-6", .adaptive_only },
        .{ "us.anthropic.claude-haiku-5-5", .adaptive_default_on },
        .{ "anthropic.claude-opus-5", .adaptive_default_on },
        .{ "anthropic.claude-sonnet-5", .adaptive_default_on },
        .{ "anthropic.claude-opus-4-8", .adaptive },
        .{ "anthropic.claude-opus-4-7", .adaptive },
        .{ "global.anthropic.claude-opus-4-6-v1", .adaptive },
        .{ "jp.anthropic.claude-sonnet-4-6", .adaptive },
        .{ "anthropic.claude-opus-4-5-20251101-v1:0", .budgeted },
        .{ "anthropic.claude-haiku-4-5-20251001-v1:0", .budgeted },
        .{ "anthropic.claude-opus-4-1-20250805-v1:0", .budgeted },
        .{ "anthropic.claude-sonnet-4-20250514-v1:0", .budgeted },
        .{ "anthropic.claude-3-7-sonnet-20250219-v1:0", .budgeted },
        .{ "anthropic.claude-3-5-haiku-20241022-v1:0", .none },
        .{ "anthropic.claude-3-5-sonnet-20241022-v2:0", .none },
        .{ "anthropic.claude-3-haiku-20240307-v1:0", .none },
        .{ "anthropic.claude-instant-v1", .none },
    };
    for (cases) |case| {
        std.testing.expectEqual(case[1], claudeVersion(case[0]).generation) catch |err| {
            std.debug.print("model {s}\n", .{case[0]});
            return err;
        };
    }
}

test "Bedrock Claude: models that cannot switch thinking off never get disabled; Claude 3.5 gets no thinking" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for ([_][]const u8{ "us.anthropic.claude-opus-5-5", "us.anthropic.claude-sonnet-5-5", "anthropic.claude-mythos-5-1" }) |model| {
        try fields(model, .none, &out);
        try std.testing.expectEqual(@as(usize, 0), out.items.len);
        try fields(model, .high, &out);
        try std.testing.expectEqualStrings("\"thinking\":{\"type\":\"adaptive\"},\"output_config\":{\"effort\":\"high\"}", out.items);
    }
    try fields("us.anthropic.claude-haiku-5-5", .none, &out);
    try std.testing.expectEqualStrings("\"thinking\":{\"type\":\"disabled\"}", out.items);
    try fields("anthropic.claude-3-5-haiku-20241022-v1:0", .high, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expect(!supportsThinking(null, "anthropic.claude-3-5-haiku-20241022-v1:0"));
    try std.testing.expect(supportsThinking(null, "anthropic.claude-3-7-sonnet-20250219-v1:0"));
}

test "Bedrock Claude: a budget is at least 1024 and below maxTokens, or there is no thinking" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const model = "anthropic.claude-sonnet-4-5-20250929-v1:0";
    _ = try shaped(model, .max, .{ .max_tokens = 8000 }, &out);
    try std.testing.expectEqualStrings("\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":7999}", out.items);
    _ = try shaped(model, .low, .{ .max_tokens = 1500 }, &out);
    try std.testing.expectEqualStrings("\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":1499}", out.items);
    _ = try shaped(model, .high, .{ .max_tokens = 1024 }, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expectEqual(@as(?u32, 1024), budgetFor(.low, 1025));
    try std.testing.expectEqual(@as(?u32, 16384), budgetFor(.high, 64000));
}

test "Bedrock Claude: thinking never shares a request with sampling or a forced tool" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    // Off when omitted (4.6 – 4.8, budgeted): no thinking, the caller's members go out.
    for ([_][]const u8{ "us.anthropic.claude-sonnet-4-6", "anthropic.claude-sonnet-4-5-20250929-v1:0" }) |model| {
        const plan = try shaped(model, .high, .{ .max_tokens = 32000, .sampling = true }, &out);
        try std.testing.expectEqual(@as(usize, 0), out.items.len);
        try std.testing.expect(plan.sampling and plan.forced_tool);
        const forced = try shaped(model, .high, .{ .max_tokens = 32000, .forced_tool = true }, &out);
        try std.testing.expectEqual(@as(usize, 0), out.items.len);
        try std.testing.expect(forced.forced_tool);
    }
    // On when omitted but switchable: switched off explicitly.
    const on_by_default = try shaped("anthropic.claude-opus-5", .high, .{ .forced_tool = true }, &out);
    try std.testing.expectEqualStrings("\"thinking\":{\"type\":\"disabled\"}", out.items);
    try std.testing.expect(on_by_default.forced_tool);
    // Always on: thinking stays, the conflicting members stay home.
    const always = try shaped("us.anthropic.claude-opus-5-5", .high, .{ .sampling = true, .forced_tool = true }, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"adaptive\"") != null);
    try std.testing.expect(!always.sampling and !always.forced_tool);
    const always_unset = try shaped("anthropic.claude-fable-5-1", null, .{ .sampling = true }, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expect(!always_unset.sampling);
}

test "Bedrock Claude: Fable cannot be switched off; older models get a budget" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try fields("anthropic.claude-fable-5-1", .none, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try fields("anthropic.claude-fable-5-1", .low, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"adaptive\"") != null);
    try fields("anthropic.claude-sonnet-4-5-20250929-v1:0", .high, &out);
    try std.testing.expectEqualStrings("\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":16384}", out.items);
    try fields("anthropic.claude-3-7-sonnet-20250219-v1:0", .none, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    // A dated id is not read as a minor version.
    try std.testing.expectEqual(ClaudeGeneration.budgeted, claudeVersion("anthropic.claude-sonnet-4-20250514-v1:0").generation);
}

test "Bedrock: gpt-oss takes reasoning_effort, other vendors get no fields" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try fields("openai.gpt-oss-120b-1:0", .xhigh, &out);
    try std.testing.expectEqualStrings("\"reasoning_effort\":\"high\"", out.items);
    // The GPT-5 line on Bedrock is not gpt-oss: no gpt-oss field for it.
    try fields("openai.gpt-5-4", .high, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expect(!supportsThinking(null, "openai.gpt-5-4"));
    try fields("deepseek.v3-v1:0", .high, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expect(supportsCachePoints(null, "us.anthropic.claude-sonnet-4-6"));
    try std.testing.expect(!supportsCachePoints(null, "deepseek.v3-v1:0"));
    try std.testing.expect(supportsCachePoints(.claude, "my-provisioned-model-arn"));
}

test "Bedrock: image block by format; an unknown MIME is refused" {
    const a = std.testing.allocator;
    const d = dialectFor(null, "us.anthropic.claude-sonnet-4-6");
    const p = d.profileFor(.bedrock, "us.anthropic.claude-sonnet-4-6");
    try std.testing.expect(p.supports_image_input);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try std.testing.expect(try d.serializeImagePart(p, .{ .media_type = "image/png", .data = "QUJD" }, &out, a));
    try std.testing.expectEqualStrings("{\"image\":{\"format\":\"png\",\"source\":{\"bytes\":\"QUJD\"}}}", out.items);
    out.clearRetainingCapacity();
    try std.testing.expect(!(try d.serializeImagePart(p, .{ .media_type = "image/tiff", .data = "QUJD" }, &out, a)));
}
