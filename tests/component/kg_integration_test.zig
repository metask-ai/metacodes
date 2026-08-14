//! L2 组件测试:KgClient 端到端打真 tinykg 二进制 + 临时 store(设计 v3-final §8 P1)。
//!
//! DoD(声明=接线=测试):每条断言把"KgClient 方法 X → tinykg store 状态 Y"焊死。
//! 用真 tinykg(非 mock)——本地可得,格式版本由 lib/tinykg 源快照 pin(zig build 交叉编译)。
//! 找不到二进制(CI 无 tinykg)→ SkipZigTest(不是失败:KG 是增强非依赖)。

const std = @import("std");
const builtin = @import("builtin");
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
        "prj/cc-t2z/metacodes/zig-out/vendor/tinykg/tinykg",
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

fn overwriteFile(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "w") orelse return error.WriteFailed;
    defer _ = std.c.fclose(file);
    if (bytes.len > 0 and std.c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len) return error.WriteFailed;
}

fn pathExists(path: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_buf.len) return false;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    return @import("platform").fs.exists(@ptrCast(&path_buf));
}

fn unlinkPath(path: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    if (std.c.unlink(@ptrCast(&path_buf)) != 0) return error.UnlinkFailed;
}

fn renamePathForTest(from: []const u8, to: []const u8) !void {
    var from_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var to_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (from.len >= from_buf.len or to.len >= to_buf.len) return error.PathTooLong;
    @memcpy(from_buf[0..from.len], from);
    from_buf[from.len] = 0;
    @memcpy(to_buf[0..to.len], to);
    to_buf[to.len] = 0;
    if (@import("platform").fs.renameReplace(@ptrCast(&from_buf), @ptrCast(&to_buf)) != 0) return error.RenameFailed;
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

fn neighborTargetContains(a: std.mem.Allocator, kg: *KgClient, node_id: u64, needle: []const u8) !bool {
    const payload = try kg.neighborsJson(node_id, 100);
    defer a.free(payload);
    const Edge = struct { dst: u64 };
    const Envelope = struct { edges: []const Edge };
    const parsed = try std.json.parseFromSlice(Envelope, a, payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.edges) |edge| {
        const text = kg.fetchNodeText(edge.dst) catch continue;
        defer kg.allocator.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
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
    const id = try kg.remember(.decision, "用 depends_on 链编码串行步骤,完成时保留任务原文并连接独立 verification", "decision", false);
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

test "L2 KG governance: scoped recall exposes stable node ids and candidate-only guidance" {
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

    const memory_id = try kg.remember(.observation, "src/kg/client.zig 用子进程驱动 tinykg 集成,进程隔离崩溃", "module", false);

    var ab = cc.abort.AbortSignal.init();

    // 正向:相关请求 → 注入且含记忆关键词。
    {
        var conv = cc.conversation.Conversation.init(a);
        defer conv.deinit();
        try conv.appendText(.user, "client.zig 是怎么和 tinykg 集成的?子进程还是嵌入库集成方式?");
        const inj = try cc.kg_scoped_recall.build(a, &kg, &conv, &ab);
        defer if (inj) |s| a.free(s);
        try std.testing.expect(inj != null);
        const expected_id = try std.fmt.allocPrint(a, "node_id={d}", .{memory_id});
        defer a.free(expected_id);
        try std.testing.expect(std.mem.indexOf(u8, inj.?, expected_id) != null);
        try std.testing.expect(std.mem.indexOf(u8, inj.?, "子进程") != null);
        try std.testing.expect(std.mem.indexOf(u8, inj.?, "candidate, not a current fact") != null);
        try std.testing.expect(std.mem.indexOf(u8, inj.?, "KgContext(node_id)") != null);
        try std.testing.expect(std.mem.indexOf(u8, inj.?, "one untyped raw-message lexical BM25 probe") != null);
        try std.testing.expect(std.mem.indexOf(u8, inj.?, "exact canonical alias/symbol") != null);
        try std.testing.expect(std.mem.indexOf(u8, inj.?, "exact/high-precision") != null);
        try std.testing.expect(std.mem.indexOf(u8, inj.?, "强制下一步 / MANDATORY NEXT ACTION") != null);
        try std.testing.expect(std.mem.indexOf(u8, inj.?, "canonical alias/代码符号") != null);
        try std.testing.expect(std.mem.indexOf(u8, inj.?, "2-4 个分离的语义变体") != null);
        try std.testing.expect(std.mem.indexOf(u8, inj.?, "宿主整批执行") != null);
        try std.testing.expect(std.mem.indexOf(u8, inj.?, "按 node_id 合并") != null);
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

const KG_ENUMERATION_SEED_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"seed\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"seed1\",\"name\":\"KgRecall\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"graduation ceremony\\\",\\\"lexical_plan\\\":{\\\"schema_version\\\":\\\"lexical-query-plan-v3\\\",\\\"intent\\\":\\\"fact_lookup\\\",\\\"stage\\\":\\\"seed\\\",\\\"variants\\\":[{\\\"kind\\\":\\\"exact\\\",\\\"text\\\":\\\"graduation ceremony\\\"}]}}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const KG_ENUMERATION_PREMATURE_FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"early\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Unavailable\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const KG_ENUMERATION_BATCH_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"batch\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"batch1\",\"name\":\"KgRecall\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"graduation ceremony\\\",\\\"lexical_plan\\\":{\\\"schema_version\\\":\\\"lexical-query-plan-v3\\\",\\\"intent\\\":\\\"enumeration\\\",\\\"stage\\\":\\\"semantic_expansion\\\",\\\"variants\\\":[{\\\"kind\\\":\\\"synonym\\\",\\\"text\\\":\\\"commencement\\\"},{\\\"kind\\\":\\\"paraphrase\\\",\\\"text\\\":\\\"degree conferral\\\"},{\\\"kind\\\":\\\"broader\\\",\\\"text\\\":\\\"convocation\\\"}]}}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const KG_ENUMERATION_CONTEXT_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"context\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"context1\",\"name\":\"KgContext\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"node_id\\\":1,\\\"limit\\\":10}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const KG_ENUMERATION_FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"final\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"3\"}}\n\n" ++
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

test "L2 KG governance: freshness and contradiction contract enters the actual API request" {
    const a = std.testing.allocator;

    var srv = try harness.MockServer.start(KG_END_TURN_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    const names = [_][]const u8{ "KgRemember", "KgRecall", "KgContext", "TaskList", "TaskGet", "TaskUpdate" };
    const system_prompt = try cc.system_prompt.buildFull(a, "claude-sonnet-4-20250514", null, null, &names, "", true, "/tmp");
    defer a.free(system_prompt);
    // 生产 App 用 session arena 承载 defs + describe_fn 动态描述；测试保持同一生命周期，
    // 避免只 free defs slice 却漏掉各工具 owned description。
    var defs_arena = std.heap.ArenaAllocator.init(a);
    defer defs_arena.deinit();
    var pc = cc.tools.PromptContext{ .enabled_tool_names = &names };
    const defs = try cc.tools.toToolDefinitionsFull(defs_arena.allocator(), null, &pc);
    // Production always supplies the session activation set. Keep it empty here so the request
    // proves the real deferred-tool boundary: ToolSearch is visible, FormalAuditTask is not yet.
    var activated_tools = std.StringHashMap(void).init(a);
    defer activated_tools.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "continue the earlier recovery work");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var wb = cc.writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    const result = cc.agent_loop.run(&conv, client.provider(), defs, &perm, .{
        .max_turns = 1,
        .system_prompt = system_prompt,
        .activated_tools = &activated_tools,
    }, &be, a) catch |e| {
        std.debug.print("agent_loop.run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);

    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "computes no embeddings or vector distance") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "ALIAS BRANCH HAS PRIORITY") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "MUST contain only that exact term plus field names") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "EXACT/HIGH-PRECISION SEED") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "RECORD THE PLAN") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "lexical-query-plan-v3") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "executes every declared member in order") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "run-scoped host ledger owns seen state") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "2-4 separate compact probes") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "at most four semantic probes per run") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "ENUMERATION REQUIRES COVERAGE") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "count/cardinality, exhaustive-list") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "One positive hit proves existence, never completeness") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "successful v3 receipt proves every member ran") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "when the governed run has candidates and KgContext is available") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "rejects premature final answers until the available obligations commit") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "zero-candidate batch does not create an impossible KgContext obligation") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "One best-node KgContext call is sufficient") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "preserve the user's relation or action") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "necessary, not sufficient") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "mechanism, symptom, desired outcome, or nearby implementation term") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "Deduplicate candidates by node_id across every call") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "KgContext") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "For non-enumeration lookups, stop as soon as authoritative evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "Memory is a candidate, not a current fact") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "verified_by or evidences") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "deprecated_by, resolved_by, and contradiction") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "current code, git, tests, or external state") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "FIRST inspect automatic recall") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "Omit on the exact/high-precision seed") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "Persistent task control-plane algorithm") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "A successful claim returns a bounded") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "A title or compact summary alone is insufficient") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "experience_packet") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "preserve tentative/confirmed state") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "never leave finished work claimed/open") != null);

    // KgRecall/Write remain directly callable. FormalAuditTask is genuinely deferred, so
    // ToolSearch is advertised as its activation gate while the full formal schema stays absent.
    const tools_field = cap.jsonField("tools") orelse return error.ToolsFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "\"name\":\"KgRecall\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "\"lexical_plan\":{\"type\":\"object\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "\"schema_version\":{\"type\":\"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "\"enum\":[\"lexical-query-plan-v3\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "\"variants\":{\"type\":\"array\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "\"synonym\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "\"seen_node_ids\":{\"type\":\"array\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "\"variant_index\":{\"type\":\"integer\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "\"name\":\"KgContext\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "authoritative node text") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "bounded TinyKG task_packet") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "select only an open, ready, unclaimed leaf") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "successful response contains the bounded task_packet") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "\"name\":\"Write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "\"name\":\"ToolSearch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "\"name\":\"FormalAuditTask\"") == null);
}

