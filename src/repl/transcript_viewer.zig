//! Transcript viewer:Ctrl+O 打开的对话浏览器。
//!
//! **alt-screen 全屏模式(2026-06-13,根治多 agent"显两份"/footer 堆叠/几何漂移)**:进 `ESC[?1049h`
//! 切独立缓冲(主屏 grid+光标整屏保存)→ 全帧绝对定位画 transcript + 末2行 footer → 退出 `ESC[?1049l`
//! 由终端**自动逐字节恢复主缓冲**(banner+对话+输入框原样回来,零工作、零漂移、零 scrollback 污染)。
//! 空缓冲 + 绝对定位 → 天然无两份、无滚动。早期试过 inline(不进 alt-screen)既要覆盖滚进可视区的对话、
//! 又要退出不滚动,本质矛盾无法兼得(DIFF#6/#7 的"对齐 cc 不进 alt-screen"满足不了长对话),故改 alt-screen。
//!
//! 键(对齐 cc:↑↓ 主滚动 + ctrl+o toggle;保留 vim 键作增强):
//!   ↓ / j / Space   向下滚一行       ↑ / k   向上滚一行
//!   { / }           上/下一条 user prompt
//!   g / G           顶 / 底
//!   q / Esc / Ctrl+O 退出(ctrl+o 对称开关;白名单终端 Ctrl+O=CSI-u ESC[111;5u 也认)
//!
//! 本模块拆两层:
//!   - renderToLines:把 Conversation 渲染成行数组(纯函数,可单测)
//!   - runWithTheme:alt-screen 交互循环(从 loop.zig / tui_backend 调,需要 tty)

const std = @import("std");
const pfs = @import("platform").fs;
const platform_term = @import("platform").terminal; // console 宽读统一入口(review-2 F4)
const Conversation = @import("../core/conversation.zig").Conversation;
const Overlay = @import("tui/overlay.zig").Overlay;

/// 把整个对话渲染成可显示的行(owned;caller free 每行 + 数组)。
/// 每条 message 前加 role 头;tool_use/tool_result 用缩进 + 标记区分。
pub fn renderToLines(allocator: std.mem.Allocator, conv: *const Conversation) ![][]u8 {
    return renderToLinesWithTheme(allocator, conv, @import("tui/theme.zig").dark);
}

