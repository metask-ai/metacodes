//! The per-run state directory (#519), outside every workspace:
//!
//! ```
//! <state_root>/teamwork/<run_id>/
//!   ORIGINAL_REQUEST.md   write-once; the completion audit's baseline
//!   budget.jsonl          append-only run ledger (ledger.zig)
//!   open_issues.json      reviewer findings (#517)
//!   seats/<seat_id>/
//!     packet.md           written by the runtime
//!     handoff.md          written by the seat
//!     progress.md         written by the seat
//!     status.json         written by the runtime
//!     review.json         written by a reviewer seat (reviewer.zig)
//!     open_issues.json    the runtime's read-only copy of the ledger
//!                         for this seat (issues.zig)
//!     harness.log         an external harness's stderr and the driver's
//!                         diagnostics (drivers/claude_code.zig)
//! ```
//!
//! Everything a run knows is on disk, so `recover` rebuilds the seat table
//! after a crash. The run id and this directory's absolute path never enter
//! provider-visible bytes: a packet names its neighbours relative to its seat
//! directory (`seat_relative_*`). The runtime is the only writer of the files
//! it owns; it is not thread-safe and the runtime serializes calls.

const std = @import("std");
const pfs = @import("platform").fs;
const pdir = @import("platform").dir;
const util_fs = @import("../util/fs.zig");
const swarm_team = @import("../swarm/team.zig");
const types = @import("types.zig");

const RunId = types.RunId;
const SeatId = types.SeatId;

pub const teamwork_dir = "teamwork";
pub const original_request_file = "ORIGINAL_REQUEST.md";
pub const budget_file = "budget.jsonl";
pub const open_issues_file = "open_issues.json";
pub const seats_dir = "seats";

/// `ORIGINAL_REQUEST.md` as a packet names it, relative to the seat directory.
pub const seat_relative_original_request = "../../" ++ original_request_file;
/// The `open_issues.json` ledger, relative to the seat directory.
pub const seat_relative_open_issues = "../../" ++ open_issues_file;
/// The seat's read-only copy of the ledger, relative to the seat directory.
/// Packets name this one: only the runtime writes the run-level ledger.
pub const seat_relative_open_issues_copy = open_issues_file;

pub const RunFile = enum {
    original_request,
    budget,
    open_issues,
    seats,

    pub fn name(self: RunFile) []const u8 {
        return switch (self) {
            .original_request => original_request_file,
            .budget => budget_file,
            .open_issues => open_issues_file,
            .seats => seats_dir,
        };
    }
};

pub const SeatFile = enum {
    packet,
    handoff,
    progress,
    status,
    /// A reviewer seat's structured verdict (reviewer.zig).
    review,
    /// The runtime's read-only copy of `open_issues.json` (issues.zig).
    open_issues_copy,

    pub fn name(self: SeatFile) []const u8 {
        return switch (self) {
            .packet => "packet.md",
            .handoff => "handoff.md",
            .progress => "progress.md",
            .status => "status.json",
            .review => "review.json",
            .open_issues_copy => open_issues_file,
        };
    }
};

/// A seat as `status.json` records it.
pub const SeatRecord = struct {
    id: SeatId,
    role: types.Role,
    harness: types.Harness,
    status: types.SeatStatus,
};

pub const Error = error{
    PathTooLong,
    /// `create` found the run directory already present.
    RunExists,
    /// `open` found no run directory.
    RunNotFound,
    SeatExists,
    SeatNotFound,
    /// `ORIGINAL_REQUEST.md` is write-once.
    OriginalRequestExists,
    OriginalRequestMissing,
    /// `status.json` is unreadable, not the expected JSON, or names another seat.
    StatusCorrupt,
    MkdirFailed,
    WriteFailed,
    OutOfMemory,
};

pub const ReadHandoffError = types.HandoffError || error{ PathTooLong, HandoffMissing, OutOfMemory };

pub const PathBuf = [std.fs.max_path_bytes]u8;

pub const RecoveredSeat = union(enum) {
    recorded: Recorded,
    /// A seat directory without a readable `status.json`: the runtime crashed
    /// between creating the directory and recording the seat, or mid-write
    /// outside the atomic path. The runtime decides whether to re-record it.
    damaged: SeatId,

    pub const Recorded = struct {
        record: SeatRecord,
        /// `handoff.md` exists (not yet validated).
        has_handoff: bool,
    };

    pub fn id(self: RecoveredSeat) SeatId {
        return switch (self) {
            .recorded => |r| r.record.id,
            .damaged => |seat_id| seat_id,
        };
    }
};

