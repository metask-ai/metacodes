const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const pfs = platform.fs;
const runtime = @import("runtime.zig");
const swe_loop = @import("swe_loop.zig");
const types = @import("types.zig");
const run_dir = @import("run_dir.zig");
const ledger_mod = @import("ledger.zig");
const claude_code = @import("drivers/claude_code.zig");
const mcp_server = @import("mcp_server.zig");
const log = @import("../util/log.zig");

pub const relay_file = "manager-relay.sh";
pub const channel_in = "mcp.in";
pub const channel_out = "mcp.out";

pub const relay_script =
    \\exec 3>>"$1" 4<"$2"
    \\cat <&4 &
    \\reader=$!
    \\cat >&3
    \\kill "$reader" 2>/dev/null
    \\
;

pub fn drive(run: *runtime.Run, options: claude_code.Options) !runtime.State {
    switch (run.cfg.seats.get(.manager).harness) {
        .metacodes => return swe_loop.drive(run),
        .claude_code => {
            if (builtin.os.tag == .windows) return error.UnsupportedPlatform else try driveLaunched(run, options);
            return run.state;
        },
    }
}

fn driveLaunched(run: *runtime.Run, options: claude_code.Options) !void {
    const id = run.openManager() catch |err| switch (err) {
        error.RunEnded, error.BudgetExhausted, error.RoundsExhausted => return,
        else => |e| return e,
    };
    var arena_state = std.heap.ArenaAllocator.init(run.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir_buf: run_dir.PathBuf = undefined;
    const seat_dir = try arena.dupe(u8, try run.seatDir(&dir_buf, id));
    var harness_log = claude_code.HarnessLog.open(arena, seat_dir);
    defer harness_log.close();
    const spec = run.cfg.seats.getPtrConst(.manager);
    const allowance = run.cfg.manager_budget_usd.?;

    var driver = claude_code.ClaudeCodeDriver.init(options, .{ .ledger = &run.ledger, .seat = id });
    if (!try driver.probeManager(arena, spec.harness.claude_code.command.bytes, seat_dir, &run.abort, &harness_log)) {
        try run.failManager(id);
        return;
    }
    var channel = Channel.open(arena, seat_dir) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        harness_log.print("manager channel setup failed: {s}\n", .{@errorName(err)});
        try run.failManager(id);
        return;
    };
    defer channel.close();
    const config = mcpConfig(arena, run, &channel) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        harness_log.print("manager relay setup failed: {s}\n", .{@errorName(err)});
        try run.failManager(id);
        return;
    };
    var launch = driver.prepareManager(arena, spec, seat_dir, config, allowance) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        harness_log.print("sandbox setup failed: {s}\n", .{@errorName(err)});
        try run.failManager(id);
        return;
    };
    defer launch.deinit();
    run.holdManager(id) catch |err| switch (err) {
        error.BudgetExhausted => return,
        else => |e| return e,
    };

    var ended: claude_code.ManagerLaunch.Ended = .{ .stop = .spawn_failed };
    const watcher = try platform.thread.spawn(.full, superviseManager, .{ &launch, run.gpa, harness_log.fd, &run.abort, &ended });
    var server = mcp_server.Server.init(run.gpa, run);
    const served = server.serveFds(channel.input, channel.output);
    if (!run.abort.isAborted()) run.abort.abort(.host_failure);
    watcher.join();
    if (ended.stop == .spawn_failed) harness_log.print("could not start the manager\n", .{});
    try run.finishManager(id, ended.elapsed_ms, costOf(ended, allowance), resultOf(&launch, ended));
    if (ended.oom) return error.OutOfMemory;
    served catch |err| {
        if (err == error.OutOfMemory or !run.state.isTerminal()) return err;
        log.warn("teamwork", "run {s}: manager channel closed: {s}", .{ run.dir.run_id.slice(), @errorName(err) });
    };
}

fn superviseManager(launch: *const claude_code.ManagerLaunch, gpa: std.mem.Allocator, stderr_fd: ?c_int, abort: *types.AbortSignal, ended: *claude_code.ManagerLaunch.Ended) void {
    ended.* = launch.run(gpa, stderr_fd, abort);
    if (!abort.isAborted()) abort.abort(.host_failure);
}

fn costOf(ended: claude_code.ManagerLaunch.Ended, allowance: f64) ledger_mod.Cost {
    const result = ended.result orelse return .{ .reserved = allowance };
    const usd = result.cost_usd orelse return .{ .reserved = allowance };
    return .{ .harness_reported = usd };
}

fn resultOf(launch: *const claude_code.ManagerLaunch, ended: claude_code.ManagerLaunch.Ended) runtime.SeatResult {
    switch (ended.stop) {
        .spawn_failed => return .{ .failed = .spawn_failed },
        .aborted => return .aborted,
        .timeout => return .{ .failed = .timed_out },
        .exited => {},
    }
    const code = launch.launch.childExitCode(ended.exit_code orelse 0);
    if (ended.result) |result| if (result.subtype == .error_max_budget_usd) return .budget_exhausted;
    if (code != 0) {
        if (code < 0) return .{ .failed = .{ .signaled = @intCast(-code) } };
        return .{ .failed = .{ .exited = @truncate(@as(u32, @bitCast(code))) } };
    }
    const result = ended.result orelse return .{ .failed = .spawn_failed };
    if (result.is_error or result.subtype != .success) return .{ .failed = .spawn_failed };
    return .finished;
}

const Channel = struct {
    input_path: [:0]const u8,
    output_path: [:0]const u8,
    input: pfs.Fd = pfs.invalid_fd,
    output: pfs.Fd = pfs.invalid_fd,

    fn open(arena: std.mem.Allocator, seat_dir: []const u8) !Channel {
        var self: Channel = .{
            .input_path = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ seat_dir, channel_in }, 0),
            .output_path = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ seat_dir, channel_out }, 0),
        };
        errdefer self.close();
        if (pfs.makeFifo(self.input_path.ptr, 0o600) != 0 or pfs.makeFifo(self.output_path.ptr, 0o600) != 0) return error.ChannelFailed;
        self.input = pfs.open(self.input_path.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true }, 0);
        if (self.input < 0) return error.ChannelFailed;
        self.output = pfs.open(self.output_path.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true }, 0);
        if (self.output < 0) return error.ChannelFailed;
        return self;
    }

    fn close(self: *Channel) void {
        if (self.input >= 0) pfs.close(self.input);
        if (self.output >= 0) pfs.close(self.output);
        self.input = pfs.invalid_fd;
        self.output = pfs.invalid_fd;
        pfs.unlinkPath(self.input_path.ptr) catch {};
        pfs.unlinkPath(self.output_path.ptr) catch {};
    }
};

fn mcpConfig(arena: std.mem.Allocator, run: *const runtime.Run, channel: *const Channel) ![]const u8 {
    const relay = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ run.dir.root, relay_file }, 0);
    try run_dir.writeAtomic(relay, relay_script);
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{ .mcpServers = .{ .teamwork = .{
        .type = "stdio",
        .command = "/bin/sh",
        .args = .{ relay, channel.input_path, channel.output_path },
    } } }, .{}, &out.writer);
    return out.written();
}
