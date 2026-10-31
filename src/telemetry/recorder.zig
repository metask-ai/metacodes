//! SpanRecorder: one Run's `CoreEvent` stream → an OpenTelemetry span tree.
//!
//! It is a `UiBackend` that renders nothing. `agent_loop.run` tees it next to
//! the real backend when `Options.telemetry` is set (the same decorator the
//! diagnostics backend uses), so every frontend - TUI, web, daemon, headless -
//! records the same tree without knowing about tracing. The tree follows the
//! OpenTelemetry GenAI semantic conventions:
//!
//! ```text
//! invoke_agent metacodes                 run: one per agent_loop.run
//! ├── turn 1                            diag_turn_begin … diag_turn_end
//! │   ├── chat <model>                  diag_model_request (CLIENT, one per attempt)
//! │   ├── execute_tool Bash             tool_start … tool_result
//! │   └── execute_tool Read
//! ├── turn 2
//! │   ├── compact                       diag_compact_begin … diag_compact_end
//! │   │   └── chat <model>              diag_compact_request
//! │   └── chat <model>
//! ```
//!
//! Point events (cache break, breaker, continuation, auto-compact, context
//! projection) become span events on the innermost open span. A span is handed
//! to the sinks the moment it ends, children before parents, so a viewer polling
//! the session store sees a long Run fill in as it goes.
//!
//! Timing: spans opened by an edge event (`turn_begin`, `tool_start`,
//! `compact_begin`) start at that event's arrival; the model request spans
//! start at `arrival - elapsed_ms` because the loop reports them once, after
//! the stream ended. Clocks are wall-clock Unix nanoseconds (`clock`, injected
//! for tests).
//!
//! The recorder never fails the Run: an allocation failure drops the span it
//! was building and is logged once.

const std = @import("std");
const sync = @import("platform").sync;
const span_mod = @import("span.zig");
const ui_backend = @import("../core/protocol/ui_backend.zig");
const json_util = @import("../util/json.zig");
const log = @import("../util/log.zig");

const Span = span_mod.Span;
const SpanId = span_mod.SpanId;
const TraceId = span_mod.TraceId;
const Attribute = span_mod.Attribute;
const Event = span_mod.Event;
const CoreEvent = ui_backend.CoreEvent;
const UiEvent = ui_backend.UiEvent;
const UiBackend = ui_backend.UiBackend;
const SessionId = ui_backend.SessionId;

/// Where finished spans go. Called with the recorder's lock held, on the
/// thread that emitted the closing event; the span and every slice in it are
/// valid only for the call.
pub const Sink = struct {
    ctx: *anyopaque,
    onEnd: *const fn (ctx: *anyopaque, span: *const Span) void,
};

pub const RunInfo = struct {
    session_id: []const u8,
    /// The model the Run's requests name.
    model: []const u8,
    /// `gen_ai.provider.name`; empty when unknown.
    provider: []const u8 = "",
    /// The user input this Run answers (message content).
    input: ?[]const u8 = null,
    agent_name: []const u8 = "metacodes",
};

/// Content kept per attribute while recording. The exporter's policy cuts
/// further (otlp.DEFAULT_MAX_CONTENT_BYTES); the session store keeps this much.
pub const MAX_RECORDED_CONTENT_BYTES: usize = 64 * 1024;

pub const Clock = *const fn () u64;

/// A span being built. Owns its strings (arena); heap-allocated so open tool
/// spans keep stable addresses while the list grows.
const Open = struct {
    arena: std.heap.ArenaAllocator,
    id: SpanId,
    parent: ?SpanId,
    name: []const u8,
    kind: span_mod.Kind,
    start: u64,
    attrs: std.ArrayList(Attribute) = .empty,
    events: std.ArrayList(Event) = .empty,
    /// Tool spans: the tool_use id they answer.
    tool_id: []const u8 = "",

    fn create(gpa: std.mem.Allocator, parent: ?SpanId, kind: span_mod.Kind, start: u64, comptime name_fmt: []const u8, name_args: anytype) !*Open {
        const self = try gpa.create(Open);
        errdefer gpa.destroy(self);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .id = SpanId.random(),
            .parent = parent,
            .name = "",
            .kind = kind,
            .start = start,
        };
        errdefer self.arena.deinit();
        self.name = try std.fmt.allocPrint(self.arena.allocator(), name_fmt, name_args);
        return self;
    }

    fn destroy(self: *Open, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn put(self: *Open, attr: Attribute) !void {
        const a = self.arena.allocator();
        var owned = attr;
        owned.key = try a.dupe(u8, attr.key);
        switch (attr.value) {
            .string => |s| owned.value = .{ .string = try a.dupe(u8, if (attr.content) span_mod.truncateUtf8(s, MAX_RECORDED_CONTENT_BYTES) else s) },
            else => {},
        }
        try self.attrs.append(a, owned);
    }

    fn event(self: *Open, name: []const u8, time: u64, attrs: []const Attribute) !void {
        const a = self.arena.allocator();
        const copy = try a.alloc(Attribute, attrs.len);
        for (attrs, copy) |src, *dst| {
            dst.* = src;
            dst.key = try a.dupe(u8, src.key);
            if (src.value == .string) dst.value = .{ .string = try a.dupe(u8, src.value.string) };
        }
        try self.events.append(a, .{ .name = try a.dupe(u8, name), .time_unix_nano = time, .attributes = copy });
    }
};

