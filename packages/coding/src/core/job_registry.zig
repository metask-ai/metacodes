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
const platform_thread = @import("platform").thread;
const process = @import("platform").process;
const pfs = @import("platform").fs;
const rng = @import("platform").rng;
const log = @import("metacodes-base").util.log;
const util_fs = @import("metacodes-base").util.fs;
const util_time = @import("metacodes-base").util.time;
const utf8 = @import("metacodes-base").util.utf8;
const ppaths = @import("platform").paths;
const shell_mod = @import("metacodes-guard").core.shell;
const SessionId = @import("metacodes-kernel").session_id.SessionId;
const monitor_stream = @import("monitor_stream.zig");

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

/// BashOutput's poll-guard state for one job: how many waiting polls in a row
/// found it still running with only a few new bytes, and when the last of
/// them returned. The registry only stores it; BashOutput owns the policy.
pub const PollStreak = struct {
    low_yield: u8 = 0,
    last_ms: util_time.Millis = 0,
};

pub const JobKind = union(enum) {
    plain,
    monitor: monitor_stream.State,
};

pub const INPUT_STALL_QUIET_MS: u64 = 45_000;
const SWEEP_MAX_WAIT_MS: u64 = 250;
const STOP_WAIT_SLICE_MS: u64 = 10;

pub const Supervision = enum {
    unwatched,
    watchdog,

    fn treeStop(self: Supervision) process.TreeStop {
        return switch (self) {
            .unwatched => .best_effort,
            .watchdog => .required,
        };
    }
};

pub const TermGate = struct {
    reached: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
};

pub var test_term_gate: ?*TermGate = null;

fn holdBeforeTermInTests() void {
    if (!@import("builtin").is_test) return;
    const gate = test_term_gate orelse return;
    gate.reached.store(true, .release);
    while (!gate.released.load(.acquire)) util_time.sleepMs(1);
}

pub const Watchdog = struct {
    limit_ms: u64,
    output_bytes: u64 = 0,
    output_changed_ms: util_time.Millis,
    expired: bool = false,
    kill_at_ms: ?util_time.Millis = null,
    input_notice_sent: bool = false,
};

