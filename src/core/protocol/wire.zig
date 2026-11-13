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
//!   {"v":1,"type":"ui_request_closed","id":N,"outcome":"answered"|"cancelled"|"malformed","by":"..."}
//!       (`by` only when the answer named who gave it; writeRequestClosedBy)
//!   {"v":1,"type":"ui_request_unavailable","kind":"...","custom_kind":"...","reason":"..."}
//!   {"v":1,"type":"capabilities_accepted","ui_requests":[...],"custom":[...],"events":[...]|null,"ignored":{...}}
//!   {"v":1,"type":"capabilities_refused","reason":"<RefusalError name>"}
//!
//! A frontend may open the channel with a capability frame naming the UI
//! requests it renders (`parseCapabilities`; doc/WIRE_PROTOCOL.md §2):
//!
//!   {"v":1,"type":"capabilities","ui_requests":["permission","ask_question"],
//!    "custom":["video_timeline@1"],"events":["text_chunk"]}
//!
//! Once one is installed, a request it excludes is not announced: the Host
//! journals `ui_request_unavailable` and answers `unavailable` at once
//! (frontend_capabilities.zig). A frontend that never declares receives every
//! request, as before.
//!
//! Host events are what a session service adds around the kernel's events
//! (core/session_host.zig, and the bundled `--web`/`serve` host in src/web):
//! the submitted text, the end of a Run, the result of a configuration
//! command, a message refused before it ran, a poisoned Session, a Run that
//! resumes a suspended one. Their tags never collide with CoreEvent tags
//! (checked at compile time).
//!
//! A Host numbers the Runs of a Session 1, 2, … as they start. A Run's lines
//! run from its `user_message` (`run_resumed` when it resumes a Run that
//! ended `suspended`; none when a `/command` macro or `/retry` started it) to
//! its `run_done`, both carrying its `run_id`; every CoreEvent
//! journaled in between is written by `writeRunEvent` with the same `run_id`
//! and the submission's `trace_id`, when it had one. UI request and
//! capability lines carry no `run_id`; no other host line falls inside a Run.
//!
//! `data` is the CoreEvent payload with the field names of
//! core/protocol/ui_event.zig, except `prompt_manifest`, whose digests are
//! lowercase hex in the run journal's shape:
//! `{"sha256":"<hex>","sections":[{"id","order","origin","class","sha256"}]}`,
//! and `goal_updated`, the goal as goal.json and AgentCore's `goal->get` write
//! it: `{"id","objective","status","token_budget","tokens_used","time_used_ms",
//! "created_at_ms","updated_at_ms"}`.
//! UI request payloads are spelled out below, so the internal structs behind
//! them may change freely:
//!
//!   permission     {"tool":"...","args":"<tool input JSON text>"}
//!   ask_question   {"questions":[{"question","header","multi_select",
//!                                 "options":[{"label","description","preview"}]}]}
//!   custom         {"kind":"...","payload_json":"<renderer-defined JSON text>"}
//!
//! The answer a Host collects for request N is parsed by `parseResponse`
//! (a `v` field, when present, must be 1):
//!
//!   permission     {"choice":"allow_once"|"allow_always"|"deny_once"|"deny_tool_session"}
//!   ask_question   {"answers":["...", ...]}  one per question; several labels joined by ", "
//!   custom         {"result":<any JSON>}
//!
//! A malformed answer is never a grant: `parseResponse` fails it the way a
//! request nobody answered fails (`cancelResponse`), so the request closes as
//! `"malformed"`, not `"answered"`. For a permission prompt the failure names
//! the cause (`ui_request.Unanswered`), so the model is not told the user
//! declined (doc/WIRE_PROTOCOL.md §1.4).
//!
//! Any answer may also name who gave it, `"by":"<approver>"` (#446): a string
//! of 1 to `MAX_APPROVER_BYTES` bytes, read by `answerApprover` and written on
//! the request's `ui_request_closed` line. `by` never changes how the answer
//! itself is read.
//!
//! tests/fixtures/wire/v1 pins one line per event and request kind, and the
//! capability frames with their replies. Which changes keep v1 and which bump
//! `SCHEMA_VERSION` is doc/WIRE_PROTOCOL.md §4: a change may add lines or
//! append a field to a pinned line; altering any other byte of one is a bump.

const std = @import("std");
const ui_event = @import("ui_event.zig");
const ui_request = @import("ui_request.zig");
const frontend_capabilities = @import("frontend_capabilities.zig");
const util_json = @import("../../util/json.zig");
const PermissionChoice = @import("permission_choice.zig").PermissionChoice;
const prompt_sections = @import("../prompt_sections.zig");
const goal = @import("../goal.zig");
const typed_submission = @import("../typed_submission.zig");

const CoreEvent = ui_event.CoreEvent;
const UiRequest = ui_request.UiRequest;
const UiResponse = ui_request.UiResponse;
const RequestOutcome = ui_request.RequestOutcome;

pub const SCHEMA_VERSION: u32 = 1;

/// How a UI request ended, as `ui_request_closed.outcome` reports it.
pub const RequestClosed = enum {
    /// The client's well-formed answer was used.
    answered,
    /// Interrupt, close or timeout won; nothing was granted.
    cancelled,
    /// The client's answer could not be read; nothing was granted.
    malformed,
};

