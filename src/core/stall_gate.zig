//! Stall gate: in-run zero-information-gain breaker.
//!
//! The kernel bounds a run's safety and resources, but until this gate it had
//! no notion of progress: `max_turns` was the only behavioural backstop. Runs
//! on long-context, flash-class models do not loop by sending malformed calls.
//! They loop by taking steps that return nothing new, such as polling a job
//! that prints nothing, re-running a command and getting identical output, or
//! re-reading something that has not changed. Soft reminders are ignored
//! there: 76% of `[progress update]` nudges went unanswered at 400K–850K
//! context. So this gate does not remind. It stops the run and hands the
//! decision back to the person (design note: doc/STALL_GATE_DESIGN.md).
//!
//!   * sensor: once per executed tool round. Every slot that ran yields a call
//!     key `H(tool, input)` and, unless it failed, an evidence key. A realized
//!     file change is keyed by its action, `H(tool, input)`. Anything else is
//!     keyed by what came back, `H(tool, result)`, with host-timing fields
//!     such as BashOutput's `waited_ms` left out. The round is *progress* when
//!     some evidence key is not in the gate's memory, *stale* when something
//!     ran but nothing is new, and *neutral* when nothing ran (denied,
//!     deferred, suspended). The memory follows what the model can still see.
//!     Each key is anchored to the newest tool_result block that carried it,
//!     and is forgotten once that block leaves the view: compaction moves the
//!     window, or microcompaction or truncation rewrites the block in place.
//!     Forgetting only ever makes a key look new again.
//!   * policy (`State.decide`, Lean `decide`): a run of `stale_rounds`
//!     consecutive stale rounds stops it. So does a shorter run of
//!     `repeat_rounds`, if within it one identical call was made at least
//!     `repeat_calls` times. A progress round resets the stretch, and
//!     `stale_rounds == 0` never fires whatever the thresholds are. At most
//!     `MAX_STALL_DECISIONS` decisions are made per run.
//!   * actuation: enforce mode ends the run with `StopReason.stalled` after the
//!     round's results are committed, so a resumed run sees the evidence. No
//!     text is injected and provider-visible bytes are unchanged. The REPL
//!     prints `renderStopNotice`. Observe mode records the round where an
//!     enforced run would have stopped and changes nothing.
//!   * hosts opt in: `agent_loop.Options.stall_gate` is a host-contract field
//!     like the sibling gates. Interactive hosts enforce by default because a
//!     person can resume. Headless runs, macro runs and embedders leave it
//!     off.
//!
//! What it is not: hash novelty is syntactic. Outputs that differ only by a
//! timestamp, or a job that prints one progress byte per poll, are new results
//! to this gate. Semantic stagnation needs a relation judge, not a hash.
//!
//! Lean mirror: control-plane/lean/MetaCodesControl/StallGate.lean proves
//! `decisions_bounded`, `fresh_rounds_never_fire`, `new_rounds_never_fire`
//! and `stale_stretch_fires`. `maxDecisions`, the default thresholds and the
//! stretch capacity are lockstep-checked against this file by
//! scripts/eval/tests/test_delivery_cadence_constants.py.

const std = @import("std");
const msg = @import("message.zig");
const tool_exec = @import("tool_exec.zig");
const verification_progress = @import("verification_progress.zig");
const delivery_cadence = @import("delivery_cadence.zig");

/// Per-run bound on decisions. Enforce mode stops at the first one; observe
/// mode records only the first, which is the one that would have stopped the
/// run. Lean mirror: `maxDecisions`.
pub const MAX_STALL_DECISIONS: u8 = 1;

/// Stale rounds required by the repeat tier. With `DEFAULT_REPEAT_CALLS` this
/// means one identical call has returned an already-seen answer four rounds in
/// a row, i.e. five identical calls counting the novel first one. A job that
/// must be waited on has `wait_ms` (up to 600 s), and ending the turn lets a
/// job notification wake the run.
pub const DEFAULT_REPEAT_ROUNDS: u32 = 4;
/// Occurrences of one identical call within the stale stretch for the repeat
/// tier.
pub const DEFAULT_REPEAT_CALLS: u32 = 4;
/// Stale rounds that stop the run on their own: eight rounds in which
/// everything that came back had already been seen, or failed.
pub const DEFAULT_STALE_ROUNDS: u32 = 8;

