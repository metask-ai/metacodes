//! Unpack a release archive for `metacodes update` (doc/UPDATE_DESIGN.md §4.2
//! step 6): a `.tar.gz` (macOS, Linux) or `.zip` (Windows) that holds one
//! top-level directory of regular files and directories, nothing else.
//!
//! `std.tar.extract` is not used: it creates symlink members with any target,
//! so a member `a -> /x` followed by `a/y` writes outside the destination.
//! Here every member is checked before anything is created for it — its kind,
//! its name, that it is not a duplicate, and that it lies under the single
//! root — and the totals are capped. The archive's SHA-256 has already been
//! checked against the release's sums, and the unit's manifest digests are
//! checked after this; these rules are what keeps a damaged or hostile
//! archive from writing anywhere but `dest` in between.

const std = @import("std");
const builtin = @import("builtin");

pub const Format = enum {
    tar_gz,
    zip,

    /// The format a release asset's name says it is.
    pub fn of(name: []const u8) ?Format {
        if (std.mem.endsWith(u8, name, ".tar.gz") or std.mem.endsWith(u8, name, ".tgz")) return .tar_gz;
        if (std.mem.endsWith(u8, name, ".zip")) return .zip;
        return null;
    }
};

pub const Limits = struct {
    max_members: usize = 20_000,
    /// Total size of the unpacked files.
    max_bytes: u64 = 2 << 30,
};

pub const Error = error{
    /// An absolute name, a drive letter or other `:`, `..`, `.`, an empty
    /// component, a backslash or a control character.
    UnsafeMember,
    /// A symlink, hard link, device, fifo or other non-regular member.
    UnsupportedMember,
    DuplicateMember,
    /// A member outside the single top-level directory, or one named
    /// otherwise than expected.
    NotOneRoot,
    EmptyArchive,
    TooManyMembers,
    TooLarge,
    CorruptArchive,
};

/// Which member an error is about, for the message.
pub const Report = struct {
    member: ?[]const u8 = null,
};

/// Unpack `archive_path` into `dest`, an existing empty directory. Returns the
/// root directory's name; with `expected_root` the root must have that name.
/// On an error the caller removes `dest`: what was unpacked so far is not a
/// unit.
///
/// Precondition: the archive's SHA-256 matched the release's sums. std's
/// inflater (Zig 0.16) is not hardened against damaged input — a truncated
/// gzip stream trips a safety check in `Decompress.decodeLength` instead of
/// returning an error — so only bytes the release vouches for may reach it.
pub fn extract(
    arena: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    format: Format,
    dest: []const u8,
    expected_root: ?[]const u8,
    limits: Limits,
    report: *Report,
) ![]const u8 {
    var dest_dir = try std.Io.Dir.cwd().openDir(io, dest, .{});
    defer dest_dir.close(io);
    var state: State = .{ .arena = arena, .limits = limits, .expected_root = expected_root, .report = report };
    switch (format) {
        .tar_gz => try extractTarGz(io, archive_path, dest_dir, &state),
        .zip => try extractZip(io, archive_path, dest_dir, &state),
    }
    return state.root orelse error.EmptyArchive;
}

const State = struct {
    arena: std.mem.Allocator,
    limits: Limits,
    expected_root: ?[]const u8,
    report: *Report,
    root: ?[]const u8 = null,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    members: usize = 0,
    bytes: u64 = 0,

    /// Admit one member: its name (without a trailing `/`) is safe, new, under
    /// the root, and within the totals. Returns the name to create.
    fn admit(self: *State, raw_name: []const u8, is_dir: bool, size: u64) ![]const u8 {
        self.report.member = raw_name;
        const name = if (is_dir) std.mem.trimEnd(u8, raw_name, "/") else raw_name;
        try checkName(name);
        self.members += 1;
        if (self.members > self.limits.max_members) return error.TooManyMembers;
        self.bytes +|= size;
        if (self.bytes > self.limits.max_bytes) return error.TooLarge;

        const first_end = std.mem.indexOfScalar(u8, name, '/') orelse name.len;
        const first = name[0..first_end];
        if (self.root) |root| {
            if (!std.mem.eql(u8, root, first)) return error.NotOneRoot;
        } else {
            if (self.expected_root) |expected| if (!std.mem.eql(u8, expected, first)) return error.NotOneRoot;
            self.root = try self.arena.dupe(u8, first);
        }
        // Only the root itself may be a directory at the top: a file there
        // would be the archive's whole content beside no directory.
        if (first_end == name.len and !is_dir) return error.NotOneRoot;

        const gop = try self.seen.getOrPut(self.arena, try self.arena.dupe(u8, name));
        if (gop.found_existing) return error.DuplicateMember;
        self.report.member = null;
        return name;
    }
};

