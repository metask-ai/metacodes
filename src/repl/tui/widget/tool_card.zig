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
    /// 详细模式(对齐 cc verbose):摘要类工具展开完整内容,折叠阈值放宽。
    verbose: bool = false,
    /// transcript 历史视图(对齐 cc isTranscriptMode):语义同 verbose(展开)。
    transcript: bool = false,
};

pub const ResultKind = enum { ok, err };

/// 结果渲染策略(对齐 cc:renderToolResultMessage 可选 + opt-out)。
/// - hidden:结果**不进消息流**(对齐 cc 返回 null)。Task 系列在 Task 面板反馈、
///   plan mode 是模式切换 —— 它们的结果不该刷屏。renderResult 对这些工具返回空串。
/// - summary:渲染人类可读摘要(专用渲染器)。
/// 关键:**没有"裸 JSON 兜底"**。无专用渲染器又非 summary 的工具默认 hidden,
/// 绝不把工具返回的原始 JSON 原样打到屏幕(对齐 cc"纯文本结果是反模式")。
pub const ResultRenderMode = enum { hidden, summary };

pub fn resultRenderMode(tool_name: []const u8) ResultRenderMode {
    // opt-out:Task 族(状态在 Task 面板)、plan mode(模式切换,无输出)。
    if (std.mem.startsWith(u8, tool_name, "Task")) return .hidden;
    if (std.mem.eql(u8, tool_name, "EnterPlanMode") or std.mem.eql(u8, tool_name, "ExitPlanMode")) return .hidden;
    // 有专用 summary 渲染器的工具。
    // 注:WebSearch 是 Anthropic server tool,结果由 stream.zig:renderWebSearchResults
    // 单独渲染,不走本地 renderResult 路径,故不在此列。
    // 注:NotebookEdit/Skill/ListMcp/ReadMcp 暂无专用渲染器 → 走 hidden(不裸吐 JSON),
    // 后续补 summary 渲染器时再加入本列(对齐 A2)。
    const summary_tools = [_][]const u8{
        "Bash", "BashOutput", "Edit", "Write", "Read", "Grep", "Glob",
        "WebFetch", "Agent",
    };
    for (summary_tools) |t| {
        if (std.mem.eql(u8, tool_name, t)) return .summary;
    }
    // 未知/无渲染器工具:默认 hidden(不吐 JSON)。新工具要显示就显式加渲染器 + summary。
    return .hidden;
}

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

    // opt-out(对齐 cc):成功结果且工具是 hidden 模式 → 整条不显示(返回空串)。
    // Task 族的状态在 Task 面板反馈,不刷消息流。错误(kind=.err)仍显示——用户要知道失败。
    if (kind == .ok and resultRenderMode(tool_name) == .hidden) {
        return try out.toOwnedSlice(alloc); // 空串
    }

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

    // 分隔线 + 按工具分发的输出体
    if (output_text.len > 0) {
        // 分隔线(缩进 2,长度 ~ 48 列)
        try out.appendSlice(alloc, "  ");
        try out.appendSlice(alloc, th.dim);
        var i: usize = 0;
        while (i < 48) : (i += 1) try out.appendSlice(alloc, th.box_h);
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');

        // 按工具名分发到专用渲染器;未命中走通用折叠。
        try renderResultBody(alloc, th, tool_name, output_text, &out, opts, kind);
    }

    return try out.toOwnedSlice(alloc);
}

/// 按工具名分发结果体渲染。专用渲染器(Edit diff / 搜索摘要 / Read 摘要 / WebFetch 摘要)
/// 各自决定折叠/着色;未命中工具走 renderGenericFold(现有逐行折叠,Bash 等用)。
fn renderResultBody(
    alloc: std.mem.Allocator,
    th: Theme,
    tool_name: []const u8,
    output_text: []const u8,
    out: *std.ArrayList(u8),
    opts: RenderOpts,
    kind: ResultKind,
) !void {
    if (kind == .err) {
        return renderErrorBody(alloc, th, output_text, out, opts);
    }
    if (std.mem.eql(u8, tool_name, "Edit") or std.mem.eql(u8, tool_name, "Write")) {
        return renderEditDiff(alloc, th, output_text, out, opts);
    }
    if (std.mem.eql(u8, tool_name, "Grep") or std.mem.eql(u8, tool_name, "Glob")) {
        return renderSearchSummary(alloc, th, output_text, out, opts);
    }
    if (std.mem.eql(u8, tool_name, "Read")) {
        return renderReadSummary(alloc, th, output_text, out, opts);
    }
    if (std.mem.eql(u8, tool_name, "WebFetch")) {
        return renderWebFetchSummary(alloc, th, output_text, out, opts);
    }
    if (std.mem.eql(u8, tool_name, "Bash") or std.mem.eql(u8, tool_name, "BashOutput")) {
        return renderBashResult(alloc, th, output_text, out, opts);
    }
    if (std.mem.startsWith(u8, tool_name, "Task") or std.mem.eql(u8, tool_name, "Agent")) {
        return renderTaskResult(alloc, th, tool_name, output_text, out, opts);
    }
    return renderGenericFold(alloc, th, output_text, out, opts);
}