/// Evidence keys remembered at once, least recently touched evicted first.
/// Eviction only forgets, so it errs toward silence.
pub const SEEN_CAPACITY: usize = 512;
/// Calls remembered in the current stale stretch (oldest dropped first). Only
/// the repeat count reads it, so the bound can only lower that count. Lean
/// mirror: `stretchCap`.
pub const STRETCH_CAPACITY: usize = 32;
pub const MAX_TOOL_NAME_BYTES: usize = 64;

pub const Mode = enum { enforce, observe };

/// Host configuration as the CLI spells it. `host_default` enforces where a
/// person can resume the run and is off where nobody can.
pub const Setting = enum { host_default, enforce, observe, off };
pub const Host = enum { interactive, headless };

pub fn modeFor(setting: Setting, host: Host) ?Mode {
    return switch (setting) {
        .host_default => switch (host) {
            .interactive => .enforce,
            // Evaluation rollouts run headless and their stop-reason sets are
            // fixed; a person opts in with --stall-gate.
            .headless => null,
        },
        .enforce => .enforce,
        .observe => .observe,
        .off => null,
    };
}

pub const Thresholds = struct {
    repeat_rounds: u32 = DEFAULT_REPEAT_ROUNDS,
    repeat_calls: u32 = DEFAULT_REPEAT_CALLS,
    stale_rounds: u32 = DEFAULT_STALE_ROUNDS,
};

pub const Cause = enum { repeating, stale };
pub const Tag = enum { progress, stale, neutral };

pub const Key = u64;

/// Domain separation: a call, an action and an observation with the same
/// bytes are different facts.
const CALL_DOMAIN = "C";
const ACTION_DOMAIN = "A";
const OBSERVATION_DOMAIN = "O";

/// Result fields that report the host's own timing rather than anything about
/// the world. BashOutput's long-poll reports how long it waited, so without
/// this every poll of a silent job would hash differently and the gate could
/// never see a stuck poll.
const HOST_TIMING_FIELDS = [_][]const u8{"\"waited_ms\":"};

fn keyed(domain: []const u8, name: []const u8) std.hash.Wyhash {
    var h = std.hash.Wyhash.init(0);
    h.update(domain);
    h.update(name);
    h.update(&.{0});
    return h;
}

pub fn callKey(name: []const u8, input: []const u8) Key {
    var h = keyed(CALL_DOMAIN, name);
    h.update(input);
    return h.final();
}

/// A realized change is identified by what was done: its acknowledgement
/// carries nothing the model did not choose, and two different edits can
/// return byte-identical acknowledgements.
pub fn actionKey(name: []const u8, input: []const u8) Key {
    var h = keyed(ACTION_DOMAIN, name);
    h.update(input);
    return h.final();
}

pub fn observationKey(name: []const u8, content: []const u8) Key {
    var h = keyed(OBSERVATION_DOMAIN, name);
    var rest = content;
    while (rest.len > 0) {
        var at: ?usize = null;
        var field_len: usize = 0;
        for (HOST_TIMING_FIELDS) |field| {
            const found = std.mem.indexOf(u8, rest, field) orelse continue;
            if (at == null or found < at.?) {
                at = found;
                field_len = field.len;
            }
        }
        const start = at orelse {
            h.update(rest);
            break;
        };
        // Keep the field name, drop its digits.
        var end = start + field_len;
        while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
        h.update(rest[0 .. start + field_len]);
        rest = rest[end..];
    }
    return h.final();
}

/// One counted slot as the policy sees it (Lean `Slot`).
pub const Reading = struct {
    call: Key,
    /// null: the call failed. There is no non-error result to count.
    evidence: ?Key,
    /// Borrowed; copied into the stretch for the report.
    name: []const u8,
};

/// The sensor's view of one executed slot; null when it never ran. Same
/// "started" rule as the delivery-cadence and check-gate sensors.
pub fn readSlot(slot: *const tool_exec.Slot) ?Reading {
    if (slot.decision != .run or slot.pending) return null;
    const realized = verification_progress.isRealizedMutation(slot.effect, slot.effect_valid) or
        delivery_cadence.State.fileChangesRealized(slot.*);
    const call = callKey(slot.name, slot.input);
    // A realized change counts by its action even when the tool also reported
    // an error (a partial apply): the world did change.
    if (realized) return .{ .call = call, .evidence = actionKey(slot.name, slot.input), .name = slot.name };
    const content = slot.content orelse return null;
    if (slot.is_error) return .{ .call = call, .evidence = null, .name = slot.name };
    return .{ .call = call, .evidence = observationKey(slot.name, content), .name = slot.name };
}

