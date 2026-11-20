//! 把 Bash 命令包进平台沙箱:macOS Seatbelt,Linux bubblewrap。
//!
//! 入口:wrapCommand(alloc, cmd, opts) → WrapResult
//!   .passthrough = 不沙箱(disabled / 平台不支持 / excludedCommand / 逃生口)
//!   .unavailable = 本机无可用后端且 failIfUnavailable
//!   .wrapped     = 包裹后的 argv(Seatbelt 另带 profile 临时文件路径)
//!
//! 后端(`Backend`,按平台二选一,同一份 SandboxSettings):
//!   macOS:  /usr/bin/sandbox-exec -f <profile_file> /bin/bash -c "<cmd>"
//!           (用 -f 文件而非 -p inline,避免超长 profile 命令行截断;profile.zig)
//!   Linux:  bwrap --ro-bind / / ... --bind <write roots> ... -- /bin/bash -c "<cmd>"
//!           (挂载命名空间 + seccomp; launcher 经管道传 BPF,无临时文件)
//! Windows 等其它平台无后端:plan 给 passthrough / unavailable。

const std = @import("std");
const pprocess = @import("platform").process;
const pfs = @import("platform").fs;
const ppaths = @import("platform").paths;
const builtin = @import("builtin");
const profile_mod = @import("profile.zig");
const bwrap_mod = @import("bwrap.zig");
const seccomp = @import("seccomp.zig");
const config_mod = @import("config.zig");
const util_json = @import("../util/json.zig");

/// The sandbox implementation a host uses.
pub const Backend = enum {
    /// macOS `sandbox-exec` with a generated SBPL profile (profile.zig).
    seatbelt,
    /// Linux bubblewrap namespaces plus syscall filtering (bwrap/seccomp.zig).
    bwrap,
};

pub const WrappedCommand = struct {
    /// argv(以 NUL 结尾的指针数组由 caller 构造;这里给 []const []const u8)
    argv: []const []const u8,
    /// Seatbelt 的临时 profile 文件路径(deinit 时 unlink + free);bwrap 无文件 = null。
    profile_path: ?[]const u8,
    backend: Backend,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WrappedCommand) void {
        if (self.profile_path) |p| {
            unlinkProfile(p);
            self.allocator.free(p);
        }
        for (self.argv) |a| self.allocator.free(a);
        self.allocator.free(self.argv);
    }

    /// The wrapped command's exit code in `platform.process` terms (negative
    /// = killed by that signal). sandbox-exec execs the command, so its
    /// status is the command's own; bwrap waits for it and exits 128+N when
    /// it died of signal N, which is mapped back here.
    pub fn childExitCode(self: *const WrappedCommand, code: i32) i32 {
        return switch (self.backend) {
            .seatbelt => code,
            .bwrap => bwrap_mod.decodeExit(code),
        };
    }
};

fn unlinkProfile(path: []const u8) void {
    var pz: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len < pz.len) {
        @memcpy(pz[0..path.len], path);
        pz[path.len] = 0;
        pfs.unlinkPath(@ptrCast(&pz)) catch {};
    }
}

pub const WrapOptions = struct {
    cwd: []const u8,
    home: []const u8 = "",
    sandbox: *const config_mod.SandboxSettings,
    /// worktree 场景下的主 repo .git(允许写)
    main_git_dir: ?[]const u8 = null,
    /// 额外工作目录(--add-dir / additionalDirectories,绝对路径):与 cwd 同级可写。
    additional_dirs: []const []const u8 = &.{},
    /// 单次调用显式禁用沙箱(dangerouslyDisableSandbox 逃生口)
    disable_for_this_command: bool = false,
};

pub const WrapResult = union(enum) {
    /// 不沙箱:原样跑(disabled / 不支持 / excluded / 逃生口)
    passthrough,
    /// 沙箱不可用且 failIfUnavailable=true → 应拒绝执行
    unavailable,
    /// 已包裹
    wrapped: WrappedCommand,
};

/// What `wrapCommand` does with one command, decided before any I/O other
/// than the backend probe (sandbox-exec present; bwrap located and able to
/// build its namespaces, probed once per path). The permission chain's
/// autoAllowBashIfSandboxed asks the same question: only `.sandboxed` earns
/// the auto-allow, so a command that will run outside the sandbox (another
/// platform, an excluded command, the escape hatch) is never auto-allowed
/// as if it were confined.
pub const Plan = enum {
    /// Run as is: sandbox disabled, escape hatch honored, no sandbox on this
    /// host with failIfUnavailable=false, or an excluded command.
    passthrough,
    /// No sandbox on this host and failIfUnavailable=true: refuse to run.
    unavailable,
    /// Run inside the host's sandbox backend.
    sandboxed,
};

pub fn plan(sb: *const config_mod.SandboxSettings, cmd: []const u8, disable_for_this_command: bool) Plan {
    // 1. 未启用 / 单次禁用 → passthrough
    if (!sb.enabled or disable_for_this_command) return .passthrough;
    // No reviewed ABI policy means no Linux sandbox, regardless of the
    // optional-backend setting. Never mislabel a foreign ABI as confined.
    if (builtin.os.tag == .linux and !seccomp.supported()) return .unavailable;
    // 2. 本机无可用后端(非 macOS/Linux、sandbox-exec 不存在、bwrap 缺失或建不了命名空间)
    //    → unavailable / passthrough
    if (!hostSupported()) return if (sb.fail_if_unavailable) .unavailable else .passthrough;
    // 3. excludedCommands:命令首 token 命中 → passthrough
    if (sb.isExcludedCommand(firstToken(cmd))) return .passthrough;
    return .sandboxed;
}

/// Whether this host has a working sandbox backend: macOS with
/// /usr/bin/sandbox-exec, or Linux with a bubblewrap that passed its probe.
pub fn hostSupported() bool {
    return hostBackend() != null;
}

/// The backend this host confines commands with, null when it has none.
pub fn hostBackend() ?Backend {
    return switch (builtin.os.tag) {
        .macos => if (sandboxExecAvailable()) .seatbelt else null,
        .linux => if (bwrap_mod.availability() == .available) .bwrap else null,
        else => null,
    };
}

/// The bwrap network policy for `sb`. Seatbelt leaves the network open
/// (`(allow default)`), and so does bwrap by default. A domain list asks
/// for per-host filtering, which needs a filtering proxy neither backend
/// has; bwrap fails closed and gives the command no network at all.
pub fn bwrapNetwork(sb: *const config_mod.SandboxSettings) bwrap_mod.Network {
    return if (sb.allowed_domains.len > 0 or sb.denied_domains.len > 0) .isolated else .shared;
}

/// The Bash tool's per-call `dangerouslyDisableSandbox` escape hatch. It is
/// not in the tool schema, and takes effect only when the settings allow
/// unsandboxed commands (`allowUnsandboxedCommands`, default true; the
/// AgentCore sandboxed shell policy sets it false). A call that uses it runs
/// outside the sandbox, so `plan` says `.passthrough` and the permission
/// chain does not auto-allow it as sandboxed.
pub fn escapeHatchHonored(sb: *const config_mod.SandboxSettings, args_json: []const u8) bool {
    if (!sb.allow_unsandboxed_commands) return false;
    return util_json.topLevelBoolField(args_json, "dangerouslyDisableSandbox") orelse false;
}

