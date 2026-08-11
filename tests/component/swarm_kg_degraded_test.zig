//! L2 测试:Bug ② — KG 降级时 swarm teammate 通过 TaskStore 文件镜像看到 lead 任务。
//!
//! 复现路径(修复前):
//!   1. KG 降级(kg_inbox/kg_task_anchor 指针文件不存在)
//!   2. lead TaskCreate → createKgTask 返 null → 退内存 store(id="N" 而非 "kg-N")
//!   3. teammate TaskList → hasLiveKgFrontier false → 只看自己的空内存 store → frontier 空
//!
//! 修复后:
//!   1. KG 降级 → lead TaskStore 启用 mirror_path → create 时同步写 tasks.json
//!   2. teammate 启动时 setMirror + loadFromMirror → 内存 store 重开共享任务
//!   3. teammate TaskList → hasLiveKgFrontier false → 看自己的内存 store(已合并 lead 任务)→ frontier 非空
//!
//! 本测试直接验证 TaskStore 文件镜像机制(不 spawn 真 teammate,纯单元测试 + 文件 IO)。

const std = @import("std");
const testing = std.testing;
const cc = @import("cc");
const task_store = cc.core_task_store;

test "Bug ②: KG 降级时 lead 写 mirror,teammate 读 mirror 看到任务" {
    // 用临时目录做 mirror(避免污染真实 projects dir)
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPath(testing.io, &pbuf);
    const tmp_path = pbuf[0..tmp_path_len];
    const mirror_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/tasks.json",
        .{tmp_path},
    );
    defer testing.allocator.free(mirror_path);

    // lead 端:启用 mirror,创建 3 个任务
    var lead_store = task_store.TaskStore.init(testing.allocator);
    defer lead_store.deinit();
    try lead_store.setMirror(mirror_path);

    _ = try lead_store.create("调研 #1 入口层", "调研 main.zig/app.zig", null);
    _ = try lead_store.create("调研 #2 agent core", "调研 agent_loop", null);
    _ = try lead_store.create("调研 #3 工具", "调研 tools/", null);

    // 验证 mirror 文件已写(用 std.c fopen,对齐生产代码)
    var mpath_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (mirror_path.len >= mpath_buf.len) return error.PathTooLong;
    @memcpy(mpath_buf[0..mirror_path.len], mirror_path);
    mpath_buf[mirror_path.len] = 0;
    const f = std.c.fopen(@ptrCast(&mpath_buf), "r") orelse return error.MirrorNotWritten;
    defer _ = std.c.fclose(f);
    var read_buf: [1024 * 1024]u8 = undefined;
    const n = std.c.fread(&read_buf, 1, read_buf.len - 1, f);
    const bytes = read_buf[0..n];
    try testing.expect(bytes.len > 0);
    // 验证 3 个任务的 subject 都在文件里
    try testing.expect(std.mem.indexOf(u8, bytes, "调研 #1 入口层") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "调研 #2 agent core") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "调研 #3 工具") != null);

    // teammate 端:独立 TaskStore,启用同一 mirror,loadFromMirror
    var teammate_store = task_store.TaskStore.init(testing.allocator);
    defer teammate_store.deinit();
    try teammate_store.setMirror(mirror_path);
    try teammate_store.loadFromMirror();

    // 验证 teammate 内存 store 现在有 3 个任务(从 mirror 加载)
    try testing.expectEqual(@as(usize, 3), teammate_store.tasks.items.len);
    try testing.expectEqualStrings("1", teammate_store.tasks.items[0].id);
    try testing.expectEqualStrings("2", teammate_store.tasks.items[1].id);
    try testing.expectEqualStrings("3", teammate_store.tasks.items[2].id);
    try testing.expectEqualStrings("调研 #1 入口层", teammate_store.tasks.items[0].subject);
    try testing.expectEqual(@as(task_store.TaskStatus, .pending), teammate_store.tasks.items[0].status);
}

