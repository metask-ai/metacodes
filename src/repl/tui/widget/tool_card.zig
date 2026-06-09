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
//!   Read      → "{basename}"  (对齐 cc:无 icon、basename 非完整路径)
//!   Edit/Write → "± {path}" (mono: "E {path}")
//!   其它      → "" (省略)

const std = @import("std");
const theme_mod = @import("../theme.zig");
const layout = @import("../layout.zig");
const term = @import("../term.zig");
const render_mod = @import("../../render.zig");
const ts = @import("../../../treesitter/ts.zig");
const highlight = @import("../../../treesitter/highlight.zig");
const Theme = theme_mod.Theme;

pub const RenderOpts = struct {
    /// 输出最多显示几行(超出折叠 + "… +N lines")。对齐 cc 2.1.167:前 10 行。
    max_output_lines: u16 = 10,
    /// 是否启用折叠(false = 全部显示)
    collapsed: bool = true,
    /// 终端宽度(决定状态右对齐位置;0 = 不右对齐)
    cols: u16 = 0,
    /// 详细模式(对齐 cc verbose):摘要类工具展开完整内容,折叠阈值放宽。
    verbose: bool = false,
    /// transcript 历史视图(对齐 cc isTranscriptMode):语义同 verbose(展开)。
    transcript: bool = false,
    /// Edit/Write diff 的 tree-sitter 高亮缓存(按 tool_id 取新旧全文)。null → 退回关键字表。
    edit_hl_cache: ?*@import("../../../core/edit_hl_cache.zig").EditHlCache = null,
    /// 本次 tool_use id(查 edit_hl_cache 用)。
    tool_id: []const u8 = "",
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
    // opt-out(故意 hidden):
    // - Task 族:状态在 Task 面板反馈,不刷消息流。
    // - plan mode:模式切换,无输出。
    // - AskUserQuestion:走专门的交互 UI(选项菜单),非工具卡片。
    // - Skill:结果(rendered body)内联进对话文本,本身就是可见内容,无需卡片。
    if (std.mem.startsWith(u8, tool_name, "Task")) return .hidden;
    if (std.mem.eql(u8, tool_name, "EnterPlanMode") or std.mem.eql(u8, tool_name, "ExitPlanMode")) return .hidden;
    if (std.mem.eql(u8, tool_name, "AskUserQuestion")) return .hidden;
    if (std.mem.eql(u8, tool_name, "Skill")) return .hidden;
    // 有专用 summary 渲染器的工具(renderResultBody 分发到 diff/搜索/Read/WebFetch 渲染器)。
    const summary_tools = [_][]const u8{
        "Bash",     "BashOutput", "Edit", "Write", "Read", "Grep", "Glob",
        "WebFetch", "WebSearch",  "Agent",
    };
    for (summary_tools) |t| {
        if (std.mem.eql(u8, tool_name, t)) return .summary;
    }
    // 有副作用、返回 JSON 的工具:有人话渲染器(renderJsonToolSummary)→ summary。
    // 否则 hidden 会让 agent_loop 连 ⏺ 起始卡都跳过(工具被调用时 TUI 完全无感,
    // 2026-06-04 实测过的 WebSearch bug)。
    if (isJsonSummaryTool(tool_name)) return .summary;
    // 真正未知/无渲染器的工具:仍 hidden(绝不裸吐 JSON;新工具要显示就加渲染器)。
    return .hidden;
}

/// 是否在工具开始时渲染起始卡(⏺ <tool>)。与 resultRenderMode(它管*结果体*显示)分离。
///
/// Task/Agent:起始卡可见(用户必须看到 subagent 被启动),但结果体仍 hidden
/// (状态在 Task 面板反馈)。AskUserQuestion/plan-mode/Skill:无起始卡(走专门 UI)。
/// 历史 bug:agent_loop 旧逻辑直接用 resultRenderMode==hidden 跳过起始卡 → Task 被调用时
/// TUI 完全无感(用户看不到 subagent 启动)。本函数把"是否打起始卡"独立出来修复之。
pub fn showStartCard(tool_name: []const u8) bool {
    if (std.mem.eql(u8, tool_name, "AskUserQuestion")) return false;
    if (std.mem.eql(u8, tool_name, "EnterPlanMode") or std.mem.eql(u8, tool_name, "ExitPlanMode")) return false;
    if (std.mem.eql(u8, tool_name, "Skill")) return false;
    // Task/Agent:起始卡可见(精确匹配,避免 TaskCreate/TaskUpdate 等子工具噪声)。
    if (std.mem.eql(u8, tool_name, "Task") or std.mem.eql(u8, tool_name, "Agent")) return true;
    // 其余:沿用 resultRenderMode——非 hidden 才打起始卡。
    return resultRenderMode(tool_name) != .hidden;
}

/// 头部状态图标 + 颜色。与 ResultKind 解耦,处理 Bash 的两类"成功但非真成功"特例:
///   - 非零 exit_code:cc 语义上是正常结果(grep miss/test fail),不改 is_error(它进
///     API tool_result),但头部图标降级 ✓→✗ 给用户失败可视提示。
///   - auto_backgrounded:超 15s 转后台,不是完成,头部用中性 ⏺(非绿 ✓)。
/// 非 Bash 工具:沿用 kind → ✓/✗。
fn headerIcon(th: Theme, tool_name: []const u8, output_text: []const u8, kind: ResultKind) struct { glyph: []const u8, color: []const u8 } {
    if (kind == .ok and std.mem.eql(u8, tool_name, "Bash")) {
        if (std.mem.indexOf(u8, output_text, "\"auto_backgrounded\":true") != null) {
            // 转后台:中性 ⏺ + warn 色(非成功、非失败)。
            return .{ .glyph = th.icon_act, .color = th.warn };
        }
        if (extractNumberField(output_text, "exit_code")) |code| {
            if (code != 0) return .{ .glyph = th.icon_cross, .color = th.danger };
        }
    }
    return if (kind == .ok)
        .{ .glyph = th.icon_check, .color = th.success }
    else
        .{ .glyph = th.icon_cross, .color = th.danger };
}

/// 用户可见名(对齐 cc userFacingName):TUI 工具卡标题用。UI 表现层映射,
/// 不耦合 registry。当前仅 WebSearch → "Web Search"(带空格)。其余用原名。
pub fn displayName(tool_name: []const u8) []const u8 {
    if (std.mem.eql(u8, tool_name, "WebSearch")) return "Web Search";
    if (std.mem.eql(u8, tool_name, "Edit")) return "Update"; // 对齐 cc:Edit 卡标题 = Update(file)
    return tool_name;
}

/// 该工具执行中是否有"可重绘 progress 卡"(对齐 cc 单一工具卡:执行中由动态区那张卡
/// 独占显示)。返 true 的工具:不走 renderStart→滚动历史、不在底部 spinner 显工具段,
/// 改由 render_region.drawToolProgressCard 在动态区显示双段卡。当前仅 WebSearch。
pub fn hasProgressCard(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "WebSearch");
}

/// 类A(查询/执行类):执行期整张卡活在底部动态重绘区(自然语言进行时标题),
/// 完成后 **commit 进 scrollback**(过去式标题)。对齐 cc 2.1.165 工具卡两态。
/// 与 hasProgressCard(WebSearch:完成只移除,结果走助手文本)互斥。
pub fn usesLiveCard(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "Bash") or std.mem.eql(u8, tool_name, "Read") or
        std.mem.eql(u8, tool_name, "Grep") or std.mem.eql(u8, tool_name, "Glob");
}

/// tool_start 时是否占用动态区那张卡(addToolCard)。两类(WebSearch progress + 类A live)统称。
pub fn usesDynamicCard(tool_name: []const u8) bool {
    return hasProgressCard(tool_name) or usesLiveCard(tool_name);
}

/// 类A 工具运行中进行时标题(不含 ⏺ bullet,调用点加)。对齐 cc `Running 1 shell command…`。
/// caller free。
pub fn toolRunningTitle(alloc: std.mem.Allocator, tool_name: []const u8, args: []const u8) ![]u8 {
    _ = args;
    const s: []const u8 = if (std.mem.eql(u8, tool_name, "Bash"))
        "Running 1 shell command…"
    else if (std.mem.eql(u8, tool_name, "Read"))
        "Reading 1 file…"
    else if (std.mem.eql(u8, tool_name, "Grep"))
        "Searching for 1 pattern…"
    else if (std.mem.eql(u8, tool_name, "Glob"))
        "Finding files…"
    else
        displayName(tool_name);
    return try alloc.dupe(u8, s);
}

/// 类A 工具完成过去式标题(不含 ⏺ bullet)。对齐 cc `Ran 1 shell command`。
/// content 供需计数的工具(Glob:数结果行)用,其余忽略。caller free。
pub fn toolDoneTitle(alloc: std.mem.Allocator, tool_name: []const u8, args: []const u8, content: []const u8) ![]u8 {
    _ = args;
    if (std.mem.eql(u8, tool_name, "Bash")) return try alloc.dupe(u8, "Ran 1 shell command");
    if (std.mem.eql(u8, tool_name, "Read")) return try alloc.dupe(u8, "Read 1 file");
    if (std.mem.eql(u8, tool_name, "Grep")) return try alloc.dupe(u8, "Searched for 1 pattern");
    if (std.mem.eql(u8, tool_name, "Glob")) {
        const n = countGlobMatches(content);
        if (n > 0) return try std.fmt.allocPrint(alloc, "Found {d} file{s}", .{ n, if (n == 1) "" else "s" });
        return try alloc.dupe(u8, "Found files");
    }
    return try alloc.dupe(u8, displayName(tool_name));
}

/// 从 Glob 结果 content 数匹配文件数。Glob 结果是 JSON(含 matches 数组或换行分隔路径)。
/// 数 content 里的 `\n`(每路径一行)。数不出返 0。
fn countGlobMatches(content: []const u8) usize {
    // Glob 工具结果格式:JSON 字符串字段含路径列表(\n 分隔),或 matches 数组。
    // 简化:数 JSON 转义的 `\\n` 出现次数 + 1(若有非空内容)。保守:数不出返 0。
    if (content.len == 0) return 0;
    var n: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, "\\n")) |i| {
        n += 1;
        pos = i + 2;
    }
    return n; // 无 \n → 0(由 toolDoneTitle 兜底 "Found files")
}


/// 工具开始(无状态符,只有 ⏺ tool_name + 命令预览)。对齐 cc BLACK_CIRCLE bullet。
/// caller free。
pub fn renderStart(alloc: std.mem.Allocator, th: Theme, tool_name: []const u8, preview_args: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // 单行标题(对齐 cc):`⏺ <display name>(<arg>)`。bullet 用 accent 色;arg 内联括号
    // (Write/Edit→basename、Bash→命令、WebSearch→"query"…),无 arg 则只显工具名。
    try out.appendSlice(alloc, th.accent);
    try out.appendSlice(alloc, th.icon_act);
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, displayName(tool_name));
    const arg = try headerArg(alloc, tool_name, preview_args);
    defer alloc.free(arg);
    if (arg.len > 0) {
        try out.append(alloc, '(');
        try out.appendSlice(alloc, arg);
        try out.append(alloc, ')');
    }
    try out.append(alloc, '\n');

    return try out.toOwnedSlice(alloc);
}