test "L2 KG governance: lexical query plan binds variants and measures information gain" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kg-guidance.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-guidance");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;
    const memory_id = try kg.remember(.decision, "panic 时通过 checkpoint 恢复任务", "decision", false);

    var ledger = @import("cc").kg_lexical_query_plan.Ledger{};
    const ctx = @import("cc").tool_context.ToolContext{ .allocator = a, .kg = &kg, .kg_lexical_ledger = &ledger };
    const first_args =
        \\{"query":"panic crash checkpoint","lexical_plan":{"schema_version":"lexical-query-plan-v2","intent":"task_recovery","stage":"semantic_expansion","variants":[{"kind":"synonym","text":"panic crash checkpoint"},{"kind":"mechanism","text":"checkpoint recovery"}],"variant_index":0}}
    ;
    const first_out = try @import("cc").kg_tools.executeRecall(&ctx, first_args);
    defer a.free(first_out);
    var first_parsed = try std.json.parseFromSlice(std.json.Value, a, first_out, .{});
    defer first_parsed.deinit();
    const first_receipt = first_parsed.value.object.get("lexical_query_plan").?.object;
    try std.testing.expectEqualStrings("lexical-query-plan-v2", first_receipt.get("schema_version").?.string);
    try std.testing.expectEqualStrings("task_recovery", first_receipt.get("intent").?.string);
    try std.testing.expectEqualStrings("semantic_expansion", first_receipt.get("stage").?.string);
    try std.testing.expectEqualStrings("synonym", first_receipt.get("variant_kind").?.string);
    try std.testing.expectEqual(@as(i64, 0), first_receipt.get("variant_index").?.integer);
    try std.testing.expectEqual(@as(i64, 2), first_receipt.get("variant_count").?.integer);
    try std.testing.expectEqual(@as(i64, 0), first_receipt.get("repeated_hit_count").?.integer);
    try std.testing.expect(first_receipt.get("new_hit_count").?.integer >= 1);
    try std.testing.expectEqual(@as(usize, 64), first_receipt.get("plan_sha256").?.string.len);
    var first_found = false;
    for (first_parsed.value.object.get("hits").?.array.items) |hit| {
        if (hit.object.get("node_id").?.integer != @as(i64, @intCast(memory_id))) continue;
        first_found = true;
        try std.testing.expect(!hit.object.get("seen_before").?.bool);
        try std.testing.expect(hit.object.get("text") != null);
        try std.testing.expect(hit.object.get("content_ref") == null);
    }
    try std.testing.expect(first_found);

    const second_args =
        \\{"query":"checkpoint recovery","lexical_plan":{"schema_version":"lexical-query-plan-v2","intent":"task_recovery","stage":"semantic_expansion","variants":[{"kind":"synonym","text":"panic crash checkpoint"},{"kind":"mechanism","text":"checkpoint recovery"}],"variant_index":1}}
    ;
    const second_out = try @import("cc").kg_tools.executeRecall(&ctx, second_args);
    defer a.free(second_out);
    var second_parsed = try std.json.parseFromSlice(std.json.Value, a, second_out, .{});
    defer second_parsed.deinit();
    const second_receipt = second_parsed.value.object.get("lexical_query_plan").?.object;
    try std.testing.expectEqualStrings(first_receipt.get("plan_sha256").?.string, second_receipt.get("plan_sha256").?.string);
    try std.testing.expectEqualStrings("mechanism", second_receipt.get("variant_kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), second_receipt.get("variant_index").?.integer);
    try std.testing.expect(second_receipt.get("seen_state_verified").?.bool);
    try std.testing.expect(second_receipt.get("seen_node_count").?.integer >= 1);
    try std.testing.expectEqualStrings("agent_run_explicit", second_receipt.get("ledger_scope").?.string);
    try std.testing.expect(second_receipt.get("repeated_hit_count").?.integer >= 1);
    var repeated_found = false;
    for (second_parsed.value.object.get("hits").?.array.items) |hit| {
        if (hit.object.get("node_id").?.integer != @as(i64, @intCast(memory_id))) continue;
        repeated_found = true;
        try std.testing.expect(hit.object.get("seen_before").?.bool);
        try std.testing.expect(hit.object.get("text") == null);
        try std.testing.expectEqualStrings("exposed_elsewhere_in_run", hit.object.get("content_ref").?.string);
    }
    try std.testing.expect(repeated_found);

    try std.testing.expect(std.mem.indexOf(u8, first_out, "\"retrieval_mode\":\"lexical_bm25_no_embeddings\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "Semantically judge the merged lexical candidates") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "do not issue its members separately") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "content_ref=exposed_elsewhere_in_run") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_out, "KgContext") != null);

    var detail: ?[]const u8 = null;
    defer if (detail) |value| a.free(value);
    const bad_ctx = @import("cc").tool_context.ToolContext{ .allocator = a, .kg = &kg, .error_detail = &detail };
    try std.testing.expectError(error.InvalidLexicalPlan, @import("cc").kg_tools.executeRecall(
        &bad_ctx,
        "{\"query\":\"mismatch\",\"lexical_plan\":{\"schema_version\":\"lexical-query-plan-v2\",\"intent\":\"fact_lookup\",\"stage\":\"seed\",\"variants\":[{\"kind\":\"exact\",\"text\":\"needle\"}],\"variant_index\":0}}",
    ));
    try std.testing.expect(detail != null);
    try std.testing.expect(std.mem.indexOf(u8, detail.?, "must exactly match") != null);

    // Prove the real tool path rejects obsolete model-owned seen state before
    // any TinyKG subprocess can run, rather than merely unit-testing parse().
    var caller_seen_detail: ?[]const u8 = null;
    defer if (caller_seen_detail) |value| a.free(value);
    const caller_seen_ctx = @import("cc").tool_context.ToolContext{
        .allocator = a,
        .kg = &kg,
        .kg_lexical_ledger = &ledger,
        .error_detail = &caller_seen_detail,
    };
    {
        const saved_bin = kg.bin_path;
        const poisoned_bin = try a.dupe(u8, "/definitely/missing/tinykg-v2-parser-must-reject-first");
        kg.bin_path = poisoned_bin;
        defer {
            kg.bin_path = saved_bin;
            a.free(poisoned_bin);
        }
        try std.testing.expectError(error.InvalidLexicalPlan, @import("cc").kg_tools.executeRecall(
            &caller_seen_ctx,
            "{\"query\":\"needle\",\"lexical_plan\":{\"schema_version\":\"lexical-query-plan-v2\",\"intent\":\"fact_lookup\",\"stage\":\"seed\",\"variants\":[{\"kind\":\"exact\",\"text\":\"needle\"}],\"variant_index\":0,\"seen_node_ids\":[41]}}",
        ));
    }
    try std.testing.expect(caller_seen_detail != null);
    try std.testing.expect(std.mem.indexOf(u8, caller_seen_detail.?, "host-manages seen state") != null);

    var no_ledger_detail: ?[]const u8 = null;
    defer if (no_ledger_detail) |value| a.free(value);
    const no_ledger_ctx = @import("cc").tool_context.ToolContext{ .allocator = a, .kg = &kg, .error_detail = &no_ledger_detail };
    try std.testing.expectError(error.LexicalPlanLedgerUnavailable, @import("cc").kg_tools.executeRecall(&no_ledger_ctx, first_args));
    try std.testing.expect(std.mem.indexOf(u8, no_ledger_detail.?, "fail closed") != null);

    try std.testing.expectError(error.InvalidQuery, @import("cc").kg_tools.executeRecall(&ctx, "{\"query\":\"\"}"));
    try std.testing.expectError(error.InvalidQuery, @import("cc").kg_tools.executeRecall(&ctx, "{\"query\":7}"));
    const long_query = [_]u8{'x'} ** 401;
    const long_args = try std.fmt.allocPrint(a, "{{\"query\":\"{s}\"}}", .{&long_query});
    defer a.free(long_args);
    try std.testing.expectError(error.InvalidQuery, @import("cc").kg_tools.executeRecall(&ctx, long_args));
}

test "L2 KG governance: v3 batch executes every variant and exposes each node body once" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kg-batch-v3.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-batch-v3");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;
    const memory_id = try kg.remember(.decision, "panic crash checkpoint recovery procedure", "decision", false);

    var ledger = @import("cc").kg_lexical_query_plan.Ledger{};
    const ctx = @import("cc").tool_context.ToolContext{ .allocator = a, .kg = &kg, .kg_lexical_ledger = &ledger };
    const args =
        \\{"query":"panic crash checkpoint","type":"decision","lexical_plan":{"schema_version":"lexical-query-plan-v3","intent":"enumeration","stage":"semantic_expansion","variants":[{"kind":"synonym","text":"panic crash checkpoint"},{"kind":"mechanism","text":"checkpoint recovery procedure"}]}}
    ;
    const output = try @import("cc").kg_tools.executeRecall(&ctx, args);
    defer a.free(output);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, output, .{});
    defer parsed.deinit();

    const receipt = parsed.value.object.get("lexical_query_plan").?.object;
    try std.testing.expectEqualStrings("lexical-query-plan-v3", receipt.get("schema_version").?.string);
    try std.testing.expectEqualStrings("host_batch_all", receipt.get("execution").?.string);
    try std.testing.expectEqualStrings("agent_run_batch", receipt.get("ledger_scope").?.string);
    try std.testing.expect(receipt.get("all_variants_executed").?.bool);
    try std.testing.expectEqual(@as(i64, 2), receipt.get("executed_variant_count").?.integer);
    try std.testing.expectEqual(@as(usize, 2), receipt.get("variant_receipts").?.array.items.len);
    try std.testing.expect(receipt.get("probe_repeated_hit_count").?.integer >= 1);

    var body_count: usize = 0;
    for (parsed.value.object.get("hits").?.array.items) |hit| {
        if (hit.object.get("node_id").?.integer != @as(i64, @intCast(memory_id))) continue;
        body_count += 1;
        try std.testing.expect(hit.object.get("text") != null);
        try std.testing.expect(hit.object.get("content_ref") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), body_count);
    for (receipt.get("variant_receipts").?.array.items) |variant_receipt| {
        var found = false;
        for (variant_receipt.object.get("node_ids").?.array.items) |node_id| {
            if (node_id.integer == @as(i64, @intCast(memory_id))) found = true;
        }
        try std.testing.expect(found);
    }
}

test "L2 KG governance: real agent loop requires enumeration batch and recalled-node context" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const project_dir = pbuf[0..dir_len];
    const store = try std.fmt.allocPrint(a, "{s}/kg-enumeration-gate.kg", .{project_dir});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-enumeration-gate");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;
    const first_memory_id = try kg.remember(.observation, "attended sister commencement", "observation", false);
    try std.testing.expectEqual(@as(u64, 1), first_memory_id);
    _ = try kg.remember(.observation, "attended friend degree conferral", "observation", false);
    _ = try kg.remember(.observation, "attended cousin convocation", "observation", false);

    // Deliberately reproduce the paid c010 failure: after a fact_lookup seed,
    // the provider tries to finalize as unavailable. The real run path must
    // reject it, surface a host observation, accept a fixed v3 batch, require
    // real KgContext evidence, and only then allow the final answer. max_turns=2
    // proves the bounded repair loans enough turns for batch + context + final.
    const responses = [_][]const u8{
        KG_ENUMERATION_SEED_SSE,
        KG_ENUMERATION_PREMATURE_FINAL_SSE,
        KG_ENUMERATION_BATCH_SSE,
        KG_ENUMERATION_CONTEXT_SSE,
        KG_ENUMERATION_FINAL_SSE,
    };
    var srv = try harness.MockServer.startCassette(&responses, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var api_client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer api_client.deinit();

    const enabled = [_][]const u8{ "KgRecall", "KgContext" };
    var defs_arena = std.heap.ArenaAllocator.init(a);
    defer defs_arena.deinit();
    var prompt_context = cc.tools.PromptContext{ .enabled_tool_names = &enabled };
    const defs = try cc.tools.toToolDefinitionsFull(defs_arena.allocator(), null, &prompt_context);
    const system_prompt = try cc.system_prompt.buildFull(a, "claude-sonnet-4-20250514", null, null, &enabled, "", true, project_dir);
    defer a.free(system_prompt);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "How many graduation ceremonies did I attend?");
    const permission = cc.permission.createContext(.bypass_permissions, a);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const run_result = try cc.agent_loop.run(&conv, api_client.provider(), defs, &permission, .{
        .max_turns = 2,
        .system_prompt = system_prompt,
        .kg = &kg,
        .project_dir = project_dir,
        .cwd_abs = project_dir,
    }, &backend, a);

    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, run_result.stop_reason);
    try std.testing.expectEqual(@as(u32, 5), run_result.turns);
    try std.testing.expectEqual(@as(u32, 3), run_result.tool_calls);
    try std.testing.expectEqual(@as(usize, 5), srv.requestCount());

    const after_seed = srv.requestAt(1) orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, after_seed.body(), "lexical-coverage-obligation") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_seed.body(), "no lexical-query-plan-v3 semantic_expansion batch has committed") != null);

    const repair_request = srv.requestAt(2) orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, repair_request.body(), "lexical-coverage-rejected-final") != null);
    try std.testing.expect(std.mem.indexOf(u8, repair_request.body(), "Do not answer yet") != null);

    const context_request = srv.requestAt(3) orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, context_request.body(), "\\\"all_variants_executed\\\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, context_request.body(), "\\\"executed_variant_count\\\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, context_request.body(), "\\\"query_anchor_rewritten\\\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, context_request.body(), "query_anchor_input_sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, context_request.body(), "query_anchor_effective_sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, context_request.body(), "lexical-evidence-obligation") != null);

    const final_request = srv.requestAt(4) orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, final_request.body(), "\"name\":\"KgContext\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, final_request.body(), "knowledge_governance") != null);

    const final_message = conv.messages.items[conv.messages.items.len - 1];
    try std.testing.expectEqual(cc.message.Role.assistant, final_message.role);
    try std.testing.expectEqualStrings("3", final_message.blocks[0].text);
}

