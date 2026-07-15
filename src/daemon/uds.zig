//! **UDS + NDJSON 绑定(U10-B)** —— daemon 的第二条传输(本地进程间,gui/imui/语音 UI 首选)。
//! Unix domain socket(POSIX only;Windows 走 web 绑定),每行一个 JSON(NDJSON)。绑同一
//! SessionRegistry(经 server.zig 的 resolver 复用),与 WebServer 并存、共享各 session 的 journal/inbox。
//!
//! **协议(每行一 JSON 请求 → NDJSON 行回)**:
//!   {"op":"list"}                                  → {"sessions":["<id>",...]}
//!   {"op":"message","session":"<id>","text":"..."} → {"ok":true}(入 session inbox,driver 消费)
//!   {"op":"interrupt","session":"<id>"}            → {"ok":true|false}(生成期门,同 web /interrupt)
//!   {"op":"attach","session":"<id>","since":N}     → 从 seq N 起流式推 journal 行(每行原样 JSON),
//!                                                     直到 session 关停({"type":"session_closed"})或断连。
//!
//! **鉴权**:UDS 文件权限 0600(listenUnix chmod)——仅属主可连,无 CSRF/Origin 顾虑(非浏览器可达)。
//!
//! **生命周期(mirror WebServer)**:accept 线程 + per-conn detached 线程 + live_conns 计数;stop 先置
//! closing 再 close(listen_fd)唤 accept,join,drain live_conns(≤12s),unlink socket 文件。attach 流靠
//! journal.close(关停时 serve 先调)唤醒 waitSince → session_closed → 退出(与 SSE 同机制)。

const std = @import("std");
const net = @import("platform").net;
const log = @import("../util/log.zig");
const time = @import("../util/time.zig");
const server_mod = @import("../web/server.zig");
const SessionView = server_mod.SessionView;

pub const Deps = struct {
    /// 线程安全(连接线程并发分配)。
    allocator: std.mem.Allocator,
    /// 按 session id 解析 SessionView(复用 server.zig 的 resolver;UDS 只用 journal/inbox/abort/generating)。
    resolver: *const fn (ctx: *anyopaque, id: []const u8) ?SessionView,
    resolver_ctx: *anyopaque,
    /// `list` op:返回 NDJSON session 列表(caller-allocated,dispatch 用完 free)。null → 返 {"sessions":[]}。
    list_fn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) ?[]u8 = null,
    list_ctx: *anyopaque = undefined,
};