/// 工具进度(同 renderStart + 右上角带耗时)。caller free。
pub fn renderProgress(alloc: std.mem.Allocator, th: Theme, tool_name: []const u8, preview_args: []const u8, elapsed_ms: u64, opts: RenderOpts) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // 第 1 行:⏺ <display name> + (耗时 spinner)
    try out.appendSlice(alloc, th.accent);
    try out.appendSlice(alloc, th.icon_act);
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, displayName(tool_name));

    // 右上角:spinner + 耗时
    var stat_buf: [64]u8 = undefined;
    const stat = try std.fmt.bufPrint(&stat_buf, "{s}… {d:.1}s{s}", .{ th.warn, @as(f64, @floatFromInt(elapsed_ms)) / 1000.0, th.reset });
    if (opts.cols > 0) {
        const left_w = term.displayWidth(th.icon_act) + 1 + term.displayWidth(displayName(tool_name));
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

    // 标题行:**仅 transcript(独立卡)渲染**。live 模式起始卡(renderStart)已打 `⏺ Name(arg)`
    // 标题,结果卡只补 `⎿ body`,避免标题重复(对齐 cc 单卡形态)。
    if (opts.transcript) {
        // 第 1 行:⏺ <display name>(arg) + ✓/✗ X.Ys
        try out.appendSlice(alloc, th.accent);
        try out.appendSlice(alloc, th.icon_act);
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, ' ');
        try out.appendSlice(alloc, displayName(tool_name));
        const harg = try headerArg(alloc, tool_name, preview_args);
        defer alloc.free(harg);
        if (harg.len > 0) {
            try out.append(alloc, '(');
            try out.appendSlice(alloc, harg);
            try out.append(alloc, ')');
        }

        // 右上角:状态符 + 耗时(复用 appendStatusRight)。左侧宽 = bullet+空格+displayName。
        const left_w = term.displayWidth(th.icon_act) + 1 + term.displayWidth(displayName(tool_name));
        try appendStatusRight(alloc, th, tool_name, output_text, kind, elapsed_ms, opts, left_w, &out);
    }

    // 输出体:经子渲染器渲染到临时 buffer(各行 2 空格缩进),再套 ⎿ gutter——
    // 首行 `  ⎿  ` + 角符,续行 5 空格对齐(对齐 cc `  ⎿  ` gutter)。
    // 注:body 可能含 diff SGR(Edit/Write 整行背景块),不能按 codepoint 软折(会断 SGR);
    // 故 body 走 appendWithGutter(逻辑行 5 列悬挂,不软折)。纯文本长行软折只用于 `$ cmd` 预览(见 renderLiveDone)。
    if (output_text.len > 0) {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(alloc);
        try renderResultBody(alloc, th, tool_name, output_text, &body, opts, kind);
        try appendWithGutter(alloc, th, body.items, &out);
    }

    return try out.toOwnedSlice(alloc);
}

/// 右上角状态符 + 耗时(`✓ 0.4s` 右对齐)。**仅 renderResult 的 transcript(Ctrl+O 历史视图)用**。
/// 正常 scrollback 的 committed 卡(renderLiveDone)不显耗时(对齐 cc 2.1.165)。
/// left_w:标题行左侧已占显示宽(bullet+空格+标题),用于算右对齐填充。
/// 图标经 headerIcon 解耦(Bash 非零 exit→✗、转后台→中性)。末尾带 '\n'。
fn appendStatusRight(
    alloc: std.mem.Allocator,
    th: Theme,
    tool_name: []const u8,
    output_text: []const u8,
    kind: ResultKind,
    elapsed_ms: u64,
    opts: RenderOpts,
    left_w: usize,
    out: *std.ArrayList(u8),
) !void {
    const hicon = headerIcon(th, tool_name, output_text, kind);
    var stat_buf: [64]u8 = undefined;
    const stat_inner = try std.fmt.bufPrint(&stat_buf, "{s} {d:.1}s", .{ hicon.glyph, @as(f64, @floatFromInt(elapsed_ms)) / 1000.0 });
    if (opts.cols > 0) {
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
    try out.appendSlice(alloc, hicon.color);
    try out.appendSlice(alloc, stat_inner);
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');
}

/// 类A 工具(Bash/Read/Grep/Glob)完成后 commit 进 scrollback 的完整卡。对齐 cc 2.1.165:
///   行1: `⏺ <toolDoneTitle>`(过去式自然语言)+ 右对齐 `✓/✗ X.Ys`
///   行2: `  ⎿  <toolPreview>`(**只显输入** $ cmd / 📄 path / pattern: "…",不显输出——输出走助手文本)
/// 与 renderResult(live 模式只补 ⎿ body)不同:类A 运行中标题在动态区会被擦,commit 卡须自带完整标题。
/// caller free。
pub fn renderLiveDone(
    alloc: std.mem.Allocator,
    th: Theme,
    tool_name: []const u8,
    input: []const u8,
    content: []const u8,
    kind: ResultKind,
    elapsed_ms: u64,
    opts: RenderOpts,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // 行1:⏺ <done title>。**不显右对齐耗时**——对齐 cc 2.1.165:committed scrollback 卡
    // 只有 `⏺ Ran 1 shell command` 标题,无 `✓ 0.1s`(耗时仅在运行中动态卡/spinner 上,
    // 不进历史)。kind 的成功/失败由 ⎿ body 体现(错误结果走 renderResultBody 红字)。
    _ = kind;
    _ = elapsed_ms;
    const title = try toolDoneTitle(alloc, tool_name, input, content);
    defer alloc.free(title);
    try out.appendSlice(alloc, th.accent);
    try out.appendSlice(alloc, th.icon_act);
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, ' ');
    try out.appendSlice(alloc, title);
    try out.append(alloc, '\n');

    // 行2:⎿ 只显输入预览($ cmd / 📄 path / pattern: "…")。与运行中态第二行一致。
    // 长命令按宽度软折行 + 5 列悬挂缩进(对齐 cc:续行不回第 0 列,见 appendGutterWrapped)。
    const preview = try toolPreview(alloc, tool_name, input);
    defer alloc.free(preview);
    if (preview.len > 0) {
        try appendGutterWrapped(alloc, th, preview, opts.cols, &out);
    }

    return try out.toOwnedSlice(alloc);
}

fn appendWithGutter(alloc: std.mem.Allocator, th: Theme, body: []const u8, out: *std.ArrayList(u8)) !void {
    if (body.len == 0) return;
    var first = true;
    var pos: usize = 0;
    while (pos < body.len) {
        const eol = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
        var line = body[pos..eol];
        // 剥掉子渲染器加的前导 2 空格(若有),gutter 自带缩进。
        if (std.mem.startsWith(u8, line, "  ")) line = line[2..];
        if (first) {
            try out.appendSlice(alloc, "  ");
            try out.appendSlice(alloc, th.dim);
            try out.appendSlice(alloc, th.gutter);
            try out.appendSlice(alloc, th.reset);
            try out.appendSlice(alloc, "  ");
            first = false;
        } else {
            try out.appendSlice(alloc, "     "); // 5 空格对齐
        }
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
        pos = eol + 1;
    }
}

/// `⎿` gutter 行 + **宽度感知软折行 + 悬挂缩进**(对齐 cc:长命令/长摘要自然换行只到当前缩进极限,
/// 续行缩进 5 列对齐 `⎿  ` 之后的内容,不回第 0 列)。首行 `  ⎿  <seg>`,续行(逻辑续行 + 软折)`     <seg>`。
/// cols=0(无宽度信息)→ 退化为不折行(每逻辑行整行输出)。按显示宽折(CJK 占 2 列)。
fn appendGutterWrapped(alloc: std.mem.Allocator, th: Theme, text: []const u8, cols: usize, out: *std.ArrayList(u8)) !void {
    if (text.len == 0) return;
    const GUTTER_W: usize = 5; // `  ⎿  ` 显示宽 = 2 + 1(⎿)+ 2
    const avail: usize = if (cols > GUTTER_W + 4) cols - GUTTER_W else 0; // 0 = 不折行
    var first = true;
    var pos: usize = 0;
    while (pos < text.len) {
        const eol = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        var line = text[pos..eol];
        if (std.mem.startsWith(u8, line, "  ")) line = line[2..]; // 剥子渲染器前导 2 空格
        // 软折:把 line 按显示宽 avail 切成多段(avail=0 → 整行一段)。
        var seg_start: usize = 0;
        while (seg_start <= line.len) {
            const seg_end = if (avail == 0) line.len else wrapPoint(line, seg_start, avail);
            const seg = line[seg_start..seg_end];
            // 前缀:首行 gutter,续行/软折行 5 空格。
            if (first) {
                try out.appendSlice(alloc, "  ");
                try out.appendSlice(alloc, th.dim);
                try out.appendSlice(alloc, th.gutter);
                try out.appendSlice(alloc, th.reset);
                try out.appendSlice(alloc, "  ");
                first = false;
            } else {
                try out.appendSlice(alloc, "     ");
            }
            try out.appendSlice(alloc, seg);
            try out.append(alloc, '\n');
            if (seg_end >= line.len) break;
            seg_start = seg_end;
        }
        pos = eol + 1;
    }
}

