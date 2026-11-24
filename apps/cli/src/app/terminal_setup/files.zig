//! The few whole-file operations terminal setup needs, through `platform/fs`
//! (UTF-8 paths reach the same file on Windows as the wide-character checks).

const std = @import("std");
const pfs = @import("metacodes-internal").platform.fs;
const util_fs = @import("metacodes-internal").util.fs;

pub const Error = error{ OutOfMemory, NotFound, ReadFailed, WriteFailed, TooLarge, PathTooLong };

/// Every file this module reads is a small configuration file; a larger one is
/// not the file it expects.
pub const max_bytes: usize = 4 << 20;

fn pathZ(buf: *[std.fs.max_path_bytes:0]u8, path: []const u8) error{PathTooLong}![*:0]const u8 {
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0].ptr;
}

pub fn exists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    return pfs.exists(pathZ(&buf, path) catch return false);
}

/// The whole file (owned by `gpa`); `error.NotFound` when there is none.
pub fn read(gpa: std.mem.Allocator, path: []const u8) Error![]u8 {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const fd = pfs.openReadShared(try pathZ(&buf, path));
    if (fd < 0) return if (pfs.lastErrnoIs(.NOENT)) error.NotFound else error.ReadFailed;
    defer pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &chunk);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        if (out.items.len + @as(usize, @intCast(n)) > max_bytes) return error.TooLarge;
        try out.appendSlice(gpa, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(gpa);
}

/// Writes `bytes` to `path` through a temporary file in the same directory and
/// a rename, so a reader (VS Code watches `keybindings.json`) sees the old file
/// or the new one, never half of one. Creates missing parent directories only
/// when `make_parents` (the backup directory); a configuration file is written
/// only where its directory already exists.
pub fn writeAtomic(path: []const u8, bytes: []const u8, make_parents: bool) Error!void {
    if (make_parents) if (std.fs.path.dirname(path)) |dir| util_fs.mkdirParents(dir) catch return error.WriteFailed;
    var tmp_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}.metacodes-tmp", .{path}) catch return error.PathTooLong;
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const path_z = try pathZ(&path_buf, path);
    pfs.unlinkPath(tmp.ptr) catch {};
    const fd = pfs.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o644);
    if (fd < 0) return error.WriteFailed;
    if (!pfs.writeAll(fd, bytes)) {
        pfs.close(fd);
        pfs.unlinkPath(tmp.ptr) catch {};
        return error.WriteFailed;
    }
    pfs.fsyncChecked(fd) catch {
        pfs.close(fd);
        pfs.unlinkPath(tmp.ptr) catch {};
        return error.WriteFailed;
    };
    pfs.close(fd); // closed before the rename (Windows replace semantics)
    if (pfs.renameReplace(tmp.ptr, path_z) != 0) {
        pfs.unlinkPath(tmp.ptr) catch {};
        return error.WriteFailed;
    }
}

/// What a configuration file's path is on disk. A symbolic link is common for
/// dotfiles (home-manager links into the Nix store, stow and chezmoi into a
/// repository); `writeAtomic` on the link itself would replace it with a plain
/// file, so callers write the file it resolves to instead.
pub const Link = union(enum) {
    /// The path is the file itself (or nothing yet).
    none,
    /// A symbolic link: the file it resolves to.
    to: []const u8,
    /// A symbolic link to nothing.
    dangling,
};

pub fn link(arena: std.mem.Allocator, path: []const u8) error{OutOfMemory}!Link {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const z = pathZ(&buf, path) catch return .none;
    if (!pfs.isSymlink(z)) return .none;
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const real = pfs.finalPath(z, &out) orelse return .dangling;
    return .{ .to = try arena.dupe(u8, std.mem.span(real)) };
}

pub fn remove(path: []const u8) void {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    pfs.unlinkPath(pathZ(&buf, path) catch return) catch {};
}

