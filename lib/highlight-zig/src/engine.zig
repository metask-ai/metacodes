//! 4 类 token 状态机引擎。纯 stdlib，不用正则。
//!
//! 支持的 token 子集：
//! - keyword: \0 分隔的 packed string，word-boundary 匹配
//! - string: 可配置 delimiter（"/'/`/""" 等），支持 \ 和 '' 转义
//! - comment: 行注释（// # ; 等）和块注释（/* */ 等）
//! - number: 十进制、0x/0b/0o 前缀、小数点
//!
//! 不支持：科学计数法、后缀（u/i/f）、嵌套块注释。
const std = @import("std");
const types = @import("types.zig");
const ColoredSpan = types.ColoredSpan;
const LangRule = types.LangRule;
const StringDelim = types.StringDelim;
const Escape = types.Escape;
const TokenType = types.TokenType;

const State = enum { normal, in_string, in_block_comment };

inline fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}
inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
inline fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}
inline fn matchesAt(src: []const u8, pos: usize, needle: []const u8) bool {
    // needle 非空由调用方保证（matchDelimiter 只传 rule 里的 delimiter）。
    return pos + needle.len <= src.len and std.mem.eql(u8, src[pos .. pos + needle.len], needle);
}
inline fn leftBoundary(src: []const u8, pos: usize) bool {
    return pos == 0 or !isWordChar(src[pos - 1]);
}

/// 扫描字符串内容。返回 close 是否找到。
fn scanString(src: []const u8, start: usize, delim: StringDelim, end: *usize) bool {
    var e = start;
    const esc = delim.escape;
    if (esc != .none) {
        const esc_chars = esc.chars();
        while (e < src.len) {
            if (matchesAt(src, e, esc_chars)) {
                e += esc_chars.len;
                if (e < src.len) e += 1; // 跳过被转义的字符
                continue;
            }
            if (matchesAt(src, e, delim.close)) {
                e += delim.close.len;
                end.* = e;
                return true;
            }
            if (!delim.multiline and (src[e] == '\n' or src[e] == '\r')) {
                end.* = e;
                return false;
            }
            e += 1;
        }
    } else {
        while (e < src.len) {
            if (matchesAt(src, e, delim.close)) {
                e += delim.close.len;
                end.* = e;
                return true;
            }
            if (!delim.multiline and (src[e] == '\n' or src[e] == '\r')) {
                end.* = e;
                return false;
            }
            e += 1;
        }
    }
    end.* = e;
    return false;
}

/// 扫描块注释内容。返回 close 是否找到。
fn scanBlockComment(src: []const u8, start: usize, close: []const u8, end: *usize) bool {
    var e = start;
    while (e < src.len) {
        if (matchesAt(src, e, close)) {
            e += close.len;
            end.* = e;
            return true;
        }
        e += 1;
    }
    end.* = e;
    return false;
}

/// 匹配关键字（word-boundary）。返回匹配长度，0=不匹配。
/// keywords 是 \0 分隔的 packed string。
fn matchKeyword(rule: *const LangRule, src: []const u8, pos: usize) usize {
    if (rule.keywords.len == 0) return 0; // 快速路径
    if (!leftBoundary(src, pos)) return 0;
    var best: usize = 0;
    var kw_start: usize = 0;
    var i: usize = 0;
    while (i <= rule.keywords.len) : (i += 1) {
        if (i == rule.keywords.len or rule.keywords[i] == 0) {
            const kw = rule.keywords[kw_start..i];
            if (kw.len > best and matchesAt(src, pos, kw) and (pos + kw.len >= src.len or !isWordChar(src[pos + kw.len]))) {
                best = kw.len;
            }
            kw_start = i + 1;
        }
    }
    return best;
}

/// 匹配数字。返回匹配长度，0=不匹配。
/// 支持：十进制整数/小数、0x十六进制、0b二进制、0o八进制。
/// 不支持：科学计数法、后缀。
fn matchNumber(rule: *const LangRule, src: []const u8, pos: usize) usize {
    if (!leftBoundary(src, pos) or pos >= src.len) return 0;

    // 前缀（0x/0b/0o）
    for (rule.number_prefix) |prefix| {
        if (matchesAt(src, pos, prefix)) {
            const after = pos + prefix.len;
            if (after >= src.len) return 0;
            const hex = std.mem.eql(u8, prefix, "0x");
            const ok = if (hex) isHexDigit(src[after]) else isDigit(src[after]);
            if (!ok) return 0;
            var end = after + 1;
            while (end < src.len and (if (hex) isHexDigit(src[end]) else isDigit(src[end]))) : (end += 1) {}
            if (end < src.len and src[end] == '.' and end + 1 < src.len and isDigit(src[end + 1])) {
                end += 1;
                while (end < src.len and isDigit(src[end])) : (end += 1) {}
            }
            return end - pos;
        }
    }
    // 十进制
    if (!isDigit(src[pos])) return 0;
    var end = pos + 1;
    while (end < src.len and isDigit(src[end])) : (end += 1) {}
    if (end < src.len and src[end] == '.' and end + 1 < src.len and isDigit(src[end + 1])) {
        end += 1;
        while (end < src.len and isDigit(src[end])) : (end += 1) {}
    }
    return end - pos;
}

