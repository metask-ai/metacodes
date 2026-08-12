//! Plan 落图(设计 v3-final §3):批准的 `<proposed_plan>` 正文 → 持久任务 DAG。
//!
//! 取代"plan 写 markdown 文档"陋习——计划成为图里的 root task + 步骤 task 链,
//! 未来 session 从 frontier 恢复进度。任务层级写 canonical `contain`；TinyKG 兼容读旧
//! task→task `contains`，后者保留给 markdown 有序组合。
//!
//! 解析:容忍有序/无序/粗体标题列表;≥2 步即结构化。依赖标注 `(depends: 2,3)` →
//! fan-out/join;无标注默认线性链(步骤 N depends_on 步骤 N-1)。
//! 失败姿态(绝不静默/阻塞):标注解析失败退线性;整体解析失败 → 全文单 root task。
//! 落图**非原子**(逐条 add-node/add-edge):先 root 后逐步骤,任意前缀合法图;
//! 第 k 步失败 → root 打 plan_commit=incomplete + 明示(调用方 UI)。

const std = @import("std");
const client_mod = @import("client.zig");

pub const MAX_STEPS = 40; // 防病态计划炸 store;超出截断并告知。

pub const Step = struct {
    text: []const u8, // borrow(指向 plan_text)
    /// 依赖的步骤序号(1-based,指向本计划内其它步骤)。空 = 线性(依赖前一步)。
    deps: []const usize, // owned
};

pub const ParseResult = struct {
    /// root 标题(计划首行/概述;borrow)。
    title: []const u8,
    steps: []Step, // owned(steps + 各 deps)
    truncated: bool,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        for (self.steps) |s| allocator.free(s.deps);
        allocator.free(self.steps);
    }
};

/// 解析计划正文为 root 标题 + 步骤(含依赖)。steps.len==0 → 无结构(调用方落单 root task)。
pub fn parse(allocator: std.mem.Allocator, plan_text: []const u8) !ParseResult {
    var steps: std.ArrayList(Step) = .empty;
    errdefer {
        for (steps.items) |s| allocator.free(s.deps);
        steps.deinit(allocator);
    }

    var title: []const u8 = "计划";
    var title_found = false;
    var truncated = false;

    var it = std.mem.splitScalar(u8, plan_text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        const item = stripListMarker(line);
        if (item == null) {
            // 非列表行:首个非空行当标题。
            if (!title_found) {
                title = trimHeading(line);
                title_found = true;
            }
            continue;
        }
        if (steps.items.len >= MAX_STEPS) {
            truncated = true;
            break;
        }
        const step_text = item.?;
        const deps = try parseDeps(allocator, step_text, steps.items.len);
        errdefer allocator.free(deps);
        try steps.append(allocator, .{ .text = stripDepAnnotation(step_text), .deps = deps });
    }

    return .{
        .title = title,
        .steps = try steps.toOwnedSlice(allocator),
        .truncated = truncated,
    };
}

/// 列表标记剥离:`- ` / `* ` / `N. ` / `N) ` → 返回内容;非列表行返 null。
fn stripListMarker(line: []const u8) ?[]const u8 {
    if (line.len < 2) return null;
    // 无序:- 或 * 后跟空格
    if ((line[0] == '-' or line[0] == '*') and line[1] == ' ') {
        return std.mem.trim(u8, line[2..], " \t");
    }
    // 有序:数字前缀 + . 或 ) + 空格
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i > 0 and i < line.len and (line[i] == '.' or line[i] == ')')) {
        const rest = line[i + 1 ..];
        if (rest.len > 0 and rest[0] == ' ') return std.mem.trim(u8, rest[1..], " \t");
    }
    return null;
}

/// 标题去 markdown 前缀(# / **)。
fn trimHeading(line: []const u8) []const u8 {
    var s = line;
    while (s.len > 0 and (s[0] == '#' or s[0] == ' ')) s = s[1..];
    s = std.mem.trim(u8, s, "* \t");
    return if (s.len > 0) s else "计划";
}