const PendingPolicy = struct {
    id: []u8,
    decision: []u8,
    source: []u8,
    allowed: bool,
};

const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_creation: u64 = 0,
    seen: bool = false,

    fn add(self: *Usage, u: anytype) void {
        self.input += u.input_tokens;
        self.output += u.output_tokens;
        self.cache_read += u.cache_read_input_tokens;
        self.cache_creation += u.cache_creation_input_tokens;
        self.seen = true;
    }

    fn put(self: Usage, open: *Open) !void {
        if (!self.seen) return;
        try open.put(Attribute.int("gen_ai.usage.input_tokens", self.input));
        try open.put(Attribute.int("gen_ai.usage.output_tokens", self.output));
        try open.put(Attribute.int("gen_ai.usage.cache_read.input_tokens", self.cache_read));
        try open.put(Attribute.int("gen_ai.usage.cache_creation.input_tokens", self.cache_creation));
    }
};

/// A finished model request whose span waits for the tool calls it made.
const PendingChat = struct {
    open: *Open,
    end_ns: u64,
    status: span_mod.Status,
    /// The JSON parts of the assistant message, comma-separated (in `open`'s arena).
    parts: std.ArrayList(u8) = .empty,

    fn addPart(self: *PendingChat, part: Part) !void {
        const a = self.open.arena.allocator();
        var out: std.Io.Writer.Allocating = .init(a);
        writePart(&out.writer, part) catch return error.OutOfMemory;
        if (self.parts.items.len > 0) try self.parts.append(a, ',');
        try self.parts.appendSlice(a, out.written());
    }

    fn addToolCall(self: *PendingChat, id: []const u8, name: []const u8, arguments: []const u8) !void {
        const a = self.open.arena.allocator();
        var out: std.Io.Writer.Allocating = .init(a);
        writeToolCall(&out.writer, id, name, arguments) catch return error.OutOfMemory;
        if (self.parts.items.len > 0) try self.parts.append(a, ',');
        try self.parts.appendSlice(a, out.written());
    }
};

pub const Outcome = union(enum) {
    /// The loop's stop reason (`diag_run_end`).
    stop_reason: []const u8,
    /// `agent_loop.run` returned an error before reporting a stop reason.
    failed: anyerror,
};

