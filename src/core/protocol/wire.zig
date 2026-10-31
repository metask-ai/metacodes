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
//! (core/session_host.zig): the submitted text, the end of a Run, the result
//! of a configuration command, a poisoned Session. Their tags never collide
//! with CoreEvent tags (checked at compile time).
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
//! A malformed answer is never a grant: `parseResponse` answers it the way a
//! cancelled request is answered (`cancelResponse`) and reports it as
//! `.malformed`, so the request closes as `"malformed"`, not `"answered"`.
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

const CoreEvent = ui_event.CoreEvent;
const UiRequest = ui_request.UiRequest;
const UiResponse = ui_request.UiResponse;
const RequestOutcome = ui_request.RequestOutcome;

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
    /// it failed. `model_error` says why, when the stop was a model failure.
    run_done: struct { run_id: u64, trace_id: ?[]const u8 = null, stop_reason: ?[]const u8 = null, error_name: ?[]const u8 = null, model_error: ?@import("../../api/model_error.zig").Detail.View = null },
    /// A configuration command was applied (`ok`) or refused.
    command_result: struct { command: []const u8, ok: bool, error_name: ?[]const u8 = null },
    /// The Session can no longer run; the Host must close it. Work still
    /// queued was dropped and is counted.
    session_poisoned: struct { error_name: []const u8, dropped: usize },
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

/// The answer to a request that was cancelled or answered unreadably: a
/// permission prompt is denied once, never granted;
/// a question or a custom UI reports `error.InputAborted`, as Esc does in the
/// terminal.
pub fn cancelResponse(request: *const UiRequest, out: *UiResponse) error{InputAborted}!RequestOutcome {
    switch (request.*) {
        .permission => {
            out.* = .{ .permission = .deny_once };
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
