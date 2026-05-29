//! 工具调用卡片(TUI_COMPONENTS.md §5.2)。
//!
//! 渲染形态:
//!   ⚙ Bash                                        ✓ 0.4s
//!     $ git status
//!     ─────────────────────────────────────────────
//!     On branch master
//!     nothing to commit, working tree clean
//!
//! 状态分三相:
//! - renderStart:打 "⚙ tool_name" + 命令预览(运行中,无状态符)
//! - renderProgress:替换状态符为 spinner + 耗时(可选,流式更新)
//! - renderResult:替换状态符为 ✓/✗ + 耗时 + 输出(可折叠,default 5 行)
//!
//! 命令预览(`$ git status` 那行)按工具分类生成:
//!   Bash      → "$ {command}"
//!   Read      → "📄 {path}"  (mono: "R {path}")
//!   Edit/Write → "± {path}" (mono: "E {path}")
//!   其它      → "" (省略)

const std = @import("std");
const theme_mod = @import("../theme.zig");
const layout = @import("../layout.zig");
const term = @import("../term.zig");
const Theme = theme_mod.Theme;

pub const RenderOpts = struct {
    /// 输出最多显示几行(超出折叠 + "… N more lines")
    max_output_lines: u16 = 5,
    /// 是否启用折叠(false = 全部显示)
    collapsed: bool = true,
    /// 终端宽度(决定状态右对齐位置;0 = 不右对齐)
    cols: u16 = 0,
};

pub const ResultKind = enum { ok, err };

/// 工具开始(无状态符,只有 ⚙ tool_name + 命令预览)。caller free。
pub fn renderStart(alloc: std.mem.Allocator, th: Theme, tool_name: []const u8, preview_args: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // 第 1 行:⚙ tool_name
    try out.appendSlice(alloc, th.role_tool);
    try out.appendSlice(alloc, th.icon_tool);
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, tool_name);
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');

    // 第 2 行:命令预览(缩进 2 空格 + dim)
    const preview = try toolPreview(alloc, tool_name, preview_args);
    defer alloc.free(preview);
    if (preview.len > 0) {
        try out.appendSlice(alloc, "  ");
        try out.appendSlice(alloc, th.dim);
        try out.appendSlice(alloc, preview);
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
    }

    return try out.toOwnedSlice(alloc);
}

/// 工具进度(同 renderStart + 右上角带耗时)。caller free。
pub fn renderProgress(alloc: std.mem.Allocator, th: Theme, tool_name: []const u8, preview_args: []const u8, elapsed_ms: u64, opts: RenderOpts) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // 第 1 行:⚙ tool_name + (耗时 spinner)
    try out.appendSlice(alloc, th.role_tool);
    try out.appendSlice(alloc, th.icon_tool);
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, tool_name);
    try out.appendSlice(alloc, th.reset);

    // 右上角:spinner + 耗时
    var stat_buf: [64]u8 = undefined;
    const stat = try std.fmt.bufPrint(&stat_buf, "{s}… {d:.1}s{s}", .{ th.warn, @as(f64, @floatFromInt(elapsed_ms)) / 1000.0, th.reset });
    if (opts.cols > 0) {
        const left_w = term.displayWidth(th.icon_tool) + 1 + term.displayWidth(tool_name);
        // 状态文本的可视宽度:"… X.Ys"
        var vw: [32]u8 = undefined;
        const stat_vis = std.fmt.bufPrint(&vw, "… {d:.1}s", .{@as(f64, @floatFromInt(elapsed_ms)) / 1000.0}) catch "";
        const stat_w = term.displayWidth(stat_vis);
        if (opts.cols > left_w + stat_w + 1) {
            const pad = opts.cols - left_w - stat_w;
            var p: usize = 0;
            while (p < pad) : (p += 1) try out.append(alloc, ' ');
        } else {
            try out.append(alloc, ' ');
        }
    } else {
        try out.append(alloc, ' ');
    }
    try out.appendSlice(alloc, stat);
    try out.append(alloc, '\n');

    // 第 2 行:命令预览
    const preview = try toolPreview(alloc, tool_name, preview_args);
    defer alloc.free(preview);
    if (preview.len > 0) {
        try out.appendSlice(alloc, "  ");
        try out.appendSlice(alloc, th.dim);
        try out.appendSlice(alloc, preview);
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
    }

    return try out.toOwnedSlice(alloc);
}

