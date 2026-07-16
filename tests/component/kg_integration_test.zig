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
        "prj/cc-t2z/metacodes/vendor/tinykg/tinykg",
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

test "L2 KG: scoped 自动召回 — 相关请求注入、无关请求不注入(相关性门,L0 双侧)" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kgscoped.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-scoped");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    _ = try kg.remember(.observation, "src/kg/client.zig 用子进程驱动 tinykg 集成,进程隔离崩溃", "module", false);

    var ab = cc.abort.AbortSignal.init();

    // 正向:相关请求 → 注入且含记忆关键词。
    {
        var conv = cc.conversation.Conversation.init(a);
        defer conv.deinit();
        try conv.appendText(.user, "client.zig 是怎么和 tinykg 集成的?子进程还是嵌入库集成方式?");
        const inj = try cc.kg_scoped_recall.build(a, &kg, &conv, &ab);
        defer if (inj) |s| a.free(s);
        try std.testing.expect(inj != null);
        try std.testing.expect(std.mem.indexOf(u8, inj.?, "子进程") != null);
    }
    // 负向:零重合无关请求 → 不注入(相关性门挡答案缺席噪声;PM P0 逼可证伪的两侧测试)。
    {
        var conv = cc.conversation.Conversation.init(a);
        defer conv.deinit();
        try conv.appendText(.user, "今天天气怎么样适合出去散步吗周末有什么安排");
        const inj = try cc.kg_scoped_recall.build(a, &kg, &conv, &ab);
        defer if (inj) |s| a.free(s);
        try std.testing.expect(inj == null);
    }
}

test "L2 KG: typed recall — module/bug/decision 按 schema_type 过滤(本体最小切片)" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kgonto.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-onto");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    // 模拟 executeRemember 映射:module/bug → observation node + schema_type;decision → decision。
    _ = try kg.remember(.observation, "client.zig 用子进程 CLI 驱动 tinykg 集成", "module", false);
    _ = try kg.remember(.observation, "共享 KgClient 被 subagent 线程共享导致数据竞态", "bug", false);
    const dec_id = try kg.remember(.decision, "tinykg 用子进程集成而非嵌库,进程边界隔离崩溃", "decision", false);

    // typed recall type=module:只返 schema_type=module。decision/bug 命中 query 也被过滤掉。
    const mod_hits = try kg.recallTyped("tinykg 子进程 集成 驱动 client", 8, false, "module");
    defer {
        for (mod_hits) |*h| h.deinit(a);
        a.free(mod_hits);
    }
    try std.testing.expect(mod_hits.len >= 1);
    for (mod_hits) |h| try std.testing.expectEqualStrings("module", h.schema_type);

    // type=decision:只返 decision,且目标 decision 节点在内。
    const dec_hits = try kg.recallTyped("tinykg 集成 嵌库 隔离 进程", 8, false, "decision");
    defer {
        for (dec_hits) |*h| h.deinit(a);
        a.free(dec_hits);
    }
    try std.testing.expect(dec_hits.len >= 1);
    for (dec_hits) |h| try std.testing.expectEqualStrings("decision", h.schema_type);
    var found = false;
    for (dec_hits) |h| {
        if (h.node_id == dec_id) found = true;
    }
    try std.testing.expect(found);

    // 无 type:混合返回,schema_type 字段被**留住**(Linus HIGH-1 回归:解析后不丢弃)。
    const all_hits = try kg.recallTyped("tinykg 集成", 8, false, null);
    defer {
        for (all_hits) |*h| h.deinit(a);
        a.free(all_hits);
    }
    try std.testing.expect(all_hits.len >= 1);
    var any_typed = false;
    for (all_hits) |h| {
        if (h.schema_type.len > 0) any_typed = true;
    }
    try std.testing.expect(any_typed);
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

