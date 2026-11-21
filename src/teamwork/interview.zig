const std = @import("std");
const pfs = @import("platform").fs;
const types = @import("types.zig");
const config = @import("config.zig");
const run_dir = @import("run_dir.zig");
const ledger_mod = @import("ledger.zig");
const charters = @import("charters.zig");
const merge_back = @import("merge_back.zig");
const runtime = @import("runtime.zig");
const common = @import("drivers/common.zig");
const factory = @import("drivers/factory.zig");
const progress = @import("progress.zig");

pub const RequestSource = runtime.RequestSource;

pub const Segments = struct {
    skip_interview: bool = false,
    seats: config.Layer = .{},
    request: []const u8,
};

pub const SegmentError = error{
    UnknownTeamworkSegment,
    UnterminatedTeamworkSegment,
    DuplicateTeamworkSegment,
    InvalidTeamworkSeats,
    EmptyRequest,
    OutOfMemory,
};

pub fn parseSegments(arena: std.mem.Allocator, text: []const u8) SegmentError!Segments {
    var out: Segments = .{ .request = text };
    var seen_skip = false;
    var seen_seats = false;
    var rest = text;
    while (true) {
        const start = std.mem.trimStart(u8, rest, " \t\r\n");
        if (start.len == 0 or start[0] != '[') break;
        const close = std.mem.indexOfScalar(u8, start, ']') orelse return error.UnterminatedTeamworkSegment;
        const body = std.mem.trim(u8, start[1..close], " \t");
        if (std.mem.eql(u8, body, "skip-interview")) {
            if (seen_skip) return error.DuplicateTeamworkSegment;
            seen_skip = true;
            out.skip_interview = true;
        } else if (std.mem.startsWith(u8, body, "seats=")) {
            if (seen_seats) return error.DuplicateTeamworkSegment;
            seen_seats = true;
            out.seats = try parseSeats(arena, body["seats=".len..]);
        } else return error.UnknownTeamworkSegment;
        rest = start[close + 1 ..];
        out.request = std.mem.trimStart(u8, rest, " \t\r\n");
    }
    if (std.mem.trim(u8, out.request, " \t\r\n").len == 0) return error.EmptyRequest;
    return out;
}

fn parseSeats(arena: std.mem.Allocator, list: []const u8) SegmentError!config.Layer {
    var layer: config.Layer = .{};
    var seen = std.EnumSet(types.Role).initEmpty();
    var entries = std.mem.splitScalar(u8, list, ',');
    while (entries.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        var fields = std.mem.splitScalar(u8, entry, ':');
        const role = types.Role.parse(fields.first()) orelse return error.InvalidTeamworkSeats;
        const harness = types.Harness.parse(fields.next() orelse return error.InvalidTeamworkSeats) orelse return error.InvalidTeamworkSeats;
        if (seen.contains(role)) return error.InvalidTeamworkSeats;
        seen.insert(role);
        var seat: config.SeatLayer = .{ .harness = harness };
        const model = fields.rest();
        if (model.len != 0) seat.model = try arena.dupe(u8, model);
        layer.seats.set(role, seat);
    }
    return layer;
}

pub const Draft = union(enum) {
    text: []u8,
    failed: types.SeatError,
    budget_exhausted,
    aborted,

    pub fn deinit(self: *Draft, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .text => |text| gpa.free(text),
            .failed, .budget_exhausted, .aborted => {},
        }
        self.* = undefined;
    }
};

pub const interviewer_seat = "interviewer-1";
pub const interview_worktree_dir = "interview";

