//! Host check gate: outcome-guided continuation.
//!
//! When the model ends its turn after a delivery-capable action, the host runs
//! the check command pinned at startup (`--host-check <cmd>`) itself. The model
//! cannot rewrite the command and does not interpret its output; the host
//! turns the result into one of four verdicts:
//!
//!   * passed      — exit 0 and no failing result;
//!   * failed      — anything else the verdict codecs (or the raw fallback)
//!                   report;
//!   * tainted     — the run changed a file the check runs or names (the
//!                   model edited its own judge, so the verdict stops
//!                   counting);
//!   * unavailable — no verdict at all (spawn failure, timeout, or the shell
//!                   could not find or execute the command: exit 126/127).
//!
//! In enforce mode a clean failure continues the same conversation with the
//! verdict — failing names, reasons, and an escalating reading from the
//! cognitive-mode schedule — at most `max_continuations` times. Observe mode
//! runs the same check at the same boundaries and records the verdict without
//! touching the conversation, so a control arm measures what the treatment
//! arm would have acted on. A blocking Stop hook (`decision: "block"`, or exit
//! code 2) continues the run the same way under its own bound.
//!
//! This is the in-run counterpart of `host_check.zig`, which runs the same
//! kind of pinned check once after a headless Run and files the verdict in
//! TinyKG for the next trial. It does not write TinyKG: the outcome rows are
//! keyed per trial, and the history readers built on them (best attempt,
//! regression, plateau cooling) count trials, so in-run sub-attempts would
//! shift their meaning. The in-run streak is kept here and feeds the same
//! `cognitive_mode.schedule`.
//!
//! Budget: deliberately separate from the host-injection meter. The meter
//! bounds advisory nudges (HostInjectionMeter.lean); a continuation is driven
//! by an external verdict, needs explicit opt-in, and carries its own bound.
//! Formal model: control-plane/lean/MetaCodesControl/CheckGate.lean — each
//! theorem names the mirroring test below.
//!
//! Sensor failure directions: a delivery-capable action missed by the sensor
//! leaves the gate silent; an action counted wrongly costs one check run whose
//! verdict is still real. Taint detection errs toward silence: a check whose
//! files were already dirty before the run counts as tainted.

const std = @import("std");
const verdict = @import("verdict.zig");
const cognitive_mode = @import("cognitive_mode.zig");
const delivery_cadence = @import("delivery_cadence.zig");
const verification_progress = @import("verification_progress.zig");
const tool_exec = @import("tool_exec.zig");
const shell_mod = @import("shell.zig");
const common = @import("../tools/common.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

/// Default continuation budget per run.
pub const DEFAULT_MAX_CONTINUATIONS: u8 = 3;
/// Largest budget `--check-gate-max` accepts.
pub const HARD_MAX_CONTINUATIONS: u8 = 8;
/// Continuations a blocking Stop hook can earn per run (CheckGate.lean
/// `maxStopBlocks`). Claude Code leaves this to the hook script
/// (`stop_hook_active`); the host keeps its own bound.
pub const MAX_STOP_HOOK_BLOCKS: u8 = 5;
/// Wall-clock limit for one check run (same as the end-of-run host check).
pub const CHECK_TIMEOUT_MS: u64 = 180_000;
pub const MAX_CHECK_OUTPUT_BYTES: usize = 256 * 1024;
pub const MAX_COMMAND_BYTES: usize = 1024;

pub const MARKER = "[host check]";
pub const STOP_HOOK_MARKER = "Stop hook feedback:";

pub const Mode = enum { enforce, observe };

pub const Options = struct {
    /// Borrowed; the host keeps it alive for the Run.
    command: []const u8,
    mode: Mode,
    max_continuations: u8 = DEFAULT_MAX_CONTINUATIONS,
    timeout_ms: u64 = CHECK_TIMEOUT_MS,
};

/// Gate options from the CLI flags; null when the gate is off. Enforce wins
/// when both modes are given (same precedence as the sibling gates).
pub fn optionsFromFlags(command: ?[]const u8, enforce: bool, observe: bool, max: ?u8) ?Options {
    const cmd = command orelse return null;
    if (!enforce and !observe) return null;
    return .{
        .command = cmd,
        .mode = if (enforce) .enforce else .observe,
        .max_continuations = max orelse DEFAULT_MAX_CONTINUATIONS,
    };
}

pub const Verdict = enum { passed, failed, tainted, unavailable };

pub const Decision = enum {
    finish_passed,
    finish_tainted,
    finish_unavailable,
    finish_exhausted,
    record_only,
    continue_run,
};

/// Pure policy; transcription of `CheckGate.decide`.
pub fn decide(mode: Mode, budget: u8, continuations: u8, outcome: Verdict) Decision {
    return switch (outcome) {
        .passed => .finish_passed,
        .tainted => .finish_tainted,
        .unavailable => .finish_unavailable,
        .failed => switch (mode) {
            .observe => .record_only,
            .enforce => if (continuations < budget) .continue_run else .finish_exhausted,
        },
    };
}

/// Pure policy; transcription of `CheckGate.stopContinues`.
pub fn stopContinues(blocked: bool, used: u8) bool {
    return blocked and used < MAX_STOP_HOOK_BLOCKS;
}

const MAX_TRACKED_NAMES = 16;
const MAX_NAME_BYTES = 128;

/// Basenames of files this run's file tools changed. Value semantics only:
/// the state lives for a whole Run with no allocator coupling. Overflow only
/// weakens taint detection.
const NameSet = struct {
    bytes: [MAX_TRACKED_NAMES][MAX_NAME_BYTES]u8 = undefined,
    lens: [MAX_TRACKED_NAMES]usize = [_]usize{0} ** MAX_TRACKED_NAMES,
    count: usize = 0,

    fn add(self: *NameSet, path: []const u8) void {
        const name = std.fs.path.basename(path);
        if (name.len == 0 or name.len > MAX_NAME_BYTES) return;
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.get(i), name)) return;
        }
        if (self.count >= MAX_TRACKED_NAMES) return;
        @memcpy(self.bytes[self.count][0..name.len], name);
        self.lens[self.count] = name.len;
        self.count += 1;
    }

    fn get(self: *const NameSet, i: usize) []const u8 {
        return self.bytes[i][0..self.lens[i]];
    }
};