/// 从 start 起,返回不超过 max_w 显示宽的最大 byte 终点(至少推进 1 个 codepoint,防死循环)。
/// 按 UTF-8 codepoint 推进,CJK 等宽字符占 2 列(term.displayWidth)。
fn wrapPoint(s: []const u8, start: usize, max_w: usize) usize {
    var i = start;
    var w: usize = 0;
    while (i < s.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + cp_len, s.len);
        const cw = term.displayWidth(s[i..end]);
        if (w + cw > max_w) {
            // 至少吃 1 个 codepoint,避免 start 处零进展死循环。
            if (i == start) return end;
            return i;
        }
        w += cw;
        i = end;
    }
    return i;
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
    if (std.mem.eql(u8, tool_name, "Write")) {
        // cc 风格:Write 结果首行摘要 `Wrote N lines to <basename>`,下接内容预览。
        // 对齐 cc DIFF#8b:Write 是纯新建,预览**无 diff 标记**(plain 行号,非 +/-)。
        const path = extractField(output_text, "file_path") orelse extractField(output_text, "path") orelse "";
        const n = countWrittenLines(alloc, output_text);
        if (n > 0 and path.len > 0) {
            try out.appendSlice(alloc, "  ");
            try out.print(alloc, "Wrote {d} line{s} to {s}", .{ n, if (n == 1) "" else "s", basename(path) });
            try out.append(alloc, '\n');
        }
        return renderEditDiffImpl(alloc, th, output_text, out, opts, true); // plain=true(无 +/-)
    }
    if (std.mem.eql(u8, tool_name, "Edit")) {
        return renderEditDiffImpl(alloc, th, output_text, out, opts, false); // plain=false(diff +/-)
    }
    if (std.mem.eql(u8, tool_name, "NotebookEdit")) {
        // cell 改动有 gitDiff → 摘要行 + diff 渲染(tree-sitter 高亮,lang 从结果取);
        // 无 gitDiff(纯结构改/patch 失败)→ 退回 JSON 摘要。
        if (extractJsonStringField(output_text, "gitDiff") != null) {
            const mode = extractJsonStringField(output_text, "mode") orelse "edit";
            const path = extractField(output_text, "path") orelse extractField(output_text, "file_path") orelse "notebook";
            try out.appendSlice(alloc, "  ");
            try out.print(alloc, "{s} cell in {s}", .{ mode, basename(path) });
            try out.append(alloc, '\n');
            return renderEditDiffImpl(alloc, th, output_text, out, opts, false);
        }
        return renderJsonToolSummary(alloc, th, tool_name, output_text, out, opts);
    }
    if (std.mem.eql(u8, tool_name, "Grep") or std.mem.eql(u8, tool_name, "Glob")) {
        return renderSearchSummary(alloc, th, output_text, out, opts);
    }
    if (std.mem.eql(u8, tool_name, "Read")) {
        return renderReadSummary(alloc, th, output_text, out, opts);
    }
    if (std.mem.eql(u8, tool_name, "WebSearch")) {
        // 完成态(对齐 cc renderToolResultMessage):`Did N searches`(N = 结果块数)。
        // 详细结果(链接/摘要)verbose/transcript 才展开。
        return renderWebSearchSummary(alloc, th, output_text, out, opts);
    }
    if (std.mem.eql(u8, tool_name, "WebFetch")) {
        // 结果首行人类可读摘要;非 verbose 只显首行,verbose/transcript 展开。
        return renderWebFetchSummary(alloc, th, output_text, out, opts);
    }
    // 有副作用但返回 JSON 的工具:提关键字段拼一行人话(绝不裸吐 JSON)。
    // NotebookEdit/KillShell/Monitor/Cron*/Worktree/PushNotification/ListMcp/ReadMcp/ToolSearch。
    if (isJsonSummaryTool(tool_name)) {
        return renderJsonToolSummary(alloc, th, tool_name, output_text, out, opts);
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
    // 0) 中断(用户 esc / abort):对齐 cc InterruptedByUser 通用机制 —— 所有工具中断
    //    都显示 `Interrupted · What should Claude do instead?`,而非裸错误。
    if (extractField(output_text, "code")) |code| {
        if (std.mem.eql(u8, code, "Aborted")) {
            try appendLine(alloc, out, th.dim, "Interrupted · What should Claude do instead?", th.reset);
            return;
        }
    }
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
        try out.print(alloc, "… +{d} lines", .{total_lines - limit}); // 对齐 cc DIFF#8:`… +N lines`
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
    // 后台 Bash → 一行提示,不展开裸 JSON。两类:
    //   - explicit bg(run_in_background):{"job_id":..,"status":"started",...}
    //   - auto bg(超 15s 转后台):{"auto_backgrounded":true,"job_id":..,"note":..}(无 status)
    if (extractField(output_text, "job_id")) |jid| {
        const is_started = extractField(output_text, "status") != null;
        const is_auto = std.mem.indexOf(u8, output_text, "\"auto_backgrounded\":true") != null;
        if (is_started or is_auto) {
            const line = if (is_auto)
                try std.fmt.allocPrint(alloc, "▶ moved to background job {s} (exceeded 15s)", .{jid})
            else
                try std.fmt.allocPrint(alloc, "▶ background job {s}", .{jid});
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
    // Task / Agent spawn(同步):{"subagent_type":..,"final_text":..,"tool_calls":N,"tokens":N,"elapsed_ms":N}
    // 完成态塌缩卡(对齐实拍 `⎿ Done (2 tool uses · 18.1k tokens · 8s)`)。
    if (std.mem.eql(u8, tool_name, "Task") or std.mem.eql(u8, tool_name, "Agent")) {
        const st = extractField(output_text, "subagent_type") orelse "subagent";
        // 后台 spawn:{"agent_job_id":..,"status":"running",..}
        if (extractField(output_text, "agent_job_id")) |jid| {
            const line = try std.fmt.allocPrint(alloc, "◆ {s} subagent started ({s})", .{ st, jid });
            defer alloc.free(line);
            try appendLine(alloc, out, th.dim, line, th.reset);
            return;
        }
        // 同步完成:Done (N tool use(s) · X tokens · Ns)。
        if (extractField(output_text, "final_text") != null or extractNumberField(output_text, "tool_calls") != null) {
            const tc = extractNumberField(output_text, "tool_calls") orelse 0;
            const tokens = extractNumberField(output_text, "tokens") orelse 0;
            const elapsed_ms = extractNumberField(output_text, "elapsed_ms") orelse 0;
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(alloc);
            try line.appendSlice(alloc, "Done (");
            try line.print(alloc, "{d} tool use{s}", .{ tc, if (tc == 1) "" else "s" });
            if (tc > 0 and tokens > 0) {
                const tk = try fmtTokensK(alloc, tokens);
                defer alloc.free(tk);
                try line.print(alloc, " · {s} tokens", .{tk});
            }
            if (elapsed_ms > 0) {
                try line.print(alloc, " · {d}s", .{@divTrunc(elapsed_ms + 500, 1000)});
            }
            try line.append(alloc, ')');
            try appendLine(alloc, out, th.dim, line.items, th.reset);
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
/// token 数格式化(对齐 agent_tree.fmtTokens):17300 → "17.3k";<1000 原样。i64 入参。
fn fmtTokensK(alloc: std.mem.Allocator, n: i64) ![]u8 {
    if (n < 1000) return std.fmt.allocPrint(alloc, "{d}", .{n});
    const k = @as(f64, @floatFromInt(n)) / 1000.0;
    return std.fmt.allocPrint(alloc, "{d:.1}k", .{k});
}

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

/// Edit/Write 结果:从结果 JSON 提取 gitDiff,逐行着色(对齐 cc StructuredPatch)。
/// 未含 gitDiff(如简化结果)退回通用折叠。
/// plain=true(Write 纯新建):行号无 +/- 标记、无 add 背景(对齐 cc DIFF#8b);
/// plain=false(Edit diff):+绿/-红/空dim diff 着色。
fn renderEditDiffImpl(alloc: std.mem.Allocator, th: Theme, output_text: []const u8, out: *std.ArrayList(u8), opts: RenderOpts, plain: bool) !void {
    const diff = extractJsonStringField(output_text, "gitDiff") orelse {
        return renderGenericFold(alloc, th, output_text, out, opts);
    };
    // diff 是 JSON 转义字符串;就地 unescape 到临时 buf 再逐行着色。
    const unescaped = jsonUnescape(alloc, diff) catch return renderGenericFold(alloc, th, output_text, out, opts);
    defer alloc.free(unescaped);

    // 从结果里的 file_path/path 推语言(供 diff 行内语法高亮)。
    // NotebookEdit 等无法从扩展名(.ipynb)推断的工具,结果带显式 "lang" 字段 → 优先用它。
    const fpath = extractField(output_text, "file_path") orelse extractField(output_text, "path") orelse "";
    const explicit_lang = extractField(output_text, "lang");
    const lang = if (explicit_lang) |l| l else langFromPath(fpath);

    // tree-sitter 高亮:从旁路缓存按 tool_id 取新文件全文 → 整文件解析 → 按行 span 索引。
    // 命中失败/不支持语言/解析失败 → hl_opt 保持 null,appendDiffLine 退回关键字表(零回归)。
    var hl_opt: ?highlight.Highlights = null;
    defer if (hl_opt) |*h| h.deinit();
    if (opts.edit_hl_cache) |cache| {
        if (cache.get(opts.tool_id)) |entry| {
            // ts.Lang:显式 lang 字段优先(langFromTsName),否则按文件扩展名。
            const tslang_opt = if (explicit_lang) |l| tsLangFromName(l) else ts.Lang.fromPath(fpath);
            if (tslang_opt) |tslang| {
                hl_opt = highlight.highlightFile(alloc, entry.new, tslang) catch null;
            }
        }
    }
    const hl_ptr: ?*const highlight.Highlights = if (hl_opt) |*h| h else null;

    const limit: u16 = if (opts.verbose or opts.transcript) std.math.maxInt(u16) else opts.max_output_lines;
    var shown: u16 = 0;
    var total: u16 = 0;
    var pos: usize = 0;
    // 行号跟踪:从 @@ -old_start,+new_start @@ 解析,逐行推进。
    var old_ln: usize = 0;
    var new_ln: usize = 0;
    while (pos < unescaped.len) {
        const eol = std.mem.indexOfScalarPos(u8, unescaped, pos, '\n') orelse unescaped.len;
        const line = unescaped[pos..eol];
        pos = eol + 1;

        if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---")) continue;
        if (std.mem.startsWith(u8, line, "@@")) {
            parseHunkHeader(line, &old_ln, &new_ln); // 设置本 hunk 起始行号
            continue;
        }
        total += 1;
        if (opts.collapsed and shown >= limit) continue;

        const kind: DiffLineKind = if (line.len > 0 and line[0] == '+')
            .add
        else if (line.len > 0 and line[0] == '-')
            .del
        else
            .ctx;
        // 行号:add 用 new、del 用 old、ctx 两者都推进(gutter 显对应侧)。
        const num: usize = switch (kind) {
            .add => new_ln,
            .del => old_ln,
            .ctx => new_ln,
        };
        try appendDiffLine(alloc, th, out, kind, num, line, lang, opts.cols, plain, hl_ptr);
        switch (kind) {
            .add => new_ln += 1,
            .del => old_ln += 1,
            .ctx => {
                old_ln += 1;
                new_ln += 1;
            },
        }
        shown += 1;
    }
    if (opts.collapsed and total > limit) {
        try out.appendSlice(alloc, "  ");
        try out.appendSlice(alloc, th.dim);
        try out.print(alloc, "… +{d} lines", .{total - limit}); // 对齐 cc DIFF#8:`… +N lines`
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
    }
}

const DiffLineKind = enum { add, del, ctx };

/// 渲染一条 diff 行:`<行号> <bg 色块>{sign+content}<reset>`。
/// theme 有 diff 背景(256/truecolor)→ 整段套背景;否则纯前景(basic_16/mono)。
/// 前导 "  " 缩进交给 appendWithGutter 处理(它会剥掉重套 ⎿)。
/// 渲染一条 diff 行:`<bg 色块>{行号 sign content <行尾填充>}<reset>`(整行矩形,对齐 CC)。
/// theme 有 diff 背景(256/truecolor)→ 行号+sign+内容+行尾填充全在同一背景块,padEnd 到列宽
/// 成矩形;否则纯前景(basic_16/mono),不填充空块。
/// 前导 "  " 缩进交给 appendWithGutter 处理(它剥掉重套 ⎿,占 5 列)。cols 为终端宽,
/// 内容区可用宽 = cols - 5(gutter 缩进)。
fn appendDiffLine(alloc: std.mem.Allocator, th: Theme, out: *std.ArrayList(u8), kind: DiffLineKind, num: usize, line: []const u8, lang: []const u8, cols: u16, plain: bool, hl: ?*const highlight.Highlights) !void {
    // plain(Write 纯新建):无 +/- sign、无 add 背景——只 `行号 内容`(对齐 cc DIFF#8b)。
    if (plain) {
        const content = if (line.len > 0 and (line[0] == '+' or line[0] == '-' or line[0] == ' '))
            line[1..]
        else
            line;
        try out.appendSlice(alloc, "  ");
        var num_buf: [8]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d:>4} ", .{num}) catch "   ? ";
        try out.appendSlice(alloc, th.dim);
        try out.appendSlice(alloc, num_str);
        try out.appendSlice(alloc, th.reset);
        try colorLineContent(alloc, th, out, content, lang, "", hl, num, kind);
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
        return;
    }
    const bg: []const u8 = switch (kind) {
        .add => th.diff_add_bg,
        .del => th.diff_del_bg,
        .ctx => "",
    };
    const sign_fg: []const u8 = switch (kind) {
        .add => th.success,
        .del => th.danger,
        .ctx => th.dim,
    };
    const sign: u8 = if (line.len > 0) line[0] else ' ';
    const content = if (line.len > 0) line[1..] else line;

    // 前导 2 空格(gutter 会剥掉换成 ⎿ 缩进)。
    try out.appendSlice(alloc, "  ");

    // 背景块从行号开始(对齐 CC:行号也在块内)。
    try out.appendSlice(alloc, bg);

    // 行号列(右对齐 4 宽 + 1 空格 = 5 显示列;dim 但在 bg 上)。
    var num_buf: [8]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d:>4} ", .{num}) catch "   ? ";
    try out.appendSlice(alloc, th.dim);
    try out.appendSlice(alloc, num_str);
    // sign 字符:实色(+绿/-红/空 dim),坐在背景块上。注意先 reset dim 再上 sign_fg。
    try out.appendSlice(alloc, th.reset);
    try out.appendSlice(alloc, bg);
    try out.appendSlice(alloc, sign_fg);
    try out.append(alloc, sign);

    // 内容:语法高亮(bg-aware)。base = bg + (del 行整体 DIM)。高亮内部每 token 后 RESET+base,
    // 背景连续;高亮结束**不 reset**,留着接行尾填充。
    var base_buf: std.ArrayList(u8) = .empty;
    defer base_buf.deinit(alloc);
    try base_buf.appendSlice(alloc, bg);
    if (kind == .del) try base_buf.appendSlice(alloc, th.dim);
    try out.appendSlice(alloc, base_buf.items); // 内容前先铺一次 base(sign 后的起点)
    try colorLineContent(alloc, th, out, content, lang, base_buf.items, hl, num, kind);

    // 行尾填充:仅当有背景色(256/truecolor)。padEnd 到内容区可用宽(cols - 5 gutter 缩进),
    // 让背景铺满成矩形。已写显示宽 = 行号 5 + sign 1 + content 显示宽。
    if (bg.len > 0 and cols > 5) {
        const avail: usize = @as(usize, cols) - 5;
        const used: usize = 5 + 1 + term.displayWidth(content);
        if (used < avail) {
            try out.appendSlice(alloc, bg); // 确保填充段背景在(防高亮末尾状态偏移)
            var i: usize = 0;
            while (i < avail - used) : (i += 1) try out.append(alloc, ' ');
        }
    }
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');
}

/// 给 diff 行内容着色。优先 tree-sitter span(add/ctx 行,缓存命中且行文本字节匹配),
/// 否则退回关键字表 highlightCodeLine(del 行/无缓存/不匹配 → 零回归)。
/// num = 该行行号(add/ctx 的 new 行号);base = token 间重铺的底色(含 bg + del 的 dim)。
fn colorLineContent(
    alloc: std.mem.Allocator,
    th: Theme,
    out: *std.ArrayList(u8),
    content: []const u8,
    lang: []const u8,
    base: []const u8,
    hl: ?*const highlight.Highlights,
    num: usize,
    kind: DiffLineKind,
) !void {
    // tree-sitter span 路径:仅 add/ctx(在新文件,有 new 行号)且行文本与缓存内容字节相等。
    if (hl) |h| {
        if (kind != .del) {
            if (h.textForLine(num)) |file_line| {
                if (std.mem.eql(u8, file_line, content)) {
                    try renderSpans(alloc, th, out, content, h.spansForLine(num), base);
                    return;
                }
            }
        }
    }
    // 退回关键字表(bg-aware)。
    var st: render_mod.HlState = .{};
    try render_mod.highlightCodeLine(content, lang, &st, base, out, alloc, th.syntax);
}

/// 按 span 给一行着色(bg-aware,仿关键字表的 token 着色纪律):
/// span 内字节发 groupColor → 内容 → RESET+base(保背景连续);span 外字节用 base。
/// 结尾**不 reset**(留给行尾填充)。span 是相对行首的字节偏移,有序不重叠。
fn renderSpans(
    alloc: std.mem.Allocator,
    th: Theme,
    out: *std.ArrayList(u8),
    content: []const u8,
    spans: []const highlight.Span,
    base: []const u8,
) !void {
    var col: usize = 0;
    for (spans) |s| {
        const sstart = @min(@as(usize, s.start), content.len);
        const send = @min(@as(usize, s.end), content.len);
        if (sstart >= send) continue;
        // span 前的未着色字节(用 base 底色)。
        if (sstart > col) try out.appendSlice(alloc, content[col..sstart]);
        // span 着色:groupColor → 内容 → reset → 重铺 base。
        const color = groupColor(th, s.group);
        if (color.len > 0) try out.appendSlice(alloc, color);
        try out.appendSlice(alloc, content[sstart..send]);
        try out.appendSlice(alloc, th.reset);
        try out.appendSlice(alloc, base);
        col = send;
    }
    // 行尾剩余未着色字节。
    if (col < content.len) try out.appendSlice(alloc, content[col..]);
}

/// HighlightGroup → ANSI 前景色,**从 th.syntax 取**(主题化、随终端能力变化)。
/// comment 组空时回退 th.dim(basic_16 下 syntax.comment="";256/truecolor 用调色板绿)。
fn groupColor(th: Theme, group: highlight.Group) []const u8 {
    return switch (group) {
        .keyword => th.syntax.keyword,
        .string => th.syntax.string,
        .number => th.syntax.number,
        .constant => th.syntax.constant,
        .comment => if (th.syntax.comment.len > 0) th.syntax.comment else th.dim,
        .function => th.syntax.function,
        .type => th.syntax.type,
        .variable => th.syntax.variable,
        .operator => th.syntax.operator,
        .punctuation => th.syntax.punctuation,
        .none => "",
    };
}

/// 语言名(结果 "lang" 字段)→ ts.Lang。供 NotebookEdit 等显式带语言的工具。
fn tsLangFromName(name: []const u8) ?ts.Lang {
    const Pair = struct { n: []const u8, l: ts.Lang };
    const table = [_]Pair{
        .{ .n = "zig", .l = .zig },
        .{ .n = "python", .l = .python },
        .{ .n = "typescript", .l = .typescript },
        .{ .n = "tsx", .l = .tsx },
        .{ .n = "c", .l = .c },
        .{ .n = "bash", .l = .bash },
    };
    for (table) |p| {
        if (std.mem.eql(u8, name, p.n)) return p.l;
    }
    return null;
}

/// 文件扩展名 → 语法高亮语言标记(render.classifyLang 能认的名)。
fn langFromPath(path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "";
    const ext = path[dot + 1 ..];
    const map = .{
        .{ "zig", "zig" },     .{ "py", "python" }, .{ "js", "js" },   .{ "ts", "ts" },
        .{ "jsx", "jsx" },     .{ "tsx", "tsx" },   .{ "rs", "rust" }, .{ "go", "go" },
        .{ "c", "c" },         .{ "h", "c" },       .{ "cpp", "cpp" }, .{ "cc", "cpp" },
        .{ "hpp", "cpp" },     .{ "java", "java" }, .{ "sh", "bash" }, .{ "bash", "bash" },
        .{ "json", "json" },
    };
    inline for (map) |m| {
        if (std.mem.eql(u8, ext, m[0])) return m[1];
    }
    return "";
}

/// 解析 `@@ -old_start,old_lines +new_start,new_lines @@` 的起始行号。
fn parseHunkHeader(line: []const u8, old_ln: *usize, new_ln: *usize) void {
    // 找 '-' 后的数字 = old_start;'+' 后的数字 = new_start。
    if (std.mem.indexOfScalar(u8, line, '-')) |dash| {
        old_ln.* = parseLeadingUint(line[dash + 1 ..]) orelse old_ln.*;
    }
    if (std.mem.indexOfScalar(u8, line, '+')) |plus| {
        new_ln.* = parseLeadingUint(line[plus + 1 ..]) orelse new_ln.*;
    }
}

fn parseLeadingUint(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i == 0) return null;
    return std.fmt.parseInt(usize, s[0..i], 10) catch null;
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

/// WebFetch 结果:人话摘要 `Received N bytes[ (truncated)]`(对齐 cc `Received N bytes (status)`,
/// zig 结果 JSON 无 HTTP status 故略);verbose/transcript 展开正文 content。**绝不裸吐 JSON。**
fn renderWebFetchSummary(alloc: std.mem.Allocator, th: Theme, output_text: []const u8, out: *std.ArrayList(u8), opts: RenderOpts) !void {
    const bytes = extractNumberField(output_text, "bytes");
    const truncated = std.mem.indexOf(u8, output_text, "\"truncated\":true") != null;
    try out.appendSlice(alloc, "  ");
    try out.appendSlice(alloc, th.success);
    if (bytes) |b| {
        try out.print(alloc, "Received {d} bytes", .{b});
        if (truncated) try out.appendSlice(alloc, " (truncated)");
    } else {
        // 无 bytes 字段(异常结果)→ 仍给人话,不裸吐 JSON。
        try out.appendSlice(alloc, "Fetched");
    }
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');
    // verbose/transcript:展开抓取正文(content 字段),仍不裸吐整个 JSON。
    if (opts.verbose or opts.transcript) {
        if (extractField(output_text, "content")) |content| {
            const dec = jsonUnescape(alloc, content) catch null;
            defer if (dec) |d| alloc.free(d);
            const body = dec orelse content;
            // 折叠超长正文(用 renderGenericFold 套 condensed 行数)。
            var tmp: std.ArrayList(u8) = .empty;
            defer tmp.deinit(alloc);
            try tmp.appendSlice(alloc, body);
            try renderGenericFold(alloc, th, tmp.items, out, opts);
        }
    }
}

/// WebSearch 完成态(对齐 cc renderToolResultMessage):`Did N searches`。
/// N = output_text 里 `Web search results for query` 段数(每次搜索一段;子请求通常 1)。
/// verbose/transcript 才展开完整结果(链接 + 摘要)。
fn renderWebSearchSummary(alloc: std.mem.Allocator, th: Theme, output_text: []const u8, out: *std.ArrayList(u8), opts: RenderOpts) !void {
    var n: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, output_text, pos, "Web search results for query")) |i| : (pos = i + 1) n += 1;
    if (n == 0) n = 1; // 至少做了一次搜索
    var buf: [48]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "Did {d} search{s}", .{ n, if (n == 1) @as([]const u8, "") else "es" }) catch "Did 1 search";
    try out.appendSlice(alloc, "  ");
    try out.appendSlice(alloc, th.success);
    try out.appendSlice(alloc, line);
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

/// cc 风格内联标题参数:`⏺ Tool(arg)` 括号里的内容(单行,无前缀符号)。
/// 对齐 cc:Write/Edit→文件 basename;Bash→命令首行;Read→basename;Grep/Glob→pattern;
/// WebFetch→域名;WebSearch→"query";其余→空(标题不带括号)。caller free。
fn headerArg(alloc: std.mem.Allocator, tool_name: []const u8, args: []const u8) ![]u8 {
    if (std.mem.eql(u8, tool_name, "Bash")) {
        if (extractField(args, "command")) |cmd| {
            const dec = try jsonUnescape(alloc, cmd);
            defer alloc.free(dec);
            return try alloc.dupe(u8, firstLine(dec));
        }
    } else if (std.mem.eql(u8, tool_name, "Read") or std.mem.eql(u8, tool_name, "Edit") or
        std.mem.eql(u8, tool_name, "Write") or std.mem.eql(u8, tool_name, "NotebookEdit"))
    {
        if (extractField(args, "file_path") orelse extractField(args, "path")) |p| {
            return try alloc.dupe(u8, basename(p)); // cc 用 basename,不显完整路径
        }
    } else if (std.mem.eql(u8, tool_name, "Grep") or std.mem.eql(u8, tool_name, "Glob")) {
        if (extractField(args, "pattern")) |p| return try alloc.dupe(u8, p);
    } else if (std.mem.eql(u8, tool_name, "WebFetch")) {
        if (extractField(args, "url")) |u| return try alloc.dupe(u8, u);
    } else if (std.mem.eql(u8, tool_name, "WebSearch")) {
        if (extractField(args, "query")) |q| return try std.fmt.allocPrint(alloc, "\"{s}\"", .{q});
    } else if (std.mem.eql(u8, tool_name, "Agent") or std.mem.eql(u8, tool_name, "Task")) {
        if (extractField(args, "subagent_type") orelse extractField(args, "description")) |d|
            return try alloc.dupe(u8, d);
    }
    return try alloc.dupe(u8, "");
}

/// 路径 basename(最后一个 / 后的部分;无 / 则原样)。
fn basename(p: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return p[i + 1 ..];
    return p;
}

/// 从 Write 结果 gitDiff 数 `+` 行(新写入行数,对齐 cc `Wrote N lines`)。失败返 0。
/// gitDiff 是 JSON 转义串,需先 unescape 再按真实换行分行。
fn countWrittenLines(alloc: std.mem.Allocator, output_text: []const u8) usize {
    const diff = extractJsonStringField(output_text, "gitDiff") orelse return 0;
    const un = jsonUnescape(alloc, diff) catch return 0;
    defer alloc.free(un);
    var n: usize = 0;
    var pos: usize = 0;
    while (pos < un.len) {
        const eol = std.mem.indexOfScalarPos(u8, un, pos, '\n') orelse un.len;
        const line = un[pos..eol];
        // `+` 开头但非 `+++`(文件头)= 新增行。
        if (line.len > 0 and line[0] == '+' and !(line.len >= 3 and line[1] == '+' and line[2] == '+')) n += 1;
        pos = eol + 1;
    }
    return n;
}

/// 根据工具名和参数 JSON 生成单行预览("$ cmd" / "📄 path" / 等)。caller free。
/// 不识别的工具 → 返回空 slice(预览行省略)。pub:类A 动态卡(render_region)复用。
pub fn toolPreviewPub(alloc: std.mem.Allocator, tool_name: []const u8, args: []const u8) ![]u8 {
    return toolPreview(alloc, tool_name, args);
}

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
            // 对齐 cc:Read 卡 ⎿ 行只显 basename,**无 📄 icon、无完整路径**(实测 `  ⎿  CLAUDE.md`)。
            return try alloc.dupe(u8, basename(p));
        }
    } else if (std.mem.eql(u8, tool_name, "Edit") or std.mem.eql(u8, tool_name, "Write") or std.mem.eql(u8, tool_name, "NotebookEdit")) {
        if (extractField(args, "file_path") orelse extractField(args, "path")) |p| {
            return try std.fmt.allocPrint(alloc, "± {s}", .{p});
        }
    } else if (std.mem.eql(u8, tool_name, "Grep") or std.mem.eql(u8, tool_name, "Glob")) {
        // 对齐 cc GrepTool/UI.tsx:`pattern: "<pat>"[, path: "<path>"]`(双引号包,非斜杠)。
        // 旧 `/{s}/` 会把以 / 开头/结尾的 pattern(如搜 "/v1/models")显示成 "//v1/models/"。
        if (extractField(args, "pattern")) |p| {
            if (extractField(args, "path")) |path| {
                return try std.fmt.allocPrint(alloc, "pattern: \"{s}\", path: \"{s}\"", .{ p, path });
            }
            return try std.fmt.allocPrint(alloc, "pattern: \"{s}\"", .{p});
        }
    } else if (std.mem.eql(u8, tool_name, "WebFetch")) {
        if (extractField(args, "url")) |u| {
            return try std.fmt.allocPrint(alloc, "↗ {s}", .{u});
        }
    } else if (std.mem.eql(u8, tool_name, "WebSearch")) {
        // 对齐 cc 标题参数:⏺ Web Search("query")。
        if (extractField(args, "query")) |q| {
            return try std.fmt.allocPrint(alloc, "\"{s}\"", .{q});
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

/// agent 进度树动作行标签:`Tool(arg)` 一行式(对齐 cc `⎿ Bash(git status)`)。
/// input 为工具原始 JSON(可能被上游截断)。识别不出关键参数 → 退回纯工具名。
/// caller free。复用 extractField/jsonUnescape/firstLine。
pub fn actionLabel(alloc: std.mem.Allocator, tool_name: []const u8, input: []const u8) ![]u8 {
    const arg: ?[]const u8 = blk: {
        if (std.mem.eql(u8, tool_name, "Bash")) break :blk extractField(input, "command");
        if (std.mem.eql(u8, tool_name, "Read") or std.mem.eql(u8, tool_name, "Edit") or
            std.mem.eql(u8, tool_name, "Write") or std.mem.eql(u8, tool_name, "NotebookEdit"))
            break :blk (extractField(input, "file_path") orelse extractField(input, "path"));
        if (std.mem.eql(u8, tool_name, "Grep") or std.mem.eql(u8, tool_name, "Glob"))
            break :blk extractField(input, "pattern");
        if (std.mem.eql(u8, tool_name, "WebFetch")) break :blk extractField(input, "url");
        break :blk null;
    };
    if (arg) |a| {
        // command 可能含转义(&&、换行);unescape + 只取首行,再按**显示宽度**截断到 ~48 列
        // (用 layout.truncate:char-boundary-safe + CJK 宽字符正确,绝不切碎 UTF-8)。
        const dec = try jsonUnescape(alloc, a);
        defer alloc.free(dec);
        const one = firstLine(dec);
        const trunc = try layout.truncate(alloc, one, 48, "…");
        defer if (trunc.ptr != one.ptr) alloc.free(trunc); // truncate 不超长时借用 one,不能 free
        return try std.fmt.allocPrint(alloc, "{s}({s})", .{ tool_name, trunc });
    }
    return try alloc.dupe(u8, tool_name);
}

/// agent 进度树/transcript 动作行专用:`Tool: arg` 冒号式(对齐 cc `Read: /path`)。
/// 与 actionLabel(`Tool(arg)`)区别仅在分隔符。Read 用全路径(实拍 `Read: /Users/.../mod0.py`)。
/// 拿不到参数则纯工具名。caller free。
pub fn actionLabelColon(alloc: std.mem.Allocator, tool_name: []const u8, input: []const u8) ![]u8 {
    const arg: ?[]const u8 = blk: {
        if (std.mem.eql(u8, tool_name, "Bash")) break :blk extractField(input, "command");
        if (std.mem.eql(u8, tool_name, "Read") or std.mem.eql(u8, tool_name, "Edit") or
            std.mem.eql(u8, tool_name, "Write") or std.mem.eql(u8, tool_name, "NotebookEdit"))
            break :blk (extractField(input, "file_path") orelse extractField(input, "path"));
        if (std.mem.eql(u8, tool_name, "Grep") or std.mem.eql(u8, tool_name, "Glob"))
            break :blk extractField(input, "pattern");
        if (std.mem.eql(u8, tool_name, "WebFetch")) break :blk extractField(input, "url");
        break :blk null;
    };
    if (arg) |a| {
        const dec = try jsonUnescape(alloc, a);
        defer alloc.free(dec);
        const one = firstLine(dec);
        const trunc = try layout.truncate(alloc, one, 60, "…");
        defer if (trunc.ptr != one.ptr) alloc.free(trunc);
        return try std.fmt.allocPrint(alloc, "{s}: {s}", .{ tool_name, trunc });
    }
    return try alloc.dupe(u8, tool_name);
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

/// 提取 JSON 顶层字段的**裸值**(bool/number/到 `,` 或 `}` 为止),不要求引号包裹。
/// 用于 `"killed":true` / `"cells_after":5` / `"count":3` 这类非 string 值。
fn extractRawField(args: []const u8, key: []const u8) ?[]const u8 {
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
    while (p < args.len and args[p] != ',' and args[p] != '}' and args[p] != ' ') : (p += 1) {}
    if (p == start) return null;
    return args[start..p];
}

/// 这些工具有副作用、返回 JSON,需提关键字段拼人话(绝不裸吐 JSON),由 renderJsonToolSummary 处理。
fn isJsonSummaryTool(tool_name: []const u8) bool {
    const names = [_][]const u8{
        "NotebookEdit",         "KillShell",           "Monitor",
        "CronCreate",           "CronDelete",          "CronList",
        "EnterWorktree",        "ExitWorktree",        "PushNotification",
        "ListMcpResourcesTool", "ReadMcpResourceTool", "ToolSearch",
    };
    for (names) |n| if (std.mem.eql(u8, tool_name, n)) return true;
    return false;
}

/// 把有副作用工具的 JSON 结果提成一行人话。提不到关键字段 → 通用 "done" 兜底(不吐 JSON)。
fn renderJsonToolSummary(
    alloc: std.mem.Allocator,
    th: Theme,
    tool_name: []const u8,
    output_text: []const u8,
    out: *std.ArrayList(u8),
    opts: RenderOpts,
) !void {
    var line_buf: [256]u8 = undefined;
    const line: []const u8 = blk: {
        if (std.mem.eql(u8, tool_name, "NotebookEdit")) {
            const path = extractJsonStringField(output_text, "path") orelse "notebook";
            const mode = extractJsonStringField(output_text, "mode") orelse "edit";
            break :blk std.fmt.bufPrint(&line_buf, "{s} {s}", .{ mode, path }) catch "edited notebook";
        }
        if (std.mem.eql(u8, tool_name, "KillShell")) {
            const status = extractJsonStringField(output_text, "status") orelse "killed";
            break :blk std.fmt.bufPrint(&line_buf, "shell {s}", .{status}) catch "killed shell";
        }
        if (std.mem.eql(u8, tool_name, "Monitor")) {
            const desc = extractJsonStringField(output_text, "description") orelse "";
            if (desc.len > 0)
                break :blk std.fmt.bufPrint(&line_buf, "monitoring: {s}", .{desc}) catch "monitor started"
            else
                break :blk "monitor started";
        }
        if (std.mem.eql(u8, tool_name, "CronCreate")) {
            const rec = extractRawField(output_text, "recurring") orelse "false";
            break :blk std.fmt.bufPrint(&line_buf, "scheduled (recurring={s})", .{rec}) catch "scheduled";
        }
        if (std.mem.eql(u8, tool_name, "CronDelete")) {
            const del = extractRawField(output_text, "deleted") orelse "false";
            break :blk std.fmt.bufPrint(&line_buf, "deleted={s}", .{del}) catch "deleted";
        }
        if (std.mem.eql(u8, tool_name, "CronList")) {
            const cnt = extractRawField(output_text, "count") orelse "0";
            break :blk std.fmt.bufPrint(&line_buf, "{s} scheduled job(s)", .{cnt}) catch "listed jobs";
        }
        if (std.mem.eql(u8, tool_name, "EnterWorktree")) {
            const wt = extractJsonStringField(output_text, "worktree") orelse "worktree";
            break :blk std.fmt.bufPrint(&line_buf, "entered {s}", .{wt}) catch "entered worktree";
        }
        if (std.mem.eql(u8, tool_name, "ExitWorktree")) {
            break :blk "exited worktree";
        }
        if (std.mem.eql(u8, tool_name, "PushNotification")) {
            const sent = extractRawField(output_text, "sent") orelse "true";
            break :blk if (std.mem.eql(u8, sent, "true")) "notification sent" else "notification not sent";
        }
        if (std.mem.eql(u8, tool_name, "ToolSearch")) {
            // 返回 <functions>...schema;数 <function> 个数。
            var n: usize = 0;
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, output_text, pos, "<function>")) |i| : (pos = i + 1) n += 1;
            break :blk std.fmt.bufPrint(&line_buf, "activated {d} tool(s)", .{n}) catch "activated tools";
        }
        if (std.mem.eql(u8, tool_name, "ListMcpResourcesTool") or std.mem.eql(u8, tool_name, "ReadMcpResourceTool")) {
            break :blk "MCP resource(s)";
        }
        break :blk "done";
    };
    try appendLine(alloc, out, th.success, line, th.reset);
    // verbose/transcript:展开原始 JSON 供排查(折叠)。
    if (opts.verbose or opts.transcript) {
        try renderGenericFold(alloc, th, output_text, out, opts);
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const capture = @import("../test_capture.zig");

test "renderStart: Bash 工具(内联参数标题)" {
    const th = theme_mod.monochrome;
    const s = try renderStart(testing.allocator, th, "Bash", "{\"command\":\"git status\"}");
    defer testing.allocator.free(s);
    // cc 风格单行标题:`* Bash(git status)`(monochrome icon_act="*")。
    try capture.expectContains(s, "Bash(git status)");
    try capture.expectNoAnsi(s);
}

test "renderStart: Read 工具内联 basename" {
    const th = theme_mod.dark;
    const s = try renderStart(testing.allocator, th, "Read", "{\"file_path\":\"/etc/hosts\"}");
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Read(hosts)"); // cc 用 basename,非完整路径
}

test "renderStart: Edit 内联 basename + 标题 Update(对齐 cc)" {
    const th = theme_mod.monochrome;
    const s = try renderStart(testing.allocator, th, "Edit", "{\"file_path\":\"/x.zig\",\"old_string\":\"a\",\"new_string\":\"b\"}");
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Update(x.zig)"); // cc:Edit 卡标题=Update(file),basename 非全路径
}

test "renderResult: ok + ✓ + 耗时" {
    const th = theme_mod.monochrome;
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"ls\"}", "file.txt\n", .ok, 1500, .{ .transcript = true });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "+ 1.5s"); // monochrome icon_check="+"
    try capture.expectContains(s, "file.txt");
}

test "renderResult: err + ✗" {
    const th = theme_mod.monochrome;
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"false\"}", "exit 1\n", .err, 200, .{ .transcript = true });
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
    try capture.expectContains(s, "… +5 lines");
    // line6 应该被折叠
    try testing.expect(std.mem.indexOf(u8, s, "line6") == null);
}