pub const JobEventKind = union(enum) {
    ended,
    time_limit: u64,
    awaiting_input,
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
    poll_streak: PollStreak = .{},
    /// Set once the spool files have been unlinked. The path strings stay
    /// valid (they are freed at teardown) so an outstanding value snapshot
    /// never dangles; only the directory entries are gone.
    spool_released: bool = false,
    kind: JobKind = .plain,
    watchdog: ?Watchdog = null,
    stop_in_progress: bool = false,
    supervision: Supervision = .unwatched,

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
    kind: JobEventKind = .ended,

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
    sweeper: ?std.Thread = null,
    sweeper_quit: bool = false,
    sweeper_wake: sync.Condition = .{},

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
            _ = pfs.chmod(@ptrCast(&zbuf), 0o700);
        }

        return .{
            .allocator = allocator,
            .jobs = .empty,
            .index = std.AutoHashMap([12]u8, usize).init(allocator),
            .base_dir = base,
        };
    }

    pub fn deinit(self: *JobRegistry) void {
        self.lock();
        self.sweeper_quit = true;
        self.sweeper_wake.signal();
        self.unlock();
        if (self.sweeper) |sweeper| sweeper.join();
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
            switch (j.kind) {
                .plain => {},
                .monitor => |monitor| self.allocator.free(monitor.description),
            }
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

    pub fn armWatchdog(self: *JobRegistry, id: []const u8, limit_ms: u64) error{ JobNotFound, JobUnwatched }!void {
        self.lock();
        defer self.unlock();
        const entry = self.getPtrLocked(id) orelse return error.JobNotFound;
        if (entry.supervision != .watchdog) return error.JobUnwatched;
        if (entry.status != .running) return;
        entry.watchdog = .{ .limit_ms = limit_ms, .output_changed_ms = util_time.nowMs() };
        self.sweeper_wake.signal();
    }

    pub fn spawnBackgroundWatched(self: *JobRegistry, command: []const u8, cwd: ?[]const u8, owner: SessionId, limit_ms: u64) !JobEntry {
        const entry = try self.spawnBackgroundSupervised(command, cwd, owner, .watchdog);
        self.armWatchdog(entry.idSlice(), limit_ms) catch |err| {
            self.kill(entry.idSlice()) catch {};
            return err;
        };
        return self.get(entry.idSlice()) orelse error.JobNotFound;
    }

    pub var fail_sweeper_spawn_in_tests: bool = false;

    fn ensureSweeper(self: *JobRegistry) !void {
        self.lock();
        defer self.unlock();
        if (self.sweeper != null) return;
        if (@import("builtin").is_test and fail_sweeper_spawn_in_tests) return error.SystemResources;
        self.sweeper = try platform_thread.spawn(.waiter, sweepDeadlines, .{self});
    }

    fn wakeSweeper(self: *JobRegistry) void {
        self.lock();
        defer self.unlock();
        if (self.sweeper != null) self.sweeper_wake.signal();
    }

    fn sweepDeadlines(self: *JobRegistry) void {
        var steps: std.ArrayList(ExpiryStep) = .empty;
        defer steps.deinit(self.allocator);
        while (true) {
            self.sweepDue(&steps, util_time);
            self.lock();
            defer self.unlock();
            if (self.sweeper_quit) return;
            if (self.nextExpiryWaitLocked(util_time.nowMs())) |wait_ms| {
                if (wait_ms > 0) _ = self.sweeper_wake.timedWait(&self.mu, wait_ms * std.time.ns_per_ms);
            } else {
                self.sweeper_wake.wait(&self.mu);
            }
            if (self.sweeper_quit) return;
        }
    }

    fn sweepDue(self: *JobRegistry, steps: *std.ArrayList(ExpiryStep), clock: anytype) void {
        steps.clearRetainingCapacity();
        self.claimExpired(null, clock.nowMs(), steps);
        self.sendTerm(steps.items, clock);
        self.killDue(clock.nowMs());
    }

    fn nextExpiryWaitLocked(self: *JobRegistry, now_ms: util_time.Millis) ?u64 {
        var next: ?util_time.Millis = null;
        for (self.jobs.items) |*entry| {
            const due = expiryStepDue(entry) orelse continue;
            next = if (next) |n| @min(n, due) else due;
        }
        const due = next orelse return null;
        if (due <= now_ms) return 0;
        return @min(@as(u64, @intCast(due - now_ms)), SWEEP_MAX_WAIT_MS);
    }

    fn expiryStepDue(entry: *const JobEntry) ?util_time.Millis {
        if (entry.status != .running) return null;
        if (scheduledKill(entry)) |kill_at| return kill_at;
        return expiryDeadline(entry);
    }

    fn expiryDeadline(entry: *const JobEntry) ?util_time.Millis {
        if (entry.status != .running or entry.stop_in_progress or stopClaimed(entry)) return null;
        const limit = timeLimitMs(entry) orelse return null;
        return entry.started_ms + @as(util_time.Millis, @intCast(limit));
    }

    fn timeLimitMs(entry: *const JobEntry) ?u64 {
        if (entry.watchdog) |watchdog| return watchdog.limit_ms;
        return switch (entry.kind) {
            .plain => null,
            .monitor => |*state| state.timeout_ms,
        };
    }

    fn stopClaimed(entry: *const JobEntry) bool {
        if (entry.watchdog) |watchdog| return watchdog.expired;
        return switch (entry.kind) {
            .plain => false,
            .monitor => |*state| state.stop != null,
        };
    }

    fn scheduledKill(entry: *const JobEntry) ?util_time.Millis {
        if (entry.watchdog) |watchdog| return watchdog.kill_at_ms;
        return switch (entry.kind) {
            .plain => null,
            .monitor => |*state| state.kill_at_ms,
        };
    }

    fn killAtSlot(entry: *JobEntry) ?*?util_time.Millis {
        if (entry.watchdog) |*watchdog| return &watchdog.kill_at_ms;
        return switch (entry.kind) {
            .plain => null,
            .monitor => |*state| &state.kill_at_ms,
        };
    }

    fn claimExpiry(entry: *JobEntry) void {
        entry.stop_in_progress = true;
        if (entry.watchdog) |*watchdog| {
            watchdog.expired = true;
            log.info("job", "bg time limit reached id={s}", .{entry.id[0..]});
            return;
        }
        switch (entry.kind) {
            .plain => {},
            .monitor => |*state| {
                state.stop = .expired;
                log.info("job", "monitor timeout reached id={s}", .{entry.id[0..]});
            },
        }
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
        return self.spawn(command, cwd, .background, owner, true, .plain, .unwatched);
    }

    pub fn spawnBackgroundSupervised(self: *JobRegistry, command: []const u8, cwd: ?[]const u8, owner: SessionId, supervision: Supervision) !JobEntry {
        return self.spawn(command, cwd, .background, owner, true, .plain, supervision);
    }

    pub fn spawnMonitorOwned(self: *JobRegistry, command: []const u8, cwd: ?[]const u8, owner: SessionId, description: []const u8, timeout_ms: ?u64) !JobEntry {
        if (timeout_ms != null) try self.ensureSweeper();
        const owned_description = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(owned_description);
        const entry = try self.spawn(command, cwd, .background, owner, true, .{ .monitor = monitor_stream.State.init(owned_description, timeout_ms, util_time.nowMs()) }, .unwatched);
        if (timeout_ms != null) self.wakeSweeper();
        return entry;
    }

    /// Same spawn, for output that only one synchronous call will ever read.
    /// `runAutoBackgroundable` starts here and promotes the job if it later
    /// hands the id to the model.
    pub fn spawnSynchronous(self: *JobRegistry, command: []const u8, cwd: ?[]const u8) !JobEntry {
        return self.spawnSynchronousOwned(command, cwd, SessionId.single);
    }

    pub fn spawnSynchronousOwned(self: *JobRegistry, command: []const u8, cwd: ?[]const u8, owner: SessionId) !JobEntry {
        return self.spawn(command, cwd, .synchronous, owner, false, .plain, .unwatched);
    }

    pub fn spawnSynchronousSupervised(self: *JobRegistry, command: []const u8, cwd: ?[]const u8, owner: SessionId, supervision: Supervision) !JobEntry {
        return self.spawn(command, cwd, .synchronous, owner, false, .plain, supervision);
    }

    fn spawn(
        self: *JobRegistry,
        command: []const u8,
        cwd: ?[]const u8,
        retention: Retention,
        owner: SessionId,
        notify_on_exit: bool,
        kind: JobKind,
        supervision: Supervision,
    ) !JobEntry {
        if (supervision == .watchdog) try self.ensureSweeper();
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
        const proc = process.spawnToFilesStopping(argv[0..], out_fd, err_fd, cwd, true, supervision.treeStop()) catch |e| return switch (e) {
            // 子进程自己交代的失败原样上抛:Bash 据此告诉模型是 cwd 没了还是 shell 起不来,
            // 而不是登记一个 exit 127、双空流的 job 让模型去猜。
            error.ChildChdirFailed, error.ChildExecFailed => e,
            else => error.SpawnFailed,
        };
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
            .kind = kind,
            .supervision = supervision,
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
            if (j.status != .running or j.stop_in_progress) continue;
            switch (process.reapNonblock(j.proc)) { // 可移植:waitpid(WNOHANG) / WaitForSingleObject(0)
                .running => {},
                .exited => |code| {
                    process.releaseExited(j.proc);
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

    /// Kill (and reap) every running job, whatever its owner; their records
    /// and spools stay until `deinit`. Returns how many were killed.
    pub fn killAll(self: *JobRegistry) usize {
        var killed: usize = 0;
        while (true) {
            var id: ?[12]u8 = null;
            self.lock();
            for (self.jobs.items) |j| {
                if (j.status == .running) {
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

    /// Extend the job's poll streak by one for a poll that started at
    /// `started_ms` and returned at `returned_ms`, starting over if that poll
    /// began more than `idle_reset_ms` after the previous one returned (the
    /// gap is the caller's own time, not the poll's wait). Read-modify-write
    /// under the lock, so concurrent polls of one job do not lose updates.
    pub fn extendPollStreak(
        self: *JobRegistry,
        id: []const u8,
        started_ms: util_time.Millis,
        returned_ms: util_time.Millis,
        idle_reset_ms: util_time.Millis,
    ) void {
        self.lock();
        defer self.unlock();
        const entry = self.getPtrLocked(id) orelse return;
        const carried: u8 = if (started_ms - entry.poll_streak.last_ms > idle_reset_ms) 0 else entry.poll_streak.low_yield;
        entry.poll_streak = .{ .low_yield = carried +| 1, .last_ms = returned_ms };
    }

    pub fn resetPollStreak(self: *JobRegistry, id: []const u8) void {
        self.lock();
        defer self.unlock();
        if (self.getPtrLocked(id)) |entry| entry.poll_streak = .{};
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
    /// of this owner are still running or have ended without being announced, and
    /// the first one's id/preview. Taken under the lock so no pointer into
    /// `jobs.items` escapes (2026-09-19 wait design).
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
            if (!entry.notify_on_exit or (entry.status != .running and (entry.exit_announced or entry.exit_observed))) continue;
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
        return self.takeUnannouncedExitsAt(owner, allocator, util_time.nowMs());
    }

    pub fn takeUnannouncedExitsAt(self: *JobRegistry, owner: SessionId, allocator: std.mem.Allocator, now_ms: util_time.Millis) ![]JobExitEvent {
        self.stopExpired(owner, now_ms);
        self.lock();
        defer self.unlock();
        self.reapExitedLocked();
        var events = std.ArrayList(JobExitEvent).empty;
        errdefer {
            for (events.items) |*event| event.deinit(allocator);
            events.deinit(allocator);
        }
        for (self.jobs.items) |*entry| {
            if (entry.kind == .monitor) continue;
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
                .kind = endedKind(entry),
            });
        }
        for (self.jobs.items) |*entry| {
            if (!entry.notify_on_exit or entry.status != .running) continue;
            if (!std.mem.eql(u8, &entry.owner.bytes, &owner.bytes)) continue;
            const watchdog = if (entry.watchdog) |*w| w else continue;
            if (watchdog.input_notice_sent) continue;
            const stdout_size = spoolFileSize(entry.stdout_path) catch 0;
            const stderr_size = spoolFileSize(entry.stderr_path) catch 0;
            if (!awaitsInput(watchdog, entry.stdout_path, entry.stderr_path, stdout_size + stderr_size, now_ms)) continue;
            const command_preview = try allocator.dupe(u8, entry.command_preview);
            errdefer allocator.free(command_preview);
            try events.append(allocator, .{
                .id = entry.id,
                .status = .running,
                .exit_code = null,
                .started_ms = entry.started_ms,
                .ended_ms = null,
                .command_preview = command_preview,
                .stdout_unread = stdout_size -| entry.stdout_read_offset,
                .stderr_unread = stderr_size -| entry.stderr_read_offset,
                .kind = .awaiting_input,
            });
        }
        const owned = try events.toOwnedSlice(allocator);
        for (owned) |event| {
            if (event.kind != .awaiting_input) continue;
            const entry = self.getPtrLocked(event.id[0..]) orelse continue;
            if (entry.watchdog) |*w| w.input_notice_sent = true;
        }
        // Commit the at-most-once markers only after the complete owned slice
        // exists. An OOM must leave every exit retryable rather than losing the
        // earlier entries collected before the failing append.
        for (self.jobs.items) |*entry| {
            if (entry.kind == .plain and entry.notify_on_exit and entry.status != .running and !entry.exit_announced and !entry.exit_observed and
                std.mem.eql(u8, &entry.owner.bytes, &owner.bytes))
                entry.exit_announced = true;
        }
        return owned;
    }

    pub fn takeMonitorEvents(self: *JobRegistry, owner: SessionId, allocator: std.mem.Allocator, now: util_time.Millis) ![]monitor_stream.Notice {
        self.stopExpired(owner, now);
        var flooding = std.ArrayList(ExpiryStep).empty;
        defer flooding.deinit(allocator);
        const notices = try self.collectMonitorNotices(owner, allocator, now, &flooding);
        self.stopWithGrace(flooding.items);
        return notices;
    }

    fn collectMonitorNotices(
        self: *JobRegistry,
        owner: SessionId,
        allocator: std.mem.Allocator,
        now: util_time.Millis,
        flooding: *std.ArrayList(ExpiryStep),
    ) ![]monitor_stream.Notice {
        self.lock();
        defer self.unlock();
        try flooding.ensureUnusedCapacity(allocator, self.jobs.items.len);
        self.reapExitedLocked();
        const Commit = struct { index: usize, state: monitor_stream.State, announce: bool, flooding: bool };
        var commits = std.ArrayList(Commit).empty;
        defer commits.deinit(allocator);
        var notices = std.ArrayList(monitor_stream.Notice).empty;
        errdefer {
            for (notices.items) |*notice| notice.deinit(allocator);
            notices.deinit(allocator);
        }
        for (self.jobs.items, 0..) |*entry, index| {
            const current = switch (entry.kind) {
                .plain => continue,
                .monitor => |state| state,
            };
            if (entry.exit_announced or !std.mem.eql(u8, &entry.owner.bytes, &owner.bytes)) continue;
            const ended = entry.status != .running;
            if (ended and entry.exit_observed) {
                try commits.append(allocator, .{ .index = index, .state = current, .announce = true, .flooding = false });
                continue;
            }
            var next = current;
            const chunk = try readSpoolFrom(allocator, entry.stdout_path, next.stdout_cursor, monitor_stream.READ_MAX_BYTES);
            defer allocator.free(chunk);
            const mode: monitor_stream.Mode = if (ended and chunk.len < monitor_stream.READ_MAX_BYTES) .final else .streaming;
            const batch = try monitor_stream.take(allocator, &next, chunk, mode, now);
            var event_owned = true;
            defer if (event_owned) allocator.free(batch.event);
            next.stdout_cursor += batch.consumed;
            const floods = !ended and !entry.stop_in_progress and next.stop == null and next.overBudgetTooLong(now);
            if (floods) next.stop = .too_much_output;
            const end: ?monitor_stream.End = if (mode == .final) monitorEnd(entry, next) else null;
            if (batch.event.len > 0 or end != null) {
                const description = try allocator.dupe(u8, next.description);
                errdefer allocator.free(description);
                try notices.append(allocator, .{ .id = entry.id, .description = description, .event = batch.event, .end = end });
                event_owned = false;
            }
            try commits.append(allocator, .{ .index = index, .state = next, .announce = end != null, .flooding = floods });
        }
        const owned = try notices.toOwnedSlice(allocator);
        for (commits.items) |commit| {
            const entry = &self.jobs.items[commit.index];
            entry.kind = .{ .monitor = commit.state };
            if (commit.flooding) {
                entry.stop_in_progress = true;
                flooding.appendAssumeCapacity(.{ .id = entry.id, .proc = entry.proc });
            }
            if (commit.announce) entry.exit_announced = true;
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
        return self.stop(id);
    }

    const ExpiryStep = struct { id: [12]u8, proc: process.ProcHandle };

    fn claimExpired(self: *JobRegistry, owner: ?SessionId, now_ms: util_time.Millis, steps: *std.ArrayList(ExpiryStep)) void {
        self.lock();
        defer self.unlock();
        self.reapExitedLocked();
        for (self.jobs.items) |*entry| {
            if (owner) |o| if (!std.mem.eql(u8, &entry.owner.bytes, &o.bytes)) continue;
            const deadline = expiryDeadline(entry) orelse continue;
            if (deadline > now_ms) continue;
            steps.append(self.allocator, .{ .id = entry.id, .proc = entry.proc }) catch break;
            claimExpiry(entry);
        }
    }

    fn sendTerm(self: *JobRegistry, steps: []const ExpiryStep, clock: anytype) void {
        for (steps) |step| {
            holdBeforeTermInTests();
            process.terminate(step.proc);
            const kill_at = clock.nowMs() + @as(util_time.Millis, @intCast(process.KILL_GRACE_MS));
            self.lock();
            defer self.unlock();
            const entry = self.getPtrLocked(step.id[0..]) orelse continue;
            const slot = killAtSlot(entry) orelse continue;
            slot.* = kill_at;
            if (self.sweeper != null) self.sweeper_wake.signal();
        }
    }

    const KILL_BATCH = 32;

    fn killDue(self: *JobRegistry, now_ms: util_time.Millis) void {
        while (true) {
            var batch: [KILL_BATCH]ExpiryStep = undefined;
            var count: usize = 0;
            self.lock();
            for (self.jobs.items) |*entry| {
                if (count == batch.len) break;
                const slot = killAtSlot(entry) orelse continue;
                const kill_at = slot.* orelse continue;
                if (kill_at > now_ms) continue;
                batch[count] = .{ .id = entry.id, .proc = entry.proc };
                count += 1;
                slot.* = null;
            }
            self.unlock();
            self.forceKillAndReap(batch[0..count]);
            if (count < batch.len) return;
        }
    }

    fn killScheduled(self: *JobRegistry, steps: []ExpiryStep) void {
        var count: usize = 0;
        self.lock();
        for (steps) |step| {
            const entry = self.getPtrLocked(step.id[0..]) orelse continue;
            const slot = killAtSlot(entry) orelse continue;
            if (slot.* == null) continue;
            slot.* = null;
            steps[count] = step;
            count += 1;
        }
        self.unlock();
        self.forceKillAndReap(steps[0..count]);
    }

    fn forceKillAndReap(self: *JobRegistry, steps: []const ExpiryStep) void {
        if (steps.len == 0) return;
        for (steps) |step| process.forceKill(step.proc);
        for (steps) |step| process.reapBlocking(step.proc);
        self.lock();
        defer self.unlock();
        for (steps) |step| self.commitStoppedLocked(step.id[0..]);
    }

    fn stopWithGrace(self: *JobRegistry, steps: []ExpiryStep) void {
        if (steps.len == 0) return;
        self.sendTerm(steps, util_time);
        util_time.sleepMs(process.KILL_GRACE_MS);
        self.killScheduled(steps);
    }

    fn stopExpired(self: *JobRegistry, owner: SessionId, now_ms: util_time.Millis) void {
        var steps: std.ArrayList(ExpiryStep) = .empty;
        defer steps.deinit(self.allocator);
        self.claimExpired(owner, now_ms, &steps);
        self.stopWithGrace(steps.items);
    }

    fn commitStoppedLocked(self: *JobRegistry, id: []const u8) void {
        const jp = self.getPtrLocked(id) orelse return;
        jp.stop_in_progress = false;
        if (jp.status != .running) return;
        jp.status = .killed;
        jp.exit_code = -9;
        jp.ended_ms = util_time.nowMs();
    }

    fn stop(self: *JobRegistry, id: []const u8) !void {
        // 读 proc 句柄快照(锁内),kill+reap 在锁外(不让 blocking 收尸钉住锁)。可移植:
        // process.killJob(TERM→200ms→KILL)+ reapBlocking(收尸)。**不让数据结构生命周期
        // 绑架 syscall 正确性**:proc 快照保证即便 entry 状态变化仍能正确 kill/reap。
        var proc: process.ProcHandle = undefined;
        while (true) {
            self.lock();
            const jp = self.getPtrLocked(id) orelse {
                self.unlock();
                return error.JobNotFound;
            };
            if (jp.status != .running) {
                self.unlock();
                return; // 已结束，幂等返回
            }
            if (!jp.stop_in_progress) {
                jp.stop_in_progress = true;
                proc = jp.proc;
                self.unlock();
                break;
            }
            self.unlock();
            util_time.sleepMs(STOP_WAIT_SLICE_MS);
        }
        process.killJob(proc); // TERM→等→KILL（锁外）
        process.reapBlocking(proc); // 收尸（锁外，防僵尸）
        self.lock();
        defer self.unlock();
        self.commitStoppedLocked(id);
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

fn endedKind(entry: *const JobEntry) JobEventKind {
    const watchdog = entry.watchdog orelse return .ended;
    return if (watchdog.expired) .{ .time_limit = watchdog.limit_ms } else .ended;
}

fn awaitsInput(watchdog: *Watchdog, stdout_path: []const u8, stderr_path: []const u8, output_bytes: u64, now_ms: util_time.Millis) bool {
    if (output_bytes != watchdog.output_bytes) {
        watchdog.output_bytes = output_bytes;
        watchdog.output_changed_ms = now_ms;
        return false;
    }
    if (now_ms - watchdog.output_changed_ms < @as(util_time.Millis, @intCast(INPUT_STALL_QUIET_MS))) return false;
    return spoolEndsWithPrompt(stdout_path) or spoolEndsWithPrompt(stderr_path);
}

const PROMPT_TAIL_BYTES = 512;

fn spoolEndsWithPrompt(path: []const u8) bool {
    var buf: [PROMPT_TAIL_BYTES]u8 = undefined;
    const tail = readSpoolTail(path, &buf) catch return false;
    return looksLikeInteractivePrompt(tail);
}

fn readSpoolTail(path: []const u8, buf: *[PROMPT_TAIL_BYTES]u8) ![]const u8 {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&path_buf), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    const total = pfs.lseek(fd, 0, .end);
    if (total < 0) return error.SeekFailed;
    const start = @max(total - PROMPT_TAIL_BYTES, 0);
    if (pfs.lseek(fd, start, .set) < 0) return error.SeekFailed;
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = pfs.read(fd, buf[filled..]);
        if (n <= 0) break;
        filled += @intCast(n);
    }
    return buf[0..filled];
}

const PROMPT_MARKERS = [_][]const u8{
    "(y/n)",
    "[y/n]",
    "(yes/no)",
    "[yes/no]",
    "press enter",
    "press any key",
    "password:",
    "continue?",
};

pub fn looksLikeInteractivePrompt(tail: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, tail, "\r\n");
    const line_start = if (std.mem.findLastAny(u8, trimmed, "\r\n")) |index| index + 1 else 0;
    const line = trimmed[line_start..];
    if (std.mem.trim(u8, line, " \t").len == 0) return false;
    for (PROMPT_MARKERS) |marker| {
        if (std.ascii.findIgnoreCase(line, marker) != null) return true;
    }
    return std.mem.endsWith(u8, line, "? ") or std.mem.endsWith(u8, line, ": ");
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

fn monitorEnd(entry: *const JobEntry, state: monitor_stream.State) monitor_stream.End {
    if (state.stop) |stop| return switch (stop) {
        .expired => .{ .expired = .{ .after_ms = state.timeout_ms orelse 0, .events_delivered = state.events_delivered } },
        .too_much_output => .too_much_output,
    };
    if (entry.status == .exited) {
        const code = entry.exit_code orelse 0;
        return if (code == 0) .stream_ended else .{ .script_failed = code };
    }
    return .killed;
}

fn readSpoolFrom(allocator: std.mem.Allocator, path: []const u8, offset: u64, max: usize) ![]u8 {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&buf), .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return allocator.alloc(u8, 0);
    defer _ = pfs.close(fd);
    if (pfs.lseek(fd, @intCast(offset), .set) < 0) return error.SeekFailed;
    const out = try allocator.alloc(u8, max);
    errdefer allocator.free(out);
    var filled: usize = 0;
    while (filled < max) {
        const n = pfs.read(fd, out[filled..]);
        if (n <= 0) break;
        filled += @intCast(n);
    }
    return allocator.realloc(out, filled);
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

test "poll streak extends, lapses after an idle gap, saturates and resets" {
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const j = try r.spawnBackground("sleep 2", null);
    defer r.kill(j.idSlice()) catch {};
    const id = j.idSlice();
    try std.testing.expectEqual(PollStreak{}, r.get(id).?.poll_streak);
    r.extendPollStreak(id, 900, 1_000, 100);
    // A long wait of its own does not break the streak: the gap is measured
    // from the previous return to this poll's start.
    r.extendPollStreak(id, 1_050, 9_000, 100);
    try std.testing.expectEqual(PollStreak{ .low_yield = 2, .last_ms = 9_000 }, r.get(id).?.poll_streak);
    // Starting more than idle_reset_ms after the last return starts over.
    r.extendPollStreak(id, 9_101, 9_200, 100);
    try std.testing.expectEqual(PollStreak{ .low_yield = 1, .last_ms = 9_200 }, r.get(id).?.poll_streak);
    var now: util_time.Millis = 9_200;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        now += 1;
        r.extendPollStreak(id, now, now, 100);
    }
    try std.testing.expectEqual(std.math.maxInt(u8), r.get(id).?.poll_streak.low_yield);
    r.resetPollStreak(id);
    try std.testing.expectEqual(PollStreak{}, r.get(id).?.poll_streak);
    // Unknown ids are ignored, like the other cursor updates.
    r.extendPollStreak("000000000000", now, now, 100);
    r.resetPollStreak("000000000000");
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
    const owner = @import("metacodes-kernel").session_id.gen();
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
    const owner = @import("metacodes-kernel").session_id.gen();
    const other = @import("metacodes-kernel").session_id.gen();
    // `hasPendingNotifyJobs` reaps first and counts only running jobs, so the
    // job must still be alive at the first assertion. `true` exits within a
    // millisecond and lost that race on a loaded hosted runner (main fd8165f1
    // era, Gates (Linux)); a short sleep keeps the check deterministic and
    // waitUntilExited still returns in well under a second.
    const j = try r.spawnBackgroundOwned("sleep 0.5", null, owner);
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

test "spawn: cwd 已消失 → 子进程的报告原样上抛,不登记一个 exit 127 的 job" {
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    var dir_buf: [512]u8 = undefined;
    const dir = @import("metacodes-base").tools.test_tmp.path(&dir_buf, "job-vanished-cwd");
    _ = std.c.mkdir(dir.ptr, 0o700);
    try std.testing.expectEqual(@as(c_int, 0), std.c.rmdir(dir.ptr));
    try std.testing.expectError(error.ChildChdirFailed, r.spawnSynchronous("echo hello", dir));
    try std.testing.expectEqual(@as(usize, 0), r.jobs.items.len);
}

test "watchdog stops a job at its background time limit and says so in the exit event" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const j = try r.spawnBackgroundWatched("sleep 30", null, owner, 60_000);
    const early = try r.takeUnannouncedExitsAt(owner, a, j.started_ms + 59_999);
    defer freeJobExitEvents(a, early);
    try std.testing.expectEqual(@as(usize, 0), early.len);
    try std.testing.expectEqual(JobStatus.running, r.get(j.idSlice()).?.status);
    const events = try r.takeUnannouncedExitsAt(owner, a, j.started_ms + 60_000);
    defer freeJobExitEvents(a, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(JobStatus.killed, events[0].status);
    try std.testing.expectEqual(JobEventKind{ .time_limit = 60_000 }, events[0].kind);
    try std.testing.expectEqual(JobStatus.killed, r.get(j.idSlice()).?.status);
}

test "watchdog leaves a job without a limit and a KillShell kill as ordinary exits" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const unarmed = try r.spawnBackgroundOwned("sleep 30", null, owner);
    const armed = try r.spawnBackgroundWatched("sleep 30", null, owner, 60_000);
    try r.kill(armed.idSlice());
    const events = try r.takeUnannouncedExitsAt(owner, a, unarmed.started_ms + 100 * 3_600_000);
    defer freeJobExitEvents(a, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(JobEventKind.ended, events[0].kind);
    try std.testing.expectEqual(JobStatus.running, r.get(unarmed.idSlice()).?.status);
    try r.kill(unarmed.idSlice());
}

fn waitForOutput(r: *JobRegistry, id: []const u8, bytes: u64) !void {
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        const entry = r.get(id) orelse return error.JobNotFound;
        if ((spoolFileSize(entry.stdout_path) catch 0) >= bytes) return;
        util_time.sleepMs(10);
    }
    return error.NoOutput;
}

test "watchdog notices a prompt-like tail once, after the quiet window" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const prompt = "Overwrite existing files? [y/N] ";
    const j = try r.spawnBackgroundWatched("printf '" ++ prompt ++ "'; sleep 30", null, owner, 3_600_000);
    try waitForOutput(&r, j.idSlice(), prompt.len);
    const now = util_time.nowMs();
    const quiet: util_time.Millis = @intCast(INPUT_STALL_QUIET_MS);
    const first = try r.takeUnannouncedExitsAt(owner, a, now);
    defer freeJobExitEvents(a, first);
    try std.testing.expectEqual(@as(usize, 0), first.len);
    const before_window = try r.takeUnannouncedExitsAt(owner, a, now + quiet - 1);
    defer freeJobExitEvents(a, before_window);
    try std.testing.expectEqual(@as(usize, 0), before_window.len);
    const notice = try r.takeUnannouncedExitsAt(owner, a, now + quiet);
    defer freeJobExitEvents(a, notice);
    try std.testing.expectEqual(@as(usize, 1), notice.len);
    try std.testing.expectEqual(JobEventKind.awaiting_input, notice[0].kind);
    try std.testing.expectEqual(JobStatus.running, notice[0].status);
    const again = try r.takeUnannouncedExitsAt(owner, a, now + 4 * quiet);
    defer freeJobExitEvents(a, again);
    try std.testing.expectEqual(@as(usize, 0), again.len);
    try r.kill(j.idSlice());
}

test "watchdog stays quiet about a stalled job whose output is not a prompt" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const j = try r.spawnBackgroundWatched("printf 'compiling module 3 of 9\\n'; sleep 30", null, owner, 3_600_000);
    try waitForOutput(&r, j.idSlice(), "compiling module 3 of 9\n".len);
    const now = util_time.nowMs();
    const quiet: util_time.Millis = @intCast(INPUT_STALL_QUIET_MS);
    const first = try r.takeUnannouncedExitsAt(owner, a, now);
    defer freeJobExitEvents(a, first);
    const later = try r.takeUnannouncedExitsAt(owner, a, now + 10 * quiet);
    defer freeJobExitEvents(a, later);
    try std.testing.expectEqual(@as(usize, 0), first.len + later.len);
    try r.kill(j.idSlice());
}

test "looksLikeInteractivePrompt matches the listed prompts and nothing else" {
    const prompts = [_][]const u8{
        "Proceed (y/n)",
        "Install 3 packages? [Y/n] ",
        "Remove? [y/N]",
        "Are you sure (yes/no)?",
        "Press ENTER to continue",
        "press any key\n",
        "line one\nPassword:",
        "Continue?",
        "Name of the project? ",
        "Enter a value: ",
    };
    for (prompts) |prompt| try std.testing.expect(looksLikeInteractivePrompt(prompt));
    const plain = [_][]const u8{
        "",
        "\n\n",
        "Building...\n",
        "Error: missing file\n",
        "Continue? [y/N]\nDone.\n",
        "Ratio: 3/4\n",
    };
    for (plain) |text| try std.testing.expect(!looksLikeInteractivePrompt(text));
}

test "watchdog stops a job at its deadline without anyone collecting exits" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    var marker_buf: [512]u8 = undefined;
    const marker = @import("metacodes-base").tools.test_tmp.path(&marker_buf, "watchdog-sweeper-marker");
    unlinkPath(marker);
    defer unlinkPath(marker);
    var command_buf: [640]u8 = undefined;
    const command = try std.fmt.bufPrint(&command_buf, "sleep 1; touch '{s}'", .{marker});
    const j = try r.spawnBackgroundWatched(command, null, owner, 300);
    util_time.sleepMs(1500);
    try std.testing.expect(!spoolExists(marker));
    try std.testing.expectEqual(JobStatus.killed, r.get(j.idSlice()).?.status);
    const events = try r.takeUnannouncedExits(owner, a);
    defer freeJobExitEvents(a, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(JobEventKind{ .time_limit = 300 }, events[0].kind);
}

test "stopping a job kills a worker that ignores TERM after its shell has exited" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    var ready_buf: [512]u8 = undefined;
    const ready = @import("metacodes-base").tools.test_tmp.path(&ready_buf, "term-ignoring-worker-ready");
    var marker_buf: [512]u8 = undefined;
    const marker = @import("metacodes-base").tools.test_tmp.path(&marker_buf, "term-ignoring-worker-marker");
    unlinkPath(ready);
    unlinkPath(marker);
    defer unlinkPath(ready);
    defer unlinkPath(marker);
    var command_buf: [1280]u8 = undefined;
    const command = try std.fmt.bufPrint(&command_buf, "sh -c 'trap \"\" TERM; touch \"{s}\"; sleep 1; touch \"{s}\"' & wait", .{ ready, marker });
    const j = try r.spawnBackground(command, null);
    var attempts: usize = 0;
    while (!spoolExists(ready) and attempts < 500) : (attempts += 1) util_time.sleepMs(10);
    if (!spoolExists(ready)) return error.WorkerDidNotStart;
    try r.kill(j.idSlice());
    util_time.sleepMs(1500);
    try std.testing.expect(!spoolExists(marker));
}

test "watchdog stops jobs that expire together without waiting out one grace period per job" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    var marker_bufs: [2][512]u8 = undefined;
    var markers: [2][:0]const u8 = undefined;
    var ids: [2][12]u8 = undefined;
    for (&markers, &marker_bufs, 0..) |*marker, *buf, index| {
        const name = if (index == 0) "watchdog-together-first" else "watchdog-together-second";
        marker.* = @import("metacodes-base").tools.test_tmp.path(buf, name);
        unlinkPath(marker.*);
    }
    defer for (markers) |marker| unlinkPath(marker);
    for (markers, &ids) |marker, *id| {
        var command_buf: [640]u8 = undefined;
        const command = try std.fmt.bufPrint(&command_buf, "sleep 0.45; touch '{s}'", .{marker});
        id.* = (try r.spawnBackgroundWatched(command, null, owner, 300)).id;
    }
    util_time.sleepMs(1000);
    for (markers) |marker| try std.testing.expect(!spoolExists(marker));
    const events = try r.takeUnannouncedExits(owner, a);
    defer freeJobExitEvents(a, events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    for (events) |event| try std.testing.expectEqual(JobEventKind{ .time_limit = 300 }, event.kind);
}

test "jobs that exit on their own release their process handles" {
    if (comptime @import("builtin").os.tag != .windows) return error.SkipZigTest;
    const win = std.os.windows;
    const Kernel32 = struct {
        extern "kernel32" fn GetCurrentProcess() callconv(.winapi) win.HANDLE;
        extern "kernel32" fn GetProcessHandleCount(process_handle: win.HANDLE, count: *win.DWORD) callconv(.winapi) win.BOOL;
    };
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const warm_up = try r.spawnBackground("exit 0", null);
    try waitUntilExited(&r, warm_up.idSlice());
    var before: win.DWORD = 0;
    try std.testing.expect(Kernel32.GetProcessHandleCount(Kernel32.GetCurrentProcess(), &before) != .FALSE);
    const runs = 20;
    var run: usize = 0;
    while (run < runs) : (run += 1) {
        const job = try r.spawnBackground("exit 0", null);
        try waitUntilExited(&r, job.idSlice());
    }
    var after: win.DWORD = 0;
    try std.testing.expect(Kernel32.GetProcessHandleCount(Kernel32.GetCurrentProcess(), &after) != .FALSE);
    try std.testing.expect(after < before + runs / 2);
}

test "no time-limited job starts when the deadline sweeper cannot" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    JobRegistry.fail_sweeper_spawn_in_tests = true;
    defer JobRegistry.fail_sweeper_spawn_in_tests = false;
    var marker_buf: [512]u8 = undefined;
    const marker = @import("metacodes-base").tools.test_tmp.path(&marker_buf, "sweeper-refused-registry-marker");
    unlinkPath(marker);
    defer unlinkPath(marker);
    var command_buf: [640]u8 = undefined;
    const command = try std.fmt.bufPrint(&command_buf, "touch '{s}'", .{marker});
    try std.testing.expectError(error.SystemResources, r.spawnBackgroundWatched(command, null, owner, 60_000));
    try std.testing.expectError(error.SystemResources, r.spawnBackgroundSupervised(command, null, owner, .watchdog));
    try std.testing.expectError(error.SystemResources, r.spawnSynchronousSupervised(command, null, owner, .watchdog));
    try std.testing.expectEqual(@as(usize, 0), r.jobs.items.len);
    const unwatched = try r.spawnBackgroundOwned("sleep 30", null, owner);
    try std.testing.expectError(error.JobUnwatched, r.armWatchdog(unwatched.idSlice(), 60_000));
    try std.testing.expectEqual(@as(?Watchdog, null), r.get(unwatched.idSlice()).?.watchdog);
    try std.testing.expect(r.sweeper == null);
    try r.kill(unwatched.idSlice());
    util_time.sleepMs(300);
    try std.testing.expect(!spoolExists(marker));
}

test "a claimed expiry cannot be killed or reaped by anyone else before its TERM is sent" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const j = try r.spawnBackgroundWatched("sleep 30", null, owner, 60_000);
    var gate: TermGate = .{};
    test_term_gate = &gate;
    defer test_term_gate = null;
    const expired_at = j.started_ms + 60_000;
    const Claimer = struct {
        fn run(registry: *JobRegistry, session: SessionId, now_ms: util_time.Millis) void {
            registry.stopExpired(session, now_ms);
        }
    };
    const claimer = try std.Thread.spawn(.{}, Claimer.run, .{ &r, owner, expired_at });
    var released = false;
    defer if (!released) {
        gate.released.store(true, .release);
        claimer.join();
    };
    var attempts: usize = 0;
    while (!gate.reached.load(.acquire) and attempts < 500) : (attempts += 1) util_time.sleepMs(1);
    try std.testing.expect(gate.reached.load(.acquire));

    const later = expired_at + 10 * @as(util_time.Millis, @intCast(process.KILL_GRACE_MS));
    r.killDue(later);
    r.stopExpired(owner, later);
    const during = try r.takeUnannouncedExitsAt(owner, a, later);
    defer freeJobExitEvents(a, during);
    try std.testing.expectEqual(@as(usize, 0), during.len);
    const held = r.get(j.idSlice()).?;
    try std.testing.expectEqual(JobStatus.running, held.status);
    try std.testing.expect(held.stop_in_progress);
    try std.testing.expectEqual(@as(?util_time.Millis, null), held.watchdog.?.kill_at_ms);
    try std.testing.expectEqual(process.ReapStatus.running, process.reapNonblock(held.proc));

    gate.released.store(true, .release);
    claimer.join();
    released = true;
    const events = try r.takeUnannouncedExitsAt(owner, a, later);
    defer freeJobExitEvents(a, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(JobEventKind{ .time_limit = 60_000 }, events[0].kind);
    try std.testing.expect(!r.get(j.idSlice()).?.stop_in_progress);
}

fn monitorIndex(r: *JobRegistry, id: []const u8) usize {
    return r.index.get(id[0..12].*).?;
}

fn waitForStdout(r: *JobRegistry, id: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 500) : (attempts += 1) {
        if ((spoolFileSize(r.get(id).?.stdout_path) catch 0) > 0) return;
        util_time.sleepMs(10);
    }
    return error.NoMonitorOutput;
}

