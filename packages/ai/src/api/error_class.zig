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

/// Numbers an overflow message may carry. Every field is optional: this is a
/// best-effort reading across dialects, and the agent loop keeps a
/// provider-neutral fallback (the last accepted prompt size) for messages that
/// carry nothing. Providers describe the same event in two shapes:
///   - a bound on the *prompt* ("prompt is too long: N tokens > M maximum",
///     Gemini's "input token count (N) exceeds ... allowed (M)");
///   - a bound on prompt + completion ("maximum context length is M tokens ...
///     requested N tokens (I in the messages, C in the completion)").
/// `inputCap` folds both into one number the pressure model can use.
pub const ContextWindowNumbers = struct {
    /// Upper bound on prompt (input) tokens the server accepts.
    input_limit: ?u64 = null,
    /// Upper bound on prompt + completion tokens.
    total_limit: ?u64 = null,
    /// The rejected request's prompt (input) tokens, when reported.
    input_actual: ?u64 = null,
    /// The rejected request's prompt + completion tokens, when reported.
    total_actual: ?u64 = null,
    /// The completion reservation the server counted against a total limit.
    completion: ?u64 = null,

    pub fn isEmpty(self: ContextWindowNumbers) bool {
        return self.input_limit == null and self.total_limit == null and
            self.input_actual == null and self.total_actual == null and self.completion == null;
    }

    /// The largest prompt the server will take. A total-form message needs the
    /// completion reservation; when the message did not state one, the caller
    /// passes what it sent as `max_tokens`.
    pub fn inputCap(self: ContextWindowNumbers, assumed_completion: u64) ?u64 {
        if (self.input_limit) |limit| return limit;
        const total = self.total_limit orelse return null;
        const completion = self.completion orelse assumed_completion;
        return total -| completion;
    }

    /// The rejected prompt size, when the message lets us derive it.
    pub fn inputActual(self: ContextWindowNumbers, assumed_completion: u64) ?u64 {
        if (self.input_actual) |actual| return actual;
        const total = self.total_actual orelse return null;
        const completion = self.completion orelse assumed_completion;
        return total -| completion;
    }
};

/// Read the numbers out of an overflow message. Only call this for bodies that
/// `isContextWindowExceeded` already accepted; on any other text the result is
/// simply empty. Dialects covered by tests: Anthropic/Vertex, OpenAI-compatible
/// (incl. the Metask/GLM gateway wording), Gemini. Unknown wording yields an
/// empty struct, never a guess.
pub fn parseContextWindowNumbers(body: []const u8) ContextWindowNumbers {
    var out: ContextWindowNumbers = .{};

    // Anthropic: "prompt is too long: 274505 tokens > 245760 maximum".
    if (indexOfIgnoreCase(body, 0, "prompt is too long")) |at| {
        const actual = numberAfter(body, at + "prompt is too long".len);
        if (actual) |a| {
            out.input_actual = a.value;
            // The `>` arrives literal from most gateways and JSON-escaped as
            // `\u003e` from others (the body is read raw, not unescaped).
            if (indexOfGreaterThan(body, a.end)) |after_gt| {
                if (numberAfter(body, after_gt)) |limit| out.input_limit = limit.value;
            }
        }
    }

    // Gemini: "The input token count (1100000) exceeds the maximum number of tokens allowed (1048576)".
    if (indexOfIgnoreCase(body, 0, "input token count")) |at| {
        if (numberAfter(body, at + "input token count".len)) |actual| out.input_actual = actual.value;
        if (indexOfIgnoreCase(body, at, "tokens allowed")) |allowed| {
            if (numberAfter(body, allowed + "tokens allowed".len)) |limit| out.input_limit = limit.value;
        }
    }

    // OpenAI-compatible total form:
    //   "maximum context length is 128000 tokens. However, you requested 130000 tokens
    //    (120000 in the messages, 10000 in the completion)"
    //   "maximum context length of 262144 tokens. You requested a total of 262758 tokens:
    //    198758 tokens from the input messages and 64000 tokens for the completion."
    if (indexOfIgnoreCase(body, 0, "maximum context length")) |at| {
        if (numberAfter(body, at + "maximum context length".len)) |limit| out.total_limit = limit.value;
        if (indexOfIgnoreCase(body, at, "requested")) |req| {
            if (numberAfter(body, req + "requested".len)) |actual| out.total_actual = actual.value;
        }
    } else if (indexOfIgnoreCase(body, 0, "context length")) |at| {
        // "longer than the model's context length (1048576 tokens)"
        if (numberAfter(body, at + "context length".len)) |limit| out.total_limit = limit.value;
    }
    for ([_][]const u8{ "from the input messages", "in the messages" }) |phrase| {
        if (indexOfIgnoreCase(body, 0, phrase)) |at| {
            if (numberBefore(body, at)) |v| out.input_actual = out.input_actual orelse v;
        }
    }
    for ([_][]const u8{ "for the completion", "in the completion", "for completion" }) |phrase| {
        if (indexOfIgnoreCase(body, 0, phrase)) |at| {
            if (numberBefore(body, at)) |v| out.completion = out.completion orelse v;
        }
    }
    return out;
}