test "renderResult: collapsed=false 全部显示" {
    const th = theme_mod.monochrome;
    const long = "a\nb\nc\nd\ne\nf\ng\n";
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"x\"}", long, .ok, 100, .{ .collapsed = false, .max_output_lines = 3, .transcript = true });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "g");
    try testing.expect(std.mem.indexOf(u8, s, "more lines") == null);
}

test "renderResult: cols 右对齐状态符" {
    const th = theme_mod.monochrome;
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"x\"}", "", .ok, 100, .{ .cols = 60, .transcript = true });
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
    const s = try renderResult(testing.allocator, th, "Edit", "{\"file_path\":\"/x\"}", out_json, .ok, 100, .{ .transcript = true });
    defer testing.allocator.free(s);
    // 内容词出现(注:行内语法高亮会在词间插 ANSI,故断言单词而非整句)。
    try capture.expectContains(s, "line");
    try capture.expectContains(s, "old");
    // diff 头(---/+++/@@)不作为内容行显示。
    try testing.expect(std.mem.indexOf(u8, s, "+++") == null);
    // 着色:+ 行带 success 色(green),- 行带 danger 色(red)。
    try testing.expect(std.mem.indexOf(u8, s, th.success) != null);
    try testing.expect(std.mem.indexOf(u8, s, th.danger) != null);
    // 行号列出现(新格式)。
    try capture.expectContains(s, "1");
}

