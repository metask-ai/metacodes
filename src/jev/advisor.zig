//! Kernel-owned System-One decision seam (the Jev-Mem control plane).
//!
//! Every Jev-backed decision in metacodes goes through `Advisor`, so the rules
//! that keep an advisory judge safe hold in one place:
//!
//! - Off unless configured. A host that installs no advisor runs the exact
//!   baseline path. `shadow` asks and records while the deterministic baseline
//!   decides; `advisory` lets the caller's documented policy use the answer.
//! - Evidence, never authority. A caller may rank, filter, annotate or silence
//!   with an answer. Permission, sandbox, budget, formal verdicts, TinyKG
//!   admission and artifact CAS never see one.
//! - The host enumerates. Questions come from the fixed, versioned catalogs
//!   below and candidates from host data; the judge never names a command,
//!   path, node or tool.
//! - Failure split. A judge fault (timeout, refusal, malformed or priced
//!   answer, model drift) yields no answer and the caller keeps its baseline.
//!   A host abort is returned as `error.Aborted` and must stop the caller.
//! - Minimal state. Text leaves the machine only inside fixed byte budgets
//!   and after home paths and secret-shaped tokens are redacted.
//! - Every consultation yields an `Audit`; the caller journals it with what
//!   it did (`Audit.event`).
//!
//! The catalogs are narrow perceptual judgments on purpose. Measured against
//! metask-jev-4b (2026-09-23): enumeration intent 17/18 with criteria (6/18
//! without), memory type 8/8, same-fact/contradiction 12/12, relevance 0.89 for
//! the answering candidate vs <= 0.09 for distractors; a compound trajectory
//! judgment ("claims done without a passing check") only 4/6.

