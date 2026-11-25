//! Native filesystem executor. The agent stays outside the OS sandbox; each
//! open (and Write's mkdir -p) runs in a tiny confined process. SCM_RIGHTS
//! transfers that exact open file description back for existing fd-based
//! read_state, exact recovery, mutation observations, and rendering.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const pfs = platform.fs;
const exec = @import("exec.zig");
const protocol = @import("filesystem_helper.zig");
const ToolContext = @import("../tools/context.zig").ToolContext;
const read_state = @import("../core/read_state.zig");

pub fn enabled(ctx: *const ToolContext) bool {
    return if (ctx.sandbox) |sb| sb.enabled else false;
}

/// Filesystem tools have no excluded-command or unsandboxed escape hatch.
/// An explicitly enabled sandbox must produce a wrapper on every platform.
pub fn wrap(ctx: *const ToolContext, command: []const u8) !exec.WrappedCommand {
    var strict = (ctx.sandbox orelse return error.SandboxUnavailable).*;
    strict.fail_if_unavailable = true;
    strict.excluded_commands = &.{};
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = if (ctx.cwd_abs.len != 0) ctx.cwd_abs else pfs.getCwd(&cwd_buf) orelse return error.SandboxUnavailable;
    return switch (try exec.wrapCommand(ctx.allocator, command, .{
        .cwd = cwd,
        .home = ctx.home_dir,
        .sandbox = &strict,
        .additional_dirs = ctx.additional_dirs,
    })) {
        .wrapped => |wrapped| wrapped,
        .unavailable, .passthrough => error.SandboxUnavailable,
    };
}

/// Shell serialization is only for the existing sandbox wrapper's command
/// interface. Every argument is quoted independently, including executable
/// paths; request paths and flags travel over IPC, never in shell source.
pub fn wrapArgv(ctx: *const ToolContext, argv: []const ?[*:0]const u8) !?SearchCommand {
    if (!enabled(ctx)) return null;
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(ctx.allocator);
    try command.appendSlice(ctx.allocator, "exec");
    for (argv, 0..) |maybe, i| {
        const arg = maybe orelse break;
        const raw = std.mem.span(arg);
        // Development ripgrep can be a repo-relative bundled binary. The
        // sandbox changes cwd, so freeze its executable path before wrapping.
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const absolute = if (i == 0 and !std.fs.path.isAbsolute(raw))
            try std.fs.path.resolve(ctx.allocator, &.{ pfs.getCwd(&cwd_buf) orelse return error.SandboxUnavailable, raw })
        else
            null;
        defer if (absolute) |path| ctx.allocator.free(path);
        const value = absolute orelse raw;
        const quoted = try shellQuote(ctx.allocator, value);
        defer ctx.allocator.free(quoted);
        try command.append(ctx.allocator, ' ');
        try command.appendSlice(ctx.allocator, quoted);
    }
    var wrapped = try wrap(ctx, command.items);
    errdefer wrapped.deinit();
    const result = try ctx.allocator.alloc(?[*:0]const u8, wrapped.argv.len + 1);
    @memset(result, null);
    errdefer {
        for (result) |arg| if (arg) |z| ctx.allocator.free(std.mem.span(z));
        ctx.allocator.free(result);
    }
    for (wrapped.argv, 0..) |arg, i| result[i] = (try ctx.allocator.dupeZ(u8, arg)).ptr;
    return .{ .wrapped = wrapped, .argv = result, .allocator = ctx.allocator };
}

pub const SearchCommand = struct {
    wrapped: exec.WrappedCommand,
    argv: []?[*:0]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SearchCommand) void {
        for (self.argv) |arg| if (arg) |z| self.allocator.free(std.mem.span(z));
        self.allocator.free(self.argv);
        self.wrapped.deinit();
    }
};

/// Only a host environment override or the physical executable's installed
/// sibling can select this security-sensitive executable. No PATH/config.
pub fn helperPath(allocator: std.mem.Allocator) ![]u8 {
    const env = try platform.paths.environment(allocator);
    defer {
        for (env) |entry| allocator.free(entry);
        allocator.free(env);
    }
    for (env) |entry| {
        const prefix = "METACODES_SANDBOX_HELPER=";
        if (!std.mem.startsWith(u8, entry, prefix)) continue;
        const value = entry[prefix.len..];
        if (!std.fs.path.isAbsolute(value)) return error.SandboxHelperUnavailable;
        return allocator.dupe(u8, value);
    }
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = platform.paths.selfExeRealPath(&exe_buf) orelse return error.SandboxHelperUnavailable;
    const dir = std.fs.path.dirname(exe_path) orelse return error.SandboxHelperUnavailable;
    return std.fs.path.join(allocator, &.{ dir, "metacodes-fs-helper" });
}

