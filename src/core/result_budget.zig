//! The one byte budget for model-visible tool results.
//!
//! How many result bytes a turn may spend is bounded by the context window,
//! and only the provider knows the window. Every layer that decides how much
//! of a result reaches the model derives its numbers here, so widening the
//! window moves them together instead of leaving one layer pinned to a
//! constant that was back-computed from the floor.
//!
//! Budgets are counted in **encoded** bytes — what the serialized result
//! actually costs — because a preview chosen by source length can double
//! through JSON escaping and silently leave the budget it was sized against.
//!
//! Deliberately a leaf: `ToolContext` carries a `Budget` by value, so this
//! file must not reach into Conversation, the projection layer, or a Provider.

const std = @import("std");

/// Floor. A window this budget cannot see (an embedder with no Provider, a
/// unit test) still gets a usable result rather than a token preview.
pub const PER_RESULT_MIN_BYTES: usize = 8 * 1024;
/// Ceiling. Past this a single result crowds the turn no matter how large the
/// window is, and the marginal value of more inline bytes is low.
pub const PER_RESULT_MAX_BYTES: usize = 64 * 1024;
/// window(tokens)/8 → per-result inline bytes (≈ window/32 tokens at 4
/// bytes/token). 200K → 25KB, 262K → 32KB, 1M → the 64KB cap.
pub const PER_RESULT_WINDOW_DIVISOR: usize = 8;

pub const PER_TURN_MIN_BYTES: usize = 16 * 1024;
pub const PER_TURN_MAX_BYTES: usize = 200 * 1024;

pub fn perResultBytes(max_input_tokens: usize) usize {
    const derived = if (max_input_tokens == 0)
        PER_RESULT_MIN_BYTES
    else
        max_input_tokens / PER_RESULT_WINDOW_DIVISOR;
    return @min(@max(derived, PER_RESULT_MIN_BYTES), PER_RESULT_MAX_BYTES);
}

pub fn perTurnBytes(max_input_tokens: usize) usize {
    // Approximate four UTF-8 bytes/token, then allocate 30% of one request to
    // all tool results.
    const derived = std.math.mul(usize, max_input_tokens, 6) catch std.math.maxInt(usize);
    return @min(@max(derived / 5, PER_TURN_MIN_BYTES), PER_TURN_MAX_BYTES);
}

pub const Budget = struct {
    per_result_bytes: usize = PER_RESULT_MIN_BYTES,
    per_turn_bytes: usize = PER_TURN_MIN_BYTES,

    /// What a caller with no window information gets. Equal to `fromModel(0)`,
    /// and the default of every `Budget` field, so an unwired construction
    /// degrades to the historical floor instead of to zero.
    pub const floor: Budget = .{
        .per_result_bytes = PER_RESULT_MIN_BYTES,
        .per_turn_bytes = PER_TURN_MIN_BYTES,
    };

    pub fn fromModel(max_input_tokens: usize) Budget {
        return .{
            .per_result_bytes = perResultBytes(max_input_tokens),
            .per_turn_bytes = perTurnBytes(max_input_tokens),
        };
    }

    /// Encoded bytes one result's model-visible payload may occupy once
    /// `fixed_overhead` bytes of envelope scaffolding are paid for. Saturating:
    /// an overhead larger than the whole budget yields zero, never a wrap.
    pub fn payloadAllowance(self: Budget, fixed_overhead: usize) usize {
        return self.per_result_bytes -| fixed_overhead;
    }
};

pub const Pair = struct { first: usize, second: usize };

/// Max-min fair split of one payload allowance between two channels.
///
/// A fixed half-each split is wrong for the common shape: a command that
/// writes 20KB to stdout and nothing to stderr would forfeit half its
/// allowance to an empty channel. Whichever channel fits inside its half takes
/// exactly what it needs and the remainder goes to the other; only when both
/// exceed their half is the allowance actually halved.
pub fn splitPair(allowance: usize, first_bytes: u64, second_bytes: u64) Pair {
    const first = saturatingUsize(first_bytes);
    const second = saturatingUsize(second_bytes);
    if (first +| second <= allowance) return .{ .first = first, .second = second };
    const half = allowance / 2;
    if (first <= half) return .{ .first = first, .second = allowance - first };
    if (second <= half) return .{ .first = allowance - second, .second = second };
    return .{ .first = half, .second = allowance - half };
}

fn saturatingUsize(value: u64) usize {
    return std.math.cast(usize, value) orelse std.math.maxInt(usize);
}

