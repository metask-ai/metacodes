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
const file_lock = @import("../util/file_lock.zig");
const util_json = @import("../util/json.zig");

const max_mirror_bytes = 4 * 1024 * 1024;

/// 镜像写入的临时文件名 `<path>.tmp.<pid>.<单调纳秒>.<序号>`。EXCL 创建要求每次写入各用一个
/// 新名字,时钟读数单独撑不起:macOS CLOCK_MONOTONIC 1 µs、Windows QPC 常见 100 ns 一跳,
/// 紧挨的两次读数相同。进程内原子序号 + pid 让任意两个写入方(本进程线程 / 别的进程)必不
/// 同名,不再依赖镜像锁把写入错开;纳秒让复用 pid 的后来进程不撞上崩溃残留的旧临时文件。
fn mirrorTmpPath(buf: []u8, path: []const u8) error{PathTooLong}![:0]const u8 {
    const pid = @import("platform").process.currentPid();
    const seq = mirror_tmp_seq.fetchAdd(1, .monotonic);
    return std.fmt.bufPrintZ(buf, "{s}.tmp.{d}.{d}.{d}", .{ path, pid, util_time.nowNs(), seq }) catch return error.PathTooLong;
}

var mirror_tmp_seq = std.atomic.Value(u64).init(0);

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
    /// 认领序号:每次置为 in_progress 取 清单内最大值 + 1,离开 in_progress 清零。
    /// 挑"当前任务"取序号最大的:开了不关的旧任务序号总是最小,不能冒充当前工作。
    /// 用序号不用时钟:它随镜像落盘、跨进程跨重启共享,而 nowMs 是开机相对时钟,
    /// 重启后变小,会让上一次开机留下的旧任务排在新认领之前。
    /// 0 = 不在进行中,或旧镜像文件未记录(排序时视为最老)。
    claim_seq: u64 = 0,
    /// 认领者身份(owned):认领时取清单声明的身份(TaskStore.setClaimer),离开 in_progress
    /// 清零。KG 降级的镜像按仓库共享(并发会话、swarm 队友都写同一个文件),任务锚、关闭
    /// 提示和记忆溯源据它只看本 agent 认领的行。null = 未知(旧镜像、未声明身份)。
    claimed_by: ?[]const u8 = null,
    /// 认领时刻(墙钟 unix ms;与 claimed_by 同生同灭)。别人的认领只在租约期
    /// (CLAIM_LEASE_MS)内算别人的;过期后可以被重新认领。
    claimed_at_ms: i64 = 0,
    blocks: std.ArrayList([]const u8) = .empty, // elements owned
    blocked_by: std.ArrayList([]const u8) = .empty, // elements owned

    pub fn deinit(self: *Task, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.subject);
        allocator.free(self.description);
        if (self.active_form) |s| allocator.free(s);
        if (self.owner) |s| allocator.free(s);
        if (self.claimed_by) |s| allocator.free(s);
        for (self.blocks.items) |s| allocator.free(s);
        self.blocks.deinit(allocator);
        for (self.blocked_by.items) |s| allocator.free(s);
        self.blocked_by.deinit(allocator);
    }
};

/// 处置"仍标为进行中、可能已过时"的任务的指引,compact 任务锚与关闭提示共用。
/// kg-* 任务的生命周期没有 deleted(只是 failed 的兼容别名),故单独点名 failed。
pub const STALE_TASK_GUIDANCE =
    "已被后续工作完成的用 TaskUpdate 标 completed;被取代或放弃的标 deleted(kg-* 任务标 failed 并写明原因);仍需继续的保留。";

/// 别人认领、租约已过期的任务的指引(compact 任务锚与关闭提示共用):和 TinyKG 一样,
/// 过期只意味着可以重新认领;对方也许只是没续租,不能直接关闭或删除。
pub const EXPIRED_CLAIM_GUIDANCE =
    "这些任务由其它会话或队友认领,已超过租约期(2 小时)未再认领,可能已无人在做。确认后先用 TaskUpdate(status=in_progress)重新认领,再按需处理;不要直接关闭或删除。";

/// 别人的认领在多久内仍算别人的,与 TinyKG task-claim 默认租约(7200s)一致:KG 模式
/// 靠它让崩掉/退出的会话不永久占坑,降级镜像没有租约服务,用认领时刻在读侧同样判过期——
/// 否则昨天进程留下的僵尸任务对之后所有会话都算"别人的",再也不会被提醒处理。
pub const CLAIM_LEASE_MS: i64 = 7200 * std.time.ms_per_s;

fn wallNowMs() i64 {
    return @intCast(@divTrunc(util_time.nowWallNs(), std.time.ns_per_ms));
}

/// 任务 a(清单下标 a_index)是否比 b 更近被认领。序号只在旧镜像缺序号(都为 0)时
/// 相同,此时清单中靠后者更近。全序:挑"当前任务"与排序共用这一条规则。
pub fn claimedMoreRecently(a_seq: u64, a_index: usize, b_seq: u64, b_index: usize) bool {
    if (a_seq != b_seq) return a_seq > b_seq;
    return a_index > b_index;
}

