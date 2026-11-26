//! Durable, run-bound journal for actual tool-dispatch observations.
//!
//! This is execution evidence beside a session transcript, not agent memory and
//! not a canonical TinyKG store. Every complete record is written and fsynced
//! before the observation sink acknowledges it. A partial/corrupt existing
//! journal fails closed before a new run starts. This establishes an observable
//! file-flush boundary; it does not prove a filesystem's power-loss model.

const std = @import("std");
const pfs = @import("platform").fs;
const process_scan = @import("platform").process_scan;
const sync = @import("platform").sync;
const observation = @import("../tools/observation.zig");
const session_id_mod = @import("metacodes-kernel").session_id;
const util_time = @import("metacodes-base").util.time;
const util_fs = @import("metacodes-base").util.fs;
const execution_effect = @import("execution_effect.zig");
const run_recovery = @import("run_recovery.zig");
const prompt_sections = @import("prompt_sections.zig");

pub const SCHEMA_VERSION_V1 = "metacodes-tool-observation-journal-v1";
pub const SCHEMA_VERSION = "metacodes-tool-observation-journal-v2";
pub const FILE_NAME = "tool-observations.jsonl";
/// The Run lease. Whoever holds the system lock on this file (`tryLockExclusive`)
/// owns the session's next Run; the system drops that lock when the owner
/// exits, by any signal, so a free lock proves the previous owner gone. The
/// file names its owner in a `LeaseRecord`; an empty one was left by a
/// metacodes that predates the record and the lock, and is judged by whether
/// any other process still has it open (`process_scan.heldOpenByOthers`).
pub const LOCK_FILE_NAME = "tool-observations.lock";
const LEASE_SCHEMA_VERSION = "metacodes-run-lease-v1";
/// Lease records are rewritten in place at this fixed width, so a rewrite never
/// leaves the tail of a longer previous record behind.
const LEASE_RECORD_BYTES: usize = 256;

pub const LeaseState = enum {
    /// The owner's Run is open (or about to be).
    running,
    /// The Run's terminal record is durable but a derived artifact bound to it
    /// is not published yet. An owner that exits here leaves the session closed
    /// (`RunPublicationPending`) instead of silently losing that artifact.
    publication_pending,
    /// The Run and everything bound to it is published; the file is about to
    /// disappear, and says so durably in case removing it fails.
    released,
};

pub const LeaseRecord = struct {
    schema_version: []const u8 = LEASE_SCHEMA_VERSION,
    pid: i64,
    run_id: []const u8,
    acquired_wall_ns: i128,
    state: LeaseState,
};

/// What `init` does when the previous Run never reached its terminal record and
/// its owner is proven gone.
pub const AbandonedRunPolicy = enum {
    /// Keep the session closed (`UnfinishedRun`). The durable-profile contract
    /// of AgentCore and library hosts, which offer no recovery API.
    fail_closed,
    /// Close that Run with a `run_abandoned` record, then start the next one.
    /// Interactive product sessions, whose user decides what to do about a tool
    /// the dead process left running.
    record_abandoned,
};

pub const OpenOptions = struct {
    prompt: ?prompt_sections.Manifest = null,
    abandoned_run: AbandonedRunPolicy = .fail_closed,
    /// Filled on the outcomes it describes, success or not.
    report: ?*OpenReport = null,
};

/// What `init` learned beyond its result, for the host to tell its user.
pub const OpenReport = struct {
    /// Who holds the session when `init` answers `JournalBusy`.
    holder: Holder = .none,
    /// The previous Run that never finished: closed as abandoned on success
    /// under `record_abandoned`, or the reason for `UnfinishedRun`.
    unfinished: ?OpenRun = null,
    /// A half-written last record `init` cut (`record_abandoned` only).
    discarded_tail: ?DiscardedTail = null,

    pub const Holder = union(enum) {
        none,
        /// The lease record names this owner.
        process: struct { pid: i64, acquired_wall_ns: i128 },
        /// A process keeps open a lease left by an older metacodes, which does
        /// not record its owner.
        unnamed,
        /// Whether anyone holds the old-style lease could not be determined.
        unknown,
    };
};

/// The Run still open at the end of a journal.
pub const OpenRun = struct {
    run_id: session_id_mod.SessionId,
    started_wall_ns: i128,
    /// Monotonic time of its last record, relative to its start.
    last_elapsed_ns: u64,
    open_dispatches: u64,
    open_provider_attempts: u64,
    /// The tool of the most recently started dispatch, when it is still open.
    open_tool_buf: [64]u8 = undefined,
    open_tool_len: usize = 0,

    pub fn openTool(self: *const OpenRun) ?[]const u8 {
        return if (self.open_tool_len == 0) null else self.open_tool_buf[0..self.open_tool_len];
    }

    /// Wall time of its last record.
    pub fn lastActivityWallNs(self: *const OpenRun) i128 {
        return self.started_wall_ns + self.last_elapsed_ns;
    }
};

/// What to tell the person whose message `init` turned away with `err`, or
/// null when `err` is not one of the lease outcomes.
pub fn describeRefusal(buf: []u8, err: anyerror, report: *const OpenReport) ?[]const u8 {
    var since: [32]u8 = undefined;
    return switch (err) {
        error.JournalBusy => switch (report.holder) {
            .process => |holder| std.fmt.bufPrint(buf, "Another metacodes process (pid {d}) has been running a turn in this session since {s}. " ++
                "Wait for it to finish or stop it there, then send another message.", .{ holder.pid, localClock(&since, holder.acquired_wall_ns) }) catch null,
            .unnamed => "Another metacodes process, an older version that does not record its pid, is running a turn in this session. " ++
                "Wait for it to finish or stop it there, then send another message.",
            .none, .unknown => "This session's previous turn may still be running in another metacodes process, and whether that process is alive " ++
                "could not be determined. Close any other metacodes window on this session, then send another message.",
        },
        error.UnfinishedRun => if (report.unfinished) |run|
            std.fmt.bufPrint(buf, "This session's previous turn, started {s}, ended when its process exited without finishing, " ++
                "and this host does not reopen such a session.", .{localClock(&since, run.started_wall_ns)}) catch null
        else
            null,
        error.RunPublicationPending => "This session's previous turn finished, but evidence derived from it was never written. " ++
            "The session stays closed rather than lose that evidence silently; start a new session to continue.",
        else => null,
    };
}

/// What to tell the person about the Run `init` closed as abandoned.
pub fn describeAbandoned(buf: []u8, run: *const OpenRun) []const u8 {
    var started: [32]u8 = undefined;
    var last: [32]u8 = undefined;
    const when = .{ localClock(&started, run.started_wall_ns), localClock(&last, run.lastActivityWallNs()) };
    const fallback = "The previous turn in this session ended when its process exited; it is now closed as abandoned.";
    if (run.open_dispatches == 0) return std.fmt.bufPrint(buf, "The previous turn in this session (started {s}, last active {s}) " ++
        "ended when its process exited. It is now closed as abandoned.", when) catch fallback;
    const tool = run.openTool() orelse "a tool";
    return std.fmt.bufPrint(buf, "The previous turn in this session (started {s}, last active {s}) ended when its process exited " ++
        "while {s} was running. It is now closed as abandoned; what that tool did was never recorded, so check its effects " ++
        "before relying on them.", .{ when[0], when[1], tool }) catch fallback;
}

/// `2026-10-26 21:57` in the local zone (UTC when the zone is unknown).
fn localClock(buf: *[32]u8, wall_ns: i128) []const u8 {
    // The time comes from a journal record: anything out of range is unknown.
    const utc_seconds = std.math.cast(i64, @divFloor(wall_ns, std.time.ns_per_s)) orelse return "an unknown time";
    if (utc_seconds < 0 or utc_seconds > std.math.maxInt(u32)) return "an unknown time";
    const offset: i64 = if (@import("platform").timezone.local(utc_seconds)) |zone| zone.offset_minutes else 0;
    const local_seconds = utc_seconds + offset * 60;
    if (local_seconds < 0) return "an unknown time";
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(local_seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
    }) catch "an unknown time";
}

/// How `init` proved the owner of an abandoned Run gone.
pub const OwnerEvidence = enum {
    /// Its lease named it and the lease's lock was free.
    lease_unlocked,
    /// It predates the lease record, and no process kept its lease open.
    legacy_lease_unheld,
    /// There was no lease at all.
    no_lease,
};
pub const MAX_ARTIFACT_BYTES: usize = 64 * 1024 * 1024;
/// Maximum simultaneously open effects in one durable root Run. This is a
/// logical guard only: the reducer allocates in proportion to actual overlap.
/// 8192 covers MAX_AGENT_DEPTH=3 nested 8-way fanout plus each leaf agent's
/// 8-way tool window without imposing that memory cost on ordinary sessions.
pub const MAX_PENDING_EFFECTS: usize = 8192;

/// One section of the system prompt a Run sends (#184), as in its manifest.
pub const PromptSectionRecord = struct {
    id: []const u8,
    order: i64,
    origin: prompt_sections.Origin,
    class: prompt_sections.Class,
    sha256: [64]u8,
};

/// The manifest of the system prompt a Run sends: its sections in order and
/// the digest of the whole prompt.
pub const PromptRecord = struct {
    sha256: [64]u8,
    sections: []const PromptSectionRecord,
};

pub const MAX_PROMPT_RECORD_SECTIONS: usize = 128;

pub const RunStarted = struct {
    started_wall_ns: i128,
    /// Present when the Session rendered the Run's system prompt.
    prompt: ?PromptRecord = null,
    /// Present when this Run's `init` cut a half-written record a dead owner
    /// left at the end of the journal.
    discarded_tail: ?DiscardedTail = null,

    /// Optional members are written only when present, so a Run without them
    /// keeps the historical record bytes.
    pub fn jsonStringify(self: RunStarted, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("started_wall_ns");
        try jws.write(self.started_wall_ns);
        if (self.prompt) |prompt| {
            try jws.objectField("prompt");
            try jws.write(prompt);
        }
        if (self.discarded_tail) |tail| {
            try jws.objectField("discarded_tail");
            try jws.write(tail);
        }
        try jws.endObject();
    }
};

/// The bytes of a record a dead owner never finished writing, cut from the
/// journal end: how many, and their digest.
pub const DiscardedTail = struct {
    bytes: u64,
    sha256: [64]u8,
};

pub const JournalEvent = union(enum) {
    run_started: RunStarted,
    tool_observation: observation.Event,
    provider_attempt: execution_effect.ProviderAttemptEvent,
    run_finished: struct {
        stop_reason: []const u8,
        finished_wall_ns: i128,
    },
    /// The terminal record of a Run whose process died before its own: written
    /// by the process that proved it gone, carrying that Run's `run_id` and its
    /// last monotonic time. The effects it left open stay unresolved, so the
    /// Run is never evidence (`RunBinding` refuses it).
    run_abandoned: struct {
        evidence: OwnerEvidence,
        recovered_wall_ns: i128,
        /// The Run whose `init` wrote this record.
        recovered_by_run_id: []const u8,
        open_dispatches: u64,
        open_provider_attempts: u64,
    },
};

pub const Envelope = struct {
    schema_version: []const u8 = SCHEMA_VERSION,
    sequence: u64,
    monotonic_elapsed_ns: u64,
    session_id: []const u8,
    run_id: []const u8,
    event: JournalEvent,
};

pub const ValidationSummary = struct {
    records: u64,
    bytes: usize,
    complete: bool,
    artifact_sha256: [64]u8,
    /// Set exactly when `complete` is false.
    open_run: ?OpenRun = null,
    /// Wall time the last closed Run started, when a Run has closed.
    last_closed_run_started_wall_ns: ?i128 = null,
};

/// Immutable source interval for a later reflection/counterexample candidate.
/// The interval includes this Run's `run_started` and `run_finished` records.
pub const RunBinding = struct {
    session_id: session_id_mod.SessionId,
    run_id: session_id_mod.SessionId,
    first_sequence: u64,
    last_sequence: u64,
};

pub const BindingValidation = struct {
    summary: ValidationSummary,
    interval_sha256: [64]u8,
};

/// One exact, paired dispatch recovered from an immutable completed Run.
/// Borrowed strings live in `LoadedRunDispatches.arena`; scalar effect data is
/// copied by value.  This is the authoritative bridge from the host journal to
/// replay/shadow validation, not a model-supplied summary.
pub const RunDispatch = struct {
    id: []const u8,
    started_sequence: u64,
    finished_sequence: u64,
    requested_name: []const u8,
    dispatched_name: []const u8,
    origin: observation.Origin,
    agent_depth: u8,
    input_bytes: usize,
    input_sha256: [64]u8,
    replay: execution_effect.ReplayPolicy,
    file_target_state: observation.FileTargetState,
    outcome: observation.Outcome,
    effect: ?observation.Effect,
    effect_valid: bool,
};

pub const RunProviderAttempt = struct {
    attempt_id: [64]u8,
    actor_id: [24]u8,
    started_sequence: u64,
    finished_sequence: u64,
    request_sha256: [64]u8,
    logical_turn: u32,
    context_generation: u32,
    physical_attempt: u32,
    max_attempts: u32,
    outcome: execution_effect.ProviderAttemptOutcome,
    metering: execution_effect.Metering,
};

pub const RunFormalDecision = struct {
    sequence: u64,
    dispatch_id: []const u8,
    phase: observation.FormalPhase,
    operation: observation.FormalOperation,
    actuation: observation.FormalActuation,
    file_target_state: observation.FileTargetState = .unobserved,
    result: observation.FormalResult,
    recovery_action: observation.FormalRecoveryAction = .none,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    bundle_sha256: [64]u8,
    bundle_revision: u64,
    kernel_sha256: [64]u8,
    request_sha256: [64]u8,
    checker_call_sha256: ?[64]u8,
    checker_verdict_sha256: ?[64]u8,
    checker_batch_size: u32,
    verdict_sha256: ?[64]u8,
    checker_failure: ?[]const u8,
    checker_elapsed_ns: u64,
    checker_bytes: u64,
};

pub const RunRuleFilter = struct {
    sequence: u64,
    dispatch_id: []const u8,
    phase: observation.FormalPhase,
    operation: observation.RuleFilterOperation,
    project_sha256: [64]u8,
    bundle_sha256: [64]u8,
    bundle_revision: u64,
    kernel_sha256: [64]u8,
    active_rule_count: u32,
    checker_rule_count: u32,
    statically_pruned_rule_count: u32,
};

pub const BlockedVerdictBinding = struct {
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    bundle_sha256: [64]u8,
    bundle_revision: u64,
};

/// 过程信号聚合(PO-V2 M2/M4 传感器,self-evolution 触发轴):
/// 与 dispatch 配对无关的观察事件,折叠成整数充分统计。
pub const ProcessSignals = struct {
    test_weakening_candidates: u64 = 0,
    weakening_with_failed_verification: u64 = 0,
    /// verification_final_gate 是 run 末единственная总结事件;最后一条为准。
    final_closure_tier: ?u8 = null,
    final_gate_mutations_occurred: bool = false,
    known_failing: bool = false,
    redundant_verifications: u64 = 0,
};

