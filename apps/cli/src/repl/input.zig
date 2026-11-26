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
const ppaths = @import("metacodes-internal").platform.paths;
const pfs = @import("metacodes-internal").platform.fs;
const platform_term = @import("metacodes-internal").platform.terminal;
const win32_input = @import("metacodes-internal").platform.win32_input;
const platform_signal = @import("metacodes-internal").platform.signal;
const process = @import("metacodes-internal").platform.process;
const shutdown = @import("metacodes-internal").core.shutdown;
const bg_probe = @import("tui/bg_probe.zig");
const util_time = @import("metacodes-internal").util.time;

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
    page_up, // ESC[5~（agent viewing 视口翻页）
    page_down, // ESC[6~
    esc,
    tab,
    shift_tab, // cycle 权限模式
    ctrl_r,
    ctrl_t, // 切换任务列表显示
    ctrl_o, // 打开 transcript viewer
    ctrl_b, // 生成期:把主对话转后台续跑(run in background)
    ctrl_x, // Ctrl+X 前缀(配合 Ctrl+K kill 后台)
    ctrl_g, // 外部编辑器编辑当前 buffer
    ctrl_underscore, // Ctrl+_ / Ctrl+Shift+- (0x1f): undo
    paste_begin, // 括号粘贴起始 ESC[200~
    paste_end, // 括号粘贴结束 ESC[201~
    mouse: Mouse,
    cursor_position: CursorPosition,
    unknown,
};

pub const Mouse = struct {
    code: u16,
    col: u16,
    row: u16,
    released: bool,

    pub fn wheel(self: Mouse) ?enum { up, down } {
        if (self.code & 64 == 0) return null;
        return if (self.code & 1 == 0) .up else .down;
    }

    pub fn leftButton(self: Mouse) bool {
        return self.code & (3 | 64) == 0;
    }

    pub fn motion(self: Mouse) bool {
        return self.code & 32 != 0;
    }
};

pub const CursorPosition = struct {
    row: u16,
    col: u16,
};

pub fn pastedByte(key: Key) ?u8 {
    return switch (key) {
        .char => |c| c,
        .enter => '\n',
        .tab => '\t',
        else => null,
    };
}

/// 按字节喂的 CSI 状态机解析器（见 M4.1 spike）。
///
/// 支持的 CSI 序列：
///   ESC [ A/B/C/D     ↑↓→←
///   ESC [ H / F、ESC [ 1/7 ~ / 4/8 ~   Home / End
///   ESC [ 3 ~         Delete
///   ESC [ 1;<mod> A–D/H/F、ESC [ 1/3/4/5/6/7/8;<mod> ~   <mod> 只带 Caps Lock(64)/Num Lock(128) 时同不带 <mod>
///   ESC [ <num>;<mod> u   CSI u（kitty 键盘协议）
///   ESC [ 27;<mod>;<num> ~  xterm modifyOtherKeys,与 CSI u 同一张表(decodeModifiedKey)
///     - 9;2 = Shift+Tab
///     - 13;2 = Shift+Enter
///     - 13;5 = Ctrl+Enter
///   ESC [ < b;x;y M/m  SGR 鼠标报告(按下/拖动 M,松开 m)→ .mouse
///   ESC [ row;col R   光标位置应答(DSR 6n)→ .cursor_position
///   ESC CR            Meta+Return = Shift+Enter(/terminal-setup 装进终端的绑定),仅当两字节
///                     同批到达(feedRead / feedQueued);一字节一字节的 feed 仍是 Esc + Enter
/// 其它 CSI(私有前缀、更多参数段、认不出的组合)整条吃掉、报一个 .unknown;OSC 应答(`ESC ] 11 ; … BEL`)
/// 同样整条吃掉——终端应答不会漏成字符。
pub const KeyParser = struct {
    state: State = .normal,
    num1: u32 = 0,
    num2: u32 = 0,
    num3: u32 = 0,
    mouse_field: u8 = 0,
    // 一字节 feed 偶尔需吐多个键(ESC 后紧跟普通字符 = 孤立 ESC + 该字符;`ESC ]` 后不是
    // OSC 应答 = ESC + ']' + 数字 + 下一个键):feed 返回第一个,其余按序暂存这里,
    // 调用方 feed / flushEsc 后须 while(drain())|k| 排空。
    queued: [queue_capacity]Key = undefined,
    queued_head: u8 = 0,
    queued_len: u8 = 0,
    // `ESC ]` 之后的数字(OSC 编号,至多 3 位):不是应答时原样还成键。
    osc_digits: [3]u8 = undefined,
    osc_digits_len: u8 = 0,
    // 待定 ESC 读进来时,后面的字节是否已在输入队列里(feedRead 查 waitReadable(fd, 0))。终端把
    // Meta+Return 一次写出 ESC CR,读到 ESC 时 CR 已在队列;人先按 Esc 再按 Enter 是两次输入。
    esc_burst: bool = false,
    in_bracketed_paste: bool = false,
    burst: Burst = .{},

    // ']' + 3 位数字 + 截断它的那个键。
    const queue_capacity = 5;

    // csi_skip:一个认不出的 CSI(私有前缀 `?`/`>`/`=`、不成形的 `<` 鼠标报告、四段以上参数、`:` 子参数),
    // 吃到它的终结字节(0x40-0x7E)为止,整条报一个 .unknown。终端应答(DA1 `ESC[?62c`、
    // Kitty flags `ESC[?1u`)晚于启动探测才到也走这里——
    // 否则后半截会被当成敲进来的字符("62c" 进了输入框)。
    // osc_seen/osc_ps/osc_body/osc_st:`ESC ] Ps ; Pt (BEL | ESC \)`,终端的 OSC 应答(探测问的
    // 背景色 `ESC]11;rgb:…`)。只认数字编号 + `;` 开头的形状:Alt+] 之后敲别的(包括什么都不敲、
    // 等到 ESC 超时)仍是原来那几个键。迟到的背景色应答以前会变成 Esc、字符、Esc——两次 Esc
    // 连按清空了输入框。
    const State = enum { normal, esc_seen, csi_seen, csi_num1, csi_semi, csi_num2, csi_semi2, csi_num3, csi_skip, sgr_mouse, osc_seen, osc_ps, osc_body, osc_st };

    /// CSI 的参数/中间字节(0x20-0x3F):数字、`;`、`:`、私有前缀 `<=>?`、空格../。
    fn csiParam(b: u8) bool {
        return b >= 0x20 and b <= 0x3f;
    }

    /// 数字参数之后的 `$`:rxvt 系(urxvt、Eterm、aterm)Shift 组合键的终结字节(Shift+Delete
    /// `ESC[3$`、Shift+Home/End `ESC[7$`/`ESC[8$`、Shift+F11 `ESC[23$`)。按标准它是中间字节,
    /// 当成中间字节的话 parser 会把用户接着敲的字母当终结字节吃掉。
    fn rxvtShiftFinal(b: u8) bool {
        return b == '$';
    }

    /// 是否正读到一个序列中间(已收 ESC,等后续字节),包括 CSI 参数和 OSC 正文。
    /// 调用方(watcher)在 read 超时时若此为 true,应调 flushEsc():终端一次写出整个序列,
    /// 等一个读周期都没来的后半截不会再来了(被下一次进 raw 的 TCSAFLUSH 丢了,或根本是
    /// 用户按的 Esc)。
    pub fn pendingEsc(self: *const KeyParser) bool {
        return self.state != .normal;
    }

    /// 取出 feed / flushEsc 暂存的下一个键(若有)。调用方每次 feed 后循环 drain 至 null。
    /// 用于 ESC + 普通字符这类一次 feed 产出多键的场景(否则后面的字符被吞)。
    pub fn drain(self: *KeyParser) ?Key {
        if (self.queued_len == 0) return null;
        const k = self.queued[self.queued_head];
        self.queued_head = (self.queued_head + 1) % queue_capacity;
        self.queued_len -= 1;
        return k;
    }

    fn push(self: *KeyParser, k: Key) void {
        // 一次 feed 至多产出 queue_capacity 个键,调用方排空后才再喂:装不下 = 调用方漏了排空,
        // 宁丢这个键也不越界。
        std.debug.assert(self.queued_len < queue_capacity);
        if (self.queued_len == queue_capacity) return;
        self.queued[(self.queued_head + self.queued_len) % queue_capacity] = k;
        self.queued_len += 1;
    }

    /// 读周期超时、序列的后半截没来(见 pendingEsc):兑现读到的部分,parser 回到 normal。
    /// - 孤立 ESC → .esc;`ESC ]`(Alt+])及其后的数字 → .esc,']' 与数字随后 drain 出;
    ///   OSC 正文里的 ESC 等不来 `\` → 那个 ESC 是用户按的 Esc,返回 .esc。
    /// - CSI 参数、OSC 正文读到一半 → 整条作废,返回 null(不产生键)。
    /// 不在序列中间返 null。
    pub fn flushEsc(self: *KeyParser) ?Key {
        const key: ?Key = switch (self.state) {
            .normal => return null,
            .esc_seen, .osc_st => .esc,
            .osc_seen, .osc_ps => blk: {
                self.queueOscPrefix();
                break :blk .esc;
            },
            .csi_seen, .csi_num1, .csi_semi, .csi_num2, .csi_semi2, .csi_num3, .csi_skip, .sgr_mouse, .osc_body => null,
        };
        self.state = .normal;
        return key;
    }

    /// `ESC ]` 和其后的数字不是 OSC 应答:']' 和数字作为键排队(.esc 由调用方返回)。
    fn queueOscPrefix(self: *KeyParser) void {
        self.push(.{ .char = ']' });
        for (self.osc_digits[0..self.osc_digits_len]) |d| self.push(.{ .char = d });
    }

    /// 从终端读到的一个字节:ESC 时记下它后面是否已有字节在等(同一批写入)。读终端的调用方用它;
    /// 括号粘贴里的字节用 feed(粘贴内容按原样,ESC CR 不当换行键)。Windows 控制台开着
    /// win32-input-mode 时,人按的 Esc 是一条按键记录(platform_term.lastReadWasKeyRecord),
    /// 不管后面排着什么都不算同批:Esc 之后紧跟的 Enter 记录也已在队列里。终端一次写出的
    /// ESC CR(VS Code 的绑定)经 ConPTY 原样是两个字节,照旧算。
    pub fn feedRead(self: *KeyParser, fd: c_int, b: u8) ?Key {
        return self.feedQueued(b, b == 0x1b and !platform_term.lastReadWasKeyRecord() and platform_term.waitReadable(fd, 0) > 0);
    }

    pub fn feedEditorRead(self: *KeyParser, fd: c_int, b: u8) ?Key {
        const now_ns = util_time.nowNs();
        const gap_ms = self.burst.gapMs(now_ns);
        const queued = platform_term.waitReadable(fd, 0) > 0;
        var lookahead: FdLookahead = .{ .fd = fd, .queued_after = queued };
        const key = self.feedArrived(b, gap_ms, b == 0x1b and !platform_term.lastReadWasKeyRecord() and queued, &lookahead);
        self.burst.last_ns = util_time.nowNs();
        self.burst.next_queued = lookahead.queued_after;
        return key;
    }

    fn feedTimed(self: *KeyParser, b: u8, gap_ms: u64, next: ?NextArrival) ?Key {
        var lookahead: GapLookahead = .{ .next = next };
        return self.feedArrived(b, gap_ms, if (next) |n| n.gap_ms == 0 else false, &lookahead);
    }

    fn feedArrived(self: *KeyParser, b: u8, gap_ms: u64, more_queued: bool, lookahead: anytype) ?Key {
        const fast = gap_ms <= paste_burst_gap_ms;
        if (!fast) self.burst.newline_seen = false;
        const lf_closes_newline = self.burst.lf_closes_newline;
        self.burst.lf_closes_newline = false;
        const outside_paste_markers = self.state == .normal and !self.in_bracketed_paste;
        const key = self.feedQueued(b, more_queued) orelse return null;
        if (!outside_paste_markers or key != .enter or (b != '\r' and b != '\n')) return key;
        if (b == '\n' and fast and lf_closes_newline) return null;
        const pasted = (fast and self.burst.newline_seen) or lookahead.moreInputAfter(b, paste_burst_gap_ms);
        self.burst.lf_closes_newline = b == '\r' and !lookahead.tookLf();
        self.burst.newline_seen = pasted;
        if (lookahead.carried()) |next| self.feedCarried(next, lookahead.escQueued());
        return if (pasted) .shift_enter else key;
    }

    fn feedCarried(self: *KeyParser, b: u8, more_queued: bool) void {
        self.burst.lf_closes_newline = b == '\r';
        if (self.state == .normal and !self.in_bracketed_paste and (b == '\r' or b == '\n')) {
            self.push(.shift_enter);
            return;
        }
        if (self.feedQueued(b, more_queued)) |key| self.push(key);
    }

    fn pasteMarker(self: *KeyParser, marker: Key) Key {
        self.in_bracketed_paste = marker == .paste_begin;
        self.burst = .{};
        return marker;
    }

    /// feedRead 去掉终端:`more_queued` = 这个字节读进来时后面已有字节在等(仅对 ESC 有意义)。
    pub fn feedQueued(self: *KeyParser, b: u8, more_queued: bool) ?Key {
        const key = self.feed(b);
        if (b == 0x1b) self.esc_burst = more_queued;
        return key;
    }

    pub fn feed(self: *KeyParser, b: u8) ?Key {
        if (b == 0x1b) self.esc_burst = false;
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
                    self.num3 = 0;
                    return null;
                }
                if (b == ']') {
                    self.state = .osc_seen;
                    self.osc_digits_len = 0;
                    return null;
                }
                self.state = .normal;
                // Alt+key:ESC 后紧跟字母(meta)。Alt+B / Alt+F 词导航——是单个组合键,不拆。
                switch (b) {
                    'b', 'B' => return .alt_b,
                    'f', 'F' => return .alt_f,
                    // 同批到达的 ESC CR(Meta+Return)= 换行,同 Kitty 的 13;2u:/terminal-setup 让
                    // Apple Terminal 的 Shift+Return、VS Code 的 shift+enter 发的就是它(Claude Code 的
                    // VS Code 绑定同款;xterm/VTE/Konsole/Alacritty 的 Alt+Enter 也是)。分两次到达的是
                    // 人按的 Esc 再按 Enter:照旧两个键(vim 回 NORMAL 后提交、反向搜索取消)。
                    '\r' => if (self.esc_burst) return .shift_enter,
                    else => {},
                }
                // ESC ESC:第二个 ESC 重新开始一个待定序列。兑现第一个 .esc,自身回 esc_seen
                // 等后续字节(否则双击 Esc 的第二下会被当 .unknown 丢掉)。
                if (b == 0x1b) {
                    self.state = .esc_seen;
                    return .esc;
                }
                // 其它字符:这是"孤立 ESC + 该字符"两个独立键(用户极快连打,或终端把
                // 两次按键合批送来)。兑现 ESC 为本次返回值,该字符的键暂存 pending,
                // 调用方 while(drain()) 取出——否则该字符被吞(早期 bug)。
                self.push(byteToKey(b));
                return .esc;
            },
            .csi_seen => {
                if (b >= '0' and b <= '9') {
                    self.num1 = b - '0';
                    self.state = .csi_num1;
                    return null;
                }
                if (b == '<') {
                    self.state = .sgr_mouse;
                    self.mouse_field = 0;
                    return null;
                }
                if (csiParam(b)) {
                    self.state = .csi_skip;
                    return null;
                }
                self.state = .normal;
                return switch (b) {
                    'Z' => .shift_tab, // ESC [ Z = Shift+Tab(backtab)
                    else => cursorKey(b),
                };
            },
            .csi_num1 => {
                if (b >= '0' and b <= '9') {
                    // 饱和:十位以上的参数不是任何认得的键,停在上限仍是 .unknown(不溢出 panic)。
                    self.num1 = self.num1 *| 10 +| (b - '0');
                    return null;
                }
                if (b == ';') {
                    self.state = .csi_semi;
                    return null;
                }
                if (rxvtShiftFinal(b)) {
                    self.state = .normal;
                    return .unknown;
                }
                if (csiParam(b)) {
                    self.state = .csi_skip;
                    return null;
                }
                // 终结字符
                self.state = .normal;
                if (b == '~') {
                    return switch (self.num1) {
                        200 => self.pasteMarker(.paste_begin),
                        201 => self.pasteMarker(.paste_end),
                        else => tildeKey(self.num1),
                    };
                }
                // 无 modifier 的 CSI-u(ESC[<cp>u,无 ;mod):Kitty disambiguate 模式下
                // Enter/Esc/纯文本也可能编成 CSI-u。还原成对应键,避免被当 .unknown 吞掉。
                if (b == 'u') return decodeModifiedKey(self.num1, .none);
                return .unknown;
            },
            .csi_semi => {
                if (b >= '0' and b <= '9') {
                    self.num2 = b - '0';
                    self.state = .csi_num2;
                    return null;
                }
                if (rxvtShiftFinal(b)) {
                    self.state = .normal;
                    return .unknown;
                }
                if (csiParam(b)) {
                    self.state = .csi_skip;
                    return null;
                }
                self.state = .normal;
                return .unknown;
            },
            .csi_num2 => {
                if (b >= '0' and b <= '9') {
                    self.num2 = self.num2 *| 10 +| (b - '0');
                    return null;
                }
                if (b == ';') {
                    self.state = .csi_semi2;
                    return null;
                }
                if (rxvtShiftFinal(b)) {
                    self.state = .normal;
                    return .unknown;
                }
                if (csiParam(b)) {
                    self.state = .csi_skip;
                    return null;
                }
                self.state = .normal;
                if (b == 'R') return .{ .cursor_position = .{ .row = saturate16(self.num1), .col = saturate16(self.num2) } };
                const modifier = KeyModifier.fromParam(self.num2);
                if (b == 'u') return decodeModifiedKey(self.num1, modifier);
                if (modifier != KeyModifier.none) return .unknown;
                if (b == '~') return tildeKey(self.num1);
                return if (self.num1 == 1) cursorKey(b) else .unknown;
            },
            .csi_semi2 => {
                if (b >= '0' and b <= '9') {
                    self.num3 = b - '0';
                    self.state = .csi_num3;
                    return null;
                }
                if (rxvtShiftFinal(b)) {
                    self.state = .normal;
                    return .unknown;
                }
                if (csiParam(b)) {
                    self.state = .csi_skip;
                    return null;
                }
                self.state = .normal;
                return .unknown;
            },
            .csi_num3 => {
                if (b >= '0' and b <= '9') {
                    self.num3 = self.num3 *| 10 +| (b - '0');
                    return null;
                }
                if (rxvtShiftFinal(b)) {
                    self.state = .normal;
                    return .unknown;
                }
                if (csiParam(b)) {
                    self.state = .csi_skip;
                    return null;
                }
                self.state = .normal;
                if (b == '~' and self.num1 == 27) return decodeModifiedKey(self.num3, KeyModifier.fromParam(self.num2));
                return .unknown;
            },
            .sgr_mouse => {
                if (b >= '0' and b <= '9') {
                    const field = switch (self.mouse_field) {
                        0 => &self.num1,
                        1 => &self.num2,
                        else => &self.num3,
                    };
                    field.* = field.* *| 10 +| (b - '0');
                    return null;
                }
                if (b == ';' and self.mouse_field < 2) {
                    self.mouse_field += 1;
                    return null;
                }
                if ((b == 'M' or b == 'm') and self.mouse_field == 2) {
                    self.state = .normal;
                    return .{ .mouse = .{ .code = saturate16(self.num1), .col = saturate16(self.num2), .row = saturate16(self.num3), .released = b == 'm' } };
                }
                self.state = .csi_skip;
                return self.feed(b);
            },
            .csi_skip => {
                if (csiParam(b)) return null;
                self.state = .normal;
                if (b >= 0x40 and b <= 0x7e) return .unknown; // 终结字节:整条认不出的序列
                // 不是 CSI 的字节,序列到此为止:这个字节是下一个键(ESC 开新序列,控制键照常)。
                if (b == 0x1b) {
                    self.state = .esc_seen;
                    return .unknown;
                }
                return byteToKey(b);
            },
            .osc_seen, .osc_ps => {
                if (b >= '0' and b <= '9' and self.osc_digits_len < self.osc_digits.len) {
                    self.osc_digits[self.osc_digits_len] = b;
                    self.osc_digits_len += 1;
                    self.state = .osc_ps;
                    return null;
                }
                if (b == ';' and self.state == .osc_ps) {
                    self.state = .osc_body;
                    return null;
                }
                // 不是 OSC 应答:Alt+](和其后敲的数字)是键,b 是下一个键。
                self.queueOscPrefix();
                self.state = .normal;
                if (self.feed(b)) |k| self.push(k);
                return .esc;
            },
            .osc_body => switch (b) {
                0x07 => {
                    self.state = .normal;
                    return .unknown; // BEL 结尾:整条应答
                },
                0x1b => {
                    self.state = .osc_st;
                    return null;
                },
                // 应答里不会有的控制字节:序列到此为止,这个字节是下一个键(Enter、Ctrl+C 照常)。
                0x00...0x06, 0x08...0x1a, 0x1c...0x1f => {
                    self.state = .normal;
                    return byteToKey(b);
                },
                else => return null,
            },
            .osc_st => {
                if (b == '\\') {
                    self.state = .normal;
                    return .unknown; // ST 结尾:整条应答
                }
                // ESC 开了别的序列:应答就此作废,ESC + b 照常解析。
                self.state = .esc_seen;
                return self.feed(b);
            },
        }
    }
};

