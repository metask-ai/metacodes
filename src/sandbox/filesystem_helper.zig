//! One bounded open request on a private inherited Unix socket (stdin).
//! Only the already-confined helper opens paths or creates directories. The
//! returned SCM_RIGHTS descriptor is the capability checked by the OS; the
//! parent never reopens its pathname. No file bytes cross this protocol.
const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const time = @import("../util/time.zig");

pub const supported = builtin.os.tag == .linux or builtin.os.tag == .macos;
pub const magic: u32 = 0x3146534d; // MSF1, little endian
pub const header_size = 20;
pub const response_size = 8;
pub const timeout_ms = 15_000;

pub const Request = struct {
    path: []const u8,
    flags: pfs.O,
    mode: c_uint,
    mkdir_parents: bool = false,
};

// libc's ancillary ABI differs on Darwin (4-byte alignment/length) and Linux
// (size_t). Keep it explicit rather than importing platform C headers at build.
const ControlLen = if (builtin.os.tag == .macos) u32 else usize;
const IovLen = if (builtin.os.tag == .macos) c_int else usize;
const Iovec = extern struct { base: [*]u8, len: usize };
const Message = extern struct {
    name: ?*anyopaque = null,
    namelen: u32 = 0,
    iov: [*]Iovec,
    iovlen: IovLen = 1,
    control: ?*anyopaque,
    controllen: ControlLen,
    flags: c_int = 0,
};
const Control = extern struct { len: ControlLen, level: c_int, kind: c_int };
const control_align = @sizeOf(ControlLen);
const control_data = std.mem.alignForward(usize, @sizeOf(Control), control_align);
const control_size = control_data + std.mem.alignForward(usize, @sizeOf(c_int), control_align);
const sol_socket: c_int = if (builtin.os.tag == .macos) 0xffff else 1;
extern "c" fn sendmsg(fd: c_int, msg: *const Message, flags: c_int) isize;
extern "c" fn recvmsg(fd: c_int, msg: *Message, flags: c_int) isize;

pub fn wait(fd: c_int, events: i16) !void {
    return waitUntil(fd, events, time.nowMs() + timeout_ms);
}

fn waitUntil(fd: c_int, events: i16, deadline: i64) !void {
    var fds = [_]std.c.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    while (true) {
        const remaining = deadline - time.nowMs();
        if (remaining <= 0) return error.SandboxHelperTimeout;
        const n = std.c.poll(&fds, 1, @intCast(@min(remaining, timeout_ms)));
        if (n < 0 and pfs.lastErrnoIs(.INTR)) continue;
        if (n <= 0) return error.SandboxHelperTimeout;
        if (fds[0].revents & events == 0) return error.SandboxHelperProtocol;
        return;
    }
}

fn transfer(fd: c_int, bytes: []u8, writing: bool) !void {
    const deadline = time.nowMs() + timeout_ms;
    var pos: usize = 0;
    while (pos < bytes.len) {
        try waitUntil(fd, if (writing) std.c.POLL.OUT else std.c.POLL.IN, deadline);
        const n = if (writing) std.c.send(fd, bytes[pos..].ptr, bytes.len - pos, if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0) else std.c.read(fd, bytes[pos..].ptr, bytes.len - pos);
        if (n < 0 and pfs.lastErrnoIs(.INTR)) continue;
        if (n <= 0) return error.SandboxHelperProtocol;
        pos += @intCast(n);
    }
}

pub fn sendRequest(socket: c_int, req: Request) !void {
    if (req.path.len == 0 or req.path.len >= std.fs.max_path_bytes or
        req.path[0] != '/' or std.mem.indexOfScalar(u8, req.path, 0) != null)
        return error.InvalidSandboxPath;
    var header: [header_size]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], magic, .little);
    std.mem.writeInt(u32, header[4..8], @intCast(req.path.len), .little);
    const flags: u32 = @as(u32, @intFromEnum(req.flags.ACCMODE)) |
        (@as(u32, @intFromBool(req.flags.CREAT)) << 2) |
        (@as(u32, @intFromBool(req.flags.EXCL)) << 3) |
        (@as(u32, @intFromBool(req.flags.TRUNC)) << 4) |
        (@as(u32, @intFromBool(req.flags.NOFOLLOW)) << 5) |
        (@as(u32, @intFromBool(req.mkdir_parents)) << 6);
    std.mem.writeInt(u32, header[8..12], flags, .little);
    std.mem.writeInt(u32, header[12..16], req.mode, .little);
    try transfer(socket, &header, true);
    // write does not mutate the bytes.
    try transfer(socket, @constCast(req.path), true);
}

