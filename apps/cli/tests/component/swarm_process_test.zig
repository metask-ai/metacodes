//! L2 组件测试:SW6 进程外 teammate(单元/隔离面)。
//!  A CLI 解析:--teammate --agent-name/--team-name/--parent-session-id/--teammate-cwd → config。
//!  B worktree 隔离:createWorktree/removeWorktree 真 git(临时 repo)。
//! 交 key、--base-url 的用例经 forkExecTeammateAt 起真的 metacodes --teammate:fork 与 execve 之间
//! 子进程只做 async-signal-safe 调用,live MockServer 的线程不碍事。真 lead 起 teammate 的完整 e2e
//! 在 tests/tty/cases/test_teammate_process_route.py。

const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");
const harness = @import("harness");
const ppaths = @import("platform").paths;
const pfs = @import("platform").fs; // 可移植文件 IO(std.c.open 的 O 在 Windows 是 void)

const tp = cc.swarm_teammate_process;
const team = cc.swarm_team;
const swctx = cc.swarm_context;
const test_session = cc.session_id.SessionId.fromSlice("0123456789abcdef01234567").?;

// DI mock spawn:不真 fork,记录被传的 params + 返回假 pid。验证 lead-spawn 接线。
var g_mock_name: [64]u8 = undefined;
var g_mock_name_len: usize = 0;
var g_mock_cwd: [256]u8 = undefined;
var g_mock_cwd_len: usize = 0;
/// flag 按**字节**存,不存 slice:`extra_flags` 由 spawnTeammateProcess 在栈上组装,
/// 断言发生在它返回之后。今天元素恰好都是静态字面量所以存 slice 也不会崩,但那是巧合,
/// 不是契约——将来有人改成堆上拼的 flag,存 slice 的测试就读到已释放内存了。
var g_mock_flags: [16][128]u8 = undefined;
var g_mock_flag_lens: [16]usize = undefined;
var g_mock_flags_len: usize = 0;

fn mockSpawn(a: std.mem.Allocator, p: tp.SpawnProcessParams) anyerror!i64 {
    _ = a;
    g_mock_name_len = @min(p.name.len, g_mock_name.len);
    @memcpy(g_mock_name[0..g_mock_name_len], p.name[0..g_mock_name_len]);
    g_mock_cwd_len = @min(p.cwd.len, g_mock_cwd.len);
    @memcpy(g_mock_cwd[0..g_mock_cwd_len], p.cwd[0..g_mock_cwd_len]);
    g_mock_flags_len = @min(p.extra_flags.len, g_mock_flags.len);
    for (p.extra_flags[0..g_mock_flags_len], 0..) |f, i| {
        g_mock_flag_lens[i] = @min(f.len, g_mock_flags[i].len);
        @memcpy(g_mock_flags[i][0..g_mock_flag_lens[i]], f[0..g_mock_flag_lens[i]]);
    }
    return 99999; // 假 pid
}

fn mockSawFlag(needle: []const u8) bool {
    for (g_mock_flags[0..g_mock_flags_len], g_mock_flag_lens[0..g_mock_flags_len]) |*f, n| {
        if (std.mem.eql(u8, f[0..n], needle)) return true;
    }
    return false;
}

test "L2 SW6 D: 无 worktree base 时 lead-spawn 接线(登记 member=process + 追踪,mock fork)" {
    const a = std.testing.allocator;
    var home_buf: [256]u8 = undefined;
    const home = cc.util_fs.testing.uniqueDir(&home_buf, "cc-zig-sw6-spawn");
    defer cc.util_fs.testing.rmrfBestEffort(home);
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    try cc.util_fs.mkdirParents(team.teamDirPath(home, "proj", &dirbuf));
    var tf = team.TeamFile{ .allocator = a, .name = try a.dupe(u8, "proj"), .lead_agent_id = try a.dupe(u8, "team-lead@proj"), .lead_session_id = try a.dupe(u8, test_session.asSlice()) };
    defer tf.deinit();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    try team.save(a, &tf, team.configPath(home, "proj", &pbuf));

    var sw = swctx.SwarmContext{ .allocator = a, .session = test_session, .state_root = home, .team_sanitized = try a.dupe(u8, "proj") };
    // deinit 会 kill(99999)(无害:不存在的 pid)+ free。
    defer sw.deinit();

    g_mock_name_len = 0;
    const pid = try tp.spawnTeammateProcess(&sw, "worker", "", "", "", "", "0123456789abcdef01234567", null, &mockSpawn, true, .{});
    try std.testing.expectEqual(@as(i64, 99999), pid);
    // mock 收到 name。
    try std.testing.expectEqualStrings("worker", g_mock_name[0..g_mock_name_len]);
    // config 里登记了 process backend 成员。
    var cfg2: [std.fs.max_path_bytes]u8 = undefined;
    var back = team.load(a, team.configPath(home, "proj", &cfg2)) orelse return error.NoConfig;
    defer back.deinit();
    const m = back.findMember("worker") orelse return error.NoMember;
    try std.testing.expectEqualStrings("process", m.backend_type);
    try std.testing.expectEqualStrings(test_session.asSlice(), m.session_id.?);
    try std.testing.expect(m.lease_id != null);
    // 追踪表有记录(deinit 会清)。
    try std.testing.expectEqual(@as(usize, 1), sw.process_teammates.items.len);
    try std.testing.expectEqual(@as(i64, 99999), sw.process_teammates.items[0].pid);
}

