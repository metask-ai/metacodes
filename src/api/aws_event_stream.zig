//! AWS event stream framing (`application/vnd.amazon.eventstream`).
//!
//! The binary framing Bedrock's streaming APIs (ConverseStream,
//! InvokeModelWithResponseStream) use instead of SSE. It is a *framing*, not a
//! protocol: each frame carries headers that name the event and a payload the
//! wire protocol interprets (for Converse, one JSON object per event).
//!
//! ```text
//! frame   = prelude headers payload message_crc
//! prelude = total_length:u32be headers_length:u32be prelude_crc:u32be
//! header  = name_len:u8 name value_type:u8 value
//! ```
//!
//! Both CRCs are CRC-32 (IEEE) and are checked: a frame that fails either is
//! corrupt, and interpreting its payload would act on bytes the server never
//! sent. Header values are typed; the ones Bedrock sends (`:message-type`,
//! `:event-type`, `:exception-type`, `:content-type`) are strings.
//!
//! Reference: https://docs.aws.amazon.com/AmazonS3/latest/API/RESTSelectObjectAppendix.html
//! (the shared event stream encoding) and the smithy `vnd.amazon.eventstream`
//! specification.

const std = @import("std");

/// Prelude (12) plus the trailing message CRC (4).
pub const OVERHEAD: usize = 16;
/// The largest frame accepted. AWS caps an event stream message at 16 MiB;
/// a declared length beyond that is corruption, not a large event.
pub const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;
/// More headers than any Bedrock event carries; a frame with more is refused
/// rather than partially read.
pub const MAX_HEADERS: usize = 16;

pub const DecodeError = error{
    FrameTooShort,
    FrameTooLarge,
    LengthMismatch,
    PreludeChecksumMismatch,
    MessageChecksumMismatch,
    MalformedHeader,
    TooManyHeaders,
};

pub const ValueType = enum(u8) {
    bool_true = 0,
    bool_false = 1,
    byte = 2,
    short = 3,
    int = 4,
    long = 5,
    bytes = 6,
    string = 7,
    timestamp = 8,
    uuid = 9,
};

pub const Value = union(ValueType) {
    bool_true,
    bool_false,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
    bytes: []const u8,
    string: []const u8,
    timestamp: i64,
    uuid: [16]u8,
};

pub const Header = struct {
    name: []const u8,
    value: Value,
};

/// One decoded frame. Slices borrow the frame bytes.
pub const Message = struct {
    headers: []const Header,
    payload: []const u8,

    /// The string value of header `name`, or null when absent or not a string.
    pub fn header(self: Message, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (!std.mem.eql(u8, h.name, name)) continue;
            return switch (h.value) {
                .string => |text| text,
                else => null,
            };
        }
        return null;
    }
};

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

/// Total frame length declared by a 12-byte prelude, after checking the
/// prelude's own CRC. Lets a reader size the rest of the frame before reading
/// it.
pub fn frameLength(prelude: *const [12]u8) DecodeError!usize {
    const total = readU32(prelude[0..4]);
    const headers_len = readU32(prelude[4..8]);
    if (std.hash.Crc32.hash(prelude[0..8]) != readU32(prelude[8..12])) return error.PreludeChecksumMismatch;
    if (total < OVERHEAD) return error.FrameTooShort;
    if (total > MAX_FRAME_BYTES) return error.FrameTooLarge;
    if (headers_len > total - OVERHEAD) return error.LengthMismatch;
    return total;
}

