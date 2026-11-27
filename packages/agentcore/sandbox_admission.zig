//! Eager platform sandbox admission for AgentCore Sessions.
//! This deliberately does not change the shared CLI sandbox implementation.

const std = @import("std");
const pfs = @import("platform").fs;
const builtin = @import("builtin");
const sandbox_backend = @import("core_imports.zig").sandbox_exec;

const sandbox_exec = "/usr/bin/sandbox-exec";
const true_exec = "/usr/bin/true";
const minimal_profile = "(version 1)\n(allow default)\n";

pub const Availability = enum {
    available,
    unsupported_os,
    missing,
    not_executable,
};

pub const AdmissionError = error{
    UnsupportedOs,
    MissingExecutable,
    NotExecutable,
    CanaryFailed,
    OutOfMemory,
};

fn classify(supported: bool, exists: bool, executable: bool) Availability {
    if (!supported) return .unsupported_os;
    if (!exists) return .missing;
    if (!executable) return .not_executable;
    return .available;
}

pub fn executableAvailability() Availability {
    if (builtin.os.tag == .linux) return if (sandbox_backend.hostSupported()) .available else .missing;
    if (builtin.os.tag != .macos) return .unsupported_os;
    const exists = pfs.exists(sandbox_exec);
    const executable = exists and std.c.access(sandbox_exec, std.c.X_OK) == 0;
    return classify(true, exists, executable);
}

/// Validate the complete cold admission path once per sandboxed Session:
/// executable discovery plus loading and executing a minimal Seatbelt profile.
pub fn validate(allocator: std.mem.Allocator) AdmissionError!void {
    if (builtin.os.tag == .linux) {
        if (!sandbox_backend.hostSupported()) return error.CanaryFailed;
        // Exercise the same fully confined launch as Bash and external
        // workers, not merely the existence of a bwrap executable.
        const settings: @import("core_imports.zig").sandbox_config.SandboxSettings = .{
            .enabled = true,
            .fail_if_unavailable = true,
            .allow_unsandboxed_commands = false,
        };
        const wrapped = sandbox_backend.wrapCommand(allocator, "true", .{
            .cwd = "/",
            .sandbox = &settings,
        }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.CanaryFailed;
        switch (wrapped) {
            .wrapped => |value| {
                var command = value;
                defer command.deinit();
                const argv = try allocator.alloc(?[*:0]const u8, command.argv.len + 1);
                defer allocator.free(argv);
                var count: usize = 0;
                defer for (argv[0..count]) |arg| allocator.free(std.mem.span(arg.?));
                for (command.argv, 0..) |arg, i| {
                    argv[i] = (try allocator.dupeZ(u8, arg)).ptr;
                    count += 1;
                }
                argv[command.argv.len] = null;
                const result = @import("platform").process.capture(argv, allocator, .{
                    .timeout_ms = 5000,
                    .max_bytes = 4096,
                }) catch return error.CanaryFailed;
                defer allocator.free(result.stdout);
                defer allocator.free(result.stderr);
                if (result.exit_code != 0) return error.CanaryFailed;
                return;
            },
            .unavailable, .passthrough => return error.CanaryFailed,
        }
    }
    switch (executableAvailability()) {
        .available => {},
        .unsupported_os => return error.UnsupportedOs,
        .missing => return error.MissingExecutable,
        .not_executable => return error.NotExecutable,
    }

    var io_runtime = @import("platform").signal.threadedIo(allocator, .{});
    defer io_runtime.deinit();
    const result = std.process.run(allocator, io_runtime.io(), .{
        .argv = &.{ sandbox_exec, "-p", minimal_profile, true_exec },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CanaryFailed,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.CanaryFailed;
}

test "availability classifier keeps unsupported missing and non-executable distinct" {
    try std.testing.expectEqual(Availability.unsupported_os, classify(false, true, true));
    try std.testing.expectEqual(Availability.missing, classify(true, false, false));
    try std.testing.expectEqual(Availability.not_executable, classify(true, true, false));
    try std.testing.expectEqual(Availability.available, classify(true, true, true));
}

test "sandbox admission matches the current platform" {
    if (builtin.os.tag == .macos or (builtin.os.tag == .linux and sandbox_backend.hostSupported())) {
        try validate(std.testing.allocator);
    } else if (builtin.os.tag == .linux) {
        try std.testing.expectError(error.CanaryFailed, validate(std.testing.allocator));
    } else {
        try std.testing.expectError(error.UnsupportedOs, validate(std.testing.allocator));
    }
}
