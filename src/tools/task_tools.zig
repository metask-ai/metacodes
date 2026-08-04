//! Task* 工具族：共享一份 args 解析 + 序列化代码，5 个 execute 函数分别注册。
//!
//! 5 件套：
//! - TaskCreate(subject, description, active_form?) → `{task:{id,subject}}`
//! - TaskGet(taskId) → 完整 Task JSON
//! - TaskList() → `[{id,subject,status,owner?,blockedBy}]`
//! - TaskUpdate(taskId, status?|subject?|description?|active_form?|owner?|addBlocks?|addBlockedBy?) → `{ok:true}`
//! - TaskStop(taskId) → 等价于 TaskUpdate(taskId, status=completed)
//!
//! 所有工具都需要 ctx.tasks 非空；未挂载返 error.TaskStoreUnavailable。

const std = @import("std");
const ToolContext = @import("context.zig").ToolContext;
const task_store = @import("../core/task_store.zig");
const TaskStatus = task_store.TaskStatus;
const Task = task_store.Task;
const util_json = @import("../util/json.zig");
const common = @import("common.zig");
const log = @import("../util/log.zig");
const KgClient = @import("../kg/client.zig").KgClient;

const TASK_PACKET_LIMIT: usize = 12;
const TASK_PACKET_MAX_CHARS: usize = 8_000;

fn kgAgentIdent(ctx: *const ToolContext) []const u8 {
    return ctx.kg_agent_ident orelse ctx.agent_ident.asSlice();
}

/// Append a trusted same-version TinyKG JSON envelope as a nested value.
/// Failure is represented by the caller; never pretend a title-only TaskGet
/// is a complete recovery packet.
fn appendTaskPacketField(
    ctx: *const ToolContext,
    kg: *KgClient,
    task_node: u64,
    out: *std.ArrayList(u8),
) !bool {
    const packet = kg.taskPacketMeta(task_node, TASK_PACKET_LIMIT, TASK_PACKET_MAX_CHARS) catch return false;
    defer kg.allocator.free(packet);
    try out.appendSlice(ctx.allocator, ",\"task_packet\":");
    try out.appendSlice(ctx.allocator, packet);
    return true;
}

/// U6 A2:任务 DAG frontier 变更 → 经 event_reporter 发 tasks_changed 信号(默认轻量
/// invalidated,UI 重拉 frontier)。无 reporter(headless/子 agent/单测)→ no-op。在每个
/// **成功 mutation** 出口调(create/update/status/delete/stop-todo)。best-effort 不阻塞工具。
fn noteTasksChanged(ctx: *const ToolContext) void {
    if (ctx.event_reporter) |r| r.tasksChanged(.invalidated);
}

/// 任务闭合结构化投影(改动一 —— 分类的"结晶点"):把模型在闭合时提供的
/// acts_on/uses/produces 写成 concept 节点 + ref 边(默认 tentative)。任务开始时的分类是猜的,
/// 闭合时才知道真实用了什么——这是"伴随执行浮现、闭合时质量最高"原则的落点。
/// **写入失败不得阻塞任务闭合**(degraded 非依赖):任一步失败 log+continue,任务已闭合。
fn writeClosureProjection(ctx: *const ToolContext, kg: *KgClient, task_node: u64, args: []const u8) void {
    const Field = struct { field: []const u8, rel: []const u8 };
    const fields = [_]Field{
        .{ .field = "acts_on", .rel = "acts_on" },
        .{ .field = "uses", .rel = "uses" },
        .{ .field = "produces", .rel = "produces" },
    };
    var wrote_any = false;
    for (fields) |f| {
        const items = (extractStringArray(ctx.allocator, args, f.field) catch continue) orelse continue;
        defer freeStringArray(ctx.allocator, items);
        for (items) |raw| {
            const name = std.mem.trim(u8, raw, " \t\r\n");
            if (name.len == 0 or name.len > 200) continue;
            const concept = kg.ensureConcept(name) catch |e| {
                log.warn("kg", "closure projection ensureConcept({s}) failed: {s}", .{ name, @errorName(e) });
                continue;
            };
            // tentative(confirmed=false):agent 执行中打的,人类确认/纠正才落 confirmed。
            kg.addRefEdge(task_node, f.rel, concept, false) catch |e| {
                log.warn("kg", "closure projection {s}→{d} failed: {s}", .{ f.rel, concept, @errorName(e) });
                continue;
            };
            wrote_any = true;
        }
    }
    // 发现面:登记有待确认分类的任务,/kg 状态页提示人类去 /kg refs 审阅结晶。
    if (wrote_any) kg.notePendingRefTask(task_node);
}

fn requireStore(ctx: *const ToolContext) !*task_store.TaskStore {
    return ctx.tasks orelse return error.TaskStoreUnavailable;
}

// ------------------ 参数抽取 helpers ------------------
// JSON 入参，工具 args 已由 client.zig 累积成完整 UTF-8。这里只做"找字段"，不做 strict schema。
//
// 三类 helper：
//   extractString / extractStringOrError —— 返回 raw slice，借 args 底层内存，
//     仅用于 enum 等"保证带引号且无转义"的字段（status）。
//   extractIdOrError —— id 类字段（taskId），容忍裸数字（模型常发 "taskId":1 非 "1"）。
//   extractUnescaped / extractUnescapedOrError —— 返回 owned bytes，已 JSON-unescape，
//     用于模型可能塞 \n \" 的文本字段（subject、description、activeForm、owner）。
//     调用方负责 free。

/// 把 field 名映射到具名 error(对齐 Bash=MissingCommand 约定),让 agent_loop 的
/// "{tool} failed with MissingSubject" 现场告诉模型缺哪个字段,而非笼统 MissingField
/// (模型据此原地空参重试,见 e2e Task/TaskCreate input={} 风暴)。
fn missingFieldError(field: []const u8) anyerror {
    if (std.mem.eql(u8, field, "subject")) return error.MissingSubject;
    if (std.mem.eql(u8, field, "taskId")) return error.MissingTaskId;
    if (std.mem.eql(u8, field, "description")) return error.MissingDescription;
    if (std.mem.eql(u8, field, "status")) return error.MissingStatus;
    return error.MissingField;
}

fn extractString(args: []const u8, field: []const u8) !?[]const u8 {
    return util_json.extractStringField(args, field);
}

fn extractStringOrError(args: []const u8, field: []const u8) ![]const u8 {
    return util_json.extractStringField(args, field) orelse return missingFieldError(field);
}

/// 取 id 类字段(taskId),**容忍裸数字**:模型常把数字 id 发成 `"taskId":1` 而非 `"1"`
/// (实测:TaskCreate 返 id="1" 后模型调 TaskUpdate 发 `"taskId":1` → 旧版误报 MissingTaskId)。
/// id 永不含 JSON 转义(序列号/slug),故借 raw slice 即可,无需 unescape。
fn extractIdOrError(args: []const u8, field: []const u8) ![]const u8 {
    return util_json.extractStringOrNumberField(args, field) orelse return missingFieldError(field);
}

fn extractUnescaped(allocator: std.mem.Allocator, args: []const u8, field: []const u8) !?[]u8 {
    const raw = util_json.extractStringField(args, field) orelse return null;
    return try util_json.unescapeString(raw, allocator);
}

fn extractUnescapedOrError(allocator: std.mem.Allocator, args: []const u8, field: []const u8) ![]u8 {
    const raw = util_json.extractStringField(args, field) orelse return missingFieldError(field);
    return try util_json.unescapeString(raw, allocator);
}

// ------------------ JSON 输出 helpers ------------------

