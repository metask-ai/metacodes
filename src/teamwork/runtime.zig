//! The teamwork runtime (#514, #518 run lifecycle, #520, #523): one run's
//! state machine and the small operations API every manager drives.
//!
//! ```
//! start(request, config) ─► approved
//!   approved / implementing / reviewing / review_approved
//!       ── dispatch(implementer) ─► implementing ── finished ─► reviewing
//!   reviewing / review_approved
//!       ── dispatch(reviewer) ─► approved review   ─► review_approved
//!                              ─► changes / invalid ─► implementing
//!   approved ── runCandidates() (only with `candidates` configured, #525)
//!       ─► candidates ─► one implementer + reviewer per candidate worktree
//!                     ─► judge selects an approved one ─► review_approved
//!                     ─► none approved ─► failed(no_candidate_approved)
//!   review_approved ── requestCompletion()
//!       ─► approval stale        ─► reviewing
//!       ─► auditing ─► pass      ─► merging ─► done | failed(merge_*)
//!                   ─► 1st fail  ─► implementing (repair round)
//!                   ─► 2nd fail / unverified / unavailable ─► failed
//!   any live state ── cancel() ─► cancelled
//!                  ── budget reached ─► budget_exhausted
//!                  ── per-role dispatch cap ─► failed(rounds_exhausted)
//! ```
//!
//! A manager — the built-in deterministic SWE loop (`swe_loop.zig`), or
//! later Claude Code over MCP (#522) — only calls `dispatch`, `status`,
//! `requestCompletion` and `cancel`. It never declares completion: `done` is
//! reachable only through `requestCompletion`, after a review approval that
//! still binds the worktree and a passing completion audit, and merge-back
//! is the runtime's own step. Review verification (evidence, pinned check,
//! zero edits, issue ledger), budget, write isolation and audit rules hold
//! whatever the manager.
//!
//! Everything the runtime knows is on disk (`run.json`, seat
//! `status.json`, the ledgers), so `Run.reopen` continues a run after a
//! crash. Not thread-safe: one thread drives a run; another thread may only
//! trip `Run.abort` (as Ctrl-C does). Design: doc/TEAMWORK_DESIGN.md §10.

const std = @import("std");
const pfs = @import("platform").fs;
const util_fs = @import("../util/fs.zig");
const swarm_team = @import("../swarm/team.zig");
const log = @import("../util/log.zig");
const types = @import("types.zig");
const config = @import("config.zig");
const run_dir = @import("run_dir.zig");
const ledger_mod = @import("ledger.zig");
const issues = @import("issues.zig");
const reviewer = @import("reviewer.zig");
const audit = @import("audit.zig");
const merge_back = @import("merge_back.zig");
const factory = @import("drivers/factory.zig");
const common = @import("drivers/common.zig");
const charters = @import("charters.zig");
const progress = @import("progress.zig");
const judge = @import("judge.zig");
const lesson = @import("../kg/lesson.zig");

const Role = types.Role;
const SeatId = types.SeatId;
const TreeId = reviewer.TreeId;

/// At most this many completion audits per run (#514, #516).
pub const max_audits: u8 = 2;

// ── inputs ──────────────────────────────────────────────────────────────────

/// The request text the user approved (#518), byte for byte. The runtime
/// records it once as `ORIGINAL_REQUEST.md`; nothing else ever replaces it.
pub const ApprovedRequest = struct {
    text: []const u8,
    source: RequestSource,
};

pub const RequestSource = enum {
    request_file,
    skip_interview,
    interview,
    user_edited,
};

/// Where seat drivers come from.
pub const SeatSource = union(enum) {
    /// Production: `drivers/factory.zig` picks the driver from the seat's
    /// configured harness.
    harness: factory.Deps,
    /// An embedder's own drivers (tests use scripted ones). Their tool calls
    /// are unobservable, so a review is verified through the pinned check.
    custom: Custom,

    pub const Custom = struct {
        ctx: *anyopaque,
        /// The driver for one seat run; it charges `binding`.
        driverFn: *const fn (ctx: *anyopaque, spec: *const types.SeatSpec, binding: common.Binding) types.SeatDriver,
    };
};

/// What a run depends on, borrowed for the run's life.
pub const Deps = struct {
    /// Current host authorization, never restored from run state or model input.
    /// Status, cancellation and destruction remain available when disabled.
    preview: @import("../preview.zig").Features = .none,
    seats: SeatSource,
    /// The completion audit: in production
    /// `verifier_auditor.VerifierAuditor`; a host without a verifier passes
    /// `audit.UnavailableAuditor`, so no run completes unaudited.
    auditor: audit.CompletionAuditor,
    /// Re-runs the pinned check for review verification (sandboxed like
    /// the Bash tool when the host has a sandbox).
    check_runner: reviewer.CheckRunner = .{},
    cli_approval: ?CliApproval = null,
    recheck_audited_tree: *const fn (std.mem.Allocator, []const u8, []const u8, ?*const types.AbortSignal) reviewer.TreeError!TreeId = reviewer.workspaceTree,
    observer: ?progress.Observer = null,
    pitfalls: ?PitfallSink = null,
};

pub const PitfallSink = struct {
    ctx: *anyopaque,
    rememberFn: *const fn (ctx: *anyopaque, text: []const u8) bool,

    pub fn remember(self: PitfallSink, text: []const u8) bool {
        return self.rememberFn(self.ctx, text);
    }
};

/// A CLI host can reopen without loading mutable project configuration. The
/// serialized policy is borrowed for the run, together with the host digest.
pub const CliApproval = struct {
    config_json: []const u8,
    host_sha256: [32]u8,
};

pub const StartOptions = struct {
    state_root: []const u8,
    run_id: types.RunId,
    /// The user's workspace: inside a git work tree. Its top directory is
    /// the merge-back target.
    workspace: []const u8,
};

// ── state ───────────────────────────────────────────────────────────────────

pub const Failure = enum {
    /// A role reached `max_rounds` dispatches and needed another.
    rounds_exhausted,
    /// The second completion audit failed.
    audit_failed,
    /// The auditor could not decide; never a pass.
    audit_unverified,
    /// The auditor could not run; never a pass.
    audit_unavailable,
    /// The worktree changed while the auditor ran.
    audit_changed_worktree,
    /// The workspace tree could not be computed, so an approval could not
    /// be confirmed (Windows, or git failing).
    approval_unconfirmable,
    /// The user changed paths the implementer changed (`merge-conflicts.txt`).
    merge_conflict,
    /// `git apply` refused the patch, or git failed before applying.
    merge_failed,
    /// The runtime stopped during merge-back; the workspace needs a look.
    merge_interrupted,
    no_candidate_approved,
    candidates_interrupted,
    candidate_git_failed,

    pub fn parse(text: []const u8) ?Failure {
        return std.meta.stringToEnum(Failure, text);
    }
};

pub const Done = struct {
    /// Paths merge-back changed in the user's workspace.
    files_changed: u32,
    /// The worktree was removed; false = kept (its path is in the snapshot).
    worktree_removed: bool,
};

/// The run's state. The approved tree travels through `auditing` and
/// `merging`, so what is merged is exactly what was reviewed and audited.
pub const State = union(Phase) {
    /// The request is recorded; nothing dispatched yet.
    approved,
    candidates,
    /// An implementer round is due (or running).
    implementing,
    /// The last implementer finished; a review is due (or running).
    reviewing,
    /// A verified review approved this worktree tree.
    review_approved: TreeId,
    auditing: TreeId,
    merging: TreeId,
    done: Done,
    failed: Failure,
    budget_exhausted,
    cancelled,

    pub fn phase(self: State) Phase {
        return std.meta.activeTag(self);
    }

    pub fn isTerminal(self: State) bool {
        return self.phase().isTerminal();
    }
};

pub const Phase = enum {
    approved,
    candidates,
    implementing,
    reviewing,
    review_approved,
    auditing,
    merging,
    done,
    failed,
    budget_exhausted,
    cancelled,

    pub fn isTerminal(self: Phase) bool {
        return switch (self) {
            .done, .failed, .budget_exhausted, .cancelled => true,
            else => false,
        };
    }

    pub fn parse(text: []const u8) ?Phase {
        return std.meta.stringToEnum(Phase, text);
    }
};

/// The transition table. Everything not listed is illegal; terminal states
/// have no way out.
pub fn allowed(from: Phase, to: Phase) bool {
    const live_exits = switch (to) {
        .failed, .budget_exhausted, .cancelled => true,
        else => false,
    };
    return switch (from) {
        .approved => live_exits or to == .implementing or to == .candidates,
        .candidates => live_exits or to == .review_approved,
        .implementing => live_exits or to == .implementing or to == .reviewing,
        .reviewing => live_exits or to == .reviewing or to == .implementing or to == .review_approved,
        .review_approved => live_exits or to == .implementing or to == .reviewing or to == .auditing,
        // Back to `review_approved` only when a crash interrupted the audit.
        .auditing => live_exits or to == .merging or to == .implementing or to == .review_approved,
        // Merge-back is not cancellable halfway, and it spends nothing.
        .merging => to == .done or to == .failed,
        .done, .failed, .budget_exhausted, .cancelled => false,
    };
}