/// 决定是否 / 如何沙箱化一条 bash 命令。
pub fn wrapCommand(alloc: std.mem.Allocator, cmd: []const u8, opts: WrapOptions) !WrapResult {
    const sb = opts.sandbox;
    switch (plan(sb, cmd, opts.disable_for_this_command)) {
        .passthrough => return .passthrough,
        .unavailable => return .unavailable,
        .sandboxed => {},
    }

    const backend = hostBackend() orelse return if (sb.fail_if_unavailable) .unavailable else .passthrough;
    if (backend == .bwrap) {
        var located_buf: [std.fs.max_path_bytes]u8 = undefined;
        const bwrap_path = switch (bwrap_mod.locate(&located_buf)) {
            .path => |p| p,
            // Gone between the probe and now: no backend after all.
            .missing, .override_not_absolute => return if (sb.fail_if_unavailable) .unavailable else .passthrough,
        };
        const argv = try bwrap_mod.buildArgv(alloc, bwrap_path, bwrap_mod.shellPath(), .{
            .cwd = opts.cwd,
            .home = opts.home,
            .allow_write = sb.allow_write,
            .deny_write = sb.deny_write,
            .deny_read = sb.deny_read,
            .main_git_dir = opts.main_git_dir,
            .additional_dirs = opts.additional_dirs,
            .network = bwrapNetwork(sb),
            .tmpdir = ppaths.tempDir(),
            .temp_writes = sb.temp_writes,
        }, cmd);
        return .{ .wrapped = .{ .argv = argv, .profile_path = null, .backend = .bwrap, .allocator = alloc } };
    }

    // 4. 生成 profile
    const prof = try profile_mod.generate(alloc, .{
        .cwd = opts.cwd,
        .home = opts.home,
        .allow_write = sb.allow_write,
        .deny_write = sb.deny_write,
        .allow_read = sb.allow_read,
        .deny_read = sb.deny_read,
        .main_git_dir = opts.main_git_dir,
        .additional_dirs = opts.additional_dirs,
        .temp_writes = sb.temp_writes,
    });
    defer alloc.free(prof);

    // 5. 写临时 profile 文件
    const prof_path = try writeTempProfile(alloc, prof);
    errdefer {
        var pz: [std.fs.max_path_bytes]u8 = undefined;
        if (prof_path.len < pz.len) {
            @memcpy(pz[0..prof_path.len], prof_path);
            pz[prof_path.len] = 0;
            pfs.unlinkPath(@ptrCast(&pz)) catch {};
        }
        alloc.free(prof_path);
    }

    // 6. 构造 argv: sandbox-exec -f <profile> /bin/bash -c <cmd>
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv.items) |a| alloc.free(a);
        argv.deinit(alloc);
    }
    try argv.append(alloc, try alloc.dupe(u8, "/usr/bin/sandbox-exec"));
    try argv.append(alloc, try alloc.dupe(u8, "-f"));
    try argv.append(alloc, try alloc.dupe(u8, prof_path));
    if (sb.temp_writes == .isolated) if (sb.temp_writes.isolated) |path| {
        try argv.append(alloc, try alloc.dupe(u8, "/usr/bin/env"));
        for ([_][]const u8{ "TMPDIR", "TMP", "TEMP" }) |key| {
            const assignment = try std.fmt.allocPrint(alloc, "{s}={s}", .{ key, path });
            argv.append(alloc, assignment) catch |err| {
                alloc.free(assignment);
                return err;
            };
        }
    };
    try argv.append(alloc, try alloc.dupe(u8, "/bin/bash"));
    try argv.append(alloc, try alloc.dupe(u8, "-c"));
    try argv.append(alloc, try alloc.dupe(u8, cmd));

    return .{ .wrapped = .{
        .argv = try argv.toOwnedSlice(alloc),
        .profile_path = prof_path,
        .backend = .seatbelt,
        .allocator = alloc,
    } };
}

/// sandbox-exec 是否存在?
fn sandboxExecAvailable() bool {
    return pfs.exists("/usr/bin/sandbox-exec");
}

/// 命令首 token(到第一个空白)。
fn firstToken(cmd: []const u8) []const u8 {
    const t = std.mem.trim(u8, cmd, " \t");
    const sp = std.mem.indexOfAny(u8, t, " \t") orelse return t;
    return t[0..sp];
}

/// 字符串级包裹:返回可直接喂 `/bin/sh -c <ret.command>` 的命令串。
///
/// 形式: wrapCommand 的 argv 逐个单引号转义后以空格拼接,如
///   '/usr/bin/sandbox-exec' '-f' '<profile>' '/bin/bash' '-c' '<original-cmd>'
///   '/usr/bin/bwrap' '--ro-bind' '/' '/' ... '--' '/bin/bash' '-c' '<original-cmd>'
/// 与 wrapCommand 不同:不返回 argv 而是 shell 串(单引号转义),
/// 方便复用现有 job_registry / spawnBackground 的 `/bin/sh -c` 路径。
///
/// 返回 null = passthrough(沙箱未启用/不支持但 failIfUnavailable=false → 原样跑)。
/// 返回 error.SandboxUnavailable = 沙箱不可用且 failIfUnavailable=true → caller 应拒绝执行。
pub fn wrapAsShellString(alloc: std.mem.Allocator, cmd: []const u8, opts: WrapOptions) !?ShellWrap {
    const r = try wrapCommand(alloc, cmd, opts);
    switch (r) {
        .passthrough => return null,
        .unavailable => return error.SandboxUnavailable,
        .wrapped => |wc| {
            var w = wc;
            const command = joinQuoted(alloc, w.argv) catch |e| {
                w.deinit(); // unlinks the profile too
                return e;
            };
            // 释放 argv 但保留 profile 文件(交给 ShellWrap 管)
            for (w.argv) |a| alloc.free(a);
            alloc.free(w.argv);
            return ShellWrap{ .command = command, .profile_path = w.profile_path, .allocator = alloc };
        },
    }
}

pub const ShellWrap = struct {
    command: []const u8,
    /// Seatbelt 的 profile 文件;bwrap = null。
    profile_path: ?[]const u8,
    allocator: std.mem.Allocator,
    /// detached:不删 profile 文件(后台作业场景——进程还在跑,profile 不能删)。
    detached: bool = false,

    /// 删 profile 文件 + free。前台命令执行完后调。
    pub fn deinit(self: *ShellWrap) void {
        if (self.profile_path) |p| {
            if (!self.detached) unlinkProfile(p);
            self.allocator.free(p);
        }
        self.allocator.free(self.command);
    }
};

/// argv 逐个单引号转义、空格拼接成一条 shell 命令。caller free。
fn joinQuoted(alloc: std.mem.Allocator, argv: []const []const u8) error{OutOfMemory}![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (argv, 0..) |arg, i| {
        if (i > 0) try buf.append(alloc, ' ');
        const quoted = try shellSingleQuote(alloc, arg);
        defer alloc.free(quoted);
        try buf.appendSlice(alloc, quoted);
    }
    return try buf.toOwnedSlice(alloc);
}

/// 单引号包裹 + 内部 ' 转义为 '\'',供 shell 安全嵌入。caller free。
fn shellSingleQuote(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') {
            try buf.appendSlice(alloc, "'\\''");
        } else {
            try buf.append(alloc, c);
        }
    }
    try buf.append(alloc, '\'');
    return try buf.toOwnedSlice(alloc);
}

