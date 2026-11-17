//! **UDS + NDJSON 绑定(U10-B)** —— daemon 的第二条传输(本地进程间,gui/imui/语音 UI 首选)。
//! Unix domain socket(POSIX only;Windows 走 web 绑定),每行一个 JSON(NDJSON)。绑同一
//! SessionRegistry(经 server.zig 的 resolver 复用),与 WebServer 并存、共享各 session 的 journal/inbox。
//!
//! **协议(每行一 JSON 请求 → NDJSON 行回)**:
//!   {"op":"list"}                                  → {"sessions":["<id>",...]}
//!   {"op":"message","session":"<id>","text":"...","model"?:"...","permission_mode"?:"..."}
//!                                                  → {"ok":true}(入 session inbox,driver 消费;
//!                                                     字段与校验同 HTTP POST /message,见 web/submission.zig)
//!   {"op":"interrupt","session":"<id>"}            → {"ok":true|false}(生成期门,同 web /interrupt)
//!   {"op":"respond","session":"<id>","id":N,...}   → {"ok":true} | {"ok":false,"error":"..."}。
//!                                                     回答挂起的 ui_request N,同 HTTP POST /respond:
//!                                                     这一行本身就是答案(choice/answers/result 与
//!                                                     路由字段并列;wire.parseResponse 只读答案字段)。
//!                                                     stale/未知 id → {"ok":false,"error":"no pending
//!                                                     request with this id"}(即 HTTP 的 409)。
//!   {"op":"capabilities","session":"<id>","v":1,"type":"capabilities",...}
//!                                                  → 应答行:capabilities_accepted(同时落 journal,
//!                                                     每个 attach 读者可见)或 capabilities_refused。
//!                                                     这一行就是 wire §2 的能力帧本体(v/type 必填),
//!                                                     外加路由字段(parseCapabilities 忽略之),
//!                                                     同 HTTP POST /capabilities。
//!   {"op":"attach","session":"<id>","since":N}     → 从 seq N 起流式推 journal 行(每行原样 JSON),
//!                                                     直到 session 关停({"type":"session_closed"})或断连。
//!
//! **鉴权**:UDS 文件权限 0600(listenUnix chmod)——仅属主可连,无 CSRF/Origin 顾虑(非浏览器可达)。
//!
//! **生命周期(mirror WebServer)**:accept 线程 + per-conn detached 线程 + live_conns 计数;stop 先置
//! closing 后 shutdown+close(listen_fd) 唤 accept，再 join、drain live_conns(≤12s)、unlink socket 文件。attach 流靠
//! journal.close(destroy 与关停都先调)唤醒 waitSince → session_closed → 退出(与 SSE 同机制)。
//!
//! **Leases (#254).** Every op that names a session resolves it to a
//! `server.Lease` and releases it exactly once, by `defer` in `dispatch`: a
//! one-line op holds it for that line, `attach` for the whole attachment.
//! Destroying a session over HTTP never waits for an attachment; it closes the
//! journal, the attachment ends with `session_closed`, and the lease comes
//! back.

const std = @import("std");
const net = @import("platform").net;
const log = @import("../util/log.zig");
const time = @import("../util/time.zig");
const server_mod = @import("../web/server.zig");
const submission_mod = @import("../web/submission.zig");
const wire = @import("../core/protocol/wire.zig");
const SessionView = server_mod.SessionView;
const Lease = server_mod.Lease;

