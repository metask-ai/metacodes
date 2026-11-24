const std = @import("std");
const builtin = @import("builtin");
const process = @import("platform").process;
const input = @import("../input.zig");
const mirror = @import("screen_mirror.zig");
const RenderRegion = @import("render_region.zig").RenderRegion;

pub const cursor_query = "\x1b[6n";

pub const Outcome = enum { not_mine, consumed, copied };

pub fn enable(on: bool, fd: c_int) void {
    if (!on or builtin.os.tag == .windows) return;
    input.recordMouseSelection(true);
    mirror.enable(fd);
}

pub const Drag = struct {
    anchor: mirror.Point,
    focus: mirror.Point,
    released: bool = false,
    cursor_row: ?u16 = null,

    pub const Step = union(enum) {
        none,
        ask_cursor,
        select: struct { anchor: mirror.Point, focus: mirror.Point, cursor_row: u16 },
    };

    pub fn onKey(drag: *?Drag, key: input.Key) ?Step {
        switch (key) {
            .mouse => |m| {
                if (m.wheel() != null or !m.leftButton()) return .none;
                const at: mirror.Point = .{ .row = @as(i32, m.row) - 1, .col = m.col -| 1 };
                if (m.released) {
                    const d = if (drag.*) |*d| d else return .none;
                    d.focus = at;
                    d.released = true;
                    return finish(drag);
                }
                if (m.motion()) {
                    if (drag.*) |*d| {
                        if (!d.released) d.focus = at;
                    }
                    return .none;
                }
                drag.* = .{ .anchor = at, .focus = at };
                return .ask_cursor;
            },
            .cursor_position => |p| {
                const d = if (drag.*) |*d| d else return .none;
                if (d.cursor_row != null) return .none;
                d.cursor_row = p.row -| 1;
                return finish(drag);
            },
            else => return null,
        }
    }

    fn finish(drag: *?Drag) Step {
        const d = drag.* orelse return .none;
        if (!d.released) return .none;
        const cursor_row = d.cursor_row orelse return .none;
        drag.* = null;
        if (std.meta.eql(d.anchor, d.focus)) return .none;
        return .{ .select = .{ .anchor = d.anchor, .focus = d.focus, .cursor_row = cursor_row } };
    }
};

var g_drag: ?Drag = null;

pub fn handle(gpa: std.mem.Allocator, region: *RenderRegion, key: input.Key) Outcome {
    if (!input.mouseSelectionOn()) return .not_mine;
    const step = Drag.onKey(&g_drag, key) orelse return .not_mine;
    switch (step) {
        .none => return .consumed,
        .ask_cursor => {
            region.emitTerminal(cursor_query);
            return .consumed;
        },
        .select => |s| {
            const text = (mirror.selectedText(gpa, s.anchor, s.focus, s.cursor_row) catch return .consumed) orelse return .consumed;
            defer gpa.free(text);
            if (text.len == 0) return .consumed;
            const osc = osc52(gpa, text) catch return .consumed;
            defer gpa.free(osc);
            region.emitTerminal(osc);
            copyNative(gpa, text);
            return .copied;
        },
    }
}

pub fn osc52(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const prefix = "\x1b]52;c;";
    const out = try gpa.alloc(u8, prefix.len + encoder.calcSize(text.len) + 1);
    @memcpy(out[0..prefix.len], prefix);
    _ = encoder.encode(out[prefix.len .. out.len - 1], text);
    out[out.len - 1] = 0x07;
    return out;
}

fn copyNative(gpa: std.mem.Allocator, text: []const u8) void {
    if (builtin.os.tag != .macos or remoteSession()) return;
    const captured = process.capture(&.{ "/usr/bin/pbcopy", null }, gpa, .{
        .stdin_data = text,
        .timeout_ms = 2000,
        .inherit_env = true,
        .want_stderr = false,
    }) catch return;
    gpa.free(captured.stdout);
    gpa.free(captured.stderr);
}

fn remoteSession() bool {
    for ([_][*:0]const u8{ "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY" }) |name| {
        if (std.c.getenv(name)) |value| {
            if (std.mem.span(value).len > 0) return true;
        }
    }
    return false;
}

const testing = std.testing;

fn press(row: u16, col: u16) input.Key {
    return .{ .mouse = .{ .code = 0, .col = col, .row = row, .released = false } };
}

fn motionTo(row: u16, col: u16) input.Key {
    return .{ .mouse = .{ .code = 32, .col = col, .row = row, .released = false } };
}

fn release(row: u16, col: u16) input.Key {
    return .{ .mouse = .{ .code = 0, .col = col, .row = row, .released = true } };
}

fn cursorAt(row: u16) input.Key {
    return .{ .cursor_position = .{ .row = row, .col = 1 } };
}

test "drag: press asks for the cursor, release with the answer selects anchor to focus" {
    var d: ?Drag = null;
    try testing.expectEqual(Drag.Step.ask_cursor, Drag.onKey(&d, press(3, 5)).?);
    try testing.expectEqual(Drag.Step.none, Drag.onKey(&d, motionTo(4, 2)).?);
    try testing.expectEqual(Drag.Step.none, Drag.onKey(&d, cursorAt(10)).?);
    const step = Drag.onKey(&d, release(5, 7)).?;
    try testing.expectEqual(@as(i32, 2), step.select.anchor.row);
    try testing.expectEqual(@as(u16, 4), step.select.anchor.col);
    try testing.expectEqual(@as(i32, 4), step.select.focus.row);
    try testing.expectEqual(@as(u16, 6), step.select.focus.col);
    try testing.expectEqual(@as(u16, 9), step.select.cursor_row);
    try testing.expect(d == null);
}

test "drag: an answer that arrives after the release still completes the copy" {
    var d: ?Drag = null;
    _ = Drag.onKey(&d, press(1, 1));
    try testing.expectEqual(Drag.Step.none, Drag.onKey(&d, release(1, 4)).?);
    try testing.expect(Drag.onKey(&d, cursorAt(2)).? == .select);
}

test "drag: a click, the wheel and other keys copy nothing" {
    var d: ?Drag = null;
    _ = Drag.onKey(&d, press(1, 1));
    _ = Drag.onKey(&d, cursorAt(2));
    try testing.expectEqual(Drag.Step.none, Drag.onKey(&d, release(1, 1)).?);
    try testing.expectEqual(Drag.Step.none, Drag.onKey(&d, .{ .mouse = .{ .code = 64, .col = 1, .row = 1, .released = false } }).?);
    try testing.expectEqual(Drag.Step.none, Drag.onKey(&d, cursorAt(2)).?);
    try testing.expect(Drag.onKey(&d, .{ .char = 'a' }) == null);
}

test "osc52: the text goes base64 encoded to the clipboard selection" {
    const seq = try osc52(testing.allocator, "hi");
    defer testing.allocator.free(seq);
    try testing.expectEqualStrings("\x1b]52;c;aGk=\x07", seq);
}