/// 把 profile 写到临时文件,返回路径(owned)。用 pid + 计数避免冲突。
var profile_counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn writeTempProfile(alloc: std.mem.Allocator, content: []const u8) ![]u8 {
    const pid: i64 = pprocess.currentPid();
    const n = profile_counter.fetchAdd(1, .monotonic);
    const tmpdir_raw = ppaths.tempDir();
    // 去掉末尾 / ,统一用 fmt 的显式 / 拼
    const tmpdir = if (tmpdir_raw.len > 1 and tmpdir_raw[tmpdir_raw.len - 1] == '/')
        tmpdir_raw[0 .. tmpdir_raw.len - 1]
    else
        tmpdir_raw;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrint(&path_buf, "{s}/cczig_sb_{d}_{d}.sb\x00", .{ tmpdir, pid, n });
    const path = path_z[0 .. path_z.len - 1];

    const fd = pfs.open(@ptrCast(path_z.ptr), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.WriteProfileFailed;
    errdefer pfs.unlinkPath(@ptrCast(path_z.ptr)) catch {};
    defer _ = pfs.close(fd);

    var written: usize = 0;
    while (written < content.len) {
        const n2 = pfs.write(fd, content[written..][0 .. content.len - written]);
        if (n2 <= 0) return error.WriteProfileFailed;
        written += @intCast(n2);
    }

    return try alloc.dupe(u8, path);
}

// ============================================================================
// Tests
// ============================================================================

/// The common `.git` directory of the linked git worktree that `dir` lies in,
/// or null when `dir` is not inside one (a main checkout, no repository, a
/// submodule). A command in a linked worktree writes there for `git commit`
/// (objects, refs, `worktrees/<name>/`), and that directory is outside the
/// worktree, so the sandbox has to allow it (`WrapOptions.main_git_dir`). Read
/// from git's own layout, no git process: the worktree's `.git` file names its
/// gitdir, whose `commondir` names the common directory relative to it.
/// Physical path (owned by `alloc`), as the profile's other roots.
pub fn linkedWorktreeGitDir(alloc: std.mem.Allocator, dir: []const u8) ?[]u8 {
    if (!std.fs.path.isAbsolute(dir)) return null;
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    var current: []const u8 = dir;
    while (true) {
        const dot_git = std.fmt.bufPrintZ(&buf, "{s}{s}.git", .{ current, if (std.mem.endsWith(u8, current, "/")) "" else "/" }) catch return null;
        if (pfs.statMode(dot_git.ptr, false)) |mode| {
            // A `.git` directory is a main checkout; only a file points elsewhere.
            if (mode & 0o170000 != 0o100000) return null;
            var line_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
            const line = readSmall(dot_git, &line_buf) orelse return null;
            const prefix = "gitdir:";
            if (!std.mem.startsWith(u8, line, prefix)) return null;
            const gitdir_raw = std.mem.trim(u8, line[prefix.len..], " \t");
            var gitdir_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const gitdir = (if (std.fs.path.isAbsolute(gitdir_raw))
                std.fmt.bufPrint(&gitdir_buf, "{s}", .{gitdir_raw})
            else
                std.fmt.bufPrint(&gitdir_buf, "{s}/{s}", .{ current, gitdir_raw })) catch return null;
            const commondir_path = std.fmt.bufPrintZ(&buf, "{s}/commondir", .{gitdir}) catch return null;
            var common_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const common_raw = readSmall(commondir_path, &common_buf) orelse return null;
            const common = (if (std.fs.path.isAbsolute(common_raw))
                std.fmt.bufPrintZ(&buf, "{s}", .{common_raw})
            else
                std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ gitdir, common_raw })) catch return null;
            var real_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const real = pfs.realpath(common.ptr, &real_buf) orelse return null;
            return alloc.dupe(u8, std.mem.span(real)) catch null;
        }
        const parent = std.fs.path.dirname(current) orelse return null;
        if (parent.len == current.len) return null;
        current = parent;
    }
}

/// The first line of a small file, trimmed; null when it cannot be read.
fn readSmall(path: [:0]const u8, buf: []u8) ?[]const u8 {
    const fd = pfs.openZ(path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer pfs.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = pfs.readZ(fd, buf[len..]) catch return null;
        if (n == 0) break;
        len += n;
    }
    const first = std.mem.sliceTo(buf[0..len], '\n');
    const line = std.mem.trim(u8, first, " \t\r");
    return if (line.len > 0) line else null;
}

const testing = std.testing;

test "wrapCommand: disabled → passthrough" {
    const sb = config_mod.SandboxSettings{ .enabled = false };
    const r = try wrapCommand(testing.allocator, "ls", .{ .cwd = "/tmp", .sandbox = &sb });
    try testing.expect(r == .passthrough);
}

test "wrapCommand: excluded command → passthrough" {
    if (!hostSupported()) return error.SkipZigTest;
    const sb = config_mod.SandboxSettings{
        .enabled = true,
        .excluded_commands = &.{"docker"},
    };
    const r = try wrapCommand(testing.allocator, "docker ps", .{ .cwd = "/tmp", .sandbox = &sb });
    try testing.expect(r == .passthrough);
}

test "wrapCommand: disable_for_this_command → passthrough" {
    const sb = config_mod.SandboxSettings{ .enabled = true };
    const r = try wrapCommand(testing.allocator, "ls", .{
        .cwd = "/tmp",
        .sandbox = &sb,
        .disable_for_this_command = true,
    });
    try testing.expect(r == .passthrough);
}

test "wrapAsShellString: failIfUnavailable without a backend → error.SandboxUnavailable" {
    if (hostSupported()) return error.SkipZigTest; // 有后端测不到 unavailable(Linux 见 "bwrap L2: a bwrap that is missing...")
    const sb = config_mod.SandboxSettings{ .enabled = true, .fail_if_unavailable = true };
    const r = wrapAsShellString(testing.allocator, "ls", .{ .cwd = "/tmp", .sandbox = &sb });
    try testing.expectError(error.SandboxUnavailable, r);
}

test "wrapAsShellString: failIfUnavailable=false without a backend → null passthrough" {
    if (hostSupported()) return error.SkipZigTest;
    const sb = config_mod.SandboxSettings{ .enabled = true, .fail_if_unavailable = false };
    const r = try wrapAsShellString(testing.allocator, "ls", .{ .cwd = "/tmp", .sandbox = &sb });
    try testing.expect(r == null);
}

test "wrapCommand: enabled on macos → wrapped argv" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const sb = config_mod.SandboxSettings{ .enabled = true };
    const r = try wrapCommand(testing.allocator, "echo hi", .{ .cwd = "/tmp", .home = "/Users/foo", .sandbox = &sb });
    try testing.expect(r == .wrapped);
    var wc = r.wrapped;
    defer wc.deinit();
    try testing.expectEqualStrings("/usr/bin/sandbox-exec", wc.argv[0]);
    try testing.expectEqualStrings("-f", wc.argv[1]);
    try testing.expectEqualStrings("/bin/bash", wc.argv[3]);
    try testing.expectEqualStrings("-c", wc.argv[4]);
    try testing.expectEqualStrings("echo hi", wc.argv[5]);
    try testing.expectEqual(Backend.seatbelt, wc.backend);
    // profile 文件应已写入(用 std.c.access 检查存在)
    const profile_path = wc.profile_path.?;
    var pz: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(pz[0..profile_path.len], profile_path);
    pz[profile_path.len] = 0;
    try testing.expect(pfs.exists(@ptrCast(&pz)));
}

test "firstToken" {
    try testing.expectEqualStrings("docker", firstToken("docker ps -a"));
    try testing.expectEqualStrings("ls", firstToken("  ls"));
    try testing.expectEqualStrings("git", firstToken("git"));
}

// 端到端:沙箱真生效 —— cwd 内写允许,cwd 外(HOME/etc)写被拦。
// 实际 spawn sandbox-exec 跑命令,断言行为。仅 macOS。
test "e2e: sandbox blocks write outside cwd, allows inside" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    if (!sandboxExecAvailable()) return error.SkipZigTest;
    const alloc = testing.allocator;

    // 临时工作目录 /private/tmp/cczig_sbe2e_<pid>
    const pid: i64 = pprocess.currentPid();
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/private/tmp/cczig_sbe2e_{d}", .{pid});
    var dir_z: [129]u8 = undefined;
    @memcpy(dir_z[0..dir.len], dir);
    dir_z[dir.len] = 0;
    _ = pfs.mkdir(@ptrCast(&dir_z), 0o755);
    defer _ = pfs.rmdir(@ptrCast(&dir_z));

    const sb = config_mod.SandboxSettings{ .enabled = true };
    // 命令:cwd 内写 OK;cwd 外(/private/tmp/cczig_sbe2e_OUTSIDE)写应被拦
    const cmd = try std.fmt.allocPrint(alloc, "echo in > {s}/ok.txt && echo INSIDE_OK; (echo x > /private/etc/cczig_hack_{d} 2>/dev/null && echo OUTSIDE_BAD || echo OUTSIDE_BLOCKED)", .{ dir, pid });
    defer alloc.free(cmd);

    const w = try wrapAsShellString(alloc, cmd, .{ .cwd = dir, .home = "/Users/x", .sandbox = &sb });
    try testing.expect(w != null);
    var sw = w.?;
    defer sw.deinit();

    // spawn /bin/sh -c <sw.command>,捕获 stdout
    const out = try runShell(alloc, sw.command);
    defer alloc.free(out);

    // cwd 内写成功
    try testing.expect(std.mem.indexOf(u8, out, "INSIDE_OK") != null);
    // cwd 外写被沙箱拦
    try testing.expect(std.mem.indexOf(u8, out, "OUTSIDE_BLOCKED") != null);
    try testing.expect(std.mem.indexOf(u8, out, "OUTSIDE_BAD") == null);

    // 清理 cwd 内文件
    var ok_z: [160]u8 = undefined;
    const ok_path = std.fmt.bufPrint(&ok_z, "{s}/ok.txt\x00", .{dir}) catch return;
    pfs.unlinkPath(@ptrCast(ok_path.ptr)) catch {};
}

