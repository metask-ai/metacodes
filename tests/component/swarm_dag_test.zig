//! L2 组件测试:SW3 tinykg DAG 协调面。打真 tinykg 二进制 + 临时 store。
//!
//! 核心断言(差异化优势):两 teammate 从共享 KG frontier **自领**任务,tinykg 原子租约
//! 保证**不撞车**(同一任务不被两人领)。找不到 tinykg → SkipZigTest(增强非依赖)。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const swctx = cc.swarm_context;
const swtools = cc.swarm_tools;
const teammate = cc.swarm_teammate;
const team = cc.swarm_team;
const KgClient = cc.kg_client.KgClient;

fn findBin(a: std.mem.Allocator) ?[]u8 {
    if (std.c.getenv("METACODES_KG_BIN")) |v| {
        const p = std.mem.span(v);
        if (isX(p)) return a.dupe(u8, p) catch null;
    }
    // 本构建的 vendored 二进制优先:主仓路径可能存着旧格式版本的陈旧二进制,
    // 命中它会让 L2 因版本门静默 skip。
    if (cc.util_fs.getCwd(a) catch null) |cwd| {
        defer a.free(cwd);
        if (std.fmt.allocPrint(a, "{s}/zig-out/vendor/tinykg/tinykg", .{cwd}) catch null) |local| {
            if (isX(local)) return local;
            a.free(local);
        }
    }
    const home_c = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_c);
    const cands = [_][]const u8{ "prj/cc-t2z/metacodes/zig-out/vendor/tinykg/tinykg", "prj/tinykg/zig-out/bin/tinykg", "bin/tinykg" };
    for (cands) |rel| {
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ home, rel }) catch continue;
        if (isX(full)) return full;
        a.free(full);
    }
    return null;
}
fn isX(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(buf[0..path.len :0].ptr, std.c.X_OK) == 0;
}
fn sleepMs(ms: u32) void {
    cc.util_time.sleepMs(ms); // 可移植(POSIX nanosleep / Windows Sleep)
}

const TURN =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "L2 SW3: 两 teammate 从共享 frontier 自领任务,租约互斥不撞车" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    // 临时 store + kg_projects_dir(inbox 指针落此)。
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(std.testing.io, &pbuf);
    const base = pbuf[0..dlen];
    const store = try std.fmt.allocPrint(a, "{s}/dag.kg", .{base});
    defer a.free(store);
    const projects_dir = try std.fmt.allocPrint(a, "{s}/projdir", .{base});
    defer a.free(projects_dir);
    try cc.util_fs.mkdirParents(projects_dir);

    var kg = try KgClient.init(a, .{ .home = base, .domain = "swarm-dag", .config_bin = bin, .config_store = store, .env_bin = "", .env_store = "" });
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    // 建共享 inbox root + 写指针(模拟 TeamCreate 的 ensureSharedTaskRoot)。
    const root = try kg.createTask("团队共享待办", "inbox_root");
    try cc.kg_inject.writeIdPointer(a, projects_dir, "kg_inbox", root);
    // 建 3 个 ready 无依赖子任务(lead TaskCreate 等价)。
    const t1 = try kg.createChildTask(root, "task ALPHA: do the first thing", "todo");
    const t2 = try kg.createChildTask(root, "task BRAVO: do the second thing", "todo");
    const t3 = try kg.createChildTask(root, "task CHARLIE: do the third thing", "todo");
    _ = .{ t1, t2, t3 };

    // 直接测自领纯函数(绕开线程调度不确定性):三次自领轮流领到不同任务(领过的不再 ready 无主)。
    const claimed1 = teammate.tryClaimFrontierTask(a, &kg, projects_dir, "agent-one") orelse return error.NoClaim1;
    defer a.free(claimed1.prompt);
    const claimed2 = teammate.tryClaimFrontierTask(a, &kg, projects_dir, "agent-two") orelse return error.NoClaim2;
    defer a.free(claimed2.prompt);
    const claimed3 = teammate.tryClaimFrontierTask(a, &kg, projects_dir, "agent-three") orelse return error.NoClaim3;
    defer a.free(claimed3.prompt);

    // 三次自领拿到三个**不同**任务 id(租约标记:领过的不再 ready 无主)。
    try std.testing.expect(claimed1.task_id != claimed2.task_id);
    try std.testing.expect(claimed1.task_id != claimed3.task_id);
    try std.testing.expect(claimed2.task_id != claimed3.task_id);
    // 是 assigned-task 信封。
    try std.testing.expect(std.mem.indexOf(u8, claimed1.prompt, "<assigned-task") != null);
    try std.testing.expect(std.mem.indexOf(u8, claimed1.prompt, "<task-packet>{") != null);
    try std.testing.expect(std.mem.indexOf(u8, claimed1.prompt, "\"mode\":\"task-packet\"") != null);
    // 三任务全被领走后,第四次自领无可领 → null。
    try std.testing.expect(teammate.tryClaimFrontierTask(a, &kg, projects_dir, "agent-four") == null);

    // 领到的任务在 frontier 上标了 claimed_by(不再无主)。
    const rows = try kg.frontier(root, 50);
    defer {
        for (rows) |*r| r.deinit(kg.allocator);
        kg.allocator.free(rows);
    }
    var claimed_leaves: usize = 0;
    for (rows) |*r| {
        if (r.role == .leaf and r.status == .claimed and r.claimed_by != null) claimed_leaves += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), claimed_leaves);

    // Regression: self-claim holder and TaskUpdate closer must be the same
    // host-injected name@team string. The old split used agent-one to claim but
    // a random SessionId to close, which task-status-v1 correctly rejects.
    var tasks = cc.core_task_store.TaskStore.init(a);
    defer tasks.deinit();
    const ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .tasks = &tasks,
        .kg = &kg,
        .kg_projects_dir = projects_dir,
        .kg_agent_ident = "agent-one",
    };
    const close_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"completed\",\"conclusion\":\"agent-one verified completion\"}}", .{claimed1.task_id});
    defer a.free(close_args);
    const closed = try cc.task_tools.executeUpdate(&ctx, close_args);
    defer a.free(closed);
    try std.testing.expect(std.mem.indexOf(u8, closed, "\"closed\":true") != null);
    try std.testing.expectEqual(cc.kg_client.TaskStatus.completed, try kg.taskStatus(claimed1.task_id));
}

