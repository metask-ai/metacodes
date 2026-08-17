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
    "1. Re-read the ORIGINAL task statement and check each explicitly requested " ++
    "behavior or requirement is actually implemented — visible tests passing " ++
    "does not prove the statement is satisfied (test suites routinely cover " ++
    "less than what was asked).\n" ++
    "2. Compare the implementation and exact user-visible behavior with the nearest existing repository tests/contracts.\n" ++
    "3. If the requested behavior is satisfied, run at most one proportionate regression check and finish.\n" ++
    "4. Continue editing only when a concrete failure or unmet requirement justifies it.\n" ++
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

/// Negative-evidence variant: the host observed a FAILED verification attempt
/// after the last mutation with no success since. "Go verify" would be the
/// wrong instruction — the model already knows the state; the obligation is to
/// fix or to report honestly.
pub const FINAL_GATE_KNOWN_FAILING_TEXT =
    "[verification obligation]\n" ++
    "You are about to finish, but the last verification attempt after your " ++
    "file mutations FAILED and no successful verification has followed. " ++
    "Before your final answer:\n" ++
    "1. Fix the failure and re-run the verification, or\n" ++
    "2. If the failure is expected or out of scope, state the failing status " ++
    "explicitly and honestly in your final answer.\n" ++
    "Do not imply the change was verified.";

/// Injected at most once per session when a mutation lands after a successful
/// verification (the churn signature observed to flip previously-passing
/// work). Task-agnostic process guidance only.
pub const FRESHNESS_TEXT =
    "[verification freshness]\n" ++
    "This mutation happened after a successful verification; that " ++
    "verification no longer covers the current state.\n" ++
    "1. Re-run the relevant verification before finishing.\n" ++
    "2. Verification is for confirming behavior — do not rewrite " ++
    "already-passing implementations without a concrete failing reason.";

/// Bounded value-semantics name set: HashMap keys into growable buffers dangle
/// after realloc, and this state must survive arbitrarily long sessions with
/// zero allocator lifetime coupling.
const MAX_TRACKED_NAMES = 16;
const MAX_NAME_BYTES = 128;