test "an expired monitor is stopped on time without any poll and still gets the expiry notice" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const marker = try std.fmt.allocPrintSentinel(a, "{s}/late-side-effect", .{root}, 0);
    defer a.free(marker);

    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const j = try r.spawnMonitorOwned("sleep 2; touch late-side-effect", root, owner, "slow", 1_000);
    util_time.sleepMs(2_500);
    try std.testing.expect(!pfs.exists(marker));
    try std.testing.expect(r.get(j.idSlice()).?.status != .running);

    const notices = try r.takeMonitorEvents(owner, a, util_time.nowMs());
    defer monitor_stream.freeNotices(a, notices);
    try std.testing.expectEqual(@as(usize, 1), notices.len);
    try std.testing.expectEqual(@as(usize, 0), notices[0].event.len);
    try std.testing.expectEqual(@as(?monitor_stream.End, .{ .expired = .{ .after_ms = 1_000, .events_delivered = 0 } }), notices[0].end);
}

test "a monitor that went quiet after one dropped batch is not stopped for too much output" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const j = try r.spawnMonitorOwned("echo burst; sleep 60", null, owner, "quiet", null);
    try waitForStdout(&r, j.idSlice());
    const t0: util_time.Millis = 1_000_000;
    {
        r.lock();
        defer r.unlock();
        r.jobs.items[monitorIndex(&r, j.idSlice())].kind.monitor.tokens = 0;
        r.jobs.items[monitorIndex(&r, j.idSlice())].kind.monitor.refilled_ms = t0;
    }
    const dropped = try r.takeMonitorEvents(owner, a, t0);
    defer monitor_stream.freeNotices(a, dropped);
    try std.testing.expectEqual(@as(usize, 0), dropped.len);
    try std.testing.expectEqual(@as(u32, 1), r.get(j.idSlice()).?.kind.monitor.suppressed);

    const later = try r.takeMonitorEvents(owner, a, t0 + monitor_stream.OVER_BUDGET_STOP_MS + 1_000);
    defer monitor_stream.freeNotices(a, later);
    try std.testing.expectEqual(@as(usize, 0), later.len);
    try std.testing.expectEqual(JobStatus.running, r.get(j.idSlice()).?.status);
    try std.testing.expectEqual(@as(?monitor_stream.Stop, null), r.get(j.idSlice()).?.kind.monitor.stop);
}

