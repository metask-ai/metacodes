//! REPL 行编辑。
//!
//! 分两层：
//! 1. 底层：按键抽象（Key + KeyParser）+ termios raw mode 切换——从 M4.1 spike 正式化
//! 2. 中层：LineEditor——持 buffer + cursor + 多行 flag；接受 Key，输出 Action
//!
//! 渲染（repl/render.zig）是另一层。真 tty 驱动留给 runtime（M4.4 接入 repl/loop）。
//!
//! 测试策略：LineEditor 全部用 fake keystream 驱动。termios 只做 "不崩" 测试（真 tty 行为难在 CI 里验证）。

const std = @import("std");

// ============================================================================
// Key 抽象
// ============================================================================

pub const Key = union(enum) {
    char: u8,
    enter,
    shift_enter, // 插入换行而非提交（CSI u: ESC [ 13;2 u）
    ctrl_enter, // 同上（CSI u: ESC [ 13;5 u）
    backspace,
    ctrl_a,
    ctrl_e,
    ctrl_u,
    ctrl_k,
    ctrl_w, // 删上一个词
    ctrl_y, // 粘回 yank ring
    ctrl_l, // 重绘屏幕
    ctrl_c,
    ctrl_d,
    alt_b, // 上一词
    alt_f, // 下一词
    up,
    down,
    left,
    right,
    home,
    end,
    delete,
    esc,
    tab,
    shift_tab, // cycle 权限模式
    ctrl_r,
    paste_begin, // 括号粘贴起始 ESC[200~
    paste_end, // 括号粘贴结束 ESC[201~
    unknown,
};

/// 按字节喂的 CSI 状态机解析器（见 M4.1 spike）。
///
/// 支持的 CSI 序列：
///   ESC [ A/B/C/D     ↑↓→←
///   ESC [ H / F       Home / End
///   ESC [ 3 ~         Delete
///   ESC [ <num>;<mod> u   CSI u（xterm modifyOtherKeys kitty 扩展）
///     - 13;2 u = Shift+Enter
///     - 13;5 u = Ctrl+Enter
pub const KeyParser = struct {
    state: State = .normal,
    num1: u32 = 0,
    num2: u32 = 0,

    const State = enum { normal, esc_seen, csi_seen, csi_num1, csi_semi, csi_num2 };

    pub fn feed(self: *KeyParser, b: u8) ?Key {
        switch (self.state) {
            .normal => {
                if (b == 0x1b) {
                    self.state = .esc_seen;
                    return null;
                }
                return byteToKey(b);
            },
            .esc_seen => {
                if (b == '[') {
                    self.state = .csi_seen;
                    self.num1 = 0;
                    self.num2 = 0;
                    return null;
                }
                self.state = .normal;
                // Alt+key:ESC 后紧跟字母(meta)。Alt+B / Alt+F 词导航。
                switch (b) {
                    'b', 'B' => return .alt_b,
                    'f', 'F' => return .alt_f,
                    else => {},
                }
                return .esc;
            },
            .csi_seen => {
                if (b >= '0' and b <= '9') {
                    self.num1 = b - '0';
                    self.state = .csi_num1;
                    return null;
                }
                self.state = .normal;
                return switch (b) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    'Z' => .shift_tab, // ESC [ Z = Shift+Tab(backtab)
                    else => .unknown,
                };
            },
            .csi_num1 => {
                if (b >= '0' and b <= '9') {
                    self.num1 = self.num1 * 10 + (b - '0');
                    return null;
                }
                if (b == ';') {
                    self.state = .csi_semi;
                    return null;
                }
                // 终结字符
                self.state = .normal;
                if (b == '~') {
                    return switch (self.num1) {
                        3 => .delete,
                        200 => .paste_begin,
                        201 => .paste_end,
                        else => .unknown,
                    };
                }
                return .unknown;
            },
            .csi_semi => {
                if (b >= '0' and b <= '9') {
                    self.num2 = b - '0';
                    self.state = .csi_num2;
                    return null;
                }
                self.state = .normal;
                return .unknown;
            },
            .csi_num2 => {
                if (b >= '0' and b <= '9') {
                    self.num2 = self.num2 * 10 + (b - '0');
                    return null;
                }
                self.state = .normal;
                // CSI u：<key_codepoint>;<mod> u。
                //   key=13 = Enter
                //   key=99 = 'c'（Ctrl+C 编成 99;5u）
                //   key=100 = 'd'（Ctrl+D 编成 100;5u）
                //   key=27 = Esc
                // 其他组合不识别，返 .unknown（状态已重置，不会污染后续）
                if (b == 'u') {
                    // Enter 特化
                    if (self.num1 == 13) {
                        return switch (self.num2) {
                            2 => .shift_enter,
                            5 => .ctrl_enter,
                            else => .enter,
                        };
                    }
                    // Ctrl+字母：mod=5 表示 Ctrl
                    if (self.num2 == 5) {
                        return switch (self.num1) {
                            99, 67 => .ctrl_c, // 'c' / 'C'
                            100, 68 => .ctrl_d, // 'd' / 'D'
                            97, 65 => .ctrl_a,
                            101, 69 => .ctrl_e,
                            107, 75 => .ctrl_k,
                            117, 85 => .ctrl_u,
                            else => .unknown,
                        };
                    }
                    return .unknown;
                }
                return .unknown;
            },
        }
    }
};

