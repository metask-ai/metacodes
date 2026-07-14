//! LSP stdio 传输:spawn language server 子进程,通过 stdin/stdout 交换 JSON-RPC 消息。
//!
//! 与 MCP 传输(src/mcp/transport_stdio.zig,行分隔)的区别:LSP 用 **Content-Length header 帧**
//! (`Content-Length: N\r\n\r\n<N bytes body>`,对齐 LSP 规范 base protocol),而非 `\n` 分隔。
//! spawn 机制(fork+dup2+setpgid+killpg 清理)与 MCP/hook runner 同款——POSIX 子进程标准姿势。
//!
//! **异步性**:LSP server 会**主动推送** notification(尤其 `textDocument/publishDiagnostics`),
//! 与 request 的 response 交织。故 readMessage 只负责"读一条完整帧",分发(response by id vs
//! notification by method)由上层 client 处理。abort-aware poll 守卫防阻塞 agent loop。
const std = @import("std");
const process = @import("platform").process;

/// 中立 abort 检查(LSP 子系统自包含,不依赖 core 内部;集成时由 core.AbortSignal 适配)。
pub const AbortCheck = struct {
    ctx: *anyopaque,
    isAbortedFn: *const fn (*anyopaque) bool,
    pub fn isAborted(self: AbortCheck) bool {
        return self.isAbortedFn(self.ctx);
    }
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    child: process.PipeChild,
    read_buf: std.ArrayList(u8) = .empty,
    read_pos: usize = 0,
    abort: ?AbortCheck = null,

    /// spawn language server。argv null 结尾,argv[0] 绝对路径或在 PATH。走可移植 platform/process.spawnPipes
    /// (server stderr → null/NUL:M1 防 chatty server 日志糊花 TUI;inherit_env=true:server 需 PATH/HOME 找 node/python)。
    pub fn spawn(allocator: std.mem.Allocator, argv: []const ?[*:0]const u8) !Transport {
        const child = process.spawnPipes(argv, true) catch return error.SpawnFailed;
        return .{ .allocator = allocator, .child = child };
    }

    /// 发一条 JSON-RPC 消息(自动加 Content-Length header)。
    pub fn sendMessage(self: *Transport, json: []const u8) !void {
        var hdr_buf: [64]u8 = undefined;
        const hdr = try std.fmt.bufPrint(&hdr_buf, "Content-Length: {d}\r\n\r\n", .{json.len});
        try self.writeAll(hdr);
        try self.writeAll(json);
    }

    fn writeAll(self: *Transport, bytes: []const u8) !void {
        var total: usize = 0;
        while (total < bytes.len) {
            const n = self.child.write(bytes[total..]);
            if (n <= 0) return error.WriteFailed;
            total += @intCast(n);
        }
    }

    /// header 块最大(无 `\r\n\r\n` 的洪水防护);body 最大(hostile/buggy server 发超大
    /// Content-Length 却不给够 body → 无限缓冲 OOM 的防护)。LSP 消息正常 KB 级,64M 足够宽。
    const MAX_HEADER_BYTES: usize = 8 * 1024;
    const MAX_BODY_BYTES: usize = 64 * 1024 * 1024;

    /// 读一条完整 JSON-RPC 消息体(owned bytes,调用方 free)。解析 Content-Length header +
    /// 读足 body。EOF 且无残留 → error.Eof。abort → error.Aborted。坏帧/超限 → error。
    pub fn readMessage(self: *Transport) ![]u8 {
        while (true) {
            // 1) header 完整?找 \r\n\r\n。
            if (std.mem.indexOfPos(u8, self.read_buf.items, self.read_pos, "\r\n\r\n")) |hdr_end| {
                const header = self.read_buf.items[self.read_pos..hdr_end];
                const content_len = parseContentLength(header) orelse {
                    // 坏 header(无 Content-Length):跳过它,继续找下一条。防坏帧卡死。
                    self.read_pos = hdr_end + 4;
                    continue;
                };
                if (content_len > MAX_BODY_BYTES) return error.MessageTooLarge; // DoS 防护
                const body_start = hdr_end + 4;
                // 2) body 够长?用减法侧比较避免 body_start+content_len 溢出。
                if (self.read_buf.items.len - body_start >= content_len) {
                    const body = try self.allocator.dupe(u8, self.read_buf.items[body_start .. body_start + content_len]);
                    self.read_pos = body_start + content_len;
                    self.compact();
                    return body;
                }
            } else if (self.read_buf.items.len - self.read_pos > MAX_HEADER_BYTES) {
                // 迟迟找不到 \r\n\r\n 且 header 区已超限 → 流损坏,bail(而非无限缓冲)。
                return error.HeaderTooLarge;
            }
            // 3) 读更多(abort-aware poll)。
            try self.fillMore();
        }
    }

    /// 读一批字节进 read_buf。EOF → error.Eof;abort → error.Aborted。
    fn fillMore(self: *Transport) !void {
        if (self.abort) |ab| {
            while (true) {
                if (ab.isAborted()) return error.Aborted;
                if (self.child.pollReadable(100)) break; // 有数据/EOF/错误 → 下面 read;超时回查 abort
            }
        }
        var chunk: [8192]u8 = undefined;
        const n = self.child.read(&chunk);
        if (n < 0) return error.ReadFailed;
        if (n == 0) return error.Eof;
        try self.read_buf.appendSlice(self.allocator, chunk[0..@intCast(n)]);
    }

    /// 压缩 read_buf(已消费前缀丢弃),防无限增长。
    fn compact(self: *Transport) void {
        if (self.read_pos == 0) return;
        if (self.read_pos >= self.read_buf.items.len) {
            self.read_buf.clearRetainingCapacity();
            self.read_pos = 0;
            return;
        }
        std.mem.copyForwards(u8, self.read_buf.items, self.read_buf.items[self.read_pos..]);
        self.read_buf.items.len -= self.read_pos;
        self.read_pos = 0;
    }

    /// 终止子进程(SIGTERM→短等→WNOHANG 查→顽固则 SIGKILL→阻塞收尸)。**不动 stdout_fd/read_buf**
    /// ——那两个还被 reader 线程用着;子进程死后其 stdout 关闭 → reader 的 read 返 EOF 自然退出。
    /// 调用顺序(client.shutdown):terminate() → join(reader) → deinit()。
    pub fn terminate(self: *Transport) void {
        self.child.closeStdin(); // 关 stdin:良性 server 收 EOF 自退
        self.child.terminate(); // SIGTERM→等→WNOHANG→顽固 SIGKILL→收尸（见 PipeChild.terminate）
    }

    /// 关 stdout + 释放 read_buf。**必须在 reader 线程 join 之后调**(否则 UAF)。
    pub fn deinit(self: *Transport) void {
        self.child.closeStdout();
        self.read_buf.deinit(self.allocator);
    }

    /// 无独立 reader 线程时的一步式关闭(transport 单元测试用):terminate + deinit。
    pub fn close(self: *Transport) void {
        self.terminate();
        self.deinit();
    }
};