pub const Recovery = struct {
    original_request: bool,
    /// Sorted by seat id; owned by the `gpa` given to `recover`.
    seats: []RecoveredSeat,

    pub fn deinit(self: *Recovery, gpa: std.mem.Allocator) void {
        gpa.free(self.seats);
        self.* = undefined;
    }
};

pub const RunDir = struct {
    /// `<state_root>/teamwork/<run_id>`, owned.
    root: []u8,
    run_id: RunId,

    /// Create a new run directory with its `seats/`, an empty `budget.jsonl`
    /// and an empty `open_issues.json`. Fails with `RunExists` rather than
    /// adopting a directory some earlier run left behind.
    pub fn create(gpa: std.mem.Allocator, state_root: []const u8, run_id: RunId) Error!RunDir {
        var self = try init(gpa, state_root, run_id);
        errdefer self.deinit(gpa);

        var buf: PathBuf = undefined;
        const parent = try joinZ(&buf, &.{ trimSeparators(state_root), teamwork_dir });
        util_fs.mkdirParents(parent) catch |err| return switch (err) {
            error.PathTooLong => error.PathTooLong,
            error.MkdirFailed => error.MkdirFailed,
        };
        const root_z = try joinZ(&buf, &.{self.root});
        if (pfs.mkdir(root_z.ptr, 0o700) != 0) {
            return if (pfs.lastErrnoIs(.EXIST)) error.RunExists else error.MkdirFailed;
        }
        if (pfs.mkdir((try self.path(&buf, .seats)).ptr, 0o700) != 0) return error.MkdirFailed;
        try createEmpty(try self.path(&buf, .budget));
        try writeAtomic(try self.path(&buf, .open_issues), "[]\n");
        return self;
    }

    /// Open an existing run directory (after a restart, say).
    pub fn open(gpa: std.mem.Allocator, state_root: []const u8, run_id: RunId) Error!RunDir {
        var self = try init(gpa, state_root, run_id);
        errdefer self.deinit(gpa);
        var buf: PathBuf = undefined;
        if (!pfs.exists((try joinZ(&buf, &.{self.root})).ptr)) return error.RunNotFound;
        return self;
    }

    fn init(gpa: std.mem.Allocator, state_root: []const u8, run_id: RunId) Error!RunDir {
        const root = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ trimSeparators(state_root), teamwork_dir, run_id.slice() });
        if (root.len >= std.fs.max_path_bytes) {
            gpa.free(root);
            return error.PathTooLong;
        }
        return .{ .root = root, .run_id = run_id };
    }

    pub fn deinit(self: *RunDir, gpa: std.mem.Allocator) void {
        gpa.free(self.root);
        self.* = undefined;
    }

    /// Absolute path of a run-level file, NUL-terminated in `buf`.
    pub fn path(self: *const RunDir, buf: *PathBuf, file: RunFile) error{PathTooLong}![:0]const u8 {
        return joinZ(buf, &.{ self.root, file.name() });
    }

    /// Absolute path of a seat's directory.
    pub fn seatDir(self: *const RunDir, buf: *PathBuf, seat: SeatId) error{PathTooLong}![:0]const u8 {
        return joinZ(buf, &.{ self.root, seats_dir, seat.slice() });
    }

    /// Absolute path of one of a seat's files.
    pub fn seatPath(self: *const RunDir, buf: *PathBuf, seat: SeatId, file: SeatFile) error{PathTooLong}![:0]const u8 {
        return joinZ(buf, &.{ self.root, seats_dir, seat.slice(), file.name() });
    }

    /// Record the user's original request. Write-once and atomic: the bytes
    /// go to a temporary file that is then installed without replacing, so a
    /// second write fails with `OriginalRequestExists` and a crash never
    /// leaves a partial request behind.
    pub fn writeOriginalRequest(self: *const RunDir, bytes: []const u8) Error!void {
        var final_buf: PathBuf = undefined;
        const final = try self.path(&final_buf, .original_request);
        var tmp_buf: PathBuf = undefined;
        const tmp = try joinZ(&tmp_buf, &.{ self.root, original_request_file ++ ".tmp" });
        if (pfs.exists(final.ptr)) return error.OriginalRequestExists;
        try writeFresh(tmp, bytes);
        const result = pfs.installNoReplace(tmp.ptr, final.ptr) catch {
            pfs.unlinkPath(tmp.ptr) catch {};
            return error.WriteFailed;
        };
        switch (result) {
            .moved => {},
            .linked => pfs.unlinkPath(tmp.ptr) catch {},
            .already_exists => {
                pfs.unlinkPath(tmp.ptr) catch {};
                return error.OriginalRequestExists;
            },
        }
    }

    /// The original request, owned by `gpa`.
    pub fn readOriginalRequest(self: *const RunDir, gpa: std.mem.Allocator) Error![]u8 {
        var buf: PathBuf = undefined;
        return swarm_team.readFileAlloc(gpa, try self.path(&buf, .original_request)) orelse
            error.OriginalRequestMissing;
    }

    /// Create the seat's directory and record it.
    pub fn createSeat(self: *const RunDir, record: SeatRecord) Error!void {
        var buf: PathBuf = undefined;
        const dir = try self.seatDir(&buf, record.id);
        if (pfs.mkdir(dir.ptr, 0o700) != 0) {
            return if (pfs.lastErrnoIs(.EXIST)) error.SeatExists else error.MkdirFailed;
        }
        try self.writeSeatRecord(record);
    }

    /// Write (or replace) the seat's packet.
    pub fn writePacket(self: *const RunDir, seat: SeatId, bytes: []const u8) Error!void {
        var buf: PathBuf = undefined;
        try self.requireSeat(seat);
        try writeAtomic(try self.seatPath(&buf, seat, .packet), bytes);
    }

    /// Read and strictly parse the seat's `handoff.md`; the handoff is owned
    /// by `gpa`.
    pub fn readHandoff(self: *const RunDir, gpa: std.mem.Allocator, seat: SeatId) ReadHandoffError!types.Handoff {
        var buf: PathBuf = undefined;
        const text = swarm_team.readFileAlloc(gpa, try self.seatPath(&buf, seat, .handoff)) orelse
            return error.HandoffMissing;
        defer gpa.free(text);
        return types.Handoff.parse(gpa, text);
    }

    /// Atomically replace the seat's `status.json`.
    pub fn writeSeatRecord(self: *const RunDir, record: SeatRecord) Error!void {
        var buf: PathBuf = undefined;
        try self.requireSeat(record.id);
        var text_buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(
            &text_buf,
            "{{\"seat_id\":\"{s}\",\"role\":\"{s}\",\"harness\":\"{s}\",\"status\":\"{s}\"}}\n",
            .{ record.id.slice(), record.role.name(), record.harness.name(), record.status.name() },
        ) catch unreachable; // ids are <= 64 path-safe bytes; enum names are short
        try writeAtomic(try self.seatPath(&buf, record.id, .status), text);
    }

    pub fn readSeatRecord(self: *const RunDir, seat: SeatId) Error!SeatRecord {
        var buf: PathBuf = undefined;
        try self.requireSeat(seat);
        // status.json is a few hundred bytes; a fixed scratch keeps this
        // allocation-free for callers.
        var scratch_bytes: [16 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&scratch_bytes);
        const scratch = fba.allocator();
        const text = swarm_team.readFileAlloc(scratch, try self.seatPath(&buf, seat, .status)) orelse
            return error.StatusCorrupt;
        return parseRecord(scratch, seat, text) catch error.StatusCorrupt;
    }

    /// Rebuild the seat table from disk: every `seats/<id>/` whose name is a
    /// valid seat id, with its recorded status, or `damaged` when the record
    /// cannot be read. Temporary files and foreign names are ignored.
    pub fn recover(self: *const RunDir, gpa: std.mem.Allocator) Error!Recovery {
        var buf: PathBuf = undefined;
        const original_request = pfs.exists((try self.path(&buf, .original_request)).ptr);

        var seats: std.ArrayList(RecoveredSeat) = .empty;
        errdefer seats.deinit(gpa);
        var it = pdir.open((try self.path(&buf, .seats)).ptr) orelse return error.RunNotFound;
        defer pdir.close(&it);
        while (pdir.next(&it)) |entry| {
            const seat = SeatId.parse(entry.name) catch continue;
            const recovered: RecoveredSeat = if (self.readSeatRecord(seat)) |record| blk: {
                var hbuf: PathBuf = undefined;
                const has_handoff = pfs.exists((try self.seatPath(&hbuf, seat, .handoff)).ptr);
                break :blk .{ .recorded = .{ .record = record, .has_handoff = has_handoff } };
            } else |err| switch (err) {
                error.StatusCorrupt => .{ .damaged = seat },
                error.SeatNotFound => continue, // a plain file named like a seat
                else => return err,
            };
            try seats.append(gpa, recovered);
        }
        const slice = try seats.toOwnedSlice(gpa);
        std.mem.sort(RecoveredSeat, slice, {}, struct {
            fn lessThan(_: void, a: RecoveredSeat, b: RecoveredSeat) bool {
                return SeatId.lessThan({}, a.id(), b.id());
            }
        }.lessThan);
        return .{ .original_request = original_request, .seats = slice };
    }

    fn requireSeat(self: *const RunDir, seat: SeatId) Error!void {
        var buf: PathBuf = undefined;
        const dir = try self.seatDir(&buf, seat);
        if (!pfs.exists(dir.ptr) or pfs.isExistingNonDir(dir.ptr)) return error.SeatNotFound;
    }
};

