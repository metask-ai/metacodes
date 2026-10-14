//! SessionHost — the multi-session service an embedding Host puts behind its
//! own transport.
//!
//! A network Host (HTTP/SSE, WebSocket, a queue) needs more than an
//! `AgentSession`: Sessions opened and closed by id at runtime, submissions
//! queued and run one at a time, an event log a client can replay after it
//! reconnects, UI requests answered by id from another process, an interrupt
//! that also releases a pending prompt, transcripts it can resume from, and a
//! Session that became unusable reported as such. SessionHost composes those
//! from the kernel's own parts — `AgentRuntime`/`AgentSession`,
//! `EventJournal` (seq + epoch), `protocol.wire` lines and
//! `transcript.sessionDir` — so each Host does not rebuild them.
//! Authentication, tenancy, idempotency and the transport stay with the Host.
//!
//! Per Session one driver thread makes every call into the AgentSession.
//! Submissions and configuration commands share one FIFO, so "set the model,
//! then send this" happens in that order and only while the Session is idle.
//! `interrupt` is the one cross-thread call into the kernel; its abort is
//! built for that.
//!
//! Lifetimes: `open` and `acquire` return a counted reference that `release`
//! gives back; no pointer escapes without one. `close` takes the Session out
//! of the table, answers its pending prompt as cancelled, aborts its Run,
//! joins the driver, closes the journal (waking every reader), waits for any
//! in-flight `interrupt` to leave the kernel and destroys the AgentSession,
//! so the id can be opened again as soon as `close` returns. It never waits
//! for references: a holder keeps a closed `HostedSession` readable (journal,
//! `snapshot`) and the last `release` frees it. `gpa` must be thread-safe: the
//! driver, journal readers and Host threads all allocate from it.

const std = @import("std");
const sync = @import("platform").sync;
const pfs = @import("platform").fs;
const agent_session = @import("agent_session.zig");
const Conversation = @import("conversation.zig").Conversation;
const transcript = @import("transcript.zig");
const workspace_policy = @import("workspace_policy.zig");
const EventJournal = @import("event_journal.zig").EventJournal;
const wire = @import("protocol/wire.zig");
const ui_request = @import("protocol/ui_request.zig");
const ui_event = @import("protocol/ui_event.zig");
const session_id_mod = @import("session_id.zig");
const types = @import("../types.zig");
const prompt_sections = @import("prompt_sections.zig");
const permission_settings = @import("../permission/settings.zig");
const util_time = @import("../util/time.zig");
const log = @import("../util/log.zig");

const AgentRuntime = agent_session.AgentRuntime;
const AgentSession = agent_session.AgentSession;
const SessionConfig = agent_session.SessionConfig;
const SessionId = session_id_mod.SessionId;

pub const Options = struct {
    /// Submissions and commands queued per Session before `submit` and
    /// `command` report `error.QueueFull`.
    max_queued: usize = 64,
    /// Turn limit of each Run.
    max_turns: u32 = 400,
    /// Flush each Session's transcript (`transcript.sessionDir` under its
    /// state root) after every Run and command, so `open(.resume)` restores
    /// it.
    transcripts: bool = true,
    /// How long a UI request waits for `respond`. Null waits until
    /// `interrupt` or `close`. An expired request is answered as cancelled.
    ui_request_timeout_ms: ?u64 = null,
};

pub const OpenMode = enum {
    /// A new conversation. Under an explicit id whose transcript exists, the
    /// transcript is replaced at once, never appended to.
    fresh,
    /// The conversation persisted under `id`.
    @"resume",
};

pub const OpenSpec = struct {
    /// Borrowed for the call. `ui_requester` and `run_ui_requester` must be
    /// null: UI requests are answered through `HostedSession.respond`.
    config: SessionConfig,
    /// Null generates an id (fresh only).
    id: ?SessionId = null,
    mode: OpenMode = .fresh,
};

pub const Phase = enum { idle, running, poisoned, closing };

pub const Submission = struct {
    text: []const u8,
    /// Opaque; echoed as `trace_id` on this Run's wire lines.
    trace_id: ?[]const u8 = null,
};

/// A configuration change applied by the driver between Runs, in queue
/// order. Borrowed for `HostedSession.command`, which copies it.
pub const Command = union(enum) {
    set_model: []const u8,
    set_permission_mode: types.PermissionMode,
    set_reasoning_effort: ?types.ReasoningEffort,
    set_additional_directories: []const []const u8,
    set_prompt_profile: prompt_sections.Profile,
    update_permission_rules: permission_settings.RuleSetInput,
    compact,
};

