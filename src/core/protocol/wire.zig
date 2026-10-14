//! Versioned JSON lines for a Host that carries a Session across a process or
//! network boundary (SSE, a WebSocket, a queue). In-process Hosts consume the
//! typed `CoreEvent` / `UiRequest` values directly; anything that serializes
//! them goes through this module, so a field renamed inside the kernel is a
//! visible change to this contract rather than a silent change to every Host.
//!
//! Every line is one JSON object carrying the schema version `v` and a `type`:
//!
//!   {"v":1,"type":"<CoreEvent tag>","data":<payload or null>}
//!   {"v":1,"type":"<CoreEvent tag>","run_id":N,"trace_id":"...","data":...}   (writeRunEvent)
//!   {"v":1,"type":"<HostEvent tag>","data":{...}}                              (writeHostEvent)
//!   {"v":1,"type":"ui_request","id":N,"kind":"<UiRequest tag>","request":{...}}
//!   {"v":1,"type":"ui_request_closed","id":N,"outcome":"answered"|"cancelled"|"malformed"}
//!
//! Host events are what a session service adds around the kernel's events
//! (core/session_host.zig): the submitted text, the end of a Run, the result
//! of a configuration command, a poisoned Session. Their tags never collide
//! with CoreEvent tags (checked at compile time).
//!
//! `data` is the CoreEvent payload with the field names of
//! core/protocol/ui_event.zig, except `prompt_manifest`, whose digests are
//! lowercase hex in the run journal's shape:
//! `{"sha256":"<hex>","sections":[{"id","order","origin","class","sha256"}]}`.
//! UI request payloads are spelled out below, so the internal structs behind
//! them may change freely:
//!
//!   permission     {"tool":"...","args":"<tool input JSON text>"}
//!   plan_approval  {"plan_md":"...","kg_step_count":N}
//!   ask_question   {"questions":[{"question","header","multi_select",
//!                                 "options":[{"label","description","preview"}]}]}
//!   custom         {"kind":"...","payload_json":"<renderer-defined JSON text>"}
//!
//! The answer a Host collects for request N is parsed by `parseResponse`
//! (a `v` field, when present, must be 1):
//!
//!   permission     {"choice":"allow_once"|"allow_always"|"deny_once"|"deny_tool_session"}
//!   plan_approval  {"choice":"approve_default"|"approve_accept_edits"|"reject"}
//!   ask_question   {"answers":["...", ...]}  one per question; several labels joined by ", "
//!   custom         {"result":<any JSON>}
//!
//! A malformed answer is never a grant: `parseResponse` answers it the way a
//! cancelled request is answered (`cancelResponse`) and reports it as
//! `.malformed`, so the request closes as `"malformed"`, not `"answered"`.
//!
//! tests/fixtures/wire/v1 pins one line per event and request kind. A change
//! that alters any of them either bumps `SCHEMA_VERSION` or is refused.

const std = @import("std");
const ui_event = @import("ui_event.zig");
const ui_request = @import("ui_request.zig");
const util_json = @import("../../util/json.zig");
const PermissionChoice = @import("permission_choice.zig").PermissionChoice;
const prompt_sections = @import("../prompt_sections.zig");

const CoreEvent = ui_event.CoreEvent;
const UiRequest = ui_request.UiRequest;
const UiResponse = ui_request.UiResponse;
const RequestOutcome = ui_request.RequestOutcome;
const PlanApproval = ui_request.PlanApproval;

pub const SCHEMA_VERSION: u32 = 1;

/// How a UI request ended, as `ui_request_closed.outcome` reports it.
pub const RequestClosed = enum {
    /// The client's well-formed answer was used.
    answered,
    /// Interrupt, close or timeout won; the safe answer was used.
    cancelled,
    /// The client's answer could not be read; the safe answer was used.
    malformed,
};

/// How `parseResponse` read a client's answer.
pub const Reading = enum {
    /// Well-formed: `out` holds the client's answer.
    answer,
    /// Malformed or of another version: `out` holds `cancelResponse`'s safe
    /// answer.
    malformed,

    /// The `ui_request_closed` outcome to journal for this reading.
    pub fn closed(self: Reading) RequestClosed {
        return switch (self) {
            .answer => .answered,
            .malformed => .malformed,
        };
    }
};

/// The Run a CoreEvent belongs to, as the EventSink reported it, and the
/// opaque trace ID the Host's caller attached to the submission.
pub const RunContext = struct {
    run_id: u64,
    trace_id: ?[]const u8 = null,
};