/// Encoded size of one byte inside a JSON string, matching
/// `std.json.Stringify.encodeJsonString` with default options
/// (`escape_unicode = false`, so bytes >= 0x80 pass through at their own size).
pub fn encodedByteLen(byte: u8) usize {
    return switch (byte) {
        '"', '\\', 0x08, 0x0C, '\n', '\r', '\t' => 2,
        0x00...0x07, 0x0B, 0x0E...0x1F => 6,
        else => 1,
    };
}

pub fn encodedLen(bytes: []const u8) usize {
    var total: usize = 0;
    for (bytes) |byte| total +|= encodedByteLen(byte);
    return total;
}

/// Longest prefix of `bytes` whose encoded form fits in `max_encoded`, cut on
/// a UTF-8 boundary so the preview never ends mid-codepoint.
pub fn encodedPrefixLen(bytes: []const u8, max_encoded: usize) usize {
    var used: usize = 0;
    var end: usize = 0;
    while (end < bytes.len) : (end += 1) {
        const cost = encodedByteLen(bytes[end]);
        if (used + cost > max_encoded) break;
        used += cost;
    }
    return floorUtf8Boundary(bytes, end);
}

/// Longest suffix of `bytes` whose encoded form fits in `max_encoded`, cut on
/// a UTF-8 boundary.
pub fn encodedSuffixLen(bytes: []const u8, max_encoded: usize) usize {
    var used: usize = 0;
    var start: usize = bytes.len;
    while (start > 0) {
        const cost = encodedByteLen(bytes[start - 1]);
        if (used + cost > max_encoded) break;
        used += cost;
        start -= 1;
    }
    return bytes.len - ceilUtf8Boundary(bytes, start);
}

/// Encoded cost of `source` in the encoding the envelope will render it with.
/// JSON escaping is per byte; base64 expands 4:3 and never escapes.
///
/// One definition, because every layer that cuts a preview has to agree with
/// the layer that renders it: two independent copies of "how much will this
/// cost" is how a preview ends up sized against one encoding and emitted in
/// another.
pub fn encodedCost(source: []const u8, base64: bool) usize {
    if (base64) return std.base64.standard.Encoder.calcSize(source.len);
    return encodedLen(source);
}

/// Longest prefix of `source` costing at most `max_encoded` once encoded.
pub fn headCut(source: []const u8, max_encoded: usize, base64: bool) usize {
    if (base64) return @min(source.len, max_encoded / 4 * 3);
    return encodedPrefixLen(source, max_encoded);
}

/// Longest suffix of `source` costing at most `max_encoded` once encoded.
pub fn tailCut(source: []const u8, max_encoded: usize, base64: bool) usize {
    if (base64) return @min(source.len, max_encoded / 4 * 3);
    return encodedSuffixLen(source, max_encoded);
}

pub fn floorUtf8Boundary(bytes: []const u8, desired: usize) usize {
    var end = @min(desired, bytes.len);
    if (end == bytes.len) return end;
    while (end > 0 and isUtf8ContinuationByte(bytes[end])) : (end -= 1) {}
    return end;
}

pub fn ceilUtf8Boundary(bytes: []const u8, desired: usize) usize {
    var start = @min(desired, bytes.len);
    while (start < bytes.len and isUtf8ContinuationByte(bytes[start])) : (start += 1) {}
    return start;
}

fn isUtf8ContinuationByte(byte: u8) bool {
    return (byte & 0b1100_0000) == 0b1000_0000;
}

test "budget scales with the window and clamps at both ends" {
    try std.testing.expectEqual(PER_RESULT_MIN_BYTES, perResultBytes(0));
    try std.testing.expectEqual(PER_RESULT_MIN_BYTES, perResultBytes(32_000));
    try std.testing.expectEqual(@as(usize, 25_000), perResultBytes(200_000));
    try std.testing.expectEqual(@as(usize, 32_768), perResultBytes(262_144));
    try std.testing.expectEqual(PER_RESULT_MAX_BYTES, perResultBytes(2_000_000));
    try std.testing.expectEqual(PER_TURN_MIN_BYTES, perTurnBytes(0));
    try std.testing.expectEqual(PER_TURN_MAX_BYTES, perTurnBytes(200_000));
    try std.testing.expectEqual(Budget.floor, Budget.fromModel(0));
}

test "payloadAllowance saturates instead of wrapping" {
    const budget = Budget.fromModel(200_000);
    try std.testing.expectEqual(@as(usize, 25_000 - 2048), budget.payloadAllowance(2048));
    try std.testing.expectEqual(@as(usize, 0), budget.payloadAllowance(1 << 40));
}