pub const LoadedRunDispatches = struct {
    arena: std.heap.ArenaAllocator,
    interval_sha256: [64]u8,
    stop_reason: []const u8,
    dispatches: []const RunDispatch,
    provider_attempts: []const RunProviderAttempt,
    formal_decisions: []const RunFormalDecision,
    rule_filters: []const RunRuleFilter,
    process_signals: ProcessSignals = .{},

    pub fn deinit(self: *LoadedRunDispatches) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Journal = struct {
    mutex: sync.Mutex = .{},
    fd: pfs.Fd,
    /// The lease file, open and locked for this Journal's whole life.
    lock_fd: pfs.Fd,
    lock_path: [std.fs.max_path_bytes + 1]u8,
    lock_path_len: usize,
    session_id: session_id_mod.SessionId,
    run_id: session_id_mod.SessionId,
    run_first_sequence: u64,
    sequence: u64,
    file_bytes: usize,
    started_ns: i128,
    started_wall_ns: i128,
    recovery: run_recovery.Reducer,
    finished: bool = false,
    failed: bool = false,
    release_requested: bool = false,
    lock_released: bool = false,

    pub fn init(
        session_dir: []const u8,
        session_id: session_id_mod.SessionId,
    ) !Journal {
        return initWithOptions(session_dir, session_id, .{});
    }

    /// `init`, recording in `run_started` the manifest of the system prompt
    /// the Run sends (#184).
    pub fn initWithPrompt(
        session_dir: []const u8,
        session_id: session_id_mod.SessionId,
        prompt: ?prompt_sections.Manifest,
    ) !Journal {
        return initWithOptions(session_dir, session_id, .{ .prompt = prompt });
    }

    /// Take the session's Run lease, validate every existing record, settle a
    /// Run its dead owner left open (`AbandonedRunPolicy`), then durably
    /// publish this Run's identity before any provider or tool action can use
    /// the returned sink.
    ///
    /// `JournalBusy`: a live process holds the lease. `UnfinishedRun`: the
    /// previous Run's owner is gone without its terminal record, under
    /// `fail_closed`. `RunPublicationPending`: the previous Run finished but an
    /// artifact bound to it was never published.
    pub fn initWithOptions(
        session_dir: []const u8,
        session_id: session_id_mod.SessionId,
        options: OpenOptions,
    ) !Journal {
        var lock_path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const lock_path = try std.fmt.bufPrint(
            &lock_path_buf,
            "{s}/{s}\x00",
            .{ session_dir, LOCK_FILE_NAME },
        );
        const run_id = session_id_mod.gen();
        const started_wall_ns = util_time.nowWallNs();
        var lease = try Lease.acquire(@ptrCast(lock_path.ptr), options.report, run_id, started_wall_ns);
        errdefer lease.giveUp(@ptrCast(lock_path.ptr));

        var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path = try std.fmt.bufPrint(
            &path_buf,
            "{s}/{s}\x00",
            .{ session_dir, FILE_NAME },
        );
        const fd = pfs.open(
            @ptrCast(path.ptr),
            .{ .ACCMODE = .RDWR, .CREAT = true, .APPEND = true, .NOFOLLOW = true },
            @as(std.c.mode_t, 0o600),
        );
        if (fd < 0) return error.OpenFailed;
        errdefer _ = pfs.close(fd);
        try pfs.makeCloseOnExec(fd);

        // The lease is ours, so no writer is mid-record: a last record without
        // its newline belongs to a dead owner. It is cut only once this init
        // takes the Run, so a refusal leaves the journal as found.
        var torn: ?TornTail = null;
        const summary = validateFd(fd, session_id, null, null) catch |err| blk: {
            if (err != error.PartialRecord or options.abandoned_run != .record_abandoned) return err;
            torn = try planTornTailCut(fd, session_id);
            break :blk torn.?.summary;
        };
        var abandon: ?OwnerEvidence = null;
        if (summary.open_run) |open_run| {
            if (options.report) |report| report.unfinished = open_run;
            if (options.abandoned_run == .fail_closed) return error.UnfinishedRun;
            abandon = lease.prior.evidence();
        } else switch (lease.prior) {
            .record => |state| if (state == .publication_pending) return error.RunPublicationPending,
            // An older metacodes kept its marker past a Run's terminal record
            // only when publication failed (or it died in the instant between),
            // and it made that marker just before the Run started. An empty
            // lease made after the last Run closed is a leftover of an owner
            // that died before writing anything, and keeps nothing pending.
            // Comparing with the start leaves the Run's whole length as margin
            // for coarse file clocks; a tie is not taken as kept.
            .legacy => |modified| if (summary.last_closed_run_started_wall_ns) |started| {
                if (modified < started) return error.RunPublicationPending;
            },
            .created, .unreadable => {},
        }

        // Taking the Run: from here a crash leaves a lease naming this process,
        // which the next owner judges by its lock alone. (A lease this init
        // published names it already.)
        if (!lease.recorded) {
            try writeLeaseRecord(lease.fd, run_id, started_wall_ns, .running);
            lease.recorded = true;
        }
        if (torn) |cut| {
            try applyTornTailCut(fd, cut.kept);
            if (options.report) |report| report.discarded_tail = cut.tail;
        }
        if (pfs.lseek(fd, 0, .end) < 0) return error.SeekFailed;

        var journal = Journal{
            .fd = fd,
            .lock_fd = lease.fd,
            .lock_path = lock_path_buf,
            .lock_path_len = lock_path.len - 1,
            .session_id = session_id,
            .run_id = run_id,
            .run_first_sequence = summary.records,
            .sequence = summary.records,
            .file_bytes = summary.bytes,
            .started_ns = util_time.nowNs(),
            .started_wall_ns = started_wall_ns,
            .recovery = run_recovery.Reducer.init(std.heap.c_allocator, MAX_PENDING_EFFECTS),
        };
        errdefer journal.recovery.deinit();
        if (abandon) |evidence| {
            try journal.appendAbandoned(summary.open_run.?, evidence);
            journal.run_first_sequence = journal.sequence;
        }
        var prompt_sections_buf: [MAX_PROMPT_RECORD_SECTIONS]PromptSectionRecord = undefined;
        const prompt_record: ?PromptRecord = if (options.prompt) |manifest| blk: {
            if (manifest.entries.len > MAX_PROMPT_RECORD_SECTIONS) return error.PromptRecordTooLarge;
            for (manifest.entries, prompt_sections_buf[0..manifest.entries.len]) |entry, *record| record.* = .{
                .id = entry.id,
                .order = entry.order,
                .origin = entry.origin,
                .class = entry.class,
                .sha256 = std.fmt.bytesToHex(entry.sha256, .lower),
            };
            break :blk .{
                .sha256 = std.fmt.bytesToHex(manifest.sha256, .lower),
                .sections = prompt_sections_buf[0..manifest.entries.len],
            };
        } else null;
        try journal.appendEvent(.{ .run_started = .{
            .started_wall_ns = started_wall_ns,
            .prompt = prompt_record,
            .discarded_tail = if (torn) |cut| cut.tail else null,
        } });
        try fsyncDirectory(session_dir);
        return journal;
    }

    pub fn deinit(self: *Journal) void {
        self.recovery.deinit();
        if (self.fd >= 0) _ = pfs.close(self.fd);
        self.fd = -1;
        // Only a released Run gives the lease up. Any other exit leaves the
        // file naming this process, and closing it drops the lock, which is
        // what proves this owner gone to the next one.
        if (self.finished and self.release_requested and !self.lock_released) {
            self.releaseLease() catch if (is_windows and self.lock_fd >= 0) {
                // Last chance: the Run and its publication are done, and a
                // record still saying otherwise would close the session.
                _ = pfs.close(self.lock_fd);
                self.lock_fd = -1;
                self.lock_path[self.lock_path_len] = 0;
                pfs.unlinkPath(@ptrCast(&self.lock_path)) catch {};
            };
        }
        if (self.lock_fd >= 0) _ = pfs.close(self.lock_fd);
        self.lock_fd = -1;
    }

    pub fn sink(self: *Journal) observation.Sink {
        return .{ .ctx = @ptrCast(self), .emitFn = emitThunk };
    }

    /// Provider attempts share this journal with tool dispatches. Tool boundary
    /// events are already persisted by `sink()` and therefore remain a no-op
    /// here instead of creating a second authoritative record.
    pub fn executionBoundary(self: *Journal) execution_effect.Boundary {
        return .{ .ctx = @ptrCast(self), .emitFn = boundaryThunk };
    }

    pub fn runId(self: *const Journal) []const u8 {
        return self.run_id.asSlice();
    }

    pub fn runBinding(self: *const Journal) !RunBinding {
        if (!self.finished or !self.lock_released or self.sequence == 0)
            return error.RunNotFinished;
        return self.finishedRunBinding();
    }

    /// Return the exact durable interval after `sealRun` but before releasing
    /// the lease.  This is intentionally separate from `runBinding`:
    /// ordinary consumers must only observe a completely published Run.
    pub fn finishedRunBinding(self: *const Journal) !RunBinding {
        if (!self.finished or self.sequence == 0) return error.RunNotFinished;
        return .{
            .session_id = self.session_id,
            .run_id = self.run_id,
            .first_sequence = self.run_first_sequence,
            .last_sequence = self.sequence - 1,
        };
    }

    pub fn finishRun(self: *Journal, stop_reason: []const u8) !void {
        try self.seal(stop_reason, .running);
        try self.releaseFinishedRun();
    }

    /// Durably append the terminal record while keeping the lease, marked
    /// `publication_pending`. A caller that must publish a derived artifact
    /// does so before `releaseFinishedRun`, without opening a window in which
    /// the next Run starts first; should it never get there, the next `init`
    /// keeps the session closed instead of silently losing that artifact.
    pub fn sealRun(self: *Journal, stop_reason: []const u8) !void {
        return self.seal(stop_reason, .publication_pending);
    }

    fn seal(self: *Journal, stop_reason: []const u8, lease_state: LeaseState) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failed) return error.JournalFailed;
        if (self.finished) return error.RunAlreadyFinished;
        // Before the terminal record: an owner that dies between the two has
        // left its Run unfinished, which needs no publication either way.
        if (lease_state != .running)
            try writeLeaseRecord(self.lock_fd, self.run_id, self.started_wall_ns, lease_state);
        self.appendEventLocked(.{ .run_finished = .{
            .stop_reason = stop_reason,
            .finished_wall_ns = util_time.nowWallNs(),
        } }) catch |err| {
            self.failed = true;
            return err;
        };
        self.finished = true;
    }

    /// Complete publication and allow the next Run. Once requested, deinit
    /// retries the release if this attempt fails.
    pub fn releaseFinishedRun(self: *Journal) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.finished) return error.RunNotFinished;
        if (self.lock_released) return;
        self.release_requested = true;
        try self.releaseLease();
    }

    /// Give the lease up: say `released` durably, then remove the file. Either
    /// alone lets the next Run start (on Windows only the record counts). A
    /// failure keeps the descriptor open so `deinit` can try again.
    fn releaseLease(self: *Journal) !void {
        if (self.lock_released) return;
        if (self.lock_fd < 0) return error.LeaseLost;
        const recorded = if (writeLeaseRecord(self.lock_fd, self.run_id, self.started_wall_ns, .released)) true else |_| false;
        self.lock_path[self.lock_path_len] = 0;
        const path: [*:0]const u8 = @ptrCast(&self.lock_path);
        if (is_windows) {
            // Windows refuses to delete a file anyone has open, and a successor
            // may hold this one the moment ours closes: the record must say
            // `released` before the handle goes (a retry needs the handle),
            // and the delete is then a courtesy.
            if (!recorded) return error.LeaseReleaseFailed;
            _ = pfs.close(self.lock_fd);
            self.lock_fd = -1;
            pfs.unlinkPath(path) catch {};
        } else {
            // Remove the name while still holding the lock: a process that
            // opened it before then holds a file nobody can name, which
            // `Lease.acquire` notices, never a second live lease. A name that
            // no longer leads here (an older metacodes' late unlink, then a
            // new lease) is someone else's and stays.
            const ours = namesFile(path, self.lock_fd) catch false;
            const removed = if (!ours) true else if (pfs.unlinkPath(path)) true else |err| err == error.NotFound;
            // Still named and still locked by this process: a retry may unlink
            // it. Once the name is gone it may belong to a successor at any
            // moment, so nothing below may fail into a retry.
            if (!recorded and !removed) return error.LeaseReleaseFailed;
            if (removed) {
                if (std.fs.path.dirname(self.lock_path[0..self.lock_path_len])) |directory|
                    fsyncDirectory(directory) catch {};
            }
            _ = pfs.close(self.lock_fd);
            self.lock_fd = -1;
        }
        self.lock_released = true;
    }

    /// Close the Run `init` found open with its owner gone. The record carries
    /// that Run's identity and last monotonic time, not this process's: it is
    /// the dead Run's terminal record. It bypasses `recovery`, which never saw
    /// that Run start; every later `validateFd` replays it with the rest.
    fn appendAbandoned(self: *Journal, run: OpenRun, evidence: OwnerEvidence) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.writeEnvelopeLocked(.{
            .sequence = self.sequence,
            .monotonic_elapsed_ns = run.last_elapsed_ns,
            .session_id = self.session_id.asSlice(),
            .run_id = run.run_id.asSlice(),
            .event = .{ .run_abandoned = .{
                .evidence = evidence,
                .recovered_wall_ns = util_time.nowWallNs(),
                .recovered_by_run_id = self.run_id.asSlice(),
                .open_dispatches = run.open_dispatches,
                .open_provider_attempts = run.open_provider_attempts,
            } },
        });
    }

    fn emitThunk(raw: *anyopaque, event: observation.Event) bool {
        const self: *Journal = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failed or self.finished) return false;
        self.appendEventLocked(.{ .tool_observation = event }) catch {
            self.failed = true;
            return false;
        };
        return true;
    }

    fn boundaryThunk(raw: *anyopaque, event: execution_effect.BoundaryEvent) bool {
        const self: *Journal = @ptrCast(@alignCast(raw));
        const provider_event: ?execution_effect.ProviderAttemptEvent = switch (event) {
            .before => |intent| switch (intent) {
                .provider_request => |started| .{ .started = started },
                .tool_dispatch => null,
            },
            .after => |result| switch (result) {
                .provider_request => |finished| .{ .finished = finished },
                .tool_dispatch => null,
            },
        };
        const provider = provider_event orelse return true;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failed or self.finished or
            !execution_effect.validateProviderAttemptEvent(provider)) return false;
        self.appendEventLocked(.{ .provider_attempt = provider }) catch {
            self.failed = true;
            return false;
        };
        return true;
    }

    fn appendEvent(self: *Journal, event: JournalEvent) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.appendEventLocked(event);
    }

    fn appendEventLocked(self: *Journal, event: JournalEvent) !void {
        if (self.failed) return error.JournalFailed;
        // Validate the transition before making it durable. A failed write
        // poisons this Journal, so advancing the in-memory reducer first cannot
        // authorize later work; it only lets illegal live sequences fail now
        // instead of on the next process's validation pass.
        try applyRecoveryEvent(&self.recovery, self.run_id, event);
        return self.writeEnvelopeLocked(.{
            .sequence = self.sequence,
            .monotonic_elapsed_ns = elapsedNs(self.started_ns),
            .session_id = self.session_id.asSlice(),
            .run_id = self.run_id.asSlice(),
            .event = event,
        });
    }

    fn writeEnvelopeLocked(self: *Journal, envelope: Envelope) !void {
        if (self.failed) return error.JournalFailed;
        const line = try std.json.Stringify.valueAlloc(std.heap.c_allocator, envelope, .{});
        // realloc +1 通常原地扩(单分配),失败路径下面手动释放——不能用 defer free(line):
        // realloc 成功后 line 已失效。
        const record = std.heap.c_allocator.realloc(line, line.len + 1) catch {
            std.heap.c_allocator.free(line);
            return error.OutOfMemory;
        };
        defer std.heap.c_allocator.free(record);
        record[record.len - 1] = '\n';
        if (record.len > MAX_ARTIFACT_BYTES -| self.file_bytes)
            return error.ArtifactTooLarge;
        // 单缓冲提交:record+换行曾是两次 writeAll,SIGKILL 落在两次 syscall 之间
        // 必然留下无终止符的尾行。合并后 kill 窗口关死;short write(ENOSPC 等)
        // 仍可能撕裂半行——那条路径 failed=true→sealRun 拒写 run_finished,
        // 两侧审计器都因缺终止记录 fail-closed,不会当好数据读。
        try writeAll(self.fd, record);
        try pfs.fsyncChecked(self.fd);
        self.file_bytes += record.len;
        self.sequence += 1;
    }
};

const is_windows = @import("builtin").os.tag == .windows;

/// Bounds the retries when releases keep racing this acquisition; past it the
/// session is reported busy, which is what such contention is.
const MAX_LEASE_ATTEMPTS: usize = 16;

/// How long an older metacodes' marker must stay named, once nobody holds it,
/// to count as kept rather than mid-release (its close and unlink are
/// microseconds apart).
const LEGACY_RELEASE_SETTLE_MS: u64 = 100;

/// Pause between attempts on a Windows lease whose deletion is pending.
const WINDOWS_RELEASE_RETRY_MS: u64 = 20;

