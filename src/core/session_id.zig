//! SessionId:会话标识(多 Session 架构基石)。
//!
//! 背景:重构前 session id 这个 24-byte 定长 struct 埋在 transcript.zig 里,只在生成处用;
//! 下游(agent_loop.Options / ToolContext / preload / render)全用裸 `[]const u8`。多 Session
//! 化(M5/M6)需要把它当一等值类型携带、比较、做 HashMap key——本模块先把类型 + 生成函数
//! 抽成独立模块(单一真理源),让后续模块能 import 它而不必拖进整个 transcript。
//!
//! **本步(M1)仅做零行为变化的抽取**:类型 + gen()。equality / fromSlice / HashMap key
//! 等能力等 M5(协议读回)/M6(session 路由 + HashMap)真需要时,在那个 commit 里按确切
//! 签名加——不在这里投机性预加。
//!
//! 字符串边界(持久化路径)用 `asSlice()` 取 []const u8。

const std = @import("std");

/// 会话标识。24 个 hex 字符 = 16(ms 时间戳) + 8(monotonic ns 低位),自然可排序、唯一。
/// 值类型:可拷贝,无外部生命周期依赖。
pub const SessionId = struct {
    bytes: [24]u8,

    /// 借出底层字节(持久化路径的字符串边界用)。生命周期同 self。
    pub fn asSlice(self: *const SessionId) []const u8 {
        return self.bytes[0..];
    }

    /// 单 Session(N=1 / TUI)默认占位 id。多 Session 路由前,所有事件都归属它。
    /// **用 ASCII '0'(0x30)不是 \0(0x00)**:bytes 当 hex 字符串用(asSlice 喂持久化路径),
    /// 全 \0 会让路径含 NUL 字节炸掉;"000…0" 是合法 24-char hex。gen() 永远产不出它
    /// (要 ms 时间戳=0=1970-01-01,现实不可能)→ 安全 sentinel。**勿"优化"成 std.mem.zeroes。**
    pub const single: SessionId = .{ .bytes = .{'0'} ** 24 };
};

/// 生成 session id:ms 时间戳(可排序)+ monotonic ns 低 32 位 + 进程内原子计数(去重)。
/// 不用真随机(真随机会破坏 record-replay 确定性,见 recorder)。
/// 计数器的必要性:高负载下 clock_gettime(MONOTONIC) 连续两次可返回**相同读数**
/// (粗粒度 tick;全测试套并发时 64 连发实测撞过)→ 纯 ms+monotonic 会产重复 id,
/// 而 agent_ident(claim 租约)要求进程内每 loop 严格唯一。确定性自增序列,replay 安全。
var gen_counter = std.atomic.Value(u32).init(0);

pub fn gen() SessionId {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const ms: u64 = @intCast(@as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000));
    var ts2: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts2);
    const mono: u32 = @truncate(@as(u64, @bitCast(@as(i64, @intCast(ts2.nsec)))));
    const uniq = mono +% gen_counter.fetchAdd(1, .monotonic);

    var id: SessionId = undefined;
    _ = std.fmt.bufPrint(id.bytes[0..16], "{x:0>16}", .{ms}) catch unreachable;
    _ = std.fmt.bufPrint(id.bytes[16..24], "{x:0>8}", .{uniq}) catch unreachable;
    return id;
}

// ============================================================================
// Tests
// ============================================================================
const testing = std.testing;

test "gen 产 24-char id,全 hex 字符" {
    const id = gen();
    try testing.expectEqual(@as(usize, 24), id.asSlice().len);
    for (id.asSlice()) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(is_hex);
    }
}


test "gen 连发唯一(agent_ident 防撞地基:进程内并发 subagent 各持一 id)" {
    // claim 租约身份 = per-agent-loop gen();同进程紧邻两次 gen 必须不同
    // (ms 时戳相同时靠 monotonic ns 低位区分)。
    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const id = gen();
        const key = std.hash.XxHash64.hash(0, id.asSlice());
        const gop = try seen.getOrPut(key);
        try testing.expect(!gop.found_existing);
        try testing.expect(!std.mem.eql(u8, id.asSlice(), SessionId.single.asSlice()));
    }
}
