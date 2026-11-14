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
//! A submission may carry that model and permission mode itself (#445), as
//! the bundled daemon's message does; a refusal of either applies neither
//! and is journaled as `message_rejected` instead of a Run. With
//! `Options.models` a model name resolves as on the daemon: tier names,
//! then the provider guard (`ModelPolicy`). Every change of model, permission
//! mode, reasoning effort or additional directory is journaled as
//! `config_changed`, as the daemon's config sink journals it: a command's
//! before its `command_result`, a submission's before its `user_message`.
//! `interrupt` is the one cross-thread call into the kernel; its abort is
//! built for that.
//!
//! A team lead (`SessionConfig.team` with the lead role, once its team
//! exists) is fed its inbox the way the bundled daemon feeds an `App` lead
//! (#277, #445): while its queue is empty the driver reads the lead inbox at
//! most every `lead_inbox_poll_ms`, and a teammate's reply becomes the lead's
//! next Run, queued behind the work already there.
//!
//! A Session that selected the cron tools (`RuntimeConfig.enable_cron`) has
//! its scheduled prompts fired by its driver (#445), as the CLI fires them
//! when it is back at the prompt: while the queue is empty and the Session has
//! cron jobs, the driver checks them at most every `cron_poll_ms`, and each
//! prompt due becomes a Run typed `cron_source`/`cron_kind`, in the order the
//! jobs were created. A job never fires during a Run or ahead of queued work.
//! Jobs live with the AgentSession: closing it drops them. Fired prompts
//! count against `max_queued` (#493): the driver takes only as many as the
//! queue has room for, and a job left out stays due and fires once there is
//! room, so `Snapshot.queued` never passes the bound and no prompt is lost.
//! The lead's inbox is read under the same bound. A Host sees the jobs in
//! `Snapshot.cron_jobs` and removes them without a Run through
//! `Command.cancel_cron_job` and `cancel_all_cron_jobs`.
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
const model_tiers = @import("../api/model_tiers.zig");
const model_availability = @import("../api/model_availability.zig");
const model_name = @import("../api/model_name.zig");
const permission_mode = @import("../permission/mode.zig");
const util_time = @import("../util/time.zig");
const log = @import("../util/log.zig");
const swarm_tools = @import("../swarm/tools.zig");
const swarm_context = @import("../swarm/context.zig");
const swarm_team = @import("../swarm/team.zig");
const cron_registry = @import("cron_registry.zig");

/// A cron job's id (#493), as `CronCreate` returned it to the model and
/// `Snapshot.cron_jobs` reports it. `CronJobId.parse` takes a Host's text.
pub const CronJobId = cron_registry.JobId;
/// A cron job as `Snapshot.cron_jobs` reports it (#493).
pub const CronJob = cron_registry.JobView;
/// `CronJob.schedule`: `.once`, or `.recurring` with its cron expression.
pub const CronSchedule = cron_registry.Schedule;

/// How often an idle team lead's inbox, a locked file, is read: the bundled
/// daemon's `session_service.LeadMail.POLL_MS`.
pub const lead_inbox_poll_ms: u64 = 500;

/// The typed `source` and `kind` of the Run that reports a failed teammate
/// spawn to its lead. A failure while fulfilling such a Run's own spawns is
/// only logged, so reports never chain.
pub const spawn_failure_source = "session_host";
pub const spawn_failure_kind = "teammate_spawn_failed";

/// How often an idle Session with cron jobs checks which are due (#445).
/// Cron expressions name minutes and `delaySeconds` seconds, so a check a
/// second keeps a prompt at most that late.
pub const cron_poll_ms: u64 = 1000;

/// The typed `source` and `kind` of a Run a cron job fired (#445). Neither
/// reaches the provider without a submission template: the Run's user
/// message is the job's prompt, as when the CLI fires it.
pub const cron_source = "session_host";
pub const cron_kind = "cron_fired";

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
    /// How a question or custom UI request waits for its answer: holding the
    /// driver (`.block`, as before #446) or as a suspended Run that survives
    /// `close` (`.suspend`, which needs `transcripts`). A permission request
    /// always blocks.
    ui_request_wait: UiRequestWait = .block,
    /// What a request `ui_request_timeout_ms` leaves unanswered gets.
    ui_request_expiry: UiRequestExpiry = .cancel,
    /// How long a UI request waits for `respond`. Null waits until
    /// `interrupt` or `close`. An expired request gets `ui_request_expiry`;
    /// a permission prompt it closes is denied, and the model reads that
    /// nobody answered in time (doc/WIRE_PROTOCOL.md §1.4). The value never
    /// reaches the model.
    ui_request_timeout_ms: ?u64 = null,
    /// How long after its Run started an idempotency key still makes a
    /// delivery a duplicate. With `transcripts`, the keys outlive the Host:
    /// a Session opened again under its id (resumed or fresh) keeps them.
    idempotency_retention_ms: u64 = 24 * std.time.ms_per_hour,
    /// Started idempotency keys kept per Session; beyond it the oldest is
    /// forgotten first.
    idempotency_max_keys: usize = 10_000,
    /// How a model name in `Submission.model` or `Command.set_model` becomes
    /// the model a Session switches to (#445). Null takes the name as it is,
    /// for the Session's own check (`InvalidModel`) and its provider.
    models: ?ModelPolicy = null,
};

/// The bundled daemon's model resolution (`SessionService.setTurnModel`,
/// api/model_availability.zig), for a Host that offers it (#445). A name is
/// trimmed, a tier name (`low`/`mid`/`high`, or `haiku`/`sonnet`/`opus`)
/// resolves through `tiers`' entry for the Session's provider kind, and the
/// result must be one the provider takes: one `catalog` lists for it, or
/// one whose id names it (`claude-`, `gpt`/`o1`/`o3`, `gemini`). Anything
/// else, an unset tier included, is `error.ModelUnavailable` and changes
/// nothing. A tier's reasoning effort is not applied, as on the daemon.
pub const ModelPolicy = struct {
    /// Borrowed; outlives the SessionHost.
    tiers: ?*const model_tiers.TierTable = null,
    /// Borrowed; outlives the SessionHost.
    catalog: []const CatalogModel = &.{},
};

