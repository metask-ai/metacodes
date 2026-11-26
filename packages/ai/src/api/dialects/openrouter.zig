//! # OpenRouter 接入
//!
//! OpenRouter 是路由器:一个模型背后挂多家上游(endpoint),每家上游一条 offer。它在
//! OpenAI chat/completions wire 上提供**统一**的推理参数,所以这里的方言只看 OpenRouter
//! 自己的请求面,不看上游是谁——上游的方言差异由 OpenRouter 翻译。
//!
//! ## 接入点
//!
//! - 内置 profile `openrouter`(`packages/ai/src/provider/profiles/openrouter.zig`):一个渠道 `auto`,
//!   请求不带 `provider` 对象,由 OpenRouter 的默认路由挑上游(价格、速度、可用性,失败自动换)。
//!   模型来自账户自己的列表 `GET /api/v1/models/user`(`packages/ai/src/api/openrouter_catalog.zig`,
//!   只留走聊天接口且支持工具的),由 `Host.ingestOpenRouterBuiltin` 导入。
//! - 凭据:浏览器登录换来的 key(`ProviderProfile.key_grant`,`packages/ai/src/api/openrouter_login.zig`,
//!   官方 PKCE)、粘贴的 key,或 `OPENROUTER_API_KEY`;都按普通 API key 存在
//!   `keys/openrouter.json`。
//! - `provider_catalogs` 导入的目录(`ingestOpenRouter`,每个 endpoint 一个渠道,按 tag 命名)
//!   仍可用,但不能用内置的 id `openrouter`。
//! - 端点:`https://openrouter.ai/api/v1`;`METACODES_OPENROUTER_URL` 把所有地址整体换到
//!   https 或本机明文地址(开发、测试)。
//!
//! ## 协议
//!
//! - `openai_chat`。鉴权:Bearer。
//! - 署名(`ATTRIBUTION_HEADERS`,本方言的每个请求都带):`HTTP-Referer` 写项目主页,
//!   `X-OpenRouter-Title` 写 `metacodes`,`X-OpenRouter-Categories` 写 `cli-agent`。
//!   不发 `X-OpenRouter-App-Visibility`:应用在 OpenRouter 的排行里公开。
//!
//! ## 思考与推理
//!
//! - 请求:`reasoning:{"effort": ...}`,取值 none / minimal / low / medium / high / xhigh /
//!   max,与中立档位一一对应,原样发;`none` 关推理(推理必开的模型会拒绝)。未指定不发,
//!   由模型自己决定。
//! - 不发 OpenAI 的顶层 `reasoning_effort`(OpenRouter 文档没有这个请求参数)。
//! - 响应:流式 `delta.reasoning`(字符串);结构化的 `reasoning_details` 不解析。
//!   兼容起见,没有 `reasoning` 时退回读 `reasoning_content`。
//!
//! ## 回传与缓存
//!
//! - 文档建议工具调用时把推理回传(`message.reasoning`,`reasoning_content` 是别名)。
//!   本方言声明 `echoes_reasoning_content`,以 `reasoning_content` 回传 thinking 块——
//!   挂在 DeepSeek 这类"带工具时必须回传"的上游后面时,这是必要的。
//! - 缓存:由上游决定;本方言不发 `prompt_cache_key`。
//!
//! ## 已知差异
//!
//! - 加密 / 摘要型推理(`reasoning_details` 的 encrypted 条目)不保存、不回传。
//! - 图像输入按模型名的家族表判断,目录的 `input_modalities` 声明优先。
//!
//! ## 来源
//!
//! - https://openrouter.ai/docs/use-cases/reasoning-tokens(2026-11 核对:reasoning
//!   对象、effort 取值、流式字段、回传方式)
//! - https://openrouter.ai/docs/api-reference/list-endpoints-for-a-model(目录形态)
//! - https://openrouter.ai/docs/app-attribution(2026-11-18 核对:`HTTP-Referer` 必需、
//!   `X-OpenRouter-Title`(`X-Title` 兼容)、`X-OpenRouter-Categories`、新建应用时的可见性)
//! - https://openrouter.ai/docs/guides/overview/auth/oauth(2026-11-18 核对:PKCE、任意端口的
//!   本机回调、无回调方式、`POST /api/v1/auth/keys`)

const std = @import("std");
const types = @import("../../types.zig");
const util_json = @import("metacodes-base").util.json;
const model_adapter = @import("../model_adapter.zig");
const dialect_mod = @import("../dialect.zig");
const compat = @import("openai_compat.zig");
const Vendor = @import("../../provider/vendor.zig").Vendor;

