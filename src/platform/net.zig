//! 可移植 TCP loopback socket。auth OAuth 回调 + --web HTTP server 共用。
//!
//! 为什么单独一层:Windows 的 socket 是 `SOCKET`(内核对象句柄,非 int fd),不能用
//! `_close/_read/_write`(那是文件 fd 的 CRT 层),必须走 `closesocket/recv/send`;
//! 且任何 socket 调用前必须 `WSAStartup`。POSIX 下 socket 就是普通 fd,read/write/close
//! 通用。两者接口差异被这层吸收,上层(auth/web)只见中立 `Socket` + 语义函数。
//!
//! 只支持我们需要的形态:127.0.0.1 loopback 的 listen/accept + connect,阻塞 IO +
//! 可选收/发超时。不做通用 sockets 库(YAGNI)。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const win = std.os.windows;
const ws2 = win.ws2_32; // 只用它的常量/struct(AF/SOCK/SOL/SO/IPPROTO/sockaddr);zig 0.16 未导出函数

// zig 0.16 std 的 ws2_32 只有常量与 struct,零函数 extern。socket 函数与句柄类型手 extern
// (与 process.zig 手 extern kernel32 同款)。SOCKET 是 UINT_PTR(内核对象句柄,非 fd)。
const SOCKET = usize;
const INVALID_SOCKET: SOCKET = ~@as(usize, 0);
const SOCKET_ERROR: i32 = -1;
// WSAStartup 只往里写、我们从不读,故用定长对齐字节块(避开 x86/x64 字段序差异)。x64 实际 ~408B。
const WSADATA = extern struct { data: [512]u8 align(8) = undefined };

// 嵌套 namespace:extern 符号名必须是真实 ws2_32 导出名(recv/send/...),但本文件已有同名
// 中立 wrapper(pub fn recv/send),故放进 `sys` 隔离,符号名不受 zig 侧标识符影响。
const sys = struct {
    extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSADATA) callconv(.winapi) i32;
    extern "ws2_32" fn socket(af: i32, socktype: i32, protocol: i32) callconv(.winapi) SOCKET;
    extern "ws2_32" fn bind(s: SOCKET, addr: *const anyopaque, namelen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.winapi) i32;
    extern "ws2_32" fn accept(s: SOCKET, addr: ?*anyopaque, addrlen: ?*i32) callconv(.winapi) SOCKET;
    extern "ws2_32" fn connect(s: SOCKET, addr: *const anyopaque, namelen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
    extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
    extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
    extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, optname: i32, optval: [*]const u8, optlen: i32) callconv(.winapi) i32;
    extern "ws2_32" fn getsockname(s: SOCKET, addr: *anyopaque, addrlen: *i32) callconv(.winapi) i32;
};

/// 中立 socket 句柄。POSIX=fd(c_int),Windows=SOCKET(UINT_PTR)。
pub const Socket = if (is_windows) SOCKET else c_int;

pub const Error = error{
    SocketFailed,
    BindFailed,
    ListenFailed,
    ConnectFailed,
    GetSocknameFailed,
    WsaStartupFailed,
};

pub const Listener = struct {
    sock: Socket,
    /// 实际绑定端口(port=0 时内核分配,getsockname 读回)。
    port: u16,
};

/// Windows 首次 socket 调用前必须 WSAStartup。refcounted 且可重入,进程生命周期不 cleanup。
/// 单次守卫防重复 startup 泄漏 refcount(启动期单线程,atomic 兜并发)。
var wsa_started = std.atomic.Value(bool).init(false);

fn ensureStartup() Error!void {
    if (!is_windows) return;
    if (wsa_started.swap(true, .acq_rel)) return; // 已 startup
    var data: WSADATA = undefined;
    // MAKEWORD(2,2) = 0x0202
    if (sys.WSAStartup(0x0202, &data) != 0) {
        wsa_started.store(false, .release);
        return error.WsaStartupFailed;
    }
}