fn writeString(dst: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try util_json.serializeString(s, dst, allocator);
}

fn writeTaskJson(
    dst: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    t: *const Task,
    full: bool,
) !void {
    try dst.append(allocator, '{');
    try dst.appendSlice(allocator, "\"id\":");
    try writeString(dst, allocator, t.id);
    try dst.appendSlice(allocator, ",\"subject\":");
    try writeString(dst, allocator, t.subject);
    try dst.appendSlice(allocator, ",\"status\":");
    try writeString(dst, allocator, t.status.toString());

    if (t.owner) |o| {
        try dst.appendSlice(allocator, ",\"owner\":");
        try writeString(dst, allocator, o);
    }

    if (full) {
        try dst.appendSlice(allocator, ",\"description\":");
        try writeString(dst, allocator, t.description);
        if (t.active_form) |af| {
            try dst.appendSlice(allocator, ",\"activeForm\":");
            try writeString(dst, allocator, af);
        }
        try dst.appendSlice(allocator, ",\"blocks\":[");
        for (t.blocks.items, 0..) |b, i| {
            if (i > 0) try dst.append(allocator, ',');
            try writeString(dst, allocator, b);
        }
        try dst.appendSlice(allocator, "],\"blockedBy\":[");
        for (t.blocked_by.items, 0..) |b, i| {
            if (i > 0) try dst.append(allocator, ',');
            try writeString(dst, allocator, b);
        }
        try dst.append(allocator, ']');
    } else {
        // list 视图里 blockedBy 影响可调度性，一并返
        try dst.appendSlice(allocator, ",\"blockedBy\":[");
        for (t.blocked_by.items, 0..) |b, i| {
            if (i > 0) try dst.append(allocator, ',');
            try writeString(dst, allocator, b);
        }
        try dst.append(allocator, ']');
    }
    try dst.append(allocator, '}');
}

// ============================================================================
// TaskCreate
// ============================================================================

pub fn executeCreate(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const store = try requireStore(ctx);

    const subject = try extractUnescapedOrError(ctx.allocator, args, "subject");
    defer ctx.allocator.free(subject);
    // description 必填(对齐 cc TaskCreateTool 的 z.string() + schema required)。
    // 缺字段返具名 MissingDescription(不再 orelse "" 静默吞掉,与 schema 声明一致)。
    const description = try extractUnescapedOrError(ctx.allocator, args, "description");
    defer ctx.allocator.free(description);
    const active_form = try extractUnescaped(ctx.allocator, args, "activeForm");
    defer if (active_form) |af| ctx.allocator.free(af);

    // KG write-through(设计 v3 §2:图为唯一真相):KG 可用 → todo 直接落图挂 inbox root,
    // 返回 id="kg-<node>"(单命名空间——后续 TaskUpdate/Get/Stop 一律走 kg- 路由)。
    // 失败(KG 降级/落图错)→ 退内存 store(现状,id="N")。**绝不 brick**:任何 KG 错都不
    // 让 TaskCreate 失败,只退内存(KG 是增强非依赖)。
    if (createKgTask(ctx, subject, description)) |kg_node| {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(ctx.allocator);
        try out.appendSlice(ctx.allocator, "{\"task\":{\"id\":\"kg-");
        const idbuf = try std.fmt.allocPrint(ctx.allocator, "{d}", .{kg_node});
        defer ctx.allocator.free(idbuf);
        try out.appendSlice(ctx.allocator, idbuf);
        try out.appendSlice(ctx.allocator, "\",\"subject\":");
        try writeString(&out, ctx.allocator, subject);
        try out.appendSlice(ctx.allocator, ",\"persisted\":true}}");
        noteTasksChanged(ctx); // U6:新任务入 frontier
        return try out.toOwnedSlice(ctx.allocator);
    }

    const t = try store.create(subject, description, active_form);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "{\"task\":{\"id\":");
    try writeString(&out, ctx.allocator, t.id);
    try out.appendSlice(ctx.allocator, ",\"subject\":");
    try writeString(&out, ctx.allocator, t.subject);
    try out.appendSlice(ctx.allocator, "}}");
    noteTasksChanged(ctx); // U6:新任务入 frontier
    return try out.toOwnedSlice(ctx.allocator);
}

/// TaskCreate write-through:把 todo 落图挂 inbox root。返回 kg node id(成功)或 null(降级/失败)。
/// **best-effort 且绝不 brick**:任何一步失败都返 null → 上层退内存 store。
fn createKgTask(ctx: *const ToolContext, subject: []const u8, description: []const u8) ?u64 {
    const kg = ctx.kg orelse return null;
    if (!kg.ready or ctx.kg_projects_dir.len == 0) return null;

    const inbox = ensureInboxRoot(ctx, kg) orelse return null;

    // 节点文本 = subject + 换行 + description(首行 = 看板标题,firstLineTrunc 只取首行)。
    const text = if (description.len > 0)
        std.fmt.allocPrint(ctx.allocator, "{s}\n{s}", .{ subject, description }) catch return null
    else
        ctx.allocator.dupe(u8, subject) catch return null;
    defer ctx.allocator.free(text);

    // 子任务原语:todo 挂 inbox root(contains),不直挂 project(inbox root 已挂 task 锚,
    // 归属经下钻可达;旧 createTask+addEdge 是双挂拍平)。
    const node = kg.createChildTask(inbox, text, "todo") catch return null;

    // **镜像进内存 store**(PM P0-A 回归修复):图是持久真相,store 是 TaskTab/TaskList 的
    // 同步显示缓存。不镜像 → TaskTab 只读 store → KG ready 时面板全黑(任务落图但面板不读图)。
    if (ctx.tasks) |store| {
        var idbuf: [24]u8 = undefined;
        const kg_id = std.fmt.bufPrint(&idbuf, "kg-{d}", .{node}) catch return node;
        store.createWithId(kg_id, subject, description, .pending) catch {};
    }
    return node;
}

/// 从 store 移除 kg- 镜像(闭合/删除计划步骤或 todo 后,让 TaskTab/TaskList 同步消失)。
fn removeKgMirror(ctx: *const ToolContext, node_id: u64) void {
    const store = ctx.tasks orelse return;
    var idbuf: [24]u8 = undefined;
    const kg_id = std.fmt.bufPrint(&idbuf, "kg-{d}", .{node_id}) catch return;
    store.updateStatus(kg_id, .deleted) catch {}; // 缺失 → no-op
}

/// 懒建 inbox root(会话待办容器)。读 kg_inbox 指针;缺失/stale → 建新 root task + 写指针。
/// 返回 inbox root id 或 null(KG 错)。
fn ensureInboxRoot(ctx: *const ToolContext, kg: *@import("../kg/client.zig").KgClient) ?u64 {
    const inject = @import("../kg/inject.zig");
    if (inject.readIdPointer(ctx.allocator, ctx.kg_projects_dir, "kg_inbox")) |id| {
        // stale 校验:指针指向的必须仍是 task(被 GC/改写则重建)。
        if (kg.nodeIsTask(id) catch false) return id;
        inject.clearIdPointer(ctx.allocator, ctx.kg_projects_dir, "kg_inbox");
    }
    const root = kg.createTask("会话待办(ad-hoc todos)", "inbox_root") catch return null;
    inject.writeIdPointer(ctx.allocator, ctx.kg_projects_dir, "kg_inbox", root) catch {};
    // 12b:inbox root 已挂 task 锚(createTask 路由)——顺手写锚指针(frontier 单入口)。
    if (kg.ensureTaskAnchorId()) |aid| {
        inject.writeIdPointer(ctx.allocator, ctx.kg_projects_dir, "kg_task_anchor", aid) catch {};
    } else |_| {}
    return root;
}