test "renderResult: diff 背景色块(truecolor)+ 行号 + del DIM" {
    const th = theme_mod.select(.dark, .truecolor);
    const out_json = "{\"success\":true,\"path\":\"/x.zig\",\"gitDiff\":\"--- a/x.zig\\n+++ b/x.zig\\n@@ -1,1 +1,1 @@\\n-const b = 2;\\n+const b = 20;\\n\"}";
    const s = try renderResult(testing.allocator, th, "Edit", "{\"file_path\":\"/x.zig\"}", out_json, .ok, 100, .{ .transcript = true });
    defer testing.allocator.free(s);
    // add 行带绿背景块(truecolor RGB),del 行带红背景块。
    try testing.expect(std.mem.indexOf(u8, s, "48;2;33;58;43") != null); // add bg #213A2B
    try testing.expect(std.mem.indexOf(u8, s, "48;2;74;34;29") != null); // del bg #4A221D
    // del 行整体 DIM(\x1b[2m,防删除色被语法盖)。
    try testing.expect(std.mem.indexOf(u8, s, th.dim) != null);
    // 行内语法高亮(truecolor theme):const→keyword RGB 紫(#C586C0),20→number RGB(#B5CEA8)。
    // (此用例无 edit_hl_cache → 走关键字表 fallback,高亮色现也从 th.syntax 取,故是 truecolor RGB。)
    try testing.expect(std.mem.indexOf(u8, s, "38;2;197;134;192") != null); // keyword 紫
    try testing.expect(std.mem.indexOf(u8, s, "38;2;181;206;168") != null); // number(20)绿
}

