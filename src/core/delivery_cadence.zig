//! Delivery-cadence obligation: exploration that never turns into a
//! deliverable.
//!
//! Field evidence (wb-bench-sec vim-tabpanel, 2026-09): 168 tool calls in
//! 1200 s — Read 83 / Bash 54 / Grep 31 — zero Write/Edit, killed by the
//! harness with no report on disk, reward 0. Tool time was 13 s; the rest
//! was inference spent re-opening lines of investigation. The community
//! names this failure class ("analysis paralysis", Cuadron et al. 2025) and
//! converges on one discipline against it: get a first version of the
//! deliverable on disk early and improve it in place (SWE-agent autosubmit,
//! AIxCC "submit as soon as possible", Anthropic's progress-file harness,
//! agenc-core "keep a verified result on disk and improve on a copy").
//!
//! This module is the host-side half of that discipline, shaped like the
//! verification final gate and the requirement ledger — a task-agnostic
//! process obligation, never a verdict:
//!   * sensor (engineering): every executed tool call is classified as
//!     exploration (read-only tools, read-only Bash), neutral (ledger and
//!     memory bookkeeping), or a delivery-capable mutation (file writes,
//!     non-read-only Bash, subagents and, conservatively, any tool this
//!     module does not know). Exploration calls are counted; the first
//!     mutation disarms the gate for the rest of the run.
//!   * policy (proven): at the turn boundary, crossing the first threshold
//!     with no mutation yet earns one bounded nudge, crossing the second
//!     earns a second — never more, never a denial, never once a mutation
//!     was seen. Formal model:
//!     control-plane/lean/MetaCodesControl/DeliveryCadence.lean. Each
//!     theorem names the mirroring test below.
//!   * budget: injections go through the global host-injection meter.
//!
//! What it is not: it does not read the task, does not know any harness
//! deadline, and does not judge the deliverable. The nudge carries only the
//! run's own counter and the anytime instruction. Unknown tools disarm
//! rather than count, so a misclassification can only silence the gate,
//! never fire it wrongly.

const std = @import("std");
const common = @import("../tools/common.zig");
const util_json = @import("../util/json.zig");
const bash_parser = @import("../permission/bash_parser.zig");
const tool_exec = @import("tool_exec.zig");
const verification_progress = @import("verification_progress.zig");

pub const MAX_CADENCE_NUDGES: u8 = 2;

/// Default thresholds in exploration-only tool calls. The vim run above
/// crossed both within its first ten minutes; a run that edits within its
/// first forty calls (the common coding shape) never sees the gate.
pub const DEFAULT_FIRST_THRESHOLD: u32 = 40;
pub const DEFAULT_SECOND_THRESHOLD: u32 = 80;

pub const Thresholds = struct {
    first: u32 = DEFAULT_FIRST_THRESHOLD,
    second: u32 = DEFAULT_SECOND_THRESHOLD,
};

pub const MARKER = "[delivery cadence]";

/// First threshold crossed with no file created or changed. `{d}` = the
/// run's exploration-call count. Task-agnostic: the only variable is the
/// run's own counter; the instruction is the anytime discipline.
pub const FIRST_NUDGE_FMT =
    MARKER ++ "\n" ++
    "You have made {d} tool calls in this run without creating or changing " ++
    "any file. If this task expects a written result (a file, a patch, a " ++
    "report), write its first version now from the evidence you already " ++
    "have, then keep improving it in place: a partial result on disk is " ++
    "worth more than a complete one that is never written. If the task " ++
    "expects only an answer, write your current best answer and its " ++
    "evidence into a notes file or your task ledger before continuing.";

/// Second threshold crossed, still nothing on disk.
pub const SECOND_NUDGE_FMT =
    MARKER ++ "\n" ++
    "{d} tool calls in this run and still no file created or changed. Stop " ++
    "widening the search. Commit to your strongest candidate: write the " ++
    "deliverable now with the evidence you have, mark what remains " ++
    "unverified, and only then continue investigating if anything is left.";

pub const Decision = enum { none, first, second };

