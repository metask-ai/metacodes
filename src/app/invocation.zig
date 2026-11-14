//! The command the user ran to start this process, for the messages that tell
//! them what to run next (#482). Installs side by side differ in launcher name
//! and state root (scripts/install.sh), so telling someone who ran
//! `metacodes-dev` to run `metacodes login` signs in another install.
//!
//! Argv[0] cannot tell installs apart: the launcher `metacodes install` writes
//! is a `/bin/sh` script that `exec`s `<prefix>/bin/metacodes`, so every
//! install starts as `…/bin/metacodes`. The launcher therefore exports its own
//! path (`$0`) as `METACODES_LAUNCHER` (install.zig `launcherBody`). Every
//! process a session starts inherits that variable, and it is not removed
//! (Zig 0.16 borrows the startup environment block; see core/auth.zig), so it
//! is believed only when the file it names is a launcher `metacodes install`
//! wrote that execs this very executable. A value left by another install's
//! launcher, or by one since removed, is ignored. Then comes argv[0] (a
//! symlink or copy under another name, a build run by its path), then
//! `metacodes`.
//!
//! Host-only: the CLI's messages ask; library code never does.

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const install = @import("install.zig");

const is_windows = builtin.os.tag == .windows;

/// The name a message uses when nothing better is known.
pub const default_command = "metacodes";

/// The largest file read as a launcher (`metacodes install` reads as much).
const max_launcher_bytes = 64 << 10;

/// What a process observes about how it was started. Every field is borrowed.
pub const Observed = struct {
    /// `METACODES_LAUNCHER`: the path of the launcher that ran it.
    launcher: ?[]const u8 = null,
    /// Argv[0]: the name or path it was run by.
    argv0: ?[]const u8 = null,
    /// Its own physical path (`platform.paths.selfExeRealPath`), which the
    /// launcher must exec to be believed.
    self_exe: ?[]const u8 = null,
};

/// The command to name: the launcher's, when that launcher execs `self_exe`;
/// else argv[0]'s; else `metacodes`. The result borrows from `observed` or is
/// static. `scratch` holds the launcher only while it is checked.
pub fn commandName(scratch: std.mem.Allocator, observed: Observed) []const u8 {
    if (observed.launcher) |launcher| if (nameOf(launcher)) |name| {
        if (observed.self_exe) |exe| if (launcherRuns(scratch, launcher, exe)) return name;
    };
    if (observed.argv0) |argv0| if (nameOf(argv0)) |name| return name;
    return default_command;
}

/// The command `path` names: its last component, without `.exe` or `.cmd` on
/// Windows. Null unless a shell reads it back as that one word: letters,
/// digits and `._+-`, not starting with `-` or `.`.
pub fn nameOf(path: []const u8) ?[]const u8 {
    var name = std.fs.path.basename(path);
    if (is_windows) for ([_][]const u8{ ".exe", ".cmd" }) |extension| {
        if (name.len > extension.len and std.ascii.endsWithIgnoreCase(name, extension)) {
            name = name[0 .. name.len - extension.len];
            break;
        }
    };
    if (name.len == 0 or name[0] == '-' or name[0] == '.') return null;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '+', '-' => {},
        else => return null,
    };
    return name;
}

/// Whether `launcher` is a launcher `metacodes install` wrote whose target is
/// `self_exe` (`install.launcherTarget`, any form it has written).
fn launcherRuns(scratch: std.mem.Allocator, launcher: []const u8, self_exe: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(scratch);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = readLauncher(arena, launcher) orelse return false;
    const target = (install.launcherTarget(arena, body) catch return false) orelse return false;
    if (std.mem.eql(u8, target, self_exe)) return true;
    // The installer writes the physical path; a directory on it that has
    // become a symlink since still leads here.
    const target_z = arena.dupeZ(u8, target) catch return false;
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = pfs.finalPath(target_z.ptr, &real_buf) orelse return false;
    return std.mem.eql(u8, std.mem.span(real), self_exe);
}

