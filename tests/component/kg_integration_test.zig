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
