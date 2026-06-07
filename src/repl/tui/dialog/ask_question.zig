//! AskUserQuestion 交互对话框(替代 ask_user.zig 旧的 stderr 裸 print + 裸 read)。
//!
//! 设计对齐 dialog/permission.zig 的分层:
//! - render():纯渲染单个问题 → {frame,rows}(可 snapshot 测试)。rows = frame 行数,供 run 精确回顶。
//! - run():多问题 wizard,raw mode 读键循环。**由 TuiBackend.askQuestion 在主线程调用**——
//!   调用前已 stopInput(watcher 不再抢 fd0)+ enterExclusiveOverlay(持渲染锁冻结固定区)。
//!   故本模块独占 fd0/输出,**绝不**调任何 RenderRegion 渲染方法(非递归 mutex 会自死锁),只裸 writeAll。
//!
//! 单选:↑↓ 移动高亮 + 数字 1-4 跳选 + Enter 确认 → 选中 label。
//! 多选:↑↓ 移动 + 空格 toggle [x] + Enter 确认 → 勾选的 label 用 ", " 拼接(零勾选时 Enter 忽略)。
//! ESC / Ctrl+C → error.InputAborted(取消整个 AskUserQuestion,对齐 cc)。

const std = @import("std");
const ansi = @import("../ansi.zig");
const input_mod = @import("../../input.zig");
const theme_mod = @import("../theme.zig");
const layout = @import("../layout.zig");
const term = @import("../term.zig");
const ctx = @import("../../../tools/context.zig");
const Theme = theme_mod.Theme;

const MAX_DESC_PREVIEW = 72;
/// 真 cc 选中箭头(U+276F),区别于 theme.icon_arrow(→)。mono 降级用 ">"。
const POINTER = "❯";
const POINTER_ASCII = ">";
/// chip:未答/已答标记(对齐 cc ☐/☒)。mono 降级 [ ]/[x]。
const CHIP_OFF = "☐";
const CHIP_ON = "☒";
/// 多选 checkbox 勾选符(对齐 cc ✔)。
const CHECK_ON = "✔";
/// Submit 导航项标记。
const SUBMIT_MARK = "✔";

/// 自动追加的固定选项(对齐 cc:每问末尾追加 Type something + Chat about this)。
const OTHER_LABEL = "Type something";
const CHAT_LABEL = "Chat about this";

/// Other 项选中时的输入光标块(反色空格,让用户看到焦点在输入区)。mono 降级 "_"。
const CURSOR_BLOCK = "▏";
const CURSOR_BLOCK_ASCII = "_";

/// Chat about this 选中提交时返回的哨兵(对齐 cc onRespondToClaude:取消结构化问答转自由回复)。
/// 上层 ask_user/agent_loop 识别此值 → 不把它当答案塞给模型(留空答案,用户自由输入)。
pub const CHAT_SENTINEL = "\x00__cc_chat_about_this__";

fn isUnicode(th: Theme) bool {
    // mono 主题 box_h = "-"(ASCII);其余 = "─"(unicode)。借此判降级。
    return !std.mem.eql(u8, th.box_h, "-");
}

fn pointer(th: Theme) []const u8 {
    return if (isUnicode(th)) POINTER else POINTER_ASCII;
}

pub const Rendered = struct {
    frame: []u8, // owned,caller free
    rows: usize, // frame 占的终端行数(= frame 内 '\n' 数),run 用它 cursor.up 回顶
};


/// 多问导航信息(阶段2):画顶部 `←  chip… ✔ Submit  →` 导航条。
/// headers/answered 长度 == 问题数;current = 当前视图(== 问题数 时是 Submit 视图)。
pub const NavInfo = struct {
    headers: []const []const u8,
    answered: []const bool,
    current: usize, // 0..N-1 = 第 N 问;N = Submit 视图
};

/// 画导航条 `←  ☐ H1 ☒ H2  ✔ Submit  →`(render 与 renderSubmit 共用,避免两处实现漂移)。
/// 全量 chip 宽超终端 → 退紧凑 `←  <当前chip>  (i/N)  ✔ Submit →`(9 问也不撑屏)。
/// current==headers.len 时为 Submit 视图(Submit 高亮、紧凑模式不显单问 chip)。
fn appendNavBar(alloc: std.mem.Allocator, out: *std.ArrayList(u8), th: Theme, nav: NavInfo, width: usize) !void {
    const on_submit = nav.current == nav.headers.len;
    // 全量 chip 宽预估:每 chip ≈ chip符(2) + 空格(1) + header可见宽(≤12) + 间隔(2);+ ← + ✔Submit + →。
    var est: usize = 2 + 2 + 7 + 4;
    for (nav.headers) |h| est += 3 + @min(term.displayWidth(h), 12) + 2;
    const compact = est > width;

    try out.appendSlice(alloc, th.dim);
    try out.appendSlice(alloc, if (isUnicode(th)) "←" else "<");
    try out.appendSlice(alloc, th.reset);
    try out.appendSlice(alloc, "  ");
    if (compact) {
        if (!on_submit) {
            try out.appendSlice(alloc, th.accent);
            try out.appendSlice(alloc, if (isUnicode(th)) (if (nav.answered[nav.current]) CHIP_ON else CHIP_OFF) else (if (nav.answered[nav.current]) "[x]" else "[ ]"));
            try out.append(alloc, ' ');
            const hdr = try layout.truncate(alloc, nav.headers[nav.current], 12, "…");
            defer if (hdr.ptr != nav.headers[nav.current].ptr) alloc.free(@constCast(hdr));
            try out.appendSlice(alloc, hdr);
            try out.appendSlice(alloc, th.reset);
        }
        try out.appendSlice(alloc, th.dim);
        try out.print(alloc, "  ({d}/{d})  ", .{ @min(nav.current + 1, nav.headers.len), nav.headers.len });
        try out.appendSlice(alloc, th.reset);
    } else for (nav.headers, 0..) |h, qi| {
        const cur = qi == nav.current;
        if (cur) try out.appendSlice(alloc, th.accent) else try out.appendSlice(alloc, th.dim);
        try out.appendSlice(alloc, if (isUnicode(th)) (if (nav.answered[qi]) CHIP_ON else CHIP_OFF) else (if (nav.answered[qi]) "[x]" else "[ ]"));
        try out.append(alloc, ' ');
        const hdr = try layout.truncate(alloc, h, 12, "…");
        defer if (hdr.ptr != h.ptr) alloc.free(@constCast(hdr));
        try out.appendSlice(alloc, hdr);
        try out.appendSlice(alloc, th.reset);
        try out.appendSlice(alloc, "  ");
    }
    if (on_submit) try out.appendSlice(alloc, th.accent) else try out.appendSlice(alloc, th.dim);
    try out.appendSlice(alloc, if (isUnicode(th)) SUBMIT_MARK else "v");
    try out.appendSlice(alloc, " Submit");
    try out.appendSlice(alloc, th.reset);
    try out.appendSlice(alloc, "  ");
    try out.appendSlice(alloc, th.dim);
    try out.appendSlice(alloc, if (isUnicode(th)) "→" else ">");
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');
}

