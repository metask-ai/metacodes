//! L2 组件测试:SW1 teammate 运行时(spawn→work→idle→消息续跑→shutdown→join)。
//!
//! 策略(对齐 agent_background_test):MockServer.startCassette 假模型 + 隔离 fake HOME,
//! 直接驱动 TeammateRegistry。全链断言:
//!  A spawn:config.json 出现成员(is_active=true 起步);
//!  B idle:lead 邮箱收到 idle_notification + config is_active 翻 false;
//!  C 续跑:向 teammate 邮箱投 plain 消息 → 第二轮跑起来(第二条 idle_notification +
//!    output_buf 含第二轮文本)+ 消息被标已读;
//!  D shutdown:投 shutdown_request → 线程优雅退出(status=terminated);
//!  E deinit:等待中 deinit 不挂(abort 打断 idle-wait)。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const team = cc.swarm_team;
const mailbox = cc.swarm_mailbox;
const teammate = cc.swarm_teammate;

const TURN_SSE_FMT =
    "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
    "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
    "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{s}\"}}}}\n\n" ++
    "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
    "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
    "data: {{\"type\":\"message_stop\"}}\n\n";

const TURN1_SSE = std.fmt.comptimePrint(TURN_SSE_FMT, .{"TURN1 DONE"});
const TURN2_SSE = std.fmt.comptimePrint(TURN_SSE_FMT, .{"TURN2 DONE"});

fn sleepMs(ms: u32) void {
    cc.util_time.sleepMs(ms); // 可移植(POSIX nanosleep / Windows Sleep)
}

/// 建隔离 HOME + team 目录 + config.json(lead 成员为空 roster)。返回 home(owned by buf)。
fn setupTeam(a: std.mem.Allocator, home_buf: []u8) ![]const u8 {
    const home = try std.fmt.bufPrint(home_buf, "/tmp/cc-zig-teammate-l2-{d}", .{cc.util_time.nowNs()});
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    try cc.util_fs.mkdirParents(team.teamDirPath(home, "proj", &dirbuf));
    var tf = team.TeamFile{
        .allocator = a,
        .name = try a.dupe(u8, "proj"),
        .lead_agent_id = try a.dupe(u8, "team-lead@proj"),
        .created_at_ms = 1,
    };
    defer tf.deinit();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    try team.save(a, &tf, team.configPath(home, "proj", &pbuf));
    return home;
}

/// 数 lead 邮箱里 idle_notification 条数。
fn countIdleNotifications(a: std.mem.Allocator, home: []const u8) !usize {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const lead_inbox = team.inboxPath(home, "proj", "team-lead", &pbuf);
    var all = try mailbox.readAll(a, lead_inbox);
    defer all.deinit();
    var n: usize = 0;
    for (all.items.items) |*m| {
        if (mailbox.classify(a, m.text) == .idle_notification) n += 1;
    }
    return n;
}

/// 轮询直到 lead 邮箱 idle_notification 达到 want 条(超时失败)。
fn waitIdleCount(a: std.mem.Allocator, home: []const u8, want: usize, max_ms: u32) !void {
    var waited: u32 = 0;
    while (waited < max_ms) : (waited += 20) {
        if ((try countIdleNotifications(a, home)) >= want) return;
        sleepMs(20);
    }
    return error.IdleNotificationTimeout;
}