/// 错误结果友好渲染:从结构化错误里提取人话(detail→message),红色显示;
/// 提不到但内容是 JSON(`{`/`[` 开头)→ 显示一行通用错误标记,**绝不裸吐 error JSON**;
/// 内容是纯文本 → unescape 后折叠。对齐 cc FallbackToolUseErrorMessage。
fn renderErrorBody(alloc: std.mem.Allocator, th: Theme, output_text: []const u8, out: *std.ArrayList(u8), opts: RenderOpts) !void {
    // 1) 结构化错误:优先 detail,退而求其次 message。空串视为提不到。
    const human: ?[]const u8 = blk: {
        if (extractField(output_text, "detail")) |d| {
            if (d.len > 0) break :blk d;
        }
        if (extractField(output_text, "message")) |m| {
            if (m.len > 0) break :blk m;
        }
        break :blk null;
    };
    if (human) |text| {
        const dec = try jsonUnescape(alloc, text);
        defer alloc.free(dec);
        try appendLine(alloc, out, th.danger, dec, th.reset);
        return;
    }

    // 2) 提不到人话但内容像 JSON(`{` 或 `[` 开头)→ 不裸吐,显示通用标记。
    const trimmed = std.mem.trim(u8, output_text, " \t\r\n");
    if (trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[')) {
        try appendLine(alloc, out, th.danger, "[tool error]", th.reset);
        return;
    }

    // 3) 纯文本错误:unescape 后折叠(genericFold 已 unescape-safe)。
    const dec = try jsonUnescape(alloc, output_text);
    defer alloc.free(dec);
    return renderGenericFold(alloc, th, dec, out, opts);
}

/// 通用逐行折叠(原 renderResult 的输出体逻辑)。Bash 等无专用渲染器的工具用。
fn renderGenericFold(alloc: std.mem.Allocator, th: Theme, output_text: []const u8, out: *std.ArrayList(u8), opts: RenderOpts) !void {
    const limit: u16 = if (opts.verbose or opts.transcript) std.math.maxInt(u16) else opts.max_output_lines;
    var line_count: u16 = 0;
    var total_lines: u16 = 0;
    var pos: usize = 0;
    while (pos < output_text.len) {
        const eol = std.mem.indexOfScalarPos(u8, output_text, pos, '\n') orelse output_text.len;
        total_lines += 1;
        if (opts.collapsed and line_count >= limit) {
            // 跳过,但继续算 total_lines
        } else {
            try out.appendSlice(alloc, "  ");
            try out.appendSlice(alloc, output_text[pos..eol]);
            try out.append(alloc, '\n');
            line_count += 1;
        }
        pos = eol + 1;
    }

    if (opts.collapsed and total_lines > limit) {
        try out.appendSlice(alloc, "  ");
        try out.appendSlice(alloc, th.dim);
        try out.print(alloc, "… {d} more lines", .{total_lines - limit});
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
    }
}

/// 一行普通文本(2 空格缩进 + 可选颜色)。
fn appendLine(alloc: std.mem.Allocator, out: *std.ArrayList(u8), color: []const u8, text: []const u8, reset: []const u8) !void {
    try out.appendSlice(alloc, "  ");
    if (color.len > 0) try out.appendSlice(alloc, color);
    try out.appendSlice(alloc, text);
    if (color.len > 0) try out.appendSlice(alloc, reset);
    try out.append(alloc, '\n');
}

/// Bash 结果:从结果 JSON 提取 stdout/stderr/exit_code,**unescape 后**显示真实多行输出,
/// 而非裸 JSON。对齐 cc BashToolResultMessage(渲染 stdout 文本本身,不含 JSON 包装)。
fn renderBashResult(alloc: std.mem.Allocator, th: Theme, output_text: []const u8, out: *std.ArrayList(u8), opts: RenderOpts) !void {
    // 后台 Bash:{"job_id":..,"status":"started",...} → 一行提示,不展开。
    if (extractField(output_text, "job_id")) |jid| {
        if (extractField(output_text, "status") != null) {
            const line = try std.fmt.allocPrint(alloc, "▶ background job {s}", .{jid});
            defer alloc.free(line);
            try appendLine(alloc, out, th.dim, line, th.reset);
            return;
        }
    }

    const stdout_raw = extractField(output_text, "stdout");
    const stderr_raw = extractField(output_text, "stderr");
    const exit_raw = extractField(output_text, "exit_code"); // 数字字段:extractField 只取 string,见下

    // 容错:若 output 不像 Bash 结果 JSON(无 stdout 字段且无 exit_code 数字),按纯文本走
    // 通用折叠——不强行套 "(no output)"(单测/历史可能直接喂纯文本)。
    if (stdout_raw == null and extractNumberField(output_text, "exit_code") == null) {
        return renderGenericFold(alloc, th, output_text, out, opts);
    }

    // stdout:unescape 后逐行折叠(复用 renderGenericFold)。
    var printed_any = false;
    if (stdout_raw) |so| {
        if (so.len > 0) {
            const dec = try jsonUnescape(alloc, so);
            defer alloc.free(dec);
            const trimmed = std.mem.trim(u8, dec, "\n");
            if (trimmed.len > 0) {
                try renderGenericFold(alloc, th, trimmed, out, opts);
                printed_any = true;
            }
        }
    }
    // stderr:非空则摘要(dim/红前缀几行)。
    if (stderr_raw) |se| {
        if (se.len > 0) {
            const dec = try jsonUnescape(alloc, se);
            defer alloc.free(dec);
            const trimmed = std.mem.trim(u8, dec, "\n");
            if (trimmed.len > 0) {
                try appendLine(alloc, out, th.dim, "stderr:", th.reset);
                try renderGenericFold(alloc, th, trimmed, out, opts);
                printed_any = true;
            }
        }
    }
    // exit_code != 0 → 红色 exit N。exit_code 是数字,extractField(只取 string)拿不到,
    // 用专门的数字提取。
    if (extractNumberField(output_text, "exit_code")) |code| {
        if (code != 0) {
            const line = try std.fmt.allocPrint(alloc, "exit {d}", .{code});
            defer alloc.free(line);
            try appendLine(alloc, out, th.danger, line, th.reset);
            printed_any = true;
        }
    }
    _ = exit_raw;

    if (!printed_any) {
        try appendLine(alloc, out, th.dim, "(no output)", th.reset);
    }
}

/// Task 系列结果:不显示裸 JSON,显示人类可读摘要。
fn renderTaskResult(alloc: std.mem.Allocator, th: Theme, tool_name: []const u8, output_text: []const u8, out: *std.ArrayList(u8), opts: RenderOpts) !void {
    _ = opts;
    // TaskCreate: {"task":{"id":"1","subject":".."}} → ✓ created task #1: subject
    if (std.mem.eql(u8, tool_name, "TaskCreate")) {
        const id = extractField(output_text, "id") orelse "?";
        const subj = extractField(output_text, "subject") orelse "";
        const line = try std.fmt.allocPrint(alloc, "{s} created task #{s}: {s}", .{ th.icon_check, id, subj });
        defer alloc.free(line);
        try appendLine(alloc, out, th.dim, line, th.reset);
        return;
    }
    // Task / Agent spawn(同步):{"subagent_type":..,"final_text":..,"stop_reason":..}
    if (std.mem.eql(u8, tool_name, "Task") or std.mem.eql(u8, tool_name, "Agent")) {
        const st = extractField(output_text, "subagent_type") orelse "subagent";
        if (extractField(output_text, "final_text")) |ft| {
            const dec = try jsonUnescape(alloc, ft);
            defer alloc.free(dec);
            const head = firstLine(std.mem.trim(u8, dec, " \n"));
            const line = try std.fmt.allocPrint(alloc, "◆ {s}: {s}", .{ st, head });
            defer alloc.free(line);
            try appendLine(alloc, out, th.dim, line, th.reset);
            return;
        }
        // 后台 spawn:{"agent_job_id":..,"status":"running",..}
        if (extractField(output_text, "agent_job_id")) |jid| {
            const line = try std.fmt.allocPrint(alloc, "◆ {s} subagent started ({s})", .{ st, jid });
            defer alloc.free(line);
            try appendLine(alloc, out, th.dim, line, th.reset);
            return;
        }
    }
    // TaskOutput: {"status":..,"turns":..,"final_text":..} → status · N turns + 摘要
    if (std.mem.eql(u8, tool_name, "TaskOutput")) {
        const status = extractField(output_text, "status") orelse "?";
        const turns = extractNumberField(output_text, "turns") orelse 0;
        const line = try std.fmt.allocPrint(alloc, "{s} · {d} turns", .{ status, turns });
        defer alloc.free(line);
        try appendLine(alloc, out, th.dim, line, th.reset);
        return;
    }
    // TaskUpdate/TaskStop/TaskList/其它:{"ok":true} 等 → 简短确认。
    if (std.mem.indexOf(u8, output_text, "\"ok\":true") != null) {
        try appendLine(alloc, out, th.dim, "✓ ok", th.reset);
        return;
    }
    // 兜底:走通用(已 unescape 防裸 JSON 一坨)。
    return renderGenericFold(alloc, th, output_text, out, .{});
}

/// 取字符串首行(无换行则整串)。
fn firstLine(s: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return s;
    return s[0..nl];
}

/// 提取顶层数字字段(extractField 只取 string 值;exit_code/turns 是裸数字)。
fn extractNumberField(args: []const u8, key: []const u8) ?i64 {
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
    const start = p;
    if (p < args.len and (args[p] == '-')) p += 1;
    while (p < args.len and args[p] >= '0' and args[p] <= '9') : (p += 1) {}
    if (p == start) return null;
    return std.fmt.parseInt(i64, args[start..p], 10) catch null;
}

/// Edit/Write 结果:从结果 JSON 提取 gitDiff,逐行 +绿 / -红 / 空dim 着色(对齐 cc
/// StructuredPatch 着色)。未含 gitDiff(如简化结果)退回通用折叠。
fn renderEditDiff(alloc: std.mem.Allocator, th: Theme, output_text: []const u8, out: *std.ArrayList(u8), opts: RenderOpts) !void {
    const diff = extractJsonStringField(output_text, "gitDiff") orelse {
        return renderGenericFold(alloc, th, output_text, out, opts);
    };
    // diff 是 JSON 转义字符串;就地 unescape 到临时 buf 再逐行着色。
    const unescaped = jsonUnescape(alloc, diff) catch return renderGenericFold(alloc, th, output_text, out, opts);
    defer alloc.free(unescaped);

    const limit: u16 = if (opts.verbose or opts.transcript) std.math.maxInt(u16) else opts.max_output_lines;
    var shown: u16 = 0;
    var total: u16 = 0;
    var pos: usize = 0;
    while (pos < unescaped.len) {
        const eol = std.mem.indexOfScalarPos(u8, unescaped, pos, '\n') orelse unescaped.len;
        const line = unescaped[pos..eol];
        // 跳过 diff 文件头(--- / +++ / @@),只着色实际增删/上下文行。
        const is_header = std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---") or std.mem.startsWith(u8, line, "@@");
        if (!is_header) {
            total += 1;
            if (opts.collapsed and shown >= limit) {
                pos = eol + 1;
                continue;
            }
            const color: []const u8 = if (line.len > 0 and line[0] == '+') th.success else if (line.len > 0 and line[0] == '-') th.danger else th.dim;
            try out.appendSlice(alloc, "  ");
            try out.appendSlice(alloc, color);
            try out.appendSlice(alloc, line);
            try out.appendSlice(alloc, th.reset);
            try out.append(alloc, '\n');
            shown += 1;
        }
        pos = eol + 1;
    }
    if (opts.collapsed and total > limit) {
        try out.appendSlice(alloc, "  ");
        try out.appendSlice(alloc, th.dim);
        try out.print(alloc, "… {d} more diff lines", .{total - limit});
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
    }
}

/// Grep/Glob 结果:出 "Found N …" 摘要(对齐 cc SearchResultSummary)。
/// condensed(默认):只摘要行;verbose/transcript:摘要 + 文件/匹配列表(走通用折叠)。
fn renderSearchSummary(alloc: std.mem.Allocator, th: Theme, output_text: []const u8, out: *std.ArrayList(u8), opts: RenderOpts) !void {
    // 数非空行(每行一个文件/匹配)。
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < output_text.len) {
        const eol = std.mem.indexOfScalarPos(u8, output_text, pos, '\n') orelse output_text.len;
        if (std.mem.trim(u8, output_text[pos..eol], " \t\r").len > 0) count += 1;
        pos = eol + 1;
    }
    try out.appendSlice(alloc, "  ");
    try out.appendSlice(alloc, th.success);
    try out.print(alloc, "Found {d} {s}", .{ count, if (count == 1) "result" else "results" });
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');
    // verbose/transcript:展开列表。
    if (opts.verbose or opts.transcript) {
        try renderGenericFold(alloc, th, output_text, out, opts);
    }
}

