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
//! Authentication, tenancy and the transport stay with the Host.
//!
//! A submission may be typed (#447, core/typed_submission.zig): its
//! `source`, `kind` and `attributes` are echoed on its `user_message` and
//! reach the provider only through the Session's submission template. Its
//! `idempotency_key` makes repeated deliveries one Run: a key already queued,
//! running or started within `idempotency_retention_ms` is refused as
//! `error.DuplicateSubmission`, also by a Host that resumed the Session after
//! a restart (core/idempotency_ledger.zig, kept in the session directory).
//! A full queue refuses before anything is held, so a refused delivery can
//! be retried; `Snapshot` reports the depth and the bound.
//!
//! A Host whose client opens the channel with a capability frame
//! (doc/WIRE_PROTOCOL.md §2) hands it to `declareCapabilities`; from then on
//! a UI request the client cannot render is journaled as
//! `ui_request_unavailable` and answered `unrenderable` without waiting. A
//! Session whose client never declares announces every request, as before.
//!
//! UI requests (#446). An answer may name who gave it (`by`); its
//! `ui_request_closed` line records them. What an unanswered request gets
//! once `ui_request_timeout_ms` passes is `ui_request_expiry`'s choice. With
//! `ui_request_wait = .suspend`, a question or custom UI request does not hold
//! the driver: its Run ends `suspended`, the Session's directory keeps the
//! request (`ui_request_store`), `close` leaves it there, a
//! Session opened again under its id announces it again under the same id,
//! and `respond` resumes the Run with the answer, once (`AgentSession`'s
//! `AdmittedRun.resumeWithResults`). A permission request always blocks: the
//! kernel's permission gate reads a `pending` answer as no answer and denies
//! the tool. Work submitted while a request waits is queued behind it, and
//! `Snapshot.queue_waiting` says so.
//!
//! Per Session one driver thread makes every call into the AgentSession.
//! Submissions and configuration commands share one FIFO, so "set the model,
//! then send this" happens in that order and only while the Session is idle.
//! `interrupt` is the one cross-thread call into the kernel; its abort is
//! built for that.
//!
//! A team lead (`SessionConfig.team` with the lead role, once its team
//! exists) is fed its inbox the way the bundled daemon feeds an `App` lead
//! (#277, #445): while its queue is empty the driver reads the lead inbox at
//! most every `lead_inbox_poll_ms`, and a teammate's reply becomes the lead's
//! next Run, queued behind the work already there.
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
const builtin = @import("builtin");
const sync = @import("platform").sync;
const pfs = @import("platform").fs;
const agent_session = @import("agent_session.zig");
const agent_loop = @import("agent_loop.zig");
const ui_request_store = @import("ui_request_store.zig");
const tool_error = @import("tool_error.zig");
const ask_user = @import("../tools/ask_user.zig");
const Conversation = @import("conversation.zig").Conversation;
const MessagePosition = @import("conversation.zig").MessagePosition;
const transcript = @import("transcript.zig");
const workspace_policy = @import("workspace_policy.zig");
const EventJournal = @import("event_journal.zig").EventJournal;
const wire = @import("protocol/wire.zig");
const ui_request = @import("protocol/ui_request.zig");
const ui_event = @import("protocol/ui_event.zig");
const frontend_capabilities = @import("protocol/frontend_capabilities.zig");
const session_id_mod = @import("session_id.zig");
const types = @import("../types.zig");
const prompt_sections = @import("prompt_sections.zig");
const typed_submission = @import("typed_submission.zig");
const idempotency_ledger = @import("idempotency_ledger.zig");
const permission_settings = @import("../permission/settings.zig");
const util_time = @import("../util/time.zig");
const log = @import("../util/log.zig");
const swarm_tools = @import("../swarm/tools.zig");

/// How often an idle team lead's inbox, a locked file, is read: the bundled
/// daemon's `session_service.LeadMail.POLL_MS`.
pub const lead_inbox_poll_ms: u64 = 500;

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
    /// How a question or custom UI request waits for its answer: holding the
    /// driver (`.block`, as before #446) or as a suspended Run that survives
    /// `close` (`.suspend`, which needs `transcripts`). A permission request
    /// always blocks.
    ui_request_wait: UiRequestWait = .block,
    /// What a request `ui_request_timeout_ms` leaves unanswered gets.
    ui_request_expiry: UiRequestExpiry = .cancel,
    /// How long a UI request waits for `respond`. Null waits until
    /// `interrupt` or `close`. An expired request gets `ui_request_expiry`.
    ui_request_timeout_ms: ?u64 = null,
    /// How long after its Run started an idempotency key still makes a
    /// delivery a duplicate. With `transcripts`, the keys outlive the Host:
    /// a Session opened again under its id (resumed or fresh) keeps them.
    idempotency_retention_ms: u64 = 24 * std.time.ms_per_hour,
    /// Started idempotency keys kept per Session; beyond it the oldest is
    /// forgotten first.
    idempotency_max_keys: usize = 10_000,
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
    /// How a submission becomes its Run's user message (#447). Null: the
    /// text alone, byte for byte, so `source`, `kind` and `attributes` never
    /// reach the provider. Otherwise `{{text}}`, `{{source}}`, `{{kind}}` and
    /// `{{attributes}}` are substituted (`typed_submission.render`); any
    /// other `{{` refuses the open (`error.InvalidSubmissionTemplate`).
    /// Copied.
    submission_template: ?[]const u8 = null,
};

/// `suspended` (#446): a Run ended `suspended` on UI request
/// `Snapshot.pending_request_id` (`Options.ui_request_wait = .suspend`);
/// nothing else runs until that request is answered, interrupted or expires.
/// Queued work waits, and a team lead does not read its inbox (reading marks
/// mail read), so a teammate's reply waits there for the lead to resume.
pub const Phase = enum { idle, running, suspended, poisoned, closing };

/// One of a typed submission's `attributes` (#447).
pub const Attribute = typed_submission.Attribute;