pub fn renderToLinesWithTheme(allocator: std.mem.Allocator, conv: *const Conversation, th: @import("tui/theme.zig").Theme) ![][]u8 {
    const tool_card = @import("tui/widget/tool_card.zig");
    // 全程持 snapshot 锁:遍历 conv.messages.items 期间禁止 append(realloc 会抽走 items
    // 底层 buffer → UAF)。生成期 watcher 线程经此读快照,与主线程 agent_loop 的 append 互斥。
    // mutex 是同步原语,@constCast 取可变指针不算逻辑修改 conv。锁持有时间 = 一次渲染(O(msgs)),
    // append 一轮几次故阻塞可忽略。
    const mut_conv = @constCast(conv);
    mut_conv.lockSnapshot();
    defer mut_conv.unlockSnapshot();

    var lines = std.ArrayList([]u8).empty;
    errdefer {
        for (lines.items) |l| allocator.free(l);
        lines.deinit(allocator);
    }

    // 先建 tool_use_id → {name,input} 查表,供 tool_result 用 renderResult 走逐工具渲染器
    // (Edit diff 着色 / 搜索摘要 / Read 摘要)。borrow 自 conversation,无需 free。
    const ToolMeta = struct { name: []const u8, input: []const u8 };
    var tool_meta = std.StringHashMap(ToolMeta).init(allocator);
    defer tool_meta.deinit();
    for (conv.messages.items) |m| {
        for (m.blocks) |b| {
            if (b == .tool_use) try tool_meta.put(b.tool_use.id, .{ .name = b.tool_use.name, .input = b.tool_use.input });
        }
    }

    for (conv.messages.items) |m| {
        // cc 风格 transcript:**不画 ▶ user/◀ assistant 角色头**(对齐 napicc v2.1.170 实拍:viewer
        // 内容与主区同款渲染,assistant=⏺+markdown / user=❯+原文,无角色标签)。这保证 Ctrl+O 进出
        // 渲染等效——退出重绘的行 == 主区已渲染的行,markdown 不会"变源码"、无 ▶/◀ 残留。
        for (m.blocks) |b| {
            switch (b) {
                .text => |t| switch (m.role) {
                    // assistant 文本:逐行过 markdown(渲染等效主区 emitAssistantLine),段首 ⏺ 续行 2 空格。
                    .assistant => try appendAssistantMarkdown(allocator, &lines, t, th),
                    // user 文本:❯ 前缀 + 原文(不渲 markdown,对齐主区 user 回显)。
                    .user => try appendUserText(allocator, &lines, t, th),
                },
                .tool_use => |tu| {
                    // tool_card.renderStart 输出多行字符串(2 行带 ANSI);split 进 lines。
                    const card = try tool_card.renderStart(allocator, th, tu.name, tu.input);
                    defer allocator.free(card);
                    var pos: usize = 0;
                    while (pos < card.len) {
                        const eol = std.mem.indexOfScalarPos(u8, card, pos, '\n') orelse card.len;
                        if (eol > pos) {
                            // 加 2 空格缩进
                            const indented = try std.fmt.allocPrint(allocator, "  {s}", .{card[pos..eol]});
                            try lines.append(allocator, indented);
                        }
                        pos = eol + 1;
                    }
                },
                .tool_result => |tr| {
                    // 用 renderResult 走逐工具渲染器(Edit diff 着色 / 搜索摘要 / Read 摘要);
                    // transcript 视图展开(verbose 语义)。查不到 tool_use 则用空名走通用折叠。
                    const meta = tool_meta.get(tr.tool_use_id);
                    const t_name: []const u8 = if (meta) |mm| mm.name else "";
                    const t_input: []const u8 = if (meta) |mm| mm.input else "{}";
                    const kind: tool_card.ResultKind = if (tr.is_error) .err else .ok;
                    const card = try tool_card.renderResult(allocator, th, t_name, t_input, tr.content, kind, 0, .{ .transcript = true });
                    defer allocator.free(card);
                    var pos: usize = 0;
                    while (pos < card.len) {
                        const eol = std.mem.indexOfScalarPos(u8, card, pos, '\n') orelse card.len;
                        if (eol > pos) {
                            const indented = try std.fmt.allocPrint(allocator, "  {s}", .{card[pos..eol]});
                            try lines.append(allocator, indented);
                        }
                        pos = eol + 1;
                    }
                },
                .thinking => |t| {
                    // 思考块:头标 + 折叠内容(前 3 行)
                    const head = try std.fmt.allocPrint(allocator, "  {s}{s} thinking{s}", .{ th.role_thinking, th.icon_thinking, th.reset });
                    try lines.append(allocator, head);
                    try appendWrappedFolded(allocator, &lines, t, "    ", th.dim, th.reset, 3);
                },
                .image => |img| {
                    // 终端不内联渲图:显示元信息行(类型 + base64 字节数)。
                    const head = try std.fmt.allocPrint(allocator, "  {s}❯ [image {s}, {d} bytes base64]{s}", .{ th.dim, img.media_type, img.data.len, th.reset });
                    try lines.append(allocator, head);
                },
            }
        }
        try lines.append(allocator, try allocator.dupe(u8, "")); // 空行分隔
    }

    return try lines.toOwnedSlice(allocator);
}

