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
//! of the table, releases its pending prompt, aborts its Run, joins the
//! driver, closes the journal (waking every reader), waits until every
//! reference is released and only then destroys the AgentSession — so a
//! thread must release its own reference before it closes. Once `close`
//! returns, the id can be opened again. `gpa` must be thread-safe: the driver,
//! journal readers and Host threads all allocate from it.

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
            hosted.teardown();
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

    pub fn release(_: *SessionHost, hosted: *HostedSession) void {
        hosted.mutex.lock();
        defer hosted.mutex.unlock();
        std.debug.assert(hosted.references > 0);
        hosted.references -= 1;
        if (hosted.references == 0) hosted.released.broadcast();
    }

    /// See the module comment. Returns after the Session is gone.
    pub fn close(self: *SessionHost, id: SessionId) error{SessionNotFound}!void {
        self.mutex.lock();
        const removed = self.sessions.fetchRemove(id.bytes);
        self.mutex.unlock();
        const entry = removed orelse return error.SessionNotFound;
        entry.value.teardown();
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
    host: *SessionHost,
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
    released: sync.Condition = .{},
    ui_ready: sync.Condition = .{},
    queue: std.ArrayList(*Work) = .empty,
    phase: Phase = .idle,
    closing: bool = false,
    references: usize = 0,
    /// The admitted Run, 0 between Runs.
    current_run_id: u64 = 0,
    /// Set by `interrupt` for the Run being started or running; cleared when
    /// the next submission is taken.
    run_interrupted: bool = false,
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
        const work = try self.host.gpa.create(Work);
        work.* = .{ .arena = std.heap.ArenaAllocator.init(self.host.gpa), .item = .{ .command = .compact } };
        return work;
    }

    /// Takes `work` on success; on error the caller still owns it.
    fn enqueue(self: *HostedSession, work: *Work) EnqueueError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing) return error.SessionClosed;
        if (self.phase == .poisoned) return error.SessionPoisoned;
        if (self.queue.items.len >= self.host.options.max_queued) return error.QueueFull;
        try self.queue.append(self.host.gpa, work);
        self.work_ready.signal();
    }

    /// Stops the current Run (or the one about to be admitted) and answers a
    /// pending UI request as cancelled. Queued work still runs afterwards.
    pub fn interrupt(self: *HostedSession) InterruptOutcome {
        self.mutex.lock();
        const run_id = self.current_run_id;
        const starting = self.phase == .running;
        if (starting) self.run_interrupted = true;
        self.ui_ready.broadcast();
        self.mutex.unlock();
        if (run_id == 0) return if (starting) .requested else .no_run;
        self.session.abort(run_id, .user_interrupt) catch return .too_late;
        return .requested;
    }

    /// Answers UI request `request_id` with a `protocol.wire` response. A
    /// request that is not the pending one (answered, cancelled, stale) is
    /// `error.NoSuchRequest`.
    pub fn respond(self: *HostedSession, request_id: u64, response_json: []const u8) RespondError!void {
        const owned = try self.host.gpa.dupe(u8, response_json);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending_request_id == 0 or self.pending_request_id != request_id or self.response != null) {
            self.host.gpa.free(owned);
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
            .permission_mode = self.session.permission_ctx.modeValue(),
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
                }
                return work;
            }
            self.work_ready.wait(&self.mutex);
        }
    }

    fn freeWork(self: *HostedSession, work: *Work) void {
        work.arena.deinit();
        self.host.gpa.destroy(work);
    }

    const RunScope = struct {
        hosted: *HostedSession,
        context: wire.RunContext,

        fn sink(self: *RunScope) agent_session.EventSink {
            return .{ .ctx = self, .emit = emit };
        }

        fn emit(ctx: *anyopaque, _: SessionId, _: u64, event: ui_event.CoreEvent) bool {
            const self: *RunScope = @ptrCast(@alignCast(ctx));
            const line = wire.writeRunEvent(self.hosted.host.gpa, self.context, event) catch {
                log.warn("session_host", "dropped CoreEvent .{s} (OOM)", .{@tagName(event)});
                return true;
            };
            defer self.hosted.host.gpa.free(line);
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
        defer dropped.deinit(self.host.gpa);
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
        const copy = self.host.gpa.dupe(u8, model) catch |err| return err;
        self.session.setModel(model) catch |err| {
            self.host.gpa.free(copy);
            return err;
        };
        self.mutex.lock();
        const previous = self.model;
        self.model = copy;
        self.mutex.unlock();
        // The transcript's meta names the model; the writer borrows this copy.
        if (self.writer) |*writer| writer.model = self.model;
        self.host.gpa.free(previous);
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
        const line = wire.writeHostEvent(self.host.gpa, event) catch {
            log.warn("session_host", "dropped host event .{s} (OOM)", .{@tagName(event)});
            return;
        };
        defer self.host.gpa.free(line);
        self.journal.append(line);
    }

    fn appendLine(self: *HostedSession, line: error{OutOfMemory}![]u8) void {
        const owned = line catch return;
        defer self.host.gpa.free(owned);
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

        const announce = wire.writeRequest(self.host.gpa, request_id, req) catch |err| {
            self.mutex.lock();
            self.pending_request_id = 0;
            self.mutex.unlock();
            return err;
        };
        defer self.host.gpa.free(announce);
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
        const response = self.response;
        self.response = null;
        self.pending_request_id = 0;
        self.mutex.unlock();

        if (response) |json| {
            defer self.host.gpa.free(json);
            self.appendLine(wire.writeRequestClosed(self.host.gpa, request_id, .answered));
            return wire.parseResponse(req, json, allocator, out);
        }
        self.appendLine(wire.writeRequestClosed(self.host.gpa, request_id, .cancelled));
        return wire.cancelResponse(req, out);
    }

    // ── teardown ──────────────────────────────────────────────────────────

    /// Ends the driver: no further work is taken, a pending UI request is
    /// answered as cancelled, and the current Run is aborted.
    fn stopDriver(self: *HostedSession) void {
        self.mutex.lock();
        self.closing = true;
        self.phase = .closing;
        const run_id = self.current_run_id;
        self.work_ready.broadcast();
        self.ui_ready.broadcast();
        self.mutex.unlock();
        if (run_id != 0) self.session.abort(run_id, .user_interrupt) catch {};
        self.driver.join();
    }

    fn teardown(self: *HostedSession) void {
        self.stopDriver();

        self.journal.close();
        self.mutex.lock();
        while (self.references > 0) self.released.wait(&self.mutex);
        const queued = self.queue;
        self.queue = .empty;
        self.mutex.unlock();
        for (queued.items) |work| self.freeWork(work);
        var queue = queued;
        queue.deinit(self.host.gpa);

        self.session.destroy() catch |err| log.err("session_host", "destroy {s}: {s}", .{ self.id.asSlice(), @errorName(err) });
        if (self.writer) |*writer| writer.deinit();
        if (self.response) |json| self.host.gpa.free(json);
        self.journal.deinit();
        self.host.gpa.free(self.model);
        self.host.gpa.destroy(self);
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