fn byteToKey(b: u8) Key {
    return switch (b) {
        '\r', '\n' => .enter,
        0x09 => .tab,
        0x12 => .ctrl_r,
        0x7f, 0x08 => .backspace,
        0x01 => .ctrl_a,
        0x03 => .ctrl_c,
        0x04 => .ctrl_d,
        0x05 => .ctrl_e,
        0x0b => .ctrl_k,
        0x15 => .ctrl_u,
        0x17 => .ctrl_w,
        0x19 => .ctrl_y,
        0x0c => .ctrl_l,
        // 可打印 ASCII：0x20-0x7E
        // UTF-8 多字节：0x80+（首字节 0xC0-0xFF，延续字节 0x80-0xBF）——逐字节作为 .char 透传
        // 终端在显示时会把完整 UTF-8 序列组合成一个字符
        else => if (b >= 0x20) Key{ .char = b } else .unknown,
    };
}

// ============================================================================
// Raw mode（termios）
// ============================================================================

/// 切 raw 模式，返回旧 termios；非 tty 或失败返 null。
/// 同时启用 xterm modifyOtherKeys / CSI u 协议，以区分 Shift+Enter / Ctrl+Enter。
/// 不支持 CSI u 的终端会忽略这条转义，行为无损。
pub fn enterRawMode(fd: std.c.fd_t) ?std.c.termios {
    var orig: std.c.termios = undefined;
    if (std.c.tcgetattr(fd, &orig) != 0) return null;

    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;

    if (std.c.tcsetattr(fd, std.posix.TCSA.FLUSH, &raw) != 0) return null;

    // 启用 xterm modifyOtherKeys mode 1：只编码 "普通方式无法表示的组合键"
    // （Shift+Enter、Ctrl+Enter）。mode 2 会把所有 Ctrl+字母也编码为 CSI u，
    // 导致 Ctrl+C 变成 `\x1b[99;5u` 被我们的状态机漏判→输出"99~"一类乱码。mode 1 更保守。
    const enable = "\x1b[>4;1m";
    _ = std.c.write(fd, enable.ptr, enable.len);

    // 启用 bracketed paste mode：粘贴内容被 ESC[200~ ... ESC[201~ 包裹，
    // 让我们能把"粘贴"和"逐字键入"区分开（大块粘贴存外部 + 占位符）。
    const enable_paste = "\x1b[?2004h";
    _ = std.c.write(fd, enable_paste.ptr, enable_paste.len);

    return orig;
}

pub fn restoreMode(fd: std.c.fd_t, orig: std.c.termios) void {
    // 关 bracketed paste + modifyOtherKeys
    const disable_paste = "\x1b[?2004l";
    _ = std.c.write(fd, disable_paste.ptr, disable_paste.len);
    const disable = "\x1b[>4;0m";
    _ = std.c.write(fd, disable.ptr, disable.len);
    _ = std.c.tcsetattr(fd, std.posix.TCSA.FLUSH, &orig);
}

// ============================================================================
// LineEditor：buffer + cursor，按 Key 产生 Action
// ============================================================================