test "L2 KG governance: KgContext emits evidence, freshness, and supersession signals" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kg-context.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-context");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    const old_id = try kg.remember(.decision, "authoritative-policy=quartz-16; superseded generation", "decision", false);
    const root_id = try kg.remember(.decision, "authoritative-policy=quartz-17; verify connected evidence", "decision", false);
    const evidence_id = try kg.remember(.observation, "evidence: approved after concurrency replay", "observation", false);
    try kg.addEdge(root_id, "derived_from", evidence_id);
    try kg.addEdge(root_id, "verified_by", evidence_id);
    try kg.addEdge(old_id, "deprecated_by", root_id);

    const ctx = @import("cc").tool_context.ToolContext{ .allocator = a, .kg = &kg };
    const args = try std.fmt.allocPrint(a, "{{\"node_id\":{d},\"limit\":5,\"text_offset\":0,\"text_limit\":16}}", .{root_id});
    defer a.free(args);
    const out = try @import("cc").kg_tools.executeContext(&ctx, args);
    defer a.free(out);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqual(@as(i64, @intCast(root_id)), obj.get("node_id").?.integer);
    try std.testing.expectEqualStrings("authoritative-po", obj.get("text").?.string);
    try std.testing.expectEqual(@as(i64, 0), obj.get("text_offset").?.integer);
    try std.testing.expectEqual(@as(i64, 16), obj.get("next_text_offset").?.integer);
    try std.testing.expect(obj.get("text_truncated").?.bool);
    const graph = obj.get("graph").?.object;
    try std.testing.expectEqualStrings("tinykg-agent-retrieval-v1", graph.get("schema_version").?.string);
    try std.testing.expectEqualStrings("neighbors", graph.get("mode").?.string);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"rel\":\"derived_from\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "one best-node KgContext call is sufficient") != null);
    const governance = obj.get("knowledge_governance").?.object;
    try std.testing.expectEqualStrings("metacodes-knowledge-governance-v1", governance.get("schema_version").?.string);
    try std.testing.expect(governance.get("current_generation").?.bool);
    try std.testing.expect(governance.get("deprecated_by").? == .null);
    try std.testing.expectEqual(@as(i64, 1), governance.get("verification_edge_count").?.integer);
    try std.testing.expectEqualStrings("evidence_connected_candidate", governance.get("trust_state").?.string);
    try std.testing.expectEqualStrings("unknown_requires_current_state_check", governance.get("freshness_state").?.string);
    try std.testing.expectEqualStrings("candidate_only", governance.get("usage").?.string);

    const old_args = try std.fmt.allocPrint(a, "{{\"node_id\":{d},\"limit\":20}}", .{old_id});
    defer a.free(old_args);
    const old_out = try @import("cc").kg_tools.executeContext(&ctx, old_args);
    defer a.free(old_out);
    var old_parsed = try std.json.parseFromSlice(std.json.Value, a, old_out, .{});
    defer old_parsed.deinit();
    const old_governance = old_parsed.value.object.get("knowledge_governance").?.object;
    try std.testing.expect(!old_governance.get("current_generation").?.bool);
    try std.testing.expectEqual(@as(i64, @intCast(root_id)), old_governance.get("deprecated_by").?.integer);
    try std.testing.expectEqualStrings("superseded", old_governance.get("trust_state").?.string);
    try std.testing.expect(std.mem.indexOf(u8, old_out, "do not use memory as a current fact") != null);

    var detail: ?[]const u8 = null;
    defer if (detail) |d| a.free(d);
    const bad_ctx = @import("cc").tool_context.ToolContext{ .allocator = a, .kg = &kg, .error_detail = &detail };
    try std.testing.expectError(error.InvalidLimit, @import("cc").kg_tools.executeContext(&bad_ctx, "{\"node_id\":1,\"limit\":21}"));
    try std.testing.expect(detail != null);
    try std.testing.expect(std.mem.indexOf(u8, detail.?, "1..20") != null);
    a.free(detail.?);
    detail = null;
    try std.testing.expectError(error.InvalidLimit, @import("cc").kg_tools.executeContext(&bad_ctx, "{\"node_id\":1,\"limit\":0}"));
    try std.testing.expect(detail != null);
    try std.testing.expect(std.mem.indexOf(u8, detail.?, "1..20") != null);
    a.free(detail.?);
    detail = null;
    try std.testing.expectError(error.InvalidLimit, @import("cc").kg_tools.executeContext(&bad_ctx, "{\"node_id\":1,\"text_limit\":1}"));
    try std.testing.expect(detail != null);
    try std.testing.expect(std.mem.indexOf(u8, detail.?, "4..12000") != null);
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

