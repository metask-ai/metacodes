//! Typed System-One questions for a TypeSafe-Jev-compatible `/v1/systemone`
//! service.
//!
//! Jev-Mem (arXiv 2609.23986) moves the high-frequency decisions of an agent
//! memory — typing, relation judgment, routing, candidate scoring, stopping —
//! off autoregressive generation and onto a typed controller that answers
//! with calibrated probabilities. This module is the typed half of that
//! controller: a request is one bounded `state` text plus named questions, an
//! answer is a probability distribution per question.
//!
//! Every question carries its decision criteria. Measured against
//! metask-jev-4b on 2026-09-23, the same enumeration-intent question scored
//! 6/18 as a bare boolean description and 17/18 with true/false criteria, so a
//! criterion-less question is not representable here.
//!
//! Serialization is deterministic (declaration order, no clock, no ids):
//! identical inputs produce identical request bytes, and the service answers
//! an identical request with identical probabilities. That is what allows a
//! judgment to enter an append-only tool result without breaking the
//! provider-visible cache contract.

const std = @import("std");
const util_json = @import("../util/json.zig");

/// Our own per-request bound; the service shares one prefill across all
/// questions of a request, so batching is the cheap direction.
pub const MAX_QUESTIONS: usize = 32;
/// Service contract: enum choices are 1–26 non-empty strings.
pub const MAX_OPTIONS: usize = 26;
/// A one-option choice has a known answer and is not worth a request.
pub const MIN_OPTIONS: usize = 2;
pub const MAX_NAME_BYTES: usize = 64;
pub const MAX_TEXT_BYTES: usize = 1024;
/// Tolerance on the sum of a returned distribution. The service normalizes
/// in float32 (0.11378676 + 0.88621318 = 0.99999994); anything further off is
/// not a probability distribution and fails closed.
pub const SUM_TOLERANCE: f64 = 0.01;

pub const Boolean = struct {
    description: []const u8,
    when_true: []const u8,
    when_false: []const u8,
};

pub const Option = struct {
    /// Wire key and answer label: `[a-z][a-z0-9_]*`.
    label: []const u8,
    criterion: []const u8,
};

/// Mutually exclusive alternatives (wire type `enum`).
pub const Choice = struct {
    description: []const u8,
    options: []const Option,
};

pub const Question = union(enum) {
    boolean: Boolean,
    choice: Choice,
};

pub const Named = struct {
    /// Wire key: `[a-z][a-z0-9_]*`, unique within a request.
    name: []const u8,
    question: Question,
};

pub const SpecError = error{
    NoQuestions,
    TooManyQuestions,
    InvalidName,
    DuplicateName,
    EmptyText,
    TextTooLong,
    TooFewOptions,
    TooManyOptions,
    InvalidLabel,
    DuplicateLabel,
};

/// Reject a question set the service would refuse or answer meaninglessly.
/// Usable at comptime: fixed catalogs call it in a `comptime` block so a bad
/// question is a compile error rather than a runtime fallback.
pub fn validate(questions: []const Named) SpecError!void {
    if (questions.len == 0) return error.NoQuestions;
    if (questions.len > MAX_QUESTIONS) return error.TooManyQuestions;
    for (questions, 0..) |named, index| {
        if (!validKey(named.name)) return error.InvalidName;
        for (questions[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, named.name)) return error.DuplicateName;
        }
        switch (named.question) {
            .boolean => |b| {
                try validText(b.description);
                try validText(b.when_true);
                try validText(b.when_false);
            },
            .choice => |c| {
                try validText(c.description);
                if (c.options.len < MIN_OPTIONS) return error.TooFewOptions;
                if (c.options.len > MAX_OPTIONS) return error.TooManyOptions;
                for (c.options, 0..) |option, option_index| {
                    if (!validKey(option.label)) return error.InvalidLabel;
                    try validText(option.criterion);
                    for (c.options[0..option_index]) |earlier| {
                        if (std.mem.eql(u8, earlier.label, option.label)) return error.DuplicateLabel;
                    }
                }
            },
        }
    }
}

fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > MAX_NAME_BYTES) return false;
    if (!std.ascii.isLower(key[0])) return false;
    for (key) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '_')) return false;
    }
    return true;
}

fn validText(text: []const u8) SpecError!void {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.EmptyText;
    if (text.len > MAX_TEXT_BYTES) return error.TextTooLong;
}

/// Append the complete request body for `questions` (already validated).
/// Booleans send their criteria under the `true`/`false` keys; choices send
/// one criterion per label, in declaration order.
pub fn writeRequest(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    state: []const u8,
    questions: []const Named,
) error{OutOfMemory}!void {
    std.debug.assert(questions.len > 0 and questions.len <= MAX_QUESTIONS);
    try out.appendSlice(allocator, "{\"state\":");
    try util_json.serializeString(state, out, allocator);
    try out.appendSlice(allocator, ",\"questions\":{");
    for (questions, 0..) |named, index| {
        if (index > 0) try out.append(allocator, ',');
        try util_json.serializeString(named.name, out, allocator);
        switch (named.question) {
            .boolean => |b| {
                try out.appendSlice(allocator, ":{\"type\":\"boolean\",\"description\":");
                try util_json.serializeString(b.description, out, allocator);
                try out.appendSlice(allocator, ",\"criteria\":{\"true\":");
                try util_json.serializeString(b.when_true, out, allocator);
                try out.appendSlice(allocator, ",\"false\":");
                try util_json.serializeString(b.when_false, out, allocator);
                try out.appendSlice(allocator, "}}");
            },
            .choice => |c| {
                try out.appendSlice(allocator, ":{\"type\":\"enum\",\"description\":");
                try util_json.serializeString(c.description, out, allocator);
                try out.appendSlice(allocator, ",\"criteria\":{");
                for (c.options, 0..) |option, option_index| {
                    if (option_index > 0) try out.append(allocator, ',');
                    try util_json.serializeString(option.label, out, allocator);
                    try out.append(allocator, ':');
                    try util_json.serializeString(option.criterion, out, allocator);
                }
                try out.appendSlice(allocator, "}}");
            },
        }
    }
    try out.appendSlice(allocator, "}}");
}

pub const Answer = union(enum) {
    /// P(true).
    boolean: f64,
    /// One probability per option, aligned with `Choice.options`.
    choice: []const f64,
};

/// Parsed answers, aligned with the request's question order. Owns every
/// byte through its arena.
pub const Answers = struct {
    arena: std.heap.ArenaAllocator,
    /// Model identity reported by the service ("unknown" when absent).
    model: []const u8,
    /// `usage.tariff` as reported by the service ("" when absent). There is
    /// no spend accounting for System-One calls yet, so the transport only
    /// accepts services that declare themselves free (`none`).
    tariff: []const u8,
    values: []const Answer,

    pub fn deinit(self: *Answers) void {
        self.arena.deinit();
    }

    pub fn probTrue(self: *const Answers, index: usize) f64 {
        return self.values[index].boolean;
    }

    pub fn distribution(self: *const Answers, index: usize) []const f64 {
        return self.values[index].choice;
    }
};

pub const ResponseError = error{
    OutOfMemory,
    /// Not the documented response shape at all.
    MalformedResponse,
    /// The service reported an `error` or `partial_errors` for a question
    /// set this module already validated: a contract drift, never retried.
    ServiceRejected,
    AnswerMissing,
    AnswerTypeMismatch,
    ProbabilityInvalid,
};