pub const Action = enum {
    /// 继续（buffer 改变或 cursor 移动，调用方需重绘）
    redraw,
    /// 提交当前行（enter）
    commit,
    /// 用户取消（Ctrl+C：空 buffer 第一次 → 提示；非空 buffer → 丢弃回 prompt）
    cancel,
    /// 第一次 Ctrl+C 空 buffer 时——调用方应打印"按 Ctrl+C 再次退出"提示
    cancel_hint,
    /// 第二次连续 Ctrl+C（中间无其他按键）→ 退出 REPL
    exit_repl,
    /// 空输入 Ctrl+D → 主动退出 REPL；非空输入 Ctrl+D → 丢弃
    eof,
    /// 历史上一条
    history_prev,
    /// 历史下一条
    history_next,
    /// TAB：请求补全（调用方计算候选并回填 buffer）
    complete,
    /// Ctrl+R：进入反向历史搜索（调用方驱动搜索 UI）
    reverse_search,
    /// Ctrl+L：重绘屏幕(调用方清屏 + 重画 prompt + buffer)
    redraw_screen,
    /// Shift+Tab：cycle 权限模式(调用方改 app.config.permission_mode)
    cycle_perm_mode,
    /// 无语义变化（如 unknown 键）
    none,
};

pub const LineEditor = struct {
    buf: std.ArrayList(u8),
    cursor: usize = 0,
    allocator: std.mem.Allocator,
    /// 上一次按键是否是 Ctrl+C（用于"双击退出"语义）。任何其他按键重置为 false。
    ctrl_c_armed: bool = false,
    /// yank ring:Ctrl+W/K/U 删除的内容存这,Ctrl+Y 粘回。
    yank_buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) LineEditor {
        return .{ .buf = .empty, .allocator = allocator, .yank_buf = .empty };
    }

    pub fn deinit(self: *LineEditor) void {
        self.buf.deinit(self.allocator);
        self.yank_buf.deinit(self.allocator);
    }

    /// 输入一个 Key 并更新状态。返回对应 Action。
    pub fn handle(self: *LineEditor, key: Key) !Action {
        // "双击 Ctrl+C 退出" 语义：只有连续两次 Ctrl+C（中间无其他按键）才触发 exit_repl。
        // 非 ctrl_c 按键会重置 armed 标志。
        const was_armed = self.ctrl_c_armed;
        if (@as(std.meta.Tag(Key), key) != .ctrl_c) {
            self.ctrl_c_armed = false;
        }

        switch (key) {
            .char => |c| {
                try self.buf.insert(self.allocator, self.cursor, c);
                self.cursor += 1;
                return .redraw;
            },
            .enter => return .commit,
            .shift_enter, .ctrl_enter => {
                try self.buf.insert(self.allocator, self.cursor, '\n');
                self.cursor += 1;
                return .redraw;
            },
            .backspace => {
                if (self.cursor == 0) return .none;
                const start = prevCharBoundary(self.buf.items, self.cursor);
                const n = self.cursor - start;
                var i: usize = 0;
                while (i < n) : (i += 1) _ = self.buf.orderedRemove(start);
                self.cursor = start;
                return .redraw;
            },
            .delete => {
                if (self.cursor >= self.buf.items.len) return .none;
                const end = nextCharBoundary(self.buf.items, self.cursor);
                const n = end - self.cursor;
                var i: usize = 0;
                while (i < n) : (i += 1) _ = self.buf.orderedRemove(self.cursor);
                return .redraw;
            },
            .left => {
                if (self.cursor == 0) return .none;
                self.cursor = prevCharBoundary(self.buf.items, self.cursor);
                return .redraw;
            },
            .right => {
                if (self.cursor >= self.buf.items.len) return .none;
                self.cursor = nextCharBoundary(self.buf.items, self.cursor);
                return .redraw;
            },
            .home, .ctrl_a => {
                if (self.cursor == 0) return .none;
                self.cursor = 0;
                return .redraw;
            },
            .end, .ctrl_e => {
                if (self.cursor == self.buf.items.len) return .none;
                self.cursor = self.buf.items.len;
                return .redraw;
            },
            .ctrl_u => {
                if (self.cursor == 0) return .none;
                // 删除光标左边所有字符
                self.buf.replaceRangeAssumeCapacity(0, self.cursor, &.{});
                self.cursor = 0;
                return .redraw;
            },
            .ctrl_k => {
                if (self.cursor >= self.buf.items.len) return .none;
                self.buf.items.len = self.cursor; // 截断
                return .redraw;
            },
            .ctrl_c => {
                if (self.buf.items.len > 0) {
                    // buffer 非空 —— 清 buffer，不退出
                    self.ctrl_c_armed = false;
                    return .cancel;
                }
                // buffer 空
                if (was_armed) {
                    // 连续第二次 Ctrl+C —— 真的退出
                    self.ctrl_c_armed = false;
                    return .exit_repl;
                }
                // 第一次 Ctrl+C 且 buffer 空：arm + 提示
                self.ctrl_c_armed = true;
                return .cancel_hint;
            },
            .ctrl_d => {
                if (self.buf.items.len == 0) return .eof;
                return .none; // 非空时忽略（不删除字符，不像 delete）
            },
            .up => return .history_prev,
            .down => return .history_next,
            .tab => return .complete,
            .shift_tab => return .cycle_perm_mode,
            .ctrl_r => return .reverse_search,
            .ctrl_l => return .redraw_screen,
            .ctrl_w => {
                // 删上一个词:从 cursor 往前跳过空白,再删到上一个词边界
                if (self.cursor == 0) return .none;
                var start = self.cursor;
                while (start > 0 and self.buf.items[start - 1] == ' ') start -= 1;
                while (start > 0 and self.buf.items[start - 1] != ' ') start -= 1;
                try self.stashYank(self.buf.items[start..self.cursor]);
                const n = self.cursor - start;
                var i: usize = 0;
                while (i < n) : (i += 1) _ = self.buf.orderedRemove(start);
                self.cursor = start;
                return .redraw;
            },
            .ctrl_y => {
                if (self.yank_buf.items.len == 0) return .none;
                try self.buf.insertSlice(self.allocator, self.cursor, self.yank_buf.items);
                self.cursor += self.yank_buf.items.len;
                return .redraw;
            },
            .alt_b => {
                if (self.cursor == 0) return .none;
                var p = self.cursor;
                while (p > 0 and self.buf.items[p - 1] == ' ') p -= 1;
                while (p > 0 and self.buf.items[p - 1] != ' ') p -= 1;
                self.cursor = p;
                return .redraw;
            },
            .alt_f => {
                const len = self.buf.items.len;
                if (self.cursor >= len) return .none;
                var p = self.cursor;
                while (p < len and self.buf.items[p] == ' ') p += 1;
                while (p < len and self.buf.items[p] != ' ') p += 1;
                self.cursor = p;
                return .redraw;
            },
            // paste_begin/end 由驱动循环（loop.zig）直接处理，编辑器层忽略
            .paste_begin, .paste_end => return .none,
            .esc, .unknown => return .none,
        }
    }

    /// 把删除的内容存入 yank_buf(覆盖式,够用)。
    fn stashYank(self: *LineEditor, slice: []const u8) !void {
        self.yank_buf.clearRetainingCapacity();
        try self.yank_buf.appendSlice(self.allocator, slice);
    }

    /// 清空（用于 cancel / 历史覆盖写入）。
    pub fn reset(self: *LineEditor) void {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
    }

    /// 把 buffer 整体替换为给定字节（用于历史导航写回）。
    pub fn setLine(self: *LineEditor, line: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.allocator, line);
        self.cursor = self.buf.items.len;
    }

    pub fn view(self: *const LineEditor) []const u8 {
        return self.buf.items;
    }
};

