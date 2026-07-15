//! UI-neutral owner for one stateful AgentCore session.
//!
//! `AgentSession` owns provider, conversation, permission and Run lifecycle
//! state. This first contract is deliberately text-only: tool execution,
//! suspend/resume and UI request channels are added as separate capabilities.

const std = @import("std");
const sync = @import("platform").sync;
const types = @import("../types.zig");
const provider_factory = @import("../api/provider_factory.zig");
const Conversation = @import("conversation.zig").Conversation;
const permission = @import("../permission.zig");
const abort_mod = @import("../util/abort.zig");
const AbortSignal = abort_mod.AbortSignal;
const ui_backend = @import("protocol/ui_backend.zig");
const CoreEvent = ui_backend.CoreEvent;
const UiEvent = ui_backend.UiEvent;
const SessionId = ui_backend.SessionId;
const agent_loop = @import("agent_loop.zig");
const secure = @import("../util/secure.zig");

pub const Config = struct {
    provider_kind: types.ProviderKind,
    api_key: []const u8,
    model: []const u8,
    base_url: ?[]const u8 = null,
    permission_mode: types.PermissionMode = .default,
};

pub const EventSink = struct {
    ctx: *anyopaque,
    /// The callback is synchronous. Returning false is fatal for this Session.
    emit: *const fn (ctx: *anyopaque, session_id: SessionId, run_id: u64, event: CoreEvent) bool,
};

const State = enum {
    idle,
    running,
    abort_requested,
    poisoned,
    destroying,
};

/// Reasons an external host may use to stop a synchronous Run. Internal
/// failures use private AbortSignal reasons and cannot be forged by callers.
pub const AbortReason = enum {
    user_interrupt,
    timeout,

    fn internal(self: AbortReason) abort_mod.Reason {
        return switch (self) {
            .user_interrupt => .user_interrupt,
            .timeout => .timeout,
        };
    }
};

pub const LifecycleError = error{
    SessionBusy,
    StaleRun,
    AbortTooLate,
    InvalidSessionState,
    CallbackFailed,
};

