//! win32-input-mode (DECSET 9001) key records, turned back into VT bytes.
//!
//! With the mode on, a Windows console sends every key event as a record
//! `CSI Vk ; Sc ; Uc ; Kd ; Cs ; Rc _` (virtual key, scan code, the UTF-16
//! unit the key types, key down, control key state, repeat count), key-ups
//! included, where it sent the VT bytes the key types before. `Decoder` hands
//! on, for each key-down record, the bytes the same key sends with the mode
//! off (`keyBytes`), nothing for a key-up, and every byte that is no record as
//! it came. So whoever reads the console reads what it read without the mode,
//! except for the keys those bytes cannot tell apart: Shift+Enter.
//!
//! How the records arrive (Windows Terminal 1.24 through ConPTY and classic
//! conhost, Windows 11 26300, measured with a client of the console that
//! logged its input queue and reads): the console writes a key event's record
//! into the input queue at once, one queued event per character, so a record
//! a short read cut in two has its rest queued already. Bytes a terminal
//! writes to the pseudo console in one go (text, `ESC [ A`, the `ESC CR` of
//! VS Code's Shift+Enter binding) are queued as those characters, not as
//! records; a single control character it writes alone (CR, ESC, Ctrl+A) is
//! made a record, Ctrl+A with a Ctrl key record around it.

const std = @import("std");

