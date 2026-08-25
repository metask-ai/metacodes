//! L2 组件测试(层2):工具执行冒烟 —— 统一走 dispatch 整链。
//!
//! 与既有 src/tools/*.zig 单测的区别:那些**直调 execute**,绕过了 dispatch 的
//! validateRequired + validateTypes 前置校验链;而 agent_loop 实际走的是 dispatch。
//! 本测试用 cc.tools.dispatch(&ctx, name, args) 跑完整链路,确保:
//!   ① 正常入参 → 工具执行成功、输出含预期;
//!   ② 缺 required 字段 → 字段具名 Missing* error(校验链拦在 execute 前);
//!   ③ 类型错 → InvalidFieldType。
//! 每工具 2-3 例(正常 + 错误/边界)。
//!
//! 不可在纯 L2 自动化执行的工具(WebFetch 需网络、Cron 需时钟、PushNotification 发
//! 系统通知、AskUserQuestion 需 TTY、Monitor 长驻、Worktree 改 cwd+git、MCP 需 server)
//! 不在此造执行冒烟——它们的 schema 由 tool_schema_coverage_test 覆盖,执行覆盖缺口
//! 已在测试差距清单登记(见 tests/README.md)。

const std = @import("std");
const cc = @import("cc");

const tools = cc.tools;
const ToolContext = cc.tool_context.ToolContext;

fn simpleCtx(a: std.mem.Allocator) ToolContext {
    return ToolContext.simple(a);
}

/// Built-in smoke cases can only produce `.ok`; keep the typed dispatch
/// boundary explicit while transferring the returned bytes to the caller.
fn dispatchOk(ctx: *const ToolContext, name: []const u8, args: []const u8) ![]u8 {
    var outcome = try tools.dispatch(ctx, name, args);
    return switch (outcome) {
        .ok => |*body| (try body.takeModelBytes(ctx.allocator)).bytes,
        else => {
            outcome.deinit(ctx.allocator);
            return error.UnexpectedDispatchOutcome;
        },
    };
}

// ============================================================================
// dispatch 校验链(所有工具共享的前置层)
// ============================================================================

test "L2 smoke/dispatch: 缺 required → 字段具名错误(链路拦在 execute 前)" {
    const a = std.testing.allocator;
    var ctx = simpleCtx(a);
    try std.testing.expectError(error.MissingContent, tools.dispatch(&ctx, "Write", "{\"file_path\":\"/tmp/x\"}"));
    try std.testing.expectError(error.MissingCommand, tools.dispatch(&ctx, "Bash", "{}"));
    try std.testing.expectError(error.MissingDescription, tools.dispatch(&ctx, "TaskCreate", "{\"subject\":\"S\"}"));
}

test "L2 smoke/dispatch: 类型错 → InvalidFieldType" {
    const a = std.testing.allocator;
    var ctx = simpleCtx(a);
    try std.testing.expectError(error.InvalidFieldType, tools.dispatch(&ctx, "Bash", "{\"command\":\"ls\",\"timeout\":\"5\"}"));
    try std.testing.expectError(error.InvalidFieldType, tools.dispatch(&ctx, "Read", "{\"file_path\":\"/x\",\"limit\":\"10\"}"));
}

test "L2 smoke/dispatch: 未知工具 → UnknownTool" {
    const a = std.testing.allocator;
    var ctx = simpleCtx(a);
    try std.testing.expectError(error.UnknownTool, tools.dispatch(&ctx, "__no_such_tool__", "{}"));
}

// ============================================================================
// Bash(无副作用)
// ============================================================================

test "L2 smoke: Bash echo → stdout 含输出, exit_code 0" {
    const a = std.testing.allocator;
    var ctx = simpleCtx(a);
    const out = try dispatchOk(&ctx, "Bash", "{\"command\":\"echo cc_smoke_hello\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "cc_smoke_hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"exit_code\":0") != null);
}

test "L2 smoke: Bash 非零退出 → exit_code 透传" {
    const a = std.testing.allocator;
    var ctx = simpleCtx(a);
    const out = try dispatchOk(&ctx, "Bash", "{\"command\":\"exit 3\"}");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"exit_code\":3") != null);
}

// ============================================================================
// Write / Read(文件副作用,写→读回验证)
// ============================================================================

