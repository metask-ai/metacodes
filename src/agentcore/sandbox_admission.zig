//! AgentCore-only admission probe for the macOS Seatbelt executor.
//! This deliberately does not change the shared CLI sandbox implementation.

const std = @import("std");
const pfs = @import("platform").fs;
const builtin = @import("builtin");

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
    if (builtin.os.tag != .macos) return .unsupported_os;
    const exists = pfs.exists(sandbox_exec);
    const executable = exists and std.c.access(sandbox_exec, std.c.X_OK) == 0;
    return classify(true, exists, executable);
}

/// Validate the complete cold admission path once per sandboxed Session:
/// executable discovery plus loading and executing a minimal Seatbelt profile.
pub fn validate(allocator: std.mem.Allocator) AdmissionError!void {
    switch (executableAvailability()) {
        .available => {},
        .unsupported_os => return error.UnsupportedOs,
        .missing => return error.MissingExecutable,
        .not_executable => return error.NotExecutable,
    }

    var io_runtime = std.Io.Threaded.init(allocator, .{});
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
    if (builtin.os.tag == .macos) {
        try validate(std.testing.allocator);
    } else {
        try std.testing.expectError(error.UnsupportedOs, validate(std.testing.allocator));
    }
}
