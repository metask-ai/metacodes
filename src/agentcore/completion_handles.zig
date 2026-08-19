//! AgentCore-owned lifetime and projection layer for independent text completions.
//!
//! The public Completion surface is deliberately separate from AgentRuntime and
//! Session. Each handle owns one Provider and admits at most one active complete
//! call or stream. Public `complete` drains the same streaming Provider path used
//! by public streams so every supported Provider has one canonical implementation.

const std = @import("std");
const sync = @import("platform").sync;
const core = @import("metacodes-core");
const completion_mod = core.api_completion;
const provider_factory = core.api_provider_factory;
const api_stream = core.api_stream;
const types = core.types;
const AbortSignal = core.util_abort.AbortSignal;
const AbortReason = core.util_abort.Reason;

pub const MAX_RESULT_BYTES: usize = 16 * 1024 * 1024;

pub const TextMessage = struct {
    role: types.MessageRole,
    text: []const u8,
};

pub const Request = struct {
    messages: []const TextMessage,
    system: ?[]const u8,
};

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,

    fn add(self: *Usage, delta: api_stream.UsageDelta) error{ResourceLimit}!void {
        self.input_tokens = std.math.add(u64, self.input_tokens, delta.input_tokens) catch
            return error.ResourceLimit;
        self.output_tokens = std.math.add(u64, self.output_tokens, delta.output_tokens) catch
            return error.ResourceLimit;
        self.cache_read_input_tokens = std.math.add(
            u64,
            self.cache_read_input_tokens,
            delta.cache_read_input_tokens,
        ) catch return error.ResourceLimit;
        self.cache_creation_input_tokens = std.math.add(
            u64,
            self.cache_creation_input_tokens,
            delta.cache_creation_input_tokens,
        ) catch return error.ResourceLimit;
    }
};

pub const StopReason = enum {
    unknown,
    end_turn,
    max_tokens,
    stop_sequence,
    pause_turn,
    refusal,
    aborted,
};

pub const Result = struct {
    text: []u8,
    usage: Usage,
    stop_reason: StopReason,
};

pub const Event = union(enum) {
    text: []u8,
    thinking: []u8,
    usage: Usage,
    done: StopReason,
};

pub const Completion = struct {
    const State = enum { idle, complete_active, stream_active, destroyed };

    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    state: State = .idle,
    api_key: []u8,
    base_url: ?[]u8,
    model: []u8,
    owned_provider: provider_factory.OwnedProvider,
    runtime: completion_mod.CompletionRuntime,

    pub fn create(
        allocator: std.mem.Allocator,
        provider_kind: types.ProviderKind,
        api_key: []const u8,
        model: []const u8,
        base_url: ?[]const u8,
    ) !*Completion {
        const self = try allocator.create(Completion);
        errdefer allocator.destroy(self);
        const owned_api_key = try allocator.dupe(u8, api_key);
        errdefer {
            @memset(owned_api_key, 0);
            allocator.free(owned_api_key);
        }
        const owned_model = try allocator.dupe(u8, model);
        errdefer allocator.free(owned_model);
        const owned_base_url = if (base_url) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_base_url) |value| allocator.free(value);

        var owned_provider = try provider_factory.makeProvider(
            allocator,
            provider_kind,
            owned_api_key,
            owned_model,
            owned_base_url,
        );
        errdefer owned_provider.deinit();
        const runtime = completion_mod.CompletionRuntime.init(owned_provider.provider());
        self.* = .{
            .allocator = allocator,
            .api_key = owned_api_key,
            .base_url = owned_base_url,
            .model = owned_model,
            .owned_provider = owned_provider,
            .runtime = runtime,
        };
        return self;
    }

    pub fn destroy(self: *Completion) error{Busy}!void {
        self.mutex.lock();
        if (self.state != .idle) {
            self.mutex.unlock();
            return error.Busy;
        }
        self.state = .destroyed;
        self.mutex.unlock();

        const allocator = self.allocator;
        self.owned_provider.deinit();
        @memset(self.api_key, 0);
        allocator.free(self.api_key);
        if (self.base_url) |value| allocator.free(value);
        allocator.free(self.model);
        allocator.destroy(self);
    }

    pub fn providerKind(self: *const Completion) types.ProviderKind {
        return self.owned_provider.kind();
    }

    pub fn configuredModel(self: *const Completion) []const u8 {
        return self.model;
    }

    pub fn complete(self: *Completion, request: Request) !Result {
        try self.enter(.complete_active);
        defer self.leave(.complete_active);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const api_messages = try buildMessages(arena.allocator(), request.messages);
        var abort = AbortSignal.init();
        var stream = try self.runtime.stream(.{
            .messages = api_messages,
            .system = request.system,
            .abort = &abort,
        });
        defer stream.deinit();

        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(self.allocator);
        var usage = Usage{};
        while (try stream.next()) |event| {
            defer deinitProviderEvent(self.allocator, event);
            switch (event) {
                .text => |part| {
                    const next_len = std.math.add(usize, text.items.len, part.len) catch
                        return error.ResourceLimit;
                    if (next_len > MAX_RESULT_BYTES) return error.ResourceLimit;
                    try text.appendSlice(self.allocator, part);
                },
                .thinking => {},
                .usage => |delta| try usage.add(delta),
                .done => break,
                .tool_use_start, .web_search_result, .web_search_query => return error.UnsupportedResponse,
            }
        }
        return .{
            .text = try text.toOwnedSlice(self.allocator),
            .usage = usage,
            .stop_reason = mapStopReason(stream.stopReason()),
        };
    }

    pub fn startStream(self: *Completion, request: Request) !*Stream {
        try self.enter(.stream_active);
        errdefer self.leave(.stream_active);

        const stream = try self.allocator.create(Stream);
        errdefer self.allocator.destroy(stream);
        stream.* = .{
            .allocator = self.allocator,
            .owner = self,
            .abort_signal = AbortSignal.init(),
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const api_messages = try buildMessages(arena.allocator(), request.messages);
        stream.inner = try self.runtime.stream(.{
            .messages = api_messages,
            .system = request.system,
            .abort = &stream.abort_signal,
        });
        return stream;
    }

    fn enter(self: *Completion, active: State) error{Busy}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .idle) return error.Busy;
        self.state = active;
    }

    fn leave(self: *Completion, active: State) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.state == active);
        self.state = .idle;
    }
};