pub const AgentSession = struct {
    allocator: std.mem.Allocator,
    session_id: SessionId,
    api_key: []u8,
    model: []u8,
    base_url: ?[]u8,
    provider: provider_factory.OwnedProvider,
    conversation: Conversation,
    permission_ctx: permission.PermissionContext,
    abort_signal: AbortSignal,
    active_sink: ?EventSink = null,

    mutex: sync.Mutex = .{},
    callback_mutex: sync.Mutex = .{},
    state: State = .idle,
    active_run_id: u64 = 0,
    last_run_id: u64 = 0,
    callback_failed: bool = false,

    /// Allocate directly at the final address. This avoids the invalid
    /// init-by-value + bind(self) pattern where a later move leaves backend ctx
    /// pointing at stale storage.
    pub fn create(allocator: std.mem.Allocator, config: Config) !*AgentSession {
        const self = try allocator.create(AgentSession);
        errdefer allocator.destroy(self);

        const api_key = try allocator.dupe(u8, config.api_key);
        errdefer secureFree(allocator, api_key);
        const model = try allocator.dupe(u8, config.model);
        errdefer allocator.free(model);
        const base_url = if (config.base_url) |url| try allocator.dupe(u8, url) else null;
        errdefer if (base_url) |url| allocator.free(url);

        const owned_provider = try provider_factory.makeProvider(
            allocator,
            config.provider_kind,
            api_key,
            model,
            base_url,
        );
        errdefer owned_provider.deinit();

        const session_id = @import("session_id.zig").gen();
        var permission_ctx = permission.createContext(config.permission_mode, allocator);
        permission_ctx.session = session_id;

        self.* = .{
            .allocator = allocator,
            .session_id = session_id,
            .api_key = api_key,
            .model = model,
            .base_url = base_url,
            .provider = owned_provider,
            .conversation = Conversation.init(allocator),
            .permission_ctx = permission_ctx,
            .abort_signal = AbortSignal.init(),
        };
        return self;
    }

    /// Destroy requires unique ownership of `self` and is valid only after the
    /// synchronous Run has returned. As with allocator.destroy, using the
    /// pointer again after success is invalid.
    pub fn destroy(self: *AgentSession) LifecycleError!void {
        self.mutex.lock();
        switch (self.state) {
            .idle, .poisoned => self.state = .destroying,
            .running, .abort_requested => {
                self.mutex.unlock();
                return error.SessionBusy;
            },
            .destroying => {
                self.mutex.unlock();
                return error.InvalidSessionState;
            },
        }
        self.mutex.unlock();

        const allocator = self.allocator;
        self.provider.deinit();
        self.conversation.deinit();
        if (self.base_url) |url| allocator.free(url);
        allocator.free(self.model);
        secureFree(allocator, self.api_key);
        self.* = undefined;
        allocator.destroy(self);
    }

    /// Run one text turn while preserving Conversation across successful Runs.
    pub fn runText(self: *AgentSession, run_id: u64, prompt: []const u8, max_turns: u32, sink: EventSink) anyerror!agent_loop.RunResult {
        try self.beginRun(run_id, sink);

        self.conversation.appendText(.user, prompt) catch |err| {
            _ = self.poisonRun();
            return err;
        };

        return self.runLoop(max_turns);
    }

    fn runLoop(self: *AgentSession, max_turns: u32) anyerror!agent_loop.RunResult {
        var backend = ui_backend.UiBackend{ .ctx = @ptrCast(self), .emit = backendEmit, .poll = backendPoll };
        var native_result = agent_loop.run(
            &self.conversation,
            self.provider.provider(),
            &.{},
            &self.permission_ctx,
            .{
                .max_turns = max_turns,
                .session = self.session_id,
                .abort = &self.abort_signal,
            },
            &backend,
            self.allocator,
        ) catch |err| {
            const callback_failed = self.poisonRun();
            if (callback_failed) return error.CallbackFailed;
            return err;
        };

        const completion = self.finishRunLifecycle();
        if (completion.callback_failed) {
            if (native_result.suspend_info) |suspend_info| suspend_info.deinit();
            return error.CallbackFailed;
        }
        if (completion.abort_requested) native_result.stop_reason = .aborted;
        return native_result;
    }

    const RunCompletion = struct {
        abort_requested: bool,
        callback_failed: bool,
    };

    fn finishRunLifecycle(self: *AgentSession) RunCompletion {
        self.callback_mutex.lock();
        self.mutex.lock();
        const completion = RunCompletion{
            .abort_requested = self.state == .abort_requested,
            .callback_failed = self.callback_failed,
        };
        if (completion.callback_failed) {
            self.state = .poisoned;
        } else {
            self.state = .idle;
        }
        self.active_run_id = 0;
        self.active_sink = null;
        self.mutex.unlock();
        self.callback_mutex.unlock();
        return completion;
    }

    pub fn abort(self: *AgentSession, run_id: u64, reason: AbortReason) LifecycleError!void {
        self.mutex.lock();
        if (self.active_run_id != 0 and self.active_run_id != run_id) {
            self.mutex.unlock();
            return error.StaleRun;
        }
        switch (self.state) {
            .running => {
                self.state = .abort_requested;
                // Store the abort flag under the same lock that linearizes the
                // state transition. The signal itself is atomic and nonblocking.
                self.abort_signal.abort(reason.internal());
                self.mutex.unlock();
            },
            .abort_requested => self.mutex.unlock(),
            .idle => {
                const too_late = run_id != 0 and self.last_run_id == run_id;
                self.mutex.unlock();
                return if (too_late) error.AbortTooLate else error.StaleRun;
            },
            .poisoned, .destroying => {
                self.mutex.unlock();
                return error.InvalidSessionState;
            },
        }
    }

    fn beginRun(self: *AgentSession, run_id: u64, sink: EventSink) LifecycleError!void {
        self.mutex.lock();
        switch (self.state) {
            .idle => {},
            .running, .abort_requested => {
                self.mutex.unlock();
                return error.SessionBusy;
            },
            .poisoned, .destroying => {
                self.mutex.unlock();
                return error.InvalidSessionState;
            },
        }
        if (run_id == 0 or run_id <= self.last_run_id) {
            self.mutex.unlock();
            return error.StaleRun;
        }
        self.abort_signal = AbortSignal.init();
        self.state = .running;
        self.active_run_id = run_id;
        self.last_run_id = run_id;
        self.callback_failed = false;
        self.active_sink = sink;
        self.mutex.unlock();
    }

    /// Poison a failed Run and return whether delivery failure was the cause.
    fn poisonRun(self: *AgentSession) bool {
        // Quiesce event delivery before clearing active_sink. The lock order is
        // always callback_mutex -> mutex, matching backendEmit/runLoop.
        self.callback_mutex.lock();
        defer self.callback_mutex.unlock();
        self.mutex.lock();
        const failed = self.callback_failed;
        self.state = .poisoned;
        self.active_run_id = 0;
        self.active_sink = null;
        self.mutex.unlock();
        return failed;
    }

    fn backendEmit(ctx: *anyopaque, _: SessionId, event: CoreEvent) void {
        const self: *AgentSession = @ptrCast(@alignCast(ctx));

        // Serialize admission and delivery. This makes "first callback failure"
        // exact even when future tool threads emit concurrently, without holding
        // the lifecycle mutex across consumer code (abort reentrancy stays safe).
        self.callback_mutex.lock();
        defer self.callback_mutex.unlock();

        self.mutex.lock();
        const already_failed = self.callback_failed;
        const run_id = self.active_run_id;
        const sink = self.active_sink;
        self.mutex.unlock();
        if (already_failed or run_id == 0 or sink == null) return;

        if (!sink.?.emit(sink.?.ctx, self.session_id, run_id, event)) {
            self.mutex.lock();
            if (!self.callback_failed) {
                self.callback_failed = true;
                self.abort_signal.abort(.host_failure);
            }
            self.mutex.unlock();
        }
    }

    fn backendPoll(_: *anyopaque, _: SessionId) ?UiEvent {
        return null;
    }
};