pub const State = struct {
    /// A delivery-capable action happened since the last check.
    dirty: bool = false,
    checks: u8 = 0,
    continuations: u8 = 0,
    last_verdict: ?Verdict = null,
    last_passed: u32 = 0,
    last_total: u32 = 0,
    /// Consecutive checks with the same failure fingerprint (0 after a
    /// non-failure); feeds `cognitive_mode.schedule`.
    streak: u8 = 0,
    last_fingerprint: u64 = 0,
    stop_hook_blocks: u8 = 0,
    names: NameSet = .{},

    pub fn shouldCheck(self: *const State) bool {
        return self.dirty;
    }

    /// Observe the slots of one executed batch. Only slots that started
    /// count (same rule as the delivery-cadence sensor): denied, deferred and
    /// suspended slots never ran.
    pub fn observeSlots(self: *State, allocator: std.mem.Allocator, slots: []const tool_exec.Slot) void {
        for (slots) |slot| {
            if (slot.decision != .run or slot.pending) continue;
            const realized = verification_progress.isRealizedMutation(slot.effect, slot.effect_valid) or
                delivery_cadence.State.fileChangesRealized(slot);
            if (slot.content == null and !realized) continue;
            if (realized) self.recordChangedFiles(allocator, slot);
            if (realized or delivery_cadence.classify(allocator, slot.name, slot.input) == .mutation)
                self.dirty = true;
        }
    }

    fn recordChangedFiles(self: *State, allocator: std.mem.Allocator, slot: tool_exec.Slot) void {
        if (slot.file_changes) |changes| {
            for (changes) |record| {
                if (!record.status.changedDisk()) continue;
                switch (record.locator) {
                    .workspace_path, .absolute_path => |path| self.names.add(path),
                    .uri => {},
                }
            }
        }
        if (verification_progress.slotFilePath(allocator, slot.input)) |path| {
            defer allocator.free(path);
            self.names.add(path);
        }
    }

    /// Mirrors `CheckGate.boundary` for one check: the dirty bit clears, the
    /// check is counted, the failure streak advances on a repeated
    /// fingerprint.
    pub fn noteVerdict(self: *State, outcome: *const Outcome) void {
        self.dirty = false;
        self.checks +|= 1;
        self.last_verdict = outcome.verdict;
        self.last_passed = outcome.passed;
        self.last_total = outcome.total;
        if (outcome.verdict == .failed) {
            self.streak = if (self.streak > 0 and self.last_fingerprint == outcome.fingerprint)
                self.streak +| 1
            else
                1;
            self.last_fingerprint = outcome.fingerprint;
        } else {
            self.streak = 0;
        }
    }

    pub fn noteDecision(self: *State, decision: Decision) void {
        if (decision == .continue_run) self.continuations +|= 1;
    }
};

