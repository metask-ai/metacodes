//! The run's reviewer-findings ledger, `open_issues.json` (#517).
//!
//! Only the runtime writes it. A reviewer seat sees a read-only copy in its
//! own seat directory (`writeSeatCopy`) and the still-open list rendered into
//! its packet (`renderOpen`), so findings carry across rounds even when the
//! reviewer seat, or its harness, changes.
//!
//! The file is a JSON array with one entry per issue ever opened:
//!
//! ```json
//! [{"id":"issue-1","state":"open","title":"...","detail":"...",
//!   "file":"src/a.zig","line":12,"round_opened":1,"round_closed":null}]
//! ```
//!
//! Closed issues stay as tombstones so an id is never reused. A valid review
//! is applied with `apply`, which is all-or-nothing: `check` first validates
//! every reference, so a rejected review leaves the ledger untouched.

const std = @import("std");
const pfs = @import("platform").fs;
const swarm_team = @import("metacodes-coding").swarm.team;
const types = @import("types.zig");
const run_dir = @import("run_dir.zig");

pub const IssueId = types.IssueId;

/// An issue as a review opens it. Strings are borrowed from the review.
pub const NewIssue = struct {
    /// The reviewer's own id for the issue; null = the runtime assigns
    /// `issue-<n>`. Either way it becomes the stable id.
    id: ?IssueId = null,
    title: []const u8,
    detail: []const u8,
    location: ?Location = null,
};

/// Where an issue is. A line only exists inside a file.
pub const Location = struct {
    file: []const u8,
    /// 1-based; null = the whole file.
    line: ?u32 = null,
};

/// What one review does to the ledger.
pub const Changes = struct {
    opened: []const NewIssue = &.{},
    /// Ids the review saw fixed.
    closed: []const IssueId = &.{},
    /// Ids the review saw still broken. An open issue a review does not
    /// mention also stays open; listing it records that it was rechecked.
    still_open: []const IssueId = &.{},
};

pub const State = union(enum) {
    open,
    /// The round whose review closed it.
    closed: u32,
};

pub const Issue = struct {
    id: IssueId,
    state: State,
    title: []const u8,
    detail: []const u8,
    location: ?Location,
    round_opened: u32,
};

pub const ApplyError = error{
    /// `closed` or `still_open` names an id the ledger does not have.
    UnknownIssue,
    /// `closed` or `still_open` names an issue that is already closed.
    IssueAlreadyClosed,
    /// An opened issue's id is already in the ledger (open or closed).
    DuplicateIssueId,
};

pub const LoadError = error{
    /// The file is missing, unreadable, or not the ledger's JSON.
    LedgerCorrupt,
    PathTooLong,
    OutOfMemory,
};

pub const Summary = struct {
    opened: u32,
    closed: u32,
    /// Open issues after the review.
    open_total: u32,
};