const Match = struct {
    len: usize,
    kind: enum { none, comment_line, comment_block, string },
    close: []const u8 = "",
    delim_idx: usize = 0,
};

fn matchDelimiter(rule: *const LangRule, src: []const u8, pos: usize) Match {
    var best = Match{ .len = 0, .kind = .none };

    // 行注释
    for (rule.comment_line) |p| {
        if (matchesAt(src, pos, p) and p.len > best.len) {
            best = .{ .len = p.len, .kind = .comment_line };
        }
    }
    // 块注释
    for (rule.comment_block) |pair| {
        if (matchesAt(src, pos, pair[0]) and pair[0].len > best.len) {
            best = .{ .len = pair[0].len, .kind = .comment_block, .close = pair[1] };
        }
    }
    // 字符串
    for (rule.string_delims, 0..) |d, i| {
        if (matchesAt(src, pos, d.open) and d.open.len > best.len) {
            best = .{ .len = d.open.len, .kind = .string, .close = d.close, .delim_idx = i };
        }
    }
    return best;
}

/// 判断字符是否可能是 token 起始符。
inline fn isTokenStart(c: u8) bool {
    return isWordChar(c) or c == '/' or c == '#' or c == ';' or c == '"' or c == '\'' or c == '`' or c == '-' or c == '*';
}

/// tokenizes 整个 source。返回 ColoredSpan 数组（allocator 拥有）。
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8, rule: *const LangRule) ![]ColoredSpan {
    var spans = std.ArrayList(ColoredSpan).empty;

    var state: State = .normal;
    var string_delim: ?StringDelim = null;
    var block_close: []const u8 = "";

    var i: usize = 0;
    while (i < source.len) {
        switch (state) {
            .normal => {
                const m = matchDelimiter(rule, source, i);
                // 行注释 → 扫到行尾
                if (m.kind == .comment_line) {
                    var end = i + m.len;
                    while (end < source.len and source[end] != '\n') : (end += 1) {}
                    try spans.append(allocator, .{ .text = source[i..end], .token = .comment });
                    i = end;
                    continue;
                }
                // 块注释
                if (m.kind == .comment_block) {
                    block_close = m.close;
                    var end: usize = i + m.len;
                    const closed = scanBlockComment(source, end, block_close, &end);
                    try spans.append(allocator, .{ .text = source[i..end], .token = .comment });
                    i = end;
                    if (!closed) state = .in_block_comment;
                    continue;
                }
                // 字符串
                if (m.kind == .string) {
                    string_delim = rule.string_delims[m.delim_idx];
                    var end: usize = i + m.len;
                    const closed = scanString(source, end, string_delim.?, &end);
                    try spans.append(allocator, .{ .text = source[i..end], .token = .string });
                    i = end;
                    if (!closed and string_delim.?.multiline and i < source.len) state = .in_string;
                    continue;
                }
                // 关键字
                const kw = matchKeyword(rule, source, i);
                if (kw > 0) {
                    try spans.append(allocator, .{ .text = source[i .. i + kw], .token = .keyword });
                    i += kw;
                    continue;
                }
                // 数字
                const num = matchNumber(rule, source, i);
                if (num > 0) {
                    try spans.append(allocator, .{ .text = source[i .. i + num], .token = .number });
                    i += num;
                    continue;
                }
                // default——批量扫到下一个可能 token 的位置
                // 优化：如果是 word char，连续吞整个 word run（避免单字符 span）
                if (isWordChar(source[i])) {
                    var end = i + 1;
                    while (end < source.len and isWordChar(source[end])) : (end += 1) {}
                    try spans.append(allocator, .{ .text = source[i..end], .token = .none });
                    i = end;
                    continue;
                }
                // 非 word char：扫到下一个 token 起始符
                var end = i + 1;
                while (end < source.len and !isTokenStart(source[end])) : (end += 1) {}
                try spans.append(allocator, .{ .text = source[i..end], .token = .none });
                i = end;
            },
            .in_string => {
                const sd = string_delim orelse {
                    state = .normal;
                    continue;
                };
                var end: usize = i;
                const closed = scanString(source, end, sd, &end);
                try spans.append(allocator, .{ .text = source[i..end], .token = .string });
                i = end;
                if (closed) {
                    state = .normal;
                    string_delim = null;
                }
            },
            .in_block_comment => {
                var end: usize = i;
                const closed = scanBlockComment(source, end, block_close, &end);
                try spans.append(allocator, .{ .text = source[i..end], .token = .comment });
                i = end;
                if (closed) state = .normal;
            },
        }
    }
    return spans.toOwnedSlice(allocator);
}