/// The outcome of a seat whose harness exited cleanly: the handoff at
/// `handoff_path`, parsed, or the contract failure. Every driver ends with
/// this, so all harnesses report a clean exit the same way.
pub fn collectHandoff(gpa: std.mem.Allocator, handoff_path: []const u8) error{OutOfMemory}!types.SeatOutcome {
    const text = swarm_team.readFileAlloc(gpa, handoff_path) orelse
        return .{ .failed = .handoff_missing };
    defer gpa.free(text);
    const handoff = types.Handoff.parse(gpa, text) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => |contract| .{ .failed = .{ .handoff_invalid = contract } },
    };
    return .{ .finished = handoff };
}

fn parseRecord(scratch: std.mem.Allocator, seat: SeatId, text: []const u8) !SeatRecord {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, scratch, text, .{});
    if (root != .object) return error.StatusCorrupt;
    const obj = root.object;
    const id_text = stringField(obj, "seat_id") orelse return error.StatusCorrupt;
    if (!std.mem.eql(u8, id_text, seat.slice())) return error.StatusCorrupt;
    return .{
        .id = seat,
        .role = types.Role.parse(stringField(obj, "role") orelse return error.StatusCorrupt) orelse return error.StatusCorrupt,
        .harness = types.Harness.parse(stringField(obj, "harness") orelse return error.StatusCorrupt) orelse return error.StatusCorrupt,
        .status = types.SeatStatus.parse(stringField(obj, "status") orelse return error.StatusCorrupt) orelse return error.StatusCorrupt,
    };
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn trimSeparators(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 1 and (text[end - 1] == '/' or text[end - 1] == '\\')) end -= 1;
    return text[0..end];
}