pub const Ledger = struct {
    /// Owns every string and the list.
    arena: std.heap.ArenaAllocator,
    /// In opening order.
    issues: std.ArrayList(Issue) = .empty,

    pub fn init(gpa: std.mem.Allocator) Ledger {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Ledger) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Read the run's `open_issues.json`.
    pub fn load(gpa: std.mem.Allocator, run: *const run_dir.RunDir) LoadError!Ledger {
        var buf: run_dir.PathBuf = undefined;
        const text = swarm_team.readFileAlloc(gpa, try run.path(&buf, .open_issues)) orelse
            return error.LedgerCorrupt;
        defer gpa.free(text);
        return parse(gpa, text);
    }

    /// Parse the ledger's JSON. Strings are copied into the ledger.
    pub fn parse(gpa: std.mem.Allocator, text: []const u8) LoadError!Ledger {
        var self = init(gpa);
        errdefer self.deinit();
        const a = self.arena.allocator();
        // alloc_always: the ledger's strings must outlive `text`.
        const root = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.LedgerCorrupt,
        };
        if (root != .array) return error.LedgerCorrupt;
        for (root.array.items) |item| {
            const issue = try parseIssue(item);
            if (self.find(issue.id) != null) return error.LedgerCorrupt;
            try self.issues.append(a, issue);
        }
        return self;
    }

    /// Atomically replace the run's `open_issues.json`.
    pub fn save(self: *const Ledger, gpa: std.mem.Allocator, run: *const run_dir.RunDir) (run_dir.Error || error{OutOfMemory})!void {
        const text = try self.render(gpa);
        defer gpa.free(text);
        var buf: run_dir.PathBuf = undefined;
        try run_dir.writeAtomic(try run.path(&buf, .open_issues), text);
    }

    /// Give `seat` its read-only copy of the ledger
    /// (`seats/<id>/open_issues.json`); packets name it through
    /// `run_dir.seat_relative_open_issues_copy`.
    pub fn writeSeatCopy(self: *const Ledger, gpa: std.mem.Allocator, run: *const run_dir.RunDir, seat: types.SeatId) (run_dir.Error || error{OutOfMemory})!void {
        const text = try self.render(gpa);
        defer gpa.free(text);
        var buf: run_dir.PathBuf = undefined;
        const path = try run.seatPath(&buf, seat, .open_issues_copy);
        // The previous round's copy is read-only. POSIX rename replaces it
        // regardless of its mode; Windows refuses, so lift the bit first.
        if (pfs.exists(path.ptr)) _ = pfs.chmod(path.ptr, 0o600);
        try run_dir.writeAtomic(path, text);
        if (pfs.chmod(path.ptr, 0o444) != 0) return error.WriteFailed;
    }

    pub fn find(self: *const Ledger, id: IssueId) ?*const Issue {
        for (self.issues.items) |*issue| if (issue.id.eql(id)) return issue;
        return null;
    }

    pub fn openCount(self: *const Ledger) u32 {
        var n: u32 = 0;
        for (self.issues.items) |issue| n += @intFromBool(issue.state == .open);
        return n;
    }

    /// Validate `changes` against the ledger without touching it; returns the
    /// number of issues that would remain open.
    pub fn check(self: *const Ledger, changes: Changes) ApplyError!u32 {
        for (changes.closed) |id| try self.requireOpen(id);
        for (changes.still_open) |id| try self.requireOpen(id);
        for (changes.opened, 0..) |issue, i| {
            const id = issue.id orelse continue;
            if (self.find(id) != null) return error.DuplicateIssueId;
            for (changes.opened[0..i]) |earlier| {
                if (earlier.id) |other| if (other.eql(id)) return error.DuplicateIssueId;
            }
        }
        var remaining: u32 = @intCast(changes.opened.len);
        for (self.issues.items) |issue| {
            if (issue.state != .open) continue;
            const closing = for (changes.closed) |id| {
                if (id.eql(issue.id)) break true;
            } else false;
            remaining += @intFromBool(!closing);
        }
        return remaining;
    }

    /// Apply one valid review from `round`: close, then open. All or nothing.
    pub fn apply(self: *Ledger, changes: Changes, round: u32) (ApplyError || error{OutOfMemory})!Summary {
        _ = try self.check(changes);
        const a = self.arena.allocator();
        try self.issues.ensureUnusedCapacity(a, changes.opened.len);
        // Copy every string before mutating, so an allocation failure leaves
        // the ledger as it was.
        const copies = try a.alloc(Issue, changes.opened.len);
        var next = self.nextOrdinal();
        for (changes.opened, copies) |issue, *copy| {
            const id = issue.id orelse blk: {
                while (true) : (next += 1) {
                    const candidate = autoId(next);
                    if (self.find(candidate) == null and !openedHas(changes.opened, candidate)) break :blk candidate;
                }
            };
            if (issue.id == null) next += 1;
            copy.* = .{
                .id = id,
                .state = .open,
                .title = try a.dupe(u8, issue.title),
                .detail = try a.dupe(u8, issue.detail),
                .location = if (issue.location) |loc| .{ .file = try a.dupe(u8, loc.file), .line = loc.line } else null,
                .round_opened = round,
            };
        }
        for (changes.closed) |id| {
            for (self.issues.items) |*issue| {
                if (issue.id.eql(id)) issue.state = .{ .closed = round };
            }
        }
        self.issues.appendSliceAssumeCapacity(copies);
        return .{
            .opened = @intCast(changes.opened.len),
            .closed = @intCast(changes.closed.len),
            .open_total = self.openCount(),
        };
    }

    /// The still-open list as a packet section. Deterministic: issue order is
    /// opening order and nothing run-specific (paths, run id, time) appears,
    /// so the bytes are a stable prompt prefix across rounds.
    pub fn renderOpen(self: *const Ledger, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("## Open issues from earlier rounds\n\n");
        if (self.openCount() == 0) {
            try w.writeAll("None.\n");
            return;
        }
        try w.writeAll("Each issue below is still open. Recheck every one: list it under `issues.closed` " ++
            "in review.json if it is fixed, under `issues.still_open` if not. An approval must close all of them.\n\n");
        for (self.issues.items) |issue| {
            if (issue.state != .open) continue;
            try w.print("- `{s}` {s}", .{ issue.id.slice(), issue.title });
            if (issue.location) |loc| {
                try w.print(" ({s}", .{loc.file});
                if (loc.line) |line| try w.print(":{d}", .{line});
                try w.writeAll(")");
            }
            try w.print(" [opened in round {d}]\n", .{issue.round_opened});
            var lines = std.mem.splitScalar(u8, std.mem.trim(u8, issue.detail, " \t\r\n"), '\n');
            while (lines.next()) |line| try w.print("  {s}\n", .{std.mem.trimEnd(u8, line, "\r")});
        }
    }

    /// The ledger's JSON, owned by `gpa`.
    pub fn render(self: *const Ledger, gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        self.writeJson(&out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice() catch error.OutOfMemory;
    }

    fn writeJson(self: *const Ledger, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("[");
        for (self.issues.items, 0..) |issue, i| {
            try w.writeAll(if (i == 0) "\n  " else ",\n  ");
            var s: std.json.Stringify = .{ .writer = w };
            try s.beginObject();
            try s.objectField("id");
            try s.write(issue.id.slice());
            try s.objectField("state");
            try s.write(@tagName(issue.state));
            try s.objectField("title");
            try s.write(issue.title);
            try s.objectField("detail");
            try s.write(issue.detail);
            try s.objectField("file");
            try s.write(if (issue.location) |loc| loc.file else null);
            try s.objectField("line");
            try s.write(if (issue.location) |loc| loc.line else null);
            try s.objectField("round_opened");
            try s.write(issue.round_opened);
            try s.objectField("round_closed");
            try s.write(switch (issue.state) {
                .open => null,
                .closed => |round| @as(?u32, round),
            });
            try s.endObject();
        }
        try w.writeAll(if (self.issues.items.len == 0) "]\n" else "\n]\n");
    }

    fn requireOpen(self: *const Ledger, id: IssueId) ApplyError!void {
        const issue = self.find(id) orelse return error.UnknownIssue;
        if (issue.state != .open) return error.IssueAlreadyClosed;
    }

    /// One past the largest `issue-<n>` ever assigned.
    fn nextOrdinal(self: *const Ledger) u32 {
        var next: u32 = 1;
        for (self.issues.items) |issue| {
            const text = issue.id.slice();
            if (!std.mem.startsWith(u8, text, auto_prefix)) continue;
            const n = std.fmt.parseInt(u32, text[auto_prefix.len..], 10) catch continue;
            if (n >= next) next = n +| 1;
        }
        return next;
    }

    fn parseIssue(value: std.json.Value) error{LedgerCorrupt}!Issue {
        if (value != .object) return error.LedgerCorrupt;
        const obj = value.object;
        const id = IssueId.parse(stringField(obj, "id") orelse return error.LedgerCorrupt) catch
            return error.LedgerCorrupt;
        const state_text = stringField(obj, "state") orelse return error.LedgerCorrupt;
        const round_opened = u32Field(obj, "round_opened") orelse return error.LedgerCorrupt;
        const round_closed = obj.get("round_closed") orelse return error.LedgerCorrupt;
        const state: State = if (std.mem.eql(u8, state_text, "open")) blk: {
            if (round_closed != .null) return error.LedgerCorrupt;
            break :blk .open;
        } else if (std.mem.eql(u8, state_text, "closed"))
            .{ .closed = u32Field(obj, "round_closed") orelse return error.LedgerCorrupt }
        else
            return error.LedgerCorrupt;
        const file = obj.get("file") orelse return error.LedgerCorrupt;
        const line = obj.get("line") orelse return error.LedgerCorrupt;
        const location: ?Location = switch (file) {
            .null => blk: {
                if (line != .null) return error.LedgerCorrupt;
                break :blk null;
            },
            .string => |f| .{ .file = f, .line = if (line == .null) null else u32Field(obj, "line") orelse return error.LedgerCorrupt },
            else => return error.LedgerCorrupt,
        };
        return .{
            .id = id,
            .state = state,
            .title = stringField(obj, "title") orelse return error.LedgerCorrupt,
            .detail = stringField(obj, "detail") orelse return error.LedgerCorrupt,
            .location = location,
            .round_opened = round_opened,
        };
    }
};