test "a monitor that resumes with one line after a dropped batch and silence is delivered, not stopped" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const j = try r.spawnMonitorOwned("echo burst; while [ ! -e go ]; do sleep 0.02; done; echo resumed; sleep 60", root, owner, "quiet", null);
    try waitForStdout(&r, j.idSlice());
    const t0: util_time.Millis = 1_000_000;
    {
        r.lock();
        defer r.unlock();
        r.jobs.items[monitorIndex(&r, j.idSlice())].kind.monitor.tokens = 0;
        r.jobs.items[monitorIndex(&r, j.idSlice())].kind.monitor.refilled_ms = t0;
    }
    const dropped = try r.takeMonitorEvents(owner, a, t0);
    defer monitor_stream.freeNotices(a, dropped);
    try std.testing.expectEqual(@as(usize, 0), dropped.len);
    const cursor = r.get(j.idSlice()).?.kind.monitor.stdout_cursor;

    const gate = try tmp.dir.createFile(std.testing.io, "go", .{});
    gate.close(std.testing.io);
    var attempts: usize = 0;
    while (attempts < 500 and (spoolFileSize(r.get(j.idSlice()).?.stdout_path) catch 0) <= cursor) : (attempts += 1) util_time.sleepMs(10);

    const resumed = try r.takeMonitorEvents(owner, a, t0 + monitor_stream.OVER_BUDGET_STOP_MS + 1_000);
    defer monitor_stream.freeNotices(a, resumed);
    try std.testing.expectEqual(@as(usize, 1), resumed.len);
    try std.testing.expectEqualStrings("[1 events suppressed — output rate too high]\nresumed", resumed[0].event);
    try std.testing.expectEqual(@as(?monitor_stream.End, null), resumed[0].end);
    try std.testing.expectEqual(JobStatus.running, r.get(j.idSlice()).?.status);
    try std.testing.expectEqual(@as(?monitor_stream.Stop, null), r.get(j.idSlice()).?.kind.monitor.stop);
}