pub const State = struct {
    mutation_seen: bool = false,
    checkpoint_emitted: bool = false,
    /// True while the most recent realized mutation has not been followed by
    /// a successful verification in a *later* completed turn. Intra-turn
    /// ordering is deliberately not trusted (same reasoning as the
    /// checkpoint): a turn that both mutates and verifies leaves the
    /// obligation open until a verification-only turn clears it.
    unverified_mutation: bool = false,
    /// A verification-shaped attempt after the last mutation FAILED and no
    /// success has followed. Selects the honest-report nudge variant.
    known_failing: bool = false,
    /// Tier-1: canonical test-runner evidence (existing conservative grammar).
    tier1_verifications: u32 = 0,
    /// Tier-2: validating re-observation — a non-display computation that
    /// references a mutated file and exited 0 (inline import probes,
    /// py_compile, pipeline re-runs). Real verification behavior observed in
    /// the field that the tier-1 grammar cannot see.
    tier2_verifications: u32 = 0,
    /// Churn signature: a realized mutation landed while the session was in a
    /// verified state. Observational counter for the shadow phase of any
    /// future formal rule.
    reopened_after_verification: u32 = 0,
    /// v3 传感器(PO-V2 M4,observe):义务已闭合时又来的验证事件计数
    /// (每轮至多 +1;"绿灯重跑"的可观察面),与最终一次闭合义务的证据级
    /// (0=未闭合/被重开,1=tier1 测试命令,2=tier2 变更面重观察)。
    redundant_verifications: u32 = 0,
    final_closure_tier: u8 = 0,
    /// 最近一次验证尝试(tier1/tier2 形状)的结局是失败(PO-V2 M2 信号位:
    /// 失败之后的测试文件编辑是"弱化候选")。成功验证清零。
    last_verification_failed: bool = false,
    churn_caution_pending: bool = false,
    churn_caution_emitted: bool = false,
    /// Basenames of files with realized mutations this session (bounded;
    /// overflow only widens tier-2 misses, never falsely satisfies).
    name_bytes: [MAX_TRACKED_NAMES][MAX_NAME_BYTES]u8 = undefined,
    name_lens: [MAX_TRACKED_NAMES]usize = [_]usize{0} ** MAX_TRACKED_NAMES,
    name_count: usize = 0,

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
        const was_verified = self.mutation_seen and !self.unverified_mutation;
        var realized_mutation = false;
        var tier1 = false;
        var tier2 = false;
        var failed_attempt = false;
        // Classification pass uses the PRE-turn name set: a same-turn
        // mutation+probe pair must not close the obligation (intra-turn order
        // is untrusted), and the obligation branch below already keeps it
        // open on mutating turns.
        for (slots) |slot| {
            if (isSuccessfulVerification(allocator, slot)) {
                tier1 = true;
            } else if (self.isSuccessfulReobservation(allocator, slot)) {
                tier2 = true;
            } else if (self.isFailedVerificationAttempt(allocator, slot)) {
                failed_attempt = true;
            }
        }
        for (slots) |slot| {
            if (isRealizedMutation(slot.effect, slot.effect_valid)) {
                realized_mutation = true;
                self.recordMutatedName(allocator, slot.input);
            }
        }
        self.mutation_seen = self.mutation_seen or realized_mutation;
        if (tier1) self.tier1_verifications += 1;
        if (tier2) self.tier2_verifications += 1;
        // Final-gate obligation: a mutating turn (re)opens it regardless of a
        // same-turn verification; a verification-only turn closes it.
        if (realized_mutation) {
            if (was_verified) {
                self.reopened_after_verification += 1;
                if (!self.churn_caution_emitted) self.churn_caution_pending = true;
            }
            self.unverified_mutation = true;
            self.known_failing = false;
            self.final_closure_tier = 0;
        } else if (tier1 or tier2) {
            if (!self.unverified_mutation and mutation_preceded_turn) {
                // M4 传感器:没有待验变更却在验证——"绿灯重跑"面,只计数不判定。
                self.redundant_verifications += 1;
            } else if (self.unverified_mutation) {
                self.final_closure_tier = if (tier2) 2 else 1;
            }
            self.unverified_mutation = false;
            self.known_failing = false;
        } else if (failed_attempt and self.unverified_mutation) {
            self.known_failing = true;
        }
        // M2 信号位与义务无关,单独维护:本轮出现成功验证 → 清;
        // 只有失败尝试 → 置。两者皆无 → 保持。
        if (tier1 or tier2) {
            self.last_verification_failed = false;
        } else if (failed_attempt) {
            self.last_verification_failed = true;
        }
        const checkpoint = mutation_preceded_turn and
            !self.checkpoint_emitted and tier1;
        if (!checkpoint) return false;
        self.checkpoint_emitted = true;
        return true;
    }

    /// One-shot churn caution consumption for the freshness injection.
    pub fn takeChurnCaution(self: *State) bool {
        if (!self.churn_caution_pending) return false;
        self.churn_caution_pending = false;
        self.churn_caution_emitted = true;
        return true;
    }

    fn recordMutatedName(
        self: *State,
        allocator: std.mem.Allocator,
        input: []const u8,
    ) void {
        const encoded = common.extractJsonArg(input, "file_path") orelse
            common.extractJsonArg(input, "notebook_path") orelse return;
        const path = util_json.unescapeString(encoded, allocator) catch return;
        defer allocator.free(path);
        const name = basename(path);
        if (name.len == 0 or name.len > MAX_NAME_BYTES) return;
        for (0..self.name_count) |i| {
            if (std.mem.eql(u8, self.name_bytes[i][0..self.name_lens[i]], name))
                return;
        }
        if (self.name_count >= MAX_TRACKED_NAMES) return;
        @memcpy(self.name_bytes[self.name_count][0..name.len], name);
        self.name_lens[self.name_count] = name.len;
        self.name_count += 1;
    }

    /// Tier-2 verification: a successful Bash command that consumes a mutated
    /// artifact. Conservative on laundering: heredoc payloads are data, and a
    /// non-heredoc command may only chain with `&&`.
    fn isSuccessfulReobservation(
        self: *const State,
        allocator: std.mem.Allocator,
        slot: tool_exec.Slot,
    ) bool {
        if (self.name_count == 0) return false;
        if (slot.decision != .run or slot.pending or slot.is_error or
            !std.mem.eql(u8, slot.name, "Bash")) return false;
        const content = slot.content orelse return false;
        if (std.mem.indexOf(u8, content, "\"exit_code\":") == null or
            util_json.extractIntField(content, "exit_code") != 0) return false;
        const command = decodedCommand(allocator, slot.input) orelse return false;
        defer allocator.free(command);
        if (!tierTwoCommandShape(command)) return false;
        return self.commandReferencesMutated(command);
    }

    /// A verification-shaped attempt (tier-1 grammar or tier-2 reference)
    /// whose exit code is nonzero: negative evidence, not noise.
    fn isFailedVerificationAttempt(
        self: *const State,
        allocator: std.mem.Allocator,
        slot: tool_exec.Slot,
    ) bool {
        if (slot.decision != .run or slot.pending or
            !std.mem.eql(u8, slot.name, "Bash")) return false;
        const content = slot.content orelse return false;
        if (std.mem.indexOf(u8, content, "\"exit_code\":") == null) return false;
        if (util_json.extractIntField(content, "exit_code") == 0) return false;
        const command = decodedCommand(allocator, slot.input) orelse return false;
        defer allocator.free(command);
        if (isVerificationCommand(allocator, command)) return true;
        return tierTwoCommandShape(command) and self.commandReferencesMutated(command);
    }

    fn commandReferencesMutated(self: *const State, command: []const u8) bool {
        for (0..self.name_count) |i| {
            const name = self.name_bytes[i][0..self.name_lens[i]];
            if (std.mem.indexOf(u8, command, name) != null) return true;
            const stem = nameStem(name);
            if (stem.len >= 4 and containsBoundedToken(command, stem)) return true;
        }
        return false;
    }
};