fn joinZ(buf: *PathBuf, parts: []const []const u8) error{PathTooLong}![:0]const u8 {
    var len: usize = 0;
    for (parts, 0..) |part, i| {
        const sep: usize = if (i == 0) 0 else 1;
        if (len + sep + part.len >= buf.len) return error.PathTooLong;
        if (sep == 1) buf[len] = '/';
        len += sep;
        @memcpy(buf[len..][0..part.len], part);
        len += part.len;
    }
    buf[len] = 0;
    return buf[0..len :0];
}

/// Replace `path_z` atomically (temporary file + rename).
pub fn writeAtomic(path_z: [:0]const u8, bytes: []const u8) Error!void {
    swarm_team.atomicWrite(path_z, bytes) catch |err| return switch (err) {
        error.PathTooLong => error.PathTooLong,
        else => error.WriteFailed,
    };
}

/// Create `path_z` empty; an existing file is left alone.
fn createEmpty(path_z: [:0]const u8) Error!void {
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600);
    if (fd < 0) return error.WriteFailed;
    pfs.close(fd);
}

/// Write `bytes` to `path_z` (truncating) and flush them to disk.
fn writeFresh(path_z: [:0]const u8, bytes: []const u8) Error!void {
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600);
    if (fd < 0) return error.WriteFailed;
    defer pfs.close(fd);
    if (!pfs.writeAll(fd, bytes)) return error.WriteFailed;
    pfs.fsyncChecked(fd) catch return error.WriteFailed;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Fixtures for teamwork tests.
