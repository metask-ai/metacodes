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
    "requirement, including edge conditions the statement names. Close each " ++
    "item (status=completed) only when it is implemented and verified; close " ++
    "inapplicable items with a short reason. Keep the ledger current as you " ++
    "work.\n" ++
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
    "already pin it.";

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

pub const MAX_LEDGER_NUDGES: u8 = 2;

pub const State = struct {
    prompt_emitted: bool = false,
    nudges: u8 = 0,
    coverage_nudge_used: bool = false,

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
        if (total == 0 and mutations_occurred and self.prompt_emitted and
            !self.coverage_nudge_used) return .coverage;
        return .none;
    }
};

pub const Decision = enum { none, open_items, coverage };

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

test "closure disarms and coverage fires once" {
    // Lean mirror: RequirementLedger.closure_disarms.
    var state = State{ .prompt_emitted = true };
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
