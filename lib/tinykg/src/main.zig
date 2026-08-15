const std = @import("std");
const tinykg = @import("tinykg.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const allocator = std.heap.smp_allocator;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    tinykg.cli.invoke(.{
        .argv = args,
        .environment = init.environ_map,
    }, stdout, allocator, init.io) catch |err| {
        // A command that fails after buffering output must not have that
        // partial result published by the error path.  In particular,
        // schema-reconcile flushes its success receipt inside the guarded
        // transaction; if that flush fails it rolls the catalog back before
        // returning here.  Retrying the stale stdout buffer would otherwise
        // acknowledge a mutation that no longer exists.
        stdout.end = 0;
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
        const stderr = &stderr_file_writer.interface;
        try stderr.print("tinykg: error: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    try stdout.flush();
}