pub const ReviewResult = union(enum) {
    approved: TreeId,
    /// Issues still open after the review.
    changes_requested: u32,
    /// The review did not hold up (reviewer.RejectReason).
    rejected: std.meta.Tag(reviewer.RejectReason),
    /// The worktree's tree could not be computed, so the review could not
    /// be judged.
    unjudgeable,
};

/// How a seat run ended, as the runtime judged it.
pub const SeatResult = union(enum) {
    /// An implementer left a valid handoff.
    finished,
    /// A reviewer left a valid handoff; its review as judged.
    review: ReviewResult,
    judgment: JudgmentResult,
    failed: types.SeatError,
    budget_exhausted,
    aborted,
    /// The runtime stopped while the seat ran (found by `Run.reopen`).
    interrupted,
};

pub const JudgmentResult = union(enum) {
    selected: u8,
    invalid: judge.Invalid,
};

// ── snapshot ────────────────────────────────────────────────────────────────

pub const CandidateStatus = enum {
    queued,
    implementing,
    reviewing,
    approved,
    rejected,
    selected,
    eliminated,

    pub fn parse(text: []const u8) ?CandidateStatus {
        return std.meta.stringToEnum(CandidateStatus, text);
    }
};

pub const CandidateSnapshot = struct {
    status: CandidateStatus = .queued,
    tree: ?TreeId = null,
};

pub const SeatSnapshot = struct {
    id: SeatId,
    role: Role,
    harness: types.Harness,
    status: types.SeatStatus,
    charter_sha256: ?[64]u8 = null,
    /// Null before the seat ends, and for seats ended before a `reopen`.
    result: ?SeatResult = null,
};

pub const BudgetSnapshot = struct {
    cap_usd: f64,
    spent_usd: f64,
    remaining_usd: f64,
    charges: usize,
};

pub const AuditSnapshot = struct {
    used: u8,
    max: u8 = max_audits,
    last: ?audit.VerdictKind,
};

/// A run as UI and MCP consumers see it: plain data. Slices are borrowed
/// from the run and valid until its next operation.
pub const RunSnapshot = struct {
    run_id: types.RunId,
    /// The first line of the approved request (at most `goal_max` bytes).
    goal: []const u8,
    state: State,
    seats: []const SeatSnapshot,
    budget: BudgetSnapshot,
    open_issues: u32,
    audit: AuditSnapshot,
    max_rounds: u32,
    /// The implementer worktree while it exists; after a failed or
    /// interrupted run, where the work is kept.
    worktree: ?[]const u8,
    /// Paths in `merge-conflicts.txt` after a `merge_conflict`.
    merge_conflicts: u32,
    candidates: []const CandidateSnapshot,
};

pub const goal_max = 200;

pub const CandidatesResult = union(enum) {
    selected: u8,
    failed: Failure,
    budget_exhausted,
    cancelled,
};

pub const CompletionResult = union(enum) {
    /// Audited, merged into the user's workspace, uncommitted.
    done: Done,
    /// The worktree changed after the approval; the run is back in
    /// `reviewing`.
    approval_stale,
    /// The first audit failed; its report is forwarded and the run is back in
    /// `implementing` for a repair round.
    repair_requested,
    failed: Failure,
    budget_exhausted,
    cancelled,
};

// ── errors ──────────────────────────────────────────────────────────────────

pub const Error = run_dir.Error || error{
    PreviewDisabled,
    RunBusy,
    LeaseFailed,
    /// The run is in a terminal state (or just entered one).
    RunEnded,
    /// Only the implementer and the reviewer are dispatched; the verifier is
    /// the completion audit, the interviewer runs before the run, and the
    /// manager drives it.
    RoleNotDispatchable,
    /// A reviewer was asked for before an implementer finished.
    NothingToReview,
    CandidatesPending,
    NoCandidates,
    CandidateBudgetExceeded,
    /// `requestCompletion` without a current review approval.
    NotApproved,
    /// The instructions name the run directory, the worktree, the user's
    /// repository or the run id: provider-visible bytes must not (cache
    /// contract).
    InstructionsNameRunState,
    /// The dispatch would pass `max_rounds`; the run is now failed.
    RoundsExhausted,
    /// No budget is left; the run is now `budget_exhausted`.
    BudgetExhausted,
    Aborted,
    /// A transition the table forbids was attempted: a runtime bug, refused.
    IllegalTransition,
};

pub const StartError = Error || merge_back.Error || ledger_mod.LoadError || issues.LoadError || error{EmptyRequest};

pub const ReopenError = StartError || error{ StateCorrupt, ConfigurationChanged };

// ── the run ─────────────────────────────────────────────────────────────────

