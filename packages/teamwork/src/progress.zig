const std = @import("std");
const sync = @import("platform").sync;
const types = @import("types.zig");
const runtime = @import("runtime.zig");
const config = @import("config.zig");
const wire = @import("metacodes-coding").core.protocol.wire;

pub const Phase = enum {
    interviewing,
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

    pub fn of(phase: runtime.Phase) Phase {
        return switch (phase) {
            inline else => |tag| @field(Phase, @tagName(tag)),
        };
    }

    pub fn isTerminal(self: Phase) bool {
        return switch (self) {
            .interviewing => false,
            inline else => |tag| @field(runtime.Phase, @tagName(tag)).isTerminal(),
        };
    }
};

pub const Snapshot = struct {
    run_id: types.RunId,
    goal: []const u8,
    phase: Phase,
    seats: []const runtime.SeatSnapshot,
    budget: runtime.BudgetSnapshot,
    audit: runtime.AuditSnapshot,
    candidates: []const runtime.CandidateSnapshot = &.{},

    pub fn ofRun(run: runtime.RunSnapshot) Snapshot {
        return .{
            .run_id = run.run_id,
            .goal = run.goal,
            .phase = .of(run.state.phase()),
            .seats = run.seats,
            .budget = run.budget,
            .audit = run.audit,
            .candidates = run.candidates,
        };
    }

    pub fn seatsDone(self: Snapshot) usize {
        var count: usize = 0;
        for (self.seats) |seat| {
            if (seat.status == .done) count += 1;
        }
        return count;
    }

    pub fn jsonStringify(self: Snapshot, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("run_id");
        try jw.write(self.run_id.slice());
        try jw.objectField("goal");
        try jw.write(self.goal);
        try jw.objectField("phase");
        try jw.write(self.phase);
        try jw.objectField("done");
        try jw.write(self.seatsDone());
        try jw.objectField("total");
        try jw.write(self.seats.len);
        try jw.objectField("seats");
        try jw.beginArray();
        for (self.seats) |seat| {
            try jw.write(.{ .id = seat.id.slice(), .role = seat.role, .harness = seat.harness, .status = seat.status });
        }
        try jw.endArray();
        try jw.objectField("budget");
        try jw.write(.{ .cap_usd = self.budget.cap_usd, .spent_usd = self.budget.spent_usd });
        try jw.objectField("audit");
        try jw.write(.{ .used = self.audit.used, .max = self.audit.max, .last = self.audit.last });
        try jw.objectField("candidates");
        try jw.beginArray();
        for (self.candidates, 1..) |candidate, number| {
            try jw.write(.{ .candidate = number, .status = candidate.status });
        }
        try jw.endArray();
        try jw.endObject();
    }
};

pub const Change = union(enum) {
    seat: SeatChange,
    phase: PhaseChange,

    pub const SeatChange = struct {
        id: types.SeatId,
        from: ?types.SeatStatus,
        to: types.SeatStatus,
    };

    pub const PhaseChange = struct {
        from: Phase,
        to: Phase,
    };

    pub fn jsonStringify(self: Change, jw: anytype) !void {
        switch (self) {
            .seat => |seat| try jw.write(.{ .kind = "seat", .seat = seat.id.slice(), .from = seat.from, .to = seat.to }),
            .phase => |phase| try jw.write(.{ .kind = "phase", .from = phase.from, .to = phase.to }),
        }
    }
};

pub const Event = struct {
    change: Change,
    snapshot: Snapshot,
};

pub const Observer = struct {
    ctx: *anyopaque,
    notifyFn: *const fn (ctx: *anyopaque, event: *const Event) void,

    pub fn notify(self: Observer, event: *const Event) void {
        self.notifyFn(self.ctx, event);
    }
};

pub const snapshot_line_type = "teamwork.snapshot";
pub const event_line_type = "teamwork.event";

pub fn writeSnapshotLine(w: *std.Io.Writer, snapshot: Snapshot) std.Io.Writer.Error!void {
    try writeLine(w, snapshot_line_type, snapshot);
}

pub fn writeEventLine(w: *std.Io.Writer, event: *const Event) std.Io.Writer.Error!void {
    try writeLine(w, event_line_type, .{ .change = event.change, .snapshot = event.snapshot });
}

fn writeLine(w: *std.Io.Writer, line_type: []const u8, data: anytype) std.Io.Writer.Error!void {
    var jw: std.json.Stringify = .{ .writer = w };
    try jw.write(.{ .v = wire.SCHEMA_VERSION, .type = line_type, .data = data });
    try w.writeByte('\n');
}

