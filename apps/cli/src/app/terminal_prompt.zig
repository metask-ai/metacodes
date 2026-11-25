//! Reading answers at a terminal for the CLI's line-by-line prompts
//! (`metacodes login`, `metacodes mcp login`, `metacodes providers add`). The
//! prompts go to stderr, the answers come from stdin.

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("metacodes-internal").platform.fs;
const platform_term = @import("metacodes-internal").platform.terminal;
const auth = @import("metacodes-internal").core.auth;

/// Both ends a prompt needs are terminals: stdin to answer on, stderr to ask
/// on. Without them a command takes its answers as arguments instead.
pub fn interactive() bool {
    return platform_term.isatty(0) and platform_term.isatty(2);
}

/// One line from stdin, without its line end. A line longer than `buf` is
/// cut at its length.
pub fn readLine(buf: []u8) !usize {
    var len: usize = 0;
    while (len < buf.len) {
        var ch: [1]u8 = undefined;
        const n = pfs.read(0, ch[0..1]);
        if (n < 0) return error.InputFailed;
        if (n == 0) break;
        if (ch[0] == '\n' or ch[0] == '\r') break;
        buf[len] = ch[0];
        len += 1;
    }
    return len;
}

/// Read a line from the terminal without echo (raw mode, so Ctrl+C arrives as
/// a byte and is honoured). Bracketed-paste markers and other escape sequences
/// are skipped; a non-terminal stdin is read as a plain line.
/// Echo is off before the prompt is written: a paste that arrived between the
/// prompt and the mode switch would be echoed by the terminal itself.
pub fn readSecretLine(prompt: []const u8, buf: []u8) !usize {
    const saved = platform_term.enterRaw(0) orelse {
        std.debug.print("{s}", .{prompt});
        return readLine(buf);
    };
    defer platform_term.restoreMode(0, saved);
    std.debug.print("{s}", .{prompt});
    var len: usize = 0;
    var in_escape = false;
    while (true) {
        var ch: [1]u8 = undefined;
        const n = pfs.read(0, ch[0..1]);
        if (n < 0) return error.InputFailed;
        if (n == 0) break;
        const c = ch[0];
        if (in_escape) {
            // CSI ends on a byte in 0x40..0x7e ('~' for the paste markers).
            if (c >= 0x40 and c <= 0x7e and c != '[') in_escape = false;
            continue;
        }
        switch (c) {
            '\r', '\n' => break,
            0x03 => return error.Interrupted,
            0x1b => in_escape = true,
            0x7f, 0x08 => {
                if (len > 0) {
                    len -= 1;
                    buf[len] = 0;
                }
            },
            else => {
                if (c < 0x20) continue;
                if (len == buf.len) return error.KeyTooLong;
                buf[len] = c;
                len += 1;
            },
        }
    }
    return len;
}

pub const StdinPaste = struct {
    fd: c_int = 0,
    closed: bool = false,
    line: [4096]u8 = undefined,
    line_len: usize = 0,

    pub fn source(self: *StdinPaste) auth.PasteSource {
        return .{ .ctx = self, .take = take, .refused = refused, .prompt = auth.PASTE_PROMPT };
    }

    fn take(ctx: *anyopaque, out: []u8) ?[]const u8 {
        const self: *StdinPaste = @ptrCast(@alignCast(ctx));
        if (out.len == 0) return null;
        const room = @min(self.line.len, out.len);
        while (!self.closed and platform_term.waitReadable(self.fd, 0) > 0) {
            var byte: [1]u8 = undefined;
            const n = pfs.read(self.fd, &byte);
            if (n < 0) {
                self.closed = true;
                return null;
            }
            if (n == 0) {
                self.closed = !platform_term.isatty(self.fd);
                return if (self.line_len > 0) self.handOver(out) else null;
            }
            if (byte[0] == '\n' or byte[0] == '\r') {
                if (self.line_len > 0) return self.handOver(out);
                continue;
            }
            self.line[self.line_len] = byte[0];
            self.line_len += 1;
            if (self.line_len == room) return self.handOver(out);
        }
        return null;
    }

    fn handOver(self: *StdinPaste, out: []u8) []const u8 {
        const n = @min(self.line_len, out.len);
        @memcpy(out[0..n], self.line[0..n]);
        self.line_len = 0;
        return out[0..n];
    }

    fn refused(ctx: *anyopaque, why: auth.PasteRefusal) void {
        _ = ctx;
        std.debug.print("{s}\n", .{auth.pasteRefusalText(why)});
    }
};

pub fn waitText(buffer: []u8, ms: u64) []const u8 {
    const minute = std.time.ms_per_min;
    if (ms >= minute and ms % minute == 0) {
        const minutes = ms / minute;
        return std.fmt.bufPrint(buffer, "{d} minute{s}", .{ minutes, if (minutes == 1) "" else "s" }) catch "time";
    }
    if (ms % std.time.ms_per_s == 0) {
        const seconds = ms / std.time.ms_per_s;
        return std.fmt.bufPrint(buffer, "{d} second{s}", .{ seconds, if (seconds == 1) "" else "s" }) catch "time";
    }
    return std.fmt.bufPrint(buffer, "{d} ms", .{ms}) catch "time";
}

test "waitText names the login wait bound in the largest whole unit (#722)" {
    var buffer: [48]u8 = undefined;
    try std.testing.expectEqualStrings("10 minutes", waitText(&buffer, 10 * std.time.ms_per_min));
    try std.testing.expectEqualStrings("1 minute", waitText(&buffer, std.time.ms_per_min));
    try std.testing.expectEqualStrings("90 seconds", waitText(&buffer, 90 * std.time.ms_per_s));
    try std.testing.expectEqualStrings("1 second", waitText(&buffer, std.time.ms_per_s));
    try std.testing.expectEqualStrings("1500 ms", waitText(&buffer, 1500));
}

test "a line pasted through a pipe is handed over once it is whole, and half a line never blocks the wait (#738)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer pfs.close(fds[0]);
    var writer_open = true;
    defer if (writer_open) pfs.close(fds[1]);
    var paste: StdinPaste = .{ .fd = fds[0] };
    const source = paste.source();
    var out: [64]u8 = undefined;

    try std.testing.expect(source.take(source.ctx, &out) == null);
    try std.testing.expect(pfs.writeAll(fds[1], "http://localhost:1455/cb?code=c"));
    try std.testing.expect(source.take(source.ctx, &out) == null);
    try std.testing.expect(pfs.writeAll(fds[1], "1&state=s\r\n\nnext"));
    try std.testing.expectEqualStrings("http://localhost:1455/cb?code=c1&state=s", source.take(source.ctx, &out).?);
    try std.testing.expect(source.take(source.ctx, &out) == null);
    try std.testing.expect(pfs.writeAll(fds[1], "\n"));
    try std.testing.expectEqualStrings("next", source.take(source.ctx, &out).?);

    try std.testing.expect(pfs.writeAll(fds[1], "y" ** 70 ++ "\n"));
    try std.testing.expectEqualStrings("y" ** 64, source.take(source.ctx, &out).?);
    try std.testing.expectEqualStrings("y" ** 6, source.take(source.ctx, &out).?);
    try std.testing.expect(!paste.closed);

    try std.testing.expect(pfs.writeAll(fds[1], "tail"));
    pfs.close(fds[1]);
    writer_open = false;
    try std.testing.expectEqualStrings("tail", source.take(source.ctx, &out).?);
    try std.testing.expect(paste.closed);
    try std.testing.expect(source.take(source.ctx, &out) == null);
}