/// 渲染单个问题(对齐 cc 实录:chip 行/导航条 + 底边 + 裸排问题/选项 + 底部分隔线,**不套外层 box**)。
/// nav != null(多问):画 `←  chip… ✔ Submit  →` 导航条;nav == null(单问):画单 chip 行 + 底边。
/// selected:当前高亮选项 index(含末尾追加的 Other/Chat 虚拟项)。
/// checked:多选勾选状态(len >= 真实 options.len);单选忽略。
/// other_text:Other 项已输入的自由文本(空=显示 "Type something")。
/// cols:终端宽,画底部分隔线 + 导航条。caller free 返回的 .frame。
/// preview note 编辑态(对齐 cc:按 n 在 preview 框下加 note 行)。
/// text:已输入的 note(空=显示 placeholder);editing:是否在 note 编辑态(改提示行)。
pub const NoteState = struct {
    text: []const u8 = "",
    editing: bool = false,
};

pub fn render(
    alloc: std.mem.Allocator,
    th: Theme,
    q: ctx.AskQuestion,
    nav: ?NavInfo,
    selected: usize,
    checked: []const bool,
    other_text: []const u8,
    note: NoteState,
    cols: usize,
) !Rendered {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const width: usize = if (cols >= 20 and cols <= 200) cols else 80;
    const sep_w: usize = if (width > 2) width else 80;

    // ── 顶部:导航条(多问)/ chip 行(单问)。────────────────────────────
    if (nav) |nv| {
        try appendNavBar(alloc, &out, th, nv, width);
    } else {
        // 单问:` ☐ header` chip + box 底边。
        try out.append(alloc, ' ');
        try out.appendSlice(alloc, th.dim);
        try out.appendSlice(alloc, if (isUnicode(th)) CHIP_OFF else "[ ]");
        try out.append(alloc, ' ');
        const hdr = try layout.truncate(alloc, q.header, 12, "…"); // cc chip 限 12 列
        defer if (hdr.ptr != q.header.ptr) alloc.free(@constCast(hdr));
        try out.appendSlice(alloc, hdr);
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
        // box 底边(╰────╯),对齐 cc chip 行下的封边。
        try out.appendSlice(alloc, th.dim);
        try out.appendSlice(alloc, th.box_bl);
        var i: usize = 0;
        while (i < sep_w -| 2) : (i += 1) try out.appendSlice(alloc, th.box_h);
        try out.appendSlice(alloc, th.box_br);
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
    }

    // ── 问题文本(顶格,accent)。────────────────────────────────────────
    try out.appendSlice(alloc, th.accent);
    try out.appendSlice(alloc, q.question);
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');
    try out.append(alloc, '\n');

    // ── 选项块:先渲染进临时 buf(便于 preview side-by-side 行合并)。──────
    const real_n = q.options.len;
    const total_items = real_n + 2; // +Other +Chat
    var opt_buf: std.ArrayList(u8) = .empty;
    defer opt_buf.deinit(alloc);
    var idx: usize = 0;
    while (idx < total_items) : (idx += 1) {
        const is_sel = idx == selected;
        const is_other = idx == real_n;
        const is_chat = idx == real_n + 1;

        if (is_sel) {
            try opt_buf.appendSlice(alloc, th.accent);
            try opt_buf.appendSlice(alloc, pointer(th));
            try opt_buf.append(alloc, ' ');
        } else {
            try opt_buf.appendSlice(alloc, "  ");
        }
        try opt_buf.print(alloc, "{d}. ", .{idx + 1});
        if (q.multi and !is_chat) {
            const on = idx < checked.len and checked[idx];
            if (on) {
                try opt_buf.appendSlice(alloc, "[");
                try opt_buf.appendSlice(alloc, if (isUnicode(th)) CHECK_ON else "x");
                try opt_buf.appendSlice(alloc, "] ");
            } else {
                try opt_buf.appendSlice(alloc, "[ ] ");
            }
        }
        const label = if (is_other)
            (if (other_text.len > 0) other_text else OTHER_LABEL)
        else if (is_chat)
            CHAT_LABEL
        else
            q.options[idx].label;
        try opt_buf.appendSlice(alloc, label);
        // Other 项选中时显输入光标块——让用户看到焦点在此可直接打字(bug1:旧版无任何输入反馈)。
        if (is_other and is_sel) {
            try opt_buf.appendSlice(alloc, if (isUnicode(th)) CURSOR_BLOCK else CURSOR_BLOCK_ASCII);
        }
        if (is_sel) try opt_buf.appendSlice(alloc, th.reset);
        try opt_buf.append(alloc, '\n');

        if (!is_other and !is_chat and q.options[idx].description.len > 0) {
            const desc = try layout.truncate(alloc, q.options[idx].description, MAX_DESC_PREVIEW, "…");
            defer if (desc.ptr != q.options[idx].description.ptr) alloc.free(@constCast(desc));
            const indent: usize = if (q.multi) 2 else 5;
            var p: usize = 0;
            while (p < indent) : (p += 1) try opt_buf.append(alloc, ' ');
            try opt_buf.appendSlice(alloc, th.dim);
            try opt_buf.appendSlice(alloc, desc);
            try opt_buf.appendSlice(alloc, th.reset);
            try opt_buf.append(alloc, '\n');
        }
    }

    // ── preview side-by-side:单选 + 选中真实项有 preview → 右侧框,行合并。──
    const preview_text: []const u8 = if (!q.multi and selected < real_n) q.options[selected].preview else "";
    var has_preview = false;
    if (preview_text.len > 0) {
        has_preview = true;
        try appendOptionsWithPreview(alloc, th, &out, opt_buf.items, preview_text, note, width);
    } else {
        try out.appendSlice(alloc, opt_buf.items);
    }

    // ── 底部分隔线(────)+ 提示行。────────────────────────────────────
    try out.appendSlice(alloc, th.dim);
    var j: usize = 0;
    while (j < sep_w) : (j += 1) try out.appendSlice(alloc, th.box_h);
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');

    try out.appendSlice(alloc, th.dim);
    // 提示行随上下文变:note 编辑态 / Other 项 / preview 模式 / 普通。
    if (has_preview and note.editing) {
        try out.appendSlice(alloc, "ctrl+g to edit in Vim · Esc to cancel"); // note 编辑态(实录)
    } else if (selected == real_n) {
        // Other 选中=输入态:强调可直接打字(bug1:旧文案"Enter to select"误导,像还在选项导航)。
        try out.appendSlice(alloc, "Type your answer · Enter to submit · ctrl+g to edit in Vim · Esc to cancel");
    } else if (has_preview) {
        try out.appendSlice(alloc, "Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel");
    } else {
        try out.appendSlice(alloc, "Enter to select · ↑/↓ to navigate · Esc to cancel");
    }
    try out.appendSlice(alloc, th.reset);

    const frame = try out.toOwnedSlice(alloc);
    var rows: usize = 0;
    for (frame) |c| {
        if (c == '\n') rows += 1;
    }
    return .{ .frame = frame, .rows = rows };
}

/// 一行的可见显示宽(跳过 SGR 转义序列 ESC[…m)。
fn visibleWidth(line: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == 0x1b) {
            // 跳到 'm'(SGR 结束)或序列尽头。
            var j = i + 1;
            while (j < line.len and line[j] != 'm') : (j += 1) {}
            i = if (j < line.len) j + 1 else line.len;
            continue;
        }
        const cp_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const end = @min(i + cp_len, line.len);
        w += term.displayWidth(line[i..end]);
        i = end;
    }
    return w;
}