pub const paste_burst_gap_ms: u64 = 10;

const Burst = struct {
    last_ns: ?util_time.Nanos = null,
    next_queued: bool = false,
    newline_seen: bool = false,
    lf_closes_newline: bool = false,

    fn gapMs(self: Burst, now_ns: util_time.Nanos) u64 {
        const last = self.last_ns orelse return std.math.maxInt(u64);
        if (self.next_queued) return 0;
        return @intCast(@divTrunc(@max(now_ns - last, 0), std.time.ns_per_ms));
    }
};

const FdLookahead = struct {
    fd: c_int,
    queued_after: bool,
    took_lf: bool = false,
    carried_byte: ?u8 = null,
    esc_queued: bool = false,

    fn moreInputAfter(self: *FdLookahead, b: u8, ms: u64) bool {
        if (platform_term.waitReadable(self.fd, @intCast(ms)) <= 0) return false;
        self.queued_after = true;
        if (b != '\r') return true;
        var next: [1]u8 = undefined;
        if (platform_term.readInput(self.fd, &next) != 1) return true; // no EINTR: waitReadable reported data
        if (next[0] != '\n') {
            self.carried_byte = next[0];
            self.queued_after = platform_term.waitReadable(self.fd, 0) > 0;
            self.esc_queued = next[0] == 0x1b and !platform_term.lastReadWasKeyRecord() and self.queued_after;
            return true;
        }
        self.took_lf = true;
        self.queued_after = platform_term.waitReadable(self.fd, @intCast(ms)) > 0;
        return self.queued_after;
    }

    fn tookLf(self: *const FdLookahead) bool {
        return self.took_lf;
    }

    fn carried(self: *const FdLookahead) ?u8 {
        return self.carried_byte;
    }

    fn escQueued(self: *const FdLookahead) bool {
        return self.esc_queued;
    }
};

const NextArrival = struct { byte: u8, gap_ms: u64, after_gap_ms: ?u64 };

const GapLookahead = struct {
    next: ?NextArrival,

    fn moreInputAfter(self: *GapLookahead, b: u8, ms: u64) bool {
        const next = self.next orelse return false;
        if (next.gap_ms > ms) return false;
        if (b == '\r' and next.byte == '\n') return if (next.after_gap_ms) |gap| gap <= ms else false;
        return true;
    }

    fn tookLf(_: *const GapLookahead) bool {
        return false;
    }

    fn carried(_: *const GapLookahead) ?u8 {
        return null;
    }

    fn escQueued(_: *const GapLookahead) bool {
        return false;
    }
};

fn saturate16(value: u32) u16 {
    return @intCast(@min(value, std.math.maxInt(u16)));
}

const KeyModifier = packed struct(u32) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    unassigned: u24 = 0,

    const none: KeyModifier = .{};
    const shift_only: KeyModifier = .{ .shift = true };
    const alt_only: KeyModifier = .{ .alt = true };
    const ctrl_only: KeyModifier = .{ .ctrl = true };
    const ctrl_shift: KeyModifier = .{ .ctrl = true, .shift = true };

    fn fromParam(param: u32) KeyModifier {
        var modifier: KeyModifier = @bitCast(param -| 1);
        modifier.caps_lock = false;
        modifier.num_lock = false;
        return modifier;
    }
};

fn printableKey(codepoint: u32) Key {
    return if (codepoint >= 0x20 and codepoint <= 0x7e) Key{ .char = @intCast(codepoint) } else .unknown;
}

fn decodeModifiedKey(codepoint: u32, modifier: KeyModifier) Key {
    return switch (codepoint) {
        9 => switch (modifier) {
            KeyModifier.none => .tab,
            KeyModifier.shift_only => .shift_tab,
            else => .unknown,
        },
        13 => if (modifier.alt) .shift_enter else switch (modifier) {
            KeyModifier.shift_only => .shift_enter,
            KeyModifier.ctrl_only => .ctrl_enter,
            else => .enter,
        },
        // 带修饰的 Esc(Shift/Ctrl+Esc)仍是 Esc:取消、关闭对它的每个使用方都一样
        // (反向搜索、transcript viewer 旧的自解码 CSI-u 就只看 codepoint 27)。
        27 => .esc,
        127 => switch (modifier) {
            KeyModifier.none, KeyModifier.shift_only => .backspace,
            else => .unknown,
        },
        else => switch (modifier) {
            // ASCII 可打印 → char(兼容把纯文本也 CSI-u 编码的终端)。
            KeyModifier.none, KeyModifier.shift_only => printableKey(codepoint),
            KeyModifier.ctrl_only => ctrlLetterKey(codepoint),
            KeyModifier.ctrl_shift => if (codepoint == '-') .ctrl_underscore else .unknown,
            // Alt+字母:Kitty disambiguate 把 Alt+B/Alt+F 编成 CSI-u(旧编码 ESC b
            // 与"ESC 再按 b"有歧义),不认的话开了协议的终端上词跳转就没了。
            KeyModifier.alt_only => switch (codepoint) {
                98, 66 => .alt_b,
                102, 70 => .alt_f,
                else => .unknown,
            },
            else => .unknown,
        },
    };
}

// Ctrl+字母:Kitty disambiguate 模式下某些终端/tmux 会把普通 Ctrl+letter 也编成 CSI-u
// (非仅歧义键)→ 必须覆盖 app 用到的全部 Ctrl 组合,否则该键在这些终端上静默丢
// (实测 bug:Ctrl+O 在发 CSI-u 的终端无反应)。与 byteToKey 的 0x01-0x1f 控制字节集保持一致。
fn ctrlLetterKey(codepoint: u32) Key {
    return switch (codepoint) {
        99, 67 => .ctrl_c, // 'c' / 'C'
        100, 68 => .ctrl_d, // 'd'
        97, 65 => .ctrl_a,
        101, 69 => .ctrl_e,
        107, 75 => .ctrl_k,
        117, 85 => .ctrl_u,
        111, 79 => .ctrl_o, // 'o' — transcript viewer(实测漏)
        98, 66 => .ctrl_b, // 'b' — 转后台(run in background)
        114, 82 => .ctrl_r, // 'r' — reverse search
        116, 84 => .ctrl_t, // 't' — task panel toggle
        103, 71 => .ctrl_g, // 'g'
        120, 88 => .ctrl_x, // 'x' — Ctrl+X 前缀
        108, 76 => .ctrl_l, // 'l' — external edit
        119, 87 => .ctrl_w, // 'w'
        121, 89 => .ctrl_y, // 'y'
        95 => .ctrl_underscore, // '_' — undo
        47 => .ctrl_underscore,
        104, 72 => .backspace,
        105, 73 => .tab,
        106, 74, 109, 77 => .enter,
        91 => .esc,
        else => .unknown,
    };
}

fn cursorKey(final: u8) Key {
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        else => .unknown,
    };
}

fn tildeKey(number: u32) Key {
    return switch (number) {
        1, 7 => .home,
        3 => .delete,
        4, 8 => .end,
        5 => .page_up,
        6 => .page_down,
        else => .unknown,
    };
}

fn byteToKey(b: u8) Key {
    return switch (b) {
        '\r', '\n' => .enter,
        0x09 => .tab,
        0x12 => .ctrl_r,
        0x14 => .ctrl_t,
        0x0f => .ctrl_o,
        0x02 => .ctrl_b, // 生成期转后台(run in background)
        0x18 => .ctrl_x,
        0x07 => .ctrl_g,
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
        0x1f => .ctrl_underscore, // Ctrl+_ / Ctrl+Shift+- : undo
        // 可打印 ASCII：0x20-0x7E
        // UTF-8 多字节：0x80+（首字节 0xC0-0xFF，延续字节 0x80-0xBF）——逐字节作为 .char 透传
        // 终端在显示时会把完整 UTF-8 序列组合成一个字符
        else => if (b >= 0x20) Key{ .char = b } else .unknown,
    };
}

// ============================================================================
// Raw mode（termios）
// ============================================================================

/// SIGCONT is handled asynchronously by publishing this bit.  The next
/// foreground input poll performs the actual terminal IO in normal context.
var g_resume_requested = std.atomic.Value(bool).init(false);

fn onContinue() void {
    g_resume_requested.store(true, .release);
}

/// Install the process-wide resume hook used by both input phases.
pub fn installResumeHandler() void {
    platform_signal.installContinue(onContinue);
}

/// Consume a pending SIGCONT and restore the intended raw/escape state.
/// Re-entering raw mode is idempotent; the saved cooked mode belongs to the
/// surrounding input phase and is never replaced by this reconciliation.
pub fn reconcileAfterResume(fd: c_int) bool {
    if (!g_resume_requested.swap(false, .acquire)) return false;
    if (reconcileModes(fd)) return true;
    // Keep the request pending if the descriptor was transiently unavailable;
    // the next poll gets another chance to restore the interactive state.
    g_resume_requested.store(true, .release);
    return false;
}

/// Whether a raw-mode key read that returned < 0 only lost a race with a
/// signal: a terminal resize (SIGWINCH) or a resume (SIGCONT) interrupts a
/// blocked read with EINTR and carries no input, so the reader retries
/// (redrawing if it redraws per iteration) instead of taking the failure as
/// an answer. That is how a resize used to become "user declined" in the
/// permission dialog. A pending resume is reconciled first. A requested
/// process shutdown (SIGINT) still ends the reader. Call it right after the
/// failed read, before another call can overwrite errno. Windows has neither
/// signal, and its console read does not set errno, so a stale value there
/// is never taken for an interruption.
pub fn retryInterruptedRead(fd: c_int) bool {
    const interrupted = @import("builtin").os.tag != .windows and pfs.lastErrnoIs(.INTR);
    const resumed = reconcileAfterResume(fd);
    if (shutdown.requested()) return false;
    return interrupted or resumed;
}

/// How long a modal key loop waits for input before it looks again. A lone
/// ESC still pending when the wait runs out is the Esc key: terminals send a
/// sequence's bytes together, and the prompt's own loop uses the same tick.
const key_wait_ms: i32 = 200;

/// What `readKey` got.
pub const KeyRead = union(enum) {
    key: Key,
    /// A signal (a resize, a resume) cut the wait short. Nothing was lost:
    /// a sequence read halfway stays in the parser. Redraw, then read again.
    interrupted,
    /// End of input, a read error, or a requested shutdown.
    closed,
};

/// One key for a modal loop that owns the terminal in raw mode (transcript
/// viewer, reverse search). Bytes go through `parser`, so the rest of an
/// escape sequence is read like any other byte: a resize between ESC and `[`
/// no longer splits `ESC [ A` into Esc plus two typed characters, and a lone
/// Esc is reported once the wait runs out instead of waiting for another key.
pub fn readKey(fd: c_int, parser: *KeyParser) KeyRead {
    if (parser.drain()) |key| return .{ .key = key };
    while (true) {
        const rc = platform_term.waitReadable(fd, key_wait_ms);
        if (rc == 0) {
            if (parser.flushEsc()) |key| return .{ .key = key };
            continue;
        }
        if (rc < 0) return if (retryInterruptedRead(fd)) .interrupted else .closed;
        var b: [1]u8 = undefined;
        const n = platform_term.readInput(fd, &b);
        if (n < 0) return if (retryInterruptedRead(fd)) .interrupted else .closed;
        if (n == 0) return .closed;
        if (parser.feedRead(fd, b[0])) |key| return .{ .key = key };
    }
}

/// Reconcile all terminal mode families with the intended interactive state.
/// This is deliberately shared by initial entry and SIGCONT recovery so a new
/// mode cannot be enabled in one path and forgotten in the other.
pub fn reconcileModes(fd: c_int) bool {
    if (platform_term.enterRaw(fd) == null) return false;
    emitEnableSequences(fd);
    rearmRescue();
    return true;
}

/// win32-input-mode(DECSET 9001):Windows 控制台把每个按键整条送来(虚拟键、字符、
/// 按下/抬起、修饰键状态),读控制台输入的地方(platform/terminal.zig readInput)还原成
/// VT 字节;Shift+Enter 由此能和 Enter 区分。Windows Terminal 1.24(ConPTY)与经典 conhost
/// 实测都认它。bracketed paste(DECSET 2004)与它一起
/// 写给控制台:开着时 Windows Terminal 把粘贴包进 `ESC[200~ … ESC[201~` 送来,经典 conhost 把
/// 标记连同每个字符编成记录送来;没开时 Windows Terminal 先弹多行粘贴警告,两者都把每个换行
/// 当 Enter 送来,逐行提交。
const console_enable = "\x1b[?9001h" ++ "\x1b[?2004h";
const console_disable = "\x1b[?2004l" ++ "\x1b[?9001l";

/// 控制台模式(console_enable / console_disable)写到哪:控制台的输出(Windows 控制台不收写给
/// stdin 的字节),只在 stdin/stdout 都是控制台时,与 TERM 无关(Windows 上通常没有 TERM)。
/// 测试把它指到一个文件(g_console_out_for_testing)。
fn consoleOut() ?c_int {
    if (g_console_out_for_testing) |out| return out;
    return if (platform_term.isConsole()) 1 else null;
}
var g_console_out_for_testing: ?c_int = null;

fn emitEnableSequences(fd: c_int) void {
    if (consoleOut()) |out| {
        _ = pfs.writeAll(out, console_enable);
        platform_term.decodeKeyRecords();
    }
    // Dumb terminals do not understand private modes; keep their output clean.
    const term = std.c.getenv("TERM");
    const dumb = term == null or std.mem.eql(u8, std.mem.span(term.?), "dumb") or std.mem.span(term.?).len == 0;
    if (dumb) return;

    // Kitty keyboard + modifyOtherKeys are enabled only for the terminals that
    // are known, or answered the startup probe, to parse them.  The sequence
    // starts by popping stale Kitty state, making repeated reconciliation safe
    // even after shell changes.
    if (shouldEnableKittyKeyboard()) {
        _ = pfs.writeAll(fd, kbd_enable_seq);
    }
    const enable_paste = "\x1b[?2004h";
    _ = pfs.writeAll(fd, enable_paste);
    if (mouseSelectionOn()) _ = pfs.writeAll(fd, mouse_selection_enable);
}

pub const mouse_selection_enable = "\x1b[?1002h\x1b[?1006h";
pub const mouse_selection_disable = "\x1b[?1006l\x1b[?1002l";

var g_mouse_selection = std.atomic.Value(bool).init(false);

pub fn recordMouseSelection(on: bool) void {
    g_mouse_selection.store(on, .release);
}

pub fn mouseSelectionOn() bool {
    return g_mouse_selection.load(.acquire);
}

/// 切 raw 模式，返回旧 termios；非 tty 或失败返 null。
/// 进 raw mode。返回原 termios(供 restoreMode 复原);非 tty 返 null。
/// 仅对**证明了能力的终端**(shouldEnableKittyKeyboard:认得出的、或启动探测答了 Kitty flags)
/// 启用 Kitty 键盘协议 / xterm modifyOtherKeys,以区分 Shift+Enter / Ctrl+Enter。deny-list 上的
/// (如 Apple Terminal)不发——它们会 honor 协议并发回 parser 处理不了的 codepoint(对齐真 cc
/// terminal.ts:167:无条件发是 #23350 踩过的坑)。
///
/// **键盘协议序列**(对齐真 cc ink.tsx:418,pop-before-push 防残留栈叠加):
///   `\x1b[<u`   DISABLE_KITTY_KEYBOARD —— 先 pop 清 Kitty 栈
///   `\x1b[>1u`  ENABLE_KITTY flags=1(disambiguate-only):歧义键(Shift/Ctrl+Enter、
///              Esc、功能键)编成 CSI-u,纯文本不编码 → Warp/iTerm/kitty/WezTerm/ghostty 用这条
///   `\x1b[>4;2m` ENABLE_MODIFY_OTHER_KEYS level 2:不支持 Kitty 的 xterm 系走这条
/// 实测:Warp 收到 `\x1b[>1u` 后 Shift+Enter 才发 `\x1b[13;2u`(否则退回裸 \n,被当 Enter)。
/// 不发协议的终端 Shift+Enter 发裸 \r/\n,换行改靠 backslash+return(见 LineEditor.handle .enter)。
pub const kbd_enable_seq = "\x1b[<u" ++ "\x1b[>1u" ++ "\x1b[>4;2m";
pub const kbd_disable_seq = "\x1b[<u" ++ "\x1b[>4m"; // DISABLE_KITTY(pop) + DISABLE_MODIFY_OTHER_KEYS

/// 怎样决定发不发 Kitty 键盘协议 / modifyOtherKeys(#327)。
pub const KeyboardPolicy = enum {
    /// 环境认得出、已知实现正确的终端(及 tmux):直接发,不问。
    enable,
    /// 已知会把协议用坏的终端(deny-list)、dumb 终端、问了也答不准的 multiplexer:不发,也不问。
    disable,
    /// 环境认不出:启动探测(tui/bg_probe.zig)问终端本身,答了 Kitty flags 才发;没答 → 不发。
    probe,
};

/// Kitty 键盘协议 **deny-list**:探测也不问,答了也不发(TERM 自己认得出的 kitty/Ghostty 除外,
/// 见 classifyKittyKeyboard)。
/// 真 cc 注释铁证(terminal.ts:167):此前无条件发(#23350)是 bug——某些终端(Apple Terminal/
/// SSH/xterm.js)会 honor enable 并发回 parser 处理不了的 codepoint(→ 各种键乱/乱码)。
/// 那次教训里点名的终端留在这里:Apple_Terminal;xterm.js 的宿主 vscode(VS Code 及其分支)、Hyper。
/// Apple Terminal 换行靠 backslash+return。SSH 不是终端,不在此列:远端认不出的终端正是探测
/// 要回答的问题(探测经 SSH 问到本地真正的终端)。
const kitty_deny_term_programs = [_][]const u8{ "Apple_Terminal", "vscode", "Hyper" };

/// 环境就能认出、已知正确实现 Kitty/modifyOtherKeys 的终端(对齐真 cc EXTENDED_KEYS_TERMINALS +
/// 实测追加 Warp):直接发,省一次往返,也不因探测改变它们已验证过的行为。
/// WarpTerminal 为 cc-zig 追加(用户实测:其默认未开 Kitty,需主动发 \x1b[>1u 才能 Shift+Enter 换行)。
const kitty_term_programs = [_][]const u8{ "iTerm.app", "WezTerm", "ghostty", "WarpTerminal" };

/// 会话跑在哪个终端复用器里。复用器自己应答查询,答的是它自己而不是外层终端,故不探测。
pub const Multiplexer = enum {
    none,
    /// tmux 接受 modifyOtherKeys 且不转发 Kitty 给外层(对齐真 cc):照旧直接发。
    tmux,
    /// GNU screen、zellij,或 TERM 是 screen*/tmux* 而本进程不在 tmux 里(经 SSH 从复用器里连过来):
    /// 照旧只看环境认不认得出终端。
    other,
};

/// 纯函数(便于纯单测,不依赖真 env):据 TERM_PROGRAM / TERM / 复用器定 Kitty 协议策略。
pub fn classifyKittyKeyboard(term_program: ?[]const u8, term: ?[]const u8, multiplexer: Multiplexer) KeyboardPolicy {
    // dumb 终端不懂私有模式:emitEnableSequences 什么都不发,提示文案也要与之一致。
    if (term == null or term.?.len == 0 or std.mem.eql(u8, term.?, "dumb")) return .disable;
    if (multiplexer == .tmux) return .enable;
    // TERM 是终端给自己起的 shell 设的;TERM_PROGRAM 会从外层继承(从 Terminal.app 或 VS Code
    // 里启动的 kitty 仍带着外层的 TERM_PROGRAM)。TERM 认得出就以它为准,先于 deny-list。
    if (kittyTerm(term.?)) return .enable;
    if (term_program) |tp| {
        for (kitty_deny_term_programs) |n| if (std.mem.eql(u8, tp, n)) return .disable;
        for (kitty_term_programs) |n| if (std.mem.eql(u8, tp, n)) return .enable;
    }
    return if (multiplexer == .other) .disable else .probe;
}

