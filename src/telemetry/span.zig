//! The span model the OpenTelemetry layer records and exports.
//!
//! A `Span` is plain data: identifiers, a time range, attributes, events and a
//! status. It does not know how it is encoded (`otlp.zig`) or where it goes
//! (`recorder.zig` hands finished spans to the session store and the process
//! exporter). Slices are borrowed from whoever built the span, normally the
//! recorder's run arena, and are valid only for the duration of the sink call.
//!
//! Message content (prompts, model output, tool arguments and results) is
//! marked on the attribute itself (`Attribute.content`), so the policy that
//! decides whether content leaves the machine is applied by the encoder, once,
//! instead of by every place that builds a span.

const std = @import("std");
const rng = @import("platform").rng;

/// W3C trace id: 16 bytes, never all zero.
pub const TraceId = struct {
    bytes: [16]u8,

    pub fn random() TraceId {
        var id: TraceId = .{ .bytes = undefined };
        fillNonZero(&id.bytes);
        return id;
    }

    pub fn hex(self: TraceId) [32]u8 {
        return std.fmt.bytesToHex(self.bytes, .lower);
    }
};

/// W3C span id: 8 bytes, never all zero.
pub const SpanId = struct {
    bytes: [8]u8,

    pub fn random() SpanId {
        var id: SpanId = .{ .bytes = undefined };
        fillNonZero(&id.bytes);
        return id;
    }

    pub fn hex(self: SpanId) [16]u8 {
        return std.fmt.bytesToHex(self.bytes, .lower);
    }
};

/// An all-zero id is invalid in W3C trace context. The entropy source failing
/// is not a reason to stop a Run, so a failed read falls back to the clock and
/// a counter: unique within the process, which is what a span tree needs.
fn fillNonZero(buf: []u8) void {
    if (!rng.randomBytes(buf)) {
        const S = struct {
            var counter = std.atomic.Value(u64).init(0);
        };
        const seed: u64 = @truncate(@as(u128, @bitCast(@as(i128, @import("../util/time.zig").nowWallNs()))));
        var prng = std.Random.DefaultPrng.init(seed ^ S.counter.fetchAdd(0x9e3779b97f4a7c15, .monotonic));
        prng.random().bytes(buf);
    }
    for (buf) |b| if (b != 0) return;
    buf[buf.len - 1] = 1;
}

/// OTLP `Span.SpanKind` values.
pub const Kind = enum(u8) {
    internal = 1,
    server = 2,
    client = 3,
    producer = 4,
    consumer = 5,
};

/// OTLP status. An error carries its description; the other two cannot.
pub const Status = union(enum) {
    unset,
    ok,
    @"error": []const u8,

    /// OTLP `Status.StatusCode`.
    pub fn code(self: Status) u8 {
        return switch (self) {
            .unset => 0,
            .ok => 1,
            .@"error" => 2,
        };
    }
};

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    double: f64,
    boolean: bool,
};

pub const Attribute = struct {
    key: []const u8,
    value: Value,
    /// Message content: prompts, model output, tool arguments and results.
    /// Exported only when the destination's policy says so (see
    /// `otlp.ContentPolicy`).
    content: bool = false,

    pub fn str(key: []const u8, value: []const u8) Attribute {
        return .{ .key = key, .value = .{ .string = value } };
    }
    pub fn int(key: []const u8, value: anytype) Attribute {
        return .{ .key = key, .value = .{ .int = std.math.cast(i64, value) orelse std.math.maxInt(i64) } };
    }
    pub fn boolean(key: []const u8, value: bool) Attribute {
        return .{ .key = key, .value = .{ .boolean = value } };
    }
    pub fn text(key: []const u8, value: []const u8) Attribute {
        return .{ .key = key, .value = .{ .string = value }, .content = true };
    }
};

pub const Event = struct {
    name: []const u8,
    time_unix_nano: u64,
    attributes: []const Attribute = &.{},
};

pub const Span = struct {
    trace_id: TraceId,
    span_id: SpanId,
    /// Null for the root span of a trace.
    parent_span_id: ?SpanId = null,
    name: []const u8,
    kind: Kind = .internal,
    start_unix_nano: u64,
    end_unix_nano: u64,
    attributes: []const Attribute = &.{},
    events: []const Event = &.{},
    status: Status = .unset,
};

/// Wall-clock nanoseconds since the Unix epoch, as OTLP wants them.
pub fn nowUnixNano() u64 {
    const ns = @import("../util/time.zig").nowWallNs();
    return if (ns <= 0) 0 else @intCast(ns);
}

/// The longest prefix of `bytes` that is at most `max` bytes and does not end
/// inside a UTF-8 sequence.
pub fn truncateUtf8(bytes: []const u8, max: usize) []const u8 {
    if (bytes.len <= max) return bytes;
    var end = max;
    // Step back over continuation bytes, then over the lead byte whose
    // sequence would not fit.
    while (end > 0 and (bytes[end] & 0xC0) == 0x80) end -= 1;
    return bytes[0..end];
}

test "otel: ids are random, non-zero and hex encode to their W3C width" {
    const a = TraceId.random();
    const b = TraceId.random();
    try std.testing.expect(!std.mem.eql(u8, &a.bytes, &b.bytes));
    try std.testing.expect(!std.mem.allEqual(u8, &a.bytes, 0));
    const h = a.hex();
    try std.testing.expectEqual(@as(usize, 32), h.len);
    try std.testing.expectEqual(@as(usize, 16), SpanId.random().hex().len);
}

test "otel: truncateUtf8 never splits a multi-byte character" {
    const s = "ab中文"; // 2 + 3 + 3 bytes
    try std.testing.expectEqualStrings("ab", truncateUtf8(s, 3));
    try std.testing.expectEqualStrings("ab", truncateUtf8(s, 4));
    try std.testing.expectEqualStrings("ab中", truncateUtf8(s, 5));
    try std.testing.expectEqualStrings(s, truncateUtf8(s, 100));
}