test "L2 SW6 D2: 保留名 team-lead 不能 spawn 进程外" {
    const a = std.testing.allocator;
    var home_buf: [256]u8 = undefined;
    const home = cc.util_fs.testing.uniqueDir(&home_buf, "cc-zig-sw6-res");
    defer cc.util_fs.testing.rmrfBestEffort(home);
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    try cc.util_fs.mkdirParents(team.teamDirPath(home, "proj", &dirbuf));
    var tf = team.TeamFile{ .allocator = a, .name = try a.dupe(u8, "proj"), .lead_agent_id = try a.dupe(u8, "team-lead@proj"), .lead_session_id = try a.dupe(u8, test_session.asSlice()) };
    defer tf.deinit();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    try team.save(a, &tf, team.configPath(home, "proj", &pbuf));
    var sw = swctx.SwarmContext{ .allocator = a, .session = test_session, .state_root = home, .team_sanitized = try a.dupe(u8, "proj") };
    defer sw.deinit();
    try std.testing.expectError(error.ReservedName, tp.spawnTeammateProcess(&sw, "Team-Lead", "", "", "", "", "0123456789abcdef01234567", null, &mockSpawn, true, .{}));
}

test "L2 SW6: process teammate rejects a parent session different from swarm routing" {
    const a = std.testing.allocator;
    var home_buf: [256]u8 = undefined;
    const home = cc.util_fs.testing.uniqueDir(&home_buf, "cc-zig-sw6-session");
    defer cc.util_fs.testing.rmrfBestEffort(home);
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    try cc.util_fs.mkdirParents(team.teamDirPath(home, "proj", &dirbuf));
    var tf = team.TeamFile{ .allocator = a, .name = try a.dupe(u8, "proj"), .lead_agent_id = try a.dupe(u8, "team-lead@proj"), .lead_session_id = try a.dupe(u8, test_session.asSlice()) };
    defer tf.deinit();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    try team.save(a, &tf, team.configPath(home, "proj", &pbuf));
    var sw = swctx.SwarmContext{ .allocator = a, .session = test_session, .state_root = home, .team_sanitized = try a.dupe(u8, "proj") };
    defer sw.deinit();
    try std.testing.expectError(
        error.SessionMismatch,
        tp.spawnTeammateProcess(&sw, "worker", "", "", "", "", "fedcba987654321001234567", null, &mockSpawn, true, .{}),
    );
    var cfg: [std.fs.max_path_bytes]u8 = undefined;
    var after = team.load(a, team.configPath(home, "proj", &cfg)) orelse return error.NoConfig;
    defer after.deinit();
    try std.testing.expect(after.findMember("worker") == null);
}

test "L2 SW6 A: --teammate 身份 args 解析进 config" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{
        "metacodes",           "--teammate", "--agent-name",        "bob",    "--team-name",    "proj",
        "--parent-session-id", "sess9",      "--teammate-lease-id", "lease9", "--teammate-cwd", "/tmp/wt7",
    };
    const cfg = cc.parseArgsForTest(&argv, a);
    // 注:parseArgsForTest 用 arena/allocator dupe;这里 testing.allocator 会报泄漏若 dupe 未 free。
    // config 字符串归调用方——测试结束前 free。
    defer {
        if (cfg.teammate_name.len > 0) a.free(cfg.teammate_name);
        if (cfg.teammate_team.len > 0) a.free(cfg.teammate_team);
        if (cfg.teammate_parent_session.len > 0) a.free(cfg.teammate_parent_session);
        if (cfg.teammate_lease_id.len > 0) a.free(cfg.teammate_lease_id);
        if (cfg.teammate_cwd.len > 0) a.free(cfg.teammate_cwd);
    }
    try std.testing.expectEqualStrings("bob", cfg.teammate_name);
    try std.testing.expectEqualStrings("proj", cfg.teammate_team);
    try std.testing.expectEqualStrings("sess9", cfg.teammate_parent_session);
    try std.testing.expectEqualStrings("lease9", cfg.teammate_lease_id);
    try std.testing.expectEqualStrings("/tmp/wt7", cfg.teammate_cwd);
    try std.testing.expect(cfg.agent_teams); // --teammate 隐含开 teams
}

