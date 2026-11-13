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
//! With `Options.teammates`, the SessionHost also fulfils the lead's
//! `SpawnTeammate` requests, as the daemon's `App` starts its teammates
//! (#445): after each item the lead's driver takes the pending requests in
//! order, asks the Host's `TeammateFactory` for each member's configuration,
//! opens the member as another Session on the same host under the lead's team
//! identity and a fresh lease, and submits the request's prompt as its first
//! Run. Closing the lead closes the members it opened. A name whose member
//! the Host closed is opened again under a fresh lease, and a spawn that
//! fails becomes the lead's next Run, so its model learns of it; a failure
//! while fulfilling that report Run's own spawns is only logged.
//! `InheritLead` is the factory that configures each member like its lead.
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
const swarm_context = @import("../swarm/context.zig");
const swarm_team = @import("../swarm/team.zig");

/// How often an idle team lead's inbox, a locked file, is read: the bundled
/// daemon's `session_service.LeadMail.POLL_MS`.
pub const lead_inbox_poll_ms: u64 = 500;

/// The typed `source` and `kind` of the Run that reports a failed teammate
/// spawn to its lead. A failure while fulfilling such a Run's own spawns is
/// only logged, so reports never chain.
pub const spawn_failure_source = "session_host";
pub const spawn_failure_kind = "teammate_spawn_failed";

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
    /// Configures the member Sessions a hosted team lead's `SpawnTeammate`
    /// asks for; the SessionHost opens and runs them. Null leaves the
    /// requests pending, for the Host to fulfil itself.
    teammates: ?TeammateFactory = null,
    /// Flush each Session's transcript (`transcript.sessionDir` under its
    /// state root) after every Run and command, so `open(.resume)` restores
    /// it.
    transcripts: bool = true,
    /// How long a UI request waits for `respond`. Null waits until
    /// `interrupt` or `close`. An expired request is answered as cancelled.
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

pub const Phase = enum { idle, running, poisoned, closing };

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
pub const RespondError = error{ NoSuchRequest, OutOfMemory };
/// Test seam, read only in test builds: runs on the interrupting or closing
/// thread once the cancellation is decided and before the kernel abort is
/// requested - the window in which a released prompt used to let the Run take
/// another turn.
pub const testing_hooks = struct {
    pub var before_abort: ?*const fn (*HostedSession) void = null;
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
    messages: usize,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.model);
        self.* = undefined;
    }
};

/// A teammate a hosted lead asked for. Borrowed for `TeammateFactory.configure`.
pub const TeammateSpawn = struct {
    /// The lead Session that asked.
    lead: SessionId,
    /// The lead's team (sanitized).
    team_name: []const u8,
    /// The member's sanitized name; never "team-lead".
    name: []const u8,
    /// The member's first Run, submitted once it is open.
    prompt: []const u8,
    /// As the lead model passed them; the factory decides what they mean.
    agent_type: ?[]const u8,
    effort: ?[]const u8,
    /// The lead's settings when it asked, after every command its queue ran
    /// before (`set_model`, `set_permission_mode`, `set_reasoning_effort`):
    /// what the bundled daemon's `App` teammates inherit from their lead.
    lead_model: []const u8,
    lead_permission_mode: types.PermissionMode,
    lead_reasoning_effort: ?types.ReasoningEffort,
};

/// How the Host configures a member Session (#445). The SessionHost owns the
/// team identity: `configure` returns `team = null`, and the member joins
/// `spawn.team_name` as `spawn.name` under the lead's session id and a fresh
/// lease. Provider, workspace, tools and permissions are the Host's choice,
/// as for any Session it opens. The returned configuration may borrow from
/// `arena`, which lives until the member is open. Runs on the lead's driver
/// thread, so two leads may call it at once; an error drops the request,
/// reports it to the lead as its next Run (unless the Run that asked was
/// itself such a report) and leaves the lead running.
pub const TeammateFactory = struct {
    ctx: *anyopaque,
    configure: *const fn (ctx: *anyopaque, arena: std.mem.Allocator, spawn: TeammateSpawn) anyerror!SessionConfig,
};

/// The `TeammateFactory` that configures each member like its lead, as the
/// bundled daemon's `App` starts its teammates with the lead's provider,
/// model and permission context (#445). A member gets `base` (the
/// configuration the Host opens its leads with: provider, credentials,
/// workspace, tools, permission rules) with the lead's current model and
/// permission mode, and the spawn's `effort` or else the lead's reasoning
/// effort. `agent_type` is not interpreted.
pub const InheritLead = struct {
    /// Borrowed; outlives the SessionHost. Its `team` and UI requesters are
    /// not used.
    base: SessionConfig,

    pub fn factory(self: *InheritLead) TeammateFactory {
        return .{ .ctx = self, .configure = configure };
    }

    /// `base` as the member of the lead `spawn` describes. Borrows from
    /// both.
    pub fn derive(base: SessionConfig, spawn: TeammateSpawn) error{InvalidTeammateEffort}!SessionConfig {
        var config = base;
        config.team = null;
        config.ui_requester = null;
        config.run_ui_requester = null;
        config.model = spawn.lead_model;
        config.permission_mode = spawn.lead_permission_mode;
        config.reasoning_effort = if (spawn.effort) |name|
            std.meta.stringToEnum(types.ReasoningEffort, name) orelse return error.InvalidTeammateEffort
        else
            spawn.lead_reasoning_effort;
        return config;
    }

    fn configure(ctx: *anyopaque, arena: std.mem.Allocator, spawn: TeammateSpawn) anyerror!SessionConfig {
        const self: *InheritLead = @ptrCast(@alignCast(ctx));
        var config = try derive(self.base, spawn);
        // `spawn` is borrowed for this call only.
        config.model = try arena.dupe(u8, spawn.lead_model);
        return config;
    }
};