// ============================================================================
// TaskGet
// ============================================================================

pub fn executeGet(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const id = try extractIdOrError(args, "taskId");

    // KG 任务的本地 TaskStore 只是 UI 镜像，不能成为读取旁路。尤其 claim 后镜像
    // 必然存在，若命中即返会在最需要恢复上下文时丢掉 parent/dependencies/evidence
    // packet。所有 kg-* TaskGet 都回 TinyKG 真源。
    if (std.mem.startsWith(u8, id, "kg-")) {
        return getKgTask(ctx, id["kg-".len..]);
    }

    const store = try requireStore(ctx);
    const t = store.get(id) orelse return error.TaskNotFound;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try writeTaskJson(&out, ctx.allocator, t, true);
    return try out.toOwnedSlice(ctx.allocator);
}

// ============================================================================
// TaskList
// ============================================================================

pub fn executeList(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    _ = args;
    const store = try requireStore(ctx);
    const kg_live = hasLiveKgFrontier(ctx);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.append(ctx.allocator, '[');
    var first = true;
    for (store.tasks.items) |t| {
        // Graph is authoritative whenever a live frontier pointer exists.
        // Local kg-* entries remain a UI/offline fallback only; emitting them
        // here would hide live claimed_by/readiness/status behind stale cache.
        if (kg_live and std.mem.startsWith(u8, t.id, "kg-")) continue;
        if (!first) try out.append(ctx.allocator, ',');
        first = false;
        try writeTaskJson(&out, ctx.allocator, t, false);
    }
    // KG 持久计划步骤(有活跃 kg_root 时,从 frontier 呈现;id="kg-<node>",readiness→status)。
    // 这让模型在同一份任务清单里看到跨会话计划步骤(设计 v3 §2:图为唯一真相)。
    // M3:原子——失败回滚 out 到追加前长度,绝不吐半截坏 JSON。
    const kg_mark = out.items.len;
    const kg_first_before = first;
    const parallel_ready = appendKgFrontier(ctx, &out, &first) catch blk: {
        out.shrinkRetainingCapacity(kg_mark);
        first = kg_first_before;
        // A pointer only says that a graph projection exists; it does not prove
        // that the live frontier subprocess succeeded.  On a transient KG
        // failure, keep the UI usable by falling back to the local kg-* cache.
        // The cache is appended only after the authoritative read has failed,
        // so it can never hide fresh claimed_by/readiness/status on success.
        for (store.tasks.items) |t| {
            if (!std.mem.startsWith(u8, t.id, "kg-")) continue;
            if (!first) try out.append(ctx.allocator, ',');
            first = false;
            try writeTaskJson(&out, ctx.allocator, t, false);
        }
        break :blk 0;
    };
    appendParallelHint(ctx, &out, &first, parallel_ready) catch {};
    try out.append(ctx.allocator, ']');
    return try out.toOwnedSlice(ctx.allocator);
}

fn hasLiveKgFrontier(ctx: *const ToolContext) bool {
    const kg = ctx.kg orelse return false;
    if (!kg.ready or ctx.kg_projects_dir.len == 0) return false;
    const inject = @import("../kg/inject.zig");
    return inject.readIdPointer(ctx.allocator, ctx.kg_projects_dir, "kg_task_anchor") != null or
        inject.readIdPointer(ctx.allocator, ctx.kg_projects_dir, "kg_root") != null or
        inject.readIdPointer(ctx.allocator, ctx.kg_projects_dir, "kg_inbox") != null;
}

/// 并行信号:frontier 的 ready 无主叶子集按定义相互无序(有未闭合排序边就不会 ready)
/// → k≥2 时是天然的 fan-out 候选。提示模型可起 subagent 各认领一叶,防串行浪费。
fn appendParallelHint(ctx: *const ToolContext, out: *std.ArrayList(u8), first: *bool, ready_unclaimed: usize) !void {
    if (ready_unclaimed < 2) return;
    if (!first.*) try out.append(ctx.allocator, ',');
    first.* = false;
    const hint = try std.fmt.allocPrint(
        ctx.allocator,
        "{{\"parallel_hint\":\"{d} 个 ready 任务相互无依赖,可并行:可用 Task 工具起后台 subagent 分别处理;每个 subagent 开工前先 TaskUpdate(status=in_progress)认领(租约防撞车),完成后 status=completed 闭合。\"}}",
        .{ready_unclaimed},
    );
    defer ctx.allocator.free(hint);
    try out.appendSlice(ctx.allocator, hint);
}

/// 把 KG 任务面 frontier 作为任务项追加进 TaskList 输出。
/// 12b 单入口:优先 kg_task_anchor(task 锚=总任务,深遍历一次看全多计划树+inbox);
/// 无锚指针(存量店)退回 kg_root(单计划 legacy)。readiness 是图派生的,必须每次读活值。
/// Live graph rows are authoritative. TaskStore kg-* mirrors are suppressed by
/// executeList and used only if this whole append fails. 空 inbox root 叶(全部
/// todo 闭合后的容器残影)按 kg_inbox 指针滤掉。
/// 返回 ready 且无主的叶子数(并行 fan-out 信号源)。
fn appendKgFrontier(ctx: *const ToolContext, out: *std.ArrayList(u8), first: *bool) !usize {
    const kg = ctx.kg orelse return 0;
    if (!kg.ready or ctx.kg_projects_dir.len == 0) return 0;
    const inject = @import("../kg/inject.zig");
    if (inject.readIdPointer(ctx.allocator, ctx.kg_projects_dir, "kg_task_anchor") != null) {
        const anchor_ready = try appendRootFrontier(ctx, out, first, "kg_task_anchor", true, null);
        // appendRootFrontier clears an authoritative empty/stale pointer. Fall
        // through to legacy roots immediately instead of requiring a restart.
        // A transient error returns above and preserves the anchor, so older
        // projections never masquerade as live truth.
        if (inject.readIdPointer(ctx.allocator, ctx.kg_projects_dir, "kg_task_anchor") != null) return anchor_ready;
    }
    // Legacy two-pointer stores:show both the plan and ad-hoc inbox instead of
    // letting a stale local mirror stand in for one half of the graph. The two
    // roots may overlap, so stable task ids are deduplicated across both reads.
    var seen = std.AutoHashMap(u64, void).init(ctx.allocator);
    defer seen.deinit();
    const plan_ready = try appendRootFrontier(ctx, out, first, "kg_root", true, &seen);
    const inbox_ready = try appendRootFrontier(ctx, out, first, "kg_inbox", false, &seen);
    return plan_ready + inbox_ready;
}

/// 12b frontier 行过滤:空 inbox root 容器残影。kg-* TaskStore mirrors are
/// suppressed at the store iteration, never by discarding authoritative rows.
fn skipFrontierRow(r: @import("../kg/client.zig").FrontierRow, inbox_id: ?u64) bool {
    if (inbox_id) |iid| {
        // inbox root 无开放子时以 leaf 现身——它是容器不是任务,永不该上看板。
        if (r.task_id == iid) return true;
    }
    return false;
}