pub fn draft(gpa: std.mem.Allocator, deps: runtime.Deps, cfg: config.Config.Enabled, options: runtime.StartOptions, request: []const u8, abort: *const types.AbortSignal) !Draft {
    if (!deps.preview.teamwork) return error.PreviewDisabled;
    if (std.mem.trim(u8, request, " \t\r\n").len == 0) return error.EmptyRequest;
    const repo = try merge_back.toplevel(gpa, options.workspace, null);
    defer gpa.free(repo);
    var dir = try run_dir.RunDir.reserveRoot(gpa, options.state_root, options.run_id, false);
    defer dir.deinit(gpa);
    try dir.initialize();
    var buf: run_dir.PathBuf = undefined;
    var ledger = try ledger_mod.Ledger.load(gpa, try dir.path(&buf, .budget), cfg.budget_usd);
    defer ledger.deinit(gpa);

    const id = types.SeatId.parse(interviewer_seat) catch unreachable;
    const spec = cfg.seats.getPtrConst(.interviewer);
    const digest = std.fmt.bytesToHex(charters.digest(.interviewer), .lower);
    var record: run_dir.SeatRecord = .{ .id = id, .role = .interviewer, .harness = spec.harnessKind(), .status = .queued, .charter_sha256 = digest };
    try dir.createSeat(record);
    const reporter: Reporter = .{ .observer = deps.observer, .run_id = options.run_id, .goal = runtime.goalOf(request), .ledger = &ledger };
    reporter.seat(record, null);
    const packet = try renderPacket(gpa, request);
    defer gpa.free(packet);
    try dir.writePacket(id, packet);

    const snapshot = try merge_back.snapshot(gpa, repo, dir.root, abort);
    const worktree = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir.root, interview_worktree_dir });
    defer gpa.free(worktree);
    try merge_back.addWorktree(gpa, repo, worktree, snapshot.commit, abort);
    defer _ = merge_back.removeWorktree(gpa, repo, worktree);

    record.status = .working;
    try dir.writeSeatRecord(record);
    reporter.seat(record, .queued);
    var packet_buf: run_dir.PathBuf = undefined;
    var handoff_buf: run_dir.PathBuf = undefined;
    const paths: types.SeatPaths = .{
        .packet = try dir.seatPath(&packet_buf, id, .packet),
        .handoff = try dir.seatPath(&handoff_buf, id, .handoff),
        .workspace = worktree,
    };
    const binding: common.Binding = .{ .ledger = &ledger, .seat = id };
    var outcome = switch (deps.seats) {
        .harness => |configured| blk: {
            var seat_deps = configured;
            seat_deps.metacodes.preview = deps.preview;
            seat_deps.claude_code.preview = deps.preview;
            var driver = factory.forSeat(spec, seat_deps, binding);
            break :blk try driver.driver().run(gpa, spec, paths, abort);
        },
        .custom => |custom| try custom.driverFn(custom.ctx, spec, binding).run(gpa, spec, paths, abort),
    };
    defer outcome.deinit(gpa);
    const exhausted = outcome != .aborted and ledger.isExhausted();
    record.status = switch (outcome) {
        .finished => if (exhausted) .done else .needs_you,
        else => .failed,
    };
    try dir.writeSeatRecord(record);
    reporter.seat(record, .working);
    if (exhausted) return .budget_exhausted;
    return switch (outcome) {
        .finished => |handoff| .{ .text = try std.fmt.allocPrint(gpa, "{s}\n\n## Acceptance checks\n\n{s}\n", .{
            std.mem.trim(u8, handoff.conclusion, " \t\r\n"),
            std.mem.trim(u8, handoff.verification, " \t\r\n"),
        }) },
        .failed => |err| .{ .failed = err },
        .budget_exhausted => .budget_exhausted,
        .aborted => .aborted,
    };
}

pub fn finishApproval(gpa: std.mem.Allocator, deps: runtime.Deps, cfg: config.Config.Enabled, options: runtime.StartOptions, request: []const u8) !void {
    var dir = try run_dir.RunDir.open(gpa, options.state_root, options.run_id);
    defer dir.deinit(gpa);
    var record = try dir.readSeatRecord(types.SeatId.parse(interviewer_seat) catch unreachable);
    if (record.status != .needs_you) return;
    record.status = .done;
    try dir.writeSeatRecord(record);
    var buf: run_dir.PathBuf = undefined;
    var ledger = try ledger_mod.Ledger.load(gpa, try dir.path(&buf, .budget), cfg.budget_usd);
    defer ledger.deinit(gpa);
    const reporter: Reporter = .{ .observer = deps.observer, .run_id = options.run_id, .goal = runtime.goalOf(request), .ledger = &ledger };
    reporter.seat(record, .needs_you);
}

const Reporter = struct {
    observer: ?progress.Observer,
    run_id: types.RunId,
    goal: []const u8,
    ledger: *const ledger_mod.Ledger,

    fn seat(self: Reporter, record: run_dir.SeatRecord, from: ?types.SeatStatus) void {
        const observer = self.observer orelse return;
        const seats = [_]runtime.SeatSnapshot{.{ .id = record.id, .role = record.role, .harness = record.harness, .status = record.status, .charter_sha256 = record.charter_sha256 }};
        const event: progress.Event = .{
            .change = .{ .seat = .{ .id = record.id, .from = from, .to = record.status } },
            .snapshot = .{
                .run_id = self.run_id,
                .goal = self.goal,
                .phase = .interviewing,
                .seats = &seats,
                .budget = .{ .cap_usd = self.ledger.cap_usd, .spent_usd = self.ledger.spent_usd, .remaining_usd = self.ledger.remainingUsd(), .charges = self.ledger.entries },
                .audit = .{ .used = 0, .last = null },
            },
        };
        observer.notify(&event);
    }
};

pub fn renderPacket(gpa: std.mem.Allocator, request: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(gpa,
        \\# Interview
        \\
        \\Turn the user's request below into the task statement for this run. Your working directory is a snapshot of the user's repository made for this interview: read the code there and change nothing.
        \\
        \\## Output
        \\
        \\Next to this packet write `handoff.md` with the sections `## Observation`, `## Reasoning`, `## Caveats`, `## Conclusion` and `## Verification`. The Conclusion is the proposed task statement, written for an implementer who never met the user. The Verification lists the acceptance checks. The user approves, edits or rejects your proposal before any work starts.
        \\
        \\## Request
        \\
        \\{s}
    , .{request});
}

pub const Decision = union(enum) {
    approve,
    edit: []const u8,
    reject,
};

pub const Approved = struct {
    text: []const u8,
    source: RequestSource,
};

