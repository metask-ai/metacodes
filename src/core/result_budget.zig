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
const artifact_store = @import("tool_result_artifact.zig");

/// Two units, kept apart by the type system because every byte-budget defect
/// this file has had was a confusion between them.
///
/// Scope is deliberate, and was arrived at by measurement rather than taste.
/// The units are enforced where a *conversion* happens - the cut and cost
/// primitives, and the allowance that feeds them. `Budget`'s own fields stay
/// plain `usize`: they are compared against a committed result's own length,
/// which is the same unit, so typing them added seventeen `.raw()` calls at
/// boundaries that were never in danger and caught nothing. Types are a tax
/// wherever they are not preventing a confusion; the tax is only worth paying
/// at the crossings.
///
/// `Source` counts bytes as they sit in the content buffer. `Encoded` counts
/// what those bytes cost once rendered into the envelope - JSON escaping can
/// double a byte, base64 expands 4:3, and a base64 *string* is itself Encoded
/// while what it decodes to is Source. A cut takes an `Encoded` budget and
/// answers in `Source`, which is exactly the conversion that kept being
/// skipped: reading `target` source bytes when `target` was an encoded
/// allowance, clamping a recovery read the same way, and writing a base64
/// character count into a counter documented as original bytes.
///
/// Non-exhaustive enums rather than structs: zero representation cost, and
/// `@intFromEnum` makes every crossing between the units something you have to
/// write down.
pub const Source = enum(usize) {
    _,
    pub inline fn of(n: usize) Source {
        return @enumFromInt(n);
    }
    pub inline fn raw(self: Source) usize {
        return @intFromEnum(self);
    }
    pub inline fn lte(self: Source, other: Source) bool {
        return self.raw() <= other.raw();
    }
    pub inline fn plus(self: Source, other: Source) Source {
        return of(self.raw() +| other.raw());
    }

    /// Take the cut instead of handing back a bare length.
    ///
    /// This is ergonomics, not safety, and the distinction is worth stating
    /// because the first draft of this comment claimed otherwise. Slicing
    /// through the type removes the `.raw()` at every cut site and keeps the
    /// length next to the buffer it came from in the source text - but
    /// `head(wrong_buffer)` still type-checks. Pinning a length to *its*
    /// buffer would need a phantom parameter on `Source`, which is a different
    /// order of complexity; buffer mix-ups remain a job for tests.
    pub inline fn head(self: Source, bytes: []const u8) []const u8 {
        return bytes[0..@min(self.raw(), bytes.len)];
    }

    pub inline fn tail(self: Source, bytes: []const u8) []const u8 {
        return bytes[bytes.len - @min(self.raw(), bytes.len) ..];
    }

    /// What is left after the head cut - the buffer a tail cut may use.
    pub inline fn rest(self: Source, bytes: []const u8) []const u8 {
        return bytes[@min(self.raw(), bytes.len)..];
    }
};

pub const Encoded = enum(usize) {
    _,
    pub inline fn of(n: usize) Encoded {
        return @enumFromInt(n);
    }
    pub inline fn raw(self: Encoded) usize {
        return @intFromEnum(self);
    }
    pub inline fn lte(self: Encoded, other: Encoded) bool {
        return self.raw() <= other.raw();
    }
    /// Saturating: an overhead larger than the whole budget yields zero.
    pub inline fn minus(self: Encoded, other: Encoded) Encoded {
        return of(self.raw() -| other.raw());
    }
    pub inline fn plus(self: Encoded, other: Encoded) Encoded {
        return of(self.raw() +| other.raw());
    }
    pub inline fn scaled(self: Encoded, num: usize, den: usize) Encoded {
        return of(self.raw() / den * num);
    }
    pub inline fn min(self: Encoded, other: Encoded) Encoded {
        return of(@min(self.raw(), other.raw()));
    }
};

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

/// Whether bytes remain safe to hand back inline after CAS publication fails.
/// This preserves the pre-publication degradation path: projection can still
/// render a bounded head/tail envelope with `storage_error` for any complete
/// result the publisher could historically hold inline. `ceiling` is exactly
/// that: the largest result this publisher has ever held inline, so retaining
/// up to it reintroduces no new materialization. The native spool and the
/// AgentCore projector pass `PER_RESULT_MAX_BYTES` (they would have to read
/// the bytes back from disk); the classic MCP client passes the frame limit it
/// has already materialized. OOM cannot support a fallback allocation and an
/// incomplete capture has no complete inline form, so neither is retained.
pub fn retainInlineAfterFailedPublish(err: anyerror, bytes: u64, complete: bool, ceiling: u64) bool {
    if (err == error.OutOfMemory) return false;
    if (!complete) return false;
    return bytes <= ceiling;
}

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

pub const RECOVERY_TURN_DIVISOR: usize = 2;

