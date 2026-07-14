//! ExitPlanMode 审批对话框(对齐 cc ExitPlanModePermissionRequest)。
//!
//! 模型调 ExitPlanMode 提交计划 → 弹此框让用户 review + 决定:
//! - [1] Yes, proceed                  → 批准,恢复进 plan 前的原模式,模型继续执行
//! - [2] Yes, and auto-accept edits     → 批准并切 accept_edits
//! - [3] No, keep planning              → 留在 plan 模式,模型继续打磨计划
//!
//! 分层(同 permission.zig):
//! - render():纯渲染 → []u8(可 snapshot 测试)
//! - run():render + raw 读键循环(调用方负责终端接管/raw mode)
//!
//! 返回 ToolContext.PlanApproval。

const std = @import("std");
const pfs = @import("platform").fs;
const ansi = @import("../ansi.zig");
const theme_mod = @import("../theme.zig");
const layout = @import("../layout.zig");
const term = @import("../term.zig");
const Theme = theme_mod.Theme;
const PlanApproval = @import("../../../tools/context.zig").ToolContext.PlanApproval;

pub const Option = struct {
    key: u8, // '1' / '2' / '3'
    label: []const u8,
    choice: PlanApproval,
};

pub const options = [_]Option{
    .{ .key = '1', .label = "Yes, proceed", .choice = .approve_default },
    .{ .key = '2', .label = "Yes, and auto-accept edits", .choice = .approve_accept_edits },
    .{ .key = '3', .label = "No, keep planning", .choice = .reject },
};

/// 计划正文最多显示几行(超出折叠提示),防超长计划撑爆终端。
const MAX_PLAN_LINES = 30;
/// 对话框内容区宽度。
const BOX_WIDTH = 72;

/// 渲染审批对话框为字符串。selected = 当前高亮选项 index(0..2)。caller free。
/// plan_md 是计划 markdown(可多行);逐行 dim 显示,超 MAX_PLAN_LINES 折叠。
pub fn render(alloc: std.mem.Allocator, th: Theme, plan_md: []const u8, selected: usize) ![]u8 {
    return renderWithKg(alloc, th, plan_md, selected, 0);
}

/// 带 KG 步骤数的渲染:kg_steps>0 时在提示行前加一行"批准后将存为 N 步持久任务图"。
pub fn renderWithKg(alloc: std.mem.Allocator, th: Theme, plan_md: []const u8, selected: usize, kg_steps: usize) ![]u8 {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);

    // 计划正文:逐行 dim 显示,每行按宽度截断(软折交给 drawBox 的 wrapLines)。
    // 模型未提供计划摘要(plan 可选)→ 给提示,框照常弹(绝不因缺 plan 卡住)。
    const trimmed = std.mem.trim(u8, plan_md, " \t\r\n");
    if (trimmed.len == 0) {
        try content.appendSlice(alloc, th.dim);
        try content.appendSlice(alloc, "(The plan was described above. Ready to start coding?)");
        try content.appendSlice(alloc, th.reset);
        try content.append(alloc, '\n');
    }
    var line_count: usize = 0;
    var total_lines: usize = 0;
    var pos: usize = 0;
    while (pos < plan_md.len) {
        const eol = std.mem.indexOfScalarPos(u8, plan_md, pos, '\n') orelse plan_md.len;
        total_lines += 1;
        if (line_count < MAX_PLAN_LINES) {
            const raw = plan_md[pos..eol];
            // 截断到内容宽(留 drawBox padding 余量),长行不撑破框。
            const trunc = try layout.truncate(alloc, raw, BOX_WIDTH, "…");
            defer if (trunc.ptr != raw.ptr) alloc.free(@constCast(trunc));
            try content.appendSlice(alloc, th.dim);
            try content.appendSlice(alloc, trunc);
            try content.appendSlice(alloc, th.reset);
            try content.append(alloc, '\n');
            line_count += 1;
        }
        pos = eol + 1;
    }
    if (total_lines > MAX_PLAN_LINES) {
        try content.appendSlice(alloc, th.dim);
        try content.print(alloc, "… +{d} more lines", .{total_lines - MAX_PLAN_LINES});
        try content.appendSlice(alloc, th.reset);
        try content.append(alloc, '\n');
    }
    try content.append(alloc, '\n');

    // KG 落图提示(PM P0-1:让用户看见计划将成为持久任务图)。
    if (kg_steps > 0) {
        try content.appendSlice(alloc, th.accent);
        try content.print(alloc, "✓ 批准后将存为 {d} 步持久任务图(跨会话可恢复,用 /kg 查看)", .{kg_steps});
        try content.appendSlice(alloc, th.reset);
        try content.appendSlice(alloc, "\n\n");
    }

    // 提示行。
    try content.appendSlice(alloc, "Would you like to proceed?");
    try content.append(alloc, '\n');

    // 选项行:高亮 selected。
    for (options, 0..) |opt, i| {
        if (i == selected) {
            try content.appendSlice(alloc, th.accent);
            try content.appendSlice(alloc, th.icon_arrow);
            try content.append(alloc, ' ');
        } else {
            const arrow_w = term.displayWidth(th.icon_arrow);
            var p: usize = 0;
            while (p < arrow_w + 1) : (p += 1) try content.append(alloc, ' ');
        }
        try content.print(alloc, "[{c}] {s}", .{ opt.key, opt.label });
        if (i == selected) try content.appendSlice(alloc, th.reset);
        if (i + 1 < options.len) try content.append(alloc, '\n');
    }

    return try layout.drawBox(alloc, th, content.items, .{
        .title = "Ready to code?",
        .width = BOX_WIDTH,
        .padding = 1,
    });
}