/// 工具完成(头 + 状态符 + 命令预览 + 分隔线 + 折叠输出)。caller free。
pub fn renderResult(
    alloc: std.mem.Allocator,
    th: Theme,
    tool_name: []const u8,
    preview_args: []const u8,
    output_text: []const u8,
    kind: ResultKind,
    elapsed_ms: u64,
    opts: RenderOpts,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // 第 1 行:⚙ tool_name + ✓/✗ X.Ys
    try out.appendSlice(alloc, th.role_tool);
    try out.appendSlice(alloc, th.icon_tool);
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, tool_name);
    try out.appendSlice(alloc, th.reset);

    // 右上角:状态符 + 耗时
    const status_color = if (kind == .ok) th.success else th.danger;
    const status_icon = if (kind == .ok) th.icon_check else th.icon_cross;
    var stat_buf: [64]u8 = undefined;
    const stat_inner = try std.fmt.bufPrint(&stat_buf, "{s} {d:.1}s", .{ status_icon, @as(f64, @floatFromInt(elapsed_ms)) / 1000.0 });
    if (opts.cols > 0) {
        const left_w = term.displayWidth(th.icon_tool) + 1 + term.displayWidth(tool_name);
        const stat_w = term.displayWidth(stat_inner);
        if (opts.cols > left_w + stat_w + 1) {
            const pad = opts.cols - left_w - stat_w;
            var p: usize = 0;
            while (p < pad) : (p += 1) try out.append(alloc, ' ');
        } else {
            try out.append(alloc, ' ');
        }
    } else {
        try out.append(alloc, ' ');
    }
    try out.appendSlice(alloc, status_color);
    try out.appendSlice(alloc, stat_inner);
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');

    // 第 2 行:命令预览
    const preview = try toolPreview(alloc, tool_name, preview_args);
    defer alloc.free(preview);
    if (preview.len > 0) {
        try out.appendSlice(alloc, "  ");
        try out.appendSlice(alloc, th.dim);
        try out.appendSlice(alloc, preview);
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
    }

    // 分隔线 + 折叠输出
    if (output_text.len > 0) {
        // 分隔线(缩进 2,长度 ~ 48 列)
        try out.appendSlice(alloc, "  ");
        try out.appendSlice(alloc, th.dim);
        var i: usize = 0;
        while (i < 48) : (i += 1) try out.appendSlice(alloc, th.box_h);
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');

        // 输出行(缩进 2,折叠到 max_output_lines)
        var line_count: u16 = 0;
        var total_lines: u16 = 0;
        var pos: usize = 0;
        while (pos < output_text.len) {
            const eol = std.mem.indexOfScalarPos(u8, output_text, pos, '\n') orelse output_text.len;
            total_lines += 1;
            if (opts.collapsed and line_count >= opts.max_output_lines) {
                // 跳过,但继续算 total_lines
            } else {
                try out.appendSlice(alloc, "  ");
                try out.appendSlice(alloc, output_text[pos..eol]);
                try out.append(alloc, '\n');
                line_count += 1;
            }
            pos = eol + 1;
        }

        if (opts.collapsed and total_lines > opts.max_output_lines) {
            try out.appendSlice(alloc, "  ");
            try out.appendSlice(alloc, th.dim);
            try out.print(alloc, "… {d} more lines", .{total_lines - opts.max_output_lines});
            try out.appendSlice(alloc, th.reset);
            try out.append(alloc, '\n');
        }
    }

    return try out.toOwnedSlice(alloc);
}

// ============================================================================
// 命令预览构造
// ============================================================================

/// 根据工具名和参数 JSON 生成单行预览("$ cmd" / "📄 path" / 等)。caller free。
/// 不识别的工具 → 返回空 slice(预览行省略)。
fn toolPreview(alloc: std.mem.Allocator, tool_name: []const u8, args: []const u8) ![]u8 {
    if (std.mem.eql(u8, tool_name, "Bash")) {
        if (extractField(args, "command")) |cmd| {
            return try std.fmt.allocPrint(alloc, "$ {s}", .{cmd});
        }
    } else if (std.mem.eql(u8, tool_name, "Read")) {
        if (extractField(args, "file_path") orelse extractField(args, "path")) |p| {
            return try std.fmt.allocPrint(alloc, "📄 {s}", .{p});
        }
    } else if (std.mem.eql(u8, tool_name, "Edit") or std.mem.eql(u8, tool_name, "Write") or std.mem.eql(u8, tool_name, "NotebookEdit")) {
        if (extractField(args, "file_path") orelse extractField(args, "path")) |p| {
            return try std.fmt.allocPrint(alloc, "± {s}", .{p});
        }
    } else if (std.mem.eql(u8, tool_name, "Grep") or std.mem.eql(u8, tool_name, "Glob")) {
        if (extractField(args, "pattern")) |p| {
            return try std.fmt.allocPrint(alloc, "/{s}/", .{p});
        }
    } else if (std.mem.eql(u8, tool_name, "WebFetch")) {
        if (extractField(args, "url")) |u| {
            return try std.fmt.allocPrint(alloc, "↗ {s}", .{u});
        }
    }
    return try alloc.dupe(u8, "");
}