/// assistant 文本:逐行过 markdown(复用主区 render.renderLineStreaming,渲染等效),段首 `⏺ `(accent)
/// 续行 `  `(2 空格,对齐主区 emitAssistantLine 前缀)。一个 text block 用一个 StreamState(代码块跨行)。
/// 不做列宽软折(transcript 终端自己软换行;主区软折是为固定区,viewer 全屏可不折)。
fn appendAssistantMarkdown(allocator: std.mem.Allocator, lines: *std.ArrayList([]u8), text: []const u8, th: @import("tui/theme.zig").Theme) !void {
    const md_render = @import("render.zig");
    var st: md_render.StreamState = .{};
    var first = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |seg| {
        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(allocator);
        md_render.renderLineStreaming(seg, &st, &rendered, allocator, th.syntax) catch {
            rendered.clearRetainingCapacity();
            rendered.appendSlice(allocator, seg) catch {};
        };
        // 段首 `⏺ `(accent),续行 `  `。代码块围栏行 renderLineStreaming 输出空 → 仍占一行(对齐主区)。
        const prefix: []const u8 = if (first) "⏺ " else "  ";
        const color: []const u8 = if (first) th.accent else "";
        const line = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}{s}", .{ color, prefix, th.reset, rendered.items, "\x1b[0m" });
        try lines.append(allocator, line);
        first = false;
    }
}

/// user 文本:`❯ ` 前缀(accent)+ 原文(不渲 markdown,对齐主区 user 回显)。续行 2 空格缩进。
fn appendUserText(allocator: std.mem.Allocator, lines: *std.ArrayList([]u8), text: []const u8, th: @import("tui/theme.zig").Theme) !void {
    var first = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |seg| {
        const prefix: []const u8 = if (first) "❯ " else "  ";
        const color: []const u8 = if (first) th.accent else "";
        const line = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}\x1b[0m", .{ color, prefix, th.reset, seg });
        try lines.append(allocator, line);
        first = false;
    }
}

/// 带折叠的 wrapped:超过 max_lines 后,后续行省略,加 "… N more lines"。
fn appendWrappedFolded(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]u8),
    text: []const u8,
    prefix: []const u8,
    color: []const u8,
    reset: []const u8,
    max_lines: u16,
) !void {
    // 先算总行数
    var total: u32 = 0;
    {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |_| total += 1;
    }
    var emitted: u32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |seg| {
        if (emitted >= max_lines) break;
        const line = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ prefix, color, seg, reset });
        try lines.append(allocator, line);
        emitted += 1;
    }
    if (total > max_lines) {
        const more = total - max_lines;
        const line = try std.fmt.allocPrint(allocator, "{s}{s}… {d} more lines{s}", .{ prefix, color, more, reset });
        try lines.append(allocator, line);
    }
}

/// 找所有 user prompt 在 lines 里的行号(用于 { } 跳转)。
/// 找 user prompt 行的行号({/} 跳转用)。user 文本段首前缀 `❯ `(appendUserText)。
/// (旧版认 `▶ user` 角色头,已去;改认 ❯ 前缀。assistant/tool 行不含 ❯,无误匹配。)
pub fn userPromptLineIndices(allocator: std.mem.Allocator, lines: []const []const u8) ![]usize {
    var idx = std.ArrayList(usize).empty;
    errdefer idx.deinit(allocator);
    for (lines, 0..) |l, i| {
        if (std.mem.indexOf(u8, l, "❯ ") != null) try idx.append(allocator, i);
    }
    return try idx.toOwnedSlice(allocator);
}

pub fn freeLines(allocator: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |l| allocator.free(l);
    allocator.free(lines);
}

/// 交互循环。fd = stdin。rows = 终端高度(末 2 行给 footer)。
/// 进 alt-screen(ESC[?1049h)→ 全屏画 → 处理键 → 退出 ESC[?1049l 自动恢复主缓冲(见模块头注)。
pub fn run(fd: c_int, allocator: std.mem.Allocator, conv: *const Conversation, rows: usize) !void {
    return runWithTheme(fd, allocator, conv, rows, @import("tui/theme.zig").dark);
}

