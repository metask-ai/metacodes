//! Turn-boundary background-job notifications.
//!
//! Only metadata is rendered here. Child output is arbitrary process input and
//! must remain behind BashOutput so it cannot be elevated to a user message.

const std = @import("std");
const util_time = @import("../util/time.zig");
const registry_mod = @import("job_registry.zig");
const JobExitEvent = registry_mod.JobExitEvent;

pub const TASK_NOTIFICATION_TAG = "task-notification";

pub fn render(allocator: std.mem.Allocator, events: []const JobExitEvent) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (events, 0..) |event, index| {
        var duration_buf: [32]u8 = undefined;
        if (index != 0) try out.writer.writeAll("\n\n");
        try out.writer.writeAll("<task-notification>\n<task-id>");
        try out.writer.writeAll(event.id[0..]);
        try out.writer.writeAll("</task-id>\n<status>");
        try out.writer.writeAll(if (event.status == .killed) "killed" else "exited");
        try out.writer.writeAll("</status>\n");
        if (event.exit_code) |code| try out.writer.print("<exit-code>{d}</exit-code>\n", .{code});
        try out.writer.writeAll("<summary>Background job `");
        try writeXmlEscaped(&out.writer, event.command_preview);
        try out.writer.print("` {s} after {s}. Unread output: stdout {d} bytes, stderr {d} bytes. Read it with BashOutput(job_id=\"{s}\"); do not re-run the command.</summary>\n</task-notification>", .{
            if (event.status == .killed) "was killed" else "exited",
            humanDuration(&duration_buf, event.started_ms, event.ended_ms),
            event.stdout_unread,
            event.stderr_unread,
            event.id[0..],
        });
    }
    return try out.toOwnedSlice();
}

fn writeXmlEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |byte, index| {
        const replacement: ?[]const u8 = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => null,
        };
        if (replacement) |escaped| {
            if (index > start) try writer.writeAll(text[start..index]);
            try writer.writeAll(escaped);
            start = index + 1;
        }
    }
    if (start < text.len) try writer.writeAll(text[start..]);
}

fn humanDuration(buffer: *[32]u8, started: util_time.Millis, ended: ?util_time.Millis) []const u8 {
    const elapsed: u64 = if (ended) |finish|
        @intCast(@max(finish - started, 0))
    else
        0;
    const seconds = elapsed / 1000;
    const hours = seconds / 3600;
    const minutes = (seconds % 3600) / 60;
    const secs = seconds % 60;
    if (hours > 0) return std.fmt.bufPrint(buffer, "{d}h{d:0>2}m", .{ hours, minutes }) catch "0s";
    if (minutes > 0) return std.fmt.bufPrint(buffer, "{d}m{d:0>2}s", .{ minutes, secs }) catch "0s";
    return std.fmt.bufPrint(buffer, "{d}s", .{secs}) catch "0s";
}

test "JobNotify renders one metadata-only event" {
    const a = std.testing.allocator;
    var event = JobExitEvent{
        .id = "6ab4f8e82fe4".*,
        .status = .exited,
        .exit_code = 0,
        .started_ms = 1000,
        .ended_ms = 253000,
        .command_preview = try a.dupe(u8, "python -c ..."),
        .stdout_unread = 354,
        .stderr_unread = 0,
    };
    defer event.deinit(a);
    const text = try render(a, &.{event});
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "<task-notification>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<exit-code>0</exit-code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "4m12s") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "354 bytes") != null);
}

test "JobNotify coalesces two events and escapes command preview" {
    const a = std.testing.allocator;
    var first = JobExitEvent{ .id = "000000000001".*, .status = .exited, .exit_code = 0, .started_ms = 0, .ended_ms = 1000, .command_preview = try a.dupe(u8, "echo <x> & y"), .stdout_unread = 0, .stderr_unread = 0 };
    var second = JobExitEvent{ .id = "000000000002".*, .status = .killed, .exit_code = null, .started_ms = 0, .ended_ms = 3661000, .command_preview = try a.dupe(u8, "sleep 30"), .stdout_unread = 1, .stderr_unread = 2 };
    defer first.deinit(a);
    defer second.deinit(a);
    const text = try render(a, &.{ first, second });
    defer a.free(text);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "<task-notification>"));
    try std.testing.expect(std.mem.indexOf(u8, text, "&lt;x&gt; &amp; y") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<status>killed</status>\n<summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1h01m") != null);
}

test "JobNotify never leaks output bytes or spool paths" {
    const a = std.testing.allocator;
    var event = JobExitEvent{ .id = "000000000003".*, .status = .exited, .exit_code = 0, .started_ms = 0, .ended_ms = 1000, .command_preview = try a.dupe(u8, "printf output"), .stdout_unread = 6, .stderr_unread = 0 };
    defer event.deinit(a);
    const text = try render(a, &.{event});
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/tmp/") == null);
}

test "JobNotify real job output never reaches the notification" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var jobs = try registry_mod.JobRegistry.init(a);
    defer jobs.deinit();
    const owner = @import("session_id.zig").gen();
    // Build the marker in the child so the command preview itself does not
    // contain the bytes whose accidental stdout promotion this test guards.
    const entry = try jobs.spawnBackgroundOwned("printf '\\123\\105\\103\\122\\105\\124\\137\\115\\101\\122\\113\\105\\122\\137\\130\\131\\132'", null, owner);
    const stdout_path = entry.stdout_path;
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        jobs.reapExited();
        if ((jobs.get(entry.idSlice()) orelse return error.JobNotFound).status != .running) break;
        util_time.sleepMs(10);
    }
    if ((jobs.get(entry.idSlice()) orelse return error.JobNotFound).status == .running) return error.JobDidNotExit;
    const events = try jobs.takeUnannouncedExits(owner, a);
    defer registry_mod.freeJobExitEvents(a, events);
    const text = try render(a, events);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "SECRET_MARKER_XYZ") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, stdout_path) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, entry.idSlice()) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "17 bytes") != null);
}