/// 简易 `/bin/sh -c cmd` 捕获 stdout(测试用,复用 tools/common 的 spawn)。
/// The capture runs with an empty environment, so on macOS `git` is Xcode's
/// `/usr/bin/git` shim: 1-2.5 s a call while its xcrun cache is cold, more on
/// a loaded runner. The e2e setup's three git calls overran a 10 s limit on a
/// macOS runner (#401); the limit only bounds a hang, so it is generous.
const RUN_SHELL_TIMEOUT_MS: u64 = 60_000;

fn runShell(alloc: std.mem.Allocator, cmd: []const u8) ![]u8 {
    const common = @import("../tools/common.zig");
    const cmd_z = try alloc.dupeZ(u8, cmd);
    defer alloc.free(cmd_z);
    const argv0: [*:0]const u8 = "/bin/sh";
    var argv: [4]?[*:0]const u8 = .{ argv0, "-c", cmd_z.ptr, null };
    const out = try common.spawnCaptureWithStderrTimed(argv[0..argv.len], alloc, null, RUN_SHELL_TIMEOUT_MS, null, common.MAX_SPAWN_CAPTURE_BYTES, null);
    alloc.free(out.stderr);
    return out.stdout;
}

test "linkedWorktreeGitDir: a linked worktree names its common .git, a main checkout nothing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    // main/.git is a directory with a linked worktree's private gitdir in it;
    // wt/.git is the file git writes there (absolute), rel/.git the relative form.
    try tmp.dir.createDirPath(testing.io, "main/.git/worktrees/wt");
    try tmp.dir.createDirPath(testing.io, "main/sub");
    try tmp.dir.createDirPath(testing.io, "wt/deep/er");
    try tmp.dir.createDirPath(testing.io, "rel");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "main/.git/worktrees/wt/commondir", .data = "../..\n" });
    const pointer = try std.fmt.allocPrint(alloc, "gitdir: {s}/main/.git/worktrees/wt\n", .{root});
    defer alloc.free(pointer);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "wt/.git", .data = pointer });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "rel/.git", .data = "gitdir: ../main/.git/worktrees/wt\n" });
    const expected = try std.fmt.allocPrint(alloc, "{s}/main/.git", .{root});
    defer alloc.free(expected);

    for ([_][]const u8{ "wt", "wt/deep/er", "rel" }) |inside| {
        const dir = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, inside });
        defer alloc.free(dir);
        const got = linkedWorktreeGitDir(alloc, dir) orelse return error.TestExpectedGitDir;
        defer alloc.free(got);
        try testing.expectEqualStrings(expected, got);
    }
    for ([_][]const u8{ "main", "main/sub" }) |checkout| {
        const dir = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, checkout });
        defer alloc.free(dir);
        try testing.expect(linkedWorktreeGitDir(alloc, dir) == null);
    }
    // A `.git` file without a commondir (a submodule's) is no linked worktree.
    try tmp.dir.createDirPath(testing.io, "modules/sm");
    try tmp.dir.createDirPath(testing.io, "sm");
    const sm_pointer = try std.fmt.allocPrint(alloc, "gitdir: {s}/modules/sm\n", .{root});
    defer alloc.free(sm_pointer);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "sm/.git", .data = sm_pointer });
    const sm = try std.fmt.allocPrint(alloc, "{s}/sm", .{root});
    defer alloc.free(sm);
    try testing.expect(linkedWorktreeGitDir(alloc, sm) == null);
}

test "e2e: git commit in a linked worktree needs its common .git writable, and gets it" {
    if (!hostSupported()) return error.SkipZigTest; // Seatbelt or bwrap
    const alloc = testing.allocator;
    // Not under /tmp or $TMPDIR: the profile lets every command write there,
    // which would hide the main repository's .git being outside the worktree.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    const setup = try std.fmt.allocPrint(alloc, "set -e; cd {s}; git init -q main; cd main; " ++
        "git -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed; git worktree add -q ../wt -b wt; echo READY", .{root});
    defer alloc.free(setup);
    const ready = try runShell(alloc, setup);
    defer alloc.free(ready);
    if (std.mem.indexOf(u8, ready, "READY") == null) return error.SkipZigTest; // no git here
    const wt = try std.fmt.allocPrint(alloc, "{s}/wt", .{root});
    defer alloc.free(wt);
    const git_dir = linkedWorktreeGitDir(alloc, wt) orelse return error.TestExpectedGitDir;
    defer alloc.free(git_dir);
    try testing.expect(std.mem.endsWith(u8, git_dir, "/main/.git"));

    const sb = config_mod.SandboxSettings{ .enabled = true };
    const commit = try std.fmt.allocPrint(alloc, "cd {s} && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m in-sandbox 2>&1 && echo COMMITTED || echo REFUSED", .{wt});
    defer alloc.free(commit);
    // Without the common directory the commit cannot write its objects...
    {
        var w = (try wrapAsShellString(alloc, commit, .{ .cwd = wt, .home = "/Users/x", .sandbox = &sb })).?;
        defer w.deinit();
        const out = try runShell(alloc, w.command);
        defer alloc.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "REFUSED") != null);
    }
    // ...with it, it can.
    var w = (try wrapAsShellString(alloc, commit, .{ .cwd = wt, .home = "/Users/x", .sandbox = &sb, .main_git_dir = git_dir })).?;
    defer w.deinit();
    const out = try runShell(alloc, w.command);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "COMMITTED") != null);
}

// ── bubblewrap L2 (Linux) ────────────────────────────────────────────────────
// Each test runs real commands under the bwrap backend through `wrapCommand`
// / `wrapAsShellString`, the paths the Bash tool, Monitor, the reviewer's
// check runner and the Claude Code seat driver take. Skipped off Linux, and
// on a Linux host whose bwrap cannot build a sandbox.

fn requireBwrap() !void {
    if (hostBackend() != .bwrap) return error.SkipZigTest;
}

const Ran = struct {
    stdout: []u8,
    stderr: []u8,
    /// `childExitCode`: negative = killed by that signal.
    code: i32,

    fn deinit(self: Ran) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }

    fn has(self: Ran, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.stdout, needle) != null;
    }
};

/// Wrap `cmd` and run the argv directly (no outer shell), so the exit
/// status is the wrapper's own.
fn runWrapped(cmd: []const u8, opts: WrapOptions) !Ran {
    const alloc = testing.allocator;
    const r = try wrapCommand(alloc, cmd, opts);
    if (r != .wrapped) return error.TestExpectedWrapped;
    var wc = r.wrapped;
    defer wc.deinit();
    try testing.expectEqual(Backend.bwrap, wc.backend);
    try testing.expect(wc.profile_path == null);
    return captureWrapped(&wc);
}