fn decodedCommand(allocator: std.mem.Allocator, input: []const u8) ?[]u8 {
    const encoded = common.extractJsonArg(input, "command") orelse return null;
    return util_json.unescapeString(encoded, allocator) catch null;
}

fn nameStem(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    if (dot == 0) return name;
    return name[0..dot];
}

fn isWordByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// `stem` must appear bounded by non-word bytes so short module stems cannot
/// match inside unrelated identifiers.
fn containsBoundedToken(haystack: []const u8, stem: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, from, stem)) |at| {
        const before_ok = at == 0 or !isWordByte(haystack[at - 1]);
        const end = at + stem.len;
        const after_ok = end >= haystack.len or !isWordByte(haystack[end]);
        if (before_ok and after_ok) return true;
        from = at + 1;
    }
    return false;
}

/// Shape guard for tier-2: reject display-only heads outright, treat a heredoc
/// tail as opaque data, and forbid exit-code laundering separators (`;`, `||`,
/// `|`, `&` backgrounding) in the shell-visible prefix. `&&` chains and the
/// `2>&1` presentation redirect stay legal.
fn tierTwoCommandShape(command: []const u8) bool {
    const shell_visible = heredocPrefix(command);
    var tokens = std.mem.tokenizeAny(u8, shell_visible, " \t\r\n");
    var first = tokens.next() orelse return false;
    // Skip leading `cd dir &&` segments for the display-head check.
    while (std.mem.eql(u8, basename(first), "cd")) {
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "&&")) break;
        } else return false;
        first = tokens.next() orelse return false;
    }
    const head = basename(first);
    const display_heads = [_][]const u8{
        "cat",  "echo", "ls",   "head", "tail", "less",
        "more", "printf", "true", "stat", "wc", "grep",
        "find", "rg",
    };
    for (display_heads) |d| {
        if (std.mem.eql(u8, head, d)) return false;
    }
    // Laundering guard on the shell-visible prefix only.
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < shell_visible.len) : (i += 1) {
        const c = shell_visible[i];
        if (c == '\\' and !in_single and i + 1 < shell_visible.len) {
            i += 1;
            continue;
        }
        if (c == '\'' and !in_double) in_single = !in_single;
        if (c == '"' and !in_single) in_double = !in_double;
        if (in_single or in_double) continue;
        switch (c) {
            ';', '|' => return false,
            '&' => {
                const double = i + 1 < shell_visible.len and shell_visible[i + 1] == '&';
                const redirect = i >= 2 and
                    std.mem.eql(u8, shell_visible[i - 2 .. i + 2], "2>&1");
                if (redirect) {
                    i += 1;
                    continue;
                }
                if (!double) return false;
                i += 1;
            },
            else => {},
        }
    }
    return true;
}