pub const UdsServer = struct {
    allocator: std.mem.Allocator,
    deps: Deps,
    listen_fd: net.Socket,
    path: []u8, // owned;stop 时 unlink
    accept_thread: std.Thread = undefined,
    /// 活跃连接线程数(detached)。stop 等它归零再 destroy self——否则连接线程还摸 self.deps 时已释放(UAF)。
    live_conns: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// stop 已发起:acceptLoop/handleConn 唯一的主动退出依据。
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn start(allocator: std.mem.Allocator, path: []const u8, deps: Deps) !*UdsServer {
        const fd = try net.listenUnix(path, 16);
        errdefer net.closeSocket(fd);
        const self = try allocator.create(UdsServer);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .deps = deps,
            .listen_fd = fd,
            .path = try allocator.dupe(u8, path),
        };
        errdefer allocator.free(self.path);
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    pub fn stop(self: *UdsServer) void {
        self.closing.store(true, .release);
        net.closeSocket(self.listen_fd); // 唤 accept 阻塞
        self.accept_thread.join();
        // drain 连接线程(≤12s):journal 已 close 会唤醒 attach,普通请求线程靠 recv 超时查 closing。
        var waited: usize = 0;
        while (self.live_conns.load(.acquire) > 0 and waited < 12_000) : (waited += 10) time.sleepMs(10);
        if (self.live_conns.load(.acquire) > 0)
            log.warn("uds", "stop: {d} conn thread(s) still live after 12s, leaking UdsServer", .{self.live_conns.load(.acquire)});
        net.unlinkUnixPath(self.path);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    fn acceptLoop(self: *UdsServer) void {
        while (true) {
            const conn = net.acceptConn(self.listen_fd) orelse {
                if (self.closing.load(.acquire)) return; // 主动 stop:listen_fd 已关
                time.sleepMs(10); // 兜底防 EBADF-未标记-closing 忙循环
                continue;
            };
            if (self.closing.load(.acquire)) {
                net.closeSocket(conn);
                return;
            }
            _ = self.live_conns.fetchAdd(1, .acq_rel);
            const t = std.Thread.spawn(.{}, handleConn, .{ self, conn }) catch {
                net.closeSocket(conn);
                _ = self.live_conns.fetchSub(1, .acq_rel);
                continue;
            };
            t.detach();
        }
    }

    fn handleConn(self: *UdsServer, conn: net.Socket) void {
        defer {
            net.closeSocket(conn);
            _ = self.live_conns.fetchSub(1, .acq_rel);
        }
        net.setRecvTimeoutMs(conn, 1000); // 周期醒来查 closing
        net.setSendTimeoutMs(conn, 10_000); // 慢客户端不钉死线程
        var accum: std.ArrayList(u8) = .empty;
        defer accum.deinit(self.allocator);
        var rbuf: [4096]u8 = undefined;
        while (!self.closing.load(.acquire)) {
            const n = net.recv(conn, &rbuf);
            if (n == 0) return; // 对端关闭
            if (n < 0) continue; // 超时/错误 → 回顶查 closing(超时是空闲常态)
            accum.appendSlice(self.allocator, rbuf[0..@intCast(n)]) catch return;
            while (std.mem.indexOfScalar(u8, accum.items, '\n')) |nl| {
                const took_over = self.dispatch(conn, accum.items[0..nl]);
                // 移除已消费行(含 \n):remainder 前移。
                const rest_start = nl + 1;
                const rest_len = accum.items.len - rest_start;
                std.mem.copyForwards(u8, accum.items[0..rest_len], accum.items[rest_start..]);
                accum.shrinkRetainingCapacity(rest_len);
                if (took_over) return; // attach 接管连接,不再读
            }
            if (accum.items.len > 1 << 20) return; // 单行 1MB 上限,防 OOM
        }
    }

    /// 处理一行 NDJSON 请求。返回 true = attach 接管连接(handleConn 停止读)。
    fn dispatch(self: *UdsServer, conn: net.Socket, line: []const u8) bool {
        if (std.mem.trim(u8, line, " \t\r").len == 0) return false; // 空行忽略
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch {
            _ = self.writeLine(conn, "{\"ok\":false,\"error\":\"bad json\"}");
            return false;
        };
        if (v != .object) {
            _ = self.writeLine(conn, "{\"ok\":false,\"error\":\"not object\"}");
            return false;
        }
        const op = getStr(v, "op") orelse {
            _ = self.writeLine(conn, "{\"ok\":false,\"error\":\"missing op\"}");
            return false;
        };

        if (std.mem.eql(u8, op, "list")) {
            if (self.deps.list_fn) |lf| {
                if (lf(self.deps.list_ctx, self.allocator)) |js| {
                    defer self.allocator.free(js);
                    _ = self.writeLine(conn, js);
                    return false;
                }
            }
            _ = self.writeLine(conn, "{\"sessions\":[]}");
            return false;
        }

        const sid = getStr(v, "session") orelse {
            _ = self.writeLine(conn, "{\"ok\":false,\"error\":\"missing session\"}");
            return false;
        };
        const sv = self.deps.resolver(self.deps.resolver_ctx, sid) orelse {
            _ = self.writeLine(conn, "{\"ok\":false,\"error\":\"unknown session\"}");
            return false;
        };

        if (std.mem.eql(u8, op, "message")) {
            const text = getStr(v, "text") orelse {
                _ = self.writeLine(conn, "{\"ok\":false,\"error\":\"missing text\"}");
                return false;
            };
            // 回显先于入队(附着的 attach 立刻见已提交消息)。inbox.push 内部 dupe,text(arena)传入即可。
            const echo = std.json.Stringify.valueAlloc(self.allocator, .{ .user_message = text }, .{}) catch null;
            if (echo) |e| {
                defer self.allocator.free(e);
                sv.journal.append(e);
            }
            if (!sv.inbox.push(text)) {
                _ = self.writeLine(conn, "{\"ok\":false,\"error\":\"queue push failed\"}");
                return false;
            }
            _ = self.writeLine(conn, "{\"ok\":true}");
            return false;
        }
        if (std.mem.eql(u8, op, "interrupt")) {
            // 生成期门(同 web /interrupt,S1):空闲期不打 abort,免吞下条消息。
            if (sv.generating) |g| {
                if (!g.load(.acquire)) {
                    _ = self.writeLine(conn, "{\"ok\":false,\"error\":\"not generating\"}");
                    return false;
                }
            }
            sv.abort.abort(.user_interrupt);
            _ = self.writeLine(conn, "{\"ok\":true}");
            return false;
        }
        if (std.mem.eql(u8, op, "attach")) {
            const since: usize = getUint(v, "since") orelse 0;
            self.doAttach(conn, sv, since);
            return true; // 连接交给 attach 流
        }
        _ = self.writeLine(conn, "{\"ok\":false,\"error\":\"unknown op\"}");
        return false;
    }

    /// attach:从 seq `since` 起流式推 journal 行(每行本身是 JSON)。mirror serveSse,去 HTTP 帧。
    /// 退出:session 关停(journal.close 唤醒 → session_closed)/ 写失败(死连接)/ closing。
    fn doAttach(self: *UdsServer, conn: net.Socket, sv: SessionView, since_in: usize) void {
        var since = since_in;
        while (!self.closing.load(.acquire)) {
            const batch = sv.journal.waitSince(self.allocator, since, 15_000) catch return;
            if (batch) |lines| {
                defer {
                    for (lines) |l| self.allocator.free(l);
                    self.allocator.free(lines);
                }
                for (lines) |l| {
                    if (!self.writeLine(conn, l)) return; // journal 行即 JSON,原样一行
                }
                since += lines.len;
            } else {
                if (sv.journal.isClosed()) {
                    _ = self.writeLine(conn, "{\"type\":\"session_closed\"}");
                    return;
                }
                if (!self.writeLine(conn, "{\"type\":\"keepalive\"}")) return; // 探死连接
            }
        }
    }

    /// 写一行(bytes + '\n'),处理部分写。返回 false = 连接死/写失败。
    fn writeLine(self: *UdsServer, conn: net.Socket, bytes: []const u8) bool {
        _ = self;
        return sendAll(conn, bytes) and sendAll(conn, "\n");
    }
};

fn sendAll(conn: net.Socket, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = net.send(conn, bytes[off..]);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v.object.get(key)) |x| {
        if (x == .string) return x.string;
    }
    return null;
}

fn getUint(v: std.json.Value, key: []const u8) ?usize {
    if (v.object.get(key)) |x| {
        switch (x) {
            .integer => |i| return if (i < 0) null else @intCast(i),
            else => return null,
        }
    }
    return null;
}

// ============================================================================
// Tests —— NDJSON dispatch 纯逻辑(getStr/getUint 解析)+ 真 UDS 往返在 e2e(daemon_serve_multi_e2e)。
// 注册在 main.zig 测试聚合器,否则 lazy analysis 整个跳过。
// ============================================================================
const testing = std.testing;

test "getStr/getUint 解析 NDJSON 字段" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"op\":\"attach\",\"session\":\"abc\",\"since\":7}", .{});
    try testing.expectEqualStrings("attach", getStr(v, "op").?);
    try testing.expectEqualStrings("abc", getStr(v, "session").?);
    try testing.expectEqual(@as(?usize, 7), getUint(v, "since"));
    try testing.expectEqual(@as(?[]const u8, null), getStr(v, "missing"));
    try testing.expectEqual(@as(?usize, null), getUint(v, "op")); // 非整数 → null
}
