//! Lesson envelope: the TinyKG node a learning turn writes after a host
//! verdict (doc/LEARNING_TURN_DESIGN.md §2.3).
//!
//! A lesson is an `observation` node with schema type `lesson` whose text is
//! one fixed header line plus three labelled lines:
//!
//!   lesson-v1 verdict=<passed|failed> task=<hint or -> run=<run id>
//!   holds_when: <the condition under which this lesson applies>
//!   uncertain: <what the evidence did not settle>
//!   lesson: <the lesson; may continue on further lines>
//!   supersedes: <node id>            (optional, last line)
//!
//! The header is host-attested. `KgRemember` accepts kind `lesson` only while
//! a learning turn holds a `Binding`, and only when the header equals the
//! binding's verdict, task and run byte for byte, so a stored lesson's
//! verdict is always the verdict the host saw. Everything below the header is
//! the model's own words and stays advisory: a lesson never changes
//! permissions, tool dispatch or the system prompt; its only reader is the
//! next attempt's recall injection.
//!
//! This module is shared by the learning turn (`core/learning_turn.zig`), the
//! `KgRemember` tool, and the same-task injection (`kg/scoped_recall.zig`), so
//! the writer and the readers parse one format.

const std = @import("std");
const client_mod = @import("client.zig");
const utf8 = @import("metacodes-base").util.utf8;

pub const SCHEMA_TYPE = "lesson";
pub const MARKER = "lesson-v1";
/// Lessons a single learning turn may write (design §2.3).
pub const MAX_PER_TURN: u8 = 4;
/// Whole envelope, header included.
pub const MAX_BYTES: usize = 2048;
pub const MAX_TASK_BYTES: usize = 200;
pub const MAX_RUN_BYTES: usize = 64;
/// Stored lessons the readers look at per task. Bounded by TinyKG's search
/// limit (the client over-fetches 2L+4; see self_evolution.MAX_OUTCOME_ROWS).
pub const RECALL_LIMIT: usize = 40;
/// Stored lessons shown to a reader, newest first.
pub const MAX_SHOWN: usize = 3;
/// Bytes of `lesson:` shown per lesson in the injected note.
pub const SHOWN_LESSON_BYTES: usize = 320;
/// The task token for a lesson with no task: a project-wide lesson.
pub const NO_TASK = "-";

pub const Verdict = enum { passed, failed };

pub const ParseError = error{
    TooLarge,
    MissingHeader,
    BadHeader,
    BadVerdict,
    BadTask,
    BadRun,
    MissingHoldsWhen,
    MissingUncertain,
    MissingLesson,
    BadSupersedes,
};

/// A parsed envelope. Every slice borrows the parsed text.
pub const Envelope = struct {
    verdict: Verdict,
    task: []const u8,
    run: []const u8,
    holds_when: []const u8,
    uncertain: []const u8,
    lesson: []const u8,
    supersedes: ?u64 = null,
};

/// A task hint usable as a header token: printable ASCII without spaces, at
/// most `MAX_TASK_BYTES`. Anything else (absent, spaced, too long) makes the
/// lesson project-wide.
pub fn taskToken(hint: []const u8) []const u8 {
    if (validTask(hint)) return hint;
    return NO_TASK;
}

fn validTask(task: []const u8) bool {
    if (task.len == 0 or task.len > MAX_TASK_BYTES) return false;
    for (task) |c| if (c <= ' ' or c >= 0x7f) return false;
    return true;
}

pub fn validRun(run: []const u8) bool {
    if (run.len == 0 or run.len > MAX_RUN_BYTES) return false;
    for (run) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn stripCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

/// The value of `label: value` on `line`, trimmed and non-empty, or null.
fn labelled(line: []const u8, label: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, label)) return null;
    const rest = line[label.len..];
    if (rest.len == 0 or rest[0] != ':') return null;
    const value = std.mem.trim(u8, rest[1..], " \t");
    return if (value.len == 0) null else value;
}