/// UTF-8 continuation byte（高两位是 10）
inline fn isUtf8Continuation(b: u8) bool {
    return (b & 0b1100_0000) == 0b1000_0000;
}

/// 从 pos 向前找到前一个 UTF-8 字符起始位置。pos 必须在字符边界。
fn prevCharBoundary(bytes: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    while (p > 0 and isUtf8Continuation(bytes[p])) : (p -= 1) {}
    return p;
}

/// 从 pos 向后找到下一个 UTF-8 字符起始位置（即当前字符的末尾）。
fn nextCharBoundary(bytes: []const u8, pos: usize) usize {
    if (pos >= bytes.len) return bytes.len;
    var p = pos + 1;
    while (p < bytes.len and isUtf8Continuation(bytes[p])) : (p += 1) {}
    return p;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "KeyParser: ASCII char" {
    var p = KeyParser{};
    try testing.expect(p.feed('a').? == .char);
}

test "KeyParser: enter + backspace + ctrl" {
    var p = KeyParser{};
    try testing.expect(p.feed('\n').? == .enter);
    try testing.expect(p.feed(0x7f).? == .backspace);
    try testing.expect(p.feed(0x03).? == .ctrl_c);
    try testing.expect(p.feed(0x04).? == .ctrl_d);
}

test "KeyParser: arrow keys sequence" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed('[') == null);
    try testing.expect(p.feed('A').? == .up);
}