test "L2 teammate 全链: spawn→idle→消息续跑→shutdown 优雅退出" {
    const a = std.testing.allocator;

    const bodies = [_][]const u8{ TURN1_SSE, TURN2_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var home_buf: [128]u8 = undefined;
    const home = try setupTeam(a, &home_buf);
    defer cc.util_fs.testing.rmrfBestEffort(home);

    var reg = try teammate.TeammateRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic, home);
    defer reg.deinit();

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    const entry = try reg.spawnTeammate(.{
        .name = "bob",
        .team = "proj",
        .prompt = "start work",
        .tool_defs = empty_defs,
        .permission_ctx = perm,
        .color = "blue",
        .agent_type = "general-purpose",
    });

    // A: config.json 有成员 bob。
    var cfgbuf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg_path = team.configPath(home, "proj", &cfgbuf);
    {
        var tf = team.load(a, cfg_path) orelse return error.NoConfig;
        defer tf.deinit();
        const m = tf.findMember("bob") orelse return error.NoMember;
        try std.testing.expectEqualStrings("bob@proj", m.agent_id);
        try std.testing.expectEqualStrings("in-process", m.backend_type);
    }

    // B: 第一轮跑完 → idle notification + is_active=false + 输出含 TURN1。
    try waitIdleCount(a, home, 1, 5000);
    try std.testing.expectEqual(teammate.TeammateStatus.idle, entry.statusSnapshot());
    {
        var tf = team.load(a, cfg_path) orelse return error.NoConfig;
        defer tf.deinit();
        try std.testing.expect(!tf.findMember("bob").?.is_active);
        entry.lockPublic();
        defer entry.unlockPublic();
        try std.testing.expect(std.mem.indexOf(u8, entry.output_buf.items, "TURN1 DONE") != null);
    }

    // C: 投 plain 消息 → 第二轮跑 → 第二条 idle notification + 输出含 TURN2 + 消息标已读。
    var inbox_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bob_inbox = team.inboxPath(home, "proj", "bob", &inbox_buf);
    try mailbox.deliver(a, bob_inbox, "team-lead", "continue with step 2", null, null);
    try waitIdleCount(a, home, 2, 5000);
    {
        entry.lockPublic();
        const has_turn2 = std.mem.indexOf(u8, entry.output_buf.items, "TURN2 DONE") != null;
        entry.unlockPublic();
        try std.testing.expect(has_turn2);
        var unread = try mailbox.readUnread(a, bob_inbox);
        defer unread.deinit();
        try std.testing.expectEqual(@as(usize, 0), unread.items.items.len);
    }

    // D: shutdown_request → 线程优雅退出。
    try mailbox.deliver(a, bob_inbox, "team-lead", "{\"type\":\"shutdown_request\",\"request_id\":\"r1\"}", null, null);
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 20) {
        if (entry.statusSnapshot() == .terminated) break;
        sleepMs(20);
    }
    try std.testing.expectEqual(teammate.TeammateStatus.terminated, entry.statusSnapshot());
    // 终止后 is_active=false 保持。
    {
        var tf = team.load(a, cfg_path) orelse return error.NoConfig;
        defer tf.deinit();
        try std.testing.expect(!tf.findMember("bob").?.is_active);
    }
}

test "L2 teammate deinit: idle-wait 中 abort 打断,join 不挂" {
    const a = std.testing.allocator;

    const bodies = [_][]const u8{TURN1_SSE};
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var home_buf: [128]u8 = undefined;
    const home = try setupTeam(a, &home_buf);
    defer cc.util_fs.testing.rmrfBestEffort(home);

    var reg = try teammate.TeammateRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic, home);

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    _ = try reg.spawnTeammate(.{
        .name = "carl",
        .team = "proj",
        .prompt = "start",
        .tool_defs = empty_defs,
        .permission_ctx = perm,
    });

    // 等它进 idle-wait(1 条 idle notification),然后 deinit 必须把等待线程打断。
    try waitIdleCount(a, home, 1, 5000);
    reg.deinit(); // 挂了=测试超时,过了=abort 传导正确
}

