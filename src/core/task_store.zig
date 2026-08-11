//! TaskStore：模型的长任务清单（一次 session 的 TODO scratchpad）。
//!
//! 为什么需要：模型做多步任务时需要跨轮维护进度（pending / in_progress / completed），
//! 否则每轮都要在 messages 里重复列任务耗 token。
//!
//! 设计取舍：
//! - 内存 ArrayList，session 结束丢弃（TS 有文件持久化是为多 agent 共享，
//!   我们单进程无此需求）。
//! - ID 用单调递增 u64 字符串化（"1", "2", ...），稳定且无 UUID 依赖。
//! - status 枚举：pending / in_progress / completed / deleted。
//! - blocks/blockedBy：task ID 列表，模型自行维护依赖图。
//! - **文件镜像**（KG 降级时 swarm 共享后备）：mirror_path 非 null 时,每次写操作
//!   best-effort 持久化到 JSON 文件;loadFromMirror 把别的进程/线程写的任务合并进来。
//!   用途:KG 降级 → TaskCreate 退内存 store(进程隔离) → swarm teammate 看不到 lead 任务;
//!   镜像文件让 teammate 通过读 mirror 看到 lead 任务。KG 可用时不启用(tinykg store 已共享)。

const std = @import("std");
const util_time = @import("../util/time.zig");
const sync = @import("platform").sync;
const log = @import("../util/log.zig");

pub const TaskStatus = enum {
    pending,
    in_progress,
    completed,
    deleted,

    pub fn fromString(s: []const u8) ?TaskStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "deleted")) return .deleted;
        return null;
    }

    pub fn toString(self: TaskStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
            .deleted => "deleted",
        };
    }
};

pub const Task = struct {
    id: []const u8, // owned
    subject: []const u8, // owned
    description: []const u8, // owned
    active_form: ?[]const u8 = null, // owned?
    owner: ?[]const u8 = null, // owned?
    status: TaskStatus = .pending,
    /// 转为 completed 的时戳(ms);供 TUI 清单 TTL(完成 ~30s 后从清单淡出)。
    /// 0 = 未完成或未记录。
    completed_ms: i64 = 0,
    blocks: std.ArrayList([]const u8) = .empty, // elements owned
    blocked_by: std.ArrayList([]const u8) = .empty, // elements owned

    pub fn deinit(self: *Task, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.subject);
        allocator.free(self.description);
        if (self.active_form) |s| allocator.free(s);
        if (self.owner) |s| allocator.free(s);
        for (self.blocks.items) |s| allocator.free(s);
        self.blocks.deinit(allocator);
        for (self.blocked_by.items) |s| allocator.free(s);
        self.blocked_by.deinit(allocator);
    }
};

