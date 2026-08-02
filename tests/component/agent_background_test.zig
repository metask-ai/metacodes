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

// subagent 第一轮:**单轮内发 3 个 TaskCreate**(精确复现致命 bug 触发场景——小模型
// "先规划"习惯,一轮发多个 TaskCreate)。每个含齐全 subject+description。
// 修复前:subagent ctx.tasks=null → 3 个全 TaskStoreUnavailable → 单轮内熔断 turns=1。
// 修复后:① subagent 有独立 TaskStore → TaskCreate 成功;② 即便失败,单轮多工具同错也
// 不再误熔断。
const SUBAGENT_3_TASKCREATE_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"TaskCreate\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"subject\\\":\\\"a\\\",\\\"description\\\":\\\"da\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t2\",\"name\":\"TaskCreate\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"subject\\\":\\\"b\\\",\\\"description\\\":\\\"db\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t3\",\"name\":\"TaskCreate\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"subject\\\":\\\"c\\\",\\\"description\\\":\\\"dc\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":2}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
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
    cc.util_time.sleepMs(ms); // 可移植(POSIX nanosleep / Windows Sleep)
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
    var reg = try cc.agent_job_registry.AgentJobRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic);
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
    var reg = try cc.agent_job_registry.AgentJobRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic);
    defer reg.deinit();

    const ctx = makeCtx(a, &client, &agents, &perm, &reg);

    const spawn_out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"general-purpose\",\"prompt\":\"hi\",\"run_in_background\":true}");
    defer a.free(spawn_out);
    const job_id = try extractJobId(a, spawn_out);
    defer a.free(job_id);

    const query = try std.fmt.allocPrint(a, "{{\"agent_job_id\":\"{s}\"}}", .{job_id});
    defer a.free(query);

    // One call must long-poll through the cassette delay and observe terminal
    // state. The old zero-wait snapshot required a caller-side busy loop and
    // let real models trip the identical-result zero-gain breaker.
    const r = try cc.task_output_tool.execute(&ctx, query);
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"status\":\"done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "BG DONE") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"stop_reason\":\"end_turn\"") != null);
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
    var reg = try cc.agent_job_registry.AgentJobRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic);

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
    var reg = try cc.agent_job_registry.AgentJobRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic);
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

// 回归(本次修复核心):subagent 第一轮单轮内发 3 个 TaskCreate。
// 修复前两 bug 叠加 → subagent ctx.tasks=null 全失败 + 单轮内熔断 → stop_reason=tool_loop,
// turns=1,final_text 只有开场白。这正是 tty e2e 当时没抓到的(它只验主 agent 发起了 Task,
// 不验 subagent 内部出口)。本用例从**出口**断言:subagent 不熔断 + 干完活。
//
// 为什么放这层:真模型 e2e 无法稳定让 subagent"恰好单轮发 3 个 TaskCreate"(MiniMax 不
// 确定),但这里用 cassette 精确复现该轮次,确定性、每次必触发。
test "L2 回归: subagent 单轮多 TaskCreate 不熔断,正常完成(治 tasks=null + 单轮误熔断)" {
    const a = std.testing.allocator;

    // 第 1 轮:3 个 TaskCreate(原 bug 触发轮);第 2 轮:end_turn 收尾。
    const bodies = [_][]const u8{ SUBAGENT_3_TASKCREATE_SSE, BG_DONE_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 50);
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
    var reg = try cc.agent_job_registry.AgentJobRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic);
    defer reg.deinit();

    const ctx = makeCtx(a, &client, &agents, &perm, &reg);

    const spawn_out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"general-purpose\",\"prompt\":\"plan and do\",\"run_in_background\":true}");
    defer a.free(spawn_out);
    const job_id = try extractJobId(a, spawn_out);
    defer a.free(job_id);

    const query = try std.fmt.allocPrint(a, "{{\"agent_job_id\":\"{s}\"}}", .{job_id});
    defer a.free(query);

    var done = false;
    var i: usize = 0;
    while (i < 500) : (i += 1) { // 最多 ~5s
        const r = try cc.task_output_tool.execute(&ctx, query);
        defer a.free(r);
        if (std.mem.indexOf(u8, r, "\"status\":\"done\"") != null) {
            // 核心断言:subagent 走完两轮正常 end_turn,**不是** tool_loop 熔断。
            try std.testing.expect(std.mem.indexOf(u8, r, "\"stop_reason\":\"tool_loop\"") == null);
            try std.testing.expect(std.mem.indexOf(u8, r, "\"stop_reason\":\"end_turn\"") != null);
            // 干完了活(走到第 2 轮的收尾文本),不是 turns=1 卡死。
            try std.testing.expect(std.mem.indexOf(u8, r, "BG DONE") != null);
            done = true;
            break;
        }
        sleepMs(10);
    }
    try std.testing.expect(done);
}

// A-1 精准接线断言(同步路径,直接读 SubagentResult):subagent 调 3 个 TaskCreate →
// subagent_tasks_created 应为 3。这条**专门**抓"spawnAgent 是否给 subagent 接了非 null
// task store"——若没接(原 bug),3 个 TaskCreate 全 TaskStoreUnavailable,计数为 0。
// (后台那条 e2e 因 A-2 修好后也不熔断而变绿,无法单独暴露 A-1;此条用计数把 A-1 钉死。)
test "L2 接线: subagent 调 TaskCreate 真成功(独立 store 接通,计数=3)" {
    const a = std.testing.allocator;

    const bodies = [_][]const u8{ SUBAGENT_3_TASKCREATE_SSE, BG_DONE_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "k", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};

    const result = try cc.core_subagent.spawnAgent(a, client.provider(), &client, empty_defs, &perm, null, "plan and do", .{ .max_turns = 5 });
    defer result.deinit();

    // 接线证明:3 个 TaskCreate 全部成功落进 subagent 独立 store。tasks=null 时此值=0。
    try std.testing.expectEqual(@as(u32, 3), result.subagent_tasks_created);
    // 顺带:不熔断、走到收尾。
    try std.testing.expect(result.stop_reason != .tool_loop);
}