test "L2 KG: 项目级 schema 隔离 — 自定义类型跨项目用被 block + 清晰错误 + 孤儿自清" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kgscope.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    // proj-alpha 引入自定义类型 "migration" → auto-scope block 政策 scope 到 alpha。
    {
        var kg_a = try makeClient(a, bin, store, "proj-alpha");
        defer kg_a.deinit();
        kg_a.ensureReady();
        if (!kg_a.ready) return error.SkipZigTest;
        const resolved = cc.kg_client.resolveMemoryType("migration") orelse return error.SkipZigTest;
        const id_a = try kg_a.remember(resolved.node_kind, "alpha 做了一次 schema migration", resolved.schema_type, false);
        try std.testing.expect(id_a > 0); // 首次引入成功(演化本体:类型能长出来)
    }
    // proj-beta 用同一自定义类型 → tinykg block-at-write 拒绝 → KgError.Data(不是 Transient!)
    // + detail 点名类型(清晰可行动)+ 孤儿已自清。
    {
        var kg_b = try makeClient(a, bin, store, "proj-beta");
        defer kg_b.deinit();
        kg_b.ensureReady();
        if (!kg_b.ready) return error.SkipZigTest;
        const resolved = cc.kg_client.resolveMemoryType("migration") orelse return error.SkipZigTest;
        const res = kg_b.remember(resolved.node_kind, "beta 也想用 migration 类型", resolved.schema_type, false);
        // 关键断言:归 Data(分类修好了),不是 Transient(修前的 bug——agent 收到空的 "(Transient: )")。
        try std.testing.expectError(cc.kg_client.KgError.Data, res);
        // detail 点名了类型 "migration"(清晰错误,不是裸 SchemaProjectScopeViolation 或空串)。
        const d = kg_b.detail();
        try std.testing.expect(std.mem.indexOf(u8, d, "migration") != null);
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

test "L2 KG: 深树全链 — 嵌套子任务/branch 聚合/path/claim 租约/并行提示/闭合波前前进" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const proj_dir = pbuf[0..dir_len];
    const store = try std.fmt.allocPrint(a, "{s}/kgdeep.kg", .{proj_dir});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-deep");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    // 计划:步骤一/步骤二串行;运行中给步骤一拆两个**并行**子任务(挂步骤一下,不拍平)。
    const plan_commit = @import("cc").kg_plan_commit;
    const inject = @import("cc").kg_inject;
    const r = try plan_commit.commit(a, &kg, "深树计划\n1. 步骤一\n2. 步骤二");
    try inject.writeIdPointer(a, proj_dir, "kg_root", r.root_id);

    const rows0 = try kg.frontier(r.root_id, 10);
    var step1_id: u64 = 0;
    for (rows0) |row| {
        if (std.mem.indexOf(u8, row.text, "步骤一") != null) step1_id = row.task_id;
    }
    for (rows0) |*row| row.deinit(a);
    a.free(rows0);
    try std.testing.expect(step1_id != 0);

    // 子任务原语:挂 step 下(不直挂 project——挂根即归属,深树不拍平)。
    const sub_a = try kg.createChildTask(step1_id, "子任务甲", "todo");
    const sub_b = try kg.createChildTask(step1_id, "子任务乙", "todo");

    // frontier 深遍历:步骤一变 branch(不可执行,等子树);甲/乙是 ready 叶子,path 带"步骤一"。
    {
        const rows = try kg.frontier(r.root_id, 10);
        defer {
            for (rows) |*row| row.deinit(a);
            a.free(rows);
        }
        var step1_is_branch = false;
        var sub_a_ok = false;
        var sub_b_ready = false;
        for (rows) |row| {
            if (row.task_id == step1_id and row.role == .branch) step1_is_branch = true;
            if (row.task_id == sub_a and row.role == .leaf and row.readiness == .ready) {
                if (row.path) |p| sub_a_ok = std.mem.indexOf(u8, p, "步骤一") != null;
            }
            if (row.task_id == sub_b and row.readiness == .ready) sub_b_ready = true;
        }
        try std.testing.expect(step1_is_branch);
        try std.testing.expect(sub_a_ok); // 叶子 + path 面包屑
        try std.testing.expect(sub_b_ready);
    }

    // TaskList:两个 ready 无主叶子 → 并行 fan-out 提示;branch 不上看板;path 字段在。
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
    {
        const list = try task_tools.executeList(&ctx, "{}");
        defer a.free(list);
        try std.testing.expect(std.mem.indexOf(u8, list, "parallel_hint") != null);
        try std.testing.expect(std.mem.indexOf(u8, list, "\"path\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, list, "\"subject\":\"步骤一\"") == null);
    }

    // TaskUpdate in_progress → 认领落图(租约);他人 session 认领同任务被拒(Data 不重试)。
    {
        const claim_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"in_progress\"}}", .{sub_a});
        defer a.free(claim_args);
        const resp = try task_tools.executeUpdate(&ctx, claim_args);
        defer a.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp, "\"claimed\":true") != null);

        try std.testing.expectError(error.Data, kg.claimTask(sub_a, "other-session"));

        // 认领后只剩 1 个无主 ready → 并行提示消失;认领的步骤镜像上板(12b:
        // 本 session 的 claim 以镜像 in_progress 呈现,frontier 行被镜像去重)。
        const list = try task_tools.executeList(&ctx, "{}");
        defer a.free(list);
        try std.testing.expect(std.mem.indexOf(u8, list, "parallel_hint") == null);
        try std.testing.expect(std.mem.indexOf(u8, list, "\"subject\":\"子任务甲\",\"status\":\"in_progress\"") != null or
            std.mem.indexOf(u8, list, "\"status\":\"in_progress\"") != null);
    }

    // 闭合两个子任务 → 步骤一子树全闭 → 步骤一变 ready 叶子(波前上移);闭步骤一 → 步骤二解锁。
    try kg.closeTask(sub_a, "甲完成");
    try kg.closeTask(sub_b, "乙完成");
    {
        const rows = try kg.frontier(r.root_id, 10);
        defer {
            for (rows) |*row| row.deinit(a);
            a.free(rows);
        }
        var step1_leaf_ready = false;
        for (rows) |row| {
            if (row.task_id == step1_id and row.role == .leaf and row.readiness == .ready) step1_leaf_ready = true;
        }
        try std.testing.expect(step1_leaf_ready);
    }
    try kg.closeTask(step1_id, "步骤一整体完成");
    {
        const rows = try kg.frontier(r.root_id, 10);
        defer {
            for (rows) |*row| row.deinit(a);
            a.free(rows);
        }
        var step2_ready = false;
        for (rows) |row| {
            if (std.mem.indexOf(u8, row.text, "步骤二") != null and row.readiness == .ready) step2_ready = true;
        }
        try std.testing.expect(step2_ready);
    }
}