test "monitors that expire together are all signalled before any grace period ends" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const first_marker = try std.fmt.allocPrintSentinel(a, "{s}/first", .{root}, 0);
    defer a.free(first_marker);
    const second_marker = try std.fmt.allocPrintSentinel(a, "{s}/second", .{root}, 0);
    defer a.free(second_marker);

    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const first = try r.spawnMonitorOwned("sleep 1.15; touch first", root, owner, "one", 1_000);
    const second = try r.spawnMonitorOwned("sleep 1.15; touch second", root, owner, "two", 1_000);
    {
        r.lock();
        defer r.unlock();
        r.jobs.items[monitorIndex(&r, second.idSlice())].started_ms = r.jobs.items[monitorIndex(&r, first.idSlice())].started_ms;
    }
    util_time.sleepMs(1_700);
    try std.testing.expect(!pfs.exists(first_marker));
    try std.testing.expect(!pfs.exists(second_marker));

    const notices = try r.takeMonitorEvents(owner, a, util_time.nowMs());
    defer monitor_stream.freeNotices(a, notices);
    try std.testing.expectEqual(@as(usize, 2), notices.len);
    for (notices) |notice| try std.testing.expectEqual(@as(?monitor_stream.End, .{ .expired = .{ .after_ms = 1_000, .events_delivered = 0 } }), notice.end);
}