test "Bug ②: lead 后续 TaskUpdate 同步到 mirror,teammate reload 看到状态变化" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPath(testing.io, &pbuf);
    const tmp_path = pbuf[0..tmp_path_len];
    const mirror_path = try std.fmt.allocPrint(testing.allocator, "{s}/tasks.json", .{tmp_path});
    defer testing.allocator.free(mirror_path);

    // lead 建任务 + 完成一个
    var lead_store = task_store.TaskStore.init(testing.allocator);
    defer lead_store.deinit();
    try lead_store.setMirror(mirror_path);

    _ = try lead_store.create("Task A", "do A", null);
    _ = try lead_store.create("Task B", "do B", null);
    try lead_store.updateStatus("1", .completed);

    // teammate 第一次 load
    var teammate_store = task_store.TaskStore.init(testing.allocator);
    defer teammate_store.deinit();
    try teammate_store.setMirror(mirror_path);
    try teammate_store.loadFromMirror();

    try testing.expectEqual(@as(usize, 2), teammate_store.tasks.items.len);
    // Task 1 应该是 completed(从 mirror 加载的状态)
    try testing.expectEqual(@as(task_store.TaskStatus, .completed), teammate_store.tasks.items[0].status);
    try testing.expectEqual(@as(task_store.TaskStatus, .pending), teammate_store.tasks.items[1].status);

    // lead 删除 Task 2
    try lead_store.updateStatus("2", .deleted);

    // mirror 是共享真源而不是 append-only cache；删除必须传播，否则 teammate 会继续
    // 执行已经撤销的任务。
    try teammate_store.loadFromMirror();
    try testing.expectEqual(@as(usize, 1), teammate_store.tasks.items.len);
    try testing.expectEqual(@as(task_store.TaskStatus, .completed), teammate_store.tasks.items[0].status);
    try testing.expectEqualStrings("1", teammate_store.tasks.items[0].id);
}

test "Bug ②: loadFromMirror 文件不存在时静默返回(无 crash,无任务)" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPath(testing.io, &pbuf);
    const tmp_path = pbuf[0..tmp_path_len];
    const mirror_path = try std.fmt.allocPrint(testing.allocator, "{s}/nonexistent.json", .{tmp_path});
    defer testing.allocator.free(mirror_path);

    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    try store.setMirror(mirror_path);
    // 不存在文件 → 静默返回,store 仍空
    try store.loadFromMirror();
    try testing.expectEqual(@as(usize, 0), store.tasks.items.len);
}

test "Bug ②: stale writer 先 reload 再写,不会覆盖其它进程的新任务" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPath(testing.io, &pbuf);
    const tmp_path = pbuf[0..tmp_path_len];
    const mirror_path = try std.fmt.allocPrint(testing.allocator, "{s}/tasks.json", .{tmp_path});
    defer testing.allocator.free(mirror_path);

    // lead 建任务
    var lead_store = task_store.TaskStore.init(testing.allocator);
    defer lead_store.deinit();
    try lead_store.setMirror(mirror_path);
    _ = try lead_store.create("Original", "from lead", null);

    // teammate 先加载旧快照；随后 lead 又创建 B，使 teammate 的内存变 stale。
    var teammate_store = task_store.TaskStore.init(testing.allocator);
    defer teammate_store.deinit();
    try teammate_store.setMirror(mirror_path);
    try teammate_store.loadFromMirror();
    _ = try lead_store.create("Lead later", "must survive", null);

    // teammate create 必须在 file lock 内先 reload，所以新任务拿 id=3，且不会抹掉 B。
    const teammate_task = try teammate_store.create("Teammate own", "from teammate", null);
    try testing.expectEqualStrings("3", teammate_task.id);

    var observer = task_store.TaskStore.init(testing.allocator);
    defer observer.deinit();
    try observer.setMirror(mirror_path);
    try observer.loadFromMirror();
    try testing.expectEqual(@as(usize, 3), observer.tasks.items.len);
    try testing.expectEqualStrings("Original", observer.tasks.items[0].subject);
    try testing.expectEqualStrings("Lead later", observer.tasks.items[1].subject);
    try testing.expectEqualStrings("Teammate own", observer.tasks.items[2].subject);
}

