//! Unknown CLI arguments must be rejected, never silently ignored.
//!
//! Harness review 2026-08-17 finding #1: the arg loop had no terminal else,
//! so `metacodes --definitely-not-a-real-flag --help` exited 0 and a renamed
//! treatment flag (e.g. --verification-final-gate) would silently degrade a
//! paid evaluation arm to control while the launch contract still recorded
//! configured:true. The flag surface is an external contract; skew must fail
//! closed. These tests pin the rejection wiring (声明=接线=测试).

const std = @import("std");
const cc = @import("cc");

test "unknown --flag is recorded as parse_error, not ignored" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{ "metacodes", "--definitely-not-a-real-flag" };
    const config = cc.parseArgsForTest(&argv, a);
    try std.testing.expect(config.parse_error != null);
    try std.testing.expectEqualStrings("--definitely-not-a-real-flag", config.parse_error.?);
    a.free(config.parse_error.?);
}

test "unknown positional word is rejected too" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{ "metacodes", "strayword" };
    const config = cc.parseArgsForTest(&argv, a);
    try std.testing.expect(config.parse_error != null);
    try std.testing.expectEqualStrings("strayword", config.parse_error.?);
    a.free(config.parse_error.?);
}

test "parse stops at the first unknown argument" {
    const a = std.testing.allocator;
    // --verbose comes AFTER the bad flag: parsing must have stopped, so it
    // stays false and the recorded offender is the first unknown arg.
    const argv = [_][*:0]const u8{ "metacodes", "--bogus", "--verbose" };
    const config = cc.parseArgsForTest(&argv, a);
    try std.testing.expect(config.parse_error != null);
    try std.testing.expectEqualStrings("--bogus", config.parse_error.?);
    try std.testing.expect(!config.verbose);
    a.free(config.parse_error.?);
}

test "every known evaluation treatment flag still parses cleanly" {
    const a = std.testing.allocator;
    // The exact flag set the WorkBuddy overlay passes (metacodes_agent.py).
    // If any of these is renamed on the Zig side, this test fails before a
    // paid run can silently degrade.
    const argv = [_][*:0]const u8{
        "metacodes",
        "--verification-checkpoint",
        "--verification-final-gate",
        "--verification-final-observe",
        "--requirement-ledger",
        "--requirement-ledger-observe",
        "--no-theme",
    };
    const config = cc.parseArgsForTest(&argv, a);
    try std.testing.expect(config.parse_error == null);
    try std.testing.expect(config.verification_final_gate);
    try std.testing.expect(config.requirement_ledger);
}

test "argv0 alone yields a clean default config" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{"metacodes"};
    const config = cc.parseArgsForTest(&argv, a);
    try std.testing.expect(config.parse_error == null);
}
