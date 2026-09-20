//! Bash 后台作业注册表。
//!
//! 目的：让 Bash tool 的 `run_in_background:true` 能 fork 一个进程并立刻返回 job_id，
//! 后续用 BashOutput / KillShell 子工具轮询/终止。
//!
//! 设计：
//! - **stdout/stderr 全落盘**：/tmp/metacodes-jobs/<uid>/<job_id>.{out,err}
//!   子进程打开这两个文件做 stdout/stderr，父端不再 pipe 读。
//! - **job_id**：12-char hex（类似 log.RequestId）
//! - **状态机**：running → exited | killed | failed
//!   状态由 waitpid 决定——register 后的 reap 靠 `poll()` 每次查询
//! - **lifecycle**：App 退出时 killpg 所有 running job（防孤儿）
//! - **spool retention**：落盘文件由 registry 拥有（issue #37）。`.synchronous`
//!   job 的输出一旦渲染进 tool result 就立刻 unlink；`.background` job 的输出
//!   留到 registry teardown——`BashOutput` 在此之前的任何一轮都可能来读它。
//!   两者都不会活过 `deinit`，命令输出因此不再无限期留在 OS 临时目录里。
//!
//! 简化：
//! - 一期单进程单 registry；不跨 session 恢复
//! - 不持久化；App 重启丢所有 job

const std = @import("std");
const sync = @import("platform").sync;
const process = @import("platform").process;
const pfs = @import("platform").fs;
const rng = @import("platform").rng;
const log = @import("../util/log.zig");
const util_fs = @import("../util/fs.zig");
const util_time = @import("../util/time.zig");
const utf8 = @import("../util/utf8.zig");
const ppaths = @import("platform").paths;
const shell_mod = @import("shell.zig");
const SessionId = @import("session_id.zig").SessionId;

pub const JobStatus = enum { running, exited, killed, failed };

/// Who is still allowed to read this job's spool files.
///
/// The distinction is the whole cleanup contract: a synchronous Bash call
/// owns its spool privately and is done with it the moment the result has
/// been rendered, while a backgrounded job's spool is the only place its
/// output lives and `BashOutput` may ask for it at any later turn.
pub const Retention = enum {
    /// Reachable by job id: keep the files until registry teardown.
    background,
    /// Private to one synchronous call: releasable as soon as its result has
    /// been rendered.
    synchronous,
};

pub const JobEntry = struct {
    id: [12]u8,
    /// 进程句柄（POSIX=pid，Windows=HANDLE）。走可移植 platform/process。
    proc: process.ProcHandle,
    started_ms: util_time.Millis,
    stdout_path: []const u8, // owned
    stderr_path: []const u8, // owned
    command_preview: []const u8, // owned, 前 N 字符便于 UI 列表
    /// Exit ownership is the spawning agent identity; main/subagent jobs must
    /// never cross conversation boundaries (2026-09-19 event-channel hazard).
    owner: SessionId = SessionId.single,
    /// These flags make announcement delivery at-most-once and suppress stale
    /// exits already observed through BashOutput/KillShell.
    notify_on_exit: bool = false,
    exit_announced: bool = false,
    exit_observed: bool = false,
    ended_ms: ?util_time.Millis = null,
    status: JobStatus = .running,
    exit_code: ?i32 = null,
    retention: Retention = .background,
    /// BashOutput's implicit read positions. These are registry state rather
    /// than fields on a caller snapshot so repeated polls resume where the
    /// previous result stopped.
    stdout_read_offset: u64 = 0,
    stderr_read_offset: u64 = 0,
    /// Set once the spool files have been unlinked. The path strings stay
    /// valid (they are freed at teardown) so an outstanding value snapshot
    /// never dangles; only the directory entries are gone.
    spool_released: bool = false,

    pub fn idSlice(self: *const JobEntry) []const u8 {
        return self.id[0..];
    }
};

/// Metadata-only exit record: child output and spool paths never cross into
/// the user-role notification, avoiding prompt-injection elevation.
pub const JobExitEvent = struct {
    id: [12]u8,
    status: JobStatus,
    exit_code: ?i32,
    started_ms: util_time.Millis,
    ended_ms: ?util_time.Millis,
    command_preview: []u8,
    stdout_unread: u64,
    stderr_unread: u64,

    pub fn deinit(self: *JobExitEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.command_preview);
        self.command_preview = &.{};
    }
};