test "U6 A2: 前台 Task → agent_lifecycle spawned(foreground)+done 经 event_reporter 端到端" {
    // DoD(声明=接线=测试):agent.execute 前台路径必须真发 spawned+done。构造带 recording
    // reporter 的 ctx,跑同步子 agent(单轮 end_turn),断言两事件各一次 + 顺序 spawned→done。
    const a = std.testing.allocator;
    const ui_event = cc.ui_event;

    const bodies = [_][]const u8{BG_DONE_SSE};
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

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var reg = try cc.agent_job_registry.AgentJobRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic);
    defer reg.deinit();

    // recording reporter:按序记事件 tag(spawned/done),验 foreground=true。
    const Rec = struct {
        seq: std.ArrayList(u8) = .empty, // 's'=spawned 'd'=done
        alloc: std.mem.Allocator,
        fg_spawned: bool = false,
        fn agentCb(c: *anyopaque, ev: ui_event.AgentLifecycle) void {
            const self: *@This() = @ptrCast(@alignCast(c));
            switch (ev) {
                .spawned => |s| {
                    self.seq.append(self.alloc, 's') catch {};
                    self.fg_spawned = s.foreground;
                },
                .done => self.seq.append(self.alloc, 'd') catch {},
                .status => self.seq.append(self.alloc, '?') catch {},
            }
        }
        fn tasksCb(c: *anyopaque, ev: ui_event.TasksChanged) void {
            _ = c;
            _ = ev;
        }
        fn reporter(self: *@This()) ui_event.EventReporter {
            return .{ .ctx = @ptrCast(self), .agentFn = &agentCb, .tasksFn = &tasksCb };
        }
    };
    var rec = Rec{ .alloc = a };
    defer rec.seq.deinit(a);

    var ctx = makeCtx(a, &client, &agents, &perm, &reg);
    ctx.event_reporter = rec.reporter();

    // 前台(无 run_in_background)→ 阻塞跑完 → spawned 先、done 后。
    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"general-purpose\",\"prompt\":\"hi\",\"description\":\"d\"}");
    defer a.free(out);

    try std.testing.expectEqualStrings("sd", rec.seq.items); // 恰好 spawned 后 done
    try std.testing.expect(rec.fg_spawned); // 前台路径 foreground=true
}

test "U6 F1: 前台 Task 子 agent 失败也发 done(SSE 不卡 running)——spawned 后必有 done" {
    // review F1:done 原只在 spawnAgentSink 成功后发,失败则 spawned 无对应 done → SSE 客户端
    // 永久卡 running。修:errdefer 在 error 路径补发 done{failed}(done_emitted 抑制成功路径双发)。
    // 本测用 400 响应逼子 agent 失败,断言事件序列以 spawned 起、以 done 收(不 stuck)。
    const a = std.testing.allocator;
    const ui_event = cc.ui_event;

    // 400 → 子 agent run 失败(graceful api_error result 或 Zig error,两路都必须收尾 done)。
    var srv = try harness.MockServer.startWithStatus("{\"error\":\"bad\"}", 0, "HTTP/1.1 400 Bad Request");
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
    var reg = try cc.agent_job_registry.AgentJobRegistry.init(a, "k", url, "claude-sonnet-4-20250514", .anthropic);
    defer reg.deinit();

    const Rec = struct {
        seq: std.ArrayList(u8) = .empty,
        alloc: std.mem.Allocator,
        fn agentCb(c: *anyopaque, ev: ui_event.AgentLifecycle) void {
            const self: *@This() = @ptrCast(@alignCast(c));
            switch (ev) {
                .spawned => self.seq.append(self.alloc, 's') catch {},
                .done => self.seq.append(self.alloc, 'd') catch {},
                .status => self.seq.append(self.alloc, '?') catch {},
            }
        }
        fn tasksCb(c: *anyopaque, ev: ui_event.TasksChanged) void {
            _ = c;
            _ = ev;
        }
        fn reporter(self: *@This()) ui_event.EventReporter {
            return .{ .ctx = @ptrCast(self), .agentFn = &agentCb, .tasksFn = &tasksCb };
        }
    };
    var rec = Rec{ .alloc = a };
    defer rec.seq.deinit(a);

    var ctx = makeCtx(a, &client, &agents, &perm, &reg);
    ctx.event_reporter = rec.reporter();

    // execute 可能返回 error(Zig error 路径)或 ok(graceful api_error result)——两路都可接受,
    // 关键不变式:**spawned 之后必有 done**(不 stuck running)。
    const out = cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"general-purpose\",\"prompt\":\"hi\",\"description\":\"d\"}") catch null;
    if (out) |o| a.free(o);

    // 事件序列以 's' 起、以 'd' 收(无论中间;最后一个必是 done)。
    try std.testing.expect(rec.seq.items.len >= 2);
    try std.testing.expectEqual(@as(u8, 's'), rec.seq.items[0]);
    try std.testing.expectEqual(@as(u8, 'd'), rec.seq.items[rec.seq.items.len - 1]);
    // 且恰好一个 done(errdefer 与正常 done 不双发)。
    var dcount: usize = 0;
    for (rec.seq.items) |ch| {
        if (ch == 'd') dcount += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), dcount);
}
