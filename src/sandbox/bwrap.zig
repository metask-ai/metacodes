//! The Linux backend of the agent sandbox: bubblewrap (`bwrap`).
//!
//! It confines a command the way the macOS Seatbelt profile (profile.zig)
//! does, from the same `SandboxSettings`: everything readable, writes only
//! under the write roots, `denyWrite` and `denyRead` carved out on top.
//! Seatbelt filters by path; bwrap builds a mount namespace, so the mapping
//! is by mounts:
//!
//! | Setting                              | bwrap                                      |
//! |--------------------------------------|--------------------------------------------|
//! | everything readable, nothing written | `--ro-bind / /`                            |
//! | devices, /dev/fd, /dev/std*          | `--dev /dev` (fresh minimal devtmpfs)      |
//! | process view                         | `--unshare-pid --proc /proc`               |
//! | cwd, additional dirs, linked-worktree `.git`, `$TMPDIR`, `/tmp`, `/var/tmp`, `allowWrite` | `--bind P P`, P physical |
//! | `denyWrite`                          | `--ro-bind P P` after the write roots      |
//! | `denyRead` directory / file          | `--tmpfs P --remount-ro P` / `--ro-bind /dev/null P` |
//! | `network.allowedDomains`/`deniedDomains` set | `--unshare-net` (no per-host filter: fail closed) |
//! | TIOCSTI, leftover children           | `--new-session --die-with-parent`          |
//! | SysV IPC                             | `--unshare-ipc`                            |
//!
//! Every root is resolved physically (`pfs.finalPath`) before it is bound,
//! and the binds are fixed when the namespace is built, so a symlink (one in
//! a write root pointing out of it, or a root that is itself a link) never
//! widens the writable set: a write through it lands on whatever mount the
//! target lies in, read-only unless that target is itself a write root.
//!
//! Locating bwrap: `METACODES_BWRAP` when set (it must be absolute), else the
//! distribution paths `/usr/bin/bwrap` and `/bin/bwrap`. Never `PATH`: the
//! sandbox binary decides what "confined" means, so it must not be whatever
//! a repository or a shell profile puts first on the search path. Project
//! settings cannot name it either, for the same reason: a checked-in
//! `.claude/settings.json` could otherwise point at a fake bwrap that runs
//! every auto-allowed command bare.
//!
//! Availability is a cached one-shot probe per bwrap path: run `/bin/sh -c :`
//! under exactly the namespace flags and seccomp delivery the wrapper uses. A host that has bwrap
//! but forbids unprivileged user namespaces (a container, a hardened sysctl)
//! fails the probe and reports the sandbox unavailable, never "sandboxed".

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const pprocess = @import("platform").process;
const ppaths = @import("platform").paths;
const psync = @import("platform").sync;
const log = @import("../util/log.zig");
const seccomp = @import("seccomp.zig");

/// Distribution install paths, tried in order when `METACODES_BWRAP` is unset.
pub const default_paths = [_][:0]const u8{ "/usr/bin/bwrap", "/bin/bwrap" };

/// Why the backend can or cannot confine a command on this host.
pub const Availability = enum {
    available,
    /// Not Linux.
    unsupported_os,
    /// No reviewed syscall/audit-architecture policy for this ABI.
    unsupported_architecture,
    /// `METACODES_BWRAP` names a relative path.
    override_not_absolute,
    /// No regular file at `METACODES_BWRAP` or at any default path.
    missing,
    /// bwrap could not build the namespaces AND install the syscall filter.
    probe_failed,
};

/// What the sandboxed command may reach over the network.
pub const Network = seccomp.Network;

const PathBuf = [std.fs.max_path_bytes]u8;

pub const Located = union(enum) {
    path: [:0]const u8,
    override_not_absolute,
    missing,
};

/// The bwrap executable to use, written into `buf`.
pub fn locate(buf: *PathBuf) Located {
    if (ppaths.bwrapEnv()) |override| {
        if (!std.fs.path.isAbsolute(override)) return .override_not_absolute;
        const z = std.fmt.bufPrintZ(buf, "{s}", .{override}) catch return .missing;
        return if (isRegularFile(z)) .{ .path = z } else .missing;
    }
    for (default_paths) |candidate| {
        if (!isRegularFile(candidate)) continue;
        const z = std.fmt.bufPrintZ(buf, "{s}", .{candidate}) catch return .missing;
        return .{ .path = z };
    }
    return .missing;
}

