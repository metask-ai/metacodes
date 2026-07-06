const std = @import("std");

/// Classify provider error payloads without depending on one vendor's exact
/// JSON shape. Keep this conservative: recovery mutates conversation history,
/// so ambiguous "request too large" errors must not be treated as context
/// overflow unless token/context/window wording is also present.
pub fn isContextWindowExceeded(body: []const u8) bool {
    if (containsIgnoreCase(body, "context_window_exceeded")) return true;
    // Anthropic 经典措辞(metask/glm-5.2 实测 2026-07-06:
    // `prompt is too long: 274505 tokens > 245760 maximum`;Vertex 首字母大写)。
    // cc 的 reactive compact 也按此串匹配(cc/src/services/api/errors.ts)。
    if (containsIgnoreCase(body, "prompt is too long")) return true;
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
    // metask/glm-5.2 真实报错(2026-07-06 实测抓包)。
    try std.testing.expect(isContextWindowExceeded("{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"prompt is too long: 274505 tokens \\u003e 245760 maximum\"}}"));
    // Vertex 大小写变体。
    try std.testing.expect(isContextWindowExceeded("Prompt is too long"));
    // metask/glm-5.2 第二种措辞(2026-07-06 fix4.log 实测:in+max_tokens 超总窗时)——
    // 靠 "maximum context" 模式命中;钉原文防措辞模式被误删。
    try std.testing.expect(isContextWindowExceeded("{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Requested token count exceeds the model's maximum context length of 262144 tokens. You requested a total of 262758 tokens: 198758 tokens from the input messages and 64000 tokens for the completion.\"}}"));
    try std.testing.expect(isContextWindowExceeded("{\"error\":{\"message\":\"This model's maximum context length is 200000 tokens.\"}}"));
    try std.testing.expect(isContextWindowExceeded("{\"message\":\"too many input tokens: 210000 > limit\"}"));
    try std.testing.expect(isContextWindowExceeded("Input token limit exceeded for this request"));
}

test "context window exceeded classifier avoids unrelated request-too-large errors" {
    try std.testing.expect(!isContextWindowExceeded("{\"error\":{\"type\":\"request_too_large\",\"message\":\"body too large\"}}"));
    try std.testing.expect(!isContextWindowExceeded("{\"error\":{\"type\":\"overloaded_error\",\"message\":\"server overloaded\"}}"));
    try std.testing.expect(!isContextWindowExceeded("{\"error\":{\"message\":\"invalid model\"}}"));
}
