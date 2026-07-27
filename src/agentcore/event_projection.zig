//! AgentCore-only fork event projection and A1 final-text reconstruction.
//!
//! The child still runs at its true agent depth. This adapter decides which
//! semantic events reach the outer ABI Run and independently reconstructs the
//! final answer from closed response segments and public tool boundaries.

const std = @import("std");
const sync = @import("platform").sync;
const core = @import("metacodes-core");

const CoreEvent = core.protocol.ui_event.CoreEvent;
const UiBackend = core.protocol.ui_backend.UiBackend;
const UiEvent = core.protocol.ui_event.UiEvent;
const SessionId = core.session_id.SessionId;

pub const Mode = enum {
    external_run_root,
    model_tool,
};

pub const Projector = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    downstream: *const UiBackend,
    mutex: sync.Mutex = .{},
    current_segment: std.ArrayList(u8) = .empty,
    closed_segments: std.ArrayList(u8) = .empty,
    reconstruction_error: ?anyerror = null,

    pub fn init(
        allocator: std.mem.Allocator,
        mode: Mode,
        downstream: *const UiBackend,
    ) Projector {
        return .{
            .allocator = allocator,
            .mode = mode,
            .downstream = downstream,
        };
    }

    pub fn deinit(self: *Projector) void {
        self.mutex.lock();
        self.current_segment.deinit(self.allocator);
        self.closed_segments.deinit(self.allocator);
        self.mutex.unlock();
        self.* = undefined;
    }

    pub fn backend(self: *Projector) UiBackend {
        return .{
            .ctx = self,
            .emit = emit,
            .poll = poll,
        };
    }

    /// Copy the last answer-group's closed segments. Any text in an unclosed
    /// segment is provisional and is deliberately excluded.
    pub fn appendFinalText(
        self: *Projector,
        out: *std.ArrayList(u8),
    ) error{OutOfMemory}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.reconstruction_error != null) return error.OutOfMemory;
        try out.appendSlice(self.allocator, self.closed_segments.items);
    }

    fn emit(raw: *anyopaque, session: SessionId, event: CoreEvent) void {
        const self: *Projector = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();

        self.observe(event);
        if (self.shouldForward(event)) {
            self.downstream.emitEvent(session, event);
        }
    }

    fn poll(raw: *anyopaque, session: SessionId) ?UiEvent {
        const self: *Projector = @ptrCast(@alignCast(raw));
        return self.downstream.pollEvent(session);
    }

    fn observe(self: *Projector, event: CoreEvent) void {
        if (self.reconstruction_error != null) return;
        switch (event) {
            .text_chunk => |bytes| {
                self.current_segment.appendSlice(self.allocator, bytes) catch {
                    self.reconstruction_error = error.OutOfMemory;
                };
            },
            .stream_done => {
                self.closed_segments.appendSlice(
                    self.allocator,
                    self.current_segment.items,
                ) catch {
                    self.reconstruction_error = error.OutOfMemory;
                    return;
                };
                self.current_segment.clearRetainingCapacity();
            },
            .tool_start, .tool_result => {
                // A boundary invalidates both earlier closed responses and any
                // currently open segment. Consecutive boundaries are idempotent.
                self.closed_segments.clearRetainingCapacity();
                self.current_segment.clearRetainingCapacity();
            },
            else => {},
        }
    }

    fn shouldForward(self: *const Projector, event: CoreEvent) bool {
        return switch (self.mode) {
            .external_run_root => true,
            .model_tool => switch (event) {
                .text_chunk, .stream_done, .usage => true,
                else => false,
            },
        };
    }
};

const EventProbe = struct {
    text: usize = 0,
    stream_done: usize = 0,
    tool_start: usize = 0,
    tool_progress: usize = 0,
    tool_result: usize = 0,
    usage: usize = 0,

    fn backend(self: *EventProbe) UiBackend {
        return .{ .ctx = self, .emit = emit, .poll = poll };
    }

    fn emit(raw: *anyopaque, _: SessionId, event: CoreEvent) void {
        const self: *EventProbe = @ptrCast(@alignCast(raw));
        switch (event) {
            .text_chunk => self.text += 1,
            .stream_done => self.stream_done += 1,
            .tool_start => self.tool_start += 1,
            .tool_progress => self.tool_progress += 1,
            .tool_result => self.tool_result += 1,
            .usage => self.usage += 1,
            else => {},
        }
    }

    fn poll(_: *anyopaque, _: SessionId) ?UiEvent {
        return null;
    }
};

fn feedFixture(backend: *const UiBackend) void {
    backend.emitEvent(.single, .{ .text_chunk = "answer" });
    backend.emitEvent(.single, .stream_done);
    backend.emitEvent(.single, .{ .tool_start = .{
        .id = "tool-1",
        .name = "Read",
        .input = "{}",
    } });
    backend.emitEvent(.single, .{ .tool_progress = .{
        .id = "tool-1",
        .text = "working",
    } });
    backend.emitEvent(.single, .{ .tool_result = .{
        .id = "tool-1",
        .name = "Read",
        .input = "{}",
        .content = "ok",
        .is_error = false,
    } });
    backend.emitEvent(.single, .{ .usage = .{
        .input_tokens = 3,
        .output_tokens = 2,
    } });
}