pub const TaskStore = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(*Task), // pointers so addresses stable across growth
    next_id: u64 = 1,
    /// **task#19**:driver 单线程改 tasks;attach 快照(HTTP 线程)要跨线程读 → mutex 串行,免
    /// grow-during-iterate 悬挂 / torn 读 task 内容。所有**改 tasks / 改 task 内容**的公开方法锁内跑;
    /// get() 无锁(driver 内部/单线程用 + 被上锁方法内部调,不能重入)。snapshotTasks 锁内 dup 值语义。
    mutex: sync.Mutex = .{},
    /// **文件镜像路径**(owned;null = 关闭镜像,向后兼容)。KG 降级时 swarm teammate 共享
    /// 后备:lead 写 → 持久化 mirror;teammate loadFromMirror → 内存合并。mirror_path 不可变
    /// (setMirror 后);写操作 best-effort 持久化(失败不 brick,只 log.warn)。
    mirror_path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) TaskStore {
        return .{ .allocator = allocator, .tasks = .empty };
    }

    /// 配置 mirror 路径(owned dupe)。传入空串等价关闭。仅调用一次(初始化期);
    /// 重复调用 free 旧 path 再 dupe 新的。线程模型:driver 单线程设置期,无并发。
    pub fn setMirror(self: *TaskStore, mirror_path: []const u8) void {
        if (self.mirror_path) |p| self.allocator.free(p);
        if (mirror_path.len == 0) {
            self.mirror_path = null;
            return;
        }
        self.mirror_path = self.allocator.dupe(u8, mirror_path) catch null;
    }

    /// **task#19 跨线程读**:锁内把当前任务快照成 owned 值(id/subject/status),供 attach 快照。
    /// caller free 每个 .id/.subject + 外层 slice。
    pub const TaskView = struct { id: []u8, subject: []u8, status: TaskStatus };
    pub fn snapshotTasks(self: *TaskStore, allocator: std.mem.Allocator) ![]TaskView {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        const out = try allocator.alloc(TaskView, self.tasks.items.len);
        errdefer allocator.free(out);
        var n: usize = 0;
        errdefer for (out[0..n]) |v| {
            allocator.free(v.id);
            allocator.free(v.subject);
        };
        for (self.tasks.items) |t| {
            out[n] = .{
                .id = try allocator.dupe(u8, t.id),
                .subject = try allocator.dupe(u8, t.subject),
                .status = t.status,
            };
            n += 1;
        }
        return out;
    }

    pub fn deinit(self: *TaskStore) void {
        for (self.tasks.items) |t| {
            t.deinit(self.allocator);
            self.allocator.destroy(t);
        }
        self.tasks.deinit(self.allocator);
        if (self.mirror_path) |p| self.allocator.free(p);
    }

    /// **镜像持久化**(best-effort):把当前所有任务写进 mirror_path JSON 文件。
    /// 调用方约定:已持有 mutex(从写方法末尾调)。失败只 log.warn,不 brick(任务是
    /// 增强非依赖,对齐 KG 降级原则)。文件格式:JSON 数组,每元素 {id,subject,
    /// description,status,active_form?,owner?,blocks?,blocked_by?}。
    /// 用 std.c fopen/fwrite/fclose + rename(对齐 inject.zig 的 fs API 模式,Zig 0.17 std.fs.cwd 移除)。
    /// 用 std.Io.Writer.Allocating 缓冲写(对齐 task_batch.zig:382 模式)。
    fn mirrorToFileLocked(self: *TaskStore) void {
        const path = self.mirror_path orelse return;
        // 写到临时文件 + rename 原子替换(防读到半截写)
        var tmp_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        _ = std.fmt.bufPrint(&tmp_buf, "{s}.tmp\x00", .{path}) catch return;

        const f = std.c.fopen(@ptrCast(&tmp_buf), "w") orelse return;

        var w: std.Io.Writer.Allocating = .init(self.allocator);
        defer w.deinit();
        w.writer.writeByte('[') catch {
            _ = std.c.fclose(f);
            return;
        };
        var first = true;
        for (self.tasks.items) |t| {
            // deleted 已从 items 移除,不写
            if (!first) w.writer.writeByte(',') catch break;
            first = false;
            self.appendTaskJson(&w, t) catch break;
        }
        w.writer.writeByte(']') catch {};
        const written = w.toOwnedSlice() catch {
            _ = std.c.fclose(f);
            return;
        };
        defer self.allocator.free(written);
        _ = std.c.fwrite(written.ptr, 1, written.len, f);
        // 显式 fclose(flush 缓冲)再 rename——rename 在 fclose 之前会让 rename 看到未 flush 的文件
        _ = std.c.fclose(f);
        // path 也需要 null-terminated
        var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (path.len >= path_buf.len) return;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        _ = std.c.rename(@ptrCast(&tmp_buf), @ptrCast(&path_buf));
    }

    /// 单个 task 序列化成 JSON 对象,append 到 writer。
    fn appendTaskJson(self: *TaskStore, w: *std.Io.Writer.Allocating, t: *const Task) !void {
        _ = self; // 仅用于命名空间;无字段访问(状态全在 t)
        try w.writer.writeAll("{\"id\":");
        try std.json.Stringify.encodeJsonString(t.id, .{}, &w.writer);
        try w.writer.writeAll(",\"subject\":");
        try std.json.Stringify.encodeJsonString(t.subject, .{}, &w.writer);
        try w.writer.writeAll(",\"description\":");
        try std.json.Stringify.encodeJsonString(t.description, .{}, &w.writer);
        try w.writer.writeAll(",\"status\":\"");
        try w.writer.writeAll(t.status.toString());
        try w.writer.writeAll("\"");
        if (t.active_form) |af| {
            try w.writer.writeAll(",\"active_form\":");
            try std.json.Stringify.encodeJsonString(af, .{}, &w.writer);
        }
        if (t.owner) |o| {
            try w.writer.writeAll(",\"owner\":");
            try std.json.Stringify.encodeJsonString(o, .{}, &w.writer);
        }
        if (t.blocks.items.len > 0) {
            try w.writer.writeAll(",\"blocks\":[");
            var first_b = true;
            for (t.blocks.items) |b| {
                if (!first_b) try w.writer.writeAll(",");
                first_b = false;
                try std.json.Stringify.encodeJsonString(b, .{}, &w.writer);
            }
            try w.writer.writeAll("]");
        }
        if (t.blocked_by.items.len > 0) {
            try w.writer.writeAll(",\"blocked_by\":[");
            var first_bb = true;
            for (t.blocked_by.items) |b| {
                if (!first_bb) try w.writer.writeAll(",");
                first_bb = false;
                try std.json.Stringify.encodeJsonString(b, .{}, &w.writer);
            }
            try w.writer.writeAll("]");
        }
        try w.writer.writeAll("}");
    }

    /// **从镜像加载**(teammate 启动时调):读 mirror_path JSON,合并进内存 store。
    /// 合并语义:按 id 去重(已存在则跳过,保留内存版本——lead 的内存是真相,mirror 是补充)。
    /// best-effort:文件不存在/解析失败 → 静默返回(KG 降级镜像未写过)。线程模型:driver
    /// 单线程初始化期调,无并发。
    pub fn loadFromMirror(self: *TaskStore) void {
        const path = self.mirror_path orelse return;
        // null-terminate path for std.c.fopen
        var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (path.len >= path_buf.len) return;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const f = std.c.fopen(@ptrCast(&path_buf), "r") orelse return; // 不存在 = 无镜像
        defer _ = std.c.fclose(f);

        // 读文件:用固定大小缓冲(任务文件应很小,4MB 上限足够)
        var read_buf: [4 * 1024 * 1024]u8 = undefined;
        const n = std.c.fread(&read_buf, 1, read_buf.len - 1, f);
        if (n == 0) return;
        const bytes = read_buf[0..n];

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch |e| {
            log.warn("taskstore", "mirror parse failed {s}: {s}", .{ path, @errorName(e) });
            return;
        };
        defer parsed.deinit();

        const arr = switch (parsed.value) {
            .array => |a| a.items,
            else => return,
        };
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        for (arr) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const id = jsonFieldStr(self.allocator, obj, "id") orelse continue;
            // id 去重:已存在跳过(lead 内存真相优先)
            if (self.get(id) != null) {
                self.allocator.free(id);
                continue;
            }
            const subject = jsonFieldStr(self.allocator, obj, "subject") orelse {
                self.allocator.free(id);
                continue;
            };
            const description = jsonFieldStr(self.allocator, obj, "description") orelse {
                self.allocator.free(id);
                self.allocator.free(subject);
                continue;
            };
            const status_str = jsonFieldStr(self.allocator, obj, "status") orelse {
                // 默认 pending;不 free 字面量(无 alloc)
                if (self.appendLoadedTask(id, subject, description, null, null, .pending)) |_| {
                    continue; // append 成功,处理下一个 item
                } else |_| {
                    self.freeLoadedFields(id, subject, description, null, null);
                }
                continue;
            };
            defer self.allocator.free(status_str);
            const status = TaskStatus.fromString(status_str) orelse .pending;
            const active_form = jsonFieldStr(self.allocator, obj, "active_form");
            const owner = jsonFieldStr(self.allocator, obj, "owner");
            if (self.appendLoadedTask(id, subject, description, active_form, owner, status)) |_| {
                continue;
            } else |_| {
                self.freeLoadedFields(id, subject, description, active_form, owner);
                continue;
            }
        }
    }

    /// helper:appendLoadedTask 把已 dupe 的 owned fields 组装成 Task 加入 items。
    /// 成功后所有权转移到 store;失败由调用方 free(见 freeLoadedFields)。
    fn appendLoadedTask(
        self: *TaskStore,
        id: []u8,
        subject: []u8,
        description: []u8,
        active_form: ?[]u8,
        owner: ?[]u8,
        status: TaskStatus,
    ) !void {
        const t = try self.allocator.create(Task);
        t.* = .{
            .id = id,
            .subject = subject,
            .description = description,
            .active_form = active_form,
            .owner = owner,
            .status = status,
        };
        // blocks / blocked_by 可选,暂不加载(swarm 自领用不到依赖图)
        self.tasks.append(self.allocator, t) catch |e| {
            self.allocator.destroy(t);
            return e;
        };
    }

    /// helper:appendLoadedTask 失败时释放 owned fields(防止 leak)。
    /// fields 由 self.allocator(jsonFieldStr 里)dupe,故用 self.allocator free。
    fn freeLoadedFields(
        self: *TaskStore,
        id: []u8,
        subject: []u8,
        description: []u8,
        active_form: ?[]u8,
        owner: ?[]u8,
    ) void {
        self.allocator.free(id);
        self.allocator.free(subject);
        self.allocator.free(description);
        if (active_form) |s| self.allocator.free(s);
        if (owner) |s| self.allocator.free(s);
    }

    /// helper:json object 取 string 字段(owned dupe)。失败返 null。
    fn jsonFieldStr(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8) ?[]u8 {
        const v = obj.get(name) orelse return null;
        const s = switch (v) {
            .string => |str| str,
            else => return null,
        };
        return allocator.dupe(u8, s) catch null;
    }

    /// 创建任务，返回刚创建的 task 指针（借，调用方不 free）。
    pub fn create(
        self: *TaskStore,
        subject: []const u8,
        description: []const u8,
        active_form: ?[]const u8,
    ) !*Task {
        _ = self.mutex.lock(); // task#19:与 attach 快照读串行
        defer _ = self.mutex.unlock();
        const t = try self.allocator.create(Task);
        errdefer self.allocator.destroy(t);

        const id = try std.fmt.allocPrint(self.allocator, "{d}", .{self.next_id});
        errdefer self.allocator.free(id);

        const subj = try self.allocator.dupe(u8, subject);
        errdefer self.allocator.free(subj);

        const desc = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc);

        const af: ?[]const u8 = if (active_form) |v| try self.allocator.dupe(u8, v) else null;
        errdefer if (af) |p| self.allocator.free(p);

        t.* = .{ .id = id, .subject = subj, .description = desc, .active_form = af };

        try self.tasks.append(self.allocator, t);
        self.next_id += 1;
        self.mirrorToFileLocked();
        return t;
    }

    /// 用**显式 id** 插入(KG write-through 镜像:图为持久真相,store 为 TaskTab/TaskList 的
    /// 同步显示缓存;id 用 "kg-<node>" 与图对齐)。已存在同 id → 幂等跳过(供启动重建)。
    /// status 可指定(计划步骤 blocked 等)。绝不动 next_id(kg- 不占数字命名空间)。
    pub fn createWithId(
        self: *TaskStore,
        id: []const u8,
        subject: []const u8,
        description: []const u8,
        status: TaskStatus,
    ) !void {
        _ = self.mutex.lock(); // task#19
        defer _ = self.mutex.unlock();
        if (self.get(id) != null) return; // 幂等(get 无锁,不重入)
        const t = try self.allocator.create(Task);
        errdefer self.allocator.destroy(t);
        const id_owned = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_owned);
        const subj = try self.allocator.dupe(u8, subject);
        errdefer self.allocator.free(subj);
        const desc = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc);
        t.* = .{ .id = id_owned, .subject = subj, .description = desc, .active_form = null, .status = status };
        try self.tasks.append(self.allocator, t);
        self.mirrorToFileLocked();
    }

    /// 按 id 查找。返回指针（借），找不到 null。
    pub fn get(self: *TaskStore, id: []const u8) ?*Task {
        for (self.tasks.items) |t| {
            if (std.mem.eql(u8, t.id, id)) return t;
        }
        return null;
    }

    /// Return the one persistent KG task currently owned by this agent loop.
    /// Zero, multiple, or malformed `kg-*` mirrors are deliberately
    /// indistinguishable: execution-grounded knowledge must fail safe instead
    /// of guessing which task should receive a fact.
    pub fn uniqueActiveKgTaskId(self: *TaskStore) ?u64 {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        var active: ?u64 = null;
        for (self.tasks.items) |task| {
            if (task.status != .in_progress or !std.mem.startsWith(u8, task.id, "kg-")) continue;
            const node_id = std.fmt.parseInt(u64, task.id["kg-".len..], 10) catch return null;
            if (node_id == 0 or active != null) return null;
            active = node_id;
        }
        return active;
    }

    /// 更新 status。若 deleted 则实际从列表删除并释放。
    pub fn updateStatus(self: *TaskStore, id: []const u8, status: TaskStatus) !void {
        _ = self.mutex.lock(); // task#19
        defer _ = self.mutex.unlock();
        for (self.tasks.items, 0..) |t, i| {
            if (!std.mem.eql(u8, t.id, id)) continue;
            if (status == .deleted) {
                t.deinit(self.allocator);
                self.allocator.destroy(t);
                _ = self.tasks.orderedRemove(i);
                self.mirrorToFileLocked();
                return;
            }
            t.status = status;
            // 记/清完成时戳(供 TUI 清单 TTL)。
            if (status == .completed) {
                if (t.completed_ms == 0) t.completed_ms = util_time.nowMs();
            } else {
                t.completed_ms = 0;
            }
            self.mirrorToFileLocked();
            return;
        }
        return error.TaskNotFound;
    }

    /// 更新各字段（任意可选）。
    ///
    /// **Move 语义**：传入 owned bytes 的所有权即转交给本函数——无论成功/失败，本函数负责 free。
    /// 调用方不得再 free；若调用方需要临时保留，请自己 dupe。
    ///
    /// **事务性**：本函数保证 "全改或全不改"。以前的实现对每个字段独立 dupe+swap，
    /// 若多字段中某个 allocator 失败，前面的字段已被改而后面没改——Task 处于部分更新
    /// 状态，模型以为 update 失败重试会导致前置字段被改两次。
    /// 现在 move 语义下没有 dupe，所以不存在中间失败；但若 error.TaskNotFound 发生
    /// （例如并发删除），errdefer 把所有传入 owned 清掉。
    pub fn update(
        self: *TaskStore,
        id: []const u8,
        opts: struct {
            subject: ?[]u8 = null,
            description: ?[]u8 = null,
            active_form: ?[]u8 = null,
            owner: ?[]u8 = null,
        },
    ) !void {
        _ = self.mutex.lock(); // task#19
        defer _ = self.mutex.unlock();
        // 先用可变局部变量接管所有权。任一错误路径由 errdefer 释放。
        var subject = opts.subject;
        errdefer if (subject) |s| self.allocator.free(s);
        var description = opts.description;
        errdefer if (description) |s| self.allocator.free(s);
        var active_form = opts.active_form;
        errdefer if (active_form) |s| self.allocator.free(s);
        var owner = opts.owner;
        errdefer if (owner) |s| self.allocator.free(s);

        const t = self.get(id) orelse return error.TaskNotFound;

        // 全部批量替换：无 allocator 调用，不会中途失败。
        // 每条：把 local 置 null 表示所有权已转移，errdefer 不再 free。
        if (subject) |s| {
            self.allocator.free(t.subject);
            t.subject = s;
            subject = null;
        }
        if (description) |s| {
            self.allocator.free(t.description);
            t.description = s;
            description = null;
        }
        if (active_form) |s| {
            if (t.active_form) |old| self.allocator.free(old);
            t.active_form = s;
            active_form = null;
        }
        if (owner) |s| {
            if (t.owner) |old| self.allocator.free(old);
            t.owner = s;
            owner = null;
        }
        self.mirrorToFileLocked();
    }

    /// 添加 blocks/blockedBy 依赖（深拷贝 ID）。
    pub fn addBlocks(self: *TaskStore, id: []const u8, blocked_ids: []const []const u8) !void {
        _ = self.mutex.lock(); // task#19(一致性:虽 snapshot 暂不读 blocks)
        defer _ = self.mutex.unlock();
        const t = self.get(id) orelse return error.TaskNotFound;
        for (blocked_ids) |bid| {
            const s = try self.allocator.dupe(u8, bid);
            errdefer self.allocator.free(s);
            try t.blocks.append(self.allocator, s);
        }
        self.mirrorToFileLocked();
    }

    pub fn addBlockedBy(self: *TaskStore, id: []const u8, blocker_ids: []const []const u8) !void {
        _ = self.mutex.lock(); // task#19
        defer _ = self.mutex.unlock();
        const t = self.get(id) orelse return error.TaskNotFound;
        for (blocker_ids) |bid| {
            const s = try self.allocator.dupe(u8, bid);
            errdefer self.allocator.free(s);
            try t.blocked_by.append(self.allocator, s);
        }
        self.mirrorToFileLocked();
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "TaskStore: create/get/update/delete cycle" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();

    const t1 = try store.create("Subject A", "Desc A", "Doing A");
    try testing.expectEqualStrings("1", t1.id);
    try testing.expect(t1.status == .pending);

    const t2 = try store.create("Subject B", "Desc B", null);
    try testing.expectEqualStrings("2", t2.id);
    try testing.expect(t2.active_form == null);

    try store.updateStatus("1", .in_progress);
    try testing.expect(store.get("1").?.status == .in_progress);

    // update 接 owned bytes（move 语义）；用 dupe 生成测试数据并 move 进去
    try store.update("2", .{
        .subject = try testing.allocator.dupe(u8, "Subject B2"),
        .owner = try testing.allocator.dupe(u8, "agent-x"),
    });
    try testing.expectEqualStrings("Subject B2", store.get("2").?.subject);
    try testing.expectEqualStrings("agent-x", store.get("2").?.owner.?);

    try store.addBlocks("1", &.{ "2", "3" });
    try testing.expect(store.get("1").?.blocks.items.len == 2);
    try testing.expectEqualStrings("2", store.get("1").?.blocks.items[0]);

    try store.updateStatus("1", .deleted);
    try testing.expect(store.get("1") == null);
    try testing.expect(store.tasks.items.len == 1);

    // 2 still there, get still works
    try testing.expect(store.get("2") != null);
}