fn captureWrapped(wc: *const WrappedCommand) !Ran {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = try arena.alloc(?[*:0]const u8, wc.argv.len + 1);
    for (wc.argv, 0..) |a, i| argv[i] = (try arena.dupeZ(u8, a)).ptr;
    argv[wc.argv.len] = null;
    const out = try pprocess.capture(argv, alloc, .{ .timeout_ms = RUN_SHELL_TIMEOUT_MS });
    return .{ .stdout = out.stdout, .stderr = out.stderr, .code = wc.childExitCode(out.exit_code) };
}

/// A scratch tree outside every temp root (`testing.tmpDir` lives in the
/// build's cache directory), so only what the sandbox grants is writable.
const Tree = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,
    join_buf: [4][std.fs.max_path_bytes]u8 = undefined,
    join_next: usize = 0,

    fn init(self: *Tree) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}) };
        self.root_len = try self.tmp.dir.realPath(testing.io, &self.root_buf);
        try testing.expect(!std.mem.startsWith(u8, self.root(), "/tmp/"));
    }

    fn deinit(self: *Tree) void {
        self.tmp.cleanup();
    }

    fn root(self: *const Tree) []const u8 {
        return self.root_buf[0..self.root_len];
    }

    /// `<root>/<rel>`, valid until four more calls.
    fn path(self: *Tree, rel: []const u8) [:0]const u8 {
        const buf = &self.join_buf[self.join_next % self.join_buf.len];
        self.join_next += 1;
        return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ self.root(), rel }) catch unreachable;
    }
};

test "bwrap L2: a command writes inside the workspace and nowhere outside it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // comptime: keeps the body off other targets
    try requireBwrap();
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    try t.tmp.dir.createDirPath(testing.io, "ws");
    try t.tmp.dir.createDirPath(testing.io, "outside");
    try t.tmp.dir.createDirPath(testing.io, "extra");

    const sb = config_mod.SandboxSettings{ .enabled = true };
    const cmd = try std.fmt.allocPrint(testing.allocator,
        \\echo in > ok.txt && echo INSIDE_OK
        \\(echo x > {s}) 2>/dev/null && echo OUTSIDE_BAD || echo OUTSIDE_BLOCKED
        \\(echo x > {s}) 2>/dev/null && echo EXTRA_OK || echo EXTRA_BLOCKED
        \\(echo x > /tmp/cc-zig-bwrap-tmp-$$ && rm /tmp/cc-zig-bwrap-tmp-$$) 2>/dev/null && echo TMP_OK || echo TMP_BLOCKED
        \\(echo x > /etc/cc-zig-bwrap-etc) 2>/dev/null && echo ETC_BAD || echo ETC_BLOCKED
    , .{ t.path("outside/bad.txt"), t.path("extra/in.txt") });
    defer testing.allocator.free(cmd);
    const extra = try testing.allocator.dupe(u8, t.path("extra"));
    defer testing.allocator.free(extra);
    const ran = try runWrapped(cmd, .{ .cwd = t.path("ws"), .home = "/nonexistent-home", .sandbox = &sb, .additional_dirs = &.{extra} });
    defer ran.deinit();
    errdefer std.debug.print("stdout={s}\nstderr={s}\n", .{ ran.stdout, ran.stderr });
    for ([_][]const u8{ "INSIDE_OK", "OUTSIDE_BLOCKED", "EXTRA_OK", "TMP_OK", "ETC_BLOCKED" }) |want| try testing.expect(ran.has(want));
    try testing.expect(pfs.exists(t.path("ws/ok.txt")));
    try testing.expect(pfs.exists(t.path("extra/in.txt")));
    try testing.expect(!pfs.exists(t.path("outside/bad.txt")));
}

test "bwrap L2: a symlink in the workspace pointing outside cannot carry a write out" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // comptime: keeps the body off other targets
    try requireBwrap();
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    try t.tmp.dir.createDirPath(testing.io, "ws");
    try t.tmp.dir.createDirPath(testing.io, "outside");
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/victim", .data = "original\n" });
    if (std.c.symlink(t.path("outside"), t.path("ws/escape")) != 0) return error.SkipZigTest;
    if (std.c.symlink(t.path("outside/victim"), t.path("ws/victim-link")) != 0) return error.SkipZigTest;
    // A write root that is itself a link is bound at its target: the link
    // names that directory, nothing wider.
    if (std.c.symlink(t.path("ws"), t.path("ws-link")) != 0) return error.SkipZigTest;

    const sb = config_mod.SandboxSettings{ .enabled = true };
    const ran = try runWrapped(
        \\(echo x > escape/new) 2>/dev/null && echo DIR_LINK_BAD || echo DIR_LINK_BLOCKED
        \\(echo x > victim-link) 2>/dev/null && echo FILE_LINK_BAD || echo FILE_LINK_BLOCKED
        \\(ln -s ../outside made && echo x > made/new2) 2>/dev/null && echo NEW_LINK_BAD || echo NEW_LINK_BLOCKED
        \\(echo y > via-link.txt) && echo LINKED_ROOT_OK
    , .{ .cwd = t.path("ws-link"), .sandbox = &sb });
    defer ran.deinit();
    errdefer std.debug.print("stdout={s}\nstderr={s}\n", .{ ran.stdout, ran.stderr });
    for ([_][]const u8{ "DIR_LINK_BLOCKED", "FILE_LINK_BLOCKED", "NEW_LINK_BLOCKED", "LINKED_ROOT_OK" }) |want| try testing.expect(ran.has(want));
    try testing.expect(!pfs.exists(t.path("outside/new")));
    try testing.expect(!pfs.exists(t.path("outside/new2")));
    try testing.expect(pfs.exists(t.path("ws/via-link.txt")));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("original", readSmall(t.path("outside/victim"), &buf).?);
}

test "bwrap L2: denyRead hides a directory and a file; denyWrite protects an existing and a future path" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // comptime: keeps the body off other targets
    try requireBwrap();
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    try t.tmp.dir.createDirPath(testing.io, "home/.ssh");
    try t.tmp.dir.createDirPath(testing.io, "ws/locked");
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "home/.ssh/id_test", .data = "SSH_SECRET_9c1\n" });
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "home/.netrc", .data = "NETRC_SECRET_4b2\n" });
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "home/visible", .data = "VISIBLE_7d3\n" });
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "ws/.env", .data = "ENV_ORIGINAL\n" });

    const home = try testing.allocator.dupe(u8, t.path("home"));
    defer testing.allocator.free(home);
    const sb = config_mod.SandboxSettings{
        .enabled = true,
        .deny_read = &.{ "~/.ssh", "~/.netrc" },
        .deny_write = &.{ ".env", "locked/not-yet/out.bin" },
    };
    const cmd = try std.fmt.allocPrint(testing.allocator,
        \\cat {s}/.ssh/id_test 2>/dev/null; ls {s}/.ssh; cat {s}/.netrc 2>/dev/null; cat {s}/visible
        \\(echo x > .env) 2>/dev/null && echo ENV_BAD || echo ENV_BLOCKED
        \\(mkdir -p locked/not-yet && echo x > locked/not-yet/out.bin) 2>/dev/null && echo FUTURE_BAD || echo FUTURE_BLOCKED
        \\(echo x > free.txt) && echo FREE_OK
    , .{ home, home, home, home });
    defer testing.allocator.free(cmd);
    const ran = try runWrapped(cmd, .{ .cwd = t.path("ws"), .home = home, .sandbox = &sb });
    defer ran.deinit();
    errdefer std.debug.print("stdout={s}\nstderr={s}\n", .{ ran.stdout, ran.stderr });
    try testing.expect(!ran.has("SSH_SECRET"));
    try testing.expect(!ran.has("id_test"));
    try testing.expect(!ran.has("NETRC_SECRET"));
    try testing.expect(ran.has("VISIBLE_7d3"));
    try testing.expect(ran.has("ENV_BLOCKED"));
    try testing.expect(ran.has("FUTURE_BLOCKED"));
    try testing.expect(ran.has("FREE_OK"));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("ENV_ORIGINAL", readSmall(t.path("ws/.env"), &buf).?);
    try testing.expect(!pfs.exists(t.path("ws/locked/not-yet/out.bin")));
}

