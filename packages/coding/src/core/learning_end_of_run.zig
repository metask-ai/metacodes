//! End-of-run form of the learning turn (doc/LEARNING_TURN_DESIGN.md §2.1).
//!
//! The evaluation harness arms the host check through `METACODES_HOST_CHECK`,
//! which runs after `agent_loop.run` has returned, so the in-run learning turn
//! never sees that verdict. This form spends one bounded, no-tools provider
//! request instead, in the pattern of `self_evolution.endOfRun`: a frozen role
//! prompt, a packet built from the host's verdict and the stored lessons for
//! the task, the self-evolution author caps on tokens and cost, and the
//! response treated as evidence. The host then writes the lessons the response
//! carries through `KgClient.remember` with schema type `lesson` and the same
//! header binding `KgRemember` enforces (`kg/lesson.zig`), so both forms store
//! byte-compatible nodes.
//!
//! Policy: the same pure `learning_turn.decide`. It runs only after an
//! attempt that reached its own end (`end_turn`) and only when the in-run
//! learning turn did not already decide on a verdict (`modeFor`). Observe mode
//! decides and records without a request. Distill and reconcile share the one
//! request: the packet lists the stored lessons and asks for corrections as
//! `supersedes:` lessons, so the report counts one pass.
//!
//! Failure direction: every fault (caps, transport, an incomplete or tool-using
//! response, usage over the caps) writes nothing and is reported as
//! `degraded`; it never changes the run's exit.

const std = @import("std");
const learning_turn = @import("learning_turn.zig");
const host_check = @import("host_check.zig");
const self_evolution = @import("self_evolution.zig");
const rule_author = @import("rule_author.zig");
const lesson = @import("../kg/lesson.zig");
const kg_client_mod = @import("../kg/client.zig");
const provider_mod = @import("metacodes-ai").api.provider;
const types = @import("metacodes-ai").types;
const AbortSignal = @import("metacodes-base").util.abort.AbortSignal;
const log = @import("metacodes-base").util.log;

pub const MARKER = learning_turn.MARKER ++ " end of run";
/// The attempt's own final note, quoted as unverified context.
pub const MAX_FINAL_NOTE_BYTES: usize = 4096;
/// Envelopes looked at in one response; any beyond count as refused.
pub const MAX_SEGMENTS: usize = 2 * lesson.MAX_PER_TURN;
/// Response text kept: room for every segment at the envelope cap plus prose.
pub const MAX_RESPONSE_BYTES: usize = MAX_SEGMENTS * lesson.MAX_BYTES + 4096;
/// The packet is bounded so its tokens cannot exceed the author input cap: a
/// token covers at least one byte, so bytes bound tokens.
pub const MAX_PACKET_BYTES: usize = 32 * 1024;

comptime {
    std.debug.assert(MAX_PACKET_BYTES + ROLE_PROMPT.len <= self_evolution.AUTHOR_MAX_INPUT_TOKENS);
}

/// Frozen system prompt. Provider-visible bytes are a cache contract, so it
/// carries no run data.
pub const ROLE_PROMPT =
    "You review one finished attempt at a software task after the host ran a pinned check on it. " ++
    "You have no tools and nothing you write changes the attempt or its workspace. " ++
    "Your only output is lessons for a fresh attempt at the same task, in the exact envelope the user message gives, " ++
    "or nothing when the attempt taught nothing reusable.";

/// The mode the end-of-run form runs in, or null. It needs an attempt that
/// ended on its own (`end_turn`: not aborted, stalled, cut by a budget or the
/// turn cap) and an in-run learning turn that did not decide on a verdict:
/// absent, or `none_unchecked` because the check gate never ran at the final
/// workspace. Any other in-run decision stands — a pass already ran or was
/// recorded, and a tainted, unavailable or unstorable verdict must not be
/// re-litigated by a second check.
pub fn modeFor(configured: ?learning_turn.Mode, in_run: ?learning_turn.Report, attempt_finished: bool) ?learning_turn.Mode {
    const mode = configured orelse return null;
    if (!attempt_finished) return null;
    if (in_run) |report| if (report.decision != .none_unchecked) return null;
    return mode;
}

pub const Input = struct {
    mode: learning_turn.Mode,
    evidence: *const host_check.Evidence,
    /// METACODES_TASK_HINT. Not a clean header token → project-wide lessons.
    task_hint: []const u8,
    /// The journal run id; names the run in lesson headers.
    run_label: []const u8,
    /// The attempt's final note (unverified, quoted as such).
    final_note: []const u8 = "",
};