pub const ToolName = struct {
    bytes: [MAX_TOOL_NAME_BYTES]u8 = [_]u8{0} ** MAX_TOOL_NAME_BYTES,
    len: u8 = 0,

    pub fn of(name: []const u8) ToolName {
        const n = @min(name.len, MAX_TOOL_NAME_BYTES);
        var out = ToolName{ .len = @intCast(n) };
        @memcpy(out.bytes[0..n], name[0..n]);
        return out;
    }

    pub fn slice(self: *const ToolName) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Where a key's newest evidence sits in the conversation. The block is still
/// in view while the same bytes are there: a cleared or truncated result is a
/// new slice.
const Anchor = struct {
    message: usize,
    block: usize,
    ptr: usize,
    len: usize,
};

const Entry = struct {
    key: Key,
    /// Recency stamp for eviction.
    touched: u64,
    /// Set when this round touched the key; the block is that slot's result.
    pending_slot: ?usize = null,
    anchor: ?Anchor = null,
};

/// Evidence keys the model can still see.
const Memory = struct {
    entries: [SEEN_CAPACITY]Entry = undefined,
    len: usize = 0,
    clock: u64 = 0,

    fn find(self: *Memory, key: Key) ?*Entry {
        for (self.entries[0..self.len]) |*entry| {
            if (entry.key == key) return entry;
        }
        return null;
    }

    pub fn contains(self: *const Memory, key: Key) bool {
        for (self.entries[0..self.len]) |entry| {
            if (entry.key == key) return true;
        }
        return false;
    }

    /// Record `key` as the evidence of slot `slot` in this round. A hit
    /// refreshes it; a miss admits it, evicting the least recently touched
    /// entry when full. Returns true when the key was new.
    fn touch(self: *Memory, key: Key, slot: usize) bool {
        self.clock += 1;
        if (self.find(key)) |entry| {
            entry.touched = self.clock;
            entry.pending_slot = slot;
            return false;
        }
        const index = if (self.len < SEEN_CAPACITY) blk: {
            self.len += 1;
            break :blk self.len - 1;
        } else blk: {
            var oldest: usize = 0;
            for (self.entries[0..self.len], 0..) |entry, i| {
                if (entry.touched < self.entries[oldest].touched) oldest = i;
            }
            break :blk oldest;
        };
        self.entries[index] = .{ .key = key, .touched = self.clock, .pending_slot = slot };
        return true;
    }

    fn remove(self: *Memory, index: usize) void {
        self.len -= 1;
        self.entries[index] = self.entries[self.len];
    }

    /// The round's results were appended as the last message, one
    /// tool_result block per slot in slot order. Anchor every key this round
    /// touched to its block, and forget any that has none.
    fn anchorRound(self: *Memory, messages: []const msg.Message) u32 {
        var forgotten: u32 = 0;
        var i: usize = 0;
        while (i < self.len) {
            const entry = &self.entries[i];
            const slot = entry.pending_slot orelse {
                i += 1;
                continue;
            };
            entry.pending_slot = null;
            if (messages.len > 0) {
                const last = messages.len - 1;
                if (slot < messages[last].blocks.len) switch (messages[last].blocks[slot]) {
                    .tool_result => |result| {
                        entry.anchor = .{ .message = last, .block = slot, .ptr = @intFromPtr(result.content.ptr), .len = result.content.len };
                        i += 1;
                        continue;
                    },
                    else => {},
                };
            }
            self.remove(i);
            forgotten += 1;
        }
        return forgotten;
    }

    /// Forget every key whose newest evidence is no longer in the model's
    /// view: the block fell behind the compaction boundary, the message is
    /// gone, or the block's bytes were replaced (cleared or truncated).
    fn forgetInvisible(self: *Memory, messages: []const msg.Message, active_start: usize) u32 {
        var forgotten: u32 = 0;
        var i: usize = 0;
        while (i < self.len) {
            if (visible(self.entries[i].anchor, messages, active_start)) {
                i += 1;
            } else {
                self.remove(i);
                forgotten += 1;
            }
        }
        return forgotten;
    }

    fn visible(anchor: ?Anchor, messages: []const msg.Message, active_start: usize) bool {
        const a = anchor orelse return false;
        if (a.message < active_start or a.message >= messages.len) return false;
        const blocks = messages[a.message].blocks;
        if (a.block >= blocks.len) return false;
        return switch (blocks[a.block]) {
            .tool_result => |result| @intFromPtr(result.content.ptr) == a.ptr and result.content.len == a.len,
            else => false,
        };
    }
};

const StretchEntry = struct { call: Key, name: ToolName };

/// Calls of the current stale stretch, oldest dropped first.
const Stretch = struct {
    entries: [STRETCH_CAPACITY]StretchEntry = undefined,
    len: usize = 0,
    next: usize = 0,

    fn push(self: *Stretch, call: Key, name: []const u8) void {
        self.entries[self.next] = .{ .call = call, .name = ToolName.of(name) };
        self.next = (self.next + 1) % STRETCH_CAPACITY;
        if (self.len < STRETCH_CAPACITY) self.len += 1;
    }

    fn clear(self: *Stretch) void {
        self.len = 0;
        self.next = 0;
    }

    const Top = struct { count: u32, name: ToolName };

    /// The most frequent identical call and how often it occurs (Lean
    /// `maxRepeat`).
    fn mostRepeated(self: *const Stretch) Top {
        var top = Top{ .count = 0, .name = .{} };
        for (self.entries[0..self.len], 0..) |entry, i| {
            var count: u32 = 0;
            for (self.entries[0..self.len]) |other| {
                if (other.call == entry.call) count += 1;
            }
            if (count > top.count) top = .{ .count = count, .name = self.entries[i].name };
        }
        return top;
    }
};

/// What a decision saw, carried out of the run (`RunResult.stall`) for the
/// host to show. Value type: it outlives the conversation's borrowed names.
pub const Report = struct {
    cause: Cause,
    /// Consecutive stale rounds at the decision.
    stale_rounds: u32,
    /// The most repeated identical call in the stretch and its count.
    tool: ToolName,
    repeats: u32,
    /// Counted tool rounds observed when the gate decided (1-based).
    round: u32,
};

const RoundScan = struct { counted: bool = false, novel: bool = false };

pub const State = struct {
    memory: Memory = .{},
    stretch: Stretch = .{},
    /// Consecutive stale rounds (0 after any progress round).
    stale_rounds: u32 = 0,
    /// 0..MAX_STALL_DECISIONS.
    decisions: u8 = 0,
    /// Terminal record.
    rounds: u32 = 0,
    progress_rounds: u32 = 0,
    max_stale_rounds: u32 = 0,
    max_repeats: u32 = 0,
    /// Keys dropped because their evidence left the model's view.
    forgotten: u32 = 0,
    decided: ?Report = null,

    /// Forget keys whose evidence the model can no longer see. Call it before
    /// observing a round; messages are the conversation's, read in place.
    pub fn forgetInvisible(self: *State, messages: []const msg.Message, active_start: usize) void {
        self.forgotten +|= self.memory.forgetInvisible(messages, active_start);
    }

    /// Observe one executed batch (before its content moves into the
    /// conversation). Lean mirror: `observe`.
    pub fn observeSlots(self: *State, slots: []const tool_exec.Slot) Tag {
        var scan = RoundScan{};
        for (slots, 0..) |*slot, index| {
            if (readSlot(slot)) |reading| self.scanOne(&scan, reading, index);
        }
        return self.closeRound(scan);
    }

    /// Same, over readings already taken: reading `i` is slot `i`.
    pub fn observeReadings(self: *State, readings: []const Reading) Tag {
        var scan = RoundScan{};
        for (readings, 0..) |reading, index| self.scanOne(&scan, reading, index);
        return self.closeRound(scan);
    }

    fn scanOne(self: *State, scan: *RoundScan, reading: Reading, slot: usize) void {
        scan.counted = true;
        self.stretch.push(reading.call, reading.name);
        if (reading.evidence) |key| {
            if (self.memory.touch(key, slot)) scan.novel = true;
        }
    }

    fn closeRound(self: *State, scan: RoundScan) Tag {
        if (!scan.counted) return .neutral;
        self.rounds +|= 1;
        if (scan.novel) {
            self.progress_rounds +|= 1;
            self.stale_rounds = 0;
            self.stretch.clear();
            return .progress;
        }
        self.stale_rounds +|= 1;
        self.max_stale_rounds = @max(self.max_stale_rounds, self.stale_rounds);
        self.max_repeats = @max(self.max_repeats, self.stretch.mostRepeated().count);
        return .stale;
    }

    /// The round's results were committed as the conversation's last message:
    /// anchor this round's keys to their blocks.
    pub fn anchorRound(self: *State, messages: []const msg.Message) void {
        self.forgotten +|= self.memory.anchorRound(messages);
    }

    /// Pure policy over the observed stretch. Lean mirror: `decide`.
    pub fn decide(self: *const State, thresholds: Thresholds) ?Cause {
        if (self.decisions >= MAX_STALL_DECISIONS) return null;
        if (self.stale_rounds == 0) return null;
        if (self.stale_rounds >= thresholds.repeat_rounds and
            self.stretch.mostRepeated().count >= thresholds.repeat_calls) return .repeating;
        if (self.stale_rounds >= thresholds.stale_rounds) return .stale;
        return null;
    }

    /// Count the decision and keep what it saw. Lean mirror: `step`.
    pub fn noteDecided(self: *State, cause: Cause) Report {
        self.decisions +|= 1;
        const top = self.stretch.mostRepeated();
        const report = Report{
            .cause = cause,
            .stale_rounds = self.stale_rounds,
            .tool = top.name,
            .repeats = top.count,
            .round = self.rounds,
        };
        self.decided = report;
        return report;
    }
};

/// What the REPL prints after a stalled stop. It names the cause, the
/// evidence and how to continue. The conversation is intact, so the person's
/// next message resumes it.
pub fn renderStopNotice(allocator: std.mem.Allocator, report: Report) ![]u8 {
    return switch (report.cause) {
        .repeating => std.fmt.allocPrint(
            allocator,
            "运行已停止(stalled):连续 {d} 轮工具调用没有带回任何新结果,其中 {s} 以完全相同的输入调用了 {d} 次。" ++
                "看起来在原地打转(轮询没有变化的作业 / 反复执行同一命令)。\n" ++
                "直接输入下一步续接:换个方向,或说明要它继续等(长等待用 BashOutput 的 wait_ms,或结束本轮等作业通知)。",
            .{ report.stale_rounds, report.tool.slice(), report.repeats },
        ),
        .stale => std.fmt.allocPrint(
            allocator,
            "运行已停止(stalled):连续 {d} 轮工具调用没有带回任何新结果(返回的都是已经看过的输出,或调用失败)。" ++
                "看起来在原地打转。\n直接输入下一步续接:换个方向,或给它新的线索。",
            .{report.stale_rounds},
        ),
    };
}

// ── Tests: synthetic traces only ──────────────────────────────────────────

const testing = std.testing;

fn obs(name: []const u8, input: []const u8, result: []const u8) Reading {
    return .{ .call = callKey(name, input), .evidence = observationKey(name, result), .name = name };
}

fn failed(name: []const u8, input: []const u8) Reading {
    return .{ .call = callKey(name, input), .evidence = null, .name = name };
}

fn act(name: []const u8, input: []const u8) Reading {
    return .{ .call = callKey(name, input), .evidence = actionKey(name, input), .name = name };
}

/// Feed `rounds` rounds of the same readings and let the policy step after
/// each, as the agent loop does. Returns the round (1-based) of the first
/// decision, or null.
fn drive(s: *State, t: Thresholds, round: []const Reading, rounds: usize) ?usize {
    var first: ?usize = null;
    for (0..rounds) |i| {
        _ = s.observeReadings(round);
        if (s.decide(t)) |cause| {
            _ = s.noteDecided(cause);
            if (first == null) first = i + 1;
        }
    }
    return first;
}

test "repeating trace: the same poll returning the same snapshot fires the repeat tier exactly once" {
    var s = State{};
    const poll = obs("BashOutput", "{\"job_id\":\"j1\"}", "{\"status\":\"running\",\"stdout\":\"\",\"waited_ms\":30001}");
    // Round 1 is novel; rounds 2..5 are stale with 1..4 identical calls.
    const first = drive(&s, .{}, &.{poll}, 20);
    try testing.expectEqual(@as(?usize, 5), first);
    try testing.expectEqual(@as(u8, 1), s.decisions);
    try testing.expectEqual(Cause.repeating, s.decided.?.cause);
    try testing.expectEqualStrings("BashOutput", s.decided.?.tool.slice());
    try testing.expectEqual(@as(u32, 4), s.decided.?.repeats);
    try testing.expectEqual(@as(u32, 4), s.decided.?.stale_rounds);
    // Bounded: twenty rounds of the same loop still decided once.
    try testing.expectEqual(MAX_STALL_DECISIONS, s.decisions);
}

test "host timing is not information: polls differing only in waited_ms are the same answer" {
    try testing.expectEqual(
        observationKey("BashOutput", "{\"status\":\"running\",\"waited_ms\":30001,\"x\":1}"),
        observationKey("BashOutput", "{\"status\":\"running\",\"waited_ms\":29998,\"x\":1}"),
    );
    // Anything else that changes is information.
    try testing.expect(observationKey("BashOutput", "{\"status\":\"running\",\"waited_ms\":1}") !=
        observationKey("BashOutput", "{\"status\":\"exited\",\"waited_ms\":1}"));
    try testing.expect(observationKey("BashOutput", "{\"stdout\":\"a\",\"waited_ms\":1}") !=
        observationKey("BashOutput", "{\"stdout\":\"ab\",\"waited_ms\":1}"));
    // The same bytes from another tool are another fact.
    try testing.expect(observationKey("Read", "x") != observationKey("Grep", "x"));
    try testing.expect(observationKey("Read", "x") != actionKey("Read", "x"));
}

test "stale trace: varied calls that only return seen answers fire the stale tier" {
    var s = State{};
    const a = obs("Read", "{\"file_path\":\"a\"}", "A");
    const b = obs("Read", "{\"file_path\":\"b\"}", "B");
    _ = s.observeReadings(&.{ a, b });
    try testing.expectEqual(@as(?Cause, null), s.decide(.{}));
    // Different inputs each round (no call repeats 4 times), same answers.
    var i: u32 = 0;
    while (i < DEFAULT_STALE_ROUNDS - 1) : (i += 1) {
        var input_buf: [32]u8 = undefined;
        const input = try std.fmt.bufPrint(&input_buf, "{{\"pattern\":\"p{d}\"}}", .{i});
        const r = Reading{ .call = callKey("Grep", input), .evidence = observationKey("Read", "A"), .name = "Grep" };
        try testing.expectEqual(Tag.stale, s.observeReadings(&.{r}));
        try testing.expectEqual(@as(?Cause, null), s.decide(.{}));
    }
    // A failure is not a new result either.
    try testing.expectEqual(Tag.stale, s.observeReadings(&.{failed("Edit", "{\"x\":1}")}));
    try testing.expectEqual(@as(?Cause, .stale), s.decide(.{}));
}

test "progressing trace: a round with one new result never fires, however repetitive the rest" {
    var s = State{};
    const poll = obs("BashOutput", "{\"job_id\":\"j1\"}", "{\"status\":\"running\"}");
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        // The same stale poll three times per round, plus one read that returns
        // something never seen before (a job whose log grows).
        var buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "line {d}", .{i});
        const tag = s.observeReadings(&.{ poll, poll, poll, obs("Read", "{\"file_path\":\"log\"}", line) });
        try testing.expectEqual(Tag.progress, tag);
        try testing.expectEqual(@as(?Cause, null), s.decide(.{ .repeat_rounds = 1, .repeat_calls = 1, .stale_rounds = 1 }));
    }
    try testing.expectEqual(@as(u8, 0), s.decisions);
    try testing.expectEqual(@as(u32, 0), s.max_stale_rounds);
}