pub const Run = struct {
    gpa: std.mem.Allocator,
    deps: Deps,
    cfg: config.Config.Enabled,
    dir: run_dir.RunDir,
    /// Kernel lock, never inherited by a seat. One process drives a run.
    lease_fd: pfs.Fd,
    ledger: ledger_mod.Ledger,
    issues: issues.Ledger,
    /// Shared by every seat of the run: tripped by `cancel`, by the
    /// exhausting ledger charge, or from another thread.
    abort: types.AbortSignal,
    state: State,
    /// The user's work tree top; owned.
    repo: []u8,
    /// `<run>/worktree`; owned.
    worktree: []u8,
    worktree_present: bool,
    base: merge_back.Snapshot,
    request_source: RequestSource,
    /// Seats dispatched per role.
    dispatched: std.EnumArray(Role, u32) = .initFill(0),
    audits: u8 = 0,
    last_audit: ?audit.VerdictKind = null,
    merge_conflicts: u32 = 0,
    candidates: [config.max_candidates]CandidateSnapshot = @splat(.{}),
    seats: std.ArrayList(SeatSnapshot) = .empty,
    /// Owned.
    goal: []u8,

    /// Record the approved request and set the run up: run directory,
    /// `ORIGINAL_REQUEST.md` (once), budget ledger with the configured cap,
    /// issue ledger, and the implementer's worktree of a snapshot of the
    /// workspace. `cfg`'s strings must outlive the run.
    pub fn start(gpa: std.mem.Allocator, deps: Deps, request: ApprovedRequest, cfg: config.Config.Enabled, options: StartOptions) StartError!*Run {
        if (!deps.preview.teamwork) return error.PreviewDisabled;
        if (std.mem.trim(u8, request.text, " \t\r\n").len == 0) return error.EmptyRequest;
        const self = blk: {
            // Resolve the repository before anything is written.
            const repo = try merge_back.toplevel(gpa, options.workspace, null);
            errdefer gpa.free(repo);
            var dir = try run_dir.RunDir.reserveRoot(gpa, options.state_root, options.run_id, true);
            errdefer dir.deinit(gpa);
            const lease = try acquireLease(&dir);
            errdefer pfs.close(lease);
            var buf: run_dir.PathBuf = undefined;
            if (pfs.exists((try dir.path(&buf, .state)).ptr) or pfs.exists((try dir.path(&buf, .worktree)).ptr)) return error.RunExists;
            try checkCandidateBudget(gpa, &dir, cfg);
            try dir.initialize();
            dir.writeOriginalRequest(request.text) catch |err| switch (err) {
                error.OriginalRequestExists => {
                    const prior = try dir.readOriginalRequest(gpa);
                    defer gpa.free(prior);
                    if (!std.mem.eql(u8, prior, request.text)) return error.RunExists;
                },
                else => |e| return e,
            };
            const base = try merge_back.snapshot(gpa, repo, dir.root, null);
            const worktree = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir.root, run_dir.worktree_dir });
            errdefer gpa.free(worktree);
            // On success `open` owns `repo`, `dir` and `worktree`.
            break :blk try open(gpa, deps, cfg, dir, lease, repo, worktree, base, .approved, request.source);
        };
        errdefer self.destroy();
        // Publish the approval and base together before creating a worktree.
        // Resume can finish an interrupted checkout under the same lease.
        try self.persist();
        if (cfg.candidates.len == 0) try self.completeInitialCheckout();
        try self.persist();
        return self;
    }

    fn completeInitialCheckout(self: *Run) merge_back.Error!void {
        try merge_back.ensureInitialWorktree(self.gpa, self.repo, self.worktree, self.base.commit);
        self.worktree_present = true;
    }

    /// Continue a run after a restart, from its directory alone. A seat the
    /// crash interrupted is recorded `failed` (`interrupted`) and its round
    /// is run again with the next seat id; an interrupted audit is not
    /// counted; an interrupted merge-back fails the run for the user to
    /// inspect. A terminal run reopens as it ended.
    pub fn reopen(gpa: std.mem.Allocator, deps: Deps, cfg: config.Config.Enabled, state_root: []const u8, run_id: types.RunId) ReopenError!*Run {
        if (!deps.preview.teamwork) return error.PreviewDisabled;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        var buf: run_dir.PathBuf = undefined;
        var saved: Saved = undefined;
        const self = blk: {
            var dir = try run_dir.RunDir.open(gpa, state_root, run_id);
            errdefer dir.deinit(gpa);
            const lease = try acquireLease(&dir);
            errdefer pfs.close(lease);
            const text = swarm_team.readFileAlloc(gpa, try dir.path(&buf, .state)) orelse return error.StateCorrupt;
            defer gpa.free(text);
            saved = parseSaved(arena_state.allocator(), text) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.StateCorrupt,
            };
            // Approval pins the entire policy, not just the task text. A
            // restart must not increase the cap, replace a harness or weaken
            // the pinned check by reading an edited configuration file.
            const fingerprint = try configFingerprint(gpa, cfg);
            if (!std.mem.eql(u8, &fingerprint, &saved.config_sha256)) return error.ConfigurationChanged;
            const host_sha256: ?[32]u8 = if (deps.cli_approval) |approval| approval.host_sha256 else null;
            if (!std.meta.eql(host_sha256, saved.host_sha256)) return error.ConfigurationChanged;
            const repo = try gpa.dupe(u8, saved.repo);
            errdefer gpa.free(repo);
            const worktree = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir.root, run_dir.worktree_dir });
            errdefer gpa.free(worktree);
            const state: State = switch (saved.state) {
                .auditing => |tree| .{ .review_approved = tree },
                .merging => .{ .failed = .merge_interrupted },
                .candidates => .{ .failed = .candidates_interrupted },
                else => saved.state,
            };
            break :blk try open(gpa, deps, cfg, dir, lease, repo, worktree, saved.base, state, saved.request_source);
        };
        errdefer self.destroy();
        self.candidates = saved.candidates;
        for (self.candidates[0..cfg.candidates.len], 1..) |candidate, number| {
            if (candidate.status != .selected) continue;
            const selected = try self.candidateWorktree(number);
            gpa.free(self.worktree);
            self.worktree = selected;
        }
        const worktree_z = std.fmt.bufPrintZ(&buf, "{s}", .{self.worktree}) catch return error.PathTooLong;
        self.worktree_present = pfs.exists(worktree_z.ptr);
        if (saved.initial_checkout_pending) {
            if (self.state != .approved) return error.StateCorrupt;
            try self.completeInitialCheckout();
        }
        self.dispatched = saved.dispatched;
        self.audits = saved.audits;
        self.last_audit = saved.last_audit;
        self.merge_conflicts = saved.merge_conflicts;

        var recovery = try self.dir.recover(gpa);
        defer recovery.deinit(gpa);
        for (recovery.seats) |seat| {
            const id = seat.id();
            const role, const ordinal = parseSeatId(id) orelse continue;
            if (ordinal > self.dispatched.get(role)) self.dispatched.set(role, ordinal);
            var snap: SeatSnapshot = switch (seat) {
                .recorded => |r| .{ .id = id, .role = r.record.role, .harness = r.record.harness, .status = r.record.status, .charter_sha256 = r.record.charter_sha256 },
                .damaged => .{ .id = id, .role = role, .harness = cfg.seats.get(role).harnessKind(), .status = .queued },
            };
            if (!snap.status.isTerminal()) {
                snap.status = .failed;
                snap.result = .interrupted;
                try self.dir.writeSeatRecord(.{ .id = id, .role = snap.role, .harness = snap.harness, .status = .failed, .charter_sha256 = snap.charter_sha256 });
            }
            try self.seats.append(gpa, snap);
        }
        try self.persist();
        return self;
    }

    fn open(
        gpa: std.mem.Allocator,
        deps: Deps,
        cfg: config.Config.Enabled,
        dir: run_dir.RunDir,
        lease: pfs.Fd,
        repo: []u8,
        worktree: []u8,
        base: merge_back.Snapshot,
        state: State,
        request_source: RequestSource,
    ) StartError!*Run {
        var buf: run_dir.PathBuf = undefined;
        var ledger = try ledger_mod.Ledger.load(gpa, try dir.path(&buf, .budget), cfg.budget_usd);
        errdefer ledger.deinit(gpa);
        var ledger_issues = try issues.Ledger.load(gpa, &dir);
        errdefer ledger_issues.deinit();
        const request = try dir.readOriginalRequest(gpa);
        defer gpa.free(request);
        const goal = try gpa.dupe(u8, goalOf(request));
        errdefer gpa.free(goal);

        const self = try gpa.create(Run);
        self.* = .{
            .gpa = gpa,
            .deps = deps,
            .cfg = cfg,
            .dir = dir,
            .lease_fd = lease,
            .ledger = ledger,
            .issues = ledger_issues,
            .abort = types.AbortSignal.init(),
            .state = state,
            .repo = repo,
            .worktree = worktree,
            .worktree_present = false,
            .base = base,
            .request_source = request_source,
            .goal = goal,
        };
        // `self` is heap-allocated, so the ledger may point into it.
        self.ledger.abort_on_exhaustion = &self.abort;
        return self;
    }

    /// Release the run's memory. Disk state is left as it is (a live run can
    /// be reopened later).
    pub fn destroy(self: *Run) void {
        const gpa = self.gpa;
        self.releaseLease();
        self.seats.deinit(gpa);
        gpa.free(self.goal);
        gpa.free(self.worktree);
        gpa.free(self.repo);
        self.issues.deinit();
        self.ledger.deinit(gpa);
        self.dir.deinit(gpa);
        gpa.destroy(self);
    }

    fn releaseLease(self: *Run) void {
        if (self.lease_fd >= 0) pfs.close(self.lease_fd);
        self.lease_fd = pfs.invalid_fd;
    }

    // ── operations ──────────────────────────────────────────────────────────

    /// The run as plain data.
    pub fn status(self: *const Run) RunSnapshot {
        return .{
            .run_id = self.dir.run_id,
            .goal = self.goal,
            .state = self.state,
            .seats = self.seats.items,
            .budget = .{
                .cap_usd = self.ledger.cap_usd,
                .spent_usd = self.ledger.spent_usd,
                .remaining_usd = self.ledger.remainingUsd(),
                .charges = self.ledger.entries,
            },
            .open_issues = self.issues.openCount(),
            .audit = .{ .used = self.audits, .last = self.last_audit },
            .max_rounds = self.cfg.max_rounds,
            .worktree = if (self.worktree_present) self.worktree else null,
            .merge_conflicts = self.merge_conflicts,
            .candidates = self.candidates[0..self.cfg.candidates.len],
        };
    }

    /// Run one implementer or reviewer seat to its end and judge it.
    /// `instructions` are the manager's notes for the packet (may be empty);
    /// they must not name run state (see `InstructionsNameRunState`).
    ///
    /// An implementer works in the run's worktree. A reviewer sees the same
    /// worktree read-only; its review is verified by the runtime
    /// (`reviewer.judgeSeat`: a metacodes reviewer's Bash calls through
    /// `BashCallLog`, the pinned check re-run, zero edits, ledger updates).
    pub fn dispatch(self: *Run, role: Role, instructions: []const u8) Error!SeatId {
        if (!self.deps.preview.teamwork) return error.PreviewDisabled;
        try self.checkLive();
        const candidates_pending = self.state == .approved and self.cfg.candidates.len != 0;
        switch (role) {
            .implementer => switch (self.state) {
                .approved => if (candidates_pending) return error.CandidatesPending,
                .implementing, .reviewing, .review_approved => {},
                else => return error.RunEnded,
            },
            .reviewer => switch (self.state) {
                .reviewing, .review_approved => {},
                .approved => return if (candidates_pending) error.CandidatesPending else error.NothingToReview,
                .implementing => return error.NothingToReview,
                else => return error.RunEnded,
            },
            .interviewer, .manager, .verifier, .judge => return error.RoleNotDispatchable,
        }
        if (self.namesRunState(instructions)) return error.InstructionsNameRunState;
        if (self.dispatched.get(role) >= self.dispatchCap(role)) {
            try self.transition(.{ .failed = .rounds_exhausted });
            return error.RoundsExhausted;
        }

        const spec = self.cfg.seats.getPtrConst(role);
        const packet = try self.renderPacket(role, instructions);
        defer self.gpa.free(packet);
        const id = try self.openSeat(role, spec, packet);
        if (role == .implementer) try self.transition(.implementing) else try self.transition(.reviewing);
        try self.setSeatStatus(id, .working);

        const result: SeatResult = switch (role) {
            .implementer => try self.runImplementer(id, spec, self.worktree),
            .reviewer => try self.runReviewer(id, spec, self.worktree, .{ .run = self.dispatched.get(.reviewer) }),
            else => unreachable,
        };
        try self.closeSeat(id, result);
        if (try self.stopAfterSeat(result)) return id;
        switch (result) {
            .finished => try self.transition(.reviewing),
            .review => |review| switch (review) {
                .approved => |tree| try self.transition(.{ .review_approved = tree }),
                .changes_requested, .rejected => try self.transition(.implementing),
                .unjudgeable => try self.transition(.reviewing),
            },
            // The same round runs again with a new seat, within the cap.
            .failed, .interrupted => try self.persist(),
            .budget_exhausted, .aborted, .judgment => unreachable,
        }
        return id;
    }

    pub fn runCandidates(self: *Run) Error!CandidatesResult {
        if (!self.deps.preview.teamwork) return error.PreviewDisabled;
        try self.checkLive();
        const count = self.cfg.candidates.len;
        if (count == 0 or self.state != .approved) return error.NoCandidates;
        if (candidateEstimate(self.cfg) > self.ledger.remainingUsd()) return error.CandidateBudgetExceeded;
        try self.transition(.candidates);

        var trials: [config.max_candidates]Trial = @splat(.{});
        for (self.cfg.candidates.slice(), 1..) |*spec, number| {
            if (try self.runCandidate(spec, number, &trials[number - 1])) return self.endedResult();
        }

        var facts: [config.max_candidates][160]u8 = undefined;
        var entries: [config.max_candidates]judge.Entry = undefined;
        var any_eligible = false;
        for (entries[0..count], trials[0..count], 0..) |*entry, trial, index| {
            const eligible = self.candidates[index].status == .approved;
            entry.* = .{ .eligible = eligible, .fact = trial.fact(&facts[index], eligible) };
            any_eligible = any_eligible or eligible;
        }
        if (!any_eligible) {
            try self.transition(.{ .failed = .no_candidate_approved });
            return self.endedResult();
        }

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const judgment = try self.runJudge(arena_state.allocator(), entries[0..count], trials[0..count]) orelse return self.endedResult();
        const selected = judgment.selected;
        for (self.candidates[0..count], 1..) |*candidate, number| {
            if (number == selected) {
                candidate.status = .selected;
                continue;
            }
            if (candidate.status == .approved) candidate.status = .eliminated;
            const path = try self.candidateWorktree(number);
            defer self.gpa.free(path);
            _ = merge_back.removeWorktree(self.gpa, self.repo, path);
        }
        const path = try self.candidateWorktree(selected);
        self.gpa.free(self.worktree);
        self.worktree = path;
        self.worktree_present = true;
        try self.recordPitfalls(entries[0..count], judgment);
        try self.transition(.{ .review_approved = self.candidates[selected - 1].tree.? });
        return .{ .selected = selected };
    }

    const Trial = struct {
        implementer: ?SeatResult = null,
        review: ?SeatResult = null,
        reviewer: ?SeatId = null,

        fn fact(self: Trial, buf: []u8, eligible: bool) []const u8 {
            if (eligible) return "passed its verified review";
            if (self.review) |result| return switch (result) {
                .review => |review| switch (review) {
                    .approved => unreachable,
                    .changes_requested => |open_issues| std.fmt.bufPrint(buf, "was not approved: the review requested changes ({d} open issues)", .{open_issues}) catch unreachable,
                    .rejected => |reason| std.fmt.bufPrint(buf, "was not approved: the review did not hold up ({s})", .{@tagName(reason)}) catch unreachable,
                    .unjudgeable => "was not approved: its review could not be judged",
                },
                .failed => |err| std.fmt.bufPrint(buf, "was not approved: its reviewer failed ({s})", .{@tagName(err)}) catch unreachable,
                else => "was not approved: its reviewer did not finish",
            };
            if (self.implementer) |result| return switch (result) {
                .failed => |err| std.fmt.bufPrint(buf, "was not approved: its implementer failed ({s})", .{@tagName(err)}) catch unreachable,
                else => "was not approved: its implementer did not finish",
            };
            return "was not approved: its worktree could not be created";
        }
    };

    fn runCandidate(self: *Run, spec: *const types.SeatSpec, number: usize, trial: *Trial) Error!bool {
        const candidate = &self.candidates[number - 1];
        candidate.status = .implementing;
        const workspace = try self.candidateWorktree(number);
        defer self.gpa.free(workspace);
        var dir_buf: run_dir.PathBuf = undefined;
        const parent = std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ self.dir.root, run_dir.candidates_dir }) catch return error.PathTooLong;
        util_fs.mkdirParents(parent) catch return error.MkdirFailed;
        merge_back.addWorktree(self.gpa, self.repo, workspace, self.base.commit, &self.abort) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Aborted => {
                try self.transition(.cancelled);
                return true;
            },
            else => {
                log.warn("teamwork", "run {s}: candidate {d} worktree: {s}", .{ self.dir.run_id.slice(), number, @errorName(err) });
                candidate.status = .rejected;
                return false;
            },
        };

        const implementer_packet = try self.renderPacket(.implementer, "");
        defer self.gpa.free(implementer_packet);
        const implementer = try self.openSeat(.implementer, spec, implementer_packet);
        try self.setSeatStatus(implementer, .working);
        const built = try self.runImplementer(implementer, spec, workspace);
        trial.implementer = built;
        if (built != .finished) candidate.status = .rejected else candidate.status = .reviewing;
        try self.closeSeat(implementer, built);
        if (try self.stopAfterSeat(built)) return true;
        if (built != .finished) return false;

        const reviewer_spec = self.cfg.seats.getPtrConst(.reviewer);
        const reviewer_packet = try self.renderPacket(.reviewer, "");
        defer self.gpa.free(reviewer_packet);
        const review_seat = try self.openSeat(.reviewer, reviewer_spec, reviewer_packet);
        trial.reviewer = review_seat;
        try self.setSeatStatus(review_seat, .working);
        var candidate_issues = issues.Ledger.init(self.gpa);
        defer candidate_issues.deinit();
        const reviewed = try self.runReviewer(review_seat, reviewer_spec, workspace, .{ .candidate = &candidate_issues });
        trial.review = reviewed;
        switch (reviewed) {
            .review => |review| switch (review) {
                .approved => |tree| candidate.* = .{ .status = .approved, .tree = tree },
                else => candidate.status = .rejected,
            },
            else => candidate.status = .rejected,
        }
        try self.closeSeat(review_seat, reviewed);
        return self.stopAfterSeat(reviewed);
    }

    fn runJudge(self: *Run, arena: std.mem.Allocator, entries: []const judge.Entry, trials: []const Trial) Error!?judge.Judgment {
        const workspace = try self.prepareJudging(entries, trials) orelse {
            try self.transition(.{ .failed = .candidate_git_failed });
            return null;
        };
        defer self.gpa.free(workspace);
        const spec = self.cfg.seats.getPtrConst(.judge);
        const packet = try judge.renderPacket(self.gpa, self.cfg.check_command, entries);
        defer self.gpa.free(packet);
        while (self.dispatched.get(.judge) < self.dispatchCap(.judge)) {
            const id = try self.openSeat(.judge, spec, packet);
            try self.setSeatStatus(id, .working);
            var files: SeatFiles = .{};
            try files.init(&self.dir, id);
            var drivers = self.driversFor(spec, id);
            var outcome = try drivers.driver().run(self.gpa, spec, files.paths(workspace), &self.abort);
            defer outcome.deinit(self.gpa);
            var judgment: judge.Judgment = undefined;
            const result: SeatResult = switch (outcome) {
                .finished => .{ .judgment = try self.readJudgment(arena, id, entries, &judgment) },
                .failed => |err| .{ .failed = err },
                .budget_exhausted => .budget_exhausted,
                .aborted => .aborted,
            };
            try self.closeSeat(id, result);
            if (try self.stopAfterSeat(result)) return null;
            if (result == .judgment and result.judgment == .selected) return judgment;
        }
        try self.transition(.{ .failed = .rounds_exhausted });
        return null;
    }

    fn readJudgment(self: *Run, arena: std.mem.Allocator, id: SeatId, entries: []const judge.Entry, out: *judge.Judgment) error{ OutOfMemory, PathTooLong }!JudgmentResult {
        var buf: run_dir.PathBuf = undefined;
        const text = try run_dir.readSeatOutput(self.gpa, try self.dir.seatPath(&buf, id, .judgment), judge.max_judgment_bytes + 1) orelse
            return .{ .invalid = error.JudgmentMissing };
        defer self.gpa.free(text);
        out.* = judge.parse(arena, text, entries) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => |e| return .{ .invalid = e },
        };
        return .{ .selected = out.selected };
    }

    fn prepareJudging(self: *Run, entries: []const judge.Entry, trials: []const Trial) Error!?[]u8 {
        const workspace = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.dir.root, run_dir.judging_dir });
        errdefer self.gpa.free(workspace);
        util_fs.mkdirParents(workspace) catch return error.MkdirFailed;
        var file_buf: run_dir.PathBuf = undefined;
        var name_buf: [48]u8 = undefined;
        for (entries, trials, 0..) |entry, trial, index| {
            if (!entry.eligible) continue;
            const number = index + 1;
            const diff = merge_back.diffPatch(self.gpa, self.repo, self.base.commit, self.candidates[index].tree.?, &self.abort) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.warn("teamwork", "run {s}: candidate {d} diff: {s}", .{ self.dir.run_id.slice(), number, @errorName(err) });
                    self.gpa.free(workspace);
                    return null;
                },
            };
            defer self.gpa.free(diff);
            const diff_path = std.fmt.bufPrintZ(&file_buf, "{s}/{s}", .{ workspace, judge.diffFile(&name_buf, number) }) catch return error.PathTooLong;
            try run_dir.writeAtomic(diff_path, diff);
            const review_path = try self.dir.seatPath(&file_buf, trial.reviewer.?, .review);
            const review = try run_dir.readSeatOutput(self.gpa, review_path, reviewer.max_review_bytes + 1) orelse continue;
            defer self.gpa.free(review);
            const copy_path = std.fmt.bufPrintZ(&file_buf, "{s}/{s}", .{ workspace, judge.reviewFile(&name_buf, number) }) catch return error.PathTooLong;
            try run_dir.writeAtomic(copy_path, review);
        }
        return workspace;
    }

    fn recordPitfalls(self: *Run, entries: []const judge.Entry, judgment: judge.Judgment) error{OutOfMemory}!void {
        const sink = self.deps.pitfalls orelse return;
        var binding: lesson.Binding = .{ .verdict = .failed, .task = lesson.NO_TASK, .run = self.dir.run_id.slice() };
        for (entries, 1..) |entry, number| {
            const reason = judgment.reasons[number - 1] orelse continue;
            const text = try judge.renderLesson(self.gpa, .{
                .run = self.dir.run_id,
                .goal = self.goal,
                .number = number,
                .selected = judgment.selected,
                .fact = entry.fact,
                .reason = reason,
            });
            defer self.gpa.free(text);
            const envelope = lesson.parse(text) catch |err| {
                log.warn("teamwork", "run {s}: candidate {d} lesson refused: {s}", .{ self.dir.run_id.slice(), number, @errorName(err) });
                continue;
            };
            lesson.checkBinding(envelope, &binding) catch |err| {
                log.warn("teamwork", "run {s}: candidate {d} lesson refused: {s}", .{ self.dir.run_id.slice(), number, @errorName(err) });
                continue;
            };
            if (!binding.reserve()) break;
            if (!sink.remember(text)) {
                binding.release();
                log.warn("teamwork", "run {s}: candidate {d} lesson not stored", .{ self.dir.run_id.slice(), number });
            }
        }
    }

    fn endedResult(self: *const Run) CandidatesResult {
        return switch (self.state) {
            .budget_exhausted => .budget_exhausted,
            .cancelled => .cancelled,
            .failed => |failure| .{ .failed = failure },
            else => unreachable,
        };
    }

    fn candidateWorktree(self: *const Run, number: usize) error{OutOfMemory}![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/{s}/candidate-{d}", .{ self.dir.root, run_dir.candidates_dir, number });
    }

    fn dispatchCap(self: *const Run, role: Role) u32 {
        const extra: u32 = switch (role) {
            .implementer, .reviewer => self.cfg.candidates.len -| 1,
            else => 0,
        };
        return self.cfg.max_rounds + extra;
    }

    fn openSeat(self: *Run, role: Role, spec: *const types.SeatSpec, packet: []const u8) Error!SeatId {
        const ordinal = self.dispatched.get(role) + 1;
        const id = types.seatIdFor(role, ordinal);
        const charter_digest = std.fmt.bytesToHex(charters.digest(role), .lower);
        try self.dir.createSeat(.{ .id = id, .role = role, .harness = spec.harnessKind(), .status = .queued, .charter_sha256 = charter_digest });
        self.dispatched.set(role, ordinal);
        try self.seats.append(self.gpa, .{ .id = id, .role = role, .harness = spec.harnessKind(), .status = .queued, .charter_sha256 = charter_digest });
        self.emit(.{ .seat = .{ .id = id, .from = null, .to = .queued } });
        try self.dir.writePacket(id, packet);
        try self.issues.writeSeatCopy(self.gpa, &self.dir, id);
        return id;
    }

    fn closeSeat(self: *Run, id: SeatId, result: SeatResult) Error!void {
        self.seats.items[self.seats.items.len - 1].result = result;
        try self.setSeatStatus(id, switch (result) {
            .finished, .review, .judgment => .done,
            .failed, .budget_exhausted, .aborted, .interrupted => .failed,
        });
    }

    fn stopAfterSeat(self: *Run, result: SeatResult) Error!bool {
        if (self.ledger.isExhausted() or result == .budget_exhausted) {
            try self.endForBudget();
            return true;
        }
        if (result == .aborted or self.abort.isAborted()) {
            try self.transition(.cancelled);
            return true;
        }
        return false;
    }

    /// Ask the runtime to complete the run. Only from `review_approved`; the
    /// runtime confirms the approval still binds the worktree, runs the
    /// completion audit (at most `max_audits`), and on a pass merges the
    /// approved tree into the user's workspace. Nothing else reaches `done`.
    pub fn requestCompletion(self: *Run) Error!CompletionResult {
        if (!self.deps.preview.teamwork) return error.PreviewDisabled;
        try self.checkLive();
        const approved = switch (self.state) {
            .review_approved => |tree| tree,
            else => return error.NotApproved,
        };
        const current = reviewer.workspaceTree(self.gpa, self.worktree, self.dir.root, &self.abort) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Aborted => return self.settleAbort(),
            else => return self.failWith(.approval_unconfirmable),
        };
        if (!approved.eql(current)) {
            try self.transition(.reviewing);
            return .approval_stale;
        }

        try self.transition(.{ .auditing = approved });
        const attempt = self.audits + 1;
        var scratch_buf: run_dir.PathBuf = undefined;
        const scratch = try self.auditPath(&scratch_buf, attempt, "");
        util_fs.mkdirParents(scratch) catch return error.MkdirFailed;
        const request = try self.dir.readOriginalRequest(self.gpa);
        defer self.gpa.free(request);
        var verdict = try self.deps.auditor.audit(self.gpa, .{
            .preview = self.deps.preview,
            .original_request = request,
            .workspace = self.worktree,
            .approved_tree = approved,
            .base = self.base.commit.slice(),
            .check = self.cfg.check_command,
            .attempt = attempt,
            .scratch_dir = scratch,
            .ledger = &self.ledger,
            .abort = &self.abort,
        });
        defer verdict.deinit(self.gpa);
        try self.writeAuditReport(attempt, &verdict);
        self.audits = attempt;
        self.last_audit = std.meta.activeTag(verdict);

        if (self.ledger.isExhausted()) {
            try self.endForBudget();
            return .budget_exhausted;
        }
        if (self.abort.isAborted()) return self.settleAbort();
        switch (verdict) {
            .pass => |tree| if (!tree.eql(approved)) return self.failWith(.audit_changed_worktree),
            .fail => {
                if (attempt < max_audits) {
                    try self.transition(.implementing);
                    return .repair_requested;
                }
                return self.failWith(.audit_failed);
            },
            .unverified => return self.failWith(.audit_unverified),
            .unavailable => return self.failWith(.audit_unavailable),
        }

        const after = self.deps.recheck_audited_tree(self.gpa, self.worktree, self.dir.root, &self.abort) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Aborted => return self.settleAbort(),
            else => return self.failWith(.approval_unconfirmable),
        };
        if (self.abort.isAborted()) return self.settleAbort();
        if (!after.eql(approved)) return self.failWith(.audit_changed_worktree);
        try self.transition(.{ .merging = approved });
        return self.mergeBack(approved);
    }

    /// Stop the run: every live seat is aborted through the shared signal
    /// and the run ends `cancelled`. The user's workspace is not touched;
    /// the worktree is kept. Idempotent on an ended run.
    pub fn cancel(self: *Run) Error!void {
        if (self.state.isTerminal()) return;
        self.abort.abort(.user_interrupt);
        try self.transition(.cancelled);
    }

    // ── seats ───────────────────────────────────────────────────────────────

    const Drivers = union(enum) {
        harness: factory.Driver,
        custom: types.SeatDriver,

        fn driver(self: *Drivers) types.SeatDriver {
            return switch (self.*) {
                .harness => |*d| d.driver(),
                .custom => |d| d,
            };
        }
    };

    fn driversFor(self: *Run, spec: *const types.SeatSpec, id: SeatId) Drivers {
        const binding: common.Binding = .{ .ledger = &self.ledger, .seat = id };
        return switch (self.deps.seats) {
            .harness => |configured| blk: {
                var deps = configured;
                deps.metacodes.preview = self.deps.preview;
                deps.claude_code.preview = self.deps.preview;
                break :blk .{ .harness = factory.forSeat(spec, deps, binding) };
            },
            .custom => |c| .{ .custom = c.driverFn(c.ctx, spec, binding) },
        };
    }

    const SeatFiles = struct {
        packet: run_dir.PathBuf = undefined,
        handoff: run_dir.PathBuf = undefined,
        packet_len: usize = 0,
        handoff_len: usize = 0,

        fn init(self: *SeatFiles, run: *const run_dir.RunDir, id: SeatId) error{PathTooLong}!void {
            self.packet_len = (try run.seatPath(&self.packet, id, .packet)).len;
            self.handoff_len = (try run.seatPath(&self.handoff, id, .handoff)).len;
        }

        fn paths(self: *const SeatFiles, workspace: []const u8) types.SeatPaths {
            return .{ .packet = self.packet[0..self.packet_len], .handoff = self.handoff[0..self.handoff_len], .workspace = workspace };
        }
    };

    fn runImplementer(self: *Run, id: SeatId, spec: *const types.SeatSpec, workspace: []const u8) Error!SeatResult {
        var files: SeatFiles = .{};
        try files.init(&self.dir, id);
        var drivers = self.driversFor(spec, id);
        var outcome = try drivers.driver().run(self.gpa, spec, files.paths(workspace), &self.abort);
        defer outcome.deinit(self.gpa);
        return switch (outcome) {
            .finished => .finished,
            .failed => |err| .{ .failed = err },
            .budget_exhausted => .budget_exhausted,
            .aborted => .aborted,
        };
    }

    const ReviewLedger = union(enum) {
        run: u32,
        candidate: *issues.Ledger,
    };

    fn runReviewer(self: *Run, id: SeatId, spec: *const types.SeatSpec, workspace: []const u8, ledger: ReviewLedger) Error!SeatResult {
        var files: SeatFiles = .{};
        try files.init(&self.dir, id);
        const before = reviewer.workspaceTree(self.gpa, workspace, self.dir.root, &self.abort) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Aborted => return .aborted,
            else => return .{ .review = .unjudgeable },
        };

        var calls = reviewer.BashCallLog.init(self.gpa, null);
        defer calls.deinit();
        var drivers = self.driversFor(spec, id);
        // A metacodes reviewer's Bash calls are observed at the dispatch
        // seam, so its evidence is checked against what really ran.
        const observable = switch (drivers) {
            .harness => |*d| switch (d.*) {
                .metacodes => |*m| blk: {
                    m.tool_observer = calls.sink();
                    break :blk true;
                },
                .claude_code => false,
            },
            .custom => false,
        };
        var outcome = try drivers.driver().run(self.gpa, spec, files.paths(workspace), &self.abort);
        defer outcome.deinit(self.gpa);
        switch (outcome) {
            .finished => {},
            .failed => |err| return .{ .failed = err },
            .budget_exhausted => return .budget_exhausted,
            .aborted => return .aborted,
        }
        const after = reviewer.workspaceTree(self.gpa, workspace, self.dir.root, &self.abort) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Aborted => return .aborted,
            else => return .{ .review = .unjudgeable },
        };
        var check_runner = self.deps.check_runner;
        var check_tmp_buf: run_dir.PathBuf = undefined;
        if (self.cfg.check_command != null) {
            const check_tmp = std.fmt.bufPrintZ(&check_tmp_buf, "{s}/check-{s}", .{ self.dir.root, id.slice() }) catch return error.PathTooLong;
            // The completed seat could have replaced an entry in its output
            // directory. Its paths must not become a new sandbox write grant.
            if (pfs.mkdir(check_tmp.ptr, 0o700) != 0) return error.MkdirFailed;
            check_runner.private_temp = check_tmp;
        }
        const context: reviewer.Context = .{
            .observed = if (observable) .{ .calls = calls.calls() } else .unobservable,
            .check = self.cfg.check_command,
            .runner = check_runner,
            .workspace = workspace,
            .tree_before = before,
            .tree_after = after,
            .round = switch (ledger) {
                .run => |round| round,
                .candidate => 1,
            },
            .abort = &self.abort,
        };
        const judged = switch (ledger) {
            .run => reviewer.judgeSeat(self.gpa, &self.dir, id, &self.issues, context),
            .candidate => |candidate_issues| reviewer.judgeSeatReview(self.gpa, &self.dir, id, candidate_issues, context),
        } catch |err| switch (err) {
            error.Aborted => return .aborted,
            else => |e| return e,
        };
        return .{ .review = switch (judged) {
            .approved => |approval| .{ .approved = approval.tree },
            .changes_requested => |summary| .{ .changes_requested = summary.open_total },
            .review_rejected => |reason| .{ .rejected = std.meta.activeTag(reason) },
        } };
    }

    fn setSeatStatus(self: *Run, id: SeatId, seat_status: types.SeatStatus) Error!void {
        for (self.seats.items) |*seat| {
            if (!seat.id.eql(id)) continue;
            const previous = seat.status;
            seat.status = seat_status;
            try self.dir.writeSeatRecord(.{ .id = id, .role = seat.role, .harness = seat.harness, .status = seat_status, .charter_sha256 = seat.charter_sha256 });
            if (previous != seat_status) self.emit(.{ .seat = .{ .id = id, .from = previous, .to = seat_status } });
            return;
        }
        return error.SeatNotFound;
    }

    // ── packets ─────────────────────────────────────────────────────────────

    /// A seat's packet: fixed text, the run's own facts named by paths
    /// relative to the seat directory, the open issues, and the manager's
    /// notes. No run id, absolute path or time (cache contract).
    fn renderPacket(self: *const Run, role: Role, instructions: []const u8) Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        const w = &out.writer;
        switch (role) {
            .reviewer => {
                const base = try reviewer.renderPacket(self.gpa, .{ .check = self.cfg.check_command, .ledger = &self.issues });
                defer self.gpa.free(base);
                w.writeAll(base) catch return error.OutOfMemory;
            },
            else => self.writeImplementerPacket(w) catch return error.OutOfMemory,
        }
        if (self.last_audit != null and self.last_audit.? == .fail) {
            w.print(
                \\
                \\## Completion audit
                \\
                \\The completion audit found that the result does not yet fulfil the request. Its report is `{s}` (relative to the directory of this packet). Every finding in it must be addressed; a second failed audit ends the run.
                \\
            , .{run_dir.seat_relative_first_audit_report}) catch return error.OutOfMemory;
        }
        const notes = std.mem.trim(u8, instructions, " \t\r\n");
        if (notes.len != 0) {
            w.print("\n## Notes from the manager\n\n{s}\n", .{notes}) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice() catch error.OutOfMemory;
    }

    fn writeImplementerPacket(self: *const Run, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print(
            \\# Implement
            \\
            \\Make the change requested in `{s}` (relative to the directory of this packet). Your working directory is a git worktree of the user's repository made for this run; change files there. Do not commit, and do not create or move git refs: the runtime collects the diff itself.
            \\
            \\## Pinned check
            \\
            \\
        , .{run_dir.seat_relative_original_request});
        if (self.cfg.check_command) |check| {
            try w.writeAll("The reviewer must run this command from the workspace root and the runtime runs it again; it has to pass:\n\n```\n");
            try w.writeAll(check.text);
            try w.writeAll("\n```\n\n");
        } else {
            try w.writeAll("None is configured. Leave the change in a state the reviewer can test.\n\n");
        }
        try self.issues.renderOpen(w);
        try w.print(
            \\
            \\A read-only copy of the full issue ledger is `{s}` next to this packet. Fix every open issue.
            \\
            \\## Output
            \\
            \\Next to this packet write `handoff.md` with the sections `## Observation`, `## Reasoning`, `## Caveats`, `## Conclusion` and `## Verification`.
            \\
        , .{run_dir.seat_relative_open_issues_copy});
    }

    fn namesRunState(self: *const Run, text: []const u8) bool {
        const id = self.dir.run_id;
        const needles = [_][]const u8{ self.dir.root, self.worktree, self.repo, id.slice() };
        for (needles) |needle| {
            if (needle.len != 0 and std.mem.indexOf(u8, text, needle) != null) return true;
        }
        return false;
    }

    // ── completion ──────────────────────────────────────────────────────────

    /// `audits/audit-<n><suffix>` in the run directory.
    fn auditPath(self: *const Run, buf: *run_dir.PathBuf, attempt: u8, suffix: []const u8) Error![:0]const u8 {
        return std.fmt.bufPrintZ(buf, "{s}/{s}/audit-{d}{s}", .{ self.dir.root, run_dir.audits_dir, attempt, suffix }) catch error.PathTooLong;
    }

    fn writeAuditReport(self: *const Run, attempt: u8, verdict: *const audit.AuditVerdict) Error!void {
        var buf: run_dir.PathBuf = undefined;
        const path = try self.auditPath(&buf, attempt, ".md");
        const text = try std.fmt.allocPrint(self.gpa, "# Completion audit {d}: {s}\n\n{s}", .{ attempt, @tagName(verdict.*), verdict.report() });
        defer self.gpa.free(text);
        try run_dir.writeAtomic(path, text);
    }

    fn mergeBack(self: *Run, approved: TreeId) Error!CompletionResult {
        if (!self.deps.preview.teamwork) return error.PreviewDisabled;
        var patch_buf: run_dir.PathBuf = undefined;
        var conflicts_buf: run_dir.PathBuf = undefined;
        const merged = merge_back.mergeBack(self.gpa, .{
            .repo = self.repo,
            .base = self.base,
            .approved = approved,
            .scratch_dir = self.dir.root,
            .patch_path = try self.dir.path(&patch_buf, .merge_patch),
            .conflicts_path = try self.dir.path(&conflicts_buf, .merge_conflicts),
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("teamwork", "run {s}: merge-back failed: {s}", .{ self.dir.run_id.slice(), @errorName(err) });
                return self.failWith(.merge_failed);
            },
        };
        switch (merged) {
            .applied => |applied| {
                const removed = merge_back.removeWorktree(self.gpa, self.repo, self.worktree);
                self.worktree_present = !removed;
                const done: Done = .{ .files_changed = applied.files, .worktree_removed = removed };
                try self.transition(.{ .done = done });
                return .{ .done = done };
            },
            .conflict => |n| {
                self.merge_conflicts = n;
                return self.failWith(.merge_conflict);
            },
            .apply_failed => return self.failWith(.merge_failed),
        }
    }

    // ── transitions ─────────────────────────────────────────────────────────

    /// Fail on an ended run; turn a pending stop (no budget left, or the
    /// shared signal tripped) into its terminal state first.
    fn checkLive(self: *Run) Error!void {
        if (self.state.isTerminal()) return error.RunEnded;
        if (self.ledger.remainingUsd() <= 0) {
            try self.endForBudget();
            return error.BudgetExhausted;
        }
        if (self.abort.isAborted()) {
            try self.transition(.cancelled);
            return error.RunEnded;
        }
    }

    fn endForBudget(self: *Run) Error!void {
        self.abort.abort(.host_failure);
        try self.transition(.budget_exhausted);
    }

    fn settleAbort(self: *Run) Error!CompletionResult {
        if (self.ledger.isExhausted()) {
            try self.endForBudget();
            return .budget_exhausted;
        }
        try self.transition(.cancelled);
        return .cancelled;
    }

    fn failWith(self: *Run, failure: Failure) Error!CompletionResult {
        try self.transition(.{ .failed = failure });
        return .{ .failed = failure };
    }

    /// Move to `next` if the table allows it, and persist. An illegal
    /// transition is a runtime bug: it is refused and logged.
    fn transition(self: *Run, next: State) Error!void {
        if (!allowed(self.state.phase(), next.phase())) {
            log.err("teamwork", "run {s}: illegal transition {s} -> {s}", .{ self.dir.run_id.slice(), @tagName(self.state.phase()), @tagName(next.phase()) });
            return error.IllegalTransition;
        }
        const previous = self.state.phase();
        self.state = next;
        try self.persist();
        if (next.isTerminal()) self.releaseLease();
        if (previous != next.phase()) self.emit(.{ .phase = .{ .from = .of(previous), .to = .of(next.phase()) } });
    }

    fn emit(self: *const Run, change: progress.Change) void {
        const observer = self.deps.observer orelse return;
        const event: progress.Event = .{ .change = change, .snapshot = .ofRun(self.status()) };
        observer.notify(&event);
    }

    // ── run.json ────────────────────────────────────────────────────────────

    fn persist(self: *const Run) Error!void {
        var out: std.Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        self.writeState(&out.writer) catch return error.OutOfMemory;
        var buf: run_dir.PathBuf = undefined;
        try run_dir.writeAtomic(try self.dir.path(&buf, .state), out.written());
    }

    fn writeState(self: *const Run, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var s: std.json.Stringify = .{ .writer = w };
        try s.beginObject();
        try s.objectField("config_sha256");
        const fingerprint = configFingerprint(self.gpa, self.cfg) catch return error.WriteFailed;
        const fingerprint_hex = std.fmt.bytesToHex(fingerprint, .lower);
        try s.write(fingerprint_hex[0..]);
        if (self.deps.cli_approval) |approval| {
            try s.objectField("approved_config_json");
            try s.write(approval.config_json);
            try s.objectField("host_policy_sha256");
            const host_hex = std.fmt.bytesToHex(approval.host_sha256, .lower);
            try s.write(host_hex[0..]);
        }
        try s.objectField("request_source");
        try s.write(@tagName(self.request_source));
        try s.objectField("initial_checkout_pending");
        try s.write(self.state == .approved and !self.worktree_present and self.cfg.candidates.len == 0);
        try s.objectField("state");
        try s.write(@tagName(self.state.phase()));
        try s.objectField("detail");
        switch (self.state) {
            .review_approved, .auditing, .merging => |tree| try s.write(tree.slice()),
            .failed => |failure| try s.write(@tagName(failure)),
            .done => |done| {
                try s.beginObject();
                try s.objectField("files_changed");
                try s.write(done.files_changed);
                try s.objectField("worktree_removed");
                try s.write(done.worktree_removed);
                try s.endObject();
            },
            .approved, .candidates, .implementing, .reviewing, .budget_exhausted, .cancelled => try s.write(null),
        }
        try s.objectField("repo");
        try s.write(self.repo);
        try s.objectField("base_commit");
        try s.write(self.base.commit.slice());
        try s.objectField("start_tree");
        try s.write(self.base.tree.slice());
        try s.objectField("dispatched");
        try s.beginObject();
        for (std.enums.values(Role)) |role| {
            try s.objectField(role.name());
            try s.write(self.dispatched.get(role));
        }
        try s.endObject();
        try s.objectField("audits");
        try s.write(self.audits);
        try s.objectField("last_audit");
        if (self.last_audit) |kind| try s.write(@tagName(kind)) else try s.write(null);
        try s.objectField("merge_conflicts");
        try s.write(self.merge_conflicts);
        try s.objectField("candidates");
        try s.beginArray();
        for (self.candidates[0..self.cfg.candidates.len]) |candidate| {
            try s.beginObject();
            try s.objectField("status");
            try s.write(@tagName(candidate.status));
            try s.objectField("tree");
            if (candidate.tree) |tree| try s.write(tree.slice()) else try s.write(null);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
        try w.writeAll("\n");
    }
};

