//! KG 注入段构建(设计 v3-final §5)。
//!
//! 渐进披露:注入段只是启动快照(plan root 标题 + ready 前 3 + 计数 + 时效声明),
//! 实时真相靠 TaskList。**空态零输出**(无 kg_root / frontier 空 → 一个字不注入)。
//! 预算:记忆通道合计目标 300-600 tok(本段自身 ≤ ~40 行硬截断兜底)。
//!
//! 线程模型(P1 现状):App.initKg **同步**调 buildSummary(内部 spawn tinykg;本地未竞争
//! store 为毫秒级)。锁竞争时最坏挂 35s——**P2 待办**:移后台线程,产不可变快照,主线程
//! turn 边界取用(设计 §5 要求启动零阻塞)。此处不谎称已线程化(Linus M2)。

const std = @import("std");
const pfs = @import("platform").fs;
const client_mod = @import("client.zig");

pub const MAX_READY_SHOWN: usize = 3;

/// 读 per-project 指针文件(kg_root / kg_inbox;设计 §2)。缺失/空/非数字 → null。
/// 线程安全:路径缓冲在栈上(主线程 /kg 与后台构建线程都会调)。
pub fn readIdPointer(allocator: std.mem.Allocator, projects_dir: []const u8, name: []const u8) ?u64 {
    const path = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ projects_dir, name }, 0) catch return null;
    defer allocator.free(path);
    const f = pfs.fopen(path.ptr, "r") orelse return null;
    defer _ = std.c.fclose(f);
    var buf: [32]u8 = undefined;
    const n = std.c.fread(&buf, 1, buf.len - 1, f);
    if (n == 0) return null;
    const s = std.mem.trim(u8, buf[0..n], " \r\n\t");
    return std.fmt.parseInt(u64, s, 10) catch null;
}

/// 写指针文件(plan 落图/inbox 懒建时用;P2 主用,P1 供测试与 /kg)。
pub fn writeIdPointer(allocator: std.mem.Allocator, projects_dir: []const u8, name: []const u8, id: u64) !void {
    const path = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ projects_dir, name }, 0) catch return error.OutOfMemory;
    defer allocator.free(path);
    const f = pfs.fopen(path.ptr, "w") orelse return error.WriteFailed;
    defer _ = std.c.fclose(f);
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}\n", .{id}) catch unreachable;
    _ = std.c.fwrite(s.ptr, 1, s.len, f);
}

/// 删指针文件(stale 防御:root NotFound → 清指针,设计 §3)。
pub fn clearIdPointer(allocator: std.mem.Allocator, projects_dir: []const u8, name: []const u8) void {
    const path = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ projects_dir, name }, 0) catch return;
    defer allocator.free(path);
    pfs.unlinkPath(path.ptr) catch {};
}

const RootLoad = enum { loaded, invalid, unavailable };

/// Load one pointer root into owned row storage. `invalid` is authoritative
/// (the id is not a task) and clears the pointer; `unavailable` covers
/// transient subprocess/allocation failures and deliberately preserves it.
fn appendRootRows(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    projects_dir: []const u8,
    pointer_name: []const u8,
    root_id: u64,
    rows: *std.ArrayList(client_mod.FrontierRow),
) RootLoad {
    const is_task = kg.nodeIsTask(root_id) catch return .unavailable;
    if (!is_task) {
        clearIdPointer(allocator, projects_dir, pointer_name);
        return .invalid;
    }
    const fetched = kg.frontier(root_id, 50) catch return .unavailable;
    rows.appendSlice(kg.allocator, fetched) catch {
        for (fetched) |*r| r.deinit(kg.allocator);
        kg.allocator.free(fetched);
        return .unavailable;
    };
    // Row-owned strings moved into rows; only release the old slice container.
    kg.allocator.free(fetched);
    return .loaded;
}

/// 构建注入段。返回 null = 空态(零输出);否则 owned 字符串。
/// 在后台线程调用(内部 spawn tinykg;主线程绝不直接调)。
/// 两部分:① 记忆数锚(count>0 时,提升 recall 采用率——PM#3);② plan frontier(有活跃图时)。
pub fn buildSummary(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    projects_dir: []const u8,
) ?[]u8 {
    return buildSummaryForAgent(allocator, kg, projects_dir, "");
}