pub const Recorder = struct {
    gpa: std.mem.Allocator,
    sinks: []const Sink,
    clock: Clock,
    info: RunInfo,
    trace_id: TraceId,
    mutex: sync.Mutex = .{},

    run: ?*Open = null,
    turn: ?*Open = null,
    compact: ?*Open = null,
    tools: std.ArrayList(*Open) = .empty,
    policies: std.ArrayList(PendingPolicy) = .empty,

    /// Model output since the last model request span (content).
    text: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    /// The last model request's span, until its tool calls are known.
    chat: ?PendingChat = null,
    request_usage: Usage = .{},
    run_usage: Usage = .{},
    finished: bool = false,
    warned: bool = false,

    /// Start the Run span now. `info`'s slices are copied.
    pub fn init(gpa: std.mem.Allocator, sinks: []const Sink, info: RunInfo, clock: Clock) Recorder {
        var self: Recorder = .{
            .gpa = gpa,
            .sinks = sinks,
            .clock = clock,
            .info = info,
            .trace_id = TraceId.random(),
        };
        self.startRun() catch |err| self.noteFailure(err);
        return self;
    }

    pub fn traceId(self: *const Recorder) TraceId {
        return self.trace_id;
    }

    pub fn backend(self: *Recorder) UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emitThunk, .poll = pollThunk };
    }

    /// Close every open span with `outcome` (idempotent: `diag_run_end`
    /// normally gets here first).
    pub fn finish(self: *Recorder, outcome: Outcome) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.finishLocked(outcome);
    }

    pub fn deinit(self: *Recorder) void {
        self.finish(.{ .failed = error.RunAbandoned });
        self.text.deinit(self.gpa);
        self.thinking.deinit(self.gpa);
        self.tools.deinit(self.gpa);
        for (self.policies.items) |p| self.freePolicy(p);
        self.policies.deinit(self.gpa);
    }

    fn startRun(self: *Recorder) !void {
        const run = try Open.create(self.gpa, null, .internal, self.clock(), "invoke_agent {s}", .{self.info.agent_name});
        errdefer run.destroy(self.gpa);
        try run.put(Attribute.str("gen_ai.operation.name", "invoke_agent"));
        try run.put(Attribute.str("gen_ai.agent.name", self.info.agent_name));
        try run.put(Attribute.str("gen_ai.conversation.id", self.info.session_id));
        try run.put(Attribute.str("session.id", self.info.session_id));
        if (self.info.model.len > 0) try run.put(Attribute.str("gen_ai.request.model", self.info.model));
        if (self.info.provider.len > 0) try run.put(Attribute.str("gen_ai.provider.name", self.info.provider));
        const input = self.info.input orelse "";
        if (input.len > 0) {
            const messages = try messagesJson(run.arena.allocator(), "user", &.{.{ .kind = "text", .content = input }});
            try run.put(Attribute.text("gen_ai.input.messages", messages));
        }
        self.run = run;
    }

    fn pollThunk(_: *anyopaque, _: SessionId) ?UiEvent {
        return null;
    }

    fn emitThunk(ctx: *anyopaque, _: SessionId, ev: CoreEvent) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .text_chunk, .thinking_chunk, .usage, .tool_start, .tool_result, .policy_decision => {},
            .diag_turn_begin, .diag_turn_end, .diag_model_request, .diag_compact_request => {},
            .diag_compact_begin, .diag_compact_end, .diag_tool_stage, .diag_breaker_tripped => {},
            .diag_cache_break, .diag_continuation, .diag_run_end, .auto_compact, .context_projection => {},
            else => return,
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.finished) return;
        self.handle(ev) catch |err| self.noteFailure(err);
    }

    fn noteFailure(self: *Recorder, err: anyerror) void {
        if (self.warned) return;
        self.warned = true;
        log.warn("otel", "span recording degraded: {s}", .{@errorName(err)});
    }

    /// The span a point event belongs to.
    fn innermost(self: *Recorder) ?*Open {
        return self.compact orelse self.turn orelse self.run;
    }

    fn parentId(self: *Recorder) ?SpanId {
        return if (self.innermost()) |o| o.id else null;
    }

    fn handle(self: *Recorder, ev: CoreEvent) !void {
        const now = self.clock();
        // The pending chat span collects the tool calls that follow it (and
        // their permission decisions); anything else closes it.
        switch (ev) {
            .tool_start, .policy_decision, .usage => {},
            else => self.flushChat(),
        }
        switch (ev) {
            .text_chunk => |s| appendBounded(self.gpa, &self.text, s),
            .thinking_chunk => |s| appendBounded(self.gpa, &self.thinking, s),
            .usage => |u| {
                self.request_usage.add(u);
                self.run_usage.add(u);
            },
            .diag_turn_begin => |d| {
                if (self.turn) |open| {
                    self.turn = null;
                    self.end(open, now, .{ .@"error" = "turn superseded" });
                }
                const parent = if (self.run) |r| r.id else null;
                const turn = try Open.create(self.gpa, parent, .internal, now, "turn {d}", .{d.turn});
                errdefer turn.destroy(self.gpa);
                try turn.put(Attribute.int("metacodes.turn", d.turn));
                try turn.put(Attribute.str("metacodes.run.trace_id", &d.trace_id));
                self.turn = turn;
            },
            .diag_turn_end => |d| {
                self.endTools(now, .{ .@"error" = "tool result missing" });
                const turn = self.turn orelse return;
                self.turn = null;
                turn.put(Attribute.int("metacodes.turn.tool_calls_total", d.tool_calls)) catch {};
                self.endPolicies(turn, now);
                self.end(turn, now, .unset);
            },
            .diag_model_request => |d| try self.modelSpan(now, d.elapsed_ms, d.attempt, d.outcome, null),
            .diag_compact_begin => |d| {
                if (self.compact) |open| {
                    self.compact = null;
                    self.end(open, now, .{ .@"error" = "compaction superseded" });
                }
                const compact = try Open.create(self.gpa, self.parentId(), .internal, now, "compact", .{});
                errdefer compact.destroy(self.gpa);
                try compact.put(Attribute.str("metacodes.compact.cause", d.cause));
                self.compact = compact;
            },
            .diag_compact_request => |d| try self.modelSpan(now, d.elapsed_ms, 0, d.outcome, d.cause),
            .diag_compact_end => |d| {
                const compact = self.compact orelse return;
                self.compact = null;
                compact.put(Attribute.str("metacodes.compact.outcome", d.outcome)) catch {};
                const failed = !std.mem.eql(u8, d.outcome, "success") and !std.mem.eql(u8, d.outcome, "unchanged");
                self.end(compact, now, if (failed) .{ .@"error" = d.outcome } else .unset);
            },
            .tool_start => |t| {
                const tool = try Open.create(self.gpa, self.parentId(), .internal, now, "execute_tool {s}", .{t.name});
                errdefer tool.destroy(self.gpa);
                tool.tool_id = try tool.arena.allocator().dupe(u8, t.id);
                try tool.put(Attribute.str("gen_ai.operation.name", "execute_tool"));
                try tool.put(Attribute.str("gen_ai.tool.name", t.name));
                try tool.put(Attribute.str("gen_ai.tool.call.id", t.id));
                try tool.put(Attribute.str("gen_ai.tool.type", "function"));
                try tool.put(Attribute.text("gen_ai.tool.call.arguments", t.input));
                if (self.chat) |*pending| pending.addToolCall(t.id, t.name, t.input) catch {};
                if (self.takePolicy(t.id)) |p| {
                    defer self.freePolicy(p);
                    try tool.put(Attribute.str("metacodes.permission.decision", p.decision));
                    try tool.put(Attribute.str("metacodes.permission.source", p.source));
                    try tool.put(Attribute.boolean("metacodes.permission.allowed", p.allowed));
                }
                try self.tools.append(self.gpa, tool);
            },
            .tool_result => |t| {
                const tool = self.takeTool(t.id) orelse blk: {
                    // A result without a start: reconstruct the span from its elapsed time.
                    const start = now -| t.elapsed_ms * std.time.ns_per_ms;
                    const made = try Open.create(self.gpa, self.parentId(), .internal, start, "execute_tool {s}", .{t.name});
                    errdefer made.destroy(self.gpa);
                    try made.put(Attribute.str("gen_ai.operation.name", "execute_tool"));
                    try made.put(Attribute.str("gen_ai.tool.name", t.name));
                    try made.put(Attribute.str("gen_ai.tool.call.id", t.id));
                    try made.put(Attribute.text("gen_ai.tool.call.arguments", t.input));
                    break :blk made;
                };
                tool.put(Attribute.int("metacodes.tool.elapsed_ms", t.elapsed_ms)) catch {};
                tool.put(Attribute.text("gen_ai.tool.call.result", t.content)) catch {};
                if (t.is_error) tool.put(Attribute.str("error.type", "tool_error")) catch {};
                self.end(tool, now, if (t.is_error) .{ .@"error" = "tool returned an error" } else .unset);
            },
            .policy_decision => |p| {
                if (self.findTool(p.id)) |tool| {
                    try tool.event("permission", now, &.{
                        Attribute.str("decision", p.decision),
                        Attribute.str("source", p.source),
                        Attribute.boolean("allowed", p.allowed),
                    });
                    return;
                }
                const id = try self.gpa.dupe(u8, p.id);
                errdefer self.gpa.free(id);
                const decision = try self.gpa.dupe(u8, p.decision);
                errdefer self.gpa.free(decision);
                const source = try self.gpa.dupe(u8, p.source);
                errdefer self.gpa.free(source);
                try self.policies.append(self.gpa, .{ .id = id, .decision = decision, .source = source, .allowed = p.allowed });
            },
            .diag_tool_stage => |d| if (self.turn) |turn| {
                try turn.put(Attribute.int("metacodes.turn.tool_stage_ms", d.elapsed_ms));
            },
            .diag_cache_break => |d| if (self.innermost()) |o| try o.event("cache_break", now, &.{
                Attribute.int("gen_ai.usage.cache_read.input_tokens", d.cache_read),
                Attribute.int("gen_ai.usage.cache_creation.input_tokens", d.cache_creation),
            }),
            .diag_breaker_tripped => |d| if (self.innermost()) |o| try o.event("breaker_tripped", now, &.{
                Attribute.int("metacodes.same_error_count", d.same_err_count),
            }),
            .diag_continuation => |d| if (self.innermost()) |o| try o.event("continuation", now, &.{
                Attribute.int("metacodes.continuation", d.n),
                Attribute.int("metacodes.continuation.max", d.max),
            }),
            .auto_compact => |d| if (self.innermost()) |o| try o.event("auto_compact", now, &.{
                Attribute.str("cause", d.cause),
                Attribute.int("dropped_messages", d.dropped),
                Attribute.int("kept_messages", d.kept),
                Attribute.int("before_tokens", d.before_tokens),
                Attribute.int("after_tokens", d.after_tokens),
            }),
            .context_projection => |d| if (self.innermost()) |o| try o.event("context_projection", now, &.{
                Attribute.str("kind", d.kind),
                Attribute.str("cause", d.cause),
                Attribute.int("changed_items", d.changed_items),
                Attribute.int("bytes_before", d.bytes_before),
                Attribute.int("bytes_after", d.bytes_after),
            }),
            .diag_run_end => |d| {
                if (self.run) |run| {
                    run.put(Attribute.int("metacodes.run.turns", d.turns)) catch {};
                    run.put(Attribute.int("metacodes.run.tool_calls", d.tool_calls)) catch {};
                    run.put(Attribute.str("metacodes.run.trace_id", &d.trace_id)) catch {};
                }
                self.finishLocked(.{ .stop_reason = d.stop_reason_name });
            },
            else => {},
        }
    }

    /// A `chat` span for one provider request that has just completed.
    /// `compact_cause` marks a compact-summary request. A normal request's
    /// span stays pending until the next event that is not one of its tool
    /// calls, so the calls join its `gen_ai.output.messages`.
    fn modelSpan(self: *Recorder, now: u64, elapsed_ms: u64, attempt: u32, outcome: []const u8, compact_cause: ?[]const u8) !void {
        self.flushChat();
        const start = now -| elapsed_ms * std.time.ns_per_ms;
        const model = self.info.model;
        const chat = try Open.create(self.gpa, self.parentId(), .client, start, "chat {s}", .{model});
        errdefer chat.destroy(self.gpa);
        try chat.put(Attribute.str("gen_ai.operation.name", "chat"));
        if (model.len > 0) try chat.put(Attribute.str("gen_ai.request.model", model));
        if (self.info.provider.len > 0) try chat.put(Attribute.str("gen_ai.provider.name", self.info.provider));
        try chat.put(Attribute.str("metacodes.request.outcome", outcome));
        const ok = std.mem.eql(u8, outcome, "success");
        if (!ok) try chat.put(Attribute.str("error.type", outcome));
        const status: span_mod.Status = if (ok) .unset else .{ .@"error" = try chat.arena.allocator().dupe(u8, outcome) };
        if (compact_cause) |cause| {
            try chat.put(Attribute.str("metacodes.request.purpose", "compact"));
            try chat.put(Attribute.str("metacodes.compact.cause", cause));
            self.end(chat, now, status);
            return;
        }
        try chat.put(Attribute.int("metacodes.request.recovery_attempt", attempt));
        try self.request_usage.put(chat);
        var pending: PendingChat = .{ .open = chat, .end_ns = now, .status = status };
        if (self.thinking.items.len > 0) try pending.addPart(.{ .kind = "reasoning", .content = self.thinking.items });
        if (self.text.items.len > 0) try pending.addPart(.{ .kind = "text", .content = self.text.items });
        self.request_usage = .{};
        self.text.clearRetainingCapacity();
        self.thinking.clearRetainingCapacity();
        self.chat = pending;
    }

    /// End the pending chat span with the output it collected.
    fn flushChat(self: *Recorder) void {
        var pending = self.chat orelse return;
        self.chat = null;
        if (pending.parts.items.len > 0) {
            const a = pending.open.arena.allocator();
            if (std.mem.concat(a, u8, &.{ "[{\"role\":\"assistant\",\"parts\":[", pending.parts.items, "]}]" })) |messages| {
                pending.open.put(Attribute.text("gen_ai.output.messages", messages)) catch {};
            } else |_| {}
        }
        self.end(pending.open, pending.end_ns, pending.status);
    }

    fn findTool(self: *Recorder, id: []const u8) ?*Open {
        for (self.tools.items) |t| if (std.mem.eql(u8, t.tool_id, id)) return t;
        return null;
    }

    fn takeTool(self: *Recorder, id: []const u8) ?*Open {
        for (self.tools.items, 0..) |t, i| if (std.mem.eql(u8, t.tool_id, id)) return self.tools.orderedRemove(i);
        return null;
    }

    fn takePolicy(self: *Recorder, id: []const u8) ?PendingPolicy {
        for (self.policies.items, 0..) |p, i| if (std.mem.eql(u8, p.id, id)) return self.policies.orderedRemove(i);
        return null;
    }

    fn freePolicy(self: *Recorder, p: PendingPolicy) void {
        self.gpa.free(p.id);
        self.gpa.free(p.decision);
        self.gpa.free(p.source);
    }

    /// Decisions for tools that never started (denied before dispatch) are
    /// recorded as events on the span that was open when they were made.
    fn endPolicies(self: *Recorder, on: *Open, now: u64) void {
        for (self.policies.items) |p| {
            on.event("permission", now, &.{
                Attribute.str("gen_ai.tool.call.id", p.id),
                Attribute.str("decision", p.decision),
                Attribute.str("source", p.source),
                Attribute.boolean("allowed", p.allowed),
            }) catch {};
            self.freePolicy(p);
        }
        self.policies.clearRetainingCapacity();
    }

    fn endTools(self: *Recorder, now: u64, status: span_mod.Status) void {
        while (self.tools.pop()) |tool| self.end(tool, now, status);
    }

    fn finishLocked(self: *Recorder, outcome: Outcome) void {
        if (self.finished) return;
        self.finished = true;
        self.flushChat();
        const now = self.clock();
        const interrupted: span_mod.Status = .{ .@"error" = switch (outcome) {
            .stop_reason => |r| r,
            .failed => |err| @errorName(err),
        } };
        self.endTools(now, interrupted);
        if (self.compact) |c| {
            self.compact = null;
            self.end(c, now, interrupted);
        }
        if (self.turn) |t| {
            self.turn = null;
            self.endPolicies(t, now);
            self.end(t, now, interrupted);
        }
        const run = self.run orelse return;
        self.run = null;
        self.endPolicies(run, now);
        self.run_usage.put(run) catch {};
        switch (outcome) {
            .stop_reason => |reason| {
                run.put(Attribute.str("metacodes.run.stop_reason", reason)) catch {};
                self.end(run, now, runStatus(reason));
            },
            .failed => |err| {
                run.put(Attribute.str("error.type", @errorName(err))) catch {};
                self.end(run, now, .{ .@"error" = @errorName(err) });
            },
        }
    }

    /// Hand the finished span to every sink and free it.
    fn end(self: *Recorder, open: *Open, end_ns: u64, status: span_mod.Status) void {
        defer open.destroy(self.gpa);
        const s: Span = .{
            .trace_id = self.trace_id,
            .span_id = open.id,
            .parent_span_id = open.parent,
            .name = open.name,
            .kind = open.kind,
            .start_unix_nano = open.start,
            .end_unix_nano = @max(end_ns, open.start),
            .attributes = open.attrs.items,
            .events = open.events.items,
            .status = status,
        };
        for (self.sinks) |sink| sink.onEnd(sink.ctx, &s);
    }
};

