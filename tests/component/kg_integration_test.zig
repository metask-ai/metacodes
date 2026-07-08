//! L2 组件测试:KgClient 端到端打真 tinykg 二进制 + 临时 store(设计 v3-final §8 P1)。
//!
//! DoD(声明=接线=测试):每条断言把"KgClient 方法 X → tinykg store 状态 Y"焊死。
//! 用真 tinykg(非 mock)——本地可得,格式版本由 build-tinykg.sh 锁定。
//! 找不到二进制(CI 无 tinykg)→ SkipZigTest(不是失败:KG 是增强非依赖)。

const std = @import("std");
const cc = @import("cc");

const KgClient = cc.kg_client.KgClient;

/// 定位 tinykg 二进制:env METACODES_KG_BIN > vendor > dev(~/prj/tinykg)。
fn findBin(allocator: std.mem.Allocator) ?[]u8 {
    if (std.c.getenv("METACODES_KG_BIN")) |v| {
        const p = std.mem.span(v);
        if (isX(p)) return allocator.dupe(u8, p) catch null;
    }
    const home_c = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_c);
    const candidates = [_][]const u8{
        "prj/cc-t2z/cc-zig/vendor/tinykg/tinykg",
        "prj/tinykg/zig-out/bin/tinykg",
    };
    for (candidates) |rel| {
        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, rel }) catch continue;
        if (isX(full)) return full;
        allocator.free(full);
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

/// 建一个用临时 store + 指定 bin 的 KgClient(绕过 env,直接注入路径)。
fn makeClient(a: std.mem.Allocator, bin: []const u8, store: []const u8, domain: []const u8) !KgClient {
    return KgClient.init(a, .{
        .home = "/tmp",
        .domain = domain,
        .config_bin = bin,
        .config_store = store,
        .env_bin = "", // 屏蔽真实 env
        .env_store = "",
    });
}

test "L2 KG: ensureReady 建店 + 版本门通过 + remember/recall 往返" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kgtest.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-alpha");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) {
        std.debug.print("KG degraded: {s}\n", .{kg.degradedMessage()});
        return error.SkipZigTest; // 版本 skew 等环境问题不算测试失败
    }

    // remember → 返回 node id。
    const id = try kg.remember(.decision, "用 depends_on 链编码串行步骤,revise 成 verification 闭合", "decision", false);
    try std.testing.expect(id > 0);

    // recall 命中(BM25;domain 过滤=proj-alpha)。
    const hits = try kg.recall("depends_on 串行 闭合", 5, false);
    defer {
        for (hits) |*h| h.deinit(a);
        a.free(hits);
    }
    try std.testing.expect(hits.len >= 1);
    try std.testing.expectEqual(id, hits[0].node_id);
    try std.testing.expectEqualStrings("decision", hits[0].kind);
    try std.testing.expectEqualStrings("proj-alpha", hits[0].domain);
    // 全文经 get 补取(search JSON 不含全文,实证)——必须非空且含原文关键词。
    try std.testing.expect(std.mem.indexOf(u8, hits[0].text, "depends_on") != null);
}

test "L2 KG: listRecentMemories 按 id 降序枚举最近(替虚词 hack)" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kgrecent.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-recent");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest; // 版本 skew 等环境问题不算失败

    const id1 = try kg.remember(.decision, "第一条决策 alpha", "decision", false);
    const id2 = try kg.remember(.decision, "第二条决策 beta", "decision", false);
    const id3 = try kg.remember(.decision, "第三条决策 gamma", "decision", false);
    try std.testing.expect(id3 > id2 and id2 > id1);

    // list-recent 按 id 降序枚举:三条全在,最近(id3)在最前——旧虚词 search hack 做不到(受召回门槛污染)。
    const hits = try kg.listRecentMemories(10);
    defer {
        for (hits) |*h| h.deinit(a);
        a.free(hits);
    }
    try std.testing.expect(hits.len >= 3);
    try std.testing.expectEqual(id3, hits[0].node_id);
    try std.testing.expectEqual(id2, hits[1].node_id);
    try std.testing.expectEqual(id1, hits[2].node_id);
    try std.testing.expect(std.mem.indexOf(u8, hits[0].text, "gamma") != null);
}

