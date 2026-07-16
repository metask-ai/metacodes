const std = @import("std");
const tinykg = @import("tinykg.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const allocator = std.heap.smp_allocator;
    tinykg.cli.setRuntimeEnvMap(init.environ_map);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    tinykg.cli.run(args, stdout, allocator, init.io) catch |err| {
        try stdout.flush();
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
        const stderr = &stderr_file_writer.interface;
        try stderr.print("tinykg: error: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    try stdout.flush();
}