/// Stop reasons that mean the Run did not do what it was asked.
fn runStatus(reason: []const u8) span_mod.Status {
    const failures = [_][]const u8{ "api_error", "tool_error", "tool_loop", "max_tokens_exhausted", "stalled" };
    for (failures) |f| if (std.mem.eql(u8, reason, f)) return .{ .@"error" = reason };
    return .unset;
}

fn appendBounded(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) void {
    const room = MAX_RECORDED_CONTENT_BYTES -| buf.items.len;
    if (room == 0) return;
    buf.appendSlice(gpa, span_mod.truncateUtf8(s, room)) catch {};
}

const Part = struct { kind: []const u8, content: []const u8 };

/// A semantic-convention `tool_call` part; the arguments stay the JSON text
/// the model produced, as a string.
fn writeToolCall(w: *std.Io.Writer, id: []const u8, name: []const u8, arguments: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("{\"type\":\"tool_call\",\"id\":");
    try json_util.writeJsonString(w, id);
    try w.writeAll(",\"name\":");
    try json_util.writeJsonString(w, name);
    try w.writeAll(",\"arguments\":");
    try json_util.writeJsonString(w, span_mod.truncateUtf8(arguments, MAX_RECORDED_CONTENT_BYTES));
    try w.writeByte('}');
}

