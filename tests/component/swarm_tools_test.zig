//! L2 组件测试:SW2 工具面端到端(TeamCreate → Task spawn teammate → SendMessage →
//! teammate 干活回 idle → pollLeadInbox 拉回)。
//!
//! 通过真 ToolContext + 真 SwarmContext + MockServer cassette 驱动,断言:
//!  A TeamCreate 工具建队 + registry 就位;
//!  B Task(name=…) 走 teammate 分支 → 成员进 config + teammate 线程跑起来;
//!  C SendMessage(lead→teammate) 投进 teammate 邮箱,续跑第二轮;
//!  D pollLeadInbox 把 teammate 的 idle 通知拉成 <teammate-status>;
//!  E TeamDelete 拒活跃 → shutdown 后可删。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const swtools = cc.swarm_tools;
const swctx = cc.swarm_context;
const team = cc.swarm_team;
const mailbox = cc.swarm_mailbox;

var swarm_dialect_ctx: u8 = 0;

fn injectSwarmDialectMarker(
    _: *anyopaque,
    _: cc.model_adapter.ModelProfile,
    _: ?cc.api_dialect.ReasoningEffort,
    system: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) anyerror!void {
    try system.appendSlice(allocator, "\nSWARM_DIALECT_MARKER");
}

const swarm_test_dialect = cc.api_dialect.Dialect{
    .ctx = @ptrCast(&swarm_dialect_ctx),
    .injectSystemModsFn = injectSwarmDialectMarker,
};

fn resolveSwarmDialect(_: *const anyopaque, kind: cc.api_dialect.ProviderKind, model: []const u8) cc.api_dialect.Dialect {
    if (kind == .anthropic) return swarm_test_dialect;
    return cc.api_dialect.dialectFor(kind, model);
}

fn swarmDialectResolver() cc.api_dialect.Resolver {
    return .{ .ctx = @ptrCast(&swarm_dialect_ctx), .resolveFn = resolveSwarmDialect };
}

const TURN_FMT =
    "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
    "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
    "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{s}\"}}}}\n\n" ++
    "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
    "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
    "data: {{\"type\":\"message_stop\"}}\n\n";
const T1 = std.fmt.comptimePrint(TURN_FMT, .{"TEAMMATE TURN1"});
const T2 = std.fmt.comptimePrint(TURN_FMT, .{"TEAMMATE TURN2"});

fn sleepMs(ms: u32) void {
    cc.util_time.sleepMs(ms); // 可移植(POSIX nanosleep / Windows Sleep)
}

