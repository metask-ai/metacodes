const std = @import("std");

/// Classify provider error payloads without depending on one vendor's exact
/// JSON shape. Keep this conservative: recovery mutates conversation history,
/// so ambiguous "request too large" errors must not be treated as context
/// overflow unless token/context/window wording is also present.
pub fn isContextWindowExceeded(body: []const u8) bool {
    if (containsIgnoreCase(body, "context_window_exceeded")) return true;
    if (containsIgnoreCase(body, "context window")) return true;
    if (containsIgnoreCase(body, "context length")) return true;
    if (containsIgnoreCase(body, "maximum context")) return true;
    if (containsIgnoreCase(body, "context limit")) return true;
    if (containsIgnoreCase(body, "too many input tokens")) return true;
    if (containsIgnoreCase(body, "input tokens") and containsIgnoreCase(body, "limit")) return true;
    if (containsIgnoreCase(body, "token limit") and containsIgnoreCase(body, "input")) return true;
    if (containsIgnoreCase(body, "max_tokens") and containsIgnoreCase(body, "context")) return true;
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "context window exceeded classifier matches common provider payloads" {
    try std.testing.expect(isContextWindowExceeded("{\"error\":{\"type\":\"context_window_exceeded\",\"message\":\"too large\"}}"));
    try std.testing.expect(isContextWindowExceeded("{\"error\":{\"message\":\"This model's maximum context length is 200000 tokens.\"}}"));
    try std.testing.expect(isContextWindowExceeded("{\"message\":\"too many input tokens: 210000 > limit\"}"));
    try std.testing.expect(isContextWindowExceeded("Input token limit exceeded for this request"));
}

test "context window exceeded classifier avoids unrelated request-too-large errors" {
    try std.testing.expect(!isContextWindowExceeded("{\"error\":{\"type\":\"request_too_large\",\"message\":\"body too large\"}}"));
    try std.testing.expect(!isContextWindowExceeded("{\"error\":{\"type\":\"overloaded_error\",\"message\":\"server overloaded\"}}"));
    try std.testing.expect(!isContextWindowExceeded("{\"error\":{\"message\":\"invalid model\"}}"));
}
