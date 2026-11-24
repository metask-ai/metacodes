const std = @import("std");
const app_mod = @import("../app.zig");
const cmd_output = @import("cmd_output.zig");
const command = @import("../teamwork/command.zig");
const interview = @import("../teamwork/interview.zig");
const types = @import("../teamwork/types.zig");
const progress = @import("../teamwork/progress.zig");
const agent_tree = @import("tui/widget/agent_tree.zig");

pub const LineReader = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque) ?[]u8,

    fn read(self: LineReader) ?[]u8 {
        return self.readFn(self.ctx);
    }
};

pub const Session = struct {
    job: ?*command.Background = null,
    board: progress.Board = .init(std.heap.c_allocator),

    pub fn deinit(self: *Session) void {
        defer self.board.deinit();
        const job = self.job orelse return;
        self.job = null;
        if (!job.finished()) cmd_output.print("Teamwork run {s} was cancelled with this session. Continue it with: metacodes --preview teamwork resume {s} --approve (under the same permission mode and sandbox settings)\n", .{ job.id.slice(), job.id.slice() });
        job.stop();
    }
};

pub const usage =
    \\Usage: /teamwork [skip-interview] [seats=<role>:<harness>[:<model>],...] <request>
    \\       /teamwork status [<run id>]
    \\
;

pub fn handle(app: *app_mod.App, allocator: std.mem.Allocator, session: *Session, args: []const u8, reader: LineReader) void {
    const theme = app.theme;
    if (std.mem.eql(u8, args, "status") or std.mem.startsWith(u8, args, "status ")) {
        showStatus(app, allocator, session, std.mem.trim(u8, args["status".len..], " \t"));
        return;
    }
    if (!app.config.preview.features().teamwork) {
        cmd_output.print("{s}/teamwork is a preview feature and it is off. Start metacodes with --preview=teamwork (or --preview), or set \"preview\": {{\"teamwork\": true}} in config.json.{s}\n", .{ theme.danger, theme.reset });
        return;
    }
    if (std.mem.trim(u8, args, " \t\r\n").len == 0) {
        cmd_output.print("{s}", .{usage});
        return;
    }
    if (session.job) |job| {
        if (!job.finished()) {
            cmd_output.print("{s}Teamwork run {s} is still running. Check it with /teamwork status.{s}\n", .{ theme.warn, job.id.slice(), theme.reset });
            return;
        }
        job.stop();
        session.job = null;
    }
    session.board.clear();
    var prompter_state: Prompter = .{ .app = app, .allocator = allocator, .reader = reader };
    defer prompter_state.deinit();
    cmd_output.print("Preparing the teamwork run; unless the request says [skip-interview], the interviewer drafts the task first…\n", .{});
    const result = command.startInteractive(app, app.cwdAbs(), args, prompter_state.prompter(), &session.board);
    app.abort.reset();
    settleBoard(&session.board, result);
    const outcome = result catch |err| {
        cmd_output.print("{s}/teamwork failed: {s}{s}\n", .{ theme.danger, @errorName(err), theme.reset });
        return;
    };
    switch (outcome) {
        .started => |job| {
            session.job = job;
            cmd_output.print("Teamwork run {s} has started in the background. Ask about its progress at any time: /teamwork status\n", .{job.id.slice()});
        },
        .rejected => |id| ended(app, "Rejected.", id),
        .interview_failed => |id| ended(app, "The interviewer did not produce a draft.", id),
        .budget_exhausted => |id| ended(app, "The budget ran out during the interview.", id),
        .aborted => |id| ended(app, "The interview was cancelled.", id),
    }
}

fn settleBoard(board: *progress.Board, result: anyerror!command.Interactive) void {
    const outcome = result catch return board.clear();
    if (outcome != .started) board.clear();
}

fn ended(app: *app_mod.App, what: []const u8, id: types.RunId) void {
    cmd_output.print("{s} Nothing was started. Any interview spend is recorded in {s}/teamwork/{s}/budget.jsonl.\n", .{ what, app.stateRoot(), id.slice() });
}

