//! 把 Bash 命令包进 macOS Seatbelt 沙箱。
//!
//! 入口:wrapCommand(alloc, cmd, opts) → ?WrappedCommand
//!   返回 null = 不沙箱(disabled / 平台不支持 / excludedCommand / 逃生口)
//!   返回 WrappedCommand = 用 sandbox-exec 包裹后的 argv + profile 临时文件路径
//!
//! sandbox-exec 调用形式:
//!   sandbox-exec -f <profile_file> /bin/bash -c "<cmd>"
//! (用 -f 文件而非 -p inline,避免超长 profile 命令行截断)
//!
//! 只在 macOS 生效(builtin.os.tag == .macos)。其它平台返回 null(暂不实现 bubblewrap)。

const std = @import("std");
const pprocess = @import("platform").process;
const pfs = @import("platform").fs;
const builtin = @import("builtin");
const profile_mod = @import("profile.zig");
const config_mod = @import("config.zig");

pub const WrappedCommand = struct {
    /// argv(以 NUL 结尾的指针数组由 caller 构造;这里给 []const []const u8)
    argv: []const []const u8,
    /// 临时 profile 文件路径(caller 在子进程结束后 unlink + free)
    profile_path: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WrappedCommand) void {
        // 删临时 profile 文件
        var pz: [std.fs.max_path_bytes]u8 = undefined;
        if (self.profile_path.len < pz.len) {
            @memcpy(pz[0..self.profile_path.len], self.profile_path);
            pz[self.profile_path.len] = 0;
            _ = std.c.unlink(@ptrCast(&pz));
        }
        for (self.argv) |a| self.allocator.free(a);
        self.allocator.free(self.argv);
        self.allocator.free(self.profile_path);
    }
};

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

/// 决定是否 / 如何沙箱化一条 bash 命令。
pub fn wrapCommand(alloc: std.mem.Allocator, cmd: []const u8, opts: WrapOptions) !WrapResult {
    const sb = opts.sandbox;

    // 1. 未启用 / 单次禁用 → passthrough
    if (!sb.enabled or opts.disable_for_this_command) return .passthrough;

    // 2. 非 macOS → 暂不支持(passthrough;Linux bubblewrap 留待 C.2)
    if (builtin.os.tag != .macos) {
        if (sb.fail_if_unavailable) return .unavailable;
        return .passthrough;
    }

    // 3. sandbox-exec 不存在 → unavailable / passthrough
    if (!sandboxExecAvailable()) {
        if (sb.fail_if_unavailable) return .unavailable;
        return .passthrough;
    }

    // 4. excludedCommands:命令首 token 命中 → passthrough
    const head = firstToken(cmd);
    if (sb.isExcludedCommand(head)) return .passthrough;

    // 5. 生成 profile
    const prof = try profile_mod.generate(alloc, .{
        .cwd = opts.cwd,
        .home = opts.home,
        .allow_write = sb.allow_write,
        .deny_write = sb.deny_write,
        .allow_read = sb.allow_read,
        .deny_read = sb.deny_read,
        .main_git_dir = opts.main_git_dir,
        .additional_dirs = opts.additional_dirs,
    });
    defer alloc.free(prof);

    // 6. 写临时 profile 文件
    const prof_path = try writeTempProfile(alloc, prof);
    errdefer {
        var pz: [std.fs.max_path_bytes]u8 = undefined;
        if (prof_path.len < pz.len) {
            @memcpy(pz[0..prof_path.len], prof_path);
            pz[prof_path.len] = 0;
            _ = std.c.unlink(@ptrCast(&pz));
        }
        alloc.free(prof_path);
    }

    // 7. 构造 argv: sandbox-exec -f <profile> /bin/bash -c <cmd>
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv.items) |a| alloc.free(a);
        argv.deinit(alloc);
    }
    try argv.append(alloc, try alloc.dupe(u8, "/usr/bin/sandbox-exec"));
    try argv.append(alloc, try alloc.dupe(u8, "-f"));
    try argv.append(alloc, try alloc.dupe(u8, prof_path));
    try argv.append(alloc, try alloc.dupe(u8, "/bin/bash"));
    try argv.append(alloc, try alloc.dupe(u8, "-c"));
    try argv.append(alloc, try alloc.dupe(u8, cmd));

    return .{ .wrapped = .{
        .argv = try argv.toOwnedSlice(alloc),
        .profile_path = prof_path,
        .allocator = alloc,
    } };
}

/// sandbox-exec 是否存在?
fn sandboxExecAvailable() bool {
    return std.c.access("/usr/bin/sandbox-exec", std.c.F_OK) == 0;
}

/// 命令首 token(到第一个空白)。
fn firstToken(cmd: []const u8) []const u8 {
    const t = std.mem.trim(u8, cmd, " \t");
    const sp = std.mem.indexOfAny(u8, t, " \t") orelse return t;
    return t[0..sp];
}