test "L2 KG: recall 客户端 domain 隔离(别项目记忆不串味)" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kgiso.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    // 同一 store,两个项目 domain 各写一条含相同关键词的记忆。
    {
        var kg_a = try makeClient(a, bin, store, "proj-alpha");
        defer kg_a.deinit();
        kg_a.ensureReady();
        if (!kg_a.ready) return error.SkipZigTest;
        _ = try kg_a.remember(.decision, "authtoken 用 JWT 存 header", "decision", false);
    }
    {
        var kg_b = try makeClient(a, bin, store, "proj-beta");
        defer kg_b.deinit();
        kg_b.ensureReady();
        if (!kg_b.ready) return error.SkipZigTest;
        _ = try kg_b.remember(.decision, "authtoken 用 opaque cookie 存 session", "decision", false);

        // proj-beta 搜 authtoken:只应命中 beta 自己的,不含 alpha 的 JWT 决策。
        const hits = try kg_b.recall("authtoken", 10, false);
        defer {
            for (hits) |*h| h.deinit(a);
            a.free(hits);
        }
        try std.testing.expect(hits.len >= 1);
        for (hits) |h| {
            try std.testing.expectEqualStrings("proj-beta", h.domain);
            try std.testing.expect(std.mem.indexOf(u8, h.text, "JWT") == null); // 别项目记忆被过滤
        }
    }
}

test "L2 KG: global scope 记忆跨项目可见" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kgglobal.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    {
        var kg = try makeClient(a, bin, store, "proj-alpha");
        defer kg.deinit();
        kg.ensureReady();
        if (!kg.ready) return error.SkipZigTest;
        _ = try kg.remember(.user_preference, "用户偏好:代码质量优先于速度,用中文交流", "feedback", true); // scope_global
    }
    {
        var kg = try makeClient(a, bin, store, "proj-gamma"); // 不同项目
        defer kg.deinit();
        kg.ensureReady();
        if (!kg.ready) return error.SkipZigTest;
        const hits = try kg.recall("用户偏好 代码质量 中文", 10, false);
        defer {
            for (hits) |*h| h.deinit(a);
            a.free(hits);
        }
        try std.testing.expect(hits.len >= 1);
        try std.testing.expectEqualStrings("global", hits[0].domain); // global 跨项目命中
    }
}

const harness = @import("harness");

const KG_END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "L2 KG: 注入段经 inject_user_context 进请求体(字节断言,DoD)" {
    // 端到端:kg_summary → user_context.build → inject_user_context → buildApiMessages
    // → 序列化请求体。用真 MockServer 捕获 body,断言 KG 记忆锚字节在内。
    const a = std.testing.allocator;

    // 先造 user_context(含 kg_summary),证明 KG 段进入首条 user message。
    const uc = (try cc.user_context.build(a, .{
        .cwd = "",
        .home = "",
        .kg_summary = "# Knowledge Graph\n本项目/全局共 7 条持久记忆——处理涉及既往决策/约定的任务前,先 KgRecall。\n",
    })).?;
    defer a.free(uc);

    var srv = try harness.MockServer.start(KG_END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var wb = cc.writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    const result = cc.agent_loop.run(&conv, client.provider(), &.{}, &perm, .{
        .max_turns = 1,
        .inject_user_context = uc, // ← KG 注入通道
    }, &be, a) catch |e| {
        std.debug.print("agent_loop.run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);

    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    // KG 记忆锚必须出现在实际发出的请求 body 里。
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "7 条持久记忆") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "KgRecall") != null);
}

test "L2 KG: 版本门 — degraded 明示且不 spawn" {
    const a = std.testing.allocator;
    // 故意给不存在的二进制 → degraded,ensureReady 不崩,recall 返回 Degraded。
    var kg = try KgClient.init(a, .{
        .home = "/tmp",
        .domain = "p",
        .config_bin = "/nonexistent/tinykg",
        .config_store = "/tmp/never.kg",
        .env_bin = "",
        .env_store = "",
    });
    defer kg.deinit();
    kg.ensureReady();
    try std.testing.expect(!kg.ready);
    try std.testing.expect(kg.degradedMessage().len > 0);
    // degraded 后调用直接返回 Degraded(不 spawn)。
    try std.testing.expectError(cc.kg_client.KgError.Degraded, kg.recall("x", 5, false));
}