/// Sensor classes. `neutral` exists so bookkeeping the host itself asks for
/// (the ledger prompt says TaskCreate) neither counts as exploration nor
/// disarms the gate.
pub const Class = enum { exploration, neutral, mutation };

pub const State = struct {
    /// Exploration-only tool calls observed before the first mutation.
    exploration_calls: u32 = 0,
    /// Sticky: a delivery-capable mutation (or realized file effect) was seen.
    mutation_seen: bool = false,
    /// Thresholds already decided (0..MAX_CADENCE_NUDGES). Observe mode
    /// advances it too, so control arms measure the same crossings.
    level: u8 = 0,
    /// Injections actually made (enforced mode only).
    nudges: u8 = 0,

    /// Pure policy over host-observed counts; mirrors `DeliveryCadence.decide`.
    pub fn decide(self: *const State, thresholds: Thresholds) Decision {
        if (self.mutation_seen) return .none;
        if (self.level == 0 and self.exploration_calls >= thresholds.first) return .first;
        if (self.level == 1 and self.exploration_calls >= thresholds.second) return .second;
        return .none;
    }

    /// Mirrors `DeliveryCadence.step`: a decided threshold is consumed.
    pub fn noteDecided(self: *State) void {
        self.level +|= 1;
    }

    /// Observe one completed tool turn. Denied, deferred and suspended slots
    /// never executed and are skipped.
    pub fn observeSlots(self: *State, allocator: std.mem.Allocator, slots: []const tool_exec.Slot) void {
        for (slots) |slot| {
            if (slot.decision != .run or slot.pending) continue;
            const realized = verification_progress.isRealizedMutation(slot.effect, slot.effect_valid);
            self.observeCall(classify(allocator, slot.name, slot.input), realized);
        }
    }

    pub fn observeCall(self: *State, class: Class, realized_mutation: bool) void {
        if (self.mutation_seen) return;
        if (realized_mutation or class == .mutation) {
            self.mutation_seen = true;
            return;
        }
        if (class == .exploration) self.exploration_calls +|= 1;
    }
};

const EXPLORATION_TOOLS = [_][]const u8{
    "Read",         "Grep",      "Glob",      "CodeMap",             "FindSymbol",
    "ReadArtifact", "WebFetch",  "WebSearch", "ReadMcpResourceTool", "ListMcpResourcesTool",
    "KgRecall",     "KgContext",
};

const NEUTRAL_TOOLS = [_][]const u8{
    "TaskCreate", "TaskUpdate",       "TaskList",        "TaskGet",       "KgRemember",
    "ToolSearch", "BashOutput",       "KillShell",       "TaskOutput",    "TaskStop",
    "Monitor",    "PushNotification", "AskUserQuestion", "EnterPlanMode", "ExitPlanMode",
    "CronCreate", "CronDelete",       "CronList",        "SendMessage",   "FormalAuditTask",
    "Skill",
};

/// Classify one executed tool call. Unknown names (MCP, plugins) are
/// `mutation` on purpose: the safe failure of this sensor is silence.
pub fn classify(allocator: std.mem.Allocator, name: []const u8, input: []const u8) Class {
    if (std.mem.eql(u8, name, "Bash")) return classifyBash(allocator, input);
    for (EXPLORATION_TOOLS) |tool| if (std.mem.eql(u8, name, tool)) return .exploration;
    for (NEUTRAL_TOOLS) |tool| if (std.mem.eql(u8, name, tool)) return .neutral;
    return .mutation;
}