test "L2 KG: schema v2 明确 degraded 并给 copy-on-write task-status-v1 迁移指令" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/legacy-schema.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    // 先用当前 binary 建合法 store，再只把 manifest schema 降为 2，模拟迁移前 canonical store。
    {
        var current = try makeClient(a, bin, store, "proj-schema-gate");
        defer current.deinit();
        current.ensureReady();
        if (!current.ready) return error.SkipZigTest;
    }
    const manifest_path = try std.fmt.allocPrint(a, "{s}/.tinykg/store-manifest.json", .{store});
    defer a.free(manifest_path);
    try overwriteFile(a, manifest_path,
        \\{
        \\  "store_manifest_version": 1,
        \\  "storage_format_version": 2,
        \\  "created_by": "tinykg",
        \\  "schema": {"schema_version": 2, "kernel_version": 1, "enabled_profiles": []},
        \\  "migration": {"name": "legacy-test", "source": "", "recorded_ns": 1}
        \\}
    );

    var legacy = try makeClient(a, bin, store, "proj-schema-gate");
    defer legacy.deinit();
    legacy.ensureReady();
    try std.testing.expect(!legacy.ready);
    const reason = legacy.degradedMessage();
    try std.testing.expect(std.mem.indexOf(u8, reason, "期望 3 实际 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, reason, "migrate-store-v2") != null);
    try std.testing.expect(std.mem.indexOf(u8, reason, "--task-status-v1 --verify") != null);
}

test "L2 KG migrate: legacy canonical 自动迁移并保留 rollback backup" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/auto-legacy.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    // 用当前 binary 创建结构正确的店，再移除 manifest，机械模拟 legacy store。
    {
        var current = try makeClient(a, bin, store, "proj-auto-migrate");
        defer current.deinit();
        current.ensureReady();
        if (!current.ready) return error.SkipZigTest;
    }
    const manifest = try std.fmt.allocPrint(a, "{s}/.tinykg/store-manifest.json", .{store});
    defer a.free(manifest);
    try unlinkPath(manifest);

    var migrated = try makeClient(a, bin, store, "proj-auto-migrate");
    defer migrated.deinit();
    migrated.ensureReady();
    try std.testing.expect(migrated.ready);
    const backup = try std.fmt.allocPrint(a, "{s}.legacy.bak", .{store});
    defer a.free(backup);
    try std.testing.expect(pathExists(store));
    try std.testing.expect(pathExists(backup));
}

test "L2 KG migrate: canonical rename 后崩溃窗口由 backup 恢复且不会 init 空店" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/recover-legacy.kg", .{pbuf[0..dir_len]});
    defer a.free(store);
    {
        var current = try makeClient(a, bin, store, "proj-auto-recover");
        defer current.deinit();
        current.ensureReady();
        if (!current.ready) return error.SkipZigTest;
    }
    const manifest = try std.fmt.allocPrint(a, "{s}/.tinykg/store-manifest.json", .{store});
    defer a.free(manifest);
    try unlinkPath(manifest);
    const backup = try std.fmt.allocPrint(a, "{s}.legacy.bak", .{store});
    defer a.free(backup);
    // 精确模拟 host 已把 canonical 改名为 backup、尚未调用 provider/tinykg 的崩溃窗。
    try renamePathForTest(store, backup);
    try std.testing.expect(!pathExists(store));

    var recovered = try makeClient(a, bin, store, "proj-auto-recover");
    defer recovered.deinit();
    recovered.ensureReady();
    try std.testing.expect(recovered.ready);
    try std.testing.expect(pathExists(store));
    try std.testing.expect(pathExists(backup));
}

test "L2 KG migrate: TinyKG 发布失败时恢复 legacy 且 session fail closed" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/failed-legacy.kg", .{pbuf[0..dir_len]});
    defer a.free(store);
    {
        var current = try makeClient(a, bin, store, "proj-auto-fail");
        defer current.deinit();
        current.ensureReady();
        if (!current.ready) return error.SkipZigTest;
    }
    const manifest = try std.fmt.allocPrint(a, "{s}/.tinykg/store-manifest.json", .{store});
    defer a.free(manifest);
    try unlinkPath(manifest);

    // TinyKG 只会回收带 request-matched marker 的 staging；外来目录必须拒绝。
    const foreign_staging = try std.fmt.allocPrint(a, "{s}.tinykg-migrate-store-v2.tmp", .{store});
    defer a.free(foreign_staging);
    const staging_z = try a.dupeZ(u8, foreign_staging);
    defer a.free(staging_z);
    if (std.c.mkdir(staging_z.ptr, 0o700) != 0) return error.MkdirFailed;

    var failed = try makeClient(a, bin, store, "proj-auto-fail");
    defer failed.deinit();
    failed.ensureReady();
    try std.testing.expect(!failed.ready);
    try std.testing.expect(pathExists(store)); // rollback 恢复原店，不留下 canonical 缺口
    const backup = try std.fmt.allocPrint(a, "{s}.legacy.bak", .{store});
    defer a.free(backup);
    try std.testing.expect(!pathExists(backup));
    try std.testing.expect(std.mem.indexOf(u8, failed.degradedMessage(), "自动 migrate 失败") != null);
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

    // 长程控制面不允许闭合证据覆盖任务身份:原步骤文本仍在同一 id，证据通过
    // verified_by 独立挂接；task-packet/get/neighbors 因此能同时恢复“做什么”、
    // “完成状态”和“凭什么完成”。
    try std.testing.expectEqual(cc.kg_client.TaskStatus.completed, try kg.taskStatus(step1_id));
    const packet = try kg.taskPacket(step1_id, 20);
    defer kg.allocator.free(packet);
    try std.testing.expect(std.mem.startsWith(u8, packet, "task_packet\t"));
    try std.testing.expect(std.mem.indexOf(u8, packet, "\tstatus=completed\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet, "\ttask\t读现有代码") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet, "verified_by_out") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet, "completion evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet, "代码已读") != null);
    const closed_text = try kg.fetchNodeText(step1_id);
    defer kg.allocator.free(closed_text);
    try std.testing.expectEqualStrings("读现有代码", std.mem.trim(u8, closed_text, " \t\r\n"));
    const closed_graph = try kg.neighborsJson(step1_id, 20);
    defer kg.allocator.free(closed_graph);
    var closed_json = try std.json.parseFromSlice(std.json.Value, a, closed_graph, .{});
    defer closed_json.deinit();
    const closed_root = closed_json.value.object.get("root") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("task", closed_root.object.get("kind").?.string);
    var evidence_id: u64 = 0;
    for (closed_json.value.object.get("edges").?.array.items) |edge| {
        const obj = edge.object;
        if (std.mem.eql(u8, obj.get("rel").?.string, "verified_by")) {
            evidence_id = @intCast(obj.get("dst").?.integer);
        }
    }
    try std.testing.expect(evidence_id != 0);
    const evidence_text = try kg.fetchNodeText(evidence_id);
    defer kg.allocator.free(evidence_text);
    try std.testing.expect(std.mem.indexOf(u8, evidence_text, "步骤1完成:代码已读") != null);

    // 幂等完成:重复 close 不新建 verification/边，也不生成 deprecated_by 版本链。
    try kg.closeTask(step1_id, "重复调用应 no-op");
    const closed_graph_again = try kg.neighborsJson(step1_id, 20);
    defer kg.allocator.free(closed_graph_again);
    var verified_by_count: usize = 0;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, closed_graph_again, scan, "\"rel\":\"verified_by\"")) |pos| {
        verified_by_count += 1;
        scan = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), verified_by_count);

    // fresh restart 不依赖进程内缓存：同一稳定 task id 仍能恢复 completed packet/原文/证据。
    {
        var fresh = try makeClient(a, bin, store, "proj-plan");
        defer fresh.deinit();
        fresh.ensureReady();
        try std.testing.expect(fresh.ready);
        try std.testing.expectEqual(cc.kg_client.TaskStatus.completed, try fresh.taskStatus(step1_id));
        const fresh_packet = try fresh.taskPacket(step1_id, 20);
        defer fresh.allocator.free(fresh_packet);
        try std.testing.expect(std.mem.indexOf(u8, fresh_packet, "读现有代码") != null);
        try std.testing.expect(std.mem.indexOf(u8, fresh_packet, "verified_by_out") != null);
        try std.testing.expect(std.mem.indexOf(u8, fresh_packet, "completion evidence") != null);
        try std.testing.expect(std.mem.indexOf(u8, fresh_packet, "代码已读") != null);
    }

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

    // A 已闭合退出 frontier；稳定 task 本身仍可由 TaskGet/task-packet 按原 id 恢复。
    const list2 = try task_tools.executeList(&ctx, "{}");
    defer a.free(list2);
    try std.testing.expect(std.mem.indexOf(u8, list2, "\"subject\":\"A\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, list2, "\"subject\":\"B\"") != null);
    const get_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\"}}", .{a_id});
    defer a.free(get_args);
    const closed_task = try task_tools.executeGet(&ctx, get_args);
    defer a.free(closed_task);
    try std.testing.expect(std.mem.indexOf(u8, closed_task, "\"subject\":\"A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, closed_task, "\"kg_status\":\"completed\"") != null);
}