/// Sleep at least `ms`: a signal (SIGWINCH, SIGTERM, ...) ends one sleep early.
fn settleMs(ms: u64) void {
    const deadline = util_time.nowNs() + @as(i128, ms) * std.time.ns_per_ms;
    while (true) {
        const now = util_time.nowNs();
        if (now >= deadline) return;
        util_time.sleepMs(@intCast(@divTrunc(deadline - now + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
    }
}

/// Test seam, read only in test builds: runs in place of the settle `acquire`
/// gives an older metacodes' marker nobody holds, so a test can finish that
/// marker's release inside the window instead of racing a clock into it.
const testing_hooks = struct {
    var legacy_release_settle: ?*const fn (lease_path: [*:0]const u8) void = null;
};

/// Give an older metacodes caught between closing its marker at `path` and
/// unlinking it the moment to finish.
fn settleLegacyRelease(path: [*:0]const u8) void {
    if (@import("builtin").is_test) if (testing_hooks.legacy_release_settle) |hook| return hook(path);
    settleMs(LEGACY_RELEASE_SETTLE_MS);
}

/// The session's Run lease while `init` decides whether to take the Run.
const Lease = struct {
    fd: pfs.Fd,
    prior: Prior,
    /// The file holds this acquisition's own record.
    recorded: bool,

    const Prior = union(enum) {
        /// No lease existed; this acquisition published its own.
        created,
        /// An empty lease that no process holds: an older metacodes' marker,
        /// or a leftover of an owner that died before writing its record.
        /// Carries when the file was made (it was never written).
        legacy: i128,
        /// A lease record, in the state its now-gone owner left it.
        record: LeaseState,
        /// Bytes that are not a record: an owner died while writing one.
        unreadable,

        fn evidence(self: Prior) OwnerEvidence {
            return switch (self) {
                .created => .no_lease,
                .legacy => .legacy_lease_unheld,
                .record, .unreadable => .lease_unlocked,
            };
        }
    };

    /// Take the lease at `path` for the Run `run_id`. A new lease is written
    /// under a name of its own first and published by a link (Windows: move)
    /// that refuses to replace one, so the name never shows an empty file: an
    /// owner dying at any instant leaves either no lease or a record naming it.
    fn acquire(
        path: [*:0]const u8,
        report: ?*OpenReport,
        run_id: session_id_mod.SessionId,
        acquired_wall_ns: i128,
    ) !Lease {
        var legacy_unheld = false;
        var denied = false;
        var attempt: usize = 0;
        while (attempt < MAX_LEASE_ATTEMPTS) : (attempt += 1) {
            // A name per attempt: one a failed attempt could not remove (a
            // scanner holding it, say) must not block the next.
            var staged_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
            const staged = std.fmt.bufPrintZ(&staged_buf, "{s}.{s}.{d}", .{ std.mem.span(path), run_id.asSlice(), attempt }) catch
                return error.NameTooLong;
            denied = false;
            if (try publish(path, staged, run_id, acquired_wall_ns)) |fd|
                return .{ .fd = fd, .prior = .created, .recorded = true };
            const fd = pfs.open(path, leaseOpenFlags(.{ .ACCMODE = .RDWR, .NOFOLLOW = true }), @as(std.c.mode_t, 0));
            if (fd < 0) {
                if (pfs.lastErrnoIs(.NOENT)) continue; // released since: publish again
                // Windows refuses to open a file whose deletion is pending
                // until its last handle closes: a release in progress.
                if (is_windows and pfs.lastErrnoIs(.ACCES)) {
                    denied = true;
                    util_time.sleepMs(WINDOWS_RELEASE_RETRY_MS);
                    continue;
                }
                return error.LeaseOpenFailed;
            }
            pfs.makeCloseOnExec(fd) catch |err| {
                _ = pfs.close(fd);
                return err;
            };
            pfs.tryLockExclusive(fd) catch |err| {
                if (err == error.WouldBlock) {
                    if (report) |r| r.holder = switch (readLease(fd)) {
                        .record => |owner| .{ .process = .{ .pid = owner.pid, .acquired_wall_ns = owner.acquired_wall_ns } },
                        .empty, .unreadable => .unknown,
                    };
                }
                _ = pfs.close(fd);
                return if (err == error.WouldBlock) error.JournalBusy else error.LeaseLockFailed;
            };
            // A lock taken through a name the owner has since removed guards a
            // file nobody else can reach: start over with the name as it is now.
            const same = namesFile(path, fd) catch |err| {
                _ = pfs.close(fd);
                return err;
            };
            if (!same) {
                _ = pfs.close(fd);
                continue;
            }
            switch (readLease(fd)) {
                // Windows publishes by a move, before it can lock: the record
                // found may be the one it just put there.
                .record => |owner| return .{
                    .fd = fd,
                    .prior = if (std.mem.eql(u8, owner.runId(), run_id.asSlice())) .created else .{ .record = owner.state },
                    .recorded = std.mem.eql(u8, owner.runId(), run_id.asSlice()),
                },
                .unreadable => return .{ .fd = fd, .prior = .unreadable, .recorded = false },
                .empty => {
                    // An older metacodes takes no lock; it holds its marker open
                    // until it is done.
                    if (legacy_unheld) return legacyLease(fd);
                    if (!is_windows) {
                        // Asked while this lease stays locked: the file judged
                        // is the file taken.
                        const held = process_scan.heldOpenByOthers(path) catch {
                            _ = pfs.close(fd);
                            if (report) |r| r.holder = .unknown;
                            return error.JournalBusy;
                        };
                        if (!held) {
                            // An older metacodes releases by closing its marker,
                            // then unlinking it: one caught between the two is
                            // not a marker it kept. Give it the moment to go.
                            settleLegacyRelease(path);
                            const still = namesFile(path, fd) catch |err| {
                                _ = pfs.close(fd);
                                return err;
                            };
                            if (still) return legacyLease(fd);
                            _ = pfs.close(fd);
                            continue;
                        }
                        _ = pfs.close(fd);
                        if (report) |r| r.holder = .unnamed;
                        return error.JournalBusy;
                    }
                    // Windows counts this process's own handle: with ours closed,
                    // give an owner mid-release the moment to delete it (it
                    // cannot while anyone has it open), ask, then take the lease
                    // again. (A marker an older metacodes made in the one-scan
                    // gap after that would pass unseen.)
                    _ = pfs.close(fd);
                    settleLegacyRelease(path);
                    const held = process_scan.heldOpenByOthers(path) catch {
                        if (report) |r| r.holder = .unknown;
                        return error.JournalBusy;
                    };
                    if (held) {
                        if (report) |r| r.holder = .unnamed;
                        return error.JournalBusy;
                    }
                    legacy_unheld = true;
                },
            }
        }
        // Denied every time: not a release in progress but the file itself.
        if (denied) return error.LeaseOpenFailed;
        if (report) |r| r.holder = .unknown;
        return error.JournalBusy;
    }

    fn legacyLease(fd: pfs.Fd) !Lease {
        const info = pfs.fileInfo(fd) catch {
            _ = pfs.close(fd);
            return error.StatFailed;
        };
        return .{ .fd = fd, .prior = .{ .legacy = info.modified_wall_ns }, .recorded = false };
    }

    /// Write this Run's record under `staged` and publish it at `path`. Null
    /// when a lease already exists there. POSIX keeps the staged descriptor,
    /// locked before the link, as the published lease; Windows cannot move a
    /// file it holds open, and leaves the taking to `acquire`.
    fn publish(
        path: [*:0]const u8,
        staged: [:0]const u8,
        run_id: session_id_mod.SessionId,
        acquired_wall_ns: i128,
    ) !?pfs.Fd {
        const fd = pfs.open(staged.ptr, leaseOpenFlags(.{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true }), @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.LeaseOpenFailed;
        var keep = false;
        defer if (!keep) {
            _ = pfs.close(fd);
            pfs.unlinkPath(staged.ptr) catch {};
        };
        try pfs.makeCloseOnExec(fd);
        if (!is_windows) pfs.tryLockExclusive(fd) catch return error.LeaseLockFailed;
        try writeLeaseRecord(fd, run_id, acquired_wall_ns, .running);
        if (is_windows) {
            _ = pfs.close(fd);
            keep = true;
            // Anything but a move leaves the name to `acquire`, which retries a
            // lease whose deletion is still pending.
            const installed = pfs.installNoReplace(staged.ptr, path) catch .already_exists;
            if (installed == .already_exists) pfs.unlinkPath(staged.ptr) catch {};
            return null;
        }
        // A link refused for any reason but an existing lease (no hard links
        // on FAT, exFAT, many network and FUSE mounts): create the lease in
        // place. There the record follows the create closely, not atomically
        // with it, and an empty leftover is judged by its age.
        const installed = pfs.installNoReplace(staged.ptr, path) catch
            return publishInPlace(path, run_id, acquired_wall_ns);
        if (installed == .already_exists) return null;
        // Linked: the lease is published and this descriptor holds its lock.
        keep = true;
        pfs.unlinkPath(staged.ptr) catch {};
        return fd;
    }

    /// `publish` where the lease cannot be staged and linked: create it at
    /// `path` directly, lock it, and write the record. Null when a lease
    /// already exists, or someone locked this one first.
    fn publishInPlace(path: [*:0]const u8, run_id: session_id_mod.SessionId, acquired_wall_ns: i128) !?pfs.Fd {
        const fd = pfs.open(path, leaseOpenFlags(.{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true }), @as(std.c.mode_t, 0o600));
        if (fd < 0) {
            if (pfs.lastErrnoIs(.EXIST)) return null;
            return error.LeaseOpenFailed;
        }
        pfs.tryLockExclusive(fd) catch |err| {
            // Whoever locked it first decides about it; otherwise it goes.
            if (err != error.WouldBlock) pfs.unlinkPath(path) catch {};
            _ = pfs.close(fd);
            if (err == error.WouldBlock) return null;
            return error.LeaseLockFailed;
        };
        errdefer {
            pfs.unlinkPath(path) catch {};
            _ = pfs.close(fd);
        }
        try pfs.makeCloseOnExec(fd);
        try writeLeaseRecord(fd, run_id, acquired_wall_ns, .running);
        return fd;
    }

    /// `init` failed after acquiring. A lease it published says nothing a
    /// successor needs, so it goes (POSIX: while still locked); any other is
    /// left as found.
    fn giveUp(self: *Lease, path: [*:0]const u8) void {
        if (self.prior == .created) {
            if (is_windows) {
                _ = pfs.close(self.fd);
                pfs.unlinkPath(path) catch {};
                return;
            }
            if (namesFile(path, self.fd) catch false) pfs.unlinkPath(path) catch {};
        }
        _ = pfs.close(self.fd);
    }
};

/// Lease descriptors never outlive an exec: a child holding one would hold
/// its lock past its owner's death.
fn leaseOpenFlags(flags: pfs.O) pfs.O {
    var with_cloexec = flags;
    with_cloexec.CLOEXEC = true;
    return with_cloexec;
}

const LeaseContent = union(enum) {
    empty,
    record: struct {
        pid: i64,
        acquired_wall_ns: i128,
        state: LeaseState,
        run_id: @FieldType(session_id_mod.SessionId, "bytes"),

        fn runId(self: *const @This()) []const u8 {
            return &self.run_id;
        }
    },
    unreadable,
};

fn readLease(fd: pfs.Fd) LeaseContent {
    var buf: [LEASE_RECORD_BYTES * 2]u8 = undefined;
    if (pfs.lseek(fd, 0, .set) < 0) return .unreadable;
    var len: usize = 0;
    while (len < buf.len) {
        const n = pfs.read(fd, buf[len..]);
        if (n < 0) return .unreadable;
        if (n == 0) break;
        len += @intCast(n);
    }
    if (len == 0) return .empty;
    var scratch: [LEASE_RECORD_BYTES * 2]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    const record = std.json.parseFromSliceLeaky(LeaseRecord, fixed.allocator(), buf[0..len], .{
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    }) catch return .unreadable;
    if (!std.mem.eql(u8, record.schema_version, LEASE_SCHEMA_VERSION)) return .unreadable;
    const owner_run = session_id_mod.SessionId.fromSlice(record.run_id) orelse return .unreadable;
    return .{ .record = .{
        .pid = record.pid,
        .acquired_wall_ns = record.acquired_wall_ns,
        .state = record.state,
        .run_id = owner_run.bytes,
    } };
}

/// Rewrite the lease record in place, at its fixed width, durably.
fn writeLeaseRecord(
    fd: pfs.Fd,
    run_id: session_id_mod.SessionId,
    acquired_wall_ns: i128,
    state: LeaseState,
) !void {
    var buf: [LEASE_RECORD_BYTES]u8 = undefined;
    var writer: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    std.json.Stringify.value(LeaseRecord{
        .pid = @import("platform").process.currentPid(),
        .run_id = run_id.asSlice(),
        .acquired_wall_ns = acquired_wall_ns,
        .state = state,
    }, .{}, &writer) catch return error.LeaseRecordTooLarge;
    const used = writer.buffered().len;
    @memset(buf[used .. buf.len - 1], ' ');
    buf[buf.len - 1] = '\n';
    if (pfs.lseek(fd, 0, .set) < 0) return error.SeekFailed;
    try writeAll(fd, &buf);
    pfs.setSize(fd, buf.len) catch return error.LeaseWriteFailed;
    try pfs.fsyncChecked(fd);
}

/// Whether `path` still names the file open at `fd`. Windows deletes no file
/// that is open, so there the name cannot have moved.
fn namesFile(path: [*:0]const u8, fd: pfs.Fd) !bool {
    if (is_windows) return true;
    const by_name = pfs.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, @as(std.c.mode_t, 0));
    if (by_name < 0) {
        if (pfs.lastErrnoIs(.NOENT)) return false;
        return error.LeaseOpenFailed;
    }
    defer _ = pfs.close(by_name);
    const named = pfs.fileInfo(by_name) catch return error.StatFailed;
    const held = pfs.fileInfo(fd) catch return error.StatFailed;
    return named.device == held.device and named.inode == held.inode;
}

/// Validate a journal without mutating it. Useful for replay admission and L2.
pub fn validate(
    session_dir: []const u8,
    session_id: session_id_mod.SessionId,
) !ValidationSummary {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/{s}\x00",
        .{ session_dir, FILE_NAME },
    );
    const fd = pfs.open(
        @ptrCast(path.ptr),
        .{ .ACCMODE = .RDONLY, .NOFOLLOW = true },
        @as(std.c.mode_t, 0),
    );
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    return validateFd(fd, session_id, null, null);
}

/// Reopen the artifact and prove that the exact run interval still exists.
/// Candidate creation uses the returned artifact digest as immutable source
/// evidence; callers cannot satisfy it with a detached run id alone.
pub fn validateRunBinding(
    session_dir: []const u8,
    binding: RunBinding,
) !BindingValidation {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/{s}\x00",
        .{ session_dir, FILE_NAME },
    );
    const fd = pfs.open(
        @ptrCast(path.ptr),
        .{ .ACCMODE = .RDONLY, .NOFOLLOW = true },
        @as(std.c.mode_t, 0),
    );
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    var interval_sha256: [64]u8 = undefined;
    const summary = try validateFd(fd, binding.session_id, binding, &interval_sha256);
    return .{ .summary = summary, .interval_sha256 = interval_sha256 };
}

/// Reopen a completed Run and recover the concrete paired dispatches used by
/// shadow evaluation.  The exact interval is validated first and its digest is
/// rechecked against the second read, so an append is harmless while a rewrite
/// or replacement between the two reads fails closed.
pub fn loadRunDispatches(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    binding: RunBinding,
) !LoadedRunDispatches {
    const validated = try validateRunBinding(session_dir, binding);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ session_dir, FILE_NAME });
    const path_z = try a.dupeZ(u8, path);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    const info = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!info.is_regular or info.link_count != 1 or info.size > MAX_ARTIFACT_BYTES) return error.NotRegularFile;
    const bytes = try a.alloc(u8, @intCast(info.size));
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.ReadFailed;
        offset += @intCast(count);
    }
    const after = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!after.is_regular or after.link_count != 1 or after.size != info.size) return error.ArtifactChanged;
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return error.PartialRecord;

    var interval_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var records: std.ArrayList(RunDispatch) = .empty;
    var provider_attempts: std.ArrayList(RunProviderAttempt) = .empty;
    var formal_decisions: std.ArrayList(RunFormalDecision) = .empty;
    var process_signals = ProcessSignals{};
    var rule_filters: std.ArrayList(RunRuleFilter) = .empty;
    var stop_reason: ?[]const u8 = null;
    var open = std.AutoHashMap([32]u8, usize).init(a);
    var open_provider_attempts = std.AutoHashMap([32]u8, usize).init(a);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const envelope = std.json.parseFromSliceLeaky(Envelope, a, line, .{
            .ignore_unknown_fields = false,
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        }) catch return error.InvalidRecord;
        if (envelope.sequence < binding.first_sequence or
            envelope.sequence > binding.last_sequence) continue;
        if (!std.mem.eql(u8, envelope.session_id, binding.session_id.asSlice()) or
            !std.mem.eql(u8, envelope.run_id, binding.run_id.asSlice()))
            return error.InvalidRunBinding;
        interval_hasher.update(line);
        interval_hasher.update("\n");
        switch (envelope.event) {
            .run_started => if (envelope.sequence != binding.first_sequence)
                return error.InvalidRunBinding,
            .run_finished => |finished| {
                if (envelope.sequence != binding.last_sequence or stop_reason != null)
                    return error.InvalidRunBinding;
                stop_reason = finished.stop_reason;
            },
            .run_abandoned => return error.InvalidRunBinding,
            .provider_attempt => |provider_event| switch (provider_event) {
                .started => |started| {
                    const key = dispatchKey(&started.attempt_id);
                    if (open_provider_attempts.contains(key)) return error.InvalidRecord;
                    const index = provider_attempts.items.len;
                    try provider_attempts.append(a, .{
                        .attempt_id = started.attempt_id,
                        .actor_id = started.actor_id,
                        .started_sequence = envelope.sequence,
                        .finished_sequence = envelope.sequence,
                        .request_sha256 = started.request_sha256,
                        .logical_turn = started.logical_turn,
                        .context_generation = started.context_generation,
                        .physical_attempt = started.physical_attempt,
                        .max_attempts = started.max_attempts,
                        .outcome = .api_error,
                        .metering = .unknown,
                    });
                    try open_provider_attempts.put(key, index);
                },
                .finished => |finished| {
                    const index = open_provider_attempts.fetchRemove(dispatchKey(&finished.attempt_id)) orelse
                        return error.InvalidRecord;
                    const record = &provider_attempts.items[index.value];
                    record.finished_sequence = envelope.sequence;
                    record.outcome = finished.outcome;
                    record.metering = finished.metering;
                },
            },
            .tool_observation => |event| switch (event) {
                // Diagnostic-only: a coverage gap binds no rule identity and
                // no checker call, so replay has nothing to validate. It must
                // still never be silently dropped from the hashed interval.
                .rule_coverage_gap, .rule_bounds_overflow, .requirement_ledger, .delivery_cadence, .progress_updates, .stall_gate, .check_gate, .isolated_verifier, .learning_turn, .test_integrity, .system_one_decision => {},
                .test_weakening_candidate => |weakening| {
                    process_signals.test_weakening_candidates += 1;
                    if (weakening.last_verification_failed)
                        process_signals.weakening_with_failed_verification += 1;
                },
                .verification_final_gate => |gate| {
                    process_signals.final_closure_tier = gate.final_closure_tier;
                    process_signals.final_gate_mutations_occurred = gate.mutations_occurred;
                    process_signals.known_failing = gate.known_failing;
                    process_signals.redundant_verifications += gate.redundant_verifications;
                },
                .rule_filter => |filter| try rule_filters.append(a, .{
                    .sequence = envelope.sequence,
                    .dispatch_id = filter.dispatch_id,
                    .phase = filter.phase,
                    .operation = filter.operation,
                    .project_sha256 = filter.project_sha256,
                    .bundle_sha256 = filter.bundle_sha256,
                    .bundle_revision = filter.bundle_revision,
                    .kernel_sha256 = filter.kernel_sha256,
                    .active_rule_count = filter.active_rule_count,
                    .checker_rule_count = filter.checker_rule_count,
                    .statically_pruned_rule_count = filter.statically_pruned_rule_count,
                }),
                .formal_decision => |formal| try formal_decisions.append(a, .{
                    .sequence = envelope.sequence,
                    .dispatch_id = formal.dispatch_id,
                    .phase = formal.phase,
                    .operation = standardFormalOperation(formal.phase),
                    .actuation = formal.actuation,
                    .file_target_state = formal.file_target_state,
                    .result = formal.result,
                    .recovery_action = .none,
                    .candidate_id = formal.candidate_id,
                    .project_sha256 = formal.project_sha256,
                    .bundle_sha256 = formal.bundle_sha256,
                    .bundle_revision = formal.bundle_revision,
                    .kernel_sha256 = formal.kernel_sha256,
                    .request_sha256 = formal.request_sha256,
                    .checker_call_sha256 = formal.checker_call_sha256,
                    .checker_verdict_sha256 = formal.checker_verdict_sha256,
                    .checker_batch_size = formal.checker_batch_size,
                    .verdict_sha256 = formal.verdict_sha256,
                    .checker_failure = formal.checker_failure,
                    .checker_elapsed_ns = formal.checker_elapsed_ns,
                    .checker_bytes = formal.checker_bytes,
                }),
                .formal_decision_batch => |batch| for (batch.decisions) |decision| {
                    try formal_decisions.append(a, .{
                        .sequence = envelope.sequence,
                        .dispatch_id = batch.dispatch_id,
                        .phase = batch.phase,
                        .operation = if (std.mem.eql(
                            u8,
                            batch.schema_version,
                            observation.FORMAL_BATCH_SCHEMA_VERSION,
                        ) or std.mem.eql(
                            u8,
                            batch.schema_version,
                            observation.FORMAL_BATCH_SCHEMA_VERSION_V4,
                        )) decision.operation else standardFormalOperation(batch.phase),
                        .actuation = batch.actuation,
                        .file_target_state = batch.file_target_state,
                        .result = decision.result,
                        .recovery_action = decision.recovery_action,
                        .candidate_id = decision.candidate_id,
                        .project_sha256 = batch.project_sha256,
                        .bundle_sha256 = batch.bundle_sha256,
                        .bundle_revision = batch.bundle_revision,
                        .kernel_sha256 = batch.kernel_sha256,
                        .request_sha256 = decision.request_sha256,
                        .checker_call_sha256 = batch.checker_call_sha256,
                        .checker_verdict_sha256 = batch.checker_verdict_sha256,
                        .checker_batch_size = batch.checker_batch_size,
                        .verdict_sha256 = decision.verdict_sha256,
                        .checker_failure = decision.checker_failure,
                        .checker_elapsed_ns = batch.checker_elapsed_ns,
                        .checker_bytes = batch.checker_bytes,
                    });
                },
                .dispatch_started => |started| {
                    const key = dispatchKey(started.id);
                    if (open.contains(key)) return error.InvalidRecord;
                    const index = records.items.len;
                    try records.append(a, .{
                        .id = started.id,
                        .started_sequence = envelope.sequence,
                        .finished_sequence = envelope.sequence,
                        .requested_name = started.requested_name,
                        .dispatched_name = started.dispatched_name,
                        .origin = started.origin,
                        .agent_depth = started.agent_depth,
                        .input_bytes = started.input_bytes,
                        .input_sha256 = started.input_sha256,
                        .replay = started.replay,
                        .file_target_state = started.file_target_state,
                        .outcome = .host_fatal,
                        .effect = null,
                        .effect_valid = false,
                    });
                    try open.put(key, index);
                },
                .dispatch_finished => |finished| {
                    const index = open.fetchRemove(dispatchKey(finished.id)) orelse
                        return error.InvalidRecord;
                    const record = &records.items[index.value];
                    if (!std.mem.eql(u8, record.requested_name, finished.requested_name) or
                        !std.mem.eql(u8, record.dispatched_name, finished.dispatched_name) or
                        record.origin != finished.origin or
                        record.agent_depth != finished.agent_depth)
                        return error.InvalidRecord;
                    record.outcome = finished.outcome;
                    record.finished_sequence = envelope.sequence;
                    record.effect = finished.effect;
                    record.effect_valid = finished.effect_valid;
                },
            },
        }
    }
    if (open.count() != 0 or open_provider_attempts.count() != 0) return error.InvalidRecord;
    var raw_digest: [32]u8 = undefined;
    interval_hasher.final(&raw_digest);
    const interval_sha256 = std.fmt.bytesToHex(raw_digest, .lower);
    if (!std.mem.eql(u8, &interval_sha256, &validated.interval_sha256))
        return error.ArtifactChanged;
    return .{
        .arena = arena,
        .interval_sha256 = interval_sha256,
        .stop_reason = stop_reason orelse return error.InvalidRunBinding,
        .dispatches = try records.toOwnedSlice(a),
        .provider_attempts = try provider_attempts.toOwnedSlice(a),
        .formal_decisions = try formal_decisions.toOwnedSlice(a),
        .rule_filters = try rule_filters.toOwnedSlice(a),
        .process_signals = process_signals,
    };
}

pub fn runContainsBlockedVerdict(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    binding: RunBinding,
    checker_sha256: [64]u8,
    verdict_sha256: [64]u8,
    project_sha256: [64]u8,
    verdict_binding: ?BlockedVerdictBinding,
) !bool {
    var run = try loadRunDispatches(allocator, session_dir, binding);
    defer run.deinit();
    for (run.formal_decisions) |formal| {
        if (formal.actuation == .enforced and formal.result == .block and
            formal.verdict_sha256 != null and
            std.mem.eql(u8, &formal.kernel_sha256, &checker_sha256) and
            std.mem.eql(u8, &formal.project_sha256, &project_sha256) and
            std.mem.eql(u8, &formal.verdict_sha256.?, &verdict_sha256))
        {
            if (verdict_binding) |verdict_identity| {
                if (!std.mem.eql(u8, &formal.candidate_id, &verdict_identity.candidate_id) or
                    !std.mem.eql(u8, &formal.project_sha256, &verdict_identity.project_sha256) or
                    !std.mem.eql(u8, &formal.bundle_sha256, &verdict_identity.bundle_sha256) or
                    formal.bundle_revision != verdict_identity.bundle_revision)
                    continue;
            }
            return true;
        }
    }
    return false;
}

fn applyRecoveryEvent(
    reducer: *run_recovery.Reducer,
    run_id: session_id_mod.SessionId,
    event: JournalEvent,
) !void {
    switch (event) {
        .run_started => try reducer.apply(.{
            .run_started = run_recovery.EffectKey.fromBytes(run_id.asSlice()),
        }),
        .provider_attempt => |provider_event| switch (provider_event) {
            .started => |started| try reducer.apply(.{
                .provider_intent = .{
                    .key = try run_recovery.EffectKey.fromSha256Hex(started.attempt_id),
                    // A process crash never blindly repeats a provider request.
                    // In-process connect retries receive a distinct durable intent.
                    .replay = .never,
                },
            }),
            .finished => |finished| try reducer.apply(.{
                .provider_result = try run_recovery.EffectKey.fromSha256Hex(finished.attempt_id),
            }),
        },
        .tool_observation => |tool_event| switch (tool_event) {
            .dispatch_started => |started| try reducer.apply(.{ .tool_intent = .{
                .key = run_recovery.EffectKey.fromBytes(started.id),
                .replay = started.replay,
            } }),
            .dispatch_finished => |finished| try reducer.apply(.{
                .tool_result = run_recovery.EffectKey.fromBytes(finished.id),
            }),
            else => {},
        },
        .run_finished => {
            try reducer.apply(.run_closing);
            try reducer.apply(.run_finished);
        },
        .run_abandoned => try reducer.apply(.run_abandoned),
    }
}

fn validateFd(
    fd: pfs.Fd,
    expected_session: session_id_mod.SessionId,
    expected_binding: ?RunBinding,
    interval_sha256_out: ?*[64]u8,
) !ValidationSummary {
    const bytes = try readArtifact(fd);
    defer std.heap.c_allocator.free(bytes);
    if (bytes.len > 0 and bytes[bytes.len - 1] != '\n')
        return error.PartialRecord;
    return validateBytes(bytes, expected_session, expected_binding, interval_sha256_out);
}

/// The whole journal behind `fd`, from its start; the caller frees it with
/// `std.heap.c_allocator`.
fn readArtifact(fd: pfs.Fd) ![]u8 {
    const info = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!info.is_regular or info.link_count != 1) return error.NotRegularFile;
    if (info.size > MAX_ARTIFACT_BYTES) return error.ArtifactTooLarge;
    const size: usize = @intCast(info.size);
    if (pfs.lseek(fd, 0, .set) < 0) return error.SeekFailed;
    const bytes = try std.heap.c_allocator.alloc(u8, size);
    errdefer std.heap.c_allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = pfs.read(fd, bytes[offset..]);
        if (n <= 0) return error.ReadFailed;
        offset += @intCast(n);
    }
    return bytes;
}

/// The record a dead owner left half-written at the end of the journal. It
/// was never acknowledged — a record is acknowledged only once written whole
/// and flushed — so it is no evidence; what it was is kept as its length and
/// digest (`RunStarted.discarded_tail`). Everything before it must validate:
/// a damaged journal is not this repair's to make.
const TornTail = struct {
    summary: ValidationSummary,
    kept: usize,
    tail: DiscardedTail,
};

fn planTornTailCut(fd: pfs.Fd, session_id: session_id_mod.SessionId) !TornTail {
    const bytes = try readArtifact(fd);
    defer std.heap.c_allocator.free(bytes);
    const kept = if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |index| index + 1 else 0;
    if (kept == bytes.len) return error.PartialRecord;
    return .{
        .summary = try validateBytes(bytes[0..kept], session_id, null, null),
        .kept = kept,
        .tail = .{ .bytes = bytes.len - kept, .sha256 = observation.sha256Hex(bytes[kept..]) },
    };
}

fn applyTornTailCut(fd: pfs.Fd, kept: usize) !void {
    pfs.setSize(fd, kept) catch return error.TruncateFailed;
    try pfs.fsyncChecked(fd);
}