pub const test_support = struct {
    /// A unique fixture state root under the test temp root, removed by `deinit`.
    pub const TestRoot = struct {
        buf: PathBuf,
        len: usize,

        pub fn init(tag: []const u8) TestRoot {
            var self: TestRoot = .{ .buf = undefined, .len = 0 };
            self.len = util_fs.testing.uniqueDir(&self.buf, tag).len;
            util_fs.mkdirParents(self.slice()) catch {};
            return self;
        }

        pub fn slice(self: *const TestRoot) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn deinit(self: *TestRoot) void {
            util_fs.testing.rmrfBestEffort(self.slice());
        }
    };
};

fn testRecord(id_text: []const u8, role: types.Role, harness: types.Harness, status: types.SeatStatus) SeatRecord {
    return .{ .id = SeatId.parse(id_text) catch unreachable, .role = role, .harness = harness, .status = status };
}

test "run dir: create lays out the run and refuses to adopt an existing one" {
    var root = test_support.TestRoot.init("cc-zig-teamwork-create");
    defer root.deinit();
    const run_id = try RunId.parse("r1");
    var run = try RunDir.create(testing.allocator, root.slice(), run_id);
    defer run.deinit(testing.allocator);

    var buf: PathBuf = undefined;
    try testing.expect(pfs.exists((try run.path(&buf, .seats)).ptr));
    try testing.expect(pfs.exists((try run.path(&buf, .budget)).ptr));
    const issues = swarm_team.readFileAlloc(testing.allocator, try run.path(&buf, .open_issues)).?;
    defer testing.allocator.free(issues);
    try testing.expectEqualStrings("[]\n", issues);
    try testing.expect(std.mem.endsWith(u8, run.root, "/teamwork/r1"));

    try testing.expectError(error.RunExists, RunDir.create(testing.allocator, root.slice(), run_id));
    try testing.expectError(error.RunNotFound, RunDir.open(testing.allocator, root.slice(), try RunId.parse("r2")));
}

