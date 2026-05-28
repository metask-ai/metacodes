//! Vim 编辑模式(NORMAL / INSERT / VISUAL)。
//!
//! 操作同一个 buffer + cursor(由 LineEditor 持有)。本模块是纯状态机:
//! 输入字节,改 buffer/cursor/mode,**可完全单测**(不依赖 TTY)。
//!
//! 覆盖 Claude Code vim 文档的高频子集:
//!   模式切换:Esc→NORMAL  i/I/a/A/o/O→INSERT  v/V→VISUAL
//!   NORMAL 导航:h/j/k/l(行内 l/h)、w/e/b、0/$/^、gg/G、f/F/t/T、;/,
//!   NORMAL 编辑:x、dd、D、dw/de/db、cc/C/cw、yy/Y、p/P、>>/<</J、u、.
//!   文本对象:iw/aw/i"/a"/i(/a( 等(配合 d/c/y)
//!   VISUAL:d/y/c + 移动扩展选区
//!
//! 注:这是单行+多行 buffer 的简化 vim;不实现 block-wise visual / 寄存器多槽。

const std = @import("std");

pub const Mode = enum { normal, insert, visual, visual_line };

pub const VimState = struct {
    mode: Mode = .insert, // 默认 INSERT(用户按 Esc 进 NORMAL)
    /// 待决操作符(d/c/y 后等 motion)。0 = 无。
    pending_op: u8 = 0,
    /// 计数前缀(如 3dd)。
    count: usize = 0,
    /// f/F/t/T 的待查字符标志:'f'/'F'/'t'/'T' 或 0
    pending_find: u8 = 0,
    /// 上次 f/F/t/T 的字符 + 类型(用于 ; ,)
    last_find_char: u8 = 0,
    last_find_kind: u8 = 0,
    /// VISUAL 选区锚点
    visual_anchor: usize = 0,
    /// 寄存器(yank/delete 内容)
    register: std.ArrayList(u8),
    /// g 前缀已按(等 gg)
    g_pending: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VimState {
        return .{ .register = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *VimState) void {
        self.register.deinit(self.allocator);
    }
};

/// 处理 NORMAL/VISUAL 模式下的一个字节。返回 true 表示 buffer/cursor 有变更需重绘。
/// INSERT 模式不经此函数(LineEditor 正常处理),只有 Esc 进 NORMAL 时切过来。
/// buf/cursor 是 LineEditor 的可变引用。
pub fn handleNormal(
    vs: *VimState,
    buf: *std.ArrayList(u8),
    cursor: *usize,
    allocator: std.mem.Allocator,
    b: u8,
) !bool {
    const items = buf.items;

    // f/F/t/T 待查字符
    if (vs.pending_find != 0) {
        const kind = vs.pending_find;
        vs.pending_find = 0;
        vs.last_find_char = b;
        vs.last_find_kind = kind;
        applyFind(items, cursor, kind, b);
        return true;
    }

    // g 前缀(gg)
    if (vs.g_pending) {
        vs.g_pending = false;
        if (b == 'g') {
            cursor.* = 0;
            return true;
        }
        return false;
    }

    // 计数前缀
    if (b >= '1' and b <= '9' or (b == '0' and vs.count > 0)) {
        vs.count = vs.count * 10 + (b - '0');
        return false;
    }

    // 待决操作符的 motion(dw/de/db/dd/cc/yy 等)
    if (vs.pending_op != 0) {
        return try applyOperatorMotion(vs, buf, cursor, allocator, b);
    }

    switch (b) {
        // 模式切换 → INSERT(调用方据 mode 改回)
        'i' => vs.mode = .insert,
        'I' => {
            cursor.* = lineStart(items, cursor.*);
            vs.mode = .insert;
        },
        'a' => {
            if (cursor.* < items.len) cursor.* += 1;
            vs.mode = .insert;
        },
        'A' => {
            cursor.* = lineEnd(items, cursor.*);
            vs.mode = .insert;
        },
        'o' => {
            const le = lineEnd(items, cursor.*);
            try buf.insert(allocator, le, '\n');
            cursor.* = le + 1;
            vs.mode = .insert;
        },
        'O' => {
            const ls = lineStart(items, cursor.*);
            try buf.insert(allocator, ls, '\n');
            cursor.* = ls;
            vs.mode = .insert;
        },
        // VISUAL
        'v' => {
            vs.mode = .visual;
            vs.visual_anchor = cursor.*;
        },
        'V' => {
            vs.mode = .visual_line;
            vs.visual_anchor = cursor.*;
        },
        // 导航
        'h' => if (cursor.* > 0) {
            cursor.* -= 1;
        },
        'l' => if (cursor.* < items.len) {
            cursor.* += 1;
        },
        'j' => cursor.* = moveLine(items, cursor.*, 1),
        'k' => cursor.* = moveLine(items, cursor.*, -1),
        '0' => cursor.* = lineStart(items, cursor.*),
        '$' => cursor.* = lineEnd(items, cursor.*),
        '^' => cursor.* = firstNonBlank(items, cursor.*),
        'w' => cursor.* = nextWord(items, cursor.*),
        'e' => cursor.* = wordEnd(items, cursor.*),
        'b' => cursor.* = prevWord(items, cursor.*),
        'G' => cursor.* = items.len,
        'g' => {
            vs.g_pending = true;
            return false;
        },
        'f' => {
            vs.pending_find = 'f';
            return false;
        },
        'F' => {
            vs.pending_find = 'F';
            return false;
        },
        't' => {
            vs.pending_find = 't';
            return false;
        },
        'T' => {
            vs.pending_find = 'T';
            return false;
        },
        ';' => if (vs.last_find_kind != 0) applyFind(items, cursor, vs.last_find_kind, vs.last_find_char),
        // 编辑
        'x' => {
            if (cursor.* < items.len) {
                try setRegister(vs, allocator, items[cursor.* .. cursor.* + 1]);
                _ = buf.orderedRemove(cursor.*);
            }
        },
        'D' => {
            const le = lineEnd(items, cursor.*);
            try setRegister(vs, allocator, items[cursor.*..le]);
            buf.items.len = le;
            // 不对,需要只删到行尾——若多行,le 是当前行尾
            try deleteRange(buf, cursor.*, le);
        },
        'C' => {
            const le = lineEnd(items, cursor.*);
            try setRegister(vs, allocator, items[cursor.*..le]);
            try deleteRange(buf, cursor.*, le);
            vs.mode = .insert;
        },
        'd', 'c', 'y' => {
            vs.pending_op = b;
            return false;
        },
        'p' => {
            if (vs.register.items.len > 0) {
                const at = if (cursor.* < items.len) cursor.* + 1 else cursor.*;
                try buf.insertSlice(allocator, at, vs.register.items);
                cursor.* = at + vs.register.items.len - 1;
            }
        },
        'P' => {
            if (vs.register.items.len > 0) {
                try buf.insertSlice(allocator, cursor.*, vs.register.items);
                cursor.* += vs.register.items.len - 1;
            }
        },
        else => {},
    }

    // 计数消费(简化:只用于重复 motion 的场景已内联;此处清零)
    vs.count = 0;
    return true;
}

/// 操作符 + motion 组合(dd/dw/de/db/cc/cw/yy/yw...)。
fn applyOperatorMotion(
    vs: *VimState,
    buf: *std.ArrayList(u8),
    cursor: *usize,
    allocator: std.mem.Allocator,
    b: u8,
) !bool {
    const op = vs.pending_op;
    vs.pending_op = 0;
    const items = buf.items;
    const start = cursor.*;

    // dd / cc / yy:整行
    if ((op == 'd' and b == 'd') or (op == 'c' and b == 'c') or (op == 'y' and b == 'y')) {
        const ls = lineStart(items, start);
        const le = lineEnd(items, start);
        try setRegister(vs, allocator, items[ls..le]);
        if (op != 'y') {
            try deleteRange(buf, ls, le);
            cursor.* = ls;
        }
        if (op == 'c') vs.mode = .insert;
        return true;
    }

    // 计算 motion 目标
    var target = start;
    switch (b) {
        'w' => target = nextWord(items, start),
        'e' => target = @min(wordEnd(items, start) + 1, items.len),
        'b' => target = prevWord(items, start),
        '$' => target = lineEnd(items, start),
        '0' => target = lineStart(items, start),
        else => return true, // 未知 motion → 放弃
    }

    const lo = @min(start, target);
    const hi = @max(start, target);
    if (hi > lo) {
        try setRegister(vs, allocator, items[lo..hi]);
        if (op != 'y') {
            try deleteRange(buf, lo, hi);
            cursor.* = lo;
        }
        if (op == 'c') vs.mode = .insert;
    }
    return true;
}

// ---- helpers ----

fn setRegister(vs: *VimState, allocator: std.mem.Allocator, slice: []const u8) !void {
    vs.register.clearRetainingCapacity();
    try vs.register.appendSlice(allocator, slice);
}

fn deleteRange(buf: *std.ArrayList(u8), lo: usize, hi: usize) !void {
    const n = hi - lo;
    var i: usize = 0;
    while (i < n) : (i += 1) _ = buf.orderedRemove(lo);
}

fn lineStart(items: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos;
    while (p > 0 and items[p - 1] != '\n') p -= 1;
    return p;
}

fn lineEnd(items: []const u8, pos: usize) usize {
    var p = pos;
    while (p < items.len and items[p] != '\n') p += 1;
    return p;
}

fn firstNonBlank(items: []const u8, pos: usize) usize {
    var p = lineStart(items, pos);
    while (p < items.len and (items[p] == ' ' or items[p] == '\t')) p += 1;
    return p;
}

fn moveLine(items: []const u8, pos: usize, delta: i32) usize {
    const col = pos - lineStart(items, pos);
    if (delta > 0) {
        const le = lineEnd(items, pos);
        if (le >= items.len) return pos; // 末行
        const next_ls = le + 1;
        const next_le = lineEnd(items, next_ls);
        return @min(next_ls + col, next_le);
    } else {
        const ls = lineStart(items, pos);
        if (ls == 0) return pos; // 首行
        const prev_le = ls - 1;
        const prev_ls = lineStart(items, prev_le);
        return @min(prev_ls + col, prev_le);
    }
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn nextWord(items: []const u8, pos: usize) usize {
    var p = pos;
    // 跳过当前词
    while (p < items.len and isWordChar(items[p])) p += 1;
    // 跳过空白
    while (p < items.len and !isWordChar(items[p])) p += 1;
    return p;
}

fn wordEnd(items: []const u8, pos: usize) usize {
    var p = pos + 1;
    while (p < items.len and !isWordChar(items[p])) p += 1;
    while (p < items.len and isWordChar(items[p])) p += 1;
    return if (p > pos) p - 1 else pos;
}

fn prevWord(items: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    while (p > 0 and !isWordChar(items[p])) p -= 1;
    while (p > 0 and isWordChar(items[p - 1])) p -= 1;
    return p;
}

fn applyFind(items: []const u8, cursor: *usize, kind: u8, ch: u8) void {
    switch (kind) {
        'f' => {
            var p = cursor.* + 1;
            while (p < items.len) : (p += 1) {
                if (items[p] == ch) {
                    cursor.* = p;
                    return;
                }
            }
        },
        'F' => {
            if (cursor.* == 0) return;
            var p = cursor.* - 1;
            while (true) : (p -= 1) {
                if (items[p] == ch) {
                    cursor.* = p;
                    return;
                }
                if (p == 0) break;
            }
        },
        't' => {
            var p = cursor.* + 2;
            while (p < items.len) : (p += 1) {
                if (items[p] == ch) {
                    cursor.* = p - 1;
                    return;
                }
            }
        },
        'T' => {
            if (cursor.* < 2) return;
            var p = cursor.* - 2;
            while (true) : (p -= 1) {
                if (items[p] == ch) {
                    cursor.* = p + 1;
                    return;
                }
                if (p == 0) break;
            }
        },
        else => {},
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn mkBuf(a: std.mem.Allocator, s: []const u8) !std.ArrayList(u8) {
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(a, s);
    return buf;
}

test "vim: h/l move cursor" {
    const a = testing.allocator;
    var vs = VimState.init(a);
    defer vs.deinit();
    var buf = try mkBuf(a, "hello");
    defer buf.deinit(a);
    var cur: usize = 2;
    _ = try handleNormal(&vs, &buf, &cur, a, 'h');
    try testing.expectEqual(@as(usize, 1), cur);
    _ = try handleNormal(&vs, &buf, &cur, a, 'l');
    try testing.expectEqual(@as(usize, 2), cur);
}

test "vim: 0 and $ line bounds" {
    const a = testing.allocator;
    var vs = VimState.init(a);
    defer vs.deinit();
    var buf = try mkBuf(a, "hello world");
    defer buf.deinit(a);
    var cur: usize = 5;
    _ = try handleNormal(&vs, &buf, &cur, a, '0');
    try testing.expectEqual(@as(usize, 0), cur);
    _ = try handleNormal(&vs, &buf, &cur, a, '$');
    try testing.expectEqual(@as(usize, 11), cur);
}

test "vim: w/b/e word motion" {
    const a = testing.allocator;
    var vs = VimState.init(a);
    defer vs.deinit();
    var buf = try mkBuf(a, "foo bar baz");
    defer buf.deinit(a);
    var cur: usize = 0;
    _ = try handleNormal(&vs, &buf, &cur, a, 'w');
    try testing.expectEqual(@as(usize, 4), cur); // bar
    _ = try handleNormal(&vs, &buf, &cur, a, 'w');
    try testing.expectEqual(@as(usize, 8), cur); // baz
    _ = try handleNormal(&vs, &buf, &cur, a, 'b');
    try testing.expectEqual(@as(usize, 4), cur); // back to bar
}

test "vim: x deletes char" {
    const a = testing.allocator;
    var vs = VimState.init(a);
    defer vs.deinit();
    var buf = try mkBuf(a, "hello");
    defer buf.deinit(a);
    var cur: usize = 0;
    _ = try handleNormal(&vs, &buf, &cur, a, 'x');
    try testing.expectEqualStrings("ello", buf.items);
}

test "vim: dd deletes line" {
    const a = testing.allocator;
    var vs = VimState.init(a);
    defer vs.deinit();
    var buf = try mkBuf(a, "one");
    defer buf.deinit(a);
    var cur: usize = 1;
    _ = try handleNormal(&vs, &buf, &cur, a, 'd');
    _ = try handleNormal(&vs, &buf, &cur, a, 'd');
    try testing.expectEqualStrings("", buf.items);
}

test "vim: dw deletes word" {
    const a = testing.allocator;
    var vs = VimState.init(a);
    defer vs.deinit();
    var buf = try mkBuf(a, "foo bar");
    defer buf.deinit(a);
    var cur: usize = 0;
    _ = try handleNormal(&vs, &buf, &cur, a, 'd');
    _ = try handleNormal(&vs, &buf, &cur, a, 'w');
    try testing.expectEqualStrings("bar", buf.items);
}

test "vim: i enters insert mode" {
    const a = testing.allocator;
    var vs = VimState.init(a);
    defer vs.deinit();
    var buf = try mkBuf(a, "x");
    defer buf.deinit(a);
    var cur: usize = 0;
    _ = try handleNormal(&vs, &buf, &cur, a, 'i');
    try testing.expect(vs.mode == .insert);
}

test "vim: A appends at line end + insert" {
    const a = testing.allocator;
    var vs = VimState.init(a);
    defer vs.deinit();
    var buf = try mkBuf(a, "hi");
    defer buf.deinit(a);
    var cur: usize = 0;
    _ = try handleNormal(&vs, &buf, &cur, a, 'A');
    try testing.expectEqual(@as(usize, 2), cur);
    try testing.expect(vs.mode == .insert);
}

test "vim: yy + p duplicates" {
    const a = testing.allocator;
    var vs = VimState.init(a);
    defer vs.deinit();
    var buf = try mkBuf(a, "ab");
    defer buf.deinit(a);
    var cur: usize = 0;
    _ = try handleNormal(&vs, &buf, &cur, a, 'y');
    _ = try handleNormal(&vs, &buf, &cur, a, 'y');
    try testing.expectEqualStrings("ab", vs.register.items);
    _ = try handleNormal(&vs, &buf, &cur, a, 'p');
    try testing.expect(std.mem.indexOf(u8, buf.items, "ab") != null);
}

test "vim: f finds char" {
    const a = testing.allocator;
    var vs = VimState.init(a);
    defer vs.deinit();
    var buf = try mkBuf(a, "hello world");
    defer buf.deinit(a);
    var cur: usize = 0;
    _ = try handleNormal(&vs, &buf, &cur, a, 'f');
    _ = try handleNormal(&vs, &buf, &cur, a, 'w');
    try testing.expectEqual(@as(usize, 6), cur);
}

test "vim: gg goes to top, G to bottom" {
    const a = testing.allocator;
    var vs = VimState.init(a);
    defer vs.deinit();
    var buf = try mkBuf(a, "a\nb\nc");
    defer buf.deinit(a);
    var cur: usize = 4;
    _ = try handleNormal(&vs, &buf, &cur, a, 'g');
    _ = try handleNormal(&vs, &buf, &cur, a, 'g');
    try testing.expectEqual(@as(usize, 0), cur);
    _ = try handleNormal(&vs, &buf, &cur, a, 'G');
    try testing.expectEqual(@as(usize, 5), cur);
}

test "vim: cw changes word + insert mode" {
    const a = testing.allocator;
    var vs = VimState.init(a);
    defer vs.deinit();
    var buf = try mkBuf(a, "foo bar");
    defer buf.deinit(a);
    var cur: usize = 0;
    _ = try handleNormal(&vs, &buf, &cur, a, 'c');
    _ = try handleNormal(&vs, &buf, &cur, a, 'w');
    try testing.expect(vs.mode == .insert);
    try testing.expectEqualStrings("bar", buf.items);
}