test "splitPair gives an empty channel's share to the channel that needs it" {
    // Both fit: neither is cut.
    try std.testing.expectEqual(Pair{ .first = 300, .second = 40 }, splitPair(1000, 300, 40));
    // The common shape: stderr empty, stdout takes the whole allowance.
    try std.testing.expectEqual(Pair{ .first = 1000, .second = 0 }, splitPair(1000, 9000, 0));
    // A small stderr keeps exactly what it needs; stdout takes the rest,
    // which is more than half.
    try std.testing.expectEqual(Pair{ .first = 900, .second = 100 }, splitPair(1000, 9000, 100));
    // Symmetric.
    try std.testing.expectEqual(Pair{ .first = 100, .second = 900 }, splitPair(1000, 100, 9000));
    // Only when both exceed their half is the allowance actually halved.
    try std.testing.expectEqual(Pair{ .first = 500, .second = 500 }, splitPair(1000, 9000, 9000));
    // Odd allowances lose no byte to rounding.
    const odd = splitPair(1001, 9000, 9000);
    try std.testing.expectEqual(@as(usize, 1001), odd.first + odd.second);
}

test "encoded length matches std.json.Stringify byte for byte" {
    const cases = [_][]const u8{
        "plain ascii",
        "quote\" backslash\\ newline\n tab\t return\r",
        "control\x01\x02\x1f",
        "多字节 UTF-8 内容",
        "",
    };
    for (cases) |case| {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try std.json.Stringify.encodeJsonString(case, .{}, &out.writer);
        // The writer emits the surrounding quotes; encodedLen counts the body.
        try std.testing.expectEqual(out.written().len - 2, encodedLen(case));
    }
}

test "encoded prefix and suffix respect the encoded budget, not the source length" {
    // Every byte escapes to two, so only half as many source bytes fit.
    const escaped = "\n\n\n\n\n\n\n\n\n\n";
    try std.testing.expectEqual(@as(usize, 5), encodedPrefixLen(escaped, 10));
    try std.testing.expectEqual(@as(usize, 5), encodedSuffixLen(escaped, 10));
    // Plain bytes map one to one.
    try std.testing.expectEqual(@as(usize, 10), encodedPrefixLen("0123456789", 10));
    // Budget larger than the content returns the content.
    try std.testing.expectEqual(@as(usize, 10), encodedPrefixLen("0123456789", 999));
    try std.testing.expectEqual(@as(usize, 10), encodedSuffixLen("0123456789", 999));
    // A zero budget yields nothing rather than a partial codepoint.
    try std.testing.expectEqual(@as(usize, 0), encodedPrefixLen("abc", 0));
    try std.testing.expectEqual(@as(usize, 0), encodedSuffixLen("abc", 0));
}

test "encoded cuts never split a codepoint" {
    const text = "aa\u{4F60}\u{597D}bb"; // 2 + 3 + 3 + 2 bytes
    // A budget of 4 can hold "aa" plus one byte of the next codepoint; the cut
    // must fall back to the boundary at 2.
    try std.testing.expectEqual(@as(usize, 2), encodedPrefixLen(text, 4));
    try std.testing.expectEqual(@as(usize, 5), encodedPrefixLen(text, 5));
    // Same from the tail: a budget of 4 holds "bb" plus one trailing byte.
    try std.testing.expectEqual(@as(usize, 2), encodedSuffixLen(text, 4));
    try std.testing.expectEqual(@as(usize, 5), encodedSuffixLen(text, 5));
    for ([_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }) |limit| {
        const head = encodedPrefixLen(text, limit);
        const tail = encodedSuffixLen(text, limit);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text[0..head]));
        try std.testing.expect(std.unicode.utf8ValidateSlice(text[text.len - tail ..]));
        try std.testing.expect(encodedLen(text[0..head]) <= limit);
        try std.testing.expect(encodedLen(text[text.len - tail ..]) <= limit);
    }
}

test "headCut and tailCut never exceed the encoded budget they were given" {
    const cases = [_][]const u8{
        "plain ascii content that maps one to one",
        "\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"",
        "line\nline\nline\nline\nline\n",
        "\x00\x01\x02binary\xff\xfe payload",
        "\u{4F60}\u{597D}\u{4E16}\u{754C}",
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |base64| {
            var limit: usize = 0;
            while (limit <= 64) : (limit += 1) {
                const head = headCut(case, limit, base64);
                const tail = tailCut(case, limit, base64);
                try std.testing.expect(encodedCost(case[0..head], base64) <= limit);
                try std.testing.expect(encodedCost(case[case.len - tail ..], base64) <= limit);
            }
        }
    }
}
