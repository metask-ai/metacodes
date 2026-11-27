//! Agent 进度树(对齐 Claude Code v2.1.168 `⏺ Running N <Type> agents…` 实拍金标准)。
//!
//! 数据源:AgentJobRegistry.snapshotJobs() 的 []JobSnapshot(值语义快照)。
//! 渲染纯函数 → owned 字符串,caller free;便于单测。
//!
//! 样式(实拍 napicc v2.1.168):
//!   ⏺ Running 3 Explore agents…                          ← 标题按 agent TYPE 分组计数
//!      ├ Summarize mod0.py · 1 tool use · 17.3k tokens   ← <desc> · N tool use(s) [· X tokens]
//!      │ ⎿  Read: /Users/.../mod0.py                      ← 动作行三态(冒号式 Tool: arg)
//!      ├ Summarize mod1.py · 0 tool uses                  ← tool_calls=0 省略 tokens
//!      │ ⎿  Initializing…                                 ← running 尚无工具
//!      └ Summarize mod2.py · 3 tool uses · 17.7k tokens
//!        ⎿  Done                                          ← 该 agent 完成
//!        (ctrl+b to run in background)                    ← 起后 ~2s 出现
//!
//! 标题分组:全部 running 同 type → `Running N <Type> agent(s)…`;混合 type → `Running N agents…`。
//! 全部 done → `N subagent(s) finished`(无 spinner 语义)。
//! 最多显示 MAX_SHOWN 个(对齐 cc MAX_PROGRESS_MESSAGES_TO_SHOW=3),超出 `… +M more`。

const std = @import("std");
const Theme = @import("../theme.zig").Theme;
const term = @import("../term.zig");
const registry = @import("metacodes-internal").core.agent_job_registry;
const tool_card = @import("tool_card.zig");
const util_time = @import("metacodes-internal").util.time;
const progress = @import("metacodes-internal").teamwork.progress;
const teamwork_types = @import("metacodes-internal").teamwork.types;
const TerminalEnv = @import("../term.zig").TerminalEnv;

const JobSnapshot = registry.AgentJobRegistry.JobSnapshot;
const JobStatus = registry.JobStatus;

/// 对齐 cc MAX_PROGRESS_MESSAGES_TO_SHOW。
pub const MAX_SHOWN: usize = 3;

/// 起后多久显示 (ctrl+b to run in background) 提示(对齐 cc PROGRESS_THRESHOLD_MS)。
pub const BACKGROUND_HINT_MS: i64 = 2000;

/// 渲染 agent 进度树。jobs 为空 → 返回空串(caller 据此决定是否占行)。
/// now_ms:当前时刻(毫秒),用于 ctrl+b 提示的 2s 门控 + 防 Date.now 散用。caller free 返回值。
pub fn render(alloc: std.mem.Allocator, th: Theme, jobs: []const JobSnapshot, now_ms: i64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (jobs.len == 0) return try out.toOwnedSlice(alloc);

    // 统计 running 数 + 判断是否同质 type(标题分组)。
    var running: usize = 0;
    var running_type: ?[]const u8 = null;
    var homogeneous = true;
    for (jobs) |j| {
        if (j.status != .running) continue;
        running += 1;
        if (running_type) |t| {
            if (!std.mem.eql(u8, t, j.agent_type)) homogeneous = false;
        } else {
            running_type = j.agent_type;
        }
    }

    // 标题行:⏺ Running N <Type> agent(s)… / N subagent(s) finished
    try out.appendSlice(alloc, th.accent);
    try out.appendSlice(alloc, th.icon_act);
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, ' ');
    if (running > 0) {
        if (homogeneous and running_type != null and running_type.?.len > 0) {
            try out.print(alloc, "Running {d} {s} agent{s}…", .{ running, running_type.?, plural(running) });
        } else {
            try out.print(alloc, "Running {d} agent{s}…", .{ running, plural(running) });
        }
    } else {
        try out.print(alloc, "{d} subagent{s} finished", .{ jobs.len, plural(jobs.len) });
    }
    try out.append(alloc, '\n');

    const shown = @min(jobs.len, MAX_SHOWN);
    for (jobs[0..shown], 0..) |j, idx| {
        const is_last = (idx == shown - 1) and (jobs.len <= MAX_SHOWN);
        try renderJobLine(alloc, th, j, is_last, &out);
    }

    if (jobs.len > MAX_SHOWN) {
        const more = jobs.len - MAX_SHOWN;
        try out.appendSlice(alloc, "   ");
        try out.appendSlice(alloc, th.dim);
        try out.print(alloc, "… +{d} more", .{more});
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
    }

    // (ctrl+b to run in background):any running 且最早 agent 起后 >= 2s。
    if (running > 0) {
        var min_start: i64 = std.math.maxInt(i64);
        for (jobs) |j| {
            if (j.status == .running and j.started_ms != 0 and j.started_ms < min_start) min_start = j.started_ms;
        }
        if (min_start != std.math.maxInt(i64) and now_ms - min_start >= BACKGROUND_HINT_MS) {
            try out.appendSlice(alloc, "     ");
            try out.appendSlice(alloc, th.dim);
            try out.appendSlice(alloc, backgroundHint());
            try out.appendSlice(alloc, th.reset);
            try out.append(alloc, '\n');
        }
    }

    return try out.toOwnedSlice(alloc);
}