pub fn freeJobExitEvents(allocator: std.mem.Allocator, events: []JobExitEvent) void {
    for (events) |*event| event.deinit(allocator);
    allocator.free(events);
}

pub const JobRegistry = struct {
    allocator: std.mem.Allocator,
    jobs: std.ArrayList(JobEntry),
    /// id → index into jobs，O(1) 查询。
    /// 关键：key 是 [12]u8 **值**（不是 slice），因为 ArrayList grow 会 realloc 底层 buffer，
    /// 任何指向 jobs[i].id 的 slice 都会悬挂。值语义完全规避这个问题。
    index: std.AutoHashMap([12]u8, usize),
    base_dir: []const u8, // owned，/tmp/metacodes-jobs/<uid>
    /// 线程安全锁:并发工具线程(executeSlots 并发批 + stream_prefetch 边流边执行的只读 Bash/
    /// BashOutput)会并发 spawnBackground(append+put)/get/reapExited/kill → 无锁则 ArrayList/HashMap
    /// 数据竞争 + 堆损坏(Linus HIGH-1)。全仓惯例 std.c.pthread_*(裁剪 std 无 Thread.Mutex)。
    mu: sync.Mutex = .{},

    fn lock(self: *JobRegistry) void {
        _ = self.mu.lock();
    }
    fn unlock(self: *JobRegistry) void {
        _ = self.mu.unlock();
    }

    pub fn init(allocator: std.mem.Allocator) !JobRegistry {
        const uid = ppaths.uid();
        // 可移植临时目录(POSIX TMPDIR|/tmp / Windows TEMP|TMP)——不再硬编码 /tmp(windows 无)。
        const base = try std.fmt.allocPrint(allocator, "{s}/metacodes-jobs/{d}", .{ ppaths.tempDir(), uid });
        errdefer allocator.free(base);
        try util_fs.mkdirParents(base);
        // POSIX 收紧目录权限 0700(bg job stdout/stderr 落盘,防他用户偷读);Windows 无 POSIX
        // mode 概念(ACL 走 TEMP 默认的每用户隔离),跳过。
        if (@import("builtin").os.tag != .windows) {
            var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
            @memcpy(zbuf[0..base.len], base);
            zbuf[base.len] = 0;
            _ = std.c.chmod(@ptrCast(&zbuf), 0o700);
        }

        return .{
            .allocator = allocator,
            .jobs = .empty,
            .index = std.AutoHashMap([12]u8, usize).init(allocator),
            .base_dir = base,
        };
    }

    pub fn deinit(self: *JobRegistry) void {
        // 杀所有 running job 并 reap（防孤儿进程）。可移植:killJob(TERM→等→KILL)+reapBlocking(收尸)。
        for (self.jobs.items) |*j| {
            if (j.status == .running) {
                process.killJob(j.proc);
                process.reapBlocking(j.proc);
            }
        }
        for (self.jobs.items) |*j| {
            // The registry owns these files. Freeing the path strings while
            // leaving the files behind is what let every command's stdout and
            // stderr accumulate in the OS temp directory indefinitely
            // (issue #37). Every writer has been reaped above, so nothing can
            // still be appending to them.
            unlinkSpool(j);
            self.allocator.free(j.stdout_path);
            self.allocator.free(j.stderr_path);
            self.allocator.free(j.command_preview);
        }
        self.index.deinit();
        self.jobs.deinit(self.allocator);
        self.allocator.free(self.base_dir);
    }

    /// Drop a completed synchronous job's spool now that its output has been
    /// rendered into a tool result. Idempotent, and deliberately a no-op for a
    /// job that is still running or that a consumer can still reach by id —
    /// the retention boundary is what keeps `BashOutput` working.
    pub fn releaseSpool(self: *JobRegistry, id: []const u8) void {
        self.lock();
        defer self.unlock();
        const entry = self.getPtrLocked(id) orelse return;
        if (entry.retention != .synchronous or entry.status == .running) return;
        unlinkSpool(entry);
    }

    /// Promote an auto-backgrounded job: its id has just been handed to the
    /// model, so its spool must survive until teardown.
    pub fn promoteToBackground(self: *JobRegistry, id: []const u8) void {
        self.lock();
        defer self.unlock();
        const entry = self.getPtrLocked(id) orelse return;
        entry.retention = .background;
        entry.notify_on_exit = true;
    }

    /// 生成新 job id：12 hex = 6 byte，走可移植熵源 `platform/rng.zig`
    /// （POSIX=/dev/urandom，Windows=RtlGenRandom）。失败 fatal：进程启不了 bg job 比 id 碰撞强，
    /// JobRegistry 使用方已有兜底（spawnBackground 失败回退同步执行）。
    fn genId() error{RandomFailed}![12]u8 {
        var raw: [6]u8 = undefined;
        if (!rng.randomBytes(&raw)) {
            log.err("job", "randomBytes failed (entropy source unavailable)", .{});
            return error.RandomFailed;
        }
        var id: [12]u8 = undefined;
        _ = std.fmt.bufPrint(&id, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ raw[0], raw[1], raw[2], raw[3], raw[4], raw[5] }) catch unreachable;
        return id;
    }

    /// spawn 一个子进程跑 `/bin/sh -c command`，stdout/stderr 重定向到落盘文件。
    /// 立刻返回 job_id，不等待进程结束。
    /// cwd 非 null → 子进程 chdir(borrow:spawn 时消费,不存 JobEntry——生命周期不匹配)。
    pub fn spawnBackground(self: *JobRegistry, command: []const u8, cwd: ?[]const u8) !JobEntry {
        return self.spawnBackgroundOwned(command, cwd, SessionId.single);
    }

    pub fn spawnBackgroundOwned(self: *JobRegistry, command: []const u8, cwd: ?[]const u8, owner: SessionId) !JobEntry {
        return self.spawn(command, cwd, .background, owner, true);
    }

    /// Same spawn, for output that only one synchronous call will ever read.
    /// `runAutoBackgroundable` starts here and promotes the job if it later
    /// hands the id to the model.
    pub fn spawnSynchronous(self: *JobRegistry, command: []const u8, cwd: ?[]const u8) !JobEntry {
        return self.spawnSynchronousOwned(command, cwd, SessionId.single);
    }

    pub fn spawnSynchronousOwned(self: *JobRegistry, command: []const u8, cwd: ?[]const u8, owner: SessionId) !JobEntry {
        return self.spawn(command, cwd, .synchronous, owner, false);
    }

    fn spawn(
        self: *JobRegistry,
        command: []const u8,
        cwd: ?[]const u8,
        retention: Retention,
        owner: SessionId,
        notify_on_exit: bool,
    ) !JobEntry {
        const id = try genId();

        const stdout_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.out", .{ self.base_dir, id[0..] });
        errdefer self.allocator.free(stdout_path);
        const stderr_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.err", .{ self.base_dir, id[0..] });
        errdefer self.allocator.free(stderr_path);

        // 预创建空文件（0600）让 reader 能立刻打开。
        // 这两条 errdefer 是 issue #37 的另一半:spawn 在文件创建之后失败
        // (第二个 open、shell wrap OOM、spawnToFiles、registerEntry) 时,
        // 只释放路径字符串会把两个空文件永远留在临时目录里。
        const out_fd = createFile(stdout_path) orelse return error.OpenFailed;
        errdefer unlinkPath(stdout_path);
        defer _ = pfs.close(out_fd);
        const err_fd = createFile(stderr_path) orelse return error.OpenFailed;
        errdefer unlinkPath(stderr_path);
        defer _ = pfs.close(err_fd);

        // 走可移植 platform/process.spawnToFiles(POSIX fork+dup2 / Windows CreateProcessW NO_WINDOW
        // + _get_osfhandle 把落盘 fd 转 HANDLE)。可移植 shell(复刻 codex):POSIX /bin/sh -c;
        // Windows 原生 PowerShell/cmd,零 git-bash。wrapCommand:PowerShell 前置 UTF-8 输出编码。
        const shell = shell_mod.detectDefault();
        const cmd_z = try shell_mod.wrapCommand(self.allocator, shell, command);
        defer self.allocator.free(cmd_z);
        var argv: [6]?[*:0]const u8 = undefined;
        shell_mod.deriveExecArgs(shell, cmd_z.ptr, &argv);
        const proc = process.spawnToFiles(argv[0..], out_fd, err_fd, cwd) catch return error.SpawnFailed;
        // From this point until registerEntry succeeds, the child has no owner
        // in jobs[]. OOM while allocating the preview/index must not leak a
        // live background process.
        errdefer {
            process.killJob(proc);
            process.reapBlocking(proc);
        }

        const started_ms: util_time.Millis = util_time.nowMs();

        const preview_slice = utf8.pagePrefix(command, 120);
        const repaired_preview = try utf8.repairInvalidUtf8(self.allocator, preview_slice);
        defer self.allocator.free(repaired_preview);
        const preview = try self.allocator.dupe(u8, repaired_preview);
        errdefer self.allocator.free(preview);

        const entry = JobEntry{
            .id = id,
            .proc = proc,
            .started_ms = started_ms,
            .stdout_path = stdout_path,
            .stderr_path = stderr_path,
            .command_preview = preview,
            .owner = owner,
            .notify_on_exit = notify_on_exit,
            .status = .running,
            .retention = retention,
        };
        try self.registerEntry(entry);
        log.info("job", "bg spawn id={s} cmd={s}", .{ id[0..], preview });
        return entry; // 值拷贝(非指针),caller 用快照安全
    }

    /// Register an already-owned entry through the same append/index mutation
    /// used by real background jobs. Keeping this as one operation makes the
    /// ArrayList-reallocation invariant directly testable without spawning a
    /// hundred OS processes merely to exercise a value-keyed map.
    fn registerEntry(self: *JobRegistry, entry: JobEntry) !void {
        self.lock();
        defer self.unlock();
        // Never let a random-ID collision overwrite the index entry for a
        // live job. The caller still owns the child until registration
        // succeeds and its errdefer kills/reaps it on this error.
        if (self.index.contains(entry.id)) return error.JobIdCollision;
        self.jobs.append(self.allocator, entry) catch |e| {
            return e;
        };
        errdefer _ = self.jobs.pop();
        const new_idx = self.jobs.items.len - 1;
        // key 是 [12]u8 值拷贝，不依赖 jobs buffer 生命周期
        try self.index.put(entry.id, new_idx);
    }

    /// 当前 running 状态的 job 数(statusline 显示用)。
    pub fn runningCount(self: *JobRegistry) usize {
        self.lock();
        defer self.unlock();
        var n: usize = 0;
        for (self.jobs.items) |*j| {
            if (j.status == .running) n += 1;
        }
        return n;
    }

    pub fn runningCountForOwner(self: *JobRegistry, owner: SessionId) usize {
        self.lock();
        defer self.unlock();
        var n: usize = 0;
        for (self.jobs.items) |*j| {
            if (j.status == .running and std.mem.eql(u8, j.owner.asSlice(), owner.asSlice())) n += 1;
        }
        return n;
    }

    /// 非阻塞 reap：对所有 running job waitpid(WNOHANG)，把已退出的状态更新。
    pub fn reapExited(self: *JobRegistry) void {
        self.lock();
        defer self.unlock();
        self.reapExitedLocked();
    }

    /// 持锁内部版(kill 复用,避免自锁死锁)。
    fn reapExitedLocked(self: *JobRegistry) void {
        for (self.jobs.items) |*j| {
            if (j.status != .running) continue;
            switch (process.reapNonblock(j.proc)) { // 可移植:waitpid(WNOHANG) / WaitForSingleObject(0)
                .running => {},
                .exited => |code| {
                    j.exit_code = code;
                    j.status = if (code < 0) .killed else .exited; // 负=被信号杀(posixExitCode)
                    j.ended_ms = util_time.nowMs();
                    log.info("job", "bg exit id={s} code={d} status={s}", .{ j.id[0..], code, @tagName(j.status) });
                },
            }
        }
    }

    /// 按 id 查；命中返回 **值快照**(JobEntry 拷贝,caller 仅读)。O(1)。
    /// 返回值而非指针:并发 append 会 realloc jobs buffer 让内部指针悬挂(Linus HIGH-1)。
    /// job 生命周期内 append-only(退出只改 status,不移除),故快照里的 owned slice(path/preview)
    /// 在 caller 读取期间保持有效(直到 deinit)。id slice 长度必须正好 12;否则返 null。
    pub fn get(self: *JobRegistry, id: []const u8) ?JobEntry {
        self.lock();
        defer self.unlock();
        return if (self.getPtrLocked(id)) |p| p.* else null;
    }

    pub fn getForOwner(self: *JobRegistry, id: []const u8, owner: SessionId) ?JobEntry {
        self.lock();
        defer self.unlock();
        const entry = self.getPtrLocked(id) orelse return null;
        if (!std.mem.eql(u8, entry.owner.asSlice(), owner.asSlice())) return null;
        return entry.*;
    }

    /// Terminate a job only when it belongs to `owner`.  Ownership is checked
    /// while the registry lock is held, then the existing blocking kill path
    /// performs process signalling outside the lock.
    pub fn killForOwner(self: *JobRegistry, id: []const u8, owner: SessionId) !void {
        self.lock();
        const entry = self.getPtrLocked(id) orelse {
            self.unlock();
            return error.JobNotFound;
        };
        if (!std.mem.eql(u8, entry.owner.asSlice(), owner.asSlice())) {
            self.unlock();
            return error.JobNotFound;
        }
        self.unlock();
        return self.kill(id);
    }

    /// Kill all running jobs belonging to one session.  Pick one id at a time
    /// under the lock, then perform the blocking kill outside it. This avoids
    /// an allocation-sized snapshot (and the silent partial cleanup an OOM
    /// snapshot would cause) while remaining safe when another caller kills a
    /// job concurrently.
    pub fn killAllForOwner(self: *JobRegistry, owner: SessionId) usize {
        var killed: usize = 0;
        while (true) {
            var id: ?[12]u8 = null;
            self.lock();
            for (self.jobs.items) |j| {
                if (j.status == .running and std.mem.eql(u8, j.owner.asSlice(), owner.asSlice())) {
                    id = j.id;
                    break;
                }
            }
            self.unlock();
            const selected = id orelse break;
            self.kill(selected[0..]) catch continue;
            killed += 1;
        }
        return killed;
    }

    /// Advance BashOutput's remembered cursors under the registry mutex.
    /// `null` leaves that channel unchanged; the value is the next offset
    /// reported by a successful read, including a truncated read.
    pub fn updateReadCursors(self: *JobRegistry, id: []const u8, stdout_next: ?u64, stderr_next: ?u64) void {
        self.lock();
        defer self.unlock();
        const entry = self.getPtrLocked(id) orelse return;
        if (stdout_next) |next| entry.stdout_read_offset = next;
        if (stderr_next) |next| entry.stderr_read_offset = next;
    }

    pub fn markExitObserved(self: *JobRegistry, id: []const u8) void {
        self.lock();
        defer self.unlock();
        if (self.getPtrLocked(id)) |entry| entry.exit_observed = true;
    }

    pub fn hasPendingNotifyJobs(self: *JobRegistry, owner: SessionId) bool {
        self.lock();
        defer self.unlock();
        self.reapExitedLocked();
        for (self.jobs.items) |entry| {
            if (entry.notify_on_exit and entry.status == .running and std.mem.eql(u8, &entry.owner.bytes, &owner.bytes)) return true;
        }
        return false;
    }

    /// Value snapshot for the in-core wait spinner: how many notify-eligible jobs
    /// of this owner are still running and the first one's id/preview. Taken under
    /// the lock so no pointer into `jobs.items` escapes (2026-09-19 wait design).
    pub const PendingNotifySummary = struct {
        count: u32 = 0,
        first_id: [12]u8 = .{'0'} ** 12,
        first_preview: [40]u8 = undefined,
        first_preview_len: u8 = 0,

        pub fn preview(self: *const PendingNotifySummary) []const u8 {
            return self.first_preview[0..self.first_preview_len];
        }
    };

    pub fn pendingNotifySummary(self: *JobRegistry, owner: SessionId) PendingNotifySummary {
        self.lock();
        defer self.unlock();
        self.reapExitedLocked();
        var out: PendingNotifySummary = .{};
        for (self.jobs.items) |entry| {
            if (!entry.notify_on_exit or entry.status != .running) continue;
            if (!std.mem.eql(u8, &entry.owner.bytes, &owner.bytes)) continue;
            if (out.count == 0) {
                out.first_id = entry.id;
                var n: usize = @min(entry.command_preview.len, out.first_preview.len);
                // 不切坏 UTF-8:回退到字符边界(continuation byte 0b10xxxxxx)。
                while (n > 0 and n < entry.command_preview.len and (entry.command_preview[n] & 0b1100_0000) == 0b1000_0000) : (n -= 1) {}
                @memcpy(out.first_preview[0..n], entry.command_preview[0..n]);
                out.first_preview_len = @intCast(n);
            }
            out.count += 1;
        }
        return out;
    }

    pub fn takeUnannouncedExits(self: *JobRegistry, owner: SessionId, allocator: std.mem.Allocator) ![]JobExitEvent {
        self.lock();
        defer self.unlock();
        self.reapExitedLocked();
        var events = std.ArrayList(JobExitEvent).empty;
        errdefer {
            for (events.items) |*event| event.deinit(allocator);
            events.deinit(allocator);
        }
        for (self.jobs.items) |*entry| {
            if (!entry.notify_on_exit or entry.status == .running or entry.exit_announced or entry.exit_observed) continue;
            if (!std.mem.eql(u8, &entry.owner.bytes, &owner.bytes)) continue;
            const command_preview = try allocator.dupe(u8, entry.command_preview);
            errdefer allocator.free(command_preview);
            const stdout_size = spoolFileSize(entry.stdout_path) catch 0;
            const stderr_size = spoolFileSize(entry.stderr_path) catch 0;
            try events.append(allocator, .{
                .id = entry.id,
                .status = entry.status,
                .exit_code = if (entry.status == .exited) entry.exit_code else null,
                .started_ms = entry.started_ms,
                .ended_ms = entry.ended_ms,
                .command_preview = command_preview,
                .stdout_unread = stdout_size -| entry.stdout_read_offset,
                .stderr_unread = stderr_size -| entry.stderr_read_offset,
            });
        }
        const owned = try events.toOwnedSlice(allocator);
        // Commit the at-most-once markers only after the complete owned slice
        // exists. An OOM must leave every exit retryable rather than losing the
        // earlier entries collected before the failing append.
        for (self.jobs.items) |*entry| {
            if (entry.notify_on_exit and entry.status != .running and !entry.exit_announced and !entry.exit_observed and
                std.mem.eql(u8, &entry.owner.bytes, &owner.bytes))
                entry.exit_announced = true;
        }
        return owned;
    }

    /// 持锁内部版:返回内部指针供 kill 就地改 status/exit_code。**调用方必须持锁**且不得
    /// 让指针逃逸出临界区(realloc 会作废它)。
    fn getPtrLocked(self: *JobRegistry, id: []const u8) ?*JobEntry {
        if (id.len != 12) return null;
        var key: [12]u8 = undefined;
        @memcpy(&key, id[0..12]);
        const idx = self.index.get(key) orelse return null;
        return &self.jobs.items[idx];
    }

    /// killGroup：向 pgid 发 SIGTERM → 0.5s → SIGKILL。
    pub fn kill(self: *JobRegistry, id: []const u8) !void {
        // 读 proc 句柄快照(锁内),kill+reap 在锁外(不让 blocking 收尸钉住锁)。可移植:
        // process.killJob(TERM→200ms→WNOHANG→KILL)+ reapBlocking(收尸)。**不让数据结构生命周期
        // 绑架 syscall 正确性**:proc 快照保证即便 entry 状态变化仍能正确 kill/reap。
        var proc: process.ProcHandle = undefined;
        {
            self.lock();
            const jp = self.getPtrLocked(id) orelse {
                self.unlock();
                return error.JobNotFound;
            };
            if (jp.status != .running) {
                self.unlock();
                return; // 已结束，幂等返回
            }
            proc = jp.proc;
            self.unlock();
        }
        process.killJob(proc); // TERM→等→KILL（锁外）
        process.reapBlocking(proc); // 收尸（锁外，防僵尸）
        self.lock();
        if (self.getPtrLocked(id)) |jp| {
            if (jp.status == .running) {
                jp.status = .killed;
                jp.exit_code = -9; // SIGKILL 语义
                jp.ended_ms = util_time.nowMs();
            }
        }
        self.unlock();
    }

    pub fn activeCount(self: *JobRegistry) usize {
        self.lock();
        defer self.unlock();
        var n: usize = 0;
        for (self.jobs.items) |j| if (j.status == .running) {
            n += 1;
        };
        return n;
    }
};