/// A member name that can only mean a path below the destination, on every
/// platform the archive might be unpacked on.
fn checkName(name: []const u8) Error!void {
    if (name.len == 0 or name[0] == '/') return error.UnsafeMember;
    for (name) |c| {
        if (c < 0x20 or c == 0x7f or c == '\\' or c == ':') return error.UnsafeMember;
    }
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafeMember;
    }
}

fn extractTarGz(io: std.Io, archive_path: []const u8, dest: std.Io.Dir, state: *State) !void {
    var file = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, &window);

    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&gzip.reader, .{ .file_name_buffer = &name_buffer, .link_name_buffer = &link_buffer });
    var copy_buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const member = it.next() catch |err| return tarError(err, &file_reader, &gzip);
        const entry = member orelse break;
        switch (entry.kind) {
            .directory => {
                const name = try state.admit(entry.name, true, 0);
                try dest.createDirPath(io, name);
            },
            .file => {
                const name = try state.admit(entry.name, false, entry.size);
                if (std.fs.path.dirname(name)) |parent| try dest.createDirPath(io, parent);
                const executable = entry.mode & 0o100 != 0;
                var out = try dest.createFile(io, name, .{
                    .exclusive = true,
                    .permissions = if (executable) .executable_file else .default_file,
                });
                defer out.close(io);
                var writer = out.writer(io, &copy_buffer);
                it.streamRemaining(entry, &writer.interface) catch |err| switch (err) {
                    error.ReadFailed => return tarError(error.ReadFailed, &file_reader, &gzip),
                    error.WriteFailed => return writer.err.?,
                    error.EndOfStream => return error.CorruptArchive,
                };
                try writer.interface.flush();
            },
            .sym_link => {
                state.report.member = entry.name;
                return error.UnsupportedMember;
            },
        }
    }
    // Read the gzip stream to its end, so its length and CRC-32 are checked.
    _ = gzip.reader.discardRemaining() catch |err| return tarError(err, &file_reader, &gzip);
}

/// A tar or gzip failure, as this module names it: an I/O error of the file
/// stays what it is, a header std does not support is an unsupported member,
/// and anything else in the stream is corruption.
fn tarError(err: anyerror, file_reader: *std.Io.File.Reader, gzip: *std.compress.flate.Decompress) anyerror {
    return switch (err) {
        error.TarUnsupportedHeader => error.UnsupportedMember,
        error.ReadFailed => if (file_reader.err) |io_err| io_err else if (gzip.err != null) error.CorruptArchive else error.CorruptArchive,
        error.OutOfMemory => error.OutOfMemory,
        else => error.CorruptArchive,
    };
}

fn extractZip(io: std.Io, archive_path: []const u8, dest: std.Io.Dir, state: *State) !void {
    var file = try std.Io.Dir.cwd().openFile(io, archive_path, .{});
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;

    // Every member is admitted before the first one is written.
    {
        var it = std.zip.Iterator.init(&reader) catch return error.CorruptArchive;
        while (true) {
            const member = it.next() catch return error.CorruptArchive;
            const entry = member orelse break;
            if (entry.filename_len == 0 or entry.filename_len > name_buffer.len) return error.UnsafeMember;
            reader.seekTo(entry.header_zip_offset) catch return error.CorruptArchive;
            const header = reader.interface.takeStruct(std.zip.CentralDirectoryFileHeader, .little) catch return error.CorruptArchive;
            const name = name_buffer[0..entry.filename_len];
            reader.interface.readSliceAll(name) catch return error.CorruptArchive;
            const is_dir = name[name.len - 1] == '/';
            // A Unix-made member carries its mode in the high half: only
            // regular files and directories are accepted.
            if ((header.version_made_by >> 8) == 3) {
                const kind = (header.external_file_attributes >> 16) & 0o170000;
                const expected: u32 = if (is_dir) 0o040000 else 0o100000;
                if (kind != 0 and kind != expected) {
                    state.report.member = try state.arena.dupe(u8, name);
                    return error.UnsupportedMember;
                }
            }
            const owned = try state.arena.dupe(u8, name);
            _ = try state.admit(owned, is_dir, entry.uncompressed_size);
        }
    }
    var it = std.zip.Iterator.init(&reader) catch return error.CorruptArchive;
    while (true) {
        const member = it.next() catch return error.CorruptArchive;
        const entry = member orelse break;
        entry.extract(&reader, .{}, &name_buffer, dest) catch |err| {
            // std's own format errors are all named `Zip…`; a file system
            // error (a full disk) stays what it is.
            const name = @errorName(err);
            if (std.mem.startsWith(u8, name, "Zip") or err == error.UnsupportedCompressionMethod or err == error.EndOfStream)
                return error.CorruptArchive;
            return err;
        };
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const fixture = @import("archive_fixture.zig");

const Scratch = struct {
    tmp: testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    next: u32 = 0,

    fn init(self: *Scratch) !void {
        self.tmp = testing.tmpDir(.{});
        const len = try self.tmp.dir.realPath(testing.io, &self.root_buf);
        self.root = self.root_buf[0..len];
    }

    /// Write `bytes` as an archive, unpack it into a fresh `out-<n>/`.
    fn unpack(self: *Scratch, arena: std.mem.Allocator, format: Format, bytes: []const u8, expected_root: ?[]const u8, report: *Report) ![]const u8 {
        self.next += 1;
        const n = self.next;
        const archive_rel = try std.fmt.allocPrint(arena, "archive-{d}.{s}", .{ n, if (format == .zip) "zip" else "tar.gz" });
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = archive_rel, .data = bytes });
        const out_rel = try std.fmt.allocPrint(arena, "out-{d}", .{n});
        try self.tmp.dir.createDirPath(testing.io, out_rel);
        return extract(
            arena,
            testing.io,
            try std.fs.path.join(arena, &.{ self.root, archive_rel }),
            format,
            try std.fs.path.join(arena, &.{ self.root, out_rel }),
            expected_root,
            .{},
            report,
        );
    }
};