/// Parse a 200 response body for `questions`. Strict in both directions: a
/// missing label, an unexpected label or a distribution that does not sum to
/// one fails the whole call, because callers fall back to their deterministic
/// baseline and a half-trusted answer is worse than none.
pub fn parseResponse(
    gpa: std.mem.Allocator,
    questions: []const Named,
    body: []const u8,
) ResponseError!Answers {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedResponse,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedResponse;
    const root = parsed.value.object;
    if (root.get("error") != null) return error.ServiceRejected;
    if (root.get("partial_errors")) |partial| {
        if (partial != .object or partial.object.count() > 0) return error.ServiceRejected;
    }
    const answers_value = root.get("answers") orelse return error.MalformedResponse;
    if (answers_value != .object) return error.MalformedResponse;
    const answers = answers_value.object;

    var result: Answers = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .model = "unknown",
        .tariff = "",
        .values = &.{},
    };
    errdefer result.arena.deinit();
    const arena = result.arena.allocator();

    if (root.get("model")) |model| {
        if (model == .string and model.string.len > 0) result.model = try arena.dupe(u8, model.string);
    }
    if (root.get("usage")) |usage| {
        if (usage == .object) {
            if (usage.object.get("tariff")) |tariff| {
                if (tariff == .string) result.tariff = try arena.dupe(u8, tariff.string);
            }
        }
    }

    const values = try arena.alloc(Answer, questions.len);
    for (questions, values) |named, *value| {
        const answer = answers.get(named.name) orelse return error.AnswerMissing;
        if (answer != .object) return error.MalformedResponse;
        const probabilities_value = answer.object.get("probabilities") orelse return error.AnswerMissing;
        if (probabilities_value != .object) return error.MalformedResponse;
        const probabilities = probabilities_value.object;
        switch (named.question) {
            .boolean => {
                if (probabilities.count() != 2) return error.AnswerTypeMismatch;
                const p_true = try probabilityAt(probabilities, "true");
                const p_false = try probabilityAt(probabilities, "false");
                try checkSum(p_true + p_false);
                value.* = .{ .boolean = p_true };
            },
            .choice => |c| {
                if (probabilities.count() != c.options.len) return error.AnswerTypeMismatch;
                const distribution = try arena.alloc(f64, c.options.len);
                var sum: f64 = 0;
                for (c.options, distribution) |option, *p| {
                    p.* = try probabilityAt(probabilities, option.label);
                    sum += p.*;
                }
                try checkSum(sum);
                value.* = .{ .choice = distribution };
            },
        }
    }
    result.values = values;
    return result;
}

fn probabilityAt(map: std.json.ObjectMap, label: []const u8) ResponseError!f64 {
    const raw = map.get(label) orelse return error.AnswerTypeMismatch;
    const p: f64 = switch (raw) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return error.ProbabilityInvalid,
        else => return error.ProbabilityInvalid,
    };
    if (!std.math.isFinite(p) or p < 0 or p > 1) return error.ProbabilityInvalid;
    return p;
}

fn checkSum(sum: f64) ResponseError!void {
    if (@abs(sum - 1.0) > SUM_TOLERANCE) return error.ProbabilityInvalid;
}

/// Index of the most probable option; ties go to the earlier option so the
/// result is a pure function of the distribution.
pub fn argmax(distribution: []const f64) usize {
    std.debug.assert(distribution.len > 0);
    var best: usize = 0;
    for (distribution, 0..) |p, index| {
        if (p > distribution[best]) best = index;
    }
    return best;
}

/// Whole percent for provider-visible rendering. Two significant digits are
/// all a calibrated 4B judge can support, and an integer renders identically
/// on every platform.
pub fn percent(p: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(p, 0.0, 1.0) * 100.0));
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const enumeration_question = [_]Named{.{
    .name = "needs_enumeration",
    .question = .{ .boolean = .{
        .description = "Does answering this request require counting or listing several matching items?",
        .when_true = "The answer is a count or a complete list.",
        .when_false = "The answer is a single fact or an action.",
    } },
}};

const kind_options = [_]Option{
    .{ .label = "decision", .criterion = "A rule the project adopted." },
    .{ .label = "bug", .criterion = "A defect and its fix." },
};

comptime {
    validate(&enumeration_question) catch unreachable;
}

