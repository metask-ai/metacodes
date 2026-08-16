//! Lightweight, run-local progress observer for coding work.
//!
//! This is deliberately not a Lean rule and not a stop condition.  It consumes
//! typed effects from the real tool dispatch seam and one conservative class of
//! successful verification command, then asks `agent_loop` to append a single
//! late user-message checkpoint.  The stable system prompt and tool schema stay
//! byte-for-byte unchanged.

const std = @import("std");
const tool_exec = @import("tool_exec.zig");
const observation = @import("../tools/observation.zig");
const common = @import("../tools/common.zig");
const util_json = @import("../util/json.zig");
const bash_parser = @import("../permission/bash_parser.zig");

pub const CHECKPOINT_TEXT =
    "[verification checkpoint]\n" ++
    "A post-mutation verification command succeeded. Before doing more work:\n" ++
    "1. Compare the implementation and exact user-visible behavior with the nearest existing repository tests/contracts.\n" ++
    "2. If the requested behavior is satisfied, run at most one proportionate regression check and finish.\n" ++
    "3. Continue editing only when a concrete failure or unmet requirement justifies it.\n" ++
    "Do not add unrelated tests, docs, or refactors.";

pub const FINAL_GATE_TEXT =
    "[verification obligation]\n" ++
    "You are about to finish, but the last file mutation has not been " ++
    "followed by a successful verification run. Before your final answer:\n" ++
    "1. Run the most relevant verification command (the project's tests, the " ++
    "task's acceptance checks, or a direct execution of the changed code).\n" ++
    "2. If it fails, fix the code and verify again.\n" ++
    "3. Only then give your final answer.\n" ++
    "If no verification command can exist for this change, state that " ++
    "explicitly in your final answer instead of implying it was verified.";

pub const State = struct {
    mutation_seen: bool = false,
    checkpoint_emitted: bool = false,
    /// True while the most recent realized mutation has not been followed by
    /// a successful verification in a *later* completed turn. Intra-turn
    /// ordering is deliberately not trusted (same reasoning as the
    /// checkpoint): a turn that both mutates and verifies leaves the
    /// obligation open until a verification-only turn clears it.
    unverified_mutation: bool = false,

    /// Observe one completed tool-use turn.  A mutation and verification in the
    /// same parallel turn do not trigger: their real execution order is not a
    /// safe semantic dependency.  The verification must follow a mutation from
    /// an earlier completed turn.
    pub fn observeTurn(
        self: *State,
        allocator: std.mem.Allocator,
        slots: []const tool_exec.Slot,
    ) bool {
        const mutation_preceded_turn = self.mutation_seen;
        var realized_mutation = false;
        var any_successful_verification = false;
        for (slots) |slot| {
            if (isRealizedMutation(slot.effect, slot.effect_valid))
                realized_mutation = true;
            if (isSuccessfulVerification(allocator, slot))
                any_successful_verification = true;
        }
        self.mutation_seen = self.mutation_seen or realized_mutation;
        // Final-gate obligation: a mutating turn (re)opens it regardless of a
        // same-turn verification; a verification-only turn closes it.
        if (realized_mutation) {
            self.unverified_mutation = true;
        } else if (any_successful_verification) {
            self.unverified_mutation = false;
        }
        const checkpoint = mutation_preceded_turn and
            !self.checkpoint_emitted and any_successful_verification;
        if (!checkpoint) return false;
        self.checkpoint_emitted = true;
        return true;
    }
};

fn isRealizedMutation(effect: ?observation.Effect, effect_valid: bool) bool {
    if (!effect_valid) return false;
    const value = effect orelse return false;
    return switch (value) {
        // V1 has not been re-observed by the host, so it is not sufficient for
        // a progress transition.
        .file_mutation_v1 => false,
        .file_mutation_v2 => |mutation| mutation.mutation.change == .changed and
            mutation.reobservation.state == .matched,
    };
}

fn isSuccessfulVerification(allocator: std.mem.Allocator, slot: tool_exec.Slot) bool {
    if (slot.decision != .run or slot.pending or slot.is_error or
        !std.mem.eql(u8, slot.name, "Bash")) return false;
    const content = slot.content orelse return false;
    if (std.mem.indexOf(u8, content, "\"exit_code\":") == null or
        util_json.extractIntField(content, "exit_code") != 0) return false;

    const encoded = common.extractJsonArg(slot.input, "command") orelse return false;
    const command = util_json.unescapeString(encoded, allocator) catch return false;
    defer allocator.free(command);
    const evidence = verificationEvidence(allocator, command) orelse return false;
    return switch (evidence) {
        .shell_exit => true,
        .pytest_summary => pytestSummaryPassed(allocator, content),
    };
}

const Evidence = enum { shell_exit, pytest_summary };

