//! Processes that run from an install prefix, for `metacodes update`
//! (doc/UPDATE_DESIGN.md §6.2): each with its parent pid and physical
//! executable path, and the means to stop one.
//!
//! Matching is by the executable's physical path, which is exact; a command
//! line can name a prefix without running from it. The list is best effort:
//! processes of other users may be invisible (Linux hides their `exe` link),
//! and one that starts after the scan is not in it.
//!
//! - macOS: `proc_listallpids`, `proc_pidpath`, `proc_pidinfo(PROC_PIDT_SHORTBSDINFO)`.
//! - Linux: `/proc/<pid>/exe` (a replaced binary reads `<path> (deleted)`) and
//!   the parent field of `/proc/<pid>/stat`.
//! - Windows: a Toolhelp32 snapshot (which carries the parent pid) and
//!   `QueryFullProcessImageNameW`.

const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const is_windows = native_os == .windows;

pub const Pid = u32;

pub const Process = struct {
    pid: Pid,
    /// 0 when the platform does not say.
    ppid: Pid,
    /// The physical path of the executable image.
    exe: []const u8,
};

pub const Error = error{ Unsupported, ScanFailed, OutOfMemory };

/// Every visible process whose executable lies below `prefix` (a physical
/// path without a trailing separator). `arena` owns the result.
pub fn listUnder(arena: std.mem.Allocator, io: std.Io, prefix: []const u8) Error![]Process {
    var out: std.ArrayList(Process) = .empty;
    switch (native_os) {
        .macos => try listMacos(arena, prefix, &out),
        .linux => try listLinux(arena, io, prefix, &out),
        .windows => try listWindows(arena, prefix, &out),
        else => return error.Unsupported,
    }
    return out.items;
}

/// `exe` is a path strictly below `prefix`. Windows compares without regard
/// to case and to a `\\?\` prefix, as its file system does.
pub fn isUnder(prefix: []const u8, exe: []const u8) bool {
    const p = if (is_windows) stripVerbatim(prefix) else prefix;
    const e = if (is_windows) stripVerbatim(exe) else exe;
    if (e.len <= p.len + 1) return false;
    const head = e[0..p.len];
    const same = if (is_windows) std.ascii.eqlIgnoreCase(head, p) else std.mem.eql(u8, head, p);
    if (!same) return false;
    return e[p.len] == '/' or (is_windows and e[p.len] == '\\');
}

fn stripVerbatim(path: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, path, "\\\\?\\")) path[4..] else path;
}

/// The physical executable of `pid` now, or null when it is gone or not
/// visible. Callers re-check it right before `terminate`, so a pid reused
/// since the scan is never signalled.
pub fn exePath(arena: std.mem.Allocator, io: std.Io, pid: Pid) ?[]const u8 {
    return switch (native_os) {
        .macos => macosExe(arena, pid),
        .linux => linuxExe(arena, io, pid),
        .windows => windowsExe(arena, pid),
        else => null,
    };
}

/// Ask `pid` to exit: SIGTERM on POSIX. On Windows there is no such request
/// for a windowless process, so it is ended with `TerminateProcess`.
pub fn terminate(pid: Pid) error{ TerminateFailed, Unsupported }!void {
    if (is_windows) {
        const handle = OpenProcess(PROCESS_TERMINATE, 0, pid) orelse return error.TerminateFailed;
        defer std.os.windows.CloseHandle(handle);
        if (TerminateProcess(handle, 1) == 0) return error.TerminateFailed;
        return;
    }
    if (native_os != .macos and native_os != .linux) return error.Unsupported;
    std.posix.kill(@intCast(pid), .TERM) catch return error.TerminateFailed;
}

/// Whether `pid` still exists.
pub fn alive(pid: Pid) bool {
    if (is_windows) {
        const handle = OpenProcess(SYNCHRONIZE, 0, pid) orelse return false;
        defer std.os.windows.CloseHandle(handle);
        return WaitForSingleObject(handle, 0) == WAIT_TIMEOUT;
    }
    if (native_os == .linux) {
        // A zombie still answers kill(0); it has stopped running.
        var buf: [64]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "/proc/{d}/stat", .{pid}) catch return false;
        const fd = std.c.open(path, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return false;
        defer _ = std.c.close(fd);
        var stat_buf: [512]u8 = undefined;
        const n = std.c.read(fd, &stat_buf, stat_buf.len);
        if (n <= 0) return false;
        const fields = statFields(stat_buf[0..@intCast(n)]) orelse return true;
        return fields.state != 'Z' and fields.state != 'X';
    }
    if (native_os == .macos) {
        // A zombie still answers kill(0) until its parent reaps it, but
        // proc_pidinfo already fails for it with ESRCH (observed on macOS 26).
        var info: ProcBsdShortInfo = undefined;
        if (proc_pidinfo(@intCast(pid), PROC_PIDT_SHORTBSDINFO, 0, &info, @sizeOf(ProcBsdShortInfo)) == @sizeOf(ProcBsdShortInfo))
            return info.status != SZOMB;
        if (std.c.errno(@as(c_int, -1)) == .SRCH) return false;
    }
    std.posix.kill(@intCast(pid), @enumFromInt(0)) catch |err| return err == error.PermissionDenied;
    return true;
}