/// preview side-by-side:左 opt_buf(多行)+ 右 preview 框,行合并写进 out。
/// 对齐 cc:选项列 + 右侧圆角框(┌┐└┘),超 maxlines 折叠 `── ✂ ── N lines hidden ──`。
fn appendOptionsWithPreview(
    alloc: std.mem.Allocator,
    th: Theme,
    out: *std.ArrayList(u8),
    opt_buf: []const u8,
    preview_text: []const u8,
    note: NoteState,
    width: usize,
) !void {
    const PREVIEW_MAXLINES = 6;
    // 右框起始列:选项列后留 gap。左列宽取选项最长可见宽 + gap,最小 34(对齐 cc 观感)。
    var max_opt_w: usize = 0;
    {
        var it = std.mem.splitScalar(u8, opt_buf, '\n');
        while (it.next()) |ln| {
            if (ln.len == 0) continue;
            const w = visibleWidth(ln);
            if (w > max_opt_w) max_opt_w = w;
        }
    }
    const left_col = @max(max_opt_w + 2, 34);
    const box_inner: usize = if (width > left_col + 6) width - left_col - 4 else 40;

    // 构造 preview 框的行(不含左侧):┌─…─┐ / │ content │ … / └─…─┘ + 折叠。
    var pv_lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (pv_lines.items) |l| alloc.free(@constCast(l));
        pv_lines.deinit(alloc);
    }
    // 顶边。
    try pv_lines.append(alloc, try boxEdge(alloc, th, "┌", "┐", box_inner));
    // 正文(逐行,折叠)。
    var total_lines: usize = 0;
    var shown: usize = 0;
    var pit = std.mem.splitScalar(u8, preview_text, '\n');
    while (pit.next()) |pl| {
        total_lines += 1;
        if (shown < PREVIEW_MAXLINES) {
            try pv_lines.append(alloc, try boxContent(alloc, th, pl, box_inner));
            shown += 1;
        }
    }
    if (total_lines > PREVIEW_MAXLINES) {
        try pv_lines.append(alloc, try boxFold(alloc, th, total_lines - PREVIEW_MAXLINES, box_inner));
    }
    // 底边。
    try pv_lines.append(alloc, try boxEdge(alloc, th, "└", "┘", box_inner));

    // note 行(对齐 cc):编辑态 → note 内容/placeholder 行(缩进进框内);随后 `Notes: press n…`。
    if (note.editing) {
        var nl: std.ArrayList(u8) = .empty;
        errdefer nl.deinit(alloc);
        try nl.appendSlice(alloc, "  "); // 框内缩进
        if (note.text.len > 0) {
            try nl.appendSlice(alloc, note.text);
        } else {
            try nl.appendSlice(alloc, th.dim);
            try nl.appendSlice(alloc, "Add notes on this design…");
            try nl.appendSlice(alloc, th.reset);
        }
        try pv_lines.append(alloc, try nl.toOwnedSlice(alloc));
    }
    {
        var hl: std.ArrayList(u8) = .empty;
        errdefer hl.deinit(alloc);
        try hl.appendSlice(alloc, th.dim);
        if (note.text.len > 0 and !note.editing) {
            // 已存 note(非编辑态):显示 `Notes: <text>`。
            try hl.appendSlice(alloc, "Notes: ");
            try hl.appendSlice(alloc, th.reset);
            try hl.appendSlice(alloc, note.text);
        } else {
            try hl.appendSlice(alloc, "Notes: press n to add notes");
            try hl.appendSlice(alloc, th.reset);
        }
        try pv_lines.append(alloc, try hl.toOwnedSlice(alloc));
    }

    // 行合并:逐左行,右补到 left_col,再拼对应 preview 行。
    var lit = std.mem.splitScalar(u8, opt_buf, '\n');
    var row: usize = 0;
    while (lit.next()) |ln| {
        // opt_buf 末尾的空段(最后一个 \n 后)不输出。
        if (ln.len == 0 and lit.peek() == null) break;
        try out.appendSlice(alloc, ln);
        const vw = visibleWidth(ln);
        if (row < pv_lines.items.len) {
            var pad = if (left_col > vw) left_col - vw else 1;
            while (pad > 0) : (pad -= 1) try out.append(alloc, ' ');
            try out.appendSlice(alloc, pv_lines.items[row]);
        }
        try out.append(alloc, '\n');
        row += 1;
    }
    // 若 preview 行多于左行,补齐剩余 preview 行。
    while (row < pv_lines.items.len) : (row += 1) {
        var pad = left_col;
        while (pad > 0) : (pad -= 1) try out.append(alloc, ' ');
        try out.appendSlice(alloc, pv_lines.items[row]);
        try out.append(alloc, '\n');
    }
}

fn boxEdge(alloc: std.mem.Allocator, th: Theme, l: []const u8, r: []const u8, inner: usize) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(alloc);
    try b.appendSlice(alloc, th.dim);
    try b.appendSlice(alloc, if (isUnicode(th)) l else "+");
    var i: usize = 0;
    while (i < inner + 2) : (i += 1) try b.appendSlice(alloc, th.box_h);
    try b.appendSlice(alloc, if (isUnicode(th)) r else "+");
    try b.appendSlice(alloc, th.reset);
    return try b.toOwnedSlice(alloc);
}

fn boxContent(alloc: std.mem.Allocator, th: Theme, content: []const u8, inner: usize) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(alloc);
    const trunc = try layout.truncate(alloc, content, inner, "…");
    defer if (trunc.ptr != content.ptr) alloc.free(@constCast(trunc));
    try b.appendSlice(alloc, th.dim);
    try b.appendSlice(alloc, if (isUnicode(th)) "│" else "|");
    try b.appendSlice(alloc, th.reset);
    try b.append(alloc, ' ');
    try b.appendSlice(alloc, trunc);
    // 右 pad 到 inner。
    var pad = if (inner > visibleWidth(trunc)) inner - visibleWidth(trunc) else 0;
    while (pad > 0) : (pad -= 1) try b.append(alloc, ' ');
    try b.append(alloc, ' ');
    try b.appendSlice(alloc, th.dim);
    try b.appendSlice(alloc, if (isUnicode(th)) "│" else "|");
    try b.appendSlice(alloc, th.reset);
    return try b.toOwnedSlice(alloc);
}

fn boxFold(alloc: std.mem.Allocator, th: Theme, hidden: usize, inner: usize) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(alloc);
    try b.appendSlice(alloc, th.dim);
    try b.appendSlice(alloc, if (isUnicode(th)) "├── ✂ ── " else "+-- X -- ");
    try b.print(alloc, "{d} lines hidden ", .{hidden});
    const used = visibleWidth(b.items) - visibleWidth(th.dim);
    var i: usize = used;
    while (i < inner + 3) : (i += 1) try b.appendSlice(alloc, th.box_h);
    try b.appendSlice(alloc, if (isUnicode(th)) "┤" else "+");
    try b.appendSlice(alloc, th.reset);
    return try b.toOwnedSlice(alloc);
}


