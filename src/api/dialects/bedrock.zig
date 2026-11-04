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
//! 由本方言写进 `additionalModelRequestFields` 的成员(片段;客户端包外层对象):
//!
//! | 模型 | 选了档位 | none / minimal | 未指定 |
//! |---|---|---|---|
//! | Claude 4.6 及以后、5.x(自适应思考) | `thinking:{type:adaptive}` + `output_config:{effort}` | `thinking:{type:disabled}`(Fable / Mythos 不能关,不发) | 不发 |
//! | Claude 3.7 / 4.0 / 4.5 | `thinking:{type:enabled,budget_tokens:N}` | 不发 | 不发 |
//! | OpenAI gpt-oss | `reasoning_effort`:low / medium / high | 不发 | 不发 |
//! | 其它 | 不发 | 不发 | 不发 |
//!
//! - Claude 的 effort 词汇:low / medium / high / xhigh / max;xhigh 只有 4.7 起与 5.x
//!   认,4.6 上发成 max。
//! - 旧 Claude 的预算:low 2048、medium 8192、high 16384、xhigh / max 24576,必须小于
//!   `inferenceConfig.maxTokens`。
//!
//! ## 回传与缓存
//!
//! - **带工具时必须回传上一条 assistant 的 thinking 块(含签名)**,否则报错。签名不进
//!   会话记录:客户端把一次响应里的 reasoningContent(文本 + 签名,或 redactedContent)
//!   按这次响应的第一个 toolUseId 存起来,序列化含该 toolUseId 的 assistant 消息时放回
//!   消息开头。只在本进程内有效;跨进程恢复到工具回合中间时,这一轮的思考不回传。
//! - 缓存:Claude 型号在 system 末尾与 tools 末尾各放一个
//!   `{"cachePoint":{"type":"default"}}`;其它厂商不放(不支持的型号会拒绝)。
//!
//! ## 已知差异
//!
//! - 图像:`{"image":{"format":"png|jpeg|gif|webp","source":{"bytes":"<base64>"}}}`,
//!   其它 MIME 报能力错误。
//! - `tool_choice`:auto → `{"auto":{}}`,any → `{"any":{}}`,指定工具 →
//!   `{"tool":{"name":...}}`;none 不发 toolChoice(Converse 没有 none)。Claude 思考时
//!   不支持强制工具。
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
//!   (2026-11 核对:旧型号的 budget_tokens、工具回合必须回传 thinking 块)

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
    const vendor = declared orelse familyOf(model);
    return compat.ready(if (vendor) |v| switch (v) {
        .claude => claudeDialect(model),
        .openai => GptOss.dialect,
        else => plain,
    } else plain);
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
    /// Thinking only through `type: enabled` + `budget_tokens` (3.7 – 4.5).
    budgeted,
    /// Adaptive thinking; `disabled` allowed (4.6 – 4.8, Opus/Sonnet/Haiku 5.x).
    adaptive,
    /// Adaptive only: `enabled` and `disabled` are 400 (Fable, Mythos).
    adaptive_only,
};

pub const ClaudeVersion = struct { generation: ClaudeGeneration, accepts_xhigh: bool };

/// Which thinking contract a Claude model id on Bedrock speaks.
pub fn claudeVersion(model: []const u8) ClaudeVersion {
    if (hasSubstr(model, "fable") or hasSubstr(model, "mythos")) return .{ .generation = .adaptive_only, .accepts_xhigh = true };
    const lines = [_][]const u8{ "opus-", "sonnet-", "haiku-" };
    for (lines) |line| {
        const at = std.ascii.indexOfIgnoreCase(model, line) orelse continue;
        const rest = model[at + line.len ..];
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
        if (major >= 5 or (major == 4 and minor >= 6)) {
            return .{ .generation = .adaptive, .accepts_xhigh = major >= 5 or minor >= 7 };
        }
        return .{ .generation = .budgeted, .accepts_xhigh = false };
    }
    // `claude-3-7-sonnet` and other older names.
    return .{ .generation = .budgeted, .accepts_xhigh = false };
}

/// The thinking budget an older Claude model gets for a neutral level.
pub fn budgetTokens(effort: ReasoningEffort) u32 {
    return switch (effort) {
        .none, .minimal => 0,
        .low => 2048,
        .medium => 8192,
        .high => 16384,
        .xhigh, .max => 24576,
    };
}

/// One Claude dialect per thinking contract: `serializeThinking` has no model
/// argument, so the contract is chosen when the dialect is.
fn ClaudeFor(comptime version: ClaudeVersion) type {
    return struct {
        fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
            _ = ctx;
            _ = p;
            const e = effort orelse return;
            if (!e.active()) {
                if (version.generation == .adaptive) try member(out, a, "\"thinking\":{\"type\":\"disabled\"}");
                return;
            }
            switch (version.generation) {
                .budgeted => {
                    var buf: [96]u8 = undefined;
                    try member(out, a, try std.fmt.bufPrint(&buf, "\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{budgetTokens(e)}));
                },
                .adaptive, .adaptive_only => {
                    try member(out, a, "\"thinking\":{\"type\":\"adaptive\"},\"output_config\":{\"effort\":");
                    const name = switch (e) {
                        .xhigh => if (version.accepts_xhigh) "xhigh" else "max",
                        else => e.name(),
                    };
                    try util_json.serializeString(name, out, a);
                    try out.append(a, '}');
                },
            }
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
        .budgeted => ClaudeFor(.{ .generation = .budgeted, .accepts_xhigh = false }).dialect,
        .adaptive => if (v.accepts_xhigh)
            ClaudeFor(.{ .generation = .adaptive, .accepts_xhigh = true }).dialect
        else
            ClaudeFor(.{ .generation = .adaptive, .accepts_xhigh = false }).dialect,
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
/// braces; empty when the dialect has nothing to say).
pub fn serializeAdditionalFields(d: Dialect, model: []const u8, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    try d.serializeThinking(d.profileFor(.bedrock, model), effort, out, a);
}

/// Prompt-cache points are a Claude feature on Bedrock (and Nova, which has
/// no dialect here); other vendors reject the block.
pub fn supportsCachePoints(declared: ?Vendor, model: []const u8) bool {
    return (declared orelse familyOf(model)) == .claude;
}

// ── tests ────────────────────────────────────────────────────────────────────

fn fields(model: []const u8, effort: ?ReasoningEffort, out: *std.ArrayList(u8)) !void {
    out.clearRetainingCapacity();
    try serializeAdditionalFields(dialectFor(null, model), model, effort, out, std.testing.allocator);
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