pub const Deps = struct {
    kg: *kg_client_mod.KgClient,
    provider: provider_mod.Provider,
    /// Provenance tag for written lessons (the session id), as `KgRemember`.
    session: []const u8 = "",
    abort: ?*const AbortSignal = null,
};

pub const Outcome = struct {
    report: learning_turn.Report,
    /// Provider requests spent: 0 or 1.
    requests: u8 = 0,
    usage: rule_author.Usage = .{},
    /// Why a distill decision wrote nothing it could have (`@errorName`), or null.
    degraded: ?[]const u8 = null,
};

pub const Error = error{
    OutputCapNotEnforcedByProvider,
    PacketTooLarge,
    ToolEventForbidden,
    ResponseTooLarge,
    ResponseIncomplete,
    UsageExceededCaps,
    CostExceededCaps,
};

/// The end-of-run learning turn. Never fails: faults are `Outcome.degraded`.
pub fn run(allocator: std.mem.Allocator, deps: Deps, input: Input) Outcome {
    var state = learning_turn.State{};
    defer state.deinit(allocator);
    state.grounding = input.evidence.grounding;
    const decision = learning_turn.decide(state.grounding, deps.kg.ready);
    state.decision = decision;
    var outcome = Outcome{ .report = state.report(input.mode) };
    if (decision != .distill or input.mode != .enforce) {
        logOutcome(&outcome);
        return outcome;
    }
    state.bind(if (state.grounding == .passed) .passed else .failed, .{
        .mode = input.mode,
        .task_hint = input.task_hint,
        .run_label = input.run_label,
    }, fallbackTraceId(input.run_label));
    distill(allocator, deps, input, &state, &outcome) catch |err| {
        outcome.degraded = @errorName(err);
        log.warn("learning", "end-of-run learning turn degraded: {s}", .{@errorName(err)});
    };
    outcome.report = state.report(input.mode);
    logOutcome(&outcome);
    return outcome;
}

fn distill(allocator: std.mem.Allocator, deps: Deps, input: Input, state: *learning_turn.State, outcome: *Outcome) !void {
    if (deps.provider.maxTokens() > self_evolution.AUTHOR_MAX_OUTPUT_TOKENS)
        return error.OutputCapNotEnforcedByProvider;
    const existing = try lesson.collectForTask(allocator, deps.kg, state.binding.task, learning_turn.MAX_EXISTING_SHOWN);
    defer lesson.freeStored(allocator, existing);
    state.existing = existing.len;
    const packet = try renderPacket(allocator, state, existing, input.evidence.verdict_text orelse "", input.final_note);
    defer allocator.free(packet);
    if (packet.len > MAX_PACKET_BYTES) return error.PacketTooLarge;

    state.startPass(.distill);
    _ = state.beginPassTurn();
    defer state.phase = .idle;
    outcome.requests = 1;
    const response = try request(allocator, deps, packet, &outcome.usage);
    defer allocator.free(response);
    try checkUsage(outcome.usage);
    store(deps, state, response);
    state.distill_accepted = state.binding.acceptedCount();
}

/// One streamed request without tools; returns the response text (owned).
fn request(allocator: std.mem.Allocator, deps: Deps, packet: []const u8, usage: *rule_author.Usage) ![]u8 {
    const api_messages = [_]types.ApiMessage{.{
        .role = .user,
        .content = &[_]types.ApiContent{.{ .text = packet }},
    }};
    var stream = try deps.provider.sendStream(&api_messages, ROLE_PROMPT, null, deps.abort, null, null, "");
    defer stream.deinit();
    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(allocator);
    var saw_done = false;
    while (try stream.next()) |event| switch (event) {
        .text => |bytes| {
            defer allocator.free(bytes);
            if (bytes.len > MAX_RESPONSE_BYTES -| response.items.len) return error.ResponseTooLarge;
            try response.appendSlice(allocator, bytes);
        },
        .thinking => |bytes| allocator.free(bytes),
        .reasoning_item => |bytes| allocator.free(bytes),
        .usage => |delta| {
            usage.input_tokens +|= delta.input_tokens;
            usage.output_tokens +|= delta.output_tokens;
            usage.cache_read_input_tokens +|= delta.cache_read_input_tokens;
            usage.cache_creation_input_tokens +|= delta.cache_creation_input_tokens;
        },
        .done => saw_done = true,
        .tool_use_start => |tool| {
            allocator.free(tool.id);
            allocator.free(tool.name);
            allocator.free(tool.input_json);
            return error.ToolEventForbidden;
        },
        .web_search_query => |query| {
            allocator.free(query);
            return error.ToolEventForbidden;
        },
        .web_search_result => |result| {
            allocator.free(result.ui_text);
            allocator.free(result.content_json);
            return error.ToolEventForbidden;
        },
    };
    if (!saw_done or stream.stopReason() != .end_turn) return error.ResponseIncomplete;
    return response.toOwnedSlice(allocator);
}