/// 呈现单个 root 的 frontier。is_plan 标注 plan_step(true)vs inbox todo(false)。
/// 返回 ready 且无主的叶子数(供并行 fan-out 提示)。
fn appendRootFrontier(
    ctx: *const ToolContext,
    out: *std.ArrayList(u8),
    first: *bool,
    pointer_name: []const u8,
    is_plan: bool,
    seen: ?*std.AutoHashMap(u64, void),
) !usize {
    const kg = ctx.kg.?;
    const inject = @import("../kg/inject.zig");
    const root = inject.readIdPointer(ctx.allocator, ctx.kg_projects_dir, pointer_name) orelse return 0;
    // M2:省掉冗余 nodeIsTask spawn。frontier 的 data error 是权威结构失效
    // (NotFound/非 task/坏图)，可清 stale pointer；transient 不是缺席证据，必须
    // 保留 pointer 并上抛，避免旧投影冒充真源。
    const rows = kg.frontier(root, 50) catch |e| {
        if (e == error.Data) {
            inject.clearIdPointer(ctx.allocator, ctx.kg_projects_dir, pointer_name);
            return 0;
        }
        return e;
    };
    if (rows.len == 0) {
        inject.clearIdPointer(ctx.allocator, ctx.kg_projects_dir, pointer_name);
        kg.allocator.free(rows);
        return 0;
    }
    defer {
        // kg 内存契约:rows 是 kg.allocator 分的,必须用它释放(subagent 线程 ctx.allocator 不同源)。
        for (rows) |*r| r.deinit(kg.allocator);
        kg.allocator.free(rows);
    }
    // 12b 过滤器:空 inbox root 叶(容器残影)按 kg_inbox 指针滤。
    const inbox_id: ?u64 = inject.readIdPointer(ctx.allocator, ctx.kg_projects_dir, "kg_inbox");
    var ready_unclaimed: usize = 0;
    for (rows) |r| {
        if (skipFrontierRow(r, inbox_id)) continue;
        // branch = 开放复合节点(靠子树闭合),非可执行项;看板只列叶子/关联,
        // 结构上下文由叶子行的 path 面包屑承担。
        if (r.role == .branch) continue;
        if (seen) |ids| {
            const entry = try ids.getOrPut(r.task_id);
            if (entry.found_existing) continue;
        }
        if (r.role == .leaf and r.status == .open and r.readiness == .ready and r.claimed_by == null) ready_unclaimed += 1;
        if (!first.*) try out.append(ctx.allocator, ',');
        first.* = false;
        const status = switch (r.status) {
            .open => if (r.readiness == .ready) "pending" else "blocked",
            .claimed => "in_progress",
            .completed => "completed", // canonical frontier 不返回 completed；保守兼容。
            .failed => "blocked",
        };
        try out.appendSlice(ctx.allocator, "{\"id\":\"kg-");
        const idbuf = try std.fmt.allocPrint(ctx.allocator, "{d}", .{r.task_id});
        defer ctx.allocator.free(idbuf);
        try out.appendSlice(ctx.allocator, idbuf);
        try out.appendSlice(ctx.allocator, "\",\"subject\":");
        // subject = 首行(标题);write-through 的 todo 文本是 "subject\ndescription",
        // 计划步骤多为单行——两者都取首行做看板标题。
        const nl = std.mem.indexOfScalar(u8, r.text, '\n');
        const title = if (nl) |i| r.text[0..i] else r.text;
        try writeString(out, ctx.allocator, title);
        try out.appendSlice(ctx.allocator, ",\"status\":\"");
        try out.appendSlice(ctx.allocator, status);
        try out.appendSlice(ctx.allocator, "\",\"kg_status\":\"");
        try out.appendSlice(ctx.allocator, @tagName(r.status));
        try out.appendSlice(ctx.allocator, "\",\"");
        try out.appendSlice(ctx.allocator, if (is_plan) "plan_step" else "persisted");
        try out.appendSlice(ctx.allocator, "\":true,\"readiness\":\"");
        try out.appendSlice(ctx.allocator, @tagName(r.readiness));
        try out.appendSlice(ctx.allocator, "\"");
        if (r.path) |p| {
            try out.appendSlice(ctx.allocator, ",\"path\":");
            try writeString(out, ctx.allocator, p);
        }
        if (r.claimed_by) |c| {
            try out.appendSlice(ctx.allocator, ",\"claimed_by\":");
            try writeString(out, ctx.allocator, c);
        }
        try out.appendSlice(ctx.allocator, "}");
    }
    return ready_unclaimed;
}

/// KG 任务查询(TaskGet 的 kg-<node> 路由)。返回节点文本(首行 subject + 全文 description)。
fn getKgTask(ctx: *const ToolContext, node_id_str: []const u8) anyerror![]u8 {
    const kg = ctx.kg orelse return error.KgUnavailable;
    if (!kg.ready) return error.KgUnavailable;
    const node_id = std.fmt.parseInt(u64, node_id_str, 10) catch return error.TaskNotFound;
    const lifecycle = kg.taskStatus(node_id) catch return error.TaskNotFound;
    const text = kg.fetchNodeText(node_id) catch return error.TaskNotFound;
    defer kg.allocator.free(text); // kg 内存契约(见 KgClient 顶注)
    if (text.len == 0) return error.TaskNotFound;
    // 首行 = subject,全文 = description(与 createKgTask 的 subject\ndescription 对称)。
    const nl = std.mem.indexOfScalar(u8, text, '\n');
    const subject = if (nl) |i| text[0..i] else text;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "{\"id\":\"kg-");
    try out.appendSlice(ctx.allocator, node_id_str);
    try out.appendSlice(ctx.allocator, "\",\"subject\":");
    try writeString(&out, ctx.allocator, subject);
    try out.appendSlice(ctx.allocator, ",\"description\":");
    try writeString(&out, ctx.allocator, text);
    try out.appendSlice(ctx.allocator, ",\"status\":\"");
    try out.appendSlice(ctx.allocator, switch (lifecycle) {
        .open => "pending",
        .claimed => "in_progress",
        .completed => "completed",
        .failed => "blocked",
    });
    try out.appendSlice(ctx.allocator, "\",\"kg_status\":\"");
    try out.appendSlice(ctx.allocator, @tagName(lifecycle));
    try out.appendSlice(ctx.allocator, "\",\"persisted\":true");
    if (!(try appendTaskPacketField(ctx, kg, node_id, &out))) {
        try out.appendSlice(ctx.allocator, ",\"task_packet_unavailable\":true");
    }
    try out.append(ctx.allocator, '}');
    return try out.toOwnedSlice(ctx.allocator);
}

fn failKgTask(
    ctx: *const ToolContext,
    kg: *@import("../kg/client.zig").KgClient,
    node_id: u64,
    args: []const u8,
) anyerror![]u8 {
    const evidence = (try extractUnescaped(ctx.allocator, args, "conclusion")) orelse
        (try extractUnescaped(ctx.allocator, args, "evidence")) orelse
        (try extractUnescaped(ctx.allocator, args, "description")) orelse
        try ctx.allocator.dupe(u8, "failed/cancelled");
    defer ctx.allocator.free(evidence);
    kg.failTaskAs(node_id, evidence, kgAgentIdent(ctx)) catch |e| {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "标记任务失败({s}): {s}", .{ @errorName(e), kg.detail() });
        return error.KgCloseFailed;
    };
    // Authorization precedes every derived write. Stable task kind means the
    // terminal node remains a valid ref-edge source after task-close.
    writeClosureProjection(ctx, kg, node_id, args);
    removeKgMirror(ctx, node_id);
    noteTasksChanged(ctx);
    return try ctx.allocator.dupe(u8, "{\"ok\":true,\"failed\":true,\"kg_status\":\"failed\",\"preserved\":true}");
}