test "L2 KG: failed 是显式终态 — frontier/TaskList 保留失败上下文且不解锁父任务" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const proj_dir = pbuf[0..dir_len];
    const store = try std.fmt.allocPrint(a, "{s}/kgfailed.kg", .{proj_dir});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-failed");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    const root = try kg.createTask("失败传播计划", "plan_root");
    const child = try kg.createChildTask(root, "不可恢复的步骤", "plan_step");
    const cancelled = try kg.createChildTask(root, "主动取消的步骤", "plan_step");
    try cc.kg_inject.writeIdPointer(a, proj_dir, "kg_root", root);

    const TaskStore = cc.core_task_store.TaskStore;
    var tasks = TaskStore.init(a);
    defer tasks.deinit();
    const ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .tasks = &tasks,
        .kg = &kg,
        .kg_projects_dir = proj_dir,
    };
    const fail_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"failed\",\"conclusion\":\"验证发现产物不可用\"}}", .{child});
    defer a.free(fail_args);
    const fail_response = try cc.task_tools.executeUpdate(&ctx, fail_args);
    defer a.free(fail_response);
    try std.testing.expect(std.mem.indexOf(u8, fail_response, "\"kg_status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fail_response, "\"preserved\":true") != null);

    // 旧 deleted 调用在 KG 路由上只作 failed 兼容别名，不能物理删除稳定 id。
    const deleted_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"deleted\",\"conclusion\":\"用户取消\"}}", .{cancelled});
    defer a.free(deleted_args);
    const deleted_response = try cc.task_tools.executeUpdate(&ctx, deleted_args);
    defer a.free(deleted_response);
    try std.testing.expect(std.mem.indexOf(u8, deleted_response, "\"kg_status\":\"failed\"") != null);
    try std.testing.expectEqual(cc.kg_client.TaskStatus.failed, try kg.taskStatus(cancelled));
    const cancelled_packet = try kg.taskPacket(cancelled, 20);
    defer kg.allocator.free(cancelled_packet);
    try std.testing.expect(std.mem.indexOf(u8, cancelled_packet, "主动取消的步骤") != null);

    try std.testing.expectEqual(cc.kg_client.TaskStatus.failed, try kg.taskStatus(child));
    const packet = try kg.taskPacket(child, 20);
    defer kg.allocator.free(packet);
    try std.testing.expect(std.mem.indexOf(u8, packet, "status=failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet, "不可恢复的步骤") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet, "failure evidence") != null);

    const rows = try kg.frontier(root, 20);
    defer {
        for (rows) |*row| row.deinit(kg.allocator);
        kg.allocator.free(rows);
    }
    var found_failed = false;
    for (rows) |row| {
        if (row.task_id == child and row.role == .failed and row.status == .failed and row.readiness == .blocked) {
            found_failed = true;
        }
    }
    try std.testing.expect(found_failed);

    // failed child 不算 completed：父 branch 仍不可 claim，且错误必须归 data 而非瞬时重试。
    try std.testing.expectError(cc.kg_client.KgError.Data, kg.claimTask(root, "agent-failed-test"));
    try std.testing.expect(std.mem.indexOf(u8, kg.detail(), "TaskHasOpenChildren") != null);

    const list = try cc.task_tools.executeList(&ctx, "{}");
    defer a.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"subject\":\"不可恢复的步骤\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"status\":\"blocked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"kg_status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "parallel_hint") == null);
}

test "L2 KG: claim returns bounded packet and fresh process resumes with one lease identity" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const proj_dir = pbuf[0..dir_len];
    const store = try std.fmt.allocPrint(a, "{s}/kg-resume-packet.kg", .{proj_dir});
    defer a.free(store);

    var first = try makeClient(a, bin, store, "proj-resume-packet");
    defer first.deinit();
    first.ensureReady();
    if (!first.ready) return error.SkipZigTest;

    const root = try first.createTask("跨进程目标", "plan_root");
    const child = try first.createChildTask(root, "实现 packet 恢复\n必须读取父目标、依赖和证据", "plan_step");
    try cc.kg_inject.writeIdPointer(a, proj_dir, "kg_root", root);

    var first_tasks = cc.core_task_store.TaskStore.init(a);
    defer first_tasks.deinit();
    const holder = "worker@packet-team";
    const first_ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .tasks = &first_tasks,
        .kg = &first,
        .kg_projects_dir = proj_dir,
        .kg_agent_ident = holder,
    };
    const claim_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"in_progress\"}}", .{child});
    defer a.free(claim_args);
    const claimed = try cc.task_tools.executeUpdate(&first_ctx, claim_args);
    defer a.free(claimed);
    var claimed_json = try std.json.parseFromSlice(std.json.Value, a, claimed, .{});
    defer claimed_json.deinit();
    const claimed_obj = claimed_json.value.object;
    try std.testing.expect(claimed_obj.get("claimed").?.bool);
    try std.testing.expectEqualStrings(holder, claimed_obj.get("claimed_by").?.string);
    const claim_packet = claimed_obj.get("task_packet") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("task-packet", claim_packet.object.get("mode").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(child)), claim_packet.object.get("query").?.object.get("task_id").?.integer);
    try std.testing.expectEqualStrings("claimed", claim_packet.object.get("query").?.object.get("status").?.string);
    try std.testing.expect(!claim_packet.object.get("summary").?.object.get("truncated").?.bool);
    // claim 已把 kg-* 任务镜像进本地 TaskStore；TaskGet 仍必须回图真源，不能被镜像旁路。
    const same_get_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\"}}", .{child});
    defer a.free(same_get_args);
    const same_fetched = try cc.task_tools.executeGet(&first_ctx, same_get_args);
    defer a.free(same_fetched);
    try std.testing.expect(std.mem.indexOf(u8, same_fetched, "\"task_packet\":{") != null);
    const live_list = try cc.task_tools.executeList(&first_ctx, "{}");
    defer a.free(live_list);
    try std.testing.expect(std.mem.indexOf(u8, live_list, "\"kg_status\":\"claimed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, live_list, holder) != null);

    // Simulate a fresh process/client with no Conversation. The same resumed
    // host identity can recover the exact claimed task from TaskGet and the
    // startup packet; a different session must not receive that private lease packet.
    var fresh = try makeClient(a, bin, store, "proj-resume-packet");
    defer fresh.deinit();
    fresh.ensureReady();
    try std.testing.expect(fresh.ready);
    var fresh_tasks = cc.core_task_store.TaskStore.init(a);
    defer fresh_tasks.deinit();
    const fresh_ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .tasks = &fresh_tasks,
        .kg = &fresh,
        .kg_projects_dir = proj_dir,
        .kg_agent_ident = holder,
    };
    const get_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\"}}", .{child});
    defer a.free(get_args);
    const fetched = try cc.task_tools.executeGet(&fresh_ctx, get_args);
    defer a.free(fetched);
    var fetched_json = try std.json.parseFromSlice(std.json.Value, a, fetched, .{});
    defer fetched_json.deinit();
    const fetched_packet = fetched_json.value.object.get("task_packet") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("claimed", fetched_packet.object.get("query").?.object.get("status").?.string);
    var saw_parent = false;
    for (fetched_packet.object.get("edges").?.array.items) |edge| {
        if (std.mem.eql(u8, edge.object.get("view_role").?.string, "parent_in")) saw_parent = true;
    }
    try std.testing.expect(saw_parent);

    const resumed_summary = cc.kg_inject.buildSummaryForAgent(a, &fresh, proj_dir, holder) orelse return error.TestUnexpectedResult;
    defer a.free(resumed_summary);
    try std.testing.expect(std.mem.indexOf(u8, resumed_summary, "Active task recovery packet") != null);
    try std.testing.expect(std.mem.indexOf(u8, resumed_summary, "\"task_id\":") != null);
    const other_summary = cc.kg_inject.buildSummaryForAgent(a, &fresh, proj_dir, "other-session") orelse return error.TestUnexpectedResult;
    defer a.free(other_summary);
    try std.testing.expect(std.mem.indexOf(u8, other_summary, "Active task recovery packet") == null);

    const wrong_ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .tasks = &fresh_tasks,
        .kg = &fresh,
        .kg_projects_dir = proj_dir,
        .kg_agent_ident = "other-session",
    };
    const release_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"pending\"}}", .{child});
    defer a.free(release_args);
    try std.testing.expectError(error.KgReleaseFailed, cc.task_tools.executeUpdate(&wrong_ctx, release_args));
    try std.testing.expectEqual(cc.kg_client.TaskStatus.claimed, try fresh.taskStatus(child));

    const wrong_close_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"completed\",\"conclusion\":\"wrong holder evidence must not commit\",\"acts_on\":[\"UNAUTHORIZED_PROJECTION_SENTINEL\"]}}", .{child});
    defer a.free(wrong_close_args);
    try std.testing.expectError(error.KgCloseFailed, cc.task_tools.executeUpdate(&wrong_ctx, wrong_close_args));
    try std.testing.expectEqual(cc.kg_client.TaskStatus.claimed, try fresh.taskStatus(child));
    const wrong_neighbors = try fresh.neighborsText(child, 20);
    defer fresh.allocator.free(wrong_neighbors);
    try std.testing.expect(std.mem.indexOf(u8, wrong_neighbors, "UNAUTHORIZED_PROJECTION_SENTINEL") == null);

    const close_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"completed\",\"conclusion\":\"fresh process verified packet recovery\"}}", .{child});
    defer a.free(close_args);
    const closed = try cc.task_tools.executeUpdate(&fresh_ctx, close_args);
    defer a.free(closed);
    try std.testing.expect(std.mem.indexOf(u8, closed, "\"closed\":true") != null);
    try std.testing.expectEqual(cc.kg_client.TaskStatus.completed, try fresh.taskStatus(child));
    const terminal_packet = try fresh.taskPacket(child, 20);
    defer fresh.allocator.free(terminal_packet);
    try std.testing.expect(std.mem.indexOf(u8, terminal_packet, "fresh process verified packet recovery") != null);
    try std.testing.expect(std.mem.indexOf(u8, terminal_packet, "wrong holder evidence must not commit") == null);
}

test "L2 KG: claim packet 失败会释放刚取得的租约" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    if (std.mem.indexOfScalar(u8, bin, '"') != null) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const proj_dir = pbuf[0..dir_len];
    const store = try std.fmt.allocPrint(a, "{s}/kg-claim-packet-fail.kg", .{proj_dir});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-claim-packet-fail");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;
    const root = try kg.createTask("packet rollback root", "plan_root");
    const child = try kg.createChildTask(root, "packet rollback child", "plan_step");

    // Delegate every command to real tinykg except task-packet, which fails
    // after task-claim has already succeeded inside the same tool call.
    const wrapper = try std.fmt.allocPrint(a, "{s}/tinykg-packet-fail", .{proj_dir});
    defer a.free(wrapper);
    const script = try std.fmt.allocPrint(a, "#!/bin/sh\nif [ \"$1\" = \"task-packet\" ]; then exit 23; fi\nexec \"{s}\" \"$@\"\n", .{bin});
    defer a.free(script);
    try overwriteFile(a, wrapper, script);
    const wrapper_z = try a.dupeZ(u8, wrapper);
    defer a.free(wrapper_z);
    if (std.c.chmod(wrapper_z.ptr, 0o700) != 0) return error.SkipZigTest;
    a.free(kg.bin_path.?);
    kg.bin_path = try a.dupe(u8, wrapper);

    var tasks = cc.core_task_store.TaskStore.init(a);
    defer tasks.deinit();
    var detail: ?[]const u8 = null;
    defer if (detail) |d| a.free(d);
    const holder = "packet-fail-worker";
    const ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .tasks = &tasks,
        .kg = &kg,
        .kg_projects_dir = proj_dir,
        .kg_agent_ident = holder,
        .error_detail = &detail,
    };
    const claim_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"in_progress\"}}", .{child});
    defer a.free(claim_args);
    try std.testing.expectError(error.KgTaskPacketUnavailable, cc.task_tools.executeUpdate(&ctx, claim_args));
    a.free(kg.bin_path.?);
    kg.bin_path = try a.dupe(u8, bin);
    try std.testing.expectEqual(cc.kg_client.TaskStatus.open, try kg.taskStatus(child));
    try std.testing.expect(detail != null and std.mem.indexOf(u8, detail.?, "已自动释放") != null);
}