test "L2 KG: 12b 锚单入口 — TaskList 经 task 锚看全多计划,镜像 todo 不双列,inbox 容器不现身" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const proj_dir = pbuf[0..dir_len];
    const store_path = try std.fmt.allocPrint(a, "{s}/kganchor.kg", .{proj_dir});
    defer a.free(store_path);

    var kg = try makeClient(a, bin, store_path, "proj-anchor");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    const plan_commit = @import("cc").kg_plan_commit;
    const inject = @import("cc").kg_inject;
    // 两个计划树(锚下多计划一次看全——旧 kg_root 单指针做不到)。
    const r1 = try plan_commit.commit(a, &kg, "计划甲\n1. 甲一\n2. 甲二");
    const r2 = try plan_commit.commit(a, &kg, "计划乙\n1. 乙一\n2. 乙二");
    _ = r1;
    _ = r2;
    const aid = try kg.ensureTaskAnchorId();
    try inject.writeIdPointer(a, proj_dir, "kg_task_anchor", aid);

    const task_tools = @import("cc").task_tools;
    const TaskStore = @import("cc").core_task_store.TaskStore;
    var tstore = TaskStore.init(a);
    defer tstore.deinit();
    var ctx = @import("cc").tool_context.ToolContext{
        .allocator = a,
        .tasks = &tstore,
        .kg = &kg,
        .kg_projects_dir = proj_dir,
    };

    // write-through todo(镜像 + 图 inbox,inbox root 挂锚)。
    const created = try task_tools.executeCreate(&ctx, "{\"subject\":\"顺手待办\",\"description\":\"d\"}");
    a.free(created);

    const list = try task_tools.executeList(&ctx, "{}");
    defer a.free(list);
    // 锚单入口:两棵计划树的 ready 叶子都在(甲一/乙一;甲二被 depends_on 门住也在,blocked)。
    try std.testing.expect(std.mem.indexOf(u8, list, "\"subject\":\"甲一\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"subject\":\"乙一\"") != null);
    // 镜像 todo 只出现一次(store 遍历),frontier 行被镜像去重滤掉。
    const first_hit = std.mem.indexOf(u8, list, "\"subject\":\"顺手待办\"").?;
    try std.testing.expect(std.mem.indexOfPos(u8, list, first_hit + 1, "\"subject\":\"顺手待办\"") == null);
    // inbox root 是容器不是任务,不上看板。
    try std.testing.expect(std.mem.indexOf(u8, list, "会话待办") == null);
}