test "progressing trace: TDD (same test command, new output after each edit) and distinct edits never fire" {
    var s = State{};
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        var edit_buf: [48]u8 = undefined;
        var out_buf: [48]u8 = undefined;
        const edit = try std.fmt.bufPrint(&edit_buf, "{{\"old\":\"v{d}\",\"new\":\"v{d}\"}}", .{ i, i + 1 });
        // A passing suite prints the same line every time; the edits are the news.
        try testing.expectEqual(Tag.progress, s.observeReadings(&.{ act("Edit", edit), obs("Bash", "{\"command\":\"zig build test\"}", "All 42 tests passed.") }));
        try testing.expectEqual(@as(?Cause, null), s.decide(.{}));
        // And a failing suite whose output changes is news on its own.
        const out = try std.fmt.bufPrint(&out_buf, "1 failed: expected {d}", .{i});
        try testing.expectEqual(Tag.progress, s.observeReadings(&.{obs("Bash", "{\"command\":\"zig build test\"}", out)}));
    }
    try testing.expectEqual(@as(u8, 0), s.decisions);
}

test "neutral rounds (nothing ran) neither reset nor lengthen the stretch" {
    var s = State{};
    const poll = obs("BashOutput", "{\"job_id\":\"j1\"}", "same");
    _ = s.observeReadings(&.{poll});
    _ = s.observeReadings(&.{poll});
    try testing.expectEqual(@as(u32, 1), s.stale_rounds);
    try testing.expectEqual(Tag.neutral, s.observeReadings(&.{}));
    try testing.expectEqual(@as(u32, 1), s.stale_rounds);
    try testing.expectEqual(@as(u32, 2), s.rounds);
}

