//! Whole-process sandbox boundary for external harnesses. The controller
//! stays on the host; this launch confines the harness and its descendants.
//! Unlike the interactive Bash escape hatch, an enabled worker sandbox
//! never falls back to a host launch or honors excludedCommands.

const std = @import("std");
const exec = @import("exec.zig");
const config = @import("config.zig");

pub const Options = struct {
    cwd: []const u8,
    home: []const u8 = "",
    sandbox: *const config.SandboxSettings,
    additional_dirs: []const []const u8 = &.{},
};

pub const Launch = union(enum) {
    confined: exec.WrappedCommand,
    /// Only a trusted caller's explicit sandbox.enabled=false selects this.
    host: []const []const u8,

    pub fn argv(self: *const Launch) []const []const u8 {
        return switch (self.*) {
            .confined => |wrapped| wrapped.argv,
            .host => |args| args,
        };
    }

    pub fn childExitCode(self: *const Launch, code: i32) i32 {
        return switch (self.*) {
            .confined => |wrapped| wrapped.childExitCode(code),
            .host => code,
        };
    }

    pub fn deinit(self: *Launch) void {
        switch (self.*) {
            .confined => |*wrapped| wrapped.deinit(),
            .host => {},
        }
    }
};

pub fn prepare(gpa: std.mem.Allocator, argv: []const []const u8, opts: Options) !Launch {
    if (argv.len == 0) return error.EmptyCommand;
    if (!opts.sandbox.enabled) return .{ .host = argv };

    var strict = opts.sandbox.*;
    strict.fail_if_unavailable = true;
    strict.allow_unsandboxed_commands = false;
    strict.excluded_commands = &.{};
    const command = try shellCommand(gpa, argv);
    defer gpa.free(command);
    return switch (try exec.wrapCommand(gpa, command, .{
        .cwd = opts.cwd,
        .home = opts.home,
        .sandbox = &strict,
        .additional_dirs = opts.additional_dirs,
    })) {
        .wrapped => |wrapped| .{ .confined = wrapped },
        .unavailable, .passthrough => error.SandboxUnavailable,
    };
}

/// No harness argv element is interpreted as shell syntax.
pub fn shellCommand(gpa: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var command: std.ArrayList(u8) = .empty;
    errdefer command.deinit(gpa);
    try command.appendSlice(gpa, "exec");
    for (argv) |arg| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.EmbeddedNullByte;
        try command.appendSlice(gpa, " '");
        for (arg) |c| {
            if (c == '\'') {
                try command.appendSlice(gpa, "'\\''");
            } else try command.append(gpa, c);
        }
        try command.append(gpa, '\'');
    }
    return command.toOwnedSlice(gpa);
}

test "worker sandbox quotes arguments without executing their shell syntax" {
    const command = try shellCommand(std.testing.allocator, &.{ "/opt/worker", "it's", "$(touch /nope)", "a\nb" });
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("exec '/opt/worker' 'it'\\''s' '$(touch /nope)' 'a\nb'", command);
    try std.testing.expectError(error.EmbeddedNullByte, shellCommand(std.testing.allocator, &.{"bad\x00arg"}));
}