/// 全屏 transcript viewer(2026-06-13 改 alt-screen,根治多 agent"显两份")。进 \x1b[?1049h 切独立
/// 缓冲、全屏绝对定位画 transcript + 末2行 footer;退出 \x1b[?1049l 由终端**自动逐字节恢复主缓冲**
/// (banner+对话+输入框原样回来,零漂移、零 scrollback 污染)。空缓冲 + 绝对定位 → 天然无两份。
pub fn runWithTheme(fd: c_int, allocator: std.mem.Allocator, conv: *const Conversation, rows: usize, th: @import("tui/theme.zig").Theme) !void {
    return runWithThemeAnchor(fd, allocator, conv, rows, 1, th);
}

/// anchor_hint:旧 inline 模式的区顶兜底行,alt-screen 不再需要(独立缓冲全屏绝对定位)。保留参数
/// 仅为不动 caller 签名(tui_backend/loop 仍传它)——内部丢弃。
pub fn runWithThemeAnchor(fd: c_int, allocator: std.mem.Allocator, conv: *const Conversation, rows: usize, anchor_hint: usize, th: @import("tui/theme.zig").Theme) !void {
    _ = anchor_hint; // alt-screen 全屏模式不需要区顶 anchor(独立缓冲,绝对定位)
    const lines = try renderToLinesWithTheme(allocator, conv, th);
    defer freeLines(allocator, lines);
    const prompts = try userPromptLineIndices(allocator, lines);
    defer allocator.free(prompts);

    const cols = blk: {
        const sz = @import("tui/term.zig").getSize(fd) orelse break :blk @as(usize, 80);
        break :blk @as(usize, sz.cols);
    };

    // **alt-screen 全屏 transcript**(用户实测:多 agent 长跑时 inline 重画会显两份/footer 堆叠/几何
    // 漂移——根因是 inline 既要覆盖滚进可视区的对话、又要退出不滚动,无法兼得)。改用 alt-screen:进
    // 独立缓冲全屏画 transcript(空缓冲 → 绝对定位天然无两份),退出由终端**自动逐字节恢复主缓冲**
    // (banner+对话+输入框原样回来,零漂移)。只此 Ctrl+O 进全屏,其它一切不变。
    var ov = Overlay{};
    ov.enter(); // \x1b[?1049h + hide cursor + home
    defer ov.exit(); // \x1b[?1049l → 终端自动恢复主缓冲

    // 视口:rows 1..rows-2 全部给内容,末 2 行 footer。alt 缓冲空,全屏绝对定位画无两份、无滚动。
    const footer_rows: usize = 2;
    const view_rows: usize = if (rows > footer_rows) rows - footer_rows else 1;
    var top: usize = 0;
    const max_top = if (lines.len > view_rows) lines.len - view_rows else 0;
    top = max_top; // 对齐 cc:打开时定位到底部(最新)

    // 简单 ESC 序列解析:↑=\x1b[A ↓=\x1b[B。esc 单独=退出。
    while (true) {
        drawScreen(lines, top, view_rows, rows, cols, th);
        var b: [1]u8 = undefined;
        const n = platform_term.readInput(fd, &b);
        if (n <= 0) break;
        const c = b[0];
        if (c == 0x1b) {
            // 可能是方向键 CSI 或单 Esc。读后续两字节判定。
            var s0: [1]u8 = undefined;
            const n2 = platform_term.readInput(fd, &s0);
            if (n2 <= 0) break; // 裸 Esc → 退出
            if (s0[0] == '[') {
                var s1: [1]u8 = undefined;
                const n3 = platform_term.readInput(fd, &s1);
                if (n3 <= 0) break;
                switch (s1[0]) {
                    'A' => top = if (top > 0) top - 1 else 0, // ↑
                    'B' => top = @min(top + 1, max_top), // ↓
                    '5' => { // PageUp(ESC[5~)——读掉结尾 ~
                        var s2: [1]u8 = undefined;
                        _ = platform_term.readInput(fd, &s2);
                        top = if (top > view_rows) top - view_rows else 0;
                    },
                    '6' => { // PageDown(ESC[6~)
                        var s2: [1]u8 = undefined;
                        _ = platform_term.readInput(fd, &s2);
                        top = @min(top + view_rows, max_top);
                    },
                    '0'...'4', '7'...'9' => {
                        // Kitty/modifyOtherKeys CSI-u:ESC[<cp>;<mod>u(白名单终端把 Ctrl+O 编成
                        // ESC[111;5u 而非裸 0x0f → 旧 viewer 不退出,toggle 失效)。读完整序列到终止字母,
                        // 取 codepoint(';' 前的数字)。Ctrl+O(111)/q(113)/Esc(27)→ 退出(对称开关)。
                        const cp = readCsiCodepoint(fd, s1[0] - '0');
                        if (cp == 111 or cp == 113 or cp == 27) break;
                        // 其余 CSI-u(功能键等)忽略。
                    },
                    else => {},
                }
                continue;
            }
            break; // Esc + 非 [ → 退出
        }
        switch (c) {
            'q', 0x03, 0x0f => break, // q / Ctrl+C / Ctrl+O(对称开关)
            'j', ' ' => top = @min(top + 1, max_top),
            'k' => top = if (top > 0) top - 1 else 0,
            'g' => top = 0,
            'G' => top = max_top,
            'd' => top = @min(top + view_rows / 2, max_top),
            'u' => top = if (top > view_rows / 2) top - view_rows / 2 else 0,
            '}' => top = @min(nextPrompt(prompts, top), max_top),
            '{' => top = prevPrompt(prompts, top),
            else => {},
        }
    }

    // 退出:alt-screen(defer ov.exit() → \x1b[?1049l)由终端**自动逐字节恢复主缓冲**——banner+对话+
    // 输入框原样回来,零工作、零漂移。不再手动 \x1b[2J 清屏 + \n 重发对话尾(那是 inline 模式产物,
    // 会把框推走、重引 box_top 漂移)。caller(tui_backend/loop)在 ov.exit() 后 redraw 画固定区/输入框。
}

