//! Plays the startup splash (`splash.zig`) on the controlling terminal.
//!
//! `decide` is the gate (pure, so every reason to stay quiet is testable);
//! `play` paces frames on the region below the cursor, lets any key jump to
//! the settled wordmark, and always ends with the cursor shown and SGR reset.
//! The key that skips is consumed: before the prompt exists there is nowhere
//! for it to go, and the input box's own raw-mode entry flushes type-ahead.

const std = @import("std");
const platform = @import("platform");
const platform_term = platform.terminal;
const pfs = platform.fs;
const splash = @import("splash.zig");
const term = @import("term.zig");
const theme = @import("theme.zig");
const util_time = @import("../../util/time.zig");

/// Set to any value to keep the splash off for this process.
pub const disable_env = "METACODES_NO_STARTUP_ANIMATION";

pub const Skip = enum { not_a_tty, disabled_by_env, disabled_by_config, dumb_terminal, too_small };

pub const Plan = struct { layout: splash.Layout, size: term.TermSize };

pub const Decision = union(enum) { play: Plan, skip: Skip };

pub const Gate = struct {
    stdin_tty: bool,
    stdout_tty: bool,
    env_disabled: bool,
    /// `startupAnimation` from config.json; null when unset.
    config: ?bool,
    term_dumb: bool,
    size: ?term.TermSize,
};

pub fn decide(g: Gate) Decision {
    // Both ends: frames go to stdout and the skip key comes from stdin.
    if (!g.stdin_tty or !g.stdout_tty) return .{ .skip = .not_a_tty };
    if (g.env_disabled) return .{ .skip = .disabled_by_env };
    if (g.config == false) return .{ .skip = .disabled_by_config };
    if (g.term_dumb) return .{ .skip = .dumb_terminal };
    const size = g.size orelse return .{ .skip = .too_small };
    const layout = splash.layoutFor(size.cols, size.rows) orelse return .{ .skip = .too_small };
    return .{ .play = .{ .layout = layout, .size = size } };
}

/// The gate as this process sees it. `config` comes from the caller, which
/// owns the state root.
pub fn gateFromEnv(config: ?bool) Gate {
    const term_env = std.c.getenv("TERM");
    return .{
        .stdin_tty = platform_term.isatty(0),
        .stdout_tty = platform_term.isatty(1),
        .env_disabled = std.c.getenv(disable_env) != null,
        .config = config,
        .term_dumb = if (term_env) |t| std.mem.eql(u8, std.mem.span(t), "dumb") else false,
        .size = term.getSize(1),
    };
}

/// Colour depth from the terminal, background from the resolved theme. An
/// explicit monochrome theme drops colour even on a colour terminal.
pub fn styleFor(variant: theme.Variant, cap: term.ColorCapability) splash.Style {
    const mode: splash.ColorMode = if (variant == .monochrome) .none else switch (cap) {
        .none => .none,
        .basic_16 => .basic_16,
        .extended_256 => .extended_256,
        .truecolor => .truecolor,
    };
    return .{ .mode = mode, .bg = if (variant == .light) .light else .dark };
}

pub const Outcome = enum {
    completed,
    skipped_by_key,
    /// The terminal changed size mid-play; the region's rows may have
    /// reflowed, so no settled frame is drawn over them.
    resized,
    /// stdin could not enter raw mode, so a key could not skip; nothing drawn.
    no_raw_mode,
    out_of_memory,
    write_failed,
};

pub fn play(gpa: std.mem.Allocator, plan: Plan, style: splash.Style, seed: u64) Outcome {
    const saved = platform_term.enterRaw(0) orelse return .no_raw_mode;
    defer platform_term.restoreMode(0, saved);

    var sp = splash.Splash.init(gpa, plan.layout, style, seed) catch return .out_of_memory;
    defer sp.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    const start = util_time.nowNs();
    var frames: u32 = 0;
    const outcome: Outcome = run: while (true) {
        const t = secondsSince(start);
        if (t >= splash.duration) break :run .completed;
        sp.advanceTo(t);
        sp.compose(t, frames);
        buf.clearRetainingCapacity();
        sp.writeFrame(gpa, &buf, if (frames == 0) .first else .next) catch break :run .out_of_memory;
        // Count the frame before writing: a short write may already have hidden the cursor.
        frames += 1;
        if (!writeAll(buf.items)) break :run .write_failed;
        if (!sameSize(plan.size)) break :run .resized;
        const deadline = start + @as(util_time.Nanos, frames) * splash.frame_ns;
        if (platform_term.waitReadable(0, msUntil(deadline)) > 0) {
            drainInput();
            break :run .skipped_by_key;
        }
    };

    if (frames > 0) {
        const settle = switch (outcome) {
            .completed, .skipped_by_key, .out_of_memory => true,
            .resized, .write_failed, .no_raw_mode => false,
        };
        var settled = false;
        if (settle) {
            sp.composeFinal();
            buf.clearRetainingCapacity();
            if (sp.writeFrame(gpa, &buf, .last)) |_| {
                settled = writeAll(buf.items);
            } else |_| {}
        }
        if (!settled) _ = writeAll("\x1b[0m\x1b[?2026l\x1b[?25h");
    }
    return outcome;
}