fn validateBytes(
    bytes: []const u8,
    expected_session: session_id_mod.SessionId,
    expected_binding: ?RunBinding,
    interval_sha256_out: ?*[64]u8,
) !ValidationSummary {
    const size = bytes.len;

    var expected_sequence: u64 = 0;
    var active_run: ?session_id_mod.SessionId = null;
    var active_started_wall_ns: i128 = 0;
    var last_closed_run_started_wall_ns: ?i128 = null;
    // The most recently started dispatch of the active Run, to name the tool a
    // dead owner left running.
    var last_dispatch_key: ?[32]u8 = null;
    var last_dispatch_name_buf: [64]u8 = undefined;
    var last_dispatch_name_len: usize = 0;
    var recovery = run_recovery.Reducer.init(std.heap.c_allocator, MAX_PENDING_EFFECTS);
    defer recovery.deinit();
    var active_elapsed_ns: u64 = 0;
    var binding_started = false;
    var binding_finished = false;
    var binding_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var open_dispatches = std.AutoHashMap([32]u8, OpenDispatch).init(std.heap.c_allocator);
    defer open_dispatches.deinit();
    var open_provider_attempts = std.AutoHashMap([32]u8, void).init(std.heap.c_allocator);
    defer open_provider_attempts.deinit();
    var seen_dispatches = std.AutoHashMap([32]u8, u8).init(std.heap.c_allocator);
    defer seen_dispatches.deinit();
    var formal_events = std.AutoHashMap([32]u8, u8).init(std.heap.c_allocator);
    defer formal_events.deinit();
    var pre_decisions = std.AutoHashMap([32]u8, PreDecision).init(std.heap.c_allocator);
    defer pre_decisions.deinit();
    var formal_dispatches = std.AutoHashMap([32]u8, FormalDispatchState).init(std.heap.c_allocator);
    defer formal_dispatches.deinit();
    var pending_rule_filters = std.AutoHashMap([32]u8, PendingRuleFilter).init(
        std.heap.c_allocator,
    );
    defer pending_rule_filters.deinit();
    var rule_filter_identities = std.AutoHashMap([32]u8, RuleFilterIdentity).init(
        std.heap.c_allocator,
    );
    defer rule_filter_identities.deinit();
    var formal_validation = FormalValidationState{
        .open_dispatches = &open_dispatches,
        .seen_dispatches = &seen_dispatches,
        .formal_events = &formal_events,
        .pre_decisions = &pre_decisions,
        .formal_dispatches = &formal_dispatches,
    };
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(Envelope, std.heap.c_allocator, line, .{
            .ignore_unknown_fields = false,
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        }) catch return error.InvalidRecord;
        defer parsed.deinit();
        const envelope = parsed.value;
        const run_id = session_id_mod.SessionId.fromSlice(envelope.run_id) orelse
            return error.InvalidRecord;
        if ((!std.mem.eql(u8, envelope.schema_version, SCHEMA_VERSION) and
            !std.mem.eql(u8, envelope.schema_version, SCHEMA_VERSION_V1)) or
            envelope.sequence != expected_sequence or
            !std.mem.eql(u8, envelope.session_id, expected_session.asSlice()))
            return error.InvalidRecord;
        applyRecoveryEvent(&recovery, run_id, envelope.event) catch
            return error.InvalidRecord;
        switch (envelope.event) {
            .run_started => |started| {
                if (active_run != null or open_dispatches.count() != 0 or
                    open_provider_attempts.count() != 0 or
                    pending_rule_filters.count() != 0)
                    return error.InvalidRecord;
                if (started.prompt) |prompt| {
                    if (!validPromptRecord(prompt)) return error.InvalidRecord;
                }
                if (started.discarded_tail) |tail| {
                    if (tail.bytes == 0 or !validHex(tail.sha256)) return error.InvalidRecord;
                }
                active_run = run_id;
                active_started_wall_ns = started.started_wall_ns;
                last_dispatch_key = null;
                active_elapsed_ns = envelope.monotonic_elapsed_ns;
                if (expected_binding) |binding| {
                    if (std.mem.eql(u8, binding.run_id.asSlice(), run_id.asSlice())) {
                        if (binding_started or envelope.sequence != binding.first_sequence)
                            return error.InvalidRunBinding;
                        binding_started = true;
                        binding_hasher.update(line);
                        binding_hasher.update("\n");
                    }
                }
            },
            .provider_attempt => |provider_event| {
                const current = active_run orelse return error.InvalidRecord;
                if (!std.mem.eql(u8, envelope.schema_version, SCHEMA_VERSION) or
                    !std.mem.eql(u8, current.asSlice(), run_id.asSlice()) or
                    envelope.monotonic_elapsed_ns < active_elapsed_ns or
                    !execution_effect.validateProviderAttemptEvent(provider_event))
                    return error.InvalidRecord;
                active_elapsed_ns = envelope.monotonic_elapsed_ns;
                if (expected_binding) |binding| {
                    if (binding_started and !binding_finished and
                        std.mem.eql(u8, binding.run_id.asSlice(), run_id.asSlice()))
                    {
                        binding_hasher.update(line);
                        binding_hasher.update("\n");
                    }
                }
                switch (provider_event) {
                    .started => |started| {
                        const key = dispatchKey(&started.attempt_id);
                        // Only a *still-open* attempt id is a real overlap. A
                        // bounded same-turn mid-stream re-issue legitimately
                        // reopens an attempt id whose prior physical attempt
                        // already closed (started → finished → started →
                        // finished): a balanced pair the recovery reducer and
                        // loadRunDispatches both accept positionally. Rejecting
                        // a merely once-seen id instead made such a journal
                        // permanently unresumable. Uniqueness across closed
                        // attempts is the writer's job (see agent_loop's
                        // per-turn re-issue generation), not an interval
                        // invariant: nothing downstream keys a run by it.
                        const entry = try open_provider_attempts.getOrPut(key);
                        if (entry.found_existing) return error.InvalidRecord;
                    },
                    .finished => |finished| {
                        if (open_provider_attempts.fetchRemove(dispatchKey(&finished.attempt_id)) == null)
                            return error.InvalidRecord;
                    },
                }
            },
            .tool_observation => |tool_event| {
                const current = active_run orelse return error.InvalidRecord;
                if (!std.mem.eql(u8, current.asSlice(), run_id.asSlice()) or
                    envelope.monotonic_elapsed_ns < active_elapsed_ns)
                    return error.InvalidRecord;
                active_elapsed_ns = envelope.monotonic_elapsed_ns;
                if (expected_binding) |binding| {
                    if (binding_started and !binding_finished and
                        std.mem.eql(u8, binding.run_id.asSlice(), run_id.asSlice()))
                    {
                        binding_hasher.update(line);
                        binding_hasher.update("\n");
                    }
                }
                switch (tool_event) {
                    .rule_coverage_gap, .rule_bounds_overflow, .verification_final_gate, .requirement_ledger, .delivery_cadence, .progress_updates, .stall_gate, .check_gate, .isolated_verifier, .learning_turn, .test_integrity, .test_weakening_candidate, .system_one_decision => {},
                    .rule_filter => |filter| {
                        try validateRuleFilter(&rule_filter_identities, filter);
                        const key = ruleFilterKey(filter.dispatch_id, filter.phase);
                        const entry = try pending_rule_filters.getOrPut(key);
                        if (entry.found_existing) return error.InvalidRecord;
                        entry.value_ptr.* = PendingRuleFilter.from(filter);
                    },
                    .formal_decision => |formal| {
                        const legacy = std.mem.eql(
                            u8,
                            formal.schema_version,
                            observation.FORMAL_SCHEMA_VERSION_V1,
                        );
                        if ((!legacy and !std.mem.eql(
                            u8,
                            formal.schema_version,
                            observation.FORMAL_SCHEMA_VERSION,
                        )) or (legacy and formal.actuation != .enforced))
                            return error.InvalidRecord;
                        try acceptFormalDecision(&formal_validation, .{
                            .dispatch_id = formal.dispatch_id,
                            .phase = formal.phase,
                            .operation = standardFormalOperation(formal.phase),
                            .actuation = formal.actuation,
                            .result = formal.result,
                            .recovery_action = .none,
                            .candidate_id = formal.candidate_id,
                            .project_sha256 = formal.project_sha256,
                            .bundle_sha256 = formal.bundle_sha256,
                            .bundle_revision = formal.bundle_revision,
                            .kernel_sha256 = formal.kernel_sha256,
                            .request_sha256 = formal.request_sha256,
                            .checker_call_sha256 = formal.checker_call_sha256,
                            .checker_verdict_sha256 = formal.checker_verdict_sha256,
                            .checker_batch_size = formal.checker_batch_size,
                            .verdict_sha256 = formal.verdict_sha256,
                            .checker_failure = formal.checker_failure,
                            .checker_bytes = formal.checker_bytes,
                            .is_batch = false,
                        }, .{ .is_batch = false, .first = true, .last = true });
                    },
                    .formal_decision_batch => |batch| {
                        const legacy_v1 = std.mem.eql(
                            u8,
                            batch.schema_version,
                            observation.FORMAL_BATCH_SCHEMA_VERSION_V1,
                        );
                        const legacy_v2 = std.mem.eql(
                            u8,
                            batch.schema_version,
                            observation.FORMAL_BATCH_SCHEMA_VERSION_V2,
                        );
                        const legacy_v3 = std.mem.eql(
                            u8,
                            batch.schema_version,
                            observation.FORMAL_BATCH_SCHEMA_VERSION_V3,
                        );
                        const legacy_v4 = std.mem.eql(
                            u8,
                            batch.schema_version,
                            observation.FORMAL_BATCH_SCHEMA_VERSION_V4,
                        );
                        const current_schema = std.mem.eql(
                            u8,
                            batch.schema_version,
                            observation.FORMAL_BATCH_SCHEMA_VERSION,
                        );
                        if ((!legacy_v1 and !legacy_v2 and !legacy_v3 and !legacy_v4 and
                            !current_schema) or
                            (legacy_v1 and batch.actuation != .enforced) or
                            batch.decisions.len == 0 or
                            batch.decisions.len > batch.checker_batch_size or
                            batch.checker_batch_size > @import("../formal/project_harness_runtime.zig").MAX_BATCH_REQUESTS or
                            (batch.decisions.len < batch.checker_batch_size and
                                batch.decisions[batch.decisions.len - 1].result == .admit))
                            return error.InvalidRecord;
                        if (current_schema) {
                            const filter = pending_rule_filters.fetchRemove(ruleFilterKey(
                                batch.dispatch_id,
                                batch.phase,
                            )) orelse return error.InvalidRecord;
                            if (!filter.value.matchesBatch(batch)) return error.InvalidRecord;
                        }
                        for (batch.decisions, 0..) |decision, decision_index| {
                            const operation = if (current_schema or legacy_v4)
                                decision.operation
                            else
                                standardFormalOperation(batch.phase);
                            if (operation.phase() != batch.phase) return error.InvalidRecord;
                            if (decision.recovery_action != .none and
                                (legacy_v1 or legacy_v2 or batch.phase != .pre or
                                    decision.result != .block or
                                    batch.file_target_state != .regular_existing))
                                return error.InvalidRecord;
                            try acceptFormalDecision(&formal_validation, .{
                                .dispatch_id = batch.dispatch_id,
                                .phase = batch.phase,
                                .operation = operation,
                                .actuation = batch.actuation,
                                .result = decision.result,
                                .recovery_action = decision.recovery_action,
                                .candidate_id = decision.candidate_id,
                                .project_sha256 = batch.project_sha256,
                                .bundle_sha256 = batch.bundle_sha256,
                                .bundle_revision = batch.bundle_revision,
                                .kernel_sha256 = batch.kernel_sha256,
                                .request_sha256 = decision.request_sha256,
                                .checker_call_sha256 = batch.checker_call_sha256,
                                .checker_verdict_sha256 = batch.checker_verdict_sha256,
                                .checker_batch_size = batch.checker_batch_size,
                                .verdict_sha256 = decision.verdict_sha256,
                                .checker_failure = decision.checker_failure,
                                .checker_bytes = batch.checker_bytes,
                                .is_batch = true,
                            }, .{
                                .is_batch = true,
                                .first = decision_index == 0,
                                .last = decision_index + 1 == batch.decisions.len,
                            });
                        }
                    },
                    .dispatch_started => |started| {
                        if (!std.mem.eql(u8, started.schema_version, observation.SCHEMA_VERSION) and
                            !std.mem.eql(u8, started.schema_version, observation.SCHEMA_VERSION_V1))
                            return error.InvalidRecord;
                        if (!validReplayPolicy(started.replay)) return error.InvalidRecord;
                        const key = dispatchKey(started.id);
                        if (seen_dispatches.contains(key)) return error.InvalidRecord;
                        if (pending_rule_filters.fetchRemove(ruleFilterKey(
                            started.id,
                            .pre,
                        ))) |entry| {
                            if (entry.value.phase != .pre or
                                entry.value.checker_rule_count != 0)
                                return error.InvalidRecord;
                        } else if (rule_filter_identities.contains(key) and
                            formal_dispatches.get(key) == null)
                        {
                            return error.InvalidRecord;
                        }
                        try seen_dispatches.put(key, 0);
                        const formal_state = formal_dispatches.getPtr(key);
                        if (formal_state) |state| {
                            if (state.terminal_pre or state.pre_count == 0 or
                                state.started or state.batch_open or
                                state.validating_recovery)
                                return error.InvalidRecord;
                            state.started = true;
                        }
                        const entry = try open_dispatches.getOrPut(key);
                        if (entry.found_existing) return error.InvalidRecord;
                        last_dispatch_key = key;
                        last_dispatch_name_len = @min(started.dispatched_name.len, last_dispatch_name_buf.len);
                        @memcpy(last_dispatch_name_buf[0..last_dispatch_name_len], started.dispatched_name[0..last_dispatch_name_len]);
                        entry.value_ptr.* = .{
                            .identity = dispatchIdentity(
                                started.requested_name,
                                started.dispatched_name,
                                started.origin,
                                started.agent_depth,
                            ),
                            .governed = formal_state != null,
                            .expected_post_count = if (formal_state) |state| state.pre_count else 0,
                            .post_count = 0,
                            .terminal_post = false,
                            .post_batch_open = false,
                            .post_batch_seen = false,
                        };
                    },
                    .dispatch_finished => |finished| {
                        if (!std.mem.eql(u8, finished.schema_version, observation.SCHEMA_VERSION) and
                            !std.mem.eql(u8, finished.schema_version, observation.SCHEMA_VERSION_V1))
                            return error.InvalidRecord;
                        const entry = open_dispatches.fetchRemove(dispatchKey(finished.id)) orelse
                            return error.InvalidRecord;
                        if (pending_rule_filters.fetchRemove(ruleFilterKey(
                            finished.id,
                            .post,
                        ))) |filter_entry| {
                            if (filter_entry.value.phase != .post or
                                filter_entry.value.checker_rule_count != 0)
                                return error.InvalidRecord;
                        } else if (rule_filter_identities.contains(dispatchKey(finished.id)) and
                            formal_dispatches.get(dispatchKey(finished.id)) == null)
                        {
                            return error.InvalidRecord;
                        }
                        if (!std.meta.eql(entry.value.identity, dispatchIdentity(
                            finished.requested_name,
                            finished.dispatched_name,
                            finished.origin,
                            finished.agent_depth,
                        )) or entry.value.post_batch_open or
                            (entry.value.governed and
                                (entry.value.post_count == 0 or
                                    (!entry.value.terminal_post and
                                        entry.value.post_count != entry.value.expected_post_count))))
                            return error.InvalidRecord;
                    },
                }
            },
            .run_finished => {
                const current = active_run orelse return error.InvalidRecord;
                last_closed_run_started_wall_ns = active_started_wall_ns;
                if (!std.mem.eql(u8, current.asSlice(), run_id.asSlice()) or
                    envelope.monotonic_elapsed_ns < active_elapsed_ns or
                    open_dispatches.count() != 0 or open_provider_attempts.count() != 0 or
                    pending_rule_filters.count() != 0)
                    return error.InvalidRecord;
                var formal_states = formal_dispatches.valueIterator();
                while (formal_states.next()) |state| {
                    // A pre block/fault is a complete no-dispatch outcome.  A
                    // set of all-admit pre decisions without a subsequent real
                    // dispatch is not a closed control loop.
                    if (!state.started and !state.terminal_pre)
                        return error.InvalidRecord;
                }
                if (expected_binding) |binding| {
                    if (std.mem.eql(u8, binding.run_id.asSlice(), run_id.asSlice())) {
                        if (!binding_started or binding_finished or
                            envelope.sequence != binding.last_sequence)
                            return error.InvalidRunBinding;
                        binding_hasher.update(line);
                        binding_hasher.update("\n");
                        binding_finished = true;
                    }
                }
                active_run = null;
                active_elapsed_ns = 0;
                seen_dispatches.clearRetainingCapacity();
                formal_events.clearRetainingCapacity();
                pre_decisions.clearRetainingCapacity();
                formal_dispatches.clearRetainingCapacity();
                rule_filter_identities.clearRetainingCapacity();
            },
            .run_abandoned => |abandoned| {
                // Written by a later process for exactly the Run still open,
                // at that Run's last monotonic time, counting what it left open.
                const current = active_run orelse return error.InvalidRecord;
                const recovered_by = session_id_mod.SessionId.fromSlice(abandoned.recovered_by_run_id) orelse
                    return error.InvalidRecord;
                last_closed_run_started_wall_ns = active_started_wall_ns;
                if (!std.mem.eql(u8, envelope.schema_version, SCHEMA_VERSION) or
                    !std.mem.eql(u8, current.asSlice(), run_id.asSlice()) or
                    std.mem.eql(u8, recovered_by.asSlice(), run_id.asSlice()) or
                    envelope.monotonic_elapsed_ns != active_elapsed_ns or
                    abandoned.open_dispatches != open_dispatches.count() or
                    abandoned.open_provider_attempts != open_provider_attempts.count())
                    return error.InvalidRecord;
                // Its open effects stay unresolved: never an evidence interval.
                if (expected_binding) |binding| {
                    if (std.mem.eql(u8, binding.run_id.asSlice(), run_id.asSlice()))
                        return error.InvalidRunBinding;
                }
                active_run = null;
                active_elapsed_ns = 0;
                open_dispatches.clearRetainingCapacity();
                open_provider_attempts.clearRetainingCapacity();
                pending_rule_filters.clearRetainingCapacity();
                seen_dispatches.clearRetainingCapacity();
                formal_events.clearRetainingCapacity();
                pre_decisions.clearRetainingCapacity();
                formal_dispatches.clearRetainingCapacity();
                rule_filter_identities.clearRetainingCapacity();
            },
        }
        expected_sequence += 1;
    }
    if (expected_binding != null and (!binding_started or !binding_finished))
        return error.InvalidRunBinding;
    if (interval_sha256_out) |out| {
        var raw: [32]u8 = undefined;
        binding_hasher.final(&raw);
        out.* = std.fmt.bytesToHex(raw, .lower);
    }
    const reducer_complete = recovery.state == .idle;
    if (reducer_complete != (active_run == null)) return error.InvalidRecord;
    const open_run: ?OpenRun = if (active_run) |run_id| blk: {
        var run: OpenRun = .{
            .run_id = run_id,
            .started_wall_ns = active_started_wall_ns,
            .last_elapsed_ns = active_elapsed_ns,
            .open_dispatches = open_dispatches.count(),
            .open_provider_attempts = open_provider_attempts.count(),
        };
        if (last_dispatch_key) |key| if (open_dispatches.contains(key)) {
            @memcpy(run.open_tool_buf[0..last_dispatch_name_len], last_dispatch_name_buf[0..last_dispatch_name_len]);
            run.open_tool_len = last_dispatch_name_len;
        };
        break :blk run;
    } else null;
    return .{
        .records = expected_sequence,
        .bytes = size,
        .complete = reducer_complete,
        .artifact_sha256 = observation.sha256Hex(bytes),
        .open_run = open_run,
        .last_closed_run_started_wall_ns = last_closed_run_started_wall_ns,
    };
}

fn dispatchKey(id: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &digest, .{});
    return digest;
}

fn ruleFilterKey(id: []const u8, phase: observation.FormalPhase) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("metacodes-project-rule-filter-key-v1\x00");
    hasher.update(id);
    hasher.update(&.{@intFromEnum(phase)});
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn validateRuleFilter(
    identities: *std.AutoHashMap([32]u8, RuleFilterIdentity),
    filter: @FieldType(observation.Event, "rule_filter"),
) !void {
    if (!std.mem.eql(u8, filter.schema_version, observation.RULE_FILTER_SCHEMA_VERSION) or
        filter.dispatch_id.len == 0 or filter.dispatch_id.len > 256 or
        !std.mem.eql(
            u8,
            filter.proof,
            "MetaCodesControl.ProjectRule.target_mismatch_admits_both",
        ) or
        filter.bundle_revision == 0 or filter.active_rule_count == 0 or
        filter.checker_rule_count > filter.active_rule_count or
        filter.statically_pruned_rule_count !=
            filter.active_rule_count - filter.checker_rule_count or
        !validHex(filter.project_sha256) or !validHex(filter.bundle_sha256) or
        !validHex(filter.kernel_sha256) or
        (filter.operation == .exact_edit_recovery and filter.checker_rule_count == 0))
        return error.InvalidRecord;
    const identity = RuleFilterIdentity{
        .project_sha256 = filter.project_sha256,
        .bundle_sha256 = filter.bundle_sha256,
        .bundle_revision = filter.bundle_revision,
        .kernel_sha256 = filter.kernel_sha256,
        .active_rule_count = filter.active_rule_count,
    };
    const entry = try identities.getOrPut(dispatchKey(filter.dispatch_id));
    if (entry.found_existing) {
        if (!std.meta.eql(entry.value_ptr.*, identity)) return error.InvalidRecord;
    } else {
        entry.value_ptr.* = identity;
    }
}