pub const Decoder = struct {
    // A record read so far: ESC, `[`, digits and `;`. Whether it is one shows
    // at its `_`; any other byte ends it as the bytes it was.
    frame: [frame_capacity]u8 = undefined,
    frame_len: u8 = 0,
    // Handed out once, ahead of `press`: a frame that was no record, with the
    // byte that ended it, or the high half of a surrogate pair whose low half
    // never came.
    once: [once_capacity]u8 = undefined,
    once_pos: u8 = 0,
    once_len: u8 = 0,
    once_from_record: bool = false,
    // The bytes of the key a record pressed, handed out `press_left` times.
    press: [press_capacity]u8 = undefined,
    press_len: u8 = 0,
    press_pos: u8 = 0,
    press_left: u16 = 0,
    // A high surrogate waiting for the record with its low half (an emoji
    // comes as two key-down records).
    high_surrogate: u16 = 0,
    /// A key-down record typed a printable character: the host sends the
    /// keys it reads off the keyboard (Windows Terminal, classic conhost), so
    /// a record's modifier state is real and Shift+Enter is not Enter. A
    /// terminal that sends only VT bytes through ConPTY gets records for its
    /// lone control characters (CR, ESC, Ctrl+A), never for text.
    typed_text: bool = false,
    /// Whether the last byte `take` handed out came from a key record (a key
    /// pressed on the console) rather than as a byte the terminal wrote.
    last_from_record: bool = false,

    // ESC, `[`, six fields of at most five digits and five `;`.
    const frame_capacity = 40;
    const once_capacity = frame_capacity + 1;
    const press_capacity = key_bytes_max;
    const field_count = 6;
    /// How often one record repeats its key at most. A console counts the
    /// repeats of a held key that its reader has not read yet (measured: 1 in
    /// Windows Terminal, 2 in conhost); text that only looks like a record,
    /// pasted into a terminal, may say anything up to 2^32.
    pub const max_repeat = 256;

    /// Whether `take` has bytes to hand out. `put` takes the next byte only
    /// once it has none.
    pub fn holding(self: *const Decoder) bool {
        return self.once_pos < self.once_len or self.press_left > 0;
    }

    /// Whether part of a record has been read and the rest is still to come.
    pub fn framing(self: *const Decoder) bool {
        return self.frame_len > 0;
    }

    /// One byte as the console sent it.
    pub fn put(self: *Decoder, b: u8) void {
        std.debug.assert(!self.holding());
        if (self.frame_len == 0) return self.start(b);
        if (self.frame_len == 1) {
            if (b == '[') {
                self.frame[1] = b;
                self.frame_len = 2;
                return;
            }
        } else if (((b >= '0' and b <= '9') or b == ';') and self.frame_len < frame_capacity) {
            self.frame[self.frame_len] = b;
            self.frame_len += 1;
            return;
        } else if (b == '_' and self.record(self.frame[2..self.frame_len])) {
            self.frame_len = 0;
            return;
        }
        // No record: what was read of it goes on as it came, and `b` starts
        // over (an ESC may begin the next record).
        self.holdRaw(self.frame[0..self.frame_len]);
        self.frame_len = 0;
        self.start(b);
    }

    /// Nothing more is queued: a record is never cut there (the console
    /// queues all of it at once), so the frame read so far is the bytes it was.
    pub fn endOfInput(self: *Decoder) void {
        if (self.frame_len == 0) return;
        std.debug.assert(!self.holding());
        self.holdRaw(self.frame[0..self.frame_len]);
        self.frame_len = 0;
    }

    /// Hand out as many decoded bytes as fit in `out`; returns how many.
    pub fn take(self: *Decoder, out: []u8) usize {
        var n: usize = 0;
        while (n < out.len) {
            if (self.once_pos < self.once_len) {
                out[n] = self.once[self.once_pos];
                self.once_pos += 1;
                self.last_from_record = self.once_from_record;
            } else if (self.press_left > 0) {
                out[n] = self.press[self.press_pos];
                self.press_pos += 1;
                if (self.press_pos == self.press_len) {
                    self.press_pos = 0;
                    self.press_left -= 1;
                }
                self.last_from_record = true;
            } else break;
            n += 1;
        }
        if (self.once_pos == self.once_len) {
            self.once_pos = 0;
            self.once_len = 0;
        }
        return n;
    }

    /// Drop what has been read and not handed out. What the host was found
    /// to be (`typed_text`) stays.
    pub fn reset(self: *Decoder) void {
        self.* = .{ .typed_text = self.typed_text };
    }

    fn start(self: *Decoder, b: u8) void {
        if (b == 0x1b) {
            self.frame[0] = b;
            self.frame_len = 1;
        } else self.holdRaw(&.{b});
    }

    fn holdRaw(self: *Decoder, bytes: []const u8) void {
        @memcpy(self.once[self.once_len..][0..bytes.len], bytes);
        self.once_len += @intCast(bytes.len);
        self.once_from_record = false;
    }

    /// A record's fields (`Vk;Sc;Uc;Kd;Cs;Rc`; an empty or left-out field is
    /// 0, Rc 1). More than six fields make no record (false). A key-up is no
    /// key. A key-down's key bytes are handed out Rc times, at most
    /// `max_repeat`; a key that types nothing is never repeated.
    fn record(self: *Decoder, text: []const u8) bool {
        var field = [field_count]u32{ 0, 0, 0, 0, 0, 1 };
        var i: usize = 0;
        var empty = true;
        for (text) |c| {
            if (c == ';') {
                i += 1;
                if (i == field_count) return false;
                empty = true;
                continue;
            }
            if (empty) field[i] = 0;
            empty = false;
            field[i] = field[i] *| 10 +| (c - '0');
        }
        if (field[3] == 0) return true; // key-up
        const vk = field[0];
        const unit = field[2];
        const cs = field[4];
        if (unit >= 0x20 and unit != 0x7f) self.typed_text = true;
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            self.holdHighSurrogate();
            self.high_surrogate = @intCast(unit);
            return true;
        }
        var cp: u21 = @intCast(@min(unit, 0x10FFFF));
        if (unit >= 0xDC00 and unit <= 0xDFFF and self.high_surrogate != 0) {
            cp = 0x10000 + ((@as(u21, self.high_surrogate) - 0xD800) << 10) + (cp - 0xDC00);
            self.high_surrogate = 0;
        } else self.holdHighSurrogate();
        var key: [key_bytes_max]u8 = undefined;
        const bytes = keyBytes(vk, cp, cs, &key);
        if (bytes.len == 0) return true;
        @memcpy(self.press[0..bytes.len], bytes);
        self.press_len = @intCast(bytes.len);
        self.press_pos = 0;
        self.press_left = @intCast(std.math.clamp(field[5], 1, max_repeat));
        return true;
    }

    /// A high surrogate whose low half did not come next goes on as WTF-8,
    /// as platform/terminal.zig hands on a lone half the console reads.
    fn holdHighSurrogate(self: *Decoder) void {
        if (self.high_surrogate == 0) return;
        const n = std.unicode.wtf8Encode(self.high_surrogate, self.once[self.once_len..]) catch 0;
        self.once_len += @intCast(n);
        self.once_from_record = true;
        self.high_surrogate = 0;
    }
};

