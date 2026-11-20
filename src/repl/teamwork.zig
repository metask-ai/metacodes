const std = @import("std");
const app_mod = @import("../app.zig");
const cmd_output = @import("cmd_output.zig");
const command = @import("../teamwork/command.zig");
const interview = @import("../teamwork/interview.zig");
const types = @import("../teamwork/types.zig");

pub const LineReader = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque) ?[]u8,

    fn read(self: LineReader) ?[]u8 {
        return self.readFn(self.ctx);
    }
};

pub const Session = struct {
    job: ?*command.Background = null,

    pub fn deinit(self: *Session) void {
        const job = self.job orelse return;
        self.job = null;
        if (!job.finished()) cmd_output.print("Teamwork run {s} was cancelled with this session. Continue it with: metacodes --preview teamwork resume {s} --approve\n", .{ job.id.slice(), job.id.slice() });
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
    if (!app.config.preview.isEnabled()) {
        cmd_output.print("{s}/teamwork is a preview feature and preview is off. Start metacodes with --preview or set \"preview\": true in config.json.{s}\n", .{ theme.danger, theme.reset });
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
    var prompter_state: Prompter = .{ .app = app, .allocator = allocator, .reader = reader };
    defer prompter_state.deinit();
    cmd_output.print("Preparing the teamwork run; unless the request says [skip-interview], the interviewer drafts the task first…\n", .{});
    const outcome = command.startInteractive(app, app.cwdAbs(), args, prompter_state.prompter()) catch |err| {
        cmd_output.print("{s}/teamwork failed: {s}{s}\n", .{ theme.danger, @errorName(err), theme.reset });
        return;
    };
    switch (outcome) {
        .started => |job| {
            session.job = job;
            cmd_output.print("Teamwork run {s} has started in the background. Ask about its progress at any time: /teamwork status\n", .{job.id.slice()});
        },
        .rejected => |id| cmd_output.print("Rejected. Nothing was started (interview record: teamwork run {s}).\n", .{id.slice()}),
        .interview_failed => |id| cmd_output.print("{s}The interviewer did not produce a draft (run {s}). Nothing was started.{s}\n", .{ theme.danger, id.slice(), theme.reset }),
        .budget_exhausted => |id| cmd_output.print("{s}The budget ran out during the interview (run {s}). Nothing was started.{s}\n", .{ theme.danger, id.slice(), theme.reset }),
        .aborted => |id| cmd_output.print("The interview was cancelled (run {s}). Nothing was started.\n", .{id.slice()}),
    }
}

fn showStatus(app: *app_mod.App, allocator: std.mem.Allocator, session: *const Session, explicit: []const u8) void {
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

    fn decide(ctx: *anyopaque, proposal: []const u8) anyerror!interview.Decision {
        const self: *Prompter = @ptrCast(@alignCast(ctx));
        const theme = self.app.theme;
        cmd_output.print("\n{s}Proposed task{s}\n\n{s}\n", .{ theme.dim, theme.reset, proposal });
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