/// Unlink one entry's spool files and record that it happened. Failures are
/// deliberately silent: a missing file is the desired end state, and a
/// cleanup error must never turn into a failed Bash result.
fn unlinkSpool(entry: *JobEntry) void {
    if (entry.spool_released) return;
    entry.spool_released = true;
    unlinkPath(entry.stdout_path);
    unlinkPath(entry.stderr_path);
}

fn unlinkPath(path: []const u8) void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    pfs.unlinkPath(@ptrCast(&buf)) catch {};
}

fn createFile(path: []const u8) ?pfs.Fd {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&buf), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return null;
    return fd;
}

fn spoolFileSize(path: []const u8) !u64 {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&buf), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    const total = pfs.lseek(fd, 0, .end);
    if (total < 0) return error.SeekFailed;
    return @intCast(total);
}

fn exitCode(status: c_int) i32 {
    if ((status & 0x7f) == 0) return @as(i32, @intCast((status >> 8) & 0xff));
    return -@as(i32, @intCast(status & 0x7f));
}

// ============================================================================
// Tests
// ============================================================================

test "spawn and reap echo" {
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();

    const j = try r.spawnBackground("echo hello; sleep 0.05", null);
    try std.testing.expect(j.status == .running);

    // Windows PowerShell cold start is not bounded by the old fixed 200 ms
    // sleep. Poll with a finite deadline so the test verifies behavior without
    // becoming timing-dependent on machine load.
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        util_time.sleepMs(10);
        r.reapExited();
        if (r.get(j.idSlice()).?.status != .running) break;
    }

    const j2 = r.get(j.idSlice()).?;
    try std.testing.expect(j2.status == .exited);
    try std.testing.expect(j2.exit_code.? == 0);

    // Exit code alone is not evidence that the requested shell command ran.
    // In particular, the Windows detached-process path once returned 0 while
    // producing neither output nor side effects.  Verify the redirected file
    // that is the actual JobRegistry/Bash data path.
    const fd = try pfs.openZ(j2.stdout_path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = pfs.close(fd);
    var buf: [64]u8 = undefined;
    const n = try pfs.readZ(fd, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "hello") != null);
}