test "a monitor that fails before its deadline keeps its exit code even when reaped after it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const j = try r.spawnMonitorOwned("exit 3", null, owner, "fails", 1_000);
    try waitUntilExited(&r, j.idSlice());
    const started = r.get(j.idSlice()).?.started_ms;
    {
        r.lock();
        defer r.unlock();
        r.jobs.items[monitorIndex(&r, j.idSlice())].ended_ms = started + 5_000;
    }
    const notices = try r.takeMonitorEvents(owner, a, started + 5_000);
    defer monitor_stream.freeNotices(a, notices);
    try std.testing.expectEqual(@as(usize, 1), notices.len);
    try std.testing.expectEqual(@as(?monitor_stream.End, .{ .script_failed = 3 }), notices[0].end);
}

test "two concurrent stops of one job claim it once and both return" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const j = try r.spawnBackground("sleep 30", null);
    const Stopper = struct {
        fn run(registry: *JobRegistry, id: [12]u8) void {
            registry.kill(id[0..]) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Stopper.run, .{ &r, j.id });
    try r.kill(j.idSlice());
    thread.join();
    const after = r.get(j.idSlice()).?;
    try std.testing.expectEqual(JobStatus.killed, after.status);
    try std.testing.expect(!after.stop_in_progress);
    try std.testing.expectEqual(@as(usize, 0), r.killAll());
}