pub const EnqueueError = error{ QueueFull, SessionClosed, SessionPoisoned, OutOfMemory };
pub const RespondError = error{ NoSuchRequest, OutOfMemory };
pub const InterruptOutcome = enum {
    /// Nothing was running or about to run.
    no_run,
    /// A Run was in progress or being admitted: it stops unless it had just
    /// finished, and a pending UI request was answered as cancelled.
    requested,
    /// The Run had already finished.
    too_late,
};

/// What a Host reports about a Session (e.g. as `/state`). `model` is owned
/// by the allocator given to `snapshot`.
pub const Snapshot = struct {
    id: SessionId,
    phase: Phase,
    model: []const u8,
    permission_mode: types.PermissionMode,
    reasoning_effort: ?types.ReasoningEffort,
    queued: usize,
    seq: usize,
    epoch: [16]u8,
    pending_request_id: u64,
    messages: usize,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.model);
        self.* = undefined;
    }
};

pub const SessionHost = struct {
    gpa: std.mem.Allocator,
    runtime: *AgentRuntime,
    options: Options,
    mutex: sync.Mutex = .{},
    sessions: std.AutoHashMapUnmanaged([24]u8, *HostedSession) = .empty,
    closed: bool = false,

    /// `runtime` is borrowed and must outlive `deinit`.
    pub fn init(gpa: std.mem.Allocator, runtime: *AgentRuntime, options: Options) SessionHost {
        return .{ .gpa = gpa, .runtime = runtime, .options = options };
    }

    /// Closes every Session (see `close`) and refuses further `open`s.
    /// References still held stay readable shells; their holders release
    /// them with `HostedSession.release`.
    pub fn deinit(self: *SessionHost) void {
        self.mutex.lock();
        self.closed = true;
        self.mutex.unlock();
        while (true) {
            self.mutex.lock();
            var it = self.sessions.iterator();
            const entry = it.next() orelse {
                self.mutex.unlock();
                break;
            };
            const hosted = entry.value_ptr.*;
            const key = entry.key_ptr.*;
            _ = self.sessions.remove(key);
            self.mutex.unlock();
            hosted.shutdown();
            hosted.retire();
        }
        self.sessions.deinit(self.gpa);
    }

    /// Returns the Session holding one reference for the caller.
    pub fn open(self: *SessionHost, spec: OpenSpec) !*HostedSession {
        if (spec.config.ui_requester != null or spec.config.run_ui_requester != null) return error.UiRequesterNotAllowed;
        if (spec.mode == .@"resume" and spec.id == null) return error.IdRequiredForResume;
        if (spec.id) |id| {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return error.HostClosed;
            if (self.sessions.contains(id.bytes)) return error.SessionAlreadyOpen;
        }

        const hosted = try self.gpa.create(HostedSession);
        errdefer self.gpa.destroy(hosted);
        const model = try self.gpa.dupe(u8, spec.config.model);
        errdefer self.gpa.free(model);
        hosted.* = .{
            .host = self,
            .gpa = self.gpa,
            .id = undefined,
            .session = undefined,
            .journal = EventJournal.init(self.gpa),
            .model = model,
            .reasoning_effort = spec.config.reasoning_effort,
        };
        errdefer hosted.journal.deinit();

        var config = spec.config;
        config.ui_requester = .{ .ctx = hosted, .requestFn = HostedSession.requestUi };

        var conversation = Conversation.init(self.gpa);
        defer conversation.deinit();
        var policy = try workspace_policy.WorkspacePolicy.init(self.gpa, config.workspace);
        defer policy.deinit();
        if (spec.mode == .@"resume") {
            const dir = try transcript.sessionDir(self.gpa, policy.stateRoot(), policy.root, spec.id.?);
            defer self.gpa.free(dir);
            var file_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const file = std.fmt.bufPrintZ(&file_buf, "{s}/transcript.jsonl", .{dir}) catch return error.TranscriptNotFound;
            if (!pfs.exists(file.ptr)) return error.TranscriptNotFound;
            try transcript.loadTranscript(&conversation, dir, self.gpa);
        }

        const session = if (spec.id) |id|
            try self.runtime.createRestoredSession(config, .{
                .session_id = id,
                .last_run_id = 0,
                .last_compact_id = 0,
                .conversation = &conversation,
            })
        else
            try self.runtime.createSession(config);
        errdefer session.destroy() catch {};
        hosted.session = session;
        hosted.id = session.session_id;
        hosted.messages = conversation.len();

        if (self.options.transcripts) {
            if (spec.mode == .@"resume") {
                const dir = try transcript.sessionDir(self.gpa, session.workspace.stateRoot(), session.workspace.root, hosted.id);
                hosted.writer = transcript.Writer.openExisting(self.gpa, dir, hosted.model, conversation.len());
            } else {
                hosted.writer = try transcript.Writer.init(self.gpa, session.workspace.root, session.workspace.stateRoot(), hosted.model, hosted.id);
                // A fresh conversation under a reused id must not resume the
                // old one: replace the file now rather than at the first Run.
                hosted.writer.?.rewriteOnNextFlush();
                hosted.persist();
            }
        }
        errdefer if (hosted.writer) |*writer| writer.deinit();

        hosted.driver = try std.Thread.spawn(.{}, HostedSession.driverMain, .{hosted});
        // The caller's reference, taken before the Session becomes visible.
        hosted.references = 1;

        self.mutex.lock();
        const refused: ?anyerror = if (self.closed)
            error.HostClosed
        else if (self.sessions.contains(hosted.id.bytes))
            error.SessionAlreadyOpen
        else blk: {
            self.sessions.put(self.gpa, hosted.id.bytes, hosted) catch |err| break :blk err;
            break :blk null;
        };
        self.mutex.unlock();
        if (refused) |err| {
            // Never published: stop the driver; the errdefers above free the rest.
            hosted.references = 0;
            hosted.stopDriver();
            return err;
        }
        return hosted;
    }

    /// A counted reference to an open Session, or null. Pair with `release`.
    pub fn acquire(self: *SessionHost, id: SessionId) ?*HostedSession {
        self.mutex.lock();
        defer self.mutex.unlock();
        const hosted = self.sessions.get(id.bytes) orelse return null;
        hosted.mutex.lock();
        defer hosted.mutex.unlock();
        hosted.references += 1;
        return hosted;
    }

    /// Same as `HostedSession.release`.
    pub fn release(_: *SessionHost, hosted: *HostedSession) void {
        hosted.release();
    }

    /// See the module comment. Returns once the kernel Session is destroyed.
    pub fn close(self: *SessionHost, id: SessionId) error{SessionNotFound}!void {
        self.mutex.lock();
        const removed = self.sessions.fetchRemove(id.bytes);
        self.mutex.unlock();
        const entry = removed orelse return error.SessionNotFound;
        entry.value.shutdown();
        entry.value.retire();
    }

    /// Ids of the open Sessions, owned by `allocator`.
    pub fn list(self: *SessionHost, allocator: std.mem.Allocator) error{OutOfMemory}![]SessionId {
        self.mutex.lock();
        defer self.mutex.unlock();
        const ids = try allocator.alloc(SessionId, self.sessions.count());
        var it = self.sessions.valueIterator();
        var index: usize = 0;
        while (it.next()) |hosted| : (index += 1) ids[index] = hosted.*.id;
        return ids;
    }
};