fn writePart(w: *std.Io.Writer, p: Part) std.Io.Writer.Error!void {
    try w.print("{{\"type\":\"{s}\",\"content\":", .{p.kind});
    try json_util.writeJsonString(w, span_mod.truncateUtf8(p.content, MAX_RECORDED_CONTENT_BYTES));
    try w.writeByte('}');
}

/// `gen_ai.input.messages` / `gen_ai.output.messages`: the semantic
/// conventions' JSON message list with one message of `role`.
fn messagesJson(arena: std.mem.Allocator, role: []const u8, parts: []const Part) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print("[{{\"role\":\"{s}\",\"parts\":[", .{role}) catch return error.OutOfMemory;
    for (parts, 0..) |p, i| {
        if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
        writePart(w, p) catch return error.OutOfMemory;
    }
    w.writeAll("]}]") catch return error.OutOfMemory;
    return out.written();
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

/// Collects copies of the finished spans' shape for assertions.
const Captured = struct {
    name: []u8,
    id: SpanId,
    parent: ?SpanId,
    kind: span_mod.Kind,
    start: u64,
    end: u64,
    status: u8,
    attrs_json: []u8,
};

const Capture = struct {
    gpa: std.mem.Allocator,
    spans: std.ArrayList(Captured) = .empty,

    fn sink(self: *Capture) Sink {
        return .{ .ctx = @ptrCast(self), .onEnd = onEnd };
    }

    fn onEnd(ctx: *anyopaque, s: *const Span) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        const json = @import("otlp.zig").encodeSpanJson(self.gpa, s, .{ .include = true }) catch unreachable;
        self.spans.append(self.gpa, .{
            .name = self.gpa.dupe(u8, s.name) catch unreachable,
            .id = s.span_id,
            .parent = s.parent_span_id,
            .kind = s.kind,
            .start = s.start_unix_nano,
            .end = s.end_unix_nano,
            .status = s.status.code(),
            .attrs_json = json,
        }) catch unreachable;
    }

    fn deinit(self: *Capture) void {
        for (self.spans.items) |s| {
            self.gpa.free(s.name);
            self.gpa.free(s.attrs_json);
        }
        self.spans.deinit(self.gpa);
    }

    fn get(self: *Capture, name: []const u8) *Captured {
        for (self.spans.items) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        std.debug.panic("no span named {s}", .{name});
    }
};