fn isValid(s: Socket) bool {
    if (is_windows) return s != INVALID_SOCKET;
    return s >= 0;
}

/// 构造 127.0.0.1:port 的 sockaddr_in(网络字节序)。POSIX/Windows sockaddr.in 同布局。
fn loopbackAddr(port: u16) if (is_windows) ws2.sockaddr.in else std.c.sockaddr.in {
    return .{
        .family = if (is_windows) ws2.AF.INET else std.c.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0x0100007f, // 127.0.0.1,已是网络字节序
        .zero = [_]u8{0} ** 8,
    };
}

fn newTcp() Error!Socket {
    try ensureStartup();
    const s = if (is_windows)
        sys.socket(ws2.AF.INET, ws2.SOCK.STREAM, ws2.IPPROTO.TCP)
    else
        std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (!isValid(s)) return error.SocketFailed;
    return s;
}

fn setReuseAddr(s: Socket) void {
    const yes: c_int = 1;
    if (is_windows) {
        _ = sys.setsockopt(s, ws2.SOL.SOCKET, ws2.SO.REUSEADDR, @ptrCast(&yes), @sizeOf(c_int));
    } else {
        _ = std.c.setsockopt(s, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &yes, @sizeOf(c_int));
    }
}

/// 绑 127.0.0.1:port(0=内核分配)+ REUSEADDR + listen(backlog),读回真实端口。
pub fn listenLoopback(port: u16, backlog: u31) Error!Listener {
    const s = try newTcp();
    errdefer closeSocket(s);
    setReuseAddr(s);

    var addr = loopbackAddr(port);
    if (is_windows) {
        if (sys.bind(s, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
        if (sys.listen(s, backlog) != 0) return error.ListenFailed;
    } else {
        if (std.c.bind(s, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) return error.BindFailed;
        if (std.c.listen(s, backlog) < 0) return error.ListenFailed;
    }

    var bound = loopbackAddr(0);
    if (is_windows) {
        var blen: i32 = @sizeOf(@TypeOf(bound));
        if (sys.getsockname(s, @ptrCast(&bound), &blen) != 0) return error.GetSocknameFailed;
    } else {
        var blen: std.c.socklen_t = @sizeOf(@TypeOf(bound));
        if (std.c.getsockname(s, @ptrCast(&bound), &blen) < 0) return error.GetSocknameFailed;
    }
    return .{ .sock = s, .port = std.mem.bigToNative(u16, bound.port) };
}

/// 阻塞 accept 一个连接。出错返 null(调用方据自身 closing 标志决定退出 vs 重试)。
pub fn acceptConn(listener: Socket) ?Socket {
    if (is_windows) {
        const c = sys.accept(listener, null, null);
        if (c == INVALID_SOCKET) return null;
        return c;
    } else {
        var caddr: std.c.sockaddr = undefined;
        var alen: std.c.socklen_t = @sizeOf(@TypeOf(caddr));
        const c = std.c.accept(listener, &caddr, &alen);
        if (c < 0) return null;
        return c;
    }
}

/// 连 127.0.0.1:port。
pub fn connectLoopback(port: u16) Error!Socket {
    const s = try newTcp();
    errdefer closeSocket(s);
    var addr = loopbackAddr(port);
    if (is_windows) {
        if (sys.connect(s, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.ConnectFailed;
    } else {
        if (std.c.connect(s, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) return error.ConnectFailed;
    }
    return s;
}

/// 收。返回读到字节数;0=对端关闭;<0=错误(含超时)。语义同 POSIX read。
pub fn recv(s: Socket, buf: []u8) isize {
    if (is_windows) {
        const n = sys.recv(s, buf.ptr, @intCast(buf.len), 0);
        if (n == SOCKET_ERROR) return -1;
        return n;
    }
    return std.c.read(s, buf.ptr, buf.len);
}

/// 发。返回写出字节数;<=0=错误。语义同 POSIX write。
pub fn send(s: Socket, buf: []const u8) isize {
    if (is_windows) {
        const n = sys.send(s, buf.ptr, @intCast(buf.len), 0);
        if (n == SOCKET_ERROR) return -1;
        return n;
    }
    return std.c.write(s, buf.ptr, buf.len);
}

pub fn closeSocket(s: Socket) void {
    if (is_windows) {
        _ = sys.closesocket(s);
    } else {
        _ = std.c.close(s);
    }
}

/// 收超时。POSIX=timeval;Windows=DWORD 毫秒(关键差异:同 optname 不同参数类型)。
pub fn setRecvTimeoutMs(s: Socket, ms: u32) void {
    setTimeoutMs(s, .recv, ms);
}

/// 发超时(SSE 长写不许被卡死客户端钉住线程)。
pub fn setSendTimeoutMs(s: Socket, ms: u32) void {
    setTimeoutMs(s, .send, ms);
}

// optname 在 POSIX 是 u32、Windows 是 i32,类型不一,故不跨平台传参,分支内各取常量。
fn setTimeoutMs(s: Socket, which: enum { recv, send }, ms: u32) void {
    if (is_windows) {
        const opt: i32 = switch (which) {
            .recv => ws2.SO.RCVTIMEO,
            .send => ws2.SO.SNDTIMEO,
        };
        const timeout: u32 = ms; // Windows SO_*TIMEO 取 DWORD 毫秒
        _ = sys.setsockopt(s, ws2.SOL.SOCKET, opt, @ptrCast(&timeout), @sizeOf(u32));
    } else {
        const opt: u32 = switch (which) {
            .recv => std.c.SO.RCVTIMEO,
            .send => std.c.SO.SNDTIMEO,
        };
        const tv = std.c.timeval{
            .sec = @intCast(ms / 1000),
            .usec = @intCast((ms % 1000) * 1000),
        };
        _ = std.c.setsockopt(s, std.c.SOL.SOCKET, opt, &tv, @sizeOf(std.c.timeval));
    }
}

// ============================================================================
// Tests(POSIX 真回环:listen→connect→send→recv→close 全链)
// ============================================================================

const testing = std.testing;

// 注意:测试体**不**加 `if (is_windows) return` 早退——那会让 windows 分支因懒分析被
// 整个跳过(W5 rng 同款陷阱:标准库 lazy analysis 不分析无 reachable caller 的分支)。
// 保留对 listenLoopback/recv/send 的引用,`zig test --test-no-exec -target windows` 才会
// 真编译 windows 分支抓类型错;POSIX `zig test` 则真执行回环。
test "loopback listen/connect/send/recv roundtrip" {
    const listener = try listenLoopback(0, 4);
    defer closeSocket(listener.sock);
    try testing.expect(listener.port != 0);

    const client = try connectLoopback(listener.port);
    defer closeSocket(client);

    const conn = acceptConn(listener.sock) orelse return error.AcceptFailed;
    defer closeSocket(conn);

    const msg = "ping";
    try testing.expectEqual(@as(isize, 4), send(client, msg));

    var buf: [16]u8 = undefined;
    const n = recv(conn, &buf);
    try testing.expectEqual(@as(isize, 4), n);
    try testing.expectEqualSlices(u8, msg, buf[0..@intCast(n)]);
}

test "setRecvTimeout makes blocking recv return on idle" {
    const listener = try listenLoopback(0, 4);
    defer closeSocket(listener.sock);
    const client = try connectLoopback(listener.port);
    defer closeSocket(client);
    const conn = acceptConn(listener.sock) orelse return error.AcceptFailed;
    defer closeSocket(conn);

    setRecvTimeoutMs(conn, 50); // 50ms 后无数据应超时返回 <0
    var buf: [8]u8 = undefined;
    const n = recv(conn, &buf); // 对端不发,应超时
    try testing.expect(n < 0);
}
