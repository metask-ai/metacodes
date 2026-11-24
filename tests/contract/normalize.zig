const std = @import("std");

pub const Literal = struct {
    needle: []const u8,
    placeholder: []const u8,
};

pub const Rules = struct {
    literals: []const Literal = &.{},
};

const volatile_number_suffixes = [_][]const u8{ "_ms", "_ns", "_at", "_unix", "Nano" };
const volatile_number_keys = [_][]const u8{"content_bytes"};
const volatile_string_keys = [_][]const u8{"trace_id"};

pub fn apply(gpa: std.mem.Allocator, input: []const u8, rules: Rules) ![]u8 {
    var current = try gpa.dupe(u8, input);
    errdefer gpa.free(current);
    const literals = try gpa.dupe(Literal, rules.literals);
    defer gpa.free(literals);
    std.mem.sort(Literal, literals, {}, longerNeedleFirst);
    for (literals) |literal| {
        if (literal.needle.len == 0) continue;
        const next = try std.mem.replaceOwned(u8, gpa, current, literal.needle, literal.placeholder);
        gpa.free(current);
        current = next;
    }
    const passes = [_]*const fn (std.mem.Allocator, []const u8) anyerror![]u8{
        replaceTimestamps,
        replaceVolatileNumbers,
        replaceVolatileStrings,
        replaceUuids,
        replaceHexRuns,
    };
    for (passes) |pass| {
        const next = try pass(gpa, current);
        gpa.free(current);
        current = next;
    }
    return current;
}

fn longerNeedleFirst(_: void, a: Literal, b: Literal) bool {
    return a.needle.len > b.needle.len;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHex(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f');
}

fn digitsAt(s: []const u8, at: usize, n: usize) bool {
    if (at + n > s.len) return false;
    for (s[at..][0..n]) |c| if (!isDigit(c)) return false;
    return true;
}

fn dateLen(s: []const u8, at: usize) usize {
    if (!digitsAt(s, at, 4) or at + 10 > s.len) return 0;
    if (s[at + 4] != '-' or s[at + 7] != '-') return 0;
    if (!digitsAt(s, at + 5, 2) or !digitsAt(s, at + 8, 2)) return 0;
    if (at > 0 and isDigit(s[at - 1])) return 0;
    return 10;
}

fn timeLen(s: []const u8, at: usize) usize {
    if (!digitsAt(s, at, 2) or at + 8 > s.len) return 0;
    if (s[at + 2] != ':' or s[at + 5] != ':' or !digitsAt(s, at + 3, 2) or !digitsAt(s, at + 6, 2)) return 0;
    var end = at + 8;
    if (end < s.len and s[end] == '.') {
        end += 1;
        while (end < s.len and isDigit(s[end])) end += 1;
    }
    if (end < s.len and s[end] == 'Z') {
        end += 1;
    } else if (end + 6 <= s.len and (s[end] == '+' or s[end] == '-') and digitsAt(s, end + 1, 2) and s[end + 3] == ':' and digitsAt(s, end + 4, 2)) {
        end += 6;
    }
    return end - at;
}

fn replaceTimestamps(gpa: std.mem.Allocator, s: []const u8) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const date = dateLen(s, i);
        if (date > 0 and i + date < s.len and (s[i + date] == 'T' or s[i + date] == ' ')) {
            const time = timeLen(s, i + date + 1);
            if (time > 0) {
                try out.appendSlice(gpa, "<TIMESTAMP>");
                i += date + 1 + time;
                continue;
            }
        }
        try out.append(gpa, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn isKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isVolatileKey(key: []const u8) bool {
    for (volatile_number_suffixes) |suffix| if (std.mem.endsWith(u8, key, suffix)) return true;
    for (volatile_number_keys) |name| if (std.mem.eql(u8, key, name)) return true;
    return false;
}

fn replaceVolatileNumbers(gpa: std.mem.Allocator, s: []const u8) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != ':') {
            try out.append(gpa, s[i]);
            i += 1;
            continue;
        }
        try out.append(gpa, ':');
        i += 1;
        var quote = i - 1;
        if (quote == 0) continue;
        quote -= 1;
        if (s[quote] != '"') continue;
        if (quote > 0 and s[quote - 1] == '\\') continue;
        const key_end = quote;
        var key_start = key_end;
        while (key_start > 0 and isKeyChar(s[key_start - 1])) key_start -= 1;
        if (!isVolatileKey(s[key_start..key_end])) continue;
        var value_start = i;
        if (value_start < s.len and s[value_start] == '"') value_start += 1;
        var value_end = value_start;
        while (value_end < s.len and isDigit(s[value_end])) value_end += 1;
        if (value_end == value_start) continue;
        try out.appendSlice(gpa, s[i..value_start]);
        try out.appendSlice(gpa, "<N>");
        i = value_end;
    }
    return out.toOwnedSlice(gpa);
}