const Work = struct {
    arena: std.heap.ArenaAllocator,
    item: union(enum) {
        submission: Submission,
        command: Command,
    },
};

pub const HostedSession = struct {
    /// Borrowed from the SessionHost; read only while the Session is open.
    host: *SessionHost,
    /// The host's allocator, kept here so a closed shell can free itself
    /// after the SessionHost is gone.
    gpa: std.mem.Allocator,
    id: SessionId,
    session: *AgentSession,
    /// Wire lines of this Session: the kernel's events of every Run (with
    /// `run_id`/`trace_id`), the Host events, and UI requests with their
    /// close. Readers use `waitSinceFrom` and stop once `isClosed`.
    journal: EventJournal,
    writer: ?transcript.Writer = null,
    driver: std.Thread = undefined,

    mutex: sync.Mutex = .{},
    work_ready: sync.Condition = .{},
    kernel_idle: sync.Condition = .{},
    ui_ready: sync.Condition = .{},
    queue: std.ArrayList(*Work) = .empty,
    phase: Phase = .idle,
    closing: bool = false,
    /// Out of the table and shut down; the last reference frees the shell.
    retired: bool = false,
    references: usize = 0,
    /// Host threads inside a kernel call (`interrupt`'s abort); shutdown
    /// waits for them before destroying the AgentSession.
    kernel_users: usize = 0,
    /// The permission mode as of shutdown; live Sessions are read directly.
    final_permission_mode: types.PermissionMode = .default,
    /// The admitted Run, 0 between Runs.
    current_run_id: u64 = 0,
    /// Set by `interrupt` for the Run being started or running; cleared when
    /// the next submission is taken.
    run_interrupted: bool = false,
    /// The current submission's Run has returned; `finishRun` is reporting
    /// it. An interrupt now is too late.
    run_returned: bool = false,
    /// Copies the driver keeps current for `snapshot`, which cannot read the
    /// AgentSession's own fields while the driver changes them.
    model: []u8,
    reasoning_effort: ?types.ReasoningEffort,
    messages: usize = 0,

    /// One UI request at a time; a second (from a parallel tool) waits.
    ui_serial: sync.Mutex = .{},
    pending_request_id: u64 = 0,
    next_request_id: u64 = 1,
    response: ?[]u8 = null,

    // Driver-only.
    last_run_id: u64 = 0,
    last_compact_id: u64 = 0,

    /// Gives back a reference from `open` or `acquire`; the last one of a
    /// closed Session frees it. Valid after `SessionHost.deinit`.
    pub fn release(self: *HostedSession) void {
        self.mutex.lock();
        std.debug.assert(self.references > 0);
        self.references -= 1;
        const free_now = self.references == 0 and self.retired;
        self.mutex.unlock();
        if (free_now) self.destroyShell();
    }

    pub fn submit(self: *HostedSession, submission: Submission) EnqueueError!void {
        const work = try self.newWork();
        errdefer self.freeWork(work);
        const a = work.arena.allocator();
        work.item = .{ .submission = .{
            .text = try a.dupe(u8, submission.text),
            .trace_id = if (submission.trace_id) |trace_id| try a.dupe(u8, trace_id) else null,
        } };
        try self.enqueue(work);
    }

    pub fn command(self: *HostedSession, cmd: Command) EnqueueError!void {
        const work = try self.newWork();
        errdefer self.freeWork(work);
        work.item = .{ .command = try copyCommand(work.arena.allocator(), cmd) };
        try self.enqueue(work);
    }

    fn newWork(self: *HostedSession) error{OutOfMemory}!*Work {
        const work = try self.gpa.create(Work);
        work.* = .{ .arena = std.heap.ArenaAllocator.init(self.gpa), .item = .{ .command = .compact } };
        return work;
    }

    /// Takes `work` on success; on error the caller still owns it.
    fn enqueue(self: *HostedSession, work: *Work) EnqueueError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing) return error.SessionClosed;
        if (self.phase == .poisoned) return error.SessionPoisoned;
        if (self.queue.items.len >= self.host.options.max_queued) return error.QueueFull;
        try self.queue.append(self.gpa, work);
        self.work_ready.signal();
    }

    /// Stops the current Run (or the one about to be admitted) and answers a
    /// pending UI request as cancelled. Queued work still runs afterwards.
    pub fn interrupt(self: *HostedSession) InterruptOutcome {
        self.mutex.lock();
        if (self.closing) {
            self.mutex.unlock();
            return .no_run;
        }
        if (self.phase == .running and self.run_returned) {
            self.mutex.unlock();
            return .too_late;
        }
        const run_id = self.current_run_id;
        const starting = self.phase == .running;
        if (starting) self.run_interrupted = true;
        self.ui_ready.broadcast();
        if (run_id != 0) self.kernel_users += 1;
        self.mutex.unlock();
        if (run_id == 0) return if (starting) .requested else .no_run;
        defer self.leaveKernel();
        self.session.abort(run_id, .user_interrupt) catch return .too_late;
        return .requested;
    }

    fn leaveKernel(self: *HostedSession) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.kernel_users -= 1;
        if (self.kernel_users == 0) self.kernel_idle.broadcast();
    }

    /// Answers UI request `request_id` with a `protocol.wire` response. A
    /// request that is not the pending one (answered, cancelled, stale), or
    /// one an interrupt or close has already cancelled, is
    /// `error.NoSuchRequest`.
    pub fn respond(self: *HostedSession, request_id: u64, response_json: []const u8) RespondError!void {
        const owned = try self.gpa.dupe(u8, response_json);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending_request_id == 0 or self.pending_request_id != request_id or self.response != null or
            self.run_interrupted or self.closing)
        {
            self.gpa.free(owned);
            return error.NoSuchRequest;
        }
        self.response = owned;
        self.ui_ready.broadcast();
    }

    pub fn snapshot(self: *HostedSession, allocator: std.mem.Allocator) error{OutOfMemory}!Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .id = self.id,
            .phase = self.phase,
            .model = try allocator.dupe(u8, self.model),
            // `closing` is set under this lock before the kernel Session is
            // destroyed, so a live read here cannot race the destroy.
            .permission_mode = if (self.closing) self.final_permission_mode else self.session.permission_ctx.modeValue(),
            .reasoning_effort = self.reasoning_effort,
            .queued = self.queue.items.len,
            .seq = self.journal.count(),
            .epoch = self.journal.epochHex(),
            .pending_request_id = self.pending_request_id,
            .messages = self.messages,
        };
    }

    // ── driver ────────────────────────────────────────────────────────────

    fn driverMain(self: *HostedSession) void {
        while (self.nextWork()) |work| {
            defer self.freeWork(work);
            switch (work.item) {
                .submission => |submission| self.runSubmission(submission),
                .command => |cmd| self.applyCommand(cmd),
            }
        }
    }

    fn nextWork(self: *HostedSession) ?*Work {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (self.closing) return null;
            if (self.queue.items.len > 0 and self.phase != .poisoned) {
                const work = self.queue.orderedRemove(0);
                if (work.item == .submission) {
                    self.phase = .running;
                    self.run_interrupted = false;
                    self.run_returned = false;
                }
                return work;
            }
            self.work_ready.wait(&self.mutex);
        }
    }

    fn freeWork(self: *HostedSession, work: *Work) void {
        work.arena.deinit();
        self.gpa.destroy(work);
    }

    const RunScope = struct {
        hosted: *HostedSession,
        context: wire.RunContext,

        fn sink(self: *RunScope) agent_session.EventSink {
            return .{ .ctx = self, .emit = emit };
        }

        fn emit(ctx: *anyopaque, _: SessionId, _: u64, event: ui_event.CoreEvent) bool {
            const self: *RunScope = @ptrCast(@alignCast(ctx));
            const line = wire.writeRunEvent(self.hosted.gpa, self.context, event) catch {
                log.warn("session_host", "dropped CoreEvent .{s} (OOM)", .{@tagName(event)});
                return true;
            };
            defer self.hosted.gpa.free(line);
            self.hosted.journal.append(line);
            return true;
        }
    };

    fn runSubmission(self: *HostedSession, submission: Submission) void {
        self.last_run_id += 1;
        const context = wire.RunContext{ .run_id = self.last_run_id, .trace_id = submission.trace_id };
        self.emitHost(.{ .user_message = .{ .run_id = context.run_id, .trace_id = context.trace_id, .text = submission.text } });

        var scope = RunScope{ .hosted = self, .context = context };
        // An interrupt of the previous Run may still be inside the provider's
        // cancel; admission would report SessionBusy until it returns.
        self.session.awaitProviderCancelsDrained();
        var admitted = self.session.admitRun(context.run_id, scope.sink()) catch |err| {
            self.finishRun(context, null, err);
            return;
        };
        // An interrupt or close that arrived between taking the submission
        // and admitting the Run had no Run to abort; it applies now. Either
        // that caller saw `current_run_id` or this block sees its flag.
        self.mutex.lock();
        self.current_run_id = context.run_id;
        const stop_now = self.run_interrupted or self.closing;
        self.mutex.unlock();
        if (stop_now) self.session.abort(context.run_id, .user_interrupt) catch {};

        const outcome = admitted.runText(submission.text, self.host.options.max_turns);
        self.mutex.lock();
        self.current_run_id = 0;
        self.run_returned = true;
        self.mutex.unlock();
        if (outcome) |result| {
            if (result.suspend_info) |info| info.deinit();
            self.finishRun(context, @tagName(result.stop_reason), null);
        } else |err| {
            self.finishRun(context, null, err);
        }
    }

    fn finishRun(self: *HostedSession, context: wire.RunContext, stop_reason: ?[]const u8, failure: ?anyerror) void {
        self.persist();
        const poisoned = self.session.isPoisoned();
        var dropped: std.ArrayList(*Work) = .empty;
        defer dropped.deinit(self.gpa);
        self.mutex.lock();
        if (poisoned) {
            self.phase = .poisoned;
            std.mem.swap(std.ArrayList(*Work), &dropped, &self.queue);
        } else if (!self.closing) {
            self.phase = .idle;
        }
        self.mutex.unlock();
        for (dropped.items) |work| self.freeWork(work);

        self.emitHost(.{ .run_done = .{
            .run_id = context.run_id,
            .trace_id = context.trace_id,
            .stop_reason = stop_reason,
            .error_name = if (failure) |err| @errorName(err) else null,
        } });
        if (poisoned) self.emitHost(.{ .session_poisoned = .{
            .error_name = if (failure) |err| @errorName(err) else "SessionPoisoned",
            .dropped = dropped.items.len,
        } });
    }

    fn applyCommand(self: *HostedSession, cmd: Command) void {
        self.session.awaitProviderCancelsDrained();
        const failure: ?anyerror = switch (cmd) {
            .set_model => |model| self.applyModel(model),
            .set_permission_mode => |mode| if (self.session.setPermissionMode(mode)) |_| null else |err| err,
            .set_reasoning_effort => |effort| if (self.session.setReasoningEffort(effort)) |_| blk: {
                self.mutex.lock();
                self.reasoning_effort = effort;
                self.mutex.unlock();
                break :blk null;
            } else |err| err,
            .set_additional_directories => |dirs| if (self.session.setAdditionalDirectories(dirs)) |_| null else |err| err,
            .set_prompt_profile => |profile| if (self.session.setPromptProfile(profile)) |_| null else |err| err,
            .update_permission_rules => |rules| if (self.session.updatePermissionRules(rules)) |_| null else |err| err,
            .compact => blk: {
                self.last_compact_id += 1;
                _ = self.session.compact(self.last_compact_id, .{}) catch |err| break :blk err;
                break :blk null;
            },
        };
        if (failure == null) self.persist();
        self.emitHost(.{ .command_result = .{
            .command = @tagName(cmd),
            .ok = failure == null,
            .error_name = if (failure) |err| @errorName(err) else null,
        } });
    }

    fn applyModel(self: *HostedSession, model: []const u8) ?anyerror {
        const copy = self.gpa.dupe(u8, model) catch |err| return err;
        self.session.setModel(model) catch |err| {
            self.gpa.free(copy);
            return err;
        };
        self.mutex.lock();
        const previous = self.model;
        self.model = copy;
        self.mutex.unlock();
        // The transcript's meta names the model; the writer borrows this copy.
        if (self.writer) |*writer| writer.model = self.model;
        self.gpa.free(previous);
        return null;
    }

    /// Flush the committed Conversation to the transcript. A poisoned Session
    /// has no committed state to lease; what reached disk before stays.
    fn persist(self: *HostedSession) void {
        const writer = if (self.writer) |*writer| writer else return;
        var lease = self.session.snapshotCommitted() catch return;
        defer lease.deinit();
        writer.flush(lease.conversation);
        self.mutex.lock();
        self.messages = lease.conversation.len();
        self.mutex.unlock();
    }

    fn emitHost(self: *HostedSession, event: wire.HostEvent) void {
        const line = wire.writeHostEvent(self.gpa, event) catch {
            log.warn("session_host", "dropped host event .{s} (OOM)", .{@tagName(event)});
            return;
        };
        defer self.gpa.free(line);
        self.journal.append(line);
    }

    fn appendLine(self: *HostedSession, line: error{OutOfMemory}![]u8) void {
        const owned = line catch return;
        defer self.gpa.free(owned);
        self.journal.append(owned);
    }

    // ── UI requests ───────────────────────────────────────────────────────

    fn requestUi(
        ctx: *anyopaque,
        _: SessionId,
        allocator: std.mem.Allocator,
        req: *const ui_request.UiRequest,
        out: *ui_request.UiResponse,
    ) anyerror!ui_request.RequestOutcome {
        const self: *HostedSession = @ptrCast(@alignCast(ctx));
        self.ui_serial.lock();
        defer self.ui_serial.unlock();

        self.mutex.lock();
        if (self.closing or self.run_interrupted) {
            self.mutex.unlock();
            return wire.cancelResponse(req, out);
        }
        const request_id = self.next_request_id;
        self.next_request_id += 1;
        self.pending_request_id = request_id;
        self.mutex.unlock();

        const announce = wire.writeRequest(self.gpa, request_id, req) catch |err| {
            self.mutex.lock();
            self.pending_request_id = 0;
            self.mutex.unlock();
            return err;
        };
        defer self.gpa.free(announce);
        self.journal.append(announce);

        const deadline: ?i128 = if (self.host.options.ui_request_timeout_ms) |ms|
            util_time.nowNs() + @as(i128, ms) * std.time.ns_per_ms
        else
            null;
        self.mutex.lock();
        while (self.response == null and !self.run_interrupted and !self.closing) {
            if (deadline) |limit| {
                const now = util_time.nowNs();
                if (now >= limit) break;
                _ = self.ui_ready.timedWait(&self.mutex, @intCast(limit - now));
            } else {
                self.ui_ready.wait(&self.mutex);
            }
        }
        const response = self.takeResponseLocked();
        self.pending_request_id = 0;
        self.mutex.unlock();

        if (response) |json| {
            defer self.gpa.free(json);
            const reading = wire.parseResponse(req, json, allocator, out) catch |err| {
                self.appendLine(wire.writeRequestClosed(self.gpa, request_id, if (err == error.InputAborted) .malformed else .cancelled));
                return err;
            };
            self.appendLine(wire.writeRequestClosed(self.gpa, request_id, reading.closed()));
            return .answered;
        }
        self.appendLine(wire.writeRequestClosed(self.gpa, request_id, .cancelled));
        return wire.cancelResponse(req, out);
    }

    /// The stored answer to the pending request, unless cancellation won: an
    /// interrupt or close already in force discards a response that raced
    /// it, so a late "allow" cannot run a tool the user stopped. Caller holds
    /// `mutex`; the returned slice is the caller's.
    fn takeResponseLocked(self: *HostedSession) ?[]u8 {
        const response = self.response orelse return null;
        self.response = null;
        if (self.run_interrupted or self.closing) {
            self.gpa.free(response);
            return null;
        }
        return response;
    }

    // ── teardown ──────────────────────────────────────────────────────────

    /// Ends the driver: no further work is taken, a pending UI request is
    /// answered as cancelled, and the current Run is aborted.
    fn stopDriver(self: *HostedSession) void {
        self.mutex.lock();
        self.closing = true;
        self.phase = .closing;
        self.final_permission_mode = self.session.permission_ctx.modeValue();
        const run_id = self.current_run_id;
        self.work_ready.broadcast();
        self.ui_ready.broadcast();
        self.mutex.unlock();
        if (run_id != 0) self.session.abort(run_id, .user_interrupt) catch {};
        self.driver.join();
    }

    /// Everything that needs the kernel: after this the AgentSession is gone
    /// and the id is free; the shell (journal, snapshot) stays for holders.
    fn shutdown(self: *HostedSession) void {
        self.stopDriver();
        self.journal.close();
        self.mutex.lock();
        while (self.kernel_users > 0) self.kernel_idle.wait(&self.mutex);
        var queue = self.queue;
        self.queue = .empty;
        const response = self.response;
        self.response = null;
        self.mutex.unlock();
        for (queue.items) |work| self.freeWork(work);
        queue.deinit(self.gpa);
        if (response) |json| self.gpa.free(json);

        self.session.destroy() catch |err| log.err("session_host", "destroy {s}: {s}", .{ self.id.asSlice(), @errorName(err) });
        if (self.writer) |*writer| writer.deinit();
        self.writer = null;
    }

    /// Marks a shut-down Session retired; frees it now if nobody holds it.
    fn retire(self: *HostedSession) void {
        self.mutex.lock();
        self.retired = true;
        const free_now = self.references == 0;
        self.mutex.unlock();
        if (free_now) self.destroyShell();
    }

    fn destroyShell(self: *HostedSession) void {
        self.journal.deinit();
        self.gpa.free(self.model);
        self.gpa.destroy(self);
    }
};