test "L2 KG: derived_from 溯源 — 认领计划步骤后 KgRemember 的记忆回链任务" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const proj_dir = pbuf[0..dir_len];
    const store_path = try std.fmt.allocPrint(a, "{s}/kgprov.kg", .{proj_dir});
    defer a.free(store_path);

    var kg = try makeClient(a, bin, store_path, "proj-prov");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    const plan_commit = @import("cc").kg_plan_commit;
    const r = try plan_commit.commit(a, &kg, "溯源计划\n1. 调查根因\n2. 写修复");
    const rows = try kg.frontier(r.root_id, 10);
    var step_id: u64 = 0;
    for (rows) |row| {
        if (std.mem.indexOf(u8, row.text, "调查根因") != null) step_id = row.task_id;
    }
    for (rows) |*row| row.deinit(a);
    a.free(rows);
    try std.testing.expect(step_id != 0);

    const task_tools = @import("cc").task_tools;
    const kg_tools_mod = @import("cc").kg_tools;
    const TaskStore = @import("cc").core_task_store.TaskStore;
    var tstore = TaskStore.init(a);
    defer tstore.deinit();
    var ctx = @import("cc").tool_context.ToolContext{
        .allocator = a,
        .tasks = &tstore,
        .kg = &kg,
        .kg_projects_dir = proj_dir,
    };

    // 认领(in_progress)→ 计划步骤镜像上板(activeKgTaskId 溯源锚可见)。
    const claim_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"in_progress\"}}", .{step_id});
    defer a.free(claim_args);
    const resp = try task_tools.executeUpdate(&ctx, claim_args);
    a.free(resp);

    // 任务执行中沉淀记忆 → 自动 derived_from 回链。
    const mem_resp = try kg_tools_mod.executeRemember(&ctx, "{\"text\":\"根因是缓存钥匙失灵\",\"kind\":\"bug\"}");
    defer a.free(mem_resp);
    const marker = "\"node_id\":";
    const mpos = std.mem.indexOf(u8, mem_resp, marker).?;
    const mem_id = blk: {
        var end = mpos + marker.len;
        while (end < mem_resp.len and mem_resp[end] >= '0' and mem_resp[end] <= '9') end += 1;
        break :blk try std.fmt.parseInt(u64, mem_resp[mpos + marker.len .. end], 10);
    };

    const nb = try kg.neighborsText(mem_id, 10);
    defer a.free(nb);
    var expect_buf: [48]u8 = undefined;
    const needle = try std.fmt.bufPrint(&expect_buf, "derived_from\t{d}", .{step_id});
    try std.testing.expect(std.mem.indexOf(u8, nb, needle) != null);
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