test "policy: zero stale rounds never fires for any thresholds; each tier needs its own condition" {
    var s = State{};
    try testing.expectEqual(@as(?Cause, null), s.decide(.{ .repeat_rounds = 0, .repeat_calls = 0, .stale_rounds = 0 }));
    const poll = obs("BashOutput", "{\"job_id\":\"j1\"}", "same");
    _ = s.observeReadings(&.{poll}); // novel
    _ = s.observeReadings(&.{poll}); // stale 1, one call in the stretch
    try testing.expectEqual(@as(?Cause, .repeating), s.decide(.{ .repeat_rounds = 1, .repeat_calls = 1, .stale_rounds = 9 }));
    try testing.expectEqual(@as(?Cause, null), s.decide(.{ .repeat_rounds = 1, .repeat_calls = 2, .stale_rounds = 9 }));
    try testing.expectEqual(@as(?Cause, null), s.decide(.{ .repeat_rounds = 2, .repeat_calls = 1, .stale_rounds = 9 }));
    try testing.expectEqual(@as(?Cause, .stale), s.decide(.{ .repeat_rounds = 2, .repeat_calls = 9, .stale_rounds = 1 }));
    _ = s.noteDecided(.stale);
    try testing.expectEqual(@as(?Cause, null), s.decide(.{ .repeat_rounds = 0, .repeat_calls = 0, .stale_rounds = 0 }));
}

