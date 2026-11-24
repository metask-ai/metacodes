//! The prompt profile checkpoint section (#184): the Session's profile, so a
//! restored Session renders the same system prompt bytes.
//!
//! Layout, little-endian: magic (8), entry count (u32), reserved zero (u32),
//! then per entry op (u8: the PROMPT_OP_* code), interpolate (u8), reserved
//! zero (6 bytes), order (i64), id length (u32), text length (u32), id, text.
//! A Session without a profile has no section at all (empty bytes).

const std = @import("std");
const core = @import("metacodes-core");
const prompt_sections = core.prompt_sections;

const magic = "R18PRMT\x00";
const header_bytes = magic.len + 8;
const entry_header_bytes = 1 + 1 + 6 + 8 + 4 + 4;

pub const DecodeError = error{
    OutOfMemory,
    /// Not a well-formed section.
    Corrupt,
    /// Well formed, but a profile this kernel refuses (for instance it names a
    /// kernel section that no longer exists).
    Unsupported,
};

fn opCode(op: prompt_sections.Op) u8 {
    return switch (op) {
        .add => 1,
        .replace => 2,
        .remove => 3,
    };
}

fn opFromCode(code: u8) ?prompt_sections.Op {
    return switch (code) {
        1 => .add,
        2 => .replace,
        3 => .remove,
        else => null,
    };
}

/// Encode a validated profile; an empty profile encodes to no bytes.
pub fn encode(allocator: std.mem.Allocator, profile: prompt_sections.Profile) ![]u8 {
    if (profile.isEmpty()) return allocator.alloc(u8, 0);
    var size: usize = header_bytes;
    for (profile.sections) |section| size += entry_header_bytes + section.id.len + section.text.len;
    const out = try allocator.alloc(u8, size);
    @memcpy(out[0..magic.len], magic);
    std.mem.writeInt(u32, out[magic.len..][0..4], @intCast(profile.sections.len), .little);
    std.mem.writeInt(u32, out[magic.len + 4 ..][0..4], 0, .little);
    var at: usize = header_bytes;
    for (profile.sections) |section| {
        out[at] = opCode(section.op);
        out[at + 1] = @intFromBool(section.interpolate);
        @memset(out[at + 2 .. at + 8], 0);
        std.mem.writeInt(i64, out[at + 8 ..][0..8], section.order, .little);
        std.mem.writeInt(u32, out[at + 16 ..][0..4], @intCast(section.id.len), .little);
        std.mem.writeInt(u32, out[at + 20 ..][0..4], @intCast(section.text.len), .little);
        at += entry_header_bytes;
        @memcpy(out[at..][0..section.id.len], section.id);
        at += section.id.len;
        @memcpy(out[at..][0..section.text.len], section.text);
        at += section.text.len;
    }
    std.debug.assert(at == size);
    return out;
}

/// Decode a section and validate the profile against this kernel.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!prompt_sections.OwnedProfile {
    if (bytes.len == 0) return .{};
    if (bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..magic.len], magic) or
        std.mem.readInt(u32, bytes[magic.len + 4 ..][0..4], .little) != 0)
        return error.Corrupt;
    const count = std.mem.readInt(u32, bytes[magic.len..][0..4], .little);
    // A section never holds an empty profile, and the count bounds the scratch
    // allocation before any entry is read.
    if (count == 0 or count > (bytes.len - header_bytes) / entry_header_bytes) return error.Corrupt;
    const sections = try allocator.alloc(prompt_sections.ProfileSection, count);
    defer allocator.free(sections);
    var at: usize = header_bytes;
    for (sections) |*section| {
        if (bytes.len - at < entry_header_bytes) return error.Corrupt;
        const op = opFromCode(bytes[at]) orelse return error.Corrupt;
        if (bytes[at + 1] > 1 or !std.mem.allEqual(u8, bytes[at + 2 .. at + 8], 0)) return error.Corrupt;
        const order = std.mem.readInt(i64, bytes[at + 8 ..][0..8], .little);
        const id_len = std.mem.readInt(u32, bytes[at + 16 ..][0..4], .little);
        const text_len = std.mem.readInt(u32, bytes[at + 20 ..][0..4], .little);
        at += entry_header_bytes;
        if (bytes.len - at < @as(u64, id_len) + text_len) return error.Corrupt;
        section.* = .{
            .op = op,
            .id = bytes[at..][0..id_len],
            .order = order,
            .text = bytes[at + id_len ..][0..text_len],
            .interpolate = bytes[at - entry_header_bytes + 1] == 1,
        };
        at += id_len + text_len;
    }
    if (at != bytes.len) return error.Corrupt;
    const profile: prompt_sections.Profile = .{ .sections = sections };
    if (core.system_prompt.validateProfile(profile) != null) return error.Unsupported;
    return prompt_sections.OwnedProfile.clone(allocator, profile);
}

const testing = std.testing;

test "a profile round-trips through its checkpoint section" {
    const profile: prompt_sections.Profile = .{ .sections = &.{
        .{ .op = .replace, .id = "metacodes:identity", .text = "You are Shopkeeper on {{platform}}.", .interpolate = true },
        .{ .op = .add, .id = "host:rules", .order = -5, .text = "Read the page first." },
        .{ .op = .remove, .id = "metacodes:tone" },
    } };
    const bytes = try encode(testing.allocator, profile);
    defer testing.allocator.free(bytes);
    var decoded = try decode(testing.allocator, bytes);
    defer decoded.deinit();
    try testing.expect(decoded.profile().eql(profile));

    const empty = try encode(testing.allocator, .{});
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
    var none = try decode(testing.allocator, empty);
    defer none.deinit();
    try testing.expect(none.profile().isEmpty());
}

test "a malformed or refused section fails closed" {
    const profile: prompt_sections.Profile = .{ .sections = &.{
        .{ .op = .add, .id = "host:rules", .order = 1, .text = "Rules." },
    } };
    const bytes = try encode(testing.allocator, profile);
    defer testing.allocator.free(bytes);
    // Every truncation, and a trailing byte, is corrupt.
    for (1..bytes.len) |len| {
        try testing.expectError(error.Corrupt, decode(testing.allocator, bytes[0..len]));
    }
    const longer = try std.mem.concat(testing.allocator, u8, &.{ bytes, "x" });
    defer testing.allocator.free(longer);
    try testing.expectError(error.Corrupt, decode(testing.allocator, longer));
    const mutated = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(mutated);
    for ([_]struct { usize, u8 }{
        .{ 0, 'X' }, // magic
        .{ magic.len, 0 }, // empty count
        .{ magic.len + 4, 1 }, // reserved
        .{ header_bytes, 9 }, // op
        .{ header_bytes + 1, 2 }, // interpolate
        .{ header_bytes + 2, 1 }, // reserved
    }) |case| {
        @memcpy(mutated, bytes);
        mutated[case[0]] = case[1];
        try testing.expectError(error.Corrupt, decode(testing.allocator, mutated));
    }
    // Well formed, but this kernel refuses editing a locked section.
    const locked = try encode(testing.allocator, .{ .sections = &.{
        .{ .op = .replace, .id = "metacodes:system", .text = "x" },
    } });
    defer testing.allocator.free(locked);
    try testing.expectError(error.Unsupported, decode(testing.allocator, locked));
}