fn kittyTerm(term: []const u8) bool {
    if (std.mem.indexOf(u8, term, "kitty") != null) return true; // xterm-kitty 等
    return std.mem.eql(u8, term, "xterm-ghostty");
}

fn envValue(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |v| std.mem.span(v) else null;
}

fn nonEmptyEnv(name: [*:0]const u8) bool {
    return if (envValue(name)) |v| v.len > 0 else false;
}

pub const no_keyboard_enhancement_env = "METACODES_NO_KEYBOARD_ENHANCEMENT";

pub fn keyboardEnhancementOptedOut() bool {
    return envValue(no_keyboard_enhancement_env) != null;
}

/// 读真实 env 调 classifyKittyKeyboard。
pub fn keyboardPolicy() KeyboardPolicy {
    if (keyboardEnhancementOptedOut()) return .disable;
    const term = envValue("TERM");
    const multiplexer: Multiplexer = if (nonEmptyEnv("TMUX"))
        .tmux
    else if (nonEmptyEnv("STY") or envValue("ZELLIJ") != null or
        (term != null and (std.mem.startsWith(u8, term.?, "screen") or std.mem.startsWith(u8, term.?, "tmux"))))
        .other
    else
        .none;
    return classifyKittyKeyboard(envValue("TERM_PROGRAM"), term, multiplexer);
}

/// 启动探测的答案:终端答了 Kitty flags 查询。进程内只在启动时、首次进 raw mode 之前写一次
/// (app.resolveInteractiveTerminal),此后 enable/restore/提示文案读到的恒是同一个值。
var g_kitty_answered = std.atomic.Value(bool).init(false);

pub fn recordKeyboardProbe(kitty_answered: bool) void {
    g_kitty_answered.store(kitty_answered, .release);
}

/// 发不发 Kitty 协议:策略 + (策略要探测时)启动探测的答案。同进程 env 不变、答案只写一次,
/// enterRawMode 与 restoreMode 的判定恒一致。
pub fn shouldEnableKittyKeyboard() bool {
    return switch (keyboardPolicy()) {
        .enable => true,
        .disable => false,
        .probe => g_kitty_answered.load(.acquire),
    };
}

/// 当前终端的换行方式提示(对齐真 cc getNewlineInstructions,但按 cc-zig 实际能力):
/// - 发了 Kitty 协议(认得出的终端、或探测答了)→ Shift+Enter 真换行 → "shift + ⏎ for newline";
///   tmux 里照发,但 tmux 默认不转发 extended keys,Shift+Enter 到这里仍是 \r,所以不算
/// - 没发(deny-list 的 Apple Terminal 等、探测说不支持或没答,Shift+Enter 发裸 \r=Enter 会提交)
///   → "\ + ⏎ for newline"(cc-zig 无 macOS 原生 modifier 检测,故 Apple Terminal 只能靠
///   backslash 续行,不能照抄真 cc 对 Apple 的 "shift+⏎" 文案——那会误导)。
/// - Windows 控制台:开了 win32-input-mode,且有按键记录打出过字(platform_term.keyRecordsTypeText:
///   宿主送的是键盘上真实的按键,修饰键状态在里面)→ "shift + ⏎"。只发 VT 字节的终端经 ConPTY
///   时,单独的 CR/ESC 也被做成记录,但字从来不是,那里 Shift+Enter 照旧提交。提示只在输入框多于
///   一行时出现,那时用户已经敲过字,所以这条判据不会晚。
/// - 终端自己把 Shift+Enter 绑成了 ESC CR(/terminal-setup,#386;recordNewlineBinding)→ 也是 shift。
pub fn newlineHint() []const u8 {
    const protocol_newline = shouldEnableKittyKeyboard() and !nonEmptyEnv("TMUX");
    const shift_newline = protocol_newline or platform_term.keyRecordsTypeText() or g_newline_binding.load(.acquire);
    return if (shift_newline) "shift + \xe2\x8f\x8e for newline" else "\\ + \xe2\x8f\x8e for newline";
}

pub fn keyboardSummary() []const u8 {
    if (keyboardEnhancementOptedOut()) return "off · " ++ no_keyboard_enhancement_env ++ " is set";
    if (shouldEnableKittyKeyboard()) return "on (Kitty protocol, modifyOtherKeys) · " ++ no_keyboard_enhancement_env ++ "=1 turns it off";
    return "off";
}

/// 终端配置里的 Shift+Enter 绑定(发 ESC CR,KeyParser 读成 .shift_enter)此刻生效与否:启动时据
/// terminal_setup.bindingLive 写一次,/terminal-setup 装上 / 撤销后再写(VS Code 当场生效;Apple Terminal
/// 要重开,本进程不改)。
var g_newline_binding = std.atomic.Value(bool).init(false);

pub fn recordNewlineBinding(live: bool) void {
    g_newline_binding.store(live, .release);
}

/// 进程第一次进 raw mode 之前,终端收到的都是启动期间敲的键(探测之后、启动动画期间、
/// App.init 期间):它们是给第一个输入框的,这一次切换保留它们,整段读出留给它
/// (collectStartupInput)。此后的切换照旧丢掉终端已收、未读的输入(TCSAFLUSH:两次读输入之间
/// 的键,见 tests/tty/tty_driver.py)。
var g_first_raw_entry = std.atomic.Value(bool).init(true);

pub fn enterRawMode(fd: c_int) ?platform_term.SavedMode {
    // 启动探测到期、应答还在路上时终端一直是安静模式(bg_probe.Late):接管它,返回探测前的
    // 模式供 restoreMode 复原(当前的安静模式不是要复原的那个)。
    const original = bg_probe.handOver(fd);
    // 模式切换走可移植 platform/terminal(POSIX termios / Windows console mode)。
    const startup = g_first_raw_entry.swap(false, .acq_rel);
    const orig = (if (startup) platform_term.enterRawKeepingInput(fd) else platform_term.enterRaw(fd)) orelse {
        if (original) |o| platform_term.restoreModeKeepingInput(fd, o);
        return null;
    };
    emitEnableSequences(fd);
    armRescue(fd, original orelse orig);
    if (startup) collectStartupInput(fd, startupSettleMs(bg_probe.roundTripMs()));
    return original orelse orig;
}

/// 启动期输入,等第一个输入框取走(takeStartupText)。只在主线程上读写。
var g_startup_text: ?StartupText = null;

/// 终端读空之后再等多久才算启动期输入到齐:一段粘贴的后半截可能还在路上。pty 一次只放行约
/// 4 KiB;慢链路上更是分批到达,批与批相隔约一个往返(SSH 空闲后重新发送,初始拥塞窗口约
/// 14 KB;mosh 也分帧)。启动探测量过往返时间就等它的两倍,至少 50 ms;至多 500 ms,一个
/// 离谱的测量值不该拖慢启动。没探测(Windows、什么都不问)等 50 ms。
fn startupSettleMs(round_trip_ms: ?i64) i32 {
    const rtt = round_trip_ms orelse return startup_settle_min_ms;
    return @intCast(std.math.clamp(2 * rtt, startup_settle_min_ms, startup_settle_max_ms));
}
const startup_settle_min_ms: i32 = 50;
const startup_settle_max_ms: i32 = 500;

/// 首个输入框出现之前留下的启动期输入(探测、启动动画、App.init 期间敲的键或粘贴的文字)
/// 整体作为一次粘贴交给它:那时括号粘贴还没打开(第一个输入框才开),一段多行粘贴里的每个
/// 换行都是 Enter——第一行单独提交给了模型。这里把已到的全部读出(探测交回 stdin 的在前,
/// 终端的在后),还原成正文(StartupText),直到终端读空、再等 settle_ms 也没有新的;
/// 第一个输入框把它插入(loop.readLineRaw):换行是文本,用户按 Enter 才提交,大段粘贴照常
/// 落盘成占位符。不设长度上限,一个字节也不留给后面当按键。
fn collectStartupInput(fd: c_int, settle_ms: i32) void {
    var text = StartupText.init(std.heap.c_allocator);
    var chunk: [256]u8 = undefined;
    var read_any = false;
    while (true) {
        // Windows:不产字符的按键排在队首时 ReadConsoleW 会一直等下一个产字符的键。
        platform_term.dropSilentInput(fd);
        if (platform_term.waitReadable(fd, 0) <= 0) {
            if (read_any and platform_term.waitReadable(fd, settle_ms) > 0) continue;
            break;
        }
        const n = platform_term.readInput(fd, &chunk); // no EINTR: waitReadable reported data
        if (n <= 0) break;
        read_any = true;
        text.feed(chunk[0..@intCast(n)]);
    }
    text.finish();
    @import("metacodes-internal").util.log.debug("input", "startup input before the first prompt: {d} bytes of text", .{text.text().len});
    if (text.text().len == 0 and !text.dropped) return text.deinit();
    g_startup_text = text;
}

/// What was typed before the first prompt, for it to insert as one paste.
/// Null once taken, and when nothing was typed. The caller deinits it. A
/// turn that runs before the first prompt (a cron due at startup, a goal
/// loop going on) leaves it alone: the reply's draft (`TuiBackend.draft`) is
/// dropped when the reply ends, so the text waits for the first prompt.
pub fn takeStartupText() ?StartupText {
    const text = g_startup_text orelse return null;
    g_startup_text = null;
    return text;
}

/// 启动期输入 → 粘贴正文:按键还原(KeyParser),字符、换行、Tab 留下,退格删掉前一个
/// UTF-8 字符(启动期间打错了改的字照样生效),其它键(方向键、Esc、Ctrl 组合)丢掉。
pub const StartupText = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    parser: KeyParser = .{},
    /// Memory ran out: what came after was read and dropped, not left as keys.
    dropped: bool = false,

    pub fn init(gpa: std.mem.Allocator) StartupText {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *StartupText) void {
        self.buf.deinit(self.gpa);
    }

    pub fn feed(self: *StartupText, input_bytes: []const u8) void {
        for (input_bytes) |b| {
            if (self.parser.feed(b)) |k| self.apply(k);
            while (self.parser.drain()) |k| self.apply(k);
        }
    }

    /// Nothing more comes: a sequence still open is resolved (a lone Esc is
    /// dropped like any key that types nothing).
    pub fn finish(self: *StartupText) void {
        if (self.parser.flushEsc()) |k| self.apply(k);
        while (self.parser.drain()) |k| self.apply(k);
    }

    /// The text to insert, without the newlines it starts or ends with (the
    /// Enter that skipped the startup animation, the one after the last
    /// line): nothing is submitted, so they would only leave empty lines.
    /// Empty when it is only blanks.
    pub fn text(self: *const StartupText) []const u8 {
        const t = std.mem.trim(u8, self.buf.items, "\n");
        return if (std.mem.trim(u8, t, " \t\n").len == 0) t[0..0] else t;
    }

    fn apply(self: *StartupText, k: Key) void {
        if (self.dropped) return;
        switch (k) {
            .char => |c| self.push(c),
            .enter, .shift_enter => self.push('\n'),
            .tab => self.push('\t'),
            .backspace => while (self.buf.items.len > 0) {
                const last = self.buf.items[self.buf.items.len - 1];
                self.buf.items.len -= 1;
                if (last & 0xC0 != 0x80) break; // a lead byte: the whole character is gone
            },
            else => {},
        }
    }

    fn push(self: *StartupText, c: u8) void {
        self.buf.append(self.gpa, c) catch {
            self.dropped = true;
        };
    }
};

pub fn restoreMode(fd: c_int, orig: platform_term.SavedMode) void {
    disarmRescue();
    emitDisableSequences(fd);
    platform_term.restoreMode(fd, orig); // POSIX tcsetattr / Windows SetConsoleMode
}

const rescue_capacity = 64;
comptime {
    std.debug.assert("\x1b[?2004l".len + mouse_selection_disable.len + kbd_disable_seq.len <= rescue_capacity);
}
var g_rescue_fd: c_int = -1;
var g_rescue_mode: platform_term.SavedMode = undefined;
var g_rescue_bytes: [rescue_capacity]u8 = undefined;
var g_rescue_len: usize = 0;
var g_rescue_armed = std.atomic.Value(bool).init(false);
var g_rescue_installed = std.atomic.Value(bool).init(false);

fn armRescue(fd: c_int, mode: platform_term.SavedMode) void {
    if (@import("builtin").os.tag == .windows) return;
    g_rescue_armed.store(false, .release);
    const parts = [_][]const u8{
        "\x1b[?2004l",
        if (mouseSelectionOn()) mouse_selection_disable else "",
        if (shouldEnableKittyKeyboard()) kbd_disable_seq else "",
    };
    var len: usize = 0;
    for (parts) |part| {
        @memcpy(g_rescue_bytes[len..][0..part.len], part);
        len += part.len;
    }
    g_rescue_len = len;
    g_rescue_fd = fd;
    g_rescue_mode = mode;
    g_rescue_armed.store(true, .release);
    if (@import("builtin").os.tag != .windows and !g_rescue_installed.swap(true, .acq_rel)) rescue_signals.install();
}

fn disarmRescue() void {
    g_rescue_armed.store(false, .release);
}

fn rearmRescue() void {
    if (g_rescue_fd >= 0) g_rescue_armed.store(true, .release);
}

pub fn rescueTerminal() void {
    if (!g_rescue_armed.swap(false, .acq_rel)) return;
    _ = pfs.writeAll(g_rescue_fd, g_rescue_bytes[0..g_rescue_len]);
    platform_term.restoreModeKeepingInput(g_rescue_fd, g_rescue_mode);
}

const rescue_signals = struct {
    const fatal = [_]std.posix.SIG{ .ABRT, .QUIT, .ALRM, .SEGV, .BUS, .ILL, .FPE, .TRAP };
    var previous: [fatal.len]std.posix.Sigaction = undefined;

    fn install() void {
        for (fatal, &previous) |sig, *saved| {
            std.posix.sigaction(sig, null, saved);
            if (saved.handler.handler == std.posix.SIG.IGN) continue;
            const act: std.posix.Sigaction = .{
                .handler = .{ .handler = onFatal },
                .mask = std.posix.sigemptyset(),
                .flags = std.posix.SA.ONSTACK,
            };
            std.posix.sigaction(sig, &act, null);
        }
        var stop: std.posix.Sigaction = undefined;
        std.posix.sigaction(.TSTP, null, &stop);
        if (stop.handler.handler == std.posix.SIG.IGN) return;
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = onStop },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.TSTP, &act, null);
    }

    fn onFatal(sig: std.posix.SIG) callconv(.c) void {
        rescueTerminal();
        for (fatal, previous) |candidate, saved| {
            if (candidate != sig) continue;
            std.posix.sigaction(sig, &saved, null);
            break;
        }
        std.posix.raise(sig) catch {};
    }

    fn onStop(_: std.posix.SIG) callconv(.c) void {
        rescueTerminal();
        const default: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var ours: std.posix.Sigaction = undefined;
        std.posix.sigaction(.TSTP, &default, &ours);
        var stopping = std.posix.sigemptyset();
        std.posix.sigaddset(&stopping, .TSTP);
        std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &stopping, null);
        std.posix.raise(.TSTP) catch {};
        std.posix.sigaction(.TSTP, &ours, null);
        rearmRescue();
        g_resume_requested.store(true, .release);
    }
};

/// emitEnableSequences 开的转义模式关回去。关 bracketed paste(始终)+ 键盘协议(仅发过 enable
/// 的——对称 enterRawMode,同进程 env 不变、探测答案只写一次,判定恒一致,不会发了 enable 没
/// disable;没发过的不发孤立 disable,避免 Apple Terminal honor 它出异常)+ 控制台的
/// win32-input-mode 与它的 bracketed paste。
fn emitDisableSequences(fd: c_int) void {
    const disable_paste = "\x1b[?2004l";
    _ = pfs.writeAll(fd, disable_paste);
    if (mouseSelectionOn()) _ = pfs.writeAll(fd, mouse_selection_disable);
    if (shouldEnableKittyKeyboard()) {
        _ = pfs.writeAll(fd, kbd_disable_seq);
    }
    if (consoleOut()) |out| _ = pfs.writeAll(out, console_disable);
}

/// 在 raw 模式里读键的地方把终端借给一个自己读终端的子进程(`$EDITOR`):终端回到 cooked,
/// REPL 开的转义模式全关——否则编辑器收到的是括号粘贴标记、Kitty 键码,Windows 控制台上
/// 每个键都是一条 win32-input-mode 记录 `ESC[…_`。返回借出前的模式,交给 takeBackTerminal;
/// 不是终端 → null(什么都没动)。
pub fn lendTerminal(fd: c_int) ?platform_term.SavedMode {
    const saved = platform_term.saveMode(fd) orelse return null;
    disarmRescue();
    emitDisableSequences(fd);
    platform_term.setCooked(fd);
    return saved;
}

/// 子进程用完终端:回到借出前的模式,转义模式重新打开(Windows 控制台上 Shift+Enter 照旧换行)。
pub fn takeBackTerminal(fd: c_int, saved: platform_term.SavedMode) void {
    platform_term.restoreMode(fd, saved);
    emitEnableSequences(fd);
    rearmRescue();
}