test "a monitor that keeps flooding past the budget for 30 s is stopped with a notice" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const j = try r.spawnMonitorOwned("while :; do echo spam; sleep 0.01; done", null, owner, "flood", null);
    try waitForStdout(&r, j.idSlice());
    const t0: util_time.Millis = 1_000_000;
    {
        r.lock();
        defer r.unlock();
        r.jobs.items[monitorIndex(&r, j.idSlice())].kind.monitor.tokens = 0;
        r.jobs.items[monitorIndex(&r, j.idSlice())].kind.monitor.refilled_ms = std.math.maxInt(i64) / 2;
    }
    const dropped = try r.takeMonitorEvents(owner, a, t0);
    defer monitor_stream.freeNotices(a, dropped);
    try std.testing.expectEqual(@as(usize, 0), dropped.len);
    const cursor = r.get(j.idSlice()).?.kind.monitor.stdout_cursor;
    var attempts: usize = 0;
    while (attempts < 500 and (spoolFileSize(r.get(j.idSlice()).?.stdout_path) catch 0) <= cursor) : (attempts += 1) util_time.sleepMs(10);

    const stopping = try r.takeMonitorEvents(owner, a, t0 + monitor_stream.OVER_BUDGET_STOP_MS);
    defer monitor_stream.freeNotices(a, stopping);
    try std.testing.expectEqual(@as(usize, 0), stopping.len);
    try std.testing.expect(r.get(j.idSlice()).?.status != .running);
    const stopped = try r.takeMonitorEvents(owner, a, t0 + monitor_stream.OVER_BUDGET_STOP_MS);
    defer monitor_stream.freeNotices(a, stopped);
    try std.testing.expectEqual(@as(usize, 1), stopped.len);
    try std.testing.expectEqual(@as(?monitor_stream.End, .too_much_output), stopped[0].end);
}

test "a monitor stdout line longer than one read is delivered once, then the next line" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const j = try r.spawnMonitorOwned("head -c 140000 /dev/zero | tr '\\0' x; echo; echo normal", null, owner, "long", null);
    try waitUntilExited(&r, j.idSlice());
    var lines = std.ArrayList(u8).empty;
    defer lines.deinit(a);
    var ended = false;
    var takes: usize = 0;
    while (!ended and takes < 10) : (takes += 1) {
        const notices = try r.takeMonitorEvents(owner, a, util_time.nowMs());
        defer monitor_stream.freeNotices(a, notices);
        for (notices) |notice| {
            if (notice.event.len > 0) {
                if (lines.items.len > 0) try lines.append(a, '\n');
                try lines.appendSlice(a, notice.event);
            }
            if (notice.end != null) ended = true;
        }
    }
    try std.testing.expect(ended);
    var expected: [monitor_stream.LINE_MAX_BYTES + "\nnormal".len]u8 = undefined;
    @memset(expected[0..monitor_stream.LINE_MAX_BYTES], 'x');
    @memcpy(expected[monitor_stream.LINE_MAX_BYTES..], "\nnormal");
    try std.testing.expectEqualStrings(&expected, lines.items);
}

test "a monitor expiring during another monitor's grace period is signalled at its own deadline" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const command = "trap 'echo term' TERM; echo ready; while :; do sleep 0.05; done";
    const first = try r.spawnMonitorOwned(command, null, owner, "first", null);
    const second = try r.spawnMonitorOwned(command, null, owner, "second", null);
    const jobs = [_]JobEntry{ first, second };
    for (jobs, [_]util_time.Millis{ 0, 50 }) |job, start_ms| {
        try waitForOutput(&r, job.idSlice(), "ready\n".len);
        const entry = &r.jobs.items[monitorIndex(&r, job.idSlice())];
        entry.started_ms = start_ms;
        entry.kind.monitor.timeout_ms = 1_000;
    }
    var clock = struct {
        ms: util_time.Millis,

        fn nowMs(self: @This()) util_time.Millis {
            return self.ms;
        }
    }{ .ms = 1_000 };
    var steps: std.ArrayList(JobRegistry.ExpiryStep) = .empty;
    defer steps.deinit(a);
    r.sweepDue(&steps, clock);
    try waitForOutput(&r, first.idSlice(), "ready\nterm\n".len);
    try std.testing.expectEqual(@as(?monitor_stream.Stop, null), r.get(second.idSlice()).?.kind.monitor.stop);
    const next = r.nextExpiryWaitLocked(clock.ms);
    try std.testing.expectEqual(@as(?u64, 50), next);
    clock.ms += @intCast(next.?);
    r.sweepDue(&steps, clock);
    try waitForOutput(&r, second.idSlice(), "ready\nterm\n".len);
    for (jobs) |job| {
        try std.testing.expectEqual(JobStatus.running, r.get(job.idSlice()).?.status);
        try std.testing.expectEqual(process.ReapStatus.running, process.reapNonblock(job.proc));
    }
    clock.ms += process.KILL_GRACE_MS;
    r.sweepDue(&steps, clock);
    for (jobs) |job| try std.testing.expectEqual(JobStatus.killed, r.get(job.idSlice()).?.status);

    const notices = try r.takeMonitorEvents(owner, a, clock.ms);
    defer monitor_stream.freeNotices(a, notices);
    try std.testing.expectEqual(@as(usize, 2), notices.len);
    for (notices, jobs) |notice, job| {
        try std.testing.expectEqual(job.id, notice.id);
        try std.testing.expectEqualStrings("ready\nterm", notice.event);
        try std.testing.expectEqual(@as(?monitor_stream.End, .{ .expired = .{
            .after_ms = 1_000,
            .events_delivered = 2,
        } }), notice.end);
    }
}