fn copyCommand(a: std.mem.Allocator, cmd: Command) error{OutOfMemory}!Command {
    return switch (cmd) {
        .set_model => |model| .{ .set_model = try a.dupe(u8, model) },
        .set_permission_mode, .set_reasoning_effort, .compact => cmd,
        .set_additional_directories => |dirs| .{ .set_additional_directories = try copyStrings(a, dirs) },
        .set_prompt_profile => |profile| blk: {
            const sections = try a.alloc(prompt_sections.ProfileSection, profile.sections.len);
            for (profile.sections, sections) |section, *copy| {
                copy.* = section;
                copy.id = try a.dupe(u8, section.id);
                copy.text = try a.dupe(u8, section.text);
            }
            break :blk .{ .set_prompt_profile = .{ .sections = sections } };
        },
        .update_permission_rules => |rules| .{ .update_permission_rules = .{
            .allow = try copyStrings(a, rules.allow),
            .ask = try copyStrings(a, rules.ask),
            .deny = try copyStrings(a, rules.deny),
        } },
    };
}

fn copyStrings(a: std.mem.Allocator, strings: []const []const u8) error{OutOfMemory}![]const []const u8 {
    const copy = try a.alloc([]const u8, strings.len);
    for (strings, copy) |string, *slot| slot.* = try a.dupe(u8, string);
    return copy;
}