/// Decode one complete frame. `headers_buf` receives the headers; the
/// returned message borrows `frame` and `headers_buf`.
pub fn decode(frame: []const u8, headers_buf: *[MAX_HEADERS]Header) DecodeError!Message {
    if (frame.len < OVERHEAD) return error.FrameTooShort;
    const total = try frameLength(frame[0..12]);
    if (total != frame.len) return error.LengthMismatch;
    if (std.hash.Crc32.hash(frame[0 .. frame.len - 4]) != readU32(frame[frame.len - 4 ..])) return error.MessageChecksumMismatch;
    const headers_len = readU32(frame[4..8]);
    const headers_bytes = frame[12 .. 12 + headers_len];
    const payload = frame[12 + headers_len .. frame.len - 4];

    var count: usize = 0;
    var at: usize = 0;
    while (at < headers_bytes.len) {
        if (count == MAX_HEADERS) return error.TooManyHeaders;
        const name_len = headers_bytes[at];
        at += 1;
        if (name_len == 0 or at + name_len + 1 > headers_bytes.len) return error.MalformedHeader;
        const name = headers_bytes[at .. at + name_len];
        at += name_len;
        const type_byte = headers_bytes[at];
        at += 1;
        const value_type = std.enums.fromInt(ValueType, type_byte) orelse return error.MalformedHeader;
        const rest = headers_bytes[at..];
        const value: Value, const used: usize = switch (value_type) {
            .bool_true => .{ .bool_true, 0 },
            .bool_false => .{ .bool_false, 0 },
            .byte => blk: {
                if (rest.len < 1) return error.MalformedHeader;
                break :blk .{ .{ .byte = @bitCast(rest[0]) }, 1 };
            },
            .short => blk: {
                if (rest.len < 2) return error.MalformedHeader;
                break :blk .{ .{ .short = std.mem.readInt(i16, rest[0..2], .big) }, 2 };
            },
            .int => blk: {
                if (rest.len < 4) return error.MalformedHeader;
                break :blk .{ .{ .int = std.mem.readInt(i32, rest[0..4], .big) }, 4 };
            },
            .long, .timestamp => blk: {
                if (rest.len < 8) return error.MalformedHeader;
                const v = std.mem.readInt(i64, rest[0..8], .big);
                break :blk .{ if (value_type == .long) Value{ .long = v } else Value{ .timestamp = v }, 8 };
            },
            .bytes, .string => blk: {
                if (rest.len < 2) return error.MalformedHeader;
                const len = std.mem.readInt(u16, rest[0..2], .big);
                if (rest.len < 2 + @as(usize, len)) return error.MalformedHeader;
                const bytes = rest[2 .. 2 + len];
                break :blk .{ if (value_type == .string) Value{ .string = bytes } else Value{ .bytes = bytes }, 2 + @as(usize, len) };
            },
            .uuid => blk: {
                if (rest.len < 16) return error.MalformedHeader;
                break :blk .{ .{ .uuid = rest[0..16].* }, 16 };
            },
        };
        at += used;
        headers_buf[count] = .{ .name = name, .value = value };
        count += 1;
    }
    return .{ .headers = headers_buf[0..count], .payload = payload };
}

pub const ReadError = DecodeError || std.Io.Reader.Error || std.mem.Allocator.Error || error{TruncatedFrame};

/// Read the next whole frame from `reader` into memory owned by the caller
/// (free with `allocator`). Null at a clean end of stream — no byte of a new
/// frame arrived; a frame cut short is `TruncatedFrame`.
pub fn readFrame(reader: *std.Io.Reader, allocator: std.mem.Allocator) ReadError!?[]u8 {
    var prelude: [12]u8 = undefined;
    const got = reader.readSliceShort(&prelude) catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
    };
    if (got == 0) return null;
    if (got < prelude.len) return error.TruncatedFrame;
    const total = try frameLength(&prelude);
    const frame = try allocator.alloc(u8, total);
    errdefer allocator.free(frame);
    @memcpy(frame[0..12], &prelude);
    reader.readSliceAll(frame[12..]) catch |err| switch (err) {
        error.EndOfStream => return error.TruncatedFrame,
        error.ReadFailed => return error.ReadFailed,
    };
    return frame;
}

/// Encode a frame with string headers. Test fixtures and mock servers use it;
/// the client only decodes.
pub fn encode(allocator: std.mem.Allocator, headers: []const [2][]const u8, payload: []const u8) ![]u8 {
    var header_bytes: std.ArrayList(u8) = .empty;
    defer header_bytes.deinit(allocator);
    for (headers) |pair| {
        try header_bytes.append(allocator, @intCast(pair[0].len));
        try header_bytes.appendSlice(allocator, pair[0]);
        try header_bytes.append(allocator, @intFromEnum(ValueType.string));
        var len: [2]u8 = undefined;
        std.mem.writeInt(u16, &len, @intCast(pair[1].len), .big);
        try header_bytes.appendSlice(allocator, &len);
        try header_bytes.appendSlice(allocator, pair[1]);
    }
    const total = OVERHEAD + header_bytes.items.len + payload.len;
    const out = try allocator.alloc(u8, total);
    std.mem.writeInt(u32, out[0..4], @intCast(total), .big);
    std.mem.writeInt(u32, out[4..8], @intCast(header_bytes.items.len), .big);
    std.mem.writeInt(u32, out[8..12], std.hash.Crc32.hash(out[0..8]), .big);
    @memcpy(out[12 .. 12 + header_bytes.items.len], header_bytes.items);
    @memcpy(out[12 + header_bytes.items.len .. total - 4], payload);
    std.mem.writeInt(u32, out[total - 4 ..][0..4], std.hash.Crc32.hash(out[0 .. total - 4]), .big);
    return out;
}