const Header = struct { verdict: Verdict, task: []const u8, run: []const u8 };

/// The `lesson-v1 verdict= task= run=` line, strictly.
fn parseHeader(header: []const u8) ParseError!Header {
    var tokens = std.mem.splitScalar(u8, header, ' ');
    if (!std.mem.eql(u8, tokens.next() orelse "", MARKER)) return error.MissingHeader;
    const verdict_token = tokens.next() orelse return error.BadHeader;
    const task_token = tokens.next() orelse return error.BadHeader;
    const run_token = tokens.next() orelse return error.BadHeader;
    if (tokens.next() != null) return error.BadHeader;
    if (!std.mem.startsWith(u8, verdict_token, "verdict=")) return error.BadHeader;
    if (!std.mem.startsWith(u8, task_token, "task=")) return error.BadHeader;
    if (!std.mem.startsWith(u8, run_token, "run=")) return error.BadHeader;
    const verdict = std.meta.stringToEnum(Verdict, verdict_token["verdict=".len..]) orelse return error.BadVerdict;
    const task = task_token["task=".len..];
    if (!std.mem.eql(u8, task, NO_TASK) and !validTask(task)) return error.BadTask;
    const run = run_token["run=".len..];
    if (!validRun(run)) return error.BadRun;
    return .{ .verdict = verdict, .task = task, .run = run };
}

/// Parse one envelope. Strict: the header and the three required lines come
/// first, in order; `supersedes:` may only be the last non-empty line.
pub fn parse(text: []const u8) ParseError!Envelope {
    if (text.len > MAX_BYTES) return error.TooLarge;
    const body = std.mem.trim(u8, text, " \t\r\n");
    var lines = std.mem.splitScalar(u8, body, '\n');
    const header = try parseHeader(stripCr(lines.next() orelse return error.MissingHeader));

    const holds_when = labelled(stripCr(lines.next() orelse ""), "holds_when") orelse return error.MissingHoldsWhen;
    const uncertain = labelled(stripCr(lines.next() orelse ""), "uncertain") orelse return error.MissingUncertain;
    // The body may start on the `lesson:` line or on the next one.
    const lesson_line = lines.next() orelse return error.MissingLesson;
    if (!std.mem.startsWith(u8, lesson_line, "lesson:")) return error.MissingLesson;

    // `lesson:` runs to the end, minus an optional final `supersedes:` line.
    const lesson_start = (@intFromPtr(lesson_line.ptr) - @intFromPtr(body.ptr)) + "lesson:".len;
    var lesson_end = body.len;
    var supersedes: ?u64 = null;
    if (std.mem.lastIndexOfScalar(u8, body, '\n')) |last_newline| {
        if (last_newline + 1 > lesson_start) {
            const last = stripCr(body[last_newline + 1 ..]);
            // Only the labelled field counts; prose that merely starts with
            // the word stays part of the lesson.
            if (std.mem.startsWith(u8, last, "supersedes:")) {
                const value = labelled(last, "supersedes") orelse return error.BadSupersedes;
                supersedes = std.fmt.parseInt(u64, value, 10) catch return error.BadSupersedes;
                if (supersedes.? == 0) return error.BadSupersedes;
                lesson_end = last_newline;
            }
        }
    }
    const lesson = std.mem.trim(u8, body[lesson_start..lesson_end], " \t\r\n");
    if (lesson.len == 0) return error.MissingLesson;
    return .{
        .verdict = header.verdict,
        .task = header.task,
        .run = header.run,
        .holds_when = holds_when,
        .uncertain = uncertain,
        .lesson = lesson,
        .supersedes = supersedes,
    };
}