pub fn open(ctx: *const ToolContext, path: []const u8, flags: pfs.O, mode: c_uint, mkdir_parents: bool) anyerror!pfs.Fd {
    if (!enabled(ctx)) {
        if (mkdir_parents) try @import("../util/fs.zig").mkdirParentsOf(path);
        return pfs.openZ(path, flags, mode);
    }
    if (comptime !protocol.supported) return error.SandboxUnavailable;
    const allocator = ctx.allocator;
    const helper = try helperPath(allocator);
    defer allocator.free(helper);
    const quoted = try shellQuote(allocator, helper);
    defer allocator.free(quoted);
    const command = try std.fmt.allocPrint(allocator, "exec {s}", .{quoted});
    defer allocator.free(command);
    var wrapped = try wrap(ctx, command);
    defer wrapped.deinit();
    const argv = try allocator.alloc(?[*:0]const u8, wrapped.argv.len + 1);
    @memset(argv, null);
    defer {
        for (argv) |arg| if (arg) |z| allocator.free(std.mem.span(z));
        allocator.free(argv);
    }
    for (wrapped.argv, 0..) |arg, i| argv[i] = (try allocator.dupeZ(u8, arg)).ptr;

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = if (ctx.cwd_abs.len != 0) ctx.cwd_abs else pfs.getCwd(&cwd_buf) orelse return error.SandboxUnavailable;
    const absolute = try std.fs.path.resolve(allocator, &.{ cwd, path });
    defer allocator.free(absolute);
    // Prepare all memory and environment before fork: the child only makes
    // async-signal-safe syscalls, even when called by an AgentCore host thread.
    const env = try platform.paths.environment(allocator);
    defer {
        for (env) |entry| allocator.free(entry);
        allocator.free(env);
    }
    const envp = try allocator.allocSentinel(?[*:0]const u8, env.len, null);
    defer allocator.free(envp);
    for (env, 0..) |entry, i| envp[i] = entry.ptr;

    platform.process.forkSerialLock();
    var locked = true;
    defer if (locked) platform.process.forkSerialUnlock();
    var pair: [2]c_int = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair) != 0) return error.SandboxHelperUnavailable;
    defer _ = std.c.close(pair[0]);
    var child_socket: ?c_int = pair[1];
    defer if (child_socket) |fd| {
        _ = std.c.close(fd);
    };
    // Protect callers with closed stdin/stdout/stderr from dup2 aliasing.
    for (&pair, 0..) |*fd, i| {
        if (fd.* < 3) {
            const raised = std.c.fcntl(fd.*, std.c.F.DUPFD, @as(c_int, 3));
            if (raised < 0) return error.SandboxHelperUnavailable;
            _ = std.c.close(fd.*);
            fd.* = raised;
            if (i == 1) child_socket = raised;
        }
        try pfs.makeCloseOnExec(fd.*);
        if (builtin.os.tag == .macos) {
            const yes: c_int = 1;
            if (std.c.setsockopt(fd.*, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &yes, @sizeOf(c_int)) != 0)
                return error.SandboxHelperUnavailable;
        }
    }
    var null_fd = pfs.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (null_fd < 0) return error.SandboxHelperUnavailable;
    defer _ = std.c.close(null_fd);
    // Lifting the sockets can leave a stdio slot free again. Keep the null
    // source above stdio too, so dup2(socket, 0) cannot replace that source.
    if (null_fd < 3) {
        const raised = std.c.fcntl(null_fd, std.c.F.DUPFD, @as(c_int, 3));
        if (raised < 0) return error.SandboxHelperUnavailable;
        _ = std.c.close(null_fd);
        null_fd = raised;
    }
    try pfs.makeCloseOnExec(null_fd);
    const pid = if (builtin.os.tag == .macos)
        try spawnDarwinHelper(argv, envp, pair[1], null_fd)
    else blk: {
        const child = std.c.fork();
        if (child < 0) return error.SandboxHelperUnavailable;
        if (child == 0) {
            _ = std.c.setpgid(0, 0);
            if (std.c.dup2(pair[1], 0) < 0 or std.c.dup2(null_fd, 1) < 0 or std.c.dup2(null_fd, 2) < 0) std.c._exit(127);
            // A sandbox must not inherit unsandboxed directory/file descriptors
            // from its host. Keep only the private socket and null output streams.
            if (std.os.linux.syscall3(.close_range, 3, std.math.maxInt(u32), 0) != 0) std.c._exit(127);
            _ = std.c.execve(argv[0].?, @ptrCast(argv.ptr), envp.ptr);
            std.c._exit(127);
        }
        break :blk child;
    };
    _ = std.c.close(pair[1]);
    child_socket = null;
    platform.process.forkSerialUnlock();
    locked = false;
    // Always bound wrapper/helper lifetime, including protocol/startup failure.
    defer {
        _ = std.c.kill(-pid, std.c.SIG.KILL);
        _ = std.c.kill(pid, std.c.SIG.KILL);
        var status: c_int = 0;
        while (std.c.waitpid(pid, &status, 0) < 0 and pfs.lastErrnoIs(.INTR)) {}
    }
    try protocol.sendRequest(pair[0], .{ .path = absolute, .flags = flags, .mode = mode, .mkdir_parents = mkdir_parents });
    // Darwin has no MSG_CMSG_CLOEXEC. Serialize receive+fcntl against every
    // production fork so an authorized descriptor cannot leak to another tool.
    try protocol.wait(pair[0], std.c.POLL.IN);
    platform.process.forkSerialLock();
    defer platform.process.forkSerialUnlock();
    return protocol.receiveResponse(pair[0]);
}