pub const Prompter = struct {
    ctx: *anyopaque,
    decideFn: *const fn (ctx: *anyopaque, terms: []const u8, draft: []const u8) anyerror!Decision,
};

pub fn approve(proposal: []const u8, unchanged: RequestSource, terms: []const u8, prompter: Prompter) !?Approved {
    var current = proposal;
    var edited = false;
    while (true) {
        switch (try prompter.decideFn(prompter.ctx, terms, current)) {
            .approve => return .{ .text = current, .source = if (edited) .user_edited else unchanged },
            .edit => |text| {
                if (std.mem.trim(u8, text, " \t\r\n").len == 0) continue;
                current = text;
                edited = true;
            },
            .reject => return null,
        }
    }
}

test "segments: none keeps the request byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = "  Fix the [bug] in x.\n";
    const parsed = try parseSegments(arena_state.allocator(), text);
    try std.testing.expect(!parsed.skip_interview);
    try std.testing.expectEqual(text.ptr, parsed.request.ptr);
    try std.testing.expectEqual(text.len, parsed.request.len);
}

test "segments: skip-interview and seats override the configured layer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseSegments(arena_state.allocator(), "[skip-interview] [seats=implementer:metacodes:fast-model, reviewer:claude_code]\nAdd x.\n");
    try std.testing.expect(parsed.skip_interview);
    try std.testing.expectEqualStrings("Add x.\n", parsed.request);
    try std.testing.expectEqual(types.Harness.metacodes, parsed.seats.seats.get(.implementer).harness.?);
    try std.testing.expectEqualStrings("fast-model", parsed.seats.seats.get(.implementer).model.?);
    try std.testing.expectEqual(types.Harness.claude_code, parsed.seats.seats.get(.reviewer).harness.?);
    try std.testing.expect(parsed.seats.seats.get(.reviewer).model == null);
    try std.testing.expect(parsed.seats.seats.get(.verifier).harness == null);
}

test "segments: malformed options are refused, never treated as request text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectError(error.UnknownTeamworkSegment, parseSegments(a, "[skip-interviews] x"));
    try std.testing.expectError(error.UnterminatedTeamworkSegment, parseSegments(a, "[skip-interview x"));
    try std.testing.expectError(error.DuplicateTeamworkSegment, parseSegments(a, "[skip-interview][skip-interview] x"));
    try std.testing.expectError(error.InvalidTeamworkSeats, parseSegments(a, "[seats=implementer] x"));
    try std.testing.expectError(error.InvalidTeamworkSeats, parseSegments(a, "[seats=boss:metacodes] x"));
    try std.testing.expectError(error.InvalidTeamworkSeats, parseSegments(a, "[seats=reviewer:codex] x"));
    try std.testing.expectError(error.InvalidTeamworkSeats, parseSegments(a, "[seats=reviewer:metacodes,reviewer:claude_code] x"));
    try std.testing.expectError(error.EmptyRequest, parseSegments(a, "[skip-interview]  \n"));
}

test "interview packet: fixed text plus the request, nothing run-specific" {
    const a = try renderPacket(std.testing.allocator, "Add x.\n");
    defer std.testing.allocator.free(a);
    const b = try renderPacket(std.testing.allocator, "Add x.\n");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings(a, b);
    try std.testing.expect(std.mem.endsWith(u8, a, "## Request\n\nAdd x.\n"));
    try std.testing.expect(std.mem.indexOfScalar(u8, a, '/') == null);
}

const ScriptedPrompter = struct {
    decisions: []const Decision,
    shown: [4][]const u8 = undefined,
    calls: usize = 0,

    fn prompter(self: *ScriptedPrompter) Prompter {
        return .{ .ctx = self, .decideFn = decide };
    }

    fn decide(ctx: *anyopaque, _: []const u8, proposal: []const u8) anyerror!Decision {
        const self: *ScriptedPrompter = @ptrCast(@alignCast(ctx));
        self.shown[self.calls] = proposal;
        defer self.calls += 1;
        return self.decisions[self.calls];
    }
};

test "approve: the approved bytes are the last text the user saw" {
    var plain: ScriptedPrompter = .{ .decisions = &.{.approve} };
    const as_drafted = (try approve("draft\n", .interview, "terms", plain.prompter())).?;
    try std.testing.expectEqualStrings("draft\n", as_drafted.text);
    try std.testing.expectEqual(RequestSource.interview, as_drafted.source);

    var editing: ScriptedPrompter = .{ .decisions = &.{ .{ .edit = "  \n" }, .{ .edit = "edited\r\ntext \n" }, .approve } };
    const edited = (try approve("draft\n", .interview, "terms", editing.prompter())).?;
    try std.testing.expectEqualStrings("edited\r\ntext \n", edited.text);
    try std.testing.expectEqual(RequestSource.user_edited, edited.source);
    try std.testing.expectEqualStrings("edited\r\ntext \n", editing.shown[2]);

    var rejecting: ScriptedPrompter = .{ .decisions = &.{ .{ .edit = "other" }, .reject } };
    try std.testing.expect(try approve("draft\n", .interview, "terms", rejecting.prompter()) == null);
}