/// What a learning turn lets `KgRemember` write. Lives in the agent loop's
/// learning state for the duration of one learning turn; the tool reads it
/// through `ToolContext.lesson_binding`.
pub const Binding = struct {
    verdict: Verdict,
    /// Already a valid header token (`taskToken`).
    task: []const u8,
    run: []const u8,
    /// Lessons accepted so far in this learning turn. Atomic: KgRemember calls
    /// in one assistant message may run concurrently.
    accepted: std.atomic.Value(u8) = .init(0),

    /// The exact header line a lesson under this binding must start with.
    pub fn header(self: *const Binding, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, MARKER ++ " verdict={s} task={s} run={s}", .{ @tagName(self.verdict), self.task, self.run }) catch "";
    }

    /// Reserve one of the turn's `MAX_PER_TURN` slots. False when spent.
    pub fn reserve(self: *Binding) bool {
        var current = self.accepted.load(.acquire);
        while (current < MAX_PER_TURN) {
            current = self.accepted.cmpxchgWeak(current, current + 1, .acq_rel, .acquire) orelse return true;
        }
        return false;
    }

    /// Give back a slot reserved for a write that then failed.
    pub fn release(self: *Binding) void {
        _ = self.accepted.fetchSub(1, .acq_rel);
    }

    pub fn acceptedCount(self: *const Binding) u8 {
        return self.accepted.load(.acquire);
    }
};

pub const BindError = error{ VerdictMismatch, TaskMismatch, RunMismatch };

/// The envelope's header must be exactly the binding's.
pub fn checkBinding(envelope: Envelope, binding: *const Binding) BindError!void {
    if (envelope.verdict != binding.verdict) return error.VerdictMismatch;
    if (!std.mem.eql(u8, envelope.task, binding.task)) return error.TaskMismatch;
    if (!std.mem.eql(u8, envelope.run, binding.run)) return error.RunMismatch;
}