/// Read 结果:出 "Read N lines"/image/PDF 摘要(对齐 cc FileRead UI)。
/// condensed:摘要行;verbose/transcript:摘要 + 内容(通用折叠)。
fn renderReadSummary(alloc: std.mem.Allocator, th: Theme, output_text: []const u8, out: *std.ArrayList(u8), opts: RenderOpts) !void {
    // 探测特殊首部(Read image / Read PDF / cells)——工具若已产摘要则直接用首行。
    const first_eol = std.mem.indexOfScalar(u8, output_text, '\n') orelse output_text.len;
    const first = output_text[0..first_eol];
    var summary_buf: [64]u8 = undefined;
    const summary: []const u8 = blk: {
        if (std.mem.indexOf(u8, first, "image") != null or std.mem.indexOf(u8, first, "PDF") != null) break :blk first;
        // 数行数。
        var lines: usize = 0;
        var pos: usize = 0;
        while (pos < output_text.len) {
            _ = std.mem.indexOfScalarPos(u8, output_text, pos, '\n') orelse {
                if (pos < output_text.len) lines += 1;
                break;
            };
            lines += 1;
            pos = (std.mem.indexOfScalarPos(u8, output_text, pos, '\n') orelse output_text.len) + 1;
        }
        break :blk std.fmt.bufPrint(&summary_buf, "Read {d} {s}", .{ lines, if (lines == 1) "line" else "lines" }) catch "Read";
    };
    try out.appendSlice(alloc, "  ");
    try out.appendSlice(alloc, th.dim);
    try out.appendSlice(alloc, summary);
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');
    if (opts.verbose or opts.transcript) {
        try renderGenericFold(alloc, th, output_text, out, opts);
    }
}