pub fn secureClear(bytes: []u8) void {
    secure.zero(bytes);
}

fn secureFree(allocator: std.mem.Allocator, bytes: []u8) void {
    secure.free(allocator, bytes);
}

const EraseObservingAllocator = struct {
    backing: std.mem.Allocator,
    target_len: usize,
    fail_index: ?usize = null,
    allocations: usize = 0,
    target_ptr: ?[*]u8 = null,
    target_freed: bool = false,
    target_was_zero: bool = false,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.fail_index == self.allocations) {
            self.allocations += 1;
            return null;
        }
        self.allocations += 1;
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        if (len == self.target_len and self.target_ptr == null) self.target_ptr = ptr;
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.target_ptr) |target| {
            if (memory.ptr == target) {
                self.target_freed = true;
                self.target_was_zero = std.mem.allEqual(u8, memory, 0);
            }
        }
        self.backing.rawFree(memory, alignment, ret_addr);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

const SinkProbe = struct {
    accept: bool = true,
    calls: usize = 0,
    session_id: ?SessionId = null,
    run_id: u64 = 0,

    fn emit(ctx: *anyopaque, session_id: SessionId, run_id: u64, _: CoreEvent) bool {
        const self: *SinkProbe = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.session_id = session_id;
        self.run_id = run_id;
        return self.accept;
    }

    fn sink(self: *SinkProbe) EventSink {
        return .{ .ctx = self, .emit = emit };
    }
};

fn createTestSession(mode: types.PermissionMode) !*AgentSession {
    return AgentSession.create(std.testing.allocator, .{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .permission_mode = mode,
    });
}

test "secureClear uses optimizer-resistant zeroing" {
    var key = [_]u8{ 1, 2, 3, 4 };
    secureClear(&key);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &key);
}

test "AgentSession zeroes the copied API key before normal free" {
    const key = "normal-destroy-key-with-unique-length-37";
    var observer = EraseObservingAllocator{ .backing = std.testing.allocator, .target_len = key.len };
    const self = try AgentSession.create(observer.allocator(), .{
        .provider_kind = .anthropic,
        .api_key = key,
        .model = "m",
        .base_url = null,
    });
    try self.destroy();
    try std.testing.expect(observer.target_freed);
    try std.testing.expect(observer.target_was_zero);
}

test "AgentSession zeroes the copied API key when later construction fails" {
    const key = "failed-create-key-with-unique-length-41---";
    // create(Session)=0, dupe(api_key)=1, dupe(model)=2 -> fail after the
    // sensitive copy exists and force its errdefer cleanup.
    var observer = EraseObservingAllocator{
        .backing = std.testing.allocator,
        .target_len = key.len,
        .fail_index = 2,
    };
    try std.testing.expectError(error.OutOfMemory, AgentSession.create(observer.allocator(), .{
        .provider_kind = .anthropic,
        .api_key = key,
        .model = "m",
        .base_url = null,
    }));
    try std.testing.expect(observer.target_freed);
    try std.testing.expect(observer.target_was_zero);
}

