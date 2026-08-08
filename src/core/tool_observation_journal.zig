//! Durable, run-bound journal for actual tool-dispatch observations.
//!
//! This is execution evidence beside a session transcript, not agent memory and
//! not a canonical TinyKG store. Every complete record is written and fsynced
//! before the observation sink acknowledges it. A partial/corrupt existing
//! journal fails closed before a new run starts. This establishes an observable
//! file-flush boundary; it does not prove a filesystem's power-loss model.

const std = @import("std");
const pfs = @import("platform").fs;
const sync = @import("platform").sync;
const observation = @import("../tools/observation.zig");
const session_id_mod = @import("session_id.zig");
const util_time = @import("../util/time.zig");
const util_fs = @import("../util/fs.zig");

pub const SCHEMA_VERSION = "metacodes-tool-observation-journal-v1";
pub const FILE_NAME = "tool-observations.jsonl";
pub const LOCK_FILE_NAME = "tool-observations.lock";
pub const MAX_ARTIFACT_BYTES: usize = 64 * 1024 * 1024;

pub const JournalEvent = union(enum) {
    run_started: struct {
        started_wall_ns: i128,
    },
    tool_observation: observation.Event,
    run_finished: struct {
        stop_reason: []const u8,
        finished_wall_ns: i128,
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
    requested_name: []const u8,
    dispatched_name: []const u8,
    origin: observation.Origin,
    agent_depth: u8,
    input_bytes: usize,
    input_sha256: [64]u8,
    outcome: observation.Outcome,
    effect: ?observation.Effect,
    effect_valid: bool,
};

pub const RunFormalDecision = struct {
    dispatch_id: []const u8,
    phase: observation.FormalPhase,
    result: observation.FormalResult,
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

pub const BlockedVerdictBinding = struct {
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    bundle_sha256: [64]u8,
    bundle_revision: u64,
};

pub const LoadedRunDispatches = struct {
    arena: std.heap.ArenaAllocator,
    interval_sha256: [64]u8,
    dispatches: []const RunDispatch,
    formal_decisions: []const RunFormalDecision,

    pub fn deinit(self: *LoadedRunDispatches) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Journal = struct {
    mutex: sync.Mutex = .{},
    fd: pfs.Fd,
    lock_fd: pfs.Fd,
    lock_path: [std.fs.max_path_bytes + 1]u8,
    lock_path_len: usize,
    session_id: session_id_mod.SessionId,
    run_id: session_id_mod.SessionId,
    run_first_sequence: u64,
    sequence: u64,
    file_bytes: usize,
    started_ns: i128,
    finished: bool = false,
    failed: bool = false,
    lock_released: bool = false,

    /// Open the session-owned append-only artifact, validate every existing
    /// record, then durably publish this run's identity before any provider or
    /// tool action can use the returned sink.
    pub fn init(
        session_dir: []const u8,
        session_id: session_id_mod.SessionId,
    ) !Journal {
        var lock_path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const lock_path = try std.fmt.bufPrint(
            &lock_path_buf,
            "{s}/{s}\x00",
            .{ session_dir, LOCK_FILE_NAME },
        );
        const lock_fd = pfs.open(
            @ptrCast(lock_path.ptr),
            .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true },
            @as(std.c.mode_t, 0o600),
        );
        if (lock_fd < 0) return error.JournalBusy;
        errdefer {
            _ = pfs.close(lock_fd);
            pfs.unlinkPath(@ptrCast(lock_path.ptr)) catch {};
        }
        try pfs.makeCloseOnExec(lock_fd);
        try pfs.fsyncChecked(lock_fd);

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

        const summary = try validateFd(fd, session_id, null, null);
        if (!summary.complete) return error.UnfinishedRun;
        if (pfs.lseek(fd, 0, .end) < 0) return error.SeekFailed;

        var journal = Journal{
            .fd = fd,
            .lock_fd = lock_fd,
            .lock_path = lock_path_buf,
            .lock_path_len = lock_path.len - 1,
            .session_id = session_id,
            .run_id = session_id_mod.gen(),
            .run_first_sequence = summary.records,
            .sequence = summary.records,
            .file_bytes = summary.bytes,
            .started_ns = util_time.nowNs(),
        };
        try journal.appendEvent(.{ .run_started = .{
            .started_wall_ns = util_time.nowWallNs(),
        } });
        try fsyncDirectory(session_dir);
        return journal;
    }

    pub fn deinit(self: *Journal) void {
        if (self.fd >= 0) _ = pfs.close(self.fd);
        self.fd = -1;
        if (self.lock_fd >= 0) _ = pfs.close(self.lock_fd);
        self.lock_fd = -1;
        // A clean terminal record releases the lease. Any other path leaves the
        // marker behind so a later process cannot mistake a crash window for a
        // safely closed Run. Recovery is an explicit audit action, not init().
        if (self.finished and !self.lock_released) self.unlinkLock() catch {};
    }

    pub fn sink(self: *Journal) observation.Sink {
        return .{ .ctx = @ptrCast(self), .emitFn = emitThunk };
    }

    pub fn runId(self: *const Journal) []const u8 {
        return self.run_id.asSlice();
    }

    pub fn runBinding(self: *const Journal) !RunBinding {
        if (!self.finished or !self.lock_released or self.sequence == 0)
            return error.RunNotFinished;
        return .{
            .session_id = self.session_id,
            .run_id = self.run_id,
            .first_sequence = self.run_first_sequence,
            .last_sequence = self.sequence - 1,
        };
    }

    pub fn finishRun(self: *Journal, stop_reason: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failed) return error.JournalFailed;
        if (self.finished) return error.RunAlreadyFinished;
        try self.appendEventLocked(.{ .run_finished = .{
            .stop_reason = stop_reason,
            .finished_wall_ns = util_time.nowWallNs(),
        } });
        self.finished = true;
        if (self.lock_fd >= 0) _ = pfs.close(self.lock_fd);
        self.lock_fd = -1;
        try self.unlinkLock();
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

    fn appendEvent(self: *Journal, event: JournalEvent) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.appendEventLocked(event);
    }

    fn appendEventLocked(self: *Journal, event: JournalEvent) !void {
        if (self.failed) return error.JournalFailed;
        const envelope = Envelope{
            .sequence = self.sequence,
            .monotonic_elapsed_ns = elapsedNs(self.started_ns),
            .session_id = self.session_id.asSlice(),
            .run_id = self.run_id.asSlice(),
            .event = event,
        };
        const line = try std.json.Stringify.valueAlloc(std.heap.c_allocator, envelope, .{});
        defer std.heap.c_allocator.free(line);
        if (line.len + 1 > MAX_ARTIFACT_BYTES -| self.file_bytes)
            return error.ArtifactTooLarge;
        try writeAll(self.fd, line);
        try writeAll(self.fd, "\n");
        try pfs.fsyncChecked(self.fd);
        self.file_bytes += line.len + 1;
        self.sequence += 1;
    }

    fn unlinkLock(self: *Journal) !void {
        self.lock_path[self.lock_path_len] = 0;
        try pfs.unlinkPath(@ptrCast(&self.lock_path));
        const directory = std.fs.path.dirname(self.lock_path[0..self.lock_path_len]) orelse
            return error.InvalidLockPath;
        try fsyncDirectory(directory);
        self.lock_released = true;
    }
};

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
    var formal_decisions: std.ArrayList(RunFormalDecision) = .empty;
    var open = std.AutoHashMap([32]u8, usize).init(a);
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
            .run_finished => if (envelope.sequence != binding.last_sequence)
                return error.InvalidRunBinding,
            .tool_observation => |event| switch (event) {
                .formal_decision => |formal| try formal_decisions.append(a, .{
                    .dispatch_id = formal.dispatch_id,
                    .phase = formal.phase,
                    .result = formal.result,
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
                        .dispatch_id = batch.dispatch_id,
                        .phase = batch.phase,
                        .result = decision.result,
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
                        .requested_name = started.requested_name,
                        .dispatched_name = started.dispatched_name,
                        .origin = started.origin,
                        .agent_depth = started.agent_depth,
                        .input_bytes = started.input_bytes,
                        .input_sha256 = started.input_sha256,
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
                    record.effect = finished.effect;
                    record.effect_valid = finished.effect_valid;
                },
            },
        }
    }
    if (open.count() != 0) return error.InvalidRecord;
    var raw_digest: [32]u8 = undefined;
    interval_hasher.final(&raw_digest);
    const interval_sha256 = std.fmt.bytesToHex(raw_digest, .lower);
    if (!std.mem.eql(u8, &interval_sha256, &validated.interval_sha256))
        return error.ArtifactChanged;
    return .{
        .arena = arena,
        .interval_sha256 = interval_sha256,
        .dispatches = try records.toOwnedSlice(a),
        .formal_decisions = try formal_decisions.toOwnedSlice(a),
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
        if (formal.result == .block and formal.verdict_sha256 != null and
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

fn validateFd(
    fd: pfs.Fd,
    expected_session: session_id_mod.SessionId,
    expected_binding: ?RunBinding,
    interval_sha256_out: ?*[64]u8,
) !ValidationSummary {
    const info = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!info.is_regular or info.link_count != 1) return error.NotRegularFile;
    if (info.size > MAX_ARTIFACT_BYTES) return error.ArtifactTooLarge;
    const size: usize = @intCast(info.size);
    if (pfs.lseek(fd, 0, .set) < 0) return error.SeekFailed;
    const bytes = try std.heap.c_allocator.alloc(u8, size);
    defer std.heap.c_allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = pfs.read(fd, bytes[offset..]);
        if (n <= 0) return error.ReadFailed;
        offset += @intCast(n);
    }
    if (bytes.len > 0 and bytes[bytes.len - 1] != '\n')
        return error.PartialRecord;

    var expected_sequence: u64 = 0;
    var active_run: ?session_id_mod.SessionId = null;
    var active_elapsed_ns: u64 = 0;
    var binding_started = false;
    var binding_finished = false;
    var binding_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var open_dispatches = std.AutoHashMap([32]u8, OpenDispatch).init(std.heap.c_allocator);
    defer open_dispatches.deinit();
    var seen_dispatches = std.AutoHashMap([32]u8, u8).init(std.heap.c_allocator);
    defer seen_dispatches.deinit();
    var formal_events = std.AutoHashMap([32]u8, u8).init(std.heap.c_allocator);
    defer formal_events.deinit();
    var pre_decisions = std.AutoHashMap([32]u8, PreDecision).init(std.heap.c_allocator);
    defer pre_decisions.deinit();
    var formal_dispatches = std.AutoHashMap([32]u8, FormalDispatchState).init(std.heap.c_allocator);
    defer formal_dispatches.deinit();
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
        if (!std.mem.eql(u8, envelope.schema_version, SCHEMA_VERSION) or
            envelope.sequence != expected_sequence or
            !std.mem.eql(u8, envelope.session_id, expected_session.asSlice()))
            return error.InvalidRecord;
        switch (envelope.event) {
            .run_started => {
                if (active_run != null or open_dispatches.count() != 0)
                    return error.InvalidRecord;
                active_run = run_id;
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
                    .formal_decision => |formal| {
                        if (!std.mem.eql(u8, formal.schema_version, observation.FORMAL_SCHEMA_VERSION))
                            return error.InvalidRecord;
                        try acceptFormalDecision(&formal_validation, .{
                            .dispatch_id = formal.dispatch_id,
                            .phase = formal.phase,
                            .result = formal.result,
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
                        });
                    },
                    .formal_decision_batch => |batch| {
                        if (!std.mem.eql(u8, batch.schema_version, observation.FORMAL_BATCH_SCHEMA_VERSION) or
                            batch.decisions.len == 0 or
                            batch.decisions.len > batch.checker_batch_size or
                            batch.checker_batch_size > @import("../formal/project_harness_runtime.zig").MAX_BATCH_REQUESTS or
                            (batch.decisions.len < batch.checker_batch_size and
                                batch.decisions[batch.decisions.len - 1].result == .admit))
                            return error.InvalidRecord;
                        for (batch.decisions) |decision| {
                            try acceptFormalDecision(&formal_validation, .{
                                .dispatch_id = batch.dispatch_id,
                                .phase = batch.phase,
                                .result = decision.result,
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
                            });
                        }
                    },
                    .dispatch_started => |started| {
                        if (!std.mem.eql(u8, started.schema_version, observation.SCHEMA_VERSION))
                            return error.InvalidRecord;
                        const key = dispatchKey(started.id);
                        if (seen_dispatches.contains(key)) return error.InvalidRecord;
                        try seen_dispatches.put(key, 0);
                        const formal_state = formal_dispatches.getPtr(key);
                        if (formal_state) |state| {
                            if (state.terminal_pre or state.pre_count == 0 or state.started)
                                return error.InvalidRecord;
                            state.started = true;
                        }
                        const entry = try open_dispatches.getOrPut(key);
                        if (entry.found_existing) return error.InvalidRecord;
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
                        };
                    },
                    .dispatch_finished => |finished| {
                        if (!std.mem.eql(u8, finished.schema_version, observation.SCHEMA_VERSION))
                            return error.InvalidRecord;
                        const entry = open_dispatches.fetchRemove(dispatchKey(finished.id)) orelse
                            return error.InvalidRecord;
                        if (!std.meta.eql(entry.value.identity, dispatchIdentity(
                            finished.requested_name,
                            finished.dispatched_name,
                            finished.origin,
                            finished.agent_depth,
                        )) or (entry.value.governed and
                            (entry.value.post_count == 0 or
                                (!entry.value.terminal_post and
                                    entry.value.post_count != entry.value.expected_post_count))))
                            return error.InvalidRecord;
                    },
                }
            },
            .run_finished => {
                const current = active_run orelse return error.InvalidRecord;
                if (!std.mem.eql(u8, current.asSlice(), run_id.asSlice()) or
                    envelope.monotonic_elapsed_ns < active_elapsed_ns or
                    open_dispatches.count() != 0)
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
    return .{
        .records = expected_sequence,
        .bytes = size,
        .complete = active_run == null,
        .artifact_sha256 = observation.sha256Hex(bytes),
    };
}

