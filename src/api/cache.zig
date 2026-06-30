//! Cache:多 Provider 缓存策略的扩展点契约(中立层,leaf,谁都可依赖)。
//!
//! 设计(见架构报告"多 Provider 缓存"节 + metaknow root「多 Provider 分离架构设计」):
//! 三家 prompt caching 机制差异巨大,但都收进 provider 的两个 hook:
//!   - **写侧 prepareCache**:请求序列化前,provider 据自己的范式改写缓存意图。三家在此分叉:
//!       · Anthropic:显式断点(请求体注入 cache_control;已实现于 request.zig 的 MessagesRequest 默认值)
//!       · OpenAI:全自动前缀匹配,**no-op**(客户端无可标记的;只能调 prompt 结构稳定前缀)
//!       · Gemini:隐式自动 no-op,或显式有状态(创建 CachedContent 对象、持句柄、TTL、404 重建)
//!   - **读侧 parseCacheUsage**:流结束读 usage 时,provider 解析自己字段名的命中数,归一成中立 UsageDelta。
//!       三家字段名不同:
//!       · Anthropic:`cache_read_input_tokens` / `cache_creation_input_tokens`
//!       · OpenAI:`usage.prompt_tokens_details.cached_tokens`(只有读,无写区分)
//!       · Gemini:`usageMetadata.cachedContentTokenCount`
//!
//! **内核无感**:agent_loop 只消费中立 UsageDelta(经 CoreEvent.usage 上抛 UI),
//! 完全不知道缓存命中来自哪家、用哪种机制。这是承袭 Provider 架构的一贯纪律。
//!
//! **诚实纪律(承袭 P3)**:本契约只为已验证 provider 落实现。Anthropic 写侧 = request.zig 现有
//! cache_control(实证);OpenAI/Gemini 写侧 = no-op(自动缓存);读侧三家都据各自真实字段名解析。
//! Gemini 的"有状态显式缓存"是 GeminiClient 私有的句柄表逻辑,在其 prepareCache 内部实现,
//! 不上浮本契约——本契约只定义"何时调、传什么、归一成什么",不规定 provider 内部怎么管句柄。

const std = @import("std");
const util_json = @import("../util/json.zig");

/// 中立缓存用量(归一三家不同字段名后的统一表示)。
/// 注:与 stream.zig 的 UsageDelta 字段对齐——parseCacheUsage 把各家 raw usage 解析进 UsageDelta
/// 的 cache_read_input_tokens / cache_creation_input_tokens 两字段。本类型是"只看缓存两数"的视图,
/// 供想单独拿缓存命中的调用方用;主路径直接用 UsageDelta 即可。
pub const CacheUsage = struct {
    /// 命中缓存、按折扣计费的输入 token 数(三家都有这个概念)。
    read_tokens: u64 = 0,
    /// 写入缓存、按溢价计费的输入 token 数(Anthropic 有;OpenAI/Gemini 无显式写区分 → 0)。
    creation_tokens: u64 = 0,
};

/// Provider 缓存范式(用于诊断/日志,说明该 provider 用哪种缓存控制方式)。
/// 不驱动逻辑分支(逻辑分支在各 provider 的 hook 实现里),仅供可观测性。
pub const CacheMode = enum {
    /// 显式断点:客户端在请求里标记缓存边界(Anthropic cache_control)。
    explicit_breakpoint,
    /// 全自动前缀:客户端无标记,服务端前缀哈希匹配(OpenAI / Gemini 隐式)。
    automatic_prefix,
    /// 有状态对象:客户端创建/引用远程 cache 对象,管理 TTL + 404 重建(Gemini 显式)。
    stateful_object,
    /// 不支持/未启用缓存。
    none,

    pub fn label(self: CacheMode) []const u8 {
        return switch (self) {
            .explicit_breakpoint => "explicit_breakpoint",
            .automatic_prefix => "automatic_prefix",
            .stateful_object => "stateful_object",
            .none => "none",
        };
    }
};