test "Bug ②: KG 可用路径不启用 mirror(向后兼容)" {
    // 不调 setMirror → mirror_path=null → 写操作不触发文件 IO
    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    // 不调 setMirror
    _ = try store.create("Task without mirror", "no file written", null);
    try testing.expectEqual(@as(usize, 1), store.tasks.items.len);
    try testing.expect(store.mirror_path == null);
    try testing.expect(!cc.swarm_teammate.shouldUseDegradedTaskMirror(true, "/tmp/project"));
    try testing.expect(cc.swarm_teammate.shouldUseDegradedTaskMirror(false, "/tmp/project"));
    try testing.expect(!cc.swarm_teammate.shouldUseDegradedTaskMirror(false, ""));
}

test "Bug ② L2: real TaskList reopens lead mirror instead of returning stale teammate state" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPath(testing.io, &pbuf);
    const mirror_path = try std.fmt.allocPrint(testing.allocator, "{s}/tasks.json", .{pbuf[0..tmp_path_len]});
    defer testing.allocator.free(mirror_path);

    var lead_store = task_store.TaskStore.init(testing.allocator);
    defer lead_store.deinit();
    try lead_store.setMirror(mirror_path);
    _ = try lead_store.create("Visible through TaskList", "runtime wiring", null);

    var teammate_store = task_store.TaskStore.init(testing.allocator);
    defer teammate_store.deinit();
    try teammate_store.setMirror(mirror_path);
    var ctx = cc.tool_context.ToolContext{ .allocator = testing.allocator, .tasks = &teammate_store };
    const first = try cc.task_tools.executeList(&ctx, "{}");
    defer testing.allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "Visible through TaskList") != null);

    _ = try lead_store.create("Added after first read", "must refresh", null);
    const second = try cc.task_tools.executeList(&ctx, "{}");
    defer testing.allocator.free(second);
    try testing.expect(std.mem.indexOf(u8, second, "Added after first read") != null);
}

test "Bug ②: corrupt mirror blocks mutation without overwriting evidence" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp_dir.dir.realPath(testing.io, &pbuf);
    const mirror_path = try std.fmt.allocPrint(testing.allocator, "{s}/tasks.json", .{pbuf[0..tmp_path_len]});
    defer testing.allocator.free(mirror_path);

    var path_z: [std.fs.max_path_bytes:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_z, "{s}", .{mirror_path});
    const f = std.c.fopen(path.ptr, "w") orelse return error.TestWriteFailed;
    _ = std.c.fwrite("{truncated".ptr, 1, "{truncated".len, f);
    _ = std.c.fclose(f);

    var store = task_store.TaskStore.init(testing.allocator);
    defer store.deinit();
    try store.setMirror(mirror_path);
    try testing.expectError(error.MirrorCorrupt, store.create("must not publish", "fail closed", null));

    const check = std.c.fopen(path.ptr, "r") orelse return error.TestReadFailed;
    var check_open = true;
    defer {
        if (check_open) _ = std.c.fclose(check);
    }
    var bytes: [32]u8 = undefined;
    const n = std.c.fread(&bytes, 1, bytes.len, check);
    try testing.expectEqualStrings("{truncated", bytes[0..n]);

    // Exercise the post-allocation decode error path too: prior implementations could
    // free required strings once through Task.deinit and once through outer errdefer.
    _ = std.c.fclose(check);
    check_open = false;
    const malformed = "[{\"id\":\"1\",\"subject\":\"s\",\"description\":\"d\",\"blocks\":[1]}]";
    const rewrite = std.c.fopen(path.ptr, "w") orelse return error.TestWriteFailed;
    _ = std.c.fwrite(malformed.ptr, 1, malformed.len, rewrite);
    _ = std.c.fclose(rewrite);
    try testing.expectError(error.MirrorCorrupt, store.loadFromMirror());
}
