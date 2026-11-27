const std = @import("std");
const platform_term = @import("metacodes-internal").platform.terminal;
const util_time = @import("metacodes-internal").util.time;
const input_mod = @import("../../input.zig");

pub const Timing = struct {
    quiet_ms: u32,
    paste_gap_ms: ?u32,

    pub const interactive: Timing = .{ .quiet_ms = 400, .paste_gap_ms = @intCast(input_mod.paste_burst_gap_ms) };
    pub const immediate: Timing = .{ .quiet_ms = 0, .paste_gap_ms = null };
};

pub const Gate = struct {
    timing: Timing,
    last_input_ns: ?util_time.Nanos = null,
    open: bool = false,

    pub fn init(timing: Timing) Gate {
        return .{ .timing = timing };
    }

    pub fn shown(self: *Gate, now_ns: util_time.Nanos) void {
        if (!self.open) self.last_input_ns = now_ns;
    }

    pub fn admits(self: *Gate, now_ns: util_time.Nanos) bool {
        if (!self.open) self.open = now_ns - (self.last_input_ns orelse now_ns) >= @as(util_time.Nanos, self.timing.quiet_ms) * std.time.ns_per_ms;
        self.last_input_ns = now_ns;
        return self.open;
    }

    pub fn close(self: *Gate, now_ns: util_time.Nanos) void {
        self.open = false;
        self.last_input_ns = now_ns;
    }

    pub fn pasteFollows(self: *const Gate, in_fd: c_int, parser: *const input_mod.KeyParser) bool {
        const gap_ms = self.timing.paste_gap_ms orelse return false;
        if (parser.queued_len > 0) return true;
        return platform_term.waitReadable(in_fd, @intCast(gap_ms)) > 0;
    }
};

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "answer gate: a key while the box opens or while typing goes on is not an answer, the first after a quiet spell is" {
    var gate = Gate.init(.interactive);
    gate.shown(1000 * ms);
    try testing.expect(!gate.admits(1000 * ms));
    try testing.expect(!gate.admits(1350 * ms));
    try testing.expect(!gate.admits(1700 * ms));
    try testing.expect(gate.admits(2100 * ms));
    try testing.expect(gate.admits(2150 * ms));
}

test "answer gate: closing it asks for another quiet spell, and a key refused meanwhile starts the spell again" {
    var gate = Gate.init(.interactive);
    gate.shown(0);
    try testing.expect(gate.admits(500 * ms));
    gate.close(600 * ms);
    try testing.expect(!gate.admits(900 * ms));
    try testing.expect(!gate.admits(1250 * ms));
    try testing.expect(gate.admits(1650 * ms));
}

test "answer gate: a key before the first frame is never an answer, and the quiet spell counts from the end of the frame" {
    var gate = Gate.init(.interactive);
    try testing.expect(!gate.admits(5000 * ms));
    gate.shown(6000 * ms);
    try testing.expect(!gate.admits(6010 * ms));
    gate.shown(6011 * ms);
    try testing.expect(gate.admits(6500 * ms));
}

test "answer gate: a frame drawn while the gate is closed starts its spell again, one drawn while it is open leaves it open" {
    var gate = Gate.init(.interactive);
    gate.shown(0);
    try testing.expect(!gate.admits(300 * ms));
    gate.shown(800 * ms);
    try testing.expect(!gate.admits(1000 * ms));
    gate.shown(1000 * ms);
    try testing.expect(gate.admits(1500 * ms));
    gate.shown(5000 * ms);
    try testing.expect(gate.admits(5000 * ms));
}

test "answer gate: the immediate timing admits every key and never waits for a paste" {
    var gate = Gate.init(.immediate);
    try testing.expect(gate.admits(0));
    gate.close(0);
    try testing.expect(gate.admits(0));
    var parser = input_mod.KeyParser{};
    try testing.expect(!gate.pasteFollows(-1, &parser));
}

test "answer gate: bytes already waiting, or arriving within the paste gap, are a paste; a key alone is not" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const gate = Gate.init(.interactive);
    var parser = input_mod.KeyParser{};
    try testing.expect(!gate.pasteFollows(fds[0], &parser));
    _ = std.c.write(fds[1], "y", 1);
    try testing.expect(gate.pasteFollows(fds[0], &parser));
}