fn validHex(value: [64]u8) bool {
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn validPromptRecord(prompt: PromptRecord) bool {
    if (!validHex(prompt.sha256) or prompt.sections.len > MAX_PROMPT_RECORD_SECTIONS) return false;
    for (prompt.sections, 0..) |section, index| {
        if (!validHex(section.sha256) or
            !(std.mem.startsWith(u8, section.id, prompt_sections.kernel_prefix) or
                std.mem.startsWith(u8, section.id, prompt_sections.host_prefix)))
            return false;
        if (index != 0) {
            const previous = prompt.sections[index - 1];
            if (previous.order > section.order or
                (previous.order == section.order and std.mem.order(u8, previous.id, section.id) != .lt))
                return false;
        }
    }
    return true;
}

fn validReplayPolicy(policy: execution_effect.ReplayPolicy) bool {
    return switch (policy) {
        .never, .read_only => true,
        .idempotent => |key| validHex(key.bytes) and !std.mem.allEqual(u8, &key.bytes, '0'),
        .reobservable => |receipt| validHex(receipt.receipt_sha256) and
            !std.mem.allEqual(u8, &receipt.receipt_sha256, '0'),
    };
}

fn validCheckerFailure(value: ?[]const u8) bool {
    const name = value orelse return false;
    const kind = std.meta.stringToEnum(
        @import("../formal/project_harness_runtime.zig").FailureKind,
        name,
    ) orelse return false;
    return kind != .none;
}

const DispatchIdentity = struct {
    requested_sha256: [32]u8,
    dispatched_sha256: [32]u8,
    origin: observation.Origin,
    agent_depth: u8,
};

const FormalControlIdentity = struct {
    project_sha256: [64]u8,
    bundle_sha256: [64]u8,
    bundle_revision: u64,
    kernel_sha256: [64]u8,
    actuation: observation.FormalActuation,
};

const RuleFilterIdentity = struct {
    project_sha256: [64]u8,
    bundle_sha256: [64]u8,
    bundle_revision: u64,
    kernel_sha256: [64]u8,
    active_rule_count: u32,
};

const PendingRuleFilter = struct {
    phase: observation.FormalPhase,
    operation: observation.RuleFilterOperation,
    identity: RuleFilterIdentity,
    checker_rule_count: u32,

    fn from(filter: @FieldType(observation.Event, "rule_filter")) PendingRuleFilter {
        return .{
            .phase = filter.phase,
            .operation = filter.operation,
            .identity = .{
                .project_sha256 = filter.project_sha256,
                .bundle_sha256 = filter.bundle_sha256,
                .bundle_revision = filter.bundle_revision,
                .kernel_sha256 = filter.kernel_sha256,
                .active_rule_count = filter.active_rule_count,
            },
            .checker_rule_count = filter.checker_rule_count,
        };
    }

    fn matchesBatch(
        self: PendingRuleFilter,
        batch: @FieldType(observation.Event, "formal_decision_batch"),
    ) bool {
        if (self.phase != batch.phase or
            self.checker_rule_count != batch.checker_batch_size or
            !std.mem.eql(u8, &self.identity.project_sha256, &batch.project_sha256) or
            !std.mem.eql(u8, &self.identity.bundle_sha256, &batch.bundle_sha256) or
            self.identity.bundle_revision != batch.bundle_revision or
            !std.mem.eql(u8, &self.identity.kernel_sha256, &batch.kernel_sha256))
            return false;
        var saw_recovery = false;
        for (batch.decisions) |decision| {
            if (decision.operation.isRecovery()) saw_recovery = true;
        }
        return (self.operation == .exact_edit_recovery) == saw_recovery;
    }
};

const FormalDispatchState = struct {
    identity: FormalControlIdentity,
    /// Number of candidate admissions in the latest pre-dispatch generation.
    /// A governed rewrite starts a new generation; the denied Write generation
    /// must not inflate the Edit generation's required post cardinality.
    pre_count: u32,
    terminal_pre: bool,
    started: bool,
    generation: u32,
    pending_recovery_candidate: ?[64]u8,
    validating_recovery: bool,
    recovery_seen: bool,
    batch_open: bool,
};

const PreDecision = struct {
    identity: FormalControlIdentity,
    result: observation.FormalResult,
    generation: u32,
    post_seen: bool,
};

const OpenDispatch = struct {
    identity: DispatchIdentity,
    governed: bool,
    expected_post_count: u32,
    post_count: u32,
    terminal_post: bool,
    post_batch_open: bool,
    post_batch_seen: bool,
};

const FormalRecord = struct {
    dispatch_id: []const u8,
    phase: observation.FormalPhase,
    operation: observation.FormalOperation,
    actuation: observation.FormalActuation,
    result: observation.FormalResult,
    recovery_action: observation.FormalRecoveryAction,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    bundle_sha256: [64]u8,
    bundle_revision: u64,
    kernel_sha256: [64]u8,
    request_sha256: [64]u8,
    checker_call_sha256: ?[64]u8,
    checker_verdict_sha256: ?[64]u8,
    checker_batch_size: u32,
    verdict_sha256: ?[64]u8,
    checker_failure: ?[]const u8,
    checker_bytes: u64,
    is_batch: bool,
};

const FormalBatchBoundary = struct {
    is_batch: bool,
    first: bool,
    last: bool,
};

const FormalValidationState = struct {
    open_dispatches: *std.AutoHashMap([32]u8, OpenDispatch),
    seen_dispatches: *std.AutoHashMap([32]u8, u8),
    formal_events: *std.AutoHashMap([32]u8, u8),
    pre_decisions: *std.AutoHashMap([32]u8, PreDecision),
    formal_dispatches: *std.AutoHashMap([32]u8, FormalDispatchState),
};

fn acceptFormalDecision(
    state: *FormalValidationState,
    formal: FormalRecord,
    boundary: FormalBatchBoundary,
) !void {
    if (formal.dispatch_id.len == 0 or formal.dispatch_id.len > 256 or
        formal.operation.phase() != formal.phase or
        formal.bundle_revision == 0 or
        !validHex(formal.candidate_id) or
        !validHex(formal.project_sha256) or
        !validHex(formal.bundle_sha256) or
        !validHex(formal.kernel_sha256) or
        !validHex(formal.request_sha256) or
        formal.checker_batch_size == 0 or
        formal.checker_batch_size > @import("../formal/project_harness_runtime.zig").MAX_BATCH_REQUESTS or
        (formal.checker_call_sha256 != null and !validHex(formal.checker_call_sha256.?)) or
        (formal.checker_verdict_sha256 != null and !validHex(formal.checker_verdict_sha256.?)) or
        (formal.is_batch and formal.checker_call_sha256 == null))
        return error.InvalidRecord;
    switch (formal.result) {
        .admit, .block => if (formal.verdict_sha256 == null or
            !validHex(formal.verdict_sha256.?) or
            formal.checker_failure != null or formal.checker_bytes == 0 or
            (formal.is_batch and formal.checker_verdict_sha256 == null))
            return error.InvalidRecord,
        .fault => if (!validCheckerFailure(formal.checker_failure) or
            formal.verdict_sha256 != null or
            (formal.is_batch and formal.checker_verdict_sha256 != null))
            return error.InvalidRecord,
    }
    const dispatch_key = dispatchKey(formal.dispatch_id);
    const event_key = formalEventKey(
        formal.dispatch_id,
        formal.candidate_id,
        formal.operation,
        formal.request_sha256,
    );
    if (state.formal_events.contains(event_key)) return error.InvalidRecord;
    try state.formal_events.put(event_key, 0);
    const identity = FormalControlIdentity{
        .project_sha256 = formal.project_sha256,
        .bundle_sha256 = formal.bundle_sha256,
        .bundle_revision = formal.bundle_revision,
        .kernel_sha256 = formal.kernel_sha256,
        .actuation = formal.actuation,
    };
    switch (formal.phase) {
        .pre => {
            if (state.seen_dispatches.contains(dispatch_key) or
                state.open_dispatches.contains(dispatch_key))
                return error.InvalidRecord;
            const state_entry = try state.formal_dispatches.getOrPut(dispatch_key);
            if (!state_entry.found_existing) {
                if (boundary.is_batch and !boundary.first)
                    return error.InvalidRecord;
                state_entry.value_ptr.* = .{
                    .identity = identity,
                    .pre_count = 0,
                    .terminal_pre = false,
                    .started = false,
                    .generation = 0,
                    .pending_recovery_candidate = null,
                    .validating_recovery = false,
                    .recovery_seen = false,
                    .batch_open = boundary.is_batch,
                };
            } else {
                const dispatch_state = state_entry.value_ptr;
                if (!std.meta.eql(dispatch_state.identity, identity) or
                    dispatch_state.started)
                    return error.InvalidRecord;
                if (boundary.is_batch and boundary.first) {
                    // The only legal second pre batch is the explicit recovery
                    // transition selected by the preceding enforced block.
                    if (dispatch_state.batch_open or
                        !dispatch_state.terminal_pre or
                        dispatch_state.pending_recovery_candidate == null)
                        return error.InvalidRecord;
                    dispatch_state.generation = std.math.add(
                        u32,
                        dispatch_state.generation,
                        1,
                    ) catch return error.InvalidRecord;
                    dispatch_state.pre_count = 0;
                    dispatch_state.terminal_pre = false;
                    dispatch_state.validating_recovery = true;
                    dispatch_state.recovery_seen = false;
                    dispatch_state.batch_open = true;
                } else if (boundary.is_batch) {
                    if (!dispatch_state.batch_open or dispatch_state.terminal_pre)
                        return error.InvalidRecord;
                } else if (dispatch_state.batch_open or
                    dispatch_state.terminal_pre or
                    dispatch_state.validating_recovery)
                    return error.InvalidRecord;
            }
            const dispatch_state = state_entry.value_ptr;
            if (formal.operation.isRecovery()) {
                // Product auto-recovery starts a second generation under the
                // original Write id.  Direct/embedding callers deliberately
                // default auto-recovery off, so their model-authored Edit uses
                // a fresh id.  Preserve that public path, but accept its
                // recovery operation only when this run already contains an
                // outstanding enforced recovery direction for the exact
                // candidate and control identity.  Move that obligation to the
                // new dispatch rather than merely observing it: a successful
                // recovery must not leave stale authority behind, while a
                // retry-eligible block can explicitly transfer it again.
                // A bare recovery label is not authority.
                if (!dispatch_state.validating_recovery) {
                    if (!takePendingRecoveryCandidate(
                        state.formal_dispatches,
                        formal.candidate_id,
                        identity,
                    )) return error.InvalidRecord;
                    dispatch_state.validating_recovery = true;
                    dispatch_state.pending_recovery_candidate = formal.candidate_id;
                }
                const expected = dispatch_state.pending_recovery_candidate orelse
                    return error.InvalidRecord;
                if (dispatch_state.recovery_seen or
                    !std.mem.eql(u8, &expected, &formal.candidate_id))
                    return error.InvalidRecord;
                dispatch_state.recovery_seen = true;
            } else if (formal.operation != .pre_decision) {
                return error.InvalidRecord;
            }
            dispatch_state.pre_count = std.math.add(
                u32,
                dispatch_state.pre_count,
                1,
            ) catch return error.InvalidRecord;
            const pair_key = formalPairKey(
                formal.dispatch_id,
                formal.candidate_id,
                formal.operation,
            );
            if (state.pre_decisions.get(pair_key)) |prior| {
                if (prior.generation == dispatch_state.generation)
                    return error.InvalidRecord;
            }
            try state.pre_decisions.put(pair_key, .{
                .identity = identity,
                .result = formal.result,
                .generation = dispatch_state.generation,
                .post_seen = false,
            });
            if (formal.actuation == .enforced and formal.result != .admit) {
                dispatch_state.terminal_pre = true;
                dispatch_state.pending_recovery_candidate =
                    if (formal.result == .block and
                    formal.recovery_action == .edit_existing_file_exact and
                    (!dispatch_state.validating_recovery or
                        formal.operation == .recovery_pre_decision))
                        formal.candidate_id
                    else
                        null;
            }
            if (boundary.is_batch and boundary.last) {
                if (!dispatch_state.batch_open or
                    (dispatch_state.validating_recovery and
                        !dispatch_state.recovery_seen))
                    return error.InvalidRecord;
                dispatch_state.batch_open = false;
                if (dispatch_state.validating_recovery) {
                    dispatch_state.validating_recovery = false;
                    if (!dispatch_state.terminal_pre)
                        dispatch_state.pending_recovery_candidate = null;
                } else if (!dispatch_state.terminal_pre) {
                    dispatch_state.pending_recovery_candidate = null;
                }
            }
        },
        .post => {
            const opened = state.open_dispatches.getPtr(dispatch_key) orelse
                return error.InvalidRecord;
            const dispatch_state = state.formal_dispatches.get(dispatch_key) orelse
                return error.InvalidRecord;
            if (boundary.is_batch and boundary.first) {
                if (opened.post_batch_open or opened.post_batch_seen or
                    opened.post_count != 0)
                    return error.InvalidRecord;
                opened.post_batch_open = true;
                opened.post_batch_seen = true;
            } else if (boundary.is_batch) {
                if (!opened.post_batch_open) return error.InvalidRecord;
            } else if (opened.post_batch_open or opened.post_batch_seen) {
                return error.InvalidRecord;
            }
            const pair_key = formalPairKey(
                formal.dispatch_id,
                formal.candidate_id,
                formal.operation,
            );
            const prior = state.pre_decisions.getPtr(pair_key) orelse
                return error.InvalidRecord;
            if (!opened.governed or opened.terminal_post or
                (formal.actuation == .enforced and prior.result != .admit) or
                prior.generation != dispatch_state.generation or
                prior.post_seen or
                !std.meta.eql(prior.identity, identity) or
                !std.meta.eql(dispatch_state.identity, identity))
                return error.InvalidRecord;
            prior.post_seen = true;
            opened.post_count = std.math.add(u32, opened.post_count, 1) catch
                return error.InvalidRecord;
            if (opened.post_count > opened.expected_post_count)
                return error.InvalidRecord;
            if (formal.actuation == .enforced and formal.result != .admit)
                opened.terminal_post = true;
            if (boundary.is_batch and boundary.last) {
                if (!opened.post_batch_open) return error.InvalidRecord;
                opened.post_batch_open = false;
            }
        },
    }
}

/// Consume exactly one outstanding direction and transfer it to a fresh
/// recovery dispatch.  Matching the complete control identity prevents a rule
/// from borrowing an obligation emitted under another project, bundle revision,
/// kernel, or actuation mode.  Candidate identity alone is not sufficient.
fn takePendingRecoveryCandidate(
    formal_dispatches: *std.AutoHashMap([32]u8, FormalDispatchState),
    candidate_id: [64]u8,
    identity: FormalControlIdentity,
) bool {
    var states = formal_dispatches.valueIterator();
    while (states.next()) |state| {
        const pending = state.pending_recovery_candidate orelse continue;
        if (state.terminal_pre and !state.started and
            std.meta.eql(state.identity, identity) and
            std.mem.eql(u8, &pending, &candidate_id))
        {
            state.pending_recovery_candidate = null;
            return true;
        }
    }
    return false;
}

fn formalIdentity(formal: anytype) FormalControlIdentity {
    return .{
        .project_sha256 = formal.project_sha256,
        .bundle_sha256 = formal.bundle_sha256,
        .bundle_revision = formal.bundle_revision,
        .kernel_sha256 = formal.kernel_sha256,
        .actuation = formal.actuation,
    };
}

fn standardFormalOperation(
    phase: observation.FormalPhase,
) observation.FormalOperation {
    return switch (phase) {
        .pre => .pre_decision,
        .post => .post_decision,
    };
}

fn formalEventKey(
    dispatch_id: []const u8,
    candidate_id: [64]u8,
    operation: observation.FormalOperation,
    request_sha256: [64]u8,
) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("metacodes-formal-event-key-v3\x00");
    hasher.update(dispatch_id);
    hasher.update("\x00");
    hasher.update(&candidate_id);
    hasher.update(&.{@intFromEnum(operation)});
    hasher.update(&request_sha256);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn formalPairKey(
    dispatch_id: []const u8,
    candidate_id: [64]u8,
    operation: observation.FormalOperation,
) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("metacodes-formal-pair-key-v1\x00");
    hasher.update(dispatch_id);
    hasher.update("\x00");
    hasher.update(&candidate_id);
    hasher.update(&.{@intFromBool(operation.isRecovery())});
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn dispatchIdentity(
    requested_name: []const u8,
    dispatched_name: []const u8,
    origin: observation.Origin,
    agent_depth: u8,
) DispatchIdentity {
    var requested: [32]u8 = undefined;
    var dispatched: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(requested_name, &requested, .{});
    std.crypto.hash.sha2.Sha256.hash(dispatched_name, &dispatched, .{});
    return .{
        .requested_sha256 = requested,
        .dispatched_sha256 = dispatched,
        .origin = origin,
        .agent_depth = agent_depth,
    };
}

fn writeAll(fd: pfs.Fd, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = pfs.write(fd, bytes[offset..]);
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}

fn fsyncDirectory(directory: []const u8) !void {
    if (@import("builtin").os.tag == .windows) return;
    const path_z = try std.heap.c_allocator.dupeZ(u8, directory);
    defer std.heap.c_allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.DirectoryOpenFailed;
    defer _ = pfs.close(fd);
    try pfs.fsyncChecked(fd);
}

fn elapsedNs(started_ns: i128) u64 {
    const now = util_time.nowNs();
    if (now <= started_ns) return 0;
    const delta: u128 = @intCast(now - started_ns);
    return @intCast(@min(delta, std.math.maxInt(u64)));
}

fn testFormalEvent(
    dispatch_id: []const u8,
    phase: observation.FormalPhase,
    result: observation.FormalResult,
) observation.Event {
    return testFormalEventFor('a', dispatch_id, phase, result);
}

fn testFormalEventFor(
    candidate_byte: u8,
    dispatch_id: []const u8,
    phase: observation.FormalPhase,
    result: observation.FormalResult,
) observation.Event {
    return testFormalEventForActuation(
        candidate_byte,
        dispatch_id,
        phase,
        result,
        .enforced,
    );
}

fn testFormalEventForActuation(
    candidate_byte: u8,
    dispatch_id: []const u8,
    phase: observation.FormalPhase,
    result: observation.FormalResult,
    actuation: observation.FormalActuation,
) observation.Event {
    return .{ .formal_decision = .{
        .dispatch_id = dispatch_id,
        .phase = phase,
        .actuation = actuation,
        .result = result,
        .candidate_id = .{candidate_byte} ** 64,
        .project_sha256 = .{'b'} ** 64,
        .bundle_sha256 = .{'c'} ** 64,
        .bundle_revision = 1,
        .kernel_sha256 = .{'d'} ** 64,
        .request_sha256 = .{'e'} ** 64,
        .verdict_sha256 = if (result == .fault) null else .{'f'} ** 64,
        .checker_failure = if (result == .fault) "spawn_failed" else null,
        .checker_elapsed_ns = 1,
        .checker_bytes = if (result == .fault) 0 else 1,
    } };
}

fn testFormalBatchEvent(
    dispatch_id: []const u8,
    phase: observation.FormalPhase,
    batch_size: u32,
    decisions: []const observation.FormalCandidateDecision,
) observation.Event {
    var result = observation.Event{ .formal_decision_batch = .{
        .dispatch_id = dispatch_id,
        .phase = phase,
        .project_sha256 = .{'b'} ** 64,
        .bundle_sha256 = .{'c'} ** 64,
        .bundle_revision = 1,
        .kernel_sha256 = .{'d'} ** 64,
        .checker_call_sha256 = if (phase == .pre) .{'1'} ** 64 else .{'2'} ** 64,
        .checker_verdict_sha256 = if (phase == .pre) .{'3'} ** 64 else .{'4'} ** 64,
        .checker_batch_size = batch_size,
        .checker_elapsed_ns = 1,
        .checker_bytes = 1,
        .decisions = decisions,
    } };
    // Existing validator fixtures predate relevance filters and deliberately
    // exercise the v4 compatibility path. New v5 fixtures opt in explicitly.
    result.formal_decision_batch.schema_version =
        observation.FORMAL_BATCH_SCHEMA_VERSION_V4;
    return result;
}

fn testRuleFilterEvent(
    dispatch_id: []const u8,
    phase: observation.FormalPhase,
    checker_rule_count: u32,
    operation: observation.RuleFilterOperation,
) observation.Event {
    return .{ .rule_filter = .{
        .dispatch_id = dispatch_id,
        .phase = phase,
        .operation = operation,
        .project_sha256 = .{'b'} ** 64,
        .bundle_sha256 = .{'c'} ** 64,
        .bundle_revision = 1,
        .kernel_sha256 = .{'d'} ** 64,
        .active_rule_count = 2,
        .checker_rule_count = checker_rule_count,
        .statically_pruned_rule_count = 2 - checker_rule_count,
    } };
}

fn testCurrentFormalBatchEvent(
    dispatch_id: []const u8,
    phase: observation.FormalPhase,
    batch_size: u32,
    decisions: []const observation.FormalCandidateDecision,
) observation.Event {
    var result = testFormalBatchEvent(dispatch_id, phase, batch_size, decisions);
    result.formal_decision_batch.schema_version = observation.FORMAL_BATCH_SCHEMA_VERSION;
    return result;
}

fn testDispatchStart(id: []const u8) observation.Event {
    return .{ .dispatch_started = .{
        .id = id,
        .requested_name = "Write",
        .dispatched_name = "Write",
        .origin = .authoritative,
        .agent_depth = 0,
        .input_bytes = 2,
        .input_sha256 = observation.sha256Hex("{}"),
    } };
}

fn testDispatchFinish(id: []const u8) observation.Event {
    return .{ .dispatch_finished = .{
        .id = id,
        .requested_name = "Write",
        .dispatched_name = "Write",
        .origin = .authoritative,
        .agent_depth = 0,
        .outcome = .succeeded,
        .error_code = null,
        .elapsed_ms = 1,
        .result_present = true,
        .result_bytes = 2,
        .result_sha256 = observation.sha256Hex("ok"),
        .effect = null,
        .effect_valid = true,
    } };
}

fn writeTestRun(
    directory: []const u8,
    sid: session_id_mod.SessionId,
    events: []const observation.Event,
) !void {
    try util_fs.mkdirParents(directory);
    var journal = try Journal.init(directory, sid);
    for (events) |event| {
        if (!journal.sink().emit(event)) return error.TestJournalRejected;
    }
    try journal.finishRun("end_turn");
    journal.deinit();
}

test "formal journal enforces pre dispatch post finish wiring and permits pre block" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;

    const blocked_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/blocked", .{root});
    defer std.testing.allocator.free(blocked_dir);
    const blocked = [_]observation.Event{testFormalEvent("blocked", .pre, .block)};
    try writeTestRun(blocked_dir, sid, &blocked);
    _ = try validate(blocked_dir, sid);

    const shadow_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/shadow-block", .{root});
    defer std.testing.allocator.free(shadow_dir);
    const shadow = [_]observation.Event{
        testFormalEventForActuation('a', "shadow-block", .pre, .block, .shadow),
        testDispatchStart("shadow-block"),
        testFormalEventForActuation('a', "shadow-block", .post, .block, .shadow),
        testDispatchFinish("shadow-block"),
    };
    try writeTestRun(shadow_dir, sid, &shadow);
    _ = try validate(shadow_dir, sid);

    const mixed_actuation_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/mixed-actuation",
        .{root},
    );
    defer std.testing.allocator.free(mixed_actuation_dir);
    const mixed_actuation = [_]observation.Event{
        testFormalEventForActuation('a', "mixed-actuation", .pre, .block, .shadow),
        testDispatchStart("mixed-actuation"),
        testFormalEvent("mixed-actuation", .post, .block),
        testDispatchFinish("mixed-actuation"),
    };
    try writeTestRun(mixed_actuation_dir, sid, &mixed_actuation);
    try std.testing.expectError(error.InvalidRecord, validate(mixed_actuation_dir, sid));

    const legacy_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/legacy-v1", .{root});
    defer std.testing.allocator.free(legacy_dir);
    var legacy_pre = testFormalEvent("legacy-v1", .pre, .admit);
    legacy_pre.formal_decision.schema_version = observation.FORMAL_SCHEMA_VERSION_V1;
    var legacy_post = testFormalEvent("legacy-v1", .post, .admit);
    legacy_post.formal_decision.schema_version = observation.FORMAL_SCHEMA_VERSION_V1;
    const legacy = [_]observation.Event{
        legacy_pre,
        testDispatchStart("legacy-v1"),
        legacy_post,
        testDispatchFinish("legacy-v1"),
    };
    try writeTestRun(legacy_dir, sid, &legacy);
    _ = try validate(legacy_dir, sid);

    const forged_legacy_shadow_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/legacy-v1-shadow",
        .{root},
    );
    defer std.testing.allocator.free(forged_legacy_shadow_dir);
    var forged_legacy_shadow = testFormalEventForActuation(
        'a',
        "legacy-v1-shadow",
        .pre,
        .block,
        .shadow,
    );
    forged_legacy_shadow.formal_decision.schema_version = observation.FORMAL_SCHEMA_VERSION_V1;
    const forged_legacy_shadow_events = [_]observation.Event{forged_legacy_shadow};
    try writeTestRun(forged_legacy_shadow_dir, sid, &forged_legacy_shadow_events);
    try std.testing.expectError(
        error.InvalidRecord,
        validate(forged_legacy_shadow_dir, sid),
    );

    const forged_shadow_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/enforced-block-dispatched",
        .{root},
    );
    defer std.testing.allocator.free(forged_shadow_dir);
    const forged_shadow = [_]observation.Event{
        testFormalEvent("enforced-block-dispatched", .pre, .block),
        testDispatchStart("enforced-block-dispatched"),
        testFormalEvent("enforced-block-dispatched", .post, .block),
        testDispatchFinish("enforced-block-dispatched"),
    };
    try writeTestRun(forged_shadow_dir, sid, &forged_shadow);
    try std.testing.expectError(error.InvalidRecord, validate(forged_shadow_dir, sid));

    const admitted_only_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/admitted-only", .{root});
    defer std.testing.allocator.free(admitted_only_dir);
    const admitted_only = [_]observation.Event{testFormalEvent("admitted-only", .pre, .admit)};
    try writeTestRun(admitted_only_dir, sid, &admitted_only);
    try std.testing.expectError(error.InvalidRecord, validate(admitted_only_dir, sid));

    const duplicate_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/duplicate", .{root});
    defer std.testing.allocator.free(duplicate_dir);
    const duplicate = [_]observation.Event{
        testFormalEvent("duplicate", .pre, .admit),
        testFormalEvent("duplicate", .pre, .admit),
    };
    try writeTestRun(duplicate_dir, sid, &duplicate);
    try std.testing.expectError(error.InvalidRecord, validate(duplicate_dir, sid));

    const missing_post_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing-post", .{root});
    defer std.testing.allocator.free(missing_post_dir);
    const missing_post = [_]observation.Event{
        testFormalEvent("missing-post", .pre, .admit),
        testDispatchStart("missing-post"),
        testDispatchFinish("missing-post"),
    };
    try writeTestRun(missing_post_dir, sid, &missing_post);
    try std.testing.expectError(error.InvalidRecord, validate(missing_post_dir, sid));

    const complete_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/complete", .{root});
    defer std.testing.allocator.free(complete_dir);
    const complete = [_]observation.Event{
        testFormalEvent("complete", .pre, .admit),
        testDispatchStart("complete"),
        testFormalEvent("complete", .post, .admit),
        testDispatchFinish("complete"),
    };
    try writeTestRun(complete_dir, sid, &complete);
    _ = try validate(complete_dir, sid);

    const batch_pre_decisions = [_]observation.FormalCandidateDecision{
        .{
            .result = .admit,
            .candidate_id = .{'1'} ** 64,
            .request_sha256 = .{'5'} ** 64,
            .verdict_sha256 = .{'6'} ** 64,
            .checker_failure = null,
        },
        .{
            .result = .admit,
            .candidate_id = .{'2'} ** 64,
            .request_sha256 = .{'7'} ** 64,
            .verdict_sha256 = .{'8'} ** 64,
            .checker_failure = null,
        },
    };
    const batch_post_decisions = [_]observation.FormalCandidateDecision{
        .{
            .operation = .post_decision,
            .result = .admit,
            .candidate_id = .{'1'} ** 64,
            .request_sha256 = .{'9'} ** 64,
            .verdict_sha256 = .{'a'} ** 64,
            .checker_failure = null,
        },
        .{
            .operation = .post_decision,
            .result = .admit,
            .candidate_id = .{'2'} ** 64,
            .request_sha256 = .{'b'} ** 64,
            .verdict_sha256 = .{'c'} ** 64,
            .checker_failure = null,
        },
    };
    const batch_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/batch-complete", .{root});
    defer std.testing.allocator.free(batch_dir);
    const batch_complete = [_]observation.Event{
        testFormalBatchEvent("batch-complete", .pre, 2, &batch_pre_decisions),
        testDispatchStart("batch-complete"),
        testFormalBatchEvent("batch-complete", .post, 2, &batch_post_decisions),
        testDispatchFinish("batch-complete"),
    };
    try writeTestRun(batch_dir, sid, &batch_complete);
    _ = try validate(batch_dir, sid);

    const current_batch_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/batch-current",
        .{root},
    );
    defer std.testing.allocator.free(current_batch_dir);
    const current_batch = [_]observation.Event{
        testRuleFilterEvent("batch-current", .pre, 2, .ordinary),
        testCurrentFormalBatchEvent("batch-current", .pre, 2, &batch_pre_decisions),
        testDispatchStart("batch-current"),
        testRuleFilterEvent("batch-current", .post, 2, .ordinary),
        testCurrentFormalBatchEvent("batch-current", .post, 2, &batch_post_decisions),
        testDispatchFinish("batch-current"),
    };
    try writeTestRun(current_batch_dir, sid, &current_batch);
    _ = try validate(current_batch_dir, sid);

    const missing_filter_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/batch-current-missing-filter",
        .{root},
    );
    defer std.testing.allocator.free(missing_filter_dir);
    const missing_filter = [_]observation.Event{
        testCurrentFormalBatchEvent(
            "batch-current-missing-filter",
            .pre,
            2,
            &batch_pre_decisions,
        ),
    };
    try writeTestRun(missing_filter_dir, sid, &missing_filter);
    try std.testing.expectError(error.InvalidRecord, validate(missing_filter_dir, sid));

    const zero_filter_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/zero-filter",
        .{root},
    );
    defer std.testing.allocator.free(zero_filter_dir);
    const zero_filter = [_]observation.Event{
        testRuleFilterEvent("zero-filter", .pre, 0, .ordinary),
        testDispatchStart("zero-filter"),
        testRuleFilterEvent("zero-filter", .post, 0, .ordinary),
        testDispatchFinish("zero-filter"),
    };
    try writeTestRun(zero_filter_dir, sid, &zero_filter);
    _ = try validate(zero_filter_dir, sid);

    const count_mismatch_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/filter-count-mismatch",
        .{root},
    );
    defer std.testing.allocator.free(count_mismatch_dir);
    const count_mismatch = [_]observation.Event{
        testRuleFilterEvent("filter-count-mismatch", .pre, 1, .ordinary),
        testCurrentFormalBatchEvent(
            "filter-count-mismatch",
            .pre,
            2,
            &batch_pre_decisions,
        ),
    };
    try writeTestRun(count_mismatch_dir, sid, &count_mismatch);
    try std.testing.expectError(error.InvalidRecord, validate(count_mismatch_dir, sid));

    const proof_mismatch_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/filter-proof-mismatch",
        .{root},
    );
    defer std.testing.allocator.free(proof_mismatch_dir);
    var wrong_proof = testRuleFilterEvent("filter-proof-mismatch", .pre, 0, .ordinary);
    wrong_proof.rule_filter.proof = "unproved_host_optimization";
    const proof_mismatch = [_]observation.Event{wrong_proof};
    try writeTestRun(proof_mismatch_dir, sid, &proof_mismatch);
    try std.testing.expectError(error.InvalidRecord, validate(proof_mismatch_dir, sid));

    const revision_mismatch_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/filter-revision-mismatch",
        .{root},
    );
    defer std.testing.allocator.free(revision_mismatch_dir);
    var wrong_revision = testRuleFilterEvent(
        "filter-revision-mismatch",
        .pre,
        2,
        .ordinary,
    );
    wrong_revision.rule_filter.bundle_revision = 2;
    const revision_mismatch = [_]observation.Event{
        wrong_revision,
        testCurrentFormalBatchEvent(
            "filter-revision-mismatch",
            .pre,
            2,
            &batch_pre_decisions,
        ),
    };
    try writeTestRun(revision_mismatch_dir, sid, &revision_mismatch);
    try std.testing.expectError(error.InvalidRecord, validate(revision_mismatch_dir, sid));

    const dangling_filter_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/dangling-filter",
        .{root},
    );
    defer std.testing.allocator.free(dangling_filter_dir);
    const dangling_filter = [_]observation.Event{
        testRuleFilterEvent("dangling-filter", .pre, 0, .ordinary),
    };
    try writeTestRun(dangling_filter_dir, sid, &dangling_filter);
    try std.testing.expectError(error.InvalidRecord, validate(dangling_filter_dir, sid));

    // Concurrent tool completion may interleave filter and checker events.
    // The binding is keyed by dispatch and phase rather than being a fragile
    // global "next filter" slot.
    const interleaved_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/interleaved-filters",
        .{root},
    );
    defer std.testing.allocator.free(interleaved_dir);
    const interleaved = [_]observation.Event{
        testRuleFilterEvent("interleaved-a", .pre, 2, .ordinary),
        testRuleFilterEvent("interleaved-b", .pre, 2, .ordinary),
        testCurrentFormalBatchEvent("interleaved-b", .pre, 2, &batch_pre_decisions),
        testCurrentFormalBatchEvent("interleaved-a", .pre, 2, &batch_pre_decisions),
        testDispatchStart("interleaved-a"),
        testDispatchStart("interleaved-b"),
        testRuleFilterEvent("interleaved-a", .post, 2, .ordinary),
        testRuleFilterEvent("interleaved-b", .post, 2, .ordinary),
        testCurrentFormalBatchEvent("interleaved-b", .post, 2, &batch_post_decisions),
        testCurrentFormalBatchEvent("interleaved-a", .post, 2, &batch_post_decisions),
        testDispatchFinish("interleaved-b"),
        testDispatchFinish("interleaved-a"),
    };
    try writeTestRun(interleaved_dir, sid, &interleaved);
    _ = try validate(interleaved_dir, sid);

    const forged_recovery_filter_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/forged-recovery-filter",
        .{root},
    );
    defer std.testing.allocator.free(forged_recovery_filter_dir);
    const forged_recovery_filter = [_]observation.Event{
        testRuleFilterEvent(
            "forged-recovery-filter",
            .pre,
            2,
            .exact_edit_recovery,
        ),
        testCurrentFormalBatchEvent(
            "forged-recovery-filter",
            .pre,
            2,
            &batch_pre_decisions,
        ),
    };
    try writeTestRun(forged_recovery_filter_dir, sid, &forged_recovery_filter);
    try std.testing.expectError(
        error.InvalidRecord,
        validate(forged_recovery_filter_dir, sid),
    );

    const truncated_batch_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/batch-truncated",
        .{root},
    );
    defer std.testing.allocator.free(truncated_batch_dir);
    const truncated_batch = [_]observation.Event{
        testFormalBatchEvent("batch-truncated", .pre, 2, batch_pre_decisions[0..1]),
    };
    try writeTestRun(truncated_batch_dir, sid, &truncated_batch);
    try std.testing.expectError(error.InvalidRecord, validate(truncated_batch_dir, sid));

    const recovery_decisions = [_]observation.FormalCandidateDecision{.{
        .result = .block,
        .recovery_action = .edit_existing_file_exact,
        .candidate_id = .{'1'} ** 64,
        .request_sha256 = .{'5'} ** 64,
        .verdict_sha256 = .{'6'} ** 64,
        .checker_failure = null,
    }};
    var recovery_event = testFormalBatchEvent(
        "batch-recovery",
        .pre,
        1,
        &recovery_decisions,
    );
    recovery_event.formal_decision_batch.file_target_state = .regular_existing;
    const recovery_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/batch-recovery",
        .{root},
    );
    defer std.testing.allocator.free(recovery_dir);
    const recovery_events = [_]observation.Event{recovery_event};
    try writeTestRun(recovery_dir, sid, &recovery_events);
    _ = try validate(recovery_dir, sid);

    // A selected exact recovery is a second pre generation for the same
    // model tool-use id.  Only that latest generation owes post decisions;
    // the denied Write generation remains durable provenance, not an extra
    // post obligation for the host-synthesized Edit.
    const initial_rewrite_decisions = [_]observation.FormalCandidateDecision{
        .{
            .result = .admit,
            .candidate_id = .{'1'} ** 64,
            .request_sha256 = .{'5'} ** 64,
            .verdict_sha256 = .{'6'} ** 64,
            .checker_failure = null,
        },
        .{
            .result = .block,
            .recovery_action = .edit_existing_file_exact,
            .candidate_id = .{'2'} ** 64,
            .request_sha256 = .{'7'} ** 64,
            .verdict_sha256 = .{'8'} ** 64,
            .checker_failure = null,
        },
    };
    const rewrite_pre_decisions = [_]observation.FormalCandidateDecision{
        .{
            .result = .admit,
            .candidate_id = .{'1'} ** 64,
            .request_sha256 = .{'9'} ** 64,
            .verdict_sha256 = .{'a'} ** 64,
            .checker_failure = null,
        },
        .{
            .operation = .recovery_pre_decision,
            .result = .admit,
            .candidate_id = .{'2'} ** 64,
            .request_sha256 = .{'b'} ** 64,
            .verdict_sha256 = .{'c'} ** 64,
            .checker_failure = null,
        },
    };
    const rewrite_post_decisions = [_]observation.FormalCandidateDecision{
        .{
            .operation = .post_decision,
            .result = .admit,
            .candidate_id = .{'1'} ** 64,
            .request_sha256 = .{'d'} ** 64,
            .verdict_sha256 = .{'e'} ** 64,
            .checker_failure = null,
        },
        .{
            .operation = .recovery_post_decision,
            .result = .admit,
            .candidate_id = .{'2'} ** 64,
            .request_sha256 = .{'f'} ** 64,
            .verdict_sha256 = .{'0'} ** 64,
            .checker_failure = null,
        },
    };
    var initial_rewrite = testFormalBatchEvent(
        "exact-rewrite",
        .pre,
        2,
        &initial_rewrite_decisions,
    );
    initial_rewrite.formal_decision_batch.file_target_state = .regular_existing;
    var rewrite_start = testDispatchStart("exact-rewrite");
    rewrite_start.dispatch_started.dispatched_name = "Edit";
    var rewrite_finish = testDispatchFinish("exact-rewrite");
    rewrite_finish.dispatch_finished.dispatched_name = "Edit";
    const exact_rewrite_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/exact-rewrite",
        .{root},
    );
    defer std.testing.allocator.free(exact_rewrite_dir);
    const exact_rewrite_events = [_]observation.Event{
        initial_rewrite,
        testFormalBatchEvent("exact-rewrite", .pre, 2, &rewrite_pre_decisions),
        rewrite_start,
        testFormalBatchEvent("exact-rewrite", .post, 2, &rewrite_post_decisions),
        rewrite_finish,
    };
    try writeTestRun(exact_rewrite_dir, sid, &exact_rewrite_events);
    _ = try validate(exact_rewrite_dir, sid);

    var missing_recovery = rewrite_pre_decisions;
    missing_recovery[1].operation = .pre_decision;
    const missing_recovery_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/missing-recovery-transition",
        .{root},
    );
    defer std.testing.allocator.free(missing_recovery_dir);
    const missing_recovery_events = [_]observation.Event{
        initial_rewrite,
        testFormalBatchEvent("exact-rewrite", .pre, 2, &missing_recovery),
    };
    try writeTestRun(missing_recovery_dir, sid, &missing_recovery_events);
    try std.testing.expectError(error.InvalidRecord, validate(missing_recovery_dir, sid));

    var wrong_recovery = rewrite_pre_decisions;
    wrong_recovery[0].operation = .recovery_pre_decision;
    wrong_recovery[1].operation = .pre_decision;
    const wrong_recovery_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/wrong-recovery-candidate",
        .{root},
    );
    defer std.testing.allocator.free(wrong_recovery_dir);
    const wrong_recovery_events = [_]observation.Event{
        initial_rewrite,
        testFormalBatchEvent("exact-rewrite", .pre, 2, &wrong_recovery),
    };
    try writeTestRun(wrong_recovery_dir, sid, &wrong_recovery_events);
    try std.testing.expectError(error.InvalidRecord, validate(wrong_recovery_dir, sid));

    var stale_source_post = rewrite_post_decisions;
    stale_source_post[1].operation = .post_decision;
    const stale_source_post_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/stale-source-post",
        .{root},
    );
    defer std.testing.allocator.free(stale_source_post_dir);
    const stale_source_post_events = [_]observation.Event{
        initial_rewrite,
        testFormalBatchEvent("exact-rewrite", .pre, 2, &rewrite_pre_decisions),
        rewrite_start,
        testFormalBatchEvent("exact-rewrite", .post, 2, &stale_source_post),
        rewrite_finish,
    };
    try writeTestRun(stale_source_post_dir, sid, &stale_source_post_events);
    try std.testing.expectError(error.InvalidRecord, validate(stale_source_post_dir, sid));

    // Direct/embedding RuntimeGate construction deliberately leaves automatic
    // host synthesis disabled. Its legitimate recovery therefore arrives as
    // a later model-authored Edit with a fresh tool-use id. Keep accepting that
    // public path, but only when an earlier enforced block in this same run
    // selected exact recovery for the same candidate.
    var manual_direction = testFormalBatchEvent(
        "manual-write",
        .pre,
        1,
        &recovery_decisions,
    );
    manual_direction.formal_decision_batch.file_target_state = .regular_existing;
    const manual_recovery_pre_decisions = [_]observation.FormalCandidateDecision{.{
        .operation = .recovery_pre_decision,
        .result = .admit,
        .candidate_id = .{'1'} ** 64,
        .request_sha256 = .{'7'} ** 64,
        .verdict_sha256 = .{'8'} ** 64,
        .checker_failure = null,
    }};
    const manual_recovery_post_decisions = [_]observation.FormalCandidateDecision{.{
        .operation = .recovery_post_decision,
        .result = .admit,
        .candidate_id = .{'1'} ** 64,
        .request_sha256 = .{'9'} ** 64,
        .verdict_sha256 = .{'a'} ** 64,
        .checker_failure = null,
    }};
    var manual_start = testDispatchStart("manual-edit");
    manual_start.dispatch_started.requested_name = "Edit";
    manual_start.dispatch_started.dispatched_name = "Edit";
    var manual_finish = testDispatchFinish("manual-edit");
    manual_finish.dispatch_finished.requested_name = "Edit";
    manual_finish.dispatch_finished.dispatched_name = "Edit";
    const manual_recovery_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/manual-recovery-new-id",
        .{root},
    );
    defer std.testing.allocator.free(manual_recovery_dir);
    const manual_recovery_events = [_]observation.Event{
        manual_direction,
        testFormalBatchEvent(
            "manual-edit",
            .pre,
            1,
            &manual_recovery_pre_decisions,
        ),
        manual_start,
        testFormalBatchEvent(
            "manual-edit",
            .post,
            1,
            &manual_recovery_post_decisions,
        ),
        manual_finish,
    };
    try writeTestRun(manual_recovery_dir, sid, &manual_recovery_events);
    _ = try validate(manual_recovery_dir, sid);

    // The successful recovery consumed the only outstanding direction.  A
    // later recovery-labelled pre decision cannot borrow stale authority from
    // the already completed Edit.
    const consumed_direction_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/manual-recovery-consumed",
        .{root},
    );
    defer std.testing.allocator.free(consumed_direction_dir);
    const consumed_direction_events = [_]observation.Event{
        manual_direction,
        testFormalBatchEvent(
            "manual-edit",
            .pre,
            1,
            &manual_recovery_pre_decisions,
        ),
        manual_start,
        testFormalBatchEvent(
            "manual-edit",
            .post,
            1,
            &manual_recovery_post_decisions,
        ),
        manual_finish,
        testFormalBatchEvent(
            "manual-edit-stale",
            .pre,
            1,
            &manual_recovery_pre_decisions,
        ),
    };
    try writeTestRun(consumed_direction_dir, sid, &consumed_direction_events);
    try std.testing.expectError(
        error.InvalidRecord,
        validate(consumed_direction_dir, sid),
    );

    // A Lean retry direction transfers the same outstanding obligation to the
    // next fresh tool-use id.  This is the direct/embedding compatibility path
    // when automatic host synthesis is disabled.
    const retryable_recovery_pre_decisions = [_]observation.FormalCandidateDecision{.{
        .operation = .recovery_pre_decision,
        .result = .block,
        .recovery_action = .edit_existing_file_exact,
        .candidate_id = .{'1'} ** 64,
        .request_sha256 = .{'b'} ** 64,
        .verdict_sha256 = .{'c'} ** 64,
        .checker_failure = null,
    }};
    var retry_start = manual_start;
    retry_start.dispatch_started.id = "manual-edit-retry";
    var retry_finish = manual_finish;
    retry_finish.dispatch_finished.id = "manual-edit-retry";
    var retryable_recovery_event = testFormalBatchEvent(
        "manual-edit-malformed",
        .pre,
        1,
        &retryable_recovery_pre_decisions,
    );
    retryable_recovery_event.formal_decision_batch.file_target_state =
        .regular_existing;
    const retry_transfer_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/manual-recovery-retry-transfer",
        .{root},
    );
    defer std.testing.allocator.free(retry_transfer_dir);
    const retry_transfer_events = [_]observation.Event{
        manual_direction,
        retryable_recovery_event,
        testFormalBatchEvent(
            "manual-edit-retry",
            .pre,
            1,
            &manual_recovery_pre_decisions,
        ),
        retry_start,
        testFormalBatchEvent(
            "manual-edit-retry",
            .post,
            1,
            &manual_recovery_post_decisions,
        ),
        retry_finish,
    };
    try writeTestRun(retry_transfer_dir, sid, &retry_transfer_events);
    _ = try validate(retry_transfer_dir, sid);

    // Candidate equality cannot bridge a project-rule revision.  The complete
    // formal control identity is part of the outstanding direction.
    var cross_revision_recovery = testFormalBatchEvent(
        "manual-edit-cross-revision",
        .pre,
        1,
        &manual_recovery_pre_decisions,
    );
    cross_revision_recovery.formal_decision_batch.bundle_revision = 2;
    const cross_revision_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/manual-recovery-cross-revision",
        .{root},
    );
    defer std.testing.allocator.free(cross_revision_dir);
    const cross_revision_events = [_]observation.Event{
        manual_direction,
        cross_revision_recovery,
    };
    try writeTestRun(cross_revision_dir, sid, &cross_revision_events);
    try std.testing.expectError(
        error.InvalidRecord,
        validate(cross_revision_dir, sid),
    );

    const forged_manual_recovery_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/manual-recovery-without-direction",
        .{root},
    );
    defer std.testing.allocator.free(forged_manual_recovery_dir);
    const forged_manual_recovery_events = [_]observation.Event{
        testFormalBatchEvent(
            "manual-edit",
            .pre,
            1,
            &manual_recovery_pre_decisions,
        ),
    };
    try writeTestRun(
        forged_manual_recovery_dir,
        sid,
        &forged_manual_recovery_events,
    );
    try std.testing.expectError(
        error.InvalidRecord,
        validate(forged_manual_recovery_dir, sid),
    );

    var forged_legacy_recovery = recovery_event;
    forged_legacy_recovery.formal_decision_batch.schema_version =
        observation.FORMAL_BATCH_SCHEMA_VERSION_V2;
    const legacy_recovery_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/batch-recovery-forged-v2",
        .{root},
    );
    defer std.testing.allocator.free(legacy_recovery_dir);
    const legacy_recovery_events = [_]observation.Event{forged_legacy_recovery};
    try writeTestRun(legacy_recovery_dir, sid, &legacy_recovery_events);
    try std.testing.expectError(error.InvalidRecord, validate(legacy_recovery_dir, sid));

    const multi_missing_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/multi-missing", .{root});
    defer std.testing.allocator.free(multi_missing_dir);
    const multi_missing = [_]observation.Event{
        testFormalEventFor('1', "multi-missing", .pre, .admit),
        testFormalEventFor('2', "multi-missing", .pre, .admit),
        testDispatchStart("multi-missing"),
        testFormalEventFor('1', "multi-missing", .post, .admit),
        testDispatchFinish("multi-missing"),
    };
    try writeTestRun(multi_missing_dir, sid, &multi_missing);
    try std.testing.expectError(error.InvalidRecord, validate(multi_missing_dir, sid));

    // Conjunctive rules short-circuit after a terminal post block/fault.  The
    // remaining admitted pre decisions do not need synthetic post verdicts,
    // but the real dispatch finish must still be present.
    const multi_block_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/multi-block", .{root});
    defer std.testing.allocator.free(multi_block_dir);
    const multi_block = [_]observation.Event{
        testFormalEventFor('1', "multi-block", .pre, .admit),
        testFormalEventFor('2', "multi-block", .pre, .admit),
        testDispatchStart("multi-block"),
        testFormalEventFor('1', "multi-block", .post, .block),
        testDispatchFinish("multi-block"),
    };
    try writeTestRun(multi_block_dir, sid, &multi_block);
    _ = try validate(multi_block_dir, sid);

    // Fault telemetry is authority-bearing evidence, not an arbitrary log
    // string.  Only a real non-`none` runtime FailureKind is admissible.
    const invalid_failure_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/invalid-failure", .{root});
    defer std.testing.allocator.free(invalid_failure_dir);
    var invalid_failure = testFormalEvent("invalid-failure", .pre, .fault);
    invalid_failure.formal_decision.checker_failure = "made_up_failure";
    const invalid_failure_events = [_]observation.Event{invalid_failure};
    try writeTestRun(invalid_failure_dir, sid, &invalid_failure_events);
    try std.testing.expectError(error.InvalidRecord, validate(invalid_failure_dir, sid));
}