fn candidateEstimate(cfg: config.Config.Enabled) f64 {
    return @as(f64, @floatFromInt(cfg.candidates.len)) * (cfg.candidate_estimate_usd orelse 0);
}

fn checkCandidateBudget(gpa: std.mem.Allocator, dir: *const run_dir.RunDir, cfg: config.Config.Enabled) StartError!void {
    if (cfg.candidates.len == 0) return;
    var buf: run_dir.PathBuf = undefined;
    var ledger = try ledger_mod.Ledger.load(gpa, try dir.path(&buf, .budget), cfg.budget_usd);
    defer ledger.deinit(gpa);
    if (candidateEstimate(cfg) > ledger.remainingUsd()) return error.CandidateBudgetExceeded;
}

fn acquireLease(dir: *const run_dir.RunDir) Error!pfs.Fd {
    var buf: run_dir.PathBuf = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/runtime.lock", .{dir.root}) catch return error.PathTooLong;
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true }, 0o600);
    if (fd < 0) return error.LeaseFailed;
    errdefer pfs.close(fd);
    pfs.tryLockExclusive(fd) catch |err| return switch (err) {
        error.WouldBlock => error.RunBusy,
        error.LockFailed => error.LeaseFailed,
    };
    return fd;
}

const Saved = struct {
    config_sha256: [32]u8,
    host_sha256: ?[32]u8,
    initial_checkout_pending: bool,
    state: State,
    repo: []const u8,
    base: merge_back.Snapshot,
    request_source: RequestSource,
    dispatched: std.EnumArray(Role, u32),
    audits: u8,
    last_audit: ?audit.VerdictKind,
    merge_conflicts: u32,
    candidates: [config.max_candidates]CandidateSnapshot,
};