fn sendResponse(socket: c_int, fd: ?c_int, errno: c_int) !void {
    var bytes: [response_size]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], magic, .little);
    std.mem.writeInt(u32, bytes[4..8], @intCast(errno), .little);
    var control: [control_size]u8 align(@alignOf(Control)) = @splat(0);
    if (fd) |file| {
        const header: *Control = @ptrCast(&control);
        header.* = .{ .len = control_data + @sizeOf(c_int), .level = sol_socket, .kind = 1 }; // SCM_RIGHTS
        @as(*c_int, @ptrCast(@alignCast(&control[control_data]))).* = file;
    }
    var iov = Iovec{ .base = &bytes, .len = bytes.len };
    var msg = Message{ .iov = @ptrCast(&iov), .control = if (fd != null) &control else null, .controllen = if (fd != null) control.len else 0 };
    try wait(socket, std.c.POLL.OUT);
    const n = sendmsg(socket, &msg, if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0);
    if (n <= 0) return error.SandboxHelperProtocol;
    if (n < bytes.len) try transfer(socket, bytes[@intCast(n)..], true);
}

pub fn receiveResponse(socket: c_int) !pfs.Fd {
    var bytes: [response_size]u8 = undefined;
    var control: [control_size]u8 align(@alignOf(Control)) = @splat(0);
    var iov = Iovec{ .base = &bytes, .len = bytes.len };
    var msg = Message{ .iov = @ptrCast(&iov), .control = &control, .controllen = control.len };
    try wait(socket, std.c.POLL.IN);
    const n = recvmsg(socket, &msg, 0);
    if (n <= 0) return error.SandboxHelperProtocol;
    var received: ?c_int = null;
    const header: *const Control = @ptrCast(&control);
    var unexpected_rights = false;
    if (msg.controllen >= control_data + @sizeOf(c_int) and header.level == sol_socket and
        header.kind == 1 and header.len >= control_data + @sizeOf(c_int))
    {
        const end = @min(@as(usize, header.len), @min(@as(usize, msg.controllen), control.len));
        var offset: usize = control_data;
        while (offset + @sizeOf(c_int) <= end) : (offset += @sizeOf(c_int)) {
            const fd = @as(*const c_int, @ptrCast(@alignCast(&control[offset]))).*;
            if (received == null) received = fd else {
                _ = std.c.close(fd);
                unexpected_rights = true;
            }
        }
        if (header.len != control_data + @sizeOf(c_int)) unexpected_rights = true;
    }
    errdefer if (received) |fd| {
        _ = std.c.close(fd);
    };
    // MSG_CTRUNC / MSG_TRUNC: no partial or extra capability is acceptable.
    if (msg.flags != 0 or unexpected_rights) return error.SandboxHelperProtocol;
    if (n < bytes.len) try transfer(socket, bytes[@intCast(n)..], false);
    if (std.mem.readInt(u32, bytes[0..4], .little) != magic) return error.SandboxHelperProtocol;
    const errno = std.mem.readInt(u32, bytes[4..8], .little);
    if (errno != 0) {
        if (received != null) return error.SandboxHelperProtocol;
        if (errno > std.math.maxInt(c_int)) return error.SandboxHelperProtocol;
        // Preserve meaningful native open errors without relying on the
        // parent's unrelated errno left by process/IPC operations.
        if (pfs.errnoTag(@intCast(errno))) |tag| pfs.setErrno(tag);
        return if (errno == @intFromEnum(std.c.E.NOENT)) error.FileNotFound else error.SandboxAccessDenied;
    }
    const fd = received orelse return error.SandboxHelperProtocol;
    try pfs.makeCloseOnExec(fd);
    return fd;
}

pub fn serve() !void {
    if (!supported) return error.SandboxUnavailable;
    var header: [header_size]u8 = undefined;
    try transfer(0, &header, false);
    if (std.mem.readInt(u32, header[0..4], .little) != magic or
        std.mem.readInt(u32, header[16..20], .little) != 0) return error.SandboxHelperProtocol;
    const len = std.mem.readInt(u32, header[4..8], .little);
    const bits = std.mem.readInt(u32, header[8..12], .little);
    const mode = std.mem.readInt(u32, header[12..16], .little);
    if (len == 0 or len >= std.fs.max_path_bytes or bits & ~@as(u32, 127) != 0 or bits & 3 > 2 or mode & ~@as(u32, 0o777) != 0)
        return error.SandboxHelperProtocol;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try transfer(0, path_buf[0..len], false);
    path_buf[len] = 0;
    const path = path_buf[0..len :0];
    if (path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.SandboxHelperProtocol;
    const flags: pfs.O = .{
        .ACCMODE = @enumFromInt(bits & 3),
        .CREAT = bits & 4 != 0,
        .EXCL = bits & 8 != 0,
        .TRUNC = bits & 16 != 0,
        .NOFOLLOW = bits & 32 != 0,
        .NONBLOCK = true, // a FIFO/device must never hang the agent open
    };
    if (bits & 64 != 0) try @import("../util/fs.zig").mkdirParentsOf(path);
    const fd = pfs.open(path.ptr, flags, mode);
    if (fd < 0) return sendResponse(0, null, pfs.lastErrno());
    defer _ = pfs.close(fd);
    // Native file tools consume regular files; never transfer directory,
    // device, socket, or FIFO capabilities to the unsandboxed host.
    const info = pfs.fileInfo(fd) catch return sendResponse(0, null, @intFromEnum(std.c.E.ACCES));
    if (!info.is_regular) return sendResponse(0, null, @intFromEnum(std.c.E.ACCES));
    try sendResponse(0, fd, 0);
}