test "tool observation journal durably appends, validates, and resumes sequence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;

    var journal = try Journal.init(root, sid);
    const first_run = journal.run_id;
    const sink = journal.sink();
    try std.testing.expect(sink.emit(.{ .dispatch_started = .{
        .id = "tool-1",
        .requested_name = "write_tool",
        .dispatched_name = "Write",
        .origin = .authoritative,
        .agent_depth = 2,
        .input_bytes = 2,
        .input_sha256 = observation.sha256Hex("{}"),
    } }));
    try std.testing.expect(sink.emit(.{ .dispatch_finished = .{
        .id = "tool-1",
        .requested_name = "write_tool",
        .dispatched_name = "Write",
        .origin = .authoritative,
        .agent_depth = 2,
        .outcome = .succeeded,
        .error_code = null,
        .elapsed_ms = 1,
        .result_present = true,
        .result_bytes = 2,
        .result_sha256 = observation.sha256Hex("ok"),
        .effect = null,
        .effect_valid = true,
    } }));
    try journal.finishRun("end_turn");
    const first_binding = try journal.runBinding();
    try std.testing.expect(!sink.emit(.{ .dispatch_started = .{
        .id = "late",
        .requested_name = "Read",
        .dispatched_name = "Read",
        .origin = .authoritative,
        .agent_depth = 0,
        .input_bytes = 0,
        .input_sha256 = observation.sha256Hex(""),
    } }));
    journal.deinit();

    const first = try validate(root, sid);
    try std.testing.expectEqual(@as(u64, 4), first.records);
    try std.testing.expect(first.complete);
    const bound = try validateRunBinding(root, first_binding);
    try std.testing.expectEqual(@as(u64, 4), bound.summary.records);
    try std.testing.expectEqualSlices(u8, &first.artifact_sha256, &bound.interval_sha256);
    var wrong_binding = first_binding;
    wrong_binding.last_sequence -= 1;
    try std.testing.expectError(error.InvalidRunBinding, validateRunBinding(root, wrong_binding));

    var resumed = try Journal.init(root, sid);
    defer resumed.deinit();
    try std.testing.expect(!std.mem.eql(u8, first_run.asSlice(), resumed.runId()));
    try resumed.finishRun("end_turn");
    const second = try validate(root, sid);
    try std.testing.expectEqual(@as(u64, 6), second.records);
    try std.testing.expect(second.complete);
    try std.testing.expect(second.bytes > first.bytes);
    try std.testing.expect(!std.mem.eql(u8, &second.artifact_sha256, &first.artifact_sha256));
    const rebound = try validateRunBinding(root, first_binding);
    try std.testing.expectEqualSlices(u8, &bound.interval_sha256, &rebound.interval_sha256);
}