/// WebFetch 结果:出首行状态摘要;verbose 展开正文。
fn renderWebFetchSummary(alloc: std.mem.Allocator, th: Theme, output_text: []const u8, out: *std.ArrayList(u8), opts: RenderOpts) !void {
    const first_eol = std.mem.indexOfScalar(u8, output_text, '\n') orelse output_text.len;
    try out.appendSlice(alloc, "  ");
    try out.appendSlice(alloc, th.success);
    try out.appendSlice(alloc, output_text[0..first_eol]);
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');
    if (opts.verbose or opts.transcript) {
        try renderGenericFold(alloc, th, output_text, out, opts);
    }
}

/// 提取 JSON 顶层 string 字段的**原始(仍转义)**值切片(供 unescape)。
fn extractJsonStringField(args: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [64]u8 = undefined;
    if (key.len + 3 > pat_buf.len) return null;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, args, pat) orelse return null;
    var p = at + pat.len;
    while (p < args.len and (args[p] == ' ' or args[p] == '\t' or args[p] == ':')) : (p += 1) {}
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

/// JSON string 转义还原(\n \t \" \\ \uXXXX 的常见子集)。caller free。
fn jsonUnescape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                'n' => try out.append(alloc, '\n'),
                't' => try out.append(alloc, '\t'),
                'r' => try out.append(alloc, '\r'),
                '"' => try out.append(alloc, '"'),
                '\\' => try out.append(alloc, '\\'),
                '/' => try out.append(alloc, '/'),
                'u' => {
                    // \uXXXX:解码 BMP 码点为 UTF-8(用户截图里 & 未解码显示成字面,
                    // 应还原成 &)。解析失败则保留字面 u(容错)。
                    if (i + 4 < s.len) {
                        const hex = s[i + 1 .. i + 5];
                        if (std.fmt.parseInt(u21, hex, 16)) |cp| {
                            var buf: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                            if (n > 0) {
                                try out.appendSlice(alloc, buf[0..n]);
                                i += 4;
                            } else {
                                try out.append(alloc, 'u');
                            }
                        } else |_| {
                            try out.append(alloc, 'u');
                        }
                    } else {
                        try out.append(alloc, 'u');
                    }
                },
                else => try out.append(alloc, s[i]),
            }
        } else {
            try out.append(alloc, s[i]);
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
            // command 含 shell 操作符(&&、>、换行),JSON 里被转义成 && 等;
            // unescape 后再显示,否则用户看到 && 而非 &&。
            const dec = try jsonUnescape(alloc, cmd);
            defer alloc.free(dec);
            const oneline = firstLine(dec); // 多行命令只显首行预览
            return try std.fmt.allocPrint(alloc, "$ {s}", .{oneline});
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
    } else if (std.mem.eql(u8, tool_name, "Agent") or std.mem.eql(u8, tool_name, "Task")) {
        // 让用户认出"这是哪种 subagent"(用户曾困惑"要 subagent 却显示 Task")。
        // 预览:◆ <subagent_type>: <description>。缺省 general-purpose。
        const st = extractField(args, "subagent_type") orelse "general-purpose";
        if (extractField(args, "description")) |d| {
            return try std.fmt.allocPrint(alloc, "◆ {s} subagent: {s}", .{ st, d });
        }
        return try std.fmt.allocPrint(alloc, "◆ {s} subagent", .{st});
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

// ---- 逐工具结果渲染器 ----

test "renderResult: Edit diff +绿 -红 着色" {
    const th = theme_mod.dark;
    // 模拟 Write/Edit 结果 JSON,gitDiff 字段含标准 diff(JSON 转义)。
    const out_json = "{\"success\":true,\"path\":\"/x\",\"gitDiff\":\"--- a/x\\n+++ b/x\\n@@ -1,2 +1,2 @@\\n ctx\\n-old line\\n+new line\\n\"}";
    const s = try renderResult(testing.allocator, th, "Edit", "{\"file_path\":\"/x\"}", out_json, .ok, 100, .{});
    defer testing.allocator.free(s);
    // 增行内容、删行内容出现;diff 头(---/+++/@@)不作为内容行显示。
    try capture.expectContains(s, "new line");
    try capture.expectContains(s, "old line");
    // 着色:+ 行带 success 色(green),- 行带 danger 色(red)。
    try testing.expect(std.mem.indexOf(u8, s, th.success) != null);
    try testing.expect(std.mem.indexOf(u8, s, th.danger) != null);
}

test "renderResult: Edit 无 gitDiff → 退回通用折叠" {
    const th = theme_mod.monochrome;
    const out_json = "{\"success\":true,\"path\":\"/x\"}";
    const s = try renderResult(testing.allocator, th, "Write", "{\"file_path\":\"/x\"}", out_json, .ok, 100, .{});
    defer testing.allocator.free(s);
    // 不崩,原样走通用折叠(含 path 文本)。
    try capture.expectContains(s, "/x");
}

test "renderResult: Grep/Glob 出 Found N 摘要(condensed)" {
    const th = theme_mod.monochrome;
    const out = "src/a.zig\nsrc/b.zig\nsrc/c.zig\n";
    const s = try renderResult(testing.allocator, th, "Grep", "{\"pattern\":\"foo\"}", out, .ok, 50, .{});
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Found 3 results");
    // condensed:不展开文件列表
    try testing.expect(std.mem.indexOf(u8, s, "src/a.zig") == null);
}

test "renderResult: Grep verbose 展开文件列表" {
    const th = theme_mod.monochrome;
    const out = "src/a.zig\nsrc/b.zig\n";
    const s = try renderResult(testing.allocator, th, "Grep", "{\"pattern\":\"foo\"}", out, .ok, 50, .{ .verbose = true });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Found 2 results");
    try capture.expectContains(s, "src/a.zig"); // verbose 展开
    try capture.expectContains(s, "src/b.zig");
}

test "renderResult: Read 出 Read N lines 摘要" {
    const th = theme_mod.monochrome;
    const out = "line1\nline2\nline3\n";
    const s = try renderResult(testing.allocator, th, "Read", "{\"file_path\":\"/x\"}", out, .ok, 30, .{});
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Read 3 lines");
    // condensed:不展开内容
    try testing.expect(std.mem.indexOf(u8, s, "line2") == null);
}

test "renderResult: Read image 摘要直用首行" {
    const th = theme_mod.monochrome;
    const out = "Read image (512 KB)\n";
    const s = try renderResult(testing.allocator, th, "Read", "{\"file_path\":\"/x.png\"}", out, .ok, 30, .{});
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Read image (512 KB)");
}

test "renderResult: WebFetch 出状态摘要" {
    const th = theme_mod.monochrome;
    const out = "Received 12 KB (HTTP 200 OK)\n<html>...</html>\n";
    const s = try renderResult(testing.allocator, th, "WebFetch", "{\"url\":\"http://x\"}", out, .ok, 80, .{});
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Received 12 KB (HTTP 200 OK)");
    // condensed:不展开正文
    try testing.expect(std.mem.indexOf(u8, s, "<html>") == null);
}

test "renderResult: Bash 仍走通用折叠(无专用渲染器)" {
    const th = theme_mod.monochrome;
    const out = "a\nb\nc\nd\ne\nf\ng\n";
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"x\"}", out, .ok, 10, .{ .max_output_lines = 3 });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "a");
    try capture.expectContains(s, "… 4 more lines");
}