test "run dir: ORIGINAL_REQUEST.md is write-once" {
    var root = test_support.TestRoot.init("cc-zig-teamwork-request");
    defer root.deinit();
    var run = try RunDir.create(testing.allocator, root.slice(), try RunId.parse("r1"));
    defer run.deinit(testing.allocator);

    try testing.expectError(error.OriginalRequestMissing, run.readOriginalRequest(testing.allocator));
    try run.writeOriginalRequest("Add a --dry-run flag.\n");
    try testing.expectError(error.OriginalRequestExists, run.writeOriginalRequest("Something else.\n"));

    const text = try run.readOriginalRequest(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Add a --dry-run flag.\n", text);
    var buf: PathBuf = undefined;
    try testing.expect(!pfs.exists((try joinZ(&buf, &.{ run.root, original_request_file ++ ".tmp" })).ptr));
}

test "run dir: seats record status, packets and handoffs" {
    var root = test_support.TestRoot.init("cc-zig-teamwork-seat");
    defer root.deinit();
    var run = try RunDir.create(testing.allocator, root.slice(), try RunId.parse("r1"));
    defer run.deinit(testing.allocator);

    const seat = testRecord("implementer-1", .implementer, .claude_code, .queued);
    try run.createSeat(seat);
    try testing.expectError(error.SeatExists, run.createSeat(seat));
    try testing.expectError(error.SeatNotFound, run.writePacket(try SeatId.parse("ghost"), "x"));

    try run.writePacket(seat.id, "Task: see " ++ seat_relative_original_request ++ "\n");
    var updated = seat;
    updated.status = .working;
    try run.writeSeatRecord(updated);
    try testing.expectEqual(types.SeatStatus.working, (try run.readSeatRecord(seat.id)).status);
    try testing.expectEqual(types.Harness.claude_code, (try run.readSeatRecord(seat.id)).harness);

    try testing.expectError(error.HandoffMissing, run.readHandoff(testing.allocator, seat.id));
    var buf: PathBuf = undefined;
    try writeFresh(try run.seatPath(&buf, seat.id, .handoff), "## Observation\no\n## Reasoning\nr\n## Caveats\nc\n## Conclusion\nk\n");
    try testing.expectError(error.MissingVerification, run.readHandoff(testing.allocator, seat.id));
    try writeFresh(try run.seatPath(&buf, seat.id, .handoff), "## Observation\no\n## Reasoning\nr\n## Caveats\nc\n## Conclusion\nk\n## Verification\nv\n");
    var handoff = try run.readHandoff(testing.allocator, seat.id);
    defer handoff.deinit(testing.allocator);
    try testing.expectEqualStrings("k", handoff.conclusion);
}

test "run dir: recover rebuilds the seat table after a simulated crash" {
    var root = test_support.TestRoot.init("cc-zig-teamwork-recover");
    defer root.deinit();
    const run_id = try RunId.parse("r1");
    {
        var run = try RunDir.create(testing.allocator, root.slice(), run_id);
        defer run.deinit(testing.allocator);
        try run.writeOriginalRequest("request\n");
        try run.createSeat(testRecord("reviewer-1", .reviewer, .metacodes, .queued));
        try run.createSeat(testRecord("implementer-1", .implementer, .claude_code, .working));
        var buf: PathBuf = undefined;
        try writeFresh(try run.seatPath(&buf, try SeatId.parse("implementer-1"), .handoff), "partial");
        // Crash between mkdir and the first status write.
        _ = pfs.mkdir((try run.seatDir(&buf, try SeatId.parse("verifier-1"))).ptr, 0o700);
        // A status file torn by something that bypassed the atomic write.
        _ = pfs.mkdir((try run.seatDir(&buf, try SeatId.parse("interviewer-1"))).ptr, 0o700);
        try writeFresh(try run.seatPath(&buf, try SeatId.parse("interviewer-1"), .status), "{\"seat_id\":\"interv");
        // A status naming another seat is not trusted either.
        _ = pfs.mkdir((try run.seatDir(&buf, try SeatId.parse("manager-1"))).ptr, 0o700);
        try writeFresh(try run.seatPath(&buf, try SeatId.parse("manager-1"), .status), "{\"seat_id\":\"reviewer-1\",\"role\":\"manager\",\"harness\":\"metacodes\",\"status\":\"done\"}");
        // Debris that is not a seat.
        _ = pfs.mkdir((try joinZ(&buf, &.{ run.root, seats_dir, "Not.A.Seat" })).ptr, 0o700);
        try writeFresh(try joinZ(&buf, &.{ run.root, seats_dir, "status.json.tmp" }), "x");
        // The process dies here: nothing is closed or flushed beyond this point.
    }

    var run = try RunDir.open(testing.allocator, root.slice(), run_id);
    defer run.deinit(testing.allocator);
    var recovery = try run.recover(testing.allocator);
    defer recovery.deinit(testing.allocator);

    try testing.expect(recovery.original_request);
    try testing.expectEqual(@as(usize, 5), recovery.seats.len);
    const ids = [_][]const u8{ "implementer-1", "interviewer-1", "manager-1", "reviewer-1", "verifier-1" };
    for (ids, recovery.seats) |want, got| {
        const got_id = got.id();
        try testing.expectEqualStrings(want, got_id.slice());
    }

    const implementer = recovery.seats[0].recorded;
    try testing.expectEqual(types.SeatStatus.working, implementer.record.status);
    try testing.expectEqual(types.Harness.claude_code, implementer.record.harness);
    try testing.expect(implementer.has_handoff);
    try testing.expect(recovery.seats[1] == .damaged);
    try testing.expect(recovery.seats[2] == .damaged);
    const reviewer = recovery.seats[3].recorded;
    try testing.expectEqual(types.SeatStatus.queued, reviewer.record.status);
    try testing.expect(!reviewer.has_handoff);
    try testing.expect(recovery.seats[4] == .damaged);

    // A damaged seat is repaired by recording it again.
    try run.writeSeatRecord(testRecord("verifier-1", .verifier, .metacodes, .queued));
    try testing.expectEqual(types.SeatStatus.queued, (try run.readSeatRecord(try SeatId.parse("verifier-1"))).status);
}
