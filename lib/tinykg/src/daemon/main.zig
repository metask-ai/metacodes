const std = @import("std");
const builtin = @import("builtin");
const version = @import("../version.zig");
const protocol = @import("protocol.zig");
const store_actor = @import("store_actor.zig");

const Arguments = struct {
    store_path: []const u8,
    read_only: bool = false,
};

fn parseArguments(args: []const []const u8) !Arguments {
    var store_path: ?[]const u8 = null;
    var read_only = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--store")) {
            index += 1;
            if (index >= args.len or store_path != null) return error.InvalidArguments;
            store_path = args[index];
        } else if (std.mem.eql(u8, arg, "--read-only")) {
            if (read_only) return error.InvalidArguments;
            read_only = true;
        } else {
            return error.InvalidArguments;
        }
    }
    return .{ .store_path = store_path orelse return error.MissingStorePath, .read_only = read_only };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        var stdout_buffer: [128]u8 = undefined;
        var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
        try stdout_file_writer.interface.print("{s}\n", .{version.daemon_cli});
        try stdout_file_writer.interface.flush();
        return;
    }
    const parsed_args = parseArguments(args) catch |err| {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
        try stderr_file_writer.interface.print(
            "tinykgd: error: {s}; usage: tinykgd --store <path> [--read-only]\n",
            .{@errorName(err)},
        );
        try stderr_file_writer.interface.flush();
        std.process.exit(2);
    };

    const allocator = std.heap.smp_allocator;
    var actor = if (parsed_args.read_only)
        try store_actor.StoreActor.initReadOnly(allocator, init.io, parsed_args.store_path)
    else
        try store_actor.StoreActor.init(allocator, init.io, parsed_args.store_path);
    defer actor.deinit();

    const stdin_buffer = try allocator.alloc(u8, protocol.max_request_bytes + 1);
    defer allocator.free(stdin_buffer);
    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, stdin_buffer);
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var group_parsed: std.ArrayList(std.json.Parsed(protocol.Request)) = .empty;
    defer {
        for (group_parsed.items) |*parsed| parsed.deinit();
        group_parsed.deinit(allocator);
    }
    var group_requests: std.ArrayList(protocol.Request) = .empty;
    defer group_requests.deinit(allocator);
    while (true) {
        const maybe_line = stdin_reader.interface.takeDelimiter('\n') catch |err| {
            try protocol.writeProtocolError(stdout, "", actor.currentGeneration(), err);
            try stdout.flush();
            return;
        };
        var line = maybe_line orelse break;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(protocol.Request, allocator, line, .{
            .ignore_unknown_fields = false,
            .allocate = .alloc_always,
        }) catch |err| {
            try protocol.writeProtocolError(stdout, "", actor.currentGeneration(), err);
            try stdout.flush();
            continue;
        };

        // Group commit: batch the run of already-queued groupable writes so
        // the whole run shares one durability sync. Only input that is
        // immediately available joins the group; the loop never waits for
        // more work before acknowledging what it has.
        if (actor.groupableWrite(parsed.value)) {
            for (group_parsed.items) |*stale| stale.deinit();
            group_parsed.clearRetainingCapacity();
            group_requests.clearRetainingCapacity();
            try group_parsed.append(allocator, parsed);
            try group_requests.append(allocator, parsed.value);
            while (group_parsed.items.len < protocol.group_commit_max_requests and stdinHasBufferedLine(&stdin_reader.interface)) {
                const next_line_raw = stdin_reader.interface.takeDelimiter('\n') catch break;
                var next_line = next_line_raw orelse break;
                if (next_line.len > 0 and next_line[next_line.len - 1] == '\r') next_line = next_line[0 .. next_line.len - 1];
                if (next_line.len == 0) continue;
                var next_parsed = std.json.parseFromSlice(protocol.Request, allocator, next_line, .{
                    .ignore_unknown_fields = false,
                    .allocate = .alloc_always,
                }) catch |err| {
                    try protocol.writeProtocolError(stdout, "", actor.currentGeneration(), err);
                    try stdout.flush();
                    continue;
                };
                if (!actor.groupableWrite(next_parsed.value)) {
                    // flush the group first, then handle the stray request
                    try processGroupAndRespond(&actor, group_requests.items, stdout);
                    for (group_parsed.items) |*stale| stale.deinit();
                    group_parsed.clearRetainingCapacity();
                    group_requests.clearRetainingCapacity();
                    defer next_parsed.deinit();
                    respondSingle(&actor, next_parsed.value, stdout);
                    try stdout.flush();
                    break;
                }
                try group_parsed.append(allocator, next_parsed);
                try group_requests.append(allocator, next_parsed.value);
            }
            if (group_requests.items.len > 0) {
                try processGroupAndRespond(&actor, group_requests.items, stdout);
                for (group_parsed.items) |*stale| stale.deinit();
                group_parsed.clearRetainingCapacity();
                group_requests.clearRetainingCapacity();
            }
            // Self-heal after the failures are flushed: without this, a bare
            // NDJSON client with no web maintenance tick could wedge every
            // subsequent write behind unrepaired index debt.
            actor.maintenanceStepIfPending();
            continue;
        }

        defer parsed.deinit();
        respondSingle(&actor, parsed.value, stdout);
        try stdout.flush();
        actor.maintenanceStepIfPending();
    }
}

fn stdinHasBufferedLine(reader: *std.Io.Reader) bool {
    if (std.mem.indexOfScalar(u8, reader.buffered(), '\n') != null) return true;
    if (builtin.os.tag == .windows) return false;
    var fds = [_]std.c.pollfd{.{ .fd = 0, .events = std.c.POLL.IN, .revents = 0 }};
    const ready = std.c.poll(&fds, 1, 0);
    return ready > 0 and (fds[0].revents & std.c.POLL.IN) != 0;
}

fn respondSingle(actor: *store_actor.StoreActor, request: protocol.Request, stdout: *std.Io.Writer) void {
    const response = actor.process(request) catch |err| {
        protocol.writeProtocolError(stdout, request.requestId, actor.currentGeneration(), err) catch {};
        return;
    };
    protocol.writeResponse(stdout, response.*) catch {};
}

fn processGroupAndRespond(
    actor: *store_actor.StoreActor,
    requests: []const protocol.Request,
    stdout: *std.Io.Writer,
) !void {
    actor.processGroup(requests, stdout) catch |err| {
        for (requests) |request| {
            protocol.writeProtocolError(stdout, request.requestId, actor.currentGeneration(), err) catch {};
        }
        try stdout.flush();
        return;
    };
    try stdout.flush();
}

test "daemon executable requires one canonical Store" {
    try std.testing.expectError(error.MissingStorePath, parseArguments(&.{"tinykgd"}));
    try std.testing.expectEqualStrings(
        "memory.kg",
        (try parseArguments(&.{ "tinykgd", "--store", "memory.kg" })).store_path,
    );
}

// Backpressure is bounded by protocol.queue_capacity. The NDJSON reader is a
// single-thread StoreActor; it returns error.DaemonQueueFull instead of
// admitting unbounded generation-bound sessions.
