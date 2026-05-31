//! L2 组件测试:Task* 工具缺必需字段时返回**具名** error(e2e triage 修复)。
//!
//! 背景(doc/E2E_FRAMEWORK_DESIGN.md §8 + 全 17 场景 e2e):
//!   MiniMax 模型常对 Task/TaskCreate 发空参 {},cc-zig 原先返回笼统 error.MissingField
//!   → agent_loop 给模型的现场是 "TaskCreate failed with MissingField"(不说缺哪个字段)
//!   → 模型原地空参重试 40+ 次(input={} 风暴)。
//!
//! 修复:对齐 Bash=MissingCommand / Grep=MissingPattern 约定,按字段返回具名 error
//!   (MissingSubject / MissingTaskId / MissingPrompt),现场告诉模型缺哪个字段。
//!
//! 本测验证具名 error 真的端到端生效(execute 缺字段 → 具名 error,非 MissingField)。

const std = @import("std");
const cc = @import("cc");

fn ctxWithStore(store: *cc.core_task_store.TaskStore) cc.tool_context.ToolContext {
    return cc.tool_context.ToolContext{ .allocator = std.testing.allocator, .tasks = store };
}

test "L2 triage: TaskCreate({}) → 具名 MissingSubject(非 MissingField)" {
    var store = cc.core_task_store.TaskStore.init(std.testing.allocator);
    defer store.deinit();
    const ctx = ctxWithStore(&store);
    try std.testing.expectError(error.MissingSubject, cc.task_tools.executeCreate(&ctx, "{}"));
}

test "L2 triage: TaskGet({}) → 具名 MissingTaskId" {
    var store = cc.core_task_store.TaskStore.init(std.testing.allocator);
    defer store.deinit();
    const ctx = ctxWithStore(&store);
    try std.testing.expectError(error.MissingTaskId, cc.task_tools.executeGet(&ctx, "{}"));
}

test "L2 triage: TaskCreate(有 subject) 仍正常工作(未破坏 happy path)" {
    var store = cc.core_task_store.TaskStore.init(std.testing.allocator);
    defer store.deinit();
    const ctx = ctxWithStore(&store);
    const r = try cc.task_tools.executeCreate(&ctx, "{\"subject\":\"hello\",\"description\":\"d\"}");
    defer std.testing.allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"id\":\"1\"") != null);
}

// Task 工具(subagent):缺 prompt → 具名 MissingPrompt。
// 注意 execute 先查 depth/api_client 依赖,故这里只能间接断言错误名常量存在;
// 完整路径在 e2e(真模型空参 → 现场含 MissingPrompt)。这里锁住 errorToJson 映射:
// MissingPrompt 归 invalid_args(Missing* 前缀),detail 含字段名。
test "L2 triage: tool_error 把 MissingPrompt 归 invalid_args + detail 留名" {
    const a = std.testing.allocator;
    const j = try cc.tool_error.errorToJson("MissingPrompt", "Task failed with {s}", .{"MissingPrompt"}, a);
    defer a.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "invalid_args") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "MissingPrompt") != null);
}