fn isRegularFile(path: [:0]const u8) bool {
    const mode = pfs.statMode(path.ptr, true) orelse return false;
    return mode & 0o170000 == 0o100000;
}

/// Whether the backend can confine a command now. Locates bwrap on every
/// call (the override is read from the environment) and probes each path
/// once per process.
pub fn availability() Availability {
    if (builtin.os.tag != .linux) return .unsupported_os;
    if (!seccomp.supported()) return .unsupported_architecture;
    var buf: PathBuf = undefined;
    return switch (locate(&buf)) {
        .path => |path| probeCached(path),
        .override_not_absolute => .override_not_absolute,
        .missing => .missing,
    };
}

const CacheEntry = struct {
    path: PathBuf = undefined,
    len: usize = 0,
    result: Availability = .missing,
};
var cache_mutex: psync.Mutex = .{};
var cache: [4]CacheEntry = [_]CacheEntry{.{}} ** 4;
var cache_len: usize = 0;

fn probeCached(path: [:0]const u8) Availability {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    for (cache[0..cache_len]) |*entry| {
        if (std.mem.eql(u8, entry.path[0..entry.len], path)) return entry.result;
    }
    const result = probe(path);
    if (cache_len < cache.len) {
        const entry = &cache[cache_len];
        @memcpy(entry.path[0..path.len], path);
        entry.len = path.len;
        entry.result = result;
        cache_len += 1;
    }
    return result;
}

/// Namespace flags every wrapped command gets; the probe uses the same set
/// (with `--unshare-net`, the strictest), so "available" means these work.
const namespace_flags = [_][]const u8{ "--unshare-pid", "--unshare-ipc", "--new-session", "--die-with-parent" };

fn probe(path: [:0]const u8) Availability {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = [_][]const u8{
        path,            "--seccomp",     "9",                 "--ro-bind", "/",             "/",
        "--dev",         "/dev",          "--proc",            "/proc",     "--unshare-pid", "--unshare-ipc",
        "--unshare-net", "--new-session", "--die-with-parent", "--",        "/bin/sh",       "-c",
        ":",
    };
    const launched = seccomp.launchArgv(arena, .isolated, &raw) catch return .probe_failed;
    const argv = arena.alloc(?[*:0]const u8, launched.len + 1) catch return .probe_failed;
    for (launched, 0..) |arg, i| argv[i] = (arena.dupeZ(u8, arg) catch return .probe_failed).ptr;
    argv[launched.len] = null;
    const out = pprocess.capture(argv, std.heap.page_allocator, .{
        .timeout_ms = 10_000,
        .max_bytes = 4096,
    }) catch |err| {
        log.warn("sandbox", "bubblewrap probe of {s} could not run: {s}", .{ path, @errorName(err) });
        return .probe_failed;
    };
    defer std.heap.page_allocator.free(out.stdout);
    defer std.heap.page_allocator.free(out.stderr);
    if (out.exit_code == 0) return .available;
    log.warn("sandbox", "bubblewrap at {s} cannot create a sandbox (exit {d}): {s}", .{
        path,
        out.exit_code,
        std.mem.trim(u8, std.mem.sliceTo(out.stderr, '\n'), " \r"),
    });
    return .probe_failed;
}

/// What to confine a command to. Paths may be `~/`, absolute or relative
/// to `cwd`; they are resolved physically here.
pub const Request = struct {
    cwd: []const u8,
    home: []const u8 = "",
    allow_write: []const []const u8 = &.{},
    deny_write: []const []const u8 = &.{},
    deny_read: []const []const u8 = &.{},
    main_git_dir: ?[]const u8 = null,
    additional_dirs: []const []const u8 = &.{},
    network: Network = .shared,
    /// `$TMPDIR` of the caller; null = unset.
    tmpdir: ?[]const u8 = null,
};

/// Linux temp roots every sandboxed command may write, as Seatbelt allows
/// `/private/tmp` and `/private/var/folders`.
const temp_roots = [_][]const u8{ "/tmp", "/var/tmp" };