/// Conservative shell classifier.  Pipelines, `;`, `||`, backgrounding,
/// substitutions and newlines are rejected because the final shell exit code
/// would not prove that the test command itself succeeded.  `cd dir && test`
/// is accepted because every segment must succeed.
pub fn isVerificationCommand(allocator: std.mem.Allocator, command: []const u8) bool {
    return verificationEvidence(allocator, command) != null;
}

/// A `;`-joined command can never prove anything through its shell exit code
/// (a failed test followed by `echo` exits 0), but the ubiquitous agent idiom
/// `./pytest; echo "exit=$?"` still carries unlaunderable evidence: the pytest
/// summary text. Accept a semicolon chain only when the head is a pytest-kind
/// command and every trailing segment is pure display (echo/printf/cat/true,
/// no redirects, pipes or control operators), and downgrade the evidence to
/// the summary text, never the exit code.
fn semicolonDisplayChainEvidence(
    allocator: std.mem.Allocator,
    command: []const u8,
) ?Evidence {
    var segments = std.ArrayList([]const u8).empty;
    defer segments.deinit(allocator);
    var in_single = false;
    var in_double = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        if (c == '\\' and !in_single and i + 1 < command.len) {
            i += 1;
            continue;
        }
        if (c == '\'' and !in_double) in_single = !in_single;
        if (c == '"' and !in_single) in_double = !in_double;
        if (c == ';' and !in_single and !in_double) {
            segments.append(allocator, command[start..i]) catch return null;
            start = i + 1;
        }
    }
    if (in_single or in_double) return null;
    segments.append(allocator, command[start..]) catch return null;
    var effective: usize = 0;
    for (segments.items) |raw| {
        if (std.mem.trim(u8, raw, " \t\r").len != 0) effective += 1;
    }
    if (effective < 2) return null;
    var head: ?[]const u8 = null;
    for (segments.items) |raw| {
        const segment = std.mem.trim(u8, raw, " \t\r");
        if (segment.len == 0) continue;
        if (head == null) {
            head = segment;
            continue;
        }
        if (!displayOnlySegment(segment)) return null;
    }
    const head_command = head orelse return null;
    _ = verificationEvidence(allocator, head_command) orelse return null;
    if (!headIsPytest(allocator, head_command)) return null;
    return .pytest_summary;
}

fn displayOnlySegment(segment: []const u8) bool {
    if (std.mem.indexOfAny(u8, segment, "><|&`") != null) return false;
    var tokens = std.mem.tokenizeAny(u8, segment, " \t\r");
    const first = basename(tokens.next() orelse return false);
    return std.mem.eql(u8, first, "echo") or std.mem.eql(u8, first, "printf") or
        std.mem.eql(u8, first, "cat") or std.mem.eql(u8, first, "true");
}

fn headIsPytest(allocator: std.mem.Allocator, head: []const u8) bool {
    const pipeline = stripDisplayPipeline(head) orelse return false;
    if (!onlyAndConjunctions(pipeline.command)) return false;
    const segments = splitAndConjunctions(allocator, pipeline.command) catch return false;
    defer allocator.free(segments);
    for (segments) |raw| {
        const segment = bash_parser.stripWrappers(raw);
        if (testKind(segment)) |kind| {
            if (kind == .pytest) return true;
        }
    }
    return false;
}

fn verificationEvidence(allocator: std.mem.Allocator, command: []const u8) ?Evidence {
    if (semicolonDisplayChainEvidence(allocator, command)) |evidence| return evidence;
    const pipeline = stripDisplayPipeline(command) orelse return null;
    if (!onlyAndConjunctions(pipeline.command)) return null;
    // The general permission parser deliberately treats every `&` as a shell
    // separator.  Here `onlyAndConjunctions` has already admitted the narrow
    // presentation redirect `2>&1`; feeding that string back through the
    // general parser would split it into `2>` / `1` and silently miss the
    // normal `pytest 2>&1 | tail` form used by real coding agents.
    const segments = splitAndConjunctions(allocator, pipeline.command) catch return null;
    defer allocator.free(segments);
    if (segments.len == 0) return null;

    var tests: usize = 0;
    var pytest = false;
    for (segments) |raw| {
        const segment = bash_parser.stripWrappers(raw);
        if (testKind(segment)) |kind| {
            tests += 1;
            pytest = kind == .pytest;
            continue;
        }
        if (!isDirectoryChange(segment)) return null;
    }
    if (tests != 1) return null;
    if (!pipeline.has_display_pipe) return .shell_exit;
    return if (pytest) .pytest_summary else null;
}