var test_clock_ns: u64 = 0;
fn testClock() u64 {
    return test_clock_ns;
}
fn advance(ms: u64) void {
    test_clock_ns += ms * std.time.ns_per_ms;
}

test "otel: a run with one tool turn and a final answer builds the GenAI span tree" {
    const a = testing.allocator;
    var cap: Capture = .{ .gpa = a };
    defer cap.deinit();
    const sinks = [_]Sink{cap.sink()};
    test_clock_ns = 1_000 * std.time.ns_per_ms;
    var rec = Recorder.init(a, &sinks, .{ .session_id = "sess-1", .model = "claude-x", .provider = "anthropic", .input = "list files" }, testClock);
    defer rec.deinit();
    const be = rec.backend();
    const tid: [12]u8 = "abcd00010000".*;

    advance(1);
    be.emit(be.ctx, .single, .{ .diag_turn_begin = .{ .trace_id = tid, .depth = 0, .turn = 1 } });
    be.emit(be.ctx, .single, .{ .thinking_chunk = "plan" });
    be.emit(be.ctx, .single, .{ .text_chunk = "Let me look." });
    be.emit(be.ctx, .single, .{ .usage = .{ .input_tokens = 100, .output_tokens = 20, .cache_read_input_tokens = 50 } });
    advance(300);
    be.emit(be.ctx, .single, .{ .diag_model_request = .{ .trace_id = tid, .depth = 0, .turn = 1, .attempt = 0, .elapsed_ms = 250, .outcome = "success" } });
    be.emit(be.ctx, .single, .{ .policy_decision = .{ .trace_id = tid, .depth = 0, .id = "tu_1", .tool = "Bash", .decision = "allow", .source = "rule", .allowed = true } });
    be.emit(be.ctx, .single, .{ .tool_start = .{ .id = "tu_1", .name = "Bash", .input = "{\"command\":\"ls\"}" } });
    advance(40);
    be.emit(be.ctx, .single, .{ .tool_result = .{ .id = "tu_1", .name = "Bash", .input = "{\"command\":\"ls\"}", .content = "a.txt", .is_error = false, .elapsed_ms = 40 } });
    be.emit(be.ctx, .single, .{ .diag_turn_end = .{ .trace_id = tid, .depth = 0, .turn = 1, .tool_calls = 1 } });
    advance(1);
    be.emit(be.ctx, .single, .{ .diag_turn_begin = .{ .trace_id = tid, .depth = 0, .turn = 2 } });
    be.emit(be.ctx, .single, .{ .text_chunk = "Done: a.txt" });
    be.emit(be.ctx, .single, .{ .usage = .{ .input_tokens = 130, .output_tokens = 5 } });
    advance(100);
    be.emit(be.ctx, .single, .{ .diag_model_request = .{ .trace_id = tid, .depth = 0, .turn = 2, .attempt = 0, .elapsed_ms = 90, .outcome = "success" } });
    be.emit(be.ctx, .single, .{ .diag_turn_end = .{ .trace_id = tid, .depth = 0, .turn = 2, .tool_calls = 1 } });
    be.emit(be.ctx, .single, .{ .diag_run_end = .{ .trace_id = tid, .depth = 0, .turns = 2, .tool_calls = 1, .stop_reason_name = "end_turn" } });
    // Rendering-only events are ignored, and nothing is recorded after the end.
    be.emit(be.ctx, .single, .stream_begin);
    be.emit(be.ctx, .single, .{ .diag_turn_begin = .{ .trace_id = tid, .depth = 0, .turn = 3 } });

    // chat, tool, turn 1, chat, turn 2, run: children end before parents.
    try testing.expectEqual(@as(usize, 6), cap.spans.items.len);
    try testing.expectEqualStrings("invoke_agent metacodes", cap.spans.items[5].name);
    const run = cap.get("invoke_agent metacodes");
    const turn1 = cap.get("turn 1");
    const tool = cap.get("execute_tool Bash");
    const chat1 = &cap.spans.items[0];
    try testing.expectEqualStrings("chat claude-x", chat1.name);
    try testing.expect(run.parent == null);
    try testing.expectEqual(run.id, turn1.parent.?);
    try testing.expectEqual(turn1.id, chat1.parent.?);
    try testing.expectEqual(turn1.id, tool.parent.?);
    try testing.expectEqual(span_mod.Kind.client, chat1.kind);
    // The model span ends at the event and starts elapsed_ms earlier.
    try testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), chat1.end - chat1.start);
    try testing.expectEqual(@as(u64, 40 * std.time.ns_per_ms), tool.end - tool.start);

    try testing.expect(std.mem.indexOf(u8, chat1.attrs_json, "\"gen_ai.usage.input_tokens\",\"value\":{\"intValue\":\"100\"}") != null);
    try testing.expect(std.mem.indexOf(u8, chat1.attrs_json, "\"gen_ai.usage.cache_read.input_tokens\",\"value\":{\"intValue\":\"50\"}") != null);
    try testing.expect(std.mem.indexOf(u8, chat1.attrs_json, "{\\\"type\\\":\\\"reasoning\\\",\\\"content\\\":\\\"plan\\\"}") != null);
    try testing.expect(std.mem.indexOf(u8, chat1.attrs_json, "Let me look.") != null);
    try testing.expect(std.mem.indexOf(u8, chat1.attrs_json, "{\\\"type\\\":\\\"tool_call\\\",\\\"id\\\":\\\"tu_1\\\",\\\"name\\\":\\\"Bash\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, tool.attrs_json, "\"metacodes.permission.decision\",\"value\":{\"stringValue\":\"allow\"}") != null);
    try testing.expect(std.mem.indexOf(u8, tool.attrs_json, "\"gen_ai.tool.call.result\",\"value\":{\"stringValue\":\"a.txt\"}") != null);
    // Run totals: 100+130 in, 20+5 out.
    try testing.expect(std.mem.indexOf(u8, run.attrs_json, "\"gen_ai.usage.input_tokens\",\"value\":{\"intValue\":\"230\"}") != null);
    try testing.expect(std.mem.indexOf(u8, run.attrs_json, "\"gen_ai.usage.output_tokens\",\"value\":{\"intValue\":\"25\"}") != null);
    try testing.expect(std.mem.indexOf(u8, run.attrs_json, "\"metacodes.run.stop_reason\",\"value\":{\"stringValue\":\"end_turn\"}") != null);
    try testing.expect(std.mem.indexOf(u8, run.attrs_json, "\"gen_ai.conversation.id\",\"value\":{\"stringValue\":\"sess-1\"}") != null);
    try testing.expect(std.mem.indexOf(u8, run.attrs_json, "list files") != null);
    try testing.expectEqual(@as(u8, 0), run.status);
    // The second turn's chat carries only its own output and usage.
    const chat2 = &cap.spans.items[3];
    try testing.expect(std.mem.indexOf(u8, chat2.attrs_json, "Let me look.") == null);
    try testing.expect(std.mem.indexOf(u8, chat2.attrs_json, "\"gen_ai.usage.input_tokens\",\"value\":{\"intValue\":\"130\"}") != null);
}

