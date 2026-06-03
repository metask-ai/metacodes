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

fn requireStore(ctx: *const ToolContext) !*task_store.TaskStore {
    return ctx.tasks orelse return error.TaskStoreUnavailable;
}

// ------------------ 参数抽取 helpers ------------------
// JSON 入参，工具 args 已由 client.zig 累积成完整 UTF-8。这里只做"找字段"，不做 strict schema。
//
// 两类 helper：
//   extractString / extractStringOrError —— 返回 raw slice，借 args 底层内存，
//     仅用于 ID / enum 等"保证无转义"的字段（taskId、status）。
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

    const t = try store.create(subject, description, active_form);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "{\"task\":{\"id\":");
    try writeString(&out, ctx.allocator, t.id);
    try out.appendSlice(ctx.allocator, ",\"subject\":");
    try writeString(&out, ctx.allocator, t.subject);
    try out.appendSlice(ctx.allocator, "}}");
    return try out.toOwnedSlice(ctx.allocator);
}

// ============================================================================
// TaskGet
// ============================================================================

pub fn executeGet(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const store = try requireStore(ctx);
    const id = try extractStringOrError(args, "taskId");
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

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.append(ctx.allocator, '[');
    for (store.tasks.items, 0..) |t, i| {
        if (i > 0) try out.append(ctx.allocator, ',');
        try writeTaskJson(&out, ctx.allocator, t, false);
    }
    try out.append(ctx.allocator, ']');
    return try out.toOwnedSlice(ctx.allocator);
}

// ============================================================================
// TaskUpdate
// ============================================================================

pub fn executeUpdate(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const store = try requireStore(ctx);
    const id = try extractStringOrError(args, "taskId");

    if (try extractString(args, "status")) |status_str| {
        const st = TaskStatus.fromString(status_str) orelse return error.InvalidStatus;
        try store.updateStatus(id, st);
        if (st == .deleted) {
            // 删除后不能再拿 id 查找；提前返回避免后续字段更新。
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

    const store = try requireStore(ctx);
    const id = try extractStringOrError(args, "taskId");
    try store.updateStatus(id, .completed);
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
        if (data[p] != '"') return error.MalformedArray;
        p += 1;
        const start = p;
        // 读到下一个非转义 "
        while (p < data.len) : (p += 1) {
            if (data[p] == '\\') {
                p += 1;
                continue;
            }
            if (data[p] == '"') break;
        }
        if (p >= data.len) return error.MalformedArray;
        // unescape：把 \n \" \\ \uXXXX 转回来（与文本字段处理一致）
        const s = try util_json.unescapeString(data[start..p], allocator);
        errdefer allocator.free(s);
        try list.append(allocator, s);
        p += 1;
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