test "KeyParser: delete (ESC [ 3 ~)" {
    var p = KeyParser{};
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('3');
    try testing.expect(p.feed('~').? == .delete);
}

test "LineEditor: insert chars" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'h' });
    _ = try ed.handle(Key{ .char = 'i' });
    try testing.expectEqualStrings("hi", ed.view());
    try testing.expect(ed.cursor == 2);
}

test "LineEditor: backspace" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'a' });
    _ = try ed.handle(Key{ .char = 'b' });
    _ = try ed.handle(.backspace);
    try testing.expectEqualStrings("a", ed.view());
    try testing.expect(ed.cursor == 1);
}

test "LineEditor: backspace at beginning no-op" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    const a = try ed.handle(.backspace);
    try testing.expect(a == .none);
}

test "LineEditor: cursor left/right" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("abc") |c| _ = try ed.handle(Key{ .char = c });
    _ = try ed.handle(.left);
    try testing.expect(ed.cursor == 2);
    _ = try ed.handle(.left);
    _ = try ed.handle(.left);
    try testing.expect(ed.cursor == 0);
    const a = try ed.handle(.left);
    try testing.expect(a == .none);
    _ = try ed.handle(.right);
    try testing.expect(ed.cursor == 1);
}

test "LineEditor: home / end" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("hello") |c| _ = try ed.handle(Key{ .char = c });
    try testing.expect(ed.cursor == 5);
    _ = try ed.handle(.home);
    try testing.expect(ed.cursor == 0);
    _ = try ed.handle(.end);
    try testing.expect(ed.cursor == 5);
}

test "LineEditor: ctrl_a / ctrl_e" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("xyz") |c| _ = try ed.handle(Key{ .char = c });
    _ = try ed.handle(.ctrl_a);
    try testing.expect(ed.cursor == 0);
    _ = try ed.handle(.ctrl_e);
    try testing.expect(ed.cursor == 3);
}

test "LineEditor: insert mid-line" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("ac") |c| _ = try ed.handle(Key{ .char = c });
    _ = try ed.handle(.left);
    _ = try ed.handle(Key{ .char = 'b' });
    try testing.expectEqualStrings("abc", ed.view());
    try testing.expect(ed.cursor == 2);
}

test "LineEditor: delete" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("abc") |c| _ = try ed.handle(Key{ .char = c });
    _ = try ed.handle(.home);
    _ = try ed.handle(.delete);
    try testing.expectEqualStrings("bc", ed.view());
    try testing.expect(ed.cursor == 0);
}

test "LineEditor: ctrl_u kills line to start" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("hello world") |c| _ = try ed.handle(Key{ .char = c });
    // cursor at end: position 11. 先左移到 6
    for (0..5) |_| _ = try ed.handle(.left);
    try testing.expect(ed.cursor == 6);
    _ = try ed.handle(.ctrl_u); // 删除 [0,6) → "world"
    try testing.expectEqualStrings("world", ed.view());
    try testing.expect(ed.cursor == 0);
}

test "LineEditor: ctrl_k kills to end" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("hello world") |c| _ = try ed.handle(Key{ .char = c });
    _ = try ed.handle(.home);
    for (0..5) |_| _ = try ed.handle(.right);
    _ = try ed.handle(.ctrl_k); // 删 " world"
    try testing.expectEqualStrings("hello", ed.view());
}

test "LineEditor: enter -> commit" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'a' });
    const a = try ed.handle(.enter);
    try testing.expect(a == .commit);
}

test "LineEditor: ctrl_c with non-empty buffer cancels" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'a' });
    const a = try ed.handle(.ctrl_c);
    try testing.expect(a == .cancel);
}

test "LineEditor: first ctrl_c on empty buffer hints" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    const a = try ed.handle(.ctrl_c);
    try testing.expect(a == .cancel_hint);
    try testing.expect(ed.ctrl_c_armed);
}