test "L2 KG: legacy kg_inbox lease survives fresh-process startup recovery" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const proj_dir = pbuf[0..dir_len];
    const store = try std.fmt.allocPrint(a, "{s}/kg-legacy-inbox-resume.kg", .{proj_dir});
    defer a.free(store);

    var first = try makeClient(a, bin, store, "proj-legacy-inbox-resume");
    defer first.deinit();
    first.ensureReady();
    if (!first.ready) return error.SkipZigTest;

    const inbox = try first.createTask("legacy inbox", "todo_root");
    const child = try first.createChildTask(inbox, "恢复旧待办租约", "todo");
    try cc.kg_inject.writeIdPointer(a, proj_dir, "kg_inbox", inbox);
    const holder = "legacy-worker@resume";
    try first.claimTask(child, holder);

    // 新 client 模拟重启；无 kg_task_anchor，仍须从 legacy inbox 找回租约
    // packet。同时模拟历史上 kg_root/kg_inbox 重叠的店，输出必须按稳定 task id 去重。
    try cc.kg_inject.writeIdPointer(a, proj_dir, "kg_root", inbox);
    var fresh = try makeClient(a, bin, store, "proj-legacy-inbox-resume");
    defer fresh.deinit();
    fresh.ensureReady();
    try std.testing.expect(fresh.ready);
    const summary = cc.kg_inject.buildSummaryForAgent(a, &fresh, proj_dir, holder) orelse return error.TestUnexpectedResult;
    defer a.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "Active task recovery packet") != null);
    var task_id_buf: [48]u8 = undefined;
    const task_id_needle = try std.fmt.bufPrint(&task_id_buf, "\"task_id\":{d}", .{child});
    try std.testing.expect(std.mem.indexOf(u8, summary, task_id_needle) != null);
    var claimed_buf: [96]u8 = undefined;
    const claimed_needle = try std.fmt.bufPrint(&claimed_buf, "CLAIMED [{d}]", .{child});
    const claimed_pos = std.mem.indexOf(u8, summary, claimed_needle) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOfPos(u8, summary, claimed_pos + claimed_needle.len, claimed_needle) == null);

    var tasks = cc.core_task_store.TaskStore.init(a);
    defer tasks.deinit();
    const ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .tasks = &tasks,
        .kg = &fresh,
        .kg_projects_dir = proj_dir,
        .kg_agent_ident = holder,
    };
    const list = try cc.task_tools.executeList(&ctx, "{}");
    defer a.free(list);
    var id_buf: [64]u8 = undefined;
    const id_needle = try std.fmt.bufPrint(&id_buf, "\"id\":\"kg-{d}\"", .{child});
    const id_pos = std.mem.indexOf(u8, list, id_needle) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOfPos(u8, list, id_pos + id_needle.len, id_needle) == null);
}

test "L2 KG: stale task anchor falls back to legacy root in the same startup" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const proj_dir = pbuf[0..dir_len];
    const store = try std.fmt.allocPrint(a, "{s}/kg-stale-anchor.kg", .{proj_dir});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-stale-anchor");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    const legacy_root = try kg.createTask("legacy root", "plan_root");
    const child = try kg.createChildTask(legacy_root, "same-startup fallback child", "plan_step");
    _ = child;
    try cc.kg_inject.writeIdPointer(a, proj_dir, "kg_root", legacy_root);
    try cc.kg_inject.writeIdPointer(a, proj_dir, "kg_task_anchor", 999_999_999);

    const summary = cc.kg_inject.buildSummaryForAgent(a, &kg, proj_dir, "worker") orelse return error.TestUnexpectedResult;
    defer a.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "same-startup fallback child") != null);
    try std.testing.expect(cc.kg_inject.readIdPointer(a, proj_dir, "kg_task_anchor") == null);

    // Recreate the stale pointer to exercise TaskList's independent live path.
    try cc.kg_inject.writeIdPointer(a, proj_dir, "kg_task_anchor", 999_999_999);
    var tasks = cc.core_task_store.TaskStore.init(a);
    defer tasks.deinit();
    const ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .tasks = &tasks,
        .kg = &kg,
        .kg_projects_dir = proj_dir,
    };
    const list = try cc.task_tools.executeList(&ctx, "{}");
    defer a.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "same-startup fallback child") != null);
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
        try std.testing.expectEqual(cc.kg_client.TaskStatus.claimed, try kg.taskStatus(sub_a));

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
    try kg.closeTaskAs(sub_a, "甲完成", ctx.agent_ident.asSlice());
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
    // inbox root 是容器不是任务,不上看板；它可作为 todo 的 path 面包屑出现。
    try std.testing.expect(std.mem.indexOf(u8, list, "\"subject\":\"会话待办") == null);
}

test "L2 KG: TaskList live frontier 瞬时失败时回退本地 kg 镜像" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const proj_dir = pbuf[0..dir_len];
    const store_path = try std.fmt.allocPrint(a, "{s}/kg-list-fallback.kg", .{proj_dir});
    defer a.free(store_path);

    var kg = try makeClient(a, bin, store_path, "proj-list-fallback");
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

    // write-through 同时建立 live pointer 和本地 UI 镜像。
    const created = try task_tools.executeCreate(&ctx, "{\"subject\":\"离线仍可见\",\"description\":\"cached projection\"}");
    a.free(created);
    try std.testing.expect(tstore.tasks.items.len == 1);

    // 保持 ready/pointer 不变，只让后续 frontier spawn 失败，模拟瞬时执行故障。
    a.free(kg.bin_path.?);
    kg.bin_path = try a.dupe(u8, "/definitely/missing/tinykg");

    const list = try task_tools.executeList(&ctx, "{}");
    defer a.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "离线仍可见") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"id\":\"kg-") != null);
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

test "L2 KG ontology feedback: successful host execution projects without model self-report" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const project_dir = pbuf[0..dir_len];
    const store_path = try std.fmt.allocPrint(a, "{s}/kg-execution-feedback.kg", .{project_dir});
    defer a.free(store_path);

    var kg = try makeClient(a, bin, store_path, "proj-execution-feedback");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    const root = try kg.createTask("execution-grounded ontology root", "plan_root");
    const first = try kg.createChildTask(root, "first observed task", "plan_step");
    const second = try kg.createChildTask(root, "second isolated task", "plan_step");

    const first_path = try std.fmt.allocPrint(a, "{s}/first.zig", .{project_dir});
    defer a.free(first_path);
    const second_path = try std.fmt.allocPrint(a, "{s}/second.zig", .{project_dir});
    defer a.free(second_path);
    try overwriteFile(a, first_path, "const value = 1;\n");
    try overwriteFile(a, second_path, "const sibling = 2;\n");

    var tasks = cc.core_task_store.TaskStore.init(a);
    defer tasks.deinit();
    const ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .tasks = &tasks,
        .kg = &kg,
        .project_dir = project_dir,
        .cwd_abs = project_dir,
    };
    const rid = cc.util_log.RequestId{ .bytes = [_]u8{'k'} ** 12 };

    // Claim is the provenance anchor. The host sensor refuses to guess if the
    // TaskStore has zero or multiple in-progress kg-* mirrors.
    const first_claim_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"in_progress\"}}", .{first});
    defer a.free(first_claim_args);
    const first_claim = try cc.task_tools.executeUpdate(&ctx, first_claim_args);
    defer a.free(first_claim);

    const read_first = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}\"}}", .{first_path});
    defer a.free(read_first);
    const edit_first = try std.fmt.allocPrint(
        a,
        "{{\"file_path\":\"{s}\",\"old_string\":\"const value = 1;\",\"new_string\":\"const value = 3; // PRIVATE_BODY_SENTINEL\"}}",
        .{first_path},
    );
    defer a.free(edit_first);
    var first_slots = [_]cc.tool_exec.Slot{
        .{ .decision = .run, .name = "Read", .id = "read-first", .input = read_first },
        .{ .decision = .run, .name = "Edit", .id = "edit-first", .input = edit_first },
    };
    defer for (&first_slots) |*slot| slot.deinit(a);
    try cc.tool_exec.executeSlots(&first_slots, &ctx, a, rid);
    try std.testing.expect(!first_slots[0].is_error);
    try std.testing.expect(!first_slots[1].is_error);

    // No acts_on/uses/produces fields: projection must be supplied entirely by
    // the execution ledger, while raw Edit body never enters the graph.
    const first_close_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"completed\",\"conclusion\":\"host execution verified\"}}", .{first});
    defer a.free(first_close_args);
    const first_close = try cc.task_tools.executeUpdate(&ctx, first_close_args);
    defer a.free(first_close);
    try std.testing.expect(std.mem.indexOf(u8, first_close, "\"explicit\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_close, "\"observed\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_close, "\"retained\":0") != null);
    const first_neighbors = try kg.neighborsJson(first, 30);
    defer a.free(first_neighbors);
    try std.testing.expect(try neighborTargetContains(a, &kg, first, "first.zig"));
    try std.testing.expect(std.mem.indexOf(u8, first_neighbors, "\"rel\":\"acts_on\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_neighbors, "\"rel\":\"produces\"") != null);
    try std.testing.expect(!(try neighborTargetContains(a, &kg, first, "PRIVATE_BODY_SENTINEL")));

    const second_claim_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"in_progress\"}}", .{second});
    defer a.free(second_claim_args);
    const second_claim = try cc.task_tools.executeUpdate(&ctx, second_claim_args);
    defer a.free(second_claim);

    const denied_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}/DENIED_SENTINEL.zig\",\"content\":\"must not execute\"}}", .{project_dir});
    defer a.free(denied_input);
    const missing_input = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}/MISSING_SENTINEL.zig\"}}", .{project_dir});
    defer a.free(missing_input);
    const read_second = try std.fmt.allocPrint(a, "{{\"file_path\":\"{s}\"}}", .{second_path});
    defer a.free(read_second);
    var second_slots = [_]cc.tool_exec.Slot{
        .{ .decision = .denied, .name = "Write", .id = "denied-write", .input = denied_input },
        .{ .decision = .run, .name = "Read", .id = "failed-read", .input = missing_input },
        .{ .decision = .run, .name = "Read", .id = "read-second", .input = read_second },
    };
    defer for (&second_slots) |*slot| slot.deinit(a);
    try cc.tool_exec.executeSlots(&second_slots, &ctx, a, rid);
    try std.testing.expect(second_slots[1].is_error);
    try std.testing.expect(!second_slots[2].is_error);

    // Explicit + observed copies of the same fact must collapse to one edge;
    // task one above still proves the zero-self-report path independently.
    const second_close_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"completed\",\"conclusion\":\"isolation verified\",\"acts_on\":[\"second.zig\"]}}", .{second});
    defer a.free(second_close_args);
    const second_close = try cc.task_tools.executeUpdate(&ctx, second_close_args);
    defer a.free(second_close);
    try std.testing.expect(std.mem.indexOf(u8, second_close, "\"observed\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_close, "\"explicit\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_close, "\"projected\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_close, "\"retained\":0") != null);
    const second_neighbors = try kg.neighborsJson(second, 30);
    defer a.free(second_neighbors);
    try std.testing.expect(try neighborTargetContains(a, &kg, second, "second.zig"));
    try std.testing.expect(!(try neighborTargetContains(a, &kg, second, "first.zig")));
    try std.testing.expect(!(try neighborTargetContains(a, &kg, second, "DENIED_SENTINEL")));
    try std.testing.expect(!(try neighborTargetContains(a, &kg, second, "MISSING_SENTINEL")));
    try std.testing.expect(!(try neighborTargetContains(a, &kg, first, "second.zig")));
}