pub const Unavailable = enum { spawn_failed, timed_out, empty_command, not_runnable };

/// One check run turned into a verdict. Owns `output` and `parsed`.
pub const Outcome = struct {
    verdict: Verdict,
    unavailable: ?Unavailable = null,
    exit_code: i32 = 0,
    passed: u32 = 0,
    total: u32 = 0,
    fingerprint: u64 = 0,
    output: []u8 = &.{},
    parsed: ?verdict.ParseOutcome = null,

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        if (self.output.len > 0) allocator.free(self.output);
        if (self.parsed) |*p| p.deinit();
        self.* = undefined;
    }
};

const Captured = struct { output: []u8, exit_code: i32 };

const RunError = error{ Aborted, OutOfMemory };

/// Run `command` through the platform shell in `cwd`. Timeouts and spawn
/// failures are values (the host got no verdict); an abort is an error the
/// caller must honour.
fn capture(
    allocator: std.mem.Allocator,
    command: []const u8,
    cwd: ?[]const u8,
    abort: ?*const AbortSignal,
    timeout_ms: u64,
) RunError!union(enum) { done: Captured, unavailable: Unavailable } {
    const sys_shell = shell_mod.detectDefault();
    const cmd_z = try shell_mod.wrapCommand(allocator, sys_shell, command);
    defer allocator.free(cmd_z);
    var argv: [6]?[*:0]const u8 = undefined;
    shell_mod.deriveExecArgs(sys_shell, cmd_z.ptr, &argv);
    const out = common.spawnCaptureWithStderrTimed(argv[0..], allocator, abort, timeout_ms, null, MAX_CHECK_OUTPUT_BYTES, cwd) catch |err| switch (err) {
        error.Aborted => return error.Aborted,
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => return .{ .unavailable = .timed_out },
        else => return .{ .unavailable = .spawn_failed },
    };
    defer allocator.free(out.stderr);
    if (out.stderr.len == 0) return .{ .done = .{ .output = out.stdout, .exit_code = out.exit_code } };
    defer allocator.free(out.stdout);
    // stderr after stdout: pytest summaries go to stdout, compilers to
    // stderr; the raw fallback needs both.
    const merged = try std.mem.concat(allocator, u8, &.{ out.stdout, "\n", out.stderr });
    return .{ .done = .{ .output = merged, .exit_code = out.exit_code } };
}

/// Run the pinned check and classify the result. `state` supplies the files
/// this run changed (taint).
pub fn runCheck(
    allocator: std.mem.Allocator,
    options: Options,
    cwd: ?[]const u8,
    abort: ?*const AbortSignal,
    state: *const State,
) RunError!Outcome {
    if (std.mem.trim(u8, options.command, " \t\r\n").len == 0)
        return .{ .verdict = .unavailable, .unavailable = .empty_command };
    const captured = switch (try capture(allocator, options.command, cwd, abort, options.timeout_ms)) {
        .unavailable => |reason| return .{ .verdict = .unavailable, .unavailable = reason },
        .done => |done| done,
    };
    // 126/127: the shell could not execute or find the command. That is the
    // check's own failure, not the workspace's — asking the model to "fix the
    // cause in your changes" would send it after a missing script.
    if (captured.exit_code == 126 or captured.exit_code == 127)
        return .{ .verdict = .unavailable, .unavailable = .not_runnable, .exit_code = captured.exit_code, .output = captured.output };
    var outcome = Outcome{ .verdict = .failed, .exit_code = captured.exit_code, .output = captured.output };
    errdefer outcome.deinit(allocator);
    const parsed = try verdict.parseAuto(allocator, captured.output, captured.exit_code);
    var any_failed = false;
    for (parsed.results) |result| {
        if (result.kind == .failed) any_failed = true;
    }
    outcome.passed = parsed.passed;
    outcome.total = parsed.total;
    outcome.fingerprint = failureFingerprint(&parsed, captured.exit_code);
    const passed = captured.exit_code == 0 and !any_failed;
    outcome.parsed = parsed;

    // Taint: the run changed a program the command executes or a test file a
    // result names, or `git status` shows a named test file modified.
    var porcelain: ?[]u8 = null;
    defer if (porcelain) |p| allocator.free(p);
    switch (try capture(allocator, "git status --porcelain", cwd, abort, 10_000)) {
        .done => |done| {
            if (done.exit_code == 0) porcelain = done.output else allocator.free(done.output);
        },
        .unavailable => {},
    }
    if (isTainted(&outcome.parsed.?, options.command, porcelain, &state.names)) {
        outcome.verdict = .tainted;
    } else if (passed) {
        outcome.verdict = .passed;
    }
    return outcome;
}