// Darwin has no closefrom. POSIX_SPAWN_CLOEXEC_DEFAULT closes unmentioned
// descriptors in the kernel, including descriptors above a lowered rlimit.
// The explicit dup2 actions retain only the private channel and null outputs.
// Opaque handles and flags follow the macOS SDK's spawn.h and sys/spawn.h.
const DarwinSpawn = struct {
    const Handle = ?*anyopaque;
    extern "c" fn posix_spawnattr_init(attr: *Handle) c_int;
    extern "c" fn posix_spawnattr_destroy(attr: *Handle) c_int;
    extern "c" fn posix_spawnattr_setflags(attr: *Handle, flags: c_short) c_int;
    extern "c" fn posix_spawnattr_setpgroup(attr: *Handle, group: std.c.pid_t) c_int;
    extern "c" fn posix_spawn_file_actions_init(actions: *Handle) c_int;
    extern "c" fn posix_spawn_file_actions_destroy(actions: *Handle) c_int;
    extern "c" fn posix_spawn_file_actions_adddup2(actions: *Handle, source: c_int, target: c_int) c_int;
    extern "c" fn posix_spawn(pid: *std.c.pid_t, path: [*:0]const u8, actions: *const Handle, attr: *const Handle, argv: [*]const ?[*:0]const u8, envp: [*]const ?[*:0]const u8) c_int;
};

fn spawnDarwinHelper(argv: []const ?[*:0]const u8, envp: []const ?[*:0]const u8, channel: c_int, null_fd: c_int) error{SandboxHelperUnavailable}!std.c.pid_t {
    var actions: DarwinSpawn.Handle = null;
    if (DarwinSpawn.posix_spawn_file_actions_init(&actions) != 0) return error.SandboxHelperUnavailable;
    defer _ = DarwinSpawn.posix_spawn_file_actions_destroy(&actions);
    var attr: DarwinSpawn.Handle = null;
    if (DarwinSpawn.posix_spawnattr_init(&attr) != 0) return error.SandboxHelperUnavailable;
    defer _ = DarwinSpawn.posix_spawnattr_destroy(&attr);
    const close_unmentioned_and_set_group: c_short = 0x4000 | 0x0002;
    if (DarwinSpawn.posix_spawnattr_setflags(&attr, close_unmentioned_and_set_group) != 0 or
        DarwinSpawn.posix_spawnattr_setpgroup(&attr, 0) != 0 or
        DarwinSpawn.posix_spawn_file_actions_adddup2(&actions, channel, 0) != 0 or
        DarwinSpawn.posix_spawn_file_actions_adddup2(&actions, null_fd, 1) != 0 or
        DarwinSpawn.posix_spawn_file_actions_adddup2(&actions, null_fd, 2) != 0)
        return error.SandboxHelperUnavailable;
    var pid: std.c.pid_t = undefined;
    if (DarwinSpawn.posix_spawn(&pid, argv[0].?, &actions, &attr, argv.ptr, envp.ptr) != 0) return error.SandboxHelperUnavailable;
    return pid;
}

test "native filesystem sandbox: Darwin helper spawn drops unmentioned host descriptors" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    platform.process.forkSerialLock();
    defer platform.process.forkSerialUnlock();
    const null_fd = pfs.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    try std.testing.expect(null_fd >= 0);
    defer _ = std.c.close(null_fd);
    // Deliberately not CLOEXEC and high enough to avoid loader/shell fd reuse.
    const host_fd = std.c.fcntl(null_fd, std.c.F.DUPFD, @as(c_int, 200));
    try std.testing.expect(host_fd >= 200);
    defer _ = std.c.close(host_fd);
    var channel: [2]c_int = undefined;
    try std.testing.expect(std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &channel) == 0);
    defer _ = std.c.close(channel[0]);
    defer _ = std.c.close(channel[1]);
    try pfs.makeCloseOnExec(channel[0]);
    try pfs.makeCloseOnExec(channel[1]);
    var command_buffer: [128]u8 = undefined;
    const command = try std.fmt.bufPrintZ(&command_buffer, "test ! -e /dev/fd/{d}", .{host_fd});
    const argv = [_]?[*:0]const u8{ "/bin/sh", "-c", command.ptr, null };
    const envp = [_]?[*:0]const u8{null};
    const pid = try spawnDarwinHelper(&argv, &envp, channel[1], null_fd);
    var status: c_int = 0;
    while (std.c.waitpid(pid, &status, 0) < 0) {
        if (!pfs.lastErrnoIs(.INTR)) return error.WaitFailed;
    }
    try std.testing.expectEqual(@as(c_int, 0), status);
}

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidSandboxPath;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, byte);
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

/// Staleness checks must use the same confined open path as the mutation.
pub fn statPath(ctx: *const ToolContext, path: []const u8) !read_state.StatInfo {
    if (!enabled(ctx)) return read_state.statPath(path);
    const fd = try open(ctx, path, .{ .ACCMODE = .RDONLY }, 0, false);
    defer _ = pfs.close(fd);
    return read_state.statFd(fd);
}