test "validate rejects every shape the service or the judge cannot use" {
    try testing.expectError(error.NoQuestions, validate(&.{}));
    const boolean: Question = enumeration_question[0].question;
    try testing.expectError(error.InvalidName, validate(&.{.{ .name = "Upper", .question = boolean }}));
    try testing.expectError(error.InvalidName, validate(&.{.{ .name = "", .question = boolean }}));
    try testing.expectError(error.InvalidName, validate(&.{.{ .name = "has space", .question = boolean }}));
    try testing.expectError(error.DuplicateName, validate(&.{
        .{ .name = "same", .question = boolean },
        .{ .name = "same", .question = boolean },
    }));
    try testing.expectError(error.EmptyText, validate(&.{.{ .name = "q", .question = .{ .boolean = .{
        .description = "d",
        .when_true = " ",
        .when_false = "f",
    } } }}));
    try testing.expectError(error.TooFewOptions, validate(&.{.{ .name = "q", .question = .{ .choice = .{
        .description = "d",
        .options = kind_options[0..1],
    } } }}));
    try testing.expectError(error.DuplicateLabel, validate(&.{.{ .name = "q", .question = .{ .choice = .{
        .description = "d",
        .options = &.{ kind_options[0], kind_options[0] },
    } } }}));
    try testing.expectError(error.InvalidLabel, validate(&.{.{ .name = "q", .question = .{ .choice = .{
        .description = "d",
        .options = &.{ kind_options[0], .{ .label = "9lives", .criterion = "c" } },
    } } }}));

    var many: [MAX_OPTIONS + 1]Option = undefined;
    var labels: [MAX_OPTIONS + 1][3]u8 = undefined;
    for (&many, &labels, 0..) |*option, *label, index| {
        label.* = .{ 'o', 'a' + @as(u8, @intCast(index / 26)), 'a' + @as(u8, @intCast(index % 26)) };
        option.* = .{ .label = label, .criterion = "c" };
    }
    try validate(&.{.{ .name = "q", .question = .{ .choice = .{ .description = "d", .options = many[0..MAX_OPTIONS] } } }});
    try testing.expectError(error.TooManyOptions, validate(&.{.{ .name = "q", .question = .{ .choice = .{ .description = "d", .options = &many } } }}));

    var names: [MAX_QUESTIONS + 1][3]u8 = undefined;
    var set: [MAX_QUESTIONS + 1]Named = undefined;
    for (&set, &names, 0..) |*named, *name, index| {
        name.* = .{ 'q', 'a' + @as(u8, @intCast(index / 26)), 'a' + @as(u8, @intCast(index % 26)) };
        named.* = .{ .name = name, .question = boolean };
    }
    try validate(set[0..MAX_QUESTIONS]);
    try testing.expectError(error.TooManyQuestions, validate(&set));
}

test "writeRequest is byte-stable and carries every criterion" {
    const questions = [_]Named{
        enumeration_question[0],
        .{ .name = "kind", .question = .{ .choice = .{ .description = "Which type?", .options = &kind_options } } },
    };
    try validate(&questions);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try writeRequest(&out, testing.allocator, "User request: \"list all\"\n", &questions);
    try testing.expectEqualStrings(
        "{\"state\":\"User request: \\\"list all\\\"\\n\",\"questions\":{" ++
            "\"needs_enumeration\":{\"type\":\"boolean\",\"description\":\"Does answering this request require counting or listing several matching items?\"," ++
            "\"criteria\":{\"true\":\"The answer is a count or a complete list.\",\"false\":\"The answer is a single fact or an action.\"}}," ++
            "\"kind\":{\"type\":\"enum\",\"description\":\"Which type?\",\"criteria\":{\"decision\":\"A rule the project adopted.\",\"bug\":\"A defect and its fix.\"}}}}",
        out.items,
    );
}