/// The shell a wrapped command runs in, as Seatbelt's `/bin/bash -c`.
pub fn shellPath() []const u8 {
    return if (pfs.exists("/bin/bash")) "/bin/bash" else "/bin/sh";
}

/// The launcher pipes BPF to `bwrap_path --seccomp 9 ... -- shell -c command`.
/// No temporary file or parent fd. Every element is owned by alloc.
pub fn buildArgv(
    alloc: std.mem.Allocator,
    bwrap_path: []const u8,
    shell: []const u8,
    req: Request,
    command: []const u8,
) error{ OutOfMemory, UnsupportedArchitecture }![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer {
        for (argv.items) |a| alloc.free(a);
        argv.deinit(alloc);
    }
    var writable: std.ArrayList([]const u8) = .empty;
    defer {
        for (writable.items) |p| alloc.free(p);
        writable.deinit(alloc);
    }

    try push(alloc, &argv, &.{ bwrap_path, "--seccomp", "9", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc" });

    // Write roots, physical and deduplicated.
    try addWritable(alloc, &writable, req, req.cwd);
    for (req.additional_dirs) |d| try addWritable(alloc, &writable, req, d);
    if (req.main_git_dir) |g| try addWritable(alloc, &writable, req, g);
    if (req.tmpdir) |t| try addWritable(alloc, &writable, req, t);
    for (temp_roots) |t| try addWritable(alloc, &writable, req, t);
    for (req.allow_write) |p| try addWritable(alloc, &writable, req, p);
    for (writable.items) |p| try push(alloc, &argv, &.{ "--bind", p, p });

    // denyWrite over the write roots. A path that does not exist yet cannot
    // be bound; if it lies in a write root, its nearest existing ancestor is
    // made read-only instead (Seatbelt refuses the create; so must we).
    for (req.deny_write) |raw| {
        const expanded = try expand(alloc, raw, req);
        defer alloc.free(expanded);
        if (try physical(alloc, expanded)) |p| {
            defer alloc.free(p);
            try push(alloc, &argv, &.{ "--ro-bind", p, p });
            continue;
        }
        const ancestor = (try nearestExisting(alloc, expanded)) orelse continue;
        defer alloc.free(ancestor);
        if (!withinAny(writable.items, ancestor)) continue; // already read-only
        log.warn("sandbox", "denyWrite {s} does not exist; {s} is read-only for this command instead", .{ raw, ancestor });
        try push(alloc, &argv, &.{ "--ro-bind", ancestor, ancestor });
    }

    // denyRead last, so nothing bound above shows through. A path that does
    // not exist has nothing to read.
    for (req.deny_read) |raw| {
        const expanded = try expand(alloc, raw, req);
        defer alloc.free(expanded);
        const p = (try physical(alloc, expanded)) orelse continue;
        defer alloc.free(p);
        var zbuf: PathBuf = undefined;
        const pz = std.fmt.bufPrintZ(&zbuf, "{s}", .{p}) catch continue;
        const mode = pfs.statMode(pz.ptr, true) orelse continue;
        if (mode & 0o170000 == 0o040000) {
            try push(alloc, &argv, &.{ "--tmpfs", p, "--remount-ro", p });
        } else {
            try push(alloc, &argv, &.{ "--ro-bind", "/dev/null", p });
        }
    }

    try push(alloc, &argv, &namespace_flags);
    if (req.network == .isolated) try push(alloc, &argv, &.{"--unshare-net"});
    // A relative cwd ("." when the caller has none) is where bwrap already is.
    if (std.fs.path.isAbsolute(req.cwd)) try push(alloc, &argv, &.{ "--chdir", req.cwd });
    try push(alloc, &argv, &.{ "--", shell, "-c", command });
    return seccomp.launchArgv(alloc, req.network, argv.items);
}

fn push(alloc: std.mem.Allocator, argv: *std.ArrayList([]const u8), items: []const []const u8) error{OutOfMemory}!void {
    for (items) |item| {
        const owned = try alloc.dupe(u8, item);
        argv.append(alloc, owned) catch |err| {
            alloc.free(owned);
            return err;
        };
    }
}

fn addWritable(alloc: std.mem.Allocator, writable: *std.ArrayList([]const u8), req: Request, raw: []const u8) error{OutOfMemory}!void {
    const expanded = try expand(alloc, raw, req);
    defer alloc.free(expanded);
    // A missing root cannot be bound, and has nothing to write into.
    const p = (try physical(alloc, expanded)) orelse return;
    for (writable.items) |existing| {
        if (std.mem.eql(u8, existing, p)) {
            alloc.free(p);
            return;
        }
    }
    writable.append(alloc, p) catch |err| {
        alloc.free(p);
        return err;
    };
}

/// `~` / `~/x` against `home`, a relative path against `cwd`.
fn expand(alloc: std.mem.Allocator, raw: []const u8, req: Request) error{OutOfMemory}![]u8 {
    if (req.home.len > 0) {
        if (std.mem.eql(u8, raw, "~")) return alloc.dupe(u8, req.home);
        if (std.mem.startsWith(u8, raw, "~/")) return std.fmt.allocPrint(alloc, "{s}/{s}", .{ req.home, raw[2..] });
    }
    if (std.fs.path.isAbsolute(raw) or std.mem.eql(u8, raw, req.cwd)) return alloc.dupe(u8, raw);
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ req.cwd, raw });
}