fn build(arena: std.mem.Allocator, format: Format, members: []const fixture.Member) ![]u8 {
    return switch (format) {
        .tar_gz => fixture.tarGz(arena, members),
        .zip => fixture.zip(arena, members),
    };
}

test "a release archive unpacks under its one root, keeping the executable bit (tar.gz and zip)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: Scratch = .{ .tmp = undefined };
    try scratch.init();
    defer scratch.tmp.cleanup();

    var tar_root: []const u8 = "";
    for ([_]Format{ .tar_gz, .zip }) |format| {
        const bytes = try build(arena, format, &.{
            .{ .name = "metacodes-1.2.3-x/", .kind = .directory },
            .{ .name = "metacodes-1.2.3-x/bin/", .kind = .directory },
            .{ .name = "metacodes-1.2.3-x/bin/metacodes", .kind = .executable, .data = "#!/bin/sh\n" },
            .{ .name = "metacodes-1.2.3-x/manifest.json", .data = "{}" },
            .{ .name = "metacodes-1.2.3-x/share/doc/README.md", .data = "readme" },
        });
        var report: Report = .{};
        const root = try scratch.unpack(arena, format, bytes, "metacodes-1.2.3-x", &report);
        try testing.expectEqualStrings("metacodes-1.2.3-x", root);
        if (format == .tar_gz) tar_root = try std.fmt.allocPrint(arena, "out-{d}/{s}", .{ scratch.next, root });
    }
    // Look inside the tar one.
    var dir = try scratch.tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "out-")) continue;
        const base = try std.fmt.allocPrint(arena, "{s}/metacodes-1.2.3-x", .{entry.name});
        const readme = try scratch.tmp.dir.readFileAlloc(testing.io, try std.fmt.allocPrint(arena, "{s}/share/doc/README.md", .{base}), arena, .limited(64));
        try testing.expectEqualStrings("readme", readme);
    }
    // The tar member's mode carries the executable bit (zip is unpacked on
    // Windows only, where there is none).
    if (builtin.os.tag != .windows) {
        const stat = try scratch.tmp.dir.statFile(testing.io, try std.fmt.allocPrint(arena, "{s}/bin/metacodes", .{tar_root}), .{});
        const manifest_stat = try scratch.tmp.dir.statFile(testing.io, try std.fmt.allocPrint(arena, "{s}/manifest.json", .{tar_root}), .{});
        try testing.expect(stat.permissions.toMode() & 0o100 != 0);
        try testing.expect(manifest_stat.permissions.toMode() & 0o100 == 0);
    }
}