test "L2 KG: B/C 合并 — Write memdir markdown 自动入图,召回命中 section 正文" {
    // 声明=接线=测试(DoD):Write 工具落盘 memdir/*.md → autosync 自动 importMarkdownDoc
    // + 挂 project 子树 → recall(search --project,md:* 投影下钻)命中 section 正文。
    // 同时锁排除项:MEMORY.md(索引)绝不入图。
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const proj_dir = pbuf[0..dir_len];
    const store = try std.fmt.allocPrint(a, "{s}/kgauto.kg", .{proj_dir});
    defer a.free(store);
    // memdir = <tmp>/memory(isAutoMemPath 要 realpath 存在)
    const memdir_abs = try std.fmt.allocPrint(a, "{s}/memory", .{proj_dir});
    defer a.free(memdir_abs);
    {
        var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        @memcpy(zbuf[0..memdir_abs.len], memdir_abs);
        zbuf[memdir_abs.len] = 0;
        _ = std.c.mkdir(@ptrCast(&zbuf), 0o755);
    }

    var kg = try makeClient(a, bin, store, "proj-auto");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    const write_tool = @import("cc").write_tool;
    var rs = @import("cc").core_read_state.ReadState.init(a);
    defer rs.deinit();
    const ctx = @import("cc").tool_context.ToolContext{
        .allocator = a,
        .kg = &kg,
        .kg_projects_dir = proj_dir,
        .memdir_abs = memdir_abs,
        .read_state = &rs,
    };

    // ① 写记忆 markdown → 自动入图。
    const args = try std.fmt.allocPrint(a,
        \\{{"file_path":"{s}/memory/lesson-parser.md","content":"# parser lesson\n\n## root cause\n\nquokka tokenizer offset bug lesson body\n"}}
    , .{proj_dir});
    defer a.free(args);
    const out1 = try write_tool.execute(&ctx, args);
    defer a.free(out1);
    try std.testing.expect(std.mem.indexOf(u8, out1, "\"success\":true") != null);

    // 召回:section 正文命中(证明 import + attach + md:* 下钻全链通)。
    const hits = try kg.recall("quokka tokenizer offset", 10, false);
    defer {
        for (hits) |*h| h.deinit(a);
        a.free(hits);
    }
    try std.testing.expect(hits.len >= 1);
    var found = false;
    for (hits) |h| {
        if (std.mem.indexOf(u8, h.text, "quokka") != null) found = true;
    }
    try std.testing.expect(found);

    // ② MEMORY.md(索引)不入图:**全库节点计数不变**(比 project-scoped recall 强——
    // "入了图但 attach 失败"那种假过也会被抓,Linus 次要7)。
    const count_before_idx = kg.memoryCount();
    const args2 = try std.fmt.allocPrint(a,
        \\{{"file_path":"{s}/memory/MEMORY.md","content":"# Memory Index\n\n- xylophone unique index marker entry\n"}}
    , .{proj_dir});
    defer a.free(args2);
    const out2 = try write_tool.execute(&ctx, args2);
    defer a.free(out2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "\"success\":true") != null);
    try std.testing.expectEqual(count_before_idx, kg.memoryCount());

    // ③ memdir 外的 .md 不入图(同样全库计数断言)。
    const args3 = try std.fmt.allocPrint(a,
        \\{{"file_path":"{s}/outside-note.md","content":"# outside\n\nzeppelin outside marker body\n"}}
    , .{proj_dir});
    defer a.free(args3);
    const out3 = try write_tool.execute(&ctx, args3);
    defer a.free(out3);
    try std.testing.expectEqual(count_before_idx, kg.memoryCount());

    // ④ **旧版本退出召回(Linus BLOCKER1 回归锁)**:同一记忆文件 Edit(内容变)→ 稳定 key
    // upsert 同一 document(tinykg 增量合并替换旧投影边)→ 召回只见新版内容,旧版独特词
    // 零命中(否则每次编辑都往召回里追加一套近似副本,"KG 唯一真相"变全历史堆放场)。
    const args4 = try std.fmt.allocPrint(a,
        \\{{"file_path":"{s}/memory/lesson-parser.md","content":"# parser lesson v2\n\n## root cause\n\nquokka tokenizer offset bug REVISED narwhal conclusion\n"}}
    , .{proj_dir});
    defer a.free(args4);
    const out4 = try write_tool.execute(&ctx, args4);
    defer a.free(out4);
    try std.testing.expect(std.mem.indexOf(u8, out4, "\"success\":true") != null);
    // 新版独特词命中。
    const hits_new = try kg.recall("narwhal conclusion", 10, false);
    defer {
        for (hits_new) |*h| h.deinit(a);
        a.free(hits_new);
    }
    try std.testing.expect(hits_new.len >= 1);
    // 旧版独特词(lesson body——v2 已不含)零命中:旧投影已被 upsert 替换,不残留召回。
    const hits_old = try kg.recall("lesson body", 10, false);
    defer {
        for (hits_old) |*h| h.deinit(a);
        a.free(hits_old);
    }
    for (hits_old) |h| {
        try std.testing.expect(std.mem.indexOf(u8, h.text, "lesson body") == null);
    }

    // ⑤ **同文件不同拼写只产一个 document(canonical key 锁)**:经 `<memdir>/../memory/x.md`
    // 之类非规范拼写再写同一文件 → stable_key 派生自 canonical → 仍 upsert 同 document,
    // 全库节点计数不因拼写差异翻倍(裸 path hash 的话这里会新建一套子树)。
    const count_before_alias = kg.memoryCount();
    const args5 = try std.fmt.allocPrint(a,
        \\{{"file_path":"{s}/memory/../memory/lesson-parser.md","content":"# parser lesson v2\n\n## root cause\n\nquokka tokenizer offset bug REVISED narwhal conclusion\n"}}
    , .{proj_dir});
    defer a.free(args5);
    const out5 = try write_tool.execute(&ctx, args5);
    defer a.free(out5);
    try std.testing.expect(std.mem.indexOf(u8, out5, "\"success\":true") != null);
    try std.testing.expectEqual(count_before_alias, kg.memoryCount());

    // ⑥ **删除语义(PM P0-2 回归锁)**:Write 空内容 = 删除——空 upsert 清旧投影,
    // 该文件的正文从召回消失(否则"删错误记忆"删不掉图里的幽灵版本)。
    const args6 = try std.fmt.allocPrint(a,
        \\{{"file_path":"{s}/memory/lesson-parser.md","content":""}}
    , .{proj_dir});
    defer a.free(args6);
    const out6 = try write_tool.execute(&ctx, args6);
    defer a.free(out6);
    try std.testing.expect(std.mem.indexOf(u8, out6, "\"success\":true") != null);
    const hits_deleted = try kg.recall("narwhal conclusion", 10, false);
    defer {
        for (hits_deleted) |*h| h.deinit(a);
        a.free(hits_deleted);
    }
    for (hits_deleted) |h| {
        try std.testing.expect(std.mem.indexOf(u8, h.text, "narwhal") == null);
    }

    // ⑦ **schema_type 下推 + source_label 溯源**:重建记忆文件 → typed recall(type=document,
    // server-side --schema-type 成员集)命中 document 根,且 hit 带来源文件名(PM P1 溯源)。
    const args7 = try std.fmt.allocPrint(a,
        \\{{"file_path":"{s}/memory/lesson-parser.md","content":"# parser lesson v3\n\nquokka final lesson revision\n"}}
    , .{proj_dir});
    defer a.free(args7);
    const out7 = try write_tool.execute(&ctx, args7);
    defer a.free(out7);
    const hits_doc = try kg.recallTyped("parser lesson", 10, false, "document");
    defer {
        for (hits_doc) |*h| h.deinit(a);
        a.free(hits_doc);
    }
    try std.testing.expect(hits_doc.len >= 1);
    var labeled = false;
    for (hits_doc) |h| {
        try std.testing.expectEqualStrings("document", h.schema_type); // server-side 过滤生效
        if (std.mem.eql(u8, h.source_label, "lesson-parser.md")) labeled = true;
    }
    try std.testing.expect(labeled);

    // ⑧ **nodeMemorySource 三类判定(forget 防护安全闸的 L2 锁)**:document 根 → label+derived;
    // section/正文(external_key md-doc:...#.../content:...)→ derived 无 label;
    // 普通 KgRemember observation(无 external_key)→ 不误拦。PM 验收残留1:该判定此前仅人工
    // 真二进制验证过——固化,防"测错面"血泪三度复发。
    {
        // document 根:recallTyped(document) 的首个 hit id 即 doc 根。
        const doc_src = kg.nodeMemorySource(hits_doc[0].node_id);
        defer if (doc_src.label) |l| a.free(l);
        try std.testing.expect(doc_src.md_derived);
        try std.testing.expect(doc_src.label != null);
        // 正文节点:recall 命中 "quokka final"(observation kind,content: external_key)。
        const hits_body = try kg.recall("quokka final lesson revision", 5, false);
        defer {
            for (hits_body) |*h| h.deinit(a);
            a.free(hits_body);
        }
        var body_checked = false;
        for (hits_body) |h| {
            if (std.mem.indexOf(u8, h.text, "quokka final") == null) continue;
            const body_src = kg.nodeMemorySource(h.node_id);
            defer if (body_src.label) |l| a.free(l);
            try std.testing.expect(body_src.md_derived); // section/正文同样受 forget 防护
            try std.testing.expect(body_src.label == null);
            body_checked = true;
        }
        try std.testing.expect(body_checked);
        // 普通 typed 记忆:不误拦。
        const plain_id = try kg.remember(.observation, "plain zorro fact not from markdown", "observation", false);
        const plain_src = kg.nodeMemorySource(plain_id);
        defer if (plain_src.label) |l| a.free(l);
        try std.testing.expect(!plain_src.md_derived);
    }
}