pub const Board = struct {
    gpa: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    revision: std.atomic.Value(u64) = .init(0),
    held: ?Held = null,

    const Held = struct {
        run_id: types.RunId,
        goal: [runtime.goal_max]u8,
        goal_len: usize,
        phase: Phase,
        seats: std.ArrayList(runtime.SeatSnapshot),
        budget: runtime.BudgetSnapshot,
        audit: runtime.AuditSnapshot,
        candidates: [config.max_candidates]runtime.CandidateSnapshot,
        candidates_len: usize,
    };

    pub const Copy = struct {
        gpa: std.mem.Allocator,
        held: Held,

        pub fn snapshot(self: *const Copy) Snapshot {
            return view(&self.held);
        }

        pub fn deinit(self: *Copy) void {
            self.held.seats.deinit(self.gpa);
            self.* = undefined;
        }
    };

    pub fn init(gpa: std.mem.Allocator) Board {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Board) void {
        if (self.held) |*held| held.seats.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn observer(self: *Board) Observer {
        return .{ .ctx = self, .notifyFn = onEvent };
    }

    fn onEvent(ctx: *anyopaque, event: *const Event) void {
        const self: *Board = @ptrCast(@alignCast(ctx));
        self.publish(event.snapshot) catch {};
    }

    pub fn publish(self: *Board, snapshot: Snapshot) error{OutOfMemory}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var seats = if (self.held) |*held| held.seats else std.ArrayList(runtime.SeatSnapshot).empty;
        seats.clearRetainingCapacity();
        seats.appendSlice(self.gpa, snapshot.seats) catch |err| {
            seats.deinit(self.gpa);
            self.held = null;
            return err;
        };
        var held: Held = .{
            .run_id = snapshot.run_id,
            .goal = undefined,
            .goal_len = @min(snapshot.goal.len, runtime.goal_max),
            .phase = snapshot.phase,
            .seats = seats,
            .budget = snapshot.budget,
            .audit = snapshot.audit,
            .candidates = undefined,
            .candidates_len = @min(snapshot.candidates.len, config.max_candidates),
        };
        @memcpy(held.goal[0..held.goal_len], snapshot.goal[0..held.goal_len]);
        @memcpy(held.candidates[0..held.candidates_len], snapshot.candidates[0..held.candidates_len]);
        self.held = held;
        _ = self.revision.fetchAdd(1, .release);
    }

    pub fn clear(self: *Board) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.held) |*held| held.seats.deinit(self.gpa);
        self.held = null;
        _ = self.revision.fetchAdd(1, .release);
    }

    pub fn currentRevision(self: *const Board) u64 {
        return self.revision.load(.acquire);
    }

    pub fn read(self: *Board, gpa: std.mem.Allocator) error{OutOfMemory}!?Copy {
        self.mutex.lock();
        defer self.mutex.unlock();
        const held = &(self.held orelse return null);
        var copy: Copy = .{ .gpa = gpa, .held = held.* };
        copy.held.seats = .empty;
        try copy.held.seats.appendSlice(gpa, held.seats.items);
        return copy;
    }

    fn view(held: *const Held) Snapshot {
        return .{
            .run_id = held.run_id,
            .goal = held.goal[0..held.goal_len],
            .phase = held.phase,
            .seats = held.seats.items,
            .budget = held.budget,
            .audit = held.audit,
            .candidates = held.candidates[0..held.candidates_len],
        };
    }
};

const testing = std.testing;

fn sampleSeats() [3]runtime.SeatSnapshot {
    return .{
        .{ .id = types.seatIdFor(.implementer, 1), .role = .implementer, .harness = .metacodes, .status = .done },
        .{ .id = types.seatIdFor(.reviewer, 1), .role = .reviewer, .harness = .claude_code, .status = .working },
        .{ .id = types.seatIdFor(.implementer, 2), .role = .implementer, .harness = .claude_code, .status = .queued },
    };
}

fn sampleSnapshot(seats: []const runtime.SeatSnapshot) Snapshot {
    return .{
        .run_id = types.RunId.parse("run-7") catch unreachable,
        .goal = "Add feature.txt",
        .phase = .reviewing,
        .seats = seats,
        .budget = .{ .cap_usd = 5, .spent_usd = 0.5, .remaining_usd = 4.5, .charges = 1 },
        .audit = .{ .used = 0, .last = null },
    };
}

test "progress: phases mirror the runtime and interviewing precedes them" {
    for (std.enums.values(runtime.Phase)) |phase| {
        try testing.expectEqualStrings(@tagName(phase), @tagName(Phase.of(phase)));
        try testing.expectEqual(phase.isTerminal(), Phase.of(phase).isTerminal());
    }
    try testing.expect(!Phase.interviewing.isTerminal());
}

test "progress: the board keeps an owned copy and counts revisions" {
    var board = Board.init(testing.allocator);
    defer board.deinit();
    try testing.expect((try board.read(testing.allocator)) == null);
    var seats = sampleSeats();
    var goal = "Add feature.txt".*;
    var snapshot = sampleSnapshot(&seats);
    snapshot.goal = &goal;
    const event: Event = .{ .change = .{ .seat = .{ .id = seats[1].id, .from = .queued, .to = .working } }, .snapshot = snapshot };
    board.observer().notify(&event);
    seats[1].status = .failed;
    goal[0] = 'X';
    var copy = (try board.read(testing.allocator)).?;
    defer copy.deinit();
    try testing.expectEqual(@as(u64, 1), board.currentRevision());
    try testing.expectEqualStrings("Add feature.txt", copy.snapshot().goal);
    try testing.expectEqual(types.SeatStatus.working, copy.snapshot().seats[1].status);
    try testing.expectEqual(@as(usize, 1), copy.snapshot().seatsDone());
    board.clear();
    try testing.expect((try board.read(testing.allocator)) == null);
    try testing.expectEqual(@as(u64, 2), board.currentRevision());
}
