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
const theme_mod = @import("../theme.zig");
const layout = @import("../layout.zig");
const term = @import("../term.zig");
const ctx = @import("../../../tools/context.zig");
const Theme = theme_mod.Theme;

const MAX_DESC_PREVIEW = 60;

pub const Rendered = struct {
    frame: []u8, // owned,caller free
    rows: usize, // frame 占的终端行数(= frame 内 '\n' 数),run 用它 cursor.up 回顶
};

/// 渲染单个问题为带框对话框。
/// q_index/q_total: 多问题时标题显示 "Question 2/3";单问题(total==1)只显 "Question"。
/// selected: 当前高亮选项 index。
/// checked: 多选勾选状态(len == options.len);单选传全 false(不显 [x])。
/// caller free 返回的 .frame。
pub fn render(
    alloc: std.mem.Allocator,
    th: Theme,
    q: ctx.AskQuestion,
    q_index: usize,
    q_total: usize,
    selected: usize,
    checked: []const bool,
) !Rendered {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);

    // header(短标签,dim) —— 非空才显。
    if (q.header.len > 0) {
        try content.appendSlice(alloc, th.dim);
        try content.appendSlice(alloc, q.header);
        try content.appendSlice(alloc, th.reset);
        try content.append(alloc, '\n');
    }

    // 问题行(accent)。
    try content.appendSlice(alloc, th.accent);
    try content.appendSlice(alloc, q.question);
    try content.appendSlice(alloc, th.reset);
    try content.append(alloc, '\n');
    try content.append(alloc, '\n');

    const arrow_w = term.displayWidth(th.icon_arrow);

    // 选项行。
    for (q.options, 0..) |opt, i| {
        // 前导:高亮项显箭头(accent),否则空格对齐。
        if (i == selected) {
            try content.appendSlice(alloc, th.accent);
            try content.appendSlice(alloc, th.icon_arrow);
            try content.append(alloc, ' ');
        } else {
            var p: usize = 0;
            while (p < arrow_w + 1) : (p += 1) try content.append(alloc, ' ');
        }

        // 多选:[x]/[ ] 复选框。
        if (q.multi) {
            const on = i < checked.len and checked[i];
            try content.print(alloc, "[{s}] ", .{if (on) "x" else " "});
        }

        // label + 可选 description(dim,截断)。
        try content.appendSlice(alloc, opt.label);
        if (opt.description.len > 0) {
            const preview = try layout.truncate(alloc, opt.description, MAX_DESC_PREVIEW, "…");
            defer if (preview.ptr != opt.description.ptr) alloc.free(@constCast(preview));
            try content.appendSlice(alloc, " ");
            try content.appendSlice(alloc, th.dim);
            try content.appendSlice(alloc, "— ");
            try content.appendSlice(alloc, preview);
            try content.appendSlice(alloc, th.reset);
        }
        if (i == selected) try content.appendSlice(alloc, th.reset);
        try content.append(alloc, '\n');
    }

    // 提示行(dim)。
    try content.append(alloc, '\n');
    try content.appendSlice(alloc, th.dim);
    if (q.multi) {
        try content.appendSlice(alloc, "↑↓ move · space toggle · enter confirm · esc cancel");
    } else {
        try content.appendSlice(alloc, "↑↓ select · enter confirm · esc cancel");
    }
    try content.appendSlice(alloc, th.reset);

    // 标题:多问题显进度。
    var title_buf: [32]u8 = undefined;
    const title: []const u8 = if (q_total > 1)
        try std.fmt.bufPrint(&title_buf, "Question {d}/{d}", .{ q_index + 1, q_total })
    else
        "Question";

    const frame = try layout.drawBox(alloc, th, content.items, .{
        .title = title,
        .padding = 1,
    });

    // rows = frame 内换行数。drawBox 每行(含顶/底边)后跟 '\n',末行底边后也有 '\n'(见 layout)。
    // run 据此 cursor.up(rows) 回到对话框上方重画。
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

/// 多问题 wizard 交互循环。调用方(TuiBackend.askQuestion)已:① stopInput(watcher 不抢 fd0);
/// ② enterExclusiveOverlay(持渲染锁 + 擦固定区);③ 终端仍在生成期 raw mode(gen_raw_orig 未 restore)。
/// 故本函数独占 fd0/输出,直接 read/writeAll,**不**碰 raw mode、**不**碰 RenderRegion。
///
/// 逐问交互;每问选定后 append 一条答案到 out(单选=label;多选=勾选 label 用 ", " 拼接,owned by
/// allocator)。任一问 ESC/Ctrl+C → error.InputAborted(取消整个工具,已 append 的答案由 caller 清理)。
pub fn run(
    alloc: std.mem.Allocator,
    th: Theme,
    in_fd: std.c.fd_t,
    questions: []const ctx.AskQuestion,
    out: *std.ArrayList([]const u8),
) !void {
    for (questions, 0..) |q, qi| {
        const ans = try askOne(alloc, th, in_fd, q, qi, questions.len);
        try out.append(alloc, ans);
    }
}