// ============================================================================
// Tests (offline; the provider-backed paths are L2 in
// tests/component/session_host_test.zig)
// ============================================================================

fn waitForLine(journal: *EventJournal, needle: []const u8) !void {
    const a = std.testing.allocator;
    var waited: u32 = 0;
    while (waited < 1000) : (waited += 1) {
        if (try journal.waitSince(a, 0, 10)) |lines| {
            defer {
                for (lines) |line| a.free(line);
                a.free(lines);
            }
            for (lines) |line| if (std.mem.indexOf(u8, line, needle) != null) return;
        }
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    return error.JournalTimeout;
}

test "SessionHost offline: open, queue, snapshot, interrupt, respond, close" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];

    const runtime = try AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{ .transcripts = false });
    defer host.deinit();
    const config = SessionConfig{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        // Nothing listens on the discard port: a Run fails fast, offline.
        .base_url = "http://127.0.0.1:9",
        .workspace = .{ .root = root },
        .allowed_tools = &.{},
    };
    try std.testing.expectError(error.IdRequiredForResume, host.open(.{ .config = config, .mode = .@"resume" }));
    var with_requester = config;
    with_requester.ui_requester = .{ .ctx = &host, .requestFn = HostedSession.requestUi };
    try std.testing.expectError(error.UiRequesterNotAllowed, host.open(.{ .config = with_requester }));

    const hosted = try host.open(.{ .config = config });
    const id = hosted.id;
    try std.testing.expectError(error.SessionAlreadyOpen, host.open(.{ .config = config, .id = id }));
    try std.testing.expectEqual(InterruptOutcome.no_run, hosted.interrupt());
    try std.testing.expectError(error.NoSuchRequest, hosted.respond(1, "{}"));

    try hosted.command(.{ .set_model = "other-model" });
    try waitForLine(&hosted.journal, "\"type\":\"command_result\"");
    try hosted.submit(.{ .text = "unreachable provider", .trace_id = "t" });
    try waitForLine(&hosted.journal, "\"type\":\"user_message\"");
    _ = hosted.interrupt();
    try waitForLine(&hosted.journal, "\"type\":\"run_done\"");
    var snapshot = try hosted.snapshot(a);
    defer snapshot.deinit(a);
    try std.testing.expectEqualStrings("other-model", snapshot.model);
    try std.testing.expect(snapshot.seq >= 3);

    const ids = try host.list(a);
    defer a.free(ids);
    try std.testing.expectEqual(@as(usize, 1), ids.len);
    host.release(hosted);
    try host.close(id);
    try std.testing.expectError(error.SessionNotFound, host.close(id));
}