/// Position just past the first `>` (literal or JSON-escaped `\u003e`) at or
/// after `from`.
fn indexOfGreaterThan(body: []const u8, from: usize) ?usize {
    const literal = std.mem.indexOfScalarPos(u8, body, from, '>');
    const escaped = indexOfIgnoreCase(body, from, "\\u003e");
    if (literal == null and escaped == null) return null;
    const lit = literal orelse std.math.maxInt(usize);
    const esc = escaped orelse std.math.maxInt(usize);
    return if (lit < esc) lit + 1 else esc + "\\u003e".len;
}

const Number = struct { value: u64, end: usize };

/// Skip at most a few non-digit bytes (" of ", " is ", " (", " a total of ")
/// and read one digit run. Thousands separators (`,` / `_`) inside the run are
/// tolerated; anything further away is another sentence.
fn numberAfter(body: []const u8, from: usize) ?Number {
    const MAX_SKIP = 24;
    var i = from;
    var skipped: usize = 0;
    while (i < body.len and !std.ascii.isDigit(body[i])) : (i += 1) {
        skipped += 1;
        if (skipped > MAX_SKIP) return null;
    }
    return readDigits(body, i);
}

/// Walk back over at most a few non-digit bytes ("tokens ", " (") to the digit
/// run that precedes `before`.
fn numberBefore(body: []const u8, before: usize) ?u64 {
    const MAX_SKIP = 16;
    var i = before;
    var skipped: usize = 0;
    while (i > 0 and !std.ascii.isDigit(body[i - 1])) : (i -= 1) {
        skipped += 1;
        if (skipped > MAX_SKIP) return null;
    }
    var start = i;
    while (start > 0 and (std.ascii.isDigit(body[start - 1]) or body[start - 1] == ',' or body[start - 1] == '_')) : (start -= 1) {}
    while (start < i and !std.ascii.isDigit(body[start])) : (start += 1) {}
    const n = readDigits(body, start) orelse return null;
    return n.value;
}

fn readDigits(body: []const u8, start: usize) ?Number {
    var i = start;
    var value: u64 = 0;
    var digits: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (std.ascii.isDigit(c)) {
            if (digits >= 15) return null; // no token count has 16 digits; refuse to overflow
            value = value * 10 + (c - '0');
            digits += 1;
        } else if ((c == ',' or c == '_') and digits > 0 and i + 1 < body.len and std.ascii.isDigit(body[i + 1])) {
            continue;
        } else break;
    }
    if (digits == 0) return null;
    return .{ .value = value, .end = i };
}

fn indexOfIgnoreCase(haystack: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or from > haystack.len or haystack.len - from < needle.len) return null;
    var i: usize = from;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
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

test "overflow numbers: Anthropic prompt-is-too-long carries prompt actual and limit" {
    const n = parseContextWindowNumbers("{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"prompt is too long: 274505 tokens \\u003e 245760 maximum\"}}");
    // The `>` arrives JSON-escaped as > on some gateways and literal on others.
    try std.testing.expectEqual(@as(?u64, 274505), n.input_actual);
    try std.testing.expectEqual(@as(?u64, 245760), n.input_limit);
    const literal = parseContextWindowNumbers("prompt is too long: 274505 tokens > 245760 maximum");
    try std.testing.expectEqual(@as(?u64, 274505), literal.input_actual);
    try std.testing.expectEqual(@as(?u64, 245760), literal.input_limit);
    try std.testing.expectEqual(@as(?u64, 245760), literal.inputCap(64_000));
    try std.testing.expectEqual(@as(?u64, 274505), literal.inputActual(64_000));
}