test "renderResult: diff 整块矩形(cols 填充背景到行尾,对齐 CC)" {
    const th = theme_mod.select(.dark, .truecolor);
    const out_json = "{\"success\":true,\"path\":\"/x.zig\",\"gitDiff\":\"--- a/x.zig\\n+++ b/x.zig\\n@@ -1,1 +1,1 @@\\n+const b = 20;\\n\"}";
    // cols=40 → 内容区可用宽 = 40-5(gutter)=35。add 行内容显示宽 < 35 → 应 padEnd 空格填充。
    const s = try renderResult(testing.allocator, th, "Edit", "{\"file_path\":\"/x.zig\"}", out_json, .ok, 100, .{ .cols = 40, .transcript = true });
    defer testing.allocator.free(s);
    // 矩形特征:背景块开启后,行尾有填充空格(背景延伸),最后才 reset。
    // 验证:add bg 序列出现,且其后(同一行内)有连续空格填充到接近列宽。
    const add_bg = "48;2;33;58;43";
    const bg_pos_opt = std.mem.indexOf(u8, s, add_bg);
    try testing.expect(bg_pos_opt != null);
    const bg_pos = bg_pos_opt.?;
    // 从 bg 起到行尾(\n)之间,应有一段 >=4 连续空格(填充证据;内容 "const b = 20;" 约 13 列,
    // 行号5+sign1+13=19,填到 35 → 约 16 空格填充)。
    const nl = std.mem.indexOfScalarPos(u8, s, bg_pos, '\n') orelse s.len;
    const seg = s[bg_pos..nl];
    try testing.expect(std.mem.indexOf(u8, seg, "    ") != null); // >=4 连续空格 = 填充证据
}

test "renderResult: diff basic_16 无背景块只前景(对齐 metacode fg-only)" {
    const th = theme_mod.select(.dark, .basic_16);
    const out_json = "{\"success\":true,\"path\":\"/x.zig\",\"gitDiff\":\"--- a/x.zig\\n+++ b/x.zig\\n@@ -1,1 +1,1 @@\\n-a\\n+b\\n\"}";
    const s = try renderResult(testing.allocator, th, "Edit", "{\"file_path\":\"/x.zig\"}", out_json, .ok, 100, .{ .transcript = true });
    defer testing.allocator.free(s);
    // 16 色:不出现任何背景转义(48;2 / 48;5)。
    try testing.expect(std.mem.indexOf(u8, s, "48;2;") == null);
    try testing.expect(std.mem.indexOf(u8, s, "48;5;") == null);
    // 仍有 +绿/-红 前景。
    try testing.expect(std.mem.indexOf(u8, s, th.success) != null);
    try testing.expect(std.mem.indexOf(u8, s, th.danger) != null);
}

test "renderResult: Edit 无 gitDiff → 退回通用折叠" {
    const th = theme_mod.monochrome;
    const out_json = "{\"success\":true,\"path\":\"/x\"}";
    const s = try renderResult(testing.allocator, th, "Write", "{\"file_path\":\"/x\"}", out_json, .ok, 100, .{ .transcript = true });
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
    const s = try renderResult(testing.allocator, th, "Grep", "{\"pattern\":\"foo\"}", out, .ok, 50, .{ .verbose = true, .transcript = true });
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
    const s = try renderResult(testing.allocator, th, "Read", "{\"file_path\":\"/x.png\"}", out, .ok, 30, .{ .transcript = true });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Read image (512 KB)");
}

test "renderResult: WebFetch 人话摘要(真 JSON 契约,不裸吐)" {
    const th = theme_mod.monochrome;
    // 真 WebFetch 结果 JSON 形态(web_fetch.zig):{url,bytes,truncated,content}。
    const out = "{\"url\":\"http://x\",\"bytes\":528,\"truncated\":false,\"content\":\"Example Domain body text\"}";
    const s = try renderResult(testing.allocator, th, "WebFetch", "{\"url\":\"http://x\"}", out, .ok, 80, .{});
    defer testing.allocator.free(s);
    // 人话摘要 `Received N bytes`(对齐 cc),condensed 不展开正文。
    try capture.expectContains(s, "Received 528 bytes");
    // **绝不裸吐 JSON 字段名**(反模式:之前裸打 output_text 首行=整个 JSON)。
    try testing.expect(std.mem.indexOf(u8, s, "\"bytes\"") == null);
    try testing.expect(std.mem.indexOf(u8, s, "\"content\"") == null);
    // condensed:不展开正文。
    try testing.expect(std.mem.indexOf(u8, s, "Example Domain body text") == null);
}

