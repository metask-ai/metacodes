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
//! - **文件镜像**（KG 降级时 swarm 共享后备）：mirror_path 非 null 时，每次写操作
//!   在跨进程锁内先重开最新 JSON，再原子持久化；loadFromMirror 替换本地投影。
//!   用途:KG 降级 → TaskCreate 退内存 store(进程隔离) → swarm teammate 看不到 lead 任务;
//!   镜像文件让 teammate 通过读 mirror 看到并更新共享任务。KG 可用时不启用。

const std = @import("std");
const util_time = @import("../util/time.zig");
const sync = @import("platform").sync;
const pfs = @import("platform").fs;
const file_lock = @import("../swarm/file_lock.zig");

const max_mirror_bytes = 4 * 1024 * 1024;

/// Requirement-ledger counts for the session-end closure obligation.
/// Mutex-held snapshot; kg-mirror rows count like local rows (they are the
/// model's declared ledger either way).
pub const LedgerCounts = struct { open: usize, total: usize };

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
    /// **文件镜像路径**(owned;null = 关闭镜像,向后兼容)。KG 降级时它是同机 swarm
    /// 的共享任务真源，不是“各进程局部快照最后写者覆盖”。每次 mutation 都按固定顺序
    /// `mutex -> file_lock -> reload -> mutate -> fsync+rename`，因此 stale writer 不会抹掉
    /// 其它 teammate 的任务；文件损坏或锁失败会在 mutation 前 fail closed。
    mirror_path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) TaskStore {
        return .{ .allocator = allocator, .tasks = .empty };
    }

    /// 配置 mirror 路径(owned dupe)。传入空串等价关闭。仅调用一次(初始化期);
    /// 重复调用 free 旧 path 再 dupe 新的。线程模型:driver 单线程设置期,无并发。
    pub fn setMirror(self: *TaskStore, mirror_path: []const u8) !void {
        if (mirror_path.len == 0) {
            if (self.mirror_path) |p| self.allocator.free(p);
            self.mirror_path = null;
            return;
        }
        // Allocate first: on OOM the existing owned path must remain valid, not become
        // a freed dangling pointer that deinit later frees a second time.
        const replacement = try self.allocator.dupe(u8, mirror_path);
        if (self.mirror_path) |p| self.allocator.free(p);
        self.mirror_path = replacement;
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

    /// 调用方已持有 `mutex`；若启用 mirror，同时获取跨进程锁并重放磁盘最新值。
    /// 返回的 guard 必须由调用方在 mutation/persist 完成后 release。
    fn beginMirrorTxnLocked(self: *TaskStore) !?file_lock.Lock {
        const path = self.mirror_path orelse return null;
        var lock = try file_lock.acquire(path, .{});
        errdefer lock.release();
        try self.reloadMirrorLocked();
        return lock;
    }

    /// 把当前内存状态写成完整共享快照。调用方必须同时持有 mutex 与 mirror file lock。
    /// 这是 KG 降级控制面的写入边界：短写、fsync 或 rename 任一失败都显式报错。
    fn mirrorToFileLocked(self: *TaskStore) !void {
        const path = self.mirror_path orelse return;

        var w: std.Io.Writer.Allocating = .init(self.allocator);
        defer w.deinit();
        try w.writer.writeByte('[');
        var first = true;
        for (self.tasks.items) |t| {
            if (!first) try w.writer.writeByte(',');
            first = false;
            try self.appendTaskJson(&w, t);
        }
        try w.writer.writeByte(']');
        const written = try w.toOwnedSlice();
        defer self.allocator.free(written);

        var tmp_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp.{d}", .{ path, util_time.nowNs() }) catch return error.PathTooLong;
        // EXCL + unpredictable per-write suffix prevents a pre-existing hardlink at a
        // fixed `.tmp` pathname from being truncated before the atomic rename.
        const fd = pfs.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, @as(c_uint, 0o600));
        if (fd < 0) return error.MirrorOpenFailed;
        var fd_open = true;
        var published = false;
        defer {
            if (fd_open) pfs.close(fd);
            if (!published) _ = std.c.unlink(tmp.ptr);
        }
        var offset: usize = 0;
        while (offset < written.len) {
            const n = pfs.write(fd, written[offset..]);
            if (n <= 0) return error.MirrorWriteFailed;
            offset += @intCast(n);
        }
        try pfs.fsyncChecked(fd);
        pfs.close(fd);
        fd_open = false;

        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (path.len >= path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        if (pfs.renameReplace(tmp.ptr, @ptrCast(&path_buf)) != 0) return error.MirrorRenameFailed;
        published = true;
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
        if (t.completed_ms != 0) {
            try w.writer.print(",\"completed_ms\":{d}", .{t.completed_ms});
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

    /// 重新打开共享 mirror，并用磁盘完整快照替换本地投影。状态更新和删除都必须传播，
    /// 因此不能使用“已有 ID 跳过”的 append-merge。不存在表示尚无共享 backlog。
    fn reloadMirrorLocked(self: *TaskStore) !void {
        const bytes = (try self.readMirrorLocked()) orelse return;
        defer self.allocator.free(bytes);
        if (bytes.len == 0) return error.MirrorCorrupt;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{}) catch return error.MirrorCorrupt;
        defer parsed.deinit();

        const arr = switch (parsed.value) {
            .array => |a| a.items,
            else => return error.MirrorCorrupt,
        };
        var fresh = TaskStore.init(self.allocator);
        defer fresh.deinit();
        for (arr) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => return error.MirrorCorrupt,
            };
            const t = try fresh.decodeMirrorTask(obj);
            if (fresh.get(t.id) != null) {
                t.deinit(self.allocator);
                self.allocator.destroy(t);
                return error.MirrorCorrupt;
            }
            fresh.tasks.append(self.allocator, t) catch |err| {
                t.deinit(self.allocator);
                self.allocator.destroy(t);
                return err;
            };
            if (std.fmt.parseInt(u64, t.id, 10)) |numeric_id| {
                fresh.next_id = @max(fresh.next_id, std.math.add(u64, numeric_id, 1) catch return error.MirrorCorrupt);
            } else |_| {}
        }
        const old_tasks = self.tasks;
        self.tasks = fresh.tasks;
        fresh.tasks = old_tasks;
        self.next_id = fresh.next_id;
    }

    fn readMirrorLocked(self: *TaskStore) !?[]u8 {
        const path = self.mirror_path orelse return null;
        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (path.len >= path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const fd = pfs.open(@ptrCast(&path_buf), .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, @as(c_uint, 0));
        if (fd < 0) {
            if (!pfs.exists(@ptrCast(&path_buf))) return null;
            return error.MirrorOpenFailed;
        }
        defer pfs.close(fd);
        const info = pfs.fileInfo(fd) catch return error.MirrorReadFailed;
        if (!info.is_regular or info.size > max_mirror_bytes) return error.MirrorCorrupt;
        const len = std.math.cast(usize, info.size) orelse return error.MirrorCorrupt;
        const bytes = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = pfs.read(fd, bytes[offset..]);
            if (n <= 0) return error.MirrorReadFailed;
            offset += @intCast(n);
        }
        return bytes;
    }

    fn decodeMirrorTask(self: *TaskStore, obj: std.json.ObjectMap) !*Task {
        var task_owns_fields = false;
        const id = try jsonRequiredString(self.allocator, obj, "id");
        errdefer if (!task_owns_fields) self.allocator.free(id);
        const subject = try jsonRequiredString(self.allocator, obj, "subject");
        errdefer if (!task_owns_fields) self.allocator.free(subject);
        const description = try jsonRequiredString(self.allocator, obj, "description");
        errdefer if (!task_owns_fields) self.allocator.free(description);
        const active_form = try jsonOptionalString(self.allocator, obj, "active_form");
        errdefer if (!task_owns_fields) if (active_form) |value| self.allocator.free(value);
        const owner = try jsonOptionalString(self.allocator, obj, "owner");
        errdefer if (!task_owns_fields) if (owner) |value| self.allocator.free(value);
        const status = if (obj.get("status")) |value| switch (value) {
            .string => |raw| TaskStatus.fromString(raw) orelse return error.MirrorCorrupt,
            else => return error.MirrorCorrupt,
        } else .pending;
        if (status == .deleted) return error.MirrorCorrupt;
        const completed_ms: i64 = if (obj.get("completed_ms")) |value| switch (value) {
            .integer => |raw| raw,
            else => return error.MirrorCorrupt,
        } else 0;
        if (completed_ms < 0 or (status != .completed and completed_ms != 0)) return error.MirrorCorrupt;

        const t = try self.allocator.create(Task);
        t.* = .{
            .id = id,
            .subject = subject,
            .description = description,
            .active_form = active_form,
            .owner = owner,
            .status = status,
            .completed_ms = completed_ms,
        };
        task_owns_fields = true;
        errdefer {
            t.deinit(self.allocator);
            self.allocator.destroy(t);
        }
        try decodeStringList(self.allocator, obj, "blocks", &t.blocks);
        try decodeStringList(self.allocator, obj, "blocked_by", &t.blocked_by);
        return t;
    }

    fn jsonRequiredString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8) ![]u8 {
        const value = obj.get(name) orelse return error.MirrorCorrupt;
        return switch (value) {
            .string => |raw| try allocator.dupe(u8, raw),
            else => error.MirrorCorrupt,
        };
    }

    fn jsonOptionalString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8) !?[]u8 {
        const value = obj.get(name) orelse return null;
        return switch (value) {
            .string => |raw| try allocator.dupe(u8, raw),
            else => error.MirrorCorrupt,
        };
    }

    fn decodeStringList(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8, out: *std.ArrayList([]const u8)) !void {
        const value = obj.get(name) orelse return;
        const items = switch (value) {
            .array => |array| array.items,
            else => return error.MirrorCorrupt,
        };
        for (items) |item| {
            const raw = switch (item) {
                .string => |text| text,
                else => return error.MirrorCorrupt,
            };
            const owned = try allocator.dupe(u8, raw);
            errdefer allocator.free(owned);
            try out.append(allocator, owned);
        }
    }

    pub fn loadFromMirror(self: *TaskStore) !void {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        var mirror_txn = try self.beginMirrorTxnLocked();
        defer if (mirror_txn) |*lock| lock.release();
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
        var mirror_txn = try self.beginMirrorTxnLocked();
        defer if (mirror_txn) |*lock| lock.release();
        errdefer if (mirror_txn != null) self.reloadMirrorLocked() catch {};

        var task_owned_by_store = false;
        const t = try self.allocator.create(Task);
        errdefer if (!task_owned_by_store) self.allocator.destroy(t);

        const id = try std.fmt.allocPrint(self.allocator, "{d}", .{self.next_id});
        errdefer if (!task_owned_by_store) self.allocator.free(id);

        const subj = try self.allocator.dupe(u8, subject);
        errdefer if (!task_owned_by_store) self.allocator.free(subj);

        const desc = try self.allocator.dupe(u8, description);
        errdefer if (!task_owned_by_store) self.allocator.free(desc);

        const af: ?[]const u8 = if (active_form) |v| try self.allocator.dupe(u8, v) else null;
        errdefer if (!task_owned_by_store) if (af) |p| self.allocator.free(p);

        t.* = .{ .id = id, .subject = subj, .description = desc, .active_form = af };

        try self.tasks.append(self.allocator, t);
        task_owned_by_store = true;
        self.next_id += 1;
        try self.mirrorToFileLocked();
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
        var mirror_txn = try self.beginMirrorTxnLocked();
        defer if (mirror_txn) |*lock| lock.release();
        errdefer if (mirror_txn != null) self.reloadMirrorLocked() catch {};
        if (self.get(id) != null) return; // 幂等(get 无锁,不重入)
        var task_owned_by_store = false;
        const t = try self.allocator.create(Task);
        errdefer if (!task_owned_by_store) self.allocator.destroy(t);
        const id_owned = try self.allocator.dupe(u8, id);
        errdefer if (!task_owned_by_store) self.allocator.free(id_owned);
        const subj = try self.allocator.dupe(u8, subject);
        errdefer if (!task_owned_by_store) self.allocator.free(subj);
        const desc = try self.allocator.dupe(u8, description);
        errdefer if (!task_owned_by_store) self.allocator.free(desc);
        t.* = .{ .id = id_owned, .subject = subj, .description = desc, .active_form = null, .status = status };
        try self.tasks.append(self.allocator, t);
        task_owned_by_store = true;
        try self.mirrorToFileLocked();
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
    pub fn ledgerCounts(self: *TaskStore) LedgerCounts {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        var open: usize = 0;
        for (self.tasks.items) |t| {
            if (t.status == .pending or t.status == .in_progress) open += 1;
        }
        return .{ .open = open, .total = self.tasks.items.len };
    }

    pub fn updateStatus(self: *TaskStore, id: []const u8, status: TaskStatus) !void {
        _ = self.mutex.lock(); // task#19
        defer _ = self.mutex.unlock();
        var mirror_txn = try self.beginMirrorTxnLocked();
        defer if (mirror_txn) |*lock| lock.release();
        errdefer if (mirror_txn != null) self.reloadMirrorLocked() catch {};
        for (self.tasks.items, 0..) |t, i| {
            if (!std.mem.eql(u8, t.id, id)) continue;
            if (status == .deleted) {
                t.deinit(self.allocator);
                self.allocator.destroy(t);
                _ = self.tasks.orderedRemove(i);
                try self.mirrorToFileLocked();
                return;
            }
            t.status = status;
            // 记/清完成时戳(供 TUI 清单 TTL)。
            if (status == .completed) {
                if (t.completed_ms == 0) t.completed_ms = util_time.nowMs();
            } else {
                t.completed_ms = 0;
            }
            try self.mirrorToFileLocked();
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
        var mirror_txn = try self.beginMirrorTxnLocked();
        defer if (mirror_txn) |*lock| lock.release();
        errdefer if (mirror_txn != null) self.reloadMirrorLocked() catch {};
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
        try self.mirrorToFileLocked();
    }

    /// 添加 blocks/blockedBy 依赖（深拷贝 ID）。
    pub fn addBlocks(self: *TaskStore, id: []const u8, blocked_ids: []const []const u8) !void {
        _ = self.mutex.lock(); // task#19(一致性:虽 snapshot 暂不读 blocks)
        defer _ = self.mutex.unlock();
        var mirror_txn = try self.beginMirrorTxnLocked();
        defer if (mirror_txn) |*lock| lock.release();
        errdefer if (mirror_txn != null) self.reloadMirrorLocked() catch {};
        const t = self.get(id) orelse return error.TaskNotFound;
        for (blocked_ids) |bid| {
            const s = try self.allocator.dupe(u8, bid);
            errdefer self.allocator.free(s);
            try t.blocks.append(self.allocator, s);
        }
        try self.mirrorToFileLocked();
    }

    pub fn addBlockedBy(self: *TaskStore, id: []const u8, blocker_ids: []const []const u8) !void {
        _ = self.mutex.lock(); // task#19
        defer _ = self.mutex.unlock();
        var mirror_txn = try self.beginMirrorTxnLocked();
        defer if (mirror_txn) |*lock| lock.release();
        errdefer if (mirror_txn != null) self.reloadMirrorLocked() catch {};
        const t = self.get(id) orelse return error.TaskNotFound;
        for (blocker_ids) |bid| {
            const s = try self.allocator.dupe(u8, bid);
            errdefer self.allocator.free(s);
            try t.blocked_by.append(self.allocator, s);
        }
        try self.mirrorToFileLocked();
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