fn parseSaved(arena: std.mem.Allocator, text: []const u8) !Saved {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    if (root != .object) return error.StateCorrupt;
    const obj = root.object;
    const phase = Phase.parse(try stringField(obj, "state")) orelse return error.StateCorrupt;
    const detail = obj.get("detail") orelse return error.StateCorrupt;
    const state: State = switch (phase) {
        .approved => .approved,
        .candidates => .candidates,
        .implementing => .implementing,
        .reviewing => .reviewing,
        .budget_exhausted => .budget_exhausted,
        .cancelled => .cancelled,
        .review_approved => .{ .review_approved = try treeOf(detail) },
        .auditing => .{ .auditing = try treeOf(detail) },
        .merging => .{ .merging = try treeOf(detail) },
        .failed => .{ .failed = Failure.parse(if (detail == .string) detail.string else return error.StateCorrupt) orelse return error.StateCorrupt },
        .done => blk: {
            if (detail != .object) return error.StateCorrupt;
            break :blk .{ .done = .{
                .files_changed = try intField(u32, detail.object, "files_changed"),
                .worktree_removed = switch (detail.object.get("worktree_removed") orelse return error.StateCorrupt) {
                    .bool => |b| b,
                    else => return error.StateCorrupt,
                },
            } };
        },
    };
    var dispatched: std.EnumArray(Role, u32) = .initFill(0);
    const counts = obj.get("dispatched") orelse return error.StateCorrupt;
    if (counts != .object) return error.StateCorrupt;
    for (std.enums.values(Role)) |role| {
        if (role == .judge and counts.object.get(role.name()) == null) continue;
        dispatched.set(role, try intField(u32, counts.object, role.name()));
    }
    var candidates: [config.max_candidates]CandidateSnapshot = @splat(.{});
    if (obj.get("candidates")) |list| {
        if (list != .array or list.array.items.len > config.max_candidates) return error.StateCorrupt;
        for (list.array.items, candidates[0..list.array.items.len]) |item, *candidate| {
            if (item != .object) return error.StateCorrupt;
            candidate.* = .{
                .status = CandidateStatus.parse(try stringField(item.object, "status")) orelse return error.StateCorrupt,
                .tree = switch (item.object.get("tree") orelse return error.StateCorrupt) {
                    .null => null,
                    else => |tree| try treeOf(tree),
                },
            };
        }
    }
    const last_audit: ?audit.VerdictKind = switch (obj.get("last_audit") orelse return error.StateCorrupt) {
        .null => null,
        .string => |name| std.meta.stringToEnum(audit.VerdictKind, name) orelse return error.StateCorrupt,
        else => return error.StateCorrupt,
    };
    return .{
        .config_sha256 = try parseFingerprint(try stringField(obj, "config_sha256")),
        .host_sha256 = if (obj.get("host_policy_sha256")) |value|
            if (value == .string) try parseFingerprint(value.string) else return error.StateCorrupt
        else
            null,
        .initial_checkout_pending = if (obj.get("initial_checkout_pending")) |value|
            if (value == .bool) value.bool else return error.StateCorrupt
        else
            false,
        .state = state,
        .repo = try stringField(obj, "repo"),
        .base = .{
            .commit = try treeOf(obj.get("base_commit") orelse return error.StateCorrupt),
            .tree = try treeOf(obj.get("start_tree") orelse return error.StateCorrupt),
        },
        .request_source = if (obj.get("request_source")) |value|
            if (value == .string) std.meta.stringToEnum(RequestSource, value.string) orelse return error.StateCorrupt else return error.StateCorrupt
        else
            .request_file,
        .dispatched = dispatched,
        .audits = try intField(u8, obj, "audits"),
        .last_audit = last_audit,
        .merge_conflicts = try intField(u32, obj, "merge_conflicts"),
        .candidates = candidates,
    };
}