/// all_answered=false 时显警告行。sel:0=Submit answers,1=Cancel。
pub fn renderSubmit(
    alloc: std.mem.Allocator,
    th: Theme,
    nav: NavInfo,
    all_answered: bool,
    sel: usize,
    cols: usize,
) !Rendered {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const width: usize = if (cols >= 20 and cols <= 200) cols else 80;
    const sep_w: usize = if (width > 2) width else 80;

    // 导航条(current = Submit)。
    try appendNavBar(alloc, &out, th, nav, width);

    try out.appendSlice(alloc, "Review your answers\n");
    if (!all_answered) {
        try out.appendSlice(alloc, th.warn);
        try out.appendSlice(alloc, if (isUnicode(th)) "⚠ " else "! ");
        try out.appendSlice(alloc, "You have not answered all questions");
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
    }
    try out.appendSlice(alloc, "Ready to submit your answers?\n");

    // Submit / Cancel 选项。
    const labels = [_][]const u8{ "Submit answers", "Cancel" };
    for (labels, 0..) |lab, i| {
        if (i == sel) {
            try out.appendSlice(alloc, th.accent);
            try out.appendSlice(alloc, pointer(th));
            try out.append(alloc, ' ');
        } else {
            try out.appendSlice(alloc, "  ");
        }
        try out.print(alloc, "{d}. {s}", .{ i + 1, lab });
        if (i == sel) try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
    }

    try out.appendSlice(alloc, th.dim);
    var j: usize = 0;
    while (j < sep_w) : (j += 1) try out.appendSlice(alloc, th.box_h);
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, "Enter to select · ↑/↓ to navigate · Esc to cancel");
    try out.appendSlice(alloc, th.reset);

    const frame = try out.toOwnedSlice(alloc);
    var rows: usize = 0;
    for (frame) |c| {
        if (c == '\n') rows += 1;
    }
    return .{ .frame = frame, .rows = rows };
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) void {
    var total: usize = 0;
    while (total < bytes.len) {
        const w = std.c.write(fd, bytes.ptr + total, bytes.len - total);
        if (w <= 0) return;
        total += @as(usize, @intCast(w));
    }
}

/// 上限(每问选项 2-4;问题数上限在 ask_user.MAX_QUESTIONS=9 校验,这里留余量防越界)。
/// MAX_Q 必须 ≥ ask_user.MAX_QUESTIONS,否则合法的 9 问会撞这里的栈数组容量崩 InputAborted。
const MAX_Q = 12;
const MAX_OPT = 16;

comptime {
    // 容量必须容得下工具层放行的最大问题数,否则合法输入会在 run() 里越界/被错误兜底。
    std.debug.assert(MAX_Q >= @import("../../../tools/ask_user.zig").MAX_QUESTIONS);
}

/// 单问的可变状态(wizard 跨视图保留)。
const QState = struct {
    selected: usize = 0, // 当前高亮项(含 Other/Chat 虚拟项)
    checked: [MAX_OPT]bool = [_]bool{false} ** MAX_OPT,
    other_buf: [256]u8 = undefined,
    other_len: usize = 0,
    answered: bool = false, // chip ☐/☒:单选已选 / 多选已勾 / Other 已填
    // 已定答案(answered=true 时有效;Submit 时一次性输出)。owned。
    answer: ?[]u8 = null,
    // preview note:per-option(每个 preview 选项自己的 note)。editing=当前在 note 编辑态。
    note_buf: [MAX_OPT][128]u8 = undefined,
    note_len: [MAX_OPT]usize = [_]usize{0} ** MAX_OPT,
    editing_note: bool = false,
};

/// 多问题 wizard 交互循环(状态机)。调用方已 stopInput + enterExclusiveOverlay + raw mode。
/// 视图:0..N-1 = 第 N 问;N = Submit 确认。←→ 切视图,↑↓ 选项,space toggle,数字跳选,
/// Other 项直接打字内联编辑,enter 确定本问(单选自动→下一视图);Submit 视图选 Submit answers 完成。
/// esc/Ctrl+C → InputAborted(整个工具放弃)。每问一条答案 append 到 out(owned)。
pub fn run(
    alloc: std.mem.Allocator,
    th: Theme,
    in_fd: std.c.fd_t,
    questions: []const ctx.AskQuestion,
    out: *std.ArrayList([]const u8),
    cols: usize,
) !void {
    const out_fd: std.c.fd_t = 2;
    const nq = questions.len;
    if (nq == 0) return;
    const multi_q = nq > 1;

    var qs = [_]QState{.{}} ** MAX_Q;
    defer for (qs[0..@min(nq, MAX_Q)]) |*s| {
        if (s.answer) |a| alloc.free(a);
    };
    if (nq > MAX_Q) return error.InputAborted;

    var view: usize = 0; // 当前视图(0..nq-1 问题;nq = Submit,仅 multi_q)
    var submit_sel: usize = 0; // Submit 视图的 Submit/Cancel 选择

    // 导航条 headers(借问题的 header)。
    var headers: [MAX_Q][]const u8 = undefined;
    var answered_flags: [MAX_Q]bool = undefined;
    for (questions[0..nq], 0..) |q, qi| headers[qi] = q.header;

    var prev_rows: usize = 0;
    while (true) {
        for (qs[0..nq], 0..) |s, qi| answered_flags[qi] = s.answered;
        // 单问完成:advanceView 把 view 推过末尾(== nq)→ finalize 返回(无 Submit 视图)。
        if (!multi_q and view >= nq) {
            return try finalizeAll(alloc, questions[0..nq], qs[0..nq], out);
        }

        const nav: ?NavInfo = if (multi_q) NavInfo{
            .headers = headers[0..nq],
            .answered = answered_flags[0..nq],
            .current = view,
        } else null;

        // 回顶重画:回到上一帧首行行首,再 clear-to-end-of-screen 抹掉整帧足迹。
        // 不擦会留下旧帧残字——新帧某行比旧行短时尾部旧字符不被覆盖(实测乱码
        // `Esc to cancelt in Vim`),且旧 REPL 输入框/分隔线残影会冒出来(实测多出一个输入框)。
        if (prev_rows > 0) {
            var up_buf: [16]u8 = undefined;
            writeAll(out_fd, ansi.cursor.up(@intCast(prev_rows), &up_buf));
            writeAll(out_fd, "\r");
            writeAll(out_fd, ansi.clear.to_end_of_screen);
        }

        const on_submit = multi_q and view == nq;
        const r = if (on_submit) blk: {
            var all = true;
            for (qs[0..nq]) |s| {
                if (!s.answered) all = false;
            }
            break :blk try renderSubmit(alloc, th, nav.?, all, submit_sel, cols);
        } else blk: {
            const q = questions[view];
            const st = &qs[view];
            break :blk try render(alloc, th, q, nav, st.selected, st.checked[0 .. q.options.len + 2], st.other_buf[0..st.other_len], .{
                .text = if (st.selected < q.options.len) st.note_buf[st.selected][0..st.note_len[st.selected]] else "",
                .editing = st.editing_note,
            }, cols);
        };
        defer alloc.free(r.frame);
        writeAll(out_fd, r.frame);
        prev_rows = r.rows;

        var buf: [8]u8 = undefined;
        const n = std.c.read(in_fd, &buf, buf.len);
        if (n <= 0) return error.InputAborted;
        const b = buf[0];

        // ── Submit 视图键处理。──────────────────────────────────────────
        if (on_submit) {
            switch (b) {
                0x03 => return error.InputAborted,
                0x1b => {
                    if (n >= 3 and buf[1] == '[') {
                        switch (buf[2]) {
                            'A' => submit_sel = if (submit_sel == 0) 1 else 0,
                            'B' => submit_sel = (submit_sel + 1) % 2,
                            'D' => view = nq - 1, // ← 回最后一问
                            else => {},
                        }
                        continue;
                    }
                    return error.InputAborted;
                },
                '\r', '\n' => {
                    if (submit_sel == 1) { // Cancel → 回最后一问
                        view = nq - 1;
                        continue;
                    }
                    // Submit answers:输出所有已答(未答的用首选项兜底,对齐 answer_queue 兜底语义)。
                    return try finalizeAll(alloc, questions[0..nq], qs[0..nq], out);
                },
                '1' => {
                    submit_sel = 0;
                    continue;
                },
                '2' => {
                    submit_sel = 1;
                    continue;
                },
                else => continue,
            }
        }

        // ── 问题视图键处理。──────────────────────────────────────────────
        const q = questions[view];
        const st = &qs[view];
        const real_n = q.options.len;
        const total_items = real_n + 2;
        const other_idx = real_n;
        const chat_idx = real_n + 1;
        const has_preview = !q.multi and st.selected < real_n and q.options[st.selected].preview.len > 0;

        // ── note 编辑态:所有输入进 note 缓冲;Esc/enter 退出(保留 note)。──
        if (st.editing_note) {
            const oi = st.selected; // 编辑的是当前选项的 note
            if (b == 0x07) { // Ctrl+G:唤起 $EDITOR/Vim 编辑 note(对齐 cc"edit in Vim")。
                editNoteInEditor(alloc, in_fd, st, oi);
                continue;
            }
            if (b == 0x1b or b == '\r' or b == '\n') {
                // Esc / enter:退出 note 编辑态(实录:Esc 保留已输入 note)。
                st.editing_note = false;
                continue;
            }
            if (b == 0x7f) { // backspace
                if (st.note_len[oi] > 0) st.note_len[oi] -= 1;
                continue;
            }
            if (b >= 0x20 and oi < real_n and st.note_len[oi] + 1 < st.note_buf[oi].len) {
                st.note_buf[oi][st.note_len[oi]] = b;
                st.note_len[oi] += 1;
            }
            continue;
        }

        // 'n':preview 模式下进 note 编辑态(对齐 cc)。
        if (b == 'n' and has_preview and st.selected != other_idx) {
            st.editing_note = true;
            continue;
        }

        // Other 项上:可见字符直接内联编辑。
        if (st.selected == other_idx and b >= 0x20 and b != 0x7f and b != ' ') {
            if (st.other_len + 1 < st.other_buf.len) {
                st.other_buf[st.other_len] = b;
                st.other_len += 1;
            }
            continue;
        }

        switch (b) {
            0x03 => return error.InputAborted,
            0x7f => {
                if (st.selected == other_idx and st.other_len > 0) st.other_len -= 1;
                continue;
            },
            0x1b => {
                if (n >= 3 and buf[1] == '[') {
                    switch (buf[2]) {
                        'A' => st.selected = if (st.selected == 0) total_items - 1 else st.selected - 1, // ↑
                        'B' => st.selected = (st.selected + 1) % total_items, // ↓
                        'C' => if (multi_q) { // → 下一视图(问题或 Submit)
                            view = if (view + 1 <= nq) view + 1 else nq;
                        },
                        'D' => if (multi_q and view > 0) { // ← 上一问
                            view -= 1;
                        },
                        else => {},
                    }
                    continue;
                }
                return error.InputAborted; // 孤立 ESC
            },
            ' ' => {
                if (st.selected == other_idx) {
                    if (st.other_len + 1 < st.other_buf.len) {
                        st.other_buf[st.other_len] = ' ';
                        st.other_len += 1;
                    }
                } else if (q.multi and st.selected != chat_idx) {
                    st.checked[st.selected] = !st.checked[st.selected];
                    st.answered = anyChecked(st.checked[0..real_n]);
                }
                continue;
            },
            '\r', '\n' => {
                try commitQuestion(alloc, q, st, chat_idx, other_idx, real_n);
                if (st.answered) advanceView(&view, nq, q.multi, multi_q);
                continue;
            },
            '1'...'9' => {
                const idx: usize = b - '1';
                if (idx < total_items) {
                    st.selected = idx;
                    if (q.multi and idx < real_n) {
                        st.checked[idx] = !st.checked[idx];
                        st.answered = anyChecked(st.checked[0..real_n]);
                    } else if (!q.multi and idx < real_n) {
                        try commitQuestion(alloc, q, st, chat_idx, other_idx, real_n);
                        advanceView(&view, nq, q.multi, multi_q);
                    }
                }
                continue;
            },
            else => continue,
        }
    }
}