/// KG 计划步骤更新(TaskUpdate 的 kg-<node> 路由)。completed/failed 走 canonical
/// task-close；deleted 是旧兼容别名，在 KG 中也转 failed，绝不物理删除稳定 task id。
fn updateKgTask(ctx: *const ToolContext, node_id_str: []const u8, args: []const u8) anyerror![]u8 {
    const kg = ctx.kg orelse return error.KgUnavailable;
    if (!kg.ready) return error.KgUnavailable;
    const node_id = std.fmt.parseInt(u64, node_id_str, 10) catch return error.InvalidStatus;

    const status_str = (try extractString(args, "status")) orelse {
        common.setErrorDetail(ctx.error_detail, ctx.allocator, "KG 计划步骤只支持 status=pending|in_progress|completed|failed|deleted", .{});
        return error.InvalidStatus;
    };
    if (std.mem.eql(u8, status_str, "failed")) return failKgTask(ctx, kg, node_id, args);
    const st = TaskStatus.fromString(status_str) orelse return error.InvalidStatus;
    switch (st) {
        .completed => {
            // 一句话结论优先作闭合证据(改动一的"结晶":闭合时质量最高的一句总结);
            // 无 conclusion 才退回 evidence/description。
            const evidence = (try extractUnescaped(ctx.allocator, args, "conclusion")) orelse
                (try extractUnescaped(ctx.allocator, args, "evidence")) orelse
                (try extractUnescaped(ctx.allocator, args, "description")) orelse
                try ctx.allocator.dupe(u8, "completed");
            defer ctx.allocator.free(evidence);
            kg.closeTaskAs(node_id, evidence, kgAgentIdent(ctx)) catch |e| {
                common.setErrorDetail(ctx.error_detail, ctx.allocator, "闭合计划步骤失败({s}): {s}", .{ @errorName(e), kg.detail() });
                return error.KgCloseFailed;
            };
            // Terminal lifecycle is orthogonal to kind:the stable task remains
            // a valid projection source. Run only after authorization succeeds.
            writeClosureProjection(ctx, kg, node_id, args);
            removeKgMirror(ctx, node_id); // store 镜像同步消失(TaskTab/TaskList)
            // 搭车:返回更新后的 frontier(刷新看板——设计 §2.2 R2 幂等"看板"非"领任务")。
            // 闭合正是选下一步的时刻:ready 无主叶子 ≥2 时同样给并行提示。
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(ctx.allocator);
            try out.appendSlice(ctx.allocator, "{\"ok\":true,\"closed\":true,\"next\":");
            var first = true;
            try out.append(ctx.allocator, '[');
            const parallel_ready = appendKgFrontier(ctx, &out, &first) catch 0;
            appendParallelHint(ctx, &out, &first, parallel_ready) catch {};
            try out.append(ctx.allocator, ']');
            try out.appendSlice(ctx.allocator, "}");
            noteTasksChanged(ctx); // U6:闭合 → frontier 变(解锁下游)
            return out.toOwnedSlice(ctx.allocator);
        },
        .deleted => {
            // 兼容旧模型的 deleted 调用；持久任务的生命周期只有四态，删除不是状态。
            return failKgTask(ctx, kg, node_id, args);
        },
        else => {
            // in_progress/pending:状态本身是易失 UI 态(不落图),但**租约落图**——
            // in_progress = 本 session 认领(多 agent 并行防撞车,TTL 读侧过期),
            // pending = 释放租约(放回任务池)。撞他人未过期租约 → 明确报错引导换任务。
            var claimed_packet: ?[]u8 = null;
            defer if (claimed_packet) |packet| kg.allocator.free(packet);
            if (st == .in_progress) {
                kg.claimTask(node_id, kgAgentIdent(ctx)) catch {
                    common.setErrorDetail(ctx.error_detail, ctx.allocator, "任务 {d} 已被其他 session 认领(租约未过期): {s}。请用 TaskList 选择其他 ready 任务,或等租约过期。", .{ node_id, kg.detail() });
                    return error.KgClaimHeld;
                };
                // Claim without recovery context is not a usable state. Match
                // swarm self-assignment semantics: packet failure rolls the
                // just-acquired lease back instead of inviting title-only work.
                claimed_packet = kg.taskPacketMeta(node_id, TASK_PACKET_LIMIT, TASK_PACKET_MAX_CHARS) catch {
                    const packet_detail = try ctx.allocator.dupe(u8, kg.detail());
                    defer ctx.allocator.free(packet_detail);
                    kg.releaseTask(node_id, kgAgentIdent(ctx)) catch |release_err| {
                        common.setErrorDetail(ctx.error_detail, ctx.allocator, "任务 {d} 已认领但 task packet 获取失败，且自动释放也失败({s})；租约可能仍由 {s} 持有。packet 错误: {s}；release 错误: {s}", .{ node_id, @errorName(release_err), kgAgentIdent(ctx), packet_detail, kg.detail() });
                        return error.KgTaskPacketUnavailable;
                    };
                    common.setErrorDetail(ctx.error_detail, ctx.allocator, "任务 {d} 的 task packet 获取失败，刚取得的租约已自动释放；请稍后重试。{s}", .{ node_id, packet_detail });
                    return error.KgTaskPacketUnavailable;
                };
            } else if (st == .pending) {
                kg.releaseTask(node_id, kgAgentIdent(ctx)) catch |e| {
                    common.setErrorDetail(ctx.error_detail, ctx.allocator, "释放任务 {d} 租约失败({s}): {s}。任务仍保持原状态。", .{ node_id, @errorName(e), kg.detail() });
                    return error.KgReleaseFailed;
                };
            }
            if (st == .in_progress) {
                var out: std.ArrayList(u8) = .empty;
                errdefer out.deinit(ctx.allocator);
                // Build the complete response before touching the local mirror.
                // If construction fails, release the lease that the caller
                // never learned it owns; no projection then needs rollback.
                var response_committed = false;
                errdefer if (!response_committed) {
                    kg.releaseTask(node_id, kgAgentIdent(ctx)) catch {};
                };
                try out.appendSlice(ctx.allocator, "{\"ok\":true,\"claimed\":true,\"claimed_by\":");
                try writeString(&out, ctx.allocator, kgAgentIdent(ctx));
                try out.appendSlice(ctx.allocator, ",\"task_packet\":");
                try out.appendSlice(ctx.allocator, claimed_packet.?);
                try out.appendSlice(ctx.allocator, ",\"note\":\"已认领；先按 task_packet 恢复父目标、依赖和证据，再开始工作；完成后 status=completed 闭合\"}");
                const response = try out.toOwnedSlice(ctx.allocator);
                // 认领的计划步骤镜像上板:TaskTab 可见 + activeKgTaskId(溯源锚)
                // 能找到。todo 早有镜像;镜像失败不能推翻已完整构造的真源响应。
                if (ctx.tasks) |store| {
                    var idbuf: [24]u8 = undefined;
                    const kg_id = std.fmt.bufPrint(&idbuf, "kg-{d}", .{node_id}) catch unreachable;
                    if (store.get(kg_id) == null) {
                        if (kg.fetchNodeText(node_id)) |text| {
                            defer kg.allocator.free(text); // kg 内存契约:subagent 线程 ctx.allocator 不同源
                            const nl = std.mem.indexOfScalar(u8, text, '\n');
                            const subject = if (nl) |i| text[0..i] else text;
                            store.createWithId(kg_id, subject, text, .in_progress) catch {};
                        } else |_| {}
                    } else {
                        store.updateStatus(kg_id, .in_progress) catch {};
                    }
                }
                noteTasksChanged(ctx); // U6:claim → frontier 变
                response_committed = true;
                return response;
            }
            if (ctx.tasks) |store| {
                var idbuf: [24]u8 = undefined;
                const kg_id = std.fmt.bufPrint(&idbuf, "kg-{d}", .{node_id}) catch unreachable;
                store.updateStatus(kg_id, .pending) catch {};
            }
            noteTasksChanged(ctx); // U6:release → frontier 变
            return try ctx.allocator.dupe(u8, "{\"ok\":true,\"note\":\"已放回任务池(租约已释放)\"}");
        },
    }
}