test "kill running job" {
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();

    const j = try r.spawnBackground("sleep 30", null);
    try std.testing.expect(j.status == .running);
    try r.kill(j.idSlice());
    const j2 = r.get(j.idSlice()).?;
    try std.testing.expect(j2.status == .killed);
}

test "activeCount" {
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();

    const j1 = try r.spawnBackground("sleep 2", null);
    const j2 = try r.spawnBackground("sleep 2", null);
    _ = j1;
    _ = j2;
    try std.testing.expect(r.activeCount() == 2);
    try r.kill(r.jobs.items[0].idSlice());
    try r.kill(r.jobs.items[1].idSlice());
    try std.testing.expect(r.activeCount() == 0);
}

fn spoolExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&buf), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return false;
    _ = pfs.close(fd);
    return true;
}

fn waitUntilExited(r: *JobRegistry, id: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        r.reapExited();
        if ((r.get(id) orelse return error.JobNotFound).status != .running) return;
        util_time.sleepMs(10);
    }
    return error.JobDidNotExit;
}

test "a completed synchronous job's spool is released" {
    // issue #37: with a JobRegistry present, every synchronous Bash execution
    // spools to files from byte zero. Nothing used to remove them, so ordinary
    // use grew the OS temp directory without bound and left every command's
    // output on disk indefinitely.
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();

    const j = try r.spawnSynchronous("echo spooled", null);
    try waitUntilExited(&r, j.idSlice());
    try std.testing.expect(spoolExists(j.stdout_path));
    try std.testing.expect(spoolExists(j.stderr_path));

    r.releaseSpool(j.idSlice());
    try std.testing.expect(!spoolExists(j.stdout_path));
    try std.testing.expect(!spoolExists(j.stderr_path));
    // Idempotent: a second release (error path plus defer) must not fail.
    r.releaseSpool(j.idSlice());
}