test "otel: an aborted run closes the open turn and tool as errors; finish is idempotent" {
    const a = testing.allocator;
    var cap: Capture = .{ .gpa = a };
    defer cap.deinit();
    const sinks = [_]Sink{cap.sink()};
    test_clock_ns = 5 * std.time.ns_per_s;
    var rec = Recorder.init(a, &sinks, .{ .session_id = "s", .model = "m" }, testClock);
    defer rec.deinit();
    const be = rec.backend();
    const tid: [12]u8 = "000000000000".*;
    be.emit(be.ctx, .single, .{ .diag_turn_begin = .{ .trace_id = tid, .depth = 0, .turn = 1 } });
    be.emit(be.ctx, .single, .{ .policy_decision = .{ .trace_id = tid, .depth = 0, .id = "denied", .tool = "Write", .decision = "deny", .source = "user", .allowed = false } });
    be.emit(be.ctx, .single, .{ .tool_start = .{ .id = "t", .name = "Bash", .input = "{}" } });
    advance(10);
    rec.finish(.{ .failed = error.Interrupted });
    rec.finish(.{ .stop_reason = "end_turn" });

    try testing.expectEqual(@as(usize, 3), cap.spans.items.len);
    try testing.expectEqual(@as(u8, 2), cap.get("execute_tool Bash").status);
    const turn = cap.get("turn 1");
    try testing.expectEqual(@as(u8, 2), turn.status);
    try testing.expect(std.mem.indexOf(u8, turn.attrs_json, "\"name\":\"permission\"") != null);
    const run = cap.get("invoke_agent metacodes");
    try testing.expectEqual(@as(u8, 2), run.status);
    try testing.expect(std.mem.indexOf(u8, run.attrs_json, "Interrupted") != null);
}

