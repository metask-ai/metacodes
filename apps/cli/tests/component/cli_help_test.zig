//! The CLI's help is data for the next command, so it must be written to
//! stdout. Keep this process-level check separate from parser tests: a
//! `--help` argument exits before the in-process test root can inspect it.

const std = @import("std");
const cc = @import("cc");

fn runCli(a: std.mem.Allocator, args: []const []const u8) !cc.tools_common.SpawnOut {
    const raw_path = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest;
    const path = try a.dupeZ(u8, std.mem.span(raw_path));

    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (argv.items) |item| if (item) |z| a.free(std.mem.span(z));
        argv.deinit(a);
    }
    try argv.append(a, path.ptr);
    for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    try argv.append(a, null);

    return cc.tools_common.spawnCaptureWithStderrTimed(
        argv.items,
        a,
        null,
        10_000,
        null,
        cc.tools_common.MAX_SPAWN_CAPTURE_BYTES,
        null,
    );
}

fn expectHelp(args: []const []const u8, marker: []const u8) !void {
    const a = std.testing.allocator;
    const result = try runCli(a, args);
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, marker) != null);
    try std.testing.expect(result.stderr.len == 0);
}

test "top-level help writes to stdout" {
    try expectHelp(&.{"--help"}, "metacodes — embeddable agent core and coding CLI");
    try expectHelp(&.{"-h"}, "metacodes — embeddable agent core and coding CLI");
}

test "top-level help wins over the arguments after it, and is found after others" {
    // argv[1] answered before the rest of startup: what follows it was never
    // parsed, so an unknown flag there is not an error.
    try expectHelp(&.{ "--help", "--no-such-flag" }, "metacodes — embeddable agent core and coding CLI");
    try expectHelp(&.{ "-h", "--no-such-flag" }, "metacodes — embeddable agent core and coding CLI");
    // In a later position the argument parser answers it, so an unknown flag
    // before it is still an error.
    try expectHelp(&.{ "--model", "help-test-model", "--help" }, "metacodes — embeddable agent core and coding CLI");
    const a = std.testing.allocator;
    const refused = try runCli(a, &.{ "--no-such-flag", "--help" });
    defer a.free(refused.stdout);
    defer a.free(refused.stderr);
    try std.testing.expectEqual(@as(i32, 2), refused.exit_code);
    try std.testing.expectEqual(@as(usize, 0), refused.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, refused.stderr, "unknown flag '--no-such-flag'") != null);
}

test "subcommand help writes to stdout" {
    const cases = [_]struct { command: []const u8, marker: []const u8 }{
        .{ .command = "login", .marker = "metacodes login" },
        .{ .command = "doctor", .marker = "usage: metacodes doctor" },
        .{ .command = "install", .marker = "usage: metacodes install" },
        .{ .command = "sealed", .marker = "usage: metacodes sealed" },
    };
    for (cases) |case| {
        try expectHelp(&.{ case.command, "--help" }, case.marker);
        try expectHelp(&.{ case.command, "-h" }, case.marker);
    }
}