/// Startup/resume variant. If this exact host-injected identity still owns a
/// live lease, include one bounded packet so a fresh process can recover the
/// active objective without depending on transcript prose.
pub fn buildSummaryForAgent(
    allocator: std.mem.Allocator,
    kg: *client_mod.KgClient,
    projects_dir: []const u8,
    agent_identity: []const u8,
) ?[]u8 {
    if (!kg.ready) return null;
    // 类型 facet(domain 准确 + 按 schema_type 分布);替代旧 memoryCount(全库节点计数,含别项目+任务)。
    const facet = kg.memoryFacet(allocator);
    defer if (facet) |f| f.deinit(allocator);
    const mem_count: usize = if (facet) |f| f.total else 0;
    const breakdown: []const u8 = if (facet) |f| f.breakdown else "";

    // 任务面 frontier(可选)。12b 单入口:优先 task 锚(一次看全多计划+inbox)。
    // 存量店可能只有 kg_root、只有 kg_inbox，或两者并存；两者都读，避免 fresh
    // process 恰好漏掉 inbox 中仍由自己持有租约的任务。
    var row_storage: std.ArrayList(client_mod.FrontierRow) = .empty;
    defer {
        for (row_storage.items) |*r| r.deinit(kg.allocator);
        row_storage.deinit(kg.allocator);
    }
    var root_id: u64 = 0;
    const anchor_ptr = readIdPointer(allocator, projects_dir, "kg_task_anchor");
    var load_legacy = anchor_ptr == null;
    if (anchor_ptr) |anchor| {
        switch (appendRootRows(allocator, kg, projects_dir, "kg_task_anchor", anchor, &row_storage)) {
            .loaded => root_id = anchor,
            .invalid => load_legacy = true, // stale anchor:fall back in this same startup.
            .unavailable => {}, // transient failure:preserve pointer and do not trust older roots.
        }
    }
    if (load_legacy) {
        const RootPointer = struct { name: []const u8, id: ?u64 };
        const roots = [_]RootPointer{
            .{ .name = "kg_root", .id = readIdPointer(allocator, projects_dir, "kg_root") },
            .{ .name = "kg_inbox", .id = readIdPointer(allocator, projects_dir, "kg_inbox") },
        };
        for (roots) |root| {
            const rid = root.id orelse continue;
            if (appendRootRows(allocator, kg, projects_dir, root.name, rid, &row_storage) == .loaded and root_id == 0) {
                root_id = rid;
            }
        }
    }
    // Legacy pointers may overlap (including both pointing at the same root, or
    // one subtree containing the other). Frontier rows are identified by their
    // stable task id; collapse duplicates before counting, rendering, or
    // choosing a resume packet. Compaction moves ownership into the retained
    // prefix, deinitializing only the duplicate copies.
    var unique_len: usize = 0;
    var row_index: usize = 0;
    while (row_index < row_storage.items.len) : (row_index += 1) {
        var duplicate = false;
        for (row_storage.items[0..unique_len]) |prior| {
            if (prior.task_id == row_storage.items[row_index].task_id) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            row_storage.items[row_index].deinit(kg.allocator);
            continue;
        }
        if (unique_len != row_index) row_storage.items[unique_len] = row_storage.items[row_index];
        unique_len += 1;
    }
    row_storage.shrinkRetainingCapacity(unique_len);
    const rows = row_storage.items;
    var view: []const client_mod.FrontierRow = rows;
    if (rows.len > 0) {
        if (readIdPointer(allocator, projects_dir, "kg_inbox")) |inbox_id| {
            // inbox root 行(容器残影)滤出视图;不 deinit(原片 defer 统一释放)。
            var keep: usize = 0;
            for (rows, 0..) |r, i| {
                if (r.task_id == inbox_id) continue;
                if (keep != i) std.mem.swap(client_mod.FrontierRow, &rows[keep], &rows[i]);
                keep += 1;
            }
            view = rows[0..keep];
        }
    }

    var resume_packet: ?[]u8 = null;
    defer if (resume_packet) |packet| kg.allocator.free(packet);
    if (agent_identity.len > 0) {
        for (view) |r| {
            const holder = r.claimed_by orelse continue;
            if (r.status != .claimed or !std.mem.eql(u8, holder, agent_identity)) continue;
            resume_packet = kg.taskPacketMeta(r.task_id, 12, 8_000) catch null;
            break; // startup budget:one current work packet;TaskList handles the rest.
        }
    }

    // 全空(无记忆 + 无 frontier)→ 空态零输出。
    if (mem_count == 0 and view.len == 0) return null;
    return renderSummaryFull(allocator, root_id, view, mem_count, breakdown, resume_packet) catch null;
}