test "bwrap L2: a domain list leaves the command no network; without one the host's stays" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // comptime: keeps the body off other targets
    try requireBwrap();
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    const interfaces = "tail -n +3 /proc/net/dev | cut -d: -f1 | tr -d ' ' | sort | tr '\\n' ,; echo";
    const host_ifaces = try runShell(testing.allocator, interfaces);
    defer testing.allocator.free(host_ifaces);

    const allowed = [_][]const u8{"example.com"};
    const closed = config_mod.SandboxSettings{ .enabled = true, .allowed_domains = &allowed };
    try testing.expectEqual(bwrap_mod.Network.isolated, bwrapNetwork(&closed));
    const cmd = interfaces ++ "\n(exec 3<>/dev/tcp/1.1.1.1/53) 2>/dev/null && echo NET_OPEN || echo NET_CLOSED";
    const ran = try runWrapped(cmd, .{ .cwd = t.root(), .sandbox = &closed });
    defer ran.deinit();
    errdefer std.debug.print("stdout={s}\nstderr={s}\n", .{ ran.stdout, ran.stderr });
    try testing.expect(std.mem.startsWith(u8, ran.stdout, "lo,\n"));
    try testing.expect(ran.has("NET_CLOSED"));

    const open = config_mod.SandboxSettings{ .enabled = true };
    try testing.expectEqual(bwrap_mod.Network.shared, bwrapNetwork(&open));
    const shared = try runWrapped(interfaces, .{ .cwd = t.root(), .sandbox = &open });
    defer shared.deinit();
    try testing.expectEqualStrings(host_ifaces, shared.stdout);
}

test "bwrap L2: the exit code and a killing signal pass through" {
    if (builtin.os.tag != .linux) return error.SkipZigTest; // comptime: keeps the body off other targets
    try requireBwrap();
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    const sb = config_mod.SandboxSettings{ .enabled = true };
    const cases = [_]struct { cmd: []const u8, code: i32 }{
        .{ .cmd = "exit 0", .code = 0 },
        .{ .cmd = "exit 7", .code = 7 },
        .{ .cmd = "kill -TERM $$", .code = -15 },
        .{ .cmd = "kill -KILL $$", .code = -9 },
    };
    for (cases) |case| {
        const ran = try runWrapped(case.cmd, .{ .cwd = t.root(), .sandbox = &sb });
        defer ran.deinit();
        testing.expectEqual(case.code, ran.code) catch |err| {
            std.debug.print("cmd={s} stderr={s}\n", .{ case.cmd, ran.stderr });
            return err;
        };
    }
    // Through the shell-string form the Bash tool runs, the code is the
    // shell's: 128+N for a signal, as bash itself reports it.
    var w = (try wrapAsShellString(testing.allocator, "exit 7", .{ .cwd = t.root(), .sandbox = &sb })).?;
    defer w.deinit();
    try testing.expect(w.profile_path == null);
    const cmd_z = try testing.allocator.dupeZ(u8, w.command);
    defer testing.allocator.free(cmd_z);
    var argv = [_]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null };
    const out = try pprocess.capture(&argv, testing.allocator, .{ .timeout_ms = RUN_SHELL_TIMEOUT_MS });
    defer testing.allocator.free(out.stdout);
    defer testing.allocator.free(out.stderr);
    try testing.expectEqual(@as(i32, 7), out.exit_code);
}

test "bwrap L2: a bwrap that is missing, relative or cannot sandbox fails closed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const saved: ?[:0]u8 = if (ppaths.bwrapEnv()) |v| try testing.allocator.dupeZ(u8, v) else null;
    defer if (saved) |v| testing.allocator.free(v);
    defer if (saved) |v| ppaths.setEnv("METACODES_BWRAP", v.ptr) else ppaths.unsetEnv("METACODES_BWRAP");

    const strict = config_mod.SandboxSettings{ .enabled = true, .fail_if_unavailable = true };
    const lax = config_mod.SandboxSettings{ .enabled = true };
    const cases = [_]struct { value: [*:0]const u8, want: bwrap_mod.Availability }{
        .{ .value = "/nonexistent-cc-zig/bwrap", .want = .missing },
        .{ .value = "relative/bwrap", .want = .override_not_absolute },
        // A real executable that is not bwrap: located, but the probe fails.
        .{ .value = "/bin/false", .want = .probe_failed },
    };
    for (cases) |case| {
        ppaths.setEnv("METACODES_BWRAP", case.value);
        try testing.expectEqual(case.want, bwrap_mod.availability());
        try testing.expect(!hostSupported());
        try testing.expectEqual(Plan.unavailable, plan(&strict, "touch x", false));
        try testing.expectError(error.SandboxUnavailable, wrapAsShellString(testing.allocator, "touch x", .{ .cwd = "/", .sandbox = &strict }));
        const r = try wrapCommand(testing.allocator, "touch x", .{ .cwd = "/", .sandbox = &strict });
        try testing.expect(r == .unavailable);
        // failIfUnavailable=false runs it bare, and says so: not `.sandboxed`,
        // so autoAllowBashIfSandboxed does not apply.
        try testing.expectEqual(Plan.passthrough, plan(&lax, "touch x", false));
    }
}

// Independent syscall numbers in the kernel-facing consumer keep these tests
// from merely restating the generator's std.os.linux enum/table lookups.
const seccomp_probe =
    \\import array, ctypes, errno, os, platform, socket, subprocess, sys, threading
    \\libc = ctypes.CDLL(None, use_errno=True)
    \\libc.syscall.restype = ctypes.c_long
    \\arm = platform.machine() == 'aarch64'
    \\def raw(nr, *args):
    \\    ctypes.set_errno(0)
    \\    result = libc.syscall(ctypes.c_long(nr), *[ctypes.c_long(v) for v in (args + (0,)*6)[:6]])
    \\    return result, ctypes.get_errno()
    \\def denied(nr, *args):
    \\    result, err = raw(nr, *args)
    \\    assert (result, err) == (-1, errno.EPERM), (nr, result, err)
    \\for nr in ([117, 270, 271, 280, 241, 282, 97, 268, 40, 39, 41, 51] if arm else
    \\           [101, 310, 311, 321, 298, 323, 272, 308, 165, 166, 155, 161]):
    \\    denied(nr)
    \\for nr in [425, 426, 427, 428, 429, 430, 431, 432, 433, 438, 442]:
    \\    denied(nr)
    \\# Even invalid fds/arguments yield policy EPERM, before kernel validation.
    \\denied(29 if arm else 16, -1, 0x5412)
    \\denied(29 if arm else 16, -1, 0x10000541c)
    \\for flag in [0x80, 0x20000, 0x2000000, 0x4000000, 0x8000000, 0x10000000, 0x20000000, 0x40000000]:
    \\    denied(220 if arm else 56, flag | 17)
    \\assert raw(435) == (-1, errno.ENOSYS)
    \\for nr in [198 if arm else 41, 199 if arm else 53]:
    \\    denied(nr, 40, 1) # AF_VSOCK, including socketpair
    \\    denied(nr, 0x100000028, 1) # kernel truncates domain to int
    \\denied(199 if arm else 53, 1, 2) # AF_UNIX SOCK_DGRAM pairs can target host paths
    \\isolated = sys.argv[1] == 'isolated'
    \\for family in [1, 16, 17, 31]:
    \\    denied(198 if arm else 41, family, 1)
    \\if isolated:
    \\    for family in [2, 10, 16, 17, 31]:
    \\        denied(198 if arm else 41, family, 1)
    \\else:
    \\    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    \\        s.bind(('127.0.0.1', 0)); s.listen()
    \\        with socket.create_connection(s.getsockname()) as c:
    \\            conn, _ = s.accept()
    \\            with conn:
    \\                c.sendall(b'tcp'); assert conn.recv(3) == b'tcp'
