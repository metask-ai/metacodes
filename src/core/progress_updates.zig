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
//!   * sensor: every turn is observed. Visible model text (non-whitespace bytes
//!     the user saw; thinking and host-rendered decorations do not count) ends
//!     the silent stretch; a tool round without it lengthens the stretch by one
//!     round; the stretch also has a wall-clock length, measured from the last
//!     visible text (or nudge, or run start).
//!   * policy: at the turn boundary a stretch of at least `Thresholds.rounds`
//!     silent tool rounds AND at least `Thresholds.min_silent_ms` of silence
//!     earns one bounded nudge asking for a short progress note (stage,
//!     findings, next step; no private reasoning) — never more than
//!     `MAX_PROGRESS_NUDGES` decisions per run, never a denial. The stretch
//!     restarts after a decision, so the second one needs another full stretch.
//!     Rounds alone would fire on three sub-second lookups; time alone would
//!     fire during one long test run whose spinner already names the tool.
//!   * budget: injections go through the global host-injection meter.
//!   * hosts opt in: `agent_loop.Options.progress_updates` is a host-contract
//!     field like the sibling gates (interactive REPL, web session and
//!     `--stream-json` headless turn it on; macro runs, evals and embedders
//!     without a reader do not).
//!
//! What it is not: it does not synthesize placeholder activity messages (the
//! model writes the update, so it carries task-level content); it does not fire
//! on simple tasks (a run that finishes within the thresholds never sees it);
//! and it does not touch the final answer (the reply to a nudge is followed by
//! more tool calls → `commentary`, or ends the turn → `final`, exactly as any
//! other visible text is classified by the output-semantics channel).
//!
//! Lean mirror: control-plane/lean/MetaCodesControl/ProgressUpdates.lean proves
//! the policy (narrated turn never nudged, below either threshold never fires,
//! decisions bounded over any trace); `maxNudges` there is this file's
//! `MAX_PROGRESS_NUDGES` (lockstep-checked by
//! scripts/eval/tests/test_delivery_cadence_constants.py).

const std = @import("std");
/// Monotonic clock type shared with agent_loop (`util/time.zig` nowNs).
pub const Nanos = @import("../util/time.zig").Nanos;

/// Per-run bound on decisions (and therefore nudges). Lean mirror: `maxNudges`.
pub const MAX_PROGRESS_NUDGES: u8 = 2;

/// Consecutive silent tool rounds before the loop may ask for an update. Three
/// rounds is past the "one quick lookup" shape.
pub const DEFAULT_SILENT_ROUNDS: u32 = 3;

/// Wall-clock silence (since the last visible model text) before the loop may
/// ask. The prompt section speaks of "more than a few seconds"; this is that
/// floor, so quick cached rounds never trip the gate on their own.
pub const DEFAULT_MIN_SILENT_MS: u64 = 10_000;

pub const MARKER = "[progress update]";

/// `{d}` = consecutive silent tool rounds observed. Task-agnostic: the only
/// variable is the run's own counter. Asks for the note and the continuation
/// in the same reply so the note is never mistaken for the answer.
pub const NUDGE_FMT =
    MARKER ++ "\n" ++
    "{d} tool rounds in a row have gone by without a word to the user. In this " ++
    "same reply, first give one or two sentences of progress — the stage you are " ++
    "at, what you found, what you will do next (task facts, not private reasoning, " ++
    "no tool output) — then go on with the task without stopping: the next tool " ++
    "call, or the final answer if nothing is left to do.";

pub const Thresholds = struct {
    /// Silent tool rounds required. 0 = rounds are not required (time-only).
    rounds: u32 = DEFAULT_SILENT_ROUNDS,
    /// Wall-clock silence required, milliseconds. 0 = rounds-only.
    min_silent_ms: u64 = DEFAULT_MIN_SILENT_MS,
};

pub const State = struct {
    /// Consecutive tool rounds without visible model text (reset by any
    /// visible text and by a decision).
    silent_rounds: u32 = 0,
    /// Monotonic ns of the last visible model text, decision, or run start:
    /// the silent stretch's wall-clock origin.
    last_visible_ns: Nanos,
    /// Boundary decisions so far (0..MAX_PROGRESS_NUDGES): fired nudges in
    /// enforced mode, would-have-fired in observe mode.
    decisions: u8 = 0,
    /// Nudges actually injected (≤ decisions; 0 in observe mode).
    nudges: u8 = 0,
    /// Longest silent stretch seen in the run (terminal record).
    max_silent_rounds: u32 = 0,

    pub fn init(now_ns: Nanos) State {
        return .{ .last_visible_ns = now_ns };
    }

    /// Observe one completed turn. `visible_text_bytes` = non-whitespace model
    /// text the user saw this turn; `has_tool_use` = the turn issued tool calls.
    /// Visible text ends the stretch whatever else the turn did (a narrated
    /// answer that a terminal gate sends back for more work counts as
    /// narration); a silent tool round lengthens it; a silent turn without
    /// tools (thinking only) leaves the round count alone but the clock runs.
    pub fn observeTurn(self: *State, visible_text_bytes: usize, has_tool_use: bool, now_ns: Nanos) void {
        if (visible_text_bytes > 0) {
            self.silent_rounds = 0;
            self.last_visible_ns = now_ns;
            return;
        }
        if (!has_tool_use) return;
        self.silent_rounds +|= 1;
        self.max_silent_rounds = @max(self.max_silent_rounds, self.silent_rounds);
    }

    pub fn silentForMs(self: *const State, now_ns: Nanos) u64 {
        if (now_ns <= self.last_visible_ns) return 0;
        return @intCast(@divTrunc(now_ns - self.last_visible_ns, std.time.ns_per_ms));
    }

    /// Pure policy over the host-observed stretch. Lean mirror: `decide`.
    pub fn decide(self: *const State, thresholds: Thresholds, now_ns: Nanos) bool {
        return self.decisions < MAX_PROGRESS_NUDGES and
            self.silent_rounds >= thresholds.rounds and
            self.silentForMs(now_ns) >= thresholds.min_silent_ms;
    }

    /// The boundary decided: count it (and the injection, when one happened)
    /// and start the next stretch from zero. Lean mirror: `step`.
    pub fn noteDecided(self: *State, injected: bool, now_ns: Nanos) void {
        self.decisions +|= 1;
        if (injected) self.nudges +|= 1;
        self.silent_rounds = 0;
        self.last_visible_ns = now_ns;
    }
};

