//! MCP stdio 传输：spawn 子进程，通过其 stdin/stdout 交换 JSON-RPC 消息。
//!
//! MCP spec 2024-11-05 规定 stdio 传输用 **newline-delimited JSON**（NDJSON）：
//! 每条 JSON-RPC 消息独占一行，以 `\n` 结尾。读取端按行切分。
//!
//! 设计：
//! - `StdioTransport.spawn(argv)` 创建子进程，持有 stdin/stdout 两个 pipe fd
//! - `send(json)` 写一行到 stdin
//! - `recvLine(allocator)` 读一行（阻塞，返 []u8 owned）
//! - `close()` 关 pipe，wait 子进程收尾
//!
//! abort-aware:设 `abort` 后,recvLine 用 poll(100ms)守卫阻塞 read,超时查 abort → error.Aborted。
//! 让挂死的 MCP server 能被 Ctrl+C(AbortSignal)打断,不再无限 wedge agent。未设 abort → 退回纯阻塞。

const std = @import("std");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

/// 单行(一条 JSON-RPC 响应/resource)字节上限(轴A OOM 防线)。MCP resource 可合法较大(文件内容),
/// 64MB 对真实响应绰绰;超此值必是无 `\n` 的病态/恶意巨型行 → 断帧报错 error.McpLineTooLarge。
const MAX_MCP_LINE_BYTES: usize = 64 * 1024 * 1024;

pub const StdioTransport = struct {
    pid: std.c.pid_t,
    stdin_fd: std.c.fd_t,
    stdout_fd: std.c.fd_t,
    read_buf: std.ArrayList(u8),
    read_buf_pos: usize = 0,
    allocator: std.mem.Allocator,
    /// 可选中断信号(callTool 期设);null=纯阻塞(如 initialize 短握手)。
    abort: ?*const AbortSignal = null,

    /// spawn 子进程。argv 以 null 结尾，argv[0] 是绝对路径或在 PATH 内。
    pub fn spawn(allocator: std.mem.Allocator, argv: []const ?[*:0]const u8) !StdioTransport {
        // 两对 pipe：一对给子 stdin（父写 → 子读），一对给子 stdout（子写 → 父读）
        var in_pipe: [2]std.c.fd_t = undefined; // [0] read, [1] write
        var out_pipe: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&in_pipe) != 0) return error.PipeFailed;
        errdefer {
            _ = std.c.close(in_pipe[0]);
            _ = std.c.close(in_pipe[1]);
        }
        if (std.c.pipe(&out_pipe) != 0) return error.PipeFailed;
        errdefer {
            _ = std.c.close(out_pipe[0]);
            _ = std.c.close(out_pipe[1]);
        }

        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            // 子进程
            _ = std.c.setpgid(0, 0);
            // stdin ← in_pipe[0]
            _ = std.c.dup2(in_pipe[0], 0);
            _ = std.c.close(in_pipe[0]);
            _ = std.c.close(in_pipe[1]);
            // stdout → out_pipe[1]
            _ = std.c.dup2(out_pipe[1], 1);
            _ = std.c.close(out_pipe[0]);
            _ = std.c.close(out_pipe[1]);

            const argv0 = argv[0] orelse std.c._exit(127);
            _ = std.c.execve(argv0, @as([*:null]const ?[*:0]const u8, @ptrCast(argv.ptr)), &.{null});
            std.c._exit(127);
        }

        // 父进程：关掉不用的一端
        _ = std.c.close(in_pipe[0]); // 父不读 stdin pipe
        _ = std.c.close(out_pipe[1]); // 父不写 stdout pipe

        return .{
            .pid = pid,
            .stdin_fd = in_pipe[1],
            .stdout_fd = out_pipe[0],
            .read_buf = .empty,
            .allocator = allocator,
        };
    }

    /// 写一行 JSON。自动追加 '\n'。
    pub fn send(self: *StdioTransport, json: []const u8) !void {
        var total: usize = 0;
        while (total < json.len) {
            const n = std.c.write(self.stdin_fd, json.ptr + total, json.len - total);
            if (n <= 0) return error.WriteFailed;
            total += @as(usize, @intCast(n));
        }
        const nl = [_]u8{'\n'};
        const w = std.c.write(self.stdin_fd, &nl, 1);
        if (w <= 0) return error.WriteFailed;
    }

    /// 读一行（不含 '\n'）。阻塞直到拿到一行或 EOF。
    /// 返回 owned bytes；EOF 且缓冲区空时返 error.Eof。
    pub fn recvLine(self: *StdioTransport) ![]u8 {
        var chunk: [4096]u8 = undefined;
        while (true) {
            // 先看缓冲区里有没有换行
            if (std.mem.indexOfScalarPos(u8, self.read_buf.items, self.read_buf_pos, '\n')) |nl| {
                const line = self.read_buf.items[self.read_buf_pos..nl];
                const owned = try self.allocator.dupe(u8, line);
                self.read_buf_pos = nl + 1;
                // 压缩 buffer（避免无限增长）
                if (self.read_buf_pos > 4096) {
                    std.mem.copyForwards(u8, self.read_buf.items, self.read_buf.items[self.read_buf_pos..]);
                    self.read_buf.items.len -= self.read_buf_pos;
                    self.read_buf_pos = 0;
                }
                return owned;
            }
            // abort-aware:有 abort 时 poll 守卫阻塞 read——超时(100ms)回查 abort,被中断即返 error.Aborted。
            if (self.abort) |ab| {
                while (true) {
                    if (ab.isAborted()) return error.Aborted;
                    var pfds = [_]std.c.pollfd{.{ .fd = self.stdout_fd, .events = std.c.POLL.IN, .revents = 0 }};
                    const prc = std.c.poll(&pfds, 1, 100);
                    if (prc > 0) break; // 有数据可读 → 下面 read
                    if (prc < 0) break; // EINTR/错误 → 让 read 处理
                    // prc==0 超时 → 回查 abort 后再 poll
                }
            }
            // 读更多
            const n = std.c.read(self.stdout_fd, &chunk, chunk.len);
            if (n < 0) return error.ReadFailed;
            if (n == 0) {
                if (self.read_buf_pos >= self.read_buf.items.len) return error.Eof;
                // EOF 但缓冲区有残留，按"无换行的最后一行"返回
                const tail = try self.allocator.dupe(u8, self.read_buf.items[self.read_buf_pos..]);
                self.read_buf_pos = self.read_buf.items.len;
                return tail;
            }
            try self.read_buf.appendSlice(self.allocator, chunk[0..@as(usize, @intCast(n))]);
            // 轴A OOM 防线:单行(一条响应/resource)无换行时 read_buf 会无界增长。超上限断帧报错,
            // 而非把 GB 级单行 JSON 全堆进内存(恶意/超大 MCP resource)。
            if (self.read_buf.items.len - self.read_buf_pos > MAX_MCP_LINE_BYTES) return error.McpLineTooLarge;
        }
    }

    pub fn close(self: *StdioTransport) void {
        _ = std.c.close(self.stdin_fd);
        _ = std.c.close(self.stdout_fd);
        // 让子进程收到 EOF 后正常退出；给 1s 宽限再强杀
        const req = std.c.timespec{ .sec = 1, .nsec = 0 };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
        _ = std.c.kill(-self.pid, std.c.SIG.TERM);
        var status: c_int = 0;
        _ = std.c.waitpid(self.pid, &status, 0);
        self.read_buf.deinit(self.allocator);
    }
};