/// The self-evolution author caps, checked on what the provider reports.
/// Exceeding them means the request ran outside its permit: nothing is stored.
pub fn checkUsage(usage: rule_author.Usage) Error!void {
    const metered_input = usage.input_tokens +| usage.cache_read_input_tokens +| usage.cache_creation_input_tokens;
    if (metered_input > self_evolution.AUTHOR_MAX_INPUT_TOKENS or usage.output_tokens > self_evolution.AUTHOR_MAX_OUTPUT_TOKENS)
        return error.UsageExceededCaps;
    const cost = rule_author.actualCost(usage, self_evolution.authorPricing()) catch return error.CostExceededCaps;
    if (cost > self_evolution.AUTHOR_MAX_COST_MICROUSD) return error.CostExceededCaps;
}

/// Write every envelope the response carries that the binding admits, within
/// the turn's lesson budget. Refusals are counted, never stored.
fn store(deps: Deps, state: *learning_turn.State, response: []const u8) void {
    const split = splitEnvelopes(response);
    state.lessons_refused +|= @intCast(split.overflow);
    for (split.segments[0..split.count]) |segment| {
        if (!admit(deps.kg, &state.binding, segment)) {
            state.lessons_refused +|= 1;
            continue;
        }
        const node_id = deps.kg.remember(.observation, segment, lesson.SCHEMA_TYPE, false) catch |err| {
            state.binding.release();
            state.lessons_refused +|= 1;
            log.warn("learning", "end-of-run lesson write failed: {s}", .{@errorName(err)});
            continue;
        };
        if (deps.session.len > 0) deps.kg.tagProvenance(node_id, deps.session);
    }
}

/// The `KgRemember` admission rule (`kg_tools.admitLesson`) without a tool
/// context: a parseable envelope, the bound header, a `supersedes:` that names
/// a stored lesson for the task, and a free slot (reserved on success).
fn admit(kg: *kg_client_mod.KgClient, binding: *lesson.Binding, segment: []const u8) bool {
    const envelope = lesson.parse(segment) catch return false;
    lesson.checkBinding(envelope, binding) catch return false;
    if (envelope.supersedes) |target| if (!lesson.isStoredLesson(kg, binding.task, target)) return false;
    return binding.reserve();
}

pub const Split = struct {
    segments: [MAX_SEGMENTS][]const u8 = undefined,
    count: usize = 0,
    /// Envelopes past `MAX_SEGMENTS`.
    overflow: usize = 0,
};

/// Cut the response into envelopes: each starts at a line that begins with
/// the lesson marker and runs to the next such line, a fence line (```) or a
/// `---` rule. Text outside envelopes is commentary and ignored. Every claimed
/// envelope is split out whatever header it claims, so one that names another
/// verdict, task or run reaches the binding check and counts as refused
/// instead of vanishing as prose.
pub fn splitEnvelopes(response: []const u8) Split {
    var out = Split{};
    var start: ?usize = null;
    var offset: usize = 0;
    while (offset <= response.len) {
        const end = std.mem.indexOfScalarPos(u8, response, offset, '\n') orelse response.len;
        const line = std.mem.trim(u8, response[offset..end], " \t\r");
        const opens = std.mem.startsWith(u8, line, lesson.MARKER ++ " ");
        const closes = opens or std.mem.startsWith(u8, line, "```") or std.mem.eql(u8, line, "---");
        if (closes) if (start) |s| {
            push(&out, response[s..offset]);
            start = null;
        };
        if (opens) start = offset;
        if (end == response.len) break;
        offset = end + 1;
    }
    if (start) |s| push(&out, response[s..]);
    return out;
}