/// Half the turn budget is reserved for exempt recovery reads. In a 200K
/// window, 4 full 25,000-byte chunks fit in 102,400; the 5th is deferred
/// (today 8 fit in projection and the 9th blows the turn).
pub fn recoveryAllowanceBytes(budget: Budget) usize {
    return budget.per_turn_bytes / RECOVERY_TURN_DIVISOR;
}

pub fn recoveryReadCost(budget: Budget) usize {
    return @max(1, @min(artifact_store.MAX_READ_BYTES, budget.per_result_bytes));
}

pub const Budget = struct {
    /// Deliberately plain `usize`, not `Encoded`. These are compared almost
    /// exclusively against a committed result's own length - same unit, no
    /// confusion possible - so typing them bought no safety and cost 17
    /// `.raw()` calls at boundaries that were never in danger. The units earn
    /// their keep where a *conversion* happens: the cut and cost primitives,
    /// and `payloadAllowance`, which feeds them.
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
    /// The one crossing on this type: a plain budget becomes an `Encoded`
    /// allowance the cut primitives can spend.
    pub fn payloadAllowance(self: Budget, fixed_overhead: Encoded) Encoded {
        return Encoded.of(self.per_result_bytes).minus(fixed_overhead);
    }
};

pub const Pair = struct { first: Encoded, second: Encoded };

test "recovery allowance and cost follow turn budget" {
    const b = Budget.fromModel(200_000);
    try std.testing.expectEqual(@as(usize, 102_400), recoveryAllowanceBytes(b));
    try std.testing.expectEqual(@as(usize, 25_000), recoveryReadCost(b));
    const m = Budget.fromModel(1_000_000);
    try std.testing.expectEqual(perTurnBytes(1_000_000) / 2, recoveryAllowanceBytes(m));
    try std.testing.expectEqual(artifact_store.MAX_READ_BYTES, recoveryReadCost(m));
    try std.testing.expectEqual(@as(usize, PER_TURN_MIN_BYTES / 2), recoveryAllowanceBytes(Budget.floor));
}

/// Max-min fair split of one payload allowance between two channels.
///
/// A fixed half-each split is wrong for the common shape: a command that
/// writes 20KB to stdout and nothing to stderr would forfeit half its
/// allowance to an empty channel. Whichever channel fits inside its half takes
/// exactly what it needs and the remainder goes to the other; only when both
/// exceed their half is the allowance actually halved.
pub fn splitPair(allowance_e: Encoded, first_demand: Encoded, second_demand: Encoded) Pair {
    const allowance = allowance_e.raw();
    const first = first_demand.raw();
    const second = second_demand.raw();
    if (first +| second <= allowance) return .{ .first = first_demand, .second = second_demand };
    const half = allowance / 2;
    if (first <= half) return .{ .first = first_demand, .second = Encoded.of(allowance - first) };
    if (second <= half) return .{ .first = Encoded.of(allowance - second), .second = second_demand };
    return .{ .first = Encoded.of(half), .second = Encoded.of(allowance - half) };
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

pub fn encodedLen(bytes: []const u8) Encoded {
    var total: usize = 0;
    for (bytes) |byte| total +|= encodedByteLen(byte);
    return Encoded.of(total);
}

/// Longest prefix of `bytes` whose encoded form fits in `max_encoded`, cut on
/// a UTF-8 boundary so the preview never ends mid-codepoint.
pub fn encodedPrefixLen(bytes: []const u8, max_encoded: Encoded) Source {
    const limit = max_encoded.raw();
    var used: usize = 0;
    var end: usize = 0;
    while (end < bytes.len) : (end += 1) {
        const cost = encodedByteLen(bytes[end]);
        if (used + cost > limit) break;
        used += cost;
    }
    return Source.of(floorUtf8Boundary(bytes, end));
}

/// Longest suffix of `bytes` whose encoded form fits in `max_encoded`, cut on
/// a UTF-8 boundary.
pub fn encodedSuffixLen(bytes: []const u8, max_encoded: Encoded) Source {
    const limit = max_encoded.raw();
    var used: usize = 0;
    var start: usize = bytes.len;
    while (start > 0) {
        const cost = encodedByteLen(bytes[start - 1]);
        if (used + cost > limit) break;
        used += cost;
        start -= 1;
    }
    return Source.of(bytes.len - ceilUtf8Boundary(bytes, start));
}

/// Encoded cost of `source` in the encoding the envelope will render it with.
/// JSON escaping is per byte; base64 expands 4:3 and never escapes.
///
/// One definition, because every layer that cuts a preview has to agree with
/// the layer that renders it: two independent copies of "how much will this
/// cost" is how a preview ends up sized against one encoding and emitted in
/// another.
pub fn encodedCost(source: []const u8, base64: bool) Encoded {
    if (base64) return Encoded.of(std.base64.standard.Encoder.calcSize(source.len));
    return encodedLen(source);
}

/// Longest prefix of `source` costing at most `max_encoded` once encoded.
pub fn headCut(source: []const u8, max_encoded: Encoded, base64: bool) Source {
    if (base64) return Source.of(@min(source.len, max_encoded.raw() / 4 * 3));
    return encodedPrefixLen(source, max_encoded);
}

/// Longest suffix of `source` costing at most `max_encoded` once encoded.
pub fn tailCut(source: []const u8, max_encoded: Encoded, base64: bool) Source {
    if (base64) return Source.of(@min(source.len, max_encoded.raw() / 4 * 3));
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
    try std.testing.expectEqual(Encoded.of(25_000 - 2048), budget.payloadAllowance(.of(2048)));
    try std.testing.expectEqual(Encoded.of(0), budget.payloadAllowance(.of(1 << 40)));
}

test "splitPair gives an empty channel's share to the channel that needs it" {
    // Both fit: neither is cut.
    try std.testing.expectEqual(Pair{ .first = Encoded.of(300), .second = Encoded.of(40) }, splitPair(.of(1000), .of(300), .of(40)));
    // The common shape: stderr empty, stdout takes the whole allowance.
    try std.testing.expectEqual(Pair{ .first = Encoded.of(1000), .second = Encoded.of(0) }, splitPair(.of(1000), .of(9000), .of(0)));
    // A small stderr keeps exactly what it needs; stdout takes the rest,
    // which is more than half.
    try std.testing.expectEqual(Pair{ .first = Encoded.of(900), .second = Encoded.of(100) }, splitPair(.of(1000), .of(9000), .of(100)));
    // Symmetric.
    try std.testing.expectEqual(Pair{ .first = Encoded.of(100), .second = Encoded.of(900) }, splitPair(.of(1000), .of(100), .of(9000)));
    // Only when both exceed their half is the allowance actually halved.
    try std.testing.expectEqual(Pair{ .first = Encoded.of(500), .second = Encoded.of(500) }, splitPair(.of(1000), .of(9000), .of(9000)));
    // Odd allowances lose no byte to rounding.
    const odd = splitPair(.of(1001), .of(9000), .of(9000));
    try std.testing.expectEqual(Encoded.of(1001), odd.first.plus(odd.second));
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
        try std.testing.expectEqual(Encoded.of(out.written().len - 2), encodedLen(case));
    }
}

