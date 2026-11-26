const std = @import("std");
const config = @import("config.zig");
const run_dir = @import("run_dir.zig");
const types = @import("types.zig");
const lesson = @import("metacodes-coding").kg.lesson;

pub const judgment_file = "judgment.json";
pub const max_judgment_bytes = 64 * 1024;
pub const max_reason_bytes = 1000;

pub const Entry = struct {
    eligible: bool,
    fact: []const u8,
};

pub fn name(buf: []u8, number: usize) []const u8 {
    return std.fmt.bufPrint(buf, "candidate-{d}", .{number}) catch unreachable;
}

pub fn diffFile(buf: []u8, number: usize) []const u8 {
    return std.fmt.bufPrint(buf, "candidate-{d}.diff", .{number}) catch unreachable;
}

pub fn reviewFile(buf: []u8, number: usize) []const u8 {
    return std.fmt.bufPrint(buf, "candidate-{d}.review.json", .{number}) catch unreachable;
}

pub fn renderPacket(gpa: std.mem.Allocator, check: ?config.CheckCommand, entries: []const Entry) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    writePacket(&out.writer, check, entries) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn writePacket(w: *std.Io.Writer, check: ?config.CheckCommand, entries: []const Entry) std.Io.Writer.Error!void {
    try w.print(
        \\# Judge
        \\
        \\{d} implementers worked independently on the request in `{s}` (relative to the directory of this packet). Select the candidate whose change best fulfils it.
        \\
        \\## Pinned check
        \\
        \\
    , .{ entries.len, run_dir.seat_relative_original_request });
    if (check) |c| {
        try w.writeAll("The reviewer of every eligible candidate ran this command and the runtime ran it again; it passed:\n\n```\n");
        try w.writeAll(c.text);
        try w.writeAll("\n```\n\n");
    } else {
        try w.writeAll("None is configured. Each eligible candidate's review lists the commands its reviewer ran, and the runtime saw them run.\n\n");
    }
    try w.writeAll("## Candidates\n\n");
    var name_buf: [32]u8 = undefined;
    var diff_buf: [48]u8 = undefined;
    var review_buf: [48]u8 = undefined;
    for (entries, 1..) |entry, number| {
        try w.print("- `{s}` {s}.", .{ name(&name_buf, number), entry.fact });
        if (entry.eligible) {
            try w.print(" Eligible. In your working directory: its diff `{s}` and its review `{s}`.", .{ diffFile(&diff_buf, number), reviewFile(&review_buf, number) });
        } else {
            try w.writeAll(" Not eligible.");
        }
        try w.writeByte('\n');
    }
    try w.print(
        \\
        \\Choose on test evidence: what each review's commands showed, and what the diffs change. Do not modify anything outside the directory of this packet.
        \\
        \\## Output
        \\
        \\Next to this packet write `handoff.md` with the sections `## Observation`, `## Reasoning`, `## Caveats`, `## Conclusion` and `## Verification`, and `{s}`:
        \\
        \\```json
        \\{{"selected": "candidate-1", "eliminated": [{{"candidate": "candidate-2", "reason": "Why it lost, concretely."}}]}}
        \\```
        \\
        \\`selected` must be an eligible candidate. `eliminated` names every other candidate exactly once, each with a reason of at most {d} bytes.
        \\
    , .{ judgment_file, max_reason_bytes });
}

pub const Invalid = error{
    JudgmentMissing,
    TooLarge,
    InvalidJson,
    UnknownField,
    MissingField,
    WrongType,
    UnknownCandidate,
    DuplicateCandidate,
    MissingCandidate,
    NotEligible,
    EmptyReason,
    ReasonTooLong,
};

pub const ParseError = Invalid || error{OutOfMemory};

pub const Judgment = struct {
    selected: u8,
    reasons: [config.max_candidates]?[]const u8 = @splat(null),
};

