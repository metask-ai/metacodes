//! 认知模式调度器(跨尝试科学方法的策略半边)。
//!
//! 理解是语义的、不可证;但"同一证据点连败 N 次 ⇒ 当前读法已穷尽 ⇒
//! 强制切换读法"是纯 host 可观察策略。模式的**语义**(每个 directive 的
//! 措辞)是工程分类器;模式的**调度**(streak → mode)是纯函数,由 Lean
//! 镜面证明(全函数/随 streak 单调不回退/首败默认 verify/三败必达 union)
//! ——与 ledger/obligation 同款分工。
//!
//! 零新增注入源:调度只参数化既有结局 note 的内容,不产生新的 host
//! 注入,与注入计量器无交互。
//!
//! Lean 镜面:control-plane/lean/MetaCodesControl/CognitiveMode.lean。

const std = @import("std");

pub const Mode = enum {
    verify,
    construct,
    union_all,
    invert,

    pub fn directive(self: Mode) []const u8 {
        return switch (self) {
            .verify => "verify it against the workspace and fix the discrepancy",
            .construct => "verification is exhausted for this point — read it " ++
                "constructively: create the thing it names and make the claim true",
            .union_all => "single readings are exhausted — enumerate every plausible " ++
                "reading and satisfy their UNION in this one attempt (a cheap shotgun " ++
                "beats another single guess against a delayed verdict)",
            .invert => "repetition has refuted your standing interpretation — assume " ++
                "it is wrong, argue the strongest alternative reading, and implement that",
        };
    }
};

/// streak = 该证据点在**连续末尾**多少次既往尝试中都失败。
/// 0/1 → verify(首败没有历史,默认模式即无害);2 → construct;
/// 3 → union;≥4 → invert(终态保持,不回退)。
pub fn schedule(streak: usize) Mode {
    return switch (streak) {
        0, 1 => .verify,
        2 => .construct,
        3 => .union_all,
        else => .invert,
    };
}

test "schedule is total, monotone, defaults to verify, reaches union by three" {
    // Lean mirror: CognitiveMode.{defaults_to_verify, monotone, reaches_union}.
    try std.testing.expectEqual(Mode.verify, schedule(0));
    try std.testing.expectEqual(Mode.verify, schedule(1));
    try std.testing.expectEqual(Mode.construct, schedule(2));
    try std.testing.expectEqual(Mode.union_all, schedule(3));
    try std.testing.expectEqual(Mode.invert, schedule(4));
    try std.testing.expectEqual(Mode.invert, schedule(100));
    var previous: usize = 0;
    for (0..12) |streak| {
        const rank = @intFromEnum(schedule(streak));
        try std.testing.expect(rank >= previous);
        previous = rank;
    }
}