/// Whether a process other than this one has `path` open now. Windows cannot
/// tell this process's handles from another's, so there the caller asks while
/// holding none of its own. Best effort like `listUnder`: another user's
/// descriptors may be invisible, and an open after the scan is not in the
/// answer.
///
/// - macOS: `proc_listpidspath` (event-only watchers such as Spotlight's do
///   not count).
/// - Linux: any `/proc/<pid>/fd/<n>` whose link names the file. Only the link
///   is read, never the file it names, so a hung network mount cannot stall it.
/// - Windows: an open that shares nothing fails with a sharing violation.
pub fn heldOpenByOthers(path: [*:0]const u8) error{ Unsupported, ScanFailed }!bool {
    return switch (native_os) {
        .macos => heldOpenMacos(path),
        .linux => heldOpenLinux(path),
        .windows => heldOpenWindows(path),
        else => error.Unsupported,
    };
}

fn heldOpenMacos(path: [*:0]const u8) error{ScanFailed}!bool {
    if (native_os != .macos) return error.ScanFailed;
    const own: c_int = std.c.getpid();
    // A full buffer of other holders is already a yes.
    var pids: [256]c_int = undefined;
    const bytes = proc_listpidspath(PROC_ALL_PIDS, 0, path, PROC_LISTPIDSPATH_EXCLUDE_EVTONLY, &pids, @sizeOf(@TypeOf(pids)));
    if (bytes < 0) return error.ScanFailed;
    const count = @min(@as(usize, @intCast(bytes)) / @sizeOf(c_int), pids.len);
    for (pids[0..count]) |pid| if (pid > 0 and pid != own) return true;
    return false;
}

fn heldOpenLinux(path: [*:0]const u8) error{ScanFailed}!bool {
    if (native_os != .linux) return error.ScanFailed;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.mem.span(std.c.realpath(path, &target_buf) orelse return error.ScanFailed);
    const own: Pid = @intCast(std.c.getpid());
    const proc = std.c.opendir("/proc") orelse return error.ScanFailed;
    defer _ = std.c.closedir(proc);
    while (std.c.readdir(proc)) |entry| {
        const pid = std.fmt.parseInt(Pid, std.mem.sliceTo(&entry.name, 0), 10) catch continue;
        if (pid == own) continue;
        var dir_buf: [64]u8 = undefined;
        const fd_dir = std.fmt.bufPrintZ(&dir_buf, "/proc/{d}/fd", .{pid}) catch continue;
        // Another user's table, or a process that exited since the listing.
        const fds = std.c.opendir(fd_dir) orelse continue;
        defer _ = std.c.closedir(fds);
        while (std.c.readdir(fds)) |fd_entry| {
            const name = std.mem.sliceTo(&fd_entry.name, 0);
            if (name.len == 0 or name[0] == '.') continue;
            var link_buf: [96]u8 = undefined;
            const link = std.fmt.bufPrintZ(&link_buf, "/proc/{d}/fd/{s}", .{ pid, name }) catch continue;
            var named_buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = std.c.readlink(link, &named_buf, named_buf.len);
            if (n <= 0) continue;
            if (std.mem.eql(u8, named_buf[0..@intCast(n)], target)) return true;
        }
    }
    return false;
}