/// A model a provider's catalog lists (`ModelPolicy.catalog`).
pub const CatalogModel = struct {
    provider: types.ProviderKind,
    id: []const u8,
};

/// Why a model switch through the SessionHost failed.
pub const ModelChangeError = agent_session.ModelMutationError || error{
    /// `Options.models` refused the name: an unset tier, or a model the
    /// Session's provider does not take.
    ModelUnavailable,
};

/// Why a submission was `message_rejected`.
pub const SubmissionRefusal = ModelChangeError || agent_session.PermissionModeMutationError;

/// The model `requested` names under `policy`, for a Session of `provider`;
/// borrowed from `requested` or the tier table.
fn resolveModel(policy: ModelPolicy, provider: types.ProviderKind, requested: []const u8) error{ModelUnavailable}![]const u8 {
    const tiers = if (policy.tiers) |table| table.forKind(provider) else null;
    const model = model_availability.resolveTierName(tiers, requested);
    const listed = for (policy.catalog) |entry| {
        if (entry.provider == provider and model_name.eqlIgnoreCase(entry.id, model)) break true;
    } else false;
    if (!model_availability.available(provider, listed, model)) return error.ModelUnavailable;
    return model;
}

/// `message_rejected.message`: why, in words, as the bundled daemon says it
/// where the two refuse alike. `mode` is the submission's own.
fn refusalReason(err: SubmissionRefusal, mode: ?types.PermissionMode) []const u8 {
    return switch (err) {
        error.PermissionModeDisabled => permission_mode.disabledReason(mode orelse .default),
        error.ModelUnavailable => model_availability.unavailable_reason,
        error.InvalidModel => "model name is empty or not valid UTF-8",
        error.SessionBusy => "session is busy",
        error.InvalidSessionState => "session can no longer take changes",
        error.OutOfMemory => "out of memory",
    };
}

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
    /// submit under a new key. A submission `message_rejected` refused
    /// started no Run and does not spend its key. `model` and
    /// `permission_mode` are not part of what a key compares.
    idempotency_key: ?[]const u8 = null,
    /// The Session's model and permission mode from this Run on (#445), as
    /// the bundled daemon's `POST /message` takes them: applied by the
    /// driver just before the Run, as `set_model` then `set_permission_mode`
    /// queued right ahead of it would be, each journaled as `config_changed`
    /// as the daemon journals them. The model resolves through
    /// `Options.models`. The mode is checked first, so a refusal of either
    /// changes nothing; then `message_rejected` takes the place of
    /// `user_message`, saying why in words, the text stays out of the
    /// conversation and no Run starts. Null leaves the setting as it is.
    model: ?[]const u8 = null,
    permission_mode: ?types.PermissionMode = null,
};

