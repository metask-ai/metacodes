//! L2 组件测试:SW6 进程外 teammate(单元/隔离面)。
//!  A CLI 解析:--teammate --agent-name/--team-name/--parent-session-id/--teammate-cwd → config。
//!  B worktree 隔离:createWorktree/removeWorktree 真 git(临时 repo)。
//! 完整 lead→fork+exec 真 metacodes --teammate→处理消息 e2e 归 SW7 进程 e2e harness——
//! 在带 live MockServer 线程的组件测试里 fork() 多线程进程不安全,须用干净的进程 harness。

const std = @import("std");
const cc = @import("cc");
const pfs = @import("platform").fs; // 可移植文件 IO(std.c.open 的 O 在 Windows 是 void)

const tp = cc.swarm_teammate_process;
const team = cc.swarm_team;
const swctx = cc.swarm_context;

// DI mock spawn:不真 fork,记录被传的 params + 返回假 pid。验证 lead-spawn 接线。
var g_mock_name: [64]u8 = undefined;
var g_mock_name_len: usize = 0;
var g_mock_cwd: [256]u8 = undefined;
var g_mock_cwd_len: usize = 0;
fn mockSpawn(a: std.mem.Allocator, p: tp.SpawnProcessParams) anyerror!i64 {
    _ = a;
    g_mock_name_len = @min(p.name.len, g_mock_name.len);
    @memcpy(g_mock_name[0..g_mock_name_len], p.name[0..g_mock_name_len]);
    g_mock_cwd_len = @min(p.cwd.len, g_mock_cwd.len);
    @memcpy(g_mock_cwd[0..g_mock_cwd_len], p.cwd[0..g_mock_cwd_len]);
    return 99999; // 假 pid
}

test "L2 SW6 D: 无 worktree base 时 lead-spawn 接线(登记 member=process + 追踪,mock fork)" {
    const a = std.testing.allocator;
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "/tmp/cc-zig-sw6-spawn-{d}", .{cc.util_time.nowNs()});
    defer cc.util_fs.testing.rmrfBestEffort(home);
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    try cc.util_fs.mkdirParents(team.teamDirPath(home, "proj", &dirbuf));
    var tf = team.TeamFile{ .allocator = a, .name = try a.dupe(u8, "proj"), .lead_agent_id = try a.dupe(u8, "team-lead@proj") };
    defer tf.deinit();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    try team.save(a, &tf, team.configPath(home, "proj", &pbuf));

    var sw = swctx.SwarmContext{ .allocator = a, .home = home, .team_sanitized = try a.dupe(u8, "proj") };
    // deinit 会 kill(99999)(无害:不存在的 pid)+ free。
    defer sw.deinit();

    g_mock_name_len = 0;
    const pid = try tp.spawnTeammateProcess(&sw, "worker", "", "", "", null, &mockSpawn);
    try std.testing.expectEqual(@as(i64, 99999), pid);
    // mock 收到 name。
    try std.testing.expectEqualStrings("worker", g_mock_name[0..g_mock_name_len]);
    // config 里登记了 process backend 成员。
    var cfg2: [std.fs.max_path_bytes]u8 = undefined;
    var back = team.load(a, team.configPath(home, "proj", &cfg2)) orelse return error.NoConfig;
    defer back.deinit();
    const m = back.findMember("worker") orelse return error.NoMember;
    try std.testing.expectEqualStrings("process", m.backend_type);
    // 追踪表有记录(deinit 会清)。
    try std.testing.expectEqual(@as(usize, 1), sw.process_teammates.items.len);
    try std.testing.expectEqual(@as(i64, 99999), sw.process_teammates.items[0].pid);
}

test "L2 SW6 D2: 保留名 team-lead 不能 spawn 进程外" {
    const a = std.testing.allocator;
    var home_buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "/tmp/cc-zig-sw6-res-{d}", .{cc.util_time.nowNs()});
    defer cc.util_fs.testing.rmrfBestEffort(home);
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    try cc.util_fs.mkdirParents(team.teamDirPath(home, "proj", &dirbuf));
    var tf = team.TeamFile{ .allocator = a, .name = try a.dupe(u8, "proj"), .lead_agent_id = try a.dupe(u8, "team-lead@proj") };
    defer tf.deinit();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    try team.save(a, &tf, team.configPath(home, "proj", &pbuf));
    var sw = swctx.SwarmContext{ .allocator = a, .home = home, .team_sanitized = try a.dupe(u8, "proj") };
    defer sw.deinit();
    try std.testing.expectError(error.ReservedName, tp.spawnTeammateProcess(&sw, "Team-Lead", "", "", "", null, &mockSpawn));
}

test "L2 SW6 A: --teammate 身份 args 解析进 config" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{
        "metacodes", "--teammate", "--agent-name", "bob", "--team-name", "proj",
        "--parent-session-id", "sess9", "--teammate-cwd", "/tmp/wt7",
    };
    const cfg = cc.parseArgsForTest(&argv, a);
    // 注:parseArgsForTest 用 arena/allocator dupe;这里 testing.allocator 会报泄漏若 dupe 未 free。
    // config 字符串归调用方——测试结束前 free。
    defer {
        if (cfg.teammate_name.len > 0) a.free(cfg.teammate_name);
        if (cfg.teammate_team.len > 0) a.free(cfg.teammate_team);
        if (cfg.teammate_parent_session.len > 0) a.free(cfg.teammate_parent_session);
        if (cfg.teammate_cwd.len > 0) a.free(cfg.teammate_cwd);
    }
    try std.testing.expectEqualStrings("bob", cfg.teammate_name);
    try std.testing.expectEqualStrings("proj", cfg.teammate_team);
    try std.testing.expectEqualStrings("sess9", cfg.teammate_parent_session);
    try std.testing.expectEqualStrings("/tmp/wt7", cfg.teammate_cwd);
    try std.testing.expect(cfg.agent_teams); // --teammate 隐含开 teams
}

test "L2 SW6 B: worktree 隔离 create + remove(真 git)" {
    const a = std.testing.allocator;
    // 临时 git repo。
    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/cc-zig-sw6-wt-{d}", .{cc.util_time.nowNs()});
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
    // removeWorktree → 目录清。
    tp.removeWorktree(a, wt, root, null);
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
    const out = common.spawnCaptureWithStderrTimed(argv.items, a, null, 15_000, null, common.MAX_SPAWN_CAPTURE_BYTES) catch return false;
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    return out.exit_code == 0;
}