/// Why a request ended without the client's well-formed answer: what
/// `cancelResponse` reports and what the Host journals, from one value.
pub const NoAnswer = enum {
    /// Nobody answered before the Host's deadline.
    timed_out,
    /// An interrupt or a close won.
    cancelled,
    /// The client's answer could not be read.
    unreadable,

    /// The `ui_request_closed` outcome to journal. A timeout closes as
    /// `cancelled`: v1's outcome set has no timeout, and adding one is a
    /// breaking change (doc/WIRE_PROTOCOL.md §4).
    pub fn closed(self: NoAnswer) RequestClosed {
        return switch (self) {
            .timed_out, .cancelled => .cancelled,
            .unreadable => .malformed,
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
    /// A queued submission became the input of Run `run_id` (`UserMessage`).
    user_message: UserMessage,
    /// Run `run_id` ended: `stop_reason` when it returned, `error_name` when
    /// it failed. `model_error` says why, when the stop was a model failure.
    run_done: struct { run_id: u64, trace_id: ?[]const u8 = null, stop_reason: ?[]const u8 = null, error_name: ?[]const u8 = null, model_error: ?@import("../../api/model_error.zig").Detail.View = null },
    /// A configuration command was applied (`ok`) or refused. `command` names
    /// it: SessionHost's `Command` tag, or the verb of a `--web`/`serve`
    /// `/command` line (`mode`, `edit`, …; `shell` for `!cmd`, `prompt` for
    /// plain text). `error_name` is set exactly when `ok` is false. `message`
    /// is what the command reports for a person (`--web`/`serve`: its outcome
    /// or a shell command's output); SessionHost has none.
    command_result: struct { command: []const u8, ok: bool, error_name: ?[]const u8 = null, message: ?[]const u8 = null },
    /// A message (`--web`/`serve` `POST /message`, UDS `message`; a
    /// SessionHost `Submission`) started no Run: its `model` or
    /// `permission_mode` was refused, neither was applied
    /// and its `text` stayed out of the conversation. It takes the place of
    /// that message's `user_message`. `model` and `permission_mode` repeat
    /// what the message asked for (null when not given; the mode in the
    /// spelling `/state` reports); `message` says why, in words.
    message_rejected: struct { message: []const u8, text: []const u8, model: ?[]const u8 = null, permission_mode: ?[]const u8 = null },
    /// The Session can no longer run; the Host must close it. Work still
    /// queued was dropped and is counted.
    session_poisoned: struct { error_name: []const u8, dropped: usize },
    /// Run `run_id` resumes a Run that ended `suspended` on UI request
    /// `request_id`, whose `ui_request_closed` precedes this line (#446). It
    /// takes the place of `user_message` as the Run's first line, and
    /// `trace_id` is the suspended Run's.
    run_resumed: struct { run_id: u64, trace_id: ?[]const u8 = null, request_id: u64 },
};

/// `user_message`'s payload. `text` is the submitted text. `replaces` is the
/// 1-based position of the user message it was submitted to replace
/// (edit-and-rerun): that message and everything after it leave the
/// conversation before the Run, unless `run_done` names the refusal
/// (`PositionOutOfRange`, `NotUserMessage`, `PositionCompacted`). Null when
/// the text is appended after the whole conversation.
///
/// A typed submission (#447) adds `source`, `kind`, `idempotency_key` and
/// `attributes` (one JSON object), appended under doc/WIRE_PROTOCOL.md §4's
/// additive rule 2. Each is written only when the submission had it, so the
/// line of a submission without them keeps its bytes.
pub const UserMessage = struct {
    run_id: u64,
    trace_id: ?[]const u8 = null,
    text: []const u8,
    replaces: ?usize = null,
    source: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    idempotency_key: ?[]const u8 = null,
    attributes: []const typed_submission.Attribute = &.{},
};

/// The `type`s of the lines this module writes or reads besides the event
/// tags.
const LINE_TYPES = [_][]const u8{
    "ui_request",
    "ui_request_closed",
    "ui_request_unavailable",
    "capabilities",
    "capabilities_accepted",
    "capabilities_refused",
};

comptime {
    // Every pair of names is compared byte by byte; the default quota of
    // 1000 backward branches ran out at the sixth HostEvent tag.
    @setEvalBranchQuota(100_000);
    for (std.meta.fields(HostEvent)) |host| {
        for (std.meta.fields(CoreEvent)) |core| {
            if (std.mem.eql(u8, host.name, core.name)) @compileError("HostEvent tag collides with CoreEvent: " ++ host.name);
        }
    }
    for (LINE_TYPES) |line_type| {
        for (std.meta.fields(HostEvent)) |host| {
            if (std.mem.eql(u8, host.name, line_type)) @compileError("HostEvent tag collides with a wire line type: " ++ host.name);
        }
        for (std.meta.fields(CoreEvent)) |core| {
            if (std.mem.eql(u8, core.name, line_type)) @compileError("CoreEvent tag collides with a wire line type: " ++ core.name);
        }
    }
}

/// Whether `name` is the `type` of a v1 line: a CoreEvent or HostEvent tag,
/// or a request or capability line. A frontend ignores a `type` it does not
/// know (doc/WIRE_PROTOCOL.md §4); a check of what a Host journals uses this
/// to refuse any line outside the grammar.
pub fn isLineType(name: []const u8) bool {
    inline for (std.meta.fields(CoreEvent)) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    inline for (std.meta.fields(HostEvent)) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    for (LINE_TYPES) |line_type| {
        if (std.mem.eql(u8, line_type, name)) return true;
    }
    return false;
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
        .user_message => |message| try writeUserMessage(json, message),
        inline else => |payload| try json.write(payload),
    }
    try json.endObject();
}

fn writeUserMessage(json: *std.json.Stringify, message: UserMessage) std.json.Stringify.Error!void {
    try json.beginObject();
    try json.objectField("run_id");
    try json.write(message.run_id);
    try json.objectField("trace_id");
    try json.write(message.trace_id);
    try json.objectField("text");
    try json.write(message.text);
    try json.objectField("replaces");
    try json.write(message.replaces);
    if (message.source) |source| {
        try json.objectField("source");
        try json.write(source);
    }
    if (message.kind) |kind| {
        try json.objectField("kind");
        try json.write(kind);
    }
    if (message.idempotency_key) |key| {
        try json.objectField("idempotency_key");
        try json.write(key);
    }
    if (message.attributes.len != 0) {
        try json.objectField("attributes");
        try typed_submission.writeAttributes(json, message.attributes);
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
        .goal_updated => |updated| try writeGoal(json, updated),
        inline else => |payload| {
            if (@TypeOf(payload) == void) try json.write(null) else try json.write(payload);
        },
    }
    try json.endObject();
}

/// Field for field as `goal.writeJson`, so every surface spells a goal alike.
fn writeGoal(json: *std.json.Stringify, updated: *const goal.Goal) std.json.Stringify.Error!void {
    try json.beginObject();
    try json.objectField("id");
    try json.write(updated.id[0..]);
    try json.objectField("objective");
    try json.write(updated.objective);
    try json.objectField("status");
    try json.write(@tagName(updated.status));
    try json.objectField("token_budget");
    try json.write(updated.token_budget);
    try json.objectField("tokens_used");
    try json.write(updated.tokens_used);
    try json.objectField("time_used_ms");
    try json.write(updated.time_used_ms);
    try json.objectField("created_at_ms");
    try json.write(updated.created_at_ms);
    try json.objectField("updated_at_ms");
    try json.write(updated.updated_at_ms);
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

/// `writeRequestClosed` with `by`, who gave the answer the request closed on
/// (`answerApprover`), appended under doc/WIRE_PROTOCOL.md §4's additive rule
/// 2 (#446). Null writes exactly `writeRequestClosed`'s line, so a request
/// whose answer named nobody keeps its bytes. Caller-owned.
pub fn writeRequestClosedBy(allocator: std.mem.Allocator, id: u64, outcome: RequestClosed, by: ?[]const u8) error{OutOfMemory}![]u8 {
    const approver = by orelse return writeRequestClosed(allocator, id, outcome);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    writeRequestClosedTo(&json, id, outcome, approver) catch return error.OutOfMemory;
    return finish(allocator, &out);
}

fn writeRequestClosedTo(json: *std.json.Stringify, id: u64, outcome: RequestClosed, approver: []const u8) std.json.Stringify.Error!void {
    try json.beginObject();
    try json.objectField("v");
    try json.write(SCHEMA_VERSION);
    try json.objectField("type");
    try json.write("ui_request_closed");
    try json.objectField("id");
    try json.write(id);
    try json.objectField("outcome");
    try json.write(@tagName(outcome));
    try json.objectField("by");
    try json.write(approver);
    try json.endObject();
}

/// The longest approver (`by`) an answer may name, in bytes.
pub const MAX_APPROVER_BYTES: usize = 256;

pub const ApproverError = error{
    /// `by` is present but is not a JSON string of 1 to `MAX_APPROVER_BYTES`
    /// bytes. A Host refuses such an answer before it is taken, so a request
    /// is never closed on an answer whose approver could not be recorded.
    InvalidApprover,
    OutOfMemory,
};

/// Who gave `json`, an answer to a UI request, as it names them in its
/// optional `by` field (#446), copied into `allocator`. Self-reported and
/// unauthenticated: a Host that needs a verified approver takes it from its
/// own authentication, not from an answer body. Null when it names
/// nobody: no `by`, `"by":null`, or an answer that is not a JSON object
/// (`parseResponse` reads that one as malformed anyway). The answer itself is
/// read by `parseResponse` alone; `by` never changes that reading.
pub fn answerApprover(allocator: std.mem.Allocator, json: []const u8) ApproverError!?[]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (parsed != .object) return null;
    const value = parsed.object.get("by") orelse return null;
    return switch (value) {
        .null => null,
        .string => |name| if (name.len == 0 or name.len > MAX_APPROVER_BYTES)
            error.InvalidApprover
        else
            try allocator.dupe(u8, name),
        else => error.InvalidApprover,
    };
}

/// A `ui_request` line read back: `writeRequest`'s inverse.
pub const Announcement = struct {
    id: u64,
    /// Slices into the arena given to `parseRequest`.
    request: UiRequest,
};

/// Reads a `ui_request` line `writeRequest` wrote, for a Host that keeps an
/// announcement and needs the request again (a suspended request after a
/// restart, #446). Everything is allocated in `arena`, which the caller frees
/// as a whole. A line that is not a v1 `ui_request` is `error.NotARequest`.
pub fn parseRequest(arena: std.mem.Allocator, line: []const u8) error{ NotARequest, OutOfMemory }!Announcement {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotARequest,
    };
    if (parsed != .object) return error.NotARequest;
    const object = parsed.object;
    const version = object.get("v") orelse return error.NotARequest;
    if (version != .integer or version.integer != SCHEMA_VERSION) return error.NotARequest;
    const line_type = stringOf(object, "type") orelse return error.NotARequest;
    if (!std.mem.eql(u8, line_type, "ui_request")) return error.NotARequest;
    const id = object.get("id") orelse return error.NotARequest;
    if (id != .integer or id.integer <= 0) return error.NotARequest;
    const kind = std.meta.stringToEnum(std.meta.Tag(UiRequest), stringOf(object, "kind") orelse return error.NotARequest) orelse
        return error.NotARequest;
    const body_value = object.get("request") orelse return error.NotARequest;
    if (body_value != .object) return error.NotARequest;
    const body = body_value.object;
    const request: UiRequest = switch (kind) {
        .permission => .{ .permission = .{
            .tool = stringOf(body, "tool") orelse return error.NotARequest,
            .args = stringOf(body, "args") orelse return error.NotARequest,
        } },
        .custom => .{ .custom = .{
            .kind = stringOf(body, "kind") orelse return error.NotARequest,
            .payload_json = stringOf(body, "payload_json") orelse return error.NotARequest,
        } },
        .ask_question => blk: {
            const list = body.get("questions") orelse return error.NotARequest;
            if (list != .array) return error.NotARequest;
            const questions = try arena.alloc(ui_request.AskQuestion, list.array.items.len);
            for (list.array.items, questions) |item, *question| {
                if (item != .object) return error.NotARequest;
                const multi = item.object.get("multi_select") orelse return error.NotARequest;
                if (multi != .bool) return error.NotARequest;
                const option_list = item.object.get("options") orelse return error.NotARequest;
                if (option_list != .array) return error.NotARequest;
                const options = try arena.alloc(ui_request.AskOption, option_list.array.items.len);
                for (option_list.array.items, options) |option_value, *option| {
                    if (option_value != .object) return error.NotARequest;
                    option.* = .{
                        .label = stringOf(option_value.object, "label") orelse return error.NotARequest,
                        .description = stringOf(option_value.object, "description") orelse return error.NotARequest,
                        .preview = stringOf(option_value.object, "preview") orelse return error.NotARequest,
                    };
                }
                question.* = .{
                    .question = stringOf(item.object, "question") orelse return error.NotARequest,
                    .header = stringOf(item.object, "header") orelse return error.NotARequest,
                    .multi = multi.bool,
                    .options = options,
                };
            }
            break :blk .{ .ask_question = questions };
        },
    };
    return .{ .id = @intCast(id.integer), .request = request };
}