test "LineEditor: double ctrl_c on empty buffer exits" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try testing.expect((try ed.handle(.ctrl_c)) == .cancel_hint);
    try testing.expect((try ed.handle(.ctrl_c)) == .exit_repl);
    try testing.expect(!ed.ctrl_c_armed);
}

test "LineEditor: ctrl_c armed is reset by any other key" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(.ctrl_c); // armed
    try testing.expect(ed.ctrl_c_armed);
    _ = try ed.handle(Key{ .char = 'x' });
    try testing.expect(!ed.ctrl_c_armed);
    // 再按 ctrl_c 应该回到 cancel_hint（因为 buffer 已经有 'x' 了，cancel buffer）
    try testing.expect((try ed.handle(.ctrl_c)) == .cancel);
}

test "LineEditor: ctrl_d empty -> eof" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    const a = try ed.handle(.ctrl_d);
    try testing.expect(a == .eof);
}

test "LineEditor: ctrl_d non-empty -> none" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'a' });
    const a = try ed.handle(.ctrl_d);
    try testing.expect(a == .none);
}

test "LineEditor: up/down -> history actions" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try testing.expect((try ed.handle(.up)) == .history_prev);
    try testing.expect((try ed.handle(.down)) == .history_next);
}

test "LineEditor: setLine / reset" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try ed.setLine("history line");
    try testing.expectEqualStrings("history line", ed.view());
    try testing.expect(ed.cursor == 12);
    ed.reset();
    try testing.expect(ed.view().len == 0);
    try testing.expect(ed.cursor == 0);
}

test "LineEditor: insert UTF-8 bytes (Chinese)" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    // 你 = 0xE4 0xBD 0xA0（3 字节 UTF-8）
    for ([_]u8{ 0xE4, 0xBD, 0xA0 }) |b| _ = try ed.handle(Key{ .char = b });
    try testing.expectEqualStrings("你", ed.view());
    try testing.expect(ed.cursor == 3);
}

test "LineEditor: backspace removes whole UTF-8 char" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ([_]u8{ 0xE4, 0xBD, 0xA0 }) |b| _ = try ed.handle(Key{ .char = b }); // 你
    for ([_]u8{ 0xE5, 0xA5, 0xBD }) |b| _ = try ed.handle(Key{ .char = b }); // 好
    try testing.expectEqualStrings("你好", ed.view());
    try testing.expect(ed.cursor == 6);
    _ = try ed.handle(.backspace);
    try testing.expectEqualStrings("你", ed.view());
    try testing.expect(ed.cursor == 3);
}

test "LineEditor: left moves by whole UTF-8 char" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ([_]u8{ 0xE4, 0xBD, 0xA0 }) |b| _ = try ed.handle(Key{ .char = b });
    for ([_]u8{ 0xE5, 0xA5, 0xBD }) |b| _ = try ed.handle(Key{ .char = b });
    try testing.expect(ed.cursor == 6);
    _ = try ed.handle(.left);
    try testing.expect(ed.cursor == 3); // 跳过 "好" 的 3 字节
    _ = try ed.handle(.left);
    try testing.expect(ed.cursor == 0);
}

test "LineEditor: delete removes whole UTF-8 char" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ([_]u8{ 0xE4, 0xBD, 0xA0 }) |b| _ = try ed.handle(Key{ .char = b });
    for ([_]u8{ 0xE5, 0xA5, 0xBD }) |b| _ = try ed.handle(Key{ .char = b });
    _ = try ed.handle(.home);
    _ = try ed.handle(.delete);
    try testing.expectEqualStrings("好", ed.view());
}

test "KeyParser: UTF-8 byte passes through as .char" {
    var p = KeyParser{};
    // 中文 "啊" = 0xE5 0x95 0x8A
    const e5 = p.feed(0xE5).?;
    try testing.expect(@as(std.meta.Tag(Key), e5) == .char);
    try testing.expect(e5.char == 0xE5);
}

test "KeyParser: Shift+Enter via CSI u" {
    var p = KeyParser{};
    // ESC [ 1 3 ; 2 u
    for ([_]u8{ 0x1b, '[', '1', '3', ';', '2' }) |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.feed('u').? == .shift_enter);
}