test "a running synchronous job keeps its spool" {
    // Releasing while the child is still writing would unlink the file out
    // from under it, which is exactly the failure this guard exists to make
    // impossible on the timeout path.
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();

    const j = try r.spawnSynchronous("sleep 30", null);
    r.releaseSpool(j.idSlice());
    try std.testing.expect(spoolExists(j.stdout_path));
    try r.kill(j.idSlice());
}

test "a backgrounded job keeps its spool until registry teardown" {
    // BashOutput may ask for a backgrounded job's output at any later turn,
    // so the retention boundary is teardown, not completion.
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    var torn_down = false;
    defer if (!torn_down) r.deinit();

    const j = try r.spawnBackground("echo background", null);
    try waitUntilExited(&r, j.idSlice());
    r.releaseSpool(j.idSlice());
    try std.testing.expect(spoolExists(j.stdout_path));
    try std.testing.expect(spoolExists(j.stderr_path));

    // The paths outlive the entry only because this test copies them.
    const stdout_path = try a.dupe(u8, j.stdout_path);
    defer a.free(stdout_path);
    const stderr_path = try a.dupe(u8, j.stderr_path);
    defer a.free(stderr_path);
    r.deinit();
    torn_down = true;
    try std.testing.expect(!spoolExists(stdout_path));
    try std.testing.expect(!spoolExists(stderr_path));
}