/// 渲染 + 读键循环(不管 raw mode / 终端接管——调用方负责)。
/// out_fd:输出 fd(TuiBackend 接管用 stderr=2 与 region 同流)。
/// 默认高亮第 3 项(No, keep planning)——安全默认偏向"不轻易放行"。
/// 返回 null = 读失败(调用方按 .reject 兜底)。
pub fn run(alloc: std.mem.Allocator, th: Theme, in_fd: c_int, out_fd: c_int, plan_md: []const u8) ?PlanApproval {
    return runWithKg(alloc, th, in_fd, out_fd, plan_md, 0);
}

pub fn runWithKg(alloc: std.mem.Allocator, th: Theme, in_fd: c_int, out_fd: c_int, plan_md: []const u8, kg_steps: usize) ?PlanApproval {
    var selected: usize = 0; // 默认高亮第一项(Yes, proceed)——计划已展示,用户主动 review 后多数批准
    var prev_rows: usize = 0;
    while (true) {
        if (prev_rows > 0) {
            var up_buf: [16]u8 = undefined;
            writeAll(out_fd, ansi.cursor.up(@intCast(prev_rows), &up_buf));
            writeAll(out_fd, "\r");
        }
        const frame = renderWithKg(alloc, th, plan_md, selected, kg_steps) catch return .reject;
        defer alloc.free(frame);
        writeAll(out_fd, frame);
        prev_rows = countRows(frame);

        var buf: [8]u8 = undefined;
        const n = pfs.read(in_fd, &buf);
        if (n <= 0) return null;
        const b = buf[0];

        switch (b) {
            '1' => return .approve_default,
            '2' => return .approve_accept_edits,
            '3' => return .reject,
            0x03 => return .reject, // Ctrl+C → 留在 plan
            0x1b => {
                // 裸 ESC(非方向键序列)→ 留在 plan。
                if (n == 1) return .reject;
            },
            '\r', '\n' => return options[selected].choice, // Enter 确认高亮
            else => {},
        }
        // 方向键:ESC [ A/B
        if (b == 0x1b and n >= 3 and buf[1] == '[') {
            switch (buf[2]) {
                'A' => selected = if (selected == 0) options.len - 1 else selected - 1, // up
                'B' => selected = (selected + 1) % options.len, // down
                else => {},
            }
        }
    }
}

/// frame 占的终端行数(= '\n' 数),供 cursor.up 精确回顶。
fn countRows(frame: []const u8) usize {
    var rows: usize = 0;
    for (frame) |c| {
        if (c == '\n') rows += 1;
    }
    return rows;
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    var total: usize = 0;
    while (total < bytes.len) {
        const w = pfs.write(fd, bytes[total..]);
        if (w <= 0) return;
        total += @as(usize, @intCast(w));
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const capture = @import("../test_capture.zig");

test "render: monochrome 含标题/计划正文/三选项/无 ANSI" {
    const th = theme_mod.monochrome;
    const s = try render(testing.allocator, th, "1. Read config\n2. Patch loader", 0);
    defer testing.allocator.free(s);

    try capture.expectContains(s, "Ready to code?");
    try capture.expectContains(s, "Read config"); // 计划正文出现
    try capture.expectContains(s, "Patch loader");
    try capture.expectContains(s, "Would you like to proceed?");
    try capture.expectContains(s, "[1] Yes, proceed");
    try capture.expectContains(s, "[2] Yes, and auto-accept edits");
    try capture.expectContains(s, "[3] No, keep planning");
    try capture.expectNoAnsi(s);
}

test "render: dark 含 ANSI + 高亮箭头" {
    const th = theme_mod.dark;
    const s = try render(testing.allocator, th, "do the thing", 1);
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "\x1b") != null);
    // selected=1 → 第二项前有箭头。
    try testing.expect(std.mem.indexOf(u8, s, th.icon_arrow) != null);
}

test "render: 超长计划折叠 … +N more lines" {
    const th = theme_mod.monochrome;
    var plan: std.ArrayList(u8) = .empty;
    defer plan.deinit(testing.allocator);
    var i: usize = 0;
    while (i < MAX_PLAN_LINES + 5) : (i += 1) try plan.print(testing.allocator, "line {d}\n", .{i});
    const s = try render(testing.allocator, th, plan.items, 0);
    defer testing.allocator.free(s);
    try capture.expectContains(s, "more lines");
}

test "render: 空 plan 给提示不空框(实测 bug:模型把计划写对话文本里)" {
    const th = theme_mod.monochrome;
    const s = try render(testing.allocator, th, "", 0);
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Ready to code?");
    try capture.expectContains(s, "described above"); // 空计划提示
    try capture.expectContains(s, "[1] Yes, proceed"); // 选项照常
}

test "options 键/choice 映射正确" {
    try testing.expectEqual(PlanApproval.approve_default, options[0].choice);
    try testing.expectEqual(PlanApproval.approve_accept_edits, options[1].choice);
    try testing.expectEqual(PlanApproval.reject, options[2].choice);
    try testing.expectEqual(@as(u8, '1'), options[0].key);
}