test "L2 KG: 目标导向投影 — 任务闭合经工具写 acts_on/uses/produces ref 边(tentative,改动一/三)" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const proj_dir = pbuf[0..dir_len];
    const store = try std.fmt.allocPrint(a, "{s}/kgproj.kg", .{proj_dir});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-projection");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    const plan_commit = @import("cc").kg_plan_commit;
    const inject = @import("cc").kg_inject;
    const r = try plan_commit.commit(a, &kg, "计划\n1. A\n2. B");
    try inject.writeIdPointer(a, proj_dir, "kg_root", r.root_id);

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

    // 找步骤 A 的 kg id。
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

    // 闭合 A + 结构化投影:实际作用/使用/产出。
    const upd_args = try std.fmt.allocPrint(a,
        \\{{"taskId":"kg-{d}","status":"completed","conclusion":"重构完成,分层清晰",
        \\"acts_on":["src/kg/client.zig"],"uses":["tree-sitter","ref-edge"],"produces":["projection-v1"]}}
    , .{a_id});
    defer a.free(upd_args);
    const upd = try task_tools.executeUpdate(&ctx, upd_args);
    defer a.free(upd);
    try std.testing.expect(std.mem.indexOf(u8, upd, "\"closed\":true") != null);

    // 投影必须落图:acts_on/uses/produces ref 边,每条 state=tentative(写入容忍模糊)。
    const nb = try kg.neighborsJson(a_id, 50);
    defer a.free(nb);
    try std.testing.expect(std.mem.indexOf(u8, nb, "\"rel\":\"acts_on\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nb, "\"rel\":\"uses\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nb, "\"rel\":\"produces\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nb, "\"state\":\"tentative\"") != null);
    // 闭合投影绝不会自己标 confirmed(那是人类确认/纠正专属)。
    try std.testing.expect(std.mem.indexOf(u8, nb, "\"state\":\"confirmed\"") == null);
    // uses 有两个目标 → 至少两条 tentative(证明数组每个元素都建了边)。
    var tentative_count: usize = 0;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, nb, scan, "\"state\":\"tentative\"")) |pos| {
        tentative_count += 1;
        scan = pos + 1;
    }
    try std.testing.expect(tentative_count >= 4); // 1 acts_on + 2 uses + 1 produces

    // 发现面(PM 终审):闭合投影登记任务为"待确认",/kg 状态页/bare `/kg refs` 据此提示人类结晶。
    const pend = kg.pendingRefTasks(a);
    defer if (pend.len > 0) a.free(pend);
    var found = false;
    for (pend) |t| {
        if (t == a_id) found = true;
    }
    try std.testing.expect(found);

    // **第二闭合动词 TaskStop 也投影**(PM 终审:两个等价闭合动词不能分叉)。A 闭合后 B ready,
    // 用 executeStop(kg-B) 带 acts_on → 断言 ref 边同样落图(不是只 TaskUpdate 才结晶)。
    const rows_b = try kg.frontier(r.root_id, 10);
    defer {
        for (rows_b) |*row| row.deinit(a);
        a.free(rows_b);
    }
    var b_id: u64 = 0;
    for (rows_b) |row| {
        if (std.mem.eql(u8, std.mem.trim(u8, row.text, " "), "B")) b_id = row.task_id;
    }
    try std.testing.expect(b_id != 0);
    const stop_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"acts_on\":[\"src/repl/loop.zig\"]}}", .{b_id});
    defer a.free(stop_args);
    const stopped = try task_tools.executeStop(&ctx, stop_args);
    defer a.free(stopped);
    const nb_b = try kg.neighborsJson(b_id, 50);
    defer a.free(nb_b);
    try std.testing.expect(std.mem.indexOf(u8, nb_b, "\"rel\":\"acts_on\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nb_b, "\"state\":\"tentative\"") != null);
}