fn backgroundHint() []const u8 {
    return if (TerminalEnv.fromProcess().insideTmux()) "(ctrl+b ctrl+b to run in background)" else "(ctrl+b to run in background)";
}

pub fn renderTeamwork(alloc: std.mem.Allocator, th: Theme, snapshot: progress.Snapshot, max_cols: ?usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const title = " Teamwork";
    try out.appendSlice(alloc, th.accent);
    try out.appendSlice(alloc, th.icon_act);
    try out.appendSlice(alloc, th.reset);
    try out.appendSlice(alloc, title);
    if (snapshot.goal.len > 0) {
        const separator = " · ";
        try out.appendSlice(alloc, separator);
        const used = term.displayWidth(th.icon_act) + title.len + term.displayWidth(separator);
        try appendGoal(alloc, &out, snapshot.goal, if (max_cols) |cols| cols -| used else null);
    }
    try out.append(alloc, '\n');

    try out.appendSlice(alloc, "   ");
    try out.appendSlice(alloc, th.dim);
    try out.print(alloc, "{d}/{d} done · ${d:.2} / ${d:.2} · {s}", .{ snapshot.seatsDone(), snapshot.seats.len, snapshot.budget.spent_usd, snapshot.budget.cap_usd, @tagName(snapshot.phase) });
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');

    if (snapshot.candidates.len != 0) {
        try out.appendSlice(alloc, "   ");
        try out.appendSlice(alloc, th.dim);
        try out.appendSlice(alloc, "candidates");
        for (snapshot.candidates, 1..) |candidate, number| {
            try out.print(alloc, " · {d} {s}", .{ number, @tagName(candidate.status) });
        }
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
    }

    for (snapshot.seats, 0..) |seat, idx| {
        try out.appendSlice(alloc, "   ");
        try out.appendSlice(alloc, th.dim);
        try out.appendSlice(alloc, if (idx + 1 == snapshot.seats.len) th.tree_end else th.tree_branch);
        try out.appendSlice(alloc, th.reset);
        try out.print(alloc, " {s} · {s} · ", .{ seat.id.slice(), harnessLabel(seat.harness) });
        try out.appendSlice(alloc, switch (seat.status) {
            .working => th.accent,
            .needs_you => th.warn,
            .done => th.success,
            .failed => th.danger,
            .queued, .waiting => th.dim,
        });
        try out.appendSlice(alloc, @tagName(seat.status));
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
    }
    return try out.toOwnedSlice(alloc);
}

fn harnessLabel(harness: teamwork_types.Harness) []const u8 {
    return switch (harness) {
        .metacodes => "metacodes",
        .claude_code => "Claude Code",
    };
}

fn appendGoal(alloc: std.mem.Allocator, out: *std.ArrayList(u8), goal: []const u8, max_cols: ?usize) !void {
    const ellipsis = "…";
    const limit = max_cols orelse std.math.maxInt(usize);
    const fits = goalWidth(goal) <= limit;
    var cols: usize = 0;
    var i: usize = 0;
    while (i < goal.len) {
        const len = goalCharLen(goal, i);
        const char = goal[i .. i + len];
        const width = goalCharWidth(char);
        if (!fits and cols + width + 1 > limit) break;
        if (isControl(char)) try out.append(alloc, ' ') else try out.appendSlice(alloc, char);
        cols += width;
        i += len;
    }
    if (!fits and limit > 0) try out.appendSlice(alloc, ellipsis);
}