// ============================================================================
// TaskUpdate
// ============================================================================

pub fn executeUpdate(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const id = try extractIdOrError(args, "taskId");

    // KG 计划步骤(id 形如 "kg-<node>",由 TaskList 从 frontier 呈现)→ 路由到 KG。
    // completed → task-close(保留 task kind/id/原文 + verified_by 独立证据,自动解锁 depends_on 链);
    // failed/deleted → failed 终态并保留稳定 task id。
    // 这是"DAG 驱动执行"的闭环:模型领 ready 步骤、干活、TaskUpdate completed → 下一步解锁。
    if (std.mem.startsWith(u8, id, "kg-")) {
        return updateKgTask(ctx, id["kg-".len..], args);
    }

    const store = try requireStore(ctx);
    if (try extractString(args, "status")) |status_str| {
        const st = TaskStatus.fromString(status_str) orelse return error.InvalidStatus;
        try store.updateStatus(id, st);
        if (st == .deleted) {
            // 删除后不能再拿 id 查找；提前返回避免后续字段更新。
            noteTasksChanged(ctx); // U6:frontier 变
            return try ctx.allocator.dupe(u8, "{\"ok\":true,\"deleted\":true}");
        }
    }

    // 字段更新（模型可能写 \n \" 等 JSON 转义，必须 unescape 后再存）
    // extractUnescaped 返回 owned bytes；store.update 采用 move 语义——
    // 无论成功/失败，store.update 负责 free（成功：赋给 task；失败：errdefer 清）。
    // 关键：必须在 `try store.update` **之前**把 local var 置 null，否则 store.update
    // 的 errdefer + executeUpdate 的 errdefer 在 error 路径下会 double-free。
    var subject = try extractUnescaped(ctx.allocator, args, "subject");
    errdefer if (subject) |s| ctx.allocator.free(s);
    var description = try extractUnescaped(ctx.allocator, args, "description");
    errdefer if (description) |s| ctx.allocator.free(s);
    var active_form = try extractUnescaped(ctx.allocator, args, "activeForm");
    errdefer if (active_form) |s| ctx.allocator.free(s);
    var owner = try extractUnescaped(ctx.allocator, args, "owner");
    errdefer if (owner) |s| ctx.allocator.free(s);

    if (subject != null or description != null or active_form != null or owner != null) {
        // Commit ownership: 把 local 拷到临时量并立刻清 local；
        // 之后 store.update 无论 OK/Err，executeUpdate 层的 errdefer 都不会再碰它们。
        const subj_tmp = subject;
        subject = null;
        const desc_tmp = description;
        description = null;
        const af_tmp = active_form;
        active_form = null;
        const own_tmp = owner;
        owner = null;
        try store.update(id, .{
            .subject = subj_tmp,
            .description = desc_tmp,
            .active_form = af_tmp,
            .owner = own_tmp,
        });
    } else {
        // 没有字段要更新：本来 extract* 都返 null，这里实际都是 null；
        // 理论上不会 free 任何东西，但写出来保持语义一致、防止未来误改。
        if (subject) |s| ctx.allocator.free(s);
        subject = null;
        if (description) |s| ctx.allocator.free(s);
        description = null;
        if (active_form) |s| ctx.allocator.free(s);
        active_form = null;
        if (owner) |s| ctx.allocator.free(s);
        owner = null;
    }

    // blocks / blockedBy：期望是 string 数组，简化只支持 addBlocks / addBlockedBy
    if (try extractStringArray(ctx.allocator, args, "addBlocks")) |items| {
        defer freeStringArray(ctx.allocator, items);
        try store.addBlocks(id, items);
    }
    if (try extractStringArray(ctx.allocator, args, "addBlockedBy")) |items| {
        defer freeStringArray(ctx.allocator, items);
        try store.addBlockedBy(id, items);
    }

    noteTasksChanged(ctx); // U6:status/字段/blocks 任一变 → frontier 信号
    return try ctx.allocator.dupe(u8, "{\"ok\":true}");
}

// ============================================================================
// TaskStop（快捷：等价于 update status=completed）
// ============================================================================

// TaskStop（统一分流，对齐 Claude Code 的统一 TaskStop）：
//   - agent_job_id 或 taskId 以 "agent_" 开头 → 终止后台 subagent(abort，非阻塞)。
//   - 否则 → todo 快捷：等价于 update status=completed。
// ============================================================================

pub fn executeStop(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    // 优先看 agent_job_id;没有再看 taskId 是否带 agent_ 前缀。
    const agent_id: ?[]const u8 = blk: {
        if (@import("../util/json.zig").extractStringField(args, "agent_job_id")) |aid| break :blk aid;
        if (@import("../util/json.zig").extractStringField(args, "taskId")) |tid| {
            if (std.mem.startsWith(u8, tid, "agent_")) break :blk tid;
        }
        break :blk null;
    };
    if (agent_id) |aid| {
        const reg = ctx.agent_jobs orelse return error.AgentJobsUnavailable;
        reg.kill(aid) catch |e| switch (e) {
            error.JobNotFound => return error.JobNotFound,
        };
        return std.fmt.allocPrint(ctx.allocator, "{{\"agent_job_id\":\"{s}\",\"status\":\"killing\"}}", .{aid});
    }

    const id = try extractIdOrError(args, "taskId");
    // KG 任务(kg-<node>)→ 闭合(与 TaskUpdate completed 同路径)。
    if (std.mem.startsWith(u8, id, "kg-")) {
        const kg = ctx.kg orelse return error.KgUnavailable;
        if (!kg.ready) return error.KgUnavailable;
        const node_id = std.fmt.parseInt(u64, id["kg-".len..], 10) catch return error.TaskNotFound;
        // conclusion 优先作闭合证据(与 updateKgTask 对齐)。
        const evidence = (try extractUnescaped(ctx.allocator, args, "conclusion")) orelse
            try ctx.allocator.dupe(u8, "completed");
        defer ctx.allocator.free(evidence);
        kg.closeTaskAs(node_id, evidence, kgAgentIdent(ctx)) catch |e| {
            common.setErrorDetail(ctx.error_detail, ctx.allocator, "闭合任务失败({s})", .{@errorName(e)});
            return error.KgCloseFailed;
        };
        // TaskStop 自称"等价 TaskUpdate completed"——投影与闭合顺序也必须同路径。
        writeClosureProjection(ctx, kg, node_id, args);
        removeKgMirror(ctx, node_id); // store 镜像同步消失
        noteTasksChanged(ctx); // U6:TaskStop 闭合 → frontier 变
        return try ctx.allocator.dupe(u8, "{\"ok\":true,\"status\":\"completed\"}");
    }
    const store = try requireStore(ctx);
    try store.updateStatus(id, .completed);
    noteTasksChanged(ctx); // U6:TaskStop 闭合 → frontier 变
    return try ctx.allocator.dupe(u8, "{\"ok\":true,\"status\":\"completed\"}");
}

// ============================================================================
// String array 解析（"addBlocks":["a","b","c"]）
// ============================================================================