/// 把 `current` 写临时文件,开 $VISUAL/$EDITOR(前台阻塞)编辑,读回(owned,去尾换行)。
/// 调用方负责终端模式:本函数 spawn 的编辑器自管 termios,但调用方应在调用前退 raw / 调用后重进。
/// REPL 主循环(loop.zig Ctrl+G)和 AskUserQuestion preview note(ask_question.zig ctrl+g)共用。
pub fn externalEdit(allocator: std.mem.Allocator, current: []const u8) ![]u8 {
    const editor_env = std.c.getenv("VISUAL") orelse std.c.getenv("EDITOR") orelse return error.NoEditor;
    const editor_cmd = std.mem.span(editor_env);

    // 每进程一个缓冲文件,放平台临时目录(POSIX $TMPDIR/… 或 /tmp,Windows %TEMP%):
    // 固定的 /tmp/cc-zig-edit-buffer.txt 会让两个并行 REPL 互相覆盖对方正在编辑的内容,
    // 在 Windows 上还依赖当前驱动器根下的 \tmp 存在。
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintZ(&tmp_path_buf, "{s}/metacodes-edit-buffer-{d}.txt", .{ ppaths.tempDir(), process.currentPid() });
    {
        const fd = pfs.open(tmp_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.WriteFailed;
        defer _ = pfs.close(fd);
        if (current.len > 0) _ = pfs.write(fd, current[0..current.len]); // no EINTR: regular file
    }

    const path_z = try allocator.dupeZ(u8, tmp_path);
    defer allocator.free(path_z);
    var argv = [_]?[*:0]const u8{ "/bin/sh", "-c", undefined, null };
    const sh_cmd = try std.fmt.allocPrintSentinel(allocator, "{s} \"{s}\"", .{ editor_cmd, tmp_path }, 0);
    defer allocator.free(sh_cmd);
    argv[2] = sh_cmd.ptr;

    // $EDITOR 交互式:继承 stdio（编辑器接管终端）+ wait，走可移植 platform/process。
    // Windows 的 /bin/sh 依赖 git-bash（roadmap shell 决策 node 8871）。
    _ = process.runInherit(argv[0..], true) catch return error.ForkFailed;

    const rfd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (rfd < 0) return error.ReadFailed;
    defer _ = pfs.close(rfd);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pfs.read(rfd, buf[0..buf.len]); // no EINTR: regular file, not the terminal
        if (n <= 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    pfs.unlinkPath(path_z.ptr) catch {};
    var result = try out.toOwnedSlice(allocator);
    if (result.len > 0 and result[result.len - 1] == '\n') {
        result = try allocator.realloc(result, result.len - 1);
    }
    return result;
}

// ============================================================================
// LineEditor：buffer + cursor，按 Key 产生 Action
// ============================================================================

pub const Action = enum {
    /// 继续（buffer 改变或 cursor 移动，调用方需重绘）
    redraw,
    /// 提交当前行（enter）
    commit,
    /// Ctrl+D on an empty buffer. The idle prompt confirms it with a second
    /// press in `ui.dispatch` before it gets here; only paths without that
    /// state (none today) would see it.
    eof,
    /// 无语义变化（如 unknown 键）
    none,
};

const Snapshot = struct {
    bytes: []u8, // owned(dupe);pop/丢弃/deinit 时 free
    cursor: usize,
};
const undo_max_depth = 50;

pub const LineEditor = struct {
    buf: std.ArrayList(u8),
    cursor: usize = 0,
    allocator: std.mem.Allocator,
    /// yank ring:Ctrl+W/K/U 删除的内容存这,Ctrl+Y 粘回。
    yank_buf: std.ArrayList(u8),
    /// undo 栈:破坏性编辑前快照 buf+cursor。深度上限 undo_max_depth,超了丢最旧。
    undo_stack: std.ArrayList(Snapshot),
    /// 去抖:上一次 handle 处理的 Key tag。连续 .char 只在段首 push 一次。
    last_op: ?std.meta.Tag(Key) = null,
    /// up/down 竖移的 sticky 目标显示列(visual col)。null=无竖移流。
    /// 任何经 handle 的键(非竖移)清空;竖移路径(loop 经 RenderRegion.tryVerticalMove)
    /// 直接维护此字段,故连续 up/down 保 goal column。详见 ui_compare/diff/INPUT_BEHAVIOR_DIFF_2026-06-11.md。
    goal_vcol: ?usize = null,
    // TODO(redo):redo 栈留待后续(CC 主要只做 undo,Ctrl+Y 已被 yank 占用)。

    pub fn init(allocator: std.mem.Allocator) LineEditor {
        return .{ .buf = .empty, .allocator = allocator, .yank_buf = .empty, .undo_stack = .empty };
    }

    pub fn deinit(self: *LineEditor) void {
        self.buf.deinit(self.allocator);
        self.yank_buf.deinit(self.allocator);
        for (self.undo_stack.items) |s| self.allocator.free(s.bytes);
        self.undo_stack.deinit(self.allocator);
    }

    /// 输入一个 Key 并更新状态。返回对应 Action。
    pub fn handle(self: *LineEditor, key: Key) !Action {
        // 任何经 editor 的键都是非竖移键(up/down 在 dispatch 截获,永不入此)→ 终结竖移流。
        self.goal_vcol = null;

        // undo 去抖:破坏性编辑前 push 当前状态。char 连打只在段首压一次(last_op != char);
        // 其它破坏性操作每次都压。导航键不压但更新 last_op(使 char→left→char 在第二个 char 重新压)。
        {
            const tag = @as(std.meta.Tag(Key), key);
            switch (key) {
                .char => {
                    if (self.last_op != .char) self.pushUndo();
                },
                .backspace, .delete, .ctrl_u, .ctrl_w, .ctrl_y, .shift_enter => {
                    self.pushUndo();
                },
                .ctrl_d => {
                    // Ctrl+D deletes forward on a non-empty buffer (see below).
                    if (self.cursor < self.buf.items.len) self.pushUndo();
                },
                .ctrl_k => {
                    // Ctrl+K 单按 = kill-line(Ctrl+X Ctrl+K 序列已迁 dispatch,不到 editor)。
                    // 仅真截断才压 undo(末尾 Ctrl+K 是 no-op)。
                    if (self.cursor < self.buf.items.len) self.pushUndo();
                },
                else => {},
            }
            self.last_op = tag;
        }

        switch (key) {
            .char => |c| {
                try self.buf.insert(self.allocator, self.cursor, c);
                self.cursor += 1;
                return .redraw;
            },
            .enter => {
                // backslash + return 续行(对齐真 cc useTextInput.ts:247-267):光标前一字节是
                // ASCII '\'(0x5c)且处逻辑行尾(buffer 末尾或下一字节是 '\n')→ 删 '\' + 原位插 '\n'
                // + 不提交。非白名单终端(Apple Terminal)Shift+Enter 发裸 \r→.enter,靠此换行;
                // 白名单终端用 .shift_enter(13;2u)直接插 \n,不经此,两路径不冲突。
                // '\'=0x5c 是 ASCII,UTF-8 多字节字节均 >= 0x80,前一字节直接比安全。
                if (self.cursor > 0 and self.buf.items[self.cursor - 1] == '\\') {
                    const at_eol = self.cursor == self.buf.items.len or self.buf.items[self.cursor] == '\n';
                    if (at_eol) {
                        self.pushUndo(); // .enter 不在上方 pushUndo 白名单,续行改 buffer 须显式压栈
                        _ = self.buf.orderedRemove(self.cursor - 1); // 删 '\'
                        self.cursor -= 1;
                        try self.buf.insert(self.allocator, self.cursor, '\n'); // 原位插 '\n'
                        self.cursor += 1;
                        return .redraw;
                    }
                }
                return .commit;
            },
            .shift_enter => {
                try self.buf.insert(self.allocator, self.cursor, '\n');
                self.cursor += 1;
                return .redraw;
            },
            // Ctrl+Enter(CSI-u 13;5u):真 cc v2.1.172 实测**不换行**(整个序列被吞:既不插
            // \n 也不插字符),只 Shift+Enter 换行。对齐 → no-op。
            .ctrl_enter => return .none,
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
                // 删除光标左边所有字符,先存入 yank ring(供 Ctrl+Y 粘回,对齐 cc)。
                try self.stashYank(self.buf.items[0..self.cursor]);
                self.buf.replaceRangeAssumeCapacity(0, self.cursor, &.{});
                self.cursor = 0;
                return .redraw;
            },
            .ctrl_k => {
                // Ctrl+K 单按 = kill-line(删到行尾)。Ctrl+X Ctrl+K 序列(杀后台)已迁 dispatch。
                if (self.cursor >= self.buf.items.len) return .none;
                try self.stashYank(self.buf.items[self.cursor..]); // 存 yank(Ctrl+Y 粘回)
                self.buf.items.len = self.cursor; // 截断
                return .redraw;
            },
            // Ctrl+C belongs to the prompt's double-press state (`ui.dispatch`)
            // and, during a reply, to the watcher's interrupt; the editor has
            // nothing of its own to do with it.
            .ctrl_c => return .none,
            .ctrl_d => {
                if (self.buf.items.len == 0) return .eof;
                // Non-empty: delete forward, as Claude Code (and iPython) do.
                if (self.cursor >= self.buf.items.len) return .none;
                const end = nextCharBoundary(self.buf.items, self.cursor);
                self.buf.replaceRangeAssumeCapacity(self.cursor, end - self.cursor, &.{});
                return .redraw;
            },
            // 全局快捷键(↑↓/Tab/Shift+Tab/Ctrl+R/T/O/G/X/L)已全部由 dispatch(ui.zig)拦截解析,
            // editor 永远收不到它们(dispatch 返回非 pass_to_editor)→ 此处不再处理,落 else=.none。
            // Ctrl+X Ctrl+K 序列也迁 dispatch(UiState.ctrl_x_armed),editor 只管 Ctrl+K 单按 kill-line。
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
            .ctrl_underscore => {
                // undo:pop 栈顶快照恢复 buf+cursor。空栈则无操作。
                const snap = self.undo_stack.pop() orelse return .none;
                defer self.allocator.free(snap.bytes);
                self.buf.clearRetainingCapacity();
                try self.buf.appendSlice(self.allocator, snap.bytes);
                self.cursor = if (snap.cursor <= self.buf.items.len) snap.cursor else self.buf.items.len;
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
            // Esc is the prompt's double press (`ui.dispatch`: a second Esc
            // clears the draft) or, during a reply, the watcher's interrupt.
            .esc => return .none,
            // 全局快捷键(↑↓/Tab/Shift+Tab/Ctrl+R/T/O/G/X/L)由 dispatch(ui.zig)拦截,
            // editor 正常收不到;此处兜底返 .none(防御:vim/边界路径若漏到这不崩)。
            .up, .down, .tab, .shift_tab, .ctrl_r, .ctrl_t, .ctrl_o, .ctrl_b, .ctrl_g, .ctrl_x, .ctrl_l => return .none,
            .page_up, .page_down => return .none, // viewing 视口翻页键,editor 不处理(dispatch 拦截)
            .mouse, .cursor_position, .unknown => return .none,
        }
    }

    /// 把删除的内容存入 yank_buf(覆盖式,够用)。
    fn stashYank(self: *LineEditor, slice: []const u8) !void {
        self.yank_buf.clearRetainingCapacity();
        try self.yank_buf.appendSlice(self.allocator, slice);
    }

    /// 破坏性编辑前调用:把当前 buf+cursor 压入 undo 栈(dupe owned)。超上限丢最旧。
    /// void(非 !void):瞬时 OOM 只丢 undo 历史,不破坏编辑。
    fn pushUndo(self: *LineEditor) void {
        const snap = self.allocator.dupe(u8, self.buf.items) catch return;
        if (self.undo_stack.items.len >= undo_max_depth) {
            const oldest = self.undo_stack.orderedRemove(0);
            self.allocator.free(oldest.bytes);
        }
        self.undo_stack.append(self.allocator, .{ .bytes = snap, .cursor = self.cursor }) catch {
            self.allocator.free(snap); // append 失败:回收防泄漏
        };
    }

    /// 清空 undo 历史(reset/setLine/clear 时调:行已换,旧快照无意义)。
    fn clearUndo(self: *LineEditor) void {
        for (self.undo_stack.items) |s| self.allocator.free(s.bytes);
        self.undo_stack.clearRetainingCapacity();
        self.last_op = null;
        self.goal_vcol = null; // 整体替换 buffer(reset/setLine/clear)亦终结竖移流
    }

    /// 清空（用于 cancel / 历史覆盖写入）。
    pub fn reset(self: *LineEditor) void {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.clearUndo();
    }

    /// 把 buffer 整体替换为给定字节（用于历史导航写回）。
    pub fn setLine(self: *LineEditor, line: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(self.allocator, line);
        self.cursor = self.buf.items.len;
        self.clearUndo();
    }

    pub fn view(self: *const LineEditor) []const u8 {
        return self.buf.items;
    }

    /// yank ring 当前内容长度(供 UI 判断"是否有可粘贴的已删文本",对齐 cc Ctrl+Y 提示)。
    pub fn yankLen(self: *const LineEditor) usize {
        return self.yank_buf.items.len;
    }

    /// 清空编辑行(buf + cursor 归零)。生成期回车入队后清框用。
    pub fn clear(self: *LineEditor) void {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.clearUndo();
    }
};

/// UTF-8 continuation byte（高两位是 10）
inline fn isUtf8Continuation(b: u8) bool {
    return (b & 0b1100_0000) == 0b1000_0000;
}

/// 从 pos 向前找到前一个 UTF-8 字符起始位置。pos 必须在字符边界。
pub fn prevCharBoundary(bytes: []const u8, pos: usize) usize {
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

test "KeyParser: SGR mouse reports and cursor position answers become keys" {
    var p = KeyParser{};
    var got: ?Key = null;
    for ("\x1b[<32;12;5M") |b| got = p.feed(b);
    try std.testing.expectEqualDeep(Key{ .mouse = .{ .code = 32, .col = 12, .row = 5, .released = false } }, got.?);
    for ("\x1b[<0;3;4m") |b| got = p.feed(b);
    try std.testing.expectEqualDeep(Key{ .mouse = .{ .code = 0, .col = 3, .row = 4, .released = true } }, got.?);
    for ("\x1b[17;1R") |b| got = p.feed(b);
    try std.testing.expectEqualDeep(Key{ .cursor_position = .{ .row = 17, .col = 1 } }, got.?);
    for ("\x1b[<1;2Ma") |b| got = p.feed(b);
    try std.testing.expectEqualDeep(Key{ .char = 'a' }, got.?);
    try std.testing.expect(!p.pendingEsc());
}

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

test "KeyParser: lone ESC flushes via flushEsc (interrupt 用)" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null); // esc_seen,等后续字节
    try testing.expect(p.pendingEsc()); // 卡在 esc_seen
    try testing.expect(p.flushEsc().? == .esc); // 超时兑现孤立 ESC
    try testing.expect(!p.pendingEsc()); // 回 normal
    try testing.expect(p.flushEsc() == null); // 非 esc_seen 再 flush 无效
    // 兑现后状态干净:普通字符仍正常。
    const k = p.feed('x').?;
    try testing.expect(@as(std.meta.Tag(Key), k) == .char);
}

test "KeyParser: ESC followed by printable char yields two keys (esc + char, 不吞字符)" {
    var p = KeyParser{};
    // ESC 后紧跟 'x'(终端把两次快按合批送来,或用户极快连打):
    // feed(0x1b) 进 esc_seen 不出键;feed('x') 兑现 .esc 并把 'x' 暂存 pending。
    try testing.expect(p.feed(0x1b) == null);
    const first = p.feed('x').?;
    try testing.expect(first == .esc); // 第一个键 = 孤立 ESC
    const second = p.drain().?; // 第二个键 = 'x'(早期 bug:此字符被吞)
    try testing.expect(@as(std.meta.Tag(Key), second) == .char);
    try testing.expect(second.char == 'x');
    try testing.expect(p.drain() == null); // 排空后无残留
}

test "KeyParser: ESC + 'b'/'f' 仍是 Alt 组合键(不拆成两键)" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed('b').? == .alt_b); // ESC b = Alt+B(词左),单个键
    try testing.expect(p.drain() == null); // 不产生第二个键
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed('f').? == .alt_f); // ESC f = Alt+F(词右)
    try testing.expect(p.drain() == null);
}

test "KeyParser: ESC ESC — 第一个兑现,第二个重新待定" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed(0x1b).? == .esc); // 兑现第一个 ESC
    try testing.expect(p.drain() == null); // 第二个 ESC 不入 pending(它回到 esc_seen)
    try testing.expect(p.pendingEsc()); // 仍卡在 esc_seen(等第三字节)
    try testing.expect(p.flushEsc().? == .esc); // 超时兑现第二个 ESC
}

test "KeyParser: ESC + 控制键(Ctrl+A)— ESC 兑现 + 控制键不丢" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed(0x01).? == .esc); // 0x01 = Ctrl+A
    try testing.expect(p.drain().? == .ctrl_a); // 控制键也保留(不吞)
    try testing.expect(p.drain() == null);
}

test "KeyParser: delete (ESC [ 3 ~)" {
    var p = KeyParser{};
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('3');
    try testing.expect(p.feed('~').? == .delete);
}

test "KeyParser: page_up (ESC [ 5 ~) / page_down (ESC [ 6 ~)" {
    var p = KeyParser{};
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('5');
    try testing.expect(p.feed('~').? == .page_up);
    // 状态复位后可解析下一个序列。
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('6');
    try testing.expect(p.feed('~').? == .page_down);
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

test "LineEditor: ctrl_c leaves the buffer to the prompt state" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'a' });
    try testing.expect((try ed.handle(.ctrl_c)) == .none);
    try testing.expectEqualStrings("a", ed.view());
}

test "LineEditor: ctrl_d deletes forward on a non-empty buffer" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "héllo");
    _ = try ed.handle(.home);
    _ = try ed.handle(.right); // after 'h'
    try testing.expect((try ed.handle(.ctrl_d)) == .redraw);
    try testing.expectEqualStrings("hllo", ed.view()); // the two-byte é is removed whole
    _ = try ed.handle(.end);
    try testing.expect((try ed.handle(.ctrl_d)) == .none); // nothing ahead of the cursor
    try testing.expectEqualStrings("hllo", ed.view());
    _ = try ed.handle(.ctrl_underscore); // undo restores the deleted char
    try testing.expectEqualStrings("héllo", ed.view());
}

test "LineEditor: ctrl_d on an empty buffer is eof" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try testing.expect((try ed.handle(.ctrl_d)) == .eof);
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

test "LineEditor: 全局键(↑↓/Tab/Shift+Tab/Ctrl+R/T/O/G/L)不再归 editor → .none(已迁 dispatch)" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    // 这些键由 dispatch(ui.zig)拦截解析,editor 兜底返 .none(防御:误加回会被此测抓)。
    try testing.expect((try ed.handle(.up)) == .none);
    try testing.expect((try ed.handle(.down)) == .none);
    try testing.expect((try ed.handle(.tab)) == .none);
    try testing.expect((try ed.handle(.shift_tab)) == .none);
    try testing.expect((try ed.handle(.ctrl_r)) == .none);
    try testing.expect((try ed.handle(.ctrl_t)) == .none);
    try testing.expect((try ed.handle(.ctrl_o)) == .none);
    try testing.expect((try ed.handle(.ctrl_g)) == .none);
    try testing.expect((try ed.handle(.ctrl_l)) == .none);
    try testing.expect((try ed.handle(.ctrl_x)) == .none);
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

test "KeyParser: 无 mod CSI-u 文本键还原(Kitty disambiguate)" {
    // ESC[97u(无 ;mod)= 'a' → .char='a'(兼容把纯文本也 CSI-u 编码的终端)。
    var p = KeyParser{};
    for ([_]u8{ 0x1b, '[', '9', '7' }) |b| try testing.expect(p.feed(b) == null);
    const k = p.feed('u').?;
    try testing.expect(@as(std.meta.Tag(Key), k) == .char);
    try testing.expect(k.char == 'a');
}

test "KeyParser: 无 mod CSI-u Enter/Esc 还原" {
    // ESC[13u → .enter(无 mod Enter,非 0x20-0x7e 范围,须显式)
    var p1 = KeyParser{};
    for ([_]u8{ 0x1b, '[', '1', '3' }) |b| try testing.expect(p1.feed(b) == null);
    try testing.expect(p1.feed('u').? == .enter);
    // ESC[27u → .esc
    var p2 = KeyParser{};
    for ([_]u8{ 0x1b, '[', '2', '7' }) |b| try testing.expect(p2.feed(b) == null);
    try testing.expect(p2.feed('u').? == .esc);
}

test "KeyParser: CSI-u Esc with a modifier is still Esc" {
    // ESC[27;5u(Ctrl+Esc)/ESC[27;2u(Shift+Esc):反向搜索与 transcript viewer 靠它取消/关闭。
    for ([_][]const u8{ "\x1b[27;5u", "\x1b[27;2u" }) |seq| {
        var p = KeyParser{};
        for (seq[0 .. seq.len - 1]) |b| try testing.expect(p.feed(b) == null);
        try testing.expect(p.feed('u').? == .esc);
    }
}

test "KeyParser: CSI Delete still works" {
    var p = KeyParser{};
    for ([_]u8{ 0x1b, '[', '3' }) |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.feed('~').? == .delete);
}

test "KeyParser: CSI u with unknown mod falls back to Enter" {
    var p = KeyParser{};
    // ESC [ 13 ; 9 u  (mod=9 = Super，我们不关心)
    for ([_]u8{ 0x1b, '[', '1', '3', ';', '9' }) |b| try testing.expect(p.feed(b) == null);
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

test "LineEditor: ctrl_enter is no-op (对齐真 cc:只 shift_enter 换行)" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    _ = try ed.handle(Key{ .char = 'x' });
    const action = try ed.handle(.ctrl_enter);
    try testing.expect(action == .none); // 不换行、不提交
    try testing.expectEqualStrings("x", ed.view()); // 缓冲不变,无 \n
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

test "LineEditor: Esc never edits the buffer (the prompt's double press clears)" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try testing.expect((try ed.handle(.esc)) == .none);
    try typeStr(&ed, "hello");
    try testing.expect((try ed.handle(.esc)) == .none);
    try testing.expect((try ed.handle(.esc)) == .none);
    try testing.expectEqualStrings("hello", ed.view());
}

test "KeyParser: ctrl_t byte" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x14).? == .ctrl_t);
}

test "LineEditor: ctrl_k alone truncates (not kill)" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "hello");
    ed.cursor = 2;
    try testing.expect((try ed.handle(.ctrl_k)) == .redraw);
    try testing.expectEqualStrings("he", ed.view());
}

test "KeyParser: ctrl_o / ctrl_x bytes" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x0f).? == .ctrl_o);
    try testing.expect(p.feed(0x18).? == .ctrl_x);
}

test "KeyParser: Ctrl+B byte + Kitty CSI-u(转后台键路径)" {
    // 裸字节 0x02 → .ctrl_b。
    var p = KeyParser{};
    try testing.expect(p.feed(0x02).? == .ctrl_b);
    // Kitty CSI-u 形式 ESC[98;5u(98='b',5=Ctrl)→ .ctrl_b(白名单终端会发这个而非 0x02)。
    var p2 = KeyParser{};
    inline for ("\x1b[98;5u") |c| {
        const k = p2.feed(c);
        if (c == 'u') try testing.expect(k.? == .ctrl_b);
    }
}