const std = @import("std");
const question = @import("question.zig");
const client_mod = @import("client.zig");
const observation = @import("../tools/observation.zig");
const util_time = @import("../util/time.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

pub const Mode = observation.SystemOneMode;
pub const Decision = observation.SystemOneDecision;
pub const Outcome = observation.SystemOneOutcome;

pub const MAX_MODEL_BYTES: usize = 64;

// ---------------------------------------------------------------------------
// Question catalogs. Each is validated at compile time and versioned: changing
// a word changes the judge's input distribution, so it must change the id.
// ---------------------------------------------------------------------------

/// v2 wording ("is it about the specific thing asked") replaced v1 ("is it
/// needed to answer"), which was too strict: memories that only lead to the
/// answer were judged irrelevant. On the 123 pinned LongMemEval-S dev cases
/// judged under both, v2 recovered gold evidence in 0.748 of cases vs 0.724
/// for v1 with the same policy and excerpt.
pub const RECALL_RELEVANCE_SET = "metacodes.jev.recall-relevance.v2";
/// Jev-Mem scores at most K_w = 10 candidates per request; eight excerpts of
/// `RECALL_EXCERPT_BYTES` keep the state far below the 4096-token limit.
pub const MAX_RECALL_CANDIDATES: usize = 8;

pub const recall_relevance_questions: [MAX_RECALL_CANDIDATES]question.Named = blk: {
    var out: [MAX_RECALL_CANDIDATES]question.Named = undefined;
    for (&out, 0..) |*named, index| {
        named.* = .{
            .name = std.fmt.comptimePrint("c{d}", .{index}),
            .question = .{ .boolean = .{
                .description = std.fmt.comptimePrint(
                    "Does candidates[{d}] contain information about the specific person, event, object or topic that the request asks about?",
                    .{index},
                ),
                .when_true = "It mentions or describes the specific thing the request is about, even if it does not fully answer it.",
                .when_false = "It is about something else and only shares generic words with the request.",
            } },
        };
    }
    question.validate(&out) catch unreachable;
    break :blk out;
};

/// Tool-path variant of the relevance catalog (KgRecall): the same per-candidate
/// questions followed by Jev-Mem's evidence-sufficiency Noul, answered in one
/// request so the stop signal costs no extra round trip.
pub const RECALL_EVIDENCE_SET = "metacodes.jev.recall-evidence.v2";

pub const recall_sufficiency_question = question.Named{
    .name = "sufficient",
    .question = .{ .boolean = .{
        .description = "Do the candidates together contain support for every factual part of an answer to the request?",
        .when_true = "A grounded answer can be given from these candidates without inventing missing facts.",
        .when_false = "Some required fact or link is missing; candidates about related topics are not enough.",
    } },
};

pub const ENUMERATION_INTENT_SET = "metacodes.jev.enumeration-intent.v1";

pub const enumeration_questions = [_]question.Named{.{
    .name = "needs_enumeration",
    .question = .{ .boolean = .{
        .description = "Does answering this user request require collecting multiple matching items and counting or listing them?",
        .when_true = "The answer is a count (how many) or a complete list of several matching items, occurrences or events.",
        .when_false = "The answer is a single fact, a yes/no, a date or name, or the request asks to perform an action or code change.",
    } },
}};

pub const MEMORY_RELATION_SET = "metacodes.jev.memory-relation.v1";
pub const MAX_RELATION_CANDIDATES: usize = 3;

/// Interleaved `same{i}`, `contradicts{i}` per existing memory.
pub const memory_relation_questions: [2 * MAX_RELATION_CANDIDATES]question.Named = blk: {
    var out: [2 * MAX_RELATION_CANDIDATES]question.Named = undefined;
    for (0..MAX_RELATION_CANDIDATES) |index| {
        out[2 * index] = .{
            .name = std.fmt.comptimePrint("same{d}", .{index}),
            .question = .{ .boolean = .{
                .description = std.fmt.comptimePrint(
                    "Do new_memory and existing[{d}] state the same fact, so that storing both would be redundant?",
                    .{index},
                ),
                .when_true = "Both describe the same specific fact, decision or event; one adds no essential new detail.",
                .when_false = "They describe different facts, or new_memory adds an essential detail the existing one lacks.",
            } },
        };
        out[2 * index + 1] = .{
            .name = std.fmt.comptimePrint("contradicts{d}", .{index}),
            .question = .{ .boolean = .{
                .description = std.fmt.comptimePrint(
                    "Does new_memory contradict existing[{d}], so that both cannot be currently true?",
                    .{index},
                ),
                .when_true = "The two accounts conflict on the same subject, such as a changed value, a reversed decision or an updated fact.",
                .when_false = "They are compatible, unrelated, or one merely adds detail to the other.",
            } },
        };
    }
    question.validate(&out) catch unreachable;
    break :blk out;
};

comptime {
    question.validate(&enumeration_questions) catch unreachable;
    question.validate(&(recall_relevance_questions ++ [_]question.Named{recall_sufficiency_question})) catch unreachable;
}

// ---------------------------------------------------------------------------
// State budgets (bytes, before redaction shrinks them).
// ---------------------------------------------------------------------------

pub const REQUEST_BYTES: usize = 400;
pub const RECALL_EXCERPT_BYTES: usize = @import("excerpt.zig").JUDGE_WINDOW_BYTES;
pub const ENUMERATION_TEXT_BYTES: usize = 1200;
pub const RELATION_TEXT_BYTES: usize = 1200;

comptime {
    // Worst case of each state shape stays inside the transport's cap.
    const recall_worst = "request: ".len + REQUEST_BYTES +
        MAX_RECALL_CANDIDATES * ("\n\ncandidates[0] (): ".len + 64 + RECALL_EXCERPT_BYTES);
    std.debug.assert(recall_worst <= client_mod.MAX_STATE_BYTES);
    const relation_worst = "new_memory: ".len + RELATION_TEXT_BYTES +
        MAX_RELATION_CANDIDATES * ("\n\nexisting[0]: ".len + RELATION_TEXT_BYTES);
    std.debug.assert(relation_worst <= client_mod.MAX_STATE_BYTES);
}

// ---------------------------------------------------------------------------
// Audit and judgments
// ---------------------------------------------------------------------------

pub const Audit = struct {
    decision: Decision,
    question_set: []const u8,
    mode: Mode,
    outcome: Outcome,
    request_sha256: [64]u8,
    model_buf: [MAX_MODEL_BYTES]u8 = undefined,
    model_len: usize = 0,
    elapsed_ms: u64 = 0,
    question_count: u32,
    state_bytes: u32,

    pub fn model(self: *const Audit) []const u8 {
        return self.model_buf[0..self.model_len];
    }

    fn setModel(self: *Audit, name: []const u8) void {
        const n = @min(name.len, MAX_MODEL_BYTES);
        @memcpy(self.model_buf[0..n], name[0..n]);
        self.model_len = n;
    }

    /// The journal record for this consultation. `changed` counts host
    /// decisions that differ from the baseline (applied when `actuated`,
    /// counterfactual otherwise). Borrows `self`: emit before it goes away.
    pub fn event(self: *const Audit, actuated: bool, judged: u32, positive: u32, changed: u32) observation.Event {
        return .{ .system_one_decision = .{
            .decision = self.decision,
            .question_set = self.question_set,
            .mode = self.mode,
            .outcome = self.outcome,
            .actuated = actuated,
            .request_sha256 = self.request_sha256,
            .model = self.model(),
            .elapsed_ms = self.elapsed_ms,
            .question_count = self.question_count,
            .state_bytes = self.state_bytes,
            .judged = judged,
            .positive = positive,
            .changed = changed,
        } };
    }
};

/// Whole-percent P(true) per boolean question, aligned with the catalog
/// slice that was asked. Meaningful only when `answered()`.
pub fn Judgment(comptime capacity: usize) type {
    return struct {
        audit: Audit,
        percents: [capacity]u8 = [_]u8{0} ** capacity,
        count: usize = 0,

        pub fn answered(self: *const @This()) bool {
            return self.audit.outcome == .answered;
        }

        /// How many judged questions reached `threshold` percent.
        pub fn countAtLeast(self: *const @This(), threshold: u8) u32 {
            var n: u32 = 0;
            for (self.percents[0..self.count]) |p| {
                if (p >= threshold) n += 1;
            }
            return n;
        }
    };
}

pub const RecallCandidate = struct {
    /// Memory type label (`decision`, `bug`, …); host data, not redacted.
    type_label: []const u8,
    text: []const u8,
};

pub const ExistingMemory = struct {
    text: []const u8,
};

pub const ConsultError = error{ OutOfMemory, Aborted };

/// The memory decisions an advisor can be consulted on. Each one is a separate
/// operator choice (`METACODES_JEV_DECISIONS`); a surface the advisor does not
/// advise behaves exactly as if no advisor were installed.
pub const Surface = enum { scoped_recall, recall_evidence, memory_relation, enumeration_intent };
pub const Surfaces = std.EnumSet(Surface);

pub const Advisor = struct {
    client: *client_mod.Client,
    mode: Mode,
    /// Replaced by `~` in every state sent; empty disables home redaction.
    home: []const u8 = "",
    surfaces: Surfaces = .initFull(),

    pub fn actuates(self: *const Advisor) bool {
        return self.mode == .advisory;
    }

    pub fn advises(self: *const Advisor, surface: Surface) bool {
        return self.surfaces.contains(surface);
    }

    /// P(relevant) for each candidate against the request (Jev-Mem's
    /// candidate relevance Noul), at most `MAX_RECALL_CANDIDATES`.
    pub fn judgeRecallRelevance(
        self: *Advisor,
        allocator: std.mem.Allocator,
        abort: ?*const AbortSignal,
        request: []const u8,
        candidates: []const RecallCandidate,
    ) ConsultError!Judgment(MAX_RECALL_CANDIDATES) {
        const n = @min(candidates.len, MAX_RECALL_CANDIDATES);
        std.debug.assert(n > 0);
        var state: std.ArrayList(u8) = .empty;
        defer state.deinit(allocator);
        try self.writeRecallState(&state, allocator, request, candidates[0..n]);
        return self.judge(MAX_RECALL_CANDIDATES, allocator, abort, .recall_relevance, RECALL_RELEVANCE_SET, state.items, recall_relevance_questions[0..n]);
    }

    /// P(relevant) for each candidate followed by P(sufficient) for the set:
    /// `percents[0..n]` are the candidates, `percents[n]` the sufficiency.
    pub fn judgeRecallEvidence(
        self: *Advisor,
        allocator: std.mem.Allocator,
        abort: ?*const AbortSignal,
        request: []const u8,
        candidates: []const RecallCandidate,
    ) ConsultError!Judgment(MAX_RECALL_CANDIDATES + 1) {
        const n = @min(candidates.len, MAX_RECALL_CANDIDATES);
        std.debug.assert(n > 0);
        var state: std.ArrayList(u8) = .empty;
        defer state.deinit(allocator);
        try self.writeRecallState(&state, allocator, request, candidates[0..n]);
        var questions: [MAX_RECALL_CANDIDATES + 1]question.Named = undefined;
        @memcpy(questions[0..n], recall_relevance_questions[0..n]);
        questions[n] = recall_sufficiency_question;
        return self.judge(MAX_RECALL_CANDIDATES + 1, allocator, abort, .recall_relevance, RECALL_EVIDENCE_SET, state.items, questions[0 .. n + 1]);
    }

    fn writeRecallState(
        self: *const Advisor,
        state: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        request: []const u8,
        candidates: []const RecallCandidate,
    ) error{OutOfMemory}!void {
        try state.appendSlice(allocator, "request: ");
        try appendRedacted(state, allocator, request, REQUEST_BYTES, self.home);
        for (candidates, 0..) |candidate, index| {
            const label = candidate.type_label[0..@min(candidate.type_label.len, 64)];
            try state.print(allocator, "\n\ncandidates[{d}] ({s}): ", .{ index, label });
            try appendRedacted(state, allocator, candidate.text, RECALL_EXCERPT_BYTES, self.home);
        }
    }

    /// P(the request needs a complete count or list).
    pub fn judgeEnumerationIntent(
        self: *Advisor,
        allocator: std.mem.Allocator,
        abort: ?*const AbortSignal,
        request: []const u8,
    ) ConsultError!Judgment(1) {
        var state: std.ArrayList(u8) = .empty;
        defer state.deinit(allocator);
        try state.appendSlice(allocator, "User request: ");
        try appendRedacted(&state, allocator, request, ENUMERATION_TEXT_BYTES, self.home);
        return self.judge(1, allocator, abort, .enumeration_intent, ENUMERATION_INTENT_SET, state.items, &enumeration_questions);
    }

    /// Interleaved P(same fact), P(contradiction) of `new_text` against each
    /// existing memory, at most `MAX_RELATION_CANDIDATES`.
    pub fn judgeMemoryRelations(
        self: *Advisor,
        allocator: std.mem.Allocator,
        abort: ?*const AbortSignal,
        new_text: []const u8,
        existing: []const ExistingMemory,
    ) ConsultError!Judgment(2 * MAX_RELATION_CANDIDATES) {
        const n = @min(existing.len, MAX_RELATION_CANDIDATES);
        std.debug.assert(n > 0);
        var state: std.ArrayList(u8) = .empty;
        defer state.deinit(allocator);
        try state.appendSlice(allocator, "new_memory: ");
        try appendRedacted(&state, allocator, new_text, RELATION_TEXT_BYTES, self.home);
        for (existing[0..n], 0..) |memory, index| {
            try state.print(allocator, "\n\nexisting[{d}]: ", .{index});
            try appendRedacted(&state, allocator, memory.text, RELATION_TEXT_BYTES, self.home);
        }
        return self.judge(2 * MAX_RELATION_CANDIDATES, allocator, abort, .memory_relation, MEMORY_RELATION_SET, state.items, memory_relation_questions[0 .. 2 * n]);
    }

    fn judge(
        self: *Advisor,
        comptime capacity: usize,
        allocator: std.mem.Allocator,
        abort: ?*const AbortSignal,
        decision: Decision,
        question_set: []const u8,
        state: []const u8,
        questions: []const question.Named,
    ) ConsultError!Judgment(capacity) {
        std.debug.assert(questions.len <= capacity);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        try question.writeRequest(&body, allocator, state, questions);
        var result: Judgment(capacity) = .{ .audit = .{
            .decision = decision,
            .question_set = question_set,
            .mode = self.mode,
            .outcome = .answered,
            .request_sha256 = sha256Hex(body.items),
            .question_count = @intCast(questions.len),
            .state_bytes = @intCast(state.len),
        } };
        const started_ms = util_time.nowMs();
        var answers = self.client.ask(allocator, abort, state, questions) catch |err| {
            result.audit.elapsed_ms = @intCast(@max(util_time.nowMs() - started_ms, 0));
            result.audit.outcome = switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Aborted => return error.Aborted,
                error.InvalidRequest => .invalid_request,
                error.Unavailable => .unavailable,
                error.Rejected => .rejected,
                error.MalformedResponse => .malformed,
                error.PricedService => .priced_service,
                error.ModelMismatch => .model_mismatch,
            };
            return result;
        };
        defer answers.deinit();
        result.audit.elapsed_ms = @intCast(@max(util_time.nowMs() - started_ms, 0));
        result.audit.setModel(answers.model);
        for (questions, 0..) |_, index| {
            result.percents[index] = question.percent(answers.probTrue(index));
        }
        result.count = questions.len;
        return result;
    }
};