/// 解析行尾 `(depends: 2,3)` → 依赖步骤序号(0-based)。无标注 → 线性(依赖前一步,
/// 若非首步)。标注解析失败 → 退线性(渐进降级,绝不阻塞)。
fn parseDeps(allocator: std.mem.Allocator, step_text: []const u8, step_index: usize) ![]usize {
    const marker = "(depends:";
    if (std.mem.indexOf(u8, step_text, marker)) |start| {
        const after = step_text[start + marker.len ..];
        const end = std.mem.indexOfScalar(u8, after, ')') orelse after.len;
        var deps: std.ArrayList(usize) = .empty;
        errdefer deps.deinit(allocator);
        var num_it = std.mem.splitScalar(u8, after[0..end], ',');
        while (num_it.next()) |tok| {
            const t = std.mem.trim(u8, tok, " \t");
            if (t.len == 0) continue;
            const n = std.fmt.parseInt(usize, t, 10) catch continue; // 单个坏值跳过
            if (n >= 1 and n <= step_index) { // 1-based,只能依赖前面的步骤(防环)
                try deps.append(allocator, n - 1);
            }
        }
        if (deps.items.len > 0) return deps.toOwnedSlice(allocator);
        deps.deinit(allocator);
    }
    // 无有效标注 → 线性:非首步依赖前一步。
    if (step_index == 0) return allocator.alloc(usize, 0);
    const linear = try allocator.alloc(usize, 1);
    linear[0] = step_index - 1;
    return linear;
}

fn stripDepAnnotation(step_text: []const u8) []const u8 {
    if (std.mem.indexOf(u8, step_text, "(depends:")) |i| {
        return std.mem.trim(u8, step_text[0..i], " \t");
    }
    return step_text;
}

pub const CommitResult = struct {
    root_id: u64,
    steps_committed: usize,
    total_steps: usize,
    incomplete: bool, // 部分失败(第 k 步落图失败)
    structured: bool, // false = 解析无结构,落成单 root task
    truncated: bool, // 计划超 MAX_STEPS 被截断(M1:绝不静默)
    doc_id: u64 = 0, // legacy 批准计划文档;只作审计材料,不是真实进度源;0=未导入
};

/// 把计划落成任务 DAG。返回 root id(供指针文件持久化)。
/// 崩溃安全序:先 root 后逐步骤(节点→contain→depends_on),任意前缀合法图。
pub fn commit(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    plan_text: []const u8,
) client_mod.KgError!CommitResult {
    var parsed = parse(allocator, plan_text) catch return client_mod.KgError.OutOfMemory;
    defer parsed.deinit(allocator);

    // 无结构(<2 步)→ 全文单 root task(设计:绝不因解析失败不落图)。
    if (parsed.steps.len < 2) {
        const root = try kg.createTask(plan_text, "plan_step");
        const doc = kg.importMarkdownDoc(plan_text) catch 0; // 人类可见文档(bonus,失败不阻塞)
        return .{ .root_id = root, .steps_committed = 0, .total_steps = 0, .incomplete = false, .structured = false, .truncated = parsed.truncated, .doc_id = doc };
    }

    const root = try kg.createTask(parsed.title, "plan_step");
    var step_ids = allocator.alloc(u64, parsed.steps.len) catch return client_mod.KgError.OutOfMemory;
    defer allocator.free(step_ids);

    var committed: usize = 0;
    for (parsed.steps, 0..) |step, i| {
        // 子任务原语(节点+contain 一体):steps **不直挂 project**——root 已挂 task 锚,
        // steps 经 root 可达(membership 下钻),直挂是拍平反模式。失败即停,前缀已是合法图。
        const sid = kg.createChildTask(root, step.text, "plan_step") catch {
            return .{ .root_id = root, .steps_committed = committed, .total_steps = parsed.steps.len, .incomplete = true, .structured = true, .truncated = parsed.truncated };
        };
        step_ids[i] = sid;
        for (step.deps) |dep_idx| {
            if (dep_idx < i) { // 只连已建的前驱
                kg.addEdge(sid, "depends_on", step_ids[dep_idx]) catch {
                    return .{ .root_id = root, .steps_committed = committed, .total_steps = parsed.steps.len, .incomplete = true, .structured = true, .truncated = parsed.truncated };
                };
            }
        }
        committed += 1;
    }

    // 兼容保留批准时的原始 Markdown 审计材料；当前状态由 task snapshot 重新投影，
    // 不再把这份不可同步更新的 document 当作进度真源。失败不阻塞任务 DAG。
    const doc = kg.importMarkdownDoc(plan_text) catch 0;
    return .{ .root_id = root, .steps_committed = committed, .total_steps = parsed.steps.len, .incomplete = false, .structured = true, .truncated = parsed.truncated, .doc_id = doc };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parse: 有序列表 + 线性依赖" {
    const a = testing.allocator;
    var r = try parse(a,
        \\重构解析器
        \\1. 读现有代码
        \\2. 写新实现
        \\3. 补测试
    );
    defer r.deinit(a);
    try testing.expectEqualStrings("重构解析器", r.title);
    try testing.expectEqual(@as(usize, 3), r.steps.len);
    try testing.expectEqualStrings("读现有代码", r.steps[0].text);
    try testing.expectEqual(@as(usize, 0), r.steps[0].deps.len); // 首步无依赖
    try testing.expectEqual(@as(usize, 1), r.steps[1].deps.len); // 依赖前一步
    try testing.expectEqual(@as(usize, 0), r.steps[1].deps[0]);
}

