//! L2 for #482: a run that finds no credential names, in its sign-in hint,
//! the command the user ran. The real CLI (`METACODES_TEST_CLI_BIN`) runs
//! with an empty state root and nothing else in its environment, started:
//! - by its own path: `metacodes login`;
//! - through a symlink named `metacodes-dev`: argv[0] says `metacodes-dev`;
//! - through the launcher `metacodes install` writes, named `metacodes-dev`
//!   (the reported case). It execs `…/bin/metacodes`, which is all argv[0]
//!   says, so only the `METACODES_LAUNCHER` it exports can name it;
//! - by its own path while `METACODES_LAUNCHER` names another install's
//!   launcher (inherited from that install's session): not believed.
//! No credential reaches the child, so every run stops at credential
//! resolution, before a provider request exists.

const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");

const testing = std.testing;

const Cli = struct {
    arena: std.mem.Allocator,
    state_root: []const u8,

    /// Runs `target args…` with METACODES_HOME at the empty state root and
    /// METACODES_LAUNCHER at `launcher_env` ("" is unset); returns stderr.
    fn run(self: Cli, target: []const u8, launcher_env: []const u8, args: []const []const u8) ![]const u8 {
        // capture hands a POSIX child an empty environment. The shell adds
        // the two variables and execs `target` by its path, which becomes
        // argv[0], as for a command a shell found on PATH.
        const script = "export METACODES_HOME=\"$1\" METACODES_LAUNCHER=\"$2\"; shift 2; exec \"$@\"";
        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        for ([_][]const u8{ "/bin/sh", "-c", script, "sh", self.state_root, launcher_env, target }) |arg|
            try argv.append(self.arena, (try self.arena.dupeZ(u8, arg)).ptr);
        for (args) |arg| try argv.append(self.arena, (try self.arena.dupeZ(u8, arg)).ptr);
        try argv.append(self.arena, null);
        const out = try cc.tools_common.spawnCaptureWithStderrTimed(
            argv.items,
            self.arena,
            null,
            30_000,
            null,
            cc.tools_common.MAX_SPAWN_CAPTURE_BYTES,
            null,
        );
        if (out.exit_code == 0) {
            std.debug.print("{s} exited 0 without a credential; stderr:\n{s}\n", .{ target, out.stderr });
            return error.TestUnexpectedResult;
        }
        return out.stderr;
    }
};

/// `stderr` holds the missing-credential hint, every sign-in line of which
/// runs `command`, the bare `login` first.
fn expectHint(a: std.mem.Allocator, stderr: []const u8, command: []const u8) !void {
    errdefer std.debug.print("expected the hint for `{s}`; stderr:\n{s}\n", .{ command, stderr });
    const head = try std.fmt.allocPrint(a, "Authentication required.\nUse one of:\n  {s} login\n  {s} login --oauth-token-json <token-response.json>\n", .{ command, command });
    try testing.expect(std.mem.indexOf(u8, stderr, head) != null);
    const login = try std.fmt.allocPrint(a, "  {s} login", .{command});
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, stderr, login));
    // No sign-in line names another command.
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  ") or std.mem.indexOf(u8, line, " login") == null) continue;
        try testing.expect(std.mem.startsWith(u8, line, login));
    }
}

test "a run without credentials names the command that was run in its sign-in hint (#482)" {
    // The launcher is a /bin/sh script; Windows writes a .cmd one.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const raw_cli = std.c.getenv("METACODES_TEST_CLI_BIN") orelse return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, root_buf[0..try tmp.dir.realPath(io, &root_buf)]);
    // Physical, as the installer writes it into a launcher.
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(io, std.mem.span(raw_cli), a);
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.createDirPath(io, "link");
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, "other/bin");
    const cli: Cli = .{ .arena = a, .state_root = try std.fs.path.join(a, &.{ root, "state" }) };

    try expectHint(a, try cli.run(exe, "", &.{}), "metacodes");

    try tmp.dir.symLink(io, exe, "link/metacodes-dev", .{});
    try expectHint(a, try cli.run(try std.fs.path.join(a, &.{ root, "link/metacodes-dev" }), "", &.{}), "metacodes-dev");

    try tmp.dir.writeFile(io, .{
        .sub_path = "bin/metacodes-dev",
        .data = try cc.app_install.launcherBody(a, exe),
        .flags = .{ .permissions = .executable_file },
    });
    const launcher = try std.fs.path.join(a, &.{ root, "bin/metacodes-dev" });
    try expectHint(a, try cli.run(launcher, "", &.{}), "metacodes-dev");
    // The Metask session message names it too.
    const metask = try cli.run(launcher, "", &.{ "--provider", "metask" });
    if (std.mem.indexOf(u8, metask, "run `metacodes-dev login --provider metask` to log in again") == null) {
        std.debug.print("expected the Metask session message for `metacodes-dev`; stderr:\n{s}\n", .{metask});
        return error.TestUnexpectedResult;
    }

    try tmp.dir.writeFile(io, .{ .sub_path = "other/bin/metacodes", .data = "another install" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "bin/metacodes-other",
        .data = try cc.app_install.launcherBody(a, try std.fs.path.join(a, &.{ root, "other/bin/metacodes" })),
        .flags = .{ .permissions = .executable_file },
    });
    try expectHint(a, try cli.run(exe, try std.fs.path.join(a, &.{ root, "bin/metacodes-other" }), &.{}), "metacodes");
}