const Dialect = dialect_mod.Dialect;
const ModelProfile = model_adapter.ModelProfile;
const ProviderKind = model_adapter.ProviderKind;
const ReasoningEffort = types.ReasoningEffort;

pub const vendor: Vendor = .openrouter;

/// Who is calling, said as it is (https://openrouter.ai/docs/app-attribution,
/// 2026-11-18): the project's address identifies the app, the title names
/// it, the category is OpenRouter's for a terminal coding agent. Every
/// request on a route that declares this dialect carries them; none carries
/// anything about the user.
pub const ATTRIBUTION_HEADERS = [_]std.http.Header{
    .{ .name = "HTTP-Referer", .value = "https://github.com/metask-ai/metacodes" },
    .{ .name = "X-OpenRouter-Title", .value = "metacodes" },
    .{ .name = "X-OpenRouter-Categories", .value = "cli-agent" },
};

/// OpenRouter 只能由路由声明,不能从模型名推断(`vendor/model` 形式的名字也可能来自
/// 别的聚合网关)。
pub fn claims(kind: ProviderKind, model: []const u8) bool {
    _ = kind;
    _ = model;
    return false;
}

pub fn dialect(kind: ProviderKind, model: []const u8) ?Dialect {
    _ = model;
    return if (kind == .openai) compat.ready(Chat.dialect) else null;
}

pub fn openaiProfile(model: []const u8) ModelProfile {
    const family = model_adapter.familyImageInput(model);
    return .{
        .thinking_mode = .openai_effort,
        .effort_levels = .full,
        .returns_reasoning_content = true,
        .echoes_reasoning_content = true,
        .supports_image_input = family orelse false,
        .image_input_source = if (family != null) .model_family else .unknown,
    };
}

fn profile(ctx: *anyopaque, kind: ProviderKind, model: []const u8) ModelProfile {
    _ = ctx;
    return if (kind == .openai) openaiProfile(model) else model_adapter.profileFor(kind, model);
}

const Chat = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        const e = effort orelse return;
        try out.appendSlice(a, ",\"reasoning\":{\"effort\":");
        try util_json.serializeString(e.name(), out, a);
        try out.append(a, '}');
    }

    fn extractThinkingDelta(ctx: *anyopaque, raw: []const u8, a: std.mem.Allocator) anyerror!?[]u8 {
        _ = ctx;
        if (try compat.extractStringDelta(raw, "reasoning", a)) |text| return text;
        return compat.extractStringDelta(raw, "reasoning_content", a);
    }

    const dialect = blk: {
        var d = compat.base;
        d.serializeThinkingFn = serializeThinking;
        d.extractThinkingDeltaFn = extractThinkingDelta;
        d.profileFn = profile;
        break :blk d;
    };
};

test "OpenRouter: reasoning.effort 原样发,未指定不发,不发顶层 reasoning_effort" {
    const a = std.testing.allocator;
    const d = dialect(.openai, "deepseek/deepseek-v4-pro").?;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, .xhigh, &out, a);
    try std.testing.expectEqualStrings(",\"reasoning\":{\"effort\":\"xhigh\"}", out.items);
    out.clearRetainingCapacity();
    try d.serializeThinking(.{}, .none, &out, a);
    try std.testing.expectEqualStrings(",\"reasoning\":{\"effort\":\"none\"}", out.items);
    out.clearRetainingCapacity();
    try d.serializeThinking(.{}, null, &out, a);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "OpenRouter: 解析 delta.reasoning,不把 reasoning_details 当文本" {
    const a = std.testing.allocator;
    const d = dialect(.openai, "x").?;
    const got = (try d.extractThinkingDelta("{\"choices\":[{\"delta\":{\"reasoning\":\"step\\n1\",\"reasoning_details\":[{\"type\":\"reasoning.text\",\"text\":\"step\\n1\"}]}}]}", a)).?;
    defer a.free(got);
    try std.testing.expectEqualStrings("step\n1", got);
    try std.testing.expect(try d.extractThinkingDelta("{\"choices\":[{\"delta\":{\"reasoning_details\":[]}}]}", a) == null);
    const legacy = (try d.extractThinkingDelta("{\"delta\":{\"reasoning_content\":\"r\"}}", a)).?;
    defer a.free(legacy);
    try std.testing.expectEqualStrings("r", legacy);
}

test "OpenRouter: 不参与按名推断,回传推理" {
    try std.testing.expect(!claims(.openai, "openrouter/auto"));
    try std.testing.expect(openaiProfile("anthropic/claude-sonnet-4").echoes_reasoning_content);
    try std.testing.expect(openaiProfile("anthropic/claude-sonnet-4").supports_image_input);
}
