//! Small, shared UTF-8 boundary helpers.
//!
//! These helpers operate on byte offsets because the streaming tools expose
//! byte cursors. A prefix may contain arbitrary bytes (the JSON/text sink is
//! responsible for repairing invalid UTF-8), but a valid multi-byte sequence
//! is never split by a boundary returned here.

const std = @import("std");

const replacement = "\u{FFFD}";

pub fn isContinuationByte(byte: u8) bool {
    return (byte & 0b1100_0000) == 0b1000_0000;
}

/// Move an offset that may point into a UTF-8 sequence to the next sequence
/// boundary. Invalid bytes are treated as one-byte units so the cursor always
/// makes progress.
pub fn ceilBoundary(bytes: []const u8, offset: usize) usize {
    var p = @min(offset, bytes.len);
    while (p < bytes.len and isContinuationByte(bytes[p])) : (p += 1) {}
    return p;
}

/// Return the largest prefix no longer than `limit` that does not split a
/// valid UTF-8 sequence. Invalid bytes remain addressable as one-byte units;
/// callers that serialize text must repair them explicitly.
pub fn prefixEnd(bytes: []const u8, limit: usize) usize {
    const bound = @min(limit, bytes.len);
    var p: usize = 0;
    while (p < bound) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[p]) catch {
            p += 1;
            continue;
        };
        if (p + length > bound) break;
        if (p + length <= bytes.len and std.unicode.utf8ValidateSlice(bytes[p .. p + length])) {
            p += length;
        } else {
            p += 1;
        }
    }
    return p;
}

/// Advance over exactly one valid code point, or one byte for malformed
/// input. This prevents a max-byte page smaller than a code point from
/// returning an empty page forever.
pub fn nextBoundary(bytes: []const u8, offset: usize) usize {
    const p = @min(offset, bytes.len);
    if (p >= bytes.len) return p;
    const length = std.unicode.utf8ByteSequenceLength(bytes[p]) catch return p + 1;
    if (p + length <= bytes.len and std.unicode.utf8ValidateSlice(bytes[p .. p + length])) return p + length;
    return p + 1;
}

/// Return a bounded page which makes progress even when the first code point
/// is wider than the requested budget. The source cursor remains a raw-byte
/// offset; the caller decides how an invalid byte is represented downstream.
pub fn pagePrefix(bytes: []const u8, max_bytes: usize) []const u8 {
    if (bytes.len == 0 or max_bytes == 0) return bytes[0..0];
    if (bytes.len <= max_bytes) return bytes;
    const end = prefixEnd(bytes, max_bytes);
    if (end != 0) return bytes[0..end];
    return bytes[0..nextBoundary(bytes, 0)];
}

/// Copy bytes while replacing malformed UTF-8 one byte at a time. This is
/// intentionally a recovery primitive for already persisted text; new data
/// should be validated at its source boundary instead of repaired here.
pub fn repairInvalidUtf8(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(allocator, replacement);
            i += 1;
            continue;
        };
        if (i + length <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + length])) {
            try out.appendSlice(allocator, bytes[i .. i + length]);
            i += length;
        } else {
            try out.appendSlice(allocator, replacement);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

test "UTF-8 boundaries never split a valid sequence and always advance" {
    const text = "ab中文😀z";
    try std.testing.expectEqual(@as(usize, 2), prefixEnd(text, 3));
    try std.testing.expectEqual(@as(usize, 5), prefixEnd(text, 5));
    try std.testing.expectEqual(@as(usize, 5), ceilBoundary(text, 3));
    try std.testing.expectEqual(@as(usize, 8), nextBoundary(text, 5));
    try std.testing.expectEqual(@as(usize, 1), nextBoundary("\xe4", 0));
}

test "UTF-8 boundary treats malformed bytes as progress units" {
    const bytes = "a\xe4\x60";
    try std.testing.expectEqual(@as(usize, 1), prefixEnd(bytes, 2));
    try std.testing.expectEqual(@as(usize, 2), nextBoundary(bytes, 1));
}

test "pagePrefix makes progress when a code point exceeds the budget" {
    const text = "中";
    try std.testing.expectEqualStrings(text, pagePrefix(text, 1));
    try std.testing.expectEqualStrings(text, pagePrefix(text, 2));
}

test "repairInvalidUtf8 replaces malformed bytes without changing valid text" {
    const repaired = try repairInvalidUtf8(std.testing.allocator, "ok\xe4\x60中文\x80");
    defer std.testing.allocator.free(repaired);
    try std.testing.expectEqualStrings("ok\u{FFFD}`中文\u{FFFD}", repaired);
}