fn stringOf(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

/// The line reporting that `request` was not announced because the
/// frontend's declaration excludes it, caller-owned. It takes no request id:
/// nothing is pending and nothing can answer it.
pub fn writeRequestUnavailable(
    allocator: std.mem.Allocator,
    request: *const UiRequest,
    reason: frontend_capabilities.Unavailable,
) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    writeRequestUnavailableTo(&json, request, reason) catch return error.OutOfMemory;
    return finish(allocator, &out);
}

fn writeRequestUnavailableTo(json: *std.json.Stringify, request: *const UiRequest, reason: frontend_capabilities.Unavailable) std.json.Stringify.Error!void {
    try json.beginObject();
    try json.objectField("v");
    try json.write(SCHEMA_VERSION);
    try json.objectField("type");
    try json.write("ui_request_unavailable");
    try json.objectField("kind");
    try json.write(@tagName(request.*));
    if (request.* == .custom) {
        try json.objectField("custom_kind");
        try json.write(request.custom.kind);
    }
    try json.objectField("reason");
    try json.write(@tagName(reason));
    try json.endObject();
}

// ── Capability frames (doc/WIRE_PROTOCOL.md §2) ──────────────────────────────

/// Why a capability frame was refused; its name is
/// `capabilities_refused.reason`.
pub const RefusalError = error{
    /// Not one JSON object.
    NotAnObject,
    /// Over `frontend_capabilities.MAX_FRAME_BYTES`.
    FrameTooLarge,
    /// `v` absent or not `SCHEMA_VERSION`.
    SchemaVersionMismatch,
    /// `type` is not "capabilities".
    NotCapabilities,
    /// `ui_requests` absent, or a list that is not an array of strings of at
    /// most `MAX_NAME_BYTES`.
    InvalidField,
    /// `ui_requests` lists "custom": custom kinds are declared in `custom`.
    CustomInUiRequests,
    /// A `custom` entry is not `<name>@<major>`.
    InvalidCustomKind,
    /// A list is longer than its bound.
    TooManyEntries,
};

