//! Unknown CLI arguments and out-of-vocabulary flag VALUES must be rejected,
//! never silently ignored or silently defaulted.
//!
//! Harness review 2026-08-17 finding #1 (and re-review #3): the arg loop had
//! no terminal else, so `metacodes --definitely-not-a-real-flag --help`
//! exited 0, and value flags swallowed bad values (`--permission BOGUS`
//! silently landed in .default) — either way a paid evaluation arm degrades
//! to control while the launch contract records configured:true. The flag
//! surface is an external contract; skew must fail closed (声明=接线=测试).

const std = @import("std");
const cc = @import("cc");

fn parseErr(config: anytype, needle: []const u8) !void {
    try std.testing.expect(config.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, config.parse_error.?, needle) != null);
}

fn freeErr(a: std.mem.Allocator, config: anytype) void {
    if (config.parse_error) |e| a.free(e);
}

test "unknown --flag is rejected with a message naming it" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{ "metacodes", "--definitely-not-a-real-flag" };
    const config = cc.parseArgsForTest(&argv, a);
    defer freeErr(a, config);
    try parseErr(config, "unknown flag '--definitely-not-a-real-flag'");
}

test "unknown positional word is rejected too" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{ "metacodes", "strayword" };
    const config = cc.parseArgsForTest(&argv, a);
    defer freeErr(a, config);
    try parseErr(config, "unexpected positional argument 'strayword'");
}

test "parse stops at the first unknown argument" {
    const a = std.testing.allocator;
    // --verbose comes AFTER the bad flag: parsing must have stopped, so it
    // stays false and the recorded offender is the first unknown arg.
    const argv = [_][*:0]const u8{ "metacodes", "--bogus", "--verbose" };
    const config = cc.parseArgsForTest(&argv, a);
    defer freeErr(a, config);
    try parseErr(config, "'--bogus'");
    try std.testing.expect(!config.verbose);
}

test "--version parses cleanly and requests the version exit path" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{ "metacodes", "--version" };
    const config = cc.parseArgsForTest(&argv, a);
    defer freeErr(a, config);
    try std.testing.expect(config.parse_error == null);
    try std.testing.expect(config.show_version);
}

test "every known evaluation treatment flag still parses cleanly" {
    const a = std.testing.allocator;
    // The exact boolean flag set the WorkBuddy overlay passes
    // (metacodes_agent.py). A Zig-side rename fails here, not in a paid run.
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
    defer freeErr(a, config);
    try std.testing.expect(config.parse_error == null);
    try std.testing.expect(config.verification_final_gate);
    try std.testing.expect(config.requirement_ledger);
}

test "every overlay VALUE flag parses with a legitimate value" {
    const a = std.testing.allocator;
    // The value flags metacodes_agent.py emits: --model, --model-display-name,
    // --permission, --disallowed-tools, --max-tokens. Pins vocabulary AND
    // that the strict value parsing accepts the exact values the overlay sends.
    const argv = [_][*:0]const u8{
        "metacodes",
        "--model",
        "glm-5.2",
        "--model-display-name",
        "glm-5.2",
        "--permission",
        "bypassPermissions",
        "--disallowed-tools",
        "WebFetch,WebSearch",
        "--max-tokens",
        "32768",
    };
    const config = cc.parseArgsForTest(&argv, a);
    try std.testing.expect(config.parse_error == null);
    try std.testing.expectEqual(@as(?u32, 32768), config.max_tokens);
    try std.testing.expectEqual(cc.types_mod.PermissionMode.bypass_permissions, config.permission_mode);
    a.free(config.model);
    a.free(config.model_display_name.?);
    a.free(config.disallowed_tools.?);
}

test "out-of-vocabulary flag values fail closed" {
    const a = std.testing.allocator;
    const cases = [_]struct { argv: [3][*:0]const u8, needle: []const u8 }{
        .{ .argv = .{ "metacodes", "--permission", "TOTALLY-BOGUS" }, .needle = "invalid permission mode 'TOTALLY-BOGUS'" },
        .{ .argv = .{ "metacodes", "--max-tokens", "notanumber" }, .needle = "invalid value 'notanumber' for --max-tokens" },
        .{ .argv = .{ "metacodes", "--reasoning-effort", "bogus" }, .needle = "invalid value 'bogus'" },
        .{ .argv = .{ "metacodes", "--teammate-mode", "bogus" }, .needle = "invalid value 'bogus' for --teammate-mode" },
        .{ .argv = .{ "metacodes", "--temperature", "warm" }, .needle = "invalid value 'warm' for --temperature" },
        .{ .argv = .{ "metacodes", "--web", "70000" }, .needle = "invalid port '70000'" },
    };
    for (cases) |case| {
        const config = cc.parseArgsForTest(&case.argv, a);
        defer freeErr(a, config);
        try parseErr(config, case.needle);
    }
}

test "missing value for a value-required flag fails closed" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{ "metacodes", "--max-tokens" };
    const config = cc.parseArgsForTest(&argv, a);
    defer freeErr(a, config);
    try parseErr(config, "missing value for --max-tokens");
}

test "teammate-mode accepts its documented vocabulary" {
    const a = std.testing.allocator;
    const process_argv = [_][*:0]const u8{ "metacodes", "--teammate-mode", "process" };
    var config = cc.parseArgsForTest(&process_argv, a);
    try std.testing.expect(config.parse_error == null);
    try std.testing.expect(config.teammate_out_of_process);
    // "thread" is the in-process name documented in --help.
    const thread_argv = [_][*:0]const u8{ "metacodes", "--teammate-mode", "thread" };
    config = cc.parseArgsForTest(&thread_argv, a);
    try std.testing.expect(config.parse_error == null);
    try std.testing.expect(!config.teammate_out_of_process);
}

test "in-range optional web port still parses" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{ "metacodes", "--web", "8080" };
    const config = cc.parseArgsForTest(&argv, a);
    try std.testing.expect(config.parse_error == null);
    try std.testing.expectEqual(@as(?u16, 8080), config.web_port);
}

test "argv0 alone yields a clean default config" {
    const a = std.testing.allocator;
    const argv = [_][*:0]const u8{"metacodes"};
    const config = cc.parseArgsForTest(&argv, a);
    try std.testing.expect(config.parse_error == null);
}
