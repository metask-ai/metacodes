//! Agent 进度树(对齐 Claude Code `⏺ Running N subagents…` swarm 树)。
//!
//! 数据源:AgentJobRegistry.snapshotJobs() 的 []JobSnapshot(值语义快照)。
//! 渲染纯函数 → owned 字符串,caller free;便于单测。
//!
//! 样式:
//!   ⏺ Running 2 subagents…
//!      ├ Explore: inspect repo · 5 tools · turn 2
//!      │  ⎿ Grep
//!      └ Plan: design api · 3 tools · turn 1
//!         ⎿ Read
//!
//! 全部 done → 标题 `N subagents finished`(不再有 spinner 语义)。
//! 最多显示 MAX_SHOWN 个(对齐 cc MAX_PROGRESS_MESSAGES_TO_SHOW=3),超出 `… +M more`。

const std = @import("std");
const Theme = @import("../theme.zig").Theme;
const term = @import("../term.zig");
const registry = @import("../../../core/agent_job_registry.zig");

const JobSnapshot = registry.AgentJobRegistry.JobSnapshot;
const JobStatus = registry.JobStatus;

/// 对齐 cc MAX_PROGRESS_MESSAGES_TO_SHOW。
pub const MAX_SHOWN: usize = 3;

/// 渲染 agent 进度树。jobs 为空 → 返回空串(caller 据此决定是否占行)。
/// caller free 返回值。
pub fn render(alloc: std.mem.Allocator, th: Theme, jobs: []const JobSnapshot) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (jobs.len == 0) return try out.toOwnedSlice(alloc);

    // 统计 running 数,决定标题动词。
    var running: usize = 0;
    for (jobs) |j| {
        if (j.status == .running) running += 1;
    }

    // 标题行:⏺ Running N subagents… / N subagents finished
    try out.appendSlice(alloc, th.accent);
    try out.appendSlice(alloc, th.icon_act);
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, ' ');
    if (running > 0) {
        try out.print(alloc, "Running {d} subagent{s}…", .{ running, plural(running) });
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

    return try out.toOwnedSlice(alloc);
}

/// 一个 job 的两行:分支行 `├ <type>: <desc> · N tools · turn M` + 动作行 `⎿ <tool>`。
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
    try out.print(alloc, " · {d} tool{s} · turn {d}", .{ j.tool_calls, plural(j.tool_calls), j.current_turn });
    try out.appendSlice(alloc, th.reset);
    try out.append(alloc, '\n');

    // 动作行:仅 running 且有当前工具时显示 `│  ⎿ <tool>`(末枝用空格替竖管)。
    if (j.status == .running and j.current_tool.len > 0) {
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
        try out.appendSlice(alloc, j.current_tool);
        try out.appendSlice(alloc, th.reset);
        try out.append(alloc, '\n');
    }
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

fn mkSnap(id: []u8, status: JobStatus, desc: []u8, turns: u32, tool_calls: u32, current_turn: u32, current_tool: []u8) JobSnapshot {
    return .{ .id = id, .status = status, .desc = desc, .turns = turns, .tool_calls = tool_calls, .current_turn = current_turn, .current_tool = current_tool };
}

test "agent_tree: 空 jobs → 空串" {
    const s = try render(testing.allocator, theme_mod.monochrome, &.{});
    defer testing.allocator.free(s);
    try testing.expectEqual(@as(usize, 0), s.len);
}

test "agent_tree: 单 running job 出标题 + 分支 + 动作行" {
    var id = "agent_1".*;
    var desc = "inspect repo".*;
    var tool = "Grep".*;
    const jobs = [_]JobSnapshot{
        mkSnap(&id, .running, &desc, 2, 5, 2, &tool),
    };
    const s = try render(testing.allocator, theme_mod.monochrome, &jobs);
    defer testing.allocator.free(s);
    try capture.expectNoAnsi(s);
    try capture.expectContains(s, "Running 1 subagent…");
    try capture.expectContains(s, "inspect repo");
    try capture.expectContains(s, "5 tools · turn 2");
    try capture.expectContains(s, "Grep"); // 动作行
    // 单个 = 末枝,mono tree_end="\"。
    try capture.expectContains(s, "\\ inspect repo");
}

test "agent_tree: 全 done → finished 标题,无动作行" {
    var id = "agent_1".*;
    var desc = "task one".*;
    var empty = "".*;
    const jobs = [_]JobSnapshot{
        mkSnap(&id, .done, &desc, 3, 7, 3, empty[0..0]),
    };
    const s = try render(testing.allocator, theme_mod.monochrome, &jobs);
    defer testing.allocator.free(s);
    try capture.expectContains(s, "1 subagent finished");
    try capture.expectContains(s, "7 tools · turn 3");
    // done 无 current_tool → 无 ⎿ 动作行。
    try testing.expect(std.mem.indexOf(u8, s, "\\ ") == null or std.mem.indexOf(u8, s, "task one") != null);
}

test "agent_tree: 超 MAX_SHOWN 折叠 +M more" {
    var ids: [5][8]u8 = undefined;
    var descs: [5][8]u8 = undefined;
    var empty = "".*;
    var jobs: [5]JobSnapshot = undefined;
    for (0..5) |k| {
        @memcpy(ids[k][0..7], "agent_x");
        ids[k][6] = @intCast('0' + k);
        @memcpy(descs[k][0..4], "jobx");
        descs[k][3] = @intCast('0' + k);
        jobs[k] = mkSnap(ids[k][0..7], .running, descs[k][0..4], 1, 1, 1, empty[0..0]);
    }
    const s = try render(testing.allocator, theme_mod.monochrome, &jobs);
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Running 5 subagents…");
    try capture.expectContains(s, "… +2 more"); // 5 - 3
}

test "agent_tree: dark 主题树形字符 ├└⎿" {
    var id1 = "agent_1".*;
    var id2 = "agent_2".*;
    var d1 = "first".*;
    var d2 = "second".*;
    var t1 = "Read".*;
    var empty = "".*;
    const jobs = [_]JobSnapshot{
        mkSnap(&id1, .running, &d1, 1, 1, 1, &t1),
        mkSnap(&id2, .running, &d2, 1, 2, 1, empty[0..0]),
    };
    const s = try render(testing.allocator, theme_mod.dark, &jobs);
    defer testing.allocator.free(s);
    try capture.expectContains(s, "├"); // 非末枝
    try capture.expectContains(s, "└"); // 末枝
    try capture.expectContains(s, "⎿"); // 动作臂
    try capture.expectContains(s, "│"); // 非末枝下竖管
}