test "AgentSession initializes per-session permission state" {
    const self = try createTestSession(.plan);
    defer self.destroy() catch unreachable;
    try std.testing.expectEqual(types.PermissionMode.plan, self.permission_ctx.modeValue());
    try std.testing.expectEqualSlices(u8, self.session_id.asSlice(), self.permission_ctx.session.asSlice());
}

test "AgentSession enforces one active Run and monotonic nonzero run ids" {
    const self = try createTestSession(.default);
    var probe = SinkProbe{};

    try std.testing.expectError(error.StaleRun, self.beginRun(0, probe.sink()));
    try self.beginRun(1, probe.sink());
    try std.testing.expectEqual(State.running, self.state);
    try std.testing.expectError(error.SessionBusy, self.beginRun(2, probe.sink()));
    try std.testing.expectError(error.SessionBusy, self.destroy());

    const first = self.finishRunLifecycle();
    try std.testing.expect(!first.abort_requested);
    try std.testing.expect(!first.callback_failed);
    try std.testing.expectEqual(State.idle, self.state);
    try std.testing.expectError(error.StaleRun, self.beginRun(1, probe.sink()));

    try self.beginRun(2, probe.sink());
    _ = self.finishRunLifecycle();
    try self.destroy();
}

test "AgentSession abort is run-scoped, idempotent and reports late requests" {
    const self = try createTestSession(.default);
    var probe = SinkProbe{};

    try std.testing.expectError(error.StaleRun, self.abort(0, .user_interrupt));
    try self.beginRun(3, probe.sink());
    try std.testing.expectError(error.StaleRun, self.abort(4, .user_interrupt));
    try self.abort(3, .timeout);
    try std.testing.expectEqual(State.abort_requested, self.state);
    try std.testing.expect(self.abort_signal.isAborted());
    try std.testing.expectEqual(abort_mod.Reason.timeout, self.abort_signal.reason());

    // A repeated abort is harmless and preserves the first reason.
    try self.abort(3, .user_interrupt);
    try std.testing.expectEqual(abort_mod.Reason.timeout, self.abort_signal.reason());
    try std.testing.expectError(error.SessionBusy, self.destroy());

    const completion = self.finishRunLifecycle();
    try std.testing.expect(completion.abort_requested);
    try std.testing.expect(!completion.callback_failed);
    try std.testing.expectError(error.AbortTooLate, self.abort(3, .user_interrupt));
    try self.destroy();
}

test "AgentSession callback failure aborts delivery and poisons the Session" {
    const self = try createTestSession(.default);
    var probe = SinkProbe{ .accept = false };
    try self.beginRun(7, probe.sink());

    AgentSession.backendEmit(self, self.session_id, .{ .phase_change = .generating });
    AgentSession.backendEmit(self, self.session_id, .stream_done);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(u64, 7), probe.run_id);
    try std.testing.expectEqualSlices(u8, self.session_id.asSlice(), probe.session_id.?.asSlice());
    try std.testing.expect(self.abort_signal.isAborted());
    try std.testing.expectEqual(abort_mod.Reason.host_failure, self.abort_signal.reason());

    const completion = self.finishRunLifecycle();
    try std.testing.expect(completion.callback_failed);
    try std.testing.expectEqual(State.poisoned, self.state);
    try std.testing.expectError(error.InvalidSessionState, self.beginRun(8, probe.sink()));
    try self.destroy();
}

test "unexpected pre-run allocation failure poisons the Session" {
    const allocator = std.testing.allocator;
    const self = try AgentSession.create(allocator, .{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = "http://127.0.0.1:1/v1/messages",
    });
    defer self.destroy() catch unreachable;

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    self.conversation.allocator = failing.allocator();
    var sink_state: u8 = 0;
    const Sink = struct {
        fn emit(_: *anyopaque, _: SessionId, _: u64, _: CoreEvent) bool {
            return true;
        }
    };
    try std.testing.expectError(error.OutOfMemory, self.runText(1, "must fail before provider I/O", 1, .{
        .ctx = &sink_state,
        .emit = Sink.emit,
    }));
    try std.testing.expectEqual(State.poisoned, self.state);
    try std.testing.expectError(error.InvalidSessionState, self.beginRun(2, .{
        .ctx = &sink_state,
        .emit = Sink.emit,
    }));
    try std.testing.expectError(error.InvalidSessionState, self.abort(1, .user_interrupt));
}