pub const TaskStore = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(*Task), // pointers so addresses stable across growth
    next_id: u64 = 1,
    /// 终态处置后被移除的 KG 镜像任务终身计数(见 ledgerCounts/noteKgMirrorClosed)。
    kg_closed: usize = 0,
    /// **task#19**:driver 单线程改 tasks;attach 快照(HTTP 线程)要跨线程读 → mutex 串行,免
    /// grow-during-iterate 悬挂 / torn 读 task 内容。所有**改 tasks / 改 task 内容**的公开方法锁内跑;
    /// get() 无锁(driver 内部/单线程用 + 被上锁方法内部调,不能重入)。snapshotTasks 锁内 dup 值语义。
    mutex: sync.Mutex = .{},
    /// **文件镜像路径**(owned;null = 关闭镜像,向后兼容)。KG 降级时它是同机 swarm
    /// 的共享任务真源，不是“各进程局部快照最后写者覆盖”。每次 mutation 都按固定顺序
    /// `mutex -> file_lock -> reload -> mutate -> fsync+rename`，因此 stale writer 不会抹掉
    /// 其它 teammate 的任务；文件损坏或锁失败会在 mutation 前 fail closed。
    mirror_path: ?[]u8 = null,
    /// 使用本清单的 agent 以什么身份认领任务(owned;null = 未声明,不按认领者过滤)。
    claimer: ?[]u8 = null,

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

    /// 声明使用本清单的 agent 以什么身份认领任务。必须与工具认领 KG 租约的身份同源
    /// (ToolContext.kg_agent_ident orelse agent_ident);agent_loop.run 每次进入时设置,
    /// 会话轮换后自然跟上(轮换前的身份认领的行之后算别人的,到期后可重新认领)。
    /// 之后的认领把它记进任务行(Task.claimed_by)。
    /// 复制失败时身份清空(不按认领者过滤、认领不记身份),而不是留着可能已轮换掉的旧身份。
    pub fn setClaimer(self: *TaskStore, ident: ?[]const u8) !void {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        if (ident) |new| {
            if (self.claimer) |current| {
                if (std.mem.eql(u8, current, new)) return;
            }
        }
        const replacement: ?[]u8 = if (ident) |new| self.allocator.dupe(u8, new) catch |err| {
            if (self.claimer) |current| self.allocator.free(current);
            self.claimer = null;
            return err;
        } else null;
        if (self.claimer) |current| self.allocator.free(current);
        self.claimer = replacement;
    }

    /// 一条进行中认领对本 agent 的归属。
    const Attribution = enum {
        /// 本 agent 的(或认领者未知):可点名续做、提示关闭、作溯源。
        own,
        /// 别人的本地认领,租约已过期:可能已没人在做。提示里单独列出,和 TinyKG 一样只建议
        /// 先重新认领再处理,不建议直接关闭或删除(对方也许只是没续租)。
        expired_foreign,
        /// 别人仍持有的认领:不点名、不建议处理、不作溯源。
        foreign,
    };

    fn attribution(self: *const TaskStore, t: *const Task, now_ms: i64) Attribution {
        const me = self.claimer orelse return .own;
        const holder = t.claimed_by orelse return .own;
        if (std.mem.eql(u8, holder, me)) return .own;
        // kg-* 行的租约归 TinyKG 管:镜像只是启动时的快照,本地不判过期(TinyKG 让租约过期后,
        // TaskList 的实时 frontier 和下次启动的重建都会把它放回任务池)。
        if (std.mem.startsWith(u8, t.id, "kg-")) return .foreign;
        // 时刻未知(0)或比"现在 + 一个租约"还晚(时钟错乱/被改过)都不信;略早于认领时刻
        // (时钟小幅回拨)按未过期处理。
        if (t.claimed_at_ms == 0 or t.claimed_at_ms > now_ms +| CLAIM_LEASE_MS) return .expired_foreign;
        return if (now_ms - t.claimed_at_ms >= CLAIM_LEASE_MS) .expired_foreign else .foreign;
    }

    /// **task#19 跨线程读**:锁内把任务快照成 owned 值(id/subject/status),供 attach 快照
    /// 等跨线程读者。用完交给 `freeTaskViews`。
    pub const TaskView = struct {
        id: []u8,
        subject: []u8,
        status: TaskStatus,
        /// snapshotOwnInProgress 专用:别人的认领、租约已过期(只该提示先重新认领再处理)。
        expired_claim: bool = false,
    };

    /// 全部任务,清单顺序。
    pub fn snapshotTasks(self: *TaskStore, allocator: std.mem.Allocator) ![]TaskView {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        return dupeViews(allocator, self.tasks.items, null);
    }

    /// 本 agent 该处理的进行中任务:先是自己的(最近认领在前,与 latestInProgress 同一
    /// 规则),再是别人租约已过期的(expired_claim = true,同样最近在前);别人仍持有的不含。
    /// 共享镜像先重放磁盘:队友/别的会话刚接手或关闭的行不能按陈旧的本地副本被点名。
    /// 重放失败(锁忙、文件损坏)只是退回内存副本——这是只读快照,不该让任务锚整个消失。
    pub fn snapshotOwnInProgress(self: *TaskStore, allocator: std.mem.Allocator) ![]TaskView {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        var mirror_txn = self.beginMirrorTxnLocked() catch null;
        defer if (mirror_txn) |*lock| lock.release();
        const Row = struct { index: usize, expired: bool };
        var rows: std.ArrayList(Row) = .empty;
        defer rows.deinit(allocator);
        const now_ms = wallNowMs();
        for (self.tasks.items, 0..) |t, i| {
            if (t.status != .in_progress) continue;
            switch (self.attribution(t, now_ms)) {
                .own => try rows.append(allocator, .{ .index = i, .expired = false }),
                .expired_foreign => try rows.append(allocator, .{ .index = i, .expired = true }),
                .foreign => {},
            }
        }
        const Order = struct {
            tasks: []const *Task,
            fn before(ctx: @This(), a: Row, b: Row) bool {
                if (a.expired != b.expired) return !a.expired;
                return claimedMoreRecently(ctx.tasks[a.index].claim_seq, a.index, ctx.tasks[b.index].claim_seq, b.index);
            }
        };
        std.mem.sort(Row, rows.items, Order{ .tasks = self.tasks.items }, Order.before);
        const picks = try allocator.alloc(usize, rows.items.len);
        defer allocator.free(picks);
        for (rows.items, picks) |row, *pick| pick.* = row.index;
        const views = try dupeViews(allocator, self.tasks.items, picks);
        for (rows.items, views) |row, *view| view.expired_claim = row.expired;
        return views;
    }

    /// 释放快照;空切片(含 `catch &.{}` 的静态空值)是 no-op。
    pub fn freeTaskViews(allocator: std.mem.Allocator, views: []const TaskView) void {
        for (views) |v| {
            allocator.free(v.id);
            allocator.free(v.subject);
        }
        allocator.free(views);
    }

    /// 复制 `pick` 选中的行(null = 全部),按 pick 顺序。失败时已复制的全部释放。
    fn dupeViews(allocator: std.mem.Allocator, tasks: []const *Task, pick: ?[]const usize) ![]TaskView {
        const len = if (pick) |p| p.len else tasks.len;
        const out = try allocator.alloc(TaskView, len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |v| {
                allocator.free(v.id);
                allocator.free(v.subject);
            }
            allocator.free(out);
        }
        while (n < len) : (n += 1) {
            const t = tasks[if (pick) |p| p[n] else n];
            const id = try allocator.dupe(u8, t.id);
            errdefer allocator.free(id);
            out[n] = .{ .id = id, .subject = try allocator.dupe(u8, t.subject), .status = t.status };
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
        if (self.claimer) |c| self.allocator.free(c);
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
        const tmp = try mirrorTmpPath(&tmp_buf, path);
        // EXCL + unpredictable per-write suffix prevents a pre-existing hardlink at a
        // fixed `.tmp` pathname from being truncated before the atomic rename.
        const fd = pfs.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, @as(c_uint, 0o600));
        if (fd < 0) return error.MirrorOpenFailed;
        var fd_open = true;
        var published = false;
        defer {
            if (fd_open) pfs.close(fd);
            if (!published) pfs.unlinkPath(tmp.ptr) catch {};
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
        try util_json.writeJsonString(&w.writer, t.id);
        try w.writer.writeAll(",\"subject\":");
        try util_json.writeJsonString(&w.writer, t.subject);
        try w.writer.writeAll(",\"description\":");
        try util_json.writeJsonString(&w.writer, t.description);
        try w.writer.writeAll(",\"status\":\"");
        try w.writer.writeAll(t.status.toString());
        try w.writer.writeAll("\"");
        if (t.active_form) |af| {
            try w.writer.writeAll(",\"active_form\":");
            try util_json.writeJsonString(&w.writer, af);
        }
        if (t.owner) |o| {
            try w.writer.writeAll(",\"owner\":");
            try util_json.writeJsonString(&w.writer, o);
        }
        if (t.completed_ms != 0) {
            try w.writer.print(",\"completed_ms\":{d}", .{t.completed_ms});
        }
        if (t.claim_seq != 0) {
            try w.writer.print(",\"claim_seq\":{d}", .{t.claim_seq});
        }
        if (t.claimed_by) |holder| {
            try w.writer.writeAll(",\"claimed_by\":");
            try util_json.writeJsonString(&w.writer, holder);
            try w.writer.print(",\"claimed_at_ms\":{d}", .{t.claimed_at_ms});
        }
        if (t.blocks.items.len > 0) {
            try w.writer.writeAll(",\"blocks\":[");
            var first_b = true;
            for (t.blocks.items) |b| {
                if (!first_b) try w.writer.writeAll(",");
                first_b = false;
                try util_json.writeJsonString(&w.writer, b);
            }
            try w.writer.writeAll("]");
        }
        if (t.blocked_by.items.len > 0) {
            try w.writer.writeAll(",\"blocked_by\":[");
            var first_bb = true;
            for (t.blocked_by.items) |b| {
                if (!first_bb) try w.writer.writeAll(",");
                first_bb = false;
                try util_json.writeJsonString(&w.writer, b);
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
        const claimed_by = try jsonOptionalString(self.allocator, obj, "claimed_by");
        errdefer if (!task_owns_fields) if (claimed_by) |value| self.allocator.free(value);
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
        // 旧镜像没有该字段:in_progress 行读作 0(排序视为最老),不算损坏。
        const claim_seq: u64 = if (obj.get("claim_seq")) |value| switch (value) {
            .integer => |raw| std.math.cast(u64, raw) orelse return error.MirrorCorrupt,
            else => return error.MirrorCorrupt,
        } else 0;
        if (status != .in_progress and (claim_seq != 0 or claimed_by != null)) return error.MirrorCorrupt;
        const claimed_at_ms: i64 = if (obj.get("claimed_at_ms")) |value| switch (value) {
            .integer => |raw| raw,
            else => return error.MirrorCorrupt,
        } else 0;
        if (claimed_at_ms < 0 or (claimed_by == null and claimed_at_ms != 0)) return error.MirrorCorrupt;

        const t = try self.allocator.create(Task);
        t.* = .{
            .id = id,
            .subject = subject,
            .description = description,
            .active_form = active_form,
            .owner = owner,
            .status = status,
            .completed_ms = completed_ms,
            .claim_seq = claim_seq,
            .claimed_by = claimed_by,
            .claimed_at_ms = claimed_at_ms,
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
    /// mirror 开启时,后续任何 mutation 的 reload 会整体替换 task 对象——
    /// 返回的指针(及其字段切片)只保证在下一次 store mutation 开始前有效。
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
    /// in_progress 行记为本清单声明的身份认领(本 agent 刚认领的 KG 任务)。
    pub fn createWithId(
        self: *TaskStore,
        id: []const u8,
        subject: []const u8,
        description: []const u8,
        status: TaskStatus,
    ) !void {
        return self.createWithIdClaimed(id, subject, description, status, .current);
    }

    /// 同 createWithId,但 in_progress 行的认领者是给定的租约持有者(启动时按 KG frontier
    /// 重建镜像:租约可能属于别的会话或队友;null = 租约已过期,持有者未知)。
    pub fn createWithIdHeldBy(
        self: *TaskStore,
        id: []const u8,
        subject: []const u8,
        description: []const u8,
        status: TaskStatus,
        holder: ?[]const u8,
    ) !void {
        return self.createWithIdClaimed(id, subject, description, status, .{ .holder = holder });
    }

    const Claimant = union(enum) { current, holder: ?[]const u8 };

    fn createWithIdClaimed(
        self: *TaskStore,
        id: []const u8,
        subject: []const u8,
        description: []const u8,
        status: TaskStatus,
        claimant: Claimant,
    ) !void {
        _ = self.mutex.lock(); // task#19
        defer _ = self.mutex.unlock();
        var mirror_txn = try self.beginMirrorTxnLocked();
        defer if (mirror_txn) |*lock| lock.release();
        errdefer if (mirror_txn != null) self.reloadMirrorLocked() catch {};
        if (self.get(id) != null) return; // 幂等(get 无锁,不重入)
        const holder: ?[]const u8 = if (status != .in_progress) null else switch (claimant) {
            .current => self.claimer,
            .holder => |value| value,
        };
        var task_owned_by_store = false;
        const t = try self.allocator.create(Task);
        errdefer if (!task_owned_by_store) self.allocator.destroy(t);
        const id_owned = try self.allocator.dupe(u8, id);
        errdefer if (!task_owned_by_store) self.allocator.free(id_owned);
        const subj = try self.allocator.dupe(u8, subject);
        errdefer if (!task_owned_by_store) self.allocator.free(subj);
        const desc = try self.allocator.dupe(u8, description);
        errdefer if (!task_owned_by_store) self.allocator.free(desc);
        const claimed_by: ?[]const u8 = if (holder) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (!task_owned_by_store) if (claimed_by) |value| self.allocator.free(value);
        t.* = .{
            .id = id_owned,
            .subject = subj,
            .description = desc,
            .active_form = null,
            .status = status,
            .claim_seq = if (status == .in_progress) self.nextClaimSeqLocked() else 0,
            .claimed_by = claimed_by,
            .claimed_at_ms = if (claimed_by != null) wallNowMs() else 0,
        };
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
    /// of guessing which task should receive a fact. Rows another agent
    /// claimed (a teammate's, or another session's live lease mirrored at
    /// startup) are not this loop's and are not counted.
    pub fn uniqueActiveKgTaskId(self: *TaskStore) ?u64 {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        const now_ms = wallNowMs();
        var active: ?u64 = null;
        for (self.tasks.items) |task| {
            if (task.status != .in_progress or !std.mem.startsWith(u8, task.id, "kg-")) continue;
            if (self.attribution(task, now_ms) != .own) continue;
            const node_id = std.fmt.parseInt(u64, task.id["kg-".len..], 10) catch return null;
            if (node_id == 0 or active != null) return null;
            active = node_id;
        }
        return active;
    }

    /// 本 agent 最近认领的进行中任务;无则 null。不加锁,与 `get` 同约定:只能在改动本清单的
    /// agent 线程调用(它读 `claimer`,setClaimer 换身份时会释放旧值),跨线程读要用快照。
    pub fn latestInProgress(self: *const TaskStore) ?*Task {
        return self.tasks.items[self.latestInProgressIndex(false) orelse return null];
    }

    /// 最近认领的 `kg-*` 进行中任务的节点 id;畸形 id 跳过,无则 null。
    /// 记忆溯源锚用:多个进行中时取最新的,而不是最老的(开了没关的那个)。
    pub fn latestInProgressKgTaskId(self: *TaskStore) ?u64 {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        const index = self.latestInProgressIndex(true) orelse return null;
        return kgNodeId(self.tasks.items[index].id);
    }

    fn latestInProgressIndex(self: *const TaskStore, kg_only: bool) ?usize {
        const now_ms = wallNowMs();
        var best: ?usize = null;
        for (self.tasks.items, 0..) |t, i| {
            if (t.status != .in_progress) continue;
            if (kg_only and kgNodeId(t.id) == null) continue;
            if (self.attribution(t, now_ms) != .own) continue;
            if (best) |b| {
                if (!claimedMoreRecently(t.claim_seq, i, self.tasks.items[b].claim_seq, b)) continue;
            }
            best = i;
        }
        return best;
    }

    /// `kg-<节点号>` 的节点号;非 kg 行、畸形号与 0(不是有效节点)→ null。
    fn kgNodeId(id: []const u8) ?u64 {
        if (!std.mem.startsWith(u8, id, "kg-")) return null;
        const node_id = std.fmt.parseInt(u64, id["kg-".len..], 10) catch return null;
        return if (node_id == 0) null else node_id;
    }

    /// 下一个认领序号:清单内最大值 + 1。调用方持有 mutex;镜像开启时已在事务里重放过
    /// 磁盘,别的进程刚写下的认领也算在内。封顶在 i64 上限:镜像 JSON 只读得回这么大的
    /// 整数,越过它的序号写得出去、读回来却判损坏(之后所有 Task* 都会失败)。
    fn nextClaimSeqLocked(self: *const TaskStore) u64 {
        const ceiling: u64 = std.math.maxInt(i64);
        var max: u64 = 0;
        for (self.tasks.items) |t| max = @max(max, t.claim_seq);
        return if (max >= ceiling) ceiling else max + 1;
    }

    /// 更新 status。若 deleted 则实际从列表删除并释放。
    pub fn ledgerCounts(self: *TaskStore) LedgerCounts {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        var open: usize = 0;
        for (self.tasks.items) |t| {
            if (t.status == .pending or t.status == .in_progress) open += 1;
        }
        // KG write-through 任务的镜像在终态处置时被物理删除(TaskTab 显示
        // 同步需要),但账本语义的 total 是"曾登记过的需求项"——不含终身
        // 计数时,全部闭合的健康会话会被记成 items_total=0,end-gate 据此
        // 误发"从未记录需求账本"(fstack-r2 全部 16 个 trial 实测如此,
        // 假 nudge 在训练模型无视 nudge;PO-V2 M1)。
        return .{ .open = open, .total = self.tasks.items.len + self.kg_closed };
    }

    /// KG 镜像任务进入终态(completed/failed/stop-closed)被移除时的终身
    /// 计数。只在终态处置点调用——取消/GC 不是需求项生命周期的完成。
    pub fn noteKgMirrorClosed(self: *TaskStore) void {
        _ = self.mutex.lock();
        defer _ = self.mutex.unlock();
        self.kg_closed += 1;
    }

    pub fn updateStatus(self: *TaskStore, id: []const u8, status: TaskStatus) !void {
        _ = self.mutex.lock(); // task#19
        defer _ = self.mutex.unlock();
        // mirror 开启时 beginMirrorTxnLocked 的 reload 会整体替换并释放现有 task 对象。
        // 调用方传的 id 常借自 store 内 task(`store.updateStatus(t.id, ...)`)——不先拷贝,
        // reload 后它就是悬垂指针,查找失配 → TaskNotFound 被调用方吞掉,更新静默失效。
        const id_copy = try self.allocator.dupe(u8, id);
        defer self.allocator.free(id_copy);
        // 认领者先复制好(唯一可能失败的分配),之后的状态改写不会半途失败。
        var claimed_by: ?[]const u8 = if (status != .in_progress) null else if (self.claimer) |me| try self.allocator.dupe(u8, me) else null;
        defer if (claimed_by) |value| self.allocator.free(value);
        var mirror_txn = try self.beginMirrorTxnLocked();
        defer if (mirror_txn) |*lock| lock.release();
        errdefer if (mirror_txn != null) self.reloadMirrorLocked() catch {};
        for (self.tasks.items, 0..) |t, i| {
            if (!std.mem.eql(u8, t.id, id_copy)) continue;
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
            // 每次置 in_progress 都取新序号并记认领者(重新认领 = 此刻由本 agent 在做),
            // 离开即清零。
            t.claim_seq = if (status == .in_progress) self.nextClaimSeqLocked() else 0;
            if (t.claimed_by) |old| self.allocator.free(old);
            t.claimed_at_ms = if (claimed_by != null) wallNowMs() else 0;
            t.claimed_by = claimed_by;
            claimed_by = null;
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
        // 先用可变局部变量接管所有权(在任何可失败步骤之前,含下方 dupe/txn)。
        // 任一错误路径由 errdefer 释放。
        var subject = opts.subject;
        errdefer if (subject) |s| self.allocator.free(s);
        var description = opts.description;
        errdefer if (description) |s| self.allocator.free(s);
        var active_form = opts.active_form;
        errdefer if (active_form) |s| self.allocator.free(s);
        var owner = opts.owner;
        errdefer if (owner) |s| self.allocator.free(s);
        // id 可能借自 store 内 task,mirror reload 会释放它——先拷贝(见 updateStatus)。
        const id_copy = try self.allocator.dupe(u8, id);
        defer self.allocator.free(id_copy);
        var mirror_txn = try self.beginMirrorTxnLocked();
        defer if (mirror_txn) |*lock| lock.release();
        errdefer if (mirror_txn != null) self.reloadMirrorLocked() catch {};

        const t = self.get(id_copy) orelse return error.TaskNotFound;

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
        // id 可能借自 store 内 task,mirror reload 会释放它——先拷贝(见 updateStatus)。
        const id_copy = try self.allocator.dupe(u8, id);
        defer self.allocator.free(id_copy);
        var mirror_txn = try self.beginMirrorTxnLocked();
        defer if (mirror_txn) |*lock| lock.release();
        errdefer if (mirror_txn != null) self.reloadMirrorLocked() catch {};
        const t = self.get(id_copy) orelse return error.TaskNotFound;
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
        // id 可能借自 store 内 task,mirror reload 会释放它——先拷贝(见 updateStatus)。
        const id_copy = try self.allocator.dupe(u8, id);
        defer self.allocator.free(id_copy);
        var mirror_txn = try self.beginMirrorTxnLocked();
        defer if (mirror_txn) |*lock| lock.release();
        errdefer if (mirror_txn != null) self.reloadMirrorLocked() catch {};
        const t = self.get(id_copy) orelse return error.TaskNotFound;
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

test "TaskStore: claim_seq 只在 in_progress 期间非零,每次认领取更大的序号" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    const a = try store.create("A", "", null);
    const b = try store.create("B", "", null);
    try testing.expectEqual(@as(u64, 0), a.claim_seq);

    try store.updateStatus(a.id, .in_progress);
    try store.updateStatus(b.id, .in_progress);
    try testing.expect(b.claim_seq > a.claim_seq);
    try store.updateStatus(a.id, .in_progress); // 重新认领
    try testing.expect(a.claim_seq > b.claim_seq);

    try store.updateStatus(a.id, .pending);
    try testing.expectEqual(@as(u64, 0), a.claim_seq);
    try store.updateStatus(b.id, .completed);
    try testing.expectEqual(@as(u64, 0), b.claim_seq);

    try store.createWithId("kg-7", "claimed", "", .in_progress);
    try testing.expect(store.get("kg-7").?.claim_seq != 0);
    try store.createWithId("kg-8", "open", "", .pending);
    try testing.expectEqual(@as(u64, 0), store.get("kg-8").?.claim_seq);
}

test "TaskStore: latestInProgress 取最近认领的,而不是最早开的那个" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    try testing.expect(store.latestInProgress() == null);

    const old = try store.create("v189 旧思路", "", null);
    const mid = try store.create("v215 中间", "", null);
    const cur = try store.create("v277 当前", "", null);
    try store.updateStatus(old.id, .in_progress);
    try store.updateStatus(mid.id, .in_progress);
    try store.updateStatus(cur.id, .in_progress);
    try testing.expectEqualStrings("3", store.latestInProgress().?.id);

    // 重新认领最老的那个 → 它才是当前任务。
    try store.updateStatus(old.id, .in_progress);
    try testing.expectEqualStrings("1", store.latestInProgress().?.id);
    try store.updateStatus(old.id, .completed);
    try testing.expectEqualStrings("3", store.latestInProgress().?.id);

    // 旧镜像缺序号(都为 0)时按清单位置,靠后者更近。
    mid.claim_seq = 0;
    cur.claim_seq = 0;
    try testing.expectEqualStrings("3", store.latestInProgress().?.id);

    const views = try store.snapshotOwnInProgress(testing.allocator);
    defer TaskStore.freeTaskViews(testing.allocator, views);
    try testing.expectEqual(@as(usize, 2), views.len);
    try testing.expectEqualStrings("3", views[0].id);
    try testing.expectEqualStrings("2", views[1].id);
}

test "TaskStore: latestInProgressKgTaskId 取最新 kg-* 认领,跳过非 kg 与畸形 id" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    try testing.expect(store.latestInProgressKgTaskId() == null);

    try store.createWithId("kg-41", "old", "", .in_progress);
    try store.createWithId("kg-42", "new", "", .in_progress);
    try store.createWithId("session-only", "local", "", .in_progress);
    try store.createWithId("kg-bad", "malformed", "", .in_progress);
    try store.createWithId("kg-0", "not a node", "", .in_progress);
    try testing.expectEqual(@as(?u64, 42), store.latestInProgressKgTaskId());

    try store.updateStatus("kg-41", .in_progress);
    try testing.expectEqual(@as(?u64, 41), store.latestInProgressKgTaskId());
    try store.updateStatus("kg-41", .pending);
    try testing.expectEqual(@as(?u64, 42), store.latestInProgressKgTaskId());
}

test "TaskStore: 认领记下声明的身份,离开 in_progress 清掉;别人仍持有的行不算自己的" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    for (0..3) |_| _ = try store.create("t", "", null);
    try store.setClaimer("me");
    try store.setClaimer("me"); // 同值重复声明是 no-op
    // 另一个会话在共享镜像里的活认领(本地行):别人的。
    try store.createWithIdHeldBy("x1", "其它会话在做", "", .in_progress, "other-session");
    try store.updateStatus("1", .in_progress);
    try store.updateStatus("3", .in_progress);
    try testing.expectEqualStrings("me", store.get("1").?.claimed_by.?);
    try testing.expectEqualStrings("other-session", store.get("x1").?.claimed_by.?);
    // 墙钟时刻,不是开机相对时钟(后者在镜像里跨重启就错)。
    try testing.expect(store.get("1").?.claimed_at_ms > 1_577_836_800_000); // 2020-01-01

    {
        const own = try store.snapshotOwnInProgress(testing.allocator);
        defer TaskStore.freeTaskViews(testing.allocator, own);
        try testing.expectEqual(@as(usize, 2), own.len);
        try testing.expectEqualStrings("3", own[0].id);
        try testing.expectEqualStrings("1", own[1].id);
        try testing.expect(!own[0].expired_claim and !own[1].expired_claim);
    }
    try testing.expectEqualStrings("3", store.latestInProgress().?.id);

    // 本 agent 接手 x1:认领者换成自己,它成了当前任务。
    try store.updateStatus("x1", .in_progress);
    try testing.expectEqualStrings("me", store.get("x1").?.claimed_by.?);
    try testing.expectEqualStrings("x1", store.latestInProgress().?.id);
    try store.updateStatus("x1", .completed);
    try testing.expect(store.get("x1").?.claimed_by == null);
    try testing.expectEqual(@as(i64, 0), store.get("x1").?.claimed_at_ms);

    // 不声明身份时不过滤(子 agent / 单机清单),认领也不记身份。
    try store.setClaimer(null);
    try store.updateStatus("2", .in_progress);
    try testing.expect(store.get("2").?.claimed_by == null);
    const all = try store.snapshotOwnInProgress(testing.allocator);
    defer TaskStore.freeTaskViews(testing.allocator, all);
    try testing.expectEqual(@as(usize, 3), all.len);
}

// 不记旧身份:身份轮换后(Ctrl+B 转后台、切换会话)旧身份认领的行算别人的,租约期内不点名,
// 过期后只提示先重新认领。转到后台的那条对话用的是全新的空清单,接不走这些行;
// 它们靠租约过期回到可认领状态。
test "TaskStore: 身份轮换后,旧身份的认领不当成新身份自己的" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    _ = try store.create("moved to background", "", null);
    try store.setClaimer("session-1");
    try store.updateStatus("1", .in_progress);
    try store.createWithId("kg-5", "lease held by session-1", "", .in_progress);
    try store.setClaimer("session-2");

    // 租约期内:都不是前台新会话的,不点名续做、不作溯源。
    try testing.expect(store.latestInProgress() == null);
    try testing.expect(store.latestInProgressKgTaskId() == null);
    // 过期后本地行可以被重新认领,但仍不是"当前任务";kg 行的租约归 TinyKG,本地不判过期。
    store.get("1").?.claimed_at_ms -= CLAIM_LEASE_MS;
    store.get("kg-5").?.claimed_at_ms -= CLAIM_LEASE_MS;
    try testing.expect(store.latestInProgress() == null);
    const views = try store.snapshotOwnInProgress(testing.allocator);
    defer TaskStore.freeTaskViews(testing.allocator, views);
    try testing.expectEqual(@as(usize, 1), views.len);
    try testing.expectEqualStrings("1", views[0].id);
    try testing.expect(views[0].expired_claim);
}

test "TaskStore: 共享镜像读不了时,快照退回内存副本而不是报错" {
    const test_fs = @import("../util/fs.zig");
    var dbuf: [256]u8 = undefined;
    const dir_path = test_fs.testing.uniqueDir(&dbuf, "cc-zig-taskstore-snapshot-fallback");
    try test_fs.mkdirParents(dir_path);
    defer test_fs.testing.rmrfBestEffort(dir_path);
    var pbuf: [192]u8 = undefined;
    const mirror = try std.fmt.bufPrint(&pbuf, "{s}/tasks.json", .{dir_path});

    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    try store.setMirror(mirror);
    try store.setClaimer("me");
    _ = try store.create("mine", "", null);
    try store.updateStatus("1", .in_progress);
    try writeMirrorFixture(mirror, "{truncated");

    const views = try store.snapshotOwnInProgress(testing.allocator);
    defer TaskStore.freeTaskViews(testing.allocator, views);
    try testing.expectEqual(@as(usize, 1), views.len);
    try testing.expectEqualStrings("1", views[0].id);
}

test "TaskStore: 重新认领刷新认领时刻(续租)" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    try store.setClaimer("me");
    _ = try store.create("t", "", null);
    try store.updateStatus("1", .in_progress);
    store.get("1").?.claimed_at_ms = 1;
    try store.updateStatus("1", .in_progress);
    try testing.expect(store.get("1").?.claimed_at_ms > 1_577_836_800_000);
}

test "TaskStore: kg 行别人持有的租约本地永不判过期(TinyKG 负责)" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    try store.setClaimer("me");
    try store.createWithIdHeldBy("kg-9", "队友的持久任务", "", .in_progress, "worker@team");
    store.get("kg-9").?.claimed_at_ms -= 10 * CLAIM_LEASE_MS;
    const views = try store.snapshotOwnInProgress(testing.allocator);
    defer TaskStore.freeTaskViews(testing.allocator, views);
    try testing.expectEqual(@as(usize, 0), views.len);
    try testing.expect(store.latestInProgressKgTaskId() == null);
    try testing.expect(store.uniqueActiveKgTaskId() == null);
}

test "TaskStore: 快照先重放共享镜像——别的写入方刚接手的任务不再按陈旧副本算自己的" {
    const test_fs = @import("../util/fs.zig");
    var dbuf: [256]u8 = undefined;
    const dir_path = test_fs.testing.uniqueDir(&dbuf, "cc-zig-taskstore-snapshot-reload");
    try test_fs.mkdirParents(dir_path);
    defer test_fs.testing.rmrfBestEffort(dir_path);
    var pbuf: [192]u8 = undefined;
    const mirror = try std.fmt.bufPrint(&pbuf, "{s}/tasks.json", .{dir_path});

    var lead = TaskStore.init(testing.allocator);
    defer lead.deinit();
    try lead.setMirror(mirror);
    try lead.setClaimer("lead");
    _ = try lead.create("shared", "", null);
    try lead.updateStatus("1", .in_progress);

    // 队友(另一个写入方)接手任务 1;lead 的内存副本还写着自己认领。
    var worker = TaskStore.init(testing.allocator);
    defer worker.deinit();
    try worker.setMirror(mirror);
    try worker.setClaimer("worker@team");
    try worker.loadFromMirror();
    try worker.updateStatus("1", .in_progress);
    try testing.expectEqualStrings("lead", lead.get("1").?.claimed_by.?);

    const views = try lead.snapshotOwnInProgress(testing.allocator);
    defer TaskStore.freeTaskViews(testing.allocator, views);
    try testing.expectEqual(@as(usize, 0), views.len);
}

test "TaskStore: 别人的认领只在租约期内算别人的——过期后作为僵尸排在自己的之后" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    try store.setClaimer("today-session");
    try store.createWithIdHeldBy("y1", "昨天的 A", "", .in_progress, "yesterday-session");
    try store.createWithIdHeldBy("y2", "昨天的 B", "", .in_progress, "yesterday-session");
    _ = try store.create("今天的", "", null);
    try store.updateStatus("1", .in_progress);

    // 租约期内:昨天的两行不是本 agent 的。
    {
        const own = try store.snapshotOwnInProgress(testing.allocator);
        defer TaskStore.freeTaskViews(testing.allocator, own);
        try testing.expectEqual(@as(usize, 1), own.len);
    }
    // y1 的租约到期、y2 的认领时刻未知:作为过期的别人认领排在自己的之后,但不是当前任务。
    store.get("y1").?.claimed_at_ms -= CLAIM_LEASE_MS;
    store.get("y2").?.claimed_at_ms = 0;
    {
        const own = try store.snapshotOwnInProgress(testing.allocator);
        defer TaskStore.freeTaskViews(testing.allocator, own);
        try testing.expectEqual(@as(usize, 3), own.len);
        try testing.expectEqualStrings("1", own[0].id);
        try testing.expect(!own[0].expired_claim);
        try testing.expectEqualStrings("y2", own[1].id);
        try testing.expectEqualStrings("y1", own[2].id);
        try testing.expect(own[1].expired_claim and own[2].expired_claim);
    }
    try testing.expectEqualStrings("1", store.latestInProgress().?.id);

    // 认领时刻略晚于现在(时钟小幅回拨):仍在租约期;远超"现在 + 一个租约"(时钟错乱或被改):不信。
    const now = wallNowMs();
    store.get("y1").?.claimed_at_ms = now + 60_000;
    store.get("y2").?.claimed_at_ms = now + 2 * CLAIM_LEASE_MS;
    {
        const own = try store.snapshotOwnInProgress(testing.allocator);
        defer TaskStore.freeTaskViews(testing.allocator, own);
        try testing.expectEqual(@as(usize, 2), own.len);
        try testing.expectEqualStrings("y2", own[1].id);
    }
}