;

const seccomp_probe_ipc =
    \\a, b = socket.socketpair()
    \\with a, b:
    \\    a.sendall(b'local'); assert b.recv(5) == b'local'
    \\# The filesystem helper receives file descriptors over a connected pair.
    \\a, b = socket.socketpair()
    \\with a, b, open('rights-%d.txt' % os.getpid(), 'w+') as f:
    \\    f.write('descriptor'); f.flush(); f.seek(0)
    \\    receiver = '''import array, os, socket, sys
    \\s = socket.socket(fileno=int(sys.argv[1]))
    \\data, anc, flags, addr = s.recvmsg(1, socket.CMSG_SPACE(array.array('i').itemsize))
    \\assert data == b'f' and len(anc) == 1
    \\level, kind, payload = anc[0]
    \\assert (level, kind) == (socket.SOL_SOCKET, socket.SCM_RIGHTS)
    \\fds = array.array('i'); fds.frombytes(payload[:fds.itemsize])
    \\assert os.read(fds[0], 10) == b'descriptor'
    \\os.close(fds[0]); s.sendmsg([b'ok']); s.close()
    \\'''
    \\    child = subprocess.Popen(['/usr/bin/python3', '-c', receiver, str(b.fileno())], pass_fds=(b.fileno(),))
    \\    a.sendmsg([b'f'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [f.fileno()]))])
    \\    assert a.recvmsg(2)[0] == b'ok'; assert child.wait() == 0
    \\with open('ordinary-%d.txt' % os.getpid(), 'w+') as f:
    \\    f.write('read/write works'); f.seek(0); assert f.read() == 'read/write works'
    \\assert libc.prctl(21, 0, 0, 0, 0) == 2 # PR_GET_SECCOMP
    \\assert libc.prctl(39, 0, 0, 0, 0) == 1 # PR_GET_NO_NEW_PRIVS
    \\assert libc.prctl(38, 0, 0, 0, 0) == -1 # cannot undo no_new_privs
    \\for fd in [8, 9]:
    \\    try: os.fstat(fd)
    \\    except OSError as e: assert e.errno == errno.EBADF
    \\    else: raise AssertionError('launcher fd leaked')
    \\done = []
    \\def worker():
    \\    denied(425); done.append(True)
    \\thread = threading.Thread(target=worker)
    \\thread.start(); thread.join(); assert done == [True]
    \\if len(sys.argv) < 3:
    \\    subprocess.check_call(['/usr/bin/python3', __file__, sys.argv[1], 'child'])
    \\    print('PARENT_FILTER_OK')
    \\else:
    \\    print('EXEC_CHILD_FILTER_OK')
;

test "bwrap L2 seccomp: kernel denials, inherited filter, ordinary IO and network variants" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try requireBwrap();
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    // Each child runs the same independent syscall consumer after exec.
    const script = seccomp_probe ++ "\n" ++ seccomp_probe_ipc;
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "probe.py", .data = script });
    for ([_]bool{ false, true }) |isolated| {
        const sb = config_mod.SandboxSettings{ .enabled = true, .allowed_domains = if (isolated) &.{"example.invalid"} else &.{} };
        const ran = try runWrapped(if (isolated) "python3 probe.py isolated" else "python3 probe.py shared", .{ .cwd = t.root(), .sandbox = &sb });
        defer ran.deinit();
        errdefer std.debug.print("stdout={s}\nstderr={s}\n", .{ ran.stdout, ran.stderr });
        try testing.expectEqual(@as(i32, 0), ran.code);
        try testing.expect(ran.has("PARENT_FILTER_OK"));
        try testing.expect(ran.has("EXEC_CHILD_FILTER_OK"));
    }
}

test "bwrap L2 seccomp: x32 and foreign audit ABI die in the kernel" {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    try requireBwrap();
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    const sb = config_mod.SandboxSettings{ .enabled = true };
    const ran = try runWrapped(
        \\python3 - <<'PY'
        \\import ctypes, mmap, os, resource, signal
        \\resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        \\for machine_code in [
        \\    bytes.fromhex('b8270000400f05c3'), # x32 getpid
        \\    bytes.fromhex('b8000200000f05c3'), # legacy untagged x32 nr 512
        \\    bytes.fromhex('b814000000cd80c3'), # i386 getpid via int 0x80
        \\]:
        \\    pid = os.fork()
        \\    if pid == 0:
        \\        page = mmap.mmap(-1, 4096, prot=mmap.PROT_READ | mmap.PROT_WRITE | mmap.PROT_EXEC)
        \\        page.write(machine_code)
        \\        fn = ctypes.CFUNCTYPE(ctypes.c_long)(ctypes.addressof(ctypes.c_char.from_buffer(page)))
        \\        fn(); os._exit(99)
        \\    _, status = os.waitpid(pid, 0)
        \\    assert os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGSYS, status
        \\print('ABI_GUARD_OK')
        \\PY
    , .{ .cwd = t.root(), .sandbox = &sb });
    defer ran.deinit();
    errdefer std.debug.print("stdout={s}\nstderr={s}\n", .{ ran.stdout, ran.stderr });
    try testing.expectEqual(@as(i32, 0), ran.code);
    try testing.expect(ran.has("ABI_GUARD_OK"));
}

fn agentFilterCount() !u32 {
    const fd = try pfs.openZ("/proc/self/status", .{ .ACCMODE = .RDONLY }, 0);
    defer _ = pfs.close(fd);
    var buf: [8192]u8 = undefined;
    const n = try pfs.readZ(fd, &buf);
    const key = "Seccomp_filters:\t";
    const start = (std.mem.indexOf(u8, buf[0..n], key) orelse return error.MissingSeccompStatus) + key.len;
    return std.fmt.parseInt(u32, std.mem.sliceTo(buf[start..n], '\n'), 10);
}

test "bwrap L2 seccomp: compiler and child exec work without filtering the agent" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try requireBwrap();
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    const before = try agentFilterCount();
    const sb = config_mod.SandboxSettings{ .enabled = true };
    const ran = try runWrapped(
        \\export PATH=/usr/bin:/bin
        \\printf '#include <stdio.h>\nint main(void) { puts("COMPILED_OK"); return 0; }\n' > main.c
        \\/usr/bin/cc main.c -o program && ./program
    , .{ .cwd = t.root(), .sandbox = &sb });
    defer ran.deinit();
    errdefer std.debug.print("stdout={s}\nstderr={s}\n", .{ ran.stdout, ran.stderr });
    try testing.expectEqual(@as(i32, 0), ran.code);
    try testing.expect(ran.has("COMPILED_OK"));
    try testing.expectEqual(before, try agentFilterCount());
}

test "bwrap L2 seccomp: detached shell carries its filter without files or parent fds" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try requireBwrap();
    const alloc = testing.allocator;
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    const sb = config_mod.SandboxSettings{ .enabled = true };
    const opts = WrapOptions{ .cwd = t.root(), .sandbox = &sb };
    var wc = (try wrapCommand(alloc, "true", opts)).wrapped;
    wc.deinit(); // Unused wrapper owns only memory, no filesystem/fd resource.

    var shell = (try wrapAsShellString(alloc,
        \\python3 - <<'PY'
        \\import ctypes, errno
        \\libc = ctypes.CDLL(None, use_errno=True)
        \\assert libc.syscall(425, 0, 0) == -1 and ctypes.get_errno() == errno.EPERM
        \\print('DETACHED_FILTER_OK')
        \\PY
    , opts)).?;
    const command = try alloc.dupe(u8, shell.command);
    defer alloc.free(command);
    try testing.expect(shell.profile_path == null);
    shell.detached = true;
    shell.deinit(); // Before launcher startup, exercising the spawn race.
    const stdout = try runShell(alloc, command);
    defer alloc.free(stdout);
    try testing.expect(std.mem.indexOf(u8, stdout, "DETACHED_FILTER_OK") != null);
    var input_wrap = (try wrapAsShellString(alloc, "IFS= read -r line; [ \"$line\" = STDIN_OK ] && echo STDIN_PRESERVED", opts)).?;
    defer input_wrap.deinit();
    const piped = try std.fmt.allocPrint(alloc, "printf 'STDIN_OK\\n' | {s}", .{input_wrap.command});
    defer alloc.free(piped);
    const input_stdout = try runShell(alloc, piped);
    defer alloc.free(input_stdout);
    try testing.expect(std.mem.indexOf(u8, input_stdout, "STDIN_PRESERVED") != null);
}