test "L2 SW6 B: worktree 隔离 create + remove(真 git)" {
    const a = std.testing.allocator;
    // 临时 git repo。
    var root_buf: [256]u8 = undefined;
    const root = cc.util_fs.testing.uniqueDir(&root_buf, "cc-zig-sw6-wt");
    defer cc.util_fs.testing.rmrfBestEffort(root);
    try cc.util_fs.mkdirParents(root);
    // git init + 一个 commit(worktree add 需至少一个 ref)。
    if (!runGit(a, root, &.{ "init", "-q" })) return error.SkipZigTest;
    _ = runGit(a, root, &.{ "config", "user.email", "t@t" });
    _ = runGit(a, root, &.{ "config", "user.name", "t" });
    // 建个文件 + commit。
    var fb: [200:0]u8 = undefined;
    const fp = try std.fmt.bufPrintZ(&fb, "{s}/README", .{root});
    const fd = pfs.open(fp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (fd >= 0) {
        _ = pfs.write(fd, "hi");
        pfs.close(fd);
    }
    _ = runGit(a, root, &.{ "add", "-A" });
    if (!runGit(a, root, &.{ "commit", "-q", "-m", "init" })) return error.SkipZigTest;

    // createWorktree(在 root 里跑 git;wt 路径在 root 外)。
    var wt_buf: [200]u8 = undefined;
    const wt = try std.fmt.bufPrint(&wt_buf, "{s}-wt", .{root});
    defer cc.util_fs.testing.rmrfBestEffort(wt);
    // git worktree 需在 repo 内执行——用 chdir。测试进程 chdir(单线程,安全)。
    var cwd_z: [200:0]u8 = undefined;
    @memcpy(cwd_z[0..root.len], root);
    cwd_z[root.len] = 0;
    const saved = savedCwd();
    _ = std.c.chdir(&cwd_z);
    defer restoreCwd(saved);

    tp.createWorktree(a, wt, "teammate-bob", "HEAD", root, null) catch return error.SkipZigTest;
    // worktree 目录存在(README 被 checkout)。
    var rb: [256:0]u8 = undefined;
    const rp = try std.fmt.bufPrintZ(&rb, "{s}/README", .{wt});
    try std.testing.expect(cc.platform_fs.exists(rp.ptr));
    // 锁定 worktree 会让单 --force 删除失败。严格 API 必须传播失败且
    // 保留磁盘事实，不能像旧 best-effort wrapper 一样虚报已清理。
    try std.testing.expect(runGit(a, root, &.{ "worktree", "lock", wt }));
    try std.testing.expectError(
        error.WorktreeRemoveFailed,
        tp.removeWorktreeStrict(a, wt, root, null),
    );
    try std.testing.expect(cc.platform_fs.exists(rp.ptr));
    try std.testing.expect(runGit(a, root, &.{ "worktree", "unlock", wt }));
    try tp.removeWorktreeStrict(a, wt, root, null);
    try std.testing.expect(!cc.platform_fs.exists(rp.ptr));
}

var cwd_save_buf: [std.fs.max_path_bytes]u8 = undefined;
fn savedCwd() []const u8 {
    const p = std.c.getcwd(&cwd_save_buf, cwd_save_buf.len) orelse return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}
fn restoreCwd(saved: []const u8) void {
    if (saved.len == 0) return;
    var z: [std.fs.max_path_bytes:0]u8 = undefined;
    if (saved.len >= z.len) return;
    @memcpy(z[0..saved.len], saved);
    z[saved.len] = 0;
    _ = std.c.chdir(&z);
}

fn runGit(a: std.mem.Allocator, cwd: []const u8, args: []const []const u8) bool {
    // 在 cwd 里跑 git（用 git -C <cwd>）。
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (argv.items) |it| if (it) |s| a.free(std.mem.span(s));
        argv.deinit(a);
    }
    argv.append(a, (a.dupeZ(u8, "/usr/bin/env") catch return false).ptr) catch return false;
    argv.append(a, (a.dupeZ(u8, "git") catch return false).ptr) catch return false;
    argv.append(a, (a.dupeZ(u8, "-C") catch return false).ptr) catch return false;
    argv.append(a, (a.dupeZ(u8, cwd) catch return false).ptr) catch return false;
    for (args) |ar| argv.append(a, (a.dupeZ(u8, ar) catch return false).ptr) catch return false;
    argv.append(a, null) catch return false;
    const common = cc.tools_common;
    const out = common.spawnCaptureWithStderrTimed(argv.items, a, null, 15_000, null, common.MAX_SPAWN_CAPTURE_BYTES, null) catch return false;
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    return out.exit_code == 0;
}

test "L2 SW6 F7: 进程外 teammate 先等死再收尸——已死收掉,存活拒删,terminate 不留僵尸" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX fork/waitpid
    const a = std.testing.allocator;
    var sw = swctx.SwarmContext{ .allocator = a, .state_root = "" };
    defer sw.deinit();

    // ① 立即退出的子进程:reap 应收尸并摘除记录(修 008 僵尸)。
    const dead_pid = std.c.fork();
    if (dead_pid == 0) std.c._exit(0);
    try std.testing.expect(dead_pid > 0);
    try sw.process_teammates.append(a, .{
        .pid = dead_pid,
        .session = test_session,
        .name = try a.dupe(u8, "dead"),
        .worktree_path = try a.dupe(u8, ""),
        .repo = try a.dupe(u8, ""),
    });
    cc.util_time.sleepMs(100); // 让子进程退净成 zombie
    try std.testing.expectEqual(@as(usize, 0), sw.reapDeadProcessTeammates());
    try std.testing.expectEqual(@as(usize, 0), sw.process_teammates.items.len);
    // 已收尸:再 waitpid 返 -1(ECHILD),无僵尸残留。
    var st: c_int = 0;
    try std.testing.expectEqual(@as(std.c.pid_t, -1), std.c.waitpid(dead_pid, &st, 1));

    // ② 长活子进程:reap 判存活(TeamDelete 会据此拒删);terminate 杀死+收尸,不留僵尸。
    const live_pid = std.c.fork();
    if (live_pid == 0) {
        // 子进程:睡等信号(默认 SIGTERM 动作=终止)。nanosleep 是 async-signal-safe。
        while (true) cc.util_time.sleepMs(1000);
    }
    try std.testing.expect(live_pid > 0);
    try sw.process_teammates.append(a, .{
        .pid = live_pid,
        .session = test_session,
        .name = try a.dupe(u8, "live"),
        .worktree_path = try a.dupe(u8, ""),
        .repo = try a.dupe(u8, ""),
    });
    try std.testing.expectEqual(@as(usize, 1), sw.reapDeadProcessTeammates()); // 存活
    sw.terminateProcessTeammates(2000); // SIGTERM → 等死 → 收尸
    try std.testing.expectEqual(@as(usize, 0), sw.process_teammates.items.len);
    try std.testing.expectEqual(@as(std.c.pid_t, -1), std.c.waitpid(live_pid, &st, 1));
}