test "L2 KG: 分类纠正入图 — 覆盖不并存 + error_event/fix 留痕(改动四)" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kgcorrect.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-correct");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    // 建"任务"节点 + 旧分类目标 + tentative acts_on 边(裸 add-edge 不校验端点 kind,可用 concept 代任务)。
    const task = try kg.ensureConcept("task-node");
    const old_c = try kg.ensureConcept("old-target");
    try kg.addRefEdge(task, "acts_on", old_c, false); // tentative

    // 纠正前打 marker:确定性推 error_event/fix 的 id(fresh store 顺序分配)。
    const marker = try kg.ensureConcept("__marker__");
    // correctClassification 内部顺序:ensureConcept(new)=marker+1 → err=marker+2 → fix=marker+3。
    try kg.correctClassification(task, "acts_on", old_c, "new-target");
    const new_c = try kg.ensureConcept("new-target"); // 幂等:返上面刚建的 id
    try std.testing.expectEqual(marker + 1, new_c);

    // ① 覆盖不并存:旧边删除(task 邻居里不再有 dst=old_c),新边到 new_c 且 confirmed。
    const nb = try kg.neighborsJson(task, 50);
    defer a.free(nb);
    var dbuf: [32]u8 = undefined;
    const old_dst = try std.fmt.bufPrint(&dbuf, "\"dst\":{d},", .{old_c});
    try std.testing.expect(std.mem.indexOf(u8, nb, old_dst) == null); // 旧分类没了
    var dbuf2: [32]u8 = undefined;
    const new_dst = try std.fmt.bufPrint(&dbuf2, "\"dst\":{d},", .{new_c});
    try std.testing.expect(std.mem.indexOf(u8, nb, new_dst) != null); // 新分类在
    try std.testing.expect(std.mem.indexOf(u8, nb, "\"state\":\"confirmed\"") != null); // 人类纠正=confirmed
    try std.testing.expect(std.mem.indexOf(u8, nb, "\"state\":\"tentative\"") == null);

    // ② 留痕:error_event(marker+2)记旧分类,derived_from 任务(来源);resolved_by fix(marker+3)。
    const err_id = marker + 2;
    const fix_id = marker + 3;
    const err_text = try kg.fetchNodeText(err_id);
    defer kg.allocator.free(err_text);
    try std.testing.expect(std.mem.indexOf(u8, err_text, "misclassified") != null);
    const fix_text = try kg.fetchNodeText(fix_id);
    defer kg.allocator.free(fix_text);
    try std.testing.expect(std.mem.indexOf(u8, fix_text, "reclassified") != null);
    // error_event 出边:derived_from 任务 + resolved_by fix(审计对成链)。
    const err_nb = try kg.neighborsJson(err_id, 20);
    defer a.free(err_nb);
    try std.testing.expect(std.mem.indexOf(u8, err_nb, "\"rel\":\"derived_from\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_nb, "\"rel\":\"resolved_by\"") != null);

    // ③ **幂等重试**(Linus #1):模拟"上次删旧失败"的半成品(旧 tentative 边又在),再纠正一次。
    // add-edge 对 concept 不去重,若盲加会叠出第二条 confirmed 新边——幂等分支必须探到既有新边只翻位。
    try kg.addRefEdge(task, "acts_on", old_c, false); // 旧边复现(tentative)
    try kg.correctClassification(task, "acts_on", old_c, "new-target"); // 重试
    const nb2 = try kg.neighborsJson(task, 50);
    defer a.free(nb2);
    try std.testing.expect(std.mem.indexOf(u8, nb2, old_dst) == null); // 旧边再次被删
    // 恰一条 confirmed 新边(未因重试叠出重复)——若盲 addRefEdge 会变两条。
    var confirmed_count: usize = 0;
    var s: usize = 0;
    while (std.mem.indexOfPos(u8, nb2, s, "\"state\":\"confirmed\"")) |p| {
        confirmed_count += 1;
        s = p + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), confirmed_count);
}
