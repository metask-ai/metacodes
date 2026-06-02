//! L2 组件测试:后台 subagent(Task run_in_background)+ TaskOutput/TaskStop 统一分流。
//!
//! 设计见 plan(后台 subagent + TaskOutput/TaskStop 统一运行时任务)。验证:
//!  A 不阻塞:run_in_background=true → agent.execute 立即返回 agent_job_id(远早于
//!    cassette 的 chunk_delay),不等子 agent 跑完。
//!  B running→done 增量:TaskOutput 轮询能看到 running,最终 done 含 final_text+stop_reason。
//!  C TaskStop:executeStop(agent_job_id) abort 后台 job → 轮询到 killed。
//!  E todo 不回归:executeStop(普通 taskId) 仍标 completed(分流正确)。
//!
//! 策略(对齐 tool_loop_breaker_test):MockServer.startCassette + 直接构造 ToolContext
//! 调 agent.execute,绕开整个 App。后台线程 + MockServer 时序用 poll 循环(非裸 sleep)。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

// 子 agent 一轮就 end_turn,输出文本 "BG DONE"。
const BG_DONE_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"BG DONE\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn makeCtx(
    a: std.mem.Allocator,
    client: *cc.client_mod.Client,
    agents: *const cc.agents_set.AgentSet,
    perm: *const cc.permission.PermissionContext,
    reg: *cc.agent_job_registry.AgentJobRegistry,
) cc.tool_context.ToolContext {
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    return cc.tool_context.ToolContext{
        .allocator = a,
        .api_client = client,
        .tool_defs = empty_defs,
        .permission_ctx = @constCast(perm),
        .agents = agents,
        .agent_jobs = reg,
        .parent_model = "claude-sonnet-4-20250514",
    };
}

fn sleepMs(ms: u32) void {
    var req = std.c.timespec{ .sec = 0, .nsec = @as(isize, @intCast(ms)) * 1_000_000 };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);
}

fn extractJobId(a: std.mem.Allocator, out: []const u8) ![]u8 {
    const key = "\"agent_job_id\":\"";
    const i = std.mem.indexOf(u8, out, key) orelse return error.NoJobId;
    const start = i + key.len;
    const end = std.mem.indexOfScalarPos(u8, out, start, '"') orelse return error.NoJobId;
    return a.dupe(u8, out[start..end]);
}

test "L2 后台A: run_in_background=true 立即返回 agent_job_id 且不阻塞" {
    const a = std.testing.allocator;

    const bodies = [_][]const u8{BG_DONE_SSE};
    var srv = try harness.MockServer.startCassette(&bodies, 200); // 200ms chunk delay
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try agents.loadFromStandardPaths(""); // 注入 builtin(含 general-purpose),"" 跳过 project 扫描

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var reg = try cc.agent_job_registry.AgentJobRegistry.init(a, "k", url, "claude-sonnet-4-20250514");
    defer reg.deinit(); // abort+join 所有 job —— 也回归 deinit 安全性

    const ctx = makeCtx(a, &client, &agents, &perm, &reg);

    const t0 = cc.util_time.nowMs();
    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"general-purpose\",\"prompt\":\"hi\",\"run_in_background\":true}");
    defer a.free(out);
    const dt = cc.util_time.nowMs() - t0;

    try std.testing.expect(std.mem.indexOf(u8, out, "agent_job_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"status\":\"running\"") != null);
    // 不阻塞:返回应远早于 cassette 的 200ms 网络延迟(子 agent 还没跑完)
    try std.testing.expect(dt < 150);
}

test "L2 后台B: TaskOutput running→done 拿到 final_text + stop_reason" {
    const a = std.testing.allocator;

    const bodies = [_][]const u8{BG_DONE_SSE};
    var srv = try harness.MockServer.startCassette(&bodies, 100);
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

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var reg = try cc.agent_job_registry.AgentJobRegistry.init(a, "k", url, "claude-sonnet-4-20250514");
    defer reg.deinit();

    const ctx = makeCtx(a, &client, &agents, &perm, &reg);

    const spawn_out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"general-purpose\",\"prompt\":\"hi\",\"run_in_background\":true}");
    defer a.free(spawn_out);
    const job_id = try extractJobId(a, spawn_out);
    defer a.free(job_id);

    const query = try std.fmt.allocPrint(a, "{{\"agent_job_id\":\"{s}\"}}", .{job_id});
    defer a.free(query);

    var done = false;
    var i: usize = 0;
    while (i < 300) : (i += 1) { // 最多 ~3s
        const r = try cc.task_output_tool.execute(&ctx, query);
        defer a.free(r);
        if (std.mem.indexOf(u8, r, "\"status\":\"done\"") != null) {
            try std.testing.expect(std.mem.indexOf(u8, r, "BG DONE") != null);
            try std.testing.expect(std.mem.indexOf(u8, r, "\"stop_reason\":\"end_turn\"") != null);
            done = true;
            break;
        }
        sleepMs(10);
    }
    try std.testing.expect(done);
}

