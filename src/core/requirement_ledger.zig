//! Session-end requirement-ledger closure obligation.
//!
//! The dominant residual failure class on hard tasks is dropped explicit
//! requirements: the model implements the mainline and silently loses edge
//! clauses the statement names. This module pairs the TinyKG-backed task
//! plane (the model's own TaskCreate ledger) with a bounded host gate:
//! decompose-then-close. Like the verification gate it is a process
//! obligation, never a verdict — the host counts open ledger items, it does
//! not judge their content.
//!
//! Formal model: control-plane/lean/MetaCodesControl/RequirementLedger.lean.
//! Theorems (pristine sessions are never nudged, the nudge budget is a hard
//! bound, closure disarms) mirror the tests named alongside them.

const std = @import("std");

/// Injected once at the first tool-result boundary (second request onward —
/// the cacheable first request stays byte-identical). Task-agnostic.
pub const LEDGER_PROMPT_TEXT =
    "[requirement ledger]\n" ++
    "Before going further: decompose the task statement into your task list " ++
    "(TaskCreate) — one item per explicitly requested behavior or " ++
    "requirement, including edge conditions the statement names. Every " ++
    "conditional clause, named boundary (empty/zero/duplicate/ordering/" ++
    "case), and requested output artifact is a candidate item — a statement " ++
    "with many clauses deserves many items. Close each item " ++
    "(status=completed) only after a check you actually executed in this " ++
    "session (a command, a test, an observed output) — asserting it works " ++
    "without running anything is not verification. Close inapplicable items " ++
    "with a short reason. Keep the ledger current as you work.\n" ++
    // PO-V2 M3(prompt 协议,任务无关):计划期钉下的具体选择要落成可核对
    // 的 decision;fstack-r2 的 dotenv 死法 = 计划两次决定 debug 级,下一个
    // Edit 写成 info,自测把漂移钉死——typed 决策 + 收尾核对是它的直接猎物。
    "When your plan fixes a concrete choice (a level, a format, an " ++
    "algorithm, a name), record it as a one-line decision (KgRemember, " ++
    "kind=decision). Before your final answer, re-check each recorded " ++
    "decision against your actual changes: honored, or explicitly revised " ++
    "with a reason. If you discover a defect you decide not to fix, record " ++
    "it as an open task item instead of prose. When a convention is NOT " ++
    "stated by the task (accepted input values, an output field's exact " ++
    "shape, an argv form), search the repository for prior art before " ++
    "inventing one — existing tests, caches, and sibling call sites usually " ++
    "already pin it. But prior art only fills gaps: an explicit signal from " ++
    "the task statement or from verifier feedback (including a test name " ++
    "that names a module, an algorithm, or a behavior) outranks repository " ++
    "convention when they conflict.";

/// Premature final answer with open ledger items. `{d}` = open count.
pub const OPEN_NUDGE_FMT =
    "[requirement ledger]\n" ++
    "You are about to finish, but {d} item(s) on your task ledger are still " ++
    "open. Before your final answer: complete each remaining item and mark " ++
    "it completed, or close it with an explicit reason why it does not " ++
    "apply. Do not silently drop declared requirements.";

/// Premature final answer after mutations with no ledger ever recorded.
pub const COVERAGE_NUDGE_TEXT =
    "[requirement ledger]\n" ++
    "You are about to finish after making changes, but never recorded a " ++
    "requirement ledger. Before your final answer: re-check the task " ++
    "statement and confirm each explicitly requested behavior is " ++
    "implemented — if there are multiple requirements, record and close " ++
    "them now; if it is a single requirement, state that explicitly.";

/// 全关但极短的账本再获一次重扫 nudge(p3 生产取证:失分任务登 2-4 条、
/// verifier 检 11-15 面,open_at_final=0 让旧 gate 全程免疫)。一次性;
/// 要求按"执行过的检查"重扫,不奖励凑数。
pub const SHALLOW_NUDGE_TEXT =
    "[requirement ledger]\n" ++
    "You are about to finish and every ledger item is closed — but the " ++
    "ledger is very short. Re-scan the task statement once before your " ++
    "final answer: every conditional clause, named edge case (empty/zero/" ++
    "duplicate/ordering/case), and requested output artifact should map to " ++
    "an item you verified by an executed check. Add and verify anything " ++
    "you missed; if the statement genuinely has this few requirements, " ++
    "state that explicitly and finish.";