test "parseResponse reads the service's own answer shape" {
    const questions = [_]Named{
        enumeration_question[0],
        .{ .name = "kind", .question = .{ .choice = .{ .description = "Which type?", .options = &kind_options } } },
    };
    // Captured from metask-jev-4b (probabilities shortened).
    const body =
        \\{"answers":{"needs_enumeration":{"probabilities":{"false":0.11378676,"true":0.88621324},"type":"boolean"},
        \\"kind":{"probabilities":{"bug":0.25,"decision":0.75},"type":"enum"}},
        \\"model":"metask-jev-4b","usage":{"provider":"self-hosted","tariff":"none"}}
    ;
    var answers = try parseResponse(testing.allocator, &questions, body);
    defer answers.deinit();
    try testing.expectEqualStrings("metask-jev-4b", answers.model);
    try testing.expectEqualStrings("none", answers.tariff);
    try testing.expectApproxEqAbs(@as(f64, 0.88621324), answers.probTrue(0), 1e-9);
    try testing.expectEqual(@as(usize, 0), argmax(answers.distribution(1)));
    try testing.expectEqual(@as(u8, 89), percent(answers.probTrue(0)));
    try testing.expectEqual(@as(u8, 75), percent(answers.distribution(1)[0]));
}

test "parseResponse fails closed on every contract drift" {
    const questions = [_]Named{enumeration_question[0]};
    const cases = [_]struct { body: []const u8, expected: ResponseError }{
        .{ .body = "not json", .expected = error.MalformedResponse },
        .{ .body = "[]", .expected = error.MalformedResponse },
        .{ .body = "{\"error\":{\"needs_enumeration\":\"supported types are enum and boolean.\"}}", .expected = error.ServiceRejected },
        .{ .body = "{\"answers\":{},\"partial_errors\":{\"needs_enumeration\":\"bad\"}}", .expected = error.ServiceRejected },
        .{ .body = "{\"answers\":{}}", .expected = error.AnswerMissing },
        .{ .body = "{\"answers\":{\"needs_enumeration\":{\"type\":\"boolean\"}}}", .expected = error.AnswerMissing },
        .{ .body = "{\"answers\":{\"needs_enumeration\":{\"probabilities\":{\"true\":1.0}}}}", .expected = error.AnswerTypeMismatch },
        .{ .body = "{\"answers\":{\"needs_enumeration\":{\"probabilities\":{\"yes\":0.5,\"no\":0.5}}}}", .expected = error.AnswerTypeMismatch },
        .{ .body = "{\"answers\":{\"needs_enumeration\":{\"probabilities\":{\"true\":0.9,\"false\":0.9}}}}", .expected = error.ProbabilityInvalid },
        .{ .body = "{\"answers\":{\"needs_enumeration\":{\"probabilities\":{\"true\":1.5,\"false\":-0.5}}}}", .expected = error.ProbabilityInvalid },
        .{ .body = "{\"answers\":{\"needs_enumeration\":{\"probabilities\":{\"true\":\"0.5\",\"false\":0.5}}}}", .expected = error.ProbabilityInvalid },
    };
    for (cases) |case| {
        try testing.expectError(case.expected, parseResponse(testing.allocator, &questions, case.body));
    }
    // Integer endpoints and an empty partial_errors object are well-formed.
    var answers = try parseResponse(
        testing.allocator,
        &questions,
        "{\"answers\":{\"needs_enumeration\":{\"probabilities\":{\"true\":1,\"false\":0}}},\"partial_errors\":{}}",
    );
    defer answers.deinit();
    try testing.expectEqual(@as(f64, 1.0), answers.probTrue(0));
    try testing.expectEqualStrings("unknown", answers.model);
    try testing.expectEqualStrings("", answers.tariff);
}

test "argmax breaks ties toward the earlier option" {
    try testing.expectEqual(@as(usize, 0), argmax(&.{ 0.5, 0.5 }));
    try testing.expectEqual(@as(usize, 2), argmax(&.{ 0.2, 0.3, 0.5 }));
}