fn heldOpenWindows(path: [*:0]const u8) error{ScanFailed}!bool {
    if (!is_windows) return error.ScanFailed;
    const utf8 = std.mem.span(path);
    var wide: [win.PATH_MAX_WIDE + 1]u16 = undefined;
    if (utf8.len >= wide.len) return error.ScanFailed;
    const len = std.unicode.utf8ToUtf16Le(&wide, utf8) catch return error.ScanFailed;
    wide[len] = 0;
    const handle = CreateFileW(wide[0..len :0].ptr, GENERIC_READ, 0, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (handle == win.INVALID_HANDLE_VALUE) {
        return switch (GetLastError()) {
            ERROR_SHARING_VIOLATION => true,
            else => error.ScanFailed,
        };
    }
    win.CloseHandle(handle);
    return false;
}

// ── macOS ────────────────────────────────────────────────────────────────────

extern "c" fn proc_listpidspath(
    type: u32,
    typeinfo: u32,
    path: [*:0]const u8,
    pathflags: u32,
    buffer: ?*anyopaque,
    buffersize: c_int,
) c_int;
const PROC_ALL_PIDS: u32 = 1;
const PROC_LISTPIDSPATH_EXCLUDE_EVTONLY: u32 = 2;
extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_pidpath(pid: c_int, buffer: *anyopaque, buffersize: u32) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
const PROC_PIDT_SHORTBSDINFO: c_int = 13;
const SZOMB: u32 = 5;
const PROC_PIDPATHINFO_MAXSIZE = 4096;
const ProcBsdShortInfo = extern struct {
    pid: u32,
    ppid: u32,
    pgid: u32,
    status: u32,
    comm: [16]u8,
    flags: u32,
    uid: u32,
    gid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    rfu: u32,
};

fn listMacos(arena: std.mem.Allocator, prefix: []const u8, out: *std.ArrayList(Process)) Error!void {
    const estimate = proc_listallpids(null, 0);
    if (estimate <= 0) return error.ScanFailed;
    // Processes start between the two calls; leave room for them.
    const capacity: usize = @as(usize, @intCast(estimate)) + 256;
    const pids = try arena.alloc(c_int, capacity);
    const count = proc_listallpids(pids.ptr, @intCast(capacity * @sizeOf(c_int)));
    if (count <= 0) return error.ScanFailed;
    for (pids[0..@min(@as(usize, @intCast(count)), capacity)]) |pid| {
        if (pid <= 0) continue;
        const exe = macosExe(arena, @intCast(pid)) orelse continue;
        if (!isUnder(prefix, exe)) continue;
        var info: ProcBsdShortInfo = undefined;
        const got = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, @sizeOf(ProcBsdShortInfo));
        const ppid: Pid = if (got == @sizeOf(ProcBsdShortInfo)) info.ppid else 0;
        try out.append(arena, .{ .pid = @intCast(pid), .ppid = ppid, .exe = exe });
    }
}

fn macosExe(arena: std.mem.Allocator, pid: Pid) ?[]const u8 {
    if (native_os != .macos) return null;
    var buf: [PROC_PIDPATHINFO_MAXSIZE]u8 = undefined;
    const n = proc_pidpath(@intCast(pid), &buf, buf.len);
    if (n <= 0) return null;
    return arena.dupe(u8, buf[0..@intCast(n)]) catch null;
}

// ── Linux ────────────────────────────────────────────────────────────────────

fn listLinux(arena: std.mem.Allocator, io: std.Io, prefix: []const u8, out: *std.ArrayList(Process)) Error!void {
    var proc = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return error.ScanFailed;
    defer proc.close(io);
    var it = proc.iterate();
    while (it.next(io) catch return error.ScanFailed) |entry| {
        const pid = std.fmt.parseInt(Pid, entry.name, 10) catch continue;
        const exe = linuxExe(arena, io, pid) orelse continue;
        if (!isUnder(prefix, exe)) continue;
        var path_buf: [64]u8 = undefined;
        const stat_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch continue;
        var stat_buf: [512]u8 = undefined;
        const stat = std.Io.Dir.cwd().readFile(io, stat_path, &stat_buf) catch continue;
        const fields = statFields(stat) orelse continue;
        try out.append(arena, .{ .pid = pid, .ppid = fields.ppid, .exe = exe });
    }
}

fn linuxExe(arena: std.mem.Allocator, io: std.Io, pid: Pid) ?[]const u8 {
    if (native_os != .linux) return null;
    var path_buf: [64]u8 = undefined;
    const link = std.fmt.bufPrint(&path_buf, "/proc/{d}/exe", .{pid}) catch return null;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().readLink(io, link, &target_buf) catch return null;
    return arena.dupe(u8, withoutDeletedSuffix(target_buf[0..n])) catch null;
}

/// `/proc/<pid>/exe` of a process whose executable was replaced (renamed
/// over) reads `<old path> (deleted)`: it still runs from that prefix.
fn withoutDeletedSuffix(target: []const u8) []const u8 {
    const suffix = " (deleted)";
    return if (std.mem.endsWith(u8, target, suffix)) target[0 .. target.len - suffix.len] else target;
}

const StatFields = struct { state: u8, ppid: Pid };

