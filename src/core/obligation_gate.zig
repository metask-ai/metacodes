//! 任务范围收尾义务的执行面(动态层"合法过拟合"的 actuation 半边)。
//!
//! 义务由运行期 author 从任务环境学得(self_evolution.ObligationEnvelope,
//! 绑定 task_sha256、随店走、可撤回);本模块只做两件事:
//! ① 观察本 Run 内执行过的 Bash 命令,子串命中即记 met;
//! ② 提前收尾时对未满足义务给**有界 nudge**(ledger 同款哲学:纯注入、
//!    绝不硬拒、预算封顶、prompt 未给不罚)。
//! 策略纯函数 decide() 与 Lean 文档级证明镜面对应
//! (control-plane/lean/MetaCodesControl/ObligationGate.lean)。

const std = @import("std");
const self_evolution = @import("self_evolution.zig");
const kg_client_mod = @import("../kg/client.zig");

pub const MAX_OBLIGATION_NUDGES: u8 = 2;

pub const NUDGE_FMT =
    "[task obligation]\n" ++
    "A rule you authored for this task in a previous attempt is not yet " ++
    "satisfied: {s}\n" ++
    "It requires that, before finishing, you execute a command containing " ++
    "`{s}` and act on its result. Run it now and show the outcome; if it is " ++
    "genuinely inapplicable in this workspace, say so explicitly with the " ++
    "reason.";

pub const Decision = struct {
    /// 需要 nudge 的义务下标;null = 无动作。
    index: ?usize,
};

pub const Runtime = struct {
    arena: std.heap.ArenaAllocator,
    envelopes: []self_evolution.ObligationEnvelope,
    met: []bool,
    nudged: []bool,
    nudges_used: u8 = 0,

    pub fn deinit(self: *Runtime) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const Runtime) usize {
        return self.envelopes.len;
    }

    /// Bash dispatch 观察:任一义务的 needle 是命令子串 → met。
    pub fn observeCommand(self: *Runtime, command: []const u8) void {
        for (self.envelopes, 0..) |envelope, index| {
            if (self.met[index]) continue;
            if (std.mem.indexOf(u8, command, envelope.command_needle) != null)
                self.met[index] = true;
        }
    }

    /// 提前收尾时的策略(纯:只读状态,不落副作用——调用方按返回值
    /// 记账,与 ledger 的 State.decide 同款)。Lean 镜面:ObligationGate。
    pub fn decide(self: *const Runtime) Decision {
        if (self.nudges_used >= MAX_OBLIGATION_NUDGES) return .{ .index = null };
        for (self.envelopes, 0..) |_, index| {
            if (self.met[index] or self.nudged[index]) continue;
            return .{ .index = index };
        }
        return .{ .index = null };
    }

    /// 记账:该义务已 nudge(每义务一次,全局预算封顶)。
    pub fn noteNudged(self: *Runtime, index: usize) void {
        self.nudged[index] = true;
        self.nudges_used += 1;
    }
};

/// 从 KG 装载当前任务的义务运行时。义务缺失/店不可用 → null(零开销)。
pub fn load(
    gpa: std.mem.Allocator,
    kg: *kg_client_mod.KgClient,
    task_hint: []const u8,
) ?*Runtime {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const envelopes = self_evolution.collectObligations(a, kg, task_hint) catch {
        arena.deinit();
        return null;
    };
    if (envelopes.len == 0) {
        arena.deinit();
        return null;
    }
    const met = a.alloc(bool, envelopes.len) catch {
        arena.deinit();
        return null;
    };
    const nudged = a.alloc(bool, envelopes.len) catch {
        arena.deinit();
        return null;
    };
    @memset(met, false);
    @memset(nudged, false);
    const runtime = gpa.create(Runtime) catch {
        arena.deinit();
        return null;
    };
    runtime.* = .{ .arena = arena, .envelopes = envelopes, .met = met, .nudged = nudged };
    return runtime;
}

fn testRuntime(envelope_count: usize) Runtime {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const a = arena.allocator();
    const envelopes = a.alloc(self_evolution.ObligationEnvelope, envelope_count) catch unreachable;
    for (envelopes, 0..) |*e, i| {
        e.* = .{
            .candidate_id = "00" ** 32,
            .task_sha256 = "11" ** 32,
            .command_needle = if (i == 0) "pytest test_a.py" else "make check",
            .reason = "learned closure obligation",
        };
    }
    const met = a.alloc(bool, envelope_count) catch unreachable;
    const nudged = a.alloc(bool, envelope_count) catch unreachable;
    @memset(met, false);
    @memset(nudged, false);
    return .{ .arena = arena, .envelopes = envelopes, .met = met, .nudged = nudged };
}

test "observed command satisfies the obligation and disarms the nudge" {
    var runtime = testRuntime(1);
    defer runtime.arena.deinit();
    try std.testing.expectEqual(@as(?usize, 0), runtime.decide().index);
    runtime.observeCommand("cd /workspace && pytest test_a.py -q");
    try std.testing.expectEqual(@as(?usize, null), runtime.decide().index);
}

test "each obligation nudges at most once and the budget is global" {
    // Lean mirror: ObligationGate.per_obligation_one_shot / budget_bound.
    var runtime = testRuntime(2);
    defer runtime.arena.deinit();
    const first = runtime.decide().index orelse return error.TestExpectedNudge;
    runtime.noteNudged(first);
    const second = runtime.decide().index orelse return error.TestExpectedNudge;
    try std.testing.expect(second != first);
    runtime.noteNudged(second);
    try std.testing.expectEqual(@as(?usize, null), runtime.decide().index);
    // 预算封顶:即使有第三个义务也不再 nudge(nudges_used=2)。
    try std.testing.expectEqual(@as(u8, 2), runtime.nudges_used);
}

test "unmatched command leaves the obligation open" {
    var runtime = testRuntime(1);
    defer runtime.arena.deinit();
    runtime.observeCommand("ls -la");
    try std.testing.expectEqual(@as(?usize, 0), runtime.decide().index);
}
