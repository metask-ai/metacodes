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
};

pub const Journal = struct {
    mutex: sync.Mutex = .{},
    fd: pfs.Fd,
    lock_fd: pfs.Fd,
    lock_path: [std.fs.max_path_bytes + 1]u8,
    lock_path_len: usize,
    session_id: session_id_mod.SessionId,
    run_id: session_id_mod.SessionId,
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

        const summary = try validateFd(fd, session_id);
        if (!summary.complete) return error.UnfinishedRun;
        if (pfs.lseek(fd, 0, .end) < 0) return error.SeekFailed;

        var journal = Journal{
            .fd = fd,
            .lock_fd = lock_fd,
            .lock_path = lock_path_buf,
            .lock_path_len = lock_path.len - 1,
            .session_id = session_id,
            .run_id = session_id_mod.gen(),
            .sequence = summary.records,
            .file_bytes = summary.bytes,
            .started_ns = util_time.nowNs(),
        };
        try journal.appendEvent(.{ .run_started = .{
            .started_wall_ns = util_time.nowWallNs(),
        } });
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
    return validateFd(fd, session_id);
}

fn validateFd(
    fd: pfs.Fd,
    expected_session: session_id_mod.SessionId,
) !ValidationSummary {
    const info = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!info.is_regular) return error.NotRegularFile;
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
    var open_dispatches = std.AutoHashMap([32]u8, void).init(std.heap.c_allocator);
    defer open_dispatches.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(Envelope, std.heap.c_allocator, line, .{
            .ignore_unknown_fields = false,
            .allocate = .alloc_always,
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
            },
            .tool_observation => |tool_event| {
                const current = active_run orelse return error.InvalidRecord;
                if (!std.mem.eql(u8, current.asSlice(), run_id.asSlice()) or
                    envelope.monotonic_elapsed_ns < active_elapsed_ns)
                    return error.InvalidRecord;
                active_elapsed_ns = envelope.monotonic_elapsed_ns;
                switch (tool_event) {
                    .dispatch_started => |started| {
                        const entry = try open_dispatches.getOrPut(dispatchKey(started.id));
                        if (entry.found_existing) return error.InvalidRecord;
                    },
                    .dispatch_finished => |finished| {
                        if (!open_dispatches.remove(dispatchKey(finished.id)))
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
                active_run = null;
                active_elapsed_ns = 0;
            },
        }
        expected_sequence += 1;
    }
    return .{
        .records = expected_sequence,
        .bytes = size,
        .complete = active_run == null,
    };
}

fn dispatchKey(id: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &digest, .{});
    return digest;
}

fn writeAll(fd: pfs.Fd, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = pfs.write(fd, bytes[offset..]);
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}

fn elapsedNs(started_ns: i128) u64 {
    const now = util_time.nowNs();
    if (now <= started_ns) return 0;
    const delta: u128 = @intCast(now - started_ns);
    return @intCast(@min(delta, std.math.maxInt(u64)));
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

    var resumed = try Journal.init(root, sid);
    defer resumed.deinit();
    try std.testing.expect(!std.mem.eql(u8, first_run.asSlice(), resumed.runId()));
    try resumed.finishRun("end_turn");
    const second = try validate(root, sid);
    try std.testing.expectEqual(@as(u64, 6), second.records);
    try std.testing.expect(second.complete);
    try std.testing.expect(second.bytes > first.bytes);
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
