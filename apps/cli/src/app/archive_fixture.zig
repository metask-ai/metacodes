//! Release archives for tests: `.tar.gz` through std's tar writer and gzip
//! compressor, `.zip` written by hand (stored, no compression), plus raw tar
//! headers for the member kinds std's writer cannot produce. Used by the
//! unpacker's and the updater's tests; nothing in the product calls it.

const std = @import("std");

pub const Kind = enum { file, executable, directory, symlink, hard_link, char_device };

pub const Member = struct {
    name: []const u8,
    kind: Kind = .file,
    data: []const u8 = "",
    /// Symlink and hard-link target.
    link: []const u8 = "",
};

/// The bytes of a gzip-compressed tar archive holding `members` in order.
pub fn tarGz(arena: std.mem.Allocator, members: []const Member) ![]u8 {
    var tar_bytes: std.Io.Writer.Allocating = .init(arena);
    var tar: std.tar.Writer = .{ .underlying_writer = &tar_bytes.writer };
    for (members) |member| switch (member.kind) {
        .file => try tar.writeFileBytes(member.name, member.data, .{ .mode = 0o644 }),
        .executable => try tar.writeFileBytes(member.name, member.data, .{ .mode = 0o755 }),
        .directory => try tar.writeDir(member.name, .{ .mode = 0o755 }),
        .symlink => try tar.writeLink(member.name, member.link, .{ .mode = 0o777 }),
        .hard_link => try writeRawHeader(&tar_bytes.writer, member.name, '1', member.link),
        .char_device => try writeRawHeader(&tar_bytes.writer, member.name, '3', ""),
    };
    try tar.finishPedantically();

    var gz_bytes: std.Io.Writer.Allocating = try .initCapacity(arena, 64);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var compress: std.compress.flate.Compress = try .init(&gz_bytes.writer, window, .gzip, .default);
    try compress.writer.writeAll(tar_bytes.written());
    try compress.finish();
    return gz_bytes.written();
}

/// A ustar header with no data, for member kinds `std.tar.Writer` has no
/// call for (hard links, devices).
fn writeRawHeader(w: *std.Io.Writer, name: []const u8, typeflag: u8, link: []const u8) !void {
    var header = [_]u8{0} ** 512;
    @memcpy(header[0..name.len], name);
    @memcpy(header[100..107], "0000644");
    @memcpy(header[108..115], "0000000");
    @memcpy(header[116..123], "0000000");
    @memcpy(header[124..135], "00000000000");
    @memcpy(header[136..147], "00000000000");
    header[156] = typeflag;
    @memcpy(header[157..][0..link.len], link);
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");
    @memset(header[148..156], ' ');
    var sum: u32 = 0;
    for (header) |byte| sum += byte;
    _ = try std.fmt.bufPrint(header[148..155], "{o:0>6}\x00", .{sum});
    try w.writeAll(&header);
}

/// The bytes of a zip archive holding `members`, stored without
/// compression. Directories end in `/`; a symlink is marked the way Info-ZIP
/// marks one (Unix mode in the high half of the external attributes).
pub fn zip(arena: std.mem.Allocator, members: []const Member) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    const Central = struct { name: []const u8, crc: u32, size: u32, offset: u32, mode: u32 };
    var central: std.ArrayList(Central) = .empty;
    for (members) |member| {
        const data: []const u8 = switch (member.kind) {
            .symlink => member.link,
            .directory => "",
            else => member.data,
        };
        const mode: u32 = switch (member.kind) {
            .directory => 0o040755,
            .symlink => 0o120777,
            .executable => 0o100755,
            else => 0o100644,
        };
        const crc = std.hash.Crc32.hash(data);
        const offset: u32 = @intCast(out.written().len);
        try w.writeAll("PK\x03\x04");
        try w.writeInt(u16, 20, .little); // version needed
        try w.writeInt(u16, 0, .little); // flags
        try w.writeInt(u16, 0, .little); // stored
        try w.writeInt(u16, 0, .little); // time
        try w.writeInt(u16, 0x21, .little); // date (1980-01-01)
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, @intCast(data.len), .little);
        try w.writeInt(u32, @intCast(data.len), .little);
        try w.writeInt(u16, @intCast(member.name.len), .little);
        try w.writeInt(u16, 0, .little); // extra
        try w.writeAll(member.name);
        try w.writeAll(data);
        try central.append(arena, .{ .name = member.name, .crc = crc, .size = @intCast(data.len), .offset = offset, .mode = mode });
    }
    const cd_offset: u32 = @intCast(out.written().len);
    for (central.items) |entry| {
        try w.writeAll("PK\x01\x02");
        try w.writeInt(u16, (3 << 8) | 20, .little); // made by: Unix
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0x21, .little);
        try w.writeInt(u32, entry.crc, .little);
        try w.writeInt(u32, entry.size, .little);
        try w.writeInt(u32, entry.size, .little);
        try w.writeInt(u16, @intCast(entry.name.len), .little);
        try w.writeInt(u16, 0, .little); // extra
        try w.writeInt(u16, 0, .little); // comment
        try w.writeInt(u16, 0, .little); // disk
        try w.writeInt(u16, 0, .little); // internal attributes
        try w.writeInt(u32, entry.mode << 16, .little);
        try w.writeInt(u32, entry.offset, .little);
        try w.writeAll(entry.name);
    }
    const cd_size: u32 = @as(u32, @intCast(out.written().len)) - cd_offset;
    try w.writeAll("PK\x05\x06");
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, @intCast(central.items.len), .little);
    try w.writeInt(u16, @intCast(central.items.len), .little);
    try w.writeInt(u32, cd_size, .little);
    try w.writeInt(u32, cd_offset, .little);
    try w.writeInt(u16, 0, .little);
    return out.written();
}