fn toolResultMessage(blocks: []msg.Block) msg.Message {
    return .{ .role = .user, .blocks = blocks };
}

test "memory follows the view: a result cleared out of the context may be fetched again as news" {
    var s = State{};
    const read = obs("Read", "{\"file_path\":\"a\"}", "A");
    try testing.expectEqual(Tag.progress, s.observeReadings(&.{read}));
    var original = [_]u8{ 'A', 'A' };
    var blocks = [_]msg.Block{.{ .tool_result = .{ .tool_use_id = "t1", .content = &original } }};
    var messages = [_]msg.Message{toolResultMessage(&blocks)};
    s.anchorRound(&messages);
    // Still in view: the same answer is stale.
    s.forgetInvisible(&messages, 0);
    try testing.expectEqual(Tag.stale, s.observeReadings(&.{read}));
    s.anchorRound(&messages);
    // Microcompaction rewrites the block in place: the model no longer sees it.
    const stub = "[cleared]";
    blocks[0].tool_result.content = stub;
    s.forgetInvisible(&messages, 0);
    try testing.expectEqual(@as(u32, 1), s.forgotten);
    try testing.expectEqual(Tag.progress, s.observeReadings(&.{read}));
    try testing.expectEqual(@as(u32, 0), s.stale_rounds);
    // Compaction moves the window past it: forgotten again.
    s.anchorRound(&messages);
    s.forgetInvisible(&messages, 1);
    try testing.expectEqual(Tag.progress, s.observeReadings(&.{read}));
}

