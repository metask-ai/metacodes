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
const process = @import("platform").process;
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const Capture = @import("../core/tool_result_artifact.zig").Capture;
const util_time = @import("../util/time.zig");

/// 单行(一条 JSON-RPC 响应/resource)字节上限(轴A OOM 防线)。MCP resource 可合法较大(文件内容),
/// 64MB 对真实响应绰绰;超此值必是无 `\n` 的病态/恶意巨型行 → 断帧报错 error.McpLineTooLarge。
const MAX_MCP_LINE_BYTES: usize = 64 * 1024 * 1024;

pub const StdioTransport = struct {
    child: process.PipeChild,
    read_buf: std.ArrayList(u8),
    read_buf_pos: usize = 0,
    allocator: std.mem.Allocator,
    /// 可选中断信号(callTool 期设);null=纯阻塞(如 initialize 短握手)。
    abort: ?*const AbortSignal = null,
    /// Optional absolute deadline (`util_time.nowMs()` scale). A child that
    /// accepts a request and then emits no newline would otherwise block the
    /// caller forever; with a deadline the read fails instead. `null` keeps the
    /// original blocking behaviour.
    deadline_ms: ?i64 = null,

    /// spawn 子进程。argv 以 null 结尾，argv[0] 是绝对路径或在 PATH 内。
    /// 走可移植 platform/process.spawnPipes（POSIX fork+pipe / Windows CreateProcessW+CreatePipe）。
    pub fn spawn(allocator: std.mem.Allocator, argv: []const ?[*:0]const u8) !StdioTransport {
        const child = process.spawnPipes(argv, false, null) catch return error.SpawnFailed;
        return .{
            .child = child,
            .read_buf = .empty,
            .allocator = allocator,
        };
    }

    /// 写一行 JSON。自动追加 '\n'。
    pub fn send(self: *StdioTransport, json: []const u8) !void {
        var total: usize = 0;
        while (total < json.len) {
            const n = self.child.write(json[total..]);
            if (n <= 0) return error.WriteFailed;
            total += @as(usize, @intCast(n));
        }
        if (self.child.write("\n") <= 0) return error.WriteFailed;
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
            // abort-aware:有 abort 时 pollReadable 守卫阻塞 read——超时(100ms)回查 abort,中断即返 error.Aborted。
            // 可移植:POSIX poll / Windows PeekNamedPipe(见 platform/process.PipeChild.pollReadable)。
            if (self.abort != null or self.deadline_ms != null) {
                while (true) {
                    if (self.abort) |ab| {
                        if (ab.isAborted()) return error.Aborted;
                    }
                    if (self.deadline_ms) |deadline| {
                        if (util_time.nowMs() >= deadline) return error.Timeout;
                    }
                    if (self.child.pollReadable(100)) break; // 有数据/EOF/错误 → 下面 read
                    // 超时 → 回查 abort/deadline 后再 poll
                }
            }
            // 读更多
            const n = self.child.read(&chunk);
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

    /// Receive one NDJSON frame directly into a kernel-private capture. Bytes
    /// already buffered by a preceding control response are drained first;
    /// bytes after the terminating newline remain available to the next frame.
    /// The line itself is never assembled in `read_buf`.
    pub fn recvLineCapture(self: *StdioTransport, capture: *Capture) !void {
        if (self.read_buf_pos < self.read_buf.items.len) {
            if (std.mem.indexOfScalarPos(u8, self.read_buf.items, self.read_buf_pos, '\n')) |nl| {
                try capture.write(self.read_buf.items[self.read_buf_pos..nl]);
                self.read_buf_pos = nl + 1;
                self.compactReadBuffer();
                return;
            }
            try capture.write(self.read_buf.items[self.read_buf_pos..]);
            self.read_buf.clearRetainingCapacity();
            self.read_buf_pos = 0;
        }

        var chunk: [32 * 1024]u8 = undefined;
        while (true) {
            if (self.abort) |ab| {
                while (true) {
                    if (ab.isAborted()) return error.Aborted;
                    if (self.child.pollReadable(100)) break;
                }
            }
            const n = self.child.read(&chunk);
            if (n < 0) return error.ReadFailed;
            if (n == 0) {
                if (capture.bytes == 0) return error.Eof;
                return;
            }
            const bytes = chunk[0..@as(usize, @intCast(n))];
            if (std.mem.indexOfScalar(u8, bytes, '\n')) |nl| {
                try capture.write(bytes[0..nl]);
                if (nl + 1 != bytes.len)
                    try self.read_buf.appendSlice(self.allocator, bytes[nl + 1 ..]);
                return;
            }
            try capture.write(bytes);
        }
    }

    fn compactReadBuffer(self: *StdioTransport) void {
        if (self.read_buf_pos == self.read_buf.items.len) {
            self.read_buf.clearRetainingCapacity();
            self.read_buf_pos = 0;
        } else if (self.read_buf_pos > 4096) {
            std.mem.copyForwards(u8, self.read_buf.items, self.read_buf.items[self.read_buf_pos..]);
            self.read_buf.items.len -= self.read_buf_pos;
            self.read_buf_pos = 0;
        }
    }

    pub fn close(self: *StdioTransport) void {
        self.child.closeStdin(); // EOF → 子进程正常退出
        self.child.closeStdout();
        self.child.terminate(); // kill 整组 + 回收（closeStdin 的 EOF 已让多数 server 自退，此为兜底）
        self.read_buf.deinit(self.allocator);
    }
};

// ============================================================================
// Tests（用 cat 做最简 echo server，验证 send/recv 往返）
// ============================================================================

const testing = std.testing;

test "StdioTransport: cat echoes lines" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
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
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // POSIX 专属测试脚手架(spawn 命令/shell hook/系统文件/Seatbelt)
    const allocator = testing.allocator;
    const argv = [_]?[*:0]const u8{ "/bin/true", null };
    var t = try StdioTransport.spawn(allocator, argv[0..]);
    defer t.close();
    // /bin/true 立即退出，EOF
    const result = t.recvLine();
    try testing.expectError(error.Eof, result);
}