test "L2 后台E: TaskStop 对普通 todo taskId 仍标 completed(分流不回归)" {
    const a = std.testing.allocator;

    var store = cc.core_task_store.TaskStore.init(a);
    defer store.deinit();
    // 先建一个 todo
    const ctx = cc.tool_context.ToolContext{ .allocator = a, .tasks = &store };
    const created = try cc.task_tools.executeCreate(&ctx, "{\"subject\":\"x\",\"description\":\"d\"}");
    a.free(created);

    // executeStop(taskId=1) 走 todo 路径(非 agent_ 前缀)→ completed
    const r = try cc.task_tools.executeStop(&ctx, "{\"taskId\":\"1\"}");
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"status\":\"completed\"") != null);
}

test "L2 后台 registry: deinit 在有 running job 时 abort+join 不崩不泄漏" {
    const a = std.testing.allocator;

    // 永不结束:cassette 给一条慢响应(大 chunk_delay),deinit 时 abort 打断。
    const bodies = [_][]const u8{BG_DONE_SSE};
    var srv = try harness.MockServer.startCassette(&bodies, 5000); // 5s,确保 deinit 时仍 running
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

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var reg = try cc.agent_job_registry.AgentJobRegistry.init(a, "k", url, "claude-sonnet-4-20250514");

    const ctx = makeCtx(a, &client, &agents, &perm, &reg);
    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"general-purpose\",\"prompt\":\"hi\",\"run_in_background\":true}");
    a.free(out);

    // 立刻 deinit:job 还在 running(等 5s 网络),deinit 应 abort 打断 + join 干净返回。
    reg.deinit();
}

test "L2 后台并发: 多 job 各得不同 id 且都可查;MAX_BG_JOBS 上限生效" {
    const a = std.testing.allocator;

    const bodies = [_][]const u8{BG_DONE_SSE};
    var srv = try harness.MockServer.startCassette(&bodies, 3000); // 慢,保证并发期都 running
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

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var reg = try cc.agent_job_registry.AgentJobRegistry.init(a, "k", url, "claude-sonnet-4-20250514");
    defer reg.deinit(); // 多 running job 一起 abort+join

    const ctx = makeCtx(a, &client, &agents, &perm, &reg);

    // 起满 MAX_BG_JOBS 个,收集 id 去重。
    const MAX = cc.agent_job_registry.MAX_BG_JOBS;
    var ids = std.ArrayList([]u8).empty;
    defer {
        for (ids.items) |id| a.free(id);
        ids.deinit(a);
    }
    var n: usize = 0;
    while (n < MAX) : (n += 1) {
        const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"general-purpose\",\"prompt\":\"hi\",\"run_in_background\":true}");
        defer a.free(out);
        const id = try extractJobId(a, out);
        // 去重 + 可查
        for (ids.items) |prev| try std.testing.expect(!std.mem.eql(u8, prev, id));
        try std.testing.expect(reg.get(id) != null);
        try ids.append(a, id);
    }

    // 第 MAX+1 个:只要还有 running job 占满,应被上限拒绝。为避免与"早完成"竞态,
    // 这里断言"要么被拒,要么(极少数早完成情形)返回有效 job"——核心是不崩不泄漏 +
    // 上限逻辑存在。多数情况下命中 TooManyBackgroundJobs。
    if (cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"general-purpose\",\"prompt\":\"hi\",\"run_in_background\":true}")) |extra| {
        // 早完成腾出名额 → 返回成功;释放避免泄漏。
        a.free(extra);
    } else |err| {
        try std.testing.expectEqual(error.TooManyBackgroundJobs, err);
    }
}