pub const DeclareError = RefusalError || error{OutOfMemory};

/// Reads a frontend's capability frame. The Declaration owns its memory (an
/// arena over `gpa`); `json` is only borrowed for the call. Names this core
/// does not know are kept in `ignored_*`, not refused, so a newer frontend
/// is routed by what this core can deliver.
pub fn parseCapabilities(gpa: std.mem.Allocator, json: []const u8) DeclareError!frontend_capabilities.Declaration {
    const caps = frontend_capabilities;
    if (json.len > caps.MAX_FRAME_BYTES) return error.FrameTooLarge;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    // alloc_always: every string the Declaration keeps is in the arena, never
    // in the caller's buffer.
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotAnObject,
    };
    if (parsed != .object) return error.NotAnObject;
    const object = parsed.object;
    const version = object.get("v") orelse return error.SchemaVersionMismatch;
    if (version != .integer or version.integer != SCHEMA_VERSION) return error.SchemaVersionMismatch;
    const frame_type = object.get("type") orelse return error.NotCapabilities;
    if (frame_type != .string or !std.mem.eql(u8, frame_type.string, "capabilities")) return error.NotCapabilities;

    var named = std.EnumSet(caps.NamedKind).initEmpty();
    var ignored_ui_requests: std.ArrayList([]const u8) = .empty;
    const ui_requests = try stringList(object, "ui_requests", caps.MAX_UI_REQUESTS) orelse return error.InvalidField;
    for (ui_requests) |item| {
        const name = item.string;
        if (std.mem.eql(u8, name, "custom")) return error.CustomInUiRequests;
        if (std.meta.stringToEnum(caps.NamedKind, name)) |kind| {
            named.insert(kind);
        } else try appendDistinct(a, &ignored_ui_requests, name);
    }

    var custom: std.ArrayList([]const u8) = .empty;
    if (try stringList(object, "custom", caps.MAX_CUSTOM_KINDS)) |kinds| {
        for (kinds) |item| {
            if (!caps.isVersionedKind(item.string)) return error.InvalidCustomKind;
            try appendDistinct(a, &custom, item.string);
        }
    }

    var events: ?std.EnumSet(caps.EventTag) = null;
    var ignored_events: std.ArrayList([]const u8) = .empty;
    if (try stringList(object, "events", caps.MAX_EVENTS)) |names| {
        var set = std.EnumSet(caps.EventTag).initEmpty();
        for (names) |item| {
            if (std.meta.stringToEnum(caps.EventTag, item.string)) |tag| {
                set.insert(tag);
            } else try appendDistinct(a, &ignored_events, item.string);
        }
        events = set;
    }

    return .{
        .arena = arena,
        .capabilities = .{
            .named = named,
            .custom = try custom.toOwnedSlice(a),
            .events = events,
        },
        .ignored_ui_requests = try ignored_ui_requests.toOwnedSlice(a),
        .ignored_events = try ignored_events.toOwnedSlice(a),
    };
}