const roles_before_candidates = @intFromEnum(Role.judge);

const SingleLinePolicy = struct {
    budget_usd: f64,
    check_command: ?config.CheckCommand,
    max_rounds: u32,
    seats: struct { values: [roles_before_candidates]types.SeatSpec },

    fn of(cfg: config.Config.Enabled) SingleLinePolicy {
        return .{
            .budget_usd = cfg.budget_usd,
            .check_command = cfg.check_command,
            .max_rounds = cfg.max_rounds,
            .seats = .{ .values = cfg.seats.values[0..roles_before_candidates].* },
        };
    }
};

fn configFingerprint(gpa: std.mem.Allocator, cfg: config.Config.Enabled) error{OutOfMemory}![32]u8 {
    const bytes = if (cfg.candidates.len == 0)
        try std.json.Stringify.valueAlloc(gpa, SingleLinePolicy.of(cfg), .{})
    else
        try std.json.Stringify.valueAlloc(gpa, cfg, .{});
    defer gpa.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn parseFingerprint(text: []const u8) error{StateCorrupt}![32]u8 {
    if (text.len != 64) return error.StateCorrupt;
    var result: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, text) catch return error.StateCorrupt;
    return result;
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return error.StateCorrupt;
    return if (value == .string) value.string else error.StateCorrupt;
}