test "L2 SW2 端到端: TeamCreate → Task spawn teammate → SendMessage → pollLeadInbox" {
    const a = std.testing.allocator;

    const bodies = [_][]const u8{ T1, T2 };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try agents.loadFromStandardPaths("");

    var home_buf: [256]u8 = undefined;
    const home = cc.util_fs.testing.uniqueDir(&home_buf, "cc-zig-sw2-l2");
    defer cc.util_fs.testing.rmrfBestEffort(home);
    try cc.util_fs.mkdirParents(home);

    var sw = swctx.SwarmContext{
        .allocator = a,
        .home = home,
        .api_key = "k",
        .base_url = url,
        .model = "claude-sonnet-4-20250514",
        .provider_kind = .anthropic,
        .dialect_resolver = swarmDialectResolver(),
    };
    defer sw.deinit();

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    const ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .api_client = &client,
        .tool_defs = empty_defs,
        .permission_ctx = @constCast(&perm),
        .agents = &agents,
        .swarm = &sw,
        .parent_model = "claude-sonnet-4-20250514",
    };

    // A: TeamCreate。
    const r1 = try cc.swarm_tools.executeTeamCreate(&ctx, "{\"name\":\"proj\"}");
    a.free(r1);
    try std.testing.expect(sw.hasTeam());

    // B: Task(name=worker) → teammate 分支。
    const spawn_out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"general-purpose\",\"prompt\":\"do the work\",\"name\":\"worker\"}");
    defer a.free(spawn_out);
    try std.testing.expect(std.mem.indexOf(u8, spawn_out, "\"teammate\":\"worker\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spawn_out, "worker@proj") != null);
    // 成员进 config。
    var cfgbuf: [std.fs.max_path_bytes]u8 = undefined;
    {
        var tf = team.load(a, sw.configPath(&cfgbuf)) orelse return error.NoConfig;
        defer tf.deinit();
        try std.testing.expect(tf.findMember("worker") != null);
    }

    // C+D: 等 teammate 第一轮跑完 → lead 邮箱有 idle 通知 → pollLeadInbox 拉成 status。
    var pulled_status = false;
    var waited: u32 = 0;
    while (waited < 20_000) : (waited += 30) {
        if (try swtools.pollLeadInbox(a, &sw)) |pulled| {
            defer a.free(pulled);
            if (std.mem.indexOf(u8, pulled, "<teammate-status from=\"worker\"") != null) {
                pulled_status = true;
                break;
            }
        }
        sleepMs(30);
    }
    try std.testing.expect(pulled_status);
    const first_request_body = (srv.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, first_request_body, "SWARM_DIALECT_MARKER") != null);

    // SendMessage 续跑第二轮。
    const r2 = try cc.swarm_tools.executeSendMessage(&ctx, "{\"to\":\"worker\",\"message\":\"continue\",\"summary\":\"go\"}");
    defer a.free(r2);
    try std.testing.expect(std.mem.indexOf(u8, r2, "\"delivered\":1") != null);
    // teammate 第二轮跑起来(worker inbox 消息被消费掉)。
    var inbox_buf: [std.fs.max_path_bytes]u8 = undefined;
    const worker_inbox = team.inboxPath(home, "proj", "worker", &inbox_buf);
    var consumed = false;
    waited = 0;
    while (waited < 20_000) : (waited += 30) {
        var unread = try mailbox.readUnread(a, worker_inbox);
        defer unread.deinit();
        if (unread.items.items.len == 0) {
            consumed = true;
            break;
        }
        sleepMs(30);
    }
    try std.testing.expect(consumed);

    // E: TeamDelete 先拒(teammate 还活着),shutdown 后可删。
    // teammate 仍在 idle(存活)→ 拒删。
    try std.testing.expectError(error.TeammatesStillActive, cc.swarm_tools.executeTeamDelete(&ctx, "{}"));
    // shutdown teammate。
    const rsd = try cc.swarm_tools.executeSendMessage(&ctx, "{\"to\":\"worker\",\"message\":\"{\\\"type\\\":\\\"shutdown_request\\\",\\\"request_id\\\":\\\"r1\\\"}\",\"summary\":\"stop\"}");
    a.free(rsd);
    // 等 teammate 退出(liveCount → 0)。
    waited = 0;
    while (waited < 20_000) : (waited += 30) {
        if (sw.teammates.?.liveCount() == 0) break;
        sleepMs(30);
    }
    // TeamDelete 对活着的 teammate 会拒绝;先断言退出,让"没退出"和"删不掉"是两个失败。
    try std.testing.expectEqual(@as(usize, 0), sw.teammates.?.liveCount());
    const rdel = try cc.swarm_tools.executeTeamDelete(&ctx, "{}");
    defer a.free(rdel);
    try std.testing.expect(std.mem.indexOf(u8, rdel, "\"status\":\"deleted\"") != null);
    try std.testing.expect(!sw.hasTeam());
}