test "TaskStore: uniqueActiveKgTaskId 不把别人的 kg 认领算作本 loop 的" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    try store.createWithIdHeldBy("kg-40", "previous session's live lease", "", .in_progress, "old-session");
    try store.setClaimer("me");
    try testing.expect(store.uniqueActiveKgTaskId() == null); // 只有别人的行:不挂执行事实
    try store.createWithId("kg-41", "mine", "", .in_progress);
    try testing.expectEqual(@as(?u64, 41), store.uniqueActiveKgTaskId());
}

test "TaskStore: setClaimer 复制失败时清空身份,不留可能已轮换掉的旧身份" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    try store.setClaimer("old-session");
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    store.allocator = failing.allocator();
    try testing.expectError(error.OutOfMemory, store.setClaimer("new-session"));
    store.allocator = testing.allocator;
    try testing.expect(store.claimer == null);
}

test "TaskStore: 显式 id 插入的认领者——本 agent 认领记当前身份,重建镜像记租约持有者" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    try store.setClaimer("lead-session");
    try store.createWithId("kg-10", "mine", "", .in_progress);
    try store.createWithIdHeldBy("kg-11", "teammate's", "", .in_progress, "worker@team");
    try store.createWithIdHeldBy("kg-12", "lease expired", "", .in_progress, null);
    try store.createWithIdHeldBy("kg-13", "open", "", .pending, "worker@team");
    try testing.expectEqualStrings("lead-session", store.get("kg-10").?.claimed_by.?);
    try testing.expectEqualStrings("worker@team", store.get("kg-11").?.claimed_by.?);
    try testing.expect(store.get("kg-12").?.claimed_by == null);
    try testing.expect(store.get("kg-13").?.claimed_by == null); // 非进行中不记认领者

    // 溯源不挂到队友的任务上:最近插入的 kg-11/kg-12 里只有持有者未知的 12 算自己的。
    try testing.expectEqual(@as(?u64, 12), store.latestInProgressKgTaskId());
    try store.updateStatus("kg-12", .pending);
    try testing.expectEqual(@as(?u64, 10), store.latestInProgressKgTaskId());
}

