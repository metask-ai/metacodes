const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .windows) return error.WindowsHostRequired;

    // Temporary compatibility for tests that still hard-code `/tmp/...`.
    // The Windows CRT resolves that spelling to `\tmp` on the current drive.
    // TODO: migrate those tests to std.testing.tmpDir/platform.paths.tempDir,
    // then delete this prelude instead of preserving the root-directory hack.
    try std.Io.Dir.cwd().createDirPath(init.io, "/tmp");
}
