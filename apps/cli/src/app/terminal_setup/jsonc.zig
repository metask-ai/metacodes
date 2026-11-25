//! JSONC as VS Code writes `keybindings.json`: JSON plus `//` and `/* */`
//! comments and trailing commas.
//!
//! Both passes here keep the length of the text: `blank` turns comments into
//! spaces (line breaks stay), `dropTrailingCommas` then does the same to
//! trailing commas, which leaves plain JSON. Offsets found in either text
//! therefore index the original too, so `terminal_setup/vscode.zig` reads the
//! plain text with `std.json` and splices the original, keeping every comment
//! and the user's formatting. It looks for separators in the comment-free
//! text, where a trailing comma is still visible.

const std = @import("std");

pub const Error = error{ OutOfMemory, InvalidJsonc };

const utf8_bom = "\xef\xbb\xbf";

/// `src` with its comments (and a leading UTF-8 byte-order mark) turned into
/// spaces, owned by `gpa`. An unterminated string or block comment is
/// `error.InvalidJsonc`; anything else `std.json` judges afterwards.
pub fn blank(gpa: std.mem.Allocator, src: []const u8) Error![]u8 {
    const out = try gpa.dupe(u8, src);
    errdefer gpa.free(out);
    var i: usize = 0;
    if (std.mem.startsWith(u8, out, utf8_bom)) {
        @memset(out[0..utf8_bom.len], ' ');
        i = utf8_bom.len;
    }
    while (i < out.len) {
        switch (out[i]) {
            '"' => i = try stringEnd(out, i),
            '/' => {
                if (i + 1 < out.len and out[i + 1] == '/') {
                    while (i < out.len and out[i] != '\n' and out[i] != '\r') : (i += 1) out[i] = ' ';
                } else if (i + 1 < out.len and out[i + 1] == '*') {
                    out[i] = ' ';
                    out[i + 1] = ' ';
                    i += 2;
                    while (true) : (i += 1) {
                        if (i + 1 >= out.len) return error.InvalidJsonc;
                        if (out[i] == '*' and out[i + 1] == '/') {
                            out[i] = ' ';
                            out[i + 1] = ' ';
                            i += 2;
                            break;
                        }
                        if (out[i] != '\n' and out[i] != '\r') out[i] = ' ';
                    }
                } else {
                    i += 1; // a lone `/` is not JSON; std.json reports it
                }
            },
            else => i += 1,
        }
    }
    return out;
}

/// The index just past the string that opens at `text[open]`.
fn stringEnd(text: []const u8, open: usize) error{InvalidJsonc}!usize {
    var i = open + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] == '"') return i + 1;
    }
    return error.InvalidJsonc;
}

/// Turns the trailing commas of comment-free text (`blank`'s) into spaces, in
/// place: a `,` whose next significant byte closes an array or object.
pub fn dropTrailingCommas(text: []u8) error{InvalidJsonc}!void {
    var last_significant: ?usize = null;
    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            '"' => {
                last_significant = i;
                i = try stringEnd(text, i);
            },
            ' ', '\t', '\n', '\r' => i += 1,
            ']', '}' => {
                if (last_significant) |at| if (text[at] == ',') {
                    text[at] = ' ';
                };
                last_significant = i;
                i += 1;
            },
            else => {
                last_significant = i;
                i += 1;
            },
        }
    }
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Index of the first byte of `text` that is not whitespace, at or after `from`.
pub fn nextSignificant(text: []const u8, from: usize) ?usize {
    var i = from;
    while (i < text.len) : (i += 1) if (!isSpace(text[i])) return i;
    return null;
}

/// Index of the last byte of `text[0..before]` that is not whitespace.
pub fn prevSignificant(text: []const u8, before: usize) ?usize {
    var i = before;
    while (i > 0) {
        i -= 1;
        if (!isSpace(text[i])) return i;
    }
    return null;
}

/// The document's top-level array in its comment-free text: `[` (`open`), its
/// `]` (`close`), and the significant byte just before `]` (`last`: `open` for
/// an empty array, `,` after a trailing comma). The caller has checked with
/// `std.json` that the document is one array, so the first significant byte is
/// `[` and the last is `]`.
pub const TopArray = struct {
    open: usize,
    close: usize,
    last: usize,
};

/// null for a document with no value at all (empty, or only comments).
pub fn topArray(text: []const u8) ?TopArray {
    const open = nextSignificant(text, 0) orelse return null;
    const close = prevSignificant(text, text.len).?;
    std.debug.assert(text[open] == '[' and text[close] == ']' and close > open);
    return .{ .open = open, .close = close, .last = prevSignificant(text, close).? };
}