fn goalWidth(goal: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < goal.len) {
        const len = goalCharLen(goal, i);
        cols += goalCharWidth(goal[i .. i + len]);
        i += len;
    }
    return cols;
}

fn goalCharLen(goal: []const u8, i: usize) usize {
    return @min(std.unicode.utf8ByteSequenceLength(goal[i]) catch 1, goal.len - i);
}

fn goalCharWidth(char: []const u8) usize {
    return if (isControl(char)) 1 else term.displayWidth(char);
}

fn isControl(char: []const u8) bool {
    return char.len == 1 and (char[0] < 0x20 or char[0] == 0x7f);
}

/// token 数格式化:17300 → "17.3k";<1000 原样。
fn fmtTokens(alloc: std.mem.Allocator, n: u64) ![]u8 {
    if (n < 1000) return std.fmt.allocPrint(alloc, "{d}", .{n});
    const k = @as(f64, @floatFromInt(n)) / 1000.0;
    // 一位小数(对齐 cc 17.3k);整 k 也显 .0?实拍是 17.3k/18.1k,统一一位小数。
    return std.fmt.allocPrint(alloc, "{d:.1}k", .{k});
}

/// 一个 job 的两行:分支行 `├ <desc> · N tool use(s) [· X tokens]` + 动作行三态。
fn renderJobLine(alloc: std.mem.Allocator, th: Theme, j: JobSnapshot, is_last: bool, out: *std.ArrayList(u8)) !void {
    const branch = if (is_last) th.tree_end else th.tree_branch;
    // 分支行(缩进 3 空格 + 树枝符)。
    try out.appendSlice(alloc, "   ");
    try out.appendSlice(alloc, th.dim);
    try out.appendSlice(alloc, branch);
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, ' ');
    // 状态着色:running=accent / done=success dim / failed=danger / killed=warn。
    const sc = switch (j.status) {
        .running => th.accent,
        .done => th.success,
        .failed => th.danger,
        .killed => th.warn,
    };
    try out.appendSlice(alloc, sc);
    try out.appendSlice(alloc, j.desc);
    try out.appendSlice(alloc, th.reset);
    try out.appendSlice(alloc, th.dim);
    // `· N tool use(s)`(对齐 cc:tool use 单/tool uses 复)。
    try out.print(alloc, " · {d} tool use{s}", .{ j.tool_calls, plural(j.tool_calls) });
    // `· X tokens` 仅当 tool_calls>0(对齐实拍:0 tool uses 不显 tokens)。
    if (j.tool_calls > 0 and j.tokens > 0) {
        const tk = try fmtTokens(alloc, j.tokens);
        defer alloc.free(tk);
        try out.print(alloc, " · {s} tokens", .{tk});
    }
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');

    // 动作行三态(对齐实拍):
    //   running + 有当前工具 → `Tool: arg`(冒号式)
    //   running + 无工具    → `Initializing…`
    //   非 running          → `Done`
    try out.appendSlice(alloc, "   ");
    try out.appendSlice(alloc, th.dim);
    if (is_last) {
        try out.appendSlice(alloc, " "); // 末枝下无竖管
    } else {
        try out.appendSlice(alloc, th.tree_pipe);
    }
    try out.appendSlice(alloc, "  ");
    try out.appendSlice(alloc, th.gutter);
    try out.append(alloc, ' ');
    if (j.status == .running) {
        if (j.current_tool.len > 0) {
            const label = tool_card.actionLabelColon(alloc, j.current_tool, j.current_tool_input) catch null;
            if (label) |l| {
                defer alloc.free(l);
                try out.appendSlice(alloc, l);
            } else {
                try out.appendSlice(alloc, j.current_tool);
            }
        } else {
            try out.appendSlice(alloc, "Initializing…");
        }
    } else {
        try out.appendSlice(alloc, "Done");
    }
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');
}