test "InheritLead.derive: the lead's model, mode and effort over the base; the spawn's effort wins; no team" {
    const base: SessionConfig = .{
        .provider_kind = .anthropic,
        .api_key = "k",
        .model = "base-model",
        .permission_mode = .default,
        .reasoning_effort = .low,
        .workspace = .{ .root = "/w" },
        .allowed_tools = &.{"Read"},
        .team = .{ .role = .lead, .team_name = "crew" },
    };
    var spawn: TeammateSpawn = .{
        .lead = session_id_mod.gen(),
        .team_name = "crew",
        .name = "solver",
        .prompt = "p",
        .agent_type = null,
        .effort = null,
        .lead_model = "lead-model",
        .lead_permission_mode = .accept_edits,
        .lead_reasoning_effort = .high,
    };
    const inherited = try InheritLead.derive(base, spawn);
    try std.testing.expectEqualStrings("lead-model", inherited.model);
    try std.testing.expectEqual(types.PermissionMode.accept_edits, inherited.permission_mode);
    try std.testing.expectEqual(types.ReasoningEffort.high, inherited.reasoning_effort.?);
    try std.testing.expect(inherited.team == null);
    try std.testing.expectEqualStrings("/w", inherited.workspace.root);
    try std.testing.expectEqualStrings("Read", inherited.allowed_tools[0]);

    spawn.effort = "minimal";
    try std.testing.expectEqual(types.ReasoningEffort.minimal, (try InheritLead.derive(base, spawn)).reasoning_effort.?);
    spawn.lead_reasoning_effort = null;
    spawn.effort = null;
    try std.testing.expect((try InheritLead.derive(base, spawn)).reasoning_effort == null);
    spawn.effort = "loud";
    try std.testing.expectError(error.InvalidTeammateEffort, InheritLead.derive(base, spawn));
}