/// Order-independent identity of a failure set: exit code plus every failing
/// result name. The raw fallback has one constant name, so repeated raw
/// failures share a fingerprint.
fn failureFingerprint(parsed: *const verdict.ParseOutcome, exit_code: i32) u64 {
    var acc: u64 = std.hash.Wyhash.hash(0, std.mem.asBytes(&exit_code));
    for (parsed.results) |result| {
        if (result.kind != .failed) continue;
        acc +%= std.hash.Wyhash.hash(1, result.name);
    }
    return acc;
}

fn isTainted(
    parsed: *const verdict.ParseOutcome,
    command: []const u8,
    porcelain: ?[]const u8,
    names: *const NameSet,
) bool {
    if (porcelain) |p| if (verdict.taintedByWorkspaceEdits(parsed, p)) return true;
    for (0..names.count) |i| {
        const name = names.get(i);
        if (executesFile(command, name)) return true;
        for (parsed.results) |result| {
            const file_part = if (std.mem.indexOf(u8, result.name, "::")) |cut| result.name[0..cut] else result.name;
            if (std.mem.eql(u8, std.fs.path.basename(file_part), name)) return true;
        }
    }
    return false;
}

const INTERPRETERS = [_][]const u8{ "sh", "bash", "dash", "zsh", "python", "python3", "node", "ruby", "perl" };

/// Whether `command` executes a file whose basename is `name`: the program of
/// each shell segment, or — when that program is an interpreter — the first
/// non-flag argument (`./pytest`, `sh check.sh`, `python3 run_tests.py`).
/// Arguments are inputs, not the judge: `grep -qx X result.txt` reads the
/// deliverable, and changing the deliverable is the whole point.
fn executesFile(command: []const u8, name: []const u8) bool {
    if (name.len == 0) return false;
    var segments = std.mem.tokenizeAny(u8, command, ";&|\n()");
    while (segments.next()) |segment| {
        var tokens = std.mem.tokenizeAny(u8, segment, " \t\r");
        var program: ?[]const u8 = null;
        while (tokens.next()) |raw| {
            const token = std.mem.trim(u8, raw, "\"'");
            if (token.len == 0) continue;
            if (program == null) {
                // Leading `VAR=value` assignments are not the program.
                if (std.mem.indexOfScalar(u8, token, '=') != null) continue;
                if (std.mem.eql(u8, std.fs.path.basename(token), name)) return true;
                program = std.fs.path.basename(token);
                var interpreter = false;
                for (INTERPRETERS) |known| {
                    if (std.mem.eql(u8, program.?, known)) interpreter = true;
                }
                if (!interpreter) break;
                continue;
            }
            if (token[0] == '-') continue;
            if (std.mem.eql(u8, std.fs.path.basename(token), name)) return true;
            break;
        }
    }
    return false;
}

const MAX_LISTED_FAILURES = 10;
const MAX_REASON_BYTES = 240;
const MAX_TAIL_BYTES = 1600;