// F1/F2 回归:teammate 用 SendMessage 把结果回传 lead(teammate 的 ToolContext.swarm 已接线)。
test "L2 SW2 F1/F2: teammate SendMessage 回 lead 送达 lead 邮箱" {
    const a = std.testing.allocator;

    // teammate 第一轮就调 SendMessage(to=team-lead) 交结果,然后 end_turn。
    const SEND_SSE =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"s1\",\"name\":\"SendMessage\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"to\\\":\\\"team-lead\\\",\\\"message\\\":\\\"my final answer is 42\\\",\\\"summary\\\":\\\"done\\\"}\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    const bodies = [_][]const u8{ SEND_SSE, T2 };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try agents.loadFromStandardPaths("");

    var home_buf: [256]u8 = undefined;
    const home = cc.util_fs.testing.uniqueDir(&home_buf, "cc-zig-sw2-f1");
    defer cc.util_fs.testing.rmrfBestEffort(home);
    try cc.util_fs.mkdirParents(home);

    var sw = swctx.SwarmContext{ .allocator = a, .home = home, .api_key = "k", .base_url = url, .model = "claude-sonnet-4-20250514", .provider_kind = .anthropic };
    defer sw.deinit();

    const perm = cc.permission.createContext(.bypass_permissions, a);
    // teammate 需要 SendMessage 在工具集里(--agent-teams 门,组件测试直接给全量含 swarm)。
    // **ctx.allocator 用 scoped arena(对齐生产 App arena)**:tool 执行内部(toToolDefinitionsFull 的
    // describe_fn 动态描述串、agent_tool 的 redescribeForContext)按 arena 生命周期分配、**无 per-desc
    // free 助手**——生产靠 App arena 批量释放。测试若用 testing.allocator 会漏 ~15 描述串 + redescribe
    // 分配。teammate 线程走 owned_prov=c_allocator(agent.zig:291),不碰 ctx.allocator → arena 仅主线程
    // 用,无跨线程竞争。结果串(r1/spawn_out/…)亦 arena 所有,不再逐个 free。
    var ctx_arena = std.heap.ArenaAllocator.init(a);
    defer ctx_arena.deinit();
    const ca = ctx_arena.allocator();
    const tool_defs = try cc.tools.toToolDefinitionsFull(ca, null, &cc.tool_prompt_ctx.PromptContext{ .agent_teams = true });
    const ctx = cc.tool_context.ToolContext{
        .allocator = ca,
        .api_client = &client,
        .tool_defs = tool_defs,
        .permission_ctx = @constCast(&perm),
        .agents = &agents,
        .swarm = &sw,
        .parent_model = "claude-sonnet-4-20250514",
    };
    _ = try cc.swarm_tools.executeTeamCreate(&ctx, "{\"name\":\"proj\"}");
    _ = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"general-purpose\",\"prompt\":\"solve it\",\"name\":\"solver\"}");

    // teammate 的 SendMessage → lead 邮箱含 "my final answer is 42"。
    var inbox_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lead_inbox = team.inboxPath(home, "proj", "team-lead", &inbox_buf);
    var got = false;
    var waited: u32 = 0;
    while (waited < 20_000) : (waited += 30) {
        var all = try mailbox.readAll(a, lead_inbox);
        defer all.deinit();
        for (all.items.items) |*m| {
            if (std.mem.indexOf(u8, m.text, "my final answer is 42") != null and
                std.mem.eql(u8, m.from, "solver")) got = true;
        }
        if (got) break;
        sleepMs(30);
    }
    try std.testing.expect(got);
    // F3 回归:teammate 的请求体带 SWARM_ADDENDUM(有 team 时 system prompt 追加)。
    if (srv.lastRequest()) |req| {
        try std.testing.expect(std.mem.indexOf(u8, req.body(), "Team collaboration (active team)") != null);
    }
    // 收尾:shutdown 让 teammate 退出,便于 sw.deinit join。
    _ = try cc.swarm_tools.executeSendMessage(&ctx, "{\"to\":\"solver\",\"message\":\"{\\\"type\\\":\\\"shutdown_request\\\",\\\"request_id\\\":\\\"r1\\\"}\",\"summary\":\"stop\"}");
    waited = 0;
    while (waited < 20_000) : (waited += 30) {
        if (sw.teammates.?.liveCount() == 0) break;
        sleepMs(30);
    }
}