/// A Bash call counts as exploration only when every compound segment is a
/// read-only command with no file redirect and no in-place flag. The
/// permission layer's read-only roster is a "no prompt needed" list, so the
/// extra guards close the holes that matter here (`sed -i`, `find -delete`,
/// `cat a > b`); anything doubtful disarms.
fn classifyBash(allocator: std.mem.Allocator, input: []const u8) Class {
    const encoded = common.extractJsonArg(input, "command") orelse return .mutation;
    const raw = util_json.unescapeString(encoded, allocator) catch return .mutation;
    defer allocator.free(raw);
    // The permission splitter treats a lone `&` as a separator, so `2>&1`
    // would become the segments `cat f 2>` and `1`. Descriptor dups carry no
    // file effect: drop them before splitting.
    const command = stripDescriptorDups(allocator, raw) catch return .mutation;
    defer allocator.free(command);
    const segments = bash_parser.splitCompound(allocator, command) catch return .mutation;
    defer allocator.free(segments);
    if (segments.len == 0) return .neutral;
    for (segments) |segment| {
        const target = bash_parser.stripWrappers(segment);
        if (!bash_parser.isReadonlyCommand(target)) return .mutation;
        if (hasFileRedirect(segment)) return .mutation;
        if (hasInPlaceFlag(target)) return .mutation;
    }
    return .exploration;
}

/// Remove `[N]>&M` and `[N]<&M` descriptor duplications (`2>&1`, `>&2`).
fn stripDescriptorDups(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, command.len);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < command.len) {
        const c = command[i];
        if ((c == '>' or c == '<') and i + 2 < command.len and command[i + 1] == '&' and
            std.ascii.isDigit(command[i + 2]))
        {
            // Drop an optional leading descriptor digit already copied.
            if (out.items.len > 0 and std.ascii.isDigit(out.items[out.items.len - 1]) and
                (out.items.len == 1 or out.items[out.items.len - 2] == ' ' or out.items[out.items.len - 2] == '\t'))
            {
                out.items.len -= 1;
            }
            i += 2;
            while (i < command.len and std.ascii.isDigit(command[i])) : (i += 1) {}
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// `>` or `>>` outside quotes that is not a descriptor dup (`2>&1`) and not
/// a discard to /dev/null.
fn hasFileRedirect(segment: []const u8) bool {
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        const c = segment[i];
        if (c == '\\' and i + 1 < segment.len) {
            i += 1;
            continue;
        }
        if (!in_double and c == '\'') {
            in_single = !in_single;
            continue;
        }
        if (!in_single and c == '"') {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double or c != '>') continue;
        var rest = segment[i + 1 ..];
        if (rest.len > 0 and rest[0] == '>') rest = rest[1..];
        if (rest.len > 0 and rest[0] == '&') continue; // descriptor dup
        const trimmed = std.mem.trimStart(u8, rest, " \t");
        if (std.mem.startsWith(u8, trimmed, "/dev/null")) continue;
        return true;
    }
    return false;
}

/// In-place or destructive flags on commands the read-only roster admits.
fn hasInPlaceFlag(target: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, target, " \t");
    const head = tokens.next() orelse return false;
    if (std.mem.eql(u8, head, "sed")) {
        while (tokens.next()) |tok| {
            if (std.mem.startsWith(u8, tok, "-i") or std.mem.startsWith(u8, tok, "--in-place")) return true;
        }
        return false;
    }
    if (std.mem.eql(u8, head, "find")) {
        while (tokens.next()) |tok| {
            for ([_][]const u8{ "-delete", "-exec", "-execdir", "-ok", "-okdir" }) |flag| {
                if (std.mem.eql(u8, tok, flag)) return true;
            }
        }
        return false;
    }
    return false;
}

test "mutation disarms the cadence gate" {
    // Lean mirror: DeliveryCadence.mutation_disarms.
    var state = State{ .exploration_calls = 500, .mutation_seen = true };
    try std.testing.expectEqual(Decision.none, state.decide(.{ .first = 1, .second = 2 }));
    // Once seen, later exploration is neither counted nor able to re-arm.
    state.observeCall(.exploration, false);
    try std.testing.expectEqual(@as(u32, 500), state.exploration_calls);
    try std.testing.expectEqual(Decision.none, state.decide(.{ .first = 1, .second = 2 }));
    // A realized file effect disarms even when the name says exploration.
    var effect = State{};
    effect.observeCall(.exploration, true);
    try std.testing.expect(effect.mutation_seen);
}