/// A member Session a lead's driver opened, closed with the lead. `lease` is
/// the roster identity it joined under.
const Teammate = struct {
    name: []u8,
    id: SessionId,
    lease: SessionId,
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
    /// Members this lead opened (`Options.teammates`); names owned by `gpa`.
    /// Driver-only until the driver is joined, then `shutdown` closes them.
    teammates: std.ArrayList(Teammate) = .empty,

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
            self.fulfilSpawns(!isSpawnFailureReport(work));
        }
    }

    fn nextWork(self: *HostedSession) ?*Work {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
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

    /// Opens a member Session for each `SpawnTeammate` request the lead's
    /// last Run made, oldest first, and submits its prompt. A name this lead
    /// already opened and the Host has not closed takes the prompt as its
    /// next Run instead. A request that fails is reported to the lead as its
    /// next Run (`reportSpawnFailure`) when `report_failures`; otherwise it is
    /// only logged. Driver-only: the requests live in the lead's
    /// `SwarmContext`.
    fn fulfilSpawns(self: *HostedSession, report_failures: bool) void {
        const factory = self.host.options.teammates orelse return;
        if (!self.leadsTeam()) return;
        const swarm = &self.session.swarm.?;
        while (self.admitsSpawns()) {
            const request = swarm.popPendingSpawn() orelse return;
            var owned = request;
            defer owned.deinit(swarm.allocator);
            var target: SpawnTarget = .new_member;
            self.spawnTeammate(factory, swarm, &owned, &target) catch |err| {
                log.warn("session_host", "teammate {s} of {s} not started: {s}", .{ owned.name, self.id.asSlice(), @errorName(err) });
                if (report_failures) self.reportSpawnFailure(owned.name, target, err);
            };
        }
    }

    /// Whether a spawn request went to an open member or a new one.
    const SpawnTarget = enum { new_member, open_member };

    /// True for the Run `reportSpawnFailure` queued. A failure while
    /// fulfilling that Run's own spawns is only logged: under the `App` a
    /// failed spawn is a tool result inside the same Run, bounded by its turn
    /// limit, while here each report is a new Run, so a model that keeps
    /// asking for a name that cannot start would otherwise loop without end.
    fn isSpawnFailureReport(work: *const Work) bool {
        const submission = switch (work.item) {
            .submission => |submission| submission,
            .command => return false,
        };
        const source = submission.source orelse return false;
        const kind = submission.kind orelse return false;
        return std.mem.eql(u8, source, spawn_failure_source) and std.mem.eql(u8, kind, spawn_failure_kind);
    }

    fn spawnTeammate(
        self: *HostedSession,
        factory: TeammateFactory,
        swarm: *const swarm_context.SwarmContext,
        request: *const swarm_context.SpawnRequest,
        target: *SpawnTarget,
    ) !void {
        for (self.teammates.items, 0..) |known, index| {
            if (!std.mem.eql(u8, known.name, request.name)) continue;
            if (self.host.acquire(known.id)) |member| {
                defer member.release();
                target.* = .open_member;
                return member.submit(.{ .text = request.prompt });
            }
            // The Host closed it, but its roster entry still holds the old
            // lease, under which no member may join again. Drop that entry
            // (only while it is still the one this lead opened) and open the
            // name anew under a fresh lease, so mail from the closed member
            // stays unaddressed, as the `App` reaps a terminated teammate.
            var config_buf: [std.fs.max_path_bytes]u8 = undefined;
            const config_path = swarm_team.configPath(swarm.state_root, swarm.team_sanitized, &config_buf);
            _ = swarm_tools.removeMemberFromConfig(self.gpa, config_path, known.name, swarm.session.asSlice(), known.lease.asSlice());
            self.gpa.free(known.name);
            _ = self.teammates.swapRemove(index);
            break;
        }

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var config = try factory.configure(factory.ctx, arena.allocator(), .{
            .lead = self.id,
            .team_name = swarm.team_sanitized,
            .name = request.name,
            .prompt = request.prompt,
            .agent_type = request.agent_type,
            .effort = request.effort,
            .lead_model = self.model,
            .lead_permission_mode = self.session.permission_ctx.modeValue(),
            .lead_reasoning_effort = self.reasoning_effort,
        });
        if (config.team != null) return error.TeammateTeamConfigNotAllowed;
        const lease = session_id_mod.gen();
        config.team = .{
            .role = .member,
            .team_name = swarm.team_sanitized,
            .member_name = request.name,
            .lead_session_id = swarm.session.asSlice(),
            .member_lease = lease.asSlice(),
        };
        // Room first, so an opened member is always one the lead will close.
        try self.teammates.ensureUnusedCapacity(self.gpa, 1);
        const name = try self.gpa.dupe(u8, request.name);
        errdefer self.gpa.free(name);
        const member = try self.host.open(.{ .config = config });
        defer member.release();
        self.teammates.appendAssumeCapacity(.{ .name = name, .id = member.id, .lease = lease });
        try member.submit(.{ .text = request.prompt });
    }

    /// Tells the lead model that teammate `name` was not started (or, when
    /// it was already open, did not take the prompt), as the lead's next Run,
    /// in the `teammate-status` form its inbox uses for a failed teammate;
    /// under the `App` the same failure is the spawn tool's result. The Run's
    /// `user_message` is typed (`spawn_failure_source`,
    /// `spawn_failure_kind`); the provider sees only the text.
    fn reportSpawnFailure(self: *HostedSession, name: []const u8, target: SpawnTarget, err: anyerror) void {
        const work = self.newWork() catch return;
        const what = switch (target) {
            .new_member => "teammate was not started",
            .open_member => "teammate did not take the prompt",
        };
        const text = std.fmt.allocPrint(
            work.arena.allocator(),
            "<teammate-status from=\"{s}\" state=\"failed\">{s}: {s}</teammate-status>",
            .{ name, what, @errorName(err) },
        ) catch {
            self.freeWork(work);
            return;
        };
        work.item = .{ .submission = .{ .text = text, .source = spawn_failure_source, .kind = spawn_failure_kind } };
        self.enqueue(work) catch |enqueue_err| {
            log.warn("session_host", "spawn failure of {s} not reported to {s}: {s}", .{ name, self.id.asSlice(), @errorName(enqueue_err) });
            self.freeWork(work);
        };
    }

    /// A closing lead starts no member, and neither does a poisoned one: it
    /// could never take the member's reply.
    fn admitsSpawns(self: *HostedSession) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return !self.closing and self.phase != .poisoned;
    }

    /// Closes the members this lead opened; after the driver is joined.
    fn closeTeammates(self: *HostedSession) void {
        for (self.teammates.items) |member| {
            // Already closed by the Host: nothing to do.
            self.host.close(member.id) catch {};
            self.gpa.free(member.name);
        }
        self.teammates.deinit(self.gpa);
        self.teammates = .empty;
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
        if (outcome) |result| {
            if (result.suspend_info) |info| info.deinit();
            const failed_on_model = result.stop_reason == .api_error or result.stop_reason == .max_tokens_exhausted;
            const model_failure = if (failed_on_model) &self.session.last_model_error else null;
            self.finishRun(context, @tagName(result.stop_reason), null, model_failure);
        } else |err| {
            self.finishRun(context, null, err, null);
        }
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
            self.phase = .idle;
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

        self.mutex.lock();
        // Released means the abort is in force. An interrupt still on its way
        // to the kernel lets the prompt be announced and wait for it.
        if (self.ui_released) {
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
        while (self.response == null and !self.ui_released) {
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
        self.closeTeammates();
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

/// Wall-clock milliseconds: idempotency keys outlive the process.
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