/// 读完一段 CSI 序列(已读到 ESC[<first_digit>),返回 ';' 前的 codepoint(如 Ctrl+O=111),
/// 并把剩余字节(mod 数字 + 终止字母 u/~/letter)读干净,不污染下一轮 read。
fn readCsiCodepoint(fd: c_int, first_digit: u8) u32 {
    var cp: u32 = first_digit;
    var in_mod = false; // 进入 ';' 后是 modifier 段,后续数字不计入 codepoint
    while (true) {
        var sx: [1]u8 = undefined;
        const nx = platform_term.readInput(fd, &sx);
        if (nx <= 0) return cp;
        const ch = sx[0];
        if (ch >= '0' and ch <= '9') {
            if (!in_mod) cp = cp * 10 + (ch - '0');
        } else if (ch == ';') {
            in_mod = true;
        } else {
            return cp; // 终止字母(u / ~ / A-Z / a-z)
        }
    }
}

fn nextPrompt(prompts: []const usize, cur: usize) usize {
    for (prompts) |p| {
        if (p > cur) return p;
    }
    return cur;
}

fn prevPrompt(prompts: []const usize, cur: usize) usize {
    var result: usize = 0;
    for (prompts) |p| {
        if (p < cur) result = p else break;
    }
    return result;
}