test "SessionHost: cancellation wins over a racing answer; an interrupt after the Run returned is too late" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const runtime = try AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{ .transcripts = false });
    defer host.deinit();
    const hosted = try host.open(.{ .config = .{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = "http://127.0.0.1:9",
        .workspace = .{ .root = root },
        .allowed_tools = &.{},
    } });
    defer hosted.release();
    const allow = "{\"choice\":\"allow_once\"}";

    // The driver is idle; stand in for a pending permission prompt.
    hosted.mutex.lock();
    hosted.pending_request_id = 7;
    hosted.run_interrupted = true;
    hosted.mutex.unlock();
    // Interrupt already in force: the answer is refused...
    try std.testing.expectError(error.NoSuchRequest, hosted.respond(7, allow));
    // ...and one stored just before the interrupt is discarded when taken.
    hosted.mutex.lock();
    hosted.run_interrupted = false;
    hosted.mutex.unlock();
    try hosted.respond(7, allow);
    hosted.mutex.lock();
    hosted.run_interrupted = true;
    const taken = hosted.takeResponseLocked();
    hosted.pending_request_id = 0;
    hosted.run_interrupted = false;
    hosted.mutex.unlock();
    try std.testing.expect(taken == null);

    // The Run has returned and finishRun is still reporting it.
    hosted.mutex.lock();
    hosted.phase = .running;
    hosted.run_returned = true;
    hosted.mutex.unlock();
    try std.testing.expectEqual(InterruptOutcome.too_late, hosted.interrupt());
    hosted.mutex.lock();
    hosted.phase = .idle;
    hosted.run_returned = false;
    hosted.mutex.unlock();
}