fn intField(comptime T: type, obj: std.json.ObjectMap, key: []const u8) !T {
    const value = obj.get(key) orelse return error.StateCorrupt;
    if (value != .integer) return error.StateCorrupt;
    return std.math.cast(T, value.integer) orelse error.StateCorrupt;
}

fn treeOf(value: std.json.Value) !TreeId {
    if (value != .string) return error.StateCorrupt;
    return TreeId.parse(value.string) catch error.StateCorrupt;
}

/// `implementer-3` → (.implementer, 3); null for any other name.
fn parseSeatId(id: SeatId) ?struct { Role, u32 } {
    const text = id.slice();
    const dash = std.mem.lastIndexOfScalar(u8, text, '-') orelse return null;
    const role = Role.parse(text[0..dash]) orelse return null;
    const ordinal = std.fmt.parseInt(u32, text[dash + 1 ..], 10) catch return null;
    return .{ role, ordinal };
}

/// The first non-blank line of the request, at most `goal_max` bytes, cut
/// on a UTF-8 boundary.
pub fn goalOf(request: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, request, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r#");
        if (line.len == 0) continue;
        if (line.len <= goal_max) return line;
        var end: usize = goal_max;
        while (end > 0 and (line[end] & 0xC0) == 0x80) end -= 1;
        return line[0..end];
    }
    return "";
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "runtime: terminal states have no way out; merge-back cannot be cancelled" {
    for (std.enums.values(Phase)) |from| {
        for (std.enums.values(Phase)) |to| {
            if (from.isTerminal()) try testing.expect(!allowed(from, to));
        }
    }
    try testing.expect(!allowed(.merging, .cancelled));
    try testing.expect(!allowed(.merging, .budget_exhausted));
    // `done` is reachable only from merging, merging only from auditing.
    for (std.enums.values(Phase)) |from| {
        if (from != .merging) try testing.expect(!allowed(from, .done));
        if (from != .auditing) try testing.expect(!allowed(from, .merging));
        if (from != .review_approved) try testing.expect(!allowed(from, .auditing));
    }
    try testing.expect(!allowed(.approved, .reviewing));
    try testing.expect(!allowed(.implementing, .review_approved));
}