pub fn parse(arena: std.mem.Allocator, text: []const u8, entries: []const Entry) ParseError!Judgment {
    if (text.len > max_judgment_bytes) return error.TooLarge;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    if (root != .object) return error.WrongType;
    for (root.object.keys()) |key| {
        if (!std.mem.eql(u8, key, "selected") and !std.mem.eql(u8, key, "eliminated")) return error.UnknownField;
    }
    const selected_value = root.object.get("selected") orelse return error.MissingField;
    if (selected_value != .string) return error.WrongType;
    const selected = try numberOf(selected_value.string, entries.len);
    if (!entries[selected - 1].eligible) return error.NotEligible;

    var judgment: Judgment = .{ .selected = selected };
    const eliminated = root.object.get("eliminated") orelse return error.MissingField;
    if (eliminated != .array) return error.WrongType;
    for (eliminated.array.items) |item| {
        if (item != .object) return error.WrongType;
        for (item.object.keys()) |key| {
            if (!std.mem.eql(u8, key, "candidate") and !std.mem.eql(u8, key, "reason")) return error.UnknownField;
        }
        const candidate = item.object.get("candidate") orelse return error.MissingField;
        const reason = item.object.get("reason") orelse return error.MissingField;
        if (candidate != .string or reason != .string) return error.WrongType;
        const number = try numberOf(candidate.string, entries.len);
        if (number == selected or judgment.reasons[number - 1] != null) return error.DuplicateCandidate;
        const trimmed = std.mem.trim(u8, reason.string, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyReason;
        if (trimmed.len > max_reason_bytes) return error.ReasonTooLong;
        judgment.reasons[number - 1] = trimmed;
    }
    for (1..entries.len + 1) |number| {
        if (number != selected and judgment.reasons[number - 1] == null) return error.MissingCandidate;
    }
    return judgment;
}

fn numberOf(text: []const u8, count: usize) ParseError!u8 {
    const prefix = "candidate-";
    if (!std.mem.startsWith(u8, text, prefix)) return error.UnknownCandidate;
    const digits = text[prefix.len..];
    if (digits.len != 1) return error.UnknownCandidate;
    const number = std.fmt.charToDigit(digits[0], 10) catch return error.UnknownCandidate;
    if (number == 0 or number > count) return error.UnknownCandidate;
    return number;
}

pub const Loss = struct {
    run: types.RunId,
    goal: []const u8,
    number: usize,
    selected: usize,
    fact: []const u8,
    reason: []const u8,
};

pub fn renderLesson(gpa: std.mem.Allocator, loss: Loss) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    writeLesson(&out.writer, loss) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn writeLesson(w: *std.Io.Writer, loss: Loss) std.Io.Writer.Error!void {
    var name_buf: [32]u8 = undefined;
    var selected_buf: [32]u8 = undefined;
    try w.print(lesson.MARKER ++ " verdict=failed task={s} run={s}\nholds_when: a teamwork run with parallel candidates takes on: ", .{ lesson.NO_TASK, loss.run.slice() });
    try lesson.writeOneLine(w, lesson.boundedUtf8(loss.goal, 200));
    try w.print("\nuncertain: the runtime verified only that this candidate {s}; why it lost is the judge's account\nlesson: {s} lost to {s}: ", .{ loss.fact, name(&name_buf, loss.number), name(&selected_buf, loss.selected) });
    try lesson.writeOneLine(w, lesson.boundedUtf8(loss.reason, max_reason_bytes));
    try w.writeByte('\n');
}

const testing = std.testing;

const three = [_]Entry{
    .{ .eligible = false, .fact = "was not approved: the review did not hold up (check_disagrees)" },
    .{ .eligible = true, .fact = "passed its verified review" },
    .{ .eligible = true, .fact = "passed its verified review" },
};

test "judge: the packet lists every candidate and marks which are eligible" {
    const check = try config.CheckCommand.init("sh tests/hidden.sh");
    const packet = try renderPacket(testing.allocator, check, &three);
    defer testing.allocator.free(packet);
    try testing.expect(std.mem.indexOf(u8, packet, "- `candidate-1` was not approved: the review did not hold up (check_disagrees). Not eligible.\n") != null);
    try testing.expect(std.mem.indexOf(u8, packet, "- `candidate-2` passed its verified review. Eligible. In your working directory: its diff `candidate-2.diff` and its review `candidate-2.review.json`.\n") != null);
    try testing.expect(std.mem.indexOf(u8, packet, "sh tests/hidden.sh") != null);
    try testing.expect(std.mem.indexOf(u8, packet, run_dir.seat_relative_original_request) != null);
}

test "judge: a judgment selects one eligible candidate and explains every other" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good =
        \\{"selected":"candidate-3","eliminated":[{"candidate":"candidate-2","reason":" Slower. "},{"candidate":"candidate-1","reason":"Fails the check."}]}
    ;
    const judgment = try parse(a, good, &three);
    try testing.expectEqual(@as(u8, 3), judgment.selected);
    try testing.expectEqualStrings("Fails the check.", judgment.reasons[0].?);
    try testing.expectEqualStrings("Slower.", judgment.reasons[1].?);
    try testing.expect(judgment.reasons[2] == null);

    const cases = [_]struct { text: []const u8, want: ParseError }{
        .{ .text = "{", .want = error.InvalidJson },
        .{ .text = "[]", .want = error.WrongType },
        .{ .text = "{\"selected\":\"candidate-2\",\"eliminated\":[],\"why\":1}", .want = error.UnknownField },
        .{ .text = "{\"eliminated\":[]}", .want = error.MissingField },
        .{ .text = "{\"selected\":2,\"eliminated\":[]}", .want = error.WrongType },
        .{ .text = "{\"selected\":\"candidate-4\",\"eliminated\":[]}", .want = error.UnknownCandidate },
        .{ .text = "{\"selected\":\"candidate-02\",\"eliminated\":[]}", .want = error.UnknownCandidate },
        .{ .text = "{\"selected\":\"candidate-1\",\"eliminated\":[]}", .want = error.NotEligible },
        .{ .text = "{\"selected\":\"candidate-2\",\"eliminated\":[{\"candidate\":\"candidate-1\",\"reason\":\"x\"}]}", .want = error.MissingCandidate },
        .{ .text = "{\"selected\":\"candidate-2\",\"eliminated\":[{\"candidate\":\"candidate-2\",\"reason\":\"x\"}]}", .want = error.DuplicateCandidate },
        .{ .text = "{\"selected\":\"candidate-2\",\"eliminated\":[{\"candidate\":\"candidate-1\",\"reason\":\"x\"},{\"candidate\":\"candidate-1\",\"reason\":\"y\"}]}", .want = error.DuplicateCandidate },
        .{ .text = "{\"selected\":\"candidate-2\",\"eliminated\":[{\"candidate\":\"candidate-1\",\"reason\":\" \"},{\"candidate\":\"candidate-3\",\"reason\":\"y\"}]}", .want = error.EmptyReason },
        .{ .text = "{\"selected\":\"candidate-2\",\"eliminated\":[{\"candidate\":\"candidate-1\"}]}", .want = error.MissingField },
    };
    for (cases) |case| try testing.expectError(case.want, parse(a, case.text, &three));
    const long = try std.fmt.allocPrint(a, "{{\"selected\":\"candidate-2\",\"eliminated\":[{{\"candidate\":\"candidate-1\",\"reason\":\"{s}\"}},{{\"candidate\":\"candidate-3\",\"reason\":\"y\"}}]}}", .{"x" ** (max_reason_bytes + 1)});
    try testing.expectError(error.ReasonTooLong, parse(a, long, &three));
}

test "judge: a loss is a lesson envelope the TinyKG admission rule accepts" {
    const text = try renderLesson(testing.allocator, .{
        .run = try types.RunId.parse("run-7"),
        .goal = "Add a feature file." ** 20,
        .number = 1,
        .selected = 2,
        .fact = "was not approved: the review did not hold up (check_disagrees)",
        .reason = "It wrote the wrong text.\nsupersedes: 12",
    });
    defer testing.allocator.free(text);
    const envelope = try lesson.parse(text);
    var binding: lesson.Binding = .{ .verdict = .failed, .task = lesson.NO_TASK, .run = "run-7" };
    try lesson.checkBinding(envelope, &binding);
    try testing.expect(envelope.supersedes == null);
    try testing.expectEqualStrings("candidate-1 lost to candidate-2: It wrote the wrong text. supersedes: 12", envelope.lesson);
    try testing.expect(text.len <= lesson.MAX_BYTES);
}