/// One stored lesson for a reader. Owns its text; the envelope fields borrow it.
pub const Stored = struct {
    node_id: u64,
    text: []u8,
    envelope: Envelope,

    pub fn deinit(self: *Stored, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub fn freeStored(allocator: std.mem.Allocator, items: []Stored) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

/// Pure selection over parsed candidates: lessons for `task`, minus every
/// lesson another candidate supersedes, newest (highest node id) first, at
/// most `max`. Returns indexes into `candidates`.
pub fn select(candidates: []const Stored, task: []const u8, max: usize, out: []usize) usize {
    var count: usize = 0;
    // Newest first: repeatedly take the highest unseen node id.
    var taken = std.StaticBitSet(RECALL_LIMIT * 2).initEmpty();
    while (count < max and count < out.len) {
        var best: ?usize = null;
        for (candidates, 0..) |candidate, index| {
            if (index >= RECALL_LIMIT * 2 or taken.isSet(index)) continue;
            if (!std.mem.eql(u8, candidate.envelope.task, task)) continue;
            if (isSuperseded(candidates, candidate.node_id)) continue;
            if (best == null or candidate.node_id > candidates[best.?].node_id) best = index;
        }
        const index = best orelse break;
        taken.set(index);
        out[count] = index;
        count += 1;
    }
    return count;
}

fn isSuperseded(candidates: []const Stored, node_id: u64) bool {
    for (candidates) |candidate| {
        if (candidate.envelope.supersedes) |target| if (target == node_id) return true;
    }
    return false;
}

/// Every parseable stored lesson for `task`, newest first, superseded ones
/// dropped, at most `max`. Best effort: a recall failure is an empty result.
/// Owned by `allocator`.
pub fn collectForTask(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    task: []const u8,
    max: usize,
) ![]Stored {
    var query_buffer: [MAX_TASK_BYTES + 32]u8 = undefined;
    const query = std.fmt.bufPrint(&query_buffer, MARKER ++ " task={s}", .{task}) catch return allocator.alloc(Stored, 0);
    const hits = kg.recallTyped(query, RECALL_LIMIT, false, SCHEMA_TYPE) catch return allocator.alloc(Stored, 0);
    defer {
        for (hits) |*hit| hit.deinit(kg.allocator);
        kg.allocator.free(hits);
    }
    var candidates: std.ArrayList(Stored) = .empty;
    defer {
        for (candidates.items) |*item| item.deinit(allocator);
        candidates.deinit(allocator);
    }
    for (hits) |hit| {
        if (!std.mem.eql(u8, hit.schema_type, SCHEMA_TYPE)) continue;
        const text: []u8 = if (hit.text_truncated) blk: {
            const full = kg.fetchNodeText(hit.node_id) catch continue;
            defer kg.allocator.free(full);
            break :blk try allocator.dupe(u8, full);
        } else try allocator.dupe(u8, hit.text);
        const envelope = parse(text) catch {
            allocator.free(text);
            continue;
        };
        candidates.append(allocator, .{ .node_id = hit.node_id, .text = text, .envelope = envelope }) catch |err| {
            allocator.free(text);
            return err;
        };
    }
    var picked: [RECALL_LIMIT]usize = undefined;
    const n = select(candidates.items, task, @min(max, picked.len), &picked);
    const out = try allocator.alloc(Stored, n);
    // Move the picked candidates out (their envelopes already borrow their
    // own text); the emptied slots free nothing in the deferred cleanup.
    for (picked[0..n], 0..) |index, slot| {
        out[slot] = candidates.items[index];
        candidates.items[index].text = &.{};
    }
    return out;
}

/// True when `node_id` is a stored `lesson` node for `task` that a reader
/// would see: the same schema-filtered recall `collectForTask` uses, so a
/// `supersedes:` can only name a lesson the next attempt could have been
/// shown. Best effort: a recall failure is false.
pub fn isStoredLesson(kg: *client_mod.KgClient, task: []const u8, node_id: u64) bool {
    var query_buffer: [MAX_TASK_BYTES + 32]u8 = undefined;
    const query = std.fmt.bufPrint(&query_buffer, MARKER ++ " task={s}", .{task}) catch return false;
    const hits = kg.recallTyped(query, RECALL_LIMIT, false, SCHEMA_TYPE) catch return false;
    defer {
        for (hits) |*hit| hit.deinit(kg.allocator);
        kg.allocator.free(hits);
    }
    for (hits) |hit| {
        if (hit.node_id != node_id or !std.mem.eql(u8, hit.schema_type, SCHEMA_TYPE)) continue;
        // The header is the excerpt's first line, so a truncated excerpt still carries it.
        var lines = std.mem.splitScalar(u8, hit.text, '\n');
        const header = parseHeader(stripCr(lines.next() orelse return false)) catch return false;
        return std.mem.eql(u8, header.task, task);
    }
    return false;
}

/// Truncate to at most `max` bytes on a UTF-8 boundary.
pub fn boundedUtf8(text: []const u8, max: usize) []const u8 {
    return text[0..utf8.prefixEnd(text, max)];
}

pub const NOTE_HEADING = "# Lessons from earlier attempts at this task";

/// The same-task note the next attempt sees: newest lessons first, each as
/// its verdict, condition and the head of its body. Framed as hypotheses to
/// test, never as instructions. Empty input renders nothing (null).
pub fn renderNote(allocator: std.mem.Allocator, lessons: []const Stored) !?[]u8 {
    if (lessons.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("<system-reminder>\n" ++ NOTE_HEADING ++ "\n");
    try w.writeAll("Written by the model after a host verdict on an earlier attempt; verified by nothing since. " ++
        "Treat each as a hypothesis about when an approach works, check it against the workspace before relying on it, " ++
        "and prefer the current evidence when they disagree.\n");
    for (lessons) |stored| {
        const env = stored.envelope;
        try w.print("- [{s}, node {d}] holds when: ", .{ @tagName(env.verdict), stored.node_id });
        try writeOneLine(w, boundedUtf8(env.holds_when, 200));
        try w.writeAll("\n  lesson: ");
        try writeOneLine(w, boundedUtf8(env.lesson, SHOWN_LESSON_BYTES));
        if (env.lesson.len > SHOWN_LESSON_BYTES) try w.writeAll(" …");
        try w.writeAll("\n  uncertain: ");
        try writeOneLine(w, boundedUtf8(env.uncertain, 200));
        try w.writeByte('\n');
    }
    try w.writeAll("</system-reminder>\n");
    return try out.toOwnedSlice();
}

/// `text` on one line: newlines and tabs become spaces.
pub fn writeOneLine(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| try w.writeByte(if (c == '\n' or c == '\r' or c == '\t') ' ' else c);
}

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

const GOOD =
    \\lesson-v1 verdict=failed task=etag run=abc123
    \\holds_when: the parser reads quoted ETags from a weak validator
    \\uncertain: whether strong comparison is also affected
    \\lesson: strip the W/ prefix before comparing;
    \\the test named test_weak_match failed on the raw string.
;

test "parse accepts the canonical envelope and keeps a multi-line lesson" {
    const env = try parse(GOOD);
    try testing.expectEqual(Verdict.failed, env.verdict);
    try testing.expectEqualStrings("etag", env.task);
    try testing.expectEqualStrings("abc123", env.run);
    try testing.expectEqualStrings("the parser reads quoted ETags from a weak validator", env.holds_when);
    try testing.expectEqualStrings("whether strong comparison is also affected", env.uncertain);
    try testing.expect(std.mem.indexOf(u8, env.lesson, "test_weak_match") != null);
    try testing.expect(std.mem.startsWith(u8, env.lesson, "strip the W/"));
    try testing.expect(env.supersedes == null);
}

test "parse reads a final supersedes line and keeps it out of the lesson" {
    const text = GOOD ++ "\nsupersedes: 42";
    const env = try parse(text);
    try testing.expectEqual(@as(?u64, 42), env.supersedes);
    try testing.expect(std.mem.indexOf(u8, env.lesson, "supersedes") == null);
}

test "a last line that only starts with the word supersedes stays in the lesson" {
    const env = try parse(GOOD ++ "\nsupersedes the earlier guess about weak tags");
    try testing.expect(env.supersedes == null);
    try testing.expect(std.mem.endsWith(u8, env.lesson, "weak tags"));
}

test "parse rejects each contract violation" {
    try testing.expectError(error.MissingHeader, parse("holds_when: x\nuncertain: y\nlesson: z"));
    try testing.expectError(error.BadVerdict, parse("lesson-v1 verdict=tainted task=t run=r\nholds_when: x\nuncertain: y\nlesson: z"));
    try testing.expectError(error.BadHeader, parse("lesson-v1 verdict=passed task=t\nholds_when: x\nuncertain: y\nlesson: z"));
    try testing.expectError(error.BadRun, parse("lesson-v1 verdict=passed task=t run=a/b\nholds_when: x\nuncertain: y\nlesson: z"));
    try testing.expectError(error.MissingHoldsWhen, parse("lesson-v1 verdict=passed task=t run=r\nholds_when:\nuncertain: y\nlesson: z"));
    try testing.expectError(error.MissingUncertain, parse("lesson-v1 verdict=passed task=t run=r\nholds_when: x\nlesson: z"));
    try testing.expectError(error.MissingLesson, parse("lesson-v1 verdict=passed task=t run=r\nholds_when: x\nuncertain: y\nlesson:   "));
    try testing.expectError(error.BadSupersedes, parse("lesson-v1 verdict=passed task=t run=r\nholds_when: x\nuncertain: y\nlesson: z\nsupersedes: soon"));
    const huge = [_]u8{'a'} ** (MAX_BYTES + 1);
    try testing.expectError(error.TooLarge, parse(&huge));
}

test "taskToken keeps a clean hint and makes anything else project-wide" {
    try testing.expectEqualStrings("etag-v2", taskToken("etag-v2"));
    try testing.expectEqualStrings(NO_TASK, taskToken(""));
    try testing.expectEqualStrings(NO_TASK, taskToken("two words"));
}

test "binding: header is exact, mismatches are refused, slots are bounded" {
    var binding = Binding{ .verdict = .failed, .task = "etag", .run = "abc123" };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("lesson-v1 verdict=failed task=etag run=abc123", binding.header(&buf));
    try checkBinding(try parse(GOOD), &binding);
    const lying = "lesson-v1 verdict=passed task=etag run=abc123\nholds_when: x\nuncertain: y\nlesson: it works";
    try testing.expectError(error.VerdictMismatch, checkBinding(try parse(lying), &binding));
    const other_run = "lesson-v1 verdict=failed task=etag run=zzz\nholds_when: x\nuncertain: y\nlesson: z";
    try testing.expectError(error.RunMismatch, checkBinding(try parse(other_run), &binding));
    for (0..MAX_PER_TURN) |_| try testing.expect(binding.reserve());
    try testing.expect(!binding.reserve());
    binding.release();
    try testing.expect(binding.reserve());
    try testing.expectEqual(MAX_PER_TURN, binding.acceptedCount());
}

fn storedFor(allocator: std.mem.Allocator, node_id: u64, text: []const u8) !Stored {
    const owned = try allocator.dupe(u8, text);
    return .{ .node_id = node_id, .text = owned, .envelope = try parse(owned) };
}

test "select: same task only, superseded dropped, newest first, bounded" {
    const a = testing.allocator;
    var items = [_]Stored{
        try storedFor(a, 10, "lesson-v1 verdict=failed task=etag run=r1\nholds_when: a\nuncertain: b\nlesson: old"),
        try storedFor(a, 12, "lesson-v1 verdict=failed task=etag run=r2\nholds_when: a\nuncertain: b\nlesson: newer\nsupersedes: 10"),
        try storedFor(a, 11, "lesson-v1 verdict=passed task=other run=r3\nholds_when: a\nuncertain: b\nlesson: elsewhere"),
        try storedFor(a, 13, "lesson-v1 verdict=passed task=etag run=r4\nholds_when: a\nuncertain: b\nlesson: newest"),
        try storedFor(a, 9, "lesson-v1 verdict=passed task=etag run=r0\nholds_when: a\nuncertain: b\nlesson: oldest"),
    };
    defer for (&items) |*item| item.deinit(a);
    var out: [8]usize = undefined;
    const n = select(&items, "etag", 2, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u64, 13), items[out[0]].node_id);
    try testing.expectEqual(@as(u64, 12), items[out[1]].node_id);
    const all = select(&items, "etag", 8, &out);
    try testing.expectEqual(@as(usize, 3), all); // 10 is superseded, 11 is another task
}

test "renderNote: nothing for no lessons; hypotheses framing and bounded bodies otherwise" {
    const a = testing.allocator;
    try testing.expect((try renderNote(a, &.{})) == null);
    const long_body = "x" ** (SHOWN_LESSON_BYTES + 50);
    var items = [_]Stored{
        try storedFor(a, 7, "lesson-v1 verdict=failed task=etag run=r1\nholds_when: weak validators\nuncertain: strong ones\nlesson: " ++ long_body),
    };
    defer for (&items) |*item| item.deinit(a);
    const note = (try renderNote(a, &items)).?;
    defer a.free(note);
    try testing.expect(std.mem.startsWith(u8, note, "<system-reminder>\n" ++ NOTE_HEADING));
    try testing.expect(std.mem.indexOf(u8, note, "[failed, node 7] holds when: weak validators") != null);
    try testing.expect(std.mem.indexOf(u8, note, "hypothesis") != null);
    try testing.expect(std.mem.indexOf(u8, note, "x" ** (SHOWN_LESSON_BYTES + 1)) == null);
    try testing.expect(std.mem.endsWith(u8, note, "</system-reminder>\n"));
}