/// `<dir>/<stem>-<UTC YYYYMMDD-HHMMSS><ext>`, with `-2`, `-3`, … before the
/// extension when a backup of that second exists already (owned by `gpa`).
pub fn freshName(gpa: std.mem.Allocator, dir: []const u8, stem: []const u8, ext: []const u8, unix_seconds: i64) error{OutOfMemory}![]u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(unix_seconds, 0)) };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const secs = epoch.getDaySeconds();
    var stamp_buf: [32]u8 = undefined;
    const stamp = std.fmt.bufPrint(&stamp_buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        day.year,               month_day.month.numeric(), month_day.day_index + 1,
        secs.getHoursIntoDay(), secs.getMinutesIntoHour(), secs.getSecondsIntoMinute(),
    }) catch unreachable;
    var n: usize = 1;
    while (true) : (n += 1) {
        const name = if (n == 1)
            try std.fmt.allocPrint(gpa, "{s}-{s}{s}", .{ stem, stamp, ext })
        else
            try std.fmt.allocPrint(gpa, "{s}-{s}-{d}{s}", .{ stem, stamp, n, ext });
        defer gpa.free(name);
        const full = try std.fs.path.join(gpa, &.{ dir, name });
        if (!exists(full)) return full;
        gpa.free(full);
    }
}

const testing = std.testing;

test "files: read, atomic write over an existing file, and a fresh backup name" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];

    const file = try std.fs.path.join(gpa, &.{ root, "keybindings.json" });
    defer gpa.free(file);
    try testing.expectError(error.NotFound, read(gpa, file));
    try writeAtomic(file, "[1]", false);
    try writeAtomic(file, "[2]", false);
    const got = try read(gpa, file);
    defer gpa.free(got);
    try testing.expectEqualStrings("[2]", got);
    // No temporary file is left behind.
    const tmp_name = try std.fmt.allocPrint(gpa, "{s}.metacodes-tmp", .{file});
    defer gpa.free(tmp_name);
    try testing.expect(!exists(tmp_name));

    // A configuration file is not written into a directory that does not exist;
    // a backup creates its directory.
    const nested = try std.fs.path.join(gpa, &.{ root, "missing", "User", "keybindings.json" });
    defer gpa.free(nested);
    try testing.expectError(error.WriteFailed, writeAtomic(nested, "[]", false));
    const backups = try std.fs.path.join(gpa, &.{ root, "state", "terminal-setup" });
    defer gpa.free(backups);
    // 2026-10-29 02:15:34 UTC.
    const first = try freshName(gpa, backups, "keybindings", ".json", 1_793_240_134);
    defer gpa.free(first);
    try testing.expect(std.mem.endsWith(u8, first, "keybindings-20261029-021534.json"));
    try writeAtomic(first, "backup", true);
    const second = try freshName(gpa, backups, "keybindings", ".json", 1_793_240_134);
    defer gpa.free(second);
    try testing.expect(std.mem.endsWith(u8, second, "keybindings-20261029-021534-2.json"));
}

test "files: link tells a plain file, a symbolic link and a dangling one apart" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "real.json", .data = "[]" });
    try @import("metacodes-internal").platform.test_support.symlinkOrSkip(tmp.dir, testing.io, "real.json", "link.json", .{});
    try @import("metacodes-internal").platform.test_support.symlinkOrSkip(tmp.dir, testing.io, "missing.json", "dangling.json", .{});

    try testing.expect(try link(arena, try std.fs.path.join(arena, &.{ root, "real.json" })) == .none);
    try testing.expect(try link(arena, try std.fs.path.join(arena, &.{ root, "nothing.json" })) == .none);
    try testing.expect(try link(arena, try std.fs.path.join(arena, &.{ root, "dangling.json" })) == .dangling);
    const to = (try link(arena, try std.fs.path.join(arena, &.{ root, "link.json" }))).to;
    try testing.expect(std.mem.endsWith(u8, to, "real.json"));
    // Writing the resolved file keeps the link a link.
    try writeAtomic(to, "[1]", false);
    const via_link = try read(arena, try std.fs.path.join(arena, &.{ root, "link.json" }));
    try testing.expectEqualStrings("[1]", via_link);
    var lbuf: [std.fs.max_path_bytes:0]u8 = undefined;
    try testing.expect(pfs.isSymlink(try pathZ(&lbuf, try std.fs.path.join(arena, &.{ root, "link.json" }))));
}
