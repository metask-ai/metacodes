const std = @import("std");

/// Model identifiers are provider data, not source-code constants; ASCII
/// matching keeps routing case-insensitive without changing wire bytes.
pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    @setEvalBranchQuota(10_000);
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (lowerAscii(left) != lowerAscii(right)) return false;
    }
    return true;
}

fn lowerAscii(c: u8) u8 {
    // The model table calls this at comptime; the higher quota keeps that path
    // valid while the runtime helper remains allocation-free.
    return std.ascii.toLower(c);
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    @setEvalBranchQuota(10_000);
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    @setEvalBranchQuota(10_000);
    return value.len >= prefix.len and eqlIgnoreCase(value[0..prefix.len], prefix);
}

test "model name matching is ASCII case insensitive and bounded" {
    try std.testing.expect(eqlIgnoreCase("GLM-5.2", "glm-5.2"));
    try std.testing.expect(containsIgnoreCase("Claude-Haiku-4", "haiku-4"));
    try std.testing.expect(startsWithIgnoreCase("GPT-5", "gpt"));
    try std.testing.expect(!containsIgnoreCase("glm-4", "glm-5"));
    try std.testing.expect(!startsWithIgnoreCase("claude-3-5-haiku", "claude-haiku-4"));
}

test "case-insensitive model routing, capability, pricing, catalog, and context" {
    const claude = @import("dialects/claude.zig");
    const openai = @import("dialects/openai.zig");
    const adapter = @import("model_adapter.zig");
    const capability = @import("capability.zig");
    const pricing = @import("../util/pricing.zig");
    const Catalog = @import("catalog.zig").Catalog;
    const ModelContext = @import("../app/model_context.zig").ModelContext;
    const prompt = @import("../core/system_prompt.zig");

    const a = std.testing.allocator;
    var upper_buf: std.ArrayList(u8) = .empty;
    defer upper_buf.deinit(a);
    var lower_buf: std.ArrayList(u8) = .empty;
    defer lower_buf.deinit(a);
    try claude.claudeDialectFor("GLM-5.2").serializeThinking(.{}, .high, &upper_buf, a);
    try claude.claudeDialectFor("glm-5.2").serializeThinking(.{}, .high, &lower_buf, a);
    try std.testing.expectEqualStrings(lower_buf.items, upper_buf.items);
    upper_buf.clearRetainingCapacity();
    try openai.openaiDialectFor("GLM-5.2").serializeThinking(.{}, .high, &upper_buf, a);
    lower_buf.clearRetainingCapacity();
    try openai.openaiDialectFor("glm-5.2").serializeThinking(.{}, .high, &lower_buf, a);
    try std.testing.expectEqualStrings(lower_buf.items, upper_buf.items);
    try std.testing.expectEqual(adapter.profileFor(.openai, "GLM-5.2"), adapter.profileFor(.openai, "glm-5.2"));
    try std.testing.expectEqual(capability.supports(.anthropic, "GLM-5.2", .structured_output), capability.supports(.anthropic, "glm-5.2", .structured_output));
    try std.testing.expectEqual(pricing.rateFor("GLM-5.2"), pricing.rateFor("glm-5.2"));
    try std.testing.expect(!containsIgnoreCase("glm-4", "glm-5"));
    try std.testing.expect(!containsIgnoreCase("claude-3-5-haiku", "claude-haiku-4"));

    var catalog = Catalog.init(a);
    defer catalog.deinit();
    try catalog.loadFromModelsListJson("{\"data\":[{\"id\":\"GLM-5.2\",\"max_tokens\":64000,\"max_input_tokens\":1048576}]} ");
    try std.testing.expectEqual(@as(u32, 64000), catalog.maxTokensFor("glm-5.2", null));
    var context = ModelContext.init(a);
    defer context.deinit();
    context.parse("[models]\n\"glm-5.2\" = 262144\n");
    try std.testing.expectEqual(@as(u32, 262144), context.windowFor("GLM-5.2"));
    try std.testing.expect(prompt.getKnowledgeCutoff("claude-3-5-haiku") == null);
}

test "model routing source guard rejects direct case-sensitive model matching" {
    const sources = [_][]const u8{
        @embedFile("model_adapter.zig"),         @embedFile("capability.zig"),            @embedFile("dialect.zig"),
        @embedFile("dialects/openai.zig"),       @embedFile("dialects/claude.zig"),       @embedFile("catalog.zig"),
        @embedFile("../app/model_context.zig"),  @embedFile("../util/pricing.zig"),       @embedFile("../util/model.zig"),
        @embedFile("../core/system_prompt.zig"), @embedFile("../repl/model_command.zig"), @embedFile("../main.zig"),
        @embedFile("../plugin/runtime.zig"),
    };
    const forbidden = [_][]const u8{
        "std.mem.indexOf(u8, model", "std.mem.eql(u8, model", "std.mem.startsWith(u8, model", "std.mem.eql(u8, e.model_id",
    };
    for (sources) |source| for (forbidden) |needle| try std.testing.expect(std.mem.indexOf(u8, source, needle) == null);
}