/// Events a session service emits around the kernel's. Borrowed slices.
pub const HostEvent = union(enum) {
    /// A queued submission became the input of Run `run_id`.
    user_message: struct { run_id: u64, trace_id: ?[]const u8 = null, text: []const u8 },
    /// Run `run_id` ended: `stop_reason` when it returned, `error_name` when
    /// it failed.
    run_done: struct { run_id: u64, trace_id: ?[]const u8 = null, stop_reason: ?[]const u8 = null, error_name: ?[]const u8 = null },
    /// A configuration command was applied (`ok`) or refused.
    command_result: struct { command: []const u8, ok: bool, error_name: ?[]const u8 = null },
    /// The Session can no longer run; the Host must close it. Work still
    /// queued was dropped and is counted.
    session_poisoned: struct { error_name: []const u8, dropped: usize },
};

comptime {
    for (std.meta.fields(HostEvent)) |host| {
        for (std.meta.fields(CoreEvent)) |core| {
            if (std.mem.eql(u8, host.name, core.name)) @compileError("HostEvent tag collides with CoreEvent: " ++ host.name);
        }
        if (std.mem.eql(u8, host.name, "ui_request") or std.mem.eql(u8, host.name, "ui_request_closed"))
            @compileError("HostEvent tag collides with a UI request line: " ++ host.name);
    }
}

/// One CoreEvent as a wire line, caller-owned. The event's borrowed slices
/// are copied before return, so this is safe inside a synchronous emit.
pub fn writeEvent(allocator: std.mem.Allocator, event: CoreEvent) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    writeEventTo(&json, event) catch return error.OutOfMemory;
    return finish(allocator, &out);
}

/// `writeEvent` with the Run's `run_id` and, when set, `trace_id` after
/// `type`.
pub fn writeRunEvent(allocator: std.mem.Allocator, context: RunContext, event: CoreEvent) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    writeEventToWith(&json, context, event) catch return error.OutOfMemory;
    return finish(allocator, &out);
}

/// One HostEvent as a wire line, caller-owned.
pub fn writeHostEvent(allocator: std.mem.Allocator, event: HostEvent) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    writeHostEventTo(&json, event) catch return error.OutOfMemory;
    return finish(allocator, &out);
}

fn writeHostEventTo(json: *std.json.Stringify, event: HostEvent) std.json.Stringify.Error!void {
    try json.beginObject();
    try json.objectField("v");
    try json.write(SCHEMA_VERSION);
    try json.objectField("type");
    try json.write(@tagName(event));
    try json.objectField("data");
    switch (event) {
        inline else => |payload| try json.write(payload),
    }
    try json.endObject();
}

fn writeEventTo(json: *std.json.Stringify, event: CoreEvent) std.json.Stringify.Error!void {
    return writeEventToWith(json, null, event);
}

fn writeEventToWith(json: *std.json.Stringify, context: ?RunContext, event: CoreEvent) std.json.Stringify.Error!void {
    try json.beginObject();
    try json.objectField("v");
    try json.write(SCHEMA_VERSION);
    try json.objectField("type");
    try json.write(@tagName(event));
    if (context) |run| {
        try json.objectField("run_id");
        try json.write(run.run_id);
        if (run.trace_id) |trace_id| {
            try json.objectField("trace_id");
            try json.write(trace_id);
        }
    }
    try json.objectField("data");
    switch (event) {
        .prompt_manifest => |manifest| try writeManifest(json, manifest),
        inline else => |payload| {
            if (@TypeOf(payload) == void) try json.write(null) else try json.write(payload);
        },
    }
    try json.endObject();
}