/// The continuation message for a clean failure. Carries only the check's
/// own output and the run's counters; no task content. Failing names come
/// from the verdict codecs; the output tail is always included because the
/// codecs keep names, not the assertion detail the model needs.
pub fn renderContinuation(
    allocator: std.mem.Allocator,
    options: Options,
    outcome: *const Outcome,
    state: *const State,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.print(MARKER ++ "\nYou ended your turn, so the host ran the pinned check command itself: `{s}`\n", .{options.command});
    try w.print("Result: FAILED (exit code {d}).\n", .{outcome.exit_code});
    if (outcome.parsed) |parsed| {
        var listed: usize = 0;
        var failing: usize = 0;
        for (parsed.results) |result| {
            if (result.kind != .failed or std.mem.eql(u8, result.name, "pinned check")) continue;
            failing += 1;
            if (listed == MAX_LISTED_FAILURES) continue;
            if (listed == 0) try w.writeAll("Failing:\n");
            listed += 1;
            try w.writeAll("- ");
            try w.writeAll(result.name);
            const reason = if (result.message.len > 0) result.message else result.callsite;
            if (reason.len > 0) {
                try w.writeAll(": ");
                try writeOneLine(w, reason, MAX_REASON_BYTES);
            }
            try w.writeByte('\n');
        }
        if (failing > listed) try w.print("- … and {d} more\n", .{failing - listed});
    }
    const tail = utf8Tail(outcome.output, MAX_TAIL_BYTES);
    if (tail.len > 0) {
        try w.writeAll("Output tail:\n");
        try w.writeAll(tail);
        if (tail[tail.len - 1] != '\n') try w.writeByte('\n');
    }
    const mode = cognitive_mode.schedule(state.streak);
    try w.print("This failure set has come back {d} time(s) in a row; reading for this attempt: {s}.\n", .{ state.streak, mode.directive() });
    try w.writeAll("Find the cause in your changes, fix it, and run the check yourself before you finish. " ++
        "Do not edit the check command or the files it runs: a verdict from a check you changed no longer counts.\n");
    const left = options.max_continuations -| state.continuations;
    try w.print("Host-check continuations left after this one: {d}.", .{left});
    return out.toOwnedSlice();
}

/// The continuation message for a blocking Stop hook (Claude Code wording).
pub fn renderStopFeedback(allocator: std.mem.Allocator, reason: ?[]const u8) ![]u8 {
    const text = reason orelse "Blocked by hook";
    return std.fmt.allocPrint(allocator, STOP_HOOK_MARKER ++ "\n{s}", .{text});
}