fn dispatchKey(id: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &digest, .{});
    return digest;
}

fn validHex(value: [64]u8) bool {
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
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
};

const FormalDispatchState = struct {
    identity: FormalControlIdentity,
    pre_count: u32,
    terminal_pre: bool,
    started: bool,
};

const PreDecision = struct {
    identity: FormalControlIdentity,
    result: observation.FormalResult,
};

const OpenDispatch = struct {
    identity: DispatchIdentity,
    governed: bool,
    expected_post_count: u32,
    post_count: u32,
    terminal_post: bool,
};

const FormalRecord = struct {
    dispatch_id: []const u8,
    phase: observation.FormalPhase,
    result: observation.FormalResult,
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

const FormalValidationState = struct {
    open_dispatches: *std.AutoHashMap([32]u8, OpenDispatch),
    seen_dispatches: *std.AutoHashMap([32]u8, u8),
    formal_events: *std.AutoHashMap([32]u8, u8),
    pre_decisions: *std.AutoHashMap([32]u8, PreDecision),
    formal_dispatches: *std.AutoHashMap([32]u8, FormalDispatchState),
};

fn acceptFormalDecision(state: *FormalValidationState, formal: FormalRecord) !void {
    if (formal.dispatch_id.len == 0 or formal.dispatch_id.len > 256 or
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
    const event_key = formalKey(formal.dispatch_id, formal.candidate_id, formal.phase);
    if (state.formal_events.contains(event_key)) return error.InvalidRecord;
    try state.formal_events.put(event_key, 0);
    const identity = FormalControlIdentity{
        .project_sha256 = formal.project_sha256,
        .bundle_sha256 = formal.bundle_sha256,
        .bundle_revision = formal.bundle_revision,
        .kernel_sha256 = formal.kernel_sha256,
    };
    switch (formal.phase) {
        .pre => {
            if (state.seen_dispatches.contains(dispatch_key) or
                state.open_dispatches.contains(dispatch_key))
                return error.InvalidRecord;
            const state_entry = try state.formal_dispatches.getOrPut(dispatch_key);
            if (!state_entry.found_existing) {
                state_entry.value_ptr.* = .{
                    .identity = identity,
                    .pre_count = 0,
                    .terminal_pre = false,
                    .started = false,
                };
            } else if (!std.meta.eql(state_entry.value_ptr.identity, identity) or
                state_entry.value_ptr.terminal_pre)
                return error.InvalidRecord;
            state_entry.value_ptr.pre_count = std.math.add(
                u32,
                state_entry.value_ptr.pre_count,
                1,
            ) catch return error.InvalidRecord;
            if (formal.result != .admit) state_entry.value_ptr.terminal_pre = true;
            try state.pre_decisions.put(
                formalKey(formal.dispatch_id, formal.candidate_id, .pre),
                .{ .identity = identity, .result = formal.result },
            );
        },
        .post => {
            const opened = state.open_dispatches.getPtr(dispatch_key) orelse
                return error.InvalidRecord;
            const dispatch_state = state.formal_dispatches.get(dispatch_key) orelse
                return error.InvalidRecord;
            const prior = state.pre_decisions.get(
                formalKey(formal.dispatch_id, formal.candidate_id, .pre),
            ) orelse return error.InvalidRecord;
            if (!opened.governed or opened.terminal_post or
                prior.result != .admit or
                !std.meta.eql(prior.identity, identity) or
                !std.meta.eql(dispatch_state.identity, identity))
                return error.InvalidRecord;
            opened.post_count = std.math.add(u32, opened.post_count, 1) catch
                return error.InvalidRecord;
            if (formal.result != .admit) opened.terminal_post = true;
        },
    }
}

fn formalIdentity(formal: anytype) FormalControlIdentity {
    return .{
        .project_sha256 = formal.project_sha256,
        .bundle_sha256 = formal.bundle_sha256,
        .bundle_revision = formal.bundle_revision,
        .kernel_sha256 = formal.kernel_sha256,
    };
}

fn formalKey(
    dispatch_id: []const u8,
    candidate_id: [64]u8,
    phase: observation.FormalPhase,
) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("metacodes-formal-event-key-v1\x00");
    hasher.update(dispatch_id);
    hasher.update("\x00");
    hasher.update(&candidate_id);
    hasher.update(&.{@intFromEnum(phase)});
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
    return .{ .formal_decision = .{
        .dispatch_id = dispatch_id,
        .phase = phase,
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
    return .{ .formal_decision_batch = .{
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
            .result = .admit,
            .candidate_id = .{'1'} ** 64,
            .request_sha256 = .{'9'} ** 64,
            .verdict_sha256 = .{'a'} ** 64,
            .checker_failure = null,
        },
        .{
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
}