/// A Bedrock event frame: `:message-type event`, `:event-type <name>`, JSON.
pub fn encodeEvent(allocator: std.mem.Allocator, event_type: []const u8, json: []const u8) ![]u8 {
    return encode(allocator, &.{
        .{ ":event-type", event_type },
        .{ ":content-type", "application/json" },
        .{ ":message-type", "event" },
    }, json);
}

// ── tests ────────────────────────────────────────────────────────────────────

test "a frame round-trips: headers by name, payload intact" {
    const a = std.testing.allocator;
    const frame = try encodeEvent(a, "contentBlockDelta", "{\"delta\":{\"text\":\"hi\"}}");
    defer a.free(frame);
    var headers: [MAX_HEADERS]Header = undefined;
    const message = try decode(frame, &headers);
    try std.testing.expectEqualStrings("contentBlockDelta", message.header(":event-type").?);
    try std.testing.expectEqualStrings("event", message.header(":message-type").?);
    try std.testing.expect(message.header(":exception-type") == null);
    try std.testing.expectEqualStrings("{\"delta\":{\"text\":\"hi\"}}", message.payload);
}

test "a known vector from the AWS event stream specification decodes" {
    // The empty-message vector of the reference implementation's test suite
    // (awslabs/aws-c-event-stream): total 16, no headers, no payload.
    const empty = [_]u8{ 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x05, 0xc2, 0x48, 0xeb, 0x7d, 0x98, 0xc8, 0xff };
    var headers: [MAX_HEADERS]Header = undefined;
    const message = try decode(&empty, &headers);
    try std.testing.expectEqual(@as(usize, 0), message.headers.len);
    try std.testing.expectEqual(@as(usize, 0), message.payload.len);
}

test "corruption anywhere is refused, never interpreted" {
    const a = std.testing.allocator;
    const frame = try encodeEvent(a, "messageStop", "{\"stopReason\":\"end_turn\"}");
    defer a.free(frame);
    var headers: [MAX_HEADERS]Header = undefined;

    const flipped_payload = try a.dupe(u8, frame);
    defer a.free(flipped_payload);
    flipped_payload[frame.len - 8] ^= 0x01;
    try std.testing.expectError(error.MessageChecksumMismatch, decode(flipped_payload, &headers));

    const flipped_prelude = try a.dupe(u8, frame);
    defer a.free(flipped_prelude);
    flipped_prelude[3] ^= 0x01;
    try std.testing.expectError(error.PreludeChecksumMismatch, decode(flipped_prelude, &headers));

    try std.testing.expectError(error.LengthMismatch, decode(frame[0 .. frame.len - 1], &headers));
    try std.testing.expectError(error.FrameTooShort, decode(frame[0..8], &headers));
}

test "readFrame splits a byte stream into frames and reports truncation" {
    const a = std.testing.allocator;
    const one = try encodeEvent(a, "messageStart", "{\"role\":\"assistant\"}");
    defer a.free(one);
    const two = try encodeEvent(a, "metadata", "{\"usage\":{\"inputTokens\":3}}");
    defer a.free(two);
    const stream = try std.mem.concat(a, u8, &.{ one, two });
    defer a.free(stream);

    var reader: std.Io.Reader = .fixed(stream);
    const first = (try readFrame(&reader, a)).?;
    defer a.free(first);
    try std.testing.expectEqualSlices(u8, one, first);
    const second = (try readFrame(&reader, a)).?;
    defer a.free(second);
    try std.testing.expectEqualSlices(u8, two, second);
    try std.testing.expect(try readFrame(&reader, a) == null);

    var cut: std.Io.Reader = .fixed(stream[0 .. one.len + 5]);
    const whole = (try readFrame(&cut, a)).?;
    a.free(whole);
    try std.testing.expectError(error.TruncatedFrame, readFrame(&cut, a));
}

test "a declared length beyond the cap is corruption, not an allocation" {
    var prelude: [12]u8 = undefined;
    std.mem.writeInt(u32, prelude[0..4], MAX_FRAME_BYTES + 1, .big);
    std.mem.writeInt(u32, prelude[4..8], 0, .big);
    std.mem.writeInt(u32, prelude[8..12], std.hash.Crc32.hash(prelude[0..8]), .big);
    try std.testing.expectError(error.FrameTooLarge, frameLength(&prelude));
}