test "renderResult: WebFetch truncated 标注 + verbose 展开正文" {
    const th = theme_mod.monochrome;
    const out = "{\"url\":\"http://x\",\"bytes\":99999,\"truncated\":true,\"content\":\"long page body\"}";
    const s = try renderResult(testing.allocator, th, "WebFetch", "{\"url\":\"http://x\"}", out, .ok, 80, .{ .verbose = true });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Received 99999 bytes");
    try capture.expectContains(s, "(truncated)");
    try capture.expectContains(s, "long page body"); // verbose 展开正文
    try testing.expect(std.mem.indexOf(u8, s, "\"content\"") == null); // 仍不裸吐字段名
}

test "renderResult: Bash 仍走通用折叠(无专用渲染器)" {
    const th = theme_mod.monochrome;
    const out = "a\nb\nc\nd\ne\nf\ng\n";
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"x\"}", out, .ok, 10, .{ .max_output_lines = 3 });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "a");
    try capture.expectContains(s, "… +4 lines");
}

test "renderResult: verbose 关折叠(通用)" {
    const th = theme_mod.monochrome;
    const out = "a\nb\nc\nd\ne\nf\ng\n";
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"x\"}", out, .ok, 10, .{ .max_output_lines = 3, .verbose = true, .transcript = true });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "g"); // 全显示
    try testing.expect(std.mem.indexOf(u8, s, "more lines") == null);
}

test "VISUAL demo: Edit diff(TUI_DEMO=1)" {
    if (std.c.getenv("TUI_DEMO") == null) return error.SkipZigTest;
    const th = theme_mod.select(.dark, .truecolor); // 真彩:看背景色块 + 行内高亮
    const out_json = "{\"success\":true,\"path\":\"/x.zig\",\"gitDiff\":\"--- a/x.zig\\n+++ b/x.zig\\n@@ -1,3 +1,3 @@\\n const a = 1;\\n-const b = 2;\\n+const b = 20;\\n const c = 3;\\n\"}";
    const s = try renderResult(testing.allocator, th, "Edit", "{\"file_path\":\"/x.zig\"}", out_json, .ok, 88, .{ .cols = 60, .transcript = true });
    defer testing.allocator.free(s);
    std.debug.print("\n{s}\n", .{s});
}

// ---- opt-out 不变量(无裸 JSON / hidden 工具结果不进消息流)----

test "resultRenderMode: 故意 hidden vs 应显示" {
    // 故意 hidden:Task 族(Task 面板)、plan 模式(模式切换)、AskUserQuestion(交互 UI)、
    // Skill(结果内联进对话文本)。
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("Task"));
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("TaskCreate"));
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("TaskOutput"));
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("EnterPlanMode"));
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("ExitPlanMode"));
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("AskUserQuestion"));
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("Skill"));
    // 完全未知的工具 hidden(绝不裸吐 JSON)。
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("SomeFutureTool"));
    // 有专用渲染器的工具 → summary。
    try testing.expectEqual(ResultRenderMode.summary, resultRenderMode("Bash"));
    try testing.expectEqual(ResultRenderMode.summary, resultRenderMode("Edit"));
    // 回归守卫:WebSearch 现为普通函数工具,必须 summary(否则 agent_loop 连 ⏺ 起始卡
    // 都跳过 → TUI 完全不显示,2026-06-04 实测过的 bug)。
    try testing.expectEqual(ResultRenderMode.summary, resultRenderMode("WebSearch"));
    try testing.expectEqual(ResultRenderMode.summary, resultRenderMode("WebFetch"));
    // 有副作用、返回 JSON 的工具:有人话渲染器 → summary(同样曾被误吞)。
    try testing.expectEqual(ResultRenderMode.summary, resultRenderMode("NotebookEdit"));
    try testing.expectEqual(ResultRenderMode.summary, resultRenderMode("KillShell"));
    try testing.expectEqual(ResultRenderMode.summary, resultRenderMode("Monitor"));
    try testing.expectEqual(ResultRenderMode.summary, resultRenderMode("CronCreate"));
    try testing.expectEqual(ResultRenderMode.summary, resultRenderMode("EnterWorktree"));
    try testing.expectEqual(ResultRenderMode.summary, resultRenderMode("PushNotification"));
    try testing.expectEqual(ResultRenderMode.summary, resultRenderMode("ToolSearch"));
    try testing.expectEqual(ResultRenderMode.summary, resultRenderMode("ListMcpResourcesTool"));
}

test "showStartCard: Task/Agent 起始卡可见但结果仍 hidden(#8)" {
    // #8 修复:起始卡门控与结果门控分离。Task/Agent 必须打起始卡(用户看到 subagent 启动),
    // 但结果体仍 hidden(状态在 Task 面板)。
    try testing.expect(showStartCard("Task"));
    try testing.expect(showStartCard("Agent"));
    // 结果侧不变:Task 结果仍 hidden。
    try testing.expectEqual(ResultRenderMode.hidden, resultRenderMode("Task"));
    // 走专门 UI 的工具:不打起始卡。
    try testing.expect(!showStartCard("AskUserQuestion"));
    try testing.expect(!showStartCard("EnterPlanMode"));
    try testing.expect(!showStartCard("ExitPlanMode"));
    try testing.expect(!showStartCard("Skill"));
    // 普通可见工具:打起始卡(沿用 resultRenderMode != hidden)。
    try testing.expect(showStartCard("Bash"));
    try testing.expect(showStartCard("WebSearch"));
    // 完全未知工具:不打(resultRenderMode hidden)。
    try testing.expect(!showStartCard("SomeFutureTool"));
}

test "renderResult: Bash 非零 exit_code 头部降级 ✗(#3)" {
    // #3 修复:Bash 把非零 exit 包成正常 JSON(is_error=false → kind=.ok),但头部图标
    // 应降级 ✓→✗ 给失败可视提示。不碰 is_error(它进 API tool_result)。
    const th = theme_mod.monochrome; // icon_check="+" icon_cross="X"
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"exit 3\"}", "{\"stdout\":\"\",\"stderr\":\"\",\"exit_code\":3}", .ok, 100, .{ .transcript = true });
    defer testing.allocator.free(s);
    // 头部应是 X(cross)不是 +(check)——尽管 kind=.ok。
    try testing.expect(std.mem.indexOf(u8, s, "X 0.1s") != null);
    try testing.expect(std.mem.indexOf(u8, s, "+ 0.1s") == null);
}

test "renderResult: Bash exit_code=0 头部仍 ✓(#3 不误伤)" {
    const th = theme_mod.monochrome;
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"true\"}", "{\"stdout\":\"ok\\n\",\"exit_code\":0}", .ok, 100, .{ .transcript = true });
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "+ 0.1s") != null); // 仍 check
    try testing.expect(std.mem.indexOf(u8, s, "X 0.1s") == null);
}

test "renderResult: auto_backgrounded 头部中性 + ▶ 提示不裸吐 JSON(#4)" {
    // #4 修复:超 15s 转后台,头部非 ✓(中性 icon_act);body 渲染 ▶ 提示行,不裸吐 JSON。
    const th = theme_mod.monochrome; // icon_act="*"
    const json = "{\"auto_backgrounded\":true,\"job_id\":\"abc123\",\"partial_stdout\":\"\",\"partial_stderr\":\"\",\"note\":\"Command exceeded 15s; moved to background.\"}";
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"sleep 20\"}", json, .ok, 15100, .{ .transcript = true });
    defer testing.allocator.free(s);
    // 头部:中性 *(icon_act)不是 +(check)。
    try testing.expect(std.mem.indexOf(u8, s, "* 15.1s") != null);
    try testing.expect(std.mem.indexOf(u8, s, "+ 15.1s") == null);
    // body:▶ 后台提示 + job id,且不裸吐 auto_backgrounded JSON。
    try testing.expect(std.mem.indexOf(u8, s, "moved to background job abc123") != null);
    try testing.expect(std.mem.indexOf(u8, s, "auto_backgrounded") == null);
}

test "renderJsonToolSummary: 提人话不裸吐 JSON" {
    const a = testing.allocator;
    const th = theme_mod.monochrome;
    const cases = [_]struct { name: []const u8, json: []const u8, want: []const u8 }{
        .{ .name = "NotebookEdit", .json = "{\"success\":true,\"path\":\"nb.ipynb\",\"mode\":\"replace\",\"cells_after\":5}", .want = "replace nb.ipynb" },
        .{ .name = "KillShell", .json = "{\"job_id\":\"j1\",\"status\":\"killed\"}", .want = "shell killed" },
        .{ .name = "Monitor", .json = "{\"job_id\":\"j1\",\"status\":\"running\",\"description\":\"watch log\"}", .want = "monitoring: watch log" },
        .{ .name = "CronCreate", .json = "{\"id\":\"c1\",\"recurring\":true,\"scheduled\":true}", .want = "recurring=true" },
        .{ .name = "CronDelete", .json = "{\"deleted\":true,\"id\":\"c1\"}", .want = "deleted=true" },
        .{ .name = "CronList", .json = "{\"jobs\":[],\"count\":3}", .want = "3 scheduled" },
        .{ .name = "PushNotification", .json = "{\"sent\":true,\"message\":\"x\"}", .want = "notification sent" },
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try renderJsonToolSummary(a, th, c.name, c.json, &out, .{});
        // 含人话关键词。
        try testing.expect(std.mem.indexOf(u8, out.items, c.want) != null);
        // 不裸吐 JSON(非 verbose 不应出现原始字段引号块)。
        try testing.expect(std.mem.indexOf(u8, out.items, "\"success\"") == null);
        try testing.expect(std.mem.indexOf(u8, out.items, "\"job_id\"") == null);
    }
}

test "WebSearch 卡片:display name 标题 + Did N searches 完成 + 中断行" {
    const a = testing.allocator;
    const th = theme_mod.monochrome;
    // displayName 映射。
    try testing.expectEqualStrings("Web Search", displayName("WebSearch"));
    try testing.expectEqualStrings("Bash", displayName("Bash"));
    // hasProgressCard:仅 WebSearch(执行中走单一动态卡,不重复显示)。
    try testing.expect(hasProgressCard("WebSearch"));
    try testing.expect(!hasProgressCard("Bash"));
    try testing.expect(!hasProgressCard("WebFetch"));

    // 起始卡:标题用 "Web Search"(带空格)+ 预览 "query"。
    const start = try renderStart(a, th, "WebSearch", "{\"query\":\"zig news\"}");
    defer a.free(start);
    try testing.expect(std.mem.indexOf(u8, start, "Web Search") != null);
    try testing.expect(std.mem.indexOf(u8, start, "\"zig news\"") != null);

    // 完成卡:Did N searches(N = "Web search results for query" 段数)。
    const result_text = "Web search results for query: \"zig news\"\n\nsome summary\n\nREMINDER: ...";
    const res = try renderResult(a, th, "WebSearch", "{\"query\":\"zig news\"}", result_text, .ok, 6600, .{ .transcript = true });
    defer a.free(res);
    try testing.expect(std.mem.indexOf(u8, res, "Web Search") != null);
    try testing.expect(std.mem.indexOf(u8, res, "Did 1 search") != null);

    // 中断卡:任意工具 Aborted → cc 通用中断行。
    const abort_json = "{\"error\":{\"code\":\"Aborted\",\"detail\":\"user interrupted\"}}";
    const ab = try renderResult(a, th, "WebSearch", "{\"query\":\"q\"}", abort_json, .err, 1000, .{});
    defer a.free(ab);
    try testing.expect(std.mem.indexOf(u8, ab, "Interrupted · What should Claude do instead?") != null);
}