test "bwrap L2 seccomp: empty or corrupt delivery refuses to run payload" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try requireBwrap();
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    const sb = config_mod.SandboxSettings{ .enabled = true };
    for ([_]bool{ false, true }) |corrupt| {
        var wc = (try wrapCommand(testing.allocator, "touch PAYLOAD_RAN", .{ .cwd = t.root(), .sandbox = &sb })).wrapped;
        defer wc.deinit();
        // Replace only the BPF producer's positional argument. No valid
        // filter => bwrap must fail rather than execute the payload bare.
        const args: [][]const u8 = @constCast(wc.argv);
        const bad = try testing.allocator.dupe(u8, if (corrupt) "\\0001\\0002\\0003" else "");
        testing.allocator.free(args[4]);
        args[4] = bad;
        const ran = try captureWrapped(&wc);
        defer ran.deinit();
        try testing.expect(ran.code != 0);
        try testing.expect(!pfs.exists(t.path("PAYLOAD_RAN")));
    }
}

test "bwrap L2 seccomp: readable host Unix listeners cannot bypass mount protection" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try requireBwrap();
    const alloc = testing.allocator;
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "unix-child.py", .data =
        \\import errno, os, socket
        \\assert os.path.exists('host.sock') and os.path.exists('host.dgram')
        \\for kind, name in [(socket.SOCK_STREAM, 'host.sock'), (socket.SOCK_DGRAM, 'host.dgram')]:
        \\    try:
        \\        with socket.socket(socket.AF_UNIX, kind) as s:
        \\            s.connect(name); s.sendall(b'ESCAPED')
        \\    except OSError as e:
        \\        assert e.errno == errno.EPERM, e
        \\    else:
        \\        raise AssertionError('host listener reached')
        \\# A connected datagram pair is NOT safe: it can address a host path.
        \\try:
        \\    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        \\except OSError as e:
        \\    assert e.errno == errno.EPERM, e
        \\else:
        \\    a.sendto(b'ESCAPED', 'host.dgram'); raise AssertionError('datagram pair escaped')
        \\for kind in [socket.SOCK_STREAM, socket.SOCK_SEQPACKET]:
        \\    a, b = socket.socketpair(socket.AF_UNIX, kind)
        \\    with a, b:
        \\        try: a.connect('host.sock')
        \\        except OSError: pass
        \\        else: raise AssertionError('connected pair retargeted')
        \\        try: a.sendmsg([b'ESCAPED'], [], 0, 'host.sock')
        \\        except OSError: pass
        \\        else: assert b.recv(7) == b'ESCAPED' # SEQPACKET ignores the address
        \\print('UNIX_HOST_BLOCKED')
    });
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "unix-host.py", .data =
        \\import json, os, socket, subprocess, sys
        \\os.chdir(os.path.dirname(__file__))
        \\with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream, socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as dgram:
        \\    stream.bind('host.sock'); stream.listen(); stream.settimeout(0.1)
        \\    dgram.bind('host.dgram'); dgram.settimeout(0.1)
        \\    # Confirm that both host endpoints work before testing confinement.
        \\    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as control:
        \\        control.connect('host.sock')
        \\        accepted, _ = stream.accept(); accepted.close()
        \\    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as control:
        \\        control.sendto(b'control', 'host.dgram'); assert dgram.recv(7) == b'control'
        \\    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        \\    with a, b:
        \\        a.sendto(b'pair bypass', 'host.dgram'); assert dgram.recv(20) == b'pair bypass'
        \\    argv = json.load(open(sys.argv[1]))
        \\    result = subprocess.run(argv, capture_output=True, timeout=10)
        \\    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
        \\    assert b'UNIX_HOST_BLOCKED' in result.stdout
        \\    for listener in [stream, dgram]:
        \\        try:
        \\            if listener is stream: listener.accept()
        \\            else: listener.recv(100)
        \\        except TimeoutError:
        \\            pass
        \\        else:
        \\            raise AssertionError('sandbox reached host listener')
        \\    for fd in [8, 9]:
        \\        os.dup2(0, fd)
        \\        collision = subprocess.run(argv, capture_output=True, pass_fds=(fd,), timeout=10)
        \\        assert collision.returncode == 125 and b'reserved' in collision.stderr, collision
        \\        os.close(fd)
        \\os.unlink('host.sock'); os.unlink('host.dgram')
        \\print('HOST_LISTENERS_UNREACHED')
    });
    for ([_]bool{ false, true }) |isolated| {
        const sb = config_mod.SandboxSettings{ .enabled = true, .allowed_domains = if (isolated) &.{"example.invalid"} else &.{} };
        var wc = (try wrapCommand(alloc, "/usr/bin/python3 unix-child.py", .{ .cwd = t.root(), .sandbox = &sb })).wrapped;
        defer wc.deinit();
        const json = try std.json.Stringify.valueAlloc(alloc, wc.argv, .{});
        defer alloc.free(json);
        try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "unix-argv.json", .data = json });
        const host_script = try alloc.dupeZ(u8, t.path("unix-host.py"));
        defer alloc.free(host_script);
        const argv = [_]?[*:0]const u8{ "/usr/bin/python3", host_script.ptr, "unix-argv.json", null };
        const out = try pprocess.capture(&argv, alloc, .{ .timeout_ms = RUN_SHELL_TIMEOUT_MS });
        defer alloc.free(out.stdout);
        defer alloc.free(out.stderr);
        errdefer std.debug.print("host stdout={s}\nhost stderr={s}\n", .{ out.stdout, out.stderr });
        try testing.expectEqual(@as(i32, 0), out.exit_code);
        try testing.expect(std.mem.indexOf(u8, out.stdout, "HOST_LISTENERS_UNREACHED") != null);
    }
}

test "bwrap L2 seccomp: availability rejects a backend without filter support" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var t: Tree = undefined;
    try t.init();
    defer t.deinit();
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "legacy-bwrap", .data =
        \\#!/bin/sh
        \\# Simulate a legacy backend: namespace options work, --seccomp does not.
        \\for arg do
        \\    [ "$arg" != --seccomp ] || exit 64
        \\done
        \\exit 0
        \\
    });
    const executable = t.path("legacy-bwrap");
    try testing.expectEqual(@as(c_int, 0), pfs.chmod(executable, 0o755));
    const saved: ?[:0]u8 = if (ppaths.bwrapEnv()) |v| try testing.allocator.dupeZ(u8, v) else null;
    defer if (saved) |v| testing.allocator.free(v);
    defer if (saved) |v| ppaths.setEnv("METACODES_BWRAP", v.ptr) else ppaths.unsetEnv("METACODES_BWRAP");
    ppaths.setEnv("METACODES_BWRAP", executable);
    try testing.expectEqual(bwrap_mod.Availability.probe_failed, bwrap_mod.availability());
    const strict = config_mod.SandboxSettings{ .enabled = true, .fail_if_unavailable = true };
    try testing.expectEqual(Plan.unavailable, plan(&strict, "true", false));
    try testing.expectError(error.SandboxUnavailable, wrapAsShellString(testing.allocator, "true", .{ .cwd = t.root(), .sandbox = &strict }));
}