test "a release archive with a member that could leave the destination is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: Scratch = .{ .tmp = undefined };
    try scratch.init();
    defer scratch.tmp.cleanup();

    const Case = struct {
        members: []const fixture.Member,
        err: anyerror,
        expected_root: ?[]const u8 = null,
        formats: []const Format = &.{ .tar_gz, .zip },
    };
    const cases = [_]Case{
        .{ .members = &.{ .{ .name = "r/", .kind = .directory }, .{ .name = "r/a", .kind = .symlink, .link = "/etc" } }, .err = error.UnsupportedMember },
        .{ .members = &.{ .{ .name = "r/", .kind = .directory }, .{ .name = "r/a", .kind = .hard_link, .link = "r/b" } }, .err = error.UnsupportedMember, .formats = &.{.tar_gz} },
        .{ .members = &.{ .{ .name = "r/", .kind = .directory }, .{ .name = "r/tty", .kind = .char_device } }, .err = error.UnsupportedMember, .formats = &.{.tar_gz} },
        .{ .members = &.{.{ .name = "r/../escape", .data = "x" }}, .err = error.UnsafeMember },
        .{ .members = &.{.{ .name = "/abs/file", .data = "x" }}, .err = error.UnsafeMember },
        .{ .members = &.{.{ .name = "r/C:/x", .data = "x" }}, .err = error.UnsafeMember },
        .{ .members = &.{.{ .name = "r/a\\b", .data = "x" }}, .err = error.UnsafeMember },
        .{ .members = &.{.{ .name = "r/./a", .data = "x" }}, .err = error.UnsafeMember },
        .{ .members = &.{.{ .name = "r//a", .data = "x" }}, .err = error.UnsafeMember },
        .{ .members = &.{.{ .name = "r/new\nline", .data = "x" }}, .err = error.UnsafeMember },
        .{ .members = &.{ .{ .name = "r/a", .data = "x" }, .{ .name = "r/a", .data = "y" } }, .err = error.DuplicateMember },
        .{ .members = &.{ .{ .name = "r/a", .data = "x" }, .{ .name = "s/b", .data = "y" } }, .err = error.NotOneRoot },
        .{ .members = &.{.{ .name = "loose-file", .data = "x" }}, .err = error.NotOneRoot },
        .{ .members = &.{.{ .name = "other/a", .data = "x" }}, .err = error.NotOneRoot, .expected_root = "r" },
        .{ .members = &.{}, .err = error.EmptyArchive },
    };
    for (cases, 0..) |case, index| for (case.formats) |format| {
        const bytes = try build(arena, format, case.members);
        var report: Report = .{};
        testing.expectError(case.err, scratch.unpack(arena, format, bytes, case.expected_root, &report)) catch |err| {
            std.debug.print("case {d} ({s}) did not fail with {s}\n", .{ index, @tagName(format), @errorName(case.err) });
            return err;
        };
    };
    // A symlink never reaches the disk, even as the first member.
    var report: Report = .{};
    try testing.expectError(error.UnsupportedMember, scratch.unpack(arena, .tar_gz, try fixture.tarGz(arena, &.{.{ .name = "r", .kind = .symlink, .link = "/" }}), null, &report));
    try testing.expectEqualStrings("r", report.member.?);
}

test "a release archive past the member or size limits, or a truncated zip, is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: Scratch = .{ .tmp = undefined };
    try scratch.init();
    defer scratch.tmp.cleanup();

    const members = [_]fixture.Member{
        .{ .name = "r/a", .data = "12345" },
        .{ .name = "r/b", .data = "67890" },
        .{ .name = "r/c", .data = "abcde" },
    };
    for ([_]Format{ .tar_gz, .zip }) |format| {
        const bytes = try build(arena, format, &members);
        const archive = try std.fs.path.join(arena, &.{ scratch.root, if (format == .zip) "limits.zip" else "limits.tar.gz" });
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = archive, .data = bytes });
        var report: Report = .{};
        try scratch.tmp.dir.createDirPath(testing.io, "lim-a");
        try testing.expectError(error.TooManyMembers, extract(arena, testing.io, archive, format, try std.fs.path.join(arena, &.{ scratch.root, "lim-a" }), null, .{ .max_members = 2 }, &report));
        try scratch.tmp.dir.deleteTree(testing.io, "lim-a");
        try scratch.tmp.dir.createDirPath(testing.io, "lim-b");
        try testing.expectError(error.TooLarge, extract(arena, testing.io, archive, format, try std.fs.path.join(arena, &.{ scratch.root, "lim-b" }), null, .{ .max_bytes = 14 }, &report));
        try scratch.tmp.dir.deleteTree(testing.io, "lim-b");

        // A truncated zip is refused. (A truncated gzip stream is not a case
        // this module can be given: see `extract`'s precondition.)
        if (format == .zip) {
            var truncated_report: Report = .{};
            try testing.expectError(error.CorruptArchive, scratch.unpack(arena, format, bytes[0 .. bytes.len - 12], null, &truncated_report));
        }
    }
}

test "Format.of names the release archive formats" {
    try testing.expectEqual(Format.tar_gz, Format.of("metacodes-1.0.0-aarch64-macos.tar.gz").?);
    try testing.expectEqual(Format.zip, Format.of("metacodes-1.0.0-x86_64-windows-gnu.zip").?);
    try testing.expect(Format.of("metacodes-1.0.0-SHA256SUMS") == null);
}