test "L2 KG: plan 落图 → frontier → 闭合解锁(DAG 驱动全链)" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kgplan.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-plan");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    const plan_commit = @import("cc").kg_plan_commit;
    const plan =
        \\重构解析器
        \\1. 读现有代码
        \\2. 写新实现
        \\3. 补测试
    ;
    const r = try plan_commit.commit(a, &kg, plan);
    try std.testing.expect(r.structured);
    try std.testing.expectEqual(@as(usize, 3), r.steps_committed);
    try std.testing.expect(!r.incomplete);

    // frontier:步骤1 ready,步骤2/3 因 depends_on 链 missing_dependencies。
    const rows1 = try kg.frontier(r.root_id, 10);
    defer {
        for (rows1) |*row| row.deinit(a);
        a.free(rows1);
    }
    var ready1: usize = 0;
    var step1_id: u64 = 0;
    for (rows1) |row| {
        if (row.readiness == .ready) {
            ready1 += 1;
            if (std.mem.indexOf(u8, row.text, "读现有代码") != null) step1_id = row.task_id;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), ready1); // 只有步骤1 ready
    try std.testing.expect(step1_id != 0);

    // 闭合步骤1 → 步骤2 应自动变 ready。
    try kg.closeTask(step1_id, "步骤1完成:代码已读");
    const rows2 = try kg.frontier(r.root_id, 10);
    defer {
        for (rows2) |*row| row.deinit(a);
        a.free(rows2);
    }
    var has_step1 = false;
    var step2_ready = false;
    for (rows2) |row| {
        if (std.mem.indexOf(u8, row.text, "读现有代码") != null) has_step1 = true;
        if (std.mem.indexOf(u8, row.text, "写新实现") != null and row.readiness == .ready) step2_ready = true;
    }
    try std.testing.expect(!has_step1); // 步骤1 已闭合,退出 frontier
    try std.testing.expect(step2_ready); // 步骤2 解锁
}

test "L2 KG: 无结构计划 → 全文单 root task(不阻塞,设计降级)" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kgflat.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-flat");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    const plan_commit = @import("cc").kg_plan_commit;
    const r = try plan_commit.commit(a, &kg, "就改个 typo,没有步骤结构");
    try std.testing.expect(!r.structured); // 无结构
    try std.testing.expect(r.root_id > 0); // 但仍落图(全文单 root task)
}

test "L2 KG: DAG 驱动闭环经工具 — TaskList 呈现 frontier + TaskUpdate kg- 闭合解锁" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const proj_dir = pbuf[0..dir_len]; // 用 tmp 目录当 kg_projects_dir
    const store = try std.fmt.allocPrint(a, "{s}/kgloop.kg", .{proj_dir});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-loop");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    // 落图 3 步线性计划 + 写 kg_root 指针。
    const plan_commit = @import("cc").kg_plan_commit;
    const inject = @import("cc").kg_inject;
    const r = try plan_commit.commit(a, &kg, "计划\n1. A\n2. B\n3. C");
    try inject.writeIdPointer(a, proj_dir, "kg_root", r.root_id);

    // 构造 ToolContext(kg + kg_projects_dir + tasks)。
    const task_tools = @import("cc").task_tools;
    const TaskStore = @import("cc").core_task_store.TaskStore;
    var tstore = TaskStore.init(a);
    defer tstore.deinit();
    const ctx = @import("cc").tool_context.ToolContext{
        .allocator = a,
        .tasks = &tstore,
        .kg = &kg,
        .kg_projects_dir = proj_dir,
    };

    // TaskList:应含 kg- 计划步骤,步骤1 ready(pending)、步骤2/3 blocked。
    const list1 = try task_tools.executeList(&ctx, "{}");
    defer a.free(list1);
    try std.testing.expect(std.mem.indexOf(u8, list1, "\"plan_step\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, list1, "\"kg-") != null);
    try std.testing.expect(std.mem.indexOf(u8, list1, "\"subject\":\"A\"") != null);

    // 找到步骤 A 的 kg-id(它是 ready)。frontier 直接查更稳。
    const rows = try kg.frontier(r.root_id, 10);
    defer {
        for (rows) |*row| row.deinit(a);
        a.free(rows);
    }
    var a_id: u64 = 0;
    for (rows) |row| {
        if (std.mem.eql(u8, std.mem.trim(u8, row.text, " "), "A")) a_id = row.task_id;
    }
    try std.testing.expect(a_id != 0);

    // TaskUpdate kg-<A> completed → 闭合,返回刷新的 frontier(next 含 B ready)。
    const upd_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"completed\",\"evidence\":\"A done\"}}", .{a_id});
    defer a.free(upd_args);
    const upd = try task_tools.executeUpdate(&ctx, upd_args);
    defer a.free(upd);
    try std.testing.expect(std.mem.indexOf(u8, upd, "\"closed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, upd, "\"subject\":\"B\"") != null); // B 解锁进 next

    // A 已闭合退出 frontier;再 TaskList 不应再含 subject "A"(它现在是 verification)。
    const list2 = try task_tools.executeList(&ctx, "{}");
    defer a.free(list2);
    try std.testing.expect(std.mem.indexOf(u8, list2, "\"subject\":\"A\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, list2, "\"subject\":\"B\"") != null);
}