test "L2 KG experience feedback: claim exposes verified prior execution before work" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const project_dir = pbuf[0..dir_len];
    const store_path = try std.fmt.allocPrint(a, "{s}/kg-experience-feedback.kg", .{project_dir});
    defer a.free(store_path);

    var kg = try makeClient(a, bin, store_path, "proj-experience-feedback");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    const root = try kg.createTask("parser recovery roadmap", "plan_root");
    const prior = try kg.createChildTask(root, "repair parser checkpoint recovery corruption", "plan_step");
    const unfinished = try kg.createChildTask(root, "parser checkpoint recovery unfinished decoy", "plan_step");
    const current = try kg.createChildTask(root, "diagnose parser checkpoint recovery regression", "plan_step");

    var tasks = cc.core_task_store.TaskStore.init(a);
    defer tasks.deinit();
    const ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .tasks = &tasks,
        .kg = &kg,
        .project_dir = project_dir,
        .cwd_abs = project_dir,
    };

    // Materialize the same lifecycle/provenance shape produced in normal use:
    // claim -> completed + verified_by -> tentative execution association.
    const prior_claim_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"in_progress\"}}", .{prior});
    defer a.free(prior_claim_args);
    const prior_claim = try cc.task_tools.executeUpdate(&ctx, prior_claim_args);
    defer a.free(prior_claim);
    const prior_close_args = try std.fmt.allocPrint(
        a,
        "{{\"taskId\":\"kg-{d}\",\"status\":\"completed\",\"conclusion\":\"parser checkpoint replay verified\",\"acts_on\":[\"src/parser_checkpoint.zig\"],\"uses\":[\"checkpoint-replay\"]}}",
        .{prior},
    );
    defer a.free(prior_close_args);
    const prior_close = try cc.task_tools.executeUpdate(&ctx, prior_close_args);
    defer a.free(prior_close);
    const confirmed_playbook = try kg.ensureConcept("verified-parser-recovery-playbook");
    try kg.addRefEdge(prior, "produces", confirmed_playbook, true);

    // A lexically closer but unfinished task must never enter the experience
    // packet. Its graph association is deliberately present to catch adapters
    // that inspect neighbors but forget lifecycle/evidence governance.
    const decoy = try kg.ensureConcept("UNFINISHED_EXPERIENCE_SENTINEL");
    try kg.addRefEdge(unfinished, "acts_on", decoy, false);

    // Prove the fixture actually distinguishes mixed-kind retrieval from the
    // task-only contract. This exact decision would consume a normal recall
    // slot, but must never appear in the experience packet's search window.
    _ = try kg.remember(.decision, "diagnose parser checkpoint recovery regression", "decision", false);
    const mixed_hits = try kg.recall("diagnose parser checkpoint recovery regression", 8, true);
    defer {
        for (mixed_hits) |*hit| hit.deinit(kg.allocator);
        kg.allocator.free(mixed_hits);
    }
    var saw_non_task_hit = false;
    for (mixed_hits) |hit| {
        if (!std.mem.eql(u8, hit.kind, "task")) saw_non_task_hit = true;
    }
    try std.testing.expect(saw_non_task_hit);

    const current_claim_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\",\"status\":\"in_progress\"}}", .{current});
    defer a.free(current_claim_args);
    const rid = cc.util_log.RequestId{ .bytes = [_]u8{'x'} ** 12 };
    const claim_result = try cc.tool_exec.executeOne(&ctx, "TaskUpdate", current_claim_args, "claim-current", a, rid);
    switch (claim_result) {
        .done => |done| {
            defer if (done.content) |content| a.free(content);
            try std.testing.expect(!done.is_error);
            const content = done.content orelse return error.TestUnexpectedResult;
            var parsed = try std.json.parseFromSlice(std.json.Value, a, content, .{});
            defer parsed.deinit();
            const packet = parsed.value.object.get("experience_packet") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("metacodes-experience-packet-v1", packet.object.get("schema_version").?.string);
            try std.testing.expect(packet.object.get("candidate_only").?.bool);
            try std.testing.expectEqualStrings("exact_task_text_task_kind_only", packet.object.get("automatic_probe_scope").?.string);
            try std.testing.expectEqualStrings("llm_before_work_if_insufficient", packet.object.get("semantic_expansion_owner").?.string);
            try std.testing.expectEqualStrings("multi_read_reverify_required", packet.object.get("snapshot_consistency").?.string);
            try std.testing.expectEqual(@as(i64, @intCast(current)), packet.object.get("query_task_id").?.integer);
            try std.testing.expect(std.mem.indexOf(u8, content, "repair parser checkpoint recovery corruption") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "src/parser_checkpoint.zig") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "checkpoint-replay") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "verified-parser-recovery-playbook") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "\"state\":\"tentative\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "\"state\":\"confirmed\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "\"evidence_node_ids\":[") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "parser checkpoint replay verified") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "UNFINISHED_EXPERIENCE_SENTINEL") == null);
            const history = packet.object.get("history").?.array.items;
            var prior_history: ?std.json.ObjectMap = null;
            for (history) |entry| {
                if (entry != .object) continue;
                const entry_id = entry.object.get("task_id") orelse continue;
                if (entry_id == .integer and entry_id.integer == @as(i64, @intCast(prior))) {
                    prior_history = entry.object;
                    break;
                }
            }
            const prior_entry = prior_history orelse return error.TestUnexpectedResult;
            const evidence_ids = prior_entry.get("evidence_node_ids").?.array.items;
            const verified_evidence = prior_entry.get("verified_evidence").?.array.items;
            try std.testing.expect(evidence_ids.len >= 1);
            try std.testing.expect(verified_evidence.len >= 1);
            const evidence_entry = verified_evidence[0].object;
            try std.testing.expectEqual(evidence_ids[0].integer, evidence_entry.get("node_id").?.integer);
            try std.testing.expect(std.mem.indexOf(u8, evidence_entry.get("text").?.string, "parser checkpoint replay verified") != null);
            const metrics = packet.object.get("metrics").?.object;
            try std.testing.expect(metrics.get("accepted_tasks").?.integer >= 1);
            try std.testing.expect(metrics.get("accepted_evidence_excerpts").?.integer >= 1);
            try std.testing.expectEqual(@as(i64, 0), metrics.get("evidence_excerpt_failures").?.integer);
            try std.testing.expect(metrics.get("rejected_not_completed").?.integer >= 1);
            try std.testing.expectEqual(@as(i64, 2), metrics.get("accepted_tentative").?.integer);
            try std.testing.expectEqual(@as(i64, 1), metrics.get("accepted_confirmed").?.integer);
            // The text-search window itself is task-only. Execution concepts
            // such as src/parser_checkpoint.zig cannot crowd out prior tasks.
            try std.testing.expectEqual(metrics.get("search_hits").?.integer, metrics.get("task_candidates").?.integer);
            const subprocess_lower = metrics.get("subprocess_calls_lower_bound").?.integer;
            const subprocess_upper = metrics.get("subprocess_calls_upper_bound").?.integer;
            try std.testing.expect(subprocess_lower >= 1);
            try std.testing.expect(subprocess_upper >= subprocess_lower);
            try std.testing.expect(!metrics.get("subprocess_count_exact").?.bool);
            try std.testing.expectEqual(@as(usize, 10), metrics.get("packet_bytes").?.string.len);
            if (std.c.getenv("METACODES_PRINT_EXPERIENCE_METRICS") != null) {
                std.debug.print(
                    "experience_feedback_metrics schema=v1 search_hits={d} task_candidates={d} accepted_tasks={d} accepted_associations={d} accepted_tentative={d} accepted_confirmed={d} rejected_not_completed={d} subprocess_lower={d} subprocess_upper={d} elapsed_ms={d} packet_bytes={s}\n",
                    .{
                        metrics.get("search_hits").?.integer,
                        metrics.get("task_candidates").?.integer,
                        metrics.get("accepted_tasks").?.integer,
                        metrics.get("accepted_associations").?.integer,
                        metrics.get("accepted_tentative").?.integer,
                        metrics.get("accepted_confirmed").?.integer,
                        metrics.get("rejected_not_completed").?.integer,
                        subprocess_lower,
                        subprocess_upper,
                        metrics.get("elapsed_ms").?.integer,
                        metrics.get("packet_bytes").?.string,
                    },
                );
            }
        },
        else => return error.TestUnexpectedResult,
    }

    // A fresh decision round after compaction/restart follows TaskGet rather
    // than re-claiming the live lease. The same governed experience must cross
    // the unified result boundary on that recovery path too.
    const current_get_args = try std.fmt.allocPrint(a, "{{\"taskId\":\"kg-{d}\"}}", .{current});
    defer a.free(current_get_args);
    const get_result = try cc.tool_exec.executeOne(&ctx, "TaskGet", current_get_args, "recover-current", a, rid);
    switch (get_result) {
        .done => |done| {
            defer if (done.content) |content| a.free(content);
            try std.testing.expect(!done.is_error);
            const content = done.content orelse return error.TestUnexpectedResult;
            try std.testing.expect(std.mem.indexOf(u8, content, "\"kg_status\":\"claimed\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "\"experience_packet\":{") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "repair parser checkpoint recovery corruption") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "parser checkpoint replay verified") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "UNFINISHED_EXPERIENCE_SENTINEL") == null);
            try std.testing.expect(std.mem.indexOf(u8, content, "\"query_reused_from_tool_result\":true") != null);
        },
        else => return error.TestUnexpectedResult,
    }

    // Scope-matched L2: prove the enriched tool result is not merely computed
    // and discarded. A real two-turn agent loop must serialize the historical
    // task into the second provider request before the model can choose work.
    const api_current = try kg.createChildTask(root, "investigate parser checkpoint recovery failure", "plan_step");
    var api_id_buf: [24]u8 = undefined;
    const api_id = try std.fmt.bufPrint(&api_id_buf, "{d}", .{api_current});
    const claim_sse_template =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"claim1\",\"name\":\"TaskUpdate\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"taskId\\\":\\\"kg-__TASK_ID__\\\",\\\"status\\\":\\\"in_progress\\\"}\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    const claim_sse = try std.mem.replaceOwned(u8, a, claim_sse_template, "__TASK_ID__", api_id);
    defer a.free(claim_sse);
    const responses = [_][]const u8{ claim_sse, KG_END_TURN_SSE };
    var srv = try harness.MockServer.startCassette(&responses, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var api_client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer api_client.deinit();
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "Claim the persistent task, inspect prior evidence, then continue.");
    var api_tasks = cc.core_task_store.TaskStore.init(a);
    defer api_tasks.deinit();
    const enabled = [_][]const u8{ "TaskUpdate", "KgRecall", "KgContext" };
    var defs_arena = std.heap.ArenaAllocator.init(a);
    defer defs_arena.deinit();
    var prompt_context = cc.tools.PromptContext{ .enabled_tool_names = &enabled };
    const defs = try cc.tools.toToolDefinitionsFull(defs_arena.allocator(), null, &prompt_context);
    const system_prompt = try cc.system_prompt.buildFull(a, "claude-sonnet-4-20250514", null, null, &enabled, "", true, "/tmp");
    defer a.free(system_prompt);
    const permission = cc.permission.createContext(.bypass_permissions, a);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const run_result = try cc.agent_loop.run(&conv, api_client.provider(), defs, &permission, .{
        .max_turns = 2,
        .system_prompt = system_prompt,
        .tasks = &api_tasks,
        .kg = &kg,
        .project_dir = project_dir,
        .cwd_abs = project_dir,
    }, &backend, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, run_result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());
    const first_request = srv.requestAt(0) orelse return error.NoRequestCaptured;
    const second_request = srv.requestAt(1) orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, first_request.body(), "LEXICAL EXPANSION") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_request.body(), "2-4 separate compact semantic variants") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_request.body(), "lexical-query-plan-v3") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_request.body(), "host executes the fixed batch") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_request.body(), "merges by node_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_request.body(), "repair parser checkpoint recovery corruption") == null);
    try std.testing.expect(std.mem.indexOf(u8, first_request.body(), "parser checkpoint replay verified") == null);
    try std.testing.expect(std.mem.indexOf(u8, second_request.body(), "metacodes-experience-packet-v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_request.body(), "repair parser checkpoint recovery corruption") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_request.body(), "parser checkpoint replay verified") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_request.body(), "llm_before_work_if_insufficient") != null);
    if (std.c.getenv("METACODES_PRINT_EXPERIENCE_METRICS") != null)
        std.debug.print("experience_feedback_delivery schema=v1 provider_requests={d} delivered_to_next_request=1\n", .{srv.requestCount()});
}

test "L2 KG: ref-edge 重试修复缺失 state 且不降级 confirmed" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kg-ref-retry.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-ref-retry");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;

    const task = try kg.ensureConcept("partial-projection-task");
    const target = try kg.ensureConcept("partial-projection-target");
    try kg.addEdge(task, "uses", target); // simulate add-edge success before state write failed
    try kg.addRefEdge(task, "uses", target, false);
    const repaired = try kg.neighborsJson(task, 20);
    defer a.free(repaired);
    try std.testing.expect(std.mem.indexOf(u8, repaired, "\"state\":\"tentative\"") != null);

    try kg.confirmClassification(task, "uses", target);
    try kg.addRefEdge(task, "uses", target, false); // agent retry must not downgrade human confirmation
    const monotonic = try kg.neighborsJson(task, 20);
    defer a.free(monotonic);
    try std.testing.expect(std.mem.indexOf(u8, monotonic, "\"state\":\"confirmed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, monotonic, "\"state\":\"tentative\"") == null);
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

const CHILD_KG_RECALL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"kg1\",\"name\":\"KgRecall\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"quasar-needle-731 isolated child memory\\\",\\\"lexical_plan\\\":{\\\"schema_version\\\":\\\"lexical-query-plan-v1\\\",\\\"intent\\\":\\\"task_recovery\\\",\\\"stage\\\":\\\"seed\\\",\\\"variants\\\":[{\\\"kind\\\":\\\"exact\\\",\\\"text\\\":\\\"quasar-needle-731 isolated child memory\\\"}],\\\"variant_index\\\":0,\\\"seen_node_ids\\\":[]}}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "L2 KG: general-purpose child gets read tools and an isolated KgClient" {
    const a = std.testing.allocator;
    const bin = findBin(a) orelse return error.SkipZigTest;
    defer a.free(bin);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const store = try std.fmt.allocPrint(a, "{s}/kg-child-read.kg", .{pbuf[0..dir_len]});
    defer a.free(store);

    var kg = try makeClient(a, bin, store, "proj-child-read");
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.SkipZigTest;
    _ = try kg.remember(.decision, "quasar-needle-731: child agents must recover this durable decision", "decision", false);

    const responses = [_][]const u8{ CHILD_KG_RECALL_SSE, KG_END_TURN_SSE };
    var srv = try harness.MockServer.startCassette(&responses, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    try agents.loadFromStandardPaths("");
    const general = agents.find("general-purpose").?;

    const enabled = [_][]const u8{ "KgRemember", "KgRecall", "KgContext" };
    var defs_arena = std.heap.ArenaAllocator.init(a);
    defer defs_arena.deinit();
    var prompt_ctx = cc.tools.PromptContext{ .enabled_tool_names = &enabled };
    const parent_defs = try cc.tools.toToolDefinitionsFull(defs_arena.allocator(), null, &prompt_ctx);
    const filtered = try cc.agents_filter.filterToolDefs(a, parent_defs, general);
    defer a.free(filtered);
    var child_policy = cc.tool_context.ToolSetExecutionPolicy{ .definitions = filtered };

    const perm = cc.permission.createContext(.bypass_permissions, a);
    var child_abort = cc.util_abort.AbortSignal.init();
    var result = try cc.core_subagent.spawnAgent(
        a,
        client.provider(),
        &client,
        parent_defs,
        &perm,
        &child_abort,
        "Recover the durable decision before answering.",
        .{
            .max_turns = 3,
            .tool_defs_override = filtered,
            .execution_policy = child_policy.executionPolicy(),
            .kg = &kg,
            .home_dir = "/tmp",
        },
    );
    defer result.deinit();

    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    const tools_field = cap.jsonField("tools") orelse return error.ToolsFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "\"name\":\"KgRecall\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "\"name\":\"KgContext\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_field, "\"name\":\"KgRemember\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "quasar-needle-731") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "child agents must recover this durable decision") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "seen_state_verified") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "agent_run_plan") != null);
    try std.testing.expectEqual(@as(u32, 1), result.tool_calls);

    // KgRecall sets abort on the client it executes against. The parent must stay untouched,
    // otherwise a child cancellation pointer leaks into the parent session after return.
    try std.testing.expect(kg.abort == null);
}