/// Split the command after `onlyAndConjunctions` has rejected every operator
/// except `&&` and the exact stderr presentation redirect `2>&1`.  Returned
/// slices borrow `command`; only the outer slice is allocated.
fn splitAndConjunctions(
    allocator: std.mem.Allocator,
    command: []const u8,
) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var start: usize = 0;
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        if (c == '\\' and !in_single and i + 1 < command.len) {
            i += 1;
            continue;
        }
        if (c == '\'' and !in_double) {
            in_single = !in_single;
            continue;
        }
        if (c == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double or c != '&') continue;
        // `onlyAndConjunctions` proved every remaining ampersand is the first
        // byte of `&&`; the one in `2>&1` is preceded by `2>`.
        if (i >= 2 and std.mem.eql(u8, command[i - 2 .. i + 2], "2>&1")) {
            i += 1;
            continue;
        }
        const segment = std.mem.trim(u8, command[start..i], " \t\r");
        if (segment.len == 0) return error.InvalidConjunction;
        try out.append(allocator, segment);
        i += 1;
        start = i + 1;
    }
    const tail = std.mem.trim(u8, command[start..], " \t\r");
    if (tail.len == 0) return error.InvalidConjunction;
    try out.append(allocator, tail);
    return out.toOwnedSlice(allocator);
}

const Pipeline = struct { command: []const u8, has_display_pipe: bool };

/// Accept only presentation-only `| head ...` / `| tail ...` suffixes. Their
/// shell exit status belongs to the viewer, so callers must additionally
/// validate the framework summary in captured output.
fn stripDisplayPipeline(command: []const u8) ?Pipeline {
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        if (c == '\\' and !in_single and i + 1 < command.len) {
            i += 1;
            continue;
        }
        if (c == '\'' and !in_double) {
            in_single = !in_single;
            continue;
        }
        if (c == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double or c != '|') continue;
        if ((i + 1 < command.len and (command[i + 1] == '|' or command[i + 1] == '&')) or
            (i > 0 and command[i - 1] == '|')) return null;
        const viewer = std.mem.trim(u8, command[i + 1 ..], " \t\r");
        if (std.mem.indexOfScalar(u8, viewer, '|') != null or
            std.mem.indexOfScalar(u8, viewer, ';') != null or
            std.mem.indexOfScalar(u8, viewer, '&') != null) return null;
        var tokens = std.mem.tokenizeAny(u8, viewer, " \t\r");
        const head = std.fs.path.basename(tokens.next() orelse return null);
        if (!std.mem.eql(u8, head, "head") and !std.mem.eql(u8, head, "tail")) return null;
        return .{
            .command = std.mem.trim(u8, command[0..i], " \t\r"),
            .has_display_pipe = true,
        };
    }
    if (in_single or in_double) return null;
    return .{ .command = command, .has_display_pipe = false };
}

fn pytestSummaryPassed(allocator: std.mem.Allocator, content: []const u8) bool {
    const encoded_out = common.extractJsonArg(content, "stdout") orelse return false;
    const encoded_err = common.extractJsonArg(content, "stderr") orelse return false;
    const stdout = util_json.unescapeString(encoded_out, allocator) catch return false;
    defer allocator.free(stdout);
    const stderr = util_json.unescapeString(encoded_err, allocator) catch return false;
    defer allocator.free(stderr);
    const passed = std.mem.indexOf(u8, stdout, " passed") != null or
        std.mem.indexOf(u8, stderr, " passed") != null;
    return passed and pytestStreamHasNoFailure(stdout) and
        pytestStreamHasNoFailure(stderr);
}

fn pytestStreamHasNoFailure(bytes: []const u8) bool {
    return std.mem.indexOf(u8, bytes, " failed") == null and
        std.mem.indexOf(u8, bytes, " error") == null and
        std.mem.indexOf(u8, bytes, " errors") == null and
        std.mem.indexOf(u8, bytes, " ERROR") == null and
        std.mem.indexOf(u8, bytes, "no tests ran") == null;
}

fn onlyAndConjunctions(command: []const u8) bool {
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        if (c == '\\' and !in_single and i + 1 < command.len) {
            i += 1;
            continue;
        }
        if (c == '\'' and !in_double) {
            in_single = !in_single;
            continue;
        }
        if (c == '"' and !in_single) {
            in_double = !in_double;
            continue;
        }
        if (in_single or in_double) continue;
        // `2>&1` changes only where stderr is observed, not the test process
        // exit status.  It is common immediately before a display-only tail.
        if (c == '2' and i + 3 < command.len and
            std.mem.eql(u8, command[i .. i + 4], "2>&1") and
            (i == 0 or std.ascii.isWhitespace(command[i - 1])) and
            (i + 4 == command.len or std.ascii.isWhitespace(command[i + 4])))
        {
            i += 3;
            continue;
        }
        if (c == '\n' or c == ';' or c == '`') return false;
        if (c == '$' and i + 1 < command.len and command[i + 1] == '(') return false;
        if (c == '|') return false;
        if (c == '&') {
            if (i + 1 >= command.len or command[i + 1] != '&') return false;
            i += 1;
        }
    }
    return !in_single and !in_double;
}