test "TaskStore: update non-existent returns TaskNotFound" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    try testing.expectError(error.TaskNotFound, store.updateStatus("99", .completed));
    try testing.expectError(error.TaskNotFound, store.update("99", .{
        .subject = try testing.allocator.dupe(u8, "x"),
    }));
    try testing.expectError(error.TaskNotFound, store.addBlocks("99", &.{}));
}

test "TaskStore: update is transactional — TaskNotFound doesn't leak inputs" {
    // 若 update 未 free 自己收到的 owned bytes，GPA 会在 defer store.deinit 后
    // 报 "leak detected"；std.testing.allocator 本身也会报。
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();

    const s = try testing.allocator.dupe(u8, "subject-x");
    const d = try testing.allocator.dupe(u8, "desc-x");
    const af = try testing.allocator.dupe(u8, "doing-x");
    const own = try testing.allocator.dupe(u8, "owner-x");
    try testing.expectError(error.TaskNotFound, store.update("missing", .{
        .subject = s,
        .description = d,
        .active_form = af,
        .owner = own,
    }));
    // 所有 owned bytes 应由 update 的 errdefer 释放——测试如果泄漏，allocator 会报
}

test "TaskStatus fromString/toString roundtrip" {
    try testing.expect(TaskStatus.fromString("pending").? == .pending);
    try testing.expect(TaskStatus.fromString("in_progress").? == .in_progress);
    try testing.expect(TaskStatus.fromString("completed").? == .completed);
    try testing.expect(TaskStatus.fromString("deleted").? == .deleted);
    try testing.expect(TaskStatus.fromString("nope") == null);
    try testing.expectEqualStrings("in_progress", TaskStatus.in_progress.toString());
}