test "renderResult: Task 成功结果不进消息流(空串)" {
    const th = theme_mod.monochrome;
    // Task 返回的典型 JSON,绝不应出现在屏幕上。
    const out = "{\"task_id\":\"agent_1\",\"result\":\"done\"}";
    const s = try renderResult(testing.allocator, th, "Task", "{\"description\":\"x\"}", out, .ok, 1200, .{ .transcript = true });
    defer testing.allocator.free(s);
    try testing.expectEqual(@as(usize, 0), s.len);
}

test "renderResult: NotebookEdit 显示人话摘要(不裸吐 JSON)" {
    const th = theme_mod.monochrome;
    const out = "{\"success\":true,\"path\":\"/n.ipynb\",\"mode\":\"replace\",\"cells_after\":3}";
    const s = try renderResult(testing.allocator, th, "NotebookEdit", "{\"notebook_path\":\"/n.ipynb\"}", out, .ok, 100, .{});
    defer testing.allocator.free(s);
    // 结果体显示人话摘要(mode + path),不再 hidden(曾被误吞,2026-06-04 修)。
    // 注:live 模式(transcript=false)结果卡只含 ⎿ body(标题在起始卡),故只断言 body 摘要。
    try testing.expect(std.mem.indexOf(u8, s, "replace /n.ipynb") != null);
    // 但绝不裸吐 JSON 字段名。
    try testing.expect(std.mem.indexOf(u8, s, "\"success\"") == null);
    try testing.expect(std.mem.indexOf(u8, s, "cells_after") == null);
}

test "renderResult: 错误结果提取 detail 而非裸吐 error JSON" {
    const th = theme_mod.monochrome;
    // 结构化工具错误(tool_error.errorToJson 形态)。
    const out = "{\"error\":{\"code\":\"E_NOENT\",\"detail\":\"file not found: /missing\"}}";
    const s = try renderResult(testing.allocator, th, "Read", "{\"file_path\":\"/missing\"}", out, .err, 50, .{ .transcript = true });
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
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"x\"}", out, .err, 50, .{ .transcript = true });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "permission denied");
    try capture.expectContains(s, "retry later");
}

test "renderResult: 无 detail 的结构化错误不裸吐 JSON" {
    const th = theme_mod.monochrome;
    // errorToJson 总带 detail,但外部错误可能只有 code → 绝不裸吐 {"error":...}。
    const out = "{\"error\":{\"code\":\"E_X\",\"recoverable\":false}}";
    const s = try renderResult(testing.allocator, th, "Read", "{\"file_path\":\"/x\"}", out, .err, 50, .{ .transcript = true });
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
    const s = try renderResult(testing.allocator, th, "Write", "{\"file_path\":\"/x\"}", out, .err, 50, .{ .transcript = true });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "disk full");
    try testing.expect(std.mem.indexOf(u8, s, "\"message\"") == null);
}

test "renderResult: err 侧绕过专用渲染器(Edit 失败不走 diff)" {
    const th = theme_mod.dark;
    // Edit 失败:即便输出里有 gitDiff,err 路径也应走 renderErrorBody 而非 diff 着色。
    const out = "{\"error\":{\"detail\":\"old_string not found\"},\"gitDiff\":\"--- a\\n+++ b\\n+x\\n\"}";
    const s = try renderResult(testing.allocator, th, "Edit", "{\"file_path\":\"/x\"}", out, .err, 50, .{ .transcript = true });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "old_string not found");
    // diff 正文(+x 的内容行)不应出现 —— 证明没走 renderEditDiff。
    try testing.expect(std.mem.indexOf(u8, s, "+++") == null);
}

test "renderResult: err 侧 Grep 失败走 error 体而非 Found N 摘要" {
    const th = theme_mod.monochrome;
    const out = "{\"error\":{\"detail\":\"invalid regex\"}}";
    const s = try renderResult(testing.allocator, th, "Grep", "{\"pattern\":\"[\"}", out, .err, 50, .{ .transcript = true });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "invalid regex");
    try testing.expect(std.mem.indexOf(u8, s, "Found") == null);
}

test "renderResult: hidden 工具失败时仍渲染(不静默吞错)" {
    const th = theme_mod.monochrome;
    // Task 成功 → hidden(空串);但失败必须让用户看到,否则 subagent 错误被吞。
    const out = "{\"error\":{\"detail\":\"subagent crashed\"}}";
    const s = try renderResult(testing.allocator, th, "Task", "{\"description\":\"x\"}", out, .err, 800, .{ .transcript = true });
    defer testing.allocator.free(s);
    try testing.expect(s.len > 0);
    try capture.expectContains(s, "subagent crashed");
    // 状态符是失败标记。
    try capture.expectContains(s, "X 0.8s"); // monochrome icon_cross="X"
}

// ---- cc 风格观感:⏺ bullet + ⎿ gutter + 5 列续行(对齐 Claude Code)----

test "renderStart: 用 ⏺ bullet 而非 ⚙(dark)" {
    const th = theme_mod.dark;
    const s = try renderStart(testing.allocator, th, "Bash", "{\"command\":\"ls\"}");
    defer testing.allocator.free(s);
    try capture.expectContains(s, "⏺"); // bullet(dark 带色,故分开断言 glyph 与名)
    try capture.expectContains(s, "Bash");
    try testing.expect(std.mem.indexOf(u8, s, "⚙") == null); // 旧齿轮不再出现
}

test "renderResult: ⎿ gutter + 5 列续行 + 无 ──── 分隔线(dark)" {
    const th = theme_mod.dark;
    const out = "line1\nline2\n";
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"x\"}", out, .ok, 300, .{ .collapsed = false, .transcript = true });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "⏺"); // bullet
    // 首行结果挂在 ⎿ gutter 下(gutter 与 line1 之间是 reset+2空格,故分开断言)。
    try capture.expectContains(s, "⎿");
    try capture.expectContains(s, "  line1");
    // 续行 5 空格对齐(角符之后)。
    try capture.expectContains(s, "     line2");
    // 旧的 ──── 分隔线彻底移除。
    try testing.expect(std.mem.indexOf(u8, s, "────") == null);
}

test "renderLiveDone: committed 卡无右对齐耗时(回归:实测 cc 历史卡不显 ✓ Ns)" {
    // 实测 bug:每条历史工具卡右侧显示 `✓ 0.1s`,cc 2.1.165 committed scrollback 卡无此耗时
    //（耗时仅在运行中动态卡/spinner)。renderLiveDone 不该再调 appendStatusRight。
    const th = theme_mod.dark;
    const s = try renderLiveDone(testing.allocator, th, "Bash", "{\"command\":\"git status\"}", "ok", .ok, 1234, .{ .cols = 80 });
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Ran 1 shell command"); // 过去式标题仍在
    // 不含耗时(1234ms→"1.2s")也不含状态符 ✓。
    try testing.expect(std.mem.indexOf(u8, s, "1.2s") == null);
    try testing.expect(std.mem.indexOf(u8, s, "✓") == null);
}

test "renderLiveDone: 失败工具也不显耗时/✗(错误走 ⎿ body)" {
    const th = theme_mod.dark;
    const s = try renderLiveDone(testing.allocator, th, "Bash", "{\"command\":\"false\"}", "err", .err, 500, .{ .cols = 80 });
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "0.5s") == null);
    try testing.expect(std.mem.indexOf(u8, s, "✗") == null);
}

test "renderResult: monochrome 用 ASCII gutter(\\)而非 unicode" {
    const th = theme_mod.monochrome;
    const out = "alpha\nbeta\n";
    const s = try renderResult(testing.allocator, th, "Bash", "{\"command\":\"x\"}", out, .ok, 100, .{ .collapsed = false, .transcript = true });
    defer testing.allocator.free(s);
    try capture.expectNoAnsi(s);
    try capture.expectContains(s, "* Bash"); // mono icon_act="*"
    try capture.expectContains(s, "\\  alpha"); // mono gutter="\"
    try capture.expectContains(s, "     beta"); // 续行 5 空格
    try testing.expect(std.mem.indexOf(u8, s, "⎿") == null); // 无 unicode 角符
}

// ---- actionLabel:agent 树动作行 `Tool(arg)`(width-safe 截断)----

test "actionLabel: 各工具关键参数" {
    const a = testing.allocator;
    {
        const s = try actionLabel(a, "Bash", "{\"command\":\"git status\"}");
        defer a.free(s);
        try testing.expectEqualStrings("Bash(git status)", s);
    }
    {
        const s = try actionLabel(a, "Read", "{\"file_path\":\"/etc/hosts\"}");
        defer a.free(s);
        try testing.expectEqualStrings("Read(/etc/hosts)", s);
    }
    {
        const s = try actionLabel(a, "Grep", "{\"pattern\":\"TODO\"}");
        defer a.free(s);
        try testing.expectEqualStrings("Grep(TODO)", s);
    }
    {
        // 识别不出参数 → 纯工具名。
        const s = try actionLabel(a, "SomeTool", "{}");
        defer a.free(s);
        try testing.expectEqualStrings("SomeTool", s);
    }
}

test "actionLabel: 多行 command 只取首行" {
    const s = try actionLabel(testing.allocator, "Bash", "{\"command\":\"cd /x\\nmake\"}");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("Bash(cd /x)", s);
}

test "toolPreview: Grep pattern 用 pattern:\"…\" 格式(不产生双斜杠)" {
    const a = testing.allocator;
    // 回归:含 / 的 pattern(如搜 \"/v1/models\")旧 `/{s}/` 会显示成 `//v1/models/`。
    {
        const s = try toolPreviewPub(a, "Grep", "{\"pattern\":\"/v1/models\"}");
        defer a.free(s);
        try testing.expectEqualStrings("pattern: \"/v1/models\"", s);
        try testing.expect(std.mem.indexOf(u8, s, "//") == null); // 无双斜杠
    }
    {
        const s = try toolPreviewPub(a, "Grep", "{\"pattern\":\"TODO\"}");
        defer a.free(s);
        try testing.expectEqualStrings("pattern: \"TODO\"", s);
    }
    {
        // 带 path:对齐 cc `pattern: "x", path: "y"`。
        const s = try toolPreviewPub(a, "Grep", "{\"pattern\":\"foo\",\"path\":\"src/util\"}");
        defer a.free(s);
        try testing.expectEqualStrings("pattern: \"foo\", path: \"src/util\"", s);
    }
}

test "actionLabel: 超长 CJK 参数按显示宽截断且不切碎 UTF-8" {
    // 30 个中文(显示宽 60 列)> 48 列上限 → 必须按宽度截断,且输出仍是合法 UTF-8。
    const path = "{\"file_path\":\"中文路径中文路径中文路径中文路径中文路径中文路径中文路径中文路径中文路径中文路径\"}";
    const s = try actionLabel(testing.allocator, "Read", path);
    defer testing.allocator.free(s);
    // 合法 UTF-8(切在字符边界,绝不半个码点)。
    try testing.expect(std.unicode.utf8ValidateSlice(s));
    // 截断标记存在。
    try testing.expect(std.mem.indexOf(u8, s, "…") != null);
    // 形如 Read(...…)。
    try testing.expect(std.mem.startsWith(u8, s, "Read("));
    try testing.expect(std.mem.endsWith(u8, s, ")"));
}