test "below the first threshold nothing fires" {
    // Lean mirror: DeliveryCadence.pristine_never_nudged.
    var state = State{};
    const thresholds = Thresholds{ .first = 3, .second = 6 };
    try std.testing.expectEqual(Decision.none, state.decide(thresholds));
    state.observeCall(.exploration, false);
    state.observeCall(.neutral, false);
    state.observeCall(.exploration, false);
    try std.testing.expectEqual(@as(u32, 2), state.exploration_calls);
    try std.testing.expectEqual(Decision.none, state.decide(thresholds));
}

test "levels fire in order, at most once each, never past the budget" {
    // Lean mirror: DeliveryCadence.first_requires_threshold /
    // second_requires_first_fired / level_bounded.
    var state = State{};
    const thresholds = Thresholds{ .first = 2, .second = 4 };
    var i: usize = 0;
    while (i < 10) : (i += 1) state.observeCall(.exploration, false);
    // Far past both thresholds: the first level must still come first.
    try std.testing.expectEqual(Decision.first, state.decide(thresholds));
    state.noteDecided();
    try std.testing.expectEqual(Decision.second, state.decide(thresholds));
    state.noteDecided();
    try std.testing.expectEqual(Decision.none, state.decide(thresholds));
    state.noteDecided();
    try std.testing.expectEqual(Decision.none, state.decide(thresholds));
    try std.testing.expect(state.level <= MAX_CADENCE_NUDGES + 1);
    // Between the thresholds the second level waits for the counter.
    var waiting = State{ .level = 1, .exploration_calls = 3 };
    try std.testing.expectEqual(Decision.none, waiting.decide(thresholds));
    waiting.observeCall(.exploration, false);
    try std.testing.expectEqual(Decision.second, waiting.decide(thresholds));
}

test "classifier: read-only tools and read-only bash are exploration, bookkeeping is neutral, everything else disarms" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(Class.exploration, classify(a, "Read", "{\"file_path\":\"x\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Grep", "{}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"ls -la && git status\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"timeout 5 grep -rn foo src | head\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"ls 2>/dev/null\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"cat a.txt 2>&1\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"ls >&2\"}"));
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"grep -rn foo . 2>&1 | head -20\"}"));
    try std.testing.expectEqual(Class.neutral, classify(a, "TaskCreate", "{}"));
    try std.testing.expectEqual(Class.neutral, classify(a, "KgRemember", "{}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Write", "{}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Edit", "{}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Task", "{}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "mcp__srv__search", "{}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"ls && rm -rf build\"}"));
    // `echo` is on the permission layer's read-only roster and mutates
    // nothing; a fresh file is the mutation shape.
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"echo hi\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"touch notes.md\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"mkdir -p out\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{}"));
}

test "bash redirects and in-place flags disarm" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"cat a.txt > b.txt\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"ls >> log.txt\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"sed -i 's/a/b/' f.c\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"find . -name '*.o' -delete\"}"));
    try std.testing.expectEqual(Class.mutation, classify(a, "Bash", "{\"command\":\"find . -name x -exec rm {} +\"}"));
    // A quoted `>` is data, not a redirect.
    try std.testing.expectEqual(Class.exploration, classify(a, "Bash", "{\"command\":\"grep -n '>' f.c\"}"));
}

test "nudge texts carry only the counter and the anytime instruction" {
    const a = std.testing.allocator;
    const first = try std.fmt.allocPrint(a, FIRST_NUDGE_FMT, .{@as(u32, 40)});
    defer a.free(first);
    const second = try std.fmt.allocPrint(a, SECOND_NUDGE_FMT, .{@as(u32, 80)});
    defer a.free(second);
    for ([_][]const u8{ first, second }) |text| {
        try std.testing.expect(std.mem.startsWith(u8, text, MARKER));
        // No benchmark, verifier or grading vocabulary may ever enter a nudge.
        for ([_][]const u8{ "verifier", "reward", "score", "grade", "benchmark", "deadline", "timeout" }) |banned| {
            try std.testing.expect(std.mem.indexOf(u8, text, banned) == null);
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, first, "40 tool calls") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "80 tool calls") != null);
}