test "encoded prefix and suffix respect the encoded budget, not the source length" {
    // Every byte escapes to two, so only half as many source bytes fit.
    const escaped = "\n\n\n\n\n\n\n\n\n\n";
    try std.testing.expectEqual(Source.of(5), encodedPrefixLen(escaped, .of(10)));
    try std.testing.expectEqual(Source.of(5), encodedSuffixLen(escaped, .of(10)));
    // Plain bytes map one to one.
    try std.testing.expectEqual(Source.of(10), encodedPrefixLen("0123456789", .of(10)));
    // Budget larger than the content returns the content.
    try std.testing.expectEqual(Source.of(10), encodedPrefixLen("0123456789", .of(999)));
    try std.testing.expectEqual(Source.of(10), encodedSuffixLen("0123456789", .of(999)));
    // A zero budget yields nothing rather than a partial codepoint.
    try std.testing.expectEqual(Source.of(0), encodedPrefixLen("abc", .of(0)));
    try std.testing.expectEqual(Source.of(0), encodedSuffixLen("abc", .of(0)));
}

test "encoded cuts never split a codepoint" {
    const text = "aa\u{4F60}\u{597D}bb"; // 2 + 3 + 3 + 2 bytes
    // A budget of 4 can hold "aa" plus one byte of the next codepoint; the cut
    // must fall back to the boundary at 2.
    try std.testing.expectEqual(Source.of(2), encodedPrefixLen(text, .of(4)));
    try std.testing.expectEqual(Source.of(5), encodedPrefixLen(text, .of(5)));
    // Same from the tail: a budget of 4 holds "bb" plus one trailing byte.
    try std.testing.expectEqual(Source.of(2), encodedSuffixLen(text, .of(4)));
    try std.testing.expectEqual(Source.of(5), encodedSuffixLen(text, .of(5)));
    for ([_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }) |limit| {
        const head = encodedPrefixLen(text, Encoded.of(limit)).raw();
        const tail = encodedSuffixLen(text, Encoded.of(limit)).raw();
        try std.testing.expect(std.unicode.utf8ValidateSlice(text[0..head]));
        try std.testing.expect(std.unicode.utf8ValidateSlice(text[text.len - tail ..]));
        try std.testing.expect(encodedLen(text[0..head]).raw() <= limit);
        try std.testing.expect(encodedLen(text[text.len - tail ..]).raw() <= limit);
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
                const head = headCut(case, Encoded.of(limit), base64).raw();
                const tail = tailCut(case, Encoded.of(limit), base64).raw();
                try std.testing.expect(encodedCost(case[0..head], base64).raw() <= limit);
                try std.testing.expect(encodedCost(case[case.len - tail ..], base64).raw() <= limit);
            }
        }
    }
}