test "KeyParser: Ctrl+O via Kitty CSI-u (ESC[111;5u)" {
    // 实测 bug:Kitty disambiguate 模式下某些终端把 Ctrl+O 编成 CSI-u(111='o',5=Ctrl)
    // 而非裸 0x0f → 旧 CSI-u 表无 'o' → 返 .unknown → Ctrl+O 静默失效。覆盖该路径。
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed('[') == null);
    try testing.expect(p.feed('1') == null);
    try testing.expect(p.feed('1') == null);
    try testing.expect(p.feed('1') == null);
    try testing.expect(p.feed(';') == null);
    try testing.expect(p.feed('5') == null);
    try testing.expect(p.feed('u').? == .ctrl_o);
    // 大写 'O'(79)同样映射(某些终端 Ctrl+Shift 变体)。
    var p2 = KeyParser{};
    inline for ("\x1b[79;5u") |c| {
        const k = p2.feed(c);
        if (c == 'u') try testing.expect(k.? == .ctrl_o);
    }
    // 其它新增覆盖键抽查:Ctrl+R(114) / Ctrl+T(116) 经 CSI-u 也能解。
    var p3 = KeyParser{};
    inline for ("\x1b[114;5u") |c| {
        const k = p3.feed(c);
        if (c == 'u') try testing.expect(k.? == .ctrl_r);
    }
}

test "KeyParser: ctrl_g byte" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x07).? == .ctrl_g);
}

test "KeyParser: shift_tab via ESC [ Z" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed('[') == null);
    try testing.expect(p.feed('Z').? == .shift_tab);
}

fn expectSequence(seq: []const u8, expected: Key) !void {
    var p = KeyParser{};
    for (seq[0 .. seq.len - 1]) |b| try testing.expect(p.feed(b) == null);
    try testing.expectEqual(expected, p.feed(seq[seq.len - 1]).?);
    try testing.expect(p.drain() == null);
    try testing.expect(!p.pendingEsc());
}

test "KeyParser: Tab and Shift+Tab as kitty CSI u" {
    try expectSequence("\x1b[9;2u", .shift_tab);
    try expectSequence("\x1b[9u", .tab);
    try expectSequence("\x1b[9;1u", .tab);
    try expectSequence("\x1b[9;66u", .shift_tab);
    try expectSequence("\x1b[9;5u", .unknown);
}

test "KeyParser: modifyOtherKeys CSI 27;mod;key~ decodes through the CSI u table" {
    try expectSequence("\x1b[27;2;9~", .shift_tab);
    try expectSequence("\x1b[27;1;9~", .tab);
    try expectSequence("\x1b[27;2;13~", .shift_enter);
    try expectSequence("\x1b[27;5;13~", .ctrl_enter);
    try expectSequence("\x1b[27;1;13~", .enter);
    try expectSequence("\x1b[27;5;27~", .esc);
    try expectSequence("\x1b[27;5;99~", .ctrl_c);
    try expectSequence("\x1b[27;5;111~", .ctrl_o);
    try expectSequence("\x1b[27;5;95~", .ctrl_underscore);
    try expectSequence("\x1b[27;3;98~", .alt_b);
    try expectSequence("\x1b[27;3;102~", .alt_f);
}

fn expectBothEncodings(codepoint: u32, modifier: u32, expected: Key) !void {
    var buf: [32]u8 = undefined;
    for ([_]u32{ 0, 64, 128, 192 }) |locks| {
        try expectSequence(try std.fmt.bufPrint(&buf, "\x1b[{d};{d}u", .{ codepoint, modifier + locks }), expected);
        try expectSequence(try std.fmt.bufPrint(&buf, "\x1b[27;{d};{d}~", .{ modifier + locks, codepoint }), expected);
    }
}

test "KeyParser: Ctrl+_, Shift+Backspace, Ctrl+H/I/J/M/[ and Shift+Space decode in CSI u and modifyOtherKeys as their legacy bytes do" {
    const cases = [_]struct { u32, u32, u8 }{
        .{ 45, 6, 0x1f },
        .{ 47, 5, 0x1f },
        .{ 95, 5, 0x1f },
        .{ 127, 2, 0x7f },
        .{ 127, 1, 0x7f },
        .{ 104, 5, 0x08 },
        .{ 72, 5, 0x08 },
        .{ 105, 5, '\t' },
        .{ 106, 5, '\n' },
        .{ 109, 5, '\r' },
        .{ 32, 2, ' ' },
        .{ 32, 5, 0x00 },
    };
    for (cases) |c| try expectBothEncodings(c[0], c[1], byteToKey(c[2]));
    try expectBothEncodings(91, 5, .esc);
    var buf: [8]Key = undefined;
    try testing.expectEqualSlices(Key, &.{.esc}, parseAll("\x1b", &buf));
}

test "KeyParser: Enter with the Alt bit is Shift+Enter in CSI u and modifyOtherKeys, as ESC CR is" {
    for ([_]u32{ 3, 4, 7, 8 }) |modifier| try expectBothEncodings(13, modifier, .shift_enter);
    var p = KeyParser{};
    try testing.expect(p.feedQueued(0x1b, true) == null);
    try testing.expectEqual(Key.shift_enter, p.feedQueued('\r', false).?);
    try expectBothEncodings(13, 2, .shift_enter);
    try expectBothEncodings(13, 5, .ctrl_enter);
    try expectBothEncodings(13, 1, .enter);
    try expectBothEncodings(13, 6, .enter);
    try expectBothEncodings(13, 9, .enter);
}

test "KeyParser: a printable key with only Shift is that character in CSI u and modifyOtherKeys" {
    try expectBothEncodings(65, 2, .{ .char = 'A' });
    try expectBothEncodings(95, 2, .{ .char = '_' });
    try expectBothEncodings(126, 2, .{ .char = '~' });
    try expectBothEncodings(31, 2, .unknown);
}

test "KeyParser: unknown modifyOtherKeys combos are one .unknown and leave no characters" {
    var buf: [16]Key = undefined;
    const keys = parseAll("a\x1b[27;5;9~b\x1b[27;2;8~c\x1b[28;2;9~d\x1b[27;2;9uf\x1b[27;2;9;1~g", &buf);
    const expected = [_]Key{ .{ .char = 'a' }, .unknown, .{ .char = 'b' }, .unknown, .{ .char = 'c' }, .unknown, .{ .char = 'd' }, .unknown, .{ .char = 'f' }, .unknown, .{ .char = 'g' } };
    try testing.expectEqualSlices(Key, &expected, keys);
}

test "KeyParser: cursor and editing keys with only Caps Lock or Num Lock on are the plain keys" {
    const finals = [_]struct { u8, Key }{ .{ 'A', .up }, .{ 'B', .down }, .{ 'C', .right }, .{ 'D', .left }, .{ 'H', .home }, .{ 'F', .end } };
    const tildes = [_]struct { u32, Key }{ .{ 1, .home }, .{ 3, .delete }, .{ 4, .end }, .{ 5, .page_up }, .{ 6, .page_down }, .{ 7, .home }, .{ 8, .end } };
    var buf: [16]u8 = undefined;
    for ([_]u32{ 1, 65, 129, 193 }) |modifier| {
        for (finals) |f| try expectSequence(try std.fmt.bufPrint(&buf, "\x1b[1;{d}{c}", .{ modifier, f[0] }), f[1]);
        for (tildes) |t| try expectSequence(try std.fmt.bufPrint(&buf, "\x1b[{d};{d}~", .{ t[0], modifier }), t[1]);
    }
    var keys_buf: [8]Key = undefined;
    const keys = parseAll("a\x1b[1;65Db\x1b[3;129~c", &keys_buf);
    try testing.expectEqualSlices(Key, &.{ .{ .char = 'a' }, .left, .{ .char = 'b' }, .delete, .{ .char = 'c' } }, keys);
}

test "KeyParser: Home and End as tmux, GNU screen, the Linux console and rxvt send them" {
    try expectSequence("\x1b[1~", .home);
    try expectSequence("\x1b[7~", .home);
    try expectSequence("\x1b[4~", .end);
    try expectSequence("\x1b[8~", .end);
    try expectSequence("\x1b[1;1~", .home);
    try expectSequence("\x1b[4;1~", .end);
    var buf: [16]Key = undefined;
    const keys = parseAll("abc\x1b[1~X\x1b[4~Y\x1b[7~Z\x1b[8~", &buf);
    try testing.expectEqualSlices(Key, &.{ .{ .char = 'a' }, .{ .char = 'b' }, .{ .char = 'c' }, .home, .{ .char = 'X' }, .end, .{ .char = 'Y' }, .home, .{ .char = 'Z' }, .end }, keys);
}

test "KeyParser: Shift, Alt or Ctrl next to a lock still keeps a cursor or editing key from being the plain key" {
    for ([_][]const u8{ "\x1b[1;2A", "\x1b[1;66A", "\x1b[1;5D", "\x1b[1;133D", "\x1b[1;3H", "\x1b[1;67F", "\x1b[3;130~", "\x1b[5;69~", "\x1b[6;2~", "\x1b[1;2~", "\x1b[4;5~", "\x1b[7;66~", "\x1b[8;3~" }) |seq| {
        try expectSequence(seq, .unknown);
    }
}

test "KeyParser: lock bits make no key of a sequence that has none, and no paste marker" {
    for ([_][]const u8{ "\x1b[2;65~", "\x1b[200;65~", "\x1b[201;129~", "\x1b[1;65P", "\x1b[2;65A" }) |seq| {
        try expectSequence(seq, .unknown);
    }
}

test "KeyParser: Shift+Tab split across reads still decodes once" {
    for ([_][]const u8{ "\x1b[9;2u", "\x1b[27;2;9~" }) |seq| {
        for (1..seq.len) |cut| {
            var p = KeyParser{};
            var keys: [4]Key = undefined;
            var n: usize = 0;
            for ([_][]const u8{ seq[0..cut], seq[cut..] }) |chunk| {
                for (chunk) |b| {
                    if (p.feed(b)) |k| {
                        keys[n] = k;
                        n += 1;
                    }
                    while (p.drain()) |k| {
                        keys[n] = k;
                        n += 1;
                    }
                }
                try testing.expectEqual(chunk.ptr == seq.ptr, p.pendingEsc());
            }
            try testing.expectEqualSlices(Key, &.{.shift_tab}, keys[0..n]);
        }
    }
}

test "KeyParser: an interrupted modifyOtherKeys sequence is dropped on flush" {
    var p = KeyParser{};
    for ("\x1b[27;2;") |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.flushEsc() == null);
    try testing.expect(!p.pendingEsc());
    for ("\x1b[27;2;9") |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.flushEsc() == null);
    try testing.expectEqual(@as(?Key, .{ .char = '~' }), p.feed('~'));
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

test "KeyParser: 同批到达的 ESC CR(/terminal-setup 绑定发的 Meta+Return)是 Shift+Enter" {
    var p = KeyParser{};
    // 终端一次写出 ESC CR:读到 ESC 时 CR 已在队列。
    try testing.expect(p.feedQueued(0x1b, true) == null);
    try testing.expect(p.feedQueued('\r', false).? == .shift_enter);
    try testing.expect(p.drain() == null);
    try testing.expect(!p.pendingEsc());
    // ESC LF 不是这个绑定:照旧 Esc + Enter 两键。
    try testing.expect(p.feedQueued(0x1b, true) == null);
    try testing.expect(p.feedQueued('\n', false).? == .esc);
    try testing.expect(p.drain().? == .enter);
}

test "KeyParser: 人按的 Esc 再按 Enter(分两次到达)仍是 Esc + Enter" {
    var p = KeyParser{};
    // 读到 ESC 时后面没有字节在等:哪怕 Enter 在 ESC 超时前到达,也是两个键。
    try testing.expect(p.feedQueued(0x1b, false) == null);
    try testing.expect(p.feedQueued('\r', false).? == .esc);
    try testing.expect(p.drain().? == .enter);
    // 读循环已按超时兑现的 Esc 同样。
    try testing.expect(p.feedQueued(0x1b, false) == null);
    try testing.expect(p.flushEsc().? == .esc);
    try testing.expect(p.feedQueued('\r', false).? == .enter);
    // 逐字节 feed(括号粘贴的读法)不知道批次:ESC CR 照旧是 Esc + Enter,粘贴内容不变。
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed('\r').? == .esc);
    try testing.expect(p.drain().? == .enter);
    // 上一个 ESC 的"同批"不会粘到下一个 ESC 上。
    try testing.expect(p.feedQueued(0x1b, true) == null);
    try testing.expect(p.feedQueued('x', false).? == .esc);
    try testing.expectEqual(@as(u8, 'x'), p.drain().?.char);
    try testing.expect(p.feed(0x1b) == null);
    try testing.expect(p.feed('\r').? == .esc);
    try testing.expect(p.drain().? == .enter);
}

test "readKey(Windows 控制台):ESC CR 同批读到是 Shift+Enter,ESC 读走后才到的 CR 是两个键" {
    // 往测试自己的控制台输入队列里写键盘记录,走真实的 readInput / waitReadable,不依赖 ConPTY 时序。
    // 编译期跳过:否则别的平台也要分析下面对 Windows API 的调用(macOS 不认 winapi 调用约定,
    // Linux 链接不到 kernel32 的符号)。
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var console = try @import("metacodes-internal").platform.test_support.PrivateConsole.begin();
    defer console.end();
    var p = KeyParser{};
    var b: [1]u8 = undefined;

    // 同批,在 readInput 的缓冲里:两个键都排好了才开读,ReadConsoleW 一次拿走两个字符,
    // 队列里不再有按下记录。读出 ESC 后,CR 还在缓冲里。
    try console.send(&.{ .{ .down = 0x1b }, .{ .up = 0x1b }, .{ .down = '\r' }, .{ .up = '\r' } });
    try testing.expectEqual(@as(isize, 1), platform_term.readInput(0, &b));
    try testing.expectEqual(@as(u8, 0x1b), b[0]);
    try testing.expectEqual(@as(usize, 0), console.keyDownsQueued());
    try testing.expectEqual(@as(i32, 1), platform_term.waitReadable(0, 0));
    try testing.expect(p.feedRead(0, b[0]) == null);
    try testing.expect(readKey(0, &p).key == .shift_enter);

    // 同批,在记录队列里:ReadConsoleW 只拿到 ESC,CR 的按下记录随后进队,前面夹着 ESC 的抬起和
    // 一次焦点变化(都不产字节)。waitReadable 跳过它们,数到 CR 的按下。
    try console.send(&.{.{ .down = 0x1b }});
    try testing.expectEqual(@as(isize, 1), platform_term.readInput(0, &b));
    try testing.expectEqual(@as(u8, 0x1b), b[0]);
    try console.send(&.{ .{ .up = 0x1b }, .focus, .{ .down = '\r' }, .{ .up = '\r' } });
    try testing.expectEqual(@as(i32, 1), platform_term.waitReadable(0, 0));
    try testing.expect(p.feedRead(0, b[0]) == null);
    try testing.expect(readKey(0, &p).key == .shift_enter);

    // 分两次:读走 ESC 时队列里只有抬起和焦点记录,waitReadable 把它们取走、答"没有"。Enter
    // 在 ESC 的等待期内才到,仍是 Esc + Enter 两个键。
    try console.send(&.{.{ .down = 0x1b }});
    try testing.expectEqual(@as(isize, 1), platform_term.readInput(0, &b));
    try console.send(&.{ .{ .up = 0x1b }, .focus });
    try testing.expectEqual(@as(i32, 0), platform_term.waitReadable(0, 0));
    try testing.expect(p.feedRead(0, b[0]) == null);
    try console.send(&.{ .{ .down = '\r' }, .{ .up = '\r' } });
    try testing.expect(readKey(0, &p).key == .esc);
    try testing.expect(readKey(0, &p).key == .enter);
}

test "readInput(Windows 控制台送按键记录):读出的是键,抬键记录不叫醒等待,半截的不是记录照原样" {
    // win32-input-mode 开着时控制台把一条记录逐字符排进队列(sendChars),与真机同形。
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var console = try @import("metacodes-internal").platform.test_support.PrivateConsole.begin();
    defer console.end();
    defer platform_term.resetConsoleInputForTesting();
    platform_term.decodeKeyRecords();
    var buf: [8]u8 = undefined;

    // ↓ 按下 + 抬起:对话框一次读 8 字节,读到的是 ↓ 的 VT 字节,不是记录。
    try console.sendChars("\x1b[40;80;0;1;288;1_\x1b[40;80;0;0;288;1_");
    try testing.expectEqual(@as(isize, 3), platform_term.readInput(0, &buf));
    try testing.expectEqualStrings("\x1b[B", buf[0..3]);
    try testing.expect(platform_term.lastReadWasKeyRecord());

    // Esc 读走之后才到的抬键记录不产字节:等 Esc 后续的那一轮等待照旧到时(0),不被它叫醒,
    // 它也被取走了。
    try console.sendChars("\x1b[27;1;27;1;32;1_");
    try testing.expectEqual(@as(isize, 1), platform_term.readInput(0, buf[0..1]));
    try testing.expectEqual(@as(u8, 0x1b), buf[0]);
    try console.sendChars("\x1b[27;1;27;0;32;1_");
    try testing.expectEqual(@as(i32, 0), platform_term.waitReadable(0, 100));
    try testing.expectEqual(@as(usize, 0), console.keyDownsQueued());

    // 队列到头时还没成记录的字节(这里是终端写来的 x 和 ESC [ 1 2):原样交出,不等下一个键。
    try console.sendChars("x\x1b[12");
    var got: usize = 0;
    var reads: usize = 0;
    while (got < 5 and reads < 3) : (reads += 1) {
        const n = platform_term.readInput(0, buf[got..]);
        try testing.expect(n > 0);
        got += @intCast(n);
    }
    try testing.expectEqualStrings("x\x1b[12", buf[0..got]);
    try testing.expect(!platform_term.lastReadWasKeyRecord());
}

test "readInput(Windows 控制台送按键记录):一条记录被 ReadConsoleW 的 256 字符一批切开,读出的仍是那个键" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var console = try @import("metacodes-internal").platform.test_support.PrivateConsole.begin();
    defer console.end();
    defer platform_term.resetConsoleInputForTesting();
    platform_term.decodeKeyRecords();
    // 250 个终端写来的字,再一条 ↓ 记录(按下 19 字符 + 抬起):第一批 256 个字符在记录的第 6 个
    // 字符处截断,剩下的还排在队列里。
    try console.sendChars("x" ** 250 ++ "\x1b[40;80;0;1;288;1_\x1b[40;80;0;0;288;1_");
    var got: [300]u8 = undefined;
    var n: usize = 0;
    var reads: usize = 0;
    while (n < 253 and reads < 16) : (reads += 1) {
        const r = platform_term.readInput(0, got[n..@min(n + 64, got.len)]);
        try testing.expect(r > 0);
        n += @intCast(r);
    }
    try testing.expectEqualStrings("x" ** 250 ++ "\x1b[B", got[0..n]);
    try testing.expect(platform_term.lastReadWasKeyRecord());
    try testing.expectEqual(@as(i32, 0), platform_term.waitReadable(0, 0)); // 抬起记录读走了,不产字节
}

test "lendTerminal(Windows 控制台):编辑器拿到的控制台没有 win32-input-mode 和括号粘贴,还回来再打开" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var console = try @import("metacodes-internal").platform.test_support.PrivateConsole.begin();
    defer console.end();
    defer platform_term.resetConsoleInputForTesting();
    // 控制台模式序列写进一个文件(这里 stdout 不是控制台),按写入顺序核对。
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/metacodes-lend-test-{d}.txt", .{ ppaths.tempDir(), process.currentPid() });
    const out = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    try testing.expect(out >= 0);
    defer pfs.unlinkPath(path.ptr) catch {};
    defer _ = pfs.close(out);
    g_console_out_for_testing = out;
    defer g_console_out_for_testing = null;
    const ENABLE_LINE_INPUT: u32 = 0x0002;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;

    // REPL 的 raw 模式:9001 与 2004 开着。
    const before = platform_term.enterRaw(0) orelse return error.TestUnexpectedResult;
    defer platform_term.restoreMode(0, before);
    emitEnableSequences(0);
    try expectFile(path, console_enable);

    // 编辑器运行期间:两者关着,控制台是 cooked(行输入),也不带 VT 输入。
    const lent = lendTerminal(0) orelse return error.TestUnexpectedResult;
    try expectFile(path, console_enable ++ console_disable);
    const during = platform_term.saveMode(0).?;
    try testing.expect(during.in_mode & ENABLE_LINE_INPUT != 0);
    try testing.expect(during.in_mode & ENABLE_VIRTUAL_TERMINAL_INPUT == 0);

    // 还回来:raw 模式,两者重新打开。
    takeBackTerminal(0, lent);
    try expectFile(path, console_enable ++ console_disable ++ console_enable);
    const after = platform_term.saveMode(0).?;
    try testing.expect(after.in_mode & ENABLE_LINE_INPUT == 0);
    try testing.expect(after.in_mode & ENABLE_VIRTUAL_TERMINAL_INPUT != 0);
}