// ---------------------------------------------------------------------------
// State hygiene
// ---------------------------------------------------------------------------

/// Credential prefixes whose tokens are replaced before any text leaves the
/// host. Deliberately a fixed list: a redaction heuristic that guesses at
/// entropy would also eat hashes, ids and code the judge needs.
const SECRET_PREFIXES = [_][]const u8{
    "sk-",    "sk_live_", "sk_test_", "ghp_",  "gho_", "ghs_", "ghu_", "github_pat_",
    "glpat-", "xoxb-",    "xoxp-",    "xoxa-", "AKIA", "ASIA", "AIza",
};
const MIN_SECRET_TOKEN_BYTES: usize = 16;
pub const REDACTED = "[redacted]";

/// Append at most `max_bytes` of `text` (cut on a UTF-8 boundary), with every
/// occurrence of `home` replaced by `~` and every credential-shaped token by
/// `[redacted]`.
pub fn appendRedacted(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
    max_bytes: usize,
    home: []const u8,
) error{OutOfMemory}!void {
    const bounded = utf8Prefix(text, max_bytes);
    var index: usize = 0;
    while (index < bounded.len) {
        if (home.len > 1 and std.mem.startsWith(u8, bounded[index..], home)) {
            try out.append(allocator, '~');
            index += home.len;
            continue;
        }
        const at_token_start = index == 0 or isTokenBoundary(bounded[index - 1]);
        if (at_token_start) {
            if (secretTokenLen(bounded[index..])) |len| {
                try out.appendSlice(allocator, REDACTED);
                index += len;
                continue;
            }
        }
        try out.append(allocator, bounded[index]);
        index += 1;
    }
}

