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
const log = @import("../util/log.zig");
const util_fs = @import("../util/fs.zig");
const util_time = @import("../util/time.zig");

pub const JobStatus = enum { running, exited, killed, failed };

pub const JobEntry = struct {
    id: [12]u8,
    pid: std.c.pid_t,
    pgid: std.c.pid_t,
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

    pub fn init(allocator: std.mem.Allocator) !JobRegistry {
        const uid = std.c.getuid();
        const base = try std.fmt.allocPrint(allocator, "/tmp/metacodes-jobs/{d}", .{uid});
        errdefer allocator.free(base);
        try util_fs.mkdirParents(base);
        var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        @memcpy(zbuf[0..base.len], base);
        zbuf[base.len] = 0;
        _ = std.c.chmod(@ptrCast(&zbuf), 0o700);

        return .{
            .allocator = allocator,
            .jobs = .empty,
            .index = std.AutoHashMap([12]u8, usize).init(allocator),
            .base_dir = base,
        };
    }

    pub fn deinit(self: *JobRegistry) void {
        // 杀所有 running job 并 reap（防孤儿进程）
        for (self.jobs.items) |*j| {
            if (j.status == .running) {
                _ = std.c.kill(-j.pgid, std.c.SIG.TERM);
            }
        }
        // 短等让 TERM 生效（与 kill() 一样的策略），再补 KILL + waitpid
        const req = std.c.timespec{ .sec = 0, .nsec = 200_000_000 };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
        for (self.jobs.items) |*j| {
            if (j.status == .running) {
                var status: c_int = 0;
                const WNOHANG: c_int = 1;
                const rc = std.c.waitpid(j.pid, &status, WNOHANG);
                if (rc == 0) {
                    _ = std.c.kill(-j.pgid, std.c.SIG.KILL);
                    _ = std.c.waitpid(j.pid, &status, 0);
                }
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

    /// 生成新 job id：12 hex = 6 byte，从 `/dev/urandom` 读熵。
    /// 之所以不走 `std.posix.getrandom`：Zig 0.16 stable 没有该绑定；macOS libc 也没有
    /// `getrandom(2)` 系统调用。`/dev/urandom` 在 Linux / macOS / BSD 都可用，纯 POSIX。
    /// 失败 fatal：进程启不了 bg job 比 id 碰撞强。JobRegistry 的使用方已有兜底
    /// （spawnBackground 失败回退同步执行）。
    fn genId() error{RandomFailed}![12]u8 {
        var raw: [6]u8 = undefined;
        const fd = std.c.open("/dev/urandom", std.c.O{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) {
            const errno = std.c._errno().*;
            log.err("job", "open /dev/urandom failed errno={d}", .{errno});
            return error.RandomFailed;
        }
        defer _ = std.c.close(fd);
        var pos: usize = 0;
        while (pos < raw.len) {
            const n = std.c.read(fd, raw[pos..].ptr, raw.len - pos);
            if (n <= 0) {
                const errno = std.c._errno().*;
                log.err("job", "read /dev/urandom failed rc={d} errno={d}", .{ n, errno });
                return error.RandomFailed;
            }
            pos += @as(usize, @intCast(n));
        }
        var id: [12]u8 = undefined;
        _ = std.fmt.bufPrint(&id, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ raw[0], raw[1], raw[2], raw[3], raw[4], raw[5] }) catch unreachable;
        return id;
    }

    /// spawn 一个子进程跑 `/bin/sh -c command`，stdout/stderr 重定向到落盘文件。
    /// 立刻返回 job_id，不等待进程结束。
    pub fn spawnBackground(self: *JobRegistry, command: []const u8) !JobEntry {
        const id = try genId();

        const stdout_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.out", .{ self.base_dir, id[0..] });
        errdefer self.allocator.free(stdout_path);
        const stderr_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.err", .{ self.base_dir, id[0..] });
        errdefer self.allocator.free(stderr_path);

        // 预创建空文件（0600）让 reader 能立刻打开
        const out_fd = createFile(stdout_path) orelse return error.OpenFailed;
        const err_fd = createFile(stderr_path) orelse {
            _ = std.c.close(out_fd);
            return error.OpenFailed;
        };

        const cmd_z = try self.allocator.dupeZ(u8, command);
        defer self.allocator.free(cmd_z);

        const pid = std.c.fork();
        if (pid < 0) {
            _ = std.c.close(out_fd);
            _ = std.c.close(err_fd);
            return error.SpawnFailed;
        }

        if (pid == 0) {
            // 子进程
            _ = std.c.setpgid(0, 0);
            _ = std.c.dup2(out_fd, 1);
            _ = std.c.dup2(err_fd, 2);
            _ = std.c.close(out_fd);
            _ = std.c.close(err_fd);

            const argv0: [*:0]const u8 = "/bin/sh";
            var argv: [4]?[*:0]const u8 = .{ argv0, "-c", cmd_z.ptr, null };
            _ = std.c.execve(argv0, @as([*:null]const ?[*:0]const u8, @ptrCast(&argv)), &.{null});
            std.c._exit(127);
        }

        _ = std.c.close(out_fd);
        _ = std.c.close(err_fd);
        _ = std.c.setpgid(pid, pid);

        const started_ms: util_time.Millis = util_time.nowMs();

        const preview = try self.allocator.dupe(u8, command[0..@min(command.len, 120)]);
        errdefer self.allocator.free(preview);

        const entry = JobEntry{
            .id = id,
            .pid = pid,
            .pgid = pid,
            .started_ms = started_ms,
            .stdout_path = stdout_path,
            .stderr_path = stderr_path,
            .command_preview = preview,
            .status = .running,
        };
        try self.jobs.append(self.allocator, entry);
        const new_idx = self.jobs.items.len - 1;
        // key 是 [12]u8 值拷贝，不依赖 jobs buffer 生命周期
        try self.index.put(id, new_idx);
        log.info("job", "bg spawn id={s} pid={d} cmd={s}", .{ id[0..], pid, preview });
        return entry;
    }

    /// 非阻塞 reap：对所有 running job waitpid(WNOHANG)，把已退出的状态更新。
    pub fn reapExited(self: *JobRegistry) void {
        for (self.jobs.items) |*j| {
            if (j.status != .running) continue;
            var status: c_int = 0;
            const WNOHANG: c_int = 1;
            const rc = std.c.waitpid(j.pid, &status, WNOHANG);
            if (rc == j.pid) {
                j.exit_code = exitCode(status);
                j.status = if ((status & 0x7f) != 0) .killed else .exited;
                log.info("job", "bg exit id={s} pid={d} code={d} status={s}", .{ j.id[0..], j.pid, j.exit_code.?, @tagName(j.status) });
            }
        }
    }

    /// 按 id 查；命中返回指针（指向内部存储，caller 仅读）。O(1)。
    /// id slice 长度必须正好 12；否则返 null。
    pub fn get(self: *JobRegistry, id: []const u8) ?*JobEntry {
        if (id.len != 12) return null;
        var key: [12]u8 = undefined;
        @memcpy(&key, id[0..12]);
        const idx = self.index.get(key) orelse return null;
        return &self.jobs.items[idx];
    }

    /// killGroup：向 pgid 发 SIGTERM → 0.5s → SIGKILL。
    pub fn kill(self: *JobRegistry, id: []const u8) !void {
        // 第一阶段：查 job，读快照，发 TERM。作用域结束后指针作废。
        // 保留 pid + pgid 快照：无论 registry 后续状态变化，我们都要能正确 reap。
        // 这是"不让数据结构生命周期绑架 syscall 正确性"的铁律。
        var pid: std.c.pid_t = undefined;
        var pgid: std.c.pid_t = undefined;
        {
            const j = self.get(id) orelse return error.JobNotFound;
            if (j.status != .running) return; // 已结束，幂等返回
            pid = j.pid;
            pgid = j.pgid;
            _ = std.c.kill(-pgid, std.c.SIG.TERM);
        }

        // 睡眠 + reap。reapExited 可能改 status/exit_code，但当前实现不动 jobs 数组。
        // 即便将来 reapExited 移除已退出 entry，第二阶段的 pid 快照保证我们仍能 waitpid。
        var req = std.c.timespec{ .sec = 0, .nsec = 500_000_000 };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
        self.reapExited();
        // POSIX 契约：reapExited 内部 waitpid(pid, WNOHANG)。若子进程已退，pid 被 reap
        // 且 j.status 被置为 .exited/.killed；若还在跑，pid 未 reap 且 j.status 仍 .running。
        // 所以下面 `j.status == .running` 为真时，pid **一定未被 reap**，
        // waitpid(pid, 0) 阻塞等它死掉是安全的。**不要**把 reapExited 的 WNOHANG 改成 0。

        // 第二阶段：若 entry 还在且仍 running，补 KILL；否则用快照兜底 reap（防僵尸）。
        if (self.get(id)) |j| {
            if (j.status == .running) {
                _ = std.c.kill(-pgid, std.c.SIG.KILL);
                var status: c_int = 0;
                _ = std.c.waitpid(pid, &status, 0);
                j.exit_code = exitCode(status);
                j.status = .killed;
            }
        } else {
            // entry 不在 registry 了（当前实现不会发生，但防御性兜底）
            // 发一次 KILL + blocking waitpid 回收 pid，避免僵尸。
            _ = std.c.kill(-pgid, std.c.SIG.KILL);
            var status: c_int = 0;
            _ = std.c.waitpid(pid, &status, 0);
        }
    }

    pub fn activeCount(self: *const JobRegistry) usize {
        var n: usize = 0;
        for (self.jobs.items) |j| if (j.status == .running) { n += 1; };
        return n;
    }
};

fn createFile(path: []const u8) ?std.c.fd_t {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = std.c.open(@ptrCast(&buf), std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
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

    const j = try r.spawnBackground("echo hello; sleep 0.05");
    try std.testing.expect(j.status == .running);

    // 等一会儿让子进程退出
    var req = std.c.timespec{ .sec = 0, .nsec = 200_000_000 };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);

    r.reapExited();
    const j2 = r.get(j.idSlice()).?;
    try std.testing.expect(j2.status == .exited);
    try std.testing.expect(j2.exit_code.? == 0);
}

test "kill running job" {
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();

    const j = try r.spawnBackground("sleep 30");
    try std.testing.expect(j.status == .running);
    try r.kill(j.idSlice());
    const j2 = r.get(j.idSlice()).?;
    try std.testing.expect(j2.status == .killed);
}

test "activeCount" {
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();

    const j1 = try r.spawnBackground("sleep 2");
    const j2 = try r.spawnBackground("sleep 2");
    _ = j1;
    _ = j2;
    try std.testing.expect(r.activeCount() == 2);
    try r.kill(r.jobs.items[0].idSlice());
    try r.kill(r.jobs.items[1].idSlice());
    try std.testing.expect(r.activeCount() == 0);
}

test "get returns correct entry across many spawns" {
    // 不变量：无论 registry append 了多少次（触发 ArrayList grow），
    // 用保存的 id 查回来的 entry 必须和保存时的 id 一致。
    //
    // 这个测试在修复前（key 是指向 jobs[i].id 的 slice）会 crash：
    // ArrayList grow 后老 slice key 悬挂，get 读到错的 index，&jobs.items[idx] 越界。
    // （已亲手把 fix 回退验证过，crash。）
    //
    // 100 次 trivial job 足以触发 6-7 轮 ArrayList grow（empty → 1 → 2 → 4 → 8 → 16 → 32 → 64 → 128）。
    const a = std.testing.allocator;
    var r = try JobRegistry.init(a);
    defer r.deinit();

    const N = 100;
    var saved_ids: [N][12]u8 = undefined;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const j = try r.spawnBackground("true");
        saved_ids[i] = j.id;
    }

    // 反向查所有保存的 id，断言内容一致
    i = N;
    while (i > 0) {
        i -= 1;
        const found = r.get(saved_ids[i][0..]) orelse return error.IdLost;
        try std.testing.expectEqualSlices(u8, &saved_ids[i], &found.id);
    }
}