/// The physical path of an existing `path`; null when it does not exist.
fn physical(alloc: std.mem.Allocator, path: []const u8) error{OutOfMemory}!?[]u8 {
    var zbuf: PathBuf = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return null;
    var out: PathBuf = undefined;
    const resolved = pfs.finalPath(z.ptr, &out) orelse return null;
    return try alloc.dupe(u8, std.mem.span(resolved));
}

/// The physical form of the deepest existing ancestor of `path`.
fn nearestExisting(alloc: std.mem.Allocator, path: []const u8) error{OutOfMemory}!?[]u8 {
    var current = path;
    while (std.fs.path.dirname(current)) |parent| {
        if (try physical(alloc, parent)) |p| return p;
        if (parent.len == current.len) break;
        current = parent;
    }
    return null;
}

fn withinAny(roots: []const []const u8, path: []const u8) bool {
    for (roots) |root| if (within(root, path)) return true;
    return false;
}

/// `path` is `root` or below it, on a separator boundary.
fn within(root: []const u8, path: []const u8) bool {
    if (root.len == 0 or !std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    if (root[root.len - 1] == '/') return true;
    return path[root.len] == '/';
}

/// A bwrap child killed by signal N makes bwrap exit 128+N (bwrap cannot
/// die of the same signal itself). Map that back to the negative-signal
/// convention of `platform.process` exit codes.
pub fn decodeExit(code: i32) i32 {
    if (code > 128 and code <= 128 + 64) return -(code - 128);
    return code;
}

// ============================================================================
// Tests (argv mapping; the behaviour is proven against real bwrap in exec.zig)
// ============================================================================

const testing = std.testing;

fn indexOfSeq(argv: []const []const u8, seq: []const []const u8) ?usize {
    if (seq.len > argv.len) return null;
    var i: usize = 0;
    while (i + seq.len <= argv.len) : (i += 1) {
        var all = true;
        for (seq, 0..) |s, j| {
            if (!std.mem.eql(u8, argv[i + j], s)) {
                all = false;
                break;
            }
        }
        if (all) return i;
    }
    return null;
}

fn freeArgv(alloc: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |a| alloc.free(a);
    alloc.free(argv);
}

test "bwrap argv: read-only root, physical write roots, carve-outs after them, command last" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: PathBuf = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    try tmp.dir.createDirPath(testing.io, "ws/secret");
    try tmp.dir.createDirPath(testing.io, "extra");
    try tmp.dir.createDirPath(testing.io, "home/.ssh");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/.env", .data = "K=V\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "home/.netrc", .data = "x\n" });
    // A symlinked additional directory is bound at its target.
    try tmp.dir.symLink(testing.io, "extra", "extra-link", .{ .is_directory = true });

    const ws = try std.fmt.allocPrint(alloc, "{s}/ws", .{root});
    defer alloc.free(ws);
    const home = try std.fmt.allocPrint(alloc, "{s}/home", .{root});
    defer alloc.free(home);
    const link = try std.fmt.allocPrint(alloc, "{s}/extra-link", .{root});
    defer alloc.free(link);
    const extra = try std.fmt.allocPrint(alloc, "{s}/extra", .{root});
    defer alloc.free(extra);
    const env_file = try std.fmt.allocPrint(alloc, "{s}/ws/.env", .{root});
    defer alloc.free(env_file);
    const ssh = try std.fmt.allocPrint(alloc, "{s}/home/.ssh", .{root});
    defer alloc.free(ssh);
    const netrc = try std.fmt.allocPrint(alloc, "{s}/home/.netrc", .{root});
    defer alloc.free(netrc);

    const argv = try buildArgv(alloc, "/usr/bin/bwrap", "/bin/bash", .{
        .cwd = ws,
        .home = home,
        .additional_dirs = &.{link},
        .deny_write = &.{".env"},
        .deny_read = &.{ "~/.ssh", "~/.netrc", "~/missing" },
        .allow_write = &.{"~/does-not-exist"},
    }, "echo hi");
    defer freeArgv(alloc, argv);

    try testing.expectEqualStrings("/bin/sh", argv[0]);
    try testing.expect(indexOfSeq(argv, &.{ "/usr/bin/bwrap", "--seccomp", "9" }) != null);
    try testing.expect(indexOfSeq(argv, &.{ "--ro-bind", "/", "/" }) != null);
    try testing.expect(indexOfSeq(argv, &.{ "--dev", "/dev" }) != null);
    try testing.expect(indexOfSeq(argv, &.{ "--proc", "/proc" }) != null);
    const ws_bind = indexOfSeq(argv, &.{ "--bind", ws, ws }).?;
    try testing.expect(indexOfSeq(argv, &.{ "--bind", extra, extra }) != null);
    try testing.expect(indexOfSeq(argv, &.{ "--bind", link, link }) == null);
    var tmp_buf: PathBuf = undefined;
    const physical_tmp = std.mem.span(pfs.realpath("/tmp", &tmp_buf) orelse return error.PathResolutionFailed);
    try testing.expect(indexOfSeq(argv, &.{ "--bind", physical_tmp, physical_tmp }) != null);
    const deny_w = indexOfSeq(argv, &.{ "--ro-bind", env_file, env_file }).?;
    const deny_r = indexOfSeq(argv, &.{ "--tmpfs", ssh, "--remount-ro", ssh }).?;
    try testing.expect(indexOfSeq(argv, &.{ "--ro-bind", "/dev/null", netrc }) != null);
    try testing.expect(ws_bind < deny_w and deny_w < deny_r);
    for (argv) |a| try testing.expect(std.mem.indexOf(u8, a, "does-not-exist") == null);
    for (argv) |a| try testing.expect(std.mem.indexOf(u8, a, "missing") == null);
    try testing.expect(indexOfSeq(argv, &namespace_flags) != null);
    try testing.expect(indexOfSeq(argv, &.{"--unshare-net"}) == null);
    try testing.expect(indexOfSeq(argv, &.{ "--chdir", ws }) != null);
    try testing.expectEqual(argv.len - 4, indexOfSeq(argv, &.{ "--", "/bin/bash", "-c", "echo hi" }).?);
}

