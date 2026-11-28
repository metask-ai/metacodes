const std = @import("std");
const builtin = @import("builtin");
const process = @import("metacodes-internal").platform.process;
const platform_thread = @import("metacodes-internal").platform.thread;
const CopyNotice = @import("ui_state.zig").CopyNotice;
const input = @import("../input.zig");
const TerminalEnv = @import("term.zig").TerminalEnv;
const mirror = @import("screen_mirror.zig");
const remote = @import("remote.zig");
const tui_config = @import("config.zig");
const RenderRegion = @import("render_region.zig").RenderRegion;

pub const cursor_query = "\x1b[6n";

pub const Outcome = union(enum) { not_mine, consumed, copied: CopyNotice };

pub const no_mouse_env = "METACODES_NO_MOUSE";

pub fn enable(gpa: std.mem.Allocator, state_root: []const u8, fd: c_int) void {
    const env = TerminalEnv.fromProcess();
    if (builtin.os.tag == .windows or env.insideGnuScreen() or !turnedOn(gpa, state_root)) return;
    input.recordMouseSelection(true);
    mirror.enable(fd);
    if (env.insideTmux()) askTmuxInBackground();
}

pub fn turnedOn(gpa: std.mem.Allocator, state_root: []const u8) bool {
    if (std.c.getenv(no_mouse_env) != null or state_root.len == 0) return false;
    return tui_config.loadMouse(gpa, state_root) orelse false;
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
            return .{ .copied = noticeFor(copyNative(gpa, text), g_tmux_clipboard.load(.acquire)) };
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

fn copyNative(gpa: std.mem.Allocator, text: []const u8) bool {
    if (builtin.os.tag != .macos or remote.session()) return false;
    const captured = process.capture(&.{ "/usr/bin/pbcopy", null }, gpa, .{
        .stdin_data = text,
        .timeout_ms = 2000,
        .inherit_env = true,
        .want_stderr = false,
    }) catch return false;
    gpa.free(captured.stdout);
    gpa.free(captured.stderr);
    return captured.exit_code == 0;
}

pub const TmuxClipboard = enum(u8) { unknown, passes_on, drops };

var g_tmux_clipboard = std.atomic.Value(TmuxClipboard).init(.unknown);

pub fn noticeFor(copied_natively: bool, tmux: TmuxClipboard) CopyNotice {
    if (copied_natively) return .system_clipboard;
    return if (tmux == .drops) .tmux_dropped else .terminal_clipboard;
}

pub fn tmuxClipboard(set_clipboard: []const u8) TmuxClipboard {
    const value = std.mem.trim(u8, set_clipboard, " \t\r\n");
    if (std.mem.eql(u8, value, "on")) return .passes_on;
    if (std.mem.eql(u8, value, "off") or std.mem.eql(u8, value, "external")) return .drops;
    return .unknown;
}

fn askTmuxInBackground() void {
    const thread = platform_thread.spawn(.waiter, askTmux, .{}) catch return;
    thread.detach();
}

fn askTmux() void {
    const gpa = std.heap.c_allocator;
    const captured = process.capture(&.{ "/usr/bin/env", "tmux", "show-options", "-sv", "set-clipboard", null }, gpa, .{
        .timeout_ms = 2000,
        .inherit_env = true,
        .want_stderr = false,
    }) catch return;
    defer gpa.free(captured.stdout);
    defer gpa.free(captured.stderr);
    if (captured.exit_code != 0) return;
    g_tmux_clipboard.store(tmuxClipboard(captured.stdout), .release);
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

test "the copy notice says where the text went: the system clipboard, the terminal, or a tmux that drops it" {
    try testing.expectEqual(CopyNotice.system_clipboard, noticeFor(true, .drops));
    try testing.expectEqual(CopyNotice.terminal_clipboard, noticeFor(false, .unknown));
    try testing.expectEqual(CopyNotice.terminal_clipboard, noticeFor(false, .passes_on));
    try testing.expectEqual(CopyNotice.tmux_dropped, noticeFor(false, .drops));
}

test "tmux's set-clipboard passes an application's OSC 52 on only when it is on; anything unreadable counts as passing" {
    try testing.expectEqual(TmuxClipboard.passes_on, tmuxClipboard("on\n"));
    try testing.expectEqual(TmuxClipboard.drops, tmuxClipboard("external\n"));
    try testing.expectEqual(TmuxClipboard.drops, tmuxClipboard("off"));
    try testing.expectEqual(TmuxClipboard.unknown, tmuxClipboard(""));
    try testing.expectEqual(TmuxClipboard.unknown, tmuxClipboard("invalid option: set-clipboard"));
    try testing.expectEqual(CopyNotice.terminal_clipboard, noticeFor(false, tmuxClipboard("")));
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

test "turnedOn: only config.json's \"mouse\": true turns drag-to-copy on, and METACODES_NO_MOUSE keeps it off even then" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const paths = @import("metacodes-internal").platform.paths;
    const previous = if (std.c.getenv(no_mouse_env)) |raw| try testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
    defer {
        if (previous) |value| {
            paths.setEnv(no_mouse_env, value.ptr);
            testing.allocator.free(value);
        } else paths.unsetEnv(no_mouse_env);
    }
    paths.unsetEnv(no_mouse_env);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state_root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];

    try testing.expect(!turnedOn(testing.allocator, state_root));
    for ([_][]const u8{ "{}", "{\"theme\": \"dark\"}", "{\"mouse\": false}", "{\"mouse\": \"on\"}", "{\"mouse\": 1}", "not json" }) |config| {
        errdefer std.debug.print("config.json={s}\n", .{config});
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = config });
        try testing.expect(!turnedOn(testing.allocator, state_root));
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = "{\"theme\": \"dark\", \"mouse\": true}" });
    try testing.expect(turnedOn(testing.allocator, state_root));
    try testing.expect(!turnedOn(testing.allocator, ""));
    for ([_][*:0]const u8{ "1", "0", "" }) |value| {
        errdefer std.debug.print("{s}={s}\n", .{ no_mouse_env, value });
        paths.setEnv(no_mouse_env, value);
        try testing.expect(!turnedOn(testing.allocator, state_root));
    }
}