fn plural(n: anytype) []const u8 {
    return if (n == 1) "" else "s";
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const theme_mod = @import("../theme.zig");
const capture = @import("../test_capture.zig");
const ppaths = @import("metacodes-internal").platform.paths;

fn mkSnap(id: []u8, status: JobStatus, desc: []u8, agent_type: []u8, tool_calls: u32, tokens: u64, current_tool: []u8, current_tool_input: []u8) JobSnapshot {
    return .{
        .id = id,
        .status = status,
        .desc = desc,
        .turns = 0,
        .tool_calls = tool_calls,
        .current_turn = 0,
        .current_tool = current_tool,
        .current_tool_input = current_tool_input,
        .foreground = false,
        .agent_type = agent_type,
        .tokens = tokens,
        .started_ms = 0,
    };
}

test "agent_tree: 空 jobs → 空串" {
    const s = try render(testing.allocator, theme_mod.monochrome, &.{}, 0);
    defer testing.allocator.free(s);
    try testing.expectEqual(@as(usize, 0), s.len);
}

test "agent_tree: 单 running job 标题按 type 分组 + 行 tool use(s) + tokens + 动作行冒号式" {
    var id = "agent_1".*;
    var desc = "Summarize mod0.py".*;
    var atype = "Explore".*;
    var tool = "Read".*;
    var inp = "{\"file_path\":\"/Users/x/mod0.py\"}".*;
    const jobs = [_]JobSnapshot{
        mkSnap(&id, .running, &desc, &atype, 1, 17300, &tool, &inp),
    };
    const s = try render(testing.allocator, theme_mod.monochrome, &jobs, 0);
    defer testing.allocator.free(s);
    try capture.expectNoAnsi(s);
    // 标题按 type 分组(对齐实拍 `Running 1 Explore agent…`)。
    try capture.expectContains(s, "Running 1 Explore agent…");
    try capture.expectContains(s, "Summarize mod0.py");
    // 行: 1 tool use(单数) · 17.3k tokens。
    try capture.expectContains(s, "1 tool use · 17.3k tokens");
    // 动作行冒号式 + 全路径(对齐实拍 `Read: /Users/.../mod0.py`)。
    try capture.expectContains(s, "Read: /Users/x/mod0.py");
}

test "agent_tree: 0 tool uses 不显 tokens + Initializing 动作行" {
    var id = "agent_1".*;
    var desc = "Summarize mod1.py".*;
    var atype = "Explore".*;
    var empty = "".*;
    const jobs = [_]JobSnapshot{
        mkSnap(&id, .running, &desc, &atype, 0, 17300, empty[0..0], empty[0..0]),
    };
    const s = try render(testing.allocator, theme_mod.monochrome, &jobs, 0);
    defer testing.allocator.free(s);
    // 0 tool uses(复数)且不显 tokens。
    try capture.expectContains(s, "0 tool uses");
    try testing.expect(std.mem.indexOf(u8, s, "tokens") == null);
    // running 无工具 → Initializing…
    try capture.expectContains(s, "Initializing…");
}

test "agent_tree: done agent 动作行 Done" {
    var id = "agent_1".*;
    var desc = "task one".*;
    var atype = "Explore".*;
    var empty = "".*;
    const jobs = [_]JobSnapshot{
        mkSnap(&id, .done, &desc, &atype, 7, 18100, empty[0..0], empty[0..0]),
    };
    const s = try render(testing.allocator, theme_mod.monochrome, &jobs, 0);
    defer testing.allocator.free(s);
    // 全 done → finished 标题。
    try capture.expectContains(s, "1 subagent finished");
    try capture.expectContains(s, "7 tool uses · 18.1k tokens");
    // 完成 → 动作行 Done。
    try capture.expectContains(s, "Done");
}

test "agent_tree: 混合 type → 标题退回通用 Running N agents" {
    var id1 = "agent_1".*;
    var id2 = "agent_2".*;
    var d1 = "a".*;
    var d2 = "b".*;
    var t1 = "Explore".*;
    var t2 = "Plan".*;
    var empty = "".*;
    const jobs = [_]JobSnapshot{
        mkSnap(&id1, .running, &d1, &t1, 1, 1000, empty[0..0], empty[0..0]),
        mkSnap(&id2, .running, &d2, &t2, 1, 1000, empty[0..0], empty[0..0]),
    };
    const s = try render(testing.allocator, theme_mod.monochrome, &jobs, 0);
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Running 2 agents…");
    try testing.expect(std.mem.indexOf(u8, s, "Explore agents") == null);
}

test "agent_tree: ctrl+b 提示在起后 2s 出现" {
    const saved_tmux = if (std.c.getenv("TMUX")) |raw| try testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
    defer if (saved_tmux) |value| {
        ppaths.setEnv("TMUX", value.ptr);
        testing.allocator.free(value);
    } else ppaths.unsetEnv("TMUX");
    ppaths.unsetEnv("TMUX");
    var id = "agent_1".*;
    var desc = "Summarize".*;
    var atype = "Explore".*;
    var empty = "".*;
    var jobs = [_]JobSnapshot{
        mkSnap(&id, .running, &desc, &atype, 0, 0, empty[0..0], empty[0..0]),
    };
    jobs[0].started_ms = 1000;
    // now=2000 < started+2000 → 不显。
    const s1 = try render(testing.allocator, theme_mod.monochrome, &jobs, 2000);
    defer testing.allocator.free(s1);
    try testing.expect(std.mem.indexOf(u8, s1, "ctrl+b") == null);
    // now=3500 >= started+2000 → 显示。
    const s2 = try render(testing.allocator, theme_mod.monochrome, &jobs, 3500);
    defer testing.allocator.free(s2);
    try capture.expectContains(s2, "(ctrl+b to run in background)");
}

test "agent_tree: inside tmux the hint asks for ctrl+b twice, since tmux takes the first as its prefix" {
    const saved_tmux = if (std.c.getenv("TMUX")) |raw| try testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
    defer if (saved_tmux) |value| {
        ppaths.setEnv("TMUX", value.ptr);
        testing.allocator.free(value);
    } else ppaths.unsetEnv("TMUX");
    ppaths.setEnv("TMUX", "/tmp/tmux-0/default,1,0");
    var id = "agent_1".*;
    var desc = "Summarize".*;
    var atype = "Explore".*;
    var empty = "".*;
    var jobs = [_]JobSnapshot{
        mkSnap(&id, .running, &desc, &atype, 0, 0, empty[0..0], empty[0..0]),
    };
    jobs[0].started_ms = 1000;
    const shown = try render(testing.allocator, theme_mod.monochrome, &jobs, 3500);
    defer testing.allocator.free(shown);
    try capture.expectContains(shown, "(ctrl+b ctrl+b to run in background)");
}

test "agent_tree: 超 MAX_SHOWN 折叠 +M more" {
    var ids: [5][8]u8 = undefined;
    var descs: [5][8]u8 = undefined;
    var atype = "Explore".*;
    var empty = "".*;
    var jobs: [5]JobSnapshot = undefined;
    for (0..5) |k| {
        @memcpy(ids[k][0..7], "agent_x");
        ids[k][6] = @intCast('0' + k);
        @memcpy(descs[k][0..4], "jobx");
        descs[k][3] = @intCast('0' + k);
        jobs[k] = mkSnap(ids[k][0..7], .running, descs[k][0..4], &atype, 1, 1000, empty[0..0], empty[0..0]);
    }
    const s = try render(testing.allocator, theme_mod.monochrome, &jobs, 0);
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Running 5 Explore agents…");
    try capture.expectContains(s, "… +2 more"); // 5 - 3
}

test "agent_tree: dark 主题树形字符 ├└⎿" {
    var id1 = "agent_1".*;
    var id2 = "agent_2".*;
    var d1 = "first".*;
    var d2 = "second".*;
    var atype = "Explore".*;
    var t1 = "Read".*;
    var in1 = "{\"file_path\":\"/x\"}".*;
    var empty = "".*;
    const jobs = [_]JobSnapshot{
        mkSnap(&id1, .running, &d1, &atype, 1, 1000, &t1, &in1),
        mkSnap(&id2, .running, &d2, &atype, 2, 1000, empty[0..0], empty[0..0]),
    };
    const s = try render(testing.allocator, theme_mod.dark, &jobs, 0);
    defer testing.allocator.free(s);
    try capture.expectContains(s, "├"); // 非末枝
    try capture.expectContains(s, "└"); // 末枝
    try capture.expectContains(s, "⎿"); // 动作臂
    try capture.expectContains(s, "│"); // 非末枝下竖管
    try capture.expectContains(s, "Read: /x"); // 动作行冒号式带全路径
}

fn teamworkSeats() [3]@import("metacodes-internal").teamwork.runtime.SeatSnapshot {
    return .{
        .{ .id = teamwork_types.seatIdFor(.implementer, 1), .role = .implementer, .harness = .metacodes, .status = .done },
        .{ .id = teamwork_types.seatIdFor(.reviewer, 1), .role = .reviewer, .harness = .claude_code, .status = .working },
        .{ .id = teamwork_types.seatIdFor(.implementer, 2), .role = .implementer, .harness = .metacodes, .status = .needs_you },
    };
}

fn teamworkSnapshot(seats: []const @import("metacodes-internal").teamwork.runtime.SeatSnapshot, goal: []const u8) !progress.Snapshot {
    return .{
        .run_id = try teamwork_types.RunId.parse("run-1"),
        .goal = goal,
        .phase = .reviewing,
        .seats = seats,
        .budget = .{ .cap_usd = 5, .spent_usd = 0.42, .remaining_usd = 4.58, .charges = 2 },
        .audit = .{ .used = 0, .last = null },
    };
}

test "agent_tree teamwork: three seats mixing metacodes and Claude Code" {
    const seats = teamworkSeats();
    const s = try renderTeamwork(testing.allocator, theme_mod.dark, try teamworkSnapshot(&seats, "Add feature.txt"), 80);
    defer testing.allocator.free(s);
    try capture.expectStrippedEquals(testing.allocator, s,
        \\⏺ Teamwork · Add feature.txt
        \\   1/3 done · $0.42 / $5.00 · reviewing
        \\   ├ implementer-1 · metacodes · done
        \\   ├ reviewer-1 · Claude Code · working
        \\   └ implementer-2 · metacodes · needs_you
        \\
    );
}

test "agent_tree teamwork: colours follow the seat status" {
    const seats = teamworkSeats();
    const s = try renderTeamwork(testing.allocator, theme_mod.dark, try teamworkSnapshot(&seats, "Add feature.txt"), 80);
    defer testing.allocator.free(s);
    const th = theme_mod.dark;
    const working = try std.mem.concat(testing.allocator, u8, &.{ th.accent, "working", th.reset });
    defer testing.allocator.free(working);
    const needs_you = try std.mem.concat(testing.allocator, u8, &.{ th.warn, "needs_you", th.reset });
    defer testing.allocator.free(needs_you);
    try capture.expectContains(s, working);
    try capture.expectContains(s, needs_you);
}

test "agent_tree teamwork: the goal is cut to the width and never carries control bytes" {
    const seats = teamworkSeats();
    const s = try renderTeamwork(testing.allocator, theme_mod.monochrome, try teamworkSnapshot(seats[0..1], "Ship\x1b[2Jthe 全角 feature now"), 24);
    defer testing.allocator.free(s);
    const title = s[0..std.mem.indexOfScalar(u8, s, '\n').?];
    try testing.expectEqualStrings("* Teamwork · Ship [2Jth…", title);
    try testing.expect(term.displayWidth(title) <= 24);
    const unbounded = try renderTeamwork(testing.allocator, theme_mod.monochrome, try teamworkSnapshot(seats[0..1], "Ship the 全角 feature now"), null);
    defer testing.allocator.free(unbounded);
    try capture.expectContains(unbounded, "* Teamwork · Ship the 全角 feature now\n");
}

test "agent_tree teamwork: control bytes count as the spaces they become when fitting the goal" {
    const seats = teamworkSeats();
    const goal = "ab\x01\x02\x03\x04";
    const exact = try renderTeamwork(testing.allocator, theme_mod.monochrome, try teamworkSnapshot(seats[0..1], goal), 13 + 6);
    defer testing.allocator.free(exact);
    try capture.expectContains(exact, "* Teamwork · ab    \n");
    const narrow = try renderTeamwork(testing.allocator, theme_mod.monochrome, try teamworkSnapshot(seats[0..1], goal), 13 + 5);
    defer testing.allocator.free(narrow);
    const title = narrow[0..std.mem.indexOfScalar(u8, narrow, '\n').?];
    try testing.expectEqualStrings("* Teamwork · ab  …", title);
    try testing.expect(term.displayWidth(title) <= 13 + 5);
}

test "agent_tree teamwork: parallel candidates show their statuses under the summary" {
    const seats = teamworkSeats();
    var snapshot = try teamworkSnapshot(seats[0..1], "Add feature.txt");
    const candidates = [_]@import("metacodes-internal").teamwork.runtime.CandidateSnapshot{ .{ .status = .rejected }, .{ .status = .selected }, .{ .status = .eliminated } };
    snapshot.phase = .candidates;
    snapshot.candidates = &candidates;
    const s = try renderTeamwork(testing.allocator, theme_mod.dark, snapshot, 80);
    defer testing.allocator.free(s);
    try capture.expectStrippedEquals(testing.allocator, s,
        \\⏺ Teamwork · Add feature.txt
        \\   1/1 done · $0.42 / $5.00 · candidates
        \\   candidates · 1 rejected · 2 selected · 3 eliminated
        \\   └ implementer-1 · metacodes · done
        \\
    );
}