test "renderResult: verbose 关折叠(通用)" {
    const th = theme_mod.monochrome;
    const out = "a\nb\nc\nd\ne\nf\ng\n";
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"x\"}", out, .ok, 10, .{ .max_output_lines = 3, .verbose = true });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "g"); // 全显示
    try testing.expect(std.mem.indexOf(u8, s, "more lines") == null);
}

test "VISUAL demo: Edit diff(TUI_DEMO=1)" {
    if (std.c.getenv("TUI_DEMO") == null) return error.SkipZigTest;
    const th = theme_mod.dark;
    const out_json = "{\"success\":true,\"path\":\"/x.zig\",\"gitDiff\":\"--- a/x.zig\\n+++ b/x.zig\\n@@ -1,3 +1,3 @@\\n const a = 1;\\n-const b = 2;\\n+const b = 20;\\n const c = 3;\\n\"}";
    const s = try renderResult(testing.allocator, th, "Edit", "{\"file_path\":\"/x.zig\"}", out_json, .ok, 88, .{ .cols = 60 });
    defer testing.allocator.free(s);
    std.debug.print("\n{s}\n", .{s});
}

// ---- opt-out 不变量(无裸 JSON / hidden 工具结果不进消息流)----

test "resultRenderMode: Task 族 + plan 模式 + 未知工具 → hidden" {
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("Task"));
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("TaskCreate"));
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("TaskOutput"));
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("EnterPlanMode"));
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("ExitPlanMode"));
    // 无专用渲染器的工具(暂)归 hidden,绝不裸吐 JSON。
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("NotebookEdit"));
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("Skill"));
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("ListMcpResourcesTool"));
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("ReadMcpResourceTool"));
    // 完全未知的工具也 hidden。
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("SomeFutureTool"));
    // 有专用渲染器的工具 → summary。
    try testing.expectEqual(ResultRenderMode.summary, resultRenderMode("Bash"));
    try testing.expectEqual(ResultRenderMode.summary, resultRenderMode("Edit"));
}