pub const Stream = struct {
    allocator: std.mem.Allocator,
    owner: *Completion,
    abort_signal: AbortSignal,
    inner: ?completion_mod.StreamHandle = null,
    terminal: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn next(self: *Stream) !Event {
        if (self.terminal.load(.acquire)) return error.TooLate;
        const inner = self.inner orelse return error.InvalidState;
        const optional_event = inner.next() catch |err| {
            self.terminal.store(true, .release);
            if (err == error.Aborted and self.abort_signal.isAborted())
                return Event{ .done = .aborted };
            return err;
        };
        const event = optional_event orelse {
            self.terminal.store(true, .release);
            return .{ .done = mapStopReason(inner.stopReason()) };
        };
        return switch (event) {
            .text => |part| .{ .text = part },
            .thinking => |part| .{ .thinking = part },
            .usage => |delta| .{ .usage = .{
                .input_tokens = delta.input_tokens,
                .output_tokens = delta.output_tokens,
                .cache_read_input_tokens = delta.cache_read_input_tokens,
                .cache_creation_input_tokens = delta.cache_creation_input_tokens,
            } },
            .done => blk: {
                self.terminal.store(true, .release);
                break :blk .{ .done = mapStopReason(inner.stopReason()) };
            },
            .tool_use_start, .web_search_result, .web_search_query => {
                deinitProviderEvent(self.allocator, event);
                self.terminal.store(true, .release);
                self.abort_signal.abort(.api_error);
                self.owner.runtime.providerInfo().provider.cancel(&self.abort_signal);
                return error.UnsupportedResponse;
            },
        };
    }

    pub fn abort(self: *Stream, reason: AbortReason) error{TooLate}!void {
        if (self.terminal.load(.acquire)) return error.TooLate;
        self.abort_signal.abort(reason);
        self.owner.runtime.providerInfo().provider.cancel(&self.abort_signal);
    }

    pub fn destroy(self: *Stream) void {
        if (!self.terminal.load(.acquire)) {
            self.abort_signal.abort(.user_interrupt);
            self.owner.runtime.providerInfo().provider.cancel(&self.abort_signal);
        }
        if (self.inner) |inner| inner.deinit();
        const allocator = self.allocator;
        self.owner.leave(.stream_active);
        allocator.destroy(self);
    }
};

fn deinitProviderEvent(allocator: std.mem.Allocator, event: api_stream.StreamEvent) void {
    switch (event) {
        .text, .thinking => |bytes| allocator.free(bytes),
        .tool_use_start => |tool| {
            allocator.free(tool.id);
            allocator.free(tool.name);
            allocator.free(tool.input_json);
        },
        .web_search_result => |result| {
            allocator.free(result.ui_text);
            allocator.free(result.content_json);
        },
        .web_search_query => |query| allocator.free(query),
        .usage, .done => {},
    }
}

fn buildMessages(
    allocator: std.mem.Allocator,
    messages: []const TextMessage,
) error{OutOfMemory}![]const types.ApiMessage {
    const out = try allocator.alloc(types.ApiMessage, messages.len);
    for (messages, out) |source, *destination| {
        const content = try allocator.alloc(types.ApiContent, 1);
        content[0] = .{ .text = source.text };
        destination.* = .{
            .role = source.role,
            .content = content,
        };
    }
    return out;
}

fn mapStopReason(reason: api_stream.StopReason) StopReason {
    return switch (reason) {
        .unknown, .tool_use => .unknown,
        .end_turn => .end_turn,
        .max_tokens => .max_tokens,
        .stop_sequence => .stop_sequence,
        .pause_turn => .pause_turn,
        .refusal => .refusal,
    };
}