test "promotion to background extends a synchronous job's retention" {
    // The auto-background path hands the job id to the model mid-call; from
    // that moment the spool is reachable and must stop being releasable.
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();

    const j = try r.spawnSynchronous("echo promoted", null);
    r.promoteToBackground(j.idSlice());
    try waitUntilExited(&r, j.idSlice());
    r.releaseSpool(j.idSlice());
    try std.testing.expect(spoolExists(j.stdout_path));
    try std.testing.expect(spoolExists(j.stderr_path));
}

test "teardown removes the spool of a job that was still running" {
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    var torn_down = false;
    defer if (!torn_down) r.deinit();

    const j = try r.spawnBackground("sleep 30", null);
    const stdout_path = try a.dupe(u8, j.stdout_path);
    defer a.free(stdout_path);
    try std.testing.expect(spoolExists(stdout_path));
    // deinit kills and reaps first, so nothing is still writing when the
    // directory entry goes away.
    r.deinit();
    torn_down = true;
    try std.testing.expect(!spoolExists(stdout_path));
}

test "get returns correct entry across many registrations" {
    // 不变量：无论 registry append 了多少次（触发 ArrayList grow），
    // 用保存的 id 查回来的 entry 必须和保存时的 id 一致。
    //
    // 这个测试在修复前（key 是指向 jobs[i].id 的 slice）会 crash：
    // ArrayList grow 后老 slice key 悬挂，get 读到错的 index，&jobs.items[idx] 越界。
    // （已亲手把 fix 回退验证过，crash。）
    //
    // 100 次 registration 足以触发 6-7 轮 ArrayList grow（empty → 1 → 2 → 4 → 8 → 16 → 32 → 64 → 128）。
    // spawnBackground 的真实进程/重定向路径由前面的 spawn-and-reap 测试覆盖；本测试只验证
    // registerEntry 的容器不变量，避免 100 个 shell 启动把一个内存安全回归测成 20 秒。
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();

    const N = 100;
    var saved_ids: [N][12]u8 = undefined;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        _ = try std.fmt.bufPrint(&saved_ids[i], "{x:0>12}", .{i});
        const stdout_path = try a.dupe(u8, "synthetic.out");
        errdefer a.free(stdout_path);
        const stderr_path = try a.dupe(u8, "synthetic.err");
        errdefer a.free(stderr_path);
        const preview = try a.dupe(u8, "synthetic registration");
        errdefer a.free(preview);
        try r.registerEntry(.{
            .id = saved_ids[i],
            .proc = undefined, // status=.exited: lifecycle code never observes this handle
            .started_ms = util_time.nowMs(),
            .stdout_path = stdout_path,
            .stderr_path = stderr_path,
            .command_preview = preview,
            .status = .exited,
            .exit_code = 0,
            // These entries name no real files. Marking the spool already
            // released keeps teardown from issuing an unlink for a relative
            // pathname in whatever directory the test happens to run in.
            .spool_released = true,
        });
    }

    // 反向查所有保存的 id，断言内容一致
    i = N;
    while (i > 0) {
        i -= 1;
        const found = r.get(saved_ids[i][0..]) orelse return error.IdLost;
        try std.testing.expectEqualSlices(u8, &saved_ids[i], &found.id);
    }
}

