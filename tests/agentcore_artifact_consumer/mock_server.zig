const std = @import("std");
const net = @import("platform").net;

pub const Server = struct {
    listener: net.Socket,
    port: u16,
    bodies: []const []const u8,
    thread: std.Thread,
    closing: std.atomic.Value(bool) = .init(false),

    pub fn start(_: std.Io, bodies: []const []const u8) !*Server {
        const listener = try net.listenLoopback(0, 16);
        errdefer net.closeSocket(listener.sock);
        const self = try std.heap.page_allocator.create(Server);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{
            .listener = listener.sock,
            .port = listener.port,
            .bodies = bodies,
            .thread = undefined,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    pub fn url(self: *const Server, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1/messages", .{self.port});
    }

    pub fn stop(self: *Server) void {
        self.closing.store(true, .release);
        // Closing a socket does not reliably wake accept on every supported
        // Windows build. A loopback connection is a deterministic wake-up.
        if (net.connectLoopback(self.port)) |wake| net.closeSocket(wake) else |_| {}
        net.closeSocket(self.listener);
        self.thread.join();
        std.heap.page_allocator.destroy(self);
    }

    fn serve(self: *Server) void {
        for (self.bodies) |body| {
            if (self.closing.load(.acquire)) return;
            const conn = net.acceptConn(self.listener) orelse return;
            if (self.closing.load(.acquire)) {
                net.closeSocket(conn);
                return;
            }
            serveResponse(conn, body);
            net.closeSocket(conn);
        }
    }
};

fn serveResponse(conn: net.Socket, body: []const u8) void {
    // Winsock resets a connection that is closed while request bytes remain
    // unread.  The reset can discard an already-sent response, so consume the
    // complete fixed-length provider request before returning the SSE body.
    net.setRecvTimeoutMs(conn, 10_000);
    net.setSendTimeoutMs(conn, 10_000);
    if (!drainRequest(conn)) return;

    var header: [256]u8 = undefined;
    const header_bytes = std.fmt.bufPrint(
        &header,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{body.len},
    ) catch return;
    sendAll(conn, header_bytes);
    sendAll(conn, body);
}

fn drainRequest(conn: net.Socket) bool {
    var header: [16 * 1024]u8 = undefined;
    var total: usize = 0;
    var header_end: ?usize = null;
    var content_length: usize = 0;
    while (total < header.len and header_end == null) {
        const received = net.recv(conn, header[total..]);
        if (received <= 0) return false;
        total += @intCast(received);
        if (std.mem.indexOf(u8, header[0..total], "\r\n\r\n")) |index| {
            header_end = index + 4;
            content_length = parseContentLength(header[0..index]) orelse 0;
        }
    }

    const body_start = header_end orelse return false;
    const buffered_body = total - body_start;
    if (buffered_body >= content_length) return true;

    var remaining = content_length - buffered_body;
    var discard: [16 * 1024]u8 = undefined;
    while (remaining > 0) {
        const received = net.recv(conn, discard[0..@min(remaining, discard.len)]);
        if (received <= 0) return false;
        remaining -= @intCast(received);
    }
    return true;
}

fn parseContentLength(header: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch null;
    }
    return null;
}

fn sendAll(conn: net.Socket, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = net.send(conn, bytes[offset..]);
        if (written <= 0) return;
        offset += @intCast(written);
    }
}
