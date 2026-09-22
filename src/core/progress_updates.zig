//! Progress-update obligation: a multi-stage run that goes silent (#114).
//!
//! The shared Core forwards whatever visible text the model produces and
//! classifies it (commentary before a tool call, final at end_turn), but a
//! model that calls tools round after round without writing a word leaves the
//! user with nothing but tool lifecycle events — they say that something ran,
//! not which stage the task is at, what was found, or what comes next. The
//! default prompt's brevity rules push in the same direction, and how often a
//! given model narrates on its own is a model property, not a Core guarantee.
//!
//! This module is the host-side half of the expectation, shaped like the
//! delivery-cadence gate — a task-agnostic process obligation, never a verdict:
//!   * sensor: every tool round is classified as silent (no visible assistant
//!     text before its tool calls) or narrated; consecutive silent rounds are
//!     counted and any narrated round resets the count.
//!   * policy: at the turn boundary, `silent_rounds >= threshold` earns one
//!     bounded nudge asking for a short progress note (stage, findings, next
//!     step; no private reasoning) — never more than `MAX_PROGRESS_NUDGES` per
//!     run, never a denial. The counter restarts after a nudge, so the second
//!     one needs another full stretch of silence.
//!   * budget: injections go through the global host-injection meter.
//!
//! What it is not: it does not synthesize placeholder activity messages (the
//! model writes the update, so it carries task-level content); it does not fire
//! on simple tasks (a run that finishes within the threshold never sees it);
//! and it does not touch the final answer (the reply to a nudge is followed by
//! more tool calls → `commentary`, or ends the turn → `final`, exactly as any
//! other visible text is classified by the output-semantics channel).

const std = @import("std");

pub const MAX_PROGRESS_NUDGES: u8 = 2;

/// Consecutive silent tool rounds before the loop asks for an update. Three
/// rounds is past the "one quick lookup" shape and inside the window where a
/// user starts wondering whether anything is still happening.
pub const DEFAULT_SILENT_ROUNDS: u32 = 3;

pub const MARKER = "[progress update]";

/// `{d}` = consecutive silent tool rounds observed. Task-agnostic: the only
/// variable is the run's own counter.
pub const NUDGE_FMT =
    MARKER ++ "\n" ++
    "You have completed {d} consecutive tool rounds without telling the user " ++
    "anything. Before you continue, write one or two sentences of progress for " ++
    "the user: which stage of the task you are at, what you have found so far, " ++
    "and what you will do next. State facts about the task, not your private " ++
    "reasoning, and do not repeat tool output. Then continue the task.";

pub const State = struct {
    /// Consecutive tool rounds without visible assistant text (reset by any
    /// narrated round and by a nudge).
    silent_rounds: u32 = 0,
    /// Nudges injected so far (0..MAX_PROGRESS_NUDGES).
    nudges: u8 = 0,
    /// Longest silent stretch seen in the run (diagnostics only).
    max_silent_rounds: u32 = 0,

    /// Observe one completed tool round. `visible_text_bytes` is the visible
    /// assistant text the round produced before its tool calls.
    pub fn observeToolRound(self: *State, visible_text_bytes: usize) void {
        if (visible_text_bytes == 0) {
            self.silent_rounds +|= 1;
            self.max_silent_rounds = @max(self.max_silent_rounds, self.silent_rounds);
        } else {
            self.silent_rounds = 0;
        }
    }

    /// Pure policy over the host-observed count. A zero threshold never fires.
    pub fn decide(self: *const State, threshold: u32) bool {
        if (threshold == 0) return false;
        return self.nudges < MAX_PROGRESS_NUDGES and self.silent_rounds >= threshold;
    }

    /// A nudge was injected: count it and start the next silent stretch from zero.
    pub fn noteNudged(self: *State) void {
        self.nudges +|= 1;
        self.silent_rounds = 0;
    }
};

test "state: consecutive silent rounds accumulate and any narrated round resets the stretch" {
    var s = State{};
    s.observeToolRound(0);
    s.observeToolRound(0);
    try std.testing.expectEqual(@as(u32, 2), s.silent_rounds);
    s.observeToolRound(17);
    try std.testing.expectEqual(@as(u32, 0), s.silent_rounds);
    try std.testing.expectEqual(@as(u32, 2), s.max_silent_rounds);
    s.observeToolRound(0);
    try std.testing.expectEqual(@as(u32, 1), s.silent_rounds);
}

test "state: the policy fires at the threshold, restarts after a nudge, and never passes the bound" {
    var s = State{};
    try std.testing.expect(!s.decide(DEFAULT_SILENT_ROUNDS));
    s.observeToolRound(0);
    s.observeToolRound(0);
    try std.testing.expect(!s.decide(DEFAULT_SILENT_ROUNDS)); // 2 < 3
    s.observeToolRound(0);
    try std.testing.expect(s.decide(DEFAULT_SILENT_ROUNDS)); // 3 >= 3
    s.noteNudged();
    try std.testing.expectEqual(@as(u8, 1), s.nudges);
    try std.testing.expect(!s.decide(DEFAULT_SILENT_ROUNDS)); // stretch restarted
    s.observeToolRound(0);
    s.observeToolRound(0);
    s.observeToolRound(0);
    try std.testing.expect(s.decide(DEFAULT_SILENT_ROUNDS));
    s.noteNudged();
    // Bound reached: however long the silence, no third nudge.
    var i: usize = 0;
    while (i < 20) : (i += 1) s.observeToolRound(0);
    try std.testing.expect(!s.decide(DEFAULT_SILENT_ROUNDS));
    try std.testing.expectEqual(MAX_PROGRESS_NUDGES, s.nudges);
}

test "state: a zero threshold never fires" {
    var s = State{};
    s.observeToolRound(0);
    try std.testing.expect(!s.decide(0));
}