pub fn hashFileContent(ctx: *const ToolContext, path: []const u8) !u64 {
    if (!enabled(ctx)) return read_state.hashFileContent(path);
    const fd = try open(ctx, path, .{ .ACCMODE = .RDONLY }, 0, false);
    defer _ = pfs.close(fd);
    var hash = std.hash.Wyhash.init(0);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = try pfs.readZ(fd, &buf);
        if (n == 0) break;
        hash.update(buf[0..n]);
    }
    return hash.final();
}

/// What `denyRead` hides, for a path that can no longer be asked of the
/// sandbox: a file deleted or moved away since, so there is nothing at the
/// path for `open` to refuse. Both backends hide a denied path and all below
/// it (Seatbelt `subpath`; bubblewrap binds `/dev/null` over a file and a
/// tmpfs over a directory), each in its own resolution of the configured
/// path: `~` expanded, then the realpath from this process (Seatbelt) or the
/// path joined to the command's directory, physical when it exists
/// (bubblewrap). Build it when the command starts, as the backends resolve
/// theirs: a denied file the command deletes resolves no more.
///
/// It decides alone for paths that are gone, so it errs wide: it also keeps
/// the unresolved forms, and on macOS, whose volumes usually ignore case,
/// compares ASCII letters without it.
pub const ReadDenied = struct {
    allocator: std.mem.Allocator,
    prefixes: [][]u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, ctx: *const ToolContext) error{OutOfMemory}!ReadDenied {
        const sb = ctx.sandbox orelse return .{ .allocator = allocator };
        if (!sb.enabled) return .{ .allocator = allocator };
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |p| allocator.free(p);
            list.deinit(allocator);
        }
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = if (ctx.cwd_abs.len != 0) ctx.cwd_abs else pfs.getCwd(&cwd_buf) orelse "";
        for (sb.deny_read) |raw| {
            const expanded = try expandHome(allocator, raw, ctx.home_dir);
            defer allocator.free(expanded);
            try appendPhysical(allocator, &list, expanded);
            if (!std.fs.path.isAbsolute(expanded) and cwd.len == 0) continue;
            const anchored = try std.fs.path.resolve(allocator, &.{ cwd, expanded });
            {
                errdefer allocator.free(anchored);
                try list.append(allocator, anchored);
            }
            try appendPhysical(allocator, &list, anchored);
        }
        return .{ .allocator = allocator, .prefixes = try list.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *ReadDenied) void {
        for (self.prefixes) |p| self.allocator.free(p);
        self.allocator.free(self.prefixes);
        self.* = undefined;
    }

    /// `path` (absolute) is a denied path or below one.
    pub fn covers(self: *const ReadDenied, path: []const u8) bool {
        for (self.prefixes) |prefix| if (within(prefix, path)) return true;
        return false;
    }

    fn within(prefix: []const u8, path: []const u8) bool {
        if (prefix.len == 0 or path.len < prefix.len) return false;
        const head = path[0..prefix.len];
        const same = if (builtin.os.tag == .macos) std.ascii.eqlIgnoreCase(head, prefix) else std.mem.eql(u8, head, prefix);
        if (!same) return false;
        return path.len == prefix.len or prefix[prefix.len - 1] == '/' or path[prefix.len] == '/';
    }

    fn expandHome(allocator: std.mem.Allocator, raw: []const u8, home: []const u8) error{OutOfMemory}![]u8 {
        if (home.len > 0) {
            if (std.mem.eql(u8, raw, "~")) return allocator.dupe(u8, home);
            if (std.mem.startsWith(u8, raw, "~/")) return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, raw[2..] });
        }
        return allocator.dupe(u8, raw);
    }

    fn appendPhysical(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), path: []const u8) error{OutOfMemory}!void {
        var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{path}) catch return;
        var out: [std.fs.max_path_bytes + 1]u8 = undefined;
        const resolved = pfs.finalPath(z.ptr, &out) orelse return;
        const owned = try allocator.dupe(u8, std.mem.span(resolved));
        errdefer allocator.free(owned);
        try list.append(allocator, owned);
    }
};

test "ReadDenied covers a denied path and below it, in every form a backend resolves it to" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no sandbox backend
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    try tmp.dir.createDirPath(std.testing.io, "real");
    try tmp.dir.symLink(std.testing.io, "real", "link", .{ .is_directory = true });
    try tmp.dir.createDirPath(std.testing.io, "real2");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real2/f.txt", .data = "" });
    try tmp.dir.symLink(std.testing.io, "real2", "link2", .{ .is_directory = true });
    var buf: [6][std.fs.max_path_bytes]u8 = undefined;
    const p = struct {
        fn at(b: *[std.fs.max_path_bytes]u8, base: []const u8, rel: []const u8) []const u8 {
            return std.fmt.bufPrint(b, "{s}/{s}", .{ base, rel }) catch unreachable;
        }
    }.at;

    const deny = [_][]const u8{
        p(&buf[0], root, "secret"), // absolute
        "~/token.env", // under home
        "rel.key", // relative to the command's directory
        p(&buf[1], root, "link"), // through a symlink: matched physically too
        // Relative and through a symlink: bubblewrap binds the physical path
        // under the command's directory, which is not this process's.
        "link2/f.txt",
    };
    var sb: @import("config.zig").SandboxSettings = .{ .enabled = true, .deny_read = &deny };
    var ctx = ToolContext.simple(allocator);
    ctx.cwd_abs = root;
    ctx.home_dir = root;
    ctx.sandbox = &sb;
    var denied = try ReadDenied.init(allocator, &ctx);
    defer denied.deinit();

    for ([_][]const u8{ "secret", "secret/a/b.txt", "token.env", "rel.key", "link/x", "real/x", "link2/f.txt", "real2/f.txt" }) |rel|
        try std.testing.expect(denied.covers(p(&buf[2], root, rel)));
    for ([_][]const u8{ "secretx", "secret.txt", "token.envx", "other/rel.key", "realx", "real2/g.txt" }) |rel|
        try std.testing.expect(!denied.covers(p(&buf[3], root, rel)));
    // Seatbelt matches on volumes that ignore case; the comparison does too.
    try std.testing.expectEqual(builtin.os.tag == .macos, denied.covers(p(&buf[4], root, "SECRET/a")));

    sb.enabled = false;
    var off = try ReadDenied.init(allocator, &ctx);
    defer off.deinit();
    try std.testing.expect(!off.covers(p(&buf[5], root, "secret")));
}