/// 极简 JSON 顶层 string 字段提取(unescape 不做,只为预览)。
fn extractField(args: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [64]u8 = undefined;
    if (key.len + 4 > pat_buf.len) return null;
    pat_buf[0] = '"';
    @memcpy(pat_buf[1..][0..key.len], key);
    pat_buf[1 + key.len] = '"';
    pat_buf[2 + key.len] = ':';
    const pat = pat_buf[0 .. 3 + key.len];
    const idx = std.mem.indexOf(u8, args, pat) orelse return null;
    var p = idx + pat.len;
    while (p < args.len and (args[p] == ' ' or args[p] == '\t')) : (p += 1) {}
    if (p >= args.len or args[p] != '"') return null;
    p += 1;
    const start = p;
    while (p < args.len) : (p += 1) {
        if (args[p] == '\\') {
            p += 1;
            continue;
        }
        if (args[p] == '"') return args[start..p];
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const capture = @import("../test_capture.zig");

test "renderStart: Bash 工具" {
    const th = theme_mod.monochrome;
    const s = try renderStart(testing.allocator, th, "Bash", "{\"command\":\"git status\"}");
    defer testing.allocator.free(s);
    try capture.expectContains(s, "* Bash"); // monochrome icon_tool="*"
    try capture.expectContains(s, "$ git status");
    try capture.expectNoAnsi(s);
}

test "renderStart: Read 工具用 📄 预览" {
    const th = theme_mod.dark;
    const s = try renderStart(testing.allocator, th, "Read", "{\"file_path\":\"/etc/hosts\"}");
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Read");
    try capture.expectContains(s, "📄 /etc/hosts");
}

test "renderStart: Edit 用 ± 预览" {
    const th = theme_mod.monochrome;
    const s = try renderStart(testing.allocator, th, "Edit", "{\"file_path\":\"/x.zig\",\"old_string\":\"a\",\"new_string\":\"b\"}");
    defer testing.allocator.free(s);
    try capture.expectContains(s, "± /x.zig");
}

test "renderResult: ok + ✓ + 耗时" {
    const th = theme_mod.monochrome;
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"ls\"}", "file.txt\n", .ok, 1500, .{});
    defer testing.allocator.free(s);
    try capture.expectContains(s, "+ 1.5s"); // monochrome icon_check="+"
    try capture.expectContains(s, "file.txt");
}

test "renderResult: err + ✗" {
    const th = theme_mod.monochrome;
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"false\"}", "exit 1\n", .err, 200, .{});
    defer testing.allocator.free(s);
    try capture.expectContains(s, "X 0.2s"); // monochrome icon_cross="X"
    try capture.expectContains(s, "exit 1");
}

test "renderResult: 折叠超长输出" {
    const th = theme_mod.monochrome;
    const long =
        "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n";
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"seq 10\"}", long, .ok, 100, .{ .max_output_lines = 5 });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "line1");
    try capture.expectContains(s, "line5");
    try capture.expectContains(s, "… 5 more lines");
    // line6 应该被折叠
    try testing.expect(std.mem.indexOf(u8, s, "line6") == null);
}

test "renderResult: collapsed=false 全部显示" {
    const th = theme_mod.monochrome;
    const long = "a\nb\nc\nd\ne\nf\ng\n";
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"x\"}", long, .ok, 100, .{ .collapsed = false, .max_output_lines = 3 });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "g");
    try testing.expect(std.mem.indexOf(u8, s, "more lines") == null);
}

test "renderResult: cols 右对齐状态符" {
    const th = theme_mod.monochrome;
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"x\"}", "", .ok, 100, .{ .cols = 60 });
    defer testing.allocator.free(s);
    // 在 60 列宽下应有 padding 把 "+ 0.1s" 推到右边
    try capture.expectContains(s, "+ 0.1s");
}

test "extractField: 简单提取" {
    try testing.expectEqualStrings("git status", extractField("{\"command\":\"git status\"}", "command").?);
    try testing.expectEqualStrings("/x", extractField("{\"file_path\":\"/x\",\"other\":1}", "file_path").?);
    try testing.expect(extractField("{}", "command") == null);
}

test "renderProgress: 显示 spinner + 耗时" {
    const th = theme_mod.monochrome;
    const s = try renderProgress(testing.allocator, th, "Bash", "{\"command\":\"sleep 5\"}", 2300, .{});
    defer testing.allocator.free(s);
    try capture.expectContains(s, "… 2.3s");
    try capture.expectContains(s, "$ sleep 5");
}

test "VISUAL demo: tool_card(TUI_DEMO=1)" {
    if (std.c.getenv("TUI_DEMO") == null) return error.SkipZigTest;
    const th = theme_mod.dark;
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"git status\"}",
        "On branch master\nnothing to commit, working tree clean\n",
        .ok, 423, .{ .cols = 60 });
    defer testing.allocator.free(s);
    std.debug.print("\n{s}\n", .{s});
}