/// 从 header 块(不含结尾 \r\n\r\n)解析 Content-Length 值。大小写不敏感 header 名。
fn parseContentLength(header: []const u8) ?usize {
    var it = std.mem.splitSequence(u8, header, "\r\n");
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
            return std.fmt.parseInt(usize, val, 10) catch null;
        }
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "parseContentLength: 大小写不敏感 + 多 header" {
    try testing.expectEqual(@as(?usize, 42), parseContentLength("Content-Length: 42"));
    try testing.expectEqual(@as(?usize, 7), parseContentLength("content-length:7"));
    try testing.expectEqual(@as(?usize, 100), parseContentLength("Content-Type: x\r\nContent-Length: 100"));
    try testing.expectEqual(@as(?usize, null), parseContentLength("Content-Type: application/json"));
    try testing.expectEqual(@as(?usize, null), parseContentLength("Content-Length: notanumber"));
}

test "Transport: cat 回显 Content-Length 帧往返" {
    const a = testing.allocator;
    // cat 把我们写的字节原样回吐(含 header)。我们发一条 framed 消息,cat 回吐同样字节,
    // readMessage 解析出 body。
    const argv = [_]?[*:0]const u8{ "/bin/cat", null };
    var t = try Transport.spawn(a, argv[0..]);
    defer t.close();

    try t.sendMessage("{\"jsonrpc\":\"2.0\",\"id\":1}");
    const body = try t.readMessage();
    defer a.free(body);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1}", body);
}

test "Transport: 超大 Content-Length → MessageTooLarge(DoS 防护)" {
    const a = testing.allocator;
    // 子进程只吐一个超大 Content-Length header,不给 body → 应立即 MessageTooLarge,不无限缓冲。
    const argv = [_]?[*:0]const u8{ "/bin/sh", "-c", "printf 'Content-Length: 99999999999\\r\\n\\r\\n'", null };
    var t = try Transport.spawn(a, argv[0..]);
    defer t.close();
    try testing.expectError(error.MessageTooLarge, t.readMessage());
}

test "Transport: 超长无终止 header → HeaderTooLarge(不无限缓冲)" {
    const a = testing.allocator;
    // 吐 >8KB 无 \r\n\r\n 的垃圾 → HeaderTooLarge。
    const argv = [_]?[*:0]const u8{ "/bin/sh", "-c", "yes X | head -c 20000", null };
    var t = try Transport.spawn(a, argv[0..]);
    defer t.close();
    try testing.expectError(error.HeaderTooLarge, t.readMessage());
}

test "Transport: 多条 framed 消息保序 + 粘包切分" {
    const a = testing.allocator;
    const argv = [_]?[*:0]const u8{ "/bin/cat", null };
    var t = try Transport.spawn(a, argv[0..]);
    defer t.close();

    try t.sendMessage("aa");
    try t.sendMessage("bbbb");
    try t.sendMessage("c");
    const m1 = try t.readMessage();
    defer a.free(m1);
    const m2 = try t.readMessage();
    defer a.free(m2);
    const m3 = try t.readMessage();
    defer a.free(m3);
    try testing.expectEqualStrings("aa", m1);
    try testing.expectEqualStrings("bbbb", m2);
    try testing.expectEqualStrings("c", m3);
}