/// 在 alt-screen 独立缓冲里全屏重绘 transcript:内容画屏顶 rows 1..rows-2(每行 `\x1b[{r};1H` 绝对
/// 定位 + `\x1b[2K` 清行 + 内容)、footer 画屏底末2行(分隔线 rows-1 + 提示 rows)。缓冲是空的,
/// 绝对定位天然无两份、无滚动。退出由 caller 的 `Overlay.exit()`(ESC[?1049l)自动恢复主缓冲。
fn drawScreen(lines: []const []const u8, top: usize, view_rows: usize, rows: usize, cols: usize, th: @import("tui/theme.zig").Theme) void {
    var nbuf: [16]u8 = undefined;
    // alt-screen 独立缓冲内全帧绝对定位:内容画 rows 1..view_rows(=rows-2),每行 \x1b[{r};1H + 清行 +
    // 内容。缓冲是空的 → 绝对定位天然无两份、无滚动。空行也清(覆盖上一帧滚动后的残留)。
    var r: usize = 0;
    var i: usize = top;
    while (r < view_rows) : (r += 1) {
        const screen_row = r + 1; // 1-based,从屏顶画
        writeAll(1, std.fmt.bufPrint(&nbuf, "\x1b[{d};1H\x1b[2K", .{screen_row}) catch "");
        if (i < lines.len) {
            writeAll(1, lines[i]);
            i += 1;
        }
    }
    // footer(固定屏底末2行):分隔线(rows-1)+ 提示(rows)。绝对行 → 不堆叠成多行。
    const sep_row = if (rows >= 2) rows - 1 else 1;
    writeAll(1, std.fmt.bufPrint(&nbuf, "\x1b[{d};1H\x1b[2K", .{sep_row}) catch "");
    writeAll(1, th.dim);
    var k: usize = 0;
    const sep_w = if (cols > 0) cols else 80;
    while (k < sep_w) : (k += 1) writeAll(1, "\xe2\x94\x80"); // ─
    writeAll(1, th.reset);
    // footer 提示行(对齐 napicc v2.1.170 金标准全文)。
    writeAll(1, std.fmt.bufPrint(&nbuf, "\x1b[{d};1H\x1b[2K", .{rows}) catch "");
    writeAll(1, th.dim);
    writeAll(1, "  Showing detailed transcript · ctrl+o to toggle · ↑↓ scroll · q quit");
    writeAll(1, th.reset);
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    var total: usize = 0;
    while (total < bytes.len) {
        const n = pfs.write(fd, bytes[total..]);
        if (n <= 0) return;
        total += @intCast(n);
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "renderToLines: user=❯前缀 / assistant=⏺前缀+markdown(无角色头,渲染等效主区)" {
    const a = testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "fix the bug");
    try conv.appendText(.assistant, "Looking at it.\nFound it.");

    const lines = try renderToLines(a, &conv);
    defer freeLines(a, lines);

    var has_user_prefix = false; // user 文本 ❯ 前缀
    var has_asst_prefix = false; // assistant 段首 ⏺ 前缀
    var has_found = false;
    var has_role_header = false; // 不应再有 ▶ user / ◀ assistant 角色头
    for (lines) |l| {
        if (std.mem.indexOf(u8, l, "❯ ") != null and std.mem.indexOf(u8, l, "fix the bug") != null) has_user_prefix = true;
        if (std.mem.indexOf(u8, l, "⏺ ") != null and std.mem.indexOf(u8, l, "Looking at it") != null) has_asst_prefix = true;
        if (std.mem.indexOf(u8, l, "Found it") != null) has_found = true;
        if (std.mem.indexOf(u8, l, "▶ user") != null or std.mem.indexOf(u8, l, "◀ assistant") != null) has_role_header = true;
    }
    try testing.expect(has_user_prefix);
    try testing.expect(has_asst_prefix);
    try testing.expect(has_found);
    try testing.expect(!has_role_header); // 关键:无角色头(对齐 cc,渲染等效主区)
}

test "renderToLines: assistant markdown 渲染(粗体→SGR,非源码)" {
    const a = testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.assistant, "this is **bold** text");
    const lines = try renderToLines(a, &conv);
    defer freeLines(a, lines);
    // markdown 渲染后:`**bold**` 字面源码不应出现(应渲成 SGR 加粗);"bold" 文字仍在。
    var has_literal_stars = false;
    var has_bold_word = false;
    for (lines) |l| {
        if (std.mem.indexOf(u8, l, "**bold**") != null) has_literal_stars = true;
        if (std.mem.indexOf(u8, l, "bold") != null) has_bold_word = true;
    }
    try testing.expect(!has_literal_stars); // 关键:不显源码 `**bold**`(bug#1 根治)
    try testing.expect(has_bold_word);
}