fn isDirectoryChange(segment: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, std.mem.trim(u8, segment, " \t\r"), " \t\r");
    return if (tokens.next()) |head| std.mem.eql(u8, head, "cd") else false;
}

fn basename(token: []const u8) []const u8 {
    return std.fs.path.basename(token);
}

const TestKind = enum { pytest, other };

fn testKind(segment: []const u8) ?TestKind {
    var tokens = std.mem.tokenizeAny(u8, std.mem.trim(u8, segment, " \t\r"), " \t\r");
    const first_raw = tokens.next() orelse return null;
    const first = basename(first_raw);
    var flags = tokens;
    while (flags.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V") or
            std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return null;
    }
    if (std.mem.eql(u8, first, "pytest") or std.mem.eql(u8, first, "py.test")) return .pytest;
    if (std.mem.eql(u8, first, "ctest")) return .other;
    if (std.mem.eql(u8, first, "python") or std.mem.eql(u8, first, "python3")) {
        return if (std.mem.eql(u8, tokens.next() orelse return null, "-m") and
            std.mem.eql(u8, tokens.next() orelse return null, "pytest")) .pytest else null;
    }
    if (std.mem.eql(u8, first, "zig")) {
        const sub = tokens.next() orelse return null;
        if (std.mem.eql(u8, sub, "test")) return .other;
        if (!std.mem.eql(u8, sub, "build")) return null;
        return if (std.mem.startsWith(u8, tokens.next() orelse return null, "test")) .other else null;
    }
    if (std.mem.eql(u8, first, "cargo") or std.mem.eql(u8, first, "go"))
        return if (std.mem.eql(u8, tokens.next() orelse return null, "test")) .other else null;
    if (std.mem.eql(u8, first, "npm")) {
        const sub = tokens.next() orelse return null;
        if (std.mem.eql(u8, sub, "test")) return .other;
        return if (std.mem.eql(u8, sub, "run") and
            std.mem.startsWith(u8, tokens.next() orelse return null, "test")) .other else null;
    }
    if (std.mem.eql(u8, first, "pnpm") or std.mem.eql(u8, first, "yarn"))
        return if (std.mem.startsWith(u8, tokens.next() orelse return null, "test")) .other else null;
    if (std.mem.eql(u8, first, "make"))
        return if (std.mem.startsWith(u8, tokens.next() orelse return null, "test")) .other else null;
    return null;
}

test "semicolon display chains carry pytest summary evidence only" {
    const a = std.testing.allocator;
    // The ubiquitous agent idiom: run the test, then echo the exit code.
    try std.testing.expect(isVerificationCommand(a, "./pytest; echo \"exit=$?\""));
    try std.testing.expect(isVerificationCommand(
        a,
        "./pytest; echo \"exit=$?\"; cat result.txt",
    ));
    // A non-display suffix could do work after a failed test; reject.
    try std.testing.expect(!isVerificationCommand(a, "./pytest; rm -rf junk"));
    // Redirects inside the suffix write state; reject.
    try std.testing.expect(!isVerificationCommand(a, "./pytest; cat > out.txt"));
    // A non-test head gains nothing from a display suffix.
    try std.testing.expect(!isVerificationCommand(a, "ls; echo ok"));
    // Non-pytest kinds have no summary text to fall back on; reject.
    try std.testing.expect(!isVerificationCommand(a, "make test; echo done"));
}

test "verification classifier accepts bounded test forms and rejects ambiguous shell status" {
    const a = std.testing.allocator;
    try std.testing.expect(isVerificationCommand(a, "cd /workspace && python -m pytest testing/test_config.py -q"));
    try std.testing.expect(isVerificationCommand(a, "zig build test:eval"));
    try std.testing.expect(isVerificationCommand(a, "zig test src/parser_test.zig"));
    try std.testing.expect(isVerificationCommand(a, "timeout 30 cargo test parser"));
    try std.testing.expect(isVerificationCommand(a, "python -m pytest -q | tail -20"));
    try std.testing.expect(isVerificationCommand(a, "python -m pytest -q 2>&1 | tail -20"));
    try std.testing.expect(!isVerificationCommand(a, "python -m pytest -q | grep passed"));
    try std.testing.expect(!isVerificationCommand(a, "grep -n test src/a.zig"));
    try std.testing.expect(!isVerificationCommand(a, "python -m pytest -q; true"));
    try std.testing.expect(!isVerificationCommand(a, "python -m pytest --version"));
    try std.testing.expect(!isVerificationCommand(a, "zig test --help"));
    try std.testing.expect(!isVerificationCommand(a, "cd /workspace && git status"));
}