/// Bytes of `text` that are not ASCII whitespace: the sensor's notion of
/// "the user saw something" (a lone "\n" delta before a tool call is not
/// narration, and neither is a bare space).
pub fn visibleLen(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        if (!std.ascii.isWhitespace(c)) n += 1;
    }
    return n;
}

const ms: Nanos = std.time.ns_per_ms;

test "state: silent tool rounds accumulate, visible text resets rounds and the clock, thinking-only turns count no round" {
    var s = State.init(0);
    s.observeTurn(0, true, 1 * ms);
    s.observeTurn(0, true, 2 * ms);
    try std.testing.expectEqual(@as(u32, 2), s.silent_rounds);
    try std.testing.expectEqual(@as(u64, 2), s.silentForMs(2 * ms));
    s.observeTurn(0, false, 3 * ms); // no text, no tools: not a silent round
    try std.testing.expectEqual(@as(u32, 2), s.silent_rounds);
    s.observeTurn(17, false, 5 * ms); // narrated turn the loop continued (no tool call)
    try std.testing.expectEqual(@as(u32, 0), s.silent_rounds);
    try std.testing.expectEqual(@as(u64, 0), s.silentForMs(5 * ms));
    try std.testing.expectEqual(@as(u32, 2), s.max_silent_rounds);
    s.observeTurn(0, true, 6 * ms);
    try std.testing.expectEqual(@as(u32, 1), s.silent_rounds);
    try std.testing.expectEqual(@as(u64, 1), s.silentForMs(6 * ms));
}

test "state: the policy needs both thresholds, restarts after a decision, and never passes the bound" {
    const t = Thresholds{ .rounds = 3, .min_silent_ms = 10 };
    var s = State.init(0);
    try std.testing.expect(!s.decide(t, 100 * ms));
    s.observeTurn(0, true, 1 * ms);
    s.observeTurn(0, true, 2 * ms);
    try std.testing.expect(!s.decide(t, 100 * ms)); // 2 < 3 rounds
    s.observeTurn(0, true, 3 * ms);
    try std.testing.expect(!s.decide(t, 9 * ms)); // 3 rounds but 9 ms < 10 ms
    try std.testing.expect(s.decide(t, 10 * ms)); // both thresholds met
    s.noteDecided(true, 10 * ms);
    try std.testing.expectEqual(@as(u8, 1), s.decisions);
    try std.testing.expectEqual(@as(u8, 1), s.nudges);
    try std.testing.expect(!s.decide(t, 100 * ms)); // stretch restarted
    s.observeTurn(0, true, 11 * ms);
    s.observeTurn(0, true, 12 * ms);
    s.observeTurn(0, true, 13 * ms);
    try std.testing.expect(s.decide(t, 30 * ms));
    s.noteDecided(false, 30 * ms); // observe mode: decided, nothing injected
    try std.testing.expectEqual(@as(u8, 2), s.decisions);
    try std.testing.expectEqual(@as(u8, 1), s.nudges);
    // Bound reached: however long the silence, no third decision.
    var i: usize = 0;
    while (i < 20) : (i += 1) s.observeTurn(0, true, @as(Nanos, @intCast(40 + i)) * ms);
    try std.testing.expect(!s.decide(t, 1000 * ms));
    try std.testing.expectEqual(MAX_PROGRESS_NUDGES, s.decisions);
}

test "state: a zero threshold on one axis leaves the other axis in charge" {
    var s = State.init(0);
    s.observeTurn(0, true, 1 * ms);
    try std.testing.expect(s.decide(.{ .rounds = 1, .min_silent_ms = 0 }, 1 * ms)); // rounds-only
    try std.testing.expect(!s.decide(.{ .rounds = 0, .min_silent_ms = 5 }, 4 * ms)); // time-only, not yet
    try std.testing.expect(s.decide(.{ .rounds = 0, .min_silent_ms = 5 }, 5 * ms));
}

test "visibleLen: whitespace is not narration" {
    try std.testing.expectEqual(@as(usize, 0), visibleLen("\n \t\r\n"));
    try std.testing.expectEqual(@as(usize, 0), visibleLen(""));
    try std.testing.expectEqual(@as(usize, 5), visibleLen(" hel lo \n"));
}