/// provider 的缓存范式(真消费者:各 client 的 doStream 日志带上它,便于一眼看出该 provider 用哪种
/// 缓存机制做了什么)。不驱动控制流——缓存逻辑在各 client 的序列化/句柄表里;此处仅为可观测性归类。
pub fn modeFor(kind: @import("capability.zig").ProviderKind) CacheMode {
    return switch (kind) {
        .anthropic => .explicit_breakpoint, // cache_control 断点
        .openai => .automatic_prefix, // 自动前缀,无标记
        .gemini => .stateful_object, // 句柄表 + cachedContent 引用(本 client 实现)
        .other => .none,
    };
}

// ── 读侧:三家 usage 缓存字段 → 中立 CacheUsage ──────────────────────────────
// 各 provider 的 parseCacheUsage 实现直接调下面对应的解析器。集中在此,便于一处审计三家字段名。

/// Anthropic:`cache_read_input_tokens` / `cache_creation_input_tokens`(usage object 顶层)。
pub fn parseAnthropicCacheUsage(usage_obj: []const u8) CacheUsage {
    return .{
        .read_tokens = util_json.extractIntField(usage_obj, "cache_read_input_tokens"),
        .creation_tokens = util_json.extractIntField(usage_obj, "cache_creation_input_tokens"),
    };
}

/// OpenAI:`usage.prompt_tokens_details.cached_tokens`。只有读命中,无写区分 → creation=0。
/// 注:cached_tokens 嵌在 prompt_tokens_details 子对象内,但裸 substring 提取对嵌套字段同样有效
/// (字段名唯一,extractIntField 找 `"cached_tokens":<digits>`)。
pub fn parseOpenAICacheUsage(usage_obj: []const u8) CacheUsage {
    return .{
        .read_tokens = util_json.extractIntField(usage_obj, "cached_tokens"),
        .creation_tokens = 0,
    };
}

/// Gemini:`usageMetadata.cachedContentTokenCount`。隐式/显式都用这个字段报命中。
/// 同样无写区分 → creation=0(显式缓存的"创建"是单独的 createCachedContent 请求,不在生成 usage 里)。
pub fn parseGeminiCacheUsage(usage_obj: []const u8) CacheUsage {
    return .{
        .read_tokens = util_json.extractIntField(usage_obj, "cachedContentTokenCount"),
        .creation_tokens = 0,
    };
}

// ── 测试:三家字段名各自解析正确(单一真相源,防字段名漂移)──────────────────
test "Anthropic 缓存 usage 解析" {
    const obj = "{\"input_tokens\":100,\"cache_read_input_tokens\":2048,\"cache_creation_input_tokens\":512}";
    const cu = parseAnthropicCacheUsage(obj);
    try std.testing.expectEqual(@as(u64, 2048), cu.read_tokens);
    try std.testing.expectEqual(@as(u64, 512), cu.creation_tokens);
}

test "OpenAI 缓存 usage 解析(嵌套 prompt_tokens_details)" {
    const obj = "{\"prompt_tokens\":2006,\"completion_tokens\":300,\"prompt_tokens_details\":{\"cached_tokens\":1920}}";
    const cu = parseOpenAICacheUsage(obj);
    try std.testing.expectEqual(@as(u64, 1920), cu.read_tokens);
    try std.testing.expectEqual(@as(u64, 0), cu.creation_tokens); // OpenAI 无写区分
}

test "Gemini 缓存 usage 解析" {
    const obj = "{\"promptTokenCount\":4096,\"cachedContentTokenCount\":3000,\"candidatesTokenCount\":50}";
    const cu = parseGeminiCacheUsage(obj);
    try std.testing.expectEqual(@as(u64, 3000), cu.read_tokens);
    try std.testing.expectEqual(@as(u64, 0), cu.creation_tokens);
}

test "缺字段容错全 0" {
    const cu = parseAnthropicCacheUsage("{\"input_tokens\":50}");
    try std.testing.expectEqual(@as(u64, 0), cu.read_tokens);
    try std.testing.expectEqual(@as(u64, 0), cu.creation_tokens);
}

test "modeFor:三家缓存范式归类(真消费者断言)" {
    try std.testing.expectEqual(CacheMode.explicit_breakpoint, modeFor(.anthropic));
    try std.testing.expectEqual(CacheMode.automatic_prefix, modeFor(.openai));
    try std.testing.expectEqual(CacheMode.stateful_object, modeFor(.gemini));
    try std.testing.expectEqual(CacheMode.none, modeFor(.other));
    try std.testing.expectEqualStrings("stateful_object", modeFor(.gemini).label());
}
