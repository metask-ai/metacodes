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
const ppaths = @import("platform").paths;
const shell_mod = @import("shell.zig");

pub const JobStatus = enum { running, exited, killed, failed };

pub const JobEntry = struct {
    id: [12]u8,
    /// 进程句柄（POSIX=pid，Windows=HANDLE）。走可移植 platform/process。
    proc: process.ProcHandle,
    started_ms: util_time.Millis,
    stdout_path: []const u8, // owned
    stderr_path: []const u8, // owned
    command_preview: []const u8, // owned, 前 N 字符便于 UI 列表
    status: JobStatus = .running,
    exit_code: ?i32 = null,

    pub fn idSlice(self: *const JobEntry) []const u8 {
        return self.id[0..];
    }
};

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
        for (self.jobs.items) |j| {
            self.allocator.free(j.stdout_path);
            self.allocator.free(j.stderr_path);
            self.allocator.free(j.command_preview);
        }
        self.index.deinit();
        self.jobs.deinit(self.allocator);
        self.allocator.free(self.base_dir);
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
        const id = try genId();

        const stdout_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.out", .{ self.base_dir, id[0..] });
        errdefer self.allocator.free(stdout_path);
        const stderr_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.err", .{ self.base_dir, id[0..] });
        errdefer self.allocator.free(stderr_path);

        // 预创建空文件（0600）让 reader 能立刻打开
        const out_fd = createFile(stdout_path) orelse return error.OpenFailed;
        defer _ = pfs.close(out_fd);
        const err_fd = createFile(stderr_path) orelse return error.OpenFailed;
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

        const preview = try self.allocator.dupe(u8, command[0..@min(command.len, 120)]);
        errdefer self.allocator.free(preview);

        const entry = JobEntry{
            .id = id,
            .proc = proc,
            .started_ms = started_ms,
            .stdout_path = stdout_path,
            .stderr_path = stderr_path,
            .command_preview = preview,
            .status = .running,
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

fn createFile(path: []const u8) ?pfs.Fd {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = pfs.open(@ptrCast(&buf), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return null;
    return fd;
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