test "L2 SW3 F1: 同一任务二次 claim 直接 ClaimHeld(租约互斥硬证)" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/held.kg", .{pbuf[0..dlen]});
    defer a.free(store);

    var kg = try KgClient.init(a, .{ .home = pbuf[0..dlen], .domain = "held", .config_bin = bin, .config_store = store, .env_bin = "", .env_store = "" });
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    const root = try kg.createTask("root", "inbox_root");
    const t = try kg.createChildTask(root, "the one task", "todo");
    // agent-A 领取成功。
    try kg.claimTask(t, "agent-A");
    // agent-B 领同一任务 → 必被拒(ClaimHeld → KgError)。这才是 done_when 的"互斥"硬证。
    try std.testing.expectError(cc.kg_client.KgError.Data, kg.claimTask(t, "agent-B"));
    // A 释放后 B 可领。
    try kg.releaseTask(t, "agent-A");
    try kg.claimTask(t, "agent-B");
}

test "L2 SW3 M3: 两线程并发自领同一 frontier,无任务被领两次(各自独立 KgClient)" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(std.testing.io, &pbuf);
    const base = pbuf[0..dlen];
    const store = try std.fmt.allocPrint(a, "{s}/conc.kg", .{base});
    defer a.free(store);
    const projects_dir = try std.fmt.allocPrint(a, "{s}/pd", .{base});
    defer a.free(projects_dir);
    try cc.util_fs.mkdirParents(projects_dir);

    // seed store + 6 ready 任务。
    var seed = try KgClient.init(a, .{ .home = base, .domain = "conc", .config_bin = bin, .config_store = store, .env_bin = "", .env_store = "" });
    defer seed.deinit();
    seed.ensureReady();
    if (!seed.ready) return error.SkipZigTest;
    const root = try seed.createTask("root", "inbox_root");
    try cc.kg_inject.writeIdPointer(a, projects_dir, "kg_inbox", root);
    var ti: usize = 0;
    while (ti < 6) : (ti += 1) {
        var tb: [64]u8 = undefined;
        _ = try seed.createChildTask(root, try std.fmt.bufPrint(&tb, "task number {d}", .{ti}), "todo");
    }

    // 两线程各自独立 KgClient(c_allocator,H1 修法),各自 loop 自领直到无可领,记录领到的 task_id。
    const Worker = struct {
        store: []const u8,
        base: []const u8,
        pd: []const u8,
        bin: []const u8,
        name: []const u8,
        claimed: std.ArrayList(u64) = .empty,
        ok: bool = true,

        fn run(self: *@This()) void {
            const ca = std.heap.c_allocator;
            var kc = KgClient.init(ca, .{ .home = self.base, .domain = "conc", .config_bin = self.bin, .config_store = self.store, .env_bin = "", .env_store = "" }) catch {
                self.ok = false;
                return;
            };
            defer kc.deinit();
            kc.ensureReady();
            if (!kc.ready) {
                self.ok = false;
                return;
            }
            while (teammate.tryClaimFrontierTask(ca, &kc, self.pd, self.name)) |claim| {
                ca.free(claim.prompt);
                self.claimed.append(ca, claim.task_id) catch {};
            }
        }
    };
    var w1 = Worker{ .store = store, .base = base, .pd = projects_dir, .bin = bin, .name = "worker-1" };
    var w2 = Worker{ .store = store, .base = base, .pd = projects_dir, .bin = bin, .name = "worker-2" };
    defer w1.claimed.deinit(std.heap.c_allocator);
    defer w2.claimed.deinit(std.heap.c_allocator);
    const th1 = try std.Thread.spawn(.{}, Worker.run, .{&w1});
    const th2 = try std.Thread.spawn(.{}, Worker.run, .{&w2});
    th1.join();
    th2.join();
    try std.testing.expect(w1.ok and w2.ok);

    // 关键(租约互斥硬证):两线程领到的 task_id 集合**不相交**(没有任务被两人领),合计=6(全领完)。
    // 注:不要求两线程各领 >0——一个线程抢先领完 6 个仍是正确的互斥(无双领);要求的是 no-overlap。
    try std.testing.expectEqual(@as(usize, 6), w1.claimed.items.len + w2.claimed.items.len);
    for (w1.claimed.items) |id1| {
        for (w2.claimed.items) |id2| {
            try std.testing.expect(id1 != id2); // 无重叠 = 真并发下租约互斥(H1 修法验证:两独立 client 不撞车)
        }
    }
}