test "renderResult: Task 成功结果不进消息流(空串)" {
    const th = theme_mod.monochrome;
    // Task 返回的典型 JSON,绝不应出现在屏幕上。
    const out = "{\"task_id\":\"agent_1\",\"result\":\"done\"}";
    const s = try renderResult(testing.allocator, th, "Task", "{\"description\":\"x\"}", out, .ok, 1200, .{});
    defer testing.allocator.free(s);
    try testing.expectEqual(@as(usize, 0), s.len);
}

test "renderResult: NotebookEdit 成功结果 hidden(不裸吐 JSON)" {
    const th = theme_mod.monochrome;
    const out = "{\"success\":true,\"path\":\"/n.ipynb\",\"mode\":\"replace\",\"cells_after\":3}";
    const s = try renderResult(testing.allocator, th, "NotebookEdit", "{\"notebook_path\":\"/n.ipynb\"}", out, .ok, 100, .{});
    defer testing.allocator.free(s);
    // hidden:整条空串,屏幕上看不到任何 JSON 大括号。
    try testing.expectEqual(@as(usize, 0), s.len);
}

test "renderResult: 错误结果提取 detail 而非裸吐 error JSON" {
    const th = theme_mod.monochrome;
    // 结构化工具错误(tool_error.errorToJson 形态)。
    const out = "{\"error\":{\"code\":\"E_NOENT\",\"detail\":\"file not found: /missing\"}}";
    const s = try renderResult(testing.allocator, th, "Read", "{\"file_path\":\"/missing\"}", out, .err, 50, .{});
    defer testing.allocator.free(s);
    // detail 文本出现,且解过转义。
    try capture.expectContains(s, "file not found: /missing");
    // 不裸吐结构化字段名 code。
    try testing.expect(std.mem.indexOf(u8, s, "\"code\"") == null);
    try testing.expect(std.mem.indexOf(u8, s, "E_NOENT") == null);
}