test "renderToLines: Edit tool_result 经 renderResult 出 diff 着色" {
    const a = testing.allocator;
    const msg = @import("../core/message.zig");
    var conv = Conversation.init(a);
    defer conv.deinit();

    // assistant 发起 Edit tool_use
    {
        const blocks = try a.alloc(msg.Block, 1);
        blocks[0] = .{ .tool_use = .{
            .id = try a.dupe(u8, "tu_1"),
            .name = try a.dupe(u8, "Edit"),
            .input = try a.dupe(u8, "{\"file_path\":\"/x.zig\"}"),
        } };
        try conv.append(.{ .role = .assistant, .blocks = blocks });
    }
    // user 回 tool_result(含 gitDiff)
    {
        const blocks = try a.alloc(msg.Block, 1);
        blocks[0] = .{ .tool_result = .{
            .tool_use_id = try a.dupe(u8, "tu_1"),
            .content = try a.dupe(u8, "{\"success\":true,\"path\":\"/x.zig\",\"gitDiff\":\"--- a/x.zig\\n+++ b/x.zig\\n@@ -1,1 +1,1 @@\\n-const b = 2;\\n+const b = 20;\\n\"}"),
            .is_error = false,
        } };
        try conv.append(.{ .role = .user, .blocks = blocks });
    }

    const lines = try renderToLinesWithTheme(a, &conv, @import("tui/theme.zig").dark);
    defer freeLines(a, lines);

    var has_new = false;
    var has_old = false;
    var has_green = false;
    var has_red = false;
    const th = @import("tui/theme.zig").dark;
    for (lines) |l| {
        // 内容现经行内语法高亮(const→magenta、20→yellow),整句被 ANSI 切碎,
        // 故断言高亮无法拆开的片段:数字 20(+行)/ 行内 "b = "。
        if (std.mem.indexOf(u8, l, "20") != null) has_new = true;
        if (std.mem.indexOf(u8, l, "b = ") != null) has_old = true;
        if (std.mem.indexOf(u8, l, th.success) != null) has_green = true;
        if (std.mem.indexOf(u8, l, th.danger) != null) has_red = true;
    }
    try testing.expect(has_new); // + 行内容(数字 20)
    try testing.expect(has_old); // 行内 "b = " 片段
    try testing.expect(has_green); // + 行 success 着色
    try testing.expect(has_red); // - 行 danger 着色
}

test "userPromptLineIndices: finds user lines" {
    const a = testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "first");
    try conv.appendText(.assistant, "reply");
    try conv.appendText(.user, "second");

    const lines = try renderToLines(a, &conv);
    defer freeLines(a, lines);
    const prompts = try userPromptLineIndices(a, lines);
    defer a.free(prompts);
    try testing.expectEqual(@as(usize, 2), prompts.len);
    try testing.expect(prompts[0] < prompts[1]);
}

test "nextPrompt / prevPrompt navigation" {
    const prompts = [_]usize{ 0, 5, 12 };
    try testing.expectEqual(@as(usize, 5), nextPrompt(&prompts, 0));
    try testing.expectEqual(@as(usize, 12), nextPrompt(&prompts, 5));
    try testing.expectEqual(@as(usize, 12), nextPrompt(&prompts, 12)); // 末尾不动
    try testing.expectEqual(@as(usize, 5), prevPrompt(&prompts, 12));
    try testing.expectEqual(@as(usize, 0), prevPrompt(&prompts, 5));
    try testing.expectEqual(@as(usize, 0), prevPrompt(&prompts, 0));
}