/// The bytes of `path` when it is a regular file of at most
/// `max_launcher_bytes`. Opened non-blocking, so a FIFO named by a stray
/// value is turned away instead of waited on.
fn readLauncher(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const path_z = arena.dupeZ(u8, path) catch return null;
    const flags: pfs.O = if (is_windows) .{ .ACCMODE = .RDONLY } else .{ .ACCMODE = .RDONLY, .NONBLOCK = true };
    const fd = pfs.open(path_z.ptr, flags, 0);
    if (fd < 0) return null;
    defer pfs.close(fd);
    const info = pfs.fileInfo(fd) catch return null;
    if (!info.is_regular or info.size > max_launcher_bytes) return null;
    const bytes = arena.alloc(u8, @intCast(info.size)) catch return null;
    var len: usize = 0;
    while (len < bytes.len) {
        const n = pfs.read(fd, bytes[len..]);
        if (n < 0) return null;
        if (n == 0) break;
        len += @intCast(n);
    }
    return bytes[0..len];
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "nameOf takes the last component and refuses what a shell would misread (#482)" {
    try testing.expectEqualStrings("metacodes", nameOf("metacodes").?);
    try testing.expectEqualStrings("metacodes-dev", nameOf("metacodes-dev").?);
    try testing.expectEqualStrings("metacodes-dev", nameOf("/Users/someone/.local/bin/metacodes-dev").?);
    try testing.expectEqualStrings("metacodes-dev-fix_482.b", nameOf("./metacodes-dev-fix_482.b").?);
    try testing.expectEqualStrings("metacodes", nameOf("/Users/someone/.local/opt/metacodes-dev/bin/metacodes").?);
    for ([_][]const u8{ "", "/", "-zsh", ".hidden", "my metacodes", "mc;rm", "mc$x", "mc`x`", "it's", "a\nb" }) |path| {
        try testing.expectEqual(@as(?[]const u8, null), nameOf(path));
    }
    if (is_windows) {
        try testing.expectEqualStrings("metacodes", nameOf("C:\\Users\\a b\\opt\\mc\\bin\\metacodes.exe").?);
        try testing.expectEqualStrings("mc", nameOf("C:\\Users\\a\\bin\\mc.CMD").?);
        try testing.expectEqual(@as(?[]const u8, null), nameOf(".exe"));
    }
}

test "commandName falls back from the launcher to argv[0] to metacodes (#482)" {
    const a = testing.allocator;
    try testing.expectEqualStrings("metacodes", commandName(a, .{}));
    try testing.expectEqualStrings("metacodes", commandName(a, .{ .argv0 = "" }));
    try testing.expectEqualStrings("metacodes", commandName(a, .{ .argv0 = "-sh" }));
    try testing.expectEqualStrings("metacodes-dev", commandName(a, .{ .argv0 = "/somewhere/bin/metacodes-dev" }));
    // A launcher that cannot be checked is not believed: nothing to read, or
    // nothing to check it against.
    try testing.expectEqualStrings("mc", commandName(a, .{ .launcher = "/no/such/launcher/metacodes-dev", .argv0 = "mc", .self_exe = "/no/such/bin/metacodes" }));
    try testing.expectEqualStrings("mc", commandName(a, .{ .launcher = "/no/such/launcher/metacodes-dev", .argv0 = "mc" }));
}

/// A tree with an executable at `prefix/bin/metacodes`, as an install has.
const Layout = struct {
    tmp: testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",

    fn init(self: *Layout) !void {
        self.tmp = testing.tmpDir(.{});
        try self.tmp.dir.createDirPath(testing.io, "prefix/bin");
        try self.tmp.dir.createDirPath(testing.io, "local/bin");
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "prefix/bin/metacodes", .data = "exe" });
        const len = try self.tmp.dir.realPath(testing.io, &self.root_buf);
        self.root = self.root_buf[0..len];
    }

    fn path(self: *const Layout, arena: std.mem.Allocator, sub_path: []const u8) ![]const u8 {
        return std.fs.path.join(arena, &.{ self.root, sub_path });
    }

    /// `local/bin/<name>`, written as `metacodes install` writes a launcher.
    fn launcher(self: *const Layout, arena: std.mem.Allocator, name: []const u8, executable: []const u8) ![]const u8 {
        const sub_path = try std.fs.path.join(arena, &.{ "local/bin", name });
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = try install.launcherBody(arena, executable) });
        return self.path(arena, sub_path);
    }
};