/// `path` 的全部内容是 `want`。
fn expectFile(path: [:0]const u8, want: []const u8) !void {
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    try testing.expect(fd >= 0);
    defer _ = pfs.close(fd);
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const r = pfs.read(fd, buf[n..]); // no EINTR: regular file, not the terminal
        if (r <= 0) break;
        n += @intCast(r);
    }
    try testing.expectEqualStrings(want, buf[0..n]);
}

test "readKey(Windows 控制台送按键记录):Esc 记录后面排着 Enter 也是两个键;终端写来的 ESC CR 是 Shift+Enter" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    var console = try @import("metacodes-internal").platform.test_support.PrivateConsole.begin();
    defer console.end();
    defer platform_term.resetConsoleInputForTesting();
    platform_term.decodeKeyRecords();
    var p = KeyParser{};

    // 人连按 Esc、Enter:两条记录一起排在队列里,Esc 也不算同批(它是按键记录)。
    try console.sendChars("\x1b[27;1;27;1;32;1_\x1b[27;1;27;0;32;1_\x1b[13;28;13;1;32;1_\x1b[13;28;13;0;32;1_");
    try testing.expect(readKey(0, &p).key == .esc);
    try testing.expect(readKey(0, &p).key == .enter);

    // VS Code 的 Shift+Enter 绑定一次写出 ESC CR:ConPTY 原样排成两个字符,不是记录。
    try console.sendChars("\x1b\r");
    try testing.expect(readKey(0, &p).key == .shift_enter);
}

test "LineEditor: 同批的 ESC CR 经 KeyParser 插换行,单独的 CR 提交" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    var p = KeyParser{};
    var last: Action = .none;
    const typed = "a\x1b\rb\r";
    for (typed, 0..) |b, i| {
        if (p.feedQueued(b, i + 1 < typed.len)) |k| last = try ed.handle(k);
        while (p.drain()) |k| last = try ed.handle(k);
    }
    try testing.expectEqualStrings("a\nb", ed.view());
    try testing.expectEqual(Action.commit, last);
}

test "newlineHint:终端里装了 Shift+Enter 绑定(recordNewlineBinding)就提示 Shift+Enter" {
    defer recordNewlineBinding(false);
    recordNewlineBinding(true);
    try testing.expectEqualStrings("shift + \xe2\x8f\x8e for newline", newlineHint());
    recordNewlineBinding(false);
    if (!shouldEnableKittyKeyboard()) try testing.expectEqualStrings("\\ + \xe2\x8f\x8e for newline", newlineHint());
}

test "enterRawMode on non-tty returns null or restores cleanly" {
    const orig = enterRawMode(0);
    if (orig) |o| restoreMode(0, o);
}

test "an interrupted key read is retried unless the process is shutting down" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    defer shutdown.resetForTesting();
    // No resume is pending, so the fd is never touched.
    std.c._errno().* = @intFromEnum(std.c.E.INTR);
    try testing.expect(retryInterruptedRead(-1));
    // A real read failure still ends the reader.
    std.c._errno().* = @intFromEnum(std.c.E.IO);
    try testing.expect(!retryInterruptedRead(-1));
    // SIGINT asked the process to stop: the interrupted dialog ends as before.
    shutdown.request();
    std.c._errno().* = @intFromEnum(std.c.E.INTR);
    try testing.expect(!retryInterruptedRead(-1));
}

test "readKey assembles a sequence, reports a lone Esc once the wait runs out, and stops at end of input" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // pipe as the terminal
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    var parser = KeyParser{};
    try testing.expect(pfs.writeAll(fds[1], "\x1b[Aq\x1b"));
    try testing.expect(readKey(fds[0], &parser).key == .up);
    try testing.expectEqual(@as(u8, 'q'), readKey(fds[0], &parser).key.char);
    // Nothing follows the ESC: it is the Esc key, not the start of a sequence
    // that waits for the next key.
    try testing.expect(readKey(fds[0], &parser).key == .esc);
    _ = std.c.close(fds[1]);
    try testing.expect(readKey(fds[0], &parser) == .closed);
}

// The case #340 describes: the terminal's resize lands between ESC and `[`.
// The REPL's SIGWINCH handler has no SA_RESTART, so the wait for the rest of
// the sequence returns EINTR. It used to end the read (reverse search
// cancelled, viewer closed) and leave `[A` to be read as typed text.
test "a resize between ESC and [ interrupts readKey and leaves the sequence in the parser" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    defer shutdown.resetForTesting();
    var saved: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.WINCH, null, &saved);
    defer std.posix.sigaction(std.posix.SIG.WINCH, &saved, null);
    platform_signal.installResize(struct {
        fn onResize() void {}
    }.onResize);

    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    try testing.expect(pfs.writeAll(fds[1], "\x1b"));

    const Reader = struct {
        fd: c_int,
        parser: KeyParser = .{},
        got: KeyRead = .closed,
        started: std.atomic.Value(bool) = .init(false),
        finished: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.got = readKey(self.fd, &self.parser);
            self.finished.store(true, .release);
        }
    };
    var reader: Reader = .{ .fd = fds[0] };
    const thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    while (!reader.started.load(.acquire)) std.Thread.yield() catch {};
    // Keep resizing until the reader is back: the first signal may land
    // before it blocks.
    var rounds: usize = 0;
    while (rounds < 100 and !reader.finished.load(.acquire)) : (rounds += 1) {
        @import("metacodes-internal").platform.sync.sleepMs(2);
        _ = std.c.pthread_kill(thread.getHandle(), std.posix.SIG.WINCH);
    }
    thread.join();
    try testing.expect(reader.got == .interrupted);
    try testing.expect(reader.parser.pendingEsc());

    try testing.expect(pfs.writeAll(fds[1], "[A"));
    try testing.expect(readKey(fds[0], &reader.parser).key == .up);
}

test "reconcileModes on a non-tty is a no-op" {
    if (@import("builtin").os.tag == .windows) return;
    const fd = pfs.openZ("/dev/null", .{ .ACCMODE = .RDONLY }, 0) catch unreachable;
    defer _ = pfs.close(fd);
    try testing.expect(!reconcileModes(fd));
}

test "键盘协议序列字节(接线:enter/restore 发的就是这些)" {
    // Kitty disambiguate(>1u)是 Warp/iTerm/kitty 等区分 Shift/Ctrl+Enter 的关键。
    // 实测:Warp 收到 \x1b[>1u 后 Shift+Enter 才发 \x1b[13;2u。
    try testing.expectEqualStrings("\x1b[<u\x1b[>1u\x1b[>4;2m", kbd_enable_seq);
    try testing.expectEqualStrings("\x1b[<u\x1b[>4m", kbd_disable_seq);
}

test "classifyKittyKeyboard:deny-list / 认得出 / 探测 分流矩阵" {
    const t = "xterm-256color";
    // deny-list(#23350 的教训):Apple Terminal、xterm.js 的宿主——不发也不问,探测答了也不算。
    try testing.expectEqual(KeyboardPolicy.disable, classifyKittyKeyboard("Apple_Terminal", t, .none));
    try testing.expectEqual(KeyboardPolicy.disable, classifyKittyKeyboard("vscode", t, .none));
    try testing.expectEqual(KeyboardPolicy.disable, classifyKittyKeyboard("Hyper", t, .none));
    // 认得出的 TERM_PROGRAM(含实测追加的 Warp)→ 直接发,不问。
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("WarpTerminal", t, .none));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("iTerm.app", t, .none));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("WezTerm", t, .none));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("ghostty", t, .none));
    // TERM 子串命中(TERM_PROGRAM 可能不设,SSH 只带 TERM 过去)。
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard(null, "xterm-kitty", .none));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard(null, "xterm-ghostty", .none));
    // 认不出 → 问终端(SSH 远端、Linux 控制台、foot、Alacritty……)。
    try testing.expectEqual(KeyboardPolicy.probe, classifyKittyKeyboard(null, t, .none));
    try testing.expectEqual(KeyboardPolicy.probe, classifyKittyKeyboard("SomeNewTerminal", t, .none));
    try testing.expectEqual(KeyboardPolicy.probe, classifyKittyKeyboard(null, "linux", .none));
    // dumb / 没有 TERM(Windows console 常态)→ 什么都不发,也不问。
    try testing.expectEqual(KeyboardPolicy.disable, classifyKittyKeyboard(null, null, .none));
    try testing.expectEqual(KeyboardPolicy.disable, classifyKittyKeyboard(null, "", .none));
    try testing.expectEqual(KeyboardPolicy.disable, classifyKittyKeyboard("iTerm.app", "dumb", .tmux));
    // TERM 认得出的终端先于 deny-list:从 Terminal.app / VS Code 里启动的 kitty、Ghostty 继承了
    // 外层的 TERM_PROGRAM,TERM 才是它自己设的。
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("Apple_Terminal", "xterm-kitty", .none));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("vscode", "xterm-ghostty", .none));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("Hyper", "xterm-kitty", .other));
    // tmux 照旧直接发;其它复用器照旧只看环境(答查询的是复用器自己,不问)。
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard(null, "screen-256color", .tmux));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("vscode", "tmux-256color", .tmux));
    try testing.expectEqual(KeyboardPolicy.disable, classifyKittyKeyboard(null, "screen-256color", .other));
    try testing.expectEqual(KeyboardPolicy.enable, classifyKittyKeyboard("ghostty", t, .other));
}

test "rescueTerminal writes the off sequences once, only while armed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const was_installed = g_rescue_installed.swap(true, .acq_rel);
    defer g_rescue_installed.store(was_installed, .release);
    const was_mouse = mouseSelectionOn();
    defer recordMouseSelection(was_mouse);
    defer disarmRescue();
    const envs = [_]SavedEnv{
        try SavedEnv.set("TERM", "xterm-kitty"),
        try SavedEnv.set(no_keyboard_enhancement_env, null),
    };
    defer for (envs) |saved| saved.restore();
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const mode = std.mem.zeroes(platform_term.SavedMode);
    var buf: [128]u8 = undefined;

    recordMouseSelection(true);
    armRescue(fds[1], mode);
    rescueTerminal();
    rescueTerminal();
    const all = "\x1b[?2004l" ++ mouse_selection_disable ++ kbd_disable_seq;
    try testing.expectEqual(@as(isize, all.len), std.c.read(fds[0], &buf, buf.len));
    try testing.expectEqualStrings(all, buf[0..all.len]);
    try testing.expectEqual(@as(c_int, 0), platform_term.waitReadable(fds[0], 0));

    recordMouseSelection(false);
    ppaths.setEnv(no_keyboard_enhancement_env, "1");
    armRescue(fds[1], mode);
    disarmRescue();
    rescueTerminal();
    try testing.expectEqual(@as(c_int, 0), platform_term.waitReadable(fds[0], 0));
    rearmRescue();
    rescueTerminal();
    const paste_only = "\x1b[?2004l";
    try testing.expectEqual(@as(isize, paste_only.len), std.c.read(fds[0], &buf, buf.len));
    try testing.expectEqualStrings(paste_only, buf[0..paste_only.len]);
}

test "shouldEnableKittyKeyboard: 要探测的终端只在答了 Kitty flags 时才发,提示文案跟着走" {
    const saved = g_kitty_answered.load(.acquire);
    defer recordKeyboardProbe(saved);
    const shift = "shift + \xe2\x8f\x8e for newline";
    const backslash = "\\ + \xe2\x8f\x8e for newline";
    for ([_]bool{ true, false }) |answered| {
        recordKeyboardProbe(answered);
        const expected = switch (keyboardPolicy()) {
            .enable => true,
            .disable => false,
            .probe => answered,
        };
        try testing.expectEqual(expected, shouldEnableKittyKeyboard());
        try testing.expectEqualStrings(if (expected and !nonEmptyEnv("TMUX")) shift else backslash, newlineHint());
    }
}

fn savedEnv(name: [*:0]const u8) !?[:0]u8 {
    return if (std.c.getenv(name)) |raw| try testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
}

fn restoreEnv(name: [*:0]const u8, saved: ?[:0]u8) void {
    if (saved) |value| {
        ppaths.setEnv(name, value.ptr);
        testing.allocator.free(value);
    } else ppaths.unsetEnv(name);
}

const SavedEnv = struct {
    name: [*:0]const u8,
    value: ?[:0]u8,

    fn set(name: [*:0]const u8, value: ?[*:0]const u8) !SavedEnv {
        const previous = if (std.c.getenv(name)) |raw| try testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .name = name, .value = previous };
    }

    fn restore(self: SavedEnv) void {
        if (self.value) |v| {
            ppaths.setEnv(self.name, v.ptr);
            testing.allocator.free(v);
        } else ppaths.unsetEnv(self.name);
    }
};

test "newlineHint: inside tmux the keyboard protocol stays on, but the hint is \\ + ⏎: tmux sends Shift+Enter as Enter unless extended-keys forwards it" {
    defer recordNewlineBinding(false);
    recordNewlineBinding(false);
    const envs = [_]SavedEnv{
        try SavedEnv.set("TMUX", "/tmp/tmux-0/default,1,0"),
        try SavedEnv.set("TERM", "xterm-256color"),
        try SavedEnv.set(no_keyboard_enhancement_env, null),
    };
    defer for (envs) |saved| saved.restore();
    try testing.expect(shouldEnableKittyKeyboard());
    if (platform_term.keyRecordsTypeText()) return;
    try testing.expectEqualStrings("\\ + \xe2\x8f\x8e for newline", newlineHint());
}

test "keyboardPolicy: METACODES_NO_KEYBOARD_ENHANCEMENT keeps the protocol off for every terminal, and keyboardSummary says why" {
    const previous_answer = g_kitty_answered.load(.acquire);
    defer recordKeyboardProbe(previous_answer);
    const saved_term = try savedEnv("TERM");
    defer restoreEnv("TERM", saved_term);
    const saved_opt_out = try savedEnv(no_keyboard_enhancement_env);
    defer restoreEnv(no_keyboard_enhancement_env, saved_opt_out);
    ppaths.setEnv("TERM", "xterm-kitty");

    ppaths.unsetEnv(no_keyboard_enhancement_env);
    try testing.expect(!keyboardEnhancementOptedOut());
    try testing.expectEqual(KeyboardPolicy.enable, keyboardPolicy());
    try testing.expect(shouldEnableKittyKeyboard());
    try testing.expectEqualStrings("on (Kitty protocol, modifyOtherKeys) · METACODES_NO_KEYBOARD_ENHANCEMENT=1 turns it off", keyboardSummary());

    ppaths.setEnv(no_keyboard_enhancement_env, "1");
    for ([_]bool{ true, false }) |answered| {
        recordKeyboardProbe(answered);
        try testing.expect(keyboardEnhancementOptedOut());
        try testing.expectEqual(KeyboardPolicy.disable, keyboardPolicy());
        try testing.expect(!shouldEnableKittyKeyboard());
        try testing.expectEqualStrings("off · METACODES_NO_KEYBOARD_ENHANCEMENT is set", keyboardSummary());
        try testing.expectEqualStrings("\\ + \xe2\x8f\x8e for newline", newlineHint());
    }
}

test "KeyParser: 迟到的终端应答整条吃掉,不漏成字符" {
    // DA1(Windows Terminal 实测的那条)、Kitty flags、OSC 之外的私有 CSI,以及 xterm 式
    // modifyOtherKeys 三段参数:每条报一个 .unknown,前后敲的字照常。
    var p = KeyParser{};
    const stream = "a\x1b[?61;4;6;7;14;21;22;23;24;28;32;42;52cb\x1b[?1uc\x1b[>4;2md\x1b[27;7;120~e\x1b[1;5Af";
    var chars: [8]u8 = undefined;
    var n_chars: usize = 0;
    var unknowns: usize = 0;
    for (stream) |b| {
        const k = p.feed(b) orelse continue;
        switch (k) {
            .char => |c| {
                chars[n_chars] = c;
                n_chars += 1;
            },
            .unknown => unknowns += 1,
            else => return error.TestUnexpectedResult,
        }
        try testing.expect(p.drain() == null);
    }
    try testing.expectEqualStrings("abcdef", chars[0..n_chars]);
    try testing.expectEqual(@as(usize, 5), unknowns);
}

/// 喂完 stream,按产出顺序收集全部键(含 drain 出的)。
fn parseAll(stream: []const u8, out: []Key) []Key {
    var p = KeyParser{};
    var n: usize = 0;
    for (stream) |b| {
        if (p.feed(b)) |k| {
            out[n] = k;
            n += 1;
        }
        while (p.drain()) |k| {
            out[n] = k;
            n += 1;
        }
    }
    if (p.flushEsc()) |k| {
        out[n] = k;
        n += 1;
        while (p.drain()) |k2| {
            out[n] = k2;
            n += 1;
        }
    }
    return out[0..n];
}

fn parseChunks(stream: []const u8, cuts: []const usize, out: []Key) []Key {
    var p = KeyParser{};
    var n: usize = 0;
    var start: usize = 0;
    for (0..cuts.len + 1) |i| {
        const end = if (i < cuts.len) cuts[i] else stream.len;
        const chunk = stream[start..end];
        for (chunk, 0..) |b, j| {
            if (p.feedQueued(b, j + 1 < chunk.len)) |k| {
                out[n] = k;
                n += 1;
            }
            while (p.drain()) |k| {
                out[n] = k;
                n += 1;
            }
        }
        start = end;
    }
    if (p.flushEsc()) |k| {
        out[n] = k;
        n += 1;
    }
    return out[0..n];
}

test "KeyParser: a stream of legacy, CSI u and modifyOtherKeys keys decodes the same however the reads split it" {
    const stream = "a\x1b[1~\x1b[4~\x1b[7~\x1b[8~\x1b[1;65A\x1b[3;129~" ++
        "\x1b[45;6u\x1b[27;6;45~\x1b[47;5u\x1b[27;5;95~\x1f" ++
        "\x1b[127;2u\x1b[27;2;127~\x1b[104;5u\x7f\x08" ++
        "\x1b[106;5u\x1b[27;5;109~\x1b[105;5u\t\x1b[91;5u" ++
        "\x1b[13;3u\x1b[27;3;13~\x1b[13;2u\x1b[27;2;32~\x1b[32;66u" ++
        "\x1b[9;2u\x1b[Z\x1b[99;5u\x1b[98;3u\x1bf\x1b\x1b[B" ++
        "\x1b[200~x\x1b[201~\x1b[12;40R\x1b[1;2A\x1b[27;7;120~z";
    const expected = [_]Key{ .{ .char = 'a' }, .home, .end, .home, .end, .up, .delete } ++
        [_]Key{.ctrl_underscore} ** 5 ++
        [_]Key{.backspace} ** 5 ++
        [_]Key{ .enter, .enter, .tab, .tab, .esc } ++
        [_]Key{.shift_enter} ** 3 ++ [_]Key{.{ .char = ' ' }} ** 2 ++
        [_]Key{ .shift_tab, .shift_tab, .ctrl_c, .alt_b, .alt_f, .esc, .down } ++
        [_]Key{ .paste_begin, .{ .char = 'x' }, .paste_end, .{ .cursor_position = .{ .row = 12, .col = 40 } }, .unknown, .unknown, .{ .char = 'z' } };
    var buf: [64]Key = undefined;
    try testing.expectEqualSlices(Key, &expected, parseChunks(stream, &.{}, &buf));
    try testing.expectEqualSlices(Key, &expected, parseAll(stream, &buf));

    for (1..stream.len) |cut| {
        errdefer std.debug.print("one cut at byte {d}\n", .{cut});
        try testing.expectEqualSlices(Key, &expected, parseChunks(stream, &.{cut}, &buf));
    }
    var cuts: [stream.len]usize = undefined;
    for (1..stream.len) |size| {
        errdefer std.debug.print("reads of {d} bytes\n", .{size});
        var n: usize = 0;
        var at = size;
        while (at < stream.len) : (at += size) {
            cuts[n] = at;
            n += 1;
        }
        try testing.expectEqualSlices(Key, &expected, parseChunks(stream, cuts[0..n], &buf));
    }
    var prng = std.Random.DefaultPrng.init(0x6b657973);
    const random = prng.random();
    for (0..500) |round| {
        errdefer std.debug.print("random split round {d}\n", .{round});
        var n: usize = 0;
        var at: usize = 0;
        while (true) {
            at += random.intRangeAtMost(usize, 1, 12);
            if (at >= stream.len) break;
            cuts[n] = at;
            n += 1;
        }
        try testing.expectEqualSlices(Key, &expected, parseChunks(stream, cuts[0..n], &buf));
    }
}

const TimedWrite = struct { bytes: []const u8, after_ms: u64 };