pub const Submission = struct {
    text: []const u8,
    /// Opaque; echoed as `trace_id` on this Run's wire lines.
    trace_id: ?[]const u8 = null,
    /// Edit-and-rerun (issue #432): `text` replaces the user message at this
    /// position. Just before the Run, the driver drops that message and
    /// everything after it (`AgentSession.rewindToUserMessage`), so the Run
    /// sees exactly the context that preceded it plus `text`. A position that
    /// cannot be rerun fails the Run with its `RewindError` name and changes
    /// nothing. Null appends `text` after the whole conversation.
    replaces: ?MessagePosition = null,
    /// Typed submission (#447; rules in core/typed_submission.zig): echoed
    /// on `user_message`, and seen by the provider only as the Session's
    /// submission template renders them.
    source: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    attributes: []const Attribute = &.{},
    /// One Run per key: see `SubmitError.DuplicateSubmission`. The key is
    /// spent when its Run starts, whatever the Run then does; to try again,
    /// submit under a new key.
    idempotency_key: ?[]const u8 = null,
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
/// `submit`'s refusals. Nothing is queued or held by any of them.
pub const SubmitError = EnqueueError || typed_submission.Invalid || error{
    /// The idempotency key was accepted before with the same submission:
    /// it is queued, running, or its Run started within
    /// `idempotency_retention_ms`. That delivery's Run answers for this one,
    /// so a transport reports it as accepted. Checked before the queue
    /// bound: a retry of accepted work is never told to back off.
    DuplicateSubmission,
    /// The idempotency key was accepted before for a different submission
    /// (its text, source, kind, attributes or `replaces` differ).
    IdempotencyKeyReused,
};
pub const RespondError = error{
    /// No request with this id is open: never announced, closed, or
    /// cancelled by an interrupt, a close or its expiry.
    NoSuchRequest,
    /// The request already took an answer, not yet applied (#446): this one
    /// changed nothing. A Host may report it as accepted.
    AlreadyAnswered,
    /// The answer's `by` is not an approver (`wire.answerApprover`); the
    /// request is still open.
    InvalidApprover,
    OutOfMemory,
};
/// Test seam, read only in test builds: runs on the interrupting or closing
/// thread once the cancellation is decided and before the kernel abort is
/// requested - the window in which a released prompt used to let the Run take
/// another turn.
pub const testing_hooks = struct {
    pub var before_abort: ?*const fn (*HostedSession) void = null;
    /// On the driver, once it has taken a suspended Run's resumption and
    /// before anything is applied (#446): the window in which a second
    /// answer to the same request must change nothing.
    pub var before_resumption: ?*const fn (*HostedSession) void = null;
};

pub const InterruptOutcome = enum {
    /// Nothing was running or about to run.
    no_run,
    /// A Run was in progress or being admitted: it stops unless it had just
    /// finished, and a pending UI request was answered as cancelled.
    requested,
    /// The Run had already finished.
    too_late,
};

/// How a question or custom UI request waits for its answer
/// (`Options.ui_request_wait`, #446).
pub const UiRequestWait = enum {
    /// The driver waits inside the request until `respond`, the timeout,
    /// `interrupt` or `close`, which answers it as cancelled. The default,
    /// and the only way before #446.
    block,
    /// The Run ends `suspended` (the kernel's suspension: the tool call is
    /// left without a result) and the Session's directory keeps the request.
    /// `close` leaves it there; a Session opened again under the id
    /// (`.resume`) announces it again under the same id; `respond` resumes
    /// the Run with the answer then, once. Request ids are kept too, so none
    /// is reused across restarts. A permission request still blocks as under
    /// `.block`: the kernel's permission gate reads a `pending` answer as no
    /// answer and denies the tool (permission/prompt.zig), so this mode never
    /// answers one `pending`. Needs `Options.transcripts`.
    @"suspend",
};

/// What a UI request that `ui_request_timeout_ms` leaves unanswered gets
/// (`Options.ui_request_expiry`, #446). Each closes the request with an
/// outcome v1 already has, never a new one (doc/WIRE_PROTOCOL.md §4).
pub const UiRequestExpiry = enum {
    /// The default, as before #446: the request closes `"cancelled"` with
    /// its safe answer (a permission denied once, a question or custom UI
    /// aborted) and the Run goes on without the answer.
    cancel,
    /// As `cancel`, and the Run stops there, as after `interrupt`, instead of
    /// going on without the answer.
    interrupt,
    /// The request is announced again, the same line under the same id, and
    /// waits another `ui_request_timeout_ms`; again until it is answered,
    /// interrupted or closed. A Host escalates on the repeated line.
    re_announce,
};

/// Why queued work has not started (`Snapshot.queue_waiting`, #446). A
/// Session runs one thing at a time, so work submitted while a request is
/// open is queued behind it, never refused for it; a Host that wants it to
/// run at once opens another Session.
pub const QueueWaiting = enum {
    /// Nothing is queued, or the driver is taking the head now.
    none,
    /// Behind the Run in progress.
    run,
    /// Behind UI request `pending_request_id`: the Run in progress waits for
    /// its answer, or, in `Phase.suspended`, the suspended Run does.
    ui_request,
};

/// What a Host reports about a Session (e.g. as `/state`). `model` is owned
/// by the allocator given to `snapshot`.
pub const Snapshot = struct {
    id: SessionId,
    phase: Phase,
    model: []const u8,
    permission_mode: types.PermissionMode,
    reasoning_effort: ?types.ReasoningEffort,
    /// Submissions and commands waiting, and the bound (`Options.max_queued`)
    /// at which `submit` and `command` refuse with `error.QueueFull`.
    queued: usize,
    max_queued: usize,
    seq: usize,
    epoch: [16]u8,
    pending_request_id: u64,
    /// What queued work waits for (#446); `.ui_request` names
    /// `pending_request_id`.
    queue_waiting: QueueWaiting,
    /// The Session's UI request policies, as `Options` declared them: how a
    /// question or custom UI request waits (a permission request always
    /// blocks), how long a request waits, and what it gets when that passes.
    ui_request_wait: UiRequestWait,
    ui_request_timeout_ms: ?u64,
    ui_request_expiry: UiRequestExpiry,
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
        // A suspended request lives in the Session's directory.
        if (self.options.ui_request_wait == .@"suspend" and !self.options.transcripts) return error.SuspendRequiresTranscripts;
        if (spec.config.ui_requester != null or spec.config.run_ui_requester != null) return error.UiRequesterNotAllowed;
        if (spec.mode == .@"resume" and spec.id == null) return error.IdRequiredForResume;
        if (spec.submission_template) |template| try typed_submission.checkTemplate(template);
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
        const template = if (spec.submission_template) |text| try self.gpa.dupe(u8, text) else null;
        errdefer if (template) |text| self.gpa.free(text);
        hosted.* = .{
            .host = self,
            .gpa = self.gpa,
            .id = undefined,
            .session = undefined,
            .journal = EventJournal.init(self.gpa),
            .model = model,
            .reasoning_effort = spec.config.reasoning_effort,
            .max_queued = self.options.max_queued,
            .submission_template = template,
            .ledger = .init(self.gpa, self.options.idempotency_retention_ms, self.options.idempotency_max_keys),
        };
        errdefer hosted.journal.deinit();
        errdefer hosted.ledger.deinit();

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
        // The keys belong to the id, not to one conversation: a fresh open
        // under a reused id keeps them, as a delivery that ran stays run.
        if (hosted.writer) |*writer| try hosted.ledger.load(writer.dir, wallMs());

        // UI requests (#446): the policies, read by a shell that outlives the
        // SessionHost too, and what the Session's directory kept.
        hosted.request_policy = .{
            .wait = self.options.ui_request_wait,
            .timeout_ms = self.options.ui_request_timeout_ms,
            .expiry = self.options.ui_request_expiry,
        };
        hosted.store_dir = if (hosted.writer) |*writer| writer.dir else null;
        hosted.restoreRequests(spec.mode, &conversation);
        errdefer hosted.dropRequests();
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
        /// The driver's own (#446): resume the suspended Run with how its
        /// request was settled (`HostedSession.suspension`, not owned here).
        resumption: *Suspension,
        /// The driver's own (#446): announce the suspended Run's request
        /// again (`UiRequestExpiry.re_announce`).
        re_announce,
    },
};

/// The UI request policies of a Session (`Options`, #446).
const RequestPolicy = struct {
    wait: UiRequestWait = .block,
    timeout_ms: ?u64 = null,
    expiry: UiRequestExpiry = .cancel,
};

/// A question or custom UI request the Run in progress answered `pending`
/// (`UiRequestWait.suspend`): the kernel suspends the Run on it at the end of
/// the tool calls in flight. Strings are the Session allocator's.
const Suspending = struct {
    id: u64,
    /// Its `ui_request` line.
    announcement: []u8,
    /// An answer that came before the Run suspended, applied once it has.
    answer: ?[]u8 = null,
    by: ?[]u8 = null,
};

/// A Run that ended `suspended`, kept until its request is settled and the
/// driver resumes it (#446). Everything but `settled` is fixed once held and
/// lives in `arena`; `settled`'s strings are the Session allocator's.
const Suspension = struct {
    arena: std.heap.ArenaAllocator,
    request_id: u64,
    /// The request's `ui_request` line, announced again as is, and the
    /// request read back from it.
    announcement: []const u8,
    request: ui_request.UiRequest,
    /// The tool call the Run suspended on, and the results of the calls that
    /// ran beside it (the kernel's `SuspendInfo`).
    tool_use_id: []const u8,
    tool_name: []const u8,
    completed: []const agent_loop.SuspendInfo.CompletedResult,
    /// The suspended Run's own settings, which the Run resuming it keeps.
    settings: RunSettings,
    /// Wall-clock milliseconds at which the request expires unanswered.
    /// Driver-only.
    expires_at_ms: ?i64,
    /// Under the Session's `mutex`.
    settled: Settled = .open,

    const Settled = union(enum) {
        open,
        answered: struct { json: []u8, by: ?[]u8 },
        cancelled: struct { stop: bool },
    };
};