const TestFixture = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    workspace: []u8,
    outside: []u8,

    fn init() !TestFixture {
        if (!protocol.supported or !exec.hostSupported()) return error.SkipZigTest;
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(std.testing.io, &root_buf);
        const root = try allocator.dupe(u8, root_buf[0..len]);
        errdefer allocator.free(root);
        const workspace = try std.fs.path.join(allocator, &.{ root, "workspace" });
        errdefer allocator.free(workspace);
        const outside = try std.fs.path.join(allocator, &.{ root, "outside" });
        errdefer allocator.free(outside);
        try @import("../util/fs.zig").mkdirParents(workspace);
        try @import("../util/fs.zig").mkdirParents(outside);
        return .{ .tmp = tmp, .root = root, .workspace = workspace, .outside = outside };
    }

    fn deinit(self: *TestFixture) void {
        const allocator = std.testing.allocator;
        allocator.free(self.root);
        allocator.free(self.workspace);
        allocator.free(self.outside);
        self.tmp.cleanup();
    }

    fn path(self: *const TestFixture, rel: []const u8) ![]u8 {
        return std.fs.path.join(std.testing.allocator, &.{ self.root, rel });
    }

    fn write(file_path: []const u8, bytes: []const u8) !void {
        const fd = try pfs.openZ(file_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        defer _ = pfs.close(fd);
        try std.testing.expect(pfs.writeAll(fd, bytes));
    }

    fn expectBytes(file_path: []const u8, expected: []const u8) !void {
        const fd = try pfs.openZ(file_path, .{ .ACCMODE = .RDONLY }, 0);
        defer _ = pfs.close(fd);
        const bytes = try @import("../tools/common.zig").readAllFromFdCapped(fd, std.testing.allocator, 4096);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualStrings(expected, bytes);
    }

    fn context(self: *const TestFixture, sb: *const @import("config.zig").SandboxSettings) ToolContext {
        var ctx = ToolContext.simple(std.testing.allocator);
        ctx.cwd_abs = self.workspace;
        ctx.resolve_relative_paths = true;
        ctx.sandbox = sb;
        return ctx;
    }
};

fn expectDenied(result: anyerror![]u8) !void {
    if (result) |bytes| {
        std.testing.allocator.free(bytes);
        return error.ExpectedSandboxDenial;
    } else |err| switch (err) {
        error.SandboxAccessDenied, error.FileNotFound, error.SandboxOutlineUnavailable => {},
        else => return err,
    }
}

test "L2 native filesystem sandbox: Read denies text image outline and symlink without read_state" {
    if (comptime !protocol.supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    const sb = @import("config.zig").SandboxSettings{ .enabled = true, .deny_read = &.{fixture.outside} };
    var ctx = fixture.context(&sb);
    var rs = read_state.ReadState.init(allocator);
    defer rs.deinit();
    ctx.read_state = &rs;
    const read = @import("../tools/read.zig");
    for ([_][]const u8{ "outside/secret.txt", "outside/secret.png", "outside/secret.zig" }) |rel| {
        const path = try fixture.path(rel);
        defer allocator.free(path);
        try TestFixture.write(path, "secret-native-sandbox-marker\n");
        const args = try std.fmt.allocPrint(allocator, "{{\"file_path\":\"{s}\",\"outline\":true}}", .{path});
        defer allocator.free(args);
        try expectDenied(read.execute(&ctx, args));
        try std.testing.expect(rs.get(path) == null);
    }
    const target = try fixture.path("outside/secret.txt");
    defer allocator.free(target);
    const link = try fixture.path("workspace/link.txt");
    defer allocator.free(link);
    const tz = try allocator.dupeZ(u8, target);
    defer allocator.free(tz);
    const lz = try allocator.dupeZ(u8, link);
    defer allocator.free(lz);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(tz, lz));
    try expectDenied(read.execute(&ctx, "{\"file_path\":\"link.txt\"}"));
    try std.testing.expect(rs.get(link) == null);
}