fn parseTimed(writes: []const TimedWrite, out: []Key) []Key {
    var bytes: [1024]u8 = undefined;
    var gaps: [1024]u64 = undefined;
    var total: usize = 0;
    var pending_gap: u64 = std.math.maxInt(u64);
    for (writes) |write| {
        pending_gap = @min(pending_gap, write.after_ms);
        for (write.bytes) |b| {
            bytes[total] = b;
            gaps[total] = pending_gap;
            pending_gap = 0;
            total += 1;
        }
        if (write.bytes.len > 0) pending_gap = std.math.maxInt(u64);
    }
    var p = KeyParser{};
    var n: usize = 0;
    for (bytes[0..total], 0..) |b, i| {
        const next: ?NextArrival = if (i + 1 < total) .{
            .byte = bytes[i + 1],
            .gap_ms = gaps[i + 1],
            .after_gap_ms = if (i + 2 < total) gaps[i + 2] else null,
        } else null;
        if (p.feedTimed(b, gaps[i], next)) |k| {
            out[n] = k;
            n += 1;
        }
        while (p.drain()) |k| {
            out[n] = k;
            n += 1;
        }
    }
    if (p.flushEsc()) |k| {
        out[n] = k;
        n += 1;
    }
    return out[0..n];
}

fn typedText(keys: []const Key, out: []u8) []const u8 {
    var n: usize = 0;
    for (keys) |k| {
        const c: ?u8 = switch (k) {
            .char => |c| c,
            .shift_enter => '\n',
            .enter => '\r',
            else => null,
        };
        if (c) |byte| {
            out[n] = byte;
            n += 1;
        }
    }
    return out[0..n];
}

fn expectTimedText(writes: []const TimedWrite, expected: []const u8) !void {
    var keys: [512]Key = undefined;
    var text: [512]u8 = undefined;
    try testing.expectEqualStrings(expected, typedText(parseTimed(writes, &keys), &text));
}

test "paste burst: a multi-line paste without bracketed paste markers gives line breaks, never Enter" {
    try expectTimedText(&.{.{ .bytes = "one two\rthree\rfour", .after_ms = 1000 }}, "one two\nthree\nfour");
    try expectTimedText(&.{.{ .bytes = "one\rtwo\r", .after_ms = 1000 }}, "one\ntwo\n");
    try expectTimedText(&.{.{ .bytes = "a\rb", .after_ms = 1000 }}, "a\nb");
    try expectTimedText(&.{.{ .bytes = "a\rb\r", .after_ms = 1000 }}, "a\nb\n");
    try expectTimedText(&.{.{ .bytes = "unix\nline feeds\n", .after_ms = 1000 }}, "unix\nline feeds\n");
    try expectTimedText(&.{.{ .bytes = "a1\r\nb2\r\nc3\r\n", .after_ms = 1000 }}, "a1\nb2\nc3\n");
    try expectTimedText(&.{.{ .bytes = "blank\r\rline", .after_ms = 1000 }}, "blank\n\nline");
}

test "paste burst: one line written together with its Enter is sent, as a script or tmux send-keys writes it" {
    try expectTimedText(&.{.{ .bytes = "hello\r", .after_ms = 1000 }}, "hello\r");
    try expectTimedText(&.{.{ .bytes = "hello\n", .after_ms = 1000 }}, "hello\r");
    try expectTimedText(&.{.{ .bytes = "hello\r\n", .after_ms = 1000 }}, "hello\r");
    try expectTimedText(&.{.{ .bytes = "a longer line of text, written at once\r", .after_ms = 1000 }}, "a longer line of text, written at once\r");
    try expectTimedText(&.{ .{ .bytes = "hello\r", .after_ms = 1000 }, .{ .bytes = "next\r", .after_ms = 300 } }, "hello\rnext\r");
}

test "paste burst: a newline at the start of the terminal's next chunk is still a line break" {
    try expectTimedText(&.{ .{ .bytes = "first part of it", .after_ms = 1000 }, .{ .bytes = "\rnext", .after_ms = 3 } }, "first part of it\nnext");
    try expectTimedText(&.{ .{ .bytes = "abc", .after_ms = 1000 }, .{ .bytes = "\rdef", .after_ms = 40 } }, "abc\ndef");
}

test "paste burst: typing at human speed, fast typing with rollover and a lone Enter all submit" {
    try expectTimedText(&.{ .{ .bytes = "h", .after_ms = 1000 }, .{ .bytes = "e", .after_ms = 90 }, .{ .bytes = "l", .after_ms = 120 }, .{ .bytes = "l", .after_ms = 80 }, .{ .bytes = "o", .after_ms = 100 }, .{ .bytes = "\r", .after_ms = 150 } }, "hello\r");
    try expectTimedText(&.{ .{ .bytes = "f", .after_ms = 1000 }, .{ .bytes = "a", .after_ms = 25 }, .{ .bytes = "s", .after_ms = 12 }, .{ .bytes = "t", .after_ms = 30 }, .{ .bytes = "\r", .after_ms = 40 } }, "fast\r");
    try expectTimedText(&.{ .{ .bytes = "o", .after_ms = 1000 }, .{ .bytes = "k", .after_ms = 4 }, .{ .bytes = "\r", .after_ms = 5 } }, "ok\r");
    try expectTimedText(&.{.{ .bytes = "\r", .after_ms = 1000 }}, "\r");
}

test "paste burst: an IME committing several CJK characters at once, then Enter 150 ms later, submits" {
    try expectTimedText(&.{ .{ .bytes = "你好世界", .after_ms = 1000 }, .{ .bytes = "\r", .after_ms = 150 } }, "你好世界\r");
    try expectTimedText(&.{ .{ .bytes = "中文", .after_ms = 1000 }, .{ .bytes = "\r", .after_ms = 20 } }, "中文\r");
}

test "paste burst: the 10 ms limit, before the input after an Enter and inside a burst" {
    try testing.expectEqual(@as(u64, 10), paste_burst_gap_ms);
    try expectTimedText(&.{ .{ .bytes = "abc", .after_ms = 1000 }, .{ .bytes = "\r", .after_ms = 500 }, .{ .bytes = "x", .after_ms = 10 } }, "abc\nx");
    try expectTimedText(&.{ .{ .bytes = "abc", .after_ms = 1000 }, .{ .bytes = "\r", .after_ms = 500 }, .{ .bytes = "x", .after_ms = 11 } }, "abc\rx");
    try expectTimedText(&.{ .{ .bytes = "one\rtwo", .after_ms = 1000 }, .{ .bytes = "\r", .after_ms = 10 } }, "one\ntwo\n");
    try expectTimedText(&.{ .{ .bytes = "one\rtwo", .after_ms = 1000 }, .{ .bytes = "\r", .after_ms = 11 } }, "one\ntwo\r");
    try expectTimedText(&.{ .{ .bytes = "one\rtwo", .after_ms = 1000 }, .{ .bytes = "!", .after_ms = 11 }, .{ .bytes = "\r", .after_ms = 0 } }, "one\ntwo!\r");
}

test "paste burst: keys that send several bytes at once, then Enter, still submit" {
    var buf: [16]Key = undefined;
    try testing.expectEqualSlices(Key, &.{ .up, .enter }, parseTimed(&.{ .{ .bytes = "\x1b[A", .after_ms = 1000 }, .{ .bytes = "\r", .after_ms = 50 } }, &buf));
    try testing.expectEqualSlices(Key, &.{ .ctrl_c, .enter }, parseTimed(&.{ .{ .bytes = "\x1b[99;5u", .after_ms = 1000 }, .{ .bytes = "\r", .after_ms = 60 } }, &buf));
    try testing.expectEqualSlices(Key, &.{.shift_enter}, parseTimed(&.{.{ .bytes = "\x1b\r", .after_ms = 1000 }}, &buf));
    try testing.expectEqualSlices(Key, &.{ .esc, .enter }, parseTimed(&.{ .{ .bytes = "\x1b", .after_ms = 1000 }, .{ .bytes = "\r", .after_ms = 100 } }, &buf));
}

test "paste burst: bracketed paste markers win, and the Enter after them submits" {
    var buf: [32]Key = undefined;
    const keys = parseTimed(&.{ .{ .bytes = "\x1b[200~one\rtwo\x1b[201~", .after_ms = 1000 }, .{ .bytes = "\r", .after_ms = 5 } }, &buf);
    try testing.expectEqualSlices(Key, &.{ .paste_begin, .{ .char = 'o' }, .{ .char = 'n' }, .{ .char = 'e' }, .enter, .{ .char = 't' }, .{ .char = 'w' }, .{ .char = 'o' }, .paste_end, .enter }, keys);
}

test "paste burst: a bracketed paste ends the burst before it, so an Enter right after the paste submits" {
    var buf: [32]Key = undefined;
    const keys = parseTimed(&.{ .{ .bytes = "a\rb\r\x1b[200~x\x1b[201~", .after_ms = 1000 }, .{ .bytes = "\r", .after_ms = 5 } }, &buf);
    try testing.expectEqualSlices(Key, &.{ .{ .char = 'a' }, .shift_enter, .{ .char = 'b' }, .shift_enter, .paste_begin, .{ .char = 'x' }, .paste_end, .enter }, keys);
}

test "paste burst: splitting a write into back-to-back writes anywhere never changes the keys" {
    const writes = [_]TimedWrite{
        .{ .bytes = "h", .after_ms = 1000 },                        .{ .bytes = "i", .after_ms = 90 },                                .{ .bytes = "\r", .after_ms = 150 },
        .{ .bytes = "one two\r\nthree\rfour\r", .after_ms = 2000 }, .{ .bytes = "\r", .after_ms = 400 },
        .{ .bytes = "你好世界", .after_ms = 1000 },
        .{ .bytes = "\r", .after_ms = 150 },                        .{ .bytes = "\x1b[200~pasted\rtext\x1b[201~", .after_ms = 1000 }, .{ .bytes = "\r", .after_ms = 5 },
        .{ .bytes = "\x1b[A", .after_ms = 1000 },                   .{ .bytes = "\r", .after_ms = 50 },                               .{ .bytes = "\x1b\r", .after_ms = 1000 },
        .{ .bytes = "abc", .after_ms = 1000 },                      .{ .bytes = "\rdef", .after_ms = 40 },                            .{ .bytes = "\r", .after_ms = 300 },
    };
    var expected_buf: [256]Key = undefined;
    const expected = parseTimed(&writes, &expected_buf);
    var split: [128]TimedWrite = undefined;
    var buf: [256]Key = undefined;
    for (writes, 0..) |write, w| {
        for (1..write.bytes.len) |cut| {
            errdefer std.debug.print("write {d} cut at byte {d}\n", .{ w, cut });
            var n: usize = 0;
            for (writes, 0..) |other, o| {
                if (o == w) {
                    split[n] = .{ .bytes = other.bytes[0..cut], .after_ms = other.after_ms };
                    split[n + 1] = .{ .bytes = other.bytes[cut..], .after_ms = 0 };
                    n += 2;
                } else {
                    split[n] = other;
                    n += 1;
                }
            }
            try testing.expectEqualSlices(Key, expected, parseTimed(split[0..n], &buf));
        }
    }
    var prng = std.Random.DefaultPrng.init(0x62757273);
    const random = prng.random();
    for (0..300) |round| {
        errdefer std.debug.print("random split round {d}\n", .{round});
        var n: usize = 0;
        for (writes) |write| {
            var start: usize = 0;
            var first = true;
            while (start < write.bytes.len) {
                const left = write.bytes.len - start;
                const len = if (left > 1 and random.boolean()) random.intRangeAtMost(usize, 1, left - 1) else left;
                split[n] = .{ .bytes = write.bytes[start .. start + len], .after_ms = if (first) write.after_ms else 0 };
                first = false;
                n += 1;
                start += len;
            }
        }
        try testing.expectEqualSlices(Key, expected, parseTimed(split[0..n], &buf));
    }
}

fn readEditorKey(fd: c_int, parser: *KeyParser) !Key {
    if (parser.drain()) |key| return key;
    while (true) {
        if (platform_term.waitReadable(fd, 2000) <= 0) return error.TestUnexpectedResult;
        var b: [1]u8 = undefined;
        if (platform_term.readInput(fd, &b) != 1) return error.TestUnexpectedResult; // no EINTR: waitReadable reported data
        if (parser.feedEditorRead(fd, b[0])) |key| return key;
    }
}

fn readKeys(fd: c_int, parser: *KeyParser, count: usize, out: []Key) ![]Key {
    for (out[0..count]) |*slot| slot.* = try readEditorKey(fd, parser);
    return out[0..count];
}

test "feedRead: outside the prompt's editor keys written together each count, Enter included" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    var parser = KeyParser{};
    try testing.expect(pfs.writeAll(fds[1], "\x1b[B\x1b[B\x1b[B\rabc\r"));
    var keys: [8]Key = undefined;
    for (&keys) |*slot| {
        const read = readKey(fds[0], &parser);
        if (read != .key) return error.TestUnexpectedResult;
        slot.* = read.key;
    }
    try testing.expectEqualSlices(Key, &.{ .down, .down, .down, .enter, .{ .char = 'a' }, .{ .char = 'b' }, .{ .char = 'c' }, .enter }, &keys);

    var editor = KeyParser{};
    try testing.expect(pfs.writeAll(fds[1], "a\rb\r"));
    var buf: [4]Key = undefined;
    try testing.expectEqualSlices(Key, &.{ .{ .char = 'a' }, .shift_enter, .{ .char = 'b' }, .shift_enter }, try readKeys(fds[0], &editor, 4, &buf));
}

test "feedRead: a multi-line burst written at once gives line breaks, and Enter 60 ms later submits" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    var parser = KeyParser{};
    var buf: [32]Key = undefined;
    var text: [32]u8 = undefined;
    try testing.expect(pfs.writeAll(fds[1], "line one\rline two\r"));
    try testing.expectEqualStrings("line one\nline two\n", typedText(try readKeys(fds[0], &parser, 18, &buf), &text));
    @import("metacodes-internal").platform.sync.sleepMs(60);
    try testing.expect(pfs.writeAll(fds[1], "\r"));
    try testing.expectEqual(Key.enter, (try readKeys(fds[0], &parser, 1, &buf))[0]);
}

test "feedRead: bytes already waiting count as one burst however slowly they are read" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    var parser = KeyParser{};
    var text: [32]u8 = undefined;
    var n: usize = 0;
    try testing.expect(pfs.writeAll(fds[1], "line one\rline two\r"));
    for (0..18) |_| {
        n += typedText(&.{try readEditorKey(fds[0], &parser)}, text[n..]).len;
        @import("metacodes-internal").platform.sync.sleepMs(15);
    }
    try testing.expectEqualStrings("line one\nline two\n", text[0..n]);
}

test "feedRead: one line and its Enter written at once is sent, and a CR LF is one Enter" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    var parser = KeyParser{};
    var buf: [8]Key = undefined;
    var text: [16]u8 = undefined;
    try testing.expect(pfs.writeAll(fds[1], "hello\r"));
    try testing.expectEqualStrings("hello\r", typedText(try readKeys(fds[0], &parser, 6, &buf), &text));
    try testing.expect(pfs.writeAll(fds[1], "again\r\n"));
    try testing.expectEqualStrings("again\r", typedText(try readKeys(fds[0], &parser, 6, &buf), &text));
    @import("metacodes-internal").platform.sync.sleepMs(60);
    try testing.expect(pfs.writeAll(fds[1], "\r"));
    try testing.expectEqual(Key.enter, try readEditorKey(fds[0], &parser));
    try testing.expectEqual(@as(i32, 0), platform_term.waitReadable(fds[0], 0));
}

test "feedRead: an IME commit, then Enter 150 ms later, submits" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    var parser = KeyParser{};
    var buf: [32]Key = undefined;
    var text: [32]u8 = undefined;
    try testing.expect(pfs.writeAll(fds[1], "你好世界"));
    try testing.expectEqualStrings("你好世界", typedText(try readKeys(fds[0], &parser, 12, &buf), &text));
    @import("metacodes-internal").platform.sync.sleepMs(150);
    try testing.expect(pfs.writeAll(fds[1], "\r"));
    try testing.expectEqual(Key.enter, (try readKeys(fds[0], &parser, 1, &buf))[0]);
}

test "feedRead: after a bracketed paste read the way the prompt reads it, the next Enter submits" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    var parser = KeyParser{};
    var buf: [4]Key = undefined;
    try testing.expect(pfs.writeAll(fds[1], "\x1b[200~p1\rp2\rp3\x1b[201~"));
    try testing.expectEqual(Key.paste_begin, (try readKeys(fds[0], &parser, 1, &buf))[0]);
    var pasted: [16]u8 = undefined;
    var n: usize = 0;
    while (true) {
        var b: [1]u8 = undefined;
        try testing.expectEqual(@as(isize, 1), platform_term.readInput(fds[0], &b));
        const key = parser.feed(b[0]) orelse continue;
        if (key == .paste_end) break;
        pasted[n] = pastedByte(key).?;
        n += 1;
    }
    try testing.expectEqualStrings("p1\np2\np3", pasted[0..n]);
    @import("metacodes-internal").platform.sync.sleepMs(30);
    try testing.expect(pfs.writeAll(fds[1], "\r"));
    try testing.expectEqual(Key.enter, (try readKeys(fds[0], &parser, 1, &buf))[0]);
}

fn readUntilQuiet(fd: c_int, parser: *KeyParser, out: []Key) []Key {
    var n: usize = 0;
    while (n < out.len) {
        if (parser.drain()) |key| {
            out[n] = key;
            n += 1;
            continue;
        }
        if (platform_term.waitReadable(fd, 50) <= 0) break;
        var b: [1]u8 = undefined;
        if (platform_term.readInput(fd, &b) != 1) break; // no EINTR: waitReadable reported data
        if (parser.feedEditorRead(fd, b[0])) |key| {
            out[n] = key;
            n += 1;
        }
    }
    return out[0..n];
}

test "feedRead: a paste mixing CR, LF and CR LF reads at the prompt as the timed model parses it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const pastes = [_]struct { bytes: []const u8, text: []const u8 }{
        .{ .bytes = "one\rX\nthree", .text = "one\nX\nthree" },
        .{ .bytes = "a\rb\nc\r\nd\re", .text = "a\nb\nc\nd\ne" },
        .{ .bytes = "x\r\r\ny\rz\n", .text = "x\n\ny\nz\n" },
    };
    for (pastes) |paste| {
        errdefer std.debug.print("paste {f}\n", .{std.ascii.hexEscape(paste.bytes, .upper)});
        var model_buf: [32]Key = undefined;
        const model = parseTimed(&.{.{ .bytes = paste.bytes, .after_ms = 1000 }}, &model_buf);
        var text: [32]u8 = undefined;
        try testing.expectEqualStrings(paste.text, typedText(model, &text));
        var parser = KeyParser{};
        try testing.expect(pfs.writeAll(fds[1], paste.bytes));
        var buf: [32]Key = undefined;
        try testing.expectEqualSlices(Key, model, readUntilQuiet(fds[0], &parser, &buf));
    }
}

/// `stream` read the way platform/terminal.zig reads a console that sends
/// win32-input-mode key records, then parsed like parseAll.
fn parseRecords(stream: []const u8, out: []Key) []Key {
    var d: win32_input.Decoder = .{};
    var bytes: [256]u8 = undefined;
    var n: usize = 0;
    for (stream) |b| {
        n += d.take(bytes[n..]);
        d.put(b);
    }
    n += d.take(bytes[n..]);
    d.endOfInput();
    n += d.take(bytes[n..]);
    return parseAll(bytes[0..n], out);
}

test "KeyParser: a Shift+Enter key record is the key Kitty's CSI-u gives, an Enter record Enter" {
    var buf: [8]Key = undefined;
    // Shift down, Enter down with SHIFT_PRESSED, Enter up, Shift up (measured).
    const shift_enter = parseRecords("\x1b[16;42;0;1;48;1_\x1b[13;28;13;1;48;1_\x1b[13;28;13;0;48;1_\x1b[16;42;0;0;32;1_", &buf);
    try testing.expectEqual(@as(usize, 1), shift_enter.len);
    try testing.expect(shift_enter[0] == .shift_enter);
    const enter = parseRecords("\x1b[13;28;13;1;32;1_\x1b[13;28;13;0;32;1_", &buf);
    try testing.expectEqual(@as(usize, 1), enter.len);
    try testing.expect(enter[0] == .enter);
}