/// The strings of the array at `field`, or null when it is absent or null.
fn stringList(object: std.json.ObjectMap, field: []const u8, max: usize) RefusalError!?[]const std.json.Value {
    const value = object.get(field) orelse return null;
    if (value == .null) return null;
    if (value != .array) return error.InvalidField;
    const items = value.array.items;
    if (items.len > max) return error.TooManyEntries;
    for (items) |item| {
        if (item != .string or item.string.len > frontend_capabilities.MAX_NAME_BYTES) return error.InvalidField;
    }
    return items;
}

fn appendDistinct(a: std.mem.Allocator, list: *std.ArrayList([]const u8), name: []const u8) error{OutOfMemory}!void {
    for (list.items) |seen| {
        if (std.mem.eql(u8, seen, name)) return;
    }
    try list.append(a, name);
}

/// The `capabilities_accepted` line for `declaration`, caller-owned. Named
/// kinds and events are in UiRequest / CoreEvent tag order, custom kinds in
/// the frame's.
pub fn writeCapabilitiesAccepted(allocator: std.mem.Allocator, declaration: *const frontend_capabilities.Declaration) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer };
    writeCapabilitiesAcceptedTo(&json, declaration) catch return error.OutOfMemory;
    return finish(allocator, &out);
}

fn writeCapabilitiesAcceptedTo(json: *std.json.Stringify, declaration: *const frontend_capabilities.Declaration) std.json.Stringify.Error!void {
    const capabilities = &declaration.capabilities;
    try json.beginObject();
    try json.objectField("v");
    try json.write(SCHEMA_VERSION);
    try json.objectField("type");
    try json.write("capabilities_accepted");
    try json.objectField("ui_requests");
    try json.beginArray();
    var named = capabilities.named.iterator();
    while (named.next()) |kind| try json.write(@tagName(kind));
    try json.endArray();
    try json.objectField("custom");
    try json.write(capabilities.custom);
    try json.objectField("events");
    if (capabilities.events) |*events| {
        try json.beginArray();
        var tags = events.iterator();
        while (tags.next()) |tag| try json.write(@tagName(tag));
        try json.endArray();
    } else try json.write(null);
    try json.objectField("ignored");
    try json.beginObject();
    try json.objectField("ui_requests");
    try json.write(declaration.ignored_ui_requests);
    try json.objectField("events");
    try json.write(declaration.ignored_events);
    try json.endObject();
    try json.endObject();
}

/// The `capabilities_refused` reply to a frame `parseCapabilities` refused,
/// caller-owned. Its `v` tells a frontend of another version which one this
/// core speaks.
pub fn writeCapabilitiesRefused(allocator: std.mem.Allocator, reason: RefusalError) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"v\":{d},\"type\":\"capabilities_refused\",\"reason\":\"{s}\"}}", .{ SCHEMA_VERSION, @errorName(reason) });
}

/// An accepted frame and its `capabilities_accepted` line, both owned by the
/// allocator given to `acceptCapabilities`.
pub const Accepted = struct {
    declaration: frontend_capabilities.Declaration,
    line: []u8,
};

/// Parses a frame and writes its acknowledgement: what a Host installs in its
/// Session's `frontend_capabilities.Slot`. On error nothing is left to free.
pub fn acceptCapabilities(gpa: std.mem.Allocator, json: []const u8) DeclareError!Accepted {
    var declaration = try parseCapabilities(gpa, json);
    errdefer declaration.deinit();
    return .{ .declaration = declaration, .line = try writeCapabilitiesAccepted(gpa, &declaration) };
}

fn finish(allocator: std.mem.Allocator, out: *std.Io.Writer.Allocating) error{OutOfMemory}![]u8 {
    const raw = try out.toOwnedSlice();
    defer allocator.free(raw);
    return util_json.repairJsonUtf8(allocator, raw);
}

pub const CancelError = error{InputAborted} || ui_request.Unanswered;