test "memory follows the view: a loop whose newest copy stays visible is still stale under microcompaction" {
    var s = State{};
    const poll = obs("BashOutput", "{\"job_id\":\"j1\"}", "same");
    var contents: [8][4]u8 = undefined;
    var blocks: [8][1]msg.Block = undefined;
    var messages: [8]msg.Message = undefined;
    var first: ?usize = null;
    for (0..8) |round| {
        _ = s.observeReadings(&.{poll});
        contents[round] = .{ 's', 'a', 'm', 'e' };
        blocks[round][0] = .{ .tool_result = .{ .tool_use_id = "t", .content = &contents[round] } };
        messages[round] = toolResultMessage(&blocks[round]);
        s.anchorRound(messages[0 .. round + 1]);
        if (first == null) if (s.decide(.{})) |cause| {
            _ = s.noteDecided(cause);
            first = round + 1;
        };
        // Keep only the newest result intact, as microcompaction does at the
        // top of the context window.
        if (round > 0) blocks[round - 1][0].tool_result.content = "[cleared]";
        s.forgetInvisible(messages[0 .. round + 1], 0);
    }
    try testing.expectEqual(@as(?usize, 5), first);
}

test "memory: a key with no block in the committed message is forgotten (errs toward silence)" {
    var s = State{};
    _ = s.observeReadings(&.{ obs("Read", "a", "A"), obs("Read", "b", "B") });
    var content = [_]u8{'A'};
    var blocks = [_]msg.Block{.{ .tool_result = .{ .tool_use_id = "t1", .content = &content } }};
    var messages = [_]msg.Message{toolResultMessage(&blocks)};
    s.anchorRound(&messages); // slot 1 has no block
    try testing.expectEqual(@as(u32, 1), s.forgotten);
    try testing.expectEqual(Tag.progress, s.observeReadings(&.{ obs("Read", "a", "A"), obs("Read", "b", "B") }));
}