test "provider physical attempt shares run journal and preserves unknown versus known usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;

    var journal = try Journal.init(root, sid);
    defer journal.deinit();
    const boundary = journal.executionBoundary();
    const request_sha256 = execution_effect.sha256Hex(&.{"canonical-request"});
    const first_id = execution_effect.providerAttemptId(sid.bytes, request_sha256, 1, 0, 1);
    const second_id = execution_effect.providerAttemptId(sid.bytes, request_sha256, 1, 0, 2);
    try std.testing.expect(boundary.emit(.{ .before = .{ .provider_request = .{
        .attempt_id = first_id,
        .actor_id = sid.bytes,
        .request_sha256 = request_sha256,
        .logical_turn = 1,
        .context_generation = 0,
        .physical_attempt = 1,
        .max_attempts = 2,
    } } }));
    try std.testing.expect(boundary.emit(.{ .after = .{ .provider_request = .{
        .attempt_id = first_id,
        .outcome = .api_error,
        .metering = .unknown,
    } } }));
    try std.testing.expect(boundary.emit(.{ .before = .{ .provider_request = .{
        .attempt_id = second_id,
        .actor_id = sid.bytes,
        .request_sha256 = request_sha256,
        .logical_turn = 1,
        .context_generation = 0,
        .physical_attempt = 2,
        .max_attempts = 2,
    } } }));
    try std.testing.expect(boundary.emit(.{ .after = .{ .provider_request = .{
        .attempt_id = second_id,
        .outcome = .succeeded,
        .metering = .{ .known = .{
            .input_tokens = 11,
            .output_tokens = 7,
            .cache_read_input_tokens = 5,
            .cache_creation_input_tokens = 3,
        } },
    } } }));
    try journal.finishRun("end_turn");

    var loaded = try loadRunDispatches(std.testing.allocator, root, try journal.runBinding());
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.provider_attempts.len);
    try std.testing.expect(loaded.provider_attempts[0].outcome == .api_error);
    try std.testing.expect(loaded.provider_attempts[0].metering == .unknown);
    try std.testing.expect(loaded.provider_attempts[1].outcome == .succeeded);
    const metering = switch (loaded.provider_attempts[1].metering) {
        .known => |usage| usage,
        .unknown => return error.ExpectedKnownMetering,
    };
    try std.testing.expectEqual(@as(u64, 11), metering.input_tokens);
    try std.testing.expectEqual(@as(u64, 5), metering.cache_read_input_tokens);
    try std.testing.expectEqualSlices(
        u8,
        &loaded.provider_attempts[0].request_sha256,
        &loaded.provider_attempts[1].request_sha256,
    );
}

test "a bounded same-turn re-issue reopens one provider attempt id and still validates" {
    // Reproduces a pre-fix journal: a mid-stream failure re-issues the same
    // turn, and because the writer restarted the provider budget at physical
    // attempt 1 the two attempts derived the *same* id. The record is a
    // balanced started → finished → started → finished, so validation must
    // accept it and the Run must stay resumable.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;

    var journal = try Journal.init(root, sid);
    defer journal.deinit();
    const boundary = journal.executionBoundary();
    const request_sha256 = execution_effect.sha256Hex(&.{"canonical-request"});
    const attempt_id = execution_effect.providerAttemptId(sid.bytes, request_sha256, 1, 0, 1);
    try std.testing.expect(boundary.emit(.{ .before = .{ .provider_request = .{
        .attempt_id = attempt_id,
        .actor_id = sid.bytes,
        .request_sha256 = request_sha256,
        .logical_turn = 1,
        .context_generation = 0,
        .physical_attempt = 1,
        .max_attempts = 1,
    } } }));
    try std.testing.expect(boundary.emit(.{ .after = .{ .provider_request = .{
        .attempt_id = attempt_id,
        .outcome = .stream_error,
        .metering = .unknown,
    } } }));
    // The re-issue reopens the same id only after the first attempt closed.
    try std.testing.expect(boundary.emit(.{ .before = .{ .provider_request = .{
        .attempt_id = attempt_id,
        .actor_id = sid.bytes,
        .request_sha256 = request_sha256,
        .logical_turn = 1,
        .context_generation = 0,
        .physical_attempt = 1,
        .max_attempts = 1,
    } } }));
    try std.testing.expect(boundary.emit(.{ .after = .{ .provider_request = .{
        .attempt_id = attempt_id,
        .outcome = .succeeded,
        .metering = .unknown,
    } } }));
    try journal.finishRun("end_turn");

    const summary = try validate(root, sid);
    try std.testing.expect(summary.complete);

    var loaded = try loadRunDispatches(std.testing.allocator, root, try journal.runBinding());
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.provider_attempts.len);
    try std.testing.expect(loaded.provider_attempts[0].outcome == .stream_error);
    try std.testing.expect(loaded.provider_attempts[1].outcome == .succeeded);
    // Both resolve positionally even though they share an id.
    try std.testing.expectEqualSlices(
        u8,
        &loaded.provider_attempts[0].attempt_id,
        &loaded.provider_attempts[1].attempt_id,
    );
}

test "an overlapping provider attempt id is refused at write time" {
    // The relaxed read invariant still forbids a *genuine* overlap: a second
    // start of an id whose first attempt has not closed. The write boundary
    // rejects it (the recovery reducer's DuplicateIntent), so such a record can
    // never reach the journal in the first place.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;

    var journal = try Journal.init(root, sid);
    defer journal.deinit();
    const boundary = journal.executionBoundary();
    const request_sha256 = execution_effect.sha256Hex(&.{"canonical-request"});
    const attempt_id = execution_effect.providerAttemptId(sid.bytes, request_sha256, 1, 0, 1);
    const started = execution_effect.BoundaryEvent{ .before = .{ .provider_request = .{
        .attempt_id = attempt_id,
        .actor_id = sid.bytes,
        .request_sha256 = request_sha256,
        .logical_turn = 1,
        .context_generation = 0,
        .physical_attempt = 1,
        .max_attempts = 1,
    } } };
    try std.testing.expect(boundary.emit(started));
    // Second start while the first is still open: refused.
    try std.testing.expect(!boundary.emit(started));
}

test "run cannot seal while a provider intent has no durable result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;
    var journal = try Journal.init(root_buffer[0..root_len], sid);
    defer journal.deinit();
    const boundary = journal.executionBoundary();
    const request_sha256 = execution_effect.sha256Hex(&.{"request"});
    try std.testing.expect(boundary.emit(.{ .before = .{ .provider_request = .{
        .attempt_id = execution_effect.providerAttemptId(sid.bytes, request_sha256, 1, 0, 1),
        .actor_id = sid.bytes,
        .request_sha256 = request_sha256,
        .logical_turn = 1,
        .context_generation = 0,
        .physical_attempt = 1,
        .max_attempts = 1,
    } } }));
    try std.testing.expectError(error.RunHasPendingEffects, journal.sealRun("end_turn"));
    const summary = try validate(root_buffer[0..root_len], sid);
    try std.testing.expect(!summary.complete);
}

test "tool observation journal lease rejects a concurrent writer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;

    var first = try Journal.init(root, sid);
    defer first.deinit();
    try std.testing.expectError(error.JournalBusy, Journal.init(root, sid));
    const live = try validate(root, sid);
    try std.testing.expect(!live.complete);
    try first.finishRun("end_turn");

    // The old owner may deinit after the next owner has acquired the same path.
    // It must not unlink that new lease.
    var second = try Journal.init(root, sid);
    defer second.deinit();
    first.deinit();
    try std.testing.expectError(error.JournalBusy, Journal.init(root, sid));
    try second.finishRun("end_turn");
}

test "sealed run retains crash marker until derived publication releases it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;

    var journal = try Journal.init(root, sid);
    try journal.sealRun("end_turn");
    _ = try journal.finishedRunBinding();
    try std.testing.expectError(error.RunNotFinished, journal.runBinding());
    try std.testing.expectError(error.JournalBusy, Journal.init(root, sid));

    try journal.releaseFinishedRun();
    _ = try journal.runBinding();
    var next = try Journal.init(root, sid);
    defer next.deinit();
    try next.finishRun("end_turn");
    journal.deinit();
}

test "run_started records the Run's prompt manifest only when there is one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;

    var entries = [_]prompt_sections.ManifestEntry{
        .{ .id = "metacodes:identity", .order = -1000, .origin = .host, .class = .replaceable, .sha256 = prompt_sections.sha256("I") },
        .{ .id = "host:rules", .order = 500, .origin = .host, .class = .removable, .sha256 = prompt_sections.sha256("R") },
    };
    const manifest: prompt_sections.Manifest = .{ .entries = &entries, .sha256 = prompt_sections.sha256("I\n\nR") };
    var with_prompt = try Journal.initWithPrompt(root, sid, manifest);
    try with_prompt.finishRun("end_turn");
    with_prompt.deinit();
    var without_prompt = try Journal.init(root, sid);
    try without_prompt.finishRun("end_turn");
    without_prompt.deinit();
    try std.testing.expect((try validate(root, sid)).complete);

    const bytes = try tmp.dir.readFileAlloc(std.testing.io, FILE_NAME, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const first = lines.next().?;
    const expected_prompt = try std.fmt.allocPrint(
        std.testing.allocator,
        "\"prompt\":{{\"sha256\":\"{s}\",\"sections\":[" ++
            "{{\"id\":\"metacodes:identity\",\"order\":-1000,\"origin\":\"host\",\"class\":\"replaceable\",\"sha256\":\"{s}\"}}," ++
            "{{\"id\":\"host:rules\",\"order\":500,\"origin\":\"host\",\"class\":\"removable\",\"sha256\":\"{s}\"}}]}}}}}}}}",
        .{
            &std.fmt.bytesToHex(prompt_sections.sha256("I\n\nR"), .lower),
            &std.fmt.bytesToHex(prompt_sections.sha256("I"), .lower),
            &std.fmt.bytesToHex(prompt_sections.sha256("R"), .lower),
        },
    );
    defer std.testing.allocator.free(expected_prompt);
    try std.testing.expect(std.mem.endsWith(u8, first, expected_prompt));
    _ = lines.next().?; // run_finished
    const third = lines.next().?;
    try std.testing.expect(std.mem.indexOf(u8, third, "\"run_started\":{\"started_wall_ns\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, third, "prompt") == null);
}

test "a recorded prompt manifest must be well formed" {
    const digest = std.fmt.bytesToHex(prompt_sections.sha256("x"), .lower);
    var sections = [_]PromptSectionRecord{
        .{ .id = "metacodes:identity", .order = -1000, .origin = .kernel, .class = .replaceable, .sha256 = digest },
        .{ .id = "host:rules", .order = 500, .origin = .host, .class = .removable, .sha256 = digest },
    };
    try std.testing.expect(validPromptRecord(.{ .sha256 = digest, .sections = &sections }));
    var upper = digest;
    upper[0] = 'F';
    try std.testing.expect(!validPromptRecord(.{ .sha256 = upper, .sections = &sections }));
    sections[1].id = "other:rules";
    try std.testing.expect(!validPromptRecord(.{ .sha256 = digest, .sections = &sections }));
    sections[1].id = "host:rules";
    sections[1].order = -2000;
    try std.testing.expect(!validPromptRecord(.{ .sha256 = digest, .sections = &sections }));
}

test "tool observation journal rejects a partial existing record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = FILE_NAME,
        .data = "{\"schema_version\":\"broken\"}",
    });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;
    try std.testing.expectError(
        error.PartialRecord,
        Journal.init(root_buffer[0..root_len], sid),
    );
    // The lease this failed init created never named anyone: it must not stay
    // behind looking like an older metacodes' marker.
    var lease_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    try std.testing.expect(!pfs.exists((try testLeasePath(&lease_buf, root_buffer[0..root_len])).ptr));
}