const key_bytes_max = 12;

/// The VT bytes a Windows console sends without win32-input-mode for one press
/// of the key a key-down record names (virtual key `vk`, character `cp`,
/// control key state `cs`). Measured key by key against Windows Terminal 1.24
/// and classic conhost (Windows 11 26300): Backspace is 0x7f and
/// Ctrl+Backspace 0x08, Shift+Tab `ESC[Z`, Alt adds an ESC in front (not for
/// AltGr, Ctrl+Alt with a printable character), arrows and Home/End `ESC[X`,
/// with modifiers `ESC[1;mX`, F1-F4 `ESC O X`, the other function and editing
/// keys `ESC[n~`, with modifiers `ESC[n;m~` (m = 1 + Shift + 2·Alt + 4·Ctrl),
/// Ctrl+Alt+letter (the record has no character) ESC and the control byte.
/// Shift+Enter, which those bytes cannot tell from Enter, is Kitty's
/// `CSI 13;2u`, the key a terminal with the Kitty protocol on sends.
/// Ctrl+Enter stays `\n`: ConPTY makes a line break written to the pseudo
/// console an Enter with Ctrl held (Uc 10), the same record. A modifier alone,
/// Pause, Apps and other keys that type nothing: no bytes.
pub fn keyBytes(vk: u32, cp: u21, cs: u32, out: *[key_bytes_max]u8) []const u8 {
    const shift = cs & 0x10 != 0; // SHIFT_PRESSED
    const alt = cs & 0x03 != 0; // RIGHT_ALT_PRESSED | LEFT_ALT_PRESSED
    const ctrl = cs & 0x0c != 0; // RIGHT_CTRL_PRESSED | LEFT_CTRL_PRESSED
    const mod: u8 = 1 + @as(u8, @intFromBool(shift)) + 2 * @as(u8, @intFromBool(alt)) + 4 * @as(u8, @intFromBool(ctrl));
    if (vk == 0x0d and mod == 2) return "\x1b[13;2u"; // VK_RETURN
    if (cp != 0) {
        if (vk == 0x09 and shift) return "\x1b[Z"; // VK_TAB
        const c: u21 = if (vk == 0x08) switch (cp) { // VK_BACK
            0x08 => 0x7f,
            0x7f => 0x08,
            else => cp,
        } else cp;
        var n: usize = 0;
        if (alt and !(ctrl and c >= 0x20)) {
            out[0] = 0x1b;
            n = 1;
        }
        n += std.unicode.wtf8Encode(c, out[n..]) catch return out[0..0];
        return out[0..n];
    }
    if (ctrl and vk >= 'A' and vk <= 'Z') {
        var n: usize = 0;
        if (alt) {
            out[0] = 0x1b;
            n = 1;
        }
        out[n] = @intCast(vk - 0x40);
        return out[0 .. n + 1];
    }
    const csi_final: ?u8 = switch (vk) {
        0x25 => 'D', // VK_LEFT
        0x26 => 'A', // VK_UP
        0x27 => 'C', // VK_RIGHT
        0x28 => 'B', // VK_DOWN
        0x24 => 'H', // VK_HOME
        0x23 => 'F', // VK_END
        else => null,
    };
    if (csi_final) |f| return if (mod == 1)
        std.fmt.bufPrint(out, "\x1b[{c}", .{f}) catch unreachable
    else
        std.fmt.bufPrint(out, "\x1b[1;{d}{c}", .{ mod, f }) catch unreachable;
    const ss3_final: ?u8 = switch (vk) {
        0x70 => 'P', // VK_F1
        0x71 => 'Q',
        0x72 => 'R',
        0x73 => 'S', // VK_F4
        else => null,
    };
    if (ss3_final) |f| return if (mod == 1)
        std.fmt.bufPrint(out, "\x1bO{c}", .{f}) catch unreachable
    else
        std.fmt.bufPrint(out, "\x1b[1;{d}{c}", .{ mod, f }) catch unreachable;
    const tilde: ?u8 = switch (vk) {
        0x2d => 2, // VK_INSERT
        0x2e => 3, // VK_DELETE
        0x21 => 5, // VK_PRIOR
        0x22 => 6, // VK_NEXT
        0x74 => 15, // VK_F5
        0x75 => 17,
        0x76 => 18,
        0x77 => 19,
        0x78 => 20,
        0x79 => 21,
        0x7a => 23,
        0x7b => 24, // VK_F12
        else => null,
    };
    if (tilde) |t| return if (mod == 1)
        std.fmt.bufPrint(out, "\x1b[{d}~", .{t}) catch unreachable
    else
        std.fmt.bufPrint(out, "\x1b[{d};{d}~", .{ t, mod }) catch unreachable;
    return out[0..0];
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Every byte of `stream` through `d`, then the end of input; what came out.
fn decodeAll(d: *Decoder, stream: []const u8, out: []u8) []u8 {
    var n: usize = 0;
    for (stream) |b| {
        n += d.take(out[n..]);
        d.put(b);
    }
    n += d.take(out[n..]);
    d.endOfInput();
    n += d.take(out[n..]);
    return out[0..n];
}

fn decode(stream: []const u8, out: []u8) []u8 {
    var d: Decoder = .{};
    return decodeAll(&d, stream, out);
}

/// Records as Windows Terminal 1.24 and classic conhost send them with
/// win32-input-mode on (Windows 11 26300), each with the VT bytes the same key
/// sent with it off. A key's modifier records (Shift, Ctrl, Alt down and up)
/// come along, as they do on the wire.
const measured = [_]struct { name: []const u8, records: []const u8, vt: []const u8 }{
    .{ .name = "a", .records = "\x1b[65;30;97;1;32;1_\x1b[65;30;97;0;32;1_", .vt = "a" },
    .{ .name = "Shift+A", .records = "\x1b[16;42;0;1;48;1_\x1b[65;30;65;1;48;1_\x1b[65;30;65;0;48;1_\x1b[16;42;0;0;32;1_", .vt = "A" },
    .{ .name = "Enter", .records = "\x1b[13;28;13;1;32;1_\x1b[13;28;13;0;32;1_", .vt = "\r" },
    .{ .name = "Ctrl+Enter", .records = "\x1b[17;29;0;1;40;1_\x1b[13;28;10;1;40;1_\x1b[13;28;10;0;40;1_\x1b[17;29;0;0;32;1_", .vt = "\n" },
    .{ .name = "Backspace", .records = "\x1b[8;14;8;1;32;1_\x1b[8;14;8;0;32;1_", .vt = "\x7f" },
    .{ .name = "Ctrl+Backspace", .records = "\x1b[17;29;0;1;40;1_\x1b[8;14;127;1;40;1_\x1b[8;14;127;0;40;1_\x1b[17;29;0;0;32;1_", .vt = "\x08" },
    .{ .name = "Alt+Backspace", .records = "\x1b[18;56;0;1;34;1_\x1b[8;14;8;1;34;1_\x1b[8;14;8;0;34;1_\x1b[18;56;0;0;32;1_", .vt = "\x1b\x7f" },
    .{ .name = "Tab", .records = "\x1b[9;15;9;1;32;1_\x1b[9;15;9;0;32;1_", .vt = "\t" },
    .{ .name = "Shift+Tab", .records = "\x1b[16;42;0;1;48;1_\x1b[9;15;9;1;48;1_\x1b[9;15;9;0;48;1_\x1b[16;42;0;0;32;1_", .vt = "\x1b[Z" },
    .{ .name = "Esc", .records = "\x1b[27;1;27;1;32;1_\x1b[27;1;27;0;32;1_", .vt = "\x1b" },
    .{ .name = "Space", .records = "\x1b[32;57;32;1;32;1_\x1b[32;57;32;0;32;1_", .vt = " " },
    .{ .name = "Ctrl+Space", .records = "\x1b[17;29;0;1;40;1_\x1b[17;29;0;0;32;1_", .vt = "" },
    .{ .name = "Left", .records = "\x1b[37;75;0;1;288;1_\x1b[37;75;0;0;288;1_", .vt = "\x1b[D" },
    .{ .name = "Up", .records = "\x1b[38;72;0;1;288;1_", .vt = "\x1b[A" },
    .{ .name = "Right", .records = "\x1b[39;77;0;1;288;1_", .vt = "\x1b[C" },
    .{ .name = "Down", .records = "\x1b[40;80;0;1;288;1_", .vt = "\x1b[B" },
    .{ .name = "Shift+Left", .records = "\x1b[16;42;0;1;48;1_\x1b[37;75;0;1;304;1_", .vt = "\x1b[1;2D" },
    .{ .name = "Ctrl+Left", .records = "\x1b[17;29;0;1;40;1_\x1b[37;75;0;1;296;1_", .vt = "\x1b[1;5D" },
    .{ .name = "Alt+Left", .records = "\x1b[18;56;0;1;34;1_\x1b[37;75;0;1;290;1_", .vt = "\x1b[1;3D" },
    .{ .name = "Ctrl+Shift+Right", .records = "\x1b[39;77;0;1;312;1_", .vt = "\x1b[1;6C" },
    .{ .name = "Home", .records = "\x1b[36;71;0;1;288;1_", .vt = "\x1b[H" },
    .{ .name = "End", .records = "\x1b[35;79;0;1;288;1_", .vt = "\x1b[F" },
    .{ .name = "Shift+Home", .records = "\x1b[36;71;0;1;304;1_", .vt = "\x1b[1;2H" },
    .{ .name = "Insert", .records = "\x1b[45;82;0;1;288;1_", .vt = "\x1b[2~" },
    .{ .name = "Delete", .records = "\x1b[46;83;0;1;288;1_", .vt = "\x1b[3~" },
    .{ .name = "Shift+Delete", .records = "\x1b[46;83;0;1;304;1_", .vt = "\x1b[3;2~" },
    .{ .name = "Ctrl+Delete", .records = "\x1b[46;83;0;1;296;1_", .vt = "\x1b[3;5~" },
    .{ .name = "PgUp", .records = "\x1b[33;73;0;1;288;1_", .vt = "\x1b[5~" },
    .{ .name = "PgDn", .records = "\x1b[34;81;0;1;288;1_", .vt = "\x1b[6~" },
    .{ .name = "F1", .records = "\x1b[112;59;0;1;32;1_", .vt = "\x1bOP" },
    .{ .name = "Ctrl+F1", .records = "\x1b[112;59;0;1;40;1_", .vt = "\x1b[1;5P" },
    .{ .name = "F5", .records = "\x1b[116;63;0;1;32;1_", .vt = "\x1b[15~" },
    .{ .name = "Shift+F5", .records = "\x1b[116;63;0;1;48;1_", .vt = "\x1b[15;2~" },
    .{ .name = "F12", .records = "\x1b[123;88;0;1;32;1_", .vt = "\x1b[24~" },
    .{ .name = "Ctrl+A", .records = "\x1b[17;29;0;1;40;1_\x1b[65;30;1;1;40;1_", .vt = "\x01" },
    .{ .name = "Ctrl+C", .records = "\x1b[17;29;0;1;40;1_\x1b[67;46;3;1;40;1_\x1b[67;46;3;0;40;1_\x1b[17;29;0;0;32;1_", .vt = "\x03" },
    .{ .name = "Ctrl+D", .records = "\x1b[68;32;4;1;40;1_", .vt = "\x04" },
    .{ .name = "Ctrl+Z", .records = "\x1b[90;44;26;1;40;1_", .vt = "\x1a" },
    .{ .name = "Ctrl+Alt+A", .records = "\x1b[65;30;0;1;42;1_", .vt = "\x1b\x01" },
    .{ .name = "Alt+B", .records = "\x1b[18;56;0;1;34;1_\x1b[66;48;98;1;34;1_", .vt = "\x1bb" },
    .{ .name = "Alt+F", .records = "\x1b[70;33;102;1;34;1_", .vt = "\x1bf" },
    .{ .name = "IME commit", .records = "\x1b[0;0;20320;1;32;1_", .vt = "你" },
    .{ .name = "VK_PACKET text", .records = "\x1b[255;0;20013;1;32;1_\x1b[255;0;25991;1;32;1_", .vt = "中文" },
    .{ .name = "emoji", .records = "\x1b[255;0;55357;1;32;1_\x1b[255;0;56832;1;32;1_", .vt = "😀" },
    .{ .name = "Pause", .records = "\x1b[19;69;0;1;32;1_\x1b[19;69;0;0;32;1_", .vt = "" },
};

test "a win32-input-mode record decodes to the VT bytes its key sends without the mode, for every key measured" {
    for (measured) |m| {
        errdefer std.debug.print("win32 record and VT bytes part ways: {s}\n", .{m.name});
        var out: [64]u8 = undefined;
        try testing.expectEqualStrings(m.vt, decode(m.records, &out));
    }
}

test "Shift+Enter decodes to Kitty's CSI 13;2u; Enter, Ctrl+Enter and Alt+Enter keep their VT bytes" {
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings("\x1b[13;2u", decode("\x1b[16;42;0;1;48;1_\x1b[13;28;13;1;48;1_\x1b[13;28;13;0;48;1_\x1b[16;42;0;0;32;1_", &out));
    // Right Shift and the numpad Enter carry the same state.
    try testing.expectEqualStrings("\x1b[13;2u", decode("\x1b[13;28;13;1;304;1_", &out));
    try testing.expectEqualStrings("\r", decode("\x1b[13;28;13;1;0;1_", &out));
    // A line break written to the pseudo console (a paste) comes back with
    // LEFT_CTRL_PRESSED and Uc 10, the record a real Ctrl+Enter gives.
    try testing.expectEqualStrings("\x1b[200~a\nb\x1b[201~", decode("\x1b[200~a\x1b[13;28;10;1;8;1_\x1b[13;28;10;0;8;1_b\x1b[201~", &out));
    try testing.expectEqualStrings("\x1b\r", decode("\x1b[13;28;13;1;2;1_\x1b[13;28;13;0;2;1_", &out));
}

test "bytes that are no record go on as they came, VS Code's ESC CR among them" {
    var out: [64]u8 = undefined;
    for ([_][]const u8{
        "a\x1b\rb", // ESC CR written to the pseudo console in one go
        "\x1b[A\x1b[1;5D\x1b[13;2u", // VT keys and CSI u
        "\x1b[200~text\x1b[201~", // a Windows Terminal paste
        "\x1b]11;rgb:1e1e/1e1e/2e2e\x07", // an OSC answer
        "\x1b[65;0;97;1;32;1;9_x", // a seventh field
        "\x1b[" ++ "1" ** 40 ++ "_", // longer than any record
        "\x1b\x1b[65;30", // a frame the end of input cuts: its bytes
        "中文😀",
    }) |raw| {
        errdefer std.debug.print("changed: {any}\n", .{raw});
        try testing.expectEqualStrings(raw, decode(raw, &out));
    }
}

test "key-ups and keys that type nothing give no bytes; Rc repeats, at most max_repeat times" {
    var out: [Decoder.max_repeat * 2]u8 = undefined;
    try testing.expectEqualStrings("", decode("\x1b[65;30;97;0;32;1_\x1b[16;42;0;1;48;1_\x1b[16;42;0;0;32;1_", &out));
    try testing.expectEqualStrings("bbb", decode("\x1b[66;48;98;1;32;3_", &out));
    // Rc 0, or left out, is one press.
    try testing.expectEqualStrings("b", decode("\x1b[66;48;98;1;32;0_", &out));
    try testing.expectEqualStrings("a", decode("\x1b[65;;97;1_", &out));
    // Text that only looks like a record says what it likes.
    const many = decode("\x1b[66;48;98;1;32;4294967295_", &out);
    try testing.expectEqual(@as(usize, Decoder.max_repeat), many.len);
    for (many) |b| try testing.expectEqual(@as(u8, 'b'), b);
    try testing.expectEqualStrings("\x1b[A" ** 3, decode("\x1b[38;72;0;1;288;3_", &out));
    // A key that types nothing is not repeated at all, however large its Rc.
    var d: Decoder = .{};
    for ("\x1b[16;42;0;1;48;4294967295_") |b| d.put(b);
    try testing.expect(!d.holding());
}

test "a surrogate pair split over two records is one character; a lone half goes on as WTF-8" {
    var out: [32]u8 = undefined;
    var wtf8: [12]u8 = undefined;
    const hi = try std.unicode.wtf8Encode(0xD83D, wtf8[0..]);
    wtf8[hi] = 'a';
    const lo = try std.unicode.wtf8Encode(0xDE00, wtf8[hi + 1 ..]);
    try testing.expectEqualStrings(wtf8[0 .. hi + 1 + lo], decode("\x1b[255;0;55357;1;32;1_\x1b[65;30;97;1;32;1_\x1b[255;0;56832;1;32;1_", &out));
}

test "a record cut in two by a short read decodes once its rest comes" {
    var d: Decoder = .{};
    var out: [8]u8 = undefined;
    for ("\x1b[65;30") |b| d.put(b);
    try testing.expect(d.framing());
    try testing.expectEqual(@as(usize, 0), d.take(&out));
    for (";97;1;32;1_") |b| d.put(b);
    try testing.expect(!d.framing());
    try testing.expectEqual(@as(usize, 1), d.take(&out));
    try testing.expectEqual(@as(u8, 'a'), out[0]);
}

test "the decoder says which bytes came from key records" {
    var d: Decoder = .{};
    var out: [8]u8 = undefined;
    for ("\x1b[27;1;27;1;32;1_") |b| d.put(b);
    try testing.expectEqual(@as(usize, 1), d.take(&out));
    try testing.expect(d.last_from_record);
    d.put(0x1b);
    d.put('\r');
    try testing.expectEqual(@as(usize, 2), d.take(&out));
    try testing.expectEqualStrings("\x1b\r", out[0..2]);
    try testing.expect(!d.last_from_record);
}

test "only a key-down record that types text shows the host sends real key events" {
    // What ConPTY makes of the control characters a VT-only terminal writes
    // (measured): CR, ESC, Ctrl+A with its Ctrl records; a Ctrl+Enter-like
    // pasted line break; key-ups of anything.
    for ([_][]const u8{
        "\x1b[13;28;13;1;0;1_\x1b[13;28;13;0;0;1_",
        "\x1b[27;1;27;1;0;1_\x1b[27;1;27;0;0;1_",
        "\x1b[17;29;0;1;8;1_\x1b[65;30;1;1;8;1_\x1b[65;30;1;0;8;1_\x1b[17;29;0;0;0;1_",
        "\x1b[13;28;10;1;8;1_",
        "\x1b[16;42;0;1;16;1_",
        "\x1b[65;30;97;0;0;1_",
        "plain text \x1b[13;2u",
    }) |stream| {
        var d: Decoder = .{};
        var out: [64]u8 = undefined;
        _ = decodeAll(&d, stream, &out);
        try testing.expect(!d.typed_text);
    }
    for ([_][]const u8{ "\x1b[65;30;97;1;32;1_", "\x1b[0;0;20320;1;32;1_", "\x1b[255;0;55357;1;32;1_" }) |stream| {
        var d: Decoder = .{};
        var out: [64]u8 = undefined;
        _ = decodeAll(&d, stream, &out);
        try testing.expect(d.typed_text);
        d.reset();
        try testing.expect(d.typed_text);
    }
}

test "a classic conhost paste, markers and all as records, decodes to the bracketed paste" {
    // Right-click paste of "p\nq" with 2004 and 9001 on (measured shape): every
    // character a down/up pair, the markers' bytes too (Vk 0), the line break an Enter.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(testing.allocator);
    for ("\x1b[200~p") |c| {
        const vk: u32 = if (c == 'p') 80 else 0;
        try stream.print(testing.allocator, "\x1b[{d};0;{d};1;0;1_\x1b[{d};0;{d};0;0;1_", .{ vk, c, vk, c });
    }
    try stream.appendSlice(testing.allocator, "\x1b[13;28;13;1;0;1_\x1b[13;28;13;0;0;1_");
    for ("q\x1b[201~") |c| try stream.print(testing.allocator, "\x1b[0;0;{d};1;0;1_\x1b[0;0;{d};0;0;1_", .{ c, c });
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings("\x1b[200~p\rq\x1b[201~", decode(stream.items, &out));
}