fn freeStringArray(allocator: std.mem.Allocator, items: [][]const u8) void {
    for (items) |s| allocator.free(s);
    allocator.free(items);
}

/// 返回 owned 切片（每个元素 owned）或 null（字段缺失）。语法错误返空数组。
fn extractStringArray(
    allocator: std.mem.Allocator,
    data: []const u8,
    field: []const u8,
) !?[][]const u8 {
    // 定位 "field":[...]
    var buf: [128]u8 = undefined;
    if (field.len > 100) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    const pat = buf[0 .. 3 + field.len];
    const idx = std.mem.indexOf(u8, data, pat) orelse return null;

    var p = idx + pat.len;
    while (p < data.len and (data[p] == ' ' or data[p] == '\t')) : (p += 1) {}
    if (p >= data.len or data[p] != '[') return null;
    p += 1;

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }

    while (p < data.len) {
        while (p < data.len and (data[p] == ' ' or data[p] == '\t' or data[p] == ',')) : (p += 1) {}
        if (p >= data.len) break;
        if (data[p] == ']') break;
        if (data[p] == '"') {
            // 带引号字符串元素:读到下一个非转义 "。
            p += 1;
            const start = p;
            while (p < data.len) : (p += 1) {
                if (data[p] == '\\') {
                    p += 1;
                    continue;
                }
                if (data[p] == '"') break;
            }
            if (p >= data.len) return error.MalformedArray;
            // unescape:把 \n \" \\ \uXXXX 转回来(与文本字段处理一致)
            const s = try util_json.unescapeString(data[start..p], allocator);
            errdefer allocator.free(s);
            try list.append(allocator, s);
            p += 1;
        } else {
            // 裸元素(数字 id 等):模型常把 id 数组发成 `"addBlocks":[1,2]` 而非 `["1","2"]`
            // (同 taskId 裸数字 bug,见 extractStringOrNumberField)。取到 ,/]/空白前的 token。
            const start = p;
            while (p < data.len) : (p += 1) {
                const c = data[p];
                if (c == ',' or c == ']' or c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
            }
            if (p == start) return error.MalformedArray;
            const s = try allocator.dupe(u8, data[start..p]);
            errdefer allocator.free(s);
            try list.append(allocator, s);
        }
    }

    return try list.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn testCtx(store: *task_store.TaskStore) ToolContext {
    return ToolContext{ .allocator = testing.allocator, .tasks = store };
}

test "U6 A2: tasks_changed 经 event_reporter 在 create/update/stop 各发一次(DoD 端到端接线)" {
    const ui_event = @import("../core/protocol/ui_event.zig");
    // 记录型 reporter:数 tasksChanged 次数;agentLifecycle 不该被 task 工具触发。
    const Rec = struct {
        tasks: usize = 0,
        agents: usize = 0,
        fn tasksCb(c: *anyopaque, ev: ui_event.TasksChanged) void {
            _ = ev;
            const self: *@This() = @ptrCast(@alignCast(c));
            self.tasks += 1;
        }
        fn agentCb(c: *anyopaque, ev: ui_event.AgentLifecycle) void {
            _ = ev;
            const self: *@This() = @ptrCast(@alignCast(c));
            self.agents += 1;
        }
        fn reporter(self: *@This()) ui_event.EventReporter {
            return .{ .ctx = @ptrCast(self), .agentFn = &agentCb, .tasksFn = &tasksCb };
        }
    };
    var rec = Rec{};
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    var ctx = testCtx(&store);
    ctx.event_reporter = rec.reporter();

    testing.allocator.free(try executeCreate(&ctx, "{\"subject\":\"A\",\"description\":\"Da\"}"));
    try testing.expectEqual(@as(usize, 1), rec.tasks); // create → 1

    testing.allocator.free(try executeUpdate(&ctx, "{\"taskId\":\"1\",\"status\":\"in_progress\"}"));
    try testing.expectEqual(@as(usize, 2), rec.tasks); // update → 2

    testing.allocator.free(try executeStop(&ctx, "{\"taskId\":\"1\"}"));
    try testing.expectEqual(@as(usize, 3), rec.tasks); // stop → 3

    // 删除也发。
    testing.allocator.free(try executeUpdate(&ctx, "{\"taskId\":\"1\",\"status\":\"deleted\"}"));
    try testing.expectEqual(@as(usize, 4), rec.tasks); // delete → 4

    try testing.expectEqual(@as(usize, 0), rec.agents); // task 工具绝不发 agent_lifecycle
}

test "TaskCreate + TaskList roundtrip" {
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    const ctx = testCtx(&store);

    const r1 = try executeCreate(&ctx, "{\"subject\":\"First\",\"description\":\"D1\"}");
    defer testing.allocator.free(r1);
    try testing.expect(std.mem.indexOf(u8, r1, "\"id\":\"1\"") != null);

    const r2 = try executeCreate(&ctx, "{\"subject\":\"Second\",\"description\":\"D2\",\"activeForm\":\"Seconding\"}");
    defer testing.allocator.free(r2);
    try testing.expect(std.mem.indexOf(u8, r2, "\"id\":\"2\"") != null);

    const list = try executeList(&ctx, "{}");
    defer testing.allocator.free(list);
    try testing.expect(std.mem.indexOf(u8, list, "\"First\"") != null);
    try testing.expect(std.mem.indexOf(u8, list, "\"Second\"") != null);
    try testing.expect(std.mem.indexOf(u8, list, "\"status\":\"pending\"") != null);
}

// e2e triage 修复:缺必需字段返回**具名** error(非笼统 MissingField),
// 让模型从 "TaskCreate failed with MissingSubject" 知道缺哪个字段而非原地空参重试。
test "TaskCreate({}) 缺 subject → 具名 MissingSubject(非 MissingField)" {
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    const ctx = testCtx(&store);
    try testing.expectError(error.MissingSubject, executeCreate(&ctx, "{}"));
}

// 对齐 cc:description 必填。早先实现 `orelse ""` 静默吞掉缺失,与 schema required
// 声明矛盾。现在缺 description(但有 subject)返具名 MissingDescription。
test "TaskCreate 有 subject 缺 description → 具名 MissingDescription" {
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    const ctx = testCtx(&store);
    try testing.expectError(error.MissingDescription, executeCreate(&ctx, "{\"subject\":\"S\"}"));
}

test "TaskGet({}) 缺 taskId → 具名 MissingTaskId" {
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    const ctx = testCtx(&store);
    try testing.expectError(error.MissingTaskId, executeGet(&ctx, "{}"));
}

test "missingFieldError 映射" {
    try testing.expectEqual(error.MissingSubject, missingFieldError("subject"));
    try testing.expectEqual(error.MissingTaskId, missingFieldError("taskId"));
    try testing.expectEqual(error.MissingField, missingFieldError("unknown_field"));
}

test "TaskGet returns full task" {
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    const ctx = testCtx(&store);

    const c = try executeCreate(&ctx, "{\"subject\":\"X\",\"description\":\"Desc\",\"activeForm\":\"Doing\"}");
    testing.allocator.free(c);

    const g = try executeGet(&ctx, "{\"taskId\":\"1\"}");
    defer testing.allocator.free(g);
    try testing.expect(std.mem.indexOf(u8, g, "\"description\":\"Desc\"") != null);
    try testing.expect(std.mem.indexOf(u8, g, "\"activeForm\":\"Doing\"") != null);
    try testing.expect(std.mem.indexOf(u8, g, "\"blocks\":[]") != null);
}

test "TaskGet non-existent errors" {
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    const ctx = testCtx(&store);
    try testing.expectError(error.TaskNotFound, executeGet(&ctx, "{\"taskId\":\"99\"}"));
}

test "TaskUpdate: 裸数字 taskId 容错(真 bug:模型发 \"taskId\":1 非 \"1\" → 旧版误报 MissingTaskId)" {
    // 实测真 tty:TaskCreate 返 id="1" 后,模型调 TaskUpdate 发 {"status":"completed","taskId":1}
    // (数字,非字符串)。旧版 extractStringField 只认带引号值 → null → MissingTaskId。
    // 修:taskId 走 extractStringOrNumberField,裸数字 1 取成 "1",命中 store。
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    const ctx = testCtx(&store);
    const c = try executeCreate(&ctx, "{\"subject\":\"X\",\"description\":\"D\"}");
    testing.allocator.free(c);

    // 裸数字 taskId(模型真实发送形态)→ 应成功更新,不再 MissingTaskId。
    const u = try executeUpdate(&ctx, "{\"status\":\"completed\",\"taskId\":1}");
    defer testing.allocator.free(u);
    try testing.expect(std.mem.indexOf(u8, u, "\"ok\":true") != null);
    // 验证确实命中 id="1" 的任务(状态真改成 completed)。
    const g = try executeGet(&ctx, "{\"taskId\":1}"); // Get 也容忍裸数字
    defer testing.allocator.free(g);
    try testing.expect(std.mem.indexOf(u8, g, "\"status\":\"completed\"") != null);
}

test "TaskGet: 裸数字 taskId 容错" {
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    const ctx = testCtx(&store);
    const c = try executeCreate(&ctx, "{\"subject\":\"X\",\"description\":\"D\"}");
    testing.allocator.free(c);
    const g = try executeGet(&ctx, "{\"taskId\":1}"); // 裸数字
    defer testing.allocator.free(g);
    try testing.expect(std.mem.indexOf(u8, g, "\"subject\":\"X\"") != null);
}

test "TaskUpdate status + field + blocks" {
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    const ctx = testCtx(&store);

    testing.allocator.free(try executeCreate(&ctx, "{\"subject\":\"A\",\"description\":\"Da\"}"));
    testing.allocator.free(try executeCreate(&ctx, "{\"subject\":\"B\",\"description\":\"Db\"}"));

    const r = try executeUpdate(&ctx, "{\"taskId\":\"1\",\"status\":\"in_progress\",\"owner\":\"me\",\"addBlocks\":[\"2\"]}");
    defer testing.allocator.free(r);

    try testing.expect(store.get("1").?.status == .in_progress);
    try testing.expectEqualStrings("me", store.get("1").?.owner.?);
    try testing.expect(store.get("1").?.blocks.items.len == 1);
    try testing.expectEqualStrings("2", store.get("1").?.blocks.items[0]);
}

test "TaskUpdate addBlocks: 裸数字数组元素容错(模型发 addBlocks:[2] 非 [\"2\"])" {
    // 同 taskId 裸数字 bug:id 数组里模型也常发裸数字。旧版 extractStringArray 撞非引号元素
    // → MalformedArray → addBlocks 整个失败。修:裸元素也取 token。
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    const ctx = testCtx(&store);
    testing.allocator.free(try executeCreate(&ctx, "{\"subject\":\"A\",\"description\":\"Da\"}"));
    testing.allocator.free(try executeCreate(&ctx, "{\"subject\":\"B\",\"description\":\"Db\"}"));
    testing.allocator.free(try executeCreate(&ctx, "{\"subject\":\"C\",\"description\":\"Dc\"}"));

    // 裸数字 taskId + 裸数字数组元素(模型真实形态)。
    const r = try executeUpdate(&ctx, "{\"taskId\":1,\"addBlocks\":[2,3]}");
    defer testing.allocator.free(r);
    try testing.expect(store.get("1").?.blocks.items.len == 2);
    try testing.expectEqualStrings("2", store.get("1").?.blocks.items[0]);
    try testing.expectEqualStrings("3", store.get("1").?.blocks.items[1]);
}

test "TaskStop: 裸数字 taskId 容错" {
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    const ctx = testCtx(&store);
    testing.allocator.free(try executeCreate(&ctx, "{\"subject\":\"A\",\"description\":\"Da\"}"));
    const r = try executeStop(&ctx, "{\"taskId\":1}"); // 裸数字
    defer testing.allocator.free(r);
    try testing.expect(store.get("1").?.status == .completed);
}

test "TaskUpdate delete removes task" {
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    const ctx = testCtx(&store);

    testing.allocator.free(try executeCreate(&ctx, "{\"subject\":\"A\",\"description\":\"Da\"}"));
    const r = try executeUpdate(&ctx, "{\"taskId\":\"1\",\"status\":\"deleted\"}");
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "\"deleted\":true") != null);
    try testing.expect(store.get("1") == null);
}