// ============================================================================
// Tests（用 cat 做最简 echo server，验证 send/recv 往返）
// ============================================================================

const testing = std.testing;

test "StdioTransport: cat echoes lines" {
    const allocator = testing.allocator;
    const argv = [_]?[*:0]const u8{ "/bin/cat", null };
    var t = try StdioTransport.spawn(allocator, argv[0..]);
    defer t.close();

    try t.send("hello");
    const line = try t.recvLine();
    defer allocator.free(line);
    try testing.expectEqualStrings("hello", line);
}

test "StdioTransport: multiple lines preserve order" {
    const allocator = testing.allocator;
    const argv = [_]?[*:0]const u8{ "/bin/cat", null };
    var t = try StdioTransport.spawn(allocator, argv[0..]);
    defer t.close();

    try t.send("one");
    try t.send("two");
    try t.send("three");
    const l1 = try t.recvLine();
    defer allocator.free(l1);
    const l2 = try t.recvLine();
    defer allocator.free(l2);
    const l3 = try t.recvLine();
    defer allocator.free(l3);
    try testing.expectEqualStrings("one", l1);
    try testing.expectEqualStrings("two", l2);
    try testing.expectEqualStrings("three", l3);
}

test "StdioTransport: EOF after close returns error" {
    const allocator = testing.allocator;
    const argv = [_]?[*:0]const u8{ "/bin/true", null };
    var t = try StdioTransport.spawn(allocator, argv[0..]);
    defer t.close();
    // /bin/true 立即退出，EOF
    const result = t.recvLine();
    try testing.expectError(error.Eof, result);
}
