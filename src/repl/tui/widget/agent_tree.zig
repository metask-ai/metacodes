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
const registry = @import("../../../core/agent_job_registry.zig");
const tool_card = @import("tool_card.zig");
const util_time = @import("../../../util/time.zig");

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
            try out.appendSlice(alloc, "(ctrl+b to run in background)");
            try out.appendSlice(alloc, th.reset);
            try out.append(alloc, '\n');
        }
    }

    return try out.toOwnedSlice(alloc);
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