test "parse: depends 标注 fan-out/join" {
    const a = testing.allocator;
    var r = try parse(a,
        \\# 并行计划
        \\- 步骤A
        \\- 步骤B (depends: 1)
        \\- 步骤C (depends: 1)
        \\- 步骤D (depends: 2,3)
    );
    defer r.deinit(a);
    try testing.expectEqual(@as(usize, 4), r.steps.len);
    try testing.expectEqualStrings("步骤A", r.steps[0].text);
    // B、C 都依赖 A(fan-out)。
    try testing.expectEqual(@as(usize, 0), r.steps[1].deps[0]);
    try testing.expectEqual(@as(usize, 0), r.steps[2].deps[0]);
    // D 依赖 B、C(join)。
    try testing.expectEqual(@as(usize, 2), r.steps[3].deps.len);
    try testing.expectEqual(@as(usize, 1), r.steps[3].deps[0]);
    try testing.expectEqual(@as(usize, 2), r.steps[3].deps[1]);
    // dep 标注被剥离出正文。
    try testing.expect(std.mem.indexOf(u8, r.steps[3].text, "depends") == null);
}

test "parse: 无结构(<2 步)→ steps 空" {
    const a = testing.allocator;
    var r = try parse(a, "就修个 typo,没有步骤");
    defer r.deinit(a);
    try testing.expect(r.steps.len < 2);
}

test "parse: 坏 depends 标注退线性(不阻塞)" {
    const a = testing.allocator;
    var r = try parse(a,
        \\计划
        \\- 步骤一
        \\- 步骤二 (depends: 垃圾)
    );
    defer r.deinit(a);
    try testing.expectEqual(@as(usize, 2), r.steps.len);
    // 坏标注 → 退线性(依赖前一步)。
    try testing.expectEqual(@as(usize, 1), r.steps[1].deps.len);
    try testing.expectEqual(@as(usize, 0), r.steps[1].deps[0]);
}

test "parse: 前向依赖被丢弃(防环)" {
    const a = testing.allocator;
    var r = try parse(a,
        \\计划
        \\- A (depends: 2)
        \\- B
    );
    defer r.deinit(a);
    // A 依赖 B(2)是前向引用,只能依赖前面 → 丢弃 → 首步无依赖。
    try testing.expectEqual(@as(usize, 0), r.steps[0].deps.len);
}

test "MAX_STEPS 截断" {
    const a = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "大计划\n");
    var i: usize = 0;
    while (i < MAX_STEPS + 10) : (i += 1) {
        const line = try std.fmt.allocPrint(a, "- 步骤{d}\n", .{i});
        defer a.free(line);
        try buf.appendSlice(a, line);
    }
    var r = try parse(a, buf.items);
    defer r.deinit(a);
    try testing.expectEqual(@as(usize, MAX_STEPS), r.steps.len);
    try testing.expect(r.truncated);
}