fn anyChecked(checked: []const bool) bool {
    for (checked) |c| {
        if (c) return true;
    }
    return false;
}

/// 单问 wizard:无导航(单问)直接逐问处理时,enter 后无下一视图 → 由 advanceView 决定。
/// 单问(!multi_q):commit 后直接结束(view 推到 nq=1 触发 finalize)。
fn advanceView(view: *usize, nq: usize, multi: bool, multi_q: bool) void {
    _ = multi;
    if (!multi_q) {
        view.* = nq; // 单问:推过末尾,run 末尾处理 finalize
    } else if (view.* + 1 <= nq) {
        view.* = view.* + 1; // 多问:→ 下一视图(到 Submit)
    }
}

/// 把当前问的选择固化进 st.answer + 标记 answered。
fn commitQuestion(alloc: std.mem.Allocator, q: ctx.AskQuestion, st: *QState, chat_idx: usize, other_idx: usize, real_n: usize) !void {
    if (st.answer) |a| {
        alloc.free(a);
        st.answer = null;
    }
    if (st.selected == chat_idx) {
        // Chat about this = 取消结构化问答转自由回复(对齐 cc onRespondToClaude)。
        // 返回哨兵而非字面 label,上层识别后不当答案塞模型(bug2:旧版把 "Chat about this" 当答案)。
        st.answer = try alloc.dupe(u8, CHAT_SENTINEL);
        st.answered = true;
        return;
    }
    if (st.selected == other_idx) {
        if (st.other_len == 0) return; // 空 Other 不算答
        st.answer = try alloc.dupe(u8, st.other_buf[0..st.other_len]);
        st.answered = true;
        return;
    }
    if (q.multi) {
        if (!anyChecked(st.checked[0..real_n])) return; // 零勾选不算答
        st.answer = @constCast(try joinChecked(alloc, q.options, st.checked[0..real_n]));
        st.answered = true;
        return;
    }
    st.answer = try alloc.dupe(u8, q.options[st.selected].label);
    st.answered = true;
}

/// Submit:把每问答案 append 到 out(未答用首选项 label 兜底)。
fn finalizeAll(alloc: std.mem.Allocator, questions: []const ctx.AskQuestion, qs: []QState, out: *std.ArrayList([]const u8)) !void {
    for (questions, 0..) |q, qi| {
        const st = &qs[qi];
        if (st.answer) |a| {
            try out.append(alloc, a);
            st.answer = null; // 所有权转移给 out,避免 defer 双 free
        } else {
            // 未答兜底:首选项 label。
            try out.append(alloc, try alloc.dupe(u8, q.options[0].label));
        }
    }
}


