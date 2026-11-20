//! Reading answers at a terminal for the CLI's line-by-line prompts
//! (`metacodes login`, `metacodes providers add`). The prompts go to stderr,
//! the answers come from stdin.

const std = @import("std");
const pfs = @import("platform").fs;
const platform_term = @import("platform").terminal;

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