test "a launcher is believed only when it execs this executable (#482)" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var layout: Layout = .{ .tmp = undefined };
    try layout.init();
    defer layout.tmp.cleanup();
    const exe = try layout.path(arena, "prefix/bin/metacodes");

    // The dev launcher execs this executable, which starts as `…/bin/metacodes`.
    const dev = try layout.launcher(arena, "metacodes-dev", exe);
    try testing.expectEqualStrings("metacodes-dev", commandName(testing.allocator, .{ .launcher = dev, .argv0 = exe, .self_exe = exe }));
    // A form written before #482 names the same executable, so it counts too.
    try layout.tmp.dir.writeFile(testing.io, .{
        .sub_path = "local/bin/metacodes-old",
        .data = try std.fmt.allocPrint(arena, "#!/bin/sh\n# metacodes launcher written by `metacodes install`\nexec '{s}' \"$@\"\n", .{exe}),
    });
    try testing.expectEqualStrings("metacodes-old", commandName(testing.allocator, .{ .launcher = try layout.path(arena, "local/bin/metacodes-old"), .argv0 = exe, .self_exe = exe }));
    // Reached through a symlink, the launcher goes by the link's name: what was typed.
    try layout.tmp.dir.symLink(testing.io, dev, "local/bin/mcd", .{});
    try testing.expectEqualStrings("mcd", commandName(testing.allocator, .{ .launcher = try layout.path(arena, "local/bin/mcd"), .argv0 = exe, .self_exe = exe }));
    // A prefix reached through a directory that became a symlink after the
    // launcher was written still leads to this executable.
    try layout.tmp.dir.symLink(testing.io, try layout.path(arena, "prefix"), "alias", .{ .is_directory = true });
    const moved = try layout.launcher(arena, "metacodes-moved", try layout.path(arena, "alias/bin/metacodes"));
    try testing.expectEqualStrings("metacodes-moved", commandName(testing.allocator, .{ .launcher = moved, .argv0 = exe, .self_exe = exe }));

    // Inherited from another install's session: that launcher execs another
    // executable, so argv[0] decides.
    try layout.tmp.dir.createDirPath(testing.io, "other/bin");
    try layout.tmp.dir.writeFile(testing.io, .{ .sub_path = "other/bin/metacodes", .data = "other exe" });
    const other = try layout.launcher(arena, "metacodes-other", try layout.path(arena, "other/bin/metacodes"));
    try testing.expectEqualStrings("metacodes", commandName(testing.allocator, .{ .launcher = other, .argv0 = exe, .self_exe = exe }));
    // Not a launcher, or not a file at all.
    try layout.tmp.dir.writeFile(testing.io, .{ .sub_path = "local/bin/wrapper", .data = try std.fmt.allocPrint(arena, "#!/bin/sh\nexec '{s}' \"$@\"\n", .{exe}) });
    try testing.expectEqualStrings("metacodes", commandName(testing.allocator, .{ .launcher = try layout.path(arena, "local/bin/wrapper"), .argv0 = exe, .self_exe = exe }));
    try testing.expectEqualStrings("metacodes", commandName(testing.allocator, .{ .launcher = try layout.path(arena, "local/bin"), .argv0 = exe, .self_exe = exe }));
    try testing.expectEqualStrings("metacodes", commandName(testing.allocator, .{ .launcher = exe, .argv0 = exe, .self_exe = exe }));
    // A launcher whose name a shell would misread is not named.
    const odd = try layout.launcher(arena, "my metacodes", exe);
    try testing.expectEqualStrings("metacodes", commandName(testing.allocator, .{ .launcher = odd, .argv0 = exe, .self_exe = exe }));
}

/// mkfifo(3), which std does not declare.
const posix_test = if (is_windows) struct {} else struct {
    extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
};

test "a FIFO named as the launcher is turned away without waiting for a writer (#482)" {
    if (is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var layout: Layout = .{ .tmp = undefined };
    try layout.init();
    defer layout.tmp.cleanup();
    const exe = try layout.path(arena, "prefix/bin/metacodes");
    const fifo = try std.fmt.allocPrintSentinel(arena, "{s}/local/bin/metacodes-dev", .{layout.root}, 0);
    if (!is_windows) {
        if (posix_test.mkfifo(fifo.ptr, 0o600) != 0) return error.MkfifoFailed;
    }
    try testing.expectEqualStrings("metacodes", commandName(testing.allocator, .{ .launcher = fifo, .argv0 = exe, .self_exe = exe }));
}