test "renderResult: 非结构化错误 unescape 后折叠显示" {
    const th = theme_mod.monochrome;
    // 没有 detail 字段的错误:整段 unescape 后显示,不丢失。
    const out = "permission denied\\nretry later\\n";
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"x\"}", out, .err, 50, .{});
    defer testing.allocator.free(s);
    try capture.expectContains(s, "permission denied");
    try capture.expectContains(s, "retry later");
}

test "renderResult: 无 detail 的结构化错误不裸吐 JSON" {
    const th = theme_mod.monochrome;
    // errorToJson 总带 detail,但外部错误可能只有 code → 绝不裸吐 {"error":...}。
    const out = "{\"error\":{\"code\":\"E_X\",\"recoverable\":false}}";
    const s = try renderResult(testing.allocator, th, "Read", "{\"file_path\":\"/x\"}", out, .err, 50, .{});
    defer testing.allocator.free(s);
    try capture.expectContains(s, "[tool error]");
    // 不出现任何 JSON 结构残留。
    try testing.expect(std.mem.indexOf(u8, s, "\"error\"") == null);
    try testing.expect(std.mem.indexOf(u8, s, "\"code\"") == null);
    try testing.expect(std.mem.indexOf(u8, s, "E_X") == null);
}

test "renderResult: detail 为空串退回 message" {
    const th = theme_mod.monochrome;
    const out = "{\"error\":{\"detail\":\"\",\"message\":\"disk full\"}}";
    const s = try renderResult(testing.allocator, th, "Write", "{\"file_path\":\"/x\"}", out, .err, 50, .{});
    defer testing.allocator.free(s);
    try capture.expectContains(s, "disk full");
    try testing.expect(std.mem.indexOf(u8, s, "\"message\"") == null);
}