fn writeOneLine(w: *std.Io.Writer, text: []const u8, cap: usize) !void {
    var written: usize = 0;
    var pending_space = false;
    var i: usize = 0;
    while (i < text.len and written < cap) {
        const c = text[i];
        if (c == '\n' or c == '\r' or c == '\t' or c == ' ') {
            pending_space = written > 0;
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (i + len > text.len or written + len > cap) break;
        if (pending_space) {
            try w.writeByte(' ');
            written += 1;
            pending_space = false;
        }
        try w.writeAll(text[i .. i + len]);
        written += len;
        i += len;
    }
    if (i < text.len) try w.writeAll(" …");
}

/// Last `cap` bytes of `text`, starting on a UTF-8 boundary.
fn utf8Tail(text: []const u8, cap: usize) []const u8 {
    if (text.len <= cap) return text;
    var start = text.len - cap;
    while (start < text.len and (text[start] & 0xC0) == 0x80) start += 1;
    return text[start..];
}

// ── Tests (policy names mirror CheckGate.lean) ─────────────────────────────

const testing = std.testing;

test "clean boundary is never checked" {
    // Lean: clean_boundary_never_checked.
    const state = State{};
    try testing.expect(!state.shouldCheck());
}

test "only a clean failure continues" {
    // Lean: only_failure_continues.
    for ([_]Mode{ .enforce, .observe }) |mode| {
        for ([_]Verdict{ .passed, .failed, .tainted, .unavailable }) |outcome| {
            for (0..4) |used| {
                const d = decide(mode, 3, @intCast(used), outcome);
                if (d == .continue_run) try testing.expectEqual(Verdict.failed, outcome);
            }
        }
    }
    try testing.expectEqual(Decision.finish_passed, decide(.enforce, 3, 0, .passed));
    try testing.expectEqual(Decision.finish_tainted, decide(.enforce, 3, 0, .tainted));
    try testing.expectEqual(Decision.finish_unavailable, decide(.enforce, 3, 0, .unavailable));
}

test "observe mode never continues" {
    // Lean: observe_never_continues.
    for ([_]Verdict{ .passed, .failed, .tainted, .unavailable }) |outcome| {
        try testing.expect(decide(.observe, 8, 0, outcome) != .continue_run);
    }
    try testing.expectEqual(Decision.record_only, decide(.observe, 8, 0, .failed));
}

test "continuation needs budget" {
    // Lean: continue_needs_budget.
    try testing.expectEqual(Decision.continue_run, decide(.enforce, 2, 1, .failed));
    try testing.expectEqual(Decision.finish_exhausted, decide(.enforce, 2, 2, .failed));
    try testing.expectEqual(Decision.finish_exhausted, decide(.enforce, 0, 0, .failed));
}

test "continuations and checks stay within budget over a trace" {
    // Lean: continuations_bounded, checks_bounded. Drive the State in
    // agent_loop's order — check first, then the Stop hook whenever the check
    // did not continue — with every boundary dirty, failing and blocked.
    const budget: u8 = 3;
    var state = State{};
    var ended = false;
    var boundaries: usize = 0;
    while (!ended and boundaries < 50) : (boundaries += 1) {
        state.dirty = true;
        if (!state.shouldCheck()) break;
        state.noteVerdict(&.{ .verdict = .failed, .fingerprint = 7 });
        const d = decide(.enforce, budget, state.continuations, .failed);
        state.noteDecision(d);
        if (d == .continue_run) continue;
        if (stopContinues(true, state.stop_hook_blocks)) {
            state.stop_hook_blocks += 1;
            continue;
        }
        ended = true;
    }
    try testing.expect(ended);
    try testing.expectEqual(budget, state.continuations);
    try testing.expectEqual(MAX_STOP_HOOK_BLOCKS, state.stop_hook_blocks);
    try testing.expectEqual(budget + MAX_STOP_HOOK_BLOCKS + 1, state.checks);
}

test "a non-blocking Stop hook never continues" {
    // Lean: unblocked_never_continues.
    for (0..10) |used| try testing.expect(!stopContinues(false, @intCast(used)));
}

test "Stop hook blocks stay within budget" {
    // Lean: stop_blocks_bounded, stop_continue_needs_budget.
    var used: u8 = 0;
    for (0..20) |_| {
        if (stopContinues(true, used)) used += 1;
    }
    try testing.expectEqual(MAX_STOP_HOOK_BLOCKS, used);
}

test "optionsFromFlags: off without a mode or command; enforce wins" {
    try testing.expect(optionsFromFlags(null, true, false, null) == null);
    try testing.expect(optionsFromFlags("make check", false, false, null) == null);
    const both = optionsFromFlags("make check", true, true, 5).?;
    try testing.expectEqual(Mode.enforce, both.mode);
    try testing.expectEqual(@as(u8, 5), both.max_continuations);
    const observe = optionsFromFlags("make check", false, true, null).?;
    try testing.expectEqual(Mode.observe, observe.mode);
    try testing.expectEqual(DEFAULT_MAX_CONTINUATIONS, observe.max_continuations);
}

test "failure streak advances only on the same fingerprint" {
    var state = State{};
    state.noteVerdict(&.{ .verdict = .failed, .fingerprint = 1 });
    try testing.expectEqual(@as(u8, 1), state.streak);
    state.noteVerdict(&.{ .verdict = .failed, .fingerprint = 1 });
    try testing.expectEqual(@as(u8, 2), state.streak);
    state.noteVerdict(&.{ .verdict = .failed, .fingerprint = 2 });
    try testing.expectEqual(@as(u8, 1), state.streak);
    state.noteVerdict(&.{ .verdict = .passed });
    try testing.expectEqual(@as(u8, 0), state.streak);
    try testing.expectEqual(@as(u8, 4), state.checks);
    try testing.expect(!state.dirty);
}

test "executesFile: the program or the interpreted script, never an argument" {
    try testing.expect(executesFile("./pytest -q", "pytest"));
    try testing.expect(executesFile("sh run_tests.sh", "run_tests.sh"));
    try testing.expect(executesFile("python3 -u \"tests/check.py\"", "check.py"));
    try testing.expect(executesFile("CI=1 ./check.sh && echo ok", "check.sh"));
    try testing.expect(executesFile("echo run >> log; bash -e verify.sh", "verify.sh"));
    try testing.expect(!executesFile("grep -qx 'TOTAL=42' result.txt", "result.txt"));
    try testing.expect(!executesFile("zig build test", "build.zig"));
    try testing.expect(!executesFile("./pytest_extra", "pytest"));
    try testing.expect(!executesFile("python3 run.py result.txt", "result.txt"));
}

test "taint: a changed file named by the command or a result" {
    var parsed = try verdict.parseAuto(testing.allocator, "FAILED tests/test_calc.py::test_add - boom\n", 1);
    defer parsed.deinit();
    var names = NameSet{};
    try testing.expect(!isTainted(&parsed, "./pytest", null, &names));
    names.add("src/calc.py");
    try testing.expect(!isTainted(&parsed, "./pytest", null, &names));
    names.add("/w/tests/test_calc.py");
    try testing.expect(isTainted(&parsed, "./pytest", null, &names));
    var runner = NameSet{};
    runner.add("pytest");
    try testing.expect(isTainted(&parsed, "./pytest -q", null, &runner));
}

test "runCheck classifies pass, failure and spawn failure" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX shell fixture
    const state = State{};
    var pass = try runCheck(testing.allocator, .{ .command = "printf 'ok\\n'", .mode = .enforce }, null, null, &state);
    defer pass.deinit(testing.allocator);
    try testing.expectEqual(Verdict.passed, pass.verdict);
    var fail = try runCheck(testing.allocator, .{ .command = "printf 'boom\\n' >&2; exit 3", .mode = .enforce }, null, null, &state);
    defer fail.deinit(testing.allocator);
    try testing.expectEqual(Verdict.failed, fail.verdict);
    try testing.expectEqual(@as(i32, 3), fail.exit_code);
    try testing.expect(std.mem.indexOf(u8, fail.output, "boom") != null);
    var empty = try runCheck(testing.allocator, .{ .command = "  ", .mode = .enforce }, null, null, &state);
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(Verdict.unavailable, empty.verdict);
    var missing = try runCheck(testing.allocator, .{ .command = "no-such-check-command-zz9", .mode = .enforce }, null, null, &state);
    defer missing.deinit(testing.allocator);
    try testing.expectEqual(Verdict.unavailable, missing.verdict);
    try testing.expectEqual(Unavailable.not_runnable, missing.unavailable.?);
}