/// note 编辑态 Ctrl+G:暂退 raw → 唤起 $EDITOR/Vim 编辑当前选项 note → 重进 raw → 回填。
/// 终端模式:对话框运行在生成期 raw(gen_raw_orig)下;编辑器需 cooked,故 save→restore→editor→re-enter。
/// 失败(无 $EDITOR/spawn 失败)静默忽略(note 保持原样,不崩)。
fn editNoteInEditor(alloc: std.mem.Allocator, fd: std.c.fd_t, st: *QState, oi: usize) void {
    if (oi >= MAX_OPT) return;
    // 1. 存当前(raw)termios,临时回 cooked(ECHO+ICANON)给编辑器。
    var saved: std.c.termios = undefined;
    if (std.c.tcgetattr(fd, &saved) != 0) return;
    var cooked = saved;
    cooked.lflag.ECHO = true;
    cooked.lflag.ICANON = true;
    cooked.lflag.ISIG = true;
    _ = std.c.tcsetattr(fd, std.posix.TCSA.FLUSH, &cooked);

    // 2. 唤起编辑器(前台阻塞),传入当前 note 文本。
    const cur = st.note_buf[oi][0..st.note_len[oi]];
    const edited = input_mod.externalEdit(alloc, cur) catch {
        _ = std.c.tcsetattr(fd, std.posix.TCSA.FLUSH, &saved); // 失败也要恢复 raw
        return;
    };
    defer alloc.free(edited);

    // 3. 恢复 raw termios(对话框继续读键)。
    _ = std.c.tcsetattr(fd, std.posix.TCSA.FLUSH, &saved);

    // 4. 回填编辑结果(截断到 buf 上限;只取首行,note 是单行语义)。
    const line_end = std.mem.indexOfScalar(u8, edited, '\n') orelse edited.len;
    const n = @min(line_end, st.note_buf[oi].len - 1);
    @memcpy(st.note_buf[oi][0..n], edited[0..n]);
    st.note_len[oi] = n;
}

/// 多选:勾选的 label 用 ", " 拼接(owned)。
fn joinChecked(alloc: std.mem.Allocator, options: []const ctx.AskOption, checked: []const bool) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var count: usize = 0;
    for (options, 0..) |o, i| {
        if (i >= checked.len or !checked[i]) continue;
        if (count > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, o.label);
        count += 1;
    }
    return try buf.toOwnedSlice(alloc);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const capture = @import("../test_capture.zig");

fn mkOpt(label: []const u8, desc: []const u8) ctx.AskOption {
    return .{ .label = label, .description = desc };
}

test "render: 单选像素结构(❯+编号 / desc 独立行 / Other+Chat 追加 / 提示文案)" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{ mkOpt("Red", "a warm color"), mkOpt("Green", "a calm color") };
    const q = ctx.AskQuestion{ .question = "Which color?", .header = "Color", .multi = false, .options = &opts };
    const r = try render(testing.allocator, th, q, null, 0, &.{ false, false, false, false }, "", .{}, 80);
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "Color"); // chip header
    try capture.expectContains(r.frame, "Which color?");
    try capture.expectContains(r.frame, "1. Red"); // 编号
    try capture.expectContains(r.frame, "2. Green");
    try capture.expectContains(r.frame, "a warm color"); // desc 独立行
    try capture.expectContains(r.frame, "3. Type something"); // Other 自动追加
    try capture.expectContains(r.frame, "4. Chat about this"); // Chat 自动追加
    try capture.expectContains(r.frame, "Enter to select · ↑/↓ to navigate · Esc to cancel");
    try testing.expect(std.mem.indexOf(u8, r.frame, "\x1b") == null); // mono 无 ANSI
}

test "render: 单选选中项显 ❯ 箭头(unicode)" {
    const th = theme_mod.dark;
    const opts = [_]ctx.AskOption{ mkOpt("a", ""), mkOpt("b", "") };
    const q = ctx.AskQuestion{ .question = "q", .header = "", .multi = false, .options = &opts };
    const r = try render(testing.allocator, th, q, null, 1, &.{ false, false, false, false }, "", .{}, 80);
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "❯"); // cc 风格箭头(非 →)
    try testing.expect(std.mem.indexOf(u8, r.frame, "\x1b") != null);
}

test "render: 多选 checkbox 在编号后 [ ]/[✔]" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{ mkOpt("Zig", ""), mkOpt("Rust", ""), mkOpt("Go", "") };
    const q = ctx.AskQuestion{ .question = "langs?", .header = "L", .multi = true, .options = &opts };
    const r = try render(testing.allocator, th, q, null, 0, &.{ true, false, true, false, false }, "", .{}, 80);
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "1. [x] Zig"); // 编号后 checkbox(mono x)
    try capture.expectContains(r.frame, "2. [ ] Rust");
}

test "render: 多选 unicode checkbox ✔" {
    const th = theme_mod.dark;
    const opts = [_]ctx.AskOption{ mkOpt("a", ""), mkOpt("b", "") };
    const q = ctx.AskQuestion{ .question = "q", .header = "", .multi = true, .options = &opts };
    const r = try render(testing.allocator, th, q, null, 0, &.{ true, false, false, false }, "", .{}, 80);
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "✔"); // 勾选符
}

test "render: 不套外层 box(无顶边 ╭),只 chip 底边 ╰ + 底部分隔线" {
    const th = theme_mod.dark;
    const opts = [_]ctx.AskOption{ mkOpt("a", ""), mkOpt("b", "") };
    const q = ctx.AskQuestion{ .question = "q", .header = "H", .multi = false, .options = &opts };
    const r = try render(testing.allocator, th, q, null, 0, &.{ false, false, false, false }, "", .{}, 80);
    defer testing.allocator.free(r.frame);
    try testing.expect(std.mem.indexOf(u8, r.frame, th.box_tl) == null); // 无顶边圆角
    try testing.expect(std.mem.indexOf(u8, r.frame, th.box_bl) != null); // 有 chip 底边
}

test "render: Other 项显示已输入文本(other_text)" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{ mkOpt("a", ""), mkOpt("b", "") };
    const q = ctx.AskQuestion{ .question = "q", .header = "", .multi = false, .options = &opts };
    // selected=2(Other 项),已输入 "purple"。
    const r = try render(testing.allocator, th, q, null, 2, &.{ false, false, false, false }, "purple", .{}, 80);
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "3. purple"); // Other label = 输入文本
    try capture.expectContains(r.frame, "ctrl+g to edit in Vim"); // 选中 Other 提示行变化
}

test "render: rows == frame 内换行数(供回顶)" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{ mkOpt("a", ""), mkOpt("b", "") };
    const q = ctx.AskQuestion{ .question = "q", .header = "H", .multi = false, .options = &opts };
    const r = try render(testing.allocator, th, q, null, 0, &.{ false, false, false, false }, "", .{}, 80);
    defer testing.allocator.free(r.frame);
    var nl: usize = 0;
    for (r.frame) |c| {
        if (c == '\n') nl += 1;
    }
    try testing.expectEqual(nl, r.rows);
    try testing.expect(r.rows > 0);
}

test "joinChecked: 勾选 label 用 \", \" 拼接,跳过未勾选" {
    const opts = [_]ctx.AskOption{ mkOpt("a", ""), mkOpt("b", ""), mkOpt("c", "") };
    const joined = try joinChecked(testing.allocator, &opts, &.{ true, false, true });
    defer testing.allocator.free(@constCast(joined));
    try testing.expectEqualStrings("a, c", joined);
}

test "joinChecked: 全勾选" {
    const opts = [_]ctx.AskOption{ mkOpt("x", ""), mkOpt("y", "") };
    const joined = try joinChecked(testing.allocator, &opts, &.{ true, true });
    defer testing.allocator.free(@constCast(joined));
    try testing.expectEqualStrings("x, y", joined);
}