test "KeyParser: Esc as key records waits for the read timeout like a VT Esc" {
    var p = KeyParser{};
    var bytes: [8]u8 = undefined;
    var d: win32_input.Decoder = .{};
    var n: usize = 0;
    for ("\x1b[27;1;27;1;32;1_\x1b[27;1;27;0;32;1_") |b| {
        n += d.take(bytes[n..]);
        d.put(b);
    }
    n += d.take(bytes[n..]);
    // The key-up adds nothing: one ESC, and the parser waits for what may follow.
    try testing.expectEqualStrings("\x1b", bytes[0..n]);
    try testing.expect(p.feed(bytes[0]) == null);
    try testing.expect(p.pendingEsc());
    try testing.expect(p.flushEsc().? == .esc);
    // Esc, then an arrow a moment later: two keys, as with VT bytes.
    var keys: [8]Key = undefined;
    const esc_left = parseRecords("\x1b[27;1;27;1;32;1_\x1b[37;75;0;1;288;1_", &keys);
    try testing.expectEqual(@as(usize, 2), esc_left.len);
    try testing.expect(esc_left[0] == .esc);
    try testing.expect(esc_left[1] == .left);
}

test "newlineHint: Shift+Enter once a key record typed text, not for a VT-only terminal's records" {
    // Kitty on (the test's own terminal) says Shift+Enter either way.
    if (shouldEnableKittyKeyboard()) return error.SkipZigTest;
    defer platform_term.resetConsoleInputForTesting();
    platform_term.resetConsoleInputForTesting();
    try testing.expectEqualStrings("\\ + \xe2\x8f\x8e for newline", newlineHint());
    // What ConPTY makes of the CR, ESC and Ctrl+A a VT-only terminal (Alacritty)
    // writes: records, with Ctrl state, but no text. Shift+Enter there is Enter.
    platform_term.decodeConsoleInputForTesting("\x1b[13;28;13;1;0;1_\x1b[13;28;13;0;0;1_\x1b[27;1;27;1;0;1_\x1b[17;29;0;1;8;1_\x1b[65;30;1;1;8;1_");
    try testing.expectEqualStrings("\\ + \xe2\x8f\x8e for newline", newlineHint());
    // A typed letter as a record: Windows Terminal or conhost.
    platform_term.decodeConsoleInputForTesting("\x1b[65;30;97;1;32;1_\x1b[65;30;97;0;32;1_");
    try testing.expectEqualStrings("shift + \xe2\x8f\x8e for newline", newlineHint());
}

test "KeyParser: 迟到的背景色应答(OSC 11,BEL 或 ST 结尾)整条吃掉,前后的字照常" {
    var buf: [16]Key = undefined;
    const keys = parseAll("a\x1b]11;rgb:1e1e/1e1e/2e2e\x1b\\b\x1b]11;rgb:ffff/ffff/ffff\x07c", &buf);
    try testing.expectEqual(@as(usize, 5), keys.len);
    try testing.expectEqual(@as(u8, 'a'), keys[0].char);
    try testing.expect(keys[1] == .unknown);
    try testing.expectEqual(@as(u8, 'b'), keys[2].char);
    try testing.expect(keys[3] == .unknown);
    try testing.expectEqual(@as(u8, 'c'), keys[4].char);
}

test "KeyParser: Alt+] 后面不是 OSC 应答 → 还是 Esc、']' 和后面那几个键" {
    var buf: [16]Key = undefined;
    // Alt+] 后敲字母。
    var keys = parseAll("\x1b]x", &buf);
    try testing.expectEqual(@as(usize, 3), keys.len);
    try testing.expect(keys[0] == .esc);
    try testing.expectEqual(@as(u8, ']'), keys[1].char);
    try testing.expectEqual(@as(u8, 'x'), keys[2].char);
    // Alt+] 后敲数字再敲别的(数字原样还回来)。
    keys = parseAll("\x1b]12x", &buf);
    try testing.expectEqual(@as(usize, 5), keys.len);
    try testing.expect(keys[0] == .esc);
    try testing.expectEqualStrings("]12x", &[_]u8{ keys[1].char, keys[2].char, keys[3].char, keys[4].char });
    // Alt+] 后什么都不敲:等到 ESC 超时(flushEsc)兑现。
    var p = KeyParser{};
    for ("\x1b]") |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.pendingEsc());
    try testing.expect(p.flushEsc().? == .esc);
    try testing.expectEqual(@as(u8, ']'), p.drain().?.char);
    try testing.expect(p.drain() == null);
    // Alt+] 后 Alt+]:第二个 ESC 开新序列。
    keys = parseAll("\x1b]\x1b]", &buf);
    try testing.expectEqual(@as(usize, 4), keys.len);
    try testing.expect(keys[0] == .esc and keys[2] == .esc);
    try testing.expect(keys[1].char == ']' and keys[3].char == ']');
}

test "KeyParser: OSC 被控制键或别的序列截断 → 那个键照常" {
    var buf: [8]Key = undefined;
    var keys = parseAll("\x1b]11;rgb\r", &buf);
    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expect(keys[0] == .enter);
    keys = parseAll("\x1b]11;rgb\x1b[A", &buf);
    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expect(keys[0] == .up);
}

test "KeyParser: 读到一半的序列等不来后半截 → 超时兑现时丢掉,不吞下一个键" {
    // 探测到期时停在应答中间、或一个键被读切开,后半截被下一次进 raw 的 TCSAFLUSH 丢了:
    // 以前 parser 一直等终结字节,把用户接着敲的第一个字母当终结字节吃掉(`ls` → `s`)。
    const cut = [_][]const u8{ "\x1b[?62;", "\x1b]11;rgb:1e1e/", "\x1b[", "\x1b[1;5", "\x1b[12" };
    for (cut) |prefix| {
        var p = KeyParser{};
        for (prefix) |b| try testing.expect(p.feed(b) == null);
        try testing.expect(p.pendingEsc());
        try testing.expect(p.flushEsc() == null); // 序列作废,没有键
        try testing.expect(!p.pendingEsc());
        try testing.expectEqual(@as(u8, 'l'), p.feed('l').?.char);
        try testing.expectEqual(@as(u8, 's'), p.feed('s').?.char);
    }
    // OSC 里的 ESC 之后等不来 `\`:那个 ESC 是用户按的 Esc。
    var p = KeyParser{};
    for ("\x1b]11;x\x1b") |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.pendingEsc());
    try testing.expect(p.flushEsc().? == .esc);
    try testing.expectEqual(@as(u8, 'a'), p.feed('a').?.char);
}

fn startupText(input_bytes: []const u8) StartupText {
    var t = StartupText.init(testing.allocator);
    t.feed(input_bytes);
    t.finish();
    return t;
}

fn expectStartupText(want: []const u8, input_bytes: []const u8) !void {
    var t = startupText(input_bytes);
    defer t.deinit();
    try testing.expectEqualStrings(want, t.text());
}

test "StartupText: 启动期粘贴的换行是文本,退格删前一个字,其它键不进正文" {
    // 没有括号粘贴的多行粘贴:换行是 CR(终端的 Enter)或 LF。
    try expectStartupText("line1\nline2\nline3", "line1\rline2\nline3");
    // 打错了退格改:按 UTF-8 字符删。
    try expectStartupText("fix the bug", "fix teh\x7f\x7fhe bug");
    try expectStartupText("a", "a你\x08");
    try expectStartupText("", "\x7f\x7f");
    // 方向键、Esc、Ctrl 组合、Alt+]、截断的序列都不进正文(正文里不会有 ESC)。
    var t = startupText("a\x1b[Db\x1b\x03c\x1b]x\td\x1b[1;5");
    defer t.deinit();
    try testing.expectEqualStrings("abc]x\td", t.text());
    try testing.expect(std.mem.indexOfScalar(u8, t.text(), 0x1b) == null);
}

test "StartupText: 首尾的换行不进输入框,只有空白时整段不要" {
    // 结尾的 Enter 不提交,留着只会在框里多一个空行(三行就成了四行,折成占位符)。
    try expectStartupText("fix tests", "fix tests\r");
    try expectStartupText("line1\nline2\nline3", "line1\rline2\rline3\r");
    // 按 Enter 跳过启动动画,别的什么都没敲。
    try expectStartupText("", "\r");
    try expectStartupText("", "\r \t\r\r");
    try expectStartupText("line1", "\r\rline1");
    // 行首的缩进是正文。
    try expectStartupText("  code\n  more", "\r  code\r  more\r");
}

test "StartupText: 不设上限;内存不够时其余的丢掉,不留作按键" {
    var big: [10000]u8 = undefined;
    var want: [10000]u8 = undefined;
    for (&big, &want, 0..) |*c, *w, i| {
        c.* = if (i % 50 == 49) '\r' else 'x';
        w.* = if (c.* == '\r') '\n' else c.*;
    }
    var t = startupText(&big);
    defer t.deinit();
    try testing.expect(!t.dropped);
    try testing.expectEqualStrings(want[0 .. want.len - 1], t.text());

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2, .resize_fail_index = 2 });
    var s = StartupText.init(failing.allocator());
    defer s.deinit();
    s.feed(&big);
    s.finish();
    try testing.expect(s.dropped);
    // What it kept is the beginning, whole: nothing after the first loss.
    try testing.expect(s.buf.items.len < want.len);
    try testing.expect(std.mem.startsWith(u8, &want, s.buf.items));
}

/// Read what stdin's replay owes `fd`, then what the pipe holds.
fn drainStdinForTest(fd: c_int, out: []u8) []u8 {
    var n: usize = 0;
    while (n < out.len and platform_term.waitReadable(fd, 0) > 0) {
        const k = platform_term.readInput(fd, out[n..]); // no EINTR: the replay buffer, or a test pipe poll reported readable
        if (k <= 0) break;
        n += @intCast(k);
    }
    return out[0..n];
}

test "collectStartupInput: what the probe handed back, then all the terminal holds, in order, for the first prompt" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // pipe as the terminal
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const r = fds[0];
    var got: [64]u8 = undefined;
    defer _ = drainStdinForTest(r, &got);
    // A probe round that timed out handed back a flood typed during startup:
    // stdin's replay owes all it can but one byte. A Left arrow, a key and
    // 5000 bytes of lines (more than a replay holds) are still with the
    // terminal.
    var flood: [platform_term.replay_capacity - 1]u8 = undefined;
    @memset(&flood, 'p');
    try testing.expectEqual(flood.len, platform_term.replayInput(r, &flood));
    var lines: [5000]u8 = undefined;
    for (&lines, 0..) |*c, i| c.* = if (i % 50 == 49) '\r' else 'x';
    try testing.expect(pfs.writeAll(fds[1], "\x1b[Dd"));
    try testing.expect(pfs.writeAll(fds[1], &lines));

    collectStartupInput(r, startupSettleMs(null));
    var t = takeStartupText() orelse return error.TestUnexpectedResult;
    defer t.deinit();
    try testing.expect(takeStartupText() == null);
    // Nothing is left to be read as keys: no line of it can submit.
    try testing.expectEqual(@as(usize, 0), drainStdinForTest(r, &got).len);
    // All of it, in order: the flood, `d` (the arrow types nothing), the
    // lines without the last Enter.
    const text = t.text();
    try testing.expectEqual(flood.len + 1 + lines.len - 1, text.len);
    try testing.expectEqualStrings("pdx", text[flood.len - 1 ..][0..3]);
    try testing.expectEqual(@as(usize, 99), std.mem.count(u8, text, "\n"));
}

test "collectStartupInput: it waits two round trips of the terminal for the rest of a paste, between 50 and 500 ms" {
    try testing.expectEqual(@as(i32, 50), startupSettleMs(null)); // not probed (Windows)
    try testing.expectEqual(@as(i32, 50), startupSettleMs(1));
    try testing.expectEqual(@as(i32, 240), startupSettleMs(120));
    try testing.expectEqual(@as(i32, 500), startupSettleMs(5000));
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // pipe as the terminal
    // A paste whose second half comes `gap_ms` after the first, as a slow
    // link delivers it a round trip apart. Each case leaves 400 ms or more
    // between the gap and the wait, so a thread a loaded runner wakes late
    // (100 ms and more seen on macOS) does not change the outcome.
    const cases = [_]struct { round_trip_ms: ?i64, gap_ms: u64, whole: bool }{
        // 250 ms round trip (500 ms wait), 100 ms apart: one paste.
        .{ .round_trip_ms = 250, .gap_ms = 100, .whole = true },
        // Waiting only 50 ms, the second half 500 ms later arrives as keys.
        .{ .round_trip_ms = null, .gap_ms = 500, .whole = false },
    };
    for (cases) |case| {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
        defer _ = std.c.close(fds[0]);
        defer _ = std.c.close(fds[1]);
        var rest: [32]u8 = undefined;
        defer _ = drainStdinForTest(fds[0], &rest);
        try testing.expect(pfs.writeAll(fds[1], "line1\rline2\r"));
        const Later = struct {
            fn send(fd: c_int, gap_ms: u64) void {
                @import("metacodes-internal").util.time.sleepMs(gap_ms);
                _ = pfs.writeAll(fd, "line3\rline4");
            }
        };
        const sender = try std.Thread.spawn(.{}, Later.send, .{ fds[1], case.gap_ms });
        collectStartupInput(fds[0], startupSettleMs(case.round_trip_ms));
        sender.join();
        var got = takeStartupText() orelse return error.TestUnexpectedResult;
        defer got.deinit();
        if (case.whole) {
            try testing.expectEqualStrings("line1\nline2\nline3\nline4", got.text());
        } else {
            try testing.expectEqualStrings("line1\nline2", got.text());
            try testing.expectEqualStrings("line3\rline4", drainStdinForTest(fds[0], &rest));
        }
    }
}

test "collectStartupInput: nothing typed, or only Enter to skip the startup animation, leaves the prompt empty" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // pipe as the terminal
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    collectStartupInput(fds[0], startupSettleMs(null));
    try testing.expect(takeStartupText() == null);
    try testing.expect(pfs.writeAll(fds[1], "\r"));
    collectStartupInput(fds[0], startupSettleMs(null));
    try testing.expect(takeStartupText() == null);
    try testing.expectEqual(@as(i32, 0), platform_term.waitReadable(fds[0], 0));
}

test "KeyParser: 超长的数字参数饱和而不溢出,整条仍是一个认不出的键" {
    // `ESC [` 后十位以上数字:u32 累加在 Safe 构建里溢出 panic。
    var buf: [8]Key = undefined;
    const keys = parseAll("\x1b[99999999999999999999~\x1b[1;99999999999999999999u\x1b[4294967296ua", &buf);
    try testing.expectEqual(@as(usize, 4), keys.len);
    for (keys[0..3]) |k| try testing.expect(k == .unknown);
    try testing.expectEqual(@as(u8, 'a'), keys[3].char);
}

test "KeyParser: rxvt 用 `$` 结尾的 Shift 组合键仍是一个键,不吞下一个键" {
    // urxvt/Eterm/aterm:Shift+Delete ESC[3$、Shift+Home/End ESC[7$/ESC[8$、Shift+F11/F12 ESC[23$/ESC[24$。
    for ([_][]const u8{ "\x1b[3$", "\x1b[7$", "\x1b[8$", "\x1b[23$", "\x1b[24$" }) |seq| {
        var buf: [8]Key = undefined;
        var stream: [16]u8 = undefined;
        @memcpy(stream[0..seq.len], seq);
        @memcpy(stream[seq.len..][0..3], " ab");
        const keys = parseAll(stream[0 .. seq.len + 3], &buf);
        try testing.expectEqual(@as(usize, 4), keys.len);
        try testing.expect(keys[0] == .unknown);
        try testing.expectEqualStrings(" ab", &[_]u8{ keys[1].char, keys[2].char, keys[3].char });
    }
}

test "KeyParser: Kitty 下的 Alt+B / Alt+F(CSI 98;3u / 102;3u)仍是词跳转" {
    var buf: [4]Key = undefined;
    var keys = parseAll("\x1b[98;3u\x1b[102;3u", &buf);
    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expect(keys[0] == .alt_b and keys[1] == .alt_f);
    // 其它 Alt 组合认不出,整条一个 .unknown,不漏字符。
    keys = parseAll("\x1b[120;3u", &buf);
    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expect(keys[0] == .unknown);
}

test "KeyParser: 被控制键或 ESC 截断的认不出 CSI 不吞那个键" {
    var p = KeyParser{};
    for ("\x1b[?6") |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.feed(0x03).? == .ctrl_c);
    for ("\x1b[?6") |b| try testing.expect(p.feed(b) == null);
    try testing.expect(p.feed(0x1b).? == .unknown);
    try testing.expect(p.pendingEsc());
    try testing.expect(p.feed('[') == null);
    try testing.expect(p.feed('A').? == .up);
}

test "newlineHint:返两种文案之一(随当前 env)" {
    // newlineHint 读真实 env;只断言它返回两种已知文案之一(避免依赖 CI env 具体值)。
    const h = newlineHint();
    const shift = "shift + \xe2\x8f\x8e for newline";
    const backslash = "\\ + \xe2\x8f\x8e for newline";
    try testing.expect(std.mem.eql(u8, h, shift) or std.mem.eql(u8, h, backslash));
    // 含义自洽:能发 Kitty ⇔ 显示 shift 方式。
    if (shouldEnableKittyKeyboard()) {
        try testing.expectEqualStrings(shift, h);
    } else {
        try testing.expectEqualStrings(backslash, h);
    }
}

test "LineEditor: backslash+return 行尾续行(Apple Terminal 换行)" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("abc\\") |c| _ = try ed.handle(Key{ .char = c }); // 打 "abc\"
    const action = try ed.handle(.enter);
    try testing.expect(action == .redraw); // 不提交
    try testing.expectEqualStrings("abc\n", ed.view()); // 删 \ 插 \n
    try testing.expectEqual(@as(usize, 4), ed.cursor);
    // 续行后继续打字
    _ = try ed.handle(Key{ .char = 'd' });
    try testing.expectEqualStrings("abc\nd", ed.view());
}

test "LineEditor: 无尾 backslash 的 enter 仍提交" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("abc") |c| _ = try ed.handle(Key{ .char = c });
    try testing.expect((try ed.handle(.enter)) == .commit);
}

test "LineEditor: 行中 backslash 不触发续行" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try ed.setLine("a\\b"); // "a\b",cursor 在末尾
    ed.cursor = 2; // 光标在 '\' 后、'b' 前(行中,非行尾)
    try testing.expect((try ed.handle(.enter)) == .commit); // 不续行
}

test "LineEditor: backslash 续行可 undo" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    for ("ab\\") |c| _ = try ed.handle(Key{ .char = c });
    _ = try ed.handle(.enter); // 续行 → "ab\n"
    try testing.expectEqualStrings("ab\n", ed.view());
    _ = try ed.handle(.ctrl_underscore); // undo
    try testing.expectEqualStrings("ab\\", ed.view());
}

test "KeyParser: ctrl_underscore byte 0x1f" {
    var p = KeyParser{};
    try testing.expect(p.feed(0x1f).? == .ctrl_underscore);
}

test "LineEditor: undo 折叠 char 连打为一个单元" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "abc"); // 连续 char → 段首压一次快照(空串)
    try testing.expectEqualStrings("abc", ed.view());
    try testing.expect((try ed.handle(.ctrl_underscore)) == .redraw);
    try testing.expectEqualStrings("", ed.view()); // 整段回退到空
    try testing.expectEqual(@as(usize, 0), ed.cursor);
}

test "LineEditor: undo 跨操作类型逐个回退" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "ab"); // 快照1:""(char 段首)
    _ = try ed.handle(.backspace); // 快照2:"ab" → 现 "a"
    try testing.expectEqualStrings("a", ed.view());
    try testing.expect((try ed.handle(.ctrl_underscore)) == .redraw);
    try testing.expectEqualStrings("ab", ed.view()); // undo backspace
    try testing.expect((try ed.handle(.ctrl_underscore)) == .redraw);
    try testing.expectEqualStrings("", ed.view()); // undo char 段
}

test "LineEditor: undo 空栈返回 none" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try testing.expect((try ed.handle(.ctrl_underscore)) == .none);
}

test "LineEditor: undo 栈深上限不下溢不泄漏" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    // 交替 char/backspace 制造 >50 个破坏性操作(每个都压快照)。
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        _ = try ed.handle(.{ .char = 'x' });
        _ = try ed.handle(.backspace);
    }
    // undo 到底:不下溢、不泄漏(testing.allocator 会抓泄漏)。
    var n: usize = 0;
    while (n < 130) : (n += 1) {
        if ((try ed.handle(.ctrl_underscore)) == .none) break;
    }
    try testing.expect((try ed.handle(.ctrl_underscore)) == .none); // 已见底
}

test "LineEditor: reset 清 undo 历史" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "hello");
    ed.reset();
    try testing.expect((try ed.handle(.ctrl_underscore)) == .none); // 历史已清
}