test "L2 smoke: Write 新文件 → Read 读回内容一致" {
    const a = std.testing.allocator;
    var ctx = simpleCtx(a);
    const path = "/tmp/cc-smoke-write-read.txt";
    defer _ = std.c.unlink(path);

    const wout = try dispatchOk(&ctx, "Write", "{\"file_path\":\"/tmp/cc-smoke-write-read.txt\",\"content\":\"smoke_body_42\"}");
    defer a.free(wout);
    // Write 成功不应是 error JSON
    try std.testing.expect(std.mem.indexOf(u8, wout, "\"error\"") == null);

    const rout = try dispatchOk(&ctx, "Read", "{\"file_path\":\"/tmp/cc-smoke-write-read.txt\"}");
    defer a.free(rout);
    try std.testing.expect(std.mem.indexOf(u8, rout, "smoke_body_42") != null);
}

test "L2 smoke: Read 不存在文件 → FileNotFound" {
    const a = std.testing.allocator;
    var ctx = simpleCtx(a);
    try std.testing.expectError(error.FileNotFound, tools.dispatch(&ctx, "Read", "{\"file_path\":\"/tmp/cc-smoke-nope-9z9z.txt\"}"));
}

test "L2 smoke: ReadArtifact registry schema dispatches bounded recovery" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const receipt = try cc.tool_result_artifact.persist(a, root, "artifact-dispatch-body");
    var ctx = simpleCtx(a);
    ctx.artifact_root = root;
    const args = try std.fmt.allocPrint(a, "{{\"artifact_id\":\"{s}\",\"offset\":9,\"limit\":8}}", .{receipt.id()});
    defer a.free(args);

    const result = try dispatchOk(&ctx, "ReadArtifact", args);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "dispatch") != null);
    try std.testing.expectError(error.MissingArtifactId, tools.dispatch(&ctx, "ReadArtifact", "{}"));
}

// ============================================================================
// Edit(文件副作用;simple ctx 无 read_state → 跳过 must-read 校验)
// ============================================================================

test "L2 smoke: Edit 替换字符串 → Read 读回新内容" {
    const a = std.testing.allocator;
    var ctx = simpleCtx(a);
    const path = "/tmp/cc-smoke-edit.txt";
    defer _ = std.c.unlink(path);

    const wout = try dispatchOk(&ctx, "Write", "{\"file_path\":\"/tmp/cc-smoke-edit.txt\",\"content\":\"before_X done\"}");
    a.free(wout);

    const eout = try dispatchOk(&ctx, "Edit", "{\"file_path\":\"/tmp/cc-smoke-edit.txt\",\"old_string\":\"before_X\",\"new_string\":\"after_Y\"}");
    defer a.free(eout);
    try std.testing.expect(std.mem.indexOf(u8, eout, "\"success\":true") != null);

    const rout = try dispatchOk(&ctx, "Read", "{\"file_path\":\"/tmp/cc-smoke-edit.txt\"}");
    defer a.free(rout);
    try std.testing.expect(std.mem.indexOf(u8, rout, "after_Y") != null);
    try std.testing.expect(std.mem.indexOf(u8, rout, "before_X") == null);
}

test "L2 smoke: Edit old_string 未找到 → 错误(不静默成功)" {
    const a = std.testing.allocator;
    var ctx = simpleCtx(a);
    const path = "/tmp/cc-smoke-edit-nf.txt";
    defer _ = std.c.unlink(path);
    const wout = try dispatchOk(&ctx, "Write", "{\"file_path\":\"/tmp/cc-smoke-edit-nf.txt\",\"content\":\"hello\"}");
    a.free(wout);

    // old_string 不存在 → execute 返 error(具名),dispatch 透传
    const r = tools.dispatch(&ctx, "Edit", "{\"file_path\":\"/tmp/cc-smoke-edit-nf.txt\",\"old_string\":\"NOPE\",\"new_string\":\"x\"}");
    try std.testing.expectError(error.StringNotFound, r);
}

// ============================================================================
// Grep / Glob(依赖 ripgrep;CI 无 rg 则 skip,不误判)
// ============================================================================

test "L2 smoke: Grep 在临时文件里匹配已知串(content 模式带行号)" {
    const a = std.testing.allocator;
    var ctx = simpleCtx(a);
    const path = "/tmp/cc-smoke-grep.txt";
    defer _ = std.c.unlink(path);
    const wout = try dispatchOk(&ctx, "Write", "{\"file_path\":\"/tmp/cc-smoke-grep.txt\",\"content\":\"alpha\\nNEEDLE_777\\nbeta\"}");
    a.free(wout);

    const out = dispatchOk(&ctx, "Grep", "{\"pattern\":\"NEEDLE_777\",\"path\":\"/tmp/cc-smoke-grep.txt\",\"output_mode\":\"content\"}") catch |err| {
        if (err == error.RipgrepNotFound) return error.SkipZigTest;
        return err;
    };
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "NEEDLE_777") != null);
}