fn push(out: *Split, raw: []const u8) void {
    const segment = std.mem.trim(u8, raw, " \t\r\n");
    if (segment.len == 0) return;
    if (out.count == MAX_SEGMENTS) {
        out.overflow += 1;
        return;
    }
    out.segments[out.count] = segment;
    out.count += 1;
}

/// The user message of the one request. Owned.
pub fn renderPacket(
    allocator: std.mem.Allocator,
    state: *const learning_turn.State,
    existing: []const lesson.Stored,
    verdict_text: []const u8,
    final_note: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    var header_buf: [lesson.MAX_TASK_BYTES + 96]u8 = undefined;
    const header = state.binding.header(&header_buf);
    try w.writeAll(MARKER ++ "\nThe attempt is over; its answer and its workspace are final. " ++
        "Record what a fresh attempt at this task should know.\n\n");
    try w.writeAll(if (verdict_text.len > 0) verdict_text else "The host ran the pinned check after the attempt.\n");
    try w.writeByte('\n');
    try w.writeAll(learning_turn.EVIDENCE_BOUNDARY);
    try w.writeAll("\nThe attempt's own final note (its words, verified by nothing):\n");
    const note = std.mem.trim(u8, final_note, " \t\r\n");
    if (note.len == 0) try w.writeAll("(none)\n") else {
        try w.writeAll(lesson.boundedUtf8(note, MAX_FINAL_NOTE_BYTES));
        try w.writeByte('\n');
    }
    try learning_turn.writeExisting(w, existing);
    try w.print(
        "\nReply with 0 to {d} lessons. Each starts on its own line with exactly this header and has these lines, in order:\n" ++
            "{s}\n" ++
            "holds_when: <the condition under which this lesson applies>\n" ++
            "uncertain: <what the evidence did not settle>\n" ++
            "lesson: <what to do or avoid next time, and why, grounded in the verdict>\n" ++
            "supersedes: <node id of a stored lesson above that this one corrects or replaces; omit the line otherwise>\n\n",
        .{ lesson.MAX_PER_TURN, header },
    );
    try w.writeAll("Rules: copy the header exactly; the host stores only lessons under it. ");
    try w.writeAll(learning_turn.verdictRule(state.binding.verdict));
    try w.writeAll("Where this verdict contradicts or narrows a stored lesson, write the corrected lesson with a supersedes line " ++
        "instead of leaving both standing. Make a causal claim only where the evidence supports it; put the rest under uncertain. " ++
        "Write nothing if this attempt taught nothing reusable. Text outside the lessons is ignored.");
    return out.toOwnedSlice();
}

/// Trace id for a run label that is not a header token (the journal run id
/// always is): a hash of the label, so the header stays deterministic.
fn fallbackTraceId(run_label: []const u8) [12]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(run_label, &digest, .{});
    return digest[0..12].*;
}

fn logOutcome(outcome: *const Outcome) void {
    const r = outcome.report;
    log.warn("learning", "end-of-run learning turn enforced={} grounding={s} decision={s} requests={d} lessons={d} refused={d} input_tokens={d} output_tokens={d} degraded={s}", .{
        r.enforced,                  @tagName(r.grounding), @tagName(r.decision),       outcome.requests,
        r.lessons_accepted,          r.lessons_refused,     outcome.usage.input_tokens, outcome.usage.output_tokens,
        outcome.degraded orelse "-",
    });
}

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn reportWith(decision: learning_turn.Decision) learning_turn.Report {
    return .{
        .enforced = true,
        .grounding = .unchecked,
        .decision = decision,
        .passes = 0,
        .distill_turns = 0,
        .reconcile_turns = 0,
        .lessons_accepted = 0,
        .lessons_refused = 0,
        .reconciled = 0,
        .truncated = false,
    };
}

test "modeFor: only a finished attempt whose in-run turn had no verdict" {
    try testing.expectEqual(@as(?learning_turn.Mode, null), modeFor(null, null, true));
    try testing.expectEqual(@as(?learning_turn.Mode, null), modeFor(.enforce, null, false));
    try testing.expectEqual(@as(?learning_turn.Mode, .enforce), modeFor(.enforce, null, true));
    try testing.expectEqual(@as(?learning_turn.Mode, .observe), modeFor(.observe, reportWith(.none_unchecked), true));
    for ([_]learning_turn.Decision{ .distill, .none_tainted, .none_unavailable, .none_unstorable, .none_unfinished }) |decision|
        try testing.expectEqual(@as(?learning_turn.Mode, null), modeFor(.enforce, reportWith(decision), true));
}