test "render: 9 问导航条退紧凑模式不撑屏(80 列)" {
    // 放宽到 9 问后导航条全量 chip ~140 列 > 80 → 必须退紧凑 `(i/N)`,否则软换行错乱。
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{ mkOpt("a", ""), mkOpt("b", "") };
    const q = ctx.AskQuestion{ .question = "q", .header = "Day1早餐", .multi = false, .options = &opts };
    var hdrs: [9][]const u8 = undefined;
    var ans: [9]bool = undefined;
    for (0..9) |i| {
        hdrs[i] = "Day1早餐";
        ans[i] = false;
    }
    const nav = NavInfo{ .headers = &hdrs, .answered = &ans, .current = 4 };
    const r = try render(testing.allocator, th, q, nav, 0, &.{ false, false, false, false }, "", .{}, 80);
    defer testing.allocator.free(r.frame);
    const nl = std.mem.indexOfScalar(u8, r.frame, '\n') orelse r.frame.len;
    try testing.expect(visibleWidth(r.frame[0..nl]) <= 80); // 导航条不超终端宽
    try capture.expectContains(r.frame, "(5/9)"); // 紧凑进度计数(current=4 → 第5问)
    try capture.expectContains(r.frame, "Submit"); // Submit 项仍在
}

test "render: 少量问题仍画全部 chip(不误退紧凑)" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{ mkOpt("a", ""), mkOpt("b", "") };
    const q = ctx.AskQuestion{ .question = "q", .header = "C2", .multi = false, .options = &opts };
    const hdrs = [_][]const u8{ "C1", "C2" };
    const ans = [_]bool{ false, false };
    const nav = NavInfo{ .headers = &hdrs, .answered = &ans, .current = 1 };
    const r = try render(testing.allocator, th, q, nav, 0, &.{ false, false, false, false }, "", .{}, 80);
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "C1"); // 全量 chip:两个 header 都在
    try capture.expectContains(r.frame, "C2");
    try testing.expect(std.mem.indexOf(u8, r.frame, "(2/2)") == null); // 没退紧凑
}


test "render: 多问导航条 ←  chip  ✔ Submit  →(当前问高亮)" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{ mkOpt("Red", ""), mkOpt("Blue", "") };
    const q = ctx.AskQuestion{ .question = "Color?", .header = "Color", .multi = false, .options = &opts };
    const headers = [_][]const u8{ "Color", "Size" };
    const answered = [_]bool{ false, false };
    const nav = NavInfo{ .headers = &headers, .answered = &answered, .current = 0 };
    const r = try render(testing.allocator, th, q, nav, 0, &.{ false, false, false, false }, "", .{}, 80);
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "<"); // ← (mono 降级 <)
    try capture.expectContains(r.frame, "Color");
    try capture.expectContains(r.frame, "Size");
    try capture.expectContains(r.frame, "Submit");
    try capture.expectContains(r.frame, ">"); // → (mono 降级 >)
}

test "render: 导航条已答问题 chip 为 ☒/[x]" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{ mkOpt("a", ""), mkOpt("b", "") };
    const q = ctx.AskQuestion{ .question = "q", .header = "Q2", .multi = false, .options = &opts };
    const headers = [_][]const u8{ "Q1", "Q2" };
    const answered = [_]bool{ true, false }; // Q1 已答
    const nav = NavInfo{ .headers = &headers, .answered = &answered, .current = 1 };
    const r = try render(testing.allocator, th, q, nav, 0, &.{ false, false, false, false }, "", .{}, 80);
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "[x] Q1"); // 已答
    try capture.expectContains(r.frame, "[ ] Q2"); // 未答
}

test "renderSubmit: Review/警告/Submit-Cancel" {
    const th = theme_mod.monochrome;
    const headers = [_][]const u8{ "Color", "Size" };
    const answered = [_]bool{ true, false };
    const nav = NavInfo{ .headers = &headers, .answered = &answered, .current = 2 };
    const r = try renderSubmit(testing.allocator, th, nav, false, 0, 80);
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "Review your answers");
    try capture.expectContains(r.frame, "You have not answered all questions"); // 有未答警告
    try capture.expectContains(r.frame, "Ready to submit your answers?");
    try capture.expectContains(r.frame, "1. Submit answers");
    try capture.expectContains(r.frame, "2. Cancel");
}

test "renderSubmit: 全答完无警告" {
    const th = theme_mod.monochrome;
    const headers = [_][]const u8{"A"};
    const answered = [_]bool{true};
    const nav = NavInfo{ .headers = &headers, .answered = &answered, .current = 1 };
    const r = try renderSubmit(testing.allocator, th, nav, true, 0, 80);
    defer testing.allocator.free(r.frame);
    try testing.expect(std.mem.indexOf(u8, r.frame, "have not answered") == null); // 无警告
}

test "render: preview side-by-side(选中项有 preview → 右侧框 + notes 提示)" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{
        .{ .label = "Option A", .description = "", .preview = "+----+\n|mock|\n+----+" },
        .{ .label = "Option B", .description = "", .preview = "different" },
    };
    const q = ctx.AskQuestion{ .question = "Which layout?", .header = "Layout", .multi = false, .options = &opts };
    const r = try render(testing.allocator, th, q, null, 0, &.{ false, false, false, false }, "", .{}, 100);
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "Option A");
    try capture.expectContains(r.frame, "+----+"); // preview 内容(mono box content)
    try capture.expectContains(r.frame, "mock");
    try capture.expectContains(r.frame, "n to add notes"); // preview 模式提示
}

test "render: preview 超 6 行折叠 N lines hidden" {
    const th = theme_mod.monochrome;
    var pv: std.ArrayList(u8) = .empty;
    defer pv.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 10) : (i += 1) try pv.print(testing.allocator, "line{d}\n", .{i});
    const opts = [_]ctx.AskOption{
        .{ .label = "A", .description = "", .preview = pv.items },
        .{ .label = "B", .description = "", .preview = "x" },
    };
    const q = ctx.AskQuestion{ .question = "q", .header = "H", .multi = false, .options = &opts };
    const r = try render(testing.allocator, th, q, null, 0, &.{ false, false, false, false }, "", .{}, 100);
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "lines hidden"); // 折叠
}

test "render: 多选不显 preview(preview 仅单选)" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{
        .{ .label = "A", .description = "", .preview = "SHOULD_NOT_SHOW" },
        .{ .label = "B", .description = "", .preview = "" },
    };
    const q = ctx.AskQuestion{ .question = "q", .header = "H", .multi = true, .options = &opts };
    const r = try render(testing.allocator, th, q, null, 0, &.{ false, false, false, false }, "", .{}, 100);
    defer testing.allocator.free(r.frame);
    try testing.expect(std.mem.indexOf(u8, r.frame, "SHOULD_NOT_SHOW") == null); // 多选不渲染 preview
}

test "run: 单问 enter 后正常结束(回归:advanceView 推过末尾不越界 questions[view])" {
    // 真 tty 实测崩点:单问选完 enter → advanceView 设 view=nq=1 → 旧代码 questions[1] OOB。
    // 修复:loop 顶 !multi_q and view>=nq → finalize 返回。用管道喂 enter 验证不崩 + 返回答案。
    const a = std.testing.allocator;
    var pipefd: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipefd) != 0) return error.PipeFailed;
    defer _ = std.c.close(pipefd[0]);
    // 预写一个 '\r'(enter)到管道,run 读到即选中首项并结束。
    _ = std.c.write(pipefd[1], "\r", 1);
    _ = std.c.close(pipefd[1]);

    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{ mkOpt("Red", ""), mkOpt("Blue", "") };
    const q = ctx.AskQuestion{ .question = "Color?", .header = "C", .multi = false, .options = &opts };
    var answers: std.ArrayList([]const u8) = .empty;
    defer {
        for (answers.items) |it| a.free(@constCast(it));
        answers.deinit(a);
    }
    // out_fd 走 fd2;in_fd 用管道读端。run 内部 writeAll 到 fd2(测试时可见但无碍)。
    try run(a, th, pipefd[0], &.{q}, &answers, 80);
    try testing.expectEqual(@as(usize, 1), answers.items.len);
    try testing.expectEqualStrings("Red", answers.items[0]); // 首项默认选中
}