/// 单个问题的读键循环。返回选中 label(s)(owned by alloc)。
fn askOne(
    alloc: std.mem.Allocator,
    th: Theme,
    in_fd: std.c.fd_t,
    q: ctx.AskQuestion,
    q_index: usize,
    q_total: usize,
) ![]const u8 {
    const out_fd: std.c.fd_t = 2; // 与 region 同流(stderr),不污染工具 stdout 的 tool_result。
    var selected: usize = 0;
    // 多选勾选状态(单选不用)。上限充裕(schema 限 2-4 选项)。
    var checked = [_]bool{false} ** 8;
    const nopt = q.options.len;

    var prev_rows: usize = 0;
    while (true) {
        // 回顶重画(首轮 prev_rows=0 不上移)。
        if (prev_rows > 0) {
            var up_buf: [16]u8 = undefined;
            writeAll(out_fd, ansi.cursor.up(@intCast(prev_rows), &up_buf));
            writeAll(out_fd, "\r");
        }
        const r = try render(alloc, th, q, q_index, q_total, selected, checked[0..nopt]);
        defer alloc.free(r.frame);
        writeAll(out_fd, r.frame);
        prev_rows = r.rows;

        var buf: [8]u8 = undefined;
        const n = std.c.read(in_fd, &buf, buf.len);
        if (n <= 0) return error.InputAborted;
        const b = buf[0];

        switch (b) {
            0x03 => return error.InputAborted, // Ctrl+C
            0x1b => {
                // 方向键 ESC[A/B vs 孤立 ESC(取消)。
                if (n >= 3 and buf[1] == '[') {
                    switch (buf[2]) {
                        'A' => selected = if (selected == 0) nopt - 1 else selected - 1,
                        'B' => selected = (selected + 1) % nopt,
                        else => {},
                    }
                    continue;
                }
                return error.InputAborted; // 孤立 ESC
            },
            ' ' => {
                if (q.multi) checked[selected] = !checked[selected];
                continue;
            },
            '\r', '\n' => {
                if (q.multi) {
                    var any = false;
                    for (checked[0..nopt]) |c| {
                        if (c) any = true;
                    }
                    if (!any) continue; // 零勾选 → 忽略 enter,重提示。
                    return try joinChecked(alloc, q.options, checked[0..nopt]);
                }
                return try alloc.dupe(u8, q.options[selected].label);
            },
            '1'...'9' => {
                const idx: usize = b - '1';
                if (idx < nopt) {
                    if (q.multi) {
                        checked[idx] = !checked[idx];
                        selected = idx;
                    } else {
                        return try alloc.dupe(u8, q.options[idx].label);
                    }
                }
                continue;
            },
            else => continue,
        }
    }
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

test "render: monochrome 含 header/question/options/提示行,无 ANSI" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{ mkOpt("apple", "red fruit"), mkOpt("banana", "yellow") };
    const q = ctx.AskQuestion{ .question = "pick one", .header = "Fruit", .multi = false, .options = &opts };
    const r = try render(testing.allocator, th, q, 0, 1, 0, &.{ false, false });
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "Fruit");
    try capture.expectContains(r.frame, "pick one");
    try capture.expectContains(r.frame, "apple");
    try capture.expectContains(r.frame, "banana");
    try capture.expectContains(r.frame, "red fruit");
    try capture.expectContains(r.frame, "enter confirm");
    // mono 无 ANSI 转义。
    try testing.expect(std.mem.indexOf(u8, r.frame, "\x1b") == null);
}

test "render: dark 含 ANSI + 高亮箭头在 selected 项" {
    const th = theme_mod.dark;
    const opts = [_]ctx.AskOption{ mkOpt("a", ""), mkOpt("b", "") };
    const q = ctx.AskQuestion{ .question = "q", .header = "", .multi = false, .options = &opts };
    const r = try render(testing.allocator, th, q, 0, 1, 1, &.{ false, false });
    defer testing.allocator.free(r.frame);
    try testing.expect(std.mem.indexOf(u8, r.frame, "\x1b") != null);
    // 箭头出现(高亮 selected=1)。
    try capture.expectContains(r.frame, th.icon_arrow);
}

test "render: 多选显 [x]/[ ] 复选框" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{ mkOpt("a", ""), mkOpt("b", ""), mkOpt("c", "") };
    const q = ctx.AskQuestion{ .question = "pick many", .header = "", .multi = true, .options = &opts };
    // 勾选第 0 和第 2。
    const r = try render(testing.allocator, th, q, 0, 1, 0, &.{ true, false, true });
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "[x]");
    try capture.expectContains(r.frame, "[ ]");
    try capture.expectContains(r.frame, "space toggle");
}

test "render: 多问题标题显进度 Question 2/3" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{ mkOpt("a", ""), mkOpt("b", "") };
    const q = ctx.AskQuestion{ .question = "q", .header = "", .multi = false, .options = &opts };
    const r = try render(testing.allocator, th, q, 1, 3, 0, &.{ false, false });
    defer testing.allocator.free(r.frame);
    try capture.expectContains(r.frame, "Question 2/3");
}

test "render: rows == frame 内换行数(供回顶)" {
    const th = theme_mod.monochrome;
    const opts = [_]ctx.AskOption{ mkOpt("a", ""), mkOpt("b", "") };
    const q = ctx.AskQuestion{ .question = "q", .header = "H", .multi = false, .options = &opts };
    const r = try render(testing.allocator, th, q, 0, 1, 0, &.{ false, false });
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
