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

pub const State = struct {
    mutation_seen: bool = false,
    checkpoint_emitted: bool = false,

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
        var successful_verification = false;
        for (slots) |slot| {
            if (isRealizedMutation(slot.effect, slot.effect_valid))
                realized_mutation = true;
            if (mutation_preceded_turn and
                !self.checkpoint_emitted and
                isSuccessfulVerification(allocator, slot))
                successful_verification = true;
        }
        self.mutation_seen = self.mutation_seen or realized_mutation;
        if (!successful_verification) return false;
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

fn verificationEvidence(allocator: std.mem.Allocator, command: []const u8) ?Evidence {
    const pipeline = stripDisplayPipeline(command) orelse return null;
    if (!onlyAndConjunctions(pipeline.command)) return null;
    const segments = bash_parser.splitCompound(allocator, pipeline.command) catch return null;
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
    return pytestStreamPassed(stdout) or pytestStreamPassed(stderr);
}

fn pytestStreamPassed(bytes: []const u8) bool {
    if (std.mem.indexOf(u8, bytes, " passed") == null) return false;
    return std.mem.indexOf(u8, bytes, " failed") == null and
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