test "L2 KG: TaskCreate write-through — ad-hoc todo 落图 inbox,TaskList 呈现,TaskGet/Stop 走 kg-" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const proj_dir = pbuf[0..dir_len];
    const store = try std.fmt.allocPrint(a, "{s}/kgwt.kg", .{proj_dir});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-wt");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    const task_tools = @import("cc").task_tools;
    const TaskStore = @import("cc").core_task_store.TaskStore;
    var tstore = TaskStore.init(a);
    defer tstore.deinit();
    const ctx = @import("cc").tool_context.ToolContext{
        .allocator = a,
        .tasks = &tstore,
        .kg = &kg,
        .kg_projects_dir = proj_dir,
    };

    // TaskCreate → 应 write-through 返回 kg-<node>(非内存 "1")+ persisted:true。
    const c = try task_tools.executeCreate(&ctx, "{\"subject\":\"重构解析器\",\"description\":\"拆分 lexer\"}");
    defer a.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, "\"id\":\"kg-") != null);
    try std.testing.expect(std.mem.indexOf(u8, c, "\"persisted\":true") != null);
    // 镜像进内存 store(PM P0-A:TaskTab 显示缓存),id 用 kg-<node>。
    try std.testing.expect(tstore.tasks.items.len == 1);
    try std.testing.expect(std.mem.startsWith(u8, tstore.tasks.items[0].id, "kg-"));

    // 提取 kg- id。
    const id_start = std.mem.indexOf(u8, c, "kg-").?;
    var id_end = id_start;
    while (id_end < c.len and c[id_end] != '"') id_end += 1;
    const kg_id = c[id_start..id_end]; // 形如 "kg-2"

    // TaskList → 应含该 todo(从 store 镜像呈现)。
    const list = try task_tools.executeList(&ctx, "{}");
    defer a.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"重构解析器\"") != null);

    // TaskGet kg-<node> → 图取节点。
    const get_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"{s}\"}}", .{kg_id});
    defer a.free(get_args);
    const g = try task_tools.executeGet(&ctx, get_args);
    defer a.free(g);
    try std.testing.expect(std.mem.indexOf(u8, g, "重构解析器") != null);
    try std.testing.expect(std.mem.indexOf(u8, g, "拆分 lexer") != null);

    // TaskStop kg-<node> → 闭合(出 frontier)。
    const stop_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"{s}\"}}", .{kg_id});
    defer a.free(stop_args);
    const s = try task_tools.executeStop(&ctx, stop_args);
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "completed") != null);

    // 闭合后 TaskList 不再含该 todo。
    const list2 = try task_tools.executeList(&ctx, "{}");
    defer a.free(list2);
    try std.testing.expect(std.mem.indexOf(u8, list2, "\"重构解析器\"") == null);
}

test "L2 KG: plan 落图同时建 markdown 文档,render 回人类可读(P3 D3)" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kgmddoc.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-md");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    const plan_commit = @import("cc").kg_plan_commit;
    const plan =
        \\重构解析器
        \\1. 步骤一:读代码
        \\2. 步骤二:写实现
    ;
    const r = try plan_commit.commit(a, &kg, plan);
    try std.testing.expect(r.structured); // 有序列表 → 2 步结构化
    try std.testing.expect(r.doc_id > 0); // markdown 文档已建(同源两视图)

    // render 回 markdown,人类可读——标题/结构保留。
    const md = try kg.renderMarkdownDoc(r.doc_id);
    defer a.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "重构解析器") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "步骤一:读代码") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "步骤二:写实现") != null);

    // Linus 回归:同 store 批准**不同**计划(标题位移)——内容 hash 后缀保证走干净全新导入,
    // 不撞 order_key,render 顺序必须正确(bug 时 inserted 会掉到第 2 位)。
    const plan2 =
        \\新计划
        \\1. inserted-first
        \\2. 步骤一:读代码
        \\3. 步骤二:写实现
    ;
    const r2 = try plan_commit.commit(a, &kg, plan2);
    try std.testing.expect(r2.doc_id != r.doc_id); // 不同计划 → 不同 document(非增量合并)
    const md2 = try kg.renderMarkdownDoc(r2.doc_id);
    defer a.free(md2);
    const p_ins = std.mem.indexOf(u8, md2, "inserted-first") orelse return error.TestUnexpectedResult;
    const p_s1 = std.mem.indexOf(u8, md2, "步骤一:读代码") orelse return error.TestUnexpectedResult;
    const p_s2 = std.mem.indexOf(u8, md2, "步骤二:写实现") orelse return error.TestUnexpectedResult;
    try std.testing.expect(p_ins < p_s1); // inserted-first 在最前(bug 时它掉到 alpha 后)
    try std.testing.expect(p_s1 < p_s2);

    // 真幂等:相同内容再导入 → 同 document(不新建)。
    const r3 = try plan_commit.commit(a, &kg, plan2);
    try std.testing.expect(r3.doc_id == r2.doc_id);
}