test "bwrap argv: an isolated network unshares it; a missing denyWrite locks its ancestor" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: PathBuf = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    try tmp.dir.createDirPath(testing.io, "ws/build");
    const ws = try std.fmt.allocPrint(alloc, "{s}/ws", .{root});
    defer alloc.free(ws);
    const build = try std.fmt.allocPrint(alloc, "{s}/ws/build", .{root});
    defer alloc.free(build);

    const argv = try buildArgv(alloc, "/b", "/bin/sh", .{
        .cwd = ws,
        .deny_write = &.{"build/not-yet/out.bin"},
        .network = .isolated,
    }, "true");
    defer freeArgv(alloc, argv);
    try testing.expect(indexOfSeq(argv, &.{"--unshare-net"}) != null);
    try testing.expect(indexOfSeq(argv, &.{ "--ro-bind", build, build }) != null);
}

test "decodeExit maps bwrap's 128+N back to a signal" {
    try testing.expectEqual(@as(i32, 7), decodeExit(7));
    try testing.expectEqual(@as(i32, -9), decodeExit(137));
    try testing.expectEqual(@as(i32, -15), decodeExit(143));
    try testing.expectEqual(@as(i32, 128), decodeExit(128));
    try testing.expectEqual(@as(i32, 255), decodeExit(255));
}