/// `pid (comm) state ppid …`: the command may hold spaces and parentheses,
/// so the fields start after the last `)`.
fn statFields(stat: []const u8) ?StatFields {
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    const state = fields.next() orelse return null;
    const ppid = fields.next() orelse return null;
    if (state.len != 1) return null;
    return .{ .state = state[0], .ppid = std.fmt.parseInt(Pid, ppid, 10) catch return null };
}

// ── Windows ──────────────────────────────────────────────────────────────────

const win = std.os.windows;
const TH32CS_SNAPPROCESS: u32 = 0x00000002;
const PROCESS_TERMINATE: u32 = 0x0001;
const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
const SYNCHRONIZE: u32 = 0x00100000;
const WAIT_TIMEOUT: u32 = 0x102;
const ProcessEntry32W = extern struct {
    dwSize: u32,
    cntUsage: u32,
    th32ProcessID: u32,
    th32DefaultHeapID: usize,
    th32ModuleID: u32,
    cntThreads: u32,
    th32ParentProcessID: u32,
    pcPriClassBase: i32,
    dwFlags: u32,
    szExeFile: [260]u16,
};
extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: u32, th32ProcessID: u32) callconv(.winapi) win.HANDLE;
extern "kernel32" fn Process32FirstW(hSnapshot: win.HANDLE, lppe: *ProcessEntry32W) callconv(.winapi) c_int;
extern "kernel32" fn Process32NextW(hSnapshot: win.HANDLE, lppe: *ProcessEntry32W) callconv(.winapi) c_int;
extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: c_int, dwProcessId: u32) callconv(.winapi) ?win.HANDLE;
extern "kernel32" fn QueryFullProcessImageNameW(hProcess: win.HANDLE, dwFlags: u32, lpExeName: [*]u16, lpdwSize: *u32) callconv(.winapi) c_int;
extern "kernel32" fn TerminateProcess(hProcess: win.HANDLE, uExitCode: u32) callconv(.winapi) c_int;
extern "kernel32" fn WaitForSingleObject(hHandle: win.HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?win.HANDLE,
) callconv(.winapi) win.HANDLE;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
const GENERIC_READ: u32 = 0x8000_0000;
const OPEN_EXISTING: u32 = 3;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const ERROR_SHARING_VIOLATION: u32 = 32;

fn listWindows(arena: std.mem.Allocator, prefix: []const u8, out: *std.ArrayList(Process)) Error!void {
    if (!is_windows) return error.Unsupported;
    const snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == win.INVALID_HANDLE_VALUE) return error.ScanFailed;
    defer win.CloseHandle(snapshot);
    var entry: ProcessEntry32W = undefined;
    entry.dwSize = @sizeOf(ProcessEntry32W);
    if (Process32FirstW(snapshot, &entry) == 0) return error.ScanFailed;
    while (true) {
        if (entry.th32ProcessID != 0) {
            if (windowsExe(arena, entry.th32ProcessID)) |exe| {
                if (isUnder(prefix, exe)) try out.append(arena, .{
                    .pid = entry.th32ProcessID,
                    .ppid = entry.th32ParentProcessID,
                    .exe = exe,
                });
            }
        }
        entry.dwSize = @sizeOf(ProcessEntry32W);
        if (Process32NextW(snapshot, &entry) == 0) break;
    }
}