test "L2: lead LSP and preview settings reach the teammate process" {
    // LSP 默认开之后,不透传就等于"lead 关了、teammate 照样起 language server"——逃生口
    // 在进程边界上漏掉,而进程外 teammate 恰恰是资源开销最该被尊重的地方。
    const a = std.testing.allocator;
    var home_buf: [256]u8 = undefined;
    const home = cc.util_fs.testing.uniqueDir(&home_buf, "cc-zig-sw6-nolsp");
    defer cc.util_fs.testing.rmrfBestEffort(home);
    const Features = cc.types_mod.PreviewFeatures;
    for ([_]struct { lsp: bool, preview: Features, flag: ?[]const u8 }{
        .{ .lsp = true, .preview = .none, .flag = null },
        .{ .lsp = true, .preview = .all, .flag = "--preview=execute_code,teamwork,comment_guard,background_watchdog,monitor_events" },
        .{ .lsp = false, .preview = .none, .flag = null },
        .{ .lsp = false, .preview = .{ .comment_guard = true }, .flag = "--preview=comment_guard" },
    }) |scenario| {
        // 每轮重建:lead 的 sw.deinit() 会做 orphan 清理删掉整个 team 目录。
        var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
        try cc.util_fs.mkdirParents(team.teamDirPath(home, "proj", &dirbuf));
        var tf = team.TeamFile{ .allocator = a, .name = try a.dupe(u8, "proj"), .lead_agent_id = try a.dupe(u8, "team-lead@proj"), .lead_session_id = try a.dupe(u8, test_session.asSlice()) };
        defer tf.deinit();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        try team.save(a, &tf, team.configPath(home, "proj", &pbuf));

        var sw = swctx.SwarmContext{ .allocator = a, .session = test_session, .state_root = home, .team_sanitized = try a.dupe(u8, "proj") };
        defer sw.deinit();
        sw.preview = scenario.preview;

        g_mock_flags_len = 0;
        _ = try tp.spawnTeammateProcess(&sw, "worker", "", "", "", "", "0123456789abcdef01234567", null, &mockSpawn, scenario.lsp, .{});
        // 两侧都断言:开着时不得平白多塞 flag,关着时必须带上。
        try std.testing.expectEqual(!scenario.lsp, mockSawFlag("--no-lsp"));
        try std.testing.expect(mockSawFlag("--no-preview"));
        if (scenario.flag) |flag| try std.testing.expect(mockSawFlag(flag));
        try std.testing.expectEqual(@as(usize, if (scenario.lsp) 1 else 2) + @intFromBool(scenario.flag != null), g_mock_flags_len);
    }
}

const RouteHost = struct {
    calls: usize = 0,

    fn append(ctx: *anyopaque, arena: std.mem.Allocator, out: *std.ArrayList([]const u8)) error{OutOfMemory}!void {
        const self: *RouteHost = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        try out.appendSlice(arena, &.{ "--provider", try arena.dupe(u8, "prov-x"), "--model", try arena.dupe(u8, "x-model"), "--reasoning-effort", "high" });
    }
};

fn expectMockFlags(expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, g_mock_flags_len);
    for (expected, g_mock_flags[0..g_mock_flags_len], g_mock_flag_lens[0..g_mock_flags_len]) |want, *got, n| {
        try std.testing.expectEqualStrings(want, got[0..n]);
    }
}

test "L2: the arguments the host adds for a process teammate follow the lead's own flags, and none come without a host" {
    const a = std.testing.allocator;
    var home_buf: [256]u8 = undefined;
    const home = cc.util_fs.testing.uniqueDir(&home_buf, "cc-zig-sw6-hostargs");
    defer cc.util_fs.testing.rmrfBestEffort(home);
    for ([_]bool{ true, false }) |with_host| {
        var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
        try cc.util_fs.mkdirParents(team.teamDirPath(home, "proj", &dirbuf));
        var tf = team.TeamFile{ .allocator = a, .name = try a.dupe(u8, "proj"), .lead_agent_id = try a.dupe(u8, "team-lead@proj"), .lead_session_id = try a.dupe(u8, test_session.asSlice()) };
        defer tf.deinit();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        try team.save(a, &tf, team.configPath(home, "proj", &pbuf));

        var sw = swctx.SwarmContext{ .allocator = a, .session = test_session, .state_root = home, .team_sanitized = try a.dupe(u8, "proj") };
        defer sw.deinit();
        var host: RouteHost = .{};
        if (with_host) sw.teammate_args = .{ .ctx = &host, .appendFn = RouteHost.append };

        g_mock_flags_len = 0;
        _ = try tp.spawnTeammateProcess(&sw, "worker", "", "", "", "", "0123456789abcdef01234567", null, &mockSpawn, false, .{});
        if (with_host) {
            try std.testing.expectEqual(@as(usize, 1), host.calls);
            try expectMockFlags(&.{ "--no-lsp", "--no-preview", "--provider", "prov-x", "--model", "x-model", "--reasoning-effort", "high" });
        } else {
            try std.testing.expectEqual(@as(usize, 0), host.calls);
            try expectMockFlags(&.{ "--no-lsp", "--no-preview" });
        }
    }
}

test "L2: a process teammate's inbox holds its Task prompt from the lead once it is spawned" {
    const a = std.testing.allocator;
    var home_buf: [256]u8 = undefined;
    const home = cc.util_fs.testing.uniqueDir(&home_buf, "cc-zig-sw6-prompt");
    defer cc.util_fs.testing.rmrfBestEffort(home);
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    try cc.util_fs.mkdirParents(team.teamDirPath(home, "proj", &dirbuf));
    var tf = team.TeamFile{ .allocator = a, .name = try a.dupe(u8, "proj"), .lead_agent_id = try a.dupe(u8, "team-lead@proj"), .lead_session_id = try a.dupe(u8, test_session.asSlice()) };
    defer tf.deinit();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    try team.save(a, &tf, team.configPath(home, "proj", &pbuf));

    var sw = swctx.SwarmContext{ .allocator = a, .session = test_session, .state_root = home, .team_sanitized = try a.dupe(u8, "proj") };
    defer sw.deinit();
    _ = try tp.spawnTeammateProcess(&sw, "worker", "Count the files under src/", "", "", "", "0123456789abcdef01234567", null, &mockSpawn, true, .{});

    var inbox_buf: [std.fs.max_path_bytes]u8 = undefined;
    var unread = try cc.swarm_mailbox.readUnread(a, team.inboxPath(home, "proj", "worker", &inbox_buf));
    defer unread.deinit();
    try std.testing.expectEqual(@as(usize, 1), unread.items.items.len);
    const message = unread.items.items[0];
    try std.testing.expectEqualStrings(team.TEAM_LEAD_NAME, message.from);
    try std.testing.expectEqualStrings("Count the files under src/", message.text);
    try std.testing.expectEqualStrings(test_session.asSlice(), message.session_id.?);
    try std.testing.expectEqualStrings(sw.senderLease().asSlice(), message.lease_id.?);
}