test "memory: eviction past capacity only forgets the least recently touched key" {
    var m = Memory{};
    var i: u64 = 0;
    while (i < SEEN_CAPACITY) : (i += 1) try testing.expect(m.touch(i, 0));
    try testing.expect(!m.touch(0, 0)); // refresh key 0
    try testing.expect(m.touch(SEEN_CAPACITY, 0)); // evicts key 1, the oldest untouched
    try testing.expect(m.contains(0));
    try testing.expect(!m.contains(1));
    try testing.expectEqual(SEEN_CAPACITY, m.len);
}

test "stretch: bounded window, most repeated call" {
    var st = Stretch{};
    var i: u64 = 0;
    while (i < STRETCH_CAPACITY + 5) : (i += 1) st.push(i % 3, "T");
    try testing.expectEqual(STRETCH_CAPACITY, st.len);
    const top = st.mostRepeated();
    try testing.expect(top.count >= STRETCH_CAPACITY / 3);
    try testing.expectEqualStrings("T", top.name.slice());
    st.clear();
    try testing.expectEqual(@as(u32, 0), st.mostRepeated().count);
}

test "modeFor: interactive hosts enforce by default, headless only on request" {
    try testing.expectEqual(@as(?Mode, .enforce), modeFor(.host_default, .interactive));
    try testing.expectEqual(@as(?Mode, null), modeFor(.host_default, .headless));
    try testing.expectEqual(@as(?Mode, .enforce), modeFor(.enforce, .headless));
    try testing.expectEqual(@as(?Mode, .observe), modeFor(.observe, .interactive));
    try testing.expectEqual(@as(?Mode, null), modeFor(.off, .interactive));
}

test "renderStopNotice names the cause, the evidence and how to continue" {
    const report = Report{ .cause = .repeating, .stale_rounds = 4, .tool = ToolName.of("BashOutput"), .repeats = 4, .round = 5 };
    const text = try renderStopNotice(testing.allocator, report);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "stalled") != null);
    try testing.expect(std.mem.indexOf(u8, text, "BashOutput") != null);
    try testing.expect(std.mem.indexOf(u8, text, "4 次") != null);
    const stale = try renderStopNotice(testing.allocator, .{ .cause = .stale, .stale_rounds = 8, .tool = .{}, .repeats = 1, .round = 9 });
    defer testing.allocator.free(stale);
    try testing.expect(std.mem.indexOf(u8, stale, "8 轮") != null);
}