test "TaskStore: completed 记 completed_ms,转出 completed 清零" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    const t = try store.create("S", "D", null);
    try testing.expectEqual(@as(i64, 0), t.completed_ms); // 初始未完成

    try store.updateStatus(t.id, .completed);
    try testing.expect(t.completed_ms != 0); // 完成记时戳

    // 转回 in_progress(返工)→ 时戳清零,TTL 重置。
    try store.updateStatus(t.id, .in_progress);
    try testing.expectEqual(@as(i64, 0), t.completed_ms);
}

test "TaskStore: unique active KG task fails safe on ambiguity and malformed ids" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    try testing.expect(store.uniqueActiveKgTaskId() == null);

    try store.createWithId("kg-41", "one", "", .in_progress);
    try testing.expectEqual(@as(?u64, 41), store.uniqueActiveKgTaskId());

    try store.createWithId("session-only", "scratch", "", .in_progress);
    try testing.expectEqual(@as(?u64, 41), store.uniqueActiveKgTaskId());

    try store.createWithId("kg-42", "two", "", .in_progress);
    try testing.expect(store.uniqueActiveKgTaskId() == null);
    try store.updateStatus("kg-42", .pending);
    try testing.expectEqual(@as(?u64, 41), store.uniqueActiveKgTaskId());

    try store.createWithId("kg-not-a-number", "bad", "", .in_progress);
    try testing.expect(store.uniqueActiveKgTaskId() == null);
}