test "L2: a teammate's own parser takes the route arguments after its identity as the route its start names" {
    const a = std.testing.allocator;
    const argv = try tp.buildTeammateArgv(a, "/usr/local/bin/metacodes", .{
        .name = "bob",
        .team = "proj",
        .cwd = "/tmp/wt",
        .state_root = "/srv/lead-state",
        .extra_flags = &.{ "--no-preview", "--provider", "prov-x", "--channel", "primary", "--model", "x-model", "--reasoning-effort", "high" },
    });
    defer tp.freeArgv(a, argv);
    var parse_argv: std.ArrayList([*:0]const u8) = .empty;
    defer parse_argv.deinit(a);
    for (argv) |item| try parse_argv.append(a, item orelse continue);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const config = cc.parseArgsForTest(parse_argv.items, arena.allocator());
    try std.testing.expect(config.parse_error == null);
    try std.testing.expectEqualStrings("prov-x", config.provider_profile.?);
    try std.testing.expectEqualStrings("primary", config.provider_channel.?);
    try std.testing.expectEqualStrings("x-model", config.model);
    try std.testing.expect(config.model_explicit);
    try std.testing.expectEqual(cc.types_mod.ReasoningEffort.high, config.reasoning_effort.?);
    try std.testing.expectEqualStrings("bob", config.teammate_name);
}

test "L2: buildTeammateArgv 写出的 argv,teammate 自己的解析器真的认 --no-lsp" {
    // 两段闭环:① flag 进了 argv;② 把**同一条 argv** 喂回 parseArgs,lsp 真的被关掉。
    // 只验 ① 的话,一个位置放错/被后面的 flag 覆盖的 argv 也能"通过"。
    const a = std.testing.allocator;
    const argv = try tp.buildTeammateArgv(a, "/usr/local/bin/metacodes", .{
        .name = "bob",
        .team = "proj",
        .cwd = "/tmp/wt",
        .state_root = "/srv/lead-state",
        .extra_flags = &.{ "--no-lsp", "--no-preview", "--preview=execute_code" },
    });
    defer tp.freeArgv(a, argv);

    var seen = false;
    var parse_argv: std.ArrayList([*:0]const u8) = .empty;
    defer parse_argv.deinit(a);
    for (argv) |item| {
        const z = item orelse continue; // 末尾的 execve null 终止符
        if (std.mem.eql(u8, std.mem.span(z), "--no-lsp")) seen = true;
        try parse_argv.append(a, z);
    }
    try std.testing.expect(seen);

    // parseArgs 会 dupe 值型 flag 的字符串(--agent-name/--team-name/--teammate-cwd 都是),
    // 用 arena 一把回收,省得逐字段 free 还漏。
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const config = cc.parseArgsForTest(parse_argv.items, arena.allocator());
    try std.testing.expect(config.parse_error == null); // 整条命令行合法
    try std.testing.expect(!config.lsp_enabled); // 且真的关掉了
    try std.testing.expect(config.preview.isComplete());
    try std.testing.expect(config.preview.features().eql(.{ .execute_code = true }));
    try std.testing.expectEqualStrings("bob", config.teammate_name); // 身份没被挤掉
    // The child resolves the lead's state root, not its own default.
    try std.testing.expectEqualStrings("/srv/lead-state", config.state_dir.?);
}

const ANSWER_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const EnvGuard = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try std.testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .name = name, .previous = previous };
    }

    fn restore(self: EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            std.testing.allocator.free(previous);
        } else ppaths.unsetEnv(self.name);
    }
};

const LeadHost = struct {
    base_url: []const u8,
    key: ?[]const u8,

    fn append(ctx: *anyopaque, arena: std.mem.Allocator, out: *std.ArrayList([]const u8)) error{OutOfMemory}!void {
        const self: *LeadHost = @ptrCast(@alignCast(ctx));
        try out.appendSlice(arena, &.{ "--base-url", try arena.dupe(u8, self.base_url), "--model", "lead-model", "--reasoning-effort", "low" });
    }

    fn handedKey(ctx: *anyopaque) ?swctx.HandedKey {
        const self: *LeadHost = @ptrCast(@alignCast(ctx));
        const key = self.key orelse return null;
        return .{ .key = key };
    }
};

var g_cli_exe: []const u8 = "";
var g_key_in_argv = false;

fn spawnRealCli(a: std.mem.Allocator, p: tp.SpawnProcessParams) anyerror!i64 {
    g_key_in_argv = false;
    if (p.handed_key) |key| for (p.extra_flags) |flag| {
        if (std.mem.indexOf(u8, flag, key) != null) g_key_in_argv = true;
    };
    return tp.forkExecTeammateAt(a, g_cli_exe, p);
}