fn windowsExe(arena: std.mem.Allocator, pid: Pid) ?[]const u8 {
    if (!is_windows) return null;
    const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer win.CloseHandle(handle);
    var buf: [32768]u16 = undefined;
    var len: u32 = buf.len;
    if (QueryFullProcessImageNameW(handle, 0, &buf, &len) == 0) return null;
    return std.unicode.wtf16LeToWtf8Alloc(arena, buf[0..len]) catch null;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "isUnder: strictly below the prefix, at a separator" {
    try testing.expect(isUnder("/opt/mc", "/opt/mc/bin/metacodes"));
    try testing.expect(!isUnder("/opt/mc", "/opt/mc"));
    try testing.expect(!isUnder("/opt/mc", "/opt/mc/"));
    try testing.expect(!isUnder("/opt/mc", "/opt/mc-dev/bin/metacodes"));
    try testing.expect(!isUnder("/opt/mc", "/opt/m"));
    if (is_windows) {
        try testing.expect(isUnder("C:\\Programs\\mc", "c:\\programs\\MC\\bin\\metacodes.exe"));
        try testing.expect(isUnder("\\\\?\\C:\\Programs\\mc", "C:\\Programs\\mc\\bin\\metacodes.exe"));
    } else {
        try testing.expect(!isUnder("/opt/mc", "/OPT/MC/bin/metacodes"));
    }
}

test "statFields reads the state and parent after the last parenthesis" {
    const fields = statFields("4242 (tiny kgd (x)) S 4100 4242 4242 0 -1 4194560").?;
    try testing.expectEqual(@as(u8, 'S'), fields.state);
    try testing.expectEqual(@as(Pid, 4100), fields.ppid);
    try testing.expect(statFields("garbage") == null);
    try testing.expectEqualStrings("/opt/mc/bin/metacodes", withoutDeletedSuffix("/opt/mc/bin/metacodes (deleted)"));
    try testing.expectEqualStrings("/opt/mc/bin/metacodes", withoutDeletedSuffix("/opt/mc/bin/metacodes"));
}

test "listUnder finds a child running from a prefix, with its parent, and terminate stops it" {
    if (native_os != .macos and native_os != .linux and !is_windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A long-running system program, scanned for under the directory its
    // executable really lies in. That need not be the directory it is named
    // in: where coreutils are links to one multi-call binary (uutils, the
    // default on Ubuntu 26.04), `/bin/sleep` runs from
    // `/usr/lib/cargo/bin/coreutils`. It is still spawned as `/bin/sleep`,
    // the name that makes that binary act as sleep. (A copy in a temporary
    // prefix would not do: macOS kills a copied platform binary on exec.)
    const program: []const u8 = if (is_windows) "C:\\Windows\\System32\\PING.EXE" else "/bin/sleep";
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = real_buf[0..try std.Io.Dir.cwd().realPathFile(testing.io, program, &real_buf)];
    const prefix = std.fs.path.dirname(real).?;

    const argv: []const []const u8 = if (is_windows) &.{ program, "-n", "60", "127.0.0.1" } else &.{ program, "60" };
    var child = try std.process.spawn(testing.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(testing.io);
    const child_pid: Pid = @intCast(if (is_windows) GetProcessId(child.id.?) else child.id.?);

    // The child shows up once it has exec'd.
    var found: ?Process = null;
    var tries: usize = 0;
    while (found == null and tries < 100) : (tries += 1) {
        for (try listUnder(arena, testing.io, prefix)) |process| {
            if (process.pid == child_pid) found = process;
        }
        if (found == null) sleepMs(20);
    }
    const process = found orelse return error.TestUnexpectedResult;
    try testing.expect(isUnder(prefix, process.exe));
    const own_pid: Pid = if (is_windows) GetCurrentProcessId() else @intCast(std.c.getpid());
    try testing.expectEqual(own_pid, process.ppid);
    try testing.expect(isUnder(prefix, exePath(arena, testing.io, child_pid).?));
    // This test process does not run from there, nor from a sibling name.
    for (try listUnder(arena, testing.io, prefix)) |other| try testing.expect(other.pid != own_pid);
    const sibling = try std.fmt.allocPrint(arena, "{s}-not-it", .{prefix});
    for (try listUnder(arena, testing.io, sibling)) |other| try testing.expect(other.pid != child_pid);

    try testing.expect(alive(child_pid));
    try terminate(child_pid);
    // Not alive once it has stopped, even before its parent reaps it.
    var waited: usize = 0;
    while (alive(child_pid) and waited < 200) : (waited += 1) sleepMs(10);
    try testing.expect(!alive(child_pid));
    _ = try child.wait(testing.io);
    try testing.expect(!alive(child_pid));
}

test "heldOpenByOthers sees a child holding a file, not this process, and nobody once it exits" {
    if (native_os != .macos and native_os != .linux and !is_windows) return error.SkipZigTest;
    const pfs = @import("fs.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/marker", .{root}, 0);
    defer testing.allocator.free(path);
    const own = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
    try testing.expect(own >= 0);
    // POSIX leaves this process out; Windows cannot, and says so.
    try testing.expectEqual(is_windows, try heldOpenByOthers(path.ptr));
    pfs.close(own);
    try testing.expect(!try heldOpenByOthers(path.ptr));

    if (is_windows) return;
    // The marker of a process that is still running: a child keeps it open
    // across exec, as an older metacodes keeps its lease marker.
    var child = try std.process.spawn(testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "exec 3<\"$0\"; exec sleep 60", path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    var held = false;
    var tries: usize = 0;
    while (!held and tries < 200) : (tries += 1) {
        held = try heldOpenByOthers(path.ptr);
        if (!held) sleepMs(10);
    }
    try testing.expect(held);
    child.kill(testing.io);
    try testing.expect(!try heldOpenByOthers(path.ptr));
}

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetProcessId(Process: win.HANDLE) callconv(.winapi) u32;

extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

fn sleepMs(ms: u64) void {
    if (is_windows) {
        Sleep(@intCast(ms));
        return;
    }
    var req: std.c.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&req, null);
}