test "splitEnvelopes: marker lines open, fences and rules close, prose is ignored" {
    const header = "lesson-v1 verdict=failed task=etag run=r1";
    const response =
        "Here is what I learned.\n" ++
        "```\n" ++
        header ++ "\nholds_when: a\nuncertain: b\nlesson: one\n" ++
        "```\n" ++
        "and another:\n" ++
        header ++ "\r\nholds_when: c\nuncertain: d\nlesson: two\nsupersedes: 9\n" ++
        header ++ "\nholds_when: e\nuncertain: f\nlesson: three\n" ++
        "lesson-v1 verdict=passed task=etag run=r1\nholds_when: g\nuncertain: h\nlesson: a claimed pass";
    const split = splitEnvelopes(response);
    try testing.expectEqual(@as(usize, 4), split.count);
    try testing.expectEqual(@as(usize, 0), split.overflow);
    try testing.expect(std.mem.endsWith(u8, split.segments[0], "lesson: one"));
    try testing.expect(std.mem.endsWith(u8, split.segments[1], "supersedes: 9"));
    try testing.expect(std.mem.endsWith(u8, split.segments[2], "lesson: three"));
    // Another header is still an envelope: the binding check refuses it.
    try testing.expect(std.mem.startsWith(u8, split.segments[3], "lesson-v1 verdict=passed"));
    try testing.expectEqual(@as(usize, 0), splitEnvelopes("no lessons this time").count);
}

test "splitEnvelopes: envelopes past MAX_SEGMENTS overflow" {
    const header = "lesson-v1 verdict=passed task=- run=r1";
    const one = header ++ "\nholds_when: a\nuncertain: b\nlesson: c\n";
    const response = one ** (MAX_SEGMENTS + 2);
    const split = splitEnvelopes(response);
    try testing.expectEqual(MAX_SEGMENTS, split.count);
    try testing.expectEqual(@as(usize, 2), split.overflow);
}

test "checkUsage: the author caps bound tokens and cost" {
    try checkUsage(.{ .input_tokens = 1000, .output_tokens = 500 });
    try testing.expectError(error.UsageExceededCaps, checkUsage(.{ .input_tokens = self_evolution.AUTHOR_MAX_INPUT_TOKENS + 1 }));
    try testing.expectError(error.UsageExceededCaps, checkUsage(.{ .input_tokens = 10, .cache_read_input_tokens = self_evolution.AUTHOR_MAX_INPUT_TOKENS }));
    try testing.expectError(error.UsageExceededCaps, checkUsage(.{ .output_tokens = self_evolution.AUTHOR_MAX_OUTPUT_TOKENS + 1 }));
    // The caps themselves fit the cost ceiling (the self-evolution budget).
    try checkUsage(.{ .input_tokens = self_evolution.AUTHOR_MAX_INPUT_TOKENS, .output_tokens = self_evolution.AUTHOR_MAX_OUTPUT_TOKENS });
}

test "renderPacket: binds the header, quotes the note as unverified, states the contract" {
    const a = testing.allocator;
    var state = learning_turn.State{};
    defer state.deinit(a);
    state.bind(.failed, .{ .mode = .enforce, .task_hint = "etag", .run_label = "run-1" }, .{0} ** 12);
    const packet = try renderPacket(a, &state, &.{}, "Result: FAILED (exit code 1).\n", "I fixed it, all good");
    defer a.free(packet);
    try testing.expect(std.mem.startsWith(u8, packet, MARKER));
    try testing.expect(std.mem.indexOf(u8, packet, "lesson-v1 verdict=failed task=etag run=run-1\n") != null);
    try testing.expect(std.mem.indexOf(u8, packet, "Result: FAILED") != null);
    try testing.expect(std.mem.indexOf(u8, packet, "verified by nothing):\nI fixed it, all good\n") != null);
    try testing.expect(std.mem.indexOf(u8, packet, "never a claim that it works") != null);
    try testing.expect(std.mem.indexOf(u8, packet, "(none)") != null);
    try testing.expect(packet.len <= MAX_PACKET_BYTES);
}