const RealTeammate = struct {
    arena_state: std.heap.ArenaAllocator,
    home: []const u8,
    work: []const u8,
    server: *harness.MockServer,
    guards: [9]EnvGuard,

    fn start(self: *RealTeammate, buf: []u8, tag: []const u8, stale_fd: ?[*:0]const u8, env_key: ?[*:0]const u8) !void {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        const raw_cli = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest;
        self.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena_state.deinit();
        const a = self.arena_state.allocator();
        g_cli_exe = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, std.mem.span(raw_cli), a);
        self.home = cc.util_fs.testing.uniqueDir(buf, tag);
        errdefer cc.util_fs.testing.rmrfBestEffort(self.home);
        self.work = try std.fs.path.join(a, &.{ self.home, "work" });
        try cc.util_fs.mkdirParents(self.work);
        var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
        try cc.util_fs.mkdirParents(team.teamDirPath(self.home, "proj", &dirbuf));
        var tf = team.TeamFile{ .allocator = std.testing.allocator, .name = try std.testing.allocator.dupe(u8, "proj"), .lead_agent_id = try std.testing.allocator.dupe(u8, "team-lead@proj"), .lead_session_id = try std.testing.allocator.dupe(u8, test_session.asSlice()) };
        defer tf.deinit();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        try team.save(std.testing.allocator, &tf, team.configPath(self.home, "proj", &pbuf));
        const home_z = try a.dupeZ(u8, self.home);
        self.guards = .{
            try EnvGuard.set("HOME", home_z.ptr),
            try EnvGuard.set("METACODES_KG_AUTOSTART", "0"),
            try EnvGuard.set("METACODES_JEV_URL", "off"),
            try EnvGuard.set("METACODES_NO_PROBE", "1"),
            try EnvGuard.set("METACODES_BASE_URL", null),
            try EnvGuard.set("METACODES_PRESET", null),
            try EnvGuard.set("METACODES_PROVIDER", null),
            try EnvGuard.set("METASK_API_KEY", env_key),
            try EnvGuard.set("METACODES_API_KEY_FD", stale_fd),
        };
        self.server = try harness.MockServer.startCassette(&.{ANSWER_SSE}, 0);
    }

    fn stop(self: *RealTeammate) void {
        self.server.stop();
        var i = self.guards.len;
        while (i > 0) {
            i -= 1;
            self.guards[i].restore();
        }
        cc.util_fs.testing.rmrfBestEffort(self.home);
        self.arena_state.deinit();
    }

    fn spawn(self: *RealTeammate, sw: *swctx.SwarmContext, host: *LeadHost, route: tp.TaskRoute) !void {
        host.base_url = try self.server.urlOwned(self.arena_state.allocator());
        sw.teammate_args = .{ .ctx = host, .appendFn = LeadHost.append, .handedKeyFn = LeadHost.handedKey };
        _ = try tp.spawnTeammateProcess(sw, "worker", "Reply with done.", self.work, "", "", test_session.asSlice(), null, &spawnRealCli, false, route);
    }

    fn writeDotEnv(self: *RealTeammate, text: []const u8) !void {
        const path = try std.fs.path.join(self.arena_state.allocator(), &.{ self.home, ".env" });
        const path_z = try self.arena_state.allocator().dupeZ(u8, path);
        const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.DotEnvNotWritten;
        defer _ = pfs.close(fd);
        if (!pfs.writeAll(fd, text)) return error.DotEnvNotWritten;
    }

    fn firstRequest(self: *RealTeammate) !harness.CapturedRequest {
        var waited: u64 = 0;
        while (self.server.requestCount() == 0) : (waited += 50) {
            if (waited >= 30_000) return error.TeammateSentNoRequest;
            cc.util_time.sleepMs(50);
        }
        return self.server.requestAt(0).?;
    }
};

const AppLead = struct {
    io_rt: std.Io.Threaded,
    arena_state: std.heap.ArenaAllocator,
    app: *cc.app_module.App,

    fn start(self: *AppLead, real: *RealTeammate, args: []const []const u8, api_key: []const u8, options: cc.app_module.App.InitOptions) !void {
        self.io_rt = @import("platform").signal.threadedIo(std.testing.allocator, .{});
        errdefer self.io_rt.deinit();
        self.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena_state.deinit();
        const arena = self.arena_state.allocator();
        var argv: std.ArrayList([*:0]const u8) = .empty;
        for (args) |arg| try argv.append(arena, (try arena.dupeZ(u8, arg)).ptr);
        var config = cc.parseArgsForTest(argv.items, arena);
        config.state_root = real.home;
        self.app = try cc.app_module.App.initWithOptions(std.testing.allocator, self.io_rt.io(), config, api_key, options);
        errdefer self.app.deinit();
        var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
        try cc.util_fs.mkdirParents(team.teamDirPath(real.home, "proj", &dirbuf));
        var tf = team.TeamFile{ .allocator = std.testing.allocator, .name = try std.testing.allocator.dupe(u8, "proj"), .lead_agent_id = try std.testing.allocator.dupe(u8, "team-lead@proj"), .lead_session_id = try std.testing.allocator.dupe(u8, self.app.session_id.asSlice()) };
        defer tf.deinit();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        try team.save(std.testing.allocator, &tf, team.configPath(real.home, "proj", &pbuf));
        self.app.swarm.team_sanitized = try self.app.swarm.allocator.dupe(u8, "proj");
    }

    fn spawn(self: *AppLead, real: *RealTeammate, route: tp.TaskRoute) !void {
        _ = try tp.spawnTeammateProcess(&self.app.swarm, "worker", "Reply with done.", real.work, "", "", self.app.session_id.asSlice(), null, &spawnRealCli, false, route);
    }

    fn stop(self: *AppLead) void {
        self.app.deinit();
        self.arena_state.deinit();
        self.io_rt.deinit();
    }
};

fn headersOf(request: harness.CapturedRequest) []const u8 {
    const end = std.mem.indexOf(u8, request.raw, "\r\n\r\n") orelse request.raw.len;
    return request.raw[0..end];
}

test "L2: a lead on a Metask route hands its teammate the key it started with on a descriptor, with its --base-url and the Task's model and effort" {
    var buf: [256]u8 = undefined;
    var real: RealTeammate = undefined;
    try real.start(&buf, "cc-zig-sw6-handed-key", null, "sk-ambient-metask-key");
    defer real.stop();
    const url = try real.server.urlOwned(real.arena_state.allocator());
    var lead: AppLead = undefined;
    try lead.start(&real, &.{ "metacodes", "--base-url", url, "--model", "lead-model" }, "sk-start-key", .{
        .command_line_base_url = url,
        .handed_key = "sk-start-key",
    });
    defer lead.stop();
    try lead.spawn(&real, .{ .model = "task-model", .effort = .{ .level = .high } });
    try std.testing.expect(!g_key_in_argv);

    const request = try real.firstRequest();
    errdefer std.debug.print("teammate request:\n{s}\n", .{request.raw});
    try std.testing.expect(std.mem.indexOf(u8, headersOf(request), "sk-start-key") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.raw, "sk-ambient-metask-key") == null);
    try std.testing.expectEqualStrings("\"task-model\"", request.jsonField("model") orelse "");
    try std.testing.expect(std.mem.indexOf(u8, request.body(), "\"effort\":\"high\"") != null);
}