test "KeyParser: Ctrl+Enter via CSI u" {
    var p = KeyParser{};
    for ([_]u8{ 0x1b, '[', '1', '3', ';', '5' }) |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.feed('u').? == .ctrl_enter);
}

test "KeyParser: CSI Delete still works" {
    var p = KeyParser{};
    for ([_]u8{ 0x1b, '[', '3' }) |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.feed('~').? == .delete);
}

test "KeyParser: CSI u with unknown mod falls back to Enter" {
    var p = KeyParser{};
    // ESC [ 13 ; 3 u  (mod=3 = Alt，我们不关心)
    for ([_]u8{ 0x1b, '[', '1', '3', ';', '3' }) |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.feed('u').? == .enter);
}

test "LineEditor: shift_enter inserts newline without commit" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'a' });
    const action = try ed.handle(.shift_enter);
    try testing.expect(action == .redraw);
    try testing.expectEqualStrings("a\n", ed.view());
    _ = try ed.handle(Key{ .char = 'b' });
    try testing.expectEqualStrings("a\nb", ed.view());
    // 真 enter 才 commit
    try testing.expect((try ed.handle(.enter)) == .commit);
}

test "LineEditor: ctrl_enter inserts newline" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'x' });
    _ = try ed.handle(.ctrl_enter);
    try testing.expectEqualStrings("x\n", ed.view());
}

test "LineEditor: no-op actions (esc / unknown)" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try testing.expect((try ed.handle(.esc)) == .none);
    try testing.expect((try ed.handle(.unknown)) == .none);
}

fn typeStr(ed: *LineEditor, s: []const u8) !void {
    for (s) |c| _ = try ed.handle(Key{ .char = c });
}

test "LineEditor: ctrl_w deletes previous word" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "hello world foo");
    _ = try ed.handle(.ctrl_w);
    try testing.expectEqualStrings("hello world ", ed.view());
    _ = try ed.handle(.ctrl_w);
    try testing.expectEqualStrings("hello ", ed.view());
}

test "LineEditor: ctrl_y yanks back ctrl_w deletion" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "alpha beta");
    _ = try ed.handle(.ctrl_w); // 删 "beta"
    try testing.expectEqualStrings("alpha ", ed.view());
    _ = try ed.handle(.ctrl_y); // 粘回
    try testing.expectEqualStrings("alpha beta", ed.view());
}

test "LineEditor: alt_b / alt_f word navigation" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "one two three");
    // cursor 在末尾
    _ = try ed.handle(.alt_b); // 回到 "three" 开头
    try testing.expectEqual(@as(usize, 8), ed.cursor); // "one two " = 8
    _ = try ed.handle(.alt_b); // "two" 开头
    try testing.expectEqual(@as(usize, 4), ed.cursor);
    _ = try ed.handle(.alt_f); // 跳过 "two" 到下个词末
    try testing.expectEqual(@as(usize, 7), ed.cursor);
}

test "LineEditor: shift_tab returns cycle_perm_mode" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try testing.expect((try ed.handle(.shift_tab)) == .cycle_perm_mode);
}

test "LineEditor: ctrl_l returns redraw_screen" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try testing.expect((try ed.handle(.ctrl_l)) == .redraw_screen);
}

test "KeyParser: shift_tab via ESC [ Z" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed('[') == null);
    try testing.expect(p.feed('Z').? == .shift_tab);
}

test "KeyParser: alt_b / alt_f via ESC b / ESC f" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed('b').? == .alt_b);
    var p2 = KeyParser{};
    try testing.expect(p2.feed(0x1b) == null);
    try testing.expect(p2.feed('f').? == .alt_f);
}

test "KeyParser: ctrl_w / ctrl_y / ctrl_l bytes" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x17).? == .ctrl_w);
    try testing.expect(p.feed(0x19).? == .ctrl_y);
    try testing.expect(p.feed(0x0c).? == .ctrl_l);
}

test "LineEditor: multi-key stream through KeyParser" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    var p = KeyParser{};
    const stream = "abc";
    for (stream) |b| {
        if (p.feed(b)) |k| _ = try ed.handle(k);
    }
    try testing.expectEqualStrings("abc", ed.view());
}

test "enterRawMode on non-tty returns null or restores cleanly" {
    const orig = enterRawMode(0);
    if (orig) |o| restoreMode(0, o);
}