pub const Deps = struct {
    /// 线程安全(连接线程并发分配)。
    allocator: std.mem.Allocator,
    /// 按 session id 租用 session(复用 server.zig 的 resolver;UDS 用 journal/inbox/abort/
    /// generating/web_backend——respond/capabilities 直达每会话 WebBackend,与 HTTP 同一语义源)。
    resolver: *const fn (ctx: *anyopaque, id: []const u8) ?Lease,
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
        self.accept_thread = try @import("platform").thread.spawn(.full, acceptLoop, .{self});
        return self;
    }

    pub fn stop(self: *UdsServer) void {
        _ = self.stopDrained();
    }

    /// `stop`, reporting whether every connection thread finished (see
    /// `WebServer.stopDrained`).
    pub fn stopDrained(self: *UdsServer) bool {
        self.closing.store(true, .release);
        net.shutdownSocket(self.listen_fd); // Linux:跨线程 close 不保证唤醒已阻塞的 accept
        net.closeSocket(self.listen_fd);
        self.accept_thread.join();
        // drain 连接线程(≤12s):journal 已 close 会唤醒 attach,普通请求线程靠 recv 超时查 closing。
        var waited: usize = 0;
        while (self.live_conns.load(.acquire) > 0 and waited < 12_000) : (waited += 10) time.sleepMs(10);
        if (self.live_conns.load(.acquire) > 0) {
            // 兜底(理论上不达:12s > 1s recv 超时)。存活连接线程仍读 self.closing/self.deps,
            // free/destroy 会 UAF → 泄漏 self(对齐 web/server.zig stop),and report it so the
            // caller keeps its deps alive too。socket 文件仍 unlink 不残留。
            log.warn("uds", "stop: {d} conn thread(s) still live after 12s, leaking UdsServer", .{self.live_conns.load(.acquire)});
            net.unlinkUnixPath(self.path);
            return false;
        }
        net.unlinkUnixPath(self.path);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
        return true;
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
            // 连接数上限(同 web/server.zig MAX_CONNS):每连接 1 线程,无界即 slow-loris。
            if (self.live_conns.load(.acquire) >= @import("../web/server.zig").MAX_CONNS) {
                log.warn("uds", "connection limit reached, rejecting", .{});
                net.closeSocket(conn);
                continue;
            }
            _ = self.live_conns.fetchAdd(1, .acq_rel);
            const t = @import("platform").thread.spawn(.full, handleConn, .{ self, conn }) catch {
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
            if (n < 0) {
                if (net.recvRetriable()) continue; // 超时(EAGAIN)/EINTR:回顶查 closing(空闲常态)
                return; // 真 socket 错误:关连接(Linus-A:不把真错误当超时忙旋)
            }
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
        const lease = self.deps.resolver(self.deps.resolver_ctx, sid) orelse {
            _ = self.writeLine(conn, "{\"ok\":false,\"error\":\"unknown session\"}");
            return false;
        };
        defer lease.release(); // after the op, and for attach after the whole attachment
        const sv = lease.view;

        if (std.mem.eql(u8, op, "message")) {
            // Same fields and checks as HTTP POST /message: a bad field is refused before
            // anything is queued, and the driver journals user_message when the turn starts.
            // inbox.push copies, so the arena-backed request can go in as is.
            const request = submission_mod.parseObject(v.object) catch |err| {
                var reply_buf: [192]u8 = undefined;
                const reply = std.fmt.bufPrint(&reply_buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{submission_mod.reason(err)}) catch "{\"ok\":false}";
                _ = self.writeLine(conn, reply);
                return false;
            };
            if (!sv.inbox.push(request)) {
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
        if (std.mem.eql(u8, op, "respond")) {
            // Answer the pending UI request, as HTTP `POST /s/<id>/respond` does. The
            // line itself is the answer: `wire.parseResponse` reads `choice`/`answers`/
            // `result` beside the routing fields it ignores, and a malformed answer is
            // never a grant (the request closes `malformed` with the safe answer). A
            // stale or unknown id is refused, so a reconnecting client cannot answer a
            // dialog that is no longer the open one.
            const id = getUint(v, "id") orelse {
                _ = self.writeLine(conn, "{\"ok\":false,\"error\":\"missing id\"}");
                return false;
            };
            if (sv.web_backend.respond(@intCast(id), line)) {
                _ = self.writeLine(conn, "{\"ok\":true}");
            } else {
                _ = self.writeLine(conn, "{\"ok\":false,\"error\":\"no pending request with this id\"}");
            }
            return false;
        }
        if (std.mem.eql(u8, op, "capabilities")) {
            // Declare frontend capabilities, as HTTP `POST /s/<id>/capabilities` does.
            // The line is the wire §2 capability frame itself (`v`/`type` and the kind
            // lists; `parseCapabilities` ignores the routing fields), and the reply is
            // the same acknowledgement line HTTP answers with: `capabilities_accepted`
            // (which `declareCapabilities` also journals, so every attached reader sees
            // the declaration take effect) or `capabilities_refused`. A refused frame
            // installs nothing.
            const accepted = sv.web_backend.declareCapabilities(line) catch |err| switch (err) {
                error.OutOfMemory => {
                    _ = self.writeLine(conn, "{\"ok\":false,\"error\":\"out of memory\"}");
                    return false;
                },
                else => |refusal| {
                    const refused = wire.writeCapabilitiesRefused(self.allocator, refusal) catch {
                        _ = self.writeLine(conn, "{\"ok\":false,\"error\":\"out of memory\"}");
                        return false;
                    };
                    defer self.allocator.free(refused);
                    _ = self.writeLine(conn, refused);
                    return false;
                },
            };
            defer sv.web_backend.allocator.free(accepted);
            _ = self.writeLine(conn, accepted);
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
