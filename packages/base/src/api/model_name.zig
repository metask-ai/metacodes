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

pub const case_sensitive_model_matches = [_][]const u8{
    "std.mem.indexOf(u8, model", "std.mem.eql(u8, model", "std.mem.startsWith(u8, model", "std.mem.eql(u8, e.model_id",
};
