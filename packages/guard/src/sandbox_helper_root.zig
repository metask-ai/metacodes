//! Private installed executable. Never run file requests in the agent process.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;
    @import("platform").signal.ignoreBrokenPipe();
    try @import("sandbox/filesystem_helper.zig").serve();
}
