//! 全局 host 注入计量器(元规则 ①:合成有界)。
//!
//! 每个过程门(requirement ledger / task obligation / 未来任何门)各自证明
//! 了自身 nudge 有界,但"各自有界"不蕴含"合成有界"——逐个添加机制会
//! 无声地把上下文预算吃穿。本计量器是唯一的注入额度出口:任何 host 注入
//! 必须先 tryConsume(),因此**无论存在多少个门、以何种顺序决策**,每 run
//! 的 host 注入总数 ≤ MAX_HOST_INJECTIONS_PER_RUN。
//!
//! Lean 元定理(control-plane/lean/MetaCodesControl/HostInjectionMeter.lean)
//! 对任意门序列量化:consumed_never_exceeds_cap / monotone / gate_agnostic。

const std = @import("std");

/// 每 run host 注入总上限。当前 = 账本预算(2)+ 义务预算(2)之和——
/// 引入计量器不改变今日行为,只是把隐式合成上界变成显式可证不变量;
/// 未来新门必须在这个总额度内分配,而不是各带一份新预算。
pub const MAX_HOST_INJECTIONS_PER_RUN: u8 = 4;

pub const Meter = struct {
    used: u8 = 0,

    /// 申请一次注入额度。true = 获准(计入);false = 总额度已尽,调用方
    /// 必须放弃本次注入(与各门自身的 one-shot/预算判定叠加,取更严者)。
    pub fn tryConsume(self: *Meter) bool {
        if (self.used >= MAX_HOST_INJECTIONS_PER_RUN) return false;
        self.used += 1;
        return true;
    }

    pub fn remaining(self: *const Meter) u8 {
        return MAX_HOST_INJECTIONS_PER_RUN - self.used;
    }
};

test "meter never exceeds the cap regardless of request count" {
    // Lean mirror: HostInjectionMeter.consumed_never_exceeds_cap.
    var meter = Meter{};
    var granted: usize = 0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (meter.tryConsume()) granted += 1;
    }
    try std.testing.expectEqual(@as(usize, MAX_HOST_INJECTIONS_PER_RUN), granted);
    try std.testing.expectEqual(@as(u8, 0), meter.remaining());
}

test "meter is gate-agnostic: interleaved consumers share one bound" {
    // Lean mirror: HostInjectionMeter.gate_agnostic(对任意门序列量化)。
    var meter = Meter{};
    var ledger_granted: usize = 0;
    var obligation_granted: usize = 0;
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        if (i % 2 == 0) {
            if (meter.tryConsume()) ledger_granted += 1;
        } else {
            if (meter.tryConsume()) obligation_granted += 1;
        }
    }
    try std.testing.expectEqual(
        @as(usize, MAX_HOST_INJECTIONS_PER_RUN),
        ledger_granted + obligation_granted,
    );
}