/// Return the shell-visible prefix: everything before the first unquoted `<<`
/// (the heredoc body is interpreter data, not shell grammar).
fn heredocPrefix(command: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        if (c == '\\' and !in_single and i + 1 < command.len) {
            i += 1;
            continue;
        }
        if (c == '\'' and !in_double) in_single = !in_single;
        if (c == '"' and !in_single) in_double = !in_double;
        if (in_single or in_double) continue;
        if (c == '<' and i + 1 < command.len and command[i + 1] == '<')
            return command[0..i];
    }
    return command;
}

pub fn isRealizedMutation(effect: ?observation.Effect, effect_valid: bool) bool {
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

/// 测试分类文件的任务无关启发:basename 以 test_/test. 开头、以 _test.<ext>
/// 结尾、或路径含 /tests//test/ 目录段。PO-V2 M2 候选信号用;观察期启发,
/// 精度由观察数据校准。
pub fn isTestFilePath(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    if (std.mem.startsWith(u8, base, "test_") or std.mem.startsWith(u8, base, "test.")) return true;
    if (std.mem.indexOf(u8, base, "_test.") != null or std.mem.indexOf(u8, base, ".test.") != null) return true;
    if (std.mem.indexOf(u8, path, "/tests/") != null or std.mem.indexOf(u8, path, "/test/") != null) return true;
    return false;
}

/// 编辑输入是否触碰断言类 token(assert/expect;大小写不敏感,扫原始 JSON
/// 字节即可——转义不影响 ASCII 子串)。观察期启发。
pub fn editTouchesAssertTokens(input: []const u8) bool {
    var i: usize = 0;
    while (i + 6 <= input.len) : (i += 1) {
        const window6 = input[i .. i + 6];
        var lower6: [6]u8 = undefined;
        for (window6, 0..) |c, j| lower6[j] = std.ascii.toLower(c);
        if (std.mem.eql(u8, &lower6, "assert") or std.mem.eql(u8, &lower6, "expect")) return true;
    }
    return false;
}

/// 从 Edit/Write/NotebookEdit 输入提取目标路径(unescape 后 owned)。
pub fn slotFilePath(allocator: std.mem.Allocator, input: []const u8) ?[]u8 {
    const encoded = common.extractJsonArg(input, "file_path") orelse
        common.extractJsonArg(input, "notebook_path") orelse return null;
    return util_json.unescapeString(encoded, allocator) catch null;
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
    // Retired strictness: a pure-display suffix after a pytest head now
    // yields summary-text evidence (the exit code stays untrusted).
    try std.testing.expect(isVerificationCommand(a, "python -m pytest -q; true"));
    try std.testing.expect(!isVerificationCommand(a, "python -m pytest --version"));
    try std.testing.expect(!isVerificationCommand(a, "zig test --help"));
    try std.testing.expect(!isVerificationCommand(a, "cd /workspace && git status"));
}

// ---------------------------------------------------------------------------
// v2 sensor tests: tiered verification, negative evidence, churn signature.
// Fixture shapes mirror behaviors observed in real WorkBuddy trials.
// ---------------------------------------------------------------------------

fn testBashSlot(input: []const u8, content: []const u8) tool_exec.Slot {
    return .{
        .decision = .run,
        .name = "Bash",
        .id = "b",
        .input = input,
        .content = @constCast(content),
    };
}

fn testEditSlot(input: []const u8) tool_exec.Slot {
    return .{
        .decision = .run,
        .name = "Edit",
        .id = "e",
        .input = input,
        .effect = .{ .file_mutation_v2 = .{
            .mutation = .{
                .path_sha256 = [_]u8{'0'} ** 64,
                .before_state = .known,
                .before_sha256 = [_]u8{'0'} ** 64,
                .after_sha256 = [_]u8{'1'} ** 64,
                .before_bytes = 1,
                .after_bytes = 2,
                .change = .changed,
            },
            .reobservation = .{
                .state = .matched,
                .observed_sha256 = [_]u8{'1'} ** 64,
                .observed_bytes = 2,
            },
        } },
    };
}

const OK = "{\"exit_code\":0,\"stdout\":\"\",\"stderr\":\"\"}";
const FAIL = "{\"exit_code\":1,\"stdout\":\"\",\"stderr\":\"\"}";
const EDIT_HEADERS = "{\"file_path\":\"/workspace/tornado_like/headers.py\",\"old_string\":\"a\",\"new_string\":\"b\"}";

test "tier-2 heredoc import probe closes the obligation" {
    const a = std.testing.allocator;
    var state = State{};
    _ = state.observeTurn(a, &.{testEditSlot(EDIT_HEADERS)});
    try std.testing.expect(state.unverified_mutation);
    const probe = "{\"command\":\"cd /workspace && python3 - <<'PY'\\nfrom tornado_like.headers import HTTPHeaders\\nprint(HTTPHeaders)\\nPY\"}";
    _ = state.observeTurn(a, &.{testBashSlot(probe, OK)});
    try std.testing.expect(!state.unverified_mutation);
    try std.testing.expectEqual(@as(u32, 1), state.tier2_verifications);
    try std.testing.expectEqual(@as(u32, 0), state.tier1_verifications);
}

test "tier-2 accepts py_compile chains and pipeline re-runs, rejects laundering and display heads" {
    const a = std.testing.allocator;
    var state = State{};
    _ = state.observeTurn(a, &.{testEditSlot(EDIT_HEADERS)});
    // Semicolon in the shell-visible prefix launders the exit code; stays open.
    const laundered = "{\"command\":\"python3 headers.py; echo ok\"}";
    _ = state.observeTurn(a, &.{testBashSlot(laundered, OK)});
    try std.testing.expect(state.unverified_mutation);
    // Display head is re-reading, not validating; stays open.
    const display = "{\"command\":\"cat tornado_like/headers.py\"}";
    _ = state.observeTurn(a, &.{testBashSlot(display, OK)});
    try std.testing.expect(state.unverified_mutation);
    // py_compile with an && display tail is a real validating computation.
    const compile = "{\"command\":\"cd /workspace && python3 -m py_compile tornado_like/headers.py && echo ok\"}";
    _ = state.observeTurn(a, &.{testBashSlot(compile, OK)});
    try std.testing.expect(!state.unverified_mutation);

    var rerun_state = State{};
    const edit_pipeline = "{\"file_path\":\"/workspace/app/clean_labels.py\",\"old_string\":\"x\",\"new_string\":\"y\"}";
    _ = rerun_state.observeTurn(a, &.{testEditSlot(edit_pipeline)});
    const rerun = "{\"command\":\"cd /workspace && python app/clean_labels.py --data data/labels.csv\"}";
    _ = rerun_state.observeTurn(a, &.{testBashSlot(rerun, OK)});
    try std.testing.expect(!rerun_state.unverified_mutation);
}

test "short stems never match inside identifiers" {
    const a = std.testing.allocator;
    var state = State{};
    const edit_app = "{\"file_path\":\"/workspace/app.py\",\"old_string\":\"x\",\"new_string\":\"y\"}";
    _ = state.observeTurn(a, &.{testEditSlot(edit_app)});
    const unrelated = "{\"command\":\"python3 -c 'import application'\"}";
    _ = state.observeTurn(a, &.{testBashSlot(unrelated, OK)});
    try std.testing.expect(state.unverified_mutation);
}

test "failed verification attempts set known_failing; success clears it" {
    const a = std.testing.allocator;
    var state = State{};
    _ = state.observeTurn(a, &.{testEditSlot(EDIT_HEADERS)});
    const pytest_cmd = "{\"command\":\"cd /workspace && python -m pytest -q\"}";
    _ = state.observeTurn(a, &.{testBashSlot(pytest_cmd, FAIL)});
    try std.testing.expect(state.known_failing);
    try std.testing.expect(state.unverified_mutation);
    _ = state.observeTurn(a, &.{testBashSlot(pytest_cmd, OK)});
    try std.testing.expect(!state.known_failing);
    try std.testing.expect(!state.unverified_mutation);
    try std.testing.expectEqual(@as(u32, 1), state.tier1_verifications);
}

test "mutation after verified state counts churn and arms one caution" {
    const a = std.testing.allocator;
    var state = State{};
    _ = state.observeTurn(a, &.{testEditSlot(EDIT_HEADERS)});
    const pytest_cmd = "{\"command\":\"python -m pytest -q\"}";
    _ = state.observeTurn(a, &.{testBashSlot(pytest_cmd, OK)});
    try std.testing.expect(!state.unverified_mutation);
    _ = state.observeTurn(a, &.{testEditSlot(EDIT_HEADERS)});
    try std.testing.expectEqual(@as(u32, 1), state.reopened_after_verification);
    try std.testing.expect(state.takeChurnCaution());
    try std.testing.expect(!state.takeChurnCaution());
    // A second churn round increments the counter but never re-arms the
    // one-shot caution.
    _ = state.observeTurn(a, &.{testBashSlot(pytest_cmd, OK)});
    _ = state.observeTurn(a, &.{testEditSlot(EDIT_HEADERS)});
    try std.testing.expectEqual(@as(u32, 2), state.reopened_after_verification);
    try std.testing.expect(!state.takeChurnCaution());
    // Mutation resets known_failing (the fix attempt makes the state unknown).
    _ = state.observeTurn(a, &.{testBashSlot(pytest_cmd, FAIL)});
    try std.testing.expect(state.known_failing);
    _ = state.observeTurn(a, &.{testEditSlot(EDIT_HEADERS)});
    try std.testing.expect(!state.known_failing);
}

test "same-turn mutation plus probe keeps the obligation open" {
    const a = std.testing.allocator;
    var state = State{};
    _ = state.observeTurn(a, &.{testEditSlot(EDIT_HEADERS)});
    const probe = "{\"command\":\"python3 -m py_compile tornado_like/headers.py\"}";
    _ = state.observeTurn(a, &.{ testEditSlot(EDIT_HEADERS), testBashSlot(probe, OK) });
    try std.testing.expect(state.unverified_mutation);
}

test "M2: test file path heuristic" {
    try std.testing.expect(isTestFilePath("/w/tests/test_a.py"));
    try std.testing.expect(isTestFilePath("/w/pkg/foo_test.go"));
    try std.testing.expect(isTestFilePath("/w/src/app.test.ts"));
    try std.testing.expect(isTestFilePath("/w/test/headers.py"));
    try std.testing.expect(!isTestFilePath("/w/src/app.py"));
    try std.testing.expect(!isTestFilePath("/w/contest/entry.py"));
    try std.testing.expect(!isTestFilePath("/w/src/protester.py"));
}

test "M2: assert token heuristic scans raw escaped input" {
    try std.testing.expect(editTouchesAssertTokens("{\"content\":\"    assert x == 1\\n\"}"));
    try std.testing.expect(editTouchesAssertTokens("{\"new_string\":\"expectEqual(a,b)\"}"));
    try std.testing.expect(editTouchesAssertTokens("{\"content\":\"ASSERT_TRUE(ok)\"}"));
    try std.testing.expect(!editTouchesAssertTokens("{\"content\":\"print(1)\\n\"}"));
}