test "SessionHost: a pending prompt answered and interrupted at once is cancelled through requestUi" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const runtime = try AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    var host = SessionHost.init(a, runtime, .{ .transcripts = false });
    defer host.deinit();
    const hosted = try host.open(.{ .config = .{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = "http://127.0.0.1:9",
        .workspace = .{ .root = root },
        .allowed_tools = &.{},
    } });
    defer hosted.release();

    // Once the prompt is announced, an "allow" and an interrupt arrive
    // together, before the requester wakes up.
    const Racer = struct {
        fn run(session: *HostedSession) void {
            waitForLine(&session.journal, "\"type\":\"ui_request\"") catch return;
            session.mutex.lock();
            defer session.mutex.unlock();
            session.response = session.gpa.dupe(u8, "{\"choice\":\"allow_once\"}") catch null;
            session.run_interrupted = true;
            session.ui_ready.broadcast();
        }
    };
    const thread = try std.Thread.spawn(.{}, Racer.run, .{hosted});
    defer thread.join();
    const request = ui_request.UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    var response: ui_request.UiResponse = undefined;
    try std.testing.expectEqual(ui_request.RequestOutcome.answered, try HostedSession.requestUi(hosted, hosted.id, a, &request, &response));
    try std.testing.expectEqual(ui_request.PermissionChoice.deny_once, response.permission);
    try waitForLine(&hosted.journal, "\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"cancelled\"");
    hosted.mutex.lock();
    hosted.run_interrupted = false;
    hosted.mutex.unlock();
}