/// How a requester fails a request that ended with nobody's answer. Nothing
/// is ever granted. A permission prompt fails with the `ui_request.Unanswered`
/// error naming `why`, so the gate denies it and tells the model the user did
/// not decline it; a question or a custom UI reports `error.InputAborted`, as
/// Esc does in the terminal.
pub fn cancelResponse(request: *const UiRequest, why: NoAnswer) CancelError {
    return switch (request.*) {
        .permission => switch (why) {
            .timed_out => error.UiRequestTimedOut,
            .cancelled => error.UiRequestCancelled,
            .unreadable => error.UiAnswerUnreadable,
        },
        .ask_question, .custom => error.InputAborted,
    };
}

pub const ParseError = error{ InputAborted, UiAnswerUnreadable, OutOfMemory };

/// The `ui_request_closed` outcome for a `parseResponse` failure: an answer
/// that could not be read is `malformed`; running out of memory reading it
/// is not the client's fault and closes as `cancelled`.
pub fn closedOnParseError(err: ParseError) RequestClosed {
    return switch (err) {
        error.InputAborted, error.UiAnswerUnreadable => NoAnswer.unreadable.closed(),
        error.OutOfMemory => .cancelled,
    };
}

/// Parses the Host's answer `json` to `request` into `out`. Answer slices
/// (`answers`, `custom`) are owned by `allocator`. Anything malformed fails as
/// `cancelResponse(request, .unreadable)` does and leaves `out` unwritten:
/// `error.UiAnswerUnreadable` for a permission prompt, `error.InputAborted`
/// for a question or a custom UI. The Host closes the request as
/// `closedOnParseError` says, or as `answered` when this returns.
pub fn parseResponse(
    request: *const UiRequest,
    json: []const u8,
    allocator: std.mem.Allocator,
    out: *UiResponse,
) ParseError!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json, .{}) catch
        return malformed(request);
    if (parsed != .object) return malformed(request);
    const object = parsed.object;
    if (object.get("v")) |version| {
        if (version != .integer or version.integer != SCHEMA_VERSION) return malformed(request);
    }

    switch (request.*) {
        .permission => {
            const choice = choiceField(object, PermissionChoice) orelse return malformed(request);
            out.* = .{ .permission = choice };
            return;
        },
        .ask_question => |questions| {
            const value = object.get("answers") orelse return malformed(request);
            if (value != .array or value.array.items.len != questions.len) return malformed(request);
            for (value.array.items) |item| {
                if (item != .string) return malformed(request);
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
            return;
        },
        .custom => {
            const result = object.get("result") orelse return malformed(request);
            const raw = try std.json.Stringify.valueAlloc(allocator, result, .{});
            defer allocator.free(raw);
            out.* = .{ .custom = try util_json.repairJsonUtf8(allocator, raw) };
            return;
        },
    }
}

fn malformed(request: *const UiRequest) error{ InputAborted, UiAnswerUnreadable } {
    return switch (request.*) {
        .permission => error.UiAnswerUnreadable,
        .ask_question, .custom => error.InputAborted,
    };
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

test "isLineType: every tag and line type of the grammar, and no transport frame" {
    for ([_][]const u8{ "text_chunk", "session_lifecycle", "user_message", "message_rejected", "session_poisoned", "run_resumed", "ui_request", "ui_request_closed", "ui_request_unavailable", "capabilities", "capabilities_accepted", "capabilities_refused" }) |name| {
        try testing.expect(isLineType(name));
    }
    // UDS `attach` frames sit outside the journal (doc/WIRE_PROTOCOL.md §1.3).
    for ([_][]const u8{ "keepalive", "session_closed", "resync", "Text_chunk", "" }) |name| {
        try testing.expect(!isLineType(name));
    }
}

test "writeHostEvent: message_rejected, and command_result with what it reports" {
    const rejected = try writeHostEvent(testing.allocator, .{ .message_rejected = .{ .message = "no", .text = "hi", .permission_mode = "auto" } });
    defer testing.allocator.free(rejected);
    try testing.expectEqualStrings("{\"v\":1,\"type\":\"message_rejected\",\"data\":{\"message\":\"no\",\"text\":\"hi\",\"model\":null,\"permission_mode\":\"auto\"}}", rejected);
    const result = try writeHostEvent(testing.allocator, .{ .command_result = .{ .command = "shell", .ok = true, .message = "$ ls" } });
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("{\"v\":1,\"type\":\"command_result\",\"data\":{\"command\":\"shell\",\"ok\":true,\"error_name\":null,\"message\":\"$ ls\"}}", result);
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
        // Unreadable, not the user's deny: the gate tells the model so.
        try testing.expectError(error.UiAnswerUnreadable, parseResponse(&request, json, testing.allocator, &out));
        try testing.expectEqual(RequestClosed.malformed, closedOnParseError(error.UiAnswerUnreadable));
    }
    var out: UiResponse = undefined;
    try parseResponse(&request, "{\"v\":1,\"choice\":\"allow_always\"}", testing.allocator, &out);
    try testing.expectEqual(PermissionChoice.allow_always, out.permission);
}

test "cancelResponse: a permission prompt nobody answered names why; the journal agrees" {
    const permission = UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    try testing.expectEqual(error.UiRequestTimedOut, cancelResponse(&permission, .timed_out));
    try testing.expectEqual(error.UiRequestCancelled, cancelResponse(&permission, .cancelled));
    try testing.expectEqual(error.UiAnswerUnreadable, cancelResponse(&permission, .unreadable));
    // v1's close outcomes are unchanged: a timeout still closes as cancelled.
    try testing.expectEqual(RequestClosed.cancelled, NoAnswer.timed_out.closed());
    try testing.expectEqual(RequestClosed.cancelled, NoAnswer.cancelled.closed());
    try testing.expectEqual(RequestClosed.malformed, NoAnswer.unreadable.closed());
    // A question or a custom UI aborts as Esc does, whatever the cause.
    const custom = UiRequest{ .custom = .{ .kind = "k@1", .payload_json = "{}" } };
    inline for (.{ NoAnswer.timed_out, NoAnswer.cancelled, NoAnswer.unreadable }) |why| {
        try testing.expectEqual(error.InputAborted, cancelResponse(&custom, why));
    }
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
    try parseResponse(&request, "{\"answers\":[\"Yes\",\"Yes, No\"]}", testing.allocator, &out);
    defer {
        for (out.answers) |answer| testing.allocator.free(answer);
        testing.allocator.free(out.answers);
    }
    try testing.expectEqualStrings("Yes, No", out.answers[1]);
}