test "L2 teammate 失败必达 lead: 401 快速失败 → idleReason=failed + failureReason" {
    const a = std.testing.allocator;

    var srv = try harness.MockServer.startWithStatus(
        "{\"error\":{\"type\":\"authentication_error\",\"message\":\"bad key\"}}",
        0,
        "HTTP/1.1 401 Unauthorized",
    );
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var home_buf: [128]u8 = undefined;
    const home = try setupTeam(a, &home_buf);
    defer cc.util_fs.testing.rmrfBestEffort(home);

    var reg = try teammate.TeammateRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic, home);
    defer reg.deinit();

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    _ = try reg.spawnTeammate(.{
        .name = "fay",
        .team = "proj",
        .prompt = "p",
        .tool_defs = empty_defs,
        .permission_ctx = perm,
    });

    // 失败通知到达 lead 邮箱。注:401 在 agent_loop 里是正常返回 stop_reason=api_error
    // (非 Zig error),故信封是 idleReason=failed + stopReason=api_error;线程留在
    // idle-wait 可救(lead 可 shutdown/nudge),deinit 兜底退出。
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const lead_inbox = team.inboxPath(home, "proj", "team-lead", &pbuf);
    var found = false;
    var waited: u32 = 0;
    while (waited < 15000) : (waited += 20) {
        var all = try mailbox.readAll(a, lead_inbox);
        defer all.deinit();
        for (all.items.items) |*m| {
            if (std.mem.indexOf(u8, m.text, "\"idleReason\":\"failed\"") != null and
                std.mem.indexOf(u8, m.text, "\"stopReason\":\"api_error\"") != null)
            {
                found = true;
            }
        }
        if (found) break;
        sleepMs(20);
    }
    try std.testing.expect(found);
}

test "L2 teammate 软截断不洗白: max_turns → needs_continuation + stopReason" {
    const a = std.testing.allocator;

    // 第 1 轮发 TaskCreate(stop_reason=tool_use)→ 工具执行后要第 2 轮,max_turns=1 截断。
    const TOOLUSE_SSE =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"TaskCreate\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"subject\\\":\\\"a\\\",\\\"description\\\":\\\"d\\\"}\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    const bodies = [_][]const u8{TOOLUSE_SSE};
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var home_buf: [128]u8 = undefined;
    const home = try setupTeam(a, &home_buf);
    defer cc.util_fs.testing.rmrfBestEffort(home);

    var reg = try teammate.TeammateRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic, home);
    defer reg.deinit();

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    _ = try reg.spawnTeammate(.{
        .name = "gil",
        .team = "proj",
        .prompt = "p",
        .tool_defs = empty_defs,
        .permission_ctx = perm,
        .max_turns_per_run = 1,
    });

    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const lead_inbox = team.inboxPath(home, "proj", "team-lead", &pbuf);
    var found = false;
    var waited: u32 = 0;
    while (waited < 8000) : (waited += 20) {
        var all = try mailbox.readAll(a, lead_inbox);
        defer all.deinit();
        for (all.items.items) |*m| {
            if (std.mem.indexOf(u8, m.text, "\"idleReason\":\"needs_continuation\"") != null and
                std.mem.indexOf(u8, m.text, "\"stopReason\":\"max_turns\"") != null)
            {
                found = true;
            }
        }
        if (found) break;
        sleepMs(20);
    }
    try std.testing.expect(found);
}

test "L2 teammate 协议消息不吞: task_assignment 留未读,teammate 保持 idle" {
    const a = std.testing.allocator;

    const bodies = [_][]const u8{TURN1_SSE};
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var home_buf: [128]u8 = undefined;
    const home = try setupTeam(a, &home_buf);
    defer cc.util_fs.testing.rmrfBestEffort(home);

    var reg = try teammate.TeammateRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic, home);
    defer reg.deinit();

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    const entry = try reg.spawnTeammate(.{
        .name = "hal",
        .team = "proj",
        .prompt = "p",
        .tool_defs = empty_defs,
        .permission_ctx = perm,
    });
    try waitIdleCount(a, home, 1, 5000);

    // 投协议消息(SW3 的 task_assignment):不得触发新 turn,不得被标已读。
    var inbox_buf: [std.fs.max_path_bytes]u8 = undefined;
    const hal_inbox = team.inboxPath(home, "proj", "hal", &inbox_buf);
    try mailbox.deliver(a, hal_inbox, "team-lead", "{\"type\":\"task_assignment\",\"taskId\":\"7\"}", null, null);
    sleepMs(1200); // 跨 ≥2 个 500ms 轮询周期
    try std.testing.expectEqual(teammate.TeammateStatus.idle, entry.statusSnapshot());
    {
        var unread = try mailbox.readUnread(a, hal_inbox);
        defer unread.deinit();
        try std.testing.expectEqual(@as(usize, 1), unread.items.items.len); // 留给 SW3 消费者
    }
    // shutdown:只标读 shutdown,task_assignment 仍未读。
    try mailbox.deliver(a, hal_inbox, "team-lead", "{\"type\":\"shutdown_request\",\"request_id\":\"r9\"}", null, null);
    var waited: u32 = 0;
    while (waited < 5000) : (waited += 20) {
        if (entry.statusSnapshot() == .terminated) break;
        sleepMs(20);
    }
    try std.testing.expectEqual(teammate.TeammateStatus.terminated, entry.statusSnapshot());
    {
        var unread = try mailbox.readUnread(a, hal_inbox);
        defer unread.deinit();
        try std.testing.expectEqual(@as(usize, 1), unread.items.items.len);
        try std.testing.expect(std.mem.indexOf(u8, unread.items.items[0].text, "task_assignment") != null);
    }
}