fn replaceVolatileStrings(gpa: std.mem.Allocator, s: []const u8) anyerror![]u8 {
    var current = try gpa.dupe(u8, s);
    for (volatile_string_keys) |key| {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const needle = try std.fmt.allocPrint(gpa, "\"{s}\":\"", .{key});
        defer gpa.free(needle);
        var rest: []const u8 = current;
        while (std.mem.indexOf(u8, rest, needle)) |at| {
            const start = at + needle.len;
            const end = std.mem.indexOfScalarPos(u8, rest, start, '"') orelse break;
            try out.appendSlice(gpa, rest[0..start]);
            try out.appendSlice(gpa, "<ID>");
            rest = rest[end..];
        }
        try out.appendSlice(gpa, rest);
        gpa.free(current);
        current = try out.toOwnedSlice(gpa);
    }
    return current;
}

fn uuidLen(s: []const u8, at: usize) usize {
    const groups = [_]usize{ 8, 4, 4, 4, 12 };
    if (at > 0 and isHex(s[at - 1])) return 0;
    var pos = at;
    for (groups, 0..) |n, g| {
        if (pos + n > s.len) return 0;
        for (s[pos..][0..n]) |c| if (!isHex(c)) return 0;
        pos += n;
        if (g + 1 < groups.len) {
            if (pos >= s.len or s[pos] != '-') return 0;
            pos += 1;
        }
    }
    if (pos < s.len and isHex(s[pos])) return 0;
    return pos - at;
}

fn replaceUuids(gpa: std.mem.Allocator, s: []const u8) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const n = uuidLen(s, i);
        if (n > 0) {
            try out.appendSlice(gpa, "<UUID>");
            i += n;
        } else {
            try out.append(gpa, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn replaceHexRuns(gpa: std.mem.Allocator, s: []const u8) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (!isHex(s[i]) or (i > 0 and std.ascii.isAlphanumeric(s[i - 1]))) {
            try out.append(gpa, s[i]);
            i += 1;
            continue;
        }
        var end = i;
        var digits: usize = 0;
        while (end < s.len and isHex(s[end])) : (end += 1) {
            if (isDigit(s[end])) digits += 1;
        }
        const bounded = end == s.len or !std.ascii.isAlphanumeric(s[end]);
        const pinned = std.mem.endsWith(u8, s[0..i], "offer-");
        if (bounded and !pinned and end - i >= 16 and digits > 0) {
            try out.print(gpa, "<HEX{d}>", .{end - i});
        } else {
            try out.appendSlice(gpa, s[i..end]);
        }
        i = end;
    }
    return out.toOwnedSlice(gpa);
}

pub fn splitJson(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, body, '\n') != null) return error.BodyHasLiteralNewline;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var in_string = false;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        try out.append(gpa, c);
        if (in_string) {
            if (c == '\\' and i + 1 < body.len) {
                i += 1;
                try out.append(gpa, body[i]);
                if (body[i] == 'n') try out.append(gpa, '\n');
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[', ',' => try out.append(gpa, '\n'),
            else => {},
        }
    }
    try out.append(gpa, '\n');
    return out.toOwnedSlice(gpa);
}

pub fn joinSplitJson(gpa: std.mem.Allocator, split: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (split) |c| if (c != '\n') try out.append(gpa, c);
    return out.toOwnedSlice(gpa);
}