test "L2 native filesystem sandbox: Write Edit outside and symlink denied before truncate or mkdir" {
    if (comptime !protocol.supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    const sb = @import("config.zig").SandboxSettings{
        .enabled = true,
        .deny_write = &.{fixture.outside},
        .excluded_commands = &.{"exec"}, // shell exclusions must not exempt file tools
    };
    const ctx = fixture.context(&sb);
    const outside = try fixture.path("outside/keep.txt");
    defer allocator.free(outside);
    try TestFixture.write(outside, "unchanged\n");
    const link = try fixture.path("workspace/escape.txt");
    defer allocator.free(link);
    const tz = try allocator.dupeZ(u8, outside);
    defer allocator.free(tz);
    const lz = try allocator.dupeZ(u8, link);
    defer allocator.free(lz);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(tz, lz));
    for ([_][]const u8{ outside, link }) |path| {
        const write_args = try std.fmt.allocPrint(allocator, "{{\"file_path\":\"{s}\",\"content\":\"damaged\"}}", .{path});
        defer allocator.free(write_args);
        try expectDenied(@import("../tools/write.zig").execute(&ctx, write_args));
        const edit_args = try std.fmt.allocPrint(allocator, "{{\"file_path\":\"{s}\",\"old_string\":\"unchanged\",\"new_string\":\"damaged\"}}", .{path});
        defer allocator.free(edit_args);
        try expectDenied(@import("../tools/edit.zig").execute(&ctx, edit_args));
        try TestFixture.expectBytes(outside, "unchanged\n");
    }
    const absent = try fixture.path("outside/new-parent/sub/file.txt");
    defer allocator.free(absent);
    const args = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"content\":\"no\"}}", .{absent});
    defer allocator.free(args);
    try expectDenied(@import("../tools/write.zig").execute(&ctx, args));
    const parent = try fixture.path("outside/new-parent");
    defer allocator.free(parent);
    const pz = try allocator.dupeZ(u8, parent);
    defer allocator.free(pz);
    try std.testing.expect(!pfs.exists(pz));
    const link_dir = try fixture.path("workspace/escape-dir");
    defer allocator.free(link_dir);
    const dz = try allocator.dupeZ(u8, fixture.outside);
    defer allocator.free(dz);
    const ldz = try allocator.dupeZ(u8, link_dir);
    defer allocator.free(ldz);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(dz, ldz));
    try expectDenied(@import("../tools/write.zig").execute(&ctx, "{\"path\":\"escape-dir/new-parent/sub/file.txt\",\"content\":\"damage\"}"));
    try std.testing.expect(!pfs.exists(pz));
}

test "L2 native filesystem sandbox: allowed Read Write Edit preserve receipts state and exact nofollow" {
    if (comptime !protocol.supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    const sb = @import("config.zig").SandboxSettings{ .enabled = true };
    var ctx = fixture.context(&sb);
    var rs = read_state.ReadState.init(allocator);
    defer rs.deinit();
    ctx.read_state = &rs;
    const changes = @import("../core/file_change.zig");
    var collector = changes.Collector{ .allocator = allocator, .ctx = &ctx, .tool = "Write", .tool_use_id = "sandbox-file", .agent_depth = 0 };
    defer collector.deinit();
    ctx.file_change_sink = collector.sink();
    var effect: @import("../tools/observation.zig").EffectSlot = .{};
    ctx.effect_slot = &effect;
    const path = try fixture.path("workspace/nested/file.txt");
    defer allocator.free(path);
    const wr = try @import("../tools/write.zig").execute(&ctx, "{\"path\":\"nested/file.txt\",\"content\":\"first\\n\"}");
    defer allocator.free(wr);
    try std.testing.expect(std.mem.indexOf(u8, wr, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, wr, "structuredPatch") != null);
    try TestFixture.expectBytes(path, "first\n");
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, "first\n"), rs.get(path).?.content_hash);
    try std.testing.expect(effect.valid);
    try std.testing.expectEqual(@import("../tools/observation.zig").BeforeState.missing, effect.effect.?.file_mutation_v1.before_state);
    effect = .{}; // a new dispatch gets a fresh observation slot
    const rd = try @import("../tools/read.zig").execute(&ctx, "{\"path\":\"nested/file.txt\"}");
    defer allocator.free(rd);
    try std.testing.expect(std.mem.indexOf(u8, rd, "1\tfirst") != null);
    const ed = try @import("../tools/edit.zig").execute(&ctx, "{\"file_path\":\"nested/file.txt\",\"old_string\":\"first\",\"new_string\":\"second\"}");
    defer allocator.free(ed);
    try std.testing.expect(std.mem.indexOf(u8, ed, "gitDiff") != null);
    try TestFixture.expectBytes(path, "second\n");
    try std.testing.expectEqual(std.hash.Wyhash.hash(0, "second\n"), rs.get(path).?.content_hash);
    try std.testing.expectEqual(@as(usize, 2), collector.items.items.len);
    try std.testing.expectEqual(changes.Kind.created, collector.items.items[0].kind);
    try std.testing.expectEqual(changes.Status.applied, collector.items.items[1].status);
    try std.testing.expect(collector.items.items[1].diff_complete);
    try std.testing.expect(effect.effect != null);
    try std.testing.expect(effect.valid);
    try std.testing.expectEqual(@import("../tools/observation.zig").BeforeState.known, effect.effect.?.file_mutation_v1.before_state);
    try std.testing.expectEqual(@as(usize, 7), effect.effect.?.file_mutation_v1.after_bytes);

    ctx.project_write_exclusive_create = true;
    try expectDenied(@import("../tools/write.zig").execute(&ctx, "{\"path\":\"nested/file.txt\",\"content\":\"damage\"}"));
    try TestFixture.expectBytes(path, "second\n");
    ctx.project_write_exclusive_create = false;

    // Exact recovery must keep the no-follow RDWR fd and compare on it before
    // writing. A stale source and a symlink are both rejected unchanged.
    ctx.project_edit_mode = .whole_file_exact;
    try std.testing.expectError(error.ExactRecoverySourceChanged, @import("../tools/edit.zig").execute(&ctx, "{\"file_path\":\"nested/file.txt\",\"old_string\":\"wrong\",\"new_string\":\"damage\"}"));
    const exact = try @import("../tools/edit.zig").execute(&ctx, "{\"file_path\":\"nested/file.txt\",\"old_string\":\"second\\n\",\"new_string\":\"third\\n\"}");
    defer allocator.free(exact);
    try TestFixture.expectBytes(path, "third\n");
    const link = try fixture.path("workspace/exact-link.txt");
    defer allocator.free(link);
    const tz = try allocator.dupeZ(u8, path);
    defer allocator.free(tz);
    const lz = try allocator.dupeZ(u8, link);
    defer allocator.free(lz);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(tz, lz));
    try expectDenied(@import("../tools/edit.zig").execute(&ctx, "{\"file_path\":\"exact-link.txt\",\"old_string\":\"third\\n\",\"new_string\":\"damage\"}"));
    try TestFixture.expectBytes(path, "third\n");
}