fn showStatus(app: *app_mod.App, allocator: std.mem.Allocator, session: *Session, explicit: []const u8) void {
    if (explicit.len == 0 and session.job != null) {
        if (showProgress(app, allocator, &session.board)) {
            showResumeHint(session.job.?);
            return;
        }
    }
    const id = if (explicit.len != 0)
        types.RunId.parse(explicit) catch {
            cmd_output.print("{s}Invalid run id: {s}{s}\n", .{ app.theme.danger, explicit, app.theme.reset });
            return;
        }
    else if (session.job) |job| job.id else {
        cmd_output.print("No teamwork run in this session. {s}", .{usage});
        return;
    };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    cmd_output.end();
    command.status(arena_state.allocator(), app.stateRoot(), id) catch |err| {
        cmd_output.print("{s}/teamwork status {s}: {s}{s}\n", .{ app.theme.danger, id.slice(), @errorName(err), app.theme.reset });
    };
}

fn showResumeHint(job: *command.Background) void {
    if (!job.finished()) return;
    const run = job.run orelse return;
    switch (run.state) {
        .budget_exhausted => |paused| if (paused != null)
            cmd_output.print("The run paused at its ${d} cap; the worktree is kept. Approve a higher cap and continue with: metacodes --preview teamwork resume {s} --approve --budget-usd <dollars>\n", .{ run.ledger.cap_usd, job.id.slice() }),
        else => {},
    }
}

fn showProgress(app: *app_mod.App, allocator: std.mem.Allocator, board: *progress.Board) bool {
    var copy = (board.read(allocator) catch return false) orelse return false;
    defer copy.deinit();
    const text = agent_tree.renderTeamwork(allocator, app.theme, copy.snapshot(), null) catch return false;
    defer allocator.free(text);
    cmd_output.print("{s}", .{text});
    return true;
}

const Prompter = struct {
    app: *app_mod.App,
    allocator: std.mem.Allocator,
    reader: LineReader,
    edits: std.ArrayList([]u8) = .empty,

    fn prompter(self: *Prompter) interview.Prompter {
        return .{ .ctx = self, .decideFn = decide };
    }

    fn deinit(self: *Prompter) void {
        for (self.edits.items) |text| self.allocator.free(text);
        self.edits.deinit(self.allocator);
    }

    fn decide(ctx: *anyopaque, terms: []const u8, proposal: []const u8) anyerror!interview.Decision {
        const self: *Prompter = @ptrCast(@alignCast(ctx));
        const theme = self.app.theme;
        cmd_output.print("\n{s}Proposed task{s}\n\n{s}\n\n{s}\n", .{ theme.dim, theme.reset, proposal, terms });
        while (true) {
            cmd_output.print("Approve and start? [y]es / [e]dit / [n]o: ", .{});
            cmd_output.end();
            const line = self.reader.read() orelse return .reject;
            defer self.allocator.free(line);
            const answer = std.mem.trim(u8, line, " \t\r\n");
            if (eqlAny(answer, &.{ "y", "yes", "approve" })) return .approve;
            if (eqlAny(answer, &.{ "n", "no", "reject" })) return .reject;
            if (eqlAny(answer, &.{ "e", "edit" })) {
                cmd_output.print("Type the task statement to approve instead:\n", .{});
                cmd_output.end();
                const edited = self.reader.read() orelse return .reject;
                errdefer self.allocator.free(edited);
                try self.edits.append(self.allocator, edited);
                return .{ .edit = edited };
            }
        }
    }
};

fn eqlAny(text: []const u8, options: []const []const u8) bool {
    for (options) |option| if (std.ascii.eqlIgnoreCase(text, option)) return true;
    return false;
}

test "teamwork REPL: an interview that starts no run leaves no progress panel behind" {
    const runtime = @import("../teamwork/runtime.zig");
    var board = progress.Board.init(std.testing.allocator);
    defer board.deinit();
    const id = try types.RunId.parse("run-1");
    const seats = [_]runtime.SeatSnapshot{.{ .id = types.seatIdFor(.interviewer, 1), .role = .interviewer, .harness = .metacodes, .status = .needs_you }};
    const waiting: progress.Snapshot = .{
        .run_id = id,
        .goal = "add a feature",
        .phase = .interviewing,
        .seats = &seats,
        .budget = .{ .cap_usd = 2, .spent_usd = 0.25, .remaining_usd = 1.75, .charges = 1 },
        .audit = .{ .used = 0, .last = null },
    };
    const endings = [_]anyerror!command.Interactive{
        .{ .rejected = id },
        .{ .interview_failed = id },
        .{ .budget_exhausted = id },
        .{ .aborted = id },
        error.RunExists,
    };
    for (endings) |ending| {
        try board.publish(waiting);
        settleBoard(&board, ending);
        try std.testing.expect((try board.read(std.testing.allocator)) == null);
    }
}