test "more monitors than one batch expiring together are all signalled at the deadline" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const count = 20;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    var ids: [count][12]u8 = undefined;
    for (&ids, 0..) |*id, index| {
        const command = try std.fmt.allocPrint(a, "sleep 1.15; touch marker-{d}", .{index});
        defer a.free(command);
        id.* = (try r.spawnMonitorOwned(command, root, owner, "batch", 1_000)).id;
    }
    {
        r.lock();
        defer r.unlock();
        const base = r.jobs.items[monitorIndex(&r, ids[0][0..])].started_ms;
        for (ids) |id| r.jobs.items[monitorIndex(&r, id[0..])].started_ms = base;
    }
    util_time.sleepMs(1_800);
    for (0..count) |index| {
        const marker = try std.fmt.allocPrintSentinel(a, "{s}/marker-{d}", .{ root, index }, 0);
        defer a.free(marker);
        try std.testing.expect(!pfs.exists(marker));
    }
    const notices = try r.takeMonitorEvents(owner, a, util_time.nowMs());
    defer monitor_stream.freeNotices(a, notices);
    try std.testing.expectEqual(count, notices.len);
    for (notices) |notice| try std.testing.expectEqual(@as(?monitor_stream.End, .{ .expired = .{ .after_ms = 1_000, .events_delivered = 0 } }), notice.end);
}

test "an expired monitor's worker that ignores TERM does not outlive the grace period" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const marker = try std.fmt.allocPrintSentinel(a, "{s}/worker-marker", .{root}, 0);
    defer a.free(marker);
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    _ = try r.spawnMonitorOwned("sh -c 'trap \"\" TERM; sleep 1.5; touch worker-marker' & wait", root, owner, "worker", 1_000);
    util_time.sleepMs(2_200);
    try std.testing.expect(!pfs.exists(marker));
    const notices = try r.takeMonitorEvents(owner, a, util_time.nowMs());
    defer monitor_stream.freeNotices(a, notices);
    try std.testing.expectEqual(@as(usize, 1), notices.len);
    try std.testing.expectEqual(@as(?monitor_stream.End, .{ .expired = .{ .after_ms = 1_000, .events_delivered = 0 } }), notices[0].end);
}

test "a flooding monitor stopped in the same take as an expiry gets TERM before KILL" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const termed = try std.fmt.allocPrintSentinel(a, "{s}/termed", .{root}, 0);
    defer a.free(termed);
    var r = try JobRegistry.init(a);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const expiring = try r.spawnMonitorOwned("sleep 30", root, owner, "expiring", 60_000);
    const flooding = try r.spawnMonitorOwned("trap 'touch termed; exit 0' TERM; while :; do echo spam; sleep 0.01; done", root, owner, "flooding", null);
    try waitForStdout(&r, flooding.idSlice());
    const now = util_time.nowMs();
    {
        r.lock();
        defer r.unlock();
        r.jobs.items[monitorIndex(&r, expiring.idSlice())].started_ms = now - 60_000;
        const state = &r.jobs.items[monitorIndex(&r, flooding.idSlice())].kind.monitor;
        state.tokens = 0;
        state.refilled_ms = std.math.maxInt(i64) / 2;
        state.over_budget_since_ms = now - monitor_stream.OVER_BUDGET_STOP_MS;
    }
    var saw_expired = false;
    var saw_flood_stop = false;
    var takes: usize = 0;
    while (takes < 20 and !(saw_expired and saw_flood_stop)) : (takes += 1) {
        const notices = try r.takeMonitorEvents(owner, a, if (takes == 0) now else util_time.nowMs());
        defer monitor_stream.freeNotices(a, notices);
        for (notices) |notice| {
            const end = notice.end orelse continue;
            if (std.mem.eql(u8, &notice.id, &expiring.id)) saw_expired = end == .expired;
            if (std.mem.eql(u8, &notice.id, &flooding.id)) saw_flood_stop = end == .too_much_output;
        }
        if (!(saw_expired and saw_flood_stop)) util_time.sleepMs(50);
    }
    try std.testing.expect(pfs.exists(termed));
    try std.testing.expect(saw_expired);
    try std.testing.expect(saw_flood_stop);
    for ([_][12]u8{ expiring.id, flooding.id }) |id| {
        const entry = r.get(id[0..]).?;
        try std.testing.expect(entry.status != .running);
        try std.testing.expect(!entry.stop_in_progress);
        try std.testing.expectEqual(@as(?util_time.Millis, null), entry.kind.monitor.kill_at_ms);
    }
}

fn spawnOverloadedFlood(r: *JobRegistry, owner: SessionId, now: util_time.Millis) !JobEntry {
    const j = try r.spawnMonitorOwned("while :; do echo spam; sleep 0.01; done", null, owner, "flood", null);
    try waitForStdout(r, j.idSlice());
    r.lock();
    defer r.unlock();
    const state = &r.jobs.items[monitorIndex(r, j.idSlice())].kind.monitor;
    state.tokens = 0;
    state.refilled_ms = std.math.maxInt(i64) / 2;
    state.over_budget_since_ms = now - monitor_stream.OVER_BUDGET_STOP_MS;
    return j;
}

fn expectFloodStopped(r: *JobRegistry, owner: SessionId, j: JobEntry, already_reported: bool) !void {
    var reported = already_reported;
    var takes: usize = 0;
    while (!reported and takes < 10) : (takes += 1) {
        const notices = try r.takeMonitorEvents(owner, std.testing.allocator, util_time.nowMs());
        defer monitor_stream.freeNotices(std.testing.allocator, notices);
        for (notices) |notice| {
            if (notice.end) |end| reported = reported or end == .too_much_output;
        }
    }
    try std.testing.expect(reported);
    const entry = r.get(j.idSlice()).?;
    try std.testing.expect(entry.status != .running);
    try std.testing.expect(!entry.stop_in_progress);
    try r.kill(j.idSlice());
    try std.testing.expectEqual(@as(usize, 0), r.killAll());
}

test "an allocation failure at any point of a flood take never leaves the monitor half-claimed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var r = try JobRegistry.init(std.testing.allocator);
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const now = util_time.nowMs();
    const j = try spawnOverloadedFlood(&r, owner, now);
    try std.testing.expect(r.sweeper == null);
    var reported = false;
    var fail_index: usize = 0;
    while (fail_index < 200) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const notices = r.takeMonitorEvents(owner, failing.allocator(), now) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            const entry = r.get(j.idSlice()).?;
            try std.testing.expect(!entry.stop_in_progress);
            if (entry.status == .running) try std.testing.expectEqual(@as(?monitor_stream.Stop, null), entry.kind.monitor.stop);
            continue;
        };
        defer monitor_stream.freeNotices(failing.allocator(), notices);
        for (notices) |notice| {
            if (notice.end) |end| reported = reported or end == .too_much_output;
        }
        break;
    }
    try std.testing.expect(fail_index < 200);
    try expectFloodStopped(&r, owner, j, reported);
}

test "a flood stop finishes with only persistent monitors when the registry allocator fails" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var registry_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var r = try JobRegistry.init(registry_allocator.allocator());
    defer r.deinit();
    const owner = @import("metacodes-kernel").session_id.gen();
    const now = util_time.nowMs();
    const j = try spawnOverloadedFlood(&r, owner, now);
    try std.testing.expect(r.sweeper == null);
    registry_allocator.fail_index = registry_allocator.alloc_index;
    const notices = try r.takeMonitorEvents(owner, std.testing.allocator, now);
    defer monitor_stream.freeNotices(std.testing.allocator, notices);
    registry_allocator.fail_index = std.math.maxInt(usize);
    var reported = false;
    for (notices) |notice| {
        if (notice.end) |end| reported = reported or end == .too_much_output;
    }
    try expectFloodStopped(&r, owner, j, reported);
}