test "L2 native filesystem sandbox: NotebookEdit reads and mutations are confined" {
    if (comptime !protocol.supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    const notebook = "{\"cells\":[{\"id\":\"one\",\"cell_type\":\"code\",\"source\":\"old\"}],\"metadata\":{}}";
    const inside = try fixture.path("workspace/book.ipynb");
    defer allocator.free(inside);
    const outside = try fixture.path("outside/book.ipynb");
    defer allocator.free(outside);
    try TestFixture.write(inside, notebook);
    try TestFixture.write(outside, notebook);
    const sb = @import("config.zig").SandboxSettings{ .enabled = true, .deny_write = &.{fixture.outside} };
    var ctx = fixture.context(&sb);
    const edit = @import("../tools/notebook_edit.zig");
    const allowed = try edit.execute(&ctx, "{\"notebook_path\":\"book.ipynb\",\"cell_id\":\"one\",\"new_source\":\"new\"}");
    defer allocator.free(allowed);
    try std.testing.expect(std.mem.indexOf(u8, allowed, "\"success\":true") != null);
    const args = try std.fmt.allocPrint(allocator, "{{\"notebook_path\":\"{s}\",\"cell_id\":\"one\",\"new_source\":\"damage\"}}", .{outside});
    defer allocator.free(args);
    try expectDenied(edit.execute(&ctx, args));
    try TestFixture.expectBytes(outside, notebook);
    const hidden = @import("config.zig").SandboxSettings{ .enabled = true, .deny_read = &.{fixture.outside} };
    ctx.sandbox = &hidden;
    try expectDenied(edit.execute(&ctx, args));
    try TestFixture.expectBytes(outside, notebook);
}

test "L2 native filesystem sandbox: descriptor stays bound across path replacement" {
    if (comptime !protocol.supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    const sb = @import("config.zig").SandboxSettings{ .enabled = true, .deny_write = &.{fixture.outside} };
    const ctx = fixture.context(&sb);
    const original = try fixture.path("workspace/original.txt");
    defer allocator.free(original);
    const moved = try fixture.path("workspace/moved.txt");
    defer allocator.free(moved);
    const outside = try fixture.path("outside/keep.txt");
    defer allocator.free(outside);
    try TestFixture.write(original, "first\n");
    try TestFixture.write(outside, "unchanged\n");
    const fd = try open(&ctx, original, .{ .ACCMODE = .RDWR, .NOFOLLOW = true }, 0, false);
    defer _ = pfs.close(fd);
    const oz = try allocator.dupeZ(u8, original);
    defer allocator.free(oz);
    const mz = try allocator.dupeZ(u8, moved);
    defer allocator.free(mz);
    const tz = try allocator.dupeZ(u8, outside);
    defer allocator.free(tz);
    try std.testing.expectEqual(@as(c_int, 0), pfs.renameReplace(oz, mz));
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(tz, oz));
    try std.testing.expect(pfs.writeAll(fd, "other\n"));
    try TestFixture.expectBytes(moved, "other\n");
    try TestFixture.expectBytes(outside, "unchanged\n");
    try std.testing.expect(std.c.fcntl(fd, std.c.F.GETFD) & std.c.FD_CLOEXEC != 0);
}

test "L2 native filesystem sandbox: closed stdin keeps helper stderr out of the protocol" {
    if (comptime !protocol.supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    const real_helper = try helperPath(allocator);
    defer allocator.free(real_helper);
    const helper_quoted = try shellQuote(allocator, real_helper);
    defer allocator.free(helper_quoted);
    const wrapper = try fixture.path("workspace/diagnostic helper");
    defer allocator.free(wrapper);
    const wrapper_z = try allocator.dupeZ(u8, wrapper);
    defer allocator.free(wrapper_z);
    const marker = try fixture.path("workspace/wrapper-ran");
    defer allocator.free(marker);
    const marker_quoted = try shellQuote(allocator, marker);
    defer allocator.free(marker_quoted);
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nprintf 'wrapper-used\\n' > {s}\nprintf 'helper stderr diagnostic\\n' >&2\nexec {s}\n",
        .{ marker_quoted, helper_quoted },
    );
    defer allocator.free(script);
    try TestFixture.write(wrapper, script);
    try std.testing.expectEqual(@as(c_int, 0), pfs.chmod(wrapper_z, 0o755));
    const path = try fixture.path("workspace/read.txt");
    defer allocator.free(path);
    try TestFixture.write(path, "closed-stdin-readable\n");
    const sb = @import("config.zig").SandboxSettings{ .enabled = true };
    var ctx = fixture.context(&sb);
    // The forked probe owns its allocations and environment; neither closing
    // stdin nor selecting the diagnostic wrapper changes the test runner.
    ctx.allocator = std.heap.page_allocator;
    platform.process.forkSerialLock();
    const pid = std.c.fork();
    platform.process.forkSerialUnlock();
    try std.testing.expect(pid >= 0);
    if (pid == 0) {
        platform.paths.setEnv("METACODES_SANDBOX_HELPER", wrapper_z);
        _ = std.c.close(0);
        const result = @import("../tools/read.zig").execute(&ctx, "{\"path\":\"read.txt\"}") catch std.c._exit(1);
        const correct = std.mem.indexOf(u8, result, "1\tclosed-stdin-readable") != null;
        std.c._exit(if (correct) 0 else 2);
    }
    var reaped = false;
    defer if (!reaped) {
        _ = std.c.kill(pid, std.c.SIG.KILL);
        var status: c_int = 0;
        while (std.c.waitpid(pid, &status, 0) < 0 and pfs.lastErrnoIs(.INTR)) {}
    };
    const time = @import("../util/time.zig");
    const deadline = time.nowMs() + 30_000;
    while (true) {
        var status: c_int = 0;
        const waited = std.c.waitpid(pid, &status, 1); // WNOHANG
        if (waited == pid) {
            reaped = true;
            try std.testing.expectEqual(@as(c_int, 0), status);
            break;
        }
        if (waited < 0 and !pfs.lastErrnoIs(.INTR)) return error.TestChildWaitFailed;
        if (time.nowMs() >= deadline) return error.TestChildTimeout;
        time.sleepMs(10);
    }
    try TestFixture.expectBytes(marker, "wrapper-used\n");
}

test "L2 native filesystem sandbox: missing or relative host helper fails closed before mkdir" {
    if (comptime !protocol.supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    const original = try helperPath(allocator);
    defer allocator.free(original);
    const original_z = try allocator.dupeZ(u8, original);
    defer allocator.free(original_z);
    // The build provides this variable; restore it even on failed assertions.
    defer platform.paths.setEnv("METACODES_SANDBOX_HELPER", original_z);
    const sb = @import("config.zig").SandboxSettings{ .enabled = true, .fail_if_unavailable = false };
    const ctx = fixture.context(&sb);
    platform.paths.setEnv("METACODES_SANDBOX_HELPER", "./untrusted-project-helper");
    try std.testing.expectError(error.SandboxHelperUnavailable, @import("../tools/write.zig").execute(&ctx, "{\"path\":\"new/sub/file.txt\",\"content\":\"damage\"}"));
    const missing = try fixture.path("workspace/absent-helper");
    defer allocator.free(missing);
    const missing_z = try allocator.dupeZ(u8, missing);
    defer allocator.free(missing_z);
    platform.paths.setEnv("METACODES_SANDBOX_HELPER", missing_z);
    try std.testing.expectError(error.SandboxHelperProtocol, @import("../tools/write.zig").execute(&ctx, "{\"path\":\"new/sub/file.txt\",\"content\":\"damage\"}"));
    const parent = try fixture.path("workspace/new");
    defer allocator.free(parent);
    const pz = try allocator.dupeZ(u8, parent);
    defer allocator.free(pz);
    try std.testing.expect(!pfs.exists(pz));
}

test "native filesystem sandbox: unsupported hosts refuse explicit sandbox settings" {
    if (comptime protocol.supported) return error.SkipZigTest;
    const sb = @import("config.zig").SandboxSettings{ .enabled = true, .fail_if_unavailable = false };
    var ctx = ToolContext.simple(std.testing.allocator);
    ctx.sandbox = &sb;
    try std.testing.expectError(error.SandboxUnavailable, open(&ctx, "unreachable", .{ .ACCMODE = .RDONLY }, 0, false));
    try std.testing.expectError(error.SandboxUnavailable, open(&ctx, "unreachable", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644, true));
    const argv = [_]?[*:0]const u8{ "unreachable", null };
    try std.testing.expectError(error.SandboxUnavailable, wrapArgv(&ctx, &argv));
}