/// 浅枚举地板:≤ 此数且全关时给一次重扫。p3:失分聚在 2-4,满分最低 3;
/// 对 3 条真做完的任务代价只是一轮廉价重扫。
pub const SHALLOW_FLOOR: usize = 3;

pub const MAX_LEDGER_NUDGES: u8 = 2;

pub const State = struct {
    prompt_emitted: bool = false,
    nudges: u8 = 0,
    coverage_nudge_used: bool = false,
    shallow_nudge_used: bool = false,

    /// Decide the nudge for a premature final answer. Pure policy over
    /// host-observed counts; mirrors `RequirementLedger.wantsNudge`.
    pub fn decide(
        self: *const State,
        open: usize,
        total: usize,
        mutations_occurred: bool,
    ) Decision {
        if (self.nudges >= MAX_LEDGER_NUDGES) return .none;
        if (open > 0) return .open_items;
        if (total > 0 and total <= SHALLOW_FLOOR and mutations_occurred and
            self.prompt_emitted and !self.shallow_nudge_used) return .shallow;
        if (total == 0 and mutations_occurred and self.prompt_emitted and
            !self.coverage_nudge_used) return .coverage;
        return .none;
    }
};

pub const Decision = enum { none, open_items, coverage, shallow };

test "pristine sessions are never nudged" {
    // Lean mirror: RequirementLedger.pristine_never_nudged.
    var state = State{ .prompt_emitted = true };
    try std.testing.expectEqual(Decision.none, state.decide(0, 0, false));
    // No prompt -> no coverage nudge either (the model was never asked).
    var silent = State{};
    try std.testing.expectEqual(Decision.none, silent.decide(0, 0, true));
}

test "open items nudge until the budget is exhausted" {
    // Lean mirror: RequirementLedger.nudges_bounded.
    var state = State{ .prompt_emitted = true };
    try std.testing.expectEqual(Decision.open_items, state.decide(2, 3, true));
    state.nudges = MAX_LEDGER_NUDGES;
    try std.testing.expectEqual(Decision.none, state.decide(2, 3, true));
}

test "shallow nudge fires once on a closed-but-short ledger" {
    // Lean mirror: RequirementLedger.shallow_one_shot / shallow_needs_prompt_and_mutations.
    var state = State{ .prompt_emitted = true };
    // 全关 + total ≤ 地板 + 有变更 → 一次重扫。
    try std.testing.expectEqual(Decision.shallow, state.decide(0, 2, true));
    state.shallow_nudge_used = true;
    try std.testing.expectEqual(Decision.none, state.decide(0, 2, true));
    // open 优先于 shallow;深枚举(> 地板)不触发;无变更/无 prompt 不触发。
    var fresh = State{ .prompt_emitted = true };
    try std.testing.expectEqual(Decision.open_items, fresh.decide(1, 2, true));
    try std.testing.expectEqual(Decision.none, fresh.decide(0, SHALLOW_FLOOR + 1, true));
    try std.testing.expectEqual(Decision.none, fresh.decide(0, 2, false));
    var silent = State{};
    try std.testing.expectEqual(Decision.none, silent.decide(0, 2, true));
}

test "closure disarms and coverage fires once" {
    // Lean mirror: RequirementLedger.closure_disarms / coverage_is_one_shot.
    var state = State{ .prompt_emitted = true, .shallow_nudge_used = true };
    // shallow 已消耗时,闭合的短账本回到 none(closure disarms open_items)。
    try std.testing.expectEqual(Decision.none, state.decide(0, 3, true));
    try std.testing.expectEqual(Decision.coverage, state.decide(0, 0, true));
    state.coverage_nudge_used = true;
    try std.testing.expectEqual(Decision.none, state.decide(0, 0, true));
}

test "M3: ledger prompt carries the decision-record and defect-to-ledger protocol" {
    // 提示协议是机制的一部分(fstack-r2:dotenv 计划→代码漂移;security
    // 亲口识别缺陷后散文带过)。钉住条款,防无声回退。
    try std.testing.expect(std.mem.indexOf(u8, LEDGER_PROMPT_TEXT, "KgRemember") != null);
    try std.testing.expect(std.mem.indexOf(u8, LEDGER_PROMPT_TEXT, "kind=decision") != null);
    try std.testing.expect(std.mem.indexOf(u8, LEDGER_PROMPT_TEXT, "honored, or explicitly revised") != null);
    try std.testing.expect(std.mem.indexOf(u8, LEDGER_PROMPT_TEXT, "open task item") != null);
}
