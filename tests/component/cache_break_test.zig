//! L2 组件测试:prompt cache 击穿检测 + 工具 name 排序(批3,对齐 cc)。

const std = @import("std");
const cc = @import("cc");

const Detector = cc.cache_break.CacheBreakDetector;

test "L2 击穿: 首次无基线 → null" {
    var d = Detector{};
    d.recordRequest("sys", "tools", "model");
    try std.testing.expect(d.checkResponse(5000, 0) == null);
}

test "L2 击穿: cache_read 稳定 → 无击穿" {
    var d = Detector{};
    d.recordRequest("sys", "tools", "model");
    _ = d.checkResponse(5000, 0); // 建基线
    d.recordRequest("sys", "tools", "model"); // 指纹不变
    try std.testing.expect(d.checkResponse(5000, 0) == null); // 没跌
}

test "L2 击穿: 大跌 + system 变 → 报 system prompt changed" {
    var d = Detector{};
    d.recordRequest("sysA", "tools", "model");
    _ = d.checkResponse(5000, 0);
    d.recordRequest("sysB-different", "tools", "model"); // system 变
    const r = d.checkResponse(100, 4900); // 大跌(5000→100)
    try std.testing.expect(r != null);
    try std.testing.expectEqualStrings("system prompt changed", r.?);
}

test "L2 击穿: 大跌 + tools 变 → 报 tool schemas changed" {
    var d = Detector{};
    d.recordRequest("sys", "toolsA", "model");
    _ = d.checkResponse(5000, 0);
    d.recordRequest("sys", "toolsB-diff", "model");
    const r = d.checkResponse(100, 4900);
    try std.testing.expectEqualStrings("tool schemas changed", r.?);
}

test "L2 击穿: 大跌 + 指纹全不变 → 报 TTL/server-side" {
    var d = Detector{};
    d.recordRequest("sys", "tools", "model");
    _ = d.checkResponse(5000, 0);
    d.recordRequest("sys", "tools", "model"); // 全不变
    const r = d.checkResponse(100, 4900);
    try std.testing.expect(r != null);
    try std.testing.expect(std.mem.indexOf(u8, r.?, "TTL") != null);
}

test "L2 击穿: 小跌(噪声)→ 不报" {
    var d = Detector{};
    d.recordRequest("sysA", "tools", "model");
    _ = d.checkResponse(5000, 0);
    d.recordRequest("sysB", "tools", "model");
    // 5000→4500 跌 500 < MIN_DROP_TOKENS(2000) → 不报
    try std.testing.expect(d.checkResponse(4500, 0) == null);
}

// 工具 name 排序:动态工具按 name 排序追加(静态 registry 不动)。
fn dummyExec(_: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
    return error.NotImplemented;
}

test "L2 工具排序: 动态工具按 name 排序(prefix 稳定)" {
    const a = std.testing.allocator;
    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    // 乱序注册 3 个动态工具
    try dyn.register("zzz_tool", "z", &.{}, dummyExec, null);
    try dyn.register("aaa_tool", "a", &.{}, dummyExec, null);
    try dyn.register("mmm_tool", "m", &.{}, dummyExec, null);

    const defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(defs);

    // 找到动态工具的位置,确认它们按 name 升序(aaa < mmm < zzz)
    var ai: ?usize = null;
    var mi: ?usize = null;
    var zi: ?usize = null;
    for (defs, 0..) |d, i| {
        if (std.mem.eql(u8, d.name, "aaa_tool")) ai = i;
        if (std.mem.eql(u8, d.name, "mmm_tool")) mi = i;
        if (std.mem.eql(u8, d.name, "zzz_tool")) zi = i;
    }
    try std.testing.expect(ai != null and mi != null and zi != null);
    try std.testing.expect(ai.? < mi.? and mi.? < zi.?);
}