/// What was per-Run in a Run, given again to the Run that resumes it.
const RunSettings = struct {
    trace_id: ?[]const u8 = null,
    max_turns: u32,
    /// `AdmittedRun.stream_retry_budget` (#452). SessionHost leaves it at 0
    /// (the loop's default) and keeps whatever its Run had.
    stream_retry_budget: u8 = 0,
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
    /// the next submission is taken. From then on no answer is accepted or
    /// taken.
    run_interrupted: bool = false,
    /// A pending UI request may stop waiting without an answer. Set only once
    /// the cancellation is in force in the kernel - the Run's abort requested
    /// - so the Run that resumes from the cancelled prompt sees the abort
    /// rather than starting another turn first. Cleared with
    /// `run_interrupted`.
    ui_released: bool = false,
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
    /// Who gave `response`, when it named them (`wire.answerApprover`).
    response_by: ?[]u8 = null,
    /// The policies the Session's requests follow (#446).
    request_policy: RequestPolicy = .{},
    /// The Session's directory, where `ui_request_store` keeps its request
    /// ids and a suspended request; null without transcripts. Borrowed from
    /// `writer`; set before the driver starts.
    store_dir: ?[]const u8 = null,
    /// The request the Run in progress answered `pending`, under `mutex`.
    suspending: ?Suspending = null,
    /// The suspended Run while `phase` is `.suspended`, and until its
    /// resumption has journaled the request's close. Under `mutex`; the
    /// driver (or, once it stopped, `shutdown`) frees it.
    suspension: ?*Suspension = null,
    /// The suspension the Run in progress resumes. Its settlement stays in
    /// `ui_request_store` until the transcript holds the call's result, the
    /// witness the next open checks. Under `mutex`; the driver frees it.
    resuming: ?*Suspension = null,
    /// What the client declared it renders; empty until `declareCapabilities`.
    capabilities: frontend_capabilities.Slot = .{},
    /// `Options.max_queued`, for a `snapshot` of a shell that outlived its
    /// SessionHost.
    max_queued: usize,
    /// `OpenSpec.submission_template`, owned.
    submission_template: ?[]u8 = null,
    /// Idempotency keys (#447): entries under `mutex`, the file the driver's.
    ledger: idempotency_ledger.Ledger,

    // Driver-only.
    last_run_id: u64 = 0,
    last_compact_id: u64 = 0,
    /// When an idle team lead's inbox is read next (`util_time.nowNs`).
    next_lead_poll_ns: i128 = 0,

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

    pub fn submit(self: *HostedSession, submission: Submission) SubmitError!void {
        const fields = typedFields(submission);
        try typed_submission.validate(fields);
        const work = try self.newWork();
        errdefer self.freeWork(work);
        const a = work.arena.allocator();
        work.item = .{ .submission = .{
            .text = try a.dupe(u8, submission.text),
            .trace_id = if (submission.trace_id) |trace_id| try a.dupe(u8, trace_id) else null,
            .replaces = submission.replaces,
            .source = if (submission.source) |source| try a.dupe(u8, source) else null,
            .kind = if (submission.kind) |kind| try a.dupe(u8, kind) else null,
            .attributes = try typed_submission.dupeAttributes(a, submission.attributes),
            .idempotency_key = if (submission.idempotency_key) |key| try a.dupe(u8, key) else null,
        } };
        const key = submission.idempotency_key orelse return self.enqueue(work);
        try self.enqueueKeyed(work, key, typed_submission.digest(fields));
    }

    /// `enqueue` holding `key` as pending under the same lock, so of two
    /// racing deliveries exactly one is queued. A duplicate is refused before
    /// the queue bound, and a delivery refused for the bound holds nothing.
    fn enqueueKeyed(self: *HostedSession, work: *Work, key: []const u8, digest: typed_submission.Digest) SubmitError!void {
        const now = wallMs();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing) return error.SessionClosed;
        if (self.phase == .poisoned) return error.SessionPoisoned;
        switch (self.ledger.check(key, digest, now)) {
            .new => {},
            .duplicate => return error.DuplicateSubmission,
            .reused => return error.IdempotencyKeyReused,
        }
        if (self.queue.items.len >= self.host.options.max_queued) return error.QueueFull;
        try self.ledger.accept(key, digest);
        self.queue.append(self.gpa, work) catch |err| {
            self.ledger.forget(key);
            return err;
        };
        self.work_ready.signal();
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
        if (self.phase == .suspended) {
            // The suspended request is cancelled, winning over an answer not
            // yet applied; the Run resumes only to record that, then stops.
            if (self.suspension) |suspension| self.cancelSuspensionLocked(suspension, true);
            self.work_ready.signal();
            self.mutex.unlock();
            return .requested;
        }
        if (self.phase == .running and self.run_returned) {
            self.mutex.unlock();
            return .too_late;
        }
        const run_id = self.current_run_id;
        const starting = self.phase == .running;
        if (starting) self.run_interrupted = true;
        if (run_id == 0) {
            // Not admitted yet, so no prompt is pending: runSubmission aborts
            // the Run it admits and releases its prompts then.
            self.mutex.unlock();
            return if (starting) .requested else .no_run;
        }
        self.kernel_users += 1;
        self.mutex.unlock();
        defer self.leaveKernel();
        if (builtin.is_test) if (testing_hooks.before_abort) |hook| hook(self);
        const outcome: InterruptOutcome = if (self.session.abort(run_id, .user_interrupt)) |_| .requested else |_| .too_late;
        // Abort first, then release the prompt: woken earlier, the Run took
        // the cancelled prompt as a denied tool, sent its next request, and
        // could end normally before the abort arrived.
        self.releaseUi();
        return outcome;
    }

    /// Lets a pending UI request return cancelled; call once the abort (if
    /// any) is in force.
    fn releaseUi(self: *HostedSession) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ui_released = true;
        self.ui_ready.broadcast();
    }

    fn leaveKernel(self: *HostedSession) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.kernel_users -= 1;
        if (self.kernel_users == 0) self.kernel_idle.broadcast();
    }

    /// Answers UI request `request_id` with a `protocol.wire` response, which
    /// may name who gave it (`by`, recorded on `ui_request_closed`). A
    /// request that is not open (closed, stale, or cancelled by an interrupt,
    /// a close or its expiry) is `error.NoSuchRequest`; one that already took
    /// an answer not yet applied is `error.AlreadyAnswered`. Neither changes
    /// anything. A suspended Run's request (`UiRequestWait.suspend`) is
    /// answered the same way, also after a restart; its Run then resumes.
    pub fn respond(self: *HostedSession, request_id: u64, response_json: []const u8) RespondError!void {
        const by = try wire.answerApprover(self.gpa, response_json);
        errdefer if (by) |name| self.gpa.free(name);
        const owned = try self.gpa.dupe(u8, response_json);
        errdefer self.gpa.free(owned);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending_request_id == 0 or self.pending_request_id != request_id or self.closing) return error.NoSuchRequest;
        if (self.suspension) |suspension| {
            switch (suspension.settled) {
                .open => {},
                .answered => return error.AlreadyAnswered,
                .cancelled => return error.NoSuchRequest,
            }
            suspension.settled = .{ .answered = .{ .json = owned, .by = by } };
            self.work_ready.signal();
            return;
        }
        if (self.run_interrupted) return error.NoSuchRequest;
        if (self.suspending) |*pending| {
            // Before its Run has suspended: applied once it has.
            if (pending.answer != null) return error.AlreadyAnswered;
            pending.answer = owned;
            pending.by = by;
            return;
        }
        if (self.response != null) return error.AlreadyAnswered;
        self.response = owned;
        self.response_by = by;
        self.ui_ready.broadcast();
    }

    /// Installs the client's capability frame, replacing any earlier one, and
    /// journals its `capabilities_accepted` line, which is returned owned by
    /// `allocator`. Requests made from then on are routed by it; one already
    /// pending is not. A refused frame changes nothing: reply with
    /// `wire.writeCapabilitiesRefused`.
    pub fn declareCapabilities(self: *HostedSession, allocator: std.mem.Allocator, frame_json: []const u8) wire.DeclareError![]u8 {
        var accepted = try wire.acceptCapabilities(self.gpa, frame_json);
        errdefer {
            accepted.declaration.deinit();
            self.gpa.free(accepted.line);
        }
        const reply = try allocator.dupe(u8, accepted.line);
        errdefer allocator.free(reply);
        try self.capabilities.install(self.gpa, accepted.declaration, accepted.line);
        self.journal.append(reply);
        return reply;
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
            .max_queued = self.max_queued,
            .seq = self.journal.count(),
            .epoch = self.journal.epochHex(),
            .pending_request_id = self.pending_request_id,
            .queue_waiting = if (self.queue.items.len == 0)
                .none
            else if (self.pending_request_id != 0)
                .ui_request
            else if (self.phase == .running)
                .run
            else
                .none,
            .ui_request_wait = self.request_policy.wait,
            .ui_request_timeout_ms = self.request_policy.timeout_ms,
            .ui_request_expiry = self.request_policy.expiry,
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
                .resumption => |suspension| self.runResumption(suspension),
                .re_announce => self.reannounce(),
            }
        }
    }

    fn nextWork(self: *HostedSession) ?*Work {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            // A suspended Run comes first, and nothing else runs meanwhile:
            // its conversation ends in a call without a result, so no Run may
            // start on it. Queued work waits, and a lead's inbox is not read
            // (the poll below marks what it takes as read).
            if (self.phase == .suspended and !self.closing) {
                if (self.suspendedWorkLocked()) |work| return work;
                continue;
            }
            if (self.closing) return null;
            if (self.phase == .poisoned) {
                self.work_ready.wait(&self.mutex);
                continue;
            }
            if (self.queue.items.len > 0) {
                const work = self.queue.orderedRemove(0);
                if (work.item == .submission) {
                    self.phase = .running;
                    self.run_interrupted = false;
                    self.ui_released = false;
                    self.run_returned = false;
                }
                return work;
            }
            if (!self.leadsTeam()) {
                self.work_ready.wait(&self.mutex);
                continue;
            }
            const now = util_time.nowNs();
            if (now < self.next_lead_poll_ns) {
                _ = self.work_ready.timedWait(&self.mutex, @intCast(self.next_lead_poll_ns - now));
                continue;
            }
            self.next_lead_poll_ns = now + @as(i128, lead_inbox_poll_ms) * std.time.ns_per_ms;
            // The inbox is a locked file: read it without holding the Session.
            self.mutex.unlock();
            const mail = self.takeLeadMail();
            self.mutex.lock();
            if (mail) |work| self.queue.append(self.gpa, work) catch {
                log.warn("session_host", "dropped teammate mail for {s} (OOM)", .{self.id.asSlice()});
                self.freeWork(work);
            };
        }
    }

    /// True for a team lead whose team exists. Driver-only: its Runs are what
    /// create and delete the team.
    fn leadsTeam(self: *const HostedSession) bool {
        const swarm = if (self.session.swarm) |*swarm| swarm else return false;
        return swarm.is_lead and swarm.hasTeam();
    }

    /// The lead inbox's unread mail as a submission, or null when there is
    /// none. Mail it returns is marked read. Driver-only.
    fn takeLeadMail(self: *HostedSession) ?*Work {
        const work = self.newWork() catch return null;
        const text = swarm_tools.pollLeadInbox(work.arena.allocator(), &self.session.swarm.?) catch |err| {
            log.warn("session_host", "lead inbox of {s} unreadable: {s}", .{ self.id.asSlice(), @errorName(err) });
            self.freeWork(work);
            return null;
        } orelse {
            self.freeWork(work);
            return null;
        };
        work.item = .{ .submission = .{ .text = text } };
        return work;
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
        self.emitHost(.{ .user_message = .{
            .run_id = context.run_id,
            .trace_id = context.trace_id,
            .text = submission.text,
            .replaces = if (submission.replaces) |position| position.ordinal() else null,
            .source = submission.source,
            .kind = submission.kind,
            .idempotency_key = submission.idempotency_key,
            .attributes = submission.attributes,
        } });
        if (submission.idempotency_key) |key| self.startKey(key) catch |err| {
            self.finishRun(context, null, err, null);
            return;
        };
        // Without a template the Run's input is the submitted text, byte for
        // byte: nothing typed reaches the provider.
        const rendered: ?[]u8 = if (self.submission_template) |template|
            typed_submission.render(self.gpa, template, typedFields(submission)) catch |err| {
                self.finishRun(context, null, err, null);
                return;
            }
        else
            null;
        defer if (rendered) |input| self.gpa.free(input);

        var scope = RunScope{ .hosted = self, .context = context };
        // An interrupt of the previous Run may still be inside the provider's
        // cancel; admission would report SessionBusy until it returns.
        self.session.awaitProviderCancelsDrained();
        if (submission.replaces) |position| {
            self.session.rewindToUserMessage(position) catch |err| {
                self.finishRun(context, null, err, null);
                return;
            };
        }
        var admitted = self.session.admitRun(context.run_id, scope.sink()) catch |err| {
            self.finishRun(context, null, err, null);
            return;
        };
        // An interrupt or close that arrived between taking the submission
        // and admitting the Run had no Run to abort; it applies now. Either
        // that caller saw `current_run_id` or this block sees its flag.
        self.mutex.lock();
        self.current_run_id = context.run_id;
        const stop_now = self.run_interrupted or self.closing;
        self.mutex.unlock();
        if (stop_now) {
            self.session.abort(context.run_id, .user_interrupt) catch {};
            self.releaseUi();
        }

        const outcome = admitted.runText(rendered orelse submission.text, self.host.options.max_turns);
        self.mutex.lock();
        self.current_run_id = 0;
        self.run_returned = true;
        self.mutex.unlock();
        self.settleRun(context, outcome, .{
            .trace_id = submission.trace_id,
            .max_turns = self.host.options.max_turns,
            .stream_retry_budget = admitted.stream_retry_budget,
        });
    }

    /// The end of a Run that returned: a suspended Run is held (#446), a
    /// request it answered `pending` without suspending on is closed, and
    /// `finishRun` reports it.
    fn settleRun(self: *HostedSession, context: wire.RunContext, outcome: anyerror!agent_loop.RunResult, settings: RunSettings) void {
        const result = outcome catch |err| {
            self.closeSuspending();
            self.finishRun(context, null, err, null);
            return;
        };
        // Keyed on `suspend_info`, not the stop reason: an abort requested
        // while the turn suspended reports `aborted` and still leaves the
        // tool call without a result.
        if (result.suspend_info) |info| {
            defer info.deinit();
            self.holdSuspension(info, settings);
        } else self.closeSuspending();
        const failed_on_model = result.stop_reason == .api_error or result.stop_reason == .max_tokens_exhausted;
        const model_failure = if (failed_on_model) &self.session.last_model_error else null;
        self.finishRun(context, @tagName(result.stop_reason), null, model_failure);
    }

    /// Spends `key` on the Run starting now: in memory at once, so a delivery
    /// racing it is a duplicate, then in the ledger file before the Run does
    /// anything. A key that cannot be written is let go and the Run fails as
    /// `IdempotencyKeyNotRecorded`: without its record a restarted Host would
    /// run the delivery again.
    fn startKey(self: *HostedSession, key: []const u8) error{IdempotencyKeyNotRecorded}!void {
        const now = wallMs();
        self.mutex.lock();
        const entry = self.ledger.start(key, now);
        self.mutex.unlock();
        const started = entry orelse return;
        self.ledger.append(key, started) catch |err| {
            log.warn("session_host", "idempotency key of {s} not recorded: {s}", .{ self.id.asSlice(), @errorName(err) });
            self.mutex.lock();
            self.ledger.forget(key);
            self.mutex.unlock();
            return error.IdempotencyKeyNotRecorded;
        };
        if (!self.ledger.wantsRewrite()) return;
        self.mutex.lock();
        const live = self.ledger.encodeStarted(self.gpa);
        self.mutex.unlock();
        // Best effort: an untrimmed file still answers every key it holds.
        const bytes = live catch return;
        defer self.gpa.free(bytes);
        self.ledger.replaceFile(bytes) catch |err|
            log.warn("session_host", "idempotency ledger of {s} not trimmed: {s}", .{ self.id.asSlice(), @errorName(err) });
    }

    fn finishRun(
        self: *HostedSession,
        context: wire.RunContext,
        stop_reason: ?[]const u8,
        failure: ?anyerror,
        model_failure: ?*const ?@import("../api/model_error.zig").Detail,
    ) void {
        self.persist();
        const poisoned = self.session.isPoisoned();
        var dropped: std.ArrayList(*Work) = .empty;
        defer dropped.deinit(self.gpa);
        self.mutex.lock();
        if (poisoned) {
            self.phase = .poisoned;
            std.mem.swap(std.ArrayList(*Work), &dropped, &self.queue);
        } else if (!self.closing) {
            self.phase = if (self.suspension != null) .suspended else .idle;
        }
        self.mutex.unlock();
        for (dropped.items) |work| self.freeWork(work);

        self.emitHost(.{ .run_done = .{
            .run_id = context.run_id,
            .trace_id = context.trace_id,
            .stop_reason = stop_reason,
            .error_name = if (failure) |err| @errorName(err) else null,
            .model_error = if (model_failure) |slot| (if (slot.*) |*detail| detail.view() else null) else null,
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
        // A request the client declared it cannot render never waits, not
        // even behind another prompt.
        switch (self.capabilities.route(req)) {
            .deliver => {},
            .unavailable => |reason| {
                self.appendLine(wire.writeRequestUnavailable(self.gpa, req, reason));
                return .unrenderable;
            },
        }
        self.ui_serial.lock();
        defer self.ui_serial.unlock();
        const policy = self.request_policy;
        // `.suspend` never suspends a permission request: the kernel's gate
        // would read `pending` as no answer and deny the tool unasked.
        const suspends = policy.wait == .@"suspend" and req.* != .permission;

        self.mutex.lock();
        // Released means the abort is in force. An interrupt still on its way
        // to the kernel lets the prompt be announced and wait for it.
        if (self.ui_released) {
            self.mutex.unlock();
            return cancelAnswer(req, out);
        }
        // The kernel suspends a turn on its first pending request, and the
        // resumption must answer the call this request belongs to: so one
        // per turn. Another question or custom UI of the same turn is not
        // announced and answered `unavailable` (its call fails as without a
        // frontend; an error here would poison the AgentSession). A
        // permission request blocks as always.
        if (self.suspending != null and req.* != .permission) {
            self.mutex.unlock();
            return .unavailable;
        }
        const request_id = self.next_request_id;
        self.next_request_id += 1;
        self.pending_request_id = request_id;
        self.mutex.unlock();
        // `.suspend` keeps ids across restarts: this one is written before
        // anyone can answer it. Unwritten, it is still unique in this process.
        if (policy.wait == .@"suspend") self.storeRequests() catch |err|
            log.warn("session_host", "request id {d} of {s} not recorded: {s}", .{ request_id, self.id.asSlice(), @errorName(err) });

        const announce = wire.writeRequest(self.gpa, request_id, req) catch |err| {
            self.mutex.lock();
            self.pending_request_id = 0;
            self.mutex.unlock();
            return err;
        };
        if (suspends) {
            // Registered before it is announced, so an answer that comes at
            // once is kept for the suspension.
            self.mutex.lock();
            self.suspending = .{ .id = request_id, .announcement = announce };
            self.mutex.unlock();
            self.journal.append(announce);
            return .pending;
        }
        defer self.gpa.free(announce);
        self.journal.append(announce);

        const timeout_ns: ?i128 = if (policy.timeout_ms) |ms| @as(i128, ms) * std.time.ns_per_ms else null;
        var deadline: ?i128 = if (timeout_ns) |span| util_time.nowNs() + span else null;
        var expired_stop = false;
        self.mutex.lock();
        while (self.response == null and !self.ui_released) {
            if (deadline) |limit| {
                const now = util_time.nowNs();
                if (now >= limit) {
                    switch (policy.expiry) {
                        .cancel => break,
                        .interrupt => {
                            // From now on no answer is taken, as after `interrupt`.
                            self.run_interrupted = true;
                            expired_stop = true;
                            break;
                        },
                        .re_announce => {
                            deadline = now + timeout_ns.?;
                            self.mutex.unlock();
                            self.journal.append(announce);
                            self.mutex.lock();
                            continue;
                        },
                    }
                }
                _ = self.ui_ready.timedWait(&self.mutex, @intCast(limit - now));
            } else {
                self.ui_ready.wait(&self.mutex);
            }
        }
        const response = self.takeResponseLocked();
        const by = self.response_by;
        self.response_by = null;
        self.pending_request_id = 0;
        const run_id = self.current_run_id;
        self.mutex.unlock();
        defer if (by) |name| self.gpa.free(name);
        // As in `interrupt`: the abort, then the release that answers any
        // later prompt of this Run as cancelled at once. This thread is
        // inside the Run, so the Session cannot go away meanwhile.
        if (expired_stop) {
            if (run_id != 0) self.session.abort(run_id, .user_interrupt) catch {};
            self.releaseUi();
        }

        if (response) |json| {
            defer self.gpa.free(json);
            const reading = wire.parseResponse(req, json, allocator, out) catch |err| {
                self.appendLine(if (err == error.InputAborted)
                    wire.writeRequestClosedBy(self.gpa, request_id, .malformed, by)
                else
                    wire.writeRequestClosed(self.gpa, request_id, .cancelled));
                return if (err == error.InputAborted) cancelAnswer(req, out) else err;
            };
            self.appendLine(wire.writeRequestClosedBy(self.gpa, request_id, reading.closed(), by));
            return .answered;
        }
        self.appendLine(wire.writeRequestClosed(self.gpa, request_id, .cancelled));
        return cancelAnswer(req, out);
    }

    /// `wire.cancelResponse` as the AgentSession needs it (#446): a question
    /// that was cancelled or answered unreadably is the user's outcome,
    /// `error.UiCancelled`, which the AgentSession hands to the tool (the
    /// call fails with InputAborted, as the model sees). Any other error from
    /// a requester is a broken Host to it, and poisons the Session: a
    /// cancelled question used to end its Session that way.
    fn cancelAnswer(req: *const ui_request.UiRequest, out: *ui_request.UiResponse) anyerror!ui_request.RequestOutcome {
        return wire.cancelResponse(req, out) catch |err| switch (err) {
            error.InputAborted => if (req.* == .ask_question) error.UiCancelled else err,
        };
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
            // Nobody answered what the request closes on.
            if (self.response_by) |by| self.gpa.free(by);
            self.response_by = null;
            return null;
        }
        return response;
    }

    // ── suspended Runs (#446) ─────────────────────────────────────────────

    /// Cancels a suspended Run's request, winning over an answer not yet
    /// applied. `stop`: the Run resumes only to record it, then stops.
    /// Caller holds `mutex`.
    fn cancelSuspensionLocked(self: *HostedSession, suspension: *Suspension, stop: bool) void {
        const stopping = switch (suspension.settled) {
            .open => false,
            .answered => |answered| blk: {
                self.gpa.free(answered.json);
                if (answered.by) |by| self.gpa.free(by);
                break :blk false;
            },
            .cancelled => |cancelled| cancelled.stop,
        };
        suspension.settled = .{ .cancelled = .{ .stop = stop or stopping } };
    }

    fn freeSuspending(self: *HostedSession, pending: Suspending) void {
        self.gpa.free(pending.announcement);
        if (pending.answer) |json| self.gpa.free(json);
        if (pending.by) |by| self.gpa.free(by);
    }

    /// A request the Run answered `pending` but did not suspend on (it
    /// failed, or was stopped first) closes as cancelled.
    fn closeSuspending(self: *HostedSession) void {
        self.mutex.lock();
        const pending = self.suspending orelse {
            self.mutex.unlock();
            return;
        };
        self.suspending = null;
        self.pending_request_id = 0;
        self.mutex.unlock();
        self.freeSuspending(pending);
        self.appendLine(wire.writeRequestClosed(self.gpa, pending.id, .cancelled));
    }

    /// Holds a Run that ended `suspended` until its request is settled.
    /// Durable first: the conversation with the suspended call (the
    /// transcript is fsynced), then the request with a result for every
    /// other call of its turn (`ui_request_store`, the commit point a later
    /// open reads).
    fn holdSuspension(self: *HostedSession, info: agent_loop.SuspendInfo, settings: RunSettings) void {
        self.mutex.lock();
        const taken = self.suspending;
        self.suspending = null;
        self.mutex.unlock();
        var pending = taken orelse {
            // Only `requestUi` answers `pending`, so this is not reached.
            // With no request there is nothing to resume the call with; the
            // next Run's request stands in for its result (message_repair).
            log.err("session_host", "a Run of {s} suspended on {s} without a pending request", .{ self.id.asSlice(), info.tool_use_id });
            return;
        };
        defer self.freeSuspending(pending);
        const suspension = self.buildSuspension(pending, info, settings) catch |err| {
            log.err("session_host", "request {d} of {s} not held: {s}", .{ pending.id, self.id.asSlice(), @errorName(err) });
            self.mutex.lock();
            self.pending_request_id = 0;
            self.mutex.unlock();
            self.appendLine(wire.writeRequestClosed(self.gpa, pending.id, .cancelled));
            return;
        };
        self.persist();
        self.mutex.lock();
        self.suspension = suspension;
        self.pending_request_id = suspension.request_id;
        if (pending.answer) |json| {
            suspension.settled = .{ .answered = .{ .json = json, .by = pending.by } };
            pending.answer = null;
            pending.by = null;
        }
        // An interrupt during the Run cancels what it suspended on.
        if (self.run_interrupted) self.cancelSuspensionLocked(suspension, true);
        self.mutex.unlock();
        self.storeRequests() catch |err|
            log.warn("session_host", "suspended request {d} of {s} held in memory only, a restart loses it: {s}", .{ suspension.request_id, self.id.asSlice(), @errorName(err) });
    }

    fn buildSuspension(self: *HostedSession, pending: Suspending, info: agent_loop.SuspendInfo, settings: RunSettings) !*Suspension {
        const suspension = try self.newSuspension(pending.id, settings.max_turns);
        errdefer self.destroySuspension(suspension);
        const a = suspension.arena.allocator();
        suspension.announcement = try a.dupe(u8, pending.announcement);
        suspension.request = (try wire.parseRequest(a, suspension.announcement)).request;
        suspension.tool_use_id = try a.dupe(u8, info.tool_use_id);
        try self.turnResults(a, info, suspension);
        suspension.settings = .{
            .trace_id = if (settings.trace_id) |trace_id| try a.dupe(u8, trace_id) else null,
            .max_turns = settings.max_turns,
            .stream_retry_budget = settings.stream_retry_budget,
        };
        suspension.expires_at_ms = if (self.request_policy.timeout_ms) |ms| wallMs() +| @as(i64, @intCast(ms)) else null;
        return suspension;
    }

    /// The suspended call's tool, and a result for every other call of its
    /// turn, in the turn's order. The kernel keeps the results of the calls
    /// that ran beside the suspended one, not of those it denied or deferred
    /// (agent_loop's suspension), so a call without one gets a result that
    /// says it did not run: resumed, the turn answers every call.
    fn turnResults(self: *HostedSession, a: std.mem.Allocator, info: agent_loop.SuspendInfo, suspension: *Suspension) !void {
        var results: std.ArrayList(agent_loop.SuspendInfo.CompletedResult) = .empty;
        var lease = self.session.snapshotCommitted() catch {
            // Not reached after a Run returned; keep what the kernel kept.
            for (info.completed_results) |result| try results.append(a, try copyResult(a, result));
            suspension.completed = results.items;
            return;
        };
        defer lease.deinit();
        const messages = lease.conversation.messages.items;
        const turn = if (messages.len == 0) &[_]@import("message.zig").Block{} else messages[messages.len - 1].blocks;
        for (turn) |block| switch (block) {
            .tool_use => |call| {
                if (std.mem.eql(u8, call.id, info.tool_use_id)) {
                    suspension.tool_name = try a.dupe(u8, call.name);
                    continue;
                }
                for (info.completed_results) |result| {
                    if (std.mem.eql(u8, result.tool_use_id, call.id)) {
                        try results.append(a, try copyResult(a, result));
                        break;
                    }
                } else try results.append(a, .{
                    .tool_use_id = try a.dupe(u8, call.id),
                    .content = try tool_error.errorToJson("NotRun", "{s} did not run: its turn was suspended while another call waited for a person's answer", .{call.name}, a),
                    .is_error = true,
                });
            },
            else => {},
        };
        suspension.completed = results.items;
    }

    fn copyResult(a: std.mem.Allocator, result: agent_loop.SuspendInfo.CompletedResult) error{OutOfMemory}!agent_loop.SuspendInfo.CompletedResult {
        return .{
            .tool_use_id = try a.dupe(u8, result.tool_use_id),
            .content = try a.dupe(u8, result.content),
            .is_error = result.is_error,
        };
    }

    fn newSuspension(self: *HostedSession, request_id: u64, max_turns: u32) error{OutOfMemory}!*Suspension {
        const suspension = try self.gpa.create(Suspension);
        suspension.* = .{
            .arena = std.heap.ArenaAllocator.init(self.gpa),
            .request_id = request_id,
            .announcement = "",
            .request = .{ .custom = .{ .kind = "", .payload_json = "" } },
            .tool_use_id = "",
            .tool_name = "",
            .completed = &.{},
            .settings = .{ .max_turns = max_turns },
            .expires_at_ms = null,
        };
        return suspension;
    }

    fn destroySuspension(self: *HostedSession, suspension: *Suspension) void {
        switch (suspension.settled) {
            .answered => |answered| {
                self.gpa.free(answered.json);
                if (answered.by) |by| self.gpa.free(by);
            },
            .open, .cancelled => {},
        }
        suspension.arena.deinit();
        self.gpa.destroy(suspension);
    }

    /// Frees the request state nothing will use any more.
    fn dropRequests(self: *HostedSession) void {
        if (self.suspension) |suspension| self.destroySuspension(suspension);
        self.suspension = null;
        if (self.resuming) |resumed| self.destroySuspension(resumed);
        self.resuming = null;
        if (self.suspending) |pending| self.freeSuspending(pending);
        self.suspending = null;
        if (self.response_by) |by| self.gpa.free(by);
        self.response_by = null;
    }

    /// Writes the Session's request state (`ui_request_store`): the next
    /// request id and the suspension it holds, waiting (`suspension`) or
    /// being resumed (`resuming`), with how it was settled. Nothing without a
    /// Session directory. Only the driver writes, or `close` once the driver
    /// has stopped; `respond` and `interrupt` change memory alone.
    fn storeRequests(self: *HostedSession) !void {
        const dir = self.store_dir orelse return;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const state = try self.requestStateLocked(a);
        try ui_request_store.store(a, dir, state);
    }

    /// Takes `mutex`. The settlement's strings are copied: an interrupt may
    /// free them once the lock is gone. The rest of a Suspension is fixed
    /// once held and freed only by the driver, so it is borrowed.
    fn requestStateLocked(self: *HostedSession, a: std.mem.Allocator) error{OutOfMemory}!ui_request_store.State {
        self.mutex.lock();
        defer self.mutex.unlock();
        const held = self.suspension orelse self.resuming orelse return .{ .next_id = self.next_request_id };
        const completed = try a.alloc(ui_request_store.Result, held.completed.len);
        for (held.completed, completed) |result, *copy| copy.* = .{
            .tool_use_id = result.tool_use_id,
            .content = result.content,
            .is_error = result.is_error,
        };
        return .{ .next_id = self.next_request_id, .suspended = .{
            .kind = .answer,
            .id = held.request_id,
            .announcement = held.announcement,
            .tool_use_id = held.tool_use_id,
            .tool_name = held.tool_name,
            .completed = completed,
            .trace_id = held.settings.trace_id,
            .max_turns = held.settings.max_turns,
            .stream_retry_budget = held.settings.stream_retry_budget,
            .expires_at_ms = held.expires_at_ms,
            .settled = switch (held.settled) {
                .open => null,
                .answered => |answered| .{
                    .outcome = .answered,
                    .answer = try a.dupe(u8, answered.json),
                    .by = if (answered.by) |by| try a.dupe(u8, by) else null,
                },
                .cancelled => |cancelled| .{ .outcome = .cancelled, .stop = cancelled.stop },
            },
        } };
    }

    /// At `open`: what the Session's directory kept (#446). Ids go on from
    /// where they stopped, whatever the open. On a resumed Session the
    /// transcript is the witness: a call that already has its result there
    /// was resumed, and its record is only marked consumed, never applied
    /// again; a call still waiting is held again and its request announced
    /// under its id, and a settlement it had is applied once the driver
    /// starts. A fresh open drops it with the conversation it belonged to. A
    /// file this version cannot read is left in place (logged).
    fn restoreRequests(self: *HostedSession, mode: OpenMode, conversation: *const Conversation) void {
        const dir = self.store_dir orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const state = (ui_request_store.load(arena.allocator(), dir) catch |err| {
            log.err("session_host", "UI requests of {s} not read, the file is left in place: {s}", .{ self.id.asSlice(), @errorName(err) });
            return;
        }) orelse return;
        self.next_request_id = state.next_id;
        const record = state.suspended orelse return;
        if (mode == .@"resume") switch (callState(conversation, record.tool_use_id)) {
            .waiting => if (self.restoreSuspension(record)) |suspension| {
                self.suspension = suspension;
                self.pending_request_id = suspension.request_id;
                self.phase = .suspended;
                self.journal.append(suspension.announcement);
                return;
            } else |err| {
                // Out of memory may pass; anything else will not.
                if (err == error.OutOfMemory) {
                    log.err("session_host", "suspended request {d} of {s} not restored, the file is left in place: {s}", .{ record.id, self.id.asSlice(), @errorName(err) });
                    return;
                }
                log.err("session_host", "suspended request {d} of {s} unusable, dropped: {s}", .{ record.id, self.id.asSlice(), @errorName(err) });
            },
            .answered => log.info("session_host", "request {d} of {s} was resumed already: consumed", .{ record.id, self.id.asSlice() }),
            .absent => log.warn("session_host", "request {d} of {s} no longer matches its conversation: dropped", .{ record.id, self.id.asSlice() }),
        };
        self.storeRequests() catch |err|
            log.warn("session_host", "UI requests of {s} not rewritten: {s}", .{ self.id.asSlice(), @errorName(err) });
    }

    fn restoreSuspension(self: *HostedSession, record: ui_request_store.Suspended) !*Suspension {
        const suspension = try self.newSuspension(record.id, record.max_turns);
        errdefer self.destroySuspension(suspension);
        const a = suspension.arena.allocator();
        suspension.announcement = try a.dupe(u8, record.announcement);
        const announced = try wire.parseRequest(a, suspension.announcement);
        if (announced.id != record.id or announced.request == .permission) return error.SuspensionStale;
        suspension.request = announced.request;
        suspension.tool_use_id = try a.dupe(u8, record.tool_use_id);
        suspension.tool_name = try a.dupe(u8, record.tool_name);
        const completed = try a.alloc(agent_loop.SuspendInfo.CompletedResult, record.completed.len);
        for (record.completed, completed) |result, *copy| copy.* = .{
            .tool_use_id = try a.dupe(u8, result.tool_use_id),
            .content = try a.dupe(u8, result.content),
            .is_error = result.is_error,
        };
        suspension.completed = completed;
        suspension.settings = .{
            .trace_id = if (record.trace_id) |trace_id| try a.dupe(u8, trace_id) else null,
            .max_turns = record.max_turns,
            .stream_retry_budget = record.stream_retry_budget,
        };
        suspension.expires_at_ms = record.expires_at_ms;
        // `.re_announce`: the announcement this open makes is one.
        if (self.request_policy.expiry == .re_announce) {
            if (record.expires_at_ms) |deadline| {
                if (deadline <= wallMs()) suspension.expires_at_ms = if (self.request_policy.timeout_ms) |ms| wallMs() +| @as(i64, @intCast(ms)) else null;
            }
        }
        if (record.settled) |settled| switch (settled.outcome) {
            .answered => {
                const json = try self.gpa.dupe(u8, settled.answer orelse return error.SuspensionStale);
                errdefer self.gpa.free(json);
                const by = if (settled.by) |name| try self.gpa.dupe(u8, name) else null;
                suspension.settled = .{ .answered = .{ .json = json, .by = by } };
            },
            .cancelled => suspension.settled = .{ .cancelled = .{ .stop = settled.stop } },
        };
        return suspension;
    }

    /// While a Run is suspended (caller holds `mutex`): its resumption once
    /// its request is settled, a re-announcement once it expired under
    /// `.re_announce`; otherwise null, after waiting for either.
    fn suspendedWorkLocked(self: *HostedSession) ?*Work {
        const suspension = self.suspension orelse {
            // Not reached: `.suspended` always has one. Never spin on it.
            self.phase = .idle;
            return null;
        };
        if (suspension.settled == .open) {
            const deadline = suspension.expires_at_ms orelse {
                self.work_ready.wait(&self.mutex);
                return null;
            };
            const now = wallMs();
            if (now < deadline) {
                _ = self.work_ready.timedWait(&self.mutex, @intCast((deadline - now) * std.time.ns_per_ms));
                return null;
            }
            switch (self.request_policy.expiry) {
                .cancel => suspension.settled = .{ .cancelled = .{ .stop = false } },
                .interrupt => suspension.settled = .{ .cancelled = .{ .stop = true } },
                .re_announce => return self.driverWorkLocked(.re_announce),
            }
        }
        const work = self.driverWorkLocked(.{ .resumption = suspension }) orelse return null;
        self.phase = .running;
        self.run_interrupted = false;
        self.ui_released = false;
        self.run_returned = false;
        return work;
    }

    /// A Work item of the driver's own; null, after a short wait, when there
    /// is no memory for one. Caller holds `mutex`.
    fn driverWorkLocked(self: *HostedSession, item: @FieldType(Work, "item")) ?*Work {
        const work = self.newWork() catch {
            _ = self.work_ready.timedWait(&self.mutex, 50 * std.time.ns_per_ms);
            return null;
        };
        work.item = item;
        return work;
    }

    /// `.re_announce` on a suspended Run's request: the same line again and
    /// another `ui_request_timeout_ms`, recorded for a restart.
    fn reannounce(self: *HostedSession) void {
        self.mutex.lock();
        const suspension = self.suspension orelse {
            self.mutex.unlock();
            return;
        };
        const open = suspension.settled == .open;
        if (open) suspension.expires_at_ms = if (self.request_policy.timeout_ms) |ms| wallMs() +| @as(i64, @intCast(ms)) else null;
        self.mutex.unlock();
        if (!open) return;
        self.journal.append(suspension.announcement);
        self.storeRequests() catch |err|
            log.warn("session_host", "new expiry of request {d} of {s} not recorded: {s}", .{ suspension.request_id, self.id.asSlice(), @errorName(err) });
    }

    /// What the suspended call returns, and how its request closes.
    const Resumption = struct {
        closed: wire.RequestClosed,
        /// Who gave the answer the request closes on.
        by: ?[]const u8,
        /// Stop the resumed Run once the results are recorded.
        stop: bool,
        /// The suspended call's result first, then its siblings'.
        results: []agent_loop.SuspendInfo.CompletedResult,
    };

    /// The suspended call's result as an answered call would have returned
    /// it under `.block`: the question's answers as AskUserQuestion returns
    /// them, a custom UI's `result` as is (the kernel's suspension convention,
    /// doc/CORE_REFERENCE.md §5.3). Cancelled or unreadable, the call fails
    /// with InputAborted, the safe answer (`wire.cancelResponse`).
    fn prepareResumption(suspension: *const Suspension, settled: Suspension.Settled, a: std.mem.Allocator) !Resumption {
        var closed: wire.RequestClosed = .cancelled;
        var by: ?[]const u8 = null;
        var stop = false;
        var content: ?[]const u8 = null;
        switch (settled) {
            .open => return error.NotSettled,
            .cancelled => |cancelled| stop = cancelled.stop,
            .answered => |answered| {
                by = answered.by;
                closed = .malformed;
                var out: ui_request.UiResponse = undefined;
                const reading = wire.parseResponse(&suspension.request, answered.json, a, &out) catch |err| switch (err) {
                    error.InputAborted => wire.Reading.malformed,
                    error.OutOfMemory => return error.OutOfMemory,
                };
                if (reading == .answer) switch (out) {
                    .answers => |answers| {
                        content = try ask_user.answersResult(a, answers);
                        closed = .answered;
                    },
                    .custom => |result| {
                        content = result;
                        closed = .answered;
                    },
                    // A suspension is never a permission request.
                    .permission => {},
                };
            },
        }
        const results = try a.alloc(agent_loop.SuspendInfo.CompletedResult, suspension.completed.len + 1);
        results[0] = .{
            .tool_use_id = suspension.tool_use_id,
            .content = content orelse try tool_error.errorToJson("InputAborted", "{s} failed with {s}", .{ suspension.tool_name, "InputAborted" }, a),
            .is_error = content == null,
        };
        @memcpy(results[1..], suspension.completed);
        return .{ .closed = closed, .by = if (closed == .cancelled) null else by, .stop = stop, .results = results };
    }

    /// Resumes a suspended Run with how its request was settled: the request
    /// closes, then Run N+1 starts with `run_resumed` and continues the
    /// suspended turn under the suspended Run's settings
    /// (`AdmittedRun.resumeWithResults`). Exactly once, with the transcript
    /// as the witness: the settlement is recorded before it enters the
    /// conversation and stays recorded until the resumed Run's transcript
    /// holds the call's result. A crash before then applies it on the next
    /// open; after then, that open sees the result and only drops the
    /// record.
    fn runResumption(self: *HostedSession, suspension: *Suspension) void {
        if (builtin.is_test) if (testing_hooks.before_resumption) |hook| hook(self);
        // An interrupt that came since it was settled wins over an answer.
        self.mutex.lock();
        if (self.run_interrupted) self.cancelSuspensionLocked(suspension, true);
        const settled = suspension.settled;
        self.mutex.unlock();
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const prepared = prepareResumption(suspension, settled, scratch.allocator()) catch |err| {
            self.reopenSuspension(suspension, err);
            return;
        };
        self.mutex.lock();
        self.suspension = null;
        self.resuming = suspension;
        self.pending_request_id = 0;
        self.mutex.unlock();
        self.storeRequests() catch |err|
            log.warn("session_host", "settlement of request {d} of {s} not recorded; a crash before the resumed Run is written loses it: {s}", .{ suspension.request_id, self.id.asSlice(), @errorName(err) });
        self.appendLine(wire.writeRequestClosedBy(self.gpa, suspension.request_id, prepared.closed, prepared.by));

        self.last_run_id += 1;
        const context = wire.RunContext{ .run_id = self.last_run_id, .trace_id = suspension.settings.trace_id };
        self.emitHost(.{ .run_resumed = .{ .run_id = context.run_id, .trace_id = context.trace_id, .request_id = suspension.request_id } });
        var scope = RunScope{ .hosted = self, .context = context };
        self.session.awaitProviderCancelsDrained();
        var admitted = self.session.admitRun(context.run_id, scope.sink()) catch |err| {
            self.finishRun(context, null, err, null);
            self.finishResumption();
            return;
        };
        admitted.stream_retry_budget = suspension.settings.stream_retry_budget;
        // As in `runSubmission`: an interrupt or close since the resumption
        // was taken applies now, and so does an interrupt that settled it.
        self.mutex.lock();
        self.current_run_id = context.run_id;
        const stop_now = self.run_interrupted or self.closing or prepared.stop;
        self.mutex.unlock();
        if (stop_now) {
            self.session.abort(context.run_id, .user_interrupt) catch {};
            self.releaseUi();
        }
        const outcome = admitted.resumeWithResults(prepared.results, suspension.settings.max_turns);
        self.mutex.lock();
        self.current_run_id = 0;
        self.run_returned = true;
        self.mutex.unlock();
        self.settleRun(context, outcome, suspension.settings);
        self.finishResumption();
    }

    /// After a resumed Run, `finishRun` having written its transcript: when
    /// the committed conversation holds the call's result, the recorded
    /// settlement is spent and the record is rewritten without it (or with
    /// the suspension the Run was held on again). When it does not (the Run
    /// failed before the results entered it, or the Session is poisoned),
    /// the record keeps the settlement for the next open to apply.
    fn finishResumption(self: *HostedSession) void {
        self.mutex.lock();
        const resumed = self.resuming orelse {
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();
        const applied = blk: {
            var lease = self.session.snapshotCommitted() catch break :blk false;
            defer lease.deinit();
            break :blk callState(lease.conversation, resumed.tool_use_id) == .answered;
        };
        if (!applied) log.warn("session_host", "request {d} of {s}: the resumed Run did not record its result; the next open applies it", .{ resumed.request_id, self.id.asSlice() });
        self.mutex.lock();
        self.resuming = null;
        self.mutex.unlock();
        if (applied) self.storeRequests() catch |err|
            log.warn("session_host", "request {d} of {s} not marked consumed; the next open finds its result and drops it: {s}", .{ resumed.request_id, self.id.asSlice(), @errorName(err) });
        self.destroySuspension(resumed);
    }

    /// The resumption could not be applied: the request stays open for
    /// another answer, and any answer it took is dropped (logged).
    fn reopenSuspension(self: *HostedSession, suspension: *Suspension, err: anyerror) void {
        log.err("session_host", "request {d} of {s} not resumed, it stays open: {s}", .{ suspension.request_id, self.id.asSlice(), @errorName(err) });
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (suspension.settled) {
            .answered => |answered| {
                self.gpa.free(answered.json);
                if (answered.by) |by| self.gpa.free(by);
            },
            .open, .cancelled => {},
        }
        suspension.settled = .open;
        suspension.expires_at_ms = null;
        if (!self.closing) self.phase = .suspended;
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
        self.mutex.unlock();
        if (run_id != 0) {
            if (builtin.is_test) if (testing_hooks.before_abort) |hook| hook(self);
            self.session.abort(run_id, .user_interrupt) catch {};
        }
        // As in `interrupt`: the abort before the prompt's release.
        self.releaseUi();
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
        // A suspended Run outlives the Session (#446): what settled its
        // request but was not applied yet is kept for the next open.
        if (self.suspension) |suspension| {
            if (suspension.settled != .open) self.storeRequests() catch |err|
                log.err("session_host", "settled request {d} of {s} not recorded: {s}", .{ suspension.request_id, self.id.asSlice(), @errorName(err) });
        }
        self.dropRequests();

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
        self.capabilities.deinit(self.gpa);
        self.journal.deinit();
        self.ledger.deinit();
        if (self.submission_template) |template| self.gpa.free(template);
        self.gpa.free(self.model);
        self.gpa.destroy(self);
    }
};

fn typedFields(submission: Submission) typed_submission.Fields {
    return .{
        .text = submission.text,
        .source = submission.source,
        .kind = submission.kind,
        .idempotency_key = submission.idempotency_key,
        .attributes = submission.attributes,
        .replaces = if (submission.replaces) |position| position.ordinal() else null,
    };
}

/// Wall-clock milliseconds: idempotency keys and a suspended request's
/// expiry outlive the process.
fn wallMs() i64 {
    return @intCast(@divTrunc(util_time.nowWallNs(), std.time.ns_per_ms));
}

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

/// Where tool call `id` stands in `conversation` (#446): `answered` when a
/// message after the one that made it holds its result, `waiting` when the
/// call is in the last message and nothing answers it, `absent` otherwise.
const CallState = enum { waiting, answered, absent };

fn callState(conversation: *const Conversation, id: []const u8) CallState {
    const messages = conversation.messages.items;
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        const made = for (messages[index].blocks) |block| switch (block) {
            .tool_use => |call| if (std.mem.eql(u8, call.id, id)) break true,
            else => {},
        } else false;
        if (!made) continue;
        for (messages[index + 1 ..]) |later| {
            for (later.blocks) |block| switch (block) {
                .tool_result => |result| if (std.mem.eql(u8, result.tool_use_id, id)) return .answered,
                else => {},
            };
        }
        return if (index + 1 == messages.len) .waiting else .absent;
    }
    return .absent;
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