test "run: 重画前 clear-to-end-of-screen 抹旧帧足迹(回归:残字乱码 + 多余输入框)" {
    // 真 tty 实测 bug:redraw 只 cursor.up + \r 不擦 → 旧帧残字漏出(`Esc to cancelt in Vim`)
    // + 旧 REPL 输入框/分隔线残影(看似"多一个输入框")。修:回顶后 ESC[0J 抹整帧足迹。
    // 验证:喂 ↓ 触发一次重画 → 截获 fd2 输出含 \x1b[0J(且只在第 2 帧起出现)。
    const a = std.testing.allocator;

    // 输入管道:只喂 ↓(ESC [ B)→ 触发一次重画(第 2 帧)→ 随后 EOF 使 run 返回 abort。
    // 单 keystroke 单 read,避免管道把 ↓ 与 enter 合并进一次 read(丢字节)的不确定性。
    var inpipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&inpipe) != 0) return error.PipeFailed;
    defer _ = std.c.close(inpipe[0]);
    _ = std.c.write(inpipe[1], "\x1b[B", 3);
    _ = std.c.close(inpipe[1]);

    // 把 fd2 临时 dup 到捕获管道(run 内部硬编码写 fd2)。
    var outpipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&outpipe) != 0) return error.PipeFailed;
    const saved_fd2 = std.c.dup(2);
    defer _ = std.c.close(saved_fd2);
    _ = std.c.dup2(outpipe[1], 2);
    _ = std.c.close(outpipe[1]);

    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{ mkOpt("Red", ""), mkOpt("Blue", "") };
    const q = ctx.AskQuestion{ .question = "Color?", .header = "C", .multi = false, .options = &opts };
    var answers: std.ArrayList([]const u8) = .empty;
    defer {
        for (answers.items) |it| a.free(@constCast(it));
        answers.deinit(a);
    }
    run(a, th, inpipe[0], &.{q}, &answers, 80) catch {};

    // 恢复 fd2,再读捕获内容(顺序:先恢复避免后续测试输出进捕获管道)。
    _ = std.c.dup2(saved_fd2, 2);
    var cap: [8192]u8 = undefined;
    const n = std.c.read(outpipe[0], &cap, cap.len);
    _ = std.c.close(outpipe[0]);
    try testing.expect(n > 0);
    const captured = cap[0..@intCast(n)];
    // ↓ 触发第 2 帧重画,其前应有 clear-to-end-of-screen 抹旧帧足迹。
    try testing.expect(std.mem.indexOf(u8, captured, "\x1b[0J") != null);
}

test "render: preview 默认显 Notes: press n to add notes" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{
        .{ .label = "A", .description = "", .preview = "mockup" },
        .{ .label = "B", .description = "", .preview = "other" },
    };
    const q = ctx.AskQuestion{ .question = "Which?", .header = "L", .multi = false, .options = &opts };
    const r = try render(testing.allocator, th, q, null, 0, &.{ false, false, false, false }, "", .{}, 100);
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "Notes: press n to add notes");
}

// ── 复现:真 tty 实测两 bug(模拟 tty,2026-06-07)。────────────────────────
// bug1:选 Other(Type something)→ 无任何输入焦点视觉,用户不知能打字。
// bug2:选 Chat about this + enter → 当普通 label 返回(应=取消问答转自由回复,对齐 cc onRespondToClaude)。

test "render(repro→fix): Other 选中显输入光标 + 输入态提示行(bug1)" {
    const th = theme_mod.dark; // unicode 主题:光标块 ▏(mono 降级 "_" 易误匹配,故测 unicode 路径)
    const opts = [_]ctx.AskOption{ mkOpt("Yes", "正确"), mkOpt("No", "不对") };
    const q = ctx.AskQuestion{ .question = "分类正确吗?", .header = "C", .multi = false, .options = &opts };
    // selected=2 = Other 项,未输入。
    const r = try render(testing.allocator, th, q, null, 2, &.{ false, false, false, false }, "", .{}, 80);
    defer testing.allocator.free(r.frame);
    // 修复后:Other 选中且空 → 显占位 + 可见光标块(CURSOR_BLOCK),提示行强调打字。
    try capture.expectContains(r.frame, OTHER_LABEL); // 占位仍在
    try capture.expectContains(r.frame, CURSOR_BLOCK); // ★ 输入光标(bug1 修复点)
    try capture.expectContains(r.frame, "Type your answer"); // ★ 输入态提示行(bug1 修复点)
}

test "run(repro→fix): Chat about this 选中 enter → 转自由回复哨兵(bug2)" {
    // 修复后:Chat 项 commit 返回哨兵 CHAT_SENTINEL(上层 ask_user 识别→不当答案塞模型)。
    // 直接验 commitQuestion 纯逻辑(选 chat→哨兵);run 路径的"按4+enter"管道时序不稳,留 tty e2e。
    const a = std.testing.allocator;
    const opts = [_]ctx.AskOption{ mkOpt("Yes", ""), mkOpt("No", "") };
    const q = ctx.AskQuestion{ .question = "q?", .header = "C", .multi = false, .options = &opts };
    const real_n = opts.len; // 2
    const other_idx = real_n; // 2
    const chat_idx = real_n + 1; // 3
    var st = QState{ .selected = chat_idx }; // 焦点在 Chat about this
    try commitQuestion(a, q, &st, chat_idx, other_idx, real_n);
    defer if (st.answer) |ans| a.free(ans);
    try testing.expect(st.answered);
    try testing.expectEqualStrings(CHAT_SENTINEL, st.answer.?); // ★ 哨兵而非字面 "Chat about this"
}

test "render: note 编辑态显 placeholder + 提示行变 ctrl+g" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{
        .{ .label = "A", .description = "", .preview = "mockup" },
        .{ .label = "B", .description = "", .preview = "other" },
    };
    const q = ctx.AskQuestion{ .question = "Which?", .header = "L", .multi = false, .options = &opts };
    const r = try render(testing.allocator, th, q, null, 0, &.{ false, false, false, false }, "", .{ .text = "", .editing = true }, 100);
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "Add notes on this design…"); // placeholder
    try capture.expectContains(r.frame, "ctrl+g to edit in Vim · Esc to cancel"); // note 编辑态提示行
    // 底部提示行(最后一行)不再是普通的 "Enter to select..."(实录:编辑态提示行只剩 ctrl+g)。
    const last_nl = std.mem.lastIndexOfScalar(u8, r.frame, '\n') orelse 0;
    try testing.expect(std.mem.indexOf(u8, r.frame[last_nl..], "Enter to select") == null);
}

test "render: note 已输入显文本(非编辑态 → Notes: <text>)" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{
        .{ .label = "A", .description = "", .preview = "mockup" },
        .{ .label = "B", .description = "", .preview = "other" },
    };
    const q = ctx.AskQuestion{ .question = "Which?", .header = "L", .multi = false, .options = &opts };
    const r = try render(testing.allocator, th, q, null, 0, &.{ false, false, false, false }, "", .{ .text = "my note", .editing = false }, 100);
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "Notes: ");
    try capture.expectContains(r.frame, "my note");
}