test "overflow numbers: unescaped JSON gt still parses through the escape" {
    // A body that keeps `>` must not lose the limit: unescape happens upstream
    // when available, but the parser also accepts the raw escape sequence.
    const raw = "prompt is too long: 100 tokens \\u003e 90 maximum";
    const n = parseContextWindowNumbers(raw);
    try std.testing.expectEqual(@as(?u64, 100), n.input_actual);
    try std.testing.expectEqual(@as(?u64, 90), n.input_limit);
}

test "overflow numbers: Metask/GLM total form subtracts the completion reservation" {
    const n = parseContextWindowNumbers("{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Requested token count exceeds the model's maximum context length of 262144 tokens. You requested a total of 262758 tokens: 198758 tokens from the input messages and 64000 tokens for the completion.\"}}");
    try std.testing.expectEqual(@as(?u64, 262144), n.total_limit);
    try std.testing.expectEqual(@as(?u64, 262758), n.total_actual);
    try std.testing.expectEqual(@as(?u64, 198758), n.input_actual);
    try std.testing.expectEqual(@as(?u64, 64000), n.completion);
    try std.testing.expectEqual(@as(?u64, 262144 - 64000), n.inputCap(1));
    try std.testing.expectEqual(@as(?u64, 198758), n.inputActual(1));
}

test "overflow numbers: OpenAI wording with parenthesised breakdown" {
    const n = parseContextWindowNumbers("{\"error\":{\"message\":\"This model's maximum context length is 128000 tokens. However, you requested 130000 tokens (120000 in the messages, 10000 in the completion). Please reduce the length of the messages or completion.\",\"code\":\"context_length_exceeded\"}}");
    try std.testing.expectEqual(@as(?u64, 128000), n.total_limit);
    try std.testing.expectEqual(@as(?u64, 130000), n.total_actual);
    try std.testing.expectEqual(@as(?u64, 120000), n.input_actual);
    try std.testing.expectEqual(@as(?u64, 10000), n.completion);
    try std.testing.expectEqual(@as(?u64, 118000), n.inputCap(0));
}

test "overflow numbers: total limit without a breakdown uses the caller's max_tokens" {
    const n = parseContextWindowNumbers("{\"error\":{\"message\":\"This model's maximum context length is 200000 tokens.\"}}");
    try std.testing.expectEqual(@as(?u64, 200000), n.total_limit);
    try std.testing.expectEqual(@as(?u64, null), n.completion);
    try std.testing.expectEqual(@as(?u64, 200000 - 32000), n.inputCap(32000));
    try std.testing.expectEqual(@as(?u64, null), n.inputActual(32000));
    // 2026-09-05 Metask wording: "longer than the model's context length (1048576 tokens)".
    const paren = parseContextWindowNumbers("input is longer than the model's context length (1048576 tokens)");
    try std.testing.expectEqual(@as(?u64, 1048576), paren.total_limit);
}

test "overflow numbers: Gemini input token count wording" {
    const n = parseContextWindowNumbers("{\"error\":{\"message\":\"The input token count (1100000) exceeds the maximum number of tokens allowed (1048576).\"}}");
    try std.testing.expectEqual(@as(?u64, 1100000), n.input_actual);
    try std.testing.expectEqual(@as(?u64, 1048576), n.input_limit);
}

test "overflow numbers: thousands separators and unknown wording" {
    const sep = parseContextWindowNumbers("prompt is too long: 1,101,379 tokens > 1,048,576 maximum");
    try std.testing.expectEqual(@as(?u64, 1101379), sep.input_actual);
    try std.testing.expectEqual(@as(?u64, 1048576), sep.input_limit);
    const none = parseContextWindowNumbers("{\"error\":{\"type\":\"context_window_exceeded\",\"message\":\"too large\"}}");
    try std.testing.expect(none.isEmpty());
    try std.testing.expectEqual(@as(?u64, null), none.inputCap(1));
    // A digit run far from the keyword is another sentence, not a limit.
    const far = parseContextWindowNumbers("maximum context length reached for this deployment; contact support, ticket 12345678");
    try std.testing.expectEqual(@as(?u64, null), far.total_limit);
}