fn secretTokenLen(rest: []const u8) ?usize {
    for (SECRET_PREFIXES) |prefix| {
        if (!std.mem.startsWith(u8, rest, prefix)) continue;
        var len: usize = prefix.len;
        while (len < rest.len and !isTokenBoundary(rest[len])) len += 1;
        if (len >= MIN_SECRET_TOKEN_BYTES) return len;
    }
    return null;
}

fn isTokenBoundary(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n', '"', '\'', '`', '=', ':', ',', ';', '(', ')', '[', ']', '{', '}', '<', '>' => true,
        else => false,
    };
}

fn utf8Prefix(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var n = max_bytes;
    while (n > 0 and (text[n] & 0xC0) == 0x80) n -= 1;
    return text[0..n];
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "catalogs are valid, versioned and name each candidate by index" {
    try testing.expectEqualStrings("c0", recall_relevance_questions[0].name);
    try testing.expectEqualStrings("c7", recall_relevance_questions[7].name);
    try testing.expect(std.mem.indexOf(u8, recall_relevance_questions[3].question.boolean.description, "candidates[3]") != null);
    try testing.expectEqualStrings("same2", memory_relation_questions[4].name);
    try testing.expectEqualStrings("contradicts2", memory_relation_questions[5].name);
    try question.validate(recall_relevance_questions[0..1]);
    try question.validate(memory_relation_questions[0..2]);
}

test "appendRedacted replaces home paths and credential tokens, keeps the rest" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendRedacted(
        &out,
        testing.allocator,
        "open /Users/alice/prj/x.zig with key=sk-abcdefghijklmnopqrst and ghp_0123456789abcdef0123; sha 3f2a9c",
        1024,
        "/Users/alice",
    );
    try testing.expectEqualStrings("open ~/prj/x.zig with key=[redacted] and [redacted]; sha 3f2a9c", out.items);

    // Short prefixed words and mid-token matches are not secrets.
    out.clearRetainingCapacity();
    try appendRedacted(&out, testing.allocator, "task-AKIA risk sk-short", 1024, "");
    try testing.expectEqualStrings("task-AKIA risk sk-short", out.items);
}

test "appendRedacted cuts on a UTF-8 boundary" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendRedacted(&out, testing.allocator, "ab中文", 4, "");
    try testing.expectEqualStrings("ab", out.items);
}

test "Judgment counts answers at a threshold" {
    var judgment: Judgment(4) = .{ .audit = undefined, .percents = .{ 91, 12, 60, 59 }, .count = 4 };
    try testing.expectEqual(@as(u32, 2), judgment.countAtLeast(60));
    try testing.expectEqual(@as(u32, 1), judgment.countAtLeast(80));
}