test "TaskStore: 快照在中途分配失败时不泄漏" {
    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    for (0..3) |_| {
        const t = try store.create("subject", "", null);
        try store.updateStatus(t.id, .in_progress);
    }
    // 每次分配都可能失败:失败点落在 id 与 subject 之间时,id 必须被释放。
    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        if (store.snapshotTasks(failing.allocator())) |views| {
            TaskStore.freeTaskViews(failing.allocator(), views);
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
        var failing_ip = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        if (store.snapshotOwnInProgress(failing_ip.allocator())) |views| {
            TaskStore.freeTaskViews(failing_ip.allocator(), views);
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
}

fn writeMirrorFixture(path: []const u8, bytes: []const u8) !void {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    const f = pfs.fopen(z.ptr, "wb") orelse return error.TestWriteFailed;
    defer _ = std.c.fclose(f);
    if (std.c.fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) return error.TestWriteFailed;
}

test "TaskStore: claim_seq 经镜像往返并跨进程递增;旧镜像缺字段可读,非进行中带序号判损坏" {
    const test_fs = @import("../util/fs.zig");
    var dbuf: [256]u8 = undefined;
    const dir_path = test_fs.testing.uniqueDir(&dbuf, "cc-zig-taskstore-claimseq");
    try test_fs.mkdirParents(dir_path);
    defer test_fs.testing.rmrfBestEffort(dir_path);
    var pbuf: [192]u8 = undefined;
    const mirror = try std.fmt.bufPrint(&pbuf, "{s}/tasks.json", .{dir_path});

    {
        var writer = TaskStore.init(testing.allocator);
        defer writer.deinit();
        try writer.setMirror(mirror);
        _ = try writer.create("first", "d", null);
        _ = try writer.create("second", "d", null);
        // 另一个进程(同一镜像)在 writer 认领**之前**就读过镜像:它内存里没有这次认领。
        var other = TaskStore.init(testing.allocator);
        defer other.deinit();
        try other.setMirror(mirror);
        try other.loadFromMirror();

        try writer.setClaimer("writer-session");
        try writer.updateStatus("1", .in_progress);
        const seq = writer.get("1").?.claim_seq;
        try testing.expect(seq != 0);

        // other 后认领的任务序号必须更大:序号在事务内重放磁盘之后才分配,陈旧的内存副本
        // 会算出与 writer 相同的序号。
        try other.updateStatus("2", .in_progress);
        try testing.expect(other.get("2").?.claim_seq > seq);
        try testing.expectEqual(seq, other.get("1").?.claim_seq);
        try testing.expectEqualStrings("writer-session", other.get("1").?.claimed_by.?);
        try testing.expectEqual(writer.get("1").?.claimed_at_ms, other.get("1").?.claimed_at_ms);
        try writer.loadFromMirror();
        try testing.expectEqualStrings("2", writer.latestInProgress().?.id);
    }

    try writeMirrorFixture(mirror, "[{\"id\":\"1\",\"subject\":\"s\",\"description\":\"d\",\"status\":\"in_progress\"}]");
    {
        var legacy = TaskStore.init(testing.allocator);
        defer legacy.deinit();
        try legacy.setMirror(mirror);
        try legacy.loadFromMirror();
        try testing.expectEqual(@as(u64, 0), legacy.get("1").?.claim_seq);
        try testing.expectEqualStrings("1", legacy.latestInProgress().?.id);
    }

    // 序号到了镜像能读回的上限(i64 最大值)就停在那里,新认领与之并列(按清单位置排),
    // 文件仍然读得回来。
    try writeMirrorFixture(mirror, "[{\"id\":\"1\",\"subject\":\"s\",\"description\":\"d\",\"status\":\"in_progress\",\"claim_seq\":9223372036854775807},{\"id\":\"2\",\"subject\":\"s\",\"description\":\"d\"}]");
    {
        var saturated = TaskStore.init(testing.allocator);
        defer saturated.deinit();
        try saturated.setMirror(mirror);
        try saturated.loadFromMirror();
        try saturated.updateStatus("2", .in_progress);
        try testing.expectEqual(@as(u64, std.math.maxInt(i64)), saturated.get("2").?.claim_seq);
        var reread = TaskStore.init(testing.allocator);
        defer reread.deinit();
        try reread.setMirror(mirror);
        try reread.loadFromMirror();
        try testing.expectEqualStrings("2", reread.latestInProgress().?.id);
    }

    for ([_][]const u8{
        "[{\"id\":\"1\",\"subject\":\"s\",\"description\":\"d\",\"status\":\"pending\",\"claim_seq\":5}]",
        "[{\"id\":\"1\",\"subject\":\"s\",\"description\":\"d\",\"status\":\"in_progress\",\"claim_seq\":-1}]",
        "[{\"id\":\"1\",\"subject\":\"s\",\"description\":\"d\",\"status\":\"completed\",\"claimed_by\":\"x\"}]",
        "[{\"id\":\"1\",\"subject\":\"s\",\"description\":\"d\",\"status\":\"in_progress\",\"claimed_by\":7}]",
        "[{\"id\":\"1\",\"subject\":\"s\",\"description\":\"d\",\"status\":\"in_progress\",\"claimed_at_ms\":5}]",
        "[{\"id\":\"1\",\"subject\":\"s\",\"description\":\"d\",\"status\":\"in_progress\",\"claimed_by\":\"x\",\"claimed_at_ms\":-5}]",
    }) |bad| {
        try writeMirrorFixture(mirror, bad);
        var corrupt = TaskStore.init(testing.allocator);
        defer corrupt.deinit();
        try corrupt.setMirror(mirror);
        try testing.expectError(error.MirrorCorrupt, corrupt.loadFromMirror());
    }
}

test "TaskStore: mirror 开启时 updateStatus(t.id) 不悬垂(reload 释放旧 task)" {
    // 回归(TTY T25/T28 ◻ 根因):mirror reload 会整体替换并释放 task 对象。把 create
    // 返回的 t.id 直接传回 updateStatus 时,id 在调用内部 reload 后指向已释放内存 →
    // 查找失配 → TaskNotFound 被调用方吞掉,状态静默停在 pending。修复:入口先拷贝 id。
    const test_fs = @import("../util/fs.zig");
    var dbuf: [256]u8 = undefined;
    const dir_path = @import("../util/fs.zig").testing.uniqueDir(&dbuf, "cc-zig-taskstore-test");
    try test_fs.mkdirParents(dir_path);
    defer test_fs.testing.rmrfBestEffort(dir_path);
    var pbuf: [192]u8 = undefined;
    const mirror = try std.fmt.bufPrint(&pbuf, "{s}/tasks.json", .{dir_path});

    var store = TaskStore.init(testing.allocator);
    defer store.deinit();
    try store.setMirror(mirror);

    const t = try store.create("answered q1", "test", "answered q1");
    try store.updateStatus(t.id, .completed); // t.id 会在本调用的 reload 中被释放
    const cur = store.get("1") orelse return error.TaskNotFound;
    try testing.expect(cur.status == .completed);
    try testing.expect(cur.completed_ms != 0);

    // update/addBlocks/addBlockedBy 同一入口约定:store 内 id 传回不悬垂。
    const cur2 = store.get("1").?;
    try store.update(cur2.id, .{ .subject = try testing.allocator.dupe(u8, "S2") });
    try testing.expectEqualStrings("S2", store.get("1").?.subject);
    const cur3 = store.get("1").?;
    try store.addBlocks(cur3.id, &.{"9"});
    try testing.expect(store.get("1").?.blocks.items.len == 1);
    const cur4 = store.get("1").?;
    try store.addBlockedBy(cur4.id, &.{"8"});
    try testing.expect(store.get("1").?.blocked_by.items.len == 1);
}

test "TaskStore: mirror 临时文件名相邻调用不重名(EXCL 创建不靠时钟分辨率)" {
    // 先连调、后比较:循环体只放调用本身,相邻两次才会落进同一个时钟刻度(Debug 下一次调用
    // 就近 1 µs,边调边查重会把读数错开)。只拼 nowNs() 的名字在 macOS(1 µs 一跳)上相邻调用
    // 大半同名,同名的第二个写入方会 MirrorOpenFailed。
    var slots: [256][128]u8 = undefined;
    var names: [slots.len][:0]const u8 = undefined;
    for (&slots, &names) |*slot, *name| name.* = try mirrorTmpPath(slot, "/mirror/tasks.json");
    for (names, 0..) |name, i| {
        try testing.expect(std.mem.startsWith(u8, name, "/mirror/tasks.json.tmp."));
        for (names[i + 1 ..]) |later| try testing.expect(!std.mem.eql(u8, name, later));
    }
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