test "L2 SW3: TeamCreate 建共享 root + teammate 线程自领跑起来(端到端)" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var srv = try harness.MockServer.startCassette(&[_][]const u8{ TURN, TURN, TURN }, 0);
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dlen = try tmp.dir.realPath(std.testing.io, &pbuf);
    const base = pbuf[0..dlen];
    const store = try std.fmt.allocPrint(a, "{s}/dag2.kg", .{base});
    defer a.free(store);
    const projects_dir = try std.fmt.allocPrint(a, "{s}/pd", .{base});
    defer a.free(projects_dir);
    try cc.util_fs.mkdirParents(projects_dir);
    const home = try std.fmt.allocPrint(a, "{s}/home", .{base});
    defer a.free(home);
    try cc.util_fs.mkdirParents(home);

    var kg = try KgClient.init(a, .{ .home = base, .domain = "swarm-dag2", .config_bin = bin, .config_store = store, .env_bin = "", .env_store = "" });
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    var sw = swctx.SwarmContext{ .allocator = a, .home = home, .api_key = "k", .base_url = url, .model = "claude-sonnet-4-20250514", .provider_kind = .anthropic };
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
        .kg = &kg,
        .kg_projects_dir = projects_dir,
        .parent_model = "claude-sonnet-4-20250514",
    };
    // TeamCreate → 建共享 root。
    a.free(try swtools.executeTeamCreate(&ctx, "{\"name\":\"proj\"}"));
    // 指针写好了。
    const root = cc.kg_inject.readIdPointer(a, projects_dir, "kg_inbox") orelse return error.NoRoot;
    try std.testing.expect(root > 0);
    // 挂一个 ready 任务供 teammate 自领。
    _ = try kg.createChildTask(root, "task from lead: process the data", "todo");

    // spawn 一个 teammate(prompt 让它先跑一轮 end_turn → idle → 自领 root 上的任务)。
    a.free(try cc.agent_tool.execute(&ctx, "{\"prompt\":\"await work\",\"name\":\"worker\"}"));

    // 等 teammate 自领(claimed_by 出现在 frontier)。SELF_CLAIM_POLL_MS=2500,给足时间。
    var claimed = false;
    var waited: u32 = 0;
    while (waited < 12000) : (waited += 100) {
        const rows = kg.frontier(root, 50) catch {
            sleepMs(100);
            continue;
        };
        var any = false;
        for (rows) |*r| {
            if (r.role == .leaf and r.claimed_by != null) any = true;
        }
        for (rows) |*r| r.deinit(kg.allocator);
        kg.allocator.free(rows);
        if (any) {
            claimed = true;
            break;
        }
        sleepMs(100);
    }
    try std.testing.expect(claimed);

    // SW4 releaseHeldTasks 验证:teammate 自领了任务(claimed_by 非空)。shutdown → 退出时释放租约
    // → 该任务回到无主(claimed_by=null),可被别人重领。
    var ib: [std.fs.max_path_bytes]u8 = undefined;
    const winbox = team.inboxPath(home, "proj", "worker", &ib);
    try cc.swarm_mailbox.deliver(a, winbox, "team-lead", "{\"type\":\"shutdown_request\",\"request_id\":\"r1\"}", null, null);
    waited = 0;
    while (waited < 6000) : (waited += 50) {
        if (sw.teammates.?.liveCount() == 0) break;
        sleepMs(50);
    }
    // 退出后:worker 领的任务租约已释放(claimed_by=null 或已闭合出 frontier)。
    // 只要没有"claimed_by 仍是 worker 但任务还 open"的卡死叶子即可。
    const rows2 = try kg.frontier(root, 50);
    defer {
        for (rows2) |*r| r.deinit(kg.allocator);
        kg.allocator.free(rows2);
    }
    var stuck = false;
    for (rows2) |*r| {
        if (r.role == .leaf and r.claimed_by != null) {
            if (std.mem.indexOf(u8, r.claimed_by.?, "worker") != null) stuck = true;
        }
    }
    try std.testing.expect(!stuck); // 无被退出 teammate 卡住的租约(releaseHeldTasks 生效)
}