test "runCheck: a timeout is unavailable, not a failure" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX shell fixture
    const state = State{};
    var slow = try runCheck(testing.allocator, .{ .command = "sleep 5", .mode = .enforce, .timeout_ms = 200 }, null, null, &state);
    defer slow.deinit(testing.allocator);
    try testing.expectEqual(Verdict.unavailable, slow.verdict);
    try testing.expectEqual(Unavailable.timed_out, slow.unavailable.?);
}

test "renderContinuation lists failures and the escalating reading" {
    const output = try testing.allocator.dupe(u8, "E   assert 3 == 4\nFAILED tests/test_calc.py::test_add - assert 3 == 4\n1 failed, 4 passed\n");
    const parsed = try verdict.parseAuto(testing.allocator, output, 1);
    var outcome = Outcome{ .verdict = .failed, .exit_code = 1, .total = 1, .output = output, .parsed = parsed };
    defer outcome.deinit(testing.allocator);
    var state = State{ .continuations = 1, .streak = 2 };
    state.checks = 2;
    const text = try renderContinuation(testing.allocator, .{ .command = "./pytest", .mode = .enforce, .max_continuations = 3 }, &outcome, &state);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, MARKER));
    try testing.expect(std.mem.indexOf(u8, text, "`./pytest`") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Failing:\n- tests/test_calc.py::test_add\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Output tail:\nE   assert 3 == 4\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, cognitive_mode.Mode.construct.directive()) != null);
    try testing.expect(std.mem.indexOf(u8, text, "continuations left after this one: 2") != null);
}

test "renderContinuation falls back to the output tail without names" {
    const parsed = try verdict.parseAuto(testing.allocator, "compile error: x\n", 2);
    const output = try testing.allocator.dupe(u8, "compile error: x\n");
    var outcome = Outcome{ .verdict = .failed, .exit_code = 2, .total = 1, .output = output, .parsed = parsed };
    defer outcome.deinit(testing.allocator);
    const state = State{ .streak = 1 };
    const text = try renderContinuation(testing.allocator, .{ .command = "make check", .mode = .enforce }, &outcome, &state);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "Output tail:\ncompile error: x\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Failing:") == null);
}