test "runtime: seat ids and goals" {
    const role, const n = parseSeatId(types.seatIdFor(.reviewer, 12)).?;
    try testing.expectEqual(Role.reviewer, role);
    try testing.expectEqual(@as(u32, 12), n);
    try testing.expect(parseSeatId(try SeatId.parse("helper-1")) == null);
    try testing.expectEqualStrings("Add a --dry-run flag", goalOf("\n# Add a --dry-run flag\n\nDetails."));
    const long = "é" ** 150;
    const goal = goalOf(long);
    try testing.expect(goal.len <= goal_max);
    try testing.expect(std.unicode.utf8ValidateSlice(goal));
}

test "runtime: a run approved before parallel candidates keeps its fingerprint and state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "{\"enabled\":true,\"check_command\":\"test -f feature.txt\",\"budget_usd\":5,\"seats\":{\"implementer\":{\"model\":\"m\"},\"reviewer\":{\"harness\":\"claude_code\",\"command\":\"/opt/claude/bin/claude\"}}}";
    const cfg = (try config.validate(try config.parse(a, text, null), null)).enabled;
    const fingerprint = std.fmt.bytesToHex(try configFingerprint(testing.allocator, cfg), .lower);
    try testing.expectEqualStrings("23d722bfcb25e9ecc9670f4df0d65322477ce0229f114e903e0b0dce2dd30409", &fingerprint);

    const tree = "b" ** 40;
    const saved = try parseSaved(a, "{\"config_sha256\":\"" ++ "c" ** 64 ++ "\",\"request_source\":\"request_file\",\"state\":\"implementing\",\"detail\":null,\"repo\":\"/r\",\"base_commit\":\"" ++ tree ++ "\",\"start_tree\":\"" ++ tree ++ "\",\"dispatched\":{\"manager\":0,\"interviewer\":0,\"implementer\":2,\"reviewer\":1,\"verifier\":0},\"audits\":0,\"last_audit\":null,\"merge_conflicts\":0}");
    try testing.expectEqual(@as(u32, 0), saved.dispatched.get(.judge));
    try testing.expectEqual(@as(u32, 2), saved.dispatched.get(.implementer));
    try testing.expectEqual(CandidateStatus.queued, saved.candidates[0].status);
}