fn testLeasePath(buf: []u8, root: []const u8) ![:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ root, LOCK_FILE_NAME });
}

/// An empty marker as an older metacodes keeps it: made when its Run began,
/// so before that Run's terminal record (POSIX: back-dated to 2001).
fn testKeptLegacyMarker(lease_path: [:0]const u8) !void {
    const marker = pfs.open(lease_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (marker < 0) return error.TestOpenFailed;
    defer _ = pfs.close(marker);
    const made: std.c.timespec = .{ .sec = 1_000_000_000, .nsec = 0 };
    if (std.c.futimens(marker, &.{ made, made }) != 0) return error.TestTouchFailed;
}

/// A Run whose process dies mid-dispatch: the Journal goes away without its
/// terminal record, which closes the lease file and so drops its lock.
fn testDieMidRun(root: []const u8, sid: session_id_mod.SessionId) !session_id_mod.SessionId {
    var journal = try Journal.init(root, sid);
    defer journal.deinit();
    if (!journal.sink().emit(testDispatchStart("in-flight"))) return error.TestJournalRejected;
    return journal.run_id;
}

test "a Run whose owner died stays closed under fail_closed and is abandoned under record_abandoned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;
    var lease_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const lease_path = try testLeasePath(&lease_buf, root);

    const dead_run = try testDieMidRun(root, sid);
    var refused: OpenReport = .{};
    try std.testing.expectError(error.UnfinishedRun, Journal.initWithOptions(root, sid, .{ .report = &refused }));
    const unfinished = refused.unfinished.?;
    try std.testing.expectEqualStrings(dead_run.asSlice(), unfinished.run_id.asSlice());
    try std.testing.expectEqual(@as(u64, 1), unfinished.open_dispatches);
    try std.testing.expectEqual(@as(u64, 0), unfinished.open_provider_attempts);
    try std.testing.expectEqualStrings("Write", unfinished.openTool().?);
    try std.testing.expect(refused.holder == .none);
    // Refusing leaves the dead owner's lease as it found it.
    try std.testing.expect(pfs.exists(lease_path.ptr));

    var report: OpenReport = .{};
    var next = try Journal.initWithOptions(root, sid, .{ .abandoned_run = .record_abandoned, .report = &report });
    defer next.deinit();
    try std.testing.expect(report.holder == .none);
    try std.testing.expectEqualStrings(dead_run.asSlice(), report.unfinished.?.run_id.asSlice());
    try next.finishRun("end_turn");
    try std.testing.expect(!pfs.exists(lease_path.ptr));
    try std.testing.expect((try validate(root, sid)).complete);

    // The abandoned Run is closed but is never evidence; the next Run is.
    try std.testing.expectError(error.InvalidRunBinding, validateRunBinding(root, .{
        .session_id = sid,
        .run_id = dead_run,
        .first_sequence = 0,
        .last_sequence = 2,
    }));
    const binding = try next.runBinding();
    try std.testing.expectEqual(@as(u64, 3), binding.first_sequence);
    var loaded = try loadRunDispatches(std.testing.allocator, root, binding);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 0), loaded.dispatches.len);

    // The record is the dead Run's own: its id, its last time, what it left open.
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, FILE_NAME, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    _ = lines.next().?; // run_started (dead)
    const in_flight = try std.json.parseFromSlice(Envelope, std.testing.allocator, lines.next().?, .{});
    defer in_flight.deinit();
    const abandoned = try std.json.parseFromSlice(Envelope, std.testing.allocator, lines.next().?, .{});
    defer abandoned.deinit();
    try std.testing.expectEqualStrings(dead_run.asSlice(), abandoned.value.run_id);
    try std.testing.expectEqual(in_flight.value.monotonic_elapsed_ns, abandoned.value.monotonic_elapsed_ns);
    const record = abandoned.value.event.run_abandoned;
    try std.testing.expectEqual(OwnerEvidence.lease_unlocked, record.evidence);
    try std.testing.expectEqual(@as(u64, 1), record.open_dispatches);
    try std.testing.expectEqualStrings(next.run_id.asSlice(), record.recovered_by_run_id);
}

test "a live owner keeps the session busy and the report names its process" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;

    var owner = try Journal.init(root, sid);
    defer owner.deinit();
    var report: OpenReport = .{};
    try std.testing.expectError(error.JournalBusy, Journal.initWithOptions(root, sid, .{
        .abandoned_run = .record_abandoned,
        .report = &report,
    }));
    switch (report.holder) {
        .process => |holder| {
            try std.testing.expectEqual(@as(i64, @import("platform").process.currentPid()), holder.pid);
            try std.testing.expectEqual(owner.started_wall_ns, holder.acquired_wall_ns);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(report.unfinished == null);
    try owner.finishRun("end_turn");
}

test "an older metacodes' empty marker is busy while a process holds it and abandoned once none does" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;
    var lease_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const lease_path = try testLeasePath(&lease_buf, root);

    _ = try testDieMidRun(root, sid);
    // What an older metacodes leaves while it runs: an empty marker it keeps
    // open, under no lock and naming no owner.
    const marker = pfs.open(lease_path.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true }, @as(std.c.mode_t, 0));
    try std.testing.expect(marker >= 0);
    // Its holder is another process (POSIX leaves this one out of the
    // question; Windows cannot, so there this process's handle stands in).
    var holder: ?std.process.Child = if (is_windows) null else try std.process.spawn(std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "exec 3<\"$0\"; echo held; exec sleep 60", lease_path },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer if (holder) |*child| child.kill(std.testing.io);
    if (holder) |*child| {
        _ = pfs.close(marker);
        // It says so once it holds the marker.
        var said: [1]u8 = undefined;
        while (try child.stdout.?.readStreaming(std.testing.io, &.{&said}) == 0) {}
    }
    var report: OpenReport = .{};
    try std.testing.expectError(error.JournalBusy, Journal.initWithOptions(root, sid, .{
        .abandoned_run = .record_abandoned,
        .report = &report,
    }));
    try std.testing.expect(report.holder == .unnamed);
    if (holder) |*child| {
        child.kill(std.testing.io);
        holder = null;
    } else _ = pfs.close(marker);

    var next = try Journal.initWithOptions(root, sid, .{ .abandoned_run = .record_abandoned });
    defer next.deinit();
    try next.finishRun("end_turn");
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, FILE_NAME, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"evidence\":\"legacy_lease_unheld\"") != null);
    try std.testing.expect((try validate(root, sid)).complete);
}

test "a Run sealed for publication whose owner never released it keeps the session closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;
    var lease_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const lease_path = try testLeasePath(&lease_buf, root);

    {
        var sealed = try Journal.init(root, sid);
        defer sealed.deinit();
        try sealed.sealRun("end_turn");
    }
    try std.testing.expectError(
        error.RunPublicationPending,
        Journal.initWithOptions(root, sid, .{ .abandoned_run = .record_abandoned }),
    );
    if (is_windows) return; // back-dating a file below is POSIX
    // An older metacodes' marker kept past the terminal record says the same.
    try testKeptLegacyMarker(lease_path);
    try std.testing.expectError(
        error.RunPublicationPending,
        Journal.initWithOptions(root, sid, .{ .abandoned_run = .record_abandoned }),
    );
}

test "an empty lease made after the last Run closed is a leftover, not a kept marker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;
    var lease_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const lease_path = try testLeasePath(&lease_buf, root);

    // A fresh session whose first owner died before writing anything.
    const empty = pfs.open(lease_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(empty >= 0);
    _ = pfs.close(empty);
    {
        var first = try Journal.init(root, sid);
        defer first.deinit();
        try first.finishRun("end_turn");
    }
    // The same after a finished Run: the empty file is younger than it.
    const leftover = pfs.open(lease_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(leftover >= 0);
    _ = pfs.close(leftover);
    var next = try Journal.init(root, sid);
    const started = next.started_wall_ns;
    try next.finishRun("end_turn");
    next.deinit();

    if (is_windows) return; // stamping a file below is POSIX
    // A coarse file clock can stamp a leftover with the very time the last Run
    // started: a tie is not a kept marker.
    const tie = pfs.open(lease_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(tie >= 0);
    const stamp: std.c.timespec = .{
        .sec = @intCast(@divFloor(started, std.time.ns_per_s)),
        .nsec = @intCast(@mod(started, std.time.ns_per_s)),
    };
    try std.testing.expectEqual(@as(c_int, 0), std.c.futimens(tie, &.{ stamp, stamp }));
    _ = pfs.close(tie);
    var after_tie = try Journal.init(root, sid);
    defer after_tie.deinit();
    try after_tie.finishRun("end_turn");
}

test "a plain finish that died before its release lets the next Run start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;

    {
        var finished = try Journal.init(root, sid);
        defer finished.deinit();
        // `finishRun` without its release: nothing was bound to this Run.
        try finished.seal("end_turn", .running);
    }
    var next = try Journal.init(root, sid);
    defer next.deinit();
    try next.finishRun("end_turn");
}

test "a run_abandoned record must match the Run it closes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;

    _ = try testDieMidRun(root, sid);
    var next = try Journal.initWithOptions(root, sid, .{ .abandoned_run = .record_abandoned });
    try next.finishRun("end_turn");
    next.deinit();
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, FILE_NAME, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);

    // Claiming fewer open effects than the Run left.
    const undercount = try std.mem.replaceOwned(u8, std.testing.allocator, bytes, "\"open_dispatches\":1", "\"open_dispatches\":0");
    defer std.testing.allocator.free(undercount);
    try std.testing.expect(!std.mem.eql(u8, undercount, bytes));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = FILE_NAME, .data = undercount });
    try std.testing.expectError(error.InvalidRecord, validate(root, sid));

    // Closing a Run that is not open: the abandoned record first, renumbered.
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    _ = lines.next().?;
    _ = lines.next().?;
    const abandoned_line = lines.next().?;
    const orphan = try std.mem.replaceOwned(u8, std.testing.allocator, abandoned_line, "\"sequence\":2", "\"sequence\":0");
    defer std.testing.allocator.free(orphan);
    const orphan_file = try std.fmt.allocPrint(std.testing.allocator, "{s}\n", .{orphan});
    defer std.testing.allocator.free(orphan_file);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = FILE_NAME, .data = orphan_file });
    try std.testing.expectError(error.InvalidRecord, validate(root, sid));
}

test "an owner that dies the instant it takes the lease does not close the session" {
    // Iterable: otherwise Linux opens the directory O_PATH and Windows
    // without list access, and neither handle can be listed.
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;
    var lease_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const lease_path = try testLeasePath(&lease_buf, root);

    {
        var finished = try Journal.init(root, sid);
        defer finished.deinit();
        try finished.finishRun("end_turn");
    }
    // The next owner takes the lease and dies before anything else: the lease
    // it leaves already names it, so it never passes for an older metacodes'
    // empty marker (which, beside a finished Run, would close the session).
    const dead = try Lease.acquire(lease_path.ptr, null, session_id_mod.gen(), util_time.nowWallNs());
    _ = pfs.close(dead.fd);
    try std.testing.expect(dead.prior == .created);
    var next = try Journal.init(root, sid);
    defer next.deinit();
    try next.finishRun("end_turn");

    // Publishing leaves no staged lease behind, won or lost.
    var holder = try Journal.init(root, sid);
    defer holder.deinit();
    try std.testing.expectError(error.JournalBusy, Journal.init(root, sid));
    try holder.finishRun("end_turn");
    var entries = tmp.dir.iterate();
    var saw_journal = false;
    while (try entries.next(std.testing.io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, LOCK_FILE_NAME ++ "."));
        if (std.mem.eql(u8, entry.name, FILE_NAME)) saw_journal = true;
    }
    try std.testing.expect(saw_journal);
}

test "an older metacodes' marker caught mid-release is not taken for a kept one" {
    if (is_windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;
    var lease_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const lease_path = try testLeasePath(&lease_buf, root);

    {
        var finished = try Journal.init(root, sid);
        defer finished.deinit();
        try finished.finishRun("end_turn");
    }
    // An older metacodes finishing: its marker (made when its Run began)
    // closed, so the holder scan finds it unheld, and its unlink landing in
    // the settle that follows the scan.
    try testKeptLegacyMarker(lease_path);
    const Release = struct {
        var settles: usize = 0;
        fn run(path: [*:0]const u8) void {
            settles += 1;
            pfs.unlinkPath(path) catch {};
        }
    };
    testing_hooks.legacy_release_settle = Release.run;
    defer testing_hooks.legacy_release_settle = null;
    var next = try Journal.init(root, sid);
    defer next.deinit();
    // The marker was there to be judged: it reached the settle, once.
    try std.testing.expectEqual(@as(usize, 1), Release.settles);
    try next.finishRun("end_turn");
}

fn testAppendBytes(root: []const u8, bytes: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ root, FILE_NAME });
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .APPEND = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.TestOpenFailed;
    defer _ = pfs.close(fd);
    try writeAll(fd, bytes);
}

fn testJournalSize(root: []const u8) !u64 {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ root, FILE_NAME });
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.TestOpenFailed;
    defer _ = pfs.close(fd);
    return (try pfs.fileInfo(fd)).size;
}

test "a record a dead owner left half-written is cut, recorded, and the Run abandoned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;

    _ = try testDieMidRun(root, sid);
    // SIGKILL inside write(2): the kernel may stop between pages.
    const fragment = "{\"schema_version\":\"metacodes-tool-observation-journal-v2\",\"seq";
    try testAppendBytes(root, fragment);
    const torn_size = try testJournalSize(root);
    try std.testing.expectError(error.PartialRecord, Journal.init(root, sid));
    try std.testing.expectEqual(torn_size, try testJournalSize(root));

    var report: OpenReport = .{};
    var next = try Journal.initWithOptions(root, sid, .{ .abandoned_run = .record_abandoned, .report = &report });
    defer next.deinit();
    try next.finishRun("end_turn");
    const tail = report.discarded_tail.?;
    try std.testing.expectEqual(@as(u64, fragment.len), tail.bytes);
    try std.testing.expectEqualStrings(&observation.sha256Hex(fragment), &tail.sha256);
    try std.testing.expect(report.unfinished != null);
    try std.testing.expect((try validate(root, sid)).complete);
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, FILE_NAME, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"run_abandoned\"") != null);
    const recorded = try std.fmt.allocPrint(std.testing.allocator, "\"discarded_tail\":{{\"bytes\":{d},\"sha256\":\"{s}\"}}", .{ fragment.len, &tail.sha256 });
    defer std.testing.allocator.free(recorded);
    try std.testing.expect(std.mem.indexOf(u8, bytes, recorded) != null);
}

test "a refused init leaves a half-written last record where it was" {
    if (is_windows) return error.SkipZigTest; // back-dates a file
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;
    var lease_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const lease_path = try testLeasePath(&lease_buf, root);

    {
        var finished = try Journal.init(root, sid);
        defer finished.deinit();
        try finished.finishRun("end_turn");
    }
    try testKeptLegacyMarker(lease_path);
    try testAppendBytes(root, "{\"schema_version\":");
    const torn = try testJournalSize(root);
    try std.testing.expectError(
        error.RunPublicationPending,
        Journal.initWithOptions(root, sid, .{ .abandoned_run = .record_abandoned }),
    );
    try std.testing.expectEqual(torn, try testJournalSize(root));
}

test "a half-written record after a finished Run is cut; a damaged journal is left alone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;

    {
        var finished = try Journal.init(root, sid);
        defer finished.deinit();
        try finished.finishRun("end_turn");
    }
    // The next owner died writing its very first record.
    try testAppendBytes(root, "{\"schema_version\":");
    var report: OpenReport = .{};
    var next = try Journal.initWithOptions(root, sid, .{ .abandoned_run = .record_abandoned, .report = &report });
    try next.finishRun("end_turn");
    next.deinit();
    try std.testing.expect(report.discarded_tail != null and report.unfinished == null);
    try std.testing.expect((try validate(root, sid)).complete);

    // Anything wrong before the half-written record is not this repair's.
    try testAppendBytes(root, "not a record\n{\"half");
    const damaged = try testJournalSize(root);
    try std.testing.expectError(
        error.InvalidRecord,
        Journal.initWithOptions(root, sid, .{ .abandoned_run = .record_abandoned }),
    );
    try std.testing.expectEqual(damaged, try testJournalSize(root));
}

test "a lease created in place, where links are unsupported, is locked and names its owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var lease_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const lease_path = try testLeasePath(&lease_buf, root);
    const run_id = session_id_mod.gen();

    const fd = (try Lease.publishInPlace(lease_path.ptr, run_id, 7)).?;
    defer _ = pfs.close(fd);
    switch (readLease(fd)) {
        .record => |owner| try std.testing.expectEqualStrings(run_id.asSlice(), owner.runId()),
        else => return error.TestUnexpectedResult,
    }
    const other = pfs.open(lease_path.ptr, .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
    try std.testing.expect(other >= 0);
    defer _ = pfs.close(other);
    try std.testing.expectError(error.WouldBlock, pfs.tryLockExclusive(other));
    // A second in-place create finds the lease and leaves it alone.
    try std.testing.expect((try Lease.publishInPlace(lease_path.ptr, session_id_mod.gen(), 8)) == null);
}

test "a release never removes a lease name that no longer leads to its own file" {
    if (is_windows) return error.SkipZigTest; // Windows will not delete an open file
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;
    var lease_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const lease_path = try testLeasePath(&lease_buf, root);

    var owner = try Journal.init(root, sid);
    defer owner.deinit();
    // An older metacodes' late unlink took this owner's name, and another
    // process has put its own lease there since.
    try pfs.unlinkPath(lease_path.ptr);
    const successor = pfs.open(lease_path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(successor >= 0);
    defer _ = pfs.close(successor);
    try owner.finishRun("end_turn");
    try std.testing.expect(pfs.exists(lease_path.ptr));
}

test "a lease reached through a name that has since moved is not the lease" {
    if (is_windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var lease_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const lease_path = try testLeasePath(&lease_buf, root);

    const fd = pfs.open(lease_path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = pfs.close(fd);
    try std.testing.expect(try namesFile(lease_path.ptr, fd));
    try pfs.unlinkPath(lease_path.ptr);
    try std.testing.expect(!try namesFile(lease_path.ptr, fd));
    const successor = pfs.open(lease_path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(successor >= 0);
    defer _ = pfs.close(successor);
    try std.testing.expect(!try namesFile(lease_path.ptr, fd));
}

test "lease outcomes are described for the person who sent the message" {
    var buf: [512]u8 = undefined;
    var report: OpenReport = .{ .holder = .{ .process = .{ .pid = 4242, .acquired_wall_ns = 1_793_020_790_000_000_000 } } };
    const busy = describeRefusal(&buf, error.JournalBusy, &report).?;
    try std.testing.expect(std.mem.indexOf(u8, busy, "pid 4242") != null);
    report.holder = .unnamed;
    try std.testing.expect(std.mem.indexOf(u8, describeRefusal(&buf, error.JournalBusy, &report).?, "older version") != null);
    try std.testing.expect(describeRefusal(&buf, error.RunPublicationPending, &report) != null);
    try std.testing.expect(describeRefusal(&buf, error.OutOfMemory, &report) == null);

    var run: OpenRun = .{
        .run_id = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?,
        .started_wall_ns = 1_793_020_790_000_000_000,
        .last_elapsed_ns = 2_252_220_732_000,
        .open_dispatches = 1,
        .open_provider_attempts = 0,
    };
    @memcpy(run.open_tool_buf[0..4], "Bash");
    run.open_tool_len = 4;
    const closed = describeAbandoned(&buf, &run);
    try std.testing.expect(std.mem.indexOf(u8, closed, "while Bash was running") != null);
    try std.testing.expect(std.mem.indexOf(u8, closed, "check its effects") != null);
    run.open_dispatches = 0;
    try std.testing.expect(std.mem.indexOf(u8, describeAbandoned(&buf, &run), "Bash") == null);
    // Times come from journal records; out-of-range ones are not trusted.
    var clock: [32]u8 = undefined;
    try std.testing.expectEqualStrings("an unknown time", localClock(&clock, std.math.maxInt(i128)));
    try std.testing.expectEqualStrings("an unknown time", localClock(&clock, -1));
}