/// 字符串级包裹:返回可直接喂 `/bin/sh -c <ret.command>` 的命令串。
///
/// 形式: /usr/bin/sandbox-exec -f '<profile>' /bin/bash -c '<original-cmd>'
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
            const w = wc;
            const q_prof = try shellSingleQuote(alloc, w.profile_path);
            defer alloc.free(q_prof);
            const q_cmd = try shellSingleQuote(alloc, cmd);
            defer alloc.free(q_cmd);
            const shell = try std.fmt.allocPrint(alloc, "/usr/bin/sandbox-exec -f {s} /bin/bash -c {s}", .{ q_prof, q_cmd });
            // 释放 argv 但保留 profile 文件(deinit 会 unlink,这里不调)
            for (w.argv) |a| alloc.free(a);
            alloc.free(w.argv);
            return ShellWrap{ .command = shell, .profile_path = w.profile_path, .allocator = alloc };
        },
    }
}

pub const ShellWrap = struct {
    command: []const u8,
    profile_path: []const u8,
    allocator: std.mem.Allocator,
    /// detached:不删 profile 文件(后台作业场景——进程还在跑,profile 不能删)。
    detached: bool = false,

    /// 删 profile 文件 + free。前台命令执行完后调。
    pub fn deinit(self: *ShellWrap) void {
        if (!self.detached) {
            var pz: [std.fs.max_path_bytes]u8 = undefined;
            if (self.profile_path.len < pz.len) {
                @memcpy(pz[0..self.profile_path.len], self.profile_path);
                pz[self.profile_path.len] = 0;
                _ = std.c.unlink(@ptrCast(&pz));
            }
        }
        self.allocator.free(self.command);
        self.allocator.free(self.profile_path);
    }
};

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
    const tmpdir_raw = if (std.c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    // 去掉末尾 / ,统一用 fmt 的显式 / 拼
    const tmpdir = if (tmpdir_raw.len > 1 and tmpdir_raw[tmpdir_raw.len - 1] == '/')
        tmpdir_raw[0 .. tmpdir_raw.len - 1]
    else
        tmpdir_raw;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrint(&path_buf, "{s}/cczig_sb_{d}_{d}.sb\x00", .{ tmpdir, pid, n });
    const path = path_z[0 .. path_z.len - 1];

    const fd = pfs.open(@ptrCast(path_z.ptr), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.WriteProfileFailed;
    defer _ = pfs.close(fd);

    var written: usize = 0;
    while (written < content.len) {
        const n2 = pfs.write(fd, content[written..][0..content.len - written]);
        if (n2 <= 0) return error.WriteProfileFailed;
        written += @intCast(n2);
    }

    return try alloc.dupe(u8, path);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "wrapCommand: disabled → passthrough" {
    const sb = config_mod.SandboxSettings{ .enabled = false };
    const r = try wrapCommand(testing.allocator, "ls", .{ .cwd = "/tmp", .sandbox = &sb });
    try testing.expect(r == .passthrough);
}

test "wrapCommand: excluded command → passthrough" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
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

test "wrapAsShellString: failIfUnavailable on non-macos → error.SandboxUnavailable" {
    if (builtin.os.tag == .macos) return error.SkipZigTest; // macos 有 sandbox-exec,测不到 unavailable
    const sb = config_mod.SandboxSettings{ .enabled = true, .fail_if_unavailable = true };
    const r = wrapAsShellString(testing.allocator, "ls", .{ .cwd = "/tmp", .sandbox = &sb });
    try testing.expectError(error.SandboxUnavailable, r);
}

test "wrapAsShellString: failIfUnavailable=false on non-macos → null passthrough" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
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
    // profile 文件应已写入(用 std.c.access 检查存在)
    var pz: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(pz[0..wc.profile_path.len], wc.profile_path);
    pz[wc.profile_path.len] = 0;
    try testing.expect(std.c.access(@ptrCast(&pz), std.c.F_OK) == 0);
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
    _ = std.c.mkdir(@ptrCast(&dir_z), 0o755);
    defer _ = std.c.rmdir(@ptrCast(&dir_z));

    const sb = config_mod.SandboxSettings{ .enabled = true };
    // 命令:cwd 内写 OK;cwd 外(/private/tmp/cczig_sbe2e_OUTSIDE)写应被拦
    const cmd = try std.fmt.allocPrint(alloc,
        "echo in > {s}/ok.txt && echo INSIDE_OK; (echo x > /private/etc/cczig_hack_{d} 2>/dev/null && echo OUTSIDE_BAD || echo OUTSIDE_BLOCKED)",
        .{ dir, pid });
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
    _ = std.c.unlink(@ptrCast(ok_path.ptr));
}

/// 简易 `/bin/sh -c cmd` 捕获 stdout(测试用,复用 tools/common 的 spawn)。
fn runShell(alloc: std.mem.Allocator, cmd: []const u8) ![]u8 {
    const common = @import("../tools/common.zig");
    const cmd_z = try alloc.dupeZ(u8, cmd);
    defer alloc.free(cmd_z);
    const argv0: [*:0]const u8 = "/bin/sh";
    var argv: [4]?[*:0]const u8 = .{ argv0, "-c", cmd_z.ptr, null };
    const out = try common.spawnCaptureWithStderrTimed(argv[0..argv.len], alloc, null, 10_000, null, common.MAX_SPAWN_CAPTURE_BYTES);
    alloc.free(out.stderr);
    return out.stdout;
}
