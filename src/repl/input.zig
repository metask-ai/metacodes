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
    page_up, // ESC[5~（agent viewing 视口翻页）
    page_down, // ESC[6~
    esc,
    tab,
    shift_tab, // cycle 权限模式
    ctrl_r,
    ctrl_t, // 切换任务列表显示
    ctrl_o, // 打开 transcript viewer
    ctrl_x, // Ctrl+X 前缀(配合 Ctrl+K kill 后台)
    ctrl_g, // 外部编辑器编辑当前 buffer
    ctrl_underscore, // Ctrl+_ / Ctrl+Shift+- (0x1f): undo
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
    // 一字节 feed 偶尔需吐两个键(ESC 后紧跟普通字符 = 孤立 ESC + 该字符):
    // feed 返回第一个(.esc),把第二个键暂存这里,调用方 feed 后须 while(drain())|k| 排空。
    pending: ?Key = null,

    const State = enum { normal, esc_seen, csi_seen, csi_num1, csi_semi, csi_num2 };

    /// 是否正卡在"已收 ESC、等后续字节判断是否 CSI 序列"的状态。
    /// 调用方(watcher)在 read 超时时若此为 true,应调 flushEsc() 把孤立 ESC 兑现为 .esc。
    pub fn pendingEsc(self: *const KeyParser) bool {
        return self.state == .esc_seen;
    }

    /// 取出 feed 暂存的第二个键(若有)。调用方每次 feed 后循环 drain 至 null。
    /// 用于 ESC + 普通字符这类一次 feed 产出两键的场景(否则后一个字符被吞)。
    pub fn drain(self: *KeyParser) ?Key {
        const k = self.pending orelse return null;
        self.pending = null;
        return k;
    }

    /// 把卡在 esc_seen 的孤立 ESC 兑现为 .esc(超时无后续字节时调)。非 esc_seen 返 null。
    pub fn flushEsc(self: *KeyParser) ?Key {
        if (self.state != .esc_seen) return null;
        self.state = .normal;
        return .esc;
    }

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
                // Alt+key:ESC 后紧跟字母(meta)。Alt+B / Alt+F 词导航——是单个组合键,不拆。
                switch (b) {
                    'b', 'B' => return .alt_b,
                    'f', 'F' => return .alt_f,
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
                self.pending = byteToKey(b);
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
                        5 => .page_up,
                        6 => .page_down,
                        200 => .paste_begin,
                        201 => .paste_end,
                        else => .unknown,
                    };
                }
                // 无 modifier 的 CSI-u(ESC[<cp>u,无 ;mod):Kitty disambiguate 模式下
                // Enter/Esc/纯文本也可能编成 CSI-u。还原成对应键,避免被当 .unknown 吞掉。
                if (b == 'u') {
                    return switch (self.num1) {
                        13 => .enter, // 无 mod Enter
                        27 => .esc, // 无 mod Esc
                        // ASCII 可打印 → char(兼容把纯文本也 CSI-u 编码的终端)。
                        0x20...0x7e => Key{ .char = @intCast(self.num1) },
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
        0x14 => .ctrl_t,
        0x0f => .ctrl_o,
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

/// 切 raw 模式，返回旧 termios；非 tty 或失败返 null。
/// 进 raw mode。返回原 termios(供 restoreMode 复原);非 tty 返 null。
/// 仅对**白名单终端**(shouldEnableKittyKeyboard)启用 Kitty 键盘协议 / xterm modifyOtherKeys,
/// 以区分 Shift+Enter / Ctrl+Enter。非白名单(如 Apple Terminal)不发——它们会 honor 协议并
/// 发回 parser 处理不了的 codepoint(对齐真 cc terminal.ts:167:无条件发是 #23350 踩过的坑)。
///
/// **键盘协议序列**(对齐真 cc ink.tsx:418,pop-before-push 防残留栈叠加):
///   `\x1b[<u`   DISABLE_KITTY_KEYBOARD —— 先 pop 清 Kitty 栈
///   `\x1b[>1u`  ENABLE_KITTY flags=1(disambiguate-only):歧义键(Shift/Ctrl+Enter、
///              Esc、功能键)编成 CSI-u,纯文本不编码 → Warp/iTerm/kitty/WezTerm/ghostty 用这条
///   `\x1b[>4;2m` ENABLE_MODIFY_OTHER_KEYS level 2:不支持 Kitty 的 xterm 系走这条
/// 实测:Warp 收到 `\x1b[>1u` 后 Shift+Enter 才发 `\x1b[13;2u`(否则退回裸 \n,被当 Enter)。
/// 非白名单终端 Shift+Enter 发裸 \r/\n,换行改靠 backslash+return(见 LineEditor.handle .enter)。
pub const kbd_enable_seq = "\x1b[<u" ++ "\x1b[>1u" ++ "\x1b[>4;2m";
pub const kbd_disable_seq = "\x1b[<u" ++ "\x1b[>4m"; // DISABLE_KITTY(pop) + DISABLE_MODIFY_OTHER_KEYS

/// Kitty 键盘协议**白名单**(对齐真 cc terminal.ts:167 EXTENDED_KEYS_TERMINALS + 实测追加 Warp)。
/// 真 cc 注释铁证:此前无条件发(#23350)是 bug——某些终端(Apple Terminal/SSH/xterm.js)会
/// honor enable 并发回 parser 处理不了的 codepoint(→ 各种键乱/乱码)。故只对已知正确实现
/// Kitty/modifyOtherKeys 的终端发。Apple_Terminal 不在此列 → 不发协议,换行靠 backslash+return。
/// WarpTerminal 为 cc-zig 追加(用户实测:其默认未开 Kitty,需主动发 \x1b[>1u 才能 Shift+Enter 换行)。
const kitty_term_programs = [_][]const u8{ "iTerm.app", "WezTerm", "ghostty", "WarpTerminal" };

/// 纯函数(便于纯单测,不依赖真 env):据 TERM_PROGRAM / TERM / TMUX 判断是否发 Kitty 协议。
fn classifyKittyKeyboard(term_program: ?[]const u8, term: ?[]const u8, has_tmux: bool) bool {
    if (has_tmux) return true; // tmux 接受 modifyOtherKeys 且不转发 Kitty 给外层(对齐真 cc)
    if (term_program) |tp| {
        for (kitty_term_programs) |n| if (std.mem.eql(u8, tp, n)) return true;
    }
    if (term) |t| {
        if (std.mem.indexOf(u8, t, "kitty") != null) return true; // xterm-kitty 等
        if (std.mem.eql(u8, t, "xterm-ghostty")) return true;
    }
    return false;
}

/// 读真实 env 调 classifyKittyKeyboard。getenv 返 ?[*:0]const u8 → span 成 ?[]const u8。
pub fn shouldEnableKittyKeyboard() bool {
    const tp: ?[]const u8 = if (std.c.getenv("TERM_PROGRAM")) |p| std.mem.span(p) else null;
    const term: ?[]const u8 = if (std.c.getenv("TERM")) |t| std.mem.span(t) else null;
    const has_tmux: bool = if (std.c.getenv("TMUX")) |v| std.mem.span(v).len > 0 else false;
    return classifyKittyKeyboard(tp, term, has_tmux);
}

/// 当前终端的换行方式提示(对齐真 cc getNewlineInstructions,但按 cc-zig 实际能力):
/// - 白名单终端(发 Kitty 协议 → Shift+Enter 真换行)→ "shift + ⏎ for newline"
/// - 非白名单(Apple Terminal 等,Shift+Enter 发裸 \r=Enter 会提交)→ "\ + ⏎ for newline"
///   (cc-zig 无 macOS 原生 modifier 检测,故 Apple Terminal 只能靠 backslash 续行,
///    不能照抄真 cc 对 Apple 的 "shift+⏎" 文案——那会误导)。
pub fn newlineHint() []const u8 {
    return if (shouldEnableKittyKeyboard()) "shift + \xe2\x8f\x8e for newline" else "\\ + \xe2\x8f\x8e for newline";
}

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

    // 哑终端(TERM=dumb 或空)不发任何键盘协议/粘贴序列,避免乱码回显。
    const term = std.c.getenv("TERM");
    const dumb = term == null or std.mem.eql(u8, std.mem.span(term.?), "dumb") or std.mem.span(term.?).len == 0;
    if (!dumb) {
        // Kitty 键盘协议 + modifyOtherKeys 仅对白名单终端发(非白名单会乱码/键失常)。
        if (shouldEnableKittyKeyboard()) {
            _ = std.c.write(fd, kbd_enable_seq.ptr, kbd_enable_seq.len);
        }
        // bracketed paste 兼容性好,所有非 dumb 终端都发(粘贴内容被 ESC[200~ ... ESC[201~ 包裹)。
        const enable_paste = "\x1b[?2004h";
        _ = std.c.write(fd, enable_paste.ptr, enable_paste.len);
    }

    return orig;
}

pub fn restoreMode(fd: std.c.fd_t, orig: std.c.termios) void {
    // 关 bracketed paste(始终)+ 键盘协议(仅白名单——对称 enterRawMode,同进程 env 不变判定恒一致,
    // 不会发了 enable 没 disable;非白名单不发孤立 disable,避免 Apple Terminal honor 它出异常)。
    const disable_paste = "\x1b[?2004l";
    _ = std.c.write(fd, disable_paste.ptr, disable_paste.len);
    if (shouldEnableKittyKeyboard()) {
        _ = std.c.write(fd, kbd_disable_seq.ptr, kbd_disable_seq.len);
    }
    _ = std.c.tcsetattr(fd, std.posix.TCSA.FLUSH, &orig);
}

/// 把 `current` 写临时文件,开 $VISUAL/$EDITOR(前台阻塞)编辑,读回(owned,去尾换行)。
/// 调用方负责终端模式:本函数 spawn 的编辑器自管 termios,但调用方应在调用前退 raw / 调用后重进。
/// REPL 主循环(loop.zig Ctrl+G)和 AskUserQuestion preview note(ask_question.zig ctrl+g)共用。
pub fn externalEdit(allocator: std.mem.Allocator, current: []const u8) ![]u8 {
    const editor_env = std.c.getenv("VISUAL") orelse std.c.getenv("EDITOR") orelse return error.NoEditor;
    const editor_cmd = std.mem.span(editor_env);

    const tmp_path = "/tmp/cc-zig-edit-buffer.txt";
    {
        const fd = std.c.open(tmp_path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.WriteFailed;
        defer _ = std.c.close(fd);
        if (current.len > 0) _ = std.c.write(fd, current.ptr, current.len);
    }

    const path_z = try allocator.dupeZ(u8, tmp_path);
    defer allocator.free(path_z);
    var argv = [_]?[*:0]const u8{ "/bin/sh", "-c", undefined, null };
    const sh_cmd = try std.fmt.allocPrintSentinel(allocator, "{s} {s}", .{ editor_cmd, tmp_path }, 0);
    defer allocator.free(sh_cmd);
    argv[2] = sh_cmd.ptr;

    const pid = std.c.fork();
    if (pid == 0) {
        _ = std.c.execve("/bin/sh", @ptrCast(&argv), @ptrCast(std.c.environ));
        std.c._exit(127);
    } else if (pid < 0) {
        return error.ForkFailed;
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    const rfd = std.c.open(path_z.ptr, std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (rfd < 0) return error.ReadFailed;
    defer _ = std.c.close(rfd);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(rfd, &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    _ = std.c.unlink(path_z.ptr);
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
    /// 用户取消（Ctrl+C：空 buffer 第一次 → 提示；非空 buffer → 丢弃回 prompt）
    cancel,
    /// 第一次 Ctrl+C 空 buffer 时——调用方应打印"按 Ctrl+C 再次退出"提示
    cancel_hint,
    /// 第二次连续 Ctrl+C（中间无其他按键）→ 退出 REPL
    exit_repl,
    /// 空输入 Ctrl+D → 主动退出 REPL；非空输入 Ctrl+D → 丢弃
    eof,
    /// Esc Esc(空 buffer 二次):清 draft + 保存到历史
    clear_draft,
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
    /// 上一次按键是否是 Ctrl+C（用于"双击退出"语义）。任何其他按键重置为 false。
    ctrl_c_armed: bool = false,
    /// 上一次按键是否是 Esc(用于 Esc Esc 双击清 draft)。
    esc_armed: bool = false,
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
        // "双击 Ctrl+C 退出" 语义：只有连续两次 Ctrl+C（中间无其他按键）才触发 exit_repl。
        // 非 ctrl_c 按键会重置 armed 标志。
        const was_armed = self.ctrl_c_armed;
        if (@as(std.meta.Tag(Key), key) != .ctrl_c) {
            self.ctrl_c_armed = false;
        }
        const was_esc_armed = self.esc_armed;
        if (@as(std.meta.Tag(Key), key) != .esc) {
            self.esc_armed = false;
        }

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
            .esc => {
                // Esc Esc:非空 buffer 二次按 → 清 draft(保存到历史让 Up 可恢复)
                if (was_esc_armed and self.buf.items.len > 0) {
                    self.esc_armed = false;
                    return .clear_draft;
                }
                self.esc_armed = true;
                return .none;
            },
            // 全局快捷键(↑↓/Tab/Shift+Tab/Ctrl+R/T/O/G/X/L)由 dispatch(ui.zig)拦截,
            // editor 正常收不到;此处兜底返 .none(防御:vim/边界路径若漏到这不崩)。
            .up, .down, .tab, .shift_tab, .ctrl_r, .ctrl_t, .ctrl_o, .ctrl_g, .ctrl_x, .ctrl_l => return .none,
            .page_up, .page_down => return .none, // viewing 视口翻页键,editor 不处理(dispatch 拦截)
            .unknown => return .none,
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

test "LineEditor: Esc Esc on non-empty buffer clears draft" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "hello");
    // 第一次 esc:none + arm
    try testing.expect((try ed.handle(.esc)) == .none);
    // 第二次 esc(非空 buffer):clear_draft
    try testing.expect((try ed.handle(.esc)) == .clear_draft);
}

test "LineEditor: single Esc is none (not clear)" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try typeStr(&ed, "x");
    try testing.expect((try ed.handle(.esc)) == .none);
    // 中间插入字符 → 重置 esc_armed
    _ = try ed.handle(Key{ .char = 'y' });
    try testing.expect((try ed.handle(.esc)) == .none); // 又是第一次
}

test "LineEditor: Esc Esc on empty buffer does not clear" {
    var ed = LineEditor.init(testing.allocator);
    defer ed.deinit();
    try testing.expect((try ed.handle(.esc)) == .none);
    try testing.expect((try ed.handle(.esc)) == .none); // 空 buffer → 不触发 clear_draft
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

test "键盘协议序列字节(接线:enter/restore 发的就是这些)" {
    // Kitty disambiguate(>1u)是 Warp/iTerm/kitty 等区分 Shift/Ctrl+Enter 的关键。
    // 实测:Warp 收到 \x1b[>1u 后 Shift+Enter 才发 \x1b[13;2u。
    try testing.expectEqualStrings("\x1b[<u\x1b[>1u\x1b[>4;2m", kbd_enable_seq);
    try testing.expectEqualStrings("\x1b[<u\x1b[>4m", kbd_disable_seq);
}

test "classifyKittyKeyboard:白名单分流矩阵" {
    // Apple Terminal(TERM=xterm-256color)→ 不发(根本不支持 Kitty,无条件发会乱)。
    try testing.expect(!classifyKittyKeyboard("Apple_Terminal", "xterm-256color", false));
    // 白名单 TERM_PROGRAM(含实测追加的 Warp)。
    try testing.expect(classifyKittyKeyboard("WarpTerminal", "xterm-256color", false));
    try testing.expect(classifyKittyKeyboard("iTerm.app", null, false));
    try testing.expect(classifyKittyKeyboard("WezTerm", null, false));
    try testing.expect(classifyKittyKeyboard("ghostty", null, false));
    // TERM 子串命中(TERM_PROGRAM 可能不设)。
    try testing.expect(classifyKittyKeyboard(null, "xterm-kitty", false));
    try testing.expect(classifyKittyKeyboard(null, "xterm-ghostty", false));
    // tmux 透传。
    try testing.expect(classifyKittyKeyboard(null, "screen-256color", true));
    // 默认/未知 → 不发。
    try testing.expect(!classifyKittyKeyboard(null, "xterm-256color", false));
    try testing.expect(!classifyKittyKeyboard(null, null, false));
    try testing.expect(!classifyKittyKeyboard("vscode", "xterm-256color", false));
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