const auto_prefix = "issue-";

fn autoId(n: u32) IssueId {
    var buf: [IssueId.max_len]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, auto_prefix ++ "{d}", .{n}) catch unreachable;
    return IssueId.parse(text) catch unreachable;
}

fn openedHas(opened: []const NewIssue, id: IssueId) bool {
    for (opened) |issue| if (issue.id) |own| if (own.eql(id)) return true;
    return false;
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn u32Field(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = obj.get(key) orelse return null;
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) return null;
    return @intCast(value.integer);
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn iid(text: []const u8) IssueId {
    return IssueId.parse(text) catch unreachable;
}

test "issues: apply assigns stable ids, closes, and never reuses an id" {
    var ledger = Ledger.init(testing.allocator);
    defer ledger.deinit();
    const s1 = try ledger.apply(.{ .opened = &.{
        .{ .title = "Off by one", .detail = "Loop skips the last item.", .location = .{ .file = "src/a.zig", .line = 12 } },
        .{ .id = iid("flaky-test"), .title = "Flaky", .detail = "Depends on wall time." },
        .{ .title = "No docs", .detail = "Flag undocumented." },
    } }, 1);
    try testing.expectEqual(@as(u32, 3), s1.open_total);
    try testing.expectEqualStrings("issue-1", ledger.issues.items[0].id.slice());
    try testing.expectEqualStrings("flaky-test", ledger.issues.items[1].id.slice());
    try testing.expectEqualStrings("issue-2", ledger.issues.items[2].id.slice());

    const s2 = try ledger.apply(.{
        .closed = &.{iid("issue-1")},
        .still_open = &.{iid("flaky-test")},
        .opened = &.{.{ .title = "New", .detail = "d" }},
    }, 2);
    try testing.expectEqual(@as(u32, 3), s2.open_total);
    try testing.expectEqual(@as(u32, 2), ledger.find(iid("issue-1")).?.state.closed);
    // issue-1 is closed, not forgotten: the next automatic id is issue-3.
    try testing.expectEqualStrings("issue-3", ledger.issues.items[3].id.slice());
}

test "issues: a bad reference leaves the ledger untouched" {
    var ledger = Ledger.init(testing.allocator);
    defer ledger.deinit();
    _ = try ledger.apply(.{ .opened = &.{.{ .title = "t", .detail = "d" }} }, 1);
    _ = try ledger.apply(.{ .closed = &.{iid("issue-1")}, .opened = &.{.{ .title = "u", .detail = "e" }} }, 2);
    const before = try ledger.render(testing.allocator);
    defer testing.allocator.free(before);

    try testing.expectError(error.UnknownIssue, ledger.apply(.{ .closed = &.{iid("issue-9")}, .opened = &.{.{ .title = "x", .detail = "y" }} }, 3));
    try testing.expectError(error.IssueAlreadyClosed, ledger.apply(.{ .still_open = &.{iid("issue-1")} }, 3));
    try testing.expectError(error.DuplicateIssueId, ledger.apply(.{ .opened = &.{.{ .id = iid("issue-1"), .title = "x", .detail = "y" }} }, 3));

    const after = try ledger.render(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "issues: the ledger round-trips through open_issues.json and rejects corruption" {
    var root = run_dir.test_support.TestRoot.init("cc-zig-teamwork-issues");
    defer root.deinit();
    var run = try run_dir.RunDir.create(testing.allocator, root.slice(), try types.RunId.parse("r1"));
    defer run.deinit(testing.allocator);

    var empty = try Ledger.load(testing.allocator, &run);
    try testing.expectEqual(@as(usize, 0), empty.issues.items.len);
    _ = try empty.apply(.{ .opened = &.{
        .{ .title = "A \"quoted\" title", .detail = "line one\nline two", .location = .{ .file = "src/b.zig" } },
        .{ .title = "B", .detail = "d", .location = .{ .file = "src/c.zig", .line = 7 } },
    } }, 1);
    _ = try empty.apply(.{ .closed = &.{iid("issue-2")} }, 2);
    try empty.save(testing.allocator, &run);
    empty.deinit();

    var loaded = try Ledger.load(testing.allocator, &run);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.issues.items.len);
    const a = loaded.find(iid("issue-1")).?;
    try testing.expectEqualStrings("A \"quoted\" title", a.title);
    try testing.expectEqualStrings("src/b.zig", a.location.?.file);
    try testing.expect(a.location.?.line == null);
    try testing.expectEqual(@as(u32, 2), loaded.find(iid("issue-2")).?.state.closed);

    const bad = [_][]const u8{
        "{}",
        "[{\"id\":\"Bad Id\",\"state\":\"open\",\"title\":\"t\",\"detail\":\"d\",\"file\":null,\"line\":null,\"round_opened\":1,\"round_closed\":null}]",
        "[{\"id\":\"a\",\"state\":\"open\",\"title\":\"t\",\"detail\":\"d\",\"file\":null,\"line\":null,\"round_opened\":1,\"round_closed\":2}]",
        "[{\"id\":\"a\",\"state\":\"open\",\"title\":\"t\",\"detail\":\"d\",\"file\":null,\"line\":3,\"round_opened\":1,\"round_closed\":null}]",
        "[{\"id\":\"a\",\"state\":\"gone\",\"title\":\"t\",\"detail\":\"d\",\"file\":null,\"line\":null,\"round_opened\":1,\"round_closed\":null}]",
    };
    for (bad) |text| try testing.expectError(error.LedgerCorrupt, Ledger.parse(testing.allocator, text));
}

test "issues: the seat copy is read-only and the open list renders deterministically" {
    var root = run_dir.test_support.TestRoot.init("cc-zig-teamwork-issues-copy");
    defer root.deinit();
    var run = try run_dir.RunDir.create(testing.allocator, root.slice(), try types.RunId.parse("r1"));
    defer run.deinit(testing.allocator);
    const seat = types.seatIdFor(.reviewer, 1);
    try run.createSeat(.{ .id = seat, .role = .reviewer, .harness = .metacodes, .status = .queued });

    var ledger = Ledger.init(testing.allocator);
    defer ledger.deinit();
    _ = try ledger.apply(.{ .opened = &.{
        .{ .title = "Leak", .detail = "Buffer never freed.\nSee the error path.", .location = .{ .file = "src/x.zig", .line = 40 } },
        .{ .title = "Fixed later", .detail = "d" },
    } }, 1);
    _ = try ledger.apply(.{ .closed = &.{iid("issue-2")} }, 2);
    try ledger.writeSeatCopy(testing.allocator, &run, seat);
    // A second round rewrites the copy over the read-only one.
    try ledger.writeSeatCopy(testing.allocator, &run, seat);

    var buf: run_dir.PathBuf = undefined;
    const copy_path = try run.seatPath(&buf, seat, .open_issues_copy);
    const copy = swarm_team.readFileAlloc(testing.allocator, copy_path).?;
    defer testing.allocator.free(copy);
    const want = try ledger.render(testing.allocator);
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, copy);
    if (@import("builtin").os.tag != .windows) {
        const fd = pfs.open(copy_path.ptr, .{ .ACCMODE = .RDONLY }, 0);
        try testing.expect(fd >= 0);
        defer pfs.close(fd);
        const info = try pfs.fileInfo(fd);
        try testing.expectEqual(@as(u32, 0o444), @as(u32, @intCast(info.mode & 0o777)));
    }

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try ledger.renderOpen(&out.writer);
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "- `issue-1` Leak (src/x.zig:40) [opened in round 1]\n  Buffer never freed.\n  See the error path.\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "issue-2") == null);
}
