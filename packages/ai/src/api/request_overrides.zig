//! 中立 RequestOverrides:方言字段的统一配置入口(agent loop + TUI)。
//!
//! 设计原则:**null = profile 默认**(向后兼容,保持"模型支持时自然启用")。
//! 非 null = 用户/调用方显式覆盖(可主动启用/关掉某方言字段)。
//!
//! 消费链:
//!   Config(CLI/config.json) → Client.overrides 字段 → Provider.requestOverrides()
//!   agent_loop sendStream 前 `const o = provider.requestOverrides()` 传给 serialize*
//!   → dialect.serializeThinking/ToolChoice/ResponseFormat/PromptCacheKey/ParallelToolCalls
//!
//! 来源:doc 计划 jolly-glacier(2026-08-11);KnowForge 调研发现 dialect 方法已定义
//! 但 serializeOpenAIRequest 不调用(prompt_cache_key / parallel_tool_calls / response_format
//! 是 dead code),用户无法配置这些方言字段。

const types = @import("../types.zig");

pub const ReasoningEffort = types.ReasoningEffort;
pub const ToolChoice = @import("request.zig").ToolChoice;
pub const ResponseFormatRequest = @import("dialect.zig").ResponseFormatRequest;

/// 方言字段的统一覆盖入口。所有字段 null = 用 profile 默认(dialect 静态推断)。
///
/// 消费方:agent_loop / serializeOpenAIRequest / serializeGeminiRequest。
/// 配置方:Config(CLI/config.json)+ Provider.setRequestOverrides() + AgentDef.overrides。
pub const RequestOverrides = struct {
    /// thinking 控制(原 CLI --reasoning-effort,纳入统一接口)。
    /// null = dialect 按 profile.thinking_mode + effort_levels 静态推断。
    reasoning_effort: ?ReasoningEffort = null,

    /// 工具选择(per-call 工具行为,不进 Config;但 agent_loop 内部 per-turn 可传)。
    /// null = 不发 tool_choice(模型默认行为)。
    tool_choice: ?ToolChoice = null,

    /// 结构化输出格式。null = 不发 response_format。
    /// dialect.serializeResponseFormat 会按 profile.response_format_support 能力守门
    /// (如 GLM-5 仅 json_object,传 json_schema 降级为 json_object)。
    response_format: ?ResponseFormatRequest = null,

    /// Kimi K2.6 显式缓存提示(supports_prompt_cache_key=true 的 dialect 才发)。
    /// null = 不发。gpt-4o 等不支持 dialect 会守门掉。
    prompt_cache_key: ?[]const u8 = null,

    /// Mistral 等显式 parallel_tool_calls 开关。null = 不发(模型默认)。
    /// 非 null 时 dialect.serializeParallelToolCalls 写入 wire(仅 supports=true 的 dialect)。
    parallel_tool_calls: ?bool = null,

    /// 通用采样参数(所有 OpenAI 协议都认,不经 dialect)。
    /// null = 不发(模型默认)。DeepSeek/Kimi K3 thinking 模式下应省略,但既然
    /// 用户可显式传,就不强制挡——交给用户判断。
    temperature: ?f32 = null,

    /// nucleus 采样,同 temperature。
    top_p: ?f32 = null,

    /// 全 null 检测(等价 "无覆盖",走 profile 默认)。
    pub fn isEmpty(self: RequestOverrides) bool {
        return self.reasoning_effort == null and
            self.tool_choice == null and
            self.response_format == null and
            self.prompt_cache_key == null and
            self.parallel_tool_calls == null and
            self.temperature == null and
            self.top_p == null;
    }

    /// 合并:other 非 null 字段覆盖 self(self 字段优先,other 兜底)。
    /// 用于 AgentDef.overrides 与父 Provider.overrides 合并(子覆盖父)。
    pub fn merge(self: RequestOverrides, other: RequestOverrides) RequestOverrides {
        return .{
            .reasoning_effort = self.reasoning_effort orelse other.reasoning_effort,
            .tool_choice = self.tool_choice orelse other.tool_choice,
            .response_format = self.response_format orelse other.response_format,
            .prompt_cache_key = self.prompt_cache_key orelse other.prompt_cache_key,
            .parallel_tool_calls = self.parallel_tool_calls orelse other.parallel_tool_calls,
            .temperature = self.temperature orelse other.temperature,
            .top_p = self.top_p orelse other.top_p,
        };
    }
};

// ── 单元测试 ──────────────────────────────────────────────────────────────

const std = @import("std");

test "RequestOverrides 默认全 null(等价无覆盖,走 profile 默认)" {
    const o: RequestOverrides = .{};
    try std.testing.expect(o.isEmpty());
    try std.testing.expect(o.reasoning_effort == null);
    try std.testing.expect(o.tool_choice == null);
    try std.testing.expect(o.response_format == null);
    try std.testing.expect(o.prompt_cache_key == null);
    try std.testing.expect(o.parallel_tool_calls == null);
    try std.testing.expect(o.temperature == null);
    try std.testing.expect(o.top_p == null);
}

test "RequestOverrides isEmpty 非空检测" {
    var o: RequestOverrides = .{};
    try std.testing.expect(o.isEmpty());
    o.temperature = 0.7;
    try std.testing.expect(!o.isEmpty());
    o = .{};
    o.reasoning_effort = .high;
    try std.testing.expect(!o.isEmpty());
}

test "RequestOverrides merge:子覆盖父,父兜底" {
    const parent: RequestOverrides = .{
        .temperature = 0.7,
        .reasoning_effort = .low,
    };
    const child: RequestOverrides = .{
        .reasoning_effort = .high, // 覆盖父
        // temperature 不设 → 兜底用父的 0.7
    };
    const merged = child.merge(parent);
    try std.testing.expectEqual(ReasoningEffort.high, merged.reasoning_effort.?);
    try std.testing.expectEqual(@as(f32, 0.7), merged.temperature.?);
    // 都未设的字段仍 null
    try std.testing.expect(merged.tool_choice == null);
    try std.testing.expect(merged.top_p == null);
}

test "RequestOverrides merge:都 null 仍 null" {
    const a: RequestOverrides = .{};
    const b: RequestOverrides = .{};
    const merged = a.merge(b);
    try std.testing.expect(merged.isEmpty());
}