/// Raw digests would serialize as number arrays (or, by chance, as strings).
fn writeManifest(json: *std.json.Stringify, manifest: prompt_sections.Manifest) std.json.Stringify.Error!void {
    try json.beginObject();
    try json.objectField("sha256");
    try json.write(&std.fmt.bytesToHex(manifest.sha256, .lower));
    try json.objectField("sections");
    try json.beginArray();
    for (manifest.entries) |entry| {
        try json.beginObject();
        try json.objectField("id");
        try json.write(entry.id);
        try json.objectField("order");
        try json.write(entry.order);
        try json.objectField("origin");
        try json.write(entry.origin);
        try json.objectField("class");
        try json.write(entry.class);
        try json.objectField("sha256");
        try json.write(&std.fmt.bytesToHex(entry.sha256, .lower));
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

/// The announcement of UI request `id`, caller-owned.
pub fn writeRequest(allocator: std.mem.Allocator, id: u64, request: *const UiRequest) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    writeRequestTo(&json, id, request) catch return error.OutOfMemory;
    return finish(allocator, &out);
}

fn writeRequestTo(json: *std.json.Stringify, id: u64, request: *const UiRequest) std.json.Stringify.Error!void {
    try json.beginObject();
    try json.objectField("v");
    try json.write(SCHEMA_VERSION);
    try json.objectField("type");
    try json.write("ui_request");
    try json.objectField("id");
    try json.write(id);
    try json.objectField("kind");
    try json.write(@tagName(request.*));
    try json.objectField("request");
    try json.beginObject();
    switch (request.*) {
        .permission => |permission| {
            try json.objectField("tool");
            try json.write(permission.tool);
            try json.objectField("args");
            try json.write(permission.args);
        },
        .plan_approval => |plan| {
            try json.objectField("plan_md");
            try json.write(plan.plan_md);
            try json.objectField("kg_step_count");
            try json.write(plan.kg_step_count);
        },
        .ask_question => |questions| {
            try json.objectField("questions");
            try json.beginArray();
            for (questions) |question| {
                try json.beginObject();
                try json.objectField("question");
                try json.write(question.question);
                try json.objectField("header");
                try json.write(question.header);
                try json.objectField("multi_select");
                try json.write(question.multi);
                try json.objectField("options");
                try json.beginArray();
                for (question.options) |option| {
                    try json.beginObject();
                    try json.objectField("label");
                    try json.write(option.label);
                    try json.objectField("description");
                    try json.write(option.description);
                    try json.objectField("preview");
                    try json.write(option.preview);
                    try json.endObject();
                }
                try json.endArray();
                try json.endObject();
            }
            try json.endArray();
        },
        .custom => |custom| {
            try json.objectField("kind");
            try json.write(custom.kind);
            try json.objectField("payload_json");
            try json.write(custom.payload_json);
        },
    }
    try json.endObject();
    try json.endObject();
}

/// The line that closes UI request `id`, caller-owned.
pub fn writeRequestClosed(allocator: std.mem.Allocator, id: u64, outcome: RequestClosed) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"v\":{d},\"type\":\"ui_request_closed\",\"id\":{d},\"outcome\":\"{s}\"}}", .{ SCHEMA_VERSION, id, @tagName(outcome) });
}

fn finish(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating) error{OutOfMemory}![]u8 {
    const raw = try out.toOwnedSlice();
    defer allocator.free(raw);
    return util_json.repairJsonUtf8(allocator, raw);
}

/// The answer to a request that was cancelled or answered unreadably: a
/// permission prompt is denied once and a plan is rejected, never granted;
/// a question or a custom UI reports `error.InputAborted`, as Esc does in the
/// terminal.
pub fn cancelResponse(request: *const UiRequest, out: *UiResponse) error{InputAborted}!RequestOutcome {
    switch (request.*) {
        .permission => {
            out.* = .{ .permission = .deny_once };
            return .answered;
        },
        .plan_approval => {
            out.* = .{ .plan_approval = .reject };
            return .answered;
        },
        .ask_question, .custom => return error.InputAborted,
    }
}

/// Parses the Host's answer `json` to `request` into `out`. Answer slices
/// (`answers`, `custom`) are owned by `allocator`. Anything malformed takes
/// `cancelResponse`'s safe answer and reads as `.malformed`; for a question or
/// a custom UI that safe answer is `error.InputAborted`.
pub fn parseResponse(
    request: *const UiRequest,
    json: []const u8,
    allocator: std.mem.Allocator,
    out: *UiResponse,
) error{ InputAborted, OutOfMemory }!Reading {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch
        return malformed(request, out);
    if (parsed != .object) return malformed(request, out);
    const object = parsed.object;
    if (object.get("v")) |version| {
        if (version != .integer or version.integer != SCHEMA_VERSION) return malformed(request, out);
    }

    switch (request.*) {
        .permission => {
            const choice = choiceField(object, PermissionChoice) orelse return malformed(request, out);
            out.* = .{ .permission = choice };
            return .answer;
        },
        .plan_approval => {
            const choice = choiceField(object, PlanApproval) orelse return malformed(request, out);
            out.* = .{ .plan_approval = choice };
            return .answer;
        },
        .ask_question => |questions| {
            const value = object.get("answers") orelse return malformed(request, out);
            if (value != .array or value.array.items.len != questions.len) return malformed(request, out);
            for (value.array.items) |item| {
                if (item != .string) return malformed(request, out);
            }
            const answers = try allocator.alloc([]const u8, questions.len);
            var filled: usize = 0;
            errdefer {
                for (answers[0..filled]) |answer| allocator.free(answer);
                allocator.free(answers);
            }
            for (value.array.items, 0..) |item, index| {
                answers[index] = try allocator.dupe(u8, item.string);
                filled += 1;
            }
            out.* = .{ .answers = answers };
            return .answer;
        },
        .custom => {
            const result = object.get("result") orelse return malformed(request, out);
            const raw = try std.json.Stringify.valueAlloc(allocator, result, .{});
            defer allocator.free(raw);
            out.* = .{ .custom = try util_json.repairJsonUtf8(allocator, raw) };
            return .answer;
        },
    }
}