test "L2 smoke: Glob 匹配临时目录下文件" {
    const a = std.testing.allocator;
    var ctx = simpleCtx(a);
    const path = "/tmp/cc-smoke-glob-uniq.md";
    defer _ = std.c.unlink(path);
    const wout = try dispatchOk(&ctx, "Write", "{\"file_path\":\"/tmp/cc-smoke-glob-uniq.md\",\"content\":\"x\"}");
    a.free(wout);

    const out = dispatchOk(&ctx, "Glob", "{\"pattern\":\"cc-smoke-glob-uniq.md\",\"path\":\"/tmp\"}") catch |err| {
        if (err == error.RipgrepNotFound) return error.SkipZigTest;
        return err;
    };
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "cc-smoke-glob-uniq.md") != null);
}

// ============================================================================
// Task 工具族(本地 scratchpad,需 ctx.tasks)
// ============================================================================

test "L2 smoke: TaskCreate → TaskList → TaskUpdate(完整 CRUD 经 dispatch)" {
    const a = std.testing.allocator;
    var store = cc.core_task_store.TaskStore.init(a);
    defer store.deinit();
    var ctx = simpleCtx(a);
    ctx.tasks = &store;

    const c = try dispatchOk(&ctx, "TaskCreate", "{\"subject\":\"Smoke task\",\"description\":\"do smoke\"}");
    defer a.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, "\"id\":\"1\"") != null);

    const l = try dispatchOk(&ctx, "TaskList", "{}");
    defer a.free(l);
    try std.testing.expect(std.mem.indexOf(u8, l, "Smoke task") != null);

    const u = try dispatchOk(&ctx, "TaskUpdate", "{\"taskId\":\"1\",\"status\":\"completed\"}");
    defer a.free(u);
    try std.testing.expect(std.mem.indexOf(u8, u, "\"error\"") == null);
}

test "L2 e2e: Edit no-op 经 executeSlots → 富 detail 到达 slot(code=no_op_edit)" {
    const a = std.testing.allocator;
    const tool_exec = cc.tool_exec;
    const path = "/tmp/cc-smoke-edit-noop-e2e.txt";
    defer _ = std.c.unlink(path);
    var ctx = simpleCtx(a);
    a.free(try dispatchOk(&ctx, "Write", "{\"file_path\":\"/tmp/cc-smoke-edit-noop-e2e.txt\",\"content\":\"abc\"}"));

    // 经 executeSlots(真正接 error_detail 通道的路径,非 dispatch 直调)。
    var slots = [_]tool_exec.Slot{
        .{ .decision = .run, .name = "Edit", .id = "e0", .input = "{\"file_path\":\"/tmp/cc-smoke-edit-noop-e2e.txt\",\"old_string\":\"abc\",\"new_string\":\"abc\"}" },
    };
    try tool_exec.executeSlots(&slots, &ctx, a, cc.util_log.RequestId{ .bytes = [_]u8{0} ** 12 });
    defer slots[0].deinit(a);

    try std.testing.expect(slots[0].is_error);
    const content = slots[0].content.?;
    // 富 detail 经 errorToJson 进 slot:code=no_op_edit + 可操作 detail,而非通用 "Edit failed with NoOpEdit"。
    try std.testing.expect(std.mem.indexOf(u8, content, "no_op_edit") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "no-op") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "failed with") == null);
}

test "L2 e2e: Edit not-found 经 executeSlots → 富诊断到达 slot" {
    const a = std.testing.allocator;
    const tool_exec = cc.tool_exec;
    const path = "/tmp/cc-smoke-edit-nf-e2e.txt";
    defer _ = std.c.unlink(path);
    var ctx = simpleCtx(a);
    a.free(try dispatchOk(&ctx, "Write", "{\"file_path\":\"/tmp/cc-smoke-edit-nf-e2e.txt\",\"content\":\"hello world\"}"));

    var slots = [_]tool_exec.Slot{
        .{ .decision = .run, .name = "Edit", .id = "e0", .input = "{\"file_path\":\"/tmp/cc-smoke-edit-nf-e2e.txt\",\"old_string\":\"nonexistent\",\"new_string\":\"x\"}" },
    };
    try tool_exec.executeSlots(&slots, &ctx, a, cc.util_log.RequestId{ .bytes = [_]u8{0} ** 12 });
    defer slots[0].deinit(a);

    try std.testing.expect(slots[0].is_error);
    const content = slots[0].content.?;
    try std.testing.expect(std.mem.indexOf(u8, content, "string_not_found") != null);
    // 诊断给了"Re-Read"可操作建议,而非干巴巴 "failed with"。
    try std.testing.expect(std.mem.indexOf(u8, content, "Re-Read") != null);
}
