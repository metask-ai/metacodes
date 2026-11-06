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

// The behavioural half of this guard, that every consumer answers the same
// for either case, is `model_name_consumers_test.zig`. It cannot live here: the
// provider kernel reaches this file through `util/pricing.zig`, so every test
// in it compiles into `test:provider` and `test:picker`, and that test imports
// the system prompt and, through it, the whole tool set.
test "model routing source guard rejects direct case-sensitive model matching" {
    const sources = [_][]const u8{
        @embedFile("model_adapter.zig"),         @embedFile("capability.zig"),            @embedFile("dialect.zig"),
        @embedFile("dialects/openai.zig"),       @embedFile("dialects/claude.zig"),       @embedFile("catalog.zig"),
        @embedFile("dialects/glm.zig"),          @embedFile("dialects/kimi.zig"),         @embedFile("dialects/deepseek.zig"),
        @embedFile("dialects/qwen.zig"),         @embedFile("dialects/minimax.zig"),      @embedFile("dialects/mistral.zig"),
        @embedFile("dialects/gemini.zig"),       @embedFile("dialects/registry.zig"),     @embedFile("dialects/openai_compat.zig"),
        @embedFile("../app/model_context.zig"),  @embedFile("../util/pricing.zig"),       @embedFile("../util/model.zig"),
        @embedFile("../core/system_prompt.zig"), @embedFile("../repl/model_command.zig"), @embedFile("../main.zig"),
        @embedFile("../plugin/runtime.zig"),
    };
    const forbidden = [_][]const u8{
        "std.mem.indexOf(u8, model", "std.mem.eql(u8, model", "std.mem.startsWith(u8, model", "std.mem.eql(u8, e.model_id",
    };
    for (sources) |source| for (forbidden) |needle| try std.testing.expect(std.mem.indexOf(u8, source, needle) == null);
}