test "L2 teammate MAX_TEAMMATES 上限强制执行 + working 期 is_active=true" {
    const a = std.testing.allocator;

    const bodies = [_][]const u8{TURN1_SSE};
    // 慢:保证 t0 在断言窗口(≤3s poll)内保持 working。1500ms × 6 chunk = 9s/连接。
    // 勿调大:server 串行 accept,而阻塞在 receiveHead 的线程感知不到 abort(存量债,
    // 见 teammate.zig 线程循环注释)——deinit join 的最坏耗时 = 连接数 × 单连接流时长。
    var srv = try harness.MockServer.startCassette(&bodies, 1500);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var home_buf: [128]u8 = undefined;
    const home = try setupTeam(a, &home_buf);
    defer cc.util_fs.testing.rmrfBestEffort(home);

    var reg = try teammate.TeammateRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic, home);
    defer reg.deinit();

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var name_buf: [8]u8 = undefined;
    var i: usize = 0;
    while (i < teammate.MAX_TEAMMATES) : (i += 1) {
        const nm = try std.fmt.bufPrint(&name_buf, "t{d}", .{i});
        _ = try reg.spawnTeammate(.{
            .name = nm,
            .team = "proj",
            .prompt = "p",
            .tool_defs = empty_defs,
            .permission_ctx = perm,
        });
    }
    // 第 9 个被上限拒绝。
    try std.testing.expectError(error.TooManyTeammates, reg.spawnTeammate(.{
        .name = "extra",
        .team = "proj",
        .prompt = "p",
        .tool_defs = empty_defs,
        .permission_ctx = perm,
    }));
    // working 期 config is_active=true(t0 慢请求挂着,必然 working)。
    var cfgbuf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg_path = team.configPath(home, "proj", &cfgbuf);
    var seen_active = false;
    var waited: u32 = 0;
    while (waited < 3000) : (waited += 50) {
        var tf = team.load(a, cfg_path) orelse {
            sleepMs(50);
            continue;
        };
        defer tf.deinit();
        if (tf.findMember("t0")) |m| {
            if (m.is_active) {
                seen_active = true;
                break;
            }
        }
        sleepMs(50);
    }
    try std.testing.expect(seen_active);
}

test "L2 teammate 重名拒绝 + 上限存在" {
    const a = std.testing.allocator;

    const bodies = [_][]const u8{TURN1_SSE};
    var srv = try harness.MockServer.startCassette(&bodies, 1500); // 慢:保证首个 teammate 保持 working(9s/连接,勿调大——同 MAX_TEAMMATES 注释)
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var home_buf: [128]u8 = undefined;
    const home = try setupTeam(a, &home_buf);
    defer cc.util_fs.testing.rmrfBestEffort(home);

    var reg = try teammate.TeammateRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic, home);
    defer reg.deinit();

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    _ = try reg.spawnTeammate(.{
        .name = "dora",
        .team = "proj",
        .prompt = "p",
        .tool_defs = empty_defs,
        .permission_ctx = perm,
    });
    try std.testing.expectError(error.DuplicateTeammateName, reg.spawnTeammate(.{
        .name = "dora",
        .team = "proj",
        .prompt = "p",
        .tool_defs = empty_defs,
        .permission_ctx = perm,
    }));
}