// F6: broadcast "*" 送达所有成员。
test "L2 SW2 F6: SendMessage 广播送达两 teammate" {
    const a = std.testing.allocator;

    // 两 teammate 各跑一轮 end_turn 后 idle(不消费广播,广播只需送达 inbox)。
    const bodies = [_][]const u8{ T1, T1 };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try agents.loadFromStandardPaths("");

    var home_buf: [256]u8 = undefined;
    const home = cc.util_fs.testing.uniqueDir(&home_buf, "cc-zig-sw2-bc");
    defer cc.util_fs.testing.rmrfBestEffort(home);
    try cc.util_fs.mkdirParents(home);

    var sw = swctx.SwarmContext{ .allocator = a, .home = home, .api_key = "k", .base_url = url, .model = "claude-sonnet-4-20250514", .provider_kind = .anthropic };
    defer sw.deinit();
    srv.gateNextResponse();
    defer srv.releaseGatedResponse(); // release before sw.deinit joins teammates

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    const ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .api_client = &client,
        .tool_defs = empty_defs,
        .permission_ctx = @constCast(&perm),
        .agents = &agents,
        .swarm = &sw,
        .parent_model = "claude-sonnet-4-20250514",
    };
    a.free(try cc.swarm_tools.executeTeamCreate(&ctx, "{\"name\":\"proj\"}"));
    a.free(try cc.agent_tool.execute(&ctx, "{\"prompt\":\"a\",\"name\":\"alice\"}"));
    a.free(try cc.agent_tool.execute(&ctx, "{\"prompt\":\"b\",\"name\":\"bob\"}"));
    try srv.waitUntilResponseGated();

    // 广播。
    const rb = try cc.swarm_tools.executeSendMessage(&ctx, "{\"to\":\"*\",\"message\":\"standup now\",\"summary\":\"broadcast\"}");
    defer a.free(rb);
    try std.testing.expect(std.mem.indexOf(u8, rb, "\"delivered\":2") != null);
    // 两 inbox 各含 standup。
    for ([_][]const u8{ "alice", "bob" }) |nm| {
        var ib: [std.fs.max_path_bytes]u8 = undefined;
        const inbox = team.inboxPath(home, "proj", nm, &ib);
        var all = try mailbox.readAll(a, inbox);
        defer all.deinit();
        var found = false;
        for (all.items.items) |*m| {
            if (std.mem.indexOf(u8, m.text, "standup now") != null) found = true;
        }
        try std.testing.expect(found);
    }
}

test "L2 SW2: 非 lead 上下文的 Task(name) 被拒(teammate 不 spawn teammate)" {
    const a = std.testing.allocator;

    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try agents.loadFromStandardPaths("");

    var home_buf: [256]u8 = undefined;
    const home = cc.util_fs.testing.uniqueDir(&home_buf, "cc-zig-sw2-nonlead");
    defer cc.util_fs.testing.rmrfBestEffort(home);
    try cc.util_fs.mkdirParents(home);

    // teammate 视角:is_lead=false。
    var sw = swctx.SwarmContext{ .allocator = a, .home = home, .is_lead = false, .self_name = "bob" };
    defer sw.deinit();

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var dummy_client: cc.client_mod.Client = undefined;
    const ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .api_client = &dummy_client,
        .tool_defs = empty_defs,
        .permission_ctx = @constCast(&perm),
        .agents = &agents,
        .swarm = &sw,
    };
    // 非 lead 给 name → NotTeamLead(先于任何网络调用)。
    try std.testing.expectError(error.NotTeamLead, cc.agent_tool.execute(&ctx, "{\"prompt\":\"x\",\"name\":\"kid\"}"));
    // 非 lead TeamCreate → NotTeamLead。
    try std.testing.expectError(error.NotTeamLead, cc.swarm_tools.executeTeamCreate(&ctx, "{\"name\":\"t\"}"));
}