test "otel: compaction nests its summary request; failures and point events are kept" {
    const a = testing.allocator;
    var cap: Capture = .{ .gpa = a };
    defer cap.deinit();
    const sinks = [_]Sink{cap.sink()};
    test_clock_ns = 9 * std.time.ns_per_s;
    var rec = Recorder.init(a, &sinks, .{ .session_id = "s", .model = "m" }, testClock);
    defer rec.deinit();
    const be = rec.backend();
    const tid: [12]u8 = "000000000000".*;
    be.emit(be.ctx, .single, .{ .diag_turn_begin = .{ .trace_id = tid, .depth = 0, .turn = 1 } });
    be.emit(be.ctx, .single, .{ .diag_compact_begin = .{ .trace_id = tid, .depth = 0, .turn = 1, .cause = "threshold" } });
    advance(500);
    be.emit(be.ctx, .single, .{ .diag_compact_request = .{ .trace_id = tid, .depth = 0, .turn = 1, .elapsed_ms = 400, .outcome = "success", .cause = "threshold" } });
    be.emit(be.ctx, .single, .{ .auto_compact = .{ .dropped = 10, .kept = 2, .cause = "threshold" } });
    be.emit(be.ctx, .single, .{ .diag_compact_end = .{ .trace_id = tid, .depth = 0, .turn = 1, .elapsed_ms = 500, .outcome = "success", .cause = "threshold" } });
    be.emit(be.ctx, .single, .{ .diag_cache_break = .{ .trace_id = tid, .depth = 0, .cache_read = 0, .cache_creation = 900 } });
    be.emit(be.ctx, .single, .{ .diag_model_request = .{ .trace_id = tid, .depth = 0, .turn = 1, .attempt = 1, .elapsed_ms = 5, .outcome = "api_error" } });
    be.emit(be.ctx, .single, .{ .diag_run_end = .{ .trace_id = tid, .depth = 0, .turns = 1, .tool_calls = 0, .stop_reason_name = "api_error" } });

    const compact = cap.get("compact");
    const summary = &cap.spans.items[0];
    try testing.expectEqual(compact.id, summary.parent.?);
    try testing.expect(std.mem.indexOf(u8, summary.attrs_json, "\"metacodes.request.purpose\",\"value\":{\"stringValue\":\"compact\"}") != null);
    try testing.expect(std.mem.indexOf(u8, compact.attrs_json, "\"name\":\"auto_compact\"") != null);
    const turn = cap.get("turn 1");
    try testing.expect(std.mem.indexOf(u8, turn.attrs_json, "\"name\":\"cache_break\"") != null);
    const failed_chat = &cap.spans.items[2];
    try testing.expectEqual(@as(u8, 2), failed_chat.status);
    try testing.expectEqual(@as(u8, 2), cap.get("invoke_agent metacodes").status);
}