test "TaskUpdate on missing id: no leak, no double-free across layers" {
    // 覆盖的是 executeUpdate 层的 errdefer × store.update 层的 errdefer 交互。
    // 修复 double-free 前：store.update 抛 TaskNotFound → store 层 errdefer free 了 4 个 owned bytes
    // → 控制回 executeUpdate → executeUpdate 的 errdefer 再 free 一次 = allocator abort。
    // 修复后：调用前把 local 全部置 null，executeUpdate 的 errdefer 不再触发。
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    const ctx = testCtx(&store);

    // 全字段都提供，走"有字段要更新"的 commit 分支
    try testing.expectError(error.TaskNotFound, executeUpdate(
        &ctx,
        "{\"taskId\":\"999\",\"subject\":\"s\",\"description\":\"d\",\"activeForm\":\"af\",\"owner\":\"o\"}",
    ));
    // 若 double-free / leak，testing.allocator 会在整个 test 结束时 fail
}

test "TaskStop marks completed" {
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    const ctx = testCtx(&store);

    testing.allocator.free(try executeCreate(&ctx, "{\"subject\":\"A\",\"description\":\"\"}"));
    const r = try executeStop(&ctx, "{\"taskId\":\"1\"}");
    defer testing.allocator.free(r);
    try testing.expect(store.get("1").?.status == .completed);
}

test "Task* without store returns TaskStoreUnavailable" {
    const ctx = ToolContext{ .allocator = testing.allocator };
    try testing.expectError(error.TaskStoreUnavailable, executeCreate(&ctx, "{\"subject\":\"x\",\"description\":\"\"}"));
    try testing.expectError(error.TaskStoreUnavailable, executeList(&ctx, "{}"));
    try testing.expectError(error.TaskStoreUnavailable, executeGet(&ctx, "{\"taskId\":\"1\"}"));
    try testing.expectError(error.TaskStoreUnavailable, executeUpdate(&ctx, "{\"taskId\":\"1\",\"status\":\"completed\"}"));
    try testing.expectError(error.TaskStoreUnavailable, executeStop(&ctx, "{\"taskId\":\"1\"}"));
}

test "extractStringArray parses items + empty" {
    const a = testing.allocator;

    const items = (try extractStringArray(a, "{\"addBlocks\":[\"a\",\"b\",\"c\"]}", "addBlocks")).?;
    defer freeStringArray(a, items);
    try testing.expect(items.len == 3);
    try testing.expectEqualStrings("a", items[0]);
    try testing.expectEqualStrings("c", items[2]);

    const empty = (try extractStringArray(a, "{\"addBlocks\":[]}", "addBlocks")).?;
    defer freeStringArray(a, empty);
    try testing.expect(empty.len == 0);

    const missing = try extractStringArray(a, "{\"other\":1}", "addBlocks");
    try testing.expect(missing == null);
}