test "L2: a lead on a Metask route whose .env holds a Metask key hands no key, and its teammate starts on the .env key" {
    var buf: [256]u8 = undefined;
    var real: RealTeammate = undefined;
    try real.start(&buf, "cc-zig-sw6-dotenv-key", null, null);
    defer real.stop();
    try real.writeDotEnv("METASK_API_KEY=sk-dotenv-key\n");
    const url = try real.server.urlOwned(real.arena_state.allocator());
    var lead: AppLead = undefined;
    try lead.start(&real, &.{ "metacodes", "--base-url", url, "--model", "lead-model" }, "sk-start-key", .{
        .command_line_base_url = url,
        .handed_key = "sk-start-key",
        .local_metask_key = true,
    });
    defer lead.stop();
    try std.testing.expect(lead.app.teammateKey() == null);
    try lead.spawn(&real, .{});

    const request = try real.firstRequest();
    errdefer std.debug.print("teammate request:\n{s}\n", .{request.raw});
    try std.testing.expect(std.mem.indexOf(u8, headersOf(request), "sk-dotenv-key") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.raw, "sk-start-key") == null);
}

test "L2: a METACODES_API_KEY_FD left in the lead's environment does not reach a process teammate that gets no key" {
    var buf: [256]u8 = undefined;
    var real: RealTeammate = undefined;
    try real.start(&buf, "cc-zig-sw6-stale-fd", "987", "sk-env-teammate-key");
    defer real.stop();
    var sw = swctx.SwarmContext{ .allocator = std.testing.allocator, .session = test_session, .state_root = real.home, .team_sanitized = try std.testing.allocator.dupe(u8, "proj") };
    defer sw.deinit();
    var host: LeadHost = .{ .base_url = "", .key = null };
    try real.spawn(&sw, &host, .{});

    const request = try real.firstRequest();
    errdefer std.debug.print("teammate request:\n{s}\n", .{request.raw});
    try std.testing.expect(std.mem.indexOf(u8, headersOf(request), "sk-env-teammate-key") != null);
    try std.testing.expectEqualStrings("\"lead-model\"", request.jsonField("model") orelse "");
}

test "L2: the Task's model and effort reach the teammate's own parser after the lead's route" {
    const a = std.testing.allocator;
    var home_buf: [256]u8 = undefined;
    const home = cc.util_fs.testing.uniqueDir(&home_buf, "cc-zig-sw6-task-route");
    defer cc.util_fs.testing.rmrfBestEffort(home);
    const Case = struct { route: tp.TaskRoute, model: []const u8, effort: ?cc.types_mod.ReasoningEffort };
    for ([_]Case{
        .{ .route = .{}, .model = "x-model", .effort = .high },
        .{ .route = .{ .model = "y-model", .effort = .{ .level = .low } }, .model = "y-model", .effort = .low },
        .{ .route = .{ .model = "y-model", .effort = .model_default }, .model = "y-model", .effort = null },
    }) |case| {
        var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
        try cc.util_fs.mkdirParents(team.teamDirPath(home, "proj", &dirbuf));
        var tf = team.TeamFile{ .allocator = a, .name = try a.dupe(u8, "proj"), .lead_agent_id = try a.dupe(u8, "team-lead@proj"), .lead_session_id = try a.dupe(u8, test_session.asSlice()) };
        defer tf.deinit();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        try team.save(a, &tf, team.configPath(home, "proj", &pbuf));
        var sw = swctx.SwarmContext{ .allocator = a, .session = test_session, .state_root = home, .team_sanitized = try a.dupe(u8, "proj") };
        defer sw.deinit();
        var host: RouteHost = .{};
        sw.teammate_args = .{ .ctx = &host, .appendFn = RouteHost.append };

        g_mock_flags_len = 0;
        _ = try tp.spawnTeammateProcess(&sw, "worker", "", "", "", "", test_session.asSlice(), null, &mockSpawn, true, case.route);
        var flags: [16][]const u8 = undefined;
        for (0..g_mock_flags_len) |i| flags[i] = g_mock_flags[i][0..g_mock_flag_lens[i]];
        const argv = try tp.buildTeammateArgv(a, "/usr/local/bin/metacodes", .{ .name = "worker", .team = "proj", .state_root = home, .extra_flags = flags[0..g_mock_flags_len] });
        defer tp.freeArgv(a, argv);
        var parse_argv: std.ArrayList([*:0]const u8) = .empty;
        defer parse_argv.deinit(a);
        for (argv) |item| try parse_argv.append(a, item orelse continue);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const config = cc.parseArgsForTest(parse_argv.items, arena.allocator());
        try std.testing.expect(config.parse_error == null);
        try std.testing.expectEqualStrings(case.model, config.model);
        try std.testing.expectEqual(case.effort, config.reasoning_effort);
    }
}