/// A configuration change applied by the driver between Runs, in queue
/// order. Borrowed for `HostedSession.command`, which copies it. Each is
/// answered by `command_result`. An accepted `set_model`,
/// `set_permission_mode` or `set_reasoning_effort` is first journaled as
/// `config_changed` (`model` as resolved, `mode`, `reasoning`, null
/// included), also when the value was already in force, as the bundled
/// daemon's `/model`, `/mode` and `/effort` are (#445).
/// `set_additional_directories` journals `config_changed{dirs}` for each
/// directory in force afterwards that was not before, its resolved path, as
/// the daemon's `/add-dir` does; a directory taken away has no line.
///
/// `cancel_cron_job` and `cancel_all_cron_jobs` (#493) remove the Session's
/// cron jobs without a Run, so they never fire again; a prompt one of them
/// already fired, queued, still runs. An id the Session does not have is
/// `command_result{ok:false, error_name:"CronJobNotFound"}`; cancelling all
/// of none succeeds. `Snapshot.cron_jobs` shows the result once the
/// `command_result` is journaled.
pub const Command = union(enum) {
    set_model: []const u8,
    set_permission_mode: types.PermissionMode,
    set_reasoning_effort: ?types.ReasoningEffort,
    set_additional_directories: []const []const u8,
    set_prompt_profile: prompt_sections.Profile,
    update_permission_rules: permission_settings.RuleSetInput,
    compact,
    cancel_cron_job: CronJobId,
    cancel_all_cron_jobs,
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
    /// On the driver, while a Run that suspended is being held, after the
    /// transcript is written and before the suspension is registered
    /// (#446): an answer that arrives then must still reach the request.
    pub var before_handover: ?*const fn (*HostedSession) void = null;
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
    /// The default, as before #446: the request closes `"cancelled"` and the
    /// Run goes on without the answer. A permission prompt is denied, and
    /// the model reads that nobody answered in time; a question or a custom
    /// UI fails with `InputAborted` (doc/WIRE_PROTOCOL.md §1.4).
    cancel,
    /// As `cancel`, and the Run stops there, as after `interrupt`, instead of
    /// going on without the answer. A permission prompt still reads as
    /// unanswered in time, not as interrupted: nobody stopped the prompt.
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

/// What a Host reports about a Session (e.g. as `/state`). `model` and
/// `cron_jobs` are owned by the allocator given to `snapshot`.
pub const Snapshot = struct {
    id: SessionId,
    phase: Phase,
    model: []const u8,
    permission_mode: types.PermissionMode,
    reasoning_effort: ?types.ReasoningEffort,
    /// Submissions and commands waiting, and the bound (`Options.max_queued`)
    /// at which `submit` and `command` refuse with `error.QueueFull`. Runs
    /// fired by cron jobs and the team lead's inbox count too (#493), and
    /// never take `queued` past the bound: a cron prompt that does not fit
    /// stays due and fires once the queue has room.
    queued: usize,
    max_queued: usize,
    /// The Session's cron jobs (#493), oldest first: id, next fire time
    /// (unix seconds) and whether each repeats. As of the last time the
    /// Session was between Runs: a job a Run creates or deletes shows from
    /// that Run's `run_done` on, a cancel command's from its
    /// `command_result`, and a one-shot job is gone once it fired. Empty for
    /// a Session without cron tools, and once it is closed.
    cron_jobs: []const CronJob,
    seq: usize,
    epoch: [16]u8,
    /// The UI request the Session waits on, 0 for none: the one the Run in
    /// progress blocks on (a permission request always blocks), else the
    /// question or custom UI request a Run suspended on (#446). Beside a
    /// suspended or suspending question a permission request takes its own
    /// id, shown here while it blocks; `respond` takes an answer only for
    /// the request it names.
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
        cron_registry.freeViews(allocator, self.cron_jobs);
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
        // A suspended request lives in the Session's directory.
        if (self.options.ui_request_wait == .@"suspend" and !self.options.transcripts) return error.SuspendRequiresTranscripts;
        // `.re_announce` with no period would announce without ever waiting.
        if (self.options.ui_request_expiry == .re_announce and (self.options.ui_request_timeout_ms orelse 1) == 0) return error.InvalidUiRequestTimeout;
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
            .provider_kind = spec.config.provider_kind,
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
        // Before the driver exists, so every mode change it makes is seen.
        session.permission_ctx.event_sink = hosted.configSink();
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
        hosted.driver = try @import("platform").thread.spawn(.full, HostedSession.driverMain, .{hosted});
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
    /// Its `ui_request` line, once built; the id and its owner are
    /// registered together, before it.
    announcement: ?[]u8 = null,
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
    /// The submission's idempotency key (#447): while its Run is suspended
    /// or resuming, a delivery under it is a duplicate, however old the
    /// key's ledger entry is.
    idempotency_key: ?[]const u8 = null,
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
    /// The Session's provider kind, which `setModel` keeps:
    /// `Options.models` resolves names for it.
    provider_kind: types.ProviderKind,

    /// One UI request at a time; a second (from a parallel tool) waits.
    ui_serial: sync.Mutex = .{},
    /// The request the Run in progress blocks on, under `mutex`; `response`
    /// is its answer. A suspending or suspended request is not one: it has
    /// its own id (`suspending`, `suspension`).
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
    /// The request file there could not be read: it is left as it is,
    /// never written over, and requests block instead of suspending.
    store_unwritable: bool = false,
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
    /// Queue slots the driver holds for Runs it is taking from the cron
    /// jobs or the lead's inbox with `mutex` released (#493): `submit` and
    /// `command` count them against `max_queued`, so what the driver then
    /// appends always fits. Under `mutex`.
    reserved: usize = 0,
    /// The Session's cron jobs as of the last time it was between Runs
    /// (#493), owned by `gpa`; under `mutex`, written by the driver
    /// (`refreshCronJobs`) and emptied once the AgentSession is destroyed.
    cron_jobs: []const CronJob = &.{},
    /// `OpenSpec.submission_template`, owned.
    submission_template: ?[]u8 = null,
    /// Idempotency keys (#447): entries under `mutex`, the file the driver's.
    ledger: idempotency_ledger.Ledger,

    // Driver-only.
    last_run_id: u64 = 0,
    last_compact_id: u64 = 0,
    /// When an idle team lead's inbox is read next (`util_time.nowNs`).
    next_lead_poll_ns: i128 = 0,
    /// When an idle Session with cron jobs checks them next.
    next_cron_poll_ns: i128 = 0,
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
            .model = if (submission.model) |model| try a.dupe(u8, model) else null,
            .permission_mode = submission.permission_mode,
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
            // The ledger lets a key go after its retention; a suspended
            // Run's key is held until the Run ends all the same (#446).
            .new => if (self.heldKeyLocked(key)) return error.DuplicateSubmission,
            .duplicate => return error.DuplicateSubmission,
            .reused => return error.IdempotencyKeyReused,
        }
        if (self.roomLocked() == 0) return error.QueueFull;
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
        if (self.roomLocked() == 0) return error.QueueFull;
        try self.queue.append(self.gpa, work);
        self.work_ready.signal();
    }

    /// Queue slots still free under `max_queued`, after those the driver
    /// holds (`reserved`). Caller holds `mutex`.
    fn roomLocked(self: *const HostedSession) usize {
        return self.max_queued -| (self.queue.items.len + self.reserved);
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
        if (request_id == 0 or self.closing) return error.NoSuchRequest;
        // Each open request takes the answers given under its own id, and
        // only those.
        if (self.suspension) |suspension| {
            if (suspension.request_id == request_id) {
                switch (suspension.settled) {
                    .open => {},
                    .answered => return error.AlreadyAnswered,
                    .cancelled => return error.NoSuchRequest,
                }
                suspension.settled = .{ .answered = .{ .json = owned, .by = by } };
                self.work_ready.signal();
                return;
            }
        }
        if (self.suspending) |*pending| {
            if (pending.id == request_id) {
                // Before its Run has suspended: applied once it has.
                if (self.run_interrupted) return error.NoSuchRequest;
                if (pending.answer != null) return error.AlreadyAnswered;
                pending.answer = owned;
                pending.by = by;
                return;
            }
        }
        if (self.pending_request_id == 0 or self.pending_request_id != request_id or self.run_interrupted) return error.NoSuchRequest;
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
        const model = try allocator.dupe(u8, self.model);
        errdefer allocator.free(model);
        return .{
            .id = self.id,
            .phase = self.phase,
            .model = model,
            .cron_jobs = try cron_registry.dupeViews(allocator, self.cron_jobs),
            // `closing` is set under this lock before the kernel Session is
            // destroyed, so a live read here cannot race the destroy.
            .permission_mode = if (self.closing) self.final_permission_mode else self.session.permission_ctx.modeValue(),
            .reasoning_effort = self.reasoning_effort,
            .queued = self.queue.items.len,
            .max_queued = self.max_queued,
            .seq = self.journal.count(),
            .epoch = self.journal.epochHex(),
            .pending_request_id = self.pendingIdLocked(),
            .queue_waiting = if (self.queue.items.len == 0)
                .none
            else if (self.pendingIdLocked() != 0)
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
            self.fulfilSpawns(!isSpawnFailureReport(work));
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
            // Idle: what fires by itself is checked on its own clock, and
            // the driver sleeps until the earlier of the two is due.
            const now = util_time.nowNs();
            var wake_at: ?i128 = null;
            if (self.session.cronJobCount() > 0) {
                if (now >= self.next_cron_poll_ns) {
                    self.next_cron_poll_ns = now + @as(i128, cron_poll_ms) * std.time.ns_per_ms;
                    // Fired prompts count against `max_queued` (#493): take
                    // only as many as the queue has room for, holding those
                    // slots while the lock is released; a job left out stays
                    // due for a later poll. The registry changes only on
                    // this thread, so the count read here is still due when
                    // the prompts are taken.
                    const slots = @min(self.roomLocked(), self.session.cronDueCount());
                    if (slots == 0) continue;
                    self.reserved += slots;
                    var fired: std.ArrayList(*Work) = .empty;
                    defer fired.deinit(self.gpa);
                    // `takeDueCronPrompts` takes the AgentSession's lock.
                    self.mutex.unlock();
                    self.takeDueCron(&fired, slots);
                    self.refreshCronJobs();
                    self.mutex.lock();
                    self.reserved -= slots;
                    std.debug.assert(fired.items.len <= slots);
                    for (fired.items) |work| self.queue.append(self.gpa, work) catch {
                        log.warn("session_host", "dropped a cron prompt for {s} (OOM)", .{self.id.asSlice()});
                        self.freeWork(work);
                    };
                    continue;
                }
                wake_at = self.next_cron_poll_ns;
            }
            if (self.leadsTeam()) {
                if (now >= self.next_lead_poll_ns) {
                    self.next_lead_poll_ns = now + @as(i128, lead_inbox_poll_ms) * std.time.ns_per_ms;
                    // A reply is a Run like any other (#493): read only
                    // with a slot held for it, so it never takes the queue
                    // past `max_queued`; unread mail waits in the inbox.
                    if (self.roomLocked() == 0) continue;
                    self.reserved += 1;
                    // The inbox is a locked file: read it without holding the Session.
                    self.mutex.unlock();
                    const mail = self.takeLeadMail();
                    self.mutex.lock();
                    self.reserved -= 1;
                    if (mail) |work| self.queue.append(self.gpa, work) catch {
                        log.warn("session_host", "dropped teammate mail for {s} (OOM)", .{self.id.asSlice()});
                        self.freeWork(work);
                    };
                    continue;
                }
                wake_at = if (wake_at) |at| @min(at, self.next_lead_poll_ns) else self.next_lead_poll_ns;
            }
            if (wake_at) |at| {
                _ = self.work_ready.timedWait(&self.mutex, @intCast(at - now));
            } else {
                self.work_ready.wait(&self.mutex);
            }
        }
    }

    /// Appends a submission to `fired` for each cron prompt due now, in the
    /// order the jobs were created (`AgentSession.takeDueCronPrompts`). Each
    /// is typed `cron_source`/`cron_kind`; its text is the prompt, byte for
    /// byte. At most `limit`: the jobs past it stay due. Driver-only, while
    /// the Session is idle.
    fn takeDueCron(self: *HostedSession, fired: *std.ArrayList(*Work), limit: usize) void {
        const prompts = self.session.takeDueCronPrompts(self.gpa, limit) catch |err| {
            log.warn("session_host", "cron of {s} not checked: {s}", .{ self.id.asSlice(), @errorName(err) });
            return;
        };
        defer {
            for (prompts) |prompt| self.gpa.free(prompt);
            self.gpa.free(prompts);
        }
        for (prompts) |prompt| {
            const work = self.newWork() catch {
                log.warn("session_host", "dropped a cron prompt for {s} (OOM)", .{self.id.asSlice()});
                continue;
            };
            const text = work.arena.allocator().dupe(u8, prompt) catch {
                log.warn("session_host", "dropped a cron prompt for {s} (OOM)", .{self.id.asSlice()});
                self.freeWork(work);
                continue;
            };
            work.item = .{ .submission = .{ .text = text, .source = cron_source, .kind = cron_kind } };
            fired.append(self.gpa, work) catch {
                log.warn("session_host", "dropped a cron prompt for {s} (OOM)", .{self.id.asSlice()});
                self.freeWork(work);
            };
        }
    }

    /// Copies the Session's cron jobs for `snapshot` (#493). Driver-only,
    /// between Runs: a Run's cron tools change them. A copy that fails keeps
    /// the last one.
    fn refreshCronJobs(self: *HostedSession) void {
        if (self.session.cronJobCount() == 0) {
            self.mutex.lock();
            const previous = self.cron_jobs;
            self.cron_jobs = &.{};
            self.mutex.unlock();
            cron_registry.freeViews(self.gpa, previous);
            return;
        }
        const jobs = self.session.cronJobs(self.gpa) catch |err| {
            log.warn("session_host", "cron jobs of {s} not reported: {s}", .{ self.id.asSlice(), @errorName(err) });
            return;
        };
        self.mutex.lock();
        const previous = self.cron_jobs;
        self.cron_jobs = jobs;
        self.mutex.unlock();
        cron_registry.freeViews(self.gpa, previous);
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
            // A resumed Run (#446) keeps no record of what its submission
            // was, so its spawn failures are reported. Each resumption waits
            // for a person's answer first, so reports still cannot loop on
            // their own. Re-announcing a request runs nothing.
            .command, .resumption, .re_announce => return false,
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
        if (!self.applySubmissionConfig(submission)) return;
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
            .idempotency_key = submission.idempotency_key,
        });
    }

    /// Applies a submission's own `model` and `permission_mode` (#445), in
    /// that order, each journaled as `config_changed`, as the bundled daemon
    /// journals a message's fields (`web/session.startSubmission`): even
    /// when already in force, the model as resolved. The mode is checked
    /// before anything changes, so either refusal applies nothing; only a
    /// mode switch that fails once allowed (it cannot, while the driver
    /// alone mutates the Session) leaves the model applied, as its line
    /// says. False = rejected: `message_rejected` is journaled and no Run
    /// starts.
    fn applySubmissionConfig(self: *HostedSession, submission: Submission) bool {
        if (submission.model == null and submission.permission_mode == null) return true;
        self.session.awaitProviderCancelsDrained();
        if (submission.permission_mode) |mode| {
            // AgentSession.setPermissionMode's own check, made before the
            // model changes.
            if (!self.session.permission_ctx.modeAllowed(mode)) {
                self.rejectSubmission(submission, error.PermissionModeDisabled, false);
                return false;
            }
        }
        if (submission.model) |model| {
            self.applyModel(model) catch |err| {
                self.rejectSubmission(submission, err, false);
                return false;
            };
            // Only the driver writes `model`.
            self.emitConfig(.{ .model = self.model });
        }
        if (submission.permission_mode) |mode| {
            // Journaled by the config sink (`configSink`) as it is set.
            self.session.setPermissionMode(mode) catch |err| {
                self.rejectSubmission(submission, err, submission.model != null);
                return false;
            };
        }
        return true;
    }

    /// `message_rejected` in place of the submission's `user_message`: its
    /// text stays out of the conversation, its idempotency key is let go (no
    /// Run started) and the Session is idle again. `applied` = the model
    /// was switched before the refusal and stays so.
    fn rejectSubmission(self: *HostedSession, submission: Submission, err: SubmissionRefusal, applied: bool) void {
        log.warn("session_host", "submission to {s} rejected: {s}", .{ self.id.asSlice(), @errorName(err) });
        if (applied) self.persist();
        self.mutex.lock();
        if (submission.idempotency_key) |key| self.ledger.forget(key);
        if (!self.closing) self.phase = .idle;
        self.mutex.unlock();
        self.emitHost(.{ .message_rejected = .{
            .message = refusalReason(err, submission.permission_mode),
            .text = submission.text,
            .model = submission.model,
            .permission_mode = if (submission.permission_mode) |mode| @tagName(mode) else null,
        } });
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
        // The jobs the Run's cron tools created or deleted, in `snapshot`
        // by the time `run_done` says the Run ended (#493).
        self.refreshCronJobs();

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
        // A change a `config_changed` line can say is journaled as one before
        // the `command_result`, as the bundled daemon's config sink journals
        // `/model`, `/mode`, `/effort` and `/add-dir` (#445). The mode goes
        // through the sink itself (`configSink`).
        const failure: ?anyerror = switch (cmd) {
            .set_model => |model| if (self.applyModel(model)) |_| blk: {
                // Only the driver writes `model`.
                self.emitConfig(.{ .model = self.model });
                break :blk null;
            } else |err| err,
            .set_permission_mode => |mode| if (self.session.setPermissionMode(mode)) |_| null else |err| err,
            .set_reasoning_effort => |effort| if (self.session.setReasoningEffort(effort)) |_| blk: {
                self.mutex.lock();
                self.reasoning_effort = effort;
                self.mutex.unlock();
                self.emitConfig(.{ .reasoning = effort });
                break :blk null;
            } else |err| err,
            .set_additional_directories => |dirs| self.applyDirectories(dirs),
            .set_prompt_profile => |profile| if (self.session.setPromptProfile(profile)) |_| null else |err| err,
            .update_permission_rules => |rules| if (self.session.updatePermissionRules(rules)) |_| null else |err| err,
            .compact => blk: {
                self.last_compact_id += 1;
                _ = self.session.compact(self.last_compact_id, .{}) catch |err| break :blk err;
                break :blk null;
            },
            .cancel_cron_job => |id| blk: {
                const found = self.session.cancelCronJob(id) catch |err| break :blk err;
                break :blk if (found) null else error.CronJobNotFound;
            },
            .cancel_all_cron_jobs => if (self.session.cancelAllCronJobs()) |_| null else |err| err,
        };
        switch (cmd) {
            // What `snapshot` shows before the `command_result` says so.
            .cancel_cron_job, .cancel_all_cron_jobs => self.refreshCronJobs(),
            else => {},
        }
        if (failure == null) self.persist();
        self.emitHost(.{ .command_result = .{
            .command = @tagName(cmd),
            .ok = failure == null,
            .error_name = if (failure) |err| @errorName(err) else null,
        } });
    }

    /// Replaces the Session's additional directories and journals each
    /// directory now in force that was not before as `config_changed{dirs}`,
    /// its resolved path, as the daemon journals the one `/add-dir` adds. A
    /// directory taken away has no line: v1's `dirs` names one directory
    /// that came into force.
    fn applyDirectories(self: *HostedSession, dirs: []const []const u8) ?anyerror {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        // The driver alone changes them, so this read is not racing a write.
        const previous = self.session.workspace.additional_dirs;
        const before = scratch.allocator().alloc([]const u8, previous.len) catch |err| return err;
        for (previous, before) |dir, *copy| copy.* = scratch.allocator().dupe(u8, dir) catch |err| return err;
        self.session.setAdditionalDirectories(dirs) catch |err| return err;
        for (self.session.workspace.additional_dirs) |dir| {
            const known = for (before) |old| {
                if (std.mem.eql(u8, old, dir)) break true;
            } else false;
            if (!known) self.emitConfig(.{ .dirs = dir });
        }
        return null;
    }

    /// Switches the Session to `requested`, resolved through
    /// `Options.models` when the Host set it.
    fn applyModel(self: *HostedSession, requested: []const u8) ModelChangeError!void {
        const model = if (self.host.options.models) |policy|
            try resolveModel(policy, self.provider_kind, requested)
        else
            requested;
        const copy = try self.gpa.dupe(u8, model);
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

    /// The committed conversation where the transcript is the witness of a
    /// suspension (#446). A background job does not stand in the way: jobs
    /// are no part of the committed state (`AgentSession.
    /// snapshotCommittedForRunMeasurement`), so the lease that ignores them
    /// is a coherent read; a provider cancel still in flight is waited out.
    fn conversationLease(self: *HostedSession) !agent_session.CheckpointLease {
        self.session.awaitProviderCancelsDrained();
        return self.session.snapshotCommittedForRunMeasurement();
    }

    /// `persist` for the suspend and resume points (#446): written even with
    /// a background job running. Whether the transcript was written.
    fn persistDurable(self: *HostedSession) bool {
        const writer = if (self.writer) |*writer| writer else return false;
        var lease = self.conversationLease() catch return false;
        defer lease.deinit();
        writer.flush(lease.conversation);
        self.mutex.lock();
        self.messages = lease.conversation.len();
        self.mutex.unlock();
        return true;
    }

    /// The request id a Host waits on: the blocking request's, else the
    /// suspended or suspending question's (#446). Caller holds `mutex`.
    fn pendingIdLocked(self: *const HostedSession) u64 {
        if (self.pending_request_id != 0) return self.pending_request_id;
        if (self.suspension) |suspension| return suspension.request_id;
        if (self.suspending) |pending| return pending.id;
        return 0;
    }

    /// Whether `key` is the idempotency key of the Run suspended or being
    /// resumed. Caller holds `mutex`.
    fn heldKeyLocked(self: *const HostedSession, key: []const u8) bool {
        for ([_]?*Suspension{ self.suspension, self.resuming }) |maybe| {
            const suspension = maybe orelse continue;
            const held = suspension.settings.idempotency_key orelse continue;
            if (std.mem.eql(u8, held, key)) return true;
        }
        return false;
    }

    /// The Session's config sink, as the daemon's `WebConfigSink` (#445):
    /// attached to its permission context at `open`, so every permission
    /// mode the Session takes is journaled as `config_changed{mode}`,
    /// whatever set it. Called on the thread that set it.
    fn configSink(self: *HostedSession) ui_event.ConfigEventSink {
        return .{ .ctx = self, .emitFn = emitConfigThunk };
    }

    fn emitConfigThunk(ctx: *anyopaque, change: ui_event.ConfigChange) void {
        const self: *HostedSession = @ptrCast(@alignCast(ctx));
        self.emitConfig(change);
    }

    /// A `config_changed` line between Runs, as the daemon journals one.
    fn emitConfig(self: *HostedSession, change: ui_event.ConfigChange) void {
        const line = wire.writeEvent(self.gpa, .{ .config_changed = change }) catch {
            log.warn("session_host", "dropped config_changed (OOM)", .{});
            return;
        };
        defer self.gpa.free(line);
        self.journal.append(line);
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

        self.mutex.lock();
        // Released means the abort is in force. An interrupt still on its way
        // to the kernel lets the prompt be announced and wait for it.
        if (self.ui_released) {
            self.mutex.unlock();
            return cancelAnswer(req, .cancelled);
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
        // `.suspend` never suspends a permission request: the kernel's gate
        // would read `pending` as no answer and deny the tool unasked. Nor
        // one it cannot keep: a request file it could not read.
        const suspends = policy.wait == .@"suspend" and req.* != .permission and !self.store_unwritable;
        // The id and the request it names are registered together, so an
        // answer never finds the one without the other.
        const request_id = self.next_request_id;
        self.next_request_id += 1;
        if (suspends) self.suspending = .{ .id = request_id } else self.pending_request_id = request_id;
        self.mutex.unlock();
        // `.suspend` keeps ids across restarts: this one is written before
        // anyone can answer it. Unwritten, it is still unique in this process.
        if (policy.wait == .@"suspend") self.storeRequests() catch |err|
            log.warn("session_host", "request id {d} of {s} not recorded: {s}", .{ request_id, self.id.asSlice(), @errorName(err) });

        const announce = wire.writeRequest(self.gpa, request_id, req) catch |err| {
            if (suspends) self.closeSuspending() else {
                self.mutex.lock();
                self.pending_request_id = 0;
                self.mutex.unlock();
            }
            return err;
        };
        if (suspends) {
            self.mutex.lock();
            self.suspending.?.announcement = announce;
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
        // No answer: the deadline passed, also under `.interrupt`, whose stop
        // follows from it (nobody interrupted the prompt); else an interrupt
        // or close in force cancelled it (and discarded any answer that
        // raced it); else the deadline passed.
        const why: wire.NoAnswer = if (expired_stop)
            .timed_out
        else if (self.ui_released or self.run_interrupted or self.closing)
            .cancelled
        else
            .timed_out;
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
            wire.parseResponse(req, json, allocator, out) catch |err| {
                // An unreadable answer still names who sent it; running out
                // of memory reading it closes on nobody's answer.
                const closed = wire.closedOnParseError(err);
                self.appendLine(wire.writeRequestClosedBy(self.gpa, request_id, closed, if (closed == .malformed) by else null));
                return if (err == error.OutOfMemory) err else cancelAnswer(req, .unreadable);
            };
            self.appendLine(wire.writeRequestClosedBy(self.gpa, request_id, .answered, by));
            return .answered;
        }
        // The journal and the requester's error come from the same `why`, so
        // what the Host records and what the model reads agree.
        self.appendLine(wire.writeRequestClosed(self.gpa, request_id, why.closed()));
        return cancelAnswer(req, why);
    }

    /// `wire.cancelResponse` as the AgentSession needs it (#446): a question
    /// that was cancelled or answered unreadably is the user's outcome,
    /// `error.UiCancelled`, which the AgentSession hands to the tool (the
    /// call fails with InputAborted, as the model sees). A permission
    /// prompt's `ui_request.Unanswered` error goes on as it is: the gate
    /// denies the call and tells the model why (#463). Any other error from a
    /// requester is a broken Host to the AgentSession, and poisons the
    /// Session: a cancelled question used to end its Session that way.
    fn cancelAnswer(req: *const ui_request.UiRequest, why: wire.NoAnswer) anyerror!ui_request.RequestOutcome {
        const err = wire.cancelResponse(req, why);
        return if (err == error.InputAborted and req.* == .ask_question) error.UiCancelled else err;
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
        if (pending.announcement) |line| self.gpa.free(line);
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
        self.mutex.unlock();
        self.freeSuspending(pending);
        if (pending.announcement != null) self.appendLine(wire.writeRequestClosed(self.gpa, pending.id, .cancelled));
    }

    /// Holds a Run that ended `suspended` until its request is settled.
    /// Durable first: the conversation with the suspended call (the
    /// transcript is fsynced), then the request with a result for every
    /// other call of its turn (`ui_request_store`, the commit point a later
    /// open reads).
    fn holdSuspension(self: *HostedSession, info: agent_loop.SuspendInfo, settings: RunSettings) void {
        // The request stays registered (`suspending`) until the suspension
        // takes its place under one lock, so an answer given meanwhile still
        // reaches it. Only the driver clears `suspending`.
        self.mutex.lock();
        const registered = self.suspending;
        self.mutex.unlock();
        const pending = registered orelse {
            // Only `requestUi` answers `pending`, so this is not reached.
            // With no request there is nothing to resume the call with; the
            // next Run's request stands in for its result (message_repair).
            log.err("session_host", "a Run of {s} suspended on {s} without a pending request", .{ self.id.asSlice(), info.tool_use_id });
            return;
        };
        const suspension = self.buildSuspension(pending.id, pending.announcement.?, info, settings) catch |err| {
            log.err("session_host", "request {d} of {s} not held: {s}", .{ pending.id, self.id.asSlice(), @errorName(err) });
            self.closeSuspending();
            return;
        };
        // The record is written only once the transcript holds the turn: a
        // record whose call the transcript lacks is dropped on open.
        const written = self.persistDurable();
        if (builtin.is_test) if (testing_hooks.before_handover) |hook| hook(self);
        self.mutex.lock();
        var taken = self.suspending.?;
        self.suspending = null;
        self.suspension = suspension;
        if (taken.answer) |json| {
            suspension.settled = .{ .answered = .{ .json = json, .by = taken.by } };
            taken.answer = null;
            taken.by = null;
        }
        // An interrupt during the Run cancels what it suspended on.
        if (self.run_interrupted) self.cancelSuspensionLocked(suspension, true);
        self.mutex.unlock();
        self.freeSuspending(taken);
        if (!written) {
            log.warn("session_host", "suspended request {d} of {s} held in memory only, its turn could not be written", .{ suspension.request_id, self.id.asSlice() });
            return;
        }
        self.storeRequests() catch |err|
            log.warn("session_host", "suspended request {d} of {s} held in memory only, a restart loses it: {s}", .{ suspension.request_id, self.id.asSlice(), @errorName(err) });
    }

    fn buildSuspension(self: *HostedSession, request_id: u64, announcement: []const u8, info: agent_loop.SuspendInfo, settings: RunSettings) !*Suspension {
        const suspension = try self.newSuspension(request_id, settings.max_turns);
        errdefer self.destroySuspension(suspension);
        const a = suspension.arena.allocator();
        suspension.announcement = try a.dupe(u8, announcement);
        suspension.request = (try wire.parseRequest(a, suspension.announcement)).request;
        suspension.tool_use_id = try a.dupe(u8, info.tool_use_id);
        try self.turnResults(a, info, suspension);
        suspension.settings = .{
            .trace_id = if (settings.trace_id) |trace_id| try a.dupe(u8, trace_id) else null,
            .max_turns = settings.max_turns,
            .stream_retry_budget = settings.stream_retry_budget,
            .idempotency_key = if (settings.idempotency_key) |key| try a.dupe(u8, key) else null,
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
        var lease = self.conversationLease() catch {
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
        // Left as it is (`restoreRequests` said so once).
        if (self.store_unwritable) return;
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
            .idempotency_key = held.settings.idempotency_key,
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
            // Never written over, and its ids never reused, though nothing
            // records the ids handed out from now on: they go on past the
            // file's last one and past the clock in milliseconds, which no
            // earlier process can have counted up to (a request takes a
            // model turn, far longer than a millisecond).
            self.store_unwritable = true;
            const clock: u64 = @intCast(@max(wallMs(), 1));
            self.next_request_id = @max(ui_request_store.peekNextId(arena.allocator(), dir) orelse 1, clock);
            log.err("session_host", "UI requests of {s} not read ({s}): the file is left as it is, requests block, ids start at {d}", .{ self.id.asSlice(), @errorName(err), self.next_request_id });
            return;
        }) orelse return;
        self.next_request_id = state.next_id;
        const record = state.suspended orelse return;
        if (mode == .@"resume") switch (callState(conversation, record.tool_use_id)) {
            .waiting => if (self.restoreSuspension(record)) |suspension| {
                self.suspension = suspension;
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
            .idempotency_key = if (record.idempotency_key) |key| try a.dupe(u8, key) else null,
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
    /// with InputAborted, as `wire.cancelResponse` fails a question.
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
                if (wire.parseResponse(&suspension.request, answered.json, a, &out)) |_| switch (out) {
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
                } else |err| switch (err) {
                    // Unreadable: `InputAborted`, as a suspension is never a
                    // permission request. It closes as the blocking path
                    // closes it.
                    error.InputAborted, error.UiAnswerUnreadable => closed = wire.closedOnParseError(err),
                    error.OutOfMemory => return error.OutOfMemory,
                }
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
        // `finishRun` skips the transcript while a background job runs.
        _ = self.persistDurable();
        const applied = blk: {
            var lease = self.conversationLease() catch break :blk false;
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
        // A suspended Run outlives the Session (#446): what settled its
        // request but was not applied yet is kept for the next open.
        if (self.suspension) |suspension| {
            if (suspension.settled != .open) self.storeRequests() catch |err|
                log.err("session_host", "settled request {d} of {s} not recorded: {s}", .{ suspension.request_id, self.id.asSlice(), @errorName(err) });
        }
        self.dropRequests();

        self.session.destroy() catch |err| log.err("session_host", "destroy {s}: {s}", .{ self.id.asSlice(), @errorName(err) });
        // The jobs closed with the AgentSession.
        self.mutex.lock();
        const cron_jobs = self.cron_jobs;
        self.cron_jobs = &.{};
        self.mutex.unlock();
        cron_registry.freeViews(self.gpa, cron_jobs);
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
        .set_permission_mode, .set_reasoning_effort, .compact, .cancel_cron_job, .cancel_all_cron_jobs => cmd,
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
    // Cancelled, not answered: the allow is discarded and nobody's deny is
    // invented in its place.
    try std.testing.expectError(error.UiRequestCancelled, HostedSession.requestUi(hosted, hosted.id, a, &request, &response));
    try waitForLine(&hosted.journal, "\"type\":\"ui_request_closed\",\"id\":1,\"outcome\":\"cancelled\"");
    hosted.mutex.lock();
    hosted.run_interrupted = false;
    hosted.mutex.unlock();
}

test "SessionHost #446: an answer reaches only the request it names; a permission beside a suspending question keeps its own id" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const runtime = try AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    // A timeout only so that a misrouted answer fails the test instead of
    // hanging it.
    var host = SessionHost.init(a, runtime, .{ .ui_request_wait = .@"suspend", .ui_request_timeout_ms = 2_000 });
    defer host.deinit();
    const hosted = try host.open(.{ .config = .{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = "http://127.0.0.1:9",
        .workspace = .{ .root = root, .home = root, .state_root = root },
        .allowed_tools = &.{},
    } });
    defer hosted.release();

    // A question of the Run in progress goes pending (id 1)...
    const options = [_]ui_request.AskOption{ .{ .label = "Ship", .description = "" }, .{ .label = "Wait", .description = "" } };
    const questions = [_]ui_request.AskQuestion{.{ .question = "Ship now?", .header = "Decision", .multi = false, .options = &options }};
    const question = ui_request.UiRequest{ .ask_question = &questions };
    var question_out: ui_request.UiResponse = undefined;
    try std.testing.expectEqual(ui_request.RequestOutcome.pending, try HostedSession.requestUi(hosted, hosted.id, a, &question, &question_out));
    defer hosted.closeSuspending();

    // ...and a tool still running in that turn asks for permission (id 2).
    const Asker = struct {
        outcome: anyerror!ui_request.RequestOutcome = error.NotRun,
        response: ui_request.UiResponse = undefined,
        fn run(self: *@This(), session: *HostedSession) void {
            const permission = ui_request.UiRequest{ .permission = .{ .tool = "Write", .args = "{}" } };
            self.outcome = HostedSession.requestUi(session, session.id, std.testing.allocator, &permission, &self.response);
        }
    };
    var asker = Asker{};
    const thread = try std.Thread.spawn(.{}, Asker.run, .{ &asker, hosted });
    try waitForLine(&hosted.journal, "\"type\":\"ui_request\",\"id\":2,\"kind\":\"permission\"");
    var snapshot = try hosted.snapshot(a);
    defer snapshot.deinit(a);
    try std.testing.expectEqual(@as(u64, 2), snapshot.pending_request_id);

    // The permission's answer is the permission's.
    try hosted.respond(2, "{\"choice\":\"allow_once\",\"by\":\"oncall\"}");
    thread.join();
    try std.testing.expectEqual(ui_request.RequestOutcome.answered, try asker.outcome);
    try std.testing.expectEqual(ui_request.PermissionChoice.allow_once, asker.response.permission);
    try waitForLine(&hosted.journal, "{\"v\":1,\"type\":\"ui_request_closed\",\"id\":2,\"outcome\":\"answered\",\"by\":\"oncall\"}");
    hosted.mutex.lock();
    const question_answer = hosted.suspending.?.answer;
    hosted.mutex.unlock();
    try std.testing.expect(question_answer == null);

    // The question still waits, under its own id.
    try std.testing.expectError(error.NoSuchRequest, hosted.respond(2, "{\"choice\":\"allow_once\"}"));
    try hosted.respond(1, "{\"answers\":[\"Ship\"]}");
    hosted.mutex.lock();
    const answered = hosted.suspending.?.answer != null;
    hosted.mutex.unlock();
    try std.testing.expect(answered);
}