test "parseResponse: a custom result reaches the tool as JSON text" {
    const request = UiRequest{ .custom = .{ .kind = "video_timeline", .payload_json = "{}" } };
    var out: UiResponse = undefined;
    try parseResponse(&request, "{\"result\":{\"in\":3,\"out\":42}}", testing.allocator, &out);
    defer testing.allocator.free(out.custom);
    try testing.expectEqualStrings("{\"in\":3,\"out\":42}", out.custom);
    try testing.expectError(error.InputAborted, parseResponse(&request, "{\"output\":1}", testing.allocator, &out));
}

test "acceptCapabilities: known names in tag order, custom kinds in frame order, unknown names ignored" {
    var accepted = try acceptCapabilities(testing.allocator,
        \\{"v":1,"type":"capabilities","ui_requests":["permission","form","ask_question","permission"],
        \\ "custom":["b@2","a@1","b@2"],"events":["stream_done","text_chunk","future_event"],"extra":true}
    );
    defer {
        accepted.declaration.deinit();
        testing.allocator.free(accepted.line);
    }
    try testing.expectEqualStrings(
        "{\"v\":1,\"type\":\"capabilities_accepted\",\"ui_requests\":[\"ask_question\",\"permission\"]," ++
            "\"custom\":[\"b@2\",\"a@1\"],\"events\":[\"text_chunk\",\"stream_done\"]," ++
            "\"ignored\":{\"ui_requests\":[\"form\"],\"events\":[\"future_event\"]}}",
        accepted.line,
    );
    const minimal = try acceptCapabilities(testing.allocator, "{\"v\":1,\"type\":\"capabilities\",\"ui_requests\":[],\"custom\":null}");
    var declaration = minimal.declaration;
    defer {
        declaration.deinit();
        testing.allocator.free(minimal.line);
    }
    try testing.expect(declaration.capabilities.events == null);
    try testing.expectEqualStrings(
        "{\"v\":1,\"type\":\"capabilities_accepted\",\"ui_requests\":[],\"custom\":[],\"events\":null,\"ignored\":{\"ui_requests\":[],\"events\":[]}}",
        minimal.line,
    );
}

test "parseCapabilities: every refusal reason, and the frame is never borrowed" {
    const cases = [_]struct { json: []const u8, err: RefusalError }{
        .{ .json = "[]", .err = error.NotAnObject },
        .{ .json = "{", .err = error.NotAnObject },
        .{ .json = "{\"type\":\"capabilities\",\"ui_requests\":[]}", .err = error.SchemaVersionMismatch },
        .{ .json = "{\"v\":2,\"type\":\"capabilities\",\"ui_requests\":[]}", .err = error.SchemaVersionMismatch },
        .{ .json = "{\"v\":1,\"type\":\"hello\",\"ui_requests\":[]}", .err = error.NotCapabilities },
        .{ .json = "{\"v\":1,\"type\":\"capabilities\"}", .err = error.InvalidField },
        .{ .json = "{\"v\":1,\"type\":\"capabilities\",\"ui_requests\":[1]}", .err = error.InvalidField },
        .{ .json = "{\"v\":1,\"type\":\"capabilities\",\"ui_requests\":[],\"events\":\"text_chunk\"}", .err = error.InvalidField },
        .{ .json = "{\"v\":1,\"type\":\"capabilities\",\"ui_requests\":[\"custom\"]}", .err = error.CustomInUiRequests },
        .{ .json = "{\"v\":1,\"type\":\"capabilities\",\"ui_requests\":[],\"custom\":[\"video_timeline\"]}", .err = error.InvalidCustomKind },
    };
    for (cases) |case| {
        try testing.expectError(case.err, parseCapabilities(testing.allocator, case.json));
    }
    const many = "{\"v\":1,\"type\":\"capabilities\",\"ui_requests\":[" ++ ("\"x\"," ** frontend_capabilities.MAX_UI_REQUESTS) ++ "\"x\"]}";
    try testing.expectError(error.TooManyEntries, parseCapabilities(testing.allocator, many));
    const huge = try testing.allocator.alloc(u8, frontend_capabilities.MAX_FRAME_BYTES + 1);
    defer testing.allocator.free(huge);
    @memset(huge, ' ');
    try testing.expectError(error.FrameTooLarge, parseCapabilities(testing.allocator, huge));

    const frame = try testing.allocator.dupe(u8, "{\"v\":1,\"type\":\"capabilities\",\"ui_requests\":[],\"custom\":[\"form@1\"]}");
    var declaration = try parseCapabilities(testing.allocator, frame);
    defer declaration.deinit();
    @memset(frame, 'x');
    testing.allocator.free(frame);
    try testing.expectEqualStrings("form@1", declaration.capabilities.custom[0]);

    const refused = try writeCapabilitiesRefused(testing.allocator, error.SchemaVersionMismatch);
    defer testing.allocator.free(refused);
    try testing.expectEqualStrings("{\"v\":1,\"type\":\"capabilities_refused\",\"reason\":\"SchemaVersionMismatch\"}", refused);
}