test "JobRegistry owned exit is announced once" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("session_id.zig").gen();
    const j = try r.spawnBackgroundOwned("printf notify", null, owner);
    try waitUntilExited(&r, j.idSlice());
    var events = try r.takeUnannouncedExits(owner, a);
    defer freeJobExitEvents(a, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualSlices(u8, j.idSlice(), &events[0].id);
    try std.testing.expectEqual(@as(u64, 6), events[0].stdout_unread);
    const second = try r.takeUnannouncedExits(owner, a);
    defer freeJobExitEvents(a, second);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}

test "JobRegistry owner and observed exit suppress notification" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("session_id.zig").gen();
    const other = @import("session_id.zig").gen();
    const j = try r.spawnBackgroundOwned("true", null, owner);
    try std.testing.expect(r.hasPendingNotifyJobs(owner));
    try waitUntilExited(&r, j.idSlice());
    try std.testing.expect(!r.hasPendingNotifyJobs(owner));
    const wrong = try r.takeUnannouncedExits(other, a);
    defer freeJobExitEvents(a, wrong);
    try std.testing.expectEqual(@as(usize, 0), wrong.len);
    r.markExitObserved(j.idSlice());
    const observed = try r.takeUnannouncedExits(owner, a);
    defer freeJobExitEvents(a, observed);
    try std.testing.expectEqual(@as(usize, 0), observed.len);
}