/// 纯渲染(可单测):记忆数锚(带类型 breakdown)+ frontier rows → 注入段文本。
pub fn renderSummary(allocator: std.mem.Allocator, root_id: u64, rows: []const client_mod.FrontierRow, mem_count: usize, breakdown: []const u8) ![]u8 {
    return renderSummaryFull(allocator, root_id, rows, mem_count, breakdown, null);
}

fn renderSummaryFull(
    allocator: std.mem.Allocator,
    root_id: u64,
    rows: []const client_mod.FrontierRow,
    mem_count: usize,
    breakdown: []const u8,
    resume_packet: ?[]const u8,
) ![]u8 {
    // v2 深遍历:branch 行是结构上下文(开放复合节点),不算可执行任务;
    // 计数与"ready 前 3"只看叶子/关联(frontier 的可执行集语义)。
    var ready_count: usize = 0;
    var blocked_count: usize = 0;
    var claimed_count: usize = 0;
    var failed_count: usize = 0;
    for (rows) |r| {
        if (r.role == .branch) continue;
        if (r.status == .failed) {
            failed_count += 1;
        } else if (r.status == .claimed) {
            claimed_count += 1;
        } else if (r.readiness == .ready) {
            ready_count += 1;
        } else {
            blocked_count += 1;
        }
    }
    const visible_count = ready_count + blocked_count + claimed_count + failed_count;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "# Knowledge Graph\n");
    // ① 记忆数锚 + 类型 facet(采用率:让模型知道"图里有货且有类型",recall 前先查、可按 type 过滤)。
    if (mem_count > 0) {
        if (breakdown.len > 0) {
            try appendPrint(&out, allocator, "本项目/全局共 {d} 条持久记忆({s})——处理涉及既往决策/约定的任务前,先 KgRecall(可加 type=<decision|module|bug|…> 过滤)。\n", .{ mem_count, breakdown });
        } else {
            try appendPrint(&out, allocator, "本项目/全局共 {d} 条持久记忆——处理涉及既往决策/约定的任务前,先 KgRecall。\n", .{mem_count});
        }
    }
    // ② plan frontier(有活跃图时)。
    if (visible_count > 0) {
        if (claimed_count > 0 or failed_count > 0) {
            try appendPrint(&out, allocator, "持久任务图(root {d}):{d} ready / {d} blocked / {d} claimed / {d} failed(共 {d})\n", .{ root_id, ready_count, blocked_count, claimed_count, failed_count, visible_count });
        } else {
            try appendPrint(&out, allocator, "持久任务图(root {d}):{d} ready / {d} blocked(共 {d})\n", .{ root_id, ready_count, blocked_count, visible_count });
        }
        var shown: usize = 0;
        for (rows) |r| {
            if (r.role == .branch) continue;
            if (r.status != .open) continue;
            if (r.readiness != .ready) continue;
            if (shown >= MAX_READY_SHOWN) break;
            shown += 1;
            if (r.path) |p| {
                try appendPrint(&out, allocator, "- [{d}] {s} › {s}", .{ r.task_id, p, firstLineTrunc(r.text, 120) });
            } else {
                try appendPrint(&out, allocator, "- [{d}] {s}", .{ r.task_id, firstLineTrunc(r.text, 120) });
            }
            if (r.claimed_by) |c| {
                try appendPrint(&out, allocator, "(已被 {s} 认领)", .{c});
            }
            try out.appendSlice(allocator, "\n");
        }
        if (ready_count > MAX_READY_SHOWN) try appendPrint(&out, allocator, "- …还有 {d} 个 ready 任务\n", .{ready_count - MAX_READY_SHOWN});
        for (rows) |r| {
            if (r.status != .claimed) continue;
            try appendPrint(&out, allocator, "- CLAIMED [{d}] {s}", .{ r.task_id, firstLineTrunc(r.text, 120) });
            if (r.claimed_by) |c| try appendPrint(&out, allocator, " (by {s})", .{c});
            try out.appendSlice(allocator, "\n");
        }
        for (rows) |r| {
            if (r.status != .failed) continue;
            try appendPrint(&out, allocator, "- FAILED [{d}] {s}\n", .{ r.task_id, firstLineTrunc(r.text, 120) });
        }
        try out.appendSlice(allocator, "此为启动快照,以 TaskList 实时结果为准。\n");
    }
    if (resume_packet) |packet| {
        try out.appendSlice(allocator, "## Active task recovery packet\n当前 session 仍持有下面任务的有效租约。先按 packet 恢复父目标、依赖、证据和 continuation，再继续工作；不要只凭摘要猜测。\n");
        try out.appendSlice(allocator, packet);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn appendPrint(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(line);
    try out.appendSlice(allocator, line);
}

fn firstLineTrunc(text: []const u8, max: usize) []const u8 {
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    // 只在**因 max 截断**(切点可能落在多字节字符中间)时才回退到 UTF-8 边界。
    // line_end 是自然边界(字符完整),不能回退——否则会把 '\n' 前最后一个完整 CJK
    // 字符切掉、产出坏 UTF-8("步骤一:读代码" → "步骤一:读代�")。
    if (line_end <= max) return text[0..line_end];
    var end = max;
    while (end > 0 and (text[end - 1] & 0xC0) == 0x80) end -= 1; // 回到字符起点,不切半个字
    return text[0..end];
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "renderSummary 空态外的完整渲染:计数/ready 前3/快照声明" {
    const a = testing.allocator;
    var rows = [_]client_mod.FrontierRow{
        .{ .task_id = 11, .readiness = .ready, .text = @constCast("步骤一:读代码\n第二行不显示") },
        .{ .task_id = 12, .readiness = .missing_dependencies, .text = @constCast("步骤二") },
        .{ .task_id = 13, .readiness = .ready, .text = @constCast("步骤三") },
        .{ .task_id = 14, .readiness = .ready, .text = @constCast("步骤四") },
        .{ .task_id = 15, .readiness = .ready, .text = @constCast("步骤五") },
    };
    const s = try renderSummary(a, 1, &rows, 5, "3 decision · 2 module");
    defer a.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "root 1") != null);
    try testing.expect(std.mem.indexOf(u8, s, "5 条持久记忆") != null);
    try testing.expect(std.mem.indexOf(u8, s, "3 decision · 2 module") != null); // 类型 breakdown 注入
    try testing.expect(std.mem.indexOf(u8, s, "type=") != null); // 引导 typed recall
    try testing.expect(std.mem.indexOf(u8, s, "4 ready / 1 blocked(共 5)") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[11] 步骤一:读代码") != null);
    try testing.expect(std.mem.indexOf(u8, s, "第二行不显示") == null); // 只取首行
    try testing.expect(std.mem.indexOf(u8, s, "[15]") == null); // 超出前3不列
    try testing.expect(std.mem.indexOf(u8, s, "还有 1 个 ready") != null);
    try testing.expect(std.mem.indexOf(u8, s, "以 TaskList 实时结果为准") != null);
}

test "指针文件读写清:round-trip + 缺失 null + 垃圾 null" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &pbuf);
    const dir = pbuf[0..dir_len];

    try testing.expect(readIdPointer(a, dir, "kg_root") == null); // 缺失
    try writeIdPointer(a, dir, "kg_root", 42);
    try testing.expectEqual(@as(?u64, 42), readIdPointer(a, dir, "kg_root"));
    clearIdPointer(a, dir, "kg_root");
    try testing.expect(readIdPointer(a, dir, "kg_root") == null);
}