test "A1 joins continuation segments and ignores an unclosed tail" {
    var probe = EventProbe{};
    const downstream = probe.backend();
    var projector = Projector.init(
        std.testing.allocator,
        .external_run_root,
        &downstream,
    );
    defer projector.deinit();
    const backend = projector.backend();

    backend.emitEvent(.single, .{ .text_chunk = "head" });
    backend.emitEvent(.single, .stream_done);
    backend.emitEvent(.single, .{ .text_chunk = "tail" });
    backend.emitEvent(.single, .stream_done);
    backend.emitEvent(.single, .{ .text_chunk = "provisional" });

    var final = std.ArrayList(u8).empty;
    defer final.deinit(std.testing.allocator);
    try projector.appendFinalText(&final);
    try std.testing.expectEqualStrings("headtail", final.items);
}

test "A1 tool boundaries discard closed and unclosed segments" {
    var probe = EventProbe{};
    const downstream = probe.backend();
    var projector = Projector.init(
        std.testing.allocator,
        .external_run_root,
        &downstream,
    );
    defer projector.deinit();
    const backend = projector.backend();

    backend.emitEvent(.single, .{ .text_chunk = "old-closed" });
    backend.emitEvent(.single, .stream_done);
    backend.emitEvent(.single, .{ .text_chunk = "old-open" });
    backend.emitEvent(.single, .{ .tool_start = .{
        .id = "tool-1",
        .name = "Read",
        .input = "{}",
    } });
    backend.emitEvent(.single, .{ .text_chunk = "between-boundaries" });
    backend.emitEvent(.single, .stream_done);
    backend.emitEvent(.single, .{ .tool_result = .{
        .id = "tool-1",
        .name = "Read",
        .input = "{}",
        .content = "ok",
        .is_error = false,
    } });
    backend.emitEvent(.single, .{ .tool_progress = .{
        .id = "tool-1",
        .text = "not-a-boundary",
    } });
    backend.emitEvent(.single, .{ .text_chunk = "final-1" });
    backend.emitEvent(.single, .stream_done);
    backend.emitEvent(.single, .{ .text_chunk = "final-2" });
    backend.emitEvent(.single, .stream_done);

    var final = std.ArrayList(u8).empty;
    defer final.deinit(std.testing.allocator);
    try projector.appendFinalText(&final);
    try std.testing.expectEqualStrings("final-1final-2", final.items);
}

test "run-root and model-tool projections expose different public surfaces" {
    var root_probe = EventProbe{};
    const root_downstream = root_probe.backend();
    var root = Projector.init(
        std.testing.allocator,
        .external_run_root,
        &root_downstream,
    );
    defer root.deinit();
    const root_backend = root.backend();
    feedFixture(&root_backend);
    try std.testing.expectEqual(@as(usize, 1), root_probe.text);
    try std.testing.expectEqual(@as(usize, 1), root_probe.stream_done);
    try std.testing.expectEqual(@as(usize, 1), root_probe.tool_start);
    try std.testing.expectEqual(@as(usize, 1), root_probe.tool_progress);
    try std.testing.expectEqual(@as(usize, 1), root_probe.tool_result);
    try std.testing.expectEqual(@as(usize, 1), root_probe.usage);

    var model_probe = EventProbe{};
    const model_downstream = model_probe.backend();
    var model = Projector.init(
        std.testing.allocator,
        .model_tool,
        &model_downstream,
    );
    defer model.deinit();
    const model_backend = model.backend();
    feedFixture(&model_backend);
    try std.testing.expectEqual(@as(usize, 1), model_probe.text);
    try std.testing.expectEqual(@as(usize, 1), model_probe.stream_done);
    try std.testing.expectEqual(@as(usize, 0), model_probe.tool_start);
    try std.testing.expectEqual(@as(usize, 0), model_probe.tool_progress);
    try std.testing.expectEqual(@as(usize, 0), model_probe.tool_result);
    try std.testing.expectEqual(@as(usize, 1), model_probe.usage);
}

test "model-tool hides internal boundaries without losing them for A1 reconstruction" {
    var probe = EventProbe{};
    const downstream = probe.backend();
    var projector = Projector.init(
        std.testing.allocator,
        .model_tool,
        &downstream,
    );
    defer projector.deinit();
    const backend = projector.backend();

    backend.emitEvent(.single, .{ .text_chunk = "pre-tool" });
    backend.emitEvent(.single, .stream_done);
    backend.emitEvent(.single, .{ .tool_start = .{
        .id = "tool-1",
        .name = "Read",
        .input = "{}",
    } });
    backend.emitEvent(.single, .{ .tool_result = .{
        .id = "tool-1",
        .name = "Read",
        .input = "{}",
        .content = "ok",
        .is_error = false,
    } });
    backend.emitEvent(.single, .{ .text_chunk = "final" });
    backend.emitEvent(.single, .stream_done);

    var final = std.ArrayList(u8).empty;
    defer final.deinit(std.testing.allocator);
    try projector.appendFinalText(&final);
    try std.testing.expectEqualStrings("final", final.items);
    try std.testing.expectEqual(@as(usize, 2), probe.text);
    try std.testing.expectEqual(@as(usize, 2), probe.stream_done);
    try std.testing.expectEqual(@as(usize, 0), probe.tool_start);
    try std.testing.expectEqual(@as(usize, 0), probe.tool_result);
}
