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
    var header: [256]u8 = undefined;
    const header_bytes = std.fmt.bufPrint(
        &header,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{body.len},
    ) catch return;
    sendAll(conn, header_bytes);
    sendAll(conn, body);
}

fn sendAll(conn: net.Socket, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = net.send(conn, bytes[offset..]);
        if (written <= 0) return;
        offset += @intCast(written);
    }
}