test "renderResult: err 侧绕过专用渲染器(Edit 失败不走 diff)" {
    const th = theme_mod.dark;
    // Edit 失败:即便输出里有 gitDiff,err 路径也应走 renderErrorBody 而非 diff 着色。
    const out = "{\"error\":{\"detail\":\"old_string not found\"},\"gitDiff\":\"--- a\\n+++ b\\n+x\\n\"}";
    const s = try renderResult(testing.allocator, th, "Edit", "{\"file_path\":\"/x\"}", out, .err, 50, .{});
    defer testing.allocator.free(s);
    try capture.expectContains(s, "old_string not found");
    // diff 正文(+x 的内容行)不应出现 —— 证明没走 renderEditDiff。
    try testing.expect(std.mem.indexOf(u8, s, "+++") == null);
}

test "renderResult: err 侧 Grep 失败走 error 体而非 Found N 摘要" {
    const th = theme_mod.monochrome;
    const out = "{\"error\":{\"detail\":\"invalid regex\"}}";
    const s = try renderResult(testing.allocator, th, "Grep", "{\"pattern\":\"[\"}", out, .err, 50, .{});
    defer testing.allocator.free(s);
    try capture.expectContains(s, "invalid regex");
    try testing.expect(std.mem.indexOf(u8, s, "Found") == null);
}

test "renderResult: hidden 工具失败时仍渲染(不静默吞错)" {
    const th = theme_mod.monochrome;
    // Task 成功 → hidden(空串);但失败必须让用户看到,否则 subagent 错误被吞。
    const out = "{\"error\":{\"detail\":\"subagent crashed\"}}";
    const s = try renderResult(testing.allocator, th, "Task", "{\"description\":\"x\"}", out, .err, 800, .{});
    defer testing.allocator.free(s);
    try testing.expect(s.len > 0);
    try capture.expectContains(s, "subagent crashed");
    // 状态符是失败标记。
    try capture.expectContains(s, "X 0.8s"); // monochrome icon_cross="X"
}