/// The significant bytes of one array element: `text[start..end]`.
pub const Span = struct {
    start: usize,
    end: usize,
};

/// The spans of the top-level array's elements, in order (owned by `gpa`).
/// Commas inside nested values and strings do not split; a trailing comma
/// ends the last element and starts none.
pub fn elements(gpa: std.mem.Allocator, text: []const u8, arr: TopArray) error{OutOfMemory}![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(gpa);
    var depth: usize = 0;
    var start: ?usize = null;
    var end: usize = 0;
    var i = arr.open + 1;
    while (i < arr.close) : (i += 1) {
        const c = text[i];
        if (isSpace(c)) continue;
        if (depth == 0 and c == ',') {
            if (start) |s| try spans.append(gpa, .{ .start = s, .end = end });
            start = null;
            continue;
        }
        if (start == null) start = i;
        switch (c) {
            '"' => {
                i += 1;
                while (text[i] != '"') : (i += 1) {
                    if (text[i] == '\\') i += 1;
                }
            },
            '[', '{' => depth += 1,
            ']', '}' => depth -= 1,
            else => {},
        }
        end = i + 1;
    }
    if (start) |s| try spans.append(gpa, .{ .start = s, .end = end });
    return spans.toOwnedSlice(gpa);
}

const testing = std.testing;

test "blank and dropTrailingCommas: plain JSON with the original's offsets and line breaks" {
    const src =
        \\// header
        \\[
        \\  { "key": "ctrl+/", /* not a comment */ "when": "a // b", },
        \\  /* multi
        \\     line */
        \\  "x\"y,]",
        \\]
    ;
    const text = try blank(testing.allocator, src);
    defer testing.allocator.free(text);
    try testing.expectEqual(src.len, text.len);
    for (src, text) |a, b| if (a == '\n') try testing.expectEqual(@as(u8, '\n'), b);
    // Comments are gone; the trailing commas are still there.
    try testing.expect(std.mem.indexOf(u8, text, "header") == null);
    try testing.expect(std.mem.indexOf(u8, text, "\"a // b\",") != null);
    try dropTrailingCommas(text);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    const arr = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    // `//` inside strings is text, and so are `,]` there.
    try testing.expectEqualStrings("ctrl+/", arr[0].object.get("key").?.string);
    try testing.expectEqualStrings("a // b", arr[0].object.get("when").?.string);
    try testing.expectEqualStrings("x\"y,]", arr[1].string);
}

test "blank: a byte-order mark, CRLF line comments, and the invalid cases" {
    const src = utf8_bom ++ "[1, // one\r\n2,\r\n]";
    const text = try blank(testing.allocator, src);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("   [1,       \r\n2,\r\n]", text);
    try dropTrailingCommas(text);
    try testing.expectEqualStrings("   [1,       \r\n2 \r\n]", text);
    try testing.expectError(error.InvalidJsonc, blank(testing.allocator, "[\"open"));
    try testing.expectError(error.InvalidJsonc, blank(testing.allocator, "[1] /* open"));
    // A comma is only trailing before a closing bracket.
    var kept = "[1,2]".*;
    try dropTrailingCommas(&kept);
    try testing.expectEqualStrings("[1,2]", &kept);
}

test "topArray and elements: spans of the top-level values only" {
    const src = " [ {\"a\": [1, 2], \"b\": \"x,y\"} , 3,\n\"z\", ] ";
    const arr = topArray(src).?;
    try testing.expectEqual(@as(usize, 1), arr.open);
    try testing.expectEqual(src.len - 2, arr.close);
    try testing.expectEqual(@as(u8, ','), src[arr.last]);
    const spans = try elements(testing.allocator, src, arr);
    defer testing.allocator.free(spans);
    try testing.expectEqual(@as(usize, 3), spans.len);
    try testing.expectEqualStrings("{\"a\": [1, 2], \"b\": \"x,y\"}", src[spans[0].start..spans[0].end]);
    try testing.expectEqualStrings("3", src[spans[1].start..spans[1].end]);
    try testing.expectEqualStrings("\"z\"", src[spans[2].start..spans[2].end]);

    const empty = topArray("[ ]").?;
    try testing.expectEqual(empty.open, empty.last);
    const none = try elements(testing.allocator, "[ ]", empty);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
    try testing.expect(topArray("  \n ") == null);
}