test "task#19: snapshotTasks 正确性 + 并发 create/snapshot 不崩(mutex 串行)" {
    const a = testing.allocator;
    var store = TaskStore.init(a);
    defer store.deinit();
    _ = try store.create("subj-A", "d", null);
    const t2 = try store.create("subj-B", "d", null);
    try store.updateStatus(t2.id, .in_progress);

    // 正确性:snapshotTasks 返回 owned 值(id/subject/status),与 store 一致。
    {
        const snap = try store.snapshotTasks(a);
        defer {
            for (snap) |v| {
                a.free(v.id);
                a.free(v.subject);
            }
            a.free(snap);
        }
        try testing.expectEqual(@as(usize, 2), snap.len);
        try testing.expectEqualStrings("subj-A", snap[0].subject);
        try testing.expectEqualStrings("subj-B", snap[1].subject);
        try testing.expectEqual(TaskStatus.in_progress, snap[1].status);
    }

    // 并发:writer 线程持续 create(grow tasks.items,realloc),reader 持续 snapshotTasks(迭代)。
    // 无 mutex → grow-during-iterate 悬挂/堆损坏。mutex 串行 → 干净。best-effort 竞争窗口。
    const Ctx = struct {
        s: *TaskStore,
        stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn writer(c: *@This()) void {
            while (!c.stop.load(.acquire)) {
                // create(append/grow)后立即 delete(orderedRemove)——保持 store 有界,避免 O(n²)
                // 快照 + 内存爆炸,同时仍对 tasks.items 做并发 grow/remove 压 snapshot 的迭代。
                const t = c.s.create("x", "y", null) catch continue;
                const id = std.fmt.allocPrint(c.s.allocator, "{s}", .{t.id}) catch continue;
                defer c.s.allocator.free(id);
                c.s.updateStatus(id, .deleted) catch {};
            }
        }
    };
    var wctx = Ctx{ .s = &store };
    const th = try std.Thread.spawn(.{}, Ctx.writer, .{&wctx});
    var n: usize = 0;
    while (n < 2000) : (n += 1) {
        const snap = store.snapshotTasks(a) catch continue;
        for (snap) |v| {
            a.free(v.id);
            a.free(v.subject);
        }
        a.free(snap);
    }
    wctx.stop.store(true, .release);
    th.join();
}