test "L2: a process teammate gets the lead's command-line --base-url and start key only while the lead still uses them" {
    var home_buf: [256]u8 = undefined;
    const home = cc.util_fs.testing.uniqueDir(&home_buf, "cc-zig-sw6-lead-route");
    defer cc.util_fs.testing.rmrfBestEffort(home);
    const guards = [_]EnvGuard{
        try EnvGuard.set("HOME", home.ptr),
        try EnvGuard.set("METACODES_NO_PROBE", "1"),
        try EnvGuard.set("METACODES_KG_AUTOSTART", "0"),
    };
    defer for (guards) |guard| guard.restore();
    var io_runtime = @import("platform").signal.threadedIo(std.testing.allocator, .{});
    defer io_runtime.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const url = "http://127.0.0.1:9/v1";
    var config = cc.parseArgsForTest(&.{ "metacodes", "--base-url", url, "--model", "flag-model" }, arena);
    config.state_root = home;
    const app = try cc.app_module.App.initWithOptions(std.testing.allocator, io_runtime.io(), config, "sk-start-key", .{
        .command_line_base_url = url,
        .handed_key = "sk-start-key",
    });
    defer app.deinit();

    const handed = app.teammateKey() orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("sk-start-key", handed.key);
    try std.testing.expectEqual(@as(usize, 1), handed.drop_env.len);
    try std.testing.expectEqualStrings("METASK_API_KEY", handed.drop_env[0]);
    var args: std.ArrayList([]const u8) = .empty;
    try app.appendTeammateRouteArgs(arena, &args);
    const at = for (args.items, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--base-url")) break i;
    } else return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(url, args.items[at + 1]);

    app.api_key = "sk-moved-key";
    app.api_client.base_url = "http://127.0.0.1:10/elsewhere";
    args.clearRetainingCapacity();
    try app.appendTeammateRouteArgs(arena, &args);
    for (args.items) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--base-url"));
    try std.testing.expect(app.teammateKey() == null);

    app.api_key = "sk-start-key";
    try std.testing.expectEqualStrings("sk-start-key", (app.teammateKey() orelse return error.TestExpectedEqual).key);
    app.local_metask_key = true;
    try std.testing.expect(app.teammateKey() == null);
}

fn writeFile(arena: std.mem.Allocator, dir: []const u8, name: []const u8, text: []const u8) ![]const u8 {
    const path = try std.fs.path.join(arena, &.{ dir, name });
    const path_z = try arena.dupeZ(u8, path);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.FileNotWritten;
    defer _ = pfs.close(fd);
    if (!pfs.writeAll(fd, text)) return error.FileNotWritten;
    return path;
}

fn writeNamedProvider(arena: std.mem.Allocator, state_root: []const u8, port: u16) !void {
    const config = try std.fmt.allocPrint(arena,
        \\{{"custom_providers":{{"prov-x":{{"display_name":"Prov X","credential_kinds":["api_key"],"env_aliases":[{{"name":"PROV_X_TOKEN","kind":"api_key","canonical":true}}],"channels":[{{"id":"primary","base_url":"http://127.0.0.1:{d}/x","protocol":"anthropic_messages"}}],"models":[{{"request_model_id":"x-model","display_name":"X model"}}]}}}}}}
    , .{port});
    _ = try writeFile(arena, state_root, "config.json", config);
}

test "L2: a lead started with --provider and METACODES_API_KEY_FD sends the key on the descriptor" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const raw_cli = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var home_buf: [256]u8 = undefined;
    const home = cc.util_fs.testing.uniqueDir(&home_buf, "cc-zig-fd-named-provider");
    defer cc.util_fs.testing.rmrfBestEffort(home);
    try cc.util_fs.mkdirParents(home);
    var server = try harness.MockServer.startCassette(&.{ANSWER_SSE}, 0);
    defer server.stop();
    try writeNamedProvider(a, home, server.port);
    const key_path = try writeFile(a, home, "key", "sk-descriptor-key");
    const cli = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, std.mem.span(raw_cli), a);
    const args = [_][]const u8{
        "/usr/bin/env",                                                                    "-i",
        try std.fmt.allocPrint(a, "HOME={s}", .{home}),                                    "PATH=/usr/bin:/bin",
        "METACODES_KG_AUTOSTART=0",                                                        "METACODES_JEV_URL=off",
        "METACODES_NO_PROBE=1",                                                            "METACODES_API_KEY_FD=3",
        "/bin/sh",                                                                         "-c",
        "exec \"$0\" --state-dir \"$1\" --provider prov-x --model x-model -p hi 3<\"$2\"", cli,
        home,                                                                              key_path,
    };
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    try argv.append(a, null);
    const out = try cc.tools_common.spawnCaptureWithStderrTimed(argv.items, a, null, 60_000, null, cc.tools_common.MAX_SPAWN_CAPTURE_BYTES, home);
    errdefer std.debug.print("exit {d}; stderr:\n{s}\n", .{ out.exit_code, out.stderr });
    try std.testing.expectEqual(@as(i32, 0), out.exit_code);
    const request = server.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.startsWith(u8, request.raw, "POST /x/v1/messages"));
    try std.testing.expect(std.mem.indexOf(u8, headersOf(request), "sk-descriptor-key") != null);
}

test "L2: a lead on a named provider hands its teammate the key it started with, and the teammate sends it" {
    var buf: [256]u8 = undefined;
    var real: RealTeammate = undefined;
    try real.start(&buf, "cc-zig-sw6-named-provider", null, "sk-ambient-metask-key");
    defer real.stop();
    try writeNamedProvider(real.arena_state.allocator(), real.home, real.server.port);
    var lead: AppLead = undefined;
    try lead.start(&real, &.{ "metacodes", "--provider", "prov-x", "--model", "x-model" }, "sk-start-key", .{
        .route_state = .{ .bound = .flag },
        .handed_key = "sk-start-key",
    });
    defer lead.stop();
    try lead.spawn(&real, .{});
    try std.testing.expect(!g_key_in_argv);

    const request = try real.firstRequest();
    errdefer std.debug.print("teammate request:\n{s}\n", .{request.raw});
    try std.testing.expect(std.mem.startsWith(u8, request.raw, "POST /x/v1/messages"));
    try std.testing.expect(std.mem.indexOf(u8, headersOf(request), "sk-start-key") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.raw, "sk-ambient-metask-key") == null);
}