fn malformed(request: *const UiRequest, out: *UiResponse) error{InputAborted}!Reading {
    _ = try cancelResponse(request, out);
    return .malformed;
}

fn choiceField(object: std.json.ObjectMap, comptime E: type) ?E {
    const value = object.get("choice") orelse return null;
    if (value != .string) return null;
    return std.meta.stringToEnum(E, value.string);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "writeEvent: version, tag and payload; a void payload is null" {
    const line = try writeEvent(testing.allocator, .{ .text_chunk = "hi" });
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("{\"v\":1,\"type\":\"text_chunk\",\"data\":\"hi\"}", line);
    const done = try writeEvent(testing.allocator, .stream_done);
    defer testing.allocator.free(done);
    try testing.expectEqualStrings("{\"v\":1,\"type\":\"stream_done\",\"data\":null}", done);
}

test "parseResponse: a malformed or wrong-version answer never grants a permission" {
    const request = UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    const bad = [_][]const u8{
        "not json",
        "[]",
        "{}",
        "{\"choice\":\"allow_everything\"}",
        "{\"choice\":1}",
        "{\"v\":2,\"choice\":\"allow_once\"}",
    };
    for (bad) |json| {
        var out: UiResponse = undefined;
        try testing.expectEqual(Reading.malformed, try parseResponse(&request, json, testing.allocator, &out));
        try testing.expectEqual(PermissionChoice.deny_once, out.permission);
    }
    var out: UiResponse = undefined;
    try testing.expectEqual(Reading.answer, try parseResponse(&request, "{\"v\":1,\"choice\":\"allow_always\"}", testing.allocator, &out));
    try testing.expectEqual(PermissionChoice.allow_always, out.permission);
}

test "parseResponse: ask_question needs one string per question" {
    const options = [_]ui_request.AskOption{.{ .label = "Yes", .description = "" }};
    const questions = [_]ui_request.AskQuestion{
        .{ .question = "A?", .header = "a", .multi = false, .options = &options },
        .{ .question = "B?", .header = "b", .multi = true, .options = &options },
    };
    const request = UiRequest{ .ask_question = &questions };
    var out: UiResponse = undefined;
    try testing.expectError(error.InputAborted, parseResponse(&request, "{\"answers\":[\"Yes\"]}", testing.allocator, &out));
    try testing.expectError(error.InputAborted, parseResponse(&request, "{\"answers\":[\"Yes\",2]}", testing.allocator, &out));
    try testing.expectEqual(Reading.answer, try parseResponse(&request, "{\"answers\":[\"Yes\",\"Yes, No\"]}", testing.allocator, &out));
    defer {
        for (out.answers) |answer| testing.allocator.free(answer);
        testing.allocator.free(out.answers);
    }
    try testing.expectEqualStrings("Yes, No", out.answers[1]);
}

test "parseResponse: a custom result reaches the tool as JSON text" {
    const request = UiRequest{ .custom = .{ .kind = "video_timeline", .payload_json = "{}" } };
    var out: UiResponse = undefined;
    try testing.expectEqual(Reading.answer, try parseResponse(&request, "{\"result\":{\"in\":3,\"out\":42}}", testing.allocator, &out));
    defer testing.allocator.free(out.custom);
    try testing.expectEqualStrings("{\"in\":3,\"out\":42}", out.custom);
    try testing.expectError(error.InputAborted, parseResponse(&request, "{\"output\":1}", testing.allocator, &out));
}