test "writeRequestUnavailable: custom requests name their kind, named ones do not" {
    const custom = UiRequest{ .custom = .{ .kind = "video_timeline@2", .payload_json = "{}" } };
    const line = try writeRequestUnavailable(testing.allocator, &custom, .custom_kind_not_declared);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("{\"v\":1,\"type\":\"ui_request_unavailable\",\"kind\":\"custom\",\"custom_kind\":\"video_timeline@2\",\"reason\":\"custom_kind_not_declared\"}", line);
    const permission = UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    const named = try writeRequestUnavailable(testing.allocator, &permission, .kind_not_declared);
    defer testing.allocator.free(named);
    try testing.expectEqualStrings("{\"v\":1,\"type\":\"ui_request_unavailable\",\"kind\":\"permission\",\"reason\":\"kind_not_declared\"}", named);
}

test "writeRequestClosedBy: the approver is appended and escaped; without one the line keeps its bytes" {
    const plain = try writeRequestClosed(testing.allocator, 4, .answered);
    defer testing.allocator.free(plain);
    const unnamed = try writeRequestClosedBy(testing.allocator, 4, .answered, null);
    defer testing.allocator.free(unnamed);
    try testing.expectEqualStrings(plain, unnamed);
    const named = try writeRequestClosedBy(testing.allocator, 4, .malformed, "ops \"on call\"");
    defer testing.allocator.free(named);
    try testing.expectEqualStrings("{\"v\":1,\"type\":\"ui_request_closed\",\"id\":4,\"outcome\":\"malformed\",\"by\":\"ops \\\"on call\\\"\"}", named);
}

test "answerApprover: a string of 1 to MAX_APPROVER_BYTES bytes; nobody when absent or null; anything else refused" {
    const a = testing.allocator;
    const alice = (try answerApprover(a, "{\"choice\":\"allow_once\",\"by\":\"alice@example.com\"}")).?;
    defer a.free(alice);
    try testing.expectEqualStrings("alice@example.com", alice);
    for ([_][]const u8{ "{\"choice\":\"allow_once\"}", "{\"by\":null}", "not json", "[\"by\"]" }) |json| {
        try testing.expect((try answerApprover(a, json)) == null);
    }
    const long = "{\"by\":\"" ++ ("x" ** (MAX_APPROVER_BYTES + 1)) ++ "\"}";
    for ([_][]const u8{ "{\"by\":\"\"}", "{\"by\":7}", "{\"by\":[\"alice\"]}", long }) |json| {
        try testing.expectError(error.InvalidApprover, answerApprover(a, json));
    }
    const longest = "{\"by\":\"" ++ ("x" ** MAX_APPROVER_BYTES) ++ "\"}";
    const kept = (try answerApprover(a, longest)).?;
    defer a.free(kept);
    try testing.expectEqual(MAX_APPROVER_BYTES, kept.len);
    // The answer is read the same with or without its approver.
    const request = UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    var out: UiResponse = undefined;
    try parseResponse(&request, "{\"choice\":\"allow_once\",\"by\":7}", a, &out);
    try testing.expectEqual(PermissionChoice.allow_once, out.permission);
}

test "parseRequest reads back every kind writeRequest writes, and refuses other lines" {
    const options = [_]ui_request.AskOption{
        .{ .label = "Ship", .description = "Release now" },
        .{ .label = "Wait", .description = "Hold", .preview = "## Plan" },
    };
    const questions = [_]ui_request.AskQuestion{.{ .question = "Ship now?", .header = "Decision", .multi = true, .options = &options }};
    const requests = [_]UiRequest{
        .{ .permission = .{ .tool = "Write", .args = "{\"file_path\":\"/x\"}" } },
        .{ .ask_question = &questions },
        .{ .custom = .{ .kind = "video_timeline@1", .payload_json = "{\"clips\":[]}" } },
    };
    for (&requests, 1..) |*request, id| {
        const line = try writeRequest(testing.allocator, id, request);
        defer testing.allocator.free(line);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const announced = try parseRequest(arena.allocator(), line);
        try testing.expectEqual(@as(u64, id), announced.id);
        const again = try writeRequest(testing.allocator, announced.id, &announced.request);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings(line, again);
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "{\"v\":1,\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"answered\"}",
        "{\"v\":2,\"type\":\"ui_request\",\"id\":1,\"kind\":\"custom\",\"request\":{\"kind\":\"k\",\"payload_json\":\"{}\"}}",
        "{\"v\":1,\"type\":\"ui_request\",\"id\":0,\"kind\":\"custom\",\"request\":{\"kind\":\"k\",\"payload_json\":\"{}\"}}",
        "{\"v\":1,\"type\":\"ui_request\",\"id\":1,\"kind\":\"form\",\"request\":{}}",
        "{\"v\":1,\"type\":\"ui_request\",\"id\":1,\"kind\":\"ask_question\",\"request\":{\"questions\":[{\"question\":\"q\"}]}}",
        "not json",
    }) |line| {
        try testing.expectError(error.NotARequest, parseRequest(arena.allocator(), line));
    }
}

test "writeHostEvent: run_resumed names the resumed Run, its trace and the request it waited for" {
    const line = try writeHostEvent(testing.allocator, .{ .run_resumed = .{ .run_id = 2, .trace_id = "t-1", .request_id = 7 } });
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("{\"v\":1,\"type\":\"run_resumed\",\"data\":{\"run_id\":2,\"trace_id\":\"t-1\",\"request_id\":7}}", line);
}