fn secondsSince(start: util_time.Nanos) f32 {
    const ns = util_time.nowNs() - start;
    return @as(f32, @floatFromInt(ns)) / std.time.ns_per_s;
}

fn msUntil(deadline: util_time.Nanos) i32 {
    const left = deadline - util_time.nowNs();
    if (left <= 0) return 0;
    return @intCast(@min(@divFloor(left + std.time.ns_per_ms - 1, std.time.ns_per_ms), 1000));
}

fn sameSize(size: term.TermSize) bool {
    const now = term.getSize(1) orelse return false;
    return now.cols == size.cols and now.rows == size.rows;
}

fn drainInput() void {
    var scratch: [64]u8 = undefined;
    var rounds: u8 = 0;
    while (rounds < 16 and platform_term.waitReadable(0, 0) > 0) : (rounds += 1) {
        if (platform_term.readInput(0, &scratch) <= 0) break;
    }
}

fn writeAll(bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        const n = pfs.write(1, rest);
        if (n < 0) {
            if (pfs.lastErrnoIs(.INTR)) continue;
            return false;
        }
        if (n == 0) return false;
        rest = rest[@intCast(n)..];
    }
    return true;
}

const testing = std.testing;

fn gate(overrides: anytype) Gate {
    var g: Gate = .{
        .stdin_tty = true,
        .stdout_tty = true,
        .env_disabled = false,
        .config = null,
        .term_dumb = false,
        .size = .{ .rows = 40, .cols = 120 },
    };
    inline for (std.meta.fields(@TypeOf(overrides))) |f| @field(g, f.name) = @field(overrides, f.name);
    return g;
}

test "decide: plays on an interactive terminal with nothing turning it off" {
    const d = decide(gate(.{}));
    try testing.expect(d == .play);
    try testing.expectEqual(@as(u16, 120), d.play.layout.cols);
    try testing.expectEqual(@as(u16, 120), d.play.size.cols);
    // Unset config means on; an explicit true also plays.
    try testing.expect(decide(gate(.{ .config = @as(?bool, true) })) == .play);
}

test "decide: each switch keeps it quiet, with its own reason" {
    try testing.expectEqual(Decision{ .skip = .not_a_tty }, decide(gate(.{ .stdin_tty = false })));
    try testing.expectEqual(Decision{ .skip = .not_a_tty }, decide(gate(.{ .stdout_tty = false })));
    try testing.expectEqual(Decision{ .skip = .disabled_by_env }, decide(gate(.{ .env_disabled = true })));
    try testing.expectEqual(Decision{ .skip = .disabled_by_config }, decide(gate(.{ .config = @as(?bool, false) })));
    try testing.expectEqual(Decision{ .skip = .dumb_terminal }, decide(gate(.{ .term_dumb = true })));
    try testing.expectEqual(Decision{ .skip = .too_small }, decide(gate(.{ .size = @as(?term.TermSize, null) })));
    try testing.expectEqual(Decision{ .skip = .too_small }, decide(gate(.{ .size = @as(?term.TermSize, .{ .rows = 40, .cols = 50 }) })));
    try testing.expectEqual(Decision{ .skip = .too_small }, decide(gate(.{ .size = @as(?term.TermSize, .{ .rows = 6, .cols = 120 }) })));
}

test "styleFor: monochrome theme drops colour, light theme flips the ramp" {
    try testing.expectEqual(splash.Style{ .mode = .none, .bg = .dark }, styleFor(.monochrome, .truecolor));
    try testing.expectEqual(splash.Style{ .mode = .truecolor, .bg = .light }, styleFor(.light, .truecolor));
    try testing.expectEqual(splash.Style{ .mode = .basic_16, .bg = .dark }, styleFor(.auto, .basic_16));
    try testing.expectEqual(splash.Style{ .mode = .none, .bg = .dark }, styleFor(.dark, .none));
}
